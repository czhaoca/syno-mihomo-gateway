# 配置参考

[← README](../../README.md) · [English](../configuration.md)
手册：[架构](architecture.md) · [安装](installation.md) · [离线发布包](release-packaging.md) · **配置** · [自动更新](auto-update.md) · [运维](operations.md) · [故障排查](troubleshooting.md) · [开发](development.md)

---

本文档是每一个配置项的**唯一可信来源**。所有真实取值都保存在
`.env` 中（从 `.env.example` 复制而来，执行 `chmod 600`，并被 gitignore 忽略）。提交到仓库的配置模板
只包含 `{{PLACEHOLDERS}}` 占位符——不会硬编码任何 DNS 服务器或网络地址。

## 文件

| 文件 | 是否纳入版本控制 | 用途 |
|---|---|---|
| `.env` | 否（被 gitignore 忽略） | 你的全部设置与密钥。从 `.env.example` 复制。 |
| `.env.example` | 是 | `.env` 的带注释模板。 |
| `config/subscription.txt` | 否（被 gitignore 忽略） | 你的机场/服务商订阅 URL（`Name=URL`，使用第一条有效行）。 |
| `config/subscription.txt.example` | 是 | 上述文件的模板。 |
| `config/config.template.yaml` | 是 | 带 `{{PLACEHOLDERS}}` 占位符的 Mihomo 配置。 |
| `config/config.yaml` | 否（被 gitignore 忽略） | 在容器启动时由 `scripts/render_config.sh` 渲染生成。切勿手动编辑。 |

## `.env` 参考

图例 —— **Req**：网关运行所必需 · **Upd**：自动更新所必需 ·
**Sec**：密钥（请保持 `.env` 为 `chmod 600`）。

### 网络

| 键 | Req | 说明 | 示例 |
|---|:--:|---|---|
| `ROUTER_IP` | ✅ | 你的路由器/网关 IP。用于自动探测 macvlan 的父接口。 | `192.168.1.1` |
| `SUBNET_CIDR` | ✅ | 用于 macvlan 网络的局域网子网。 | `192.168.1.0/24` |
| `MIHOMO_IP` | ✅ | 分配给 mihomo 容器的静态局域网 IP。**必须是未被占用的地址。** | `192.168.1.100` |

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

自动更新器会将每个 `UPDATE_IMAGES` 条目，通过与下面这三个变量的**精确匹配**，
映射到对应的部署目标——在 ACR 路径下，请将它们设置为你的 ACR 引用（参见
[自动更新](auto-update.md)）。

| 键 | Req | 说明 | 示例 |
|---|:--:|---|---|
| `MIHOMO_IMAGE` | ✅ | mihomo 镜像引用（指向你在中国的 ACR 镜像源）。 | `registry.cn-shenzhen.aliyuncs.com/myns/mihomo:latest` |
| `METACUBEXD_IMAGE` | ✅ | metacubexd 镜像引用。 | `registry.cn-shenzhen.aliyuncs.com/myns/metacubexd:latest` |
| `CF_IMAGE` | Upd | cloudflared 镜像引用（ACR 镜像）。如果不管理 cloudflared 可留空。 | `registry.cn-shenzhen.aliyuncs.com/myns/cloudflared:latest` |

### 阿里云 ACR（中国镜像源 —— 拉取侧）

| 键 | Upd | Sec | 说明 | 示例 |
|---|:--:|:--:|---|---|
| `DOCKER_REGISTRY` | ✅ | | ACR 镜像仓库主机。留空 = 视为公开镜像，跳过登录。 | `registry.cn-shenzhen.aliyuncs.com` |
| `DOCKER_USERNAME` | ✅ | | ACR 用户名（由初始化脚本与更新器共用）。 | `your_acr_user` |
| `ACR_PASSWORD` | ✅ | 🔒 | ACR 密码/访问令牌（用于非交互式 `--password-stdin`）。 | `…` |
| `ACR_NAMESPACE` | | | ACR 命名空间（即 docker-china-sync 中的 `ALIYUN_NAME_SPACE`）。仅供参考。 | `myns` |

