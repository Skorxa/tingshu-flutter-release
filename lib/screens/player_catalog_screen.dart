import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import '../data/cache_service.dart';
import '../data/catalog_cache_service.dart';
import '../data/log_service.dart';
import '../data/quark_pan_service.dart';
import '../data/webdav_service.dart';
import '../player/player_service.dart';
import '../source/models.dart';
import '../source/source_manager.dart';

class PlayerCatalogScreen extends StatefulWidget {
  const PlayerCatalogScreen({super.key});

  @override
  State<PlayerCatalogScreen> createState() => _PlayerCatalogScreenState();
}

class _PlayerCatalogScreenState extends State<PlayerCatalogScreen> {
  // 克制预加载:进页面/刷新只自动补 _maxAutoPages 页,跳转时才全量补全,降低风控概率
  static const _maxAutoPages = 3;
  final _random = Random();
  final ScrollController _scrollController = ScrollController();
  final List<Chapter> _chapters = [];
  final Set<String> _cachedIds = {};
  CatalogInfo? _info;
  String _sourceId = '';
  String _bookId = '';
  String _bookTitle = '';
  String _cover = '';
  int _page = 1;
  int _maxPage = 1;
  bool _hasMore = false;
  bool _loading = false;
  bool _loadingAll = false;
  bool _refreshing = false;
  bool _initialized = false;
  bool _focusedCurrent = false;
  int _cacheVersion = -1;
  String? _error;

  @override
  void initState() {
    super.initState();
    CacheService.instance.addListener(_onCacheChanged);
    unawaited(_init());
  }

  @override
  void dispose() {
    CacheService.instance.removeListener(_onCacheChanged);
    _scrollController.dispose();
    super.dispose();
  }

  void _onCacheChanged() {
    final version = CacheService.instance.cacheVersion;
    if (version == _cacheVersion) return;
    _cacheVersion = version;
    unawaited(_refreshCachedIds());
  }

  Future<void> _init() async {
    final player = PlayerService.instance;
    _sourceId = player.sourceId;
    _bookId = player.bookId;
    _bookTitle = player.bookTitle;
    _cover = player.cover;
    if (_sourceId.isNotEmpty && _bookId.isNotEmpty) {
      final cached = await CatalogCacheService.instance.load(
        sourceId: _sourceId,
        bookId: _bookId,
      );
      if (cached != null && cached.chapters.isNotEmpty && mounted) {
        setState(() {
          _info = cached.info;
          _chapters
            ..clear()
            ..addAll(cached.chapters);
          _page = cached.page + 1;
          _maxPage = cached.maxPage;
          _hasMore = cached.hasMore && cached.page < cached.maxPage;
        });
      }
    }

    if (_chapters.isEmpty && player.chapters.isNotEmpty && mounted) {
      setState(() {
        _chapters
          ..clear()
          ..addAll(player.chapters.map(Chapter.fromMap));
        _page = 1;
        _hasMore = true;
      });
    }

    await _refreshCachedIds();
    if (_chapters.isEmpty) {
      await _loadPage(reset: true);
    }
    if (_isStaticCatalogSource(_sourceId)) {
      _hasMore = false;
    } else if (_hasMore) {
      unawaited(_loadRemainingCatalog());
    }
    if (mounted) {
      setState(() => _initialized = true);
      _focusCurrentChapter();
    }
  }

  Future<void> _refreshCachedIds() async {
    _cacheVersion = CacheService.instance.cacheVersion;
    final ids = await CacheService.instance.cachedChapterIds(
      sourceId: _sourceId,
      chapterIds: _chapters.map((chapter) => chapter.chapterId),
    );
    if (!mounted) return;
    setState(() {
      _cachedIds
        ..clear()
        ..addAll(ids);
    });
  }

