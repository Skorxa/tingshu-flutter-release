import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:audio_service/audio_service.dart';

import '../data/alist_service.dart';
import '../data/aliyun_pan_service.dart';
import '../data/baidu_pan_service.dart';
import '../data/cache_service.dart';
import '../data/catalog_cache_service.dart';
import '../data/cloud_auth_service.dart';
import '../data/listening_stats_service.dart';
import '../data/log_service.dart';
import '../data/pan115_service.dart';
import '../data/quark_pan_service.dart';
import '../data/progress_service.dart';
import '../data/settings_service.dart';
import '../data/sniff_service.dart';
import '../source/source_manager.dart';
import 'audio_handler.dart';

class PlayerService extends ChangeNotifier {
  PlayerService._() {
    _offloadEnabled = SettingsService.instance.androidAudioOffload;
    _player = _createPlayer(_offloadEnabled);
    _bindPlayer();
  }
  static final PlayerService instance = PlayerService._();

  late AudioPlayer _player;
  PlayerAudioHandler? _handler;
  StreamSubscription<PlayerState>? _playerStateSub;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<Duration>? _bufferedPositionSub;
  StreamSubscription<Duration?>? _durationSub;
  StreamSubscription<PlaybackEvent>? _playbackEventSub;

  bool _offloadEnabled = false;
  bool _handlingCompletion = false;
  // 待续播态:启动时已从进度恢复书籍/章节 meta,但尚未加载音源。
  // 此时点播放(toggle)会触发 playIndex 真正加载并定位到 _resumePositionSeconds。
  bool _pendingResume = false;
  double _resumePositionSeconds = 0;
  int _playSeq = 0;
  bool _userWantsPlayback = false;
  bool _recoveringPlayback = false;
  int _recoveryAttempts = 0;
  String _recoveryChapterId = '';
  Timer? _stablePlaybackTimer;
  DateTime _lastPositionEmit = DateTime(2000);
  DateTime _lastBufferedEmit = DateTime(2000);
  Timer? _sleepTimer;
  Timer? _sleepTickTimer;
  Timer? _fadeOutTimer;
  String _sleepMode = '';
  int _sleepValue = 0;
  int _sleepRemainingChapters = 0;
  DateTime? _sleepEndAt;
  bool _isFadingOut = false;
  // 用户主动暂停的时间点:暂停超过阈值后点播放回退 5 秒。
  // 定时关闭淡出走 _player.pause 直调,不会设置此字段。
  DateTime? _pausedAt;
  static const _resumeRewindThreshold = Duration(minutes: 30);

  static AudioPlayer _createPlayer(bool offloadEnabled) {
    return AudioPlayer(
      androidAudioOffloadPreferences: AndroidAudioOffloadPreferences(
        audioOffloadMode: offloadEnabled
            ? AndroidAudioOffloadMode.enabled
            : AndroidAudioOffloadMode.disabled,
        // 部分 Android DSP 虽然声明支持音频卸载，却不支持运行时变速。
        // 要求变速能力可让 ExoPlayer 在这些设备上自动退回普通解码。
        isSpeedChangeSupportRequired: true,
      ),
    );
  }

  void _bindPlayer() {
    _playerStateSub = _player.playerStateStream.listen((s) {
      _playing = s.playing;
      _processing = s.processingState;
      _updateMiniControls();
      _broadcast();
      if (s.processingState == ProcessingState.completed) {
        unawaited(_handleCompleted());
      }
      notifyListeners();
    });
    _positionSub = _player.positionStream.listen((p) {
      final now = DateTime.now();
      // 节流: 仅每 ~500ms 更新一次进度,减少 Slider/进度条重建。
      // AudioPlayer 底层每 ~200ms 推送,人眼看 500ms 和 200ms 无差别。
      if (now.difference(_lastPositionEmit).inMilliseconds >= 500) {
        _lastPositionEmit = now;
        _recordListeningTime(p);
        _positionNotifier.value = p;
      }
      _autoSave();
    });
    _bufferedPositionSub = _player.bufferedPositionStream.listen((p) {
      final now = DateTime.now();
      if (now.difference(_lastBufferedEmit).inMilliseconds >= 500) {
        _lastBufferedEmit = now;
        _bufferedNotifier.value = p;
        _broadcast();
      }
    });
    _durationSub = _player.durationStream.listen((d) {
      _duration = d ?? Duration.zero;
      _updateMiniControls();
      _updateNowPlaying(); // 拿到时长后刷新通知栏曲目信息
      _broadcast();
      notifyListeners();
    });
    _playbackEventSub = _player.playbackEventStream.listen(
      (_) {},
      onError: (Object e, StackTrace stack) {
        _error = e.toString().replaceFirst('Exception: ', '');
        LogService.instance.error('Player', '播放流异常', error: e, stack: stack);
        notifyListeners();
        unawaited(_recoverPlaybackStream(e));
      },
    );
  }

