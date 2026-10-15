import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path_util;
import 'package:path_provider/path_provider.dart';

import '../source/models.dart';
import 'catalog_cache_service.dart';
import 'log_service.dart';
import 'pan_rate_limit.dart';
import 'secure_store.dart';

/// 115 网盘条目。
class Pan115Item {
  final String fid;
  final String pickCode;
  final String name;
  final bool isDirectory;
  final int size;
  final String thumb;

  const Pan115Item({
    required this.fid,
    required this.name,
    required this.isDirectory,
    this.pickCode = '',
    this.size = 0,
    this.thumb = '',
  });
}

class Pan115Page {
  final List<Pan115Item> items;
  final int page;
  final int pageSize;
  final bool hasMore;
  final int total;

  const Pan115Page({
    required this.items,
    required this.page,
    required this.pageSize,
    required this.hasMore,
    required this.total,
  });
}

class Pan115Audio {
  final String url;
  final Map<String, String> headers;

  const Pan115Audio(this.url, this.headers);
}

class Pan115BookMeta {
  final String title;
  final String author;
  final String narrator;

  const Pan115BookMeta({
    required this.title,
    required this.author,
    required this.narrator,
  });
}

class Pan115Book {
  final String title;
  final String author;
  final String narrator;
  final String cover;
  final String cid;
  final List<Pan115Item> audioFiles;

  const Pan115Book({
    required this.title,
    required this.author,
    required this.narrator,
    required this.cover,
    required this.cid,
    required this.audioFiles,
  });
}

/// 扫码登录会话状态。
class Pan115QrSession {
  final String qrcode;
  final String uid;
  final int time;
  final String sign;
  final String codeVerifier;
  final String appId;

  const Pan115QrSession({
    required this.qrcode,
    required this.uid,
    required this.time,
    required this.sign,
    required this.codeVerifier,
    required this.appId,
  });
}

/// 115 网盘后端:基于 115 官方开放平台 OAuth2 Device Code + PKCE 扫码登录与开放接口。
///
/// ── 流程体系 ──
/// 1. 扫码登录 (OAuth2 Device Code + PKCE, Public Client 模式, 无需 AppSecret)
///    - Step 1: POST https://passportapi.115.com/open/authDeviceCode
///              client_id, code_challenge (base64url(sha256(verifier))), code_challenge_method=sha256
///              -> 返回 { qrcode, uid, time, sign }
///    - Step 2: GET https://qrcodeapi.115.com/get/status/?uid={uid}&time={time}&sign={sign}
///              长轮询扫码状态: 0=等待扫码 1=已扫码待确认 2=已确认 -1=已过期/取消
///    - Step 3: POST https://passportapi.115.com/open/authCodeToToken
///              uid, code_verifier
///              -> 返回 { access_token, refresh_token, expires_in }
///    - Step 4: POST https://passportapi.115.com/open/authRefreshToken
///              refresh_token -> 刷新 access_token
/// 2. 列目录: GET https://proapi.115.com/open/ufile/files?cid={cid}&limit={limit}&offset={offset}
///    Header: Authorization: Bearer &lt;access_token&gt;
/// 3. 取直链:
///    - 优先: GET https://proapi.115.com/open/ufile/downurl?pick_code={pick_code}
///    - 兜底: GET https://proapi.115.com/open/video/play?pick_code={pick_code}
///    Header: Authorization: Bearer &lt;access_token&gt;
class Pan115Service extends ChangeNotifier {
  Pan115Service._();
  static final instance = Pan115Service._();

  static const _kConfig = 'pan115_config';
  // 配置(含登录凭据)的加密存储键;明文旧键由 SecureStore 迁移后删除。
  static const _kConfigSecure = 'sec.pan115_config';

  /// 目录/书库标识(写入 catalog_books.sourceId 与章节 chapterId 前缀)。
  static const sourceId = 'pan115';
  static const chapterPrefix = 'pan115:';

  static const rootCid = '0';
  static const _pageSize = 100;
  static const _maxAutoPages = 50;

  static const _passportBase = 'https://passportapi.115.com';
  static const _qrcodeBase = 'https://qrcodeapi.115.com';
  static const _openApiBase = 'https://proapi.115.com';
  static const _webBase = 'https://115.com';
  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/121.0.0.0 Safari/537.36 115Browser/27.0.0.0';

  static const audioExtensions = {
    '.mp3',
    '.m4a',
    '.m4b',
    '.aac',
    '.flac',
    '.wav',
    '.ogg',
    '.opus',
    '.ape',
    '.wma',
  };
  static const _coverExtensions = {'.jpg', '.jpeg', '.png', '.webp'};

