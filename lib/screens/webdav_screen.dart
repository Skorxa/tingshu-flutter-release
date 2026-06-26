import 'package:flutter/material.dart';

import '../data/catalog_cache_service.dart';
import '../data/log_service.dart';
import '../data/shelf_service.dart';
import '../data/webdav_service.dart';
import '../player/player_service.dart';
import '../source/models.dart';
import 'player_screen.dart';

class WebDavScreen extends StatefulWidget {
  const WebDavScreen({super.key});

  @override
  State<WebDavScreen> createState() => _WebDavScreenState();
}

class _WebDavScreenState extends State<WebDavScreen> {
  final List<String> _pathStack = [];
  List<WebDavItem> _items = [];
  bool _loading = false;
  String? _error;

  String get _currentPath => _pathStack.isEmpty
      ? WebDavService.instance.config.rootPath
      : _pathStack.last;

  @override
  void initState() {
    super.initState();
    if (WebDavService.instance.ready) {
      _load(WebDavService.instance.config.rootPath, replace: true);
    }
  }

  Future<void> _load(String path, {bool replace = false}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final items = await WebDavService.instance.list(path);
      if (!mounted) return;
      setState(() {
        _items = items;
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
      LogService.instance.error('WebDAV', '读取目录失败', error: e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _goUp() async {
    if (_pathStack.length <= 1 || _loading) return;
    _pathStack.removeLast();
    await _load(_pathStack.removeLast(), replace: false);
  }

  Future<void> _openConfig() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const WebDavConfigScreen()),
    );
    if (!mounted) return;
    if (WebDavService.instance.ready) {
      await _load(WebDavService.instance.config.rootPath, replace: true);
    } else {
      setState(() {
        _items = [];
        _pathStack.clear();
      });
    }
  }

  Future<void> _playFolder() async {
    final service = WebDavService.instance;
    final book = await _buildCurrentBook();
    if (book.audioFiles.isEmpty) {
      _toast('当前目录没有可播放的音频文件');
      return;
    }
    final chapters = <Map<String, dynamic>>[];
    for (var i = 0; i < book.audioFiles.length; i++) {
      final file = book.audioFiles[i];
      final scopedPath = service.scopedPath(file.path);
      chapters.add({
        'chapterId': 'webdav:$scopedPath',
        'index': i + 1,
        'name': file.name,
        'audioUrl': service.resolveUrl(scopedPath),
        'audioHeaders': service.headersForPath(scopedPath),
      });
    }
    final scopedBookPath = service.scopedPath(book.path);
    PlayerService.instance.setContext(
      sourceId: 'webdav',
      bookId: scopedBookPath,
      bookTitle: book.title,
      cover: book.cover,
      chapters: chapters,
    );
    await _cacheWebDavCatalog(book);
    await PlayerService.instance.playIndex(0);
    if (!mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const PlayerScreen()),
    );
  }

  Future<void> _addCurrentFolderToShelf() async {
    final service = WebDavService.instance;
    final book = await _buildCurrentBook();
    if (book.audioFiles.isEmpty) {
      _toast('当前目录没有可播放的音频文件');
      return;
    }
    if (service.parseBookFolderName(service.displayName(_currentPath)) ==
        null) {
      _toast('文件夹名需要是 书名_作者_演播者');
      return;
    }
    final author = book.narrator.isEmpty
        ? book.author
        : '${book.author} / ${book.narrator}';
    await ShelfService.instance.add(
      sourceId: 'webdav',
      bookId: service.scopedPath(book.path),
      title: book.title,
      cover: book.cover,
      author: author,
      sourceName: 'WebDAV · ${service.config.displayName}',
    );
    await _cacheWebDavCatalog(book);
    _toast('已加入书架');
  }

