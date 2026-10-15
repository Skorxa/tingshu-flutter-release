#!/usr/bin/env node
// 橘听音源冒烟测试：在 Node 里用 uni 垫片跑真实接口，验证「搜索 → 目录 → 音频」整链路
//
// 用法:
//   node smoke.cjs <源文件路径> [关键词] [选项]
//   node smoke.cjs ../../../assets/sources/tj-lrts.js 斗破苍穹
//
// 选项:
//   --book-index=N   选搜索结果里的第 N 本（默认 0）
//   --chapter=N      测目录里的第 N 章（默认 1，即第 1 章）
//   --no-audio       跳过音频检查
//
// 退出码: 0 全通过 / 1 有失败项

const { readFileSync } = require('node:fs')
const { createHash, createDecipheriv, createCipheriv, randomBytes } = require('node:crypto')

/* ── uni 垫片 ───────────────────────────────────────────── */

const cookieJars = new Map()
function jarFor (host) {
  if (!cookieJars.has(host)) cookieJars.set(host, new Map())
  return cookieJars.get(host)
}
function storeCookies (host, res) {
  const set = res.headers.getSetCookie ? res.headers.getSetCookie() : []
  const jar = jarFor(host)
  for (const c of set) {
    const kv = c.split(';')[0]
    const i = kv.indexOf('=')
    if (i > 0) jar.set(kv.slice(0, i).trim(), kv.slice(i + 1).trim())
  }
}
function cookieHeader (host) {
  const jar = jarFor(host)
  return Array.from(jar.entries()).map(([k, v]) => `${k}=${v}`).join('; ')
}

const memStore = new Map()
const enc = b => Buffer.from(b).toString('hex')
const dec = (s, e = 'hex') => Buffer.from(String(s), e)

const uni = {
  request (o) {
    const url = new URL(o.url)
    let body
    const headers = { ...(o.header || {}) }
    if (o.data && typeof o.data === 'object' && (!o.method || o.method === 'GET')) {
      for (const [k, v] of Object.entries(o.data)) url.searchParams.set(k, String(v))
    } else if (o.data != null) {
      body = typeof o.data === 'string' ? o.data : JSON.stringify(o.data)
    }
    const ck = cookieHeader(url.host)
    if (ck && !headers.Cookie && !headers.cookie) headers.Cookie = ck
    fetch(url.toString(), { method: o.method || 'GET', headers, body })
      .then(async res => {
        storeCookies(url.host, res)
        const text = await res.text()
        let data = text
        try { data = JSON.parse(text) } catch (_) { /* 保留原始字符串，与 App 行为一致 */ }
        o.success({ statusCode: res.status, header: Object.fromEntries(res.headers), data })
      })
      .catch(e => o.fail({ errMsg: e.message }))
  },
  getStorageSync: k => (memStore.has(k) ? memStore.get(k) : ''),
  setStorageSync: (k, v) => { memStore.set(k, v) },
  removeStorageSync: k => { memStore.delete(k) },
  crypto: {
    sha256Hex: o => createHash('sha256').update(typeof o === 'string' ? o : o.text || '', o.inputEncoding === 'hex' ? 'hex' : 'utf8').digest('hex'),
    md5Hex: o => createHash('md5').update(typeof o === 'string' ? o : o.text || '', o.inputEncoding === 'hex' ? 'hex' : 'utf8').digest('hex'),
    aesCbcDecrypt: o => {
      const d = createDecipheriv(`aes-${dec(o.key, o.keyEncoding || 'base64').length * 8}-cbc`, dec(o.key, o.keyEncoding || 'base64'), dec(o.iv, o.ivEncoding || 'base64'))
      return Buffer.concat([d.update(dec(o.cipherText, o.inputEncoding || 'base64')), d.final()]).toString('utf8')
    },
    aesGcmEncrypt: o => {
      const key = dec(o.key, o.keyEncoding || 'base64')
      const iv = o.iv ? dec(o.iv, o.ivEncoding || 'base64') : randomBytes(12)
      const c = createCipheriv(`aes-${key.length * 8}-gcm`, key, iv)
      const ct = Buffer.concat([c.update(Buffer.from(o.text, 'utf8')), c.final()])
      return enc(Buffer.concat([iv, ct, c.getAuthTag()]))
    },
    // 沙箱里没有的原语：垫片里用 Node 实现，方便本地验证；App 端若缺，源必须走旁路
    aesEcbDecrypt: o => {
      const key = dec(o.key, o.keyEncoding || 'base64')
      const d = createDecipheriv(`aes-${key.length * 8}-ecb`, key, null)
      return Buffer.concat([d.update(dec(o.cipherText, o.inputEncoding || 'base64')), d.final()]).toString('utf8')
    },
  },
}

