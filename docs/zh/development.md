# 开发与内部实现

[← README](../../README.md) · [English](../development.md)
手册：[架构](architecture.md) · [安装](installation.md) · [离线发布包](release-packaging.md) · [配置](configuration.md) · [自动更新](auto-update.md) · [运维](operations.md) · [CLI](cli.md) · [故障排查](troubleshooting.md) · **开发**

---

面向贡献者以及任何希望扩展本网关的人员。

## 仓库结构

```
docker-compose.yml            # mihomo（macvlan，特权）+ metacubexd（bridge）
.env.example                  # 有文档说明的配置契约（实际 .env：../syno-mihomo-gateway-data/.env）
VERSION                       # 发布版本（打进 package.sh 产物文件名）
bootstrap.sh                  # 离线安装首次运行辅助脚本（生成 .env、恢复执行位）
install.sh                    # 交互式安装器（菜单：Deploy/Redeploy/Cron/Modify/Status）
config/
  config.template.yaml        # 带 {{PLACEHOLDERS}} 的 mihomo 配置
  subscription.txt.example    # 订阅模板（实际副本：../syno-mihomo-gateway-data/config/）
scripts/
  gateway.sh                  # 非交互 CLI：deploy/redeploy/modify/cron/status/doctor/update
  setup_network.sh            # 无人值守开机自愈：/dev/net/tun + tproxy_network macvlan
  render_config.sh            # 从模板渲染 config.yaml（入口点与 CI 都调用它）
  auto_update.sh              # DSM 自动更新编排器（入口）
  doctor.sh                   # 只读诊断（也支撑 `gateway.sh doctor`）
  state_diff.sh               # 在更新前后快照/比对容器的可重放规格
  install_scheduler.sh        # 打印 DSM 任务计划 / crontab 设置
  package.sh                  # 构建主机：构建离线发布压缩包（docs/release-packaging.md）
  cli/
    spec.yaml                 # CLI 契约的唯一可信来源（见下文“CLI 契约”）
  installer/                  # 由 install.sh 加载的 TTY 模块
    ui.sh / i18n.sh           # 提示与菜单原语；EN/中文字符串（INSTALLER_LANG）
    preflight.sh / netscan.sh # docker 共享目录位置门槛；网卡扫描 + IP 建议
    wizards.sh / envedit.sh   # 逐项提示；dotenv 安全的 .env 编辑
    preprocess.sh             # 分资源清理菜单；决策策略位于 lib/resolve.sh
    flow_*.sh                 # 菜单项流程：deploy、redeploy、modify、cron、targets
  lib/
    common.sh                 # env 加载、日志+轮转、mkdir 锁、退出码
    registry.sh               # 预检（compose/架构/网络/tun）、ACR 登录、拉取+变更检测、TUN 重定向探测
    compose.sh                # compose 启动、健康门控、回滚
    container.sh              # 通用容器规格捕获/重放引擎 + 一致性守卫
    targets.sh                # 通用目标登记 + DEC-1 资格判定（state/update-targets）
    cloudflared.sh            # 外部 cloudflared 的蓝绿重建
    lifecycle.sh              # 部署盘点 + 已验证的定向拆除
    network.sh                # macvlan/IP 规划：网卡检测/扫描、IP 占用探测、OVS 警告
    notify.sh                 # 通知：webhook + 尽力而为的 Synology DSM 推送
    resolve.sh                # 无 UI 的配置解析：IP 建议、镜像引用、订阅 URL、清理计划策略
    scheduler.sh              # 安全解析 DSM/BusyBox cron 并生成任务命令
    help.sh                   # 由 cli/spec.yaml 生成——绝不手工编辑
  ci/
    render_check.py           # CI：运行真实渲染器 + 结构/规则断言
    cli_contract_check.py     # CI：spec.yaml 与已提交产物逐字节比对（--write 重新生成）
    compose_policy_check.py   # CI：fail-closed 镜像引用 + REGISTRY_MODE=acr 默认值
    package_check.py          # CI：在临时仓库中构建两种发布包，证明不打包任何密钥
    privacy_check.py          # 被跟踪内容/历史隐私守卫（+ privacy_check_test.py）
    auto_update_check.sh      # 使用伪 Docker 的计划/更新/回滚 TDD 测试
    cloudflared_check.sh      # 使用伪 Docker 的蓝绿行为 TDD 测试
    generic_update_check.sh   # 使用伪 Docker 的通用捕获/重放引擎测试
    gateway_cli_check.sh      # 通过 PATH 桩测试 gateway.sh CLI 契约
    dsm_installer_check.sh    # 使用伪 Docker 的安装器流程测试
    migrate_legacy_check.sh   # 旧版扁平安装导入器的封闭式（env -i）测试
    lifecycle_check.sh        # 使用伪 Docker 的盘点/清理安全测试
    lib/assert.sh             # sh 测试套件共享的断言
.woodpecker.yml               # CI：9 个阻断式步骤（见下方 CI 表格）
docs/                         # 手册（EN）+ docs/zh 中文镜像 + docs/*.txt 最终用户指南
```

