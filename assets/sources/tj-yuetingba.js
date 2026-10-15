// 悦听吧（www.yuetingba.cn）· 纯源实现，不依赖任何自建中转服务
// 搜索:  GET /Search?type=1&name={关键词}                       → HTML，解析 /book/detail/{guid}/0
// 目录:  GET /book/detail/{guid}/{skip}                         → HTML，每页 200 集（skip=0,200,400…）
//        章节 = <a title="{标题}" onclick="testFn('{tingId}')">
// 音频:  ① GET /api/app/docs-listen/{tingId}/ting-with-efi       → {efi, creationTime, title}
//        ② fileName = AES-256-CBC 解密 efi，密钥/IV 由 tingId 与 creationTime 逐字节相加派生
//        ③ token = MD5(fileName + '|' + expire + '|' + sk)，expire = 当前秒 + 600
//        ④ 音频服务器列表在书籍页的 var assl 里（去掉 sk 子串后 AES-128-CBC 解密成 JSON）
//        ⑤ 最终地址 = 服务器地址 + 路径 + '?token=…&expire=…'
// 说明:  站点有请求频率限制（连续请求 429），源内做了间隔与退避；多台音频服务器只有部分可用，
//        逐个探测取第一个能返回音频的（结果缓存复用）
({
  name: '悦听吧',
  id: 'tingshu-json-yuetingba',
  version: 3,
  apiVersion: 1,
  _site: 'http://www.yuetingba.cn',
  _ua: 'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Mobile Safari/537.36',
  _sk: 'xMiP5W1DHBxC5PwQ5oj5QfRn0tsT5UBk',        // 站点固定密钥：既用于剥离 assl 前缀，也用于 token 签名
  _asKey: 'le95G3hnFDJsBE+1/v9eYw==',             // assl 解密密钥（AES-128-CBC）
  _asIv: 'IvswQFEUdKYf+d1wKpYLTg==',
  _bookCache: {}, _audioCache: {}, _servers: null, _goodServer: '',
  _queue: null, _lastReqAt: 0,

  _sleep(ms) { return new Promise(r => setTimeout(r, ms)) },
  _gate() {
    const prev = this._queue || Promise.resolve()
    const job = prev.then(() => this._sleep(Math.max(0, this._lastReqAt + 900 - Date.now()))).then(() => { this._lastReqAt = Date.now() })
    this._queue = job.catch(() => {})
    return job
  },
  async _raw(url, referer, headers) {
    await this._gate()
    return await new Promise((resolve, reject) => {
      uni.request({
        url, method: 'GET',
        header: Object.assign({ 'User-Agent': this._ua, Referer: referer || this._site + '/' }, headers || {}),
        timeout: 30000,
        success: x => resolve({ statusCode: x.statusCode || 0, data: x.data }),
        fail: e => reject(new Error(e.errMsg || '网络失败'))
      })
    })
  },
  async _page(url, referer) {
    let last = ''
    for (let i = 0; i < 4; i++) {
      const r = await this._raw(url, referer)
      if (r.statusCode === 200) return String(r.data || '')
      last = 'HTTP ' + r.statusCode
      if (r.statusCode === 429 || r.statusCode >= 500) { await this._sleep(2500 + i * 2500); continue }
      break
    }
    throw new Error(last || '请求失败')
  },
  async _json(url, referer) {
    const r = await this._raw(url, referer)
    if (r.statusCode < 200 || r.statusCode >= 300) throw new Error('HTTP ' + r.statusCode)
    if (r.data && typeof r.data === 'object') return r.data
    try { return JSON.parse(String(r.data || '')) } catch (e) { throw new Error('返回不是 JSON') }
  },
  _decode(s) {
    return String(s || '')
      .replace(/&#(\d+);/g, (_, n) => String.fromCharCode(parseInt(n, 10)))
      .replace(/&nbsp;/g, ' ').replace(/&amp;/g, '&').replace(/&quot;/g, '"')
      .replace(/&#39;/g, "'").replace(/&lt;/g, '<').replace(/&gt;/g, '>')
  },
  _clean(s) { return this._decode(String(s || '').replace(/<script[\s\S]*?<\/script>/gi, ' ').replace(/<style[\s\S]*?<\/style>/gi, ' ').replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ')).trim() },
  _attr(tag, name) { const m = String(tag || '').match(new RegExp(name + "\\s*=\\s*(\"([^\"]*)\"|'([^']*)'|([^\\s>]+))", 'i')); return m ? this._decode(m[2] || m[3] || m[4] || '') : '' },
  _abs(url, base) {
    url = this._decode(String(url || '').trim())
    if (!url) return ''
    if (/^https?:\/\//i.test(url)) return url
    if (url.indexOf('//') === 0) return 'http:' + url
    if (url[0] === '/') return this._site + url
    return String(base || this._site + '/').replace(/[#?].*$/, '').replace(/\/[^/]*$/, '/') + url
  },
  _first(s, re) { const m = String(s || '').match(re); return m ? (m[1] || '') : '' },
  _guid(s) { return (String(s || '').match(/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})/i) || [])[1] || '' },
  _hex(s) { let out = ''; for (let i = 0; i < s.length; i++) { const c = s.charCodeAt(i) & 0xff; out += ('0' + c.toString(16)).slice(-2) } return out },

  // ── 密钥派生（与站点播放器一致）──
  // key: 前 20 字节逐位相加，其余字节与 iv 循环相加；iv: 取 20..5 反向逐位相加
  _gk(key, iv) {
    let out = ''
    for (let i = 0; i < 20; i++) out += String.fromCharCode(key[i].charCodeAt(0) + Number(iv[i]))
    for (let i = 20; i < key.length; i++) out += String.fromCharCode(key[i].charCodeAt(0) + Number(iv[i - 20]))
    return out
  },
  _gi(key, iv) {
    let out = ''
    for (let i = 20; i > 4; i--) out += String.fromCharCode(key[i].charCodeAt(0) + Number(iv[i - 1]))
    return out
  },
  async _aesDecrypt(cipherB64, key, iv, keyIsBase64) {
    const plain = await uni.crypto.aesCbcDecrypt({
      cipherText: cipherB64,
      key: key,
      iv: iv,
      inputEncoding: 'base64',
      keyEncoding: keyIsBase64 ? 'base64' : 'hex',
      ivEncoding: keyIsBase64 ? 'base64' : 'hex'
    })
    return String(plain || '')
  },

  // ── 音频服务器列表：来自书籍页 var assl（去 sk 前缀 → AES 解密 → JSON）──
  async _serverList(guid) {
    if (this._servers && this._servers.length) return this._servers
    const html = await this._page(this._site + '/book/detail/' + guid + '/0')
    const assl = this._first(html, /var\s+assl\s*=\s*'([^']+)'/)
    if (!assl) throw new Error('书籍页缺少服务器信息')
    const json = await this._aesDecrypt(assl.split(this._sk).join(''), this._asKey, this._asIv, true)
    let list = []
    try { list = JSON.parse(json) } catch (e) { throw new Error('服务器信息解析失败') }
    if (!Array.isArray(list) || !list.length) throw new Error('服务器列表为空')
    this._servers = list
    return list
  },
  _candidates(list) {
    // 站点规则：AsType=1 为音频服务器，Type=A 为 IPv4；按 Ratio 加权随机
    const ok = list.filter(s => String(s.AsType) === '1' && String(s.Type) === 'A')
    const use = ok.length ? ok : list
    const total = use.reduce((a, s) => a + (Number(s.Ratio) || 0), 0)
    if (total > 0) {
      // 加权顺序：先按权重降序，探测时依次尝试
      return use.slice().sort((a, b) => (Number(b.Ratio) || 0) - (Number(a.Ratio) || 0))
    }
    return use
  },
  _serverUrl(s) { return s.Scheme + '://' + s.Value + ':' + s.Port },
  _pathFor(s, plain, py, bookId, fileName) {
    const name = String(s.Name || '')
    if (name.slice(-2) === '_b') return '/myfiles/host/listen/booksdir/' + py + '_' + bookId + '/' + fileName
    if (name.slice(-2) === '_p') return '/' + py + '_' + bookId + '/' + fileName
    return plain
  },

  _parseBooks(html) {
    const list = [], seen = {}
    const re = /<a\b[^>]*href=["']([^"']*\/book\/detail\/[^"']+)["'][^>]*>([\s\S]{0,600}?)<\/a>/gi
    let m
    while ((m = re.exec(html)) !== null) {
      const href = this._abs(m[1], this._site)
      if (seen[href]) continue
      const inner = m[2]
      const img = this._first(inner, /(<img\b[^>]*>)/i)
      const alt = this._attr(img, 'alt')
      const title = this._clean(
        this._first(inner, /class=["'][^"']*box-list-item-text-title[^"']*["'][^>]*>([\s\S]*?)<\/[^>]+>/i) ||
        (alt ? alt.split(/有声小说|免费听书|在线听/)[0] : '') ||
        inner
      )
      if (!title) continue
      const block = html.slice(Math.max(0, m.index - 200), Math.min(html.length, m.index + 2500))
      seen[href] = true
      list.push({
        bookId: href,
        title: title.replace(/^《|》$/g, '').trim(),
        cover: this._abs(this._attr(img, 'src'), this._site),
        author: this._first(block, /主播[:：]\s*([^<\s]{1,20})/),
        intro: this._clean(this._first(block, /class=["'][^"']*box-list-item-text-intro[^"']*["'][^>]*>([\s\S]*?)<\/[^>]+>/i))
      })
    }
    return list
  },

  async search(keyword, page = 1, pageSize = 20) {
    const kw = String(keyword || '').trim()
    if (!kw) return { list: [], page: 1, maxPage: 1, hasMore: false }
    const html = await this._page(this._site + '/Search?type=1&name=' + encodeURIComponent(kw))
    const list = this._parseBooks(html).slice(0, Math.max(1, Number(pageSize) || 20))
    return { list, page: 1, maxPage: 1, hasMore: false }
  },

  // ── 发现页 ──
  // 站点没有传统分类页。内容入口是榜单页（/top/recommend|plays|latest/页码），
  // 每个榜单页含两个区块（如「有声小说推荐榜」+「收听排行榜」），按区块切分解析。
  // 注意：搜索接口（/Search）限流很严（约 6 秒 1 次），所以发现页不调用搜索，只取榜单，保证加载快。
  _parseRankSections(html) {
    const marks = []
    const re = /<h1[^>]*class="[^"]*section-box-title[^"]*"[^>]*>([\s\S]*?)<\/h1>/gi
    let m
    while ((m = re.exec(html)) !== null) {
      let title = this._clean(m[1]).replace(/\s*更多\s*$/, '').trim()
      if (!title) title = '榜单'
      marks.push({ title, at: m.index + m[0].length })
    }
    const out = []
    for (let i = 0; i < marks.length; i++) {
      const block = html.slice(marks[i].at, i + 1 < marks.length ? marks[i + 1].at : html.length)
      const list = this._parseBooks(block).slice(0, 12)
      if (list.length) out.push({ title: marks[i].title, list })
    }
    return out
  },
  async discover() {
    const sections = []
    const seenSets = []
    const pages = ['/top/recommend/1', '/top/plays/1', '/top/latest/1']
    for (const p of pages) {
      let found = []
      try { found = this._parseRankSections(await this._page(this._site + p)) } catch (e) { continue }
      for (const s of found) {
        // 同一榜单在页面上有两种展示（精选块 + 列表块），书目高度重合时只保留一个
        const ids = s.list.map(b => b.bookId)
        const dup = seenSets.some(prev => {
          const common = ids.filter(id => prev.indexOf(id) >= 0).length
          return common >= Math.max(3, Math.ceil(ids.length * 0.6))
        })
        if (dup) continue
        seenSets.push(ids)
        sections.push(s)
      }
    }
    return { sections: sections.slice(0, 6) }
  },

  _bookInfo(html) {
    const title = this._clean(this._first(html, /<h1[^>]*class=["'][^"']*hidden-xs[^"']*["'][^>]*>([\s\S]*?)<\/h1>/i)) ||
      this._clean(this._first(html, /<h1[^>]*>([\s\S]*?)<\/h1>/i))
    const author = this._first(html, /var\s+bookAuthorName\s*=\s*'([^']*)'/) || ''
    const speaker = this._first(html, /var\s+speakerNames\s*=\s*'([^']*)'/) || ''
    const cover = this._abs(this._first(html, /var\s+bookImageUrl\s*=\s*'([^']*)'/) || this._first(html, /<img\b[^>]*src=["']([^"']+)["']/i), this._site)
    const py = this._first(html, /var\s+py\s*=\s*'([^']*)'/) || ''
    return { title, cover, author: [author, speaker].filter(Boolean).join(' / '), py }
  },

  async getChapters(bookId, page = 1, pageSize = 30) {
    const guid = this._guid(bookId)
    if (!guid) throw new Error('无效的书籍地址')
    const p = Math.max(1, Number(page) || 1)
    const size = Math.max(1, Math.min(Number(pageSize) || 30, 100))
    let entry = this._bookCache[guid]
    if (!entry) {
      const list = []
      const seen = {}
      const collect = html => {
        const re = /<a\b[^>]*title=["']([^"']{1,160})["'][^>]*onclick=["']testFn\('([^']+)'\)/gi
        let m, added = 0
        while ((m = re.exec(html)) !== null) {
          const name = this._clean(m[1])
          const id = m[2]
          if (!name || !id || seen[id]) continue
          seen[id] = 1
          list.push({ id, name })
          added++
        }
        return added
      }
      const first = await this._page(this._site + '/book/detail/' + guid + '/0')
      const info = this._bookInfo(first)
      // 顺手把 assl 也解出来缓存，播放时就不必再取一次书籍页
      try {
        const assl = this._first(first, /var\s+assl\s*=\s*'([^']+)'/)
        if (assl && !this._servers) {
          const json = await this._aesDecrypt(assl.split(this._sk).join(''), this._asKey, this._asIv, true)
          const parsed = JSON.parse(json)
          if (Array.isArray(parsed) && parsed.length) this._servers = parsed
        }
      } catch (e) {}
      let added = collect(first)
      for (let skip = 200; skip <= 6000 && added >= 200; skip += 200) {
        let html
        try { html = await this._page(this._site + '/book/detail/' + guid + '/' + skip) } catch (e) { break }
        added = collect(html)
      }
      if (!list.length) throw new Error('目录为空或该书籍已下架')
      entry = { info, list }
      this._bookCache[guid] = entry
    }
    const maxPage = Math.max(1, Math.ceil(entry.list.length / size))
    const safePage = Math.max(1, Math.min(p, maxPage))
    const start = (safePage - 1) * size
    return {
      info: {
        title: entry.info.title, cover: entry.info.cover, author: entry.info.author,
        trackCount: entry.list.length, isFinished: true
      },
      list: entry.list.slice(start, start + size).map((x, i) => ({
        chapterId: guid + '|' + x.id,
        index: start + i + 1,
        name: x.name
      })),
      page: safePage, maxPage, hasMore: safePage < maxPage
    }
  },

  async getAudioUrl(chapterId) {
    const s = String(chapterId || '')
    const sep = s.indexOf('|')
    if (sep < 1) throw new Error('无效的章节 ID')
    const guid = s.slice(0, sep)
    const tingId = s.slice(sep + 1)
    const hit = this._audioCache[s]
    if (hit && Date.now() - hit.at < hit.ttl) return hit.value

    // 1) 取加密的音频文件信息
    const j = await this._json(this._site + '/api/app/docs-listen/' + encodeURIComponent(tingId) + '/ting-with-efi', this._site + '/')
    if (!j || !j.efi) throw new Error('该章节暂不可播放' + (j && j.msg ? '：' + this._clean(j.msg) : ''))

    // 2) 解密得到文件路径
    const key = tingId.split('-').join('')
    const iv = String(j.creationTime || '').split('-').join('').split(':').join('').split('T').join('').split('.').join('').split(' ').join('')
    const plain = await this._aesDecrypt(j.efi, this._hex(this._gk(key, iv.padEnd(20, '0'))), this._hex(this._gi(key, iv.padEnd(20, '0'))), false)
    if (!plain || plain.indexOf('/') < 0) throw new Error('音频信息解密失败')
    let fileName = ''
    try { fileName = decodeURIComponent(plain.split('/').pop()) } catch (e) { fileName = plain.split('/').pop() }
    if (!fileName) throw new Error('未解析出文件名')

    // 3) 签名
    const expire = Math.floor(Date.now() / 1000) + 600
    const token = String(await uni.crypto.md5Hex({ text: fileName + '|' + expire + '|' + this._sk })).trim()

    // 4) 选服务器并探测（多台服务器只有部分可用，成功的那台记住复用）
    const meta = this._bookCache[guid] || { info: {} }
    const py = (meta.info && meta.info.py) || ''
    const list = this._candidates(await this._serverList(guid))
    const ordered = this._goodServer ? list.slice().sort((a, b) => (this._serverUrl(b) === this._goodServer ? 1 : 0) - (this._serverUrl(a) === this._goodServer ? 1 : 0)) : list
    let lastErr = ''
    for (const sv of ordered) {
      const base = this._serverUrl(sv)
      const url = base + this._pathFor(sv, plain, py, guid, fileName) + '?token=' + token + '&expire=' + expire
      try {
        const r = await this._raw(url, this._site + '/', { Range: 'bytes=0-1' })
        if (r.statusCode === 200 || r.statusCode === 206) {
          this._goodServer = base
          const value = { url, headers: { 'User-Agent': this._ua, Referer: this._site + '/' } }
          this._audioCache[s] = { value, at: Date.now(), ttl: 4 * 60 * 1000 }   // 地址 10 分钟过期，缓存 4 分钟
          return value
        }
        lastErr = 'HTTP ' + r.statusCode
      } catch (e) { lastErr = e.message }
    }
    throw new Error('音频服务器均不可用' + (lastErr ? '（' + lastErr + '）' : ''))
  }
})