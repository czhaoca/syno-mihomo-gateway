# 运维手册

[← README](../../README.md) · [English](../operations.md)
手册：[架构](architecture.md) · [安装](installation.md) · [离线发布包](release-packaging.md) · [配置](configuration.md) · [自动更新](auto-update.md) · **运维** · [CLI](cli.md) · [故障排查](troubleshooting.md) · [开发](development.md)

---

第二天运维（Day-2 operations）。所有命令均通过 SSH 在 NAS 上、从仓库目录
`/volume1/docker/syno-mihomo-gateway` 中执行。运行时状态（实际生效的 `.env`、渲染出的
配置、日志、更新器状态）位于同级数据目录 `../syno-mihomo-gateway-data` 中。

## CLI 一览

`scripts/gateway.sh` 是官方支持的日常运维命令入口（完整参考：[CLI](cli.md)）：

```bash
sudo sh scripts/gateway.sh status --json        # 只读：部署状态（含最近一次更新器运行）
sudo sh scripts/gateway.sh doctor --json        # 只读：诊断（封装 scripts/doctor.sh）
sudo sh scripts/gateway.sh update --dry-run     # 更新器试运行；真实运行用 `update --yes`
sudo sh scripts/gateway.sh cron --time 04:30 --yes   # 持久化自动更新计划
sudo sh scripts/gateway.sh redeploy --yes       # 从已保存的 .env 重新渲染 + 强制重建
```

写操作动词（`deploy`、`redeploy`、`modify`、`update`、`cron --apply-crontab`）要求 root
（否则退出码 `6`）以及显式的 `--yes`（否则退出码 `7`）；`status`/`doctor` 两者都不需要。
密钥绝不通过 argv 传入——请在 `.env` 中设置。

## 日常命令

```bash
# status / logs
docker compose --env-file ../syno-mihomo-gateway-data/.env ps
docker logs mihomo --tail 100
docker logs mihomo-ui --tail 50

# re-render + restart mihomo (e.g. after editing the template)
docker compose --env-file ../syno-mihomo-gateway-data/.env up -d --force-recreate mihomo

# stop / start the whole stack
docker compose --env-file ../syno-mihomo-gateway-data/.env down
docker compose --env-file ../syno-mihomo-gateway-data/.env up -d
```

> 请始终传入 `--env-file`：实际生效的 `.env` 位于 `../syno-mihomo-gateway-data/.env`，
> 缺少它时 compose 文件会安全失败（`set MIHOMO_IMAGE in .env`）。`--force-recreate` 同样
> 重要：配置渲染发生在容器入口点（entrypoint）中，只有重建容器时才会重新执行——镜像
> 未变时，单纯的 `up -d mihomo` 是一次空操作，模板/订阅的修改会被静默忽略。
> `sudo sh scripts/gateway.sh redeploy --yes` 可完成同样的事情，并附带校验和健康门。

> 请使用 `docker compose`（v2）。在较旧的环境中，可能只存在 v1 二进制文件 `docker-compose`；
> 自动更新器会自动检测两者中的任意一个，但在手动执行命令时请优先使用 v2。

## Container Manager：只看不动

容器会显示在 DSM 的 Container Manager（“容器”页签）中——在那里查看状态和日志没有问题。
绝不要对本栈使用“项目”页签的**构建/更新**：它会在没有摘要门、健康门和回滚的情况下重新
拉取并重建容器。所有更新都应经由 `scripts/auto_update.sh`（计划任务）或安装器/CLI 进行。

## 更新订阅

```bash
sudo sh scripts/gateway.sh modify --subscription 'https://provider.example/path' --yes
```

或手动修改（重新渲染需要 `--force-recreate`，见上文）：

```bash
vi ../syno-mihomo-gateway-data/config/subscription.txt
docker compose --env-file ../syno-mihomo-gateway-data/.env up -d --force-recreate mihomo
```

## 更新器变更后的验收

