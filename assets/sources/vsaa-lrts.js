// 万象聚合 · 懒人听书
// 上游由万象数据聚合 API 代理：https://api2.vsaa.cn/api/book/lrts/index.php
// 需用户在音源配置中填写「万象 API Key」（在 api.vsaa.cn 注册后获取，形如 sk-xxxx）。
//
// 接口链路（注意：懒人接口把 list 放在**顶层**，不在 data 里；成功标志是 apiStatus===0）：
//   搜索   action=search.all    &keyWord=                        → data.modules.bookAlbum.bookAlbums[]
//   目录   action=book.resource &bookId=&pageNum=&pageSize=&sortType=0&isUp=1
//                                                               → 顶层 list[]、顶层 sections(总章数)
//   取流   action=listen.path   &entityId=&resId=&section=&trackId=&opType=0&quality=1&entityType=1
//                                                               → data.path
//
// 只做「听书」分支。插件的音乐单曲分支（music.mediaUrl）会返回 QQ `.mgg` 加密流，
// 需 ekey 解密，而橘听 AudioResult 没有该字段，故不实现。
//
// 取流必须带 section（为 0 会直接返回空）与 trackId(tmeId)，而橘听 getAudioUrl 只收 chapterId，
// 故 chapterId 用组合键 <albumId>|<section>|<tmeId>|<sectionId>。
({
  name: '万象·懒人听书',
  id: 'vsaa-lrts',
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
  _base: 'https://api2.vsaa.cn/api/book/lrts/index.php',
  _ua: 'okhttp/4.9.2',
  _sep: '|',
  _pageSizeMax: 1000,

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

  // 懒人接口成功标志是 apiStatus===0（不是 code），失败信息在 msg
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
          // 必须先判 errcode：懒人鉴权失败返回的是 {"code":0,"msg":"密钥错误","errcode":11002}
          // —— code 是 0，若先判 code 会把失效 Key 当成成功，静默返回空结果。
          const ec = Number(d.errcode)
          if (isFinite(ec) && ec !== 0) {
            const e = new Error(d.msg || d.message || ('万象接口错误 errcode=' + d.errcode))
            e.errcode = d.errcode
            e.keyProblem = this._isKeyError(d)
            e.retryable = e.keyProblem
            return reject(e)
          }
          const ok = d.apiStatus === 0 || d.status === 0 || d.code === 0
          if (!ok) {
            const e = new Error(d.msg || d.message || ('万象接口错误 apiStatus=' + d.apiStatus))
            e.apiCode = d.apiStatus !== undefined ? d.apiStatus : d.code
            e.keyProblem = this._isKeyError(d)
            e.retryable = e.keyProblem
            return reject(e)
          }
          resolve(d)
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

  // chapterId = <albumId>|<section>|<tmeId>|<sectionId>
  _packChapter(albumId, section, tmeId, sectionId) {
    return [albumId, section, tmeId || '', sectionId].join(this._sep)
  },
  _unpackChapter(chapterId) {
    const p = String(chapterId).split(this._sep)
    if (p.length < 4) return null
    return { albumId: p[0], section: p[1], tmeId: p[2], sectionId: p[3] }
  },

  async search(keyword, page = 1) {
    // search.book 的 id 指向阅读侧实体（book.detail 会报已下架），
    // 可播放的要用 search.all 里的 bookAlbums（entityType=1 专辑实体）。
    const d = await this._get({ action: 'search.all', keyWord: keyword })
    const ba = (d && d.data && d.data.modules && d.data.modules.bookAlbum) || {}
    const rows = (ba.bookAlbums || []).filter(x => x && x.entityType === 1)
    const size = 30
    const start = (page - 1) * size
    const list = rows.slice(start, start + size).map(it => ({
      bookId: String(it.id || it.bookId || ''),
      title: it.name || '',
      cover: it.cover || '',
      author: it.announcer || it.author || '',
      intro: it.desc || it.recReason || ''
    })).filter(x => x.bookId && x.title)
    const hasMore = start + size < rows.length
    return { list, page, maxPage: hasMore ? page + 1 : page, hasMore }
  },

  async getChapters(bookId, page = 1, pageSize = 30) {
    const albumId = String(bookId)
    const size = Math.min(Math.max(parseInt(pageSize, 10) || 30, 1), this._pageSizeMax)
    const d = await this._get({
      action: 'book.resource', bookId: albumId,
      pageNum: page, pageSize: size, sortType: 0, isUp: 1
    })
    // list 与 sections(总章数) 都在顶层
    const rows = (d && d.list) || []
    const total = parseInt((d && d.sections) || '', 10)

    let info = { title: '', cover: '', author: '', trackCount: 0, isFinished: true }
    try {
      const det = await this._get({ action: 'book.detail', id: albumId, type: 1, reqMask: 1 })
      const bk = (det && (det.data || det)) || null
      if (bk) {
        info.title = bk.name || bk.bookName || ''
        info.cover = bk.cover || bk.coverUrl || ''
        info.author = bk.announcer || bk.author || ''
      }
    } catch (e) { /* 详情失败不阻断目录 */ }

    const list = rows.map((it, i) => {
      const section = it.section
      const sectionId = String(it.sectionId || it.id || '')
      return {
        chapterId: this._packChapter(albumId, section, it.tmeId || '', sectionId),
        index: (page - 1) * size + i + 1,
        name: String(it.name || '').trim()
      }
    }).filter(x => x.name && x.chapterId)

    if (!list.length && page === 1) throw new Error('目录为空：该书在「懒人听书」暂无可用章节')
    if (!info.trackCount) info.trackCount = Number.isFinite(total) && total > 0 ? total : list.length
    const hasMore = Number.isFinite(total) && total > 0
      ? page * size < total
      : rows.length >= size
    const maxPage = Number.isFinite(total) && total > 0
      ? Math.max(1, Math.ceil(total / size))
      : (hasMore ? page + 1 : page)
    return { info, list, page, maxPage, hasMore }
  },

  async getAudioUrl(chapterId) {
    const c = this._unpackChapter(chapterId)
    if (!c) throw new Error('章节 ID 无效：' + chapterId)
    const section = parseInt(c.section, 10)
    if (!section) throw new Error('章节缺少 section，无法取流')
    const d = await this._get({
      action: 'listen.path', entityId: c.albumId, resId: c.sectionId,
      section, trackId: c.tmeId, opType: 0, quality: 1, entityType: 1
    })
    const url = (d && d.data && d.data.path) || ''
    if (!url || !/^https?:/.test(url)) throw new Error('该集无音频')
    // 懒人听书为腾讯音乐 CDN 明文 m4a（非 .mgg），无需 ekey；
    // 直链带 ttl=86400000（24h）时效，由 App 侧按需重新获取。
    return { url, headers: { 'User-Agent': this._ua } }
  }
})
