// eprendre: TingShu74
({
  name: '74听书',
  id: 'eprendre-ting74',
  version: 1,
  apiVersion: 1,
  _site: 'http://www.ting74.com',
  _ua: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36',

  _request(url, headers) {
    return new Promise((resolve, reject) => {
      uni.request({
        url,
        method: 'GET',
        header: Object.assign({ 'User-Agent': this._ua, Referer: this._site + '/' }, headers || {}),
        timeout: 20000,
        success: r => {
          if (r.statusCode < 200 || r.statusCode >= 300) return reject(new Error('HTTP ' + r.statusCode + ' | ' + url))
          resolve(String(r.data || ''))
        },
        fail: e => reject(new Error(e.errMsg || '网络失败'))
      })
    })
  },

  _decode(s) { return String(s || '').replace(/&#(\d+);/g, (_, n) => String.fromCharCode(parseInt(n, 10))).replace(/&nbsp;/g, ' ').replace(/&amp;/g, '&').replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&lt;/g, '<').replace(/&gt;/g, '>') },
  _clean(s) { return this._decode(String(s || '').replace(/<script[\s\S]*?<\/script>/gi, ' ').replace(/<style[\s\S]*?<\/style>/gi, ' ').replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ')).trim() },
  _attr(tag, name) { const m = String(tag || '').match(new RegExp(name + "\\s*=\\s*(\"([^\"]*)\"|'([^']*)'|([^\\s>]+))", 'i')); return m ? this._decode(m[2] || m[3] || m[4] || '') : '' },
  _abs(url, base) { url = this._decode(String(url || '').trim()); if (!url) return ''; if (/^https?:\/\//i.test(url)) return url; if (url.startsWith('//')) return 'http:' + url; if (url[0] === '/') return this._site + url; return String(base || this._site + '/').replace(/[#?].*$/, '').replace(/\/[^/]*$/, '/') + url },
  _first(s, re) { const m = String(s || '').match(re); return m ? (m[1] || '') : '' },

  _parseBooks(html, base) {
    const list = []
    const re = /<li\b[^>]*>[\s\S]*?<\/li>/gi
    let m
    while ((m = re.exec(html)) !== null) {
      const block = m[0]
      if (block.indexOf('list-book-dt') < 0 && block.indexOf('list-works') < 0) continue
      const href = this._first(block, /<a\b[^>]*href=["']([^"']+)["']/i)
      const title = this._clean(this._first(block, /class=["'][^"']*list-book-dt[^"']*["'][\s\S]*?<a\b[^>]*>([\s\S]*?)<\/a>/i))
      if (!href || !title) continue
      const img = this._first(block, /<img\b[^>]*>/i)
      const spans = []
      const spanRe = /<span\b[^>]*>([\s\S]*?)<\/span>/gi
      let sm
      while ((sm = spanRe.exec(block)) !== null) spans.push(this._clean(sm[1]))
      list.push({
        bookId: this._abs(href, base),
        title,
        cover: this._abs(this._attr(img, 'data-original') || this._attr(img, 'src'), base),
        author: spans[0] || '',
        intro: spans.slice(1).join(' ')
      })
    }
    return list
  },

  async search(keyword, page = 1, pageSize = 20) {
    const url = this._site + '/search.html?searchtype=name&searchword=' + encodeURIComponent(keyword) + '&page=' + page
    const html = await this._request(url)
    const list = this._parseBooks(html, url).slice(0, pageSize)
    const next = this._first(html, /class=["'][^"']*fanye[^"']*["'][\s\S]*href=["'][^"']*page=(\d+)["'][\s\S]*<\/[^>]+>/i)
    const maxPage = Number(next || page) || page
    return { list, page, maxPage, hasMore: page < maxPage || list.length >= pageSize }
  },

  async getChapters(bookId, page = 1, pageSize = 30) {
    const html = await this._request(bookId)
    const rows = []
    const re = /<li\b[^>]*>\s*<a\b[^>]*href=["']([^"']+)["'][^>]*>([\s\S]*?)<\/a>\s*<\/li>/gi
    let m
    while ((m = re.exec(html)) !== null) {
      if (rows.length > 0 || html.lastIndexOf('playlist', m.index) >= 0) {
        rows.push({ href: this._abs(m[1], bookId), title: this._clean(m[2]) })
      }
    }
    const all = rows.filter(x => x.title)
    const maxPage = Math.max(1, Math.ceil(all.length / pageSize))
    const start = (page - 1) * pageSize
    return {
      info: { title: this._clean(this._first(html, /<h1[^>]*>([\s\S]*?)<\/h1>/i)), cover: '', author: '', trackCount: all.length, isFinished: true },
      list: all.slice(start, start + pageSize).map((x, i) => ({ chapterId: x.href, index: start + i + 1, name: x.title })),
      page, maxPage, hasMore: page < maxPage
    }
  },

  async getAudioUrl(chapterId) {
    return { sniff: true, url: String(chapterId), headers: { 'User-Agent': this._ua, Referer: this._site + '/' }, waitMs: 3000, audioPatterns: ['.mp3', '.m4a', '.aac'] }
  }
})
