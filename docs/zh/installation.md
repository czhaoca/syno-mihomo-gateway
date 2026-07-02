# 安装

[← README](../../README.md) · [English](../installation.md)
手册：[架构](architecture.md) · **安装** · [离线发布包](release-packaging.md) · [配置](configuration.md) · [自动更新](auto-update.md) · [运维](operations.md) · [CLI](cli.md) · [故障排查](troubleshooting.md) · [开发](development.md)

---

这是详细的操作步骤。如需精简版本，请参阅
[README 快速开始](../../README.md#quick-start)。

## 前置条件

1. 运行 **DSM 7.2 或更新版本**（推荐 7.3.1+，自带更新的 Docker 引擎）并已安装
   **Container Manager** 的 **Synology NAS**（套件中心）。
2. 已启用 **SSH 访问**：控制面板 → 终端机和 SNMP → *启用 SSH 服务*。
3. **Root / sudo** —— 创建 macvlan 网络和 TUN 设备需要 root 权限。
4. 默认假设使用 **x86_64（Intel）NAS**（`EXPECTED_ARCH=amd64`）。如果你的型号是 ARM，
   请参阅 [自动更新 › 架构守卫](auto-update.md#架构守卫)。
5. （中国大陆）已有一个 **阿里云容器镜像服务（ACR）** 命名空间，并且 `docker-china-sync` 镜像
   已经在推送你的镜像 —— 请参阅 [自动更新 › ACR 配置](auto-update.md#acr-配置)。

### 与 Container Manager 共存（重要）

部署完成后，容器会出现在 Container Manager 的**容器**页签——在那里查看日志和状态没有问题。
但不要通过**项目（Project）**页签管理本栈，更不要点击其 *构建/更新*：该流程会在没有摘要门、
健康门和回滚的情况下重新拉取并重建容器，绕过本项目的受控更新路径（`auto_update.sh`）。
Container Manager 的图形界面也无法创建 macvlan 网络或管理特权能力，CLI 创建的 compose 栈
也不会注册为项目。请使用 `sh ./install.sh`、`scripts/gateway.sh`（见[命令行参考](cli.md)）
或计划任务更新器。

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

> 发布包**必须**位于 Docker 共享文件夹之下——任意 `/volumeN/docker` 均可（`/volume1`
> 只是最常见的情况）。这是硬性要求，不是约定俗成：Docker 守护进程会从
> `docker-compose.yml` 所在的位置绑定挂载 `./config` 和 `./scripts`。`install.sh`
> 会最先检查这一点，位置不对时拒绝继续，并打印出确切的 `sudo mv` 命令。文档假设路径为
> `/volume1/docker/syno-mihomo-gateway`；请按你的实际卷编号调整。

## 选择安装路径

- **引导安装（推荐）：** `sudo sh ./install.sh` —— 下文介绍的交互式安装器。
  它替你填写 `.env`，在触碰正在运行的栈之前完成全部校验，并在失败时自动回滚。
- **手动：** 下面的第 2–8 步 —— 自己编辑 `.env`，运行 `setup_network.sh`，然后直接
  使用 `docker compose`。

### 引导安装（推荐）

```bash
sudo sh ./install.sh
```

第一屏选择界面语言（English/中文，保存为 `INSTALLER_LANG`）；之后的所有提示都以该语言
显示。主菜单有六项 —— **部署 / 重新部署 / 定时任务 / 修改 / 状态 / 退出** —— 上方是实时
状态横幅（尚未部署 / 不完整 / 运行中，含网关 IP 与面板地址）。**状态 / 诊断**菜单项只读
展示容器、网络与 TUN 模式，并可选运行 `scripts/doctor.sh` —— 查询“网关是否在运行”
无需进入任何流程。

**部署**端到端执行：

- 其**第一步**会盘点网关容器和 macvlan，并分别询问：保留复用、自动拆除已确认属于本项目
  的资源，还是显示命令由你手动处理 —— 把这个决策放在最前面，可让随后的接口检测保持干净。
  无关资源必须手动解决；外部的 cloudflared 容器永远不在此清理范围内。
- 接口扫描只列出带有 IPv4 地址的网卡，并根据所选网卡自动填充 `ROUTER_IP` /
  `SUBNET_CIDR`；静态 IP 提示会推荐 NAS 自身 IP 之上的下一个空闲地址（用 arping/ping
  探测），并在创建网络之前对所选 IP 再次做冲突探测。
- 当所有值都已检测到（或来自上次运行的保存值）时，会出现单屏的**快速确认界面**，一次性
  展示全部取值；拒绝后回退到逐项向导。若保存的 `MIHOMO_IP` 落在重新选择的子网之外，
  会重新询问，而不是被悄悄保留。
- `CONTROLLER_SECRET` 为空时会主动提出**自动生成**一个（拒绝即明确选择“面板不设鉴权”）。
  再次运行时按回车保留已保存的密钥，输入 `-` 则清除。
- 只有在镜像、架构、渲染配置、Compose 和网络校验全部通过**之后**才会拆除现有栈 ——
  重新部署失败绝不会拆掉正在运行的网关。部署本身带健康门并自动回滚，成功报告会指向
  菜单第 **3** 项（定时任务），用于安排自动更新。

**重新部署**同时也是 IP 冲突或首次部署失败后的恢复路径：它复用 `.env` 中保存的全部设置，
提供*按原样部署 / 编辑设置 / 更改 `MIHOMO_IP` / 重新选择接口*四个选项，重新校验后以同样的
健康门加回滚方式强制重建。

如果出了问题，诊断信息会指向安装日志：
`../syno-mihomo-gateway-data/logs/install.log`（指向统一 `gateway.log` 的符号链接）。
Ctrl-D 可以干净地退出任何提示；流程中途按 Ctrl-C 也是安全的 —— 临时的配置暂存目录
（其中保存着你的订阅令牌）会被删除，任何残留的部分状态都会被下次运行的盘点步骤检测到
并提议清理。

本页其余部分为手动路径。

## 2. 配置 `.env`

```bash
sh bootstrap.sh
vi ../syno-mihomo-gateway-data/.env
```

至少需要设置 `ROUTER_IP`、`SUBNET_CIDR`、`MIHOMO_IP`、你的 DNS 服务器，以及镜像引用 ——
镜像引用是**每一种**安装都必填的，不只是中国大陆：`docker-compose.yml` 使用 fail-closed
的 `${MIHOMO_IMAGE:?}` 形式，而 `.env.example` 附带的是无法直接拉取的 ACR 占位引用
（`registry.cn-shenzhen.aliyuncs.com/your-namespace/...`）。`REGISTRY_MODE` 选择镜像来源：
`acr`（默认）从你的私有 ACR 镜像仓库拉取 —— 需设置 `DOCKER_REGISTRY`、`ACR_NAMESPACE`、
各 `*_TAG` 以及凭据（见 [自动更新 › ACR 配置](auto-update.md#acr-配置)）；`docker` 则从
上游拉取（Docker Hub / ghcr.io —— 仅在 NAS 拥有不受过滤的互联网访问时可用）。在手动路径上，
占位引用需要你自己替换；引导安装器会根据 `REGISTRY_MODE` 为你推导。每一个配置项都在
[配置](configuration.md) 中有说明。运行时数据保存在发布目录之外，因此 ZIP 升级不会删除它。
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

这个无头脚本（同时也是 DSM 开机自愈任务）会：
- 如果 `/dev/net/tun` 不存在则创建它，并修复其权限；
- 自动检测父接口（即路由到 `ROUTER_IP` 的那个接口；否则回退到默认路由）；
- 创建或复用与你的 `SUBNET_CIDR` / `ROUTER_IP` 一致的 `tproxy_network`（默认 macvlan，
  当 `TPROXY_DRIVER=ipvlan` 时为 ipvlan）；若同名网络配置不一致，脚本会拒绝删除它。

它**不会登录镜像仓库，也不会拉取镜像** —— 这发生在引导安装器的部署流程中，或在第 5 步
`docker compose up` 拉取缺失镜像时隐式进行。

**Open vSwitch** 父接口（`ovs_eth0`）会让每条创建网络的路径都打印一条非致命的提醒：
在典型的 OVS 父接口上，macvlan 子接口**可以**被局域网访问（已实测），但某些 OVS 配置
不会把子接口的新 MAC 泛洪到对端端口。请保持 `TPROXY_DRIVER=macvlan` —— 引导安装器还会
额外询问是否切换到 `ipvlan`（默认否），但那只是一个仅供访问面板的逃生口：`ipvlan`
无法为局域网客户端路由。见[故障排查](troubleshooting.md)。

首次交互式安装，或存在既有/部分部署时，请改用[引导安装器](#引导安装推荐) ——
它前置的盘点步骤会安全地处理复用/清理决策。

## 5. 启动服务栈

```bash
sudo docker compose --env-file ../syno-mihomo-gateway-data/.env up -d
```

启动时，mihomo 的入口点会根据模板 + 你的订阅 + `.env`，把 `config.yaml` 渲染到持久化
数据目录（`../syno-mihomo-gateway-data/config/`，在容器内挂载为 `/root/.config/mihomo`
—— 不是发布目录里的 `config/`），然后启动 mihomo。如果订阅 URL 或 DNS 值缺失，它会
**大声报错失败**（容器不会运行被污染的配置）。查看日志：

```bash
docker logs mihomo
docker compose --env-file ../syno-mihomo-gateway-data/.env ps
sudo sh scripts/doctor.sh          # needs root; add --egress for a real GET through the proxy
```

## 6. 打开仪表盘

从一台 **非 NAS 的局域网设备** 上访问（参见
[架构](architecture.md#网络模型-macvlan) 中关于 macvlan 的注意事项）：

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
请参阅 [运维 › 在 DSM 上配置定时任务](operations.md#在-dsm-上配置定时任务)；用以下命令打印出确切的
设置：

```bash
sh scripts/install_scheduler.sh
```

先进行试运行以确认一切都已正确连接：

```bash
sudo sh scripts/auto_update.sh --dry-run
```

## 更新仓库本身

```bash
cd /volume1/docker/syno-mihomo-gateway
git pull
sudo sh ./install.sh        # choose Redeploy; validates and force-recreates safely
```

你的 `.env`、订阅、渲染配置和日志位于同级目录
`/volume1/docker/syno-mihomo-gateway-data`，不会被 `git pull` 或替换发布目录改动。

> 通过方式 B（发布压缩包）安装的？这里没有 `git pull` —— 通过重新构建并覆盖解压压缩包来更新：
> 见 [离线发布包 › 更新离线安装](release-packaging.md#更新离线安装)。
