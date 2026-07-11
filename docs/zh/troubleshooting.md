# 故障排查与 FAQ

[← README](../../README.md) · [English](../troubleshooting.md)
手册：[架构](architecture.md) · [安装](installation.md) · [离线发布包](release-packaging.md) · [配置](configuration.md) · [自动更新](auto-update.md) · [运维](operations.md) · [CLI](cli.md) · **故障排查** · [开发](development.md)

---

## 仪表盘症状索引

三种截然不同的故障模式看起来很相似。请按确切症状对号入座——务必从**非 NAS** 的局域网设备测试，
因为 NAS 无法访问其自身的 macvlan 子接口：

| `curl http://MIHOMO_IP:CONTROLLER_PORT/version` … | 故障模式 | 前往 |
|---|---|---|
| **超时** | 错误的 TUN 栈 / TUN 关闭截走控制器回包 | [仪表盘超时](#仪表盘超时错误的-tun-栈截走控制器回包-最常见) |
| 返回 JSON，但 MetaCubeXD 仍提示*“无法连接后端”* | CORS（跨域）拦截 | [仪表盘无法连接后端](#仪表盘无法连接后端) |
| 返回 `401 Unauthorized` | 仪表盘与 `.env` 的 `CONTROLLER_SECRET` 不一致 | [检查清单](#仪表盘无法连接后端) |

## 退出码（auto_update.sh）

| 退出码 | 含义 | 处理方法 |
|---|---|---|
| `0` | 成功 / 无操作 | 无需处理 |
| `2` | 部分失败 | 查看通知与 `../syno-mihomo-gateway-data/logs/auto-update.log`（若 `gateway.sh` 先运行过，它是指向 `gateway.log` 的链接） |
| `3` | 配置 / 预检错误 | 修复报告中的前置条件；未做任何更改 |
| `4` | 另一次运行持有锁 | 等待——见下方的残留锁说明 |
| `5` | ACR 登录失败 | 检查 `ACR_PASSWORD` / 令牌是否过期 / 镜像仓库主机 |

所记录 pid 已死亡的锁会被**自动**回收（`stale lock (pid …) - reclaiming.`；无 pid 的锁会先获得
2 秒宽限期），因此退出码 `4` 意味着确有一次 pid *存活*的运行持有该锁。只有在罕见的 pid 被复用的
边缘情形下，才需要手动删除 `LOCK_DIR`（默认 `/tmp/syno-mihomo-update.lock`）。

统一 CLI（`sh scripts/gateway.sh`，参见 [CLI](cli.md)）共用退出码 `0/2/3/4/5`，并新增
`6`（变更类子命令需要 root）和 `7`（变更类子命令缺少 `--yes` 被拒绝）——两者都表示未做任何更改。
`gateway.sh status` 与 `gateway.sh doctor`（均支持 `--json`）是官方支持的诊断子命令，可替代
下文提到的底层脚本。

## `required variable MIHOMO_IMAGE is missing a value`

**症状：** 任何 `docker compose` 命令都立即中止，并提示
`required variable MIHOMO_IMAGE is missing a value: set MIHOMO_IMAGE in .env - run ./install.sh`
（或对应的 `METACUBEXD_IMAGE` 版本）。

**原因：** `docker-compose.yml` 有意使用了 fail-closed（缺省即失败）的 `${VAR:?…}` 引用，而实际
生效的 `.env` 位于 `../syno-mihomo-gateway-data/.env`——直接执行 `docker compose up -d` 看不到它。
你在执行 compose 时没有带 `--env-file`、在错误的目录下执行，或 `install.sh` 尚未写入数据目录的
`.env`。

**修复：** 始终传入 env 文件：

```sh
docker compose --env-file ../syno-mihomo-gateway-data/.env up -d
```

如果 `../syno-mihomo-gateway-data/.env` 尚不存在，请先运行 `sh ./install.sh`。

## macvlan 自访问

**症状：** 在 NAS 上执行 `curl http://MIHOMO_IP:9090` 或在仪表盘“添加后端”时超时，但其他设备可正常访问。

**原因：** 按照 Linux macvlan 的设计，宿主机**无法**访问其自身 macvlan 容器的 IP。这是预期行为，并非缺陷。

**修复 / 变通方法：**
- 打开仪表盘，并从**另一台局域网设备**上运行连通性测试。
- 更新器的 mihomo 健康探测已经在容器*内部*运行（`docker exec`）以规避此问题；在 NAS 上你也可以同样操作：`docker exec mihomo wget -qO- http://127.0.0.1:9090/version`。
- 如果你确实需要宿主机→容器的访问，可在 NAS 上添加一个 macvlan shim 接口（进阶）。

## 架构不匹配（ARM 架构的 NAS）

**症状：** 更新器记录 `arch mismatch for … image=amd64 host=arm64 - refusing to deploy.`，或容器以 `exec format error` 反复崩溃重启。

**原因：** `docker-china-sync` 默认镜像 `linux/amd64`；而你的 NAS 是 ARM 架构。

**修复：** 将 arm64 加入镜像同步（在 `docker-china-sync/images.txt` 中使用 `--platform=linux/amd64,linux/arm64`）并设置 `EXPECTED_ARCH=arm64`；或在 Intel 架构的 NAS 上运行。拒绝部署的守卫机制是在*保护*你免于崩溃重启循环——它正按预期工作。

## 重启后网络丢失

**症状：** NAS 重启后，`docker compose --env-file ../syno-mihomo-gateway-data/.env up -d`
或更新器失败并提示 `network tproxy_network … could not be found`，或更新器预检中止（退出码 `3`）。

**原因：** 通过 CLI 创建的 macvlan 不一定能在重启 / Container Manager 重启后保留；父接口也可能发生变化（`eth0` ↔ `ovs_eth0`）。

**修复：** 添加在**开机**时运行 `scripts/setup_network.sh` 的任务计划项（参见
[运维 › 在 DSM 上配置定时任务](operations.md#在-dsm-上配置定时任务)）。要立即恢复：
`sudo ./scripts/setup_network.sh && docker compose --env-file ../syno-mihomo-gateway-data/.env up -d`。

## 重启后 TUN 静默失效（启动顺序竞态）

**症状：** `doctor.sh` 报告 `ERROR in-container TUN gateway is not ready`，而其余检查全部通过
（mihomo 运行中、控制器有响应）；`docker logs mihomo` 出现
`Start TUN listening error: configure tun interface: no such file or directory`；
使用显式代理端口的客户端仍然正常，因此这种降级很容易被忽视。

**原因：** Docker 在开机任务创建 `/dev/net/tun` **之前**就自启了 mihomo，容器的设备绑定
捕获到的是空节点。随后开机任务补建了宿主机节点，但已运行的容器仍保留着空绑定——
TUN 会一直失效，直到容器重启。

**修复：** `sudo docker restart mihomo`（设备绑定在启动时重新求值；用
`docker exec mihomo ls /sys/class/net/` 验证——必须能看到 `mihomo-tun`，然后重跑
`sudo sh scripts/doctor.sh`）。预防方法：把运行 `setup_network.sh` 的**开机**任务排在
启动顺序**最前**，让 `/dev/net/tun` 在 Container Manager 拉起容器之前就绪。

## 网络已存在但设置不同

**症状：** `setup_network.sh`（或安装器）记录
`docker network 'tproxy_network' exists with different settings; refusing implicit removal` /
`run install.sh and choose automatic or manual network cleanup`；或更新器预检中止（退出码 `3`），
并提示 `macvlan parent mismatch: network='…' live='…'` 或
`macvlan configuration drift: expected parent=… subnet=… gateway=…`。

**原因：** 现有 docker 网络的父接口/子网/网关与 `.env` 或实际路由不再一致——通常是父接口发生了变化
（`eth0` ↔ `ovs_eth0`），或 `SUBNET_CIDR`/`ROUTER_IP` 被修改过。脚本拒绝隐式删除不匹配的网络。

**修复：** 重新运行 `sh ./install.sh`，并在提示时选择自动（或手动）网络清理。或者，如果你确定
没有其他组件在使用该网络，也可以自行删除（先停止挂接的容器）：
`docker network rm tproxy_network && sudo ./scripts/setup_network.sh`，然后重新部署。

## 仪表盘无法连接后端

检查清单：
- UI 是否使用了 **NAS IP**（`http://NAS_IP:WEB_UI_PORT`），而*后端*是否使用了 **mihomo IP** + `CONTROLLER_PORT`？
- 是否从非 NAS 设备上测试（macvlan 自访问）？
- 如果你设置了 `CONTROLLER_SECRET`，是否已填写？
- 控制器是否确实已启用？`docker exec mihomo wget -qO- http://127.0.0.1:9090/version` 应返回 JSON。如果没有，请检查 `docker logs mihomo` 是否有渲染 / 启动错误。

**最常见原因：CORS（跨域）。** 如果在局域网设备上后端可达（`curl http://MIHOMO_IP:CONTROLLER_PORT/version`
能返回 JSON），但 MetaCubeXD 仍提示*“无法连接后端”*，那这是**跨域拦截**，而非网络或密钥问题。仪表盘由
`http://NAS_IP:WEB_UI_PORT` 提供，而控制器在 `MIHOMO_IP:CONTROLLER_PORT` 上响应（属于不同来源/origin），
近期版本的 mihomo 默认的 CORS 白名单很**严格**（只允许内置/官方托管的仪表盘，不含任意局域网地址）。可在浏览器
开发者工具（F12）→ Console 中确认（会看到 CORS 报错）。配置模板现已设置：

```yaml
external-controller-cors:
  allow-origins:
    - '*'        # 实际 API 访问仍由 secret 控制
  allow-private-network: true
```

因此全新部署已默认允许你的仪表盘。若网关是在**此项加入之前**部署的，请更新
`config/config.template.yaml`，然后用
`docker compose --env-file ../syno-mihomo-gateway-data/.env up -d --force-recreate mihomo`
（或 `sudo sh scripts/gateway.sh redeploy --yes`）重新渲染。**不要**改为编辑已渲染的
`…-data/config/config.yaml`——容器入口在每次启动时都会按模板重新生成它，本想让改动生效的那次
重启恰好会把这份编辑覆盖掉。

## 仪表盘超时（错误的 TUN 栈截走控制器回包）—— 最常见

**症状：** 从**非 NAS 的局域网设备** `curl http://MIHOMO_IP:CONTROLLER_PORT/version` **超时**（不是
"connection refused"、不是 CORS、不是 401），但部署报告健康，且容器内
`docker exec mihomo wget -qO- http://127.0.0.1:9090/version` 返回 JSON。

**原因：** `tun:` 块用的是带 `auto-route` 的 `gvisor`/`mixed` 栈，**或者** TUN 被关闭、网关失去数据通路。
在 `stack: mixed`/`gvisor` + `auto-route` 下，mihomo 会安装策略路由（高优先级 `ip rule` → 表 2022），
把控制器的回包**截入 `mihomo-tun`**，而不是经局域网网卡发回，导致外部 TCP 连接无法完成
（[mihomo #1493](https://github.com/MetaCubeX/mihomo/issues/1493)）。容器内 `127.0.0.1` 探测仍通过，
是因为环回不经该策略规则——所以部署看起来健康，但仪表盘连不上。

**解决：** 保持 TUN **开启**（`TUN_ENABLE=true`，默认值）并使用 **`system` TUN 栈**。与
`mixed`/`gvisor` + `auto-route` 不同，`system` 栈**不会**截走控制器回包，因此
`MIHOMO_IP:CONTROLLER_PORT` 上的仪表盘后端对局域网保持可达，同时透明网关转发照常工作。这是经过验证、
可正常工作的配置——**不要**为绕开 #1493 而关闭 TUN。重新部署当前版本即可；若要原地修复旧部署，确认渲染后的
`…-data/config/config.yaml` 中 `tun.enable: true` 且 `tun.stack: system`（并有 `allow-lan: true`、
`enhanced-mode: fake-ip`）——如果不是，请在 `../syno-mihomo-gateway-data/.env` 中设置
`TUN_ENABLE=true`，或修正模板（绝不要改已渲染的文件；它在每次启动时都会重新生成）——然后执行
`docker compose --env-file ../syno-mihomo-gateway-data/.env up -d --force-recreate mihomo`。
用以下命令确认：

```sh
docker exec mihomo ip rule                       # 不应有把回包导入 tun 的高优先级规则
docker network inspect tproxy_network -f '{{.Driver}} {{index .Options "parent"}}'
```

设置 `TUN_ENABLE=false` 会让 mihomo 作为**普通（非网关）代理**运行（仅可通过
redir/tproxy/mixed/socks 端口访问）——它**不会**透明拦截局域网客户端，因此不要把它当作 #1493 的绕过手段。

## Open vSwitch **不是**仪表盘/网关超时的原因

早先的说法把**Open vSwitch** 父接口（`ovs_eth0`）归咎为“局域网设备访问仪表盘/网关超时”的原因，
并建议改用 `ipvlan` 或关闭 OVS。那是**误诊。** 在 OVS 父接口上，Docker **macvlan 子接口的 IP 确实可被
其他局域网设备访问**——已实测：位于某个 macvlan IP 上的干净容器，能从另一台局域网设备应答 ping、ARP 和
HTTP。超时的真正根因是一次**配置回归**（TUN 被关闭且 TUN 栈被设为 `mixed`），应通过上述 TUN 栈模型修复，
**而非**网络改动。请保持 `TPROXY_DRIVER=macvlan`；针对该症状不要改用 `ipvlan` 或关闭 OVS。

（`ipvlan` 反而会破坏网关：它按目的 IP 解复用，**不会**为把 `MIHOMO_IP` 当网关的局域网客户端路由。）

## 容器健康但局域网客户端无法上网

先运行只读的结构化诊断：

```bash
sudo sh scripts/doctor.sh --egress
```

它会检查宿主机 TUN 设备、macvlan、Compose 配置、镜像架构、控制器以及容器内的 `mihomo-tun`
数据通路。退出码 `0` 表示结构正常；`2` 表示降级——可选服务或出口告警（仪表盘容器未运行，或
`--egress` 探测失败 / 没有可用的下载工具）；`3` 表示本地配置或运行时故障。
`sudo sh scripts/gateway.sh doctor --json` 运行同一套检查并输出一个 JSON 对象
（参见 [CLI](cli.md)）。诊断通过后，请从另一台局域网设备测试网关和 DNS，因为 NAS 无法访问
自己的 macvlan 子容器。

## mihomo 无法启动 / 反复崩溃重启

```bash
docker logs mihomo --tail 80
```
常见原因：
- **订阅或 DNS 为空 / 损坏** —— 渲染器会明确报错：`ERROR: subscription.txt has no usable URL`
  或 `ERROR: DNS_… must be set`。请修复**实际生效**的文件
  `../syno-mihomo-gateway-data/config/subscription.txt` /
  `../syno-mihomo-gateway-data/.env` 中的 `DNS_*` 键（仓库内的 `config/` 只附带 `.example`），
  然后执行 `docker compose --env-file ../syno-mihomo-gateway-data/.env up -d --force-recreate mihomo`。
- **缺少 `/dev/net/tun`** —— 运行 `sudo ./scripts/setup_network.sh`。
- **`iptables (nf_tables): Could not fetch rule set generation id`** —— 镜像中的 nft 后端
  iptables 与 DSM 内核不兼容。在 `.env` 中设置 `TUN_AUTO_REDIRECT=false` 后重新部署；
  `system` TUN 栈仍会提供网关数据通路。
- **架构错误的镜像** —— 参见上文。

## config.yaml 中的订阅 URL 看起来不对

渲染器只会去除可选的前导 `Name=` 标签，并保留其余所有内容，包括 `?token=…&flag=…`。如果你的服务商 URL 本身包含字面量 `|` 或 `\`，它们会被转义以适配 `sed`；`subscription.txt` 中多余的换行符会被忽略（仅取第一行有效内容）。验证渲染后的值：

```bash
docker exec mihomo grep -m1 'url:' /root/.config/mihomo/config.yaml
```

## ACR 登录失败（退出码 5）

- 确认 `DOCKER_REGISTRY` 主机、`DOCKER_USERNAME` 和 `ACR_PASSWORD`（后者是机密；确保 `.env` 为 `chmod 600`）。
- ACR 访问令牌可能会过期——请在阿里云控制台重新生成。
- 手动测试：`printf '%s' "$ACR_PASSWORD" | docker login "$DOCKER_REGISTRY" -u "$DOCKER_USERNAME" --password-stdin`。

## 拉取缓慢 / 超时

到 ACR 的网络不稳定。更新器会重试拉取（`PULL_RETRIES`/`PULL_RETRY_DELAY`），并在切换**之前**完成拉取，因此拉取失败会中止而不会触及正在运行的容器。如有需要可增大重试相关的环境变量，或将计划任务安排得离镜像同步窗口更远一些。

**`manifest unknown` 不是网络抖动：** 当拉取错误显示 manifest unknown 时，通知会附加
`(not mirrored in ACR? add the upstream image to docker-china-sync/images.txt)`
——该标签在你的 ACR 命名空间中根本不存在（此提示同样适用于三件套与已登记的通用目标）。
重试无济于事；请先镜像该映像。

## DSM 7 计划任务没有运行

1. 在**控制面板 → 任务计划程序**确认任务已启用，并以 **root** 运行。
2. 重新运行 `sh scripts/install_scheduler.sh`，复制其中带绝对路径的完整命令。
3. 按“区域选项”的 NAS 时区核对触发时间；`UPDATE_TZ` 只影响日志时间戳。
4. 选中任务并点击**运行**，再检查保存的结果与
   `../syno-mihomo-gateway-data/logs/auto-update.log`。
5. 若退出码为 `3` 且提示 Docker 未就绪，说明 Container Manager 未能在
   `DOCKER_READY_TIMEOUT` 内启动；请检查套件状态或增加该超时。

如果每行日志出现两次或轮转异常，请删除 DSM 命令外层的
`>> logs/auto-update.log 2>&1`；更新器本身已经写日志。

## 自动更新时 Compose 应用失败

更新器现在会把 `compose up` 失败也当作回滚事件，而不只处理启动后的不健康。
在通知/日志中查找 `ROLLED BACK`。若回滚不完整，不要清理镜像；先用
`docker image inspect <id>` 验证旧 ID，再按[运维 › 手动回滚](operations.md#手动回滚)操作。

## 更新摘要显示 `compose: SKIPPED (TUN auto-redirect incompatible…)`

当 `TUN_AUTO_REDIRECT=true` 且存在待应用的 compose 变更时，更新器会在重建任何容器**之前**，
用一个一次性的特权容器探测新 mihomo 镜像的 iptables 前端与 DSM 内核是否兼容。若探测失败，
compose 这一对会被跳过并计为失败——正在运行的容器不受影响，通用目标 / cloudflared 仍照常进行。
`--dry-run` 从不运行该探测，只会注明真实应用时会由该探测把关。

**修复：** 在 `../syno-mihomo-gateway-data/.env` 中设置 `TUN_AUTO_REDIRECT=false` 并重新部署——
`system` TUN 栈仍会提供网关数据通路。根因与上文的 `iptables (nf_tables)` 崩溃重启相同；
该探测正是为了防止那种崩溃重启。

## 某个已登记的（通用）更新目标失败

已登记的容器（通过 `gateway.sh update --enable/--disable NAME` 管理）以带健康门的原地重建方式
更新。通知行会告诉你得到的是哪种结果：

- `NAME: FAILED health -> ROLLED BACK to last-good (now healthy)` —— 自动回滚已生效；
  可以从容排查新镜像的问题。
- `NAME: REFUSED (not replayable - container untouched; see log, or de-enroll it)` —— 捕获阶段
  发现了回放引擎无法忠实复现的设置（值中嵌入换行符、静态 IPv6 地址、`-P`/`PublishAllPorts`、
  `OomScoreAdj`、设备 cgroup 规则等）。未做任何更改。请在去掉不受支持的设置后重建容器，
  或将其取消登记：`sudo sh scripts/gateway.sh update --disable NAME --yes`。
- `NAME: FAILED AND rollback incomplete -> MANUAL ATTENTION NEEDED` —— 需要手动重建容器；
  最近一次已知良好的规格保存在 `../syno-mihomo-gateway-data/state/last-good/NAME`。
- `generic targets: INVALID enrollment list (see log)` —— 受管列表
  （`../syno-mihomo-gateway-data/state/update-targets`）未通过校验，且**没有任何**通用目标
  被处理。用 `sh scripts/gateway.sh update --list-targets` 检查后重新登记。

`sh scripts/gateway.sh update --last` 显示上一次运行的结果（`state/last-run.json`，
含 `updated_names`/`failed_names`/`rolled_back_names`）。

## 更新后 cloudflared 隧道掉线

分阶段更新会先验证临时连接器，再替换规范容器。更新失败会报告三种不同结果之一：
`update FAILED (candidate discarded; the old connector is untouched)`（无需处理）、
`update FAILED -> ROLLED BACK to the previous connector (now connected)`（自动恢复），或
`FAILED AND canonical not restored -> MANUAL ATTENTION NEEDED`——最后这种情况会保留候选容器，
因为它可能是唯一存活的连接器。如果只有 `cloudflared-candidate` 在运行，请不要删除它：

```bash
docker ps -a | grep cloudflared
docker logs --tail 100 cloudflared-candidate
```

请在候选保持连接时，按原始运行设置重建规范容器。紧急情况下可将候选重命名为
`cloudflared`；但其临时动态 IP 和省略的主机端口绑定会一直保留，直到重建完整规范配置。

## 提示“no image changes”但我本来预期会更新

更新器会将**正在运行**的容器镜像与新拉取的标签进行比较，并且只会部署与 `MIHOMO_IMAGE`/`METACUBEXD_IMAGE`/`CF_IMAGE` 匹配的引用。如果你将 `UPDATE_IMAGES` 设置为与这三者不同的引用，它会被**仅缓存**拉取，你会看到一条 `WARN`。请将它们对齐（参见 [自动更新 › 镜像引用](auto-update.md#镜像引用)）。同时确认镜像同步确实推送了新的摘要（检查 `docker-china-sync` 的 GitHub Actions 运行记录）。

## “旧部署已在清理阶段被移除”

安装器只有在所有非破坏性校验通过后才会拆除旧栈，但之后的步骤（通常是 macvlan 创建）仍可能失败。
出现此消息意味着网关处于**停机**状态——没有任何组件在为局域网客户端服务。请修复上面报告的问题
（通常是父接口或 IP 冲突）后再次选择“部署”；`sh scripts/doctor.sh` 可查看当前实际存在的组件。
下次运行安装器时，预处理步骤会重新盘点任何未完成状态。

## cron 设置提示“尚无生效的计划”

cron 流程会把 `UPDATE_SCHEDULE`/`UPDATE_TZ`/`UPDATE_ENABLED` 保存到 `.env`，但只有在 DSM
任务计划程序任务（推荐）或 crontab 条目存在后，计划才会真正运行。如果在两者都未创建时选择
“完成”，安装器会给出警告，并提议设置 `UPDATE_ENABLED=false` 以保持状态一致。请重新运行 cron
流程并选择其中一种调度方式，或以 root 运行 `sh scripts/gateway.sh cron --apply-crontab --yes`。

## Container Manager 显示异常 / 项目“卡住”

CLI 创建的 compose 栈不会注册为 Container Manager 的*项目*；脚本驱动的重建（自动更新器的
受控部署）也可能让手工创建的项目条目失去同步（“卡住”）。这只是外观问题：真实状态以
`docker`/`docker compose` 为准，`sh scripts/doctor.sh` 与安装器的“状态”菜单都会如实报告。
不要用项目页签的“构建/更新”去“修复”它——那会绕过摘要门、健康门和回滚。如果你曾手工创建
项目条目，删除该项目（不要删除容器），此后仅通过安装器/CLI 管理本栈。

## 树莓派：ACR 未同步 arm64 镜像

**症状：** 树莓派 compose 模式（`install-pi.sh`）下，部署/更新在拉取阶段失败，或架构守卫
以 `arch mismatch for … image=amd64 host=arm64` 拒绝——而安装器此前刚打印过一条 ACR
架构提示。

**原因：** 树莓派上 `REGISTRY_MODE=acr` 同样是默认值，而默认的 `docker-china-sync`
流水线只同步 `linux/amd64`——你的 ACR 命名空间里还没有这些镜像的 arm64 副本。

**处理：** 先同步 arm64（在 `docker-china-sync/images.txt` 中给每个镜像加
`--platform=linux/amd64,linux/arm64`），等一轮同步跑完再部署；或在无封锁网络上改用
`REGISTRY_MODE=docker`。与[架构不匹配（ARM 架构的 NAS）](#架构不匹配arm-架构的-nas)是
同一道守卫：拒绝就是保护，不是故障。背景：
[安装 — 树莓派](installation-pi.md#树莓派上的-compose-模式)。

## 树莓派 lite：更新被回滚

**症状：** 更新通知显示 `rolled back`，`state/lite/last-run.json` 中 `"rolled_back":1`，
退出码 `2`。

**原因：** 新装的 mihomo 二进制没有通过重启后的健康门（服务活跃 + 重启次数稳定 + 控制器
探测 + TUN 链路），更新器于是恢复了 `bin/mihomo.prev`——连同记录的版本状态一起回退，
这正是下一次计划运行能干净重试的原因。

**处理：** 通常无需处理——网关正运行在上一个二进制上。查看
`journalctl -u mihomo-gateway -n 50` 和 `logs/auto-update.log` 弄清新版本为何失败；
可固定 `MIHOMO_VERSION` 跳过有问题的版本。如果通知里出现 `MANUAL ATTENTION`，说明连
恢复本身都失败了——运行 `sh scripts/pi/lite_ctl.sh doctor` 并按报告修复。

## 树莓派：Wi-Fi（wlan0）上的 macvlan 被拒绝

**症状：** compose 模式下 `install-pi.sh` 拒绝所选/检测到的父接口（`wlan0`）。

**原因：** macvlan 子接口要在父链路上呈现额外的 MAC 地址；Wi-Fi 驱动和 AP 客户端隔离
通常会丢弃这些帧——栈能部署成功，然后局域网里谁也访问不到它。

**处理：** compose 模式请使用有线以太网——或者改用 lite 模式：它直接绑定树莓派自己的
IP，在 Wi-Fi 上也能工作。这是树莓派特有的快速失败；
[OVS 的讨论](#open-vswitch-不是仪表盘网关超时的原因)与此无关。

## 树莓派 lite：53 端口已被占用

**症状：** lite 安装时就警告过 53 端口；`lite_ctl doctor` 给出警告并指出进程名（常见为
`systemd-resolved` 或 `dnsmasq`）；客户端 DNS 无响应，或 mihomo 反复重启。

**原因：** mihomo 的 DNS 必须绑定 `:53`，而 Raspberry Pi OS / Debian 的原始镜像往往
自带一个已经监听在那里的解析器。

**处理：** 停用冲突的监听或把它挪离 53 端口（`systemd-resolved` 是它的 stub 监听；
`dnsmasq` 是它的 DNS 端口），然后 `sudo sh scripts/pi/lite_ctl.sh start` 并重跑
`doctor`——此时应报告 53 端口由 mihomo 提供服务。

## CI 没有运行

流水线在分支 `main` **和** `master` 上触发。如果你使用其他分支名称，请将其加入 `.woodpecker.yml` 的 `when.branch`。

## 整个家庭断网

如果设备使用 `MIHOMO_IP` 作为网关 / DNS 而 mihomo 宕机，它们就会被切断连接。最快的恢复方法：将受影响设备的网关 / DNS 改回路由器，然后修复 mihomo（`docker compose --env-file ../syno-mihomo-gateway-data/.env up -d mihomo`，检查日志）。对于有风险的改动，请考虑使用 kill-switch（紧急切断）+ 维护窗口。

## NAS 自身无法访问厂商服务（主机解析器失效）

**症状：** DSM 无法访问厂商服务/套件中心；NAS 上所有域名解析失败；bridge 容器（继承 NAS 的
`resolv.conf`）也全部无法解析——而网关仍在正常转发局域网客户端（它们用的是 mihomo 的 DNS，
不是 NAS 的）。

**原因：** NAS 自己的 DNS（控制面板 → 网络 → 常规）指向了在当前网络不可达的解析器——在有
过滤的网络上只配 `1.1.1.1` 是典型案例。

**解决：** 设置可达的解析器（有过滤的网络用国内解析器，如 `223.5.5.5` 与 `119.29.29.29`）。
`doctor` / `gateway.sh doctor --json` 现在会逐一探测配置的解析器（`host_dns` 检查），并点名
失效者、降级报告。

## 网络正常但 cloudflared 隧道掉线

**症状：** 到隧道边缘节点的原始 TCP 明明可达，隧道却一直断开。

**原因：** bridge 容器在**启动时**复制主机的 `resolv.conf`；主机解析器失效（见上一条）时
cloudflared 无法解析边缘节点域名。

**解决：** 先修复主机 DNS，然后 `docker restart cloudflared`。若要永久解耦，在 `.env` 设置
`CF_DNS`（逗号分隔 IPv4）并执行 `sudo sh scripts/gateway.sh update --yes`——蓝绿重建会把它
作为 `--dns` 应用。只要容器存在，`doctor` 就报告 `cloudflared` 的 ok/down/absent。

## 首次启动卡在下载 geo 数据库

**症状：** mihomo 首次启动迟迟不能完成；日志显示 geo 数据库下载停滞。

**原因：** `GEOSITE,CN` / `GEOIP,CN` 规则需要 geo 数据库；未缓存时 mihomo 会在启动时经由
常被过滤网络屏蔽的 CDN 下载。

**解决：** 部署现在会以镜像回退的方式把 `GeoSite.dat` + `geoip.metadb` 预下载到数据目录
（`scripts/lib/geodata.sh`；`GEODATA_MIRRORS` 可覆盖镜像列表）。未缓存时 `doctor` 会警告
（`geodata` 检查）；重新部署会再次预下载。

## 开启 no-resolve 后小众国内网站变慢或打不开

**症状：** 设 `DNS_GEOIP_NO_RESOLVE=true` 后，某个小众/地方性国内网站变慢或拒绝访问，
而大型国内网站一切正常。

**原因：** `no-resolve` 让 `GEOIP,CN,DIRECT` 规则不再解析域名，于是 `geosite:cn` 漏收的
国内域名不再走 DIRECT 捷径——它落到 `MATCH` 上、经代理访问。这是该开关已写明的代价，
不是故障：网站通常仍可用（走隧道），只有当它拒绝境外访客时才会打不开。

**解决：** 在 `.env` 设 `DNS_GEOIP_NO_RESOLVE=false` 并重新部署——规则恢复为经国内解析器
解析未命中的域名，即[配置 DNS 矩阵](configuration.md#dns注入到配置模板中)中记录的隐私
残余。

## 从旧的平铺安装升级

**症状：** 在旧的“所有文件一个文件夹”安装旁解压新版本后，`doctor` 报告 `.env is missing`，
且保留模式的部署被拒绝——现有 `mihomo`/`mihomo-ui` 容器属于**旧的/外来 Compose 项目**
（`foreign_project` 清理原因）。

**解决：** 先执行 `sudo sh scripts/migrate_legacy.sh --yes`（自动探测旧目录；支持
`--from DIR` / `--dry-run`）——它把订阅、geo 数据库和 `cache.db` 复制进数据目录并打印
`.env` 提示，绝不改动旧安装。然后 `sudo sh ./install.sh` → 部署，当规划器把旧容器标记为
旧版/外来项目时选择**自动清理**，让新栈接管容器名。
