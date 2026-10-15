# 音频解析矩阵

音频是音源最容易失效的部分。原则：**官方直连优先 → 平台解析器 → 第三方 API 兜底**，每一层都要能独立失败并给用户可读的提示。

## 一、各平台音频获取方式（已实测）

| 平台 | 音频获取 | 说明 |
|---|---|---|
| 酷我 kw | `mobi.s.kuwo.cn` 签名接口 → `higequ` → `antiserver` → LX 解析器 | 多通道，任一成功即可 |
| 网易 wy | LX 解析器（聆澜/ikun） | 官方接口基本取不到直链 |
| QQ tx | LX 解析器（聆澜/ikun）→ songmid 换 vkey | — |
| 酷狗 kg | LX 解析器（聆澜/HYW） | — |
| 喜马拉雅 | 官方 `mobile/v1/track/{id}?device=android` → 明文 `playUrl64`/`playUrl32` | **免费内容直接用；VIP/付费章节官方不给地址** |
| 懒人听书 | 官方 `ajax/getPlayPath`（免费）→ 第三方 API（付费兜底） | 第三方返回腾讯音乐 CDN，`ttl=86400000` |
| 站点镜像的喜马拉雅章节 | 站点接口返回 `lrts$专辑#轨道#集序号#token` | 桥接：取「专辑+集序号」喂懒人第三方 API |

## 二、全平台兜底解析器（LX 社区源）

`lx源/` 目录里可用的三个，均为 HTTP GET/POST + 自定义头，**无签名依赖**：

| 名称 | 基址 | 调用方式 |
|---|---|---|
| 聆澜 | `source.shiqianjiang.cn/api/music/url` | GET `?source=&songId=&quality=128k` + 头 `X-API-Key` |
| ikun | `c.wwwweb.top/music/url` | POST `{source,musicId,quality}` + 头 `X-Api-Key` |
| HYW | `103.79.184.97/api/music/url` | GET `?source=&id=&key=` |

必需的 API Key 在 `assets/sources/tj-juhe.js` 里以 `_llKey` / `_ikKey` / `_hywKey` 定义。

**已确认不可用**：星海（后端 410）、GDStudio（有声书 rid 返回空）、玉宁熙（需注册+混淆）、墨澜（404）、K×H（依赖 QQ Cookie）、屿溪（混淆）。

## 三、第三方音频 API（爱听书API）

基址 `https://fm.12311111.xyz/api/{lrts|ximalaya}/index.php`，`act=audio` 取直链。

**两档速率**（实测确认）：

| 档位 | 速率 | 表现 |
|---|---|---|
| 免费 | **同 IP 每 30 秒 1 次** | 间隔 2.4 秒连发时第 2 次即被拒：`请求过于频繁：同一IP每 30 秒仅可请求 1 次音频，请 N 秒后再试` |
| 赞助（速度特权，¥1/月/接口） | **每分钟 30 次**（≈2 秒/次） | 间隔 2.4 秒连发全部成功 |

**源内用自适应冷却，不写死档位**：起步按赞助档乐观尝试（`_apiCooldown = 2400`），被拒时解析服务端给的秒数抬高冷却并沿用：

```js
_apiCooldown: 2400, _apiCooldownMax: 35000,
// 撞上限速 → 按提示抬高冷却后重试（免费档会走到这里，赞助档不会）
if (!url && msg.indexOf('频繁') >= 0) {
  const sec = Number((msg.match(/(\d+)\s*秒/) || [])[1] || 30)
  this._apiCooldown = Math.min(this._apiCooldownMax, Math.max(this._apiCooldown * 3, sec * 1000 + 1200))
  r = await call()          // call() 内部按新冷却等待，无需额外 sleep
}
```

这样赞助用户全程 2 秒/次，免费用户最多首次多等一次 30 秒，之后自动降到 30 秒/次稳定运行。

**返回地址 `ttl=86400000`（24 小时有效）**，所以缓存能把限速的影响再削一层。源内三层处理（参考 `assets/sources/tj-lrts.js`）：

