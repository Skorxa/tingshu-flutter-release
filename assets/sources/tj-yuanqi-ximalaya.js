// tingshu_json: YuanQiXimalayaSource
({
  name: '元气听书-喜马拉雅',
  id: 'tingshu-json-yuanqi-ximalaya',
  apiVersion: 1,
  _api: 'https://music.haitangw.cc/tingshu/tingshu.php',
  _ua: 'okhttp/4.9.2',

  _request(data) {
    return new Promise((resolve, reject) => {
      uni.request({
        url: this._api,
        data,
        header: { 'User-Agent': this._ua },
        timeout: 30000,
        success: r => r.statusCode === 200 ? resolve(r.data) : reject(new Error('HTTP ' + r.statusCode)),
        fail: e => reject(new Error(e.errMsg || '网络失败'))
      })
    })
  },
  _clean(s) { return String(s || '').replace(/\s+/g, ' ').trim() },

  async search(keyword, page = 1, pageSize = 20) {
    const res = await this._request({ name: keyword, page, pageSize })
    const rows = Array.isArray(res.data) ? res.data : []
    const list = rows.map(item => ({
      bookId: String(item.itemId || ''),
      title: this._clean(item.title || ''),
      cover: item.cover || '',
      author: this._clean(item.nickname || ''),
      intro: this._clean(item.intro || '')
    })).filter(x => x.bookId && x.title)
    const maxPage = Number(res.maxPage || page) || page
    return { list, page: Number(res.page || page) || page, maxPage, hasMore: page < maxPage || !!res.hasMore }
  },

  async getChapters(bookId, page = 1, pageSize = 30) {
    const res = await this._request({ itemId: bookId, page, pageSize })
    const rows = Array.isArray(res.data) ? res.data : []
    const maxPage = Number(res.maxPage || page) || page
    const offset = (page - 1) * pageSize
    return {
      info: {
        title: this._clean(res.itemTitle || ''),
        cover: res.cover || '',
        author: this._clean(res.nickname || ''),
        trackCount: Number(res.trackCount || res.total || rows.length) || rows.length,
        isFinished: !!res.isFinished
      },
      list: rows.map((item, i) => ({
        chapterId: String(item.playId || ''),
        index: offset + i + 1,
        name: this._clean(item.title || '')
      })).filter(x => x.chapterId && x.name),
      page: Number(res.page || page) || page,
      maxPage,
      hasMore: page < maxPage || !!res.hasMore
    }
  },

  async getAudioUrl(chapterId) {
    const res = await this._request({ playId: chapterId })
    const url = res.url || res.url64 || ''
    if (url) return url
    throw new Error('该章节暂无音频')
  }
})
