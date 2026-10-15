import 'dart:async';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../data/catalog_cache_service.dart';
import '../data/log_service.dart';
import '../data/pan115_service.dart';
import '../data/shelf_service.dart';
import '../player/player_service.dart';
import '../widgets/cover_image.dart';
import 'player_screen.dart';

/// 115 网盘书库页面。
///
/// 接入方式遵循 115 官方开放平台 OAuth2 Device Code + PKCE 扫码登录:
/// 1. 用户输入 AppID，点击扫码登录；
/// 2. 请求 `open/authDeviceCode` 生成二维码内容，展示 QR 码；
/// 3. 长轮询 `get/status/`，扫码确认后调用 `open/authCodeToToken` 换取 Token；
/// 4. 浏览网盘文件目录、单集播放、播放整本、加入书架、目录离线缓存。
class Pan115Screen extends StatefulWidget {
  const Pan115Screen({super.key});

  @override
  State<Pan115Screen> createState() => _Pan115ScreenState();
}

class _Pan115PathEntry {
  final String cid;
  final String name;

  const _Pan115PathEntry(this.cid, this.name);
}

class _Pan115ScreenState extends State<Pan115Screen> {
  final List<_Pan115PathEntry> _pathStack = const [
    _Pan115PathEntry(Pan115Service.rootCid, '根目录'),
  ].toList();
  final ScrollController _scrollController = ScrollController();

  List<Pan115Item> _items = [];
  bool _loading = false;
  bool _loadingMore = false;
  bool _hasMore = false;
  int _currentPage = 1;
  int _totalCount = 0;
  bool _checkingLogin = false;

  bool? _loginValid;
  String? _error;
  String _coverPath = '';
  Map<String, dynamic> _userInfo = const {};

  _Pan115PathEntry get _current => _pathStack.last;
  String get _currentFid => _current.cid;
  String get _currentName => _current.name;

  bool _isBookName(String name) =>
      Pan115Service.instance.parseBookFolderName(name) != null;

