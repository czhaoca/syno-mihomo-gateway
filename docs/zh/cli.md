# 命令行参考（gateway.sh）

<!-- 本页由 scripts/cli/spec.yaml 生成——请勿手工编辑。重新生成：python3 scripts/ci/cli_contract_check.py --write -->

Synology DSM 上 Mihomo 透明代理网关的非交互命令入口。其他程序（DSM 任务计划、脚本、CI）可直接调用这些子命令；交互式安装器（sh ./install.sh 或对应平台入口 install-linux.sh / install-pi.sh）是基于同一套函数的向导前端。

## 调用方式

```sh
sh ./scripts/gateway.sh <verb> [options]
```

## 安全护栏

- 变更类子命令（deploy、redeploy、modify、update、cron --apply-crontab） 必须显式传入 --yes；否则以退出码 7 结束且不做任何更改。
- 变更类子命令需要 root 权限（否则退出码 6）；status 与 doctor 不需要。
- --dry-run 绝不更改网关或任何容器，也不需要 --yes 或 root（update --dry-run 仍会把镜像拉取到本地缓存——这正是它的用途）。
- 每个子命令都接受 --help/-h 查看其帮助；-y 是 --yes 的短别名。
- 命令行绝不接受机密参数（argv 在 ps 中可见）——请写入 .env。
- --json（仅 status 与 doctor）在标准输出只打印一个 JSON 对象； 所有日志写入日志文件与标准错误。

## 退出码

| 退出码 | 含义 |
|---|---|
| 0 | 成功或无事可做 |
| 2 | 部分组件失败，其余已应用 |
| 3 | 配置或预检错误——未做任何更改 |
| 4 | 另一个运行实例持有锁 |
| 5 | 镜像仓库登录失败——未执行任何操作 |
| 6 | 该子命令需要 root——未做任何更改 |
| 7 | 变更类子命令缺少显式 --yes 被拒绝——未做任何更改 |

## 子命令

### `deploy`

依据已保存的 .env 端到端部署网关（缺少镜像引用时自动推导）。

| 选项 | 说明 |
|---|---|
| `--cleanup-containers preserve|auto` | 部署前如何处理已存在的网关容器（默认 preserve） |
| `--cleanup-network preserve|auto` | 部署前如何处理已存在的 tproxy 网络（默认 preserve） |
| `--interface IFACE` | macvlan 的 LAN 父接口（会持久化到 .env） |
| `--yes` | 确认执行变更（真正部署时必须） |
| `--dry-run` | 打印部署计划后退出，不做任何更改 |

流程：校验配置 -> 预检 -> 规划清理 -> 拉取并校验镜像 -> 执行清理 -> 网络 -> compose 启动 + 健康门（失败时自动回滚到最近可用镜像）。


### `redeploy`

严格依据完整的已保存 .env 重新部署（绝不推导或询问）。

| 选项 | 说明 |
|---|---|
| `--cleanup-containers preserve|auto` | 同 deploy |
| `--cleanup-network preserve|auto` | 同 deploy |
| `--interface IFACE` | 同 deploy |
| `--yes` | 确认执行变更 |
| `--dry-run` | 打印计划后退出，不做任何更改 |


### `modify`

修改一项配置，然后重新执行完整的失败即停流水线。

| 选项 | 说明 |
|---|---|
| `--network` | 依据已保存的设置重建网络（TUN 设备 + macvlan） |
| `--images` | 重新推导镜像引用并以其重新部署 |
| `--mihomo-tag TAG` | 与 --images 连用，固定 mihomo 标签（持久化到 .env） |
| `--metacubexd-tag TAG` | 与 --images 连用，固定 metacubexd 标签（持久化到 .env） |
| `--subscription URL` | 替换已存储的订阅 URL（先清洗并校验） |
| `--cleanup-containers preserve|auto` | 同 deploy |
| `--cleanup-network preserve|auto` | 同 deploy |
| `--yes` | 确认执行变更 |
| `--dry-run` | 校验变更并打印计划，但不执行 |


### `cron`

持久化自动更新计划；可选写入 crontab 条目。

| 选项 | 说明 |
|---|---|
| `--time HH:MM` | 每日更新时间（24 小时制；转换为五段 cron 表达式） |
| `--schedule 'M H * * *'` | 完整的五段 cron 表达式（会校验） |
| `--tz ZONE` | 设置 UPDATE_TZ——仅用于更新器日志时间戳；DSM 任务计划与 crontab 按 NAS 系统时区（控制面板 > 区域选项）触发 |
| `--enable` | 设置 UPDATE_ENABLED=true |
| `--disable` | 设置 UPDATE_ENABLED=false |
| `--apply-crontab` | 将条目追加到系统 crontab（属变更操作——需要 --yes 与 root） |

不带 --apply-crontab 时仅写入 .env 并打印用于 DSM 任务计划的命令 （推荐的 DSM 原生方式）。

需要已存在的 .env（先部署）。--time 与 --schedule 同时给出时以 --time 为准。--apply-crontab 管理自己的条目：计划变更会替换旧的 auto_update.sh 行。


### `status`

只读的部署状态（栈、容器、网络、面板地址）。

