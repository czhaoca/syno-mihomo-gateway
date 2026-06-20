# 安装

[← README](../../README.md) · [English](../installation.md)
手册：[架构](architecture.md) · **安装** · [离线发布包](release-packaging.md) · [配置](configuration.md) · [自动更新](auto-update.md) · [运维](operations.md) · [故障排查](troubleshooting.md) · [开发](development.md)

---

这是详细的操作步骤。如需精简版本，请参阅
[README 快速开始](../../README.md#quick-start)。

## 前置条件

1. 已安装 **Container Manager**（Docker）的 **Synology NAS**（套件中心）。
2. 已启用 **SSH 访问**：控制面板 → 终端机和 SNMP → *启用 SSH 服务*。
3. **Root / sudo** —— 创建 macvlan 网络和 TUN 设备需要 root 权限。
4. 默认假设使用 **x86_64（Intel）NAS**（`EXPECTED_ARCH=amd64`）。如果你的型号是 ARM，
   请参阅 [自动更新 › 架构守卫](auto-update.md)。
5. （中国大陆）已有一个 **阿里云容器镜像服务（ACR）** 命名空间，并且 `docker-china-sync` 镜像
   已经在推送你的镜像 —— 请参阅 [自动更新 › ACR 设置](auto-update.md)。

## 1. 获取代码

根据你的网络情况选择方式。

### 方式 A —— git clone（可访问 GitHub）

通过 SSH 登录 NAS，并克隆到你的 docker 共享目录：

```bash
cd /volume1/docker
git clone https://github.com/czhaoca/syno-mihomo-gateway.git
cd syno-mihomo-gateway
```

### 方式 B —— 发布压缩包（中国大陆 / 无法访问 GitHub）

如果 NAS 无法访问 github.com，请不要克隆。在一台能联网的机器上构建发布压缩包，传到 NAS，
解压到 `/volume1/docker/syno-mihomo-gateway` —— 然后回到这里继续第 2-8 步。
完整流程见 [离线发布包](release-packaging.md)。

> 全文均假设使用路径 `/volume1/docker/syno-mihomo-gateway`（DSM 计划任务命令
> 和文档中都使用它）。如果你安装到其他位置，请相应调整这些路径。

## 2. 配置 `.env`

```bash
cp .env.example .env
chmod 600 .env          # it holds secrets (ACR password, tunnel token, controller secret)
vi .env
```

至少需要设置 `ROUTER_IP`、`SUBNET_CIDR`、`MIHOMO_IP`、你的 DNS 服务器，以及（中国大陆）
ACR 镜像仓库/凭据和镜像引用。每一个配置项都在
[配置](configuration.md) 中有说明。`.env` 已被 gitignore 忽略。

## 3. 添加你的订阅

```bash
cp config/subscription.txt.example config/subscription.txt
vi config/subscription.txt
```

一行内容，格式为 `Name=URL`；使用第一行有效内容。URL 中可以包含 `?token=…&flag=…` ——
这些 `=`/`&` 会被正确处理。`config/subscription.txt` 已被 gitignore 忽略，因此你的令牌
永远不会被提交。

```text
Default=https://your-provider.com/api/v1/subscribe?token=abc&flag=1
```

## 4. 创建网络 + TUN 设备

```bash
sudo chmod +x scripts/setup_network.sh
sudo ./scripts/setup_network.sh
```

此脚本会：
- 如果 `/dev/net/tun` 不存在则创建它，并修复其权限；
- 自动检测父接口（即路由到 `ROUTER_IP` 的那个接口；否则回退到
  默认路由）—— 支持 `eth0` 和 `ovs_eth0`；
- （重新）创建带有你的 `SUBNET_CIDR` / `ROUTER_IP` 的 `tproxy_network` macvlan；
- 可选地登录你的镜像仓库并拉取镜像（当设置了 `ACR_PASSWORD` 时为非交互式，
  否则会进行提示）。

## 5. 启动服务栈

```bash
sudo docker compose up -d
```

启动时，mihomo 的入口点会根据模板 + 你的订阅 + `.env` 渲染 `config/config.yaml`，
然后启动 mihomo。如果订阅 URL 或 DNS 值缺失，它会 **大声报错失败**（容器不会运行
被污染的配置）。查看日志：

```bash
docker logs mihomo
docker compose ps
sh scripts/doctor.sh
```

## 6. 打开仪表盘

从一台 **非 NAS 的局域网设备** 上访问（参见
[架构](architecture.md) 中关于 macvlan 的注意事项）：

1. 浏览到 `http://<NAS_IP>:<WEB_UI_PORT>`（例如 `http://192.168.1.10:8080`）—— 使用 **NAS** 的 IP，
   而不是 mihomo 的 IP。
2. 添加后端：**Host** = `MIHOMO_IP`（例如 `192.168.1.100`），**Port** = `CONTROLLER_PORT`
   （默认 `9090`），**Secret** = 你的 `CONTROLLER_SECRET`（如果为空则留空）。

## 7. 将设备指向网关

- **单台设备：** 将其路由器/网关和 DNS 设置为 `MIHOMO_IP`。
- **整个家庭：** 通过路由器的 DHCP 将 `MIHOMO_IP` 作为网关下发。⚠️ 如果
  容器停止，这些设备会失去网络连接 —— 请保持 `restart: always`（默认），并考虑
  下文的开机网络任务。

## 8. 启用自动更新（推荐）

设置 DSM 任务计划程序条目，使镜像能够自我更新，并在重启后让网络自我修复。
请参阅 [运维 › 计划任务](operations.md)；用以下命令打印出确切的
设置：

```bash
sh scripts/install_scheduler.sh
```

先进行试运行以确认一切都已正确连接：

```bash
sh scripts/auto_update.sh --dry-run
```

## 更新仓库本身

```bash
cd /volume1/docker/syno-mihomo-gateway
git pull
sudo sh ./install.sh        # 选择重新部署；校验后安全地强制重建
```

你的 `.env`、`config/subscription.txt` 和 `config/config.yaml` 已被 gitignore 忽略，
不会被 `git pull` 改动。

> 通过方式 B（发布压缩包）安装的？这里没有 `git pull` —— 通过重新构建并覆盖解压压缩包来更新：
> 见 [离线发布包 › 更新离线安装](release-packaging.md#更新离线安装)。
