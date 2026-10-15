import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tingshu_flutter/data/sync_payload.dart';

void main() {
  group('SyncPayload.compareKey', () {
    test('易变字段(updatedAt/deviceTag)不参与比较', () {
      final a = <String, dynamic>{
        'v': 2,
        'updatedAt': 1700000000000,
        'deviceTag': 'aaaa',
        'settings': {'darkMode': true},
        'progress': [
          {'bookId': 'b1', 'updatedAt': 1},
        ],
      };
      final b = <String, dynamic>{
        'v': 2,
        'updatedAt': 1799999999999,
        'deviceTag': 'zzzz',
        'settings': {'darkMode': true},
        'progress': [
          {'bookId': 'b1', 'updatedAt': 1},
        ],
      };

      // 旧实现把 updatedAt/deviceTag 一起比较,导致每一轮同步都必然整包 PUT。
      expect(SyncPayload.compareKey(a), SyncPayload.compareKey(b));
    });

    test('嵌套键顺序不影响比较结果', () {
      final a = <String, dynamic>{
        'v': 2,
        'settings': {'darkMode': true, 'autoCache': false},
        'progress': [
          {'bookId': 'b1', 'chapterId': 'c1'},
        ],
      };
      final b = <String, dynamic>{
        'settings': {'autoCache': false, 'darkMode': true},
        'progress': [
          {'chapterId': 'c1', 'bookId': 'b1'},
        ],
        'v': 2,
      };

      expect(SyncPayload.compareKey(a), SyncPayload.compareKey(b));
    });

    test('真实内容变化会被识别', () {
      final a = <String, dynamic>{
        'v': 2,
        'progress': [
          {'bookId': 'b1', 'currentTime': 10.0},
        ],
      };
      final b = <String, dynamic>{
        'v': 2,
        'progress': [
          {'bookId': 'b1', 'currentTime': 11.0},
        ],
      };
      final c = <String, dynamic>{
        'v': 2,
        'progress': [
          {'bookId': 'b1', 'currentTime': 10.0},
          {'bookId': 'b2', 'currentTime': 1.0},
        ],
      };

      expect(SyncPayload.compareKey(a), isNot(SyncPayload.compareKey(b)));
      expect(SyncPayload.compareKey(a), isNot(SyncPayload.compareKey(c)));
    });

    test('不修改入参', () {
      final payload = <String, dynamic>{
        'v': 2,
        'updatedAt': 1700000000000,
        'deviceTag': 'aaaa',
      };
      SyncPayload.compareKey(payload);
      expect(payload.containsKey('updatedAt'), isTrue);
      expect(payload.containsKey('deviceTag'), isTrue);
      expect(payload.length, 3);
    });
  });

  group('SyncPayload.progressRow', () {
    test('默认不带封面,但保留续播标识字段', () {
      final row = SyncPayload.progressRow({
        'sourceId': 'src',
        'bookId': 'b1',
        'bookTitle': '某本书',
        'cover': 'https://cdn.example.com/cover.jpg?x-signature=abcdef',
        'chapterId': 'https://cdn.example.com/a.mp3|Referer=xxx',
        'chapterName': '第 1 集',
        'chapterIdx': 3,
        'currentTime': 12.5,
        'duration': 1800.0,
        'updatedAt': 1700000000000,
      });

      expect(row.containsKey('cover'), isFalse);
      expect(row['sourceId'], 'src');
      expect(row['bookId'], 'b1');
      expect(row['chapterIdx'], 3);
      expect(row['currentTime'], 12.5);
      expect(row['updatedAt'], 1700000000000);
      // chapterId 可能内嵌直链/Referer,任何截断都会破坏跨设备续播。
      expect(row['chapterId'], 'https://cdn.example.com/a.mp3|Referer=xxx');
    });

    test('includeCover 为 true 时保留封面', () {
      final row = SyncPayload.progressRow({
        'bookId': 'b1',
        'cover': 'https://cdn.example.com/cover.jpg',
      }, includeCover: true);
      expect(row['cover'], 'https://cdn.example.com/cover.jpg');
    });

    test('超长标题被截断,缺失字段回退为安全默认值', () {
      final longTitle = '标' * (SyncPayload.maxTextLength + 50);
      final row = SyncPayload.progressRow({
        'bookId': 'b1',
        'bookTitle': longTitle,
        'chapterIdx': '7',
      });

      expect((row['bookTitle'] as String).length, SyncPayload.maxTextLength);
      expect(row['sourceId'], '');
      expect(row['chapterId'], '');
      expect(row['chapterIdx'], 7);
      expect(row['currentTime'], 0.0);
      expect(row['updatedAt'], 0);
    });

    test('progressRows 批量瘦身:只有前 coverKeep 条带封面', () {
      final source = [
        for (var i = 0; i < 5; i++)
          {'bookId': 'b$i', 'cover': 'https://cdn/$i.jpg', 'updatedAt': i},
      ];
      final rows = SyncPayload.progressRows(source, coverKeep: 2);

      expect(rows.length, 5);
      expect(rows[0].containsKey('cover'), isTrue);
      expect(rows[1].containsKey('cover'), isTrue);
      expect(rows[2].containsKey('cover'), isFalse);
      expect(rows[4].containsKey('cover'), isFalse);
      expect(rows.map((row) => row['bookId']), ['b0', 'b1', 'b2', 'b3', 'b4']);
    });
  });

  group('SyncPayload.progressRowForInsert', () {
    test('对端未带封面时保留本地封面', () {
      final row = SyncPayload.progressRowForInsert(
        incoming: {
          'sourceId': 'src',
          'bookId': 'b1',
          'chapterId': 'c9',
          'updatedAt': 20,
        },
        local: {
          'sourceId': 'src',
          'bookId': 'b1',
          'cover': 'https://local/cover.jpg',
          'bookTitle': '本地标题',
        },
      );

      expect(row['cover'], 'https://local/cover.jpg');
      expect(row['bookTitle'], '本地标题');
      expect(row['chapterId'], 'c9');
      expect(row['updatedAt'], 20);
    });

    test('对端带封面时以对端为准', () {
      final row = SyncPayload.progressRowForInsert(
        incoming: {
          'sourceId': 'src',
          'bookId': 'b1',
          'cover': 'https://remote/cover.jpg',
          'chapterId': 'c1',
          'updatedAt': 30,
        },
        local: {'cover': 'https://local/cover.jpg', 'chapterId': 'c0'},
      );

      expect(row['cover'], 'https://remote/cover.jpg');
      expect(row['chapterId'], 'c1');
    });

    test('无本地记录且对端缺字段时给出可落库的默认值', () {
      final row = SyncPayload.progressRowForInsert(incoming: {'bookId': 'b1'});

      expect(row['cover'], '');
      expect(row['sourceId'], '');
      expect(row['chapterIdx'], 0);
      expect(row['currentTime'], 0.0);
      expect(row['duration'], 0.0);
      // 必须能直接喂给 sqflite(值类型可序列化)
      expect(() => jsonEncode(row), returnsNormally);
    });
  });

  group('SyncPayload.shelfRow', () {
    test('默认不带封面并截断超长字段', () {
      final row = SyncPayload.shelfRow(
        sourceId: 'src',
        bookId: 'b1',
        title: '书' * (SyncPayload.maxTextLength + 10),
        author: '作者',
        sourceName: '音源名',
        addTime: 1700000000000,
      );

      expect(row.containsKey('cover'), isFalse);
      expect((row['title'] as String).length, SyncPayload.maxTextLength);
      expect(row['author'], '作者');
      expect(row['sourceName'], '音源名');
      expect(row['addTime'], 1700000000000);
    });

    test('传入封面时保留', () {
      final row = SyncPayload.shelfRow(
        sourceId: 'src',
        bookId: 'b1',
        title: '书',
        author: '作者',
        sourceName: '音源名',
        addTime: 1,
        cover: 'https://cdn/cover.jpg',
      );
      expect(row['cover'], 'https://cdn/cover.jpg');
    });
  });

  group('SyncPayload 退避', () {
    test('识别限流/超额状态码', () {
      expect(SyncPayload.isQuotaStatus(429), isTrue);
      expect(SyncPayload.isQuotaStatus(507), isTrue);
      expect(SyncPayload.isQuotaStatus(503), isTrue);
      expect(SyncPayload.isQuotaStatus(401), isFalse);
      expect(SyncPayload.isQuotaStatus(404), isFalse);
      expect(SyncPayload.isQuotaStatus(null), isFalse);
    });

    test('退避时长单调不减且有上限', () {
      expect(SyncPayload.retryDelayMs(0), 0);
      final first = SyncPayload.retryDelayMs(1);
      expect(first, SyncPayload.baseRetryMs);
      var previous = first;
      for (var failures = 2; failures <= 20; failures++) {
        final current = SyncPayload.retryDelayMs(failures);
        expect(current, greaterThanOrEqualTo(previous));
        expect(current, lessThanOrEqualTo(SyncPayload.maxRetryMs));
        previous = current;
      }
      expect(previous, SyncPayload.maxRetryMs);
    });

    test('限流/超额时起步退避更长', () {
      expect(
        SyncPayload.retryDelayMs(1, rateLimited: true),
        SyncPayload.rateLimitedRetryMs,
      );
      expect(
        SyncPayload.retryDelayMs(1, rateLimited: true),
        greaterThan(SyncPayload.retryDelayMs(1)),
      );
    });
  });
}
