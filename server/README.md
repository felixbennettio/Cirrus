# 卷云 Cirrus 许可证服务器与销售网站

为 Windows、Linux 和直接下载安装的 Android 版 Cirrus 出售并校验 Pro 许可证。App Store 和 Google Play 版本仍使用应用内购买，与本服务无关。

与 App 之间的约定（产品、许可证格式、设备标识、激活令牌、全部 API）见仓库根目录的 [`docs/licensing.md`](../docs/licensing.md)，两边必须一起修改。

**部署请直接看 [DEPLOY.md](DEPLOY.md)**：那是给有 SSH 权限的人或 AI 助手逐步执行的部署手册。

## 架构

```
浏览器 / Cirrus App
        │ HTTPS
        ▼
1Panel OpenResty（cirrus.routeforge.zone，证书、HTTP→HTTPS）
        │ http://127.0.0.1:8790
        ▼
cirrus-license 容器（:8080，非 root，内存上限 128 MB）
  ├─ 网站：/  /buy  /license  /privacy  /terms  /support（中英双语，无外部 CDN）
  ├─ API：/api/v1/…（激活、校验、停用、重置、订单、OAuth 配置）
  ├─ 管理后台：/admin（HTTP Basic）
  └─ 支付通知：/pay/alipay/notify、/pay/wechat/notify
        │
        ▼
./data（挂载到 /data）
  ├─ signing.key   Ed25519 签名私钥（务必备份）
  ├─ cirrus.db     SQLite（WAL）：licenses、activations、orders、events
  ├─ pay/alipay.png、pay/wechat.png   静态收款码
  └─ backups/      cirrus-license backup 生成的数据库备份
```

- 单个 Go 静态二进制（约 13 MB），纯 Go SQLite，无 CGO；运行时内存约 20 MB。
- 网站的 CSS、JS、图标全部内置，字体使用系统字体，不加载任何外部资源。
- 每个 POST 接口按 IP 限流（令牌桶，内存有上限，空闲自动清理），`/reset`、`/orders`、`/resend` 更严格；IP 取自反向代理的 `X-Real-IP` / `X-Forwarded-For`。

### 收款方式

| 方式 | 说明 | 确认收款 |
| --- | --- | --- |
| 静态收款码（默认） | 页面显示你的支付宝/微信收款码、准确金额和订单号，买家付款时在备注里填订单号 | 你在 `/admin` 点“确认收款”，立即签发许可证 |
| 支付宝电脑网站支付（`ALIPAY_MODE=page`） | 跳转到支付宝收银台；手机浏览器自动使用手机网站支付（`alipay.trade.wap.pay`） | 支付宝异步通知，自动签发 |
| 支付宝当面付（`ALIPAY_MODE=precreate`） | 页面显示动态付款二维码 | 支付宝异步通知，自动签发 |
| 微信支付 Native 支付（`WECHAT_*` 全部填写） | 页面显示动态付款二维码（`weixin://wxpay/…`），用微信扫码 | 微信支付通知（APIv3），自动签发 |

`PAY_METHODS` 仍然决定购买页显示哪些方式。启用支付宝或微信支付 API 后，如果调用失败且存在对应的 `data/pay/*.png`，会自动退回静态收款码。后台“订单”页顶部显示每种方式当前使用的模式。

订单有效期：静态收款码 24 小时，支付宝和微信支付 API 2 小时。过期后买家页面显示“已过期”；如果确实收到了款，仍然可以在后台确认。

## 配置

