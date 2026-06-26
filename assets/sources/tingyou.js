// 听优有声（tingyou.fm）Worker 源
// 接口: tingyou/search?key= / tingyou/toc?id=  |  鉴权: 无  |  分页: 搜索有 page,目录不分页
({
  name: '听优有声',
  id: 'tingyou',
  apiVersion: 1,
  _base: 'https://tingyou.fm',
  _ua: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36',

  // ── 公共请求: 包成 Promise, 统一判状态码 ──
  _get(path, params) {
    const qs = Object.entries(params)
      .map(([k, v]) => k + '=' + encodeURIComponent(v))
      .join('&')
    const url = this._base + path + (qs ? '?' + qs : '')
    return new Promise((resolve, reject) => {
      uni.request({
        url,
        method: 'GET',
        header: { 'User-Agent': this._ua },
        timeout: 15000,
        success: r => r.statusCode === 200
          ? resolve(r.data)
          : reject(new Error('HTTP ' + r.statusCode + ' | ' + url)),
        fail: e => reject(new Error(e.errMsg || '网络失败')),
      })
    })
  },

  // ── HTML 文本清洗 ──
  _clean(text) {
    return String(text || '')
      .replace(/<[^>]+>/g, ' ')
      .replace(/&nbsp;/g, ' ')
      .replace(/&amp;/g, '&')
      .replace(/&lt;/g, '<')
      .replace(/&gt;/g, '>')
      .replace(/&#(\d+);/g, (_, n) => String.fromCharCode(parseInt(n, 10)))
      .replace(/&#x([0-9a-f]+);/gi, (_, n) => String.fromCharCode(parseInt(n, 16)))
      .replace(/\s+/g, ' ')
      .trim()
  },

  _attr(tag, name) {
    const re = new RegExp(name + "\\s*=\\s*(\"([^\"]*)\"|'([^']*)'|([^\\s>]+))", 'i')
    const m = String(tag || '').match(re)
    return m ? this._clean(m[2] || m[3] || m[4] || '') : ''
  },

  _firstMatch(html, re) {
    const m = String(html || '').match(re)
    return m ? (m[1] || '') : ''
  },

  _abs(url, base) {
    url = String(url || '').trim()
    if (!url) return ''
    if (url.startsWith('//')) return 'https:' + url
    if (/^https?:\/\//i.test(url)) return url
    if (url[0] === '/') return this._base + url
    const b = String(base || this._base + '/').replace(/[#?].*$/, '').replace(/\/[^/]*$/, '/')
    return b + url
  },

  // ── search: 调用 tingyou/search?key=&page= ──
  // 返回 JSON: { code:0, data:[ { id, name, pic, author, cate, count }, ... ], pages? }
  async search(keyword, page = 1, pageSize = 20) {
    pageSize = pageSize || 20
    const res = await this._get('/tingyou/search', { key: keyword, page })
    // res.data 可能已是对象,也可能是字符串
    let data = res
    if (typeof data === 'string') {
      try { data = JSON.parse(data) } catch (e) {
        throw new Error('搜索接口返回非 JSON: ' + String(data).slice(0, 200))
      }
    }
    if (data.code && data.code !== 0) {
      throw new Error('搜索接口返回错误: code=' + data.code + ' msg=' + (data.msg || ''))
    }
    const rows = Array.isArray(data.data) ? data.data : []
    const total = parseInt(data.total || data.count || 0)
    const maxPage = Math.max(1, Math.ceil(total / pageSize))
    return {
      list: rows.map(it => ({
        bookId:  String(it.id),
        title:   String(it.name || it.title || '').trim(),
        cover:   String(it.pic  || it.cover || '').trim(),
        author:  String(it.author || ''),
        intro:   (it.cate || '') + ' · ' + (it.count || 0) + '集',
      })),
      page,
      maxPage,
      hasMore: page < maxPage,
    }
  },

  // ── getChapters: 调用 tingyou/toc?id=, 返回完整章节 JSON 数组 ──
  // 返回: { code:0, data:[ { id, name }, ... ], info:{ name, pic, author } }
  async getChapters(bookId, page = 1, pageSize = 200) {
    pageSize = pageSize || 200
    const res = await this._get('/tingyou/toc', { id: bookId })
    let data = res
    if (typeof data === 'string') {
      try { data = JSON.parse(data) } catch (e) {
        throw new Error('目录接口返回非 JSON: ' + String(data).slice(0, 200))
      }
    }
    if (data.code && data.code !== 0) {
      throw new Error('目录接口返回错误: code=' + data.code + ' msg=' + (data.msg || ''))
    }
    const rows = Array.isArray(data.data) ? data.data : []
    if (rows.length === 0) {
      throw new Error('目录为空: keys=' + Object.keys(data).join(',') + ' | ' + JSON.stringify(data).slice(0, 300))
    }
    const info = data.info || {}
    // 分页: 目录不分页则在 JS 侧切分
    const total = rows.length
    const maxPage = Math.max(1, Math.ceil(total / pageSize))
    const safePage = Math.max(1, Math.min(page, maxPage))
    const start = (safePage - 1) * pageSize
    const slice = rows.slice(start, start + pageSize)
    return {
      info: {
        title:      String(info.name  || info.title  || '').trim(),
        cover:      String(info.pic   || info.cover  || '').trim(),
        author:     String(info.author || ''),
        trackCount: total,
        isFinished: false,
      },
      list: slice.map((it, i) => ({
        chapterId: String(it.id),
        index:     start + i + 1,
        name:      String(it.name || it.title || '').trim(),
      })),
      page: safePage,
      maxPage,
      hasMore: safePage < maxPage,
    }
  },

  // ── getAudioUrl: chapterId 就是音频的完整播放 URL ──
  async getAudioUrl(chapterId) {
    // 听优 worker 源的 getAudioUrl 直接返回 chapterId 作为音频地址
    if (!chapterId || typeof chapterId !== 'string' || chapterId.length < 4) {
      throw new Error('无效的 chapterId: ' + JSON.stringify(chapterId))
    }
    // 如果 chapterId 已经是完整 http 地址, 直接返回带 Referer 的结构
    if (/^https?:\/\//i.test(chapterId)) {
      return {
        url: chapterId,
        headers: { Referer: this._base + '/', 'User-Agent': this._ua },
      }
    }
    // 否则拼接成完整 URL
    const url = this._base + '/tingyou/play?id=' + chapterId
    return {
      url,
      headers: { Referer: this._base + '/', 'User-Agent': this._ua },
    }
  },
})
