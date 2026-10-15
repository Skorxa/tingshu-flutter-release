import 'dart:convert';

/// WebDAV 同步载荷的纯函数工具。
///
/// 刻意不依赖任何 Service / 数据库,便于单测。它承担三件事:
///
/// 1. **进度行瘦身**:同步不再上行可本地重建的封面字段,并限制条数与文本长度。
/// 2. **比较口径**:载荷里"每次生成都不同"的字段会让"内容没变就不上传"的判定
///    永远失效——旧实现顶层写入 `updatedAt = now`,于是每一轮同步(含每次冷启动、
///    播放中每 5 分钟一轮)都必然整包 PUT。这里统一在比较时剔除这类字段。
/// 3. **失败退避**:限额型 WebDAV(免费套餐按上传流量/请求数计费)一旦限流或超额,
///    必须指数降频,不能每 5 分钟继续撞同一堵墙。
class SyncPayload {
  const SyncPayload._();

  /// 同步载荷版本。已发布版本(1.5.5)读取时只关心 `settings/sources/shelf/progress`
  /// 与 `v`,因此保持 2 即可向后兼容。
  static const int version = 2;

  /// 进度同步条数上限。
  /// 查询按 `updatedAt DESC`,所以"当前正在播放/最近播放"的书一定落在窗口内。
  static const int maxProgressRows = 50;

  /// 参与比较时必须剔除的字段:内容相同、但每次生成都不同。
  /// 注意 `deviceTag` 也要剔除——多设备各自持有不同的 deviceTag,留在比较口径里
  /// 会让任意两台设备之间永远判定为"有差异"。
  static const Set<String> volatileKeys = {'updatedAt', 'deviceTag', 'syncedAt'};

  /// 文本字段截断长度。只用于标题类展示字段;
  /// `chapterId`/`bookId` 是续播标识,任何截断都会破坏跨设备续播,不做处理。
  static const int maxTextLength = 120;

  /// 保留封面的条数(列表顶部、用户真正会看到的那部分)。
  ///
  /// 封面是签名 CDN URL,每条 100-300 字符,是这两块载荷里最贵的字段。全部丢掉会让
  /// "新设备首次同步"后书架/历史没有封面;只保留最近 N 条,既保住观感,又把体积压到
  /// 几 KB 量级。
  static const int coverKeepCount = 30;

  /// 首次失败后的重试间隔(5 分钟,与旧的"仅播放进度变化"节流一致)。
  static const int baseRetryMs = 5 * 60 * 1000;

  /// 退避上限(6 小时)。
  static const int maxRetryMs = 6 * 60 * 60 * 1000;

  /// 限流/超额状态下的起步退避(30 分钟)。
  static const int rateLimitedRetryMs = 30 * 60 * 1000;

  /// 单条进度。默认不带封面(对端可用本地已有的封面兜底),截断超长标题。
  static Map<String, dynamic> progressRow(Map row, {bool includeCover = false}) {
    return {
      'sourceId': _str(row, 'sourceId'),
      'bookId': _str(row, 'bookId'),
      'bookTitle': clipText(_str(row, 'bookTitle')),
      // chapterId 原样上行:部分音源把直链/Referer 编码在 chapterId 里,截断即失效。
      'chapterId': _str(row, 'chapterId'),
      'chapterName': clipText(_str(row, 'chapterName')),
      'chapterIdx': _int(row['chapterIdx']),
      'currentTime': _double(row['currentTime']),
      'duration': _double(row['duration']),
      'updatedAt': _int(row['updatedAt']),
      if (includeCover) 'cover': _str(row, 'cover'),
    };
  }

  /// 批量瘦身(同步上行用):只有前 [coverKeep] 条带封面。
  static List<Map<String, dynamic>> progressRows(
    Iterable rows, {
    int coverKeep = coverKeepCount,
  }) {
    final out = <Map<String, dynamic>>[];
    var index = 0;
    for (final row in rows) {
      out.add(
        progressRow(
          Map<String, dynamic>.from(row),
          includeCover: index < coverKeep,
        ),
      );
      index++;
    }
    return out;
  }

