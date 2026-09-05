import 'package:flutter/material.dart';

import '../data/log_service.dart';
import '../source/models.dart';
import '../source/source_manager.dart';
import '../widgets/third_party_risk_dialog.dart';

class SubscriptionManageScreen extends StatefulWidget {
  const SubscriptionManageScreen({super.key});

  @override
  State<SubscriptionManageScreen> createState() =>
      _SubscriptionManageScreenState();
}

class _SubscriptionManageScreenState extends State<SubscriptionManageScreen> {
  List<SourceSubscriptionMeta> _subscriptions = const [];
  final Set<String> _busyIds = <String>{};
  bool _checkingAll = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  void _refresh() {
    setState(() {
      _subscriptions = SourceManager.instance.getSubscriptions();
    });
  }

  Future<void> _addSubscription() async {
    final draft = await showDialog<_SubscriptionDraft>(
      context: context,
      builder: (_) => const _SubscriptionEditDialog(),
    );
    if (draft == null) return;
    if (!mounted) return;
    if (!await confirmThirdPartySourceRisk(context)) return;
    setState(() => _checkingAll = true);
    try {
      final meta = await SourceManager.instance.saveSubscription(
        url: draft.url,
        name: draft.name,
        autoUpdate: draft.autoUpdate,
      );
      final result = await SourceManager.instance.syncSubscriptionById(meta.id);
      _refresh();
      _toast(
        '订阅添加完成：新增 ${result.added}，更新 ${result.updated}，删除 ${result.removed}',
      );
    } catch (e, stack) {
      LogService.instance.error('SourceSub', '添加订阅源失败', error: e, stack: stack);
      _toast(e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _checkingAll = false);
    }
  }

