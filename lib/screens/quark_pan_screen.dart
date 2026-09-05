import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/catalog_cache_service.dart';
import '../data/log_service.dart';
import '../data/quark_pan_service.dart';
import '../data/shelf_service.dart';
import '../player/player_service.dart';
import '../source/models.dart';
import 'player_screen.dart';

class QuarkPanScreen extends StatefulWidget {
  const QuarkPanScreen({super.key});

  @override
  State<QuarkPanScreen> createState() => _QuarkPanScreenState();
}

class _QuarkPathEntry {
  final String fid;
  final String name;

  const _QuarkPathEntry(this.fid, this.name);
}

class _QuarkPanScreenState extends State<QuarkPanScreen> {
  static const MethodChannel _loginChannel = MethodChannel(
    'tingshu/source_login',
  );

  final List<_QuarkPathEntry> _pathStack = const [
    _QuarkPathEntry(QuarkPanService.rootFid, '根目录'),
  ].toList();
  List<QuarkPanItem> _items = [];
  bool _loading = false;
  bool _checkingLogin = false;
  bool? _loginValid;
  String? _error;

  _QuarkPathEntry get _current => _pathStack.last;
  String get _currentFid => _current.fid;
  String get _currentName => _current.name;
  bool get _isBookFolder =>
      QuarkPanService.instance.parseBookFolderName(_currentName) != null;

  @override
  void initState() {
    super.initState();
    if (QuarkPanService.instance.ready) {
      _load(QuarkPanService.rootFid, '根目录', replace: true);
      _checkLogin(showToast: false);
    }
  }

  Future<void> _login() async {
    try {
      final result = await _loginChannel
          .invokeMethod<Map<dynamic, dynamic>>('openLogin', {
            'url': 'https://pan.quark.cn/',
            'title': '登录夸克网盘',
            'userAgent': QuarkPanService.instance.pcUserAgent,
          });
      final cookie = '${result?['cookie'] ?? ''}'.trim();
      if (cookie.isEmpty) {
        _toast('没有拿到登录 Cookie，请确认已登录');
        return;
      }
      await QuarkPanService.instance.saveCookie(cookie);
      if (!mounted) return;
      setState(() => _loginValid = null);
      await _checkLogin(showToast: false);
      await _load(QuarkPanService.rootFid, '根目录', replace: true);
    } on MissingPluginException {
      _toast('当前平台不支持网页登录');
    } catch (e) {
      LogService.instance.error('QuarkPan', '登录失败', error: e);
      _toast(e.toString().replaceFirst('Exception: ', ''));
    }
  }

  Future<void> _checkLogin({bool showToast = true}) async {
    if (!QuarkPanService.instance.ready || _checkingLogin) return;
    setState(() => _checkingLogin = true);
    final ok = await QuarkPanService.instance.checkLogin();
    if (!mounted) return;
    setState(() {
      _loginValid = ok;
      _checkingLogin = false;
    });
    if (showToast) _toast(ok ? '夸克登录状态正常' : '登录状态可能已失效，请重新登录');
  }

