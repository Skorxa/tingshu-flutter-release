import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:tingshu_flutter/data/pan_rate_limit.dart';

void main() {
  test('退避随重试次数线性增长并带抖动', () {
    final random = Random(42);
    final first = panBackoffDelayMs(random, attempt: 1);
    final second = panBackoffDelayMs(random, attempt: 2);

    // base 2000 + [0, 3000) 抖动
    expect(first, inExclusiveRange(2000, 5000));
    // 第 2 次 = 4000 + [0, 3000)
    expect(second, inExclusiveRange(4000, 7000));
    expect(second, greaterThan(first));
  });

  test('抖动为 0 时退避恰好等于基线', () {
    final random = Random(1);
    expect(
      panBackoffDelayMs(random, attempt: 3, jitterMs: 0),
      6000,
    );
  });

  test('异常信息包含明细且可读', () {
    final e = PanRateLimitException('百度目录请求被限流\n页码: 2');
    expect(e.toString(), contains('429'));
    expect(e.toString(), contains('页码: 2'));
  });
}
