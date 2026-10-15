// 275听书网（m.i275.com 直连版，替换失效的 Worker 方案）
// 搜索：/search.php?q=   书籍：/book/{id}.html   章节：/play/{book}/{ep}.html
// 播放页需先访问首页取得 PHPSESSID；音频地址在 APlayer 配置中
// - 喜马拉雅源：签名直链（audiopay.cos.tx.xmcdn.com），可直接播放
// - 懒人听书源（lrts$…#…）：站内自身即 404，无法播放
({
  id: 'tingshu-json-i275',
  version: 1,
  name: '275听书网',
  apiVersion: 1,
  _site: 'https://m.i275.com',
  _ua: 'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Mobile Safari/537.36',
  _lrtsApi: 'https://fm.12311111.xyz/api/lrts/index.php',
  _lrtsAt: 0,
  _cookies: {}, _bookCache: {}, _audioCache: {}, _queue: null, _lastReqAt: 0,

  _sleep(ms) { return new Promise(r => setTimeout(r, ms)) },
  _gate() {
    const prev = this._queue || Promise.resolve()
    const job = prev.then(() => this._sleep(Math.max(0, this._lastReqAt + 1000 - Date.now()) + Math.floor(Math.random() * 200))).then(() => { this._lastReqAt = Date.now() })
    this._queue = job.catch(() => {})
    return job
  },
  _host(url) { const m = String(url).match(/^https?:\/\/([^/]+)/i); return m ? m[1].toLowerCase() : 'm.i275.com' },
  _jar() { return this._cookies },
  _cookieHeader() { const j = this._jar(); return Object.keys(j).map(k => k + '=' + j[k]).join('; ') },
  _remember(header) {
    const raw = header && (header['set-cookie'] || header['Set-Cookie'])
    const list = Array.isArray(raw) ? raw : (raw ? [raw] : [])
    const j = this._jar()
    for (const line of list) { const p = String(line).split(';')[0]; const i = p.indexOf('='); if (i > 0) j[p.slice(0, i).trim()] = p.slice(i + 1).trim() }
  },
  _retryAfter(header) { const x = header && (header['retry-after'] || header['Retry-After']); const n = Number(Array.isArray(x) ? x[0] : x); return isFinite(n) && n > 0 ? Math.min(15000, Math.max(1000, n * 1000)) : 0 },
  async _request(o) {
    o = o || {}; let last = { statusCode: 0, data: null, header: {} }
    for (let a = 0; a < 3; a++) {
      const headers = Object.assign({ 'User-Agent': this._ua, Referer: o.referer || this._site + '/' }, o.headers || {})
      const cookie = this._cookieHeader(); if (cookie) headers.Cookie = cookie
      await this._gate()
      let r
      try {
        r = await new Promise((resolve, reject) => uni.request({ url: o.url, method: (o.method || 'GET').toUpperCase(), data: o.data, header: headers, timeout: o.timeout || 20000, success: x => resolve({ statusCode: x.statusCode || 0, data: x.data, header: x.header || {} }), fail: e => reject(new Error(e.errMsg || '网络失败')) }))
      } catch (e) {
        if (a < 2) { await this._sleep(a ? 3000 : 1200); continue }
        throw e
      }
      this._remember(r.header); last = r
      if (r.statusCode >= 200 && r.statusCode < 300) break
      if ((r.statusCode === 429 || r.statusCode === 503) && a < 2) { await this._sleep(this._retryAfter(r.header) || (a ? 4000 : 1500)); continue }
      break
    }
    return last
  },
  // 站点对无会话请求返回通用页；先访问首页建立 PHPSESSID
  async _ensureSession() {
    if (this._jar().PHPSESSID) return
    await this._request({ url: this._site + '/' })
  },
  async _page(url, referer) {
    await this._ensureSession()
    const r = await this._request({ url, referer: referer || this._site + '/' })
    const h = String(r.data || '')
    if (r.statusCode < 200 || r.statusCode >= 300) throw new Error('HTTP ' + r.statusCode + ' | ' + url)
    return h
  },
  _decode(s) { return String(s || '').replace(/&#x?([0-9a-fA-F]+);/g, (_, n) => String.fromCharCode(/^[0-9]+$/.test(n) ? parseInt(n, 10) : parseInt(n, 16))).replace(/&nbsp;/g, ' ').replace(/&amp;/g, '&').replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&lt;/g, '<').replace(/&gt;/g, '>') },
  _clean(s) { return this._decode(String(s || '').replace(/<script[\s\S]*?<\/script>/gi, ' ').replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ')).trim() },
  _abs(u) { u = this._decode(String(u || '').trim()); if (!u) return ''; if (/^https?:\/\//i.test(u)) return u; if (u.startsWith('//')) return 'https:' + u; return this._site + u },
  _first(s, re) { const m = String(s || '').match(re); return m ? m[1] || '' : '' },
  _attr(t, n) { const m = String(t || '').match(new RegExp(n + '\\s*=\\s*("([^"]*)"|\'([^\']*)\'|([^\\s>]+))', 'i')); return m ? this._decode(m[2] || m[3] || m[4] || '') : '' },

  // 解析书籍卡片（搜索结果与首页最近上架共用结构：<a href="/book/N.html">…<img alt>…<h3>标题</h3>…）
  _parseBooks(html) {
    const out = [], seen = {}; const re = /<a\b[^>]*href=["'](?:https?:\/\/m\.i275\.com)?(\/book\/\d+\.html)["'][^>]*>([\s\S]*?)<\/a>/gi; let m
    while ((m = re.exec(html))) {
      const href = m[1], block = m[2]
      if (seen[href] || block.indexOf('<img') < 0) continue
      const title = this._clean(this._first(block, /<h3[^>]*>([\s\S]*?)<\/h3>/i) || this._attr(this._tag(block, /<img\b[^>]*>/i), 'alt'))
      if (!title) continue
      seen[href] = true
      const img = this._tag(block, /<img\b[^>]*>/i)
      const anchor = this._first(this._clean(block).match(/([^\s]{2,20})\s*演播/) ? this._clean(block).match(/([^\s:：]{2,20})\s*演播/) : null, /(.*)/)
      out.push({ bookId: this._site + href, title, cover: this._abs(this._attr(img, 'src')), author: this._clean(anchor || ''), intro: '' })
    }
    return out
  },
  _tag(s, re) { const m = String(s || '').match(re); return m ? m[0] : '' },

  async search(keyword, page = 1) {
    const kw = String(keyword || '').trim()
    if (!kw) return { list: [], page: 1, maxPage: 1, hasMore: false }
    const html = await this._page(this._site + '/search.php?q=' + encodeURIComponent(kw), this._site + '/')
    return { list: this._parseBooks(html), page: 1, maxPage: 1, hasMore: false }
  },

  async discover() {
    const html = await this._page(this._site + '/')
    const list = this._parseBooks(html).slice(0, 12)
    return { sections: list.length ? [{ title: '最近上架', list }] : [] }
  },

  async getChapters(bookId, page = 1, pageSize = 30) {
    const p = Math.max(1, Number(page) || 1), size = Math.max(1, Math.min(Number(pageSize) || 30, 100)), url = String(bookId)
    let info = this._bookCache[url]
    let all
    if (info && info._chapters) { all = info._chapters } else {
      const html = await this._page(url, this._site + '/')
      const title = this._clean(this._first(html, /<h1[^>]*text-2xl[^>]*>([\s\S]*?)<\/h1>/i)) || this._clean(this._first(html, /<h1[^>]*>([\s\S]*?)<\/h1>/i)).replace(/- ?275听书.*$/, '').trim() || this._clean(this._first(html, /<title[^>]*>([\s\S]*?)<\/title>/i)).replace(/\s*-.*$/, '')
      if (!title) throw new Error('书籍页解析失败 | ' + url)
      const author = this._clean(this._first(html, /作者：<\/span>|作者：<span[^>]*>([\s\S]*?)<\/span>/i).replace(/^作者：/, '')) || this._clean(this._first(html, /作者：<span[^>]*>([\s\S]*?)<\/span>/i))
      const anchor = this._clean(this._first(html, /演播：<span[^>]*>([\s\S]*?)<\/span>/i))
      const finished = /状态：[\s\S]{0,80}已完结/.test(html)
      const intro = this._clean(this._first(html, /property=["']og:description["'][^>]*content=["']([^"']+)["']/i))
      const seen = {}; all = []
      const re = /href=["'](?:https?:\/\/m\.i275\.com)?(\/play\/\d+\/\d+\.html)["'][^>]*>([\s\S]*?)<\/a>/gi; let m
      while ((m = re.exec(html))) {
        const href = m[1], name = this._clean(m[2])
        if (seen[href] || !name || name === '立即开始收听' || name === '继续播放') continue
        seen[href] = true
        all.push({ ep: href, name })
      }
      if (!all.length) throw new Error('目录解析失败 | ' + url)
      info = { title, cover: this._abs(this._attr(this._tag(html, /<h1[\s\S]{0,400}?<img\b[^>]*>/i), 'src') || this._first(html, /<img\b[^>]*src=["']([^"']+)["']/i)), author: [author, anchor].filter(Boolean).join(' / '), intro, isFinished: finished, _chapters: all }
      this._bookCache[url] = info
    }
    const maxPage = Math.max(1, Math.ceil(all.length / size))
    const safePage = Math.max(1, Math.min(p, maxPage))
    const start = (safePage - 1) * size
    return {
      info: { title: info.title, cover: info.cover, author: info.author, intro: info.intro, trackCount: all.length, isFinished: info.isFinished },
      list: all.slice(start, start + size).map((x, i) => ({ chapterId: this._site + x.ep, index: start + i + 1, name: x.name })),
      page: safePage, maxPage, hasMore: safePage < maxPage
    }
  },

  // ── 音频：站点自带 JSON 接口 api_chapter.php（需会话 Cookie）──
  // GET /api_chapter.php?book_id=&chapter_id= → {url, title, book_title, cover, chapter_id, book_id}
  // url 有两种：xmcdn 直链（喜马拉雅源）／ lrts$专辑#轨道#集序号#token（懒人源，站内不解析）
  // 另：接口会在多个 CDN 后端间轮换，其中 2025.tingshijie.com 已失效（403），检测到就重试换后端
  _badHost(u) { return /tingshijie\.com/i.test(String(u)) },
  async _apiChapter(bookId, chapterId) {
    await this._ensureSession()
    let last = null
    for (let i = 0; i < 4; i++) {
      const r = await this._request({ url: this._site + '/api_chapter.php?book_id=' + encodeURIComponent(bookId) + '&chapter_id=' + encodeURIComponent(chapterId), referer: this._site + '/' })
      let j = r.data
      if (typeof j === 'string') { try { j = JSON.parse(j) } catch (e) { j = null } }
      if (!j || j.error) return null
      last = j
      const u = String(j.url || '')
      if (/^https?:\/\//i.test(u) && !this._badHost(u)) return j
      if (u.indexOf('lrts$') === 0) return j
      await this._sleep(500)
    }
    return last
  },

  // lrts$ 章节桥接：lrts$<专辑>#<轨道>#<集序号>#<token>.txt → 爱听书API 解析（同 IP 每 30 秒 1 次，源内自动等窗口）
  async _lrtsAudio(raw) {
    const m = String(raw).match(/^lrts\$(\d+)#(\d+)#(\d+)#/)
    if (!m) throw new Error('无法解析该章节的懒人源标识')
    const album = m[1], section = Number(m[3]) || 1
    const call = async () => {
      const wait = this._lrtsAt + 31000 - Date.now()
      if (wait > 0) await this._sleep(wait)
      const j = await this._request({ url: this._lrtsApi + '?act=audio&bookId=' + album + '&section=' + section + '&opType=1' })
      this._lrtsAt = Date.now()
      const env = (j && j.data) || {}
      // 响应有两层：{code,msg,data:{url}}；兼容直接 {url}
      const d = env.data || env
      return { url: String(d.url || ''), msg: this._clean(d.error || env.msg || '') }
    }
    let r = await call()
    if (!/^https?:\/\//i.test(r.url) && r.msg.indexOf('频繁') >= 0) {
      const sec = Number((r.msg.match(/(\d+)\s*秒/) || [])[1] || 30)
      await this._sleep((sec + 1) * 1000)
      r = await call()
    }
    if (!/^https?:\/\//i.test(r.url)) throw new Error('该章节暂不可播放' + (r.msg ? '：' + r.msg : ''))
    return r.url
  },

  async getAudioUrl(chapterId) {
    const raw = String(chapterId || '')
    if (!/\/play\/\d+\/\d+\.html/i.test(raw)) throw new Error('无效的章节地址 | ' + raw.slice(0, 60))
    const hit = this._audioCache[raw]
    if (hit && Date.now() - hit.at < hit.ttl) return hit.value
    const ids = raw.match(/\/play\/(\d+)\/(\d+)\.html/i)
    const bookId = ids[1], chapterIdPart = ids[2]

    let audio = ''
    // 通道 1：JSON 接口
    try {
      const j = await this._apiChapter(bookId, chapterIdPart)
      if (j && j.url) audio = String(j.url)
    } catch (e) {}
    // 通道 2：播放页解析兜底
    if (!audio) {
      const html = await this._page(raw, this._site + '/')
      audio = this._first(html, /url:\s*'([^']+)'/)
    }
    if (!audio) throw new Error('未取到音频地址 | ' + raw.slice(0, 60))

    let value, ttl
    if (/^https?:\/\//i.test(audio)) {
      value = { url: audio, headers: { 'User-Agent': this._ua, Referer: this._site + '/', Accept: '*/*' } }
      ttl = 4 * 60 * 1000
    } else if (audio.indexOf('lrts$') === 0) {
      const url = await this._lrtsAudio(audio)
      value = { url, headers: { 'User-Agent': this._ua, Referer: this._site + '/' } }
      ttl = 12 * 60 * 60 * 1000
    } else {
      value = { url: this._abs(audio), headers: { 'User-Agent': this._ua, Referer: this._site + '/' } }
      ttl = 4 * 60 * 1000
    }
    this._audioCache[raw] = { value, at: Date.now(), ttl }
    return value
  }
})