import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

import 'db.dart';
import 'log_service.dart';

class ShelfBook {
  final String sourceId, bookId, title, cover, author, sourceName;
  final int addTime;
  final bool followUpdates;
  final int updateBaseline;
  final int lastCheckedAt;

  ShelfBook({
    required this.sourceId,
    required this.bookId,
    required this.title,
    required this.cover,
    required this.author,
    required this.sourceName,
    required this.addTime,
    this.followUpdates = false,
    this.updateBaseline = 0,
    this.lastCheckedAt = 0,
  });

  factory ShelfBook.fromMap(Map m) => ShelfBook(
    sourceId: '${m['sourceId'] ?? ''}',
    bookId: '${m['bookId']}',
    title: '${m['title']}',
    cover: '${m['cover']}',
    author: '${m['author']}',
    sourceName: '${m['sourceName'] ?? ''}',
    addTime: (m['addTime'] as int?) ?? 0,
    followUpdates: (m['followUpdates'] as int?) == 1,
    updateBaseline: (m['updateBaseline'] as int?) ?? 0,
    lastCheckedAt: (m['lastCheckedAt'] as int?) ?? 0,
  );
}

class ShelfService extends ChangeNotifier {
  ShelfService._();
  static final instance = ShelfService._();

  bool _applyingSync = false;

  /// WebDAV 同步合并过程中为 true,监听方据此忽略本次通知。
  bool get applyingSync => _applyingSync;

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

  /// 标记/取消追更。开启时同时刷新 lastCheckedAt,避免开启瞬间立即全查。
  Future<void> setFollowUpdates({
    required String sourceId,
    required String bookId,
    required bool value,
  }) async {
    final db = await getDb();
    final updates = <String, dynamic>{'followUpdates': value ? 1 : 0};
    if (value) {
      updates['lastCheckedAt'] = DateTime.now().millisecondsSinceEpoch;
    }
    final rows = await db.update(
      'shelf',
      updates,
      where: 'sourceId = ? AND bookId = ?',
      whereArgs: [sourceId, bookId],
    );
    if (rows > 0) {
      LogService.instance.info(
        'Shelf',
        value ? '开启追更' : '关闭追更',
        detail: 'BookID: $bookId\n音源: $sourceId',
      );
      notifyListeners();
    }
  }

  /// 更新追更基线(网盘=顶层 total,JS 源=目录缓存章节数),不触发 UI 通知。
  Future<void> updateTrackingBaseline({
    required String sourceId,
    required String bookId,
    required int baseline,
  }) async {
    final db = await getDb();
    await db.update(
      'shelf',
      {
        'updateBaseline': baseline,
        'lastCheckedAt': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'sourceId = ? AND bookId = ?',
      whereArgs: [sourceId, bookId],
    );
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

  /// WebDAV 同步合并:按 (sourceId, bookId) 取 addTime 较新的记录。
  /// 返回应用的变更条数。
  Future<int> mergeFromSync(List<Map<String, dynamic>> rows) async {
    if (rows.isEmpty) return 0;
    final db = await getDb();
    final local = await db.query('shelf');
    final localByKey = <String, Map<String, dynamic>>{
      for (final row in local) '${row['sourceId']}|${row['bookId']}': row,
    };
    final batch = db.batch();
    var changed = 0;
    for (final row in rows) {
      final sourceId = '${row['sourceId'] ?? ''}';
      final bookId = '${row['bookId'] ?? ''}';
      if (sourceId.isEmpty || bookId.isEmpty) continue;
      final addTime = (row['addTime'] as num?)?.toInt() ?? 0;
      final existing = localByKey['$sourceId|$bookId'];
      if (existing != null && ((existing['addTime'] as int?) ?? 0) >= addTime) {
        continue;
      }
      // 同步载荷不再携带封面(见 SyncPayload.shelfRow),这里保留本地已有封面,
      // 避免对端记录把本机书架的封面清空。
      final incomingCover = '${row['cover'] ?? ''}'.trim();
      batch.insert('shelf', {
        'sourceId': sourceId,
        'bookId': bookId,
        'title': '${row['title'] ?? ''}',
        'cover': incomingCover.isNotEmpty
            ? incomingCover
            : '${existing?['cover'] ?? ''}',
        'author': '${row['author'] ?? ''}',
        'sourceName': '${row['sourceName'] ?? ''}',
        'addTime': addTime,
        // 同步覆盖时保留本地追更状态(基线属于本机目录,不可同步)
        'followUpdates': (existing?['followUpdates'] as int?) ?? 0,
        'updateBaseline': (existing?['updateBaseline'] as int?) ?? 0,
        'lastCheckedAt': (existing?['lastCheckedAt'] as int?) ?? 0,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      changed++;
    }
    if (changed == 0) return 0;
    await batch.commit(noResult: true);
    LogService.instance.info(
      'Shelf',
      '已合并云端书架',
      detail: '更新条数: $changed',
    );
    _applyingSync = true;
    notifyListeners();
    _applyingSync = false;
    return changed;
  }
}
