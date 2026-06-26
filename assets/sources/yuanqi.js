// 元气听书（喜马拉雅代理）
// 接口：music.haitangw.cc  |  鉴权：无  |  UA: okhttp/4.9.2
({
  name: '元气听书',
  id: 'yuanqi',
  apiVersion: 1,

  _req(data) {
    return new Promise((resolve, reject) => {
      uni.request({
        url: 'https://music.haitangw.cc/tingshu/tingshu.php',
        data,
        header: { 'User-Agent': 'okhttp/4.9.2' },
        timeout: 15000,
        success: r => r.statusCode === 200 ? resolve(r.data) : reject(new Error('HTTP ' + r.statusCode)),
        fail: e => reject(new Error(e.errMsg || '网络失败'))
      })
    })
  },

  async search(keyword, page = 1, pageSize = 20) {
    const res = await this._req({ name: keyword, page, pageSize })
    const rows = Array.isArray(res.data) ? res.data : []
    return {
      list: rows.map(item => ({
        bookId: item.itemId,
        title:  item.title    || '',
        cover:  item.cover    || '',
        author: item.nickname || '',
        intro:  item.intro    || ''
      })),
      page: res.page || page, maxPage: res.maxPage || 1, hasMore: !!res.hasMore
    }
  },

  async getChapters(bookId, page = 1, pageSize = 30) {
    const res = await this._req({ itemId: bookId, page, pageSize })
    const rows = Array.isArray(res.data) ? res.data : []
    const offset = (page - 1) * pageSize
    return {
      info: {
        title: res.itemTitle || '', cover: res.cover || '',
        author: res.nickname || '', trackCount: res.trackCount || res.total || 0,
        isFinished: !!res.isFinished
      },
      list: rows.map((item, i) => ({ chapterId: item.playId, index: offset + i + 1, name: item.title || '' })),
      page: res.page || page, maxPage: res.maxPage || 1, hasMore: !!res.hasMore
    }
  },

  async getAudioUrl(chapterId) {
    const res = await this._req({ playId: chapterId })
    if (res.msg === 'success' && res.url) return res.url
    throw new Error('该章节暂无音频（VIP 或未更新）')
  }
})
