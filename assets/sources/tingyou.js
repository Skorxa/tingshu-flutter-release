// 听优有声（tingyou.fm）HTML + 嗅探源
// 接口:
//   search        GET /search/result?keyword=&page=     → SSR HTML, 解析 .list-item
//   getChapters   GET /audios/{albumId}/1                → 解析章节页 __NUXT_DATA__（明文全量章节）
//   getAudioUrl   返回 sniff 指令, App 用内置 WebView 打开播放页, 抓 file.hgeuz.cn/stream 直链
// 鉴权: 无 | 站点为 Nuxt SSR, 数据接口(album_chapters)是加密 payload, 故走页面解析 + 嗅探
({
  name: '听优有声',
  id: 'tingyou',
  apiVersion: 1,
  _base: 'https://tingyou.fm',
  _ua: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36',

  // ── 公共 GET, 统一判状态码, 返回 HTML 文本 ──
  _get(path) {
    const url = this._base + path
    return new Promise((resolve, reject) => {
      uni.request({
        url,
        method: 'GET',
        header: { 'User-Agent': this._ua, Referer: this._base + '/' },
        timeout: 20000,
        success: r => (r.statusCode >= 200 && r.statusCode < 300)
          ? resolve(String(r.data || ''))
          : reject(new Error('HTTP ' + r.statusCode + ' | ' + url)),
        fail: e => reject(new Error(e.errMsg || '网络失败')),
      })
    })
  },

  // ── HTML 文本清洗 ──
  _clean(text) {
    return String(text || '')
      .replace(/<[^>]+>/g, ' ')
      .replace(/&nbsp;/g, ' ')
      .replace(/&amp;/g, '&')
      .replace(/&lt;/g, '<')
      .replace(/&gt;/g, '>')
      .replace(/&#(\d+);/g, (_, n) => String.fromCharCode(parseInt(n, 10)))
      .replace(/&#x([0-9a-f]+);/gi, (_, n) => String.fromCharCode(parseInt(n, 16)))
      .replace(/\s+/g, ' ')
      .trim()
  },

  // ── 抽取页面里的 __NUXT_DATA__ JSON 数组（devalue 扁平数组）──
  _nuxtData(html) {
    const m = String(html).match(/<script[^>]*id="__NUXT_DATA__"[^>]*>([\s\S]*?)<\/script>/)
    if (!m) throw new Error('未找到 __NUXT_DATA__（页面结构可能已变）')
    try {
      return JSON.parse(m[1])
    } catch (e) {
      throw new Error('解析 __NUXT_DATA__ 失败: ' + String(e).slice(0, 120))
    }
  },

  // ── search: /search/result?keyword=&page= ，解析 <a class="list-item"> 列表 ──
  async search(keyword, page = 1, pageSize = 20) {
    pageSize = pageSize || 20
    const html = await this._get('/search/result?keyword=' + encodeURIComponent(keyword) + '&page=' + page)
    const list = []
    // 每个结果: <a href="/albums/{id}" class="list-item" ...> ... <p class="title">..</p> <p class="desc">..</p> <span class="text">N 期</span> </a>
    const re = /<a\s+href="\/albums\/(\d+)"[^>]*class="list-item"[^>]*>([\s\S]*?)<\/a>/g
    let m
    while ((m = re.exec(html)) !== null) {
      const bookId = m[1]
      const block = m[2]
      const title = this._clean((block.match(/<p[^>]*class="title"[^>]*>([\s\S]*?)<\/p>/) || [])[1] || '')
        || this._clean((block.match(/<img[^>]*\balt="([^"]*)"/) || [])[1] || '')
      if (!bookId || !title) continue
      const desc = this._clean((block.match(/<p[^>]*class="desc"[^>]*>([\s\S]*?)<\/p>/) || [])[1] || '')
      const count = this._clean((block.match(/<span[^>]*class="text"[^>]*>([\s\S]*?)<\/span>/) || [])[1] || '')
      list.push({
        bookId,
        title,
        cover: '',                                   // 列表页封面为懒加载, 无 src; 进目录后由 getChapters 补
        author: '',
        intro: [count, desc].filter(Boolean).join(' · '),
      })
    }
    // 搜不到返回空 list, 不抛错
    return { list: list.slice(0, pageSize), page, maxPage: 1, hasMore: false }
  },

  // ── getChapters: bookId 即 albumId。请求任一章节页, 从 __NUXT_DATA__ 还原全量章节 ──
  async getChapters(bookId, page = 1, pageSize = 200) {
    pageSize = pageSize || 200
    const html = await this._get('/audios/' + encodeURIComponent(bookId) + '/1')
    const arr = this._nuxtData(html)

    // devalue: 章节对象模板形如 { id, index, title, duration, creator_type, creator_id }
    // 其 index/title 字段值是“指向 arr 的下标”, 需再解引用
    const all = []
    for (let i = 0; i < arr.length; i++) {
      const el = arr[i]
      if (el && typeof el === 'object' && !Array.isArray(el)
        && el.index !== undefined && el.title !== undefined && el.duration !== undefined) {
        const idx = arr[el.index]
        const title = arr[el.title]
        if (typeof idx === 'number' && typeof title === 'string') {
          all.push({ index: idx, name: title })
        }
      }
    }
    all.sort((a, b) => a.index - b.index)
    if (all.length === 0) throw new Error('章节列表为空（解析失败或专辑无章节）')

    // 专辑信息: 对象模板含 { title, cover_url, count, author }
    const info = { title: '', cover: '', author: '', trackCount: all.length, isFinished: false }
    for (let i = 0; i < arr.length; i++) {
      const el = arr[i]
      if (el && typeof el === 'object' && !Array.isArray(el)
        && el.title !== undefined && el.cover_url !== undefined && el.count !== undefined) {
        info.title = String(arr[el.title] || '')
        info.cover = String(arr[el.cover_url] || '')
        info.author = String(arr[el.author] || '')
        info.trackCount = Number(arr[el.count]) || all.length
        break
      }
    }

    const maxPage = Math.max(1, Math.ceil(all.length / pageSize))
    const safePage = Math.max(1, Math.min(page, maxPage))
    const start = (safePage - 1) * pageSize
    const slice = all.slice(start, start + pageSize)
    return {
      info,
      list: slice.map(x => ({
        chapterId: bookId + '/' + x.index,   // 编码 albumId/index, 供 getAudioUrl 拼播放页
        index: x.index,
        name: x.name,
      })),
      page: safePage,
      maxPage,
      hasMore: safePage < maxPage,
    }
  },

  // ── getAudioUrl: chapterId = "albumId/index"。返回嗅探指令, 由 App WebView 抓时效签名直链 ──
  async getAudioUrl(chapterId) {
    if (!chapterId || String(chapterId).indexOf('/') < 0) {
      throw new Error('无效的 chapterId: ' + JSON.stringify(chapterId))
    }
    const url = this._base + '/audios/' + String(chapterId)
    return {
      sniff: true,
      url,
      headers: { 'User-Agent': this._ua, Referer: this._base + '/' },
      click: '.play-btn',                            // 播放页需点击“播放”触发音频请求
      waitMs: 5000,
      audioPatterns: ['file.hgeuz.cn/stream', '/stream/', '.mp3', '.m4a', '.aac', '.m3u8'],
    }
  },
})
