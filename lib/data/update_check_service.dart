import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../source/source_manager.dart';
import 'alist_service.dart';
import 'baidu_pan_service.dart';
import 'catalog_cache_service.dart';
import 'log_service.dart';
import 'quark_pan_service.dart';
import 'shelf_service.dart';

/// 书架追更:对标记「未完结·追更」的书做增量更新检查,有新章才补目录并
/// 发系统通知。
///
/// 每本书一次最小请求判断有无更新:
/// - JS 源:getChapters(page=1) 对比缓存 maxPage,增长只拉最后一页补录;
/// - 百度/夸克:listPage(page=1) 自带 total,顶层条目增长才 refreshCatalog;
/// - AList:list 即全量,refreshCatalog 重建后按章节数差值计数;
/// - WebDAV:PROPFIND 单层无可靠增量信号,暂不支持。
///
/// 检查仅在前台进行(启动延迟 + 每 6 小时 + 书架手动按钮),App 被杀后不检查。
class UpdateCheckService extends ChangeNotifier {
  UpdateCheckService._();
  static final instance = UpdateCheckService._();

  static const _channel = MethodChannel('tingshu/update_notify');
  static const _startupDelay = Duration(minutes: 2);
  static const _checkInterval = Duration(hours: 6);
  static const _perBookGap = Duration(milliseconds: 2000);

  final Random _random = Random();
  bool _checking = false;
  bool _ready = false;

  bool get checking => _checking;

  void init() {
    if (_ready) return;
    _ready = true;
    Timer(_startupDelay, () {
      unawaited(checkAll(reason: 'startup'));
      Timer.periodic(
        _checkInterval,
        (_) => unawaited(checkAll(reason: 'periodic')),
      );
    });
  }

  /// 检查所有追更书,返回有更新的书数量。
  Future<int> checkAll({String reason = 'manual'}) async {
    if (_checking) return 0;
    final books = (await ShelfService.instance.list())
        .where((book) => book.followUpdates)
        .toList();
    if (books.isEmpty) return 0;
    _checking = true;
    notifyListeners();
    var updatedBooks = 0;
    try {
      for (final book in books) {
        var added = 0;
        try {
          added = await _checkBook(book);
        } catch (e) {
          LogService.instance.warning(
            'UpdateCheck',
            '检查更新失败',
            detail: '书名: ${book.title}\n音源: ${book.sourceId}\n错误: $e',
          );
        }
        if (added > 0) {
          updatedBooks++;
          await notify(
            title: '《${book.title}》有更新',
            body: '新增 $added 集，打开橘听继续收听',
          );
        }
        await Future<void>.delayed(
          _perBookGap + Duration(milliseconds: _random.nextInt(1500)),
        );
      }
      LogService.instance.info(
        'UpdateCheck',
        '追更检查完成($reason)',
        detail: '检查: ${books.length} 本 · 有更新: $updatedBooks 本',
      );
    } finally {
      _checking = false;
      notifyListeners();
    }
    return updatedBooks;
  }

  Future<int> _checkBook(ShelfBook book) async {
    switch (book.sourceId) {
      case 'baidu':
        return _checkPan(
          book,
          currentTotal: (await BaiduPanService.instance.listPage(
            book.bookId,
            page: 1,
          )).total,
          refresh: () => BaiduPanService.instance.refreshCatalog(
            bookPath: book.bookId,
            fallbackCover: book.cover,
            fallbackAuthor: book.author,
          ),
        );
      case 'quark':
        return _checkPan(
          book,
          currentTotal: (await QuarkPanService.instance.listPage(
            book.bookId,
            page: 1,
          )).total,
          refresh: () => QuarkPanService.instance.refreshCatalog(
            bookFid: book.bookId,
            folderName: book.title,
            fallbackCover: book.cover,
            fallbackAuthor: book.author,
          ),
        );
      case 'alist':
        return _checkAlist(book);
      case 'webdav':
        return 0;
      default:
        return _checkJsSource(book);
    }
  }

