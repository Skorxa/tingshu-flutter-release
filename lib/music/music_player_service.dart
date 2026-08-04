import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:audio_service/audio_service.dart';

import '../data/log_service.dart';
import '../data/settings_service.dart';
import 'models.dart';
import 'music_source_manager.dart';
import 'music_audio_handler.dart';

/// 音乐模式播放服务。
///
/// 与听书侧 [PlayerService] 完全隔离:独立 AudioPlayer 实例、
/// 独立队列管理、独立 ChangeNotifier。歌曲以队列形式播放,
/// 支持单曲/列表/随机循环。
class MusicPlayerService extends ChangeNotifier {
  MusicPlayerService._() {
    _offloadEnabled = SettingsService.instance.androidAudioOffload;
    _player = _createPlayer(_offloadEnabled);
    _bindPlayer();
  }
  static final instance = MusicPlayerService._();

  late AudioPlayer _player;
  MusicAudioHandler? _handler;
  StreamSubscription<PlayerState>? _playerStateSub;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<Duration>? _bufferedPositionSub;
  StreamSubscription<Duration?>? _durationSub;
  StreamSubscription<PlaybackEvent>? _playbackEventSub;

  bool _offloadEnabled = false;
  bool _userWantsPlayback = false;
  int _playSeq = 0;

  final List<MusicInfo> _queue = [];
  int _currentIndex = -1;
  RepeatMode _repeatMode = RepeatMode.list;
  bool _shuffle = false;
  final List<int> _shuffleOrder = [];
  int _shuffleIndex = -1;

  Lyric _lyric = Lyric.empty;
  int _currentLyricIndex = -1;

  final ValueNotifier<bool> _miniVisibleNotifier = ValueNotifier(false);
  final ValueNotifier<int> _metaNotifier = ValueNotifier(0);
  final ValueNotifier<int> _controlsNotifier = ValueNotifier(0);
  final ValueNotifier<Duration> _positionNotifier = ValueNotifier(Duration.zero);
  final ValueNotifier<Duration> _bufferedNotifier = ValueNotifier(Duration.zero);
  final ValueNotifier<int> _lyricNotifier = ValueNotifier(-1);

  String _lastMetaKey = '';
  String _lastControlsKey = '';

  bool _playing = false;
  ProcessingState _processing = ProcessingState.idle;
  Duration _duration = Duration.zero;
  double _speed = 1.0;
  String? _error;
  DateTime _lastPositionEmit = DateTime(2000);
  DateTime _lastBufferedEmit = DateTime(2000);

  Timer? _sleepTimer;
  String _sleepMode = '';
  int _sleepValue = 0;
  DateTime? _sleepEndAt;

  bool get playing => _playing;
  bool get loading =>
      _processing == ProcessingState.loading ||
      _processing == ProcessingState.buffering;
  Duration get position => _positionNotifier.value;
  Duration get bufferedPosition => _bufferedNotifier.value;
  Duration get duration => _duration;
  double get speed => _speed;
  String? get error => _error;
  bool get sleepTimerActive => _sleepMode.isNotEmpty;

  List<MusicInfo> get queue => List.unmodifiable(_queue);
  int get currentIndex => _currentIndex;
  MusicInfo? get currentSong =>
      _currentIndex >= 0 && _currentIndex < _queue.length
          ? _queue[_currentIndex]
          : null;
  RepeatMode get repeatMode => _repeatMode;
  bool get shuffle => _shuffle;
  Lyric get lyric => _lyric;
  int get currentLyricIndex => _currentLyricIndex;

  ValueListenable<bool> get miniVisibleListenable => _miniVisibleNotifier;
  ValueListenable<int> get metaListenable => _metaNotifier;
  ValueListenable<int> get controlsListenable => _controlsNotifier;
  ValueListenable<Duration> get positionListenable => _positionNotifier;
  ValueListenable<Duration> get bufferedListenable => _bufferedNotifier;
  ValueListenable<int> get lyricListenable => _lyricNotifier;

