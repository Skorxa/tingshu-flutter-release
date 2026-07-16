import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/catalog_cache_service.dart';
import '../data/log_service.dart';
import 'js_engine.dart';
import 'models.dart';
import 'source_contract.dart';

class SourceSubscriptionResult {
  final int added;
  final int updated;
  final int removed;
  final int total;

  const SourceSubscriptionResult({
    required this.added,
    required this.updated,
    required this.removed,
    required this.total,
  });
}

class _SubscriptionRequest {
  final String originalUrl;
  final String requestUrl;
  final String token;

  const _SubscriptionRequest({
    required this.originalUrl,
    required this.requestUrl,
    required this.token,
  });

  factory _SubscriptionRequest.parse(String raw) {
    final trimmed = raw.trim();
    final uri = Uri.tryParse(trimmed);
    if (uri == null) {
      return _SubscriptionRequest(
        originalUrl: trimmed,
        requestUrl: trimmed,
        token: '',
      );
    }
    final fragment = uri.fragment.trim();
    final token = _extractToken(fragment);
    final requestUrl = fragment.isEmpty
        ? trimmed
        : uri.replace(fragment: '').toString();
    return _SubscriptionRequest(
      originalUrl: trimmed,
      requestUrl: requestUrl,
      token: token,
    );
  }

  Map<String, String>? get headers {
    if (token.isEmpty) return null;
    return {
      'Authorization': 'Bearer $token',
      'Accept': 'application/vnd.github.raw+json, text/plain, */*',
    };
  }

  String get maskedUrl => _maskSecret(originalUrl);

  static String _extractToken(String fragment) {
    if (fragment.isEmpty) return '';
    if (!fragment.contains('=')) return Uri.decodeComponent(fragment);
    final values = Uri.splitQueryString(fragment);
    for (final key in ['token', 'gh_token', 'access_token']) {
      final value = values[key]?.trim();
      if (value != null && value.isNotEmpty) return value;
    }
    return '';
  }

  static String _maskSecret(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.fragment.isEmpty) return url;
    final fragment = uri.fragment;
    if (!fragment.contains('=')) return uri.replace(fragment: '***').toString();
    final values = Uri.splitQueryString(fragment);
    final masked = values.map((key, value) {
      final lower = key.toLowerCase();
      if (lower == 'token' || lower == 'gh_token' || lower == 'access_token') {
        return MapEntry(key, '***');
      }
      return MapEntry(key, value);
    });
    return uri.replace(fragment: Uri(queryParameters: masked).query).toString();
  }
}

class _SubscriptionPayload {
  final _SubscriptionRequest request;
  final List rawSources;
  final String version;

  const _SubscriptionPayload({
    required this.request,
    required this.rawSources,
    required this.version,
  });
}

/// 音源管理器:对齐 uni-app 版 sourceLoader 的能力。
/// - 音源 code + 启用状态 + 激活ID 存 shared_preferences
/// - 音源订阅配置存 shared_preferences,同步后把云端 JS 源落到本地
/// - 高层 search/getChapters/getAudioUrl 路由到当前激活音源
class SourceManager {
  SourceManager._();
  static final SourceManager instance = SourceManager._();
  static const int catalogPageSize = 30;

  static const _kSources = 'audio_sources'; // List<json:{id,name,code,enabled}>
  static const _kActive = 'active_source_id';
  static const _kSubscriptionUrl = 'audio_source_subscription_url';
  static const _kSubscriptions = 'audio_source_subscriptions';

  static const _removedBundledIds = {
    'yuanqi',
    'beiji-kuwo',
    'ytysxs',
    'qt-ximalaya',
    'qt-fanqie',
    'qt-kuwo',
    'qt-qimao',
    'eprendre-bilibili',
    'eprendre-bokan-yousheng',
    'eprendre-cnr',
    'eprendre-haiyang',
    'eprendre-ifish',
    'eprendre-jdlg',
    'eprendre-jihe',
    'eprendre-koudai-weiketang',
    'eprendre-kuwo',
    'eprendre-lanren',
    'eprendre-pingshu5',
    'eprendre-ting74',
    'eprendre-vbus',
    'eprendre-ysxs8',
    'eprendre-yuntu-yousheng',
    'tingshu-json-yuetingba',
    'tingshu-json-yuanqi-ximalaya',
    'tingshu-json-ting13',
    'tingshu-json-qiting',
    'tingshu-json-tingyou',
    'tingshu-json-i275',
    'tingshu-json-leting',
    'tingshu-json-shuyinfm',
    'tingyou',
  };

  final List<Map<String, dynamic>> _stored = []; // {id,name,code,enabled}
  final List<Map<String, dynamic>> _subscriptions = [];
  final Dio _dio = Dio();
  String _activeId = '';
  String _subscriptionUrl = '';
  final Set<String> _registered = {}; // 已在 JS 引擎注册的音源 id
  final Map<String, Future<void>> _registering = {};
  final Map<String, Future<SourceSubscriptionResult>> _syncingSubscriptions =
      {};
  bool _ready = false;

