# 自动更新

[← README](../../README.md) · [English](../auto-update.md)
手册：[架构](architecture.md) · [安装](installation.md) · [离线发布包](release-packaging.md) · [配置](configuration.md) · **自动更新** · [运维](operations.md) · [CLI](cli.md) · [故障排查](troubleshooting.md) · [开发](development.md)

---

`scripts/auto_update.sh` 是[更新流水线](architecture.md#更新流水线镜像同步--拉取)中位于 DSM 端的那一半：
它从阿里云 ACR 拉取镜像，检测哪些镜像确实发生了变化，并安全地重新部署它们。它
被设计为按计划无人值守运行，并且**永远不会让网关处于损坏状态**。

## ACR 配置

"推送"端位于同级仓库 **`docker-china-sync`** 中。简而言之：

1. 创建一个阿里云**容器镜像服务（ACR）**实例 + 命名空间（`myns`）。
2. 在 `docker-china-sync` 中，设置四个 GitHub secret（`ALIYUN_REGISTRY`、`ALIYUN_NAME_SPACE`、
   `ALIYUN_REGISTRY_USER`、`ALIYUN_REGISTRY_PASSWORD`），并在 `images.txt` 中列出你的镜像
   （它已经包含了 `mihomo`、`metacubexd`、`cloudflared`）。它会每晚镜像同步一次（23:00 UTC）。
3. ACR 命名规则为 `REGISTRY/NAMESPACE/<image:tag>`（除非镜像*名称*发生冲突，否则不加命名空间前缀）。
   因此 `metacubex/mihomo:latest` → `registry.cn-….aliyuncs.com/myns/mihomo:latest`。

在 NAS 上，在 `.env` 中设置：`DOCKER_REGISTRY`、`DOCKER_USERNAME`、`ACR_PASSWORD`，并将
`MIHOMO_IMAGE` / `METACUBEXD_IMAGE` / `CF_IMAGE` 指向这些 ACR 引用。最小权限：为 NAS
创建一个专用的**只读拉取** ACR 子账号/RAM 账号，与 `docker-china-sync` 的推送账号分开
——更新器只需要拉取。

## 镜像引用

`MIHOMO_IMAGE` / `METACUBEXD_IMAGE` / `CF_IMAGE` 由 `install.sh` 根据
`REGISTRY_MODE`（默认 `acr`，或 `docker` 表示上游公共镜像）+ `DOCKER_REGISTRY` +
`ACR_NAMESPACE` + 各 `*_TAG` 值**推导**而来——参见[配置 › 容器镜像](configuration.md#容器镜像)。
无论当前处于哪种模式，解析出的三个引用都会写入 `.env`，部署调度会将每个
`UPDATE_IMAGES` 条目与它们进行**精确**匹配。请保持 `UPDATE_IMAGES` 继承这三个变量：

```dotenv
UPDATE_IMAGES="${MIHOMO_IMAGE} ${METACUBEXD_IMAGE} ${CF_IMAGE}"
```

如果某个 `UPDATE_IMAGES` 条目与这三者都不匹配，它将**被拉取但不会被部署**
（仅缓存），并且该次运行会记录一条 `WARN`。这是一个信号，说明你把 `UPDATE_IMAGES` 设置成了与
部署变量不同的引用。请让它们与 `docker-china-sync/images.txt` 保持一致。

## 为什么不用 Container Manager 自带的更新按钮？

Container Manager 的*项目*页签提供“构建/更新”——请**不要**对本栈使用它。它会重新拉取
`:latest` 并重建容器，既不比较摘要，也没有健康门和回滚；一旦上游镜像有问题，网关（以及
整个局域网的出口）会在没有自动恢复的情况下瘫痪。下面的计划脚本 `auto_update.sh` 存在的
意义正是补上这些防护。

## 运行序列

每次调用都会按顺序执行以下步骤（所有内容都会记录到 `UPDATE_LOG`——相对路径在持久
数据目录下解析，因此默认位置是 `../syno-mihomo-gateway-data/logs/auto-update.log`；
下文提到的每个可调项——`DOCKER_READY_TIMEOUT`、`HEALTH_RETRIES`、`NOTIFY_WEBHOOK_URL`
等——的默认值见[配置](configuration.md#自动更新编排器)及其
[高级可调项](configuration.md#高级可调项可选的-env-覆盖项)表）：

1. **加锁** — 一个原子的、可感知 PID 的 `mkdir` 锁。第二个并发运行会以退出码 `4`
   干净地退出，并且*不会*触碰正在运行的那次运行的锁（只有持有者才能释放它）。锁可以
   自愈：所记录 PID 已死亡的陈旧锁会被自动回收；没有 PID 的锁会得到 2 秒宽限期
   （持有者可能仍在写入其 PID），之后才被视为已崩溃。Ctrl-C / TERM 会干净地终止运行
   （退出码 `130`/`143`），并且仍会释放锁。
2. **终止开关校验** — `UPDATE_ENABLED=False` 之类的拼写错误会明确失败。
3. **终止开关** — 如果 `UPDATE_ENABLED=false`，则以 `0` 退出（除非使用 `--force`），
   此时不要求其他部署设置完整。
4. **配置校验** — 拒绝错误数字、通配符或不安全镜像引用、遗漏任一 Compose 服务，或在已配置
   `CF_IMAGE` 时没有将其加入 `UPDATE_IMAGES`。
5. **预检**（任何一步失败时中止，且不触碰任何内容）：
   - **Docker 就绪** — 最多等待 `DOCKER_READY_TIMEOUT`，直到 Container Manager、守护
     进程和 Compose 就绪；这可以应对 DSM 开机任务的竞态；
   - **[架构守卫](#架构守卫)** — NAS（宿主机）架构必须等于 `EXPECTED_ARCH`；
   - **TUN** — `/dev/net/tun` 必须存在；
   - **网络** — `tproxy_network` 必须存在，且其 macvlan 父接口仍与实际接口匹配；
   - **Compose 模型** — 在任何仓库拉取之前先校验 `docker-compose.yml` 与 `.env`；
   - **ACR 登录** — 非交互式 `--password-stdin`；遇到 `401` 时会发出通知并中止（退出码 `5`）。
6. **检测变更** — 对网关三件套*以及*每个符合条件的已登记
   [通用目标](#通用目标任意已登记的容器)：逐一 `docker pull`（带重试），要求拉取到的
   引用可在本地检查，先将拉取镜像的架构与宿主机比对，再比较**运行中容器**的内容寻址
   镜像 ID 与刚拉取的本地 ID。不同（或容器不存在）才需要部署。若拉取失败且错误明确
   指向 manifest 缺失，会附带提示：该镜像很可能尚未镜像同步到 ACR。
7. **短路** — 干净的无操作在此以 `0` 退出，且*保持静默*，除非设置了
   `NOTIFY_ON_NOCHANGE=1`（可设为每晚心跳）。`--dry-run` 也在此处报告将要应用的集合
   并停止，只会*注明*下方的 TUN 探测将决定 Compose 应用与否——dry-run 绝不会运行
   特权容器。
8. **TUN 自动重定向探测** — 仅真实运行，且仅当 compose 对发生变化并且
   `TUN_AUTO_REDIRECT=true` 时：在一次性网络命名空间中验证目标镜像能否针对 DSM 内核
   创建 iptables NAT 链。不兼容时跳过 Compose 应用（按失败上报），而通用目标和
   cloudflared 仍可继续。
9. **应用** — 严格串行，影响面最小者优先（DEC-5），因此每个较早的步骤都仍运行在
   已知良好的网关之上：
   1. **通用目标** — 原地重建 + 分层健康门 + 自动恢复，见[下文](#通用目标任意已登记的容器)；
   2. **cloudflared** — 按名称[蓝绿部署](#cloudflared-蓝绿部署)；
   3. **Compose 服务最后** — Compose v2 运行 `docker compose up -d --pull never`：
      使用刚刚拉取并校验过的本地镜像，不会与仓库发生第二次竞态。旧版 Compose v1
      回退到其缓存镜像行为并输出一条警告。Compose 应用失败*或*
      [健康门](#健康门与回滚mihomo)失败时，会确认旧镜像 ID 仍然存在，重新打标，在
      禁止隐式拉取的情况下重建，重新运行健康检查，并发送失败通知。
10. **清理**悬空层（仅在完全成功时进行，因此回滚目标不会被提前删除）。
11. **通知** — 摘要以计数开头（`updated:N unchanged:N failed:N rolled_back:N`），
    后跟逐目标的条目；通过 Webhook（设置了 `NOTIFY_WEBHOOK_URL` 时）+ 尽力而为的
    Synology 推送 + 日志发送，失败*和*成功时都会发出（无变更的运行保持静默——见第 7
    步）。可靠的默认告警途径是 DSM 任务计划的“发送运行详情”邮件（由下方退出码驱动）
    ——DSM 7 上 `synodsmnotify` 并不可靠（需要套件注册的字符串），且绝不会抑制 Webhook。
12. **记录** — 每条终止路径（经由 `EXIT` 陷阱）都会原子地写入
    `state/last-run.json`：

    ```json
    {"ts":"…","exit_code":2,"dry_run":0,"updated":1,"unchanged":3,"failed":1,
     "rolled_back":0,"updated_names":"…","failed_names":"…","rolled_back_names":"…"}
    ```

    提前中止的路径上各计数默认为 `0`；被锁拒绝的运行（退出码 `4`）绝不会覆盖正在
    运行的那次运行的记录。它会原样呈现为 `gateway.sh status --json` 中的
    `last_update`，也可通过 `gateway.sh update --last` 查看。

### 架构守卫

`docker-china-sync` 默认镜像同步 `linux/amd64`。如果你的 NAS 是 ARM 架构，那么 amd64 的 `:latest`
是无法运行的。该守卫分两层：预检先验证 **NAS 本身**与 `EXPECTED_ARCH` 匹配（可捕获
硬件更换后残留的陈旧 `.env`）；随后在检测变更阶段，更新器检查每个已拉取镜像的
`Architecture`，并**拒绝部署**任何与宿主机不匹配的镜像（绝不会为了一个无法运行的镜像
而拆掉正在运行的容器）。对于 ARM NAS：要么在 `docker-china-sync/images.txt` 中镜像同步
arm64 镜像并设置 `EXPECTED_ARCH=arm64`，要么保留一台 amd64 的 NAS。

### 健康门与回滚（mihomo）

重建之后，"正在运行"还不够——mihomo 可能已经启动但没有路由任何流量。该健康门
（`HEALTH_RETRIES` × `HEALTH_INTERVAL`）会：

- 确认容器处于 `Running` 状态且**没有陷入崩溃重启循环**：`RestartCount` 必须在该间隔
  内保持稳定，*并且*自健康门启动以来的增量不得达到 `HEALTH_MAX_RESTARTS`（默认 `3`）
  ——短暂的稳定无法掩盖一个重启循环；
- **在容器内部**（`docker exec`）探测控制器的 `GET /version`；配置密钥时会携带
  bearer token。缺少探测工具或响应失败都会使健康门失败；
- 当 `TUN_ENABLE=true`（默认值——这本来就是一台网关）时，验证容器内的 `mihomo-tun`
  网卡与 IPv4 转发，避免控制器响应正常却掩盖了损坏的透明代理数据通路。当
  `TUN_ENABLE=false`（纯代理模式）时没有 TUN 数据通路，此探测为无操作；
- 检查 metacubexd 是否在运行（仅警告——UI 不是关键组件）。

[TUN 自动重定向探测](#运行序列)是独立的：它在 Compose 应用*之前*运行（仅真实运行），
绝不属于本健康门。

如果健康门失败，更新器会校验并**重新打标到上一个正常的镜像**（在切换之前已捕获），
在禁止隐式拉取的情况下重建，重新运行健康门，并发出带有详细信息的 FAILURE 通知。
该次运行不会清理失败镜像。

> 从 NAS 进行更深入的出口/DNS 探测会受到 macvlan 自我访问的限制；请从
> 另一台 LAN 设备上执行这些探测。参见[运维 › 手动健康检查](operations.md#手动健康检查)。

### cloudflared 蓝绿部署

cloudflared 是**外部的**（不在本 compose 中），通过容器名称进行管理：

1. 在私有临时目录中**捕获**旧镜像 ID 及可重放的运行规格：环境变量/令牌、精确命令参数、入口点、
   重启策略、用户/工作目录、挂载、端口、网络/静态 IP、DNS、能力、设备、安全选项和 tmpfs。
   无法安全重放的容器网络或自动删除模式会在接触旧连接器前失败。
2. 与旧连接器并行启动 `<name>-candidate`，特意省略已发布的主机端口和静态 IP，
   使其不可能与在线容器冲突；额外网络临时使用动态地址。
3. 通过原生健康状态或注册日志标记**证明候选已连接**。失败时只删除候选，规范容器保持不变。
4. 停止并删除旧容器，用 `CF_IMAGE` 和完整保存的端口/网络规格重建规范容器；候选在验证期间
   继续维持隧道。
5. 成功后删除候选。若失败，则用保存的旧镜像 ID/规格重建并验证规范容器。若新旧规范容器都无法
   恢复，则保留仍连接的候选并报告手动恢复步骤，而不会误删唯一连接器。

首次配置（没有现有容器）需要 `CF_TUNNEL_TOKEN`；此后令牌
会从正在运行的容器中读取，你不需要在 `.env` 中配置它。

已发布的 metrics 端口只会在临时候选上省略，并会在规范替换容器上恢复（同样，固定的
MAC 地址也绝不会在候选上重放——两个容器共用同一个二层地址会导致 ARP 抖动）。若镜像
没有原生 healthcheck，连接检查会回退到 cloudflared 的注册日志。

运行摘要会区分三种失败形态：候选始终未能连接时，旧连接器**保持不变**（候选被丢弃）；
切换失败但已从保存的镜像恢复时计为 **rolled_back**；而当新旧规范容器都无法恢复时，
本次运行报告 **MANUAL ATTENTION**——此时 `-candidate` 容器可能是唯一存活的连接器，
请勿删除它。

## 通用目标（任意已登记的容器）

除网关三件套外，更新器还会刷新**任何你登记的运行中容器**，前提是其镜像已在你的 ACR 上
（`DOCKER_REGISTRY/ACR_NAMESPACE/...`）。这里特意**不做上游→ACR 名称转换**：若容器运行
的是 Docker Hub 引用，请先做镜像同步（加入 `docker-china-sync/images.txt`），用 ACR
引用重新部署容器后再登记。

**登记 / 管理**（两者都只编辑 `<数据目录>/state/update-targets` 这份托管列表，绝不写 `.env`）：

```sh
sudo sh scripts/gateway.sh update --enable <container> --yes
sh scripts/gateway.sh update --list-targets     # read-only, shows live eligibility
sh scripts/gateway.sh update --last             # read-only, last run's outcome
sudo sh scripts/gateway.sh update --disable <container> --yes
```

也可通过安装器的更新流程交互式管理（它会扫描运行中的 ACR 引用容器并逐个开关）。并发的
登记/移除调用会通过列表上的一个短锁串行化；当指定名称的容器不存在或已停止时，
`--enable` 会发出警告（否则一个拼错的名字会被登记却永远不会更新），并对疑似数据库的
镜像发出明确警告：重建没有静默机制。

两个彼此独立的排除层：

- **资格（发现阶段，警告并跳过）：** 网关三件套（由它们各自的路径更新）、compose 管理
  或标签不完整的容器（绝不手工重建）、匹配 `UPDATE_DENY_CONTAINERS` 通配的容器、
  已停止/不存在的容器，以及任何不在 `DOCKER_REGISTRY/ACR_NAMESPACE` 之下的镜像。这些
  会被记录并跳过；该次运行不受其他影响。注意 `REGISTRY_MODE=docker` 会让
  `DOCKER_REGISTRY`/`ACR_NAMESPACE` 保持未设置，从而完全禁用通用目标引擎（一条警告，
  零个合格目标）。
- **可重放性（应用阶段，fail-closed 式拒绝）：** `--rm`/`container:*` 模式的容器、
  静态 IPv6 地址、exec 形式的 healthcheck 覆盖、含内嵌换行的值，以及任何防降级守卫
  无法忠实复现的设置（`PublishAllPorts`/`-P`、`OomScoreAdj`、设备 cgroup 规则、
  userns 模式等——它会指出问题所在的设置）。被拒绝的容器**保持不变**，但会按
  `REFUSED (not replayable - container untouched)` 上报、计为失败，且该次运行以 `2`
  退出——一个已登记的 `--rm` 容器会让每次计划运行都报告部分失败，直到你将它取消登记。

**通用目标的更新方式**（严格串行，先于 cloudflared，网关对永远最后）：从 `docker
inspect` 捕获完整运行规格（挂载——匿名卷按名保留——端口、网络/别名、capabilities、
设备、资源限制、日志配置……），用新镜像原地重建，并须通过分层健康门：运行中 →
重启计数稳定、没有崩溃循环（一旦越过 `HEALTH_MAX_RESTARTS` 上限立即判失败——
`RestartCount` 只增不减，剩下的重试只会白白浪费）→ 镜像自带的 healthcheck（若有定义）
→ 可选的每目标探针。捕获是感知覆盖的：env/cmd/entrypoint——同标签和 healthcheck 一样
——只作为**相对旧镜像的覆盖**被重放，因此未经修改继承来的值交由新镜像决定；只有
*用户主动指定*的静态 IP（`IPAMConfig`）会被固定，动态分配的地址重放时仍为动态
（默认 bridge 网络的容器可以正常重放）；空的重启策略重放为 `no`。失败时自动用保存的
规格 + 旧镜像恢复（摘要中显示 `ROLLED BACK`；无法恢复的目标报告 `MANUAL ATTENTION`）。
成功后，验证过的镜像 ID 会持久化到 `<数据目录>/state/last-good/`（后续清理不影响它），
并在 `state/last-run.json` 记录本次运行——见[运行序列](#运行序列)。

**每目标探针**：`exec:<cmd>` 经由 `docker exec` 在容器内部运行；`log:<regex>` 在
**宿主机**侧对 `docker logs` 的输出做正则匹配（不会在容器的网络命名空间内运行任何
东西）——参见[配置 › 通用自动更新目标](configuration.md#通用自动更新目标)。`update --enable` 不接受
探针参数：要附加探针，请手工编辑 `<数据目录>/state/update-targets` 的第三个字段
（`name|strategy|probe`）。该列表在每次运行时都会重新做 fail-loud 校验；探针中的
shell 元字符、`|` 和换行符会被拒绝。

## 验收手册（更新器变更后必须执行）

真实容器行为**不在** CI 覆盖范围内（有意的决策：给 CI 运行器授予 docker socket 是家庭
实验室的安全决定——所有者以后可在 Woodpecker 管理界面将仓库标记为 trusted 并添加 dind
步骤来升级；在那之前，本手册是必需的人工验收门）。在 NAS 上：

1. **试运行冒烟** —— `sudo sh scripts/auto_update.sh --dry-run`：报告须准确列出三类
   目标的预期更新集，且不改变任何东西。
2. **金丝雀** —— 登记一个非关键容器，然后：

   ```sh
   sudo sh scripts/state_diff.sh snapshot <name> /tmp/canary-before
   sudo sh scripts/gateway.sh update --yes
   sudo sh scripts/state_diff.sh compare <name> /tmp/canary-before
   ```

   `state_diff.sh` 使用更新器自身的捕获引擎做快照，"状态保留"因此是机械化的相等断言
   （镜像/身份字段豁免）。出现任何 `DRIFT:` 行即验收失败——仅有一个狭窄例外：
   `labels`/`env`/`cmd`/`entrypoint`/`hc-test`/`hc-meta` 是相对各自镜像的覆盖差集，
   若新镜像恰好内置了逐字节相同的覆盖值，可能出现误报；将这些判为真实回归前请先用
   `docker inspect` 确认。另有两类 Docker 记账形式的变化已按设计归一化，永不判为漂移：
   绑定挂载与卷附着合并为同一份规范化集合比较（回放的匿名卷会合法地从 `Mounts` 迁移到
   `Binds`），且 `network_mode` 的 `default` 等同于 `bridge`。
3. **网关对** —— 按 [运维 › 手动健康检查](operations.md#手动健康检查) 验证。

## 退出码

| 退出码 | 含义 |
|---|---|
| `0` | 成功或干净的无操作 |
| `2` | 部分失败（某些操作失败；请查看通知/日志） |
| `3` | 配置 / 预检错误——未做任何更改 |
| `4` | 另一次运行持有锁 |
| `5` | ACR 登录失败——未尝试任何操作 |
| `130` / `143` | 被中断（Ctrl-C / TERM）——锁已释放，工作目录已清理 |

通过 `gateway.sh update` 驱动更新器时，还可能返回该封装脚本自己的 `6`（需要 root）和
`7`（变更型子命令缺少 `--yes`）——见[命令行参考](cli.md)。
DSM 任务计划程序可以在非零退出时发送邮件，作为第二道安全防线。

## 计划任务

参见[运维 › 在 DSM 上配置定时任务](operations.md#在-dsm-上配置定时任务)。`scripts/install_scheduler.sh`
会校验 `UPDATE_SCHEDULE`，并输出带绝对工作目录、明确 `/bin/sh`、正确 shell 引号且
没有重复日志重定向的命令。DSM 任务按 NAS 系统时区触发；`UPDATE_TZ` 只控制更新器内部的时间戳。

`sudo sh scripts/doctor.sh` 会校验部署情况：当（`UPDATE_ENABLED=true` 时）没有任何已启用的
计划任务运行 `auto_update.sh`，或缺少运行 `setup_network.sh` 的**开机**自愈任务时都会告警——
后者正是重启后 TUN 静默失效的根源。`doctor --json` 以 `update_task` / `boot_task`
检查项报告同样的结果。

创建任务后，先用一次**运行**，并检查
`../syno-mihomo-gateway-data/logs/auto-update.log` 处的日志——相对的 `UPDATE_LOG` 在
持久数据目录下解析，绝不会落在发布目录里；若 `gateway.sh` 在更新器首次运行之前运行过，
该文件是指向统一 `gateway.log` 的链接，否则是独立文件。dry-run 会拉取并检查镜像，
但绝不会切换容器：

```sh
sudo sh scripts/auto_update.sh --dry-run
```

## 树莓派 lite 模式二进制更新器

树莓派移植的裸机 **lite 模式**没有镜像可更新，因此配有一个姊妹更新器——
`scripts/pi/auto_update_lite.sh`——它更新的是**原生 mihomo 二进制**，同时完整继承本页的
运行契约：同样的锁、`UPDATE_ENABLED` 总开关、`--dry-run` / `--force`、轮转日志（数据
目录下的 `logs/auto-update.log`）、`NOTIFY_*` 通知，以及退出码 `0/2/3/4`。其最近一次
运行记录在 `state/lite/last-run.json`（与 `state/last-run.json` 相同的 JSON 结构），
旁边是已装版本标记 `state/lite/version`。

一次运行先解析发布版本号（固定的 `MIHOMO_VERSION` 优先；否则*经过* `GH_MIRROR` 跟随
`releases/latest` 跳转），已装版本一致时立即退出，然后：保留 `bin/mihomo.prev` →
下载 + 失败即关闭的校验阶梯（可选的固定 `MIHOMO_SHA256` → gzip 完整性 → 执行冒烟 →
版本一致）→ 替换 → `systemctl restart mihomo-gateway` → 健康门（服务活跃、重启次数
稳定、控制器探测、启用 TUN 时检查 TUN 链路——共用 `HEALTH_RETRIES` /
`HEALTH_INTERVAL` / `HEALTH_MAX_RESTARTS` 三个旋钮）。健康门失败会恢复 `.prev`
**连同版本状态**，因此下一次计划运行会干净地重试；连恢复都失败时上报
`MANUAL ATTENTION`，绝不谎报回滚成功。

计划任务由 `install-pi.sh` 菜单第 3 项设置——维护 `/etc/crontab` 中受管的一行（树莓派
上没有 DSM 任务计划）；compose 模式的树莓派安排的是上文的标准 `auto_update.sh`，
原样不动。完整流程与镜像/离线预放置见
[安装 — 树莓派](installation-pi.md#树莓派上的自动更新)。

## 上游行为参考

- [Synology DSM 7 任务计划程序](https://kb.synology.com/en-global/DSM/help/DSM/AdminCenter/system_taskscheduler?version=7)
- [Synology 任务脚本编写建议](https://kb.synology.com/en-global/DSM/tutorial/common_mistake_in_task_scheduler_script)
- [Docker image pull](https://docs.docker.com/reference/cli/docker/image/pull/)
- [Docker Compose up](https://docs.docker.com/reference/cli/docker/compose/up/)
