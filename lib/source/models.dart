// 音源数据模型:对齐 uni-app 版音源接口返回结构

class Book {
  final String bookId;
  final String title;
  final String cover;
  final String author;
  final String intro;

  Book({
    required this.bookId,
    required this.title,
    required this.cover,
    required this.author,
    required this.intro,
  });

  factory Book.fromMap(Map m) => Book(
    bookId: '${m['bookId'] ?? ''}',
    title: '${m['title'] ?? ''}',
    cover: '${m['cover'] ?? ''}',
    author: '${m['author'] ?? ''}',
    intro: '${m['intro'] ?? ''}',
  );
}

class Chapter {
  final String chapterId;
  final int index;
  final String name;

  Chapter({required this.chapterId, required this.index, required this.name});

  factory Chapter.fromMap(Map m) => Chapter(
    chapterId: '${m['chapterId'] ?? ''}',
    index: (m['index'] is num) ? (m['index'] as num).toInt() : 0,
    name: '${m['name'] ?? ''}',
  );

  Map<String, dynamic> toJson() => {
    'chapterId': chapterId,
    'index': index,
    'name': name,
  };
}

class CatalogInfo {
  final String title;
  final String cover;
  final String author;
  final int trackCount;
  final bool isFinished;

  CatalogInfo({
    required this.title,
    required this.cover,
    required this.author,
    required this.trackCount,
    required this.isFinished,
  });

  factory CatalogInfo.fromMap(Map? m) => CatalogInfo(
    title: '${m?['title'] ?? ''}',
    cover: '${m?['cover'] ?? ''}',
    author: '${m?['author'] ?? ''}',
    trackCount: (m?['trackCount'] is num)
        ? (m!['trackCount'] as num).toInt()
        : 0,
    isFinished: m?['isFinished'] == true,
  );
}

/// 搜索结果
class SearchResult {
  final List<Book> list;
  final int page;
  final int maxPage;
  final bool hasMore;

  SearchResult({
    required this.list,
    required this.page,
    required this.maxPage,
    required this.hasMore,
  });

  factory SearchResult.fromMap(Map m) => SearchResult(
    list: ((m['list'] as List?) ?? [])
        .map((e) => Book.fromMap(e as Map))
        .toList(),
    page: (m['page'] is num) ? (m['page'] as num).toInt() : 1,
    maxPage: (m['maxPage'] is num) ? (m['maxPage'] as num).toInt() : 1,
    hasMore: m['hasMore'] == true,
  );
}

/// 发现页单段:标题 + 书籍列表
class DiscoverSection {
  final String title;
  final List<Book> list;

  const DiscoverSection({required this.title, required this.list});

  factory DiscoverSection.fromMap(Map m) => DiscoverSection(
    title: '${m['title'] ?? ''}',
    list: ((m['list'] as List?) ?? [])
        .map((e) => Book.fromMap(e as Map))
        .toList(),
  );
}

/// 发现页结果:多段内容
class DiscoverResult {
  final List<DiscoverSection> sections;

  const DiscoverResult({required this.sections});

  factory DiscoverResult.fromMap(Map m) => DiscoverResult(
    sections: ((m['sections'] as List?) ?? [])
        .map((e) => DiscoverSection.fromMap(e as Map))
        .toList(),
  );
}

/// 目录结果
class CatalogResult {
  final CatalogInfo info;
  final List<Chapter> list;
  final int page;
  final int maxPage;
  final bool hasMore;

  CatalogResult({
    required this.info,
    required this.list,
    required this.page,
    required this.maxPage,
    required this.hasMore,
  });

  factory CatalogResult.fromMap(Map m) => CatalogResult(
    info: CatalogInfo.fromMap(m['info'] as Map?),
    list: ((m['list'] as List?) ?? [])
        .map((e) => Chapter.fromMap(e as Map))
        .toList(),
    page: (m['page'] is num) ? (m['page'] as num).toInt() : 1,
    maxPage: (m['maxPage'] is num) ? (m['maxPage'] as num).toInt() : 1,
    hasMore: m['hasMore'] == true,
  );
}

/// 音频解析结果:url + 可选自定义请求头(过防盗链)
class AudioResult {
  final String url;
  final Map<String, String> headers;
  final SniffRequest? sniff;

  AudioResult({required this.url, this.headers = const {}, this.sniff});

  bool get needsSniff => sniff != null;

