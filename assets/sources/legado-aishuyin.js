// Converted from docs/shareBookSource-2.json: 爱书音
({
  id: 'legado-aishuyin',
  version: 1,
  name: '爱书音',
  apiVersion: 1,
  _ua: 'Mozilla/5.0 (Linux; Android 13; Mobile) AppleWebKit/537.36 Chrome/124.0 Mobile Safari/537.36',
  _biliUa: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/124.0 Safari/537.36',
  _kuwoAudioSource: 'kwplayercar_ar_6.0.0.9_B_jiakong_vh.apk',
  _yuetingPages: {},
  _yuetingTotals: {},

  _request(url, options) {
    const opts = options || {}
    return new Promise((resolve, reject) => {
      uni.request({
        url,
        method: opts.method || 'GET',
        data: opts.data || null,
        header: Object.assign({
          'User-Agent': opts.userAgent || this._ua,
          Accept: 'application/json, text/plain, */*'
        }, opts.headers || {}),
        timeout: opts.timeout || 25000,
        success: r => {
          if (r.statusCode < 200 || r.statusCode >= 300) {
            reject(new Error('HTTP ' + r.statusCode + ' | ' + url))
            return
          }
          resolve(r.data)
        },
        fail: e => reject(new Error(e.errMsg || '网络失败'))
      })
    })
  },

  async _safe(url, options) {
    try { return await this._request(url, options) } catch (e) { return null }
  },

  _json(value) {
    if (value && typeof value === 'object') return value
    const text = String(value || '').trim()
    if (!text) return {}
    try { return JSON.parse(text) } catch (e) {
      try { return eval('(' + text + ')') } catch (ignored) {
        throw new Error('接口返回的不是有效 JSON')
      }
    }
  },

  _clean(value) {
    return String(value || '')
      .replace(/<em[^>]*>/gi, '')
      .replace(/<\/em>/gi, '')
      .replace(/<[^>]+>/g, '')
      .replace(/&nbsp;/g, ' ')
      .replace(/\s+/g, ' ')
      .trim()
  },

  _cover(value) {
    const url = String(value || '')
    return url.indexOf('//') === 0 ? 'https:' + url : url
  },

  _pack(value) {
    return encodeURIComponent(JSON.stringify(value))
  },

  _unpack(value) {
    try { return JSON.parse(decodeURIComponent(String(value || ''))) } catch (e) {
      return { c: String(value || '') }
    }
  },

  async search(keyword, page = 1, pageSize = 20) {
    const safePage = Math.max(1, Number(page) || 1)
    const size = Math.max(1, Math.min(Number(pageSize) || 20, 20))
    const shuyinSize = Math.max(5, Math.ceil(size / 3))
    const shuyinUrl = 'https://m.shuyinfm.com/api/search/ecms?keyword=' +
      encodeURIComponent(keyword) + '&page=' + safePage + '&pageSize=' + shuyinSize
    const kuwoUrl = 'http://baby.kuwo.cn/tingshu/api/search/Search?rn=' + size +
      '&type=album&version=8.5.6.1&wd=' + encodeURIComponent(keyword) +
      '&pn=' + safePage + '&kweexVersion=1.0.2'
    const biliUrl = 'https://api.bilibili.com/x/web-interface/search/all/v2?keyword=' +
      encodeURIComponent(keyword) + '&page=' + safePage + '&pagesize=' + size
    const yuetingUrl = 'https://m.shuyinfm.com/api/search/yuetingba?keyword=' +
      encodeURIComponent(keyword) + '&page=' + safePage + '&pageSize=' + shuyinSize

    const results = await Promise.all([
      this._safe(shuyinUrl),
      this._safe(kuwoUrl),
      this._safe(biliUrl, {
        userAgent: this._biliUa,
        headers: { Referer: 'https://www.bilibili.com/' }
      }),
      this._safe(yuetingUrl)
    ])
    if (!results[0] && !results[1] && !results[2] && !results[3]) {
      throw new Error('爱书音聚合搜索全部失败')
    }

    const list = []
    const seen = {}
    const add = (source, rawId, title, cover, author, intro, extra) => {
      const id = String(rawId || '')
      const cleanTitle = this._clean(title)
      const key = source + ':' + id
      if (!id || !cleanTitle || seen[key]) return
      seen[key] = true
      const cleanAuthor = this._clean(author)
      const meta = Object.assign({
        s: source,
        id,
        t: cleanTitle,
        c: this._cover(cover),
        a: cleanAuthor
      }, extra || {})
      const label = source === 'shuyin'
        ? '书音FM'
        : (source === 'kuwo' ? '酷我' : (source === 'bili' ? 'B站' : '悦听吧'))
      list.push({
        bookId: this._pack(meta),
        title: cleanTitle,
        cover: meta.c,
        author: label + (cleanAuthor ? ' · ' + cleanAuthor : ''),
        intro: this._clean(intro)
      })
    }

    let maxPage = safePage
    if (results[0]) {
      const res = this._json(results[0])
      const data = res && res.data ? res.data : {}
      const rows = Array.isArray(data.list) ? data.list : []
      rows.forEach(item => add(
        'shuyin', item.id, item.title, item.titlepic,
        item.player || item.username, item.moviesay,
        { f: String(item.filetype || '').indexOf('完结') >= 0 }
      ))
      maxPage = Math.max(maxPage, Number(data.totalpage || safePage) || safePage)
    }

    if (results[1]) {
      const res = this._json(results[1])
      const data = res && res.data ? res.data : {}
      const rows = Array.isArray(data.data) ? data.data : []
      rows.forEach(item => add(
        'kuwo', item.albumId, item.albumName, item.coverImg,
        item.artistName, item.title,
        { n: Number(item.songTotal || 0) || 0, f: true }
      ))
      const total = Number(data.total || rows.length) || rows.length
      maxPage = Math.max(maxPage, Math.max(1, Math.ceil(total / size)))
    }

    if (results[2]) {
      const res = this._json(results[2])
      const data = res && res.data ? res.data : {}
      const groups = Array.isArray(data.result) ? data.result : []
      let videos = []
      for (const group of groups) {
        if (group && group.result_type === 'video' && Array.isArray(group.data)) {
          videos = group.data
          break
        }
      }
      videos.forEach(item => add(
        'bili', item.bvid, item.title, item.pic,
        item.author, item.description || (item.play ? '播放次数: ' + item.play : ''),
        { f: true }
      ))
      const biliSize = Math.max(1, Number(data.pagesize || size) || size)
      const biliTotal = Math.max(0, Number(data.numResults || 0) || 0)
      const biliNext = Math.max(0, Number(data.next || 0) || 0)
      maxPage = Math.max(
        maxPage,
        Number(data.numPages || safePage) || safePage,
        biliTotal > 0 ? Math.ceil(biliTotal / biliSize) : 0,
        biliNext > safePage ? biliNext : 0
      )
    }

    if (results[3]) {
      const res = this._json(results[3])
      const rows = Array.isArray(res.results) ? res.results : []
      rows.forEach(item => add(
        'yueting', item.idPart || item.id, item.title, item.titlepic,
        item.player || item.author, item.moviesay,
        { f: String(item.filetype || '').indexOf('完结') >= 0 }
      ))
      const total = Number(res.total || rows.length) || rows.length
      maxPage = Math.max(maxPage, Math.max(1, Math.ceil(total / shuyinSize)))
    }

    return {
      list,
      page: safePage,
      maxPage,
      hasMore: safePage < maxPage
    }
  },

  async _loadYuetingPage(bookId, remotePage) {
    const key = String(bookId) + ':' + remotePage
    if (this._yuetingPages[key]) return this._yuetingPages[key]
    const url = 'https://m.shuyinfm.com/api/yuetingba/movielist?workId=' +
      encodeURIComponent(bookId) + '&page=' + remotePage
    const res = this._json(await this._request(url))
    const rows = Array.isArray(res.chapters) ? res.chapters : []
    this._yuetingPages[key] = rows
    if (rows.length < 200) {
      this._yuetingTotals[String(bookId)] = (remotePage - 1) * 200 + rows.length
    }
    return rows
  },

  async getChapters(bookId, page = 1, pageSize = 30) {
    const meta = this._unpack(bookId)
    if (!meta.s || !meta.id) throw new Error('爱书音书籍 ID 无效')
    const size = Math.max(1, Math.min(Number(pageSize) || 30, 100))
    const requestedPage = Math.max(1, Number(page) || 1)
    let rows = []
    let total = 0
    let maxPage = 1
    let safePage = requestedPage

    if (meta.s === 'shuyin') {
      const url = 'https://m.shuyinfm.com/ecmsapi/index.php?mod=movie&act=movielist&id=' +
        encodeURIComponent(meta.id) + '&page=' + requestedPage + '&pagesize=' + size
      const res = this._json(await this._request(url))
      const data = res && res.data ? res.data : {}
      rows = Array.isArray(data.moielist) ? data.moielist : []
      total = Number(data.count || rows.length) || rows.length
      maxPage = Math.max(1, Number(data.totalpage || Math.ceil(total / size)) || 1)
      safePage = Math.max(1, Math.min(requestedPage, maxPage))
    } else if (meta.s === 'kuwo') {
      const url = 'http://baby.kuwo.cn/tingshu/api/data/album/songs?albumId=' +
        encodeURIComponent(meta.id) + '&online=0&kweexVersion=1.0.2'
      const res = this._json(await this._request(url))
      const all = Array.isArray(res && res.data) ? res.data : []
      if (all.length) {
        total = all.length
        maxPage = Math.max(1, Math.ceil(total / size))
        safePage = Math.max(1, Math.min(requestedPage, maxPage))
        rows = all.slice((safePage - 1) * size, safePage * size)
      } else {
        const fallbackUrl = 'https://search.kuwo.cn/r.s?stype=albuminfo&albumid=' +
          encodeURIComponent(meta.id) + '&mobi=1&vipver=kwbook_ip_9.2.5.0&pn=' +
          (requestedPage - 1) + '&iskwbook=1&rn=' + size
        const fallback = this._json(await this._request(fallbackUrl))
        rows = Array.isArray(fallback.musiclist) ? fallback.musiclist : []
        total = Number(fallback.songnum || rows.length) || rows.length
        maxPage = Math.max(1, Math.ceil(total / size))
        safePage = Math.max(1, Math.min(requestedPage, maxPage))
      }
    } else if (meta.s === 'bili') {
      const url = 'https://api.bilibili.com/x/web-interface/view/detail?aid=&bvid=' +
        encodeURIComponent(meta.id)
      const res = this._json(await this._request(url, {
        userAgent: this._biliUa,
        headers: { Referer: 'https://www.bilibili.com/video/' + meta.id }
      }))
      const view = res && res.data && res.data.View ? res.data.View : {}
      const all = Array.isArray(view.pages) ? view.pages : []
      total = all.length
      maxPage = Math.max(1, Math.ceil(total / size))
      safePage = Math.max(1, Math.min(requestedPage, maxPage))
      rows = all.slice((safePage - 1) * size, safePage * size)
      meta.t = this._clean(view.title || meta.t)
      meta.c = this._cover(view.pic || meta.c)
      meta.a = this._clean(view.owner && view.owner.name ? view.owner.name : meta.a)
    } else if (meta.s === 'yueting') {
      const start = (requestedPage - 1) * size
      const remotePage = Math.floor(start / 200) + 1
      const remoteOffset = start % 200
      const firstRows = await this._loadYuetingPage(meta.id, remotePage)
      let combined = firstRows
      if (remoteOffset + size > firstRows.length && firstRows.length >= 200) {
        combined = firstRows.concat(
          await this._loadYuetingPage(meta.id, remotePage + 1)
        )
      }
      rows = combined.slice(remoteOffset, remoteOffset + size)
      const totalKnown = Number(this._yuetingTotals[String(meta.id)] || 0) || 0
      if (totalKnown > 0) {
        total = totalKnown
        maxPage = Math.max(1, Math.ceil(total / size))
      } else if (rows.length < size) {
        total = start + rows.length
        this._yuetingTotals[String(meta.id)] = total
        maxPage = Math.max(1, Math.ceil(total / size))
      } else {
        maxPage = requestedPage + 1
      }
      safePage = requestedPage
    } else {
      throw new Error('不支持的爱书音子源: ' + meta.s)
    }

    const start = (safePage - 1) * size
    const chapters = rows.map((item, i) => {
      const rawId = meta.s === 'shuyin' || meta.s === 'yueting'
        ? item.id
        : (meta.s === 'kuwo' ? (item.musicrid || item.id) : item.cid)
      const chapterMeta = {
        s: meta.s,
        b: String(meta.id),
        c: String(rawId || '')
      }
      if (meta.s === 'bili') chapterMeta.p = Number(item.page || start + i + 1)
      return {
        chapterId: this._pack(chapterMeta),
        index: start + i + 1,
        name: this._clean(item.title || item.name || item.songname || item.part || ('第' + (start + i + 1) + '集'))
      }
    }).filter(item => this._unpack(item.chapterId).c)

    return {
      info: {
        title: meta.t || '',
        cover: meta.c || '',
        author: meta.a || '',
        trackCount: total || Number(meta.n || 0) || chapters.length,
        isFinished: meta.f === true
      },
      list: chapters,
      page: safePage,
      maxPage,
      hasMore: safePage < maxPage
    }
  },

  _md5(input) {
    const add32 = (a, b) => (a + b) & 0xFFFFFFFF
    const cmn = (q, a, b, x, s, t) => {
      a = add32(add32(a, q), add32(x, t))
      return add32((a << s) | (a >>> (32 - s)), b)
    }
    const ff = (a, b, c, d, x, s, t) => cmn((b & c) | ((~b) & d), a, b, x, s, t)
    const gg = (a, b, c, d, x, s, t) => cmn((b & d) | (c & (~d)), a, b, x, s, t)
    const hh = (a, b, c, d, x, s, t) => cmn(b ^ c ^ d, a, b, x, s, t)
    const ii = (a, b, c, d, x, s, t) => cmn(c ^ (b | (~d)), a, b, x, s, t)
    const cycle = (x, k) => {
      let a = x[0], b = x[1], c = x[2], d = x[3]
      a = ff(a,b,c,d,k[0],7,-680876936); d = ff(d,a,b,c,k[1],12,-389564586); c = ff(c,d,a,b,k[2],17,606105819); b = ff(b,c,d,a,k[3],22,-1044525330)
      a = ff(a,b,c,d,k[4],7,-176418897); d = ff(d,a,b,c,k[5],12,1200080426); c = ff(c,d,a,b,k[6],17,-1473231341); b = ff(b,c,d,a,k[7],22,-45705983)
      a = ff(a,b,c,d,k[8],7,1770035416); d = ff(d,a,b,c,k[9],12,-1958414417); c = ff(c,d,a,b,k[10],17,-42063); b = ff(b,c,d,a,k[11],22,-1990404162)
      a = ff(a,b,c,d,k[12],7,1804603682); d = ff(d,a,b,c,k[13],12,-40341101); c = ff(c,d,a,b,k[14],17,-1502002290); b = ff(b,c,d,a,k[15],22,1236535329)
      a = gg(a,b,c,d,k[1],5,-165796510); d = gg(d,a,b,c,k[6],9,-1069501632); c = gg(c,d,a,b,k[11],14,643717713); b = gg(b,c,d,a,k[0],20,-373897302)
      a = gg(a,b,c,d,k[5],5,-701558691); d = gg(d,a,b,c,k[10],9,38016083); c = gg(c,d,a,b,k[15],14,-660478335); b = gg(b,c,d,a,k[4],20,-405537848)
      a = gg(a,b,c,d,k[9],5,568446438); d = gg(d,a,b,c,k[14],9,-1019803690); c = gg(c,d,a,b,k[3],14,-187363961); b = gg(b,c,d,a,k[8],20,1163531501)
      a = gg(a,b,c,d,k[13],5,-1444681467); d = gg(d,a,b,c,k[2],9,-51403784); c = gg(c,d,a,b,k[7],14,1735328473); b = gg(b,c,d,a,k[12],20,-1926607734)
      a = hh(a,b,c,d,k[5],4,-378558); d = hh(d,a,b,c,k[8],11,-2022574463); c = hh(c,d,a,b,k[11],16,1839030562); b = hh(b,c,d,a,k[14],23,-35309556)
      a = hh(a,b,c,d,k[1],4,-1530992060); d = hh(d,a,b,c,k[4],11,1272893353); c = hh(c,d,a,b,k[7],16,-155497632); b = hh(b,c,d,a,k[10],23,-1094730640)
      a = hh(a,b,c,d,k[13],4,681279174); d = hh(d,a,b,c,k[0],11,-358537222); c = hh(c,d,a,b,k[3],16,-722521979); b = hh(b,c,d,a,k[6],23,76029189)
      a = hh(a,b,c,d,k[9],4,-640364487); d = hh(d,a,b,c,k[12],11,-421815835); c = hh(c,d,a,b,k[15],16,530742520); b = hh(b,c,d,a,k[2],23,-995338651)
      a = ii(a,b,c,d,k[0],6,-198630844); d = ii(d,a,b,c,k[7],10,1126891415); c = ii(c,d,a,b,k[14],15,-1416354905); b = ii(b,c,d,a,k[5],21,-57434055)
      a = ii(a,b,c,d,k[12],6,1700485571); d = ii(d,a,b,c,k[3],10,-1894986606); c = ii(c,d,a,b,k[10],15,-1051523); b = ii(b,c,d,a,k[1],21,-2054922799)
      a = ii(a,b,c,d,k[8],6,1873313359); d = ii(d,a,b,c,k[15],10,-30611744); c = ii(c,d,a,b,k[6],15,-1560198380); b = ii(b,c,d,a,k[13],21,1309151649)
      a = ii(a,b,c,d,k[4],6,-145523070); d = ii(d,a,b,c,k[11],10,-1120210379); c = ii(c,d,a,b,k[2],15,718787259); b = ii(b,c,d,a,k[9],21,-343485551)
      x[0] = add32(a, x[0]); x[1] = add32(b, x[1]); x[2] = add32(c, x[2]); x[3] = add32(d, x[3])
    }
    const block = s => {
      const out = []
      for (let i = 0; i < 64; i += 4) {
        out[i >> 2] = s.charCodeAt(i) + (s.charCodeAt(i + 1) << 8) +
          (s.charCodeAt(i + 2) << 16) + (s.charCodeAt(i + 3) << 24)
      }
      return out
    }
    const text = unescape(encodeURIComponent(String(input || '')))
    const state = [1732584193, -271733879, -1732584194, 271733878]
    let i
    for (i = 64; i <= text.length; i += 64) cycle(state, block(text.substring(i - 64, i)))
    const rest = text.substring(i - 64)
    let tail = new Array(16).fill(0)
    for (i = 0; i < rest.length; i++) tail[i >> 2] |= rest.charCodeAt(i) << ((i % 4) << 3)
    tail[i >> 2] |= 0x80 << ((i % 4) << 3)
    if (i > 55) { cycle(state, tail); tail = new Array(16).fill(0) }
    tail[14] = text.length * 8
    cycle(state, tail)
    const chars = '0123456789abcdef'
    const hex = n => {
      let value = ''
      for (let j = 0; j < 4; j++) value += chars[(n >> (j * 8 + 4)) & 15] + chars[(n >> (j * 8)) & 15]
      return value
    }
    return state.map(hex).join('')
  },

  async getAudioUrl(chapterId) {
    const info = this._unpack(chapterId)
    if (!info.s || !info.c) throw new Error('爱书音章节 ID 无效')

    if (info.s === 'shuyin') {
      const timestamp = Math.floor(Date.now() / 1000)
      const raw = 'act=series&id=' + info.b + '&mod=movie&movieId=' + info.c +
        '&t=' + timestamp + '&token=ecmsapitoken'
      const token = this._md5(raw)
      const url = 'https://weixin.aikeu.com/ecmsapi/index.php?mod=movie&act=series&movieId=' +
        encodeURIComponent(info.c) + '&id=' + encodeURIComponent(info.b) +
        '&t=' + timestamp + '&token=' + token
      const res = this._json(await this._request(url, {
        headers: { Referer: 'https://m.shuyinfm.com/' }
      }))
      const audioUrl = res && res.data ? res.data.SeriesUrl : ''
      if (audioUrl) return { url: audioUrl, headers: { 'User-Agent': this._ua, Referer: 'https://m.shuyinfm.com/' } }
      throw new Error('书音 FM 音频解析失败')
    }

    if (info.s === 'yueting') {
      if (!uni.crypto || typeof uni.crypto.aesCbcDecrypt !== 'function') {
        throw new Error('当前 App 版本不支持 AES-CBC 解密')
      }
      const api = 'http://yuetingba.cn/api/app/docs-listen/' +
        encodeURIComponent(info.c) + '/ting-with-efi'
      const data = this._json(await this._request(api, {
        headers: { Referer: 'http://yuetingba.cn/' }
      }))
      const tingId = String(data.id || info.c || '').replace(/-/g, '')
      const timeText = String(data.creationTime || '')
        .replace(/-/g, '')
        .replace(/:/g, '')
        .replace(/T/g, '')
        .replace(/\./g, '')
        .replace(/ /g, '')
        .padEnd(20, '0')
      if (!data.efi || tingId.length < 21 || timeText.length < 20) {
        throw new Error('悦听吧 AES 参数不完整')
      }
      let key = ''
      for (let i = 0; i < 20; i++) {
        key += String.fromCharCode(tingId.charCodeAt(i) + Number(timeText[i] || 0))
      }
      for (let i = 20; i < tingId.length; i++) {
        key += String.fromCharCode(tingId.charCodeAt(i) + Number(timeText[i - 20] || 0))
      }
      let iv = ''
      for (let i = 20; i > 4; i--) {
        iv += String.fromCharCode(tingId.charCodeAt(i) + Number(timeText[i - 1] || 0))
      }
      const plain = await uni.crypto.aesCbcDecrypt({
        cipherText: String(data.efi),
        key,
        iv,
        inputEncoding: 'base64',
        keyEncoding: 'utf8',
        ivEncoding: 'utf8'
      })
      let audioPath = String(plain || '').trim()
      try {
        const parsed = JSON.parse(audioPath)
        audioPath = parsed.url || parsed.audioUrl || parsed.playUrl || ''
      } catch (e) {}
      if (!audioPath) throw new Error('悦听吧解密后没有音频地址')
      const audioUrl = /^https?:\/\//i.test(audioPath)
        ? audioPath
        : 'http://36.5.86.125:50011' + (audioPath[0] === '/' ? '' : '/') + audioPath
      return {
        url: audioUrl,
        headers: { 'User-Agent': this._ua, Referer: 'http://yuetingba.cn/' }
      }
    }

    if (info.s === 'kuwo') {
      const rid = String(info.c).replace(/^MUSIC_/i, '').replace(/^kuwo:\/\/track\//i, '').trim()
      const url = 'http://mobi.kuwo.cn/mobi.s?f=web&user=0&source=' +
        encodeURIComponent(this._kuwoAudioSource) +
        '&type=convert_url_with_sign&br=128k&sig=0&rid=' + encodeURIComponent(rid)
      const res = this._json(await this._request(url))
      const data = res && res.data ? res.data : res
      if (data && data.url) return String(data.url).replace(/\$(?=\S)/g, '=')
      throw new Error('酷我音频解析失败')
    }

    if (info.s === 'bili') {
      const referer = 'https://www.bilibili.com/video/' + info.b + '?p=' + (info.p || 1)
      const api = 'https://api.bilibili.com/x/player/playurl?bvid=' + encodeURIComponent(info.b) +
        '&cid=' + encodeURIComponent(info.c) + '&qn=0&fnval=16&fnver=0&fourk=1'
      const res = this._json(await this._request(api, {
        userAgent: this._biliUa,
        headers: { Referer: referer, Origin: 'https://www.bilibili.com' }
      }))
      const dash = res && res.data && res.data.dash ? res.data.dash : {}
      const audios = Array.isArray(dash.audio) ? dash.audio : []
      audios.sort((a, b) => Number(b.bandwidth || 0) - Number(a.bandwidth || 0))
      const audio = audios[0] || {}
      const audioUrl = audio.baseUrl || audio.base_url ||
        (Array.isArray(audio.backupUrl) ? audio.backupUrl[0] : '') ||
        (Array.isArray(audio.backup_url) ? audio.backup_url[0] : '')
      if (audioUrl) {
        return {
          url: audioUrl,
          headers: {
            'User-Agent': this._biliUa,
            Referer: referer,
            Origin: 'https://www.bilibili.com',
            Accept: '*/*',
            Range: 'bytes=0-'
          }
        }
      }
      return {
        sniff: true,
        url: referer,
        headers: { 'User-Agent': this._biliUa, Referer: referer, Origin: 'https://www.bilibili.com' },
        waitMs: 3500,
        audioPatterns: ['.m4s', '.mp4', '.m4a', '.mp3']
      }
    }

    throw new Error('不支持的爱书音子源: ' + info.s)
  }
})
