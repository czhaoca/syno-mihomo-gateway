# 开发与内部实现

[← README](../../README.md) · [English](../development.md)
手册：[架构](architecture.md) · [安装](installation.md) · [离线发布包](release-packaging.md) · [配置](configuration.md) · [自动更新](auto-update.md) · [运维](operations.md) · [故障排查](troubleshooting.md) · **开发**

---

面向贡献者以及任何希望扩展本网关的人员。

## 仓库结构

```
docker-compose.yml            # mihomo (macvlan, privileged) + metacubexd (bridge)
.env.example                  # documented config contract (copy to .env)
VERSION                       # release version (stamped into the package.sh artifact name)
bootstrap.sh                  # offline-install first-run helper (seeds .env, restores exec bits)
config/
  config.template.yaml        # mihomo config with {{PLACEHOLDERS}}
  subscription.txt.example    # subscription template (copy to subscription.txt)
scripts/
  gateway.sh                  # 非交互 CLI：deploy/redeploy/modify/cron/status/doctor/update
  setup_network.sh            # macvlan + TUN setup, optional ACR login/pull
  render_config.sh            # renders config.yaml from the template (entrypoint + CI both call it)
  auto_update.sh              # the DSM auto-update orchestrator (entry point)
  install_scheduler.sh        # prints DSM Task Scheduler / crontab settings
  package.sh                  # build-host: builds the offline release zip (docs/release-packaging.md)
  installer/
    preprocess.sh             # 分资源清理菜单；决策策略位于 lib/resolve.sh
  lib/
    common.sh                 # env load, logging+rotation, mkdir lock, exit codes
    registry.sh               # preflight (compose/arch/network/tun), ACR login, pull + change detect
    compose.sh                # compose up, health gate, rollback
    cloudflared.sh            # blue-green reprovision of the external cloudflared
    lifecycle.sh              # 部署盘点 + 已验证的定向拆除
    resolve.sh                # 无 UI 的配置解析：IP 建议、镜像引用、订阅 URL、清理计划策略
    scheduler.sh              # 安全解析 DSM/BusyBox cron 并生成任务命令
  ci/
    render_check.py           # CI: runs the real renderer + structural/rule assertions
    auto_update_check.sh      # 使用伪 Docker 的计划/更新/回滚 TDD 测试
    cloudflared_check.sh      # 使用伪 Docker 的蓝绿更新 TDD 测试
    gateway_cli_check.sh      # 通过 PATH 桩测试 gateway.sh CLI 契约
    lifecycle_check.sh        # 使用伪 Docker 的盘点/清理安全测试
    privacy_check.py          # 被跟踪内容/历史隐私守卫
.woodpecker.yml               # CI: compose/yaml validate, render check, shellcheck
docs/                         # this manual (EN) + docs/zh (中文)
```

## 编码规约

- **POSIX `/bin/sh`，BusyBox 兼容。** DSM 自带 BusyBox；不使用 bashism 或关联数组，
  `scripts/setup_network.sh` 和无人值守任务入口也遵循此规则。
- **编排器中不使用 `set -e`/`set -u`。** 它显式检查返回码，从而避免某个软失败意外地拆毁整个网关。
  `render_config.sh` *确实*使用了 `set -eu`（它是一个简短的、快速失败的渲染器）。
- **提交的文件中不硬编码 DNS / 网络地址**（项目规则）。请使用
  `{{PLACEHOLDERS}}` + `.env`。CI 会强制执行这一点（`render_check.py`）。
- **机密信息只放在被 gitignore 的 `.env` 中**（`ACR_PASSWORD`、`CF_TUNNEL_TOKEN`、`CONTROLLER_SECRET`）。
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
等待 Docker 并执行预检 → 拉取/检查/检测变更 → 仅使用本地镜像执行 Compose
（含健康门控/回滚）→ cloudflared 蓝绿更新 → 清理 → 通知**。完整细节见
[自动更新](auto-update.md)。关键库函数：

| 文件 | 函数 |
|---|---|
| `lib/common.sh` | `load_env`、`log*`、`rotate_log`、`acquire_lock`/`release_lock`（由 `LOCK_HELD` 守护）、`EXIT_*` 退出码 |
| `lib/registry.sh` | `validate_update_config`、`wait_for_docker_ready`、`check_arch_expectation`/`arch_ok`、`check_network`、`check_tun`、`acr_login`、`pull_image`、`deploy_needed` |
| `lib/compose.sh` | `compose_config_check`、`compose_up_local`、`health_gate`（含 `mihomo_controller_probe`）、`rollback_compose` |
| `lib/cloudflared.sh` | `cloudflared_blue_green`、`cloudflared_wait_connected`、安全规格捕获/重放、回滚、候选/临时目录清理 |
| `lib/lifecycle.sh` | `lifecycle_inspect`、已验证的容器/网络移除、手动命令输出 |
| `lib/resolve.sh` | `resolve_mihomo_ip`、`resolve_images`/`resolve_update_images`、`resolve_subscription_url`/`subscription_current`、`resolve_cleanup_plan`（无 UI；向导负责呈现结果） |
| `lib/scheduler.sh` | `cron_normalize`、`scheduler_update_command`、`scheduler_network_command`、`scheduler_reload_crond` |

