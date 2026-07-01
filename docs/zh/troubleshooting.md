# 故障排查与 FAQ

[← README](../../README.md) · [English](../troubleshooting.md)
手册：[架构](architecture.md) · [安装](installation.md) · [离线发布包](release-packaging.md) · [配置](configuration.md) · [自动更新](auto-update.md) · [运维](operations.md) · **故障排查** · [开发](development.md)

---

## 退出码（auto_update.sh）

| 退出码 | 含义 | 处理方法 |
|---|---|---|
| `0` | 成功 / 无操作 | 无需处理 |
| `2` | 部分失败 | 查看通知与 `logs/auto-update.log` |
| `3` | 配置 / 预检错误 | 修复报告中的前置条件；未做任何更改 |
| `4` | 另一次运行持有锁 | 等待，或在没有运行进行时移除残留的 `LOCK_DIR` |
| `5` | ACR 登录失败 | 检查 `ACR_PASSWORD` / 令牌是否过期 / 镜像仓库主机 |

## macvlan 自访问

**症状：** 在 NAS 上执行 `curl http://MIHOMO_IP:9090` 或在仪表盘“添加后端”时超时，但其他设备可正常访问。

**原因：** 按照 Linux macvlan 的设计，宿主机**无法**访问其自身 macvlan 容器的 IP。这是预期行为，并非缺陷。

**修复 / 变通方法：**
- 打开仪表盘，并从**另一台局域网设备**上运行连通性测试。
- 更新器的 mihomo 健康探测已经在容器*内部*运行（`docker exec`）以规避此问题；在 NAS 上你也可以同样操作：`docker exec mihomo wget -qO- http://127.0.0.1:9090/version`。
- 如果你确实需要宿主机→容器的访问，可在 NAS 上添加一个 macvlan shim 接口（进阶）。

## 架构不匹配（ARM 架构的 NAS）

**症状：** 更新器记录 `arch mismatch for … image=amd64 expected=arm64 - refusing to deploy`，或容器以 `exec format error` 反复崩溃重启。

**原因：** `docker-china-sync` 默认镜像 `linux/amd64`；而你的 NAS 是 ARM 架构。

**修复：** 将 arm64 加入镜像同步（在 `docker-china-sync/images.txt` 中使用 `--platform=linux/amd64,linux/arm64`）并设置 `EXPECTED_ARCH=arm64`；或在 Intel 架构的 NAS 上运行。拒绝部署的守卫机制是在*保护*你免于崩溃重启循环——它正按预期工作。

## 重启后网络丢失

**症状：** NAS 重启后，`docker compose up -d` 或更新器失败并提示 `network tproxy_network … could not be found`，或更新器预检中止（退出码 `3`）。

**原因：** 通过 CLI 创建的 macvlan 不一定能在重启 / Container Manager 重启后保留；父接口也可能发生变化（`eth0` ↔ `ovs_eth0`）。

**修复：** 添加在**开机**时运行 `scripts/setup_network.sh` 的任务计划项（参见 [运维 › 任务计划](operations.md)）。要立即恢复：`sudo ./scripts/setup_network.sh && docker compose up -d`。

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
`config/config.template.yaml`（或已渲染的 `…-data/config/config.yaml`），然后用
`docker compose up -d --force-recreate mihomo` 重新渲染——容器入口会在启动时按模板重新生成 `config.yaml`。

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
`enhanced-mode: fake-ip`），然后 `docker compose up -d --force-recreate mihomo`。用以下命令确认：

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

## mihomo 无法启动 / 反复崩溃重启

```bash
docker logs mihomo --tail 80
```
常见原因：
- **订阅或 DNS 为空 / 损坏** —— 渲染器会明确报错：`ERROR: subscription.txt has no usable URL` 或 `ERROR: DNS_… must be set`。请修复 `config/subscription.txt` / `.env` 中的 `DNS_*` 键，然后执行 `docker compose up -d mihomo`。
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

## DSM 7 计划任务没有运行

1. 在**控制面板 → 任务计划程序**确认任务已启用，并以 **root** 运行。
2. 重新运行 `sh scripts/install_scheduler.sh`，复制其中带绝对路径的完整命令。
3. 按“区域选项”的 NAS 时区核对触发时间；`UPDATE_TZ` 只影响日志时间戳。
4. 选中任务并点击**运行**，再检查保存的结果与 `logs/auto-update.log`。
5. 若退出码为 `3` 且提示 Docker 未就绪，说明 Container Manager 未能在
   `DOCKER_READY_TIMEOUT` 内启动；请检查套件状态或增加该超时。

如果每行日志出现两次或轮转异常，请删除 DSM 命令外层的
`>> logs/auto-update.log 2>&1`；更新器本身已经写日志。

## 自动更新时 Compose 应用失败

更新器现在会把 `compose up` 失败也当作回滚事件，而不只处理启动后的不健康。
在通知/日志中查找 `ROLLED BACK`。若回滚不完整，不要清理镜像；先用
`docker image inspect <id>` 验证旧 ID，再按[运维 › 手动回滚](operations.md)操作。

## 更新后 cloudflared 隧道掉线

分阶段更新会先验证临时连接器，再替换规范容器；若规范更新和回滚都无法完成，会保留候选。
如果只有 `cloudflared-candidate` 在运行，请不要删除——它可能是唯一实时连接器：

```bash
docker ps -a | grep cloudflared
docker logs --tail 100 cloudflared-candidate
```

请在候选保持连接时，按原始运行设置重建规范容器。紧急情况下可将候选重命名为
`cloudflared`；但其临时动态 IP 和省略的主机端口绑定会一直保留，直到重建完整规范配置。

## 提示“no image changes”但我本来预期会更新

更新器会将**正在运行**的容器镜像与新拉取的标签进行比较，并且只会部署与 `MIHOMO_IMAGE`/`METACUBEXD_IMAGE`/`CF_IMAGE` 匹配的引用。如果你将 `UPDATE_IMAGES` 设置为与这三者不同的引用，它会被**仅缓存**拉取，你会看到一条 `WARN`。请将它们对齐（参见 [自动更新 › 镜像引用](auto-update.md)）。同时确认镜像同步确实推送了新的摘要（检查 `docker-china-sync` 的 GitHub Actions 运行记录）。

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

## CI 没有运行

流水线在分支 `main` **和** `master` 上触发。如果你使用其他分支名称，请将其加入 `.woodpecker.yml` 的 `when.branch`。

## 整个家庭断网

如果设备使用 `MIHOMO_IP` 作为网关 / DNS 而 mihomo 宕机，它们就会被切断连接。最快的恢复方法：将受影响设备的网关 / DNS 改回路由器，然后修复 mihomo（`docker compose up -d mihomo`，检查日志）。对于有风险的改动，请考虑使用 kill-switch（紧急切断）+ 维护窗口。

## 容器健康但局域网客户端无法上网

先运行只读诊断：`sudo sh scripts/doctor.sh --egress`。它会检查宿主机 TUN、macvlan、
Compose 配置、镜像架构、控制器以及容器内的 `mihomo-tun` 数据通路。退出码 `0` 表示
结构正常，`2` 表示外部代理出口降级，`3` 表示本地配置或运行时故障。诊断通过后，
请从另一台局域网设备测试网关和 DNS；NAS 无法直接访问自己的 macvlan 子容器。
