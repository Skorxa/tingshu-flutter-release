// 听优有声（tingyou.fm）HTML + 嗅探源
// 接口:
//   search        GET /search/result?keyword=&page=     → SSR HTML, 解析 .list-item
//   discover      GET /api/payload + 分类加密接口       → XChaCha20-Poly1305 解密
//   getChapters   GET /albums/{id}                       → 解析 __NUXT_DATA__（明文全量 2115 章节）
//   getAudioUrl   返回 sniff 指令, App 后台 WebView 加载 /albums/{id}/{idx} (SPA 自动播放),
//                 抓 file.hgeuz.cn/stream 时效签名直链
// 鉴权: 无 | 站点为 Nuxt SSR, 数据接口(album_chapters)是加密 payload, 故走页面解析 + 嗅探
({
  name: '听友FM',
  id: 'tingyou',
  apiVersion: 1,
  _base: 'https://www.tingyou.fm',
  _payloadUrl: 'https://www.tingyou.fm/api/payload',
  _ua: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36',
  _payloadConfig: null,
  _payloadConfigAt: 0,

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

  _getJson(url, timeout = 12000) {
    return new Promise((resolve, reject) => {
      uni.request({
        url,
        method: 'GET',
        header: { 'User-Agent': this._ua, Referer: this._base + '/' },
        timeout,
        success: r => {
          if (r.statusCode < 200 || r.statusCode >= 300) {
            reject(new Error('HTTP ' + r.statusCode + ' | ' + url))
            return
          }
          try {
            resolve(typeof r.data === 'string' ? JSON.parse(r.data) : r.data)
          } catch (_) {
            reject(new Error('JSON 解析失败 | ' + url))
          }
        },
        fail: e => reject(new Error(e.errMsg || '网络失败')),
      })
    })
  },

  async _getPayloadConfig(force = false) {
    const now = Date.now()
    if (!force && this._payloadConfig && now - this._payloadConfigAt < 5 * 60 * 1000) {
      return this._payloadConfig
    }
    const data = await this._getJson(this._payloadUrl)
    const payload = data && data.payload || {}
    const pool = data && data.staticRoutePools && data.staticRoutePools.category_page || {}
    const key = String(payload.key || '').trim()
    const routes = [pool.primary].concat(Array.isArray(pool.backups) ? pool.backups : [])
      .map(x => String(x || '').replace(/\/+$/, ''))
      .filter((x, i, all) => /^https?:\/\//.test(x) && all.indexOf(x) === i)
    if (!/^[0-9a-f]{64}$/i.test(key)) throw new Error('分类接口没有返回有效的动态密钥')
    if (!routes.length) throw new Error('分类接口没有返回可用线路')
    this._payloadConfig = { key, routes }
    this._payloadConfigAt = now
    return this._payloadConfig
  },

  async _decryptPayload(data, key) {
    const envelope = data && typeof data === 'object' ? data.payload : ''
    const raw = String(envelope || '').replace(/^0x/i, '').trim()
    if (!/^[0-9a-f]+$/i.test(raw) || raw.length < 2 + 48 + 32 || raw.length % 2 !== 0) {
      throw new Error('分类接口返回了无效的加密 payload')
    }
    const version = parseInt(raw.slice(0, 2), 16)
    const nonce = raw.slice(2, 50)
    let cipherText = raw.slice(50)
    if (version === 2) cipherText = (cipherText.match(/../g) || []).reverse().join('')
    if (version !== 1 && version !== 2) throw new Error('不支持的 payload 版本: ' + version)
    const plainText = await uni.crypto.xChaCha20Poly1305Decrypt({
      cipherText,
      key,
      nonce,
      inputEncoding: 'hex',
      keyEncoding: 'hex',
      nonceEncoding: 'hex',
    })
    try {
      return JSON.parse(plainText)
    } catch (_) {
      throw new Error('分类 payload 解密成功但内容不是 JSON')
    }
  },

  async _loadEncrypted(path, config) {
    const errors = []
    for (let i = 0; i < config.routes.length; i++) {
      const url = config.routes[i] + path
      try {
        return await this._decryptPayload(await this._getJson(url, 10000), config.key)
      } catch (e) {
        errors.push(String(e && e.message || e))
      }
    }
    throw new Error('分类主备线路均失败: ' + errors.join('；').slice(0, 300))
  },

  _findBookRows(value, depth = 0) {
    if (depth > 4 || value == null) return []
    if (Array.isArray(value)) {
      if (value.some(item => item && typeof item === 'object'
        && (item.id !== undefined || item.album_id !== undefined)
        && (item.title !== undefined || item.name !== undefined))) return value
      for (let i = 0; i < value.length; i++) {
        const found = this._findBookRows(value[i], depth + 1)
        if (found.length) return found
      }
      return []
    }
    if (typeof value !== 'object') return []
    const preferred = ['list', 'items', 'albums', 'results', 'data']
    for (let i = 0; i < preferred.length; i++) {
      if (value[preferred[i]] === undefined) continue
      const found = this._findBookRows(value[preferred[i]], depth + 1)
      if (found.length) return found
    }
    const keys = Object.keys(value)
    for (let i = 0; i < keys.length; i++) {
      const found = this._findBookRows(value[keys[i]], depth + 1)
      if (found.length) return found
    }
    return []
  },

  _toBooks(data, limit = 8) {
    return this._findBookRows(data).map(item => {
      const count = Number(item.count || item.track_count || item.trackCount || 0)
      const author = String(item.author || '').trim()
      const teller = String(item.teller || item.anchor || '').trim()
      const intro = []
      if (teller && teller !== author) intro.push('演播: ' + teller)
      if (count > 0) intro.push(count + '集')
      if (item.status) intro.push(String(item.status))
      return {
        bookId: String(item.id || item.album_id || item.albumId || ''),
        title: String(item.title || item.name || '').trim(),
        cover: String(item.cover_url || item.cover || item.pic || ''),
        author: author || teller,
        intro: intro.join(' · '),
      }
    }).filter(item => item.bookId && item.title).slice(0, limit)
  },

  async _loadCategory(category, config) {
    const data = await this._loadEncrypted(
      '/types/' + category.id + '/' + category.sort + '/p1',
      config,
    )
    return this._toBooks(data, 8)
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

  async discover() {
    const categories = [
      { title: '热门', id: 46, sort: 'popular' },
      { title: '玄幻奇幻', id: 46, sort: 'comprehensive' },
      { title: '武侠小说', id: 11, sort: 'comprehensive' },
      { title: '恐怖惊悚', id: 14, sort: 'comprehensive' },
      { title: '历史军事', id: 15, sort: 'comprehensive' },
      { title: '广播剧', id: 36, sort: 'comprehensive' },
    ]
    const config = await this._getPayloadConfig()
    const loaded = new Array(categories.length)
    let next = 0
    const worker = async () => {
      while (next < categories.length) {
        const index = next++
        try {
          const list = await this._loadCategory(categories[index], config)
          if (list.length) loaded[index] = { title: categories[index].title, list }
        } catch (_) {
          // 单个分区失败不影响其他分区。
        }
      }
    }
    await Promise.all([worker(), worker()])
    const sections = loaded.filter(Boolean)
    if (!sections.length) {
      this._payloadConfig = null
      const fresh = await this._getPayloadConfig(true)
      const list = await this._loadCategory(categories[1], fresh)
      if (list.length) sections.push({ title: categories[1].title, list })
    }
    return { sections }
  },

  // ── getChapters: bookId 即 albumId。请求专辑页, 从 __NUXT_DATA__ 还原全量章节 ──
  async getChapters(bookId, page = 1, pageSize = 200) {
    pageSize = pageSize || 200
    const html = await this._get('/albums/' + encodeURIComponent(bookId))
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

  // ── getAudioUrl: chapterId = "albumId/index"。返回嗅探指令, App 后台 WebView 打开
  //                  /albums/{id}/{idx} (SPA 自动播放, 把 file.hgeuz.cn/stream 签名直链写入 <audio>)
  async getAudioUrl(chapterId) {
    if (!chapterId || String(chapterId).indexOf('/') < 0) {
      throw new Error('无效的 chapterId: ' + JSON.stringify(chapterId))
    }
    const url = this._base + '/albums/' + String(chapterId)
    return {
      sniff: true,
      url,
      headers: { 'User-Agent': this._ua, Referer: this._base + '/' },
      click: '',                                       // SPA 路由跳转后自动开始播放, 不需点击
      waitMs: 4000,
      audioPatterns: ['file.hgeuz.cn/stream', '/stream/', '.mp3', '.m4a', '.aac', '.m3u8'],
    }
  },
})