  /// 单条书架:同样只在前若干条保留封面,标题类字段截断。
  static Map<String, dynamic> shelfRow({
    required String sourceId,
    required String bookId,
    required String title,
    required String author,
    required String sourceName,
    required int addTime,
    String cover = '',
  }) {
    return {
      'sourceId': sourceId,
      'bookId': bookId,
      'title': clipText(title),
      'author': clipText(author),
      'sourceName': clipText(sourceName),
      'addTime': addTime,
      if (cover.isNotEmpty) 'cover': cover,
    };
  }

  /// 落地到本地库时的行构造。
  ///
  /// 同步载荷不带封面,但本机历史列表需要封面,所以:对端没带封面时保留本地已有的,
  /// 避免"同步一次把封面清空"。
  static Map<String, dynamic> progressRowForInsert({
    required Map incoming,
    Map? local,
  }) {
    final incomingCover = _str(incoming, 'cover').trim();
    return {
      'sourceId': _str(incoming, 'sourceId'),
      'bookId': _str(incoming, 'bookId'),
      'bookTitle': _pick(incoming, local, 'bookTitle'),
      'cover': incomingCover.isNotEmpty
          ? incomingCover
          : _str(local ?? const {}, 'cover'),
      'chapterId': _pick(incoming, local, 'chapterId'),
      'chapterName': _pick(incoming, local, 'chapterName'),
      'chapterIdx': _int(_pickRaw(incoming, local, 'chapterIdx')),
      'currentTime': _double(_pickRaw(incoming, local, 'currentTime')),
      'duration': _double(_pickRaw(incoming, local, 'duration')),
      'updatedAt': _int(_pickRaw(incoming, local, 'updatedAt')),
    };
  }

  /// 比较口径:剔除易变字段后做键排序的规范化 JSON。
  /// 不修改入参。
  static String compareKey(Map<String, dynamic> payload) {
    final scrubbed = <String, dynamic>{};
    payload.forEach((key, value) {
      if (volatileKeys.contains(key)) return;
      scrubbed[key] = value;
    });
    return canonicalJson(scrubbed);
  }

  /// 键排序的规范化 JSON(递归),用于"内容是否变化"的比较。
  static String canonicalJson(dynamic value) {
    if (value is Map) {
      final keys = value.keys.map((key) => '$key').toList()..sort();
      return '{${keys.map((key) => '${jsonEncode(key)}:${canonicalJson(value[key])}').join(',')}}';
    }
    if (value is List) {
      return '[${value.map(canonicalJson).join(',')}]';
    }
    return jsonEncode(value);
  }

  /// 限流/超额类状态码:需要明显降频。
  static bool isQuotaStatus(int? statusCode) {
    if (statusCode == null) return false;
    return statusCode == 429 || statusCode == 507 || statusCode == 503;
  }

  /// 失败后的重试间隔:第 1 次失败取 base,之后逐次翻倍,上限 [maxRetryMs]。
  static int retryDelayMs(int consecutiveFailures, {bool rateLimited = false}) {
    if (consecutiveFailures <= 0) return 0;
    var delay = rateLimited ? rateLimitedRetryMs : baseRetryMs;
    for (var i = 1; i < consecutiveFailures; i++) {
      if (delay >= maxRetryMs) break;
      delay *= 2;
    }
    return delay > maxRetryMs ? maxRetryMs : delay;
  }

  static String clipText(String value) {
    if (value.length <= maxTextLength) return value;
    return value.substring(0, maxTextLength);
  }

  static String _str(Map map, String key) => '${map[key] ?? ''}';

  /// 文本字段落地策略:对端带了该键就用对端值,否则退回本地值。
  static String _pick(Map incoming, Map? local, String key) {
    if (incoming.containsKey(key)) return _str(incoming, key);
    return _str(local ?? const {}, key);
  }

  static dynamic _pickRaw(Map incoming, Map? local, String key) {
    if (incoming.containsKey(key)) return incoming[key];
    return local?[key];
  }

  static int _int(dynamic value) {
    if (value is num) return value.toInt();
    return int.tryParse('$value') ?? 0;
  }

  static double _double(dynamic value) {
    if (value is num) return value.toDouble();
    return double.tryParse('$value') ?? 0.0;
  }
}
