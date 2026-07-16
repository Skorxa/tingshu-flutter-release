import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tingshu_flutter/data/search_history_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('search history persists, deduplicates and removes entries', () async {
    SharedPreferences.setMockInitialValues({});
    final service = SearchHistoryService.instance;
    await service.clear();

    await service.add('剑来');
    await service.add(' 雪中悍刀行 ');
    final history = await service.add('剑来');

    expect(history, ['剑来', '雪中悍刀行']);
    expect(await service.remove('剑来'), ['雪中悍刀行']);

    await service.clear();
    expect(await service.load(), isEmpty);
  });
}