  Future<void> _checkAll() async {
    if (_subscriptions.isEmpty) return;
    setState(() => _checkingAll = true);
    try {
      final updates = <SourceSubscriptionMeta>[];
      for (final item in _subscriptions) {
        final result = await SourceManager.instance.checkSubscriptionById(
          item.id,
        );
        if (result.hasUpdate) updates.add(item);
      }
      _refresh();
      if (!mounted) return;
      if (updates.isEmpty) {
        _toast('所有订阅都已经是最新版本');
        return;
      }
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('发现订阅更新'),
          content: Text('共有 ${updates.length} 个订阅检测到新版本，是否立即同步？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('稍后'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('立即同步'),
            ),
          ],
        ),
      );
      if (ok != true) return;
      var added = 0;
      var updated = 0;
      var removed = 0;
      for (final item in updates) {
        final result = await SourceManager.instance.syncSubscriptionById(
          item.id,
        );
        added += result.added;
        updated += result.updated;
        removed += result.removed;
      }
      _refresh();
      _toast('批量同步完成：新增 $added，更新 $updated，删除 $removed');
    } catch (e, stack) {
      LogService.instance.error(
        'SourceSub',
        '批量检查订阅更新失败',
        error: e,
        stack: stack,
      );
      _toast(e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _checkingAll = false);
    }
  }

  Future<void> _checkOne(SourceSubscriptionMeta item) async {
    setState(() => _busyIds.add(item.id));
    try {
      final result = await SourceManager.instance.checkSubscriptionById(
        item.id,
      );
      _refresh();
      if (!result.hasUpdate) {
        _toast('${item.name} 已是最新版本');
        return;
      }
      if (!mounted) return;
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('检测到更新'),
          content: Text(
            '${item.name}\n远端版本：${result.version.isEmpty ? '未声明' : result.version}\n音源数：${result.sourceCount}\n\n是否立即同步？',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('稍后'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('立即同步'),
            ),
          ],
        ),
      );
      if (ok != true) return;
      final syncResult = await SourceManager.instance.syncSubscriptionById(
        item.id,
      );
      _refresh();
      _toast(
        '${item.name} 同步完成：新增 ${syncResult.added}，更新 ${syncResult.updated}，删除 ${syncResult.removed}',
      );
    } catch (e, stack) {
      LogService.instance.error(
        'SourceSub',
        '检查订阅更新失败',
        error: e,
        stack: stack,
      );
      _toast(e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) {
        setState(() => _busyIds.remove(item.id));
      }
    }
  }

  Future<void> _toggleAutoUpdate(
    SourceSubscriptionMeta item,
    bool value,
  ) async {
    await SourceManager.instance.setSubscriptionAutoUpdate(item.id, value);
    _refresh();
  }

  Future<void> _delete(SourceSubscriptionMeta item) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除订阅源'),
        content: Text('确定删除「${item.name}」吗？会同时移除这个订阅下的音源。'),
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
    if (ok != true) return;
    setState(() => _busyIds.add(item.id));
    try {
      await SourceManager.instance.deleteSubscription(item.id);
      _refresh();
      _toast('已删除 ${item.name}');
    } finally {
      if (mounted) setState(() => _busyIds.remove(item.id));
    }
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('订阅源管理'),
        actions: [
          IconButton(
            tooltip: '检查全部更新',
            onPressed: _checkingAll || _subscriptions.isEmpty
                ? null
                : _checkAll,
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: '添加订阅',
            onPressed: _checkingAll ? null : _addSubscription,
            icon: const Icon(Icons.add),
          ),
        ],
      ),
      body: _subscriptions.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Text(
                  '还没有订阅源，先添加一个订阅 JSON 链接。',
                  style: TextStyle(color: cs.onSurfaceVariant),
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              itemCount: _subscriptions.length,
              separatorBuilder: (_, _) => const SizedBox(height: 12),
              itemBuilder: (context, index) {
                final item = _subscriptions[index];
                final busy = _busyIds.contains(item.id);
                return Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: cs.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: cs.outlineVariant),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              item.name,
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          if (busy)
                            SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: cs.primary,
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      SelectableText(
                        item.originalUrl,
                        style: TextStyle(
                          fontSize: 12,
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          _chip(
                            cs,
                            '版本',
                            item.version.isEmpty ? '未同步' : item.version,
                          ),
                          _chip(cs, '音源数', '${item.sourceCount}'),
                          _chip(
                            cs,
                            '上次检查',
                            item.lastCheckedAt.isEmpty
                                ? '未检查'
                                : _formatTime(item.lastCheckedAt),
                          ),
                        ],
                      ),
                      if (item.lastUpdatedAt.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(
                          '上次更新：${_formatTime(item.lastUpdatedAt)}',
                          style: TextStyle(
                            fontSize: 12,
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ],
                      if (item.lastError.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(
                          item.lastError,
                          style: TextStyle(fontSize: 12, color: cs.error),
                        ),
                      ],
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          const Icon(Icons.autorenew, size: 18),
                          const SizedBox(width: 8),
                          const Expanded(child: Text('自动更新')),
                          Switch(
                            value: item.autoUpdate,
                            onChanged: busy
                                ? null
                                : (value) => _toggleAutoUpdate(item, value),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: busy ? null : () => _checkOne(item),
                              icon: const Icon(Icons.sync),
                              label: const Text('检查更新'),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: FilledButton.tonalIcon(
                              onPressed: busy ? null : () => _delete(item),
                              icon: const Icon(Icons.delete_outline),
                              label: const Text('删除'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                );
              },
            ),
      floatingActionButton: _subscriptions.isEmpty
          ? FloatingActionButton(
              onPressed: _checkingAll ? null : _addSubscription,
              child: const Icon(Icons.add),
            )
          : null,
    );
  }

  Widget _chip(ColorScheme cs, String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        '$label $value',
        style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
      ),
    );
  }

  String _formatTime(String raw) {
    final dt = DateTime.tryParse(raw)?.toLocal();
    if (dt == null) return raw;
    final mm = dt.month.toString().padLeft(2, '0');
    final dd = dt.day.toString().padLeft(2, '0');
    final hh = dt.hour.toString().padLeft(2, '0');
    final min = dt.minute.toString().padLeft(2, '0');
    return '$mm-$dd $hh:$min';
  }
}

class _SubscriptionDraft {
  final String name;
  final String url;
  final bool autoUpdate;

  const _SubscriptionDraft({
    required this.name,
    required this.url,
    required this.autoUpdate,
  });
}

class _SubscriptionEditDialog extends StatefulWidget {
  const _SubscriptionEditDialog();

  @override
  State<_SubscriptionEditDialog> createState() =>
      _SubscriptionEditDialogState();
}

class _SubscriptionEditDialogState extends State<_SubscriptionEditDialog> {
  final TextEditingController _nameCtrl = TextEditingController();
  final TextEditingController _urlCtrl = TextEditingController(
    text: SourceManager.instance.subscriptionUrl,
  );
  bool _autoUpdate = true;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _urlCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('添加订阅源'),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _nameCtrl,
                decoration: const InputDecoration(
                  labelText: '订阅名称',
                  hintText: '可选，不填则取域名',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _urlCtrl,
                minLines: 2,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: '订阅地址',
                  hintText: 'https://.../sources.json',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  const Expanded(child: Text('开启自动更新')),
                  Switch(
                    value: _autoUpdate,
                    onChanged: (value) => setState(() => _autoUpdate = value),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            Navigator.pop(
              context,
              _SubscriptionDraft(
                name: _nameCtrl.text.trim(),
                url: _urlCtrl.text.trim(),
                autoUpdate: _autoUpdate,
              ),
            );
          },
          child: const Text('添加'),
        ),
      ],
    );
  }
}
