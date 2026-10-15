import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:pointycastle/export.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../source/source_manager.dart';
import 'log_service.dart';
import 'progress_service.dart';
import 'settings_service.dart';
import 'shelf_service.dart';
import 'secure_store.dart';
import 'sync_payload.dart';
import 'webdav_service.dart';

/// 数据同步专用的 WebDAV 服务器配置。
/// 与网盘书库的 WebDAV 账号互相独立,互不影响。
class WebDavSyncConfig {
  final String baseUrl;
  final String username;
  final String password;
  final String remoteDir;

  const WebDavSyncConfig({
    this.baseUrl = '',
    this.username = '',
    this.password = '',
    this.remoteDir = '/JuTingSync',
  });

  bool get ready => baseUrl.trim().isNotEmpty;

  Map<String, dynamic> toJson() => {
    'baseUrl': baseUrl,
    'username': username,
    'password': password,
    'remoteDir': remoteDir,
  };

  factory WebDavSyncConfig.fromJson(Map<String, dynamic> map) =>
      WebDavSyncConfig(
        baseUrl: '${map['baseUrl'] ?? ''}',
        username: '${map['username'] ?? ''}',
        password: '${map['password'] ?? ''}',
        remoteDir: '${map['remoteDir'] ?? ''}',
      );
}

/// 同步请求失败:携带 HTTP 状态码,便于上层区分限流/超额并退避。
/// `toString()` 仍是给用户看的友好文案,与旧实现保持一致。
class SyncDavException implements Exception {
  SyncDavException(this.message, {this.statusCode, this.path});

  final String message;
  final int? statusCode;
  final String? path;

  @override
  String toString() => message;
}

/// 同步专用的轻量 WebDAV 客户端:只支持读文本 / 写文本 / 建目录 / 连通性测试。
class _SyncDavClient {
  _SyncDavClient(this._config);

