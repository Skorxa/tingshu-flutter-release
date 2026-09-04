import 'package:flutter/material.dart';

import '../data/webdav_sync_service.dart';

/// 数据同步独立页面:同步服务器配置、加密密码、自动同步开关与手动操作。
/// 与「网盘书库 → WebDAV」完全独立,互不影响。
class WebDavSyncScreen extends StatefulWidget {
  const WebDavSyncScreen({super.key});

  @override
  State<WebDavSyncScreen> createState() => _WebDavSyncScreenState();
}

class _WebDavSyncScreenState extends State<WebDavSyncScreen> {
  final _baseUrl = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _remoteDir = TextEditingController();
  final _syncPassword = TextEditingController();

  @override
  void initState() {
    super.initState();
    final config = WebDavSyncService.instance.config;
    _baseUrl.text = config.baseUrl;
    _username.text = config.username;
    _password.text = config.password;
    _remoteDir.text = config.remoteDir.isEmpty
        ? WebDavSyncService.defaultRemoteDir
        : config.remoteDir;
  }

  @override
  void dispose() {
    _baseUrl.dispose();
    _username.dispose();
    _password.dispose();
    _remoteDir.dispose();
    _syncPassword.dispose();
    super.dispose();
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _saveServer({bool test = false}) async {
    if (_baseUrl.text.trim().isEmpty) {
      _toast('WebDAV 地址不能为空');
      return;
    }
    try {
      await WebDavSyncService.instance.saveConfig(
        WebDavSyncConfig(
          baseUrl: _baseUrl.text,
          username: _username.text,
          password: _password.text,
          remoteDir: _remoteDir.text,
        ),
      );
      if (test) {
        _toast('正在测试连接…');
        await WebDavSyncService.instance.testConnection();
      }
      _toast(test ? '连接测试通过' : '同步服务器已保存');
    } catch (e) {
      _toast(e.toString().replaceFirst('Exception: ', ''));
    }
  }

  Future<void> _saveSyncPassword() async {
    final value = _syncPassword.text.trim();
    if (value.isEmpty) {
      _toast('同步密码不能为空');
      return;
    }
    await WebDavSyncService.instance.setPassword(value);
    _syncPassword.clear();
    _toast('同步密码已保存');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('数据同步')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          AnimatedBuilder(
            animation: WebDavSyncService.instance,
            builder: (context, _) {
              final sync = WebDavSyncService.instance;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '同步服务器',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '独立于「网盘书库 → WebDAV」的账号，两边互不影响。',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _baseUrl,
                    keyboardType: TextInputType.url,
                    decoration: const InputDecoration(
                      labelText: 'WebDAV 地址',
                      hintText: 'https://dav.jianguoyun.com/dav',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _username,
                    decoration: const InputDecoration(
                      labelText: '账号（可选）',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _password,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: '应用密码（可选）',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _remoteDir,
                    decoration: const InputDecoration(
                      labelText: '远程目录',
                      hintText: WebDavSyncService.defaultRemoteDir,
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      FilledButton.icon(
                        onPressed: _saveServer,
                        icon: const Icon(Icons.save_outlined),
                        label: const Text('保存'),
                      ),
                      const SizedBox(width: 12),
                      OutlinedButton.icon(
                        onPressed: () => _saveServer(test: true),
                        icon: const Icon(Icons.wifi_tethering_outlined),
                        label: const Text('保存并测试'),
                      ),
                    ],
                  ),
                  const Divider(height: 32),

                  Text(
                    '加密',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '上传到 WebDAV 的数据（含音源 Cookie、配置）会用同步密码加密，'
                    '所有需要同步的设备必须设置相同的密码。',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _syncPassword,
                          obscureText: true,
                          decoration: InputDecoration(
                            labelText: sync.hasPassword
                                ? '同步密码（已设置）'
                                : '同步密码（未设置）',
                            border: const OutlineInputBorder(),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      FilledButton.tonal(
                        onPressed: _saveSyncPassword,
                        child: const Text('设置'),
                      ),
                    ],
                  ),
                  const Divider(height: 32),

                  Text(
                    '同步',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '同步内容：播放进度、书架、设置、音源（含 Cookie 配置与排序）。',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('自动同步'),
                    subtitle: const Text('启动与数据变更后按需触发'),
                    value: sync.enabled,
                    onChanged: sync.canSync
                        ? (value) => sync.setEnabled(value)
                        : (value) => _toast(
                            value ? '请先配置同步服务器并设置同步密码' : '',
                          ),
                  ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('同步状态'),
                    subtitle: Text(
                      sync.syncing
                          ? '正在同步…'
                          : sync.lastResult.isEmpty
                          ? '从未同步'
                          : '${sync.lastSyncAt == 0 ? '' : '上次: ${DateTime.fromMillisecondsSinceEpoch(sync.lastSyncAt).toString().substring(0, 16)} · '}${sync.lastResult}',
                    ),
                  ),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: sync.syncing || !sync.canSync
                              ? null
                              : () => sync.syncNow(),
                          icon: const Icon(Icons.sync_outlined),
                          label: const Text('立即同步'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: sync.syncing || !sync.canSync
                              ? null
                              : () => sync.uploadSnapshot(),
                          icon: const Icon(Icons.upload_outlined),
                          label: const Text('上传备份'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: sync.syncing || !sync.canSync
                              ? null
                              : () => sync.downloadAndMerge(),
                          icon: const Icon(Icons.download_outlined),
                          label: const Text('下载合并'),
                        ),
                      ),
                    ],
                  ),
                  if (!sync.canSync) ...[
                    const SizedBox(height: 12),
                    Text(
                      sync.hasPassword
                          ? '请先配置上方同步服务器'
                          : '请先设置同步密码',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.outline,
                      ),
                    ),
                  ],
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}
