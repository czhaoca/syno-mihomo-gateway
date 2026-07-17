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

逗号分隔的列表 → 渲染为 YAML 流式序列。**每个带 ✅ 的键都必填**（若任一为空，渲染器会
显式报错失败——仓库中不会硬编码任何 DNS）。服务器末尾的 `#All Nodes` 是 mihomo 的分组
绕行片段语法：该解析器会**经由**字面命名为 `All Nodes` 的分组拨号——那个**隐藏的**全池
url-test 分组，如今只为充当这个 DNS 锚点而保留（`hidden: true` 只是显示标志：MetaCubeXD
不显示该卡片，但分组本身仍然存活、可路由）。绕行特意走这个锚点而非 `Proxy Mode` 选择器：
它总是按健康度持有一个存活节点，因此即使你在面板里把 `Proxy Mode` 固定为 `DIRECT`、或
所选国家分组空到 REJECT，DNS 解析也照常工作。重命名或移除它必须连同每一个 `#All Nodes`
片段一起改——渲染器**和** CI 会校验任何 `DNS_*` 列表中的每个 `#分组` 片段都指向真实渲染
出的分组（或 `DIRECT`）；悬空片段会拒绝渲染。已部署 `.env` 中的 DNS 值在精简分组模型下
**无需任何修改**。出厂条目全部是纯 IP 或 **DoH-on-IP** URL，任何条目都不依赖先解析一个
域名——冷启动没有引导鸡生蛋问题。

