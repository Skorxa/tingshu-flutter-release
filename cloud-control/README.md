# 橘听云控部署

这套服务用于小范围分发橘听。它由 Cloudflare Worker、D1、私有 R2 和一个管理后台组成，提供邀请码激活、设备绑定、用户/设备禁用、会话撤销，以及私有音源订阅下载。

当前正式入口：

```text
服务地址：https://jt.966001.xyz/
管理后台：https://jt.966001.xyz/admin/
订阅链接：https://jt.966001.xyz/api/subscription
```

订阅链接不是公开下载地址，只有已激活并通过设备签名验证的橘听客户端可以读取。

## 安全边界

- APK 不保存 R2 密钥、GitHub Token 或所有用户共用的授权密码。
- 每台 Android 设备在 Android Keystore 中生成不可导出的 P-256 私钥。
- Access Token 必须和设备签名同时使用，复制 Token 到另一台手机无效。
- 每个请求包含时间戳和一次性 nonce，Worker 会阻止过期请求和重放。
- R2 存储桶必须保持私有，只允许 Worker 读取。
- 管理后台推荐放在 Cloudflare Access 后面，密码登录仅作为备用入口。

这不是不可破解的 DRM。修改过的 APK 可以绕过本地界面门禁，但没有有效设备授权仍无法通过 Worker 下载私有订阅和音源文件。已授权且取得系统 root 权限的设备仍可能提取 App 本地保存的数据。

## 1. 准备工程

```powershell
cd cloud-control
npm install
npx wrangler login
```

## 2. 创建 D1 和 R2

```powershell
npx wrangler d1 create juting-cloud-control
npx wrangler r2 bucket create juting-private
```

把 D1 创建命令输出的 `database_id` 填入 [wrangler.toml](wrangler.toml)；不要修改绑定名 `DB` 和 `PRIVATE_BUCKET`。

执行远程迁移：

```powershell
npm run db:migrate:remote
```

## 3. 设置服务密钥

至少设置下面两个 Secret：

```powershell
npx wrangler secret put ADMIN_SESSION_SECRET
npx wrangler secret put ADMIN_PASSWORD
```

`ADMIN_SESSION_SECRET` 建议使用至少 32 字节的随机值。`ADMIN_PASSWORD` 仅供没有 Cloudflare Access 时备用登录，不能使用应用邀请码或 R2 密钥。

使用 Cloudflare Access 时，在 `wrangler.toml` 的 `ADMIN_EMAILS` 中填写允许登录的邮箱，多个邮箱以逗号分隔。然后在 Zero Trust 中创建 Self-hosted 应用，保护以下路径：

```text
你的 Worker 域名/admin*
```

## 4. 管理私有音源

部署后可直接在管理后台的“云端音源”页面完成以下操作：

- 选择一个或多个 `.js` 文件上传，同名文件会覆盖。
- 删除 R2 中的音源文件，并同步从订阅清单移除。
- 查看订阅版本、清单数量、R2 文件数量和更新时间。
- 复制受保护的订阅链接 `/api/subscription`。

上传或删除后，Worker 会自动递增订阅清单的 `version`。App 检查到版本变化后才会重新同步，不需要手动编辑版本号。R2 存储桶保持私有，复制出的订阅链接仍需有效的橘听设备授权。

也可以继续使用 Wrangler 批量上传。项目现有订阅产物位于：

```text
build/source-subscription/sources.json
build/source-subscription/sources/*.js
```

清单中的相对地址为 `sources/文件名.js`。Worker 会把它映射到 `/api/sources/文件名.js`，因此 R2 对象应按下面的结构保存：

```text
sources/subscription.json
sources/files/*.js
```

上传清单：

```powershell
npx wrangler r2 object put "juting-private/sources/subscription.json" `
  --file "../build/source-subscription/sources.json" `
  --content-type "application/json; charset=utf-8" `
  --remote
```

批量上传 JS：

```powershell
Get-ChildItem "../build/source-subscription/sources" -Filter *.js | ForEach-Object {
  npx wrangler r2 object put "juting-private/sources/files/$($_.Name)" `
    --file $_.FullName `
    --content-type "text/javascript; charset=utf-8" `
    --remote
}
```

通过 Wrangler 直接覆盖清单时，需要自行提高 `sources.json` 的 `version`。通过 Web UI 管理时会自动完成。

## 5. 云控配置

“云控配置”页面始终显示一份有效配置。首次部署会写入以下默认值：

```json
{
  "appEnabled": true,
  "appDisabledMessage": "服务维护中，请稍后再试",
  "subscriptionEnabled": true,
  "subscriptionDisabledMessage": "云端音源暂时停止更新"
}
```

- `appEnabled`：关闭后，激活、刷新和授权状态接口返回 `403`，客户端显示停用原因。
- `subscriptionEnabled`：关闭后，仅订阅清单和音源文件接口返回 `503`，已有授权不受影响。
- 两个消息字段分别控制客户端看到的维护提示。

可以继续在该 JSON 中保存其他业务字段；Worker 会保留未知字段，并严格校验上述内置字段的类型。

## 6. 部署和初始化

```powershell
npm run typecheck
npm run deploy
```

部署后检查：

```text
https://你的域名/health
https://你的域名/admin
```

进入管理后台后创建邀请码。邀请码默认一次性使用；激活后，用户和设备会显示在管理页面中。禁用用户、禁用设备或撤销会话后，后续受保护请求会立即返回 `403` 或 `401`。

## 7. 构建 Android 发行包

发行包必须写入 HTTPS Worker 地址：

```powershell
flutter build apk --release --target-platform android-arm64 `
  --dart-define=CLOUD_CONTROL_URL=https://你的Worker域名 `
  --dart-define=CLOUD_CONTROL_REQUIRED=true
```

未提供 `CLOUD_CONTROL_URL` 的受控发行包会停在“授权服务未配置”页面，不会进入应用。仅在明确需要无授权开发包时使用：

```powershell
flutter build apk --debug `
  --dart-define=CLOUD_CONTROL_REQUIRED=false
```

## 本地开发

复制 `.dev.vars.example` 为 `.dev.vars`，填入仅供本地使用的管理密钥，然后运行：

```powershell
npm run db:migrate:local
npm run dev
```

Android 模拟器访问宿主机 Worker 时可使用：

```powershell
flutter run `
  --dart-define=CLOUD_CONTROL_URL=http://10.0.2.2:8787 `
  --dart-define=CLOUD_CONTROL_REQUIRED=true
```

Debug 模式只允许 `localhost`、`127.0.0.1` 和 `10.0.2.2` 使用 HTTP；发行包只接受 HTTPS。
