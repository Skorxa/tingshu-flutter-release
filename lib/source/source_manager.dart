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

/// 音源管理器:对齐 uni-app 版 sourceLoader 的能力。
/// - 音源 code + 启用状态 + 激活ID 存 shared_preferences
/// - 音源订阅 URL 存 shared_preferences,同步后把云端 JS 源落到本地
/// - 高层 search/getChapters/getAudioUrl 路由到当前激活音源
class SourceManager {
  SourceManager._();
  static final SourceManager instance = SourceManager._();
  static const int catalogPageSize = 30;

  static const _kSources = 'audio_sources'; // List<json:{id,name,code,enabled}>
  static const _kActive = 'active_source_id';
  static const _kSubscriptionUrl = 'audio_source_subscription_url';

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
  final Dio _dio = Dio();
  String _activeId = '';
  String _subscriptionUrl = '';
  final Set<String> _registered = {}; // 已在 JS 引擎注册的音源 id
  final Map<String, Future<void>> _registering = {};
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

    final before = _stored.length;
    _stored.removeWhere(
      (source) => _removedBundledIds.contains('${source['id']}'),
    );
    if (before != _stored.length) {
      _registered.removeWhere(_removedBundledIds.contains);
      if (_removedBundledIds.contains(_activeId)) _activeId = _firstEnabledId();
      LogService.instance.info(
        'Source',
        '已移除旧版内置音源',
        detail: '删除数量: ${before - _stored.length}',
      );
    }
    await _persist();

    if (_activeId.isEmpty && _stored.isNotEmpty) {
      _activeId = '${_stored.first['id']}';
    }
    _ready = true;
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kSources, jsonEncode(_stored));
    await prefs.setString(_kActive, _activeId);
    await prefs.setString(_kSubscriptionUrl, _subscriptionUrl);
  }

  // 注册到 JS 引擎(幂等)
  Future<void> _ensureRegistered(Map<String, dynamic> s) async {
    final id = '${s['id']}';
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
  }) async {
    final parsed = await JsEngine.instance.loadSource(code);
    final meta = {...parsed, ...?metaOverride};
    final id = meta['id']!;
    _registered.add(id);
    final idx = _stored.indexWhere((e) => '${e['id']}' == id);
    final entry = <String, dynamic>{
      'id': id,
      'name': meta['name'],
      'apiVersion': meta['apiVersion'] ?? '${SourceContract.version}',
      'configFields': (meta['configFields'] as List?) ?? const [],
      'loginUrl': '${meta['loginUrl'] ?? ''}',
      'loginConfigKey': '${meta['loginConfigKey'] ?? ''}',
      'code': code,
      'enabled': idx >= 0 ? _stored[idx]['enabled'] != false : true,
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

  Future<SourceSubscriptionResult> syncSubscription(String url) async {
    final normalized = url.trim();
    if (normalized.isEmpty) throw Exception('订阅地址为空');
    LogService.instance.info(
      'SourceSub',
      '开始同步音源订阅',
      detail: 'URL: $normalized',
    );
    final resp = await _dio.get<String>(
      normalized,
      options: Options(
        responseType: ResponseType.plain,
        receiveTimeout: const Duration(seconds: 30),
        validateStatus: (_) => true,
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

    final seenIds = <String>{};
    var added = 0;
    var updated = 0;
    for (var i = 0; i < rawSources.length; i++) {
      final item = rawSources[i];
      if (item is! Map) throw Exception('sources[$i] 必须是对象');
      final map = Map<String, dynamic>.from(item);
      final code = await _resolveSubscriptionCode(normalized, map, i);
      final metaOverride = <String, dynamic>{
        for (final key in [
          'id',
          'name',
          'apiVersion',
          'configFields',
          'loginUrl',
          'loginConfigKey',
        ])
          if (map.containsKey(key)) key: map[key],
      };
      final existed = _stored.any((e) => '${e['id']}' == '${map['id'] ?? ''}');
      final meta = await _addInternal(
        code,
        persist: false,
        metaOverride: metaOverride.isEmpty ? null : metaOverride,
        subscriptionUrl: normalized,
      );
      final id = '${meta['id']}';
      seenIds.add(id);
      final idx = _stored.indexWhere((e) => '${e['id']}' == id);
      if (idx >= 0 && map.containsKey('enabled')) {
        _stored[idx]['enabled'] = map['enabled'] != false;
      }
      existed ? updated++ : added++;
    }

    final removed = <String>[];
    _stored.removeWhere((source) {
      final id = '${source['id']}';
      final shouldRemove =
          '${source['subscriptionUrl'] ?? ''}' == normalized &&
          !seenIds.contains(id);
      if (shouldRemove) {
        removed.add(id);
        _registered.remove(id);
      }
      return shouldRemove;
    });
    _subscriptionUrl = normalized;
    if (_activeId.isEmpty || !_stored.any((s) => '${s['id']}' == _activeId)) {
      _activeId = _firstEnabledId();
    }
    await _persist();
    LogService.instance.info(
      'SourceSub',
      '音源订阅同步完成',
      detail:
          '新增: $added\n更新: $updated\n删除: ${removed.length}\n总数: ${_stored.length}',
    );
    return SourceSubscriptionResult(
      added: added,
      updated: updated,
      removed: removed.length,
      total: _stored.length,
    );
  }

  Future<String> _resolveSubscriptionCode(
    String subscriptionUrl,
    Map<String, dynamic> item,
    int index,
  ) async {
    final directCode = '${item['code'] ?? ''}'.trim();
    if (directCode.isNotEmpty) return directCode;
    final rawUrl = '${item['url'] ?? item['sourceUrl'] ?? item['jsUrl'] ?? ''}'
        .trim();
    if (rawUrl.isEmpty) throw Exception('sources[$index] 缺少 code 或 url');
    final sourceUrl = _resolveUrl(subscriptionUrl, rawUrl);
    final resp = await _dio.get<String>(
      sourceUrl,
      options: Options(
        responseType: ResponseType.plain,
        receiveTimeout: const Duration(seconds: 30),
        validateStatus: (_) => true,
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
}
