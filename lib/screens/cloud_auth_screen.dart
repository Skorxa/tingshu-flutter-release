import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/cache_service.dart';
import '../data/cloud_auth_service.dart';
import '../data/log_service.dart';
import '../player/player_service.dart';
import '../source/models.dart';
import '../source/source_manager.dart';

class CloudAuthGate extends StatefulWidget {
  final Widget child;

  const CloudAuthGate({super.key, required this.child});

  @override
  State<CloudAuthGate> createState() => _CloudAuthGateState();
}

class _CloudAuthGateState extends State<CloudAuthGate>
    with WidgetsBindingObserver {
  final _auth = CloudAuthService.instance;
  bool _runtimeReady = false;
  bool _bootstrapping = false;
  bool _syncingCloudSubscription = false;
  bool _wasAllowed = false;
  bool _lockApplied = false;
  CloudAuthState? _lastState;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _auth.addListener(_handleAuthorizationChanged);
    scheduleMicrotask(_handleAuthorizationChanged);
  }

  @override
  void dispose() {
    _auth.removeListener(_handleAuthorizationChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed || !_auth.isConfigured) return;
    unawaited(_verifyAfterResume());
  }

  Future<void> _verifyAfterResume() async {
    await _auth.verify(allowOffline: true, quiet: true);
    if (_auth.state == CloudAuthState.authorized) {
      unawaited(_syncCloudSubscription());
    }
  }

  void _handleAuthorizationChanged() {
    final state = _auth.state;
    final allowed = _auth.canUseApp;
    final becameOnline =
        state == CloudAuthState.authorized &&
        _lastState != CloudAuthState.authorized;
    _lastState = state;

    if (allowed) {
      _lockApplied = false;
      CacheService.instance.resumeAfterAuthorization();
      if (!_wasAllowed || !_runtimeReady) {
        unawaited(_startAuthorizedRuntime());
      } else if (becameOnline) {
        unawaited(_syncCloudSubscription());
      }
    } else if (!_lockApplied) {
      _lockApplied = true;
      CacheService.instance.suspendForAuthorization();
      unawaited(PlayerService.instance.pause());
    }
    _wasAllowed = allowed;
    if (mounted) setState(() {});
  }

  Future<void> _startAuthorizedRuntime() async {
    if (_bootstrapping) return;
    _bootstrapping = true;
    if (mounted) setState(() {});
    try {
      if (!_runtimeReady) {
        try {
          await PlayerService.instance.restoreLastSession();
          LogService.instance.info('Player', '上次播放恢复完成');
        } catch (e, stack) {
          LogService.instance.error(
            'Player',
            '上次播放恢复失败',
            error: e,
            stack: stack,
          );
        }
        try {
          await CacheService.instance.restorePending();
        } catch (e, stack) {
          LogService.instance.error(
            'Cache',
            '自动缓存任务恢复失败',
            error: e,
            stack: stack,
          );
        }
        _runtimeReady = true;
      }
    } finally {
      _bootstrapping = false;
      if (!_auth.canUseApp) {
        CacheService.instance.suspendForAuthorization();
        unawaited(PlayerService.instance.pause());
      } else if (_auth.state == CloudAuthState.authorized) {
        unawaited(_syncCloudSubscription());
      }
      if (mounted) setState(() {});
    }
  }

  Future<void> _syncCloudSubscription() async {
    if (_syncingCloudSubscription || _auth.state != CloudAuthState.authorized) {
      return;
    }
    final url = _auth.privateSubscriptionUrl;
    if (url.isEmpty) return;
    _syncingCloudSubscription = true;
    try {
      SourceSubscriptionMeta? subscription;
      for (final item in SourceManager.instance.getSubscriptions()) {
        if (item.requestUrl == url) {
          subscription = item;
          break;
        }
      }
      subscription ??= await SourceManager.instance.saveSubscription(
        url: url,
        name: '橘听云端音源',
        enabled: true,
        autoUpdate: true,
      );
      if (!subscription.enabled) return;
      if (!subscription.hasSuccess) {
        await SourceManager.instance.syncSubscriptionById(subscription.id);
        return;
      }
      final check = await SourceManager.instance.checkSubscriptionById(
        subscription.id,
      );
      if (check.hasUpdate) {
        await SourceManager.instance.syncSubscriptionById(subscription.id);
      }
    } catch (e, stack) {
      LogService.instance.error(
        'CloudAuth',
        '云端音源同步失败',
        error: e,
        stack: stack,
      );
    } finally {
      _syncingCloudSubscription = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _auth,
      builder: (context, _) {
        if (_auth.canUseApp && _runtimeReady) return widget.child;
        if (_auth.canUseApp ||
            _auth.state == CloudAuthState.checking ||
            _bootstrapping) {
          return const _CloudAuthMessage(
            icon: Icons.verified_user_outlined,
            title: '正在验证设备',
            message: '请稍候',
            loading: true,
          );
        }
        return switch (_auth.state) {
          CloudAuthState.activationRequired => const CloudActivationScreen(),
          CloudAuthState.unconfigured => const _CloudAuthMessage(
            icon: Icons.settings_ethernet,
            title: '授权服务未配置',
            message: '当前安装包缺少云控服务地址，请安装正确的发行包。',
          ),
          CloudAuthState.disabled => _CloudAuthMessage(
            icon: Icons.block_outlined,
            title: '设备不可用',
            message: _auth.error.isEmpty ? '当前用户或设备已被停用。' : _auth.error,
            actionLabel: '重新验证',
            onAction: _auth.retry,
          ),
          CloudAuthState.error => _CloudAuthMessage(
            icon: Icons.cloud_off_outlined,
            title: '暂时无法验证',
            message: _auth.error.isEmpty ? '请检查网络后重试。' : _auth.error,
            actionLabel: '重试',
            onAction: _auth.retry,
          ),
          _ => const _CloudAuthMessage(
            icon: Icons.verified_user_outlined,
            title: '正在准备应用',
            message: '请稍候',
            loading: true,
          ),
        };
      },
    );
  }
}

