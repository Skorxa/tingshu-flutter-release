import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart' show ProcessingState;

import 'music_player_service.dart';

/// 音乐模式后台处理器:接管媒体通知/锁屏/耳机线控。
class MusicAudioHandler extends BaseAudioHandler {
  @override
  Future<void> play() => MusicPlayerService.instance.play();

  @override
  Future<void> pause() => MusicPlayerService.instance.pause();

  @override
  Future<void> skipToNext() => MusicPlayerService.instance.next();

  @override
  Future<void> skipToPrevious() => MusicPlayerService.instance.prev();

  @override
  Future<void> seek(Duration position) =>
      MusicPlayerService.instance.seek(position);

  @override
  Future<void> stop() => MusicPlayerService.instance.pause();

  static const _processingMap = <ProcessingState, AudioProcessingState>{
    ProcessingState.idle: AudioProcessingState.idle,
    ProcessingState.loading: AudioProcessingState.loading,
    ProcessingState.buffering: AudioProcessingState.buffering,
    ProcessingState.ready: AudioProcessingState.ready,
    ProcessingState.completed: AudioProcessingState.completed,
  };

  void setNowPlaying({
    required String id,
    required String title,
    String album = '',
    String artist = '',
    Uri? artUri,
    Duration? duration,
  }) {
    mediaItem.add(
      MediaItem(
        id: id,
        title: title,
        album: album.isEmpty ? null : album,
        artist: artist.isEmpty ? null : artist,
        artUri: artUri,
        duration: duration,
      ),
    );
  }

  void broadcast({
    required bool playing,
    required ProcessingState processing,
    required Duration position,
    required Duration buffered,
    required double speed,
  }) {
    final p = MusicPlayerService.instance;
    final hasPrev = p.currentIndex > 0;
    final hasNext = p.currentIndex >= 0 && p.currentIndex < p.queue.length - 1;
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
