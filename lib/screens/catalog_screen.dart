import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import '../data/catalog_cache_service.dart';
import '../data/progress_service.dart';
import '../data/shelf_service.dart';
import '../player/player_service.dart';
import '../source/models.dart';
import '../source/source_manager.dart';
import '../widgets/cover_image.dart';
import 'player_screen.dart';

class CatalogScreen extends StatefulWidget {
  final Book book;
  final String? sourceId;
  final bool resume; // 从书架进入时自动续听
  const CatalogScreen({
    super.key,
    required this.book,
    this.sourceId,
    this.resume = false,
  });

  @override
  State<CatalogScreen> createState() => _CatalogScreenState();
}

class _CatalogScreenState extends State<CatalogScreen> {
  // 克制预加载:进页面只自动补 _maxAutoPages 页,其余靠用户上拉,降低被音源站风控的概率
  static const _maxAutoPages = 3;
  final _random = Random();
  final List<Chapter> _list = [];
  late final String _sourceId;
  CatalogInfo? _info;
  int _page = 1;
  int _maxPage = 1;
  bool _hasMore = false;
  bool _loading = false;
  bool _loadingAll = false;
  bool _inShelf = false;
  bool _resumed = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _sourceId = widget.sourceId?.isNotEmpty == true
        ? widget.sourceId!
        : SourceManager.instance.activeId;
    _checkShelf();
    _initCatalog();
  }

  Future<void> _initCatalog() async {
    if (_sourceId.isNotEmpty && SourceManager.instance.activeId != _sourceId) {
      await SourceManager.instance.setActive(_sourceId);
    }
    if (!mounted) return;
    await _restoreCachedCatalog();
    if (!mounted) return;
    if (_list.isEmpty) {
      await _load(reset: true);
    }
    if (!mounted) return;
    if (_hasMore) unawaited(_loadRemainingCatalog());
  }

  Future<void> _restoreCachedCatalog() async {
    if (_sourceId.isEmpty) return;
    final cached = await CatalogCacheService.instance.load(
      sourceId: _sourceId,
      bookId: widget.book.bookId,
    );
    if (cached == null || !mounted) return;
    setState(() {
      _info = cached.info;
      _list
        ..clear()
        ..addAll(cached.chapters);
      _hasMore = cached.hasMore && cached.page < cached.maxPage;
      _page = cached.page + 1;
      _maxPage = cached.maxPage;
    });
  }

  Future<void> _checkShelf() async {
    final v = await ShelfService.instance.contains(
      sourceId: _sourceId,
      bookId: widget.book.bookId,
    );
    if (mounted) setState(() => _inShelf = v);
  }

  Future<bool> _load({bool reset = false, bool fromAuto = false}) async {
    if (_loading || (!fromAuto && _loadingAll)) return false;
    if (!mounted) return false;
    setState(() {
      _loading = true;
      _error = null;
      if (reset) {
        _page = 1;
        _maxPage = 1;
        _list.clear();
      }
    });
    try {
      final res = await SourceManager.instance.getChaptersFromSource(
        _sourceId,
        widget.book.bookId,
        page: _page,
        pageSize: SourceManager.catalogPageSize,
      );
      await CatalogCacheService.instance.savePage(
        sourceId: _sourceId,
        bookId: widget.book.bookId,
        info: res.info,
        chapters: res.list,
        page: res.page,
        maxPage: res.maxPage,
        hasMore: res.hasMore && res.page < res.maxPage,
      );
      if (!mounted) return false;
      setState(() {
        _info ??= res.info;
        final existingIds = _list.map((chapter) => chapter.chapterId).toSet();
        for (final chapter in res.list) {
          if (existingIds.add(chapter.chapterId)) {
            _list.add(chapter);
          }
        }
        _list.sort((a, b) => a.index.compareTo(b.index));
        _hasMore = res.hasMore && res.page < res.maxPage;
        _page = res.page + 1;
        _maxPage = res.maxPage;
      });
      if (!fromAuto) {
        _syncPlayerContextIfCurrent();
      }
      // 续听:首批章节加载后,跳到上次位置
      if (widget.resume && !_resumed && _list.isNotEmpty) {
        _resumed = await _tryResume();
      }
      return true;
    } catch (e) {
      if (mounted) {
        setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
      }
      return false;
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadRemainingCatalog() async {
    if (_loadingAll || _sourceId.isEmpty) return;
    if (!mounted) return;
    setState(() => _loadingAll = true);
    var changed = false;
    try {
      var pages = 0;
      while (mounted && _hasMore && pages < _maxAutoPages) {
        final loaded = await _load(fromAuto: true);
        if (!loaded) break;
        changed = true;
        pages++;
        if (!_hasMore || pages >= _maxAutoPages) break;
        // 1.5~3s 随机抖动,避免固定节奏被音源站风控识别
        await Future<void>.delayed(
          Duration(milliseconds: 1500 + _random.nextInt(1500)),
        );
      }
    } finally {
      if (changed) _syncPlayerContextIfCurrent(notify: false, log: false);
      if (mounted) setState(() => _loadingAll = false);
    }
  }

  void _syncPlayerContextIfCurrent({bool notify = true, bool log = true}) {
    final player = PlayerService.instance;
    if (player.sourceId != _sourceId || player.bookId != widget.book.bookId) {
      return;
    }
    player.setContext(
      sourceId: _sourceId,
      bookId: widget.book.bookId,
      bookTitle: _info?.title.isNotEmpty == true
          ? _info!.title
          : widget.book.title,
      cover: _info?.cover.isNotEmpty == true ? _info!.cover : widget.book.cover,
      chapters: _list.map((chapter) => chapter.toJson()).toList(),
      notify: notify,
      log: log,
    );
  }

  Future<bool> _tryResume() async {
    final p = await ProgressService.instance.load(
      sourceId: _sourceId,
      bookId: widget.book.bookId,
    );
    if (!mounted) return false;
    if (p == null) return true;
    final chapterId = '${p['chapterId']}';
    final idx = _list.indexWhere((c) => c.chapterId == chapterId);
    if (idx < 0) return false;
    final seekTo = (p['currentTime'] as num?)?.toDouble() ?? 0;
    _playFrom(idx, seekTo: seekTo);
    return true;
  }

  Future<void> _toggleShelf() async {
    try {
      if (_sourceId.isEmpty) throw Exception('音源为空，无法加入书架');
      if (_inShelf) {
        await ShelfService.instance.remove(
          sourceId: _sourceId,
          bookId: widget.book.bookId,
        );
      } else {
        final title = _info?.title.isNotEmpty == true
            ? _info!.title
            : widget.book.title;
        final cover = _info?.cover.isNotEmpty == true
            ? _info!.cover
            : widget.book.cover;
        final author = _info?.author.isNotEmpty == true
            ? _info!.author
            : widget.book.author;
        await ShelfService.instance.add(
          sourceId: _sourceId,
          bookId: widget.book.bookId,
          title: title,
          cover: cover,
          author: author,
          sourceName: _sourceName(),
        );
      }
      setState(() => _inShelf = !_inShelf);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(_inShelf ? '已加入书架' : '已移出书架')));
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
      );
    }
  }

  String _sourceName() {
    for (final source in SourceManager.instance.getSources()) {
      if (source.id == _sourceId) return source.name;
    }
    return _sourceId;
  }

  void _playFrom(int index, {double seekTo = 0}) {
    final chapters = _list.map((c) => c.toJson()).toList();
    PlayerService.instance.setContext(
      sourceId: _sourceId,
      bookId: widget.book.bookId,
      bookTitle: _info?.title.isNotEmpty == true
          ? _info!.title
          : widget.book.title,
      cover: _info?.cover.isNotEmpty == true ? _info!.cover : widget.book.cover,
      chapters: chapters,
    );
    PlayerService.instance.playIndex(index, seekTo: seekTo);
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const PlayerScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final title = _info?.title.isNotEmpty == true
        ? _info!.title
        : widget.book.title;
    return Scaffold(
      appBar: AppBar(
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            icon: Icon(_inShelf ? Icons.bookmark : Icons.bookmark_border),
            color: _inShelf ? cs.primary : null,
            onPressed: _toggleShelf,
          ),
        ],
      ),
      body: _error != null && _list.isEmpty
          ? _errorState(cs)
          : NotificationListener<ScrollNotification>(
              onNotification: (n) {
                if (n.metrics.pixels >= n.metrics.maxScrollExtent - 300 &&
                    _hasMore &&
                    !_loading &&
                    !_loadingAll) {
                  _load();
                }
                return false;
              },
              child: ListView.builder(
                itemCount: _list.length + 2,
                itemBuilder: (context, index) {
                  if (index == 0) return _header(cs);
                  if (index == _list.length + 1) {
                    if (_loading || _loadingAll) {
                      return Padding(
                        padding: const EdgeInsets.all(16),
                        child: Center(
                          child: Text(
                            _loadingAll
                                ? '正在分页补全目录 ${(_page - 1).clamp(0, _maxPage)}/$_maxPage'
                                : '目录加载中...',
                          ),
                        ),
                      );
                    }
                    if (_hasMore) {
                      return const Padding(
                        padding: EdgeInsets.all(16),
                        child: Center(child: Text('上拉加载更多')),
                      );
                    }
                    return const SizedBox.shrink();
                  }
                  final i = index - 1;
                  return ListTile(
                    leading: SizedBox(
                      width: 32,
                      child: Text(
                        '${_list[i].index}',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 13,
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ),
                    title: Text(_list[i].name),
                    onTap: () => _playFrom(i),
                  );
                },
              ),
            ),
    );
  }

  Widget _header(ColorScheme cs) {
    final info = _info;
    final cover = info?.cover.isNotEmpty == true
        ? info!.cover
        : widget.book.cover;
    return Container(
      color: cs.surfaceContainerLow,
      padding: const EdgeInsets.all(16),
      margin: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: cover.isNotEmpty
                    ? CoverImage(
                        cover: cover,
                        width: 90,
                        height: 90,
                        fit: BoxFit.cover,
                        fallback: _coverFallback(cs),
                      )
                    : _coverFallback(cs),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      info?.title.isNotEmpty == true
                          ? info!.title
                          : widget.book.title,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      info?.author.isNotEmpty == true
                          ? info!.author
                          : widget.book.author,
                      style: TextStyle(
                        fontSize: 13,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '共 ${info?.trackCount ?? _list.length} 集'
                      '${info?.isFinished == true ? ' · 完结' : ''}',
                      style: TextStyle(
                        fontSize: 12,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  onPressed: _list.isEmpty ? null : () => _playFrom(0),
                  child: const Text('播放'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton(
                  onPressed: _toggleShelf,
                  child: Text(_inShelf ? '已在书架' : '加入书架'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _errorState(ColorScheme cs) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 48, color: cs.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(
              _error!,
              textAlign: TextAlign.center,
              style: TextStyle(color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            FilledButton.tonal(
              onPressed: () => _load(reset: true),
              child: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _coverFallback(ColorScheme cs) => Container(
    width: 90,
    height: 90,
    color: cs.surfaceContainerHighest,
    child: Icon(Icons.menu_book, color: cs.onSurfaceVariant, size: 32),
  );
}
