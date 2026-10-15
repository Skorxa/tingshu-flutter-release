// 万象聚合 · 七猫听书
// 上游由万象数据聚合 API 代理：https://api2.vsaa.cn/api/book/qimao/index.php
// 需用户在音源配置中填写「万象 API Key」（在 api.vsaa.cn 注册后获取，形如 sk-xxxx）。
//
// 七猫有两类专辑，走不同链路：
//   真人有声  audio_type === "1"  → album_detail/album_chapters + album_audio
//   AI 听书   其他                → album_voice/chapter_list   + album_tts（需 content_md5）
//
// 橘听协议只有 chapterId（无 extra 字段），故用组合键携带分支信息：
//   书籍  真人：a|<albumId>                             AI：t|<albumId>
//   章节  真人：a|<albumId>|<chapterId>
//         AI  ：t|<albumId>|<contentMd5>|<voiceId>|<chapterId>
({
  name: '万象·七猫',
  id: 'vsaa-qimao',
  version: 1,
  apiVersion: 1,
  configFields: [
    {
      key: 'vsaa_key', label: '万象 API Key', type: 'textarea', required: true,
      hint: '必填。可填多个 Key：每行一个，或用逗号/空格分隔。' +
        '多个 Key 会轮询使用，某个失效或额度用尽时自动切到下一个。' +
        '在 api.vsaa.cn 注册后获取，形如 sk-xxxxxxxx。'
    }
  ],
  _base: 'https://api2.vsaa.cn/api/book/qimao/index.php',
  _ua: 'okhttp/4.9.2',
  _sep: '|',
  // 发音人偏好（与万象官方插件保持一致）
  _voicePref: ['10', '8', '4', '6', '5', '7', '9', '200'],
  _voiceFallback: '10',

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
            const e = new Error(d.msg || d.message || ('万象接口错误 code=' + d.code))
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

  // ── 组合键编解码 ──────────────────────────────────────────
  _packBook(isAudio, albumId) {
    return (isAudio ? 'a' : 't') + this._sep + albumId
  },
  _unpackBook(bookId) {
    const p = String(bookId).split(this._sep)
    if (p.length < 2) return null
    return { isAudio: p[0] === 'a', albumId: p[1] }
  },
  _packChapter(isAudio, albumId, chapterId, md5, voiceId) {
    return (isAudio
      ? ['a', albumId, chapterId]
      : ['t', albumId, md5, voiceId, chapterId]).join(this._sep)
  },
  _unpackChapter(chapterId) {
    const p = String(chapterId).split(this._sep)
    if (p[0] === 'a' && p.length >= 3) {
      return { isAudio: true, albumId: p[1], chapterId: p[2] }
    }
    if (p[0] === 't' && p.length >= 5) {
      return { isAudio: false, albumId: p[1], md5: p[2], voiceId: p[3], chapterId: p[4] }
    }
    return null
  },
  _pickVoice(list) {
    const arr = Array.isArray(list) ? list : []
    for (const id of this._voicePref) {
      if (arr.some(v => String(v.voice_id) === id)) return id
    }
    const named = arr.find(v => String(v.voice_id) !== '0' && v.voice_name)
    if (named) return String(named.voice_id)
    return this._voiceFallback
  },

  async search(keyword, page = 1) {
    const d = await this._get({ action: 'search', wd: keyword, type: '1', page })
    const books = (d && d.books) || []
    const list = books.map(it => ({
      bookId: this._packBook(String(it.audio_type || '') === '1', String(it.id || '')),
      title: it.title || it.original_title || '',
      cover: it.image_link || '',
      author: '',
      intro: it.intro || it.sub_title || ''
    })).filter(x => x.title)
    const total = parseInt((d && d.total_page) || '', 10)
    const hasMore = Number.isFinite(total) ? page < total : list.length >= 10
    return { list, page, maxPage: hasMore ? page + 1 : page, hasMore }
  },

  async getChapters(bookId, page = 1) {
    const b = this._unpackBook(bookId)
    if (!b) throw new Error('书籍 ID 无效：' + bookId)
    const albumId = b.albumId
    const info = { title: '', cover: '', author: '', trackCount: 0, isFinished: true }
    let list = []

    if (b.isAudio) {
      // 真人有声
      try {
        const det = await this._get({ action: 'album_detail', album_id: albumId })
        const bk = det && det.book
        if (bk) {
          info.title = bk.title || ''
          info.cover = bk.image_link || ''
          info.author = bk.author || ''
        }
      } catch (e) { /* 详情失败不阻断目录 */ }
      const d = await this._get({ action: 'album_chapters', album_id: albumId })
      const rows = (d && d.chapter_list) || []
      list = rows.map((it, i) => ({
        chapterId: this._packChapter(true, albumId, String(it.id || '')),
        index: i + 1,
        name: String(it.title || '').trim()
      })).filter(x => x.name)
    } else {
      // AI 听书：需先确定发音人，再取带 content_md5 的章节表
      let voiceId = this._voiceFallback
      try {
        const v = await this._get({ action: 'album_voice', album_id: albumId })
        voiceId = this._pickVoice(v && v.voice_list)
        if (v) {
          info.title = v.album_title || ''
          info.cover = v.album_image_url || ''
          const bk = v.book
          if (bk) {
            info.title = info.title || bk.title || ''
            info.cover = info.cover || bk.image_link || ''
            info.author = bk.author || ''
          }
        }
      } catch (e) { /* 发音人获取失败则用默认音色 */ }
      const d = await this._get({ action: 'chapter_list', id: albumId })
      const rows = (d && d.chapter_lists) || []
      list = rows.map((it, i) => ({
        chapterId: this._packChapter(
          false, albumId, String(it.id || ''), String(it.content_md5 || ''), voiceId
        ),
        index: i + 1,
        name: String(it.title || '').trim()
      })).filter(x => x.name)
    }

    if (!list.length) throw new Error('目录为空：该书在「七猫」暂无可用章节')
    info.trackCount = list.length
    return { info, list, page, maxPage: 1, hasMore: false }
  },

  async getAudioUrl(chapterId) {
    const c = this._unpackChapter(chapterId)
    if (!c) throw new Error('章节 ID 无效：' + chapterId)
    let url = ''
    if (c.isAudio) {
      const d = await this._get({
        action: 'album_audio', album_id: c.albumId, chapter_ids: c.chapterId
      })
      const vl = (d && d.voice_list) || []
      const hit = vl.find(v => v && v.voice_url)
      url = (hit && hit.voice_url) || ''
    } else {
      if (!c.md5) throw new Error('该章节缺少正文指纹(content_md5)，无法生成听书音频')
      const d = await this._get({
        action: 'album_tts', book_id: c.albumId, chapter_id: c.chapterId,
        content_md5: c.md5, voice_id: c.voiceId
      })
      const cl = (d && d.chapter_list) || []
      const hit = cl.find(v => v && v.voice_url) || cl[0]
      url = (hit && hit.voice_url) || ''
    }
    if (!url || !/^https?:/.test(url)) throw new Error('该集无音频')
    // 七猫音频为 CDN 直链，无需鉴权头
    return { url, headers: { 'User-Agent': this._ua } }
  }
})