  Future<void> _recoverPlaybackStream(Object cause) async {
    if (_recoveringPlayback ||
        !_userWantsPlayback ||
        _pendingResume ||
        currentIndex < 0 ||
        currentIndex >= chapters.length) {
      return;
    }
    final recoverySourceId = sourceId;
    final recoveryBookId = bookId;
    final recoveryIndex = currentIndex;
    final chapterId = '${chapters[recoveryIndex]['chapterId'] ?? ''}';
    final chapterName = '${chapters[recoveryIndex]['name'] ?? ''}';
    if (chapterId.isEmpty) return;
    if (_recoveryChapterId != chapterId) {
      _recoveryChapterId = chapterId;
      _recoveryAttempts = 0;
    }
    if (_recoveryAttempts >= 2) {
      LogService.instance.error(
        'Player',
        '自动恢复已达到上限',
        error: Exception('$cause\n章节: $chapterName\n恢复次数: $_recoveryAttempts'),
      );
      return;
    }

    _recoveringPlayback = true;
    try {
      while (_userWantsPlayback && _recoveryAttempts < 2) {
        if (sourceId != recoverySourceId ||
            bookId != recoveryBookId ||
            currentIndex != recoveryIndex ||
            '${chapters[currentIndex]['chapterId'] ?? ''}' != chapterId) {
          return;
        }
        _recoveryAttempts++;
        final resumeAt = _player.position > Duration.zero
            ? _player.position
            : _positionNotifier.value;
        final delay = Duration(milliseconds: 700 * _recoveryAttempts);
        LogService.instance.warning(
          'Player',
          '准备自动恢复播放',
          detail:
              '章节: $chapterName\n第 $_recoveryAttempts/2 次\n断点: ${resumeAt.inSeconds} 秒\n等待: ${delay.inMilliseconds} ms',
        );
        await Future<void>.delayed(delay);
        if (!_userWantsPlayback) return;
        await playIndex(
          recoveryIndex,
          seekTo: resumeAt.inMilliseconds / 1000,
          recovery: true,
        );
        if (_error == null) {
          LogService.instance.info(
            'Player',
            '播放已自动恢复',
            detail:
                '章节: $chapterName\n断点: ${resumeAt.inSeconds} 秒\n恢复次数: $_recoveryAttempts',
          );
          return;
        }
      }
    } finally {
      _recoveringPlayback = false;
    }
  }

  void _scheduleRecoveryReset(String chapterId) {
    _stablePlaybackTimer?.cancel();
    _stablePlaybackTimer = Timer(const Duration(seconds: 20), () {
      if (!_playing || currentIndex < 0 || currentIndex >= chapters.length) {
        return;
      }
      if ('${chapters[currentIndex]['chapterId'] ?? ''}' != chapterId) return;
      _recoveryChapterId = chapterId;
      _recoveryAttempts = 0;
    });
  }

  /// 绑定后台媒体处理器(媒体通知/锁屏控件),由 main 在 AudioService.init 后调用。
  void attachHandler(PlayerAudioHandler handler) {
    _handler = handler;
    _updateNowPlaying();
    _broadcast();
  }

  /// 广播播放状态到媒体通知/锁屏。position/buffered 取实时值,控件由 handler 按章节位置决定。
  void _broadcast() {
    _handler?.broadcast(
      playing: _playing,
      processing: _processing,
      position: _player.position,
      buffered: _player.bufferedPosition,
      speed: _speed,
    );
  }

  /// 把当前章节的曲目信息(标题/书名/封面/时长)推给媒体通知。
  void _updateNowPlaying() {
    final handler = _handler;
    if (handler == null ||
        currentIndex < 0 ||
        currentIndex >= chapters.length) {
      return;
    }
    final ch = chapters[currentIndex];
    handler.setNowPlaying(
      id: '${ch['chapterId'] ?? ''}',
      title: '${ch['name'] ?? ''}',
      album: bookTitle,
      artUri: _coverUri(cover),
      duration: _duration > Duration.zero ? _duration : null,
    );
  }

  Future<void> _ensurePlayerConfig() async {
    final enabled = SettingsService.instance.androidAudioOffload;
    if (enabled == _offloadEnabled) return;
    await _playerStateSub?.cancel();
    await _positionSub?.cancel();
    await _bufferedPositionSub?.cancel();
    await _durationSub?.cancel();
    await _playbackEventSub?.cancel();
    await _player.dispose();
    _offloadEnabled = enabled;
    _player = _createPlayer(enabled);
    _bindPlayer();
    LogService.instance.info(
      'Player',
      enabled ? 'Android 音频卸载已启用' : 'Android 音频卸载已关闭',
      detail: '新设置会从本次加载音频开始生效',
    );
  }

