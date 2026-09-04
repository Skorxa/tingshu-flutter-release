import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:pointycastle/export.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../source/source_manager.dart';
import 'log_service.dart';
import 'progress_service.dart';
import 'settings_service.dart';
import 'shelf_service.dart';
import 'webdav_service.dart';

/// 基于 WebDAV 的多设备数据同步。
///
/// - 数据整体打包为 JSON 后用 AES-256-CBC + HMAC-SHA256 加密存储,
///   云端不出现任何明文(音源 Cookie、登录凭据等都在密文内)。
/// - 加密密钥由用户设置的"同步密码"经 PBKDF2 派生,所有设备必须
///   使用相同密码才能互相同步。
/// - 合并规则:
///   - 播放进度:按 (sourceId, bookId) 取 updatedAt 较新的一方;
///   - 书架:并集,同一本书取 addTime 较新的一方;
///   - 设置:整体按变更时间戳新者胜;
///   - 音源(代码/排序/Cookie/订阅):整体按变更时间戳新者胜。
class WebDavSyncService extends ChangeNotifier {
  WebDavSyncService._();
  static final instance = WebDavSyncService._();

  static const _kEnabled = 'sync_auto_enabled';
  static const _kPassword = 'sync_password';
  static const _kLastSyncAt = 'sync_last_sync_at';
  static const _kLastResult = 'sync_last_result';
  static const _kDeviceTag = 'sync_device_tag';

  static const _syncFileName = '/JuTingSync/juting_sync.json';

  /// 自动同步的最小间隔,防止高频操作触发风暴。
  static const _minSyncIntervalMs = 90 * 1000;
  static const _tickInterval = Duration(seconds: 60);

  final Random _random = Random.secure();

  bool _enabled = false;
  String _password = '';
  int _lastSyncAt = 0;
  String _lastResult = '';
  String _deviceTag = '';
  bool _syncing = false;
  int _lastSyncStart = 0;

  // 变更检测基线:与各服务当前时间戳比较,不一致视为有新变更。
  int _settingsStamp = 0;
  int _sourcesStamp = 0;
  int _progressStamp = 0;
  bool _localDirty = false;

  Timer? _timer;
  Timer? _startupTimer;

  bool get enabled => _enabled;
  bool get hasPassword => _password.isNotEmpty;
  int get lastSyncAt => _lastSyncAt;
  String get lastResult => _lastResult;
  bool get syncing => _syncing;
  bool get webDavReady => WebDavService.instance.ready;
  bool get canSync => webDavReady && _password.isNotEmpty;

  String get syncFilePath {
    final root = WebDavService.instance.config.rootPath.trim();
    if (root.isEmpty || root == '/') return _syncFileName;
    final normalized = root.startsWith('/') ? root : '/$root';
    return '$normalized$_syncFileName';
  }

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _enabled = prefs.getBool(_kEnabled) ?? false;
    _password = prefs.getString(_kPassword) ?? '';
    _lastSyncAt = prefs.getInt(_kLastSyncAt) ?? 0;
    _lastResult = prefs.getString(_kLastResult) ?? '';
    _deviceTag = prefs.getString(_kDeviceTag) ?? '';
    if (_deviceTag.isEmpty) {
      _deviceTag = base64Url
          .encode(List<int>.generate(3, (_) => _random.nextInt(256)))
          .replaceAll('=', '')
          .toLowerCase();
      await prefs.setString(_kDeviceTag, _deviceTag);
    }
    _refreshStamps();

    ShelfService.instance.addListener(_onShelfChanged);
    SettingsService.instance.addListener(_onSettingsChanged);

    _timer?.cancel();
    _timer = Timer.periodic(_tickInterval, (_) => _tick());

