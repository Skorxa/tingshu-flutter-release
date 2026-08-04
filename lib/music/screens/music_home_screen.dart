import 'package:flutter/material.dart';

import '../music_source_manager.dart';

/// 音乐模式首页。
/// Phase 1: 平台入口占位 + 热门搜索引导。
/// Phase 2: 加入每日推荐(网易云) + 排行榜。
class MusicHomeScreen extends StatelessWidget {
  const MusicHomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final mgr = MusicSourceManager.instance;
    return Scaffold(
      body: SafeArea(
        child: AnimatedBuilder(
          animation: mgr,
          builder: (context, _) {
            final metas = mgr.metas;
            return CustomScrollView(
              slivers: [
                SliverAppBar.large(
                  title: const Text('橘听音乐'),
                ),
                SliverPadding(
                  padding: const EdgeInsets.all(16),
                  sliver: SliverToBoxAdapter(
                    child: Text(
                      '音乐平台',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                ),
                SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  sliver: SliverGrid(
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 2,
                      mainAxisSpacing: 12,
                      crossAxisSpacing: 12,
                      childAspectRatio: 2.2,
                    ),
                    delegate: SliverChildBuilderDelegate(
                      (context, i) {
                        final meta = metas[i];
                        final selected = meta.id == mgr.activeSourceId;
                        return Card(
                          color: selected ? cs.primaryContainer : null,
                          child: InkWell(
                            borderRadius: BorderRadius.circular(12),
                            onTap: () => mgr.setActiveSource(meta.id),
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.music_note,
                                    color: selected
                                        ? cs.onPrimaryContainer
                                        : cs.onSurfaceVariant,
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        Text(
                                          meta.name,
                                          style: TextStyle(
                                            fontWeight: FontWeight.w600,
                                            color: selected
                                                ? cs.onPrimaryContainer
                                                : null,
                                          ),
                                        ),
                                        if (meta.requiresLogin)
                                          Text(
                                            '需登录',
                                            style: TextStyle(
                                              fontSize: 11,
                                              color: selected
                                                  ? cs.onPrimaryContainer
                                                  : cs.onSurfaceVariant,
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                  if (selected)
                                    Icon(
                                      Icons.check_circle,
                                      color: cs.onPrimaryContainer,
                                    ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                      childCount: metas.length,
                    ),
                  ),
                ),
                SliverPadding(
                  padding: const EdgeInsets.all(16),
                  sliver: SliverToBoxAdapter(
                    child: Card(
                      child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(Icons.info_outline, color: cs.outline),
                            const SizedBox(height: 8),
                            Text(
                              '音乐模式 · Phase 1',
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '当前已支持酷我音乐搜索与播放。\n'
                              '网易云、每日推荐、歌词将在 Phase 2 加入。',
                              style: TextStyle(
                                color: cs.onSurfaceVariant,
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
