// eprendre: JiHe GCORES
({
  name: '机核 GCORES',
  id: 'eprendre-jihe',
  apiVersion: 1,
  _site: 'https://www.gcores.com',
  _ua: 'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 Chrome/124.0 Mobile Safari/537.36',
  _request(url) {
    return new Promise((resolve, reject) => {
      uni.request({ url, method: 'GET', header: { 'User-Agent': this._ua, Accept: 'application/json,text/html,*/*' }, timeout: 20000,
        success: r => r.statusCode >= 200 && r.statusCode < 300 ? resolve(r.data) : reject(new Error('HTTP ' + r.statusCode + ' | ' + url)),
        fail: e => reject(new Error(e.errMsg || '网络失败')) })
    })
  },
  _clean(s) { return String(s || '').replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ').trim() },
  _attr(tag, name) { const m = String(tag || '').match(new RegExp(name + "\\s*=\\s*(\"([^\"]*)\"|'([^']*)'|([^\\s>]+))", 'i')); return m ? (m[2] || m[3] || m[4] || '') : '' },
  _abs(url, base) { url = String(url || '').trim(); if (/^https?:\/\//i.test(url)) return url; if (url[0] === '/') return this._site + url; return String(base || this._site + '/').replace(/\/[^/]*$/, '/') + url },

  async search(keyword, page = 1, pageSize = 20) {
    const offset = (page - 1) * 12
    const url = this._site + '/gapi/v1/albums?page[limit]=12&page[offset]=' + offset + '&sort=-updated-at&filter[is-on-sale]=0'
    const res = await this._request(url)
    const rows = Array.isArray(res.data) ? res.data : []
    const total = res.meta ? Number(res.meta['record-count'] || rows.length) : rows.length
    let list = rows.map(item => {
      const a = item.attributes || {}
      return {
        bookId: this._site + '/gapi/v1/albums/' + item.id + '/published-radios?page[limit]=100&page[offset]=0&include=media,category,albums',
        title: a.title || '',
        cover: a.cover ? ('https://image.gcores.com/' + a.cover + '?x-oss-process=image/resize,limit_1,m_fill,w_360,h_360/quality,q_90') : '',
        author: '',
        intro: '播单'
      }
    })
    if (keyword) list = list.filter(x => x.title.indexOf(keyword) >= 0 || keyword.indexOf('机核') >= 0)
    const maxPage = Math.max(1, Math.ceil(total / 12))
    return { list: list.slice(0, pageSize), page, maxPage, hasMore: page < maxPage }
  },

  async getChapters(bookId, page = 1, pageSize = 30) {
    const res = await this._request(bookId)
    const included = Array.isArray(res.included) ? res.included : []
    const audioMap = {}
    included.forEach(item => {
      const a = item.attributes || {}
      if (a.audio) audioMap[item.id] = /^https?:\/\//i.test(a.audio) ? a.audio : ('https://alioss.gcores.com/uploads/audio/' + a.audio)
    })
    const all = (Array.isArray(res.data) ? res.data : []).map(item => {
      const a = item.attributes || {}
      const media = item.relationships && item.relationships.media && item.relationships.media.data ? item.relationships.media.data.id : ''
      return { title: a.title || '', url: audioMap[media] || '' }
    }).filter(x => x.url)
    const maxPage = Math.max(1, Math.ceil(all.length / pageSize))
    const start = (page - 1) * pageSize
    return { info: { title: '', cover: '', author: '', trackCount: all.length, isFinished: true }, list: all.slice(start, start + pageSize).map((x, i) => ({ chapterId: x.url, index: start + i + 1, name: x.title || ('第' + (start + i + 1) + '期') })), page, maxPage, hasMore: page < maxPage }
  },

  async getAudioUrl(chapterId) { return String(chapterId) }
})