并发：只有持锁者才会释放锁（`LOCK_HELD`）；当候选可能是唯一已连接隧道时，EXIT 陷阱不会
回收它（`CF_KEEP_CANDIDATE`）。

## CI（`.woodpecker.yml`）

在向 `main` 和 `master` 推送/发起 PR 时运行：

| 步骤 | 内容 |
|---|---|
| `validate-compose` | `docker-compose --env-file .env.example config --quiet`（阻断式检查） |
| `validate-yaml` | `yaml.safe_load(docker-compose.yml)` |
| `render-config` | `python scripts/ci/render_check.py` —— 针对一个带 `Name=` 前缀及 `&` 参数的夹具 URL 运行**真实的**渲染器，并断言该 URL 能精确地往返还原；同时强制执行“不硬编码 DNS”规则 |
| `compose-policy` | `python scripts/ci/compose_policy_check.py` —— 断言网关镜像**仅来自 ACR**：`docker-compose.yml` 中不得有直接 Docker Hub/ghcr 回退，`.env.example` 的镜像引用须指向私有仓库 |
| `package-check` | `python scripts/ci/package_check.py` —— 在临时仓库中构建发布 zip，证明**任何密钥都不会被打包**（植入的 `.env`/订阅/`config.yaml` 不在两种压缩包的文件名*和*字节中），校验和正确，各项守卫生效，且 `bootstrap.sh` 往返正常 |
| `privacy-check` | 扫描被跟踪文件和可达 blob，拒绝私有运维标识、凭据、私钥和意外跟踪的运行时文件 |
| `dsm-shell-tests` | 在 BusyBox `sh` 下执行安装器、生命周期、计划任务/更新器和分阶段 cloudflared 断言；Docker/Compose 全部使用假实现 |
| `shellcheck` | 对入口点脚本运行 `shellcheck -x`（lib/*.sh 在上下文中被一并检查） |

## 制作发布版本

维护者构建 [离线发布包](release-packaging.md) 中所消费的离线包：

```bash
sh scripts/package.sh                         # DSM 最终用户包（默认）
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

## 推送前的本地检查

```bash
# POSIX syntax
for f in scripts/*.sh scripts/lib/*.sh; do sh -n "$f" || echo "FAIL $f"; done

# renderer + rule check (needs pyyaml)
python3 -m venv /tmp/v && /tmp/v/bin/pip install -q pyyaml && /tmp/v/bin/python scripts/ci/render_check.py

# shellcheck (via Docker, same as CI)
docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck-alpine:stable \
  shellcheck -x scripts/auto_update.sh scripts/install_scheduler.sh scripts/setup_network.sh scripts/render_config.sh scripts/package.sh bootstrap.sh

# compose renders (needs a throwaway .env)
cp .env.example .env && docker compose config -q && rm -f .env

# release packaging safeguard (hermetic; builds in a temp repo, needs git)
python3 scripts/ci/package_check.py

# 计划任务/更新器/cloudflared TDD 测试（使用伪 Docker/Compose，不修改 NAS）
sh scripts/ci/auto_update_check.sh
sh scripts/ci/cloudflared_check.sh
sh scripts/ci/dsm_installer_check.sh
sh scripts/ci/lifecycle_check.sh
python3 scripts/ci/privacy_check.py
python3 scripts/ci/privacy_check_test.py

# ACR-only image policy (no direct Docker Hub/ghcr fallback)
python3 scripts/ci/compose_policy_check.py
```

## 如何扩展

- **追踪另一个容器以进行更新：** 将其 ACR 引用添加到 `UPDATE_IMAGES`。要让它真正*部署*（而不仅仅是缓存），
  它必须是一个被某个部署镜像变量所引用的 compose 服务，或者像 cloudflared 那样被处理 ——
  否则它只会被拉取并缓存（以 `WARN` 形式记录日志）。
- **添加一个配置开关：** 在 `config.template.yaml` 中添加一个 `{{TOKEN}}`，在 mihomo 的
  `environment:` 块中添加一行 `-e`，在 `render_config.sh` 中添加一条 `sed -e`，并在
  [配置](configuration.md) 与 `.env.example` 中各添加一行。同时在 `render_check.py` 中添加一条断言。
- **修改健康门控 / 蓝绿部署：** 编辑 `lib/compose.sh` / `lib/cloudflared.sh`；保持“先拉取再切换”
  和“切换前先验证”这两条不变式。

## 与 docker-china-sync 的关系

`../docker-china-sync` 是推送端（GitHub Actions → 阿里云 ACR）。请保持其 `images.txt`
与本仓库的 `UPDATE_IMAGES` 同步。参见[自动更新 › ACR 设置](auto-update.md)。
