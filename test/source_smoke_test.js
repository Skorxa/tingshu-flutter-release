const fs = require('fs')
const crypto = require('crypto')

const sourceFile = process.argv[2]
const keyword = process.argv[3] || '剑来'
const backend = process.argv[4] || ''

function rotateLeft32(value, bits) {
  return ((value << bits) | (value >>> (32 - bits))) >>> 0
}

function quarterRound(state, a, b, c, d) {
  state[a] = (state[a] + state[b]) >>> 0
  state[d] = rotateLeft32(state[d] ^ state[a], 16)
  state[c] = (state[c] + state[d]) >>> 0
  state[b] = rotateLeft32(state[b] ^ state[c], 12)
  state[a] = (state[a] + state[b]) >>> 0
  state[d] = rotateLeft32(state[d] ^ state[a], 8)
  state[c] = (state[c] + state[d]) >>> 0
  state[b] = rotateLeft32(state[b] ^ state[c], 7)
}

function hChaCha20(key, nonce) {
  const state = new Uint32Array(16)
  state.set([0x61707865, 0x3320646e, 0x79622d32, 0x6b206574])
  for (let i = 0; i < 8; i++) state[4 + i] = key.readUInt32LE(i * 4)
  for (let i = 0; i < 4; i++) state[12 + i] = nonce.readUInt32LE(i * 4)
  for (let i = 0; i < 10; i++) {
    quarterRound(state, 0, 4, 8, 12)
    quarterRound(state, 1, 5, 9, 13)
    quarterRound(state, 2, 6, 10, 14)
    quarterRound(state, 3, 7, 11, 15)
    quarterRound(state, 0, 5, 10, 15)
    quarterRound(state, 1, 6, 11, 12)
    quarterRound(state, 2, 7, 8, 13)
    quarterRound(state, 3, 4, 9, 14)
  }
  const output = Buffer.alloc(32)
  ;[0, 1, 2, 3, 12, 13, 14, 15].forEach((word, index) => {
    output.writeUInt32LE(state[word], index * 4)
  })
  return output
}

if (!sourceFile) {
  throw new Error('Usage: node test/source_smoke_test.js <source.js> [keyword]')
}

global.uni = {
  request(options) {
    const method = String(options.method || 'GET').toUpperCase()
    const controller = new AbortController()
    const timer = setTimeout(
      () => controller.abort(),
      Number(options.timeout || 30000)
    )
    const init = {
      method,
      headers: options.header || {},
      signal: controller.signal
    }
    // 与 App 引擎保持一致(GET 的 data 作为查询参数拼接,非 GET 作为请求体),
    // 否则依赖 uni.request({url, data}) 形式传参的音源在冒烟测试里必然搜不到结果。
    let url = options.url
    if (method === 'GET' && options.data != null) {
      const params = new URLSearchParams()
      for (const [key, value] of Object.entries(options.data)) {
        if (value != null) params.append(key, String(value))
      }
      const qs = params.toString()
      if (qs) url += (url.includes('?') ? '&' : '?') + qs
    } else if (method !== 'GET' && options.data != null) {
      init.body = typeof options.data === 'string'
        ? options.data
        : JSON.stringify(options.data)
    }
    fetch(url, init)
      .then(async response => {
        const text = await response.text()
        let data = text
        try { data = JSON.parse(text) } catch (e) {}
        options.success({
          statusCode: response.status,
          data,
          header: Object.fromEntries(response.headers.entries())
        })
      })
      .catch(error => options.fail({ errMsg: error.message }))
      .finally(() => clearTimeout(timer))
  },
  crypto: {
    aesCbcDecrypt(options) {
      const decode = (value, encoding) => Buffer.from(
        String(value || ''),
        encoding === 'utf8' || encoding === 'text' ? 'utf8' : encoding
      )
      const key = decode(options.key, options.keyEncoding || 'base64')
      const iv = decode(options.iv, options.ivEncoding || 'base64')
      const cipherText = decode(
        options.cipherText || options.data,
        options.inputEncoding || 'base64'
      )
      const decipher = crypto.createDecipheriv(
        'aes-' + (key.length * 8) + '-cbc',
        key,
        iv
      )
      return Promise.resolve(
        Buffer.concat([decipher.update(cipherText), decipher.final()])
          .toString('utf8')
      )
    },
    xChaCha20Poly1305Decrypt(options) {
      const decode = (value, encoding) => Buffer.from(
        String(value || ''),
        encoding === 'utf8' || encoding === 'text' ? 'utf8' : encoding
      )
      const key = decode(options.key, options.keyEncoding || 'base64')
      const nonce = decode(options.nonce, options.nonceEncoding || 'base64')
      const encrypted = decode(
        options.cipherText || options.data,
        options.inputEncoding || 'base64'
      )
      if (key.length !== 32 || nonce.length !== 24 || encrypted.length < 16) {
        return Promise.reject(new Error('无效的 XChaCha20-Poly1305 参数'))
      }
      const subKey = hChaCha20(key, nonce.subarray(0, 16))
      const ietfNonce = Buffer.concat([Buffer.alloc(4), nonce.subarray(16)])
      const tag = encrypted.subarray(encrypted.length - 16)
      const cipherText = encrypted.subarray(0, encrypted.length - 16)
      const decipher = crypto.createDecipheriv(
        'chacha20-poly1305',
        subKey,
        ietfNonce,
        { authTagLength: 16 }
      )
      decipher.setAuthTag(tag)
      return Promise.resolve(
        Buffer.concat([decipher.update(cipherText), decipher.final()])
          .toString('utf8')
      )
    }
  },
  getStorageSync() { return undefined },
  setStorageSync() {}
}

const source = eval(fs.readFileSync(sourceFile, 'utf8'))

async function main() {
  if (process.argv.includes('--discover')) {
    if (typeof source.discover !== 'function') throw new Error('音源没有 discover 方法')
    const result = await source.discover()
    if (!result.sections || !result.sections.length) throw new Error('发现页没有分区')
    result.sections.forEach(section => {
      if (!section.title || !section.list || !section.list.length) {
        throw new Error('发现页分区格式无效')
      }
      console.log('discover:', section.title, section.list.length, section.list[0].title)
    })
    return
  }
  const search = await source.search(keyword, 1, 3)
  if (!search.list || !search.list.length) throw new Error('搜索没有结果')
  const book = backend
    ? search.list.find(item => {
        try {
          return JSON.parse(decodeURIComponent(item.bookId)).s === backend
        } catch (e) {
          return false
        }
      })
    : search.list[0]
  if (!book) throw new Error('搜索结果中没有后端: ' + backend)
  console.log('search:', search.list.length, book.title)

  const catalog = await source.getChapters(book.bookId, 1, 3)
  if (!catalog.list || !catalog.list.length) throw new Error('目录没有结果')
  const chapter = catalog.list[0]
  console.log('catalog:', catalog.list.length, catalog.info.trackCount, chapter.name)

  const audio = await source.getAudioUrl(chapter.chapterId)
  const audioUrl = typeof audio === 'string' ? audio : (audio.url || '')
  if (!audioUrl) throw new Error('音频地址为空')
  console.log('audio:', audioUrl.slice(0, 160))
}

main().catch(error => {
  console.error(error && error.stack ? error.stack : error)
  process.exitCode = 1
})
