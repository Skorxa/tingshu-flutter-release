import 'package:flutter/material.dart';

import '../data/log_service.dart';
import '../data/settings_service.dart';
import '../source/models.dart';
import '../source/source_debug_runner.dart';
import '../source/source_manager.dart';
import '../widgets/cover_image.dart';
import 'catalog_screen.dart';
import 'runtime_log_screen.dart';
import 'source_config_screen.dart';

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchHit {
  final SourceMeta source;
  final Book book;

  const _SearchHit({required this.source, required this.book});
}

class _SourceBucket {
  final SourceMeta source;
  final List<Book> books = [];
  int page = 1;
  bool hasMore = false;
  String? error;

  _SourceBucket(this.source);
}

class _SearchScreenState extends State<SearchScreen> {
  final _ctrl = TextEditingController();
  final Map<String, _SourceBucket> _buckets = {};
  String _keyword = '';
  String _selectedSourceId = 'all';
  bool _loading = false;
  bool _aggregateMode = true;
  String? _error;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  List<_SourceBucket> get _sourceBuckets => _buckets.values.toList();

  List<_SearchHit> get _hits {
    final list = <_SearchHit>[];
    for (final bucket in _sourceBuckets) {
      if (_selectedSourceId != 'all' && bucket.source.id != _selectedSourceId) {
        continue;
      }
      for (final book in bucket.books) {
        list.add(_SearchHit(source: bucket.source, book: book));
      }
    }
    return list;
  }

  bool get _hasMore {
    if (_selectedSourceId == 'all') {
      return _sourceBuckets.any((bucket) => bucket.hasMore);
    }
    return _buckets[_selectedSourceId]?.hasMore == true;
  }

  Future<void> _search({bool reset = true}) async {
    final kw = _ctrl.text.trim();
    if (kw.isEmpty || _loading) return;
    if (reset) {
      _aggregateMode = SettingsService.instance.aggregateSearch;
      final allSources = SourceManager.instance.getSources();
      final sources = _aggregateMode
          ? allSources.where((source) => source.enabled).toList()
          : allSources
                .where(
                  (source) =>
                      source.enabled &&
                      source.id == SourceManager.instance.activeId,
                )
                .toList();
      if (sources.isEmpty) {
        setState(() {
          _keyword = kw;
          _buckets.clear();
          _error = _aggregateMode ? '没有已开启的音源' : '当前音源未开启';
        });
        return;
      }
      setState(() {
        _keyword = kw;
        _selectedSourceId = _aggregateMode ? 'all' : sources.first.id;
        _buckets
          ..clear()
          ..addEntries(
            sources.map((source) => MapEntry(source.id, _SourceBucket(source))),
          );
        _error = null;
      });
      LogService.instance.info(
        'Search',
        _aggregateMode ? '开始聚合搜索' : '开始当前音源搜索',
        detail: '关键词: $kw\n音源数量: ${sources.length}',
      );
    }
    await _loadMore();
  }

