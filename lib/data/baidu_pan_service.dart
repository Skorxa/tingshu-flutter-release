import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path_util;
import 'package:path_provider/path_provider.dart';

import 'log_service.dart';
import 'pan_rate_limit.dart';
import 'secure_store.dart';
import '../source/models.dart';
import 'catalog_cache_service.dart';

class BaiduPanItem {
  final String name;
  final String path;
  final bool isDirectory;
  final int size;
  final String thumb;

  const BaiduPanItem({
    required this.name,
    required this.path,
    required this.isDirectory,
    this.size = 0,
    this.thumb = '',
  });
}

class BaiduAudio {
  final String url;
  final Map<String, String> headers;

  const BaiduAudio(this.url, this.headers);
}

class BaiduPanPage {
  final List<BaiduPanItem> items;
  final int page;
  final int pageSize;
  final bool hasMore;
  final int total;

  const BaiduPanPage({
    required this.items,
    required this.page,
    required this.pageSize,
    required this.hasMore,
    required this.total,
  });
}

class BaiduBookMeta {
  final String title;
  final String author;
  final String narrator;

  const BaiduBookMeta({
    required this.title,
    required this.author,
    required this.narrator,
  });
}

class BaiduBook {
  final String title;
  final String author;
  final String narrator;
  final String cover;
  final String path;
  final List<BaiduPanItem> audioFiles;

  const BaiduBook({
    required this.title,
    required this.author,
    required this.narrator,
    required this.cover,
    required this.path,
    required this.audioFiles,
  });
}

/// 百度网盘后端:登录 Cookie 鉴权;列目录 pan.baidu.com/api/list;
/// 取流 d.pcs.baidu.com locatedownload(请求用 netdisk UA,播放 UA 用 pan.baidu.com)。
class BaiduPanService extends ChangeNotifier {
  BaiduPanService._();
  static final instance = BaiduPanService._();

  static const _kConfig = 'baidu_pan_config';
  // 配置(含登录 Cookie)的加密存储键;明文旧键由 SecureStore 迁移后删除。
  static const _kConfigSecure = 'sec.baidu_pan_config';
  static const _pcUa =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/81.0.4044.138 Safari/537.36';
  static const _netdiskUa = 'netdisk;P2SP;2.2.91.136;android-android;';
  static const _playUa = 'pan.baidu.com'; // 播放直链 UA(用户指定)
  static const _defaultPageSize = 1000;
  static const _maxAutoPages = 200;

  static const audioExtensions = {
    '.mp3',
    '.m4a',
    '.m4b',
    '.aac',
    '.flac',
    '.wav',
    '.ogg',
    '.opus',
    '.ape',
    '.wma',
  };
  static const _coverExtensions = {'.jpg', '.jpeg', '.png', '.webp'};

  final Dio _dio = Dio();
  final Random _random = Random();
  String _cookie = '';
  String _rootPath = '/';

  String get cookie => _cookie;
  String get rootPath => _rootPath;
  bool get ready => _cookie.isNotEmpty;

