#!/bin/sh
# i18n_pi.sh (scripts/pi) - Pi-only bilingual strings, OVERLAYING the stock
# catalog without touching it: msg() is redefined to consult the pi tables
# first and fall back to installer/i18n.sh's _msg_en/_msg_zh (which install.sh
# keeps sourcing unmodified - it never sources this file). Source AFTER
# i18n.sh. Like the stock catalog, the zh table carries literal UTF-8; every
# other pi script stays ASCII-only per docs/development.md. msgf() needs no
# override (it routes through msg). EN and ZH templates MUST carry the same
# %s count in the same order; the CI suite asserts en/zh key parity.

_msg_en_pi() {
  case "$1" in
    pi_title)             printf '%s' 'Mihomo Gateway - Raspberry Pi installer' ;;
    pi_step_installer)    printf '%s' 'Raspberry Pi installer' ;;
    pi_menu_deploy)       printf '%s' 'Deploy the gateway (choose mode)' ;;
    pi_hw_title)          printf '%s' 'Detected hardware' ;;
    pi_hw_model)          printf '%s' '  model:   %s' ;;
    pi_hw_mem)            printf '%s' '  memory:  %s MB' ;;
    pi_hw_arch)           printf '%s' '  arch:    %s' ;;
    pi_hw_recommend)      printf '%s' 'recommended mode: %s' ;;
    pi_ask_mode)          printf '%s' 'Select install mode' ;;
    pi_mode_compose)      printf '%s' 'Docker compose - full stack, digest-gated auto-updates (needs a 64-bit OS and >= 1 GB RAM)' ;;
    pi_mode_lite)         printf '%s' 'Bare-metal lite - native binary + built-in dashboard (256-512 MB tier)' ;;
    pi_info_lowram_tuning) printf '%s' 'this device is in the 1 GB class: compose works with low-RAM tuning (.mrs rule-sets, zram) - lite mode leaves more headroom' ;;
    pi_warn_armv6)        printf '%s' 'this is an ARMv6 device (Pi 1 / Zero / Zero W): best-effort ONLY - expect <= 30-40 Mbps, single-device or lab use' ;;
    pi_warn_armv6_2)      printf '%s' 'no official Docker images exist for ARMv6; only the bare-metal lite mode can run here, and it is NOT supported for whole-home gateway duty' ;;
    pi_ask_armv6_ack)     printf '%s' 'continue anyway on this best-effort basis' ;;
    pi_ack_declined)      printf '%s' 'sensible choice - a Pi 3 or newer makes a far better gateway' ;;
    pi_info_compose_armv6) printf '%s' 'compose mode is unavailable on ARMv6 - continuing with lite mode' ;;
    pi_info_compose_armv7) printf '%s' 'compose mode needs a 64-bit OS (arm64): this system reports a 32-bit userland (armv7) and the dashboard image ships no arm/v7 build - reinstall 64-bit Raspberry Pi OS for compose, or use lite mode (works on 32-bit)' ;;
    pi_warn_acr_arch)     printf '%s' 'REGISTRY_MODE=acr on a %s host: your ACR namespace must mirror %s images' ;;
    pi_warn_acr_arch_fix) printf '%s' 'extend your ACR image-sync pipeline to publish %s images first, or pick the docker (upstream) source in the image wizard' ;;
    pi_err_wlan_parent)   printf '%s' 'the network parent %s is a wireless interface: macvlan over Wi-Fi is typically broken (driver/AP isolation) - compose mode needs wired Ethernet' ;;
    pi_err_wlan_parent_fix) printf '%s' 'connect the Pi with an Ethernet cable and re-run, or use lite mode (works over Wi-Fi)' ;;
    pi_step_lite)         printf '%s' 'Bare-metal lite install' ;;
    pi_step_lite_wizard)  printf '%s' 'Lite settings (ports, DNS, artifact source)' ;;
    pi_diag_lite_root)    printf '%s' 'lite install requires root (systemd unit, TUN device, DNS port 53)' ;;
    pi_diag_lite_root_fix) printf '%s' 're-run: sudo sh ./install-pi.sh' ;;
    pi_lite_ghmirror_hint) printf '%s' 'if github.com is unreachable from this network, set a public gh-proxy prefix; downloads become <prefix>/<github-url>. Leave empty for direct.' ;;
    pi_lite_q_ghmirror)   printf '%s' 'GitHub mirror prefix (empty = direct)' ;;
    pi_lite_q_version)    printf '%s' 'Pin a mihomo release tag (empty = latest)' ;;
    pi_lite_q_sha)        printf '%s' 'Optional sha256 of the pinned release archive (empty = skip)' ;;
    pi_warn_port53)       printf '%s' 'port 53 is already in use - mihomo DNS will fail to bind until the stock resolver is disabled' ;;
    pi_warn_port53_fix)   printf '%s' 'on Raspberry Pi OS: disable systemd-resolved/dnsmasq or move it off port 53, then restart mihomo-gateway' ;;
    pi_lite_info_render)  printf '%s' 'rendering config.yaml (same renderer the container path uses)' ;;
    pi_lite_diag_tag)     printf '%s' 'could not resolve the mihomo release tag' ;;
    pi_lite_diag_tag_fix) printf '%s' 'check the mirror/network, or pin MIHOMO_VERSION in .env' ;;
    pi_lite_fetch_bin)    printf '%s' 'downloading + verifying the mihomo binary (%s)' ;;
    pi_lite_ok_bin)       printf '%s' 'mihomo binary %s installed (verify ladder passed)' ;;
    pi_lite_diag_bin)     printf '%s' 'the mihomo binary failed the download/verify ladder' ;;
    pi_lite_diag_bin_fix) printf '%s' 'check the mirror, or sideload the release .gz into the data bin/ dir (see the Pi guide)' ;;
    pi_lite_fetch_ui)     printf '%s' 'downloading the MetaCubexD dashboard (compressed-dist.tgz)' ;;
    pi_lite_ok_ui)        printf '%s' 'dashboard installed - mihomo serves it at /ui on the controller port' ;;
    pi_lite_diag_ui)      printf '%s' 'the dashboard archive failed to download or its layout was unrecognized' ;;
    pi_lite_diag_ui_fix)  printf '%s' 'check the mirror, or sideload compressed-dist.tgz into the data ui/ dir' ;;
    pi_lite_diag_unit)    printf '%s' 'could not write the systemd unit' ;;
    pi_lite_diag_unit_fix) printf '%s' 'check permissions on /etc/systemd/system (run as root)' ;;
    pi_lite_info_start)   printf '%s' 'enabling + starting mihomo-gateway.service' ;;
    pi_lite_diag_start)   printf '%s' 'mihomo-gateway.service failed to start' ;;
    pi_lite_diag_start_fix) printf '%s' 'inspect: journalctl -u mihomo-gateway -n 50' ;;
    pi_lite_probe_ok)     printf '%s' 'controller answers on loopback - mihomo is up' ;;
    pi_lite_probe_warn)   printf '%s' 'controller did not answer yet - check: journalctl -u mihomo-gateway -n 50 (port 53 conflicts are the usual cause)' ;;
    pi_lite_rep_dashboard) printf '%s' 'dashboard: http://%s:%s/ui' ;;
    pi_lite_rep_client)   printf '%s' 'point LAN clients gateway + DNS at %s (this Pi)' ;;
    pi_ok_schedule)       printf '%s' 'schedule: daily at %s (device system timezone); log timestamps in %s' ;;
    pi_ok_cron_installed) printf '%s' 'crontab entry installed - the updater runs on the saved schedule' ;;
    pi_warn_cron_tz)      printf '%s' 'note: cron fires in this device SYSTEM timezone; UPDATE_TZ only affects in-job log timestamps' ;;
    pi_ask_dryrun)        printf '%s' 'Run an updater dry-run now (no changes applied)' ;;
    pi_warn_cron_not_installed) printf '%s' 'crontab entry NOT installed - automatic updates are not scheduled yet' ;;
    pi_ctl_usage)         printf '%s' 'usage: sh scripts/pi/lite_ctl.sh {status|doctor|start|stop|update [--dry-run|--force]}' ;;
    pi_ctl_usage2)        printf '%s' 'read-only: status, doctor; root required: start, stop; update delegates to the lite auto-updater' ;;
    *) return 1 ;;
  esac
}