全部通过环境变量（`.env` 文件）配置，示例和说明见 [`.env.example`](.env.example)。

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `LISTEN` | `:8080` | 监听地址。Docker 部署时不要改 |
| `DATA_DIR` | `/data` | 数据目录。Docker 部署时不要改 |
| `PUBLIC_URL` | `https://cirrus.routeforge.zone` | 对外网址，用于支付宝通知地址、邮件链接、后台同源检查 |
| `TRUST_PROXY` | `true` | 采信 `X-Real-IP` / `X-Forwarded-For`（仅当直接连接来自本机或内网地址） |
| `CLIENT_IP_HEADER` | 空 | 网站前还有 CDN 时，CDN 放客户端 IP 的请求头（EdgeOne：`EO-Connecting-IP`），优先于 `X-Real-IP`；同样只在 `TRUST_PROXY` 开启且直接连接来自本机或内网时采信 |
| `ADMIN_PASSWORD` | 空 | `/admin` 密码，用户名 `admin`；为空则关闭后台 |
| `SITE_NAME` | `卷云 Cirrus` | 网站名称 |
| `OPERATOR_NAME` | 空 | 运营者（个体户名称），显示在页脚和法律文本中 |
| `CONTACT_EMAIL` | 空 | 客服邮箱 |
| `ICP_NUMBER` | 空 | ICP 备案号，显示在每页页脚并链接到 beian.miit.gov.cn |
| `POLICY_EFFECTIVE_DATE` | `2026-10-06` | 隐私政策和用户协议的生效日期 |
| `APP_STORE_URL` | 空 | 可选，App Store 地址（iPhone、iPad、Mac），显示在首页和下载页；未设置时首页显示“即将上架” |
| `GOOGLE_PLAY_URL` | 空 | 可选，Google Play 地址（Android），显示在首页和下载页；未设置时首页显示“即将上架” |
| `DOWNLOAD_URL_WINDOWS` / `_MACOS` / `_LINUX` / `_ANDROID` | 空 | 放在别处的安装包链接。本站 `data/downloads/manifest.json` 里有该平台的文件时以它为准（见 DEPLOY.md“发布下载文件”）；都没有的平台不显示 |
| `DOWNLOAD_VERSION`、`DOWNLOAD_VERSION_<平台>` | 空 | 上面链接的版本号 |
| `DOWNLOAD_SHA256_<平台>` | 空 | 上面链接的 SHA-256 |
| `DOWNLOAD_URL` | 空 | 可选，“全部下载”链接（例如 GitHub Releases），也用于没有单独下载的平台的许可证邮件 |
| `PRODUCTS` | `windows,macos,linux,android` | 在售产品；下架的产品不再出售，已售许可证照常使用 |
| `PRICE_CNY` | `198` | 默认人民币价格。后台“价格”页设置的价格优先 |
| `PRICE_USD` | `39.99` | 美元参考价（仅显示） |
| `PRICE_CNY_WINDOWS` / `_MACOS` / `_LINUX` / `_ANDROID` | 同 `PRICE_CNY` | 按产品覆盖默认价格 |
| `PRICE_USD_WINDOWS` / `_MACOS` / `_LINUX` / `_ANDROID` | 同 `PRICE_USD` | 按产品覆盖美元参考价 |
| `MAX_DEVICES_WINDOWS` / `_MACOS` / `_LINUX` / `_ANDROID` | `1` / `1` / `1` / `1` | 每个许可证的设备数，只影响之后签发的许可证 |
| `PAY_METHODS` | `alipay,wechat` | 购买页提供的付款方式 |
| `ALIPAY_APP_ID` | 空 | 支付宝开放平台 APPID |
| `ALIPAY_PRIVATE_KEY` | 空 | **应用私钥** |
| `ALIPAY_PUBLIC_KEY` | 空 | **支付宝公钥**（不是应用公钥） |
| `ALIPAY_MODE` | `precreate` | `page` = 电脑网站支付，`precreate` = 当面付 |
| `ALIPAY_GATEWAY` | `https://openapi.alipay.com/gateway.do` | 沙箱：`https://openapi-sandbox.dl.alipaydev.com/gateway.do` |
| `WECHAT_MCHID` | 空 | 微信支付商户号 |
| `WECHAT_APPID` | 空 | 与商户号绑定的 AppID（服务号或小程序） |
| `WECHAT_API_V3_KEY` | 空 | APIv3 密钥（32 个字符） |
| `WECHAT_CERT_SERIAL` | 空 | 商户 API 证书序列号 |
| `WECHAT_PRIVATE_KEY` | 空 | 商户 API 私钥 `apiclient_key.pem`（PEM、带字面量 `\n` 的 PEM，或去掉头尾的 base64） |
| `WECHAT_PUBLIC_KEY` | 空 | **微信支付公钥**（不是平台证书），格式同上 |
| `WECHAT_PUBLIC_KEY_ID` | 空 | 微信支付公钥 ID，`PUB_KEY_ID_…` |
| `WECHAT_GATEWAY` | `https://api.mch.weixin.qq.com` | 微信支付 API 地址 |
| `OAUTH_CLIENT_ID` | `9c147a5155baf903357222bd4d31ad50` | App 使用的 Cloudflare OAuth 客户端 |
| `OAUTH_SCOPES` | 空 | 权限范围，空格或逗号分隔；没有自动同步结果时使用 |
| `OAUTH_OPTIONAL_SCOPES` | 空 | 可选权限范围 |
| `CF_ACCOUNT_ID` | 空 | 自动同步权限范围：OAuth 客户端所在的 Cloudflare 账户 ID |
| `CF_API_TOKEN` | 空 | 自动同步用的 API 令牌（Bearer），或改用下面两项 |
| `CF_API_EMAIL` / `CF_API_KEY` | 空 | 自动同步用的 Global API Key 和账户邮箱 |
| `SMTP_HOST` | 空 | 填写后启用邮件 |
| `SMTP_PORT` | `465` | 465 = SSL（隐式 TLS）；其他端口用 STARTTLS。腾讯云封禁 25 端口 |
| `SMTP_USER` / `SMTP_PASS` | 空 | SMTP 账号密码 |
| `SMTP_FROM` | 同 `SMTP_USER` | 发件人，如 `卷云 Cirrus <noreply@routeforge.zone>` |

