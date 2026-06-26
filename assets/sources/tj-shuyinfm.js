// tingshu_json: ShuyinFmSource
({
  name: '天下书音',
  id: 'tingshu-json-shuyinfm',
  apiVersion: 1,
  _site: 'https://m.shuyinfm.com',
  _ua: 'Mozilla/5.0 (Linux; Android 13; Mobile) AppleWebKit/537.36 Chrome/147.0 Mobile Safari/537.36',

  _request(url, method, data, headers) {
    return new Promise((resolve, reject) => {
      uni.request({ url, method: method || 'GET', data: data || null, header: Object.assign({ 'User-Agent': this._ua, Referer: this._site + '/' }, headers || {}), timeout: 30000,
        success: r => r.statusCode >= 200 && r.statusCode < 300 ? resolve(String(r.data || '')) : reject(new Error('HTTP ' + r.statusCode + ' | ' + url)),
        fail: e => reject(new Error(e.errMsg || '网络失败')) })
    })
  },
  _decode(s) { return String(s || '').replace(/&#(\d+);/g, (_, n) => String.fromCharCode(parseInt(n, 10))).replace(/&nbsp;/g, ' ').replace(/&amp;/g, '&').replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&lt;/g, '<').replace(/&gt;/g, '>') },
  _clean(s) { return this._decode(String(s || '').replace(/<script[\s\S]*?<\/script>/gi, ' ').replace(/<style[\s\S]*?<\/style>/gi, ' ').replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ')).trim() },
  _attr(tag, name) { const m = String(tag || '').match(new RegExp(name + "\\s*=\\s*(\"([^\"]*)\"|'([^']*)'|([^\\s>]+))", 'i')); return m ? this._decode(m[2] || m[3] || m[4] || '') : '' },
  _abs(url, base) { url = this._decode(String(url || '').trim()); if (!url) return ''; if (/^https?:\/\//i.test(url)) return url; if (url.startsWith('//')) return 'https:' + url; if (url[0] === '/') return this._site + url; return String(base || this._site + '/').replace(/[#?].*$/, '').replace(/\/[^/]*$/, '/') + url },
  _first(s, re) { const m = String(s || '').match(re); return m ? (m[1] || '') : '' },
  _parseBooks(html, base) {
    const list = []
    const re = /<li\b[^>]*class=["'][^"']*book-li[^"']*["'][^>]*>[\s\S]*?<\/li>/gi
    let m
    while ((m = re.exec(html)) !== null) {
      const block = m[0]
      const href = this._first(block, /<a\b[^>]*href=["']([^"']+)["']/i)
      const title = this._clean(this._first(block, /<h4[^>]*>([\s\S]*?)<\/h4>/i))
      if (!href || !title) continue
      const img = this._first(block, /<img\b[^>]*>/i)
      list.push({ bookId: this._abs(href, base), title, cover: this._abs(this._attr(img, 'data-original') || this._attr(img, 'data-src') || this._attr(img, 'src'), base), author: this._clean(this._first(block, /class=["'][^"']*book-meta[^"']*["'][^>]*>([\s\S]*?)<\/[^>]+>/i)), intro: this._clean(this._first(block, /<p[^>]*>([\s\S]*?)<\/p>/i)) })
    }
    return list
  },
  async search(keyword, page = 1, pageSize = 20) {
    const body = 'keyboard=' + encodeURIComponent(keyword) + '&show=title,newstext,player,playadmin,movietime,filetype'
    const html = await this._request(this._site + '/e/search/index.php', 'POST', body, { 'Content-Type': 'application/x-www-form-urlencoded' })
    return { list: this._parseBooks(html, this._site).slice(0, pageSize), page, maxPage: 1, hasMore: false }
  },
  async getChapters(bookId, page = 1, pageSize = 30) {
    const html = await this._request(bookId)
    const play = this._first(html, /<a\b[^>]*href=["']([^"']+)["'][^>]*>\s*立即播放\s*<\/a>/i)
    const tocUrl = play ? this._abs(play, bookId) : bookId
    const tocHtml = tocUrl === bookId ? html : await this._request(tocUrl)
    const all = []
    const re = /<a\b[^>]*href=["']([^"']+)["'][^>]*>([\s\S]*?)<\/a>/gi
    let m
    while ((m = re.exec(tocHtml)) !== null) {
      if (tocHtml.lastIndexOf('playlist', m.index) < 0) continue
      const name = this._clean(m[2])
      if (name) all.push({ chapterId: this._abs(m[1], tocUrl), name })
    }
    const maxPage = Math.max(1, Math.ceil(all.length / pageSize))
    const start = (page - 1) * pageSize
    return { info: { title: this._clean(this._first(html, /<h1[^>]*>([\s\S]*?)<\/h1>/i)), cover: this._abs(this._first(html, /<img\b[^>]*(?:data-original|data-src|src)=["']([^"']+)["'][^>]*>/i), bookId), author: '', trackCount: all.length, isFinished: true }, list: all.slice(start, start + pageSize).map((x, i) => ({ chapterId: x.chapterId, index: start + i + 1, name: x.name })), page, maxPage, hasMore: page < maxPage }
  },
  async getAudioUrl(chapterId) {
    return { sniff: true, url: String(chapterId), headers: { 'User-Agent': this._ua, Referer: this._site + '/' }, waitMs: 3500, audioPatterns: ['.mp3', '.m4a', '.aac', '.ogg', '.wav', '.flac', '.m3u8', '.mp4'] }
  }
})
