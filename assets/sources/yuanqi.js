// 元气听书（喜马拉雅代理）
// 接口：music.haitangw.cc  |  鉴权：无  |  UA: okhttp/4.9.2
({
  name: '元气听书',
  id: 'yuanqi',
  apiVersion: 1,
  _api: 'https://music.haitangw.cc/tingshu/tingshu.php',
  _categoryApi: 'https://music.haitangw.cc/tingshu/category.php',
  _ua: 'okhttp/4.9.2',

  _request(url, data, timeout = 15000) {
    return new Promise((resolve, reject) => {
      uni.request({
        url,
        data,
        header: { 'User-Agent': this._ua },
        timeout,
        success: r => r.statusCode === 200 ? resolve(r.data) : reject(new Error('HTTP ' + r.statusCode)),
        fail: e => reject(new Error(e.errMsg || '网络失败'))
      })
    })
  },

  _req(data, timeout = 15000) {
    return this._request(this._api, data, timeout)
  },

  _toBooks(rows, limit = 0) {
    const books = (Array.isArray(rows) ? rows : []).map(item => ({
      bookId: String(item.itemId || ''),
      title:  String(item.title || '').trim(),
      cover:  item.cover || '',
      author: String(item.nickname || '').trim(),
      intro:  String(item.intro || '').trim()
    })).filter(item => item.bookId && item.title)
    return limit > 0 ? books.slice(0, limit) : books
  },

  async search(keyword, page = 1, pageSize = 20) {
    const res = await this._req({ name: keyword, page, pageSize })
    const rows = Array.isArray(res.data) ? res.data : []
    return {
      list: this._toBooks(rows),
      page: res.page || page, maxPage: res.maxPage || 1, hasMore: !!res.hasMore
    }
  },

  async discover() {
    const fallback = ['热门', '有声书', '儿童', '历史', '相声评书', '悬疑']
    let names = fallback
    try {
      const res = await this._request(this._categoryApi, {}, 4000)
      const rows = Array.isArray(res) ? res : (Array.isArray(res.data) ? res.data : [])
      const preferred = new Set(fallback.slice(1))
      const matched = rows
        .map(item => String(item.name || '').trim())
        .filter(name => preferred.has(name))
      if (matched.length >= 3) names = ['热门'].concat(matched)
    } catch (_) {
      // 分类菜单失败时仍可用已知分区加载发现页。
    }

    const loaded = new Array(names.length)
    let next = 0
    const worker = async () => {
      while (next < names.length) {
        const index = next++
        const title = names[index]
        try {
          const res = await this._req({ name: title, page: 1, pageSize: 8 }, 6000)
          const list = this._toBooks(res && res.data, 8)
          if (list.length) loaded[index] = { title, list }
        } catch (_) {
          // 单个分区失败不影响其他分区。
        }
      }
    }
    await Promise.all([worker(), worker()])
    return { sections: loaded.filter(Boolean) }
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
