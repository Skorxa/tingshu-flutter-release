# 橘听

Flutter 版橘听 App。当前重点能力包括音源管理、单源/聚合搜索、书架、播放器、目录缓存、音频缓存、运行日志、WebDAV 网盘书库，以及需要登录的音源支持。

## 文档

- [听书音源编写规范](docs/音源编写规范.md)：完整写源教程，包含音源骨架、返回结构、登录配置、调试、导入和排错。
- [音源协议 v1](docs/source_protocol.md)：协议字段速查。

## 音源开发要点

- 音源是 QuickJS 中运行的 JavaScript 对象表达式，最外层必须是 `({ ... })`。
- 必须实现 `search`、`getChapters`、`getAudioUrl` 三个方法。
- 站点差异由音源自己适配成统一协议，App 只消费协议字段。
- 需要登录的源应声明 `login: { url, configKey }` 和对应的 `configFields`。
- 搜索结果或书架书籍长按可以执行“调试音源”，自动跑搜索、目录、音频解析并写入运行日志。

## 常用命令

```powershell
flutter analyze lib test
flutter build apk --debug
flutter build apk --release
```