  Future<bool> _loadPage({bool reset = false, bool fromAuto = false}) async {
    final player = PlayerService.instance;
    final sourceId = _sourceId.isNotEmpty ? _sourceId : player.sourceId;
    final bookId = _bookId.isNotEmpty ? _bookId : player.bookId;
    final bookTitle = _bookTitle.isNotEmpty ? _bookTitle : player.bookTitle;
    if (_loading ||
        (!fromAuto && _loadingAll) ||
        sourceId.isEmpty ||
        bookId.isEmpty) {
      return false;
    }
    if (_isStaticCatalogSource(sourceId)) {
      setState(() {
        _hasMore = false;
        _loading = false;
      });
      return false;
    }
    if (!mounted) return false;
    setState(() {
      _loading = true;
      _error = null;
      if (reset) {
        _page = 1;
        _maxPage = 1;
        _hasMore = false;
        _chapters.clear();
        _cachedIds.clear();
      }
    });

    try {
      final result = await SourceManager.instance.getChaptersFromSource(
        sourceId,
        bookId,
        page: _page,
        pageSize: SourceManager.catalogPageSize,
      );
      final hasMore = result.hasMore && result.page < result.maxPage;
      await CatalogCacheService.instance.savePage(
        sourceId: sourceId,
        bookId: bookId,
        info: result.info,
        chapters: result.list,
        page: result.page,
        maxPage: result.maxPage,
        hasMore: hasMore,
      );
      if (!mounted) return false;
      setState(() {
        _info = result.info;
        final existingIds = _chapters
            .map((chapter) => chapter.chapterId)
            .toSet();
        for (final chapter in result.list) {
          if (existingIds.add(chapter.chapterId)) {
            _chapters.add(chapter);
          }
        }
        _chapters.sort((a, b) => a.index.compareTo(b.index));
        _hasMore = hasMore;
        _page = result.page + 1;
        _maxPage = result.maxPage;
      });
      if (!fromAuto) {
        _syncPlayerContext();
      }
      await _refreshCachedIds();
      _focusCurrentChapter();
      LogService.instance.info(
        'Catalog',
        '播放器目录分页加载完成',
        detail:
            '书名: $bookTitle\n页码: ${result.page}/${result.maxPage}\n本页: ${result.list.length}',
      );
      return true;
    } catch (e) {
      LogService.instance.error('Catalog', '播放器目录加载失败', error: e);
      if (mounted) {
        setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
      }
      return false;
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadRemainingCatalog({bool full = false}) async {
    if (_loadingAll) return;
    if (!mounted) return;
    setState(() => _loadingAll = true);
    var changed = false;
    try {
      var pages = 0;
      while (mounted && _hasMore && (full || pages < _maxAutoPages)) {
        final loaded = await _loadPage(fromAuto: true);
        if (!loaded) break;
        changed = true;
        pages++;
        if (!_hasMore || (!full && pages >= _maxAutoPages)) break;
        // 1.5~3s 随机抖动,避免固定节奏被音源站风控识别
        await Future<void>.delayed(
          Duration(milliseconds: 1500 + _random.nextInt(1500)),
        );
      }
    } finally {
      if (changed) _syncPlayerContext(notify: false, log: false);
      if (mounted) setState(() => _loadingAll = false);
    }
  }

  void _syncPlayerContext({bool notify = true, bool log = true}) {
    final player = PlayerService.instance;
    final sourceId = _sourceId.isNotEmpty ? _sourceId : player.sourceId;
    final bookId = _bookId.isNotEmpty ? _bookId : player.bookId;
    if (sourceId.isEmpty || bookId.isEmpty || _chapters.isEmpty) {
      return;
    }
    if (player.sourceId != sourceId || player.bookId != bookId) return;
    player.setContext(
      sourceId: sourceId,
      bookId: bookId,
      bookTitle: _info?.title.isNotEmpty == true
          ? _info!.title
          : (_bookTitle.isNotEmpty ? _bookTitle : player.bookTitle),
      cover: _info?.cover.isNotEmpty == true
          ? _info!.cover
          : (_cover.isNotEmpty ? _cover : player.cover),
      chapters: _chapters.map(_chapterToPlayerJson).toList(),
      notify: notify,
      log: log,
    );
  }

  Future<void> _refreshCatalog() async {
    final player = PlayerService.instance;
    final sourceId = _sourceId.isNotEmpty ? _sourceId : player.sourceId;
    final bookId = _bookId.isNotEmpty ? _bookId : player.bookId;
    if (_loading || sourceId.isEmpty || bookId.isEmpty) return;
    setState(() => _refreshing = true);
    try {
      if (sourceId == 'quark') {
        await _refreshQuarkCatalog(bookId);
        return;
      }
      setState(() {
        _page = 1;
        _maxPage = 1;
        _hasMore = true;
        _error = null;
      });
      final loaded = await _loadPage();
      if (!loaded) return;
      if (_hasMore) unawaited(_loadRemainingCatalog());
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('已刷新，正在分页补全目录')));
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  Future<void> _refreshQuarkCatalog(String bookId) async {
    final cached = await QuarkPanService.instance.refreshCatalog(
      bookFid: bookId,
      folderName: _bookTitle.isNotEmpty
          ? _bookTitle
          : (_info?.title.isNotEmpty == true ? _info!.title : bookId),
      fallbackCover: _cover.isNotEmpty ? _cover : (_info?.cover ?? ''),
      fallbackAuthor: _info?.author ?? '',
    );
    if (!mounted) return;
    setState(() {
      _info = cached.info;
      _chapters
        ..clear()
        ..addAll(cached.chapters);
      _page = 1;
      _maxPage = 1;
      _hasMore = false;
      _error = null;
    });
    _syncPlayerContext();
    await _refreshCachedIds();
    _focusCurrentChapter(force: true);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('夸克目录已刷新，共 ${cached.chapters.length} 集')),
    );
  }

