#!/bin/sh
# i18n_linux.sh (scripts/linux) - generic-Linux phrasing overlay (epic
# generic-linux-port, DEC-A: delta overlay). Source AFTER i18n.sh AND
# i18n_pi.sh: msg() is redefined to consult the linux tables first, then the
# pi tables, then the stock catalog - so the ~60 shared pi_* keys stay
# single-sourced in i18n_pi.sh and ONLY the Pi-branded phrasings are overridden
# here (titles, entry-name hints, Pi-hardware/OS wording), plus the
# linux-NATIVE lx_* keys (#48: the macvlan-viability guard and the generic
# registry wizard - phrasing that exists on no other entry), plus the stock
# DSM/NAS-worded keys the generic path reaches (#53: preflight, wizards,
# flow_deploy diagnostics + report). install.sh and install-pi.sh never source
# this file. Like the other catalogs, the zh table carries literal UTF-8; EN
# and ZH templates MUST carry the same %s count in the same order, and the CI
# suite asserts en/zh key parity plus the delta-only invariant (every NON-lx_
# key here must exist in the pi table or the stock catalog).

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
    # Stock-catalog DSM/NAS keys the generic path reaches (#53) - same %s
    # arity and order as scripts/installer/i18n.sh.
    diag_no_docker_fix)   printf '%s' "Install Docker (with the compose v2 plugin) and make sure 'docker' is on PATH; if docker needs root, re-run with sudo" ;;
    diag_resolve_self_fix) printf '%s' "re-extract the bundle and run 'sh ./install-linux.sh' from inside it" ;;
    warn_arch)            printf '%s' "this host is '%s' but EXPECTED_ARCH=%s - mirror matching-arch images, or set EXPECTED_ARCH=%s in .env" ;;
    info_ip_suggest_scan) printf '%s' 'scanning the LAN for a free static IP near this host...' ;;
    q_web_port)           printf '%s' 'Dashboard port (published on this host)' ;;
    diag_pull_fail_fix)   printf '%s' 'confirm the image exists in your registry and this host can reach it' ;;
    diag_arch_mismatch_fix) printf '%s' "mirror a %s image, or set EXPECTED_ARCH to this host's arch in .env" ;;
    diag_auto_redirect)   printf '%s' 'TUN auto-redirect is incompatible with this host kernel/image' ;;
    rep_dashboard)        printf '%s' 'Dashboard (open from a LAN device that is NOT this host):' ;;
    rep_warn_isolation)   printf '%s' 'This host itself cannot reach %s (macvlan isolation) - always test from another device.' ;;
    rep_reach_test)       printf '%s' 'Verify from a LAN device (NOT this host - macvlan hides the IP from the host itself): curl http://%s:%s/version returns JSON. If it still times out from another device, see Troubleshooting.' ;;
    diag_pg_default_fix)  printf '%s' 'its COUNTRY_GROUPS regex in .env matches no node of this airport - fix the regex and Redeploy (sudo sh ./install-linux.sh); stopgap: pick another country in the dashboard Exit Country selector' ;;
    lx_warn_macvlan_virt) printf '%s' 'virtualized/cloud host detected (%s): macvlan children often cannot forward LAN traffic here (cloud VPCs filter unknown MACs; some hypervisor vswitches drop them)' ;;
    lx_warn_macvlan_virt_2) printf '%s' 'recommended: lite mode - it binds this host directly (no macvlan) and works wherever the host itself works' ;;
    lx_ask_macvlan_ack)   printf '%s' 'proceed with compose mode (macvlan) anyway?' ;;
    lx_steer_lite)        printf '%s' 'continuing in lite mode (re-run and acknowledge the warning to force macvlan)' ;;
    lx_images_where)      printf '%s' 'Container images can come from the upstream public registries (Docker Hub / ghcr.io, multi-arch - the right choice outside mainland China) or from your private Alibaba ACR mirror (mainland China; needs your own mirror pipeline).' ;;
    lx_images_opt_docker) printf '%s' 'docker - upstream public registries (default)' ;;
    lx_images_opt_acr)    printf '%s' 'acr - private Alibaba ACR mirror (mainland China)' ;;
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
    # Stock-catalog DSM/NAS keys the generic path reaches (#53) - see the en table.
    diag_no_docker_fix)   printf '%s' "请安装 Docker（含 compose v2 插件）并确保 'docker' 在 PATH 中；若 docker 需要 root，请用 sudo 重新运行" ;;
    diag_resolve_self_fix) printf '%s' "重新解压安装包，并在其内部运行 'sh ./install-linux.sh'" ;;
    warn_arch)            printf '%s' "本机架构为 '%s'，但 EXPECTED_ARCH=%s - 请镜像匹配架构的镜像，或在 .env 中设置 EXPECTED_ARCH=%s" ;;
    info_ip_suggest_scan) printf '%s' '正在扫描 LAN 上靠近本机的空闲静态 IP……' ;;
    q_web_port)           printf '%s' '仪表盘端口（在本机上发布）' ;;
    diag_pull_fail_fix)   printf '%s' '请确认镜像存在于你的仓库中，且本机能够访问它' ;;
    diag_arch_mismatch_fix) printf '%s' '请镜像一个 %s 架构的镜像，或在 .env 中将 EXPECTED_ARCH 设为本机的架构' ;;
    diag_auto_redirect)   printf '%s' 'TUN auto-redirect 与本机内核/镜像不兼容' ;;
    rep_dashboard)        printf '%s' '仪表盘（请从非本机的 LAN 设备打开）：' ;;
    rep_warn_isolation)   printf '%s' '本机自身无法访问 %s（macvlan 隔离）- 请始终从另一台设备测试。' ;;
    rep_reach_test)       printf '%s' '请从局域网设备（非本机——macvlan 使本机自身无法访问该 IP）验证：curl http://%s:%s/version 应返回 JSON。若从其他设备仍超时，请见故障排查。' ;;
    diag_pg_default_fix)  printf '%s' '该分组在 .env 中的 COUNTRY_GROUPS 正则匹配不到该机场的任何节点——修正正则后重新部署（sudo sh ./install-linux.sh）；应急：在面板 Exit Country 选择器中换一个国家' ;;
    lx_warn_macvlan_virt) printf '%s' '检测到虚拟化/云主机（%s）：macvlan 子接口在此类环境常无法转发局域网流量（云 VPC 会过滤未知 MAC；部分虚拟交换机会丢弃）' ;;
    lx_warn_macvlan_virt_2) printf '%s' '建议：精简模式 - 直接绑定本机（无需 macvlan），主机能用它就能用' ;;
    lx_ask_macvlan_ack)   printf '%s' '仍要使用 compose 模式（macvlan）吗？' ;;
    lx_steer_lite)        printf '%s' '已切换到精简模式（重新运行并确认警告可强制使用 macvlan）' ;;
    lx_images_where)      printf '%s' '容器镜像可来自上游公共仓库（Docker Hub / ghcr.io，多架构 - 中国大陆以外的正确选择），或你的私有阿里云 ACR 镜像仓库（中国大陆；需要自建镜像同步流水线）。' ;;
    lx_images_opt_docker) printf '%s' 'docker - 上游公共仓库（默认）' ;;
    lx_images_opt_acr)    printf '%s' 'acr - 私有阿里云 ACR 镜像仓库（中国大陆）' ;;
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
