// eprendre: BiliBili
({
  name: '哔哩哔哩',
  id: 'eprendre-bilibili',
  apiVersion: 1,
  _site: 'https://m.bilibili.com',
  _ua: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',

  _request(url, headers) {
    return new Promise((resolve, reject) => {
      uni.request({
        url,
        method: 'GET',
        header: Object.assign({ 'User-Agent': this._ua, Referer: this._site + '/' }, headers || {}),
        timeout: 20000,
        success: r => {
          if (r.statusCode < 200 || r.statusCode >= 300) return reject(new Error('HTTP ' + r.statusCode + ' | ' + url))
          resolve(r.data)
        },
        fail: e => reject(new Error(e.errMsg || '网络失败'))
      })
    })
  },

  _clean(text) {
    return String(text || '').replace(/<em class="keyword">/g, '').replace(/<\/em>/g, '').replace(/<[^>]+>/g, '').trim()
  },

  async search(keyword, page = 1, pageSize = 20) {
    const url = 'https://api.bilibili.com/x/web-interface/search/all/v2?keyword=' +
      encodeURIComponent(keyword) + '&page=' + page + '&pagesize=' + pageSize
    const res = await this._request(url)
    const data = res && res.data ? res.data : {}
    const groups = Array.isArray(data.result) ? data.result : []
    let videos = []
    for (const group of groups) {
      if (group && group.result_type === 'video' && Array.isArray(group.data)) {
        videos = group.data
        break
      }
    }
    const currentPage = Math.max(1, Number(data.page || page) || page)
    const responsePageSize = Math.max(1, Number(data.pagesize || pageSize) || pageSize)
    const total = Math.max(0, Number(data.numResults || 0) || 0)
    const nextPage = Math.max(0, Number(data.next || 0) || 0)
    const maxPage = Math.max(
      currentPage,
      Number(data.numPages || 0) || 0,
      total > 0 ? Math.ceil(total / responsePageSize) : 0,
      nextPage > currentPage ? nextPage : 0
    )
    return {
      list: videos.map(item => ({
        bookId: this._site + '/video/' + item.bvid,
        title: this._clean(item.title),
        cover: item.pic ? (String(item.pic).startsWith('//') ? 'https:' + item.pic : item.pic) : '',
        author: item.author || '',
        intro: item.play ? ('播放次数: ' + item.play) : ''
      })),
      page: currentPage,
      maxPage,
      hasMore: nextPage > currentPage || currentPage < maxPage
    }
  },

  async getChapters(bookId, page = 1, pageSize = 30) {
    const bvid = String(bookId).split('/').filter(Boolean).pop().split('?')[0]
    const url = 'https://api.bilibili.com/x/web-interface/view/detail?aid=&bvid=' + encodeURIComponent(bvid)
    const res = await this._request(url, { Referer: bookId })
    const view = res && res.data && res.data.View ? res.data.View : {}
    const pages = Array.isArray(view.pages) ? view.pages : []
    const maxPage = Math.max(1, Math.ceil(pages.length / pageSize))
    const safePage = Math.max(1, Math.min(page, maxPage))
    const start = (safePage - 1) * pageSize
    return {
      info: {
        title: this._clean(view.title || ''),
        cover: view.pic || '',
        author: view.owner && view.owner.name ? view.owner.name : '',
        trackCount: pages.length,
        isFinished: true
      },
      list: pages.slice(start, start + pageSize).map((item, i) => ({
        chapterId: JSON.stringify({
          bvid,
          cid: item.cid || '',
          page: item.page,
          pageUrl: 'https://www.bilibili.com/video/' + bvid + '?p=' + item.page
        }),
        index: start + i + 1,
        name: this._clean(item.part || ('P' + item.page))
      })),
      page: safePage,
      maxPage,
      hasMore: safePage < maxPage
    }
  },

  async _chapterInfo(chapterId) {
    const raw = String(chapterId || '')
    try {
      const data = JSON.parse(raw)
      if (data && data.bvid && data.cid) return data
    } catch (e) {}

    const pageUrl = raw
    const bvid = pageUrl.split('/').filter(Boolean).pop().split('?')[0]
    const p = Number((pageUrl.match(/[?&]p=(\d+)/) || [])[1] || 1) || 1
    const detailUrl = 'https://api.bilibili.com/x/web-interface/view/detail?aid=&bvid=' + encodeURIComponent(bvid)
    const res = await this._request(detailUrl, { Referer: pageUrl })
    const pages = res && res.data && res.data.View && Array.isArray(res.data.View.pages) ? res.data.View.pages : []
    const item = pages.find(x => Number(x.page || 0) === p) || pages[0] || {}
    return { bvid, cid: item.cid || '', page: p, pageUrl }
  },

  async getAudioUrl(chapterId) {
    const info = await this._chapterInfo(chapterId)
    if (info.bvid && info.cid) {
      const referer = info.pageUrl || ('https://www.bilibili.com/video/' + info.bvid)
      const api = 'https://api.bilibili.com/x/player/playurl?bvid=' +
        encodeURIComponent(info.bvid) + '&cid=' + encodeURIComponent(info.cid) +
        '&qn=0&fnval=16&fnver=0&fourk=1'
      const res = await this._request(api, {
        Referer: referer
      })
      const dash = res && res.data && res.data.dash ? res.data.dash : {}
      const audios = Array.isArray(dash.audio) ? dash.audio : []
      audios.sort((a, b) => Number(b.bandwidth || 0) - Number(a.bandwidth || 0))
      const audio = audios[0] || {}
      const url = audio.baseUrl || audio.base_url || (Array.isArray(audio.backupUrl) ? audio.backupUrl[0] : '') || (Array.isArray(audio.backup_url) ? audio.backup_url[0] : '')
      if (url) {
        return {
          url,
          headers: {
            'User-Agent': this._ua,
            Referer: referer,
            Origin: 'https://www.bilibili.com',
            Accept: '*/*',
            'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
            Range: 'bytes=0-',
            Connection: 'keep-alive'
          }
        }
      }
    }

    return {
      sniff: true,
      url: info.pageUrl || String(chapterId),
      headers: {
        'User-Agent': this._ua,
        Referer: info.pageUrl || this._site + '/',
        Origin: 'https://www.bilibili.com'
      },
      waitMs: 3500,
      audioPatterns: ['.m4s', '.mp4', '.m4a', '.mp3']
    }
  }
})
