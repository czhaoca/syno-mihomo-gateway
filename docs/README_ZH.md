# Syno-Mihomo-Gateway (透明代理网关)

[English Docs](../README.md)

"拉取即用"地部署 **Mihomo (Clash Meta)** 透明网关 —— 诞生于**群晖 NAS**，同样可以跑在**任何能
运行 Docker 的 Linux 主机（amd64 + arm64）**上，包括树莓派。家中任意设备（Apple TV、iPhone、
游戏机）只需把网关/DNS 指向该容器的局域网 IP 即可科学上网，无需安装客户端。**MetaCubeXD** 提供
网页管理面板。NAS 仍是权威的、每个发布都经过验证的部署目标（其余平台为实验性 ——
[支持层级](zh/installation-linux.md#支持层级)）。为**中国大陆**设计：镜像更新默认走
Docker Hub/ghcr → 阿里云 ACR → 你的 NAS 的流水线（`REGISTRY_MODE=docker` 可选择在无封锁的主机上
直接拉取上游镜像），并由群晖计划任务保持自动、安全、可自愈地更新。

## 功能特点
- 🚀 **自动化脚本** — 自动检测群晖网络接口（`eth0` / `ovs_eth0`）。
- 🛡️ **安全隔离** — 使用 Docker macvlan；拥有独立局域网 IP，不干扰宿主机网络。
- 🧹 **可控重新部署** — 可分别复用、安全拆除或手动处理现有网关容器和 macvlan。
- 🔧 **配置集中在 `.env`** — IP、端口、DNS、镜像仓库；仓库不提交任何密钥，模板只携带
  中性的占位示例值。
- 🔁 **订阅分离** — 机场订阅链接保存在单独的 gitignore 文件中。
- 🤖 **安全自动更新** — 按摘要检测变化，带健康检查与自动回滚；默认从阿里云 ACR 拉取
  （`REGISTRY_MODE=docker` 直接拉取上游镜像）；外部 cloudflared 采用蓝绿部署（保留隧道令牌）。
- 📦 **可更新任意容器** — 登记独立容器（`gateway.sh update --enable NAME`）；它们随同一计划任务
  更新，带运行规格捕获/回放，健康门不通过时自动回滚。

## 文档

| 指南 | 内容 |
|---|---|
| [架构](zh/architecture.md) | 组件、镜像同步→拉取流水线、macvlan 网络模型、安全模型 |
| [安装](zh/installation.md) | 完整的群晖部署流程（SSH、网络、首次启动、面板） |
| [安装 — 通用 Linux 与树莓派](zh/installation-linux.md) | 没有群晖？通用 Linux 移植（amd64 + arm64）：compose 同构或裸机 lite、支持层级、树莓派硬件与内存选型矩阵、镜像/离线安装 |
| [离线发布包](zh/release-packaging.md) | GitHub 被封锁时的离线安装：构建压缩包，在 NAS 上解压，无需 git |
| [配置](zh/configuration.md) | **完整 `.env` 参考**、模板、订阅、规则 |
| [自动更新](zh/auto-update.md) | ACR 配置、运行流程、健康检查/回滚、通用已登记目标、cloudflared 蓝绿、退出码 |
| [运维](zh/operations.md) | 运维手册：计划任务、试运行、开关、日志、通知、回滚 |
| [命令行参考](zh/cli.md) | `gateway.sh` 子命令、选项、安全护栏、退出码（由 `scripts/cli/spec.yaml` 生成） |
| [故障排查](zh/troubleshooting.md) | FAQ + 退出码 + 具体故障处理 |
| [开发](zh/development.md) | 内部实现（脚本、渲染器、CI）、编码规范、如何扩展 |

---

## DSM 兼容性

- **最低要求：DSM 7.2**（Container Manager 时代）。**推荐：DSM 7.3.1+**（自带更新的
  Docker 引擎，约 24.x）。
- 本栈的容器会**显示**在 Container Manager 的“容器”页签中，但绝不要通过“项目（Project）”
  页签管理它：其 *构建/更新* 操作会在**没有摘要门、健康门和回滚**的情况下重新拉取并重建
  容器，绕过本项目的安全模型。Container Manager 的图形界面也无法创建 macvlan 网络或管理
  特权能力，而且 CLI 创建的 compose 栈本来就不会注册为项目——受支持的管理入口是 SSH
  安装器（`sh ./install.sh`）与 `scripts/gateway.sh`。

## 快速开始

> 精简版；详见[安装](zh/installation.md)，每个配置项见[配置](zh/configuration.md)。
>
> **NAS 无法访问 GitHub（中国大陆）？** 请改用
> [离线发布包](zh/release-packaging.md)，无需第 1 步的 git clone。
>
> **完全没有群晖设备？** 网关也能跑在**任何能运行 Docker 的 Linux 主机**上
> （`sh ./install-linux.sh`），树莓派则用 `sh ./install-pi.sh` —— 支持层级、硬件选型
> 与完整流程见[安装 — 通用 Linux 与树莓派](zh/installation-linux.md)。

```bash
# 1. 下载（在群晖上，通过 SSH）
cd /volume1/docker
git clone https://github.com/czhaoca/syno-mihomo-gateway.git
cd syno-mihomo-gateway

# 2. 在发布目录旁创建持久运行数据
sh bootstrap.sh
vi ../syno-mihomo-gateway-data/.env       # 设置 ROUTER_IP、MIHOMO_IP、DNS、ACR 凭据与镜像引用（或 REGISTRY_MODE=docker）

# 3. 订阅（位于可替换的发布目录之外）
vi ../syno-mihomo-gateway-data/config/subscription.txt

# 4. 网络 + TUN（root）
sudo chmod +x scripts/setup_network.sh && sudo ./scripts/setup_network.sh

# 5. 启动
sudo docker compose --env-file ../syno-mihomo-gateway-data/.env up -d
```

**面板：** 用**群晖以外**的局域网设备打开 `http://<群晖IP>:<WEB_UI_PORT>`，添加后端
`Host=<MIHOMO_IP>`、`Port=<CONTROLLER_PORT>`（默认 `9090`）、`Secret=<CONTROLLER_SECRET>`。

> **macvlan 注意：** 群晖宿主机无法访问自己 macvlan 容器的 IP——请用其它设备打开面板与测试。
> 详见[架构](zh/architecture.md#网络模型-macvlan)。
>
> 如需引导式安装，或处理已有/部分部署，请运行 `sudo sh ./install.sh`。清理选择只会在所有
> 非破坏性校验成功后执行。

## 客户端设置

- **单设备：** 把该设备的网关与 DNS 设为 `MIHOMO_IP`。
- **全屋：** 在路由器 DHCP 中将默认网关设为 `MIHOMO_IP`。⚠️ 容器停止时这些设备将断网。

## 自动更新

由于中国大陆封锁 Docker Hub/ghcr，[`docker-china-sync`](https://github.com/czhaoca/docker-china-sync) 每晚把镜像同步到
阿里云 ACR（默认镜像来源；`REGISTRY_MODE=docker` 直接拉取上游镜像），`scripts/auto_update.sh`
（由群晖任务计划以 root 运行）只拉取、校验并部署有变化的镜像。Compose v2 用 `--pull never`
应用已校验的本地镜像；应用或健康检查失败都会回滚。同一任务还会更新任何**已登记的独立容器**
（仅限 ACR 模式）：用 `sudo sh scripts/gateway.sh update --enable NAME` / `--disable NAME` /
`--list-targets` 管理列表，用 `update --last` 查看最近一次运行结果。各目标按影响范围从小到大
依次应用：先通用容器，再 cloudflared（蓝绿部署，保留隧道令牌），最后才是网关对。
用 `sh scripts/install_scheduler.sh` 打印计划任务设置，用 `sudo sh scripts/auto_update.sh --dry-run`
试运行。

> **重启持久化：** macvlan 网络和 `/dev/net/tun` 在 NAS 重启后不会自动保留——请再添加一个
> 以**开机**为触发、以 `root` 用户运行 `scripts/setup_network.sh` 的 DSM 任务实现自愈；
> `sh scripts/install_scheduler.sh` 会打印这两个任务的设置。

详见[自动更新](zh/auto-update.md) · [运维](zh/operations.md)。

## 维护

```bash
# 更新订阅（重新渲染需要 --force-recreate）
vi ../syno-mihomo-gateway-data/config/subscription.txt
sudo docker compose --env-file ../syno-mihomo-gateway-data/.env up -d --force-recreate mihomo
# 或一步完成：sudo sh scripts/gateway.sh modify --subscription URL --yes

# 健康检查（只读；无需 root 或 --yes）
sh scripts/gateway.sh status    # 状态快照（--json 供脚本使用）
sh scripts/gateway.sh doctor    # 完整诊断（--egress 探测真实出口）

# 更新仓库
git pull && sudo sh ./install.sh
```

完整运维见[运维手册](zh/operations.md)。
