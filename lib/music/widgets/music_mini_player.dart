import 'package:flutter/material.dart';

import '../music_player_service.dart';
import '../screens/music_now_playing_screen.dart';
import '../../widgets/cover_image.dart';

class MusicMiniPlayer extends StatelessWidget {
  const MusicMiniPlayer({super.key});

  @override
  Widget build(BuildContext context) {
    final p = MusicPlayerService.instance;
    return ValueListenableBuilder<bool>(
      valueListenable: p.miniVisibleListenable,
      builder: (context, visible, _) {
        if (!visible) return const SizedBox.shrink();
        final cs = Theme.of(context).colorScheme;
        return Container(
          decoration: BoxDecoration(
            color: cs.surfaceContainerHigh,
            border: Border(top: BorderSide(color: cs.outlineVariant)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedBuilder(
                animation: p.positionListenable,
                builder: (context, _) {
                  final progress = p.duration.inMilliseconds > 0
                      ? p.position.inMilliseconds / p.duration.inMilliseconds
                      : 0.0;
                  return LinearProgressIndicator(
                    value: progress.clamp(0.0, 1.0),
                    minHeight: 2,
                    backgroundColor: cs.surfaceContainerHighest,
                  );
                },
              ),
              SafeArea(
                top: false,
                child: SizedBox(
                  height: 64,
                  child: Row(
                    children: [
                      const SizedBox(width: 14),
                      _MiniCover(cs: cs),
                      const SizedBox(width: 12),
                      Expanded(child: _MiniInfo(cs: cs)),
                      const SizedBox(width: 8),
                      const _MiniControls(),
                      const SizedBox(width: 8),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _MiniCover extends StatelessWidget {
  final ColorScheme cs;
  const _MiniCover({required this.cs});

  @override
  Widget build(BuildContext context) {
    final p = MusicPlayerService.instance;
    return ValueListenableBuilder<int>(
      valueListenable: p.metaListenable,
      builder: (context, _, _) {
        final song = p.currentSong;
        return Container(
          width: 46,
          height: 46,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            color: cs.surfaceContainerHighest,
          ),
          clipBehavior: Clip.antiAlias,
          child: song != null && song.img.isNotEmpty
              ? CoverImage(
                  cover: song.img,
                  width: 46,
                  height: 46,
                  fit: BoxFit.cover,
                  fallback: _fallback(cs),
                )
              : _fallback(cs),
        );
      },
    );
  }

  Widget _fallback(ColorScheme cs) => Container(
        width: 46,
        height: 46,
        color: cs.surfaceContainerHighest,
        child: Icon(Icons.music_note, color: cs.onSurfaceVariant, size: 20),
      );
}

class _MiniInfo extends StatelessWidget {
  final ColorScheme cs;
  const _MiniInfo({required this.cs});

  @override
  Widget build(BuildContext context) {
    final p = MusicPlayerService.instance;
    return ValueListenableBuilder<int>(
      valueListenable: p.metaListenable,
      builder: (context, _, _) {
        final song = p.currentSong;
        return InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const MusicNowPlayingScreen()),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 9),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  song?.name ?? '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  song?.singer ?? '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _MiniControls extends StatelessWidget {
  const _MiniControls();

  @override
  Widget build(BuildContext context) {
    final p = MusicPlayerService.instance;
    return ValueListenableBuilder<int>(
      valueListenable: p.controlsListenable,
      builder: (context, _, _) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.skip_previous),
            tooltip: '上一首',
            onPressed: p.currentIndex > 0 ? p.prev : null,
          ),
          IconButton.filledTonal(
            icon: p.loading
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(p.playing ? Icons.pause : Icons.play_arrow),
            tooltip: p.playing ? '暂停' : '播放',
            onPressed: p.loading ? null : p.toggle,
          ),
          IconButton(
            icon: const Icon(Icons.skip_next),
            tooltip: '下一首',
            onPressed: p.currentIndex < p.queue.length - 1 ? p.next : null,
          ),
        ],
      ),
    );
  }
}
