import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

Database? _db;

Future<void> _createProgressTable(
  Database db, {
  String table = 'play_progress',
}) async {
  await db.execute('''CREATE TABLE IF NOT EXISTS $table (
    sourceId TEXT,
    bookId TEXT,
    bookTitle TEXT, cover TEXT,
    chapterId TEXT, chapterName TEXT, chapterIdx INTEGER,
    currentTime REAL, duration REAL, updatedAt INTEGER,
    PRIMARY KEY(sourceId, bookId)
  )''');
}

Future<void> _createShelfTable(Database db, {String table = 'shelf'}) async {
  await db.execute('''CREATE TABLE IF NOT EXISTS $table (
    sourceId TEXT,
    bookId TEXT,
    title TEXT, cover TEXT, author TEXT,
    sourceName TEXT, addTime INTEGER,
    PRIMARY KEY(sourceId, bookId)
  )''');
}

Future<void> _createCacheTable(
  Database db, {
  String table = 'cache_files',
}) async {
  await db.execute('''CREATE TABLE IF NOT EXISTS $table (
    sourceId TEXT,
    chapterId TEXT,
    bookId TEXT, bookTitle TEXT, cover TEXT,
    chapterName TEXT, chapterIdx INTEGER,
    localPath TEXT, sourceUrl TEXT, size INTEGER, cachedAt INTEGER,
    PRIMARY KEY(sourceId, chapterId)
  )''');
}

Future<void> _createCatalogTables(Database db) async {
  await db.execute('''CREATE TABLE IF NOT EXISTS catalog_books (
    sourceId TEXT,
    bookId TEXT,
    title TEXT, cover TEXT, author TEXT,
    trackCount INTEGER, isFinished INTEGER,
    page INTEGER, maxPage INTEGER, hasMore INTEGER,
    updatedAt INTEGER,
    PRIMARY KEY(sourceId, bookId)
  )''');
  await db.execute('''CREATE TABLE IF NOT EXISTS catalog_chapters (
    sourceId TEXT,
    bookId TEXT,
    chapterId TEXT,
    chapterIndex INTEGER,
    name TEXT,
    cachedAt INTEGER,
    PRIMARY KEY(sourceId, bookId, chapterId)
  )''');
}

Future<void> _createIndexes(Database db) async {
  await db.execute('''CREATE INDEX IF NOT EXISTS idx_catalog_chapters_book_order
    ON catalog_chapters(sourceId, bookId, chapterIndex)''');
  await db.execute('''CREATE INDEX IF NOT EXISTS idx_shelf_add_time
    ON shelf(addTime DESC)''');
  await db.execute('''CREATE INDEX IF NOT EXISTS idx_cache_files_cached_at
    ON cache_files(cachedAt ASC)''');
  await db.execute('''CREATE INDEX IF NOT EXISTS idx_cache_files_book_order
    ON cache_files(sourceId, bookId, chapterIdx)''');
  // cachedChapterIds/cleanup 按 sourceId 查询,主键 (sourceId,chapterId) 首列不能用,需独立索引
  await db.execute('''CREATE INDEX IF NOT EXISTS idx_cache_files_source
    ON cache_files(sourceId)''');
  // listHistory 按 updatedAt DESC 排序取最近 200 条,全表扫描开销随缓存增长
  await db.execute('''CREATE INDEX IF NOT EXISTS idx_progress_updated_at
    ON play_progress(updatedAt DESC)''');
}

Future<void> _migrateShelfTable(Database db) async {
  final tableInfo = await db.rawQuery('PRAGMA table_info(shelf)');
  final names = tableInfo.map((row) => '${row['name']}').toSet();
  final hasSourceId = names.contains('sourceId');
  final hasSourceName = names.contains('sourceName');
  final sourceIdExpr = hasSourceId ? "COALESCE(sourceId, '')" : "''";
  final sourceNameExpr = hasSourceName ? "COALESCE(sourceName, '')" : "''";

  await db.execute('DROP TABLE IF EXISTS shelf_v4');
  await _createShelfTable(db, table: 'shelf_v4');
  await db.execute('''INSERT OR REPLACE INTO shelf_v4
    (sourceId, bookId, title, cover, author, sourceName, addTime)
    SELECT $sourceIdExpr, bookId, title, cover, author, $sourceNameExpr, addTime
    FROM shelf''');
  await db.execute('DROP TABLE shelf');
  await db.execute('ALTER TABLE shelf_v4 RENAME TO shelf');
}

Future<void> _migrateProgressTable(Database db) async {
  final tableInfo = await db.rawQuery('PRAGMA table_info(play_progress)');
  final names = tableInfo.map((row) => '${row['name']}').toSet();
  final hasSourceId = names.contains('sourceId');
  final sourceIdExpr = hasSourceId ? "COALESCE(sourceId, '')" : "''";

  await db.execute('DROP TABLE IF EXISTS play_progress_v6');
  await _createProgressTable(db, table: 'play_progress_v6');
  await db.execute('''INSERT OR REPLACE INTO play_progress_v6
    (sourceId, bookId, bookTitle, cover, chapterId, chapterName, chapterIdx,
     currentTime, duration, updatedAt)
    SELECT $sourceIdExpr, bookId, bookTitle, cover, chapterId, chapterName,
      chapterIdx, currentTime, duration, updatedAt
    FROM play_progress''');
  await db.execute('DROP TABLE play_progress');
  await db.execute('ALTER TABLE play_progress_v6 RENAME TO play_progress');
}

Future<void> _migrateCacheTable(Database db) async {
  final tableInfo = await db.rawQuery('PRAGMA table_info(cache_files)');
  final names = tableInfo.map((row) => '${row['name']}').toSet();
  final hasSourceId = names.contains('sourceId');
  final sourceIdExpr = hasSourceId ? "COALESCE(sourceId, '')" : "''";

  await db.execute('DROP TABLE IF EXISTS cache_files_v6');
  await _createCacheTable(db, table: 'cache_files_v6');
  await db.execute('''INSERT OR REPLACE INTO cache_files_v6
    (sourceId, chapterId, bookId, bookTitle, cover, chapterName, chapterIdx,
     localPath, sourceUrl, size, cachedAt)
    SELECT $sourceIdExpr, chapterId, bookId, bookTitle, cover, chapterName,
      chapterIdx, localPath, sourceUrl, size, cachedAt
    FROM cache_files''');
  await db.execute('DROP TABLE cache_files');
  await db.execute('ALTER TABLE cache_files_v6 RENAME TO cache_files');
}

Future<Database> getDb() async {
  if (_db != null) return _db!;
  final dir = await getDatabasesPath();
  _db = await openDatabase(
    join(dir, 'tingshu.db'),
    version: 6,
    onCreate: (db, _) async {
      await _createProgressTable(db);
      await _createShelfTable(db);
      await _createCacheTable(db);
      await _createCatalogTables(db);
      await _createIndexes(db);
    },
    onUpgrade: (db, oldVersion, newVersion) async {
      if (oldVersion < 2) {
        await _createCacheTable(db);
      }
      if (oldVersion < 3) {
        await _createCatalogTables(db);
      }
      if (oldVersion < 4) {
        await _migrateShelfTable(db);
      }
      if (oldVersion < 6) {
        await _migrateProgressTable(db);
        await _migrateCacheTable(db);
        await _createIndexes(db);
      }
    },
  );
  return _db!;
}
