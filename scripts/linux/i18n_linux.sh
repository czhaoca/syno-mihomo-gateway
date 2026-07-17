#!/bin/sh
# i18n_linux.sh (scripts/linux) - generic-Linux phrasing overlay (epic
# generic-linux-port, DEC-A: delta overlay). Source AFTER i18n.sh AND
# i18n_pi.sh: msg() is redefined to consult the linux tables first, then the
# pi tables, then the stock catalog - so the ~60 shared pi_* keys stay
# single-sourced in i18n_pi.sh and ONLY the Pi-branded phrasings are overridden
# here (titles, entry-name hints, Pi-hardware/OS wording). install.sh and
# install-pi.sh never source this file. Like the other catalogs, the zh table
# carries literal UTF-8; EN and ZH templates MUST carry the same %s count in
# the same order, and the CI suite asserts en/zh key parity plus the
# delta-only invariant (every key here must exist in the pi table).

_msg_en_linux() {
  case "$1" in
    pi_title)             printf '%s' 'Mihomo Gateway - Linux installer' ;;
    pi_step_installer)    printf '%s' 'Linux installer' ;;
    pi_warn_armv6)        printf '%s' 'this is an ARMv6 device: best-effort ONLY - expect <= 30-40 Mbps, single-device or lab use' ;;
    pi_ack_declined)      printf '%s' 'sensible choice - a 64-bit (arm64/amd64) host makes a far better gateway' ;;
    pi_info_compose_armv7) printf '%s' 'compose mode needs a 64-bit OS (arm64): this system reports a 32-bit userland (armv7) and the dashboard image ships no arm/v7 build - install a 64-bit OS for compose, or use lite mode (works on 32-bit)' ;;
    pi_err_wlan_parent_fix) printf '%s' 'connect this host with an Ethernet cable and re-run, or use lite mode (works over Wi-Fi)' ;;
    pi_diag_lite_root_fix) printf '%s' 're-run: sudo sh ./install-linux.sh' ;;
    pi_warn_port53_fix)   printf '%s' 'disable systemd-resolved/dnsmasq or move it off port 53, then restart mihomo-gateway' ;;
    pi_lite_diag_bin_fix) printf '%s' 'check the mirror, or sideload the release .gz into the data bin/ dir (see the install guide)' ;;
    pi_lite_rep_client)   printf '%s' 'point LAN clients gateway + DNS at %s (this host)' ;;
    *) return 1 ;;
  esac
}

_msg_zh_linux() {
  case "$1" in
    pi_title)             printf '%s' 'Mihomo 网关 - Linux 安装程序' ;;
    pi_step_installer)    printf '%s' 'Linux 安装程序' ;;
    pi_warn_armv6)        printf '%s' '这是 ARMv6 设备：仅作尽力支持 - 预计吞吐不超过 30-40 Mbps，只适合单设备或实验用途' ;;
    pi_ack_declined)      printf '%s' '明智的选择 - 64 位（arm64/amd64）主机更适合做网关' ;;
    pi_info_compose_armv7) printf '%s' 'compose 模式需要 64 位系统（arm64）：当前系统是 32 位（armv7），且面板镜像没有 arm/v7 构建 - 安装 64 位系统后可用 compose，或使用精简模式（支持 32 位）' ;;
    pi_err_wlan_parent_fix) printf '%s' '请用网线连接本机后重试，或使用精简模式（支持 Wi-Fi）' ;;
    pi_diag_lite_root_fix) printf '%s' '请重新运行：sudo sh ./install-linux.sh' ;;
    pi_warn_port53_fix)   printf '%s' '停用 systemd-resolved/dnsmasq 或将其移出 53 端口，然后重启 mihomo-gateway' ;;
    pi_lite_diag_bin_fix) printf '%s' '请检查镜像，或将发布的 .gz 手动放入数据目录的 bin/ 下（见安装指南）' ;;
    pi_lite_rep_client)   printf '%s' '将局域网设备的网关 + DNS 指向 %s（本机）' ;;
    *) return 1 ;;
  esac
}

# msg KEY - linux tables first, then the pi tables, then the stock catalog
# (which itself prints an unknown key verbatim - loud + debuggable, never
# crashes). Same chaining shape as i18n_pi.sh's own msg() override.
msg() {
  case "$INSTALLER_LANG" in
    zh) _msg_zh_linux "$1" 2>/dev/null || _msg_zh_pi "$1" 2>/dev/null || _msg_zh "$1" ;;
    *)  _msg_en_linux "$1" 2>/dev/null || _msg_en_pi "$1" 2>/dev/null || _msg_en "$1" ;;
  esac
}

# Under the generic entry every rerun hint must name install-linux.sh. The pi
# overlay's sudo_rerun_hint delegates to pi_sudo_rerun_hint BY NAME at runtime
# (scripts/pi/preflight.sh), so redefining the latter here - sourced last -
# retargets every hint, including the ones inside captured/stock bodies,
# without touching scripts/pi/. Phrasing-only: same shape as the pi original.
pi_sudo_rerun_hint() {
  _lr_cmd="sh ./install-linux.sh"
  if have_sudo; then
    ui_say "      $(msgf rerun_root_sudo "$C_BOLD" "$_lr_cmd" "$C_RESET")"
  else
    ui_say "      $(msgf rerun_root_nosudo "$C_BOLD" "$_lr_cmd" "$C_RESET")"
  fi
}
