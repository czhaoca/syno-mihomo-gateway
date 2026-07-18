# 安装 — 通用 Linux 与树莓派

[← README](../../README.md) · [English](../installation-linux.md)
平台补充篇：**通用 Linux 与树莓派**。群晖 DSM 的完整流程见[安装](installation.md)；
其链接的各页（配置、自动更新、故障排查等）除非本页另有说明，同样适用于这些主机。

---

没有群晖设备？本网关诞生于群晖 NAS，但同样可以跑在**任何能运行 Docker 的 Linux 主机
（amd64 + arm64）**上 —— 迷你主机、家用实验室虚拟机、arm64 开发板或**树莓派** ——
使用各自的附加安装器：

```bash
sudo sh ./install-linux.sh   # 通用 Linux 主机（amd64 / arm64）
sudo sh ./install-pi.sh      # 树莓派（同一引擎 + 树莓派硬件向导）
```

DSM 路径不受影响 —— `install.sh` 仍然只服务群晖；两个入口复用同一套底层机制。
树莓派上用 `install-pi.sh`（它了解下文的板子档位）；其他机器一律用 `install-linux.sh`。
两种安装**模式**覆盖不同的硬件档位：

- **Compose 模式** —— 与 DSM 完全相同的 Docker 栈（mihomo + metacubexd 容器、macvlan、
  按摘要检测的自动更新，带健康门与回滚）。只要硬件允许就优先选它，因为成熟的更新安全
  模型都在这条路径上。