  Future<void> _play(int index) async {
    final player = PlayerService.instance;
    final chapters = _chapters
        .map((chapter) => _chapterToPlayerJson(chapter))
        .toList();
    player.setContext(
      sourceId: _sourceId.isNotEmpty ? _sourceId : player.sourceId,
      bookId: _bookId.isNotEmpty ? _bookId : player.bookId,
      bookTitle: _info?.title.isNotEmpty == true
          ? _info!.title
          : (_bookTitle.isNotEmpty ? _bookTitle : player.bookTitle),
      cover: _info?.cover.isNotEmpty == true
          ? _info!.cover
          : (_cover.isNotEmpty ? _cover : player.cover),
      chapters: chapters,
    );
    await player.playIndex(index);
    if (mounted) Navigator.pop(context);
  }

  String _currentChapterId(PlayerService player) {
    if (player.currentIndex < 0 ||
        player.currentIndex >= player.chapters.length) {
      return '';
    }
    return '${player.chapters[player.currentIndex]['chapterId'] ?? ''}';
  }

  Map<String, dynamic> _chapterToPlayerJson(Chapter chapter) {
    final json = chapter.toJson();
    if ((_sourceId.isNotEmpty ? _sourceId : PlayerService.instance.sourceId) ==
        'webdav') {
      final path = chapter.chapterId.startsWith('webdav:')
          ? chapter.chapterId.substring('webdav:'.length)
          : chapter.chapterId;
      json['audioUrl'] = WebDavService.instance.resolveUrl(path);
      json['audioHeaders'] = WebDavService.instance.headersForPath(path);
    }
    return json;
  }

  bool _isStaticCatalogSource(String sourceId) {
    return sourceId == 'webdav' || sourceId == 'baidu' || sourceId == 'quark';
  }

