# 卷云 Cirrus：自托管 GitHub Actions Runner 设置指南（交给本地 Claude 执行）

> **给机主的说明**：把这份文件交给你本地的 Claude（它要能操作你的 Mac 和你的 Ubuntu 服务器），并对它说：
> 「请完整阅读 ci/RUNNERS.md，按顺序执行。遇到需要我本人操作的地方（sudo 密码、Apple ID 登录、钥匙串或录屏授权弹窗、浏览器登录）停下来叫我。」
>
> 做完后，让它填好文末的「交付结果」，发给云端的 Claude。**交付结果里不要包含任何令牌、密码或私钥。**

---

## 背景（给本地 Claude）

仓库 `felixbennettio/Cirrus` 是私有仓库，GitHub 自带的 Actions 机器额度已经用完，所有工作流都启动不了。机主决定用自己的两台机器当 self-hosted runner：

| 机器 | 跑什么 | 安装方式 | Runner 标签 |
| --- | --- | --- | --- |
| 机主的 Mac | 所有苹果相关任务：App Store 上传、官网直售 Mac 版（Developer ID 签名和公证）、iOS/macOS 构建、模拟器截图，以后还有原生 Swift 版 | 直接装在机主的 macOS 用户下，作为登录项（launch agent）运行，这样能用机主的钥匙串和图形界面 | `cirrus-mac` |
| 机主的 Ubuntu 26.04 服务器（AMD 8845HS，x86_64） | 代码检查和测试、Linux 版构建、Android 版构建 | 在服务器上用 Docker 运行一个 **Ubuntu 22.04 容器**，Runner 装在容器里。服务器本身还是 Ubuntu 26，不需要重装系统 | `cirrus-linux` |
| （没有） | Windows 版构建 | 继续用 GitHub 自带机器，等额度恢复，或机主以后再加一台 Windows 机器 | — |

为什么 Linux Runner 要放在 Ubuntu 22.04 容器里：Linux 版安装包会依赖构建机器的 glibc 版本。直接在 Ubuntu 26 上构建，打出来的包在 Ubuntu 22.04、Debian 12 等较老的系统上打不开。在 22.04 容器里构建，兼容性和以前用 GitHub 机器时一样。容器还能把 Android SDK、编译器这些构建依赖和服务器本身隔开，不会弄乱宿主机。

仓库里已经准备好的文件：

- `ci/runner-linux/`：Linux Runner 的 `Dockerfile`、`docker-compose.yml` 和 `entrypoint.sh`。
- `ci/runner-mac/setup.sh`：Mac Runner 的安装脚本。
- 工作流通过仓库变量 `RUNNER_LINUX`、`RUNNER_MAC`、`RUNNER_WINDOWS` 选择机器。不设置这些变量时，仍然使用 GitHub 自带的机器。

## 必须遵守

1. Runner 只注册到 `felixbennettio/Cirrus` 这一个私有仓库。不要注册到组织，也不要用于任何公开仓库。
2. 注册令牌（registration token）1 小时内有效，只能用一次。不要把它写进聊天、日志或 git。写进 `.env` 后，等注册成功就删掉。
3. 不要改仓库里的代码，也不要往仓库提交或推送任何东西。发现问题就记录下来，写进交付结果。
4. 遇到以下操作，停下来请机主本人完成：
   - 输入 sudo 密码；
   - 在 Xcode 里登录 Apple ID；
   - 处理钥匙串弹窗（选「始终允许」）和「屏幕录制」授权；
   - 在浏览器里登录 GitHub；
   - 从 App Store 安装 Xcode。
5. 不要导出任何证书私钥，也不要把 `.p12` 或 `.p8` 文件复制到别处。

---

## 第 0 步：两台机器都要做

1. 安装并登录 GitHub CLI：
   - Mac：`brew install gh`；
   - Ubuntu：`sudo apt install gh`。
   - 然后运行 `gh auth login`。登录方式选浏览器，由机主完成。登录的账号必须是仓库所有者 `felixbennettio`。
   - 用 `gh auth status` 确认已登录。
2. 克隆仓库：

   ```bash
   gh repo clone felixbennettio/Cirrus ~/src/Cirrus
   cd ~/src/Cirrus && git pull
   ```