  Future<void> _loadMore() async {
    if (_keyword.isEmpty || _loading) return;
    final targets = _sourceBuckets.where((bucket) {
      if (_selectedSourceId != 'all' && bucket.source.id != _selectedSourceId) {
        return false;
      }
      return bucket.books.isEmpty || bucket.hasMore;
    }).toList();
    if (targets.isEmpty) return;

    setState(() {
      _loading = true;
      _error = null;
    });

    await Future.wait(targets.map(_loadBucket));
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (_hits.isEmpty) {
        final errors = _sourceBuckets
            .map((bucket) => bucket.error)
            .whereType<String>()
            .toList();
        _error = errors.isEmpty ? null : errors.join('\n');
      }
    });
  }

  Future<void> _loadBucket(_SourceBucket bucket) async {
    try {
      final res = await SourceManager.instance.searchFromSource(
        bucket.source.id,
        _keyword,
        page: bucket.page,
        pageSize: 20,
      );
      final filtered = res.list.where(_matchesSearchMode).toList();
      bucket.books.addAll(filtered);
      bucket.hasMore = res.hasMore && res.page < res.maxPage;
      bucket.page = res.page + 1;
      bucket.error = null;
      if (mounted) setState(() {});
      LogService.instance.info(
        'Search',
        '音源搜索完成',
        detail:
            '音源: ${bucket.source.name}\n关键词: $_keyword\n新增结果: ${filtered.length}\n原始结果: ${res.list.length}\n匹配方式: ${SettingsService.instance.searchMatchModeLabel}\n下一页: ${bucket.page}',
      );
    } catch (e) {
      bucket.hasMore = false;
      bucket.error =
          '${bucket.source.name}: ${e.toString().replaceFirst('Exception: ', '')}';
      if (mounted) setState(() {});
      LogService.instance.error(
        'Search',
        '音源搜索失败: ${bucket.source.name}',
        error: e,
      );
    }
  }

  bool _matchesSearchMode(Book book) {
    if (SettingsService.instance.searchMatchMode != 'exact') return true;
    final keyword = _normalizeSearchText(_keyword);
    if (keyword.isEmpty) return true;
    return _normalizeSearchText(book.title) == keyword;
  }

  String _normalizeSearchText(String value) {
    return value
        .toLowerCase()
        .replaceAll(RegExp(r'\s+'), '')
        .replaceAll(RegExp(r'[《》「」『』\[\]【】（）()_-]'), '');
  }

  Future<void> _openBook(_SearchHit hit) async {
    await SourceManager.instance.setActive(hit.source.id);
    if (!mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => CatalogScreen(book: hit.book, sourceId: hit.source.id),
      ),
    );
  }

  Future<void> _showBookMenu(_SearchHit hit) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(
                hit.book.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text('${hit.source.name} · ${hit.book.bookId}'),
            ),
            if (hit.source.configurable)
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
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    if (action == 'config') {
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => SourceConfigScreen(sourceId: hit.source.id),
        ),
      );
      return;
    }
    if (action == 'debug') {
      await _debugBook(hit);
    }
  }

  Future<void> _debugBook(_SearchHit hit) async {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('已开始调试，完成后打开运行日志')));
    try {
      await SourceDebugRunner.instance.runBookDebug(
        sourceId: hit.source.id,
        sourceName: hit.source.name,
        keyword: _keyword.isNotEmpty ? _keyword : hit.book.title,
        bookId: hit.book.bookId,
        bookTitle: hit.book.title,
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
              child: TextField(
                controller: _ctrl,
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => _search(),
                decoration: InputDecoration(
                  hintText: SettingsService.instance.aggregateSearch
                      ? '聚合搜索书名 / 作者'
                      : '搜索当前音源',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.arrow_forward),
                    tooltip: '搜索',
                    onPressed: _search,
                  ),
                  filled: true,
                  contentPadding: EdgeInsets.zero,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(28),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            Expanded(child: _buildBody()),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_buckets.isEmpty) {
      return _empty(
        icon: Icons.travel_explore,
        text:
            _error ??
            (SettingsService.instance.aggregateSearch
                ? '输入关键词聚合搜索全部音源'
                : '输入关键词搜索当前音源'),
      );
    }
    if (!_aggregateMode) return _resultPane();
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sourceRail(),
        VerticalDivider(
          width: 1,
          color: Theme.of(context).colorScheme.outlineVariant,
        ),
        Expanded(child: _resultPane()),
      ],
    );
  }

  Widget _sourceRail() {
    return SizedBox(
      width: 92,
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: 6),
        children: [
          _sourceItem(
            id: 'all',
            name: '全部',
            count: _sourceBuckets.fold<int>(
              0,
              (sum, bucket) => sum + bucket.books.length,
            ),
          ),
          for (final bucket in _sourceBuckets)
            _sourceItem(
              id: bucket.source.id,
              name: bucket.source.name,
              count: bucket.books.length,
              hasError: bucket.error != null,
            ),
        ],
      ),
    );
  }

  Widget _sourceItem({
    required String id,
    required String name,
    required int count,
    bool hasError = false,
  }) {
    final cs = Theme.of(context).colorScheme;
    final selected = id == _selectedSourceId;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      child: Material(
        color: selected ? cs.secondaryContainer : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => setState(() => _selectedSourceId = id),
          child: SizedBox(
            height: 58,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: selected
                          ? FontWeight.w600
                          : FontWeight.normal,
                      color: selected ? cs.onSecondaryContainer : cs.onSurface,
                    ),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  hasError ? '失败' : '$count',
                  style: TextStyle(
                    fontSize: 11,
                    color: hasError
                        ? cs.error
                        : (selected
                              ? cs.onSecondaryContainer.withValues(alpha: 0.7)
                              : cs.onSurfaceVariant),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _resultPane() {
    final hits = _hits;
    if (_error != null && hits.isEmpty) {
      return _empty(
        icon: Icons.error_outline,
        text: _error!,
        action: '重试',
        onAction: () => _search(reset: false),
      );
    }
    if (hits.isEmpty) {
      return _empty(icon: Icons.search_off, text: _loading ? '搜索中…' : '没有搜索结果');
    }
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n.metrics.pixels >= n.metrics.maxScrollExtent - 200 &&
            _hasMore &&
            !_loading) {
          _loadMore();
        }
        return false;
      },
      child: ListView.builder(
        itemCount: hits.length + 1,
        itemBuilder: (ctx, i) {
          if (i == hits.length) {
            return Padding(
              padding: const EdgeInsets.all(16),
              child: Center(
                child: Text(
                  _loading ? '加载中…' : (_hasMore ? '上拉加载更多' : '没有更多了'),
                  style: TextStyle(
                    fontSize: 13,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            );
          }
          return _bookCell(hits[i]);
        },
      ),
    );
  }

  Widget _bookCell(_SearchHit hit) {
    final cs = Theme.of(context).colorScheme;
    final b = hit.book;
    return ListTile(
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: b.cover.isNotEmpty
            ? CoverImage(
                cover: b.cover,
                width: 44,
                height: 44,
                fit: BoxFit.cover,
                fallback: _coverFallback(cs),
              )
            : _coverFallback(cs),
      ),
      title: _ScrollingTitle(b.title, style: const TextStyle(fontSize: 16)),
      subtitle: b.author.isEmpty
          ? null
          : Text(b.author, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Container(
        constraints: const BoxConstraints(maxWidth: 84),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: cs.primaryContainer,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          hit.source.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 11, color: cs.onPrimaryContainer),
        ),
      ),
      onTap: () => _openBook(hit),
      onLongPress: () => _showBookMenu(hit),
    );
  }

  Widget _coverFallback(ColorScheme cs) => Container(
    width: 44,
    height: 44,
    color: cs.surfaceContainerHighest,
    child: Icon(Icons.menu_book, color: cs.onSurfaceVariant, size: 22),
  );

  Widget _empty({
    required IconData icon,
    required String text,
    String? action,
    VoidCallback? onAction,
  }) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: cs.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(
              text,
              textAlign: TextAlign.center,
              style: TextStyle(color: cs.onSurfaceVariant),
            ),
            if (action != null) ...[
              const SizedBox(height: 16),
              FilledButton.tonal(onPressed: onAction, child: Text(action)),
            ],
          ],
        ),
      ),
    );
  }
}

