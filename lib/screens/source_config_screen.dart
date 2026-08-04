import 'dart:convert';

import 'package:flutter/material.dart';

import '../source/models.dart';
import '../source/source_manager.dart';

enum SourceConfigMode { all, login }

class _AccountConfigEntry {
  _AccountConfigEntry({String account = '', String password = ''})
    : accountController = TextEditingController(text: account),
      passwordController = TextEditingController(text: password);

  final TextEditingController accountController;
  final TextEditingController passwordController;
  bool obscurePassword = true;

  void dispose() {
    accountController.dispose();
    passwordController.dispose();
  }
}

class SourceConfigScreen extends StatefulWidget {
  final String sourceId;
  final SourceConfigMode mode;

  const SourceConfigScreen({
    super.key,
    required this.sourceId,
    this.mode = SourceConfigMode.all,
  });

  @override
  State<SourceConfigScreen> createState() => _SourceConfigScreenState();
}

class _SourceConfigScreenState extends State<SourceConfigScreen> {
  final Map<String, TextEditingController> _controllers = {};
  final Map<String, List<_AccountConfigEntry>> _accountEntries = {};
  late final List<SourceConfigField> _fields;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final fields = SourceManager.instance.getSourceConfigFields(
      widget.sourceId,
    );
    _fields = widget.mode == SourceConfigMode.login
        ? fields.where(SourceManager.isLoginConfigField).toList()
        : fields;
    final config = SourceManager.instance.getSourceConfig(widget.sourceId);
    for (final field in _fields) {
      if (_isAccountListField(field)) {
        final entries = _decodeAccountEntries(config[field.key]);
        _accountEntries[field.key] = entries.isEmpty
            ? [_AccountConfigEntry()]
            : entries;
        continue;
      }
      final controller = TextEditingController();
      final value = config[field.key];
      if (_isJsonField(field) && value != null && value is! String) {
        controller.text = const JsonEncoder.withIndent('  ').convert(value);
      } else {
        controller.text = value == null ? '' : '$value';
      }
      _controllers[field.key] = controller;
    }
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    for (final entries in _accountEntries.values) {
      for (final entry in entries) {
        entry.dispose();
      }
    }
    super.dispose();
  }

  Future<void> _save() async {
    final config = Map<String, dynamic>.from(
      SourceManager.instance.getSourceConfig(widget.sourceId),
    );
    for (final field in _fields) {
      if (_isAccountListField(field)) {
        final value = _validatedAccounts(field);
        if (value == null) return;
        if (value.isEmpty) {
          config.remove(field.key);
        } else {
          config[field.key] = value;
        }
        continue;
      }
      final value = (_controllers[field.key]?.text ?? '').trim();
      if (value.isEmpty) {
        if (field.required) {
          _toast('${field.label} 不能为空');
          return;
        }
        config.remove(field.key);
        continue;
      }
      if (_isJsonField(field)) {
        try {
          config[field.key] = jsonDecode(value);
        } catch (e) {
          _toast('${field.label} 不是有效 JSON');
          return;
        }
      } else {
        config[field.key] = value;
      }
    }

    setState(() => _saving = true);
    try {
      await SourceManager.instance.setSourceConfig(widget.sourceId, config);
      if (!mounted) return;
      _toast('已保存');
      Navigator.pop(context);
    } catch (e) {
      _toast(e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _clear() async {
    setState(() => _saving = true);
    try {
      final config = Map<String, dynamic>.from(
        SourceManager.instance.getSourceConfig(widget.sourceId),
      );
      for (final field in _fields) {
        config.remove(field.key);
      }
      await SourceManager.instance.setSourceConfig(widget.sourceId, config);
      if (!mounted) return;
      _toast('已清空');
      Navigator.pop(context);
    } catch (e) {
      _toast(e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  List<_AccountConfigEntry> _decodeAccountEntries(dynamic value) {
    dynamic decoded = value;
    if (decoded is String && decoded.trim().isNotEmpty) {
      try {
        decoded = jsonDecode(decoded);
      } catch (_) {
        return [];
      }
    }
    if (decoded is Map && decoded['list'] is List) {
      decoded = decoded['list'];
    }
    if (decoded is! List) return [];

    final entries = <_AccountConfigEntry>[];
    for (final raw in decoded.whereType<Map>()) {
      final account =
          '${raw['email'] ?? raw['account'] ?? raw['username'] ?? ''}'.trim();
      final password = '${raw['password'] ?? ''}'.trim();
      if (account.isEmpty && password.isEmpty) continue;
      entries.add(_AccountConfigEntry(account: account, password: password));
    }
    return entries;
  }

  List<Map<String, String>>? _validatedAccounts(SourceConfigField field) {
    final rows = _accountEntries[field.key] ?? const <_AccountConfigEntry>[];
    final result = <Map<String, String>>[];
    final seen = <String>{};
    for (var i = 0; i < rows.length; i++) {
      final account = rows[i].accountController.text.trim();
      final password = rows[i].passwordController.text.trim();
      if (account.isEmpty && password.isEmpty) continue;
      if (account.isEmpty || password.isEmpty) {
        _toast('账号 ${i + 1} 的邮箱和密码需要同时填写');
        return null;
      }
      if (!seen.add(account.toLowerCase())) {
        _toast('账号池中存在重复账号：$account');
        return null;
      }
      result.add({'email': account, 'password': password});
    }
    if (field.required && result.isEmpty) {
      _toast('${field.label}至少添加一个账号');
      return null;
    }
    return result;
  }

  bool _isAccountListField(SourceConfigField field) {
    final type = field.type.toLowerCase();
    return type == 'account_list' || type == 'accounts';
  }

  bool _isJsonField(SourceConfigField field) {
    return field.type.toLowerCase() == 'json';
  }

  bool _isMultiline(SourceConfigField field) {
    final type = field.type.toLowerCase();
    return type == 'textarea' || type == 'json';
  }

  bool _isPassword(SourceConfigField field) {
    final type = field.type.toLowerCase();
    return type == 'password' || type == 'token';
  }

  void _addAccountEntry(String fieldKey) {
    setState(() {
      _accountEntries
          .putIfAbsent(fieldKey, () => [])
          .add(_AccountConfigEntry());
    });
  }

  void _removeAccountEntry(String fieldKey, int index) {
    final entries = _accountEntries[fieldKey];
    if (entries == null || index < 0 || index >= entries.length) return;
    final removed = entries[index];
    setState(() => entries.removeAt(index));
    WidgetsBinding.instance.addPostFrameCallback((_) => removed.dispose());
  }

  Widget _buildAccountListField(BuildContext context, SourceConfigField field) {
    final entries = _accountEntries[field.key] ?? <_AccountConfigEntry>[];
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${field.label}${field.required ? ' *' : ''}',
          style: theme.textTheme.titleMedium,
        ),
        if (field.hint.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            field.hint,
            style: theme.textTheme.bodySmall?.copyWith(
              color: cs.onSurfaceVariant,
            ),
          ),
        ],
        const SizedBox(height: 12),
        if (entries.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text('尚未添加账号', style: TextStyle(color: cs.onSurfaceVariant)),
          )
        else
          for (var i = 0; i < entries.length; i++) ...[
            _buildAccountRow(context, field.key, entries[i], i),
            if (i < entries.length - 1) const Divider(height: 28),
          ],
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: _saving ? null : () => _addAccountEntry(field.key),
          icon: const Icon(Icons.add),
          label: const Text('添加账号'),
        ),
      ],
    );
  }

  Widget _buildAccountRow(
    BuildContext context,
    String fieldKey,
    _AccountConfigEntry entry,
    int index,
  ) {
    final theme = Theme.of(context);
    return Column(
      key: ObjectKey(entry),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text('账号 ${index + 1}', style: theme.textTheme.labelLarge),
            ),
            IconButton(
              onPressed: _saving
                  ? null
                  : () => _removeAccountEntry(fieldKey, index),
              tooltip: '删除账号',
              icon: const Icon(Icons.delete_outline),
            ),
          ],
        ),
        TextField(
          controller: entry.accountController,
          enabled: !_saving,
          keyboardType: TextInputType.emailAddress,
          textInputAction: TextInputAction.next,
          autocorrect: false,
          decoration: const InputDecoration(
            labelText: '登录邮箱',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: entry.passwordController,
          enabled: !_saving,
          obscureText: entry.obscurePassword,
          enableSuggestions: false,
          autocorrect: false,
          decoration: InputDecoration(
            labelText: '密码',
            border: const OutlineInputBorder(),
            suffixIcon: IconButton(
              onPressed: _saving
                  ? null
                  : () => setState(
                      () => entry.obscurePassword = !entry.obscurePassword,
                    ),
              tooltip: entry.obscurePassword ? '显示密码' : '隐藏密码',
              icon: Icon(
                entry.obscurePassword
                    ? Icons.visibility_outlined
                    : Icons.visibility_off_outlined,
              ),
            ),
          ),
        ),
      ],
    );
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final sourceName = SourceManager.instance.getSourceName(widget.sourceId);
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.mode == SourceConfigMode.login ? '音源登录' : '音源设置'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            sourceName,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          Text(
            widget.sourceId,
            style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 18),
          if (_fields.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 32),
              child: Center(
                child: Text(
                  widget.mode == SourceConfigMode.login
                      ? '这个音源没有声明登录字段'
                      : '这个音源没有声明需要设置',
                  style: TextStyle(color: cs.onSurfaceVariant),
                ),
              ),
            )
          else
            for (final field in _fields) ...[
              if (_isAccountListField(field))
                _buildAccountListField(context, field)
              else
                TextField(
                  controller: _controllers[field.key],
                  minLines: _isMultiline(field) ? 3 : 1,
                  maxLines: _isMultiline(field) ? 8 : 1,
                  obscureText: !_isMultiline(field) && _isPassword(field),
                  decoration: InputDecoration(
                    labelText: '${field.label}${field.required ? ' *' : ''}',
                    hintText: field.hint.isEmpty ? null : field.hint,
                    border: const OutlineInputBorder(),
                  ),
                ),
              const SizedBox(height: 12),
            ],
          if (_fields.isNotEmpty)
            Text(
              '音源 JS 可通过 this.config.<key> 读取这些配置。只有音源声明的字段会出现在这里。',
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _saving || _fields.isEmpty ? null : _clear,
                  child: const Text('清空'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: _saving || _fields.isEmpty ? null : _save,
                  child: Text(_saving ? '保存中' : '保存'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
