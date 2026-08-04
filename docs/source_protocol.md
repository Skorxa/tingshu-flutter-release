# 音源协议 v1

App 只消费本协议字段。任何站点差异都应在 JS 音源内部适配成这里的结构。
完整写源教程见 [听书音源编写规范](./音源编写规范.md)。

## 音源对象

```js
({
  id: 'source-id',
  name: '音源名称',
  apiVersion: 1,
  configFields: [],
  login: {
    url: 'https://example.com/login',
    configKey: 'cookie'
  },

  async search(keyword, page = 1, pageSize = 20) {},
  async getChapters(bookId, page = 1, pageSize = 30) {},
  async getAudioUrl(chapterId) {}
})
```

必填：
- `id`: 字符串，稳定唯一。
- `name`: 字符串，显示给用户。
- `apiVersion`: 当前为 `1`，可省略，默认 `1`。
- `search / getChapters / getAudioUrl`: 必须是函数。
- `configFields`: 可选。只有声明了配置字段，或 App 能从登录声明推断出配置字段时，才会显示“设置/音源配置”入口并注入配置。
- `login` / `loginUrl`: 可选。声明后，音源管理页长按该源会出现“登录”，并用 App 内置 WebView 打开登录页。

## search 返回

```js
return {
  list: [
    {
      bookId: 'book-id',
      title: '书名',
      cover: 'https://...',
      author: '作者/主播',
      intro: ''
    }
  ],
  page: 1,
  maxPage: 10,
  hasMore: true
}
```

必填：
- `list`: 数组。
- `bookId`: 非空字符串。
- `title`: 非空字符串。

可选：
- `cover / author / intro`
- `page / maxPage / hasMore`

## getChapters 返回

```js
return {
  info: {
    title: '书名',
    cover: 'https://...',
    author: '作者/主播',
    trackCount: 100,
    isFinished: false
  },
  list: [
    {
      chapterId: 'chapter-id',
      index: 1,
      name: '第1集'
    }
  ],
  page: 1,
  maxPage: 4,
  hasMore: true
}
```

必填：
- `info`: 对象。
- `list`: 数组。
- `chapterId`: 非空字符串。
- `index`: 正整数，必须是正序集号。
- `name`: 非空字符串。

可选：
- `info.title / info.cover / info.author / info.trackCount / info.isFinished`
- `page / maxPage / hasMore`

## getAudioUrl 返回

可以直接返回字符串：

```js
return 'https://example.com/audio.mp3'
```

也可以返回带请求头的对象：

```js
return {
  url: 'https://example.com/audio.mp3',
  headers: {
    Referer: 'https://example.com/',
    'User-Agent': 'okhttp/4.9.0'
  }
}
```

要求：
- `url` 必须是 `http` 或 `https`。
- `headers` 可选，键和值都会按字符串处理。

## 网络能力

音源里使用 `uni.request`：

```js
uni.request({
  url: 'https://example.com/api',
  method: 'GET',
  data: { keyword: '剑来' },
  header: { 'User-Agent': 'okhttp/4.9.0' },
  timeout: 15000,
  success: r => {},
  fail: e => {}
})
```

App 会把请求交给 Dart 的 HTTP 层执行。

需要解密站点返回的 AES/CBC 数据时，可以使用通用加密桥接：

```js
const plainText = await uni.crypto.aesCbcDecrypt({
  cipherText: encryptedBase64,
  key: keyText,
  iv: ivText,
  inputEncoding: 'base64',
  keyEncoding: 'utf8',
  ivEncoding: 'utf8'
})
```

编码支持 `base64`、`hex`、`utf8`；AES key 必须为 16/24/32 字节，IV 必须为 16 字节。解密模式固定为 AES/CBC/PKCS7。

## 管理入口

音源能力由 JS 自己声明，App 不为具体站点写特殊适配逻辑。

- **设置 → 音源管理 → 长按音源**：可开启/关闭、设为当前、删除。声明了 `login` / `loginUrl`，或声明了账号、密码、Token、Cookie 等登录配置字段的源才显示“登录”；只有声明了 `configFields` 或登录配置键的源才显示“设置”。
- **搜索结果或书架书籍 → 长按**：可打开“调试音源”。调试会自动跑一遍搜索、目录、音频解析，并把每一步写入“设置 → 诊断 → 查看运行日志”。
- 聚合搜索是否启用由 App 设置控制。关闭聚合搜索时，只搜索当前音源。

