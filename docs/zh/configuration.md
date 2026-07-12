# 配置参考

[← README](../../README.md) · [English](../configuration.md)
手册：[架构](architecture.md) · [安装](installation.md) · [离线发布包](release-packaging.md) · **配置** · [自动更新](auto-update.md) · [运维](operations.md) · [CLI](cli.md) · [故障排查](troubleshooting.md) · [开发](development.md)

---

本文档是每一个配置项的**唯一可信来源**。所有真实取值都保存在
`../syno-mihomo-gateway-data/.env` 中（由 `bootstrap.sh` 从 `.env.example` 创建并执行 `chmod 600`）。提交到仓库的配置模板
只包含 `{{PLACEHOLDERS}}` 占位符——不会硬编码任何 DNS 服务器或网络地址。

## 文件

| 文件 | 是否纳入版本控制 | 用途 |
|---|---|---|
| `../syno-mihomo-gateway-data/.env` | 否（仓库外） | 你的全部设置与密钥。由 `bootstrap.sh` 创建。 |
| `.env.example` | 是 | `.env` 的带注释模板。 |
| `../syno-mihomo-gateway-data/config/subscription.txt` | 否（仓库外） | 你的服务商订阅 URL（`Name=URL`，使用第一条有效行）。 |
| `config/subscription.txt.example` | 是 | 上述文件的模板。 |
| `config/config.template.yaml` | 是 | 带 `{{PLACEHOLDERS}}` 占位符的 Mihomo 配置。 |
| `../syno-mihomo-gateway-data/config/config.yaml` | 否（仓库外） | 在容器启动时渲染生成。切勿手动编辑。 |

## `.env` 参考

图例 —— **Req**：网关运行所必需 · **Upd**：自动更新所必需 ·
**Sec**：密钥（请保持 `.env` 为 `chmod 600`）。

安装程序把 `.env` 当作 dotenv 数据读取，而不会作为 shell 程序执行。自动生成的值使用
Compose 兼容的引号，因此包含空格、`&`、`#`、`$`、引号或反斜杠的密码也能安全保存。
手动编辑时，每行只写一个 `KEY=VALUE`。

### 网络

| 键 | Req | 说明 | 示例 |
|---|:--:|---|---|
| `ROUTER_IP` | ✅ | 你的路由器/网关 IP。用于自动探测 macvlan 的父接口。 | `192.168.1.1` |
| `SUBNET_CIDR` | ✅ | 用于 macvlan 网络的局域网子网。 | `192.168.1.0/24` |
| `MIHOMO_IP` | ✅ | 分配给 mihomo 容器的静态局域网 IP。**必须是未被占用的地址**——安装器会在所选接口上，基于 NAS 自身 IP 之上推荐下一个空闲地址（用 arping/ping 扫描），并在部署前再次检测冲突。 | `192.168.1.100` |
| `PARENT_INTERFACE` | | macvlan 父接口（局域网网卡）。安装器会从接口扫描结果填入（无 IP 地址的网卡会被隐藏）；留空则自动检测（开机自愈任务也会自动检测）。 | `eth0` |
| `TPROXY_DRIVER` | | 网关网络的二层驱动：`macvlan`（默认）或 `ipvlan`。请保持 `macvlan`——它是网关**转发**角色所必需，且即便在 **Open vSwitch** 父接口（`ovs_eth0`）上，macvlan 子接口的 IP **也可被局域网其他设备访问**（已实测；OVS 不会破坏这一点）。`ipvlan` 按目的 IP 解复用，**不会**为局域网客户端经代理路由，因此不要用它作为网关。 | `macvlan` |

### Mihomo TUN

