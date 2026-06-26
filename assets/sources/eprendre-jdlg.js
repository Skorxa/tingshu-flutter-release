// eprendre: JDLG
({
  name: '经典老歌',
  id: 'eprendre-jdlg',
  apiVersion: 1,
  _site: 'http://www.jdlg.net',
  _ua: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
  _request(url) {
    return new Promise((resolve, reject) => {
      uni.request({ url, method: 'GET', header: { 'User-Agent': this._ua }, timeout: 25000,
        success: r => r.statusCode >= 200 && r.statusCode < 300 ? resolve(String(r.data || '')) : reject(new Error('HTTP ' + r.statusCode + ' | ' + url)),
        fail: e => reject(new Error(e.errMsg || '网络失败')) })
    })
  },
  _clean(s) { return String(s || '').replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ').trim() },
  _attr(tag, name) { const m = String(tag || '').match(new RegExp(name + "\\s*=\\s*(\"([^\"]*)\"|'([^']*)'|([^\\s>]+))", 'i')); return m ? (m[2] || m[3] || m[4] || '') : '' },
  _abs(url, base) { url = String(url || '').trim(); if (/^https?:\/\//i.test(url)) return url; if (url[0] === '/') return this._site + url; return String(base || this._site + '/').replace(/\/[^/]*$/, '/') + url },

  async search(keyword, page = 1, pageSize = 20) {
    if (page > 1) return { list: [], page, maxPage: 1, hasMore: false }
    const url = this._site + '/jingdianlaoge500shou/'
    const html = await this._request(url)
    const list = []
    const re = /<a\b[^>]*href=["']([^"']+)["'][^>]*>([\s\S]*?)<\/a>/gi
    let m
    while ((m = re.exec(html)) !== null) {
      const title = this._clean(m[2])
      if (!title || (keyword && title.indexOf(keyword) < 0 && keyword.indexOf('老歌') < 0)) continue
      list.push({ bookId: this._abs(m[1], url), title, cover: '', author: '', intro: '经典老歌分类/排行' })
      if (list.length >= pageSize) break
    }
    return { list, page, maxPage: 1, hasMore: false }
  },

  async getChapters(bookId, page = 1, pageSize = 30) {
    const html = await this._request(bookId)
    const all = []
    const re = /<li\b[^>]*>[\s\S]*?<\/li>/gi
    let m
    while ((m = re.exec(html)) !== null) {
      const block = m[0]
      const a = (block.match(/class=["'][^"']*(?:singer_title|songName)[^"']*["'][\s\S]*?(<a\b[\s\S]*?<\/a>)/i) || block.match(/(<a\b[\s\S]*?<\/a>)/i) || [])[1] || ''
      const title = this._clean(a)
      if (!title) continue
      all.push({ href: this._abs(this._attr(a, 'href'), bookId), title })
    }
    const maxPage = Math.max(1, Math.ceil(all.length / pageSize))
    const start = (page - 1) * pageSize
    return { info: { title: '', cover: '', author: '', trackCount: all.length, isFinished: true }, list: all.slice(start, start + pageSize).map((x, i) => ({ chapterId: x.href, index: start + i + 1, name: x.title })), page, maxPage, hasMore: page < maxPage }
  },

  async getAudioUrl(chapterId) {
    return { sniff: true, url: String(chapterId), headers: { 'User-Agent': this._ua, Referer: this._site + '/' }, waitMs: 3000, audioPatterns: ['.mp3', '.m4a'] }
  }
})
