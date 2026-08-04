import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

import '../source/models.dart';
import 'log_service.dart';

class SniffResult {
  final String url;
  final Map<String, String> headers;

  const SniffResult({required this.url, this.headers = const {}});
}

class _CachedSniffResult {
  final SniffResult result;
  final DateTime expiresAt;

  const _CachedSniffResult({required this.result, required this.expiresAt});
}

class SniffService {
  SniffService._();
  static final instance = SniffService._();

  static const MethodChannel _channel = MethodChannel('tingshu/audio_sniffer');
  static const Duration _cacheDuration = Duration(seconds: 90);

  final Map<String, Future<SniffResult>> _inFlight = {};
  final Map<String, _CachedSniffResult> _cache = {};
  Future<void> _queue = Future<void>.value();

  Future<SniffResult> sniff(SniffRequest request) async {
    if (request.url.isEmpty) throw Exception('嗅探页面地址为空');
    final key = _requestKey(request);
    final now = DateTime.now();
    _cache.removeWhere((_, entry) => !entry.expiresAt.isAfter(now));
    final cached = _cache[key];
    if (cached != null) {
      LogService.instance.info(
        'Sniff',
        '复用近期网页音频嗅探结果',
        detail: '页面: ${request.url}\n音频: ${cached.result.url}',
      );
      return cached.result;
    }

    final running = _inFlight[key];
    if (running != null) {
      LogService.instance.info(
        'Sniff',
        '复用正在进行的网页音频嗅探',
        detail: '页面: ${request.url}',
      );
      return running;
    }

    final completer = Completer<SniffResult>();
    _inFlight[key] = completer.future;
    _queue = _queue.then((_) => _runQueued(request, key, completer));
    return completer.future;
  }

  Future<void> _runQueued(
    SniffRequest request,
    String key,
    Completer<SniffResult> completer,
  ) async {
    try {
      final result = await _sniffNow(request);
      _cache[key] = _CachedSniffResult(
        result: result,
        expiresAt: DateTime.now().add(_cacheDuration),
      );
      if (!completer.isCompleted) completer.complete(result);
    } catch (error, stack) {
      if (!completer.isCompleted) completer.completeError(error, stack);
    } finally {
      if (identical(_inFlight[key], completer.future)) _inFlight.remove(key);
    }
  }

  Future<SniffResult> _sniffNow(SniffRequest request) async {
    LogService.instance.info(
      'Sniff',
      '开始后台网页音频嗅探',
      detail:
          '页面: ${request.url}\n点击: ${request.click.isEmpty ? '无' : request.click}\n等待: ${request.waitMs} ms',
    );
    final result = await _channel.invokeMethod<Map<dynamic, dynamic>>('sniff', {
      'url': request.url,
      'headers': _encodeHeaders(request.headers),
      'click': request.click,
      'waitMs': request.waitMs,
      'audioPatterns': request.audioPatterns,
      'userAgent': request.userAgent,
    });
    final url = '${result?['url'] ?? ''}'.trim();
    if (url.isEmpty) throw Exception('没有嗅探到音频资源');
    final headers = <String, String>{};
    headers.addAll(_decodeHeaders('${result?['headers'] ?? ''}'));
    LogService.instance.info(
      'Sniff',
      '网页音频嗅探成功',
      detail: '页面: ${request.url}\n音频: $url',
    );
    return SniffResult(url: url, headers: headers);
  }

  String _requestKey(SniffRequest request) {
    final sortedHeaders = request.headers.entries.toList()
      ..sort((a, b) => a.key.toLowerCase().compareTo(b.key.toLowerCase()));
    return jsonEncode({
      'url': request.url,
      'headers': {for (final entry in sortedHeaders) entry.key: entry.value},
      'click': request.click,
      'waitMs': request.waitMs,
      'patterns': request.audioPatterns,
      'userAgent': request.userAgent,
    });
  }

  String _encodeHeaders(Map<String, String> headers) {
    return headers.entries
        .map((entry) => '${entry.key}:${entry.value}')
        .join('\n');
  }

  Map<String, String> _decodeHeaders(String raw) {
    final out = <String, String>{};
    for (final line in raw.split('\n')) {
      final index = line.indexOf(':');
      if (index <= 0) continue;
      out[line.substring(0, index).trim()] = line.substring(index + 1).trim();
    }
    return out;
  }
}
