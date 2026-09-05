import 'dart:math';

/// 网盘限流(HTTP 429)异常:调用方捕获后按退避策略等待重试。
class PanRateLimitException implements Exception {
  final String detail;

  PanRateLimitException(this.detail);

  @override
  String toString() => '网盘限流(429): $detail';
}

/// 第 [attempt] 次重试前的退避毫秒数:线性增长并带随机抖动。
/// 纯函数,便于单元测试;抖动避免多设备同时重试形成同步风暴。
int panBackoffDelayMs(
  Random random, {
  int attempt = 1,
  int baseMs = 2000,
  int jitterMs = 3000,
}) {
  final jitter = jitterMs <= 0 ? 0 : random.nextInt(jitterMs);
  return baseMs * attempt + jitter;
}