对自动更新机制的任何修改，都必须在 NAS 上通过
[验收手册](auto-update.md#验收手册更新器变更后必须执行)（试运行冒烟 → `state_diff.sh`
金丝雀 → 网关对检查）。这是**必需的**人工验收门：真实容器行为有意不在 CI 中覆盖。

## 在 DSM 上配置定时任务

在 DSM 7 上请使用**控制面板 → 任务计划程序**，不要直接编辑 `/etc/crontab`。
官方界面能保留任务、手动运行，并保存或邮件发送异常输出。打印经过校验的设置：

```bash
sh scripts/install_scheduler.sh
```

在 **控制面板 → 任务计划程序** 中创建两个任务（用户 = **root**）：

1. **计划的任务 → 用户定义的脚本** —— 自动更新器，在你设定的 `UPDATE_SCHEDULE` 时间运行：
   ```
   cd '/volume1/docker/syno-mihomo-gateway' && exec /bin/sh '/volume1/docker/syno-mihomo-gateway/scripts/auto_update.sh'
   ```
   实际路径请复制脚本打印的精确命令。选择 **root**、启用任务，并勾选“仅当脚本异常终止时
   发送运行详情”，或启用“设置 → 保存输出结果”。不要自行追加 `>> …` 日志重定向：
   更新器已经自行持有并轮转位于 `../syno-mihomo-gateway-data/logs/` 下的日志；再次重定向
   会导致重复日志并破坏轮转。
2. **触发的任务 → 开机** —— 在重启后重新创建 macvlan + TUN（弥补
   “更新时网络缺失”的漏洞）：
   ```
   cd '/volume1/docker/syno-mihomo-gateway' && exec /bin/sh '/volume1/docker/syno-mihomo-gateway/scripts/setup_network.sh'
   ```
   开机辅助脚本会等待 Container Manager/Docker 就绪后再处理 macvlan。

计划本身持久化在 `.env` 中——用 `sudo sh scripts/gateway.sh cron --time HH:MM --yes`
（`--time` 必须带冒号）或 `cron --schedule 'EXPR' --yes` 设置。作为任务计划程序的无界面
替代方案，`cron --apply-crontab --yes` 会写入（并在后续运行中重写）它自己的
`/etc/crontab` 条目——但 DSM 界面仍是推荐的方式。

DSM 按**控制面板 → 区域选项**中配置的时区触发任务；`UPDATE_TZ`（或 `cron --tz`）只改变
更新器的日志时间戳。请安排在镜像同步窗口之后充裕的时间，然后选择任务并先点击一次
**运行**。确认结果为零并检查 `../syno-mihomo-gateway-data/logs/auto-update.log` 后，
再依赖无人值守运行。

## 手动运行更新器

```bash
sudo sh scripts/auto_update.sh --dry-run   # 拉取 + 检查 + 报告，不切换容器
sudo sh scripts/auto_update.sh             # real run
sudo sh scripts/auto_update.sh --force     # ignore UPDATE_ENABLED=false kill-switch
```

CLI 等价命令：`sudo sh scripts/gateway.sh update --dry-run` / `update --yes` /
`update --force --yes`。

退出码：`0` 正常/无操作 · `2` 部分失败 · `3` 配置/预检 · `4` 已加锁 · `5` ACR
登录失败（参见 [自动更新 › 退出码](auto-update.md#退出码)）。Ctrl-C/TERM 会干净地终止
（`130`/`143`）。

退出码 `4` 表示另一次运行持有锁（`/tmp/syno-mihomo-update.lock`）。崩溃运行遗留的锁会
自愈：下一次运行会探测记录的 pid 并回收失效的锁（无 pid 的锁会先获得 2 秒宽限期）。
绝不要手动删除正在运行的实例的锁目录。

发布前或修改更新逻辑后，运行与 CI 相同的 DSM/BusyBox 回归测试：

```bash
sh scripts/ci/dsm_installer_check.sh
sh scripts/ci/lifecycle_check.sh
sh scripts/ci/auto_update_check.sh
sh scripts/ci/cloudflared_check.sh
sh scripts/ci/generic_update_check.sh
sh scripts/ci/gateway_cli_check.sh
docker compose --env-file .env.example config --quiet
```

CI 还会额外运行 Python 检查门——`scripts/ci/render_check.py`、
`cli_contract_check.py`、`compose_policy_check.py`、`package_check.py`、
`privacy_check.py`——以及 shellcheck（参见 `.woodpecker.yml`）。

## 终止开关（Kill-switch）

要在不删除任务的前提下暂停所有自动更新：

```bash
sudo sh scripts/gateway.sh cron --disable --yes   # 在实际生效的 .env 中写入 UPDATE_ENABLED=false
```

或直接编辑 `../syno-mihomo-gateway-data/.env`（仓库根目录的 `.env` 只作为一次性的历史
迁移来源，此后会被忽略）：

```dotenv
# ../syno-mihomo-gateway-data/.env
UPDATE_ENABLED=false
```

随后计划任务运行时会立即以 `0` 退出。用 `cron --enable --yes` 或将其设回 `true` 重新
启用（也可用 `--force` 运行一次）。取值是严格的：只接受精确的字符串 `true`/`false`——
像 `False` 这样的笔误会使运行以退出码 `3` 中止并发出通知，而不是静默停用。

## 日志

- 各工具日志：`../syno-mihomo-gateway-data/logs/`——安装器写入 `install.log`，更新器写入
  `auto-update.log`，每个 `gateway.sh` 动词写入 `gateway.log`（带 `verb=`/`run=` 审计
  字段）。若 `gateway.sh` 是最先运行的工具，它会把另外两个名字链接到 `gateway.log`，
  三者共享同一文件。达到 `LOG_MAX_BYTES` 时自行轮转，保留 `LOG_KEEP` 份历史——不依赖
  `logrotate`。（相对路径的 `UPDATE_LOG` 在数据目录下解析，而不是仓库目录。）
- 容器日志：`docker logs mihomo` / `docker logs mihomo-ui` / `docker logs cloudflared`。

```bash
tail -f ../syno-mihomo-gateway-data/logs/gateway.log
```

## 更新器状态文件

位于 `../syno-mihomo-gateway-data/state/` 下：

- `last-run.json` —— 最近一次更新器运行的结果，在每条终止路径上原子写入（被锁拒绝的
  运行除外）。字段：`ts`、`exit_code`、`dry_run`、`updated`、`unchanged`、`failed`、
  `rolled_back`，以及 `updated_names` / `failed_names` / `rolled_back_names`。用
  `sudo sh scripts/gateway.sh update --last` 读取（它也内嵌在 `status --json` 中）。
- `last-good/<name>` —— 每个通用目标验证过的 `image_id` + `spec_digest`，仅在健康门通过
  后写入；不受 `docker image prune` 影响，因此手动恢复时可以重新打标该镜像 ID。
- `update-targets` —— 通用目标登记列表（每行一条 `name|strategy|probe` 记录）；用
  `sudo sh scripts/gateway.sh update --list-targets` / `--enable NAME` / `--disable NAME`
  管理。参见[自动更新 › 通用目标](auto-update.md#通用目标任意已登记的容器)。

## 通知

**默认途径——DSM 任务计划邮件。**每个入口脚本都会在故障状态下以非零码退出，因此请在计划
任务上启用“仅在脚本异常终止时发送运行详情（邮件）”——DSM 会在真正需要关注时给你发邮件。
这是文档化的默认方式，除 DSM 自身的通知设置外无需任何配置。

**可选的富通知——Webhook。**在 `.env` 中设置 `NOTIFY_WEBHOOK_URL`（兼容 Bark/Gotify/Slack 的
JSON POST）。通知会在失败时**以及**有变化的成功时触发；设置 `NOTIFY_ON_NOCHANGE=1`
还能收到安静的“无变化”提示。URL（常内嵌令牌）通过 stdin 配置传给 curl，绝不经过 argv。

**尽力而为——DSM 推送。**DSM 7 上 `synodsmnotify` 需要套件注册的消息字符串，普通脚本调用
可能返回 0 却什么也没送达。脚本仍会尝试它（DSM 6 可用，且不经过网关），但绝不依赖它，
也绝不因此抑制 Webhook。

## 手动健康检查

首选专门构建的只读诊断——它通过 `docker exec` 从容器网络命名空间内部探测，
因此不受 macvlan 自访问限制的影响：

```bash
sudo sh scripts/doctor.sh                  # 退出码 0 健康 · 2 降级 · 3 损坏
sudo sh scripts/doctor.sh --egress         # 另外探测经代理的真实出口
sudo sh scripts/gateway.sh doctor --json   # 相同检查（compose、tun_gateway、controller、
                                           # image_arch、dashboard、update_task、boot_task、
                                           # subscription 等）汇总为一个 JSON 对象
```

其中 `update_task` / `boot_task` 检查校验 DSM 任务计划的部署情况（一个运行
`auto_update.sh` 的计划任务，以及一个运行 `setup_network.sh` 的开机任务——后者是让 TUN
在 NAS 重启后保持存活的关键）；`unknown` 表示该机器上没有可搜索的计划任务存储。

若要从局域网一侧验证，请在**另一台局域网设备**（而非 NAS）上运行以下原始探测命令
（原因见 [macvlan 自访问](troubleshooting.md#macvlan-自访问)）：

```bash
# controller reachable?
curl -s http://MIHOMO_IP:9090/version          # add: -H "Authorization: Bearer <secret>" if set
# egress actually proxies?
curl -s -x http://MIHOMO_IP:7890 -m 10 -o /dev/null -w '%{http_code}\n' http://www.gstatic.com/generate_204   # expect 204
# DNS served by mihomo?
dig @MIHOMO_IP gstatic.com +short
```

在 NAS 本机上，你仍然可以从容器内部检查控制器：

```bash
docker exec mihomo wget -qO- http://127.0.0.1:9090/version
```

## 手动回滚

更新器会在健康门控失败时自动回滚。若需手动还原（例如你在更新器之外拉取了一个有问题的镜像）：
固定到上一个镜像并重新创建容器。

```bash
docker images registry.cn-….aliyuncs.com/myns/mihomo      # find the previous IMAGE ID
docker tag <OLD_IMAGE_ID> "$MIHOMO_IMAGE"                  # re-point the tag
docker compose --env-file ../syno-mihomo-gateway-data/.env up -d --force-recreate mihomo
```

对于已登记的通用目标，验证过的镜像 ID 记录在
`../syno-mihomo-gateway-data/state/last-good/<name>` 中——按同样方式重新打标，然后重新
运行更新器（参见[自动更新 › 通用目标](auto-update.md#通用目标任意已登记的容器)）。

如果只有 `cloudflared-candidate` 在运行，请把它视为实时恢复连接器，不要删除。先检查日志，
再按原始运行设置重建规范容器，由候选维持隧道。紧急情况下可只重命名候选，但它仍会使用
临时动态 IP，且没有原来的主机端口绑定：

```bash
docker logs --tail 100 cloudflared-candidate
docker rename cloudflared-candidate cloudflared
```

## 磁盘清理

更新器会在成功运行后清理悬空（dangling）镜像层。若需手动回收更多空间：

```bash
docker image prune -f          # dangling only (safe)
```

请避免使用 `docker system prune -a` —— 它可能删除你在回滚时想要使用的最近可用镜像。

## 修改路由规则

编辑 `config/config.template.yaml` 中的 `rules:` 列表（以及 `proxy-providers`、端口等），
然后执行 `docker compose --env-file ../syno-mihomo-gateway-data/.env up -d --force-recreate mihomo`
（或 `sudo sh scripts/gateway.sh redeploy --yes`）以重新渲染并重启。
参见[配置](configuration.md#configconfigtemplateyaml)。
