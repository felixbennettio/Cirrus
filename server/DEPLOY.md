# 部署手册：卷云 Cirrus 许可证服务器

本手册写给**有服务器 SSH 权限的人或 AI 助手**，请按顺序逐步执行。每一步都给出了命令、预期结果和出错时的处理办法。

- 目标：`https://cirrus.routeforge.zone`，由 1Panel 的 OpenResty 反向代理到 `127.0.0.1:8790`，容器内监听 8080。
- 服务器：腾讯云上海，Ubuntu，已安装 1Panel 和 Docker。**不在服务器上编译**：部署包里已经有编译好的静态二进制（amd64 和 arm64）。
- 除非特别注明“本地”，所有命令都在服务器上以 root 执行（不是 root 时在前面加 `sudo`）。
- 文中 `<VERSION>` 指部署包版本，即 `cirrus-license-<VERSION>.tar.gz` 文件名中的部分；`<SERVER>` 指 SSH 登录目标（如 `root@1.2.3.4`）。
- 下文的 `docker compose` 如果不可用，一律换成 `docker-compose`。

## 0. 开始前向机主确认的信息

| 项目 | 必需 | 说明 |
| --- | --- | --- |
| 部署包 `cirrus-license-<VERSION>.tar.gz` 及其 sha256 | 是 | 由 `server/build-bundle.sh` 生成 |
| `ICP_NUMBER` | 是 | 备案号，例如 `沪ICP备12345678号-1` |
| `OPERATOR_NAME` | 是 | 个体户名称，显示在页脚、隐私政策和用户协议中 |
| `CONTACT_EMAIL` | 是 | 客服邮箱 |
| `ADMIN_PASSWORD` | 否 | 不提供则由你生成（第 2 步），并告知机主 |
| 支付宝、微信收款码图片 | 是 | 两张 PNG，第 6 步上传 |
| `routeforge.zone` 的 DNS 管理权限 | 是 | 第 4 步添加 A 记录（可能需要机主操作） |
| 1Panel 面板地址和账号 | 建议 | 第 5 步创建网站；没有时用 5.4 的手动配置 |
| SMTP 账号 | 否 | 有则自动发送许可证邮件 |
| 支付宝开放平台 APPID 和密钥 | 否 | 以后再开，见第 12 节 |

## 1. 预检查

```bash
uname -m                      # x86_64 → 使用 amd64 二进制；aarch64 → arm64。其他架构：停止，告知机主
free -m                       # available 列至少 150 MB
df -h /opt                    # 至少 300 MB 可用
docker version --format '{{.Server.Version}}'
docker compose version || docker-compose version     # 记下哪个可用
systemctl is-active 1panel 2>/dev/null; which 1pctl  # 1Panel 是否存在
docker ps --format '{{.Names}}\t{{.Image}}' | grep -i openresty   # 1Panel 的 OpenResty 容器
ss -ltnp | grep -w 8790 || echo "8790 空闲"           # 必须空闲
which curl python3 openssl sha256sum                 # 验证脚本需要
timeout 120 docker pull alpine:3.20                  # 能否拉取基础镜像
```

判断：

- 8790 被占用：找出占用者（`ss -ltnp | grep 8790`），告知机主，不要擅自停止其他服务。如需换端口，修改 `docker-compose.yml` 中的 `127.0.0.1:8790`，后面所有 8790 同步替换。
- `docker pull alpine:3.20` 失败（国内访问 Docker Hub 不稳定）：
  1. 在 1Panel → 容器 → 配置 → 镜像加速 中添加可用的加速地址（1Panel 自带的或机主信任的），再试；或
  2. 本地执行 `docker pull --platform linux/amd64 alpine:3.20 && docker save alpine:3.20 | gzip > alpine-3.20.tar.gz`（arm64 服务器把 amd64 换成 arm64），上传后在服务器 `docker load < alpine-3.20.tar.gz`；或
  3. 不用 Docker，按附录 B 用 systemd 运行。
- 没有 python3：`apt-get install -y python3`（只有验证脚本需要）。

## 2. 上传部署包并创建配置

本地：

```bash
scp dist/cirrus-license-<VERSION>.tar.gz <SERVER>:/tmp/
sha256sum dist/cirrus-license-<VERSION>.tar.gz      # 记下
```