3. **检查网络**（机器在国内时很重要）。逐个测试下面这些地址：

   ```bash
   for u in https://github.com https://api.github.com https://objects.githubusercontent.com \
            https://pipelines.actions.githubusercontent.com https://results-receiver.actions.githubusercontent.com \
            https://storage.googleapis.com https://pub.dev https://dl.google.com https://maven.google.com \
            https://repo.maven.apache.org https://services.gradle.org https://plugins.gradle.org \
            https://proxy.golang.org https://registry-1.docker.io; do
     printf '%-60s ' "$u"; curl -s -o /dev/null -m 15 -w '%{http_code}\n' "$u" || echo FAIL
   done
   ```

   - 有 `FAIL` 或长时间超时：问机主是否已有代理（例如 `http://127.0.0.1:7890`）。有的话，按下面「代理设置」配置；没有的话，记录到交付结果里，然后停下。
   - **代理设置：**
     - **Mac Runner**：在 `~/actions-runner-cirrus/.env` 里加入下面三行，然后运行 `./svc.sh stop && ./svc.sh start`：

       ```
       https_proxy=http://代理地址:端口
       http_proxy=http://代理地址:端口
       no_proxy=localhost,127.0.0.1
       ```

     - **Linux 容器**：在 `ci/runner-linux/.env` 里加 `HTTPS_PROXY=...` 和 `HTTP_PROXY=...`，并在 `docker-compose.yml` 的 `environment` 里同样传入 `https_proxy`、`http_proxy`、`no_proxy`。
       - 构建镜像时，加上 `docker compose build --build-arg HTTPS_PROXY=... --build-arg HTTP_PROXY=...`。
       - 代理如果在宿主机的 127.0.0.1 上，容器访问不到。这时让代理监听局域网地址，或者在 compose 里给容器加 `network_mode: host`，二选一。
     - **Docker 拉取镜像**：Docker 守护进程本身也要能访问 Docker Hub。可以用 systemd 的 drop-in 文件 `/etc/systemd/system/docker.service.d/proxy.conf` 设置 `Environment="HTTPS_PROXY=..."`，也可以配置国内镜像加速。
   - 没有代理、只能用国内镜像时：
     - 在 Runner 的环境变量里加 `FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn`、`PUB_HOSTED_URL=https://pub.flutter-io.cn`、`GOPROXY=https://goproxy.cn,direct`。Mac 写进 `.env`，Linux 写进 compose 的 `environment`。
     - Linux 镜像构建时加 `--build-arg GO_DOWNLOAD=https://golang.google.cn/dl`。
     - **注意**：GitHub 本身（github.com 和 actions 相关域名）必须能稳定访问，否则 Runner 收不到任务。

---

## 第一部分：Ubuntu 服务器（Linux Runner）

### A1. 检查机器

```bash
lsb_release -a; uname -m; nproc; free -h; df -h /var/lib/docker / 2>/dev/null
```

- 需要 `x86_64`。
- Docker 所在磁盘至少要有 60 GB 空闲空间：Android SDK、Gradle、Flutter 的缓存会占不少空间。
- 记下总内存。容器的内存上限建议设为总内存的一半左右，用 `.env` 里的 `RUNNER_MEMORY` 设置，例如 `RUNNER_MEMORY=16g`。

### A2. 安装 Docker

```bash
docker version && docker compose version
```

如果没有安装：

```bash
sudo apt-get update
sudo apt-get install -y docker.io docker-compose-v2   # Ubuntu 自带的包；也可以按 docs.docker.com 用 Docker 官方的 apt 源安装
sudo systemctl enable --now docker
sudo usermod -aG docker "$USER"                       # 之后要重新登录才生效；在那之前命令前面加 sudo
```

### A3. 获取注册令牌，启动 Runner

```bash
cd ~/src/Cirrus/ci/runner-linux
TOKEN=$(gh api -X POST repos/felixbennettio/Cirrus/actions/runners/registration-token --jq .token)
umask 077
printf 'RUNNER_TOKEN=%s\nRUNNER_NAME=%s\nRUNNER_MEMORY=%s\n' "$TOKEN" "$(hostname)-cirrus" "16g" > .env   # 内存按 A1 的结果填写
unset TOKEN
docker compose up -d --build        # 第一次要下载和构建镜像，大约 10–20 分钟
docker logs -f cirrus-runner-linux  # 看到 “Listening for Jobs” 就说明成功了，按 Ctrl-C 退出
```