构建参数（由 docker compose 读取，不传给程序）：`ALPINE_MIRROR`（如 `mirrors.tencent.com`），`GOPROXY`（仅源码构建，国内用 `https://goproxy.cn,direct`）。镜像内固定 `TZ=Asia/Shanghai`、`GOMEMLIMIT=96MiB`。

### 支付宝的三个密钥值不要填错

- `ALIPAY_PRIVATE_KEY` = **应用私钥**：用“支付宝开放平台密钥工具”生成，只保存在服务器上。
- `ALIPAY_PUBLIC_KEY` = **支付宝公钥**：把“应用公钥”上传到开放平台后，平台显示的“支付宝公钥”。**不是应用公钥。**
- 只支持“公钥模式”加签（不是“证书模式”），RSA2。
- 两个值都可以直接粘贴密钥工具导出的一整行 base64（不带 `-----BEGIN` 头），也可以是 PEM（多行时用字面量 `\n` 连成一行）。

### 微信支付的密钥值

- 7 个 `WECHAT_*` 变量（除 `WECHAT_GATEWAY`）必须全部填写，只填一部分会拒绝启动。
- `WECHAT_PRIVATE_KEY` 是商户 API 证书的私钥 `apiclient_key.pem`；`WECHAT_CERT_SERIAL` 是同一张证书的序列号。
- `WECHAT_PUBLIC_KEY` / `WECHAT_PUBLIC_KEY_ID` 是商户平台“API 安全 → 微信支付公钥”里的公钥文件和公钥 ID。只支持公钥模式，不支持“平台证书”。
- 通知地址 `https://cirrus.routeforge.zone/pay/wechat/notify` 每次下单时自动传给微信，无需在商户平台配置。开通步骤见 DEPLOY.md 第 13 节。

### Cloudflare OAuth 权限范围