    if (_enabled && canSync) {
      _startupTimer?.cancel();
      _startupTimer = Timer(const Duration(seconds: 10), () {
        unawaited(syncNow(reason: 'startup'));
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _startupTimer?.cancel();
    ShelfService.instance.removeListener(_onShelfChanged);
    SettingsService.instance.removeListener(_onSettingsChanged);
    super.dispose();
  }

  void _onShelfChanged() {
    if (!ShelfService.instance.applyingSync) _localDirty = true;
  }

  void _onSettingsChanged() {
    if (!SettingsService.instance.isApplyingRemote) _localDirty = true;
  }

  void _refreshStamps() {
    _settingsStamp = SettingsService.instance.settingsChangedAt;
    _sourcesStamp = SourceManager.instance.lastChangedAt;
    _progressStamp = ProgressService.instance.lastSavedAt;
    _localDirty = false;
  }

  bool _hasLocalChanges() {
    return _settingsStamp != SettingsService.instance.settingsChangedAt ||
        _sourcesStamp != SourceManager.instance.lastChangedAt ||
        _progressStamp != ProgressService.instance.lastSavedAt ||
        _localDirty;
  }

  Future<void> _tick() async {
    if (!_enabled || _syncing || !canSync) return;
    if (!_hasLocalChanges()) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    // 只有播放进度变化时降低同步频率,避免连续播放期间频繁整包上传。
    final onlyProgress =
        !_localDirty &&
        _progressStamp != ProgressService.instance.lastSavedAt &&
        _settingsStamp == SettingsService.instance.settingsChangedAt &&
        _sourcesStamp == SourceManager.instance.lastChangedAt;
    final minInterval = onlyProgress ? 5 * 60 * 1000 : _minSyncIntervalMs;
    if (_lastSyncStart > 0 && now - _lastSyncStart < minInterval) {
      return;
    }
    await syncNow(reason: 'auto');
  }

  Future<void> setEnabled(bool value) async {
    _enabled = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kEnabled, value);
    notifyListeners();
    if (value && canSync) {
      unawaited(syncNow(reason: 'enable'));
    }
  }

  Future<void> setPassword(String value) async {
    _password = value.trim();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kPassword, _password);
    notifyListeners();
  }

  /// 合并式同步:拉取云端 → 合并应用 → 推送合并结果。
  Future<void> syncNow({String reason = 'manual'}) async {
    if (_syncing) return;
    if (!webDavReady) {
      _setLastResult('未配置 WebDAV,请先在网盘页配置账号');
      return;
    }
    if (_password.isEmpty) {
      _setLastResult('未设置同步密码');
      return;
    }
    _syncing = true;
    _lastSyncStart = DateTime.now().millisecondsSinceEpoch;
    _localDirty = false;
    notifyListeners();
    try {
      final remoteText = await WebDavService.instance.getString(syncFilePath);
      Map<String, dynamic>? remote;
      if (remoteText != null && remoteText.trim().isNotEmpty) {
        remote = _decryptEnvelope(remoteText);
        final payloadVersion = _asInt(remote['v']);
        if (payloadVersion > 2) {
          throw Exception('云端同步数据版本过新,请先升级 App');
        }
      }
      if (remote != null) {
        await _applyRemote(remote);
      }
      final merged = await _buildPayload();
      if (remote == null || _sortedJson(merged) != _sortedJson(remote)) {
        final envelope = _encryptEnvelope(jsonEncode(merged));
        await WebDavService.instance.putString(syncFilePath, envelope);
        _lastResult = remote == null ? '已上传本地数据' : '已合并并上传';
      } else {
        _lastResult = '云端与本地一致';
      }
      _lastSyncAt = DateTime.now().millisecondsSinceEpoch;
      _refreshStamps();
      await _persistState();
      LogService.instance.info(
        'Sync',
        'WebDAV 同步完成',
        detail: '触发: $reason\n结果: $_lastResult\n路径: $syncFilePath',
      );
    } catch (e, stack) {
      _lastResult = '同步失败: $e';
      LogService.instance.error(
        'Sync',
        'WebDAV 同步失败 ($reason)\n路径: $syncFilePath',
        error: e,
        stack: stack,
      );
    } finally {
      _syncing = false;
      notifyListeners();
    }
  }