服务器：

```bash
sha256sum /tmp/cirrus-license-<VERSION>.tar.gz      # 必须与本地一致
mkdir -p /opt/cirrus-license
tar -xzf /tmp/cirrus-license-<VERSION>.tar.gz -C /opt/cirrus-license --strip-components=1
cd /opt/cirrus-license
sha256sum -c SHA256SUMS                             # 每行都应为 OK
ls -la                                              # bin/ Dockerfile.runtime docker-compose.yml .env.example DEPLOY.md README.md smoke-test.sh …
```

已存在 `/opt/cirrus-license/.env` 或 `data/` 时说明之前部署过：**不要覆盖**，改按第 10 节升级。

创建 `.env`（值来自第 0 步；含 `&`、`|`、`\` 的值请用编辑器手动修改）：

```bash
cd /opt/cirrus-license
cp .env.example .env && chmod 600 .env
set_env() { sed -i "s|^$1=.*|$1=$2|" .env; }

ADMIN_PASSWORD=$(openssl rand -base64 24 | tr -d '/+=')   # 机主提供了密码就改用机主的
set_env ADMIN_PASSWORD "$ADMIN_PASSWORD"
set_env OPERATOR_NAME 'XXXX（个体工商户）'
set_env CONTACT_EMAIL 'support@routeforge.zone'
set_env ICP_NUMBER '沪ICP备XXXXXXXX号-1'
# 可选：
# set_env DOWNLOAD_URL 'https://github.com/…/releases'
# set_env SMTP_HOST 'smtp.exmail.qq.com'; set_env SMTP_USER 'noreply@routeforge.zone'; set_env SMTP_PASS '…'
# set_env SMTP_FROM '卷云 Cirrus <noreply@routeforge.zone>'
# 腾讯云服务器上 apk 下载更快：
echo 'ALPINE_MIRROR=mirrors.tencent.com' >> .env

grep -E '^(PUBLIC_URL|ADMIN_PASSWORD|OPERATOR_NAME|CONTACT_EMAIL|ICP_NUMBER|PAY_METHODS|ALIPAY_MODE)=' .env
echo "管理后台密码：$ADMIN_PASSWORD"
```

**如果密码是你生成的，务必把它告诉机主**（后台地址 `https://cirrus.routeforge.zone/admin`，用户名 `admin`）。

创建数据目录（容器以 uid 10001 运行，必须拥有该目录）：

```bash
install -d -o 10001 -g 10001 -m 700 /opt/cirrus-license/data
install -d -o 10001 -g 10001 -m 755 /opt/cirrus-license/data/pay
```

## 3. 启动

```bash
cd /opt/cirrus-license
docker compose up -d --build
docker compose ps                         # STATUS 为 Up，约 30 秒后显示 (healthy)
docker compose logs --tail=30 cirrus-license
```

日志中应有：

- `created a new signing key: BACK UP data/signing.key NOW`（仅首次）
- `licence signing key ed25519_public_key=…`
- `cirrus-license started … listen=:8080 …`

```bash
curl -s http://127.0.0.1:8790/healthz     # 输出 ok
ls -l data/                               # signing.key（-rw-------，属主 10001）、cirrus.db
```

容器反复重启时看第 11 节。

## 4. DNS

在 `routeforge.zone` 的 DNS 服务商处添加：

| 类型 | 主机记录 | 值 | TTL |
| --- | --- | --- | --- |
| A | `cirrus` | 服务器公网 IP | 600 |

服务器公网 IP 在腾讯云控制台查看。如果 DNS 托管在 Cloudflare，请设为**仅 DNS（灰色云朵）**，否则签发证书和获取访客真实 IP 都会出问题。

验证（可能需要几分钟生效）：

```bash
getent hosts cirrus.routeforge.zone       # 应解析为服务器公网 IP
```

同时确认腾讯云安全组（以及 `ufw status` 显示的防火墙）放行了 TCP 80 和 443。**不要**对外开放 8790。

## 5. 1Panel 网站与 HTTPS

### 5.1 创建反向代理网站

1Panel → **网站** → **网站** → **创建网站** → 选择 **反向代理**：

