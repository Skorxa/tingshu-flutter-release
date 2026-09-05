import 'dart:async';

import 'package:flutter/material.dart';

import '../data/alist_service.dart';
import '../data/baidu_pan_service.dart';
import '../data/catalog_cache_service.dart';
import '../data/log_service.dart';
import '../data/progress_service.dart';
import '../data/quark_pan_service.dart';
import '../data/shelf_service.dart';
import '../data/webdav_service.dart';
import '../player/player_service.dart';
import '../source/models.dart';
import '../source/source_debug_runner.dart';
import '../source/source_manager.dart';
import '../widgets/cover_image.dart';
import 'player_screen.dart';
import 'runtime_log_screen.dart';
import 'source_config_screen.dart';
import 'source_switch_screen.dart';

class ShelfScreen extends StatefulWidget {
  const ShelfScreen({super.key});

  @override
  State<ShelfScreen> createState() => _ShelfScreenState();
}

class _ShelfScreenState extends State<ShelfScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  List<ShelfBook> _books = [];
  List<ShelfBook> _history = [];
  String _openingKey = '';

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this)
      ..addListener(_onTabChanged);
    ShelfService.instance.addListener(_onShelfChanged);
    _load();
  }

  @override
  void dispose() {
    _tabController
      ..removeListener(_onTabChanged)
      ..dispose();
    ShelfService.instance.removeListener(_onShelfChanged);
    super.dispose();
  }

  void _onTabChanged() {
    if (!_tabController.indexIsChanging && mounted) setState(() {});
  }

  void _onShelfChanged() {
    unawaited(_load());
  }

  Future<void> _load() async {
    final books = await ShelfService.instance.list();
    final historyRows = await ProgressService.instance.listHistory();
    final history = historyRows.map(_historyBookFromProgress).toList();
    if (mounted) {
      setState(() {
        _books = books;
        _history = history;
      });
    }
  }

  ShelfBook _historyBookFromProgress(Map<String, dynamic> row) {
    final sourceId = '${row['sourceId'] ?? ''}';
    return ShelfBook(
      sourceId: sourceId,
      bookId: '${row['bookId'] ?? ''}',
      title: '${row['bookTitle'] ?? ''}',
      cover: '${row['cover'] ?? ''}',
      author: '${row['chapterName'] ?? ''}',
      sourceName: _sourceName(sourceId),
      addTime: (row['updatedAt'] as int?) ?? 0,
    );
  }

  String _sourceName(String sourceId) {
    if (sourceId == 'webdav') return 'WebDAV';
    if (sourceId == 'baidu') return '百度网盘';
    if (sourceId == 'quark') return '夸克网盘';
    if (sourceId == 'alist') return 'Alist';
    return SourceManager.instance.getSourceName(sourceId);
  }

  Future<void> _clearHistory() async {
    if (_history.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清除历史记录'),
        content: const Text('将清空所有播放历史和断点记录。收藏不会受影响。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('清除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ProgressService.instance.clearHistory();
    await _load();
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('已清空历史记录')));
  }

  Future<void> _openBook(ShelfBook book) async {
    final sourceId = book.sourceId.isNotEmpty
        ? book.sourceId
        : SourceManager.instance.activeId;
    final key = '$sourceId:${book.bookId}';
    if (sourceId.isEmpty || _openingKey.isNotEmpty) return;

    setState(() => _openingKey = key);
    try {
      if (sourceId == 'webdav') {
        await _openWebDavBook(book);
        return;
      }
      if (sourceId == 'baidu') {
        await _openBaiduBook(book);
        return;
      }
      if (sourceId == 'quark') {
        await _openQuarkBook(book);
        return;
      }
      if (sourceId == 'alist') {
        await _openAlistBook(book);
        return;
      }
      if (SourceManager.instance.activeId != sourceId) {
        await SourceManager.instance.setActive(sourceId);
      }

      var cached = await CatalogCacheService.instance.load(
        sourceId: sourceId,
        bookId: book.bookId,
      );
      if (cached == null || cached.chapters.isEmpty) {
        final res = await SourceManager.instance.getChaptersFromSource(
          sourceId,
          book.bookId,
          page: 1,
          pageSize: SourceManager.catalogPageSize,
        );
        await CatalogCacheService.instance.savePage(
          sourceId: sourceId,
          bookId: book.bookId,
          info: res.info,
          chapters: res.list,
          page: res.page,
          maxPage: res.maxPage,
          hasMore: res.hasMore && res.page < res.maxPage,
        );
        cached = CachedCatalog(
          info: res.info,
          chapters: res.list,
          page: res.page,
          maxPage: res.maxPage,
          hasMore: res.hasMore && res.page < res.maxPage,
        );
      }
      if (cached.chapters.isEmpty) throw Exception('目录为空');

      final progress = await ProgressService.instance.load(
        sourceId: sourceId,
        bookId: book.bookId,
      );
      if (progress != null && cached.hasMore) {
        cached = await _loadCatalogUntilResume(
          sourceId: sourceId,
          book: book,
          cached: cached,
          progress: progress,
        );
      }
      var index = 0;
      var seekTo = 0.0;
      if (progress != null) {
        final chapterId = '${progress['chapterId'] ?? ''}';
        final savedIndex = (progress['chapterIdx'] as int?) ?? 0;
        final matched = cached.chapters.indexWhere(
          (chapter) => chapter.chapterId == chapterId,
        );
        index = matched >= 0 ? matched : savedIndex;
        if (index < 0 || index >= cached.chapters.length) index = 0;
        seekTo = (progress['currentTime'] as num?)?.toDouble() ?? 0;
      }

      final title = cached.info.title.isNotEmpty
          ? cached.info.title
          : book.title;
      final cover = cached.info.cover.isNotEmpty
          ? cached.info.cover
          : book.cover;
      PlayerService.instance.setContext(
        sourceId: sourceId,
        bookId: book.bookId,
        bookTitle: title,
        cover: cover,
        chapters: cached.chapters.map((chapter) => chapter.toJson()).toList(),
      );
      await PlayerService.instance.playIndex(index, seekTo: seekTo);
      LogService.instance.info(
        'Shelf',
        '从书架直接进入播放',
        detail: '书名: $title\n章节序号: ${index + 1}\n断点: ${seekTo.toInt()} 秒',
      );
      if (!mounted) return;
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const PlayerScreen()),
      ).then((_) => _load());
    } catch (e) {
      LogService.instance.error('Shelf', '从书架播放失败', error: e);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
        );
      }
    } finally {
      if (mounted) setState(() => _openingKey = '');
    }
  }

  Future<void> _openBaiduBook(ShelfBook book) async {
    final service = BaiduPanService.instance;
    if (!service.ready) throw Exception('请先登录百度网盘');
    // 优先用加入书架时缓存的目录;缺失则递归重建(含分卷子目录)
    var cached = await CatalogCacheService.instance.load(
      sourceId: 'baidu',
      bookId: book.bookId,
    );
    if (cached == null || cached.chapters.isEmpty) {
      final bb = await service.toBook(book.bookId);
      if (bb.audioFiles.isEmpty) throw Exception('目录没有可播放的音频文件');
      final author = bb.narrator.isEmpty
          ? bb.author
          : '${bb.author} / ${bb.narrator}';
      final info = CatalogInfo(
        title: book.title.isNotEmpty ? book.title : bb.title,
        cover: book.cover.isNotEmpty ? book.cover : bb.cover,
        author: book.author.isNotEmpty ? book.author : author,
        trackCount: bb.audioFiles.length,
        isFinished: true,
      );
      final chapters = <Chapter>[
        for (var i = 0; i < bb.audioFiles.length; i++)
          Chapter(
            chapterId: 'baidu:${bb.audioFiles[i].path}',
            index: i + 1,
            name: bb.audioFiles[i].name,
          ),
      ];
      await CatalogCacheService.instance.savePage(
        sourceId: 'baidu',
        bookId: book.bookId,
        info: info,
        chapters: chapters,
        page: 1,
        maxPage: 1,
        hasMore: false,
      );
      cached = CachedCatalog(
        info: info,
        chapters: chapters,
        page: 1,
        maxPage: 1,
        hasMore: false,
      );
    }

    // 封面本地化后台执行,不阻塞播放;结果更新书架/目录缓存,下次打开生效。
    unawaited(_ensureBaiduLocalCover(book, cached));

    final progress = await ProgressService.instance.load(
      sourceId: 'baidu',
      bookId: book.bookId,
    );
    var index = 0;
    var seekTo = 0.0;
    if (progress != null) {
      final chapterId = '${progress['chapterId'] ?? ''}';
      final savedIndex = (progress['chapterIdx'] as int?) ?? 0;
      final matched = cached.chapters.indexWhere(
        (chapter) => chapter.chapterId == chapterId,
      );
      index = matched >= 0 ? matched : savedIndex;
      if (index < 0 || index >= cached.chapters.length) index = 0;
      seekTo = (progress['currentTime'] as num?)?.toDouble() ?? 0;
    }

    PlayerService.instance.setContext(
      sourceId: 'baidu',
      bookId: book.bookId,
      bookTitle: cached.info.title.isNotEmpty ? cached.info.title : book.title,
      cover: cached.info.cover.isNotEmpty ? cached.info.cover : book.cover,
      chapters: cached.chapters.map((chapter) => chapter.toJson()).toList(),
    );
    await PlayerService.instance.playIndex(index, seekTo: seekTo);
    if (!mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const PlayerScreen()),
    ).then((_) => _load());
  }

  Future<String> _ensureBaiduLocalCover(
    ShelfBook book,
    CachedCatalog cached,
  ) async {
    final current = cached.info.cover.isNotEmpty
        ? cached.info.cover
        : book.cover;
    if (_isLocalPath(current)) return current;
    try {
      final items = await BaiduPanService.instance.list(book.bookId);
      final coverItem = BaiduPanService.instance.findCoverItem(items);
      if (coverItem == null) return current;
      final localCover = await BaiduPanService.instance.cacheCover(coverItem);
      await ShelfService.instance.updateCover(
        sourceId: 'baidu',
        bookId: book.bookId,
        cover: localCover,
      );
      await CatalogCacheService.instance.updateCover(
        sourceId: 'baidu',
        bookId: book.bookId,
        cover: localCover,
      );
      return localCover;
    } catch (e) {
      LogService.instance.warning(
        'Shelf',
        '百度网盘本地封面补全失败，继续使用现有封面',
        detail: '书名: ${book.title}\n错误: $e',
      );
      return current;
    }
  }

  bool _isLocalPath(String value) {
    final lower = value.toLowerCase();
    if (lower.isEmpty) return false;
    return !(lower.startsWith('http://') ||
        lower.startsWith('https://') ||
        lower.startsWith('//'));
  }

  Future<void> _openQuarkBook(ShelfBook book) async {
    final service = QuarkPanService.instance;
    if (!service.ready) throw Exception('请先登录夸克网盘');
    var cached = await CatalogCacheService.instance.load(
      sourceId: 'quark',
      bookId: book.bookId,
    );
    if (cached == null || cached.chapters.isEmpty) {
      cached = await service.refreshCatalog(
        bookFid: book.bookId,
        folderName: book.title,
        fallbackCover: book.cover,
        fallbackAuthor: book.author,
      );
    }

    // 封面本地化后台执行,不阻塞播放;结果更新书架/目录缓存,下次打开生效。
    unawaited(_ensureQuarkLocalCover(book, cached));

    final progress = await ProgressService.instance.load(
      sourceId: 'quark',
      bookId: book.bookId,
    );
    var index = 0;
    var seekTo = 0.0;
    if (progress != null) {
      final chapterId = '${progress['chapterId'] ?? ''}';
      final savedIndex = (progress['chapterIdx'] as int?) ?? 0;
      final matched = cached.chapters.indexWhere(
        (chapter) => chapter.chapterId == chapterId,
      );
      index = matched >= 0 ? matched : savedIndex;
      if (index < 0 || index >= cached.chapters.length) index = 0;
      seekTo = (progress['currentTime'] as num?)?.toDouble() ?? 0;
    }

    PlayerService.instance.setContext(
      sourceId: 'quark',
      bookId: book.bookId,
      bookTitle: cached.info.title.isNotEmpty ? cached.info.title : book.title,
      cover: cached.info.cover.isNotEmpty ? cached.info.cover : book.cover,
      chapters: cached.chapters.map((chapter) => chapter.toJson()).toList(),
    );
    await PlayerService.instance.playIndex(index, seekTo: seekTo);
    LogService.instance.info(
      'Shelf',
      '从夸克网盘书架进入播放',
      detail: '书名: ${book.title}\n章节序号: ${index + 1}\n断点: ${seekTo.toInt()} 秒',
    );
    if (!mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const PlayerScreen()),
    ).then((_) => _load());
  }

  Future<String> _ensureQuarkLocalCover(
    ShelfBook book,
    CachedCatalog cached,
  ) async {
    final current = cached.info.cover.isNotEmpty
        ? cached.info.cover
        : book.cover;
    if (_isLocalPath(current)) return current;
    try {
      final items = await QuarkPanService.instance.list(book.bookId);
      final coverItem = QuarkPanService.instance.findCoverItem(items);
      if (coverItem == null) return current;
      final localCover = await QuarkPanService.instance.cacheCover(coverItem);
      await ShelfService.instance.updateCover(
        sourceId: 'quark',
        bookId: book.bookId,
        cover: localCover,
      );
      await CatalogCacheService.instance.updateCover(
        sourceId: 'quark',
        bookId: book.bookId,
        cover: localCover,
      );
      return localCover;
    } catch (e) {
      LogService.instance.warning(
        'Shelf',
        '夸克网盘本地封面补全失败，继续使用现有封面',
        detail: '书名: ${book.title}\n错误: $e',
      );
      return current;
    }
  }

  Future<void> _openWebDavBook(ShelfBook book) async {
    final service = WebDavService.instance;
    if (!service.ready) throw Exception('请先配置 WebDAV');
    await service.activateForScopedPath(book.bookId);
    final rawPath = service.pathFromScopedPath(book.bookId);
    final items = await service.list(rawPath);
    final webdavBook = service.toBook(rawPath, items);
    if (webdavBook.audioFiles.isEmpty) throw Exception('目录没有可播放的音频文件');
    final cover = book.cover.isNotEmpty ? book.cover : webdavBook.cover;
    final chapters = <Map<String, dynamic>>[];
    for (var i = 0; i < webdavBook.audioFiles.length; i++) {
      final file = webdavBook.audioFiles[i];
      final scopedPath = service.scopedPath(file.path);
      chapters.add({
        'chapterId': 'webdav:$scopedPath',
        'index': i + 1,
        'name': file.name,
        'audioUrl': service.resolveUrl(scopedPath),
        'audioHeaders': service.headersForPath(scopedPath),
      });
    }
    final progress = await ProgressService.instance.load(
      sourceId: 'webdav',
      bookId: book.bookId,
    );
    var index = 0;
    var seekTo = 0.0;
    if (progress != null) {
      final chapterId = '${progress['chapterId'] ?? ''}';
      final savedIndex = (progress['chapterIdx'] as int?) ?? 0;
      final matched = chapters.indexWhere(
        (chapter) => '${chapter['chapterId'] ?? ''}' == chapterId,
      );
      index = matched >= 0 ? matched : savedIndex;
      if (index < 0 || index >= chapters.length) index = 0;
      seekTo = (progress['currentTime'] as num?)?.toDouble() ?? 0;
    }
    PlayerService.instance.setContext(
      sourceId: 'webdav',
      bookId: book.bookId,
      bookTitle: book.title,
      cover: cover,
      chapters: chapters,
    );
    await PlayerService.instance.playIndex(index, seekTo: seekTo);
    LogService.instance.info(
      'Shelf',
      '从 WebDAV 书架进入播放',
      detail: '书名: ${book.title}\n章节序号: ${index + 1}\n断点: ${seekTo.toInt()} 秒',
    );
    if (!mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const PlayerScreen()),
    ).then((_) => _load());
  }

  Future<void> _openAlistBook(ShelfBook book) async {
    final service = AlistService.instance;
    if (!service.ready) throw Exception('请先配置 Alist');
    await service.activateForScopedPath(book.bookId);
    final rawPath = service.pathFromScopedPath(book.bookId);

    // 目录缓存优先:章节 chapterId 自带 alist: 占位,播放时才解析直链,
    // 因此缓存可以放心复用,秒开不发请求。未命中才枚举网盘(仅首开)。
    List<Map<String, dynamic>> chapters;
    String cover = book.cover;
    String title = book.title;
    final cached = await CatalogCacheService.instance.load(
      sourceId: 'alist',
      bookId: book.bookId,
    );
    if (cached != null && cached.chapters.isNotEmpty) {
      chapters = [
        for (final ch in cached.chapters)
          {'chapterId': ch.chapterId, 'index': ch.index, 'name': ch.name},
      ];
      if (cached.info.title.isNotEmpty) title = cached.info.title;
      if (cached.info.cover.isNotEmpty) cover = cached.info.cover;
      LogService.instance.info(
        'Shelf',
        'Alist 目录缓存命中，直接续播',
        detail: '书名: ${book.title}\n章节数: ${chapters.length}',
      );
    } else {
      final items = await service.list(rawPath);
      final alistBook = service.toBook(rawPath, items);
      if (alistBook.audioFiles.isEmpty) throw Exception('目录没有可播放的音频文件');
      chapters = [
        for (var i = 0; i < alistBook.audioFiles.length; i++)
          {
            'chapterId': 'alist:${service.scopedPath(alistBook.audioFiles[i].path)}',
            'index': i + 1,
            'name': alistBook.audioFiles[i].name,
          },
      ];
      title = alistBook.title.isNotEmpty ? alistBook.title : book.title;
      await CatalogCacheService.instance.savePage(
        sourceId: 'alist',
        bookId: service.scopedPath(alistBook.path),
        info: CatalogInfo(
          title: title,
          cover: cover,
          author: alistBook.narrator.isEmpty
              ? alistBook.author
              : '${alistBook.author} / ${alistBook.narrator}',
          trackCount: chapters.length,
          isFinished: true,
        ),
        chapters: [
          for (final ch in chapters)
            Chapter(
              chapterId: '${ch['chapterId']}',
              index: (ch['index'] as num).toInt(),
              name: '${ch['name']}',
            ),
        ],
        page: 1,
        maxPage: 1,
        hasMore: false,
      );
      // 封面缓存后台补齐,不阻塞播放
      final coverItem = service.findCoverItem(items);
      if (coverItem != null) {
        unawaited(() async {
          try {
            await service.cacheCover(coverItem);
          } catch (e) {
            LogService.instance.warning(
              'Shelf',
              'Alist 封面后台缓存失败',
              detail: '书名: ${book.title}\n错误: $e',
            );
          }
        }());
      }
    }

    final progress = await ProgressService.instance.load(
      sourceId: 'alist',
      bookId: book.bookId,
    );
    var index = 0;
    var seekTo = 0.0;
    if (progress != null) {
      final chapterId = '${progress['chapterId'] ?? ''}';
      final savedIndex = (progress['chapterIdx'] as int?) ?? 0;
      final matched = chapters.indexWhere(
        (chapter) => '${chapter['chapterId'] ?? ''}' == chapterId,
      );
      index = matched >= 0 ? matched : savedIndex;
      if (index < 0 || index >= chapters.length) index = 0;
      seekTo = (progress['currentTime'] as num?)?.toDouble() ?? 0;
    }

    PlayerService.instance.setContext(
      sourceId: 'alist',
      bookId: book.bookId,
      bookTitle: title,
      cover: cover,
      chapters: chapters,
    );
    await PlayerService.instance.playIndex(index, seekTo: seekTo);
    LogService.instance.info(
      'Shelf',
      '从 Alist 书架进入播放',
      detail: '书名: ${book.title}\n章节序号: ${index + 1}\n断点: ${seekTo.toInt()} 秒',
    );
    if (!mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const PlayerScreen()),
    ).then((_) => _load());
  }

  Future<void> _showBookMenu(ShelfBook book) async {
    final sourceId = book.sourceId.isNotEmpty
        ? book.sourceId
        : SourceManager.instance.activeId;
    if (sourceId.isEmpty) return;
    final sourceName = book.sourceName.isNotEmpty
        ? book.sourceName
        : SourceManager.instance.getSourceName(sourceId);
    final configurable = SourceManager.instance.sourceHasConfig(sourceId);
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(
                book.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text('$sourceName · ${book.bookId}'),
            ),
            if (configurable)
              ListTile(
                leading: const Icon(Icons.tune),
                title: const Text('音源配置'),
                onTap: () => Navigator.pop(ctx, 'config'),
              ),
            ListTile(
              leading: const Icon(Icons.bug_report_outlined),
              title: const Text('调试音源'),
              subtitle: const Text('自动跑搜索、目录、音频解析并写入日志'),
              onTap: () => Navigator.pop(ctx, 'debug'),
            ),
            ListTile(
              leading: const Icon(Icons.swap_horizontal_circle_outlined),
              title: const Text('换源播放'),
              subtitle: const Text('按书名搜索其他音源，对齐当前章节'),
              onTap: () => Navigator.pop(ctx, 'switch'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    if (action == 'config') {
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => SourceConfigScreen(sourceId: sourceId),
        ),
      );
      return;
    }
    if (action == 'switch') {
      final progress = await ProgressService.instance.load(
        sourceId: sourceId,
        bookId: book.bookId,
      );
      if (!mounted) return;
      final chapterIdx = (progress?['chapterIdx'] as num?)?.toInt() ?? 0;
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => SourceSwitchScreen(
            sourceId: sourceId,
            bookId: book.bookId,
            bookTitle: book.title,
            currentChapterName: '${progress?['chapterName'] ?? ''}',
            currentIndex: chapterIdx,
          ),
        ),
      );
      _load();
      return;
    }
    if (action == 'debug') {
      await _debugBook(book, sourceId: sourceId, sourceName: sourceName);
    }
  }

  Future<void> _debugBook(
    ShelfBook book, {
    required String sourceId,
    required String sourceName,
  }) async {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('已开始调试，完成后打开运行日志')));
    try {
      await SourceDebugRunner.instance.runBookDebug(
        sourceId: sourceId,
        sourceName: sourceName,
        keyword: book.title,
        bookId: book.bookId,
        bookTitle: book.title,
      );
      if (!mounted) return;
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const RuntimeLogScreen()),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
      );
    }
  }

  Future<CachedCatalog> _loadCatalogUntilResume({
    required String sourceId,
    required ShelfBook book,
    required CachedCatalog cached,
    required Map<String, dynamic> progress,
  }) async {
    final chapterId = '${progress['chapterId'] ?? ''}';
    final savedIndex = (progress['chapterIdx'] as int?) ?? 0;
    if (chapterId.isEmpty && savedIndex < cached.chapters.length) {
      return cached;
    }
    var info = cached.info;
    final chapters = [...cached.chapters];
    var page = cached.page + 1;
    var maxPage = cached.maxPage;
    var hasMore = cached.hasMore && cached.page < cached.maxPage;

    while (hasMore) {
      if (chapterId.isNotEmpty &&
          chapters.any((chapter) => chapter.chapterId == chapterId)) {
        break;
      }
      if (chapterId.isEmpty && savedIndex < chapters.length) break;
      try {
        final res = await SourceManager.instance.getChaptersFromSource(
          sourceId,
          book.bookId,
          page: page,
          pageSize: SourceManager.catalogPageSize,
        );
        hasMore = res.hasMore && res.page < res.maxPage;
        await CatalogCacheService.instance.savePage(
          sourceId: sourceId,
          bookId: book.bookId,
          info: res.info,
          chapters: res.list,
          page: res.page,
          maxPage: res.maxPage,
          hasMore: hasMore,
        );
        info = res.info;
        final existingIds = chapters
            .map((chapter) => chapter.chapterId)
            .toSet();
        for (final chapter in res.list) {
          if (existingIds.add(chapter.chapterId)) {
            chapters.add(chapter);
          }
        }
        chapters.sort((a, b) => a.index.compareTo(b.index));
        page = res.page + 1;
        maxPage = res.maxPage;
        await Future<void>.delayed(const Duration(milliseconds: 250));
      } catch (e) {
        LogService.instance.warning(
          'Shelf',
          '续播补全目录失败，使用已缓存目录播放',
          detail: '书名: ${book.title}\n错误: $e',
        );
        break;
      }
    }
    return CachedCatalog(
      info: info,
      chapters: chapters,
      page: page - 1,
      maxPage: maxPage,
      hasMore: hasMore,
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final showingHistory = _tabController.index == 1;
    return Scaffold(
      appBar: AppBar(
        title: const Text('我的书架'),
        actions: [
          if (showingHistory && _history.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_sweep_outlined),
              tooltip: '清空历史',
              onPressed: _clearHistory,
            ),
        ],
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: '收藏'),
            Tab(text: '历史'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _bookList(
            cs: cs,
            books: _books,
            emptyText: '收藏还是空的\n去搜索页添加吧',
            history: false,
          ),
          _bookList(
            cs: cs,
            books: _history,
            emptyText: '暂无播放历史',
            history: true,
          ),
        ],
      ),
    );
  }

  Widget _bookList({
    required ColorScheme cs,
    required List<ShelfBook> books,
    required String emptyText,
    required bool history,
  }) {
    if (books.isEmpty) return _emptyState(cs, emptyText);
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        itemCount: books.length,
        itemBuilder: (context, i) {
          final b = books[i];
          final key = '${b.sourceId}:${b.bookId}';
          final opening = _openingKey == key;
          final sourceLabel = b.sourceName.isNotEmpty
              ? b.sourceName
              : b.sourceId;
          return Card(
            margin: const EdgeInsets.only(bottom: 12),
            child: InkWell(
              onTap: opening ? null : () => _openBook(b),
              onLongPress: opening ? null : () => _showBookMenu(b),
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    // 封面
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: b.cover.isNotEmpty
                          ? _coverImage(b.cover, cs)
                          : _coverFallback(cs),
                    ),
                    const SizedBox(width: 12),
                    // 信息
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            b.title.isNotEmpty ? b.title : b.bookId,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              height: 1.3,
                            ),
                          ),
                          if (b.author.isNotEmpty) ...[
                            const SizedBox(height: 6),
                            Text(
                              b.author,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 13,
                                color: cs.onSurfaceVariant,
                              ),
                            ),
                          ],
                          const SizedBox(height: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: cs.secondaryContainer,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              sourceLabel,
                              style: TextStyle(
                                fontSize: 11,
                                color: cs.onSecondaryContainer,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    // 操作按钮
                    IconButton(
                      icon: opening
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Icon(Icons.delete_outline, color: cs.onSurfaceVariant),
                      onPressed: () async {
                        if (opening) return;
                        final confirmed = await showDialog<bool>(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            title: Text(history ? '删除历史记录' : '移出书架'),
                            content: Text(
                              history
                                  ? '确定要删除「${b.title}」的播放记录吗？'
                                  : '确定要将「${b.title}」移出书架吗？',
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(ctx, false),
                                child: const Text('取消'),
                              ),
                              FilledButton(
                                onPressed: () => Navigator.pop(ctx, true),
                                child: const Text('确定'),
                              ),
                            ],
                          ),
                        );
                        if (confirmed != true) return;
                        if (history) {
                          await ProgressService.instance.remove(
                            sourceId: b.sourceId,
                            bookId: b.bookId,
                          );
                        } else {
                          await ShelfService.instance.remove(
                            sourceId: b.sourceId,
                            bookId: b.bookId,
                          );
                        }
                        await _load();
                      },
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _emptyState(ColorScheme cs, String text) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.bookmark_border, size: 48, color: cs.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(
              text,
              textAlign: TextAlign.center,
              style: TextStyle(color: cs.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  Widget _coverImage(String cover, ColorScheme cs) {
    return CoverImage(
      cover: cover,
      width: 56,
      height: 56,
      fit: BoxFit.cover,
      fallback: _coverFallback(cs),
    );
  }

  Widget _coverFallback(ColorScheme cs) => Container(
    width: 56,
    height: 56,
    color: cs.surfaceContainerHighest,
    child: Icon(Icons.menu_book, color: cs.onSurfaceVariant, size: 28),
  );
}
