import 'models.dart';

class SourceContract {
  SourceContract._();

  static const int version = 1;

  static int requireSupportedApiVersion(
    dynamic raw, {
    required String sourceId,
    required String sourceName,
  }) {
    final parsed = raw is num ? raw.toInt() : int.tryParse('$raw');
    final label = _label(sourceId, sourceName);
    if (parsed == null || parsed <= 0) {
      throw Exception('$label.apiVersion 必须是正整数');
    }
    if (parsed > version) {
      throw Exception('$label 需要音源协议 v$parsed，当前软件仅支持 v$version，请先更新软件');
    }
    return parsed;
  }

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
    final seenIds = <String>{};
    for (var i = 0; i < rawList.length; i++) {
      final item = _asMap(rawList[i], '$label.search list[$i] 必须是对象');
      final bookId = _requiredString(item, 'bookId', '$label.search list[$i]');
      final title = _requiredString(item, 'title', '$label.search list[$i]');
      if (!seenIds.add(bookId)) continue;
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
    final pagination = _pagination(map);
    return SearchResult(
      list: books,
      page: pagination.page,
      maxPage: pagination.maxPage,
      hasMore: pagination.hasMore,
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
    final seenIds = <String>{};
    for (var i = 0; i < rawList.length; i++) {
      final item = _asMap(rawList[i], '$label.getChapters list[$i] 必须是对象');
      final chapterId = _requiredString(
        item,
        'chapterId',
        '$label.getChapters list[$i]',
      );
      final name = _requiredString(item, 'name', '$label.getChapters list[$i]');
      if (!seenIds.add(chapterId)) continue;
      final index = _positiveInt(item, 'index', i + 1);
      chapters.add(Chapter(chapterId: chapterId, index: index, name: name));
    }
    final pagination = _pagination(map);
    return CatalogResult(
      info: CatalogInfo(
        title: _optionalString(infoMap, 'title'),
        cover: _normalizeCover(_optionalString(infoMap, 'cover')),
        author: _optionalString(infoMap, 'author'),
        trackCount: _nonNegativeInt(infoMap, 'trackCount', chapters.length),
        isFinished: infoMap['isFinished'] == true,
      ),
      list: chapters,
      page: pagination.page,
      maxPage: pagination.maxPage,
      hasMore: pagination.hasMore,
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

  static DiscoverResult parseDiscoverResult(
    dynamic raw, {
    required String sourceId,
    required String sourceName,
  }) {
    final label = _label(sourceId, sourceName);
    final map = _asMap(raw, '$label.discover 必须返回对象');
    final rawSections = map['sections'];
    if (rawSections is! List) {
      throw Exception('$label.discover 返回缺少 sections 数组');
    }
    final sections = <DiscoverSection>[];
    for (var i = 0; i < rawSections.length; i++) {
      final item = _asMap(rawSections[i], '$label.discover sections[$i] 必须是对象');
      final rawList = item['list'];
      if (rawList is! List) {
        throw Exception('$label.discover sections[$i] 缺少 list 数组');
      }
      final books = <Book>[];
      for (var j = 0; j < rawList.length; j++) {
        final entry = _asMap(
          rawList[j],
          '$label.discover sections[$i].list[$j] 必须是对象',
        );
        final bookId = _requiredString(
          entry,
          'bookId',
          '$label.discover sections[$i].list[$j]',
        );
        final title = _requiredString(
          entry,
          'title',
          '$label.discover sections[$i].list[$j]',
        );
        books.add(
          Book(
            bookId: bookId,
            title: title,
            cover: _normalizeCover(_optionalString(entry, 'cover')),
            author: _optionalString(entry, 'author'),
            intro: _optionalString(entry, 'intro'),
          ),
        );
      }
      sections.add(
        DiscoverSection(title: _optionalString(item, 'title'), list: books),
      );
    }
    return DiscoverResult(sections: sections);
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
      // 注意：这里绝对不能用 Uri.encodeFull —— 它会把已经是百分号转义的 URL 二次编码
      // （如番茄封面签名 x-signature=xxx%3D 会被编成 %253D，导致 CDN 返回 403）。
      // 服务端下发的 URL 已是合法转义形式，原样返回；仅在含非法字符时做一次轻量规范化。
      return _safeUri(cover);
    }
    return cover;
  }

  // 保留既有 %XX 转义，仅编码真正非法的字符（空格/中文等）。
  // Uri.tryParse 不会改动已转义序列，可安全用于此场景。
  static String _safeUri(String value) {
    final parsed = Uri.tryParse(value);
    if (parsed == null) return value;
    final normalized = parsed.toString();
    // 若规范化后把原 %XX 破坏成了 %25XX，则退回原值，保证不二次编码
    if (normalized.contains('%25') && !value.contains('%25')) return value;
    return normalized;
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

  static ({int page, int maxPage, bool hasMore}) _pagination(Map map) {
    final page = _positiveInt(map, 'page', 1);
    var maxPage = _positiveInt(map, 'maxPage', page);
    final declaredHasMore = map['hasMore'] == true;
    if (maxPage < page) maxPage = page;
    if (declaredHasMore && maxPage <= page) maxPage = page + 1;
    return (
      page: page,
      maxPage: maxPage,
      hasMore: declaredHasMore && page < maxPage,
    );
  }
}