  String sourceId = '';
  String bookId = '';
  String bookTitle = '';
  String cover = '';
  List<Map<String, dynamic>> chapters = [];
  int currentIndex = -1;
  final ValueNotifier<bool> _miniVisibleNotifier = ValueNotifier(false);
  final ValueNotifier<int> _miniMetaNotifier = ValueNotifier(0);
  final ValueNotifier<int> _miniControlsNotifier = ValueNotifier(0);
  String _lastMiniMetaKey = '';
  String _lastMiniControlsKey = '';

  bool _playing = false;
  ProcessingState _processing = ProcessingState.idle;
  // 进度类高频状态独立为 ValueNotifier:position 每秒变化多次,
  // 只局部刷新进度条,不再 notifyListeners 触发 MiniPlayer/播放页整体重建。
  final ValueNotifier<Duration> _positionNotifier = ValueNotifier(
    Duration.zero,
  );
  final ValueNotifier<Duration> _bufferedNotifier = ValueNotifier(
    Duration.zero,
  );
  late final Listenable positionListenable = Listenable.merge([
    _positionNotifier,
    _bufferedNotifier,
  ]);
  Duration _duration = Duration.zero;
  double _speed = 1.0;
  String? _error;
  DateTime? _lastSave;
  Duration? _lastStatsPosition;
  int _statsAccumMs = 0; // 亚秒收听时长累加器,满 1s 才上报,避免 inSeconds 取整丢失

  bool get playing => _playing;
  bool get pendingResume => _pendingResume;
  bool get loading =>
      _processing == ProcessingState.loading ||
      _processing == ProcessingState.buffering;
  Duration get position => _positionNotifier.value;
  Duration get bufferedPosition => _bufferedNotifier.value;
  Duration get duration => _duration;
  double get speed => _speed;
  String? get error => _error;
  bool get sleepTimerActive => _sleepMode.isNotEmpty;
  ValueListenable<bool> get miniVisibleListenable => _miniVisibleNotifier;
  ValueListenable<int> get miniMetaListenable => _miniMetaNotifier;
  ValueListenable<int> get miniControlsListenable => _miniControlsNotifier;

  String get sleepTimerLabel {
    if (_sleepMode == 'chapters') {
      return '剩余 $_sleepRemainingChapters 集关闭';
    }
    if (_sleepMode == 'minutes') {
      final end = _sleepEndAt;
      if (end == null) return '定时关闭已开启';
      final remain = end.difference(DateTime.now());
      final minutes = remain.inSeconds <= 0
          ? 0
          : (remain.inSeconds / 60).ceil();
      return '$minutes 分钟后关闭';
    }
    return '定时关闭';
  }

  String get currentChapterName =>
      (currentIndex >= 0 && currentIndex < chapters.length)
      ? '${chapters[currentIndex]['name'] ?? ''}'
      : '';

  void _updateMiniVisible() {
    final visible = bookId.isNotEmpty;
    if (_miniVisibleNotifier.value != visible) {
      _miniVisibleNotifier.value = visible;
    }
  }

  void _updateMiniMeta() {
    final key = [
      bookId,
      bookTitle,
      cover,
      currentIndex,
      currentChapterName,
    ].join('\u0001');
    if (key == _lastMiniMetaKey) return;
    _lastMiniMetaKey = key;
    _miniMetaNotifier.value++;
  }

  void _updateMiniControls() {
    final key = [
      _playing,
      loading,
      currentIndex,
      chapters.length,
    ].join('\u0001');
    if (key == _lastMiniControlsKey) return;
    _lastMiniControlsKey = key;
    _miniControlsNotifier.value++;
  }

  void _updateMiniState() {
    _updateMiniVisible();
    _updateMiniMeta();
    _updateMiniControls();
  }

