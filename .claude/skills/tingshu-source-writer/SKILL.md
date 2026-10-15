---
name: tingshu-source-writer
description: 为「橘听」Flutter App 编写、调试、修复并发布有声书音源。音源是在内置 QuickJS 引擎中运行的 JS 对象表达式 ({...})，把任意站点/接口的数据适配成 App 协议，再通过订阅下发到客户端。当用户提到「写音源 / 新增源 / 加一个源 / 适配某站点 / 修音源 / 音源搜不到 / 目录乱序 / getAudioUrl 解析失败 / 音频放不了 / 发布源 / 上传云端」等时使用。
---

# 橘听音源编写

音源 = 一段在内置 **QuickJS** 里运行的 JS 对象表达式，把任意站点的有声书数据适配成 App 协议。写完后通过**订阅**下发（R2 + 清单版本号），不是重新打包 APK。

## 按顺序做这四件事

1. **读权威素材**（本仓库，协议以它们为准）
   - `docs/音源编写规范.md` — 完整规范（字段、登录、调试、排错）
   - `assets/sources/yuanqi.js` — 标准 JSON 接口的最小干净模板，新源从它起步
   - `assets/sources/beiji-kuwo.js` — 多接口 / 非标准 JSON / 倒序映射 / 多通道音频解析
   - `assets/sources/tj-i275.js` — 会话型站点：JSON 接口 + 页面解析兜底 + 跨站音频桥接
   - `assets/sources/tj-lrts.js` — 官方接口 + 第三方解析兜底 + 源内限速/缓存/预取
   - `assets/sources/tingyou.js` — 新版明文 JSON API（无加密、无页面解析）
   - `assets/js/uni_shim.js`、`lib/source/source_contract.dart` — 运行时能力与返回值硬校验

2. **判定站点形态** → 查 `references/site-patterns.md`
   先分清是「页面解析」还是「有接口」。**能走接口就别解析页面**。

3. **实现 + 冒烟测试** → 用 `scripts/smoke.cjs`（Node + uni 垫片，直接打真实接口）

   ```bash
   node --check assets/sources/<name>.js
   node .claude/skills/tingshu-source-writer/scripts/smoke.cjs assets/sources/<name>.js 关键词
   # 可选: --book-index=0 --chapter=1 --no-audio
   ```

   它会依次验：加载、三方法齐备、搜索有结果、发现页、目录（**含顺序自检**）、音频 206。
   首条搜索结果可能是已下架专辑、也可能是纯付费专辑——脚本会自动换书（含发现页的精选专辑），
   这类失败属数据问题，不代表源有缺陷。

4. **发布** → 按 `references/publish.md`：双目录同步 → 清单加条目并升版本 → 上传 R2 → 健康检查。

不确定某一步该怎么做判断时，看 `references/case-study.md`——一份真实的从零到发布全记录（探活踩到风控文案 → 绕过加密 → 分页与顺序验证 → 冒烟暴露假失败 → 发布卡授权），末尾附另两种站型的对照案例。

## 运行机制铁律

- **是 QuickJS，不是浏览器**：无 `DOM/window/fetch/XMLHttpRequest/localStorage/document`。有 `console/setTimeout/JSON/Promise` 和现代语法（async/await、箭头函数、`?.`、模板串）。HTML 只能用正则解析。
- 整段脚本必须是**一个对象表达式** `({ ... })`；最外层不是对象、或缺 `id`/`name`/三方法 → 加载即报错。
- 网络只能 `uni.request`（Dart 侧 dio 执行），单次方法调用超时 **30 秒**。
- 方法内 `this` 指向音源对象本身；配置在 `this.config`。
- `uni.crypto` 只有 6 个原语，见 `references/audio-chains.md` 末尾的清单——**缺原语时先找站点的明文旁路，别急着改 App**。

## 协议速查

| 方法 | 入参 | 返回 |
|---|---|---|
| `search(keyword, page, pageSize)` | 关键词, 页码(从1), 每页数(默认20) | `{ list:[{bookId,title,cover,author,intro}], page, maxPage, hasMore }` |
| `getChapters(bookId, page, pageSize)` | 书id, 页码(从1), 每页数 | `{ info:{title,cover,author,trackCount,isFinished}, list:[{chapterId,index,name}], page, maxPage, hasMore }` |
| `getAudioUrl(chapterId)` | 章节id | `'http...'` 或 `{ url, headers }` |
| `discover()` 可选 | — | `{ sections:[{title, list:[书]}] }` |
| `login`/`configFields` 可选 | — | 登录页与配置字段，见规范第 7 节 |

- 必填非空：`search.list[].bookId/title`、`getChapters.list[].chapterId/name/index`、音频 url 必须 http(s)。
- `bookId`/`chapterId` **必须能被自己的接口再次识别**（原样回传，或用 `_pack/_unpack` 把元数据 JSON 编码进去）。
- `index` 用全书连续集号；`hasMore`/`isFinished` **只认严格 `true`**。
- 搜不到 → 返回空 `list`，**不要抛错**；真出错才 `throw new Error`。

## 六条最常踩的坑（详情见 references/pitfalls.md）

1. 引擎对任何状态码都进 `success`，必须自己判 `statusCode`。
2. `res.data` 能 JSON.parse 才是对象，否则是原始字符串——非标准 JSON（单引号 dict）要 `new Function('return('+d+')')()` 兜底。
3. **目录顺序不一定是你要的**：kw 专辑最新在前要倒序、tx 专辑服务端乱序要按章节名数字排序、wy 大歌单 `tracks` 会被截断。大书一律「拉全量 → 排序 → 沉底片花 → 内存分页」。
4. 第三方音频接口常有 **IP 限速**：在源内记录上次调用时间、自动等窗口、分级缓存、预取下一集（见 `tj-lrts.js`）。
5. ID 参数可能是**字符串敏感**的（传数字返回“参数无效”之类），先按文档原样传。
6. 接口响应可能是**两层信封** `{code,msg,data:{url}}`，也可能是裸对象——两种都兼容。

## 交付前检查清单

- [ ] `({ ... })` 包裹，`id` 全局唯一，三方法名精确。
- [ ] 每请求判 `statusCode`；失败 throw，无结果返回空 list。
- [ ] 目录顺序正确（抽首集/末集核对），大书能分页。
- [ ] 音频直链实测 `Range: bytes=0-99` 能返回 206 + audio/*。
- [ ] 限速接口已做源内等待 + 缓存；会话型站点已先建会话。
- [ ] 防盗链需要时返回 `{ url, headers }`。
- [ ] `assets/sources/` 与 `build/source-subscription/sources/` 两份一致，清单版本已 +1。
- [ ] R2 已上传（清单 + 新源文件），废弃源已删除。
