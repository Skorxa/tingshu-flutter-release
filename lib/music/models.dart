// 音乐模式数据模型

/// 单首歌曲的元信息
class MusicInfo {
  final String id;
  final String name;
  final String singer;
  final String album;
  final String img;
  final Duration? duration;
  final String source; // 平台标识: kuwo / wy / kg / tx / custom:xxx
  final List<MusicQuality> qualities;

  MusicInfo({
    required this.id,
    required this.name,
    required this.singer,
    this.album = '',
    this.img = '',
    this.duration,
    required this.source,
    this.qualities = const [],
  });

  factory MusicInfo.fromMap(Map m, {required String source}) {
    final rawDuration = m['duration'];
    Duration? dur;
    if (rawDuration is num) {
      dur = Duration(seconds: rawDuration.toInt());
    } else if (rawDuration is String) {
      final sec = int.tryParse(rawDuration);
      if (sec != null) dur = Duration(seconds: sec);
    }
    return MusicInfo(
      id: '${m['id'] ?? m['songId'] ?? m['rid'] ?? ''}',
      name: '${m['name'] ?? m['songName'] ?? ''}',
      singer: '${m['singer'] ?? m['artist'] ?? ''}',
      album: '${m['album'] ?? ''}',
      img: '${m['img'] ?? m['pic'] ?? m['albumpic'] ?? ''}',
      duration: dur,
      source: source,
      qualities: [],
    );
  }

  Map<String, dynamic> toMap() => {
    'id': id,
    'name': name,
    'singer': singer,
    'album': album,
    'img': img,
    'duration': duration?.inSeconds ?? 0,
    'source': source,
  };
}

/// 可选音质
class MusicQuality {
  final String type; // '128k' / '320k' / 'flac' / 'master' 等
  final String label; // 显示名称

  const MusicQuality({required this.type, required this.label});

  @override
  String toString() => label;
}

/// 单行歌词
class LyricLine {
  final Duration time;
  final String text;

  const LyricLine({required this.time, required this.text});
}

/// 完整歌词(含翻译)
class Lyric {
  final List<LyricLine> lines;
  final bool hasTranslation;

  const Lyric({required this.lines, this.hasTranslation = false});

  static const empty = Lyric(lines: []);
}

/// 搜索结果
class MusicSearchResult {
  final List<MusicInfo> list;
  final int page;
  final int maxPage;
  final bool hasMore;

  MusicSearchResult({
    required this.list,
    required this.page,
    required this.maxPage,
    required this.hasMore,
  });
}

/// 排行榜/歌单条目
class Leaderboard {
  final String id;
  final String name;
  final String img;
  final String source;

  const Leaderboard({
    required this.id,
    required this.name,
    this.img = '',
    required this.source,
  });
}

/// 每日推荐歌曲列表
class DailyRecommend {
  final List<MusicInfo> list;
  final String source;

  const DailyRecommend({required this.list, required this.source});
}
