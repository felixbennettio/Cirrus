# 卷云 Cirrus：开通支付宝、微信支付自动收款（交给本地 Claude 执行）

> **给机主（你）的说明**：新版部署包 `cirrus-license-<版本>.tar.gz` 里已经带着这份文件。把部署包交给本地能用浏览器、能 SSH 到服务器的 Claude，对它说：
> 「请完整阅读 PAYMENT_SETUP.md，按顺序执行。遇到需要我本人操作（扫码、人脸、短信验证、签署协议、付款）的地方停下来叫我。」
>
> 做完后，让它把文末「交付结果」那一节填好发给云端的 Claude。**任何私钥、APIv3 密钥、Global API Key 都不要发出来。**

---

## 给本地 Claude 的任务说明

你在帮机主（个体工商户，网站备案主体相同）开通支付宝和微信支付的 API 收款，让 https://cirrus.routeforge.zone 的许可证订单付款后自动确认、自动发放许可证。

你能用的东西：

- 机主电脑上已登录的浏览器：支付宝商家平台、支付宝开放平台、微信支付商户平台；
- SSH 登录服务器 `124.221.77.85`。许可证服务装在 `/opt/cirrus-license`，用 docker compose 运行，配置在 `/opt/cirrus-license/.env`，部署说明在 `/opt/cirrus-license/DEPLOY.md`；
- 本机的 `openssl`、`curl`。

### 必须遵守

1. **密钥只进服务器的 `.env`**。私钥、支付宝公钥、APIv3 密钥、证书私钥、Cloudflare 密钥都不能出现在聊天、截图、日志、命令行历史或 git 里。写入 `.env` 时用编辑器或 `cat > … <<'EOF'`，写完 `chmod 600 .env`。本地生成的密钥文件放在机主指定的安全位置，完成后提醒机主备份到密码管理器。
2. 改 `.env` 之前先备份：`cp .env .env.bak.$(date +%Y%m%d%H%M%S)`。
3. **不要改动**服务器上其他网站、容器和 1Panel 设置；routeforge.zone 上的 Wiki 必须保持原样。
4. 遇到以下操作，**停下来请机主本人完成**：
   - 扫码登录、人脸识别、短信或邮箱验证码；
   - 签署协议、勾选承诺书；
   - 填写或修改银行账户和证件信息；
   - 任何真实付款。
5. 平台界面和本文菜单名称不一致时，按字面意思找最接近的入口。拿不准的时候截图给机主确认，不要猜着提交。
6. 每一步做完都记录结果，用于最后的「交付结果」。

### 第 0 步：升级服务器

服务器必须先升级到新版部署包，否则不支持微信支付 API 和权限范围同步。

1. 按 `/opt/cirrus-license/DEPLOY.md` 第 10 节「升级与回滚」升级。升级前先备份数据库。
2. 确认新版正常：

```bash
curl -s https://cirrus.routeforge.zone/healthz     # 应为 ok
```

3. 网站现在经过腾讯云 EdgeOne（`cirrus.routeforge.zone` 解析到 `*.eo.dnse2.com`）。按 `DEPLOY.md` 第 15 节「网站前面有 CDN（腾讯云 EdgeOne）时」做完三件事：
   - `.env` 设置 `CLIENT_IP_HEADER=EO-Connecting-IP`；
   - EdgeOne 规则引擎里 `/api/*`、`/pay/*`、`/admin*`、`/license*`、`/buy*`、`/oauth/*` 不缓存；
   - `/pay/alipay/notify`、`/pay/wechat/notify` 跳过 Bot / CC 质询。
   
   EdgeOne 控制台需要登录腾讯云。没有登录就停下来请机主登录。改规则前截图原设置，改完再截图。第 15 节末尾的验证命令必须全部通过。**这一步不做，付款后的自动发货可能收不到通知。**

---

## 第一部分：支付宝

