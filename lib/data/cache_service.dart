import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../source/source_manager.dart';
import 'baidu_pan_service.dart';
import 'catalog_cache_service.dart';
import 'db.dart';
import 'log_service.dart';
import 'quark_pan_service.dart';
import 'settings_service.dart';
import 'sniff_service.dart';
import 'webdav_service.dart';

class CacheClearResult {
  final int files;
  final int rows;
  final int bytes;

  CacheClearResult({
    required this.files,
    required this.rows,
    required this.bytes,
  });
}

class CachedAudioEntry {
  final String sourceId;
  final String sourceName;
  final String bookId;
  final String bookTitle;
  final String cover;
  final String chapterId;
  final String chapterName;
  final int chapterIdx;
  final String localPath;
  final int size;
  final int cachedAt;

  const CachedAudioEntry({
    required this.sourceId,
    required this.sourceName,
    required this.bookId,
    required this.bookTitle,
    required this.cover,
    required this.chapterId,
    required this.chapterName,
    required this.chapterIdx,
    required this.localPath,
    required this.size,
    required this.cachedAt,
  });

  String get key => '$sourceId::$chapterId';
}

class CachedAudioBook {
  final String sourceId;
  final String sourceName;
  final String bookId;
  final String bookTitle;
  final String cover;
  final List<CachedAudioEntry> entries;
  final int totalBytes;
  final int latestCachedAt;

  const CachedAudioBook({
    required this.sourceId,
    required this.sourceName,
    required this.bookId,
    required this.bookTitle,
    required this.cover,
    required this.entries,
    required this.totalBytes,
    required this.latestCachedAt,
  });

  String get key => '$sourceId::$bookId';
}

class CacheLibrarySnapshot {
  final List<CachedAudioBook> books;
  final int totalFiles;
  final int totalBytes;

  const CacheLibrarySnapshot({
    required this.books,
    required this.totalFiles,
    required this.totalBytes,
  });
}

class _PlaybackCacheContext {
  final String sourceId;
  final String bookId;
  final String bookTitle;
  final String cover;
  final List<Map<String, dynamic>> chapters;
  final int currentIndex;

  const _PlaybackCacheContext({
    required this.sourceId,
    required this.bookId,
    required this.bookTitle,
    required this.cover,
    required this.chapters,
    required this.currentIndex,
  });
}

class _HlsPlaylistDetected implements Exception {
  const _HlsPlaylistDetected();
}

class CacheService extends ChangeNotifier {
  CacheService._() {
    SettingsService.instance.addListener(_onSettingsChanged);
  }

  static final instance = CacheService._();

  final Dio _dio = Dio();
  Timer? _timer;
  Timer? _countdownTimer;
  bool _syncing = false;
  bool _restored = false;
  int _cacheVersion = 0;
  DateTime? _nextRunAt;

  /// 独立的倒计时标签 notifier,定时器每秒只更新此值,
  /// 不再经 [notifyListeners] 广播,避免播放页/状态栏整树重建。
  final ValueNotifier<String> countdownNotifier = ValueNotifier('');

  String _bookId = '';
  String _sourceId = '';
  String _bookTitle = '';
  String _cover = '';
  List<Map<String, dynamic>> _chapters = [];
  int _currentIndex = -1;

  bool get syncing => _syncing;
  int get cacheVersion => _cacheVersion;

  bool get countdownVisible =>
      SettingsService.instance.autoCache &&
      _bookId.isNotEmpty &&
      _currentIndex >= 0;

  Duration? get nextRunRemaining {
    final next = _nextRunAt;
    if (!countdownVisible || next == null) return null;
    final remaining = next.difference(DateTime.now());
    return remaining.isNegative ? Duration.zero : remaining;
  }

  String get countdownLabel {
    if (!countdownVisible) return '';
    if (_syncing) return '正在缓存后续章节...';
    final remaining = nextRunRemaining;
    if (remaining == null) return '等待自动缓存';
    final minutes = remaining.inMinutes.toString().padLeft(2, '0');
    final seconds = remaining.inSeconds
        .remainder(60)
        .toString()
        .padLeft(2, '0');
    return '下次自动缓存倒计时 $minutes:$seconds';
  }

