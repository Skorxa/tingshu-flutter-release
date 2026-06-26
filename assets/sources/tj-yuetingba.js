// tingshu_json: YuetingbaSource
({
  name: '悦听吧',
  id: 'tingshu-json-yuetingba',
  apiVersion: 1,
  _site: 'http://www.yuetingba.cn',
  _worker: 'https://audiocdn.966001.xyz',
  _pwd: 'admin123',
  _sk: 'xMiP5W1DHBxC5PwQ5oj5QfRn0tsT5UBk',
  _ua: 'Mozilla/5.0 (Linux; Android 13; Mobile) AppleWebKit/537.36 Chrome/147.0 Mobile Safari/537.36',

  _request(url, headers) {
    return new Promise((resolve, reject) => {
      uni.request({ url, method: 'GET', header: Object.assign({ 'User-Agent': this._ua, Referer: this._site + '/' }, headers || {}), timeout: 30000,
        success: r => r.statusCode >= 200 && r.statusCode < 300 ? resolve(String(r.data || '')) : reject(new Error('HTTP ' + r.statusCode + ' | ' + url)),
        fail: e => reject(new Error(e.errMsg || '网络失败')) })
    })
  },
  _decode(s) { return String(s || '').replace(/&#(\d+);/g, (_, n) => String.fromCharCode(parseInt(n, 10))).replace(/&nbsp;/g, ' ').replace(/&amp;/g, '&').replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&lt;/g, '<').replace(/&gt;/g, '>') },
  _clean(s) { return this._decode(String(s || '').replace(/<script[\s\S]*?<\/script>/gi, ' ').replace(/<style[\s\S]*?<\/style>/gi, ' ').replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ')).trim() },
  _attr(tag, name) { const m = String(tag || '').match(new RegExp(name + "\\s*=\\s*(\"([^\"]*)\"|'([^']*)'|([^\\s>]+))", 'i')); return m ? this._decode(m[2] || m[3] || m[4] || '') : '' },
  _abs(url, base) { url = this._decode(String(url || '').trim()); if (!url) return ''; if (/^https?:\/\//i.test(url)) return url; if (url.startsWith('//')) return 'http:' + url; if (url[0] === '/') return this._site + url; return String(base || this._site + '/').replace(/[#?].*$/, '').replace(/\/[^/]*$/, '/') + url },
  _host(base) { return String(base || this._worker).replace(/^https?:\/\//, '').replace(/\/.*$/, '') },
  _workerUrl(path) { const sep = path.indexOf('?') >= 0 ? '&' : '?'; return this._worker + '/' + path.replace(/^\/+/, '') + sep + 'pwd=' + encodeURIComponent(this._pwd) + '&host=' + encodeURIComponent(this._host(this._worker)) },
  _first(s, re) { const m = String(s || '').match(re); return m ? (m[1] || '') : '' },
  _parseBooks(html, base) {
    const list = [], seen = {}
    const re = /<a\b[^>]*href=["']([^"']*\/book\/detail\/[^"']+)["'][^>]*>[\s\S]*?<\/a>/gi
    let m
    while ((m = re.exec(html)) !== null) {
      const href = this._abs(m[1], base)
      if (seen[href]) continue
      const block = html.slice(Math.max(0, m.index - 700), Math.min(html.length, m.index + m[0].length + 900))
      const img = this._first(block, /<img\b[^>]*>/i)
      const title = this._clean(this._first(block, /class=["'][^"']*box-list-item-text-title[^"']*["'][^>]*>([\s\S]*?)<\/[^>]+>/i) || this._attr(img, 'alt') || m[0])
      if (!title) continue
      seen[href] = true
      list.push({ bookId: href, title, cover: this._abs(this._attr(img, 'src'), base), author: '', intro: this._clean(this._first(block, /class=["'][^"']*box-list-item-text-intro[^"']*["'][^>]*>([\s\S]*?)<\/[^>]+>/i)) })
    }
    return list
  },
  _chapterNo(title) { const m = String(title || '').match(/\d+/); return m ? Number(m[0]) : 999999 },

  async search(keyword, page = 1, pageSize = 20) {
    const html = await this._request(this._site + '/Search?type=1&name=' + encodeURIComponent(keyword))
    return { list: this._parseBooks(html, this._site).slice(0, pageSize), page, maxPage: 1, hasMore: false }
  },
  async getChapters(bookId, page = 1, pageSize = 30) {
    const html = await this._request(bookId)
    const bookIdVar = this._first(html, /var\s+bookId\s*=\s*'([^']+)'/i)
    const py = this._first(html, /var\s+py\s*=\s*'([^']+)'/i)
    const all = []
    const re = /<a\b[^>]*(?:onclick=["'][^"']*docs-listen[^"']*|href=["'][^"']*docs-listen[^"']*)[^>]*>([\s\S]*?)<\/a>/gi
    let m
    while ((m = re.exec(html)) !== null) {
      const tag = m[0]
      const id = (tag.match(/'([^']+)'/) || [])[1] || (tag.match(/\/docs-listen\/([^/?#"']+)/) || [])[1] || ''
      const title = this._clean(m[1])
      if (!id || !title) continue
      const api = this._workerUrl('yuetingba/audio?id=' + encodeURIComponent(id) + '&bookId=' + encodeURIComponent(bookIdVar) + '&py=' + encodeURIComponent(py) + '&asUrl=&asName=&sk=' + encodeURIComponent(this._sk))
      all.push({ chapterId: api, name: title })
    }
    all.sort((a, b) => this._chapterNo(a.name) - this._chapterNo(b.name))
    const maxPage = Math.max(1, Math.ceil(all.length / pageSize))
    const start = (page - 1) * pageSize
    return { info: { title: this._clean(this._first(html, /<h1[^>]*>([\s\S]*?)<\/h1>/i)), cover: this._abs(this._first(html, /<img\b[^>]*src=["']([^"']+)["'][^>]*>/i), bookId), author: '', trackCount: all.length, isFinished: true }, list: all.slice(start, start + pageSize).map((x, i) => ({ chapterId: x.chapterId, index: start + i + 1, name: x.name })), page, maxPage, hasMore: page < maxPage }
  },
  async getAudioUrl(chapterId) {
    const raw = await this._request(chapterId, { Referer: this._site + '/' })
    const json = (JSON.parse(raw).data || JSON.parse(raw))
    const url = json.url || json.proxyUrl || ''
    if (!url) throw new Error('悦听吧 Worker 未返回音频')
    return { url, headers: { 'User-Agent': this._ua, Referer: this._site + '/', Accept: 'audio/*,*/*;q=0.8' } }
  }
})
