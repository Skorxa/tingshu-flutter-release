import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path_util;
import 'package:path_provider/path_provider.dart';

import '../source/models.dart';
import 'catalog_cache_service.dart';
import 'log_service.dart';
import 'pan_rate_limit.dart';
import 'secure_store.dart';

/// 阿里云盘条目。
class AliyunPanItem {
  final String fileId;
  final String name;
  final String thumb;
  final String category;
  final bool isDirectory;
  final int size;

  const AliyunPanItem({
    required this.fileId,
    required this.name,
    this.thumb = '',
    this.category = '',
    this.isDirectory = false,
    this.size = 0,
  });
}

/// 一页目录(marker 游标式分页,没有页码概念)。
class AliyunPanPage {
  final List<AliyunPanItem> items;
  final String nextMarker;
  final int pageSize;
  final bool hasMore;
  final int total;

  const AliyunPanPage({
    required this.items,
    required this.nextMarker,
    required this.pageSize,
    required this.hasMore,
    required this.total,
  });
}

class AliyunAudio {
  final String url;
  final Map<String, String> headers;

  const AliyunAudio(this.url, this.headers);
}

class AliyunBookMeta {
  final String title;
  final String author;
  final String narrator;

  const AliyunBookMeta({
    required this.title,
    required this.author,
    required this.narrator,
  });
}

class AliyunBook {
  final String title;
  final String author;
  final String narrator;
  final String cover;
  final String fileId;
  final List<AliyunPanItem> audioFiles;

  const AliyunBook({
    required this.title,
    required this.author,
    required this.narrator,
    required this.cover,
    required this.fileId,
    required this.audioFiles,
  });
}

/// 阿里云盘后端:登录态由页面经 MethodChannel `tingshu/source_login` 的原生 WebView
/// 抓 `localStorage.token` 后注入(也支持用户手动粘贴),服务层只负责用
/// access_token 调 OpenAPI 列目录、取直链播放 —— 本文件里没有任何 WebView 代码。
///
/// 注意语义:`ready` 只表示"有登录态";要真正浏览目录还必须有 [driveId]
/// (来自登录态的 `default_drive_id`),页面据此决定是浏览还是提示重新登录。
///
/// ── 使用的接口面(细节都集中在下面的常量里,便于按抓包核对) ──
/// 1. 列目录  POST  {_apiBase}/adrive/v3/file/list
///    body: { drive_id, parent_file_id(根为 'root'), limit, marker,
///            order_by:'name', order_direction:'ASC', fields:'*' }
///    返回: { items:[{ file_id, name, type, size, thumbnail, category, ... }], next_marker }
///    - `type == 'folder'` 视为目录;`next_marker` 非空即还有下一页。
/// 2. 取直链  POST  {_apiBase}/adrive/v3/file/get_download_url
///    body: { drive_id, file_id, expire_sec:900 } → { url, expiration }
/// 3. 刷新令牌 POST {_apiBase}/token/refresh
///    body: { client_id, client_secret, grant_type:'refresh_token', refresh_token }
///    → { access_token, refresh_token, expires_in }
///    - **只有用户自己填了 client_id + client_secret 才会尝试刷新**;这两个值
///      绝不硬编码在代码里(用户没填且 access_token 过期时直接提示重新登录)。
/// 4. 播放请求头: `Authorization: Bearer <access_token>` +
///    `Referer: https://www.alipan.com/` + PC UA。
///
/// ⚠️ 待抓包核对(本机无法联网核对,下列点按阿里云盘 OpenAPI 的公开形态编写):
/// - `/adrive/v3/file/list` 与 `/adrive/v3/file/get_download_url` 的版本段与路径
///   拼写(v3 vs v1.0/openFile/getDownloadUrl 等历史形态);
/// - 列表接口是否接受 `fields:'*'`,以及游标字段是否就叫 `next_marker`;
/// - 列表接口是否返回 `total`(当前:返回就顺手用上,不返回则 total=0,UI 显示"未知");
/// - 取直链响应里是否就是 `url` / `expiration`,以及该直链是否仍需带 Authorization;
/// - `/token/refresh` 是否必须带 client_secret,以及响应里 `expires_in` 的字段名;
/// - localStorage 的 `token` 键内容形态(JSON 对象 / 是否被 URL 编码 / 是否二次编码);
/// - 列表里的 `thumbnail` 是否需要带 Authorization 才能下载(当前先按"不需要"处理,
///   失败时回落用 file_id 换取带签名的直链)。
class AliyunPanService extends ChangeNotifier {
  AliyunPanService._();
  static final instance = AliyunPanService._();

  static const _kConfig = 'aliyun_pan_config';
  // 配置(含 access_token/refresh_token/client_secret)的加密存储键;
  // 明文旧键由 SecureStore 迁移后删除。
  static const _kConfigSecure = 'sec.aliyun_pan_config';