  /// 音源 getAudioUrl 返回 String、{url, headers} 或
  /// {sniff:true,url,headers,click,waitMs,audioPatterns}
  factory AudioResult.from(dynamic ret) {
    if (ret is String) return AudioResult(url: ret);
    if (ret is Map && ret['sniff'] == true) {
      final sniff = SniffRequest.fromMap(ret);
      return AudioResult(url: sniff.url, headers: sniff.headers, sniff: sniff);
    }
    if (ret is Map && ret['url'] != null) {
      final h = <String, String>{};
      final hs = ret['headers'];
      if (hs is Map) {
        hs.forEach((k, v) => h['$k'] = '$v');
      }
      return AudioResult(url: '${ret['url']}', headers: h);
    }
    throw Exception('音源返回的音频信息无效');
  }
}

class SniffRequest {
  final String url;
  final Map<String, String> headers;
  final String click;
  final int waitMs;
  final List<String> audioPatterns;
  final String userAgent;

  SniffRequest({
    required this.url,
    this.headers = const {},
    this.click = '',
    this.waitMs = 3000,
    this.audioPatterns = const [],
    this.userAgent = '',
  });

  factory SniffRequest.fromMap(Map map) {
    final headers = <String, String>{};
    final rawHeaders = map['headers'] ?? map['header'];
    if (rawHeaders is Map) {
      rawHeaders.forEach((key, value) => headers['$key'] = '$value');
    }
    final patterns = <String>[];
    final rawPatterns = map['audioPatterns'] ?? map['patterns'];
    if (rawPatterns is List) {
      for (final pattern in rawPatterns) {
        final value = '$pattern'.trim();
        if (value.isNotEmpty) patterns.add(value);
      }
    }
    return SniffRequest(
      url: '${map['url'] ?? ''}'.trim(),
      headers: headers,
      click: '${map['click'] ?? map['clickSelector'] ?? ''}'.trim(),
      waitMs: (map['waitMs'] is num)
          ? (map['waitMs'] as num).toInt()
          : int.tryParse('${map['waitMs'] ?? ''}') ?? 3000,
      audioPatterns: patterns,
      userAgent: '${map['userAgent'] ?? ''}'.trim(),
    );
  }
}

/// 音源元数据
class SourceConfigField {
  final String key;
  final String label;
  final String type;
  final String hint;
  final bool required;

  SourceConfigField({
    required this.key,
    required this.label,
    this.type = 'text',
    this.hint = '',
    this.required = false,
  });

  factory SourceConfigField.fromMap(Map m) {
    final key = '${m['key'] ?? ''}'.trim();
    return SourceConfigField(
      key: key,
      label: '${m['label'] ?? key}'.trim(),
      type: '${m['type'] ?? 'text'}'.trim(),
      hint: '${m['hint'] ?? ''}',
      required: m['required'] == true,
    );
  }

  Map<String, dynamic> toJson() => {
    'key': key,
    'label': label,
    'type': type,
    'hint': hint,
    'required': required,
  };
}

class SourceMeta {
  final String id;
  final String name;
  final String loginUrl;
  final String loginConfigKey;
  final int apiVersion;
  final List<SourceConfigField> configFields;
  final bool supportsDiscover;
  bool active;
  bool enabled;

  SourceMeta({
    required this.id,
    required this.name,
    this.loginUrl = '',
    this.loginConfigKey = '',
    this.apiVersion = 1,
    this.configFields = const [],
    this.supportsDiscover = false,
    this.active = false,
    this.enabled = true,
  });

  bool get configurable => configFields.isNotEmpty;
}

class SourceSubscriptionMeta {
  final String id;
  final String name;
  final String originalUrl;
  final String requestUrl;
  final bool enabled;
  final bool autoUpdate;
  final int sourceCount;
  final String version;
  final String lastCheckedAt;
  final String lastUpdatedAt;
  final String lastError;

  const SourceSubscriptionMeta({
    required this.id,
    required this.name,
    required this.originalUrl,
    required this.requestUrl,
    required this.enabled,
    required this.autoUpdate,
    required this.sourceCount,
    required this.version,
    required this.lastCheckedAt,
    required this.lastUpdatedAt,
    required this.lastError,
  });

  bool get hasSuccess => lastUpdatedAt.isNotEmpty;
  bool get hasError => lastError.isNotEmpty;
}

class SourceSubscriptionCheckResult {
  final String subscriptionId;
  final String version;
  final int sourceCount;
  final bool hasUpdate;

  const SourceSubscriptionCheckResult({
    required this.subscriptionId,
    required this.version,
    required this.sourceCount,
    required this.hasUpdate,
  });
}