class _ScrollingTitle extends StatefulWidget {
  final String text;
  final TextStyle style;

  const _ScrollingTitle(this.text, {required this.style});

  @override
  State<_ScrollingTitle> createState() => _ScrollingTitleState();
}

class _ScrollingTitleState extends State<_ScrollingTitle> {
  final ScrollController _controller = ScrollController();
  bool _running = false;
  bool _disposed = false; // 防止 dispose 后异步回调操作 controller
  bool _tickerEnabled = true; // 同步缓存 TickerMode,避免异步间隙访问 context

  @override
  void didUpdateWidget(covariant _ScrollingTitle oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) {
      _running = false;
      if (_controller.hasClients && !_disposed) _controller.jumpTo(0);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _controller.dispose();
    super.dispose();
  }

  void _startIfNeeded(double maxWidth) {
    if (_running || _disposed || widget.text.isEmpty) return;
    final painter = TextPainter(
      text: TextSpan(text: widget.text, style: widget.style),
      maxLines: 1,
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: double.infinity);
    if (painter.width <= maxWidth) return;
    _running = true;
    Future<void>.delayed(const Duration(milliseconds: 700), _loop);
  }

  Future<void> _loop() async {
    // 仅在 widget 可见且 Ticker 启用时运行动画循环
    while (mounted && !_disposed && _running && _controller.hasClients) {
      if (!_tickerEnabled) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        continue;
      }
      final max = _controller.position.maxScrollExtent;
      if (max <= 0) {
        _running = false;
        return;
      }
      await _controller.animateTo(
        max,
        duration: Duration(milliseconds: (max * 28).clamp(1800, 7000).toInt()),
        curve: Curves.linear,
      );
      if (!mounted || _disposed || !_running) return;
      await Future<void>.delayed(const Duration(milliseconds: 900));
      await _controller.animateTo(
        0,
        duration: const Duration(milliseconds: 450),
        curve: Curves.easeOut,
      );
      await Future<void>.delayed(const Duration(milliseconds: 900));
    }
  }

  @override
  Widget build(BuildContext context) {
    // 同步缓存 TickerMode,供异步循环 _loop 使用
    _tickerEnabled = TickerMode.valuesOf(context).enabled;
    return LayoutBuilder(
      builder: (context, constraints) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _startIfNeeded(constraints.maxWidth);
        });
        return SizedBox(
          height: 22,
          child: SingleChildScrollView(
            controller: _controller,
            scrollDirection: Axis.horizontal,
            physics: const NeverScrollableScrollPhysics(),
            child: Text(
              widget.text,
              maxLines: 1,
              softWrap: false,
              style: widget.style,
            ),
          ),
        );
      },
    );
  }
}
