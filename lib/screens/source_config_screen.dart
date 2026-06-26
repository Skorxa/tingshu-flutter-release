import 'dart:convert';

import 'package:flutter/material.dart';

import '../source/models.dart';
import '../source/source_manager.dart';

enum SourceConfigMode { all, login }

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
    super.dispose();
  }

  Future<void> _save() async {
    final config = Map<String, dynamic>.from(
      SourceManager.instance.getSourceConfig(widget.sourceId),
    );
    for (final field in _fields) {
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
