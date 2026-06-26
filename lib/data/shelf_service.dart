import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

import 'db.dart';
import 'log_service.dart';

class ShelfBook {
  final String sourceId, bookId, title, cover, author, sourceName;
  final int addTime;

  ShelfBook({
    required this.sourceId,
    required this.bookId,
    required this.title,
    required this.cover,
    required this.author,
    required this.sourceName,
    required this.addTime,
  });

  factory ShelfBook.fromMap(Map m) => ShelfBook(
    sourceId: '${m['sourceId'] ?? ''}',
    bookId: '${m['bookId']}',
    title: '${m['title']}',
    cover: '${m['cover']}',
    author: '${m['author']}',
    sourceName: '${m['sourceName'] ?? ''}',
    addTime: (m['addTime'] as int?) ?? 0,
  );
}

class ShelfService extends ChangeNotifier {
  ShelfService._();
  static final instance = ShelfService._();

  Future<void> add({
    required String sourceId,
    required String bookId,
    required String title,
    required String cover,
    required String author,
    required String sourceName,
  }) async {
    final db = await getDb();
    await db.insert('shelf', {
      'sourceId': sourceId,
      'bookId': bookId,
      'title': title,
      'cover': cover,
      'author': author,
      'sourceName': sourceName,
      'addTime': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    LogService.instance.info(
      'Shelf',
      '加入书架',
      detail: '书名: $title\nBookID: $bookId\n音源: $sourceName($sourceId)',
    );
    notifyListeners();
  }

  Future<void> remove({
    required String sourceId,
    required String bookId,
  }) async {
    final db = await getDb();
    await db.delete(
      'shelf',
      where: 'sourceId = ? AND bookId = ?',
      whereArgs: [sourceId, bookId],
    );
    LogService.instance.info(
      'Shelf',
      '移出书架',
      detail: 'BookID: $bookId\n音源: $sourceId',
    );
    notifyListeners();
  }

  Future<void> updateCover({
    required String sourceId,
    required String bookId,
    required String cover,
  }) async {
    if (cover.trim().isEmpty) return;
    final db = await getDb();
    final rows = await db.update(
      'shelf',
      {'cover': cover},
      where: 'sourceId = ? AND bookId = ?',
      whereArgs: [sourceId, bookId],
    );
    if (rows > 0) {
      LogService.instance.info(
        'Shelf',
        '书架封面已更新',
        detail: 'BookID: $bookId\n音源: $sourceId\n封面: $cover',
      );
      notifyListeners();
    }
  }

  Future<bool> contains({
    required String sourceId,
    required String bookId,
  }) async {
    final db = await getDb();
    final rows = await db.query(
      'shelf',
      where: 'sourceId = ? AND bookId = ?',
      whereArgs: [sourceId, bookId],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  Future<List<ShelfBook>> list() async {
    final db = await getDb();
    final rows = await db.query('shelf', orderBy: 'addTime DESC');
    return rows.map(ShelfBook.fromMap).toList();
  }
}