  Future<String?> getCachedPath({
    required String sourceId,
    required String chapterId,
  }) async {
    final db = await getDb();
    final rows = await db.query(
      'cache_files',
      columns: ['localPath'],
      where: 'sourceId = ? AND chapterId = ?',
      whereArgs: [sourceId, chapterId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final localPath = '${rows.first['localPath'] ?? ''}';
    if (localPath.isEmpty || !File(localPath).existsSync()) {
      await db.delete(
        'cache_files',
        where: 'sourceId = ? AND chapterId = ?',
        whereArgs: [sourceId, chapterId],
      );
      _markCacheChanged();
      return null;
    }
    return localPath;
  }

  Future<Set<String>> cachedChapterIds({
    required String sourceId,
    required Iterable<String> chapterIds,
  }) async {
    final ids = chapterIds.where((id) => id.isNotEmpty).toSet();
    if (ids.isEmpty) return {};
    final db = await getDb();
    final rows = await db.query(
      'cache_files',
      columns: ['sourceId', 'chapterId', 'localPath'],
      where: 'sourceId = ?',
      whereArgs: [sourceId],
    );
    final cached = <String>{};
    var changed = false;
    for (final row in rows) {
      final chapterId = '${row['chapterId'] ?? ''}';
      if (!ids.contains(chapterId)) continue;
      final localPath = '${row['localPath'] ?? ''}';
      if (localPath.isNotEmpty && await File(localPath).exists()) {
        cached.add(chapterId);
      } else {
        await db.delete(
          'cache_files',
          where: 'sourceId = ? AND chapterId = ?',
          whereArgs: [sourceId, chapterId],
        );
        changed = true;
      }
    }
    if (changed) _markCacheChanged();
    return cached;
  }

  Future<void> removeCached({
    required String sourceId,
    required String chapterId,
  }) async {
    await removeEntries([
      CachedAudioEntry(
        sourceId: sourceId,
        sourceName: SourceManager.instance.getSourceName(sourceId),
        bookId: '',
        bookTitle: '',
        cover: '',
        chapterId: chapterId,
        chapterName: '',
        chapterIdx: 0,
        localPath: '',
        size: 0,
        cachedAt: 0,
      ),
    ]);
  }

  Future<CacheLibrarySnapshot> loadLibrary() async {
    final db = await getDb();
    final rows = await db.query(
      'cache_files',
      orderBy: 'cachedAt DESC, bookTitle COLLATE NOCASE ASC, chapterIdx ASC',
    );
    final staleKeys = <MapEntry<String, String>>[];
    final byBook = <String, List<CachedAudioEntry>>{};
    var totalBytes = 0;

    for (final row in rows) {
      final sourceId = '${row['sourceId'] ?? ''}';
      final chapterId = '${row['chapterId'] ?? ''}';
      final localPath = '${row['localPath'] ?? ''}';
      if (sourceId.isEmpty || chapterId.isEmpty || localPath.isEmpty) {
        staleKeys.add(MapEntry(sourceId, chapterId));
        continue;
      }
      final file = File(localPath);
      if (!file.existsSync()) {
        staleKeys.add(MapEntry(sourceId, chapterId));
        continue;
      }
      final rowSize = (row['size'] is num) ? (row['size'] as num).toInt() : 0;
      final fileSize = rowSize > 0 ? rowSize : file.statSync().size;
      final entry = CachedAudioEntry(
        sourceId: sourceId,
        sourceName: SourceManager.instance.getSourceName(sourceId),
        bookId: '${row['bookId'] ?? ''}',
        bookTitle: '${row['bookTitle'] ?? ''}',
        cover: '${row['cover'] ?? ''}',
        chapterId: chapterId,
        chapterName: '${row['chapterName'] ?? ''}',
        chapterIdx: (row['chapterIdx'] is num)
            ? (row['chapterIdx'] as num).toInt()
            : 0,
        localPath: localPath,
        size: fileSize,
        cachedAt: (row['cachedAt'] is num)
            ? (row['cachedAt'] as num).toInt()
            : 0,
      );
      totalBytes += fileSize;
      byBook
          .putIfAbsent('${entry.sourceId}::${entry.bookId}', () => [])
          .add(entry);
    }

    if (staleKeys.isNotEmpty) {
      for (final key in staleKeys) {
        await db.delete(
          'cache_files',
          where: 'sourceId = ? AND chapterId = ?',
          whereArgs: [key.key, key.value],
        );
      }
      _markCacheChanged();
    }

    final books = byBook.entries.map((group) {
      final entries = [...group.value]
        ..sort((a, b) => a.chapterIdx.compareTo(b.chapterIdx));
      final first = entries.first;
      final bookBytes = entries.fold<int>(0, (sum, entry) => sum + entry.size);
      final latest = entries.fold<int>(
        0,
        (current, entry) => entry.cachedAt > current ? entry.cachedAt : current,
      );
      return CachedAudioBook(
        sourceId: first.sourceId,
        sourceName: first.sourceName,
        bookId: first.bookId,
        bookTitle: first.bookTitle,
        cover: first.cover,
        entries: entries,
        totalBytes: bookBytes,
        latestCachedAt: latest,
      );
    }).toList()..sort((a, b) => b.latestCachedAt.compareTo(a.latestCachedAt));

    return CacheLibrarySnapshot(
      books: books,
      totalFiles: books.fold<int>(0, (sum, book) => sum + book.entries.length),
      totalBytes: totalBytes,
    );
  }

  Future<CacheClearResult> removeEntries(
    Iterable<CachedAudioEntry> entries,
  ) async {
    final targetKeys = entries
        .map((entry) => '${entry.sourceId}::${entry.chapterId}')
        .where((key) => key != '::')
        .toSet();
    final targets = targetKeys
        .map((key) {
          final index = key.indexOf('::');
          return MapEntry(key.substring(0, index), key.substring(index + 2));
        })
        .toList(growable: false);
    if (targets.isEmpty) {
      return CacheClearResult(files: 0, rows: 0, bytes: 0);
    }

    final db = await getDb();
    var deletedFiles = 0;
    var deletedRows = 0;
    var deletedBytes = 0;

    for (final target in targets) {
      final rows = await db.query(
        'cache_files',
        columns: ['localPath', 'size'],
        where: 'sourceId = ? AND chapterId = ?',
        whereArgs: [target.key, target.value],
      );
      for (final row in rows) {
        final localPath = '${row['localPath'] ?? ''}';
        if (localPath.isEmpty) continue;
        try {
          final deleted = await _deleteCachePath(localPath);
          deletedFiles += deleted.files;
          deletedBytes += deleted.bytes;
        } catch (e) {
          LogService.instance.warning(
            'Cache',
            '删除缓存文件失败',
            detail: '路径: $localPath\n错误: $e',
          );
        }
      }
      deletedRows += await db.delete(
        'cache_files',
        where: 'sourceId = ? AND chapterId = ?',
        whereArgs: [target.key, target.value],
      );
    }

    if (deletedRows > 0 || deletedFiles > 0) _markCacheChanged();
    LogService.instance.info(
      'Cache',
      '已删除选中缓存',
      detail:
          '条目: ${targets.length}\n删除文件: $deletedFiles\n删除索引: $deletedRows\n释放空间: $deletedBytes bytes',
    );
    return CacheClearResult(
      files: deletedFiles,
      rows: deletedRows,
      bytes: deletedBytes,
    );
  }

  void _markCacheChanged() {
    _cacheVersion++;
    notifyListeners();
  }

  void startForPlayback({
    required String sourceId,
    required String bookId,
    required String bookTitle,
    required String cover,
    required List<Map<String, dynamic>> chapters,
    required int currentIndex,
  }) {
    _sourceId = sourceId;
    _bookId = bookId;
    _bookTitle = bookTitle;
    _cover = cover;
    _chapters = chapters
        .map((chapter) => Map<String, dynamic>.from(chapter))
        .toList();
    _currentIndex = currentIndex;
    _schedule();
    unawaited(syncFollowing());
  }

  Future<bool> restorePending() async {
    if (_restored) return _bookId.isNotEmpty;
    _restored = true;
    final db = await getDb();
    final rows = await db.query('cache_state', where: 'id = 1', limit: 1);
    if (rows.isEmpty) return false;
    final row = rows.first;
    final sourceId = '${row['sourceId'] ?? ''}';
    final bookId = '${row['bookId'] ?? ''}';
    if (sourceId.isEmpty || bookId.isEmpty) return false;
    final cached = await CatalogCacheService.instance.load(
      sourceId: sourceId,
      bookId: bookId,
    );
    if (cached == null || cached.chapters.isEmpty) {
      LogService.instance.warning(
        'Cache',
        '无法恢复自动缓存任务',
        detail: 'BookID: $bookId\n音源: $sourceId\n原因: 本地目录不存在',
      );
      return false;
    }
    final chapters = cached.chapters
        .map((chapter) => chapter.toJson())
        .toList(growable: false);
    final currentChapterId = '${row['currentChapterId'] ?? ''}';
    var currentIndex = chapters.indexWhere(
      (chapter) => '${chapter['chapterId'] ?? ''}' == currentChapterId,
    );
    if (currentIndex < 0) {
      currentIndex = (row['currentIndex'] as num?)?.toInt() ?? 0;
    }
    currentIndex = currentIndex.clamp(0, chapters.length - 1);
    _sourceId = sourceId;
    _bookId = bookId;
    _bookTitle = '${row['bookTitle'] ?? cached.info.title}';
    _cover = '${row['cover'] ?? cached.info.cover}';
    _chapters = chapters;
    _currentIndex = currentIndex;
    final nextRunMs = (row['nextRunAt'] as num?)?.toInt() ?? 0;
    _schedule(
      preferredRunAt: nextRunMs > 0
          ? DateTime.fromMillisecondsSinceEpoch(nextRunMs)
          : null,
    );
    LogService.instance.info(
      'Cache',
      '自动缓存任务已恢复',
      detail:
          '书名: $_bookTitle\n章节: ${chapters[currentIndex]['name'] ?? ''}\n后续章节: ${chapters.length - currentIndex - 1}',
    );
    return true;
  }

  Future<void> _persistState() async {
    if (_sourceId.isEmpty ||
        _bookId.isEmpty ||
        _currentIndex < 0 ||
        _currentIndex >= _chapters.length) {
      return;
    }
    final db = await getDb();
    await db.insert('cache_state', {
      'id': 1,
      'sourceId': _sourceId,
      'bookId': _bookId,
      'bookTitle': _bookTitle,
      'cover': _cover,
      'currentChapterId': '${_chapters[_currentIndex]['chapterId'] ?? ''}',
      'currentIndex': _currentIndex,
      'nextRunAt': _nextRunAt?.millisecondsSinceEpoch,
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  _PlaybackCacheContext? _snapshotContext() {
    if (_sourceId.isEmpty || _bookId.isEmpty || _currentIndex < 0) return null;
    return _PlaybackCacheContext(
      sourceId: _sourceId,
      bookId: _bookId,
      bookTitle: _bookTitle,
      cover: _cover,
      chapters: _chapters
          .map((chapter) => Map<String, dynamic>.from(chapter))
          .toList(growable: false),
      currentIndex: _currentIndex,
    );
  }

  bool _samePlaybackContext(_PlaybackCacheContext context) {
    return context.sourceId == _sourceId &&
        context.bookId == _bookId &&
        context.currentIndex == _currentIndex;
  }

  void _onSettingsChanged() {
    _schedule();
    unawaited(cleanup());
    unawaited(syncFollowing());
  }

  void _schedule({DateTime? preferredRunAt}) {
    _timer?.cancel();
    _timer = null;
    final settings = SettingsService.instance;
    if (!settings.autoCache || _bookId.isEmpty || _currentIndex < 0) {
      _nextRunAt = null;
      _stopCountdownTicker();
      unawaited(_persistState());
      notifyListeners();
      return;
    }
    final interval = Duration(minutes: settings.cacheFrequencyMinutes);
    final now = DateTime.now();
    final requested = preferredRunAt ?? now.add(interval);
    final delay = requested.isAfter(now)
        ? requested.difference(now)
        : const Duration(seconds: 3);
    _nextRunAt = now.add(delay);
    unawaited(_persistState());
    // 更新倒计时标签首帧,然后启 ticker
    countdownNotifier.value = countdownLabel;
    _startCountdownTicker();
    notifyListeners();
    LogService.instance.info(
      'Cache',
      '启动自动缓存定时器',
      detail:
          '频率: ${settings.cacheFrequencyLabel}\n后续章节数: ${settings.maxCacheChapters}',
    );
    _timer = Timer(delay, () async {
      await syncFollowing();
      _schedule();
    });
  }

  void _startCountdownTicker() {
    _countdownTimer ??= Timer.periodic(
      const Duration(seconds: 1),
      (_) => _tickCountdown(),
    );
  }

  void _tickCountdown() {
    countdownNotifier.value = countdownLabel;
  }

  void _stopCountdownTicker() {
    _countdownTimer?.cancel();
    _countdownTimer = null;
    countdownNotifier.value = '';
  }

  Future<void> triggerNow() async {
    if (!countdownVisible || _syncing) return;
    _timer?.cancel();
    _timer = null;
    _nextRunAt = null;
    notifyListeners();
    LogService.instance.info(
      'Cache',
      '手动触发后续章节缓存',
      detail: '书名: $_bookTitle\n音源: $_sourceId\n当前章节序号: ${_currentIndex + 1}',
    );
    await syncFollowing();
    _schedule();
  }

  Future<void> syncFollowing() async {
    final settings = SettingsService.instance;
    if (!settings.autoCache ||
        _syncing ||
        _bookId.isEmpty ||
        _currentIndex < 0) {
      return;
    }
    final context = _snapshotContext();
    if (context == null) return;
    _syncing = true;
    notifyListeners();
    try {
      final start = context.currentIndex + 1;
      final end = (start + settings.maxCacheChapters).clamp(
        0,
        context.chapters.length,
      );
      LogService.instance.info(
        'Cache',
        '开始同步后续章节缓存',
        detail:
            '书名: ${context.bookTitle}\n范围: ${start + 1} - $end\n上限: ${settings.maxCacheChapters}',
      );
      for (var i = start; i < end; i++) {
        if (!_samePlaybackContext(context)) {
          LogService.instance.info(
            'Cache',
            '播放上下文已变化，停止本轮缓存',
            detail: '书名: ${context.bookTitle}',
          );
          break;
        }
        final chapter = context.chapters[i];
        final chapterId = '${chapter['chapterId'] ?? ''}';
        if (chapterId.isEmpty ||
            await getCachedPath(
                  sourceId: context.sourceId,
                  chapterId: chapterId,
                ) !=
                null) {
          continue;
        }
        try {
          await _downloadChapter(context, chapter, i);
        } catch (e, stack) {
          LogService.instance.error(
            'Cache',
            '章节缓存失败，继续后续任务',
            error: e,
            stack: stack,
          );
        }
      }
      await cleanup();
    } finally {
      _syncing = false;
      notifyListeners();
    }
  }

  Future<void> _downloadChapter(
    _PlaybackCacheContext context,
    Map<String, dynamic> chapter,
    int index,
  ) async {
    final chapterId = '${chapter['chapterId'] ?? ''}';
    var audioUrl = '${chapter['audioUrl'] ?? ''}';
    var audioHeaders = <String, String>{};
    final rawHeaders = chapter['audioHeaders'];
    if (rawHeaders is Map) {
      rawHeaders.forEach((key, value) => audioHeaders['$key'] = '$value');
    }
    if (audioUrl.isEmpty && context.sourceId == 'webdav') {
      final webdavPath = chapterId.startsWith('webdav:')
          ? chapterId.substring('webdav:'.length)
          : chapterId;
      audioUrl = WebDavService.instance.resolveUrl(webdavPath);
      audioHeaders = WebDavService.instance.headersForPath(webdavPath);
    }
    if (audioUrl.isEmpty && chapterId.startsWith('baidu:')) {
      final audio = await BaiduPanService.instance.resolveAudio(
        chapterId.substring('baidu:'.length),
      );
      audioUrl = audio.url;
      audioHeaders = audio.headers;
    }
    if (audioUrl.isEmpty && chapterId.startsWith('quark:')) {
      final audio = await QuarkPanService.instance.resolveAudio(
        chapterId.substring('quark:'.length),
      );
      audioUrl = audio.url;
      audioHeaders = audio.headers;
    }
    if (audioUrl.isEmpty) {
      final audio = context.sourceId.isNotEmpty
          ? await SourceManager.instance.getAudioUrlFromSource(
              context.sourceId,
              chapterId,
            )
          : await SourceManager.instance.getAudioUrl(chapterId);
      if (audio.needsSniff) {
        final sniffed = await SniffService.instance.sniff(audio.sniff!);
        audioUrl = sniffed.url;
        audioHeaders = sniffed.headers;
      } else {
        audioUrl = audio.url;
        audioHeaders = audio.headers;
      }
    }
    LogService.instance.info(
      'Cache',
      '开始下载章节缓存',
      detail:
          '书名: ${context.bookTitle}\n章节: ${chapter['name'] ?? ''}\nURL: $audioUrl',
    );
    final dir = await _cacheDir();
    final file = File(
      path.join(
        dir.path,
        '${_fileName(context.sourceId, chapterId)}${_extension(audioUrl)}',
      ),
    );
    final tmp = File('${file.path}.tmp');
    if (tmp.existsSync()) tmp.deleteSync();
    late File cachedFile;

    try {
      if (_isHlsUrl(audioUrl)) {
        cachedFile = await _downloadHls(
          cacheDir: dir,
          cacheKey: _fileName(context.sourceId, chapterId),
          playlistUrl: audioUrl,
          headers: audioHeaders,
        );
      } else {
        try {
          final response = await _dio.download(
            audioUrl,
            tmp.path,
            options: Options(
              headers: audioHeaders.isEmpty ? null : audioHeaders,
              receiveTimeout: const Duration(seconds: 30),
            ),
          );
          await _validateDownloadedAudio(tmp, response);
          if (file.existsSync()) file.deleteSync();
          cachedFile = await tmp.rename(file.path);
        } on _HlsPlaylistDetected {
          final initialPlaylist = await tmp.readAsString();
          await tmp.delete();
          cachedFile = await _downloadHls(
            cacheDir: dir,
            cacheKey: _fileName(context.sourceId, chapterId),
            playlistUrl: audioUrl,
            headers: audioHeaders,
            initialPlaylist: initialPlaylist,
          );
        }
      }
    } on DioException catch (e) {
      if (tmp.existsSync()) {
        try {
          await tmp.delete();
        } catch (_) {}
      }
      LogService.instance.warning(
        'Cache',
        '章节缓存下载请求失败',
        detail:
            '章节: ${chapter['name'] ?? ''}\n状态码: ${e.response?.statusCode ?? '无'}\nURL: $audioUrl\nHeaders: ${jsonEncode(_redactedHeaders(audioHeaders))}',
      );
      rethrow;
    } catch (_) {
      if (tmp.existsSync()) {
        try {
          await tmp.delete();
        } catch (_) {}
      }
      rethrow;
    }

    final cachedSize = await _cachePathSize(cachedFile.path);
    final db = await getDb();
    await db.insert('cache_files', {
      'sourceId': context.sourceId,
      'chapterId': chapterId,
      'bookId': context.bookId,
      'bookTitle': context.bookTitle,
      'cover': context.cover,
      'chapterName': '${chapter['name'] ?? ''}',
      'chapterIdx': index,
      'localPath': cachedFile.path,
      'sourceUrl': audioUrl,
      'size': cachedSize,
      'cachedAt': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    LogService.instance.info(
      'Cache',
      '章节缓存完成',
      detail:
          '章节: ${chapter['name'] ?? ''}\n大小: $cachedSize bytes\n路径: ${cachedFile.path}',
    );
    _markCacheChanged();
  }

  bool _isHlsUrl(String url) {
    final uri = Uri.tryParse(url);
    return uri != null && uri.path.toLowerCase().endsWith('.m3u8');
  }

  Future<File> _downloadHls({
    required Directory cacheDir,
    required String cacheKey,
    required String playlistUrl,
    required Map<String, String> headers,
    String? initialPlaylist,
  }) async {
    final finalDir = Directory(path.join(cacheDir.path, '$cacheKey.hls'));
    final tempDir = Directory(path.join(cacheDir.path, '$cacheKey.hls.tmp'));
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
    await tempDir.create(recursive: true);
    try {
      final media = await _resolveHlsMediaPlaylist(
        Uri.parse(playlistUrl),
        headers,
        initialPlaylist: initialPlaylist,
      );
      final lower = media.content.toLowerCase();
      if (!lower.contains('#ext-x-endlist')) {
        throw Exception('暂不支持缓存直播或持续更新的 HLS 列表');
      }
      if (lower.contains('#ext-x-byterange')) {
        throw Exception('暂不支持缓存使用 BYTERANGE 的 HLS 列表');
      }

      final lines = media.content.replaceAll('\r\n', '\n').split('\n');
      final rewritten = <String>[];
      var resourceIndex = 0;
      for (final rawLine in lines) {
        final line = rawLine.trim();
        if (line.isEmpty) {
          rewritten.add(rawLine);
          continue;
        }
        if (!line.startsWith('#')) {
          resourceIndex++;
          rewritten.add(
            await _downloadHlsResource(
              baseUri: media.uri,
              reference: line,
              directory: tempDir,
              index: resourceIndex,
              headers: headers,
              fallbackExtension: '.ts',
            ),
          );
          continue;
        }
        final uriMatch = RegExp(
          r'URI="([^"]+)"',
          caseSensitive: false,
        ).firstMatch(rawLine);
        if (uriMatch == null) {
          rewritten.add(rawLine);
          continue;
        }
        resourceIndex++;
        final localName = await _downloadHlsResource(
          baseUri: media.uri,
          reference: uriMatch.group(1)!,
          directory: tempDir,
          index: resourceIndex,
          headers: headers,
          fallbackExtension: line.toLowerCase().startsWith('#ext-x-key')
              ? '.key'
              : '.bin',
        );
        rewritten.add(rawLine.replaceFirst(uriMatch.group(1)!, localName));
      }
      if (resourceIndex == 0) throw Exception('HLS 列表中没有可缓存的媒体分片');
      final playlist = File(path.join(tempDir.path, 'index.m3u8'));
      await playlist.writeAsString(rewritten.join('\n'), flush: true);
      if (finalDir.existsSync()) await finalDir.delete(recursive: true);
      final renamed = await tempDir.rename(finalDir.path);
      final localPlaylist = File(path.join(renamed.path, 'index.m3u8'));
      LogService.instance.info(
        'Cache',
        'HLS 分片缓存完成',
        detail: '分片及资源: $resourceIndex\n目录: ${renamed.path}',
      );
      return localPlaylist;
    } catch (_) {
      if (tempDir.existsSync()) {
        try {
          await tempDir.delete(recursive: true);
        } catch (_) {}
      }
      rethrow;
    }
  }

  @visibleForTesting
  Future<File> downloadHlsForTesting({
    required Directory cacheDir,
    required String playlistUrl,
    Map<String, String> headers = const {},
  }) {
    return _downloadHls(
      cacheDir: cacheDir,
      cacheKey: 'test_hls',
      playlistUrl: playlistUrl,
      headers: headers,
    );
  }

  Future<({Uri uri, String content})> _resolveHlsMediaPlaylist(
    Uri initialUri,
    Map<String, String> headers, {
    String? initialPlaylist,
  }) async {
    var uri = initialUri;
    var content = initialPlaylist ?? await _fetchHlsPlaylist(uri, headers);
    for (var depth = 0; depth < 3; depth++) {
      final lines = content.replaceAll('\r\n', '\n').split('\n');
      final audioPlaylists = <String>[];
      final variants = <({String url, int bandwidth, bool audioOnly})>[];
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i].trim();
        if (line.toUpperCase().startsWith('#EXT-X-MEDIA:') &&
            line.toUpperCase().contains('TYPE=AUDIO')) {
          final match = RegExp(
            r'URI="([^"]+)"',
            caseSensitive: false,
          ).firstMatch(line);
          if (match != null) audioPlaylists.add(match.group(1)!);
        }
        if (!line.toUpperCase().startsWith('#EXT-X-STREAM-INF:')) continue;
        final bandwidth =
            int.tryParse(
              RegExp(
                    r'BANDWIDTH=(\d+)',
                    caseSensitive: false,
                  ).firstMatch(line)?.group(1) ??
                  '',
            ) ??
            0;
        final codecs =
            RegExp(
              r'CODECS="([^"]+)"',
              caseSensitive: false,
            ).firstMatch(line)?.group(1)?.toLowerCase() ??
            '';
        final hasAudioCodec =
            codecs.contains('mp4a') ||
            codecs.contains('opus') ||
            codecs.contains('vorbis') ||
            codecs.contains('ac-3') ||
            codecs.contains('ec-3');
        final hasVideoCodec =
            codecs.contains('avc') ||
            codecs.contains('hvc') ||
            codecs.contains('hev') ||
            codecs.contains('vp9') ||
            codecs.contains('av01');
        for (var j = i + 1; j < lines.length; j++) {
          final candidate = lines[j].trim();
          if (candidate.isEmpty) continue;
          if (!candidate.startsWith('#')) {
            variants.add((
              url: candidate,
              bandwidth: bandwidth,
              audioOnly: hasAudioCodec && !hasVideoCodec,
            ));
          }
          break;
        }
      }
      String? child;
      if (audioPlaylists.isNotEmpty) {
        child = audioPlaylists.first;
      } else if (variants.isNotEmpty) {
        final audioOnly = variants
            .where((variant) => variant.audioOnly)
            .toList();
        if (audioOnly.isNotEmpty) {
          audioOnly.sort((a, b) => b.bandwidth.compareTo(a.bandwidth));
          child = audioOnly.first.url;
        } else {
          variants.sort((a, b) => a.bandwidth.compareTo(b.bandwidth));
          child = variants.first.url;
        }
      }
      if (child == null) return (uri: uri, content: content);
      uri = uri.resolve(child);
      content = await _fetchHlsPlaylist(uri, headers);
    }
    throw Exception('HLS 主列表嵌套层级过深');
  }

  Future<String> _fetchHlsPlaylist(Uri uri, Map<String, String> headers) async {
    final response = await _dio.get<String>(
      uri.toString(),
      options: Options(
        headers: headers.isEmpty ? null : headers,
        responseType: ResponseType.plain,
        receiveTimeout: const Duration(seconds: 30),
      ),
    );
    final content = response.data ?? '';
    if (!content.trimLeft().toLowerCase().startsWith('#extm3u')) {
      throw Exception('HLS 播放列表格式无效');
    }
    return content;
  }

  Future<String> _downloadHlsResource({
    required Uri baseUri,
    required String reference,
    required Directory directory,
    required int index,
    required Map<String, String> headers,
    required String fallbackExtension,
  }) async {
    final resourceUri = baseUri.resolve(reference);
    final ext = path.extension(resourceUri.path).toLowerCase();
    final safeExt = ext.length > 1 && ext.length <= 8 ? ext : fallbackExtension;
    final name = 'resource_${index.toString().padLeft(5, '0')}$safeExt';
    final file = File(path.join(directory.path, name));
    final response = await _dio.download(
      resourceUri.toString(),
      file.path,
      options: Options(
        headers: headers.isEmpty ? null : headers,
        receiveTimeout: const Duration(seconds: 30),
      ),
    );
    final statusCode = response.statusCode ?? 0;
    if (statusCode < 200 || statusCode >= 300 || await file.length() <= 0) {
      throw Exception('HLS 资源下载失败: HTTP $statusCode');
    }
    return name;
  }

  Future<void> _validateDownloadedAudio(
    File file,
    Response<dynamic> response,
  ) async {
    final statusCode = response.statusCode ?? 0;
    if (statusCode < 200 || statusCode >= 300) {
      throw Exception('下载响应状态异常: HTTP $statusCode');
    }
    final stat = await file.stat();
    final contentType =
        (response.headers.value(Headers.contentTypeHeader) ?? '')
            .split(';')
            .first
            .trim()
            .toLowerCase();
    final handle = await file.open();
    late final List<int> prefixBytes;
    try {
      prefixBytes = await handle.read(512);
    } finally {
      await handle.close();
    }
    final prefix = latin1
        .decode(prefixBytes, allowInvalid: true)
        .replaceFirst('ï»¿', '')
        .replaceFirst('\ufeff', '')
        .trimLeft()
        .toLowerCase();
    final knownAudioSignature = _hasAudioSignature(prefixBytes);
    final hlsPlaylist =
        contentType.contains('mpegurl') || prefix.startsWith('#extm3u');
    if (hlsPlaylist) {
      throw const _HlsPlaylistDetected();
    }
    if (stat.size < 256) {
      throw Exception('下载文件过小，疑似错误响应: ${stat.size} bytes');
    }
    final textResponse =
        contentType.startsWith('text/') ||
        contentType.contains('json') ||
        contentType.contains('xml');
    final errorDocument =
        prefix.startsWith('<!doctype html') ||
        prefix.startsWith('<html') ||
        prefix.startsWith('<?xml') ||
        prefix.startsWith('{"') ||
        prefix.startsWith('[{"') ||
        prefix.contains('<title>403') ||
        prefix.contains('<title>404') ||
        prefix.contains('access denied');
    if (errorDocument || (textResponse && !knownAudioSignature)) {
      throw Exception(
        '下载内容不是音频${contentType.isEmpty ? '' : '，Content-Type: $contentType'}',
      );
    }
  }

  bool _hasAudioSignature(List<int> bytes) {
    bool matches(int offset, List<int> signature) {
      if (bytes.length < offset + signature.length) return false;
      for (var i = 0; i < signature.length; i++) {
        if (bytes[offset + i] != signature[i]) return false;
      }
      return true;
    }

    if (matches(0, const [0x49, 0x44, 0x33]) || // ID3 / MP3
        matches(0, const [0x4f, 0x67, 0x67, 0x53]) || // OggS
        matches(0, const [0x66, 0x4c, 0x61, 0x43]) || // fLaC
        matches(0, const [0x52, 0x49, 0x46, 0x46]) || // RIFF / WAV
        matches(0, const [0x41, 0x44, 0x49, 0x46]) || // ADIF / AAC
        matches(4, const [0x66, 0x74, 0x79, 0x70]) || // ftyp / MP4
        matches(4, const [0x73, 0x74, 0x79, 0x70]) || // styp / M4S
        matches(4, const [0x6d, 0x6f, 0x6f, 0x66])) {
      return true;
    }
    return bytes.length >= 2 &&
        bytes[0] == 0xff &&
        (bytes[1] & 0xe0) == 0xe0; // MPEG/ADTS frame sync
  }

  Map<String, String> _redactedHeaders(Map<String, String> headers) {
    final redacted = <String, String>{};
    headers.forEach((key, value) {
      final normalized = key.toLowerCase();
      final sensitive =
          normalized == 'cookie' ||
          normalized == 'authorization' ||
          normalized.contains('token') ||
          normalized.contains('secret') ||
          normalized.contains('api-key') ||
          normalized.contains('apikey');
      redacted[key] = sensitive ? '***' : value;
    });
    return redacted;
  }

  Directory? _hlsRootForPath(String localPath) {
    final file = File(localPath);
    final parent = file.parent;
    if (path.basename(file.path).toLowerCase() == 'index.m3u8' &&
        parent.path.toLowerCase().endsWith('.hls')) {
      return parent;
    }
    return null;
  }

  int _cachePathSizeSync(String localPath) {
    final hlsRoot = _hlsRootForPath(localPath);
    if (hlsRoot != null && hlsRoot.existsSync()) {
      var bytes = 0;
      for (final entity in hlsRoot.listSync(recursive: true)) {
        if (entity is! File) continue;
        try {
          bytes += entity.lengthSync();
        } catch (_) {}
      }
      return bytes;
    }
    final file = File(localPath);
    if (!file.existsSync()) return 0;
    try {
      return file.lengthSync();
    } catch (_) {
      return 0;
    }
  }

  Future<int> _cachePathSize(String localPath) async {
    return _cachePathSizeSync(localPath);
  }

  Future<({int files, int bytes})> _deleteCachePath(String localPath) async {
    final hlsRoot = _hlsRootForPath(localPath);
    if (hlsRoot != null && hlsRoot.existsSync()) {
      var files = 0;
      var bytes = 0;
      for (final entity in hlsRoot.listSync(recursive: true)) {
        if (entity is! File) continue;
        files++;
        try {
          bytes += entity.lengthSync();
        } catch (_) {}
      }
      await hlsRoot.delete(recursive: true);
      return (files: files, bytes: bytes);
    }
    final file = File(localPath);
    if (!file.existsSync()) return (files: 0, bytes: 0);
    final bytes = await file.length();
    await file.delete();
    return (files: 1, bytes: bytes);
  }

  Future<void> cleanup() async {
    final settings = SettingsService.instance;
    final countLimit = settings.cleanupLimit;
    final byteLimit = settings.cacheSpaceLimit <= 0
        ? 0
        : settings.cacheSpaceLimit * 1024 * 1024;
    if (countLimit == 0 && byteLimit == 0) return;
    final db = await getDb();
    final rows = await db.query('cache_files', orderBy: 'cachedAt ASC');
    int rowSize(Map<String, Object?> row) {
      final stored = (row['size'] as num?)?.toInt() ?? 0;
      if (stored > 0) return stored;
      final localPath = '${row['localPath'] ?? ''}';
      if (localPath.isEmpty) return 0;
      return _cachePathSizeSync(localPath);
    }

    var totalBytes = rows.fold<int>(0, (sum, row) => sum + rowSize(row));
    var remainingCount = rows.length;
    final removeRows = <Map<String, Object?>>[];
    for (final row in rows) {
      final overCount = countLimit > 0 && remainingCount > countLimit;
      final overSpace = byteLimit > 0 && totalBytes > byteLimit;
      if (!overCount && !overSpace) break;
      removeRows.add(row);
      remainingCount--;
      totalBytes -= rowSize(row);
    }
    if (removeRows.isEmpty) return;
    var deleted = false;
    LogService.instance.info(
      'Cache',
      '开始清理缓存',
      detail:
          '当前数量: ${rows.length}\n集数上限: ${countLimit == 0 ? '不限制' : countLimit}\n空间上限: ${settings.cacheSpaceLimitLabel}\n删除数量: ${removeRows.length}',
    );
    for (final row in removeRows) {
      final localPath = '${row['localPath'] ?? ''}';
      if (localPath.isNotEmpty) {
        try {
          await _deleteCachePath(localPath);
        } catch (_) {}
      }
      await db.delete(
        'cache_files',
        where: 'sourceId = ? AND chapterId = ?',
        whereArgs: ['${row['sourceId'] ?? ''}', '${row['chapterId']}'],
      );
      deleted = true;
    }
    if (deleted) _markCacheChanged();
  }

  Future<CacheClearResult> clearAllAudioCache() async {
    final db = await getDb();
    var deletedFiles = 0;
    var deletedBytes = 0;

    final dir = await _cacheDir();
    if (dir.existsSync()) {
      for (final entity in dir.listSync(recursive: true)) {
        if (entity is! File) continue;
        deletedFiles++;
        try {
          deletedBytes += entity.lengthSync();
        } catch (_) {}
      }
      await dir.delete(recursive: true);
      await dir.create(recursive: true);
    }

    final deletedRows = await db.delete('cache_files');
    if (deletedRows > 0 || deletedFiles > 0) _markCacheChanged();
    LogService.instance.info(
      'Cache',
      '音频缓存已卸载',
      detail:
          '删除文件: $deletedFiles\n删除索引: $deletedRows\n释放空间: $deletedBytes bytes',
    );
    return CacheClearResult(
      files: deletedFiles,
      rows: deletedRows,
      bytes: deletedBytes,
    );
  }

  Future<Directory> _cacheDir() async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory(path.join(base.path, 'audio_cache'));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  String _fileName(String sourceId, String chapterId) {
    return base64Url
        .encode(utf8.encode('$sourceId::$chapterId'))
        .replaceAll('=', '');
  }

  String _extension(String url) {
    final ext = path.extension(Uri.tryParse(url)?.path ?? '').toLowerCase();
    if (ext.length > 1 && ext.length <= 6) return ext;
    return '.audio';
  }
}
