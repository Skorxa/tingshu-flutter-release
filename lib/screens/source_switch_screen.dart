import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pool/pool.dart';

import '../data/log_service.dart';
import '../data/shelf_service.dart';
import '../player/player_service.dart';
import '../source/models.dart';
import '../source/source_manager.dart';
import '../widgets/cover_image.dart';
import 'player_screen.dart';

/// 一键换源:按当前书名聚合搜索,选定替代书籍后尽量对齐到当前播放章节。
/// 旧书进度保留在原 (sourceId, bookId) 下,随时可以换回来。
class SourceSwitchScreen extends StatefulWidget {
  final String sourceId;
  final String bookId;
  final String bookTitle;
  final String currentChapterName;
  final int currentIndex;

  const SourceSwitchScreen({
    super.key,
    required this.sourceId,
    required this.bookId,
    required this.bookTitle,
    required this.currentChapterName,
    required this.currentIndex,
  });

  @override
  State<SourceSwitchScreen> createState() => _SourceSwitchScreenState();
}

class _SwitchBucket {
  final SourceMeta source;
  final List<Book> books = [];
  String? error;

  _SwitchBucket(this.source);
}

class _SourceSwitchScreenState extends State<SourceSwitchScreen> {
  late final TextEditingController _keyword;
  final List<_SwitchBucket> _buckets = [];
  bool _searching = false;
  bool _switching = false;

  @override
  void initState() {
    super.initState();
    _keyword = TextEditingController(text: widget.bookTitle);
    unawaited(_search());
  }

