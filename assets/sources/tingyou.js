// 听友FM（tingyou.fm）直连版
// 搜索:     GET /search/result?keyword=&page=          → SSR HTML 解析 .list-item
// 发现页:   json 镜像分类接口（XChaCha20-Poly1305 解密）
// 目录:     json 镜像 album_info/{id} + album_chapters/{id}（解密）→ NUXT HTML 解析兜底
// 音频直连: POST /api/play_token（AES-256-GCM 加密请求体 + Bearer 令牌）→ 解密响应取 play_url
//   令牌:   POST /api/guest（加密空对象）→ auth_token（Fernet）
//   设备:   dfp Cookie = f-{base36(YYYYMMDD)}:f-{base64(SM4-ECB(指纹串, sha256('fa317cd29b|日期')前16字节))}
//   回退:   直连失败时返回嗅探指令（旧方案, App WebView 打开 /audios/{id}/{idx} 抓流）
// 请求/响应加密均为 hex 信封: 版本字节(1B=01/02) + IV/nonce + 密文; 版本2 时密文字节对反转;
// 请求用 AES-GCM（uni.crypto.aesGcmEncrypt 返回 IV||密文||TAG）, 响应用 XChaCha20-Poly1305
({
  name: '听友FM',
  id: 'tingyou',
  version: 2,
  apiVersion: 1,
  _base: 'https://www.tingyou.fm',
  _ua: 'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Mobile Safari/537.36',
  _payloadUrl: 'https://www.tingyou.fm/api/payload',
  _payloadConfig: null,
  _payloadConfigAt: 0,
  _dfp: '', _dfpDay: '',
  _auth: '', _authAt: 0,
  _cookies: {},
  _audioCache: {},

  // ── 公共 GET（HTML/明文 JSON）──
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

  // ── 动态密钥与镜像线路 ──
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
      throw new Error('接口返回了无效的加密 payload')
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
      throw new Error('payload 解密成功但内容不是 JSON')
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
    throw new Error('镜像线路均失败: ' + errors.join('；').slice(0, 300))
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
    // 每个结果: <a href="/albums/{id}" class="list-item"> ... <p class="title"> <p class="desc"> <span class="text">N 期
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
        cover: '',
        author: '',
        intro: [count, desc].filter(Boolean).join(' · '),
      })
    }
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

  // ── getChapters: 镜像接口（解密）为主, NUXT 页面解析兜底 ──
  async getChapters(bookId, page = 1, pageSize = 200) {
    pageSize = pageSize || 200
    const p = Math.max(1, Number(page) || 1)
    try {
      const config = await this._getPayloadConfig()
      const info = await this._loadEncrypted('/album_info/' + encodeURIComponent(bookId), config)
      const ch = await this._loadEncrypted('/album_chapters/' + encodeURIComponent(bookId), config)
      const rows = Array.isArray(ch && ch.chapters) ? ch.chapters : []
      const all = rows
        .map(x => ({ index: Number(x.index) || 0, name: String(x.title || '').trim() }))
        .filter(x => x.name)
        .sort((a, b) => a.index - b.index)
      if (!all.length) throw new Error('章节列表为空')
      const author = String(info.author || '').trim()
      const teller = String(info.teller || '').trim()
      const result = {
        info: {
          title: String(info.title || ''),
          cover: String(info.cover_url || info.cover || ''),
          author: author || teller,
          trackCount: Number(info.count) || all.length,
          isFinished: Number(info.status) === 1,
        },
        list: [],
        page: p, maxPage: 1, hasMore: false,
      }
      const maxPage = Math.max(1, Math.ceil(all.length / pageSize))
      const safePage = Math.max(1, Math.min(p, maxPage))
      const start = (safePage - 1) * pageSize
      result.list = all.slice(start, start + pageSize).map(x => ({
        chapterId: bookId + '/' + x.index,
        index: x.index,
        name: x.name,
      }))
      result.page = safePage
      result.maxPage = maxPage
      result.hasMore = safePage < maxPage
      return result
    } catch (e) {
      return this._chaptersViaNuxt(bookId, p, pageSize)
    }
  },

  // NUXT 页面解析兜底（镜像失效时走这里）
  async _chaptersViaNuxt(bookId, page, pageSize) {
    const html = await this._get('/albums/' + encodeURIComponent(bookId))
    const arr = this._nuxtData(html)
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
    return {
      info,
      list: all.slice(start, start + pageSize).map(x => ({
        chapterId: bookId + '/' + x.index,
        index: x.index,
        name: x.name,
      })),
      page: safePage,
      maxPage,
      hasMore: safePage < maxPage,
    }
  },

  // ════════ 音频直连 ════════

  _today() {
    const d = new Date()
    return '' + d.getFullYear() + ('0' + (d.getMonth() + 1)).slice(-2) + ('0' + d.getDate()).slice(-2)
  },

  // dfp 设备指纹 Cookie（SM4-ECB, 密钥随日期变化；服务端只验可解密性）
  async _ensureDfp(keyHex) {
    const day = this._today()
    if (this._dfp && this._dfpDay === day) return this._dfp
    const sha = await uni.crypto.sha256Hex({ text: 'fa317cd29b|' + day })
    const fp = 'tyfm|' + this._ua + '|' + day
    const enc = await uni.crypto.sm4EcbEncrypt({ plainText: fp, key: sha.slice(0, 32) })
    this._dfp = 'f-' + parseInt(day, 10).toString(36) + ':f-' + encodeURIComponent(enc)
    this._dfpDay = day
    return this._dfp
  },

  _cookieHeader() {
    const parts = []
    if (this._dfp) parts.push('dfp=' + this._dfp)
    for (const k in this._cookies) parts.push(k + '=' + this._cookies[k])
    return parts.join('; ')
  },

  _captureCookies(header) {
    if (!header) return
    let raw = header['set-cookie'] || header['Set-Cookie'] || null
    if (!raw) return
    if (!Array.isArray(raw)) raw = [raw]
    for (const c of raw) {
      const kv = String(c).split(';')[0]
      const eq = kv.indexOf('=')
      if (eq > 0) this._cookies[kv.slice(0, eq).trim()] = kv.slice(eq + 1).trim()
    }
  },

  // 加密请求体: '01' + IV||密文||TAG(hex)
  async _encBody(obj, keyHex) {
    const inner = await uni.crypto.aesGcmEncrypt({
      plainText: JSON.stringify(obj),
      key: keyHex,
      outputEncoding: 'hex',
    })
    return '01' + inner
  },

  async _apiPost(path, obj) {
    const config = await this._getPayloadConfig()
    await this._ensureDfp(config.key)
    const body = await this._encBody(obj, config.key)
    return new Promise((resolve, reject) => {
      uni.request({
        url: this._base + path,
        method: 'POST',
        header: {
          'User-Agent': this._ua,
          'Content-Type': 'text/plain',
          'x-payload-version': '1',
          Accept: 'application/json',
          Origin: this._base,
          Referer: this._base + '/',
          Cookie: this._cookieHeader(),
        },
        data: body,
        timeout: 15000,
        success: r => {
          this._captureCookies(r.header)
          resolve({ statusCode: r.statusCode || 0, data: r.data })
        },
        fail: e => reject(new Error(e.errMsg || '网络失败')),
      })
    })
  },

  async _decryptResponse(res) {
    let parsed = res.data
    if (typeof parsed === 'string') {
      try { parsed = JSON.parse(parsed) } catch (e) { throw new Error('响应不是 JSON: ' + String(parsed).slice(0, 80)) }
    }
    if (parsed && parsed.detail && !parsed.payload) return parsed   // 明文错误响应
    return this._decryptPayload(parsed, this._payloadConfig.key)
  },

  async _guestLogin() {
    const res = await this._apiPost('/api/guest', {})
    if (res.statusCode !== 200) throw new Error('guest 接口 HTTP ' + res.statusCode)
    const data = await this._decryptResponse(res)
    if (!data || !data.auth_token) throw new Error('guest 未返回 auth_token')
    this._auth = String(data.auth_token)
    this._authAt = Date.now()
    return this._auth
  },

  async _ensureAuth() {
    if (this._auth && Date.now() - this._authAt < 10 * 60 * 1000) return this._auth
    return this._guestLogin()
  },

  // getAudioUrl: chapterId = "albumId/index"
  async getAudioUrl(chapterId) {
    const s = String(chapterId || '')
    const sep = s.indexOf('/')
    if (sep < 1) throw new Error('无效的 chapterId: ' + JSON.stringify(chapterId))
    const albumId = s.slice(0, sep)
    const idx = s.slice(sep + 1)
    const hit = this._audioCache[s]
    if (hit && Date.now() - hit.at < 240000) return hit.value

    // 直连：guest 令牌 → play_token → play_url
    try {
      await this._ensureAuth()
      let res = await this._apiPost('/api/play_token', { album_id: Number(albumId), chapter_idx: Number(idx) || 1 })
      if (res.statusCode === 401) {
        // 令牌过期 → 重新登录一次
        this._auth = ''
        await this._guestLogin()
        res = await this._apiPost('/api/play_token', { album_id: Number(albumId), chapter_idx: Number(idx) || 1 })
      }
      if (res.statusCode !== 200) throw new Error('play_token HTTP ' + res.statusCode)
      const data = await this._decryptResponse(res)
      const playUrl = data && data.play_url
      if (!playUrl || !/^https?:\/\//i.test(playUrl)) {
        throw new Error((data && data.detail) || 'play_url 为空')
      }
      const value = { url: playUrl, headers: { 'User-Agent': this._ua, Referer: this._base + '/' } }
      this._audioCache[s] = { value, at: Date.now() }
      return value
    } catch (e) {
      // 直连失败 → 回退嗅探（旧方案）
      return this._sniffFallback(s)
    }
  },

  _sniffFallback(chapterId) {
    // 旧 App 无新加密桥时走这里。站点 SPA 较慢, 自动点击播放按钮( SSR 初始 HTML 即含 .play-btn )
    // 并把等待拉长到 12s( 嗅探器每秒扫描一次, 总上限 20s 由 App 控制 )
    return {
      sniff: true,
      url: this._base + '/audios/' + String(chapterId),
      headers: { 'User-Agent': this._ua, Referer: this._base + '/' },
      click: '.play-btn',
      waitMs: 12000,
      audioPatterns: ['file.hgeuz.cn/stream', '/stream/', '.mp3', '.m4a', '.aac', '.m3u8'],
    }
  },
})
