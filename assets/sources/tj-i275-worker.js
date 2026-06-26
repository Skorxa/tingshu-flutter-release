// tingshu_json: I275WorkerSource
({
  name: '275听书网（Worker）',
  id: 'tingshu-json-i275',
  apiVersion: 1,
  _site: 'https://m.i275.com',
  _worker: 'https://audiocdn.966001.xyz',
  _pwd: 'admin123',
  _ua: 'Mozilla/5.0 (Linux; Android 13; Mobile) AppleWebKit/537.36 Chrome/147.0 Mobile Safari/537.36',

  _request(url, headers) {
    return new Promise((resolve, reject) => {
      uni.request({ url, method: 'GET', header: Object.assign({ 'User-Agent': this._ua, Referer: this._site + '/' }, headers || {}), timeout: 30000,
        success: r => r.statusCode >= 200 && r.statusCode < 300 ? resolve(String(r.data || '')) : reject(new Error('HTTP ' + r.statusCode + ' | ' + url)),
        fail: e => reject(new Error(e.errMsg || '网络失败')) })
    })
  },
  _decode(s) { return String(s || '').replace(/&#(\d+);/g, (_, n) => String.fromCharCode(parseInt(n, 10))).replace(/&nbsp;/g, ' ').replace(/&amp;/g, '&').replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&lt;/g, '<').replace(/&gt;/g, '>') },
  _clean(s) { return this._decode(String(s || '').replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ')).trim() },
  _attr(tag, name) { const m = String(tag || '').match(new RegExp(name + "\\s*=\\s*(\"([^\"]*)\"|'([^']*)'|([^\\s>]+))", 'i')); return m ? this._decode(m[2] || m[3] || m[4] || '') : '' },
  _abs(url, base) { url = this._decode(String(url || '').trim()); if (!url) return ''; if (/^https?:\/\//i.test(url)) return url; if (url.startsWith('//')) return 'https:' + url; if (url[0] === '/') return this._site + url; return String(base || this._site + '/').replace(/[#?].*$/, '').replace(/\/[^/]*$/, '/') + url },
  _host(base) { return String(base || this._worker).replace(/^https?:\/\//, '').replace(/\/.*$/, '') },
  _workerUrl(path) { const sep = path.indexOf('?') >= 0 ? '&' : '?'; return this._worker + '/' + path.replace(/^\/+/, '') + sep + 'pwd=' + encodeURIComponent(this._pwd) + '&host=' + encodeURIComponent(this._host(this._worker)) },
  _first(s, re) { const m = String(s || '').match(re); return m ? (m[1] || '') : '' },
  _parseBooks(html, base) {
    const list = [], seen = {}
    const re = /<a\b[^>]*href=["']([^"']*\/book\/[^"']+)["'][^>]*>[\s\S]*?<\/a>/gi
    let m
    while ((m = re.exec(html)) !== null) {
      const href = this._abs(m[1], base)
      if (!/\/book\/\d+\.html/.test(href) || seen[href]) continue
      const block = m[0]
      const img = this._first(block, /<img\b[^>]*>/i)
      const title = this._clean(this._attr(img, 'alt') || this._first(block, /<h3[^>]*>([\s\S]*?)<\/h3>/i) || block)
      if (!title) continue
      seen[href] = true
      list.push({ bookId: href, title, cover: this._abs(this._attr(img, 'src'), base), author: '', intro: '' })
    }
    return list
  },

  async search(keyword, page = 1, pageSize = 20) {
    const html = await this._request(this._site + '/search.php?q=' + encodeURIComponent(keyword))
    const list = this._parseBooks(html, this._site).slice(0, pageSize)
    return { list, page, maxPage: 1, hasMore: false }
  },

  async getChapters(bookId, page = 1, pageSize = 30) {
    const html = await this._request(bookId)
    const bookMatch = String(bookId).match(/\/book\/(\d+)\.html/)
    const bookNo = bookMatch ? bookMatch[1] : ''
    const all = []
    const re = /<a\b[^>]*href=["']([^"']*\/play\/[^"']+)["'][^>]*>([\s\S]*?)<\/a>/gi
    let m
    while ((m = re.exec(html)) !== null) {
      const href = this._abs(m[1], bookId)
      const epBook = (href.match(/\/play\/(\d+)\//) || [])[1] || ''
      if (bookNo && epBook && epBook !== bookNo) continue
      const title = this._clean(m[2])
      if (title) all.push({ chapterId: href, name: title })
    }
    const maxPage = Math.max(1, Math.ceil(all.length / pageSize))
    const start = (page - 1) * pageSize
    return { info: { title: this._clean(this._first(html, /<h1[^>]*>([\s\S]*?)<\/h1>/i)), cover: this._abs(this._first(html, /<img\b[^>]*src=["']([^"']+)["']/i), bookId), author: '', trackCount: all.length, isFinished: true }, list: all.slice(start, start + pageSize).map((x, i) => ({ chapterId: x.chapterId, index: start + i + 1, name: x.name })), page, maxPage, hasMore: page < maxPage }
  },

  async getAudioUrl(chapterId) {
    const m = String(chapterId).match(/\/play\/(\d+)\/(\d+)\.html/)
    if (!m) return String(chapterId)
    const api = this._workerUrl('i275/audio?book=' + encodeURIComponent(m[1]) + '&episode=' + encodeURIComponent(m[2]))
    const raw = await this._request(api, { Referer: this._site + '/' })
    const json = (JSON.parse(raw).data || JSON.parse(raw))
    return json.url || json.proxyUrl || this._workerUrl('i275/stream?book=' + encodeURIComponent(m[1]) + '&episode=' + encodeURIComponent(m[2]))
  }
})