| 键 | Req | 说明 | 默认值 |
|---|:--:|---|---|
| `TUN_ENABLE` | | 透明网关 TUN。默认 **`true`**（开启）——渲染配置带有使用 **`system` 栈**的 `tun:` 块（并配 `allow-lan: true` 与 `enhanced-mode: fake-ip`），局域网设备把网关 + DNS 指向 `MIHOMO_IP` 即可经机场出网，也可把 `MIHOMO_IP:7890`/`:7891` 当作显式代理。`system` 栈**不会**截走控制器回包，因此仪表盘后端保持可达——这才是 mihomo #1493 的真正修复方式（不要关闭 TUN）。设 `TUN_ENABLE=false` 会运行**普通的非网关代理**（仅可通过 redir/tproxy/mixed/socks 端口访问，不会透明拦截局域网客户端）。仅小写 `true`/`false`。 | `true` |
| `TUN_AUTO_REDIRECT` | | 仅当 `TUN_ENABLE=true` 时生效：可选的 Linux TCP 重定向优化。DSM 上应保持 `false`，除非安装程序的一次性 iptables 兼容性探测成功。仅接受小写 `true`/`false`。 | `false` |

### 端口与控制器

| 键 | Req | 说明 | 示例 |
|---|:--:|---|---|
| `WEB_UI_PORT` | ✅ | MetaCubeXD 仪表盘的宿主机端口（发布在 NAS 的 IP 上）。 | `8080` |
| `CONTROLLER_PORT` | ✅ | Mihomo RESTful 控制器端口（绑定 `0.0.0.0`；通过 `MIHOMO_IP:PORT` 访问）。 | `9090` |
| `CONTROLLER_SECRET` | | 控制器认证密钥。留空 = 不认证；留空时安装器会提议自动生成随机密钥（显式拒绝则保持开放）。重跑安装器时，按 **Enter** 保留已保存的密钥，输入 `-` 则清空。渲染器会转义 `&`、`\|`、`\`，但安装器**拒绝**包含 `\|` 的密钥——请避免使用。 | `` |

### DNS（注入到配置模板中）

逗号分隔的列表 → 渲染为 YAML 流式序列。**前三项必填**（若任一为空，渲染器会显式报错
失败——仓库中不会硬编码任何 DNS）。服务器末尾的 `#auto` 是 mihomo 的分组绕行片段语法：
该解析器会**经由**模板中字面命名为 `auto` 的分组拨号（两处名字要一起改；CI 会校验每个
片段都指向真实存在的分组）。绕行特意走 `auto`（url-test 组）而非 `PROXY` 选择器：`auto`
总是按健康度选一个存活节点，因此即使你在面板里把 `PROXY` 固定为 `DIRECT`，DNS 解析也
照常工作。出厂条目全部是纯 IP 或 **DoH-on-IP** URL，任何条目都不依赖先解析一个域名——
冷启动没有引导鸡生蛋问题。

