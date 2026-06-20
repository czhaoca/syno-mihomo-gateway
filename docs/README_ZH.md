# Syno-Mihomo-Gateway (群晖 DSM 透明网关)

[English Docs](../README.md)

在群晖 NAS 上"拉取即用"地部署 **Mihomo (Clash Meta)** 透明网关。家中任意设备（Apple TV、iPhone、
游戏机）只需把网关/DNS 指向该容器的局域网 IP 即可科学上网，无需安装客户端。**MetaCubeXD** 提供
网页管理面板。为**中国大陆**设计：镜像更新走 Docker Hub/ghcr → 阿里云 ACR → 你的 NAS 的流水线，
并由群晖计划任务保持自动、安全、可自愈地更新。

## 功能特点
- 🚀 **自动化脚本** — 自动检测群晖网络接口（`eth0` / `ovs_eth0`）。
- 🛡️ **安全隔离** — 使用 Docker macvlan；拥有独立局域网 IP，不干扰宿主机网络。
- 🧹 **可控重新部署** — 可分别复用、安全拆除或手动处理现有网关容器和 macvlan。
- 🔧 **配置集中在 `.env`** — IP、端口、DNS、镜像仓库；仓库内不硬编码任何密钥或 DNS。
- 🔁 **订阅分离** — 机场订阅链接保存在单独的 gitignore 文件中。
- 🤖 **安全自动更新** — 从阿里云 ACR 拉取，按摘要检测变化，带健康检查与自动回滚；外部 cloudflared
  采用蓝绿部署（保留隧道令牌）。

## 文档

| 指南 | 内容 |
|---|---|
| [架构](zh/architecture.md) | 组件、镜像同步→拉取流水线、macvlan 网络模型、安全模型 |
| [安装](zh/installation.md) | 完整的群晖部署流程（SSH、网络、首次启动、面板） |
| [离线发布包](zh/release-packaging.md) | GitHub 被封锁时的离线安装：构建压缩包，在 NAS 上解压，无需 git |
| [配置](zh/configuration.md) | **完整 `.env` 参考**、模板、订阅、规则 |
| [自动更新](zh/auto-update.md) | ACR 配置、运行流程、健康检查/回滚、cloudflared 蓝绿、退出码 |
| [运维](zh/operations.md) | 运维手册：计划任务、试运行、开关、日志、通知、回滚 |
| [故障排查](zh/troubleshooting.md) | FAQ + 退出码 + 具体故障处理 |
| [开发](zh/development.md) | 内部实现（脚本、渲染器、CI）、编码规范、如何扩展 |

---

## 快速开始

> 精简版；详见[安装](zh/installation.md)，每个配置项见[配置](zh/configuration.md)。
>
> **NAS 无法访问 GitHub（中国大陆）？** 请改用
> [离线发布包](zh/release-packaging.md)，无需第 1 步的 git clone。

```bash
# 1. 下载（在群晖上，通过 SSH）
cd /volume1/docker
git clone https://github.com/czhaoca/syno-mihomo-gateway.git
cd syno-mihomo-gateway

# 2. 配置（.env 含密钥）
cp .env.example .env && chmod 600 .env && vi .env       # 设置 ROUTER_IP、MIHOMO_IP、DNS、（中国）ACR 凭证与镜像地址

# 3. 订阅（gitignore，令牌不会被提交）
cp config/subscription.txt.example config/subscription.txt && vi config/subscription.txt

# 4. 网络 + TUN（root）
sudo chmod +x scripts/setup_network.sh && sudo ./scripts/setup_network.sh

# 5. 启动
sudo docker compose up -d
```

**面板：** 用**群晖以外**的局域网设备打开 `http://<群晖IP>:<WEB_UI_PORT>`，添加后端
`Host=<MIHOMO_IP>`、`Port=<CONTROLLER_PORT>`（默认 `9090`）、`Secret=<CONTROLLER_SECRET>`。

> **macvlan 注意：** 群晖宿主机无法访问自己 macvlan 容器的 IP——请用其它设备打开面板与测试。
> 详见[架构](zh/architecture.md#网络模型-macvlan)。
>
> 首次安装或处理已有/部分部署时，请运行 `sudo sh ./install.sh`。清理选择只会在所有非破坏性
> 校验成功后执行。

## 客户端设置

- **单设备：** 把该设备的网关与 DNS 设为 `MIHOMO_IP`。
- **全屋：** 在路由器 DHCP 中将默认网关设为 `MIHOMO_IP`。⚠️ 容器停止时这些设备将断网。

## 自动更新

由于中国大陆封锁 Docker Hub/ghcr，[`docker-china-sync`](https://github.com/czhaoca/docker-china-sync) 每晚把镜像同步到
阿里云 ACR，`scripts/auto_update.sh`（由群晖任务计划以 root 运行）只拉取、校验并部署有变化的镜像。
Compose v2 用 `--pull never` 应用已校验的本地镜像；应用或健康检查失败都会回滚。外部 cloudflared 走蓝绿部署。
用 `sh scripts/install_scheduler.sh` 打印计划任务设置，用 `sh scripts/auto_update.sh --dry-run`
试运行。详见[自动更新](zh/auto-update.md) · [运维](zh/operations.md)。

## 维护

```bash
# 更新订阅
vi config/subscription.txt && docker compose up -d mihomo

# 更新仓库
git pull && docker compose up -d
```

完整运维见[运维手册](zh/operations.md)。
