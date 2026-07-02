# 音源订阅格式

音源订阅是一个 JSON 文件。软件通过 URL 拉取这个文件,再按列表同步本地音源。

## 推荐格式

```json
{
  "name": "我的音源订阅",
  "version": 1,
  "sources": [
    {
      "url": "https://example.com/sources/source-a.js"
    },
    {
      "code": "module.exports = { ... }"
    }
  ]
}
```

也兼容顶层直接为数组:

```json
[
  { "url": "https://example.com/sources/source-a.js" },
  { "url": "https://example.com/sources/source-b.js" }
]
```

## 字段

- `url`: 远程 JS 音源地址。支持相对路径,会按订阅 JSON 地址自动补全。
- `code`: 直接内嵌完整 JS 音源文本。
- `id`: 可选。覆盖 JS 内声明的 id。
- `name`: 可选。覆盖 JS 内声明的名称。
- `enabled`: 可选。`false` 表示同步后默认关闭。
- `loginUrl`: 可选。声明登录页面地址。
- `loginConfigKey`: 可选。登录 Cookie 或 Token 保存字段。
- `configFields`: 可选。音源设置字段。

## 私有 GitHub 仓库

如果订阅文件放在 GitHub 私有仓库,可以在订阅地址后追加 token 片段:

```text
https://raw.githubusercontent.com/Skorxa/tingshu-sources/main/sources.json#token=ghp_xxx
```

软件会把 `#token=...` 转成 `Authorization: Bearer ...` 请求头,并且同一个 token 会继续用于拉取订阅内的相对 JS 文件。日志里会自动打码 token。

建议 token 只授予该私有仓库的只读权限。公开仓库不需要追加 token。

## 同步规则

- 云端新增源: 本地新增。
- 云端修改 JS: 本地更新,并清理对应目录缓存。
- 云端删除源: 删除本地同一个订阅 URL 下的对应音源。
- 本地登录配置会按音源声明字段保留。
