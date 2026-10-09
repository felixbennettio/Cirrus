# 自托管 GitHub Actions Runner

工作流默认在 GitHub 托管的机器上运行。这个目录里的文件用来在自己的机器上运行它们。

## 选择机器

工作流通过仓库变量选择机器，值是 Runner 标签的 JSON 数组。不设置时用 GitHub 托管的机器。

```bash
gh variable set RUNNER_LINUX   --body '["self-hosted","cirrus-linux"]'
gh variable set RUNNER_MAC     --body '["self-hosted","cirrus-mac"]'
gh variable set RUNNER_WINDOWS --body '["self-hosted","cirrus-windows"]'
gh variable delete RUNNER_LINUX   # 换回 GitHub 托管的机器
```

注册令牌在仓库的 Settings → Actions → Runners → New self-hosted runner 里取，或者用 `gh api -X POST repos/<owner>/<repo>/actions/runners/registration-token`。令牌 1 小时内有效，只能用一次，不要提交到仓库，也不要打印出来。

## Linux（`runner-linux/`）：代码检查、Linux 和 Android 构建

Runner 跑在 **Ubuntu 22.04 容器**里：Linux 安装包依赖构建机器的 glibc 版本，在 22.04 上构建，打出的包在较老的发行版上也能运行。容器还把 Android SDK 等构建依赖和宿主机隔开。

```bash
cd ci/runner-linux
echo "RUNNER_TOKEN=<注册令牌>" > .env     # 只在第一次启动时需要
docker compose up -d --build
```

- 可选变量：`RUNNER_NAME`、`RUNNER_URL`（默认本仓库）、`RUNNER_MEMORY`（默认 10g）。
- 注册信息、Flutter、Gradle、pub 的缓存都在 `runner-home` 卷里，重启不需要令牌。注册成功后把令牌从 `.env` 删掉。
- 需要代理时，在本地的 `docker-compose.override.yml`（不提交）里加代理环境变量。
- 想让 `docker stop` 能正常注销 Runner，在 override 里设置 `RUNNER_MANUALLY_TRAP_SIG=1`：容器里的 `run.sh` 是 1 号进程，默认不处理 SIGTERM，被强杀后 GitHub 会报 "A session for this runner already exists"。

## macOS（`runner-mac/setup.sh`）：iOS、macOS、App Store 和 Developer ID

```bash
RUNNER_TOKEN=<注册令牌> ci/runner-mac/setup.sh
```

- Runner 作为当前用户的 launch agent 运行：用户登录后才运行，能用该用户的钥匙串。
- 需要 Xcode 和 iOS 平台组件；签名和上传用 App Store Connect API 密钥（仓库 Secrets），不需要在机器上登录 Apple ID。
- launch agent 不能带 `SessionCreate`：带了它，任务会在新的安全会话里运行，访问不到已解锁的钥匙串，codesign 报 "User interaction is not allowed"。`setup.sh` 装完会把它删掉。
- 官网直售的 Mac 版需要钥匙串里有 Developer ID Application 证书，并对私钥设置 `security set-key-partition-list`，让 codesign 不弹窗。
- 在 SSH 会话里签名会报 errSecInternalComponent，这是正常的：钥匙串只在图形会话里解锁。
- 虚拟机里的 macOS 通常没有 Metal 显卡，Flutter 在 iOS 模拟器和 macOS 上画不出画面。截图和画面检查（`glass-preview.yml`、`screenshots.yml`）要在真机或 GitHub 托管的 Mac 上跑。

## Windows

按 GitHub 的说明原生安装 Runner，标签加上 `cirrus-windows`。还需要：Visual Studio Build Tools（C++ 工具和 ATL）、Inno Setup 6、jq；Git for Windows 的 `bin` 要排在 PATH 前面，避免 `shell: bash` 调到 WSL。

## 共同说明

- 在自托管机器上，`subosito/flutter-action` 不使用 GitHub 的缓存（`cache: ${{ runner.environment == 'github-hosted' }}`）：SDK 和 pub 缓存本来就留在本机磁盘，从 GitHub 恢复反而更慢。
- 缓存的 Flutter SDK 如果出现莫名的编译错误（例如找不到框架文件），在 `_work/_tool/flutter/<版本>/flutter` 里 `git status` 看是否被改动，用 `git checkout` 恢复。
- GitHub 会自动删除离线超过 14 天的 Runner。
