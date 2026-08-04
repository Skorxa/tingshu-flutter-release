import 'package:flutter_test/flutter_test.dart';
import 'package:tingshu_flutter/data/cache_service.dart';

void main() {
  test('automatic cache window includes the current chapter', () {
    final window = CacheService.computeCacheWindow(
      currentIndex: 9,
      chapterCount: 100,
      maxChapters: 3,
    );

    expect(window.start, 9);
    expect(window.end, 12);
  });

  test('automatic cache window is clamped at the catalog end', () {
    final window = CacheService.computeCacheWindow(
      currentIndex: 99,
      chapterCount: 100,
      maxChapters: 20,
    );

    expect(window.start, 99);
    expect(window.end, 100);
  });
}