  /// 内置默认 115 开放平台 AppID (用户仍可在 UI 中自定义修改并加密持久化)。
  static const defaultAppId = '100195135';

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
      sendTimeout: const Duration(seconds: 30),
    ),
  );
  final Random _random = Random();

  String _appId = '';
  String _accessToken = '';
  String _refreshToken = '';
  int _expiresAt = 0;
  String _cookie = '';

  String get appId => _appId.isNotEmpty ? _appId : defaultAppId;
  String get accessToken => _accessToken;
  String get refreshToken => _refreshToken;
  int get expiresAt => _expiresAt;
  String get cookie => _cookie;

  /// 无论是有 access_token 还是保留的 Cookie,都视为就绪。
  bool get ready => _accessToken.isNotEmpty || _cookie.isNotEmpty;
  String get webBase => _webBase;

  Future<void> init() async {
    final raw = await SecureStore.instance.readMigrated(
      _kConfig,
      _kConfigSecure,
    );
    if (raw == null || raw.isEmpty) return;
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      _appId = '${map['app_id'] ?? ''}'.trim();
      _accessToken = '${map['access_token'] ?? ''}'.trim();
      _refreshToken = '${map['refresh_token'] ?? ''}'.trim();
      _expiresAt = _asInt(map['expires_at']);
      _cookie = '${map['cookie'] ?? ''}'.trim();
      LogService.instance.info(
        'Pan115',
        '读取已存配置完成',
        detail:
            'AppID: ${_appId.isNotEmpty ? _appId : '(未设置)'}\nToken: ${tokenSummary(_accessToken)}\nCookie: ${cookieSummary(_cookie)}',
      );
    } catch (e) {
      LogService.instance.warning('Pan115', '读取配置失败', detail: '$e');
    }
  }

  Future<void> _persist() async {
    await SecureStore.instance.write(
      _kConfigSecure,
      jsonEncode({
        'app_id': _appId,
        'access_token': _accessToken,
        'refresh_token': _refreshToken,
        'expires_at': _expiresAt,
        'cookie': _cookie,
      }),
    );
  }

  Future<void> setAppId(String appId) async {
    _appId = appId.trim();
    await _persist();
    notifyListeners();
  }

  Future<void> saveTokenManual({
    required String appId,
    required String accessToken,
    String refreshToken = '',
    int expiresIn = 7200,
  }) async {
    _appId = appId.trim();
    _accessToken = accessToken.trim();
    _refreshToken = refreshToken.trim();
    _expiresAt = DateTime.now().millisecondsSinceEpoch + (expiresIn * 1000);
    await _persist();
    LogService.instance.info(
      'Pan115',
      '手动保存 Token 成功',
      detail: 'AppID: $_appId\nToken: ${tokenSummary(_accessToken)}',
    );
    notifyListeners();
  }

  Future<void> saveCookie(String cookie) async {
    _cookie = cookie.trim();
    await _persist();
    LogService.instance.info(
      'Pan115',
      '已保存登录 Cookie',
      detail: '长度: ${_cookie.length}\n字段: ${cookieSummary(_cookie)}',
    );
    notifyListeners();
  }

  Future<void> logout() async {
    _accessToken = '';
    _refreshToken = '';
    _expiresAt = 0;
    _cookie = '';
    await _persist();
    notifyListeners();
  }

  // ── PKCE 与扫码登录认证 ──

  static String genVerifier() {
    const chars =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
    final r = Random.secure();
    return List.generate(64, (_) => chars[r.nextInt(chars.length)]).join();
  }

  static String genChallenge(String verifier) => base64Url
      .encode(sha256.convert(utf8.encode(verifier)).bytes)
      .replaceAll('=', '');

  /// Step 1: 请求设备码与二维码内容。
  Future<Pan115QrSession> authDeviceCode({String? appId}) async {
    final useAppId = (appId ?? this.appId).trim();
    final effectiveAppId = useAppId.isNotEmpty ? useAppId : defaultAppId;
    _appId = effectiveAppId;

    final verifier = genVerifier();
    final challenge = genChallenge(verifier);

    LogService.instance.info('Pan115', '请求扫码设备码', detail: 'AppID: $effectiveAppId');

    final resp = await _dio.post<String>(
      '$_passportBase/open/authDeviceCode',
      data: {
        'client_id': effectiveAppId,
        'code_challenge': challenge,
        'code_challenge_method': 'sha256',
      },
      options: Options(
        contentType: Headers.formUrlEncodedContentType,
        responseType: ResponseType.plain,
        validateStatus: (_) => true,
      ),
    );

    if ((resp.statusCode ?? 0) >= 400) {
      throw Exception(
        '获取 115 扫码二维码失败 HTTP ${resp.statusCode}: ${resp.data}',
      );
    }

    final data = _decodeBody(resp.data ?? '{}');
    _ensureOk(data);

    final payload = data['data'];
    if (payload is! Map) {
      throw Exception('115 返回设备码格式错误: ${resp.data}');
    }

    final qrcode = '${payload['qrcode'] ?? ''}'.trim();
    final uid = '${payload['uid'] ?? ''}'.trim();
    final time = _asInt(payload['time']);
    final sign = '${payload['sign'] ?? ''}'.trim();

    if (qrcode.isEmpty || uid.isEmpty) {
      throw Exception('115 未返回有效二维码或 UID');
    }

    return Pan115QrSession(
      qrcode: qrcode,
      uid: uid,
      time: time,
      sign: sign,
      codeVerifier: verifier,
      appId: useAppId,
    );
  }

  /// Step 2: 轮询扫码状态。
  /// 返回码状态:
  ///   0: 等待扫码 (继续轮询)
  ///   1: 已扫码，等待确认 (继续轮询)
  ///   2: 已确认 (可换取 Token)
  ///  -1: 已过期 / 已取消 (结束轮询)
  Future<int> pollQrStatus(Pan115QrSession session) async {
    final resp = await _dio.get<String>(
      '$_qrcodeBase/get/status/',
      queryParameters: {
        'uid': session.uid,
        'time': session.time,
        'sign': session.sign,
        '_': DateTime.now().millisecondsSinceEpoch,
      },
      options: Options(
        responseType: ResponseType.plain,
        // 长轮询响应超时留足时间
        receiveTimeout: const Duration(seconds: 40),
        validateStatus: (_) => true,
      ),
    );

    if ((resp.statusCode ?? 0) >= 400) {
      throw Exception('轮询扫码状态失败 HTTP ${resp.statusCode}');
    }

    final data = _decodeBody(resp.data ?? '{}');
    final state = data['state'];
    // state 为 0 表示二维码无效或过期
    if (state == 0 || state == false) {
      return -1;
    }

    dynamic statusVal;
    if (data['data'] is Map) {
      statusVal = data['data']['status'];
    } else {
      statusVal = data['status'];
    }

    final status = _asInt(statusVal);
    final msg = '${data['msg'] ?? data['message'] ?? ''}';
    if (msg.contains('过期') || msg.contains('取消')) return -1;
    return status;
  }

  /// Step 3: 用户确认后用 uid + code_verifier 换取 Token。
  Future<void> authCodeToToken(Pan115QrSession session) async {
    LogService.instance.info(
      'Pan115',
      '用设备码换取 Token',
      detail: 'UID: ${session.uid}',
    );

    // 官方接口: POST /open/deviceCodeToToken (根据官方语雀文档)
    final resp = await _dio.post<String>(
      '$_passportBase/open/deviceCodeToToken',
      data: {
        'uid': session.uid,
        'code_verifier': session.codeVerifier,
      },
      options: Options(
        contentType: Headers.formUrlEncodedContentType,
        responseType: ResponseType.plain,
        validateStatus: (_) => true,
      ),
    );

    if ((resp.statusCode ?? 0) >= 400) {
      throw Exception('换取 Token 失败 HTTP ${resp.statusCode}: ${resp.data}');
    }

    final data = _decodeBody(resp.data ?? '{}');
    _ensureOk(data);

    final payload = (data['data'] is Map) ? data['data'] as Map : data;
    final at = '${payload['access_token'] ?? ''}'.trim();
    final rt = '${payload['refresh_token'] ?? ''}'.trim();
    final expiresIn = _asInt(payload['expires_in']);

    if (at.isEmpty) {
      throw Exception('换取 Token 失败：响应未包含 access_token');
    }

    _appId = session.appId;
    _accessToken = at;
    _refreshToken = rt;
    _expiresAt = DateTime.now().millisecondsSinceEpoch +
        (expiresIn > 0 ? expiresIn : 7200) * 1000;

    await _persist();
    LogService.instance.info(
      'Pan115',
      '扫码登录成功，Token 已保存',
      detail:
          'AppID: $_appId\nToken: ${tokenSummary(_accessToken)}\n有效秒数: $expiresIn',
    );
    notifyListeners();
  }

  /// Step 4: 刷新 Token。
  Future<bool> refreshAccessToken() async {
    if (_refreshToken.isEmpty) return false;

    LogService.instance.info('Pan115', '请求刷新 Token');

    try {
      final resp = await _dio.post<String>(
        '$_passportBase/open/refreshToken',
        data: {'refresh_token': _refreshToken},
        options: Options(
          contentType: Headers.formUrlEncodedContentType,
          responseType: ResponseType.plain,
          validateStatus: (_) => true,
        ),
      );

      if ((resp.statusCode ?? 0) >= 400) {
        LogService.instance.warning(
          'Pan115',
          '刷新 Token 失败 HTTP ${resp.statusCode}',
          detail: resp.data,
        );
        return false;
      }

      final data = _decodeBody(resp.data ?? '{}');
      _ensureOk(data);

      final payload = (data['data'] is Map) ? data['data'] as Map : data;
      final at = '${payload['access_token'] ?? ''}'.trim();
      final rt = '${payload['refresh_token'] ?? ''}'.trim();
      final expiresIn = _asInt(payload['expires_in']);

      if (at.isEmpty) return false;

      _accessToken = at;
      if (rt.isNotEmpty) _refreshToken = rt;
      _expiresAt = DateTime.now().millisecondsSinceEpoch +
          (expiresIn > 0 ? expiresIn : 7200) * 1000;

      await _persist();
      LogService.instance.info(
        'Pan115',
        '刷新 Token 成功',
        detail: 'Token: ${tokenSummary(_accessToken)}\n有效秒数: $expiresIn',
      );
      notifyListeners();
      return true;
    } catch (e) {
      LogService.instance.warning('Pan115', '刷新 Token 异常', detail: '$e');
      return false;
    }
  }

  /// 在发起请求前自动检测 Token 是否即将过期(5 分钟内)，若需刷新则提前刷新。
  Future<void> ensureValidToken() async {
    if (_accessToken.isEmpty || _refreshToken.isEmpty) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    // 提前 300 秒刷新
    if (_expiresAt > 0 && now + 300000 >= _expiresAt) {
      await refreshAccessToken();
    }
  }

  // ── 纯函数部分(可单测) ──

  static bool isAudioName(String name) {
    final lower = name.toLowerCase();
    return audioExtensions.any(lower.endsWith);
  }

  static bool isCoverName(String name) {
    final lower = name.toLowerCase();
    return lower.startsWith('cover') && _coverExtensions.any(lower.endsWith);
  }

  /// 文件夹名 `书名_作者_演播者` → 元数据;不足三段返回 null(由调用方回落目录名)。
  static Pan115BookMeta? parseFolderName(String name) {
    final parts = name
        .split(RegExp(r'_+'))
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty)
        .toList(growable: false);
    if (parts.length < 3) return null;
    return Pan115BookMeta(
      title: parts.first,
      author: parts[1],
      narrator: parts.sublist(2).join('_'),
    );
  }

  /// 列表接口条目 → 领域对象。兼容官方开放平台字段与历史别名。
  /// 根据官方语雀文档:
  /// - `fc`: 文件分类。0 文件夹，1 文件
  /// - `fn`: 文件(夹)名称
  /// - `fid`: 文件ID
  /// - `pc`: 文件提取码
  /// - `fs`: 文件大小 (int)
  /// - `thumb` / `fco` / `ico`: 缩略图 / 文件夹封面 / 后缀名
  static Pan115Item itemFromJson(Map<String, dynamic> json) {
    final fc = json['fc'];
    final dirValue = json['is_dir'] ?? json['isDir'] ?? json['dir'];
    final rawType = json['t'] ?? json['type'];
    final fileCategory = json['file_category'];

    final isDir =
        fc == 0 ||
        fc == '0' ||
        dirValue == true ||
        dirValue == 1 ||
        dirValue == '1' ||
        rawType == 'folder' ||
        rawType == 'dir' ||
        fileCategory == 0 ||
        fileCategory == '0';

    final name = '${json['fn'] ?? json['file_name'] ?? json['name'] ?? json['n'] ?? ''}'.trim();
    final fid = '${json['fid'] ?? json['file_id'] ?? json['id'] ?? ''}'.trim();
    final pickCode = '${json['pc'] ?? json['pick_code'] ?? json['pickcode'] ?? ''}'.trim();
    final size = _asInt(json['fs'] ?? json['file_size'] ?? json['size'] ?? json['s']);
    final thumb = '${json['fco'] ?? json['thumb'] ?? json['thumb_url'] ?? json['ico'] ?? json['u'] ?? ''}'.trim();

    return Pan115Item(
      fid: fid,
      pickCode: pickCode,
      name: name,
      isDirectory: isDir,
      size: size,
      thumb: thumb,
    );
  }

  /// 章节 id:优先用 pick_code(取直链需要);缺失时退回 `id:<fid>` 形式。
  static String chapterToken(Pan115Item item) {
    if (item.pickCode.isNotEmpty) return item.pickCode;
    return 'id:${item.fid}';
  }

  static String chapterIdFor(Pan115Item item) =>
      '$chapterPrefix${chapterToken(item)}';

  /// 播放/下载用的请求头。兼容 Token 与 Cookie 两种凭据。
  static Map<String, String> playHeadersFor(String tokenOrCookie) {
    final out = <String, String>{
      'User-Agent': _ua,
      'Referer': '$_webBase/',
    };
    if (tokenOrCookie.isNotEmpty) {
      if (tokenOrCookie.contains('=')) {
        out['Cookie'] = tokenOrCookie;
      } else {
        out['Authorization'] = 'Bearer $tokenOrCookie';
      }
    }
    return out;
  }

  /// 115 请求头降级变体:0=完整凭据 1=去 Cookie 与 Authorization 2=仅 UA。
  static Map<String, String> headerVariantHeaders(
    Map<String, String> headers,
    int variant,
  ) {
    if (variant <= 0) return headers;
    final out = {...headers}
      ..remove('Cookie')
      ..remove('Authorization');
    if (variant >= 2) out.remove('Referer');
    return out;
  }

  static String cookieSummary(String cookie) {
    final keys = cookie
        .split(';')
        .map((part) => part.trim().split('=').first.trim())
        .where((key) => key.isNotEmpty)
        .take(12)
        .toList();
    return keys.isEmpty ? '(无)' : keys.join(', ');
  }

  static String tokenSummary(String token) {
    if (token.isEmpty) return '(无)';
    if (token.length <= 8) return '长度: ${token.length}';
    return '${token.substring(0, 4)}...${token.substring(token.length - 4)} (长度 ${token.length})';
  }

  static int naturalCompare(String a, String b) {
    final ax = _tokens(a);
    final bx = _tokens(b);
    final len = ax.length < bx.length ? ax.length : bx.length;
    for (var i = 0; i < len; i++) {
      final cmp = ax[i].compareTo(bx[i]);
      if (cmp != 0) return cmp;
    }
    return ax.length.compareTo(bx.length);
  }

  static List<String> _tokens(String value) {
    final out = <String>[];
    final lower = value.toLowerCase();
    for (final match in RegExp(r'\d+|\D+').allMatches(lower)) {
      final token = match.group(0) ?? '';
      if (token.isEmpty) continue;
      final number = int.tryParse(token);
      out.add(number == null ? token : number.toString().padLeft(12, '0'));
    }
    return out;
  }

  static int _asInt(dynamic value) {
    if (value is num) return value.toInt();
    return int.tryParse('$value') ?? 0;
  }

  static int compareItems(Pan115Item a, Pan115Item b) {
    if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
    return naturalCompare(a.name, b.name);
  }

  // ── 网络业务部分 ──

  bool isAudioFile(String name) => isAudioName(name);
  bool isCoverFile(String name) => isCoverName(name);

  /// 获取当前 115 登录用户信息与 VIP 状态。
  Future<Map<String, dynamic>> getUserInfo() async {
    if (!ready || _accessToken.isEmpty) {
      return const {};
    }
    await ensureValidToken();
    try {
      final resp = await _dio.get<String>(
        '$_openApiBase/open/user/info',
        options: Options(
          headers: {
            'Authorization': 'Bearer $_accessToken',
            'User-Agent': _ua,
            'Accept': 'application/json',
          },
          responseType: ResponseType.plain,
          validateStatus: (_) => true,
        ),
      );
      if (resp.statusCode == 401) {
        final refreshed = await refreshAccessToken();
        if (refreshed) return await getUserInfo();
      }
      if ((resp.statusCode ?? 0) < 400 && resp.data != null) {
        final data = _decodeBody(resp.data!);
        _ensureOk(data);
        final payload = data['data'];
        if (payload is Map) {
          return Map<String, dynamic>.from(payload);
        }
      }
    } catch (e) {
      LogService.instance.warning('Pan115', '获取用户信息异常', detail: '$e');
    }
    return const {};
  }

  /// 搜索网盘文件 (支持全局搜索有声书或音频)。
  Future<List<Pan115Item>> searchFiles(String keyword, {int limit = 100}) async {
    final kw = keyword.trim();
    if (kw.isEmpty) return const [];
    if (!ready) throw Exception('请先登录 115 网盘');
    await ensureValidToken();

    final isTokenAuth = _accessToken.isNotEmpty;
    if (!isTokenAuth) return const [];

    try {
      final resp = await _dio.get<String>(
        '$_openApiBase/open/ufile/search',
        queryParameters: {
          'search_value': kw,
          'limit': limit,
          'offset': 0,
        },
        options: Options(
          headers: {
            'Authorization': 'Bearer $_accessToken',
            'User-Agent': _ua,
            'Accept': 'application/json',
          },
          responseType: ResponseType.plain,
          validateStatus: (_) => true,
        ),
      );

      if (resp.statusCode == 401) {
        final refreshed = await refreshAccessToken();
        if (refreshed) return await searchFiles(keyword, limit: limit);
      }

      if ((resp.statusCode ?? 0) < 400 && resp.data != null) {
        final data = _decodeBody(resp.data!);
        _ensureOk(data);
        final rawList = data['data'];
        final items = <Pan115Item>[];
        if (rawList is List) {
          for (final entry in rawList) {
            if (entry is! Map) continue;
            final item = itemFromJson(Map<String, dynamic>.from(entry));
            if (item.fid.isEmpty && item.pickCode.isEmpty) continue;
            items.add(item);
          }
        }
        items.sort(compareItems);
        return items;
      }
    } catch (e) {
      LogService.instance.warning('Pan115', '搜索文件异常', detail: '$e');
      rethrow;
    }
    return const [];
  }

  Future<bool> checkLogin() async {
    if (!ready) return false;
    try {
      await listPage(rootCid, page: 1);
      LogService.instance.info('Pan115', '登录状态检测通过');
      return true;
    } catch (e) {
      LogService.instance.warning('Pan115', '登录状态检测失败', detail: '$e');
      return false;
    }
  }

  Pan115BookMeta? parseBookFolderName(String name) => parseFolderName(name);

  Future<List<Pan115Item>> list(String cid) async {
    final all = <Pan115Item>[];
    var page = 1;
    var hasMore = true;
    while (hasMore && page <= _maxAutoPages) {
      Pan115Page result;
      try {
        result = await listPage(cid, page: page);
      } on PanRateLimitException catch (e) {
        if (page == 1) rethrow;
        final wait = panBackoffDelayMs(_random);
        LogService.instance.warning(
          'Pan115',
          '触发网盘限流，退避后重试',
          detail: 'CID: $cid\n页码: $page\n等待: ${wait}ms\n${e.detail}',
        );
        await Future<void>.delayed(Duration(milliseconds: wait));
        result = await listPage(cid, page: page);
      }
      all.addAll(result.items);
      hasMore = result.hasMore;
      LogService.instance.info(
        'Pan115',
        '目录分页读取',
        detail:
            'CID: $cid\n页码: ${result.page}\n本页: ${result.items.length}\n累计: ${all.length}\n总数: ${result.total > 0 ? result.total : '未知'}\n继续: ${result.hasMore ? '是' : '否'}',
      );
      page++;
      if (hasMore) {
        await Future<void>.delayed(
          Duration(milliseconds: 250 + _random.nextInt(400)),
        );
      }
    }
    if (hasMore) {
      LogService.instance.warning(
        'Pan115',
        '目录页数超过保护上限，已停止继续读取',
        detail: 'CID: $cid\n已读取页数: $_maxAutoPages\n累计条目: ${all.length}',
      );
    }
    all.sort(compareItems);
    LogService.instance.info(
      'Pan115',
      '列目录完成',
      detail: 'CID: $cid\n条目: ${all.length}\n页数: ${page - 1}',
    );
    return all;
  }

  /// 分页获取指定目录下的条目。
  Future<Pan115Page> listPage(String cid, {int page = 1}) async {
    if (!ready) throw Exception('请先登录 115 网盘');

    await ensureValidToken();

    LogService.instance.info(
      'Pan115',
      '请求目录页',
      detail: 'CID: $cid\n页码: $page\n每页: $_pageSize',
    );

    // 优先使用官方开放平台接口 /open/ufile/files
    final offset = (page - 1) * _pageSize;
    final isTokenAuth = _accessToken.isNotEmpty;

    Response<String> resp;
    if (isTokenAuth) {
      final query = <String, dynamic>{
        'offset': offset,
        'limit': _pageSize,
        'show_dir': 1,
      };
      // cid 非空且不为根目录 '0' 时才传递 cid 参数；根目录由接口默认返回根层级
      if (cid.isNotEmpty && cid != '0') {
        query['cid'] = cid;
      }
      resp = await _dio.get<String>(
        '$_openApiBase/open/ufile/files',
        queryParameters: query,
        options: Options(
          headers: {
            'Authorization': 'Bearer $_accessToken',
            'User-Agent': _ua,
            'Accept': 'application/json, text/plain, */*',
          },
          responseType: ResponseType.plain,
          validateStatus: (_) => true,
        ),
      );
      if (resp.statusCode == 401) {
        final refreshed = await refreshAccessToken();
        if (refreshed) {
          return listPage(cid, page: page);
        }
        throw Exception('115 授权已失效，请重新扫码登录');
      }
    } else {
      // 兼容旧版 Web Cookie
      resp = await _dio.get<String>(
        'https://webapi.115.com/files',
        queryParameters: {
          'aid': 1,
          'cid': cid,
          'offset': offset,
          'limit': _pageSize,
          'show_dir': 1,
          'o': 'user_ptime',
          'asc': 0,
          'natsort': 0,
          'snap': 0,
          'record_open_time': 1,
          'format': 'json',
        },
        options: Options(
          headers: _headers(),
          responseType: ResponseType.plain,
          validateStatus: (_) => true,
        ),
      );
    }

    if (resp.statusCode == 429) {
      throw PanRateLimitException('115 目录请求被限流\nCID: $cid\n页码: $page');
    }
    if ((resp.statusCode ?? 0) >= 400) {
      throw Exception('115 目录请求失败 HTTP ${resp.statusCode}\nCID: $cid\n页码: $page');
    }

    final data = _decodeBody(resp.data ?? '{}');
    _ensureOk(data);

    final rawList = data['data'];
    final items = <Pan115Item>[];
    if (rawList is List) {
      for (final entry in rawList) {
        if (entry is! Map) continue;
        final item = itemFromJson(Map<String, dynamic>.from(entry));
        if (item.fid.isEmpty && item.pickCode.isEmpty) continue;
        items.add(item);
      }
    }
    items.sort(compareItems);

    final total = _asInt(data['count'] ?? data['total']);
    return Pan115Page(
      items: items,
      page: page,
      pageSize: _pageSize,
      hasMore: total > 0 ? page * _pageSize < total : items.length >= _pageSize,
      total: total,
    );
  }

  Future<List<Pan115Item>> collectAudioFiles(String cid) async {
    final out = <Pan115Item>[];
    await _collect(cid, out, 0);
    return out;
  }

  Future<void> _collect(String cid, List<Pan115Item> out, int depth) async {
    if (depth > 3) return;
    final items = await list(cid);
    final audios = items
        .where((e) => !e.isDirectory && isAudioFile(e.name))
        .toList()
      ..sort((a, b) => naturalCompare(a.name, b.name));
    out.addAll(audios);
    final subs = items.where((e) => e.isDirectory).toList()
      ..sort((a, b) => naturalCompare(a.name, b.name));
    for (final sub in subs) {
      await Future<void>.delayed(
        Duration(milliseconds: 300 + _random.nextInt(500)),
      );
      await _collect(sub.fid, out, depth + 1);
    }
  }

  Future<Pan115Book> toBook(String cid, {required String folderName}) async {
    final meta = parseBookFolderName(folderName);
    final topItems = await list(cid);
    final audios = await collectAudioFiles(cid);
    final cover = await resolveBookCover(topItems, audios, bookCid: cid);
    return Pan115Book(
      title: meta?.title ?? folderName,
      author: meta?.author ?? '',
      narrator: meta?.narrator ?? '',
      cover: cover,
      cid: cid,
      audioFiles: audios,
    );
  }

  Future<CachedCatalog> refreshCatalog({
    required String bookCid,
    required String folderName,
    String fallbackCover = '',
    String fallbackAuthor = '',
  }) async {
    final book = await toBook(bookCid, folderName: folderName);
    if (book.audioFiles.isEmpty) throw Exception('目录没有可播放的音频文件');
    final author = book.narrator.isEmpty
        ? (book.author.isNotEmpty ? book.author : fallbackAuthor)
        : '${book.author} / ${book.narrator}';
    final info = CatalogInfo(
      title: book.title,
      cover: book.cover.isNotEmpty ? book.cover : fallbackCover,
      author: author,
      trackCount: book.audioFiles.length,
      isFinished: true,
    );
    final chapters = <Chapter>[
      for (var i = 0; i < book.audioFiles.length; i++)
        Chapter(
          chapterId: chapterIdFor(book.audioFiles[i]),
          index: i + 1,
          name: book.audioFiles[i].name,
        ),
    ];
    await CatalogCacheService.instance.savePage(
      sourceId: sourceId,
      bookId: bookCid,
      info: info,
      chapters: chapters,
      page: 1,
      maxPage: 1,
      hasMore: false,
    );
    LogService.instance.info(
      'Pan115',
      '书籍目录已刷新并写入 SQLite',
      detail: '书名: ${info.title}\nCID: $bookCid\n章节数: ${chapters.length}',
    );
    return CachedCatalog(
      info: info,
      chapters: chapters,
      page: 1,
      maxPage: 1,
      hasMore: false,
    );
  }

  Pan115Item? findCoverItem(List<Pan115Item> items) {
    final covers =
        items.where((it) => !it.isDirectory && isCoverFile(it.name)).toList()
          ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return covers.isEmpty ? null : covers.first;
  }

  Future<String> resolveBookCover(
    List<Pan115Item> topItems,
    List<Pan115Item> audios, {
    required String bookCid,
  }) async {
    final coverItem = findCoverItem(topItems);
    if (coverItem != null) {
      try {
        return await cacheCover(coverItem);
      } catch (e) {
        LogService.instance.warning(
          'Pan115',
          '封面缓存失败，继续使用远程缩略图',
          detail: '书籍 CID: $bookCid\n封面: ${coverItem.name}\n错误: $e',
        );
        if (coverItem.thumb.isNotEmpty) return coverItem.thumb;
      }
    }
    for (final a in audios) {
      if (a.thumb.isNotEmpty) return a.thumb;
    }
    return '';
  }

  Future<String> cacheCover(Pan115Item coverItem) async {
    final ext = path_util.extension(coverItem.name).toLowerCase();
    final safeExt = ext.isEmpty ? '.jpg' : (ext.length > 6 ? '.jpg' : ext);
    final key = base64Url
        .encode(
            utf8.encode(coverItem.fid.isEmpty ? coverItem.name : coverItem.fid))
        .replaceAll(RegExp(r'=+$'), '');
    final dir = Directory(
      path_util.join((await getApplicationCacheDirectory()).path, 'covers'),
    );
    if (!await dir.exists()) await dir.create(recursive: true);
    final file = File(path_util.join(dir.path, 'pan115_$key$safeExt'));
    if (await file.exists() && await file.length() > 0) return file.path;

    var url = coverItem.thumb.trim();
    var headers = _headers();
    if (url.isEmpty) {
      final audio = await _resolveDownload(
        chapterToken(coverItem),
        playHeaders: false,
      );
      url = audio.url;
      headers = audio.headers;
    }
    if (url.startsWith('//')) url = 'https:$url';
    if (url.isEmpty) throw Exception('封面缩略图地址为空');
    await _dio.download(
      url,
      file.path,
      options: Options(
        headers: headers,
        receiveTimeout: const Duration(seconds: 30),
      ),
    );
    if (await file.length() <= 0) {
      await file.delete();
      throw Exception('封面下载文件大小为 0');
    }
    LogService.instance.info(
      'Pan115',
      '封面已缓存到本地',
      detail: '文件: ${coverItem.name}\n路径: ${file.path}',
    );
    return file.path;
  }

  /// 解析指定 token (pick_code 或 id:&lt;fid&gt;) 的直链音频。
  Future<Pan115Audio> resolveAudio(
    String token, {
    int headerVariant = 0,
  }) async {
    return _resolveDownload(
      token,
      playHeaders: true,
      headerVariant: headerVariant,
    );
  }

  Future<Pan115Audio> _resolveDownload(
    String token, {
    required bool playHeaders,
    int headerVariant = 0,
  }) async {
    if (!ready) throw Exception('请先登录 115 网盘');

    await ensureValidToken();

    LogService.instance.info('Pan115', '请求下载直链', detail: '标识: $token');
    final pickCode = token.startsWith('id:') ? '' : token;
    final fileId = token.startsWith('id:') ? token.substring(3) : '';

    String url = '';

    // 1. 如果有 access_token，使用 115 官方开放平台接口
    if (_accessToken.isNotEmpty) {
      // 优先 /open/ufile/downurl (官方文档要求: POST, form-data / x-www-form-urlencoded, 参数 pick_code)
      if (pickCode.isNotEmpty) {
        try {
          final resp = await _dio.post<String>(
            '$_openApiBase/open/ufile/downurl',
            data: {'pick_code': pickCode},
            options: Options(
              contentType: Headers.formUrlEncodedContentType,
              headers: {
                'Authorization': 'Bearer $_accessToken',
                'User-Agent': _ua,
              },
              responseType: ResponseType.plain,
              validateStatus: (_) => true,
            ),
          );

          if (resp.statusCode == 401) {
            final refreshed = await refreshAccessToken();
            if (refreshed) {
              return await _resolveDownload(
                token,
                playHeaders: playHeaders,
                headerVariant: headerVariant,
              );
            }
          } else if (resp.statusCode == 429) {
            throw PanRateLimitException('115 取直链被限流\n标识: $token');
          } else if ((resp.statusCode ?? 0) < 400 && resp.data != null) {
            final map = _decodeBody(resp.data!);
            url = _findUrl(map);
          }
        } catch (e) {
          if (e is PanRateLimitException) rethrow;
          LogService.instance.warning(
            'Pan115',
            'downurl 接口解析异常，尝试 video/play',
            detail: '$e',
          );
        }
      }

      // 兜底 /open/video/play (针对部分媒体文件与视频文件)
      if (url.isEmpty && pickCode.isNotEmpty) {
        try {
          final resp = await _dio.get<String>(
            '$_openApiBase/open/video/play',
            queryParameters: {'pick_code': pickCode},
            options: Options(
              headers: {
                'Authorization': 'Bearer $_accessToken',
                'User-Agent': _ua,
              },
              responseType: ResponseType.plain,
              validateStatus: (_) => true,
            ),
          );
          if (resp.statusCode == 401) {
            final refreshed = await refreshAccessToken();
            if (refreshed) {
              return await _resolveDownload(
                token,
                playHeaders: playHeaders,
                headerVariant: headerVariant,
              );
            }
          } else if (resp.statusCode == 429) {
            throw PanRateLimitException('115 取直链被限流\n标识: $token');
          } else if ((resp.statusCode ?? 0) < 400 && resp.data != null) {
            final map = _decodeBody(resp.data!);
            url = _findUrl(map);
          }
        } catch (e) {
          if (e is PanRateLimitException) rethrow;
          LogService.instance.warning(
            'Pan115',
            'video/play 接口解析异常',
            detail: '$e',
          );
        }
      }
    }

    // 2. 如果官方接口未成功或使用 Cookie，尝试 Web 端 download 接口 (302 重定向拿直链)
    if (url.isEmpty && _cookie.isNotEmpty) {
      final query = <String, dynamic>{
        if (pickCode.isNotEmpty) 'pickcode': pickCode,
        if (fileId.isNotEmpty) 'file_id': fileId,
        'dl': 0,
      };
      final resp = await _dio.get<List<int>>(
        'https://webapi.115.com/files/download',
        queryParameters: query,
        options: Options(
          headers: _headers(),
          responseType: ResponseType.bytes,
          followRedirects: false,
          validateStatus: (_) => true,
        ),
      );
      if (resp.statusCode == 429) {
        throw PanRateLimitException('115 取直链被限流\n标识: $token');
      }
      url = _downloadUrlFrom(resp);
    }

    if (url.isEmpty) {
      throw Exception('115 取直链失败，未获取到有效播放地址\n标识: $token');
    }

    LogService.instance.info('Pan115', '取直链完成', detail: '标识: $token\nURL: $url');

    final credential = _accessToken.isNotEmpty ? _accessToken : _cookie;
    final headers = playHeaders
        ? headerVariantHeaders(playHeadersFor(credential), headerVariant)
        : _headers();

    return Pan115Audio(url, headers);
  }

  String _downloadUrlFrom(Response<List<int>> resp) {
    final location = resp.headers.value('location') ?? '';
    if (location.startsWith('http')) return location;
    if (location.startsWith('//')) return 'https:$location';
    final body = resp.data;
    if (body == null || body.isEmpty) return '';
    try {
      final text = utf8.decode(body, allowMalformed: true);
      final map = jsonDecode(text);
      return _findUrl(map);
    } catch (_) {
      return '';
    }
  }

  String _findUrl(Object? value) {
    if (value is Map) {
      for (final key in const [
        'url',
        'durl',
        'download_url',
        'file_url',
        'location',
        'play_url',
      ]) {
        final raw = value[key];
        if (raw is String && raw.startsWith('http')) return raw;
      }
      for (final entry in value.entries) {
        final found = _findUrl(entry.value);
        if (found.isNotEmpty) return found;
      }
    } else if (value is List) {
      for (final item in value) {
        final found = _findUrl(item);
        if (found.isNotEmpty) return found;
      }
    }
    return '';
  }

  Map<String, String> _headers() => {
        'User-Agent': _ua,
        if (_cookie.isNotEmpty) 'Cookie': _cookie,
        if (_accessToken.isNotEmpty) 'Authorization': 'Bearer $_accessToken',
        'Referer': '$_webBase/',
        'Accept': 'application/json, text/plain, */*',
      };

  Map<String, dynamic> _decodeBody(String body) {
    try {
      return jsonDecode(body) as Map<String, dynamic>;
    } catch (_) {
      throw Exception(
        '115 接口返回非 JSON: ${body.length > 200 ? body.substring(0, 200) : body}',
      );
    }
  }

  void _ensureOk(Map<String, dynamic> data) {
    final state = data['state'];
    final code = data['code'];
    final errno = data['errno'];
    if (state == true || state == 1 || code == 0 || (state == null && errno == null && code == null)) {
      return;
    }
    final message = '${data['error'] ?? data['message'] ?? data['msg'] ?? ''}';
    if (errno == 40101017 ||
        errno == 990009 ||
        code == 401 ||
        message.contains('登录') ||
        message.contains('token')) {
      throw Exception('115 登录状态失效，请重新登录');
    }
    throw Exception('115 网盘返回错误 errno=${errno ?? code ?? ''} $message');
  }
}
