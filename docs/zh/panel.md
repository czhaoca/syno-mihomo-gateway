# 网关面板

**网关面板**（`mihomo-panel`，compose 中的 `panel` 服务）是本栈的第三个
容器：一个小巧的 FastAPI 应用，掌管**分设备的动态策略**（把某台设备在
*full-tunnel*、*full-direct* 与默认路由之间切换，不用碰 `.env`，也不用
重启任何东西）以及**持久化的流量统计**。它把 SRC-IP 规则文件写进 mihomo
的配置卷，并经控制器 API 热重载它们——mihomo 本身从不会因为一次策略
变更而重启。

- Web 界面：`http://<PANEL_IP>:<PANEL_PORT>/ui/`（默认端口 8090），中英
  双语，仅同源访问。
- CLI：`gateway.sh policy --list` / `--set <ip> --mode full-tunnel|full-direct|default`
  （[CLI 参考](cli.md)）。
- HTTP API：[生成的参考](../panel-api.md)（仅英文）——只增不破的 `/v1` 契约。
- 体检：`companion_health`（面板停止或降级 ⇒ 告警）与 `policy_parity`
  （面板状态与 mihomo 规则出现漂移 ⇒ **错误，退出码 3**）。

## 策略变更如何生效

1. 一次修改（经界面、CLI 或 API 发起）到达面板，并按**失败即停**的方式
   校验（裸 IP 规范化为 `/32`，拒绝地址重叠，也拒绝目标为面板自身的
   地址）。
2. 期望状态被写入 SQLite（`policy.db`），随后渲染进
   `providers/dyn-full-direct.txt` / `dyn-full-tunnel.txt`（先写临时
   文件，再改名）。
3. 面板把对应的规则 provider PUT 给 mihomo 控制器，并重新读取规则条数
   进行核对（**count parity**）。响应中如实的 `applied` / `parity`
   字段会说明这次变更是否已经 LIVE 生效，而不仅仅是保存下来。
4. 应用失败时，面板会**失败即静态保持**：标记 `panel-apply-failed`
   被置位，webhook（若已配置）会触发，且 doctor 的 `policy_parity` 会
   持续报告漂移，直到某次应用真正收敛为止。

这些规则文件位于常规路由**之上**（就在局域网豁免规则
`GEOIP,LAN,DIRECT` 的下面），因此设备策略会压过 GEOSITE/GEOIP 路由，而
局域网目标则始终保持直连——一台 full-tunnel 设备仍然能够访问 NAS。

## 优先级与网段的关系

静态的 `.env` 网段（`FULL_PROXY_SOURCES`）仍然在部署时渲染；**动态条目
优先级更高**。界面上每一行设备都会显示其是否属于该网段，覆盖一个网段
地址前会要求确认（真正的日常翻转运维权威是面板，而不是 `.env`——网段
仍是那条声明式基线，即便面板被重置也留存不变）。

## 部署

面板随本栈一起部署——`install.sh`（全新安装时）会询问 `PANEL_IP`（网关
子网上的一个备用局域网地址，已做冲突检查），并**生成 `PANEL_SECRET`**
（32 位十六进制字符）；升级安装则以同样的方式迁移已有的 `.env`，并把
`PANEL_IMAGE` 并入 `UPDATE_IMAGES`。在这些开关就位之前，compose 会
**大声报错失败**（`${PANEL_IMAGE:?}` / `${PANEL_IP:?}`）。镜像在 `acr`
模式下来自你自己的 ACR（由镜像流水线持续镜像同步），在 `docker` 模式下
来自你自己提供的 `PANEL_UPSTREAM`——每一个 `PANEL_*` 开关见
[配置](configuration.md)。

最小权限：容器以 uid 10001 运行，只挂载 provider 写入面以及它自己的
`state/panel` 子目录——绝不挂载数据目录根，也绝不挂载 `state/` 本身
（自动更新器的元数据存放在那里）。安装器会在 `compose up` 之前，把这两个
挂载点都交给该 uid 所有。

## 数据、留存与备份

`state/panel/` 存放 `policy.db`（设备策略 + 审计日志）与 `stats.db`
（流量历史：分钟→小时→天分层汇总，带硬性大小上限，最旧的层级最先被
裁剪，采集器停摆期间会留下如实的空缺行）。每次策略变更都会把已提交的
`policy.db` 在旁边快照为一份滚动的 `policy.db.bak-<时间戳>`
（`PANEL_BACKUP_KEEP`，默认 5）；`stats.db` 是派生历史，没有自动备份。
留存开关（`PANEL_STATS_*`）记录在[配置](configuration.md)；备份/恢复/
重置/清除的运维手册见[运维](operations.md)。

## 安全

- **绝不要把面板暴露到公网**——不要让 cloudflared（或任何隧道/端口
  转发）指向 `PANEL_IP`。面板按局域网专用设计：**即使修改被锁定，读取
  在局域网内也始终开放**，所以暴露到公网会泄漏你的设备策略与流量历史，
  无论 `PANEL_SECRET` 多强都无济于事；而且 bearer 校验没有速率限制——
  对于修改操作，密钥的熵是唯一的抗暴力破解屏障。
- 修改操作始终要求 `Authorization: Bearer <PANEL_SECRET>`；空密钥会
  拒绝所有修改（失败即停），而不会因此放行。
- 记录在案的后续工作（v1 尚未包含）：一项自动化的 doctor 检查——用于
  发现面板意外暴露到公网——将需要一个独立的 Cloudflare API 凭据与
  授权范围，因为这里的 cloudflared 运行在令牌模式下，它的入站映射对
  任何本地文件都不可见。在它出现之前，本节的警告就是唯一的控制手段。

## 感觉不对时

[故障排查](troubleshooting.md)覆盖了具体场景：策略漂移
（`policy_parity` 退出码 3、那个标记文件）、每次修改都返回 403、
fail-static 的恢复路径，以及为什么一台 full-direct 设备仍可能出现
境外 DNS 的不对称现象。