```js
// 第二层：分级缓存（官方通道短、VIP 通道长）
this._audioCache[key] = { value, at: Date.now(), ttl: 12 * 60 * 60 * 1000 }

// 第三层：解析成功后排队预取下一集，让连播无缝（延迟跟随当前冷却）
_schedulePrefetch(bookId, section)   // setTimeout(冷却 + 400)
```

## 三之二、VIP 密钥做成设置项（可选能力开关）

第三方解析接口通常有「免费档 / 会员档」两种权限，用 `&key=` 参数区分。**不要把密钥写死在源里**，做成 `configFields` 设置项：

```js
configFields: [
  {
    key: 'vipKey',
    label: '爱听书 VIP 密钥',
    type: 'text',
    hint: '留空 = 只走免费线路；填入密钥后启用 VIP 通道，可收听会员与付费章节',
    required: false
  }
],
_vipKey() { const c = this.config || {}; return String(c.vipKey || '').trim() },
```

行为约定（用户既定偏好）：

| 设置 | 行为 |
|---|---|
| 留空 | **只走免费线路**（官方通道），不调用付费接口；付费章节 `throw` 一句「可在音源设置里填入 VIP 密钥后收听」 |
| 已填 | 官方通道优先（不限速），失败才走 VIP 接口并带上 `&key=` |

配套注意：

- `_schedulePrefetch` 之类会打付费接口的后台任务，也要先判 `if (!this._vipKey()) return`，否则会白白占用 30 秒窗口
- 声明了 `configFields` 后，音源管理页才会出现「设置」入口（详见 `docs/音源编写规范.md` 第 7 节）
- 现成实现：`assets/sources/tj-ximalaya.js`（喜马拉雅）、`assets/sources/tj-lrts.js`（懒人听书）

## 四、常见故障与对策

| 现象 | 原因 | 对策 |
|---|---|---|
| 返回地址可点开但播放 403 | 防盗链或后端已失效 | ①带 `Referer`/`UA`；②**接口在多个 CDN 后端间轮换**，检测到已知失效域名就重试换取新后端 |
| 官方接口返回空 `playUrl` 列表 | 该集需会员/购买 | 提示用户具体原因，或转第三方 API 兜底 |
| 接口返回 401/407 | 需要登录态 | 优先找移动端接口；其次加 `configFields` 让用户填 Cookie |
| 返回 `lrts$…` 之类自定义串 | 站点自己不解析，暴露了底层来源 | 解析出底层平台 ID，转对应平台或第三方 API |
| 声音播放几秒后停 | 直链带时效签名且过期 | 缩短缓存 TTL，或每次播放前重新取 |

## 五、沙箱加密原语清单（`uni.crypto`）

**已有**：`aesGcmEncrypt`、`aesCbcDecrypt`、`sm4EcbEncrypt`、`sha256Hex`、`md5Hex`、`xChaCha20Poly1305Decrypt`

**缺失**：AES-GCM 解密、AES-ECB 解密、HMAC-SHA256、ECDSA P-256 签名

遇到缺失原语时按此顺序处理：

1. **找明文旁路**（首选）——绝大多数情况下目标数据的另一条接口没有加密。喜马拉雅官方 `mobile/v1/track` 的明文 `playUrl64` 就是这样绕开 AES-ECB 的
2. **用已有原语拼**——HMAC-SHA256 可以在 `sha256Hex` 之上手搓；注意 `aesCbcDecrypt` 是 PKCS7 填充的，**不能**用它逐块模拟 ECB
3. **最后才改 App**：`lib/source/source_crypto.dart` 加方法 + `lib/source/js_engine.dart` 的 `crypto` 通道加分支（约十几行）。改完必须发新版本 APK，用户升级前用不了该源

## 六、返回格式

```js
// 普通直链
return 'https://.../a.mp4'
// 需要防盗链头（播放与下载时都会带上）
return { url, headers: { 'User-Agent': ua, Referer: site + '/' } }
```

音频 url 必须是 http(s)。取不到时 `throw new Error('可读原因')`，别返回空串。
