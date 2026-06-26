// tingshu_json: Ting13JsonSource
({
  name: '13听书网',
  id: 'tingshu-json-ting13',
  apiVersion: 1,
  _site: 'https://www.ting13.cc',
  _account: 'beijizb@gmail.com',
  _password: '0N9kYlg78EaS5q',
  _ua: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36',
  _spIn: 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789',
  _spOut: 'O91s3EHJmfTvuYzwZ2eA0qW7CjQLhcxb8U6SKiNMyrdtIlPF14gGkaFVo5XBpD',
  _cookies: {},

  _cookieHeader() { return Object.keys(this._cookies).map(k => k + '=' + this._cookies[k]).join('; ') },
  _remember(header) {
    const raw = header && (header['set-cookie'] || header['Set-Cookie'])
    const list = Array.isArray(raw) ? raw : (raw ? [String(raw)] : [])
    for (const line of list) {
      const pair = String(line).split(';')[0]
      const idx = pair.indexOf('=')
      if (idx > 0) this._cookies[pair.slice(0, idx).trim()] = pair.slice(idx + 1).trim()
    }
  },
  _request(url, method, body, referer, extraHeaders) {
    const headers = Object.assign({ 'User-Agent': this._ua, Referer: referer || this._site + '/', Origin: this._site }, extraHeaders || {})
    const cookie = this._cookieHeader()
    if (cookie) headers.Cookie = cookie
    if (method === 'POST' && !headers['Content-Type']) headers['Content-Type'] = 'application/x-www-form-urlencoded'
    return new Promise((resolve, reject) => {
      uni.request({ url, method: method || 'GET', data: body || null, header: headers, timeout: 30000,
        success: r => {
          this._remember(r.header)
          if (r.statusCode < 200 || r.statusCode >= 300) return reject(new Error('HTTP ' + r.statusCode + ' | ' + url))
          const html = String(r.data || '')
          const pass = this._pass51(html)
          if (pass) Object.assign(this._cookies, pass)
          resolve(html)
        },
        fail: e => reject(new Error(e.errMsg || '网络失败')) })
    })
  },
  _pass51(html) {
    const m = String(html).match(/var\s+reversed\s*=\s*"([\s\S]*?)";/i)
    if (!m) return null
    try {
      const code = atob(m[1].replace(/\s+/g, '').split('').reverse().join(''))
      const token = (code.match(/var\s+token\s*=\s*'([^']*)'/i) || [])[1] || ''
      const retry = (code.match(/var\s+retry\s*=\s*([0-9]+)/i) || [])[1] || '1'
      if (!token) return null
      return { '__51guid__': token, '__51refresh__guid': retry, '__51refresh_guid': retry }
    } catch (e) { return null }
  },
  _isLoggedIn() { return !!(this._cookies.PTCMS_token || this._cookies.PTCMS_userid) },
  async _login() {
    if (this._isLoggedIn()) return true
    await this._request(this._site + '/user/public/login.html', 'GET', null, this._site + '/')
    const token = String(Date.now()) + String(Math.random()).slice(2, 10)
    await this._request(this._site + '/user/public/store_token.html', 'POST', JSON.stringify({ token }), this._site + '/user/public/login.html', { 'Content-Type': 'application/json' })
    const body = 'username=' + encodeURIComponent(this._account) + '&password=' + encodeURIComponent(this._password) + '&verificationToken=' + encodeURIComponent(token) + '&name=1'
    const html = await this._request(this._site + '/user/public/login.html', 'POST', body, this._site + '/user/public/login.html')
    return this._isLoggedIn() || /登录成功|用户中心|退出登录/.test(html)
  },
  _decode(s) { return String(s || '').replace(/&#(\d+);/g, (_, n) => String.fromCharCode(parseInt(n, 10))).replace(/&nbsp;/g, ' ').replace(/&amp;/g, '&').replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&lt;/g, '<').replace(/&gt;/g, '>') },
  _clean(s) { return this._decode(String(s || '').replace(/<script[\s\S]*?<\/script>/gi, ' ').replace(/<style[\s\S]*?<\/style>/gi, ' ').replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ')).trim() },
  _attr(tag, name) { const m = String(tag || '').match(new RegExp(name + "\\s*=\\s*(\"([^\"]*)\"|'([^']*)'|([^\\s>]+))", 'i')); return m ? this._decode(m[2] || m[3] || m[4] || '') : '' },
  _abs(url, base) { url = this._decode(String(url || '').trim()); if (!url) return ''; if (/^https?:\/\//i.test(url)) return url; if (url.startsWith('//')) return 'https:' + url; if (url[0] === '/') return this._site + url; return String(base || this._site + '/').replace(/[#?].*$/, '').replace(/\/[^/]*$/, '/') + url },
  _first(s, re) { const m = String(s || '').match(re); return m ? (m[1] || '') : '' },
  _sp(sc) {
    let out = ''
    for (const ch of String(sc || '')) {
      const idx = this._spIn.indexOf(ch)
      const mid = idx >= 0 ? this._spOut[idx] : ch
      out += this._spIn[Math.floor(Math.random() * this._spIn.length)] + mid + this._spIn[Math.floor(Math.random() * this._spIn.length)]
    }
    return out
  },
  _parseBooks(html, base) {
    const list = [], seen = {}
    const re = /<a\b[^>]*href=["']([^"']*youshengxiaoshuo\/[^"']+)["'][^>]*>[\s\S]*?<\/a>/gi
    let m
    while ((m = re.exec(html)) !== null) {
      const href = this._abs(m[1], base)
      if (seen[href]) continue
      const block = html.slice(Math.max(0, m.index - 700), Math.min(html.length, m.index + m[0].length + 900))
      const img = this._first(block, /<img\b[^>]*>/i)
      const title = this._clean(this._attr(img, 'alt') || this._attr(m[0], 'title') || m[0]).replace(/有声小说.*$/, '').trim()
      if (!title) continue
      seen[href] = true
      list.push({ bookId: href, title, cover: this._abs(this._attr(img, 'data-original') || this._attr(img, 'src'), base), author: this._clean(this._first(block, /(?:演播|主播)[：:\s]*<\/?[^>]*>\s*([^<]+)/i)), intro: this._clean(this._first(block, /class=["'][^"']*(?:list-book-des|rm-js)[^"']*["'][^>]*>([\s\S]*?)<\/[^>]+>/i)) })
    }
    return list
  },
  _tocUrl(html) {
    const link = this._first(html, /href=["']([^"']*\/tingdirs\/[^"']+)["']/i)
    if (!link) return ''
    let clean = this._abs(link, this._site).replace(/[?&]page=\d+/g, '').replace(/[?&]sort=(asc|desc)/g, '').replace(/[?&]$/, '')
    return clean + (clean.indexOf('?') >= 0 ? '&' : '?') + 'page=1&sort=asc'
  },

  async search(keyword, page = 1, pageSize = 20) {
    await this._login()
    const html = await this._request(this._site + '/novelsearch/search/result.html', 'POST', 'searchword=' + encodeURIComponent(keyword), this._site + '/')
    return { list: this._parseBooks(html, this._site).slice(0, pageSize), page, maxPage: 1, hasMore: false }
  },
  async getChapters(bookId, page = 1, pageSize = 30) {
    await this._login()
    const html = await this._request(bookId, 'GET', null, this._site + '/')
    const toc = this._tocUrl(html)
    const url = toc ? toc.replace(/page=\d+/, 'page=' + page) : bookId
    const tocHtml = toc ? await this._request(url, 'GET', null, bookId) : html
    const all = []
    const re = /<a\b[^>]*href=["']([^"']*(?:\/youshengxiaoshuo\/|\/play\/|\/ting\/)[^"']+)["'][^>]*>([\s\S]*?)<\/a>/gi
    let m
    while ((m = re.exec(tocHtml)) !== null) {
      const name = this._clean(m[2]).replace(/^正在播放[:：]\s*/, '').replace(/(?:在线收听|在线播放)[\s\S]*$/, '').replace(/[_\s-]*13听书网[\s\S]*$/, '').trim()
      if (name) all.push({ chapterId: this._abs(m[1], url), name })
    }
    return { info: { title: this._clean(this._first(html, /<h1[^>]*>([\s\S]*?)<\/h1>/i)).replace(/有声小说/g, ''), cover: this._abs(this._first(html, /<img\b[^>]*(?:data-original|src)=["']([^"']+)["'][^>]*>/i), bookId), author: '', trackCount: 0, isFinished: true }, list: all.slice(0, pageSize).map((x, i) => ({ chapterId: x.chapterId, index: (page - 1) * pageSize + i + 1, name: x.name })), page, maxPage: all.length >= pageSize ? page + 1 : page, hasMore: all.length >= pageSize }
  },
  async getAudioUrl(chapterId) {
    await this._login()
    const raw = await this._request(chapterId, 'GET', null, this._site + '/')
    const nid = this._first(raw, /<meta[^>]+name=["']_b["'][^>]+content=["']([^"']+)["']/i)
    const cid = this._first(raw, /<meta[^>]+name=["']_p["'][^>]+content=["']([^"']+)["']/i)
    const sc = this._first(raw, /<meta[^>]+name=["']_c["'][^>]+content=["']([^"']+)["']/i)
    if (!nid || !cid || !sc) throw new Error('未找到播放参数')
    const body = 'nid=' + encodeURIComponent(nid) + '&cid=' + encodeURIComponent(cid) + '&sort=read'
    const jsonText = await this._request(this._site + '/api/mapi/play', 'POST', body, chapterId, { Accept: 'application/json, text/javascript, */*; q=0.01', 'X-Requested-With': 'XMLHttpRequest', sc, sp: this._sp(sc) })
    const json = JSON.parse(jsonText)
    if (Number(json.status || 200) === 200 && json.url) return json.url
    throw new Error('播放接口未返回音频')
  }
})