  String get sleepTimerLabel {
    if (_sleepMode == 'minutes') {
      final end = _sleepEndAt;
      if (end == null) return '定时关闭已开启';
      final remain = end.difference(DateTime.now());
      final minutes = remain.inSeconds <= 0 ? 0 : (remain.inSeconds / 60).ceil();
      return '$minutes 分钟后关闭';
    }
    return '定时关闭';
  }

  static AudioPlayer _createPlayer(bool offloadEnabled) {
    return AudioPlayer(
      androidAudioOffloadPreferences: AndroidAudioOffloadPreferences(
        audioOffloadMode: offloadEnabled
            ? AndroidAudioOffloadMode.enabled
            : AndroidAudioOffloadMode.disabled,
        isSpeedChangeSupportRequired: true,
      ),
    );
  }

  void _bindPlayer() {
    _playerStateSub = _player.playerStateStream.listen((s) {
      _playing = s.playing;
      _processing = s.processingState;
      _updateControls();
      _broadcast();
      if (s.processingState == ProcessingState.completed) {
        unawaited(_handleCompleted());
      }
      notifyListeners();
    });
    _positionSub = _player.positionStream.listen((p) {
      final now = DateTime.now();
      if (now.difference(_lastPositionEmit).inMilliseconds >= 500) {
        _lastPositionEmit = now;
        _positionNotifier.value = p;
        _updateLyricIndex(p);
      }
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
      _updateNowPlaying();
      _broadcast();
      notifyListeners();
    });
    _playbackEventSub = _player.playbackEventStream.listen(
      (_) {},
      onError: (Object e, StackTrace stack) {
        _error = e.toString().replaceFirst('Exception: ', '');
        LogService.instance.error('MusicPlayer', '播放流异常', error: e, stack: stack);
        notifyListeners();
      },
    );
  }

  void attachHandler(MusicAudioHandler handler) {
    _handler = handler;
    _updateNowPlaying();
    _broadcast();
  }

  bool get hasHandler => _handler != null;

  /// 运行时模式切换时调用:AudioService 已被听书 handler 占用,
  /// 无法重新 init。音乐播放仍正常工作,仅无系统通知栏控制。
  void attachHandlerWithoutService() {
    LogService.instance.info('MusicPlayer', '音乐模式运行时切换(无后台通知)');
  }

  void _broadcast() {
    _handler?.broadcast(
      playing: _playing,
      processing: _processing,
      position: _player.position,
      buffered: _player.bufferedPosition,
      speed: _speed,
    );
  }

  void _updateNowPlaying() {
    final handler = _handler;
    final song = currentSong;
    if (handler == null || song == null) return;
    handler.setNowPlaying(
      id: '${song.source}:${song.id}',
      title: song.name,
      album: song.album,
      artist: song.singer,
      artUri: _coverUri(song.img),
      duration: _duration > Duration.zero ? _duration : song.duration,
    );
  }

  Uri? _coverUri(String cover) {
    var value = cover.trim();
    if (value.isEmpty) return null;
    if (value.startsWith('//')) value = 'https:$value';
    if (value.startsWith('http://') || value.startsWith('https://')) {
      return Uri.tryParse(value);
    }
    return null;
  }

  void _updateMiniVisible() {
    final visible = _queue.isNotEmpty && _currentIndex >= 0;
    if (_miniVisibleNotifier.value != visible) {
      _miniVisibleNotifier.value = visible;
    }
  }

  void _updateMeta() {
    final song = currentSong;
    final key = [
      song?.id,
      song?.name,
      song?.singer,
      song?.img,
      _currentIndex,
      _queue.length,
    ].join('\u0001');
    if (key == _lastMetaKey) return;
    _lastMetaKey = key;
    _metaNotifier.value++;
  }

  void _updateControls() {
    final key = [_playing, loading, _currentIndex, _queue.length].join('\u0001');
    if (key == _lastControlsKey) return;
    _lastControlsKey = key;
    _controlsNotifier.value++;
  }

  void _updateState() {
    _updateMiniVisible();
    _updateMeta();
    _updateControls();
  }

  Future<void> playQueue(List<MusicInfo> songs, {int startIndex = 0}) async {
    if (songs.isEmpty) return;
    _queue
      ..clear()
      ..addAll(songs);
    _currentIndex = startIndex;
    if (_shuffle) _rebuildShuffleOrder();
    _error = null;
    _updateState();
    notifyListeners();
    await playIndex(_currentIndex);
  }

