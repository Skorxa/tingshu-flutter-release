import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path_util;
import 'package:path_provider/path_provider.dart';

import '../source/models.dart';
import 'catalog_cache_service.dart';
import 'log_service.dart';
import 'secure_store.dart';

class QuarkPanItem {
  final String fid;
  final String name;
  final bool isDirectory;
  final int size;
  final String thumb;

  const QuarkPanItem({
    required this.fid,
    required this.name,
    required this.isDirectory,
    this.size = 0,
    this.thumb = '',
  });
}

class QuarkPanPage {
  final List<QuarkPanItem> items;
  final int page;
  final int pageSize;
  final bool hasMore;
  final int total;

  const QuarkPanPage({
    required this.items,
    required this.page,
    required this.pageSize,
    required this.hasMore,
    required this.total,
  });
}

class QuarkAudio {
  final String url;
  final Map<String, String> headers;

  const QuarkAudio(this.url, this.headers);
}

class QuarkBookMeta {
  final String title;
  final String author;
  final String narrator;

  const QuarkBookMeta({
    required this.title,
    required this.author,
    required this.narrator,
  });
}

class QuarkBook {
  final String title;
  final String author;
  final String narrator;
  final String cover;
  final String fid;
  final List<QuarkPanItem> audioFiles;

  const QuarkBook({
    required this.title,
    required this.author,
    required this.narrator,
    required this.cover,
    required this.fid,
    required this.audioFiles,
  });
}

/// 夸克网盘后端:内置 WebView 登录拿 Cookie;用文件 fid 浏览和播放。
class QuarkPanService extends ChangeNotifier {
  QuarkPanService._();
  static final instance = QuarkPanService._();

  static const _kConfig = 'quark_pan_config';
  // 配置(含登录 Cookie)的加密存储键;明文旧键由 SecureStore 迁移后删除。
  static const _kConfigSecure = 'sec.quark_pan_config';
  static const rootFid = '0';
  static const _pageSize = 200;
  static const _maxAutoPages = 300;
  static const _pcUa =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/121.0.0.0 Safari/537.36';
  static const _apiBase = 'https://drive-pc.quark.cn/1/clouddrive';
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
  String _cookie = '';

