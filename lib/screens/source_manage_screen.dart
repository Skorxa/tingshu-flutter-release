import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/log_service.dart';
import '../source/models.dart';
import '../source/source_debug_runner.dart';
import '../source/source_manager.dart';
import 'runtime_log_screen.dart';
import 'source_config_screen.dart';

class SourceManageScreen extends StatefulWidget {
  const SourceManageScreen({super.key});

  @override
  State<SourceManageScreen> createState() => _SourceManageScreenState();
}

class _SourceManageScreenState extends State<SourceManageScreen> {
  static const MethodChannel _filePickerChannel = MethodChannel(
    'tingshu/source_file_picker',
  );
  static const MethodChannel _loginChannel = MethodChannel(
    'tingshu/source_login',
  );

  final Dio _dio = Dio();
  List<SourceMeta> _sources = [];
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  void _refresh() {
    setState(() => _sources = SourceManager.instance.getSources());
  }

  /// 本地导入:调起系统文件管理器选择音源文件(.js / .txt 等纯文本)。
  Future<void> _importLocal() async {
    Map<dynamic, dynamic>? file;
    try {
      file = await _filePickerChannel.invokeMethod<Map<dynamic, dynamic>>(
        'pickSourceFile',
      );
    } on PlatformException catch (e) {
      LogService.instance.error('SourceImport', '打开文件选择器失败', error: e);
      _toast(e.message ?? '无法打开文件管理器');
      return;
    } on MissingPluginException catch (e) {
      LogService.instance.error('SourceImport', '本地文件选择通道未注册', error: e);
      _toast('当前平台暂不支持本地导入');
      return;
    } catch (e) {
      LogService.instance.error('SourceImport', '打开文件选择器失败', error: e);
      _toast('无法打开文件管理器:${e.toString().replaceFirst('Exception: ', '')}');
      return;
    }
    if (file == null) return; // 用户取消

    final code = '${file['content'] ?? ''}';
    final name = '${file['name'] ?? '本地文件'}';
    final size = (file['size'] as num?)?.toInt() ?? utf8.encode(code).length;
    if (code.trim().isEmpty) {
      _toast('文件内容为空');
      return;
    }
    if (!code.contains('getAudioUrl') || !code.contains('getChapters')) {
      _toast('文件内容不像有效音源 JS');
      return;
    }
    LogService.instance.info(
      'SourceImport',
      '开始本地文件导入音源',
      detail: '文件: $name\n大小: $size bytes',
    );
    await _addSource(code.trim());
  }

  /// 粘贴导入:手动粘贴音源 JS 文本(文件选择不便时的备选)。
  Future<void> _importPaste() async {
    final code = await _codeDialog(title: '粘贴导入', hintText: '粘贴音源 JS 内容');
    if (code == null || code.trim().isEmpty) return;
    LogService.instance.info(
      'SourceImport',
      '开始粘贴导入音源',
      detail: '代码长度: ${code.trim().length}',
    );
    await _addSource(code.trim());
  }