  Future<void> init() async {
    final raw = await SecureStore.instance.readMigrated(
      _kConfig,
      _kConfigSecure,
    );
    if (raw == null || raw.isEmpty) return;
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      _cookie = '${map['cookie'] ?? ''}';
      _rootPath = '${map['rootPath'] ?? '/'}';
    } catch (e) {
      LogService.instance.warning('BaiduPan', '读取配置失败', detail: '$e');
    }
  }

  Future<void> _persist() async {
    await SecureStore.instance.write(
      _kConfigSecure,
      jsonEncode({'cookie': _cookie, 'rootPath': _rootPath}),
    );
  }

  Future<void> saveCookie(String cookie) async {
    _cookie = cookie.trim();
    await _persist();
    LogService.instance.info(
      'BaiduPan',
      '已保存登录 Cookie',
      detail: '长度: ${_cookie.length}',
    );
    notifyListeners();
  }

  Future<void> saveRootPath(String path) async {
    var p = path.trim();
    if (p.isEmpty) p = '/';
    if (!p.startsWith('/')) p = '/$p';
    _rootPath = p;
    await _persist();
    notifyListeners();
  }

  Future<void> logout() async {
    _cookie = '';
    await _persist();
    notifyListeners();
  }

  bool isAudioFile(String name) {
    final lower = name.toLowerCase();
    return audioExtensions.any(lower.endsWith);
  }

  bool isCoverFile(String name) {
    final lower = name.toLowerCase();
    return lower.startsWith('cover') && _coverExtensions.any(lower.endsWith);
  }

  /// 文件夹名解析:书名_作者_演播者(下划线分隔,至少 3 段)。
  BaiduBookMeta? parseBookFolderName(String name) {
    final parts = name
        .split(RegExp(r'_+'))
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty)
        .toList(growable: false);
    if (parts.length < 3) return null;
    return BaiduBookMeta(
      title: parts.first,
      author: parts[1],
      narrator: parts.sublist(2).join('_'),
    );
  }

  /// 列目录。[dir] 为绝对路径(如 /我的资源/小说)。
  ///
  /// 默认自动按页拉取完整目录，避免超过百度单页数量上限时漏集。
  Future<List<BaiduPanItem>> list(
    String dir, {
    int? page,
    int pageSize = _defaultPageSize,
  }) async {
    if (page != null) {
      final single = await listPage(dir, page: page, pageSize: pageSize);
      return single.items;
    }
    final items = await listAll(dir, pageSize: pageSize);
    return items;
  }

  Future<List<BaiduPanItem>> listAll(
    String dir, {
    int pageSize = _defaultPageSize,
  }) async {
    final all = <BaiduPanItem>[];
    var page = 1;
    var hasMore = true;
    while (hasMore && page <= _maxAutoPages) {
      BaiduPanPage result;
      try {
        result = await listPage(dir, page: page, pageSize: pageSize);
      } on PanRateLimitException catch (e) {
        if (page == 1) rethrow; // 首页被限流,多半整体被限,直接上抛
        final wait = panBackoffDelayMs(_random);
        LogService.instance.warning(
          'BaiduPan',
          '触发网盘限流，退避后重试',
          detail: '路径: $dir\n页码: $page\n等待: ${wait}ms\n${e.detail}',
        );
        await Future<void>.delayed(Duration(milliseconds: wait));
        result = await listPage(dir, page: page, pageSize: pageSize);
      }
      all.addAll(result.items);
      hasMore = result.hasMore;
      LogService.instance.info(
        'BaiduPan',
        '目录分页读取',
        detail:
            '路径: $dir\n页码: ${result.page}\n本页: ${result.items.length}\n累计: ${all.length}\n总数: ${result.total > 0 ? result.total : '未知'}\n继续: ${result.hasMore ? '是' : '否'}',
      );
      page++;
      if (hasMore) {
        // 页间随机抖动,避免固定节奏被网盘风控识别
        await Future<void>.delayed(Duration(milliseconds: 250 + _random.nextInt(400)));
      }
    }
    if (hasMore) {
      LogService.instance.warning(
        'BaiduPan',
        '目录页数超过保护上限，已停止继续读取',
        detail: '路径: $dir\n已读取页数: $_maxAutoPages\n累计条目: ${all.length}',
      );
    }
    all.sort((a, b) {
      if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
      return _naturalCompare(a.name, b.name);
    });
    LogService.instance.info(
      'BaiduPan',
      '列目录完成',
      detail: '路径: $dir\n条目: ${all.length}\n页数: ${page - 1}',
    );
    return all;
  }

  Future<BaiduPanPage> listPage(
    String dir, {
    int page = 1,
    int pageSize = _defaultPageSize,
  }) async {
    if (_cookie.isEmpty) throw Exception('请先登录百度网盘');
    final url =
        'https://pan.baidu.com/api/list?order=name&desc=0&showempty=0&web=1'
        '&page=$page&num=$pageSize&dir=${Uri.encodeComponent(dir)}'
        '&channel=chunlei&clienttype=0';
    final resp = await _dio.get<String>(
      url,
      options: Options(
        headers: {'User-Agent': _pcUa, 'Cookie': _cookie},
        responseType: ResponseType.plain,
        validateStatus: (_) => true,
      ),
    );
    if (resp.statusCode == 429) {
      throw PanRateLimitException('百度目录请求被限流\n路径: $dir\n页码: $page');
    }
    final data = jsonDecode(resp.data ?? '{}') as Map<String, dynamic>;
    final errno = (data['errno'] as num?)?.toInt() ?? -1;
    if (errno != 0) throw Exception(_errnoMessage(errno));
    final rawList = (data['list'] as List?) ?? const [];
    final items = rawList.whereType<Map>().map((e) {
      final thumbs = e['thumbs'];
      return BaiduPanItem(
        name: '${e['server_filename'] ?? ''}',
        path: '${e['path'] ?? ''}',
        isDirectory: (e['isdir'] as num?)?.toInt() == 1,
        size: (e['size'] as num?)?.toInt() ?? 0,
        thumb: thumbs is Map ? '${thumbs['url3'] ?? ''}' : '',
      );
    }).toList();
    items.sort((a, b) {
      if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
      return _naturalCompare(a.name, b.name);
    });
    return BaiduPanPage(
      items: items,
      page: page,
      pageSize: pageSize,
      hasMore: _hasMore(data, rawList.length, pageSize),
      total: _extractTotal(data),
    );
  }

  /// 递归收集书文件夹下所有音频(含分卷子目录),按目录与名称自然序合并。
  Future<List<BaiduPanItem>> collectAudioFiles(String bookPath) async {
    final out = <BaiduPanItem>[];
    await _collect(bookPath, out, 0);
    return out;
  }

  Future<void> _collect(String dir, List<BaiduPanItem> out, int depth) async {
    if (depth > 3) return; // 防过深递归
    final items = await list(dir);
    final audios =
        items.where((e) => !e.isDirectory && isAudioFile(e.name)).toList()
          ..sort((a, b) => _naturalCompare(a.name, b.name));
    out.addAll(audios);
    final subs = items.where((e) => e.isDirectory).toList()
      ..sort((a, b) => _naturalCompare(a.name, b.name));
    for (final sub in subs) {
      // 子目录间隔随机抖动,避免连续打接口被风控
      await Future<void>.delayed(Duration(milliseconds: 300 + _random.nextInt(500)));
      await _collect(sub.path, out, depth + 1);
    }
  }

  /// 把一个书文件夹组合成一本书:解析命名 + 递归音频 + 封面。
  Future<BaiduBook> toBook(String bookPath) async {
    final name = _displayName(bookPath);
    final meta = parseBookFolderName(name);
    final topItems = await list(bookPath);
    final audios = await collectAudioFiles(bookPath);
    final cover = await resolveBookCover(topItems, audios, bookPath: bookPath);
    return BaiduBook(
      title: meta?.title ?? name,
      author: meta?.author ?? '',
      narrator: meta?.narrator ?? '',
      cover: cover,
      path: bookPath,
      audioFiles: audios,
    );
  }

  /// 重新枚举目录并刷新缓存(手动刷新入口),返回最新目录供 UI 直接替换。
  Future<CachedCatalog> refreshCatalog({
    required String bookPath,
    String fallbackCover = '',
    String fallbackAuthor = '',
  }) async {
    final book = await toBook(bookPath);
    if (book.audioFiles.isEmpty) throw Exception('目录没有可播放的音频文件');
    final author = book.narrator.isEmpty
        ? book.author
        : '${book.author} / ${book.narrator}';
    final info = CatalogInfo(
      title: book.title,
      cover: book.cover.isNotEmpty ? book.cover : fallbackCover,
      author: author.isNotEmpty ? author : fallbackAuthor,
      trackCount: book.audioFiles.length,
      isFinished: true,
    );
    final chapters = <Chapter>[
      for (var i = 0; i < book.audioFiles.length; i++)
        Chapter(
          chapterId: 'baidu:${book.audioFiles[i].path}',
          index: i + 1,
          name: book.audioFiles[i].name,
        ),
    ];
    await CatalogCacheService.instance.savePage(
      sourceId: 'baidu',
      bookId: bookPath,
      info: info,
      chapters: chapters,
      page: 1,
      maxPage: 1,
      hasMore: false,
    );
    LogService.instance.info(
      'BaiduPan',
      '书籍目录已刷新并写入 SQLite',
      detail: '书名: ${info.title}\n路径: $bookPath\n章节数: ${chapters.length}',
    );
    return CachedCatalog(
      info: info,
      chapters: chapters,
      page: 1,
      maxPage: 1,
      hasMore: false,
    );
  }

  BaiduPanItem? findCoverItem(List<BaiduPanItem> items) {
    final covers =
        items.where((it) => !it.isDirectory && isCoverFile(it.name)).toList()
          ..sort(
            (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
          );
    return covers.isEmpty ? null : covers.first;
  }

  Future<String> resolveBookCover(
    List<BaiduPanItem> topItems,
    List<BaiduPanItem> audios, {
    required String bookPath,
  }) async {
    final coverItem = findCoverItem(topItems);
    if (coverItem != null) {
      try {
        return await cacheCover(coverItem);
      } catch (e) {
        LogService.instance.warning(
          'BaiduPan',
          '封面缓存失败，继续使用远程缩略图',
          detail: '书籍路径: $bookPath\n封面: ${coverItem.name}\n错误: $e',
        );
        if (coverItem.thumb.isNotEmpty) return coverItem.thumb;
      }
    }
    for (final a in audios) {
      if (a.thumb.isNotEmpty) return a.thumb;
    }
    return '';
  }

  Future<String> cacheCover(BaiduPanItem coverItem) async {
    final ext = path_util.extension(coverItem.name).toLowerCase();
    final safeExt = ext.isEmpty ? '.jpg' : ext;
    final key = base64Url
        .encode(utf8.encode(coverItem.path))
        .replaceAll(RegExp(r'=+$'), '');
    final dir = Directory(
      path_util.join((await getApplicationCacheDirectory()).path, 'covers'),
    );
    if (!await dir.exists()) await dir.create(recursive: true);
    final file = File(path_util.join(dir.path, 'baidu_$key$safeExt'));
    if (await file.exists() && await file.length() > 0) return file.path;

    var url = coverItem.thumb.trim();
    var headers = <String, String>{'User-Agent': _pcUa, 'Cookie': _cookie};
    if (url.isEmpty) {
      final audio = await _resolveDownload(coverItem.path, playHeaders: false);
      url = audio.url;
      headers = audio.headers;
    }
    if (url.startsWith('//')) url = 'https:$url';
    if (url.isEmpty) throw Exception('封面缩略图地址为空');

    await _dio.download(
      url,
      file.path,
      options: Options(
        headers: headers,
        receiveTimeout: const Duration(seconds: 30),
      ),
    );
    if (await file.length() <= 0) {
      await file.delete();
      throw Exception('封面下载文件大小为 0');
    }
    LogService.instance.info(
      'BaiduPan',
      '封面已缓存到本地',
      detail: '文件: ${coverItem.name}\n路径: ${file.path}',
    );
    return file.path;
  }

  /// 取文件可播放直链 + 播放 header(UA=pan.baidu.com)。
  Future<BaiduAudio> resolveAudio(String path) async {
    return _resolveDownload(path, playHeaders: true);
  }

  Future<BaiduAudio> _resolveDownload(
    String path, {
    required bool playHeaders,
  }) async {
    if (_cookie.isEmpty) throw Exception('请先登录百度网盘');
    final url =
        'https://d.pcs.baidu.com/rest/2.0/pcs/file?app_id=250528'
        '&method=locatedownload&path=${Uri.encodeComponent(path)}&use=1';
    final resp = await _dio.get<String>(
      url,
      options: Options(
        headers: {'User-Agent': _netdiskUa, 'Cookie': _cookie},
        responseType: ResponseType.plain,
        followRedirects: true,
        validateStatus: (_) => true,
      ),
    );
    final body = resp.data ?? '';
    Map<String, dynamic> data;
    try {
      data = jsonDecode(body) as Map<String, dynamic>;
    } catch (_) {
      throw Exception(
        '取直链返回非 JSON: ${body.length > 200 ? body.substring(0, 200) : body}',
      );
    }
    final urls = data['urls'] as List?;
    if (urls == null || urls.isEmpty) {
      throw Exception('取直链失败(可能 Cookie 失效或被限制): $body');
    }
    final dlUrl = '${(urls.first as Map)['url'] ?? ''}';
    if (dlUrl.isEmpty) throw Exception('直链为空');
    LogService.instance.info(
      'BaiduPan',
      '取直链完成',
      detail: '路径: $path\nURL: $dlUrl',
    );
    return BaiduAudio(dlUrl, {
      'User-Agent': playHeaders ? _playUa : _netdiskUa,
      'Cookie': _cookie,
    });
  }

  bool _hasMore(Map<String, dynamic> data, int itemCount, int pageSize) {
    for (final key in const ['has_more', 'hasMore', 'more']) {
      final value = data[key];
      if (value is bool) return value;
      if (value is num) return value.toInt() != 0;
      if (value is String && value.isNotEmpty) {
        return value == '1' || value.toLowerCase() == 'true';
      }
    }
    final total = _extractTotal(data);
    final page = (data['page'] as num?)?.toInt();
    if (total > 0 && page != null && page > 0) {
      return page * pageSize < total;
    }
    return itemCount >= pageSize;
  }

  int _extractTotal(Map<String, dynamic> data) {
    for (final key in const ['total', 'count', 'total_count']) {
      final value = data[key];
      if (value is num) return value.toInt();
      if (value is String) return int.tryParse(value) ?? 0;
    }
    return 0;
  }

  String _displayName(String path) {
    var p = path.trim();
    if (p.length > 1 && p.endsWith('/')) p = p.substring(0, p.length - 1);
    final i = p.lastIndexOf('/');
    return i >= 0 ? p.substring(i + 1) : p;
  }

  int _naturalCompare(String a, String b) {
    final na = _firstNumber(a);
    final nb = _firstNumber(b);
    if (na != null && nb != null && na != nb) return na.compareTo(nb);
    return a.toLowerCase().compareTo(b.toLowerCase());
  }

  int? _firstNumber(String value) {
    final m = RegExp(r'\d+').firstMatch(value);
    return m == null ? null : int.tryParse(m.group(0)!);
  }

  String _errnoMessage(int errno) {
    switch (errno) {
      case -6:
        return '身份验证失败(Cookie 失效),请重新登录';
      case -7:
        return '文件名非法或无权访问';
      case -9:
        return '路径不存在';
      case 2:
        return '参数错误,请检查路径';
      default:
        return '百度网盘返回错误 errno=$errno';
    }
  }
}
