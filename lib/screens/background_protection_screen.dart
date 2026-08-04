import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/background_protection_service.dart';

class BackgroundProtectionScreen extends StatefulWidget {
  const BackgroundProtectionScreen({super.key});

  @override
  State<BackgroundProtectionScreen> createState() =>
      _BackgroundProtectionScreenState();
}

class _BackgroundProtectionScreenState extends State<BackgroundProtectionScreen>
    with WidgetsBindingObserver {
  BackgroundProtectionStatus? _status;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    if (mounted) setState(() => _loading = true);
    try {
      final status = await BackgroundProtectionService.getStatus();
      if (!mounted) return;
      setState(() {
        _status = status;
        _loading = false;
      });
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _showError(e.message ?? '无法读取后台保护状态');
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
      await _refresh();
    } on PlatformException catch (e) {
      if (mounted) _showError(e.message ?? '操作失败');
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final status = _status;
    return Scaffold(
      appBar: AppBar(
        title: const Text('后台播放保护'),
        actions: [
          IconButton(
            onPressed: _loading ? null : _refresh,
            icon: const Icon(Icons.refresh),
            tooltip: '刷新状态',
          ),
        ],
      ),
      body: status == null && _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                if (_loading) const LinearProgressIndicator(minHeight: 2),
                const _SectionTitle(title: '运行状态'),
                const _StatusTile(
                  icon: Icons.play_circle_outline,
                  title: '媒体前台服务',
                  subtitle: '播放期间保持前台服务与 CPU 唤醒锁',
                  enabled: true,
                ),
                const Divider(height: 1, indent: 56),
                _StatusTile(
                  icon: Icons.notifications_active_outlined,
                  title: '播放通知',
                  subtitle: status?.notificationsEnabled == true
                      ? '已允许'
                      : '未允许，后台播放控制可能不可见',
                  enabled: status?.notificationsEnabled == true,
                  onTap: status?.notificationsEnabled == true
                      ? () => _run(
                          BackgroundProtectionService.openNotificationSettings,
                        )
                      : () => _run(() async {
                          if (status?.notificationPermissionGranted == true) {
                            await BackgroundProtectionService.openNotificationSettings();
                          } else {
                            await BackgroundProtectionService.requestNotificationPermission();
                          }
                        }),
                ),
                const Divider(height: 1, indent: 56),
                _StatusTile(
                  icon: Icons.battery_saver_outlined,
                  title: '电池优化限制',
                  subtitle: status?.batteryOptimizationExempt == true
                      ? '已允许后台持续运行'
                      : '受系统电池优化限制',
                  enabled: status?.batteryOptimizationExempt == true,
                  onTap: status?.batteryOptimizationExempt == true
                      ? null
                      : () => _run(
                          BackgroundProtectionService
                              .requestBatteryOptimizationExemption,
                        ),
                ),
                const _SectionTitle(title: '系统设置'),
                ListTile(
                  leading: const Icon(Icons.settings_outlined),
                  title: const Text('应用后台权限'),
                  subtitle: const Text('自启动、后台活动和省电策略由系统管理'),
                  trailing: const Icon(Icons.open_in_new),
                  onTap: () =>
                      _run(BackgroundProtectionService.openAppSettings),
                ),
              ],
            ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 8),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }
}

class _StatusTile extends StatelessWidget {
  const _StatusTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.enabled,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool enabled;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle: Text(subtitle),
      trailing: Icon(
        enabled ? Icons.check_circle : Icons.warning_amber_rounded,
        color: enabled ? colors.primary : colors.error,
      ),
      onTap: onTap,
    );
  }
}
