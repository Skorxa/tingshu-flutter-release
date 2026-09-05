// eprendre: PingShu5
({
  name: '单田芳评书网',
  id: 'eprendre-pingshu5',
  version: 1,
  apiVersion: 1,
  _site: 'http://www.pingshu5.net',
  _ua: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
  _cats: [
    ['单田芳', 'http://www.pingshu5.net/pbook/'],
    ['袁阔成', 'http://www.pingshu5.net/ykc/'],
    ['刘兰芳', 'http://www.pingshu5.net/llf/'],
    ['连丽如', 'http://www.pingshu5.net/llr/']
  ],
  _request(url) {
    return new Promise((resolve, reject) => {
      uni.request({ url, method: 'GET', header: { 'User-Agent': this._ua }, timeout: 20000,
        success: r => r.statusCode >= 200 && r.statusCode < 300 ? resolve(String(r.data || '')) : reject(new Error('HTTP ' + r.statusCode + ' | ' + url)),
        fail: e => reject(new Error(e.errMsg || '网络失败')) })
    })
  },
  _clean(s) { return String(s || '').replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ').trim() },
  _attr(tag, name) { const m = String(tag || '').match(new RegExp(name + "\\s*=\\s*(\"([^\"]*)\"|'([^']*)'|([^\\s>]+))", 'i')); return m ? (m[2] || m[3] || m[4] || '') : '' },
  _abs(url, base) { url = String(url || '').trim(); if (/^https?:\/\//i.test(url)) return url; if (url[0] === '/') return this._site + url; return String(base || this._site + '/').replace(/\/[^/]*$/, '/') + url },

  async search(keyword, page = 1, pageSize = 20) {
    if (page > 1) return { list: [], page, maxPage: 1, hasMore: false }
    const cat = this._cats.find(x => !keyword || x[0].indexOf(keyword) >= 0) || this._cats[0]
    const html = await this._request(cat[1])
    const list = []
    const re = /<li\b[^>]*>[\s\S]*?<\/li>/gi
    let m
    while ((m = re.exec(html)) !== null) {
      const block = m[0]
      if (block.indexOf('caption') < 0) continue
      const a = (block.match(/class=["'][^"']*caption[^"']*["'][\s\S]*?(<a\b[\s\S]*?<\/a>)/i) || [])[1] || ''
      const img = (block.match(/<img\b[^>]*>/i) || [])[0] || ''
      const title = this._clean(a)
      if (!title) continue
      if (keyword && title.indexOf(keyword) < 0 && cat[0].indexOf(keyword) < 0) continue
      list.push({ bookId: this._abs(this._attr(a, 'href'), cat[1]), title, cover: this._abs(this._attr(img, 'src'), cat[1]), author: cat[0], intro: this._clean((block.match(/<span\b[^>]*>([\s\S]*?)<\/span>/i) || [])[1] || '') })
      if (list.length >= pageSize) break
    }
    return { list, page, maxPage: 1, hasMore: false }
  },

  async getChapters(bookId, page = 1, pageSize = 30) {
    const html = await this._request(bookId)
    const all = []
    const re = /<a\b[^>]*href=["']([^"']+)["'][^>]*>([\s\S]*?)<\/a>/gi
    let m
    while ((m = re.exec(html)) !== null) {
      if (html.lastIndexOf('book-list', m.index) < 0) continue
      const title = this._clean(m[2])
      if (title) all.push({ href: this._abs(m[1], bookId), title })
    }
    const maxPage = Math.max(1, Math.ceil(all.length / pageSize))
    const start = (page - 1) * pageSize
    return { info: { title: '', cover: '', author: '', trackCount: all.length, isFinished: true }, list: all.slice(start, start + pageSize).map((x, i) => ({ chapterId: x.href, index: start + i + 1, name: x.title })), page, maxPage, hasMore: page < maxPage }
  },

  async getAudioUrl(chapterId) {
    const html = await this._request(String(chapterId))
    const audio = (html.match(/<audio[\s\S]*?<source\b[^>]*src=["']([^"']+)["']/i) || html.match(/<audio\b[^>]*src=["']([^"']+)["']/i) || [])[1] || ''
    if (!audio) throw new Error('未找到 audio source')
    return { url: this._abs(audio, String(chapterId)), headers: { Referer: String(chapterId), 'User-Agent': this._ua } }
  }
})
