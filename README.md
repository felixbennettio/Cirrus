<p align="center">
  <img src="assets/branding/cirrus_256.png" width="112" alt="Cirrus icon">
</p>

<h1 align="center">Cirrus · 卷云</h1>

<p align="center">
  快速、原生的跨平台 Cloudflare API 客户端<br>
  <b>Linux · Windows · macOS · Android · iOS</b>
</p>

<p align="center">
  <a href="#中文">中文</a> · <a href="#english">English</a>
</p>

> Cirrus 是**非官方**客户端，与 Cloudflare, Inc. 没有任何关联。"Cloudflare" 是 Cloudflare, Inc. 的商标。
> Cirrus is an **unofficial** client and is not affiliated with Cloudflare, Inc.

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="server/internal/app/static/shots/zh-Hans/home-dark.webp">
    <img src="server/internal/app/static/shots/zh-Hans/home.webp" width="68%" alt="桌面版 / Desktop">
  </picture>
  <img src="server/internal/app/static/shots/en/i-home.webp" width="19%" alt="iPhone 原生版 / iPhone app">
</p>

---

## 中文

卷云是飞得最高、最轻的云。Cirrus 用 API Token 或 Global API Key 直接调用 `api.cloudflare.com`，不经过任何中间服务器。它就是为"官方面板加载太慢"这个问题做的：

- **秒开**：账户和域名列表会缓存在本地，启动时直接显示，后台再刷新。所有列表都可以搜索；按 `Ctrl/⌘ + K` 打开命令面板，能跳到任意页面、域名、账户或 API 接口。
- **覆盖全部 API**：常用功能都有专门设计的界面；其余的 **3647 个接口**全部可以在内置的 API 控制台里浏览和调用。参数表单和请求体模板都由官方 OpenAPI 规范自动生成。
- **原生体验**：桌面端用侧边栏，手机端用抽屉导航；支持深色模式和中英双语；凭据存放在系统钥匙串里，还可以开启生物识别应用锁。

### 功能一览

| 范围 | 功能 |
|---|---|
| **域名** | 添加、删除、暂停域名；名称服务器检查；开发模式；"正在遭受攻击"模式 |
| **DNS** | 支持全部 21 种记录类型，各有专门表单；一键切换代理（橙云）；按名称、内容、备注、标签搜索；批量删除；BIND 文件导入导出；DNSSEC；DNS 设置 |
| **SSL/TLS** | 加密模式、HSTS、最低 TLS 版本、TLS 1.3；边缘证书与高级证书订购；**Origin CA 证书**（私钥和 CSR 在本机生成）；自定义证书；客户端证书 |
| **安全** | WAF 自定义规则、托管规则、限速规则（规则可拖拽排序）；安全事件；IP 访问规则；机器人管理；UA 拦截；区域锁定 |
| **规则** | 重定向、URL 重写、请求头和响应头转换、配置规则、源站规则、缓存规则、压缩、自定义错误、日志字段；页面规则（旧版）；托管转换；URL 标准化 |
| **缓存** | 按 URL、主机名、标签、前缀清除缓存，或全部清除；缓存级别与 TTL；分层缓存；Cache Reserve；Argo |
| **域名设置** | 动态列出全部约 60 项设置，按速度、网络、安全等分组 |
| **分析** | 24 小时、7 天、30 天的请求、带宽、缓存率、威胁、状态码、国家分布（GraphQL） |
| **Workers** | 在线编辑代码并部署（支持多模块）；从模板创建；环境变量、绑定、Secrets；自定义域名、路由、Cron；版本与回滚；**实时日志（tail）**；指标 |
| **Pages** | 项目、部署、构建日志、重试、回滚；自定义域名；构建设置和环境变量 |
| **存储** | KV（键浏览、编辑、批量删除）；R2（目录浏览、上传下载、预览、CORS、生命周期、r2.dev 公开访问、自定义域名）；D1（SQL 控制台、表浏览、查询历史）；Queues；Hyperdrive；Vectorize；Secrets Store |
| **Zero Trust** | Tunnels（创建隧道、安装命令、**公共主机名编辑器并自动创建 DNS 记录**、私有网络路由、连接）；Access 应用、策略、组、服务令牌、身份提供商、访问日志；Gateway 策略、列表、位置；WARP 设备、配置文件、拆分隧道、设备态势；DLP；DEX |
| **AI** | Workers AI 对话、文生图、全部模型的调用；AI Gateway |
| **账户** | 成员与角色；API Token（带权限选择的创建向导、轮换）；审计日志；列表与批量重定向；通知；域名注册；Turnstile；负载均衡；Images、Stream；Logpush 等 |
| **工具** | **API 控制台**（可调用全部接口，支持 cURL 导出、收藏和历史记录）；GraphQL 查询器（带模板）；请求日志 |

### 应用截图