- 主域名：`cirrus.routeforge.zone`
- 代理地址：协议 `http`，地址 `127.0.0.1:8790`（即 `http://127.0.0.1:8790`）
- 其他保持默认，确认创建。

1Panel 的 OpenResty 使用 host 网络，所以 `127.0.0.1:8790` 可以直接访问到容器映射的端口。

验证（DNS 已生效时）：

```bash
curl -s http://cirrus.routeforge.zone/healthz      # ok
```

### 5.2 申请 Let's Encrypt 证书并强制 HTTPS

1. 1Panel → 网站 → **证书** → 如无 ACME 账户，先创建（Let's Encrypt，填机主邮箱）。
2. **申请证书**：域名 `cirrus.routeforge.zone`，验证方式选 **HTTP**（需要第 4 步已生效、80 端口可访问）；如果 DNS 在支持的服务商（DNSPod、阿里云、Cloudflare 等），也可以选 DNS 账号验证。开启自动续签。
3. 回到网站列表 → `cirrus.routeforge.zone` → **配置** → **HTTPS**：启用 HTTPS，选择刚申请的证书，HTTP 选项选 **HTTP 自动跳转到 HTTPS**，保存。

验证：

```bash
curl -sI http://cirrus.routeforge.zone/ | head -3          # 301，Location: https://…
curl -s https://cirrus.routeforge.zone/healthz             # ok
```

### 5.3 确认代理头

本服务依赖 `Host`、`X-Real-IP`、`X-Forwarded-For`、`X-Forwarded-Proto` 识别访客 IP（限流用）和后台同源检查。1Panel 的反向代理默认会设置这些头。确认方法：

```bash
find /opt/1panel -path '*cirrus.routeforge.zone*' -name '*.conf' 2>/dev/null | xargs grep -h 'proxy_set_header' 2>/dev/null
```

应包含 `Host $host`、`X-Real-IP $remote_addr`、`X-Forwarded-For $proxy_add_x_forwarded_for`、`X-Forwarded-Proto $scheme`。缺少时在 1Panel 网站 → 配置 → 反向代理 → 编辑（或 配置文件）中补上，保存后 1Panel 会自动重载。

### 5.4 备用：不通过 1Panel 界面的 OpenResty / Nginx 配置

1Panel 界面不可用时，可以直接写配置。先确定配置目录：

```bash
OR=$(docker ps --format '{{.Names}}' | grep -i openresty | head -1); echo "$OR"
docker inspect "$OR" --format '{{range .Mounts}}{{.Source}} -> {{.Destination}}{{"\n"}}{{end}}' | grep -i conf
```

在挂载到容器 `conf.d` 的宿主机目录（1Panel 通常是 `/opt/1panel/apps/openresty/openresty/conf/conf.d/`；没有 1Panel 的普通 Nginx 是 `/etc/nginx/conf.d/`）新建 `cirrus.routeforge.zone.conf`：

```nginx
server {
    listen 80;
    server_name cirrus.routeforge.zone;
    location ^~ /.well-known/acme-challenge/ { root /var/www/acme; }   # 签发证书用，目录须在容器内可见
    location / { return 301 https://$host$request_uri; }
}

server {
    listen 443 ssl http2;            # Nginx ≥ 1.25.1 可改为 listen 443 ssl; http2 on;
    server_name cirrus.routeforge.zone;
    ssl_certificate     /path/to/fullchain.pem;    # 容器内可见的路径
    ssl_certificate_key /path/to/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    client_max_body_size 64k;

    location / {
        proxy_pass http://127.0.0.1:8790;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 60s;
    }
}
```

证书可以用 acme.sh 的 webroot 模式签发（先只启用 80 端口的 server 块）：`acme.sh --issue -d cirrus.routeforge.zone -w <对应 /var/www/acme 的宿主机目录>`，再 `acme.sh --install-cert … --reloadcmd "docker exec $OR openresty -s reload"`。

检查并重载：

```bash
docker exec "$OR" openresty -t && docker exec "$OR" openresty -s reload     # 普通 Nginx：nginx -t && systemctl reload nginx
```

## 6. 上传收款码

本地（文件名必须是 `alipay.png`、`wechat.png`，PNG 格式）：

