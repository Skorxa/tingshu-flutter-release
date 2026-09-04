import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tingshu_flutter/data/webdav_sync_service.dart';

void main() {
  group('SyncCrypto', () {
    test('encrypt/decrypt round trip restores the payload', () {
      const payload =
          '{"v":2,"updatedAt":1700000000000,"deviceTag":"ab12",'
          '"settings":{"darkMode":true},"sources":{"sources":[{"id":"s1"}]},'
          '"shelf":[],"progress":[]}';
      final envelope = SyncCrypto.encrypt(payload, '同步密码123');

      // 密文必须是 JSON 信封且不含明文片段
      expect(envelope.contains('updatedAt'), isFalse);
      expect(envelope.contains('darkMode'), isFalse);
      final map = jsonDecode(envelope) as Map;
      expect(map['app'], 'juting-sync');
      expect(map['salt'], isNotEmpty);
      expect(map['iv'], isNotEmpty);
      expect(map['ct'], isNotEmpty);
      expect(map['mac'], isNotEmpty);

      final decrypted = SyncCrypto.decrypt(envelope, '同步密码123');
      expect(jsonEncode(decrypted), payload);
    });

    test('decrypt with the wrong password throws', () {
      final envelope = SyncCrypto.encrypt('{"v":2}', 'correct-password');
      expect(
        () => SyncCrypto.decrypt(envelope, 'wrong-password'),
        throwsA(isA<Exception>()),
      );
    });

    test('decrypt rejects tampered ciphertext', () {
      final envelope = SyncCrypto.encrypt('{"v":2}', 'pw');
      final map = jsonDecode(envelope) as Map<String, dynamic>;
      // 破坏密文最后一字节(base64 末位替换)
      final ct = map['ct'] as String;
      map['ct'] =
          ct.substring(0, ct.length - 2) +
          (ct.endsWith('A') ? 'B' : 'A') +
          ct.substring(ct.length - 1);
      expect(
        () => SyncCrypto.decrypt(jsonEncode(map), 'pw'),
        throwsA(isA<Exception>()),
      );
    });

    test('decrypt rejects non-envelope data', () {
      expect(
        () => SyncCrypto.decrypt('plain text not json', 'pw'),
        throwsA(isA<Exception>()),
      );
      expect(
        () => SyncCrypto.decrypt('{"app":"other"}', 'pw'),
        throwsA(isA<Exception>()),
      );
    });

    test('same payload encrypts to different envelopes (random salt/iv)', () {
      const payload = '{"v":2}';
      final a = SyncCrypto.encrypt(payload, 'pw');
      final b = SyncCrypto.encrypt(payload, 'pw');
      expect(a, isNot(b));
      expect(SyncCrypto.decrypt(a, 'pw')['v'], 2);
      expect(SyncCrypto.decrypt(b, 'pw')['v'], 2);
    });
  });

  group('payload comparison', () {
    // _sortedJson 是私有方法;通过行为等价的自有实现验证比较语义一致。
    String sortedJson(dynamic value) {
      if (value is Map) {
        final keys = value.keys.map((k) => '$k').toList()..sort();
        return '{${keys.map((k) => '${jsonEncode(k)}:${sortedJson(value[k])}').join(',')}}';
      }
      if (value is List) {
        return '[${value.map(sortedJson).join(',')}]';
      }
      return jsonEncode(value);
    }

    test('key order does not affect equality', () {
      final a = jsonDecode('{"a":1,"b":{"x":true,"y":[1,2]},"c":null}');
      final b = jsonDecode('{"c":null,"b":{"y":[1,2],"x":true},"a":1}');
      expect(sortedJson(a), sortedJson(b));
    });

    test('different values are not equal', () {
      final a = jsonDecode('{"progress":[{"id":"p1","t":5.0}]}');
      final b = jsonDecode('{"progress":[{"id":"p1","t":6.0}]}');
      expect(sortedJson(a), isNot(sortedJson(b)));
    });
  });
}