### 自动更新编排器

| 键 | 说明 | 默认值 / 示例 |
|---|---|---|
| `UPDATE_ENABLED` | 总开关。设为 `false` 时，运行会立即退出（除非使用 `--force`）。 | `true` |
| `UPDATE_IMAGES` | 以空格分隔、需要检查/拉取的镜像引用。推荐：直接沿用上述三个镜像变量。 | `"${MIHOMO_IMAGE} ${METACUBEXD_IMAGE} ${CF_IMAGE}"` |
| `UPDATE_SCHEDULE` | Cron 表达式——DSM 计划任务/后备 crontab 的可信来源。**请加引号。** | `"0 9 * * *"` |
| `UPDATE_TZ` | 计划任务运行所在的时区（脚本会将其导出为 `TZ`）。 | `Asia/Shanghai` |
| `EXPECTED_ARCH` | 防止仅 amd64 的镜像源被装到 ARM 架构的 NAS 上。可选 `amd64`/`arm64`。 | `amd64` |

### cloudflared（外部容器，按名称蓝绿切换）

| 键 | Sec | 说明 | 默认值 / 示例 |
|---|:--:|---|---|
| `CF_CONTAINER_NAME` | | 正在运行的 cloudflared 容器的规范名称。 | `cloudflared` |
| `CF_TUNNEL_TOKEN` | 🔒 | 令牌**覆盖值**。留空 = 复用正在运行的容器中的令牌（推荐）。仅在首次部署、尚不存在任何容器时才需要填写。 | `` |
| `CF_HEALTH_TIMEOUT` | | 在切换前，等待新连接器报告 "connected" 的秒数。 | `60` |

### 上报与系统

| 键 | 说明 | 默认值 / 示例 |
|---|---|---|
| `NOTIFY_WEBHOOK_URL` | 当 `synodsmnotify` 不可用时使用的可选后备 webhook（Bark/Gotify/Slack 风格的 JSON POST）。 | `` |
| `NOTIFY_ON_NOCHANGE` | `1` = 在无变更的运行中也发送通知。 | `0` |
| `UPDATE_LOG` | 编排器日志路径（相对路径在仓库下解析）。 | `./logs/auto-update.log` |
| `LOG_KEEP` | 保留的轮转日志代数。 | `7` |
| `TZ` | 容器时区。 | `Asia/Shanghai` |

### 高级可调项（可选的 `.env` 覆盖项）

这些在 `scripts/lib/common.sh` / `registry.sh` 中已有合理默认值；仅在需要时覆盖。

| 键 | 默认值 | 含义 |
|---|---|---|
| `LOG_MAX_BYTES` | `1048576` | 当 `UPDATE_LOG` 超过此大小时进行轮转。 |
| `PULL_RETRIES` / `PULL_RETRY_DELAY` | `3` / `10` | `docker pull` 的重试次数/重试间隔（秒）。 |
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

代理**规则**、`proxy-providers` 块、端口等请直接在模板中编辑（它们
未做参数化）。编辑后，通过重建 mihomo 重新渲染
（`docker compose up -d mihomo`）。如需自定义路由，请编辑 `rules:` 列表——默认值
为 `GEOSITE,CN,DIRECT` / `GEOIP,CN,DIRECT` / `MATCH,my-airport`（国内流量直连，其余
全部走机场）。

## 订阅格式

`config/subscription.txt` —— 第一条非注释、非空白行生效。可选的 `Name=` 标签
会被去除；其余部分（即 URL，包括任何 `?token=…&flag=…`）将被原样使用。

```text
# both of these work:
Default=https://provider.example/api/v1/subscribe?token=abc&flag=1
https://provider.example/api/v1/subscribe?token=abc&flag=1
```
