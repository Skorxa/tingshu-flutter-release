import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import '../data/alist_service.dart';
import '../data/baidu_pan_service.dart';
import '../data/cache_service.dart';
import '../data/catalog_cache_service.dart';
import '../data/catalog_filter.dart';
import '../data/log_service.dart';
import '../data/quark_pan_service.dart';
import '../data/settings_service.dart';
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
  static const _chapterExtent = 64.0;
  final _random = Random();
  late final ScrollController _scrollController;
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
  int _focusRetryCount = 0;
  int _cacheVersion = -1;
  String? _error;
  // 目录净化:解析结果按规则文本缓存,列表渲染使用过滤后的可见子集
  CatalogFilter? _filter;
  String _filterRulesCache = '';
  List<Chapter> _visible = const [];

  @override
  void initState() {
    super.initState();
    final currentIndex = PlayerService.instance.currentIndex;
    _scrollController = ScrollController(
      initialScrollOffset: currentIndex > 0 ? currentIndex * _chapterExtent : 0,
    );
    CacheService.instance.addListener(_onCacheChanged);
    PlayerService.instance.addListener(_onPlayerChanged);
    unawaited(_init());
  }

  @override
  void dispose() {
    CacheService.instance.removeListener(_onCacheChanged);
    PlayerService.instance.removeListener(_onPlayerChanged);
    _scrollController.dispose();
    super.dispose();
  }

  /// 播放切集时自动跟随:当前章节滚出视口才滚动,在视口内不打扰浏览。
  void _onPlayerChanged() {
    if (!mounted || !_scrollController.hasClients) return;
    final visibleIndex = _visibleIndexOfCurrent();
    if (visibleIndex < 0) return;
    final itemTop = 8 + visibleIndex * _chapterExtent;
    final itemBottom = itemTop + _chapterExtent;
    final top = _scrollController.offset;
    final bottom = top + _scrollController.position.viewportDimension;
    if (itemTop < top || itemBottom > bottom) {
      _animateToVisibleIndex(visibleIndex);
    }
  }

  List<Chapter> _visibleChapters() {
    final rules = SettingsService.instance.catalogFilterRules;
    if (_filter == null || _filterRulesCache != rules) {
      _filterRulesCache = rules;
      _filter = CatalogFilter.parse(rules);
    }
    final filter = _filter!;
    if (filter.isEmpty) return _chapters;
    return _chapters.where((chapter) => !filter.blocked(chapter.name)).toList();
  }

  /// 当前播放章节在可见列表中的位置(净化过滤后可能不在列表内,返回 -1)。
  int _visibleIndexOfCurrent() {
    final currentChapterId = _currentChapterId(PlayerService.instance);
    if (currentChapterId.isEmpty) return -1;
    return _visible.indexWhere(
      (chapter) => chapter.chapterId == currentChapterId,
    );
  }

  void _animateToVisibleIndex(int visibleIndex) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      final viewport = _scrollController.position.viewportDimension;
      final target = (8 + visibleIndex * _chapterExtent - viewport * 0.35)
          .clamp(0.0, _scrollController.position.maxScrollExtent);
      _scrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOutCubic,
      );
    });
  }

  void _scrollBackToCurrent() {
    final visibleIndex = _visibleIndexOfCurrent();
    if (visibleIndex < 0) {
      _toast('当前章节不在目录中');
      return;
    }
    _animateToVisibleIndex(visibleIndex);
    _toast('已定位到当前章节');
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

    // 播放器内存中的目录可以立即显示，也一定包含当前正在播放的章节。
    // SQLite 目录随后合并，避免进入页面时先等待整本目录读取。
    if (player.chapters.isNotEmpty) {
      _mergeChapters(player.chapters.map(Chapter.fromMap));
      _initialized = true;
      _hasMore = !_isStaticCatalogSource(_sourceId);
      _focusCurrentChapter();
    }

    if (_sourceId.isNotEmpty && _bookId.isNotEmpty) {
      if (player.chapters.isNotEmpty) {
        final cached = await CatalogCacheService.instance.loadMeta(
          sourceId: _sourceId,
          bookId: _bookId,
        );
        if (cached != null && mounted) {
          setState(() {
            _info = cached.info;
            _page = cached.page + 1;
            _maxPage = cached.maxPage;
            _hasMore = cached.hasMore && cached.page < cached.maxPage;
          });
        }
      } else {
        final cached = await CatalogCacheService.instance.load(
          sourceId: _sourceId,
          bookId: _bookId,
        );
        if (cached != null && cached.chapters.isNotEmpty && mounted) {
          setState(() {
            _info = cached.info;
            _mergeChapters(cached.chapters);
            _page = cached.page + 1;
            _maxPage = cached.maxPage;
            _hasMore = cached.hasMore && cached.page < cached.maxPage;
            _initialized = true;
          });
          _focusCurrentChapter();
        }
      }
    }

    if (_chapters.isEmpty) {
      await _loadPage(reset: true);
    }
    if (!mounted) return;
    if (!_initialized) setState(() => _initialized = true);
    _focusCurrentChapter();
    unawaited(_refreshCachedIds());
    if (_isStaticCatalogSource(_sourceId)) {
      _hasMore = false;
    } else if (_hasMore) {
      unawaited(_loadRemainingCatalog());
    }
  }

  void _mergeChapters(Iterable<Chapter> chapters) {
    final existingIds = _chapters
        .map((chapter) => chapter.chapterId)
        .where((id) => id.isNotEmpty)
        .toSet();
    for (final chapter in chapters) {
      if (chapter.chapterId.isEmpty || existingIds.add(chapter.chapterId)) {
        _chapters.add(chapter);
      }
    }
    _chapters.sort((a, b) => a.index.compareTo(b.index));
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
        _mergeChapters(result.list);
        _hasMore = hasMore;
        _page = result.page + 1;
        _maxPage = result.maxPage;
      });
      if (!fromAuto) {
        _syncPlayerContext();
      }
      _focusCurrentChapter();
      unawaited(_refreshCachedIds());
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
      if (sourceId == 'baidu') {
        await _refreshBaiduCatalog(bookId);
        return;
      }
      if (sourceId == 'alist') {
        await _refreshAlistCatalog(bookId);
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
    _focusCurrentChapter(force: true);
    unawaited(_refreshCachedIds());
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('夸克目录已刷新，共 ${cached.chapters.length} 集')),
    );
  }

  Future<void> _refreshBaiduCatalog(String bookId) async {
    final cached = await BaiduPanService.instance.refreshCatalog(
      bookPath: bookId,
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
    _focusCurrentChapter(force: true);
    unawaited(_refreshCachedIds());
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('百度目录已刷新，共 ${cached.chapters.length} 集')),
    );
  }

  Future<void> _refreshAlistCatalog(String bookId) async {
    final cached = await AlistService.instance.refreshCatalog(
      scopedBookPath: bookId,
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
    _focusCurrentChapter(force: true);
    unawaited(_refreshCachedIds());
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Alist 目录已刷新，共 ${cached.chapters.length} 集')),
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
    // 入参为完整目录索引;净化过滤后需换算为可见列表位置
    var visibleIndex = index;
    if (index >= 0 && index < _chapters.length) {
      final chapter = _chapters[index];
      final mapped = _visible.indexWhere(
        (item) => item.chapterId == chapter.chapterId,
      );
      if (mapped < 0) {
        _toast('该章节已被净化规则隐藏');
        return;
      }
      visibleIndex = mapped;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          !_scrollController.hasClients ||
          visibleIndex < 0 ||
          visibleIndex >= _visible.length) {
        return;
      }
      final target = (8 + visibleIndex * _chapterExtent).clamp(
        0.0,
        _scrollController.position.maxScrollExtent,
      );
      _scrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOutCubic,
      );
      final chapter = _visible[visibleIndex];
      _toast('已跳转到第 ${chapter.index == 0 ? visibleIndex + 1 : chapter.index} 集');
    });
  }

  void _focusCurrentChapter({bool force = false}) {
    if (!force && _focusedCurrent) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!_scrollController.hasClients) {
        // 列表尚未挂载:下一帧重试,避免定位静默丢失
        if (++_focusRetryCount < 10) {
          _focusCurrentChapter(force: true);
        }
        return;
      }
      // postFrame 时首帧 build 已执行,_visible 已就绪
      final visibleIndex = _visibleIndexOfCurrent();
      if (visibleIndex < 0) return;
      _focusedCurrent = true;
      _focusRetryCount = 0;
      final viewport = _scrollController.position.viewportDimension;
      final target = (8 + visibleIndex * _chapterExtent - viewport * 0.35)
          .clamp(0.0, _scrollController.position.maxScrollExtent);
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
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _visible.isEmpty ? null : _scrollBackToCurrent,
                  icon: const Icon(Icons.center_focus_strong),
                  label: const Text('当前'),
                ),
              ),
            ],
          ),
        ),
      ),
      body: !_initialized && _chapters.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : ValueListenableBuilder<int>(
              valueListenable: player.miniMetaListenable,
              builder: (context, _, _) {
                if (_chapters.isEmpty) {
                  return _emptyState(cs);
                }
                _visible = _visibleChapters();
                final currentChapterId = _currentChapterId(player);
                if (_visible.isEmpty) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        '所有章节都被净化规则隐藏了\n可在 设置 → 播放 → 目录净化规则 调整',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: cs.onSurfaceVariant),
                      ),
                    ),
                  );
                }
                return Scrollbar(
                  controller: _scrollController,
                  thumbVisibility: true,
                  trackVisibility: true,
                  interactive: true,
                  thickness: 8,
                  radius: const Radius.circular(4),
                  scrollbarOrientation: ScrollbarOrientation.right,
                  child: NotificationListener<ScrollNotification>(
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
                      itemExtent: _chapterExtent,
                      padding: const EdgeInsets.fromLTRB(12, 8, 24, 8),
                      itemCount: _visible.length + 1,
                      itemBuilder: (context, index) {
                        if (index == _visible.length) {
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
                        final chapter = _visible[index];
                        final selected = chapter.chapterId == currentChapterId;
                        final cached = _cachedIds.contains(chapter.chapterId);
                        return _ChapterTile(
                          index: index,
                          chapter: chapter,
                          selected: selected,
                          cached: cached,
                          onTap: () {
                            final fullIndex = _chapters.indexWhere(
                              (item) => item.chapterId == chapter.chapterId,
                            );
                            if (fullIndex >= 0) _play(fullIndex);
                          },
                        );
                      },
                    ),
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
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      child: Card(
        margin: EdgeInsets.zero,
        child: Stack(
          children: [
            ListTile(
              selected: selected,
              selectedTileColor: cs.primaryContainer.withValues(alpha: 0.5),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              leading: Container(
                width: 42,
                alignment: Alignment.center,
                child: Text(
                  '${chapter.index == 0 ? index + 1 : chapter.index}',
                  style: TextStyle(
                    fontSize: 14,
                    color: selected ? cs.primary : cs.onSurfaceVariant,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
              ),
              title: Text(
                chapter.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 15,
                  color: selected ? cs.primary : null,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                ),
              ),
              trailing: selected
                  ? Icon(Icons.volume_up, color: cs.primary, size: 22)
                  : const SizedBox(width: 22),
              onTap: onTap,
            ),
            if (cached)
              Positioned(
                right: 14,
                bottom: 6,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: cs.tertiaryContainer,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    '已缓存',
                    style: TextStyle(
                      fontSize: 10,
                      color: cs.onTertiaryContainer,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