  @override
  void dispose() {
    _keyword.dispose();
    super.dispose();
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _search() async {
    final kw = _keyword.text.trim();
    if (kw.isEmpty || _searching) return;
    final sources = SourceManager.instance
        .getSources()
        .where((source) => source.enabled)
        .toList();
    if (sources.isEmpty) {
      _toast('没有已开启的音源');
      return;
    }
    setState(() {
      _searching = true;
      _buckets
        ..clear()
        ..addAll(sources.map((source) => _SwitchBucket(source)));
    });
    LogService.instance.info(
      'Switch',
      '开始换源搜索',
      detail: '关键词: $kw\n音源数量: ${sources.length}',
    );
    final pool = Pool(3);
    try {
      await Future.wait(
        _buckets.map(
          (bucket) => pool.withResource(() => _loadBucket(bucket, kw)),
        ),
      );
    } finally {
      pool.close();
    }
    if (mounted) setState(() => _searching = false);
  }

  Future<void> _loadBucket(_SwitchBucket bucket, String keyword) async {
    try {
      final res = await SourceManager.instance.searchFromSource(
        bucket.source.id,
        keyword,
        pageSize: 20,
      ).timeout(const Duration(seconds: 15));
      bucket.books.addAll(res.list);
      if (mounted) setState(() {});
    } catch (e) {
      bucket.error = e is TimeoutException ? '搜索超时' : '$e'.replaceFirst('Exception: ', '');
      if (mounted) setState(() {});
    }
  }

  String _normalize(String value) {
    return value
        .replaceAll(
          RegExp(r'[\s\u3000·・,，.。:：;；!！?？\-_—–()（）\[\]【】《》""'']'),
          '',
        )
        .toLowerCase();
  }

  int _matchIndex(List<Chapter> chapters) {
    final target = _normalize(widget.currentChapterName);
    if (target.isNotEmpty) {
      final byName = chapters.indexWhere(
        (chapter) => _normalize(chapter.name) == target,
      );
      if (byName >= 0) return byName;
    }
    return widget.currentIndex.clamp(0, chapters.length - 1);
  }

  /// 拉取目标书目录,翻页直到覆盖当前集序号(或目录结束)。
  Future<List<Chapter>> _loadTargetCatalog(
    String sourceId,
    String bookId,
  ) async {
    final chapters = <Chapter>[];
    final need = widget.currentIndex + 1;
    for (var page = 1; page <= 40; page++) {
      final res = await SourceManager.instance.getChaptersFromSource(
        sourceId,
        bookId,
        page: page,
      );
      chapters.addAll(res.list);
      if (chapters.length >= need || !res.hasMore || page >= res.maxPage) {
        break;
      }
    }
    chapters.sort((a, b) => a.index.compareTo(b.index));
    return chapters;
  }

  Future<void> _switchTo(SourceMeta source, Book book) async {
    if (_switching) return;
    setState(() => _switching = true);
    try {
      final chapters = await _loadTargetCatalog(source.id, book.bookId);
      if (chapters.isEmpty) {
        _toast('《${book.title}》没有可播放的目录');
        return;
      }
      if (!mounted) return;
      final matched = _matchIndex(chapters);
      final inShelf = await ShelfService.instance.contains(
        sourceId: widget.sourceId,
        bookId: widget.bookId,
      );
      if (!mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('确认换源'),
          content: Text(
            '从《${widget.bookTitle}》${widget.currentChapterName.isEmpty ? '' : '「${widget.currentChapterName}」'}\n'
            '换到《${book.title}》第 ${chapters[matched].index == 0 ? matched + 1 : chapters[matched].index} 集「${chapters[matched].name}」。\n\n'
            '${inShelf ? '书架条目将替换为新书，旧书进度保留。' : '旧书进度保留，随时可换回。'}',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('换源并播放'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;

      await SourceManager.instance.setActive(source.id);
      PlayerService.instance.setContext(
        sourceId: source.id,
        bookId: book.bookId,
        bookTitle: book.title,
        cover: book.cover,
        chapters: chapters.map((chapter) => chapter.toJson()).toList(),
      );
      await PlayerService.instance.playIndex(matched);
      if (inShelf) {
        await ShelfService.instance.remove(
          sourceId: widget.sourceId,
          bookId: widget.bookId,
        );
        final author = book.author.trim();
        await ShelfService.instance.add(
          sourceId: source.id,
          bookId: book.bookId,
          title: book.title,
          cover: book.cover,
          author: author,
          sourceName: source.name,
        );
        LogService.instance.info(
          'Switch',
          '换源完成并替换书架',
          detail:
              '旧书: ${widget.bookTitle}(${widget.sourceId})\n新书: ${book.title}(${source.id})\n对齐章节: ${matched + 1}',
        );
      } else {
        LogService.instance.info(
          'Switch',
          '换源完成',
          detail:
              '旧书: ${widget.bookTitle}(${widget.sourceId})\n新书: ${book.title}(${source.id})\n对齐章节: ${matched + 1}',
        );
      }
      if (!mounted) return;
      _toast('已换源到「${source.name}」');
      if (inShelf) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => const PlayerScreen()),
        );
      } else {
        Navigator.pop(context);
      }
    } catch (e) {
      _toast('换源失败:$e'.replaceFirst('Exception: ', ''));
      LogService.instance.error('Switch', '换源失败', error: e);
    } finally {
      if (mounted) setState(() => _switching = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final hitCount = _buckets.fold<int>(
      0,
      (sum, bucket) => sum + bucket.books.length,
    );
    return Scaffold(
      appBar: AppBar(
        title: const Text('换源播放'),
        actions: [
          IconButton(icon: const Icon(Icons.search), onPressed: _search),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _keyword,
                    onSubmitted: (_) => _search(),
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: '书名关键词（默认当前书名）',
                      prefixIcon: const Icon(Icons.search),
                      border: const OutlineInputBorder(),
                      helperText: '当前:${widget.currentChapterName.isEmpty ? widget.bookTitle : widget.currentChapterName}',
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Text(
                  _searching ? '正在搜索…' : '命中 $hitCount 本',
                  style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
                ),
              ],
            ),
          ),
          Expanded(
            child: _switching
                ? const Center(child: CircularProgressIndicator())
                : ListView(
                    padding: const EdgeInsets.only(bottom: 24),
                    children: [
                      for (final bucket in _buckets) ..._bucketTiles(bucket, cs),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  List<Widget> _bucketTiles(_SwitchBucket bucket, ColorScheme cs) {
    if (bucket.books.isEmpty) {
      return bucket.error == null
          ? const []
          : [
              ListTile(
                dense: true,
                title: Text(bucket.source.name),
                subtitle: Text(
                  bucket.error!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                ),
              ),
            ];
    }
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Text(
          bucket.source.name,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: cs.primary,
          ),
        ),
      ),
      for (final book in bucket.books)
        ListTile(
          leading: CoverImage(
            cover: book.cover,
            width: 44,
            height: 58,
            fit: BoxFit.cover,
            fallback: Container(
              width: 44,
              height: 58,
              color: cs.surfaceContainerHighest,
              child: Icon(Icons.menu_book_outlined,
                  size: 20, color: cs.onSurfaceVariant),
            ),
          ),
          title: Text(
            book.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: book.author.isEmpty
              ? null
              : Text(
                  book.author,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _switchTo(bucket.source, book),
        ),
    ];
  }
}
