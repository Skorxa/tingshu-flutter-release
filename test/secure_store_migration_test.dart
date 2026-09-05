import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tingshu_flutter/data/secure_store.dart';

/// 内存假后端:可注入写失败,模拟 Keystore 异常。
class _FakeBackend implements SecureBackend {
  final Map<String, String> values = {};
  bool failWrites = false;

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    if (failWrites) {
      throw StateError('keystore unavailable');
    }
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const prefsKey = 'legacy_password';
  const secureKey = 'sec.legacy_password';
  late _FakeBackend backend;

  setUp(() async {
    backend = _FakeBackend();
    SecureStore.instance.setBackendForTest(backend);
    SharedPreferences.setMockInitialValues({});
  });

  test('旧明文值被迁移到加密存储并删除旧键', () async {
    SharedPreferences.setMockInitialValues({prefsKey: 'secret123'});

    final store = SecureStore.instance;
    final value = await store.readMigrated(prefsKey, secureKey);

    expect(value, 'secret123');
    expect(backend.values[secureKey], 'secret123');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(prefsKey), isNull);
  });

  test('迁移幂等:重复调用不重写,已迁移数据权威', () async {
    SharedPreferences.setMockInitialValues({prefsKey: 'secret123'});
    final store = SecureStore.instance;

    await store.readMigrated(prefsKey, secureKey);
    // 模拟二次启动:旧键已删,加密存储有值
    SharedPreferences.setMockInitialValues({});
    final value = await store.readMigrated(prefsKey, secureKey);

    expect(value, 'secret123');
    expect(backend.values[secureKey], 'secret123');
  });

  test('加密存储已有值时以加密值为权威并清理残留旧键', () async {
    backend.values[secureKey] = 'new-from-secure';
    SharedPreferences.setMockInitialValues({prefsKey: 'old-plaintext'});

    final value = await SecureStore.instance.readMigrated(prefsKey, secureKey);

    expect(value, 'new-from-secure');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(prefsKey), isNull);
  });

  test('加密写入失败时保留明文旧值兜底,下次可重试', () async {
    backend.failWrites = true;
    SharedPreferences.setMockInitialValues({prefsKey: 'secret123'});

    final value = await SecureStore.instance.readMigrated(prefsKey, secureKey);

    expect(value, 'secret123');
    expect(backend.values.containsKey(secureKey), isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(prefsKey), 'secret123');
  });

  test('两处都为空时返回 null', () async {
    final value = await SecureStore.instance.readMigrated(prefsKey, secureKey);
    expect(value, isNull);
  });
}