App 在“使用 Cloudflare 登录”前请求 `GET /api/v1/oauth/config`，按返回的 `scopes` 申请权限，所以在 Cloudflare 修改 OAuth 客户端的权限后不需要发布新版 App。配置了 `CF_ACCOUNT_ID` 和 API 凭据时，服务器从 Cloudflare API 读取该客户端的 `scopes` / `optional_scopes`（缓存 1 小时，失败时继续用上次的结果），否则使用 `OAUTH_SCOPES`。凭据只用于读取，不会出现在响应或日志中。见 DEPLOY.md 第 14 节。

### 支付宝产品选择

应该开通哪个产品：网站销售对应的正规产品是 **电脑网站支付**（再加开手机网站支付，手机用户体验更好）；**当面付** 通常更容易审核通过，可以作为备选。两者使用同一个异步通知地址 `https://cirrus.routeforge.zone/pay/alipay/notify`（每次下单时自动传给支付宝，无需在后台配置）。开通步骤见 DEPLOY.md 第 12 节。

## 收款码图片

把收款码保存为 PNG，放到：

- `data/pay/alipay.png`：支付宝收款码
- `data/pay/wechat.png`：微信收款码

无需重启。缺少图片的方式在购买页显示为“暂不可用”。请确认收款码付款时可以填写备注。

## 管理后台

打开 `https://cirrus.routeforge.zone/admin`，用户名 `admin`，密码为 `ADMIN_PASSWORD`。

- **订单**：待付款订单排在最前。核对手机上的收款记录（金额和备注里的订单号）后点“确认收款”，系统签发许可证，配置了邮件时同时发给买家；也可以取消订单。
- **许可证**：按许可证（可只输入一部分）、邮箱、订单号搜索；查看设备、事件记录；吊销/恢复、释放全部设备、移除单台设备、重新发送邮件、备注。
- **手动签发**：选择产品、填写邮箱和备注即可签发，用于赠送或补发。
- **价格**：逐个产品修改人民币价格和美元参考价，保存后网站和新订单立即使用；“恢复默认”回到 `.env` 里的价格。价格保存在数据库里，升级不会丢失；已创建的订单保持下单时的金额。

后台的每个 POST 都有 CSRF 保护（同源检查 + Cookie 令牌）。连续输错密码 10 次后，该 IP 会被暂时拒绝。

## 网站语言与截图

网站有六种语言：English、Français、日本語、Русский、简体中文、繁體中文，右上角的地球按钮切换。语言的选择顺序：`?lang=`（记在 Cookie 里）→ Cookie → 浏览器的 `Accept-Language` → English；旧链接里的 `lang=zh` 仍然有效。API 的错误信息按请求的 `Accept-Language` 返回，网页脚本会带上当前页面的语言；许可证邮件使用下单时的语言，并附英文。后台只有简体中文。

- 文案在 `internal/i18n/<语言>.go`，按 id 查找；改动或新增文案时六种语言都要写，`go test` 会检查是否齐全、占位符是否一致。
- 隐私政策和用户协议在 `internal/app/templates/legal/<页面>.<语言>.html`，以简体中文版为准，其他语言版本开头注明这一点。
- 首页的应用截图在 `internal/app/static/shots/<语言>/`，用 `scripts/gallery_images.py` 从 PNG 生成（只用演示数据，不要用真实账户）。某种语言没有自己的截图时用英文截图；中文页面还会用另一种中文的截图。
- 截图里的数据来自仓库根目录的 `scripts/demo_api.py`（模拟 Cloudflare API 的演示数据）。桌面版和手机布局用 `scripts/screenshots/batch.sh` 在 Linux（Xvfb）下拍摄，环境要求写在脚本开头；iPhone 截图用 GitHub Actions 的 Screenshots 工作流在 GitHub 托管的 Mac 上拍摄（iOS 模拟器需要 Metal 显卡，自托管的 Mac 虚拟机没有）。

## 签名密钥：务必备份