`install.sh` 是交互式 TTY 前端（也是最终用户包的入口，`sh ./install.sh`）；
`scripts/gateway.sh` 是 [CLI](cli.md) 中记录的非交互动词命令面。
两者驱动同一套 `scripts/lib/` 函数。

## 编码规约

- **POSIX `/bin/sh`，BusyBox 兼容。** DSM 自带 BusyBox；不使用 bashism 或关联数组，
  `scripts/setup_network.sh` 和无人值守任务入口也遵循此规则。
- **编排器中不使用 `set -e`/`set -u`。** 它显式检查返回码，从而避免某个软失败意外地拆毁整个网关。
  `render_config.sh` *确实*使用了 `set -eu`（它是一个简短的、快速失败的渲染器）。
- **提交的文件中不硬编码 DNS / 网络地址**（项目规则）。请使用
  `{{PLACEHOLDERS}}` + `.env`。CI 会强制执行这一点（`render_check.py`）。
- **机密信息只放在被 gitignore 的 `.env` 中**（`ACR_PASSWORD`、`CF_TUNNEL_TOKEN`、`CONTROLLER_SECRET`）。
- **镜像引用 fail-closed，绝不硬编码。** compose 中每个 `image:` 都必须严格是
  `${VAR}` / `${VAR:?msg}` —— 不允许 `:-`/`:=` 默认值，不允许字面引用。镜像来源由
  `REGISTRY_MODE` 选择（默认 `acr`，`docker` 上游为显式可选项）；CI 的 `compose-policy`
  步骤对两者都强制执行。
- **拒绝私有运维数据。** `privacy_check.py` 会扫描被跟踪内容和可达 blob，同时允许公共项目链接
  与深圳 ACR 示例。
- **Shell 脚本中只使用 ASCII** —— 非 ASCII 字符（例如长破折号）会破坏 CI 镜像中 shellcheck 的输出编码。

## 渲染器（`render_config.sh`）

将模板转换为 `config.yaml` 的唯一可信来源，由 mihomo 入口点（通过 `./scripts:/scripts:ro` 挂载执行
`sh /scripts/render_config.sh && exec /mihomo`）和 CI **两者**共同调用。它遵循
`MIHOMO_CONFIG_DIR`（默认 `/root/.config/mihomo`），以便测试可以将其指向临时目录。关键的正确性要点：

- **订阅解析：** 去除可选的开头 `label=` 和结尾空白，同时*保留* URL 内部的 `=` ——
  `sed -e 's/^[A-Za-z0-9_.-]*=//' -e 's/[[:space:]]*$//'`。
  （裸 URL 没有 `name=` 前缀，因为 `https` 后面跟的是 `:`，而不是 `=`。）
