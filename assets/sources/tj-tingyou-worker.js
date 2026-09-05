// tingshu_json: TingyouWorkerSource
({
  name: '听友FM（Worker）',
  id: 'tingshu-json-tingyou',
  version: 1,
  apiVersion: 1,
  _worker: 'https://audiocdn.966001.xyz',
  _pwd: 'admin123',
  _ua: 'Mozilla/5.0 (Linux; Android 13; Mobile) AppleWebKit/537.36 Chrome/147.0 Mobile Safari/537.36',

  _request(url, headers) {
    return new Promise((resolve, reject) => {
      uni.request({
        url,
        method: 'GET',
        header: Object.assign({ 'User-Agent': this._ua, Referer: this._worker + '/' }, headers || {}),
        timeout: 30000,
        success: r => {
          if (r.statusCode < 200 || r.statusCode >= 300) return reject(new Error('HTTP ' + r.statusCode + ' | ' + url))
          resolve(r.data)
        },
        fail: e => reject(new Error(e.errMsg || '网络失败'))
      })
    })
  },
  _clean(s) { return String(s || '').replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ').trim() },
  _host(base) { return String(base || this._worker).replace(/^https?:\/\//, '').replace(/\/.*$/, '') },
  _workerUrl(path, base) {
    base = (base || this._worker).replace(/\/+$/, '')
    const sep = path.indexOf('?') >= 0 ? '&' : '?'
    return base + '/' + String(path).replace(/^\/+/, '') + sep + 'pwd=' + encodeURIComponent(this._pwd) + '&host=' + encodeURIComponent(this._host(base))
  },
  _ensureWorker(url) {
    let out = String(url || '')
    if (!out) return out
    if (!/[?&]pwd=/.test(out)) out += (out.indexOf('?') >= 0 ? '&' : '?') + 'pwd=' + encodeURIComponent(this._pwd)
    if (!/[?&]host=/.test(out)) out += '&host=' + encodeURIComponent(this._host(out))
    return out
  },
  _abs(url, base) {
    url = String(url || '').trim()
    if (!url) return ''
    if (/^https?:\/\//i.test(url)) return url
    if (url.startsWith('//')) return 'https:' + url
    if (url[0] === '/') return String(base || this._worker).replace(/\/+$/, '') + url
    return url
  },
  _books(raw) {
    const root = typeof raw === 'string' ? JSON.parse(raw) : (raw || {})
    const json = root.data || root
    const arr = json.books || root.books || json.content || root.content || []
    return (Array.isArray(arr) ? arr : []).map(item => {
      const title = item.name || item.title || item.bookName || ''
      const bookUrl = item.bookUrl || item.tocUrl || item.url || ''
      return {
        bookId: this._abs(bookUrl, this._worker),
        title: this._clean(title),
        cover: item.coverUrl || item.thumb || item.cover || '',
        author: this._clean(item.author || item.artist || item.announcer || ''),
        intro: this._clean(item.intro || item.desc || item.kind || item.status || '')
      }
    }).filter(x => x.bookId && x.title)
  },
  _episodes(raw, base) {
    const root = typeof raw === 'string' ? JSON.parse(raw) : (raw || {})
    const json = root.data || root
    const arr = json.chapters || root.chapters || json.list || root.list || []
    return (Array.isArray(arr) ? arr : []).map((item, i) => ({
      chapterId: this._abs(item.url || item.chapterUrl || item.href || '', base || this._worker),
      index: i + 1,
      name: this._clean(item.name || item.title || '')
    })).filter(x => x.chapterId && x.name)
  },

  async search(keyword, page = 1, pageSize = 20) {
    const raw = await this._request(this._workerUrl('tingyou/search?key=' + encodeURIComponent(keyword)))
    const list = this._books(raw).slice(0, pageSize)
    return { list, page, maxPage: 1, hasMore: false }
  },

  async getChapters(bookId, page = 1, pageSize = 30) {
    const detail = await this._request(this._ensureWorker(bookId))
    const json = (typeof detail === 'string' ? JSON.parse(detail) : detail).data || (typeof detail === 'string' ? JSON.parse(detail) : detail)
    let tocUrl = json.tocUrl || ''
    if (!tocUrl) {
      const id = json.id || (String(bookId).match(/[?&]id=([^&]+)/) || [])[1] || ''
      if (id) tocUrl = this._workerUrl('tingyou/toc?id=' + encodeURIComponent(decodeURIComponent(id)))
    }
    const toc = tocUrl ? await this._request(this._ensureWorker(tocUrl)) : { list: [] }
    const all = this._episodes(toc, this._worker)
    const maxPage = Math.max(1, Math.ceil(all.length / pageSize))
    const start = (page - 1) * pageSize
    return {
      info: { title: this._clean(json.name || json.title || ''), cover: json.coverUrl || json.cover || '', author: this._clean(json.author || json.artist || ''), trackCount: Number(json.count || all.length) || all.length, isFinished: true },
      list: all.slice(start, start + pageSize).map((x, i) => ({ chapterId: x.chapterId, index: start + i + 1, name: x.name })),
      page, maxPage, hasMore: page < maxPage
    }
  },

  async getAudioUrl(chapterId) {
    const raw = await this._request(this._ensureWorker(chapterId))
    const json = (typeof raw === 'string' ? JSON.parse(raw) : raw).data || (typeof raw === 'string' ? JSON.parse(raw) : raw)
    return json.proxyUrl || json.url || String(chapterId)
  }
})
