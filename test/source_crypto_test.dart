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

  test('XChaCha20-Poly1305 decrypts a fixed vector', () {
    final result = SourceCrypto.xChaCha20Poly1305Decrypt(
      cipherText:
          '753c21a714176ce850df33d5296763a35431b6598b7307fa98172b3781eb194c43f1aefe',
      key: '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f',
      nonce: '202122232425262728292a2b2c2d2e2f3031323334353637',
      inputEncoding: 'hex',
      keyEncoding: 'hex',
      nonceEncoding: 'hex',
    );

    expect(result, 'hello xchacha bridge');
  });
}
