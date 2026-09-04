// 13听书网（www.ting13.cc · PTCMS 架构）
// 链路：搜索 POST /novelsearch/search/result.html
//       目录 书籍页 a.dirurl → /tingdirs/*.html?page=N&sort=asc（站点固定分页，源内做窗口换算）
//       播放 章节页 meta(_b/_p/_c/_d) → POST /api/mapi/play（headers: sc=_c, sp=_c 移位乱序填充）
// 盾点：部分页面返回 51 挑战（var reversed），解出 __51guid__ 后重试；
//       sp 字母表必须用站点乱序表并做 (idx+3)%62 移位，顺序字母表会得到 405。
// 登录：免费内容可匿名播放；VIP/风控收紧时需要账号。支持账号池自动登录或内置 WebView Cookie。
// 限流：站点对高频访问返回 429。所有请求经全局队列串行化并保持最小间隔，
//       429/503 按 Retry-After 或指数退避重试；播放直链带 5 分钟 TTL 缓存去重。
({
  id: 'tingshu-json-ting13',
  name: '13听书网',
  apiVersion: 1,

  login: {
    url: 'https://www.ting13.cc/user/public/login.html',
    configKey: 'cookie'
  },

  configFields: [
    {
      key: 'accounts',
      label: '账号池',
      type: 'account_list',
      hint: '推荐：填写站内注册的邮箱和密码，音源会自动登录；可随时增删',
      required: false
    },
    {
      key: 'cookie',
      label: 'Cookie',
      type: 'textarea',
      hint: '备选：长按本音源“登录”会自动写入；也可手动粘贴含 PTCMS_token 的网页 Cookie',
      required: false
    }
  ],

  _site: 'https://www.ting13.cc',
  _ua: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36',
  // 播放接口 sp 头的真实字母表（从站点混淆播放器脚本中还原）
  _spTable: 'PXhw7U1B0a9kQDKZsTjIASmOeNzxYG4CHo1JyRfg2b8FLpEvr3FtVnlqMidu6c',
  _cookies: {},
  _bookCache: {},
  _tocCache: {},
  _audioCache: {},
  _loggingIn: null,
  _queue: null,
  _lastReqAt: 0,

  // ── 限流防御：全局串行 + 最小间隔 ─────────────────────────────

  _sleep(ms) {
    return new Promise(resolve => setTimeout(resolve, ms))
  },

  // 所有站点请求都经过这里：保证任意两次请求之间至少间隔 _minGap 毫秒
  _gate() {
    const prev = this._queue || Promise.resolve()
    const job = prev.then(() => {
      const wait = Math.max(0, this._lastReqAt + 400 - Date.now())
      return this._sleep(wait + Math.floor(Math.random() * 120))
    }).then(() => { this._lastReqAt = Date.now() })
    this._queue = job.catch(() => {})
    return job
  },

  // ── 基础设施：Cookie 管理 + 51 盾 ─────────────────────────────

  _cookieHeader() {
    return Object.keys(this._cookies).map(k => k + '=' + this._cookies[k]).join('; ')
  },

  _remember(header) {
    const raw = header && (header['set-cookie'] || header['Set-Cookie'])
    const list = Array.isArray(raw) ? raw : (raw ? [String(raw)] : [])
    for (const line of list) {
      const pair = String(line).split(';')[0]
      const idx = pair.indexOf('=')
      if (idx > 0) this._cookies[pair.slice(0, idx).trim()] = pair.slice(idx + 1).trim()
    }
  },

  // 响应若为 51 挑战页，解码出 guid 写入 Cookie 并返回 true
  _pass51(html) {
    const m = String(html).match(/var\s+reversed\s*=\s*"([\s\S]*?)";/)
    if (!m) return false
    try {
      const code = atob(m[1].replace(/\s+/g, '').split('').reverse().join(''))
      const token = (code.match(/var\s+token\s*=\s*'([^']*)'/) || [])[1] || ''
      const retry = (code.match(/var\s+retry\s*=\s*([0-9]+)/) || [])[1] || '1'
      if (!token) return false
      this._cookies['__51guid__'] = encodeURIComponent(token)
      this._cookies['__51refresh__guid'] = retry
      return true
    } catch (e) { return false }
  },

  _retryAfterMs(header) {
    const raw = header && (header['retry-after'] || header['Retry-After'])
    const value = Array.isArray(raw) ? raw[0] : raw
    const seconds = Number(value)
    if (isFinite(seconds) && seconds > 0) return Math.min(15000, Math.max(1000, seconds * 1000))
    return 0
  },

  async _request(options) {
    const o = options || {}
    const method = (o.method || 'GET').toUpperCase()
    let last = { statusCode: 0, data: null, header: {} }

    for (let attempt = 0; attempt < 3; attempt++) {
      const headers = Object.assign({
        'User-Agent': this._ua,
        Referer: o.referer || (this._site + '/')
      }, o.headers || {})
      if (method !== 'GET') headers.Origin = headers.Origin || this._site
      const cookie = this._cookieHeader()
      if (cookie) headers.Cookie = cookie

      await this._gate()
      const r = await new Promise((resolve, reject) => {
        uni.request({
          url: o.url,
          method,
          data: o.data,
          header: headers,
          timeout: o.timeout || 20000,
          success: res => resolve({ statusCode: res.statusCode || 0, data: res.data, header: res.header || {} }),
          fail: e => reject(new Error((e && e.errMsg) || '网络失败'))
        })
      })
      this._remember(r.header)
      last = r

      if (r.statusCode >= 200 && r.statusCode < 300) break
      // 限流/过载：按 Retry-After 或指数退避后再试（总预算控制在引擎超时内）
      if ((r.statusCode === 429 || r.statusCode === 503) && attempt < 2) {
        await this._sleep(this._retryAfterMs(r.header) || (attempt === 0 ? 1500 : 4000))
        continue
      }
      break
    }
    return last
  },

  // GET HTML：自动处理 51 挑战（挑战可能出现在任何状态码上）
  async _getHtml(url, referer) {
    for (let i = 0; i < 3; i++) {
      const r = await this._request({ url, referer })
      const html = String(r.data || '')
      if (!html.match(/var\s+reversed\s*=/)) {
        if (r.statusCode < 200 || r.statusCode >= 300) {
          throw new Error('HTTP ' + r.statusCode + ' | ' + url)
        }
        return html
      }
      if (!this._pass51(html)) break
    }
    throw new Error('页面持续返回人机验证 | ' + url)
  },

  // ── 登录：账号池程序化登录 / WebView Cookie 注入 ─────────────

  _isLoggedIn() {
    return !!(this._cookies.PTCMS_token || this._cookies.PTCMS_userid)
  },

  _config() {
    return this.config || uni.getStorageSync('sourceConfig') || {}
  },

  _accounts() {
    const cfg = this._config()
    let raw = cfg.accounts
    if (typeof raw === 'string') {
      try { raw = raw.trim() ? JSON.parse(raw) : [] } catch (e) {
        throw new Error('账号池配置格式无效')
      }
    }
    const arr = Array.isArray(raw) ? raw : (raw && Array.isArray(raw.list) ? raw.list : [])
    const out = []
    for (const item of arr) {
      if (!item) continue
      const email = String(item.email || item.account || item.username || '').trim()
      const password = String(item.password || '').trim()
      if (email && password && !out.some(x => x.email === email)) {
        out.push({ email, password })
      }
    }
    return out
  },

  async _programLogin(account) {
    // 1) 登录页（拿 PHPSESSID 等会话 Cookie，可能带 51 盾）
    await this._getHtml(this._site + '/user/public/login.html', this._site + '/')
    // 2) 申请验证 token
    const token = String(Date.now()) + String(Math.floor(Math.random() * 1e8))
    const st = await this._request({
      url: this._site + '/user/public/store_token.html',
      method: 'POST',
      data: JSON.stringify({ token }),
      headers: { 'Content-Type': 'application/json', Accept: 'application/json' },
      referer: this._site + '/user/public/login.html'
    })
    if (st.statusCode !== 200) throw new Error('store_token HTTP ' + st.statusCode)
    // 3) 提交表单登录（响应 Set-Cookie 写入 PTCMS_token / PTCMS_userid）
    const body = 'username=' + encodeURIComponent(account.email) +
      '&password=' + encodeURIComponent(account.password) +
      '&verificationToken=' + encodeURIComponent(token) + '&name=1'
    await this._request({
      url: this._site + '/user/public/login.html',
      method: 'POST',
      data: body,
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      referer: this._site + '/user/public/login.html'
    })
    return this._isLoggedIn()
  },

  // 尽力登录：有可用凭据就登录，全部失败不抛错（匿名仍可搜可播免费内容）
  async _ensureLogin(force) {
    if (!force && this._isLoggedIn()) return true

    // 1) 手动/WebView 注入的整段 Cookie
    const manual = String(this._config().cookie || '').trim()
    if (manual) {
      manual.split(';').forEach(pair => {
        const idx = pair.indexOf('=')
        if (idx > 0) {
          const k = pair.slice(0, idx).trim()
          if (/^(PTCMS_|PHPSESSID|__51)/.test(k)) {
            this._cookies[k] = pair.slice(idx + 1).trim()
          }
        }
      })
      if (this._isLoggedIn()) return true
    }

    // 2) 账号池逐个尝试（并发调用共享同一次登录）
    if (!this._loggingIn) {
      this._loggingIn = (async () => {
        const accounts = this._accounts()
        for (const acc of accounts) {
          try {
            if (await this._programLogin(acc)) return true
          } catch (e) { /* 换下一个账号 */ }
        }
        return false
      })().then(v => { this._loggingIn = null; return v })
        .catch(() => { this._loggingIn = null; return false })
    }
    return this._loggingIn
  },

  _logout() {
    Object.keys(this._cookies).forEach(k => {
      if (/^PTCMS_/.test(k)) delete this._cookies[k]
    })
  },

  // ── 文本工具 ─────────────────────────────────────────────────

  _decode(s) {
    return String(s || '')
      .replace(/&#(\d+);/g, (_, n) => String.fromCharCode(parseInt(n, 10)))
      .replace(/&nbsp;/g, ' ').replace(/&amp;/g, '&').replace(/&quot;/g, '"')
      .replace(/&#39;/g, "'").replace(/&lt;/g, '<').replace(/&gt;/g, '>')
  },

  _clean(s) {
    return this._decode(
      String(s || '')
        .replace(/<script[\s\S]*?<\/script>/gi, ' ')
        .replace(/<style[\s\S]*?<\/style>/gi, ' ')
        .replace(/<[^>]+>/g, ' ')
        .replace(/\s+/g, ' ')
    ).trim()
  },

  _attr(tag, name) {
    const m = String(tag || '').match(new RegExp(name + '\\s*=\\s*("([^"]*)"|\'([^\']*)\'|([^\\s>]+))', 'i'))
    return m ? this._decode(m[2] || m[3] || m[4] || '') : ''
  },

  _abs(url, base) {
    url = this._decode(String(url || '').trim())
    if (!url) return ''
    if (/^https?:\/\//i.test(url)) return url
    if (url.startsWith('//')) return 'https:' + url
    if (url[0] === '/') return this._site + url
    return String(base || this._site + '/').replace(/[#?].*$/, '').replace(/\/[^/]*$/, '/') + url
  },

  _first(s, re) {
    const m = String(s || '').match(re)
    return m ? (m[1] || '') : ''
  },

  _firstTag(s, re) {
    const m = String(s || '').match(re)
    return m ? m[0] : ''
  },

  // 作者/演播字段常带站点后缀（如 “悠兮缘梦_免费听书_13听书网”）
  _person(s) {
    return String(s || '').replace(/[_｜|].*$/, '').replace(/免费听书.*$/, '').trim()
  },

  // ── 列表解析 ─────────────────────────────────────────────────

  _toBook(anchorMatch, html, base) {
    const href = this._abs(anchorMatch[1], base)
    if (!href) return null
    // 向前后取上下文块，用于提取封面/简介/演播
    const start = Math.max(0, anchorMatch.index - 1400)
    const block = html.slice(start, anchorMatch.index + anchorMatch[0].length + 1100)
    const img = this._firstTag(block, /<img\b[^>]*>/i)
    const title = this._clean(this._attr(img, 'alt') || this._attr(anchorMatch[0], 'title') || anchorMatch[0])
      .replace(/有声小说.*$/, '').replace(/在线收听.*$/, '').trim()
    if (!title) return null
    const cover = this._abs(this._attr(img, 'data-original') || this._attr(img, 'src'), base)
    const authorRaw = this._first(block, /(?:演播|主播|作者)[：:\s]*(?:<\/span>)?(?:<[^>]*>)*\s*([^<]{1,40})/i)
    const intro = this._clean(this._first(block, /class=["'][^"']*rm-js[^"']*["'][^>]*>([\s\S]*?)<\/p>/i))
    return { bookId: href, title, cover, author: this._person(authorRaw), intro }
  },

  _parseBooks(html, base) {
    const list = []
    const seen = {}
    const re = /<a\b[^>]*href=["']([^"']*\/youshengxiaoshuo\/\d+\/?)["'][^>]*>([\s\S]*?)<\/a>/gi
    let m
    while ((m = re.exec(html)) !== null) {
      const book = this._toBook(m, html, base)
      if (!book || seen[book.bookId]) continue
      seen[book.bookId] = true
      list.push(book)
    }
    return list
  },

  // ── 书籍详情与目录 ───────────────────────────────────────────

  async _bookInfo(bookUrl) {
    const cached = this._bookCache[bookUrl]
    if (cached) return cached
    const html = await this._getHtml(bookUrl, this._site + '/')
    const h1Index = html.search(/<h1[^>]*>/i)
    const title = this._clean(this._first(html, /<h1[^>]*>([\s\S]*?)<\/h1>/i)).replace(/有声小说.*$/, '').trim()
    // 封面优先 og:image，其次页面内 /cover/ 图片，最后 h1 前最近一张图
    let cover = this._first(html, /property=["']og:image["'][^>]*content=["']([^"']+)["']/i)
    if (!cover) cover = this._first(html, /(?:data-original|src)=["'](https?:\/\/[^"']*\/cover\/[^"']+)["']/i)
    if (!cover && h1Index > 0) {
      const win = html.slice(Math.max(0, h1Index - 2500), h1Index)
      const imgs = win.match(/(?:data-original|src)=["']([^"']+)["']/gi) || []
      if (imgs.length) cover = this._abs(this._attr(imgs[imgs.length - 1], '(?:data-original|src)'), bookUrl)
    }
    const author = this._clean(this._first(html, /作者[：:](?:\s|<[^>]*>)*([^<]{1,40})/i))
    const announcer = this._clean(this._first(html, /演播[：:](?:\s|<[^>]*>)*([^<]{1,40})/i))
    const statusText = this._first(html, /状态[：:](?:\s|<[^>]*>)*([^<]{1,12})/i)
    const tocHref = this._first(html, /href=["']([^"']*\/tingdirs\/[^"']+)["']/i)
    const info = {
      title,
      cover: this._abs(cover, bookUrl),
      author: this._person(announcer || author),
      isFinished: /完结/.test(statusText),
      tocHref
    }
    if (!info.title) throw new Error('书籍页解析失败 | ' + String(html).slice(0, 120))
    this._bookCache[bookUrl] = info
    return info
  },

  _tocBase(bookUrl, tocHref) {
    if (!tocHref) throw new Error('未找到目录入口')
    let base = this._abs(tocHref, bookUrl)
    base = base.replace(/[?&]page=\d+/g, '').replace(/[?&]sort=(asc|desc)/g, '').replace(/[?&]$/, '')
    return base + (base.indexOf('?') >= 0 ? '&' : '?') + 'sort=asc&page='
  },

  _tocState(tocPrefix) {
    let st = this._tocCache[tocPrefix]
    if (!st) {
      st = { size: 0, pages: {}, total: null }
      this._tocCache[tocPrefix] = st
    }
    return st
  },

  async _tocPage(tocPrefix, state, n) {
    if (state.pages[n]) return state.pages[n]
    const html = await this._getHtml(tocPrefix + n, this._site + '/')
    const items = []
    const re = /<a\b[^>]*href=["']([^"']*\/play\/[^"']+)["'][^>]*>([\s\S]*?)<\/a>/gi
    let m
    while ((m = re.exec(html)) !== null) {
      const name = this._clean(m[2])
        .replace(/^正在播放[:：]\s*/, '')
        .replace(/(?:在线收听|在线播放)[\s\S]*$/, '')
        .replace(/[_\s-]*13听书网[\s\S]*$/, '')
        .trim()
      const url = this._abs(m[1], tocPrefix)
      if (name && url) items.push({ chapterId: url, name })
    }
    state.pages[n] = items
    return items
  },

  // ── 协议方法 ─────────────────────────────────────────────────

  async search(keyword, page = 1) {
    const kw = String(keyword || '').trim()
    const currentPage = Math.max(1, Number(page) || 1)
    if (!kw) return { list: [], page: currentPage, maxPage: 1, hasMore: false }
    await this._ensureLogin().catch(() => {})
    const doSearch = async () => this._request({
      url: this._site + '/novelsearch/search/result.html',
      method: 'POST',
      data: 'searchword=' + encodeURIComponent(kw),
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' }
    })
    let r = await doSearch()
    // 挑战页可能出现在任何状态码上，先过挑战再判状态
    if (this._pass51(String(r.data || ''))) {
      r = await doSearch()
    }
    if (r.statusCode < 200 || r.statusCode >= 300) {
      throw new Error('搜索 HTTP ' + r.statusCode)
    }
    return { list: this._parseBooks(String(r.data || ''), this._site), page: currentPage, maxPage: 1, hasMore: false }
  },

  async getChapters(bookId, page = 1, pageSize = 30) {
    const safePage = Math.max(1, Number(page) || 1)
    const size = Math.max(1, Math.min(Number(pageSize) || 30, 100))
    await this._ensureLogin().catch(() => {})
    const bookUrl = String(bookId)

    const info = await this._bookInfo(bookUrl)
    const tocPrefix = this._tocBase(bookUrl, info.tocHref)
    const state = this._tocState(tocPrefix)

    // 首次探测站点真实分页大小（一般 60/页，按实际为准）
    if (!state.size) {
      const first = await this._tocPage(tocPrefix, state, 1)
      state.size = Math.max(1, first.length)
      if (!first.length) {
        return {
          info: { title: info.title, cover: info.cover, author: info.author, trackCount: 0, isFinished: info.isFinished },
          list: [], page: safePage, maxPage: 1, hasMore: false
        }
      }
    }

    // App 页窗口 → 站点页窗口换算（支持跨站点页取满一页）
    const startIdx = (safePage - 1) * size
    let cur = Math.floor(startIdx / state.size) + 1
    let pos = startIdx - (cur - 1) * state.size
    const out = []
    let guard = 0
    while (out.length < size && guard < 50) {
      guard++
      const items = await this._tocPage(tocPrefix, state, cur)
      if (!items.length) {
        state.total = (cur - 1) * state.size
        break
      }
      if (items.length < state.size) {
        state.total = (cur - 1) * state.size + items.length
      }
      if (pos >= items.length) {
        if (items.length < state.size || state.total !== null) break
        cur++
        pos = 0
        continue
      }
      const take = Math.min(size - out.length, items.length - pos)
      for (let i = 0; i < take; i++) {
        out.push({ chapterId: items[pos + i].chapterId, index: startIdx + out.length + 1, name: items[pos + i].name })
      }
      pos = 0
      cur++
    }

    const endReached = state.total !== null
    const covered = startIdx + out.length
    const hasMore = endReached ? covered < state.total : out.length >= size
    const maxPage = endReached ? Math.max(1, Math.ceil(state.total / size)) : (hasMore ? safePage + 1 : safePage)

    return {
      info: {
        title: info.title,
        cover: info.cover,
        author: info.author,
        trackCount: endReached ? state.total : 0,
        isFinished: info.isFinished
      },
      list: out,
      page: safePage,
      maxPage,
      hasMore
    }
  },

  // ── 播放解析 ─────────────────────────────────────────────────

  // sp 头：对 _c 每个字符按乱序表移位 +3，再前后各插入一个随机表内字符
  _makeSp(sc) {
    const table = this._spTable
    let out = ''
    for (const ch of String(sc || '')) {
      const idx = table.indexOf(ch)
      const mid = idx >= 0 ? table[(idx + 3) % table.length] : ch
      out += table[Math.floor(Math.random() * table.length)] + mid + table[Math.floor(Math.random() * table.length)]
    }
    return out
  },

  async _resolveAudio(playUrl, isRetry) {
    const html = await this._getHtml(playUrl, this._site + '/')
    const nid = this._first(html, /<meta[^>]*name=["']_b["'][^>]*content=["']([^"']*)["']/i)
    const cid = this._first(html, /<meta[^>]*name=["']_p["'][^>]*content=["']([^"']*)["']/i)
    const sc = this._first(html, /<meta[^>]*name=["']_c["'][^>]*content=["']([^"']*)["']/i)
    const sort = this._first(html, /<meta[^>]*name=["']_d["'][^>]*content=["']([^"']*)["']/i) || 'read'
    if (!nid || !cid || !sc) {
      throw new Error('章节页缺少播放参数 | ' + html.slice(0, 120))
    }

    const r = await this._request({
      url: this._site + '/api/mapi/play',
      method: 'POST',
      data: 'nid=' + encodeURIComponent(nid) + '&cid=' + encodeURIComponent(cid) + '&sort=' + encodeURIComponent(sort),
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
        Accept: 'application/json, text/javascript, */*; q=0.01',
        'X-Requested-With': 'XMLHttpRequest',
        sc,
        sp: this._makeSp(sc)
      },
      referer: playUrl
    })

    if (r.statusCode < 200 || r.statusCode >= 300) {
      const hint = r.statusCode === 429 ? '（站点限流，已自动等待重试仍失败，请稍后再试）' : ''
      throw new Error('播放接口 HTTP ' + r.statusCode + hint)
    }

    let json = r.data
    if (typeof json === 'string') {
      try { json = JSON.parse(json) } catch (e) { json = null }
    }
    const status = Number(json && json.status)
    const msg = String((json && json.msg) || '')
    let url = String((json && json.url) || '')
    if (url.startsWith('//')) url = 'https:' + url
    else if (url.startsWith('/')) url = this._site + url

    if (status === 200 && /^https?:\/\//i.test(url)) return url

    // 需要登录 / 参数过期：强制重新认证后由外层重试一次
    if (!isRetry) {
      if (/登录|请先|会员|vip|付费/i.test(msg)) {
        await this._ensureLogin(true)
        const err = new Error('需要登录：' + msg)
        err.retryAuth = true
        throw err
      }
      if (status === 405 || /参数错误|刷新/i.test(msg)) {
        const err = new Error('播放参数已过期：' + msg)
        err.retryAuth = true
        throw err
      }
    }
    throw new Error('该章节暂无音频(status=' + status + ')' + (msg ? '：' + msg : ''))
  },

  // 播放直链短 TTL 缓存：播放器错误恢复与自动缓存重叠时避免重复解析
  _audioTtlMs() { return 5 * 60 * 1000 },

  _cachedAudio(playUrl) {
    const hit = this._audioCache[playUrl]
    if (hit && Date.now() - hit.at < this._audioTtlMs()) return hit.url
    if (hit) delete this._audioCache[playUrl]
    return ''
  },

  _storeAudio(playUrl, url) {
    const now = Date.now()
    this._audioCache[playUrl] = { url, at: now }
    // 顺手清理过期项，防止长期驻留
    const keys = Object.keys(this._audioCache)
    if (keys.length > 40) {
      for (const k of keys) {
        if (now - this._audioCache[k].at >= this._audioTtlMs()) delete this._audioCache[k]
      }
    }
  },

  async getAudioUrl(chapterId) {
    const playUrl = this._abs(String(chapterId || ''))
    if (!/\/play\//.test(playUrl)) throw new Error('无效的章节地址: ' + String(chapterId).slice(0, 80))

    const cached = this._cachedAudio(playUrl)
    if (cached) return cached

    await this._ensureLogin().catch(() => {})
    let url = ''
    try {
      url = await this._resolveAudio(playUrl, false)
    } catch (e) {
      if (e && e.retryAuth) {
        this._logout()
        url = await this._resolveAudio(playUrl, true)
      } else {
        throw e
      }
    }
    this._storeAudio(playUrl, url)
    return url
  }
})
