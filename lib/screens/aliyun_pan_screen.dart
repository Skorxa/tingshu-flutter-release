import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/aliyun_pan_service.dart';
import '../data/catalog_cache_service.dart';
import '../data/log_service.dart';
import '../data/shelf_service.dart';
import '../player/player_service.dart';
import '../source/models.dart';
import 'player_screen.dart';

/// 阿里云盘书库:内置浏览器登录抓 token,按目录浏览,文件夹按 `书名_作者_演播者`
/// 识别为书籍,可加入书架 / 播放整本。
class AliyunPanScreen extends StatefulWidget {
  const AliyunPanScreen({super.key});

  @override
  State<AliyunPanScreen> createState() => _AliyunPanScreenState();
}

class _AliyunPathEntry {
  final String fileId;
  final String name;

  const _AliyunPathEntry(this.fileId, this.name);
}

class _AliyunPanScreenState extends State<AliyunPanScreen> {
  static const MethodChannel _loginChannel = MethodChannel(
    'tingshu/source_login',
  );

  /// 面包屑 = 访问路径栈,栈顶永远是当前目录(任何中间态都保持非空)。
  final List<_AliyunPathEntry> _pathStack = <_AliyunPathEntry>[
    const _AliyunPathEntry(AliyunPanService.rootFileId, '根目录'),
  ];
  List<AliyunPanItem> _items = <AliyunPanItem>[];
  bool _loading = false;
  bool _checkingLogin = false;
  bool? _loginValid;
  String? _error;

  AliyunPanService get _service => AliyunPanService.instance;
  _AliyunPathEntry get _current => _pathStack.last;
  String get _currentFileId => _current.fileId;
  String get _currentName => _current.name;
  bool get _isBookFolder =>
      AliyunPanService.parseFolderName(_currentName) != null;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  /// 启动兜底:main.dart 若已经调过 AliyunPanService.init(),这里直接复用已就绪的
  /// 状态;没调过则补读一次加密存储,避免冷启动进页面显示成"未登录"而实际已有登录态。
  Future<void> _bootstrap() async {
    final service = _service;
    if (!service.ready) {
      await service.init();
    }
    if (!mounted) return;
    if (!service.ready) {
      LogService.instance.info('AliyunPan', '尚未登录，等待用户登录');
      return;
    }
    setState(() {});
    if (service.driveId.isEmpty) {
      // 有 token 但没 drive_id:列目录必然失败,先提示重新登录抓 default_drive_id。
      LogService.instance.warning(
        'AliyunPan',
        '登录态缺少 drive_id，跳过目录加载',
        detail: '请重新登录或粘贴完整登录态（待抓包核对）',
      );
      return;
    }
    await _load(AliyunPanService.rootFileId, '根目录', replace: true);
    await _checkLogin(showToast: false);
  }

  // ── 登录 ──

  Future<void> _login() async {
    try {
      final result = await _loginChannel.invokeMethod<Map<dynamic, dynamic>>(
        'openLogin',
        {
          'url': AliyunPanService.loginUrl,
          'title': '登录阿里云盘',
          // 桌面 UA 才会呈现网页版,登录态才会写进 localStorage.token。
          'userAgent': AliyunPanService.pcUserAgent,
          'storageKey': AliyunPanService.loginStorageKey,
        },
      );
      final raw = '${result?['storageValue'] ?? ''}'.trim();
      if (raw.isEmpty) {
        _toast(
          '没有抓到登录态（localStorage.${AliyunPanService.loginStorageKey}），请确认已登录',
        );
        return;
      }
      await _applyLoginState(raw, from: '内置浏览器');
    } on MissingPluginException {
      _toast('当前平台不支持网页登录，可改用「粘贴登录态」');
    } catch (e) {
      LogService.instance.error('AliyunPan', '登录失败', error: e);
      _toast(_message(e));
    }
  }

