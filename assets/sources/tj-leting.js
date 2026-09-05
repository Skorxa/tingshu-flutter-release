// 乐听网（www.leting.vip · PTCMS 架构，直连版）
// 链路：搜索 POST /novelsearch/search/result.html（www）
//       目录 书籍页 a.dirurl → /bookdir/*.html?page=N&sort=asc（站点固定约50条/页，源内做窗口换算）
//       播放 移动版章节页 meta(_b/_p/_n/_c) → POST m/api/act/readplay
//            body={"encodedData": base64(urlencode(JSON({novelid,chapterid,preinfoid,type:3,salt})))}
// 盾点：目录/章节页返回挑战页（var reversed），解码后按脚本里的 document.cookie 赋值动态种 Cookie
//       （本站 Cookie 名为 pt_guid/ptcms_guard_retry，与 13 听的 __51guid__ 不同，故不能硬编码）。
// 音频：站点对部分海外/受限网络返回占位地址（/audio/.m4a 无文件名），此时回退可选 Worker 代理；
//       国内网络直连即得真实直链。登录为可选项（免费内容匿名即可播）。
({
  id: 'tingshu-json-leting',
  version: 1,
  name: '乐听网',
  apiVersion: 1,

  login: {
    url: 'https://www.leting.vip/user/public/login.html',
    configKey: 'cookie'
  },

  configFields: [
    {
      key: 'accounts',
      label: '账号池',
      type: 'account_list',
      hint: '可选：填写站内注册的邮箱和密码，音源会自动登录；免费内容无需登录',
      required: false
    },
    {
      key: 'cookie',
      label: 'Cookie',
      type: 'textarea',
      hint: '备选：长按本音源“登录”会自动写入；也可手动粘贴网页 Cookie',
      required: false
    },
    {
      key: 'worker',
      label: '备用音频代理',
      type: 'text',
      hint: '可选：直连被站点限制时的 Worker 代理地址，留空则不启用兜底',
      required: false
    },
    {
      key: 'workerPwd',
      label: '代理密码',
      type: 'text',
      hint: '备用音频代理的 pwd 参数',
      required: false
    }
  ],

  _site: 'https://www.leting.vip',
  _msite: 'https://m.leting.vip',
  _uaDesk: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36',
  _uaMob: 'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Mobile Safari/537.36',
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

  _gate() {
    const prev = this._queue || Promise.resolve()
    const job = prev.then(() => {
      const wait = Math.max(0, this._lastReqAt + 400 - Date.now())
      return this._sleep(wait + Math.floor(Math.random() * 120))
    }).then(() => { this._lastReqAt = Date.now() })
    this._queue = job.catch(() => {})
    return job
  },

  // ── 基础设施：分主机 Cookie + 人机验证盾 ─────────────────────

  _hostOf(url) {
    const m = String(url || '').match(/^https?:\/\/([^/]+)/i)
    return m ? m[1].toLowerCase() : 'www.leting.vip'
  },

  _jar(host) {
    if (!this._cookies[host]) this._cookies[host] = {}
    return this._cookies[host]
  },

  _cookieHeader(host) {
    const jar = this._jar(host)
    return Object.keys(jar).map(k => k + '=' + jar[k]).join('; ')
  },

  _remember(header, host) {
    const raw = header && (header['set-cookie'] || header['Set-Cookie'])
    const list = Array.isArray(raw) ? raw : (raw ? [String(raw)] : [])
    if (!list.length) return
    const jar = this._jar(host)
    for (const line of list) {
      const pair = String(line).split(';')[0]
      const idx = pair.indexOf('=')
      if (idx > 0) jar[pair.slice(0, idx).trim()] = pair.slice(idx + 1).trim()
    }
  },

  // 响应若为挑战页：base64(反转) 解码后，解析脚本中全部 document.cookie 赋值并种入对应主机
  _guardPass(html, host) {
    const m = String(html).match(/var\s+reversed\s*=\s*"([\s\S]*?)"/)
    if (!m) return false
    let code = ''
    try {
      code = atob(m[1].replace(/\s+/g, '').split('').reverse().join(''))
    } catch (e) { return false }
    const vars = {}
    let vm
    const varRe = /var\s+(\w+)\s*=\s*(?:'([^']*)'|([0-9]+))/g
    while ((vm = varRe.exec(code))) vars[vm[1]] = vm[2] !== undefined ? vm[2] : vm[3]
    const jar = this._jar(host)
    let cm
    const ckRe = /['"](\w+)=['"]\s*\+\s*(?:encodeURIComponent\(\s*(\w+)\s*\)|(\w+))/g
    let applied = 0
    while ((cm = ckRe.exec(code))) {
      const name = cm[1]
      const rawKey = cm[2] !== undefined ? cm[2] : cm[3]
      if (!(rawKey in vars)) continue
      jar[name] = cm[2] !== undefined ? encodeURIComponent(vars[rawKey]) : vars[rawKey]
      applied++
    }
    // 兼容旧版 __51guid__ 变体：脚本只给了 token 没匹配到赋值时手动补
    if (!applied && vars.token) {
      jar['__51guid__'] = encodeURIComponent(vars.token)
      if (vars.retry !== undefined) jar['__51refresh__guid'] = vars.retry
      applied++
    }
    return applied > 0
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
    const host = this._hostOf(o.url)
    const origin = o.url.replace(/^(https?:\/\/[^/]+).*$/i, '$1')
    let last = { statusCode: 0, data: null, header: {} }

    for (let attempt = 0; attempt < 3; attempt++) {
      const headers = Object.assign({
        'User-Agent': o.mobile ? this._uaMob : this._uaDesk,
        Referer: o.referer || (origin + '/')
      }, o.headers || {})
      if (method !== 'GET') headers.Origin = headers.Origin || origin
      const cookie = this._cookieHeader(host)
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
      this._remember(r.header, host)
      last = r

      if (r.statusCode >= 200 && r.statusCode < 300) break
      if ((r.statusCode === 429 || r.statusCode === 503) && attempt < 2) {
        await this._sleep(this._retryAfterMs(r.header) || (attempt === 0 ? 1500 : 4000))
        continue
      }
      break
    }
    return last
  },

  // GET 页面：自动过人机验证（挑战可能出现在任何状态码上）
  async _getHtml(url, referer, mobile) {
    const host = this._hostOf(url)
    for (let i = 0; i < 3; i++) {
      const r = await this._request({ url, referer, mobile })
      const html = String(r.data || '')
      if (!html.match(/var\s+reversed\s*=/)) {
        if (r.statusCode < 200 || r.statusCode >= 300) {
          throw new Error('HTTP ' + r.statusCode + ' | ' + url)
        }
        return html
      }
      if (!this._guardPass(html, host)) break
    }
    throw new Error('页面持续返回人机验证 | ' + url)
  },

  // ── 登录：账号池程序化登录 / WebView Cookie 注入（可选项）──

  _isLoggedIn() {
    const jar = this._jar(this._hostOf(this._site))
    return !!(jar.PTCMS_token || jar.PTCMS_userid)
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
    await this._getHtml(this._site + '/user/public/login.html', this._site + '/')
    const token = String(Date.now()) + String(Math.floor(Math.random() * 1e8))
    const st = await this._request({
      url: this._site + '/user/public/store_token.html',
      method: 'POST',
      data: JSON.stringify({ token }),
      headers: { 'Content-Type': 'application/json', Accept: 'application/json' },
      referer: this._site + '/user/public/login.html'
    })
    if (st.statusCode !== 200) throw new Error('store_token HTTP ' + st.statusCode)
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

  async _ensureLogin(force) {
    if (!force && this._isLoggedIn()) return true

    const manual = String(this._config().cookie || '').trim()
    if (manual) {
      ['www.leting.vip', 'm.leting.vip'].forEach(h => {
        const jar = this._jar(h)
        manual.split(';').forEach(pair => {
          const idx = pair.indexOf('=')
          if (idx > 0) {
            const k = pair.slice(0, idx).trim()
            if (/^(PTCMS_|PHPSESSID|__51|pt_)/.test(k)) jar[k] = pair.slice(idx + 1).trim()
          }
        })
      })
      if (this._isLoggedIn()) return true
    }

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
    const jar = this._jar(this._hostOf(this._site))
    Object.keys(jar).forEach(k => {
      if (/^PTCMS_/.test(k)) delete jar[k]
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

  _person(s) {
    return String(s || '').replace(/[_｜|].*$/, '').replace(/播讲作品.*$/, '').replace(/免费.*$/, '').trim()
  },

  _b64enc(str) {
    if (typeof btoa === 'function') return btoa(str)
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
    let out = ''
    for (let i = 0; i < str.length; i += 3) {
      const b1 = str.charCodeAt(i)
      const b2 = str.charCodeAt(i + 1)
      const b3 = str.charCodeAt(i + 2)
      out += chars[b1 >> 2] + chars[((b1 & 3) << 4) | ((b2 || 0) >> 4)]
      out += isNaN(b2) ? '=' : chars[((b2 & 15) << 2) | ((b3 || 0) >> 6)]
      out += isNaN(b3) ? '=' : chars[b3 & 63]
    }
    return out
  },

  // ── 列表解析（搜索 / 分类共用 li.list-imgbox 结构）──────────

  _parseBooks(html, base) {
    const out = []
    const seen = {}
    const re = /<li[^>]*>\s*<div class=["']list-imgbox["'][\s\S]*?<\/li>/gi
    let m
    while ((m = re.exec(html)) !== null) {
      const block = m[0]
      const href = this._first(block, /href=["']([^"']*\/book\/\d+\.html)["']/i)
      if (!href) continue
      const abs = this._abs(href, base)
      if (seen[abs]) continue
      const dtTitle = this._first(block, /class=["']list-book-dt["'][^>]*>\s*<a[^>]*>([\s\S]*?)<\/a>/i)
      const title = this._clean(dtTitle ||
        this._first(block, /title=["']([^"']+)["']/i)).replace(/有声小说.*$/, '').trim()
      if (!title) continue
      const imgTag = this._firstTag(block, /<img\b[^>]*>/i)
      const cover = this._abs(this._attr(imgTag, 'data-original') || this._attr(imgTag, 'src'), base)
      const intro = this._clean(this._first(block, /class=["']list-book-des["'][^>]*>([\s\S]*?)<\/dd>/i))
      const authors = []
      const are = /<a\b[^>]*href=["'][^"']*\/boyin\/\d+\.html["'][^>]*>([\s\S]*?)<\/a>/gi
      let am
      while ((am = are.exec(block))) {
        const nm = this._person(this._clean(am[1]))
        if (nm && authors.indexOf(nm) < 0) authors.push(nm)
      }
      seen[abs] = true
      out.push({ bookId: abs, title, cover, author: authors.join('、'), intro })
    }
    return out
  },

  // ── 书籍详情与目录 ───────────────────────────────────────────

  async _bookInfo(bookUrl) {
    const cached = this._bookCache[bookUrl]
    if (cached) return cached
    const html = await this._getHtml(bookUrl, this._site + '/')
    const title = this._clean(this._first(html, /<h1[^>]*>([\s\S]*?)<\/h1>/i)).replace(/有声小说.*$/, '').trim()
    let cover = this._first(html, /property=["']og:image["'][^>]*content=["']([^"']+)["']/i)
    if (!cover) cover = this._first(html, /(?:data-original|src)=["'](\/public\/cover\/[^"']+)["']/i)
    const isFinished = /class="icon state end"/.test(html) || /<i[^>]*>[^<]*完结/.test(html)
    const intro = this._clean(this._first(html, /class=["']book-des["'][^>]*>([\s\S]*?)<\/div>/i))
    // 演播：定位“演播：”后最近的一段 boyin 锚点
    let announcer = ''
    const yi = html.indexOf('演播')
    if (yi >= 0) {
      const win = html.slice(yi, yi + 900)
      const names = []
      const are = /<a\b[^>]*href=["'][^"']*\/boyin\/\d+\.html["'][^>]*>([\s\S]*?)<\/a>/gi
      let am
      while ((am = are.exec(win))) {
        const nm = this._person(this._clean(am[1]))
        if (nm && names.indexOf(nm) < 0 && names.length < 6) names.push(nm)
      }
      announcer = names.join('、')
    }
    if (!announcer) {
      announcer = this._clean(this._first(html, /作者[：:](?:\s|<[^>]*>)*([^<]{1,40})/i))
    }
    const tocHref = this._first(html, /href=["']([^"']*\/bookdir\/[^"']+)["']/i)
    const info = {
      title,
      cover: this._abs(cover, bookUrl),
      author: announcer,
      isFinished,
      intro,
      tocHref
    }
    if (!info.title) throw new Error('书籍页解析失败 | ' + String(html).slice(0, 120))
    this._bookCache[bookUrl] = info
    return info
  },

  _tocBase(bookUrl, tocHref) {
    if (!tocHref) throw new Error('未找到目录入口')
    let base = this._abs(tocHref, bookUrl)
    base = base.replace(/[?&]page=\d+/g, '').replace(/[?&]sort=(asc|desc)/g, '').replace(/[?&]+$/, '')
    return base + '?sort=asc&page='
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
    // 章节列表在 id="playlist" 区块内，href 为单引号
    const pi = html.indexOf('id="playlist"')
    const seg = pi >= 0 ? html.slice(pi, pi + 500000) : html
    const items = []
    const seen = {}
    let re = /<a\b[^>]*href='([^']*\/tingshu\/\d+\/\d+\.html)'[^>]*>([\s\S]*?)<\/a>/gi
    let m
    while ((m = re.exec(seg)) !== null) {
      const name = this._clean(m[2]).replace(/^正在播放[:：]\s*/, '').trim()
      const url = this._abs(m[1], tocPrefix)
      if (name && url && !seen[url]) {
        seen[url] = true
        items.push({ chapterId: url, name })
      }
    }
    if (!items.length) {
      re = /<a\b[^>]*href=["']([^"']*\/tingshu\/\d+\/\d+\.html)["'][^>]*>([\s\S]*?)<\/a>/gi
      while ((m = re.exec(seg)) !== null) {
        const name = this._clean(m[2]).replace(/^正在播放[:：]\s*/, '').trim()
        const url = this._abs(m[1], tocPrefix)
        if (name && url && !seen[url]) {
          seen[url] = true
          items.push({ chapterId: url, name })
        }
      }
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
    if (String(r.data || '').match(/var\s+reversed\s*=/) && this._guardPass(String(r.data || ''), this._hostOf(this._site))) {
      r = await doSearch()
    }
    if (r.statusCode < 200 || r.statusCode >= 300) {
      throw new Error('搜索 HTTP ' + r.statusCode)
    }
    return { list: this._parseBooks(String(r.data || ''), this._site), page: currentPage, maxPage: 1, hasMore: false }
  },

  async discover() {
    const cats = [
      ['玄幻奇幻', 'xhqh'], ['武侠仙侠', 'wxxx'], ['悬疑推理', 'xytl'],
      ['历史军事', 'lsjs'], ['影视原著', 'ysyz'], ['儿童频道', 'ertong']
    ]
    const loaded = new Array(cats.length)
    let next = 0
    const worker = async () => {
      while (next < cats.length) {
        const i = next++
        try {
          const html = await this._getHtml(this._site + '/book/' + cats[i][1] + '/lastupdate.html', this._site + '/')
          const list = this._parseBooks(html, this._site).slice(0, 12)
          if (list.length) loaded[i] = { title: cats[i][0], list }
        } catch (e) { /* 单个分区失败不影响其他分区 */ }
      }
    }
    await Promise.all([worker(), worker()])
    return { sections: loaded.filter(Boolean) }
  },

  async getChapters(bookId, page = 1, pageSize = 30) {
    const safePage = Math.max(1, Number(page) || 1)
    const size = Math.max(1, Math.min(Number(pageSize) || 30, 100))
    await this._ensureLogin().catch(() => {})
    const bookUrl = String(bookId)

    const info = await this._bookInfo(bookUrl)
    const tocPrefix = this._tocBase(bookUrl, info.tocHref)

    // 目录入口哈希会变化：dir 变了就重置缓存状态
    let state = this._tocCache[bookUrl]
    if (!state || state.dir !== tocPrefix) {
      state = { dir: tocPrefix, size: 0, pages: {}, total: null }
      this._tocCache[bookUrl] = state
    }

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

    const trackCount = state.total !== null ? state.total : startIdx + out.length
    const maxPage = Math.max(1, Math.ceil(trackCount / size))
    return {
      info: {
        title: info.title, cover: info.cover, author: info.author,
        intro: info.intro, trackCount, isFinished: info.isFinished
      },
      list: out, page: safePage, maxPage, hasMore: safePage < maxPage && out.length > 0
    }
  },

  // ── 播放解析：移动版章节页 meta → readplay 接口 ─────────────

  _isStubUrl(u) {
    // 占位地址形如 https://mp3x.ting13.top/audio/.m4a?sign=...（无文件名）
    return /\/audio\/\.(?:mp3|m4a|aac)\?/i.test(String(u || ''))
  },

  async _workerAudio(path) {
    const cfg = this._config()
    const worker = String(cfg.worker || '').trim().replace(/\/+$/, '')
    if (!/^https?:\/\//i.test(worker)) return ''
    const pwd = String(cfg.workerPwd == null ? '' : cfg.workerPwd).trim() || 'admin123'
    const host = worker.replace(/^https?:\/\//i, '').replace(/\/.*$/, '')
    const api = worker + '/leting/audio?episode=' + encodeURIComponent(path) +
      '&pwd=' + encodeURIComponent(pwd) + '&host=' + encodeURIComponent(host)
    try {
      const r = await this._request({ url: api, referer: this._site + '/', timeout: 15000 })
      if (r.statusCode < 200 || r.statusCode >= 300) return ''
      let j = r.data
      if (typeof j === 'string') { try { j = JSON.parse(j) } catch (e) { j = null } }
      const d = (j && (j.data || j)) || {}
      const u = String(d.url || d.proxyUrl || '')
      return /^https?:\/\//i.test(u) && !this._isStubUrl(u) ? u : ''
    } catch (e) { return '' }
  },

  async _resolveDirect(path, isRetry) {
    const playUrl = this._msite + path
    const html = await this._getHtml(playUrl, this._msite + '/', true)
    const meta = name => this._first(html, new RegExp('<meta[^>]*name=["\']' + name + '["\'][^>]*content=["\']([^"\']*)["\']', 'i'))
    const nid = meta('_b')
    const cid = meta('_p')
    const pre = meta('_n') || '0'
    const salt = meta('_c')
    if (!nid || !cid || !salt) {
      throw new Error('章节页缺少播放参数 | ' + html.slice(0, 120))
    }

    const payload = JSON.stringify({ novelid: nid, chapterid: cid, preinfoid: pre, type: 3, salt: salt })
    const r = await this._request({
      url: this._msite + '/api/act/readplay',
      method: 'POST',
      data: JSON.stringify({ encodedData: this._b64enc(encodeURIComponent(payload)) }),
      headers: {
        'Content-Type': 'application/json',
        Accept: 'application/json, text/javascript, */*; q=0.01',
        'X-Requested-With': 'XMLHttpRequest'
      },
      referer: playUrl,
      mobile: true
    })

    if (r.statusCode < 200 || r.statusCode >= 300) {
      const hint = r.statusCode === 429 ? '（站点限流，已自动等待重试仍失败，请稍后再试）' : ''
      throw new Error('播放接口 HTTP ' + r.statusCode + hint)
    }

    let json = r.data
    if (typeof json === 'string') {
      try { json = JSON.parse(json) } catch (e) { json = null }
    }
    const msg = String((json && json.msg) || '')
    let url = String((json && json.audioUrl) || '')
    if (url.startsWith('//')) url = 'https:' + url
    else if (url.startsWith('/')) url = this._msite + url

    if (/^https?:\/\//i.test(url)) {
      if (!this._isStubUrl(url)) return url
      // 占位地址：站点对当前网络限制播放 → 尝试备用代理
      const fb = await this._workerAudio(path)
      if (fb) return fb
      throw new Error('站点对当前网络返回占位音频地址（疑似地区/网络限制），且未配置可用备用代理')
    }

    if (!isRetry && /登录|请先|会员|vip|付费/i.test(msg)) {
      await this._ensureLogin(true)
      const err = new Error('需要登录：' + msg)
      err.retryAuth = true
      throw err
    }
    throw new Error('该章节暂无音频' + (msg ? '：' + msg : ''))
  },

  // 播放直链短 TTL 缓存
  _audioTtlMs() { return 5 * 60 * 1000 },

  _cachedAudio(key) {
    const hit = this._audioCache[key]
    if (hit && Date.now() - hit.at < this._audioTtlMs()) return hit.url
    if (hit) delete this._audioCache[key]
    return ''
  },

  _storeAudio(key, url) {
    const now = Date.now()
    this._audioCache[key] = { url, at: now }
    const keys = Object.keys(this._audioCache)
    if (keys.length > 40) {
      for (const k of keys) {
        if (now - this._audioCache[k].at >= this._audioTtlMs()) delete this._audioCache[k]
      }
    }
  },

  async getAudioUrl(chapterId) {
    const path = String(chapterId || '').replace(/^https?:\/\/[^/]+/i, '')
    if (!/^\/tingshu\/\d+\/\d+\.html/i.test(path)) {
      throw new Error('无效的章节地址: ' + String(chapterId).slice(0, 80))
    }

    const cached = this._cachedAudio(path)
    if (cached) return cached

    await this._ensureLogin().catch(() => {})
    let url = ''
    try {
      url = await this._resolveDirect(path, false)
    } catch (e) {
      if (e && e.retryAuth) {
        this._logout()
        url = await this._resolveDirect(path, true)
      } else {
        throw e
      }
    }
    this._storeAudio(path, url)
    return url
  }
})