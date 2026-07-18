# 离线安装（发布压缩包）

[← README](../../README.md) · [English](../release-packaging.md)
手册：[架构](architecture.md) · [安装](installation.md) · **离线发布包** · [配置](configuration.md) · [自动更新](auto-update.md) · [运维](operations.md) · [CLI](cli.md) · [故障排查](troubleshooting.md) · [开发](development.md)

---

标准[安装](installation.md)流程的第一步是从 GitHub `git clone`。但在**中国大陆 github.com 无法访问**，
这一步会直接失败。本指南提供替代方案：在一台**能访问 GitHub** 的机器上构建一个**发布压缩包**，
把它带到 NAS，解压到 `/volume1/docker/syno-mihomo-gateway`，然后在本地完成配置 ——
**无需 git，NAS 也无需访问 GitHub**。

压缩包**只含源码**（compose 文件、脚本、配置模板，以及纯文本手册 ——
见[包里有什么](#打包-profile-与包内内容)），刻意**不**打包容器镜像。镜像走的是
自动更新已经在用的那条路径：由 [`docker-china-sync`](https://github.com/czhaoca/docker-china-sync)
镜像同步到你的**阿里云 ACR**，再由 NAS 从该 ACR 拉取（见第 4 步）。因此离线安装是一个双轨配置 ——
**代码走压缩包，镜像走你的 ACR 镜像** —— NAS 始终不需要访问 github.com 或 Docker Hub/ghcr。

## 何时使用

- NAS 无法访问 **github.com**（中国大陆，或屏蔽了它的网络）→ 用压缩包替代
  [安装 › 方式 A（git clone）](installation.md#1-获取代码)。
- 你不想在 NAS 上安装/运行 `git`。
- 如果 NAS *能*访问 GitHub，标准的 `git clone` 安装更简单 —— 直接用那个。

## 1. 获取发布压缩包（在能联网的机器上）

**捷径 —— 直接下载。**每个 GitHub 发布版本都已发布下面列出的四个 DSM 包产物
（zip、tar.gz 以及两个 `.sha256` 校验和文件），另有通用 Linux 移植的四个
`syno-mihomo-gateway-linux-*` 附件。在任意一台能访问 github.com 的机器上，
下载最新发布版本的附件，然后直接跳到第 2 步 —— 无需 clone，也无需构建。

**或者自己从 clone 构建**：

```bash
git clone https://github.com/czhaoca/syno-mihomo-gateway.git
cd syno-mihomo-gateway
sh scripts/package.sh                    # DSM 最终用户包（默认 profile）
```

个人使用的离线包，这一条命令就够了。维护者制作*正式发布*版本前会先跑完整的检查套件 ——
见[开发 › 制作发布版本](development.md#制作发布版本)与
[开发 › 推送前的本地检查](development.md#推送前的本地检查)。

两种方式最终都会得到：

```text
dist/syno-mihomo-gateway-<版本>.zip            # 适合 File Station 图形界面解压（无需 SSH）
dist/syno-mihomo-gateway-<版本>.tar.gz         # 解压时保留脚本的可执行位
dist/syno-mihomo-gateway-<版本>.zip.sha256     # 校验和文件
dist/syno-mihomo-gateway-<版本>.tar.gz.sha256
```

版本号来自仓库的 `VERSION` 文件（可用 `--version X.Y.Z` 覆盖）。压缩包用 `git archive` 构建，
因此**只包含被 git 跟踪的文件** —— 你的 `.env`、`config/subscription.txt`、`config/config.yaml`
绝不会被打进去。`.env.example` 和 `config/subscription.txt.example` *会*作为模板包含在内。

### 打包 profile 与包内内容

`scripts/package.sh` 构建三种 profile 之一：

- **`--profile enduser`（默认）** —— 精选的自包含发行版：运行时文件、交互式安装器，以及**仅有的
  纯文本手册**。所有 Markdown 文档（`README.md`、`docs/*.md`、`docs/zh/`）、开发/CI 工具
  （`scripts/ci`、`scripts/cli`、`.woodpecker.yml`）以及 `scripts/package.sh` 本身都会被剔除。
  在 NAS 上，手册是 `docs/README.txt`、`INSTALL.txt`、`CONFIGURE.txt`、`TROUBLESHOOTING.txt`、
  `AUTO-UPDATE.txt` 和 `CLI.txt`（另有 `.zh.txt` 中文版本）。本页 —— 连同[安装](installation.md)
  以及本指南中所有其他 `.md` 交叉链接 —— 都**不在**包内；请在联网机器上或在线阅读 `.md` 手册。
- **`--profile linux`** —— 在 enduser 集合之上**加入通用 Linux 移植**：两个入口脚本
  （`install-pi.sh` 与 `install-linux.sh`）、`scripts/pi/`、`scripts/linux/`，以及
  `docs/INSTALL-LINUX.txt` / `docs/INSTALL-LINUX.zh.txt` 指南。产物命名为
  `syno-mihomo-gateway-linux-<版本>.{zip,tar.gz}`（包内根目录名相同），两种包可以并存于 dist/。
  该移植的运行时需要从上游 releases 下载 mihomo/面板产物，因此仅此 profile 容许打包文件中出现
  通用代码托管域名；下方的身份门禁依然完整生效。在目标主机上解压后运行
  `sudo sh ./install-linux.sh`（Raspberry Pi 上运行 `sudo sh ./install-pi.sh`；见包内
  `docs/INSTALL-LINUX.txt`）。`--profile pi` 仍被接受为已弃用的别名：它会给出警告，
  然后构建同一个包。
- **`--profile dev`** —— 完整的 git 跟踪目录树（文档、CI、元数据）。内部使用；CI 的打包检查
  构建的就是它。

### 构建守卫（为什么构建会拒绝）

`package.sh` 宁可拒绝构建（退出码 3），也不打出有问题的包：

- **工作区有未提交改动** —— 除非传入 `--allow-dirty` 否则拒绝；该参数打包的是已提交的
  `HEAD`（**不含**你的本地修改），并在版本号后追加 `-dirty`。
- **密钥被 git 跟踪** —— 如果 `.env`、`config/subscription.txt`、`config/config.yaml` 或
  `logs/` 下的任何文件被 git 跟踪（`git archive` 会把它打进包里），则拒绝；请先用
  `git rm --cached <path>` 取消跟踪。
- **不是 git 检出目录** —— 必须在源码 clone 中运行，不能在解压出的发布包里运行。
- **身份泄露门禁**（enduser 与 linux profile）—— 在写出任何产物之前，会扫描暂存目录树中的
  开发者/身份识别字符串（外加一个邮箱地址正则）。任何命中都会以 `IDENTITY LEAK` 中止，
  指出违规字符串和文件，并且**不写出任何产物**。修复方法是从违规的*被跟踪*文件中清除
  该字符串、提交后重新构建 —— 不修复直接重跑不会有任何变化。禁止列表是分组的：**身份**
  字符串在两种精选 profile 中都被禁止；通用**代码托管域名**在 enduser 包中禁止、在 linux
  包中容许（其运行时需要可用的上游下载地址）。

其他参数：`--no-zip` / `--no-tar` 跳过对应产物（两个同时传是错误）。

## 2. 把压缩包传到 NAS

用任意带外方式把 `dist/syno-mihomo-gateway-<版本>.zip`（或 `.tar.gz`）传到 NAS：

- **U 盘** —— 拷贝文件，插入 DSM 的 USB 口，在 File Station 中拷出；或
- **File Station 上传** —— 通过局域网把文件拖拽到例如 `/volume1/docker`。

如果想在传输后校验完整性，把对应的 `.sha256` 一起带上。

## 3. 解压到 `/volume1/docker`

两种压缩包都会解压出一个顶层的 `syno-mihomo-gateway/` 目录，因此在 `/volume1/docker` 内解压会把
目录树正好落在 `/volume1/docker/syno-mihomo-gateway` —— 这是所有文档和 DSM 计划任务命令都假设的路径。

- **File Station（无需 SSH）：** 右键点击 `.zip` → **解压** → 解压到 `/volume1/docker`。
- **SSH：**
  ```bash
  cd /volume1/docker
  sha256sum -c syno-mihomo-gateway-<版本>.zip.sha256     # 可选的完整性校验
  unzip syno-mihomo-gateway-<版本>.zip                   # 或：tar -xzf syno-mihomo-gateway-<版本>.tar.gz
  cd syno-mihomo-gateway
  ```

> **可执行位：** File Station 解压 `.zip` 会丢掉 Unix 可执行位。下一步的 `bootstrap.sh` 会把它补回来。
> 如果你用 SSH 解压并希望直接保留可执行位（无需 bootstrap），请改用 `.tar.gz`。

## 4. 确认镜像已在你的 ACR 中

由于 Docker Hub/ghcr 同样被封锁，NAS 从**你的阿里云 ACR** 拉取镜像，而该 ACR 由
[`docker-china-sync`](https://github.com/czhaoca/docker-china-sync) 保持更新。启动服务栈前，请确认：

- `docker-china-sync` 正在把 `metacubex/mihomo` 和 `ghcr.io/metacubex/metacubexd` 镜像同步到你的
  ACR 命名空间（见其
  [配合 syno-mihomo-gateway 使用](https://github.com/czhaoca/docker-china-sync#using-with-syno-mihomo-gateway)
  一节），并且
- 在下一步里保持 `REGISTRY_MODE=acr`（默认值），并把你的 `DOCKER_REGISTRY`、`ACR_NAMESPACE`
  和凭据交给安装器 —— 它会由这些值加上 `*_TAG` **推导出** `MIHOMO_IMAGE` /
  `METACUBEXD_IMAGE`，因此通常不需要手工编辑镜像引用 —— 完整参考见
  [配置](configuration.md)与[自动更新 › ACR 配置](auto-update.md#acr-配置)。

NAS 只需要能访问你的 ACR —— 始终不需要访问 github.com。

## 5. 配置并启动

在解压出的目录里运行首次设置脚本：

```bash
sh bootstrap.sh
```

它会从随包附带的示例生成 `../syno-mihomo-gateway-data/.env` 及其 `config/subscription.txt`
（仅在不存在时），迁移旧版目录内文件，补回脚本的可执行位并打印后续步骤。它不写入任何密钥，
也不执行任何特权操作。

接着运行**交互式安装器** —— 这是发布包专为其打造的推荐流程：

```bash
sudo sh ./install.sh
```

它会引导你完成 `.env`（包括 `REGISTRY_MODE`/ACR 和推导出的镜像引用）、订阅、网络 + TUN 设备
以及启动。随包附带的 `docs/INSTALL.txt` 和 `docs/CONFIGURE.txt` 离线覆盖同样的内容。

更想手工配置？手动步骤与标准安装**完全相同** —— 请按[安装](installation.md)文档操作
（在联网机器上阅读；`.md` 手册不在包内）：

1. [配置 `.env`](installation.md#2-配置-env) —— 设置 `ROUTER_IP`、`MIHOMO_IP`、DNS，以及第 4 步里
   你的 ACR 镜像仓库/凭据（保持 `REGISTRY_MODE=acr`）。
2. [添加你的订阅](installation.md#3-添加你的订阅)。
3. [创建网络 + TUN 设备](installation.md#4-创建网络--tun-设备) —— `sudo ./scripts/setup_network.sh`。
4. [启动服务栈](installation.md#5-启动服务栈) ——
   `sudo docker compose --env-file ../syno-mihomo-gateway-data/.env up -d`。

## 6. 验证

- [ ] 目录树位于 `/volume1/docker/syno-mihomo-gateway`。
- [ ] `../syno-mihomo-gateway-data/.env` 存在（`chmod 600`）；`REGISTRY_MODE=acr`，且推导出的
      镜像引用指向你的 ACR。
- [ ] `../syno-mihomo-gateway-data/config/subscription.txt` 填入了真实 URL。
- [ ] `docker images` 显示从你的 ACR 拉取的 mihomo 和 metacubexd 镜像。
- [ ] `sudo ./scripts/setup_network.sh` 成功（已创建 macvlan + TUN）。
- [ ] 引导安装器报告容器健康。
- [ ] 从**非 NAS** 的局域网设备打开 `http://<NAS_IP>:<WEB_UI_PORT>` 能访问面板。
- [ ] 分阶段验证器（`sudo sh scripts/validate_release.sh`）通过——它的 A4.5 门会从控制器
      实时发现 url-test 分组，任何生成的国家分组（某条 `COUNTRY_GROUPS`）匹配不到任何
      机场节点时**判定发布失败**。

## 更新离线安装

这里没有 `git pull`。要更新**代码**：

1. 在联网机器上下载最新发布版本的附件（或重新构建：`git pull && sh scripts/package.sh`），
   然后把压缩包传输过去。
2. 从旧版目录内配置**首次**升级时，请覆盖解压到现有目录并运行 `sh bootstrap.sh`；确认 `.env`
   和订阅已迁移前不要删除旧目录。`/volume1/docker/syno-mihomo-gateway-data` 创建后，今后的
   发布目录可以安全替换。
3. `sh bootstrap.sh`（对已有配置是空操作，仅补回可执行位），然后运行
   `sudo sh ./install.sh` 并选择**重新部署**。这样会强制 Mihomo 渲染并启用更新后的网关配置；
   单独运行 `docker compose up -d` 可能不会使其生效。

更新**镜像**的方式不变：`scripts/auto_update.sh`（DSM 任务计划）从你的 ACR 拉取 —— 而非 GitHub ——
所以正常的[自动更新](auto-update.md)流程在离线安装上同样有效。
