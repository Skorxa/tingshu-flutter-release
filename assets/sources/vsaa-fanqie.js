// 万象聚合 · 番茄听书
// 上游由万象数据聚合 API 代理：https://api2.vsaa.cn/api/book/fanqie/index.php
// 需用户在音源配置中填写「万象 API Key」（在 api.vsaa.cn 注册后获取，形如 sk-xxxx）。
//
// 接口链路：
//   搜索   action=search   &q=&page=&type=music      → data.results[]
//   目录   action=directory&book_id=                 → data.chapters[]
//   取流   action=audio    &item_ids=&book_id=&req_type=2[&tone_id=] → data.url
//
// 注意：取流必须同时带 book_id（只传 item_ids 会报 missing book_id），
// 而橘听 getAudioUrl 只收到 chapterId，故 chapterId 用组合键 <bookId>|<itemId>。
({
  name: '万象·番茄',
  id: 'vsaa-fanqie',
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
      key: 'vsaa_tone', label: '发音人 ID（可选）', type: 'text', required: false,
      hint: '留空自动选择该章节真实可用的发音人；填数字 ID 则优先匹配，不可用时自动回退。'
    }
  ],
  _base: 'https://api2.vsaa.cn/api/book/fanqie/index.php',
  _ua: 'okhttp/4.9.2',
  _sep: '|',

  _tone() {
    const raw = (this.config && this.config.vsaa_tone) ||
      uni.getStorageSync('vsaa_tone') || ''
    const n = parseInt(String(raw).trim(), 10)
    return Number.isNaN(n) ? '' : String(n)
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
  // 判定是「这个 Key 有问题」（失效/额度用尽）而非请求本身有问题
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
    const qs = Object.entries(params)
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
            const e = new Error(d.message || d.msg || ('万象接口错误 code=' + d.code))
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

  // chapterId = <bookId>|<itemId>
  _packChapter(bookId, itemId) { return bookId + this._sep + itemId },
  _unpackChapter(chapterId) {
    const i = String(chapterId).indexOf(this._sep)
    if (i <= 0) return null
    return { bookId: String(chapterId).slice(0, i), itemId: String(chapterId).slice(i + 1) }
  },

  async search(keyword, page = 1) {
    const d = await this._get({ action: 'search', q: keyword, page, type: 'music' })
    const rows = (d && (d.results || d.list)) || []
    const list = rows.map(it => ({
      bookId: String(it.book_id || ''),
      title: it.title || '',
      cover: it.artwork || it.audio_artwork || '',
      author: it.author || '',
      intro: it.desc || it.category || ''
    })).filter(x => x.bookId && x.title)
    // 接口不返回总页数，用「不足一页即末页」判定
    const limit = parseInt((d && d.limit) || '', 10) || 10
    const hasMore = rows.length >= limit
    return { list, page, maxPage: hasMore ? page + 1 : page, hasMore }
  },

  async getChapters(bookId, page = 1) {
    const d = await this._get({ action: 'directory', book_id: bookId })
    const rows = (d && d.chapters) || []
    if (!rows.length) throw new Error('目录为空：该书在「番茄」暂无可用章节')
    const list = rows.map((it, i) => ({
      chapterId: this._packChapter(bookId, String(it.item_id || it.itemId || '')),
      index: i + 1,
      name: String(it.title || '').trim()
    })).filter(x => x.name && x.chapterId !== bookId + this._sep)
    return {
      info: {
        title: (d && d.book_name) || '',
        cover: (d && d.artwork) || '',
        author: (d && d.author) || '',
        trackCount: list.length,
        isFinished: true
      },
      list, page, maxPage: 1, hasMore: false
    }
  },

  async getAudioUrl(chapterId) {
    const c = this._unpackChapter(chapterId)
    if (!c) throw new Error('章节 ID 无效：' + chapterId)
    const params = { action: 'audio', item_ids: c.itemId, book_id: c.bookId, req_type: 2 }
    const tone = this._tone()
    if (tone) params.tone_id = tone
    const d = await this._get(params)
    const url = (d && (d.url || d.content)) || ''
    if (!url || !/^https?:/.test(url)) throw new Error('该集无音频')
    // 番茄音频直链的 Content-Type 被错标为 video/mp4，实际是 MP3（ID3 头），
    // just_audio / ExoPlayer 按内容嗅探可正常播放，无需特殊处理。
    return { url, headers: { 'User-Agent': this._ua } }
  }
})
