// eprendre: KuWo
({
  name: '酷我畅听',
  id: 'eprendre-kuwo',
  apiVersion: 1,
  _ua: 'Mozilla/5.0 (Linux; Android) AppleWebKit/537.36',
  _audioSource: 'kwplayercar_ar_6.0.0.9_B_jiakong_vh.apk',

  _request(url, headers) {
    return new Promise((resolve, reject) => {
      uni.request({
        url,
        method: 'GET',
        header: Object.assign({ 'User-Agent': this._ua }, headers || {}),
        timeout: 20000,
        success: r => {
          if (r.statusCode < 200 || r.statusCode >= 300) return reject(new Error('HTTP ' + r.statusCode + ' | ' + url))
          resolve(r.data)
        },
        fail: e => reject(new Error(e.errMsg || '网络失败'))
      })
    })
  },

  async search(keyword, page = 1, pageSize = 20) {
    const rn = Math.min(pageSize, 20)
    const url = 'http://baby.kuwo.cn/tingshu/api/search/Search?rn=' + rn +
      '&type=album&version=8.5.6.1&wd=' + encodeURIComponent(keyword) +
      '&pn=' + page + '&kweexVersion=1.0.2'
    const res = await this._request(url)
    const data = res && res.data ? res.data : {}
    const items = Array.isArray(data.data) ? data.data : []
    const total = Number(data.total || items.length) || items.length
    const maxPage = Math.max(1, Math.ceil(total / rn))
    return {
      list: items.map(item => ({
        bookId: String(item.albumId || ''),
        title: item.albumName || '',
        cover: item.coverImg || '',
        author: item.artistName || '',
        intro: item.songTotal ? ('共 ' + item.songTotal + ' 章') : (item.title || '')
      })),
      page,
      maxPage,
      hasMore: page < maxPage
    }
  },

  async getChapters(bookId, page = 1, pageSize = 30) {
    const url = 'http://baby.kuwo.cn/tingshu/api/data/album/songs?albumId=' +
      encodeURIComponent(bookId) + '&online=0&kweexVersion=1.0.2'
    const res = await this._request(url)
    const all = Array.isArray(res && res.data) ? res.data : []
    const maxPage = Math.max(1, Math.ceil(all.length / pageSize))
    const safePage = Math.max(1, Math.min(page, maxPage))
    const start = (safePage - 1) * pageSize
    return {
      info: { title: '', cover: '', author: '', trackCount: all.length, isFinished: true },
      list: all.slice(start, start + pageSize).map((item, i) => ({
        chapterId: item.musicrid || '',
        index: start + i + 1,
        name: item.name || ('第' + (start + i + 1) + '集')
      })).filter(item => item.chapterId),
      page: safePage,
      maxPage,
      hasMore: safePage < maxPage
    }
  },

  async getAudioUrl(chapterId) {
    const rid = String(chapterId).replace(/^MUSIC_/i, '').replace(/^kuwo:\/\/track\//i, '').trim()
    const url = 'http://mobi.kuwo.cn/mobi.s?f=web&user=0&source=' +
      encodeURIComponent(this._audioSource) +
      '&type=convert_url_with_sign&br=128k&sig=0&rid=' + encodeURIComponent(rid)
    const res = await this._request(url)
    const data = res && res.data ? res.data : res
    if (data && data.url) return String(data.url).replace(/\$(?=\S)/g, '=')
    throw new Error('酷我音频解析失败: ' + JSON.stringify(res).slice(0, 160))
  }
})
