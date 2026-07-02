import 'package:flutter/material.dart';

import '../data/cache_service.dart';
import '../data/settings_service.dart';
import '../widgets/cover_image.dart';

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
        builder: (context, _) => ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: [
            _summaryCard(cs, snapshot),
            const SizedBox(height: 16),
            _sectionTitle(context, '自动缓存'),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.download_for_offline_outlined),
              title: const Text('自动缓存后续章节'),
              subtitle: const Text('播放时从当前集往后缓存'),
              trailing: Switch(
                value: settings.autoCache,
                onChanged: settings.setAutoCache,
              ),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.format_list_numbered),
              title: const Text('每本书最大缓存集数'),
              subtitle: const Text('按当前正在播放的集数往后计算'),
              trailing: Text(
                '${settings.maxCacheChapters} 集',
                style: TextStyle(color: cs.onSurfaceVariant),
              ),
              onTap: () => _chooseInt(
                title: '每本书最大缓存集数',
                current: settings.maxCacheChapters,
                options: SettingsService.cacheChapterOptions,
                label: (v) => '$v 集',
                onSelected: settings.setMaxCacheChapters,
              ),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.schedule),
              title: const Text('缓存频率'),
              subtitle: const Text('自动缓存任务检查间隔'),
              trailing: Text(
                settings.cacheFrequencyLabel,
                style: TextStyle(color: cs.onSurfaceVariant),
              ),
              onTap: () => _chooseFrequency(settings),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.cleaning_services_outlined),
              title: const Text('自动清理缓存文件'),
              subtitle: const Text('超过指定数量后从最老缓存开始清理'),
              trailing: Text(
                settings.cleanupLimitLabel,
                style: TextStyle(color: cs.onSurfaceVariant),
              ),
              onTap: () => _chooseInt(
                title: '自动清理缓存文件',
                current: settings.cleanupLimit,
                options: SettingsService.cleanupLimitOptions,
                label: (v) => v == 0 ? '不清理' : '$v 集',
                onSelected: settings.setCleanupLimit,
              ),
            ),
            const SizedBox(height: 12),
            _sectionTitle(context, '缓存内容'),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.tonalIcon(
                  onPressed: snapshot == null || snapshot.totalFiles == 0
                      ? null
                      : () => _setAllSelected(!allSelected),
                  icon: Icon(
                    allSelected
                        ? Icons.check_box_outline_blank
                        : Icons.select_all,
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
            const SizedBox(height: 12),
            if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 48),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_error != null)
              _emptyState(
                context,
                icon: Icons.error_outline,
                title: '缓存读取失败',
                subtitle: _error!,
              )
            else if (snapshot == null || snapshot.books.isEmpty)
              _emptyState(
                context,
                icon: Icons.folder_off_outlined,
                title: '暂无音频缓存',
                subtitle: '自动缓存或手动缓存后的章节会出现在这里',
              )
            else
              ...snapshot.books.map((book) => _bookTile(context, book)),
          ],
        ),
      ),
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
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Column(
        children: [
          InkWell(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
            onTap: () => _toggleBookExpanded(book),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Checkbox(
                    tristate: true,
                    value: _bookSelectionValue(book),
                    onChanged: (value) =>
                        _toggleBookSelection(book, value ?? false),
                  ),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: CoverImage(
                      cover: book.cover,
                      width: 46,
                      height: 46,
                      fallback: Container(
                        width: 46,
                        height: 46,
                        color: cs.surfaceContainerHighest,
                        child: Icon(
                          Icons.book_outlined,
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ),
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
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '${book.sourceName} · ${book.entries.length} 集 · ${_formatBytes(book.totalBytes)}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '最近缓存 ${_formatTime(book.latestCachedAt)}',
                          style: TextStyle(
                            fontSize: 12,
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 4),
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
      contentPadding: const EdgeInsets.symmetric(horizontal: 12),
      controlAffinity: ListTileControlAffinity.leading,
      title: Text(
        '第 ${entry.chapterIdx + 1} 集  ${entry.chapterName.isEmpty ? entry.chapterId : entry.chapterName}',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        '${_formatBytes(entry.size)} · ${_formatTime(entry.cachedAt)}',
        style: TextStyle(color: cs.onSurfaceVariant),
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
