import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart' show rootBundle;
import 'package:dio/dio.dart';
import 'package:flutter_js/flutter_js.dart';

import 'source_crypto.dart';

/// 内嵌 JS 引擎(QuickJS):运行用户粘贴的 JS 音源脚本。
/// - uni.request 经 http 通道桥接到 dio(支持自定义请求头)
/// - 音源方法调用经 result 通道异步返回
class JsEngine {
  JsEngine._();
  static final JsEngine instance = JsEngine._();

  JavascriptRuntime? _rt;
  final Dio _dio = Dio();
  final Map<int, Completer<dynamic>> _pending = {};
  int _reqSeq = 0;
  Timer? _pump;
  bool _ready = false;
  Future<void>? _initFuture;

  JavascriptRuntime get _runtime {
    final rt = _rt;
    if (rt == null) {
      throw StateError('JS 引擎尚未初始化');
    }
    return rt;
  }

  Future<void> init() async {
    if (_ready) return;
    final inflight = _initFuture;
    if (inflight != null) {
      await inflight;
      return;
    }
    final completer = Completer<void>();
    _initFuture = completer.future;
    try {
      final rt = getJavascriptRuntime();
      final shim = await rootBundle.loadString('assets/js/uni_shim.js');
      final r = rt.evaluate(shim);
      if (r.isError) {
        throw Exception('uni 垫片加载失败: ${r.stringResult}');
      }
      rt.onMessage('http', _handleHttp);
      rt.onMessage('crypto', _handleCrypto);
      rt.onMessage('result', _handleResult);
      _rt = rt;
      _ready = true;
      completer.complete();
    } catch (e, stack) {
      _initFuture = null;
      completer.completeError(e, stack);
      rethrow;
    }
  }

  // ── crypto 通道:提供与站点无关的通用加密能力 ──
  void _handleCrypto(dynamic args) {
    final m = (args is Map) ? args : const {};
    final id = (m['id'] is num) ? (m['id'] as num).toInt() : 0;
    unawaited(_doCrypto(id, m));
  }

  Future<void> _doCrypto(int id, Map<dynamic, dynamic> args) async {
    try {
      final operation = '${args['operation'] ?? ''}';
      late final String plainText;
      switch (operation) {
        case 'aesCbcDecrypt':
          plainText = SourceCrypto.aesCbcDecrypt(
            cipherText: '${args['cipherText'] ?? ''}',
            key: '${args['key'] ?? ''}',
            iv: '${args['iv'] ?? ''}',
            inputEncoding: '${args['inputEncoding'] ?? 'base64'}',
            keyEncoding: '${args['keyEncoding'] ?? 'base64'}',
            ivEncoding: '${args['ivEncoding'] ?? 'base64'}',
          );
        case 'xChaCha20Poly1305Decrypt':
          plainText = SourceCrypto.xChaCha20Poly1305Decrypt(
            cipherText: '${args['cipherText'] ?? ''}',
            key: '${args['key'] ?? ''}',
            nonce: '${args['nonce'] ?? ''}',
            inputEncoding: '${args['inputEncoding'] ?? 'base64'}',
            keyEncoding: '${args['keyEncoding'] ?? 'base64'}',
            nonceEncoding: '${args['nonceEncoding'] ?? 'base64'}',
          );
        default:
          throw ArgumentError('不支持的加密操作: $operation');
      }
      final env = jsonEncode({'data': plainText});
      _runtime.evaluate('__cryptoResolve($id, ${jsonEncode(env)})');
    } catch (e) {
      _runtime.evaluate('__cryptoReject($id, ${jsonEncode(e.toString())})');
    }
  }

  // 仅在有未完成调用时驱动 QuickJS 微任务队列(推进 Promise 链),
  // 队列清空即停,避免空闲期每秒约 100 次的空转唤醒。
  void _ensurePump() {
    if (_pending.isEmpty) return;
    _pump ??= Timer.periodic(const Duration(milliseconds: 50), (_) {
      try {
        while (_runtime.executePendingJob() > 0) {}
      } catch (_) {}
      if (_pending.isEmpty) _stopPump();
    });
  }

  void _stopPump() {
    _pump?.cancel();
    _pump = null;
  }