| 键 | Req | 说明 | 示例 |
|---|:--:|---|---|
| `DNS_DEFAULT_NAMESERVER` | ✅ | 引导解析器——仅用于解析本节中出现的 DoH/DoT 服务器**域名**（当所有条目都以 IP 承载时处于闲置）。必须保持纯 IP、国内可达、**不走隧道**。 | `223.5.5.5,119.29.29.29` |
| `DNS_NAMESERVER` | ✅ | 引导钉扎（geo 镜像、健康检查主机、机场面板）的解析出口，**同时**——渲染为 `proxy-server-nameserver`——在任何代理就绪之前解析机场节点域名（见下文）。分域解析对未设时（传统配置档）它也是通用上游。DoH-on-IP、国内、**绝不**加分组片段后缀。 | `https://223.5.5.5/dns-query,https://120.53.53.53/dns-query` |
| `DNS_FALLBACK` | ✅ | **仅传统配置档使用：** fallback 双查询的境外抗污染解析器，当应答的 geoip 不是 CN 时使用。分域解析设置后完全不使用、**根本不会渲染**——v2 没有 fallback，因为双查询正是把所有长尾域名抄送国内解析器的通道。保持必填是为了随时能切回传统配置档。 | `https://1.1.1.1/dns-query#auto,tls://8.8.8.8:853#auto` |
| `DNS_CN_NAMESERVER` | | **分域解析对 (a)：** 命中 mihomo `geosite:cn` 列表的域名只在这里解析——国内、直连。与 `DNS_FOREIGN_NAMESERVER` 同设或同不设：只设一个会拒绝渲染；**都不设**时渲染传统配置档，与 1.3.8 之前逐字节一致（现有 `.env` 原样可用——重新部署向导会主动提议升级）。 | `https://223.5.5.5/dns-query,https://120.53.53.53/dns-query` |
| `DNS_FOREIGN_NAMESERVER` | | **分域解析对 (b)，v2 境外优先：** 渲染为**默认** `nameserver`——所有未被策略条目命中的域名（geosite 境外列表**以及**未列出的长尾）只在这里解析——境外、经 `#auto` 走隧道。这些域名完全不会到达任何国内运营方；隧道全灭时解析**失败关闭**（SERVFAIL），绝不悄悄泄漏。 | `https://1.1.1.1/dns-query#auto,https://8.8.8.8/dns-query#auto` |
| `DNS_GEOIP_NO_RESOLVE` | | `true` 会在 `GEOIP,CN,DIRECT` 规则上渲染出 `no-resolve`，使其完全不再强制任何解析。在 v2 下这次强制解析本就走隧道境外列表（私密），所以默认保持 `false`，未列出的国内域名保住直连捷径。`true` 的代价：`geosite:cn` 漏收的国内域名经 `MATCH` 走代理（见[故障排查](troubleshooting.md#开启-no-resolve-后小众国内网站变慢或打不开)）。仅接受小写 `true`/`false`。 | `false` |

**谁能看到你的 DNS 查询**（在出厂的分域解析 v2 默认值下）：

| 观察方 | 能看到什么 | 什么会改变它 |
|---|---|---|
| 国内解析服务运营方——AliDNS（阿里）、DNSPod（腾讯） | 中国列表内的域名（经加密 DoH），加上引导钉扎（geo 镜像、健康检查主机、机场面板、节点域名）。**仅此而已**——境外列表与长尾域名完全不会到达这里；从局域网客户端跑 dnsleaktest.com 扩展测试不会出现国内解析器。 | 取消分域解析对（传统配置档）会把**所有**域名送到这里——v1.3.10 之前的渲染也会经 `GEOIP,CN` 解析 + fallback 双查询泄漏长尾；`doctor` 以 `dns_privacy` 报告当前配置档。 |
| 你的 ISP / 线路上的任何人 | 只能看到网关在与知名解析器 IP 进行 DoH 通信——查询的域名是加密的，走隧道的条目在线路上甚至不表现为 DNS。 | 若在 `DNS_NAMESERVER` 里放明文 UDP 条目（如裸 `223.5.5.5`），域名会重新暴露在线路上；出厂默认避免了这一点。 |
| 机场（代理）运营方 | 它本来就代理的境外连接，其中包括你走隧道的 DNS（现在也覆盖长尾）。订阅刷新请求是直连的（已记录的残余——其 SNI 在线路上可见）。 | 代理的固有属性——据此选择机场。 |
| 境外 DoH 服务商——Cloudflare、Google | 境外列表内**以及长尾**的域名，**经隧道**到达（它们看到的是机场出口 IP，不是你家的 IP）。 | `DNS_FOREIGN_NAMESERVER` 里的服务商由你决定。 |

**`proxy-server-nameserver`——冷启动不变量。** 渲染后的配置把 `DNS_NAMESERVER` 复用为
mihomo 的 `proxy-server-nameserver`：机场节点域名经国内列表**直连**解析，处于一切依赖
隧道的路径之外。节点 IP 通常不在国内：传统配置档下 geoip 过滤器会把它们转给走隧道的
fallback 解析器，v2 下默认解析器本身就走隧道——无论哪种，**在任何节点就绪之前**都不可
达。没有这一条，全新启动或节点缓存过期时会在每个节点上以 `dns resolve failed` 收场——
生产环境实际发生过（2026-07-10）。因此 `DNS_NAMESERVER` 必须保持国内、且绝不能带
`#分组` 片段；CI 会在每个渲染变体上断言这两条性质。

**引导 DNS 钉扎（v1.3.8；v1.3.10 增加 gstatic）。** `proxy-server-nameserver` 只覆盖节点
域名——还有三个主机必须在**任何节点就绪之前**就能解析，否则冷启动永远无法完成引导：
geo 数据镜像站、健康检查主机 `www.gstatic.com`（延迟探测与空组降级出的 `COMPATIBLE`
占位符都会**直连**拨它），以及机场面板本身（其主机名在渲染时从 `subscription.txt` 推
导）。三者都被钉进 `nameserver-policy`，指向 `DNS_NAMESERVER`（国内、直连），镜像与
面板还从 fake-ip 中排除——在**每种**模式下都生效（传统与分域解析一视同仁，无开关）。
没有这层钉扎，这些主机的解析会依赖一条尚不存在的隧道，订阅便永远拉不下来
（2026-07-12 故障）。订阅主机若是 IP 字面量则无需 DNS，面板钉扎自动跳过；此外订阅节点
列表固定缓存在 `config/proxies/my-airport.yaml`，当实时拉取不可行时可由
`scripts/seed_provider.sh` 直接（重）写入（见故障排查"机场节点全部消失"一节）。

`.env.example` 的出厂默认值与 `REGISTRY_MODE=acr` 的中国大陆定位一致（分域解析 v2 开
启、全程加密、境外与长尾路径走隧道）；在无过滤的网络上，三项全用 `1.1.1.1,8.8.8.8`——
并让分域解析对保持未设——也可以。这些设置只作用于**网关**——NAS 自己的解析器（DSM
控制面板 → 网络）也必须可达，`doctor` 会逐一探测（`host_dns` 检查）并报告渲染出的配置
档（`dns_privacy` 检查）。部署时还会通过 CDN 镜像预下载 geo 数据库（`GEODATA_MIRRORS`
可覆盖镜像列表），首次启动不再依赖跨境下载——`nameserver-policy` 里的 `geosite:` 列表
与路由规则让这份预下载对 DNS 与路由都成为关键依赖。

### 容器镜像

三个镜像引用由 `install.sh` 根据 `REGISTRY_MODE` + 仓库主机 + 命名空间 + 各组件的标签**推导**得出，
因此你只需输入一次仓库/命名空间，而不必为每个镜像重复输入。自动更新器会将每个 `UPDATE_IMAGES`
条目，通过与这三个推导引用的**精确匹配**，映射到对应的部署目标（参见
[自动更新](auto-update.md#镜像引用)）。

> **缺失即失败，默认 ACR。** `docker-compose.yml` 使用 `${MIHOMO_IMAGE:?}` / `${METACUBEXD_IMAGE:?}`，
> 若引用未设置，`docker compose up` 会**直接报错失败**，而不会拉取意外的镜像。`REGISTRY_MODE` 默认
> 随发行包发布为 `acr`（中国大陆的安全默认值，因为公共镜像仓库被屏蔽）；仅当 NAS 拥有不受限的外网访问
> 时才设为 `docker`。

| 键 | Req | 说明 | 示例 |
|---|:--:|---|---|
| `REGISTRY_MODE` | ✅ | `acr`（默认；你的私有镜像源）或 `docker`（上游公共仓库；需要不受限外网）。在 `docker` 模式下**任何通用自动更新目标都不符合条件**（见下文）。 | `acr` |
| `MIHOMO_TAG` | | 用于推导 mihomo 引用的标签。 | `latest` |
| `METACUBEXD_TAG` | | 用于推导 metacubexd 引用的标签。 | `latest` |
| `CF_TAG` | | 用于推导可选的 cloudflared 引用的标签。 | `latest` |
| `MIHOMO_IMAGE` | ✅ | 推导出的 mihomo 镜像引用（安装器会据上面的值改写它）。 | `registry.cn-shenzhen.aliyuncs.com/myns/mihomo:latest` |
| `METACUBEXD_IMAGE` | ✅ | 推导出的 metacubexd 镜像引用。 | `registry.cn-shenzhen.aliyuncs.com/myns/metacubexd:latest` |
| `CF_IMAGE` | Upd | 推导出的 cloudflared 引用。不管理 cloudflared 时留空。 | `registry.cn-shenzhen.aliyuncs.com/myns/cloudflared:latest` |

### 私有镜像仓库 / 阿里云 ACR（当 `REGISTRY_MODE=acr` 时使用）

| 键 | Upd | Sec | 说明 | 示例 |
|---|:--:|:--:|---|---|
| `DOCKER_REGISTRY` | ✅ | | 镜像仓库主机（用于 `docker login` 并推导引用）；安装器会预填 `registry.cn-shenzhen.aliyuncs.com` 作为默认值。`docker` 模式下安装器会清空它以跳过登录。 | `registry.cn-shenzhen.aliyuncs.com` |
| `DOCKER_USERNAME` | ✅ | | 镜像仓库用户名（安装器与更新器共用）。 | `your_registry_user` |
| `ACR_PASSWORD` | ✅ | 🔒 | 镜像仓库密码/访问令牌（用于非交互式 `--password-stdin`）。最小权限：使用专用的**只读拉取** ACR 子账号/RAM 账号，与 `docker-china-sync` 的推送账号分开。 | `…` |
| `ACR_NAMESPACE` | ✅ | | 你的镜像所在的仓库命名空间（与主机 + 标签组合以推导引用）。 | `myns` |

### 自动更新编排器

| 键 | 说明 | 默认值 / 示例 |
|---|---|---|
| `UPDATE_ENABLED` | 总开关。设为 `false` 时，运行会立即退出（除非使用 `--force`）。 | `true` |
| `UPDATE_IMAGES` | 以空格分隔、需要检查/拉取的镜像引用。两个 Compose 引用必填；`CF_IMAGE` 非空时也必须包含。安装器会保存解析后的具体引用。 | `"${MIHOMO_IMAGE} ${METACUBEXD_IMAGE} ${CF_IMAGE}"` |
| `UPDATE_SCHEDULE` | 用于配置 DSM 任务计划/后备 crontab 的五字段数字 cron 表达式；输出前会校验范围。**请加引号。** | `"0 2 * * *"` |
| `UPDATE_TZ` | 更新器日志时间戳所用时区。DSM 触发时间遵循 NAS 的“区域选项”时区。 | `Asia/Shanghai` |
| `EXPECTED_ARCH` | 防止仅 amd64 的镜像源被装到 ARM 架构的机器上。可选 `amd64` / `arm64` / `arm`（32 位，如 armv7 树莓派）。树莓派安装器会自动固定为本机架构。 | `amd64` |

### 通用自动更新目标

登记信息**不**存放在 `.env` 中：管理列表位于
`<数据目录>/state/update-targets`（每条记录形如 `name|strategy|probe`），通过
`gateway.sh update --enable/--disable` 或安装器的更新流程编辑，并由
`update --list-targets` 展示。`recreate` 是 v1 **唯一**的策略（蓝绿部署仍为
cloudflared 专属）。仅登记还不够：目标只有在其运行镜像位于
`DOCKER_REGISTRY`/`ACR_NAMESPACE` 之下时才符合条件——`REGISTRY_MODE=docker` 时
**没有任何**通用目标符合条件。引擎细节见：
[自动更新 → 通用目标](auto-update.md#通用目标任意已登记的容器)。
更新器写入的相关状态：`state/last-run.json`（最近一次运行的结果——时间戳、退出码、
dry-run 标志、updated/unchanged/failed/rolled-back 计数与名称——由 `gateway.sh status`
与 `update --last` 展示）和 `state/last-good/<name>`（每个目标经验证的镜像 ID + 规格
摘要，跨运行保留以供回滚）。

| 变量 | 含义 | 默认值 |
|---|---|---|
| `UPDATE_DENY_CONTAINERS` | 可选的空格分隔通配（glob）列表；名称匹配的容器即使已登记也永不自动更新。 | *（空）* |

每目标探针（记录的第三个字段，登记时即校验）：`exec:<cmd>` 通过 `docker exec` 在容器内
执行；`log:<regex>` 对 `docker logs` 做正则匹配。未配置探针时，门控为：运行中 + 重启
计数稳定 + 镜像自带 healthcheck（若有定义）。

### cloudflared（外部容器，按名称蓝绿切换）

| 键 | Sec | 说明 | 默认值 / 示例 |
|---|:--:|---|---|
| `CF_CONTAINER_NAME` | | 正在运行的 cloudflared 容器的规范名称。 | `cloudflared` |
| `CF_TUNNEL_TOKEN` | 🔒 | 令牌**覆盖值**。留空 = 复用正在运行的容器中的令牌（推荐）——安装器会检测已存在的 `cloudflared` 容器并提示复用，仅在首次部署时才要求填写令牌。仅在尚不存在任何容器、首次部署时才需要填写。 | `` |
| `CF_HEALTH_TIMEOUT` | | 在切换前，等待新连接器报告 "connected" 的秒数。 | `60` |
| `CF_DNS` | | 传给隧道容器的显式 `--dns` 解析器（逗号分隔的 IPv4），使其不再继承主机的 resolv.conf——否则主机解析器不可达时隧道会被悄悄拖死。在下一次开通/蓝绿更新时生效；留空 = 继承。 | `223.5.5.5,119.29.29.29` |

### 上报与系统

| 键 | 说明 | 默认值 / 示例 |
|---|---|---|
| `NOTIFY_WEBHOOK_URL` | 可选 webhook（Bark/Gotify/Slack 风格的 JSON POST）。只要配置了就会触发——独立于 DSM 推送（`synodsmnotify`）；后者仅是尽力而为，绝不会抑制 webhook。 | `` |
| `NOTIFY_ON_NOCHANGE` | `1` = 在无变更的运行中也发送通知。 | `0` |
| `UPDATE_LOG` | 编排器日志路径（相对路径在持久数据目录下解析）。 | `./logs/auto-update.log` |
| `LOG_KEEP` | 保留的轮转日志代数。 | `7` |
| `TZ` | 容器时区。 | `Asia/Shanghai` |
| `INSTALLER_LANG` | `install.sh` 界面语言（`en` 或 `zh`）。由安装器首屏设置并保存于此，重运行时跳过该提示。 | `en` |

### 树莓派 lite 模式

由 [`install-pi.sh`](installation-pi.md) 与 lite 更新器使用；在 DSM 上无害且不生效
（`.env.example` 中以注释形式提供）。

| 键 | 说明 | 默认值 / 示例 |
|---|---|---|
| `GH_MIRROR` | 施加在上游发布下载地址上的镜像前缀（mihomo 二进制、面板、最新版本号解析）：`<镜像站>/<完整上游地址>`。留空 = 直连。 | `` |
| `MIHOMO_VERSION` | 固定 lite 安装/更新使用的 mihomo 发布版本号。留空 = 最新。 | `` |
| `MIHOMO_SHA256` | **固定版本**时可选的完整性锚点（上游不发布校验和）：设置后，下载的压缩包必须匹配才会安装——下载经过第三方镜像时建议设置。 | `` |
| `EXTERNAL_UI_DIR` | mihomo 托管面板的目录（**仅在设置时**渲染进 `external-ui`；lite 向导会设置它，DSM/compose 路径保持不设，其渲染结果因此逐字节不变）。 | `` |

### 高级可调项（可选的 `.env` 覆盖项）

这些在 `scripts/lib/common.sh` 中已有合理默认值（`TPROXY_NETWORK` 在
`scripts/lib/network.sh` 中）；仅在需要时覆盖。

| 键 | 默认值 | 含义 |
|---|---|---|
| `GATEWAY_DATA_DIR` | `../syno-mihomo-gateway-data` | 持久数据目录（`.env`、`config/`、`logs/`、`state/`），是发行目录的同级目录。compose 与所有脚本都会遵循。**须在环境变量中导出**——它用于定位 `.env`，因此不能写在 `.env` 里。 |
| `LOG_MAX_BYTES` | `1048576` | 当 `UPDATE_LOG` 超过此大小时进行轮转。 |
| `PULL_RETRIES` / `PULL_RETRY_DELAY` | `3` / `10` | `docker pull` 的重试次数/重试间隔（秒）。 |
| `DOCKER_READY_TIMEOUT` / `DOCKER_READY_INTERVAL` | `120` / `5` | DSM 计划/开机任务等待 Container Manager 的总时长与重试间隔（秒）。 |
| `HEALTH_RETRIES` / `HEALTH_INTERVAL` | `6` / `10` | mihomo 健康检查门控的尝试次数/间隔（秒）。 |
| `HEALTH_MAX_RESTARTS` | `3` | 通用目标的崩溃循环阈值：刚更新的容器重启达到该次数后，健康门（提前）判定失败。 |
| `LOCK_DIR` | `/tmp/syno-mihomo-update.lock` | 互斥锁目录。 |
| `TPROXY_NETWORK` | `tproxy_network` | 预检阶段检查的 macvlan 网络名称。 |
| `TUN_DEVICE` | `mihomo-tun` | 宿主机侧健康门查找的 TUN 接口名。必须与模板中硬编码的 `device: mihomo-tun` 一致——仅当你在模板中改了设备名时才需覆盖。 |

## `config/config.template.yaml`

存放带占位符的 Mihomo 配置，由渲染器填充：

| 占位符 | 来源键 |
|---|---|
| `{{AIRPORT_URL}}` | `../syno-mihomo-gateway-data/config/subscription.txt` 的第一行（去除标签后） |
| `{{CONTROLLER_PORT}}` / `{{CONTROLLER_SECRET}}` | `.env` |
| `{{DNS_DEFAULT_NAMESERVER}}` / `{{DNS_NAMESERVER}}` / `{{DNS_FALLBACK}}` | `.env` |
| `{{DNS_CN_NAMESERVER}}` / `{{DNS_FOREIGN_NAMESERVER}}` | `.env`（分域解析对；同时决定渲染哪套围栏 DNS 核心——设置时为 v2 境外优先，未设时为传统 `nameserver`+`fallback`） |
| `{{GEOIP_NO_RESOLVE}}` | `.env` 的 `DNS_GEOIP_NO_RESOLVE`（为 `true` 时在 GEOIP 规则上渲染 `,no-resolve`） |
| `{{TUN_AUTO_REDIRECT}}` | `.env`（缺省时为 `false`） |

代理**规则**、`proxy-groups` / `proxy-providers` 块、端口等请直接在模板中编辑（它们
未做参数化）。编辑后，用**强制重建**重新渲染：

```sh
docker compose --env-file ../syno-mihomo-gateway-data/.env up -d --force-recreate mihomo
```

（或 `sudo sh scripts/gateway.sh redeploy --yes`）。当镜像与 compose 模型未变化时，
普通的 `up -d mihomo` 是**空操作**——入口脚本只在重建容器时才重新渲染，因此仅改模板
的编辑会被静默忽略。如需自定义路由，请编辑 `rules:` 列表——默认值为
`GEOSITE,NETFLIX,STREAMING` / `GEOSITE,CN,DIRECT` / `GEOSITE,GEOLOCATION-!CN,PROXY` /
`GEOIP,CN,DIRECT` / `MATCH,PROXY`：流媒体走自己的可固定分组，国内流量直连，境外列表
域名**不经任何本地 DNS 解析**直接走代理，GEOIP 兜底其余流量。`PROXY` 是一个可选择的
代理组，默认指向 `auto`（订阅中延迟最低的节点），同时提供 `DIRECT` / `REJECT`；
`STREAMING` 是第二个选择器，默认指向 `PROXY`——在 MetaCubeXD 里把它固定到支持流媒体
解锁的节点，就能只切换流媒体流量（`auto` 按延迟选节点，而低延迟节点很少具备解锁能
力）。规则只能指向**代理组**，不能直接指向 `proxy-provider`；geosite 分类
（`netflix`、`cn`、`geolocation-!cn`）来自预下载 `geosite.dat` 中社区维护的开源列表——
无需任何额外下载。

模板还带有 `geo-auto-update` / `geox-url` 块，把地理数据库下载（`GEOSITE`/`GEOIP`
规则所需）指向 jsdelivr CDN 镜像——mihomo 的默认下载源在中国大陆被屏蔽，而卡住的
地理数据下载会让 mihomo 永远无法完成启动。若该镜像对你也不可用，请替换模板中的三个
URL（并按上述方式重新渲染）。

## 订阅格式

`../syno-mihomo-gateway-data/config/subscription.txt` —— 第一条非注释、非空白行生效。
可选的 `Name=` 标签会被去除；其余部分（即 URL，包括任何 `?token=…&flag=…`）将被原样
使用。编辑后，用与上文相同的 `--force-recreate` 命令重新渲染（或
`sudo sh scripts/gateway.sh modify --subscription URL --yes`，一步完成编辑与重新渲染）。

```text
# both of these work:
Default=https://provider.example/api/v1/subscribe?token=abc&flag=1
https://provider.example/api/v1/subscribe?token=abc&flag=1
```