目标产品：优先 **电脑网站支付**（网站卖东西的正规产品；手机浏览器自动走手机网站支付），备选 **当面付**（扫码，通常更容易批）。

### A1. 签约产品（支付宝商家平台 b.alipay.com）

1. 确认当前登录的是**个体工商户**认证的商家账号（账户中心能看到营业执照主体）。如果是个人账号，停下来告诉机主。
2. 打开「产品中心」，找到 **电脑网站支付**，点开通/立即签约：
   - 经营类目：选软件、网络服务或数字内容相关类目，以页面选项为准；
   - 网站地址：`https://cirrus.routeforge.zone`；
   - ICP 备案号：从网站页脚复制；
   - 如果要求网站截图：截首页、购买页（`/buy`）、价格区、联系方式（`/support`）和页脚备案号。
3. 同时在产品中心申请 **当面付** 作为备选。
4. 提交前把填写内容截图给机主确认。提交后记录审核状态。

### A2. 开放平台应用与密钥（支付宝开放平台 open.alipay.com）

1. 控制台 → 创建应用 → 网页/移动应用。名称填 `卷云 Cirrus`，类型选网页应用，网址填 `https://cirrus.routeforge.zone`，图标用 `https://cirrus.routeforge.zone/static/logo.png`（先下载到本地再上传）。
2. 在应用的「产品绑定 / 能力列表」里添加 **电脑网站支付**、**手机网站支付**（如果有）和 **当面付**（如果已签约）。
3. 在本机生成 RSA2 密钥对，**不要用网页生成**：

```bash
mkdir -p ~/cirrus-keys && cd ~/cirrus-keys && umask 077
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out alipay_app_private.pem
openssl pkey -in alipay_app_private.pem -pubout -out alipay_app_public.pem
# 支付宝要的「应用公钥」是去掉首尾两行、合成一行的内容：
grep -v '^-----' alipay_app_public.pem | tr -d '\n'; echo
```

4. 在「开发设置 → 接口加签方式」选 **密钥 / 公钥模式**、RSA2，粘贴上一步输出的应用公钥并保存。页面随后显示 **支付宝公钥**，把它保存为 `~/cirrus-keys/alipay_public_key.txt`。
5. 「授权回调地址」和「应用网关」不用填。
6. 记下 **APPID**（2021 开头的 16 位数字），然后提交应用上线审核。

### A3. 写入服务器

审核通过后：

```bash
ssh <服务器>
cd /opt/cirrus-license && cp .env .env.bak.$(date +%Y%m%d%H%M%S)
# 用编辑器在 .env 中设置。密钥可以写成去掉 -----BEGIN/END----- 行后的一整行 base64（最简单），
# 也可以写成 PEM，多行用字面量 \n 连成一行。格式说明见 .env.example。
#   ALIPAY_APP_ID=2021xxxxxxxxxxxx
#   ALIPAY_PRIVATE_KEY=MIIEvQIBADANBgkq...        ← 应用私钥（alipay_app_private.pem 去掉首尾行合成一行）
#   ALIPAY_PUBLIC_KEY=MIIBIjANBgkq...             ← 支付宝公钥（不是应用公钥！）
#   ALIPAY_MODE=page          ← 电脑网站支付批了用 page；只批了当面付用 precreate
chmod 600 .env
docker compose up -d
docker compose logs --tail=20 cirrus-license
```

把本地私钥文件复制到服务器时用 `scp`，或在服务器上用编辑器粘贴。不要用 `echo 私钥 >> .env` 这种会进命令历史的方式。

### A4. 测试（不付款）

```bash
curl -s -X POST https://cirrus.routeforge.zone/api/v1/orders \
  -H 'Content-Type: application/json' \
  -d '{"product":"cirrus-linux","email":"test@routeforge.zone","method":"alipay"}' | python3 -m json.tool
```