  /// 启动续播:恢复上次在听的书到「待续播」态。
  /// 灌入书籍/章节 meta 让 MiniPlayer 常驻显示(进度条停在上次位置),
  /// 但不加载音源、不出声;用户点播放键经 [toggle] -> [playIndex] 从断点续播。
  Future<void> restoreLastSession() async {
    if (bookId.isNotEmpty) return; // 已有播放上下文,不覆盖
    final last = await ProgressService.instance.latest();
    if (last == null) return;
    final sid = '${last['sourceId'] ?? ''}';
    final bid = '${last['bookId'] ?? ''}';
    if (bid.isEmpty) return;
    final catalog = await CatalogCacheService.instance.load(
      sourceId: sid,
      bookId: bid,
    );
    // 目录缓存缺失则优雅降级:维持现状不显示 MiniPlayer
    if (catalog == null || catalog.chapters.isEmpty) return;
    final chaptersJson = catalog.chapters
        .map((chapter) => chapter.toJson())
        .toList();
    // 定位章节:优先 chapterId 匹配,回退 chapterIdx,越界归 0
    final chapterId = '${last['chapterId'] ?? ''}';
    var index = chaptersJson.indexWhere(
      (chapter) => '${chapter['chapterId'] ?? ''}' == chapterId,
    );
    if (index < 0) index = (last['chapterIdx'] as int?) ?? 0;
    if (index < 0 || index >= chaptersJson.length) index = 0;

    setContext(
      sourceId: sid,
      bookId: bid,
      bookTitle: '${last['bookTitle'] ?? ''}',
      cover: '${last['cover'] ?? ''}',
      chapters: chaptersJson,
      notify: false,
      log: false,
    );
    currentIndex = index;
    _resumePositionSeconds = (last['currentTime'] as num?)?.toDouble() ?? 0;
    _pendingResume = true;
    // 进度条预显示上次位置(点播放前的静态展示)
    _duration = Duration(seconds: (last['duration'] as num?)?.toInt() ?? 0);
    _positionNotifier.value = Duration(seconds: _resumePositionSeconds.toInt());
    _updateMiniState();
    notifyListeners();
    LogService.instance.info(
      'Player',
      '恢复上次播放(待续播)',
      detail:
          '书名: $bookTitle\n章节: ${chaptersJson[index]['name'] ?? ''}\n断点: ${_resumePositionSeconds.toInt()} 秒',
    );
  }

  void setContext({
    required String sourceId,
    required String bookId,
    required String bookTitle,
    required String cover,
    required List<Map<String, dynamic>> chapters,
    bool notify = true,
    bool log = true,
  }) {
    final contextChanged = this.sourceId != sourceId || this.bookId != bookId;
    if (contextChanged) {
      _playSeq++;
      // 新播放上下文重置节流:首帧进度立即可见
      _lastPositionEmit = DateTime(2000);
      _lastBufferedEmit = DateTime(2000);
    }
    final previousChapterId =
        this.sourceId == sourceId &&
            this.bookId == bookId &&
            currentIndex >= 0 &&
            currentIndex < this.chapters.length
        ? '${this.chapters[currentIndex]['chapterId'] ?? ''}'
        : '';
    this.sourceId = sourceId;
    this.bookId = bookId;
    this.bookTitle = bookTitle;
    this.cover = cover;
    this.chapters = chapters;
    if (previousChapterId.isNotEmpty) {
      final nextIndex = chapters.indexWhere(
        (chapter) => '${chapter['chapterId'] ?? ''}' == previousChapterId,
      );
      if (nextIndex >= 0) currentIndex = nextIndex;
    }
    _updateMiniState();
    if (log) {
      LogService.instance.info(
        'Player',
        '设置播放上下文',
        detail:
            '书名: $bookTitle\n章节数: ${chapters.length}\nBookID: $bookId\n音源: $sourceId',
      );
    }
    if (notify) notifyListeners();
  }

  Future<void> playIndex(
    int index, {
    double seekTo = 0,
    bool recovery = false,
  }) async {
    if (index < 0 || index >= chapters.length) return;
    if (!_allowPlaybackRequest()) return;
    _pendingResume = false; // 真正进入播放,清除待续播态
    _userWantsPlayback = true;
    final seq = ++_playSeq;
    final playSourceId = sourceId;
    final playBookId = bookId;
    final playBookTitle = bookTitle;
    final playCover = cover;
    final playChapters = chapters
        .map((chapter) => Map<String, dynamic>.from(chapter))
        .toList(growable: false);
    final ch = playChapters[index];
    final chapterId = '${ch['chapterId']}';
    final chapterName = '${ch['name'] ?? ''}';
    if (!recovery || _recoveryChapterId != chapterId) {
      _recoveryChapterId = chapterId;
      _recoveryAttempts = 0;
    }
    await _ensurePlayerConfig();
    if (seq != _playSeq || sourceId != playSourceId || bookId != playBookId) {
      return;
    }
    currentIndex = index;
    _error = null;
    _positionNotifier.value = Duration.zero;
    _bufferedNotifier.value = Duration.zero;
    _duration = Duration.zero;
    _lastStatsPosition = Duration.zero;
    _statsAccumMs = 0;
    _updateMiniState();
    _updateNowPlaying(); // 切章即更新通知栏曲目(时长稍后由 durationStream 补)
    notifyListeners();

    try {
      LogService.instance.info(
        'Player',
        '准备播放章节',
        detail:
            '书名: $bookTitle\n章节: $chapterName\n序号: ${index + 1}/${chapters.length}',
      );
      await _startPlayback(
        seq: seq,
        sourceId: playSourceId,
        bookId: playBookId,
        bookTitle: playBookTitle,
        cover: playCover,
        chapters: playChapters,
        index: index,
        chapterId: chapterId,
        chapterName: chapterName,
        seekTo: seekTo,
      );
    } catch (e) {
      if (!_isPlayRequestActive(seq, playSourceId, playBookId, chapterId)) {
        return;
      }
      _error = e.toString().replaceFirst('Exception: ', '');
      LogService.instance.error('Player', '播放失败: $chapterName', error: e);
      _updateMiniControls();
      notifyListeners();
    }
  }

