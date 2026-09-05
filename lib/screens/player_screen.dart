import 'package:flutter/material.dart';

import '../data/cache_service.dart';
import '../data/shelf_service.dart';
import '../player/player_service.dart';
import '../source/source_manager.dart';
import '../widgets/cover_image.dart';
import 'player_catalog_screen.dart';
import 'source_switch_screen.dart';

class PlayerScreen extends StatelessWidget {
  const PlayerScreen({super.key});

  static const _speeds = [0.75, 1.0, 1.25, 1.5, 2.0];
  static const _sleepModes = ['按集关闭', '按时关闭'];

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(600).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  Future<void> _showSleepTimer(BuildContext context) async {
    final p = PlayerService.instance;
    var modeIndex = 0;
    var selectedValue = 1;

    List<int> values() {
      if (modeIndex == 0) return List.generate(30, (i) => i + 1);
      return List.generate(180, (i) => i + 1);
    }

    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            final currentValues = values();
            final unit = modeIndex == 0 ? '集' : '分钟';
            return SafeArea(
              child: SizedBox(
                height: 340,
                child: Column(
                  children: [
                    const Padding(
                      padding: EdgeInsets.only(bottom: 8),
                      child: Text(
                        '定时关闭',
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Row(
                        children: [
                          Expanded(
                            child: _wheel(
                              children: [
                                for (final mode in _sleepModes) Text(mode),
                              ],
                              onSelectedItemChanged: (index) {
                                setSheetState(() {
                                  modeIndex = index;
                                  selectedValue = 1;
                                });
                              },
                            ),
                          ),
                          Expanded(
                            child: _wheel(
                              key: ValueKey(modeIndex),
                              children: [
                                for (final value in currentValues)
                                  Text('$value $unit'),
                              ],
                              onSelectedItemChanged: (index) {
                                selectedValue = currentValues[index];
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                      child: Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed: () {
                                p.clearSleepTimer();
                                Navigator.pop(ctx);
                              },
                              child: const Text('清除计时'),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: FilledButton(
                              onPressed: () {
                                if (modeIndex == 0) {
                                  p.setSleepByChapters(selectedValue);
                                } else {
                                  p.setSleepByMinutes(selectedValue);
                                }
                                Navigator.pop(ctx);
                              },
                              child: const Text('确定'),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _wheel({
    Key? key,
    required List<Widget> children,
    required ValueChanged<int> onSelectedItemChanged,
  }) {
    return ListWheelScrollView.useDelegate(
      key: key,
      itemExtent: 42,
      diameterRatio: 1.4,
      physics: const FixedExtentScrollPhysics(),
      onSelectedItemChanged: onSelectedItemChanged,
      childDelegate: ListWheelChildBuilderDelegate(
        childCount: children.length,
        builder: (context, index) {
          if (index < 0 || index >= children.length) return null;
          return Center(child: children[index]);
        },
      ),
    );
  }

  Widget _cacheCountdown(BuildContext context, ColorScheme cs) {
    final cache = CacheService.instance;
    return ValueListenableBuilder<String>(
      valueListenable: cache.countdownNotifier,
      builder: (context, label, child) {
        if (!cache.countdownVisible) return const SizedBox.shrink();
        return GestureDetector(
          onLongPress: cache.syncing
              ? null
              : () async {
                  await cache.triggerNow();
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(const SnackBar(content: Text('已触发缓存任务')));
                },
          child: Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              label,
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = PlayerService.instance;
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: cs.surface,
      appBar: AppBar(
        title: const Text('正在播放'),
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: const [_ShelfButton()],
      ),
      body: AnimatedBuilder(
        animation: p,
        builder: (context, _) {
          final total = p.chapters.length;
          final subtitle = [
            if (p.bookTitle.isNotEmpty) p.bookTitle,
            if (total > 0) '${p.currentIndex + 1}/$total',
          ].join('  ·  ');
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
              child: Column(
                children: [
                  // 封面 - 更大的圆角和柔和阴影
                  Expanded(
                    child: Center(
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final side = constraints.biggest.shortestSide;
                          final coverSize = (side > 360 ? 360.0 : side) * 0.95;
                          return _coverBox(p.cover, cs, coverSize);
                        },
                      ),
                    ),
                  ),
                  const SizedBox(height: 28),
                  // 标题 - 更大字号
                  Text(
                    p.currentChapterName.isEmpty
                        ? '未在播放'
                        : p.currentChapterName,
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      height: 1.3,
                    ),
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (subtitle.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 14,
                        color: cs.onSurfaceVariant,
                      ),
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                  _cacheCountdown(context, cs),
                  if (p.error != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      p.error!,
                      style: TextStyle(fontSize: 13, color: cs.error),
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                  const SizedBox(height: 20),
                  // 进度区(时间/进度条)随 position 高频刷新,其余控件不参与重建
                  AnimatedBuilder(
                    animation: p.positionListenable,
                    builder: (context, _) {
                      final dur = p.duration.inMilliseconds.toDouble();
                      final pos = p.position.inMilliseconds
                          .toDouble()
                          .clamp(0, dur)
                          .toDouble();
                      final buffered = p.bufferedPosition.inMilliseconds
                          .toDouble()
                          .clamp(pos, dur)
                          .toDouble();
                      return Column(
                        children: [
                          SliderTheme(
                            data: SliderTheme.of(context).copyWith(
                              trackHeight: 3,
                              thumbShape: const RoundSliderThumbShape(
                                enabledThumbRadius: 6,
                              ),
                              overlayShape: const RoundSliderOverlayShape(
                                overlayRadius: 14,
                              ),
                            ),
                            child: Slider(
                              value: dur > 0 ? pos : 0,
                              max: dur > 0 ? dur : 1,
                              secondaryTrackValue: dur > 0 ? buffered : null,
                              secondaryActiveColor: cs.primary.withValues(
                                alpha: 0.24,
                              ),
                              onChanged: dur > 0
                                  ? (v) => p.seek(
                                      Duration(milliseconds: v.toInt()),
                                    )
                                  : null,
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  _fmt(p.position),
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: cs.onSurfaceVariant,
                                  ),
                                ),
                                Text(
                                  _fmt(p.duration),
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: cs.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: 8),
                  // 控制区:快退 10s / 上一集 / 播放暂停 / 下一集 / 快进 30s
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      IconButton(
                        iconSize: 30,
                        icon: const Icon(Icons.replay_10),
                        tooltip: '后退 10 秒',
                        onPressed: p.bookId.isEmpty
                            ? null
                            : () => p.seekBy(-10),
                      ),
                      IconButton(
                        iconSize: 36,
                        icon: const Icon(Icons.skip_previous),
                        tooltip: '上一集',
                        onPressed: p.currentIndex > 0 ? p.prev : null,
                      ),
                      Container(
                        decoration: BoxDecoration(
                          color: cs.primary,
                          shape: BoxShape.circle,
                        ),
                        child: IconButton(
                          iconSize: 44,
                          color: cs.onPrimary,
                          icon: p.loading
                              ? SizedBox(
                                  width: 28,
                                  height: 28,
                                  child: CircularProgressIndicator(
                                    color: cs.onPrimary,
                                    strokeWidth: 3,
                                  ),
                                )
                              : Icon(
                                  p.playing ? Icons.pause : Icons.play_arrow,
                                ),
                          tooltip: p.playing ? '暂停' : '播放',
                          onPressed: p.loading ? null : p.toggle,
                        ),
                      ),
                      IconButton(
                        iconSize: 36,
                        icon: const Icon(Icons.skip_next),
                        tooltip: '下一集',
                        onPressed: p.currentIndex < p.chapters.length - 1
                            ? p.next
                            : null,
                      ),
                      IconButton(
                        iconSize: 30,
                        icon: const Icon(Icons.forward_30),
                        tooltip: '前进 30 秒',
                        onPressed: p.bookId.isEmpty ? null : () => p.seekBy(30),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  const Divider(height: 1),
                  // 底部工具条:倍速 · 定时 · 目录
                  Row(
                    children: [
                      _toolButton(
                        cs,
                        icon: Icons.speed,
                        label: '${p.speed}x',
                        onTap: () {
                          final i = _speeds.indexOf(p.speed);
                          p.setSpeed(_speeds[(i + 1) % _speeds.length]);
                        },
                      ),
                      _toolButton(
                        cs,
                        icon: Icons.timer_outlined,
                        label: p.sleepTimerActive ? p.sleepTimerLabel : '定时',
                        highlight: p.sleepTimerActive,
                        onTap: () => _showSleepTimer(context),
                      ),
                      _toolButton(
                        cs,
                        icon: Icons.format_list_bulleted,
                        label: '目录',
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const PlayerCatalogScreen(),
                          ),
                        ),
                      ),
                      _toolButton(
                        cs,
                        icon: Icons.swap_horizontal_circle_outlined,
                        label: '换源',
                        onTap: () {
                          if (p.bookId.isEmpty) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('当前没有正在播放的书')),
                            );
                            return;
                          }
                          final chapterName =
                              p.currentIndex >= 0 &&
                                  p.currentIndex < p.chapters.length
                              ? '${p.chapters[p.currentIndex]['name'] ?? ''}'
                              : '';
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => SourceSwitchScreen(
                                sourceId: p.sourceId,
                                bookId: p.bookId,
                                bookTitle: p.bookTitle,
                                currentChapterName: chapterName,
                                currentIndex: p.currentIndex,
                              ),
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _coverBox(String cover, ColorScheme cs, double size) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: cs.shadow.withValues(alpha: 0.26),
            blurRadius: 28,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: cover.isNotEmpty ? _coverImage(cover, cs) : _coverFallback(cs),
      ),
    );
  }

  Widget _toolButton(
    ColorScheme cs, {
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool highlight = false,
  }) {
    final color = highlight ? cs.primary : cs.onSurfaceVariant;
    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 22, color: color),
              const SizedBox(height: 4),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: color),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // 填充父约束的封面渲染:支持 http(s) 网络封面与本地缓存文件封面
  Widget _coverImage(String cover, ColorScheme cs) {
    return CoverImage(
      cover: cover,
      width: 240,
      height: 240,
      fit: BoxFit.cover,
      fallback: _coverFallback(cs),
    );
  }

  Widget _coverFallback(ColorScheme cs) => Container(
    color: cs.surfaceContainerHighest,
    alignment: Alignment.center,
    child: Icon(Icons.album, color: cs.onSurfaceVariant, size: 64),
  );
}

/// AppBar 右上角「加入/移出书架」按钮:自管理收藏状态,随书架与当前播放书变化刷新。
class _ShelfButton extends StatefulWidget {
  const _ShelfButton();

  @override
  State<_ShelfButton> createState() => _ShelfButtonState();
}

class _ShelfButtonState extends State<_ShelfButton> {
  bool _inShelf = false;
  String _checkedKey = '';

  @override
  void initState() {
    super.initState();
    ShelfService.instance.addListener(_refresh);
    PlayerService.instance.addListener(_onPlayerChanged);
    _refresh();
  }

  @override
  void dispose() {
    ShelfService.instance.removeListener(_refresh);
    PlayerService.instance.removeListener(_onPlayerChanged);
    super.dispose();
  }

  // 当前播放书切换时(sourceId:bookId 变化)才重新查询,其余低频通知忽略
  void _onPlayerChanged() {
    final p = PlayerService.instance;
    if ('${p.sourceId}:${p.bookId}' != _checkedKey) _refresh();
  }

  Future<void> _refresh() async {
    final p = PlayerService.instance;
    _checkedKey = '${p.sourceId}:${p.bookId}';
    if (p.bookId.isEmpty) {
      if (mounted) setState(() => _inShelf = false);
      return;
    }
    final v = await ShelfService.instance.contains(
      sourceId: p.sourceId,
      bookId: p.bookId,
    );
    if (mounted) setState(() => _inShelf = v);
  }

  Future<void> _toggle() async {
    final p = PlayerService.instance;
    if (p.bookId.isEmpty) return;
    final wasInShelf = _inShelf;
    if (wasInShelf) {
      await ShelfService.instance.remove(
        sourceId: p.sourceId,
        bookId: p.bookId,
      );
    } else {
      await ShelfService.instance.add(
        sourceId: p.sourceId,
        bookId: p.bookId,
        title: p.bookTitle,
        cover: p.cover,
        author: '',
        sourceName: SourceManager.instance.getSourceName(p.sourceId),
      );
    }
    // 书架变更会经 ShelfService 通知触发 _refresh 更新图标
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(wasInShelf ? '已移出书架' : '已加入书架')));
  }

  @override
  Widget build(BuildContext context) {
    final p = PlayerService.instance;
    if (p.bookId.isEmpty) return const SizedBox.shrink();
    final cs = Theme.of(context).colorScheme;
    return IconButton(
      icon: Icon(_inShelf ? Icons.bookmark : Icons.bookmark_border),
      color: _inShelf ? cs.primary : null,
      tooltip: _inShelf ? '移出书架' : '加入书架',
      onPressed: _toggle,
    );
  }
}
