import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/log_service.dart';
import 'models.dart';
import 'music_source.dart';
import 'platforms/kuwo_source.dart';

/// 管理内置音乐平台与自定义音乐源。
///
/// 音乐模式下由 [MusicPlayerService] 和 UI 层调用,
/// 与听书侧 [SourceManager] 完全隔离。
class MusicSourceManager extends ChangeNotifier {
  MusicSourceManager._();
  static final instance = MusicSourceManager._();

  final Map<String, MusicSource> _sources = {};
  String _activeSourceId = 'kuwo';
  bool _ready = false;

  bool get ready => _ready;
  String get activeSourceId => _activeSourceId;

  /// 所有已注册音源(内置 + 自定义)
  List<MusicSourceMeta> get metas {
    return _sources.values.map((s) {
      final isCustom = s.id.startsWith('custom:');
      return MusicSourceMeta(
        id: s.id,
        name: s.name,
        requiresLogin: s.requiresLogin,
        isBuiltin: !isCustom,
      );
    }).toList();
  }

  MusicSource? get active =>
      _sources[_activeSourceId] ?? _sources['kuwo'];

  MusicSource? getSource(String id) => _sources[id];

  Future<void> init() async {
    // 注册内置平台
    _register(KuwoSource());
    // Phase 2: _register(WySource());
    // Phase 4: _register(KgSource()); _register(TxSource());
    _ready = true;
    LogService.instance.info('MusicSource', '音乐源初始化完成', detail: '已加载 ${_sources.length} 个平台');
    notifyListeners();
  }

  /// 幂等初始化:运行时模式切换时调用,避免重启 main()。
  Future<void> ensureInitialized() async {
    if (_ready) return;
    await init();
  }

  void _register(MusicSource source) {
    _sources[source.id] = source;
  }

  void setActiveSource(String id) {
    if (!_sources.containsKey(id)) return;
    if (_activeSourceId == id) return;
    _activeSourceId = id;
    final source = _sources[id]!;
    LogService.instance.info('MusicSource', '切换音乐平台', detail: '平台: ${source.name}');
    notifyListeners();
  }

  Future<MusicSearchResult> search(
    String keyword, {
    int page = 1,
    int limit = 30,
  }) async {
    final source = active;
    if (source == null) throw Exception('没有可用的音乐平台');
    return source.search(keyword, page: page, limit: limit);
  }

  /// 聚合搜索:同时搜索所有已启用的平台
  Future<Map<String, MusicSearchResult>> aggregateSearch(
    String keyword, {
    int page = 1,
    int limit = 20,
  }) async {
    final futures = <String, Future<MusicSearchResult>>{};
    for (final source in _sources.values) {
      futures[source.id] = source
          .search(keyword, page: page, limit: limit)
          .catchError((e) => MusicSearchResult(list: [], page: page, maxPage: 1, hasMore: false));
    }
    final results = <String, MusicSearchResult>{};
    for (final entry in futures.entries) {
      try {
        results[entry.key] = await entry.value;
      } catch (_) {
        results[entry.key] = MusicSearchResult(list: [], page: page, maxPage: 1, hasMore: false);
      }
    }
    return results;
  }

  Future<({String url, Map<String, String> headers})> getMusicUrl(
    String sourceId,
    String songId, {
    String? quality,
  }) async {
    final source = _sources[sourceId] ?? active;
    if (source == null) throw Exception('音源不存在: $sourceId');
    return source.getMusicUrl(songId, quality: quality);
  }

  Future<Lyric> getLyric(String sourceId, String songId) async {
    final source = _sources[sourceId] ?? active;
    if (source == null) return Lyric.empty;
    try {
      return await source.getLyric(songId);
    } catch (e) {
      LogService.instance.warning('MusicSource', '获取歌词失败', detail: '$e');
      return Lyric.empty;
    }
  }

  Future<String> getPic(String sourceId, String songId) async {
    final source = _sources[sourceId] ?? active;
    if (source == null) return '';
    try {
      return await source.getPic(songId);
    } catch (_) {
      return '';
    }
  }
}
