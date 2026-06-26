import 'package:flutter/services.dart';

import '../source/models.dart';
import 'log_service.dart';

class SniffResult {
  final String url;
  final Map<String, String> headers;

  const SniffResult({required this.url, this.headers = const {}});
}

class SniffService {
  SniffService._();
  static final instance = SniffService._();

  static const MethodChannel _channel = MethodChannel('tingshu/audio_sniffer');

  Future<SniffResult> sniff(SniffRequest request) async {
    if (request.url.isEmpty) throw Exception('嗅探页面地址为空');
    LogService.instance.info(
      'Sniff',
      '开始网页音频嗅探',
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