  Future<void> _startPlayback({
    required int seq,
    required String sourceId,
    required String bookId,
    required String bookTitle,
    required String cover,
    required List<Map<String, dynamic>> chapters,
    required int index,
    required String chapterId,
    required String chapterName,
    required double seekTo,
  }) async {
    final tag = MediaItem(
      id: chapterId,
      title: chapterName,
      album: bookTitle,
      artUri: _coverUri(cover),
    );

    // 缓存上下文随播放请求立即切换:用户开始收听某本书,上一本书的自动缓存
    // 就该停。交接不能放在 play() 之后——just_audio 的 play() 在播放结束/
    // 出错/被打断时才完成,等它会导致:(1)新书播放期间后台仍在缓存上一本书;
    // (2)数分钟后过期的播放请求恢复执行,把缓存上下文又覆盖回旧书。
    CacheService.instance.startForPlayback(
      sourceId: sourceId,
      bookId: bookId,
      bookTitle: bookTitle,
      cover: cover,
      chapters: chapters,
      currentIndex: index,
    );

    Object? lastError;
    StackTrace? lastStack;
    for (var attempt = 0; attempt < 2; attempt++) {
      String? cachedPath;
      try {
        if (attempt == 0) {
          cachedPath = await CacheService.instance.getCachedPath(
            sourceId: sourceId,
            chapterId: chapterId,
          );
        }
        if (!_isPlayRequestActive(seq, sourceId, bookId, chapterId)) return;

        final source = cachedPath != null
            ? _cachedAudioSource(cachedPath, chapterName, tag)
            : await _networkAudioSource(
                sourceId,
                chapterId,
                chapterName,
                tag,
                attempt: attempt + 1,
              );
        if (!_isPlayRequestActive(seq, sourceId, bookId, chapterId)) return;

        await _player.setAudioSource(source);
        if (!_isPlayRequestActive(seq, sourceId, bookId, chapterId)) return;
        await _player.setSpeed(_speed);
        _error = null;
        _scheduleRecoveryReset(chapterId);
        await _player.play();
        if (!_isPlayRequestActive(seq, sourceId, bookId, chapterId)) return;
        if (seekTo > 3) {
          Future.delayed(const Duration(milliseconds: 1500), () {
            if (!_isPlayRequestActive(seq, sourceId, bookId, chapterId)) return;
            _player.seek(Duration(seconds: seekTo.toInt()));
          });
        }
        return;
      } catch (e, stack) {
        lastError = e;
        lastStack = stack;
        if (!_isPlayRequestActive(seq, sourceId, bookId, chapterId)) return;
        if (cachedPath != null) {
          LogService.instance.warning(
            'Player',
            '本地缓存播放失败，删除后改用网络',
            detail: '章节: $chapterName\n路径: $cachedPath\n错误: $e',
          );
          await CacheService.instance.removeCached(
            sourceId: sourceId,
            chapterId: chapterId,
          );
          continue;
        }
        if (attempt == 0) {
          LogService.instance.warning(
            'Player',
            '网络音频加载失败，准备重试',
            detail: '章节: $chapterName\n错误: $e',
          );
          await Future<void>.delayed(const Duration(milliseconds: 800));
          continue;
        }
      }
    }
    Error.throwWithStackTrace(
      lastError ?? Exception('播放失败'),
      lastStack ?? StackTrace.current,
    );
  }

  AudioSource _cachedAudioSource(
    String cachedPath,
    String chapterName,
    MediaItem tag,
  ) {
    LogService.instance.info(
      'Player',
      '使用本地缓存播放',
      detail: '章节: $chapterName\n路径: $cachedPath',
    );
    return AudioSource.uri(Uri.file(cachedPath), tag: tag);
  }

  Uri? _coverUri(String cover) {
    var value = cover.trim();
    if (value.isEmpty) return null;
    if (value.startsWith('//')) value = 'https:$value';
    if (value.startsWith('http://') || value.startsWith('https://')) {
      return Uri.tryParse(value);
    }
    return Uri.file(value);
  }

