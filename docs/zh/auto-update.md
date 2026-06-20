# 自动更新

[← README](../../README.md) · [English](../auto-update.md)
手册：[架构](architecture.md) · [安装](installation.md) · [离线发布包](release-packaging.md) · [配置](configuration.md) · **自动更新** · [运维](operations.md) · [故障排查](troubleshooting.md) · [开发](development.md)

---

`scripts/auto_update.sh` 是[更新流水线](architecture.md)中位于 DSM 端的那一半：
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
`MIHOMO_IMAGE` / `METACUBEXD_IMAGE` / `CF_IMAGE` 指向这些 ACR 引用。

## 镜像引用

部署调度会将每个 `UPDATE_IMAGES` 条目与 `MIHOMO_IMAGE`、`METACUBEXD_IMAGE`、`CF_IMAGE`
进行**精确**匹配。请保持 `UPDATE_IMAGES` 继承这三个变量：

```dotenv
UPDATE_IMAGES="${MIHOMO_IMAGE} ${METACUBEXD_IMAGE} ${CF_IMAGE}"
```

如果某个 `UPDATE_IMAGES` 条目与这三者都不匹配，它将**被拉取但不会被部署**
（仅缓存），并且该次运行会记录一条 `WARN`。这是一个信号，说明你把 `UPDATE_IMAGES` 设置成了与
部署变量不同的引用。请让它们与 `docker-china-sync/images.txt` 保持一致。

## 运行序列

每次调用都会按顺序执行以下步骤（所有内容都会记录到 `UPDATE_LOG`）：

1. **加锁** — 一个原子的、可感知 PID 的 `mkdir` 锁。第二个并发运行会以
   `4` 的退出码干净地退出，并且*不会*触碰正在运行的那次运行的锁（只有持有者才能释放它）。
2. **终止开关校验** — `UPDATE_ENABLED=False` 之类的拼写错误会明确失败。
3. **终止开关** — 如果 `UPDATE_ENABLED=false`，则以 `0` 退出（除非使用 `--force`），
   此时不要求其他部署设置完整。
4. **配置校验** — 拒绝错误数字、通配符或不安全镜像引用、遗漏任一 Compose 服务，或在已配置
   `CF_IMAGE` 时没有将其加入 `UPDATE_IMAGES`。