  /// 内置浏览器 / 手动粘贴 共用的落地逻辑:解析登录态 → 存 SecureStore → 校验 → 载入根目录。
  Future<void> _applyLoginState(String raw, {required String from}) async {
    try {
      final map = AliyunPanService.parseWebLoginToken(raw);
      await _service.saveLogin(
        accessToken: '${map['access_token'] ?? ''}',
        refreshToken: '${map['refresh_token'] ?? ''}',
        driveId: '${map['default_drive_id'] ?? ''}',
        expireTimeMs: (map['expire_time'] as num?)?.toInt() ?? 0,
      );
      LogService.instance.info('AliyunPan', '登录态已保存', detail: '来源: $from');
      if (!mounted) return;
      setState(() => _loginValid = null);
      await _checkLogin(showToast: false);
      await _load(AliyunPanService.rootFileId, '根目录', replace: true);
      _toast('阿里云盘登录成功');
    } catch (e) {
      LogService.instance.error('AliyunPan', '保存登录态失败', error: e);
      _toast(_message(e));
    }
  }

  /// 手动粘贴登录态:给"内置浏览器抓不到 localStorage"的兜底入口。
  Future<void> _pasteLogin() async {
    final controller = TextEditingController();
    final raw = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('粘贴登录态'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '在电脑浏览器登录 alipan.com 后，打开开发者工具 → Application → '
              'Local Storage → https://www.alipan.com → 复制 token 的值（整段 JSON）。',
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              minLines: 3,
              maxLines: 6,
              decoration: const InputDecoration(
                isDense: true,
                hintText:
                    '{"access_token":"...","refresh_token":"...","default_drive_id":"..."}',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (!mounted) return;
    final text = (raw ?? '').trim();
    if (text.isEmpty) return;
    await _applyLoginState(text, from: '手动粘贴');
  }

  /// 应用凭据(client_id / client_secret)配置入口:只有填了才会自动刷新令牌。
  Future<void> _editCredentials() async {
    final idController = TextEditingController();
    final secretController = TextEditingController();
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('应用凭据（可选）'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '填上自己在阿里云盘开放平台申请的应用 client_id / client_secret 后，'
              'access_token 过期时可自动刷新，不用重新登录。留空保存不会改动已填内容。',
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: idController,
              decoration: const InputDecoration(
                isDense: true,
                labelText: 'client_id',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: secretController,
              obscureText: true,
              decoration: const InputDecoration(
                isDense: true,
                labelText: 'client_secret',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'clear'),
            child: const Text('清除凭据'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, 'save'),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    final clientId = idController.text.trim();
    final clientSecret = secretController.text.trim();
    idController.dispose();
    secretController.dispose();
    if (!mounted || action == null) return;
    if (action == 'clear') {
      await _service.saveClientCredentials(clientId: '', clientSecret: '');
      _toast('已清除应用凭据（令牌过期后只能重新登录）');
      return;
    }
    if (clientId.isEmpty && clientSecret.isEmpty) {
      _toast('没有填写内容，已保持原样');
      return;
    }
    if (clientId.isEmpty || clientSecret.isEmpty) {
      _toast('client_id 与 client_secret 需要成对填写');
      return;
    }
    await _service.saveClientCredentials(
      clientId: clientId,
      clientSecret: clientSecret,
    );
    _toast('应用凭据已保存');
  }

  Future<void> _checkLogin({bool showToast = true}) async {
    if (!_service.ready || _checkingLogin) return;
    setState(() => _checkingLogin = true);
    final ok = await _service.checkLogin();
    if (!mounted) return;
    setState(() {
      _loginValid = ok;
      _checkingLogin = false;
    });
    if (showToast) _toast(ok ? '阿里云盘登录状态正常' : '登录状态可能已失效，请重新登录');
  }

  Future<void> _logout() async {
    await _service.logout();
    if (!mounted) return;
    setState(() {
      _items = <AliyunPanItem>[];
      _loginValid = null;
      _pathStack
        ..clear()
        ..add(const _AliyunPathEntry(AliyunPanService.rootFileId, '根目录'));
    });
    _toast('已退出登录（应用凭据保留）');
  }

  // ── 浏览 ──

  /// [replace] 重置路径栈;[push] 为 false 时只刷新列表不改栈(面包屑跳转/上一级用)。
  Future<void> _load(
    String fileId,
    String name, {
    bool replace = false,
    bool push = true,
  }) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final items = await _service.list(fileId);
      if (!mounted) return;
      setState(() {
        _items = items;
        if (replace) {
          _pathStack
            ..clear()
            ..add(_AliyunPathEntry(fileId, name));
        } else if (push) {
          _pathStack.add(_AliyunPathEntry(fileId, name));
        }
      });
    } catch (e) {
      if (mounted) {
        setState(() => _error = _message(e));
      }
      LogService.instance.error('AliyunPan', '读取目录失败', error: e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 上一级:先把当前目录出栈再刷新父目录,全程保证栈非空。
  Future<void> _goUp() async {
    if (_pathStack.length <= 1 || _loading) return;
    final parent = _pathStack[_pathStack.length - 2];
    _pathStack.removeLast();
    await _load(parent.fileId, parent.name, push: false);
  }

  /// 面包屑跳转:截断到目标层,列表刷新为目标目录内容。
  Future<void> _jumpTo(int index) async {
    if (index < 0 || index >= _pathStack.length - 1 || _loading) return;
    final target = _pathStack[index];
    _pathStack.removeRange(index + 1, _pathStack.length);
    await _load(target.fileId, target.name, push: false);
  }

  Future<void> _playFile(AliyunPanItem item) async {
    setState(() => _loading = true);
    try {
      PlayerService.instance.setContext(
        sourceId: AliyunPanService.sourceId,
        bookId: item.fileId,
        bookTitle: item.name,
        cover: '',
        chapters: [
          {
            'chapterId': AliyunPanService.chapterIdFor(item),
            'index': 1,
            'name': item.name,
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
      if (mounted) _toast(_message(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<AliyunBook?> _buildBook() async {
    final book = await _service.toBook(
      _currentFileId,
      folderName: _currentName,
    );
    if (book.audioFiles.isEmpty) {
      _toast('这个文件夹（含子目录）里没有音频文件');
      return null;
    }
    return book;
  }

  String _authorOf(AliyunBook book) =>
      book.narrator.isEmpty ? book.author : '${book.author} / ${book.narrator}';

  Future<void> _addToShelf() async {
    setState(() => _loading = true);
    try {
      final book = await _buildBook();
      if (book == null) return;
      final author = _authorOf(book);
      await ShelfService.instance.add(
        sourceId: AliyunPanService.sourceId,
        bookId: book.fileId,
        title: book.title,
        cover: book.cover,
        author: author,
        sourceName: '阿里云盘',
      );
      await _cacheCatalog(book, author);
      _toast('已加入书架（${book.audioFiles.length} 集）');
    } catch (e) {
      if (mounted) _toast(_message(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _playBook() async {
    setState(() => _loading = true);
    try {
      // 目录缓存优先:命中即秒开,不重新枚举网盘(章节为 aliyun: 占位,播放时解析直链)。
      // 新增的文件在点"刷新目录"后可见。
      final cached = await CatalogCacheService.instance.load(
        sourceId: AliyunPanService.sourceId,
        bookId: _currentFileId,
      );
      if (cached != null && cached.chapters.isNotEmpty) {
        PlayerService.instance.setContext(
          sourceId: AliyunPanService.sourceId,
          bookId: _currentFileId,
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
        sourceId: AliyunPanService.sourceId,
        bookId: book.fileId,
        bookTitle: book.title,
        cover: book.cover,
        chapters: [
          for (var i = 0; i < book.audioFiles.length; i++)
            {
              'chapterId': AliyunPanService.chapterIdFor(book.audioFiles[i]),
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
      if (mounted) _toast(_message(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 刷新目录:重新枚举网盘(含子目录)并写入 SQLite 缓存;若正在播放的正是这本书,
  /// 顺手把播放器上下文换成新章节表,避免继续用旧列表。
  Future<void> _refreshCatalog() async {
    if (!_isBookFolder) {
      _toast('当前目录不是书籍目录（需 书名_作者_演播者），无法刷新目录');
      return;
    }
    setState(() => _loading = true);
    try {
      final cached = await CatalogCacheService.instance.load(
        sourceId: AliyunPanService.sourceId,
        bookId: _currentFileId,
      );
      final catalog = await _service.refreshCatalog(
        bookFileId: _currentFileId,
        folderName: _currentName,
        fallbackCover: cached?.info.cover ?? '',
        fallbackAuthor: cached?.info.author ?? '',
      );
      final player = PlayerService.instance;
      if (player.sourceId == AliyunPanService.sourceId &&
          player.bookId == _currentFileId) {
        player.setContext(
          sourceId: AliyunPanService.sourceId,
          bookId: _currentFileId,
          bookTitle: catalog.info.title,
          cover: catalog.info.cover,
          chapters: [
            for (final ch in catalog.chapters)
              {'chapterId': ch.chapterId, 'index': ch.index, 'name': ch.name},
          ],
        );
      }
      _toast('目录已刷新：${catalog.chapters.length} 集');
    } catch (e) {
      if (mounted) _toast(_message(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _cacheCatalog(AliyunBook book, String author) async {
    await CatalogCacheService.instance.savePage(
      sourceId: AliyunPanService.sourceId,
      bookId: book.fileId,
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
            chapterId: AliyunPanService.chapterIdFor(book.audioFiles[i]),
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

  String _message(Object e) => e.toString().replaceFirst('Exception: ', '');

  // ── UI ──

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('阿里云盘书库'),
        actions: [
          if (_service.ready && _isBookFolder)
            IconButton(
              icon: const Icon(Icons.bookmark_add_outlined),
              tooltip: '加入书架',
              onPressed: _loading ? null : _addToShelf,
            ),
          if (_service.ready && _isBookFolder)
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: '刷新目录（重新枚举网盘并写入缓存）',
              onPressed: _loading ? null : _refreshCatalog,
            ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _accountCard(cs),
          Expanded(child: _body(cs)),
        ],
      ),
      bottomNavigationBar: _service.ready
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

  /// 账号卡片:未登录/已登录状态 + 登录/粘贴/凭据/检测/退出 全部入口。
  Widget _accountCard(ColorScheme cs) {
    final service = _service;
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  service.ready
                      ? Icons.cloud_done_outlined
                      : Icons.cloud_off_outlined,
                  size: 18,
                  color: service.ready ? cs.primary : cs.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    service.ready ? '阿里云盘 · 已登录' : '阿里云盘 · 未登录',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Text(
                  _loginStateText(),
                  style: TextStyle(
                    fontSize: 12,
                    color: _loginValid == false
                        ? cs.error
                        : cs.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              _accountSummary(),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: _loading ? null : _login,
                  icon: const Icon(Icons.login, size: 18),
                  label: Text(service.ready ? '重新登录' : '登录（内置浏览器）'),
                ),
                OutlinedButton.icon(
                  onPressed: _loading ? null : _pasteLogin,
                  icon: const Icon(Icons.content_paste, size: 18),
                  label: const Text('粘贴登录态'),
                ),
                OutlinedButton.icon(
                  onPressed: _loading ? null : _editCredentials,
                  icon: const Icon(Icons.vpn_key_outlined, size: 18),
                  label: Text(
                    service.hasClientCredentials
                        ? '应用凭据 · 已填'
                        : '配置 client_id/secret',
                  ),
                ),
                if (service.ready)
                  OutlinedButton.icon(
                    onPressed: _checkingLogin ? null : () => _checkLogin(),
                    icon: const Icon(Icons.verified_user_outlined, size: 18),
                    label: const Text('检测登录状态'),
                  ),
                if (service.ready)
                  TextButton.icon(
                    onPressed: _loading ? null : _logout,
                    icon: const Icon(Icons.logout, size: 18),
                    label: const Text('退出登录'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _loginStateText() {
    if (!_service.ready) return '未登录';
    if (_checkingLogin) return '检测中…';
    if (_loginValid == null) return '未检测';
    return _loginValid! ? '状态正常' : '可能已失效';
  }

  String _accountSummary() {
    final service = _service;
    final parts = <String>[
      service.driveId.isEmpty
          ? 'drive_id: 缺失（请重新登录）'
          : 'drive_id: ${_shortId(service.driveId)}',
      service.hasRefreshToken ? '可自动刷新令牌' : '无 refresh_token（过期需重登）',
      service.hasClientCredentials ? '已填应用凭据' : '未填应用凭据（无法自动刷新）',
    ];
    return parts.join(' · ');
  }

  String _shortId(String id) {
    if (id.length <= 12) return id;
    return '${id.substring(0, 6)}…${id.substring(id.length - 4)}';
  }

  /// 面包屑:点上层目录直接跳回,当前层不可点。
  Widget _breadcrumb(ColorScheme cs) {
    return SizedBox(
      height: 34,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        itemCount: _pathStack.length,
        separatorBuilder: (_, _) =>
            Icon(Icons.chevron_right, size: 16, color: cs.onSurfaceVariant),
        itemBuilder: (context, index) {
          final entry = _pathStack[index];
          final isLast = index == _pathStack.length - 1;
          return Center(
            child: TextButton(
              onPressed: isLast || _loading ? null : () => _jumpTo(index),
              style: TextButton.styleFrom(
                minimumSize: Size.zero,
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text(
                entry.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  color: isLast ? cs.primary : cs.onSurfaceVariant,
                  fontWeight: isLast ? FontWeight.w600 : FontWeight.normal,
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _browser(ColorScheme cs) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _breadcrumb(cs),
        if (_isBookFolder)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Text(
              '$_currentName · 可加入书架 / 刷新目录 / 播放整本',
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
            onRefresh: () => _load(_currentFileId, _currentName, replace: true),
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
                      final isAudio = AliyunPanService.isAudioName(item.name);
                      final isCover = AliyunPanService.isCoverName(item.name);
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
                            : Text(_formatSize(item.size)),
                        trailing:
                            item.isDirectory &&
                                AliyunPanService.parseFolderName(item.name) !=
                                    null
                            ? const Icon(Icons.menu_book_outlined)
                            : null,
                        onTap: item.isDirectory
                            ? () => _load(item.fileId, item.name)
                            : (isAudio ? () => _playFile(item) : null),
                      );
                    },
                  ),
          ),
        ),
      ],
    );
  }

  /// 未登录 → 登录引导;有登录态但缺 drive_id → 可操作提示(否则浏览必然抛错);
  /// 否则正常浏览。
  Widget _body(ColorScheme cs) {
    if (!_service.ready) return _emptyHint(cs);
    if (_service.driveId.isEmpty) return _missingDriveId(cs);
    return _browser(cs);
  }

  Widget _missingDriveId(ColorScheme cs) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.key_off_outlined, size: 52, color: cs.error),
            const SizedBox(height: 12),
            Text('登录态缺少 drive_id', style: TextStyle(color: cs.error)),
            const SizedBox(height: 6),
            Text(
              '列目录与取直链都需要 default_drive_id。请重新登录抓一次完整登录态，'
              '或用「粘贴登录态」贴入含 default_drive_id 的整段 JSON。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _loading ? null : _login,
              icon: const Icon(Icons.login),
              label: const Text('重新登录'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _emptyHint(ColorScheme cs) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_outlined, size: 52, color: cs.onSurfaceVariant),
            const SizedBox(height: 12),
            Text('先登录阿里云盘', style: TextStyle(color: cs.onSurfaceVariant)),
            const SizedBox(height: 6),
            Text(
              '用上方账号卡片里的「登录（内置浏览器）」；抓不到 localStorage 时可改用「粘贴登录态」。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
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
