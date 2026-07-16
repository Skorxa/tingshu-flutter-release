import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path_util;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'log_service.dart';

/// Alist 账号配置：仅需一个根 URL，token 可选（guest 实例留空）。
class AlistConfig {
  final String id;
  final String name;
  final String baseUrl;
  final String token;
  final String rootPath;

  const AlistConfig({
    this.id = '',
    this.name = '',
    required this.baseUrl,
    required this.token,
    required this.rootPath,
  });

  bool get ready => baseUrl.trim().isNotEmpty;
  String get displayName =>
      name.trim().isNotEmpty ? name.trim() : Uri.tryParse(baseUrl)?.host ?? '';

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'baseUrl': baseUrl,
    'token': token,
    'rootPath': rootPath,
  };

  factory AlistConfig.fromJson(Map<String, dynamic> map) => AlistConfig(
    id: '${map['id'] ?? ''}',
    name: '${map['name'] ?? ''}',
    baseUrl: '${map['baseUrl'] ?? ''}',
    token: '${map['token'] ?? ''}',
    rootPath: '${map['rootPath'] ?? '/'}',
  );
}

class AlistItem {
  final String name;
  final String path;
  final bool isDirectory;
  final int size;
  final String sign;
  final String thumb;

  const AlistItem({
    required this.name,
    required this.path,
    required this.isDirectory,
    this.size = 0,
    this.sign = '',
    this.thumb = '',
  });
}

class AlistBook {
  final String title;
  final String author;
  final String narrator;
  final String cover;
  final String path;
  final List<AlistItem> audioFiles;

  const AlistBook({
    required this.title,
    required this.author,
    required this.narrator,
    required this.cover,
    required this.path,
    required this.audioFiles,
  });
}

/// Alist 后端：REST API（/api/fs/list、/api/fs/get）+ 可选 token。
/// guest 实例无需 token；需要登录的实例首次 401 时弹 WebView 抓 localStorage 的 token。
class AlistService extends ChangeNotifier {
  AlistService._();
  static final instance = AlistService._();

  static const _kAccounts = 'alist_accounts';
  static const _kActiveAccountId = 'alist_active_account_id';
  static const _loginChannel = MethodChannel('tingshu/source_login');
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

  final Dio _dio = Dio();
  final List<AlistConfig> _accounts = [];
  AlistConfig _config = const AlistConfig(
    baseUrl: '',
    token: '',
    rootPath: '/',
  );

