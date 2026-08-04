import 'package:flutter/material.dart';

import '../data/log_service.dart';
import '../data/settings_service.dart';
import '../source/models.dart';
import '../source/source_manager.dart';
import '../widgets/cover_image.dart';
import 'catalog_screen.dart';

class DiscoverScreen extends StatefulWidget {
  const DiscoverScreen({super.key});

  @override
  State<DiscoverScreen> createState() => _DiscoverScreenState();
}

class _DiscoverSourceState {
  final SourceMeta source;
  DiscoverResult? result;
  String? error;
  bool loading = true;

  _DiscoverSourceState(this.source);
}

class _DiscoverScreenState extends State<DiscoverScreen> {
  final Map<String, _DiscoverSourceState> _states = {};
  bool _firstLoading = true;
  int _lastDiscoverRevision = SettingsService.instance.discoverRevision;

  @override
  void initState() {
    super.initState();
    SettingsService.instance.addListener(_onSettingsChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _reload());
  }

  @override
  void dispose() {
    SettingsService.instance.removeListener(_onSettingsChanged);
    super.dispose();
  }

  void _onSettingsChanged() {
    if (!mounted) return;
    final revision = SettingsService.instance.discoverRevision;
    if (revision == _lastDiscoverRevision) return;
    _lastDiscoverRevision = revision;
    _reload();
  }

  Future<void> _reload() async {
    final settings = SettingsService.instance;
    final sources = SourceManager.instance
        .getSources()
        .where(
          (s) =>
              s.enabled &&
              s.supportsDiscover &&
              settings.isDiscoverSourceSelected(s.id),
        )
        .toList();

    final Map<String, _DiscoverSourceState> next = {
      for (final s in sources) s.id: _DiscoverSourceState(s),
    };
    for (final entry in _states.entries) {
      final existing = next[entry.key];
      if (existing != null) {
        existing.result = entry.value.result;
        existing.error = entry.value.error;
        existing.loading = entry.value.loading;
      }
    }

    setState(() {
      _states
        ..clear()
        ..addEntries(next.entries);
      _firstLoading = true;
    });

    if (sources.isEmpty) {
      setState(() => _firstLoading = false);
      return;
    }

    await Future.wait(sources.map(_loadSource));
    if (mounted) setState(() => _firstLoading = false);
  }

  Future<void> _loadSource(SourceMeta source) async {
    try {
      final res = await SourceManager.instance.discoverFromSource(source.id);
      if (!mounted) return;
      final st = _states[source.id];
      if (st == null) return;
      setState(() {
        st
          ..result = res
          ..error = null
          ..loading = false;
      });
      LogService.instance.info(
        'Discover',
        '发现页加载完成',
        detail: '音源: ${source.name}\n段数: ${res.sections.length}',
      );
    } catch (e) {
      if (!mounted) return;
      final st = _states[source.id];
      if (st == null) return;
      setState(() {
        st
          ..error = e.toString().replaceFirst('Exception: ', '')
          ..loading = false;
      });
      LogService.instance.warning(
        'Discover',
        '发现页加载失败',
        detail: '音源: ${source.name}\n错误: $e',
      );
    }
  }

