// eprendre: YunTuYouSheng
({
  name: '云图有声',
  id: 'eprendre-yuntu-yousheng',
  version: 1,
  apiVersion: 1,
  _wechatId: '07955551-706c-4259-9aa0-db4627dfca57',

  _request(url) {
    return new Promise((resolve, reject) => {
      uni.request({
        url,
        method: 'GET',
        timeout: 20000,
        success: r => {
          if (r.statusCode < 200 || r.statusCode >= 300) return reject(new Error('HTTP ' + r.statusCode + ' | ' + url))
          resolve(r.data)
        },
        fail: e => reject(new Error(e.errMsg || '网络失败'))
      })
    })
  },

  _book(item) {
    return {
      bookId: String(item.bookId || ''),
      title: item.bookName || '',
      cover: item.cover || '',
      author: item.authorName || item.anchorName || '',
      intro: item.chapters ? ('共 ' + item.chapters + ' 章') : (item.summary || '')
    }
  },

  async search(keyword, page = 1, pageSize = 20) {
    const url = 'http://open-service.yuntuys.com/api/w_ys/book/search/wechat:' +
      this._wechatId + '/' + encodeURIComponent(keyword) +
      '?pageSize=' + pageSize + '&pageNum=' + page
    const res = await this._request(url)
    const data = res && res.data ? res.data : {}
    const rows = Array.isArray(data.list) ? data.list : []
    const maxPage = Number(data.totalPage || 1) || 1
    return { list: rows.map(item => this._book(item)), page, maxPage, hasMore: page < maxPage }
  },

  async getChapters(bookId, page = 1, pageSize = 30) {
    const url = 'http://open-service.yuntuys.com/api/w_ys/book/getChapters/wechat:' +
      this._wechatId + '/' + encodeURIComponent(bookId) +
      '/true/asc?pageSize=' + pageSize + '&pageNum=' + page
    const res = await this._request(url)
    const pq = res && res.data && res.data.pageQuery ? res.data.pageQuery : {}
    const rows = Array.isArray(pq.list) ? pq.list : []
    const maxPage = Number(pq.totalPage || 1) || 1
    return {
      info: { title: '', cover: '', author: '', trackCount: Number(pq.totalRow || 0) || 0, isFinished: false },
      list: rows.map((item, i) => ({
        chapterId: item.audioUrl || '',
        index: (page - 1) * pageSize + i + 1,
        name: item.name || ('第' + ((page - 1) * pageSize + i + 1) + '集')
      })).filter(item => item.chapterId),
      page,
      maxPage,
      hasMore: page < maxPage
    }
  },

  async getAudioUrl(chapterId) {
    return String(chapterId)
  }
})