  /// 书库标识(写入 catalog_books.sourceId 与章节 chapterId 前缀)。
  static const sourceId = 'aliyun';
  static const chapterPrefix = 'aliyun:';

  /// 根目录的 parent_file_id 固定为 `root`。
  static const rootFileId = 'root';

  /// WebView 登录页与要抓的 localStorage 键(阿里云盘把登录态存在 `token` 里)。
  static const loginUrl = 'https://www.alipan.com/';
  static const loginStorageKey = 'token';

  static const _apiBase = 'https://openapi.alipan.com';
  static const _listPath = '/adrive/v3/file/list';
  static const _downloadPath = '/adrive/v3/file/get_download_url';
  static const _refreshPath = '/token/refresh';
  static const _webBase = 'https://www.alipan.com/';

  static const _defaultPageSize = 100;
  static const _maxAutoPages = 300;

  /// 过期判断留的余量:剩余不足 60 秒即视为过期,先刷新再请求。
  static const _expireMarginMs = 60 * 1000;
  static const _downloadExpireSec = 900;
  static const _collectMaxDepth = 3;

  static const _pcUa =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/121.0.0.0 Safari/537.36';

  /// 登录 WebView 用的 PC UA(阿里云盘网页版按桌面 UA 呈现,便于登录并写 localStorage)。
  static const pcUserAgent = _pcUa;

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

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
      sendTimeout: const Duration(seconds: 30),
    ),
  );
  final Random _random = Random();

  String _accessToken = '';
  String _refreshToken = '';
  String _driveId = '';
  int _expireTimeMs = 0;
  String _clientId = '';
  String _clientSecret = '';

  /// 刷新令牌单飞:并发调用共享同一个 Future,避免重复刷新互相顶掉 refresh_token。
  Future<void>? _refreshInFlight;

  String get driveId => _driveId;
  bool get ready => _accessToken.isNotEmpty;

  /// 是否真的可用:有令牌还不够——列目录与取直链都要求 drive_id。
  /// 页面用 [ready] 判断"已登录"以便展示修复入口,真正发请求的调用方(书架续播、
  /// 追更检查)应该用这个,避免"显示已登录但每个请求必失败"。
  bool get usable => ready && _driveId.isNotEmpty;
  bool get hasRefreshToken => _refreshToken.isNotEmpty;
  bool get hasClientCredentials =>
      _clientId.isNotEmpty && _clientSecret.isNotEmpty;

  // ── 配置读写 ──

  Future<void> init() async {
    final raw = await SecureStore.instance.readMigrated(
      _kConfig,
      _kConfigSecure,
    );
    if (raw == null || raw.isEmpty) return;
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      _accessToken = '${map['access_token'] ?? ''}';
      _refreshToken = '${map['refresh_token'] ?? ''}';
      _driveId = '${map['drive_id'] ?? ''}';
      _expireTimeMs = _asInt(map['expire_time']);
      _clientId = '${map['client_id'] ?? ''}';
      _clientSecret = '${map['client_secret'] ?? ''}';
      LogService.instance.info(
        'AliyunPan',
        '已读取阿里云盘配置',
        detail:
            'Token: ${tokenSummary(_accessToken)}\n'
            'RefreshToken: ${tokenSummary(_refreshToken)}\n'
            'DriveID: ${_driveId.isEmpty ? '(缺失)' : '已设置'}\n'
            '过期时间: ${_expireTimeMs > 0 ? DateTime.fromMillisecondsSinceEpoch(_expireTimeMs).toString() : '未知'}\n'
            'ClientID: ${_clientId.isEmpty ? '(未填)' : '已填'}\n'
            'ClientSecret: ${_clientSecret.isEmpty ? '(未填)' : '已填'}',
      );
    } catch (e) {
      LogService.instance.warning('AliyunPan', '读取配置失败', detail: '$e');
    }
  }

  Future<void> _persist() async {
    await SecureStore.instance.write(
      _kConfigSecure,
      jsonEncode({
        'access_token': _accessToken,
        'refresh_token': _refreshToken,
        'drive_id': _driveId,
        'expire_time': _expireTimeMs,
        'client_id': _clientId,
        'client_secret': _clientSecret,
      }),
    );
  }

  /// 保存登录态。空值字段按"本次没抓到,保留旧值"处理,避免一次抓取不全就把
  /// refresh_token / drive_id 抹掉;过期时间 0 表示未知(交给 401 兜底刷新)。
  Future<void> saveLogin({
    required String accessToken,
    required String refreshToken,
    required String driveId,
    int expireTimeMs = 0,
    String clientId = '',
    String clientSecret = '',
  }) async {
    final token = accessToken.trim();
    if (token.isEmpty) throw Exception('登录态里没有 access_token，请重新登录');
    _accessToken = token;
    if (refreshToken.trim().isNotEmpty) _refreshToken = refreshToken.trim();
    if (driveId.trim().isNotEmpty) _driveId = driveId.trim();
    _expireTimeMs = expireTimeMs > 0 ? expireTimeMs : 0;
    if (clientId.trim().isNotEmpty) _clientId = clientId.trim();
    if (clientSecret.trim().isNotEmpty) _clientSecret = clientSecret.trim();
    await _persist();
    LogService.instance.info(
      'AliyunPan',
      '已保存登录态',
      detail:
          'Token: ${tokenSummary(_accessToken)}\n'
          'RefreshToken: ${tokenSummary(_refreshToken)}\n'
          'DriveID: ${_driveId.isEmpty ? '(缺失)' : '已设置'}\n'
          '过期时间: ${_expireTimeMs > 0 ? DateTime.fromMillisecondsSinceEpoch(_expireTimeMs).toString() : '未知'}\n'
          'ClientID: ${_clientId.isEmpty ? '(未填)' : '已填'}\n'
          'ClientSecret: ${_clientSecret.isEmpty ? '(未填)' : '已填'}',
    );
    notifyListeners();
  }

  /// 保存应用凭据(用户自己在阿里云盘开放平台申请的 client_id/client_secret)。
  /// 传空串即清空,清空后过期就只能重新登录。
  Future<void> saveClientCredentials({
    required String clientId,
    required String clientSecret,
  }) async {
    _clientId = clientId.trim();
    _clientSecret = clientSecret.trim();
    await _persist();
    LogService.instance.info(
      'AliyunPan',
      '已保存应用凭据',
      detail:
          'ClientID: ${_clientId.isEmpty ? '(已清空)' : '长度 ${_clientId.length}'}\n'
          'ClientSecret: ${_clientSecret.isEmpty ? '(已清空)' : '长度 ${_clientSecret.length}'}',
    );
    notifyListeners();
  }

  /// 退出登录:清 token/drive_id,保留用户自己填的 client_id/secret
  /// (那是应用凭据,与账号无关,重新登录后还要用)。
  Future<void> logout() async {
    _accessToken = '';
    _refreshToken = '';
    _driveId = '';
    _expireTimeMs = 0;
    await _persist();
    LogService.instance.info('AliyunPan', '已退出阿里云盘登录(保留应用凭据)');
    notifyListeners();
  }

  // ── 纯静态部分(可单测,不依赖网络/实例状态) ──

  static bool isAudioName(String name) {
    final lower = name.toLowerCase();
    return audioExtensions.any(lower.endsWith);
  }

  static bool isCoverName(String name) {
    final lower = name.toLowerCase();
    return lower.startsWith('cover') && _coverExtensions.any(lower.endsWith);
  }

  /// 文件夹名 `书名_作者_演播者` → 元数据;不足三段返回 null(由调用方回落目录名)。
  static AliyunBookMeta? parseFolderName(String name) {
    final parts = name
        .split(RegExp(r'_+'))
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty)
        .toList(growable: false);
    if (parts.length < 3) return null;
    return AliyunBookMeta(
      title: parts.first,
      author: parts[1],
      narrator: parts.sublist(2).join('_'),
    );
  }

  /// 列表接口条目 → 领域对象。字段名按抓包核对(见类注释)。
  static AliyunPanItem itemFromJson(Map<String, dynamic> json) {
    final rawType = '${json['type'] ?? json['file_type'] ?? ''}'.toLowerCase();
    final dirValue = json['is_dir'] ?? json['isDir'] ?? json['dir'];
    final isDir =
        rawType == 'folder' ||
        rawType == 'dir' ||
        dirValue == true ||
        dirValue == 1 ||
        dirValue == '1';
    return AliyunPanItem(
      fileId: '${json['file_id'] ?? json['fileId'] ?? json['id'] ?? ''}',
      name: '${json['name'] ?? json['file_name'] ?? ''}',
      thumb: '${json['thumbnail'] ?? json['thumb'] ?? json['thumb_url'] ?? ''}',
      category: '${json['category'] ?? ''}',
      isDirectory: isDir,
      size: _asInt(json['size']),
    );
  }

  static String chapterIdFor(AliyunPanItem item) =>
      '$chapterPrefix${item.fileId}';

  /// 播放/下载用的请求头。阿里云盘直链对 Referer 敏感,Authorization 带上更稳。
  static Map<String, String> playHeadersFor(String accessToken) => {
    'Authorization': 'Bearer $accessToken',
    'Referer': _webBase,
    'User-Agent': _pcUa,
  };

  /// 直链反盗链的请求头降级变体:0=完整 1=去鉴权/跨域头 2=仅 UA。
  ///
  /// 与夸克不同,阿里云盘的播放头本来就没有 Cookie/Origin(见 [playHeadersFor]),
  /// 所以变体 1 额外去掉 `Authorization`:直链是带签名的自包含地址,鉴权头常被 CDN
  /// 判成异常请求,去掉它才是有意义的降级。服务端规则无法核对(见类注释),
  /// 调用方按 0→1→2 逐级重试。
  static Map<String, String> headerVariantHeaders(
    Map<String, String> headers,
    int variant,
  ) {
    if (variant <= 0) return headers;
    final out = {...headers}
      ..remove('Cookie')
      ..remove('Origin')
      ..remove('Authorization');
    if (variant >= 2) {
      final ua = out['User-Agent'];
      return ua == null ? const <String, String>{} : {'User-Agent': ua};
    }
    return out;
  }

  /// 凭据摘要:只暴露长度与结构,绝不输出 token 原文。
  static String tokenSummary(String token) {
    if (token.isEmpty) return '(无)';
    final segments = token.split('.').length;
    return '长度 ${token.length} / 段数 $segments';
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

  static int compareItems(AliyunPanItem a, AliyunPanItem b) {
    if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
    return naturalCompare(a.name, b.name);
  }

  /// localStorage 的 `token` 值 → 规范化字段。
  ///
  /// 阿里云盘 Web 端把登录态以 JSON 字符串存在 localStorage.token 里,形如
  /// `{"access_token":"...","refresh_token":"...","default_drive_id":"...","expires_in":7200,...}`。
  /// 这里兼容三种常见形态:纯 JSON 对象、被 URL 编码过的 JSON、被二次 JSON 编码的字符串。
  /// 解析失败抛清晰异常,调用方直接把 message 弹给用户。
  static Map<String, dynamic> parseWebLoginToken(String raw) {
    final text = raw.trim();
    if (text.isEmpty) {
      throw Exception('登录态为空：请先在网页里完成阿里云盘登录再点「完成」');
    }
    var map = _decodeTokenMap(text);
    if (map == null) {
      // 有的复制来源会把整串做一次 URL 编码(%7B%22…),这里再试一次解码。
      try {
        map = _decodeTokenMap(Uri.decodeComponent(text));
      } catch (_) {
        map = null;
      }
    }
    if (map == null) {
      throw Exception(
        '登录态不是合法的 JSON：${text.length > 120 ? text.substring(0, 120) : text}',
      );
    }
    final accessToken = '${map['access_token'] ?? map['accessToken'] ?? ''}'
        .trim();
    if (accessToken.isEmpty) {
      throw Exception('登录态里没有 access_token：可能抓到的不是 token 键，或网页尚未登录完成（待抓包核对）');
    }
    final driveId =
        '${map['default_drive_id'] ?? map['drive_id'] ?? map['defaultDriveId'] ?? ''}'
            .trim();
    return {
      'access_token': accessToken,
      'refresh_token': '${map['refresh_token'] ?? map['refreshToken'] ?? ''}'
          .trim(),
      'default_drive_id': driveId,
      // 别名:saveLogin 的形参叫 driveId,两个键都给,免得桥接处记混。
      'drive_id': driveId,
      'expire_time': _expireTimeMsFrom(map),
      'token_type': '${map['token_type'] ?? ''}',
      'user_name': '${map['user_name'] ?? map['nick_name'] ?? ''}',
    };
  }

  /// 解析 `expire_time`(ISO8601 字符串 / 秒或毫秒时间戳)或 `expires_in`(秒)
  /// 为毫秒时间戳;都拿不到时返回 0(表示未知,交给 401 兜底)。
  static int _expireTimeMsFrom(Map<String, dynamic> map) {
    final raw = map['expire_time'] ?? map['expireTime'];
    if (raw is num) {
      final value = raw.toInt();
      return value > 100000000000 ? value : value * 1000;
    }
    if (raw is String && raw.trim().isNotEmpty) {
      final trimmed = raw.trim();
      final numeric = int.tryParse(trimmed);
      if (numeric != null) {
        return numeric > 100000000000 ? numeric : numeric * 1000;
      }
      final parsed = DateTime.tryParse(trimmed);
      if (parsed != null) return parsed.toUtc().millisecondsSinceEpoch;
    }
    final expiresIn = _asInt(map['expires_in'] ?? map['expiresIn']);
    if (expiresIn > 0) {
      return DateTime.now().millisecondsSinceEpoch + expiresIn * 1000;
    }
    return 0;
  }

  static Map<String, dynamic>? _decodeTokenMap(String text) {
    if (text.isEmpty) return null;
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
      if (decoded is String) {
        // 二次编码:JSON 字符串里再套一层 JSON。
        final inner = jsonDecode(decoded);
        if (inner is Map) return Map<String, dynamic>.from(inner);
      }
    } catch (_) {
      return null;
    }
    return null;
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

  /// 日志里只记 host + path:阿里云盘直链的 query 里带签名,不能整条打进日志。
  static String _urlSummary(String url) {
    if (url.isEmpty) return '(空)';
    final uri = Uri.tryParse(url);
    if (uri == null) return '(无法解析)';
    final query = uri.query.isEmpty ? '' : '?<签名参数已省略>';
    return '${uri.scheme}://${uri.host}${uri.path}$query';
  }

  // ── 网络部分 ──

  Future<bool> checkLogin() async {
    if (_accessToken.isEmpty) return false;
    if (_driveId.isEmpty) {
      LogService.instance.warning(
        'AliyunPan',
        '缺少 drive_id，无法检测登录状态',
        detail: '登录态里应带 default_drive_id，请重新登录抓取（待抓包核对）',
      );
      return false;
    }
    try {
      await listPage(rootFileId, limit: 1);
      LogService.instance.info('AliyunPan', '登录状态检测通过');
      return true;
    } catch (e) {
      LogService.instance.warning('AliyunPan', '登录状态检测失败', detail: '$e');
      return false;
    }
  }

  Future<List<AliyunPanItem>> list(String parentFileId) async {
    final all = <AliyunPanItem>[];
    var marker = '';
    var page = 0;
    var hasMore = true;
    while (hasMore && page < _maxAutoPages) {
      AliyunPanPage result;
      try {
        result = await listPage(parentFileId, marker: marker);
      } on PanRateLimitException catch (e) {
        if (page == 0) rethrow; // 首页被限流,多半整体被限,直接上抛
        final wait = panBackoffDelayMs(_random);
        LogService.instance.warning(
          'AliyunPan',
          '触发网盘限流，退避后重试',
          detail:
              'ParentFileID: $parentFileId\n页码: ${page + 1}\n等待: ${wait}ms\n${e.detail}',
        );
        await Future<void>.delayed(Duration(milliseconds: wait));
        result = await listPage(parentFileId, marker: marker);
      }
      all.addAll(result.items);
      marker = result.nextMarker;
      hasMore = result.hasMore;
      page++;
      LogService.instance.info(
        'AliyunPan',
        '目录分页读取',
        detail:
            'ParentFileID: $parentFileId\n页码: $page\n本页: ${result.items.length}\n累计: ${all.length}\n总数: ${result.total > 0 ? result.total : '未知'}\n继续: ${result.hasMore ? '是' : '否'}',
      );
      if (hasMore) {
        // 页间随机抖动,避免固定节奏被网盘风控识别
        await Future<void>.delayed(
          Duration(milliseconds: 250 + _random.nextInt(400)),
        );
      }
    }
    if (hasMore) {
      LogService.instance.warning(
        'AliyunPan',
        '目录页数超过保护上限，已停止继续读取',
        detail:
            'ParentFileID: $parentFileId\n已读取页数: $_maxAutoPages\n累计条目: ${all.length}',
      );
    }
    all.sort(compareItems);
    LogService.instance.info(
      'AliyunPan',
      '列目录完成',
      detail: 'ParentFileID: $parentFileId\n条目: ${all.length}\n页数: $page',
    );
    return all;
  }

  Future<AliyunPanPage> listPage(
    String parentFileId, {
    String marker = '',
    int limit = 100,
  }) async {
    if (_accessToken.isEmpty) throw Exception('请先登录阿里云盘');
    if (_driveId.isEmpty) {
      throw Exception('缺少 drive_id：请重新登录以抓取 default_drive_id');
    }
    final pageSize = limit <= 0 ? _defaultPageSize : limit;
    LogService.instance.info(
      'AliyunPan',
      '请求目录页',
      detail:
          'ParentFileID: $parentFileId\n游标: ${marker.isEmpty ? '(首页)' : '已续传'}\n每页: $pageSize',
    );
    final resp = await _postJson(_listPath, {
      'drive_id': _driveId,
      'parent_file_id': parentFileId,
      'limit': pageSize,
      // 首页不带 marker:空串游标在部分接口上会被当成非法值(待抓包核对)。
      if (marker.isNotEmpty) 'marker': marker,
      'order_by': 'name',
      'order_direction': 'ASC',
      'fields': '*',
    }, context: 'ParentFileID: $parentFileId');
    _ensureHttpOk(
      resp.statusCode,
      _listPath,
      extra: 'ParentFileID: $parentFileId',
    );
    final data = _decodeBody(resp.data ?? '{}');
    _ensureOk(data, _listPath);
    final rawList = data['items'];
    final items = <AliyunPanItem>[];
    if (rawList is List) {
      for (final entry in rawList) {
        if (entry is! Map) continue;
        final item = itemFromJson(Map<String, dynamic>.from(entry));
        if (item.fileId.isEmpty) continue;
        items.add(item);
      }
    }
    items.sort(compareItems);
    final nextMarker = '${data['next_marker'] ?? ''}'.trim();
    return AliyunPanPage(
      items: items,
      nextMarker: nextMarker,
      pageSize: pageSize,
      hasMore: nextMarker.isNotEmpty && items.isNotEmpty,
      // 列表接口按"不返回 total"处理;真返回了就顺手用上(待抓包核对)。
      total: _asInt(data['total']),
    );
  }

  Future<List<AliyunPanItem>> collectAudioFiles(String parentFileId) async {
    final out = <AliyunPanItem>[];
    await _collect(parentFileId, out, 0);
    return out;
  }

  Future<void> _collect(
    String parentFileId,
    List<AliyunPanItem> out,
    int depth,
  ) async {
    if (depth > _collectMaxDepth) return;
    final items = await list(parentFileId);
    final audios =
        items.where((e) => !e.isDirectory && isAudioName(e.name)).toList()
          ..sort((a, b) => naturalCompare(a.name, b.name));
    out.addAll(audios);
    final subs = items.where((e) => e.isDirectory).toList()
      ..sort((a, b) => naturalCompare(a.name, b.name));
    for (final sub in subs) {
      // 子目录间隔随机抖动,避免连续打接口被风控
      await Future<void>.delayed(
        Duration(milliseconds: 300 + _random.nextInt(500)),
      );
      await _collect(sub.fileId, out, depth + 1);
    }
  }

  Future<AliyunBook> toBook(String fileId, {required String folderName}) async {
    final meta = parseFolderName(folderName);
    final topItems = await list(fileId);
    final audios = await collectAudioFiles(fileId);
    final cover = await resolveBookCover(topItems, audios, bookFileId: fileId);
    return AliyunBook(
      title: meta?.title ?? folderName,
      author: meta?.author ?? '',
      narrator: meta?.narrator ?? '',
      cover: cover,
      fileId: fileId,
      audioFiles: audios,
    );
  }

  Future<CachedCatalog> refreshCatalog({
    required String bookFileId,
    required String folderName,
    String fallbackCover = '',
    String fallbackAuthor = '',
  }) async {
    final book = await toBook(bookFileId, folderName: folderName);
    if (book.audioFiles.isEmpty) throw Exception('目录没有可播放的音频文件');
    final author = book.narrator.isEmpty
        ? book.author
        : '${book.author} / ${book.narrator}';
    final info = CatalogInfo(
      title: book.title,
      cover: book.cover.isNotEmpty ? book.cover : fallbackCover,
      author: author.isNotEmpty ? author : fallbackAuthor,
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
      bookId: bookFileId,
      info: info,
      chapters: chapters,
      page: 1,
      maxPage: 1,
      hasMore: false,
    );
    LogService.instance.info(
      'AliyunPan',
      '书籍目录已刷新并写入 SQLite',
      detail: '书名: ${info.title}\nFileID: $bookFileId\n章节数: ${chapters.length}',
    );
    return CachedCatalog(
      info: info,
      chapters: chapters,
      page: 1,
      maxPage: 1,
      hasMore: false,
    );
  }

  AliyunPanItem? findCoverItem(List<AliyunPanItem> items) {
    final covers =
        items.where((it) => !it.isDirectory && isCoverName(it.name)).toList()
          ..sort(
            (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
          );
    return covers.isEmpty ? null : covers.first;
  }

  Future<String> resolveBookCover(
    List<AliyunPanItem> topItems,
    List<AliyunPanItem> audios, {
    required String bookFileId,
  }) async {
    final coverItem = findCoverItem(topItems);
    if (coverItem != null) {
      try {
        return await cacheCover(coverItem);
      } catch (e) {
        LogService.instance.warning(
          'AliyunPan',
          '封面缓存失败，继续使用远程缩略图',
          detail: '书籍 FileID: $bookFileId\n封面: ${coverItem.name}\n错误: $e',
        );
        if (coverItem.thumb.isNotEmpty) return coverItem.thumb;
      }
    }
    for (final a in audios) {
      if (a.thumb.isNotEmpty) return a.thumb;
    }
    return '';
  }

  Future<String> cacheCover(AliyunPanItem coverItem) async {
    final ext = path_util.extension(coverItem.name).toLowerCase();
    final safeExt = ext.isEmpty ? '.jpg' : (ext.length > 6 ? '.jpg' : ext);
    final key = base64Url
        .encode(
          utf8.encode(
            coverItem.fileId.isEmpty ? coverItem.name : coverItem.fileId,
          ),
        )
        .replaceAll(RegExp(r'=+$'), '');
    final dir = Directory(
      path_util.join((await getApplicationCacheDirectory()).path, 'covers'),
    );
    if (!await dir.exists()) await dir.create(recursive: true);
    final file = File(path_util.join(dir.path, 'aliyun_$key$safeExt'));
    if (await file.exists() && await file.length() > 0) return file.path;

    var url = coverItem.thumb.trim();
    if (url.startsWith('//')) url = 'https:$url';
    if (url.isNotEmpty) {
      try {
        await _downloadTo(url, file.path, _coverHeaders());
      } catch (e) {
        // 缩略图 URL 可能也要求带 Authorization,或干脆是过期签名:改用直链再试一次。
        if (coverItem.fileId.isEmpty) rethrow;
        LogService.instance.warning(
          'AliyunPan',
          '缩略图下载失败，改用直链重试',
          detail: '封面: ${coverItem.name}\n缩略图: ${_urlSummary(url)}\n错误: $e',
        );
        url = '';
      }
    }
    if (url.isEmpty) {
      final audio = await _resolveDownload(
        coverItem.fileId,
        playHeaders: false,
      );
      url = audio.url;
      if (url.isEmpty) throw Exception('封面直链地址为空');
      await _downloadTo(url, file.path, audio.headers);
    }
    if (await file.length() <= 0) {
      await file.delete();
      throw Exception('封面下载文件大小为 0');
    }
    LogService.instance.info(
      'AliyunPan',
      '封面已缓存到本地',
      detail: '文件: ${coverItem.name}\n路径: ${file.path}',
    );
    return file.path;
  }

  Future<void> _downloadTo(
    String url,
    String savePath,
    Map<String, String> headers,
  ) async {
    await _dio.download(
      url,
      savePath,
      options: Options(
        headers: headers.isEmpty ? null : headers,
        receiveTimeout: const Duration(seconds: 30),
      ),
    );
  }

  Future<AliyunAudio> resolveAudio(
    String fileId, {
    int headerVariant = 0,
  }) async {
    return _resolveDownload(
      fileId,
      playHeaders: true,
      headerVariant: headerVariant,
    );
  }

  Future<AliyunAudio> _resolveDownload(
    String fileId, {
    required bool playHeaders,
    int headerVariant = 0,
  }) async {
    if (_accessToken.isEmpty) throw Exception('请先登录阿里云盘');
    LogService.instance.info('AliyunPan', '请求下载直链', detail: 'FileID: $fileId');
    final resp = await _postJson(_downloadPath, {
      'drive_id': _driveId,
      'file_id': fileId,
      'expire_sec': _downloadExpireSec,
    }, context: 'FileID: $fileId');
    _ensureHttpOk(resp.statusCode, _downloadPath, extra: 'FileID: $fileId');
    final data = _decodeBody(resp.data ?? '{}');
    _ensureOk(data, _downloadPath);
    final url = '${data['url'] ?? ''}'.trim();
    if (url.isEmpty) {
      throw Exception('取直链失败：响应缺少 url 字段（待抓包核对）\nFileID: $fileId');
    }
    LogService.instance.info(
      'AliyunPan',
      '取直链完成',
      detail:
          'FileID: $fileId\nURL: ${_urlSummary(url)}\n过期: ${data['expiration'] ?? '未知'}',
    );
    return AliyunAudio(
      url,
      playHeaders
          ? headerVariantHeaders(playHeadersFor(_accessToken), headerVariant)
          : _apiHeaders(),
    );
  }

  // ── 请求封装 ──

  Map<String, String> _apiHeaders() => {
    'Authorization': 'Bearer $_accessToken',
    'Content-Type': 'application/json',
    'User-Agent': _pcUa,
    'Referer': _webBase,
    'Origin': 'https://www.alipan.com',
    'Accept': 'application/json, text/plain, */*',
  };

  /// 封面/缩略图下载头:只带 UA + Referer,不带 Authorization
  /// (缩略图多为 CDN 签名地址,多余的 Authorization 反而可能被拒)。
  Map<String, String> _coverHeaders() => {
    'User-Agent': _pcUa,
    'Referer': _webBase,
  };

  /// 统一的 POST:先做本地过期检查(留 60 秒余量);真拿到 401 且用户填了
  /// 应用凭据 + refresh_token 时,刷新一次再重试。
  Future<Response<String>> _postJson(
    String path,
    Map<String, dynamic> body, {
    String context = '',
  }) async {
    await _ensureFreshToken();
    var resp = await _sendJson(path, body);
    if (resp.statusCode == 401 && hasRefreshToken && hasClientCredentials) {
      LogService.instance.warning(
        'AliyunPan',
        '接口返回 401，刷新令牌后重试',
        detail:
            '路径: $path\n${context.isEmpty ? '' : '$context\n'}Token: ${tokenSummary(_accessToken)}',
      );
      await _refreshTokenOnce();
      resp = await _sendJson(path, body);
    }
    return resp;
  }

  Future<Response<String>> _sendJson(String path, Map<String, dynamic> body) {
    return _dio.post<String>(
      '$_apiBase$path',
      data: jsonEncode(body),
      options: Options(
        headers: _apiHeaders(),
        responseType: ResponseType.plain,
        validateStatus: (_) => true,
      ),
    );
  }

  /// 过期判断:expireTimeMs 与本地时间比,留 60 秒余量;时间未知(0)时不做本地
  /// 判断,交给 401 兜底。
  bool _isExpired() {
    if (_expireTimeMs <= 0) return false;
    return DateTime.now().millisecondsSinceEpoch + _expireMarginMs >=
        _expireTimeMs;
  }

  /// 请求前的令牌保鲜:过期且"有 refresh_token + 用户填了应用凭据"才刷新,
  /// 否则抛「登录已过期，请重新登录」。
  Future<void> _ensureFreshToken() async {
    if (_accessToken.isEmpty) throw Exception('请先登录阿里云盘');
    if (!_isExpired()) return;
    if (!hasRefreshToken || !hasClientCredentials) {
      throw Exception('登录已过期，请重新登录');
    }
    await _refreshTokenOnce();
  }

  /// 刷新令牌单飞:并发调用共享同一个 Future,避免重复刷新互相顶掉 refresh_token。
  Future<void> _refreshTokenOnce() {
    final pending = _refreshInFlight;
    if (pending != null) return pending;
    final future = _performTokenRefresh();
    _refreshInFlight = future;
    return future.whenComplete(() {
      if (identical(_refreshInFlight, future)) _refreshInFlight = null;
    });
  }

  /// 真正打 `/token/refresh` 的地方。方法名不能叫 `_refreshToken`,
  /// 否则与同名的 refresh_token 字段冲突(字段/方法同名是编译错误)。
  Future<void> _performTokenRefresh() async {
    LogService.instance.info(
      'AliyunPan',
      '刷新访问令牌',
      detail:
          'ClientID: ${_clientId.isEmpty ? '(未填)' : '长度 ${_clientId.length}'}\n'
          'RefreshToken: ${tokenSummary(_refreshToken)}',
    );
    final resp = await _dio.post<String>(
      '$_apiBase$_refreshPath',
      data: jsonEncode({
        'client_id': _clientId,
        'client_secret': _clientSecret,
        'grant_type': 'refresh_token',
        'refresh_token': _refreshToken,
      }),
      options: Options(
        headers: {
          'Content-Type': 'application/json',
          'User-Agent': _pcUa,
          'Accept': 'application/json',
        },
        responseType: ResponseType.plain,
        validateStatus: (_) => true,
      ),
    );
    if ((resp.statusCode ?? 0) >= 400) {
      throw Exception(
        '阿里云盘刷新令牌失败 HTTP ${resp.statusCode}：client_id/secret 或 refresh_token 已失效，请重新登录',
      );
    }
    final data = _decodeBody(resp.data ?? '{}');
    final accessToken = '${data['access_token'] ?? ''}'.trim();
    if (accessToken.isEmpty) {
      throw Exception('阿里云盘刷新令牌失败：响应缺少 access_token（待抓包核对）');
    }
    _accessToken = accessToken;
    final newRefresh = '${data['refresh_token'] ?? ''}'.trim();
    if (newRefresh.isNotEmpty) _refreshToken = newRefresh;
    final newDriveId = '${data['default_drive_id'] ?? data['drive_id'] ?? ''}'
        .trim();
    if (newDriveId.isNotEmpty) _driveId = newDriveId;
    final expiresIn = _asInt(data['expires_in']);
    _expireTimeMs = expiresIn > 0
        ? DateTime.now().millisecondsSinceEpoch + expiresIn * 1000
        : 0;
    await _persist();
    LogService.instance.info(
      'AliyunPan',
      '访问令牌已刷新',
      detail:
          'Token: ${tokenSummary(_accessToken)}\n有效期: ${expiresIn > 0 ? '$expiresIn 秒' : '未知'}',
    );
    notifyListeners();
  }

  void _ensureHttpOk(int? status, String path, {String extra = ''}) {
    final code = status ?? 0;
    final suffix = extra.isEmpty ? '' : '\n$extra';
    if (code == 429) {
      throw PanRateLimitException('阿里云盘请求被限流\n路径: $path$suffix');
    }
    if (code == 401 || code == 403) {
      throw Exception('阿里云盘登录已过期或无权访问 HTTP $code\n路径: $path$suffix\n请重新登录');
    }
    if (code >= 400) {
      throw Exception('阿里云盘请求失败 HTTP $code\n路径: $path$suffix');
    }
  }

  Map<String, dynamic> _decodeBody(String body) {
    try {
      return jsonDecode(body) as Map<String, dynamic>;
    } catch (_) {
      throw Exception(
        '阿里云盘接口返回非 JSON: ${body.length > 200 ? body.substring(0, 200) : body}',
      );
    }
  }

  void _ensureOk(Map<String, dynamic> data, String path) {
    final code = '${data['code'] ?? ''}';
    if (code.isEmpty || code == '0' || code == '200' || code == 'ok') return;
    final message = '${data['message'] ?? data['msg'] ?? ''}';
    final lower = '$code $message'.toLowerCase();
    if (lower.contains('token') ||
        lower.contains('expire') ||
        message.contains('登录')) {
      throw Exception('阿里云盘登录已过期，请重新登录\n路径: $path\ncode=$code $message');
    }
    throw Exception('阿里云盘返回错误 code=$code $message\n路径: $path');
  }
}
