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

## 仪表盘超时（TUN auto-route 截走控制器回包）—— 最常见

**症状：** 从**非 NAS 的局域网设备** `curl http://MIHOMO_IP:CONTROLLER_PORT/version` **超时**（不是
"connection refused"、不是 CORS、不是 401），但部署报告健康，且容器内
`docker exec mihomo wget -qO- http://127.0.0.1:9090/version` 返回 JSON。受影响的是 **v1.2.11 – v1.2.18** 部署的网关。

**原因：** 这些版本渲染了带 `auto-route: true` 的 `tun:` 块。mihomo 的 TUN auto-route 会安装策略路由
（高优先级 `ip rule` → 表 2022），把控制器的回包**截入 `mihomo-tun`**，而不是经局域网网卡发回，
导致外部 TCP 连接无法完成（[mihomo #1493](https://github.com/MetaCubeX/mihomo/issues/1493)）。容器内
`127.0.0.1` 探测仍通过，是因为环回不经该策略规则——所以部署看起来健康，但仪表盘连不上。

**解决：** 升级到 **v1.2.19+**，其中 TUN **可选且默认关闭**——渲染配置不含 `tun:` 块，控制器即可访问
（代理走 redir/tproxy/mixed 端口），重新部署即可。若要在不升级的情况下原地修复旧部署，在 `.env` 中设
`TUN_ENABLE=false`（或从 `…-data/config/config.yaml` 删除 `tun:` 块）后
`docker compose up -d --force-recreate mihomo`。用以下命令确认：

```sh
docker exec mihomo ip rule                       # 不应有把回包导入 tun 的高优先级规则
docker network inspect tproxy_network -f '{{.Driver}} {{index .Options "parent"}}'
```

若确实需要 mihomo 透明拦截局域网客户端转发的流量（且 DSM 内核支持 TUN），设 `TUN_ENABLE=true`——但此时
仪表盘在某些环境又会超时，除非把局域网排除出 tun（`route-exclude-address`，部分版本不可靠，
[#2617](https://github.com/MetaCubeX/mihomo/issues/2617)）。

## 仪表盘超时（macvlan 跑在 Open vSwitch 上）—— 较少见，依配置而定

若你**不在**受影响的 TUN 版本上（或 `TUN_ENABLE=false`），而局域网设备仍超时，则 macvlan 父接口可能是
**Open vSwitch** 端口（`ovs_eth0`）。在*某些* OVS 配置下，Docker macvlan 子接口的新 MAC 不会泛洪到其他端口，
导致局域网设备无法访问 `MIHOMO_IP`——但多数 OVS 环境可正常工作（并非必然）。用同样的 `curl` 与 CORS 区分
（返回 JSON ⇒ CORS；超时 ⇒ TCP 不可达），并确认父接口：

```sh
docker network inspect tproxy_network -f '{{.Driver}} {{index .Options "parent"}}'
```

若 OVS 上的 macvlan 子接口确实无法被局域网设备访问：使用非 OVS 网卡可避免该问题；或设
`TPROXY_DRIVER=ipvlan`（ipvlan L2 共享父接口 MAC，可穿越 OVS）使**仪表盘**可达——但注意 ipvlan 按目的 IP
解复用，**不会**为把 `MIHOMO_IP` 当网关的局域网客户端路由。ipvlan 仅适用于仪表盘，不适用于透明转发。

## mihomo 无法启动 / 反复崩溃重启

```bash
docker logs mihomo --tail 80
```
常见原因：
- **订阅或 DNS 为空 / 损坏** —— 渲染器会明确报错：`ERROR: subscription.txt has no usable URL` 或 `ERROR: DNS_… must be set`。请修复 `config/subscription.txt` / `.env` 中的 `DNS_*` 键，然后执行 `docker compose up -d mihomo`。
- **缺少 `/dev/net/tun`** —— 运行 `sudo ./scripts/setup_network.sh`。
- **`iptables (nf_tables): Could not fetch rule set generation id`** —— 镜像中的 nft 后端
  iptables 与 DSM 内核不兼容。在 `.env` 中设置 `TUN_AUTO_REDIRECT=false` 后重新部署；
  TUN `auto-route` 仍会提供网关数据通路。
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

## CI 没有运行

流水线在分支 `main` **和** `master` 上触发。如果你使用其他分支名称，请将其加入 `.woodpecker.yml` 的 `when.branch`。

## 整个家庭断网

如果设备使用 `MIHOMO_IP` 作为网关 / DNS 而 mihomo 宕机，它们就会被切断连接。最快的恢复方法：将受影响设备的网关 / DNS 改回路由器，然后修复 mihomo（`docker compose up -d mihomo`，检查日志）。对于有风险的改动，请考虑使用 kill-switch（紧急切断）+ 维护窗口。

## 容器健康但局域网客户端无法上网

先运行只读诊断：`sudo sh scripts/doctor.sh --egress`。它会检查宿主机 TUN、macvlan、
Compose 配置、镜像架构、控制器以及容器内的 `mihomo-tun` 数据通路。退出码 `0` 表示
结构正常，`2` 表示外部代理出口降级，`3` 表示本地配置或运行时故障。诊断通过后，
请从另一台局域网设备测试网关和 DNS；NAS 无法直接访问自己的 macvlan 子容器。
