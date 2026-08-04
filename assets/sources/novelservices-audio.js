// 账号凭据由 App 的音源“登录”配置注入，本文件不内置任何账号或 Token。
({
  id: 'novelservices-audio',
  name: '速听聚合',
  apiVersion: 1,

  configFields: [
    {
      key: 'accounts',
      label: '账号池',
      type: 'account_list',
      hint: '账号数量不限，可随时添加或删除',
      required: true
    },
    {
      key: 'platforms',
      label: '搜索平台',
      type: 'text',
      hint: '留空搜索全部；可填 fanqie,qimao,ximalaya',
      required: false
    },
    {
      key: 'baseUrl',
      label: '接口地址',
      type: 'text',
      hint: '留空使用抓包中的默认地址',
      required: false
    }
  ],

  _defaultBaseUrl: 'http://110.42.61.178:2095',
  _userAgent:
    'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 ' +
    '(KHTML, like Gecko) Chrome/134.0.0.0 Mobile Safari/537.36',
  _accountStates: {},
  _roundRobinCursor: 0,
  _platformDefinitions: {
    fanqie: { id: 'fanqie', name: '番茄小说', tabType: 2 },
    qimao: { id: 'qimao', name: '七猫', tabType: 1 },
    ximalaya: { id: 'ximalaya', name: '喜马拉雅', tabType: 2 }
  },

  _config() {
    return this.config || uni.getStorageSync('sourceConfig') || {}
  },

  _baseUrl() {
    const configured = String(this._config().baseUrl || '').trim()
    return (configured || this._defaultBaseUrl).replace(/\/+$/, '')
  },

  _body(response) {
    let body = response ? response.data : null
    if (typeof body === 'string') {
      try {
        body = JSON.parse(body)
      } catch (_) {
        throw new Error('站点返回了无法解析的数据')
      }
    }
    return body
  },

  _message(body, fallback) {
    if (body && typeof body === 'object') {
      return String(body.msg || body.message || body.error || fallback)
    }
    return fallback
  },

  _request(options) {
    return new Promise((resolve, reject) => {
      uni.request({
        url: options.url,
        method: options.method || 'GET',
        data: options.data,
        header: options.header || {},
        timeout: options.timeout || 20000,
        success: resolve,
        fail: error => reject(
          new Error((error && error.errMsg) || '网络请求失败')
        )
      })
    })
  },

  _fingerprint(value) {
    let hash = 2166136261
    const text = String(value || '')
    for (let i = 0; i < text.length; i++) {
      hash ^= text.charCodeAt(i)
      hash = Math.imul(hash, 16777619)
    }
    return (hash >>> 0).toString(16)
  },

  _accountPool() {
    const cfg = this._config()
    let raw = cfg.accounts
    if (typeof raw === 'string') {
      if (raw.trim()) {
        try {
          raw = JSON.parse(raw)
        } catch (_) {
          throw new Error('账号池配置格式无效')
        }
      } else {
        raw = []
      }
    }
    const entries = Array.isArray(raw)
      ? raw.slice()
      : (raw && typeof raw === 'object' && Array.isArray(raw.list)
          ? raw.list.slice()
          : [])

    // 兼容早期的 account1/password1 等本地配置，不限制编号上限。
    if (!entries.length) {
      const indexes = []
      const keys = Object.keys(cfg)
      for (let i = 0; i < keys.length; i++) {
        const match = /^(?:account|email)(\d+)$/.exec(keys[i])
        if (match && indexes.indexOf(Number(match[1])) < 0) {
          indexes.push(Number(match[1]))
        }
      }
      indexes.sort((a, b) => a - b)
      for (let i = 0; i < indexes.length; i++) {
        const index = indexes[i]
        entries.push({
          name: '账号 ' + index,
          email: cfg['account' + index] || cfg['email' + index],
          password: cfg['password' + index],
          token: cfg['token' + index]
        })
      }
      if (!entries.length && (cfg.account || cfg.password || cfg.token)) {
        entries.push({ email: cfg.account, password: cfg.password, token: cfg.token })
      }
    }

    const result = []
    const seen = {}
    const incomplete = []
    for (let i = 0; i < entries.length; i++) {
      const item = typeof entries[i] === 'string'
        ? { token: entries[i] }
        : (entries[i] || {})
      const email = String(item.email || item.account || item.username || '').trim()
      const password = String(item.password || '').trim()
      const token = String(item.token || item.accessToken || '')
        .trim()
        .replace(/^Bearer\s+/i, '')
      if (!email && !password && !token) continue
      if (!token && (!email || !password)) {
        incomplete.push(String(item.name || item.label || '账号 ' + (i + 1)))
        continue
      }
      const identity = email.toLowerCase() || 'token:' + this._fingerprint(token)
      if (seen[identity]) continue
      seen[identity] = true
      result.push({
        key: 'account-' + i + '-' + this._fingerprint(identity + password),
        label: String(item.name || item.label || '账号' + (i + 1)),
        email: email,
        password: password,
        token: token
      })
    }
    if (incomplete.length) {
      throw new Error(incomplete.join('、') + '的邮箱和密码需要同时填写')
    }
    if (!result.length) {
      throw new Error('请长按音源选择登录，在账号池中至少添加一个账号')
    }
    return result
  },

  _stateOf(account) {
    let state = this._accountStates[account.key]
    if (!state) {
      state = {
        sessionToken: '',
        loginPromise: null,
        cooldownUntil: 0,
        inFlight: 0,
        requests: 0,
        failures: 0
      }
      this._accountStates[account.key] = state
    }
    return state
  },

  _retryError(message, cooldownMs, statusCode) {
    const error = new Error(message)
    error.retryable = true
    error.cooldownMs = cooldownMs || 30000
    if (statusCode) error.statusCode = statusCode
    return error
  },

  _retryAfterMs(response, fallback) {
    const headers = (response && (response.header || response.headers)) || {}
    let value = headers['retry-after'] || headers['Retry-After'] || ''
    if (Array.isArray(value)) value = value[0]
    const seconds = Number(value)
    if (isFinite(seconds) && seconds > 0) {
      return Math.min(10 * 60 * 1000, Math.max(30000, seconds * 1000))
    }
    return fallback
  },

  _isQuotaMessage(message) {
    return /(quota|额度|配额|次数|余额|上限|limit|insufficient|exceed)/i.test(
      String(message || '')
    )
  },

  async _login(account, forceAccountLogin) {
    const state = this._stateOf(account)
    if (state.sessionToken) return state.sessionToken
    if (!forceAccountLogin && account.token) return account.token
    if (state.loginPromise) return state.loginPromise
    if (!account.email || !account.password) {
      throw this._retryError(
        account.label + '没有可用的登录凭据',
        30 * 60 * 1000
      )
    }

    const loginPromise = (async () => {
      let response
      let body
      try {
        response = await this._request({
          url: this._baseUrl() + '/api/v1/auth/login',
          method: 'POST',
          data: { email: account.email, password: account.password },
          header: {
            Accept: 'application/json',
            'Content-Type': 'application/json',
            Origin: this._baseUrl(),
            'User-Agent': this._userAgent
          }
        })
        body = this._body(response)
      } catch (_) {
        throw this._retryError(account.label + '登录网络失败', 30000)
      }
      const status = Number(response.statusCode || 0)
      if (status === 429) {
        throw this._retryError(
          account.label + '登录被限流',
          this._retryAfterMs(response, 60000),
          status
        )
      }
      if (status < 200 || status >= 300) {
        throw this._retryError(
          account.label + '登录失败',
          status === 401 || status === 403 ? 10 * 60 * 1000 : 30000,
          status
        )
      }
      if (!body || Number(body.code) !== 0 || !body.data || !body.data.token) {
        throw this._retryError(
          account.label + '登录失败：账号凭据无效',
          10 * 60 * 1000
        )
      }
      state.sessionToken = String(body.data.token)
      return state.sessionToken
    })()
    state.loginPromise = loginPromise
    try {
      return await loginPromise
    } finally {
      if (state.loginPromise === loginPromise) state.loginPromise = null
    }
  },

  _chooseAccount(accounts, attempted) {
    const now = Date.now()
    for (let pass = 0; pass < 2; pass++) {
      for (let offset = 0; offset < accounts.length; offset++) {
        const index = (this._roundRobinCursor + offset) % accounts.length
        const account = accounts[index]
        const state = this._stateOf(account)
        if (attempted[account.key] || state.cooldownUntil > now) continue
        if (pass === 0 && state.inFlight > 0) continue
        this._roundRobinCursor = (index + 1) % accounts.length
        return account
      }
    }
    return null
  },

  async _apiWithAccount(account, path, options, authRetried) {
    options = options || {}
    let token
    try {
      token = await this._login(account, false)
    } catch (error) {
      throw error && error.retryable
        ? error
        : this._retryError(account.label + '登录失败', 30000)
    }

    let response
    let body
    try {
      response = await this._request({
        url: this._baseUrl() + path,
        method: options.method || 'GET',
        data: options.data,
        header: {
          Accept: 'application/json',
          'Content-Type': 'application/json',
          Authorization: 'Bearer ' + token,
          Origin: this._baseUrl(),
          'User-Agent': this._userAgent
        }
      })
      body = this._body(response)
    } catch (_) {
      throw this._retryError(account.label + '请求网络失败', 30000)
    }

    const status = Number(response.statusCode || 0)
    if (status === 401) {
      const state = this._stateOf(account)
      state.sessionToken = ''
      if (!authRetried && account.email && account.password) {
        await this._login(account, true)
        return this._apiWithAccount(account, path, options, true)
      }
      throw this._retryError(account.label + '登录状态失效', 10 * 60 * 1000, status)
    }
    if (status === 403) {
      throw this._retryError(account.label + '被站点拒绝访问', 5 * 60 * 1000, status)
    }
    if (status === 429) {
      throw this._retryError(
        account.label + '请求被限流',
        this._retryAfterMs(response, 60000),
        status
      )
    }
    if (status >= 500 || status === 0) {
      throw this._retryError(account.label + '服务器暂时不可用', 30000, status)
    }
    if (status < 200 || status >= 300) {
      throw new Error(this._message(body, '接口请求失败，HTTP ' + status))
    }
    if (!body || Number(body.code) !== 0) {
      const message = this._message(body, '接口返回失败')
      if (this._isQuotaMessage(message)) {
        throw this._retryError(account.label + '额度或次数已用尽', 30 * 60 * 1000)
      }
      throw new Error(message)
    }
    return body.data
  },

  async _api(path, options) {
    const accounts = this._accountPool()
    const attempted = {}
    let lastError = null
    let attemptedCount = 0
    for (let i = 0; i < accounts.length; i++) {
      const account = this._chooseAccount(accounts, attempted)
      if (!account) break
      const state = this._stateOf(account)
      attempted[account.key] = true
      attemptedCount++
      state.inFlight++
      state.requests++
      try {
        const data = await this._apiWithAccount(account, path, options, false)
        state.failures = 0
        state.cooldownUntil = 0
        return data
      } catch (error) {
        lastError = error
        if (!(error && error.retryable)) throw error
        state.failures++
        state.cooldownUntil = Date.now() + Number(error.cooldownMs || 30000)
      } finally {
        state.inFlight--
      }
    }
    if (lastError) {
      throw new Error(
        '账号池暂时不可用，已尝试 ' + attemptedCount + ' 个账号：' +
        String(lastError.message || lastError)
      )
    }
    throw new Error('账号池中的账号当前都在冷却，请稍后重试')
  },

  _platforms() {
    const raw = String(this._config().platforms || '').trim()
    const ids = raw
      ? raw.split(/[,，\s]+/).filter(Boolean)
      : ['fanqie', 'qimao', 'ximalaya']
    const result = []
    const seen = {}
    for (let i = 0; i < ids.length; i++) {
      const id = String(ids[i]).trim().toLowerCase()
      const definition = this._platformDefinitions[id]
      if (definition && !seen[id]) {
        seen[id] = true
        result.push(definition)
      }
    }
    if (!result.length) {
      throw new Error('搜索平台配置无效，可填写 fanqie,qimao,ximalaya')
    }
    return result
  },

  _decodeBookId(value) {
    const parts = String(value || '').split('|')
    if (parts.length !== 2 || !this._platformDefinitions[parts[0]] || !parts[1]) {
      throw new Error('书籍 ID 格式无效')
    }
    return { platform: parts[0], bookId: parts[1] }
  },

  _decodeChapterId(value) {
    const parts = String(value || '').split('|')
    if (
      parts.length !== 3 ||
      !this._platformDefinitions[parts[0]] ||
      !parts[1] ||
      !parts[2]
    ) {
      throw new Error('章节 ID 格式无效')
    }
    return { platform: parts[0], bookId: parts[1], chapterId: parts[2] }
  },

  async _searchPlatform(definition, keyword, page) {
    const apiPage = Math.max(0, Number(page || 1) - 1)
    const query =
      '?platform=' + encodeURIComponent(definition.id) +
      '&q=' + encodeURIComponent(keyword) +
      '&page=' + apiPage +
      '&tab_type=' + definition.tabType
    const data = await this._api('/api/v1/search' + query)
    const rows = data && Array.isArray(data.list) ? data.list : []
    const list = []
    for (let i = 0; i < rows.length; i++) {
      const row = rows[i] || {}
      const id = String(row.book_id || row.bookId || '')
      const title = String(row.title || row.book_name || '').trim()
      if (!id || !title) continue
      const author = String(row.author || row.anchor || '').trim()
      list.push({
        bookId: definition.id + '|' + id,
        title: title,
        cover: String(row.cover || row.cover_url || ''),
        author: definition.name + (author ? ' · ' + author : ''),
        intro: ''
      })
    }
    return {
      list: list,
      hasMore: !!(data && data.has_more === true)
    }
  },

  async search(keyword, page, pageSize) {
    const value = String(keyword || '').trim()
    const currentPage = Math.max(1, Number(page || 1))
    if (!value) {
      return { list: [], page: currentPage, maxPage: currentPage, hasMore: false }
    }

    const definitions = this._platforms()
    const tasks = definitions.map(async definition => {
      try {
        return await this._searchPlatform(definition, value, currentPage)
      } catch (error) {
        return { list: [], hasMore: false, error: error }
      }
    })
    const results = await Promise.all(tasks)
    const list = []
    let hasMore = false
    let successCount = 0
    let firstError = null
    for (let i = 0; i < results.length; i++) {
      const result = results[i]
      if (result.error) {
        if (!firstError) firstError = result.error
        continue
      }
      successCount++
      hasMore = hasMore || result.hasMore === true
      for (let j = 0; j < result.list.length; j++) list.push(result.list[j])
    }
    if (!successCount && firstError) throw firstError

    return {
      list: list,
      page: currentPage,
      maxPage: hasMore ? currentPage + 1 : currentPage,
      hasMore: hasMore
    }
  },

  async getChapters(encodedBookId, page, pageSize) {
    const book = this._decodeBookId(encodedBookId)
    const currentPage = Math.max(1, Number(page || 1))
    const path =
      '/api/v1/books/' + encodeURIComponent(book.platform) +
      '/' + encodeURIComponent(book.bookId) +
      '/catalog?content_type=audio&page=' + currentPage
    const data = await this._api(path)
    const info = (data && data.book_info) || {}
    const rows = data && Array.isArray(data.list) ? data.list : []
    const list = []
    const fallbackOffset = (currentPage - 1) * Number(data.page_size || 50)
    for (let i = 0; i < rows.length; i++) {
      const row = rows[i] || {}
      const chapterId = String(row.chapter_id || row.chapterId || '')
      if (!chapterId) continue
      let index = Number(row.position || row.sort_order || fallbackOffset + i + 1)
      if (!isFinite(index) || index < 1) index = fallbackOffset + i + 1
      list.push({
        chapterId: book.platform + '|' + book.bookId + '|' + chapterId,
        index: Math.floor(index),
        name: String(row.title || row.name || '第' + index + '集')
      })
    }
    list.sort((a, b) => a.index - b.index)

    const actualPage = Math.max(1, Number(data.page || currentPage))
    const maxPage = Math.max(actualPage, Number(data.total_page || actualPage))
    const total = Math.max(list.length, Number(data.total || 0))
    return {
      info: {
        title: String(info.title || ''),
        cover: String(info.cover || ''),
        author: String(info.author || ''),
        trackCount: total,
        isFinished: false
      },
      list: list,
      page: actualPage,
      maxPage: maxPage,
      hasMore: data.has_more === true || actualPage < maxPage
    }
  },

  _audioUrl(audioList) {
    if (!audioList) return ''
    if (typeof audioList === 'string') {
      return /^https?:\/\//i.test(audioList) ? audioList : ''
    }
    if (Array.isArray(audioList)) {
      for (let i = 0; i < audioList.length; i++) {
        const found = this._audioUrl(audioList[i])
        if (found) return found
      }
      return ''
    }
    if (typeof audioList !== 'object') return ''

    const directKeys = ['main_url', 'mainUrl', 'url', 'play_url', 'playUrl']
    for (let i = 0; i < directKeys.length; i++) {
      const value = audioList[directKeys[i]]
      if (typeof value === 'string' && /^https?:\/\//i.test(value)) return value
    }
    const preferred = ['video_1', 'default', 'video_2', 'video_3']
    for (let i = 0; i < preferred.length; i++) {
      if (!audioList[preferred[i]]) continue
      const found = this._audioUrl(audioList[preferred[i]])
      if (found) return found
    }
    const keys = Object.keys(audioList)
    for (let i = 0; i < keys.length; i++) {
      if (preferred.indexOf(keys[i]) >= 0 || directKeys.indexOf(keys[i]) >= 0) {
        continue
      }
      const found = this._audioUrl(audioList[keys[i]])
      if (found) return found
    }
    return ''
  },

  async getAudioUrl(encodedChapterId) {
    const chapter = this._decodeChapterId(encodedChapterId)
    const path =
      '/api/v1/books/' + encodeURIComponent(chapter.platform) +
      '/' + encodeURIComponent(chapter.bookId) +
      '/chapters/' + encodeURIComponent(chapter.chapterId) +
      '/audio?tone_id=1'
    const data = await this._api(path)
    const url = this._audioUrl(data && (data.audio_list || data.audio || data))
    if (!url) throw new Error('接口没有返回可播放的音频地址')
    return {
      url: url,
      headers: {
        Referer: this._baseUrl() + '/',
        'User-Agent': this._userAgent
      }
    }
  }
})
