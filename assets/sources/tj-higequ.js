// Hi歌曲音乐网（higequ.com · 酷我音乐套壳 · 纯歌曲）
// 搜索：/s/{关键词}/{页码}   播放页：/player/{rid}/（let code = Base64 直链）
// 榜单：/biaosheng|/xinge|/rege|/dy|/jdhj|/ys|/wh|/erge|/cz|/dj|/huayu|/yueyu|/oumei|/hanyu|/riyu|/lxqs|/jpdy|/pbjs|/ktvdc|/bill
// 姊妹站：inmp3.com / xingehui.com（同结构）
({
  id: 'tingshu-json-higequ',
  version: 1,
  name: 'Hi歌曲音乐网',
  apiVersion: 1,
  _site: 'https://higequ.com',
  _ua: 'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
  _metaCache: {}, _audioCache: {}, _queue: null, _lastReqAt: 0,

  _sleep(ms) { return new Promise(r => setTimeout(r, ms)) },
  _gate() {
    const prev = this._queue || Promise.resolve()
    const job = prev.then(() => this._sleep(Math.max(0, this._lastReqAt + 300 - Date.now()) + Math.floor(Math.random() * 150))).then(() => { this._lastReqAt = Date.now() })
    this._queue = job.catch(() => {})
    return job
  },
  _request(url) {
    return new Promise((resolve, reject) => {
      uni.request({ url, method: 'GET', header: { 'User-Agent': this._ua, Referer: this._site + '/' }, timeout: 20000,
        success: r => (r.statusCode >= 200 && r.statusCode < 300) ? resolve(String(r.data || '')) : reject(new Error('HTTP ' + r.statusCode + ' | ' + url)),
        fail: e => reject(new Error(e.errMsg || '网络失败')) })
    })
  },
  async _page(url) { await this._gate(); return this._request(url) },
  _decode(s) { return String(s || '').replace(/&#x?([0-9a-fA-F]+);/g, (_, n) => String.fromCharCode(/^[0-9]+$/.test(n) ? parseInt(n, 10) : parseInt(n, 16))).replace(/&nbsp;/g, ' ').replace(/&amp;/g, '&').replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&lt;/g, '<').replace(/&gt;/g, '>') },
  _clean(s) { return this._decode(String(s || '').replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ')).trim() },
  _pack(v) { return encodeURIComponent(JSON.stringify(v)) },
  _unpack(s) { try { return JSON.parse(decodeURIComponent(String(s || ''))) } catch (e) { return { rid: String(s || '') } } },

  // .result-item 结构：data-rid + result-title/result-artist/result-album
  _parseTracks(html) {
    const out = [], seen = {}; const re = /<div[^>]*class=["'][^"']*result-item[^"']*["'][^>]*data-rid=["'](\d+)["'][^>]*>([\s\S]*?)(?=<div[^>]*class=["'][^"']*result-item|$)/gi; let m
    while ((m = re.exec(html))) {
      const rid = m[1], block = m[2]
      if (!rid || seen[rid]) continue
      const title = this._clean(this._first(block, /class=["'][^"']*result-title[^"']*["'][^>]*>([\s\S]*?)<\/div>/i))
      if (!title) continue
      const artist = this._clean(this._first(block, /class=["'][^"']*result-artist[^"']*["'][^>]*>([\s\S]*?)<\/div>/i))
      const album = this._clean(this._first(block, /class=["'][^"']*result-album[^"']*["'][^>]*>([\s\S]*?)<\/div>/i)).replace(/^专辑[:：]\s*/, '')
      seen[rid] = true
      out.push({ rid, title, artist, album })
    }
    return out
  },
  _first(s, re) { const m = String(s || '').match(re); return m ? m[1] || '' : '' },
  _toBook(t) {
    return {
      bookId: this._pack({ rid: t.rid, name: t.title, artist: t.artist }),
      title: t.title,
      cover: '',
      author: t.artist,
      intro: t.album || ''
    }
  },

  async search(keyword, page = 1) {
    const kw = String(keyword || '').trim()
    const p = Math.max(1, Number(page) || 1)
    if (!kw) return { list: [], page: p, maxPage: 1, hasMore: false }
    const html = await this._page(this._site + '/s/' + encodeURIComponent(kw) + '/' + p)
    const list = this._parseTracks(html).map(t => this._toBook(t))
    return { list, page: p, maxPage: list.length ? p + 1 : p, hasMore: list.length >= 10 }
  },

  async discover() {
    const cats = [
      ['热歌榜单', '/rege/'], ['飙升榜', '/biaosheng/'], ['新歌榜单', '/xinge/'], ['抖音音乐榜', '/dy/'],
      ['经典怀旧榜', '/jdhj/'], ['影视金曲榜', '/ys/'], ['华语榜', '/huayu/'], ['粤语榜', '/yueyu/'],
      ['欧美榜', '/oumei/'], ['儿歌排行榜', '/erge/'], ['DJ音乐排行榜', '/dj/'], ['车载排行榜', '/cz/']
    ]
    const loaded = new Array(cats.length)
    let next = 0
    const worker = async () => {
      while (next < cats.length) {
        const i = next++
        try {
          const html = await this._page(this._site + cats[i][1])
          const tracks = this._parseTracks(html).slice(0, 12)
          if (tracks.length) loaded[i] = { title: cats[i][0], list: tracks.map(t => this._toBook(t)) }
        } catch (e) {}
      }
    }
    await Promise.all([worker(), worker(), worker()])
    return { sections: loaded.filter(Boolean) }
  },

  async getChapters(bookId, page = 1, pageSize = 30) {
    const meta = this._unpack(bookId)
    const rid = String(meta.rid || '')
    if (!/^\d+$/.test(rid)) throw new Error('无效的歌曲 ID')
    let info = this._metaCache[rid]
    if (!info) {
      info = { title: meta.name || '', cover: '', artist: meta.artist || '' }
      this._metaCache[rid] = info
    }
    return {
      info: { title: info.title, cover: info.cover, author: info.artist, intro: '', trackCount: 1, isFinished: true },
      list: [{ chapterId: rid, index: 1, name: info.title || '播放' }],
      page: 1, maxPage: 1, hasMore: false
    }
  },

  async getAudioUrl(chapterId) {
    const rid = String(chapterId).replace(/\D/g, '')
    if (!rid) throw new Error('无效的歌曲 ID')
    const hit = this._audioCache[rid]
    if (hit && Date.now() - hit.at < 240000) return hit.value
    const html = await this._page(this._site + '/player/' + rid + '/')
    const m = html.match(/let code = "([A-Za-z0-9+/=]+)"/)
    if (!m) throw new Error('未解析到音频数据 | ' + rid)
    let url = ''
    try { url = atob(m[1]) } catch (e) { throw new Error('音频数据解码失败') }
    if (!/^https?:\/\//i.test(url)) throw new Error('音频地址无效：' + url.slice(0, 60))
    if (!this._metaCache[rid]) this._metaCache[rid] = { title: '', cover: '', artist: '' }
    if (!this._metaCache[rid].cover) {
      const og = html.match(/og:image\\?" content=\\?"([^"']+)/)
      if (og) this._metaCache[rid].cover = og[1]
    }
    const value = { url, headers: { 'User-Agent': this._ua, Referer: this._site + '/' } }
    this._audioCache[rid] = { value, at: Date.now() }
    return value
  }
})