  final WebDavSyncConfig _config;
  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 60),
      sendTimeout: const Duration(seconds: 60),
    ),
  );

  /// 已确认存在的远端目录。每次 PUT 都逐级 MKCOL 会让每个同步轮次多出请求,
  /// 对按请求数计费的 WebDAV 是纯浪费,所以建过一次就记住。
  final Set<String> _ensuredDirs = <String>{};

  Map<String, String> get _authHeader {
    if (_config.username.isEmpty && _config.password.isEmpty) return const {};
    final token = base64Encode(
      utf8.encode('${_config.username}:${_config.password}'),
    );
    return {'Authorization': 'Basic $token'};
  }

  String _normalizePath(String value) {
    var path = value.trim();
    if (path.isEmpty) path = '/';
    if (!path.startsWith('/')) path = '/$path';
    return path.replaceAll(RegExp(r'/+'), '/');
  }

  String resolveUrl(String path) {
    final base = _config.baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    final baseUri = Uri.parse(base.endsWith('/') ? base : '$base/');
    final normalized = _normalizePath(path);
    final relative = normalized == '/'
        ? ''
        : normalized
              .substring(1)
              .split('/')
              .map(Uri.encodeComponent)
              .join('/');
    return baseUri.resolve(relative).toString();
  }

  String _friendlyError(DioException e, String action) {
    final status = e.response?.statusCode;
    final url = e.requestOptions.uri.toString();
    if (status == 401 || status == 403) {
      return '$action失败：认证被拒绝（$status），请检查账号密码\n$url';
    }
    if (status == 404) {
      return '$action失败：路径不存在（404）\n$url';
    }
    if (status != null) {
      return '$action失败：HTTP $status\n$url';
    }
    return '$action失败：${e.message ?? e.type.name}\n$url';
  }

  /// PROPFIND Depth:0 验证服务器可达且凭据正确。
  Future<void> testConnection() async {
    final url = resolveUrl(_normalizePath(_config.remoteDir));
    final Response<dynamic> response;
    try {
      response = await _dio.request<dynamic>(
        url,
        options: Options(
          method: 'PROPFIND',
          headers: {'Depth': '0', ..._authHeader},
          validateStatus: (_) => true,
        ),
      );
    } on DioException catch (e) {
      throw Exception(_friendlyError(e, '连接测试'));
    }
    final status = response.statusCode ?? 0;
    if (status == 404) {
      throw Exception(
        '连接成功但远程目录不存在，保存后首次同步会自动创建\n${_config.remoteDir}',
      );
    }
    if (status < 200 || status >= 300) {
      throw Exception('连接测试失败：HTTP $status\n$url');
    }
  }

  Future<String?> getString(String path) async {
    final Response<String> response;
    try {
      response = await _dio.request<String>(
        resolveUrl(path),
        options: Options(
          method: 'GET',
          responseType: ResponseType.plain,
          headers: _authHeader,
          validateStatus: (_) => true,
        ),
      );
    } on DioException catch (e) {
      throw SyncDavException(
        _friendlyError(e, '下载'),
        statusCode: e.response?.statusCode,
        path: path,
      );
    }
    final status = response.statusCode ?? 0;
    if (status == 404) return null;
    if (status < 200 || status >= 300) {
      throw SyncDavException(
        'WebDAV 下载失败（HTTP $status）\n路径: $path',
        statusCode: status,
        path: path,
      );
    }
    return response.data;
  }

  Future<void> putString(String path, String content) async {
    final normalized = _normalizePath(path);
    final segments =
        normalized.split('/').where((segment) => segment.isNotEmpty).toList();
    var current = '';
    for (final segment in segments.take(segments.length - 1)) {
      current = '$current/$segment';
      // 目录建过一次就跳过:每轮同步少一个请求。
      if (_ensuredDirs.contains(current)) continue;
      if (await _mkcolLenient(current)) _ensuredDirs.add(current);
    }
    final Response<List<int>> response;
    try {
      response = await _dio.request<List<int>>(
        resolveUrl(normalized),
        data: utf8.encode(content),
        options: Options(
          method: 'PUT',
          contentType: 'application/octet-stream',
          headers: _authHeader,
          validateStatus: (_) => true,
        ),
      );
    } on DioException catch (e) {
      throw SyncDavException(
        _friendlyError(e, '上传'),
        statusCode: e.response?.statusCode,
        path: normalized,
      );
    }
    final status = response.statusCode ?? 0;
    if (status < 200 || status >= 300) {
      // 远端目录可能被清理过,清空缓存让下次重新创建,避免一直 404/409。
      if (status == 404 || status == 409) _ensuredDirs.clear();
      throw SyncDavException(
        'WebDAV 上传失败（HTTP $status）\n路径: $normalized',
        statusCode: status,
        path: normalized,
      );
    }
  }

  /// 返回是否已确认目录存在(成功创建或服务端明确表示已存在)。
  Future<bool> _mkcolLenient(String path) async {
    try {
      final response = await _dio.request<String>(
        resolveUrl(path),
        options: Options(
          method: 'MKCOL',
          responseType: ResponseType.plain,
          headers: _authHeader,
          validateStatus: (_) => true,
        ),
      );
      final status = response.statusCode ?? 0;
      // 405 = 目录已存在;301/409 = 部分服务器对已存在目录的返回,继续尝试。
      if (status >= 200 && status < 300) return true;
      if (status == 405 || status == 301 || status == 409) return true;
      LogService.instance.warning(
        'Sync',
        '创建远程目录未成功(继续尝试上传)',
        detail: '目录: $path\nHTTP $status',
      );
      return false;
    } on DioException catch (e) {
      LogService.instance.warning(
        'Sync',
        '创建远程目录请求失败(继续尝试上传)',
        detail: '目录: $path\n${e.message ?? e.type.name}',
      );
      return false;
    }
  }
}

