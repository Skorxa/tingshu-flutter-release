import 'package:shared_preferences/shared_preferences.dart';

class SearchHistoryService {
  SearchHistoryService._();

  static final instance = SearchHistoryService._();
  static const _storageKey = 'search_history_keywords';
  static const maxItems = 20;

  List<String>? _items;

  Future<List<String>> load() async {
    final cached = _items;
    if (cached != null) return List.unmodifiable(cached);
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getStringList(_storageKey) ?? const <String>[];
    final normalized = <String>[];
    final seen = <String>{};
    for (final value in stored) {
      final keyword = value.trim();
      if (keyword.isEmpty || !seen.add(keyword.toLowerCase())) continue;
      normalized.add(keyword);
      if (normalized.length >= maxItems) break;
    }
    _items = normalized;
    return List.unmodifiable(normalized);
  }

  Future<List<String>> add(String value) async {
    final keyword = value.trim();
    if (keyword.isEmpty) return load();
    final items = [...await load()]
      ..removeWhere((item) => item.toLowerCase() == keyword.toLowerCase())
      ..insert(0, keyword);
    if (items.length > maxItems) {
      items.removeRange(maxItems, items.length);
    }
    await _save(items);
    return List.unmodifiable(items);
  }

  Future<List<String>> remove(String value) async {
    final items = [...await load()]
      ..removeWhere((item) => item.toLowerCase() == value.trim().toLowerCase());
    await _save(items);
    return List.unmodifiable(items);
  }

  Future<void> clear() async {
    await _save(const []);
  }

  Future<void> _save(List<String> items) async {
    _items = List<String>.from(items);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_storageKey, _items!);
  }
}