  Future<void> _showJumpInput() async {
    final controller = TextEditingController();
    final query = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              16,
              8,
              16,
              16 + MediaQuery.viewInsetsOf(ctx).bottom,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '跳转章节',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: controller,
                  autofocus: true,
                  textInputAction: TextInputAction.search,
                  decoration: const InputDecoration(
                    hintText: '输入章节编号或关键词',
                    prefixIcon: Icon(Icons.search),
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (value) => Navigator.pop(ctx, value),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: const Text('取消'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton(
                        onPressed: () => Navigator.pop(ctx, controller.text),
                        child: const Text('跳转'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
    controller.dispose();
    final value = query?.trim() ?? '';
    if (value.isEmpty) return;
    await _jumpTo(value);
  }

  Future<void> _jumpTo(String query) async {
    await _ensureFullCatalogForJump();
    if (!mounted) return;

    final number = int.tryParse(query);
    if (number != null && number > 0) {
      var index = _chapters.indexWhere((chapter) => chapter.index == number);
      if (index < 0 && number <= _chapters.length) index = number - 1;
      if (index >= 0 && index < _chapters.length) {
        _scrollToChapter(index);
        return;
      }
      _toast('没有找到第 $number 集');
      return;
    }

    final keyword = query.toLowerCase();
    final matches = <int>[];
    for (var i = 0; i < _chapters.length; i++) {
      if (_chapters[i].name.toLowerCase().contains(keyword)) {
        matches.add(i);
      }
    }
    if (matches.isEmpty) {
      _toast('没有找到包含「$query」的章节');
      return;
    }
    if (matches.length == 1) {
      _scrollToChapter(matches.first);
      return;
    }
    await _showJumpChoices(query, matches);
  }

  Future<void> _ensureFullCatalogForJump() async {
    if (!_hasMore) return;
    _toast('正在补全目录后再跳转');
    // 先等任何进行中的(克制)预加载结束,再全量补全,确保能定位到目标章节
    while (mounted && _loadingAll) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    if (!mounted || !_hasMore) return;
    await _loadRemainingCatalog(full: true);
  }

  Future<void> _showJumpChoices(String keyword, List<int> matches) async {
    final selected = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        final cs = Theme.of(ctx).colorScheme;
        return SafeArea(
          child: SizedBox(
            height: 420,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '找到 ${matches.length} 个「$keyword」',
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: ListView.builder(
                    itemCount: matches.length,
                    itemBuilder: (context, i) {
                      final chapterIndex = matches[i];
                      final chapter = _chapters[chapterIndex];
                      return ListTile(
                        leading: Text(
                          '${chapter.index == 0 ? chapterIndex + 1 : chapter.index}',
                          style: TextStyle(color: cs.onSurfaceVariant),
                        ),
                        title: Text(
                          chapter.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        onTap: () => Navigator.pop(ctx, chapterIndex),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
    if (selected != null) _scrollToChapter(selected);
  }

  void _scrollToChapter(int index) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          !_scrollController.hasClients ||
          index < 0 ||
          index >= _chapters.length) {
        return;
      }
      final target = (index * 56.0 + 8).clamp(
        0.0,
        _scrollController.position.maxScrollExtent,
      );
      _scrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOutCubic,
      );
      final chapter = _chapters[index];
      _toast('已跳转到第 ${chapter.index == 0 ? index + 1 : chapter.index} 集');
    });
  }

  void _focusCurrentChapter({bool force = false}) {
    if (!force && _focusedCurrent) return;
    final player = PlayerService.instance;
    final currentChapterId = _currentChapterId(player);
    if (currentChapterId.isEmpty || _chapters.isEmpty) return;
    final index = _chapters.indexWhere(
      (chapter) => chapter.chapterId == currentChapterId,
    );
    if (index < 0) return;
    _focusedCurrent = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      final viewport = _scrollController.position.viewportDimension;
      final target = (index * 56.0 + 8 - viewport * 0.35).clamp(
        0.0,
        _scrollController.position.maxScrollExtent,
      );
      _scrollController.jumpTo(target);
    });
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final player = PlayerService.instance;
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('播放目录')),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: (_loading || _loadingAll || _refreshing)
                      ? null
                      : _refreshCatalog,
                  icon: _refreshing
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh),
                  label: Text(_refreshing ? '刷新中' : '刷新目录'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _chapters.isEmpty ? null : _showJumpInput,
                  icon: const Icon(Icons.low_priority),
                  label: const Text('跳转'),
                ),
              ),
            ],
          ),
        ),
      ),
      body: !_initialized && _chapters.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : AnimatedBuilder(
              animation: player,
              builder: (context, _) {
                if (_chapters.isEmpty) {
                  return _emptyState(cs);
                }
                final currentChapterId = _currentChapterId(player);
                return NotificationListener<ScrollNotification>(
                  onNotification: (notification) {
                    if (notification.metrics.pixels >=
                            notification.metrics.maxScrollExtent - 300 &&
                        _hasMore &&
                        !_loading &&
                        !_loadingAll) {
                      unawaited(_loadPage());
                    }
                    return false;
                  },
                  child: ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: _chapters.length + 1,
                    itemBuilder: (context, index) {
                      if (index == _chapters.length) {
                        return Padding(
                          padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
                          child: Center(
                            child: Text(
                              _loadingAll
                                  ? '正在分页补全目录 ${(_page - 1).clamp(0, _maxPage)}/$_maxPage'
                                  : (_loading
                                        ? '加载中...'
                                        : (_hasMore ? '上拉加载更多' : '目录已加载完整')),
                              style: TextStyle(
                                fontSize: 13,
                                color: cs.onSurfaceVariant,
                              ),
                            ),
                          ),
                        );
                      }
                      final chapter = _chapters[index];
                      final selected = chapter.chapterId == currentChapterId;
                      final cached = _cachedIds.contains(chapter.chapterId);
                      return _ChapterTile(
                        index: index,
                        chapter: chapter,
                        selected: selected,
                        cached: cached,
                        onTap: () => _play(index),
                      );
                    },
                  ),
                );
              },
            ),
    );
  }

  Widget _emptyState(ColorScheme cs) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.format_list_bulleted,
              size: 48,
              color: cs.onSurfaceVariant,
            ),
            const SizedBox(height: 12),
            Text(
              _error ?? '暂无目录',
              textAlign: TextAlign.center,
              style: TextStyle(color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            FilledButton.tonal(
              onPressed: _loading ? null : () => _loadPage(reset: true),
              child: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ChapterTile extends StatelessWidget {
  final int index;
  final Chapter chapter;
  final bool selected;
  final bool cached;
  final VoidCallback onTap;

  const _ChapterTile({
    required this.index,
    required this.chapter,
    required this.selected,
    required this.cached,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Stack(
      children: [
        ListTile(
          selected: selected,
          selectedTileColor: cs.primary.withValues(alpha: 0.08),
          leading: SizedBox(
            width: 42,
            child: Text(
              '${chapter.index == 0 ? index + 1 : chapter.index}',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: selected ? cs.primary : cs.onSurfaceVariant,
                fontWeight: selected ? FontWeight.w700 : FontWeight.normal,
              ),
            ),
          ),
          title: Text(
            chapter.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: selected ? cs.primary : null,
              fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
            ),
          ),
          trailing: selected
              ? Icon(Icons.volume_up, color: cs.primary, size: 20)
              : const SizedBox(width: 20),
          onTap: onTap,
        ),
        if (cached)
          const Positioned(
            right: 14,
            bottom: 6,
            child: Icon(
              Icons.download_done,
              size: 15,
              color: Color(0xFF16A34A),
            ),
          ),
      ],
    );
  }
}