| 选项 | 说明 |
|---|---|
| `--json` | 在标准输出打印一个机器可读的 JSON 对象 |

当 docker/compose 不可用或 .env 损坏时以退出码 2（ok:false）结束—— JSON 对象仍会输出；否则为 0。


### `doctor`

只读诊断（退出码 0 健康 / 2 降级 / 3 故障）。人读模式运行 scripts/doctor.sh；--json 以同一套检查原生输出。

| 选项 | 说明 |
|---|---|
| `--json` | 在标准输出打印一个机器可读的 JSON 对象（--egress 仅人读模式生效） |
| `--egress` | 另通过控制器 API 探测真实的代理出口 |


### `update`

运行无人值守更新器（转交 scripts/auto_update.sh；参数原样透传），或管理其通用更新目标。

| 选项 | 说明 |
|---|---|
| `--yes` | 确认执行变更（不透传） |
| `--dry-run` | 拉取、检测并报告，但不替换任何组件（透传） |
| `--force` | 忽略 UPDATE_ENABLED=false 开关（透传） |
| `--list-targets` | 只读，无需 --yes/root；列出已登记的通用更新目标及其可用性 |
| `--last` | 只读，无需 --yes/root；显示最近一次更新运行的结果 |
| `--enable NAME` | 将容器登记为通用自动更新目标（仅写入管理列表；当 NAME 未运行或尚不 存在时会警告，镜像疑似数据库时也会警告——原地重建没有静默期） |
| `--disable NAME` | 将一个容器从通用自动更新中移除（仅写入管理列表） |

--list-targets/--last/--enable/--disable 在本地处理并拒绝其他任何 选项；--dry-run 不能与其组合（否则会绕过保护管理列表的 --yes/root 门槛）。

## 机器可读输出（--json）

status --json 输出一个扁平对象： {"verb","ok","exit_code","stack_state","mihomo_ip","dashboard_url", "checks":[{"name","value"},...],"last_update":{...}|null} （last_update 与 state/last-run.json 一致；首次运行前为 null）。 其检查名为 env、docker、mihomo_container、ui_container、network、 subscription、tun_enable。last-run.json 携带 {"ts","exit_code","dry_run","updated","unchanged","failed", "rolled_back","updated_names","failed_names","rolled_back_names"}。 doctor --json 输出 {"verb","ok","exit_code","checks":[...]}，检查名为 env、docker、arch、tun_device、network、compose、mihomo、tun_gateway、 controller、image_arch、proxy_groups、dashboard、update_task、boot_task、 cloudflared、 subscription、host_dns、geodata、dns_privacy、config_rejected、 ipv6_bypass、full_proxy（update_task/boot_task 校验 DSM 任务计划的部署情况；proxy_groups 针对生成的“<国家> Auto” url-test 分组， 取值 ok|default-empty|country-empty|provider-empty —— default-empty 表示 Country Pick 当前选中的国家分组匹配不到任何节点（默认线路流量被 REJECT，失败关闭）， country-empty 表示其他 COUNTRY_GROUPS 条目匹配不到节点， provider-empty 表示所有 url-test 分组皆空（机场节点未就绪——先做 种子恢复，不是过滤器的问题）；cloudflared 对可选的隧道容器报告 ok|down|absent；host_dns 逐一探测主机解析器；geodata 为 cached|missing；dns_privacy 反映渲染出的 DNS 配置档，取值 v2|v1|legacy —— v2 = 分域（境外优先）隐私模式，v1 = v1.3.10 之前的 渲染残留（fallback 双查询仍会把长尾查询抄送国内解析器），legacy = 国内解析器可见全部查询；config_rejected 取值 ok|render-failed|config-test-failed|rejected —— 非 ok 表示入口点守门 拒绝了最近一次渲染的配置（存在 .config.yaml.rejected 标记），mihomo 正运行上一份配置，最近的 .env/订阅修改并未生效（'rejected' = 标记存在但 reason 行不可读）；渲染通过并重新部署后自动清除； ipv6_bypass 取值 ok|exposed —— exposed 表示 LAN 接口上存在可路由互联网的全局 IPv6（私有 ULA 不算）， 双栈客户端会经 IPv6 绕过纯 IPv4 网关；full_proxy 针对整机代理网段（FULL_PROXY_SOURCES），取值 disabled|ok|parity-drift|chain-violation —— disabled 表示未启用网段， parity-drift 表示渲染出的 SRC-IP-CIDR 规则与 .env 不一致（网段修改 未生效——请重新部署），chain-violation 表示网段设备的非局域网流量 绕过了 Full Proxy 分组（通常是已在文档说明的 UDP/QUIC 穿透：出口 节点不支持 UDP 中继；该保证同样要求局域网没有可路由 IPv6——参见 ipv6_bypass）；"unknown" 表示此机器上该项不可探测）。 标准输出只有这一个对象，日志绝不混入。

日志：gateway.sh 写入 <data-dir>/logs/gateway.log（每行携带 verb= 与 run= 字段）。直接运行 auto_update.sh 写入 auto-update.log——若 gateway.sh 先运行过，它是指向 gateway.log 的链接，否则是独立文件，且不带这两个字段。