/// 基于 WebDAV 的多设备数据同步。
///
/// - 使用独立于网盘书库的 WebDAV 服务器配置,互不影响。
/// - 数据整体打包为 JSON 后用 AES-256-CBC + HMAC-SHA256 加密存储,
///   云端不出现任何明文(音源 Cookie、登录凭据等都在密文内)。
/// - 加密密钥由用户设置的"同步密码"经 PBKDF2 派生,所有设备必须
///   使用相同密码才能互相同步。
/// - 合并规则:
///   - 播放进度:按 (sourceId, bookId) 取 updatedAt 较新的一方;
///   - 书架:并集,同一本书取 addTime 较新的一方;
///   - 设置:整体按变更时间戳新者胜;
///   - 音源(代码/排序/Cookie/订阅):整体按变更时间戳新者胜。
class WebDavSyncService extends ChangeNotifier {
  WebDavSyncService._();
  static final instance = WebDavSyncService._();

  static const _kEnabled = 'sync_auto_enabled';
  static const _kPassword = 'sync_password';
  static const _kLastSyncAt = 'sync_last_sync_at';
  static const _kLastResult = 'sync_last_result';
  static const _kDeviceTag = 'sync_device_tag';
  static const _kConfig = 'sync_webdav_config';
  // 同步密码与服务器配置的加密存储键;明文旧键由 SecureStore 迁移后删除。
  static const _kPasswordSecure = 'sec.sync_password';
  static const _kConfigSecure = 'sec.sync_webdav_config';

  static const defaultRemoteDir = '/JuTingSync';

  /// 自动同步的最小间隔,防止高频操作触发风暴。
  static const _minSyncIntervalMs = 90 * 1000;
  static const _tickInterval = Duration(seconds: 60);

  final Random _random = Random.secure();

  WebDavSyncConfig _config = const WebDavSyncConfig();
  _SyncDavClient? _clientCache;
  WebDavSyncConfig? _clientConfig;
  bool _enabled = false;
  String _password = '';
  int _lastSyncAt = 0;
  String _lastResult = '';
  String _deviceTag = '';
  bool _syncing = false;
  int _lastSyncStart = 0;

  // 变更检测基线:与各服务当前时间戳比较,不一致视为有新变更。
  int _settingsStamp = 0;
  int _sourcesStamp = 0;
  int _progressStamp = 0;
  bool _localDirty = false;

  // 失败退避:限额型 WebDAV(免费套餐按上传流量/请求数计费)被限流或超额后必须降频,
  // 旧实现失败后仍按最小间隔继续重试,等于持续撞同一堵墙。
  int _consecutiveFailures = 0;
  int _retryNotBefore = 0;

  Timer? _timer;
  Timer? _startupTimer;

  WebDavSyncConfig get config => _config;
  bool get enabled => _enabled;
  bool get hasPassword => _password.isNotEmpty;
  int get lastSyncAt => _lastSyncAt;
  String get lastResult => _lastResult;
  bool get syncing => _syncing;

  /// 连续失败次数与下次可尝试时间(供 UI 展示"已退避到 X")。
  int get consecutiveFailures => _consecutiveFailures;
  int get retryNotBefore => _retryNotBefore;

  /// 同步服务器是否已配置(独立于网盘书库的 WebDAV 账号)。
  bool get serverReady => _config.ready;
  bool get canSync => serverReady && _password.isNotEmpty;

  _SyncDavClient get _client {
    if (_clientConfig != _config) {
      _clientCache = _SyncDavClient(_config);
      _clientConfig = _config;
    }
    return _clientCache!;
  }

  String get syncFilePath =>
      '${_normalizeRemoteDir(_config.remoteDir)}/juting_sync.json';

  String _normalizeRemoteDir(String value) {
    var path = value.trim();
    if (path.isEmpty) path = defaultRemoteDir;
    if (!path.startsWith('/')) path = '/$path';
    return path.replaceAll(RegExp(r'/+'), '/');
  }