```bash
scp alipay.png wechat.png <SERVER>:/opt/cirrus-license/data/pay/
```

服务器：

```bash
chown 10001:10001 /opt/cirrus-license/data/pay/*.png && chmod 644 /opt/cirrus-license/data/pay/*.png
curl -sI http://127.0.0.1:8790/static/pay/alipay.png | head -3     # 200，Content-Type: image/png
curl -sI http://127.0.0.1:8790/static/pay/wechat.png | head -3
```

无需重启。打开 `https://cirrus.routeforge.zone/buy`，两种付款方式都不应再显示“暂不可用”。请机主确认：用这两个收款码付款时可以填写备注（买家要在备注里填订单号）。

## 7. 验证

### 7.1 基本检查

```bash
curl -s http://127.0.0.1:8790/healthz                 # ok
curl -s http://127.0.0.1:8790/api/v1/pubkey           # {"ed25519":"…"}
curl -s https://cirrus.routeforge.zone/healthz        # ok
curl -s https://cirrus.routeforge.zone/api/v1/pubkey  # 与上面完全相同
curl -s https://cirrus.routeforge.zone/ | grep -o 'beian.miit.gov.cn[^<]*<' | head -1   # 页脚备案号
```

**本地**再执行一次 `curl -s https://cirrus.routeforge.zone/api/v1/pubkey`，然后在服务器上：

```bash
docker compose -f /opt/cirrus-license/docker-compose.yml logs --tail=5 cirrus-license | grep pubkey
```

日志中的 `ip=` 应为本地机器的公网 IP；如果是 `127.0.0.1` 或 `172.x.x.x`，说明代理头没有传过来，回到 5.3。

### 7.2 完整购买流程

`smoke-test.sh` 会依次：打开全部页面 → 创建测试订单 → 以管理员身份确认收款 → 查询订单拿到许可证 → 激活、错误平台、校验、停用 → 最后**吊销这张测试许可证**并加备注 `smoke-test`。

```bash
cd /opt/cirrus-license
ADMIN_PASSWORD=$(grep '^ADMIN_PASSWORD=' .env | cut -d= -f2-)
./smoke-test.sh http://127.0.0.1:8790 "$ADMIN_PASSWORD"
./smoke-test.sh https://cirrus.routeforge.zone "$ADMIN_PASSWORD"
```

两次都应以 `ALL OK` 结束。说明：

- 需要 `data/pay/alipay.png` 已存在（或开通了支付宝 API）；只有微信收款码时在命令末尾加参数 `wechat`。
- 测试订单的邮箱是 `smoke-test@example.com`。配置了 SMTP 时会尝试发信并在日志里记录失败，属正常现象。
- 测试订单会计入后台的“已付款订单”和“收入”。

不能运行脚本时，按附录 A 手动执行同样的流程。

## 8. 读取公钥并报告给机主

```bash
cd /opt/cirrus-license
docker compose exec -T cirrus-license cirrus-license pubkey
```

输出是一行标准 base64（44 个字符，以 `=` 结尾），与 `/api/v1/pubkey` 中的 `ed25519` 相同。**把这一行报告给机主**：App 构建需要把它设为 `CIRRUS_LICENSE_PUBKEY`，否则 App 无法验证激活。

## 9. 备份

### 9.1 签名密钥（立即做，只需一次）

**本地**：

```bash
scp <SERVER>:/opt/cirrus-license/data/signing.key ./cirrus-signing.key
```

把它保存到密码管理器或加密存储中，并告诉机主保存位置。丢失这个文件意味着已发布的 App 无法验证新的激活，只能发布内置新公钥的 App。`.env` 也建议一起离线保存。

### 9.2 数据库（每天）

服务运行时即可备份（SQLite `VACUUM INTO`，结果是一致的快照）：

```bash
cd /opt/cirrus-license && docker compose exec -T cirrus-license cirrus-license backup
# 输出 /data/backups/cirrus-20261006-041500.db，对应宿主机 data/backups/
```

加入 root 的 crontab（`crontab -e`），每天 04:15 备份并保留 30 天：

```cron
15 4 * * * cd /opt/cirrus-license && docker compose exec -T cirrus-license cirrus-license backup >/dev/null 2>&1; find /opt/cirrus-license/data/backups -name 'cirrus-*.db' -mtime +30 -delete
```

