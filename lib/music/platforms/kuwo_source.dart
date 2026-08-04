import 'package:dio/dio.dart';

import '../../data/log_service.dart';
import '../models.dart';
import '../music_source.dart';

/// 酷我音乐平台。无加密,纯 HTTP GET + JSON。
class KuwoSource extends MusicSource {
  KuwoSource();

  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 15),
    followRedirects: true,
    validateStatus: (s) => s != null && s < 400,
  ));

  String? _kwToken;

  @override
  String get id => 'kuwo';

  @override
  String get name => '酷我音乐';

  @override
  bool get requiresLogin => false;

  Future<void> _ensureToken() async {
    if (_kwToken != null) return;
    try {
      final resp = await _dio.get(
        'https://www.kuwo.cn/',
        options: Options(
          headers: {
            'User-Agent':
                'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
          },
        ),
      );
      final cookies = resp.headers.map['set-cookie'];
      if (cookies != null) {
        for (final cookie in cookies) {
          final match = RegExp(r'kw_token=([^;]+)').firstMatch(cookie);
          if (match != null) {
            _kwToken = match.group(1);
            return;
          }
        }
      }
    } catch (e) {
      LogService.instance.warning('Kuwo', '获取 kw_token 失败', detail: '$e');
    }
  }

  @override
  Future<MusicSearchResult> search(
    String keyword, {
    int page = 1,
    int limit = 30,
  }) async {
    final url =
        'http://search.kuwo.cn/r.s?client=kt&all=${Uri.encodeComponent(keyword)}'
        '&pn=${page - 1}&rn=$limit&uid=794762570&ver=kwplayer_ar_9.2.2.1'
        '&vipver=1&show_copyright_off=1&newver=1&ft=music&cluster=0'
        '&strategy=2012&encoding=utf8&rformat=json&vermerge=1&mobi=1&issubtitle=1';
    final resp = await _dio.get<dynamic>(
      url,
      options: Options(responseType: ResponseType.json, headers: {
        'User-Agent': 'okhttp/4.9.2',
      }),
    );
    final data = resp.data;
    List? abslist;
    int total = 0;
    if (data is Map) {
      abslist = data['abslist'] as List?;
      total = int.tryParse('${data['TOTAL'] ?? 0}') ?? 0;
    } else if (data is List) {
      abslist = data;
      total = data.length;
    }
    final list = <MusicInfo>[];
    if (abslist != null) {
      for (final item in abslist) {
        if (item is! Map) continue;
        final musicId = '${item['MUSICRID'] ?? ''}'.replaceAll('MUSIC_', '');
        if (musicId.isEmpty) continue;
        final name = _decodeHtml('${item['SONGNAME'] ?? ''}');
        final artist = _decodeHtml('${item['ARTIST'] ?? ''}');
        final album = _decodeHtml('${item['ALBUM'] ?? ''}');
        var pic = '${item['albumpic'] ?? ''}';
        if (pic.isEmpty) {
          final short = '${item['web_albumpic_short'] ?? ''}';
          if (short.isNotEmpty) {
            pic = short.startsWith('http')
                ? short
                : 'https://img1.kuwo.cn/star/albumcover/$short';
          }
        }
        final dur = int.tryParse('${item['DURATION'] ?? '0'}') ?? 0;
        list.add(MusicInfo(
          id: musicId,
          name: name,
          singer: artist,
          album: album,
          img: pic,
          duration: dur > 0 ? Duration(seconds: dur) : null,
          source: id,
        ));
      }
    }
    final maxPage = (total / limit).ceil().clamp(1, 100);
    final hasMore = page < maxPage && list.length >= limit;
    LogService.instance.info('Kuwo', '搜索完成',
        detail: '关键词: $keyword\n结果: ${list.length} 条\n页: $page/$maxPage');
    return MusicSearchResult(
      list: list,
      page: page,
      maxPage: maxPage,
      hasMore: hasMore,
    );
  }

  @override
  Future<({String url, Map<String, String> headers})> getMusicUrl(
    String songId, {
    String? quality,
  }) async {
    await _ensureToken();
    final br = _mapQuality(quality);
    final url =
        'https://www.kuwo.cn/api/v1/www/music/playUrl?mid=$songId&type=music&br=$br';
    final headers = <String, String>{
      'User-Agent':
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
      'Referer': 'https://www.kuwo.cn/',
    };
    if (_kwToken != null) {
      headers['Cookie'] = 'kw_token=$_kwToken';
      headers['csrf'] = _kwToken!;
    }
    final resp = await _dio.get<dynamic>(
      url,
      options: Options(responseType: ResponseType.json, headers: headers),
    );
    final data = resp.data;
    if (data is Map) {
      final playUrl = '${data['data']?['url'] ?? ''}';
      if (playUrl.isNotEmpty && !playUrl.contains('null')) {
        LogService.instance.info('Kuwo', '获取播放链接',
            detail: '歌曲ID: $songId\n音质: $br');
        return (url: playUrl, headers: <String, String>{});
      }
    }
    // 回退: antiserver 直连
    final fallbackUrl =
        'http://antiserver.kuwo.cn/anti.s?type=convert_url&format=mp3&response=url&rid=MUSIC_$songId';
    final fallbackResp = await _dio.get<String>(
      fallbackUrl,
      options: Options(responseType: ResponseType.plain, followRedirects: false),
    );
    final location =
        fallbackResp.headers.value('location') ?? fallbackResp.data ?? '';
    if (location.isNotEmpty && location.startsWith('http')) {
      LogService.instance.info('Kuwo', '回退 antiserver 获取播放链接',
          detail: '歌曲ID: $songId');
      return (url: location, headers: <String, String>{});
    }
    throw Exception('酷我获取播放链接失败: $songId');
  }

  String _mapQuality(String? quality) {
    switch (quality) {
      case '128k':
        return '128kmp3';
      case 'flac':
        return 'flac';
      case 'master':
        return 'flac24bit';
      default:
        return '320kmp3';
    }
  }

  @override
  Future<String> getPic(String songId) async {
    try {
      final resp = await _dio.get<dynamic>(
        'https://www.kuwo.cn/api/www/music/musicInfo?mid=$songId',
        options: Options(responseType: ResponseType.json, headers: {
          'User-Agent': 'Mozilla/5.0',
          'Referer': 'https://www.kuwo.cn/',
          if (_kwToken != null) 'Cookie': 'kw_token=$_kwToken',
          if (_kwToken != null) 'csrf': _kwToken!,
        }),
      );
      final data = resp.data;
      if (data is Map) {
        final pic =
            '${data['data']?['pic'] ?? data['data']?['albumpic'] ?? ''}';
        if (pic.isNotEmpty) return pic;
      }
    } catch (_) {}
    return '';
  }

  @override
  Future<Lyric> getLyric(String songId) async {
    try {
      final resp = await _dio.get<dynamic>(
        'https://m.kuwo.cn/newh5/singles/songinfoandlrc?musicId=$songId',
        options: Options(responseType: ResponseType.json, headers: {
          'User-Agent': 'Mozilla/5.0',
        }),
      );
      final data = resp.data;
      if (data is Map) {
        final lrclist = data['data']?['lrclist'];
        if (lrclist is List) {
          final lines = <LyricLine>[];
          for (final item in lrclist) {
            if (item is! Map) continue;
            final time = double.tryParse('${item['time'] ?? '0'}') ?? 0;
            final text = '${item['lineLyric'] ?? ''}';
            if (text.isNotEmpty) {
              lines.add(LyricLine(
                time: Duration(milliseconds: (time * 1000).round()),
                text: _decodeHtml(text),
              ));
            }
          }
          if (lines.isNotEmpty) return Lyric(lines: lines);
        }
      }
    } catch (e) {
      LogService.instance.warning('Kuwo', '获取歌词失败', detail: '$e');
    }
    return Lyric.empty;
  }

  String _decodeHtml(String s) {
    return s
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', '\x27')
        .replaceAll('&nbsp;', ' ');
  }
}
