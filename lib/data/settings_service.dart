import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SettingsService extends ChangeNotifier {
  SettingsService._();
  static final instance = SettingsService._();

  static const cacheChapterOptions = [1, 3, 5, 10, 20, 30, 50, 80];
  static const cleanupLimitOptions = [
    0,
    50,
    80,
    100,
    120,
    150,
    200,
    400,
    500,
    1000,
  ];
  static const cacheSpaceLimitOptions = [
    0, // 不限制
    500, // 500 MB
    1024, // 1 GB
    2048, // 2 GB
    5120, // 5 GB
    10240, // 10 GB
    20480, // 20 GB
  ];

  static const _kDarkMode = 'settings_dark_mode';
  static const _kAutoCache = 'settings_auto_cache';
  static const _kMaxCacheChapters = 'settings_max_cache_chapters';
  static const _kCacheFrequency = 'settings_cache_frequency';
  static const _kCleanupLimit = 'settings_cleanup_limit';
  static const _kCacheSpaceLimit = 'settings_cache_space_limit';
  static const _kAndroidAudioOffload = 'settings_android_audio_offload';
  static const _kAggregateSearch = 'settings_aggregate_search';
  static const _kDynamicColor = 'settings_dynamic_color';
  static const _kSearchMatchMode = 'settings_search_match_mode';
  static const _kUpdateManifestUrl = 'settings_update_manifest_url';
  static const _kDiscoverSourceIds = 'settings_discover_source_ids';
 static const _kDiscoverSelectionConfigured =
     'settings_discover_selection_configured';

  bool _darkMode = false;
  bool _androidAudioOffload = false;
  bool _aggregateSearch = true;
  bool _dynamicColor = true;
  String _searchMatchMode = 'fuzzy';
  bool _autoCache = false;
  int _maxCacheChapters = 3;
  String _cacheFrequency = 'standard';
  int _cleanupLimit = 100;
  int _cacheSpaceLimit = 0; // 0 表示不限制，单位 MB
  String _updateManifestUrl = '';
 List<String> _discoverSourceIds = [];
 bool _discoverSelectionConfigured = false;
 int _discoverRevision = 0;
 bool _ready = false;

  bool get darkMode => _darkMode;
  bool get androidAudioOffload => _androidAudioOffload;
  bool get aggregateSearch => _aggregateSearch;
  bool get dynamicColor => _dynamicColor;
  String get searchMatchMode => _searchMatchMode;
  bool get autoCache => _autoCache;
  int get maxCacheChapters => _maxCacheChapters;
  String get cacheFrequency => _cacheFrequency;
  int get cleanupLimit => _cleanupLimit;
  int get cacheSpaceLimit => _cacheSpaceLimit;
  String get updateManifestUrl => _updateManifestUrl;
  List<String> get discoverSourceIds => List.unmodifiable(_discoverSourceIds);
 bool get discoverSelectionConfigured => _discoverSelectionConfigured;
 int get discoverRevision => _discoverRevision;
 bool get ready => _ready;

  // ── 双模态:应用模式(tingshu / music) ──
  static const _kAppMode = 'settings_app_mode';
  String _appMode = 'tingshu';
  String get appMode => _appMode;
  bool get isMusicMode => _appMode == 'music';
  String get appModeLabel => _appMode == 'music' ? '音乐模式' : '听书模式';

  bool isDiscoverSourceSelected(String sourceId) {
    return !_discoverSelectionConfigured ||
        _discoverSourceIds.contains(sourceId);
  }

  int get cacheFrequencyMinutes => _cacheFrequency == 'fast' ? 3 : 1;

  String get cacheFrequencyLabel =>
      _cacheFrequency == 'fast' ? '快（3分钟）' : '标准（1分钟）';

  String get cleanupLimitLabel =>
      _cleanupLimit == 0 ? '不清理' : '$_cleanupLimit 集';

  String get cacheSpaceLimitLabel {
    if (_cacheSpaceLimit == 0) return '不限制';
    if (_cacheSpaceLimit >= 1024) {
      return '${(_cacheSpaceLimit / 1024).toStringAsFixed(0)} GB';
    }
    return '$_cacheSpaceLimit MB';
  }

  String get searchMatchModeLabel =>
      _searchMatchMode == 'exact' ? '精确搜索' : '模糊搜索';

  Future<void> init() async {
    if (_ready) return;
    final prefs = await SharedPreferences.getInstance();
    _darkMode = prefs.getBool(_kDarkMode) ?? false;
    _androidAudioOffload = prefs.getBool(_kAndroidAudioOffload) ?? false;
    _aggregateSearch = prefs.getBool(_kAggregateSearch) ?? true;
    _dynamicColor = prefs.getBool(_kDynamicColor) ?? true;
    final matchMode = prefs.getString(_kSearchMatchMode);
    _searchMatchMode = matchMode == 'exact' ? 'exact' : 'fuzzy';
    _autoCache = prefs.getBool(_kAutoCache) ?? false;
    _maxCacheChapters = _validInt(
      prefs.getInt(_kMaxCacheChapters),
      cacheChapterOptions,
      3,
    );
    final freq = prefs.getString(_kCacheFrequency);
    _cacheFrequency = freq == 'fast' ? 'fast' : 'standard';
    _cleanupLimit = _validInt(
      prefs.getInt(_kCleanupLimit),
      cleanupLimitOptions,
      100,
    );
    _cacheSpaceLimit = _validInt(
      prefs.getInt(_kCacheSpaceLimit),
      cacheSpaceLimitOptions,
      0,
    );
    _updateManifestUrl = prefs.getString(_kUpdateManifestUrl) ?? '';
    _discoverSourceIds = (prefs.getStringList(_kDiscoverSourceIds) ?? const [])
        .where((id) => id.trim().isNotEmpty)
        .toList();
   _discoverSelectionConfigured =
       prefs.getBool(_kDiscoverSelectionConfigured) ?? false;
    _appMode = prefs.getString(_kAppMode) ?? 'tingshu';
   _ready = true;
  }

  int _validInt(int? value, List<int> options, int fallback) {
    return value != null && options.contains(value) ? value : fallback;
  }

  Future<void> setDarkMode(bool value) async {
    _darkMode = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kDarkMode, value);
  }

  Future<void> setAndroidAudioOffload(bool value) async {
    _androidAudioOffload = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kAndroidAudioOffload, value);
  }

  Future<void> setAggregateSearch(bool value) async {
    _aggregateSearch = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kAggregateSearch, value);
  }

  Future<void> setDynamicColor(bool value) async {
    _dynamicColor = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kDynamicColor, value);
  }

  Future<void> setSearchMatchMode(String value) async {
    if (value != 'fuzzy' && value != 'exact') return;
    _searchMatchMode = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kSearchMatchMode, value);
  }

  Future<void> setAutoCache(bool value) async {
    _autoCache = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kAutoCache, value);
  }

  Future<void> setMaxCacheChapters(int value) async {
    if (!cacheChapterOptions.contains(value)) return;
    _maxCacheChapters = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kMaxCacheChapters, value);
  }

  Future<void> setCacheFrequency(String value) async {
    if (value != 'standard' && value != 'fast') return;
    _cacheFrequency = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kCacheFrequency, value);
  }

  Future<void> setCleanupLimit(int value) async {
    if (!cleanupLimitOptions.contains(value)) return;
    _cleanupLimit = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kCleanupLimit, value);
  }

  Future<void> setCacheSpaceLimit(int value) async {
    if (!cacheSpaceLimitOptions.contains(value)) return;
    _cacheSpaceLimit = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kCacheSpaceLimit, value);
  }

  Future<void> setUpdateManifestUrl(String value) async {
    _updateManifestUrl = value.trim();
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kUpdateManifestUrl, _updateManifestUrl);
  }

 Future<void> setDiscoverSourceIds(List<String> ids) async {
    final next = <String>[];
    final seen = <String>{};
    for (final id in ids) {
      final value = id.trim();
      if (value.isNotEmpty && seen.add(value)) next.add(value);
    }
    _discoverSourceIds = next;
    _discoverSelectionConfigured = true;
    _discoverRevision++;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_kDiscoverSourceIds, _discoverSourceIds);
    await prefs.setBool(_kDiscoverSelectionConfigured, true);
  }

  Future<void> setAppMode(String mode) async {
    if (mode != 'tingshu' && mode != 'music') return;
    _appMode = mode;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kAppMode, mode);
  }
}