  Future<void> init() async {
    if (_ready) return;
    final prefs = await SharedPreferences.getInstance();

    final raw = prefs.getString(_kSources);
    if (raw != null && raw.isNotEmpty) {
      final list = jsonDecode(raw) as List;
      _stored
        ..clear()
        ..addAll(list.map((e) => Map<String, dynamic>.from(e as Map)));
    }
    _activeId = prefs.getString(_kActive) ?? '';
    _subscriptionUrl = prefs.getString(_kSubscriptionUrl) ?? '';
    final rawSubscriptions = prefs.getString(_kSubscriptions);
    if (rawSubscriptions != null && rawSubscriptions.isNotEmpty) {
      final list = jsonDecode(rawSubscriptions) as List;
      _subscriptions
        ..clear()
        ..addAll(list.map((e) => Map<String, dynamic>.from(e as Map)));
    }

    final before = _stored.length;
    _stored.removeWhere((source) {
      final id = '${source['id']}';
      if (!_removedBundledIds.contains(id)) return false;
      final subscriptionId = '${source['subscriptionId'] ?? ''}'.trim();
      final subscriptionUrl = '${source['subscriptionUrl'] ?? ''}'.trim();
      return subscriptionId.isEmpty && subscriptionUrl.isEmpty;
    });
    if (before != _stored.length) {
      _registered.removeWhere(_removedBundledIds.contains);
      if (_removedBundledIds.contains(_activeId)) _activeId = _firstEnabledId();
      LogService.instance.info(
        'Source',
        '已移除旧版内置音源',
        detail: '删除数量: ${before - _stored.length}',
      );
    }
    _migrateLegacySubscriptionData();
    _backfillSourceSubscriptionIds();
    await _persist();

    if (_activeId.isEmpty && _stored.isNotEmpty) {
      _activeId = '${_stored.first['id']}';
    }
    _ready = true;
    if (_subscriptions.isNotEmpty) {
      unawaited(syncAutoUpdateSubscriptions(trigger: 'startup'));
    }
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kSources, jsonEncode(_stored));
    await prefs.setString(_kActive, _activeId);
    await prefs.setString(_kSubscriptionUrl, _subscriptionUrl);
    await prefs.setString(_kSubscriptions, jsonEncode(_subscriptions));
  }

  bool _migrateLegacySubscriptionData() {
    if (_subscriptions.isNotEmpty || _subscriptionUrl.trim().isEmpty) {
      return false;
    }
    final request = _SubscriptionRequest.parse(_subscriptionUrl);
    final entry = _createSubscriptionEntry(
      id: _newSubscriptionId(),
      name: _defaultSubscriptionName(request.requestUrl),
      originalUrl: request.originalUrl,
      requestUrl: request.requestUrl,
      enabled: true,
      autoUpdate: false,
    );
    _subscriptions.add(entry);
    for (final source in _stored) {
      final sourceUrl = '${source['subscriptionUrl'] ?? ''}';
      if (sourceUrl == request.requestUrl) {
        source['subscriptionId'] = entry['id'];
      }
    }
    LogService.instance.info('SourceSub', '已迁移旧版单订阅配置');
    return true;
  }

  bool _backfillSourceSubscriptionIds() {
    var changed = false;
    for (final source in _stored) {
      final currentId = '${source['subscriptionId'] ?? ''}';
      if (currentId.isNotEmpty) continue;
      final sourceUrl = '${source['subscriptionUrl'] ?? ''}';
      if (sourceUrl.isEmpty) continue;
      final idx = _subscriptions.indexWhere(
        (item) => '${item['requestUrl'] ?? ''}' == sourceUrl,
      );
      if (idx < 0) continue;
      source['subscriptionId'] = '${_subscriptions[idx]['id']}';
      changed = true;
    }
    return changed;
  }

  Map<String, dynamic> _createSubscriptionEntry({
    required String id,
    required String name,
    required String originalUrl,
    required String requestUrl,
    required bool enabled,
    required bool autoUpdate,
    String version = '',
    String lastCheckedAt = '',
    String lastUpdatedAt = '',
    String lastError = '',
  }) => <String, dynamic>{
    'id': id,
    'name': name,
    'originalUrl': originalUrl,
    'requestUrl': requestUrl,
    'enabled': enabled,
    'autoUpdate': autoUpdate,
    'version': version,
    'lastCheckedAt': lastCheckedAt,
    'lastUpdatedAt': lastUpdatedAt,
    'lastError': lastError,
  };

  String _newSubscriptionId() =>
      DateTime.now().microsecondsSinceEpoch.toString();

  String _defaultSubscriptionName(String url) {
    final uri = Uri.tryParse(url);
    final host = uri?.host.trim() ?? '';
    return host.isNotEmpty ? host : '订阅源';
  }

  String _nowIso() => DateTime.now().toIso8601String();

  SourceSubscriptionMeta _subscriptionMetaFromStored(
    Map<String, dynamic> item,
  ) {
    final id = '${item['id'] ?? ''}';
    return SourceSubscriptionMeta(
      id: id,
      name: '${item['name'] ?? ''}'.trim().isNotEmpty
          ? '${item['name'] ?? ''}'.trim()
          : _defaultSubscriptionName('${item['requestUrl'] ?? ''}'),
      originalUrl: '${item['originalUrl'] ?? ''}',
      requestUrl: '${item['requestUrl'] ?? ''}',
      enabled: item['enabled'] != false,
      autoUpdate: item['autoUpdate'] != false,
      sourceCount: _stored
          .where((source) => _sourceBelongsToSubscription(source, id))
          .length,
      version: '${item['version'] ?? ''}',
      lastCheckedAt: '${item['lastCheckedAt'] ?? ''}',
      lastUpdatedAt: '${item['lastUpdatedAt'] ?? ''}',
      lastError: '${item['lastError'] ?? ''}',
    );
  }

  bool _sourceBelongsToSubscription(
    Map<String, dynamic> source,
    String subscriptionId,
  ) {
    final directId = '${source['subscriptionId'] ?? ''}';
    if (directId.isNotEmpty) return directId == subscriptionId;
    final url = '${source['subscriptionUrl'] ?? ''}';
    if (url.isEmpty) return false;
    final index = _subscriptions.indexWhere(
      (item) => '${item['id'] ?? ''}' == subscriptionId,
    );
    if (index < 0) return false;
    return url == '${_subscriptions[index]['requestUrl'] ?? ''}';
  }

  // 注册到 JS 引擎(幂等)
  Future<void> _ensureRegistered(Map<String, dynamic> s) async {
    final id = '${s['id']}';
    SourceContract.requireSupportedApiVersion(
      s['apiVersion'] ?? SourceContract.version,
      sourceId: id,
      sourceName: '${s['name'] ?? id}',
    );
    if (!_registered.contains(id)) {
      final inflight = _registering[id];
      if (inflight != null) {
        await inflight;
      } else {
        final future = () async {
          await JsEngine.instance.loadSource('${s['code']}');
          _registered.add(id);
        }();
        _registering[id] = future;
        try {
          await future;
        } finally {
          _registering.remove(id);
        }
      }
    }
    await _applyConfig(s);
  }

  Map<String, dynamic> _configOf(Map<String, dynamic> s) {
    final raw = s['config'];
    if (raw is Map) return Map<String, dynamic>.from(raw);
    return <String, dynamic>{};
  }

  Map<String, dynamic> _declaredConfigOf(Map<String, dynamic> s) {
    return _filterConfig(_configOf(s), _configFieldsOf(s));
  }

  Map<String, dynamic> _filterConfig(
    Map<String, dynamic> raw,
    List<SourceConfigField> fields,
  ) {
    final allowed = fields.map((field) => field.key).toSet();
    if (allowed.isEmpty) return <String, dynamic>{};
    return Map<String, dynamic>.fromEntries(
      raw.entries.where((entry) => allowed.contains(entry.key)),
    );
  }

  Future<void> _applyConfig(Map<String, dynamic> s) async {
    final id = '${s['id']}';
    await JsEngine.instance.setSourceConfig(id, _declaredConfigOf(s));
  }

  List<SourceConfigField> _configFieldsOf(Map<String, dynamic> s) {
    final raw = s['configFields'];
    final fields = raw is List
        ? raw
              .whereType<Map>()
              .map(SourceConfigField.fromMap)
              .where((field) => field.key.isNotEmpty)
              .toList()
        : <SourceConfigField>[];
    final keys = fields.map((field) => field.key).toSet();
    for (final field in _inferredConfigFields(s)) {
      if (keys.add(field.key)) fields.add(field);
    }
    return fields;
  }

  List<SourceConfigField> _inferredConfigFields(Map<String, dynamic> s) {
    final loginKey = _loginConfigKeyOf(s);
    if (loginKey.isNotEmpty && !_isQingtianSource(s)) {
      return [
        SourceConfigField(
          key: loginKey,
          label: '登录凭据',
          type: 'textarea',
          hint: '内置登录页获取的 Cookie 或 Token 会保存到这里。',
          required: true,
        ),
      ];
    }
    if (!_isQingtianSource(s)) return const [];
    return [
      SourceConfigField(
        key: 'qt_cookie',
        label: '青天 Cookie',
        type: 'textarea',
        hint: '填写登录后的 Cookie；音源会通过 uni.getStorageSync("qt_cookie") 读取。',
        required: true,
      ),
    ];
  }

  bool _isQingtianSource(Map<String, dynamic> s) {
    final id = '${s['id']}';
    final code = '${s['code'] ?? ''}';
    return id.startsWith('qt-') ||
        code.contains('qt_cookie') ||
        code.contains('gyks.cf');
  }

  String _loginUrlOf(Map<String, dynamic> s) {
    final declared = '${s['loginUrl'] ?? ''}'.trim();
    if (declared.isNotEmpty) return declared;
    if (_isQingtianSource(s)) return 'https://v1.gyks.cf/login';
    return '';
  }

  String _loginConfigKeyOf(Map<String, dynamic> s) {
    final declared = '${s['loginConfigKey'] ?? ''}'.trim();
    if (declared.isNotEmpty) return declared;
    if (_isQingtianSource(s)) return 'qt_cookie';
    return '';
  }

  Future<Map<String, dynamic>> _addInternal(
    String code, {
    bool persist = true,
    Map<String, dynamic>? metaOverride,
    String subscriptionUrl = '',
    String subscriptionId = '',
  }) async {
    final parsed = await JsEngine.instance.loadSource(code);
    final meta = {...parsed, ...?metaOverride};
    final id = meta['id']!;
    final apiVersion = SourceContract.requireSupportedApiVersion(
      meta['apiVersion'] ?? SourceContract.version,
      sourceId: '$id',
      sourceName: '${meta['name'] ?? id}',
    );
    _registered.add(id);
    final idx = _stored.indexWhere((e) => '${e['id']}' == id);
    final entry = <String, dynamic>{
      'id': id,
      'name': meta['name'],
      'apiVersion': apiVersion,
      'configFields': (meta['configFields'] as List?) ?? const [],
      'loginUrl': '${meta['loginUrl'] ?? ''}',
      'loginConfigKey': '${meta['loginConfigKey'] ?? ''}',
      'supportsDiscover': meta['supportsDiscover'] == true,
      'code': code,
      'enabled': idx >= 0 ? _stored[idx]['enabled'] != false : true,
      'subscriptionId': subscriptionId.isNotEmpty
          ? subscriptionId
          : (idx >= 0 ? '${_stored[idx]['subscriptionId'] ?? ''}' : ''),
      'subscriptionUrl': subscriptionUrl.isNotEmpty
          ? subscriptionUrl
          : (idx >= 0 ? '${_stored[idx]['subscriptionUrl'] ?? ''}' : ''),
    };
    entry['config'] = _filterConfig(
      idx >= 0 ? _configOf(_stored[idx]) : <String, dynamic>{},
      _configFieldsOf(entry),
    );
    if (idx >= 0) {
      final oldCode = '${_stored[idx]['code']}';
      _stored[idx] = entry;
      if (oldCode != code) {
        await CatalogCacheService.instance.clearSource(id);
      }
    } else {
      _stored.add(entry);
    }
    if (_stored.length == 1) _activeId = id;
    if (persist) await _persist();
    if (_registered.contains(id)) await _applyConfig(entry);
    LogService.instance.info(
      'Source',
      idx >= 0 ? '音源已更新' : '音源已添加',
      detail: '名称: ${meta['name']}\nID: $id',
    );
    return meta;
  }

  /// 添加/更新用户音源(粘贴的 JS code)
  Future<Map<String, dynamic>> addSource(String code) => _addInternal(code);

  String get subscriptionUrl => _subscriptionUrl;

  List<SourceSubscriptionMeta> getSubscriptions() =>
      _subscriptions.map(_subscriptionMetaFromStored).toList(growable: false);

  Future<SourceSubscriptionMeta> saveSubscription({
    String id = '',
    required String url,
    String name = '',
    bool enabled = true,
    bool autoUpdate = true,
  }) async {
    final request = _SubscriptionRequest.parse(url);
    if (request.originalUrl.isEmpty) throw Exception('订阅地址为空');
    var index = id.isNotEmpty
        ? _subscriptions.indexWhere((item) => '${item['id']}' == id)
        : -1;
    index = index >= 0
        ? index
        : _subscriptions.indexWhere(
            (item) => '${item['requestUrl']}' == request.requestUrl,
          );
    final previous = index >= 0
        ? Map<String, dynamic>.from(_subscriptions[index])
        : null;
    final entry = _createSubscriptionEntry(
      id: previous == null ? _newSubscriptionId() : '${previous['id']}',
      name: name.trim().isNotEmpty
          ? name.trim()
          : (previous == null
                ? _defaultSubscriptionName(request.requestUrl)
                : '${previous['name'] ?? ''}'.trim().isNotEmpty
                ? '${previous['name']}'.trim()
                : _defaultSubscriptionName(request.requestUrl)),
      originalUrl: request.originalUrl,
      requestUrl: request.requestUrl,
      enabled: previous == null ? enabled : previous['enabled'] != false,
      autoUpdate: previous == null
          ? autoUpdate
          : previous['autoUpdate'] != false,
      version: '${previous?['version'] ?? ''}',
      lastCheckedAt: '${previous?['lastCheckedAt'] ?? ''}',
      lastUpdatedAt: '${previous?['lastUpdatedAt'] ?? ''}',
      lastError: '${previous?['lastError'] ?? ''}',
    );
    if (index >= 0) {
      _subscriptions[index] = entry;
    } else {
      _subscriptions.add(entry);
    }
    _subscriptionUrl = request.originalUrl;
    _rebindSubscriptionSources('${entry['id']}', request.requestUrl);
    await _persist();
    LogService.instance.info(
      'SourceSub',
      index >= 0 ? '订阅源已更新' : '订阅源已添加',
      detail: '名称: ${entry['name']}\nURL: ${request.maskedUrl}',
    );
    return _subscriptionMetaFromStored(entry);
  }

  void _rebindSubscriptionSources(String subscriptionId, String requestUrl) {
    for (final source in _stored) {
      final sourceUrl = '${source['subscriptionUrl'] ?? ''}';
      if (sourceUrl == requestUrl) {
        source['subscriptionId'] = subscriptionId;
      }
    }
  }

  Future<void> setSubscriptionAutoUpdate(String id, bool enabled) async {
    final idx = _subscriptions.indexWhere((item) => '${item['id']}' == id);
    if (idx < 0) return;
    _subscriptions[idx]['autoUpdate'] = enabled;
    await _persist();
    LogService.instance.info(
      'SourceSub',
      enabled ? '订阅自动更新已开启' : '订阅自动更新已关闭',
      detail: '名称: ${_subscriptions[idx]['name']}\nID: $id',
    );
  }

  Future<void> setSubscriptionEnabled(String id, bool enabled) async {
    final idx = _subscriptions.indexWhere((item) => '${item['id']}' == id);
    if (idx < 0) return;
    _subscriptions[idx]['enabled'] = enabled;
    await _persist();
    LogService.instance.info(
      'SourceSub',
      enabled ? '订阅已启用' : '订阅已停用',
      detail: '名称: ${_subscriptions[idx]['name']}\nID: $id',
    );
  }

  Future<void> deleteSubscription(String id) async {
    final idx = _subscriptions.indexWhere((item) => '${item['id']}' == id);
    if (idx < 0) return;
    final removed = Map<String, dynamic>.from(_subscriptions.removeAt(idx));
    final removedSourceIds = <String>[];
    _stored.removeWhere((source) {
      final match = _sourceBelongsToSubscription(source, id);
      if (match) {
        removedSourceIds.add('${source['id']}');
        _registered.remove('${source['id']}');
      }
      return match;
    });
    if (!_stored.any((source) => '${source['id']}' == _activeId)) {
      _activeId = _firstEnabledId();
    }
    if (_subscriptions.isEmpty) {
      _subscriptionUrl = '';
    } else if (_subscriptionUrl == '${removed['originalUrl'] ?? ''}') {
      _subscriptionUrl = '${_subscriptions.last['originalUrl'] ?? ''}';
    }
    await _persist();
    LogService.instance.info(
      'SourceSub',
      '订阅源已删除',
      detail:
          '名称: ${removed['name']}\n删除音源: ${removedSourceIds.length}\nURL: ${_SubscriptionRequest.parse('${removed['originalUrl'] ?? ''}').maskedUrl}',
    );
  }

  Future<SourceSubscriptionResult> syncSubscriptionById(String id) async {
    final inflight = _syncingSubscriptions[id];
    if (inflight != null) return inflight;
    final idx = _subscriptions.indexWhere((item) => '${item['id']}' == id);
    if (idx < 0) throw Exception('订阅不存在');
    final future = _syncSubscriptionEntry(
      Map<String, dynamic>.from(_subscriptions[idx]),
    );
    _syncingSubscriptions[id] = future;
    try {
      return await future;
    } finally {
      _syncingSubscriptions.remove(id);
    }
  }

  Future<SourceSubscriptionResult> syncAutoUpdateSubscriptions({
    String trigger = 'manual',
  }) async {
    final targets = _subscriptions
        .where(
          (item) => item['enabled'] != false && item['autoUpdate'] != false,
        )
        .map((item) => '${item['id']}')
        .toList(growable: false);
    if (targets.isEmpty) {
      return const SourceSubscriptionResult(
        added: 0,
        updated: 0,
        removed: 0,
        total: 0,
      );
    }
    LogService.instance.info(
      'SourceSub',
      '开始批量同步自动更新订阅',
      detail: '触发: $trigger\n数量: ${targets.length}',
    );
    var added = 0;
    var updated = 0;
    var removed = 0;
    for (final id in targets) {
      try {
        final check = await checkSubscriptionById(id);
        if (!check.hasUpdate) continue;
        final result = await syncSubscriptionById(id);
        added += result.added;
        updated += result.updated;
        removed += result.removed;
      } catch (e, stack) {
        LogService.instance.error(
          'SourceSub',
          '自动更新订阅失败',
          error: e,
          stack: stack,
        );
      }
    }
    return SourceSubscriptionResult(
      added: added,
      updated: updated,
      removed: removed,
      total: _stored.length,
    );
  }

  Future<SourceSubscriptionCheckResult> checkSubscriptionById(String id) async {
    final idx = _subscriptions.indexWhere((item) => '${item['id']}' == id);
    if (idx < 0) throw Exception('订阅不存在');
    final subscription = Map<String, dynamic>.from(_subscriptions[idx]);
    final payload = await _fetchSubscriptionPayload(subscription);
    final remoteVersion = payload.version;
    final currentVersion = '${_subscriptions[idx]['version'] ?? ''}';
    final hasUpdate = remoteVersion.isNotEmpty
        ? remoteVersion != currentVersion
        : '${_subscriptions[idx]['lastUpdatedAt'] ?? ''}'.isEmpty;
    _subscriptions[idx]['lastCheckedAt'] = _nowIso();
    _subscriptions[idx]['lastError'] = '';
    await _persist();
    LogService.instance.info(
      'SourceSub',
      hasUpdate ? '检测到订阅更新' : '订阅已是最新版本',
      detail:
          '名称: ${subscription['name']}\n当前版本: ${currentVersion.isEmpty ? '未知' : currentVersion}\n远端版本: ${remoteVersion.isEmpty ? '未声明' : remoteVersion}',
    );
    return SourceSubscriptionCheckResult(
      subscriptionId: id,
      version: remoteVersion,
      sourceCount: payload.rawSources.length,
      hasUpdate: hasUpdate,
    );
  }

  Future<SourceSubscriptionResult> _syncSubscriptionEntry(
    Map<String, dynamic> subscription,
  ) async {
    final id = '${subscription['id'] ?? ''}';
    final idx = _subscriptions.indexWhere((item) => '${item['id']}' == id);
    if (idx < 0) throw Exception('订阅不存在');
    _subscriptions[idx]['lastCheckedAt'] = _nowIso();
    _subscriptions[idx]['lastError'] = '';
    await _persist();
    try {
      final payload = await _fetchSubscriptionPayload(subscription);
      final request = payload.request;
      final rawSources = payload.rawSources;
      final existingCount = _stored
          .where((source) => _sourceBelongsToSubscription(source, id))
          .length;
      if (rawSources.isEmpty && existingCount > 0) {
        LogService.instance.error(
          'SourceSub',
          '订阅返回空音源列表，已阻止覆盖本地音源',
          error: Exception('订阅空列表保护'),
        );
        throw Exception('订阅返回空列表，已保留本地音源，避免误删');
      }

      final seenIds = <String>{};
      var added = 0;
      var updated = 0;
      for (var i = 0; i < rawSources.length; i++) {
        final item = rawSources[i];
        if (item is! Map) throw Exception('sources[$i] 必须是对象');
        final map = Map<String, dynamic>.from(item);
        final code = await _resolveSubscriptionCode(request, map, i);
        final metaOverride = <String, dynamic>{
          for (final key in [
            'id',
            'name',
            'apiVersion',
            'configFields',
            'loginUrl',
            'loginConfigKey',
            'supportsDiscover',
          ])
            if (map.containsKey(key)) key: map[key],
        };
        final existed = _stored.any(
          (e) => '${e['id']}' == '${map['id'] ?? ''}',
        );
        final meta = await _addInternal(
          code,
          persist: false,
          metaOverride: metaOverride.isEmpty ? null : metaOverride,
          subscriptionUrl: request.requestUrl,
          subscriptionId: id,
        );
        final sourceId = '${meta['id']}';
        seenIds.add(sourceId);
        final sourceIndex = _stored.indexWhere((e) => '${e['id']}' == sourceId);
        if (sourceIndex >= 0 && map.containsKey('enabled')) {
          _stored[sourceIndex]['enabled'] = map['enabled'] != false;
        }
        existed ? updated++ : added++;
      }

      if (seenIds.isEmpty && existingCount > 0) {
        LogService.instance.error(
          'SourceSub',
          '订阅同步没有拿到任何有效音源，已阻止删除本地音源',
          error: Exception('订阅无有效音源保护'),
        );
        throw Exception('订阅没有返回有效音源，已保留本地音源');
      }

      final removed = <String>[];
      _stored.removeWhere((source) {
        final sourceId = '${source['id']}';
        final shouldRemove =
            _sourceBelongsToSubscription(source, id) &&
            !seenIds.contains(sourceId);
        if (shouldRemove) {
          removed.add(sourceId);
          _registered.remove(sourceId);
        }
        return shouldRemove;
      });
      _subscriptionUrl = request.originalUrl;
      _subscriptions[idx]['originalUrl'] = request.originalUrl;
      _subscriptions[idx]['requestUrl'] = request.requestUrl;
      _subscriptions[idx]['version'] = payload.version;
      _subscriptions[idx]['lastUpdatedAt'] = _nowIso();
      _subscriptions[idx]['lastError'] = '';
      if (_activeId.isEmpty || !_stored.any((s) => '${s['id']}' == _activeId)) {
        _activeId = _firstEnabledId();
      }
      await _persist();
      LogService.instance.info(
        'SourceSub',
        '音源订阅同步完成',
        detail:
            '名称: ${subscription['name']}\n版本: ${payload.version.isEmpty ? '未声明' : payload.version}\n新增: $added\n更新: $updated\n删除: ${removed.length}\n总数: ${_stored.length}',
      );
      return SourceSubscriptionResult(
        added: added,
        updated: updated,
        removed: removed.length,
        total: _stored.length,
      );
    } catch (e, stack) {
      _subscriptions[idx]['lastError'] = e.toString().replaceFirst(
        'Exception: ',
        '',
      );
      await _persist();
      LogService.instance.error(
        'SourceSub',
        '音源订阅同步失败',
        error: e,
        stack: stack,
      );
      rethrow;
    }
  }

  Future<_SubscriptionPayload> _fetchSubscriptionPayload(
    Map<String, dynamic> subscription,
  ) async {
    final request = _SubscriptionRequest.parse(
      '${subscription['originalUrl'] ?? ''}',
    );
    if (request.originalUrl.isEmpty) throw Exception('订阅地址为空');
    LogService.instance.info(
      'SourceSub',
      '读取订阅源清单',
      detail: '名称: ${subscription['name']}\nURL: ${request.maskedUrl}',
    );
    final resp = await _dio.get<String>(
      request.requestUrl,
      options: Options(
        responseType: ResponseType.plain,
        receiveTimeout: const Duration(seconds: 30),
        validateStatus: (_) => true,
        headers: request.headers,
      ),
    );
    if ((resp.statusCode ?? 0) < 200 || (resp.statusCode ?? 0) >= 300) {
      throw Exception('订阅请求失败:${resp.statusCode}');
    }
    final raw = resp.data ?? '';
    final dynamic decoded = jsonDecode(raw);
    final rawSources = decoded is List
        ? decoded
        : (decoded is Map ? decoded['sources'] : null);
    if (rawSources is! List) throw Exception('订阅格式错误:缺少 sources 数组');
    final version = _subscriptionVersionOf(decoded);
    return _SubscriptionPayload(
      request: request,
      rawSources: rawSources,
      version: version,
    );
  }

  String _subscriptionVersionOf(dynamic decoded) {
    if (decoded is! Map) return '';
    for (final key in [
      'version',
      'subscriptionVersion',
      'sourceVersion',
      'updatedAt',
      'etag',
    ]) {
      final value = '${decoded[key] ?? ''}'.trim();
      if (value.isNotEmpty) return value;
    }
    return '';
  }

  Future<SourceSubscriptionResult> syncSubscription(String url) async {
    final subscription = await saveSubscription(url: url);
    return syncSubscriptionById(subscription.id);
  }

  Future<String> _resolveSubscriptionCode(
    _SubscriptionRequest request,
    Map<String, dynamic> item,
    int index,
  ) async {
    final directCode = '${item['code'] ?? ''}'.trim();
    if (directCode.isNotEmpty) return directCode;
    final rawUrl = '${item['url'] ?? item['sourceUrl'] ?? item['jsUrl'] ?? ''}'
        .trim();
    if (rawUrl.isEmpty) throw Exception('sources[$index] 缺少 code 或 url');
    final sourceUrl = _resolveUrl(request.requestUrl, rawUrl);
    final resp = await _dio.get<String>(
      sourceUrl,
      options: Options(
        responseType: ResponseType.plain,
        receiveTimeout: const Duration(seconds: 30),
        validateStatus: (_) => true,
        headers: request.headers,
      ),
    );
    if ((resp.statusCode ?? 0) < 200 || (resp.statusCode ?? 0) >= 300) {
      throw Exception('音源 JS 请求失败:${resp.statusCode} $sourceUrl');
    }
    final code = resp.data ?? '';
    if (code.trim().isEmpty) throw Exception('音源 JS 为空:$sourceUrl');
    return code;
  }

  String _resolveUrl(String baseUrl, String value) {
    final uri = Uri.tryParse(value);
    if (uri != null && uri.hasScheme) return uri.toString();
    final base = Uri.tryParse(baseUrl);
    return base == null ? value : base.resolve(value).toString();
  }

  Future<void> deleteSource(String id) async {
    String name = '';
    for (final source in _stored) {
      if ('${source['id']}' == id) {
        name = '${source['name']}';
        break;
      }
    }
    _stored.removeWhere((e) => '${e['id']}' == id);
    _registered.remove(id);
    if (_activeId == id) {
      _activeId = _firstEnabledId();
    }
    await _persist();
    LogService.instance.info('Source', '音源已删除', detail: '名称: $name\nID: $id');
  }

  Future<void> setActive(String id) async {
    final idx = _stored.indexWhere((e) => '${e['id']}' == id);
    if (idx < 0) return;
    _stored[idx]['enabled'] = true;
    _activeId = id;
    await _persist();
    LogService.instance.info(
      'Source',
      '切换当前音源',
      detail: '名称: ${_stored[idx]['name']}\nID: $id',
    );
  }

  Future<void> setEnabled(String id, bool enabled) async {
    final idx = _stored.indexWhere((e) => '${e['id']}' == id);
    if (idx < 0) return;
    _stored[idx]['enabled'] = enabled;
    if (!enabled && _activeId == id) {
      _activeId = _firstEnabledId(exceptId: id);
    } else if (enabled && _activeId.isEmpty) {
      _activeId = id;
    }
    await _persist();
    LogService.instance.info(
      'Source',
      enabled ? '音源已开启' : '音源已关闭',
      detail: '名称: ${_stored[idx]['name']}\nID: $id\n当前音源: $_activeId',
    );
  }

  Future<void> reorderSources(int oldIndex, int newIndex) async {
    await moveSource(oldIndex, newIndex, adjustsNewIndex: true);
  }

  Future<void> moveSource(
    int oldIndex,
    int newIndex, {
    bool adjustsNewIndex = false,
  }) async {
    if (oldIndex < 0 || oldIndex >= _stored.length) return;
    var target = newIndex;
    if (adjustsNewIndex && target > oldIndex) target -= 1;
    if (target < 0) target = 0;
    if (target >= _stored.length) target = _stored.length - 1;
    if (target == oldIndex) return;

    final item = _stored.removeAt(oldIndex);
    _stored.insert(target, item);
    await _persist();
    LogService.instance.info(
      'Source',
      '音源排序已更新',
      detail: '名称: ${item['name']}\nID: ${item['id']}\n位置: ${target + 1}',
    );
  }

  Map<String, dynamic> getSourceConfig(String id) {
    for (final s in _stored) {
      if ('${s['id']}' == id) return _declaredConfigOf(s);
    }
    return <String, dynamic>{};
  }

  String getSourceName(String id) {
    for (final s in _stored) {
      if ('${s['id']}' == id) return '${s['name']}';
    }
    return id;
  }

  List<SourceConfigField> getSourceConfigFields(String id) {
    for (final s in _stored) {
      if ('${s['id']}' == id) return _configFieldsOf(s);
    }
    return const [];
  }

  bool sourceHasConfig(String id) => getSourceConfigFields(id).isNotEmpty;

  bool sourceHasLoginConfig(String id) {
    return getSourceConfigFields(id).any(isLoginConfigField);
  }

  bool sourceHasSettingConfig(String id) {
    return getSourceConfigFields(id).isNotEmpty;
  }

  String getSourceLoginUrl(String id) {
    for (final s in _stored) {
      if ('${s['id']}' == id) return _loginUrlOf(s);
    }
    return '';
  }

  String getSourceLoginConfigKey(String id) {
    for (final s in _stored) {
      if ('${s['id']}' == id) return _loginConfigKeyOf(s);
    }
    return '';
  }

  static bool isLoginConfigField(SourceConfigField field) {
    final key = field.key.toLowerCase();
    final label = field.label.toLowerCase();
    return key.contains('cookie') ||
        key.contains('token') ||
        key.contains('authorization') ||
        key.contains('auth') ||
        key.contains('login') ||
        key.contains('account') ||
        key.contains('username') ||
        key.contains('password') ||
        label.contains('cookie') ||
        label.contains('token') ||
        label.contains('登录') ||
        label.contains('账号') ||
        label.contains('密码');
  }

  Future<void> setSourceConfig(String id, Map<String, dynamic> config) async {
    final idx = _stored.indexWhere((e) => '${e['id']}' == id);
    if (idx < 0) throw Exception('音源不存在: $id');
    final fields = _configFieldsOf(_stored[idx]);
    if (fields.isEmpty) throw Exception('这个音源没有声明需要配置');
    _stored[idx]['config'] = _filterConfig(config, fields);
    await _persist();
    if (_registered.contains(id)) {
      await _applyConfig(_stored[idx]);
    }
    LogService.instance.info(
      'Source',
      '音源配置已保存',
      detail:
          '名称: ${_stored[idx]['name']}\nID: $id\n${configSummary(_declaredConfigOf(_stored[idx]))}',
    );
  }

  static String configSummary(Map<String, dynamic> config) {
    if (config.isEmpty) return '配置: 未设置';
    return config.keys.map((key) => '$key: 已设置').join('\n');
  }

  String _firstEnabledId({String exceptId = ''}) {
    for (final s in _stored) {
      final id = '${s['id']}';
      if (id != exceptId && s['enabled'] != false) return id;
    }
    return '';
  }

  String get activeId => _activeId;

  List<SourceMeta> getSources() => _stored
      .map(
        (s) => SourceMeta(
          id: '${s['id']}',
          name: '${s['name']}',
          loginUrl: _loginUrlOf(s),
          loginConfigKey: _loginConfigKeyOf(s),
          apiVersion: (s['apiVersion'] is num)
              ? (s['apiVersion'] as num).toInt()
              : (int.tryParse('${s['apiVersion']}') ?? SourceContract.version),
          configFields: _configFieldsOf(s),
          supportsDiscover: s['supportsDiscover'] == true,
          active: '${s['id']}' == _activeId,
          enabled: s['enabled'] != false,
        ),
      )
      .toList();

  Map<String, dynamic>? get _active {
    if (_stored.isEmpty) return null;
    for (final s in _stored) {
      if ('${s['id']}' == _activeId && s['enabled'] != false) return s;
    }
    for (final s in _stored) {
      if (s['enabled'] != false) return s;
    }
    return null;
  }

  // ── 高层接口:路由到当前激活音源 ──

  Future<SearchResult> search(
    String keyword, {
    int page = 1,
    int pageSize = 20,
  }) async {
    final s = _active;
    if (s == null) throw Exception('未设置音源');
    return searchFromSource(
      '${s['id']}',
      keyword,
      page: page,
      pageSize: pageSize,
    );
  }

  Future<SearchResult> searchFromSource(
    String sourceId,
    String keyword, {
    int page = 1,
    int pageSize = 20,
  }) async {
    final s = _stored.firstWhere(
      (e) => '${e['id']}' == sourceId && e['enabled'] != false,
      orElse: () => <String, dynamic>{},
    );
    if (s.isEmpty) throw Exception('音源未开启');
    await _ensureRegistered(s);
    final ret = await JsEngine.instance.call(sourceId, 'search', [
      keyword,
      page,
      pageSize,
    ]);
    return SourceContract.parseSearchResult(
      ret,
      sourceId: sourceId,
      sourceName: '${s['name'] ?? sourceId}',
    );
  }

  Future<CatalogResult> getChapters(
    String bookId, {
    int page = 1,
    int pageSize = catalogPageSize,
  }) async {
    final s = _active;
    if (s == null) throw Exception('未设置音源');
    return getChaptersFromSource(
      '${s['id']}',
      bookId,
      page: page,
      pageSize: pageSize,
    );
  }

  Future<CatalogResult> getChaptersFromSource(
    String sourceId,
    String bookId, {
    int page = 1,
    int pageSize = catalogPageSize,
  }) async {
    final s = _stored.firstWhere(
      (e) => '${e['id']}' == sourceId && e['enabled'] != false,
      orElse: () => <String, dynamic>{},
    );
    if (s.isEmpty) throw Exception('音源未开启');
    await _ensureRegistered(s);
    final ret = await JsEngine.instance.call(sourceId, 'getChapters', [
      bookId,
      page,
      pageSize,
    ]);
    return SourceContract.parseCatalogResult(
      ret,
      sourceId: sourceId,
      sourceName: '${s['name'] ?? sourceId}',
    );
  }

  Future<AudioResult> getAudioUrl(String chapterId) async {
    final s = _active;
    if (s == null) throw Exception('未设置音源');
    return getAudioUrlFromSource('${s['id']}', chapterId);
  }

  Future<AudioResult> getAudioUrlFromSource(
    String sourceId,
    String chapterId,
  ) async {
    final s = _stored.firstWhere(
      (e) => '${e['id']}' == sourceId && e['enabled'] != false,
      orElse: () => <String, dynamic>{},
    );
    if (s.isEmpty) throw Exception('音源未开启');
    await _ensureRegistered(s);
    final ret = await JsEngine.instance.call(sourceId, 'getAudioUrl', [
      chapterId,
    ]);
    return SourceContract.parseAudioResult(
      ret,
      sourceId: sourceId,
      sourceName: '${s['name'] ?? sourceId}',
    );
  }

  /// 调用音源的 discover() 获取首页/分类内容(音源可选实现)。
  /// 音源未实现 discover 时抛出明确异常,供调用方降级处理。
  Future<DiscoverResult> discoverFromSource(String sourceId) async {
    final s = _stored.firstWhere(
      (e) => '${e['id']}' == sourceId && e['enabled'] != false,
      orElse: () => <String, dynamic>{},
    );
    if (s.isEmpty) throw Exception('音源未开启');
    if (s['supportsDiscover'] != true) {
      throw Exception('该音源未实现 discover');
    }
    await _ensureRegistered(s);
    final ret = await JsEngine.instance.call(sourceId, 'discover', const []);
    return SourceContract.parseDiscoverResult(
      ret,
      sourceId: sourceId,
      sourceName: '${s['name'] ?? sourceId}',
    );
  }
}