  String get pcUserAgent => _pcUa;
  String get cookie => _cookie;
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
    } catch (e) {
      LogService.instance.warning('QuarkPan', '读取配置失败', detail: '$e');
    }
  }

  Future<void> _persist() async {
    await SecureStore.instance.write(
      _kConfigSecure,
      jsonEncode({'cookie': _cookie}),
    );
  }

  Future<void> saveCookie(String cookie) async {
    _cookie = cookie.trim();
    await _persist();
    LogService.instance.info(
      'QuarkPan',
      '已保存登录 Cookie',
      detail: '长度: ${_cookie.length}\n字段: ${_cookieSummary(_cookie)}',
    );
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

  Future<bool> checkLogin() async {
    if (_cookie.isEmpty) return false;
    try {
      await listPage(rootFid, page: 1);
      LogService.instance.info('QuarkPan', '登录状态检测通过');
      return true;
    } catch (e) {
      LogService.instance.warning('QuarkPan', '登录状态检测失败', detail: '$e');
      return false;
    }
  }

  QuarkBookMeta? parseBookFolderName(String name) {
    final parts = name
        .split(RegExp(r'_+'))
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty)
        .toList(growable: false);
    if (parts.length < 3) return null;
    return QuarkBookMeta(
      title: parts.first,
      author: parts[1],
      narrator: parts.sublist(2).join('_'),
    );
  }

  Future<List<QuarkPanItem>> list(String fid) async {
    final all = <QuarkPanItem>[];
    var page = 1;
    var hasMore = true;
    while (hasMore && page <= _maxAutoPages) {
      final result = await listPage(fid, page: page);
      all.addAll(result.items);
      hasMore = result.hasMore;
      LogService.instance.info(
        'QuarkPan',
        '目录分页读取',
        detail:
            'FID: $fid\n页码: ${result.page}\n本页: ${result.items.length}\n累计: ${all.length}\n总数: ${result.total > 0 ? result.total : '未知'}\n继续: ${result.hasMore ? '是' : '否'}',
      );
      page++;
      if (hasMore) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    }
    if (hasMore) {
      LogService.instance.warning(
        'QuarkPan',
        '目录页数超过保护上限，已停止继续读取',
        detail: 'FID: $fid\n已读取页数: $_maxAutoPages\n累计条目: ${all.length}',
      );
    }
    all.sort(_compareItems);
    LogService.instance.info(
      'QuarkPan',
      '列目录完成',
      detail: 'FID: $fid\n条目: ${all.length}\n页数: ${page - 1}',
    );
    return all;
  }

  Future<QuarkPanPage> listPage(String fid, {int page = 1}) async {
    if (_cookie.isEmpty) throw Exception('请先登录夸克网盘');
    LogService.instance.info(
      'QuarkPan',
      '请求目录页',
      detail: 'FID: $fid\n页码: $page\n每页: $_pageSize',
    );
    final resp = await _dio.get<String>(
      '$_apiBase/file/sort',
      queryParameters: {
        'pr': 'ucpro',
        'fr': 'pc',
        'uc_param_str': '',
        'pdir_fid': fid,
        '_page': page,
        '_size': _pageSize,
        '_fetch_total': 1,
        '_fetch_sub_dirs': 0,
        '_sort': 'file_type:asc,file_name:asc',
      },
      options: Options(
        headers: _headers(),
        responseType: ResponseType.plain,
        validateStatus: (_) => true,
      ),
    );
    if ((resp.statusCode ?? 0) >= 400) {
      throw Exception('夸克目录请求失败 HTTP ${resp.statusCode}\nFID: $fid\n页码: $page');
    }
    final data = _decodeBody(resp.data ?? '{}');
    _ensureOk(data);
    final payload = _payload(data);
    final rawList = _extractList(payload);
    final items =
        rawList.map(_itemFromMap).where((e) => e.fid.isNotEmpty).toList()
          ..sort(_compareItems);
    final total = _extractTotal(payload);
    return QuarkPanPage(
      items: items,
      page: page,
      pageSize: _pageSize,
      hasMore: total > 0 ? page * _pageSize < total : items.length >= _pageSize,
      total: total,
    );
  }

  Future<List<QuarkPanItem>> collectAudioFiles(String folderFid) async {
    final out = <QuarkPanItem>[];
    await _collect(folderFid, out, 0);
    return out;
  }

  Future<void> _collect(String fid, List<QuarkPanItem> out, int depth) async {
    if (depth > 3) return;
    final items = await list(fid);
    final audios =
        items.where((e) => !e.isDirectory && isAudioFile(e.name)).toList()
          ..sort((a, b) => _naturalCompare(a.name, b.name));
    out.addAll(audios);
    final subs = items.where((e) => e.isDirectory).toList()
      ..sort((a, b) => _naturalCompare(a.name, b.name));
    for (final sub in subs) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await _collect(sub.fid, out, depth + 1);
    }
  }

  Future<QuarkBook> toBook(
    String folderFid, {
    required String folderName,
  }) async {
    final meta = parseBookFolderName(folderName);
    final topItems = await list(folderFid);
    final audios = await collectAudioFiles(folderFid);
    final cover = await resolveBookCover(topItems, audios, bookFid: folderFid);
    return QuarkBook(
      title: meta?.title ?? folderName,
      author: meta?.author ?? '',
      narrator: meta?.narrator ?? '',
      cover: cover,
      fid: folderFid,
      audioFiles: audios,
    );
  }

  Future<CachedCatalog> refreshCatalog({
    required String bookFid,
    required String folderName,
    String fallbackCover = '',
    String fallbackAuthor = '',
  }) async {
    final book = await toBook(bookFid, folderName: folderName);
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
          chapterId: 'quark:${book.audioFiles[i].fid}',
          index: i + 1,
          name: book.audioFiles[i].name,
        ),
    ];
    await CatalogCacheService.instance.savePage(
      sourceId: 'quark',
      bookId: bookFid,
      info: info,
      chapters: chapters,
      page: 1,
      maxPage: 1,
      hasMore: false,
    );
    LogService.instance.info(
      'QuarkPan',
      '书籍目录已刷新并写入 SQLite',
      detail: '书名: ${info.title}\nFID: $bookFid\n章节数: ${chapters.length}',
    );
    return CachedCatalog(
      info: info,
      chapters: chapters,
      page: 1,
      maxPage: 1,
      hasMore: false,
    );
  }

  QuarkPanItem? findCoverItem(List<QuarkPanItem> items) {
    final covers =
        items.where((it) => !it.isDirectory && isCoverFile(it.name)).toList()
          ..sort(
            (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
          );
    return covers.isEmpty ? null : covers.first;
  }

  Future<String> resolveBookCover(
    List<QuarkPanItem> topItems,
    List<QuarkPanItem> audios, {
    required String bookFid,
  }) async {
    final coverItem = findCoverItem(topItems);
    if (coverItem != null) {
      try {
        return await cacheCover(coverItem);
      } catch (e) {
        LogService.instance.warning(
          'QuarkPan',
          '封面缓存失败，继续使用远程缩略图',
          detail: '书籍 FID: $bookFid\n封面: ${coverItem.name}\n错误: $e',
        );
        if (coverItem.thumb.isNotEmpty) return coverItem.thumb;
      }
    }
    for (final a in audios) {
      if (a.thumb.isNotEmpty) return a.thumb;
    }
    return '';
  }

  Future<String> cacheCover(QuarkPanItem coverItem) async {
    final ext = path_util.extension(coverItem.name).toLowerCase();
    final safeExt = ext.isEmpty ? '.jpg' : ext;
    final key = base64Url
        .encode(utf8.encode(coverItem.fid))
        .replaceAll(RegExp(r'=+$'), '');
    final dir = Directory(
      path_util.join((await getApplicationCacheDirectory()).path, 'covers'),
    );
    if (!await dir.exists()) await dir.create(recursive: true);
    final file = File(path_util.join(dir.path, 'quark_$key$safeExt'));
    if (await file.exists() && await file.length() > 0) return file.path;

    var url = coverItem.thumb.trim();
    var headers = _headers();
    if (url.isEmpty) {
      final audio = await _resolveDownload(coverItem.fid, playHeaders: false);
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
      'QuarkPan',
      '封面已缓存到本地',
      detail: '文件: ${coverItem.name}\n路径: ${file.path}',
    );
    return file.path;
  }

  Future<QuarkAudio> resolveAudio(String fid) async {
    return _resolveDownload(fid, playHeaders: true);
  }

  Future<QuarkAudio> _resolveDownload(
    String fid, {
    required bool playHeaders,
  }) async {
    if (_cookie.isEmpty) throw Exception('请先登录夸克网盘');
    LogService.instance.info('QuarkPan', '请求下载直链', detail: 'FID: $fid');
    final resp = await _dio.post<String>(
      '$_apiBase/file/download',
      queryParameters: {'pr': 'ucpro', 'fr': 'pc', 'uc_param_str': ''},
      data: jsonEncode({
        'fids': [fid],
      }),
      options: Options(
        headers: {
          ..._headers(),
          'Content-Type': 'application/json;charset=UTF-8',
        },
        responseType: ResponseType.plain,
        validateStatus: (_) => true,
      ),
    );
    if ((resp.statusCode ?? 0) >= 400) {
      throw Exception('夸克取直链请求失败 HTTP ${resp.statusCode}\nFID: $fid');
    }
    final data = _decodeBody(resp.data ?? '{}');
    _ensureOk(data);
    final url = _findDownloadUrl(_payload(data));
    if (url.isEmpty) throw Exception('取直链失败: ${resp.data ?? ''}');
    LogService.instance.info(
      'QuarkPan',
      '取直链完成',
      detail: 'FID: $fid\nURL: $url',
    );
    return QuarkAudio(url, playHeaders ? _playHeaders() : _headers());
  }

  Map<String, String> _headers() => {
    'User-Agent': _pcUa,
    'Cookie': _cookie,
    'Referer': 'https://pan.quark.cn/',
    'Origin': 'https://pan.quark.cn',
    'Accept': 'application/json, text/plain, */*',
  };

  Map<String, String> _playHeaders() => {
    'User-Agent': _pcUa,
    'Cookie': _cookie,
    'Referer': 'https://pan.quark.cn/',
  };

  Map<String, dynamic> _decodeBody(String body) {
    try {
      return jsonDecode(body) as Map<String, dynamic>;
    } catch (_) {
      throw Exception(
        '夸克接口返回非 JSON: ${body.length > 200 ? body.substring(0, 200) : body}',
      );
    }
  }

  void _ensureOk(Map<String, dynamic> data) {
    final code = data['code'];
    final status = data['status'];
    final okCode = code == null || code == 0 || code == '0';
    final okStatus = status == null || status == 200 || status == '200';
    if (okCode && okStatus) return;
    final message = '${data['message'] ?? data['msg'] ?? ''}';
    if (message.contains('login') || message.contains('登录')) {
      throw Exception('夸克登录状态失效，请重新登录');
    }
    throw Exception(
      '夸克网盘返回错误 code=${code ?? ''} status=${status ?? ''} ${message.isEmpty ? '' : message}',
    );
  }

  Object? _payload(Map<String, dynamic> data) => data['data'] ?? data;

  List<Map<String, dynamic>> _extractList(Object? payload) {
    if (payload is List) {
      return payload
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    }
    if (payload is Map) {
      for (final key in const ['list', 'files', 'items', 'data']) {
        final value = payload[key];
        if (value is List) {
          return value
              .whereType<Map>()
              .map((e) => Map<String, dynamic>.from(e))
              .toList();
        }
      }
    }
    return const [];
  }

  int _extractTotal(Object? payload) {
    if (payload is! Map) return 0;
    for (final key in const ['_total', 'total', 'count']) {
      final value = payload[key];
      if (value is num) return value.toInt();
      if (value is String) return int.tryParse(value) ?? 0;
    }
    return 0;
  }

  QuarkPanItem _itemFromMap(Map<String, dynamic> e) {
    final name = '${e['file_name'] ?? e['name'] ?? e['server_filename'] ?? ''}';
    final fid = '${e['fid'] ?? e['file_id'] ?? e['id'] ?? ''}';
    final dirValue = e['dir'] ?? e['isdir'] ?? e['is_dir'];
    final fileType = e['file_type'];
    final isDir =
        dirValue == true ||
        dirValue == 1 ||
        dirValue == '1' ||
        fileType == 0 ||
        fileType == '0';
    final thumb =
        '${e['thumbnail'] ?? e['thumb'] ?? e['thumb_url'] ?? e['preview_url'] ?? ''}';
    return QuarkPanItem(
      fid: fid,
      name: name,
      isDirectory: isDir,
      size: (e['size'] as num?)?.toInt() ?? int.tryParse('${e['size']}') ?? 0,
      thumb: thumb,
    );
  }

  String _findDownloadUrl(Object? payload) {
    final found = _findStringByKeys(payload, const {
      'download_url',
      'downloadUrl',
      'downloadUrlHttps',
      'url',
      'dlink',
    });
    if (found.startsWith('//')) return 'https:$found';
    return found;
  }

  String _findStringByKeys(Object? value, Set<String> keys) {
    if (value is Map) {
      for (final entry in value.entries) {
        final key = '${entry.key}';
        final raw = entry.value;
        if (keys.contains(key) && raw is String && raw.startsWith('http')) {
          return raw;
        }
      }
      for (final entry in value.entries) {
        final found = _findStringByKeys(entry.value, keys);
        if (found.isNotEmpty) return found;
      }
    } else if (value is List) {
      for (final item in value) {
        final found = _findStringByKeys(item, keys);
        if (found.isNotEmpty) return found;
      }
    }
    return '';
  }

  int _compareItems(QuarkPanItem a, QuarkPanItem b) {
    if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
    return _naturalCompare(a.name, b.name);
  }

  int _naturalCompare(String a, String b) {
    final ax = _tokens(a);
    final bx = _tokens(b);
    final len = ax.length < bx.length ? ax.length : bx.length;
    for (var i = 0; i < len; i++) {
      final cmp = ax[i].compareTo(bx[i]);
      if (cmp != 0) return cmp;
    }
    return ax.length.compareTo(bx.length);
  }

  List<String> _tokens(String value) {
    final out = <String>[];
    final lower = value.toLowerCase();
    for (final match in RegExp(r'\d+|\D+').allMatches(lower)) {
      final token = match.group(0) ?? '';
      if (token.isEmpty) continue;
      final number = int.tryParse(token);
      out.add(number == null ? token : number.toString().padLeft(12, '0'));
    }
    return out;
  }

  String _cookieSummary(String cookie) {
    final keys = cookie
        .split(';')
        .map((part) => part.trim().split('=').first.trim())
        .where((key) => key.isNotEmpty)
        .take(12)
        .toList();
    return keys.isEmpty ? '(无)' : keys.join(', ');
  }
}
