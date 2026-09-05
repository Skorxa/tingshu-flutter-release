import 'dart:async';

import 'package:flutter/foundation.dart';

class AppLogEntry {
  final int id;
  final DateTime time;
  final String level;
  final String module;
  final String message;
  final String? detail;

  AppLogEntry({
    required this.id,
    required this.time,
    required this.level,
    required this.module,
    required this.message,
    this.detail,
  });

  String get displayTime {
    String two(int value) => value.toString().padLeft(2, '0');
    String three(int value) => value.toString().padLeft(3, '0');
    return '${two(time.hour)}:${two(time.minute)}:${two(time.second)}.${three(time.millisecond)}';
  }
}

class LogService extends ChangeNotifier {
  LogService._();
  static final instance = LogService._();

  static const _maxEntries = 800;
  static const _batchInterval = Duration(milliseconds: 500);

  final List<AppLogEntry> _entries = [];
  int _nextId = 0;
  bool _dirty = false;
  Timer? _batchTimer;

  List<AppLogEntry> get entries => List.unmodifiable(_entries);

  AppLogEntry info(String module, String message, {String? detail}) {
    return _add('INFO', module, message, detail: detail);
  }

  AppLogEntry warning(String module, String message, {String? detail}) {
    return _add('WARN', module, message, detail: detail);
  }

  AppLogEntry error(
    String module,
    String message, {
    Object? error,
    StackTrace? stack,
  }) {
    final parts = <String>[];
    if (error != null) parts.add(error.toString());
    if (stack != null) parts.add(stack.toString());
    return _add(
      'ERROR',
      module,
      message,
      detail: parts.isEmpty ? null : parts.join('\n'),
    );
  }

  void clear() {
    _entries.clear();
    _batchTimer?.cancel();
    _batchTimer = null;
    _dirty = false;
    notifyListeners();
  }

  AppLogEntry _add(
    String level,
    String module,
    String message, {
    String? detail,
  }) {
    final entry = AppLogEntry(
      id: _nextId++,
      time: DateTime.now(),
      level: level,
      module: module,
      message: message,
      detail: detail,
    );
    _entries.insert(0, entry);
    if (_entries.length > _maxEntries) {
      _entries.removeRange(_maxEntries, _entries.length);
    }
    // debugPrint 仅在 debug 模式输出,release 模式跳过 console I/O
    assert(() {
      final detailText = detail == null ? '' : '\n$detail';
      debugPrint('[$level][$module] $message$detailText');
      return true;
    }());
    _scheduleNotify();
    return entry;
  }

  /// 批量合并通知:攒到 [_batchInterval] 再触发一次 [notifyListeners],
  /// 避免高频日志(如播放进度保存、缓存进度)反复重建 UI。
  void _scheduleNotify() {
    if (_dirty) return;
    _dirty = true;
    _batchTimer ??= Timer(_batchInterval, () {
      _dirty = false;
      _batchTimer = null;
      notifyListeners();
    });
  }

  /// 构建可粘贴到 Issue / 反馈群的诊断报告(最新在前)。
  /// 导出前对每条日志做尽力脱敏:抹掉 URL 查询参数中的常见凭据值。
  String buildDiagnosticReport() {
    final buffer = StringBuffer();
    final now = DateTime.now();
    buffer.writeln('橘听诊断报告');
    buffer.writeln(
      '生成时间: ${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')} '
      '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}',
    );
    buffer.writeln('条数: ${_entries.length}(内存环形缓冲,进程重启后丢失)');
    buffer.writeln('说明: 已对 URL 中的 token/key/sign/auth 参数做尽力脱敏,导出前请再人工检查。');
    buffer.writeln('---');
    for (final entry in _entries) {
      final time =
          '${entry.time.year}-${entry.time.month.toString().padLeft(2, '0')}-${entry.time.day.toString().padLeft(2, '0')} '
          '${entry.displayTime}';
      buffer.writeln('[${entry.level}][$time][${entry.module}] ${_sanitize(entry.message)}');
      final detail = entry.detail;
      if (detail != null && detail.isNotEmpty) {
        buffer.writeln(_sanitize(detail));
      }
    }
    return buffer.toString();
  }

  static final RegExp _secretParamPattern = RegExp(
    r'([?&](?:token|key|sign|sig|auth|access_token|refresh_token|password|pwd)=)[^&\s]+',
    caseSensitive: false,
  );
  static final RegExp _basicAuthPattern = RegExp(
    r'(Authorization["\s:]*Basic\s+)[A-Za-z0-9+/=]+',
    caseSensitive: false,
  );

  static String _sanitize(String text) {
    return text
        .replaceAllMapped(
          _secretParamPattern,
          (match) => '${match.group(1)}***',
        )
        .replaceAllMapped(
          _basicAuthPattern,
          (match) => '${match.group(1)}***',
        );
  }
}
