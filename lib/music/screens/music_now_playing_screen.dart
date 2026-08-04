import 'package:flutter/material.dart' hide RepeatMode;

import '../../widgets/cover_image.dart';
import '../music_player_service.dart';

class MusicNowPlayingScreen extends StatefulWidget {
  const MusicNowPlayingScreen({super.key});

  @override
  State<MusicNowPlayingScreen> createState() => _MusicNowPlayingScreenState();
}

class _MusicNowPlayingScreenState extends State<MusicNowPlayingScreen> {
  final _lyricScrollController = ScrollController();
  bool _showLyric = false;

  @override
  void dispose() {
    _lyricScrollController.dispose();
    super.dispose();
  }

  void _scrollToLyric(int index) {
    if (!_lyricScrollController.hasClients) return;
    if (index < 0) return;
    final target = index * 48.0;
    final clamped = target.clamp(0.0, _lyricScrollController.position.maxScrollExtent);
    _lyricScrollController.animateTo(
      clamped,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = MusicPlayerService.instance;
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: AnimatedBuilder(
          animation: Listenable.merge([p, p.metaListenable, p.lyricListenable]),
          builder: (context, _) {
            final song = p.currentSong;
            if (song == null) {
              return Center(
                child: Text('没有播放中的歌曲', style: TextStyle(color: cs.onSurfaceVariant)),
              );
            }
            return Column(
              children: [
                _buildAppBar(cs, song.name, song.singer),
                Expanded(
                  child: _showLyric
                      ? _buildLyricsView(cs)
                      : _buildCoverView(cs, song.img),
                ),
                _buildProgressBar(cs),
                _buildControls(cs),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildAppBar(ColorScheme cs, String title, String artist) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.keyboard_arrow_down),
            onPressed: () => Navigator.pop(context),
          ),
          Expanded(
            child: Column(
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
                Text(
                  artist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                ),
              ],
            ),
          ),
          IconButton(
            icon: Icon(_showLyric ? Icons.album : Icons.lyrics_outlined),
            tooltip: _showLyric ? '封面' : '歌词',
            onPressed: () => setState(() => _showLyric = !_showLyric),
          ),
        ],
      ),
    );
  }

  Widget _buildCoverView(ColorScheme cs, String img) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: AspectRatio(
          aspectRatio: 1,
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: cs.shadow.withValues(alpha: 0.3),
                  blurRadius: 20,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            clipBehavior: Clip.antiAlias,
            child: img.isNotEmpty
                ? CoverImage(
                    cover: img,
                    width: double.infinity,
                    height: double.infinity,
                    fit: BoxFit.cover,
                    fallback: Container(
                      color: cs.surfaceContainerHighest,
                      child: Icon(Icons.music_note, size: 80, color: cs.onSurfaceVariant),
                    ),
                  )
                : Container(
                    color: cs.surfaceContainerHighest,
                    child: Icon(Icons.music_note, size: 80, color: cs.onSurfaceVariant),
                  ),
          ),
        ),
      ),
    );
  }

  Widget _buildLyricsView(ColorScheme cs) {
    final p = MusicPlayerService.instance;
    final lines = p.lyric.lines;
    if (lines.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.lyrics_outlined, size: 48, color: cs.outline),
            const SizedBox(height: 12),
            Text('暂无歌词', style: TextStyle(color: cs.onSurfaceVariant)),
          ],
        ),
      );
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToLyric(p.currentLyricIndex));
    return ListView.builder(
      controller: _lyricScrollController,
      padding: const EdgeInsets.symmetric(vertical: 80),
      itemExtent: 48,
      itemCount: lines.length,
      itemBuilder: (context, i) {
        final isActive = i == p.currentLyricIndex;
        return GestureDetector(
          onTap: () {
            if (lines[i].time > Duration.zero) {
              p.seek(lines[i].time);
            }
          },
          child: Container(
            height: 48,
            alignment: Alignment.centerLeft,
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(
              lines[i].text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: isActive ? 18 : 15,
                color: isActive ? cs.primary : cs.onSurfaceVariant,
                fontWeight: isActive ? FontWeight.w700 : FontWeight.w400,
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildProgressBar(ColorScheme cs) {
    final p = MusicPlayerService.instance;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: AnimatedBuilder(
        animation: Listenable.merge([p.positionListenable, p.bufferedListenable]),
        builder: (context, _) {
          final total = p.duration.inMilliseconds;
          final pos = p.position.inMilliseconds;
          final buffered = p.bufferedPosition.inMilliseconds;
          return Column(
            children: [
              Stack(
                children: [
                  LinearProgressIndicator(
                    value: total > 0 ? (buffered / total).clamp(0.0, 1.0) : 0.0,
                    minHeight: 3,
                    backgroundColor: cs.surfaceContainerHighest,
                    color: cs.surfaceContainerHigh,
                  ),
                  Slider(
                    value: total > 0 ? (pos / total).clamp(0.0, 1.0) : 0.0,
                    onChanged: total > 0
                        ? (v) => p.seek(Duration(milliseconds: (v * total).toInt()))
                        : null,
                  ),
                ],
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(_fmtDuration(p.position), style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
                  Text(_fmtDuration(p.duration), style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
                ],
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildControls(ColorScheme cs) {
    final p = MusicPlayerService.instance;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          IconButton(
            icon: Icon(
              p.repeatMode == RepeatMode.single
                  ? Icons.repeat_one
                  : Icons.repeat,
            ),
            color: p.repeatMode != RepeatMode.none ? cs.primary : null,
            onPressed: p.cycleRepeatMode,
            tooltip: '循环模式',
          ),
          IconButton(
            icon: const Icon(Icons.skip_previous, size: 36),
            onPressed: p.prev,
            tooltip: '上一首',
          ),
          Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: cs.primaryContainer,
            ),
            child: IconButton(
              iconSize: 48,
              icon: p.loading
                  ? const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2.5),
                    )
                  : Icon(
                      p.playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                      color: cs.onPrimaryContainer,
                    ),
              onPressed: p.loading ? null : p.toggle,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.skip_next, size: 36),
            onPressed: p.next,
            tooltip: '下一首',
          ),
          IconButton(
            icon: Icon(p.shuffle ? Icons.shuffle : Icons.shuffle_outlined),
            color: p.shuffle ? cs.primary : null,
            onPressed: p.toggleShuffle,
            tooltip: '随机播放',
          ),
        ],
      ),
    );
  }

  String _fmtDuration(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }
}