截图使用演示数据，与[官网](https://cirrus.routeforge.zone)相同。「iPhone 原生版」是 `apple/` 里用 SwiftUI 重写的 iOS/macOS 版（正在 TestFlight 测试），其余是 Flutter 版。

点击缩略图查看原图。

<details open>
<summary><b>总览</b></summary>
<table>
<tr>
<td width="33%" align="center"><a href="server/internal/app/static/shots/zh-Hans/home.webp"><img src="server/internal/app/static/shots/zh-Hans/home-t.webp" width="100%" alt="账户首页与快捷入口"></a><br><sub>账户首页与快捷入口</sub></td>
<td width="33%" align="center"><a href="server/internal/app/static/shots/zh-Hans/home-dark.webp"><img src="server/internal/app/static/shots/zh-Hans/home-dark-t.webp" width="100%" alt="深色模式"></a><br><sub>深色模式</sub></td>
<td width="33%" align="center"><a href="server/internal/app/static/shots/zh-Hans/domains.webp"><img src="server/internal/app/static/shots/zh-Hans/domains-t.webp" width="100%" alt="全部域名一览"></a><br><sub>全部域名一览</sub></td>
</tr>
<tr>
<td width="33%" align="center"><a href="server/internal/app/static/shots/zh-Hans/zone.webp"><img src="server/internal/app/static/shots/zh-Hans/zone-t.webp" width="100%" alt="域名概览"></a><br><sub>域名概览</sub></td>
<td width="33%" align="center"><a href="server/internal/app/static/shots/zh-Hans/analytics.webp"><img src="server/internal/app/static/shots/zh-Hans/analytics-t.webp" width="100%" alt="流量分析"></a><br><sub>流量分析</sub></td>
<td width="33%" align="center"><a href="server/internal/app/static/shots/zh-Hans/phone.webp"><img src="server/internal/app/static/shots/zh-Hans/phone-t.webp" width="100%" alt="手机版"></a><br><sub>手机版</sub></td>
</tr>
</table>
</details>

<details>
<summary><b>域名：DNS、SSL 与规则</b></summary>
<table>
<tr>
<td width="33%" align="center"><a href="server/internal/app/static/shots/zh-Hans/dns.webp"><img src="server/internal/app/static/shots/zh-Hans/dns-t.webp" width="100%" alt="DNS 记录"></a><br><sub>DNS 记录</sub></td>
<td width="33%" align="center"><a href="server/internal/app/static/shots/zh-Hans/dns-dark.webp"><img src="server/internal/app/static/shots/zh-Hans/dns-dark-t.webp" width="100%" alt="深色模式下的 DNS"></a><br><sub>深色模式下的 DNS</sub></td>
<td width="33%" align="center"><a href="server/internal/app/static/shots/zh-Hans/ssl.webp"><img src="server/internal/app/static/shots/zh-Hans/ssl-t.webp" width="100%" alt="SSL/TLS 与证书"></a><br><sub>SSL/TLS 与证书</sub></td>
</tr>
<tr>
<td width="33%" align="center"><a href="server/internal/app/static/shots/zh-Hans/security.webp"><img src="server/internal/app/static/shots/zh-Hans/security-t.webp" width="100%" alt="安全与 WAF"></a><br><sub>安全与 WAF</sub></td>
<td width="33%" align="center"><a href="server/internal/app/static/shots/zh-Hans/rules.webp"><img src="server/internal/app/static/shots/zh-Hans/rules-t.webp" width="100%" alt="规则"></a><br><sub>规则</sub></td>
<td width="33%" align="center"><a href="server/internal/app/static/shots/zh-Hans/cache.webp"><img src="server/internal/app/static/shots/zh-Hans/cache-t.webp" width="100%" alt="缓存"></a><br><sub>缓存</sub></td>
</tr>
<tr>
<td width="33%" align="center"><a href="server/internal/app/static/shots/zh-Hans/zone-settings.webp"><img src="server/internal/app/static/shots/zh-Hans/zone-settings-t.webp" width="100%" alt="域名设置"></a><br><sub>域名设置</sub></td>
<td width="33%" align="center"><a href="server/internal/app/static/shots/zh-Hans/email.webp"><img src="server/internal/app/static/shots/zh-Hans/email-t.webp" width="100%" alt="邮件路由"></a><br><sub>邮件路由</sub></td>
<td width="33%" align="center"><a href="server/internal/app/static/shots/zh-Hans/zone-more.webp"><img src="server/internal/app/static/shots/zh-Hans/zone-more-t.webp" width="100%" alt="更多域名功能"></a><br><sub>更多域名功能</sub></td>
</tr>
</table>
</details>

<details>
<summary><b>Workers、Pages 与 AI</b></summary>
<table>
<tr>
<td width="33%" align="center"><a href="server/internal/app/static/shots/zh-Hans/workers.webp"><img src="server/internal/app/static/shots/zh-Hans/workers-t.webp" width="100%" alt="Workers"></a><br><sub>Workers</sub></td>
<td width="33%" align="center"><a href="server/internal/app/static/shots/zh-Hans/worker.webp"><img src="server/internal/app/static/shots/zh-Hans/worker-t.webp" width="100%" alt="Worker 详情与代码"></a><br><sub>Worker 详情与代码</sub></td>
<td width="33%" align="center"><a href="server/internal/app/static/shots/zh-Hans/worker-bindings.webp"><img src="server/internal/app/static/shots/zh-Hans/worker-bindings-t.webp" width="100%" alt="Worker 绑定与变量"></a><br><sub>Worker 绑定与变量</sub></td>
</tr>
<tr>
<td width="33%" align="center"><a href="server/internal/app/static/shots/zh-Hans/pages.webp"><img src="server/internal/app/static/shots/zh-Hans/pages-t.webp" width="100%" alt="Pages 项目"></a><br><sub>Pages 项目</sub></td>
<td width="33%" align="center"><a href="server/internal/app/static/shots/zh-Hans/pages-project.webp"><img src="server/internal/app/static/shots/zh-Hans/pages-project-t.webp" width="100%" alt="Pages 部署记录"></a><br><sub>Pages 部署记录</sub></td>
<td width="33%" align="center"><a href="server/internal/app/static/shots/zh-Hans/ai.webp"><img src="server/internal/app/static/shots/zh-Hans/ai-t.webp" width="100%" alt="Workers AI"></a><br><sub>Workers AI</sub></td>
</tr>
</table>
</details>

<details>
<summary><b>存储</b></summary>
<table>
<tr>
<td width="33%" align="center"><a href="server/internal/app/static/shots/zh-Hans/kv.webp"><img src="server/internal/app/static/shots/zh-Hans/kv-t.webp" width="100%" alt="KV 命名空间"></a><br><sub>KV 命名空间</sub></td>
<td width="33%" align="center"><a href="server/internal/app/static/shots/zh-Hans/kv-keys.webp"><img src="server/internal/app/static/shots/zh-Hans/kv-keys-t.webp" width="100%" alt="KV 键值"></a><br><sub>KV 键值</sub></td>
<td width="33%" align="center"><a href="server/internal/app/static/shots/zh-Hans/r2.webp"><img src="server/internal/app/static/shots/zh-Hans/r2-t.webp" width="100%" alt="R2 存储桶"></a><br><sub>R2 存储桶</sub></td>
</tr>
<tr>
<td width="33%" align="center"><a href="server/internal/app/static/shots/zh-Hans/r2-bucket.webp"><img src="server/internal/app/static/shots/zh-Hans/r2-bucket-t.webp" width="100%" alt="浏览 R2 存储桶"></a><br><sub>浏览 R2 存储桶</sub></td>
<td width="33%" align="center"><a href="server/internal/app/static/shots/zh-Hans/d1.webp"><img src="server/internal/app/static/shots/zh-Hans/d1-t.webp" width="100%" alt="D1 数据库"></a><br><sub>D1 数据库</sub></td>
<td width="33%" align="center"><a href="server/internal/app/static/shots/zh-Hans/d1-db.webp"><img src="server/internal/app/static/shots/zh-Hans/d1-db-t.webp" width="100%" alt="查询 D1 数据库"></a><br><sub>查询 D1 数据库</sub></td>
</tr>
</table>
</details>

<details>
<summary><b>Zero Trust</b></summary>
<table>
<tr>
<td width="33%" align="center"><a href="server/internal/app/static/shots/zh-Hans/tunnels.webp"><img src="server/internal/app/static/shots/zh-Hans/tunnels-t.webp" width="100%" alt="隧道"></a><br><sub>隧道</sub></td>
<td width="33%" align="center"><a href="server/internal/app/static/shots/zh-Hans/tunnel.webp"><img src="server/internal/app/static/shots/zh-Hans/tunnel-t.webp" width="100%" alt="隧道详情"></a><br><sub>隧道详情</sub></td>
<td width="33%" align="center"><a href="server/internal/app/static/shots/zh-Hans/zt-networks.webp"><img src="server/internal/app/static/shots/zh-Hans/zt-networks-t.webp" width="100%" alt="私有网络"></a><br><sub>私有网络</sub></td>
</tr>
<tr>
<td width="33%" align="center"><a href="server/internal/app/static/shots/zh-Hans/access.webp"><img src="server/internal/app/static/shots/zh-Hans/access-t.webp" width="100%" alt="Access 应用"></a><br><sub>Access 应用</sub></td>
<td width="33%" align="center"><a href="server/internal/app/static/shots/zh-Hans/gateway.webp"><img src="server/internal/app/static/shots/zh-Hans/gateway-t.webp" width="100%" alt="Gateway 策略"></a><br><sub>Gateway 策略</sub></td>
<td width="33%" align="center"><a href="server/internal/app/static/shots/zh-Hans/devices.webp"><img src="server/internal/app/static/shots/zh-Hans/devices-t.webp" width="100%" alt="WARP 设备"></a><br><sub>WARP 设备</sub></td>
</tr>
</table>
</details>

<details>
<summary><b>账户管理</b></summary>
<table>
<tr>
<td width="33%" align="center"><a href="server/internal/app/static/shots/zh-Hans/members.webp"><img src="server/internal/app/static/shots/zh-Hans/members-t.webp" width="100%" alt="成员"></a><br><sub>成员</sub></td>
<td width="33%" align="center"><a href="server/internal/app/static/shots/zh-Hans/tokens.webp"><img src="server/internal/app/static/shots/zh-Hans/tokens-t.webp" width="100%" alt="API Token"></a><br><sub>API Token</sub></td>
<td width="33%" align="center"><a href="server/internal/app/static/shots/zh-Hans/tokens-dark.webp"><img src="server/internal/app/static/shots/zh-Hans/tokens-dark-t.webp" width="100%" alt="深色模式下的 API Token"></a><br><sub>深色模式下的 API Token</sub></td>
</tr>
<tr>
<td width="33%" align="center"><a href="server/internal/app/static/shots/zh-Hans/audit.webp"><img src="server/internal/app/static/shots/zh-Hans/audit-t.webp" width="100%" alt="审计日志"></a><br><sub>审计日志</sub></td>
<td width="33%" align="center"><a href="server/internal/app/static/shots/zh-Hans/lists.webp"><img src="server/internal/app/static/shots/zh-Hans/lists-t.webp" width="100%" alt="规则列表"></a><br><sub>规则列表</sub></td>
<td width="33%" align="center"><a href="server/internal/app/static/shots/zh-Hans/account-more.webp"><img src="server/internal/app/static/shots/zh-Hans/account-more-t.webp" width="100%" alt="更多账户功能"></a><br><sub>更多账户功能</sub></td>
</tr>
</table>
</details>

<details>
<summary><b>开发者工具</b></summary>
<table>
<tr>
<td width="33%" align="center"><a href="server/internal/app/static/shots/zh-Hans/console.webp"><img src="server/internal/app/static/shots/zh-Hans/console-t.webp" width="100%" alt="包含 3600 多个接口的 API 控制台"></a><br><sub>包含 3600 多个接口的 API 控制台</sub></td>
<td width="33%" align="center"><a href="server/internal/app/static/shots/zh-Hans/console-dark.webp"><img src="server/internal/app/static/shots/zh-Hans/console-dark-t.webp" width="100%" alt="深色模式下的 API 控制台"></a><br><sub>深色模式下的 API 控制台</sub></td>
<td width="33%" align="center"><a href="server/internal/app/static/shots/zh-Hans/graphql.webp"><img src="server/internal/app/static/shots/zh-Hans/graphql-t.webp" width="100%" alt="GraphQL 查询"></a><br><sub>GraphQL 查询</sub></td>
</tr>
<tr>
<td width="33%" align="center"><a href="server/internal/app/static/shots/zh-Hans/requests.webp"><img src="server/internal/app/static/shots/zh-Hans/requests-t.webp" width="100%" alt="API 请求记录"></a><br><sub>API 请求记录</sub></td>
<td width="33%" align="center"><a href="server/internal/app/static/shots/zh-Hans/palette.webp"><img src="server/internal/app/static/shots/zh-Hans/palette-t.webp" width="100%" alt="命令面板（Ctrl/⌘ + K）"></a><br><sub>命令面板（Ctrl/⌘ + K）</sub></td>
<td width="33%" align="center"><a href="server/internal/app/static/shots/zh-Hans/palette-dark.webp"><img src="server/internal/app/static/shots/zh-Hans/palette-dark-t.webp" width="100%" alt="深色模式下的命令面板"></a><br><sub>深色模式下的命令面板</sub></td>
</tr>
</table>
</details>

<details>
<summary><b>手机版</b></summary>
<table>
<tr>
<td width="33%" align="center"><a href="server/internal/app/static/shots/zh-Hans/m-home.webp"><img src="server/internal/app/static/shots/zh-Hans/m-home-t.webp" width="200" alt="手机上的首页"></a><br><sub>手机上的首页</sub></td>
<td width="33%" align="center"><a href="server/internal/app/static/shots/zh-Hans/m-home-dark.webp"><img src="server/internal/app/static/shots/zh-Hans/m-home-dark-t.webp" width="200" alt="手机上的深色模式"></a><br><sub>手机上的深色模式</sub></td>
<td width="33%" align="center"><a href="server/internal/app/static/shots/zh-Hans/m-dns.webp"><img src="server/internal/app/static/shots/zh-Hans/m-dns-t.webp" width="200" alt="手机上的 DNS"></a><br><sub>手机上的 DNS</sub></td>
</tr>
<tr>
<td width="33%" align="center"><a href="server/internal/app/static/shots/zh-Hans/m-zone.webp"><img src="server/internal/app/static/shots/zh-Hans/m-zone-t.webp" width="200" alt="手机上的域名概览"></a><br><sub>手机上的域名概览</sub></td>
<td width="33%" align="center"><a href="server/internal/app/static/shots/zh-Hans/m-drawer.webp"><img src="server/internal/app/static/shots/zh-Hans/m-drawer-t.webp" width="200" alt="导航菜单"></a><br><sub>导航菜单</sub></td>
<td width="33%" align="center"><a href="server/internal/app/static/shots/zh-Hans/m-drawer-dark.webp"><img src="server/internal/app/static/shots/zh-Hans/m-drawer-dark-t.webp" width="200" alt="深色模式下的导航菜单"></a><br><sub>深色模式下的导航菜单</sub></td>
</tr>
</table>
</details>

<details>
<summary><b>iPhone 原生版</b></summary>
<table>
<tr>
<td width="33%" align="center"><a href="server/internal/app/static/shots/en/i-home.webp"><img src="server/internal/app/static/shots/en/i-home-t.webp" width="200" alt="Liquid Glass 风格的首页"></a><br><sub>Liquid Glass 风格的首页</sub></td>
<td width="33%" align="center"><a href="server/internal/app/static/shots/en/i-zone.webp"><img src="server/internal/app/static/shots/en/i-zone-t.webp" width="200" alt="域名的全部功能"></a><br><sub>域名的全部功能</sub></td>
<td width="33%" align="center"><a href="server/internal/app/static/shots/en/i-ai.webp"><img src="server/internal/app/static/shots/en/i-ai-t.webp" width="200" alt="Workers AI 模型"></a><br><sub>Workers AI 模型</sub></td>
</tr>
</table>
</details>

<details>
<summary><b>登录与设置</b></summary>
<table>
<tr>
<td width="33%" align="center"><a href="server/internal/app/static/shots/zh-Hans/welcome.webp"><img src="server/internal/app/static/shots/zh-Hans/welcome-t.webp" width="100%" alt="使用 Cloudflare 账户或 API Token 登录"></a><br><sub>使用 Cloudflare 账户或 API Token 登录</sub></td>
<td width="33%" align="center"><a href="server/internal/app/static/shots/zh-Hans/profile.webp"><img src="server/internal/app/static/shots/zh-Hans/profile-t.webp" width="100%" alt="添加凭据"></a><br><sub>添加凭据</sub></td>
<td width="33%" align="center"><a href="server/internal/app/static/shots/zh-Hans/settings.webp"><img src="server/internal/app/static/shots/zh-Hans/settings-t.webp" width="100%" alt="设置、主题与动态取色"></a><br><sub>设置、主题与动态取色</sub></td>
</tr>
</table>
</details>

### 下载与安装

请从 [Releases](../../releases) 下载对应平台的安装包：

| 平台 | 文件 | 说明 |
|---|---|---|
| Windows | `*-windows-x64-setup.exe` / `*-portable.zip` | 安装包未签名，SmartScreen 弹出提示时选"更多信息 → 仍要运行" |
| macOS | `*-macos-universal.dmg` | 同时支持 Apple Silicon 和 Intel。未经公证，首次打开请右键选"打开"，或运行 `xattr -dr com.apple.quarantine /Applications/Cirrus.app` |
| Linux | `.AppImage` / `.deb` / `.tar.gz` | 需要 GTK 3。凭据存在 Secret Service（GNOME Keyring 或 KWallet）中；如果没有，会存到仅当前用户可读的文件，并在设置页给出提示 |
| Android | `*-android-arm64-v8a.apk`（多数手机）/ `universal.apk` | 需要 Android 7.0 及以上 |
| iOS | `*-ios-unsigned.ipa` | 没有签名，需要用 AltStore、Sideloadly、TrollStore 或自己的证书侧载安装 |

### 凭据与权限

- **推荐使用 Cloudflare 账户登录（OAuth）**：点击"使用 Cloudflare 账户登录"，在浏览器里选择账户并同意授权即可，不用复制任何 Token。Cirrus 采用授权码 + PKCE 方式，不内置客户端密钥；访问令牌会自动续期，移除凭据时会撤销授权。
- **API Token**：在 [My Profile → API Tokens](https://dash.cloudflare.com/profile/api-tokens) 创建，按需勾选权限。如果用的是账户 Token，验证失败时可以在"高级选项"里填写账户 ID。
- 也支持 **Global API Key + 邮箱**，以及专门用于 `/certificates` 接口的 **Origin CA Key**。
- 可以保存多套凭据并随时切换。凭据只保存在本机系统钥匙串中：Keychain、Android Keystore、Windows Credential Manager 或 libsecret。
- 某个页面提示"权限不足"时，会同时列出该接口需要的 Token 权限组，这些信息来自官方 OpenAPI 规范的 `x-api-token-group` 字段。

### 从源码构建

```bash
# Flutter 3.47.6（Dart 3.13）
flutter pub get
flutter run -d linux        # 或 macos / windows / android / ios
flutter test

# 更新内置的 API 目录（从官方 OpenAPI 规范生成）
dart run tool/build_catalog.dart
```

Linux 构建需要 `clang cmake ninja-build pkg-config libgtk-3-dev libsecret-1-dev`。

### 发布流程

推送 `v*` 格式的 tag（例如 `git tag v0.2.0 && git push origin v0.2.0`）就会触发 Forgejo Actions 的 [Release 工作流](.forgejo/workflows/release.yml)。它会：

1. 用最新的官方 OpenAPI 规范重新生成 API 目录；
2. 构建全部 5 个平台；
3. 附上 `SHA256SUMS.txt`，在 Forgejo 上创建 Release。

**Android 正式签名**（可选，强烈建议）：先生成 keystore，再在仓库的 *设置 → Actions → 密钥* 中添加下面几个 secrets：

```bash
keytool -genkey -v -keystore release.jks -keyalg RSA -keysize 4096 -validity 10000 -alias cirrus
base64 -w0 release.jks   # 把输出填进 ANDROID_KEYSTORE_BASE64
```

| Secret | 内容 |
|---|---|
| `ANDROID_KEYSTORE_BASE64` | keystore 的 base64 |
| `ANDROID_KEYSTORE_PASSWORD` | keystore 密码 |
| `ANDROID_KEY_ALIAS` | 别名，例如 `cirrus` |
| `ANDROID_KEY_PASSWORD` | key 密码（与 keystore 相同时可以不填） |

如果没有配置这些 secrets，APK 会用 CI 临时生成的调试密钥签名，每次构建的签名都不同，升级前需要先卸载旧版。

### 配置 OAuth 客户端

"使用 Cloudflare 账户登录"需要先在 Cloudflare 创建一个 OAuth 客户端，再把客户端 ID 写进构建：

1. 在 Cloudflare 面板打开 **Manage Account → OAuth clients → Create client**：
   - Response type：`code`；Grant types：`authorization_code`、`refresh_token`
   - Token authentication method：`none`（PKCE，无需客户端密钥）
   - Redirect URLs 两个都要填：`http://127.0.0.1/oauth/callback`（Windows/Linux，端口任意）和 `https://cirrus.routeforge.zone/oauth/callback`（iOS/Android/macOS：Cloudflare 只接受 http(s) 回调，这个网页再把授权结果交回 App）
   - Scopes：勾选 Cirrus 需要的权限。可用 Scope 的 ID 可以在 Cirrus 的 API 控制台里调用 `GET /oauth/scopes` 查看
2. 新建的客户端默认是**私有**的，只有本账户成员能授权。要给所有用户使用，需要补全 Logo 和客户端网址，通过域名 TXT 验证后改为**公开**（改为公开后不能改回私有）。
3. 在 GitHub 仓库的 *Settings → Secrets and variables → Actions → Variables* 中添加：
   - `CIRRUS_OAUTH_CLIENT_ID`：客户端 ID
   - `CIRRUS_OAUTH_SCOPES`：Scope ID，用空格分隔（不需要写 `offline_access`，应用会自动加上）

本地构建时，用 `--dart-define=CIRRUS_OAUTH_CLIENT_ID=... --dart-define=CIRRUS_OAUTH_SCOPES="..."` 传入。没有配置时，"使用 Cloudflare 账户登录"按钮不可用，用户也可以在"使用自己的 OAuth 客户端"中填写自己创建的私有客户端。

### Cirrus Pro（应用内购买）

应用商店版本提供一次性买断的 **Cirrus Pro**（不是订阅）：

- **免费功能**：域名管理全部功能，包括 DNS、SSL/TLS、安全与 WAF、规则、缓存、域名设置、7 天以内的分析，以及 API 控制台的只读请求。
- **Pro 解锁**：
  - Workers、Pages、Workers AI；
  - KV、R2、D1 等存储服务；
  - Zero Trust；
  - 账户管理（成员、API Token、审计日志等）；
  - GraphQL 查询；
  - API 控制台写请求；
  - 30 天分析；
  - 保存多套凭据。
- 免费和 Pro 的划分集中定义在 `lib/features/pro/pro_features.dart`。

| 项目 | 设置 |
|---|---|
| 商品 ID | `cirrus_pro_lifetime`（App Store 和 Google Play 都使用这个 ID） |
| App Store Connect | 类型选"非消耗型"，价格 US$39.99 / ¥198；与 iOS、macOS 共用一个 App 记录（Bundle ID `io.felixbennett.cirrus`，通用购买） |
| Google Play Console | 一次性商品，价格 US$39.99；Google Play 在中国大陆不可用 |

- **实现**：使用 `in_app_purchase`（iOS/macOS 上是 StoreKit 2，Android 上是 Play Billing）。应用启动时会静默恢复已购项目，购买完成后在本机记住，离线也能用。设置页和付费墙都提供"恢复购买"。
- **什么时候生效**：只有在构建时设置 `--dart-define=CIRRUS_STORE=appstore`（iOS/macOS）或 `play`（Android）才会启用 Pro。CI 中对应的是 `build.yml` 的 `store_build: true`。Release 工作流的构建和 Windows/Linux 版本不设置，所有功能直接可用。
- **许可证版本**：在应用商店以外销售的 Windows、Linux、Android 版本用 `--dart-define=CIRRUS_STORE=license` 构建，Pro 通过在网站购买的许可证密钥激活（`lib/core/licensing`，协议见 `docs/licensing.md`）。正式服务器 `https://cirrus.routeforge.zone` 的 Ed25519 公钥已内置；换服务器时用 `CIRRUS_LICENSE_SERVER` 和 `CIRRUS_LICENSE_PUBKEY`（标准 base64）覆盖。
- **防 DNS 污染**：应用访问自家服务器（`routeforge.zone` 及其子域名，例如许可证服务器）时不用系统 DNS，而是依次用腾讯云 HTTPDNS（HTTPS 接口）、阿里 DNS（223.5.5.5 / 223.6.6.6，HTTPS JSON 接口）解析，都失败时才用系统 DNS（`lib/core/net/secure_dns.dart`）。证书仍按域名校验，所以错误的解析结果只会导致连接失败，不会把请求带到别处。用 `CIRRUS_HTTPDNS_DOMAINS`（逗号分隔）和 `CIRRUS_HTTPDNS_TOKEN`（腾讯云 HTTPDNS 控制台的 HTTPS Token，留空则跳过腾讯云）覆盖。Cloudflare API 和浏览器打开的网页不受影响。
- **测试**：
  - Apple：在 App Store Connect 添加沙盒测试员，用 TestFlight 或开发版本购买。
  - Google：在 Play Console 中添加许可测试人员，并把应用上传到内部测试轨道。

### 架构

```
lib/
  core/api        Cloudflare 客户端：解析返回结构、分页、重试、GraphQL、导出 cURL、解析 multipart
  core/auth       凭据配置与验证（OAuth、API Token、Global Key、Origin CA Key）
  core/catalog    由 OpenAPI 规范生成的接口目录：解析 $ref、搜索、生成请求体模板
  core/session    当前凭据、账户、域名（Riverpod）
  ui/             自适应外壳、命令面板，以及根据 schema 自动生成表单、JSON 树、代码编辑器等组件
  features/       各功能模块；generic/ 用声明式规格驱动几十种资源的增删改查
tool/build_catalog.dart   OpenAPI 规范 → assets/api/catalog.json.gz（约 630 KB）
```

`test/features/specs_test.dart` 会核对每个声明式资源规格：引用的每个接口和 HTTP 方法都必须真实存在于官方 API 目录中。

---

## English

Cirrus is a fast, native client for the Cloudflare API on **Linux, Windows, macOS, Android and iOS**. It calls `api.cloudflare.com` directly with your API token or Global API Key, with no intermediate server.

- **Instant**: accounts and zones are cached locally and shown at once, then refreshed in the background. `Ctrl/⌘ + K` jumps to any page, zone, account or API endpoint.
- **The whole API**: polished screens for DNS, SSL/TLS, WAF and rules, caching, zone settings, analytics, Workers (editor, deploy, bindings, secrets, triggers, versions, **live tail**), Pages, KV, R2, D1, Queues, Hyperdrive, Vectorize, Tunnels (ingress editor), Access, Gateway, WARP devices, Workers AI, members, API tokens, audit logs, lists and more. Every remaining endpoint (**3,647 in total**) is available in the built-in **API console**, with forms and body templates generated from the official OpenAPI schema.
- **Native**: sidebar on desktop, drawer on phones, dark mode, English and Simplified Chinese, credentials in the system keychain, and an optional biometric app lock.

**Screenshots** (demo data, the same as on the [website](https://cirrus.routeforge.zone)). "iPhone app" is the SwiftUI rewrite for iOS and macOS in `apple/`, now in TestFlight; the rest is the Flutter app.

Select a thumbnail to view the full-size image.

<details open>
<summary><b>Overview</b></summary>
<table>
<tr>
<td width="33%" align="center"><a href="server/internal/app/static/shots/en/home.webp"><img src="server/internal/app/static/shots/en/home-t.webp" width="100%" alt="Account home with quick actions"></a><br><sub>Account home with quick actions</sub></td>
<td width="33%" align="center"><a href="server/internal/app/static/shots/en/home-dark.webp"><img src="server/internal/app/static/shots/en/home-dark-t.webp" width="100%" alt="Dark mode"></a><br><sub>Dark mode</sub></td>
<td width="33%" align="center"><a href="server/internal/app/static/shots/en/domains.webp"><img src="server/internal/app/static/shots/en/domains-t.webp" width="100%" alt="All your zones at a glance"></a><br><sub>All your zones at a glance</sub></td>
</tr>
<tr>
<td width="33%" align="center"><a href="server/internal/app/static/shots/en/zone.webp"><img src="server/internal/app/static/shots/en/zone-t.webp" width="100%" alt="Zone overview"></a><br><sub>Zone overview</sub></td>
<td width="33%" align="center"><a href="server/internal/app/static/shots/en/analytics.webp"><img src="server/internal/app/static/shots/en/analytics-t.webp" width="100%" alt="Traffic analytics"></a><br><sub>Traffic analytics</sub></td>
<td width="33%" align="center"><a href="server/internal/app/static/shots/en/phone.webp"><img src="server/internal/app/static/shots/en/phone-t.webp" width="100%" alt="On your phone"></a><br><sub>On your phone</sub></td>
</tr>
</table>
</details>

<details>
<summary><b>Zones: DNS, SSL and rules</b></summary>
<table>
<tr>
<td width="33%" align="center"><a href="server/internal/app/static/shots/en/dns.webp"><img src="server/internal/app/static/shots/en/dns-t.webp" width="100%" alt="DNS records"></a><br><sub>DNS records</sub></td>
<td width="33%" align="center"><a href="server/internal/app/static/shots/en/dns-dark.webp"><img src="server/internal/app/static/shots/en/dns-dark-t.webp" width="100%" alt="DNS in dark mode"></a><br><sub>DNS in dark mode</sub></td>
<td width="33%" align="center"><a href="server/internal/app/static/shots/en/ssl.webp"><img src="server/internal/app/static/shots/en/ssl-t.webp" width="100%" alt="SSL/TLS and certificates"></a><br><sub>SSL/TLS and certificates</sub></td>
</tr>
<tr>
<td width="33%" align="center"><a href="server/internal/app/static/shots/en/security.webp"><img src="server/internal/app/static/shots/en/security-t.webp" width="100%" alt="Security and WAF"></a><br><sub>Security and WAF</sub></td>
<td width="33%" align="center"><a href="server/internal/app/static/shots/en/rules.webp"><img src="server/internal/app/static/shots/en/rules-t.webp" width="100%" alt="Rules"></a><br><sub>Rules</sub></td>
<td width="33%" align="center"><a href="server/internal/app/static/shots/en/cache.webp"><img src="server/internal/app/static/shots/en/cache-t.webp" width="100%" alt="Caching"></a><br><sub>Caching</sub></td>
</tr>
<tr>
<td width="33%" align="center"><a href="server/internal/app/static/shots/en/zone-settings.webp"><img src="server/internal/app/static/shots/en/zone-settings-t.webp" width="100%" alt="Zone settings"></a><br><sub>Zone settings</sub></td>
<td width="33%" align="center"><a href="server/internal/app/static/shots/en/email.webp"><img src="server/internal/app/static/shots/en/email-t.webp" width="100%" alt="Email Routing"></a><br><sub>Email Routing</sub></td>
<td width="33%" align="center"><a href="server/internal/app/static/shots/en/zone-more.webp"><img src="server/internal/app/static/shots/en/zone-more-t.webp" width="100%" alt="More zone features"></a><br><sub>More zone features</sub></td>
</tr>
</table>
</details>

<details>
<summary><b>Workers, Pages and AI</b></summary>
<table>
<tr>
<td width="33%" align="center"><a href="server/internal/app/static/shots/en/workers.webp"><img src="server/internal/app/static/shots/en/workers-t.webp" width="100%" alt="Workers"></a><br><sub>Workers</sub></td>
<td width="33%" align="center"><a href="server/internal/app/static/shots/en/worker.webp"><img src="server/internal/app/static/shots/en/worker-t.webp" width="100%" alt="Worker details and code"></a><br><sub>Worker details and code</sub></td>
<td width="33%" align="center"><a href="server/internal/app/static/shots/en/worker-bindings.webp"><img src="server/internal/app/static/shots/en/worker-bindings-t.webp" width="100%" alt="Worker bindings and variables"></a><br><sub>Worker bindings and variables</sub></td>
</tr>
<tr>
<td width="33%" align="center"><a href="server/internal/app/static/shots/en/pages.webp"><img src="server/internal/app/static/shots/en/pages-t.webp" width="100%" alt="Pages projects"></a><br><sub>Pages projects</sub></td>
<td width="33%" align="center"><a href="server/internal/app/static/shots/en/pages-project.webp"><img src="server/internal/app/static/shots/en/pages-project-t.webp" width="100%" alt="Pages deployments"></a><br><sub>Pages deployments</sub></td>
<td width="33%" align="center"><a href="server/internal/app/static/shots/en/ai.webp"><img src="server/internal/app/static/shots/en/ai-t.webp" width="100%" alt="Workers AI"></a><br><sub>Workers AI</sub></td>
</tr>
</table>
</details>

<details>
<summary><b>Storage</b></summary>
<table>
<tr>
<td width="33%" align="center"><a href="server/internal/app/static/shots/en/kv.webp"><img src="server/internal/app/static/shots/en/kv-t.webp" width="100%" alt="KV namespaces"></a><br><sub>KV namespaces</sub></td>
<td width="33%" align="center"><a href="server/internal/app/static/shots/en/kv-keys.webp"><img src="server/internal/app/static/shots/en/kv-keys-t.webp" width="100%" alt="KV keys and values"></a><br><sub>KV keys and values</sub></td>
<td width="33%" align="center"><a href="server/internal/app/static/shots/en/r2.webp"><img src="server/internal/app/static/shots/en/r2-t.webp" width="100%" alt="R2 buckets"></a><br><sub>R2 buckets</sub></td>
</tr>
<tr>
<td width="33%" align="center"><a href="server/internal/app/static/shots/en/r2-bucket.webp"><img src="server/internal/app/static/shots/en/r2-bucket-t.webp" width="100%" alt="Browsing an R2 bucket"></a><br><sub>Browsing an R2 bucket</sub></td>
<td width="33%" align="center"><a href="server/internal/app/static/shots/en/d1.webp"><img src="server/internal/app/static/shots/en/d1-t.webp" width="100%" alt="D1 databases"></a><br><sub>D1 databases</sub></td>
<td width="33%" align="center"><a href="server/internal/app/static/shots/en/d1-db.webp"><img src="server/internal/app/static/shots/en/d1-db-t.webp" width="100%" alt="Querying a D1 database"></a><br><sub>Querying a D1 database</sub></td>
</tr>
</table>
</details>

<details>
<summary><b>Zero Trust</b></summary>
<table>
<tr>
<td width="33%" align="center"><a href="server/internal/app/static/shots/en/tunnels.webp"><img src="server/internal/app/static/shots/en/tunnels-t.webp" width="100%" alt="Tunnels"></a><br><sub>Tunnels</sub></td>
<td width="33%" align="center"><a href="server/internal/app/static/shots/en/tunnel.webp"><img src="server/internal/app/static/shots/en/tunnel-t.webp" width="100%" alt="Tunnel details"></a><br><sub>Tunnel details</sub></td>
<td width="33%" align="center"><a href="server/internal/app/static/shots/en/zt-networks.webp"><img src="server/internal/app/static/shots/en/zt-networks-t.webp" width="100%" alt="Private networks"></a><br><sub>Private networks</sub></td>
</tr>
<tr>
<td width="33%" align="center"><a href="server/internal/app/static/shots/en/access.webp"><img src="server/internal/app/static/shots/en/access-t.webp" width="100%" alt="Access applications"></a><br><sub>Access applications</sub></td>
<td width="33%" align="center"><a href="server/internal/app/static/shots/en/gateway.webp"><img src="server/internal/app/static/shots/en/gateway-t.webp" width="100%" alt="Gateway policies"></a><br><sub>Gateway policies</sub></td>
<td width="33%" align="center"><a href="server/internal/app/static/shots/en/devices.webp"><img src="server/internal/app/static/shots/en/devices-t.webp" width="100%" alt="WARP devices"></a><br><sub>WARP devices</sub></td>
</tr>
</table>
</details>

<details>
<summary><b>Account</b></summary>
<table>
<tr>
<td width="33%" align="center"><a href="server/internal/app/static/shots/en/members.webp"><img src="server/internal/app/static/shots/en/members-t.webp" width="100%" alt="Members"></a><br><sub>Members</sub></td>
<td width="33%" align="center"><a href="server/internal/app/static/shots/en/tokens.webp"><img src="server/internal/app/static/shots/en/tokens-t.webp" width="100%" alt="API tokens"></a><br><sub>API tokens</sub></td>
<td width="33%" align="center"><a href="server/internal/app/static/shots/en/tokens-dark.webp"><img src="server/internal/app/static/shots/en/tokens-dark-t.webp" width="100%" alt="API tokens in dark mode"></a><br><sub>API tokens in dark mode</sub></td>
</tr>
<tr>
<td width="33%" align="center"><a href="server/internal/app/static/shots/en/audit.webp"><img src="server/internal/app/static/shots/en/audit-t.webp" width="100%" alt="Audit log"></a><br><sub>Audit log</sub></td>
<td width="33%" align="center"><a href="server/internal/app/static/shots/en/lists.webp"><img src="server/internal/app/static/shots/en/lists-t.webp" width="100%" alt="Lists for rules"></a><br><sub>Lists for rules</sub></td>
<td width="33%" align="center"><a href="server/internal/app/static/shots/en/account-more.webp"><img src="server/internal/app/static/shots/en/account-more-t.webp" width="100%" alt="More account features"></a><br><sub>More account features</sub></td>
</tr>
</table>
</details>

<details>
<summary><b>Developer tools</b></summary>
<table>
<tr>
<td width="33%" align="center"><a href="server/internal/app/static/shots/en/console.webp"><img src="server/internal/app/static/shots/en/console-t.webp" width="100%" alt="API console with 3,600+ endpoints"></a><br><sub>API console with 3,600+ endpoints</sub></td>
<td width="33%" align="center"><a href="server/internal/app/static/shots/en/console-dark.webp"><img src="server/internal/app/static/shots/en/console-dark-t.webp" width="100%" alt="API console in dark mode"></a><br><sub>API console in dark mode</sub></td>
<td width="33%" align="center"><a href="server/internal/app/static/shots/en/graphql.webp"><img src="server/internal/app/static/shots/en/graphql-t.webp" width="100%" alt="GraphQL explorer"></a><br><sub>GraphQL explorer</sub></td>
</tr>
<tr>
<td width="33%" align="center"><a href="server/internal/app/static/shots/en/requests.webp"><img src="server/internal/app/static/shots/en/requests-t.webp" width="100%" alt="API request history"></a><br><sub>API request history</sub></td>
<td width="33%" align="center"><a href="server/internal/app/static/shots/en/palette.webp"><img src="server/internal/app/static/shots/en/palette-t.webp" width="100%" alt="Command palette (Ctrl/⌘ + K)"></a><br><sub>Command palette (Ctrl/⌘ + K)</sub></td>
<td width="33%" align="center"><a href="server/internal/app/static/shots/en/palette-dark.webp"><img src="server/internal/app/static/shots/en/palette-dark-t.webp" width="100%" alt="Command palette in dark mode"></a><br><sub>Command palette in dark mode</sub></td>
</tr>
</table>
</details>

<details>
<summary><b>On your phone</b></summary>
<table>
<tr>
<td width="33%" align="center"><a href="server/internal/app/static/shots/en/m-home.webp"><img src="server/internal/app/static/shots/en/m-home-t.webp" width="200" alt="Home on a phone"></a><br><sub>Home on a phone</sub></td>
<td width="33%" align="center"><a href="server/internal/app/static/shots/en/m-home-dark.webp"><img src="server/internal/app/static/shots/en/m-home-dark-t.webp" width="200" alt="Dark mode on a phone"></a><br><sub>Dark mode on a phone</sub></td>
<td width="33%" align="center"><a href="server/internal/app/static/shots/en/m-dns.webp"><img src="server/internal/app/static/shots/en/m-dns-t.webp" width="200" alt="DNS on a phone"></a><br><sub>DNS on a phone</sub></td>
</tr>
<tr>
<td width="33%" align="center"><a href="server/internal/app/static/shots/en/m-zone.webp"><img src="server/internal/app/static/shots/en/m-zone-t.webp" width="200" alt="Zone overview on a phone"></a><br><sub>Zone overview on a phone</sub></td>
<td width="33%" align="center"><a href="server/internal/app/static/shots/en/m-drawer.webp"><img src="server/internal/app/static/shots/en/m-drawer-t.webp" width="200" alt="Navigation menu"></a><br><sub>Navigation menu</sub></td>
<td width="33%" align="center"><a href="server/internal/app/static/shots/en/m-drawer-dark.webp"><img src="server/internal/app/static/shots/en/m-drawer-dark-t.webp" width="200" alt="Navigation menu in dark mode"></a><br><sub>Navigation menu in dark mode</sub></td>
</tr>
</table>
</details>

<details>
<summary><b>iPhone app</b></summary>
<table>
<tr>
<td width="33%" align="center"><a href="server/internal/app/static/shots/en/i-home.webp"><img src="server/internal/app/static/shots/en/i-home-t.webp" width="200" alt="Home with Liquid Glass"></a><br><sub>Home with Liquid Glass</sub></td>
<td width="33%" align="center"><a href="server/internal/app/static/shots/en/i-zone.webp"><img src="server/internal/app/static/shots/en/i-zone-t.webp" width="200" alt="Everything for a zone"></a><br><sub>Everything for a zone</sub></td>
<td width="33%" align="center"><a href="server/internal/app/static/shots/en/i-ai.webp"><img src="server/internal/app/static/shots/en/i-ai-t.webp" width="200" alt="Workers AI models"></a><br><sub>Workers AI models</sub></td>
</tr>
</table>
</details>

<details>
<summary><b>Sign-in and settings</b></summary>
<table>
<tr>
<td width="33%" align="center"><a href="server/internal/app/static/shots/en/welcome.webp"><img src="server/internal/app/static/shots/en/welcome-t.webp" width="100%" alt="Sign in with Cloudflare or an API token"></a><br><sub>Sign in with Cloudflare or an API token</sub></td>
<td width="33%" align="center"><a href="server/internal/app/static/shots/en/profile.webp"><img src="server/internal/app/static/shots/en/profile-t.webp" width="100%" alt="Adding a credential"></a><br><sub>Adding a credential</sub></td>
<td width="33%" align="center"><a href="server/internal/app/static/shots/en/settings.webp"><img src="server/internal/app/static/shots/en/settings-t.webp" width="100%" alt="Settings, themes and dynamic colour"></a><br><sub>Settings, themes and dynamic colour</sub></td>
</tr>
</table>
</details>

**Install:** grab a build from [Releases](../../releases). Desktop and iOS builds are unsigned; see the table in the Chinese section above for per-platform notes. Android release signing uses the `ANDROID_*` repository secrets described above.

**Sign-in:** "Sign in with Cloudflare" uses Cloudflare OAuth (authorization code + PKCE, no client secret): pick the account in the browser and approve; tokens refresh automatically and the grant is revoked when the credential is removed. To enable it, create an OAuth client under *Manage Account → OAuth clients* with grant types `authorization_code` + `refresh_token`, token auth method `none`, redirect URLs `http://127.0.0.1/oauth/callback` and `https://cirrus.routeforge.zone/oauth/callback` (the website page hands the result to the iOS/Android/macOS app), then set the repository variables `CIRRUS_OAUTH_CLIENT_ID` and `CIRRUS_OAUTH_SCOPES` (space-separated scope IDs). API tokens and the Global API Key still work.

**Cirrus Pro:** store builds (`--dart-define=CIRRUS_STORE=appstore|play`, or `store_build: true` in `build.yml`) sell a one-time, non-consumable `cirrus_pro_lifetime` (US$39.99 / ¥198) through StoreKit 2 and Play Billing. Zone management stays free. Workers, Pages, AI, storage, Zero Trust, account administration, GraphQL, console writes, 30-day analytics and multiple credentials need Pro. Purchases are restored silently on launch. Builds without a store flag (the Release workflow's, Windows, Linux) have everything unlocked. Windows, Linux and Android builds sold outside the stores use `CIRRUS_STORE=license`: Pro is unlocked with a licence key bought on the website (`lib/core/licensing`, contract in `docs/licensing.md`). The public key of the production server (`https://cirrus.routeforge.zone`) is built in; override both with `CIRRUS_LICENSE_SERVER` and `CIRRUS_LICENSE_PUBKEY` (standard base64) for another server. Names under `routeforge.zone` (Cirrus's own servers) are resolved over HTTPS instead of the system resolver, which some networks poison: Tencent Cloud HTTPDNS, then AliDNS (223.5.5.5), then the system resolver as a last resort (`lib/core/net/secure_dns.dart`; override with `CIRRUS_HTTPDNS_DOMAINS` and `CIRRUS_HTTPDNS_TOKEN`). Certificates are still verified against the host name.

**Build:** `flutter pub get && flutter run`. Regenerate the API catalog with `dart run tool/build_catalog.dart`. Push a `v*` tag to build all platforms and publish a release.
