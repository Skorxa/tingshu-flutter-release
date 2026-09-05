import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/baidu_pan_service.dart';
import '../data/catalog_cache_service.dart';
import '../data/log_service.dart';
import '../data/shelf_service.dart';
import '../player/player_service.dart';
import '../source/models.dart';
import 'player_screen.dart';

class BaiduPanScreen extends StatefulWidget {
  const BaiduPanScreen({super.key});

  @override
  State<BaiduPanScreen> createState() => _BaiduPanScreenState();
}

class _BaiduPanScreenState extends State<BaiduPanScreen> {
  static const MethodChannel _loginChannel = MethodChannel(
    'tingshu/source_login',
  );

  final TextEditingController _pathInput = TextEditingController();
  final List<String> _pathStack = [];
  List<BaiduPanItem> _items = [];
  bool _loading = false;
  String? _error;

  String get _currentPath =>
      _pathStack.isEmpty ? BaiduPanService.instance.rootPath : _pathStack.last;

  String _folderName(String path) {
    var p = path.trim();
    if (p.length > 1 && p.endsWith('/')) p = p.substring(0, p.length - 1);
    final i = p.lastIndexOf('/');
    return i >= 0 ? p.substring(i + 1) : p;
  }

  bool get _isBookFolder =>
      BaiduPanService.instance.parseBookFolderName(_folderName(_currentPath)) !=
      null;

  @override
  void initState() {
    super.initState();
    _pathInput.text = BaiduPanService.instance.rootPath;
    if (BaiduPanService.instance.ready) {
      _load(BaiduPanService.instance.rootPath, replace: true);
    }
  }

  @override
  void dispose() {
    _pathInput.dispose();
    super.dispose();
  }

  String _normalize(String p) {
    var s = p.trim();
    if (s.isEmpty) return '/';
    if (!s.startsWith('/')) s = '/$s';
    return s;
  }

  Future<void> _login() async {
    try {
      final result = await _loginChannel.invokeMethod<Map<dynamic, dynamic>>(
        'openLogin',
        {'url': 'https://pan.baidu.com', 'title': '登录百度网盘'},
      );
      final cookie = '${result?['cookie'] ?? ''}'.trim();
      if (cookie.isEmpty) {
        _toast('没有拿到登录 Cookie,请确认已登录');
        return;
      }
      await BaiduPanService.instance.saveCookie(cookie);
      if (!mounted) return;
      setState(() {});
      await _load(BaiduPanService.instance.rootPath, replace: true);
    } on MissingPluginException {
      _toast('当前平台不支持网页登录');
    } catch (e) {
      LogService.instance.error('BaiduPan', '登录失败', error: e);
      _toast(e.toString().replaceFirst('Exception: ', ''));
    }
  }

  Future<void> _go() async {
    final path = _normalize(_pathInput.text);
    await BaiduPanService.instance.saveRootPath(path);
    await _load(path, replace: true);
  }

  Future<void> _load(String path, {bool replace = false}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final items = await BaiduPanService.instance.list(path);
      if (!mounted) return;
      setState(() {
        _items = items;
        _pathInput.text = path;
        if (replace) {
          _pathStack
            ..clear()
            ..add(path);
        } else {
          _pathStack.add(path);
        }
      });
    } catch (e) {
      if (mounted) {
        setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
      }
      LogService.instance.error('BaiduPan', '读取目录失败', error: e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _goUp() async {
    if (_pathStack.length <= 1 || _loading) return;
    _pathStack.removeLast();
    final parent = _pathStack.removeLast();
    _pathInput.text = parent;
    await _load(parent);
  }

  Future<void> _playFile(BaiduPanItem item) async {
    setState(() => _loading = true);
    try {
      final audio = await BaiduPanService.instance.resolveAudio(item.path);
      PlayerService.instance.setContext(
        sourceId: 'baidu',
        bookId: item.path,
        bookTitle: item.name,
        cover: '',
        chapters: [
          {
            'chapterId': 'baidu:${item.path}',
            'index': 1,
            'name': item.name,
            'audioUrl': audio.url,
            'audioHeaders': audio.headers,
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

  Future<BaiduBook?> _buildBook() async {
    final book = await BaiduPanService.instance.toBook(_currentPath);
    if (book.audioFiles.isEmpty) {
      _toast('这个文件夹(含子目录)里没有音频文件');
      return null;
    }
    return book;
  }

  String _authorOf(BaiduBook book) =>
      book.narrator.isEmpty ? book.author : '${book.author} / ${book.narrator}';

  Future<void> _addToShelf() async {
    setState(() => _loading = true);
    try {
      final book = await _buildBook();
      if (book == null) return;
      final author = _authorOf(book);
      await ShelfService.instance.add(
        sourceId: 'baidu',
        bookId: book.path,
        title: book.title,
        cover: book.cover,
        author: author,
        sourceName: '百度网盘',
      );
      await _cacheCatalog(book, author);
      _toast('已加入书架(${book.audioFiles.length} 集)');
    } catch (e) {
      if (mounted) _toast(e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _playBook() async {
    setState(() => _loading = true);
    try {
      // 目录缓存优先:命中即秒开,不重新枚举网盘(章节为 baidu: 占位,播放时解析直链)。
      // 新增的文件在播放目录页点"刷新目录"后可见。
      final cached = await CatalogCacheService.instance.load(
        sourceId: 'baidu',
        bookId: _currentPath,
      );
      if (cached != null && cached.chapters.isNotEmpty) {
        PlayerService.instance.setContext(
          sourceId: 'baidu',
          bookId: _currentPath,
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
        sourceId: 'baidu',
        bookId: book.path,
        bookTitle: book.title,
        cover: book.cover,
        chapters: [
          for (var i = 0; i < book.audioFiles.length; i++)
            {
              'chapterId': 'baidu:${book.audioFiles[i].path}',
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

  Future<void> _cacheCatalog(BaiduBook book, String author) async {
    await CatalogCacheService.instance.savePage(
      sourceId: 'baidu',
      bookId: book.path,
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
            chapterId: 'baidu:${book.audioFiles[i].path}',
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
    final service = BaiduPanService.instance;
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('百度网盘书库'),
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
                  _pathStack.clear();
                });
              },
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
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _pathInput,
                  decoration: const InputDecoration(
                    isDense: true,
                    hintText: '网盘路径,如 /有声书',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _go(),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _loading ? null : _go,
                child: const Text('前往'),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
          child: Text(
            _isBookFolder ? '$_currentPath  · 可加入书架 / 播放整本' : _currentPath,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
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
            onRefresh: () => _load(_currentPath, replace: true),
            child: _items.isEmpty
                ? ListView(
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
                    itemCount: _items.length,
                    itemBuilder: (context, index) {
                      final item = _items[index];
                      final isAudio = BaiduPanService.instance.isAudioFile(
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
                        onTap: item.isDirectory
                            ? () {
                                _pathInput.text = item.path;
                                _load(item.path);
                              }
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
            Text('先登录百度网盘', style: TextStyle(color: cs.onSurfaceVariant)),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _login,
              icon: const Icon(Icons.login),
              label: const Text('登录百度网盘'),
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
