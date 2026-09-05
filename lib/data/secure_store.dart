import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'log_service.dart';

/// 可替换的加密存储后端,便于单元测试注入假实现。
abstract class SecureBackend {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// Android 走 EncryptedSharedPreferences(Keystore 主密钥加密)。
class FlutterSecureBackend implements SecureBackend {
  FlutterSecureBackend({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(encryptedSharedPreferences: true),
            );

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// 凭据加密存储:Cookie、密码、Token、邀请码等敏感字段统一经由 [SecureStore]
/// 读写,落到 Android Keystore 加密的存储中;非敏感轻量配置仍留在
/// SharedPreferences。
///
/// 旧版本把凭据明文存在 SharedPreferences,升级后由 [readMigrated] 在各服务
/// init 时完成一次性搬迁:迁移成功才删除旧键,失败时保留旧值兜底并在下次启动
/// 重试,保证任何情况下凭据不丢。
class SecureStore {
  SecureStore._();

  static final SecureStore instance = SecureStore._();

  SecureBackend _backend = FlutterSecureBackend();
  final Map<String, String?> _cache = {};

  @visibleForTesting
  void setBackendForTest(SecureBackend backend) {
    _backend = backend;
    _cache.clear();
  }

  /// 读取加密值;读取失败按"未设置"处理并记日志,由调用方决定回退策略。
  Future<String?> read(String key) async {
    if (_cache.containsKey(key)) return _cache[key];
    try {
      final value = await _backend.read(key);
      _cache[key] = value;
      return value;
    } catch (e, stack) {
      LogService.instance.error(
        'SecureStore',
        '读取加密存储失败: $key',
        error: e,
        stack: stack,
      );
      return null;
    }
  }

  /// 写入加密值;失败时记日志并向上抛出,让保存动作显式失败而不是静默丢凭据。
  Future<void> write(String key, String value) async {
    try {
      await _backend.write(key, value);
      _cache[key] = value;
    } catch (e, stack) {
      LogService.instance.error(
        'SecureStore',
        '写入加密存储失败: $key',
        error: e,
        stack: stack,
      );
      rethrow;
    }
  }

  Future<void> delete(String key) async {
    _cache.remove(key);
    try {
      await _backend.delete(key);
    } catch (e) {
      LogService.instance.warning(
        'SecureStore',
        '删除加密存储失败: $key',
        detail: '$e',
      );
    }
  }

  /// 读取曾明文存于 SharedPreferences 的凭据,并把旧值一次性搬进加密存储。
  ///
  /// - 加密存储已有值:视为已迁移,清理残留旧键,返回加密值(权威数据);
  /// - 加密存储为空且旧键有值:写入加密存储,成功后删除旧键并返回旧值;
  ///   写入失败则保留旧键并继续返回旧值,下次启动重试;
  /// - 两处都为空:返回 null。
  Future<String?> readMigrated(String prefsKey, String secureKey) async {
    final prefs = await SharedPreferences.getInstance();
    final legacy = prefs.getString(prefsKey);
    final secure = await read(secureKey);
    if (secure != null && secure.isNotEmpty) {
      if (legacy != null) {
        unawaited(prefs.remove(prefsKey));
      }
      return secure;
    }
    if (legacy != null && legacy.isNotEmpty) {
      try {
        await _backend.write(secureKey, legacy);
        _cache[secureKey] = legacy;
        await prefs.remove(prefsKey);
        LogService.instance.info(
          'SecureStore',
          '凭据已迁移到加密存储',
          detail: prefsKey,
        );
        return legacy;
      } catch (e) {
        LogService.instance.error(
          'SecureStore',
          '迁移失败,暂用明文旧值: $prefsKey',
          error: e,
        );
        return legacy;
      }
    }
    return null;
  }
}
