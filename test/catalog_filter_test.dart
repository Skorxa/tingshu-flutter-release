import 'package:flutter_test/flutter_test.dart';
import 'package:tingshu_flutter/data/catalog_filter.dart';

void main() {
  test('子串规则命中章节名', () {
    final filter = CatalogFilter.parse('求订阅\n五星好评');
    expect(filter.blocked('第3章 大战（求订阅）'), isTrue);
    expect(filter.blocked('第4章 收官（求五星好评）'), isTrue);
    expect(filter.blocked('第5章 正常章节'), isFalse);
  });

  test('正则规则按模式匹配', () {
    final filter = CatalogFilter.parse(r'/\(\d+\)/');
    expect(filter.blocked('第1章 开篇(12)'), isTrue);
    expect(filter.blocked('第2章 开篇'), isFalse);
  });

  test('空行与注释行被忽略,空规则不拦截任何内容', () {
    final filter = CatalogFilter.parse('  \n# 注释\n\n');
    expect(filter.isEmpty, isTrue);
    expect(filter.blocked('任意章节'), isFalse);
    expect(filter.allowed(['a', 'b']), ['a', 'b']);
  });

  test('非法正则被忽略并记录错误', () {
    final errors = <String>[];
    final filter = CatalogFilter.parse('/[未闭合/', errors: errors);
    expect(errors, isNotEmpty);
    expect(filter.isEmpty, isTrue);
  });

  test('allowed 过滤命中项并保留其余', () {
    final filter = CatalogFilter.parse('广告');
    expect(filter.allowed(['第1章', '广告片头', '第2章 广告时间', '第3章']), [
      '第1章',
      '第3章',
    ]);
  });
}
