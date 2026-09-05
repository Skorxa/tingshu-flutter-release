/// 目录净化:按用户规则清理章节名(从名称中剔除匹配文本),让目录更可读。
///
/// 规则文本一行一条:
/// - `/正则/` 形式按正则全局替换;
/// - 其余按子串替换。
/// 例:规则「娱乐春秋」会把「娱乐春秋01问鼎」净化为「01问鼎」。
/// 仅作用于目录**显示层**,播放/缓存顺序不受影响;章节不会被隐藏。
class CatalogFilter {
  CatalogFilter._(this._patterns, this.rulesText);

  final List<Pattern> _patterns;

  /// 生成本实例的规则原文,调用方用于检测规则是否变化。
  final String rulesText;

  static final CatalogFilter empty = CatalogFilter._(const [], '');

  bool get isEmpty => _patterns.isEmpty;

  /// 解析规则文本;非法正则行忽略并记入 [errors]。
  factory CatalogFilter.parse(String rules, {List<String>? errors}) {
    final patterns = <Pattern>[];
    for (var raw in rules.split('\n')) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      if (line.length > 2 && line.startsWith('/') && line.endsWith('/')) {
        try {
          patterns.add(RegExp(line.substring(1, line.length - 1)));
        } catch (e) {
          errors?.add('正则无效: $line');
        }
      } else {
        patterns.add(line);
      }
    }
    return CatalogFilter._(patterns, rules);
  }

  /// 清理章节名:逐条剔除匹配文本;全部剔除后为空则回退原始名。
  String clean(String chapterName) {
    if (_patterns.isEmpty || chapterName.isEmpty) return chapterName;
    var out = chapterName;
    for (final pattern in _patterns) {
      if (pattern is RegExp) {
        out = out.replaceAll(pattern, '');
      } else {
        out = out.replaceAll('$pattern', '');
      }
    }
    final trimmed = out.trim();
    return trimmed.isEmpty ? chapterName : trimmed;
  }
}
