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
2. **终止开关** — 如果 `UPDATE_ENABLED=false`，则以 `0` 退出（除非使用 `--force`）。
3. **预检**（任何一步失败时中止，且不触碰任何内容）：
   - **compose 风味** — 优先使用 `docker compose`（v2），回退到 `docker-compose`（v1）；
   - **[架构守卫](#架构守卫)** — 镜像架构必须等于 `EXPECTED_ARCH`；
   - **网络** — `tproxy_network` 必须存在，且其 macvlan 父接口仍与实际接口匹配；
   - **TUN** — `/dev/net/tun` 必须存在；
   - **ACR 登录** — 非交互式 `--password-stdin`；遇到 `401` 时会发出通知并中止（退出码 `5`）。
4. **检测变更** — 对每个镜像执行 `docker pull`（带重试），然后将**正在运行的
   容器的**镜像 ID 与刚刚拉取的本地镜像 ID 进行比较。两者不同（或容器
   不存在）⇒ 需要部署。这对 `--dry-run` 是健壮的，并且幂等：无变化 ⇒ 无操作。
5. **应用（compose 服务）** — 单次 `docker compose up -d` 只会重建发生了变化的 mihomo /
   metacubexd（先拉取后切换；绝不会先停后拉）。
6. **健康门** — 见下文。失败时 ⇒ **自动回滚**到上一个正常的镜像，重新进行健康检查，
   并发出 FAILURE 通知。
7. **应用（cloudflared）** — [蓝绿部署](#cloudflared-蓝绿部署)，仅在其自身的拉取/校验之后进行。
8. **清理**悬空层（仅在完全成功时进行，因此回滚目标绝不会在运行中途被删除）。
9. **通知** — Synology 推送（`synodsmnotify`）+ 日志，在失败*和*成功时都会发出。

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
- **在容器内部**（`docker exec`）探测控制器的 `GET /version`，这样可以
  绕过 [macvlan 自我访问](troubleshooting.md)限制。如果该
  镜像没有 `wget`/`curl`，则降级为稳定性检查（会记录日志，但不算失败）；
- 检查 metacubexd 是否在运行（仅警告——UI 不是关键组件）。

如果健康门失败，更新器会**重新打标到上一个正常的镜像**（在切换之前已捕获）并
再次执行 `docker compose up -d`，重新运行健康门，并发出带有详细信息的 FAILURE 通知。新
镜像会被保留（不被清理），以便回滚目标依然存在。

> 从 NAS 进行更深入的出口/DNS 探测会受到 macvlan 自我访问的限制；请从
> 另一台 LAN 设备上执行这些探测。参见[运维 › 手动健康检查](operations.md)。

### cloudflared 蓝绿部署

cloudflared 是**外部的**（不在本 compose 中），通过容器名称进行管理：

1. 通过 `docker inspect` **克隆**正在运行的容器的完整运行规格——所有环境变量（因此通过
   `TUNNEL_TOKEN` 传入的令牌以及 `TUNNEL_METRICS` 等设置都会被保留）、已发布的端口、绑定
   挂载、主网络 + 静态 IP、额外的网络、重启策略以及原始
   命令。只有**镜像**会被升级为 `CF_IMAGE`。`CF_TUNNEL_TOKEN`（如果已设置）会覆盖它。
2. 将其以 `<name>-candidate` 的名称与旧容器**并排**启动。Cloudflare 允许每条隧道
   有多个连接器，因此实时隧道永远不会中断。
3. 在切换之前**证明已连接**——如果存在原生 healthcheck 则使用它，否则在 `CF_HEALTH_TIMEOUT`
   内查找 "Registered tunnel connection" 日志标记。如果它始终未能连接，候选容器
   会被移除，旧容器则保持**原样不动**（不进行切换）。
4. **切换** — 停止 + 移除旧容器，然后将候选容器 `docker rename` → 规范名称（带重试）。如果
   重命名持续失败，候选容器（唯一的实时连接器）会**被保留**，并且该次运行会提示
   你手动执行 `docker rename`——清理 trap 不会回收它。

首次配置（没有现有容器）需要 `CF_TUNNEL_TOKEN`；此后令牌
会从正在运行的容器中读取，你不需要在 `.env` 中配置它。

> **前提条件：** 启动你的外部 cloudflared 时请带上 `--metrics 127.0.0.1:<port>`，以便
> 连接检查更精确（否则会回退到日志抓取）。由于更新器现在会
> 重放完整的运行规格，因此该 `--metrics` 设置会在更新之间被保留下来。

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
会打印出准确的任务命令以及一行根据 `UPDATE_SCHEDULE` / `UPDATE_TZ` 推导出的回退 crontab 行。
请将其安排在每晚镜像同步（23:00 UTC）**之后**留出充足时间运行；幂等的摘要
检测意味着精确的时间点并不关键。