/* ── 参数解析 ───────────────────────────────────────────── */

const argv = process.argv.slice(2)
const flags = {}
const positional = []
for (const a of argv) {
  const m = /^--([^=]+)(?:=(.*))?$/.exec(a)
  if (m) flags[m[1]] = m[2] === undefined ? true : m[2]
  else positional.push(a)
}
const file = positional[0]
const keyword = positional[1] || '凡人修仙传'
if (!file) {
  console.error('用法: node smoke.cjs <源文件路径> [关键词] [--book-index=0] [--chapter=1] [--no-audio]')
  process.exit(1)
}

/* ── 运行 ───────────────────────────────────────────────── */

const results = []
const ok = (stage, msg) => { results.push(true); console.log(`  [PASS] ${stage}: ${msg}`) }
const bad = (stage, msg) => { results.push(false); console.log(`  [FAIL] ${stage}: ${msg}`) }
const short = (s, n = 34) => String(s || '').slice(0, n)

let src
try {
  const code = readFileSync(file, 'utf8')
  src = new Function('uni', `return (\n${code}\n)`)(uni)
  ok('加载', `id=${src.id} name=${src.name}`)
} catch (e) {
  bad('加载', e.message)
  console.error('\n源无法加载，检查最外层是否为 ({ ... }) 且语法正确')
  process.exit(1)
}

const missing = ['search', 'getChapters', 'getAudioUrl'].filter(k => typeof src[k] !== 'function')
if (missing.length) bad('协议', '缺方法: ' + missing.join(', '))
else ok('协议', '三方法齐备')

