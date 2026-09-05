import 'dart:async';

import 'package:flutter/material.dart';
import 'package:audio_service/audio_service.dart';

import 'data/baidu_pan_service.dart';
import 'data/cloud_auth_service.dart';
import 'data/db.dart';
import 'data/listening_stats_service.dart';
import 'data/log_service.dart';
import 'data/quark_pan_service.dart';
import 'data/settings_service.dart';
import 'data/theme_service.dart';
import 'data/update_check_service.dart';
import 'data/webdav_service.dart';
import 'data/alist_service.dart';
import 'data/webdav_sync_service.dart';
import 'player/audio_handler.dart';
import 'player/player_service.dart';
import 'source/source_manager.dart';
import 'screens/discover_screen.dart';
import 'screens/cloud_auth_screen.dart';
import 'screens/search_screen.dart';
import 'screens/shelf_screen.dart';
import 'screens/source_screen.dart';
import 'widgets/mini_player.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterError.onError = (details) {
    LogService.instance.error(
      'Flutter',
      '框架异常',
      error: details.exception,
      stack: details.stack,
    );
    FlutterError.presentError(details);
  };
  LogService.instance.info('App', '应用启动');
  final audioHandler = await AudioService.init(
    builder: () => PlayerAudioHandler(),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.tingshu.audio',
      androidNotificationChannelName: '橘听',
      androidNotificationChannelDescription: '听书播放控制与后台播放',
      androidNotificationOngoing: true,
      androidStopForegroundOnPause: true,
      artDownscaleWidth: 512,
      artDownscaleHeight: 512,
    ),
  );
  PlayerService.instance.attachHandler(audioHandler);
  try {
    await SettingsService.instance.init();
    LogService.instance.info('Settings', '设置加载完成');
  } catch (e, stack) {
    LogService.instance.error('Settings', '设置加载失败', error: e, stack: stack);
  }
  try {
    await getDb(); // 初始化数据库(建表)
    LogService.instance.info('Database', '数据库初始化完成');
  } catch (e, stack) {
    LogService.instance.error('Database', '数据库初始化失败', error: e, stack: stack);
  }
  try {
    await CloudAuthService.instance.init();
    LogService.instance.info(
      'CloudAuth',
      '云端授权服务初始化完成',
      detail: '状态: ${CloudAuthService.instance.stateLabel}',
    );
  } catch (e, stack) {
    LogService.instance.error(
      'CloudAuth',
      '云端授权服务初始化失败',
      error: e,
      stack: stack,
    );
  }
  try {
    await SourceManager.instance.init();
    LogService.instance.info('Source', '音源初始化完成');
  } catch (e, stack) {
    LogService.instance.error('Source', '音源初始化失败', error: e, stack: stack);
  }

  ThemeService.instance; // 触发构造:启动封面取色监听
  runApp(const TingshuApp());

  // 非关键服务移到首帧之后初始化:收听统计与网盘/同步只在进入对应页面时才被
  // 用到,不必挡住首帧。保持 WebDav → WebDavSync 的顺序(同步首次迁移依赖
  // 书库 WebDAV 配置),各步骤独立捕获异常,单个失败不影响其余模块。
  WidgetsBinding.instance.addPostFrameCallback((_) {
    unawaited(_initDeferredServices());
  });
}

Future<void> _initDeferredServices() async {
  try {
    await ListeningStatsService.instance.init();
    LogService.instance.info('Stats', '听书统计加载完成');
  } catch (e, stack) {
    LogService.instance.error('Stats', '听书统计加载失败', error: e, stack: stack);
  }
  try {
    await WebDavService.instance.init();
    LogService.instance.info('WebDAV', '配置加载完成');
  } catch (e, stack) {
    LogService.instance.error('WebDAV', '配置加载失败', error: e, stack: stack);
  }
  try {
    await BaiduPanService.instance.init();
    LogService.instance.info('BaiduPan', '配置加载完成');
  } catch (e, stack) {
    LogService.instance.error('BaiduPan', '配置加载失败', error: e, stack: stack);
  }
  try {
    await QuarkPanService.instance.init();
    LogService.instance.info('QuarkPan', '配置加载完成');
  } catch (e, stack) {
    LogService.instance.error('QuarkPan', '配置加载失败', error: e, stack: stack);
  }
  try {
    await AlistService.instance.init();
    LogService.instance.info('Alist', '配置加载完成');
  } catch (e, stack) {
    LogService.instance.error('Alist', '配置加载失败', error: e, stack: stack);
  }
  try {
    await WebDavSyncService.instance.init();
    LogService.instance.info('Sync', 'WebDAV 同步服务初始化完成');
  } catch (e, stack) {
    LogService.instance.error('Sync', 'WebDAV 同步服务初始化失败', error: e, stack: stack);
  }
  try {
    UpdateCheckService.instance.init();
    LogService.instance.info('UpdateCheck', '追更检查服务已就绪');
  } catch (e, stack) {
    LogService.instance.error('UpdateCheck', '追更检查服务初始化失败', error: e, stack: stack);
  }
}

class TingshuApp extends StatelessWidget {
  const TingshuApp({super.key});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([
        SettingsService.instance,
        ThemeService.instance,
      ]),
      builder: (context, _) => MaterialApp(
        title: '橘听',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ThemeService.instance.light,
          useMaterial3: true,
        ),
        darkTheme: ThemeData(
          colorScheme: ThemeService.instance.dark,
          useMaterial3: true,
        ),
        themeMode: SettingsService.instance.darkMode
            ? ThemeMode.dark
            : ThemeMode.light,
        home: const CloudAuthGate(child: HomeShell()),
      ),
    );
  }
}

/// 底部导航:发现 / 搜索 / 书架 / 设置 + 全局 MiniPlayer
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _idx = 0;
  final _pages = const [
    DiscoverScreen(),
    SearchScreen(),
    ShelfScreen(),
    SourceScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          Expanded(
            child: IndexedStack(index: _idx, children: _pages),
          ),
          const MiniPlayer(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _idx,
        onDestinationSelected: (i) => setState(() => _idx = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.explore_outlined),
            selectedIcon: Icon(Icons.explore),
            label: '发现',
          ),
          NavigationDestination(
            icon: Icon(Icons.search_outlined),
            selectedIcon: Icon(Icons.search),
            label: '搜索',
          ),
          NavigationDestination(
            icon: Icon(Icons.bookmark_border),
            selectedIcon: Icon(Icons.bookmark),
            label: '书架',
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
