// eprendre: BoKanYouSheng
({
  name: '博看有声',
  id: 'eprendre-bokan-yousheng',
  apiVersion: 1,
  _instanceId: '25304',

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
      bookId: String(item.id || ''),
      title: item.name || '',
      cover: item.cover || '',
      author: '',
      intro: item.total ? ('共 ' + item.total + ' 章') : ''
    }
  },

  async search(keyword, page = 1, pageSize = 20) {
    const key = encodeURIComponent(keyword)
    const urls = [
      'https://es.bookan.com.cn/api/v3/voice/book?instanceId=' + this._instanceId + '&keyword=' + key + '&pageNum=' + page + '&limitNum=' + pageSize,
      'https://es.bookan.com.cn/api/v3/voice/album?instanceId=' + this._instanceId + '&keyword=' + key + '&pageNum=' + page + '&limitNum=' + pageSize
    ]
    const list = []
    let maxPage = 1
    for (const url of urls) {
      try {
        const res = await this._request(url)
        const data = res && res.data ? res.data : {}
        maxPage = Math.max(maxPage, Number(data.last_page || 1) || 1)
        ;(Array.isArray(data.list) ? data.list : []).forEach(item => list.push(this._book(item)))
      } catch (e) {}
    }
    return { list, page, maxPage, hasMore: page < maxPage }
  },

  async getChapters(bookId, page = 1, pageSize = 30) {
    const url = 'https://api.bookan.com.cn/voice/album/units?album_id=' +
      encodeURIComponent(bookId) + '&page=' + page + '&num=' + pageSize + '&order=1'
    const res = await this._request(url)
    const data = res && res.data ? res.data : {}
    const rows = Array.isArray(data.list) ? data.list : []
    const maxPage = Number(data.last_page || 1) || 1
    return {
      info: { title: '', cover: '', author: '', trackCount: Number(data.total || 0) || 0, isFinished: true },
      list: rows.map((item, i) => ({
        chapterId: item.file || '',
        index: (page - 1) * pageSize + i + 1,
        name: item.title || ('第' + ((page - 1) * pageSize + i + 1) + '集')
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
