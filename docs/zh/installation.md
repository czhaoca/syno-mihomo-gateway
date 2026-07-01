# 安装

[← README](../../README.md) · [English](../installation.md)
手册：[架构](architecture.md) · **安装** · [离线发布包](release-packaging.md) · [配置](configuration.md) · [自动更新](auto-update.md) · [运维](operations.md) · [故障排查](troubleshooting.md) · [开发](development.md)

---

这是详细的操作步骤。如需精简版本，请参阅
[README 快速开始](../../README.md#quick-start)。

## 前置条件

1. 运行 **DSM 7.2 或更新版本**（推荐 7.3.1+，自带更新的 Docker 引擎）并已安装
   **Container Manager** 的 **Synology NAS**（套件中心）。
2. 已启用 **SSH 访问**：控制面板 → 终端机和 SNMP → *启用 SSH 服务*。
3. **Root / sudo** —— 创建 macvlan 网络和 TUN 设备需要 root 权限。
4. 默认假设使用 **x86_64（Intel）NAS**（`EXPECTED_ARCH=amd64`）。如果你的型号是 ARM，
   请参阅 [自动更新 › 架构守卫](auto-update.md)。
5. （中国大陆）已有一个 **阿里云容器镜像服务（ACR）** 命名空间，并且 `docker-china-sync` 镜像
   已经在推送你的镜像 —— 请参阅 [自动更新 › ACR 设置](auto-update.md)。

### 与 Container Manager 共存（重要）

部署完成后，容器会出现在 Container Manager 的**容器**页签——在那里查看日志和状态没有问题。
但不要通过**项目（Project）**页签管理本栈，更不要点击其 *构建/更新*：该流程会在没有摘要门、
健康门和回滚的情况下重新拉取并重建容器，绕过本项目的受控更新路径（`auto_update.sh`）。
Container Manager 的图形界面也无法创建 macvlan 网络或管理特权能力，CLI 创建的 compose 栈
也不会注册为项目。请使用 `sh ./install.sh`、`scripts/gateway.sh` 或计划任务更新器。

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
sh bootstrap.sh
vi ../syno-mihomo-gateway-data/.env
```

至少需要设置 `ROUTER_IP`、`SUBNET_CIDR`、`MIHOMO_IP`、你的 DNS 服务器，以及（中国大陆）
ACR 镜像仓库/凭据和镜像引用。每一个配置项都在
[配置](configuration.md) 中有说明。运行时数据保存在发布目录之外，覆盖发布 ZIP 不会删除它；
`bootstrap.sh` 也会自动迁移旧版目录内的 `.env`。

## 3. 添加你的订阅

```bash
vi ../syno-mihomo-gateway-data/config/subscription.txt
```

一行内容，格式为 `Name=URL`；使用第一行有效内容。URL 中可以包含 `?token=…&flag=…` ——
这些 `=`/`&` 会被正确处理。该文件位于仓库之外，因此令牌不会被提交或被新发布包覆盖。

```text
Default=https://provider.example/api/v1/subscribe?token=REPLACE_ME&flag=1
```

## 4. 创建网络 + TUN 设备

```bash
sudo chmod +x scripts/setup_network.sh
sudo ./scripts/setup_network.sh
```

此脚本会：
- 如果 `/dev/net/tun` 不存在则创建它，并修复其权限；
- 自动检测父接口（即路由到 `ROUTER_IP` 的那个接口；否则回退到默认路由）。**Open vSwitch**
  父接口（`ovs_eth0`）没有问题——在 OVS 上 macvlan 子接口的 IP 也可被局域网其他设备访问（已实测），
  因此请保持 `TPROXY_DRIVER=macvlan`，不要改用 `ipvlan`（`ipvlan` 无法为局域网客户端路由）——
  见[故障排查](troubleshooting.md)；
- 创建或复用与 `SUBNET_CIDR` / `ROUTER_IP` 一致的 `tproxy_network`（默认 macvlan，
  当 `TPROXY_DRIVER=ipvlan` 时为 ipvlan）；若同名网络配置不一致，脚本会拒绝隐式删除；
- 可选地登录你的镜像仓库并拉取镜像（当设置了 `ACR_PASSWORD` 时为非交互式，
  否则会进行提示）。

安装器菜单上方会显示实时状态横幅（尚未部署 / 不完整 / 运行中，含网关 IP 与面板地址），
并提供“状态 / 诊断”菜单项：只读展示容器、网络与 TUN 模式，并可选运行 `scripts/doctor.sh`
——查询“网关是否在运行”不再需要进入任何流程。

若已有或曾经部分部署，请改用 `sudo sh ./install.sh`。它的**第一步**会盘点网关容器和 macvlan，
并分别询问：保留复用、自动拆除已确认属于本项目的资源，或显示命令后由你手动处理——把这个决策
放在最前面，可让随后的接口检测保持干净。接口选择随后只列出带有 IP 地址的网卡，静态 IP 提示也会
基于 NAS 自身 IP 之上推荐下一个空闲地址（用 arping/ping 探测），而非固定占位值。手动模式不会删除
任何资源，完成后可重新扫描。自动拆除仍只会在镜像、架构、渲染配置、Compose 和网络校验全部通过
后执行——重新部署失败绝不会拆掉你正在运行的网关。无关资源必须手动解决；外部 cloudflared 永远
不在此清理范围内。

## 5. 启动服务栈

```bash
sudo docker compose --env-file ../syno-mihomo-gateway-data/.env up -d
```

启动时，mihomo 的入口点会根据模板 + 你的订阅 + `.env` 渲染 `config/config.yaml`，
然后启动 mihomo。如果订阅 URL 或 DNS 值缺失，它会 **大声报错失败**（容器不会运行
被污染的配置）。查看日志：

```bash
docker logs mihomo
docker compose --env-file ../syno-mihomo-gateway-data/.env ps
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

你的 `.env`、订阅、渲染配置和日志位于同级目录
`/volume1/docker/syno-mihomo-gateway-data`，不会被 `git pull` 或替换发布目录改动。

> 通过方式 B（发布压缩包）安装的？这里没有 `git pull` —— 通过重新构建并覆盖解压压缩包来更新：
> 见 [离线发布包 › 更新离线安装](release-packaging.md#更新离线安装)。
