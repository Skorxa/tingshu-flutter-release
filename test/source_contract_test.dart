import 'package:flutter_test/flutter_test.dart';
import 'package:tingshu_flutter/source/source_contract.dart';

void main() {
  test(
    'search pagination stays loadable when hasMore conflicts with maxPage',
    () {
      final result = SourceContract.parseSearchResult(
        {
          'list': [
            {'bookId': '1', 'title': '第一本'},
            {'bookId': '1', 'title': '重复项'},
          ],
          'page': 2,
          'maxPage': 1,
          'hasMore': true,
        },
        sourceId: 'test',
        sourceName: '测试源',
      );

      expect(result.list, hasLength(1));
      expect(result.page, 2);
      expect(result.maxPage, 3);
      expect(result.hasMore, isTrue);
    },
  );

  test('rejects a source protocol newer than the app supports', () {
    expect(
      () => SourceContract.requireSupportedApiVersion(
        SourceContract.version + 1,
        sourceId: 'future',
        sourceName: '未来源',
      ),
      throwsA(isA<Exception>()),
    );
  });
}