;(async () => {
  // 1) 搜索
  let books = []
  try {
    const t0 = Date.now()
    const s = await src.search(keyword)
    books = Array.isArray(s && s.list) ? s.list : []
    if (!books.length) bad('搜索', `「${keyword}」返回 0 条（确认关键词或接口是否变化）`)
    else ok('搜索', `${books.length} 条 / ${Date.now() - t0}ms / maxPage=${s.maxPage} hasMore=${s.hasMore}`)
    books.slice(0, 3).forEach(b => console.log(`         · ${short(b.title)} | ${short(b.author, 16)} | ${short(b.intro, 30)}`))
    const useless = books.find(b => !b.bookId || !b.title)
    if (useless) bad('搜索字段', '有条目缺 bookId/title')
  } catch (e) { bad('搜索', e.message) }

  // 2) 发现页（可选）
  let discoverBooks = []
  if (typeof src.discover === 'function') {
    try {
      const d = await src.discover()
      const secs = (d && d.sections) || []
      if (secs.length) {
        ok('发现', secs.map(x => `${x.title}:${x.list.length}`).join(' '))
        // 发现页是运营精选，通常含免费章节，留作音频阶段的兜底候选
        for (const s of secs.slice(0, 3)) if (s.list && s.list[0]) discoverBooks.push(s.list[0])
      } else bad('发现', '没有分区')
    } catch (e) { bad('发现', e.message) }
  }

  // 3) 目录
  //    首条搜索结果可能是已下架专辑（站点会明确报「已下架」），这属于数据问题不是源缺陷，
  //    因此按顺序换书重试，最多试 3 本
  const startIdx = Number(flags['book-index'] || 0)
  let book = books[startIdx] || books[0]
  let chapters = []
  let lastErr = null
  const tried = []
  for (let k = 0; k < 3 && books[startIdx + k]; k++) {
    const cand = books[startIdx + k]
    try {
      const t0 = Date.now()
      const c = await src.getChapters(cand.bookId, 1, 20)
      book = cand
      chapters = Array.isArray(c && c.list) ? c.list : []
      if (!chapters.length) { lastErr = new Error('返回 0 章'); tried.push(short(cand.title, 16)); continue }
      tried.push(short(cand.title, 16))
      ok('目录', `「${short(cand.title, 18)}」${c.info?.trackCount ?? '?'} 集 / 首页 ${chapters.length} 条 / ${Date.now() - t0}ms / maxPage=${c.maxPage}`)
      if (k > 0) console.log(`         注: 前 ${k} 本不可用（${tried.slice(0, k).join('、')}），已自动换书`)
      console.log(`         首章: ${short(chapters[0].name, 40)}`)
      console.log(`         末章: ${short(chapters[chapters.length - 1].name, 40)}`)
      const badIdx = chapters.findIndex(x => !x.chapterId || !x.name || x.index === undefined)
      if (badIdx >= 0) bad('目录字段', `第 ${badIdx + 1} 条缺 chapterId/name/index`)
      // 顺序自检：集号是否单调递增
      const nums = chapters.map(x => Number(x.index)).filter(n => Number.isFinite(n))
      const sorted = nums.every((n, i) => i === 0 || n >= nums[i - 1])
      if (nums.length > 1 && !sorted) bad('目录顺序', 'index 非单调递增，怀疑需倒序或按集名排序')
      else if (nums.length > 1) ok('目录顺序', 'index 单调递增')
      break
    } catch (e) {
      lastErr = e
      tried.push(short(cand.title, 16))
    }
  }
  if (!chapters.length) bad('目录', `试了 ${tried.length} 本都失败（${tried.join('、')}）：${lastErr ? lastErr.message : '无结果'}`)

  // 4) 音频
  //    付费/VIP 专辑的前几集可能正好是收费章（源会如实报「需要会员/购买」），
  //    这不能证明源坏了，因此换书重试；只要有一本能出直链即算通过
  if (!flags['no-audio']) {
    const candidates = []
    if (chapters.length) candidates.push({ book, chapter: chapters[Math.max(1, Number(flags.chapter || 1)) - 1] || chapters[0] })
    for (let k = 1; k < 3 && books[startIdx + k]; k++) {
      const nb = books[startIdx + k]
      if (candidates.some(c => c.book.bookId === nb.bookId)) continue
      candidates.push({ book: nb, chapter: null })
    }
    for (const nb of discoverBooks) {
      if (candidates.some(c => c.book.bookId === nb.bookId)) continue
      candidates.push({ book: nb, chapter: null, from: '发现页' })
    }
    let done = false
    let lastMsg = ''
    for (const cand of candidates) {
      try {
        if (!cand.chapter) {
          const c = await src.getChapters(cand.book.bookId, 1, 1)
          cand.chapter = (c && c.list && c.list[0]) || null
        }
        if (!cand.chapter) { lastMsg = '该书取不到章节'; continue }
        const t0 = Date.now()
        const a = await src.getAudioUrl(cand.chapter.chapterId)
        const url = typeof a === 'string' ? a : a && a.url
        const headers = (a && a.headers) || {}
        if (!/^https?:\/\//i.test(String(url))) { lastMsg = '未返回 http(s) 地址: ' + String(url).slice(0, 60); continue }
        const res = await fetch(url, { headers: { ...headers, Range: 'bytes=0-99' } })
        const ct = res.headers.get('content-type') || ''
        const cr = res.headers.get('content-range') || ''
        if (res.status === 206 || res.status === 200) {
          ok('音频', `${Date.now() - t0}ms / HTTP ${res.status} ${ct} ${cr}`)
          console.log(`         来源: 「${short(cand.book.title, 20)}」${short(cand.chapter.name, 20)}`)
          console.log(`         ${short(url, 88)}`)
          done = true
          break
        }
        lastMsg = `HTTP ${res.status}（地址可取但被拒：查防盗链/后端是否失效）`
      } catch (e) { lastMsg = e.message }
    }
    if (!done) bad('音频', `试了 ${candidates.length} 本均不可播：${lastMsg}`)
  }

  finish()
})().catch(e => { console.error('未捕获异常:', e.message); process.exit(1) })

function finish () {
  const pass = results.filter(Boolean).length
  const fail = results.length - pass
  console.log(`\n结果: ${pass} 通过 / ${fail} 失败`)
  if (fail) console.log('排查顺序: 见 references/pitfalls.md（状态码 → 字段名 → 会话 → 顺序 → 防盗链）')
  process.exit(fail ? 1 : 0)
}