  bool get _isBookFolder => _isBookName(_currentName);

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _bootstrap();
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final maxScroll = _scrollController.position.maxScrollExtent;
    final currentScroll = _scrollController.position.pixels;
    // 距离底部 200 像素时自动触发加载下一页
    if (maxScroll - currentScroll <= 200) {
      if (!_loading && !_loadingMore && _hasMore) {
        _loadMore();
      }
    }
  }

  Future<void> _bootstrap() async {
    final service = Pan115Service.instance;
    if (!service.ready) {
      await service.init();
    }
    if (!mounted) return;
    if (!service.ready) {
      LogService.instance.info('Pan115', '尚未登录，等待用户登录');
      return;
    }
    setState(() {});
    await _load(Pan115Service.rootCid, '根目录', replace: true);
    await _checkLogin(showToast: false);
    _loadUserInfo();
  }

  Future<void> _loadUserInfo() async {
    if (!Pan115Service.instance.ready ||
        Pan115Service.instance.accessToken.isEmpty) {
      return;
    }
    try {
      final info = await Pan115Service.instance.getUserInfo();
      if (!mounted) return;
      setState(() => _userInfo = info);
    } catch (_) {}
  }

  // ── 账号管理 ──

  /// 扫码登录 (OAuth2 Device Code + PKCE)
  Future<void> _qrLogin() async {
    final success = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _QrLoginDialog(
        initialAppId: Pan115Service.instance.appId,
      ),
    );
    if (success == true) {
      _toast('115 扫码登录成功');
      if (!mounted) return;
      setState(() {
        _loginValid = true;
        _error = null;
      });
      await _load(Pan115Service.rootCid, '根目录', replace: true);
      _loadUserInfo();
    }
  }

  /// 手动设置 Token / AppID
  Future<void> _manualToken() async {
    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (_) => _ManualTokenDialog(
        initialAppId: Pan115Service.instance.appId,
        initialAccessToken: Pan115Service.instance.accessToken,
        initialRefreshToken: Pan115Service.instance.refreshToken,
      ),
    );
    if (result == null) return;
    final appId = result['app_id'] ?? '';
    final accessToken = result['access_token'] ?? '';
    final refreshToken = result['refresh_token'] ?? '';
    if (accessToken.isEmpty) {
      _toast('Token 不能为空');
      return;
    }

    setState(() => _loading = true);
    try {
      await Pan115Service.instance.saveTokenManual(
        appId: appId,
        accessToken: accessToken,
        refreshToken: refreshToken,
      );
      if (!mounted) return;
      setState(() {
        _loginValid = null;
        _error = null;
      });
      _toast('115 Token 已保存');
      await _checkLogin(showToast: false);
      await _load(Pan115Service.rootCid, '根目录', replace: true);
    } catch (e) {
      LogService.instance.error('Pan115', '保存 Token 失败', error: e);
      _toast(e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 手动粘贴 Cookie 兜底
  Future<void> _pasteCookie() async {
    final value = await showDialog<String>(
      context: context,
      builder: (_) => const _CookiePasteDialog(),
    );
    final cookie = (value ?? '').trim();
    if (cookie.isEmpty) return;
    setState(() => _loading = true);
    try {
      await Pan115Service.instance.saveCookie(cookie);
      if (!mounted) return;
      setState(() {
        _loginValid = null;
        _error = null;
      });
      _toast('Cookie 已保存');
      await _checkLogin(showToast: false);
      await _load(Pan115Service.rootCid, '根目录', replace: true);
    } catch (e) {
      LogService.instance.error('Pan115', '保存 Cookie 失败', error: e);
      _toast(e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _checkLogin({bool showToast = true}) async {
    if (!mounted || !Pan115Service.instance.ready || _checkingLogin) return;
    setState(() => _checkingLogin = true);
    final ok = await Pan115Service.instance.checkLogin();
    if (!mounted) return;
    setState(() {
      _loginValid = ok;
      _checkingLogin = false;
    });
    if (showToast) {
      _toast(ok ? '115 连接状态正常' : '连接状态可能已失效，请重新登录');
    }
  }

  Future<void> _refreshToken() async {
    setState(() => _loading = true);
    try {
      final ok = await Pan115Service.instance.refreshAccessToken();
      if (!mounted) return;
      if (ok) {
        _toast('115 Token 刷新成功');
        setState(() => _loginValid = true);
      } else {
        _toast('刷新 Token 失败，请重新扫码登录');
      }
    } catch (e) {
      _toast('刷新异常: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _logout() async {
    await Pan115Service.instance.logout();
    if (!mounted) return;
    setState(() {
      _items = [];
      _loginValid = null;
      _error = null;
      _coverPath = '';
      _pathStack
        ..clear()
        ..add(const _Pan115PathEntry(Pan115Service.rootCid, '根目录'));
    });
    LogService.instance.info('Pan115', '已退出 115 网盘');
    _toast('已退出 115 网盘');
  }

  // ── 目录浏览（动态分页流式加载）──

  Future<void> _load(String cid, String name, {bool replace = false}) async {
    setState(() {
      _loading = true;
      _loadingMore = false;
      _error = null;
      _currentPage = 1;
      _items = [];
    });
    try {
      final pageData = await Pan115Service.instance.listPage(cid, page: 1);
      if (!mounted) return;
      setState(() {
        _items = pageData.items;
        _hasMore = pageData.hasMore;
        _totalCount = pageData.total;
        _coverPath = '';
        if (replace) {
          _pathStack
            ..clear()
            ..add(_Pan115PathEntry(cid, name));
        } else {
          _pathStack.add(_Pan115PathEntry(cid, name));
        }
      });
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(0);
      }
      LogService.instance.info(
        'Pan115',
        '动态打开目录第一页',
        detail:
            'CID: $cid\n名称: $name\n首页条目: ${pageData.items.length}\n总数: ${pageData.total}\n更多: ${pageData.hasMore}',
      );
      if (_isBookName(name)) {
        unawaited(_identifyCover(cid, pageData.items));
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
      LogService.instance.error('Pan115', '列目录失败', error: e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadMore() async {
    if (_loading || _loadingMore || !_hasMore) return;
    setState(() => _loadingMore = true);
    final nextPage = _currentPage + 1;
    final cid = _currentFid;

    try {
      final pageData = await Pan115Service.instance.listPage(cid, page: nextPage);
      if (!mounted || _currentFid != cid) return;
      setState(() {
        _currentPage = nextPage;
        _items.addAll(pageData.items);
        _hasMore = pageData.hasMore;
        if (pageData.total > 0) _totalCount = pageData.total;
      });
      LogService.instance.info(
        'Pan115',
        '加载下一页完成',
        detail:
            'CID: $cid\n页码: $nextPage\n新增: ${pageData.items.length}\n累计: ${_items.length}\n更多: ${pageData.hasMore}',
      );
    } catch (e) {
      LogService.instance.warning('Pan115', '加载更多失败', detail: '$e');
      if (mounted) _toast('加载更多失败: ${e.toString().replaceFirst('Exception: ', '')}');
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  Future<void> _identifyCover(String cid, List<Pan115Item> items) async {
    final coverItem = Pan115Service.instance.findCoverItem(items);
    if (coverItem == null) return;
    try {
      final path = await Pan115Service.instance.cacheCover(coverItem);
      if (!mounted || _currentFid != cid) return;
      setState(() => _coverPath = path);
    } catch (e) {
      LogService.instance.warning('Pan115', '识别封面失败', detail: '$e');
    }
  }

  void _goUp() {
    if (_pathStack.length <= 1) return;
    _pathStack.removeLast();
    final target = _current;
    _load(target.cid, target.name, replace: true);
  }

  void _jumpTo(int index) {
    if (index < 0 || index >= _pathStack.length - 1) return;
    final target = _pathStack[index];
    _pathStack.removeRange(index + 1, _pathStack.length);
    _load(target.cid, target.name, replace: true);
  }

  // ── 播放与书架 ──

  Future<void> _playFile(Pan115Item item) async {
    final bookName = _isBookFolder ? _currentName : item.name;
    final meta = Pan115Service.instance.parseBookFolderName(bookName);
    final title = meta?.title ?? bookName;

    setState(() => _loading = true);
    try {
      PlayerService.instance.setContext(
        sourceId: Pan115Service.sourceId,
        bookId: item.fid.isNotEmpty ? item.fid : _currentFid,
        bookTitle: title,
        cover: _coverPath,
        chapters: [
          {
            'chapterId': Pan115Service.chapterIdFor(item),
            'index': 1,
            'name': item.name,
          },
        ],
      );
      await PlayerService.instance.playIndex(0);
      if (!mounted) return;
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const PlayerScreen()),
      );
    } catch (e) {
      if (mounted) _toast(e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _playBook() async {
    if (!_isBookFolder) return;
    setState(() => _loading = true);
    try {
      final cached = await CatalogCacheService.instance.load(
        sourceId: Pan115Service.sourceId,
        bookId: _currentFid,
      );
      if (cached != null && cached.chapters.isNotEmpty) {
        PlayerService.instance.setContext(
          sourceId: Pan115Service.sourceId,
          bookId: _currentFid,
          bookTitle: cached.info.title,
          cover: cached.info.cover,
          chapters: [
            for (final ch in cached.chapters)
              {'chapterId': ch.chapterId, 'index': ch.index, 'name': ch.name},
          ],
        );
        await PlayerService.instance.playIndex(0);
        if (!mounted) return;
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const PlayerScreen()),
        );
        return;
      }
      final catalog = await Pan115Service.instance.refreshCatalog(
        bookCid: _currentFid,
        folderName: _currentName,
        fallbackCover: _coverPath,
        fallbackAuthor: '115 网盘',
      );
      if (!mounted) return;
      PlayerService.instance.setContext(
        sourceId: Pan115Service.sourceId,
        bookId: _currentFid,
        bookTitle: catalog.info.title,
        cover: catalog.info.cover,
        chapters: [
          for (final ch in catalog.chapters)
            {'chapterId': ch.chapterId, 'index': ch.index, 'name': ch.name},
        ],
      );
      await PlayerService.instance.playIndex(0);
      if (!mounted) return;
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const PlayerScreen()),
      );
    } catch (e) {
      if (!mounted) return;
      _toast(e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _addToShelf() async {
    if (!_isBookFolder) return;
    setState(() => _loading = true);
    try {
      final catalog = await Pan115Service.instance.refreshCatalog(
        bookCid: _currentFid,
        folderName: _currentName,
        fallbackCover: _coverPath,
        fallbackAuthor: '115 网盘',
      );
      await ShelfService.instance.add(
        sourceId: Pan115Service.sourceId,
        bookId: _currentFid,
        title: catalog.info.title,
        cover: catalog.info.cover,
        author: catalog.info.author,
        sourceName: '115 网盘',
      );
      if (!mounted) return;
      _toast('已加入书架（${catalog.chapters.length} 集）');
    } catch (e) {
      if (!mounted) return;
      _toast(e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _refreshCatalog() async {
    if (!_isBookFolder) return;
    setState(() => _loading = true);
    try {
      final catalog = await Pan115Service.instance.refreshCatalog(
        bookCid: _currentFid,
        folderName: _currentName,
        fallbackCover: _coverPath,
        fallbackAuthor: '115 网盘',
      );
      if (!mounted) return;
      _toast('目录已更新，共 ${catalog.chapters.length} 章');
    } catch (e) {
      if (!mounted) return;
      _toast(e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final service = Pan115Service.instance;
    final loggedIn = service.ready;

    return Scaffold(
      appBar: AppBar(
        title: const Text('115 网盘'),
        actions: [
          if (loggedIn && _isBookFolder) ...[
            IconButton(
              tooltip: '加入书架',
              icon: const Icon(Icons.bookmark_add_outlined),
              onPressed: _loading ? null : _addToShelf,
            ),
            IconButton(
              tooltip: '刷新目录缓存',
              icon: const Icon(Icons.sync),
              onPressed: _loading ? null : _refreshCatalog,
            ),
          ],
        ],
      ),
      body: Column(
        children: [
          _accountCard(cs),
          if (_error != null)
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: cs.errorContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(Icons.error_outline, size: 18, color: cs.error),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _error!,
                      style: TextStyle(fontSize: 12, color: cs.onErrorContainer),
                    ),
                  ),
                ],
              ),
            ),
          Expanded(
            child: loggedIn ? _browser(cs) : _notLoggedIn(cs),
          ),
        ],
      ),
      bottomNavigationBar: loggedIn
          ? SafeArea(
              child: Container(
                padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
                decoration: BoxDecoration(
                  border: Border(top: BorderSide(color: cs.outlineVariant)),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _pathStack.length <= 1 || _loading
                            ? null
                            : _goUp,
                        icon: const Icon(Icons.arrow_upward),
                        label: const Text('上一级'),
                      ),
                    ),
                    if (_isBookFolder) ...[
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: _loading ? null : _playBook,
                          icon: const Icon(Icons.play_arrow),
                          label: const Text('播放整本'),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            )
          : null,
    );
  }

  /// 账号卡片
  Widget _accountCard(ColorScheme cs) {
    final service = Pan115Service.instance;
    final loggedIn = service.ready;
    final hasToken = service.accessToken.isNotEmpty;

    String authDesc;
    if (hasToken) {
      final expText = service.expiresAt > 0
          ? DateTime.fromMillisecondsSinceEpoch(service.expiresAt)
              .toLocal()
              .toString()
              .split('.')
              .first
          : '未知';
      final userName = '${_userInfo['user_name'] ?? ''}'.trim();
      final isVip = _userInfo['is_vip'] == 1 || _userInfo['vip'] == 1;
      final userPart = userName.isNotEmpty ? '用户: $userName${isVip ? ' (VIP)' : ''} · ' : '';
      authDesc =
          '${userPart}AppID: ${service.appId.isNotEmpty ? service.appId : '(未指定)'} · 到期: $expText';
    } else if (service.cookie.isNotEmpty) {
      authDesc = 'Cookie: ${Pan115Service.cookieSummary(service.cookie)}';
    } else {
      authDesc = '通过 115 开放平台扫码登录后可直接浏览与播放网盘中的有声书。';
    }

    return Card(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  loggedIn
                      ? Icons.cloud_done_outlined
                      : Icons.cloud_off_outlined,
                  size: 20,
                  color: loggedIn ? cs.primary : cs.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    loggedIn
                        ? (hasToken ? '115 开放平台已授权' : '已保存 115 Cookie')
                        : '未登录 115 网盘',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                if (loggedIn && _loginValid != null)
                  Text(
                    _loginValid! ? '状态正常' : '可能失效',
                    style: TextStyle(
                      fontSize: 12,
                      color: _loginValid! ? cs.primary : cs.error,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              authDesc,
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                FilledButton.icon(
                  onPressed: _loading ? null : _qrLogin,
                  icon: const Icon(Icons.qr_code_scanner),
                  label: const Text('扫码登录'),
                ),
                OutlinedButton.icon(
                  onPressed: _loading ? null : _manualToken,
                  icon: const Icon(Icons.vpn_key_outlined),
                  label: const Text('设置 Token'),
                ),
                OutlinedButton.icon(
                  onPressed: _loading ? null : _pasteCookie,
                  icon: const Icon(Icons.content_paste),
                  label: const Text('粘贴 Cookie'),
                ),
                if (loggedIn && hasToken)
                  OutlinedButton.icon(
                    onPressed: _loading ? null : _refreshToken,
                    icon: const Icon(Icons.refresh),
                    label: const Text('刷新 Token'),
                  ),
                if (loggedIn)
                  OutlinedButton.icon(
                    onPressed: _checkingLogin ? null : () => _checkLogin(),
                    icon: _checkingLogin
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.verified_user_outlined),
                    label: const Text('检测连接'),
                  ),
                if (loggedIn)
                  TextButton.icon(
                    onPressed: _loading ? null : _logout,
                    icon: const Icon(Icons.logout),
                    label: const Text('退出登录'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _notLoggedIn(ColorScheme cs) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_outlined, size: 52, color: cs.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(
              '请使用上方的「扫码登录」绑定 115 账号，\n即可浏览网盘并播放有声书。',
              textAlign: TextAlign.center,
              style: TextStyle(color: cs.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  Widget _browser(ColorScheme cs) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _breadcrumb(cs),
        _folderHeader(cs),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () => _load(_currentFid, _currentName, replace: true),
            child: _items.isEmpty
                ? ListView(
                    controller: _scrollController,
                    children: [
                      const SizedBox(height: 80),
                      Center(
                        child: Text(
                          _loading ? '加载中…' : '空目录',
                          style: TextStyle(color: cs.onSurfaceVariant),
                        ),
                      ),
                    ],
                  )
                : ListView.builder(
                    controller: _scrollController,
                    itemCount: _items.length + (_hasMore ? 1 : 0),
                    itemBuilder: (context, index) {
                      if (index == _items.length) {
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          child: Center(
                            child: _loadingMore
                                ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(strokeWidth: 2),
                                  )
                                : TextButton(
                                    onPressed: _loadMore,
                                    child: const Text('点击加载更多'),
                                  ),
                          ),
                        );
                      }
                      final item = _items[index];
                      final isAudio = Pan115Service.instance.isAudioFile(
                        item.name,
                      );
                      final isCover = Pan115Service.instance.isCoverFile(
                        item.name,
                      );
                      return ListTile(
                        leading: Icon(
                          item.isDirectory
                              ? Icons.folder
                              : (isAudio
                                  ? Icons.audiotrack
                                  : (isCover
                                      ? Icons.image_outlined
                                      : Icons.insert_drive_file)),
                          color: item.isDirectory
                              ? cs.primary
                              : (isAudio ? cs.tertiary : cs.onSurfaceVariant),
                        ),
                        title: Text(
                          item.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: item.isDirectory
                            ? const Text('文件夹')
                            : Text(
                                isCover && !isAudio
                                    ? '封面 · ${_formatSize(item.size)}'
                                    : _formatSize(item.size),
                              ),
                        trailing: item.isDirectory && _isBookName(item.name)
                            ? const Icon(Icons.menu_book_outlined)
                            : null,
                        onTap: item.isDirectory
                            ? () => _load(item.fid, item.name)
                            : (isAudio ? () => _playFile(item) : null),
                      );
                    },
                  ),
          ),
        ),
      ],
    );
  }

  Widget _breadcrumb(ColorScheme cs) {
    return SizedBox(
      height: 36,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        itemCount: _pathStack.length,
        separatorBuilder: (_, _) => Icon(
          Icons.chevron_right,
          size: 16,
          color: cs.onSurfaceVariant,
        ),
        itemBuilder: (context, index) {
          final entry = _pathStack[index];
          final isLast = index == _pathStack.length - 1;
          return Center(
            child: TextButton(
              onPressed: isLast || _loading ? null : () => _jumpTo(index),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                minimumSize: const Size(0, 32),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text(
                entry.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: isLast ? FontWeight.w600 : FontWeight.normal,
                  color: isLast ? cs.primary : cs.onSurfaceVariant,
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _folderHeader(ColorScheme cs) {
    final isBook = _isBookFolder;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (isBook)
            Padding(
              padding: const EdgeInsets.only(right: 10),
              child: CoverImage(
                cover: _coverPath,
                width: 44,
                height: 60,
                fallback: Container(
                  width: 44,
                  height: 60,
                  decoration: BoxDecoration(
                    color: cs.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Icon(
                    Icons.menu_book_outlined,
                    size: 20,
                    color: cs.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isBook
                      ? '$_currentName · 可加入书架 / 播放整本'
                      : (_totalCount > 0
                          ? '$_currentName · 已加载 ${_items.length}/$_totalCount 项'
                          : '$_currentName · 已加载 ${_items.length} 项'),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                ),
                if (isBook)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      _coverPath.isEmpty
                          ? '未找到封面文件（cover*.jpg/png/webp）'
                          : '封面已缓存到本地',
                      style: TextStyle(
                        fontSize: 11,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _formatSize(int bytes) {
    if (bytes <= 0) return '';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(1)} GB';
  }
}

/// 扫码登录对话框 (Device Code + PKCE)
class _QrLoginDialog extends StatefulWidget {
  final String initialAppId;
  const _QrLoginDialog({required this.initialAppId});

  @override
  State<_QrLoginDialog> createState() => _QrLoginDialogState();
}

class _QrLoginDialogState extends State<_QrLoginDialog> {
  late final TextEditingController _appIdController;
  Pan115QrSession? _session;
  bool _fetchingQr = false;
  String _statusText = '准备就绪';
  bool _expired = false;
  bool _polling = false;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    _appIdController = TextEditingController(text: widget.initialAppId);
    if (widget.initialAppId.isNotEmpty) {
      _startSession();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _appIdController.dispose();
    super.dispose();
  }

  Future<void> _startSession() async {
    final appId = _appIdController.text.trim();
    if (appId.isEmpty) {
      setState(() => _statusText = '请先输入 115 开放平台 AppID');
      return;
    }

    setState(() {
      _fetchingQr = true;
      _expired = false;
      _session = null;
      _statusText = '正在生成扫码二维码…';
    });

    try {
      final session = await Pan115Service.instance.authDeviceCode(appId: appId);
      if (_disposed || !mounted) return;
      setState(() {
        _session = session;
        _fetchingQr = false;
        _statusText = '请使用 115 手机 App 扫码并在手机上确认';
      });
      _pollLoop(session);
    } catch (e) {
      if (_disposed || !mounted) return;
      setState(() {
        _fetchingQr = false;
        _statusText = '获取二维码失败: ${e.toString().replaceFirst('Exception: ', '')}';
      });
    }
  }

  Future<void> _pollLoop(Pan115QrSession session) async {
    if (_polling) return;
    _polling = true;

    while (!_disposed && mounted && _session == session) {
      try {
        final status = await Pan115Service.instance.pollQrStatus(session);
        if (_disposed || !mounted || _session != session) break;

        if (status == 1) {
          setState(() => _statusText = '已扫码，请在手机上点击确认授权');
        } else if (status == 2) {
          setState(() => _statusText = '已确认授权，正在换取 Token…');
          await Pan115Service.instance.authCodeToToken(session);
          if (!_disposed && mounted) {
            Navigator.pop(context, true);
          }
          break;
        } else if (status == -1) {
          setState(() {
            _statusText = '二维码已失效或已取消，请点击刷新';
            _expired = true;
          });
          break;
        }
        // 长轮询接口返回后稍作微小延迟继续下一次挂起轮询
        await Future.delayed(const Duration(milliseconds: 500));
      } catch (e) {
        if (_disposed || !mounted || _session != session) break;
        // 网络抖动或超时后继续重试
        await Future.delayed(const Duration(seconds: 1));
      }
    }
    _polling = false;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Text('115 扫码登录'),
      content: SingleChildScrollView(
        child: SizedBox(
          width: 320,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _appIdController,
                decoration: InputDecoration(
                  labelText: '115 开放平台 AppID',
                  hintText: '输入您的 AppID (可在开放平台创建)',
                  border: const OutlineInputBorder(),
                  isDense: true,
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.arrow_forward),
                    tooltip: '生成二维码',
                    onPressed: _fetchingQr ? null : _startSession,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              if (_fetchingQr) ...[
                const SizedBox(height: 40),
                const CircularProgressIndicator(),
                const SizedBox(height: 40),
              ] else if (_session != null) ...[
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.08),
                        blurRadius: 8,
                      ),
                    ],
                  ),
                  child: QrImageView(
                    data: _session!.qrcode,
                    version: QrVersions.auto,
                    size: 200.0,
                    backgroundColor: Colors.white,
                  ),
                ),
                const SizedBox(height: 12),
              ],
              Text(
                _statusText,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: _expired ? cs.error : cs.onSurface,
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        if (_expired || _session != null)
          TextButton.icon(
            onPressed: _fetchingQr ? null : _startSession,
            icon: const Icon(Icons.refresh),
            label: const Text('刷新二维码'),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
      ],
    );
  }
}

/// 手动设置 Token 对话框
class _ManualTokenDialog extends StatefulWidget {
  final String initialAppId;
  final String initialAccessToken;
  final String initialRefreshToken;

  const _ManualTokenDialog({
    required this.initialAppId,
    required this.initialAccessToken,
    required this.initialRefreshToken,
  });

  @override
  State<_ManualTokenDialog> createState() => _ManualTokenDialogState();
}

class _ManualTokenDialogState extends State<_ManualTokenDialog> {
  late final TextEditingController _appIdCtrl;
  late final TextEditingController _accessCtrl;
  late final TextEditingController _refreshCtrl;

  @override
  void initState() {
    super.initState();
    _appIdCtrl = TextEditingController(text: widget.initialAppId);
    _accessCtrl = TextEditingController(text: widget.initialAccessToken);
    _refreshCtrl = TextEditingController(text: widget.initialRefreshToken);
  }

  @override
  void dispose() {
    _appIdCtrl.dispose();
    _accessCtrl.dispose();
    _refreshCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('手动设置 115 Token'),
      content: SingleChildScrollView(
        child: SizedBox(
          width: 400,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _appIdCtrl,
                decoration: const InputDecoration(
                  labelText: 'AppID',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _accessCtrl,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'access_token',
                  hintText: '粘贴 access_token',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _refreshCtrl,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: 'refresh_token (可选)',
                  hintText: '用于自动刷新过期 Token',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            Navigator.pop(context, {
              'app_id': _appIdCtrl.text.trim(),
              'access_token': _accessCtrl.text.trim(),
              'refresh_token': _refreshCtrl.text.trim(),
            });
          },
          child: const Text('保存'),
        ),
      ],
    );
  }
}

/// Cookie 粘贴对话框
class _CookiePasteDialog extends StatefulWidget {
  const _CookiePasteDialog();

  @override
  State<_CookiePasteDialog> createState() => _CookiePasteDialogState();
}

class _CookiePasteDialogState extends State<_CookiePasteDialog> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('粘贴 115 Cookie'),
      content: SizedBox(
        width: 420,
        child: TextField(
          controller: _controller,
          autofocus: true,
          minLines: 4,
          maxLines: 8,
          decoration: const InputDecoration(
            hintText: '从浏览器开发者工具 Network 里复制整行 Cookie 粘贴到这里',
            border: OutlineInputBorder(),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _controller.text),
          child: const Text('保存'),
        ),
      ],
    );
  }
}
