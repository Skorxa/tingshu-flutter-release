import '../data/log_service.dart';
import 'models.dart';
import 'source_manager.dart';

/// 单个调试步骤的结果。[ran] 是否执行;[ok] 是否成功;[logId] 关联日志条目 id(用于跳转)。
class DebugStepResult {
  final String name;
  final bool ran;
  final bool ok;
  final int? logId;
  final String summary;

  const DebugStepResult(
    this.name, {
    required this.ran,
    required this.ok,
    this.logId,
    this.summary = '',
  });

  const DebugStepResult.skipped(this.name)
    : ran = false,
      ok = false,
      logId = null,
      summary = '未执行';
}

class SourceDebugResult {
  final List<DebugStepResult> steps;
  const SourceDebugResult(this.steps);
}

class SourceDebugRunner {
  SourceDebugRunner._();
  static final instance = SourceDebugRunner._();

  /// 跑一遍 搜索 → (自动选第一本/命中 bookId) → 目录 → 播放链接,
  /// 每步独立捕获异常,返回分步结果。bookId 为空时自动取搜索第一条。
  Future<SourceDebugResult> runBookDebug({
    required String sourceId,
    required String sourceName,
    required String keyword,
    required String bookId,
    required String bookTitle,
  }) async {
    final started = DateTime.now();
    final config = SourceManager.instance.getSourceConfig(sourceId);
    LogService.instance.info(
      'SourceDebug',
      '开始音源调试',
      detail:
          '音源: $sourceName($sourceId)\n关键词: $keyword\n书名: ${bookTitle.isEmpty ? '(自动取搜索第一条)' : bookTitle}\nBookID: ${bookId.isEmpty ? '(无)' : bookId}\n${SourceManager.configSummary(config)}',
    );

    // ── 步骤 1:搜索 ──
    final searchKeyword = keyword.isNotEmpty ? keyword : bookTitle;
    final SearchResult search;
    final int searchLogId;
    try {
      final searchStart = DateTime.now();
      search = await SourceManager.instance.searchFromSource(
        sourceId,
        searchKeyword,
        page: 1,
        pageSize: 5,
      );
      searchLogId = LogService.instance
          .info(
            'SourceDebug',
            '搜索接口调试完成',
            detail:
                '耗时: ${_ms(searchStart)} ms\n结果数: ${search.list.length}\n页码: ${search.page}/${search.maxPage}\nhasMore: ${search.hasMore}\n${search.list.take(5).map((book) => '- ${book.title} | ${book.bookId} | ${book.author}').join('\n')}',
          )
          .id;
    } catch (e, stack) {
      final id = LogService.instance
          .error('SourceDebug', '搜索接口调试失败', error: e, stack: stack)
          .id;
      return SourceDebugResult([
        DebugStepResult(
          '搜索',
          ran: true,
          ok: false,
          logId: id,
          summary: _err(e),
        ),
        const DebugStepResult.skipped('目录'),
        const DebugStepResult.skipped('播放链接'),
      ]);
    }

    // 命中传入 bookId 的书;未传 bookId 时自动取第一本
    final matched = search.list.where((b) => b.bookId == bookId).toList();
    final target = matched.isNotEmpty
        ? matched.first
        : (search.list.isNotEmpty ? search.list.first : null);
    if (target == null) {
      return SourceDebugResult([
        DebugStepResult(
          '搜索',
          ran: true,
          ok: false,
          logId: searchLogId,
          summary: '搜索无结果',
        ),
        const DebugStepResult.skipped('目录'),
        const DebugStepResult.skipped('播放链接'),
      ]);
    }
    final searchStep = DebugStepResult(
      '搜索',
      ran: true,
      ok: true,
      logId: searchLogId,
      summary: '${search.list.length} 条 · 调试《${target.title}》',
    );

    // ── 步骤 2:目录 ──
    final CatalogResult catalog;
    final int catalogLogId;
    try {
      final catalogStart = DateTime.now();
      catalog = await SourceManager.instance.getChaptersFromSource(
        sourceId,
        target.bookId,
        page: 1,
        pageSize: SourceManager.catalogPageSize,
      );
      catalogLogId = LogService.instance
          .info(
            'SourceDebug',
            '目录接口调试完成',
            detail:
                '耗时: ${_ms(catalogStart)} ms\n书名: ${catalog.info.title.isNotEmpty ? catalog.info.title : target.title}\n封面: ${catalog.info.cover.isEmpty ? '(无)' : catalog.info.cover}\n章节数: ${catalog.list.length}\ntrackCount: ${catalog.info.trackCount}\n页码: ${catalog.page}/${catalog.maxPage}\nhasMore: ${catalog.hasMore}\n${catalog.list.take(8).map((c) => '- ${c.index}. ${c.name} | ${c.chapterId}').join('\n')}',
          )
          .id;
    } catch (e, stack) {
      final id = LogService.instance
          .error('SourceDebug', '目录接口调试失败', error: e, stack: stack)
          .id;
      return SourceDebugResult([
        searchStep,
        DebugStepResult(
          '目录',
          ran: true,
          ok: false,
          logId: id,
          summary: _err(e),
        ),
        const DebugStepResult.skipped('播放链接'),
      ]);
    }
    if (catalog.list.isEmpty) {
      final id = LogService.instance.warning('SourceDebug', '目录为空,无法继续解析音频').id;
      return SourceDebugResult([
        searchStep,
        DebugStepResult('目录', ran: true, ok: false, logId: id, summary: '目录为空'),
        const DebugStepResult.skipped('播放链接'),
      ]);
    }
    final catalogStep = DebugStepResult(
      '目录',
      ran: true,
      ok: true,
      logId: catalogLogId,
      summary: '${catalog.list.length} 章',
    );

    // ── 步骤 3:播放链接 ──
    final chapter = catalog.list.first;
    DebugStepResult audioStep;
    try {
      final audioStart = DateTime.now();
      final audio = await SourceManager.instance.getAudioUrlFromSource(
        sourceId,
        chapter.chapterId,
      );
      final id = LogService.instance
          .info(
            'SourceDebug',
            '音频接口调试完成',
            detail:
                '耗时: ${_ms(audioStart)} ms\n章节: ${chapter.index}. ${chapter.name}\nChapterID: ${chapter.chapterId}\nURL: ${audio.url}\nHeaders: ${audio.headers.isEmpty ? '无' : audio.headers.keys.join(', ')}',
          )
          .id;
      audioStep = DebugStepResult(
        '播放链接',
        ran: true,
        ok: true,
        logId: id,
        summary: '解析成功',
      );
    } catch (e, stack) {
      final id = LogService.instance
          .error('SourceDebug', '音频接口调试失败', error: e, stack: stack)
          .id;
      audioStep = DebugStepResult(
        '播放链接',
        ran: true,
        ok: false,
        logId: id,
        summary: _err(e),
      );
    }

    LogService.instance.info(
      'SourceDebug',
      '音源调试完成',
      detail: '总耗时: ${_ms(started)} ms\n音源: $sourceName($sourceId)',
    );
    return SourceDebugResult([searchStep, catalogStep, audioStep]);
  }

  String _err(Object e) => e.toString().replaceFirst('Exception: ', '');

  int _ms(DateTime started) {
    return DateTime.now().difference(started).inMilliseconds;
  }
}
