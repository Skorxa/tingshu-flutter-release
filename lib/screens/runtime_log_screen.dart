import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/log_service.dart';

class RuntimeLogScreen extends StatefulWidget {
  /// 打开后定位并高亮到该 id 的日志条目(用于音源调试结果跳转)。
  final int? focusLogId;

  const RuntimeLogScreen({super.key, this.focusLogId});

  @override
  State<RuntimeLogScreen> createState() => _RuntimeLogScreenState();
}

class _RuntimeLogScreenState extends State<RuntimeLogScreen> {
  final ScrollController _scrollController = ScrollController();
  final GlobalKey _focusKey = GlobalKey();
  String _filterLevel = 'all'; // all, error, warn, info

  @override
  void initState() {
    super.initState();
    if (widget.focusLogId != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final ctx = _focusKey.currentContext;
        if (ctx == null) return;
        Scrollable.ensureVisible(
          ctx,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
          alignment: 0.3,
        );
      });
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final logs = LogService.instance;
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('运行日志'),
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.filter_list),
            tooltip: '筛选',
            initialValue: _filterLevel,
            onSelected: (value) => setState(() => _filterLevel = value),
            itemBuilder: (context) => [
              const PopupMenuItem(value: 'all', child: Text('全部')),
              const PopupMenuItem(value: 'error', child: Text('错误')),
              const PopupMenuItem(value: 'warn', child: Text('警告')),
              const PopupMenuItem(value: 'info', child: Text('信息')),
            ],
          ),
          IconButton(
            icon: const Icon(Icons.ios_share),
            tooltip: '导出诊断报告',
            onPressed: () async {
              final report = LogService.instance.buildDiagnosticReport();
              await Clipboard.setData(ClipboardData(text: report));
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('诊断报告已复制到剪贴板（已做尽力脱敏，粘贴前请再人工检查）'),
                ),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.delete_sweep_outlined),
            tooltip: '清空',
            onPressed: () async {
              final confirm = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('清空日志'),
                  content: const Text('确定要清空所有运行日志吗？'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('取消'),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: const Text('清空'),
                    ),
                  ],
                ),
              );
              if (confirm == true) logs.clear();
            },
          ),
        ],
      ),
      body: AnimatedBuilder(
        animation: logs,
        builder: (context, _) {
          final allEntries = logs.entries;
          final entries = _filterLevel == 'all'
              ? allEntries
              : allEntries.where((e) {
                  if (_filterLevel == 'error') return e.level == 'ERROR';
                  if (_filterLevel == 'warn') return e.level == 'WARN';
                  return e.level == 'INFO';
                }).toList();

          if (entries.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.article_outlined,
                    size: 48,
                    color: cs.onSurfaceVariant,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    _filterLevel == 'all' ? '暂无运行日志' : '该类型暂无日志',
                    style: TextStyle(color: cs.onSurfaceVariant),
                  ),
                ],
              ),
            );
          }
          return ListView.separated(
            controller: _scrollController,
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
            itemCount: entries.length,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (context, index) {
              final entry = entries[index];
              final focus = entry.id == widget.focusLogId;
              return _LogTile(
                key: focus ? _focusKey : null,
                entry: entry,
                highlight: focus,
              );
            },
          );
        },
      ),
    );
  }
}

class _LogTile extends StatelessWidget {
  final AppLogEntry entry;
  final bool highlight;

  const _LogTile({super.key, required this.entry, this.highlight = false});

  Future<void> _copy(BuildContext context) async {
    final text = [
      entry.level,
      entry.module,
      entry.displayTime,
      entry.message,
      if (entry.detail != null && entry.detail!.isNotEmpty) entry.detail!,
    ].join('\n');
    await Clipboard.setData(ClipboardData(text: text));
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('已复制日志')));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final color = switch (entry.level) {
      'ERROR' => cs.error,
      'WARN' => const Color(0xFFE37318), // 警告橙:M3 无内置 warning,保留语义色
      _ => cs.primary,
    };
    return DecoratedBox(
      decoration: BoxDecoration(
        color: highlight
            ? cs.primaryContainer.withValues(alpha: 0.45)
            : cs.surfaceContainerLow,
        border: Border.all(
          color: highlight ? cs.primary : cs.outlineVariant,
          width: highlight ? 1.5 : 1,
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    entry.level,
                    style: TextStyle(
                      color: color,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    entry.module,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      entry.displayTime,
                      style: TextStyle(
                        fontSize: 12,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(width: 4),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      iconSize: 18,
                      tooltip: '复制日志',
                      onPressed: () => _copy(context),
                      icon: const Icon(Icons.copy_outlined),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              entry.message,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
            ),
            if (entry.detail != null && entry.detail!.isNotEmpty) ...[
              const SizedBox(height: 8),
              SelectableText(
                entry.detail!,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.35,
                  fontFamily: 'monospace',
                  color: cs.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
