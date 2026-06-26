// eprendre: LanRenTingShu
({
  name: '懒人听书',
  id: 'eprendre-lanren',
  apiVersion: 1,
  loginUrl: 'https://m.lrts.me/user',
  login: { url: 'https://m.lrts.me/user', configKey: 'cookie' },
  configFields: [
    { key: 'cookie', label: '懒人 Cookie', type: 'textarea', hint: '可通过音源登录页自动获取。', login: true, required: false }
  ],
  _site: 'https://m.lrts.me',
  _ua: 'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Mobile Safari/537.36',

  _headers(extra) {
    const cookie = (this.config && this.config.cookie) || uni.getStorageSync('cookie') || ''
    const headers = Object.assign({ 'User-Agent': this._ua, Referer: this._site + '/' }, extra || {})
    if (cookie) headers.Cookie = cookie
    return headers
  },

  _request(url, headers) {
    return new Promise((resolve, reject) => {
      uni.request({
        url,
        method: 'GET',
        header: this._headers(headers),
        timeout: 20000,
        success: r => {
          if (r.statusCode < 200 || r.statusCode >= 300) return reject(new Error('HTTP ' + r.statusCode + ' | ' + url))
          resolve(r.data)
        },
        fail: e => reject(new Error(e.errMsg || '网络失败'))
      })
    })
  },

  _cover(url) {
    url = String(url || '')
    if (!url || url.indexOf('180') >= 0 || url.lastIndexOf('.') <= 0) return url
    const i = url.lastIndexOf('.')
    return url.slice(0, i) + '_180x254' + url.slice(i)
  },

  _book(item) {
    const tags = JSON.stringify(item.tags || [])
    const prefix = tags.indexOf('VIP') >= 0 ? '[VIP] ' : (tags.indexOf('精品') >= 0 ? '[精品] ' : '')
    return {
      bookId: this._site + '?' + String(item.id || ''),
      title: prefix + (item.name || ''),
      cover: this._cover(item.cover),
      author: item.author || item.announcer || '',
      intro: item.sections ? ('共' + item.sections + '章') : (item.desc || item.recReason || '')
    }
  },

  async search(keyword, page = 1, pageSize = 20) {
    const url = this._site + '/ajax/search?keyWord=' + encodeURIComponent(keyword) +
      '&pageSize=40&pageNum=' + page + '&searchOption=1'
    const res = await this._request(url)
    const bookResult = res && res.data && res.data.bookResult ? res.data.bookResult : {}
    const rows = Array.isArray(bookResult.list) ? bookResult.list : []
    const maxPage = Math.max(1, Math.ceil((Number(bookResult.count || rows.length) || rows.length) / 40))
    return { list: rows.map(item => this._book(item)).slice(0, pageSize), page, maxPage, hasMore: page < maxPage }
  },

  async getChapters(bookId, page = 1, pageSize = 30) {
    const id = String(bookId).split('?').pop()
    const url = this._site + '/ajax/getBookMenu?bookId=' + encodeURIComponent(id) +
      '&pageNum=' + page + '&pageSize=' + pageSize + '&sortType=0'
    const res = await this._request(url)
    const rows = Array.isArray(res.list) ? res.list : []
    const sections = Number(res.sections || rows.length) || rows.length
    const maxPage = Math.max(1, Math.ceil(sections / pageSize))
    return {
      info: { title: '', cover: '', author: '', trackCount: sections, isFinished: false },
      list: rows.map((track, i) => {
        const idx = (page - 1) * pageSize + i
        const isFree = Number(track.payType || 0) === 0
        const chapterUrl = isFree
          ? this._site + '/ajax/getPlayPath?entityId=' + id + '&entityType=3&opType=1&sections=[' + track.section + ']&type=0'
          : this._site + '/player?index=' + idx + '&entityType=3&sonId=' + track.id + '&id=' + id
        return { chapterId: chapterUrl, index: idx + 1, name: track.name || ('第' + (idx + 1) + '集') }
      }),
      page,
      maxPage,
      hasMore: page < maxPage
    }
  },

  async getAudioUrl(chapterId) {
    const url = String(chapterId)
    if (url.indexOf('/ajax/getPlayPath') >= 0) {
      const res = await this._request(url)
      const list = Array.isArray(res.list) ? res.list : []
      const path = list[0] && list[0].path
      if (path) return { url: path, headers: this._headers({ Accept: 'audio/*,*/*;q=0.8' }) }
      throw new Error('懒人免费音频解析失败')
    }
    return {
      sniff: true,
      url,
      headers: this._headers(),
      waitMs: 3500,
      audioPatterns: ['.m4a', '.mp3', '.aac', '.m3u8']
    }
  }
})
