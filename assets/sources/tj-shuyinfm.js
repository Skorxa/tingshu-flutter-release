// 书音FM（m.shuyinfm.com）Next.js + 帝国CMS ecmsapi 直连版
// 搜索:   act=search&mod=movie&keyboard=            → 服务端关键词搜索
// 目录:   act=movielist&id={书id}&page=&pagesize=    → 服务端分页章节（id 为集序号）
// 详情:   act=detail&id={书id}                       → 书名/封面/演播/简介/classid
// 音频:   act=wapseries&mod=movie&id={书id}&movieId={章id}&t={秒}&token=md5(排序参数&token=SECRET)
//         → SeriesUrl（酷我 rid 解析器, 302 到酷我 CDN）+ signed_urls[]（站点自有 CDN 多线路）
//         线路全部失效时回退嗅探 /audio/{classid}-{书id}-{章id}.html
// 分类:   act=navigation&mod=column  /  列表 act=list&mod=movie&classid=&sort=
({
  name: '书音FM',
  id: 'tingshu-json-shuyinfm',
  version: 1,
  apiVersion: 1,
  _base: 'https://m.shuyinfm.com',
  _ua: 'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Mobile Safari/537.36',
  _apiUa: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
  _tokenSecret: '056a308c515e16b2fe5a5c631319339cbc60a8ee0e03d016',
  _detailCache: {}, _audioCache: {},

  _getJson(url, timeout) {
    return new Promise((resolve, reject) => {
      uni.request({
        url, method: 'GET',
        header: { 'User-Agent': this._apiUa, Referer: this._base + '/', Accept: 'application/json, text/plain, */*' },
        timeout: timeout || 15000,
        success: r => {
          if (r.statusCode < 200 || r.statusCode >= 300) return reject(new Error('HTTP ' + r.statusCode + ' | ' + url))
          try { resolve(typeof r.data === 'string' ? JSON.parse(r.data) : r.data) }
          catch (e) { reject(new Error('JSON 解析失败 | ' + url)) }
        },
        fail: e => reject(new Error(e.errMsg || '网络失败')),
      })
    })
  },

  async _api(params) {
    const qs = Object.entries(params).map(([k, v]) => k + '=' + encodeURIComponent(v)).join('&')
    const j = await this._getJson(this._base + '/ecmsapi/index.php?' + qs)
    if (j.code !== 1) throw new Error(j.message || ('接口返回 code=' + j.code))
    return j
  },

  _sliceIntro(s) {
    const t = String(s || '').replace(/\s+/g, ' ').trim()
    return t.length > 80 ? t.slice(0, 80) + '…' : t
  },

  _toBook(x) {
    return {
      bookId: String(x.id || ''),
      title: String(x.title || '').trim(),
      cover: String(x.titlepic || ''),
      author: String(x.player || '').trim(),
      intro: [this._sliceIntro(x.moviesay), String(x.filetype || '')].filter(Boolean).join(' · '),
    }
  },

  // ── 搜索 ──
  async search(keyword, page = 1, pageSize = 20) {
    const kw = String(keyword || '').trim()
    const p = Math.max(1, Number(page) || 1)
    if (!kw) return { list: [], page: p, maxPage: 1, hasMore: false }
    const j = await this._api({ act: 'search', mod: 'movie', keyboard: kw, page: p, pagesize: pageSize })
    const d = j.data || {}
    const list = (Array.isArray(d.list) ? d.list : []).map(x => this._toBook(x)).filter(b => b.bookId && b.title)
    const totalPage = Number(d.totalpage) || 1
    return { list, page: p, maxPage: totalPage, hasMore: p < totalPage && list.length > 0 }
  },

  // ── 详情（章节页头信息用）──
  async _getDetail(bookId) {
    const hit = this._detailCache[bookId]
    if (hit) return hit
    const j = await this._api({ mod: 'movie', act: 'detail', id: bookId })
    const d = j.data && j.data.detail
    if (!d) throw new Error('书籍详情获取失败 | ' + bookId)
    this._detailCache[bookId] = d
    return d
  },

  // ── 目录（服务端分页）──
  async getChapters(bookId, page = 1, pageSize = 30) {
    const id = String(bookId).replace(/[^\d].*$/, '')
    const p = Math.max(1, Number(page) || 1)
    const size = Math.max(10, Math.min(Number(pageSize) || 30, 100))
    const j = await this._api({ mod: 'movie', act: 'movielist', id, page: p, pagesize: size })
    const d = j.data || {}
    const rows = Array.isArray(d.moielist) ? d.moielist : []
    const count = Number(d.count) || rows.length
    let info = { title: '', cover: '', author: '', trackCount: count, isFinished: false }
    try {
      const det = await this._getDetail(id)
      info.title = String(det.title || '')
      info.cover = String(det.titlepic || '')
      info.author = String(det.player || '').trim()
      info.isFinished = String(det.filetype || '').indexOf('完结') >= 0
    } catch (e) {}
    const maxPage = Math.max(1, Math.ceil(count / size))
    const safePage = Math.max(1, Math.min(p, maxPage))
    return {
      info,
      list: rows.map(x => ({
        chapterId: id + '-' + String(x.id || ''),
        index: Number(x.id) || 0,
        name: String(x.title || '').trim(),
      })).filter(x => x.name),
      page: safePage, maxPage, hasMore: safePage < maxPage,
    }
  },

  // ── 音频 ──
  async _wapseries(bookId, chapterId) {
    const t = String(Math.floor(Date.now() / 1000))
    // 排序键拼串: act,id,mod,movieId,t → 追加 token → md5
    const base = 'act=wapseries&id=' + bookId + '&mod=movie&movieId=' + chapterId + '&t=' + t
    const token = await uni.crypto.md5Hex({ text: base + '&token=' + this._tokenSecret })
    const url = this._base + '/ecmsapi/index.php?act=wapseries&mod=movie&id=' + bookId + '&movieId=' + chapterId + '&t=' + t + '&token=' + token
    const j = await this._getJson(url)
    if (j.code !== 1 || !j.data) throw new Error(j.message || 'wapseries 返回异常')
    return j.data
  },

  // 候选直链有效性探测（302/206 都算可用; 坏线路 500 会被跳过）
  _probe(url) {
    return new Promise(resolve => {
      uni.request({
        url, method: 'GET',
        header: { 'User-Agent': this._ua, Range: 'bytes=0-1023' },
        timeout: 12000,
        success: r => {
          const ct = ''
          const code = r.statusCode || 0
          const ok = (code === 200 || code === 206) && r.data && String(r.data).length > 0
          resolve(ok)
        },
        fail: () => resolve(false),
      })
    })
  },

  async getAudioUrl(chapterId) {
    const s = String(chapterId || '')
    const dash = s.indexOf('-')
    if (dash < 1) throw new Error('无效的 chapterId: ' + JSON.stringify(chapterId))
    const bookId = s.slice(0, dash), chapterNo = s.slice(dash + 1)
    const hit = this._audioCache[s]
    if (hit && Date.now() - hit.at < 1800000) return hit.value

    const candidates = []
    try {
      const d = await this._wapseries(bookId, chapterNo)
      if (d.SeriesUrl) candidates.push(String(d.SeriesUrl))
      if (Array.isArray(d.signed_urls)) for (const u of d.signed_urls) if (u) candidates.push(String(u))
    } catch (e) {}
    for (const url of candidates) {
      if (!/^https?:\/\//i.test(url)) continue
      if (await this._probe(url)) {
        const value = { url, headers: { 'User-Agent': this._ua } }
        this._audioCache[s] = { value, at: Date.now() }
        return value
      }
    }

    // 全部失效 → 嗅探兜底（需要 classid 拼播放页 URL）
    let classid = '1'
    try { classid = String((await this._getDetail(bookId)).classid || '1') } catch (e) {}
    return {
      sniff: true,
      url: this._base + '/audio/' + classid + '-' + bookId + '-' + chapterNo + '.html',
      headers: { 'User-Agent': this._ua, Referer: this._base + '/' },
      click: '',
      waitMs: 4000,
      audioPatterns: ['.mp3', '.m4a', '.aac', '.m3u8', 'aikeu', 'kuwo'],
    }
  },

  // ── 发现页 ──
  async discover() {
    const jobs = [
      ['热门', () => this._api({ act: 'list', mod: 'movie', classid: '0', page: '1', pagesize: '12', sort: 'onclick desc' })],
      ['最新上架', () => this._api({ act: 'list', mod: 'movie', classid: '0', page: '1', pagesize: '12' })],
    ]
    // 从分类导航取前几个一级分类
    try {
      const nav = await this._api({ act: 'navigation', mod: 'column', classid: '0' })
      const classes = (nav.list || []).filter(c => c.classname && c.classid).slice(0, 3)
      for (const c of classes) {
        const cid = String(c.classid)
        const leaf = String(c.sonclass || '').split('|').filter(Boolean)
        jobs.push([c.classname, () => this._api({ act: 'list', mod: 'movie', classid: cid, page: '1', pagesize: '12' }).catch(() =>
          leaf.length ? this._api({ act: 'list', mod: 'movie', classid: leaf[0], page: '1', pagesize: '12' }) : Promise.reject(new Error('空分类'))
        )])
      }
    } catch (e) {}
    const rs = await Promise.allSettled(jobs.map(x => x[1]()))
    const sections = []
    for (let i = 0; i < jobs.length; i++) {
      const r = rs[i]
      if (r.status === 'fulfilled') {
        const list = ((r.value.data || {}).list || []).map(x => this._toBook(x)).filter(b => b.bookId && b.title).slice(0, 12)
        if (list.length) sections.push({ title: jobs[i][0], list })
      }
    }
    return { sections }
  },
})