  /// 保存同步服务器配置(独立于网盘书库)。
  Future<void> saveConfig(WebDavSyncConfig config) async {
    _config = WebDavSyncConfig(
      baseUrl: config.baseUrl.trim(),
      username: config.username.trim(),
      password: config.password,
      remoteDir: _normalizeRemoteDir(config.remoteDir),
    );
    await SecureStore.instance.write(
      _kConfigSecure,
      jsonEncode(_config.toJson()),
    );
    LogService.instance.info(
      'Sync',
      '同步服务器配置已保存',
      detail: '地址: ${_config.baseUrl}\n远程目录: ${_config.remoteDir}',
    );
    notifyListeners();
  }

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _enabled = prefs.getBool(_kEnabled) ?? false;
    _password = await SecureStore.instance.readMigrated(
      _kPassword,
      _kPasswordSecure,
    ) ??
    '';
    _lastSyncAt = prefs.getInt(_kLastSyncAt) ?? 0;
    _lastResult = prefs.getString(_kLastResult) ?? '';
    _deviceTag = prefs.getString(_kDeviceTag) ?? '';
    final rawConfig = await SecureStore.instance.readMigrated(
      _kConfig,
      _kConfigSecure,
    );
    if (rawConfig != null && rawConfig.isNotEmpty) {
      try {
        _config = WebDavSyncConfig.fromJson(
          Map<String, dynamic>.from(jsonDecode(rawConfig) as Map),
        );
      } catch (e) {
        LogService.instance.warning('Sync', '同步配置读取失败', detail: '$e');
      }
    }
    // 兼容迁移:同步配置为空且书库已配置 WebDAV 时,复制书库当前账号。
    // 此后两者完全独立,互不影响。
    if (!_config.ready && WebDavService.instance.ready) {
      final book = WebDavService.instance.config;
      _config = WebDavSyncConfig(
        baseUrl: book.baseUrl,
        username: book.username,
        password: book.password,
        remoteDir: defaultRemoteDir,
      );
      await SecureStore.instance.write(
        _kConfigSecure,
        jsonEncode(_config.toJson()),
      );
      LogService.instance.info(
        'Sync',
        '已从网盘书库导入 WebDAV 账号作为同步服务器',
        detail: '地址: ${_config.baseUrl}\n此后两者独立配置,互不影响',
      );
    }
    if (_deviceTag.isEmpty) {
      _deviceTag = base64Url
          .encode(List<int>.generate(3, (_) => _random.nextInt(256)))
          .replaceAll('=', '')
          .toLowerCase();
      await prefs.setString(_kDeviceTag, _deviceTag);
    }
    _refreshStamps();

    ShelfService.instance.addListener(_onShelfChanged);
    SettingsService.instance.addListener(_onSettingsChanged);

    _timer?.cancel();
    _timer = Timer.periodic(_tickInterval, (_) => _tick());