  /// 手动备份:用本地数据整体覆盖云端。
  Future<void> uploadSnapshot() async {
    if (_syncing) return;
    if (!webDavReady) {
      _setLastResult('未配置 WebDAV,请先在网盘页配置账号');
      return;
    }
    if (_password.isEmpty) {
      _setLastResult('未设置同步密码');
      return;
    }
    _syncing = true;
    notifyListeners();
    try {
      final payload = await _buildPayload();
      final envelope = _encryptEnvelope(jsonEncode(payload));
      await WebDavService.instance.putString(syncFilePath, envelope);
      _lastSyncAt = DateTime.now().millisecondsSinceEpoch;
      _lastResult = '已上传本地数据';
      _refreshStamps();
      await _persistState();
      LogService.instance.info(
        'Sync',
        'WebDAV 备份上传完成',
        detail: '路径: $syncFilePath',
      );
    } catch (e, stack) {
      _lastResult = '上传失败: $e';
      LogService.instance.error(
        'Sync',
        'WebDAV 备份上传失败',
        error: e,
        stack: stack,
      );
    } finally {
      _syncing = false;
      notifyListeners();
    }
  }

  /// 手动恢复:拉取云端并合并到本地,不上传。
  Future<void> downloadAndMerge() async {
    if (_syncing) return;
    if (!webDavReady) {
      _setLastResult('未配置 WebDAV,请先在网盘页配置账号');
      return;
    }
    if (_password.isEmpty) {
      _setLastResult('未设置同步密码');
      return;
    }
    _syncing = true;
    notifyListeners();
    try {
      final remoteText = await WebDavService.instance.getString(syncFilePath);
      if (remoteText == null || remoteText.trim().isEmpty) {
        _lastResult = '云端还没有同步数据';
        return;
      }
      final remote = _decryptEnvelope(remoteText);
      await _applyRemote(remote);
      _lastSyncAt = DateTime.now().millisecondsSinceEpoch;
      _lastResult = '已应用云端数据';
      _refreshStamps();
      await _persistState();
      LogService.instance.info('Sync', 'WebDAV 云端数据已合并到本地');
    } catch (e, stack) {
      _lastResult = '下载失败: $e';
      LogService.instance.error(
        'Sync',
        'WebDAV 云端数据合并失败',
        error: e,
        stack: stack,
      );
    } finally {
      _syncing = false;
      notifyListeners();
    }
  }

