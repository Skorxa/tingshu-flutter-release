// eprendre: IFish
({
  name: '洛奇Town',
  id: 'eprendre-ifish',
  version: 1,
  apiVersion: 1,
  _site: 'https://ifish.fun',
  _ua: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',

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
    if (keyword && keyword.indexOf('云村') >= 0) return { list: [{ bookId: this._site + '/music/daily?t=wy', title: '云村部落', cover: '', author: '', intro: '' }], page: 1, maxPage: 1, hasMore: false }
    const root = keyword && keyword.indexOf('落网') >= 0 ? this._site + '/music/luoo' : this._site + '/music/fish'
    const url = page <= 1 ? root : root + '?p=' + page
    const html = await this._request(url)
    const list = []
    const re = /<div\b[^>]*>[\s\S]*?<\/div>/gi
    let m
    while ((m = re.exec(html)) !== null) {
      const block = m[0]
      if (block.indexOf('item-title') < 0) continue
      const a = (block.match(/<a\b[\s\S]*?<\/a>/i) || [])[0] || ''
      const title = this._clean((block.match(/class=["'][^"']*item-title[^"']*["'][^>]*>([\s\S]*?)<\/[^>]+>/i) || [])[1] || a)
      if (!title || (keyword && title.indexOf(keyword) < 0 && keyword.indexOf('音乐') < 0)) continue
      const style = (block.match(/style=["']([^"']+)["']/i) || [])[1] || ''
      const cover = (style.match(/url\(([^)]+)\)/i) || [])[1] || ''
      list.push({ bookId: this._abs(this._attr(a, 'href'), url), title, cover, author: '', intro: this._clean((block.match(/class=["'][^"']*item-summary[^"']*["'][^>]*>([\s\S]*?)<\/[^>]+>/i) || [])[1] || '') })
      if (list.length >= pageSize) break
    }
    const hasMore = /下一页/.test(html)
    return { list, page, maxPage: hasMore ? page + 1 : page, hasMore }
  },

  async getChapters(bookId, page = 1, pageSize = 30) {
    const html = await this._request(bookId)
    const all = []
    const re = /<li\b[^>]*>[\s\S]*?<\/li>/gi
    let m
    while ((m = re.exec(html)) !== null) {
      const block = m[0]
      if (block.indexOf('player-list-url') < 0) continue
      const url = this._clean((block.match(/class=["'][^"']*player-list-url[^"']*["'][^>]*>([\s\S]*?)<\/[^>]+>/i) || [])[1] || '')
      const name = this._clean((block.match(/class=["'][^"']*player-list-name[^"']*["'][^>]*>([\s\S]*?)<\/[^>]+>/i) || [])[1] || '')
      const author = this._clean((block.match(/class=["'][^"']*player-list-author[^"']*["'][^>]*>([\s\S]*?)<\/[^>]+>/i) || [])[1] || '')
      if (url) all.push({ url: this._abs(url, bookId), title: name + (author ? ' - ' + author : '') })
    }
    const maxPage = Math.max(1, Math.ceil(all.length / pageSize))
    const start = (page - 1) * pageSize
    return { info: { title: '', cover: '', author: '', trackCount: all.length, isFinished: true }, list: all.slice(start, start + pageSize).map((x, i) => ({ chapterId: x.url, index: start + i + 1, name: x.title || ('第' + (start + i + 1) + '首') })), page, maxPage, hasMore: page < maxPage }
  },

  async getAudioUrl(chapterId) { return String(chapterId) }
})
