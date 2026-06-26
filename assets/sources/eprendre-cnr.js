// eprendre: CNR
({
  name: '电台电视',
  id: 'eprendre-cnr',
  apiVersion: 1,
  _cover: 'https://wdts.top/api/covers/radio.jpg',
  _cctv: [
    ['CCTV-1综合', 'http://zqh2333.top:2222/rtp/239.93.24.184:5140'],
    ['CCTV-2财经', 'http://zqh2333.top:2222/rtp/239.93.24.59:5140'],
    ['CCTV-3综艺', 'http://zqh2333.top:2222/rtp/239.93.24.150:5140'],
    ['CCTV-4中文国际', 'http://zqh2333.top:2222/rtp/239.93.25.105:5140'],
    ['CCTV-5体育', 'http://zqh2333.top:2222/rtp/239.93.55.37:5140'],
    ['CCTV-6电影', 'http://zqh2333.top:2222/rtp/239.93.24.64:5140'],
    ['CCTV-8电视剧', 'http://zqh2333.top:2222/rtp/239.93.55.39:5140'],
    ['CCTV-13新闻', 'http://zqh2333.top:2222/rtp/239.93.24.66:5140'],
    ['CCTV-15音乐', 'http://zqh2333.top:2222/rtp/239.93.24.103:5140']
  ],
  _tv: [
    ['北京卫视', 'http://zqh2333.top:2222/rtp/239.93.24.180:5140'],
    ['天津卫视', 'http://zqh2333.top:2222/rtp/239.93.24.167:5140'],
    ['东方卫视', 'http://zqh2333.top:2222/rtp/239.93.24.123:5140'],
    ['广东卫视', 'http://zqh2333.top:2222/rtp/239.93.24.181:5140'],
    ['江苏卫视', 'http://zqh2333.top:2222/rtp/239.93.24.89:5140'],
    ['浙江卫视', 'http://zqh2333.top:2222/rtp/239.93.24.124:5140'],
    ['湖南卫视', 'http://zqh2333.top:2222/rtp/239.93.24.88:5140'],
    ['山东卫视', 'http://zqh2333.top:2222/rtp/239.93.24.168:5140'],
    ['河南卫视', 'http://zqh2333.top:2222/rtp/239.93.55.45:5140']
  ],
  _nationalMap: {},
  _localMap: {},

  _post(url, data) {
    return new Promise((resolve, reject) => {
      uni.request({
        url,
        method: 'POST',
        data: data || {},
        header: { 'Content-Type': 'application/json' },
        timeout: 20000,
        success: r => {
          if (r.statusCode < 200 || r.statusCode >= 300) return reject(new Error('HTTP ' + r.statusCode + ' | ' + url))
          resolve(r.data)
        },
        fail: e => reject(new Error(e.errMsg || '网络失败'))
      })
    })
  },

  _book(id, title) {
    return { bookId: id, title, cover: this._cover, author: '', intro: '直播源，请不要开加速播放' }
  },

  async search(keyword, page = 1, pageSize = 20) {
    const k = String(keyword || '').trim()
    const list = [
      this._book('radio/national', '国家电台'),
      this._book('tv/cctv', '央视'),
      this._book('tv/tvs', '卫视')
    ]
    if (!k || page > 1) return { list: page > 1 ? [] : list, page, maxPage: 1, hasMore: false }
    const rows = list.filter(item => item.title.indexOf(k) >= 0 || item.intro.indexOf(k) >= 0)
    return { list: rows, page, maxPage: 1, hasMore: false }
  },

  async _nationalEpisodes() {
    const res = await this._post('https://apppc.cnr.cn/national', {})
    const detail = res && res.data && res.data.categories && res.data.categories[0] ? res.data.categories[0].detail : []
    return (Array.isArray(detail) ? detail : []).map((item, i) => {
      const url = item.other_info11 && item.other_info11[0] ? item.other_info11[0].url : ''
      this._nationalMap[item.id] = url
      return { chapterId: 'national&&' + item.id, index: i + 1, name: item.name || ('电台' + (i + 1)) }
    })
  },

  async _localEpisodes(parentId) {
    const res = await this._post('https://apppc.cnr.cn/local', { id: parentId })
    const detail = res && res.data && res.data.categories && res.data.categories[0] ? res.data.categories[0].detail : []
    return (Array.isArray(detail) ? detail : []).map((item, i) => {
      const url = item.other_info11 && item.other_info11[0] ? item.other_info11[0].url : ''
      this._localMap[item.id] = url
      return { chapterId: 'local&&' + item.id + '&&' + parentId, index: i + 1, name: item.name || ('电台' + (i + 1)) }
    })
  },

  async getChapters(bookId, page = 1, pageSize = 30) {
    let all = []
    if (bookId === 'radio/national') all = await this._nationalEpisodes()
    else if (String(bookId).startsWith('radio/')) all = await this._localEpisodes(String(bookId).split('/')[1])
    else all = (bookId === 'tv/cctv' ? this._cctv : this._tv).map((row, i) => ({ chapterId: 'tv&&' + row[1], index: i + 1, name: row[0] }))
    const maxPage = Math.max(1, Math.ceil(all.length / pageSize))
    const start = (page - 1) * pageSize
    return {
      info: { title: '', cover: this._cover, author: '', trackCount: all.length, isFinished: false },
      list: all.slice(start, start + pageSize),
      page,
      maxPage,
      hasMore: page < maxPage
    }
  },

  async getAudioUrl(chapterId) {
    const parts = String(chapterId).split('&&')
    if (parts[0] === 'tv') return parts[1] || ''
    if (parts[0] === 'national') {
      if (!this._nationalMap[parts[1]]) await this._nationalEpisodes()
      return this._nationalMap[parts[1]] || ''
    }
    if (parts[0] === 'local') {
      if (!this._localMap[parts[1]]) await this._localEpisodes(parts[2])
      return this._localMap[parts[1]] || ''
    }
    throw new Error('未知直播章节: ' + chapterId)
  }
})
