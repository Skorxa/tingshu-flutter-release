import 'package:flutter/material.dart';

import '../data/cache_service.dart';
import '../data/settings_service.dart';

class CacheManageScreen extends StatefulWidget {
  const CacheManageScreen({super.key});

  @override
  State<CacheManageScreen> createState() => _CacheManageScreenState();
}

class _CacheManageScreenState extends State<CacheManageScreen> {
  CacheLibrarySnapshot? _snapshot;
  bool _loading = true;
  String? _error;
  int _cacheVersion = -1;
  final Set<String> _selectedKeys = {};
  final Set<String> _expandedBooks = {};

  @override
  void initState() {
    super.initState();
    CacheService.instance.addListener(_onCacheChanged);
    _loadLibrary();
  }

  @override
  void dispose() {
    CacheService.instance.removeListener(_onCacheChanged);
    super.dispose();
  }

  void _onCacheChanged() {
    final version = CacheService.instance.cacheVersion;
    if (version == _cacheVersion) return;
    _loadLibrary();
  }

  Future<void> _loadLibrary({bool showLoading = true}) async {
    if (showLoading && mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final snapshot = await CacheService.instance.loadLibrary();
      final validKeys = snapshot.books
          .expand((book) => book.entries)
          .map((entry) => entry.key)
          .toSet();
      if (!mounted) return;
      setState(() {
        _snapshot = snapshot;
        _loading = false;
        _error = null;
        _cacheVersion = CacheService.instance.cacheVersion;
        _selectedKeys.removeWhere((key) => !validKeys.contains(key));
        _expandedBooks.removeWhere(
          (key) => !snapshot.books.any((book) => book.key == key),
        );
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  Future<void> _chooseInt({
    required String title,
    required int current,
    required List<int> options,
    required String Function(int value) label,
    required ValueChanged<int> onSelected,
  }) async {
    final value = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(title),
        children: [
          for (final option in options)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, option),
              child: Row(
                children: [
                  Expanded(child: Text(label(option))),
                  if (option == current) const Icon(Icons.check, size: 20),
                ],
              ),
            ),
        ],
      ),
    );
    if (value != null) onSelected(value);
  }

