import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart' show ProcessingState;

import 'player_service.dart';

/// 自定义后台处理器:接管 Android 媒体通知 / 锁屏 / 耳机线控控件。
///
/// 控件按当前章节在书中的位置动态决定,中间章节稳定显示
/// 「上一集 · 播放/暂停 · 下一集」——解决 just_audio_background 单源播放时
/// 上下集按钮永不渲染的问题(它的 hasPrevious/hasNext 取决于播放队列长度)。
class PlayerAudioHandler extends BaseAudioHandler {
  // ── 通知 / 锁屏 / 耳机线控按钮 → PlayerService ──
  @override
  Future<void> play() => PlayerService.instance.play();

  @override
  Future<void> pause() => PlayerService.instance.pause();

  @override
  Future<void> skipToNext() => PlayerService.instance.next();

  @override
  Future<void> skipToPrevious() => PlayerService.instance.prev();

  @override
  Future<void> seek(Duration position) => PlayerService.instance.seek(position);

  @override
  Future<void> stop() => PlayerService.instance.pause();

  static const _processingMap = <ProcessingState, AudioProcessingState>{
    ProcessingState.idle: AudioProcessingState.idle,
    ProcessingState.loading: AudioProcessingState.loading,
    ProcessingState.buffering: AudioProcessingState.buffering,
    ProcessingState.ready: AudioProcessingState.ready,
    ProcessingState.completed: AudioProcessingState.completed,
  };

  /// 切章或拿到时长时更新通知栏显示的曲目信息。
  void setNowPlaying({
    required String id,
    required String title,
    required String album,
    Uri? artUri,
    Duration? duration,
  }) {
    mediaItem.add(
      MediaItem(
        id: id,
        title: title,
        album: album,
        artUri: artUri,
        duration: duration,
      ),
    );
  }

  /// 广播播放状态到媒体通知 / 锁屏。控件按当前章节位置动态决定:
  /// 中间章节三键齐全,首章无「上一集」,尾章无「下一集」。
  void broadcast({
    required bool playing,
    required ProcessingState processing,
    required Duration position,
    required Duration buffered,
    required double speed,
  }) {
    final p = PlayerService.instance;
    final hasPrev = p.currentIndex > 0;
    final hasNext =
        p.currentIndex >= 0 && p.currentIndex < p.chapters.length - 1;
    final controls = <MediaControl>[
      if (hasPrev) MediaControl.skipToPrevious,
      if (playing) MediaControl.pause else MediaControl.play,
      if (hasNext) MediaControl.skipToNext,
    ];
    playbackState.add(
      playbackState.value.copyWith(
        controls: controls,
        systemActions: const {MediaAction.seek},
        androidCompactActionIndices: List.generate(controls.length, (i) => i),
        processingState:
            _processingMap[processing] ?? AudioProcessingState.idle,
        playing: playing,
        updatePosition: position,
        bufferedPosition: buffered,
        speed: speed,
      ),
    );
  }
}