首次启动时程序会生成 `data/signing.key`（Ed25519 种子，hex，权限 0600），并在日志中打印公钥。公钥同时可以通过 `/api/v1/pubkey` 或 `cirrus-license pubkey` 获得，需要写进 App 构建（`CIRRUS_LICENSE_PUBKEY`）。

**一定要把 `data/signing.key` 备份到服务器以外的安全位置。** 丢失后，服务器会生成新的密钥，已经发布的 App 无法验证新签发的激活令牌，所有用户都无法激活，只能发布内置新公钥的 App 版本。程序永远不会覆盖已存在的密钥文件；文件损坏时会拒绝启动。

## 备份

- `data/signing.key`：只需备份一次（不会变）。
- 数据库：可以在服务运行时执行
  `docker compose exec -T cirrus-license cirrus-license backup`
  生成 `data/backups/cirrus-时间.db`（一致性快照，基于 SQLite `VACUUM INTO`）。建议每天执行并复制到服务器以外，见 DEPLOY.md 第 9 节。
- `.env`：包含密码和密钥，单独妥善保存。

恢复：停止服务，把备份文件复制为 `data/cirrus.db`（同时删除 `cirrus.db-wal` 和 `cirrus.db-shm`），`chown 10001:10001`，再启动。

## 升级

用新的部署包替换 `bin/` 等文件（保留 `.env` 和 `data/`），然后 `docker compose up -d --build`。数据库结构会自动迁移。升级前先备份数据库；详细步骤和回滚见 DEPLOY.md 第 10 节。

## API 概览

完整约定见 `docs/licensing.md`。

| 方法与路径 | 说明 |
| --- | --- |
| `POST /api/v1/activate` | 激活 |
| `POST /api/v1/deactivate` | 停用 |
| `POST /api/v1/validate` | 校验（`active` / `not_activated` / `revoked`） |
| `POST /api/v1/reset` | 自助释放全部设备（邮箱验证，30 天一次） |
| `GET /api/v1/pubkey` | Ed25519 公钥 |
| `POST /api/v1/orders` | 创建订单 |
| `GET /api/v1/orders/{order_no}?token=` | 查询订单 |
| `GET /api/v1/orders/{order_no}/qr.png?token=` | 当面付 / 微信 Native 动态二维码图片 |
| `GET /api/v1/oauth/config` | App 登录用的 Cloudflare OAuth 客户端 ID 和权限范围（缓存 5 分钟） |
| `POST /api/v1/resend` | 把该邮箱的全部许可证重新发到邮箱（需 SMTP；无论邮箱是否存在都返回相同结果） |
| `POST /pay/alipay/notify` | 支付宝异步通知（表单，验签后返回 `success`） |
| `POST /pay/wechat/notify` | 微信支付通知（JSON，验签并解密，成功返回 200 空响应，失败返回 4xx/5xx `{"code":"FAIL"}`） |
| `GET /healthz` | 健康检查 |

## 开发

```bash
cd server
go test ./...                 # 单元测试与 HTTP 测试（含测试向量、支付宝和微信支付签名、OAuth 同步、管理后台）
go vet ./...
./build-bundle.sh             # 交叉编译 amd64/arm64 静态二进制并打包到 dist/
```

本地运行：

```bash
DATA_DIR=./data LISTEN=127.0.0.1:8080 PUBLIC_URL=http://127.0.0.1:8080 ADMIN_PASSWORD=dev go run ./cmd/cirrus-license
./deploy/smoke-test.sh http://127.0.0.1:8080 dev   # 需要 data/pay/alipay.png
```

源码构建镜像：`docker compose up -d --build`（使用多阶段 `Dockerfile`；国内可在 `.env` 中设置 `GOPROXY=https://goproxy.cn,direct`）。

目录：`cmd/cirrus-license`（入口）、`internal/license`（许可证格式与令牌）、`internal/store`（SQLite）、`internal/pay`（收款）、`internal/app`（HTTP、网站、后台）、`internal/ratelimit`、`internal/mailer`、`internal/config`、`deploy/`（部署包文件）。