  List<AlistConfig> get accounts => List.unmodifiable(_accounts);
  AlistConfig get config => _config;
  String get activeAccountId => _config.id;
  bool get ready => _config.ready;

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kAccounts);
    if (raw == null || raw.isEmpty) return;
    try {
      final rows = jsonDecode(raw) as List;
      _accounts
        ..clear()
        ..addAll(
          rows
              .whereType<Map>()
              .map(
                (row) => _normalizeConfig(
                  AlistConfig.fromJson(Map<String, dynamic>.from(row)),
                ),
              )
              .where((config) => config.ready),
        );
      if (_accounts.isNotEmpty) {
        final activeId = prefs.getString(_kActiveAccountId) ?? '';
        _config = _accounts.firstWhere(
          (account) => account.id == activeId,
          orElse: () => _accounts.first,
        );
      }
    } catch (e) {
      LogService.instance.warning('Alist', '读取配置失败', detail: '$e');
    }
  }

  Future<void> saveConfig(AlistConfig config) async {
    final normalized = _normalizeConfig(config);
    final idx = _accounts.indexWhere((account) => account.id == normalized.id);
    if (idx >= 0) {
      _accounts[idx] = normalized;
    } else {
      _accounts.add(normalized);
    }
    _config = normalized;
    await _persist();
    LogService.instance.info(
      'Alist',
      '配置已保存',
      detail:
          '名称: ${_config.displayName}\n地址: ${_config.baseUrl}\n根目录: ${_config.rootPath}\nToken: ${_config.token.isEmpty ? "无（guest）" : "已设置"}',
    );
    notifyListeners();
  }

  Future<void> setActiveAccount(String id) async {
    final next = _accounts.firstWhere(
      (account) => account.id == id,
      orElse: () => _config,
    );
    if (!next.ready) return;
    _config = next;
    await _persist();
    notifyListeners();
  }

  Future<void> deleteAccount(String id) async {
    _accounts.removeWhere((account) => account.id == id);
    if (_config.id == id) {
      _config = _accounts.isEmpty
          ? const AlistConfig(baseUrl: '', token: '', rootPath: '/')
          : _accounts.first;
    }
    await _persist();
    notifyListeners();
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _kAccounts,
      jsonEncode(_accounts.map((account) => account.toJson()).toList()),
    );
    await prefs.setString(_kActiveAccountId, _config.id);
  }

  AlistConfig _normalizeConfig(AlistConfig config) {
    final baseUrl = _normalizeBaseUrl(config.baseUrl);
    final id = config.id.trim().isNotEmpty
        ? config.id.trim()
        : 'alist_${DateTime.now().microsecondsSinceEpoch}';
    final name = config.name.trim().isNotEmpty
        ? config.name.trim()
        : (Uri.tryParse(baseUrl)?.host ?? 'Alist');
    return AlistConfig(
      id: id,
      name: name,
      baseUrl: baseUrl,
      token: config.token.trim(),
      rootPath: _normalizePath(config.rootPath),
    );
  }

  Future<bool> testConnection() async {
    final items = await list(_config.rootPath, autoLogin: true);
    LogService.instance.info(
      'Alist',
      '连接测试成功',
      detail: '根目录: ${_config.rootPath}\n项目数: ${items.length}',
    );
    return true;
  }

  /// 列目录。autoLogin=true 时，401/403 会弹 WebView 抓 token 后重试一次。
  Future<List<AlistItem>> list(String path, {bool autoLogin = true}) async {
    if (!_config.ready) throw Exception('请先配置 Alist');
    final normalizedPath = _normalizePath(path);
    try {
      return await _listWithConfig(_config, normalizedPath);
    } on _AlistAuthException catch (_) {
      if (!autoLogin) rethrow;
      final token = await _captureTokenViaWebView(_config);
      if (token.isEmpty) {
        throw Exception('Alist 需要登录，但未能获取 token');
      }
      final updated = AlistConfig(
        id: _config.id,
        name: _config.name,
        baseUrl: _config.baseUrl,
        token: token,
        rootPath: _config.rootPath,
      );
      await saveConfig(updated);
      return await _listWithConfig(updated, normalizedPath);
    }
  }

  Future<List<AlistItem>> _listWithConfig(
    AlistConfig config,
    String path,
  ) async {
    final url = '${config.baseUrl}/api/fs/list';
    LogService.instance.info('Alist', '读取目录', detail: '路径: $path\nURL: $url');
    final response = await _dio.post<dynamic>(
      url,
      data: jsonEncode({'path': path, 'refresh': false, 'password': ''}),
      options: Options(
        headers: {
          'Content-Type': 'application/json',
          if (config.token.isNotEmpty) 'Authorization': config.token,
        },
        responseType: ResponseType.json,
        validateStatus: (status) =>
            status != null && status >= 200 && status < 300,
      ),
    );
    final body = response.data;
    final map = body is String ? jsonDecode(body) as Map : body as Map;
    final code = (map['code'] is num) ? (map['code'] as num).toInt() : 0;
    if (code == 401 || code == 403) {
      throw _AlistAuthException();
    }
    if (code != 200) {
      throw Exception('Alist 列目录失败: ${map['message'] ?? code}');
    }
    final data = map['data'];
    final content = (data is Map) ? data['content'] : null;
    if (content is! List) return <AlistItem>[];
    final items = <AlistItem>[];
    for (final entry in content) {
      if (entry is! Map) continue;
      final name = '${entry['name'] ?? ''}';
      if (name.isEmpty || name == '.' || name == '..') continue;
      final isDir = entry['is_dir'] == true || entry['isDir'] == true;
      final size = (entry['size'] is num) ? (entry['size'] as num).toInt() : 0;
      final sign = '${entry['sign'] ?? ''}';
      final thumb = '${entry['thumb'] ?? ''}';
      items.add(
        AlistItem(
          name: name,
          path: _normalizePath('$path/$name'),
          isDirectory: isDir,
          size: size,
          sign: sign,
          thumb: thumb,
        ),
      );
    }
    items.sort(_compareItems);
    return items;
  }

  /// 取单个文件的播放信息：调 /api/fs/get，优先用返回的 `raw_url`
  /// （Alist 官方直链，自带 sign、可能指向独立 CDN/S3 域名），
  /// raw_url 缺失时才回退自己拼 `/d/<path>?sign=xxx`。
  /// 不做自动登录（播放时不应弹 WebView）；token 失效直接抛错，由用户去浏览页重登。
  Future<({String url, Map<String, String> headers})> resolveAudio(
    String path,
  ) async {
    final config = _configForPath(path);
    final rawPath = pathFromScopedPath(path);
    final url = '${config.baseUrl}/api/fs/get';
    final response = await _dio.post<dynamic>(
      url,
      data: jsonEncode({'path': rawPath, 'password': ''}),
      options: Options(
        headers: {
          'Content-Type': 'application/json',
          if (config.token.isNotEmpty) 'Authorization': config.token,
        },
        responseType: ResponseType.json,
        validateStatus: (status) =>
            status != null && status >= 200 && status < 300,
      ),
    );
    final body = response.data;
    final map = body is String ? jsonDecode(body) as Map : body as Map;
    final code = (map['code'] is num) ? (map['code'] as num).toInt() : 0;
    if (code == 401 || code == 403) {
      throw Exception('Alist token 失效，请到 Alist 页面重新登录');
    }
    if (code != 200) {
      throw Exception('Alist 获取文件失败: ${map['message'] ?? code}');
    }
    final data = map['data'];
    if (data is! Map) throw Exception('Alist 返回缺少文件信息');
    final rawUrl = '${data['raw_url'] ?? ''}'.trim();
    if (rawUrl.isNotEmpty) {
      // raw_url 是自包含直链（自带 sign，通常指向 CDN），无需再带 Authorization。
      LogService.instance.info(
        'Alist',
        '解析直链成功',
        detail: '文件: $rawPath\nraw_url: $rawUrl',
      );
      return (url: rawUrl, headers: <String, String>{});
    }
    // 回退：用 sign 自己拼 /d/ 直链（Local provider 无 raw_url 时）。
    final sign = '${data['sign'] ?? ''}';
    final downloadUrl = _buildDownloadUrl(config, rawPath, sign);
    final headers = <String, String>{};
    if (config.token.isNotEmpty) headers['Authorization'] = config.token;
    LogService.instance.info(
      'Alist',
      '解析直链成功（/d 回退）',
      detail: '文件: $rawPath\nurl: $downloadUrl',
    );
    return (url: downloadUrl, headers: headers);
  }

  String _buildDownloadUrl(AlistConfig config, String path, String sign) {
    final base = _normalizeBaseUrl(config.baseUrl);
    final encoded = path
        .split('/')
        .where((segment) => segment.isNotEmpty)
        .map(Uri.encodeComponent)
        .join('/');
    final url = '$base/d/$encoded';
    return sign.isEmpty ? url : '$url?sign=${Uri.encodeComponent(sign)}';
  }

  Future<String> _captureTokenViaWebView(AlistConfig config) async {
    try {
      final result = await _loginChannel.invokeMethod<Map<dynamic, dynamic>>(
        'openLogin',
        {
          'url': config.baseUrl,
          'title': '${config.displayName} · 登录',
          'storageKey': 'token',
        },
      );
      final token = '${result?['storageValue'] ?? ''}'.trim();
      LogService.instance.info(
        'Alist',
        token.isEmpty ? 'WebView 未抓到 token' : 'WebView 抓到 token',
        detail: '实例: ${config.displayName}',
      );
      return token;
    } catch (e) {
      LogService.instance.error('Alist', 'WebView 抓 token 失败', error: e);
      return '';
    }
  }

  AlistBook toBook(String folderPath, List<AlistItem> items) {
    final meta = _parseBookFolderName(_displayName(folderPath));
    final audios = items.where((item) => isAudioFile(item.name)).toList()
      ..sort(_naturalAudioCompare);
    return AlistBook(
      title: meta?.title ?? _displayName(folderPath),
      author: meta?.author ?? '',
      narrator: meta?.narrator ?? '',
      cover: _findCoverUrl(items),
      path: _normalizePath(folderPath),
      audioFiles: audios,
    );
  }

  bool isAudioFile(String name) {
    final lower = name.toLowerCase();
    return audioExtensions.any(lower.endsWith);
  }

  bool isCoverFile(String name) {
    final lower = name.toLowerCase();
    return lower.startsWith('cover') &&
        (lower.endsWith('.jpg') ||
            lower.endsWith('.jpeg') ||
            lower.endsWith('.png') ||
            lower.endsWith('.webp'));
  }

  String _findCoverUrl(List<AlistItem> items) {
    final covers =
        items
            .where((item) => !item.isDirectory && isCoverFile(item.name))
            .toList()
          ..sort(
            (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
          );
    return covers.isEmpty ? '' : resolveUrl(covers.first.path);
  }

  AlistItem? findCoverItem(List<AlistItem> items) {
    final covers =
        items
            .where((item) => !item.isDirectory && isCoverFile(item.name))
            .toList()
          ..sort(
            (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
          );
    return covers.isEmpty ? null : covers.first;
  }

  Future<String> cacheCover(AlistItem coverItem) async {
    final ext = path_util.extension(coverItem.name).toLowerCase();
    final safeExt = ext.isEmpty ? '.jpg' : ext;
    final key = base64Url
        .encode(utf8.encode(coverItem.path))
        .replaceAll(RegExp(r'=+$'), '');
    final dir = Directory(
      path_util.join((await getApplicationCacheDirectory()).path, 'covers'),
    );
    if (!await dir.exists()) await dir.create(recursive: true);
    final file = File(path_util.join(dir.path, 'alist_$key$safeExt'));
    if (await file.exists() && await file.length() > 0) {
      return file.path;
    }
    final config = _configForPath(coverItem.path);
    final rawPath = pathFromScopedPath(coverItem.path);
    // 封面用 list 里拿到的 sign 直接拼 /d/ 直链；sign 缺失时无参访问。
    final url = _buildDownloadUrl(config, rawPath, coverItem.sign);
    await _dio.download(
      url,
      file.path,
      options: Options(
        headers: {
          if (config.token.isNotEmpty) 'Authorization': config.token,
        },
      ),
    );
    LogService.instance.info(
      'Alist',
      '封面已缓存到本地',
      detail: '文件: ${coverItem.name}\n路径: ${file.path}',
    );
    return file.path;
  }

  String displayName(String path) => _displayName(path);

  String scopedPath(String path, {String? accountId}) {
    final id = (accountId ?? activeAccountId).trim();
    final normalizedPath = _normalizePath(path);
    if (id.isEmpty) return normalizedPath;
    return '$id::$normalizedPath';
  }

  String accountIdFromScopedPath(String value) {
    final index = value.indexOf('::');
    return index <= 0 ? '' : value.substring(0, index);
  }

  String pathFromScopedPath(String value) {
    final index = value.indexOf('::');
    return _normalizePath(index <= 0 ? value : value.substring(index + 2));
  }

  Future<void> activateForScopedPath(String value) async {
    final id = accountIdFromScopedPath(value);
    if (id.isNotEmpty && id != activeAccountId) {
      await setActiveAccount(id);
    }
  }

  AlistConfig _configForPath(String path) {
    final id = accountIdFromScopedPath(path);
    if (id.isEmpty) return _config;
    return _accounts.firstWhere(
      (account) => account.id == id,
      orElse: () => _config,
    );
  }

  String resolveUrl(String path) {
    final config = _configForPath(path);
    final rawPath = pathFromScopedPath(path);
    // 列表/封面预览用 list 里自带的 sign（可能过期，但封面容错高）。
    // 这里无法拿到 sign，退化为无 sign 直链；封面下载走 cacheCover 用 item.sign。
    return _buildDownloadUrl(config, rawPath, '');
  }

  int _compareItems(AlistItem a, AlistItem b) {
    if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
    return _naturalCompare(a.name, b.name);
  }

  int _naturalAudioCompare(AlistItem a, AlistItem b) =>
      _naturalCompare(a.name, b.name);

  int _naturalCompare(String a, String b) {
    final ax = _firstNumber(a);
    final bx = _firstNumber(b);
    if (ax != null && bx != null && ax != bx) return ax.compareTo(bx);
    return a.toLowerCase().compareTo(b.toLowerCase());
  }

  int? _firstNumber(String value) {
    final match = RegExp(r'\d+').firstMatch(value);
    return match == null ? null : int.tryParse(match.group(0)!);
  }

  AlistBookMeta? _parseBookFolderName(String name) {
    final parts = name
        .split(RegExp(r'_+'))
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty)
        .toList(growable: false);
    if (parts.length < 3) return null;
    return AlistBookMeta(
      title: parts.first,
      author: parts[1],
      narrator: parts.sublist(2).join('_'),
    );
  }

  String _displayName(String path) {
    final normalized = _normalizePath(path);
    if (normalized == '/') return '/';
    final trimmed = normalized.endsWith('/')
        ? normalized.substring(0, normalized.length - 1)
        : normalized;
    final index = trimmed.lastIndexOf('/');
    return _safeDecode(index >= 0 ? trimmed.substring(index + 1) : trimmed);
  }

  String _safeDecode(String value) {
    try {
      return Uri.decodeComponent(value);
    } catch (_) {
      return value;
    }
  }

  String _normalizeBaseUrl(String value) =>
      value.trim().replaceAll(RegExp(r'/+$'), '');

  String _normalizePath(String value) {
    var path = value.trim();
    if (path.isEmpty) path = '/';
    if (!path.startsWith('/')) path = '/$path';
    return path.replaceAll(RegExp(r'/+'), '/');
  }
}

class _AlistAuthException implements Exception {}

class AlistBookMeta {
  final String title;
  final String author;
  final String narrator;

  const AlistBookMeta({
    required this.title,
    required this.author,
    required this.narrator,
  });
}