  Future<AudioSource> _networkAudioSource(
    String sourceId,
    String chapterId,
    String chapterName,
    MediaItem tag, {
    required int attempt,
  }) async {
    final currentChapter = currentIndex >= 0 && currentIndex < chapters.length
        ? chapters[currentIndex]
        : const <String, dynamic>{};
    final directUrl = '${currentChapter['audioUrl'] ?? ''}';
    final dynamicCloudUrl =
        chapterId.startsWith('baidu:') ||
        chapterId.startsWith('quark:') ||
        chapterId.startsWith('alist:') ||
        chapterId.startsWith(Pan115Service.chapterPrefix) ||
        chapterId.startsWith(AliyunPanService.chapterPrefix);
    if (directUrl.isNotEmpty && !dynamicCloudUrl) {
      final headers = <String, String>{};
      final rawHeaders = currentChapter['audioHeaders'];
      if (rawHeaders is Map) {
        rawHeaders.forEach((key, value) => headers['$key'] = '$value');
      }
      LogService.instance.info(
        'Player',
        '使用直链音频播放',
        detail: '章节: $chapterName\nURL: $directUrl',
      );
      return AudioSource.uri(
        Uri.parse(directUrl),
        headers: headers.isEmpty ? null : headers,
        tag: tag,
      );
    }

    if (chapterId.startsWith('baidu:')) {
      final audio = await BaiduPanService.instance.resolveAudio(
        chapterId.substring('baidu:'.length),
      );
      LogService.instance.info(
        'Player',
        '使用百度网盘直链播放',
        detail: '章节: $chapterName\n重试: $attempt\nURL: ${audio.url}',
      );
      return AudioSource.uri(
        Uri.parse(audio.url),
        headers: audio.headers.isEmpty ? null : audio.headers,
        tag: tag,
      );
    }

    if (chapterId.startsWith('quark:')) {
      final audio = await QuarkPanService.instance.resolveAudio(
        chapterId.substring('quark:'.length),
        // 夸克 CDN 反盗链 412 时换请求头变体重试(0=完整头 1=去 Cookie)
        headerVariant: attempt > 1 ? attempt - 1 : 0,
      );
      LogService.instance.info(
        'Player',
        '使用夸克网盘直链播放',
        detail: '章节: $chapterName\n重试: $attempt\nURL: ${audio.url}',
      );
      return AudioSource.uri(
        Uri.parse(audio.url),
        headers: audio.headers.isEmpty ? null : audio.headers,
        tag: tag,
      );
    }

    if (chapterId.startsWith('alist:')) {
      // AList 懒解析:播放到哪集才调 /api/fs/get 拿新鲜直链,
      // 避免打开书时逐集预解析造成大量串行请求触发 429。
      final audio = await AlistService.instance.resolveAudio(
        chapterId.substring('alist:'.length),
      );
      LogService.instance.info(
        'Player',
        '使用 Alist 直链播放',
        detail: '章节: $chapterName\n重试: $attempt',
      );
      return AudioSource.uri(
        Uri.parse(audio.url),
        headers: audio.headers.isEmpty ? null : audio.headers,
        tag: tag,
      );
    }

    if (chapterId.startsWith(Pan115Service.chapterPrefix)) {
      // 115 懒解析:章节只带 pick_code,播放到哪集才取哪集的直链。
      final audio = await Pan115Service.instance.resolveAudio(
        chapterId.substring(Pan115Service.chapterPrefix.length),
        // CDN 反盗链时换请求头变体重试(0=完整头 1=去 Cookie 2=仅 UA)
        headerVariant: attempt > 1 ? attempt - 1 : 0,
      );
      LogService.instance.info(
        'Player',
        '使用 115 网盘直链播放',
        detail: '章节: $chapterName\n重试: $attempt',
      );
      return AudioSource.uri(
        Uri.parse(audio.url),
        headers: audio.headers.isEmpty ? null : audio.headers,
        tag: tag,
      );
    }

    if (chapterId.startsWith(AliyunPanService.chapterPrefix)) {
      // 阿里云盘懒解析:章节只带 file_id,播放时才换新鲜直链(带签名与有效期)。
      final audio = await AliyunPanService.instance.resolveAudio(
        chapterId.substring(AliyunPanService.chapterPrefix.length),
        headerVariant: attempt > 1 ? attempt - 1 : 0,
      );
      LogService.instance.info(
        'Player',
        '使用阿里云盘直链播放',
        detail: '章节: $chapterName\n重试: $attempt',
      );
      return AudioSource.uri(
        Uri.parse(audio.url),
        headers: audio.headers.isEmpty ? null : audio.headers,
        tag: tag,
      );
    }

    final audio = sourceId.isNotEmpty
        ? await SourceManager.instance.getAudioUrlFromSource(
            sourceId,
            chapterId,
          )
        : await SourceManager.instance.getAudioUrl(chapterId);
    if (audio.needsSniff) {
      final sniffed = await SniffService.instance.sniff(audio.sniff!);
      LogService.instance.info(
        'Player',
        '使用嗅探音频播放',
        detail: '章节: $chapterName\n页面: ${audio.url}\n音频: ${sniffed.url}',
      );
      return AudioSource.uri(
        Uri.parse(sniffed.url),
        headers: sniffed.headers.isEmpty ? null : sniffed.headers,
        tag: tag,
      );
    }
    LogService.instance.info(
      'Player',
      '使用网络音频播放',
      detail: '章节: $chapterName\nURL: ${audio.url}',
    );
    return AudioSource.uri(
      Uri.parse(audio.url),
      headers: audio.headers.isEmpty ? null : audio.headers,
      tag: tag,
    );
  }

