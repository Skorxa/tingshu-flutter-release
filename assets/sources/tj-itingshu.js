// 爱听书（www.itingshu.net · PTCMS 架构）
// 搜索：POST /novelsearch/search/result.html
// 目录：/youshengxiaoshuo/{id}/，章节：/play/{book}_{vol}_{chapter}.html
// 播放：章节页 meta(_b/_p/_c/_d) → POST /api/mapi/play（sc/sp）
// 部分页面有 51 challenge，Cookie 名按解码脚本动态解析。
({
  id: 'tingshu-json-itingshu',
  name: '爱听书网',
  apiVersion: 1,
  login: { url: 'https://www.itingshu.net/user/public/login.html', configKey: 'cookie' },
  configFields: [
    { key: 'accounts', label: '账号池', type: 'account_list', hint: '填写站内账号和密码，音源会自动登录；免费内容无需登录', required: false },
    { key: 'cookie', label: 'Cookie', type: 'textarea', hint: '备选：长按本音源“登录”后自动写入，也可手动粘贴 Cookie', required: false }
  ],
  _site: 'https://www.itingshu.net',
  _cookies: {}, _bookCache: {}, _pageCache: {}, _audioCache: {}, _queue: null, _lastReqAt: 0,
  _table: 'PXhw7U1B0a9kQDKZsTjIASmOeNzxYG4CHo1JyRfg2b8FLpEvr3FtVnlqMidu6c',
  _ua: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36',

  _sleep(ms) { return new Promise(r => setTimeout(r, ms)) },
  _gate() {
    const prev = this._queue || Promise.resolve()
    const job = prev.then(() => this._sleep(Math.max(0, this._lastReqAt + 400 - Date.now()) + Math.floor(Math.random() * 120))).then(() => { this._lastReqAt = Date.now() })
    this._queue = job.catch(() => {})
    return job
  },
  _host(url) { const m = String(url).match(/^https?:\/\/([^/]+)/i); return m ? m[1].toLowerCase() : 'www.itingshu.net' },
  _jar(host) { if (!this._cookies[host]) this._cookies[host] = {}; return this._cookies[host] },
  _cookieHeader(host) { const j = this._jar(host); return Object.keys(j).map(k => k + '=' + j[k]).join('; ') },
  _remember(header, host) {
    const raw = header && (header['set-cookie'] || header['Set-Cookie'])
    const list = Array.isArray(raw) ? raw : (raw ? [raw] : [])
    const j = this._jar(host)
    for (const line of list) { const p = String(line).split(';')[0]; const i = p.indexOf('='); if (i > 0) j[p.slice(0, i).trim()] = p.slice(i + 1).trim() }
  },
  _guardPass(html, host) {
    const m = String(html).match(/var\s+reversed\s*=\s*"([\s\S]*?)"/); if (!m) return false
    let code; try { code = atob(m[1].replace(/\s+/g, '').split('').reverse().join('')) } catch (e) { return false }
    const vars = {}; let v
    const vr = /var\s+(\w+)\s*=\s*(?:'([^']*)'|([0-9]+))/g
    while ((v = vr.exec(code))) vars[v[1]] = v[2] !== undefined ? v[2] : v[3]
    const j = this._jar(host); let c; let n = 0
    const cr = /['"](\w+)=['"]\s*\+\s*(?:encodeURIComponent\(\s*(\w+)\s*\)|(\w+))/g
    while ((c = cr.exec(code))) { const key = c[2] !== undefined ? c[2] : c[3]; if (!(key in vars)) continue; j[c[1]] = c[2] !== undefined ? encodeURIComponent(vars[key]) : vars[key]; n++ }
    if (!n && vars.token) { j.__51guid__ = encodeURIComponent(vars.token); j.__51refresh__guid = vars.retry || '1'; n++ }
    return n > 0
  },
  _retryAfter(header) { const x = header && (header['retry-after'] || header['Retry-After']); const n = Number(Array.isArray(x) ? x[0] : x); return isFinite(n) && n > 0 ? Math.min(15000, Math.max(1000, n * 1000)) : 0 },
  async _request(o) {
    o = o || {}; const host = this._host(o.url); let last = { statusCode: 0, data: null, header: {} }
    for (let a = 0; a < 3; a++) {
      const headers = Object.assign({ 'User-Agent': this._ua, Referer: o.referer || this._site + '/' }, o.headers || {})
      const cookie = this._cookieHeader(host); if (cookie) headers.Cookie = cookie
      await this._gate()
      let r
      try {
        r = await new Promise((resolve, reject) => uni.request({ url: o.url, method: (o.method || 'GET').toUpperCase(), data: o.data, header: headers, timeout: o.timeout || 20000, success: x => resolve({ statusCode: x.statusCode || 0, data: x.data, header: x.header || {} }), fail: e => reject(new Error(e.errMsg || '网络失败')) }))
      } catch (e) {
        // Dio/底层连接被站点 reset 时也退避重试，避免把瞬时连接错误直接暴露给调试页
        if (a < 2) { await this._sleep(a ? 3000 : 1200); continue }
        throw e
      }
      this._remember(r.header, host); last = r
      if (r.statusCode >= 200 && r.statusCode < 300) break
      if ((r.statusCode === 429 || r.statusCode === 503) && a < 2) { await this._sleep(this._retryAfter(r.header) || (a ? 4000 : 1500)); continue }
      break
    }
    return last
  },
  async _html(url, referer) {
    const host = this._host(url)
    for (let i = 0; i < 4; i++) {
      const r = await this._request({ url, referer })
      const h = String(r.data || '')
      if (/var\s+reversed\s*=/.test(h)) {
        if (this._guardPass(h, host)) continue
        throw new Error('页面验证解析失败 | ' + url)
      }
      if (r.statusCode >= 200 && r.statusCode < 300) return h
      // 403 常由过期验证 Cookie 触发：清理站点验证 Cookie，先访问首页重新建立会话再重试
      if (r.statusCode === 403 && i < 3) {
        const jar = this._jar(host)
        Object.keys(jar).forEach(k => { if (/^(__51|pt_|visitor_id|PHPSESSID)/i.test(k)) delete jar[k] })
        await this._sleep(800 + i * 700)
        if (url !== this._site + '/') {
          const home = await this._request({ url: this._site + '/', referer: this._site + '/' })
          const homeHtml = String(home.data || '')
          if (/var\s+reversed\s*=/.test(homeHtml)) this._guardPass(homeHtml, host)
        }
        continue
      }
      throw new Error('HTTP ' + r.statusCode + ' | ' + url)
    }
    throw new Error('页面持续返回 403/人机验证 | ' + url)
  },
  _isLoggedIn() { const j = this._jar(this._host(this._site)); return !!(j.PTCMS_token || j.PTCMS_userid) },
  _config() { return this.config || uni.getStorageSync('sourceConfig') || {} },
  _accounts() {
    let raw = this._config().accounts
    if (typeof raw === 'string') { try { raw = raw.trim() ? JSON.parse(raw) : [] } catch (e) { return [] } }
    const arr = Array.isArray(raw) ? raw : (raw && Array.isArray(raw.list) ? raw.list : [])
    return arr.map(x => ({ email: String(x && (x.email || x.account || x.username) || '').trim(), password: String(x && x.password || '') })).filter(x => x.email && x.password)
  },
  async _programLogin(account) {
    await this._html(this._site + '/user/public/login.html', this._site + '/').catch(() => {})
    const token = String(Date.now()) + String(Math.floor(Math.random() * 1e8))
    const st = await this._request({ url: this._site + '/user/public/store_token.html', method: 'POST', data: JSON.stringify({ token }), headers: { 'Content-Type': 'application/json', Accept: 'application/json' }, referer: this._site + '/user/public/login.html' })
    if (st.statusCode < 200 || st.statusCode >= 300) return false
    const body = 'username=' + encodeURIComponent(account.email) + '&password=' + encodeURIComponent(account.password) + '&verificationToken=' + encodeURIComponent(token) + '&name=1'
    let loginRes = await this._request({ url: this._site + '/user/public/login.html', method: 'POST', data: body, headers: { 'Content-Type': 'application/x-www-form-urlencoded', Accept: 'text/html, */*; q=0.01' }, referer: this._site + '/user/public/login.html' })
    // 登录 POST 也可能被 51 盾拦截；先写入挑战 Cookie，再原样重提一次
    const loginHtml = String(loginRes.data || '')
    if (/var\s+reversed\s*=/.test(loginHtml) && this._guardPass(loginHtml, this._host(this._site))) {
      loginRes = await this._request({ url: this._site + '/user/public/login.html', method: 'POST', data: body, headers: { 'Content-Type': 'application/x-www-form-urlencoded', Accept: 'text/html, */*; q=0.01' }, referer: this._site + '/user/public/login.html' })
    }
    return this._isLoggedIn()
  },
  async _ensureLogin(force) {
    if (!force && this._isLoggedIn()) return true
    const manual = String(this._config().cookie || '').trim()
    if (manual) { const j = this._jar(this._host(this._site)); manual.split(';').forEach(p => { const i = p.indexOf('='); if (i > 0) { const k = p.slice(0, i).trim(); if (/^(PTCMS_|PHPSESSID|__51)/.test(k)) j[k] = p.slice(i + 1).trim() } }); if (this._isLoggedIn()) return true }
    if (!this._loggingIn) this._loggingIn = (async () => { for (const a of this._accounts()) { try { if (await this._programLogin(a)) return true } catch (e) {} } return false })().then(x => { this._loggingIn = null; return x }).catch(() => { this._loggingIn = null; return false })
    return this._loggingIn
  },
  _decode(s) { return String(s || '').replace(/&#(\d+);/g, (_, n) => String.fromCharCode(parseInt(n, 10))).replace(/&nbsp;/g, ' ').replace(/&amp;/g, '&').replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&lt;/g, '<').replace(/&gt;/g, '>') },
  _clean(s) { return this._decode(String(s || '').replace(/<script[\s\S]*?<\/script>/gi, ' ').replace(/<style[\s\S]*?<\/style>/gi, ' ').replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ')).trim() },
  _abs(u, base) { u = this._decode(String(u || '').trim()); if (!u) return ''; if (/^https?:\/\//i.test(u)) return u; if (u.startsWith('//')) return 'https:' + u; if (u[0] === '/') return this._site + u; return String(base || this._site + '/').replace(/[#?].*$/, '').replace(/\/[^/]*$/, '/') + u },
  _first(s, re) { const m = String(s || '').match(re); return m ? m[1] || '' : '' },
  _tag(s, re) { const m = String(s || '').match(re); return m ? m[0] : '' },
  _attr(t, n) { const m = String(t || '').match(new RegExp(n + '\\s*=\\s*("([^"]*)"|\'([^\']*)\'|([^\\s>]+))', 'i')); return m ? this._decode(m[2] || m[3] || m[4] || '') : '' },

  _parseBooks(html, base) {
    const out = [], seen = {}; const re = /<li[^>]*>\s*<div class=["']list-imgbox["'][\s\S]*?<\/li>/gi; let m
    while ((m = re.exec(html))) {
      const b = m[0], href = this._first(b, /href=["']([^"']*\/youshengxiaoshuo\/\d+\/?)["']/i); if (!href) continue
      const id = this._abs(href, base); if (seen[id]) continue
      const title = this._clean(this._first(b, /class=["']list-book-dt["'][^>]*>[\s\S]*?<a[^>]*>([\s\S]*?)<\/a>/i) || this._first(b, /title=["']([^"']+)["']/i)).replace(/有声小说.*$/, '').trim(); if (!title) continue
      const img = this._tag(b, /<img\b[^>]*>/i); const cover = this._abs(this._attr(img, 'data-original') || this._attr(img, 'src'), base)
      const intro = this._clean(this._first(b, /class=["']list-book-des["'][^>]*>([\s\S]*?)<\/dd>/i)); const names = []; let a; const ar = /<a\b[^>]*href=["'][^"']*\/boyin\/\d+\.html["'][^>]*>([\s\S]*?)<\/a>/gi
      while ((a = ar.exec(b))) { const x = this._clean(a[1]); if (x && names.indexOf(x) < 0) names.push(x) }
      seen[id] = true; out.push({ bookId: id, title, cover, author: names.join('、'), intro })
    }
    return out
  },

  async search(keyword, page = 1) {
    const kw = String(keyword || '').trim()
    if (!kw) return { list: [], page: Math.max(1, Number(page) || 1), maxPage: 1, hasMore: false }
    // 先注入网页登录 Cookie，再访问首页建立/补齐会话，避免站点直接 reset POST 连接
    await this._ensureLogin().catch(() => {})
    await this._html(this._site + '/', this._site + '/').catch(() => {})
    let r = null
    let networkError = null
    for (let attempt = 0; attempt < 2; attempt++) {
      try {
        r = await this._request({ url: this._site + '/novelsearch/search/result.html', method: 'POST', data: 'searchword=' + encodeURIComponent(kw), headers: { 'Content-Type': 'application/x-www-form-urlencoded', Accept: 'text/html, */*; q=0.01' }, referer: this._site + '/' })
        networkError = null
        break
      } catch (e) {
        networkError = e
        if (attempt === 0) await this._sleep(1200)
      }
    }
    if (!r) throw (networkError || new Error('搜索网络失败'))
    const h = String(r.data || '')
    if (/var\s+reversed\s*=/.test(h) && this._guardPass(h, this._host(this._site))) {
      return this.search(kw, page)
    }
    if (r.statusCode < 200 || r.statusCode >= 300) throw new Error('搜索 HTTP ' + r.statusCode)
    return { list: this._parseBooks(h, this._site), page: Math.max(1, Number(page) || 1), maxPage: 1, hasMore: false }
  },

  async _bookInfo(url) {
    if (this._bookCache[url]) return this._bookCache[url]
    const h = await this._html(url, this._site + '/'); const title = this._clean(this._first(h, /<h1[^>]*>([\s\S]*?)<\/h1>/i)).replace(/有声小说.*$/, '').trim()
    let cover = this._first(h, /property=["']og:image["'][^>]*content=["']([^"']+)["']/i) || this._first(h, /(?:data-original|src)=["'](https?:\/\/[^"']*image\.[^"']+)["']/i)
    if (!cover) cover = this._first(h, /(?:data-original|src)=["']([^"']*\/cover\/[^"']+)["']/i)
    const tocHref = this._first(h, /href=["']([^"']*\/itingshus\/[^"']+)["']/i) || url
    const finished = /class=["'][^"']*state[^"']*["'][^>]*>\s*完结/.test(h) || /完结/.test(this._first(h, /<i[^>]*class=["'][^"']*state[^"']*["'][^>]*>([\s\S]*?)<\/i>/i))
    let author = ''; const ai = h.indexOf('演播'); if (ai >= 0) { const w = h.slice(ai, ai + 800); const ns = []; let x; const ar = /<a\b[^>]*href=["'][^"']*\/boyin\/\d+\.html["'][^>]*>([\s\S]*?)<\/a>/gi; while ((x = ar.exec(w))) { const n = this._clean(x[1]); if (n && ns.indexOf(n) < 0) ns.push(n) }; author = ns.join('、') }
    const info = { title, cover: this._abs(cover, url), author, intro: this._clean(this._first(h, /class=["']book-des["'][^>]*>([\s\S]*?)<\/div>/i)), isFinished: finished, tocHref }; if (!title) throw new Error('书籍页解析失败'); this._bookCache[url] = info; return info
  },

  async _chapterPage(url, page) {
    const key = url + '|' + page; if (this._pageCache[key]) return this._pageCache[key]
    const h = await this._html(url + (url.indexOf('?') >= 0 ? '&' : '?') + 'page=' + page, this._site + '/'); const out = [], seen = {}; let m
    const re = /<a\b[^>]*href=["']([^"']*\/play\/\d+_\d+_[^"']+\.html)["'][^>]*>([\s\S]*?)<\/a>/gi
    while ((m = re.exec(h))) { const id = this._abs(m[1], url); const name = this._clean(m[2]); if (name && !seen[id]) { seen[id] = true; out.push({ chapterId: id, name }) } }
    this._pageCache[key] = out; return out
  },

  async getChapters(bookId, page = 1, pageSize = 30) {
    const p = Math.max(1, Number(page) || 1), size = Math.max(1, Math.min(Number(pageSize) || 30, 100)), url = String(bookId), info = await this._bookInfo(url)
    const all = [], sitePage = 1
    // 目录页自身每页约50条，先读取站点页再按 App 窗口换算
    const dirBase = this._abs(info.tocHref || url, url)
    const state = this._pageCache[dirBase] || (this._pageCache[dirBase] = { pages: {}, size: 0, total: null })
    if (!state.size) {
      const first = await this._chapterPage(dirBase, 1)
      state.size = Math.max(1, first.length)
      state.pages[1] = first
    }
    const start = (p - 1) * size
    let cur = Math.floor(start / state.size) + 1
    let pos = start - (cur - 1) * state.size
    let guard = 0
    while (all.length < start + size && guard++ < 100) {
      let rows = state.pages[cur]
      if (!rows) { rows = await this._chapterPage(dirBase, cur); if (!rows.length) { state.total = (cur - 1) * state.size; break }; state.pages[cur] = rows }
      if (rows.length < state.size) state.total = (cur - 1) * state.size + rows.length
      if (pos >= rows.length) { if (state.total !== null) break; cur++; pos = 0; continue }
      all.push(...rows.slice(pos)); cur++; pos = 0
    }
    const shown = all.slice(0, size), list = shown.map((x, i) => ({ chapterId: x.chapterId, index: start + i + 1, name: x.name })), trackCount = state.total === null ? start + all.length : state.total, maxPage = Math.max(1, Math.ceil(trackCount / size))
    return { info: { title: info.title, cover: info.cover, author: info.author, intro: info.intro, trackCount, isFinished: info.isFinished }, list, page: p, maxPage, hasMore: p < maxPage && list.length > 0 }
  },

  _sp(sc) { let out = ''; for (const ch of String(sc)) { const i = this._table.indexOf(ch); const mid = i < 0 ? ch : this._table[(i + 3) % 62]; out += this._table[Math.floor(Math.random() * 62)] + mid + this._table[Math.floor(Math.random() * 62)] }; return out },
  async getAudioUrl(chapterId) {
    const url = String(chapterId || '')
    if (!/\/play\/\d+_\d+_[^/]+\.html/i.test(url)) throw new Error('无效的章节地址: ' + url.slice(0, 80))
    const hit = this._audioCache[url]
    if (hit && Date.now() - hit.at < 300000) return hit.url
    await this._ensureLogin().catch(() => {})

    let lastMsg = ''
    for (let attempt = 0; attempt < 2; attempt++) {
      const h = await this._html(url, this._site + '/')
      const meta = n => this._first(h, new RegExp("<meta[^>]*name=[\\\"']" + n + "[\\\'][^>]*content=[\\\"']([^\\\"']*)[\\\']", "i"))
      const nid = meta('_b'), cid = meta('_p'), sc = meta('_c'), sort = meta('_d') || 'read'
      if (!nid || !cid || !sc) throw new Error('章节页缺少播放参数')
      const r = await this._request({
        url: this._site + '/api/mapi/play', method: 'POST',
        data: 'nid=' + encodeURIComponent(nid) + '&cid=' + encodeURIComponent(cid) + '&sort=' + encodeURIComponent(sort),
        headers: { 'Content-Type': 'application/x-www-form-urlencoded', Accept: 'application/json, text/javascript, */*; q=0.01', 'X-Requested-With': 'XMLHttpRequest', sc, sp: this._sp(sc) },
        referer: url
      })
      let j = r.data
      if (typeof j === 'string') { try { j = JSON.parse(j) } catch (e) { j = null } }
      if (r.statusCode < 200 || r.statusCode >= 300) throw new Error('播放接口 HTTP ' + r.statusCode)
      let audio = String((j && j.url) || '')
      if (audio.startsWith('//')) audio = 'https:' + audio
      if (audio.startsWith('/')) audio = this._site + audio
      if (Number(j && j.status) === 200 && /^https?:\/\//i.test(audio)) {
        this._audioCache[url] = { url: audio, at: Date.now() }
        return audio
      }
      lastMsg = String((j && j.msg) || '')
      if (attempt === 0) await this._sleep(900)
    }
    throw new Error('该章节暂无音频' + (lastMsg ? '：' + lastMsg : '（播放参数已刷新仍未返回音频）'))
  }
})