  /// JS 源:page=1 一次请求对比缓存 maxPage;增长则只拉最后一页增量补录。
  Future<int> _checkJsSource(ShelfBook book) async {
    final cached = await CatalogCacheService.instance.loadMeta(
      sourceId: book.sourceId,
      bookId: book.bookId,
    );
    if (cached == null) {
      // 用户从未打开过目录,没有对比基线,跳过
      return 0;
    }
    final firstPage = await SourceManager.instance.getChaptersFromSource(
      book.sourceId,
      book.bookId,
      page: 1,
    );
    if (firstPage.maxPage <= cached.maxPage) {
      return 0;
    }
    // 尾部新增:拉最后一页,把缓存里没有的章节增量补录
    final lastPage = await SourceManager.instance.getChaptersFromSource(
      book.sourceId,
      book.bookId,
      page: firstPage.maxPage,
    );
    final existing = (await CatalogCacheService.instance.load(
          sourceId: book.sourceId,
          bookId: book.bookId,
        ))
        ?.chapters
        .map((chapter) => chapter.chapterId)
        .toSet() ??
        const <String>{};
    final fresh = lastPage.list
        .where((chapter) => !existing.contains(chapter.chapterId))
        .toList();
    if (fresh.isEmpty) {
      return 0;
    }
    await CatalogCacheService.instance.savePage(
      sourceId: book.sourceId,
      bookId: book.bookId,
      info: lastPage.info,
      chapters: fresh,
      page: lastPage.page,
      maxPage: lastPage.maxPage,
      hasMore: false,
    );
    return fresh.length;
  }

  /// 网盘源:顶层 total 对比基线,增长才全量刷新(refreshCatalog 含子目录递归)。
  Future<int> _checkPan(
    ShelfBook book, {
    required int currentTotal,
    required Future<CachedCatalog> Function() refresh,
  }) async {
    if (book.updateBaseline <= 0) {
      // 首次检查:只建立基线,不触发通知
      await ShelfService.instance.updateTrackingBaseline(
        sourceId: book.sourceId,
        bookId: book.bookId,
        baseline: currentTotal,
      );
      return 0;
    }
    if (currentTotal <= book.updateBaseline) {
      await ShelfService.instance.updateTrackingBaseline(
        sourceId: book.sourceId,
        bookId: book.bookId,
        baseline: book.updateBaseline,
      );
      return 0;
    }
    final before = await CatalogCacheService.instance.loadMeta(
      sourceId: book.sourceId,
      bookId: book.bookId,
    );
    final refreshed = await refresh();
    await ShelfService.instance.updateTrackingBaseline(
      sourceId: book.sourceId,
      bookId: book.bookId,
      baseline: currentTotal,
    );
    final added = refreshed.chapters.length - (before?.chapterCount ?? 0);
    return added > 0 ? added : 0;
  }

  /// AList:一次 list 即全量,refreshCatalog 重建并按章节数差值计数。
  Future<int> _checkAlist(ShelfBook book) async {
    final before = await CatalogCacheService.instance.loadMeta(
      sourceId: book.sourceId,
      bookId: book.bookId,
    );
    if (before == null) return 0;
    final refreshed = await AlistService.instance.refreshCatalog(
      scopedBookPath: book.bookId,
      fallbackCover: book.cover,
      fallbackAuthor: book.author,
    );
    final added = refreshed.chapters.length - before.chapterCount;
    return added > 0 ? added : 0;
  }

  Future<void> notify({required String title, required String body}) async {
    try {
      await _channel.invokeMethod<bool>('notify', {
        'title': title,
        'body': body,
      });
    } on PlatformException catch (e) {
      LogService.instance.warning(
        'UpdateCheck',
        '发送更新通知失败',
        detail: '$e',
      );
    }
  }
}