  bool _isPlayRequestActive(
    int seq,
    String sourceId,
    String bookId,
    String chapterId,
  ) {
    if (seq != _playSeq || this.sourceId != sourceId || this.bookId != bookId) {
      return false;
    }
    if (currentIndex < 0 || currentIndex >= chapters.length) return false;
    return '${chapters[currentIndex]['chapterId'] ?? ''}' == chapterId;
  }

  // 每 5 秒自动保存进度
  void _autoSave() {
    if (bookId.isEmpty || currentIndex < 0) return;
    final now = DateTime.now();
    if (_lastSave != null && now.difference(_lastSave!).inSeconds < 5) return;
    _lastSave = now;
    final ch = chapters[currentIndex];
    ProgressService.instance.save(
      sourceId: sourceId,
      bookId: bookId,
      bookTitle: bookTitle,
      cover: cover,
      chapterId: '${ch['chapterId']}',
      chapterName: '${ch['name'] ?? ''}',
      chapterIdx: currentIndex,
      currentTime: _positionNotifier.value.inSeconds.toDouble(),
      duration: _duration.inSeconds.toDouble(),
    );
  }

  void _recordListeningTime(Duration position) {
    final previous = _lastStatsPosition;
    _lastStatsPosition = position;
    if (!_playing || previous == null) return;
    final deltaMs = (position - previous).inMilliseconds;
    // 负增量(快退)或大跳变(seek/换集)不计入收听时长
    if (deltaMs <= 0 || deltaMs > 5000) return;
    _statsAccumMs += deltaMs;
    if (_statsAccumMs >= 1000) {
      final seconds = _statsAccumMs ~/ 1000;
      _statsAccumMs -= seconds * 1000;
      unawaited(ListeningStatsService.instance.addPlayedSeconds(seconds));
    }
  }

  Future<void> play() async {
    if (!_allowPlaybackRequest()) return;
    // 待续播态:首次点播放从上次断点加载并续播,而非空 play()
    if (_pendingResume) {
      final resumeAt = _resumePositionSeconds;
      _pendingResume = false;
      _pausedAt = null;
      LogService.instance.info('Player', '从待续播态开始续播');
      return playIndex(currentIndex, seekTo: resumeAt);
    }
    _userWantsPlayback = true;
    final pausedAt = _pausedAt;
    _pausedAt = null;
    if (currentIndex >= 0 &&
        (_error != null || _processing == ProcessingState.idle)) {
      return playIndex(
        currentIndex,
        seekTo: _positionNotifier.value.inMilliseconds / 1000,
      );
    }
    // 长暂停后回退 5 秒起播,帮用户找回情节记忆;仅作用于用户主动暂停恢复。
    if (pausedAt != null &&
        DateTime.now().difference(pausedAt) >= _resumeRewindThreshold) {
      LogService.instance.info('Player', '长暂停后回退 5 秒续播');
      await seekBy(-5);
    }
    LogService.instance.info('Player', '继续播放');
    await _player.play();
    _broadcast();
  }

  Future<void> pause() async {
    LogService.instance.info('Player', '暂停播放');
    _userWantsPlayback = false;
    _pausedAt = DateTime.now();
    _playSeq++;
    _stablePlaybackTimer?.cancel();
    unawaited(ListeningStatsService.instance.flush());
    await _player.pause();
    _broadcast();
  }

  bool _allowPlaybackRequest() {
    if (CloudAuthService.instance.canUseApp) return true;
    _userWantsPlayback = false;
    _error = '设备授权不可用';
    LogService.instance.warning(
      'Player',
      '已拦截未授权的播放请求',
      detail: '授权状态: ${CloudAuthService.instance.stateLabel}',
    );
    _broadcast();
    return false;
  }

  Future<void> toggle() => _playing ? pause() : play();

  Future<void> next() async {
    if (currentIndex < chapters.length - 1) await playIndex(currentIndex + 1);
  }

  Future<void> prev() async {
    if (currentIndex > 0) await playIndex(currentIndex - 1);
  }

  Future<void> seek(Duration d) async {
    await _player.seek(d);
    _broadcast();
  }

