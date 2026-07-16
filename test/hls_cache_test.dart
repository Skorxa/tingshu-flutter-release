import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tingshu_flutter/data/cache_service.dart';

void main() {
  test(
    'downloads and rewrites an HLS audio playlist for local playback',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final temp = await Directory.systemTemp.createTemp('tingshu_hls_test_');
      final serverTask = server.forEach((request) async {
        final response = request.response;
        switch (request.uri.path) {
          case '/master.m3u8':
            response.write('''#EXTM3U
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",URI="audio.m3u8"
#EXT-X-STREAM-INF:BANDWIDTH=900000,CODECS="avc1.4d401e,mp4a.40.2"
video.m3u8
''');
          case '/audio.m3u8':
            response.write('''#EXTM3U
#EXT-X-TARGETDURATION:10
#EXT-X-KEY:METHOD=AES-128,URI="key.bin"
#EXT-X-MAP:URI="init.mp4"
#EXTINF:10,
segment-1.aac
#EXTINF:10,
segment-2.aac
#EXT-X-ENDLIST
''');
          case '/key.bin':
            response.add(List<int>.generate(16, (index) => index));
          case '/init.mp4':
            response.add(const [0, 0, 0, 20, 0x66, 0x74, 0x79, 0x70]);
          case '/segment-1.aac':
          case '/segment-2.aac':
            response.add(const [0xff, 0xf1, 0x50, 0x80, 1, 2, 3, 4]);
          default:
            response.statusCode = HttpStatus.notFound;
        }
        await response.close();
      });

      try {
        final playlist = await CacheService.instance.downloadHlsForTesting(
          cacheDir: temp,
          playlistUrl:
              'http://${server.address.address}:${server.port}/master.m3u8',
        );
        final content = await playlist.readAsString();
        expect(content, contains('#EXT-X-ENDLIST'));
        expect(content, isNot(contains('http://')));
        expect(content, isNot(contains('segment-1.aac')));
        final files = playlist.parent
            .listSync()
            .whereType<File>()
            .map((file) => file.path)
            .toList();
        expect(files, hasLength(5));
        for (final file in files) {
          expect(await File(file).length(), greaterThan(0));
        }
      } finally {
        await server.close(force: true);
        await serverTask;
        if (temp.existsSync()) await temp.delete(recursive: true);
      }
    },
  );
}
