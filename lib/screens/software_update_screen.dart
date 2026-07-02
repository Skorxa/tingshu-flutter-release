import 'package:flutter/material.dart';

import '../data/app_update_service.dart';
import '../data/settings_service.dart';

class SoftwareUpdateScreen extends StatefulWidget {
  const SoftwareUpdateScreen({super.key});

  @override
  State<SoftwareUpdateScreen> createState() => _SoftwareUpdateScreenState();
}

class _SoftwareUpdateScreenState extends State<SoftwareUpdateScreen> {
  final TextEditingController _manifestCtrl = TextEditingController();
  AppVersionInfo? _current;
  AppUpdateInfo? _remote;
  bool _loadingCurrent = true;
  bool _checking = false;
  bool _downloading = false;
  bool _saving = false;
  double _downloadProgress = 0;
  String _downloadLabel = '';
  String? _status;
  String? _error;

  @override
  void initState() {
    super.initState();
    _manifestCtrl.text = SettingsService.instance.updateManifestUrl;
    _loadCurrentVersion();
  }

  @override
  void dispose() {
    _manifestCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadCurrentVersion() async {
    try {
      final version = await AppUpdateService.instance.currentVersion();
      if (!mounted) return;
      setState(() {
        _current = version;
        _loadingCurrent = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingCurrent = false;
        _error = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  Future<void> _saveManifestUrl() async {
    setState(() => _saving = true);
    await SettingsService.instance.setUpdateManifestUrl(_manifestCtrl.text);
    if (!mounted) return;
    setState(() => _saving = false);
    _toast('更新地址已保存');
  }

  Future<void> _checkUpdate() async {
    final url = _manifestCtrl.text.trim();
    if (url.isEmpty) {
      _toast('请先填写更新清单地址');
      return;
    }
    setState(() {
      _checking = true;
      _error = null;
      _status = null;
    });
    try {
      await SettingsService.instance.setUpdateManifestUrl(url);
      final current =
          _current ?? await AppUpdateService.instance.currentVersion();
      final remote = await AppUpdateService.instance.check(url);
      if (!mounted) return;
      setState(() {
        _current = current;
        _remote = remote;
        _checking = false;
        _status = remote.versionCode > current.versionCode
            ? '发现新版本 ${remote.versionName}'
            : '当前已经是最新版本';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _checking = false;
        _error = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  Future<void> _downloadAndInstall() async {
    final remote = _remote;
    if (remote == null) return;
    setState(() {
      _downloading = true;
      _downloadProgress = 0;
      _downloadLabel = '准备下载...';
      _error = null;
    });
    try {
      final downloaded = await AppUpdateService.instance.download(
        remote,
        onProgress: (progress, url, index) {
          if (!mounted) return;
          setState(() {
            _downloadProgress = progress;
            _downloadLabel =
                '镜像 ${index + 1}/${remote.urls.length} · ${(progress * 100).toStringAsFixed(0)}%';
          });
        },
      );
      if (!mounted) return;
      setState(() {
        _downloadLabel = '下载完成，准备安装';
      });
      await AppUpdateService.instance.installApk(downloaded.file.path);
      if (!mounted) return;
      setState(() {
        _downloading = false;
        _status = '已调起安装器';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _downloading = false;
        _error = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  bool get _hasNewVersion {
    final current = _current;
    final remote = _remote;
    return current != null &&
        remote != null &&
        remote.versionCode > current.versionCode;
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final current = _current;
    final remote = _remote;
    return Scaffold(
      appBar: AppBar(
        title: const Text('软件更新'),
        actions: [
          IconButton(
            tooltip: '检查更新',
            onPressed: _checking || _downloading ? null : _checkUpdate,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: cs.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                _infoChip(
                  cs,
                  '当前版本',
                  _loadingCurrent
                      ? '读取中'
                      : current == null
                      ? '未知'
                      : '${current.versionName} (${current.versionCode})',
                ),
                _infoChip(
                  cs,
                  '最新版本',
                  remote == null
                      ? '未检查'
                      : '${remote.versionName} (${remote.versionCode})',
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _manifestCtrl,
            minLines: 1,
            maxLines: 2,
            decoration: const InputDecoration(
              labelText: '更新清单地址',
              hintText: 'https://.../version.json',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _saving || _checking || _downloading
                      ? null
                      : _saveManifestUrl,
                  child: Text(_saving ? '保存中' : '保存地址'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: _checking || _downloading ? null : _checkUpdate,
                  child: Text(_checking ? '检查中' : '检查更新'),
                ),
              ),
            ],
          ),
          if (_status != null) ...[
            const SizedBox(height: 12),
            Text(
              _status!,
              style: TextStyle(
                color: _hasNewVersion ? cs.primary : cs.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(
              _error!,
              style: TextStyle(color: cs.error, fontWeight: FontWeight.w600),
            ),
          ],
          if (remote != null) ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: cs.surfaceContainerLow,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: cs.outlineVariant),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    remote.versionName,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '版本号 ${remote.versionCode}'
                    '${remote.size > 0 ? ' · ${_formatBytes(remote.size)}' : ''}'
                    '${remote.force ? ' · 强制更新' : ''}',
                    style: TextStyle(color: cs.onSurfaceVariant),
                  ),
                  if (remote.publishedAt.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      remote.publishedAt,
                      style: TextStyle(color: cs.onSurfaceVariant),
                    ),
                  ],
                  const SizedBox(height: 10),
                  Text(
                    '下载地址 ${remote.urls.length} 条',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '内置加速线路 ${AppUpdateService.githubAccelerators.length} 条',
                    style: TextStyle(color: cs.onSurfaceVariant),
                  ),
                  const SizedBox(height: 6),
                  SelectableText(
                    AppUpdateService.githubAccelerators.join('\n'),
                    style: TextStyle(height: 1.35, color: cs.onSurfaceVariant),
                  ),
                  if (remote.changelog.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    const Text(
                      '更新日志',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 8),
                    SelectableText(
                      remote.changelog,
                      style: TextStyle(height: 1.4, color: cs.onSurfaceVariant),
                    ),
                  ],
                  const SizedBox(height: 14),
                  if (_downloading) ...[
                    LinearProgressIndicator(value: _downloadProgress),
                    const SizedBox(height: 8),
                    Text(
                      _downloadLabel,
                      style: TextStyle(color: cs.onSurfaceVariant),
                    ),
                    const SizedBox(height: 12),
                  ],
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: !_hasNewVersion || _downloading
                          ? null
                          : _downloadAndInstall,
                      icon: const Icon(Icons.system_update_alt),
                      label: Text(_downloading ? '下载中' : '下载并安装'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _infoChip(ColorScheme cs, String label, String value) {
    return Container(
      constraints: const BoxConstraints(minWidth: 120, maxWidth: 220),
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
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
        ],
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
    final digits = idx == 0 ? 0 : 1;
    return '${value.toStringAsFixed(digits)} ${units[idx]}';
  }
}
