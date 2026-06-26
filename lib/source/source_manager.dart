import 'dart:convert';
import 'package:flutter/services.dart' show rootBundle;
import 'package:shared_preferences/shared_preferences.dart';

import '../data/catalog_cache_service.dart';
import '../data/log_service.dart';
import 'js_engine.dart';
import 'models.dart';
import 'source_contract.dart';

/// 音源管理器:对齐 uni-app 版 sourceLoader 的能力。
/// - 音源 code + 启用状态 + 激活ID 存 shared_preferences
/// - 首次启动预置内置示例音源(assets)
/// - 高层 search/getChapters/getAudioUrl 路由到当前激活音源
class SourceManager {
  SourceManager._();
  static final SourceManager instance = SourceManager._();
  static const int catalogPageSize = 30;

  static const _kSources = 'audio_sources'; // List<json:{id,name,code,enabled}>
  static const _kActive = 'active_source_id';

  // 首启预置的内置音源 assets。内置源启动时只登记元信息,首次使用时再编译
  // JS,避免启动阶段一次性编译十几个音源导致主线程长时间卡顿。
  static const _bundled = [
    _BundledSource('assets/sources/yuanqi.js', 'yuanqi', '元气听书'),
    _BundledSource('assets/sources/beiji-kuwo.js', 'beiji-kuwo', '北极听书'),
    _BundledSource('assets/sources/ytysxs.js', 'ytysxs', '雨听有声小说'),
    _BundledSource(
      'assets/sources/qingtian-xmly.js',
      'qt-ximalaya',
      '青天·喜马拉雅',
      loginUrl: 'https://v1.gyks.cf/login',
      loginConfigKey: 'qt_cookie',
      configFields: [
        {
          'key': 'qt_cookie',
          'label': '青天 Cookie',
          'type': 'textarea',
          'hint': '可通过音源登录页自动获取。',
          'login': true,
          'required': true,
        },
      ],
    ),
    _BundledSource(
      'assets/sources/qingtian-fanqie.js',
      'qt-fanqie',
      '青天·番茄',
      loginUrl: 'https://v1.gyks.cf/login',
      loginConfigKey: 'qt_cookie',
      configFields: [
        {
          'key': 'qt_cookie',
          'label': '青天 Cookie',
          'type': 'textarea',
          'hint': '可通过音源登录页自动获取。',
          'login': true,
          'required': true,
        },
      ],
    ),
    _BundledSource(
      'assets/sources/qingtian-kuwo.js',
      'qt-kuwo',
      '青天·酷我',
      loginUrl: 'https://v1.gyks.cf/login',
      loginConfigKey: 'qt_cookie',
      configFields: [
        {
          'key': 'qt_cookie',
          'label': '青天 Cookie',
          'type': 'textarea',
          'hint': '可通过音源登录页自动获取。',
          'login': true,
          'required': true,
        },
      ],
    ),
    _BundledSource(
      'assets/sources/qingtian-qimao.js',
      'qt-qimao',
      '青天·七猫',
      loginUrl: 'https://v1.gyks.cf/login',
      loginConfigKey: 'qt_cookie',
      configFields: [
        {
          'key': 'qt_cookie',
          'label': '青天 Cookie',
          'type': 'textarea',
          'hint': '可通过音源登录页自动获取。',
          'login': true,
          'required': true,
        },
      ],
    ),
    _BundledSource(
      'assets/sources/eprendre-bilibili.js',
      'eprendre-bilibili',
      'BiliBili',
    ),
    _BundledSource(
      'assets/sources/eprendre-bokan-yousheng.js',
      'eprendre-bokan-yousheng',
      '博看有声',
    ),
    _BundledSource('assets/sources/eprendre-cnr.js', 'eprendre-cnr', '云听'),
    _BundledSource(
      'assets/sources/eprendre-haiyang.js',
      'eprendre-haiyang',
      '海洋听书网',
      configFields: [
        {'key': 'cookie', 'label': '海洋 Cookie', 'type': 'textarea'},
      ],
    ),
    _BundledSource('assets/sources/eprendre-ifish.js', 'eprendre-ifish', '爱听书'),
    _BundledSource('assets/sources/eprendre-jdlg.js', 'eprendre-jdlg', '静读乐听'),
    _BundledSource('assets/sources/eprendre-jihe.js', 'eprendre-jihe', '鸡盒盘'),
    _BundledSource(
      'assets/sources/eprendre-koudai-weiketang.js',
      'eprendre-koudai-weiketang',
      '口袋微课堂',
    ),
    _BundledSource('assets/sources/eprendre-kuwo.js', 'eprendre-kuwo', '酷我畅听'),
    _BundledSource(
      'assets/sources/eprendre-lanren.js',
      'eprendre-lanren',
      '懒人听书',
      loginUrl: 'https://m.lrts.me/user',
      loginConfigKey: 'cookie',
      configFields: [
        {
          'key': 'cookie',
          'label': '懒人 Cookie',
          'type': 'textarea',
          'hint': '可通过音源登录页自动获取。',
          'login': true,
        },
      ],
    ),
    _BundledSource(
      'assets/sources/eprendre-pingshu5.js',
      'eprendre-pingshu5',
      '单田芳评书网',
    ),
    _BundledSource(
      'assets/sources/eprendre-ting74.js',
      'eprendre-ting74',
      '听书74',
    ),
    _BundledSource('assets/sources/eprendre-vbus.js', 'eprendre-vbus', 'VBus'),
    _BundledSource(
      'assets/sources/eprendre-ysxs8.js',
      'eprendre-ysxs8',
      '有声小说吧',
      configFields: [
        {'key': 'cookie', 'label': '有声小说吧 Cookie', 'type': 'textarea'},
      ],
    ),
    _BundledSource(
      'assets/sources/eprendre-yuntu-yousheng.js',
      'eprendre-yuntu-yousheng',
      '云图有声',
    ),
    _BundledSource(
      'assets/sources/tj-yuetingba.js',
      'tingshu-json-yuetingba',
      '悦听吧',
    ),
    _BundledSource(
      'assets/sources/tj-yuanqi-ximalaya.js',
      'tingshu-json-yuanqi-ximalaya',
      '元气听书-喜马拉雅',
    ),
    _BundledSource(
      'assets/sources/tj-ting13.js',
      'tingshu-json-ting13',
      '13听书网',
    ),
    _BundledSource('assets/sources/tj-qiting.js', 'tingshu-json-qiting', '奇听网'),
    _BundledSource(
      'assets/sources/tj-tingyou-worker.js',
      'tingshu-json-tingyou',
      '听友FM（Worker）',
    ),
    _BundledSource(
      'assets/sources/tj-i275-worker.js',
      'tingshu-json-i275',
      '275听书网（Worker）',
    ),
    _BundledSource(
      'assets/sources/tj-leting-worker.js',
      'tingshu-json-leting',
      '乐听网（Worker）',
    ),
    _BundledSource(
      'assets/sources/tj-shuyinfm.js',
      'tingshu-json-shuyinfm',
      '天下书音',
    ),
    _BundledSource('assets/sources/tingyou.js', 'tingyou', '听优有声'),
  ];

