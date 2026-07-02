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

class CacheService extends ChangeNotifier {
  CacheService._() {
    SettingsService.instance.addListener(_onSettingsChanged);
  }

  static final instance = CacheService._();

  final Dio _dio = Dio();
  Timer? _timer;
  Timer? _countdownTimer;
  bool _syncing = false;
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
      if (localPath.isNotEmpty && File(localPath).existsSync()) {
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
        final file = File(localPath);
        if (!file.existsSync()) continue;
        try {
          final stat = file.statSync();
          await file.delete();
          deletedFiles++;
          deletedBytes += stat.size;
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

  void _schedule() {
    _timer?.cancel();
    _timer = null;
    final settings = SettingsService.instance;
    if (!settings.autoCache || _bookId.isEmpty || _currentIndex < 0) {
      _nextRunAt = null;
      _stopCountdownTicker();
      notifyListeners();
      return;
    }
    final interval = Duration(minutes: settings.cacheFrequencyMinutes);
    _nextRunAt = DateTime.now().add(interval);
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
    _timer = Timer(interval, () async {
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

    try {
      await _dio.download(
        audioUrl,
        tmp.path,
        options: Options(
          headers: audioHeaders.isEmpty ? null : audioHeaders,
          receiveTimeout: const Duration(seconds: 30),
        ),
      );
      final tmpStat = await tmp.stat();
      if (tmpStat.size <= 0) throw Exception('下载文件大小为 0');
      if (file.existsSync()) file.deleteSync();
      await tmp.rename(file.path);
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
            '章节: ${chapter['name'] ?? ''}\n状态码: ${e.response?.statusCode ?? '无'}\nURL: $audioUrl\nHeaders: ${jsonEncode(audioHeaders)}',
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

    final stat = await file.stat();
    final db = await getDb();
    await db.insert('cache_files', {
      'sourceId': context.sourceId,
      'chapterId': chapterId,
      'bookId': context.bookId,
      'bookTitle': context.bookTitle,
      'cover': context.cover,
      'chapterName': '${chapter['name'] ?? ''}',
      'chapterIdx': index,
      'localPath': file.path,
      'sourceUrl': audioUrl,
      'size': stat.size,
      'cachedAt': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    LogService.instance.info(
      'Cache',
      '章节缓存完成',
      detail:
          '章节: ${chapter['name'] ?? ''}\n大小: ${stat.size} bytes\n路径: ${file.path}',
    );
    _markCacheChanged();
  }

  Future<void> cleanup() async {
    final limit = SettingsService.instance.cleanupLimit;
    if (limit == 0) return;
    final db = await getDb();
    final rows = await db.query('cache_files', orderBy: 'cachedAt ASC');
    if (rows.length <= limit) return;
    final removeRows = rows.take(rows.length - limit);
    var deleted = false;
    LogService.instance.info(
      'Cache',
      '开始清理缓存',
      detail:
          '当前数量: ${rows.length}\n保留数量: $limit\n删除数量: ${rows.length - limit}',
    );
    for (final row in removeRows) {
      final localPath = '${row['localPath'] ?? ''}';
      if (localPath.isNotEmpty) {
        final file = File(localPath);
        if (file.existsSync()) {
          try {
            file.deleteSync();
          } catch (_) {}
        }
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
    final rows = await db.query('cache_files');
    final paths = <String>{};
    var deletedFiles = 0;
    var deletedBytes = 0;

    for (final row in rows) {
      final localPath = '${row['localPath'] ?? ''}';
      if (localPath.isNotEmpty) paths.add(localPath);
    }

    final dir = await _cacheDir();
    if (dir.existsSync()) {
      for (final entity in dir.listSync(recursive: true)) {
        if (entity is File) paths.add(entity.path);
      }
    }

    for (final filePath in paths) {
      final file = File(filePath);
      if (!file.existsSync()) continue;
      try {
        final stat = file.statSync();
        await file.delete();
        deletedFiles++;
        deletedBytes += stat.size;
      } catch (e) {
        LogService.instance.warning(
          'Cache',
          '删除缓存文件失败',
          detail: '路径: $filePath\n错误: $e',
        );
      }
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