  Future<void> _openBook(SourceMeta source, Book book) async {
    await SourceManager.instance.setActive(source.id);
    if (!mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => CatalogScreen(book: book, sourceId: source.id),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final settings = SettingsService.instance;
    final states = _states.values.toList();
    final enabledSources = SourceManager.instance
        .getSources()
        .where((s) => s.enabled)
        .length;
    final selectedEnabledCount = SourceManager.instance
        .getSources()
        .where(
          (s) =>
              s.enabled &&
              s.supportsDiscover &&
              settings.isDiscoverSourceSelected(s.id),
        )
        .length;

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: RefreshIndicator(
          onRefresh: _reload,
          child: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              SliverAppBar.large(
                title: const Text('发现'),
                pinned: true,
                stretch: true,
                actions: [
                  IconButton(
                    icon: const Icon(Icons.refresh),
                    tooltip: '刷新',
                    onPressed: _reload,
                  ),
                ],
              ),
              if (_firstLoading)
                const SliverFillRemaining(
                  hasScrollBody: false,
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: CircularProgressIndicator()),
                  ),
                )
              else if (states.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: _empty(
                    cs: cs,
                    icon: Icons.explore_off_outlined,
                    text: enabledSources == 0
                        ? '还没有可用的音源\n去设置页添加或开启音源吧'
                        : (settings.discoverSelectionConfigured &&
                              settings.discoverSourceIds.isEmpty)
                        ? '没有选择发现页音源\n去设置页选择吧'
                        : (selectedEnabledCount == 0 &&
                              settings.discoverSelectionConfigured)
                        ? '已选择的发现页音源未开启\n开启后回到这里刷新'
                        : '当前音源都不支持发现页\n需要音源实现 discover 方法',
                  ),
                )
              else
                ...states.map((st) => _sourceSliver(cs, st)),
              const SliverToBoxAdapter(child: SizedBox(height: 24)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sourceSliver(ColorScheme cs, _DiscoverSourceState st) {
    if (st.loading) {
      return SliverToBoxAdapter(
        child: _sectionCard(
          cs: cs,
          title: st.source.name,
          child: const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(
              child: SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2.5),
              ),
            ),
          ),
        ),
      );
    }
    if (st.error != null) {
      return SliverToBoxAdapter(
        child: _sectionCard(
          cs: cs,
          title: st.source.name,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
            child: Row(
              children: [
                Icon(Icons.error_outline, color: cs.error, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    st.error!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
                  ),
                ),
                TextButton(
                  onPressed: () => _loadSource(st.source),
                  child: const Text('重试'),
                ),
              ],
            ),
          ),
        ),
      );
    }
    final sections = st.result?.sections ?? const <DiscoverSection>[];
    if (sections.isEmpty) {
      return SliverToBoxAdapter(
        child: _sectionCard(
          cs: cs,
          title: st.source.name,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Text(
              '暂无内容',
              style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
            ),
          ),
        ),
      );
    }
    return SliverList(
      delegate: SliverChildBuilderDelegate((context, i) {
        if (i >= sections.length) return null;
        return _sectionCard(
          cs: cs,
          title: sections[i].title.isEmpty
              ? st.source.name
              : '${st.source.name} · ${sections[i].title}',
          child: _bookRow(cs, st.source, sections[i].list),
        );
      }, childCount: sections.length),
    );
  }

  Widget _sectionCard({
    required ColorScheme cs,
    required String title,
    required Widget child,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 8),
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: cs.onSurface,
              ),
            ),
          ),
          Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
              child: child,
            ),
          ),
        ],
      ),
    );
  }

  Widget _bookRow(ColorScheme cs, SourceMeta source, List<Book> books) {
    if (books.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
        child: Text(
          '暂无内容',
          style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
        ),
      );
    }
    return SizedBox(
      height: 168,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        itemCount: books.length,
        separatorBuilder: (_, _) => const SizedBox(width: 10),
        itemBuilder: (context, i) => _bookCard(cs, source, books[i]),
      ),
    );
  }

  Widget _bookCard(ColorScheme cs, SourceMeta source, Book book) {
    return InkWell(
      onTap: () => _openBook(source, book),
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        width: 104,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: book.cover.isNotEmpty
                  ? CoverImage(
                      cover: book.cover,
                      width: 104,
                      height: 132,
                      fit: BoxFit.cover,
                      fallback: _coverFallback(cs),
                    )
                  : _coverFallback(cs, width: 104, height: 132),
            ),
            const SizedBox(height: 6),
            Text(
              book.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, height: 1.25),
            ),
          ],
        ),
      ),
    );
  }

  Widget _coverFallback(
    ColorScheme cs, {
    double width = 104,
    double height = 132,
  }) {
    return Container(
      width: width,
      height: height,
      color: cs.surfaceContainerHighest,
      child: Icon(Icons.menu_book, color: cs.onSurfaceVariant, size: 28),
    );
  }

  Widget _empty({
    required ColorScheme cs,
    required IconData icon,
    required String text,
  }) {
    return Padding(
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
        ],
      ),
    );
  }
}
