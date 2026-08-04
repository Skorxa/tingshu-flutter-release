import 'models.dart';

/// 音乐源抽象接口。
///
/// 内置平台(酷我/网易云等)用 Dart 类实现;
/// 自定义源(落雪 userApi)用 JS 引擎适配器实现。
abstract class MusicSource {
  /// 平台唯一标识
  String get id;

  /// 显示名称
  String get name;

  /// 是否需要登录(cookie)才能使用完整功能
  bool get requiresLogin;

  /// 搜索歌曲
  Future<MusicSearchResult> search(
    String keyword, {
    int page = 1,
    int limit = 30,
  });

  /// 获取播放链接。quality 为空时返回默认音质。
  /// 返回 (url, headers) 元组,headers 可能为空。
  Future<({String url, Map<String, String> headers})> getMusicUrl(
    String songId, {
    String? quality,
  });

  /// 获取封面图 URL
  Future<String> getPic(String songId);

  /// 获取歌词。无歌词时返回 [Lyric.empty]。
  Future<Lyric> getLyric(String songId);

  /// 获取每日推荐(可选)。不支持的平台抛 [UnimplementedError]。
  Future<DailyRecommend> getDailyRec(String? cookie) {
    throw UnimplementedError('$name 不支持每日推荐');
  }

  /// 获取排行榜列表(可选)。
  Future<List<Leaderboard>> getLeaderboards() {
    throw UnimplementedError('$name 不支持排行榜');
  }
}

/// 平台元信息(用于 UI 展示与切换)
class MusicSourceMeta {
  final String id;
  final String name;
  final bool requiresLogin;
  final bool isBuiltin;

  const MusicSourceMeta({
    required this.id,
    required this.name,
    this.requiresLogin = false,
    this.isBuiltin = true,
  });
}