_msg_zh_pi() {
  case "$1" in
    pi_title)             printf '%s' 'Mihomo 网关 - Raspberry Pi 安装程序' ;;
    pi_step_installer)    printf '%s' 'Raspberry Pi 安装程序' ;;
    pi_menu_deploy)       printf '%s' '部署网关（选择模式）' ;;
    pi_hw_title)          printf '%s' '检测到的硬件' ;;
    pi_hw_model)          printf '%s' '  型号：   %s' ;;
    pi_hw_mem)            printf '%s' '  内存：   %s MB' ;;
    pi_hw_arch)           printf '%s' '  架构：   %s' ;;
    pi_hw_recommend)      printf '%s' '推荐的安装模式：%s' ;;
    pi_ask_mode)          printf '%s' '请选择安装模式' ;;
    pi_mode_compose)      printf '%s' 'Docker compose - 完整栈，带摘要门控的自动更新（需要 64 位系统且内存 >= 1 GB）' ;;
    pi_mode_lite)         printf '%s' '裸机精简模式 - 原生二进制 + 内置面板（适合 256-512 MB 内存档）' ;;
    pi_info_lowram_tuning) printf '%s' '该设备属于 1 GB 内存档：compose 模式可用但需低内存调优（.mrs 规则集、zram）- 精简模式余量更大' ;;
    pi_warn_armv6)        printf '%s' '这是 ARMv6 设备（Pi 1 / Zero / Zero W）：仅作尽力支持 - 预计吞吐不超过 30-40 Mbps，只适合单设备或实验用途' ;;
    pi_warn_armv6_2)      printf '%s' 'ARMv6 没有任何官方 Docker 镜像；此设备只能运行裸机精简模式，且不支持作为全屋网关使用' ;;
    pi_ask_armv6_ack)     printf '%s' '在此尽力支持的前提下仍然继续' ;;
    pi_ack_declined)      printf '%s' '明智的选择 - Pi 3 或更新的型号更适合做网关' ;;
    pi_info_compose_armv6) printf '%s' 'ARMv6 上无法使用 compose 模式 - 将继续使用精简模式' ;;
    pi_info_compose_armv7) printf '%s' 'compose 模式需要 64 位系统（arm64）：当前系统是 32 位（armv7），且面板镜像没有 arm/v7 构建 - 重装 64 位 Raspberry Pi OS 后可用 compose，或使用精简模式（支持 32 位）' ;;
    pi_warn_acr_arch)     printf '%s' 'REGISTRY_MODE=acr 且主机架构为 %s：你的 ACR 命名空间必须镜像 %s 架构的镜像' ;;
    pi_warn_acr_arch_fix) printf '%s' '请先扩展你的 ACR 镜像同步流水线以发布 %s 镜像，或在镜像向导中选择 docker（上游）源' ;;
    pi_err_wlan_parent)   printf '%s' '网络父接口 %s 是无线网卡：Wi-Fi 上的 macvlan 通常不可用（驱动/AP 隔离）- compose 模式需要有线以太网' ;;
    pi_err_wlan_parent_fix) printf '%s' '请用网线连接 Pi 后重试，或使用精简模式（支持 Wi-Fi）' ;;
    pi_step_lite)         printf '%s' '裸机精简模式安装' ;;
    pi_step_lite_wizard)  printf '%s' '精简模式设置（端口、DNS、下载源）' ;;
    pi_diag_lite_root)    printf '%s' '精简模式安装需要 root（systemd 服务、TUN 设备、DNS 53 端口）' ;;
    pi_diag_lite_root_fix) printf '%s' '请重新运行：sudo sh ./install-pi.sh' ;;
    pi_lite_ghmirror_hint) printf '%s' '如果本网络无法直连 github.com，可设置公共 gh-proxy 加速前缀；下载地址将变为 <前缀>/<github-地址>。留空表示直连。' ;;
    pi_lite_q_ghmirror)   printf '%s' 'GitHub 镜像前缀（留空 = 直连）' ;;
    pi_lite_q_version)    printf '%s' '固定 mihomo 发布版本标签（留空 = 最新版）' ;;
    pi_lite_q_sha)        printf '%s' '可选：固定版本压缩包的 sha256（留空 = 跳过）' ;;
    pi_warn_port53)       printf '%s' '53 端口已被占用 - 在停用系统自带解析器之前 mihomo 的 DNS 将无法绑定' ;;
    pi_warn_port53_fix)   printf '%s' '在 Raspberry Pi OS 上：停用 systemd-resolved/dnsmasq 或将其移出 53 端口，然后重启 mihomo-gateway' ;;
    pi_lite_info_render)  printf '%s' '正在渲染 config.yaml（与容器路径使用同一渲染器）' ;;
    pi_lite_diag_tag)     printf '%s' '无法解析 mihomo 发布版本标签' ;;
    pi_lite_diag_tag_fix) printf '%s' '请检查镜像/网络，或在 .env 中固定 MIHOMO_VERSION' ;;
    pi_lite_fetch_bin)    printf '%s' '正在下载并校验 mihomo 二进制（%s）' ;;
    pi_lite_ok_bin)       printf '%s' 'mihomo 二进制 %s 已安装（校验梯全部通过）' ;;
    pi_lite_diag_bin)     printf '%s' 'mihomo 二进制未通过下载/校验梯' ;;
    pi_lite_diag_bin_fix) printf '%s' '请检查镜像，或将发布的 .gz 手动放入数据目录的 bin/ 下（见 Pi 指南）' ;;
    pi_lite_fetch_ui)     printf '%s' '正在下载 MetaCubexD 面板（compressed-dist.tgz）' ;;
    pi_lite_ok_ui)        printf '%s' '面板已安装 - mihomo 将在控制器端口的 /ui 提供访问' ;;
    pi_lite_diag_ui)      printf '%s' '面板压缩包下载失败或目录结构无法识别' ;;
    pi_lite_diag_ui_fix)  printf '%s' '请检查镜像，或将 compressed-dist.tgz 手动放入数据目录的 ui/ 下' ;;
    pi_lite_diag_unit)    printf '%s' '无法写入 systemd 服务文件' ;;
    pi_lite_diag_unit_fix) printf '%s' '请检查 /etc/systemd/system 的权限（以 root 运行）' ;;
    pi_lite_info_start)   printf '%s' '正在启用并启动 mihomo-gateway.service' ;;
    pi_lite_diag_start)   printf '%s' 'mihomo-gateway.service 启动失败' ;;
    pi_lite_diag_start_fix) printf '%s' '排查命令：journalctl -u mihomo-gateway -n 50' ;;
    pi_lite_probe_ok)     printf '%s' '控制器已在本机回环端口应答 - mihomo 已启动' ;;
    pi_lite_probe_warn)   printf '%s' '控制器暂未应答 - 请检查：journalctl -u mihomo-gateway -n 50（53 端口冲突是最常见原因）' ;;
    pi_lite_rep_dashboard) printf '%s' '面板地址：http://%s:%s/ui' ;;
    pi_lite_rep_client)   printf '%s' '将局域网设备的网关 + DNS 指向 %s（本 Pi）' ;;
    pi_ok_schedule)       printf '%s' '计划：按设备系统时区每日 %s；日志时间戳时区 %s' ;;
    pi_ok_cron_installed) printf '%s' '已安装 crontab 条目 - 更新器将按保存的计划运行' ;;
    pi_warn_cron_tz)      printf '%s' '注意：cron 按本设备系统时区触发；UPDATE_TZ 仅影响任务内日志时间戳' ;;
    pi_ask_dryrun)        printf '%s' '现在运行一次更新器 dry-run（不做任何更改）' ;;
    pi_warn_cron_not_installed) printf '%s' '未安装 crontab 条目 - 自动更新尚未列入计划' ;;
    pi_ctl_usage)         printf '%s' '用法：sh scripts/pi/lite_ctl.sh {status|doctor|start|stop|update [--dry-run|--force]}' ;;
    pi_ctl_usage2)        printf '%s' '只读：status、doctor；需要 root：start、stop；update 会委托给精简模式自动更新器' ;;
    *) return 1 ;;
  esac
}

# msg KEY - pi tables first, stock catalog as the fallback (which itself prints
# an unknown key verbatim - loud + debuggable, never crashes).
msg() {
  case "$INSTALLER_LANG" in
    zh) _msg_zh_pi "$1" 2>/dev/null || _msg_zh "$1" ;;
    *)  _msg_en_pi "$1" 2>/dev/null || _msg_en "$1" ;;
  esac
}