  Future<void> _load(String fid, String name, {bool replace = false}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final items = await QuarkPanService.instance.list(fid);
      if (!mounted) return;
      setState(() {
        _items = items;
        if (replace) {
          _pathStack
            ..clear()
            ..add(_QuarkPathEntry(fid, name));
        } else {
          _pathStack.add(_QuarkPathEntry(fid, name));
        }
      });
    } catch (e) {
      if (mounted) {
        setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
      }
      LogService.instance.error('QuarkPan', '读取目录失败', error: e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _goUp() async {
    if (_pathStack.length <= 1 || _loading) return;
    _pathStack.removeLast();
    final parent = _pathStack.removeLast();
    await _load(parent.fid, parent.name);
  }

  Future<void> _playFile(QuarkPanItem item) async {
    setState(() => _loading = true);
    try {
      PlayerService.instance.setContext(
        sourceId: 'quark',
        bookId: item.fid,
        bookTitle: item.name,
        cover: '',
        chapters: [
          {'chapterId': 'quark:${item.fid}', 'index': 1, 'name': item.name},
        ],
      );
      await PlayerService.instance.playIndex(0);
      if (!mounted) return;
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const PlayerScreen()),
      );
    } catch (e) {
      if (mounted) _toast(e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<QuarkBook?> _buildBook() async {
    final book = await QuarkPanService.instance.toBook(
      _currentFid,
      folderName: _currentName,
    );
    if (book.audioFiles.isEmpty) {
      _toast('这个文件夹（含子目录）里没有音频文件');
      return null;
    }
    return book;
  }

  String _authorOf(QuarkBook book) =>
      book.narrator.isEmpty ? book.author : '${book.author} / ${book.narrator}';

  Future<void> _addToShelf() async {
    setState(() => _loading = true);
    try {
      final book = await _buildBook();
      if (book == null) return;
      final author = _authorOf(book);
      await ShelfService.instance.add(
        sourceId: 'quark',
        bookId: book.fid,
        title: book.title,
        cover: book.cover,
        author: author,
        sourceName: '夸克网盘',
      );
      await _cacheCatalog(book, author);
      _toast('已加入书架（${book.audioFiles.length} 集）');
    } catch (e) {
      if (mounted) _toast(e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _playBook() async {
    setState(() => _loading = true);
    try {
      // 目录缓存优先:命中即秒开,不重新枚举网盘(章节为 quark: 占位,播放时解析直链)。
      // 新增的文件在播放目录页点"刷新目录"后可见。
      final cached = await CatalogCacheService.instance.load(
        sourceId: 'quark',
        bookId: _currentFid,
      );
      if (cached != null && cached.chapters.isNotEmpty) {
        PlayerService.instance.setContext(
          sourceId: 'quark',
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
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const PlayerScreen()),
        );
        return;
      }
      final book = await _buildBook();
      if (book == null) return;
      await _cacheCatalog(book, _authorOf(book));
      PlayerService.instance.setContext(
        sourceId: 'quark',
        bookId: book.fid,
        bookTitle: book.title,
        cover: book.cover,
        chapters: [
          for (var i = 0; i < book.audioFiles.length; i++)
            {
              'chapterId': 'quark:${book.audioFiles[i].fid}',
              'index': i + 1,
              'name': book.audioFiles[i].name,
            },
        ],
      );
      await PlayerService.instance.playIndex(0);
      if (!mounted) return;
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const PlayerScreen()),
      );
    } catch (e) {
      if (mounted) _toast(e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _cacheCatalog(QuarkBook book, String author) async {
    await CatalogCacheService.instance.savePage(
      sourceId: 'quark',
      bookId: book.fid,
      info: CatalogInfo(
        title: book.title,
        cover: book.cover,
        author: author,
        trackCount: book.audioFiles.length,
        isFinished: true,
      ),
      chapters: [
        for (var i = 0; i < book.audioFiles.length; i++)
          Chapter(
            chapterId: 'quark:${book.audioFiles[i].fid}',
            index: i + 1,
            name: book.audioFiles[i].name,
          ),
      ],
      page: 1,
      maxPage: 1,
      hasMore: false,
    );
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final service = QuarkPanService.instance;
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('夸克网盘书库'),
        actions: [
          if (service.ready && _isBookFolder)
            IconButton(
              icon: const Icon(Icons.bookmark_add_outlined),
              tooltip: '加入书架',
              onPressed: _loading ? null : _addToShelf,
            ),
          if (service.ready)
            IconButton(
              icon: const Icon(Icons.logout),
              tooltip: '重新登录',
              onPressed: () async {
                await service.logout();
                if (!mounted) return;
                setState(() {
                  _items = [];
                  _loginValid = null;
                  _pathStack
                    ..clear()
                    ..add(
                      const _QuarkPathEntry(QuarkPanService.rootFid, '根目录'),
                    );
                });
              },
            ),
          if (service.ready)
            IconButton(
              icon: _checkingLogin
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.verified_user_outlined),
              tooltip: '检测登录状态',
              onPressed: _checkingLogin ? null : _checkLogin,
            ),
        ],
      ),
      body: !service.ready ? _emptyLogin(cs) : _browser(cs),
      bottomNavigationBar: service.ready
          ? SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
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

  Widget _browser(ColorScheme cs) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Text(
            _isBookFolder ? '$_currentName · 可加入书架 / 播放整本' : _currentName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
          ),
        ),
        if (_loginValid != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Text(
              _loginValid! ? '登录状态正常' : '登录状态可能已失效',
              style: TextStyle(
                fontSize: 12,
                color: _loginValid! ? cs.primary : cs.error,
              ),
            ),
          ),
        if (_loading) const LinearProgressIndicator(minHeight: 2),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(_error!, style: TextStyle(color: cs.error)),
          ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () => _load(_currentFid, _currentName, replace: true),
            child: _items.isEmpty
                ? ListView(
                    children: [
                      const SizedBox(height: 80),
                      Center(
                        child: Text(
                          _loading ? '加载中...' : '空目录',
                          style: TextStyle(color: cs.onSurfaceVariant),
                        ),
                      ),
                    ],
                  )
                : ListView.builder(
                    itemCount: _items.length,
                    itemBuilder: (context, index) {
                      final item = _items[index];
                      final isAudio = QuarkPanService.instance.isAudioFile(
                        item.name,
                      );
                      return ListTile(
                        leading: Icon(
                          item.isDirectory
                              ? Icons.folder
                              : (isAudio
                                    ? Icons.audiotrack
                                    : Icons.insert_drive_file),
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
                            : Text(_formatSize(item.size)),
                        trailing:
                            item.isDirectory &&
                                QuarkPanService.instance.parseBookFolderName(
                                      item.name,
                                    ) !=
                                    null
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

  Widget _emptyLogin(ColorScheme cs) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_outlined, size: 52, color: cs.onSurfaceVariant),
            const SizedBox(height: 12),
            Text('先登录夸克网盘', style: TextStyle(color: cs.onSurfaceVariant)),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _login,
              icon: const Icon(Icons.login),
              label: const Text('登录夸克网盘'),
            ),
          ],
        ),
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