| 键 | Req | 说明 | 示例 |
|---|:--:|---|---|
| `DNS_DEFAULT_NAMESERVER` | ✅ | 引导解析器——仅用于解析本节中出现的 DoH/DoT 服务器**域名**（当所有条目都以 IP 承载时处于闲置）。必须保持纯 IP、国内可达、**不走隧道**。 | `223.5.5.5,119.29.29.29` |
| `DNS_NAMESERVER` | ✅ | 引导钉扎（geo 镜像、健康检查主机、机场面板）的解析出口，**同时**——渲染为 `proxy-server-nameserver`——在任何代理就绪之前解析机场节点域名（见下文）。DoH-on-IP、国内、**绝不**加分组片段后缀。 | `https://223.5.5.5/dns-query,https://120.53.53.53/dns-query` |
| `DNS_CN_NAMESERVER` | ✅ | **分域解析对 (a)：** 命中 mihomo `geosite:cn` 列表的域名只在这里解析——国内、直连。必须与 `DNS_FOREIGN_NAMESERVER` 一起设置——分域解析 v2 是**唯一**的 DNS 配置档；缺失任何一项都会拒绝渲染（入口点守门会保持上一份配置继续运行）。 | `https://223.5.5.5/dns-query,https://120.53.53.53/dns-query` |
| `DNS_FOREIGN_NAMESERVER` | ✅ | **分域解析对 (b)，v2 境外优先：** 渲染为**默认** `nameserver`——所有未被策略条目命中的域名（geosite 境外列表**以及**未列出的长尾）只在这里解析——境外、经 `#All Nodes` 走隧道。这些域名完全不会到达任何国内运营方；隧道全灭时解析**失败关闭**（SERVFAIL），绝不悄悄泄漏（fallback 双查询已随传统配置档一并移除）。 | `https://1.1.1.1/dns-query#All Nodes,https://8.8.8.8/dns-query#All Nodes` |
| `DNS_GEOIP_NO_RESOLVE` | | `true` 会在 `GEOIP,CN,DIRECT` 规则上渲染出 `no-resolve`，使其完全不再强制任何解析。在 v2 下这次强制解析本就走隧道境外列表（私密），所以默认保持 `false`，未列出的国内域名保住直连捷径。`true` 的代价：`geosite:cn` 漏收的国内域名经 `MATCH` 走代理（见[故障排查](troubleshooting.md#开启-no-resolve-后小众国内网站变慢或打不开)）。仅接受小写 `true`/`false`。 | `false` |
| `SNIFFER_ENABLE` | | 渲染**流量嗅探**（TLS SNI / HTTP Host / QUIC，`parse-pure-ip` + `override-destination`）：在网关**之外**解析 DNS 的局域网客户端发出的裸 IP 连接会恢复出域名，域名规则（含 `Streaming Sites`）照常路由它们，被污染的客户端解析结果也会在节点侧按域名重拨。未设/`false` 时不渲染该块，与 v1.3.10 之前逐字节一致（升级兼容）；`.env.example` 出厂为 `true`。路由自愈，但绕过网关的客户端要修复**隐私**仍须把设备 DNS 指向网关——见[故障排查](troubleshooting.md#局域网客户端绕过网关-dnsdnsleaktest-仍显示国内解析器)。 | `true` |
| `FULL_PROXY_SOURCES` | | **可选的按设备全代理网段：**逗号分隔的 IPv4 地址/CIDR（裸 IP 视为 `/32`）。**仅在设置时**渲染——未设时渲染配置**逐字节不变**（该特性完全不可见）。设置后，面板上会出现一个 **`Full Proxy`** 选择器，且每个条目各生成一条 `SRC-IP-CIDR` 规则，落在 **LAN 规则之后紧邻的位置**：网段内设备访问局域网目标仍走 DIRECT，而**其余一切——流媒体与国内站点一视同仁——都走 `Full Proxy`**（严格语义）。格式错误的值**拒绝渲染**并点名本键——IPv6 条目、主机名、超过 255 的字节段、超过 32 的前缀长度、重复条目、空白字符、反引号（拒绝 IPv6 是有意为之：可路由的局域网 IPv6 会*绕开*这台仅 IPv4 的网关——见 `ipv6_bypass` 注意事项）。按设备的模式切换在**路由器侧**完成（一次 DHCP 固定 IP 翻转），绝不重启网关。见[全代理设备](#全代理设备full_proxy_sources)。 | `192.168.1.240/28` |
| `COUNTRY_GROUPS` | ✅ | **必填——整个分组模型由它生成**（留空/未设会拒绝渲染，并指向 `.env.example` 的默认值）：`名称=正则;名称=正则;…` 每项生成一个 **`<Country> Auto`** url-test 分组——面板显示 `名称`，自动选中匹配 `正则` 的最快机场节点——这些分组就是 **`Country Pick`** 选择器的全部成员。**第一项**是开箱即用的默认出口国家；`.env.example` 出厂把 **Japan Auto 放在第一位**。正则风味：regexp2（.NET）——默认区分大小写（可用 `(?i)`），**无锚点子串**匹配（`日本` 匹配 `日本01`），`\|` 表示或，**反引号会拒绝渲染**（非法正则会让 mihomo 启动即崩溃）；短拉丁代码要加锚点（如 `US\d\|^US`），避免误中其他名字。正则跨越多个国家即是**多国分组**（如 `亚洲=日本\|新加坡`）。不带独立健康检查（延迟数据来自订阅源的健康检查）；匹配不到任何节点的分组被选中时 **REJECT**（失败关闭，绝不悄悄绕过代理；doctor 会标记——见[故障排查](troubleshooting.md#doctor-报告国家分组为空proxy_groupsdefault-empty--country-empty)）。`名称` 可用中文、可含中间空格（`Japan Auto`）——首尾空白会拒绝——且不得与内建、保留或已退役的分组/适配器名重名（`All Nodes` / `Country Pick` / `Proxy Mode` / `Streaming Sites` / `DIRECT` / `REJECT` / …——渲染错误会点名冲突项；完整清单见 `.env.example`）；空条目、重复名称及格式错误的条目**拒绝渲染**。请按*你的*机场节点命名调整出厂示例。 | `Japan Auto=日本\|JP\d\|^JP;US Auto=…`（见 `.env.example`） |

**命名图例**（面板上通用的后缀体系）：**`<X> Auto`** = 自动优选 url-test 分组 ·
**`<X> Mode`** = 模式选择器 · **`<X> Sites`** = 站点规则分组 · **`<X> Pick`** = 手动选择。

**已移除的开关。** 精简前的“过滤默认线路”（优先节点的圈定/剔除过滤对，及更早的
`AUTO_EXCLUDE_FILTER`）已经移除——由 `<Country> Auto` 分组加 `Country Pick` 选择器取代。
`.env` 中仍残留任何这类行都会**拒绝渲染**，错误信息会点名需要删除的行（期间入口点守门
保持上一份有效配置继续运行）；一次性升级路径见发布说明。

**谁能看到你的 DNS 查询**（在出厂的分域解析 v2 默认值下）：

| 观察方 | 能看到什么 | 什么会改变它 |
|---|---|---|
| 国内解析服务运营方——AliDNS（阿里）、DNSPod（腾讯） | 中国列表内的域名（经加密 DoH），加上引导钉扎（geo 镜像、健康检查主机、机场面板、节点域名）。**仅此而已**——境外列表与长尾域名完全不会到达这里；从局域网客户端跑 dnsleaktest.com 扩展测试不会出现国内解析器。 | 取消分域解析对（传统配置档）会把**所有**域名送到这里——v1.3.10 之前的渲染也会经 `GEOIP,CN` 解析 + fallback 双查询泄漏长尾；`doctor` 以 `dns_privacy` 报告当前配置档。 |
| 你的 ISP / 线路上的任何人 | 只能看到网关在与知名解析器 IP 进行 DoH 通信——查询的域名是加密的，走隧道的条目在线路上甚至不表现为 DNS。 | 若在 `DNS_NAMESERVER` 里放明文 UDP 条目（如裸 `223.5.5.5`），域名会重新暴露在线路上；出厂默认避免了这一点。 |
| 机场（代理）运营方 | 它本来就代理的境外连接，其中包括你走隧道的 DNS（现在也覆盖长尾）。订阅刷新请求是直连的（已记录的残余——其 SNI 在线路上可见）。 | 代理的固有属性——据此选择机场。 |
| 境外 DoH 服务商——Cloudflare、Google | 境外列表内**以及长尾**的域名，**经隧道**到达（它们看到的是机场出口 IP，不是你家的 IP）。 | `DNS_FOREIGN_NAMESERVER` 里的服务商由你决定。 |

**`proxy-server-nameserver`——冷启动不变量。** 渲染后的配置把 `DNS_NAMESERVER` 复用为
mihomo 的 `proxy-server-nameserver`：机场节点域名经国内列表**直连**解析，处于一切依赖
隧道的路径之外。节点 IP 通常不在国内，而默认解析器本身就走隧道——**在任何节点就绪
之前**都不可达。没有这一条，全新启动或节点缓存过期时会在每个节点上以 `dns resolve
failed` 收场——
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
| `{{DNS_DEFAULT_NAMESERVER}}` / `{{DNS_NAMESERVER}}` | `.env` |
| `{{DNS_CN_NAMESERVER}}` / `{{DNS_FOREIGN_NAMESERVER}}` | `.env`（分域解析对——必填；v2 境外优先是唯一的 DNS 配置档） |
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
`GEOIP,LAN,DIRECT,no-resolve` / `GEOSITE,<服务>,Streaming Sites`（netflix、spotify、
tidal、deezer、soundcloud）/ `GEOSITE,CN,DIRECT` / `GEOSITE,GEOLOCATION-!CN,Proxy Mode` /
`GEOIP,CN,DIRECT` / `MATCH,Proxy Mode`：私网/链路本地目标绝不走隧道（`LAN` 是 mihomo
内建类别，无需 geo 数据库），流媒体——视频**和**音频，同样按地区锁区——走自己的可固定
分组，国内流量直连，境外列表域名**不经任何本地 DNS 解析**直接走代理，GEOIP 兜底其余流量。

代理分组图（面板顺序 = 定义顺序——操作者会用到的选择器在前，隐藏机制在后；后缀含义见
上文[命名图例](#dns注入到配置模板中)）：

- **`Proxy Mode`**——规则（`GEOSITE`/`MATCH`）指向的选择器。成员：`Country Pick`（默认）、
  `DIRECT`、`REJECT`，外加机场原始节点。当某网站连同国 IP 跳变也要计较时，在这里
  **固定一个具体节点**就是完整的解决方案；`DIRECT` 绕过隧道，`REJECT` 阻断。
- **`Streaming Sites`**——针对解锁敏感**站点**的按服务选择器（上面的 netflix + 音频服务
  规则落在这里）。第一个成员是 `Proxy Mode`，因此开箱行为与单分组配置完全一致；
  `<Country> Auto` 分组、`DIRECT` 与原始节点一键可达——固定一个流媒体解锁节点（或某个
  国家分组，一键锁定区域）即可只切换流媒体流量。
- **`Country Pick`**——选择出口**国家**。成员正是由 `COUNTRY_GROUPS` 生成的
  `<Country> Auto` 分组（这正是该键必填的原因）；默认为**第一**项。所选国家的 url-test
  每次只持有**一个**节点，因此常规流量保持单一出口 IP，出口国家绝不会自行跳变。同国
  之内的重选（url-test `tolerance: 50`、订阅源健康检查节奏）仍会发生——若网站连这个也
  计较，请改在 `Proxy Mode` 里固定一个原始节点。这里没有 `DIRECT`/`REJECT`：绕过与阻断
  是 `Proxy Mode` 的决定，所选分组为空时**失败关闭**（REJECT）而不是泄漏。
- **`<Country> Auto`**——每条 `COUNTRY_GROUPS` 生成一个 url-test 分组：选中匹配该条正则
  的最快机场节点，`empty-fallback: REJECT`（失败关闭），`tolerance: 50`，延迟数据继承自
  订阅源健康检查（零额外探测流量）。
- **`All Nodes`**——全池 url-test，**隐藏**（`hidden: true`；MetaCubeXD 不显示），只为
  `DNS_FOREIGN_NAMESERVER` 中的 `#All Nodes` 片段充当 DNS 绕行锚点而保留（见
  [DNS 一节](#dns注入到配置模板中)）。

规则只能指向**代理组**，不能直接指向 `proxy-provider`；geosite 分类
（`netflix`、`spotify`、`cn`、`geolocation-!cn`、……）来自预下载 `geosite.dat` 中社区维
护的开源列表——无需任何额外下载。

模板还带有 `geo-auto-update` / `geox-url` 块，把地理数据库下载（`GEOSITE`/`GEOIP`
规则所需）指向 jsdelivr CDN 镜像——mihomo 的默认下载源在中国大陆被屏蔽，而卡住的
地理数据下载会让 mihomo 永远无法完成启动。若该镜像对你也不可用，请替换模板中的三个
URL（并按上述方式重新渲染）。

## 全代理设备（`FULL_PROXY_SOURCES`）

可选。设置 `FULL_PROXY_SOURCES` 会圈出一小段 **IPv4 网段**，段内设备跳过上文的智能分流：
每个条目各生成一条 `SRC-IP-CIDR` 规则，拼接在 **LAN 规则之后紧邻的位置**，因此网段内设备
访问局域网目标仍然 DIRECT，但**其余一切——流媒体与国内站点一视同仁——都走 `Full Proxy`
分组**（严格语义：对这些源 IP 不做任何国内短路）。未设时什么都不渲染，配置保持**逐字节
不变**——在你主动启用之前，该特性完全不可见。

**`Full Proxy` 分组**是一个面板选择器。成员：

- **`Proxy Mode`**（默认）——网段跟随面板上 `Proxy Mode` 的当前选择。
- 每一个 **`<Country> Auto`** 分组——把网段的出口国家**独立**于主 `Country Pick` 的选择
  单独固定。
- **`REJECT`**——断网总闸：一键让整个网段下线。

这里刻意**没有 `DIRECT`** 成员：网段内设备绝不可能被面板上的一次点击悄悄取消代理——
离开网段是*路由器侧*的操作（见下文），绝不是某个选择器状态。

**前提：DHCP 固定 IP 保留是路由器的职责。**网关不管理租约——它只匹配源 IP。请在路由器
上保留一小段固定 IP 网段（如 `192.168.1.240/28`），并把 `FULL_PROXY_SOURCES` 设为它。

**设备进出网段在路由器侧完成**——已在 UniFi 上验证（按客户端的 **Fixed IP** 保留），任何
支持按客户端 DHCP 保留的路由器做法都相同：

1. 把设备的固定 IP 保留改**入**网段，并让设备重连（开关 Wi-Fi / 重新插网线）以获取新
   租约 → 该设备即进入全代理。
2. 把保留改**出**网段 + 重连 → 恢复常规的按规则分流。

全程不涉及任何网关或容器重启——模式切换完全是路由器侧的一次租约翻转。

**修改网段本身**（即 `.env` 里的值）就是一次普通的 `.env` 编辑 + 重新部署
（`sudo sh scripts/gateway.sh redeploy --yes`）。入口点渲染守门照常生效：格式错误的值会
**拒绝渲染**、点名 `FULL_PROXY_SOURCES`，并保持上一份配置继续运行。会被大声拒绝的有：
IPv6 条目、主机名、超过 255 的字节段、超过 32 的前缀长度、重复条目、空白字符、反引号。
拒绝 IPv6 是有意为之——匹配仅针对 IPv4，而可路由的局域网 IPv6 会*完全绕开*这台网关
（见下文注意事项 3）。

`doctor` 新增 **`full_proxy`** 检查：`disabled`（未使用该键）· `ok` · `parity-drift`
（渲染出的规则与该键不再一致——你的网段修改**尚未生效**，请重新部署）·
`chain-violation`（来自网段源 IP 的一条非局域网流量绕过了 `Full Proxy`）。

**注意事项：**

1. **网段内设备访问国内站点/应用会从境外出口。**在 fake-ip 下，节点在远端解析网段设备
   的域名——国内域名*正确地*走了隧道；预期国内服务会看到境外出口并相应降级。这正是
   严格语义按设计工作，不是泄漏。
2. **QUIC/UDP 穿透。**当出口节点不支持 UDP 转发时，UDP 流会在规则引擎处穿透
   `SRC-IP-CIDR` 规则——命中国内列表的目标随后走 DIRECT；浏览器会改用走代理的 TCP
   重试。doctor 的 `full_proxy` 检查会标记此类流量；仅当某机场的 UDP 确实不可靠时，
   才会提供可选的 UDP 封锁开关。
3. **该保证的前提是不存在可路由的局域网 IPv6**（doctor `ipv6_bypass`）——双栈设备若
   拥有全局 IPv6，会*完全绕开*这台仅 IPv4 的网关。

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