## 音源配置 / 登录信息

只有音源声明了 `configFields`，或声明了可推断配置键的登录能力，用户才可以在 App 里配置登录信息或站点参数。未声明、也无法推断的配置不会注入给音源。

如果音源需要登录页，而不是手动复制 Cookie，可以声明 `login`：

```js
({
  id: 'vip-source',
  name: '需要网页登录的音源',
  apiVersion: 1,

  login: {
    url: 'https://example.com/login',
    configKey: 'cookie'
  },

  configFields: [
    {
      key: 'cookie',
      label: 'Cookie',
      type: 'textarea',
      hint: '内置登录页会自动写入；也可以手动粘贴',
      required: true
    }
  ],

  async search(keyword, page = 1, pageSize = 20) {},
  async getChapters(bookId, page = 1, pageSize = 30) {},
  async getAudioUrl(chapterId) {}
})
```

也支持简写：

```js
loginUrl: 'https://example.com/login'
```

登录行为：
- 用户在“设置 → 音源管理”长按音源，点“登录”。
- App 用内置 WebView 打开 `login.url` / `loginUrl`。
- 用户登录完成后点“完成”。
- App 读取 WebView Cookie，并保存到 `login.configKey` 指定的配置字段。
- 后续音源可通过 `this.config[configKey]` 或兼容的 `uni.getStorageSync(...)` 读取。

如果只写 `loginUrl`，App 只能知道登录页地址，不能知道 Cookie 应保存到哪个字段。需要自动保存 Cookie 时，推荐使用完整的 `login: { url, configKey }`。建议同时声明对应的 `configFields`，这样登录失败或 Cookie 过期时，用户仍可手动查看、清空或粘贴。

示例：

```js
({
  id: 'vip-source',
  name: '需要登录的音源',
  apiVersion: 1,
  configFields: [
    {
      key: 'cookie',
      label: 'Cookie',
      type: 'textarea',
      hint: '从浏览器复制 Cookie',
      required: true
    },
    {
      key: 'userAgent',
      label: 'User-Agent',
      type: 'text',
      hint: '可选'
    },
    {
      key: 'device',
      label: '设备参数',
      type: 'json',
      hint: '{"deviceId":"..."}'
    }
  ],

  async search(keyword, page = 1, pageSize = 20) {},
  async getChapters(bookId, page = 1, pageSize = 30) {},
  async getAudioUrl(chapterId) {}
})
```

字段说明：
- `key`: 必填，配置键名。音源里通过 `this.config[key]` 读取。
- `label`: 显示名称。
- `type`: `text`、`password`、`token`、`textarea`、`json`、`account_list`。
- `hint`: 输入提示。
- `required`: 是否必填。

`account_list` 会显示可动态添加、删除的账号编辑器，数量不限。保存后注入为：

```js
this.config.accounts = [
  { email: 'user1@example.com', password: '...' },
  { email: 'user2@example.com', password: '...' }
]
```

音源调用时，App 会把用户填写的声明字段注入到当前源对象：

```js
const cfg = this.config || {}
const cookie = cfg.cookie || ''
const authorization = cfg.authorization || ''
const userAgent = cfg.userAgent || 'okhttp/4.9.0'
const device = cfg.device || {}
```

也兼容以下读取方式：

```js
const cfg = uni.getStorageSync('sourceConfig') || {}
const cookie = uni.getStorageSync('cookie')
const authorization = uni.getStorageSync('authorization')
const userAgent = uni.getStorageSync('userAgent')
```

额外兼容：
- `uni.getStorageSync('qt_cookie')` 会读取 `this.config.qt_cookie`，不存在时回退到 `this.config.cookie`。这是为青天聚合类音源保留的兼容键。

`configFields` 保存的配置会持久化到 App 本地；音源自己通过 `uni.setStorageSync` 写入的临时值只存在于当前 JS 运行环境。建议优先使用 `this.config`，并由音源自己决定如何把 Cookie、Token、设备 ID 等字段拼到请求头或接口参数里。
