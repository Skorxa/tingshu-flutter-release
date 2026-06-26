import 'package:sqflite/sqflite.dart';
import 'db.dart';

class ProgressService {
  ProgressService._();
  static final instance = ProgressService._();

  Future<void> save({
    required String sourceId,
    required String bookId,
    required String bookTitle,
    required String cover,
    required String chapterId,
    required String chapterName,
    required int chapterIdx,
    required double currentTime,
    required double duration,
  }) async {
    final db = await getDb();
    await db.insert('play_progress', {
      'sourceId': sourceId,
      'bookId': bookId,
      'bookTitle': bookTitle,
      'cover': cover,
      'chapterId': chapterId,
      'chapterName': chapterName,
      'chapterIdx': chapterIdx,
      'currentTime': currentTime,
      'duration': duration,
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<Map<String, dynamic>?> load({
    required String sourceId,
    required String bookId,
  }) async {
    final db = await getDb();
    final rows = await db.query(
      'play_progress',
      where: 'sourceId = ? AND bookId = ?',
      whereArgs: [sourceId, bookId],
      limit: 1,
    );
    if (rows.isNotEmpty) return rows.first;

    // 兼容 v6 以前迁移来的进度记录。下一次自动保存会写成带 sourceId 的新记录。
    final legacyRows = await db.query(
      'play_progress',
      where: 'sourceId = ? AND bookId = ?',
      whereArgs: ['', bookId],
      limit: 1,
    );
    return legacyRows.isEmpty ? null : legacyRows.first;
  }

  /// 最近一条播放记录(按 updatedAt 倒序),用于启动续播恢复上次在听的书。
  Future<Map<String, dynamic>?> latest() async {
    final db = await getDb();
    final rows = await db.query(
      'play_progress',
      where: 'bookId IS NOT NULL AND bookId != ?',
      whereArgs: [''],
      orderBy: 'updatedAt DESC',
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  Future<List<Map<String, dynamic>>> listHistory() async {
    final db = await getDb();
    return db.query(
      'play_progress',
      where: 'bookId IS NOT NULL AND bookId != ?',
      whereArgs: [''],
      orderBy: 'updatedAt DESC',
      limit: 200,
    );
  }

  Future<void> remove({
    required String sourceId,
    required String bookId,
  }) async {
    final db = await getDb();
    await db.delete(
      'play_progress',
      where: 'sourceId = ? AND bookId = ?',
      whereArgs: [sourceId, bookId],
    );
  }

  Future<void> clearHistory() async {
    final db = await getDb();
    await db.delete('play_progress');
  }
}
