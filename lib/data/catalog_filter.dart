/// 目录净化:按用户规则屏蔽章节名,让目录更可读。
///
/// 规则文本一行一条:
/// - `/正则/` 形式按正则匹配(大小写不敏感);
/// - 其余按子串匹配。
/// 仅作用于目录**显示层**,播放/缓存顺序不受影响。
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

  /// 章节名是否命中任一规则(应被隐藏)。
  bool blocked(String chapterName) {
    if (_patterns.isEmpty || chapterName.isEmpty) return false;
    for (final pattern in _patterns) {
      if (pattern is RegExp) {
        if (pattern.hasMatch(chapterName)) return true;
      } else if (chapterName.contains('$pattern')) {
        return true;
      }
    }
    return false;
  }

  /// 过滤章节名列表,保留未命中的。
  List<String> allowed(List<String> names) =>
      names.where((name) => !blocked(name)).toList();
}