- `ALIPAY_MODE=page`：`pay.type` 应为 `redirect`，`pay.url` 指向 `openapi.alipay.com`。在浏览器打开这个地址，应看到支付宝收银台，金额 ¥198.00。**不要付款**，直接关闭。
- `ALIPAY_MODE=precreate`：`pay.type` 应为 `qr`，`pay.qr_text` 以 `https://qr.alipay.com/` 开头。
- 如果 `pay.type` 是 `static_qr`，说明调用支付宝失败。查看 `docker compose logs cirrus-license | grep -i alipay`，常见原因是公钥填成了应用公钥、APPID 错误或应用未上线。

可选：在机主同意后真实支付一笔，确认购买页自动显示许可证；然后在商家平台全额退款，再到 `https://cirrus.routeforge.zone/admin` 撤销这张测试许可证。

---

## 第二部分：微信支付（Native 扫码支付）

### W1. 先确认商户类型

在 pay.weixin.qq.com 登录后，看是否有正式的 **商户号**（10 位数字，账户中心 → 商户信息），主体是机主的个体工商户。

如果机主只有「经营收款码 / 小微商户」而没有商户平台的正式商户号，就不能接 API。这时停下来，告诉机主需要用营业执照申请普通商户，然后跳到第三部分。

### W2. 准备 AppID

Native 支付必须关联一个与商户同主体、已微信认证的 **服务号** 或 **小程序**。

1. 问机主是否已有。没有的话，需要机主本人在 mp.weixin.qq.com 用个体户主体注册并认证（一般每年 300 元）。这一步停下来交给机主。
2. 有了以后，在商户平台「产品中心 → AppID 账号管理 → 关联 AppID」发起关联，再让机主在公众平台后台确认。

### W3. 开通 Native 支付

商户平台「产品中心」→ **Native 支付** → 申请开通。按页面填写网站地址 `https://cirrus.routeforge.zone`。

### W4. API 安全设置（商户平台「账户中心 → API 安全」）

1. **APIv3 密钥**：在本机生成，然后粘贴到平台。设置时需要机主验证。

```bash
cd ~/cirrus-keys && umask 077 && openssl rand -hex 16 > wechat_apiv3_key.txt   # 32 个字符
```

2. **API 证书**：按页面用官方证书工具申请，得到 `apiclient_key.pem`（商户私钥）和 **证书序列号**，序列号在证书管理里可以看到。把 `apiclient_key.pem` 放到 `~/cirrus-keys/`。
3. **微信支付公钥**：在「微信支付公钥」处申请或下载 `pub_key.pem`，并记下 **公钥 ID**（`PUB_KEY_ID_` 开头）。

### W5. 写入服务器

```bash
cd /opt/cirrus-license && cp .env .env.bak.$(date +%Y%m%d%H%M%S)
# 在 .env 中设置：
#   WECHAT_MCHID=1234567890
#   WECHAT_APPID=wx................
#   WECHAT_API_V3_KEY=<wechat_apiv3_key.txt 的内容>
#   WECHAT_CERT_SERIAL=<API 证书序列号>
#   WECHAT_PRIVATE_KEY=MIIEvQIBADANBgkq...        ← apiclient_key.pem 去掉首尾行合成一行
#   WECHAT_PUBLIC_KEY=MIIBIjANBgkq...             ← 微信支付公钥 pub_key.pem，同上
#   （合成一行：grep -v '^-----' 文件 | tr -d '\n'。在服务器上处理，不要把输出贴到聊天里）
#   WECHAT_PUBLIC_KEY_ID=PUB_KEY_ID_...
chmod 600 .env
docker compose up -d
docker compose logs --tail=20 cirrus-license
```

7 项要全部填写，只填一部分时服务不会启动（`docker compose logs` 会说明缺哪项），APIv3 密钥必须正好 32 个字符。详细说明见 `DEPLOY.md` 第 13 节「开通微信支付 API」。
如果商户平台只有「平台证书」没有「微信支付公钥」，先在「API 安全」里申请微信支付公钥，本服务只支持公钥验签。

### W6. 测试（不付款）