5. **预检**（任何一步失败时中止，且不触碰任何内容）：
   - **Docker 就绪** — 最多等待 `DOCKER_READY_TIMEOUT`，直到 Container Manager、守护进程和 Compose 就绪；
   - **Compose 模型** — 拉取任何镜像前先校验 `docker-compose.yml` 与 `.env`；
   - **[架构守卫](#架构守卫)** — 镜像架构必须等于 `EXPECTED_ARCH`；
   - **网络** — `tproxy_network` 必须存在，且其 macvlan 父接口仍与实际接口匹配；
   - **TUN** — `/dev/net/tun` 必须存在；
   - **ACR 登录** — 非交互式 `--password-stdin`；遇到 `401` 时会发出通知并中止（退出码 `5`）。
6. **检测变更** — 对每个镜像执行 `docker pull`（带重试），要求该引用可在本地检查，
   再比较运行中容器与新镜像的内容寻址 ID。不同（或容器不存在）才需要部署。
7. **应用（Compose 服务）** — Compose v2 使用 `docker compose up -d --pull never`，
   保证采用刚刚拉取并校验过的本地镜像，避免校验后再次从仓库拉取。旧版 Compose v1
   使用缓存镜像行为并记录警告。
8. **健康门与回滚** — Compose 应用失败或健康门失败时，先确认旧镜像 ID 仍存在，再重新
   打标并在禁止隐式拉取的情况下重建，最后重新进行健康检查并发送失败通知。
9. **应用（cloudflared）** — [蓝绿部署](#cloudflared-蓝绿部署)，仅在其自身的拉取/校验之后进行。
10. **清理**悬空层（仅在完全成功时进行，因此回滚目标不会被提前删除）。
11. **通知** — Synology 推送（`synodsmnotify`）+ 日志，在失败*和*成功时都会发出。

### 架构守卫

`docker-china-sync` 默认镜像同步 `linux/amd64`。如果你的 NAS 是 ARM 架构，那么 amd64 的 `:latest`
是无法运行的。更新器会检查每个已拉取镜像的 `Architecture`，并在其不等于
`EXPECTED_ARCH` 时**拒绝部署**（绝不会为了一个无法运行的镜像而拆掉正在运行的容器）。
对于 ARM NAS：要么在 `docker-china-sync/images.txt` 中镜像同步 arm64 镜像
并设置 `EXPECTED_ARCH=arm64`，要么保留一台 amd64 的 NAS。

### 健康门与回滚（mihomo）

重建之后，"正在运行"还不够——mihomo 可能已经启动但没有路由任何流量。该健康门
（`HEALTH_RETRIES` × `HEALTH_INTERVAL`）会：

- 确认容器处于 `Running` 状态且**没有崩溃重启循环**（在该间隔内 `RestartCount` 稳定）；
- **在容器内部**（`docker exec`）探测控制器的 `GET /version`；配置密钥时会携带
  bearer token。缺少探测工具或响应失败都会使健康门失败；
- 检查容器内 `mihomo-tun` 网卡与 IPv4 转发，避免控制器正常但透明代理数据通路损坏；
- 当 `TUN_AUTO_REDIRECT=true` 时，先在一次性网络命名空间中验证目标镜像能否针对 DSM
  内核创建 iptables NAT 链；不兼容时跳过 Compose 应用；
- 检查 metacubexd 是否在运行（仅警告——UI 不是关键组件）。

如果健康门失败，更新器会校验并**重新打标到上一个正常的镜像**（在切换之前已捕获），
在禁止隐式拉取的情况下重建，重新运行健康门，并发出带有详细信息的 FAILURE 通知。
该次运行不会清理失败镜像。

> 从 NAS 进行更深入的出口/DNS 探测会受到 macvlan 自我访问的限制；请从
> 另一台 LAN 设备上执行这些探测。参见[运维 › 手动健康检查](operations.md)。

### cloudflared 蓝绿部署

cloudflared 是**外部的**（不在本 compose 中），通过容器名称进行管理：

1. 在私有临时目录中保存旧镜像 ID 及可重放的运行规格：环境变量/令牌、精确命令参数、入口点、
   重启策略、用户/工作目录、挂载、端口、网络/静态 IP、DNS、能力、设备、安全选项和 tmpfs。
   无法安全重放的容器网络或自动删除模式会在接触旧连接器前失败。
2. 与旧连接器并行启动 `<name>-candidate`，但临时候选不会占用旧容器已发布的主机端口或静态 IP，
   从而避免冲突；额外网络临时使用动态地址。
3. 通过原生健康状态或注册日志证明候选已连接。失败时只删除候选，规范容器保持不变。
4. 停止并删除旧容器，用 `CF_IMAGE` 和完整保存的端口/网络规格重建规范容器；候选在验证期间
   继续维持隧道。
5. 成功后删除候选。若失败，则用保存的旧镜像 ID/规格重建并验证回滚。若新旧规范容器都无法
   恢复，则保留仍连接的候选并报告手动恢复步骤，而不会误删唯一连接器。

首次配置（没有现有容器）需要 `CF_TUNNEL_TOKEN`；此后令牌
会从正在运行的容器中读取，你不需要在 `.env` 中配置它。

已发布的 metrics 端口只会在临时候选上省略，并会在规范替换容器上恢复。若镜像没有原生
healthcheck，连接检查会回退到 cloudflared 的注册日志。

## 退出码

| 退出码 | 含义 |
|---|---|
| `0` | 成功或干净的无操作 |
| `2` | 部分失败（某些操作失败；请查看通知/日志） |
| `3` | 配置 / 预检错误——未做任何更改 |
| `4` | 另一次运行持有锁 |
| `5` | ACR 登录失败——未尝试任何操作 |

DSM 任务计划程序可以在非零退出时发送邮件，作为第二道安全防线。

## 计划任务

参见[运维 › 在 DSM 上设置计划任务](operations.md)。`scripts/install_scheduler.sh`
会校验 `UPDATE_SCHEDULE`，并输出带绝对工作目录、明确 `/bin/sh`、正确 shell 引号且
没有重复日志重定向的命令。DSM 任务按 NAS 系统时区触发；`UPDATE_TZ` 只控制任务内日志时间。

创建后先在任务计划程序中点击**运行**，并检查 `logs/auto-update.log`。dry-run 会拉取并
检查镜像，但不会切换容器：

```sh
sudo sh scripts/auto_update.sh --dry-run
```

## 上游行为参考

- [Synology DSM 7 任务计划程序](https://kb.synology.com/en-global/DSM/help/DSM/AdminCenter/system_taskscheduler?version=7)
- [Synology 任务脚本编写建议](https://kb.synology.com/en-global/DSM/tutorial/common_mistake_in_task_scheduler_script)
- [Docker image pull](https://docs.docker.com/reference/cli/docker/image/pull/)
- [Docker Compose up](https://docs.docker.com/reference/cli/docker/compose/up/)
