const fs = require('fs')
const crypto = require('crypto')

const sourceFile = process.argv[2]
const keyword = process.argv[3] || '剑来'
const backend = process.argv[4] || ''

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
    if (method !== 'GET' && options.data != null) {
      init.body = typeof options.data === 'string'
        ? options.data
        : JSON.stringify(options.data)
    }
    fetch(options.url, init)
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
    }
  },
  getStorageSync() { return undefined },
  setStorageSync() {}
}

const source = eval(fs.readFileSync(sourceFile, 'utf8'))

async function main() {
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