  void addToQueue(MusicInfo song) {
    _queue.add(song);
    if (_currentIndex < 0) _currentIndex = 0;
    _updateState();
    notifyListeners();
  }

  void playNext(MusicInfo song) {
    if (_queue.isEmpty) {
      _queue.add(song);
      _currentIndex = 0;
    } else {
      _queue.insert(_currentIndex + 1, song);
    }
    _updateState();
    notifyListeners();
  }

  Future<void> removeFromQueue(int index) async {
    if (index < 0 || index >= _queue.length) return;
    _queue.removeAt(index);
    if (index < _currentIndex) {
      _currentIndex--;
    } else if (index == _currentIndex) {
      if (_currentIndex >= _queue.length) _currentIndex = _queue.length - 1;
      if (_currentIndex >= 0) {
        await playIndex(_currentIndex);
      } else {
        _player.stop();
        _updateState();
      }
    }
    _updateState();
    notifyListeners();
  }

  Future<void> playIndex(int index) async {
    if (index < 0 || index >= _queue.length) return;
    _userWantsPlayback = true;
    final seq = ++_playSeq;
    final song = _queue[index];
    _currentIndex = index;
    _error = null;
    _positionNotifier.value = Duration.zero;
    _bufferedNotifier.value = Duration.zero;
    _duration = song.duration ?? Duration.zero;
    _lyric = Lyric.empty;
    _currentLyricIndex = -1;
    _lyricNotifier.value = -1;
    _updateState();
    _updateNowPlaying();
    notifyListeners();

    try {
      LogService.instance.info('MusicPlayer', '准备播放', detail: '歌曲: ${song.name} - ${song.singer}\n平台: ${song.source}');
      final result = await MusicSourceManager.instance.getMusicUrl(
        song.source,
        song.id,
      );
      if (seq != _playSeq) return;

      final tag = MediaItem(
        id: '${song.source}:${song.id}',
        title: song.name,
        album: song.album,
        artist: song.singer,
        artUri: _coverUri(song.img),
      );
      await _player.setAudioSource(
        AudioSource.uri(
          Uri.parse(result.url),
          headers: result.headers.isEmpty ? null : result.headers,
          tag: tag,
        ),
      );
      if (seq != _playSeq) return;
      await _player.setSpeed(_speed);
      await _player.play();
      _error = null;
      unawaited(_loadLyric(song));
    } catch (e, stack) {
      if (seq != _playSeq) return;
      _error = e.toString().replaceFirst('Exception: ', '');
      LogService.instance.error('MusicPlayer', '播放失败: ${song.name}', error: e, stack: stack);
      _updateControls();
      notifyListeners();
    }
  }

  Future<void> _loadLyric(MusicInfo song) async {
    final lyric = await MusicSourceManager.instance.getLyric(song.source, song.id);
    _lyric = lyric;
    _currentLyricIndex = -1;
    _lyricNotifier.value = -1;
    notifyListeners();
  }

  void _updateLyricIndex(Duration position) {
    if (_lyric.lines.isEmpty) return;
    final posMs = position.inMilliseconds;
    var idx = -1;
    for (var i = 0; i < _lyric.lines.length; i++) {
      if (_lyric.lines[i].time.inMilliseconds <= posMs) {
        idx = i;
      } else {
        break;
      }
    }
    if (idx != _currentLyricIndex) {
      _currentLyricIndex = idx;
      _lyricNotifier.value = idx;
    }
  }

  Future<void> play() async {
    _userWantsPlayback = true;
    if (_currentIndex >= 0 && (_error != null || _processing == ProcessingState.idle)) {
      return playIndex(_currentIndex);
    }
    await _player.play();
    _broadcast();
  }

  Future<void> pause() async {
    _userWantsPlayback = false;
    _playSeq++;
    await _player.pause();
    _broadcast();
  }

  Future<void> toggle() => _playing ? pause() : play();