建议再用 1Panel → 计划任务 → 备份目录，把 `/opt/cirrus-license/data/backups` 定期上传到对象存储（如腾讯云 COS），做到异地备份。

### 9.3 恢复

```bash
cd /opt/cirrus-license
docker compose stop
cp data/cirrus.db data/cirrus.db.broken 2>/dev/null; rm -f data/cirrus.db-wal data/cirrus.db-shm
cp data/backups/cirrus-<时间>.db data/cirrus.db && chown 10001:10001 data/cirrus.db && chmod 600 data/cirrus.db
docker compose start && docker compose logs --tail=20 cirrus-license
```

## 10. 升级与回滚

本地：`scp dist/cirrus-license-<NEW>.tar.gz <SERVER>:/tmp/`

服务器：

```bash
cd /opt/cirrus-license
docker compose exec -T cirrus-license cirrus-license version     # 记下当前版本
docker compose exec -T cirrus-license cirrus-license backup      # 先备份数据库
docker tag cirrus-license:latest cirrus-license:rollback         # 保留当前镜像用于回滚

mkdir -p /opt/cirrus-license-releases
tar -xzf /tmp/cirrus-license-<NEW>.tar.gz -C /opt/cirrus-license-releases
cd /opt/cirrus-license-releases/cirrus-license-<NEW> && sha256sum -c SHA256SUMS
cp -r bin Dockerfile.runtime docker-compose.yml .dockerignore cirrus-license.service smoke-test.sh \
      .env.example DEPLOY.md README.md VERSION /opt/cirrus-license/

cd /opt/cirrus-license
# 新版本若新增了配置项，会出现在下面的差异里，按需加入 .env：
diff <(grep -oE '^#? ?[A-Z_]+=' .env.example | tr -d '# ' | sort -u) <(grep -oE '^[A-Z_]+=' .env | sort -u)
docker compose up -d --build
docker compose logs --tail=20 cirrus-license
docker compose exec -T cirrus-license cirrus-license version     # 应为新版本
./smoke-test.sh http://127.0.0.1:8790 "$(grep '^ADMIN_PASSWORD=' .env | cut -d= -f2-)"
```

`.env` 和 `data/` 不会被改动；数据库结构如有变化会在启动时自动迁移。

**回滚**：

```bash
cd /opt/cirrus-license
docker tag cirrus-license:rollback cirrus-license:latest
docker compose up -d --no-build --force-recreate
docker compose exec -T cirrus-license cirrus-license version
```

如果新版本已经迁移了数据库而旧版本无法启动，按 9.3 恢复升级前的备份。回滚后，把旧版本部署包里的文件复制回 `/opt/cirrus-license`，以免下次 `--build` 又构建出新版本。

## 11. 排错

| 现象 | 检查与处理 |
| --- | --- |
| 容器反复重启 | `docker compose logs --tail=50 cirrus-license` 查看最后的错误 |
| 日志 `DATA_DIR … is not writable` | `chown -R 10001:10001 /opt/cirrus-license/data` |
| 日志 `configuration: …` | `.env` 中某项格式不对，按提示修改后 `docker compose up -d` |
| 日志 `signing key: … refusing to replace it` | `signing.key` 损坏。**不要删除**，从 9.1 的离线备份恢复 |
| `docker compose up --build` 卡在 `apk add` | `.env` 中设置 `ALPINE_MIRROR=mirrors.tencent.com` 后重试 |
| 拉取 `alpine:3.20` 失败 | 见第 1 步的处理办法 |
| 网站 502 Bad Gateway | `curl http://127.0.0.1:8790/healthz`；不通则容器没起来；通则检查 1Panel 代理地址 |
| 证书申请失败 | DNS 是否生效、80 端口是否放行（安全组/ufw）、Cloudflare 是否关闭了代理 |
| 日志中 `ip=` 都是 `127.0.0.1` 或 `172.x` | 代理头缺失，见 5.3；所有访客会共享同一个限流桶 |
| 后台操作提示 `CSRF check failed` | 刷新页面重试；仍失败时检查代理是否传递了 `Host $host`，以及 `PUBLIC_URL` 是否正确 |
| 后台提示 `too many failed logins` | 密码连续输错，等几分钟再试 |
| 购买页某种付款方式“暂不可用” | `data/pay/` 下缺少对应 PNG，或文件权限不对（第 6 步） |
| 下单返回 `rate_limited` | 同一 IP 下单过于频繁（约每 2 分钟 1 单，可连续 6 单），正常保护 |
| 收不到许可证邮件 | 日志搜 `send licence email`；确认 `SMTP_PORT=465`（腾讯云封禁 25 端口）和账号密码 |
| 支付宝付款后订单仍待付款 | 日志搜 `alipay notify`：`rejected reason=…` 说明验签、app_id 或金额不符（多为 `ALIPAY_PUBLIC_KEY` 填成了应用公钥）；完全没有记录说明通知没到达，检查 HTTPS 是否正常、`PUBLIC_URL` 是否正确 |
| 查看内存和 CPU | `docker stats --no-stream cirrus-license`（正常约 20 MB，上限 128 MB） |

