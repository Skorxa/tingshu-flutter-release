// 懒人听书（m.lrts.me 官方接口 + 爱听书API 音频兜底）
// 搜索:  GET https://m.lrts.me/ajax/searchBook?keyWord=&pageNum=            （官方，不限速）
// 目录:  GET https://m.lrts.me/ajax/getBookMenu?bookId=&pageNum=&pageSize=50 （官方，50集/页）
// 音频1: GET https://m.lrts.me/ajax/getPlayPath?entityId=&entityType=3&opType=1&sections=[N]&type=0  （官方，免费章节）
// 音频2: GET https://fm.12311111.xyz/api/lrts/index.php?act=audio&bookId=&section=&opType=1          （付费章节兜底）
// 说明:  官方音频通道免费章节可用且不限速；付费/VIP 章节官方不给地址。
//        「音源设置」填入爱听书 VIP 密钥后启用 VIP 通道（付费章节可听）；留空则只走免费线路。
//        VIP 接口同 IP 每 30 秒 1 次，但返回地址 ttl=86400000 即 24 小时有效，故本地长缓存，影响很小
({
  id: 'tj-lrts',
  name: '懒人听书',
  apiVersion: 1,
  _site: 'https://m.lrts.me',
  _api: 'https://fm.12311111.xyz/api/lrts/index.php',
  _ua: 'Mozilla/5.0 (Linux; Android 12; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
  _page: 50, _parallel: 5,
  _chapterCache: {}, _audioCache: {}, _queue: null, _lastReqAt: 0,
  configFields: [
    {
      key: 'vipKey',
      label: '爱听书 VIP 密钥',
      type: 'text',
      hint: '留空 = 只走免费线路（官方接口能给的章节）；填入密钥后启用 VIP 通道，付费/会员章节也可收听',
      required: false
    }
  ],

  _vipKey() { const c = this.config || {}; return String(c.vipKey || '').trim() },
  // ── 音频接口限速处理：同 IP 每 30 秒 1 次 ──
  // 策略 1（自动等待）：把 30 秒窗口排在源内，等窗口过去再请求，用户看到的是稍长的加载而不是报错
  // 策略 2（后台预取）：一集解析成功后就排队预取下一集，使连播/手动切下一集基本秒开
  // 策略 3（长缓存）：返回地址 ttl=24h，本地缓存 12h，重复播放不再占用窗口
  _apiCallAt: 0,
  // 速率自适应：赞助通道约 30 次/分钟（≈2 秒/次），免费通道 30 秒/次。
  // 起步按赞助档乐观尝试；被拒则按服务端「请 N 秒后再试」的秒数抬高冷却并沿用。
  _apiCooldown: 2400, _apiCooldownMax: 35000, _prefetching: {},

  _sleep(ms) { return new Promise(r => setTimeout(r, ms)) },
  _gate() {
    const prev = this._queue || Promise.resolve()
    const job = prev.then(() => this._sleep(Math.max(0, this._lastReqAt + 120 - Date.now()) + Math.floor(Math.random() * 80))).then(() => { this._lastReqAt = Date.now() })
    this._queue = job.catch(() => {})
    return job
  },
  async _get(url) {
    await this._gate()
    const r = await new Promise((resolve, reject) => {
      uni.request({
        url, method: 'GET',
        header: { 'User-Agent': this._ua, Accept: 'application/json', Referer: this._site + '/' },
        timeout: 20000,
        success: x => resolve({ statusCode: x.statusCode || 0, data: x.data }),
        fail: e => reject(new Error(e.errMsg || '网络失败'))
      })
    })
    if (r.statusCode < 200 || r.statusCode >= 300) throw new Error('HTTP ' + r.statusCode + ' | ' + url.slice(0, 70))
    if (r.data && typeof r.data === 'object') return r.data
    const s = String(r.data || '')
    const i = s.indexOf('{')
    try { return JSON.parse(i > 0 ? s.slice(i) : s) } catch (e) { throw new Error('返回不是 JSON') }
  },
  _clean(s) { return String(s || '').replace(/^\uFEFF/, '').replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ').trim() },
  _cover(u) {
    let s = String(u || '').trim()
    if (!s) return ''
    if (s.indexOf('//') === 0) s = 'https:' + s
    return s.replace(/^http:/, 'https:')
  },
  _pack(v) { return encodeURIComponent(JSON.stringify(v)) },
  _unpack(s) { try { return JSON.parse(decodeURIComponent(String(s || ''))) } catch (e) { return {} } },

  _toBook(it) {
    const count = Number(it.sections || it.count || 0)
    const tags = []
    if (Number(it.vipLibrary) === 1 || (it.tags && String(it.tags).indexOf('VIP') >= 0)) tags.push('VIP')
    if (String(it.state) === '2') tags.push('完结')
    return {
      bookId: this._pack({ id: String(it.id || ''), t: this._clean(it.name || ''), c: this._cover(it.cover || ''), a: this._clean(it.announcer || it.author || '') }),
      title: this._clean(it.name || ''),
      cover: this._cover(it.cover || ''),
      author: [this._clean(it.announcer || ''), this._clean(it.author || '')].filter(Boolean).join(' / '),
      intro: (tags.length ? tags.join(' · ') + ' · ' : '') + (count ? count + '集' : '') + (it.score ? ' · ' + it.score + '分' : '')
    }
  },

  async search(keyword, page = 1) {
    const kw = String(keyword || '').trim()
    const p = Math.max(1, Number(page) || 1)
    if (!kw) return { list: [], page: p, maxPage: 1, hasMore: false }
    const j = await this._get(this._site + '/ajax/searchBook?keyWord=' + encodeURIComponent(kw) + '&pageNum=' + p)
    if (Number(j.apiStatus) !== 0 && Number(j.status) !== 0) throw new Error(this._clean(j.msg) || '搜索失败')
    const rows = Array.isArray(j.list) ? j.list : []
    return {
      list: rows.map(x => this._toBook(x)).filter(b => b.title && b.bookId),
      page: p,
      maxPage: Number(j.hasNext) ? p + 1 : p,
      hasMore: !!Number(j.hasNext)
    }
  },

  async discover() {
    const cats = ['玄幻', '都市', '历史', '悬疑', '评书', '相声', '儿童', '武侠']
    const loaded = new Array(cats.length)
    let next = 0
    const worker = async () => {
      while (next < cats.length) {
        const i = next++
        try {
          const list = (await this.search(cats[i], 1)).list.slice(0, 12)
          if (list.length) loaded[i] = { title: cats[i], list }
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
      let start = 1
      while (start <= 300) {
        const reqs = []
        for (let k = 0; k < this._parallel; k++) {
          const pn = start + k
          reqs.push(this._get(this._site + '/ajax/getBookMenu?bookId=' + id + '&pageNum=' + pn + '&pageSize=' + this._page).catch(() => null))
        }
        const pages = await Promise.all(reqs)
        let stop = false
        for (const pg of pages) {
          if (!pg) { stop = true; break }
          const rows = Array.isArray(pg.list) ? pg.list : []
          if (!rows.length) { stop = true; break }
          for (const t of rows) {
            const sec = Number(t.section || t.index || 0)
            if (!sec) continue
            list.push({ section: sec, name: this._clean(t.name || '') })
          }
          if (rows.length < this._page) { stop = true; break }
        }
        if (stop) break
        start += this._parallel
      }
      if (!list.length) throw new Error('目录为空或专辑已下架')
      list.sort((a, b) => a.section - b.section)
      entry = {
        info: { title: String(meta.t || ''), cover: String(meta.c || ''), author: String(meta.a || ''), trackCount: list.length, isFinished: false },
        list
      }
      this._chapterCache[id] = entry
    }
    const maxPage = Math.max(1, Math.ceil(entry.list.length / size))
    const safePage = Math.max(1, Math.min(p, maxPage))
    const startIdx = (safePage - 1) * size
    return {
      info: entry.info,
      list: entry.list.slice(startIdx, startIdx + size).map((x, i) => ({
        chapterId: id + '|' + x.section,
        index: x.section || (startIdx + i + 1),
        name: x.name || ('第' + (startIdx + i + 1) + '集')
      })),
      page: safePage, maxPage, hasMore: safePage < maxPage
    }
  },

  // 音频通道 2：爱听书API（付费/VIP 兜底），内部消化限速（免费档 30 秒/次、赞助档约 2 秒/次）
  // 仅在设置了 VIP 密钥时启用；未填密钥时付费章节直接给出提示
  async _apiAudio(bookId, section) {
    const k = this._vipKey()
    if (!k) throw new Error('该章节需要会员或购买后才能收听；可在音源设置里填入「爱听书 VIP 密钥」后收听')
    const url0 = this._api + '?act=audio&bookId=' + bookId + '&section=' + section + '&opType=1&key=' + encodeURIComponent(k)
    const call = async () => {
      const wait = this._apiCallAt + this._apiCooldown - Date.now()
      if (wait > 0) await this._sleep(wait)
      const j = await this._get(url0)
      this._apiCallAt = Date.now()
      const env = j.data || {}
      const dd = env.data || env
      return { url: String(dd.url || ''), msg: this._clean(dd.error || env.msg || '') }
    }
    let r = await call()
    // 撞上限速：按服务端给的秒数抬高冷却后重试（赞助档不会走到这里）
    if (!/^https?:\/\//i.test(r.url) && r.msg.indexOf('频繁') >= 0) {
      const sec = Number((r.msg.match(/(\d+)\s*秒/) || [])[1] || 30)
      this._apiCooldown = Math.min(this._apiCooldownMax, Math.max(this._apiCooldown * 3, sec * 1000 + 1200))
      r = await call()
    }
    let url = r.url
    let msg = r.msg
    if (!/^https?:\/\//i.test(url)) {
      const err = new Error('该章节暂不可播放' + (msg ? '：' + msg : ''))
      err._rateLimited = msg.indexOf('频繁') >= 0
      throw err
    }
    const value = { url, headers: { 'User-Agent': this._ua } }
    this._audioCache[bookId + '|' + section] = { value, at: Date.now(), ttl: 12 * 60 * 60 * 1000 }
    return value
  },

  // 后台预取：当前集解析完成后，等窗口轮到就解析下一集，让连播无缝
  _schedulePrefetch(bookId, section) {
    if (!this._vipKey()) return
    const key = bookId + '|' + section
    if (this._prefetching[key]) return
    const meta = this._chapterCache[bookId]
    if (!meta) return
    const idx = meta.list.findIndex(x => Number(x.section) === Number(section))
    if (idx < 0 || idx + 1 >= meta.list.length) return
    const next = Number(meta.list[idx + 1].section)
    if (!next) return
    const nextKey = bookId + '|' + next
    const hit = this._audioCache[nextKey]
    if (hit && Date.now() - hit.at < hit.ttl) return
    this._prefetching[key] = true
    const self = this
    setTimeout(function () {
      self._apiAudio(String(bookId), next)
        .catch(function () {})
        .then(function () { self._prefetching[key] = false })
    }, this._apiCooldown + 400)
  },

  async getAudioUrl(chapterId) {
    const s = String(chapterId || '')
    const sep = s.indexOf('|')
    if (sep < 1) throw new Error('无效的章节 ID')
    const bookId = s.slice(0, sep)
    const section = Number(s.slice(sep + 1)) || 1
    const hit = this._audioCache[s]
    if (hit && Date.now() - hit.at < hit.ttl) return hit.value

    // 通道 1：官方 getPlayPath（免费章节，不限速）
    try {
      const j = await this._get(this._site + '/ajax/getPlayPath?entityId=' + bookId + '&entityType=3&opType=1&sections=[' + section + ']&type=0')
      const list = Array.isArray(j.list) ? j.list : []
      let path = ''
      for (const x of list) {
        const p = String((x && (x.path || x.url)) || '')
        if (/^https?:\/\//i.test(p)) { path = p; break }
      }
      if (path) {
        const value = { url: path.replace(/^http:/, 'https:'), headers: { 'User-Agent': this._ua } }
        this._audioCache[s] = { value, at: Date.now(), ttl: 4 * 60 * 1000 }
        this._schedulePrefetch(bookId, section)
        return value
      }
    } catch (e) {}

    // 通道 2：爱听书API（付费/VIP 章节兜底，源内自动等窗口）
    const value = await this._apiAudio(bookId, section)
    this._schedulePrefetch(bookId, section)
    return value
  }
})