```bash
curl -s -X POST https://cirrus.routeforge.zone/api/v1/orders \
  -H 'Content-Type: application/json' \
  -d '{"product":"cirrus-linux","email":"test@routeforge.zone","method":"wechat"}' | python3 -m json.tool
```

- `pay.type` 应为 `qr`，`pay.qr_text` 以 `weixin://wxpay/` 开头。
- 在浏览器打开 `https://cirrus.routeforge.zone/buy`，用微信方式下单。用手机微信扫码，应显示收款方和 ¥198.00。**不付款**直接返回。
- 如果仍是 `static_qr`：用 `docker compose logs cirrus-license | grep -i wechat` 查看原因。常见原因：
  - 证书序列号不对；
  - 私钥和序列号不是同一张证书；
  - AppID 没有关联或确认；
  - Native 支付没有开通。

---

## 第三部分：登录权限范围自动同步（可选）

App 现在会在登录前读取 `https://cirrus.routeforge.zone/api/v1/oauth/config` 来决定申请哪些权限。服务器有两种方式提供这份清单。

**方式一（推荐，不在服务器上放 Cloudflare 凭据）**：手动写入 `.env`：

```
OAUTH_CLIENT_ID=9c147a5155baf903357222bd4d31ad50
OAUTH_SCOPES=<OAuth 客户端的 scopes，空格分隔，去掉 offline_access>
OAUTH_OPTIONAL_SCOPES=<optional_scopes，空格分隔>
```

以后在 Cloudflare 改了客户端的权限，只需要更新这两行并 `docker compose up -d`，不用重新发布 App。

**方式二（自动同步，按 `DEPLOY.md` 第 14 节）**：

1. 在 Cloudflare 控制台创建一个**只限这个账户**的 API Token，权限只给读取 OAuth 客户端相关的那一项（名字以控制台为准，只选“读”）。找不到合适的权限就放弃方式二，用方式一。
2. 写入 `.env`：`CF_ACCOUNT_ID=9e875b1a8162d208c5b4d9dfdabf5207`、`CF_API_TOKEN=<token>`。写入前先用第 14 节的 curl 命令确认这个 token 能读到客户端。
3. **不要把 Global API Key 放到服务器上**：它能控制整个 Cloudflare 账户。

验证：

```bash
curl -s https://cirrus.routeforge.zone/api/v1/oauth/config | python3 -m json.tool
# 应返回 client_id、scopes 列表和 source（env 或 cloudflare）
```

---

## 交付结果（填好后发给云端 Claude，不含任何密钥）

```
服务器版本：<cirrus-license version 的输出>

EdgeOne：
- CLIENT_IP_HEADER 已设置：是/否；日志中的 ip 是否为真实公网 IP：是/否
- 不缓存规则已添加：是/否（截图）
- 两个 notify 路径返回码：alipay ...，wechat ...（应为 404 或 400，不能是 EdgeOne 拦截页）

支付宝：
- 已签约产品：电脑网站支付 [已开通/审核中/被拒(原因)]，手机网站支付 [...]，当面付 [...]
- APPID：2021xxxxxxxxxxxx
- 应用状态：[已上线/审核中]
- ALIPAY_MODE：page / precreate
- 下单测试：pay.type = ...，收银台是否能打开：是/否
- 真实支付测试（如做了）：许可证是否自动发放：是/否，是否已退款并撤销

微信支付：
- 商户号：..........
- AppID：wx...（服务号/小程序名称）
- Native 支付：[已开通/审核中/没有正式商户号]
- 证书序列号：........（不是密钥，可以发）
- 微信支付公钥 ID：PUB_KEY_ID_...
- 下单测试：pay.type = ...，扫码是否显示 ¥198.00：是/否

登录权限范围：
- /api/v1/oauth/config 的 source：env / cloudflare，scopes 数量：..

遇到的问题和截图：
- ...

需要机主后续处理的事项：
- ...
```
