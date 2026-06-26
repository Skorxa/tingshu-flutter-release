---
name: tingshu-source-writer
description: 为「聚合听书」Flutter App 编写、调试或修复有声书音源。音源是在内置 QuickJS 引擎中运行的 JS 对象表达式 ({...})，必须实现 search / getChapters / getAudioUrl 三个方法，把某个网站或接口的数据适配成 App 统一协议。当用户提到「写音源 / 新增音源 / 加一个源 / 适配某站点 / 修音源 / 音源搜不到 / getChapters 报错 / getAudioUrl 解析失败 / 音源调试」等时使用。
---

# 听书音源编写

为「聚合听书」App 编写/修复音源。音源 = 一段在内置 **QuickJS** 中运行的 JS 对象表达式，把任意站点的有声书数据适配成 App 协议。

## 第一步：永远先读权威素材

动手前必读（本仓库内，是协议的唯一真相来源）：

1. `docs/音源编写规范.md` — 完整规范（协议字段、登录、调试、排错）。**有疑问以它和代码为准**。
2. `assets/sources/yuanqi.js` — 标准 JSON 接口的**最小干净模板**，新源从它起步。
3. `assets/sources/beiji-kuwo.js` — 多接口 / 非标准 JSON（Python dict）/ 页码倒序映射 / p2p 音频解析。
4. `assets/sources/ytysxs.js` — 纯 **HTML 网页**正则解析 / chapterId 内嵌直链 + Referer。
5. `assets/js/uni_shim.js` — 运行时垫片，决定 `uni.*` 到底有什么、`res.data` 怎么来。
6. `lib/source/source_contract.dart` — Dart 端对返回值的**硬校验**（哪些字段缺了会直接抛错）。

修复现有源时，同时读那个源文件本身，并让用户跑「调试音源」把运行日志给你。

## 运行机制铁律

- 是 **QuickJS，不是浏览器**：没有 `DOM / window / fetch / XMLHttpRequest / localStorage / document`。有 `console / setTimeout / JSON / Promise` 和现代 JS 语法（async/await、箭头函数、可选链 `?.`、解构、模板串）。
- 整段脚本必须是**一个对象表达式**，用 `({ ... })` 包裹。最外层不是对象、或缺 `id`/`name`/三方法 → 加载即报错。
- 网络只能用 `uni.request`，由 Dart 侧 `dio` 执行。单次方法调用超时 **30 秒**。
- 方法内 `this` 指向音源对象本身；配置注入在 `this.config`。

## 协议速查

| 方法 | 入参 | 默认 | 返回 |
|---|---|---|---|
| `search(keyword, page, pageSize)` | 关键词, 页码(从1), 每页数 | pageSize=20 | `{ list:[{bookId,title,cover,author,intro}], page, maxPage, hasMore }` |
| `getChapters(bookId, page, pageSize)` | 书id, 页码(从1), 每页数 | pageSize=30/100 | `{ info:{title,cover,author,trackCount,isFinished}, list:[{chapterId,index,name}], page, maxPage, hasMore }` |
| `getAudioUrl(chapterId)` | 章节id | — | `'http...'` 或 `{ url, headers }` |

**必填非空字段**（缺了 Dart 端抛错）：`search.list[].bookId/title`、`getChapters.list[].chapterId/name/index`、`getAudioUrl` 的 url 必须 `http/https`。

- `bookId` 由 search 产出、回传给 getChapters；`chapterId` 由 getChapters 产出、回传给 getAudioUrl。**必须能被你自己的接口再次识别**（原样回传，或像 ytysxs 那样把直链/Referer JSON 编码塞进 chapterId）。
- `index` 用全书连续集号：分页时 `offset=(page-1)*pageSize` 累加。
- `hasMore`/`isFinished` **只认严格 `true`**，`1`/`'true'` 都当 false。

## 最小模板（标准 JSON 接口）

```js
({
  name: '示例源',
  id: 'demo',                         // 全局唯一，重复会覆盖旧源
  apiVersion: 1,

  _req(data) {                        // 公共请求：包成 Promise，统一判状态码
    return new Promise((resolve, reject) => {
      uni.request({
        url: 'https://example.com/api',
        data,                         // GET → 查询参数；非 GET → 请求体
        header: { 'User-Agent': 'okhttp/4.9.2' },
        timeout: 15000,
        success: r => r.statusCode === 200
          ? resolve(r.data)           // r.data 能 JSON.parse 就是对象，否则是原始字符串
          : reject(new Error('HTTP ' + r.statusCode)),
        fail: e => reject(new Error(e.errMsg || '网络失败')),
      })
    })
  },

  async search(keyword, page = 1, pageSize = 20) {
    const res = await this._req({ name: keyword, page, pageSize })
    const rows = Array.isArray(res.data) ? res.data : []
    return {
      list: rows.map(it => ({ bookId: String(it.id), title: it.title || '', cover: it.cover || '', author: it.author || '', intro: it.intro || '' })),
      page: res.page || page, maxPage: res.maxPage || 1, hasMore: !!res.hasMore,
    }
  },

  async getChapters(bookId, page = 1, pageSize = 100) {
    const res = await this._req({ itemId: bookId, page, pageSize })
    const rows = Array.isArray(res.data) ? res.data : []
    const offset = (page - 1) * pageSize
    return {
      info: { title: res.title || '', cover: res.cover || '', author: res.author || '', trackCount: res.total || 0, isFinished: !!res.isFinished },
      list: rows.map((it, i) => ({ chapterId: String(it.playId), index: offset + i + 1, name: it.title || '' })),
      page: res.page || page, maxPage: res.maxPage || 1, hasMore: !!res.hasMore,
    }
  },

  async getAudioUrl(chapterId) {
    const res = await this._req({ playId: chapterId })
    if (res.url) return res.url
    throw new Error('该章节暂无音频（VIP 或未更新）')
  },
})
```

