import 'package:flutter/material.dart';

import '../data/settings_service.dart';
import '../source/models.dart';
import '../source/source_manager.dart';

class DiscoverSourceSettingScreen extends StatefulWidget {
  const DiscoverSourceSettingScreen({super.key});

  @override
  State<DiscoverSourceSettingScreen> createState() =>
      _DiscoverSourceSettingScreenState();
}

class _DiscoverSourceSettingScreenState
    extends State<DiscoverSourceSettingScreen> {
  List<SourceMeta> _sources = [];

  @override
  void initState() {
    super.initState();
    _sources = _supportedSources();
  }

  List<SourceMeta> _supportedSources() {
    return SourceManager.instance
        .getSources()
        .where((s) => s.supportsDiscover)
        .toList();
  }

  Future<void> _setSelection(List<String> ids) async {
    await SettingsService.instance.setDiscoverSourceIds(ids);
    if (mounted) setState(() {});
  }

  Future<void> _toggle(SourceMeta source) async {
    final settings = SettingsService.instance;
    final supportedIds = _sources.map((s) => s.id).toList();
    final current = settings.discoverSelectionConfigured
        ? List<String>.from(settings.discoverSourceIds)
        : List<String>.from(supportedIds);
    if (current.contains(source.id)) {
      current.remove(source.id);
    } else {
      current.add(source.id);
    }
    await _setSelection(current);
  }

  @override
  Widget build(BuildContext context) {
    final settings = SettingsService.instance;
    final cs = Theme.of(context).colorScheme;
    final enabledSources = _sources.where((s) => s.enabled).toList();
    final selectedCount = enabledSources
        .where((s) => settings.isDiscoverSourceSelected(s.id))
        .length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('发现页音源'),
        actions: [
          IconButton(
            tooltip: '全选',
            icon: const Icon(Icons.select_all),
            onPressed: _sources.isEmpty
                ? null
                : () => _setSelection(_sources.map((s) => s.id).toList()),
          ),
          IconButton(
            tooltip: '清空',
            icon: const Icon(Icons.deselect),
            onPressed: _sources.isEmpty ? null : () => _setSelection(const []),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
            child: Text(
              '选择要出现在首页发现页的音源，可多选。未手动设置时默认使用全部支持发现页的已启用音源。',
              style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
            child: Text(
              '已选择 $selectedCount / ${enabledSources.length} 个已启用音源',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: cs.onSurface,
              ),
            ),
          ),
          if (_sources.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 48),
              child: Center(
                child: Text(
                  '当前没有支持发现页的音源',
                  style: TextStyle(color: cs.onSurfaceVariant),
                ),
              ),
            )
          else
            ..._sources.map(
              (s) => Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  leading: Icon(
                    settings.isDiscoverSourceSelected(s.id)
                        ? Icons.explore
                        : Icons.explore_outlined,
                    color: settings.isDiscoverSourceSelected(s.id)
                        ? cs.primary
                        : cs.onSurfaceVariant,
                  ),
                  title: Text(s.name),
                  subtitle: Text(
                    '${s.id} · ${s.enabled ? '已启用' : '已关闭，开启后才会显示'}',
                  ),
                  trailing: Checkbox(
                    value: settings.isDiscoverSourceSelected(s.id),
                    onChanged: (_) => _toggle(s),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
