// tingshu_json: QitingSource
({
  name: '奇听网',
  id: 'tingshu-json-qiting',
  apiVersion: 1,
  _site: 'https://www.qiting.cc',
  _ua: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36',
  _cookies: {},

  _cookieHeader() { return Object.keys(this._cookies).map(k => k + '=' + this._cookies[k]).join('; ') },
  _remember(header) {
    const raw = header && (header['set-cookie'] || header['Set-Cookie'])
    const list = Array.isArray(raw) ? raw : (raw ? [String(raw)] : [])
    for (const line of list) {
      const pair = String(line).split(';')[0]
      const idx = pair.indexOf('=')
      if (idx > 0) this._cookies[pair.slice(0, idx).trim()] = pair.slice(idx + 1).trim()
    }
  },
  _request(url, method, body, referer) {
    const headers = { 'User-Agent': this._ua, Accept: 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8', Referer: referer || this._site + '/' }
    const cookie = this._cookieHeader()
    if (cookie) headers.Cookie = cookie
    if (method === 'POST') headers['Content-Type'] = 'application/x-www-form-urlencoded'
    return new Promise((resolve, reject) => {
      uni.request({ url, method: method || 'GET', data: body || null, header: headers, timeout: 30000,
        success: r => {
          this._remember(r.header)
          if (r.statusCode < 200 || r.statusCode >= 300) return reject(new Error('HTTP ' + r.statusCode + ' | ' + url))
          let html = String(r.data || '')
          if (/<title>Loading\.\.\.<\/title>/i.test(html) && /var\s+reversed/i.test(html)) {
            this._applyGuard(html)
          }
          resolve(html)
        },
        fail: e => reject(new Error(e.errMsg || '网络失败')) })
    })
  },
  _applyGuard(html) {
    const m = String(html).match(/var\s+reversed\s*=\s*["']([^"']+)["']/i)
    if (!m) return
    try {
      const code = atob(m[1].split('').reverse().join(''))
      const token = (code.match(/var\s+token\s*=\s*['"]([^'"]+)['"]/i) || [])[1] || ''
      if (token) {
        this._cookies.pt_guid = encodeURIComponent(token)
        this._cookies.ptcms_guard_retry = '1'
      }
    } catch (e) {}
  },
  _decode(s) { return String(s || '').replace(/&#(\d+);/g, (_, n) => String.fromCharCode(parseInt(n, 10))).replace(/&nbsp;/g, ' ').replace(/&amp;/g, '&').replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&lt;/g, '<').replace(/&gt;/g, '>') },
  _clean(s) { return this._decode(String(s || '').replace(/<script[\s\S]*?<\/script>/gi, ' ').replace(/<style[\s\S]*?<\/style>/gi, ' ').replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ')).trim() },
  _attr(tag, name) { const m = String(tag || '').match(new RegExp(name + "\\s*=\\s*(\"([^\"]*)\"|'([^']*)'|([^\\s>]+))", 'i')); return m ? this._decode(m[2] || m[3] || m[4] || '') : '' },
  _abs(url, base) { url = this._decode(String(url || '').trim()); if (!url) return ''; if (/^https?:\/\//i.test(url)) return url; if (url.startsWith('//')) return 'https:' + url; if (url[0] === '/') return this._site + url; return String(base || this._site + '/').replace(/[#?].*$/, '').replace(/\/[^/]*$/, '/') + url },
  _first(s, re) { const m = String(s || '').match(re); return m ? (m[1] || '') : '' },
  _parseBooks(html, base) {
    const list = [], seen = {}
    const re = /<a\b[^>]*href=["']([^"']*\/book\/\d+\.html)["'][^>]*>[\s\S]*?<\/a>/gi
    let m
    while ((m = re.exec(html)) !== null) {
      const href = this._abs(m[1], base)
      if (seen[href]) continue
      const blockStart = Math.max(0, m.index - 600)
      const blockEnd = Math.min(html.length, m.index + m[0].length + 900)
      const block = html.slice(blockStart, blockEnd)
      const img = this._first(block, /<img\b[^>]*>/i)
      const title = this._clean(this._attr(img, 'alt') || this._attr(m[0], 'title') || m[0]).replace(/有声小说.*$/, '').trim()
      if (!title) continue
      seen[href] = true
      list.push({ bookId: href, title, cover: this._abs(this._attr(img, 'data-original') || this._attr(img, 'src'), base), author: this._clean(this._first(block, /(?:演播|主播)[：:\s]*<\/?[^>]*>\s*([^<]+)/i)), intro: this._clean(this._first(block, /class=["'][^"']*(?:list-book-des|rm-js)[^"']*["'][^>]*>([\s\S]*?)<\/[^>]+>/i)) })
    }
    return list
  },
  _tocPage(url, page) {
    const clean = this._abs(url, this._site).replace(/&amp;/g, '&')
    const parts = clean.split('?')
    const params = parts[1] ? parts[1].split('&').filter(p => p && !/^page=/i.test(p) && !/^sort=/i.test(p)) : []
    return parts[0] + '?' + params.concat(['page=' + page, 'sort=asc']).join('&')
  },

  async search(keyword, page = 1, pageSize = 20) {
    let html = await this._request(this._site + '/search.html', 'POST', 'searchword=' + encodeURIComponent(keyword), this._site)
    if (/<title>Loading\.\.\.<\/title>/i.test(html)) html = await this._request(this._site + '/search.html', 'POST', 'searchword=' + encodeURIComponent(keyword), this._site)
    return { list: this._parseBooks(html, this._site).slice(0, pageSize), page, maxPage: 1, hasMore: false }
  },

  async getChapters(bookId, page = 1, pageSize = 30) {
    let html = await this._request(bookId, 'GET', null, this._site)
    if (/<title>Loading\.\.\.<\/title>/i.test(html)) html = await this._request(bookId, 'GET', null, this._site)
    const toc = this._first(html, /href=["']([^"']*\/bookdir\/[^"']+)["']/i)
    const tocUrl = toc ? this._tocPage(this._abs(toc, bookId), page) : bookId
    const tocHtml = toc ? await this._request(tocUrl, 'GET', null, bookId) : html
    const all = []
    const re = /<a\b[^>]*href=["']([^"']*\/tingshu\/[^"']+)["'][^>]*>([\s\S]*?)<\/a>/gi
    let m
    while ((m = re.exec(tocHtml)) !== null) {
      const name = this._clean(m[2])
      if (name) all.push({ chapterId: this._abs(m[1], tocUrl), name })
    }
    const hasMore = /[?&]page=(\d+)/i.test(tocHtml) || all.length >= pageSize
    return { info: { title: this._clean(this._first(html, /<h1[^>]*>([\s\S]*?)<\/h1>/i)), cover: this._abs(this._first(html, /<img\b[^>]*(?:data-original|src)=["']([^"']+)["'][^>]*>/i), bookId), author: '', trackCount: 0, isFinished: true }, list: all.slice(0, pageSize).map((x, i) => ({ chapterId: x.chapterId, index: (page - 1) * pageSize + i + 1, name: x.name })), page, maxPage: hasMore ? page + 1 : page, hasMore }
  },

  async getAudioUrl(chapterId) {
    const m = String(chapterId).match(/\/tingshu\/(\d+)\/(\d+)\.html/)
    const player = m ? (this._site + '/player.html?nid=' + m[1] + '&cid=' + m[2] + '&site=16') : String(chapterId)
    const raw = await this._request(player, 'GET', null, chapterId)
    const base = (raw.match(/url\d+\s*=\s*['"]([^'"]+)['"]/) || [])[1] || ''
    const suffix = (raw.match(/mp3\s*:\s*''\s*\+\s*url\d+\s*\+\s*['"]([^'"]+)['"]/) || [])[1] || (raw.match(/mp3\s*:\s*['"]([^'"]+)['"]/) || [])[1] || ''
    if (/^https?:\/\//i.test(suffix)) return suffix
    if (base && suffix) return base + suffix
    if (base) return base
    throw new Error('未解析到音频地址')
  }
})