  /// 相对当前进度快进(正秒)/快退(负秒),并夹在 [0, duration] 内。
  Future<void> seekBy(int seconds) async {
    var target = _positionNotifier.value + Duration(seconds: seconds);
    if (target < Duration.zero) target = Duration.zero;
    if (_duration > Duration.zero && target > _duration) target = _duration;
    await seek(target);
  }

  Future<void> setSpeed(double s) async {
    if (!s.isFinite || s <= 0) return;
    final previous = _speed;
    try {
      await _player.setSpeed(s);
      _speed = s;
      LogService.instance.info(
        'Player',
        '播放倍速已生效',
        detail:
            '倍速: ${s.toStringAsFixed(2)}x\n音频卸载: ${_offloadEnabled ? '开启' : '关闭'}',
      );
    } catch (e, stack) {
      _speed = previous;
      LogService.instance.error('Player', '设置播放倍速失败', error: e, stack: stack);
    } finally {
      _updateMiniControls();
      _broadcast();
      notifyListeners();
    }
  }

  void setSleepByChapters(int count) {
    _sleepTimer?.cancel();
    _sleepTickTimer?.cancel();
    _sleepMode = 'chapters';
    _sleepValue = count;
    _sleepRemainingChapters = count;
    _sleepEndAt = null;
    LogService.instance.info('Player', '设置按集定时关闭', detail: '$count 集后关闭');
    notifyListeners();
  }

  void setSleepByMinutes(int minutes) {
    _sleepTimer?.cancel();
    _sleepTickTimer?.cancel();
    _fadeOutTimer?.cancel();
    _sleepMode = 'minutes';
    _sleepValue = minutes;
    _sleepRemainingChapters = 0;
    _sleepEndAt = DateTime.now().add(Duration(minutes: minutes));

    // 提前 10 秒开始淡出
    final fadeStartDuration = Duration(minutes: minutes, seconds: -10);
    if (fadeStartDuration.inSeconds > 0) {
      _sleepTimer = Timer(fadeStartDuration, () {
        LogService.instance.info('Player', '开始淡出音量', detail: '10秒淡出');
        unawaited(_fadeOutAndPause());
      });
    } else {
      // 时长小于10秒，直接暂停
      _sleepTimer = Timer(Duration(minutes: minutes), () {
        LogService.instance.info('Player', '按时定时关闭触发', detail: '$minutes 分钟');
        _userWantsPlayback = false;
        unawaited(_player.pause());
        clearSleepTimer();
      });
    }

    _sleepTickTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => notifyListeners(),
    );
    LogService.instance.info('Player', '设置按时定时关闭', detail: '$minutes 分钟后关闭');
    notifyListeners();
  }

  /// 淡出音量并暂停
  Future<void> _fadeOutAndPause() async {
    if (_isFadingOut) return;
    _isFadingOut = true;

    final originalVolume = _player.volume;
    const steps = 20;
    const stepDuration = Duration(milliseconds: 500); // 10秒 / 20步

    for (int i = 0; i < steps; i++) {
      if (!_isFadingOut) {
        // 淡出被中断，恢复音量
        await _player.setVolume(originalVolume);
        return;
      }
      final volume = originalVolume * (1 - (i + 1) / steps);
      await _player.setVolume(volume);
      await Future.delayed(stepDuration);
    }

    _userWantsPlayback = false;
    await _player.pause();
    await _player.setVolume(originalVolume); // 恢复音量供下次播放
    _isFadingOut = false;
    clearSleepTimer();
  }

  void clearSleepTimer() {
    _sleepTimer?.cancel();
    _sleepTickTimer?.cancel();
    _fadeOutTimer?.cancel();
    _sleepTimer = null;
    _sleepTickTimer = null;
    _fadeOutTimer = null;
    _sleepMode = '';
    _sleepValue = 0;
    _sleepRemainingChapters = 0;
    _sleepEndAt = null;
    _isFadingOut = false;
    LogService.instance.info('Player', '清除定时关闭');
    notifyListeners();
  }

  Future<void> _handleCompleted() async {
    if (_handlingCompletion) return;
    _handlingCompletion = true;
    try {
      if (_sleepMode == 'chapters') {
        _sleepRemainingChapters--;
        if (_sleepRemainingChapters <= 0) {
          LogService.instance.info(
            'Player',
            '按集定时关闭触发',
            detail: '设置值: $_sleepValue 集',
          );
          clearSleepTimer();
          _userWantsPlayback = false;
          await _player.pause();
          return;
        }
        notifyListeners();
      }
      if (currentIndex < chapters.length - 1) {
        await next();
      } else {
        _userWantsPlayback = false;
      }
    } finally {
      _handlingCompletion = false;
    }
  }
}
