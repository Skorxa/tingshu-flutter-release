import 'package:flutter_test/flutter_test.dart';
import 'package:tingshu_flutter/data/catalog_filter.dart';

void main() {
  test('子串规则从章节名中剔除匹配文本', () {
    final filter = CatalogFilter.parse('娱乐春秋');
    expect(filter.clean('娱乐春秋01问鼎'), '01问鼎');
    expect(filter.clean('娱乐春秋02有点意思'), '02有点意思');
    expect(filter.clean('第3章 正常章节'), '第3章 正常章节');
  });

  test('正则规则按模式全局剔除', () {
    final filter = CatalogFilter.parse(r'/（.*?）/');
    expect(filter.clean('第1章 开篇（求订阅）'), '第1章 开篇');
    expect(filter.clean('第2章 收官（求订阅）（求五星）'), '第2章 收官');
  });

  test('多条规则依次剔除', () {
    final filter = CatalogFilter.parse('娱乐春秋\n（求订阅）');
    expect(filter.clean('娱乐春秋01问鼎（求订阅）'), '01问鼎');
  });

  test('剔除后为空回退原始章节名', () {
    final filter = CatalogFilter.parse('娱乐春秋');
    expect(filter.clean('娱乐春秋'), '娱乐春秋');
  });

  test('空行与注释行被忽略,空规则原样返回', () {
    final filter = CatalogFilter.parse('  \n# 注释\n\n');
    expect(filter.isEmpty, isTrue);
    expect(filter.clean('任意章节'), '任意章节');
  });

  test('非法正则被忽略并记录错误', () {
    final errors = <String>[];
    final filter = CatalogFilter.parse('/[未闭合/', errors: errors);
    expect(errors, isNotEmpty);
    expect(filter.isEmpty, isTrue);
  });
}
