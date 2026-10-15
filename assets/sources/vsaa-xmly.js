// 万象聚合 · 喜马拉雅
// 上游由万象数据聚合 API 代理：https://api2.vsaa.cn/api/book/xmly/index.php
// 需用户在音源配置中填写「万象 API Key」（在 api.vsaa.cn 注册后获取，形如 sk-xxxx）。
//
// 接口链路：
//   搜索   action=search.universal &kw=&type=album&page=&rows=   → data.items[]
//   目录   action=album.tracks     &albumId=&page=&pageSize=      → data.tracks[] / data.list[]
//   取流   action=track.playUrl    &trackId=&quality=&albumId=    → data.url
//
// ⚠️ 已知上游问题（2026-09-15 实测）：album.tracks 对任意专辑恒返回
//    {"code":-924,"msg":"亲，该内容因故已下架，请您谅解"}
//    （album.detail 正常，说明是 tracks 接口或万象内置账号不可用）。
//    此时需自备喜马拉雅 Cookie（下方 vsaa_ck）后重试。
({
  name: '万象·喜马拉雅',
  id: 'vsaa-xmly',
  version: 1,
  apiVersion: 1,
  configFields: [
    {
      key: 'vsaa_key', label: '万象 API Key', type: 'textarea', required: true,
      hint: '必填。可填多个 Key：每行一个，或用逗号/空格分隔。' +
        '多个 Key 会轮询使用，某个失效或额度用尽时自动切到下一个。' +
        '在 api.vsaa.cn 注册后获取，形如 sk-xxxxxxxx。'
    },
    {
      key: 'vsaa_ck', label: '喜马拉雅 Cookie（可选）', type: 'textarea', required: false,
      hint: '付费内容与部分专辑需要自备 CK；不填则使用万象接口内置账号。'
    }
  ],
  _base: 'https://api2.vsaa.cn/api/book/xmly/index.php',
  _ua: 'okhttp/4.9.2',
  _sep: '|',
  _pageSizeMax: 200,

  _ck() {
    return (this.config && this.config.vsaa_ck) ||
      uni.getStorageSync('vsaa_ck') || ''
  },

  // ── 多 Key 轮询 ──────────────────────────────────────────
  // 配置里可填多个万象 Key（换行/逗号/空格分隔）。每次请求按顺序取下一个 Key，
  // 某个 Key 失效或额度用尽时标记冷却 10 分钟并自动切到下一个，全部失败才报错。
  _keys() {
    const raw = (this.config && this.config.vsaa_key) ||
      uni.getStorageSync('vsaa_key') || ''
    const out = [], seen = {}
    String(raw).split(/[\s,;，；|]+/).forEach(s => {
      const v = s.trim()
      if (!v || seen[v]) return
      seen[v] = 1
      out.push(v)
    })
    return out
  },
  _keyState() {
    if (!this._ks) this._ks = { i: 0, bad: {} }
    return this._ks
  },
  // 轮询取下一个可用 Key（跳过冷却中的；全在冷却则取最早恢复的强制再试）
  _pickKey() {
    const keys = this._keys()
    if (!keys.length) return ''
    const st = this._keyState()
    const now = Date.now()
    for (let n = 0; n < keys.length; n++) {
      const idx = (st.i + n) % keys.length
      const k = keys[idx]
      if ((st.bad[k] || 0) > now) continue
      st.i = (idx + 1) % keys.length
      return k
    }
    let best = keys[0], bestT = Infinity
    keys.forEach(k => {
      const t = st.bad[k] || 0
      if (t < bestT) { bestT = t; best = k }
    })
    return best
  },
  _markBad(key) {
    if (!key) return
    this._keyState().bad[key] = Date.now() + 10 * 60 * 1000
  },
  // 判定是「这个 Key 有问题」（失效/额度用尽）而非请求本身有问题。
  // 注意：上游 -924（内容已下架）不算 Key 问题，不应触发轮换。
  _isKeyError(d) {
    if (!d || typeof d !== 'object') return false
    const ec = Number(d.errcode)
    if (isFinite(ec) && ec >= 11000 && ec < 12000) return true
    const c = Number(d.code), s = Number(d.status)
    if (c === 401 || c === 403 || s === 401 || s === 403) return true
    const msg = String(d.msg || d.message || '')
    return /密钥|鉴权|未授权|无权|积分|额度|次数|上限|频率|频繁|限流|不足|过期|api\s*key/i.test(msg)
  },

  _get(params) {
    const keys = this._keys()
    if (!keys.length) {
      return Promise.reject(new Error('未配置万象 API Key：请在音源设置中填写（api.vsaa.cn 注册获取）'))
    }
    const all = Object.assign({}, params)
    const ck = this._ck()
    if (ck) all.cookie = ck
    const qs = Object.entries(all)
      .filter(([, v]) => v !== undefined && v !== null && v !== '')
      .map(([k, v]) => k + '=' + encodeURIComponent(v)).join('&')

    const once = key => new Promise((resolve, reject) => {
      uni.request({
        url: this._base + '?' + qs + '&key=' + encodeURIComponent(key),
        method: 'GET', header: { 'User-Agent': this._ua }, timeout: 25000,
        success: r => {
          let d = r.data
          if (typeof d === 'string') { try { d = JSON.parse(d) } catch (e) {} }
          if (r.statusCode !== 200) {
            const e = new Error('HTTP ' + r.statusCode + '：' + String(r.data).slice(0, 80))
            e.retryable = r.statusCode >= 500
            return reject(e)
          }
          if (!d || typeof d !== 'object') return reject(new Error('接口返回非 JSON'))
          // 万象有两条错误通道：code(HTTP 语义) 与 errcode(业务语义，鉴权/额度都在这里)
          const ec = Number(d.errcode)
          if (d.code !== 0 || (isFinite(ec) && ec !== 0)) {
            let msg = d.msg || d.message || ('万象接口错误 code=' + d.code)
            // 上游 -924：喜马内容被判定下架（内置账号无权限时也会这样报）
            if (d.code === -924 && !this._ck()) {
              msg += '｜该专辑需要喜马拉雅 Cookie 才能解析，请在音源设置中填写「喜马拉雅 Cookie」'
            }
            const e = new Error(msg)
            e.apiCode = d.code
            e.errcode = d.errcode
            e.keyProblem = this._isKeyError(d)
            e.retryable = e.keyProblem
            return reject(e)
          }
          resolve(d.data)
        },
        fail: e => {
          const x = new Error((e && e.errMsg) || '网络失败')
          x.retryable = true
          reject(x)
        }
      })
    })

    const maxTry = keys.length
    const loop = n => {
      const key = this._pickKey()
      return once(key).catch(e => {
        if (e.keyProblem) this._markBad(key)
        if (e.retryable && n + 1 < maxTry) return loop(n + 1)
        throw e
      })
    }
    return loop(0)
  },

  // 主播字段可能是字符串、数组或 JSON 字符串数组
  _announcer(v) {
    if (!v) return ''
    if (Array.isArray(v)) return v.filter(Boolean).join('、')
    const s = String(v).trim()
    if (s.charAt(0) === '[') {
      try {
        const arr = JSON.parse(s)
        if (Array.isArray(arr)) return arr.filter(Boolean).join('、')
      } catch (e) { /* 非合法 JSON，按原样 */ }
    }
    return s
  },

  // chapterId = <albumId>|<trackId>
  _packChapter(albumId, trackId) { return albumId + this._sep + trackId },
  _unpackChapter(chapterId) {
    const i = String(chapterId).indexOf(this._sep)
    if (i <= 0) return null
    return { albumId: String(chapterId).slice(0, i), trackId: String(chapterId).slice(i + 1) }
  },

  async search(keyword, page = 1) {
    const d = await this._get({
      action: 'search.universal', kw: keyword, type: 'album', page, rows: 20
    })
    const rows = (d && (d.items || d.list || d.albums)) || []
    const list = rows.map(it => {
      const id = String(it.albumId || it.trackId || it.id || '')
      return {
        bookId: id,
        title: it.title || it.albumName || '',
        cover: it.cover || it.coverUrl || '',
        author: this._announcer(it.announcer) || it.nickname || '',
        intro: it.intro || it.description || ''
      }
    }).filter(x => x.bookId && x.title)
    const totalPage = parseInt((d && d.totalPage) || '', 10)
    const hasMore = Number.isFinite(totalPage) ? page < totalPage : rows.length >= 20
    return { list, page, maxPage: hasMore ? page + 1 : page, hasMore }
  },

  async getChapters(bookId, page = 1, pageSize = 30) {
    const albumId = String(bookId)
    const size = Math.min(Math.max(parseInt(pageSize, 10) || 30, 1), this._pageSizeMax)
    const d = await this._get({ action: 'album.tracks', albumId, page, pageSize: size })
    const rows = (d && (d.tracks || d.list)) || []
    const total = parseInt((d && (d.totalCount || d.total)) || '', 10)

    let info = { title: '', cover: '', author: '', trackCount: 0, isFinished: true }
    try {
      const det = await this._get({ action: 'album.detail', albumId })
      if (det) {
        info.title = det.title || det.albumName || ''
        info.cover = det.cover || det.coverUrl || ''
        info.author = this._announcer(det.announcer) || det.nickname || ''
        const tc = parseInt(det.tracksCount || det.trackCount || '', 10)
        if (Number.isFinite(tc) && tc > 0) info.trackCount = tc
      }
    } catch (e) { /* 详情失败不阻断目录 */ }

    const list = rows.map((it, i) => {
      const trackId = String((it && (it.trackId || it.id)) || '')
      return {
        chapterId: this._packChapter(albumId, trackId),
        index: (page - 1) * size + i + 1,
        name: String((it && it.title) || '').trim()
      }
    }).filter(x => x.name && x.chapterId !== albumId + this._sep)

    if (!list.length && page === 1) {
      throw new Error('目录为空：聚合服务端「喜马拉雅 /album.tracks」当前未返回章节（上游恒报已下架），请稍后重试或改用其他音源')
    }
    if (!info.trackCount) info.trackCount = list.length
    const hasMore = Number.isFinite(total) ? page * size < total : rows.length >= size
    const maxPage = Number.isFinite(total)
      ? Math.max(1, Math.ceil(total / size))
      : (hasMore ? page + 1 : page)
    return { info, list, page, maxPage, hasMore }
  },

  async getAudioUrl(chapterId) {
    const c = this._unpackChapter(chapterId)
    if (!c) throw new Error('章节 ID 无效：' + chapterId)
    const d = await this._get({
      action: 'track.playUrl', trackId: c.trackId, quality: 'mp3_64', albumId: c.albumId
    })
    const url = (d && (d.url || d.playUrl)) || ''
    if (!url || !/^https?:/.test(url)) {
      throw new Error('获取播放地址失败：该内容可能为付费内容，请在音源设置中填写「喜马拉雅 Cookie」后重试')
    }
    return { url, headers: { 'User-Agent': this._ua } }
  }
})