注册成功后，删除 `.env` 里的 `RUNNER_TOKEN` 那一行。注册信息保存在 Docker 卷 `runner-home` 里，重启后不需要再次注册。

### A4. 确认

```bash
gh api repos/felixbennettio/Cirrus/actions/runners \
  --jq '.runners[] | [.name, .status, ([.labels[].name] | join(","))] | @tsv'
```

列表里应该有 `<主机名>-cirrus  online  self-hosted,Linux,X64,cirrus-linux`。

日常维护：
- 容器设置了 `restart: unless-stopped`，服务器重启后会自动启动。
- 升级 Runner 镜像：`git pull && docker compose up -d --build`。
- 如果要彻底重新注册：`docker compose down -v`，然后从 A3 重新开始。

---

## 第二部分：Mac（Apple Runner）

### B1. 检查 Xcode 和模拟器

```bash
sw_vers; uname -m; xcodebuild -version; xcrun simctl list runtimes | grep -i ios
```

1. Xcode 需要 26.x 版本，从 App Store 安装。如果没有安装或版本过旧，停下来请机主安装或更新。
2. 第一次使用前运行：
   - `sudo xcodebuild -license accept`（需要机主输入密码）；
   - `xcodebuild -runFirstLaunch`。
3. 如果没有 iOS 26 的模拟器：运行 `xcodebuild -downloadPlatform iOS`，大约需要下载 8 GB。

### B2. 安装工具

```bash
brew -v || echo "没有 Homebrew：按 https://brew.sh 安装（需要机主密码）"
brew install jq cocoapods xcodegen gh
```

### B3. 保持 Mac 唤醒

Runner 作为登录项运行，所以**机主的用户必须保持登录**，Mac 也不能睡眠：

- 打开 系统设置 → 电池（或「能耗」）→ 选项，勾选「显示器关闭时，防止自动进入睡眠」（接电源时）。
- 或者运行 `sudo pmset -c sleep 0`（需要机主输入密码）。
- 锁屏没关系，但不要注销用户。

### B4. 安装 Runner

```bash
cd ~/src/Cirrus
RUNNER_TOKEN=$(gh api -X POST repos/felixbennettio/Cirrus/actions/runners/registration-token --jq .token) \
  ci/runner-mac/setup.sh
```

Runner 会安装在 `~/actions-runner-cirrus`，并注册为机主用户的 launch agent，开机登录后自动运行。需要代理的话，按第 0 步的「代理设置」写入 `.env`，然后重启 Runner。

### B5. 创建 Developer ID 证书（官网直售 Mac 版要用）

只需要做一次，请机主一起操作：

1. 打开 Xcode → Settings → Accounts。如果没有登录，请机主用 Apple ID 登录（团队是 XIAOCHEN LIU，SZN83F2GT9）。
2. 选中团队 → Manage Certificates… → 点左下角的「+」→ 选 **Developer ID Application**。
3. 确认证书已经生成：

   ```bash
   security find-identity -v -p codesigning | grep "Developer ID Application"
   ```

**不要**在网页上或 Xcode 里手动创建其他证书。App Store 工作流第一次在这台 Mac 上运行时，会自动创建一张「Apple Development」证书并一直复用。

### B6. 确认

```bash
gh api repos/felixbennettio/Cirrus/actions/runners \
  --jq '.runners[] | [.name, .status, ([.labels[].name] | join(","))] | @tsv'
```

列表里应该有 `<Mac 名>-cirrus  online  self-hosted,macOS,ARM64,cirrus-mac`。如果是 Intel Mac，这里会是 `X64`。

---

## 第三部分：让仓库使用这两台机器

```bash
gh variable set RUNNER_LINUX --repo felixbennettio/Cirrus --body '["self-hosted","cirrus-linux"]'
gh variable set RUNNER_MAC   --repo felixbennettio/Cirrus --body '["self-hosted","cirrus-mac"]'
gh variable list --repo felixbennettio/Cirrus
```

- 不设置 `RUNNER_WINDOWS`，Windows 继续使用 GitHub 自带的机器。
- 想换回 GitHub 自带的机器：`gh variable delete RUNNER_LINUX --repo felixbennettio/Cirrus`（Mac 同理）。

---

## 第四部分：试运行

按下面的顺序运行。第一次运行苹果相关任务时，**请机主坐在 Mac 前**，以便处理弹窗。

