# 离线安装（发布压缩包）

[← README](../../README.md) · [English](../release-packaging.md)
手册：[架构](architecture.md) · [安装](installation.md) · **离线发布包** · [配置](configuration.md) · [自动更新](auto-update.md) · [运维](operations.md) · [故障排查](troubleshooting.md) · [开发](development.md)

---

标准[安装](installation.md)流程的第一步是从 GitHub `git clone`。但在**中国大陆 github.com 无法访问**，
这一步会直接失败。本指南提供替代方案：在一台**能访问 GitHub** 的机器上构建一个**发布压缩包**，
把它带到 NAS，解压到 `/volume1/docker/syno-mihomo-gateway`，然后在本地完成配置 ——
**无需 git，NAS 也无需访问 GitHub**。

压缩包**只含源码**（compose 文件、脚本、配置模板、文档），刻意**不**打包容器镜像。镜像走的是
自动更新已经在用的那条路径：由 [`docker-china-sync`](https://github.com/czhaoca/docker-china-sync)
镜像同步到你的**阿里云 ACR**，再由 NAS 从该 ACR 拉取（见第 4 步）。因此离线安装是一个双轨配置 ——
**代码走压缩包，镜像走你的 ACR 镜像** —— NAS 始终不需要访问 github.com 或 Docker Hub/ghcr。

## 何时使用

- NAS 无法访问 **github.com**（中国大陆，或屏蔽了它的网络）→ 用压缩包替代
  [安装 › 方式 A（git clone）](installation.md)。
- 你不想在 NAS 上安装/运行 `git`。
- 如果 NAS *能*访问 GitHub，标准的 `git clone` 安装更简单 —— 直接用那个。

## 1. 构建发布压缩包（在能联网的机器上）

在任意一台能访问 github.com 的工作机上（你的笔记本、一台 VPS、CI 机器）：

```bash
git clone https://github.com/czhaoca/syno-mihomo-gateway.git
cd syno-mihomo-gateway
sh scripts/ci/dsm_installer_check.sh
sh scripts/ci/lifecycle_check.sh
sh scripts/ci/auto_update_check.sh
sh scripts/ci/cloudflared_check.sh
python3 scripts/ci/package_check.py
python3 scripts/ci/privacy_check.py
python3 scripts/ci/privacy_check_test.py
docker compose --env-file .env.example config --quiet
sh scripts/package.sh                    # DSM 最终用户包（默认配置）
```

这些命令及 Woodpecker 流水线全部通过后才能发布。更新器测试使用假的 Docker/Compose
命令，在不接触真实守护进程的情况下覆盖拉取重试、镜像 ID 比较、架构拒绝、Compose
应用失败、健康回滚、计划命令引号以及 cloudflared 分阶段切换/回滚流程。

这会在 `dist/` 下生成：

```text
dist/syno-mihomo-gateway-1.0.0.zip            # 适合 File Station 图形界面解压（无需 SSH）
dist/syno-mihomo-gateway-1.0.0.tar.gz         # 解压时保留脚本的可执行位
dist/syno-mihomo-gateway-1.0.0.zip.sha256     # 校验和文件
dist/syno-mihomo-gateway-1.0.0.tar.gz.sha256
```

版本号来自仓库的 `VERSION` 文件。压缩包用 `git archive` 构建，因此**只包含被 git 跟踪的文件** ——
你的 `.env`、`config/subscription.txt`、`config/config.yaml` 绝不会被打进去。`.env.example` 和
`config/subscription.txt.example` *会*作为模板包含在内。
（维护者请参阅 [开发 › 制作发布版本](development.md#制作发布版本)。）

## 2. 把压缩包传到 NAS

用任意带外方式把 `dist/syno-mihomo-gateway-<版本>.zip`（或 `.tar.gz`）传到 NAS：

- **U 盘** —— 拷贝文件，插入 DSM 的 USB 口，在 File Station 中拷出；或
- **File Station 上传** —— 通过局域网把文件拖拽到例如 `/volume1/docker`。

如果想在传输后校验完整性，把对应的 `.sha256` 一起带上。

## 3. 解压到 `/volume1/docker`

两种压缩包都会解压出一个顶层的 `syno-mihomo-gateway/` 目录，因此在 `/volume1/docker` 内解压会把
目录树正好落在 `/volume1/docker/syno-mihomo-gateway` —— 这是所有文档和 DSM 计划任务命令都假设的路径。

- **File Station（无需 SSH）：** 右键点击 `.zip` → **解压** → 解压到 `/volume1/docker`。
- **SSH：**
  ```bash
  cd /volume1/docker
  sha256sum -c syno-mihomo-gateway-1.0.0.zip.sha256     # 可选的完整性校验
  unzip syno-mihomo-gateway-1.0.0.zip                   # 或：tar -xzf syno-mihomo-gateway-1.0.0.tar.gz
  cd syno-mihomo-gateway
  ```

> **可执行位：** File Station 解压 `.zip` 会丢掉 Unix 可执行位。下一步的 `bootstrap.sh` 会把它补回来。
> 如果你用 SSH 解压并希望直接保留可执行位（无需 bootstrap），请改用 `.tar.gz`。

## 4. 确认镜像已在你的 ACR 中

由于 Docker Hub/ghcr 同样被封锁，NAS 从**你的阿里云 ACR** 拉取镜像，而该 ACR 由
[`docker-china-sync`](https://github.com/czhaoca/docker-china-sync) 保持更新。启动服务栈前，请确认：

- `docker-china-sync` 正在把 `metacubex/mihomo` 和 `ghcr.io/metacubex/metacubexd` 镜像同步到你的
  ACR 命名空间（见其
  [配合 syno-mihomo-gateway 使用](https://github.com/czhaoca/docker-china-sync#using-with-syno-mihomo-gateway)
  一节），并且
- 在下一步里，把 `.env` 中的 `MIHOMO_IMAGE` / `METACUBEXD_IMAGE`（以及 `DOCKER_REGISTRY` /
  `ACR_NAMESPACE` / 凭据）指向该 ACR —— 完整参考见
  [配置](configuration.md) 与 [自动更新 › ACR 设置](auto-update.md)。

NAS 只需要能访问你的 ACR —— 始终不需要访问 github.com。

## 5. 配置并启动

在解压出的目录里运行首次设置脚本：

```bash
sh bootstrap.sh
```

它会从随包的示例文件生成 `.env` 和 `config/subscription.txt`（仅在不存在时），补回脚本的可执行位，
并打印后续步骤。它不写入任何密钥，也不执行任何特权操作。

从这里开始，步骤与标准安装**完全相同** —— 请按 [安装](installation.md) 文档操作：

1. [配置 `.env`](installation.md) —— 设置 `ROUTER_IP`、`MIHOMO_IP`、DNS，以及第 4 步里你的
   ACR 镜像仓库/凭据 + 镜像地址。
2. [添加你的订阅](installation.md)。
3. [创建网络 + TUN 设备](installation.md) —— `sudo ./scripts/setup_network.sh`。
4. [启动服务栈](installation.md) —— `sudo docker compose up -d`。

## 6. 验证

- [ ] 目录树位于 `/volume1/docker/syno-mihomo-gateway`。
- [ ] `.env` 存在（`chmod 600`）；`MIHOMO_IMAGE` / `METACUBEXD_IMAGE` 指向你的 ACR。
- [ ] `config/subscription.txt` 存在且填入了你的真实 URL。
- [ ] `docker images` 显示从你的 ACR 拉取的 mihomo 和 metacubexd 镜像。
- [ ] `sudo ./scripts/setup_network.sh` 成功（已创建 macvlan + TUN）。
- [ ] `docker compose up -d` 后 `docker compose ps` 显示容器健康。
- [ ] 从**非 NAS** 的局域网设备打开 `http://<NAS_IP>:<WEB_UI_PORT>` 能访问面板。

## 更新离线安装

这里没有 `git pull`。要更新**代码**：

1. 在联网机器上重新构建压缩包（`git pull && sh scripts/package.sh`）并传输过去。
2. 把它**覆盖解压**到现有目录树（`cd /volume1/docker && unzip -o syno-mihomo-gateway-<版本>.zip`）。
   你的 `.env`、`config/subscription.txt`、`config/config.yaml` 不在压缩包里，因此会被保留。
   （上游删除的文件不会被 `unzip` 删掉 —— 如有需要请手动清理过期文件。）
3. `sh bootstrap.sh`（对已有配置是空操作，仅补回可执行位），然后运行
   `sudo sh ./install.sh` 并选择**重新部署**。这样会强制渲染并启用新版网关配置；
   单独运行 `docker compose up -d` 可能不会重新创建容器。

更新**镜像**的方式不变：`scripts/auto_update.sh`（DSM 任务计划）从你的 ACR 拉取 —— 而非 GitHub ——
所以正常的[自动更新](auto-update.md)流程在离线安装上同样有效。
