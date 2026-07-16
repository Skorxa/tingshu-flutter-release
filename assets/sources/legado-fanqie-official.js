// Converted from docs/shareBookSource-2.json: 番茄听书[官方]
({
  id: 'legado-fanqie-official',
  name: '番茄听书[官方]',
  apiVersion: 1,
  _ua: 'Mozilla/5.0 (Linux; Android 12; 23117RK66C Build/SKQ1.220303.001) AppleWebKit/537.36 Mobile Safari/537.36',
  _catalogs: {},

  _request(url, options) {
    const opts = options || {}
    return new Promise((resolve, reject) => {
      uni.request({
        url,
        method: opts.method || 'GET',
        data: opts.data || null,
        header: Object.assign({
          'User-Agent': this._ua,
          Accept: 'application/json, text/plain, */*'
        }, opts.headers || {}),
        timeout: opts.timeout || 30000,
        success: r => {
          if (r.statusCode < 200 || r.statusCode >= 300) {
            reject(new Error('HTTP ' + r.statusCode + ' | ' + url))
            return
          }
          resolve(this._json(r.data))
        },
        fail: e => reject(new Error(e.errMsg || '网络失败'))
      })
    })
  },

  _json(value) {
    if (value && typeof value === 'object') return value
    try { return JSON.parse(String(value || '')) } catch (e) {
      throw new Error('接口返回的不是有效 JSON')
    }
  },

  _clean(value) {
    return String(value || '')
      .replace(/<[^>]+>/g, '')
      .replace(/&nbsp;/g, ' ')
      .replace(/\s+/g, ' ')
      .trim()
  },

  _pack(value) {
    return encodeURIComponent(JSON.stringify(value))
  },

  _unpack(value) {
    try { return JSON.parse(decodeURIComponent(String(value || ''))) } catch (e) {
      return { id: String(value || '') }
    }
  },

  _flattenChapters(value, output) {
    if (Array.isArray(value)) {
      value.forEach(item => this._flattenChapters(item, output))
      return
    }
    if (!value || typeof value !== 'object') return
    if (value.itemId || value.item_id) {
      output.push(value)
      return
    }
    Object.keys(value).forEach(key => this._flattenChapters(value[key], output))
  },

  async search(keyword, page = 1, pageSize = 20) {
    const safePage = Math.max(1, Number(page) || 1)
    const limit = Math.max(1, Math.min(Number(pageSize) || 20, 50))
    const offset = (safePage - 1) * limit
    const params = [
      'device_platform=android',
      'os=android',
      'aid=3040',
      'app_name=novel_fm',
      'version_code=652',
      'version_name=6.5.2.32',
      '_rticket=' + Date.now()
    ].join('&')
    const url = 'https://api.novelfm.com/novelfm/bookmall/search/page/v1/?' + params
    const res = await this._request(url, {
      method: 'POST',
      data: { query: keyword, offset, limit, tab_type: 2 },
      headers: { 'Content-Type': 'application/json' }
    })
    const data = res && res.data ? res.data : {}
    const groups = Array.isArray(data.search_data) ? data.search_data : []
    const rows = []
    groups.forEach(group => {
      if (group && Array.isArray(group.books)) rows.push.apply(rows, group.books)
    })
    const seen = {}
    const list = []
    rows.forEach(item => {
      const id = String(item.book_id || item.series_id || '')
      const title = this._clean(item.book_name || item.series_title || item.original_book_name)
      if (!id || !title || seen[id]) return
      seen[id] = true
      const author = this._clean(item.author || item.anchor || item.actors)
      const cover = String(item.thumb_url || item.audio_thumb_uri || item.thumb_pic || '')
      const intro = this._clean(item.abstract || item.sub_abstract || '')
      const finished = String(item.creation_status) === '0' ||
        (item.decision_infos && item.decision_infos.creation_status === '完结')
      list.push({
        bookId: this._pack({ id, t: title, c: cover, a: author, n: Number(item.serial_count || 0) || 0, f: finished }),
        title,
        cover,
        author: author + (item.serial_count ? ' · 共' + item.serial_count + '集' : ''),
        intro
      })
    })
    const hasMore = data.has_more === true
    return {
      list,
      page: safePage,
      maxPage: hasMore ? safePage + 1 : safePage,
      hasMore
    }
  },

  async _loadCatalog(meta) {
    const cacheKey = String(meta.id || '')
    if (this._catalogs[cacheKey]) return this._catalogs[cacheKey]
    const url = 'https://fanqienovel.com/api/reader/directory/detail?bookId=' +
      encodeURIComponent(cacheKey)
    const res = await this._request(url, {
      headers: { Referer: 'https://fanqienovel.com/' }
    })
    const data = res && res.data ? res.data : {}
    const chapters = []
    this._flattenChapters(data.chapterListWithVolume || data.allItemIds || [], chapters)
    if (!chapters.length) throw new Error('番茄目录为空')
    this._catalogs[cacheKey] = chapters
    return chapters
  },

  async getChapters(bookId, page = 1, pageSize = 30) {
    const meta = this._unpack(bookId)
    if (!meta.id) throw new Error('番茄书籍 ID 为空')
    const all = await this._loadCatalog(meta)
    const size = Math.max(1, Math.min(Number(pageSize) || 30, 100))
    const maxPage = Math.max(1, Math.ceil(all.length / size))
    const safePage = Math.max(1, Math.min(Number(page) || 1, maxPage))
    const start = (safePage - 1) * size
    const rows = all.slice(start, start + size)
    return {
      info: {
        title: meta.t || '',
        cover: meta.c || '',
        author: meta.a || '',
        trackCount: all.length || Number(meta.n || 0) || 0,
        isFinished: meta.f === true
      },
      list: rows.map((item, i) => ({
        chapterId: this._pack({ b: String(meta.id), c: String(item.itemId || item.item_id || '') }),
        index: start + i + 1,
        name: this._clean(item.title || item.chapter_title || ('第' + (start + i + 1) + '集'))
      })).filter(item => this._unpack(item.chapterId).c),
      page: safePage,
      maxPage,
      hasMore: safePage < maxPage
    }
  },

  _audioUrl(value) {
    const raw = String(value || '')
    if (/^https?:\/\//i.test(raw)) return raw
    try {
      const decoded = atob(raw)
      return /^https?:\/\//i.test(decoded) ? decoded : raw
    } catch (e) {
      return raw
    }
  },

  async getAudioUrl(chapterId) {
    const info = this._unpack(chapterId)
    const itemId = String(info.c || info.id || '')
    if (!itemId) throw new Error('番茄章节 ID 为空')
    const url = 'https://api-sinfonlineb.fanqiesdk.com/api/novel/audio/video_model/mget/v1' +
      '?aid=4939&tone_id=1&item_ids=7579988172734467097,' + encodeURIComponent(itemId)
    const res = await this._request(url, {
      headers: { Referer: 'https://fanqienovel.com/' }
    })
    const rows = res && res.data && Array.isArray(res.data.video_model_infos)
      ? res.data.video_model_infos
      : []
    let model = null
    for (const row of rows) {
      if (!row || !row.video_model) continue
      try {
        const parsed = this._json(row.video_model)
        if (String(row.item_id || '') === itemId) {
          model = parsed
          break
        }
        if (!model) model = parsed
      } catch (e) {}
    }
    const videos = model && Array.isArray(model.video_list) ? model.video_list : []
    const first = videos[0] || {}
    const audioUrl = this._audioUrl(
      first.main_url || first.mainUrl || first.backup_url || first.backupUrl ||
      (model && model.fallback_api && model.fallback_api.fallback_api)
    )
    if (!audioUrl) throw new Error('番茄音频地址为空，章节可能受限')
    return {
      url: audioUrl,
      headers: {
        'User-Agent': this._ua,
        Referer: 'https://fanqienovel.com/',
        Accept: '*/*'
      }
    }
  }
})
