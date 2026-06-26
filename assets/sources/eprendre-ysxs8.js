// eprendre: YouShengXiaoShuoBa
({
  name: '有声小说吧',
  id: 'eprendre-ysxs8',
  apiVersion: 1,
  configFields: [
    { key: 'cookie', label: '有声小说吧 Cookie', type: 'textarea', required: false }
  ],
  _site: 'http://m.ysxs8.vip',
  _ua: 'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 Chrome/124.0 Mobile Safari/537.36',

  _request(url, headers) {
    const h = Object.assign({ 'User-Agent': this._ua, Referer: this._site + '/' }, headers || {})
    const cookie = (this.config && this.config.cookie) || ''
    if (cookie) h.Cookie = cookie
    return new Promise((resolve, reject) => {
      uni.request({ url, method: 'GET', header: h, timeout: 20000,
        success: r => r.statusCode >= 200 && r.statusCode < 300 ? resolve(String(r.data || '')) : reject(new Error('HTTP ' + r.statusCode + ' | ' + url)),
        fail: e => reject(new Error(e.errMsg || '网络失败')) })
    })
  },
  _decode(s) { return String(s || '').replace(/&#(\d+);/g, (_, n) => String.fromCharCode(parseInt(n, 10))).replace(/&nbsp;/g, ' ').replace(/&amp;/g, '&').replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&lt;/g, '<').replace(/&gt;/g, '>') },
  _clean(s) { return this._decode(String(s || '').replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ')).trim() },
  _attr(tag, name) { const m = String(tag || '').match(new RegExp(name + "\\s*=\\s*(\"([^\"]*)\"|'([^']*)'|([^\\s>]+))", 'i')); return m ? this._decode(m[2] || m[3] || m[4] || '') : '' },
  _abs(url, base) { url = this._decode(String(url || '').trim()); if (!url) return ''; if (/^https?:\/\//i.test(url)) return url; if (url[0] === '/') return this._site + url; return String(base || this._site + '/').replace(/\/[^/]*$/, '/') + url },
  _first(s, re) { const m = String(s || '').match(re); return m ? (m[1] || '') : '' },

  async search(keyword, page = 1, pageSize = 20) {
    const url = this._site + '/downlist/r52_' + page + '.html'
    const html = await this._request(url)
    const list = []
    const re = /<a\b[^>]*href=["']([^"']+)["'][^>]*>[\s\S]*?<\/a>/gi
    let m
    while ((m = re.exec(html)) !== null) {
      const block = m[0]
      if (block.indexOf('book-title') < 0 && block.indexOf('book-submeta') < 0) continue
      const title = this._clean(this._first(block, /class=["'][^"']*book-title[^"']*["'][^>]*>([\s\S]*?)<\/[^>]+>/i) || block)
      if (!title || (keyword && title.indexOf(keyword) < 0)) continue
      const img = this._first(block, /<img\b[^>]*>/i)
      list.push({ bookId: this._abs(m[1], url), title, cover: this._abs(this._attr(img, 'data-original') || this._attr(img, 'src'), url), author: '', intro: this._clean(this._first(block, /class=["'][^"']*book-desc[^"']*["'][^>]*>([\s\S]*?)<\/[^>]+>/i)) })
      if (list.length >= pageSize) break
    }
    const total = Number((String(html).match(/\d+\s*\/\s*(\d+)/) || [])[1] || page) || page
    return { list, page, maxPage: total, hasMore: page < total }
  },

  async getChapters(bookId, page = 1, pageSize = 30) {
    const html = await this._request(bookId)
    const all = []
    const re = /<a\b[^>]*href=["']([^"']+)["'][^>]*>([\s\S]*?)<\/a>/gi
    let m
    while ((m = re.exec(html)) !== null) {
      if (html.lastIndexOf('playlist', m.index) < 0) continue
      const title = this._clean(m[2])
      if (title) all.push({ href: this._abs(m[1], bookId), title })
    }
    const maxPage = Math.max(1, Math.ceil(all.length / pageSize))
    const start = (page - 1) * pageSize
    return { info: { title: '', cover: '', author: '', trackCount: all.length, isFinished: false }, list: all.slice(start, start + pageSize).map((x, i) => ({ chapterId: x.href, index: start + i + 1, name: x.title })), page, maxPage, hasMore: page < maxPage }
  },

  async getAudioUrl(chapterId) {
    const cookie = (this.config && this.config.cookie) || ''
    const headers = { 'User-Agent': this._ua, Referer: this._site + '/' }
    if (cookie) headers.Cookie = cookie
    return { sniff: true, url: String(chapterId), headers, waitMs: 3000, audioPatterns: ['.mp3', '.m4a', '.aac', '.m3u8'] }
  }
})
