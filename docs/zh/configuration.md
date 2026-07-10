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

逗号分隔的列表 → 渲染为 YAML 流式序列。**三项全部必填**（若任一为空，
渲染器会显式报错失败——仓库中不会硬编码任何 DNS）。

| 键 | Req | 说明 | 示例 |
|---|:--:|---|---|
| `DNS_DEFAULT_NAMESERVER` | ✅ | 引导解析器（纯 IP，用于解析其他解析器）。 | `1.1.1.1,1.0.0.1` |
| `DNS_NAMESERVER` | ✅ | 主用/国内解析器。 | `1.1.1.1,1.0.0.1` |
| `DNS_FALLBACK` | ✅ | 境外/抗污染解析器。 | `1.1.1.1,1.0.0.1` |

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
| `{{TUN_AUTO_REDIRECT}}` | `.env`（缺省时为 `false`） |

代理**规则**、`proxy-groups` / `proxy-providers` 块、端口等请直接在模板中编辑（它们
未做参数化）。编辑后，用**强制重建**重新渲染：

```sh
docker compose --env-file ../syno-mihomo-gateway-data/.env up -d --force-recreate mihomo
```

（或 `sudo sh scripts/gateway.sh redeploy --yes`）。当镜像与 compose 模型未变化时，
普通的 `up -d mihomo` 是**空操作**——入口脚本只在重建容器时才重新渲染，因此仅改模板
的编辑会被静默忽略。如需自定义路由，请编辑 `rules:` 列表——默认值
为 `GEOSITE,CN,DIRECT` / `GEOIP,CN,DIRECT` / `MATCH,PROXY`（国内流量直连，其余
全部走 `PROXY` 组）。`PROXY` 是一个可选择的代理组，默认指向 `auto`（订阅中延迟最低的
节点），同时提供 `DIRECT` / `REJECT`；规则只能指向**代理组**（如 `PROXY`），不能直接
指向 `proxy-provider`。

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
