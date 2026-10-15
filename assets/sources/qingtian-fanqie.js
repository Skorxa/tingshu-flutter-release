// 青天聚合 · 番茄畅听听书
// 聚合接口：https://v1-v7.qingtian618.com（2026-09 由 v1-v7.gyks.cf 迁移而来）
//
// 鉴权：免登录可用（搜索/目录/发现页），但「取流」每日仅 10 次；
// 在音源设置中填写登录后的 Cookie 可解除该限制。
({
  name: '青天·番茄',
  id: 'qt-fanqie',
  version: 2,
  apiVersion: 1,
  loginUrl: 'https://v1.qingtian618.com/login',
  login: { url: 'https://v1.qingtian618.com/login', configKey: 'qt_cookie' },
  configFields: [
    {
      key: 'qt_cookie', label: '青天 Cookie（可选）', type: 'textarea', login: true, required: false,
      hint: '可不填：免登录即可搜索、浏览目录与发现页，但「取流」每日仅 10 次。' +
        '填写登录后的 Cookie 可解除该限制。格式：deviceId=xxx; qttoken=xxx。'
    }
  ],
  _bases: [
    'https://v1.qingtian618.com',
    'https://v2.qingtian618.com',
    'https://v3.qingtian618.com',
    'https://v4.qingtian618.com',
    'https://v5.qingtian618.com',
    'https://v6.qingtian618.com',
    'https://v7.qingtian618.com'
  ],
  _sub: '番茄',
  _tab: '听书',
  _ua: 'okhttp/4.9.2',

  _cookie() {
    return (this.config && this.config.qt_cookie) ||
      uni.getStorageSync('qt_cookie') ||
      uni.getStorageSync('cookie') ||
      ''
  },
  _url(base, path, params) {
    const qs = Object.entries(params || {})
      .filter(([, v]) => v !== undefined && v !== null && v !== '')
      .map(([k, v]) => k + '=' + encodeURIComponent(v)).join('&')
    return base.replace(/\/+$/, '') + path + (qs ? (path.indexOf('?') >= 0 ? '&' : '?') + qs : '')
  },
  _get(path, params = {}) {
    const ck = this._cookie()
    const headers = { 'User-Agent': this._ua }
    if (ck) headers.Cookie = ck
    const bases = this._bases.slice()
    let lastError = ''
    let lastStatus = 0
    const tryAt = (i, resolve, reject) => {
      if (i >= bases.length) {
        const err = new Error(lastError || '接口请求失败')
        err.statusCode = lastStatus
        return reject(err)
      }
      const url = this._url(bases[i], path, params)
      uni.request({
        url, method: 'GET', header: headers, timeout: 15000,
        success: r => {
          const body = typeof r.data === 'string' ? r.data : ''
          if (r.statusCode === 401 || r.statusCode === 403 || r.statusCode === 502 ||
            /error code:\s*\d{3}/i.test(body)) {
            lastStatus = r.statusCode
            const err = new Error('鉴权失败｜账号 Cookie 无效或已过期，请在音源设置中更新（服务端 HTTP ' +
              r.statusCode + ' ' + body.slice(0, 80).trim() + '）')
            err.statusCode = r.statusCode
            err.authFailed = true
            return reject(err)
          }
          if (r.statusCode !== 200) {
            lastStatus = r.statusCode
            lastError = 'HTTP ' + r.statusCode + ' | ' + url
            tryAt(i + 1, resolve, reject)
            return
          }
          let d = r.data
          if (typeof d === 'string') { try { d = JSON.parse(d) } catch (e) {} }
          // 免登录额度用尽：{"code":-1,"msg":"您今日免登录访问次数已达上限(10次)！..."}
          // 新域名免登录即可搜索/看目录，但取流每日仅 10 次，需填 Cookie 解除。
          if (d && d.code === -1 && /上限|登录/.test(String(d.msg || ''))) {
            const err = new Error('青天免登录额度已用尽：' + d.msg +
              '｜请在音源设置中填写「青天 Cookie」以解除限制。')
            err.quotaExceeded = true
            return reject(err)
          }
          resolve(d)
        },
        fail: e => {
          lastError = (e && e.errMsg) || '网络失败'
          tryAt(i + 1, resolve, reject)
        }
      })
    }
    return new Promise((resolve, reject) => tryAt(0, resolve, reject))
  },
  _ok(res) { return res && (res.code === 0 || res.code === 200 || res.success === true || res.status === 200) },
  _rows(res) { return Array.isArray(res && res.data) ? res.data : [] },
  _toBook(it) {
    return {
      bookId: it.book_id || it.bookid || it.bookId || '',
      title: it.book_name || it.title || '',
      cover: it.thumb_url || it.cover || '',
      author: it.author || '',
      intro: it.abstract || it.category || ''
    }
  },

  async search(keyword, page = 1) {
    const res = await this._get('/search', { title: keyword, tab: this._tab, source: this._sub })
    if (!this._ok(res)) throw new Error('搜索失败 code=' + (res && res.code) + ' msg=' + ((res && res.msg) || ''))
    const list = this._rows(res)
      .filter(it => !it.source || it.source === this._sub)
      .map(it => this._toBook(it))
      .filter(x => x.bookId && x.title)
    return { list, page, maxPage: 1, hasMore: false }
  },

  async getChapters(bookId, page = 1) {
    const res = await this._get('/catalog', { book_id: bookId, source: this._sub, tab: this._tab })
    if (!this._ok(res)) throw new Error((res && res.msg) || '获取目录失败')
    const rows = this._rows(res)
    if (!rows.length) throw new Error('目录为空：该书在「番茄」暂无可用章节')
    const list = rows.map((it, i) => ({
      chapterId: it.item_id || it.itemId || it.content_url || '',
      index: i + 1,
      name: String(it.title || '').trim()
    })).filter(x => x.chapterId && x.name)
    return {
      info: { title: '', cover: '', author: '', trackCount: list.length, isFinished: true },
      list, page, maxPage: 1, hasMore: false
    }
  },

  async getAudioUrl(chapterId) {
    const s = String(chapterId)
    const res = (s.startsWith('/content') || s.startsWith('http'))
      ? await this._get(s.replace(/^https?:\/\/[^/]+/, ''))
      : await this._get('/content', { version: 5, source: this._sub, tab: this._tab, item_id: chapterId })
    if (!this._ok(res)) throw new Error((res && res.msg) || '获取音频失败')
    const u = res.content || res.url || (res.data && (res.data.content || res.data.url))
    if (!u || !String(u).startsWith('http')) throw new Error('该集无音频 raw=' + JSON.stringify(res).slice(0, 180))
    return { url: u, headers: { 'User-Agent': this._ua } }
  },

  // 从服务端 /discovestyle 拉取分类菜单（返回项自带 url，含 {{page}} 占位）
  // 注意：不要传 source_type，否则部分平台会退化成占位文案
  async _menu() {
    const res = await this._get('/discovestyle', { source: this._sub, tab: this._tab })
    const items = this._rows(res)
    const out = []
    const skip = ['点击登录可切换来源', '切换后长按刷新即可']
    for (const it of items) {
      const url = it && it.url
      if (!url || typeof url !== 'string') continue
      const title = String(it.title || '').trim()
      if (!title || skip.indexOf(title) >= 0 || /^--+$/.test(title)) continue
      out.push({ title, url })
    }
    return out
  },

  async discover() {
    // 分类菜单完全来自服务端 /discovestyle，不硬编码任何分类参数
    const MAX_SECTIONS = 10
    let menu = []
    try { menu = await this._menu() } catch (e) { return { sections: [] } }
    const out = []
    for (const m of menu.slice(0, MAX_SECTIONS)) {
      try {
        // 去掉 host，保留 path+query，交由 _get 做多线路容灾；{{page}} 替换为首页
        const p = m.url.replace(/^https?:\/\/[^/]+/, '').replace(/\{\{page\}\}/g, '1')
        const res = await this._get(p)
        const books = this._rows(res).map(it => this._toBook(it)).filter(x => x.bookId && x.title)
        if (books.length) out.push({ title: '番茄 · ' + m.title, list: books })
      } catch (e) { /* 单分类失败不影响整体 */ }
    }
    return { sections: out }
  }
})
