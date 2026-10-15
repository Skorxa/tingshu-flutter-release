# 站点形态识别与套路库

先判定形态再动手。**判定的最快方法：用浏览器打开目标站 → 网络面板看真实请求**（搜索、进书、点播放三个动作各看一次），比读 HTML 快得多。

## 判定顺序

1. 打开站点，搜索一次 → 看有没有 XHR/fetch 返回 JSON
2. 有 JSON → **优先走接口**（不解析页面）
3. 没有 JSON → 看播放动作：音频地址来自页面内联脚本（正则可取）还是接口
4. 页面被守卫/需要会话 → 先解决 Cookie，再谈解析

## 套路一：PTCMS 系（`novelsearch`/`search.php` 模板站）

站型特征：路径形如 `/bookdir/xxxx.html`、`/play/1_2_3.html`，站内搜索框提交到 `search.php`。

| 环节 | 请求 | 要点 |
|---|---|---|
| 搜索 | `POST /novelsearch/search/result.html`（表单 `searchkey`/`searchtype`）或 `GET /search.php?q=` | 返回 HTML，正则取 `/bookdir/` 或 `/book/N.html` 链接 |
| 目录 | `GET /bookdir/{hash}.html?page=N&sort=asc` | **`sort=asc` 必须显式带上**，否则可能是倒序 |
| 音频 | `POST /api/mapi/play` 或 `/api/play` | 需请求头 `sc`、`sp` 两个值 |

`sc`/`sp` 生成方式：站点 JS 里有一张打乱表 + 位移/异或算法，参数含时间戳。**若站点同时有老版 `play/{id}.html` 页面**，页面里通常直接内联音频地址，比复刻算法省事——优先用页面版。

## 套路二：51 盾 / 前端守卫

站型特征：直接请求内容页返回一段混淆脚本，含 `var reversed`、`base64` 解码、设置 Cookie。

处理：把脚本里 base64 解出来的值写进 `pt_guid`（或 `__51guid__` / `__51refresh__guid`）Cookie，再重放原请求。源里写一个 `_guard(html)` 探测函数：检测到守卫特征就解出 Cookie 重试一次，并缓存该 Cookie 复用。

## 套路三：会话型（无 Cookie 返回通用页 / 401）

站型特征：直接请求接口返回 `{"error":"非法访问"}`、或返回首页内容、或列表为空。

处理：
- 先 `GET 站点首页`（或任意内容页）建立会话（PHPSESSID 等），再发目标请求；Cookie 由 `uni.request` 自动携带（同域名会带上 Dart 侧 CookieJar，必要时手动从 `Set-Cookie` 取并放进 `header.Cookie`）
- Referer 用站点首页即可（多数站只校验非空）
- 参考实现：`assets/sources/tj-i275.js` 的 `_ensureSession()`

## 套路四：明文 JSON API（最省事）

站型特征：XHR 直接返回 JSON，无需签名。

- 只要传对参数（注意 ID 可能是**字符串敏感**的），就能拿搜索/目录/音频
- 参考：`assets/sources/tingyou.js`（`/api/h5/listening/search|rank|chapters|play`）
- 注意响应可能是**两层信封** `{code,msg,data:{url}}` 或裸对象，两种都兼容

## 套路五：加密 web API（有签名）

站型特征：请求体是 base64 密文、请求头带 `x-req-signature`/`x-post-signature`/`x-key-version`，启动配置是个加密文件。

**先别复刻加密**。按优先级尝试：
1. **找同站明文命名空间**：很多站把业务接口分两套，一套加密（视频/榜单），另有一套明文（如 `/api/h5/listening/*`）
2. **找移动端接口**：同一数据常有不加密的移动版（如喜马拉雅 `mobile.ximalaya.com/mobile/v1/track` 直接返回明文 `playUrl64`）
3. **确认到底有没有需要**：用浏览器 hook `crypto.subtle` 看官方客户端实际调了哪些加解密——经常发现目标接口根本没走加密
4. 实在没有旁路才考虑改 App 加原语（见 `audio-chains.md` 末尾）

## 套路六：镜像 / 套壳站（同源不同壳）

站型特征：多个域名内容一致（酷我系、听书8 系、聚合站），或站点本身是别人的镜像。

处理：**认底层平台 ID，不认站点**。
- 酷我系：抓到 `rid` 后走酷我解析链
- 资源站镜像：确认它的音频后端域名，按后端做防盗链

## 套路七：平台官方直连（喜马拉雅 / 懒人听书 / 阅文系）

官方公开接口多数不加密，关键在**请求头与设备 Cookie**：

| 平台 | 搜索 | 目录 | 音频 |
|---|---|---|---|
| 喜马拉雅 | `search.ximalaya.com/front/v1?core=album` | `mobile.ximalaya.com/mobile/v1/album/track`（**App UA + 设备 Cookie**） | `mobile.ximalaya.com/mobile/v1/track/{id}` → 明文 `playUrl64` |
| 懒人听书 | `m.lrts.me/ajax/searchBook` | `m.lrts.me/ajax/getBookMenu` | `m.lrts.me/ajax/getPlayPath`（免费）→ 第三方 API（付费） |

参考实现：`assets/sources/tj-ximalaya.js`、`assets/sources/tj-lrts.js`。

### ⚠️ 官方搜索的索引可能明显不全，优先用第三方 API 的搜索

实测喜马拉雅（同一个关键词）：

| 关键词 | 官方 `search.ximalaya.com` | 爱听书API `act=search` |
|---|---|---|
| `偷香高手 头陀渊` | **0 条**（官方对多词做「全词命中」） | **1 条，正是目标专辑** |
| `偷香高手` | 13 条 | 20 条 |

那本书在官方接口里搜不到，但**专辑本身完全正常**（用 API 拿到的 id 去取目录、取音频都没问题）。也就是说：**搜不到 ≠ 不存在**，官方搜索索引覆盖不全时，先换第三方 API 的搜索再判断。

因此 `tj-ximalaya.js` 的搜索是「API 为主、官方兜底」：

```js
let list = []
try { list = await this._searchApi(kw, p) } catch (e) {}          // 主：act=search
if (!list.length) { try { list = await this._searchOfficial(kw, p) } catch (e) {} }  // 兜底
```

判断依据：用户反馈「很多搜不到」时，先拿同一关键词对比两条搜索通道的条数，再决定改哪一条——不要急着归因于多关键词或分页。

## 套路八：CMS / ZBlog 批量站（页面解析为主）

站型特征：一整套开源 CMS（分类列表 `.category-list`、`.row3.row-b`、播放页内联 `jPlayer`/`APlayer` 配置）；ZBlog 站（`.post`、`/zb_users/`）。

处理：正则解析列表页取书链接 → 详情页取章节链接 → 播放页取内联音频配置。这类站通常有会员墙，音频缺失时给明确提示而不是报解析失败。

## 站点能力速判表

| 观察 | 结论 |
|---|---|
| XHR 返回 JSON | 走接口，别解析 HTML |
| HTML 里 `<a href="/play/...">` | 页面解析：书页拿章节、播放页拿音频 |
| 返回 `{"error":"非法访问"}`/首页内容 | 会话型，先建会话 |
| 响应体是 base64 密文 / 带签名头 | 加密型，先找明文旁路 |
| 目录页有 `sort=` 参数 | 必须显式指定排序 |
| 音频地址是 `xxx$...` 之类的自定义串 | 站点自己也不解析，找底层平台或第三方解析接口 |