  Future<void> _applyRemote(Map<String, dynamic> remote) async {
    // 设置:远端变更时间较新才整体覆盖。
    final settingsData = remote['settings'] is Map
        ? Map<String, dynamic>.from(remote['settings'] as Map)
        : null;
    final remoteSettingsAt = _asInt(remote['settingsChangedAt']);
    if (settingsData != null &&
        remoteSettingsAt > SettingsService.instance.settingsChangedAt) {
      await SettingsService.instance.applyRemoteSettings(
        settingsData,
        changedAt: remoteSettingsAt,
      );
    }

    // 音源(代码/排序/Cookie/订阅):远端变更时间较新才整体替换。
    final sourcesData = remote['sources'] is Map
        ? Map<String, dynamic>.from(remote['sources'] as Map)
        : null;
    final remoteSourcesAt = _asInt(remote['sourcesChangedAt']);
    if (sourcesData != null &&
        remoteSourcesAt > SourceManager.instance.lastChangedAt) {
      final sources = (sourcesData['sources'] as List? ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      if (sources.isNotEmpty) {
        await SourceManager.instance.restoreFromCloudSync(
          sources: sources,
          activeId: '${sourcesData['activeId'] ?? ''}',
          subscriptionUrl: '${sourcesData['subscriptionUrl'] ?? ''}',
          subscriptions: (sourcesData['subscriptions'] as List? ?? const [])
              .whereType<Map>()
              .map((e) => Map<String, dynamic>.from(e))
              .toList(),
          changedAt: remoteSourcesAt,
        );
      }
    }

    // 书架:并集,addTime 新者胜。
    final shelfRows = (remote['shelf'] as List? ?? const [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    final shelfApplied = await ShelfService.instance.mergeFromSync(shelfRows);

    // 播放进度:updatedAt 新者胜。
    final progressRows = (remote['progress'] as List? ?? const [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    final progressApplied = await ProgressService.instance.mergeFromSync(
      progressRows,
    );

    LogService.instance.info(
      'Sync',
      '云端数据合并完成',
      detail:
          '书架更新: $shelfApplied 条\n进度更新: $progressApplied 条\n'
          '设置: ${settingsData != null && remoteSettingsAt > 0 ? '按时间戳比较' : '跳过'}\n'
          '音源: ${sourcesData != null && remoteSourcesAt > 0 ? '按时间戳比较' : '跳过'}',
    );
  }

  Future<Map<String, dynamic>> _buildPayload() async {
    final shelf = await ShelfService.instance.list();
    final progress = await ProgressService.instance.listForSync();
    return {
      'v': 2,
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
      'deviceTag': _deviceTag,
      'settingsChangedAt': SettingsService.instance.settingsChangedAt,
      'sourcesChangedAt': SourceManager.instance.lastChangedAt,
      'settings': SettingsService.instance.exportForSync(),
      'sources': SourceManager.instance.exportForSync(),
      'shelf': shelf
          .map(
            (book) => {
              'sourceId': book.sourceId,
              'bookId': book.bookId,
              'title': book.title,
              'cover': book.cover,
              'author': book.author,
              'sourceName': book.sourceName,
              'addTime': book.addTime,
            },
          )
          .toList(),
      'progress': progress
          .map(
            (row) => {
              'sourceId': '${row['sourceId'] ?? ''}',
              'bookId': '${row['bookId'] ?? ''}',
              'bookTitle': '${row['bookTitle'] ?? ''}',
              'cover': '${row['cover'] ?? ''}',
              'chapterId': '${row['chapterId'] ?? ''}',
              'chapterName': '${row['chapterName'] ?? ''}',
              'chapterIdx': (row['chapterIdx'] as num?)?.toInt() ?? 0,
              'currentTime': (row['currentTime'] as num?)?.toDouble() ?? 0.0,
              'duration': (row['duration'] as num?)?.toDouble() ?? 0.0,
              'updatedAt': (row['updatedAt'] as num?)?.toInt() ?? 0,
            },
          )
          .toList(),
    };
  }

  Future<void> _persistState() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kLastSyncAt, _lastSyncAt);
    await prefs.setString(_kLastResult, _lastResult);
  }

  void _setLastResult(String value) {
    _lastResult = value;
    notifyListeners();
  }

  // ── 加密 ──────────────────────────────────────────────────────────

  String _encryptEnvelope(String plain) =>
      SyncCrypto.encrypt(plain, _password);

  Map<String, dynamic> _decryptEnvelope(String envelope) =>
      SyncCrypto.decrypt(envelope, _password);

  /// 规范化 JSON(键排序),用于比较合并结果与云端数据是否一致。
  String _sortedJson(dynamic value) {
    if (value is Map) {
      final keys = value.keys.map((k) => '$k').toList()..sort();
      return '{${keys.map((k) => '${jsonEncode(k)}:${_sortedJson(value[k])}').join(',')}}';
    }
    if (value is List) {
      return '[${value.map(_sortedJson).join(',')}]';
    }
    return jsonEncode(value);
  }

  int _asInt(dynamic value) {
    if (value is num) return value.toInt();
    return int.tryParse('$value') ?? 0;
  }
}

/// 同步数据加密:PBKDF2 派生密钥 + AES-256-CBC(PKCS7) + HMAC-SHA256 完整性校验。
/// 密文格式(JSON):{app, v, salt, iv, ct, mac},均为 base64。
class SyncCrypto {
  SyncCrypto._();

  static const envelopeTag = 'juting-sync';
  static const _pbkdf2Iterations = 50000;

  static Uint8List _randomBytes(int length) {
    final random = Random.secure();
    return Uint8List.fromList(
      List<int>.generate(length, (_) => random.nextInt(256)),
    );
  }

  /// PBKDF2-HMAC-SHA256 派生 64 字节:前 32 字节 AES 密钥,后 32 字节 HMAC 密钥。
  static Uint8List deriveKeys(String password, Uint8List salt) {
    final derivator = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))
      ..init(Pbkdf2Parameters(salt, _pbkdf2Iterations, 64));
    return derivator.process(Uint8List.fromList(utf8.encode(password)));
  }

  static Uint8List _hmacSha256(Uint8List key, List<Uint8List> parts) {
    final mac = HMac(SHA256Digest(), 64)..init(KeyParameter(key));
    for (final part in parts) {
      mac.update(part, 0, part.length);
    }
    final out = Uint8List(mac.macSize);
    mac.doFinal(out, 0);
    return out;
  }

  static PaddedBlockCipherImpl _cipher(Uint8List key, Uint8List iv, bool forEncryption) {
    return PaddedBlockCipherImpl(
      PKCS7Padding(),
      CBCBlockCipher(AESEngine()),
    )..init(
        forEncryption,
        PaddedBlockCipherParameters<ParametersWithIV<KeyParameter>, Null>(
          ParametersWithIV<KeyParameter>(KeyParameter(key), iv),
          null,
        ),
      );
  }

  static bool constantTimeEquals(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  static String encrypt(String plain, String password) {
    final salt = _randomBytes(16);
    final iv = _randomBytes(16);
    final keys = deriveKeys(password, salt);
    final aesKey = Uint8List.sublistView(keys, 0, 32);
    final macKey = Uint8List.sublistView(keys, 32, 64);
    final cipher = _cipher(aesKey, iv, true);
    final cipherText = cipher.process(Uint8List.fromList(utf8.encode(plain)));
    final mac = _hmacSha256(macKey, [salt, iv, cipherText]);
    return jsonEncode({
      'app': envelopeTag,
      'v': 1,
      'salt': base64Encode(salt),
      'iv': base64Encode(iv),
      'ct': base64Encode(cipherText),
      'mac': base64Encode(mac),
    });
  }

  static Map<String, dynamic> decrypt(String envelope, String password) {
    dynamic raw;
    try {
      raw = jsonDecode(envelope);
    } catch (_) {
      throw Exception('同步文件不是有效的加密数据');
    }
    if (raw is! Map || raw['app'] != envelopeTag) {
      throw Exception('同步文件格式无效');
    }
    final salt = base64Decode('${raw['salt']}');
    final iv = base64Decode('${raw['iv']}');
    final cipherText = base64Decode('${raw['ct']}');
    final mac = base64Decode('${raw['mac']}');
    if (salt.isEmpty || iv.length != 16 || cipherText.isEmpty) {
      throw Exception('同步文件数据不完整');
    }
    final keys = deriveKeys(password, salt);
    final aesKey = Uint8List.sublistView(keys, 0, 32);
    final macKey = Uint8List.sublistView(keys, 32, 64);
    final expected = _hmacSha256(macKey, [salt, iv, cipherText]);
    if (!constantTimeEquals(expected, mac)) {
      throw Exception('同步密码错误或数据已损坏');
    }
    final cipher = _cipher(aesKey, iv, false);
    final plain = utf8.decode(cipher.process(cipherText));
    final data = jsonDecode(plain);
    if (data is! Map) throw Exception('同步数据格式无效');
    return Map<String, dynamic>.from(data);
  }
}