  Future<void> _chooseFrequency(SettingsService settings) async {
    final value = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('缓存频率'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'standard'),
            child: Row(
              children: [
                const Expanded(child: Text('标准（1分钟）')),
                if (settings.cacheFrequency == 'standard')
                  const Icon(Icons.check, size: 20),
              ],
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'fast'),
            child: Row(
              children: [
                const Expanded(child: Text('快（3分钟）')),
                if (settings.cacheFrequency == 'fast')
                  const Icon(Icons.check, size: 20),
              ],
            ),
          ),
        ],
      ),
    );
    if (value != null) settings.setCacheFrequency(value);
  }

  List<CachedAudioEntry> get _selectedEntries {
    final snapshot = _snapshot;
    if (snapshot == null) return const [];
    return snapshot.books
        .expand((book) => book.entries)
        .where((entry) => _selectedKeys.contains(entry.key))
        .toList(growable: false);
  }

  void _setAllSelected(bool selected) {
    final snapshot = _snapshot;
    if (snapshot == null) return;
    setState(() {
      _selectedKeys.clear();
      if (selected) {
        _selectedKeys.addAll(
          snapshot.books
              .expand((book) => book.entries)
              .map((entry) => entry.key),
        );
      }
    });
  }

  bool? _bookSelectionValue(CachedAudioBook book) {
    final selectedCount = book.entries
        .where((entry) => _selectedKeys.contains(entry.key))
        .length;
    if (selectedCount == 0) return false;
    if (selectedCount == book.entries.length) return true;
    return null;
  }

  void _toggleBookSelection(CachedAudioBook book, bool selected) {
    setState(() {
      for (final entry in book.entries) {
        if (selected) {
          _selectedKeys.add(entry.key);
        } else {
          _selectedKeys.remove(entry.key);
        }
      }
    });
  }

  void _toggleEntrySelection(CachedAudioEntry entry, bool selected) {
    setState(() {
      if (selected) {
        _selectedKeys.add(entry.key);
      } else {
        _selectedKeys.remove(entry.key);
      }
    });
  }

  void _toggleBookExpanded(CachedAudioBook book) {
    setState(() {
      if (!_expandedBooks.add(book.key)) {
        _expandedBooks.remove(book.key);
      }
    });
  }

  Future<void> _deleteSelected() async {
    final entries = _selectedEntries;
    if (entries.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除选中缓存'),
        content: Text('将删除 ${entries.length} 集缓存文件，无法恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final result = await CacheService.instance.removeEntries(entries);
    if (!mounted) return;
    setState(() => _selectedKeys.clear());
    await _loadLibrary(showLoading: false);
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          '已删除 ${result.rows} 条缓存，释放 ${_formatBytes(result.bytes)}',
        ),
      ),
    );
  }

  Future<void> _clearAll() async {
    final snapshot = _snapshot;
    if (snapshot == null || snapshot.totalFiles == 0) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('卸载全部缓存'),
        content: Text('将删除全部 ${snapshot.totalFiles} 集缓存文件，无法恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('全部删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final result = await CacheService.instance.clearAllAudioCache();
    if (!mounted) return;
    setState(() => _selectedKeys.clear());
    await _loadLibrary(showLoading: false);
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          '已删除 ${result.rows} 条缓存，释放 ${_formatBytes(result.bytes)}',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = SettingsService.instance;
    final cs = Theme.of(context).colorScheme;
    final snapshot = _snapshot;
    final allSelected =
        snapshot != null &&
        snapshot.totalFiles > 0 &&
        _selectedKeys.length == snapshot.totalFiles;

    return Scaffold(
      appBar: AppBar(
        title: const Text('缓存管理'),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: _loading ? null : () => _loadLibrary(),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: AnimatedBuilder(
        animation: settings,
        builder: (context, _) => CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _summaryCard(cs, snapshot),
                    const SizedBox(height: 16),
                    _buildSettingsSection(context, settings, cs),
                    const SizedBox(height: 16),
                    _buildActionsSection(context, cs, snapshot, allSelected),
                  ],
                ),
              ),
            ),
            if (_loading)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_error != null)
              SliverFillRemaining(
                hasScrollBody: false,
                child: _emptyState(
                  context,
                  icon: Icons.error_outline,
                  title: '缓存读取失败',
                  subtitle: _error!,
                ),
              )
            else if (snapshot == null || snapshot.books.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: _emptyState(
                  context,
                  icon: Icons.folder_off_outlined,
                  title: '暂无音频缓存',
                  subtitle: '自动缓存或手动缓存后的章节会出现在这里',
                ),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
                sliver: SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, index) =>
                        _bookTile(context, snapshot.books[index]),
                    childCount: snapshot.books.length,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildSettingsSection(
    BuildContext context,
    SettingsService settings,
    ColorScheme cs,
  ) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.settings_outlined, size: 20, color: cs.primary),
              const SizedBox(width: 8),
              Text(
                '自动缓存设置',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: cs.primary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _settingRow(
            icon: Icons.download_for_offline_outlined,
            title: '自动缓存当前及后续章节',
            subtitle: '缓存数量从当前正在播放的集数开始计算',
            trailing: Switch(
              value: settings.autoCache,
              onChanged: settings.setAutoCache,
            ),
          ),
          const Divider(height: 24, indent: 40),
          _settingRow(
            icon: Icons.format_list_numbered,
            title: '每本书最大缓存集数',
            subtitle: '${settings.maxCacheChapters} 集（包含当前集）',
            trailing: const Icon(Icons.chevron_right, size: 20),
            onTap: () => _chooseInt(
              title: '每本书最大缓存集数',
              current: settings.maxCacheChapters,
              options: SettingsService.cacheChapterOptions,
              label: (v) => '$v 集',
              onSelected: settings.setMaxCacheChapters,
            ),
          ),
          const Divider(height: 24, indent: 40),
          _settingRow(
            icon: Icons.schedule,
            title: '缓存频率',
            subtitle: settings.cacheFrequencyLabel,
            trailing: const Icon(Icons.chevron_right, size: 20),
            onTap: () => _chooseFrequency(settings),
          ),
          const Divider(height: 24, indent: 40),
          _settingRow(
            icon: Icons.cleaning_services_outlined,
            title: '自动清理缓存',
            subtitle: settings.cleanupLimitLabel,
            trailing: const Icon(Icons.chevron_right, size: 20),
            onTap: () => _chooseInt(
              title: '自动清理缓存文件',
              current: settings.cleanupLimit,
              options: SettingsService.cleanupLimitOptions,
              label: (v) => v == 0 ? '不清理' : '$v 集',
              onSelected: settings.setCleanupLimit,
            ),
          ),
        ],
      ),
    );
  }

  Widget _settingRow({
    required IconData icon,
    required String title,
    required String subtitle,
    Widget? trailing,
    VoidCallback? onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: Row(
          children: [
            Icon(icon, size: 22),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(fontSize: 14)),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            ...?(trailing == null ? null : [trailing]),
          ],
        ),
      ),
    );
  }

  Widget _buildActionsSection(
    BuildContext context,
    ColorScheme cs,
    CacheLibrarySnapshot? snapshot,
    bool allSelected,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle(context, '缓存内容'),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.tonalIcon(
              onPressed: snapshot == null || snapshot.totalFiles == 0
                  ? null
                  : () => _setAllSelected(!allSelected),
              icon: Icon(
                allSelected ? Icons.check_box_outline_blank : Icons.select_all,
              ),
              label: Text(allSelected ? '取消全选' : '全选'),
            ),
            OutlinedButton.icon(
              onPressed: _selectedKeys.isEmpty
                  ? null
                  : () => setState(() => _selectedKeys.clear()),
              icon: const Icon(Icons.deselect),
              label: const Text('清空选择'),
            ),
            FilledButton.icon(
              onPressed: _selectedKeys.isEmpty ? null : _deleteSelected,
              icon: const Icon(Icons.delete_outline),
              label: Text('删除选中 (${_selectedKeys.length})'),
            ),
            OutlinedButton.icon(
              onPressed: snapshot == null || snapshot.totalFiles == 0
                  ? null
                  : _clearAll,
              icon: const Icon(Icons.delete_sweep_outlined),
              label: const Text('卸载全部'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _summaryCard(ColorScheme cs, CacheLibrarySnapshot? snapshot) {
    final books = snapshot?.books.length ?? 0;
    final files = snapshot?.totalFiles ?? 0;
    final bytes = snapshot?.totalBytes ?? 0;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          _summaryStat(cs, '书籍', '$books 本'),
          _summaryStat(cs, '章节', '$files 集'),
          _summaryStat(cs, '占用', _formatBytes(bytes)),
        ],
      ),
    );
  }

  Widget _summaryStat(ColorScheme cs, String label, String value) {
    return Container(
      constraints: const BoxConstraints(minWidth: 92, maxWidth: 180),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }

  Widget _bookTile(BuildContext context, CachedAudioBook book) {
    final cs = Theme.of(context).colorScheme;
    final expanded = _expandedBooks.contains(book.key);
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Column(
        children: [
          InkWell(
            onTap: () => _toggleBookExpanded(book),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Checkbox(
                    tristate: true,
                    value: _bookSelectionValue(book),
                    onChanged: (value) =>
                        _toggleBookSelection(book, value ?? false),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          book.bookTitle.isEmpty ? book.bookId : book.bookTitle,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          children: [
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
                                book.sourceName,
                                style: TextStyle(
                                  fontSize: 11,
                                  color: cs.onSecondaryContainer,
                                ),
                              ),
                            ),
                            Text(
                              '${book.entries.length} 集 · ${_formatBytes(book.totalBytes)}',
                              style: TextStyle(
                                fontSize: 12,
                                color: cs.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '最近缓存 ${_formatTime(book.latestCachedAt)}',
                          style: TextStyle(
                            fontSize: 11,
                            color: cs.onSurfaceVariant.withValues(alpha: 0.7),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(
                    expanded ? Icons.expand_less : Icons.expand_more,
                    color: cs.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
          if (expanded) ...[
            Divider(height: 1, color: cs.outlineVariant),
            ...book.entries.map((entry) => _chapterTile(context, entry)),
          ],
        ],
      ),
    );
  }

  Widget _chapterTile(BuildContext context, CachedAudioEntry entry) {
    final cs = Theme.of(context).colorScheme;
    return CheckboxListTile(
      value: _selectedKeys.contains(entry.key),
      onChanged: (value) => _toggleEntrySelection(entry, value ?? false),
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      controlAffinity: ListTileControlAffinity.leading,
      title: Text(
        entry.chapterName.isEmpty ? entry.chapterId : entry.chapterName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 14),
      ),
      subtitle: Text(
        '第 ${entry.chapterIdx + 1} 集 · ${_formatBytes(entry.size)}',
        style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
      ),
    );
  }

  Widget _emptyState(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 44, color: cs.onSurfaceVariant),
          const SizedBox(height: 12),
          Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: TextStyle(color: cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(BuildContext context, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }

  String _formatBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    const units = ['B', 'KB', 'MB', 'GB'];
    var value = bytes.toDouble();
    var idx = 0;
    while (value >= 1024 && idx < units.length - 1) {
      value /= 1024;
      idx++;
    }
    final fraction = idx == 0 ? 0 : 1;
    return '${value.toStringAsFixed(fraction)} ${units[idx]}';
  }

  String _formatTime(int millis) {
    if (millis <= 0) return '时间未知';
    final dt = DateTime.fromMillisecondsSinceEpoch(millis);
    String two(int value) => value.toString().padLeft(2, '0');
    return '${dt.month}-${dt.day} ${two(dt.hour)}:${two(dt.minute)}';
  }
}
