import 'package:flutter/material.dart';

import '../widgets/music_mini_player.dart';
import 'music_search_screen.dart';
import 'music_home_screen.dart';
import 'music_settings_screen.dart';

/// 音乐模式底部导航:首页 / 搜索 / 歌单 / 设置 + 全局 MusicMiniPlayer
class MusicHomeShell extends StatefulWidget {
  const MusicHomeShell({super.key});

  @override
  State<MusicHomeShell> createState() => _MusicHomeShellState();
}

class _MusicHomeShellState extends State<MusicHomeShell> {
  int _idx = 0;
  final _pages = const [
    MusicHomeScreen(),
    MusicSearchScreen(),
    MusicHomeScreen(), // 歌单(Phase 4 实现,暂时复用首页占位)
    MusicSettingsScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          Expanded(
            child: IndexedStack(index: _idx, children: _pages),
          ),
          const MusicMiniPlayer(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _idx,
        onDestinationSelected: (i) => setState(() => _idx = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home),
            label: '首页',
          ),
          NavigationDestination(
            icon: Icon(Icons.search_outlined),
            selectedIcon: Icon(Icons.search),
            label: '搜索',
          ),
          NavigationDestination(
            icon: Icon(Icons.queue_music_outlined),
            selectedIcon: Icon(Icons.queue_music),
            label: '歌单',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: '设置',
          ),
        ],
      ),
    );
  }
}
