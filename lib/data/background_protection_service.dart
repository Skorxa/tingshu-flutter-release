import 'package:flutter/services.dart';

class BackgroundProtectionStatus {
  const BackgroundProtectionStatus({
    required this.sdkInt,
    required this.notificationPermissionGranted,
    required this.notificationsEnabled,
    required this.batteryOptimizationExempt,
  });

  final int sdkInt;
  final bool notificationPermissionGranted;
  final bool notificationsEnabled;
  final bool batteryOptimizationExempt;

  factory BackgroundProtectionStatus.fromMap(Map<dynamic, dynamic> map) {
    return BackgroundProtectionStatus(
      sdkInt: (map['sdkInt'] as num?)?.toInt() ?? 0,
      notificationPermissionGranted:
          map['notificationPermissionGranted'] == true,
      notificationsEnabled: map['notificationsEnabled'] == true,
      batteryOptimizationExempt: map['batteryOptimizationExempt'] == true,
    );
  }
}

class BackgroundProtectionService {
  BackgroundProtectionService._();

  static const _channel = MethodChannel('tingshu/background_protection');

  static Future<BackgroundProtectionStatus> getStatus() async {
    final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
      'getStatus',
    );
    return BackgroundProtectionStatus.fromMap(result ?? const {});
  }

  static Future<void> requestNotificationPermission() async {
    await _channel.invokeMethod<bool>('requestNotificationPermission');
  }

  static Future<void> requestBatteryOptimizationExemption() async {
    await _channel.invokeMethod<bool>('requestBatteryOptimizationExemption');
  }

  static Future<void> openNotificationSettings() async {
    await _channel.invokeMethod<bool>('openNotificationSettings');
  }

  static Future<void> openAppSettings() async {
    await _channel.invokeMethod<bool>('openAppSettings');
  }
}
