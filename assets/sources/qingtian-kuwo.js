// 青天聚合 · 酷我
({
  name: '青天·酷我',
  id: 'qt-kuwo',
  version: 1,
  apiVersion: 1,
  loginUrl: 'https://v1.gyks.cf/login',
  login: { url: 'https://v1.gyks.cf/login', configKey: 'qt_cookie' },
  configFields: [
    { key: 'qt_cookie', label: '青天 Cookie', type: 'textarea', hint: '可通过音源登录页自动获取。', login: true, required: true }
  ],
  _bases: [
    'https://v1.gyks.cf',
    'https://v2.gyks.cf',
    'https://v3.gyks.cf',
    'https://v4.gyks.cf',
    'https://v5.gyks.cf',
    'https://v6.gyks.cf',
    'https://v7.gyks.cf',
    'http://101.35.133.34:8888'
  ],
  _sub: 'svip_酷我',
  _ua: 'okhttp/4.9.2',
  _cookie() { return (this.config && this.config.qt_cookie) || uni.getStorageSync('qt_cookie') || uni.getStorageSync('cookie') || '' },
  _url(base, path, params) { const qs = Object.entries(params || {}).map(([k, v]) => k + '=' + encodeURIComponent(v)).join('&'); return base.replace(/\/+$/, '') + path + (qs ? (path.indexOf('?') >= 0 ? '&' : '?') + qs : '') },
  _get(path, params = {}) {
    const ck = this._cookie(), headers = { 'User-Agent': this._ua }; if (ck) headers.Cookie = ck
    let lastError = ''
    const tryAt = (i, resolve, reject) => {
      if (i >= this._bases.length) return reject(new Error(lastError || '接口请求失败'))
      const url = this._url(this._bases[i], path, params)
      uni.request({ url, method: 'GET', header: headers, timeout: 15000,
        success: r => { if (r.statusCode !== 200) { lastError = 'HTTP ' + r.statusCode + ' | ' + url; tryAt(i + 1, resolve, reject); return } let d = r.data; if (typeof d === 'string') { try { d = JSON.parse(d) } catch (e) {} } resolve(d) },
        fail: e => { lastError = (e && e.errMsg) || '网络失败'; tryAt(i + 1, resolve, reject) } })
    }
    return new Promise((resolve, reject) => tryAt(0, resolve, reject))
  },
  _ok(res) { return res && (res.code === 0 || res.code === 200 || res.success === true || res.status === 200) },
  async search(keyword, page = 1) {
    const res = await this._get('/search', { title: keyword, tab: '听书', source: this._sub })
    if (!this._ok(res)) throw new Error('搜索失败 code=' + (res && res.code) + ' msg=' + ((res && res.msg) || '') + ' raw=' + JSON.stringify(res).slice(0, 160))
    const rows = Array.isArray(res.data) ? res.data : []
    return { list: rows.filter(it => !it.source || it.source === this._sub).map(it => ({ bookId: it.book_id || it.bookid || it.bookId || '', title: it.book_name || it.title || '', cover: it.thumb_url || it.cover || '', author: it.author || '', intro: it.abstract || it.category || '' })).filter(x => x.bookId && x.title), page, maxPage: 1, hasMore: false }
  },
  async getChapters(bookId, page = 1) {
    const res = await this._get('/catalog', { book_id: bookId, source: this._sub, tab: '听书' })
    if (!this._ok(res)) throw new Error((res && res.msg) || '获取目录失败')
    const rows = Array.isArray(res.data) ? res.data : []
    return { info: { title: '', cover: '', author: '', trackCount: rows.length, isFinished: true }, list: rows.map((it, i) => ({ chapterId: it.item_id || it.itemId || it.content_url || '', index: i + 1, name: String(it.title || '').trim() })).filter(x => x.chapterId && x.name), page, maxPage: 1, hasMore: false }
  },
  async getAudioUrl(chapterId) {
    const s = String(chapterId)
    const res = s.startsWith('/content') || s.startsWith('http') ? await this._get(s.replace(/^https?:\/\/[^/]+/, '')) : await this._get('/content', { version: 5, source: this._sub, tab: '听书', item_id: chapterId })
    const u = res && (res.content || res.url || (res.data && (res.data.content || res.data.url)))
    if (!u || !String(u).startsWith('http')) throw new Error('无音频 raw=' + JSON.stringify(res).slice(0, 200))
    return { url: u, headers: { Cookie: this._cookie(), 'User-Agent': this._ua } }
  }
})
