import 'package:sqflite/sqflite.dart';
import 'db.dart';
import 'sync_payload.dart';

class ProgressService {
  ProgressService._();
  static final instance = ProgressService._();

  /// 最近一次保存进度的毫秒时间戳(内存),供 WebDAV 同步检测变更。
  int _lastSavedAt = 0;
  int get lastSavedAt => _lastSavedAt;

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
    _lastSavedAt = DateTime.now().millisecondsSinceEpoch;
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

  /// 导出播放进度用于 WebDAV 同步。
  ///
  /// 默认只取最近 [limit] 条(`updatedAt DESC`,当前/最近播放的书一定在内):
  /// 同步载荷的体积主要来自这个列表,800 条 × 带封面签名 URL 会到数百 KB 量级,
  /// 对按流量/请求数计费的限额 WebDAV 不划算。上行前还会经 [SyncPayload.progressRow]
  /// 再做一次字段瘦身。
  Future<List<Map<String, dynamic>>> listForSync({int limit = 800}) async {
    final db = await getDb();
    final rows = await db.query(
      'play_progress',
      orderBy: 'updatedAt DESC',
      limit: limit,
    );
    return rows.map((row) => Map<String, dynamic>.from(row)).toList();
  }

  /// WebDAV 同步合并:按 (sourceId, bookId) 取 updatedAt 较新的记录。
  /// 返回应用的变更条数。
  Future<int> mergeFromSync(List<Map<String, dynamic>> rows) async {
    if (rows.isEmpty) return 0;
    final db = await getDb();
    final local = await db.query('play_progress');
    final localByKey = <String, Map<String, dynamic>>{
      for (final row in local) '${row['sourceId']}|${row['bookId']}': row,
    };
    final batch = db.batch();
    var changed = 0;
    for (final row in rows) {
      final sourceId = '${row['sourceId'] ?? ''}';
      final bookId = '${row['bookId'] ?? ''}';
      if (bookId.isEmpty) continue;
      final updatedAt = (row['updatedAt'] as num?)?.toInt() ?? 0;
      final existing = localByKey['$sourceId|$bookId'];
      if (existing != null &&
          ((existing['updatedAt'] as int?) ?? 0) >= updatedAt) {
        continue;
      }
      // 同步载荷不带封面(见 SyncPayload.progressRow),这里由 SyncPayload 保留本地
      // 已有封面,避免一次同步把本机历史列表的封面清空。
      batch.insert('play_progress', {
        ...SyncPayload.progressRowForInsert(
          incoming: row,
          local: existing,
        ),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      changed++;
    }
    if (changed == 0) return 0;
    await batch.commit(noResult: true);
    return changed;
  }
}
