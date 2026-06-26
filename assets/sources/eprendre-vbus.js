// eprendre: VBus
({
  name: '声音巴士',
  id: 'eprendre-vbus',
  apiVersion: 1,
  _site: 'https://www.vbus.cc',
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
    const mode = keyword && keyword.indexOf('热') >= 0 ? 'hot' : (keyword && keyword.indexOf('新') >= 0 ? 'new' : 'recommend')
    const url = this._site + '/' + mode + '/' + page
    const html = await this._request(url)
    const list = []
    const re = /<li\b[^>]*>[\s\S]*?<\/li>/gi
    let m
    while ((m = re.exec(html)) !== null) {
      const block = m[0]
      if (block.indexOf('program-meta') < 0) continue
      const a = (block.match(/<h3[^>]*>\s*(<a\b[\s\S]*?<\/a>)/i) || [])[1] || ''
      const href = this._attr(a, 'href')
      const title = this._clean(a)
      if (!href || !title) continue
      if (keyword && mode === 'recommend' && title.indexOf(keyword) < 0) continue
      list.push({ bookId: this._abs(href, url), title, cover: '', author: '', intro: this._clean((block.match(/class=["'][^"']*program-meta[^"']*["'][^>]*>([\s\S]*?)<\/[^>]+>/i) || [])[1] || '') })
      if (list.length >= pageSize) break
    }
    const hasMore = /下一页/.test(html)
    return { list, page, maxPage: hasMore ? page + 1 : page, hasMore }
  },

  async getChapters(bookId) {
    return { info: { title: '', cover: '', author: '', trackCount: 1, isFinished: true }, list: [{ chapterId: bookId, index: 1, name: '音频' }], page: 1, maxPage: 1, hasMore: false }
  },

  async getAudioUrl(chapterId) {
    const html = await this._request(String(chapterId))
    const audio = (html.match(/<audio\b[^>]*src=["']([^"']+)["']/i) || html.match(/<source\b[^>]*src=["']([^"']+)["']/i) || [])[1] || ''
    if (!audio) throw new Error('未找到 audio src')
    return { url: this._abs(audio, String(chapterId)), headers: { Referer: String(chapterId), 'User-Agent': this._ua } }
  }
})