```bash
R=felixbennettio/Cirrus
last() { gh run list --repo $R --workflow "$1" -L1 --json databaseId -q '.[0].databaseId'; }
```

1. **CI（全部平台）：**

   ```bash
   gh workflow run ci.yml --repo $R --ref main -f apple=true -f store_build=false
   sleep 10; gh run watch --repo $R "$(last ci.yml)"
   ```

   - 期望结果：「Analyze & test」、「Linux」、「Android」在服务器上通过；「macOS」、「iOS」在 Mac 上通过。
   - 「Windows」仍然使用 GitHub 自带的机器。如果 GitHub 额度还没恢复，这一项会失败，这是预期的，记录下来即可。

2. **上传 App Store（TestFlight）：**

   ```bash
   gh workflow run appstore.yml --repo $R --ref main -f platforms=ios-and-macos -f upload=true
   sleep 10; gh run watch --repo $R "$(last appstore.yml)"
   ```

   - 如果 Mac 上弹出钥匙串窗口（例如「codesign 想要访问钥匙串中的密钥」），请机主输入登录密码，并选「始终允许」。
   - 工作流最后一步会吊销以前 GitHub 机器留下的约 8 张「Created via API」开发证书。这台 Mac 自己正在用的那张会保留。
   - 运行结束后，到 developer.apple.com → Certificates 查看。应该剩下：
     - 机主自己的 1 张 Development 证书；
     - 这台 Mac 的 1 张 Development 证书；
     - 2 张 Managed 分发证书；
     - B5 创建的 Developer ID 证书。

3. **玻璃效果预览截图：**

   ```bash
   gh workflow run glass-preview.yml --repo $R --ref main
   sleep 10; gh run watch --repo $R "$(last glass-preview.yml)"
   ```

   - 第一次截取 Mac 窗口时，macOS 可能会弹出「屏幕录制」授权。请机主到 系统设置 → 隐私与安全性 → 屏幕与系统录音 中，给 Runner 进程（Runner.Listener 或 bash）开启权限，然后重跑：`gh run rerun --repo $R "$(last glass-preview.yml)"`。
   - 截图只截预览程序自己的窗口，不会截到桌面上的其他内容。

4. **官网直售 Mac 版**（需要先完成 B5）：

   ```bash
   gh workflow run mac-direct.yml --repo $R --ref main -f notarize=true
   sleep 10; gh run watch --repo $R "$(last mac-direct.yml)"
   gh run download --repo $R "$(last mac-direct.yml)" -D ~/cirrus-artifacts/mac-direct
   ```

   - 苹果公证通常需要 2–15 分钟。
   - 下载后检查：

     ```bash
     spctl -a -t open --context context:primary-signature -v ~/cirrus-artifacts/mac-direct/*.dmg
     ```

     应显示 `accepted`，`source=Notarized Developer ID`。

任何一步失败时：

```bash
gh run view --repo $R <run id> --log-failed | tail -80
```

把关键的错误行记进交付结果。不要自己修改仓库代码。

---

## 交付结果（填好后发给云端 Claude，不要包含令牌、密码或私钥）

```
Linux Runner：
- 服务器：Ubuntu 版本 …，CPU 核数 …，内存 …，Docker 版本 …
- 网络：直连 / 代理（只写类型，不写地址）/ 国内镜像；连不上的域名：…
- Runner 名称和状态：… online，标签 …
- 容器内存上限：…

Mac Runner：
- macOS 版本 …，芯片 arm64/x86_64，Xcode 版本 …，iOS 模拟器运行时：…
- Runner 名称和状态：… online，标签 …
- Developer ID Application 证书：已创建 / 未创建（原因）
- 防睡眠设置：已设置 / 未设置

仓库变量：RUNNER_LINUX = …，RUNNER_MAC = …

试运行（附 run 链接）：
1. CI：Analyze & test …，Linux …，Android …，macOS …，iOS …，Windows …
2. App Store：iOS …，macOS …（上传成功的 build 号 …）；吊销了几张旧证书：…
3. 玻璃预览：ios …，macos …（是否出现屏幕录制授权：…）
4. Mac 直售版：…，spctl 检查结果：…，DMG 文件名和 SHA-256：…

遇到的问题和错误日志（关键几行）：
- …

需要机主后续处理的事项：
- …
```
