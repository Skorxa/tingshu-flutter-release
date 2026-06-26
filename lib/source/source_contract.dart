import 'models.dart';

class SourceContract {
  SourceContract._();

  static const int version = 1;

  static SearchResult parseSearchResult(
    dynamic raw, {
    required String sourceId,
    required String sourceName,
  }) {
    final label = _label(sourceId, sourceName);
    final map = _asMap(raw, '$label.search 必须返回对象');
    final rawList = map['list'];
    if (rawList is! List) {
      throw Exception('$label.search 返回缺少 list 数组');
    }
    final books = <Book>[];
    for (var i = 0; i < rawList.length; i++) {
      final item = _asMap(rawList[i], '$label.search list[$i] 必须是对象');
      final bookId = _requiredString(item, 'bookId', '$label.search list[$i]');
      final title = _requiredString(item, 'title', '$label.search list[$i]');
      books.add(
        Book(
          bookId: bookId,
          title: title,
          cover: _normalizeCover(_optionalString(item, 'cover')),
          author: _optionalString(item, 'author'),
          intro: _optionalString(item, 'intro'),
        ),
      );
    }
    return SearchResult(
      list: books,
      page: _positiveInt(map, 'page', 1),
      maxPage: _positiveInt(map, 'maxPage', 1),
      hasMore: map['hasMore'] == true,
    );
  }

  static CatalogResult parseCatalogResult(
    dynamic raw, {
    required String sourceId,
    required String sourceName,
  }) {
    final label = _label(sourceId, sourceName);
    final map = _asMap(raw, '$label.getChapters 必须返回对象');
    final infoMap = _asMap(map['info'], '$label.getChapters 返回缺少 info 对象');
    final rawList = map['list'];
    if (rawList is! List) {
      throw Exception('$label.getChapters 返回缺少 list 数组');
    }
    final chapters = <Chapter>[];
    for (var i = 0; i < rawList.length; i++) {
      final item = _asMap(rawList[i], '$label.getChapters list[$i] 必须是对象');
      final chapterId = _requiredString(
        item,
        'chapterId',
        '$label.getChapters list[$i]',
      );
      final name = _requiredString(item, 'name', '$label.getChapters list[$i]');
      final index = _positiveInt(item, 'index', i + 1);
      chapters.add(Chapter(chapterId: chapterId, index: index, name: name));
    }
    return CatalogResult(
      info: CatalogInfo(
        title: _optionalString(infoMap, 'title'),
        cover: _normalizeCover(_optionalString(infoMap, 'cover')),
        author: _optionalString(infoMap, 'author'),
        trackCount: _nonNegativeInt(infoMap, 'trackCount', chapters.length),
        isFinished: infoMap['isFinished'] == true,
      ),
      list: chapters,
      page: _positiveInt(map, 'page', 1),
      maxPage: _positiveInt(map, 'maxPage', 1),
      hasMore: map['hasMore'] == true,
    );
  }

  static AudioResult parseAudioResult(
    dynamic raw, {
    required String sourceId,
    required String sourceName,
  }) {
    final label = _label(sourceId, sourceName);
    final audio = AudioResult.from(raw);
    final uri = Uri.tryParse(audio.url);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      throw Exception('$label.getAudioUrl 必须返回 http/https 地址');
    }
    return audio;
  }

  static String _label(String sourceId, String sourceName) {
    return sourceName.isEmpty ? sourceId : '$sourceName($sourceId)';
  }

  static Map _asMap(dynamic value, String message) {
    if (value is Map) return value;
    throw Exception(message);
  }

  static String _requiredString(Map map, String key, String scope) {
    final value = '${map[key] ?? ''}'.trim();
    if (value.isEmpty) throw Exception('$scope 缺少 $key');
    return value;
  }

  static String _optionalString(Map map, String key) {
    return '${map[key] ?? ''}'.trim();
  }

  static String _normalizeCover(String value) {
    var cover = value.trim();
    if (cover.isEmpty) return '';
    if (cover.startsWith('//')) cover = 'https:$cover';
    if (cover.startsWith('http://') || cover.startsWith('https://')) {
      return Uri.encodeFull(cover);
    }
    return cover;
  }

  static int _positiveInt(Map map, String key, int fallback) {
    final value = map[key];
    final parsed = value is num ? value.toInt() : int.tryParse('$value');
    if (parsed == null || parsed <= 0) return fallback;
    return parsed;
  }

  static int _nonNegativeInt(Map map, String key, int fallback) {
    final value = map[key];
    final parsed = value is num ? value.toInt() : int.tryParse('$value');
    if (parsed == null || parsed < 0) return fallback;
    return parsed;
  }
}
