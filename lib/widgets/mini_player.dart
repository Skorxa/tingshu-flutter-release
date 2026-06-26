import 'package:flutter/material.dart';

import '../player/player_service.dart';
import '../screens/player_screen.dart';
import 'cover_image.dart';

class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context) {
    final p = PlayerService.instance;
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
              // 仅进度条随 position 高频刷新,封面/文字/按钮不参与重建
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
    final p = PlayerService.instance;
    return ValueListenableBuilder<int>(
      valueListenable: p.miniMetaListenable,
      builder: (context, _, _) => _cover(p.cover, cs),
    );
  }

  Widget _cover(String cover, ColorScheme cs) {
    return Container(
      width: 46,
      height: 46,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: cs.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: cover.isNotEmpty ? _coverImage(cover, cs) : _fallback(cs),
    );
  }

  Widget _coverImage(String cover, ColorScheme cs) {
    return CoverImage(
      cover: cover,
      width: 46,
      height: 46,
      fit: BoxFit.cover,
      fallback: _fallback(cs),
    );
  }

  Widget _fallback(ColorScheme cs) => Container(
    width: 46,
    height: 46,
    color: cs.surfaceContainerHighest,
    child: Icon(Icons.album, color: cs.onSurfaceVariant, size: 20),
  );
}

class _MiniInfo extends StatelessWidget {
  final ColorScheme cs;

  const _MiniInfo({required this.cs});

  @override
  Widget build(BuildContext context) {
    final p = PlayerService.instance;
    return ValueListenableBuilder<int>(
      valueListenable: p.miniMetaListenable,
      builder: (context, _, _) => InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const PlayerScreen()),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 9),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _ScrollingText(
                p.currentChapterName,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              _ScrollingText(
                p.bookTitle,
                style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MiniControls extends StatelessWidget {
  const _MiniControls();

  @override
  Widget build(BuildContext context) {
    final p = PlayerService.instance;
    return ValueListenableBuilder<int>(
      valueListenable: p.miniControlsListenable,
      builder: (context, _, _) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.skip_previous),
            tooltip: '上一集',
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
            tooltip: '下一集',
            onPressed: p.currentIndex < p.chapters.length - 1 ? p.next : null,
          ),
        ],
      ),
    );
  }
}

class _ScrollingText extends StatefulWidget {
  final String text;
  final TextStyle style;

  const _ScrollingText(this.text, {required this.style});

  @override
  State<_ScrollingText> createState() => _ScrollingTextState();
}

class _ScrollingTextState extends State<_ScrollingText> {
  final ScrollController _controller = ScrollController();
  bool _running = false;
  bool _disposed = false;
  bool _tickerEnabled = true;

  @override
  void initState() {
    super.initState();
    _schedule();
  }

  @override
  void didUpdateWidget(covariant _ScrollingText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) _schedule();
  }

  @override
  void dispose() {
    _disposed = true;
    _controller.dispose();
    super.dispose();
  }

  void _schedule() {
    if (_disposed || _running) return;
    _running = true;
    WidgetsBinding.instance.addPostFrameCallback((_) => _scroll());
  }

  Future<void> _scroll() async {
    if (_disposed || !mounted || !_controller.hasClients) {
      _running = false;
      return;
    }
    // 页面不可见时暂停动画,避免后台循环
    if (!_tickerEnabled) {
      _running = true; // 保持标记,恢复可见后继续
      await Future<void>.delayed(const Duration(milliseconds: 500));
      if (_disposed || !mounted) { _running = false; return; }
      WidgetsBinding.instance.addPostFrameCallback((_) => _scroll());
      return;
    }
    final max = _controller.position.maxScrollExtent;
    if (max <= 0) {
      _running = false;
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 800));
    if (_disposed || !mounted || !_controller.hasClients) {
      _running = false;
      return;
    }
    await _controller.animateTo(
      max,
      duration: Duration(milliseconds: (max * 45).clamp(1800, 8000).toInt()),
      curve: Curves.linear,
    );
    await Future<void>.delayed(const Duration(milliseconds: 700));
    if (_disposed || !mounted || !_controller.hasClients) {
      _running = false;
      return;
    }
    _controller.jumpTo(0);
    _running = false;
    _schedule();
  }

  @override
  Widget build(BuildContext context) {
    _tickerEnabled = TickerMode.valuesOf(context).enabled;
    return SizedBox(
      height: (widget.style.fontSize ?? 13) + 4,
      child: SingleChildScrollView(
        controller: _controller,
        scrollDirection: Axis.horizontal,
        physics: const NeverScrollableScrollPhysics(),
        child: Text(
          widget.text,
          maxLines: 1,
          softWrap: false,
          style: widget.style,
        ),
      ),
    );
  }
}
