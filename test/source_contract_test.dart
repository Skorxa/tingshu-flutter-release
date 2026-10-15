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

  group('封面 URL 不得二次编码', () {
    test('保留服务端已转义的 %XX（番茄签名 %3D）', () {
      final result = SourceContract.parseSearchResult(
        {
          'list': [
            {
              'bookId': '1',
              'title': '番茄书',
              'cover':
                  'https://p3-reading-sign.fqnovelpic.com/novel-pic/a.image?x-signature=WnzEN7tStjqXF9Cwn1S778rLDlw%3D',
            },
          ],
        },
        sourceId: 'test',
        sourceName: '测试源',
      );

      final cover = result.list.first.cover;
      expect(cover, contains('%3D'));
      expect(cover, isNot(contains('%253D')));
    });

    test('不把已双编码的 %253D 再编码成 %25253D', () {
      final result = SourceContract.parseSearchResult(
        {
          'list': [
            {
              'bookId': '1',
              'title': '测试',
              'cover': 'https://x.com/a.png?sig=abc%253D',
            },
          ],
        },
        sourceId: 'test',
        sourceName: '测试源',
      );

      expect(result.list.first.cover, isNot(contains('%2525')));
    });

    test('仍会编码中文与空格等非法字符', () {
      final result = SourceContract.parseSearchResult(
        {
          'list': [
            {
              'bookId': '1',
              'title': '测试',
              'cover': 'https://x.com/中文/a b.png',
            },
          ],
        },
        sourceId: 'test',
        sourceName: '测试源',
      );

      final cover = result.list.first.cover;
      expect(cover, contains('%E4%B8%AD%E6%96%87'));
      expect(cover, contains('%20'));
      expect(cover, isNot(contains(' ')));
    });
  });
}
