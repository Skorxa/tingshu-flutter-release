import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tingshu_flutter/data/sniff_service.dart';
import 'package:tingshu_flutter/source/models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('tingshu/audio_sniffer');

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'sniff requests are deduplicated, serialized and briefly cached',
    () async {
      final firstGate = Completer<void>();
      final calls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            final arguments = Map<dynamic, dynamic>.from(call.arguments as Map);
            final pageUrl = '${arguments['url']}';
            calls.add(pageUrl);
            if (pageUrl.endsWith('/chapter-1')) await firstGate.future;
            return <String, dynamic>{
              'url': '$pageUrl/audio.mp3',
              'headers': 'Referer:$pageUrl',
            };
          });

      final firstRequest = SniffRequest(
        url: 'https://example.test/chapter-1',
        click: '.play',
      );
      final secondRequest = SniffRequest(
        url: 'https://example.test/chapter-2',
        click: '.play',
      );

      final first = SniffService.instance.sniff(firstRequest);
      final duplicate = SniffService.instance.sniff(firstRequest);
      final second = SniffService.instance.sniff(secondRequest);
      await Future<void>.delayed(Duration.zero);

      expect(calls, ['https://example.test/chapter-1']);
      firstGate.complete();
      final firstResults = await Future.wait([first, duplicate]);
      final secondResult = await second;

      expect(firstResults[0].url, firstResults[1].url);
      expect(secondResult.url, endsWith('/chapter-2/audio.mp3'));
      expect(calls, [
        'https://example.test/chapter-1',
        'https://example.test/chapter-2',
      ]);

      final cached = await SniffService.instance.sniff(firstRequest);
      expect(cached.url, firstResults.first.url);
      expect(calls, hasLength(2));
    },
  );
}
