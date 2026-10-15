// 听友FM（tingyou.fm · 新版明文 JSON API）
// 搜索:   POST {base}/h5/listening/search          body {keyword, page}
// 榜单:   GET  {base}/h5/listening/rank?section=recommend|hot|serial|storytelling&page=1
// 专辑:   GET  {base}/h5/listening/album/{id}
// 章节:   GET  {base}/h5/listening/chapters/{id}    （一次返回全量 chapters[]）
// 播放:   POST {base}/h5/listening/play             body {album_id:"<字符串>", chapter_idx:<数字>} → {play_url}
// 通用头: accept / x-listening-session(UUID) / x-listening-timezone / origin / referer
// 注意:   album_id 必须是字符串，传数字会报「听书分类参数无效」
({
  id: 'tingyou',
  name: '听友FM',
  apiVersion: 1,
  _bases: ['https://laopoaappi.oobyvy.vip/api', 'https://appp.fdhtbz.cn/api'],
  _ua: 'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Mobile Safari/537.36',
  _site: 'https://www.tingyou.fm',
  _sections: [['推荐', 'recommend'], ['热门', 'hot'], ['连载', 'serial'], ['评书', 'storytelling']],
  _chapterCache: {}, _audioCache: {}, _queue: null, _lastReqAt: 0, _sid: '',

  _uuid() {
    if (!this._sid) {
      let s = ''
      const hex = '0123456789abcdef'
      for (let i = 0; i < 32; i++) s += hex[Math.floor(Math.random() * 16)]
      this._sid = s.slice(0, 8) + '-' + s.slice(8, 12) + '-4' + s.slice(13, 16) + '-a' + s.slice(17, 20) + '-' + s.slice(20, 32)
    }
    return this._sid
  },
  _sleep(ms) { return new Promise(r => setTimeout(r, ms)) },
  _gate() {
    const prev = this._queue || Promise.resolve()
    const job = prev.then(() => this._sleep(Math.max(0, this._lastReqAt + 250 - Date.now()) + Math.floor(Math.random() * 120))).then(() => { this._lastReqAt = Date.now() })
    this._queue = job.catch(() => {})
    return job
  },
  _headers(json) {
    const h = {
      'User-Agent': this._ua,
      Accept: 'application/json',
      'x-listening-session': this._uuid(),
      'x-listening-timezone': 'Asia/Shanghai',
      Origin: this._site,
      Referer: this._site + '/'
    }
    if (json) h['Content-Type'] = 'application/json'
    return h
  },
  async _req(path, opts) {
    opts = opts || {}
    let lastErr = null
    for (const base of this._bases) {
      await this._gate()
      try {
        const r = await new Promise((resolve, reject) => {
          uni.request({
            url: base + path,
            method: opts.method || 'GET',
            data: opts.body,
            header: this._headers(!!opts.body),
            timeout: 20000,
            success: x => resolve({ statusCode: x.statusCode || 0, data: x.data }),
            fail: e => reject(new Error(e.errMsg || '网络失败'))
          })
        })
        if (r.statusCode >= 200 && r.statusCode < 300) {
          if (r.data && typeof r.data === 'object') return r.data
          try { return JSON.parse(String(r.data || '')) } catch (e) { throw new Error('返回不是 JSON') }
        }
        lastErr = new Error('HTTP ' + r.statusCode + ' | ' + path)
      } catch (e) { lastErr = e }
    }
    throw lastErr || new Error('接口请求失败')
  },
  _clean(s) { return String(s || '').replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ').trim() },
  _pack(v) { return encodeURIComponent(JSON.stringify(v)) },
  _unpack(s) { try { return JSON.parse(decodeURIComponent(String(s || ''))) } catch (e) { return {} } },

  _toBook(it) {
    const count = Number(it.count || 0)
    const teller = this._clean(it.teller || '')
    const author = this._clean(it.author || '')
    const tags = [this._clean(it.type || ''), this._clean(it.cat || '')].filter(Boolean).join('·')
    const intro = []
    if (tags) intro.push(tags)
    if (count) intro.push(count + '集')
    if (Number(it.status) === 1) intro.push('连载中')
    return {
      bookId: this._pack({ id: String(it.id), t: this._clean(it.title || ''), c: String(it.cover_url || ''), a: teller || author }),
      title: this._clean(it.title || ''),
      cover: String(it.cover_url || ''),
      author: [author, teller].filter(Boolean).join(' / '),
      intro: intro.join(' · ')
    }
  },

  async search(keyword, page = 1) {
    const kw = String(keyword || '').trim()
    const p = Math.max(1, Number(page) || 1)
    if (!kw) return { list: [], page: p, maxPage: 1, hasMore: false }
    const j = await this._req('/h5/listening/search', { method: 'POST', body: { keyword: kw, page: p } })
    const rows = Array.isArray(j.results) ? j.results : []
    return {
      list: rows.map(x => this._toBook(x)).filter(b => b.title && b.bookId),
      page: p,
      maxPage: j.has_more ? p + 1 : p,
      hasMore: !!j.has_more
    }
  },

  async discover() {
    const loaded = new Array(this._sections.length)
    let next = 0
    const worker = async () => {
      while (next < this._sections.length) {
        const i = next++
        try {
          const j = await this._req('/h5/listening/rank?section=' + this._sections[i][1] + '&page=1')
          const rows = Array.isArray(j.items) ? j.items : []
          const list = rows.map(x => this._toBook(x)).filter(b => b.title).slice(0, 12)
          if (list.length) loaded[i] = { title: this._sections[i][0], list }
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
      const j = await this._req('/h5/listening/chapters/' + encodeURIComponent(id))
      const rows = Array.isArray(j.chapters) ? j.chapters : []
      const list = rows
        .map(x => ({ index: Number(x.index) || 0, name: this._clean(x.title || '') }))
        .filter(x => x.name)
        .sort((a, b) => a.index - b.index)
      if (!list.length) throw new Error('目录为空或专辑已失效')
      entry = {
        info: {
          title: String(meta.t || ''),
          cover: String(meta.c || ''),
          author: String(meta.a || ''),
          trackCount: list.length,
          isFinished: false
        },
        list
      }
      this._chapterCache[id] = entry
    }
    const maxPage = Math.max(1, Math.ceil(entry.list.length / size))
    const safePage = Math.max(1, Math.min(p, maxPage))
    const start = (safePage - 1) * size
    return {
      info: entry.info,
      list: entry.list.slice(start, start + size).map(x => ({
        chapterId: id + '|' + x.index,
        index: x.index,
        name: x.name
      })),
      page: safePage, maxPage, hasMore: safePage < maxPage
    }
  },

  async getAudioUrl(chapterId) {
    const s = String(chapterId || '')
    const sep = s.indexOf('|')
    if (sep < 1) throw new Error('无效的章节 ID')
    const albumId = s.slice(0, sep)
    const idx = Number(s.slice(sep + 1)) || 1
    const hit = this._audioCache[s]
    if (hit && Date.now() - hit.at < 240000) return hit.value
    // album_id 必须传字符串
    const j = await this._req('/h5/listening/play', {
      method: 'POST',
      body: { album_id: albumId, chapter_idx: idx }
    })
    const url = String(j.play_url || '')
    if (!/^https?:\/\//i.test(url)) throw new Error('该章节暂不可播放' + (j.detail ? '：' + j.detail : ''))
    const value = { url, headers: { 'User-Agent': this._ua, Referer: this._site + '/' } }
    this._audioCache[s] = { value, at: Date.now() }
    return value
  }
})