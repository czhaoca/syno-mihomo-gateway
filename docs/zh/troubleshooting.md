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

## mihomo 无法启动 / 反复崩溃重启

```bash
docker logs mihomo --tail 80
```
常见原因：
- **订阅或 DNS 为空 / 损坏** —— 渲染器会明确报错：`ERROR: subscription.txt has no usable URL` 或 `ERROR: DNS_… must be set`。请修复 `config/subscription.txt` / `.env` 中的 `DNS_*` 键，然后执行 `docker compose up -d mihomo`。
- **缺少 `/dev/net/tun`** —— 运行 `sudo ./scripts/setup_network.sh`。
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

## 更新后 cloudflared 隧道掉线

蓝绿部署流程会在淘汰旧连接器之前先证明新连接器已连接成功，并在最终重命名失败时保留候选容器。如果你只看到 `cloudflared-candidate` 在运行：

```bash
docker ps -a | grep cloudflared
docker rename cloudflared-candidate cloudflared      # promote it
```

为获得最佳效果，请以 `--metrics 127.0.0.1:<port>` 启动 cloudflared（该设置会在更新间保留），这样连接检查就会精确判断，而不是靠抓取日志。

## 提示“no image changes”但我本来预期会更新

更新器会将**正在运行**的容器镜像与新拉取的标签进行比较，并且只会部署与 `MIHOMO_IMAGE`/`METACUBEXD_IMAGE`/`CF_IMAGE` 匹配的引用。如果你将 `UPDATE_IMAGES` 设置为与这三者不同的引用，它会被**仅缓存**拉取，你会看到一条 `WARN`。请将它们对齐（参见 [自动更新 › 镜像引用](auto-update.md)）。同时确认镜像同步确实推送了新的摘要（检查 `docker-china-sync` 的 GitHub Actions 运行记录）。

## CI 没有运行

流水线在分支 `main` **和** `master` 上触发。如果你使用其他分支名称，请将其加入 `.woodpecker.yml` 的 `when.branch`。

## 整个家庭断网

如果设备使用 `MIHOMO_IP` 作为网关 / DNS 而 mihomo 宕机，它们就会被切断连接。最快的恢复方法：将受影响设备的网关 / DNS 改回路由器，然后修复 mihomo（`docker compose up -d mihomo`，检查日志）。对于有风险的改动，请考虑使用 kill-switch（紧急切断）+ 维护窗口。
