// 聆阅 · 源A-LR（懒人听书 lrts）
//
// 元数据 —— 秒哒 Supabase Edge Functions（唯一来源，全项目共享并发额度，429 高发 → 需多次退避重试）
//   搜索 /lrts-search?name=&page=      详情+目录 /lrts-book?bookId=   （目录一次性全量返回，不分页）
//
// 播放解析 —— tingshu8.top 自建 PHP（明文 HTTP、零鉴权、从不 429，比 Supabase 层稳定得多）
//   GET /yuan1/lrts.php?id={bookId}*{序号}   →  data.url 为腾讯音乐 CDN 的 m4a（vkey 签名，24h 有效）
//
// 要点：
//   * chapterId 是组合键 "{bookId}*{序号}"，原样回传给 lrts.php 即可
//   * 章节无 paid 字段（整本按免费处理）；实测服务端不校验会员，type:"会员" 的章节同样返回可播 URL
//   * 直链 24h 有效，源内做 TTL 缓存避免重复解析
({
  id: 'tingshu-json-lingyue-lr',
  version: 1,
  name: '聆阅·源A-LR',
  apiVersion: 1,

  _edge: 'https://backend.appmiaoda.com/projects/supabase345057433544081408/functions/v1',
  _edgeKey: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJhdWQiOiJhdXRoZW50aWNhdGVkIiwiZXhwIjoyMTAxNjk1MzAzLCJpc3MiOiJzdXBhYmFzZSIsInJvbGUiOiJhbm9uIiwic3ViIjoiYW5vbiJ9.d_zv-NO7ifqZtHZHdEFYo0Kaxldn9NeW7Yy4YmHnsnc',
  _php: 'http://www.tingshu8.top/yuan1/lrts.php',
  _phpBases: ['http://www.tingshu8.top', 'http://115.190.207.125'],

  _ua: 'okhttp/4.12.0',
  _phpUa: 'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36',

  _bookCache: {}, _urlCache: {}, _queue: null, _lastReqAt: 0,

  _sleep(ms) { return new Promise(r => setTimeout(r, ms)) },

  // ── 播放解析请求的限流闸门（避免对 PHP 层造成压力）──
  _gate() {
    const prev = this._queue || Promise.resolve()
    const job = prev
      .then(() => this._sleep(Math.max(0, this._lastReqAt + 250 - Date.now()) + Math.floor(Math.random() * 120)))
      .then(() => { this._lastReqAt = Date.now() })
    this._queue = job.catch(() => {})
    return job
  },

  _get(url, headers, timeout) {
    return new Promise((resolve, reject) => {
      uni.request({
        url, method: 'GET',
        header: headers || {},
        timeout: timeout || 15000,
        success: resolve,
        fail: e => reject(new Error(e.errMsg || '网络失败')),
      })
    })
  },

  // ── Supabase Edge Function：并发超限时线性退避重试 ──
  // 本源元数据只有这一条路，所以重试次数比源B更激进（默认 6 次）。
  _edgeGet(fn, params, attempts) {
    const qs = Object.keys(params || {}).map(k => k + '=' + encodeURIComponent(params[k])).join('&')
    const url = this._edge + '/' + fn + (qs ? '?' + qs : '')
    const max = attempts || 6
    return (async () => {
      let lastErr = null
      for (let i = 0; i < max; i++) {
        try {
          const r = await this._get(url, {
            apikey: this._edgeKey,
            Authorization: 'Bearer ' + this._edgeKey,
            'User-Agent': this._ua,
          })
          if (r.statusCode !== 200) throw new Error('HTTP ' + r.statusCode)
          const d = typeof r.data === 'string' ? JSON.parse(r.data) : r.data
          if (d && d.code === 'projectConcurrencyLimitExceeded') {
            lastErr = new Error('Supabase 并发超限')
            await this._sleep(800 + i * 1100 + Math.floor(Math.random() * 500))
            continue
          }
          return d
        } catch (e) {
          lastErr = e
          await this._sleep(700 + i * 900 + Math.floor(Math.random() * 400))
        }
      }
      throw lastErr || new Error('Supabase 接口不可用')
    })()
  },

  _toBook(b) {
    return {
      bookId: String(b.id || ''),
      title: String(b.title || '').trim(),
      cover: String(b.cover || ''),
      author: String(b.narrator || b.author || '').split('|').filter(Boolean).join(' / '),
      intro: String(b.description || '').replace(/\s+/g, ' ').trim().slice(0, 80),
    }
  },

  async search(keyword, page = 1) {
    const kw = String(keyword || '').trim()
    const p = Math.max(1, Number(page) || 1)
    if (!kw) return { list: [], page: p, maxPage: 1, hasMore: false }

    const d = await this._edgeGet('lrts-search', { name: kw, page: p })
    const list = (Array.isArray(d && d.books) ? d.books : [])
      .map(b => this._toBook(b))
      .filter(b => b.bookId && b.title)

    // 接口不返回每页条数，按实测 10 条/页 + total 推算总页数
    const total = Number(d && d.total) || 0
    const pageSize = 10
    const maxPage = Math.max(1, Math.ceil(total / pageSize))
    return { list, page: p, maxPage, hasMore: p < maxPage && list.length > 0 }
  },

  async getChapters(bookId, page = 1, pageSize = 100) {
    const id = String(bookId).trim()
    if (!/^\d+$/.test(id)) throw new Error('无效的书籍 ID：' + bookId)
    const p = Math.max(1, Number(page) || 1)

    // lrts-book 一次性返回全部章节，源内按 pageSize 切窗口分页
    let cached = this._bookCache[id]
    if (!cached) {
      const d = await this._edgeGet('lrts-book', { bookId: id })
      const meta = (d && d.meta) || {}
      const chapters = (Array.isArray(d && d.chapters) ? d.chapters : [])
        .map(c => ({
          chapterId: String(c.id || ''),
          name: String(c.title || '').trim(),
          duration: Number(c.duration) || 0,
        }))
        .filter(c => c.chapterId && c.name)
      if (!chapters.length) throw new Error('目录为空或专辑不存在 | ' + id)
      cached = {
        title: String(meta.name || '').trim(),
        cover: String(meta.cover || '').trim(),
        author: String(meta.author || '').split('|').filter(Boolean).join(' / '),
        intro: String(meta.description || '').replace(/\s+/g, ' ').trim(),
        songnum: Number(meta.songnum) || chapters.length,
        chapters,
      }
      this._bookCache[id] = cached
    }

    const rn = Math.max(10, Math.min(Number(pageSize) || 100, 500))
    const all = cached.chapters
    const maxPage = Math.max(1, Math.ceil(all.length / rn))
    const start = (p - 1) * rn
    return {
      info: {
        title: cached.title,
        cover: cached.cover,
        author: cached.author,
        intro: cached.intro,
        trackCount: cached.songnum || all.length,
        // 接口无完结标记，按章节页数推断（有下一页即未完结）
        isFinished: false,
      },
      list: all.slice(start, start + rn).map((c, i) => ({
        chapterId: c.chapterId,
        index: start + i + 1,
        name: c.name,
      })),
      page: p, maxPage, hasMore: p < maxPage,
    }
  },

  async discover() {
    const cats = ['玄幻', '都市', '历史', '悬疑', '评书', '相声', '儿童', '武侠']
    const loaded = new Array(cats.length)
    let next = 0
    // 串行 2 路：Supabase 并发额度紧张，别开太多
    const worker = async () => {
      while (next < cats.length) {
        const i = next++
        try {
          const d = await this._edgeGet('lrts-search', { name: cats[i], page: 1 }, 3)
          const list = (Array.isArray(d && d.books) ? d.books : [])
            .map(b => this._toBook(b))
            .filter(b => b.bookId && b.title)
            .slice(0, 10)
          if (list.length) loaded[i] = { title: cats[i], list }
        } catch (e) {}
      }
    }
    await Promise.all([worker(), worker()])
    return { sections: loaded.filter(Boolean) }
  },

  // ── 播放解析：lrts.php 零鉴权，返回腾讯音乐 CDN 直链（24h 有效）──
  async getAudioUrl(chapterId) {
    const key = String(chapterId).replace(/^MUSIC_/, '').trim()
    if (!/^\d+\*\d+$/.test(key)) throw new Error('无效的章节 ID：' + chapterId)

    const hit = this._urlCache[key]
    if (hit && Date.now() - hit.at < hit.ttl) return hit.value

    await this._gate()
    let lastErr = null
    for (const base of this._phpBases) {
      try {
        const r = await this._get(
          base + '/yuan1/lrts.php?id=' + encodeURIComponent(key),
          { 'User-Agent': this._phpUa, Referer: base + '/' },
          20000
        )
        if (r.statusCode < 200 || r.statusCode >= 300) {
          lastErr = new Error('HTTP ' + r.statusCode)
          continue
        }
        const d = typeof r.data === 'string' ? JSON.parse(r.data) : r.data
        const url = d && d.data && d.data.url
        if (!url || !/^https?:\/\//i.test(String(url))) {
          lastErr = new Error('接口未返回直链：' + String((d && d.message) || '').slice(0, 60))
          await this._sleep(300)
          continue
        }
        const value = { url: String(url), headers: { 'User-Agent': this._phpUa } }
        // 官方声明 24h(86400000ms)，保守按 12h 缓存，避免边界过期
        const ttl = Math.min(Number(d.data.expiredTime) || 43200000, 43200000)
        this._urlCache[key] = { value, at: Date.now(), ttl: ttl - 60000 }
        return value
      } catch (e) {
        lastErr = e
      }
    }
    throw new Error('获取播放直链失败：' + String((lastErr && lastErr.message) || '').slice(0, 80))
  },
})