  final List<Map<String, dynamic>> _stored = []; // {id,name,code,enabled}
  String _activeId = '';
  final Set<String> _registered = {}; // 已在 JS 引擎注册的音源 id
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

    // 每次启动刷新内置音源代码,保留用户的启用/关闭状态。
    for (final bundled in _bundled) {
      try {
        final code = await rootBundle.loadString(bundled.path);
        await _addInternal(code, persist: false, bundled: bundled);
      } catch (e) {
        LogService.instance.warning(
          'Source',
          '内置音源刷新失败',
          detail: '路径: ${bundled.path}\n错误: $e',
        );
      }
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
  }

  // 注册到 JS 引擎(幂等)
  Future<void> _ensureRegistered(Map<String, dynamic> s) async {
    final id = '${s['id']}';
    if (!_registered.contains(id)) {
      await JsEngine.instance.loadSource('${s['code']}');
      _registered.add(id);
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
    _BundledSource? bundled,
  }) async {
    final meta = bundled?.toMeta() ?? await JsEngine.instance.loadSource(code);
    final id = meta['id']!;
    if (bundled == null) _registered.add(id);
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

class _BundledSource {
  final String path;
  final String id;
  final String name;
  final String loginUrl;
  final String loginConfigKey;
  final List<Map<String, dynamic>> configFields;

  const _BundledSource(
    this.path,
    this.id,
    this.name, {
    this.loginUrl = '',
    this.loginConfigKey = '',
    this.configFields = const [],
  });

  Map<String, dynamic> toMeta() => {
    'id': id,
    'name': name,
    'apiVersion': '${SourceContract.version}',
    'configFields': configFields,
    'loginUrl': loginUrl,
    'loginConfigKey': loginConfigKey,
  };
}
