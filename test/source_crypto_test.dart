import 'package:flutter_test/flutter_test.dart';
import 'package:tingshu_flutter/source/source_crypto.dart';

void main() {
  test('AES-CBC PKCS7 decrypts a fixed vector', () {
    final result = SourceCrypto.aesCbcDecrypt(
      cipherText: 'wsGxcYVlWiWb4Z2mAm5U88wzN2N9z4BKBIx288MVQws=',
      key: '0123456789abcdef',
      iv: 'abcdef9876543210',
      keyEncoding: 'utf8',
      ivEncoding: 'utf8',
    );

    expect(result, 'hello aes bridge');
  });
}