    if (_enabled && canSync) {
      _startupTimer?.cancel();
      _startupTimer = Timer(const Duration(seconds: 10), () {
        unawaited(syncNow(reason: 'startup'));
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _startupTimer?.cancel();
    ShelfService.instance.removeListener(_onShelfChanged);
    SettingsService.instance.removeListener(_onSettingsChanged);
    super.dispose();
  }

  void _onShelfChanged() {
    if (!ShelfService.instance.applyingSync) _localDirty = true;
  }

  void _onSettingsChanged() {
    if (!SettingsService.instance.isApplyingRemote) _localDirty = true;
  }

  void _refreshStamps() {
    _settingsStamp = SettingsService.instance.settingsChangedAt;
    _sourcesStamp = SourceManager.instance.lastChangedAt;
    _progressStamp = ProgressService.instance.lastSavedAt;
    _localDirty = false;
  }

  bool _hasLocalChanges() {
    return _settingsStamp != SettingsService.instance.settingsChangedAt ||
        _sourcesStamp != SourceManager.instance.lastChangedAt ||
        _progressStamp != ProgressService.instance.lastSavedAt ||
        _localDirty;
  }

  Future<void> _tick() async {
    if (!_enabled || _syncing || !canSync) return;
    if (!_hasLocalChanges()) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    // 上次失败后的退避窗口内不再尝试:限流/超额时继续按最小间隔重试只会更糟。
    if (now < _retryNotBefore) return;
    // 只有播放进度变化时降低同步频率,避免连续播放期间频繁整包上传。
    final onlyProgress =
        !_localDirty &&
        _progressStamp != ProgressService.instance.lastSavedAt &&
        _settingsStamp == SettingsService.instance.settingsChangedAt &&
        _sourcesStamp == SourceManager.instance.lastChangedAt;
    final minInterval = onlyProgress ? 5 * 60 * 1000 : _minSyncIntervalMs;
    if (_lastSyncStart > 0 && now - _lastSyncStart < minInterval) {
      return;
    }
    await syncNow(reason: 'auto');
  }

  Future<void> setEnabled(bool value) async {
    _enabled = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kEnabled, value);
    notifyListeners();
    if (value && canSync) {
      unawaited(syncNow(reason: 'enable'));
    }
  }

  /// 用当前保存的同步服务器配置做连通性测试(独立于网盘书库)。
  Future<void> testConnection() => _client.testConnection();

  Future<void> setPassword(String value) async {
    _password = value.trim();
    await SecureStore.instance.write(_kPasswordSecure, _password);
    notifyListeners();
  }

  /// 合并式同步:拉取云端 → 合并应用 → 推送合并结果。
  Future<void> syncNow({String reason = 'manual'}) async {
    if (_syncing) return;
    if (!serverReady) {
      _setLastResult('未配置 WebDAV,请先在网盘页配置账号');
      return;
    }
    if (_password.isEmpty) {
      _setLastResult('未设置同步密码');
      return;
    }
    _syncing = true;
    _lastSyncStart = DateTime.now().millisecondsSinceEpoch;
    _localDirty = false;
    notifyListeners();
    try {
      final remoteText = await _client.getString(syncFilePath);
      Map<String, dynamic>? remote;
      if (remoteText != null && remoteText.trim().isNotEmpty) {
        remote = await _decryptEnvelope(remoteText);
        final payloadVersion = _asInt(remote['v']);
        if (payloadVersion > 2) {
          throw Exception('云端同步数据版本过新,请先升级 App');
        }
      }
      if (remote != null) {
        await _applyRemote(remote);
      }
      final merged = await _buildPayload();
      // 比较口径剔除 updatedAt/deviceTag 这类"每次生成都不同"的字段,否则无论内容
      // 有没有变都会判定为有差异 → 每一轮(含每次冷启动、播放中每 5 分钟)都整包 PUT。
      if (remote == null ||
          SyncPayload.compareKey(merged) != SyncPayload.compareKey(remote)) {
        final envelope = await _encryptEnvelope(jsonEncode(merged));
        await _client.putString(syncFilePath, envelope);
        _lastResult = remote == null ? '已上传本地数据' : '已合并并上传';
        LogService.instance.info(
          'Sync',
          '同步载荷已上传',
          detail: '大小: ${(envelope.length / 1024).toStringAsFixed(1)} KB'
              '\n进度条数: ${(merged['progress'] as List?)?.length ?? 0}'
              '\n触发: $reason',
        );
      } else {
        _lastResult = '云端与本地一致';
      }
      _lastSyncAt = DateTime.now().millisecondsSinceEpoch;
      _consecutiveFailures = 0;
      _retryNotBefore = 0;
      _refreshStamps();
      await _persistState();
      LogService.instance.info(
        'Sync',
        'WebDAV 同步完成',
        detail: '触发: $reason\n结果: $_lastResult\n路径: $syncFilePath',
      );
    } catch (e, stack) {
      _consecutiveFailures++;
      final rateLimited = e is SyncDavException &&
          SyncPayload.isQuotaStatus(e.statusCode);
      final delayMs = SyncPayload.retryDelayMs(
        _consecutiveFailures,
        rateLimited: rateLimited,
      );
      _retryNotBefore = DateTime.now().millisecondsSinceEpoch + delayMs;
      _lastResult = rateLimited
          ? '同步被限流/额度不足,${(delayMs / 60000).round()} 分钟后再试: $e'
          : '同步失败: $e';
      LogService.instance.error(
        'Sync',
        'WebDAV 同步失败 ($reason)\n路径: $syncFilePath\n'
        '连续失败: $_consecutiveFailures 次,退避 ${(delayMs / 60000).round()} 分钟',
        error: e,
        stack: stack,
      );
    } finally {
      _syncing = false;
      notifyListeners();
    }
  }

  /// 手动备份:用本地数据整体覆盖云端。
  Future<void> uploadSnapshot() async {
    if (_syncing) return;
    if (!serverReady) {
      _setLastResult('未配置 WebDAV,请先在网盘页配置账号');
      return;
    }
    if (_password.isEmpty) {
      _setLastResult('未设置同步密码');
      return;
    }
    _syncing = true;
    notifyListeners();
    try {
      final payload = await _buildPayload();
      final envelope = await _encryptEnvelope(jsonEncode(payload));
      await _client.putString(syncFilePath, envelope);
      _lastSyncAt = DateTime.now().millisecondsSinceEpoch;
      _lastResult = '已上传本地数据';
      _consecutiveFailures = 0;
      _retryNotBefore = 0;
      _refreshStamps();
      await _persistState();
      LogService.instance.info(
        'Sync',
        'WebDAV 备份上传完成',
        detail: '路径: $syncFilePath',
      );
    } catch (e, stack) {
      _lastResult = '上传失败: $e';
      LogService.instance.error(
        'Sync',
        'WebDAV 备份上传失败',
        error: e,
        stack: stack,
      );
    } finally {
      _syncing = false;
      notifyListeners();
    }
  }

  /// 手动恢复:拉取云端并合并到本地,不上传。
  Future<void> downloadAndMerge() async {
    if (_syncing) return;
    if (!serverReady) {
      _setLastResult('未配置 WebDAV,请先在网盘页配置账号');
      return;
    }
    if (_password.isEmpty) {
      _setLastResult('未设置同步密码');
      return;
    }
    _syncing = true;
    notifyListeners();
    try {
      final remoteText = await _client.getString(syncFilePath);
      if (remoteText == null || remoteText.trim().isEmpty) {
        _lastResult = '云端还没有同步数据';
        return;
      }
      final remote = await _decryptEnvelope(remoteText);
      await _applyRemote(remote);
      _lastSyncAt = DateTime.now().millisecondsSinceEpoch;
      _lastResult = '已应用云端数据';
      _consecutiveFailures = 0;
      _retryNotBefore = 0;
      _refreshStamps();
      await _persistState();
      LogService.instance.info('Sync', 'WebDAV 云端数据已合并到本地');
    } catch (e, stack) {
      _lastResult = '下载失败: $e';
      LogService.instance.error(
        'Sync',
        'WebDAV 云端数据合并失败',
        error: e,
        stack: stack,
      );
    } finally {
      _syncing = false;
      notifyListeners();
    }
  }

  Future<void> _applyRemote(Map<String, dynamic> remote) async {
    // 设置:远端变更时间较新才整体覆盖。
    final settingsData = remote['settings'] is Map
        ? Map<String, dynamic>.from(remote['settings'] as Map)
        : null;
    final remoteSettingsAt = _asInt(remote['settingsChangedAt']);
    if (settingsData != null &&
        remoteSettingsAt > SettingsService.instance.settingsChangedAt) {
      await SettingsService.instance.applyRemoteSettings(
        settingsData,
        changedAt: remoteSettingsAt,
      );
    }

    // 音源(代码/排序/Cookie/订阅):远端变更时间较新才整体替换。
    final sourcesData = remote['sources'] is Map
        ? Map<String, dynamic>.from(remote['sources'] as Map)
        : null;
    final remoteSourcesAt = _asInt(remote['sourcesChangedAt']);
    if (sourcesData != null &&
        remoteSourcesAt > SourceManager.instance.lastChangedAt) {
      final sources = (sourcesData['sources'] as List? ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      if (sources.isNotEmpty) {
        await SourceManager.instance.restoreFromCloudSync(
          sources: sources,
          activeId: '${sourcesData['activeId'] ?? ''}',
          subscriptionUrl: '${sourcesData['subscriptionUrl'] ?? ''}',
          subscriptions: (sourcesData['subscriptions'] as List? ?? const [])
              .whereType<Map>()
              .map((e) => Map<String, dynamic>.from(e))
              .toList(),
          changedAt: remoteSourcesAt,
        );
      }
    }

    // 书架:并集,addTime 新者胜。
    final shelfRows = (remote['shelf'] as List? ?? const [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    final shelfApplied = await ShelfService.instance.mergeFromSync(shelfRows);

    // 播放进度:updatedAt 新者胜。
    final progressRows = (remote['progress'] as List? ?? const [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    final progressApplied = await ProgressService.instance.mergeFromSync(
      progressRows,
    );

    LogService.instance.info(
      'Sync',
      '云端数据合并完成',
      detail:
          '书架更新: $shelfApplied 条\n进度更新: $progressApplied 条\n'
          '设置: ${settingsData != null && remoteSettingsAt > 0 ? '按时间戳比较' : '跳过'}\n'
          '音源: ${sourcesData != null && remoteSourcesAt > 0 ? '按时间戳比较' : '跳过'}',
    );
  }

  Future<Map<String, dynamic>> _buildPayload() async {
    final shelf = await ShelfService.instance.list();
    // 进度只上行最近 N 条并做字段瘦身(见 SyncPayload):
    // 同步载荷的体积主要来自这个列表,而它每轮都要整包上传。
    final progress = await ProgressService.instance.listForSync(
      limit: SyncPayload.maxProgressRows,
    );
    return {
      'v': SyncPayload.version,
      // 易变字段:参与比较时会被 SyncPayload.compareKey 剔除,保留只为兼容旧版本客户端。
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
      'deviceTag': _deviceTag,
      'settingsChangedAt': SettingsService.instance.settingsChangedAt,
      'sourcesChangedAt': SourceManager.instance.lastChangedAt,
      'settings': SettingsService.instance.exportForSync(),
      'sources': SourceManager.instance.exportForSync(),
      'shelf': [
        for (var i = 0; i < shelf.length; i++)
          SyncPayload.shelfRow(
            sourceId: shelf[i].sourceId,
            bookId: shelf[i].bookId,
            title: shelf[i].title,
            author: shelf[i].author,
            sourceName: shelf[i].sourceName,
            addTime: shelf[i].addTime,
            cover: i < SyncPayload.coverKeepCount ? shelf[i].cover : '',
          ),
      ],
      'progress': SyncPayload.progressRows(progress),
    };
  }

  Future<void> _persistState() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kLastSyncAt, _lastSyncAt);
    await prefs.setString(_kLastResult, _lastResult);
  }

  void _setLastResult(String value) {
    _lastResult = value;
    notifyListeners();
  }

  // ── 加密 ──────────────────────────────────────────────────────────

  // PBKDF2(5 万次迭代)+ AES + HMAC 在主 isolate 上同步执行会产生百毫秒级
  // 卡顿,挪到 compute 后台 isolate;明文/密文均为可传输的 String/Map。
  Future<String> _encryptEnvelope(String plain) =>
      compute(_encryptEnvelopeJob, (plain, _password));

  Future<Map<String, dynamic>> _decryptEnvelope(String envelope) =>
      compute(_decryptEnvelopeJob, (envelope, _password));

  int _asInt(dynamic value) {
    if (value is num) return value.toInt();
    return int.tryParse('$value') ?? 0;
  }
}

/// 同步数据加密:PBKDF2 派生密钥 + AES-256-CBC(PKCS7) + HMAC-SHA256 完整性校验。
/// 密文格式(JSON):{app, v, salt, iv, ct, mac},均为 base64。
class SyncCrypto {
  SyncCrypto._();

  static const envelopeTag = 'juting-sync';
  static const _pbkdf2Iterations = 50000;

  static Uint8List _randomBytes(int length) {
    final random = Random.secure();
    return Uint8List.fromList(
      List<int>.generate(length, (_) => random.nextInt(256)),
    );
  }

  /// PBKDF2-HMAC-SHA256 派生 64 字节:前 32 字节 AES 密钥,后 32 字节 HMAC 密钥。
  static Uint8List deriveKeys(String password, Uint8List salt) {
    final derivator = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))
      ..init(Pbkdf2Parameters(salt, _pbkdf2Iterations, 64));
    return derivator.process(Uint8List.fromList(utf8.encode(password)));
  }

  static Uint8List _hmacSha256(Uint8List key, List<Uint8List> parts) {
    final mac = HMac(SHA256Digest(), 64)..init(KeyParameter(key));
    for (final part in parts) {
      mac.update(part, 0, part.length);
    }
    final out = Uint8List(mac.macSize);
    mac.doFinal(out, 0);
    return out;
  }

  static PaddedBlockCipherImpl _cipher(Uint8List key, Uint8List iv, bool forEncryption) {
    return PaddedBlockCipherImpl(
      PKCS7Padding(),
      CBCBlockCipher(AESEngine()),
    )..init(
        forEncryption,
        PaddedBlockCipherParameters<ParametersWithIV<KeyParameter>, Null>(
          ParametersWithIV<KeyParameter>(KeyParameter(key), iv),
          null,
        ),
      );
  }

  static bool constantTimeEquals(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  static String encrypt(String plain, String password) {
    final salt = _randomBytes(16);
    final iv = _randomBytes(16);
    final keys = deriveKeys(password, salt);
    final aesKey = Uint8List.sublistView(keys, 0, 32);
    final macKey = Uint8List.sublistView(keys, 32, 64);
    final cipher = _cipher(aesKey, iv, true);
    final cipherText = cipher.process(Uint8List.fromList(utf8.encode(plain)));
    final mac = _hmacSha256(macKey, [salt, iv, cipherText]);
    return jsonEncode({
      'app': envelopeTag,
      'v': 1,
      'salt': base64Encode(salt),
      'iv': base64Encode(iv),
      'ct': base64Encode(cipherText),
      'mac': base64Encode(mac),
    });
  }

  static Map<String, dynamic> decrypt(String envelope, String password) {
    dynamic raw;
    try {
      raw = jsonDecode(envelope);
    } catch (_) {
      throw Exception('同步文件不是有效的加密数据');
    }
    if (raw is! Map || raw['app'] != envelopeTag) {
      throw Exception('同步文件格式无效');
    }
    final salt = base64Decode('${raw['salt']}');
    final iv = base64Decode('${raw['iv']}');
    final cipherText = base64Decode('${raw['ct']}');
    final mac = base64Decode('${raw['mac']}');
    if (salt.isEmpty || iv.length != 16 || cipherText.isEmpty) {
      throw Exception('同步文件数据不完整');
    }
    final keys = deriveKeys(password, salt);
    final aesKey = Uint8List.sublistView(keys, 0, 32);
    final macKey = Uint8List.sublistView(keys, 32, 64);
    final expected = _hmacSha256(macKey, [salt, iv, cipherText]);
    if (!constantTimeEquals(expected, mac)) {
      throw Exception('同步密码错误或数据已损坏');
    }
    final cipher = _cipher(aesKey, iv, false);
    final plain = utf8.decode(cipher.process(cipherText));
    final data = jsonDecode(plain);
    if (data is! Map) throw Exception('同步数据格式无效');
    return Map<String, dynamic>.from(data);
  }
}

/// compute 任务入口:必须是顶层函数。参数为 (明文或密文, 同步密码)。
String _encryptEnvelopeJob((String, String) args) =>
    SyncCrypto.encrypt(args.$1, args.$2);

Map<String, dynamic> _decryptEnvelopeJob((String, String) args) =>
    SyncCrypto.decrypt(args.$1, args.$2);
