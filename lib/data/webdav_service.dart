import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path_util;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xml/xml.dart';

import 'log_service.dart';

class WebDavBookMeta {
  final String title;
  final String author;
  final String narrator;

  const WebDavBookMeta({
    required this.title,
    required this.author,
    required this.narrator,
  });
}

class WebDavConfig {
  final String id;
  final String name;
  final String baseUrl;
  final String username;
  final String password;
  final String rootPath;

  const WebDavConfig({
    this.id = '',
    this.name = '',
    required this.baseUrl,
    required this.username,
    required this.password,
    required this.rootPath,
  });

  bool get ready => baseUrl.trim().isNotEmpty;
  String get displayName =>
      name.trim().isNotEmpty ? name.trim() : Uri.tryParse(baseUrl)?.host ?? '';

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'baseUrl': baseUrl,
    'username': username,
    'password': password,
    'rootPath': rootPath,
  };

  factory WebDavConfig.fromJson(Map<String, dynamic> map) => WebDavConfig(
    id: '${map['id'] ?? ''}',
    name: '${map['name'] ?? ''}',
    baseUrl: '${map['baseUrl'] ?? ''}',
    username: '${map['username'] ?? ''}',
    password: '${map['password'] ?? ''}',
    rootPath: '${map['rootPath'] ?? '/'}',
  );
}

class WebDavItem {
  final String name;
  final String path;
  final bool isDirectory;
  final int size;
  final DateTime? modifiedAt;

  const WebDavItem({
    required this.name,
    required this.path,
    required this.isDirectory,
    this.size = 0,
    this.modifiedAt,
  });
}

class WebDavBook {
  final String title;
  final String author;
  final String narrator;
  final String cover;
  final String path;
  final List<WebDavItem> audioFiles;

  const WebDavBook({
    required this.title,
    required this.author,
    required this.narrator,
    required this.cover,
    required this.path,
    required this.audioFiles,
  });
}

class WebDavService extends ChangeNotifier {
  WebDavService._();
  static final instance = WebDavService._();

  static const _kConfig = 'webdav_config';
  static const _kAccounts = 'webdav_accounts';
  static const _kActiveAccountId = 'webdav_active_account_id';
  static const audioExtensions = {
    '.mp3',
    '.m4a',
    '.m4b',
    '.aac',
    '.flac',
    '.wav',
    '.ogg',
    '.opus',
  };

  final Dio _dio = Dio();
  final List<WebDavConfig> _accounts = [];
  WebDavConfig _config = const WebDavConfig(
    baseUrl: '',
    username: '',
    password: '',
    rootPath: '/',
  );
  String _effectiveBaseUrl = '';

