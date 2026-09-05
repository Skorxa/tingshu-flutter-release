import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

class SourceCrypto {
  const SourceCrypto._();

  static const int _uint32Mask = 0xffffffff;

  // ── AES-GCM 加密：返回 IV(12B) || 密文 || TAG(16B) 拼接后的编码字符串 ──
  static String aesGcmEncrypt({
    required String plainText,
    required String key,
    String iv = '',
    String plainEncoding = 'utf8',
    String keyEncoding = 'hex',
    String ivEncoding = 'hex',
    String outputEncoding = 'hex',
  }) {
    final plainBytes = decodeBytes(plainText, plainEncoding);
    final keyBytes = decodeBytes(key, keyEncoding);
    if (![16, 24, 32].contains(keyBytes.length)) {
      throw const FormatException('AES-GCM key 长度必须是 16/24/32 字节');
    }
    final Uint8List ivBytes;
    if (iv.isEmpty) {
      final random = Random.secure();
      ivBytes = Uint8List(12);
      for (var i = 0; i < ivBytes.length; i++) {
        ivBytes[i] = random.nextInt(256);
      }
    } else {
      ivBytes = decodeBytes(iv, ivEncoding);
      if (ivBytes.length != 12) {
        throw const FormatException('AES-GCM IV 长度必须是 12 字节');
      }
    }

    final cipher = GCMBlockCipher(AESEngine());
    cipher.init(
      true,
      AEADParameters(KeyParameter(keyBytes), 128, ivBytes, Uint8List(0)),
    );
    final out = Uint8List(cipher.getOutputSize(plainBytes.length));
    var n = cipher.processBytes(plainBytes, 0, plainBytes.length, out, 0);
    n += cipher.doFinal(out, n);

    final result = Uint8List(ivBytes.length + n)
      ..setRange(0, ivBytes.length, ivBytes)
      ..setRange(ivBytes.length, ivBytes.length + n, Uint8List.sublistView(out, 0, n));
    return encodeBytes(result, outputEncoding);
  }

  // ── SM4-ECB 加密（PKCS7 填充），密钥 16 字节 ──
  static String sm4EcbEncrypt({
    required String plainText,
    required String key,
    String plainEncoding = 'utf8',
    String keyEncoding = 'hex',
    String outputEncoding = 'base64',
  }) {
    final plainBytes = decodeBytes(plainText, plainEncoding);
    final keyBytes = decodeBytes(key, keyEncoding);
    if (keyBytes.length != 16) {
      throw const FormatException('SM4 key 长度必须是 16 字节');
    }

    final rk = _sm4KeyExpand(keyBytes);
    final pad = 16 - (plainBytes.length % 16);
    final padded = Uint8List(plainBytes.length + pad)
      ..setRange(0, plainBytes.length, plainBytes)
      ..fillRange(plainBytes.length, plainBytes.length + pad, pad);
    final out = Uint8List(padded.length);
    final block = Uint8List(16);
    for (var o = 0; o < padded.length; o += 16) {
      block.setRange(0, 16, padded, o);
      final enc = _sm4EncryptBlock(rk, block);
      out.setRange(o, o + 16, enc);
    }
    return encodeBytes(out, outputEncoding);
  }

  // ── SHA-256 摘要 ──
  static String sha256Hex({required String text, String inputEncoding = 'utf8'}) {
    final data = decodeBytes(text, inputEncoding);
    return encodeBytes(SHA256Digest().process(data), 'hex');
  }

  // ── MD5 摘要 ──
  static String md5Hex({required String text, String inputEncoding = 'utf8'}) {
    final data = decodeBytes(text, inputEncoding);
    return encodeBytes(MD5Digest().process(data), 'hex');
  }

  static const List<int> _sm4Sbox = [
    0xd6, 0x90, 0xe9, 0xfe, 0xcc, 0xe1, 0x3d, 0xb7, 0x16, 0xb6, 0x14, 0xc2, 0x28, 0xfb, 0x2c, 0x05,
    0x2b, 0x67, 0x9a, 0x76, 0x2a, 0xbe, 0x04, 0xc3, 0xaa, 0x44, 0x13, 0x26, 0x49, 0x86, 0x06, 0x99,
    0x9c, 0x42, 0x50, 0xf4, 0x91, 0xef, 0x98, 0x7a, 0x33, 0x54, 0x0b, 0x43, 0xed, 0xcf, 0xac, 0x62,
    0xe4, 0xb3, 0x1c, 0xa9, 0xc9, 0x08, 0xe8, 0x95, 0x80, 0xdf, 0x94, 0xfa, 0x75, 0x8f, 0x3f, 0xa6,
    0x47, 0x07, 0xa7, 0xfc, 0xf3, 0x73, 0x17, 0xba, 0x83, 0x59, 0x3c, 0x19, 0xe6, 0x85, 0x4f, 0xa8,
    0x68, 0x6b, 0x81, 0xb2, 0x71, 0x64, 0xda, 0x8b, 0xf8, 0xeb, 0x0f, 0x4b, 0x70, 0x56, 0x9d, 0x35,
    0x1e, 0x24, 0x0e, 0x5e, 0x63, 0x58, 0xd1, 0xa2, 0x25, 0x22, 0x7c, 0x3b, 0x01, 0x21, 0x78, 0x87,
    0xd4, 0x00, 0x46, 0x57, 0x9f, 0xd3, 0x27, 0x52, 0x4c, 0x36, 0x02, 0xe7, 0xa0, 0xc4, 0xc8, 0x9e,
    0xea, 0xbf, 0x8a, 0xd2, 0x40, 0xc7, 0x38, 0xb5, 0xa3, 0xf7, 0xf2, 0xce, 0xf9, 0x61, 0x15, 0xa1,
    0xe0, 0xae, 0x5d, 0xa4, 0x9b, 0x34, 0x1a, 0x55, 0xad, 0x93, 0x32, 0x30, 0xf5, 0x8c, 0xb1, 0xe3,
    0x1d, 0xf6, 0xe2, 0x2e, 0x82, 0x66, 0xca, 0x60, 0xc0, 0x29, 0x23, 0xab, 0x0d, 0x53, 0x4e, 0x6f,
    0xd5, 0xdb, 0x37, 0x45, 0xde, 0xfd, 0x8e, 0x2f, 0x03, 0xff, 0x6a, 0x72, 0x6d, 0x6c, 0x5b, 0x51,
    0x8d, 0x1b, 0xaf, 0x92, 0xbb, 0xdd, 0xbc, 0x7f, 0x11, 0xd9, 0x5c, 0x41, 0x1f, 0x10, 0x5a, 0xd8,
    0x0a, 0xc1, 0x31, 0x88, 0xa5, 0xcd, 0x7b, 0xbd, 0x2d, 0x74, 0xd0, 0x12, 0xb8, 0xe5, 0xb4, 0xb0,
    0x89, 0x69, 0x97, 0x4a, 0x0c, 0x96, 0x77, 0x7e, 0x65, 0xb9, 0xf1, 0x09, 0xc5, 0x6e, 0xc6, 0x84,
    0x18, 0xf0, 0x7d, 0xec, 0x3a, 0xdc, 0x4d, 0x20, 0x79, 0xee, 0x5f, 0x3e, 0xd7, 0xcb, 0x39, 0x48,
  ];

