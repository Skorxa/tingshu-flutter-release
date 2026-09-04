import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_update_service.dart';
import 'log_service.dart';

enum CloudAuthState {
  checking,
  unconfigured,
  activationRequired,
  authorized,
  authorizedOffline,
  disabled,
  error,
  bypassed,
}

class CloudLicenseInfo {
  final String userId;
  final String displayName;
  final String status;
  final int? expiresAt;
  final int maxDevices;

  const CloudLicenseInfo({
    required this.userId,
    required this.displayName,
    required this.status,
    required this.expiresAt,
    required this.maxDevices,
  });

  factory CloudLicenseInfo.fromMap(Map map) => CloudLicenseInfo(
    userId: '${map['id'] ?? ''}',
    displayName: '${map['displayName'] ?? ''}',
    status: '${map['status'] ?? ''}',
    expiresAt: _intOrNull(map['expiresAt']),
    maxDevices: _intOrNull(map['maxDevices']) ?? 1,
  );

  static int? _intOrNull(dynamic value) {
    if (value == null) return null;
    return value is num ? value.toInt() : int.tryParse('$value');
  }
}

class DeviceIdentity {
  final String deviceId;
  final String publicKey;
  final String deviceName;
  final String platform;

  const DeviceIdentity({
    required this.deviceId,
    required this.publicKey,
    required this.deviceName,
    required this.platform,
  });
}

class CloudAuthException implements Exception {
  final int statusCode;
  final String code;
  final String message;

  const CloudAuthException(this.statusCode, this.code, this.message);

  @override
  String toString() => message;
}

class CloudAuthService extends ChangeNotifier {
  CloudAuthService._();
  static final instance = CloudAuthService._();

