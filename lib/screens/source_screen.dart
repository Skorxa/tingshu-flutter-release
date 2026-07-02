import 'package:flutter/material.dart';

import '../data/listening_stats_service.dart';
import '../data/settings_service.dart';
import 'baidu_pan_screen.dart';
import 'cache_manage_screen.dart';
import 'quark_pan_screen.dart';
import 'runtime_log_screen.dart';
import 'software_update_screen.dart';
import 'source_manage_screen.dart';
import 'webdav_screen.dart';

class SourceScreen extends StatefulWidget {
  const SourceScreen({super.key});

  @override
  State<SourceScreen> createState() => _SourceScreenState();
}

class _SourceScreenState extends State<SourceScreen> {
  Future<void> _chooseSearchMatchMode(SettingsService settings) async {
    final value = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('搜索匹配方式'),
        children: [
          _dialogOption<String>(
            ctx,
            value: 'fuzzy',
            current: settings.searchMatchMode,
            label: '模糊搜索',
          ),
          _dialogOption<String>(
            ctx,
            value: 'exact',
            current: settings.searchMatchMode,
            label: '精确搜索',
          ),
        ],
      ),
    );
    if (value != null) settings.setSearchMatchMode(value);
  }

  Widget _dialogOption<T>(
    BuildContext context, {
    required T value,
    required T current,
    required String label,
  }) {
    final selected = value == current;
    return SimpleDialogOption(
      onPressed: () => Navigator.pop(context, value),
      child: Row(
        children: [
          Expanded(child: Text(label)),
          if (selected) const Icon(Icons.check, size: 20),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = SettingsService.instance;
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: AnimatedBuilder(
        animation: settings,
        builder: (context, _) => ListView(
          children: [
            const _ListeningStatsCard(),
            _sectionTitle('通用'),
            ListTile(
              leading: const Icon(Icons.dark_mode_outlined),
              title: const Text('夜间模式'),
              subtitle: const Text('切换深色界面'),
              trailing: Switch(
                value: settings.darkMode,
                onChanged: settings.setDarkMode,
              ),
            ),
            ListTile(
              leading: const Icon(Icons.palette_outlined),
              title: const Text('动态取色'),
              subtitle: const Text('使用当前播放书籍封面生成 Material 3 配色'),
              trailing: Switch(
                value: settings.dynamicColor,
                onChanged: settings.setDynamicColor,
              ),
            ),
            _sectionTitle('搜索设置'),
            ListTile(
              leading: const Icon(Icons.travel_explore),
              title: const Text('聚合搜索'),
              subtitle: const Text('开启后一次搜索全部已启用音源；关闭后只搜索当前音源'),
              trailing: Switch(
                value: settings.aggregateSearch,
                onChanged: settings.setAggregateSearch,
              ),
            ),
            ListTile(
              leading: const Icon(Icons.manage_search),
              title: const Text('搜索匹配方式'),
              subtitle: const Text('精确搜索只保留书名完全匹配关键词的结果'),
              trailing: Text(
                settings.searchMatchModeLabel,
                style: TextStyle(color: cs.onSurfaceVariant),
              ),
              onTap: () => _chooseSearchMatchMode(settings),
            ),
            _sectionTitle('播放设置'),
            ListTile(
              leading: const Icon(Icons.battery_saver_outlined),
              title: const Text('Android 音频卸载'),
              subtitle: const Text('降低功耗；部分设备可能出现进度或蓝牙兼容问题，下次加载音频生效'),
              trailing: Switch(
                value: settings.androidAudioOffload,
                onChanged: settings.setAndroidAudioOffload,
              ),
            ),
            _sectionTitle('缓存'),
            ListTile(
              leading: const Icon(Icons.storage_outlined),
              title: const Text('缓存管理'),
              subtitle: Text(
                '自动缓存 ${settings.autoCache ? '已开启' : '已关闭'} · 上限 ${settings.maxCacheChapters} 集 · ${settings.cacheFrequencyLabel}',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const CacheManageScreen()),
              ),
            ),
            _sectionTitle('诊断'),
            ListTile(
              leading: const Icon(Icons.system_update_outlined),
              title: const Text('软件更新'),
              subtitle: const Text('检查公开仓库的新版本并下载安装包'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const SoftwareUpdateScreen()),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.article_outlined),
              title: const Text('查看运行日志'),
              subtitle: const Text('查看搜索、播放、缓存和音源运行记录'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const RuntimeLogScreen()),
              ),
            ),
            _sectionTitle('音源管理'),
            ListTile(
              leading: const Icon(Icons.cloud_queue),
              title: const Text('WebDAV 网盘书库'),
              subtitle: const Text('连接 OpenList/AList/NAS，把网盘音频目录作为有声书播放'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const WebDavScreen()),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.cloud_outlined),
              title: const Text('百度网盘书库（测试）'),
              subtitle: const Text('登录后浏览网盘目录，试取直链播放（验证阶段）'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const BaiduPanScreen()),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.cloud_circle_outlined),
              title: const Text('夸克网盘书库（测试）'),
              subtitle: const Text('登录后浏览夸克网盘目录，按文件夹加入书架播放'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const QuarkPanScreen()),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.library_music_outlined),
              title: const Text('音源管理'),
              subtitle: const Text('本地导入、链接导入、开启关闭和删除'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const SourceManageScreen()),
              ),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  Widget _sectionTitle(String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
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
}

class _ListeningStatsCard extends StatelessWidget {
  const _ListeningStatsCard();

  @override
  Widget build(BuildContext context) {
    final stats = ListeningStatsService.instance;
    final cs = Theme.of(context).colorScheme;
    return AnimatedBuilder(
      animation: stats,
      builder: (context, _) => Container(
        margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: cs.primaryContainer,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.headphones, color: cs.onPrimaryContainer),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    '听书时长',
                    style: TextStyle(
                      fontSize: 13,
                      color: cs.onPrimaryContainer.withValues(alpha: 0.78),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _StatsBadge(
                  label: '今日',
                  value: stats.todayLabel,
                  colorScheme: cs,
                ),
                _StatsBadge(
                  label: '累计',
                  value: stats.totalLabel,
                  colorScheme: cs,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _StatsBadge extends StatelessWidget {
  final String label;
  final String value;
  final ColorScheme colorScheme;

  const _StatsBadge({
    required this.label,
    required this.value,
    required this.colorScheme,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minWidth: 112, maxWidth: 220),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: colorScheme.onPrimaryContainer.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: colorScheme.onPrimaryContainer.withValues(alpha: 0.72),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: colorScheme.onPrimaryContainer,
            ),
          ),
        ],
      ),
    );
  }
}