  // ── http 通道:执行音源发起的网络请求 ──
  void _handleHttp(dynamic args) {
    final m = (args is Map) ? args : const {};
    final int id = (m['id'] is num) ? (m['id'] as num).toInt() : 0;
    final String url = '${m['url'] ?? ''}';
    final String method = '${m['method'] ?? 'GET'}'.toUpperCase();
    final dynamic data = m['data'];
    final header = <String, dynamic>{};
    if (m['header'] is Map) {
      (m['header'] as Map).forEach((k, v) => header['$k'] = v);
    }
    final int timeout = (m['timeout'] is num)
        ? (m['timeout'] as num).toInt()
        : 15000;
    _doHttp(id, url, method, data, header, timeout);
  }

  Future<void> _doHttp(
    int id,
    String url,
    String method,
    dynamic data,
    Map<String, dynamic> header,
    int timeout,
  ) async {
    try {
      final options = Options(
        method: method,
        headers: header,
        responseType: ResponseType.plain, // 拿原始字符串,自己决定是否 JSON 解析
        sendTimeout: Duration(milliseconds: timeout),
        receiveTimeout: Duration(milliseconds: timeout),
        followRedirects: true,
        validateStatus: (_) => true,
      );
      Response resp;
      if (method == 'GET') {
        resp = await _dio.get(
          url,
          queryParameters: (data is Map)
              ? Map<String, dynamic>.from(data)
              : null,
          options: options,
        );
      } else {
        resp = await _dio.request(url, data: data, options: options);
      }
      final body = resp.data?.toString() ?? '';
      dynamic parsed;
      try {
        parsed = jsonDecode(body); // 能解析成 JSON 就传对象,否则传原始字符串
      } catch (_) {
        parsed = body;
      }
      final env = jsonEncode({
        'statusCode': resp.statusCode ?? 0,
        'header': resp.headers.map,
        'data': parsed,
      });
      _runtime.evaluate('__httpResolve($id, ${jsonEncode(env)})');
    } catch (e) {
      _runtime.evaluate('__httpReject($id, ${jsonEncode(e.toString())})');
    }
  }

  // ── result 通道:音源方法调用结果 ──
  void _handleResult(dynamic args) {
    final m = (args is Map) ? args : const {};
    final int reqId = (m['reqId'] is num) ? (m['reqId'] as num).toInt() : -1;
    final c = _pending.remove(reqId);
    if (c == null || c.isCompleted) return;
    if (m['ok'] == true) {
      c.complete(m['data']);
    } else {
      c.completeError(Exception('${m['err'] ?? '音源调用失败'}'));
    }
  }

  /// 编译并注册一个音源,返回 {id, name}
  Future<Map<String, dynamic>> loadSource(String code) async {
    await init();
    final res = _runtime.evaluate('__loadSource(${jsonEncode(code)})');
    if (res.isError) {
      throw Exception('音源解析失败: ${res.stringResult}');
    }
    final m = jsonDecode(res.stringResult) as Map;
    return {
      'id': '${m['id']}',
      'name': '${m['name']}',
      'apiVersion': '${m['apiVersion'] ?? 1}',
      'configFields': (m['configFields'] as List?) ?? const [],
      'loginUrl': '${m['loginUrl'] ?? ''}',
      'loginConfigKey': '${m['loginConfigKey'] ?? ''}',
      'supportsDiscover': m['supportsDiscover'] == true,
    };
  }

  Future<void> setSourceConfig(
    String sourceId,
    Map<String, dynamic> config,
  ) async {
    await init();
    final r = _runtime.evaluate(
      '__setSourceConfig(${jsonEncode(sourceId)}, ${jsonEncode(jsonEncode(config))})',
    );
    if (r.isError) {
      throw Exception('音源配置注入失败: ${r.stringResult}');
    }
  }

  /// 调用音源方法(search/getChapters/getAudioUrl)
  Future<dynamic> call(
    String sourceId,
    String method,
    List<dynamic> args, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    await init();
    final reqId = ++_reqSeq;
    final c = Completer<dynamic>();
    _pending[reqId] = c;
    final argsJson = jsonEncode(args);
    final r = _runtime.evaluate(
      '__call($reqId, ${jsonEncode(sourceId)}, ${jsonEncode(method)}, ${jsonEncode(argsJson)})',
    );
    if (r.isError) {
      _pending.remove(reqId);
      if (_pending.isEmpty) _stopPump();
      throw Exception('调用失败: ${r.stringResult}');
    }
    _ensurePump();
    return c.future.timeout(
      timeout,
      onTimeout: () {
        _pending.remove(reqId);
        if (_pending.isEmpty) _stopPump();
        throw TimeoutException('音源调用超时: $method');
      },
    );
  }

  void dispose() {
    _stopPump();
  }
}
