// 聚合听书（四平台聚合：酷我 kw / 网易 wy / QQ tx / 酷狗 kg）
// 搜索聚合 5 路：kw官方专辑 + tingshu8聚合 + wy歌单 + tx专辑 + kg专辑
// 解析：kw 特化通道（mobi.s → higequ → antiserver）先行，聆澜/ikun/HYW 全平台兜底
({
  id: 'tingshu-json-juhe',
  version: 1,
  name: '聚合听书',
  apiVersion: 1,
  _kwUa: 'okhttp/4.9.0',
  _ua: 'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Mobile Safari/537.36',
  _lxUa: 'lx-music-request/2.0.0',
  _llKey: 'CERU_KEY-31C0DB0B-2DFF-42EF-A2DB-47863E658840',
  _ikKey: 'IKM-P18200001-AyKQrBcgmEyPDpRy-0t',
  _hywKey: 'PYPW-QFRL-3DBF-95O6',
  _chapterCache: {}, _audioCache: {}, _queue: null, _lastReqAt: 0,

  _sleep(ms) { return new Promise(r => setTimeout(r, ms)) },
  _gate() {
    const prev = this._queue || Promise.resolve()
    const job = prev.then(() => this._sleep(Math.max(0, this._lastReqAt + 300 - Date.now()) + Math.floor(Math.random() * 150))).then(() => { this._lastReqAt = Date.now() })
    this._queue = job.catch(() => {})
    return job
  },
  _http(o) {
    o = o || {}
    return new Promise((resolve, reject) => {
      uni.request({
        url: o.url, method: o.method || 'GET', data: o.data, header: o.headers || {}, timeout: o.timeout || 15000,
        success: r => resolve({ statusCode: r.statusCode || 0, data: r.data, text: typeof r.data === 'string' ? r.data : (r.data ? JSON.stringify(r.data) : '') }),
        fail: e => reject(new Error(e.errMsg || '网络失败'))
      })
    })
  },
  async _get(url, headers, timeout) { await this._gate(); return this._http({ url, headers, timeout }) },
  // 容错解析：先 JSON，再 Python dict（单引号）风格，PHP 前缀 Warning 截断
  _j(d) {
    if (d && typeof d === 'object') return d
    const s = String(d || '')
    const i = s.indexOf('{')
    const body = i > 0 ? s.slice(i) : s
    try { return JSON.parse(body) } catch (e) {
      try { return new Function('return (' + body + ')')() } catch (e2) { return null }
    }
  },
  _pack(v) { return encodeURIComponent(JSON.stringify(v)) },
  _unpack(s) { try { return JSON.parse(decodeURIComponent(String(s || ''))) } catch (e) { return {} } },
  _clean(s) { return String(s || '').replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ').trim() },

  // ============ 搜索层 ============
  // 酷我官方专辑搜索（专辑级）
  async _searchKwO(kw, page) {
    const r = await this._get('http://tingshu.kuwo.cn/tingshu/api/search/Search?rn=20&type=album&version=8.5.6.1&wd=' + encodeURIComponent(kw) + '&pn=' + (page - 1), { 'User-Agent': this._kwUa })
    const j = this._j(r.data)
    const items = (j && j.data && Array.isArray(j.data.data)) ? j.data.data : []
    return items.map(x => ({ p: 'kw', t: 'al', id: String(x.albumId || ''), n: String(x.albumName || '').trim(), c: String(x.coverImg || ''), a: String(x.artistName || '').trim(), tag: '酷我专辑', total: Number(x.songTotal) || 0 })).filter(b => b.id && b.n)
  },
  _tsScore(an, artist, tracks, kw) {
    let score = 0
    if (/有声|广播剧|多播|小说|原著|演播|评书|相声|连载|听书/.test(an)) score += 4
    if (kw && an.indexOf(kw) >= 0) score += 2
    if ((tracks || []).filter(t => /第\s*\d+\s*[集章回]/.test(t)).length > 0) score += 2
    if (tracks && tracks.length >= 3) score += 1
    if (/文化|声工场|工作室|有声|演播/.test(String(artist || ''))) score += 1
    return score
  },
  // tingshu8 聚合搜索（曲目按专辑聚合成书，有声书优先）
  async _searchTs8(kw, page) {
    const r = await this._get('http://www.tingshu8.top/search.php?all=' + encodeURIComponent(kw) + '&rn=30&pn=' + page, { 'User-Agent': this._kwUa })
    const j = this._j(r.data)
    const groups = {}, order = []
    for (const t of (Array.isArray(j.list) ? j.list : [])) {
      const albumid = String(t.albumid || '')
      if (!albumid || albumid === '0') continue
      if (!groups[albumid]) { groups[albumid] = { albumid, album: String(t.album || ''), artist: String(t.artist || ''), img: String(t.img || ''), tracks: [] }; order.push(albumid) }
      groups[albumid].tracks.push(String(t.name || ''))
      if (!groups[albumid].album && t.album) groups[albumid].album = String(t.album)
    }
    const list = order.map(id => {
      const g = groups[id]
      return { p: 'kw', t: 'al', id: g.albumid, n: g.album.trim(), c: g.img, a: this._clean(g.artist.split('&').filter(x => x && x !== 'Unknown Singer').join(' / ')), tag: '听书聚合', total: g.tracks.length, _score: this._tsScore(g.album, g.artist, g.tracks, kw) }
    }).filter(b => b.n).sort((x, y) => y._score - x._score)
    return list.map(x => { const o = { p: x.p, t: x.t, id: x.id, n: x.n, c: x.c, a: x.a, tag: x.tag, total: x.total }; return o })
  },
  // 网易歌单搜索（用户上传的整本有声书）
  async _searchWy(kw, page) {
    const r = await this._get('https://music.163.com/api/search/get/web?s=' + encodeURIComponent(kw) + '&type=1000&offset=' + ((page - 1) * 20) + '&limit=20', { 'User-Agent': this._ua, Referer: 'https://music.163.com/' })
    const j = this._j(r.data)
    const list = (j.result && Array.isArray(j.result.playlists)) ? j.result.playlists : []
    return list.map(x => ({ p: 'wy', t: 'pl', id: String(x.id || ''), n: String(x.name || '').trim(), c: String(x.coverImgUrl || ''), a: String((x.creator && x.creator.nickname) || ''), tag: '网易歌单', total: Number(x.trackCount) || 0 })).filter(b => b.id && b.n)
  },
  // QQ 专辑搜索（musicu.fcg，喜马拉雅等有声书专辑）
  async _searchTx(kw, page) {
    const data = JSON.stringify({ req: { module: 'music.search.SearchCgiService', method: 'DoSearchForQQMusicDesktop', param: { query: kw, search_type: 2, page_num: page, num_per_page: 20 } } })
    const r = await this._get('https://u.y.qq.com/cgi-bin/musicu.fcg?data=' + encodeURIComponent(data), { 'User-Agent': this._ua, Referer: 'https://y.qq.com/' }, 20000)
    const j = this._j(r.data)
    const list = (j.req && j.req.data && j.req.data.body && Array.isArray(j.req.data.body.album.list)) ? j.req.data.body.album.list : []
    return list.map(x => ({ p: 'tx', t: 'al', id: String(x.albumMID || x.albummid || ''), n: String(x.albumName || '').trim(), c: String(x.albumPic || '').replace('180x180', '500x500'), a: String(x.singerName || ''), tag: 'QQ专辑', total: Number(x.song_count) || 0 })).filter(b => b.id && b.n)
  },
  // 酷狗专辑搜索
  async _searchKg(kw, page) {
    const r = await this._get('http://mobilecdnbj.kugou.com/api/v3/search/album?keyword=' + encodeURIComponent(kw) + '&page=' + page + '&pagesize=20', { 'User-Agent': this._ua })
    const j = this._j(r.data)
    const list = (j.data && Array.isArray(j.data.info)) ? j.data.info : []
    return list.map(x => ({ p: 'kg', t: 'al', id: String(x.albumid || ''), n: String(x.albumname || '').trim(), c: String(x.imgurl || '').replace('{size}', '240'), a: String(x.singername || ''), tag: '酷狗专辑', total: Number(x.songs_count) || 0 })).filter(b => b.id && b.n)
  },

  _toBook(b) {
    return {
      bookId: this._pack({ p: b.p, t: b.t, id: b.id, n: b.n, c: b.c, a: b.a }),
      title: b.n,
      cover: b.c,
      author: b.a,
      intro: '[' + b.tag + ']' + (b.total ? b.total + '集' : '')
    }
  },

  async search(keyword, page = 1) {
    const kw = String(keyword || '').trim()
    const p = Math.max(1, Number(page) || 1)
    if (!kw) return { list: [], page: p, maxPage: 1, hasMore: false }
    const rs = await Promise.allSettled([
      this._searchKwO(kw, p).catch(() => []),
      this._searchTs8(kw, p).catch(() => []),
      this._searchWy(kw, p).catch(() => []),
      this._searchTx(kw, p).catch(() => []),
      this._searchKg(kw, p).catch(() => [])
    ])
    const vals = rs.map(x => (x.status === 'fulfilled' ? x.value : []))
    // 四平台等权：轮询合并（kw官方 → wy → tx → kg → tingshu8），kw 内部按 albumid 去重
    const groups = [vals[0], vals[2], vals[3], vals[4], vals[1]]
    const seen = {}, list = []
    for (let round = 0; round < 10; round++) {
      let added = 0
      for (const g of groups) {
        const b = g[round]
        if (!b) continue
        const key = b.p + ':' + b.id
        if (seen[key]) continue
        seen[key] = 1
        list.push(this._toBook(b))
        added++
      }
      if (!added) break
    }
    const hasMore = vals.some(v => v.length >= 15)
    return { list, page: p, maxPage: hasMore ? p + 1 : p, hasMore }
  },

  // ============ 目录层（拉全量 + 客户端分页） ============
  async _chaptersKwAlbum(id) {
    const list = []
    let title = '', cover = '', author = ''
    // 酷我专辑按最新在前返回，rn=1000 分页拉全量后倒序
    for (let pn = 0; pn < 20; pn++) {
      const r = await this._get('http://search.kuwo.cn/r.s?pn=' + pn + '&rn=1000&stype=albuminfo&albumid=' + encodeURIComponent(id) + '&show_copyright_off=0&encoding=utf&vipver=MUSIC_9.1.0', { 'User-Agent': this._kwUa }, 30000)
      const j = this._j(r.data)
      if (pn === 0) {
        title = this._clean(j.albumname || j.name)
        cover = String(j.img || j.hts_img || '')
        author = this._clean(j.artist || '')
      }
      const tracks = Array.isArray(j.musiclist) ? j.musiclist : (Array.isArray(j.abslist) ? j.abslist : [])
      if (!tracks.length) break
      for (const t of tracks) {
        const idt = String(t.rid || t.musicrid || t.MUSICRID || t.id || '')
        const name = this._clean(t.name || t.songname || t.SONGNAME || '')
        if (idt && name) list.push({ id: idt, name })
      }
      if (tracks.length < 1000) break
    }
    list.reverse()
    this._sinkNoChapterNo(list)
    return { title, cover, author, list }
  },
  async _chaptersKwPl(id) {
    const r = await this._get('http://nplserver.kuwo.cn/pl.svc?op=getlistinfo&pid=' + encodeURIComponent(id) + '&pn=0&rn=1000&encode=utf8&keyset=pl2012&identity=kuwo&pcmp4=1&vipver=MUSIC_9.0.5.0_W1&newver=1', { 'User-Agent': this._kwUa }, 30000)
    const j = this._j(r.data)
    const tracks = Array.isArray(j.musiclist) ? j.musiclist : []
    const list = tracks.map(t => ({ id: String(t.rid || t.musicrid || t.MUSICRID || t.id || ''), name: this._clean(t.name || t.songname || '') })).filter(t => t.id && t.name)
    return { title: this._clean(j.title), cover: String(j.pic || ''), author: this._clean(j.uname || ''), list }
  },
  async _chaptersWy(id) {
    const h = { 'User-Agent': this._ua, Referer: 'https://music.163.com/' }
    // v6 接口返回完整 trackIds（legacy 只回 10 条 tracks 且 trackIds 为空）
    const r = await this._get('https://music.163.com/api/v6/playlist/detail?id=' + encodeURIComponent(id), h, 30000)
    const j = this._j(r.data)
    const pl = (j && j.playlist) || {}
    const info = { title: this._clean(pl.name || ''), cover: String(pl.coverImgUrl || ''), author: this._clean((pl.creator && pl.creator.nickname) || ''), list: [] }
    const ids = Array.isArray(pl.trackIds) ? pl.trackIds.map(x => String(x.id || x)) : []
    if (!ids.length) {
      const ts = Array.isArray(pl.tracks) ? pl.tracks : []
      info.list = ts.map(t => ({ id: String(t.id || ''), name: this._clean(t.name || '') })).filter(t => t.id && t.name)
      return info
    }
    // 按 trackIds 顺序分批拉 song/detail（每批 100）
    for (let i = 0; i < ids.length; i += 100) {
      const chunk = ids.slice(i, i + 100)
      try {
        const sr = await this._get('https://music.163.com/api/song/detail?ids=[' + chunk.join(',') + ']', h, 30000)
        const sj = this._j(sr.data)
        const byId = {}
        for (const s of (Array.isArray(sj.songs) ? sj.songs : [])) byId[String(s.id)] = this._clean(s.name || '')
        for (const idc of chunk) { const nm = byId[idc]; if (nm) info.list.push({ id: idc, name: nm }) }
      } catch (e) { break }
      if (info.list.length >= 4000) break
    }
    return info
  },
  async _chaptersTx(id) {
    const list = []
    let total = null
    let title = '', author = ''
    const cover = 'https://y.gtimg.cn/music/photo_new/T002R500x500M000' + id + '.jpg'
    for (let begin = 0; begin < 4100; begin += 100) {
      const data = JSON.stringify({ comm: { ct: 24, cv: 0 }, albumSonglist: { method: 'GetAlbumSongList', module: 'music.musichallAlbum.AlbumSongList', param: { albumMid: id, begin, num: 100, order: 1 } } })
      const r = await this._get('https://u.y.qq.com/cgi-bin/musicu.fcg?data=' + encodeURIComponent(data), { 'User-Agent': this._ua, Referer: 'https://y.qq.com/' }, 30000)
      const j = this._j(r.data)
      const d = j.albumSonglist && j.albumSonglist.data
      if (!d || !Array.isArray(d.songList)) break
      if (total === null) total = Number(d.totalNum) || 0
      for (const s of d.songList) {
        const si = s.songInfo || {}
        if (!si.mid) continue
        list.push({ id: String(si.mid), name: this._clean(si.name || si.title || '') })
        if (!title && si.album) title = this._clean(si.album.name || '')
        if (!author && Array.isArray(si.singer) && si.singer.length) author = this._clean(si.singer[0].name || '')
      }
      if (list.length >= total || !d.songList.length) break
    }
    // QQ 有声专辑服务端顺序混乱（index_cd 全 0），章节名带集数 → 提取数值排序
    this._sortByChapterNo(list)
    return { title, cover, author, list }
  },
  // 从章节名提取集数排序：多数条目含「0001/第12集」类数字时按数值排；无数字条目沉底
  _sortByChapterNo(list) {
    const keyed = [], noKey = []
    for (const t of list) {
      const m = t.name.match(/\d{2,5}/)
      if (m) keyed.push({ t, k: parseInt(m[0], 10) })
      else noKey.push(t)
    }
    if (keyed.length < Math.max(3, list.length * 0.5)) return
    keyed.sort((a, b) => a.k - b.k)
    const sorted = keyed.map(x => x.t)
    list.length = 0
    list.push.apply(list, sorted.concat(noKey))
  },
  // 稳定分区：无集数字的条目（片花/预告/花絮）沉底，有序条目保持原相对顺序
  _sinkNoChapterNo(list) {
    const keyed = [], noKey = []
    for (const t of list) { if (/\d{2,5}/.test(t.name)) keyed.push(t); else noKey.push(t) }
    if (!keyed.length) return
    const sorted = keyed.concat(noKey)
    list.length = 0
    list.push.apply(list, sorted)
  },
  async _chaptersKg(id) {
    const list = []
    let total = null
    for (let page = 1; page <= 40; page++) {
      const r = await this._get('http://mobiles.kugou.com/api/v3/album/song?albumid=' + encodeURIComponent(id) + '&page=' + page + '&pagesize=100&plat=0&version=9108', { 'User-Agent': this._ua }, 30000)
      const j = this._j(r.data)
      const d = j.data || {}
      if (total === null) total = Number(d.total) || 0
      const info = Array.isArray(d.info) ? d.info : []
      for (const s of info) {
        if (!s.hash) continue
        let name = this._clean(s.filename || s.songname || '')
        const dash = name.indexOf(' - ')
        if (dash > 0) name = name.slice(dash + 3)
        list.push({ id: String(s.hash), name })
      }
      if (!info.length || list.length >= total) break
    }
    this._sinkNoChapterNo(list)
    return { title: '', cover: '', author: '', list }
  },

  async getChapters(bookId, page = 1, pageSize = 30) {
    const meta = this._unpack(bookId)
    const p = Math.max(1, Number(page) || 1)
    const size = Math.max(1, Math.min(Number(pageSize) || 30, 100))
    const key = String(bookId)
    let entry = this._chapterCache[key]
    if (!entry) {
      const info = { title: meta.n || '', cover: meta.c || '', author: meta.a || '', trackCount: 0, isFinished: false }
      let fetched = null
      if (meta.p === 'kw' && meta.t === 'al') fetched = await this._chaptersKwAlbum(meta.id)
      else if (meta.p === 'kw') fetched = await this._chaptersKwPl(meta.id)
      else if (meta.p === 'wy') fetched = await this._chaptersWy(meta.id)
      else if (meta.p === 'tx') fetched = await this._chaptersTx(meta.id)
      else if (meta.p === 'kg') fetched = await this._chaptersKg(meta.id)
      if (!fetched || !fetched.list.length) throw new Error('目录获取失败，该书可能已失效')
      if (fetched.title) info.title = fetched.title
      if (fetched.cover) info.cover = fetched.cover
      if (fetched.author) info.author = fetched.author
      info.trackCount = fetched.list.length
      entry = { info, list: fetched.list }
      this._chapterCache[key] = entry
    }
    const maxPage = Math.max(1, Math.ceil(entry.list.length / size))
    const safePage = Math.max(1, Math.min(p, maxPage))
    const start = (safePage - 1) * size
    return {
      info: entry.info,
      list: entry.list.slice(start, start + size).map((x, i) => ({ chapterId: meta.p + ':' + x.id, index: start + i + 1, name: x.name })),
      page: safePage, maxPage, hasMore: safePage < maxPage
    }
  },

  // ============ 解析层 ============
  // kw 特化：mobi.s 官方签名（含 p2p 重建）
  async _resKwMobi(id) {
    const r = await this._get('http://mobi.kuwo.cn/mobi.s?f=web&user=0&source=kwplayer_ar_8.5.5.0_apk_keluze.apk&type=convert_url_with_sign&rid=' + encodeURIComponent(id), { 'User-Agent': this._kwUa })
    const j = this._j(r.data)
    const d = (j && j.data) ? j.data : j
    if (d && d.url && /^https?:/.test(d.url)) return { url: d.url.replace(/\$(?=\S)/g, '='), headers: { 'User-Agent': this._kwUa } }
    if (d && d.p2p_audiosourceid) {
      const m = String(d.p2p_audiosourceid).match(/^(\d+?)(\d{4})trackmedialongM(\w+?)(mp3|m4a|flac)$/)
      if (m) {
        const [, hash, code, fname, ext] = m
        const bitrate = (d && d.bitrate) || 128
        return { url: 'http://car-er.kuwo.cn/' + hash + '/resource/3' + code + '/trackmedia/long/M' + fname + '.' + ext + '?bitrate=' + bitrate + '&format=' + ext + '&user=0', headers: { 'User-Agent': this._kwUa } }
      }
    }
    return null
  },
  // kw 特化：higequ 播放页
  async _resHige(id) {
    const r = await this._get('https://higequ.com/player/' + encodeURIComponent(id) + '/', { 'User-Agent': this._ua, Referer: 'https://higequ.com/' })
    const m = String(r.text || '').match(/let code = "([A-Za-z0-9+/=]+)"/)
    if (!m) return null
    let url = ''
    try { url = atob(m[1]) } catch (e) { return null }
    if (!/^https?:/.test(url)) return null
    return { url, headers: { 'User-Agent': this._ua } }
  },
  // kw 特化：antiserver（mp3 → aac）
  async _resAnti(id) {
    for (const fmt of ['mp3', 'aac']) {
      const r = await this._get('http://antiserver.kuwo.cn/anti.s?type=convert_url&rid=MUSIC_' + encodeURIComponent(id) + '&format=' + fmt + '&response=url', { 'User-Agent': this._kwUa, Referer: 'http://www.kuwo.cn/' })
      const body = String(r.text || '').trim()
      if (/^https?:/.test(body)) return { url: body, headers: { 'User-Agent': this._kwUa } }
      await this._sleep(400)
    }
    return null
  },
  // 全平台兜底：聆澜 → ikun → HYW
  async _resLx(plat, id) {
    try {
      const r = await this._get('https://source.shiqianjiang.cn/api/music/url?source=' + plat + '&songId=' + encodeURIComponent(id) + '&quality=128k', { 'User-Agent': this._lxUa, 'X-API-Key': this._llKey })
      const j = this._j(r.data)
      if (j && j.code === 200 && /^https?:/.test(j.url || '')) return { url: j.url, headers: { 'User-Agent': this._ua } }
    } catch (e) {}
    try {
      const r = await this._http({ url: 'https://c.wwwweb.top/music/url', method: 'POST', data: JSON.stringify({ source: plat, musicId: id, quality: '128k' }), headers: { 'Content-Type': 'application/json', 'User-Agent': this._lxUa, 'X-Api-Key': this._ikKey } })
      const j = this._j(r.data)
      if (j && j.code === 200 && /^https?:/.test(j.url || '')) return { url: j.url, headers: { 'User-Agent': this._ua } }
    } catch (e) {}
    try {
      const r = await this._get('http://103.79.184.97/api/music/url?source=' + plat + '&songId=' + encodeURIComponent(id) + '&quality=128k&key=' + this._hywKey, { 'User-Agent': this._lxUa })
      const j = this._j(r.data)
      if (j && j.code === 200 && /^https?:/.test(j.url || '')) return { url: j.url, headers: { 'User-Agent': this._ua } }
    } catch (e) {}
    return null
  },

  async getAudioUrl(chapterId) {
    const s = String(chapterId || '')
    const i = s.indexOf(':')
    if (i < 1) throw new Error('无效的章节 ID')
    const plat = s.slice(0, i), id = s.slice(i + 1)
    const hit = this._audioCache[s]
    if (hit && Date.now() - hit.at < 240000) return hit.value
    const chain = []
    if (plat === 'kw') chain.push(() => this._resKwMobi(id), () => this._resHige(id), () => this._resAnti(id))
    chain.push(() => this._resLx(plat, id))
    for (const fn of chain) {
      try {
        const v = await fn()
        if (v && v.url) { this._audioCache[s] = { value: v, at: Date.now() }; return v }
      } catch (e) {}
    }
    throw new Error('解析失败（已尝试 ' + chain.length + ' 条通道）')
  },

  // ============ 发现页 ============
  async discover() {
    const jobs = [
      ['网易·有声小说', () => this._searchWy('有声小说', 1)],
      ['网易·评书', () => this._searchWy('评书', 1)],
      ['QQ·有声剧', () => this._searchTx('有声剧', 1)],
      ['酷狗·有声书', () => this._searchKg('有声小说', 1)],
      ['酷我·玄幻', () => this._searchTs8('玄幻', 1)],
      ['酷我·都市', () => this._searchTs8('都市', 1)]
    ]
    const rs = await Promise.allSettled(jobs.map(x => x[1]()))
    const sections = []
    for (let i = 0; i < jobs.length; i++) {
      const r = rs[i]
      if (r.status === 'fulfilled' && Array.isArray(r.value) && r.value.length) {
        sections.push({ title: jobs[i][0], list: r.value.slice(0, 12).map(b => this._toBook(b)) })
      }
    }
    return { sections }
  }
})