// eprendre: KouDaiWeiKeTang
({
  name: '口袋微课堂',
  id: 'eprendre-koudai-weiketang',
  version: 1,
  apiVersion: 1,
  _site: 'http://www.xiai123.com',
  _ua: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
  _roots: [
    'http://www.xiai123.com/index.html',
    'http://www.xiai123.com/yilinbanyingyu.html',
    'http://www.xiai123.com/rjpep.html',
    'http://www.xiai123.com/rjxiaoxueyuwen.html',
    'http://www.xiai123.com/zhonghuashangxiawuqiannian.html'
  ],
  _request(url, headers) {
    return new Promise((resolve, reject) => {
      uni.request({ url, method: 'GET', header: Object.assign({ 'User-Agent': this._ua, Referer: this._site + '/' }, headers || {}), timeout: 20000,
        success: r => r.statusCode >= 200 && r.statusCode < 300 ? resolve(String(r.data || '')) : reject(new Error('HTTP ' + r.statusCode + ' | ' + url)),
        fail: e => reject(new Error(e.errMsg || '网络失败')) })
    })
  },
  _clean(s) { return String(s || '').replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ').trim() },
  _attr(tag, name) { const m = String(tag || '').match(new RegExp(name + "\\s*=\\s*(\"([^\"]*)\"|'([^']*)'|([^\\s>]+))", 'i')); return m ? (m[2] || m[3] || m[4] || '') : '' },
  _abs(url, base) { url = String(url || '').trim(); if (/^https?:\/\//i.test(url)) return url; if (url[0] === '/') return this._site + url; return String(base || this._site + '/').replace(/\/[^/]*$/, '/') + url },

  async search(keyword, page = 1, pageSize = 20) {
    if (page > 1) return { list: [], page, maxPage: 1, hasMore: false }
    const list = []
    for (const root of this._roots) {
      try {
        const html = await this._request(root)
        const re = /<a\b[^>]*href=["']([^"']+)["'][^>]*>[\s\S]*?<\/a>/gi
        let m
        while ((m = re.exec(html)) !== null) {
          const block = m[0]
          const href = this._abs(m[1], root)
          if (href === this._site + '/kewen.html') continue
          const title = this._clean(block)
          if (!title || (keyword && title.indexOf(keyword) < 0 && keyword.indexOf('英语') < 0 && keyword.indexOf('语文') < 0)) continue
          const img = (block.match(/<img\b[^>]*>/i) || [])[0] || ''
          list.push({ bookId: href, title, cover: this._abs(this._attr(img, 'src'), root), author: '', intro: '口袋微课堂' })
          if (list.length >= pageSize) break
        }
      } catch (e) {}
      if (list.length >= pageSize) break
    }
    return { list, page, maxPage: 1, hasMore: false }
  },

  async getChapters(bookId, page = 1, pageSize = 30) {
    const html = await this._request(bookId)
    const scripts = []
    const re = /<script\b[^>]*src=["']([^"']+)["'][^>]*><\/script>/gi
    let m
    while ((m = re.exec(html)) !== null) {
      const src = this._abs(m[1], bookId)
      if (/^https?:\/\//i.test(src)) scripts.push(src)
    }
    let all = []
    for (const src of scripts) {
      try {
        const js = await this._request(src, { Referer: bookId })
        const arrText = (js.replace(/\r?\n/g, '').match(/(\[[\s\S]*?\])/i) || [])[1] || ''
        if (!arrText) continue
        const normalized = arrText
          .replace(/'/g, '"')
          .replace(/([{,]\s*)title\s*:/g, '$1"title":')
          .replace(/([{,]\s*)singer\s*:/g, '$1"singer":')
          .replace(/([{,]\s*)cover\s*:/g, '$1"cover":')
          .replace(/([{,]\s*)src\s*:/g, '$1"src":')
        const rows = JSON.parse(normalized)
        if (Array.isArray(rows) && rows.length) {
          all = rows.map(x => ({ title: x.title || x.singer || '', url: x.src || '', cover: x.cover || '' })).filter(x => x.url)
          break
        }
      } catch (e) {}
    }
    const maxPage = Math.max(1, Math.ceil(all.length / pageSize))
    const start = (page - 1) * pageSize
    return { info: { title: '', cover: all[0] ? all[0].cover : '', author: '', trackCount: all.length, isFinished: true }, list: all.slice(start, start + pageSize).map((x, i) => ({ chapterId: x.url, index: start + i + 1, name: x.title || ('第' + (start + i + 1) + '课') })), page, maxPage, hasMore: page < maxPage }
  },

  async getAudioUrl(chapterId) {
    const url = String(chapterId)
    return { url: encodeURI(url), headers: { Host: (url.match(/^https?:\/\/([^/]+)/i) || [])[1] || 'www.xiai123.com', Referer: this._site + '/', 'User-Agent': this._ua } }
  }
})