- **`sed` 转义：** 一个 `esc()` 辅助函数会在注入前对每个被替换值中的 `&`、`|`、`\` 进行转义
  （否则 URL 中的 `&` 会被解读为“匹配到的文本”并破坏输出）。
- **大声失败：** 空的订阅 URL 或任何空的 `DNS_*` ⇒ 以非零状态退出，且不生成输出文件。

## 编排器运行序列

`auto_update.sh` 加载这些库并依次运行：**加锁 → 校验终止开关 → 终止开关 → 校验配置 →
等待 Docker 并执行预检 → 拉取/检查/检测变更（compose 网关对、cloudflared、已登记的通用目标）→
dry-run 短路 → TUN 自动重定向探测（仅真实运行；可以否决 compose 应用）→ 按爆炸半径从小到大
严格串行应用（DEC-5）：通用目标 → cloudflared 蓝绿 → compose 网关对最后（每个阶段都带
健康门控/回滚）→ 清理 → 通知**。每条终止路径都会经由 EXIT 陷阱写入 `state/last-run.json`
（`ts`/`exit_code`/`dry_run`/计数器 + `*_names` 列表）；INT/TERM 会干净地终止（退出码
130/143）。dry-run 保持只读——它只会*记录*该探测将会门控真实应用。完整细节见
[自动更新](auto-update.md#运行序列)。关键库函数：

| 文件 | 函数 |
|---|---|
| `lib/common.sh` | `load_env`、`log*`、`rotate_log`、`acquire_lock`/`release_lock`（由 `LOCK_HELD` 守护）、`EXIT_*` 退出码 |
| `lib/registry.sh` | `validate_update_switch`/`validate_update_config`、`wait_for_docker_ready`、`check_arch_expectation`/`arch_ok`、`check_network`、`check_tun`、`acr_login`、`pull_image`、`deploy_needed`、`mihomo_auto_redirect_probe` |
| `lib/compose.sh` | `compose_config_check`、`compose_up_local`、`health_gate`（含 `mihomo_controller_probe`）、`rollback_compose` |
| `lib/container.sh` | `container_capture_spec`、`container_run_saved`、`container_restore_old`、`container_parity_guard`（对无法重放的设置 fail-closed）、工作目录管理 |
| `lib/targets.sh` | `targets_validate`、`target_enroll`/`target_remove`（通过自有锁串行化）、`targets_discover`（DEC-1 资格过滤器）、`targets_image_databaselike` |
| `lib/cloudflared.sh` | `cloudflared_blue_green`、`cloudflared_wait_connected`、安全规格捕获/重放、回滚、候选/临时目录清理 |
| `lib/lifecycle.sh` | `lifecycle_inspect`、已验证的容器/网络移除、手动命令输出 |
| `lib/network.sh` | `ensure_tun_device`、`detect_parent_interface`/`scan_interfaces`、`ip_in_use`、`validate_network_plan`、`recreate_macvlan`、`iface_is_ovs`/`warn_if_ovs_parent`（由 `setup_network.sh` 与安装器共用） |
| `lib/notify.sh` | `notify` —— 相互独立的通道：可选 webhook（配置经 curl stdin 传入，绝不走 argv）+ 尽力而为的 `synodsmnotify` |
| `lib/resolve.sh` | `resolve_mihomo_ip`、`resolve_images`/`resolve_update_images`、`resolve_subscription_url`/`subscription_current`、`resolve_cleanup_plan`（无 UI；向导负责呈现结果） |
| `lib/scheduler.sh` | `cron_normalize`、`scheduler_update_command`、`scheduler_network_command`、`scheduler_reload_crond` |

并发：只有持锁者才会释放锁（`LOCK_HELD`）；只有在 `kill -0` 证明锁中记录的 pid 已死亡后，
陈旧锁才会被回收（无 pid 的锁有 2 秒宽限期）；当 cloudflared 候选可能是唯一已连接隧道时，
EXIT 陷阱不会回收它（`CF_KEEP_CANDIDATE`）。

## CI（`.woodpecker.yml`）

在向 `main` 和 `master` 推送/发起 PR 时运行：

| 步骤 | 内容 |
|---|---|
| `validate-compose` | Compose **v2**（`apk add docker-cli-compose`，然后 `docker compose --env-file .env.example config --quiet`）—— 冻结的 v1 `docker/compose` 镜像无法解析 fail-closed 的 `${VAR:?}` 镜像引用 |
| `validate-yaml` | `yaml.safe_load(docker-compose.yml)` |
| `render-config` | `python scripts/ci/render_check.py` —— 针对一个带 `Name=` 前缀及 `&` 参数的夹具 URL 运行**真实的**渲染器，并断言该 URL 能精确地往返还原；同时强制执行“不硬编码 DNS”规则 |
| `cli-contract` | `python scripts/ci/cli_contract_check.py` —— 将已提交的 `help.sh`/`cli.md`（中英）/`CLI.txt`（中英）与从 `scripts/cli/spec.yaml` 全新重新生成的版本逐字节比对，并断言 spec 的退出码与 `common.sh` 一致、其动词集合与 `gateway.sh` 的分发一致、且 `gateway.sh --help` 逐字输出 spec 文本 |
| `compose-policy` | `python scripts/ci/compose_policy_check.py` —— 断言 **fail-closed** 的镜像引用：compose 中每个 `image:` 都严格是 `${VAR}`/`${VAR:?msg}`（无默认值、无硬编码引用），且 `.env.example` 定义了这些镜像变量并携带 `REGISTRY_MODE=acr`（ACR 为默认；`docker` 上游是显式可选项，并非被禁止） |
| `package-check` | `python scripts/ci/package_check.py` —— 在临时仓库中构建开发与最终用户**两种**发布包，证明**任何密钥都不会被打包**（植入的 `.env`/订阅/`config.yaml` 不出现在两种压缩包的文件名*和*字节中）、校验和正确、最终用户包剔除了开发者/`.md`/CI 文件、附带安装器与 `.txt` 指南、不含任何身份字符串，且其防泄漏门对注入的泄漏会以失败告终（fail-closed） |
| `privacy-check` | 扫描被跟踪文件和可达 blob，拒绝私有运维标识、凭据、私钥和意外跟踪的运行时文件（+ 该守卫的自测） |
| `dsm-shell-tests` | 八个在 BusyBox `sh` 下、使用伪 Docker/Compose/服务 CLI 的测试套件：`dsm_installer_check`、`lifecycle_check`、`auto_update_check`、`cloudflared_check`、`generic_update_check`、`gateway_cli_check`、`migrate_legacy_check`、`pi_installer_check`（Raspberry Pi 移植的共享接缝）——外加 `validate_release.sh --self-test`，即 NAS 端发布验证助手的测量函数单元检查 |
| `shellcheck` | 先对仓库中**每一个** `*.sh` 运行 `sh -n` 语法检查，再对 18 个目标运行 `shellcheck -x`：`install.sh`、`install-pi.sh`、`gateway.sh`、`auto_update.sh`、`pi/auto_update_lite.sh`、`pi/lite_ctl.sh`、`install_scheduler.sh`、`setup_network.sh`、`render_config.sh`、`package.sh`、`doctor.sh`、`state_diff.sh`、`migrate_legacy.sh`、`bootstrap.sh`、`lib/container.sh`、`lib/targets.sh`、`lib/geodata.sh`、`validate_release.sh`（被 source 的库在上下文中一并检查） |

## CLI 契约（生成的文件）

`scripts/cli/spec.yaml` 是 `gateway.sh` 命令面（动词、选项、护栏、退出码、输出——中英双语）的
**唯一可信来源**。有五个已提交的产物由它生成，**绝不可手工编辑**：

- `scripts/lib/help.sh` —— `gateway.sh` 在运行时 source 的 `--help` heredoc
- `docs/cli.md` / `docs/zh/cli.md` —— CLI 参考（EN / 中文）
- `docs/CLI.txt` / `docs/CLI.zh.txt` —— 随最终用户包发布的纯文本指南

用 `python3 scripts/ci/cli_contract_check.py --write` 重新生成——这是修改它们的唯一认可方式。
这些产物之所以提交入库而非由 CI 构建，是因为发布包是被跟踪文件的 `git archive`：
NAS 只会看到预先生成好的 `help.sh`/`CLI.txt`。CI 的 `cli-contract` 检查步骤（见上表）
会在出现任何漂移时失败。

## 制作发布版本

维护者构建 [离线发布包](release-packaging.md) 中所消费的离线包：

```bash
sh scripts/package.sh                         # 精选的 DSM 最终用户包（默认）
sh scripts/package.sh --profile dev           # 完整内部/开发包
sh scripts/package.sh --version 1.2.12         # 覆盖 VERSION 文件
```

- 用 `git archive` 构建，因此**只打包被跟踪的文件** —— `.env`、`config/subscription.txt`、
  `config/config.yaml`、`logs/` 和 `.git/` 绝不会泄漏进去。`.env.example` 和
  `config/subscription.txt.example` 作为模板包含在内。
- 版本号来自 `VERSION` 文件（其次是 `git describe`）；产物输出到被 gitignore 的 `dist/`。
  请在**干净的工作区**运行 —— 除非加 `--allow-dirty`，否则它会拒绝有未提交改动的工作区。
- 仅含源码：不打包容器镜像。镜像通过 `docker-china-sync` 的 ACR 镜像到达 NAS
  （见[与 docker-china-sync 的关系](#与-docker-china-sync-的关系)）。
- 安全保障：若有密钥路径被 git 跟踪，`package.sh` 会拒绝构建；CI 的 `package-check`
  （`scripts/ci/package_check.py`）在每次推送时证明压缩包不含任何密钥。
- 默认（最终用户）配置会通过 `package.sh` 中的 `ENDUSER_EXCLUDES` 路径规格剔除开发者/CI
  文件（README.md、AGENTS.md、`docs/*.md`、`docs/zh`、`scripts/ci`、`scripts/cli` 等），
  并附带 `.txt` 指南 + `install.sh`；一个 `leak_scan` 身份门会在暂存树中 grep 禁止字符串，
  发现即以失败告终（fail-closed）。新增被跟踪文件时，请同时检查 `scripts/package.sh`
  中的这两个列表。

### 发布一个版本

对外发布遵循固定的顺序——NAS 验证被刻意放在打标签**之前**（它曾抓住 CI 无法发现的
真实缺陷）：

1. 提交到 `master` 并推送。
2. 等待该提交上的 Woodpecker CI **全部变绿**。
3. 构建最终用户包：`sh scripts/package.sh`。
4. **打标签之前**先把发布包部署到生产 NAS 并完成验证——以
   [离线发布包 › 验证](release-packaging.md#6-验证)作为验收门。
5. 对通过验证的那个 SHA 打标签。
6. 携带四个发布包资产（zip、tar.gz 及两个 `.sha256` 校验文件）发布 GitHub Release。
7. 删除上一个 Release **及**其标签——仓库只保留最新一个版本。

## 代理（Agent）辅助部署需要临时 sudo 授权

NAS 上的部署是由**非 root 管理员账户**持有的 bundle 安装；部署或验收运行中的特权步骤
（docker 命令、替换发布目录、创建 DSM 任务计划条目、`doctor.sh`）都需要 root。当自动化
代理通过 SSH 执行这些步骤时：

1. **临时授予免密 sudo**——在 NAS 的 `/etc/sudoers.d/` 下放置一个 drop-in 文件（通过 DSM
   控制面板或 root shell）。代理在遇到第一个特权步骤时应当停下来向所有者申请授权，
   而不是假定已有授权。
2. 让代理**在授权有效期内批量完成所有特权步骤**——部署、任务计划、验收检查、`doctor`
   验证——尽量缩短授权窗口。
3. 验证通过后**立即删除该 sudoers drop-in**。代理必须在运行结束时提醒所有者撤销授权；
   遗留的授权应视为缺陷。

该授权等同于运维机密：绝不要把它的文件名、账户名或主机信息提交到仓库
（参见上文的泄漏门）。

## 推送前的本地检查

这些检查与 `.woodpecker.yml` 一一对应——当你新增一个 CI 步骤时，请在同一变更中在此处
加上其对应的本地检查。

```bash
# POSIX 语法（CI 会解析检查仓库中的每一个 .sh，包括 install.sh、installer/、ci/）
for f in $(find . -path ./.git -prune -o -name "*.sh" -print); do sh -n "$f" || echo "FAIL $f"; done

# 渲染器 + 规则检查，然后是 CLI 契约（两者都需要 pyyaml）
python3 -m venv /tmp/v && /tmp/v/bin/pip install -q pyyaml
/tmp/v/bin/python scripts/ci/render_check.py
/tmp/v/bin/python scripts/ci/cli_contract_check.py   # --write 重新生成这些产物

# shellcheck（经 Docker，与 CI 相同的 18 个目标）
docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck-alpine:stable \
  shellcheck -x install.sh install-pi.sh scripts/gateway.sh scripts/auto_update.sh \
  scripts/pi/auto_update_lite.sh scripts/pi/lite_ctl.sh \
  scripts/install_scheduler.sh scripts/setup_network.sh scripts/render_config.sh \
  scripts/package.sh scripts/doctor.sh scripts/state_diff.sh scripts/migrate_legacy.sh \
  bootstrap.sh scripts/lib/container.sh scripts/lib/targets.sh scripts/lib/geodata.sh \
  scripts/validate_release.sh

# compose 渲染（非破坏性，与 CI 相同——绝不触碰你的真实 .env）
docker compose --env-file .env.example config --quiet

# 发布打包安全保障（封闭环境；在临时仓库中构建两种包，需要 git）
python3 scripts/ci/package_check.py

# CI 运行的八个伪 Docker/PATH 桩 TDD 测试套件，外加发布验证助手的
# 自测（不修改 NAS）
sh scripts/ci/dsm_installer_check.sh
sh scripts/ci/lifecycle_check.sh
sh scripts/ci/auto_update_check.sh
sh scripts/ci/cloudflared_check.sh
sh scripts/ci/generic_update_check.sh
sh scripts/ci/gateway_cli_check.sh
sh scripts/ci/migrate_legacy_check.sh
sh scripts/ci/pi_installer_check.sh
sh scripts/validate_release.sh --self-test

# 隐私守卫 + 其自测
python3 scripts/ci/privacy_check.py
python3 scripts/ci/privacy_check_test.py

# 镜像引用策略（fail-closed 的 ${VAR:?} 引用 + REGISTRY_MODE=acr 默认值）
python3 scripts/ci/compose_policy_check.py
```

## 如何扩展

- **让另一个独立容器参与自动更新：** 将其登记为**通用目标** ——
  `sudo sh scripts/gateway.sh update --enable NAME --yes`（或安装器的目标菜单）。
  已登记的目标会被拉取、检查架构，并经由 `lib/container.sh` 原地重建，配有分层健康门控
  （运行中 → `RestartCount` 稳定 → 原生 healthcheck → 可选探针）与保存规格的自动还原；
  验证通过的记录持久化在 `../syno-mihomo-gateway-data/state/last-good/<name>`。
  资格判定（DEC-1，`lib/targets.sh`）要求该容器*已经*在运行配置的 ACR 仓库/命名空间下的
  镜像——不做上游→ACR 名称猜测，且 `REGISTRY_MODE=docker` 下没有通用目标。可选的
  `exec:<cmd>`/`log:<regex>` 探针写在 `../syno-mihomo-gateway-data/state/update-targets`
  中该目标的 `name|strategy|probe` 记录里。映射不到任何部署目标的裸 `UPDATE_IMAGES`
  引用仍会被拉取但**仅缓存**（以 `WARN` 记录，指明 `MIHOMO_IMAGE`/`METACUBEXD_IMAGE`/`CF_IMAGE`）。
  参见[自动更新 › 通用目标](auto-update.md#通用目标任意已登记的容器)。扩展该引擎请修改
  `lib/targets.sh`（资格判定）/ `lib/container.sh`（捕获/重放 + 一致性守卫，对无法重放的
  设置 fail-closed），在 `scripts/ci/generic_update_check.sh` 中补充覆盖，并用
  `scripts/state_diff.sh` 证明状态保留。
- **添加一个配置开关：** 在 `config.template.yaml` 中添加一个 `{{TOKEN}}`，在 mihomo 的
  `environment:` 块中添加一行 `- VAR=${VAR}`，在 `render_config.sh` 中添加一条 `sed -e`，并在
  [配置](configuration.md) 与 `.env.example` 中各添加一行。同时在 `render_check.py` 中添加一条断言。
- **新增或修改 `gateway.sh` 的动词/选项：** 编辑 `scripts/cli/spec.yaml`，运行
  `python3 scripts/ci/cli_contract_check.py --write`，并把重新生成的产物与 `gateway.sh`
  的改动一起提交——绝不手工编辑它们（见 [CLI 契约](#cli-契约生成的文件)）。
- **修改健康门控 / 蓝绿部署：** 编辑 `lib/compose.sh` / `lib/cloudflared.sh`；保持“先拉取再切换”
  和“切换前先验证”这两条不变式。

## 文档：镜像与最终用户指南

- `docs/zh/*.md` 是 `docs/*.md` 的中文镜像——每一处英文文档改动都必须**在同一变更中**
  同步到其镜像。
- `docs/*.txt`（+ `.zh.txt`）是 `package.sh` 最终用户配置随包发布的纯文本指南：
  `CLI.txt`/`CLI.zh.txt` 由 `spec.yaml` 生成（见上文）；其余为手工维护，必须与各自的
  `.md` 对应文档保持同步。

## 与 docker-china-sync 的关系

`../docker-china-sync` 是推送端（GitHub Actions → 阿里云 ACR）。请保持其 `images.txt`
与本仓库的 `UPDATE_IMAGES` 同步。`REGISTRY_MODE=acr`（默认）经由该镜像源拉取；
`REGISTRY_MODE=docker` 是显式可选项，直接从上游拉取并绕过它（同时使通用目标失去资格）。
参见[自动更新 › ACR 配置](auto-update.md#acr-配置)。
