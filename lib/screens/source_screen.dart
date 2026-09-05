import 'package:flutter/material.dart';

import '../data/cloud_auth_service.dart';
import '../data/listening_stats_service.dart';
import '../data/settings_service.dart';
import '../data/webdav_sync_service.dart';
import '../source/source_manager.dart';
import 'alist_screen.dart';
import 'background_protection_screen.dart';
import 'baidu_pan_screen.dart';
import 'cache_manage_screen.dart';
import 'cloud_auth_screen.dart';
import 'discover_source_setting_screen.dart';
import 'quark_pan_screen.dart';
import 'runtime_log_screen.dart';
import 'software_update_screen.dart';
import 'source_manage_screen.dart';
import 'webdav_screen.dart';
import 'webdav_sync_screen.dart';

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

  String _discoverSubtitle(SettingsService settings) {
    final sources = SourceManager.instance
        .getSources()
        .where((s) => s.enabled && s.supportsDiscover)
        .toList();
    if (sources.isEmpty) return '当前没有支持发现页的音源';
    final selected = sources
        .where((s) => settings.isDiscoverSourceSelected(s.id))
        .length;
    if (!settings.discoverSelectionConfigured) {
      return '默认全部（$selected/${sources.length}）';
    }
    return '已选择 $selected/${sources.length} 个';
  }

  @override
  Widget build(BuildContext context) {
    final settings = SettingsService.instance;
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar.large(title: const Text('设置'), expandedHeight: 120),
          SliverToBoxAdapter(
            child: AnimatedBuilder(
              animation: Listenable.merge([
                settings,
                CloudAuthService.instance,
              ]),
              builder: (context, _) => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
               children: [
                 const _ListeningStatsCard(),

                  _buildSection(
                    title: '授权',
                    icon: Icons.verified_user_outlined,
                    children: [
                      ListTile(
                        leading: const Icon(Icons.verified_user_outlined),
                        title: const Text('设备授权'),
                        subtitle: Text(
                          _authorizationSubtitle(CloudAuthService.instance),
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const CloudAuthorizationScreen(),
                          ),
                        ),
                      ),
                    ],
                  ),

                  // 数据同步
                  AnimatedBuilder(
                    animation: WebDavSyncService.instance,
                    builder: (context, _) {
                      final sync = WebDavSyncService.instance;
                      final status = sync.syncing
                          ? '正在同步…'
                          : sync.lastSyncAt == 0
                          ? (sync.lastResult.isEmpty
                                ? '多设备同步进度、书架、设置与音源'
                                : sync.lastResult)
                          : '${DateTime.fromMillisecondsSinceEpoch(sync.lastSyncAt).toString().substring(0, 16)} · ${sync.lastResult}';
                      return _buildSection(
                        title: '数据同步',
                        icon: Icons.sync_outlined,
                        children: [
                          ListTile(
                            leading: const Icon(Icons.sync_outlined),
                            title: const Text('WebDAV 数据同步'),
                            subtitle: Text(
                              status,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => const WebDavSyncScreen(),
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                  ),

                  // 外观
                  _buildSection(
                    title: '外观',
                    icon: Icons.palette_outlined,
                    children: [
                      _buildSwitchTile(
                        icon: Icons.dark_mode_outlined,
                        title: '夜间模式',
                        subtitle: '深色主题界面',
                        value: settings.darkMode,
                        onChanged: settings.setDarkMode,
                      ),
                      const Divider(height: 1, indent: 56),
                      _buildSwitchTile(
                        icon: Icons.palette_outlined,
                        title: '动态取色',
                        subtitle: '使用封面生成 Material 3 配色',
                        value: settings.dynamicColor,
                        onChanged: settings.setDynamicColor,
                      ),
                    ],
                  ),

                  // 搜索
                  _buildSection(
                    title: '搜索',
                    icon: Icons.search,
                    children: [
                      _buildSwitchTile(
                        icon: Icons.travel_explore,
                        title: '聚合搜索',
                        subtitle: '一次搜索全部已启用音源',
                        value: settings.aggregateSearch,
                        onChanged: settings.setAggregateSearch,
                      ),
                      const Divider(height: 1, indent: 56),
                      ListTile(
                        leading: const Icon(Icons.manage_search),
                        title: const Text('搜索匹配方式'),
                        subtitle: const Text('精确搜索只保留书名完全匹配的结果'),
                        trailing: Text(
                          settings.searchMatchModeLabel,
                          style: TextStyle(color: cs.onSurfaceVariant),
                        ),
                        onTap: () => _chooseSearchMatchMode(settings),
                      ),
                    ],
                  ),

                  // 发现
                  _buildSection(
                    title: '发现',
                    icon: Icons.explore_outlined,
                    children: [
                      ListTile(
                        leading: const Icon(Icons.travel_explore),
                        title: const Text('发现页音源'),
                        subtitle: Text(_discoverSubtitle(settings)),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () async {
                          await Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) =>
                                  const DiscoverSourceSettingScreen(),
                            ),
                          );
                          if (mounted) setState(() {});
                        },
                      ),
                    ],
                  ),

                  // 播放
                  _buildSection(
                    title: '播放',
                    icon: Icons.play_circle_outline,
                    children: [
                      ListTile(
                        leading: const Icon(Icons.security_outlined),
                        title: const Text('后台播放保护'),
                        subtitle: const Text('通知权限、电池优化与后台运行设置'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const BackgroundProtectionScreen(),
                          ),
                        ),
                      ),
                      const Divider(height: 1, indent: 56),
                      _buildSwitchTile(
                        icon: Icons.battery_saver_outlined,
                        title: 'Android 音频卸载',
                        subtitle: '降低功耗，下次加载音频生效',
                        value: settings.androidAudioOffload,
                        onChanged: settings.setAndroidAudioOffload,
                      ),
                    ],
                  ),

                  // 缓存
                  _buildSection(
                    title: '缓存',
                    icon: Icons.storage_outlined,
                    children: [
                      ListTile(
                        leading: const Icon(Icons.storage_outlined),
                        title: const Text('缓存管理'),
                        subtitle: Text(
                          '自动缓存 ${settings.autoCache ? "已开启" : "已关闭"} · 上限 ${settings.maxCacheChapters} 集',
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const CacheManageScreen(),
                          ),
                        ),
                      ),
                    ],
                  ),

                  // 音源
                  _buildSection(
                    title: '音源',
                    icon: Icons.library_music_outlined,
                    children: [
                      ListTile(
                        leading: const Icon(Icons.library_music_outlined),
                        title: const Text('音源管理'),
                        subtitle: const Text('本地导入、链接导入、开启关闭'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const SourceManageScreen(),
                          ),
                        ),
                      ),
                      const Divider(height: 1, indent: 56),
                      ListTile(
                        leading: const Icon(Icons.cloud_queue),
                        title: const Text('WebDAV 网盘书库'),
                        subtitle: const Text('连接 NAS，播放网盘音频目录'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const WebDavScreen(),
                          ),
                        ),
                      ),
                      const Divider(height: 1, indent: 56),
                      ListTile(
                        leading: const Icon(Icons.dns_outlined),
                        title: const Text('Alist 书库'),
                        subtitle: const Text('只需一个地址，支持 guest 访问'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const AlistScreen(),
                          ),
                        ),
                      ),
                      const Divider(height: 1, indent: 56),
                      ListTile(
                        leading: const Icon(Icons.cloud_outlined),
                        title: const Text('百度网盘书库（测试）'),
                        subtitle: const Text('登录后浏览网盘目录'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const BaiduPanScreen(),
                          ),
                        ),
                      ),
                      const Divider(height: 1, indent: 56),
                      ListTile(
                        leading: const Icon(Icons.cloud_circle_outlined),
                        title: const Text('夸克网盘书库（测试）'),
                        subtitle: const Text('登录后浏览夸克网盘目录'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const QuarkPanScreen(),
                          ),
                        ),
                      ),
                    ],
                  ),

                  // 诊断
                  _buildSection(
                    title: '诊断',
                    icon: Icons.bug_report_outlined,
                    children: [
                      ListTile(
                        leading: const Icon(Icons.system_update_outlined),
                        title: const Text('软件更新'),
                        subtitle: const Text('检查新版本并下载安装包'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const SoftwareUpdateScreen(),
                          ),
                        ),
                      ),
                      const Divider(height: 1, indent: 56),
                      ListTile(
                        leading: const Icon(Icons.article_outlined),
                        title: const Text('运行日志'),
                        subtitle: const Text('查看搜索、播放、缓存运行记录'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const RuntimeLogScreen(),
                          ),
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSection({
    required String title,
    required IconData icon,
    required List<Widget> children,
  }) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: Theme.of(context).colorScheme.outlineVariant,
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Row(
              children: [
                Icon(
                  icon,
                  size: 20,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
              ],
            ),
          ),
          ...children,
        ],
      ),
    );
  }

  Widget _buildSwitchTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle: Text(subtitle),
      trailing: Switch(value: value, onChanged: onChanged),
    );
  }

  String _authorizationSubtitle(CloudAuthService auth) {
    final name = auth.license?.displayName.trim() ?? '';
    return name.isEmpty ? auth.stateLabel : '${auth.stateLabel} · $name';
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
        margin: const EdgeInsets.all(16),
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [cs.primaryContainer, cs.secondaryContainer],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: cs.shadow.withValues(alpha: 0.1),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.headphones, color: cs.onPrimaryContainer, size: 28),
                const SizedBox(width: 12),
                Text(
                  '听书统计',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: cs.onPrimaryContainer,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 16,
              runSpacing: 12,
              children: [
                _StatsBadge(
                  icon: Icons.access_time,
                  label: '累计',
                  value: stats.totalLabel,
                  color: cs.onPrimaryContainer,
                ),
                _StatsBadge(
                  icon: Icons.today,
                  label: '今日',
                  value: stats.todayLabel,
                  color: cs.onPrimaryContainer,
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
  final IconData icon;
  final String label;
  final String value;
  final Color color;

  const _StatsBadge({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: color.withValues(alpha: 0.8)),
        const SizedBox(width: 6),
        Text(
          '$label: ',
          style: TextStyle(fontSize: 13, color: color.withValues(alpha: 0.8)),
        ),
        Text(
          value,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: color,
          ),
        ),
      ],
    );
  }
}