  Future<WebDavBook> _buildCurrentBook() async {
    final service = WebDavService.instance;
    final book = service.toBook(_currentPath, _items);
    final coverItem = service.findCoverItem(_items);
    if (coverItem == null) return book;
    try {
      final localCover = await service.cacheCover(coverItem);
      return WebDavBook(
        title: book.title,
        author: book.author,
        narrator: book.narrator,
        cover: localCover,
        path: book.path,
        audioFiles: book.audioFiles,
      );
    } catch (e) {
      LogService.instance.warning(
        'WebDAV',
        '封面缓存失败，继续使用远程封面',
        detail: '目录: $_currentPath\n错误: $e',
      );
      return book;
    }
  }

  Future<void> _cacheWebDavCatalog(WebDavBook book) async {
    final author = book.narrator.isEmpty
        ? book.author
        : '${book.author} / ${book.narrator}';
    await CatalogCacheService.instance.savePage(
      sourceId: 'webdav',
      bookId: WebDavService.instance.scopedPath(book.path),
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
            chapterId:
                'webdav:${WebDavService.instance.scopedPath(book.audioFiles[i].path)}',
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
    final service = WebDavService.instance;
    final cs = Theme.of(context).colorScheme;
    final audioCount = _items
        .where((item) => service.isAudioFile(item.name))
        .length;
    final canAddShelf =
        audioCount > 0 &&
        service.parseBookFolderName(service.displayName(_currentPath)) != null;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          service.ready
              ? 'WebDAV · ${service.config.displayName}'
              : 'WebDAV 书库',
        ),
        actions: [
          if (canAddShelf)
            IconButton(
              icon: const Icon(Icons.bookmark_add_outlined),
              tooltip: '加入书架',
              onPressed: _loading ? null : _addCurrentFolderToShelf,
            ),
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: '配置',
            onPressed: _openConfig,
          ),
        ],
      ),
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
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: audioCount == 0 || _loading
                            ? null
                            : _playFolder,
                        icon: const Icon(Icons.play_arrow),
                        label: Text('播放 $audioCount 集'),
                      ),
                    ),
                  ],
                ),
              ),
            )
          : null,
      body: !service.ready
          ? _emptyConfig(cs)
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 6),
                  child: Text(
                    _currentPath,
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
                    child: ListView.builder(
                      itemCount: _items.length,
                      itemBuilder: (context, index) {
                        final item = _items[index];
                        final isAudio = service.isAudioFile(item.name);
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
                                  service.parseBookFolderName(item.name) != null
                              ? const Icon(Icons.menu_book_outlined)
                              : null,
                          onTap: item.isDirectory
                              ? () => _load(item.path)
                              : (isAudio ? _playSingleFile(item) : null),
                        );
                      },
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  VoidCallback _playSingleFile(WebDavItem item) {
    return () async {
      final service = WebDavService.instance;
      final scopedPath = service.scopedPath(item.path);
      PlayerService.instance.setContext(
        sourceId: 'webdav',
        bookId: scopedPath,
        bookTitle: item.name,
        cover: '',
        chapters: [
          {
            'chapterId': 'webdav:$scopedPath',
            'index': 1,
            'name': item.name,
            'audioUrl': service.resolveUrl(scopedPath),
            'audioHeaders': service.headersForPath(scopedPath),
          },
        ],
      );
      await PlayerService.instance.playIndex(0);
      if (!mounted) return;
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const PlayerScreen()),
      );
    };
  }

  Widget _emptyConfig(ColorScheme cs) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_queue, size: 52, color: cs.onSurfaceVariant),
            const SizedBox(height: 12),
            Text('先配置 WebDAV 地址', style: TextStyle(color: cs.onSurfaceVariant)),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _openConfig,
              icon: const Icon(Icons.settings),
              label: const Text('配置 WebDAV'),
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

class WebDavConfigScreen extends StatefulWidget {
  const WebDavConfigScreen({super.key});

  @override
  State<WebDavConfigScreen> createState() => _WebDavConfigScreenState();
}

