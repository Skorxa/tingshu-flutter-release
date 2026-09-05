import 'package:sqflite/sqflite.dart';

import '../source/models.dart';
import 'db.dart';
import 'log_service.dart';

class CachedCatalog {
  final CatalogInfo info;
  final List<Chapter> chapters;
  final int page;
  final int maxPage;
  final bool hasMore;

  CachedCatalog({
    required this.info,
    required this.chapters,
    required this.page,
    required this.maxPage,
    required this.hasMore,
  });
}

class CachedCatalogMeta {
  final CatalogInfo info;
  final int chapterCount;
  final int page;
  final int maxPage;
  final bool hasMore;

  const CachedCatalogMeta({
    required this.info,
    required this.chapterCount,
    required this.page,
    required this.maxPage,
    required this.hasMore,
  });
}

class CatalogCacheService {
  CatalogCacheService._();
  static final instance = CatalogCacheService._();

  Future<void> clear({required String sourceId, required String bookId}) async {
    final db = await getDb();
    await db.transaction((txn) async {
      await txn.delete(
        'catalog_chapters',
        where: 'sourceId = ? AND bookId = ?',
        whereArgs: [sourceId, bookId],
      );
      await txn.delete(
        'catalog_books',
        where: 'sourceId = ? AND bookId = ?',
        whereArgs: [sourceId, bookId],
      );
    });
    LogService.instance.info(
      'CatalogCache',
      '目录缓存已清空',
      detail: 'BookID: $bookId\n音源: $sourceId',
    );
  }

  Future<void> clearSource(String sourceId) async {
    final db = await getDb();
    await db.transaction((txn) async {
      await txn.delete(
        'catalog_chapters',
        where: 'sourceId = ?',
        whereArgs: [sourceId],
      );
      await txn.delete(
        'catalog_books',
        where: 'sourceId = ?',
        whereArgs: [sourceId],
      );
    });
    LogService.instance.info(
      'CatalogCache',
      '音源目录缓存已清空',
      detail: '音源: $sourceId',
    );
  }

  /// 读取某本书的目录净化规则(空字符串表示未设置)。
  Future<String> filterRules({
    required String sourceId,
    required String bookId,
  }) async {
    final db = await getDb();
    final rows = await db.query(
      'catalog_filters',
      where: 'sourceId = ? AND bookId = ?',
      whereArgs: [sourceId, bookId],
      limit: 1,
    );
    return rows.isEmpty ? '' : '${rows.first['rules'] ?? ''}';
  }