  static const List<int> _sm4Fk = [
    0xa3b1bac6, 0x56aa3350, 0x677d9197, 0xb27022dc,
  ];

  static const List<int> _sm4Ck = [
    0x00070e15, 0x1c232a31, 0x383f464d, 0x545b6269,
    0x70777e85, 0x8c939aa1, 0xa8afb6bd, 0xc4cbd2d9,
    0xe0e7eef5, 0xfc030a11, 0x181f262d, 0x343b4249,
    0x50575e65, 0x6c737a81, 0x888f969d, 0xa4abb2b9,
    0xc0c7ced5, 0xdce3eaf1, 0xf8ff060d, 0x141b2229,
    0x30373e45, 0x4c535a61, 0x686f767d, 0x848b9299,
    0xa0a7aeb5, 0xbcc3cad1, 0xd8dfe6ed, 0xf4fb0209,
    0x10171e25, 0x2c333a41, 0x484f565d, 0x646b7279,
  ];

  static int _sm4Tau(int w) {
    return (_sm4Sbox[(w >>> 24) & 0xff] << 24 |
            _sm4Sbox[(w >>> 16) & 0xff] << 16 |
            _sm4Sbox[(w >>> 8) & 0xff] << 8 |
            _sm4Sbox[w & 0xff]) &
        _uint32Mask;
  }

  static int _sm4T(int x) {
    final b = _sm4Tau(x);
    return (b ^
            _rotateLeft32(b, 2) ^
            _rotateLeft32(b, 10) ^
            _rotateLeft32(b, 18) ^
            _rotateLeft32(b, 24)) &
        _uint32Mask;
  }

  static int _sm4T2(int x) {
    final b = _sm4Tau(x);
    return (b ^ _rotateLeft32(b, 13) ^ _rotateLeft32(b, 23)) & _uint32Mask;
  }

  static List<int> _sm4KeyExpand(Uint8List key) {
    var w = _sm4Word(key, 0) ^ _sm4Fk[0];
    var x = _sm4Word(key, 4) ^ _sm4Fk[1];
    var y = _sm4Word(key, 8) ^ _sm4Fk[2];
    var z = _sm4Word(key, 12) ^ _sm4Fk[3];
    final rk = List<int>.filled(32, 0);
    for (var r = 0; r < 32; r++) {
      final v = (w ^ _sm4T2((x ^ y ^ z ^ _sm4Ck[r]) & _uint32Mask)) & _uint32Mask;
      rk[r] = v;
      w = x;
      x = y;
      y = z;
      z = v;
    }
    return rk;
  }

  static Uint8List _sm4EncryptBlock(List<int> rk, Uint8List block) {
    var a = _sm4Word(block, 0);
    var b = _sm4Word(block, 4);
    var c = _sm4Word(block, 8);
    var d = _sm4Word(block, 12);
    for (var r = 0; r < 32; r++) {
      final v = (a ^ _sm4T((b ^ c ^ d ^ rk[r]) & _uint32Mask)) & _uint32Mask;
      a = b;
      b = c;
      c = d;
      d = v;
    }
    final out = Uint8List(16);
    _writeWord(out, 0, d);
    _writeWord(out, 4, c);
    _writeWord(out, 8, b);
    _writeWord(out, 12, a);
    return out;
  }

  static int _sm4Word(Uint8List bytes, int offset) {
    return (bytes[offset] << 24 |
            bytes[offset + 1] << 16 |
            bytes[offset + 2] << 8 |
            bytes[offset + 3]) &
        _uint32Mask;
  }

  static void _writeWord(Uint8List bytes, int offset, int word) {
    bytes[offset] = (word >>> 24) & 0xff;
    bytes[offset + 1] = (word >>> 16) & 0xff;
    bytes[offset + 2] = (word >>> 8) & 0xff;
    bytes[offset + 3] = word & 0xff;
  }

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

  static String encodeBytes(Uint8List bytes, String encoding) {
    switch (encoding.toLowerCase()) {
      case 'utf8':
      case 'text':
        return utf8.decode(bytes);
      case 'hex':
        return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      case 'base64':
        return base64Encode(bytes);
      default:
        throw ArgumentError('不支持的编码: $encoding');
    }
  }
}