class CloudActivationScreen extends StatefulWidget {
  const CloudActivationScreen({super.key});

  @override
  State<CloudActivationScreen> createState() => _CloudActivationScreenState();
}

class _CloudActivationScreenState extends State<CloudActivationScreen> {
  final _formKey = GlobalKey<FormState>();
  final _inviteController = TextEditingController();
  final _nameController = TextEditingController();
  bool _submitting = false;
  String _error = '';

  @override
  void dispose() {
    _inviteController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _activate() async {
    if (_submitting || !(_formKey.currentState?.validate() ?? false)) return;
    setState(() {
      _submitting = true;
      _error = '';
    });
    try {
      await CloudAuthService.instance.activate(
        _inviteController.text,
        displayName: _nameController.text,
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString().replaceFirst('CloudAuthException: ', '');
        });
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final visibleError = _error.isNotEmpty
        ? _error
        : CloudAuthService.instance.error;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(28),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: CircleAvatar(
                        radius: 30,
                        backgroundColor: colors.primaryContainer,
                        foregroundColor: colors.onPrimaryContainer,
                        child: const Icon(Icons.headphones, size: 30),
                      ),
                    ),
                    const SizedBox(height: 28),
                    Text(
                      '激活橘听',
                      style: Theme.of(context).textTheme.headlineMedium,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '输入管理员提供的邀请码，将授权绑定到当前设备。',
                      style: TextStyle(color: colors.onSurfaceVariant),
                    ),
                    const SizedBox(height: 28),
                    TextFormField(
                      controller: _inviteController,
                      enabled: !_submitting,
                      textCapitalization: TextCapitalization.characters,
                      autocorrect: false,
                      autofillHints: const [AutofillHints.oneTimeCode],
                      decoration: const InputDecoration(
                        labelText: '邀请码',
                        prefixIcon: Icon(Icons.key_outlined),
                        border: OutlineInputBorder(),
                      ),
                      validator: (value) =>
                          (value ?? '').trim().isEmpty ? '请输入邀请码' : null,
                      onFieldSubmitted: (_) => _activate(),
                    ),
                    const SizedBox(height: 14),
                    TextFormField(
                      controller: _nameController,
                      enabled: !_submitting,
                      maxLength: 50,
                      decoration: const InputDecoration(
                        labelText: '显示名称（可选）',
                        prefixIcon: Icon(Icons.person_outline),
                        border: OutlineInputBorder(),
                      ),
                      onFieldSubmitted: (_) => _activate(),
                    ),
                    if (visibleError.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(visibleError, style: TextStyle(color: colors.error)),
                    ],
                    const SizedBox(height: 18),
                    FilledButton.icon(
                      onPressed: _submitting ? null : _activate,
                      icon: _submitting
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.verified_user_outlined),
                      label: Text(_submitting ? '正在激活' : '激活设备'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class CloudAuthorizationScreen extends StatefulWidget {
  const CloudAuthorizationScreen({super.key});

  @override
  State<CloudAuthorizationScreen> createState() =>
      _CloudAuthorizationScreenState();
}

class _CloudAuthorizationScreenState extends State<CloudAuthorizationScreen> {
  bool _refreshing = false;

  Future<void> _refresh() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    try {
      await CloudAuthService.instance.verify(allowOffline: true);
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = CloudAuthService.instance;
    return Scaffold(
      appBar: AppBar(title: const Text('设备授权')),
      body: AnimatedBuilder(
        animation: auth,
        builder: (context, _) {
          final license = auth.license;
          final deviceId = auth.device?.deviceId ?? '';
          return ListView(
            padding: const EdgeInsets.symmetric(vertical: 8),
            children: [
              ListTile(
                leading: Icon(
                  auth.canUseApp ? Icons.verified_user : Icons.gpp_bad_outlined,
                ),
                title: const Text('授权状态'),
                subtitle: Text(
                  auth.error.isEmpty
                      ? auth.stateLabel
                      : '${auth.stateLabel} · ${auth.error}',
                ),
                trailing: _StateBadge(label: auth.stateLabel),
              ),
              const Divider(indent: 56),
              ListTile(
                leading: const Icon(Icons.person_outline),
                title: const Text('授权用户'),
                subtitle: Text(
                  license?.displayName.isNotEmpty == true
                      ? license!.displayName
                      : '未读取',
                ),
              ),
              const Divider(indent: 56),
              ListTile(
                leading: const Icon(Icons.event_outlined),
                title: const Text('有效期'),
                subtitle: Text(_expiryLabel(license?.expiresAt)),
              ),
              const Divider(indent: 56),
              ListTile(
                leading: const Icon(Icons.smartphone_outlined),
                title: const Text('设备标识'),
                subtitle: Text(deviceId.isEmpty ? '未读取' : deviceId),
                trailing: deviceId.isEmpty
                    ? null
                    : IconButton(
                        tooltip: '复制设备标识',
                        icon: const Icon(Icons.copy_outlined),
                        onPressed: () async {
                          await Clipboard.setData(
                            ClipboardData(text: deviceId),
                          );
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('设备标识已复制')),
                            );
                          }
                        },
                      ),
              ),
              const Divider(indent: 56),
              ListTile(
                leading: const Icon(Icons.schedule_outlined),
                title: const Text('最近验证'),
                subtitle: Text(_timeLabel(auth.lastVerifiedAt)),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
                child: FilledButton.icon(
                  onPressed: _refreshing ? null : _refresh,
                  icon: _refreshing
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh),
                  label: const Text('重新验证'),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _CloudAuthMessage extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;
  final bool loading;
  final String? actionLabel;
  final Future<void> Function()? onAction;

  const _CloudAuthMessage({
    required this.icon,
    required this.title,
    required this.message,
    this.loading = false,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 52, color: colors.primary),
                  const SizedBox(height: 22),
                  Text(title, style: Theme.of(context).textTheme.headlineSmall),
                  const SizedBox(height: 10),
                  Text(
                    message,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: colors.onSurfaceVariant),
                  ),
                  if (loading) ...[
                    const SizedBox(height: 24),
                    const CircularProgressIndicator(),
                  ],
                  if (actionLabel != null && onAction != null) ...[
                    const SizedBox(height: 24),
                    FilledButton.icon(
                      onPressed: () => onAction!(),
                      icon: const Icon(Icons.refresh),
                      label: Text(actionLabel!),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _StateBadge extends StatelessWidget {
  final String label;

  const _StateBadge({required this.label});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.secondaryContainer,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        child: Text(
          label,
          style: TextStyle(
            color: colors.onSecondaryContainer,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

String _expiryLabel(int? timestamp) {
  if (timestamp == null) return '长期有效';
  return _formatDateTime(
    DateTime.fromMillisecondsSinceEpoch(timestamp * 1000).toLocal(),
  );
}

String _timeLabel(int timestamp) {
  if (timestamp <= 0) return '尚未验证';
  return _formatDateTime(
    DateTime.fromMillisecondsSinceEpoch(timestamp * 1000).toLocal(),
  );
}

String _formatDateTime(DateTime value) {
  String two(int number) => number.toString().padLeft(2, '0');
  return '${value.year}-${two(value.month)}-${two(value.day)} '
      '${two(value.hour)}:${two(value.minute)}';
}