  Future<void> next() async {
    if (_queue.isEmpty) return;
    int nextIdx;
    if (_shuffle && _shuffleOrder.isNotEmpty) {
      final currentShufflePos = _shuffleOrder.indexOf(_currentIndex);
      if (currentShufflePos >= 0 && currentShufflePos < _shuffleOrder.length - 1) {
        nextIdx = _shuffleOrder[currentShufflePos + 1];
      } else if (_repeatMode != RepeatMode.none) {
        _rebuildShuffleOrder();
        nextIdx = _shuffleOrder.isEmpty ? -1 : _shuffleOrder[0];
      } else {
        return;
      }
    } else {
      nextIdx = _currentIndex + 1;
      if (nextIdx >= _queue.length) {
        if (_repeatMode == RepeatMode.list) {
          nextIdx = 0;
        } else {
          return;
        }
      }
    }
    if (nextIdx >= 0) await playIndex(nextIdx);
  }

  Future<void> prev() async {
    if (_queue.isEmpty) return;
    if (_positionNotifier.value.inSeconds > 3) {
      await _player.seek(Duration.zero);
      _broadcast();
      return;
    }
    int prevIdx;
    if (_shuffle && _shuffleOrder.isNotEmpty) {
      final currentShufflePos = _shuffleOrder.indexOf(_currentIndex);
      if (currentShufflePos > 0) {
        prevIdx = _shuffleOrder[currentShufflePos - 1];
      } else if (_repeatMode != RepeatMode.none) {
        prevIdx = _shuffleOrder.last;
      } else {
        return;
      }
    } else {
      prevIdx = _currentIndex - 1;
      if (prevIdx < 0) {
        if (_repeatMode == RepeatMode.list) {
          prevIdx = _queue.length - 1;
        } else {
          return;
        }
      }
    }
    if (prevIdx >= 0) await playIndex(prevIdx);
  }

  Future<void> seek(Duration d) async {
    await _player.seek(d);
    _broadcast();
  }

  Future<void> setSpeed(double s) async {
    if (!s.isFinite || s <= 0) return;
    try {
      await _player.setSpeed(s);
      _speed = s;
    } catch (e) {
      LogService.instance.warning('MusicPlayer', '设置倍速失败', detail: '$e');
    } finally {
      _updateControls();
      _broadcast();
      notifyListeners();
    }
  }

  void toggleShuffle() {
    _shuffle = !_shuffle;
    if (_shuffle) {
      _rebuildShuffleOrder();
    } else {
      _shuffleOrder.clear();
      _shuffleIndex = -1;
    }
    _updateControls();
    notifyListeners();
  }

  void cycleRepeatMode() {
    _repeatMode = switch (_repeatMode) {
      RepeatMode.none => RepeatMode.list,
      RepeatMode.list => RepeatMode.single,
      RepeatMode.single => RepeatMode.none,
    };
    _updateControls();
    notifyListeners();
  }

  void _rebuildShuffleOrder() {
    _shuffleOrder
      ..clear()
      ..addAll(List.generate(_queue.length, (i) => i))..shuffle();
  }

  Future<void> _handleCompleted() async {
    if (_repeatMode == RepeatMode.single) {
      await _player.seek(Duration.zero);
      await _player.play();
      return;
    }
    await next();
  }

  void setSleepByMinutes(int minutes) {
    _sleepTimer?.cancel();
    _sleepMode = 'minutes';
    _sleepValue = minutes;
    _sleepEndAt = DateTime.now().add(Duration(minutes: minutes));
    _sleepTimer = Timer(Duration(minutes: minutes), () {
      _userWantsPlayback = false;
      _player.pause();
      clearSleepTimer();
    });
    LogService.instance.info('MusicPlayer', '设置定时关闭', detail: '$minutes 分钟后关闭');
    notifyListeners();
  }

  void clearSleepTimer() {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _sleepMode = '';
    _sleepValue = 0;
    _sleepEndAt = null;
    notifyListeners();
  }

  Future<void> stopAndClear() async {
    _userWantsPlayback = false;
    _playSeq++;
    await _player.stop();
    _queue.clear();
    _currentIndex = -1;
    _lyric = Lyric.empty;
    _currentLyricIndex = -1;
    _error = null;
    _updateState();
    notifyListeners();
  }
}

enum RepeatMode { none, list, single }
