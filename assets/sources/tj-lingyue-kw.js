// 聆阅 · 源B-KW（酷我有声 · 双通道）
//
// 通道 A —— tingshu8.top PHP 代理（主链路，零鉴权、无并发限制、稳定）
//   搜索 /search.php?all=&rn=&pn=    章节 /album.php?id=&rn=&pn=    元数据(含付费标记) /kuwo.php?rid=
//   直链解析依次尝试：higequ.com/player/{rid}/（Base64）→ antiserver.kuwo.cn（mp3/aac）→ LX 社区 API
//
// 通道 B —— 聆阅 App 的秒哒 Supabase Edge Functions（仅作兜底，全项目共享并发额度，429 高发）
//   /kuwo-search?keyword=&pn=&rn=    /kuwo-albuminfo?albumId=    /kuwo-play?rid=&quality=128
//   价值点：kuwo-albuminfo 的 chapters[].paid 是官方付费标记（PHP 通道的 pay 字段需逐章请求）
//
// 说明：搜索接口返回曲目，按 albumid 聚合成书；目录为服务端分页。
({
  id: 'tingshu-json-lingyue-kw',
  version: 2,
  name: '聆阅·源B-KW',
  apiVersion: 1,

  // ── 通道 A：PHP 代理 ──
  _bases: ['http://www.tingshu8.top', 'http://115.190.207.125'],
  _anti: 'http://antiserver.kuwo.cn/anti.s',
  _resolver: 'https://higequ.com/player/',
  // ── 通道 B：Supabase（兜底）──
  _edge: 'https://backend.appmiaoda.com/projects/supabase345057433544081408/functions/v1',
  _edgeKey: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJhdWQiOiJhdXRoZW50aWNhdGVkIiwiZXhwIjoyMTAxNjk1MzAzLCJpc3MiOiJzdXBhYmFzZSIsInJvbGUiOiJhbm9uIiwic3ViIjoiYW5vbiJ9.d_zv-NO7ifqZtHZHdEFYo0Kaxldn9NeW7Yy4YmHnsnc',

  _ua: 'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36',
  _lxUa: 'lx-music-request/2.0.0',

  _antiCache: {}, _albumCache: {}, _payCache: {}, _queue: null, _lastReqAt: 0,

  _sleep(ms) { return new Promise(r => setTimeout(r, ms)) },

  // ── 全局限流闸门：所有 PHP 请求串行化并保持最小间隔（站点对高频访问返回 429）──
  _gate() {
    const prev = this._queue || Promise.resolve()
    const job = prev
      .then(() => this._sleep(Math.max(0, this._lastReqAt + 300 - Date.now()) + Math.floor(Math.random() * 150)))
      .then(() => { this._lastReqAt = Date.now() })
    this._queue = job.catch(() => {})
    return job
  },

  _raw(url, referer) {
    return new Promise((resolve, reject) => {
      uni.request({
        url, method: 'GET',
        header: { 'User-Agent': this._ua, Referer: referer || (this._bases[0] + '/') },
        timeout: 20000,
        success: r => resolve({
          statusCode: r.statusCode || 0,
          text: typeof r.data === 'string' ? r.data : JSON.stringify(r.data),
          data: r.data,
        }),
        fail: e => reject(new Error(e.errMsg || '网络失败')),
      })
    })
  },

  // PHP 接口：多 base 轮询 + 429/5xx 线性退避重试
  async _api(path, params) {
    const qs = Object.keys(params || {}).map(k => k + '=' + encodeURIComponent(params[k])).join('&')
    let lastErr = null
    for (let attempt = 0; attempt < 2; attempt++) {
      for (const base of this._bases) {
        await this._gate()
        let r
        try {
          r = await this._raw(base + path + (qs ? '?' + qs : ''))
        } catch (e) {
          lastErr = e
          continue
        }
        if (r.statusCode === 429 || r.statusCode >= 500) {
          lastErr = new Error('HTTP ' + r.statusCode + ' | ' + base + path)
          await this._sleep(600 + attempt * 800 + Math.floor(Math.random() * 300))
          continue
        }
        if (r.statusCode >= 200 && r.statusCode < 300) return r.text
        lastErr = new Error('HTTP ' + r.statusCode + ' | ' + base + path)
      }
    }
    throw lastErr || new Error('接口请求失败')
  },

  // PHP 可能先输出 Warning 再输出 JSON，从第一个 { 开始解析
  _parse(text) {
    const s = String(text || '')
    const i = s.indexOf('{')
    try { return JSON.parse(i > 0 ? s.slice(i) : s) } catch (e) {
      throw new Error('接口返回异常：' + s.slice(0, 80))
    }
  },

  // ── 通道 B：Supabase Edge Function（带退避重试；429 时静默失败交由调用方兜底）──
  _edgeGet(fn, params, attempts) {
    const qs = Object.keys(params || {}).map(k => k + '=' + encodeURIComponent(params[k])).join('&')
    const url = this._edge + '/' + fn + (qs ? '?' + qs : '')
    const max = attempts || 3
    return (async () => {
      let lastErr = null
      for (let i = 0; i < max; i++) {
        try {
          const r = await new Promise((resolve, reject) => {
            uni.request({
              url, method: 'GET',
              header: {
                apikey: this._edgeKey,
                Authorization: 'Bearer ' + this._edgeKey,
                'User-Agent': 'okhttp/4.12.0',
              },
              timeout: 15000,
              success: resolve,
              fail: e => reject(new Error(e.errMsg || '网络失败')),
            })
          })
          if (r.statusCode !== 200) throw new Error('HTTP ' + r.statusCode)
          const d = typeof r.data === 'string' ? JSON.parse(r.data) : r.data
          // 并发超限：等一会儿再来
          if (d && d.code === 'projectConcurrencyLimitExceeded') {
            lastErr = new Error('Supabase 并发超限')
            await this._sleep(900 + i * 1200 + Math.floor(Math.random() * 400))
            continue
          }
          return d
        } catch (e) {
          lastErr = e
          await this._sleep(700 + i * 900)
        }
      }
      throw lastErr || new Error('Supabase 接口不可用')
    })()
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
      if (!groups[albumid]) {
        groups[albumid] = { albumid, album: String(t.album || '').trim(), artist: String(t.artist || ''), img: String(t.img || ''), tracks: [] }
        order.push(albumid)
      }
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
        _score: this._bookScore(g.album, g.artist, g.tracks, keyword),
      }
    }).filter(x => x.title)
    out.sort((a, b) => b._score - a._score)
    return out.map(x => ({ bookId: x.bookId, title: x.title, cover: x.cover, author: x.author, intro: x.intro }))
  },

  // 把 Edge 返回的 books[] 映射为统一 Book（字段与 PHP 通道口径一致）
  _edgeBooks(books) {
    return (Array.isArray(books) ? books : [])
      .map(b => ({
        bookId: String(b.id || ''),
        title: String(b.title || '').trim(),
        cover: String(b.cover || ''),
        author: this._cleanArtist(b.author || b.narrator),
        intro: String(b.description || '').replace(/\s+/g, ' ').trim().slice(0, 80),
      }))
      .filter(b => b.bookId && b.title)
  },

  async search(keyword, page = 1) {
    const kw = String(keyword || '').trim()
    const p = Math.max(1, Number(page) || 1)
    if (!kw) return { list: [], page: p, maxPage: 1, hasMore: false }

    // 主通道：PHP 双查询（原词 + 原词"有声"），合并聚合，听书专辑排前
    try {
      const kw2 = /有声|广播剧|评书|相声/.test(kw) ? kw : kw + ' 有声'
      const [r1, r2] = await Promise.all([
        this._api('/search.php', { all: kw, rn: 30, pn: p }).then(t => this._parse(t)).catch(() => null),
        this._api('/search.php', { all: kw2, rn: 30, pn: p }).then(t => this._parse(t)).catch(() => null),
      ])
      const tracks = []
        .concat(r1 && Array.isArray(r1.list) ? r1.list : [])
        .concat(r2 && Array.isArray(r2.list) ? r2.list : [])
      if (tracks.length) {
        const list = this._toBooks(tracks, kw)
        const maxPage = Math.max(Number(r1 && r1.totalpn) || 1, Number(r2 && r2.totalpn) || 1)
        return { list, page: p, maxPage, hasMore: p < maxPage && list.length > 0 }
      }
    } catch (e) {}

    // 兜底通道：Supabase kuwo-search（pn 从 0 起）
    const d = await this._edgeGet('kuwo-search', { keyword: kw, pn: p - 1, rn: 30 })
    const list = this._edgeBooks(d && d.books)
    const total = Number(d && d.total) || 0
    const pageSize = 30
    const maxPage = Math.max(1, Math.ceil(total / pageSize))
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
      return {
        info: { title: meta.title, cover: meta.cover, author: meta.author, intro: meta.intro, trackCount: meta.trackCount || 0, isFinished: false },
        list: [], page: p, maxPage: meta.totalpn, hasMore: false,
      }
    }

    if (!meta) {
      const first = this._parse(await this._api('/album.php', { id, rn, pn: 1 }))
      meta = {
        title: String(first.album || '').trim(),
        cover: String(first.img || '').trim(),
        author: this._cleanArtist(first.artist),
        intro: String(first.info || '').trim(),
        time: String(first.time || '').trim(),
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
      info: {
        title: meta.title, cover: meta.cover, author: meta.author, intro: meta.intro,
        trackCount, isFinished: await this._isFinished(id),
      },
      list: rows
        .map((x, i) => ({ chapterId: String(x.id || ''), index: offset + i + 1, name: String(x.name || '').trim() }))
        .filter(x => x.chapterId && x.name),
      page: p, maxPage: totalpn, hasMore: p < totalpn,
    }
  },

  // ── 完结态：Supabase meta.finished 唯一可靠来源，带缓存与静默降级 ──
  async _isFinished(albumId) {
    const entry = await this._ensurePayMap(albumId)
    return !!(entry && entry.finished)
  },

  // ── 付费映射：拉取 Supabase kuwo-albuminfo 并缓存（429 时多次退避重试）──
  async _ensurePayMap(albumId) {
    const hit = this._payCache[albumId]
    if (hit && Date.now() - hit.at < 3600000) return hit
    try {
      const d = await this._edgeGet('kuwo-albuminfo', { albumId }, 4)
      const paid = {}
      for (const c of (d && Array.isArray(d.chapters) ? d.chapters : [])) {
        if (c && c.id != null) paid[String(c.id)] = c.paid === true
      }
      const entry = { at: Date.now(), finished: !!(d && d.meta && d.meta.finished === true), paid }
      this._payCache[albumId] = entry
      return entry
    } catch (e) {
      return null
    }
  },

  // ── 付费标记：优先用缓存的 Supabase paid 映射，其次逐章 kuwo.php（零鉴权 PHP）──
  async _isPaid(rid) {
    for (const albumId of Object.keys(this._payCache)) {
      const entry = this._payCache[albumId]
      if (entry && entry.paid && String(rid) in entry.paid) return entry.paid[String(rid)] === true
    }
    try {
      const d = this._parse(await this._api('/kuwo.php', { rid }))
      const info = d && d.info
      if (!info) return null
      return Number(info.pay) > 0 || info.isListenFee === true
    } catch (e) {
      return null
    }
  },

  // ── 直链解析：主 higequ（任意酷我 rid → Base64 直链）──
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

  // 兜底一：酷我 antiserver（mp3 → aac）
  async _resolveViaAnti(rid) {
    const formats = ['mp3', 'aac']
    let lastBody = ''
    for (const fmt of formats) {
      const r = await this._raw(
        this._anti + '?type=convert_url&rid=MUSIC_' + rid + '&format=' + fmt + '&response=url',
        'http://www.kuwo.cn/'
      )
      const body = String(r.text || '').trim()
      lastBody = body
      if (r.statusCode >= 200 && r.statusCode < 300 && /^https?:\/\//i.test(body)) {
        return { url: body, headers: { 'User-Agent': this._ua, Referer: 'http://www.kuwo.cn/' } }
      }
      await this._sleep(400)
    }
    throw new Error('antiserver 无直链：' + lastBody.slice(0, 60))
  },

  // 兜底二：LX 社区解析 API（聆澜 GET → ikun POST）
  async _resolveViaLx(rid) {
    try {
      const r1 = await new Promise((resolve, reject) => {
        uni.request({
          url: 'https://source.shiqianjiang.cn/api/music/url?source=kw&songId=' + rid + '&quality=128k',
          header: { 'User-Agent': this._lxUa, 'X-API-Key': 'CERU_KEY-31C0DB0B-2DFF-42EF-A2DB-47863E658840' },
          timeout: 15000,
          success: resolve,
          fail: e => reject(new Error(e.errMsg || '网络失败')),
        })
      })
      if (r1 && r1.code === 200 && /^https?:\/\//i.test(r1.url || '')) {
        return { url: r1.url, headers: { 'User-Agent': this._ua } }
      }
    } catch (e) {}
    try {
      const r2 = await new Promise((resolve, reject) => {
        uni.request({
          url: 'https://c.wwwweb.top/music/url',
          method: 'POST',
          header: { 'Content-Type': 'application/json', 'User-Agent': this._lxUa, 'X-Api-Key': 'IKM-P18200001-AyKQrBcgmEyPDpRy-0t' },
          data: { source: 'kw', musicId: rid, quality: '128k' },
          timeout: 15000,
          success: resolve,
          fail: e => reject(new Error(e.errMsg || '网络失败')),
        })
      })
      if (r2 && r2.code === 200 && /^https?:\/\//i.test(r2.url || '')) {
        return { url: r2.url, headers: { 'User-Agent': this._ua } }
      }
    } catch (e) {}
    throw new Error('LX 解析通道均不可用')
  },

  async getAudioUrl(chapterId) {
    const rid = String(chapterId).replace(/^MUSIC_/, '').replace(/^\D+/, '')
    if (!/^\d+$/.test(rid)) throw new Error('无效的章节 ID：' + chapterId)

    const hit = this._antiCache[rid]
    if (hit && Date.now() - hit.at < 240000) return hit.value

    let value = null
    try { value = await this._resolveViaHigequ(rid) } catch (e) { value = null }
    if (!value) {
      try {
        value = await this._resolveViaAnti(rid)
      } catch (e) {
        try {
          value = await this._resolveViaLx(rid)
        } catch (e2) {
          throw new Error('获取播放直链失败（higequ/antiserver/LX 均不可用）：' + String(e2.message).slice(0, 80))
        }
      }
    }

    this._antiCache[rid] = { value, at: Date.now() }
    return value
  },
})