  static const _rawBaseUrl = String.fromEnvironment('CLOUD_CONTROL_URL');
  static const _required = bool.fromEnvironment(
    'CLOUD_CONTROL_REQUIRED',
    defaultValue: true,
  );
  static const _channel = MethodChannel('tingshu/device_identity');
  static const _accessKey = 'cloud_auth_access_token';
  static const _accessExpiryKey = 'cloud_auth_access_expiry';
  static const _refreshKey = 'cloud_auth_refresh_token';
  static const _refreshExpiryKey = 'cloud_auth_refresh_expiry';
  static const _licenseKey = 'cloud_auth_license';
  static const _lastVerifiedKey = 'cloud_auth_last_verified';
  static const _offlineGraceKey = 'cloud_auth_offline_grace';
  static const _inviteCodeKey = 'cloud_auth_invite_code';

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 12),
      receiveTimeout: const Duration(seconds: 20),
      sendTimeout: const Duration(seconds: 20),
      validateStatus: (_) => true,
    ),
  );
  final Random _random = Random.secure();

  CloudAuthState _state = CloudAuthState.checking;
  CloudLicenseInfo? _license;
  DeviceIdentity? _device;
  String _accessToken = '';
  int _accessExpiresAt = 0;
  String _refreshToken = '';
  int _refreshExpiresAt = 0;
  int _lastVerifiedAt = 0;
  int _offlineGraceSeconds = 48 * 60 * 60;
  String _storedInviteCode = '';
  String _error = '';
  String _appVersion = '';
  bool _ready = false;
  bool _reactivating = false;
  Future<void>? _refreshing;
  Timer? _timer;

  CloudAuthState get state => _state;
  CloudLicenseInfo? get license => _license;
  DeviceIdentity? get device => _device;
  String get error => _error;
  int get lastVerifiedAt => _lastVerifiedAt;
  int get offlineGraceSeconds => _offlineGraceSeconds;
  bool get isRequired => _required;
  bool get isConfigured => _baseUri != null;
  bool get canUseApp => const {
    CloudAuthState.authorized,
    CloudAuthState.authorizedOffline,
    CloudAuthState.bypassed,
  }.contains(_state);

  Uri? get _baseUri {
    final value = _rawBaseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    final uri = Uri.tryParse(value);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) return null;
    if (uri.scheme == 'https') return uri;
    if (!kReleaseMode &&
        uri.scheme == 'http' &&
        const {'localhost', '127.0.0.1', '10.0.2.2'}.contains(uri.host)) {
      return uri;
    }
    return null;
  }

  String get privateSubscriptionUrl =>
      _baseUri?.resolve('/api/subscription').toString() ?? '';

  String get stateLabel => switch (_state) {
    CloudAuthState.checking => '验证中',
    CloudAuthState.unconfigured => '未配置',
    CloudAuthState.activationRequired => '未激活',
    CloudAuthState.authorized => '已授权',
    CloudAuthState.authorizedOffline => '离线授权',
    CloudAuthState.disabled => '已停用',
    CloudAuthState.error => '验证失败',
    CloudAuthState.bypassed => '开发模式',
  };

  Future<void> init() async {
    if (_ready) return;
    _ready = true;
    if (!isConfigured) {
      _setState(
        _required ? CloudAuthState.unconfigured : CloudAuthState.bypassed,
      );
      return;
    }
    try {
      _device = await _loadDeviceIdentity();
      _appVersion = await _readAppVersion();
      await _loadStoredAuthorization();
      if (_accessToken.isEmpty && _refreshToken.isEmpty) {
        // 设备曾用邀请码激活过时,先尝试静默重新激活(服务端对同设备
        // 同邀请码不消耗使用次数),失败才进入未激活状态。
        if (!await _tryAutoReactivate()) {
          _setState(CloudAuthState.activationRequired);
        }
      } else {
        await verify(allowOffline: true);
      }
      _timer = Timer.periodic(const Duration(minutes: 10), (_) {
        unawaited(verify(allowOffline: true, quiet: true));
      });
    } catch (e, stack) {
      LogService.instance.error(
        'CloudAuth',
        '授权服务初始化失败',
        error: e,
        stack: stack,
      );
      _setError(_messageOf(e));
    }
  }

  Future<void> activate(String inviteCode, {String displayName = ''}) async {
    final code = inviteCode.trim();
    if (code.isEmpty) {
      throw const CloudAuthException(400, 'empty_invite', '请输入邀请码');
    }
    final device = await _requireDevice();
    try {
      final response = await _send(
        'POST',
        '/api/auth/activate',
        body: {
          'inviteCode': code,
          'displayName': displayName.trim(),
          'deviceId': device.deviceId,
          'publicKey': device.publicKey,
          'deviceName': device.deviceName,
          'platform': device.platform,
          'appVersion': _appVersion,
        },
      );
      await _acceptAuthorization(response);
      // 记住邀请码,掉激活时可静默重新激活。
      // 服务端对同设备 + 同邀请码的重激活不消耗邀请码使用次数。
      _storedInviteCode = code;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_inviteCodeKey, code);
      LogService.instance.info(
        'CloudAuth',
        '设备授权成功',
        detail: '设备: ${device.deviceId.substring(0, 12)}',
      );
    } catch (e, stack) {
      await _handleAuthorizationFailure(e, stack: stack, activation: true);
      rethrow;
    }
  }

  Future<void> verify({bool allowOffline = true, bool quiet = false}) async {
    if (!isConfigured || _state == CloudAuthState.bypassed) return;
    if (_accessToken.isEmpty && _refreshToken.isEmpty) {
      _setState(CloudAuthState.activationRequired);
      return;
    }
    // 已授权时保持当前界面可用，后台完成复验；只有首次验证或错误重试
    // 才显示阻塞式的“验证中”状态。
    if (!quiet && !canUseApp) _setState(CloudAuthState.checking);
    try {
      await _ensureAccessToken();
      final response = await _send(
        'GET',
        '/api/auth/status',
        accessToken: _accessToken,
      );
      await _acceptLicense(response);
    } on CloudAuthException catch (e, stack) {
      if (e.statusCode == 401 && _refreshToken.isNotEmpty) {
        try {
          await _refresh();
          final response = await _send(
            'GET',
            '/api/auth/status',
            accessToken: _accessToken,
          );
          await _acceptLicense(response);
          return;
        } catch (refreshError, refreshStack) {
          await _handleAuthorizationFailure(
            refreshError,
            stack: refreshStack,
            allowOffline: allowOffline,
          );
          return;
        }
      }
      await _handleAuthorizationFailure(e, stack: stack, allowOffline: allowOffline);
    } catch (e, stack) {
      await _handleAuthorizationFailure(e, stack: stack, allowOffline: allowOffline);
    }
  }

  Future<Map<String, String>> headersForRequest(
    String method,
    Uri uri, {
    String bodyText = '',
  }) async {
    if (!isManagedUri(uri)) return const {};
    if (!canUseApp || _state == CloudAuthState.authorizedOffline) {
      throw CloudAuthException(
        401,
        'not_authorized',
        _error.isEmpty ? '设备尚未授权' : _error,
      );
    }
    await _ensureAccessToken();
    final headers = await _signedHeaders(method, uri, bodyText);
    headers['Authorization'] = 'Bearer $_accessToken';
    headers['X-App-Version'] = _appVersion;
    return headers;
  }

  Future<void> handleProtectedFailure(
    int statusCode,
    dynamic responseBody,
  ) async {
    if (statusCode != 401 && statusCode != 403) return;
    final error = _errorFromResponse(responseBody);
    final failure = CloudAuthException(statusCode, error.$1, error.$2);
    if (statusCode == 403) {
      await _handleAuthorizationFailure(failure);
      return;
    }
    // 401 可能只是访问令牌刚好过期。走完整复验流程可先刷新令牌，
    // 只有会话确实被撤销时才清除本地授权。
    await verify(allowOffline: false, quiet: true);
  }

  bool isManagedUri(Uri uri) {
    final base = _baseUri;
    if (base == null) return false;
    return uri.scheme == base.scheme &&
        uri.host == base.host &&
        uri.port == base.port;
  }

  Future<Map<String, dynamic>> fetchCloudConfig() async {
    await _ensureAccessToken();
    final response = await _send(
      'GET',
      '/api/config',
      accessToken: _accessToken,
    );
    final data = response['data'];
    return data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{};
  }

  Future<void> retry() => verify(allowOffline: true);

  Future<DeviceIdentity> _requireDevice() async {
    return _device ??= await _loadDeviceIdentity();
  }

  Future<DeviceIdentity> _loadDeviceIdentity() async {
    final result = await _channel.invokeMapMethod<String, dynamic>(
      'getIdentity',
    );
    if (result == null) throw Exception('无法获取设备凭据');
    final device = DeviceIdentity(
      deviceId: '${result['deviceId'] ?? ''}'.trim(),
      publicKey: '${result['publicKey'] ?? ''}'.trim(),
      deviceName: '${result['deviceName'] ?? 'Android 设备'}'.trim(),
      platform: '${result['platform'] ?? 'android'}'.trim(),
    );
    if (device.deviceId.isEmpty || device.publicKey.isEmpty) {
      throw Exception('设备凭据不完整');
    }
    return device;
  }

  Future<String> _readAppVersion() async {
    try {
      final version = await AppUpdateService.instance.currentVersion();
      return '${version.versionName}+${version.versionCode}';
    } catch (_) {
      return '';
    }
  }

  Future<void> _loadStoredAuthorization() async {
    final prefs = await SharedPreferences.getInstance();
    _accessToken = prefs.getString(_accessKey) ?? '';
    _accessExpiresAt = prefs.getInt(_accessExpiryKey) ?? 0;
    _refreshToken = prefs.getString(_refreshKey) ?? '';
    _refreshExpiresAt = prefs.getInt(_refreshExpiryKey) ?? 0;
    _lastVerifiedAt = prefs.getInt(_lastVerifiedKey) ?? 0;
    _offlineGraceSeconds = prefs.getInt(_offlineGraceKey) ?? 48 * 60 * 60;
    _storedInviteCode = prefs.getString(_inviteCodeKey) ?? '';
    final rawLicense = prefs.getString(_licenseKey);
    if (rawLicense != null && rawLicense.isNotEmpty) {
      try {
        final decoded = jsonDecode(rawLicense);
        if (decoded is Map) _license = CloudLicenseInfo.fromMap(decoded);
      } catch (_) {}
    }
  }

  Future<void> _saveAuthorization() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_accessKey, _accessToken);
    await prefs.setInt(_accessExpiryKey, _accessExpiresAt);
    await prefs.setString(_refreshKey, _refreshToken);
    await prefs.setInt(_refreshExpiryKey, _refreshExpiresAt);
    await prefs.setInt(_lastVerifiedKey, _lastVerifiedAt);
    await prefs.setInt(_offlineGraceKey, _offlineGraceSeconds);
    if (_license != null) {
      await prefs.setString(
        _licenseKey,
        jsonEncode({
          'id': _license!.userId,
          'displayName': _license!.displayName,
          'status': _license!.status,
          'expiresAt': _license!.expiresAt,
          'maxDevices': _license!.maxDevices,
        }),
      );
    }
  }

  Future<void> _clearAuthorization() async {
    _accessToken = '';
    _accessExpiresAt = 0;
    _refreshToken = '';
    _refreshExpiresAt = 0;
    _license = null;
    _lastVerifiedAt = 0;
    final prefs = await SharedPreferences.getInstance();
    await Future.wait([
      prefs.remove(_accessKey),
      prefs.remove(_accessExpiryKey),
      prefs.remove(_refreshKey),
      prefs.remove(_refreshExpiryKey),
      prefs.remove(_licenseKey),
      prefs.remove(_lastVerifiedKey),
    ]);
  }

  Future<void> _ensureAccessToken() async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    if (_accessToken.isNotEmpty && _accessExpiresAt > now + 60) return;
    if (_refreshToken.isEmpty) {
      throw const CloudAuthException(401, 'refresh_expired', '设备授权已失效');
    }
    // 不用设备本地时钟预判 refresh token 是否过期:设备时钟偏快时会
    // 误杀仍有效的会话。过期与否交给服务端权威判定。
    await _refresh();
  }

  Future<void> _refresh() async {
    final existing = _refreshing;
    if (existing != null) return existing;
    final operation = _performRefresh();
    _refreshing = operation;
    try {
      await operation;
    } finally {
      if (identical(_refreshing, operation)) _refreshing = null;
    }
  }

  Future<void> _performRefresh() async {
    final response = await _send(
      'POST',
      '/api/auth/refresh',
      body: {'refreshToken': _refreshToken},
    );
    await _acceptAuthorization(response);
  }

  Future<Map<String, dynamic>> _send(
    String method,
    String path, {
    Map<String, dynamic>? body,
    String accessToken = '',
  }) async {
    final base = _baseUri;
    if (base == null) {
      throw const CloudAuthException(503, 'not_configured', '授权服务未配置');
    }
    final uri = base.resolve(path);
    final bodyText = body == null ? '' : jsonEncode(body);
    final headers = await _signedHeaders(method, uri, bodyText);
    headers['Accept'] = 'application/json';
    headers['X-App-Version'] = _appVersion;
    if (body != null) headers['Content-Type'] = 'application/json';
    if (accessToken.isNotEmpty) {
      headers['Authorization'] = 'Bearer $accessToken';
    }
    Response<dynamic> response;
    try {
      response = await _dio.requestUri<dynamic>(
        uri,
        data: body == null ? null : bodyText,
        options: Options(method: method, headers: headers),
      );
    } on DioException catch (e) {
      throw CloudAuthException(0, 'network_error', e.message ?? '网络连接失败');
    }
    final payload = _decodeResponse(response.data);
    final status = response.statusCode ?? 0;
    if (status < 200 || status >= 300) {
      final error = payload['error'];
      final errorMap = error is Map ? error : const {};
      throw CloudAuthException(
        status,
        '${errorMap['code'] ?? 'request_failed'}',
        '${errorMap['message'] ?? '授权请求失败（$status）'}',
      );
    }
    return payload;
  }

  Map<String, dynamic> _decodeResponse(dynamic raw) {
    dynamic value = raw;
    if (raw is String) {
      try {
        value = jsonDecode(raw);
      } catch (_) {
        value = <String, dynamic>{};
      }
    }
    return value is Map
        ? Map<String, dynamic>.from(value)
        : <String, dynamic>{};
  }

  (String, String) _errorFromResponse(dynamic raw) {
    final payload = _decodeResponse(raw);
    final error = payload['error'];
    if (error is Map) {
      return (
        '${error['code'] ?? 'authorization_failed'}',
        '${error['message'] ?? '设备授权已失效'}',
      );
    }
    return ('authorization_failed', '设备授权已失效');
  }

  Future<Map<String, String>> _signedHeaders(
    String method,
    Uri uri,
    String bodyText,
  ) async {
    final device = await _requireDevice();
    final timestamp = DateTime.now().millisecondsSinceEpoch.toString();
    final nonceBytes = List<int>.generate(18, (_) => _random.nextInt(256));
    final nonce = base64UrlEncode(nonceBytes).replaceAll('=', '');
    final bodyHash = sha256.convert(utf8.encode(bodyText)).toString();
    final path = '${uri.path}${uri.hasQuery ? '?${uri.query}' : ''}';
    final canonical = [
      method.toUpperCase(),
      path,
      timestamp,
      nonce,
      bodyHash,
    ].join('\n');
    final signature = await _channel.invokeMethod<String>('sign', {
      'payload': canonical,
    });
    if (signature == null || signature.isEmpty) {
      throw Exception('设备签名失败');
    }
    return {
      'X-Device-Id': device.deviceId,
      'X-Device-Timestamp': timestamp,
      'X-Device-Nonce': nonce,
      'X-Device-Signature': signature,
    };
  }

  Future<void> _acceptAuthorization(Map<String, dynamic> response) async {
    final data = response['data'];
    if (data is! Map) throw Exception('授权响应格式无效');
    _accessToken = '${data['accessToken'] ?? ''}';
    _accessExpiresAt = _asInt(data['accessExpiresAt']);
    _refreshToken = '${data['refreshToken'] ?? ''}';
    _refreshExpiresAt = _asInt(data['refreshExpiresAt']);
    if (_accessToken.isEmpty || _refreshToken.isEmpty) {
      throw Exception('授权响应缺少令牌');
    }
    await _acceptLicenseMap(data);
  }

  Future<void> _acceptLicense(Map<String, dynamic> response) async {
    final data = response['data'];
    if (data is! Map) throw Exception('授权状态格式无效');
    await _acceptLicenseMap(data);
  }

  Future<void> _acceptLicenseMap(Map data) async {
    final user = data['user'];
    if (user is Map) _license = CloudLicenseInfo.fromMap(user);
    _offlineGraceSeconds = _asInt(
      data['offlineGraceSeconds'],
      fallback: _offlineGraceSeconds,
    );
    _lastVerifiedAt = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    _error = '';
    await _saveAuthorization();
    _setState(CloudAuthState.authorized);
  }

  Future<void> _handleAuthorizationFailure(
    Object error, {
    StackTrace? stack,
    bool allowOffline = false,
    bool activation = false,
  }) async {
    final message = _messageOf(error);
    final authError = error is CloudAuthException ? error : null;
    LogService.instance.error(
      'CloudAuth',
      activation ? '设备激活失败' : '授权验证失败',
      error: error,
      stack: stack,
    );
    if (activation) {
      _error = message;
      _setState(CloudAuthState.activationRequired, force: true);
      return;
    }
    if (authError?.statusCode == 403) {
      _error = message;
      _setState(CloudAuthState.disabled);
      return;
    }
    if (authError?.statusCode == 401) {
      // 刷新凭据被拒:先尝试用记住的邀请码静默重激活,覆盖“服务端已轮换
      // refresh token、但轮换响应在网络中丢失,本地仍持旧凭据”的场景。
      // 恢复失败才清空本地授权并要求手动激活。
      final recovered = await _tryAutoReactivate();
      if (!recovered) {
        await _clearAuthorization();
        _error = message;
        _setState(CloudAuthState.activationRequired);
      }
      return;
    }
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final verifiedAge = now - _lastVerifiedAt;
    final licenseStillValid =
        _license?.status == 'active' &&
        (_license?.expiresAt == null || (_license!.expiresAt! > now));
    if (allowOffline &&
        licenseStillValid &&
        _lastVerifiedAt > 0 &&
        verifiedAge >= -300 &&
        verifiedAge <= _offlineGraceSeconds) {
      _error = message;
      _setState(CloudAuthState.authorizedOffline);
      return;
    }
    _setError(message);
  }

  /// 使用记住的邀请码静默重新激活。服务端对同设备 + 同邀请码的重激活
  /// 不消耗邀请码使用次数,因此该恢复路径对用户完全无感。
  Future<bool> _tryAutoReactivate() async {
    final code = _storedInviteCode;
    if (code.isEmpty || _reactivating || !isConfigured) return false;
    _reactivating = true;
    try {
      await activate(code);
      LogService.instance.info('CloudAuth', '授权已自动恢复');
      return true;
    } catch (e) {
      LogService.instance.warning(
        'CloudAuth',
        '授权自动恢复失败',
        detail: '$e',
      );
      return false;
    } finally {
      _reactivating = false;
    }
  }

  int _asInt(dynamic value, {int fallback = 0}) {
    if (value is num) return value.toInt();
    return int.tryParse('$value') ?? fallback;
  }

  String _messageOf(Object error) => error
      .toString()
      .replaceFirst('CloudAuthException: ', '')
      .replaceFirst('Exception: ', '');

  void _setError(String message) {
    _error = message;
    _setState(CloudAuthState.error, force: true);
  }

  void _setState(CloudAuthState value, {bool force = false}) {
    final changed = _state != value;
    _state = value;
    if (changed || force) notifyListeners();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
