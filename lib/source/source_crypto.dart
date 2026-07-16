import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

class SourceCrypto {
  const SourceCrypto._();

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
