import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/log_service.dart';
import '../../widgets/cover_image.dart';
import '../models.dart';
import '../music_player_service.dart';
import '../music_source_manager.dart';
import 'music_now_playing_screen.dart';

class MusicSearchScreen extends StatefulWidget {
  const MusicSearchScreen({super.key});

  @override
  State<MusicSearchScreen> createState() => _MusicSearchScreenState();
}

class _MusicSearchScreenState extends State<MusicSearchScreen> {
  final _ctrl = TextEditingController();
  final _scrollController = ScrollController();
  final List<MusicInfo> _results = [];
  String _keyword = '';
  int _page = 1;
  bool _hasMore = false;
  bool _loading = false;
  String? _error;

 @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _ctrl.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients || _loading || !_hasMore) return;
    if (_scrollController.position.extentAfter <= 320) {
      _loadMore();
    }
  }

  Future<void> _search() async {
    final keyword = _ctrl.text.trim();
    if (keyword.isEmpty) return;
    setState(() {
      _keyword = keyword;
      _results.clear();
      _page = 1;
      _loading = true;
      _error = null;
    });
    try {
      final result = await MusicSourceManager.instance.search(keyword, page: 1);
      setState(() {
        _results.addAll(result.list);
        _hasMore = result.hasMore;
        _loading = false;
      });
    } catch (e) {
      LogService.instance.error('MusicSearch', '搜索失败', error: e);
      setState(() {
        _error = e.toString().replaceFirst('Exception: ', '');
        _loading = false;
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loading || !_hasMore || _keyword.isEmpty) return;
    setState(() => _loading = true);
    try {
      final result = await MusicSourceManager.instance.search(
        _keyword,
        page: _page + 1,
      );
      setState(() {
        _page++;
        _results.addAll(result.list);
        _hasMore = result.hasMore;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _loading = false;
        _hasMore = false;
      });
    }
  }

  void _playSong(int index) {
    MusicPlayerService.instance.playQueue(_results, startIndex: index);
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const MusicNowPlayingScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final mgr = MusicSourceManager.instance;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _ctrl,
                      textInputAction: TextInputAction.search,
                      onSubmitted: (_) => _search(),
                      decoration: InputDecoration(
                        hintText: '搜索歌曲、歌手',
                        prefixIcon: const Icon(Icons.search),
                        suffixIcon: _ctrl.text.isNotEmpty
                            ? IconButton(
                                icon: const Icon(Icons.clear),
                                onPressed: () {
                                  _ctrl.clear();
                                  setState(() {
                                    _results.clear();
                                    _keyword = '';
                                  });
                                },
                              )
                            : null,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(28),
                        ),
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _loading ? null : _search,
                    child: const Text('搜索'),
                  ),
                ],
              ),
            ),
            // 平台切换条
            AnimatedBuilder(
              animation: mgr,
              builder: (context, _) {
                final metas = mgr.metas;
                return SizedBox(
                  height: 40,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemCount: metas.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 8),
                    itemBuilder: (context, i) {
                      final meta = metas[i];
                      final selected = meta.id == mgr.activeSourceId;
                      return FilterChip(
                        label: Text(meta.name),
                        selected: selected,
                        onSelected: (_) {
                          mgr.setActiveSource(meta.id);
                          if (_keyword.isNotEmpty) _search();
                        },
                      );
                    },
                  ),
                );
              },
            ),
            Expanded(child: _buildResults(cs)),
          ],
        ),
      ),
    );
  }

  Widget _buildResults(ColorScheme cs) {
    if (_keyword.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.music_note, size: 64, color: cs.outline),
            const SizedBox(height: 16),
            Text('搜索你想听的音乐', style: TextStyle(color: cs.onSurfaceVariant)),
          ],
        ),
      );
    }
    if (_loading && _results.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _results.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(_error!, style: TextStyle(color: cs.error)),
        ),
      );
    }
    if (_results.isEmpty) {
      return Center(
        child: Text('没有找到结果', style: TextStyle(color: cs.onSurfaceVariant)),
      );
    }
    return ListView.separated(
      controller: _scrollController,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      itemCount: _results.length + (_loading ? 1 : 0),
      separatorBuilder: (_, __) => Divider(height: 1, color: cs.outlineVariant),
      itemBuilder: (context, i) {
        if (i >= _results.length) {
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
          );
        }
        final song = _results[i];
        final p = MusicPlayerService.instance;
        final isPlaying = p.currentSong?.id == song.id &&
            p.currentSong?.source == song.source;
        return ListTile(
          leading: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: song.img.isNotEmpty
                ? CoverImage(
                    cover: song.img,
                    width: 48,
                    height: 48,
                    fit: BoxFit.cover,
                    fallback: Container(
                      width: 48,
                      height: 48,
                      color: cs.surfaceContainerHighest,
                      child: Icon(Icons.music_note, color: cs.onSurfaceVariant),
                    ),
                  )
                : Container(
                    width: 48,
                    height: 48,
                    color: cs.surfaceContainerHighest,
                    child: Icon(Icons.music_note, color: cs.onSurfaceVariant),
                  ),
          ),
          title: Text(
            song.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: isPlaying ? cs.primary : null,
              fontWeight: isPlaying ? FontWeight.w600 : null,
            ),
          ),
          subtitle: Text(
            [
              song.singer,
              if (song.album.isNotEmpty) song.album,
            ].join(' - '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
          ),
          trailing: isPlaying
              ? Icon(Icons.graphic_eq, color: cs.primary)
              : Icon(Icons.play_circle_outline, color: cs.onSurfaceVariant),
          onTap: () => _playSong(i),
        );
      },
    );
  }
}
