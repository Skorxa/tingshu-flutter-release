# 实战案例：喜马拉雅直连源（从零到发布）

完整走一遍真实流程。选这个案例是因为它同时踩到了写源最典型的三个岔路口：**接口探活**、**加密绕路**、**目录分页与顺序**。

> 时间：2026-10 ｜ 产物：`assets/sources/tj-ximalaya.js`（约 9KB，187 行）
> 起点：仓库里只有代理版喜马拉雅源，没有直连版

---

## 阶段 0：确定起点与参考素材

手上有两个可用输入：

1. **第三方插件实现**（GitHub 上的随身听书插件包 `ximalaya.js`，可读 JS）——它给出了接口清单和音频解密密钥
2. **站点自身** —— 用浏览器打开、网络面板看真实请求（最快的判定手段）

从插件里抄下来的初始情报：

| 环节 | 接口 |
|---|---|
| 搜索 | `https://search.ximalaya.com/front/v1?core=album&kw=&page=&rows=20` |
| 专辑 | `https://www.ximalaya.com/revision/album/v1/simple?albumId=` |
| 目录 | `https://mobile.ximalaya.com/mobile/v1/album/track?albumId=&pageId=&pageSize=200&isAsc=true&device=android` |
| 分类 | `/revision/category/allCategoryInfo` + `/revision/category/queryCategoryPageAlbums` |
| 音频 | `/mobile-playpage/track/v3/baseInfo/{ts}?device=web&trackId=&trackQualityLevel=1` → 需 **AES-128-ECB 解密**（密钥 `aaad3e4fd540b0f79dca95606e72bf93`） |

## 阶段 1：逐个探活，先排除假失败

直接 curl 打一遍。搜索 ✅、专辑信息 ✅，目录 ❌：

```
ret=924  msg=亲，该内容因故已下架，请您谅解
```

换专辑继续试，还是 924 或空列表。此时**不要下结论说接口挂了**——先排查是不是自己有东西没带：

| 试探 | 结果 |
|---|---|
| `www.ximalaya.com/revision/album/v1/getTracksList`（web 版） | `ret=401 用户未登录` |
| `m.ximalaya.com/mobile/v1/album/track`（移动域名） | `ret=0` 但列表为空 |
| 加 `x-uid: 0`、`x-requested-with` | 仍 401 |
| 访问首页拿 Cookie 后重试 | 只有华为 WAF 的 `HWWAFSESID`，仍失败 |

**突破点**：同时带上 **App 版 UA** 和**设备 Cookie**：

```bash
curl -A 'ting_6.6.99(c0b8f2a4db1a8c6c1b7e1a3d0f2c4b6e)' \
     -H 'Cookie: 1&_device=android&<uuid>&ting_6.6.99&ximalaya&android&23&1&ios' \
     'https://mobile.ximalaya.com/mobile/v1/album/track?albumId=26110295&pageId=1&pageSize=5&isAsc=true&device=android'
# → ret=0，章节列表正常返回
```

**教训**：只带 UA 或只带 Cookie 都不行；缺任一个时站点返回的是「该内容因故已下架」——一句**误导性的风控文案**，实际含义是「没认出来是自家 App」。这类反直觉文案必须记下来（见 `pitfalls.md` 第三节）。

## 阶段 2：音频路径的关键决策（这里省掉了一次 App 发版）

插件路线是 `baseInfo` + AES-128-ECB 解密。先按插件复现，验证到：

- `baseInfo` 确实返回 5 档音质：`M4A_64 / MP3_64 / M4A_24 / MP3_32 / AAC_24`
- 解密时 key 的处理有两种，**只有一种对**：
  - 按 utf8 取 32 字节 → AES-256 → `bad decrypt` ❌
  - 按 hex 取 16 字节 → AES-128 → 成功 ✅（密钥那头看着像 32 字符，其实是 16 字节的 hex）

解密出来是 `https://a.xmcdn.com/...m4a?sign=...`，实测 206 ✅。

**但沙箱没有 AES-ECB 解密原语**（只有 `aesGcmEncrypt`/`aesCbcDecrypt`/`sm4EcbEncrypt`/`sha256Hex`/`md5Hex`/`xChaCha20Poly1305Decrypt`）。走这条路意味着：改 `source_crypto.dart` + `js_engine.dart` → 重新打包发版 → 用户升级后才能用。

于是按 `audio-chains.md` 的处理顺序先找旁路。试移动端 track 接口：

```bash
curl -A 'ting_6.6.99(...)' -H 'Cookie: 1&_device=android&<uuid>&...' \
     'https://mobile.ximalaya.com/mobile/v1/track/204879053?device=android'
```

返回对象里有 **`playUrl64` / `playUrl32` / `downloadUrl` / `downloadAacUrl`，全是明文 http 直链**：

```
playUrl64 → http://aod.cos.tx.xmcdn.com/group65/M06/6A/AC/...m4a
实测 → HTTP 206 audio/mpeg  5,170,048 bytes
```

**决策：走明文接口，零加密依赖，不改 App。** 这是整个案例里最值钱的一步——花十分钟找旁路，省掉一次发版。

## 阶段 3：分页与顺序验证（用户明确要求过的点）

找一本 3434 集的大书压测：

