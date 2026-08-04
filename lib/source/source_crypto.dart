import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

class SourceCrypto {
  const SourceCrypto._();

  static const int _uint32Mask = 0xffffffff;

  static String aesCbcDecrypt({
    required String cipherText,
    required String key,
    required String iv,
    String inputEncoding = 'base64',
    String keyEncoding = 'base64',
    String ivEncoding = 'base64',
  }) {
    final cipherBytes = decodeBytes(cipherText, inputEncoding);
    final keyBytes = decodeBytes(key, keyEncoding);
    final ivBytes = decodeBytes(iv, ivEncoding);
    if (![16, 24, 32].contains(keyBytes.length)) {
      throw const FormatException('AES key 长度必须是 16/24/32 字节');
    }
    if (ivBytes.length != 16) {
      throw const FormatException('AES-CBC IV 长度必须是 16 字节');
    }
    if (cipherBytes.isEmpty || cipherBytes.length % 16 != 0) {
      throw const FormatException('AES 密文长度必须是 16 的倍数');
    }

    final cipher = PaddedBlockCipherImpl(
      PKCS7Padding(),
      CBCBlockCipher(AESEngine()),
    );
    cipher.init(
      false,
      PaddedBlockCipherParameters<ParametersWithIV<KeyParameter>, Null>(
        ParametersWithIV<KeyParameter>(KeyParameter(keyBytes), ivBytes),
        null,
      ),
    );
    return utf8.decode(cipher.process(cipherBytes));
  }

  static String xChaCha20Poly1305Decrypt({
    required String cipherText,
    required String key,
    required String nonce,
    String inputEncoding = 'base64',
    String keyEncoding = 'base64',
    String nonceEncoding = 'base64',
  }) {
    final cipherBytes = decodeBytes(cipherText, inputEncoding);
    final keyBytes = decodeBytes(key, keyEncoding);
    final nonceBytes = decodeBytes(nonce, nonceEncoding);
    if (keyBytes.length != 32) {
      throw const FormatException('XChaCha20 key 长度必须是 32 字节');
    }
    if (nonceBytes.length != 24) {
      throw const FormatException('XChaCha20 nonce 长度必须是 24 字节');
    }
    if (cipherBytes.length < 16) {
      throw const FormatException('XChaCha20-Poly1305 密文缺少认证标签');
    }

    final subKey = _hChaCha20(
      keyBytes,
      Uint8List.sublistView(nonceBytes, 0, 16),
    );
    final ietfNonce = Uint8List(12)..setRange(4, 12, nonceBytes, 16);
    final cipher = ChaCha20Poly1305(ChaCha7539Engine(), Poly1305());
    cipher.init(
      false,
      AEADParameters(KeyParameter(subKey), 128, ietfNonce, Uint8List(0)),
    );
    final output = Uint8List(cipher.getOutputSize(cipherBytes.length));
    var outputLength = cipher.processBytes(
      cipherBytes,
      0,
      cipherBytes.length,
      output,
      0,
    );
    outputLength += cipher.doFinal(output, outputLength);
    return utf8.decode(Uint8List.sublistView(output, 0, outputLength));
  }

  static Uint8List _hChaCha20(Uint8List key, Uint8List nonce) {
    final keyData = ByteData.sublistView(key);
    final nonceData = ByteData.sublistView(nonce);
    final state = Uint32List.fromList([
      0x61707865,
      0x3320646e,
      0x79622d32,
      0x6b206574,
      for (var i = 0; i < 8; i++) keyData.getUint32(i * 4, Endian.little),
      for (var i = 0; i < 4; i++) nonceData.getUint32(i * 4, Endian.little),
    ]);

    for (var i = 0; i < 10; i++) {
      _quarterRound(state, 0, 4, 8, 12);
      _quarterRound(state, 1, 5, 9, 13);
      _quarterRound(state, 2, 6, 10, 14);
      _quarterRound(state, 3, 7, 11, 15);
      _quarterRound(state, 0, 5, 10, 15);
      _quarterRound(state, 1, 6, 11, 12);
      _quarterRound(state, 2, 7, 8, 13);
      _quarterRound(state, 3, 4, 9, 14);
    }

    final output = Uint8List(32);
    final outputData = ByteData.sublistView(output);
    const outputWords = [0, 1, 2, 3, 12, 13, 14, 15];
    for (var i = 0; i < outputWords.length; i++) {
      outputData.setUint32(i * 4, state[outputWords[i]], Endian.little);
    }
    return output;
  }

  static void _quarterRound(Uint32List state, int a, int b, int c, int d) {
    state[a] = (state[a] + state[b]) & _uint32Mask;
    state[d] = _rotateLeft32(state[d] ^ state[a], 16);
    state[c] = (state[c] + state[d]) & _uint32Mask;
    state[b] = _rotateLeft32(state[b] ^ state[c], 12);
    state[a] = (state[a] + state[b]) & _uint32Mask;
    state[d] = _rotateLeft32(state[d] ^ state[a], 8);
    state[c] = (state[c] + state[d]) & _uint32Mask;
    state[b] = _rotateLeft32(state[b] ^ state[c], 7);
  }

  static int _rotateLeft32(int value, int bits) {
    return ((value << bits) | (value >> (32 - bits))) & _uint32Mask;
  }

  static Uint8List decodeBytes(String value, String encoding) {
    switch (encoding.toLowerCase()) {
      case 'utf8':
      case 'text':
        return Uint8List.fromList(utf8.encode(value));
      case 'hex':
        final normalized = value.replaceAll(RegExp(r'\s+'), '');
        if (normalized.length.isOdd) {
          throw const FormatException('hex 长度必须是偶数');
        }
        return Uint8List.fromList([
          for (var i = 0; i < normalized.length; i += 2)
            int.parse(normalized.substring(i, i + 2), radix: 16),
        ]);
      case 'base64':
        return base64Decode(value);
      default:
        throw ArgumentError('不支持的编码: $encoding');
    }
  }
}