  /// 保存某本书的目录净化规则(在播放器目录页编辑,按书生效)。
  Future<void> setFilterRules({
    required String sourceId,
    required String bookId,
    required String rules,
  }) async {
    final db = await getDb();
    await db.insert(
      'catalog_filters',
      {
        'sourceId': sourceId,
        'bookId': bookId,
        'rules': rules,
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    LogService.instance.info(
      'CatalogCache',
      '目录净化规则已保存',
      detail:
          'BookID: $bookId\n音源: $sourceId\n规则行数: ${rules.split('\n').where((line) => line.trim().isNotEmpty).length}',
    );
  }

  Future<CachedCatalog?> load({
    required String sourceId,
    required String bookId,
  }) async {
    final meta = await loadMeta(sourceId: sourceId, bookId: bookId);
    if (meta == null) return null;
    final db = await getDb();
    final chapters = await db.query(
      'catalog_chapters',
      where: 'sourceId = ? AND bookId = ?',
      whereArgs: [sourceId, bookId],
      orderBy: 'chapterIndex ASC',
    );
    if (chapters.isEmpty) return null;
    return CachedCatalog(
      info: meta.info,
      chapters: chapters.map(_chapterFromRow).toList(),
      page: meta.page,
      maxPage: meta.maxPage,
      hasMore: meta.hasMore,
    );
  }

  Future<CachedCatalogMeta?> loadMeta({
    required String sourceId,
    required String bookId,
  }) async {
    final db = await getDb();
    final books = await db.query(
      'catalog_books',
      where: 'sourceId = ? AND bookId = ?',
      whereArgs: [sourceId, bookId],
      limit: 1,
    );
    if (books.isEmpty) return null;
    final countRows = await db.rawQuery(
      '''SELECT COUNT(*) AS chapterCount FROM catalog_chapters
         WHERE sourceId = ? AND bookId = ?''',
      [sourceId, bookId],
    );
    final book = books.first;
    final chapterCount =
        (countRows.firstOrNull?['chapterCount'] as num?)?.toInt() ?? 0;
    return CachedCatalogMeta(
      info: CatalogInfo(
        title: '${book['title'] ?? ''}',
        cover: '${book['cover'] ?? ''}',
        author: '${book['author'] ?? ''}',
        trackCount: (book['trackCount'] as int?) ?? chapterCount,
        isFinished: book['isFinished'] == 1,
      ),
      chapterCount: chapterCount,
      page: (book['page'] as int?) ?? 1,
      maxPage: (book['maxPage'] as int?) ?? 1,
      hasMore: book['hasMore'] == 1,
    );
  }

  Future<List<Chapter>> loadWindow({
    required String sourceId,
    required String bookId,
    required int offset,
    required int limit,
  }) async {
    if (limit <= 0) return const [];
    final db = await getDb();
    final rows = await db.query(
      'catalog_chapters',
      where: 'sourceId = ? AND bookId = ?',
      whereArgs: [sourceId, bookId],
      orderBy: 'chapterIndex ASC',
      offset: offset < 0 ? 0 : offset,
      limit: limit,
    );
    return rows.map(_chapterFromRow).toList(growable: false);
  }

  Chapter _chapterFromRow(Map<String, Object?> row) {
    return Chapter(
      chapterId: '${row['chapterId'] ?? ''}',
      index: (row['chapterIndex'] as int?) ?? 0,
      name: '${row['name'] ?? ''}',
    );
  }

  Future<void> savePage({
    required String sourceId,
    required String bookId,
    required CatalogInfo info,
    required List<Chapter> chapters,
    required int page,
    required int maxPage,
    required bool hasMore,
  }) async {
    final db = await getDb();
    final now = DateTime.now().millisecondsSinceEpoch;
    final existing = await db.query(
      'catalog_books',
      columns: ['page'],
      where: 'sourceId = ? AND bookId = ?',
      whereArgs: [sourceId, bookId],
      limit: 1,
    );
    final cachedPage = existing.isEmpty
        ? 0
        : ((existing.first['page'] as int?) ?? 0);
    await db.transaction((txn) async {
      await txn.insert('catalog_books', {
        'sourceId': sourceId,
        'bookId': bookId,
        'title': info.title,
        'cover': info.cover,
        'author': info.author,
        'trackCount': info.trackCount,
        'isFinished': info.isFinished ? 1 : 0,
        'page': page > cachedPage ? page : cachedPage,
        'maxPage': maxPage,
        'hasMore': hasMore ? 1 : 0,
        'updatedAt': now,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      final batch = txn.batch();
      for (final chapter in chapters) {
        batch.insert('catalog_chapters', {
          'sourceId': sourceId,
          'bookId': bookId,
          'chapterId': chapter.chapterId,
          'chapterIndex': chapter.index,
          'name': chapter.name,
          'cachedAt': now,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await batch.commit(noResult: true);
    });
    LogService.instance.info(
      'CatalogCache',
      '目录已写入 SQLite',
      detail:
          '书籍: ${info.title}\nBookID: $bookId\n音源: $sourceId\n本页章节数: ${chapters.length}\n页码: $page/$maxPage',
    );
  }

  Future<void> updateCover({
    required String sourceId,
    required String bookId,
    required String cover,
  }) async {
    if (cover.trim().isEmpty) return;
    final db = await getDb();
    final rows = await db.update(
      'catalog_books',
      {'cover': cover, 'updatedAt': DateTime.now().millisecondsSinceEpoch},
      where: 'sourceId = ? AND bookId = ?',
      whereArgs: [sourceId, bookId],
    );
    if (rows > 0) {
      LogService.instance.info(
        'CatalogCache',
        '目录封面已更新',
        detail: 'BookID: $bookId\n音源: $sourceId\n封面: $cover',
      );
    }
  }
}