需要人工处理的订单（如买家付了款但订单已过期）：在后台“订单”中筛选“已过期”，核对后点“确认收款”即可。

## 12. 以后开通支付宝 API

应该申请哪个产品：

- **电脑网站支付**（`ALIPAY_MODE=page`）：网站销售对应的正规产品。买家跳转到支付宝收银台付款；手机浏览器会自动使用**手机网站支付**（建议一起开通）。需要已备案的网站，网站内容需与经营范围相符。
- **当面付**（`ALIPAY_MODE=precreate`）：页面显示动态付款二维码。通常更容易审核通过，适合作为备选。

两者都会由支付宝自动通知付款结果，自动签发许可证。

开通步骤（在 [支付宝开放平台](https://open.alipay.com/) 操作）：

1. 创建应用（网页/移动应用），添加能力：电脑网站支付 + 手机网站支付，或当面付；按要求签约（个体户需要营业执照）。
2. 开发设置 → 接口加签方式 → **公钥模式**，加签算法 **RSA2**。用“支付宝开放平台密钥工具”生成密钥对：
   - **应用私钥** → 填入 `ALIPAY_PRIVATE_KEY`（只保存在服务器 `.env` 中）；
   - **应用公钥** → 上传到开放平台；
   - 上传后平台显示的 **支付宝公钥** → 填入 `ALIPAY_PUBLIC_KEY`。**注意不是应用公钥。**
   - 两个值都可以直接粘贴密钥工具导出的一整行 base64（不带 `-----BEGIN` 头），也可以是 PEM（多行时用字面量 `\n` 连成一行）。
3. 不需要在开放平台配置“授权回调地址”或“应用网关”。异步通知地址固定为 **`https://cirrus.routeforge.zone/pay/alipay/notify`**，每次下单时自动传给支付宝。
4. 应用审核上线后，在 `/opt/cirrus-license/.env` 中设置：

```bash
ALIPAY_APP_ID=2021xxxxxxxxxxxx
ALIPAY_PRIVATE_KEY=MIIEvQIBADANBgkqhkiG9w0BAQEFAASC…（应用私钥，一整行）
ALIPAY_PUBLIC_KEY=MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8A…（支付宝公钥，一整行）
ALIPAY_MODE=page            # 或 precreate
```

5. `cd /opt/cirrus-license && docker compose up -d`，日志中应有 `alipay_api=true alipay_mode=page`。
6. 用一个真实的小订单测试：在 `/buy` 下单并付款，几秒内页面应显示许可证，日志中有 `order paid … via=alipay`。

沙箱测试：在开放平台的沙箱应用里取得沙箱 APPID 和密钥，并设置 `ALIPAY_GATEWAY=https://openapi-sandbox.dl.alipaydev.com/gateway.do`，用沙箱买家账号付款。沙箱的异步通知同样要发到公网可访问的 `PUBLIC_URL`。测完后删除 `ALIPAY_GATEWAY` 一行（恢复正式网关）并换回正式密钥。

开通后，`data/pay/alipay.png` 只在支付宝接口调用失败时作为备用。

## 附录 A：手动执行购买流程（无法运行 smoke-test.sh 时）

```bash
B=http://127.0.0.1:8790
P=$(grep '^ADMIN_PASSWORD=' /opt/cirrus-license/.env | cut -d= -f2-)
# 1. 下单，记下 order_no 和 token
curl -s -X POST $B/api/v1/orders -H 'Content-Type: application/json' \
  -d '{"product":"cirrus-linux","email":"smoke-test@example.com","method":"alipay"}'
NO=C26xxxxxxxxxx; TOK=xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
curl -s "$B/api/v1/orders/$NO?token=$TOK"                          # "status":"pending"
# 2. 管理员确认（先取得 CSRF Cookie）
curl -s -u "admin:$P" -c /tmp/cj -o /dev/null $B/admin
CSRF=$(awk '$6=="cirrus_csrf"{print $7}' /tmp/cj)
curl -s -o /dev/null -w '%{http_code} %{redirect_url}\n' -u "admin:$P" -b /tmp/cj -H "Origin: $B" \
  --data "csrf=$CSRF&pay_ref=manual-test" $B/admin/orders/$NO/confirm      # 303 …/admin/licenses/lic_…
curl -s "$B/api/v1/orders/$NO?token=$TOK"                          # "status":"paid","license_key":"CIRRUS-…"
# 3. 激活与校验
KEY=CIRRUS-XXXXX-XXXXX-XXXXX-XXXXX
DEV=$(printf 'cirrus-device:manual-test' | sha256sum | cut -d' ' -f1)
curl -s -X POST $B/api/v1/activate -H 'Content-Type: application/json' \
  -d "{\"license_key\":\"$KEY\",\"device_id\":\"$DEV\",\"device_name\":\"test\",\"platform\":\"linux\",\"app_version\":\"test\"}"
curl -s -X POST $B/api/v1/validate -H 'Content-Type: application/json' -d "{\"license_key\":\"$KEY\",\"device_id\":\"$DEV\"}"
curl -s -X POST $B/api/v1/deactivate -H 'Content-Type: application/json' -d "{\"license_key\":\"$KEY\",\"device_id\":\"$DEV\"}"
# 4. 在后台吊销这张测试许可证（或：）
curl -s -o /dev/null -u "admin:$P" -b /tmp/cj -H "Origin: $B" --data "csrf=$CSRF" $B/admin/licenses/lic_xxxxxxxxxxxxxxxx/revoke
rm -f /tmp/cj
```

## 附录 B：不使用 Docker（systemd）

Docker 镜像无法拉取时的替代方案。二进制是静态编译的，直接运行即可。

```bash
cd /opt/cirrus-license
case "$(uname -m)" in x86_64) A=amd64 ;; aarch64) A=arm64 ;; *) echo unsupported; exit 1 ;; esac
id cirrus 2>/dev/null || useradd --system --uid 10001 --user-group --home-dir /opt/cirrus-license --shell /usr/sbin/nologin cirrus
install -m 0755 bin/cirrus-license-$A /opt/cirrus-license/cirrus-license
install -d -o cirrus -g cirrus -m 700 data && install -d -o cirrus -g cirrus -m 755 data/pay
chmod 600 .env
cp cirrus-license.service /etc/systemd/system/cirrus-license.service
systemctl daemon-reload && systemctl enable --now cirrus-license
systemctl status cirrus-license --no-pager
journalctl -u cirrus-license -n 30 --no-pager
curl -s http://127.0.0.1:8790/healthz
```

该 unit 让程序直接监听 `127.0.0.1:8790`，数据在 `/opt/cirrus-license/data`，所以第 4 步之后的步骤不变，只是把命令换掉：

- 日志：`journalctl -u cirrus-license`
- 公钥：`sudo -u cirrus env DATA_DIR=/opt/cirrus-license/data /opt/cirrus-license/cirrus-license pubkey`
- 备份：`sudo -u cirrus env DATA_DIR=/opt/cirrus-license/data /opt/cirrus-license/cirrus-license backup`
- 升级：替换 `/opt/cirrus-license/cirrus-license` 后 `systemctl restart cirrus-license`

`.env` 中不要设置 `LISTEN` 和 `DATA_DIR`（`.env` 的值会覆盖 unit 文件里的设置）。