- **裸机 "lite" 模式** —— 完全不用 Docker：原生 mihomo 二进制以 systemd 服务运行，并由
  mihomo 自己托管 MetaCubeXD 面板（`external-ui`）。正是它让小内存设备成为可行选项 ——
  也是 [macvlan 不友好主机](#macvlan-不友好主机云--虚拟机)（云虚拟机、仅 Wi-Fi 的机器）
  上的推荐答案。

## 支持层级

本矩阵是**权威版本** —— README 和其他页面只链接到这里，不再复述。

| 平台 | 层级 | 含义 |
|---|---|---|
| **群晖 DSM（NAS）** | **必须经所有者验证** | 权威部署目标。每个发布在打标签之前都会在真实 NAS 硬件上验证；DSM 测试套件是冻结的门禁。 |
| **树莓派** | 实验性 | 可用且有 CI 覆盖，但发布不在树莓派硬件上验证；支持为尽力而为。 |
| **通用 Linux（amd64 + arm64）** | 实验性 | 与树莓派同级：有 CI 覆盖、社区/尽力而为支持，发布不做逐版硬件验证。 |

## 硬件与模式矩阵

本节是**权威版本** —— 其他页面只链接到这里，不再复述。

**通用主机：** 任何 64 位（amd64/arm64）、内存 ≥ 1 GB 且有有线以太网的机器都能跑
compose 模式；更小、仅 Wi-Fi 的主机以及
[macvlan 不友好环境](#macvlan-不友好主机云--虚拟机)请用 lite 模式。下面的内存下限适用于
任何 Linux 主机，不只是树莓派。

**最低内存：** lite 模式约 **256 MB（精调后）/ 512 MB（宽裕）**；compose 模式
**≥ 1 GB（最低，需精调）/ ≥ 2 GB（宽裕）**。依据：开启 TUN + fake-ip 时 mihomo 稳态占用
约 60–100 MB RSS，Raspberry Pi OS Lite 空载约 100–125 MB，compose 模式下 dockerd +
containerd 还要再加约 140–180 MB —— 整个 compose 栈在客户端流量之前就要 450–550 MB。
省内存最有效的手段是 `.mrs` 规则集和干脆不用 Docker（见[低内存运维](#低内存运维)）。

> 256/512 MB 数字是按 mihomo 的 RSS 实测推算的，尚未在真实的 512 MB 硬件上跑持续客户端
> 负载验证过 —— 请把 lite 的下限当作参考并留出余量（zram 有助于吸收 geodata 加载时的
> 内存尖峰）。

| | Compose 模式 | Lite 模式 |
|---|---|---|
| 引擎 | Docker compose（与 DSM 相同的栈） | 原生 mihomo 二进制 + systemd |
| 面板 | metacubexd 容器 | mihomo 自己托管：`http://<主机IP>:<CONTROLLER_PORT>/ui` |
| 网络模型 | macvlan —— 网关拥有**独立**局域网 IP | 宿主直绑 —— **主机自己的 IP** 就是客户端的网关/DNS |
| 网卡 | **必须有线以太网**（macvlan 在 Wi-Fi 上不可用） | 有线或 Wi-Fi 均可 |
| 操作系统 | **必须 64 位**（面板镜像没有 32 位版本） | 64 位或 32 位均可（有 armv7/armv6 二进制） |
| 内存 | ≥ 1 GB 最低，≥ 2 GB 宽裕 | 约 256 MB（精调），512 MB 宽裕 |
| 自动更新 | `scripts/auto_update.sh`，原样复用（摘要门 → 健康门 → 回滚） | `scripts/pi/auto_update_lite.sh`（校验阶梯 → 健康门 → `.prev` 回滚） |

### 树莓派型号

按型号的结论（`install-pi.sh` 会检测板子并给出对应推荐）。本表评估的是**树莓派硬件**
对网关角色的胜任程度；所有树莓派在发布层面的支持级别以上文的[支持层级](#支持层级)
矩阵为准：

| 档位 | 型号 | 结论 |
|---|---|---|
| 不适合全屋网关 | Pi 1 A/B/B+（ARMv6，256–512 MB） | ARMv6 没有任何容器镜像，加密吞吐上限约 30–40 Mbps，网卡缺失或受 USB2 限制。lite 模式能跑，但必须先通过[尽力而为确认](#armv6-板子仅尽力而为支持)。 |
| 尽力而为，仅 lite | Pi Zero / Zero W（ARMv6）；Pi Zero 2 W（512 MB，仅 Wi-Fi）；Pi 2B（1 GB，armv7，百兆网卡） | 原生二进制 + 自带面板。Zero 2 W 是其中最好的（ARMv8 四核），但 512 MB 内存和仅 Wi-Fi 的网卡把它留在 lite 模式。 |
| 可用（需精调） | Pi 3B / 3B+（1 GB） | 在**64 位系统**上 compose 可用，需低内存精调（`.mrs` 规则集、zram）；lite 模式余量最大。安装器两种都会提供。 |
| 推荐 | Pi 4B（≥ 2 GB，真千兆网口） | DSM 拓扑原样照搬 —— compose + TUN + macvlan，无需精调。 |
| 富余 | Pi 5 | 毫无压力。 |

吞吐量预期（乐观上限 —— 透明网关要做约两倍的加密工作，实际数字会低于这些）：ARMv6 约
30–40 Mbps（填不满 100 Mbps 宽带）；四核 A53 档（Pi 3、Zero 2 W）约 270 Mbps；Pi 4B 约
760 Mbps —— 第一个能喂饱千兆级宽带的档位。近年的 amd64 迷你主机 / NUC 级设备则轻松
超过千兆并留有余量。

**老树莓派行不行（简短回答）：** ARMv6 板子**不适合**全屋网关。真正够用的最早型号是
Pi 2B（lite，尽力而为）和 Pi 3B/3B+（可用，64 位系统上精调后可跑 compose）；
Pi 4B ≥ 2 GB 是推荐的甜点位。

## Macvlan 不友好主机（云 / 虚拟机）

Compose 模式把网关放在带有独立局域网 IP 的 **macvlan** 子接口上 —— 这要求网络链路愿意
投递发往端口上第二个、未知 MAC 的帧：云 VPC（AWS/GCP/阿里云等）会过滤未知源 MAC，
部分虚拟交换机也会丢弃它们。因此 `install-linux.sh` 带有一道 **macvlan 可行性守卫**：
检测到虚拟化/云主机时（通过 `systemd-detect-virt`，无 systemd 时回退读 DMI）它会发出
警告、建议 lite 模式，并在任何 macvlan 部署之前要求明确确认（默认**否**）——
部署时拒绝确认会把安装引导进 lite 模式而不是中止；而在重新部署/修改路径上，拒绝会在
**任何东西被拆除之前直接中止**，现有部署保持原样（把已安装的栈切换到 lite 要走
**部署**的模式向导）。该检测在设计上就是启发式的：桥接组网的家用实验室虚拟机
（Proxmox/ESXi 且虚拟交换机不过滤 MAC）上 macvlan 明明可用也可能触发警告 ——
在那里确认警告、照常部署 compose 即可。见
[故障排查](troubleshooting.md#通用-linuxmacvlan-不友好主机云虚拟机--vpc--wi-fi)。

## 前置条件

1. **基于 systemd 的 Linux**（Raspberry Pi OS 或其他 Debian 系发行版是经过测试的路径）。
   compose 模式要求 **64 位**系统。
2. **Root / sudo** —— 部署需要 TUN 设备、53 端口，compose 模式还需要 Docker。
3. `curl` 或 `wget`。lite 模式解析 mihomo *最新*版本号必须用 `curl` —— 固定
   `MIHOMO_VERSION` 后两者皆可。
4. **仅 compose 模式：** Docker Engine + compose v2、**有线以太网**，以及
   [macvlan 可行的网络环境](#macvlan-不友好主机云--虚拟机)。
5. 把代码放到主机上 —— `git clone` 或[离线发布包](release-packaging.md)。与 DSM 不同，
   **没有目录位置要求**：任何可写目录都行（安装器只检查可写性）。

## 运行安装器

```bash
sudo sh ./install-linux.sh   # 树莓派上：sudo sh ./install-pi.sh
```

第一屏选择界面语言（保存为 `INSTALLER_LANG`），与 DSM 安装器一致；主菜单同样是六项 ——
**部署 / 重新部署 / 计划任务 / 修改 / 状态 / 退出** —— 上方有实时状态横幅。相对 DSM
流程，这两个入口额外提供：

- **部署**从**硬件横幅 + 模式向导**开始：读取机器信息（树莓派上还包括板子型号）、可用
  内存和 CPU 架构，然后给出模式推荐 —— ≥ 2 GB 档 → compose；约 1 GB 档 → compose 并提示
  低内存精调（同时提供 lite）；512 MB 档或任何 32 位系统 → lite；ARMv6 还需额外通过
  尽力而为确认。在硬件允许的范围内可以不接受推荐、自行选择。在 `install-linux.sh` 上，
  [macvlan 可行性守卫](#macvlan-不友好主机云--虚拟机)运行在向导与 compose 部署之间。
- **镜像来源向导的默认值随入口而异**（compose 模式）：`install-linux.sh` 默认提供
  **`REGISTRY_MODE=docker`**（上游 Docker Hub / ghcr.io 多架构清单）—— 中国大陆以外的
  正确选择，无需镜像同步流水线 —— 同时保留 `acr` 供中国大陆用户选择（并附下文的 arm64
  同步提示）。`install-pi.sh` 保持 DSM 式的 `acr` 默认。无论哪种，选择只写入你本机
  gitignore 的 `.env`。
- **状态**按记录的安装模式分发：lite 机器上通过
  [`lite_ctl`](#日常运维lite_ctl) 汇报，而不是检查容器。

所选模式记录在 `../syno-mihomo-gateway-data/state/install-mode`（标记令牌在所有入口上
保持 `pi-compose` / `pi-lite` 的名字）；运行数据与 DSM 一样放在同级的
`../syno-mihomo-gateway-data` 目录。

## Compose 模式

部署本身就是原封不动的 DSM 流水线 —— 接口扫描、快速确认屏、先校验后拆除、带回滚的健康
门启动 —— 因此从部署步骤起，[安装](installation.md)的流程逐字适用。通用/树莓派包装层
只在前面加了四道守卫：

- **`EXPECTED_ARCH` 自动固定为本机架构**（种子默认值 `amd64` 否则会让每台 arm64 主机
  都过不了架构门）。见[自动更新 › 架构守卫](auto-update.md#架构守卫)。
- **macvlan 可行性守卫**（仅 `install-linux.sh`）—— 见
  [Macvlan 不友好主机](#macvlan-不友好主机云--虚拟机)。
- **ACR arm64 前置条件（若选择 `acr`，第一次拉取前务必读）。** 默认的
  [docker-china-sync](https://github.com/czhaoca/docker-china-sync) 流水线**只同步
  amd64** —— 所以在 arm64 主机上，你的 ACR 命名空间必须在首次部署**之前**先同步好
  arm64 镜像，否则每次拉取都会拉到被架构门拒绝的镜像。可操作的做法：给镜像清单加上
  arm64 平台（在 `docker-china-sync/images.txt` 中对每个镜像使用
  `--platform=linux/amd64,linux/arm64`），等一轮同步跑完再部署。安装器会在任何拉取发生
  之前打印这条提示。网络无封锁时，`REGISTRY_MODE=docker`（上游多架构清单 ——
  `install-linux.sh` 的默认值）即可开箱即用。
- **拒绝把 Wi-Fi 作为 macvlan 父接口。** Wi-Fi 驱动和 AP 客户端隔离通常会让 macvlan
  子接口失效，因此 compose 模式要求**有线以太网**；凡是会（重新）创建网络的路径，安装器
  一律拒绝 `wl*` 父接口。仅有 Wi-Fi 的机器请用 lite 模式。

部署之后的一切 —— 从非宿主设备访问面板、把客户端指向 `MIHOMO_IP`、
[自动更新](auto-update.md) —— 与 DSM 文档描述的行为完全一致。

## Lite 模式（裸机）

lite 模式把 mihomo 作为**原生二进制跑在 systemd 下** —— 没有 Docker，没有 macvlan。
mihomo 直接绑定主机的网卡：客户端把**主机自己的 IP** 设为网关/DNS，面板由 mihomo
本体托管在 `http://<主机IP>:<CONTROLLER_PORT>/ui`（默认端口 `9090`）。

向导依次询问：控制器端口与面板密钥（与 DSM 安装器相同的"回车保留 / `-` 清除"语义）、
三组 DNS、时区，然后是 lite 专属的制品设置 ——
[`GH_MIRROR`](#gh_mirror-与离线预放置)、可选的 `MIHOMO_VERSION` 版本固定，以及（仅在
固定版本时）可选的 `MIHOMO_SHA256` 完整性锚点。订阅使用与 DSM 相同的订阅向导。如果
53 端口已被其他进程占用（系统自带解析器 —— 见
[故障排查](troubleshooting.md#树莓派-lite53-端口已被占用)），向导会当场警告，而不是让
首次启动莫名失败。

安装过程快速失败，出错时不会留下半装状态：

1. **先渲染配置** —— 与容器使用同一个经 CI 测试的渲染器；订阅或 DNS 缺失会在下载任何
   东西之前就中止。
2. **解析版本号** —— `MIHOMO_VERSION` 固定值原样使用，否则跟随 `releases/latest`
   跳转（*经过* `GH_MIRROR`）。
3. **下载并校验二进制** —— 失败即关闭的校验阶梯：可选的固定 sha256 → gzip 完整性 →
   执行并打印版本的冒烟测试 → 报告的版本必须与版本号一致。全部通过后才移动到位
   （`bin/mihomo`），并把版本号记入 `state/lite/version`。
4. **下载面板** —— MetaCubexD 的带版本 `compressed-dist.tgz` 发布资产，解压到
   `ui/metacubexd`（渲染出的配置里 `external-ui` 指向的位置）。
5. **预取 geodata**（尽力而为）—— 通过渲染配置中已有的 CDN 镜像地址；失败也没关系，
   mihomo 首次启动会自己下载。
6. **安装 systemd 服务** —— `/etc/systemd/system/mihomo-gateway.service` —— 然后启用 +
   启动，并等待控制器应答。

服务单元保持最小化、由安装器再生成（请勿手改）：`Restart=always`，且 `ExecStartPre`
**每次启动前重新渲染配置** —— 因此改完 `subscription.txt` 或 `.env` 只需
`sudo sh scripts/pi/lite_ctl.sh stop && sudo sh scripts/pi/lite_ctl.sh start`（或
`systemctl restart mihomo-gateway`）即可生效。

## `GH_MIRROR` 与离线预放置

lite 模式的制品（mihomo 二进制、面板压缩包、最新版本号解析）都从上游 Git 托管站下载，
而许多网络访问不到它。两条出路：

**镜像前缀。** 在 `.env` 中把 `GH_MIRROR` 设为 gh-proxy 风格的镜像站，所有下载地址都会
加上该前缀（`<镜像站>/<完整上游地址>`）；留空表示直连。中文界面的向导会在提问时给出
这条建议。镜像站自行选择 —— 公共 gh-proxy 实例或自建均可；选择只保存在你本机 gitignore
的 `.env` 里。当下载经过第三方镜像时，请固定 `MIHOMO_VERSION` **并**设置
`MIHOMO_SHA256`（上游不发布校验和；"固定版本 + sha256 锚点"能把篡改的镜像变成硬失败，
而不是悄悄装上错误的二进制）。

**完全离线预放置**（对应 DSM 的[离线发布包](release-packaging.md)模式）：在能联网的
机器上下载，预先放到数据目录下，安装器/更新器就用现成文件而不再下载 —— 同一套校验阶梯
仍然全部执行：

```
../syno-mihomo-gateway-data/bin/mihomo-linux-<架构>-<版本>.gz   # 架构：amd64|arm64|armv7|armv6
../syno-mihomo-gateway-data/ui/compressed-dist.tgz              # MetaCubexD 发布资产
```

同时设置 `MIHOMO_VERSION=<版本>`，这样就完全不需要联网解析版本号（二进制文件名必须带
同一个版本号，例如 `mihomo-linux-arm64-v1.19.28.gz`）。

## 日常运维：`lite_ctl`

lite 模式没有容器可供 `gateway.sh`/`doctor.sh` 检查，所以自带一个小 CLI（在 lite 机器上，
安装器的**状态**菜单项会替你调用它）：

```bash
sh scripts/pi/lite_ctl.sh {status|doctor|start|stop|update [--dry-run|--force]}
```

- `status` —— 只读快照：安装模式、已装版本、服务状态、最近一次更新运行、面板地址。
- `doctor` —— 只读诊断，词汇与退出码与 `doctor.sh` 一致：`0` 健康 / `2` 降级 /
  `3` 损坏。检查项：`.env` 解析、systemd 与服务单元、受管二进制与版本状态、订阅存在性
  加渲染检查（在一次性临时目录中进行 —— 绝不触碰线上配置）、控制器探测与 TUN 链路、
  53 端口占用（指出占用进程名）、以及自动更新 cron 条目是否真的已部署。
- `start` / `stop` —— 需 root 的 systemd 服务包装。
- `update` —— 前台运行
  [lite 二进制更新器](auto-update.md#树莓派-lite-模式二进制更新器)，参数与 cron 相同。

## 自动更新

菜单第 **3 项（计划任务）**为**两种**模式安排更新计划 —— 这些主机上没有 DSM 任务计划，
因此它管理 `/etc/crontab` 中的一行（幂等维护：换时间重跑会替换受管行，其他人的行绝不
触碰）。它询问每日 `HH:MM`、更新器时区和 `UPDATE_ENABLED` 总开关，然后按记录的安装模式
装入对应条目 —— `scripts/auto_update.sh`（compose，与 DSM 无异）或
`scripts/pi/auto_update_lite.sh`（lite）—— 并提供立即 `--dry-run` 一次的选项。

lite 更新器完整继承 compose 更新器的运行契约 —— 锁、总开关、`--dry-run`/`--force`、
轮转日志、last-run JSON、通知、退出码 —— 新二进制过不了健康门时回滚到上一个二进制
（连同版本状态一起回退），坏版本会在下一次计划运行时干净地重试。详见
[自动更新 › 树莓派 lite 模式二进制更新器](auto-update.md#树莓派-lite-模式二进制更新器)。

## 低内存运维

面向 512 MB–1 GB 档位的文档级指引（安装器不会自动做这些）：

- **`.mrs` 规则集** —— mihomo 最大的内存杠杆：二进制格式规则集的加载内存只有传统
  provider 的零头。订阅/规则集配置里能用 `.mrs` 就用。mihomo 默认的
  `geodata-loader: memconservative` 已经在用速度换内存。
- **zram 交换** —— 压缩内存交换能吸收 512 MB 板子上 geodata 加载的内存尖峰
  （Raspberry Pi OS / Debian 上装 `zram-tools`）。
- **SD 卡日志卫生** —— journald 的 `Storage=volatile`（日志进内存）和/或 `log2ram`
  避免网关的高频日志磨损 SD 卡；本项目自身的日志会自我轮转（`LOG_KEEP`）。
- **不要用桌面版系统镜像** —— Raspberry Pi OS **Lite** 空载约 100–125 MB；桌面版要多
  烧几百兆。

## ARMv6 板子：仅尽力而为支持

Pi 1 / Zero / Zero W 能完成 lite 安装（上游提供 armv6 二进制），但必须先在向导中通过
明确的确认，因为结果只是**实验/单设备玩具，不是全屋网关**：加密吞吐约 30–40 Mbps、
网卡缺失或受 USB2 限制、ARMv6 完全没有容器镜像（compose 模式不可能）。请在知情的前提
下接受这一取舍；ARMv6 上的问题按尽力而为处理。

## 故障排查

平台专属条目在主指南中：[macvlan 不友好主机（云虚拟机 / VPC /
Wi-Fi）](troubleshooting.md#通用-linuxmacvlan-不友好主机云虚拟机--vpc--wi-fi) · [ACR
未同步 arm64 镜像](troubleshooting.md#树莓派acr-未同步-arm64-镜像) · [lite
更新被回滚](troubleshooting.md#树莓派-lite更新被回滚) · [Wi-Fi 上的 macvlan
被拒绝](troubleshooting.md#树莓派wi-fiwlan0上的-macvlan-被拒绝) · [53
端口已被占用](troubleshooting.md#树莓派-lite53-端口已被占用)。其余非平台特有的问题
（DNS 症状、订阅、面板）与网关本体相同 —— 整本[故障排查](troubleshooting.md)都适用。
