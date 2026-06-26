// tingshu_json: LetingWorkerSource
({
  name: '乐听网（Worker）',
  id: 'tingshu-json-leting',
  apiVersion: 1,
  _site: 'https://www.leting.vip',
  _worker: 'https://audiocdn.966001.xyz',
  _pwd: 'admin123',
  _ua: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36',

  _request(url, headers) {
    return new Promise((resolve, reject) => {
      uni.request({ url, method: 'GET', header: Object.assign({ 'User-Agent': this._ua, Referer: this._site + '/' }, headers || {}), timeout: 30000,
        success: r => r.statusCode >= 200 && r.statusCode < 300 ? resolve(r.data) : reject(new Error('HTTP ' + r.statusCode + ' | ' + url)),
        fail: e => reject(new Error(e.errMsg || '网络失败')) })
    })
  },
  _decode(s) { return String(s || '').replace(/&#(\d+);/g, (_, n) => String.fromCharCode(parseInt(n, 10))).replace(/&nbsp;/g, ' ').replace(/&amp;/g, '&').replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&lt;/g, '<').replace(/&gt;/g, '>') },
  _clean(s) { return this._decode(String(s || '').replace(/<script[\s\S]*?<\/script>/gi, ' ').replace(/<style[\s\S]*?<\/style>/gi, ' ').replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ')).trim() },
  _attr(tag, name) { const m = String(tag || '').match(new RegExp(name + "\\s*=\\s*(\"([^\"]*)\"|'([^']*)'|([^\\s>]+))", 'i')); return m ? this._decode(m[2] || m[3] || m[4] || '') : '' },
  _abs(url, base) { url = this._decode(String(url || '').trim()); if (!url) return ''; if (/^https?:\/\//i.test(url)) return url; if (url.startsWith('//')) return 'https:' + url; if (url[0] === '/') return this._site + url; return String(base || this._site + '/').replace(/[#?].*$/, '').replace(/\/[^/]*$/, '/') + url },
  _host(base) { return String(base || this._worker).replace(/^https?:\/\//, '').replace(/\/.*$/, '') },
  _workerUrl(path) { const sep = path.indexOf('?') >= 0 ? '&' : '?'; return this._worker + '/' + path.replace(/^\/+/, '') + sep + 'pwd=' + encodeURIComponent(this._pwd) + '&host=' + encodeURIComponent(this._host(this._worker)) },
  _ensureWorker(url) { let out = String(url || ''); if (!/[?&]pwd=/.test(out)) out += (out.indexOf('?') >= 0 ? '&' : '?') + 'pwd=' + encodeURIComponent(this._pwd); if (!/[?&]host=/.test(out)) out += '&host=' + encodeURIComponent(this._host(out)); return out },
  _first(s, re) { const m = String(s || '').match(re); return m ? (m[1] || '') : '' },

  _booksFromWorker(raw) {
    const root = typeof raw === 'string' ? JSON.parse(raw) : (raw || {})
    const json = root.data || root
    const arr = json.books || root.books || json.content || root.content || []
    return (Array.isArray(arr) ? arr : []).map(item => ({ bookId: this._abs(item.bookUrl || item.tocUrl || item.url || '', this._worker), title: this._clean(item.name || item.title || item.bookName || ''), cover: item.coverUrl || item.thumb || item.cover || '', author: this._clean(item.author || item.artist || item.announcer || ''), intro: this._clean(item.intro || item.desc || '') })).filter(x => x.bookId && x.title)
  },
  _parseBooks(html, base) {
    const list = [], seen = {}
    const re = /<a\b[^>]*href=["']([^"']*\/book\/[^"']+)["'][^>]*>[\s\S]*?<\/a>/gi
    let m
    while ((m = re.exec(html)) !== null) {
      const href = this._abs(m[1], base)
      if (!href || seen[href] || /\/bookdir\/|lastupdate/i.test(href)) continue
      const block = m[0]
      const img = this._first(block, /<img\b[^>]*>/i)
      const title = this._clean(this._attr(img, 'alt') || this._attr(block, 'title') || block)
      if (!title) continue
      seen[href] = true
      list.push({ bookId: href, title, cover: this._abs(this._attr(img, 'data-original') || this._attr(img, 'src'), base), author: '', intro: '' })
    }
    return list
  },
  _episodes(raw, base) {
    const root = typeof raw === 'string' ? JSON.parse(raw) : (raw || {})
    const json = root.data || root
    const arr = json.chapters || root.chapters || json.list || root.list || []
    return (Array.isArray(arr) ? arr : []).map((item, i) => ({ chapterId: this._abs(item.url || item.chapterUrl || item.href || '', base || this._site), index: i + 1, name: this._clean(item.name || item.title || '') })).filter(x => x.chapterId && x.name)
  },

  async search(keyword, page = 1, pageSize = 20) {
    const raw = await this._request(this._workerUrl('leting/search-json?key=' + encodeURIComponent(keyword)))
    const list = this._booksFromWorker(raw).slice(0, pageSize)
    return { list, page, maxPage: 1, hasMore: false }
  },

  async getChapters(bookId, page = 1, pageSize = 30) {
    const html = await this._request(bookId, { Referer: this._site + '/' })
    const dir = this._first(html, /class=["'][^"']*dirurl[^"']*["'][^>]+href=["']([^"']+)["']/i) || this._first(html, /href=["']([^"']*\/bookdir\/[^"']+)["']/i)
    let all = []
    if (dir) {
      const api = this._workerUrl('leting/toc-json?url=' + encodeURIComponent(this._abs(dir, bookId)) + '&referer=' + encodeURIComponent(bookId))
      all = this._episodes(await this._request(api, { Referer: bookId }), this._site)
    } else {
      const re = /<a\b[^>]*href=["']([^"']*\/tingshu\/[^"']+)["'][^>]*>([\s\S]*?)<\/a>/gi
      let m
      while ((m = re.exec(html)) !== null) all.push({ chapterId: this._abs(m[1], bookId), name: this._clean(m[2]) })
    }
    const maxPage = Math.max(1, Math.ceil(all.length / pageSize))
    const start = (page - 1) * pageSize
    return { info: { title: this._clean(this._first(html, /<h1[^>]*>([\s\S]*?)<\/h1>/i)), cover: this._abs(this._first(html, /<img\b[^>]*(?:data-original|src)=["']([^"']+)["'][^>]*>/i), bookId), author: '', trackCount: all.length, isFinished: true }, list: all.slice(start, start + pageSize).map((x, i) => ({ chapterId: x.chapterId, index: start + i + 1, name: x.name })), page, maxPage, hasMore: page < maxPage }
  },

  async getAudioUrl(chapterId) {
    const path = String(chapterId).replace(/^https?:\/\/[^/]+/, '')
    const api = this._workerUrl('leting/audio?episode=' + encodeURIComponent(path))
    const raw = await this._request(api, { Referer: this._site + '/' })
    const json = (typeof raw === 'string' ? JSON.parse(raw) : raw).data || (typeof raw === 'string' ? JSON.parse(raw) : raw)
    return json.url || json.proxyUrl || this._workerUrl('leting/stream?episode=' + encodeURIComponent(path))
  }
})
