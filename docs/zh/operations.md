# 运维手册

[← README](../../README.md) · [English](../operations.md)
手册：[架构](architecture.md) · [安装](installation.md) · [离线发布包](release-packaging.md) · [配置](configuration.md) · [自动更新](auto-update.md) · **运维** · [故障排查](troubleshooting.md) · [开发](development.md)

---

第二天运维（Day-2 operations）。所有命令均通过 SSH 在 NAS 上、从仓库目录
`/volume1/docker/syno-mihomo-gateway` 中执行。

## 日常命令

```bash
# status / logs
docker compose ps
docker logs mihomo --tail 100
docker logs mihomo-ui --tail 50

# restart just mihomo (e.g. after editing the template)
docker compose up -d mihomo          # re-renders config.yaml on start

# stop / start the whole stack
docker compose down
docker compose up -d
```

> 请使用 `docker compose`（v2）。在较旧的环境中，可能只存在 v1 二进制文件 `docker-compose`；
> 自动更新器会自动检测两者中的任意一个，但在手动执行命令时请优先使用 v2。

## 更新订阅

```bash
vi ../syno-mihomo-gateway-data/config/subscription.txt
docker compose --env-file ../syno-mihomo-gateway-data/.env up -d mihomo
```

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
   发送运行详情”，或启用“设置 → 保存输出结果”。不要追加 `>> logs/auto-update.log`：
   更新器已经自行写入并轮转该日志；再次重定向会导致重复日志并破坏轮转。
2. **触发的任务 → 开机** —— 在重启后重新创建 macvlan + TUN（弥补
   “更新时网络缺失”的漏洞）：
   ```
   cd '/volume1/docker/syno-mihomo-gateway' && exec /bin/sh '/volume1/docker/syno-mihomo-gateway/scripts/setup_network.sh'
   ```
   开机辅助脚本会等待 Container Manager/Docker 就绪后再处理 macvlan。

DSM 按**控制面板 → 区域选项**中的 NAS 时区触发任务；`UPDATE_TZ` 只改变更新器的日志时间。
请安排在镜像同步窗口之后，然后选择任务并先点击一次**运行**。确认结果为零并检查
`logs/auto-update.log` 后，再依赖无人值守运行。

## 手动运行更新器

```bash
sh scripts/auto_update.sh --dry-run   # 拉取 + 检查 + 报告，不切换容器
sh scripts/auto_update.sh             # real run
sh scripts/auto_update.sh --force     # ignore UPDATE_ENABLED=false kill-switch
```

退出码：`0` 正常/无操作 · `2` 部分失败 · `3` 配置/预检 · `4` 已加锁 · `5` ACR
登录失败（参见 [自动更新 › 退出码](auto-update.md)）。

发布前或修改更新逻辑后，运行与 CI 相同的 DSM/BusyBox 回归测试：

```bash
sh scripts/ci/dsm_installer_check.sh
sh scripts/ci/auto_update_check.sh
sh scripts/ci/cloudflared_check.sh
docker compose --env-file .env.example config --quiet
```

## 终止开关（Kill-switch）

要在不删除任务的前提下暂停所有自动更新：

```dotenv
# .env
UPDATE_ENABLED=false
```

随后计划任务运行时会立即以 `0` 退出。将其设为 `true`（或使用 `--force` 运行一次）即可重新启用。

## 日志

- 编排器日志：`logs/auto-update.log`（路径 = `UPDATE_LOG`），在达到 `LOG_MAX_BYTES` 时自行轮转，
  保留 `LOG_KEEP` 份历史 —— 不依赖 `logrotate`。
- 容器日志：`docker logs mihomo` / `docker logs mihomo-ui` / `docker logs cloudflared`。

```bash
tail -f logs/auto-update.log
```

## 通知

运行结果通过 Synology `synodsmnotify @administrators` 推送（经由 Synology 的中继服务投递到
DS finder / 移动应用 —— 它**不会**经过 mihomo 网关路由，因此即便网关宕机时通知仍可送达）。
设置 `NOTIFY_WEBHOOK_URL` 可启用 Bark/Gotify/Slack 作为后备通道。通知会在**失败和回滚**时触发，
而不仅仅是在成功时；将 `NOTIFY_ON_NOCHANGE=1` 设置开启后，还能收到安静的“无变化”提示。

## 手动健康检查

由于 [macvlan 自访问问题](troubleshooting.md)，请从**另一台局域网设备**上运行以下命令，
而不要在 NAS 上运行：

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
docker compose up -d mihomo
```

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
然后执行 `docker compose up -d mihomo` 以重新渲染并重启。
参见 [配置](configuration.md)。