  Future<void> _importUrl() async {
    final url = await _singleInputDialog(title: '链接导入', hintText: '输入音源 JS 链接');
    if (url == null || url.trim().isEmpty) return;
    setState(() => _loading = true);
    try {
      LogService.instance.info(
        'SourceImport',
        '开始链接导入音源',
        detail: 'URL: ${url.trim()}',
      );
      final resp = await _dio.get<String>(
        url.trim(),
        options: Options(
          responseType: ResponseType.plain,
          receiveTimeout: const Duration(seconds: 20),
          validateStatus: (_) => true,
        ),
      );
      if ((resp.statusCode ?? 0) < 200 || (resp.statusCode ?? 0) >= 300) {
        throw Exception('链接请求失败:${resp.statusCode}');
      }
      LogService.instance.info(
        'SourceImport',
        '音源链接请求成功',
        detail: 'URL: ${url.trim()}\n状态码: ${resp.statusCode}',
      );
      final code = resp.data ?? '';
      if (code.trim().isEmpty) throw Exception('链接内容为空');
      await _addSource(code);
    } catch (e) {
      LogService.instance.error('SourceImport', '链接导入音源失败', error: e);
      _toast(e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _addSource(String code) async {
    setState(() => _loading = true);
    try {
      final meta = await SourceManager.instance.addSource(code);
      _refresh();
      _toast('已导入:${meta['name']}');
    } catch (e) {
      LogService.instance.error('SourceImport', '添加音源失败', error: e);
      _toast(e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<String?> _codeDialog({
    required String title,
    required String hintText,
  }) {
    return showDialog<String>(
      context: context,
      builder: (_) => _PromptDialog(
        title: title,
        hintText: hintText,
        maxLines: 10,
        confirmText: '导入',
      ),
    );
  }

  Future<String?> _singleInputDialog({
    required String title,
    required String hintText,
    TextInputType keyboardType = TextInputType.url,
    String confirmText = '导入',
    String initialText = '',
  }) {
    return showDialog<String>(
      context: context,
      builder: (_) => _PromptDialog(
        title: title,
        hintText: hintText,
        keyboardType: keyboardType,
        confirmText: confirmText,
        initialText: initialText,
      ),
    );
  }

  Future<void> _syncSubscription() async {
    final url = await _singleInputDialog(
      title: '音源订阅',
      hintText: '输入订阅 JSON 链接',
      confirmText: '同步',
      initialText: SourceManager.instance.subscriptionUrl,
    );
    if (url == null || url.trim().isEmpty) return;
    setState(() => _loading = true);
    try {
      final result = await SourceManager.instance.syncSubscription(url.trim());
      _refresh();
      _toast(
        '订阅同步完成：新增 ${result.added}，更新 ${result.updated}，删除 ${result.removed}',
      );
    } catch (e) {
      LogService.instance.error('SourceSub', '音源订阅同步失败', error: e);
      _toast(e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _delete(SourceMeta source) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除音源'),
        content: Text('确定删除「${source.name}」吗？'),
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
    await SourceManager.instance.deleteSource(source.id);
    _refresh();
  }

  Future<void> _openConfig(SourceMeta source) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SourceConfigScreen(sourceId: source.id),
      ),
    );
    _refresh();
  }

  Future<void> _openLogin(SourceMeta source) async {
    final loginUrl = source.loginUrl.isNotEmpty
        ? source.loginUrl
        : SourceManager.instance.getSourceLoginUrl(source.id);
    if (loginUrl.isNotEmpty) {
      try {
        final result = await _loginChannel.invokeMethod<Map<dynamic, dynamic>>(
          'openLogin',
          {'url': loginUrl, 'title': source.name},
        );
        final cookie = '${result?['cookie'] ?? ''}'.trim();
        if (cookie.isNotEmpty) {
          final key = source.loginConfigKey.isNotEmpty
              ? source.loginConfigKey
              : SourceManager.instance.getSourceLoginConfigKey(source.id);
          if (key.isNotEmpty) {
            final config = Map<String, dynamic>.from(
              SourceManager.instance.getSourceConfig(source.id),
            );
            config[key] = cookie;
            await SourceManager.instance.setSourceConfig(source.id, config);
            _refresh();
            _toast('登录 Cookie 已保存');
          } else {
            _toast('登录完成，但这个音源没有声明保存 Cookie 的字段');
          }
        } else {
          _toast('登录页没有返回 Cookie');
        }
        return;
      } catch (e) {
        LogService.instance.error('SourceLogin', '打开音源登录页失败', error: e);
        _toast(e.toString().replaceFirst('Exception: ', ''));
        return;
      }
    }
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SourceConfigScreen(
          sourceId: source.id,
          mode: SourceConfigMode.login,
        ),
      ),
    );
    _refresh();
  }

  Future<void> _showSourceMenu(SourceMeta source) async {
    final hasLogin = SourceManager.instance.sourceHasLoginConfig(source.id);
    final hasSettings = SourceManager.instance.sourceHasSettingConfig(
      source.id,
    );
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                title: Text(source.name),
                subtitle: Text('${source.id} 路 协议 v${source.apiVersion}'),
              ),
              if (hasLogin)
                ListTile(
                  leading: const Icon(Icons.login),
                  title: const Text('登录'),
                  subtitle: Text(
                    source.loginUrl.isNotEmpty
                        ? source.loginUrl
                        : '填写这个音源声明的 Cookie、Token 或账号信息',
                  ),
                  onTap: () => Navigator.pop(ctx, 'login'),
                ),
              if (hasSettings)
                ListTile(
                  leading: const Icon(Icons.tune),
                  title: const Text('设置'),
                  subtitle: const Text('修改这个音源声明的配置项'),
                  onTap: () => Navigator.pop(ctx, 'settings'),
                ),
              ListTile(
                leading: Icon(
                  source.enabled ? Icons.toggle_off_outlined : Icons.toggle_on,
                ),
                title: Text(source.enabled ? '关闭音源' : '开启音源'),
                onTap: () => Navigator.pop(ctx, 'toggle'),
              ),
              if (source.enabled && !source.active)
                ListTile(
                  leading: const Icon(Icons.radio_button_checked),
                  title: const Text('设为当前音源'),
                  onTap: () => Navigator.pop(ctx, 'active'),
                ),
              ListTile(
                leading: const Icon(Icons.bug_report_outlined),
                title: const Text('调试'),
                subtitle: const Text('输关键词,自动跑 搜索→目录→播放链接'),
                onTap: () => Navigator.pop(ctx, 'debug'),
              ),
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: const Text('删除'),
                onTap: () => Navigator.pop(ctx, 'delete'),
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted || action == null) return;
    if (action == 'login') {
      await _openLogin(source);
      return;
    }
    if (action == 'settings') {
      await _openConfig(source);
      return;
    }
    if (action == 'toggle') {
      await SourceManager.instance.setEnabled(source.id, !source.enabled);
      _refresh();
      return;
    }
    if (action == 'active') {
      await SourceManager.instance.setActive(source.id);
      _refresh();
      return;
    }
    if (action == 'debug') {
      await _debugSource(source);
      return;
    }
    if (action == 'delete') {
      await _delete(source);
    }
  }

  Future<void> _debugSource(SourceMeta source) async {
    final keyword = await _singleInputDialog(
      title: '调试 · ${source.name}',
      hintText: '输入搜索关键词(如:三国)',
      keyboardType: TextInputType.text,
      confirmText: '开始调试',
    );
    if (keyword == null || keyword.trim().isEmpty) return;
    // 调试需要音源处于开启状态(searchFromSource 会校验);未开启则先开启
    if (!source.enabled) {
      await SourceManager.instance.setEnabled(source.id, true);
      _refresh();
    }
    setState(() => _loading = true);
    SourceDebugResult result;
    try {
      result = await SourceDebugRunner.instance.runBookDebug(
        sourceId: source.id,
        sourceName: source.name,
        keyword: keyword.trim(),
        bookId: '',
        bookTitle: '',
      );
    } catch (e) {
      if (mounted) _toast(e.toString().replaceFirst('Exception: ', ''));
      return;
    } finally {
      if (mounted) setState(() => _loading = false);
    }
    if (!mounted) return;
    await _showDebugResult(source.name, result);
  }

  Future<void> _showDebugResult(
    String sourceName,
    SourceDebugResult result,
  ) async {
    final cs = Theme.of(context).colorScheme;
    void openLog(int? logId) {
      Navigator.pop(context); // 关闭结果弹窗
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => RuntimeLogScreen(focusLogId: logId)),
      );
    }

    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('调试结果 · $sourceName'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final step in result.steps)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  !step.ran
                      ? Icons.remove_circle_outline
                      : (step.ok ? Icons.check_circle : Icons.cancel),
                  color: !step.ran
                      ? cs.onSurfaceVariant
                      : (step.ok ? const Color(0xFF16A34A) : cs.error),
                ),
                title: Text(step.name),
                subtitle: step.summary.isEmpty
                    ? null
                    : Text(
                        step.summary,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                trailing: step.logId == null
                    ? null
                    : const Icon(Icons.chevron_right),
                onTap: step.logId == null ? null : () => openLog(step.logId),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
          FilledButton(
            onPressed: () => openLog(null),
            child: const Text('完整日志'),
          ),
        ],
      ),
    );
  }

  Future<void> _reorderSources(int oldIndex, int newIndex) async {
    if (_loading) return;
    final moved = _sources[oldIndex];
    setState(() {
      var target = newIndex;
      if (target < 0) target = 0;
      if (target >= _sources.length) target = _sources.length - 1;
      final item = _sources.removeAt(oldIndex);
      _sources.insert(target, item);
    });
    await SourceManager.instance.moveSource(oldIndex, newIndex);
    LogService.instance.info(
      'Source',
      '音源拖拽排序完成',
      detail: '名称: ${moved.name}\nID: ${moved.id}',
    );
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
        title: const Text('音源管理'),
        actions: [
          IconButton(
            icon: const Icon(Icons.content_paste),
            tooltip: '粘贴导入',
            onPressed: _loading ? null : _importPaste,
          ),
        ],
      ),
      body: Column(
        children: [
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _loading ? null : _importLocal,
                    icon: const Icon(Icons.folder_open),
                    label: const Text('本地导入'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _loading ? null : _importUrl,
                    icon: const Icon(Icons.link),
                    label: const Text('链接导入'),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton.tonalIcon(
                onPressed: _loading ? null : _syncSubscription,
                icon: const Icon(Icons.cloud_sync_outlined),
                label: const Text('同步订阅源'),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
            child: Text(
              '推荐使用订阅源同步;本地导入会调起系统文件管理器选择 .js 音源文件,也可用右上角粘贴文本导入。',
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
          ),
          if (_loading)
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: Center(child: CircularProgressIndicator()),
            ),
          const SizedBox(height: 12),
          Expanded(
            child: _sources.isEmpty
                ? Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 40,
                    ),
                    child: Center(
                      child: Text(
                        '暂无音源,可以先同步订阅源',
                        style: TextStyle(color: cs.onSurfaceVariant),
                      ),
                    ),
                  )
                : ReorderableListView.builder(
                    padding: const EdgeInsets.only(bottom: 24),
                    itemCount: _sources.length,
                    onReorderItem: _reorderSources,
                    buildDefaultDragHandles: false,
                    proxyDecorator: (child, index, animation) => Material(
                      elevation: 6,
                      color: cs.surface,
                      shadowColor: cs.shadow.withValues(alpha: 0.2),
                      child: child,
                    ),
                    itemBuilder: (context, index) {
                      final s = _sources[index];
                      return ListTile(
                        key: ValueKey(s.id),
                        leading: ReorderableDragStartListener(
                          index: index,
                          child: Icon(
                            Icons.drag_indicator,
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                        title: Row(
                          children: [
                            Icon(
                              s.active
                                  ? Icons.radio_button_checked
                                  : Icons.radio_button_unchecked,
                              size: 18,
                              color: s.active
                                  ? cs.primary
                                  : cs.onSurfaceVariant,
                            ),
                            const SizedBox(width: 8),
                            Expanded(child: Text(s.name)),
                          ],
                        ),
                        subtitle: Text(
                          '${s.active ? '当前使用 · ' : ''}${s.enabled ? '已开启' : '已关闭'} · 协议 v${s.apiVersion} · ${s.id}',
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Switch(
                              value: s.enabled,
                              onChanged: (v) async {
                                await SourceManager.instance.setEnabled(
                                  s.id,
                                  v,
                                );
                                _refresh();
                              },
                            ),
                            IconButton(
                              icon: Icon(
                                Icons.more_vert,
                                color: cs.onSurfaceVariant,
                              ),
                              tooltip: '更多',
                              onPressed: () => _showSourceMenu(s),
                            ),
                          ],
                        ),
                        onTap: () async {
                          if (!s.enabled) {
                            _toast('请先开启音源');
                            return;
                          }
                          await SourceManager.instance.setActive(s.id);
                          _refresh();
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

/// 输入对话框:controller 由自身 State 在 dispose 时释放,避免对话框退场动画
/// 期间 TextField 访问已释放 controller 导致崩溃。确定返回文本,取消返回 null。
class _PromptDialog extends StatefulWidget {
  final String title;
  final String hintText;
  final int maxLines;
  final TextInputType keyboardType;
  final String confirmText;
  final String initialText;

  const _PromptDialog({
    required this.title,
    required this.hintText,
    this.maxLines = 1,
    this.keyboardType = TextInputType.text,
    this.confirmText = '确定',
    this.initialText = '',
  });

  @override
  State<_PromptDialog> createState() => _PromptDialogState();
}

class _PromptDialogState extends State<_PromptDialog> {
  final TextEditingController _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _ctrl.text = widget.initialText;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: double.maxFinite,
        child: TextField(
          controller: _ctrl,
          autofocus: true,
          maxLines: widget.maxLines,
          keyboardType: widget.keyboardType,
          onSubmitted: widget.maxLines == 1
              ? (_) => Navigator.pop(context, _ctrl.text)
              : null,
          decoration: InputDecoration(
            hintText: widget.hintText,
            border: const OutlineInputBorder(),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _ctrl.text),
          child: Text(widget.confirmText),
        ),
      ],
    );
  }
}
