# 发布流程

橘听有两条下发线路，现在**主用订阅**（不用重装 APK）：

| 线路 | 适用 | 代价 |
|---|---|---|
| 订阅（R2） | 所有音源的新增/修复 | 无需发版，客户端拉清单后自动更新 |
| 内置（assets） | 随 APK 分发的默认源 | 需重新打包发版 |

## 一、订阅的文件布局

```text
build/source-subscription/
├── sources.json          ← 清单（名称、版本、源列表）
└── sources/
    └── <name>.js         ← 每个源一份，与 assets/sources/<name>.js 内容一致
```

云端结构（R2 桶 `juting-private`）：

| 键 | 内容 |
|---|---|
| `sources/subscription.json` | 就是上面的清单 |
| `sources/files/<name>.js` | 每个源文件 |

服务端绑定见 `cloud-control/wrangler.toml`：`SUBSCRIPTION_OBJECT_KEY`、`SOURCE_PREFIX`。

## 二、标准发布步骤

```bash
# 0) 在仓库根目录
cd D:/flutter/tingshu-flutter

# 1) 写完/改完源，语法检查
node --check assets/sources/<name>.js

# 2) 冒烟测试（真实接口跑一遍，见 scripts/smoke.cjs）
node .claude/skills/tingshu-source-writer/scripts/smoke.cjs assets/sources/<name>.js

# 3) 同步到订阅目录
cp assets/sources/<name>.js build/source-subscription/sources/<name>.js

# 4) 清单加条目（若已存在则沿用原条目）+ 顶层 version 加 1、updatedAt 更新
#    条目形如 { "url": "sources/<name>.js", "version": 1 }

# 5) 一致性检查：清单条目数应等于 sources/ 下文件数，且无缺失/孤儿
#    （孤儿 = 文件存在但清单没有 → 客户端永远拉不到，删掉或补进清单）

# 6) 上传（在 cloud-control 目录执行，见下）
```

## 三、上传命令

在 `D:\flutter\tingshu-flutter\cloud-control` 下执行：

```bash
# 清单（每次发布都必须传）
npx wrangler r2 object put "juting-private/sources/subscription.json" \
  --file "..\build\source-subscription\sources.json" \
  --content-type "application/json; charset=utf-8" --remote

# 变更的源文件（只传改动过的，可多个）
npx wrangler r2 object put "juting-private/sources/files/<name>.js" \
  --file "..\build\source-subscription\sources\<name>.js" \
  --content-type "text/javascript; charset=utf-8" --remote

# 删除废弃源（清单条目和云端文件都要清）
npx wrangler r2 object delete "juting-private/sources/files/<name>.js" --remote
```

## 四、认证

wrangler 用 OAuth 会过期，报 `Not logged in. Your auth token has expired` 时：

```bash
npx wrangler login          # 浏览器授权，需要交互确认
npx wrangler whoami         # 验证
```

非交互环境（如自动化）改用环境变量 `CLOUDFLARE_API_TOKEN`。

## 五、发布后验证

1. `https://jt.966001.xyz/health` — 服务存活
2. `https://jt.966001.xyz/api/subscription` — 订阅数据，**匿名访问返回 401 属正常**（需设备授权）
3. App 端：设置 → 音源管理 → 检查更新，确认清单版本号变化后源列表随之更新

## 六、注意事项

- **清单 `version` 必须每次 +1**：客户端靠它判断是否有更新；只改源文件不改版本号，客户端不会重新同步。
- **源 `id` 全局唯一**：重复会覆盖旧源。修复已有源时沿用原 id（用户端的登录配置与收藏会保留）。
- 清单里的 `updatedAt` 只是展示信息，不影响同步判定。
- 订阅还支持内嵌 `code` 字段直接写 JS 文本、以及 `enabled: false` 默认关闭，格式细节见 `docs/source_subscription.md`。
- 同步规则（客户端侧）：云端新增→本地新增；云端改 JS→本地更新并清缓存；云端删除→本地删除；本地登录配置按声明的字段保留。
