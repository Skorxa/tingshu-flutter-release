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

  async getAudioUrl(chapterId) {
    const url = String(chapterId || '')
    if (!/\/play\/\d+\/\d+\.html/i.test(url)) throw new Error('无效的章节地址 | ' + url.slice(0, 60))
    const hit = this._audioCache[url]
    if (hit && Date.now() - hit.at < 240000) return hit.value
    const html = await this._page(url, this._site + '/')
    const audio = this._first(html, /url:\s*'([^']+)'/)
    if (!audio) throw new Error('播放页缺少音频配置 | ' + url)
    let value
    if (/^https?:\/\//i.test(audio)) {
      value = { url: audio, headers: { 'User-Agent': this._ua, Referer: this._site + '/', Accept: '*/*' } }
    } else if (audio.indexOf('lrts$') === 0) {
      throw new Error('该章节为懒人听书源，275站内暂无法播放，请换其他书籍或章节')
    } else {
      value = { url: this._abs(audio), headers: { 'User-Agent': this._ua, Referer: this._site + '/' } }
    }
    this._audioCache[url] = { value, at: Date.now() }
    return value
  }
})