class _WebDavConfigScreenState extends State<WebDavConfigScreen> {
  Future<void> _edit([WebDavConfig? config]) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _WebDavAccountEditScreen(config: config),
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> _delete(WebDavConfig config) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除 WebDAV 账号'),
        content: Text('确定删除“${config.displayName}”？收藏里的旧记录不会自动删除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await WebDavService.instance.deleteAccount(config.id);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final service = WebDavService.instance;
    final accounts = service.accounts;
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('WebDAV 账号'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: '新增账号',
            onPressed: () => _edit(),
          ),
        ],
      ),
      body: accounts.isEmpty
          ? Center(
              child: FilledButton.icon(
                onPressed: () => _edit(),
                icon: const Icon(Icons.add),
                label: const Text('新增 WebDAV 账号'),
              ),
            )
          : ListView.builder(
              itemCount: accounts.length,
              itemBuilder: (context, index) {
                final account = accounts[index];
                final active = account.id == service.activeAccountId;
                return ListTile(
                  leading: Icon(
                    active ? Icons.check_circle : Icons.cloud_queue,
                    color: active ? cs.primary : cs.onSurfaceVariant,
                  ),
                  title: Text(account.displayName),
                  subtitle: Text(
                    '${account.baseUrl}\n根目录: ${account.rootPath}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  isThreeLine: true,
                  onTap: () async {
                    await service.setActiveAccount(account.id);
                    if (mounted) setState(() {});
                  },
                  trailing: PopupMenuButton<String>(
                    onSelected: (value) {
                      if (value == 'edit') _edit(account);
                      if (value == 'delete') _delete(account);
                    },
                    itemBuilder: (ctx) => const [
                      PopupMenuItem(value: 'edit', child: Text('编辑')),
                      PopupMenuItem(value: 'delete', child: Text('删除')),
                    ],
                  ),
                );
              },
            ),
    );
  }
}

class _WebDavAccountEditScreen extends StatefulWidget {
  final WebDavConfig? config;

  const _WebDavAccountEditScreen({this.config});

  @override
  State<_WebDavAccountEditScreen> createState() =>
      _WebDavAccountEditScreenState();
}

class _WebDavAccountEditScreenState extends State<_WebDavAccountEditScreen> {
  final _name = TextEditingController();
  final _baseUrl = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _rootPath = TextEditingController();
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final config =
        widget.config ??
        const WebDavConfig(
          baseUrl: '',
          username: '',
          password: '',
          rootPath: '/',
        );
    _name.text = config.name;
    _baseUrl.text = config.baseUrl;
    _username.text = config.username;
    _password.text = config.password;
    _rootPath.text = config.rootPath;
  }

  @override
  void dispose() {
    _name.dispose();
    _baseUrl.dispose();
    _username.dispose();
    _password.dispose();
    _rootPath.dispose();
    super.dispose();
  }

  Future<void> _save({bool test = false}) async {
    if (_baseUrl.text.trim().isEmpty) {
      _toast('地址不能为空');
      return;
    }
    setState(() => _saving = true);
    try {
      await WebDavService.instance.saveConfig(
        WebDavConfig(
          id: widget.config?.id ?? '',
          name: _name.text,
          baseUrl: _baseUrl.text,
          username: _username.text,
          password: _password.text,
          rootPath: _rootPath.text,
        ),
      );
      if (test) await WebDavService.instance.testConnection();
      if (!mounted) return;
      _toast(test ? '连接成功' : '已保存');
      Navigator.pop(context);
    } catch (e) {
      _toast(e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.config == null ? '新增 WebDAV' : '编辑 WebDAV'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _name,
            decoration: const InputDecoration(
              labelText: '名称',
              hintText: '家里 NAS / OpenList',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _baseUrl,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              labelText: 'WebDAV 地址',
              hintText: 'http://192.168.1.10:5244/dav',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _username,
            decoration: const InputDecoration(
              labelText: '账号',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _password,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: '密码',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _rootPath,
            decoration: const InputDecoration(
              labelText: '根目录',
              hintText: '/',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _saving ? null : () => _save(test: true),
                  child: const Text('测试并保存'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: _saving ? null : _save,
                  child: Text(_saving ? '保存中' : '保存'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
