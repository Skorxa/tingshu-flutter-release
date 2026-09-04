// 北极听书（酷我代理）
// 接口：tingshu.kuwo.cn / search.kuwo.cn / mobi.kuwo.cn  |  鉴权：无
({
  name: '北极听书',
  id: 'beiji-kuwo',
  apiVersion: 1,
  _ua: 'okhttp/4.9.0',
  _albumMeta: {},

  _get(url, params) {
    const qs = Object.entries(params).map(([k, v]) => k + '=' + encodeURIComponent(v)).join('&')
    return new Promise((resolve, reject) => {
      uni.request({
        url: url + '?' + qs,
        header: { 'User-Agent': this._ua },
        timeout: 15000,
        success: r => {
          if (r.statusCode !== 200) return reject(new Error('HTTP ' + r.statusCode))
          let d = r.data
          // search.kuwo.cn/r.s 返回 Python dict 格式（单引号），非标准 JSON
          if (typeof d === 'string') {
            try { d = JSON.parse(d) } catch(e) {
              try {
                // eslint-disable-next-line no-new-func
                d = new Function('return (' + d + ')')()
              } catch(e2) {}
            }
          }
          resolve(d)
        },
        fail: e => reject(new Error(e.errMsg || '网络失败'))
      })
    })
  },

  _cleanText(text) {
    return String(text || '')
      .replace(/&nbsp;/g, ' ')
      .replace(/&amp;/g, '&')
      .replace(/&lt;/g, '<')
      .replace(/&gt;/g, '>')
      .trim()
  },

  // albuminfo 无 img500 字段;'img' 键重复会被解析覆盖成空;pic / web_albumpic_short
  // 是形如 '120/s4s66/11/xxx.png' 的相对片段。这里拼成 240 尺寸完整 URL。
  _albumCover(res) {
    const short = res.web_albumpic_short || res.pic || ''
    if (short) {
      if (/^https?:\/\//i.test(short)) return short
      return 'http://img1.sycdn.kuwo.cn/star/albumcover/' + short.replace(/^\d+\//, '240/')
    }
    return res.pic120 || res.hts_img || ''
  },

  async _getAlbumMeta(bookId, pageSize) {
    const key = bookId + '@' + pageSize
    if (this._albumMeta[key]) return this._albumMeta[key]
    const res = await this._get('http://search.kuwo.cn/r.s', {
      stype: 'albuminfo', loginUid: '0', loginSid: 'null',
      prod: 'kwplayer_ar_9.1.7.0', bkprod: 'kwbook_ar_9.1.7.0',
      source: 'kwplayer_ar_9.1.7.0_t18.apk', bksource: 'kwbook_ar_9.1.7.0_t18.apk',
      corp: 'kuwo', albumid: bookId,
      pn: '0', rn: '1'
    })
    const total = parseInt(res.songnum || res.total || 0)
    const maxPage = Math.ceil(total / pageSize) || 1
    const firstPageCount = total % pageSize || pageSize
    const meta = {
      total,
      maxPage,
      firstPageCount,
      info: {
        title:      this._cleanText(res.albumname || res.name),
        cover:      this._albumCover(res),
        author:     this._cleanText(res.artist),
        trackCount: total,
        isFinished: res.finished === '1' || res.finished === 1 || res.finished === true
      }
    }
    this._albumMeta[key] = meta
    return meta
  },

  async search(keyword, page = 1, pageSize = 20) {
    const res = await this._get('http://tingshu.kuwo.cn/tingshu/api/search/Search', {
      rn: pageSize, type: 'album', version: '8.5.6.1', wd: keyword, pn: page - 1
    })
    if (res?.code && res.code !== 200) {
      throw new Error(res.msg || ('酷我搜索失败: ' + res.code))
    }
    const items = res?.data?.data || []
    const total = parseInt(res?.data?.total || '0')
    const maxPage = Math.ceil(total / pageSize) || 1
    return {
      list: items.map(item => ({
        bookId:  item.albumId,
        title:   item.albumName  || '',
        cover:   item.coverImg   || '',
        author:  item.artistName || '',
        intro:   (item.songTotal || 0) + '集'
      })),
      page, maxPage, hasMore: page < maxPage
    }
  },

  async getChapters(bookId, page = 1, pageSize = 30) {
    // 酷我目录接口按“最新在前”返回。这里把 App 的正序页码映射到酷我的倒序页码。
    const meta = await this._getAlbumMeta(bookId, pageSize)
    const safePage = Math.max(1, Math.min(page, meta.maxPage))
    const pn = meta.maxPage - safePage
    const res = await this._get('http://search.kuwo.cn/r.s', {
      stype: 'albuminfo', loginUid: '0', loginSid: 'null',
      prod: 'kwplayer_ar_9.1.7.0', bkprod: 'kwbook_ar_9.1.7.0',
      source: 'kwplayer_ar_9.1.7.0_t18.apk', bksource: 'kwbook_ar_9.1.7.0_t18.apk',
      corp: 'kuwo', albumid: bookId,
      pn: String(pn), rn: String(pageSize)
    })
    const tracks = Array.isArray(res.musiclist) ? res.musiclist : []
    if (tracks.length === 0) {
      const keys = typeof res === 'object' ? Object.keys(res) : ['非对象:' + typeof res]
      const preview = JSON.stringify(res).slice(0, 300)
      throw new Error('字段:' + keys.join(',') + ' | 内容:' + preview)
    }
    tracks.reverse()
    const total = meta.total || parseInt(res.songnum || tracks.length)
    const startIndex = safePage === 1
      ? 1
      : meta.firstPageCount + (safePage - 2) * pageSize + 1
    return {
      info: {
        title:      meta.info.title || this._cleanText(res.albumname || res.name),
        cover:      meta.info.cover || this._albumCover(res),
        author:     meta.info.author || this._cleanText(res.artist),
        trackCount: total,
        isFinished: meta.info.isFinished
      },
      list: tracks.map((item, i) => ({
        chapterId: item.musicrid || item.rid || '',
        index:     startIndex + i,
        name:      this._cleanText(item.name || item.songname)
      })),
      page: safePage, maxPage: meta.maxPage,
      hasMore: safePage < meta.maxPage
    }
  },

  // 兜底解析：higequ 播放页（任意酷我 rid → let code Base64 直链）
  async _resolveViaHigequ(rid) {
    const html = await new Promise((resolve, reject) => {
      uni.request({
        url: 'https://higequ.com/player/' + rid + '/',
        header: { 'User-Agent': 'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36', Referer: 'https://higequ.com/' },
        timeout: 15000,
        success: r => resolve(String(r.data || '')),
        fail: e => reject(new Error(e.errMsg || '网络失败'))
      })
    })
    const m = html.match(/let code = "([A-Za-z0-9+/=]+)"/)
    if (!m) throw new Error('higequ 无音频数据')
    const url = atob(m[1])
    if (!/^https?:\/\//i.test(url)) throw new Error('higequ 直链无效')
    return url
  },

  // 终极兜底：LX 社区解析 API（聆澜 GET → ikun POST），按 kw 平台解析任意酷我 rid
  async _resolveViaLx(rid) {
    const lxUa = 'lx-music-request/2.0.0'
    try {
      const r1 = await new Promise((resolve, reject) => {
        uni.request({
          url: 'https://source.shiqianjiang.cn/api/music/url?source=kw&songId=' + rid + '&quality=128k',
          header: { 'User-Agent': lxUa, 'X-API-Key': 'CERU_KEY-31C0DB0B-2DFF-42EF-A2DB-47863E658840' },
          timeout: 15000,
          success: r => resolve(r.data),
          fail: e => reject(new Error(e.errMsg || '网络失败'))
        })
      })
      if (r1 && r1.code === 200 && /^https?:\/\//i.test(r1.url || '')) return r1.url
    } catch (e) {}
    try {
      const r2 = await new Promise((resolve, reject) => {
        uni.request({
          url: 'https://c.wwwweb.top/music/url',
          method: 'POST',
          header: { 'Content-Type': 'application/json', 'User-Agent': lxUa, 'X-Api-Key': 'IKM-P18200001-AyKQrBcgmEyPDpRy-0t' },
          data: { source: 'kw', musicId: rid, quality: '128k' },
          timeout: 15000,
          success: r => resolve(r.data),
          fail: e => reject(new Error(e.errMsg || '网络失败'))
        })
      })
      if (r2 && r2.code === 200 && /^https?:\/\//i.test(r2.url || '')) return r2.url
    } catch (e) {}
    throw new Error('LX 解析通道均不可用')
  },

  async getAudioUrl(chapterId) {
    const rid = String(chapterId).replace(/^MUSIC_/i, '')
    let primaryErr = null
    try {
      const res = await this._get('http://mobi.kuwo.cn/mobi.s', {
        f: 'web', user: '0',
        source: 'kwplayer_ar_8.5.5.0_apk_keluze.apk',
        type: 'convert_url_with_sign', rid
      })
      const d = (res && res.data) ? res.data : res
      if (d && d.url && String(d.url).startsWith('http')) {
        return String(d.url).replace(/\$(?=\S)/g, '=')
      }
      const p2p = d && d.p2p_audiosourceid
      if (p2p) {
        const m = String(p2p).match(/^(\d+?)(\d{4})trackmedialongM(\w+?)(mp3|m4a|flac)$/)
        if (m) {
          const [, hash, code, fname, ext] = m
          const bitrate = (d && d.bitrate) || 128
          return `http://car-er.kuwo.cn/${hash}/resource/3${code}/trackmedia/long/M${fname}.${ext}?bitrate=${bitrate}&format=${ext}&user=0`
        }
      }
      if (typeof res === 'string' && res.trim().startsWith('http')) {
        return res.trim().replace(/\$(?=\S)/g, '=')
      }
      primaryErr = new Error('无法解析音频链接，p2p=' + p2p + ' res=' + JSON.stringify(res).slice(0, 100))
    } catch (e) {
      primaryErr = e
    }
    // 酷我官方通道失败 → higequ 播放页兜底
    try {
      return await this._resolveViaHigequ(rid)
    } catch (e2) {}
    // 再失败 → LX 社区 API 兜底
    try {
      return await this._resolveViaLx(rid)
    } catch (e3) {}
    throw primaryErr || new Error('无法解析音频链接')
  }
})
