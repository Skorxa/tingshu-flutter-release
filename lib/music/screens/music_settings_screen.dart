import 'package:flutter/material.dart';

import '../../data/settings_service.dart';
import '../music_player_service.dart';

class MusicSettingsScreen extends StatefulWidget {
  const MusicSettingsScreen({super.key});

  @override
  State<MusicSettingsScreen> createState() => _MusicSettingsScreenState();
}

class _MusicSettingsScreenState extends State<MusicSettingsScreen> {
  @override
  Widget build(BuildContext context) {
    final settings = SettingsService.instance;
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: ListView(
          children: [
            const SizedBox(height: 24),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text('设置', style: Theme.of(context).textTheme.headlineSmall),
            ),
            const SizedBox(height: 16),

            // ── 应用模式 ──
            _SectionHeader(title: '应用模式'),
            ListTile(
              leading: Icon(Icons.headphones, color: cs.primary),
              title: const Text('当前模式'),
              subtitle: const Text('音乐模式'),
              trailing: FilledButton.tonalIcon(
                icon: const Icon(Icons.swap_horiz),
                label: const Text('切回听书'),
                onPressed: () => _switchMode(context),
              ),
            ),
            const Divider(),

            // ── 播放设置 ──
            _SectionHeader(title: '播放设置'),
            ListTile(
              leading: const Icon(Icons.speed),
              title: const Text('播放倍速'),
              subtitle: Text(settings.androidAudioOffload ? '音频卸载已开启' : ''),
              trailing: DropdownButton<double>(
                value: MusicPlayerService.instance.speed,
                items: const [
                  DropdownMenuItem(value: 1.0, child: Text('1.0x')),
                  DropdownMenuItem(value: 1.25, child: Text('1.25x')),
                  DropdownMenuItem(value: 1.5, child: Text('1.5x')),
                  DropdownMenuItem(value: 2.0, child: Text('2.0x')),
                ],
                onChanged: (v) {
                  if (v != null) MusicPlayerService.instance.setSpeed(v);
                  setState(() {});
                },
              ),
            ),
            ListTile(
              leading: const Icon(Icons.nightlight_outlined),
              title: const Text('夜间模式'),
              trailing: Switch(
                value: settings.darkMode,
                onChanged: settings.setDarkMode,
              ),
            ),
            const Divider(),

            // ── 定时关闭 ──
            _SectionHeader(title: '定时关闭'),
            AnimatedBuilder(
              animation: MusicPlayerService.instance,
              builder: (context, _) {
                final p = MusicPlayerService.instance;
                return ListTile(
                  leading: const Icon(Icons.timer_outlined),
                  title: const Text('睡眠定时'),
                  subtitle: Text(p.sleepTimerActive ? p.sleepTimerLabel : '未开启'),
                  trailing: p.sleepTimerActive
                      ? TextButton(
                          onPressed: p.clearSleepTimer,
                          child: const Text('清除'),
                        )
                      : null,
                  onTap: () => _showSleepTimerDialog(context),
                );
              },
            ),
            const Divider(),

            // ── 关于 ──
            _SectionHeader(title: '关于'),
            const ListTile(
              leading: Icon(Icons.info_outline),
              title: Text('橘听'),
              subtitle: Text('双模态:听书 + 音乐'),
            ),
          ],
        ),
      ),
    );
  }

  void _switchMode(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('切换到听书模式'),
        content: const Text('应用将重启以切换到听书模式。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await MusicPlayerService.instance.stopAndClear();
              await SettingsService.instance.setAppMode('tingshu');
              AppRestartNotifier.instance.notify();
            },
            child: const Text('切换'),
          ),
        ],
      ),
    );
  }

  void _showSleepTimerDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('睡眠定时'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: const Text('15 分钟'),
              onTap: () {
                MusicPlayerService.instance.setSleepByMinutes(15);
                Navigator.pop(ctx);
              },
            ),
            ListTile(
              title: const Text('30 分钟'),
              onTap: () {
                MusicPlayerService.instance.setSleepByMinutes(30);
                Navigator.pop(ctx);
              },
            ),
            ListTile(
              title: const Text('45 分钟'),
              onTap: () {
                MusicPlayerService.instance.setSleepByMinutes(45);
                Navigator.pop(ctx);
              },
            ),
            ListTile(
              title: const Text('60 分钟'),
              onTap: () {
                MusicPlayerService.instance.setSleepByMinutes(60);
                Navigator.pop(ctx);
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader({required this.title});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        title,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: Theme.of(context).colorScheme.primary,
            ),
      ),
    );
  }
}

/// 全局重启通知器:设置 appMode 后触发根 widget 重建。
class AppRestartNotifier extends ChangeNotifier {
  AppRestartNotifier._();
  static final instance = AppRestartNotifier._();

  int _epoch = 0;
  int get epoch => _epoch;

  void notify() {
    _epoch++;
    notifyListeners();
  }
}