  WebDavConfig get config => _config;
  List<WebDavConfig> get accounts => List.unmodifiable(_accounts);
  String get activeAccountId => _config.id;
  bool get ready => _config.ready;

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    final accountsRaw = prefs.getString(_kAccounts);
    try {
      if (accountsRaw != null && accountsRaw.isNotEmpty) {
        final rows = jsonDecode(accountsRaw) as List;
        _accounts
          ..clear()
          ..addAll(
            rows
                .whereType<Map>()
                .map(
                  (row) => _normalizeConfig(
                    WebDavConfig.fromJson(Map<String, dynamic>.from(row)),
                  ),
                )
                .where((config) => config.ready),
          );
        final activeId = prefs.getString(_kActiveAccountId) ?? '';
        if (_accounts.isNotEmpty) {
          _config = _accounts.firstWhere(
            (account) => account.id == activeId,
            orElse: () => _accounts.first,
          );
          _effectiveBaseUrl = _config.baseUrl;
        }
        return;
      }

      final raw = prefs.getString(_kConfig);
      if (raw == null || raw.isEmpty) return;
      final legacy = _normalizeConfig(
        WebDavConfig.fromJson(
          Map<String, dynamic>.from(jsonDecode(raw) as Map),
        ),
      );
      if (!legacy.ready) return;
      _accounts
        ..clear()
        ..add(legacy);
      _config = legacy;
      _effectiveBaseUrl = _config.baseUrl;
      await _persistAccounts();
    } catch (e) {
      LogService.instance.warning('WebDAV', '读取配置失败', detail: '$e');
    }
  }

  Future<void> saveConfig(WebDavConfig config) async {
    final normalized = _normalizeConfig(config);
    final idx = _accounts.indexWhere((account) => account.id == normalized.id);
    if (idx >= 0) {
      _accounts[idx] = normalized;
    } else {
      _accounts.add(normalized);
    }
    _config = normalized;
    _effectiveBaseUrl = _config.baseUrl;
    await _persistAccounts();
    LogService.instance.info(
      'WebDAV',
      '配置已保存',
      detail:
          '名称: ${_config.displayName}\n地址: ${_config.baseUrl}\n根目录: ${_config.rootPath}\n账号: ${_config.username.isEmpty ? '未设置' : _config.username}',
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
    _effectiveBaseUrl = next.baseUrl;
    await _persistAccounts();
    notifyListeners();
  }

  Future<void> deleteAccount(String id) async {
    _accounts.removeWhere((account) => account.id == id);
    if (_config.id == id) {
      _config = _accounts.isEmpty
          ? const WebDavConfig(
              baseUrl: '',
              username: '',
              password: '',
              rootPath: '/',
            )
          : _accounts.first;
      _effectiveBaseUrl = _config.baseUrl;
    }
    await _persistAccounts();
    notifyListeners();
  }

  Future<void> _persistAccounts() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _kAccounts,
      jsonEncode(_accounts.map((account) => account.toJson()).toList()),
    );
    await prefs.setString(_kActiveAccountId, _config.id);
    await prefs.setString(_kConfig, jsonEncode(_config.toJson()));
  }

  WebDavConfig _normalizeConfig(WebDavConfig config) {
    final baseUrl = _normalizeBaseUrl(config.baseUrl);
    final id = config.id.trim().isNotEmpty
        ? config.id.trim()
        : 'webdav_${DateTime.now().microsecondsSinceEpoch}';
    final name = config.name.trim().isNotEmpty
        ? config.name.trim()
        : (Uri.tryParse(baseUrl)?.host ?? 'WebDAV');
    return WebDavConfig(
      id: id,
      name: name,
      baseUrl: baseUrl,
      username: config.username.trim(),
      password: config.password,
      rootPath: _normalizePath(config.rootPath),
    );
  }

  Future<bool> testConnection() async {
    final items = await list(_config.rootPath);
    LogService.instance.info(
      'WebDAV',
      '连接测试成功',
      detail: '根目录: ${_config.rootPath}\n项目数: ${items.length}',
    );
    return true;
  }

  Future<List<WebDavItem>> list(String path) async {
    if (!_config.ready) throw Exception('请先配置 WebDAV');
    final normalizedPath = _normalizePath(path);
    try {
      return await _listWithBase(_config.baseUrl, normalizedPath);
    } on DioException catch (e) {
      final status = e.response?.statusCode ?? 0;
      if (status == 404 && !_config.baseUrl.toLowerCase().endsWith('/dav')) {
        final fallbackBase = '${_normalizeBaseUrl(_config.baseUrl)}/dav';
        LogService.instance.warning(
          'WebDAV',
          '目录不存在，尝试 OpenList/AList 默认 /dav 地址',
          detail:
              '原地址: ${_config.baseUrl}\n重试地址: $fallbackBase\n路径: $normalizedPath',
        );
        try {
          final items = await _listWithBase(fallbackBase, normalizedPath);
          _effectiveBaseUrl = fallbackBase;
          return items;
        } on DioException catch (fallbackError) {
          throw Exception(_friendlyDioError(fallbackError));
        }
      }
      throw Exception(_friendlyDioError(e));
    }
  }

  Future<List<WebDavItem>> _listWithBase(String baseUrl, String path) async {
    final url = _resolveUrl(baseUrl, path);
    LogService.instance.info('WebDAV', '读取目录', detail: '路径: $path\nURL: $url');
    final response = await _dio.request<String>(
      url,
      options: Options(
        method: 'PROPFIND',
        responseType: ResponseType.plain,
        headers: {
          'Depth': '1',
          if (_authHeader().isNotEmpty) 'Authorization': _authHeader(),
        },
        validateStatus: (status) =>
            status != null && status >= 200 && status < 300,
      ),
    );
    final body = response.data ?? '';
    final items = _parseList(body, path, baseUrl);
    items.sort(_compareItems);
    return items;
  }

  WebDavBook toBook(String folderPath, List<WebDavItem> items) {
    final meta = parseBookFolderName(_displayName(folderPath));
    final audios = items.where((item) => isAudioFile(item.name)).toList()
      ..sort(_naturalAudioCompare);
    return WebDavBook(
      title: meta?.title ?? _displayName(folderPath),
      author: meta?.author ?? '',
      narrator: meta?.narrator ?? '',
      cover: findCoverUrl(items),
      path: _normalizePath(folderPath),
      audioFiles: audios,
    );
  }

  WebDavBookMeta? parseBookFolderName(String name) {
    final parts = name
        .split(RegExp(r'_+'))
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty)
        .toList(growable: false);
    if (parts.length < 3) return null;
    return WebDavBookMeta(
      title: parts.first,
      author: parts[1],
      narrator: parts.sublist(2).join('_'),
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

  String findCoverUrl(List<WebDavItem> items) {
    final covers =
        items
            .where((item) => !item.isDirectory && isCoverFile(item.name))
            .toList()
          ..sort(
            (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
          );
    if (covers.isEmpty) return '';
    return resolveUrl(covers.first.path);
  }

  WebDavItem? findCoverItem(List<WebDavItem> items) {
    final covers =
        items
            .where((item) => !item.isDirectory && isCoverFile(item.name))
            .toList()
          ..sort(
            (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
          );
    return covers.isEmpty ? null : covers.first;
  }

  Future<String> cacheCover(WebDavItem coverItem) async {
    final ext = path_util.extension(coverItem.name).toLowerCase();
    final safeExt = ext.isEmpty ? '.jpg' : ext;
    final key = base64Url
        .encode(utf8.encode(coverItem.path))
        .replaceAll(RegExp(r'=+$'), '');
    final dir = Directory(
      path_util.join((await getApplicationCacheDirectory()).path, 'covers'),
    );
    if (!await dir.exists()) await dir.create(recursive: true);
    final file = File(path_util.join(dir.path, 'webdav_$key$safeExt'));
    if (await file.exists() && await file.length() > 0) {
      return file.path;
    }
    final url = resolveUrl(coverItem.path);
    await _dio.download(
      url,
      file.path,
      options: Options(
        headers: {if (_authHeader().isNotEmpty) 'Authorization': _authHeader()},
      ),
    );
    LogService.instance.info(
      'WebDAV',
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

  String resolveUrl(String path) {
    final id = accountIdFromScopedPath(path);
    final rawPath = pathFromScopedPath(path);
    WebDavConfig config = _config;
    if (id.isNotEmpty) {
      config = _accounts.firstWhere(
        (account) => account.id == id,
        orElse: () => _config,
      );
    }
    return _resolveUrl(
      id.isEmpty && _effectiveBaseUrl.isNotEmpty
          ? _effectiveBaseUrl
          : config.baseUrl,
      rawPath,
    );
  }

  String _resolveUrl(String baseUrl, String path) {
    final base = _normalizeBaseUrl(baseUrl);
    final baseUri = Uri.parse(base.endsWith('/') ? base : '$base/');
    final normalizedPath = _normalizePath(
      _stripBasePath(path, _safeDecode(baseUri.path)),
    );
    final relative = normalizedPath == '/'
        ? ''
        : normalizedPath
              .substring(1)
              .split('/')
              .map(Uri.encodeComponent)
              .join('/');
    return baseUri.resolve(relative).toString();
  }

  String _friendlyDioError(DioException e) {
    final status = e.response?.statusCode;
    final url = e.requestOptions.uri.toString();
    if (status == 404) {
      return 'WebDAV 路径不存在（404）\n请检查地址是否应为 /dav，根目录是否正确。\n请求: $url';
    }
    if (status == 401 || status == 403) {
      return 'WebDAV 认证失败（$status）\n请检查账号、密码或访问权限。\n请求: $url';
    }
    if (status != null) {
      return 'WebDAV 请求失败（HTTP $status）\n请求: $url';
    }
    return 'WebDAV 请求失败: ${e.message ?? e.type.name}\n请求: $url';
  }

  Map<String, String> headers() {
    final auth = _authHeader();
    return auth.isEmpty ? const {} : {'Authorization': auth};
  }

  Map<String, String> headersForPath(String path) {
    final id = accountIdFromScopedPath(path);
    WebDavConfig config = _config;
    if (id.isNotEmpty) {
      config = _accounts.firstWhere(
        (account) => account.id == id,
        orElse: () => _config,
      );
    }
    final auth = _authHeaderFor(config);
    return auth.isEmpty ? const {} : {'Authorization': auth};
  }

  /// 将相对路径拼接到当前账号的根目录下。
  String pathUnderRoot(String relative) {
    final root = _normalizePath(_config.rootPath);
    final rel = relative.startsWith('/') ? relative : '/$relative';
    return _normalizePath(root == '/' ? rel : '$root$rel');
  }

  /// 读取远端文本文件;不存在(404)时返回 null。
  Future<String?> getString(String path) async {
    if (!_config.ready) throw Exception('请先配置 WebDAV');
    final url = resolveUrl(path);
    final Response<String> response;
    try {
      response = await _dio.request<String>(
        url,
        options: Options(
          method: 'GET',
          responseType: ResponseType.plain,
          headers: {
            if (_authHeader().isNotEmpty) 'Authorization': _authHeader(),
          },
          validateStatus: (_) => true,
        ),
      );
    } on DioException catch (e) {
      throw Exception(_friendlyDioError(e));
    }
    final status = response.statusCode ?? 0;
    if (status == 404) return null;
    if (status < 200 || status >= 300) {
      throw Exception('WebDAV 下载失败（HTTP $status）\n路径: $path');
    }
    return response.data;
  }

  /// 上传文本文件,自动逐级创建缺失的父目录。
  Future<void> putString(String path, String content) async {
    if (!_config.ready) throw Exception('请先配置 WebDAV');
    final normalized = _normalizePath(path);
    final segments = normalized
        .split('/')
        .where((segment) => segment.isNotEmpty)
        .toList();
    var current = '';
    for (final segment in segments.take(segments.length - 1)) {
      current = '$current/$segment';
      await _mkcolLenient(current);
    }
    final url = resolveUrl(normalized);
    final response = await _dio.request<List<int>>(
      url,
      data: utf8.encode(content),
      options: Options(
        method: 'PUT',
        contentType: 'application/octet-stream',
        headers: {
          if (_authHeader().isNotEmpty) 'Authorization': _authHeader(),
        },
        validateStatus: (_) => true,
      ),
    );
    final status = response.statusCode ?? 0;
    if (status < 200 || status >= 300) {
      throw Exception('WebDAV 上传失败（HTTP $status）\n路径: $normalized');
    }
  }

  Future<void> _mkcolLenient(String path) async {
    final url = resolveUrl(path);
    try {
      final response = await _dio.request<String>(
        url,
        options: Options(
          method: 'MKCOL',
          responseType: ResponseType.plain,
          headers: {
            if (_authHeader().isNotEmpty) 'Authorization': _authHeader(),
          },
          validateStatus: (_) => true,
        ),
      );
      final status = response.statusCode ?? 0;
      // 405 表示目录已存在,视为成功;其他失败交给最终 PUT 报错。
      if (status >= 200 && status < 300) return;
      if (status == 405 || status == 301 || status == 409) return;
      LogService.instance.warning(
        'WebDAV',
        '创建目录未成功(继续尝试上传)',
        detail: '目录: $path\nHTTP $status',
      );
    } on DioException catch (e) {
      LogService.instance.warning(
        'WebDAV',
        '创建目录请求失败(继续尝试上传)',
        detail: '目录: $path\n${e.message ?? e.type.name}',
      );
    }
  }

  String _authHeader() {
    return _authHeaderFor(_config);
  }

  String _authHeaderFor(WebDavConfig config) {
    if (config.username.isEmpty && config.password.isEmpty) return '';
    final token = base64Encode(
      utf8.encode('${config.username}:${config.password}'),
    );
    return 'Basic $token';
  }

  List<WebDavItem> _parseList(
    String xmlText,
    String currentPath,
    String baseUrl,
  ) {
    final document = XmlDocument.parse(xmlText);
    final basePath = _safeDecode(Uri.tryParse(baseUrl)?.path ?? '');
    final current = _normalizePath(_stripBasePath(currentPath, basePath));
    final result = <WebDavItem>[];
    for (final response in document.descendants.whereType<XmlElement>()) {
      if (response.name.local != 'response') continue;
      final href = _firstChildText(response, 'href');
      if (href.isEmpty) continue;
      final itemPath = _pathFromHref(href, basePath);
      if (_samePath(itemPath, current)) continue;
      final name = _displayName(itemPath);
      if (name.isEmpty) continue;
      final resourceType = response.descendants
          .whereType<XmlElement>()
          .where((e) => e.name.local == 'resourcetype')
          .expand((e) => e.children.whereType<XmlElement>())
          .map((e) => e.name.local)
          .toSet();
      final isDir = resourceType.contains('collection') || href.endsWith('/');
      final size =
          int.tryParse(_firstChildText(response, 'getcontentlength')) ?? 0;
      final modifiedRaw = _firstChildText(response, 'getlastmodified');
      result.add(
        WebDavItem(
          name: name,
          path: itemPath,
          isDirectory: isDir,
          size: size,
          modifiedAt: modifiedRaw.isEmpty
              ? null
              : DateTime.tryParse(modifiedRaw),
        ),
      );
    }
    return result;
  }

  String _firstChildText(XmlElement element, String localName) {
    for (final child in element.descendants.whereType<XmlElement>()) {
      if (child.name.local == localName) return child.innerText.trim();
    }
    return '';
  }

  String _pathFromHref(String href, String basePath) {
    final uri = Uri.tryParse(href);
    final rawPath = uri == null ? href : uri.path;
    return _normalizePath(_stripBasePath(_safeDecode(rawPath), basePath));
  }

  int _compareItems(WebDavItem a, WebDavItem b) {
    if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
    return _naturalCompare(a.name, b.name);
  }

  int _naturalAudioCompare(WebDavItem a, WebDavItem b) {
    return _naturalCompare(a.name, b.name);
  }

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
      final escaped = value.replaceAllMapped(
        RegExp(r'%(?![0-9A-Fa-f]{2})'),
        (_) => '%25',
      );
      try {
        return Uri.decodeComponent(escaped);
      } catch (_) {
        return value;
      }
    }
  }

  bool _samePath(String a, String b) {
    return _normalizePath(a) == _normalizePath(b);
  }

  String _stripBasePath(String path, String basePath) {
    final normalized = _normalizePath(_safeDecode(path));
    final prefix = _normalizePath(_safeDecode(basePath));
    if (prefix == '/') return normalized;
    if (normalized == prefix) return '/';
    if (normalized.startsWith('$prefix/')) {
      return normalized.substring(prefix.length);
    }
    return normalized;
  }

  String _normalizeBaseUrl(String value) {
    return value.trim().replaceAll(RegExp(r'/+$'), '');
  }

  String _normalizePath(String value) {
    var path = value.trim();
    if (path.isEmpty) path = '/';
    if (!path.startsWith('/')) path = '/$path';
    return path.replaceAll(RegExp(r'/+'), '/');
  }
}
