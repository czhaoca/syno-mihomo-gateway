# 配置参考

[← README](../../README.md) · [English](../configuration.md)
手册：[架构](architecture.md) · [安装](installation.md) · [离线发布包](release-packaging.md) · **配置** · [自动更新](auto-update.md) · [运维](operations.md) · [故障排查](troubleshooting.md) · [开发](development.md)

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
| `TPROXY_DRIVER` | | 网关网络的二层驱动：`macvlan`（默认）或 `ipvlan`。当父接口是 **Open vSwitch** 端口（`ovs_eth0`）时请用 `ipvlan`——其上的 macvlan 子接口路由器可达，但**其他局域网设备无法访问**，导致仪表盘和网关从客户端超时。ipvlan L2 共享父接口 MAC 并可穿越 OVS。检测到 `ovs_*` 父接口时安装器会自动建议。 | `macvlan` |

### Mihomo TUN

| 键 | Req | 说明 | 默认值 |
|---|:--:|---|---|
| `TUN_AUTO_REDIRECT` | | 可选的 Linux TCP 重定向优化。DSM 上应保持 `false`，除非安装程序的一次性 iptables 兼容性探测成功。无论此项为何值，TUN `auto-route` 都保持启用。仅接受小写 `true`/`false`。 | `false` |

### 端口与控制器