```
pageSize=200 → maxPageId=18
  page1: 蛊真人 001 …（1–200）
  page2: 蛊真人 201 …（201–400）
  page18: 34 章
校验: 17 × 200 + 34 = 3434 ✅ 与声明的总集数一致
```

顺序递增正确，无需倒序或重排。**验收方式**：抽首集、次集、末页末集三点核对，不能只看总数。

## 阶段 4：写源

结构（完整实现见 `assets/sources/tj-ximalaya.js`）：

```text
_uaWeb / _uaApp / _cookie()      设备 Cookie 运行时生成随机 UUID
_get(url, mobile)                按 mobile 标志切换 UA+Cookie 或浏览器头
search()                         search.ximalaya.com → docs[]
discover()                       8 个频道各自 queryCategoryPageAlbums，两个 worker 并发
getChapters()                    pageSize=200 循环到 maxPageId → 全量缓存 → 客户端内存分页
getAudioUrl()                    mobile/v1/track/{id} → playUrl64 || playUrl32 → 4 分钟缓存
```

落地的几个具体细节：

- `bookId` 用 `_pack({id,t,c,a})` 把标题/封面/主播一起编码进去，这样 `getChapters` 不必再请求专辑信息
- 章节页大小对外 30，内部一次拉 200，靠缓存与内存分页兼顾「大书不超时」与「翻页快」
- 错误要做区分：目录接口 `ret=924` → 「该专辑已下架」；音频 `playUrl` 为空 → 「该集需要会员或购买后才能收听」

## 阶段 5：冒烟测试（第一次跑就暴露了两个假问题）

用通用冒烟脚本：

```bash
node .claude/skills/tingshu-source-writer/scripts/smoke.cjs assets/sources/tj-ximalaya.js 凡人修仙传
```

第一轮结果：搜索 20 条 ✅、发现 7 分区 ✅、**目录 FAIL**——报「该内容因故已下架」。

排查结论：**挑中的那条搜索结果是已下架专辑**，源没毛病。换发现页的专辑（蛊真人）重跑 → 目录 3434 集 ✅、音频 206 ✅。

第二轮又出现：目录 ✅ 但**音频 FAIL**——`凡人修仙传+仙界篇` 是付费专辑。再换书 → 通。

**结论**：这两类失败都是**数据问题不是源缺陷**。冒烟脚本据此改成了「按顺序换书重试，并把发现页的精选专辑也纳入音频候选」，避免以后误判。

## 阶段 6：发布

```bash
node --check assets/sources/tj-ximalaya.js
cp assets/sources/tj-ximalaya.js build/source-subscription/sources/tj-ximalaya.js
# 清单加条目 { "url": "sources/tj-ximalaya.js", "version": 1 }，顶层 version 34 → 35
# 上传 R2（清单 + 源文件）
```

**本次卡在 Cloudflare 授权**（wrangler OAuth 令牌过期，`wrangler login` 需要浏览器交互确认），所以 R2 上传这一步留作待办——本地文件与清单都已就绪，授权恢复后按 `publish.md` 的两条命令补传即可。

## 阶段 7：边界实测（发布后补的经验）

顺手测了免费/付费边界，这些结果直接决定用户会看到什么：

| 专辑 | 情况 |
|---|---|
| 完全免费专辑 | 全篇可播 |
| VIP 标签专辑 | 前 26–42 集可播，深处章节**官方不给地址** |
| 已下架专辑 | 目录接口直接 `924` |

对照同平台的第三方解析 API：能解 VIP 章节，但**每 IP 每 30 秒只允许 1 次音频请求**（返回地址有效 24 小时）。结论：可以列为后续的 VIP 兜底通道，但必须套用 `tj-lrts.js` 里那套「源内等窗口 + 分级缓存 + 预取下一集」。

---

## 复盘：三个决策事后看是对的

1. **探活阶段的失败先当成自己的问题查**——「已下架」其实是风控文案，加齐 UA+Cookie 就通了。贸然判定站点不可用会直接放弃一个可用的源。
2. **遇到加密先找明文旁路**——移动端接口的明文 `playUrl64` 让整件事从「要改 App 发版」变成「纯源文件改动」。顺序永远先试旁路。
3. **验收用大书抽三点**——3434 集的书既验证了分页逻辑，也验证了顺序；小书跑通不代表大书没问题。

## 附：同一方法论在另外两种站型上的应用

| 站型 | 起点 | 关键动作 | 结果 |
|---|---|---|---|
| 听友FM（旧协议全失效） | 旧源 502 行全加密，全部 404 | 用浏览器 hook `crypto.subtle` 发现目标接口**根本没走加密** → 顺网络面板找到明文命名空间 `/api/h5/listening/*` | 重写为 184 行纯 JSON 源，零加密；同时发现该站的加密只用在视频接口上 |
| 275听书网 | 原为纯页面解析（播放页 252KB，正则抠 APlayer 配置） | 在播放页内联脚本里发现 `fetch('/api_chapter.php?book_id=&chapter_id=')` → 实测为 JSON 接口（需会话） | 音频改走接口；并把接口返回的 `lrts$专辑#轨道#集序号#token` 桥接到第三方解析 API，**救回了原本完全放不了的整类书** |

两个案例的共同点：**答案就写在站点自己的前端代码里**。读它的 JS、看它的网络请求，比猜接口快得多。
