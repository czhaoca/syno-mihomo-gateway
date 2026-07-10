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
    pi_warn_acr_arch_fix) printf '%s' 'extend your docker-china-sync (or equivalent mirror pipeline) to publish %s images first, or pick the docker (upstream) source in the image wizard' ;;
    pi_err_wlan_parent)   printf '%s' 'the network parent %s is a wireless interface: macvlan over Wi-Fi is typically broken (driver/AP isolation) - compose mode needs wired Ethernet' ;;
    pi_err_wlan_parent_fix) printf '%s' 'connect the Pi with an Ethernet cable and re-run, or use lite mode (works over Wi-Fi)' ;;
    pi_info_lite_pending) printf '%s' 'bare-metal lite mode is coming in a later update of this bundle - Docker compose mode is available today' ;;
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
    pi_warn_acr_arch_fix) printf '%s' '请先扩展你的 docker-china-sync（或同类镜像同步）以发布 %s 镜像，或在镜像向导中选择 docker（上游）源' ;;
    pi_err_wlan_parent)   printf '%s' '网络父接口 %s 是无线网卡：Wi-Fi 上的 macvlan 通常不可用（驱动/AP 隔离）- compose 模式需要有线以太网' ;;
    pi_err_wlan_parent_fix) printf '%s' '请用网线连接 Pi 后重试，或使用精简模式（支持 Wi-Fi）' ;;
    pi_info_lite_pending) printf '%s' '裸机精简模式将在本安装包的后续更新中提供 - 目前可使用 Docker compose 模式' ;;
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
