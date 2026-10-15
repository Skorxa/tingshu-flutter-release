// 喜马拉雅（ximalaya.com 官方公开接口）
// 搜索:  GET  https://search.ximalaya.com/front/v1?core=album&kw=&page=&rows=20&spellchecker=true&condition=relation&device=android&version=9.0.75
// 分类:  GET  https://www.ximalaya.com/revision/category/allCategoryInfo
// 分类专辑: GET https://www.ximalaya.com/revision/category/queryCategoryPageAlbums?category=&subcategory=&meta=&sort=0&page=&perPage=30
// 专辑:  GET  https://www.ximalaya.com/revision/album/v1/simple?albumId=
// 章节:  GET  https://mobile.ximalaya.com/mobile/v1/album/track?albumId=&pageId=&pageSize=200&isAsc=true&device=android
// 播放:  GET  https://mobile.ximalaya.com/mobile/v1/track/{trackId}?device=android  → playUrl64/playUrl32（明文直链，无需解密）
// 要点:  移动接口必须同时带 App 版 UA 与设备 Cookie，否则返回 924「内容已下架」
// VIP:   官方接口对付费章节不给地址。在「音源设置」填入爱听书 VIP 密钥后启用兜底通道：
//        GET {_api}?act=audio&bookId=&chapterId=&key= → 可收听会员/付费章节
//        留空则只走免费线路（官方通道），付费章节给出提示而不报错
({
  id: 'tj-ximalaya',
  name: '喜马拉雅',
  apiVersion: 1,
  _uaWeb: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36',
  _uaApp: 'ting_6.6.99(c0b8f2a4db1a8c6c1b7e1a3d0f2c4b6e)',
  _channels: [['有声小说', 'youshengshu'], ['广播剧', 'guangbojv'], ['相声评书', 'xiangsheng'], ['儿童', 'ertong'], ['历史', 'lishi'], ['人文', 'renwen'], ['戏曲', 'xiqu'], ['情感', 'qinggan']],
  _chapterCache: {}, _audioCache: {}, _queue: null, _lastReqAt: 0, _devCookie: '',
  // VIP 兜底接口（爱听书API）：同 IP 每 30 秒 1 次，返回地址有效 24 小时
  // 未填密钥时不调用该接口，只走官方免费线路；填了密钥才启用 VIP 通道
  _api: 'https://fm.12311111.xyz/api/ximalaya/index.php',
  // 速率自适应：赞助通道约 30 次/分钟（≈2 秒/次），免费通道 30 秒/次。
  // 起步按赞助档乐观尝试；若被拒则解析服务端「请 N 秒后再试」的秒数，抬高冷却后重试并沿用该档位。
  _apiCallAt: 0, _apiCooldown: 2400, _apiCooldownMax: 35000, _prefetching: {},
  configFields: [
    {
      key: 'vipKey',
      label: '爱听书 VIP 密钥',
      type: 'text',
      hint: '留空 = 只走免费线路（会员/付费章节不可听）；填入密钥后启用 VIP 通道，可收听会员与付费章节',
      required: false
    }
  ],

  _vipKey() { const c = this.config || {}; return String(c.vipKey || '').trim() },

  _cookie() {
    if (!this._devCookie) {
      let s = '', hex = '0123456789abcdef'
      for (let i = 0; i < 32; i++) s += hex[Math.floor(Math.random() * 16)]
      const uuid = s.slice(0, 8) + '-' + s.slice(8, 12) + '-4' + s.slice(13, 16) + '-a' + s.slice(17, 20) + '-' + s.slice(20, 32)
      this._devCookie = '1&_device=android&' + uuid + '&ting_6.6.99&ximalaya&android&23&1&ios'
    }
    return this._devCookie
  },
  _sleep(ms) { return new Promise(r => setTimeout(r, ms)) },
  _gate() {
    const prev = this._queue || Promise.resolve()
    const job = prev.then(() => this._sleep(Math.max(0, this._lastReqAt + 250 - Date.now()) + Math.floor(Math.random() * 120))).then(() => { this._lastReqAt = Date.now() })
    this._queue = job.catch(() => {})
    return job
  },
  async _get(url, mobile, timeout) {
    await this._gate()
    const headers = mobile
      ? { 'User-Agent': this._uaApp, Cookie: this._cookie(), Referer: 'https://www.ximalaya.com/' }
      : { 'User-Agent': this._uaWeb, Accept: 'application/json, text/plain, */*', Referer: 'https://www.ximalaya.com/' }
    const r = await new Promise((resolve, reject) => {
      uni.request({
        url, method: 'GET', header: headers, timeout: timeout || 20000,
        success: x => resolve({ statusCode: x.statusCode || 0, data: x.data }),
        fail: e => reject(new Error(e.errMsg || '网络失败'))
      })
    })
    if (r.statusCode < 200 || r.statusCode >= 300) throw new Error('HTTP ' + r.statusCode + ' | ' + url.slice(0, 70))
    if (r.data && typeof r.data === 'object') return r.data
    try { return JSON.parse(String(r.data || '')) } catch (e) { throw new Error('返回不是 JSON') }
  },
  _clean(s) { return String(s || '').replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ').trim() },
  _cover(u) {
    let s = String(u || '').trim()
    if (!s) return ''
    if (s.indexOf('//') === 0) s = 'https:' + s
    s = s.replace(/^http:/, 'https:')
    return s.split('!')[0] + '!op_type=3&columns=290&rows=290'
  },
  _pack(v) { return encodeURIComponent(JSON.stringify(v)) },
  _unpack(s) { try { return JSON.parse(decodeURIComponent(String(s || ''))) } catch (e) { return {} } },

  _toBook(a) {
    const count = Number(a.trackCount || a.tracks || 0)
    const paid = (a.isPaid === true || a.is_paid === true) ? ' · 付费' : ''
    const fin = String(a.isFinished === true || a.is_finished === 2 || a.is_finished === true ? '完结' : '连载')
    return {
      bookId: this._pack({ id: String(a.albumId || a.id || ''), t: this._clean(a.title || a.albumTitle || ''), c: this._cover(a.coverPath || a.cover || a.cover_path || ''), a: this._clean(a.anchorName || a.nickname || '') }),
      title: this._clean(a.title || a.albumTitle || ''),
      cover: this._cover(a.coverPath || a.cover || a.cover_path || ''),
      author: this._clean(a.anchorName || a.nickname || ''),
      intro: fin + (count ? ' · ' + count + '集' : '') + paid
    }
  },

  // ── 搜索 ──
  // 主通道走爱听书API 的搜索：索引比官方 search.ximalaya.com 全得多
  //   例：官方搜「偷香高手 头陀渊」→ 0 条（官方对多词做全词命中），该接口 → 1 条且正是目标专辑
  //   同一关键词官方 13 条，该接口 20 条
  async _searchApi(kw, p) {
    const j = await this._get(this._api + '?act=search&keyword=' + encodeURIComponent(kw) + '&page=' + p, false, 20000)
    const env = (j && j.data) || {}
    const d = env.data || env
    const rows = Array.isArray(d.list) ? d.list : []
    return rows.map(x => this._toBook({
      albumId: x.id, title: x.bookTitle, coverPath: x.bookImage,
      anchorName: x.bookAnchor, trackCount: x.count
    })).filter(b => b.title && b.bookId)
  },
  async _searchOfficial(kw, p) {
    const j = await this._get('https://search.ximalaya.com/front/v1?core=album&kw=' + encodeURIComponent(kw) +
      '&page=' + p + '&rows=20&spellchecker=true&condition=relation&device=android&version=9.0.75', false)
    const resp = j.response || {}
    const docs = Array.isArray(resp.docs) ? resp.docs : []
    return docs.map(d => this._toBook({
      albumId: d.id, title: d.title, coverPath: d.cover_path, anchorName: d.nickname,
      trackCount: d.tracks, isPaid: d.is_paid, is_finished: d.is_finished
    })).filter(b => b.title && b.bookId)
  },

  async search(keyword, page = 1) {
    const kw = String(keyword || '').trim()
    const p = Math.max(1, Number(page) || 1)
    if (!kw) return { list: [], page: p, maxPage: 1, hasMore: false }
    let apiList = []
    let apiErr = ''
    try { apiList = await this._searchApi(kw, p) } catch (e) { apiErr = e.message || String(e) }
    let list = apiList
    if (!list.length) {
      try { list = await this._searchOfficial(kw, p) } catch (e) {}
    }
    // API 不可用且官方也没结果时，把真实原因抛出来 —— 静默兜底会让人误以为「源还在用官方搜索」
    if (!list.length && apiErr) {
      throw new Error('搜索接口不可达（' + apiErr.slice(0, 80) + '）')
    }
    const hasMore = list.length >= 20
    return { list, page: p, maxPage: hasMore ? p + 1 : p, hasMore }
  },

  async discover() {
    const loaded = new Array(this._channels.length)
    let next = 0
    const worker = async () => {
      while (next < this._channels.length) {
        const i = next++
        try {
          const j = await this._get('https://www.ximalaya.com/revision/category/queryCategoryPageAlbums?category=' +
            this._channels[i][1] + '&subcategory=&meta=&sort=0&page=1&perPage=12', false)
          const al = (j.data && Array.isArray(j.data.albums)) ? j.data.albums : []
          const list = al.map(a => this._toBook(a)).filter(b => b.title)
          if (list.length) loaded[i] = { title: this._channels[i][0], list }
        } catch (e) {}
      }
    }
    await Promise.all([worker(), worker()])
    return { sections: loaded.filter(Boolean) }
  },

  async getChapters(bookId, page = 1, pageSize = 30) {
    const meta = this._unpack(bookId)
    const id = String(meta.id || '')
    if (!/^\d+$/.test(id)) throw new Error('无效的专辑 ID')
    const p = Math.max(1, Number(page) || 1)
    const size = Math.max(1, Math.min(Number(pageSize) || 30, 100))
    let entry = this._chapterCache[id]
    if (!entry) {
      const list = []
      const per = 200
      let maxPage = 1
      for (let pageId = 1; pageId <= 30; pageId++) {
        const j = await this._get('https://mobile.ximalaya.com/mobile/v1/album/track?albumId=' + id +
          '&pageId=' + pageId + '&pageSize=' + per + '&isAsc=true&device=android', true, 25000)
        if (Number(j.ret) !== 0 && list.length === 0) {
          throw new Error('喜马拉雅：' + (this._clean(j.msg) || '获取章节失败（' + j.ret + '）'))
        }
        const d = j.data || {}
        const rows = Array.isArray(d.list) ? d.list : []
        for (const t of rows) {
          const tid = String(t.trackId || '')
          const name = this._clean(t.title || '')
          if (tid && name) list.push({ id: tid, name })
        }
        maxPage = Number(d.maxPageId || 1) || 1
        if (rows.length === 0 || pageId >= maxPage) break
      }
      if (!list.length) throw new Error('目录为空或该专辑已下架')
      entry = {
        info: { title: String(meta.t || ''), cover: String(meta.c || ''), author: String(meta.a || ''), trackCount: list.length, isFinished: false },
        list
      }
      this._chapterCache[id] = entry
    }
    const maxPage = Math.max(1, Math.ceil(entry.list.length / size))
    const safePage = Math.max(1, Math.min(p, maxPage))
    const start = (safePage - 1) * size
    return {
      info: entry.info,
      // chapterId 带专辑号：官方接口只用 trackId，但 VIP 兜底接口需要 bookId
      list: entry.list.slice(start, start + size).map((x, i) => ({ chapterId: id + '|' + x.id, index: start + i + 1, name: x.name })),
      page: safePage, maxPage, hasMore: safePage < maxPage
    }
  },

  // ── VIP / 付费章节兜底：爱听书API ──
  // GET {_api}?act=audio&bookId=&chapterId= → {code,msg,data:{url}}
  // 官方接口对付费章节不给地址，这个接口能给；代价是同 IP 每 30 秒 1 次音频请求，
  // 但返回地址有效 24 小时，故源内「自动等窗口 + 长缓存 + 预取下一集」消化掉限速
  async _apiAudio(albumId, trackId) {
    const k = this._vipKey()
    if (!k) throw new Error('该集需要会员或购买后才能收听；可在音源设置里填入「爱听书 VIP 密钥」后收听')
    const call = async () => {
      const wait = this._apiCallAt + this._apiCooldown - Date.now()
      if (wait > 0) await this._sleep(wait)
      const j = await this._get(this._api + '?act=audio&bookId=' + encodeURIComponent(albumId) +
        '&chapterId=' + encodeURIComponent(trackId) + '&key=' + encodeURIComponent(k), false, 25000)
      this._apiCallAt = Date.now()
      const env = (j && j.data) || {}
      const d = env.data || env
      return { url: String(d.url || ''), msg: this._clean(d.error || env.msg || '') }
    }
    let r = await call()
    if (!/^https?:\/\//i.test(r.url) && r.msg.indexOf('频繁') >= 0) {
      // 撞上限速：按服务端给的秒数抬高冷却（免费档约 30 秒，赞助档不会走到这里）
      const sec = Number((r.msg.match(/(\d+)\s*秒/) || [])[1] || 30)
      this._apiCooldown = Math.min(this._apiCooldownMax, Math.max(this._apiCooldown * 3, sec * 1000 + 1200))
      r = await call()
    }
    if (!/^https?:\/\//i.test(r.url)) throw new Error('该章节暂不可播放' + (r.msg ? '：' + r.msg : ''))
    return r.url
  },

  // 后台预取下一集（VIP 章节每次解析要占用 30 秒窗口，预取能让连播无缝）
  _schedulePrefetch(albumId, trackId) {
    if (!this._vipKey()) return
    const meta = this._chapterCache[albumId]
    if (!meta) return
    const idx = meta.list.findIndex(x => String(x.id) === String(trackId))
    if (idx < 0 || idx + 1 >= meta.list.length) return
    const next = String(meta.list[idx + 1].id)
    const key = albumId + '|' + next
    const hit = this._audioCache[key]
    if (hit && Date.now() - hit.at < hit.ttl) return
    if (this._prefetching[key]) return
    this._prefetching[key] = true
    const self = this
    setTimeout(function () {
      self._apiAudio(albumId, next)
        .then(function (url) {
          self._audioCache[key] = {
            value: { url: url.replace(/^http:/, 'https:'), headers: { 'User-Agent': self._uaApp, Referer: 'https://www.ximalaya.com/' } },
            at: Date.now(), ttl: 12 * 60 * 60 * 1000
          }
        })
        .catch(function () {})
        .then(function () { self._prefetching[key] = false })
    }, this._apiCooldown + 400)
  },

  async getAudioUrl(chapterId) {
    const s = String(chapterId || '')
    const sep = s.indexOf('|')
    const albumId = sep > 0 ? s.slice(0, sep) : ''
    const tid = String(sep > 0 ? s.slice(sep + 1) : s).replace(/\D/g, '')
    if (!tid) throw new Error('无效的章节 ID')
    const hit = this._audioCache[s]
    if (hit && Date.now() - hit.at < hit.ttl) return hit.value

    // 通道 1：官方移动接口（免费内容，不限速）
    let msg = ''
    try {
      const j = await this._get('https://mobile.ximalaya.com/mobile/v1/track/' + tid + '?device=android', true, 20000)
      const url = String(j.playUrl64 || j.playUrl32 || j.playPathAacv224 || j.downloadUrl || '')
      msg = this._clean(j.msg || '')
      if (/^https?:\/\//i.test(url)) {
        const value = { url: url.replace(/^http:/, 'https:'), headers: { 'User-Agent': this._uaApp, Referer: 'https://www.ximalaya.com/' } }
        this._audioCache[s] = { value, at: Date.now(), ttl: 4 * 60 * 1000 }
        return value
      }
    } catch (e) { msg = e.message }

    // 通道 2：付费/VIP 兜底（仅在设置了 VIP 密钥时启用）
    if (!albumId) throw new Error('该集需要会员或购买后才能收听' + (msg ? '（' + msg + '）' : ''))
    const url = await this._apiAudio(albumId, tid)
    const value = { url: url.replace(/^http:/, 'https:'), headers: { 'User-Agent': this._uaApp, Referer: 'https://www.ximalaya.com/' } }
    this._audioCache[s] = { value, at: Date.now(), ttl: 12 * 60 * 60 * 1000 }
    this._schedulePrefetch(albumId, tid)
    return value
  }
})