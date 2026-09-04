// 聆阅听书（tingshu8.top PHP 代理 · 数据源酷我有声 · 无鉴权）
// 搜索：/search.php?all=&rn=&pn=   章节：/album.php?id=&rn=&pn=   元数据：/kuwo.php?rid=
// 直链双解析：higequ.com/player/{rid}/（Base64 直链，主）→ antiserver.kuwo.cn（mp3/aac，兜底）
// 搜索接口返回曲目，按 albumid 聚合成书；目录为服务端分页
({
  id: 'tingshu-json-lingyue',
  name: '聆阅听书',
  apiVersion: 1,
  _bases: ['http://www.tingshu8.top', 'http://115.190.207.125'],
  _anti: 'http://antiserver.kuwo.cn/anti.s',
  _resolver: 'https://higequ.com/player/',
  _ua: 'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36',
  _antiCache: {}, _albumCache: {}, _queue: null, _lastReqAt: 0,

  _sleep(ms) { return new Promise(r => setTimeout(r, ms)) },
  _gate() {
    const prev = this._queue || Promise.resolve()
    const job = prev.then(() => this._sleep(Math.max(0, this._lastReqAt + 300 - Date.now()) + Math.floor(Math.random() * 150))).then(() => { this._lastReqAt = Date.now() })
    this._queue = job.catch(() => {})
    return job
  },
  _raw(url, referer) {
    return new Promise((resolve, reject) => {
      uni.request({ url, method: 'GET', header: { 'User-Agent': this._ua, Referer: referer || 'http://www.tingshu8.top/' }, timeout: 20000,
        success: r => resolve({ statusCode: r.statusCode || 0, text: typeof r.data === 'string' ? r.data : JSON.stringify(r.data), data: r.data }),
        fail: e => reject(new Error(e.errMsg || '网络失败')) })
    })
  },
  async _api(path, params) {
    const qs = Object.keys(params || {}).map(k => k + '=' + encodeURIComponent(params[k])).join('&')
    let lastErr = null
    for (const base of this._bases) {
      await this._gate()
      try {
        const r = await this._raw(base + path + (qs ? '?' + qs : ''))
        if (r.statusCode >= 200 && r.statusCode < 300) return r.text
        lastErr = new Error('HTTP ' + r.statusCode + ' | ' + base + path)
      } catch (e) { lastErr = e }
    }
    throw lastErr || new Error('接口请求失败')
  },
  // PHP 可能输出 Warning 再输出 JSON，从第一个 { 开始解析
  _parse(text) {
    const s = String(text || '')
    const i = s.indexOf('{')
    try { return JSON.parse(i > 0 ? s.slice(i) : s) } catch (e) {
      throw new Error('接口返回异常：' + s.slice(0, 80))
    }
  },
  _cleanArtist(a) {
    return String(a || '').split('&').map(x => x.trim()).filter(x => x && x !== 'Unknown Singer').join(' / ')
  },
  // 有声书特征打分：把真正的听书专辑排到歌曲前面
  _bookScore(albumName, artist, tracks, keyword) {
    let score = 0
    const an = String(albumName || '')
    if (/有声|广播剧|多播|小说|原著|演播|评书|相声|连载|更新|听书/.test(an)) score += 4
    if (keyword && an.indexOf(keyword) >= 0) score += 2
    const ep = (Array.isArray(tracks) ? tracks : []).filter(t => /第?\s*\d+\s*[集章回]|预告|花絮/.test(String(t.name || ''))).length
    if (ep > 0) score += 2
    if (Array.isArray(tracks) && tracks.length >= 3) score += 1
    if (/文化|声工场|工作室|有声|演播/.test(String(artist || ''))) score += 1
    return score
  },
  // 曲目列表按专辑聚合为书（跳过无专辑的孤儿曲目），有声书优先
  _toBooks(tracks, keyword) {
    const groups = {}
    const order = []
    for (const t of (Array.isArray(tracks) ? tracks : [])) {
      const albumid = String(t.albumid || '')
      if (!albumid || albumid === '0') continue
      if (!groups[albumid]) { groups[albumid] = { albumid, album: String(t.album || '').trim(), artist: String(t.artist || ''), img: String(t.img || ''), tracks: [] }; order.push(albumid) }
      groups[albumid].tracks.push(t)
      if (!groups[albumid].album && t.album) groups[albumid].album = String(t.album).trim()
    }
    const out = order.map(id => {
      const g = groups[id]
      return {
        bookId: g.albumid,
        title: g.album,
        cover: g.img,
        author: this._cleanArtist(g.artist),
        intro: '',
        _score: this._bookScore(g.album, g.artist, g.tracks, keyword)
      }
    }).filter(x => x.title)
    out.sort((a, b) => b._score - a._score)
    return out.map(x => { const o = { bookId: x.bookId, title: x.title, cover: x.cover, author: x.author, intro: x.intro }; return o })
  },

  async search(keyword, page = 1) {
    const kw = String(keyword || '').trim()
    const p = Math.max(1, Number(page) || 1)
    if (!kw) return { list: [], page: p, maxPage: 1, hasMore: false }
    // 双查询：原词 + 原词"有声"，合并聚合，听书专辑排前
    const kw2 = /有声|广播剧|评书|相声/.test(kw) ? kw : kw + ' 有声'
    const [r1, r2] = await Promise.all([
      this._api('/search.php', { all: kw, rn: 30, pn: p }).then(t => this._parse(t)).catch(() => null),
      this._api('/search.php', { all: kw2, rn: 30, pn: p }).then(t => this._parse(t)).catch(() => null)
    ])
    const tracks = []
      .concat(r1 && Array.isArray(r1.list) ? r1.list : [])
      .concat(r2 && Array.isArray(r2.list) ? r2.list : [])
    const list = this._toBooks(tracks, kw)
    const t1 = Number(r1 && r1.totalpn) || 1
    const t2 = Number(r2 && r2.totalpn) || 1
    const maxPage = Math.max(t1, t2)
    return { list, page: p, maxPage, hasMore: p < maxPage && list.length > 0 }
  },

  async discover() {
    const cats = ['玄幻', '都市', '历史', '悬疑', '评书', '相声', '儿童', '武侠']
    const loaded = new Array(cats.length)
    let next = 0
    const worker = async () => {
      while (next < cats.length) {
        const i = next++
        try {
          const j = this._parse(await this._api('/search.php', { all: cats[i], rn: 20, pn: 1 }))
          const list = this._toBooks(j.list).slice(0, 10)
          if (list.length) loaded[i] = { title: cats[i], list }
        } catch (e) {}
      }
    }
    await Promise.all([worker(), worker(), worker()])
    return { sections: loaded.filter(Boolean) }
  },

  async getChapters(bookId, page = 1, pageSize = 30) {
    const id = String(bookId).replace(/^\D+/, '')
    if (!/^\d+$/.test(id)) throw new Error('无效的书籍 ID：' + bookId)
    const p = Math.max(1, Number(page) || 1)
    const rn = Math.max(5, Math.min(Number(pageSize) || 30, 50))
    let meta = this._albumCache[id]
    if (meta && meta.totalpn && p > meta.totalpn) {
      return { info: { title: meta.title, cover: meta.cover, author: meta.author, intro: meta.intro, trackCount: meta.trackCount || 0, isFinished: false }, list: [], page: p, maxPage: meta.totalpn, hasMore: false }
    }
    if (!meta) {
      const first = this._parse(await this._api('/album.php', { id, rn, pn: 1 }))
      meta = {
        title: String(first.album || '').trim(),
        cover: String(first.img || '').trim(),
        author: this._cleanArtist(first.artist),
        intro: String(first.info || '').trim(),
        time: String(first.time || '').trim()
      }
      if (!meta.title) throw new Error('专辑信息获取失败 | ' + id)
      this._albumCache[id] = meta
    }
    const j = this._parse(await this._api('/album.php', { id, rn, pn: p }))
    const rows = Array.isArray(j.list) ? j.list : []
    const totalpn = Number(j.totalpn) || 1
    meta.totalpn = totalpn
    // 首页时补拉最后一页，得到精确章节数
    let trackCount = totalpn * rn
    if (p === 1 && totalpn > 1) {
      try {
        const last = this._parse(await this._api('/album.php', { id, rn, pn: totalpn }))
        trackCount = (totalpn - 1) * rn + (Array.isArray(last.list) ? last.list.length : 0)
      } catch (e) {}
    } else if (p === 1) {
      trackCount = rows.length
    }
    meta.trackCount = trackCount
    const offset = (p - 1) * rn
    return {
      info: { title: meta.title, cover: meta.cover, author: meta.author, intro: meta.intro, trackCount, isFinished: false },
      list: rows.map((x, i) => ({ chapterId: String(x.id || ''), index: offset + i + 1, name: String(x.name || '').trim() })).filter(x => x.chapterId && x.name),
      page: p, maxPage: totalpn, hasMore: p < totalpn
    }
  },

  // 主解析：higequ 播放页（任意酷我 rid → let code Base64 直链）
  async _resolveViaHigequ(rid) {
    const html = await this._raw(this._resolver + rid + '/', 'https://higequ.com/')
    if (html.statusCode < 200 || html.statusCode >= 300) return null
    const m = String(html.text || '').match(/let code = "([A-Za-z0-9+/=]+)"/)
    if (!m) return null
    let url = ''
    try { url = atob(m[1]) } catch (e) { return null }
    if (!/^https?:\/\//i.test(url)) return null
    return { url, headers: { 'User-Agent': this._ua, Referer: 'https://higequ.com/' } }
  },
  // 兜底解析：酷我 antiserver（mp3 → aac）
  async _resolveViaAnti(rid) {
    const formats = ['mp3', 'aac']
    let lastBody = ''
    for (const fmt of formats) {
      const r = await this._raw(this._anti + '?type=convert_url&rid=MUSIC_' + rid + '&format=' + fmt + '&response=url', 'http://www.kuwo.cn/')
      const body = String(r.text || '').trim()
      lastBody = body
      if (r.statusCode >= 200 && r.statusCode < 300 && /^https?:\/\//i.test(body)) {
        return { url: body, headers: { 'User-Agent': this._ua, Referer: 'http://www.kuwo.cn/' } }
      }
      await this._sleep(400)
    }
    throw new Error('antiserver 无直链：' + lastBody.slice(0, 60))
  },
  // 终极兜底：LX 社区解析 API（聆澜 GET → ikun POST），按 kw 平台解析任意酷我 rid
  async _resolveViaLx(rid) {
    const lxUa = 'lx-music-request/2.0.0'
    try {
      const r1 = await new Promise((resolve, reject) => {
        uni.request({
          url: 'https://source.shiqianjiang.cn/api/music/url?source=kw&songId=' + rid + '&quality=128k',
          header: { 'User-Agent': lxUa, 'X-API-Key': 'CERU_KEY-31C0DB0B-2DFF-42EF-A2DB-47863E658840' },
          timeout: 15000,
          success: r => resolve(r.data),
          fail: e => reject(new Error(e.errMsg || '网络失败'))
        })
      })
      if (r1 && r1.code === 200 && /^https?:\/\//i.test(r1.url || '')) return { url: r1.url, headers: { 'User-Agent': this._ua } }
    } catch (e) {}
    try {
      const r2 = await new Promise((resolve, reject) => {
        uni.request({
          url: 'https://c.wwwweb.top/music/url',
          method: 'POST',
          header: { 'Content-Type': 'application/json', 'User-Agent': lxUa, 'X-Api-Key': 'IKM-P18200001-AyKQrBcgmEyPDpRy-0t' },
          data: { source: 'kw', musicId: rid, quality: '128k' },
          timeout: 15000,
          success: r => resolve(r.data),
          fail: e => reject(new Error(e.errMsg || '网络失败'))
        })
      })
      if (r2 && r2.code === 200 && /^https?:\/\//i.test(r2.url || '')) return { url: r2.url, headers: { 'User-Agent': this._ua } }
    } catch (e) {}
    throw new Error('LX 解析通道均不可用')
  },

  async getAudioUrl(chapterId) {
    const rid = String(chapterId).replace(/^MUSIC_/, '').replace(/^\D+/, '')
    if (!/^\d+$/.test(rid)) throw new Error('无效的章节 ID：' + chapterId)
    const hit = this._antiCache[rid]
    if (hit && Date.now() - hit.at < 240000) return hit.value
    let value = null
    let higeErr = null
    try { value = await this._resolveViaHigequ(rid) } catch (e) { higeErr = e }
    if (!value) {
      try { value = await this._resolveViaAnti(rid) } catch (e) {
        try { value = await this._resolveViaLx(rid) } catch (e2) {
          throw new Error('获取播放直链失败（higequ/antiserver/LX 均不可用）：' + String(e2.message).slice(0, 80))
        }
      }
    }
    this._antiCache[rid] = { value, at: Date.now() }
    return value
  }
})