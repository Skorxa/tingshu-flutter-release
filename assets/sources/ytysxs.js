// 雨听有声小说
// 来源: D:\test\tingshu\sources_ytysxs.jar 中 YtysxsSource.kt 的站点和选择器逻辑重写
// 站点: https://www.ytysxs.com  |  鉴权: 无  |  播放列表: AudioIgniter
({
  name: '雨听有声小说',
  id: 'ytysxs',
  version: 1,
  apiVersion: 1,
  _site: 'https://www.ytysxs.com',
  _ua: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36',
  _books: {},

  _request(url, headers) {
    const header = Object.assign({
      'User-Agent': this._ua,
      Accept: 'text/html,application/xhtml+xml,application/xml,application/json,*/*;q=0.8'
    }, headers || {})
    return new Promise((resolve, reject) => {
      uni.request({
        url,
        method: 'GET',
        header,
        timeout: 20000,
        success: r => {
          if (r.statusCode < 200 || r.statusCode >= 300) {
            return reject(new Error('HTTP ' + r.statusCode + ' | ' + url))
          }
          resolve(r.data)
        },
        fail: e => reject(new Error(e.errMsg || '网络失败'))
      })
    })
  },

  _abs(url, base) {
    url = this._decodeHtml(String(url || '').trim())
    if (!url) return ''
    if (url.startsWith('//')) return 'https:' + url
    if (/^https?:\/\//i.test(url)) return url
    if (url[0] === '/') return this._site + url
    const b = String(base || this._site + '/').replace(/[#?].*$/, '').replace(/\/[^/]*$/, '/')
    return b + url
  },

  _clean(text) {
    return this._decodeHtml(String(text || '')
      .replace(/<script[\s\S]*?<\/script>/gi, ' ')
      .replace(/<style[\s\S]*?<\/style>/gi, ' ')
      .replace(/<[^>]+>/g, ' ')
      .replace(/\s+/g, ' '))
      .trim()
  },

  _decodeHtml(text) {
    return String(text || '')
      .replace(/&#(\d+);/g, (_, n) => String.fromCharCode(parseInt(n, 10)))
      .replace(/&#x([0-9a-f]+);/gi, (_, n) => String.fromCharCode(parseInt(n, 16)))
      .replace(/&quot;/g, '"')
      .replace(/&#39;/g, "'")
      .replace(/&amp;/g, '&')
      .replace(/&lt;/g, '<')
      .replace(/&gt;/g, '>')
      .replace(/&nbsp;/g, ' ')
  },

  _attr(tag, name) {
    const re = new RegExp(name + "\\s*=\\s*(\"([^\"]*)\"|'([^']*)'|([^\\s>]+))", 'i')
    const m = String(tag || '').match(re)
    return m ? this._decodeHtml(m[2] || m[3] || m[4] || '') : ''
  },

  _firstMatch(html, re) {
    const m = String(html || '').match(re)
    return m ? (m[1] || '') : ''
  },

  _coverFromBlock(block, base) {
    const img = this._firstMatch(block, /<img\b[^>]*>/i)
    if (!img) return ''
    return this._abs(
      this._attr(img, 'data-src') ||
        this._attr(img, 'data-original') ||
        this._attr(img, 'data-lazy-src') ||
        this._attr(img, 'src'),
      base
    )
  },

  _titleFromBlock(block) {
    const titleAttr = this._firstMatch(block, /<a\b[^>]*\btitle\s*=\s*["']([^"']+)["'][^>]*>/i)
    if (titleAttr) return this._clean(titleAttr)
    const titleNode = this._firstMatch(block, /<(?:h1|h2|h3)[^>]*>([\s\S]*?)<\/(?:h1|h2|h3)>/i)
    if (titleNode) return this._clean(titleNode)
    const aText = this._firstMatch(block, /<a\b[^>]*>([\s\S]*?)<\/a>/i)
    return this._clean(aText)
  },

  _extractInfo(html, detailUrl, fallbackTitle) {
    const ogTitle = this._firstMatch(html, /<meta\b[^>]*(?:property|name)=["']og:title["'][^>]*content=["']([^"']+)["'][^>]*>/i)
    const h1 = this._firstMatch(html, /<h1\b[^>]*class=["'][^"']*entry-title[^"']*["'][^>]*>([\s\S]*?)<\/h1>/i) ||
      this._firstMatch(html, /<h1\b[^>]*>([\s\S]*?)<\/h1>/i)
    const title = this._clean(ogTitle || h1 || fallbackTitle || '')
      .replace(/有声小说.*$/, '')
      .trim()
    const ogImg = this._firstMatch(html, /<meta\b[^>]*(?:property|name)=["']og:image["'][^>]*content=["']([^"']+)["'][^>]*>/i)
    const imgTag = this._firstMatch(html, /(<img\b[^>]*(?:data-src|data-original|data-lazy-src|src)=["'][^"']*(?:img|upload|cover)[^"']*["'][^>]*>)/i)
    const cover = ogImg ? this._abs(ogImg, detailUrl) : this._coverFromBlock(imgTag, detailUrl)
    const introBlock = this._firstMatch(html, /<(?:div|section|article)\b[^>]*(?:class=["'][^"']*(?:archive-content|entry-content|post-excerpt|excerpt|single-content)[^"']*["'])[^>]*>([\s\S]*?)<\/(?:div|section|article)>/i)
    const intro = this._clean(introBlock).slice(0, 160)
    const artistText = this._clean(html)
    const artist = (artistText.match(/(?:播音|主播|演播|作者)\s*[:：]\s*([^\s，,。]+)/) || [])[1] || ''
    return { title, cover, author: artist, intro }
  },

  _parseBooks(html, base) {
    const books = []
    const seen = {}
    const add = (href, block) => {
      const url = this._abs(href, base)
      if (!/^https?:\/\/www\.ytysxs\.com\/\d+\.html(?:$|[?#])/i.test(url)) return
      if (seen[url]) return
      const title = this._titleFromBlock(block)
      if (!title) return
      seen[url] = true
      const cover = this._coverFromBlock(block, url)
      books.push({
        bookId: url,
        title,
        cover,
        author: '',
        intro: ''
      })
    }

    const articleRe = /<(article|div|li)\b[^>]*>(?=[\s\S]*?href=["'](?:https?:\/\/www\.ytysxs\.com)?\/\d+\.html["'])[\s\S]*?<\/\1>/gi
    let m
    while ((m = articleRe.exec(html)) !== null) {
      const block = m[0]
      const href = this._firstMatch(block, /<a\b[^>]*href=["']([^"']*\/\d+\.html[^"']*)["'][^>]*>/i)
      add(href, block)
      if (books.length >= 40) break
    }

    if (books.length === 0) {
      const linkRe = /<a\b[^>]*href=["']([^"']*\/\d+\.html[^"']*)["'][^>]*>([\s\S]*?)<\/a>/gi
      while ((m = linkRe.exec(html)) !== null) {
        add(m[1], m[0])
        if (books.length >= 40) break
      }
    }
    return books
  },

  _nextPage(html, base) {
    const next = this._firstMatch(html, /<a\b[^>]*(?:class=["'][^"']*next[^"']*["'][^>]*)?href=["']([^"']+)["'][^>]*>\s*(?:下一页|Next|»|&raquo;)[\s\S]*?<\/a>/i)
    return next ? this._abs(next, base) : ''
  },

  _searchUrl(keyword, page) {
    const key = encodeURIComponent(keyword)
    return page <= 1
      ? this._site + '/?s=' + key
      : this._site + '/page/' + page + '/?s=' + key
  },

  _directDetailUrl(keyword) {
    const value = String(keyword || '').trim()
    if (!value) return ''
    if (/^\d+$/.test(value)) return this._site + '/' + value + '.html'
    let url = value
    if (/^www\.ytysxs\.com\//i.test(url) || /^ytysxs\.com\//i.test(url)) {
      url = 'https://' + url
    }
    if (!/^https?:\/\//i.test(url)) return ''
    if (url.indexOf('ytysxs.com') < 0) return ''
    return /\/\d+\.html(?:$|[?#])/i.test(url) ? url : ''
  },

  async _bookFromDetail(detailUrl) {
    const html = await this._request(detailUrl, { Referer: this._site + '/' })
    const info = this._extractInfo(String(html), detailUrl, '')
    const book = {
      bookId: detailUrl,
      title: info.title || detailUrl.replace(/^.*\/(\d+)\.html.*$/, '$1'),
      cover: info.cover || '',
      author: info.author || '',
      intro: info.intro || ''
    }
    this._books[book.bookId] = book
    return book
  },

  _pagedUrl(root, page) {
    const base = String(root || this._site).replace(/\/+$/, '')
    if (page <= 1) return base + '/'
    if (base === this._site) return this._site + '/page/' + page + '/'
    return base + '/page/' + page + '/'
  },

  _searchCandidates(keyword, page) {
    const roots = [
      this._site,
      this._site + '/xianxia/',
      this._site + '/xuanhuan/',
      this._site + '/lishi/',
      this._site + '/yanqing/',
      this._site + '/dushi/',
      this._site + '/kehuan/',
      this._site + '/kbly/',
      this._site + '/tag/wanjie/'
    ]
    const urls = [this._searchUrl(keyword, page)]
    roots.forEach(root => urls.push(this._pagedUrl(root, page)))
    return urls.filter((u, i, arr) => arr.indexOf(u) === i)
  },

  _matchesKeyword(book, keyword) {
    const k = this._clean(keyword).toLowerCase()
    if (!k) return true
    const title = this._clean(book.title).toLowerCase()
    const intro = this._clean(book.intro).toLowerCase()
    return title.indexOf(k) >= 0 || intro.indexOf(k) >= 0
  },

  async search(keyword, page = 1, pageSize = 20) {
    if (page <= 1) {
      const directUrl = this._directDetailUrl(keyword)
      if (directUrl) {
        try {
          const book = await this._bookFromDetail(directUrl)
          return { list: [book], page: 1, maxPage: 1, hasMore: false }
        } catch (e) {
          // 直接 ID/URL 解析失败时继续走关键词候选搜索，方便用户输入混合关键词。
        }
      }
    }
    const found = {}
    let captchaCount = 0
    let lastError = ''
    const candidates = this._searchCandidates(keyword, Math.max(1, page))
    for (const url of candidates) {
      try {
        const html = await this._request(url, { Referer: this._site + '/' })
        if (/<(?:div|form)[^>]*(?:be-search-captcha|bec-captcha)/i.test(String(html))) {
          captchaCount++
          continue
        }
        this._parseBooks(String(html), url)
          .filter(book => this._matchesKeyword(book, keyword))
          .forEach(book => {
            found[book.bookId] = book
          })
        if (Object.keys(found).length >= pageSize) break
      } catch (e) {
        lastError = e.message || String(e)
      }
    }
    const list = Object.keys(found).map(key => found[key]).slice(0, pageSize)
    list.forEach(book => { this._books[book.bookId] = book })
    if (list.length === 0 && captchaCount === candidates.length) {
      throw new Error('所有候选页都返回搜索验证码')
    }
    if (list.length === 0 && lastError) {
      throw new Error('搜索候选页无结果，最后错误: ' + lastError)
    }
    return {
      list,
      page,
      maxPage: list.length >= pageSize ? page + 1 : page,
      hasMore: list.length >= pageSize
    }
  },

  _playlistUrls(html, detailUrl) {
    const urls = []
    const rootRe = /<[^>]*class=["'][^"']*audioigniter-root[^"']*["'][^>]*>/gi
    let m
    while ((m = rootRe.exec(html)) !== null) {
      const tag = m[0]
      const tracksUrl = this._attr(tag, 'data-tracks-url')
      if (tracksUrl) urls.push(this._abs(tracksUrl, detailUrl))
      const playlistId = this._attr(tag, 'data-playlist-id') ||
        this._attr(tag, 'data-id') ||
        this._attr(tag, 'id').replace(/\D+/g, '')
      if (playlistId) urls.push(this._site + '/?audioigniter_playlist_id=' + playlistId)
    }
    const idRe = /audioigniter_playlist_id[=\\\/'": ]+(\d+)/gi
    while ((m = idRe.exec(html)) !== null) {
      urls.push(this._site + '/?audioigniter_playlist_id=' + m[1])
    }
    return urls.filter((u, i, arr) => u && arr.indexOf(u) === i)
  },

  _tracksFromJson(raw) {
    let data = raw
    if (typeof data === 'string') {
      try { data = JSON.parse(data) } catch (e) { return [] }
    }
    if (Array.isArray(data)) return data
    if (Array.isArray(data.tracks)) return data.tracks
    if (Array.isArray(data.data)) return data.data
    if (data && data.data && Array.isArray(data.data.tracks)) return data.data.tracks
    return []
  },

  async _loadTracks(html, detailUrl) {
    const urls = this._playlistUrls(String(html), detailUrl)
    let lastError = ''
    for (const url of urls) {
      try {
        const raw = await this._request(url, {
          Referer: detailUrl,
          Accept: 'application/json,text/plain,*/*'
        })
        const tracks = this._tracksFromJson(raw)
        if (tracks.length) return tracks
      } catch (e) {
        lastError = e.message || String(e)
      }
    }
    if (lastError) throw new Error('播放列表解析失败: ' + lastError)
    throw new Error('详情页未找到 AudioIgniter 播放列表')
  },

  _audioOf(track) {
    return String(track.audio || track.audioUrl || track.url || track.src || track.file || '').trim()
  },

  _trackTitle(track, index) {
    return this._clean(track.title || track.name || track.subtitle || ('第' + index + '集'))
  },

  async getChapters(bookId, page = 1, pageSize = 30) {
    const detailUrl = this._abs(bookId, this._site + '/')
    const html = await this._request(detailUrl, { Referer: this._site + '/' })
    const cached = this._books[bookId] || this._books[detailUrl] || {}
    const info = this._extractInfo(String(html), detailUrl, cached.title)
    const tracks = await this._loadTracks(String(html), detailUrl)
    const maxPage = Math.max(1, Math.ceil(tracks.length / pageSize))
    const safePage = Math.max(1, Math.min(page, maxPage))
    const start = (safePage - 1) * pageSize
    const rows = tracks.slice(start, start + pageSize)
    return {
      info: {
        title: info.title || cached.title || '',
        cover: info.cover || cached.cover || '',
        author: info.author || cached.author || '',
        trackCount: tracks.length,
        isFinished: false
      },
      list: rows.map((track, i) => {
        const idx = start + i + 1
        const audio = this._abs(this._audioOf(track), detailUrl)
        return {
          chapterId: JSON.stringify({
            url: audio,
            referer: detailUrl,
            name: this._trackTitle(track, idx)
          }),
          index: idx,
          name: this._trackTitle(track, idx)
        }
      }).filter(chapter => chapter.chapterId.indexOf('"url":""') < 0),
      page: safePage,
      maxPage,
      hasMore: safePage < maxPage
    }
  },

  async getAudioUrl(chapterId) {
    let data
    try { data = JSON.parse(chapterId) } catch (e) {
      data = { url: String(chapterId || '') }
    }
    if (!data.url || !/^https?:\/\//i.test(data.url)) {
      throw new Error('章节没有可播放音频地址: ' + String(chapterId).slice(0, 120))
    }
    return {
      url: data.url,
      headers: {
        Referer: data.referer || this._site + '/',
        'User-Agent': this._ua,
        Accept: 'audio/*,*/*;q=0.8'
      }
    }
  }
})