## 按站点类型选参考范例

| 站点形态 | 套哪个内置源 | 关键手法 |
|---|---|---|
| 标准 JSON、GET 查询参数、无鉴权 | `yuanqi.js` | 直接套上面的模板 |
| JSON 但非标准（单引号 dict / JSONP）、页码倒序、需拼封面/解析直链 | `beiji-kuwo.js` | `new Function('return('+d+')')()` 兜底解析；正序页码映射到倒序 `pn`；p2p 字段拼直链 |
| 只有 HTML 网页、无 API | `ytysxs.js` | 正则抽 `<a href>`/`<img>`/og:meta；`chapterId` 用 `JSON.stringify({url,referer})` 携带直链；getAudioUrl 解出来加 Referer 头 |

## 高频陷阱（按踩坑频率排序）

1. **状态码要自己判**：引擎对任何状态码都不抛异常，4xx/5xx 也进 `success`。必须 `r.statusCode === 200 ? ... : reject`。
2. **`res.data` 类型不定**：能解析成 JSON 就是对象/数组，否则是原始字符串。非标准 JSON 要 `typeof d === 'string'` 时自己再 parse。
3. **页码从 1 起**：目标接口若从 0 起（如酷我），方法内 `page - 1`。
4. **「无结果」≠「出错」**：搜不到返回**空 list** `{ list: [], page, maxPage:1, hasMore:false }`，**不要抛错**；真出错才 `throw new Error`。
5. **防盗链**：音频/封面校验来源时，`getAudioUrl` 返回 `{ url, headers: { Referer, 'User-Agent' } }`，headers 会在播放和缓存下载时一并带上。
6. **优先 https**：App 虽开了明文 http，但很多站点对 http 风控。
7. **chapterId 必须可回传**：getAudioUrl 拿到它要能定位音频。无法二次请求时就在 getChapters 把直链编码进 chapterId。
8. **不要用浏览器 API**：`document`、`DOMParser`、`fetch` 一律没有，HTML 用正则解析。

## 登录与配置（需要鉴权的源）

- 手动填 Cookie/Token：声明 `configFields: [{ key, label, type, hint, required }]`，type ∈ `text|password|token|textarea|json`。读取用 `this.config[key]`。
- 网页登录：声明 `login: { url, configKey }`，App 用内置 WebView 打开登录页、完成后把 Cookie 写进 `configKey` 对应字段。简写 `loginUrl` 只声明登录页、不自动存 Cookie。
- 只有声明了 `configFields`/`login` 的源，音源管理页才显示「设置/登录」入口。详见规范文档第 7 节。

## 调试闭环

1. 让用户在搜索结果或书架**长按书籍 → 调试音源**：自动跑 search→getChapters→getAudioUrl，每步写入「设置 → 诊断 → 运行日志」。
2. 让报错会说话：解析不到时把真实返回塞进 error，例如
   `throw new Error('字段:' + Object.keys(res).join(',') + ' | ' + JSON.stringify(res).slice(0,300))`
3. `console.log` 只在 `flutter run` 控制台可见，**不进** App 运行日志；面向用户的诊断一律用 `throw new Error`。
4. 「完成但结果 0」= 接口通但字段对不上或被风控返回空 → 用 `throw` 打印真实结构，或用 curl/浏览器直接请求核对。

## 落地

- **临时测试**：设置 → 音源管理 → 粘贴导入，贴整段 `({...})`。即时编译注册，`id` 重复覆盖旧源。
- **作为内置源**：把 `xxx.js` 放进 `assets/sources/`，并在 `lib/source/source_manager.dart` 的 `_bundled` 列表追加 `'assets/sources/xxx.js'`。`pubspec.yaml` 已声明 `assets/sources/` 目录，无需改。

## 提交前检查清单

- [ ] 最外层 `({ ... })`，有唯一 `id` + `name`，三方法名精确。
- [ ] 返回字段与协议一致（`list`、`bookId`、`chapterId`、`index` 必填）。
- [ ] 页码从 1 处理；`index` 全书连续。
- [ ] 每次请求判 `statusCode`；失败 `throw`，无结果返回空 `list`。
- [ ] https 优先；音频防盗链用 `{ url, headers }`。
- [ ] 需登录的源声明了 `configFields`（和 `login`），并在请求里实际用上这些字段。
- [ ] 已跑通「搜索 → 进目录 → 播放」整链路，运行日志无异常。