| 键 | Req | 说明 | 示例 |
|---|:--:|---|---|
| `WEB_UI_PORT` | ✅ | MetaCubeXD 仪表盘的宿主机端口（发布在 NAS 的 IP 上）。 | `8080` |
| `CONTROLLER_PORT` | ✅ | Mihomo RESTful 控制器端口（绑定 `0.0.0.0`；通过 `MIHOMO_IP:PORT` 访问）。 | `9090` |
| `CONTROLLER_SECRET` | | 控制器认证密钥。留空 = 不认证。`&`、`\|`、`\` 由渲染器自动处理。 | `` |

### DNS（注入到配置模板中）

逗号分隔的列表 → 渲染为 YAML 流式序列。**三项全部必填**（若任一为空，
渲染器会显式报错失败——仓库中不会硬编码任何 DNS）。

| 键 | Req | 说明 | 示例 |
|---|:--:|---|---|
| `DNS_DEFAULT_NAMESERVER` | ✅ | 引导解析器（纯 IP，用于解析其他解析器）。 | `114.114.114.114,223.5.5.5` |
| `DNS_NAMESERVER` | ✅ | 主用/国内解析器。 | `114.114.114.114,223.5.5.5` |
| `DNS_FALLBACK` | ✅ | 境外/抗污染解析器。 | `8.8.8.8,8.8.4.4` |

### 容器镜像

三个镜像引用由 `install.sh` 根据 `REGISTRY_MODE` + 仓库主机 + 命名空间 + 各组件的标签**推导**得出，
因此你只需输入一次仓库/命名空间，而不必为每个镜像重复输入。自动更新器会将每个 `UPDATE_IMAGES`
条目，通过与这三个推导引用的**精确匹配**，映射到对应的部署目标（参见
[自动更新](auto-update.md)）。

> **缺失即失败，默认 ACR。** `docker-compose.yml` 使用 `${MIHOMO_IMAGE:?}` / `${METACUBEXD_IMAGE:?}`，
> 若引用未设置，`docker compose up` 会**直接报错失败**，而不会拉取意外的镜像。`REGISTRY_MODE` 默认
> 随发行包发布为 `acr`（中国大陆的安全默认值，因为公共镜像仓库被屏蔽）；仅当 NAS 拥有不受限的外网访问
> 时才设为 `docker`。

| 键 | Req | 说明 | 示例 |
|---|:--:|---|---|
| `REGISTRY_MODE` | ✅ | `acr`（默认；你的私有镜像源）或 `docker`（上游公共仓库；需要不受限外网）。 | `acr` |
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
| `ACR_PASSWORD` | ✅ | 🔒 | 镜像仓库密码/访问令牌（用于非交互式 `--password-stdin`）。 | `…` |
| `ACR_NAMESPACE` | ✅ | | 你的镜像所在的仓库命名空间（与主机 + 标签组合以推导引用）。 | `myns` |

### 自动更新编排器

| 键 | 说明 | 默认值 / 示例 |
|---|---|---|
| `UPDATE_ENABLED` | 总开关。设为 `false` 时，运行会立即退出（除非使用 `--force`）。 | `true` |
| `UPDATE_IMAGES` | 以空格分隔、需要检查/拉取的镜像引用。两个 Compose 引用必填；`CF_IMAGE` 非空时也必须包含。安装器会保存解析后的具体引用。 | `"${MIHOMO_IMAGE} ${METACUBEXD_IMAGE} ${CF_IMAGE}"` |
| `UPDATE_SCHEDULE` | 用于配置 DSM 任务计划/后备 crontab 的五字段数字 cron 表达式；输出前会校验范围。**请加引号。** | `"0 2 * * *"` |
| `UPDATE_TZ` | 更新器日志时间戳所用时区。DSM 触发时间遵循 NAS 的“区域选项”时区。 | `Asia/Shanghai` |
| `EXPECTED_ARCH` | 防止仅 amd64 的镜像源被装到 ARM 架构的 NAS 上。可选 `amd64`/`arm64`。 | `amd64` |

### cloudflared（外部容器，按名称蓝绿切换）

| 键 | Sec | 说明 | 默认值 / 示例 |
|---|:--:|---|---|
| `CF_CONTAINER_NAME` | | 正在运行的 cloudflared 容器的规范名称。 | `cloudflared` |
| `CF_TUNNEL_TOKEN` | 🔒 | 令牌**覆盖值**。留空 = 复用正在运行的容器中的令牌（推荐）——安装器会检测已存在的 `cloudflared` 容器并提示复用，仅在首次部署时才要求填写令牌。仅在尚不存在任何容器、首次部署时才需要填写。 | `` |
| `CF_HEALTH_TIMEOUT` | | 在切换前，等待新连接器报告 "connected" 的秒数。 | `60` |

### 上报与系统

| 键 | 说明 | 默认值 / 示例 |
|---|---|---|
| `NOTIFY_WEBHOOK_URL` | 当 `synodsmnotify` 不可用时使用的可选后备 webhook（Bark/Gotify/Slack 风格的 JSON POST）。 | `` |
| `NOTIFY_ON_NOCHANGE` | `1` = 在无变更的运行中也发送通知。 | `0` |
| `UPDATE_LOG` | 编排器日志路径（相对路径在持久数据目录下解析）。 | `./logs/auto-update.log` |
| `LOG_KEEP` | 保留的轮转日志代数。 | `7` |
| `TZ` | 容器时区。 | `Asia/Shanghai` |
| `INSTALLER_LANG` | `install.sh` 界面语言（`en` 或 `zh`）。由安装器首屏设置并保存于此，重运行时跳过该提示。 | `en` |

### 高级可调项（可选的 `.env` 覆盖项）

这些在 `scripts/lib/common.sh` / `registry.sh` 中已有合理默认值；仅在需要时覆盖。

| 键 | 默认值 | 含义 |
|---|---|---|
| `LOG_MAX_BYTES` | `1048576` | 当 `UPDATE_LOG` 超过此大小时进行轮转。 |
| `PULL_RETRIES` / `PULL_RETRY_DELAY` | `3` / `10` | `docker pull` 的重试次数/重试间隔（秒）。 |
| `DOCKER_READY_TIMEOUT` / `DOCKER_READY_INTERVAL` | `120` / `5` | DSM 计划/开机任务等待 Container Manager 的总时长与重试间隔（秒）。 |
| `HEALTH_RETRIES` / `HEALTH_INTERVAL` | `6` / `10` | mihomo 健康检查门控的尝试次数/间隔（秒）。 |
| `LOCK_DIR` | `/tmp/syno-mihomo-update.lock` | 互斥锁目录。 |
| `TPROXY_NETWORK` | `tproxy_network` | 预检阶段检查的 macvlan 网络名称。 |

## `config/config.template.yaml`

存放带占位符的 Mihomo 配置，由渲染器填充：

| 占位符 | 来源键 |
|---|---|
| `{{AIRPORT_URL}}` | `config/subscription.txt` 的第一行（去除标签后） |
| `{{CONTROLLER_PORT}}` / `{{CONTROLLER_SECRET}}` | `.env` |
| `{{DNS_DEFAULT_NAMESERVER}}` / `{{DNS_NAMESERVER}}` / `{{DNS_FALLBACK}}` | `.env` |
| `{{TUN_AUTO_REDIRECT}}` | `.env`（缺省时为 `false`） |

代理**规则**、`proxy-groups` / `proxy-providers` 块、端口等请直接在模板中编辑（它们
未做参数化）。编辑后，通过重建 mihomo 重新渲染
（`docker compose up -d mihomo`）。如需自定义路由，请编辑 `rules:` 列表——默认值
为 `GEOSITE,CN,DIRECT` / `GEOIP,CN,DIRECT` / `MATCH,PROXY`（国内流量直连，其余
全部走 `PROXY` 组）。`PROXY` 是一个可选择的代理组，默认指向 `auto`（订阅中延迟最低的
节点），同时提供 `DIRECT` / `REJECT`；规则只能指向**代理组**（如 `PROXY`），不能直接
指向 `proxy-provider`。

## 订阅格式

`config/subscription.txt` —— 第一条非注释、非空白行生效。可选的 `Name=` 标签
会被去除；其余部分（即 URL，包括任何 `?token=…&flag=…`）将被原样使用。

```text
# both of these work:
Default=https://provider.example/api/v1/subscribe?token=abc&flag=1
https://provider.example/api/v1/subscribe?token=abc&flag=1
```
