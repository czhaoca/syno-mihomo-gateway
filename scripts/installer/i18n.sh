#!/bin/sh
# i18n.sh - bilingual (en/zh) string catalog for the installer. Sourced right
# after ui.sh. Every user-facing string in the installer routes through msg/msgf
# so INSTALLER_LANG flips the whole UI. POSIX/BusyBox-safe. ZERO identity strings.
INSTALLER_LANG="${INSTALLER_LANG:-en}"

# msg KEY -> print the (format) string for KEY in the current language to stdout.
# Unknown keys print the key itself (loud + debuggable), never crash.
msg() {
  case "$INSTALLER_LANG" in
    zh) _msg_zh "$1" ;;
    *)  _msg_en "$1" ;;
  esac
}
# msgf KEY [ARG...] -> printf the KEY template with positional args. EN and ZH
# templates MUST carry the same %s count in the same order.
msgf() {
  _k="$1"; shift
  # shellcheck disable=SC2059
  printf "$(msg "$_k")" "$@"
}
_msg_en() {
  case "$1" in
    # --- ui.sh defensive helpers (used before/around choose_language) ---
    quit)             printf '%s' 'Quit.' ;;
    warn_yn)          printf '%s' 'please answer y or n' ;;
    warn_num)         printf '%s' 'enter a number' ;;
    warn_range)       printf '%s' 'out of range' ;;
    invalid_value)    printf '%s' "invalid value: '%s'" ;;

    # --- install.sh (menu + entry) ---
    title)            printf '%s' 'Mihomo Gateway - guided installer' ;;
    menu_action)      printf '%s' 'Select an action' ;;
    menu_deploy)      printf '%s' 'Deploy the gateway (first run, end-to-end)' ;;
    menu_redeploy)    printf '%s' 'Deploy with the saved .env (edit settings or deploy as-is)' ;;
    menu_cron)        printf '%s' 'Set up automatic updates (cron)' ;;
    menu_modify)      printf '%s' 'Modify an existing deployment' ;;
    menu_quit)        printf '%s' 'Quit' ;;
    bye)              printf '%s' 'Bye.' ;;
    warn_deploy_unfinished)   printf '%s' 'deploy did not finish - fix the issue above, then choose Deploy again' ;;
    warn_redeploy_unfinished) printf '%s' 'deploy did not finish - see the message above' ;;
    warn_cron_unfinished)     printf '%s' 'cron setup did not finish' ;;
    step_installer)   printf '%s' 'Mihomo Gateway installer' ;;
    info_check_loc)   printf '%s' "checking this folder's location..." ;;
    err_loc_blocked)  printf '%s' 'cannot continue until the folder location is fixed (see above).' ;;
    warn_not_root)    printf '%s' 'you are not root. The deploy and network steps need root' ;;
    warn_not_root2)   printf '%s' '(create /dev/net/tun, the macvlan network, and run docker).' ;;

    # --- preflight.sh ---
    rerun_root_sudo)  printf '%s' 'Re-run as root:  %ssudo %s%s' ;;
    rerun_root_nosudo) printf '%s' 'Re-run as the root user (no sudo found): %s%s%s' ;;
    rerun_dsm_hint)   printf '%s' "On DSM: enable SSH, log in, then 'sudo -i' (admin) before running." ;;
    diag_resolve_self)       printf '%s' "cannot resolve the installer's own folder" ;;
    diag_resolve_self_fix)   printf '%s' "re-extract the bundle and run 'sh ./install.sh' from inside it" ;;
    diag_no_docker_root)     printf '%s' 'could not find a Docker shared folder (looked for /volume*/docker)' ;;
    diag_no_docker_root_fix) printf '%s' "In DSM, install Container Manager (or Docker) so the 'docker' shared folder exists, then move this folder into it. Override the path with DOCKER_ROOT=/path sh ./install.sh" ;;
    ok_docker_root)   printf '%s' 'Docker shared folder: %s' ;;
    err_not_under)    printf '%s' 'this folder is NOT under the Docker shared folder.' ;;
    loc_here)         printf '%s' 'here:   %s' ;;
    loc_docker)       printf '%s' 'docker: %s' ;;
    loc_move_hint)    printf '%s' 'Move it there, then re-run from the new location:' ;;
    loc_move_fs)      printf '%s' "Or in File Station: move this folder into the 'docker' shared folder, then re-open it here." ;;
    err_not_writable) printf '%s' 'this folder is not writable by the current user (%s).' ;;
    loc_fix_perm)     printf '%s' 'Fix ownership/permissions, e.g.:' ;;
    ok_location)      printf '%s' 'location OK: %s' ;;
    ok_docker_compose) printf '%s' 'docker + compose detected' ;;
    diag_no_docker)   printf '%s' 'Docker or docker compose is not available' ;;
    diag_no_docker_fix) printf '%s' "Install/enable Container Manager (DSM) and make sure 'docker' is on PATH; if docker needs root, re-run with sudo" ;;
    warn_arch)        printf '%s' "this NAS is '%s' but EXPECTED_ARCH=%s - mirror matching-arch images, or set EXPECTED_ARCH=%s in .env" ;;
    ok_arch)          printf '%s' 'architecture: %s' ;;

    # --- netscan.sh ---
    net_ifaces)       printf '%s' 'Network interfaces on this host:' ;;
    net_auto_mark)    printf '%s' '  <- auto-detected (recommended)' ;;
    net_manual_entry) printf '%s' '(type an interface name manually)' ;;
    net_choose)       printf '%s' 'Choose the LAN interface for mihomo' ;;
    net_iface_name)   printf '%s' 'Interface name' ;;
    warn_iface_absent) printf '%s' "interface '%s' is not present on this host right now" ;;
    ask_use_anyway)   printf '%s' 'use it anyway?' ;;
    diag_no_iface)    printf '%s' 'no interface chosen' ;;
    diag_no_iface_fix) printf '%s' 're-run and pick a number, or type a valid interface name' ;;
    ok_iface)         printf '%s' 'interface: %s' ;;
    warn_ovs_macvlan) printf '%s' "'%s' is an Open vSwitch port - a macvlan on it is reachable by the router but NOT by other LAN devices, so the dashboard and the gateway will time out from clients." ;;
    ask_use_ipvlan)   printf '%s' 'Use the ipvlan driver instead (recommended for Open vSwitch)?' ;;
    info_ipvlan_set)  printf '%s' 'using the ipvlan L2 driver for the gateway network' ;;
    info_ovs_manual)  printf '%s' 'keeping macvlan - if clients cannot reach the gateway, disable Open vSwitch and use the physical NIC (see Troubleshooting)' ;;
    warn_ip_taken)    printf '%s' 'IP %s already answers on the LAN - likely used by another device (DHCP?).' ;;
    ask_use_ip)       printf '%s' 'use %s anyway?' ;;
    info_ip_unverified) printf '%s' 'could not verify %s is free (no ping/arping here) - make sure it is unused' ;;
    step_net_iface)   printf '%s' 'Network interface' ;;
    ok_router_gw)     printf '%s' 'router (gateway): %s' ;;
    ok_lan_subnet)    printf '%s' 'LAN subnet: %s' ;;
    info_net_partial) printf '%s' 'could not auto-derive every network setting - confirm/edit them in the next step' ;;
    step_create_net)  printf '%s' 'Create the network (TUN device + macvlan)' ;;
    warn_net_need_root) printf '%s' 'creating /dev/net/tun and the macvlan network requires root.' ;;
    diag_no_net_params) printf '%s' 'ROUTER_IP / SUBNET_CIDR not set' ;;
    diag_no_net_params_fix) printf '%s' 'run the network scan + configuration steps first' ;;
    diag_no_iface_sel) printf '%s' 'no network interface selected' ;;
    diag_no_iface_sel_fix) printf '%s' 'run the network scan step first' ;;
    diag_ip_in_use)   printf '%s' 'deploy aborted: %s is in use' ;;
    diag_ip_in_use_fix) printf '%s' 'pick a free IP via Modify/Redeploy, then try again' ;;
    diag_tun_fail)    printf '%s' 'could not prepare /dev/net/tun' ;;
    diag_tun_fail_fix) printf '%s' 'run the installer as root (sudo)' ;;
    ok_macvlan)       printf '%s' 'macvlan network ready (parent=%s)' ;;
    diag_macvlan_fail) printf '%s' "failed to create the macvlan network on '%s'" ;;
    diag_macvlan_fail_fix) printf '%s' "confirm ROUTER_IP/SUBNET_CIDR in .env match this LAN, that '%s' is the LAN-facing NIC, and that no container still holds the old network" ;;

    # --- wizards.sh ---
    step_seed)        printf '%s' 'Preparing configuration files' ;;
    ok_env_keep)      printf '%s' '.env exists - keeping your settings' ;;
    ok_env_created)   printf '%s' 'created .env from the template (chmod 600)' ;;
    diag_env_create)  printf '%s' 'could not create .env' ;;
    diag_env_create_fix) printf '%s' 'check write permission on this folder' ;;
    diag_no_example)  printf '%s' '.env.example is missing' ;;
    diag_no_example_fix) printf '%s' 're-extract the release bundle' ;;
    ok_sub_created)   printf '%s' 'created config/subscription.txt from the template' ;;
    step_env)         printf '%s' 'Network & DNS configuration' ;;
    q_router)         printf '%s' 'Router / Gateway IP' ;;
    q_subnet)         printf '%s' 'Home LAN subnet (CIDR)' ;;
    q_mihomo_ip)      printf '%s' 'Static LAN IP for mihomo (must be unused)' ;;
    info_ip_suggest_scan) printf '%s' 'scanning the LAN for a free static IP near the NAS...' ;;
    q_web_port)       printf '%s' 'Dashboard port (published on the NAS)' ;;
    warn_port_in_use) printf '%s' 'port %s looks already in use - pick another if the dashboard fails to start' ;;
    q_controller_port) printf '%s' 'Mihomo controller port' ;;
    q_controller_secret) printf '%s' 'Controller secret (Enter for no auth)' ;;
    warn_secret_pipe) printf '%s' "the secret must not contain a '|' character" ;;
    q_dns_bootstrap)  printf '%s' 'Bootstrap DNS (comma-separated)' ;;
    q_dns_domestic)   printf '%s' 'Domestic DNS (comma-separated)' ;;
    q_dns_fallback)   printf '%s' 'Overseas / fallback DNS (comma-separated)' ;;
    q_tz)             printf '%s' 'Timezone' ;;
    ok_env_saved)     printf '%s' 'saved network & DNS settings to .env' ;;
    step_images)      printf '%s' 'Container image source' ;;
    images_where)     printf '%s' 'Where should the gateway pull its container images from?' ;;
    images_choose)    printf '%s' 'Choose' ;;
    images_opt_acr)   printf '%s' 'Alibaba ACR mirror (recommended for mainland China)' ;;
    images_opt_docker) printf '%s' 'Docker Hub / ghcr upstream (BLOCKED in mainland China)' ;;
    warn_docker_blocked) printf '%s' 'Docker Hub and ghcr.io are unreachable behind the mainland-China firewall.' ;;
    ask_unfiltered)   printf '%s' 'Does this NAS have UNFILTERED internet (not behind the GFW)?' ;;
    warn_keep_acr)    printf '%s' 'keeping the ACR mirror as the image source' ;;
    q_acr_host)       printf '%s' 'ACR registry host (e.g. registry.cn-shenzhen.aliyuncs.com)' ;;
    q_acr_namespace)  printf '%s' 'ACR namespace' ;;
    q_acr_username)   printf '%s' 'ACR username' ;;
    q_acr_password)   printf '%s' 'ACR password / access token (Enter to keep existing)' ;;
    q_mihomo_tag)     printf '%s' 'mihomo image tag' ;;
    q_metacubexd_tag) printf '%s' 'metacubexd image tag' ;;
    diag_derive_images) printf '%s' 'could not derive image references' ;;
    diag_derive_images_fix) printf '%s' 'ACR mode needs the registry host AND namespace set' ;;
    ok_images)        printf '%s' 'images: %s' ;;
    ok_images_cont)   printf '%s' '        %s' ;;
    ask_cloudflared)  printf '%s' 'Also manage a cloudflared tunnel container? (advanced, optional)' ;;
    q_cf_tag)         printf '%s' 'cloudflared image tag' ;;
    ok_cf_image)      printf '%s' 'cloudflared image: %s' ;;
    q_cf_token)       printf '%s' 'cloudflared tunnel token (Enter to reuse the running one)' ;;
    q_cf_token_new)   printf '%s' 'cloudflared tunnel token (required - no running tunnel to reuse)' ;;
    info_cf_detected) printf '%s' "detected a running cloudflared container '%s' - press Enter to reuse its tunnel token" ;;
    warn_cf_token_required) printf '%s' 'a tunnel token is required to provision the first cloudflared container' ;;
    step_sub)         printf '%s' 'Airport / subscription URL' ;;
    sub_current)      printf '%s' 'current: %s' ;;
    ask_replace_sub)  printf '%s' 'replace the existing subscription URL?' ;;
    ok_sub_kept)      printf '%s' 'kept the existing subscription' ;;
    q_sub_url)        printf '%s' 'Subscription URL (paste it; you will confirm it next)' ;;
    warn_sub_required) printf '%s' 'a subscription URL is required' ;;
    warn_sub_scheme)  printf '%s' 'the URL must start with http:// or https://' ;;
    sub_confirm)      printf '%s' 'captured: %s' ;;
    ask_sub_ok)       printf '%s' 'is this URL correct and complete (not truncated)?' ;;
    ok_sub_saved)     printf '%s' 'subscription saved' ;;
    diag_sub_write)   printf '%s' 'could not write %s' ;;
    diag_sub_write_fix) printf '%s' 'check that this folder is writable' ;;

    # --- preprocess.sh ---
    step_preprocess)  printf '%s' 'Pre-deployment resource handling' ;;
    step_apply_preprocess) printf '%s' 'Apply pre-deployment choices' ;;
    prep_container_state) printf '%s' 'containers: mihomo=%s, dashboard=%s' ;;
    prep_network_state) printf '%s' 'network %s: %s' ;;
    prep_network_attached) printf '%s' 'attached containers: %s' ;;
    prep_net_match)    printf '%s' 'matches the requested macvlan' ;;
    prep_net_drift)    printf '%s' 'configuration differs from the requested macvlan' ;;
    prep_net_absent)   printf '%s' 'not present' ;;
    prep_containers_prompt) printf '%s' 'How should existing gateway containers be handled?' ;;
    prep_network_prompt) printf '%s' 'How should the existing macvlan be handled?' ;;
    prep_preserve)     printf '%s' 'Preserve and reuse it' ;;
    prep_auto)         printf '%s' 'Dismantle automatically after validation' ;;
    prep_manual)       printf '%s' 'I will handle it manually' ;;
    prep_ambiguous)    printf '%s' 'a canonical container name is not verifiably owned by this project; automatic cleanup is blocked' ;;
    prep_unrelated)    printf '%s' 'the macvlan has an unrelated attachment; automatic cleanup is blocked' ;;
    prep_drift_requires_cleanup) printf '%s' 'a mismatched macvlan cannot be reused; choose automatic or manual cleanup' ;;
    prep_network_needs_containers) printf '%s' 'remove the attached gateway containers automatically too, or handle the network manually' ;;
    prep_manual_commands) printf '%s' 'Run and review these commands in another terminal:' ;;
    prep_rescan)       printf '%s' 'Have you completed the manual cleanup and want to rescan now?' ;;
    prep_manual_pending) printf '%s' 'manual pre-deployment cleanup is still pending' ;;
    prep_manual_fix)   printf '%s' 'inspect/remove only the listed resources, then run the installer again' ;;
    prep_applied)      printf '%s' 'pre-deployment resource choices applied' ;;

    # --- flow_deploy.sh ---
    step_deploy_stack) printf '%s' 'Deploy the stack' ;;
    step_reprovision) printf '%s' 'Validate existing containers' ;;
    reprov_found)     printf '%s' '  found managed container %s (%s)' ;;
    reprov_done)      printf '%s' 'existing container ownership is valid; Compose will recreate it safely' ;;
    reprov_none)      printf '%s' 'no existing named containers' ;;
    diag_acr_login)   printf '%s' 'ACR login failed' ;;
    diag_acr_login_fix) printf '%s' 'check DOCKER_USERNAME / ACR_PASSWORD (token expiry?) in .env' ;;
    info_skip_login)  printf '%s' 'REGISTRY_MODE=docker - skipping registry login (public images)' ;;
    info_pulling)     printf '%s' 'pulling %s' ;;
    diag_pull_fail)   printf '%s' 'could not pull %s' ;;
    diag_pull_fail_fix) printf '%s' 'confirm the image exists in your registry and the NAS can reach it' ;;
    diag_arch_mismatch) printf '%s' 'image arch mismatch for %s' ;;
    diag_arch_mismatch_fix) printf '%s' "mirror a %s image, or set EXPECTED_ARCH to this NAS's arch in .env" ;;
    diag_auto_redirect) printf '%s' 'TUN auto-redirect is incompatible with this DSM kernel/image' ;;
    diag_auto_redirect_fix) printf '%s' 'set TUN_AUTO_REDIRECT=false in .env; TUN auto-route remains enabled' ;;
    info_starting)    printf '%s' 'starting containers (docker compose up -d)' ;;
    info_log_tail)    printf '%s' '--- last lines of the deploy log (the actual error) ---' ;;
    info_mihomo_logs) printf '%s' '--- docker logs mihomo (the actual crash reason) ---' ;;
    warn_no_sub)      printf '%s' 'no subscription URL is configured yet - mihomo needs one to start' ;;
    diag_compose_up)  printf '%s' 'docker compose up -d failed' ;;
    diag_compose_up_fix) printf '%s' 'review the output above and %s; verify the macvlan network and .env image refs' ;;
    ok_mihomo_healthy) printf '%s' 'mihomo is running and healthy' ;;
    diag_unhealthy)   printf '%s' 'mihomo did not become healthy' ;;
    diag_unhealthy_fix) printf '%s' "see the mihomo log above; check subscription/DNS/geo-data errors and any TUN or iptables failure" ;;
    info_egress_test) printf '%s' 'testing internet egress through the proxy (GET %s) ...' ;;
    ok_egress)        printf '%s' 'egress OK - reached the test URL through the proxy (%s ms)' ;;
    diag_egress)      printf '%s' 'the gateway is up, but it could NOT reach the internet through %s (the nodes time out)' ;;
    diag_egress_fix)  printf '%s' 'your subscription may be expired or its nodes down/blocked from this network - open the dashboard (Proxies -> test the nodes), pick a working node, or update the subscription URL, then redeploy' ;;
    info_egress_skip) printf '%s' 'egress test skipped (no wget/curl in the mihomo image)' ;;
    step_deploy_done) printf '%s' 'Deployment complete' ;;
    ok_gateway_up)    printf '%s' 'The gateway is up.' ;;
    rep_dashboard)    printf '%s' 'Dashboard (open from a LAN device that is NOT the NAS):' ;;
    rep_dashboard_url) printf '%s' '    http://<NAS-IP>:%s' ;;
    rep_add_backend)  printf '%s' '  Add a backend in the dashboard:' ;;
    rep_backend_line) printf '%s' '    Host=%s  Port=%s  Secret=<your controller secret>' ;;
    rep_point_client) printf '%s' "Point a client's gateway + DNS at %s to route it through the proxy." ;;
    rep_warn_isolation) printf '%s' 'The NAS itself cannot reach %s (macvlan isolation) - always test from another device.' ;;
    rep_reach_test)   printf '%s' 'Verify from a LAN device: curl http://%s:%s/version returns JSON. If it times out, the IP is unreachable (Open vSwitch? set TPROXY_DRIVER=ipvlan and redeploy) - see Troubleshooting.' ;;
    rep_next)         printf '%s' 'Next: set up automatic image updates from the main menu (option 2).' ;;
    step_deploy_e2e)  printf '%s' 'End-to-end deploy' ;;

    # --- flow_cron.sh ---
    cron_need_root)   printf '%s' 'installing a crontab line needs root.' ;;
    diag_no_crontab)  printf '%s' '%s not found (not a cron/DSM host?)' ;;
    diag_no_crontab_fix) printf '%s' 'use the DSM Task Scheduler settings instead' ;;
    ok_cron_exists)   printf '%s' 'an auto-update line already exists in %s - not adding a duplicate' ;;
    ok_cron_installed) printf '%s' 'fallback crontab line installed and crond reloaded' ;;
    warn_cron_reload) printf '%s' 'line added to %s but crond reload failed - use DSM Task Scheduler instead' ;;
    warn_cron_tz)     printf '%s' 'note: BusyBox crond fires in the NAS SYSTEM timezone (it ignores a per-line TZ); set the NAS time correctly. UPDATE_TZ only affects in-job log timestamps.' ;;
    diag_cron_write)  printf '%s' 'could not write to %s' ;;
    diag_cron_write_fix) printf '%s' 'run as root (sudo)' ;;
    step_cron)        printf '%s' 'Automatic update (cron) setup' ;;
    diag_no_env)      printf '%s' '.env not found' ;;
    diag_no_env_fix)  printf '%s' 'run the end-to-end deploy first (main menu option 1)' ;;
    q_daily_time)     printf '%s' 'Daily update time (HH:MM, 24h)' ;;
    cron_tz_prompt)   printf '%s' 'Timezone for updater log timestamps (DSM triggers in NAS timezone)' ;;
    cron_tz_other)    printf '%s' 'Other (type it)' ;;
    q_tz_freeform)    printf '%s' 'Timezone (e.g. Asia/Singapore)' ;;
    ask_enable_updates) printf '%s' 'Enable automatic updates?' ;;
    warn_updates_disabled) printf '%s' 'auto-updates disabled (UPDATE_ENABLED=false) - the job will no-op until re-enabled' ;;
    ok_schedule)      printf '%s' 'schedule: daily at %s in NAS system timezone; log timezone %s' ;;
    cron_how)         printf '%s' 'How do you want to schedule it?' ;;
    cron_how_dsm)     printf '%s' 'Set it up via the DSM web UI (Task Scheduler) - recommended' ;;
    cron_how_cli)     printf '%s' 'Install a crontab entry now (CLI; DSM may overwrite it on upgrade)' ;;
    cron_how_dry)     printf '%s' 'Validate now with a dry-run (pulls cache; does not swap containers)' ;;
    cron_how_done)    printf '%s' 'Done' ;;
    step_dsm_sched)   printf '%s' 'Synology DSM Task Scheduler settings' ;;
    warn_cron_not_installed) printf '%s' 'fallback crontab not installed - use the DSM web UI instead' ;;
    info_dry_run)     printf '%s' 'running: scripts/auto_update.sh --dry-run' ;;
    warn_dry_run_nonzero) printf '%s' 'dry-run exited non-zero - review the output above (this does not change the deploy)' ;;
    ok_cron_complete) printf '%s' 'cron setup complete. The DSM Task Scheduler (web UI) is the recommended, upgrade-persistent method.' ;;

    # --- flow_modify.sh ---
    step_apply)       printf '%s' 'Apply changes (redeploy)' ;;
    warn_nothing_deployed) printf '%s' 'nothing is deployed yet - use the end-to-end deploy (main menu option 1) instead' ;;
    warn_acr_login_soft) printf '%s' 'ACR login failed - a changed image may fail to pull' ;;
    info_redeploying) printf '%s' 'redeploying (docker compose up -d; re-renders config, pulls changed images)' ;;
    ok_applied)       printf '%s' 'applied + healthy' ;;
    warn_health_rollback) printf '%s' 'health gate failed - rolling back to the last-good images' ;;
    warn_rolled_back) printf '%s' 'rolled back to last-good (now healthy) - your change was NOT applied' ;;
    diag_rollback_fail) printf '%s' 'redeploy failed AND rollback incomplete' ;;
    diag_rollback_fail_fix) printf '%s' "inspect 'docker ps -a' and 'docker logs mihomo'; manual recovery may be needed" ;;
    step_modify)      printf '%s' 'Modify existing configuration' ;;
    info_stack_state) printf '%s' 'current stack state: %s' ;;
    modify_what)      printf '%s' 'What do you want to change?' ;;
    modify_net)       printf '%s' 'Network & DNS settings (.env wizard)' ;;
    modify_images)    printf '%s' 'Image source / registry / tags' ;;
    modify_sub)       printf '%s' 'Subscription URL' ;;
    modify_rerun_net) printf '%s' 'Re-run network setup (interface / macvlan)' ;;
    modify_apply)     printf '%s' 'Apply changes now (redeploy with rollback)' ;;
    modify_back)      printf '%s' 'Back to main menu' ;;

    # --- flow_redeploy.sh ---
    step_redeploy)    printf '%s' 'Deploy with the saved .env' ;;
    diag_no_env_redeploy) printf '%s' '.env not found - nothing to redeploy' ;;
    redeploy_current) printf '%s' 'Current configuration:' ;;
    redeploy_iface)   printf '%s' '  interface : %s' ;;
    redeploy_iface_auto) printf '%s' '(auto-detect)' ;;
    redeploy_router)  printf '%s' '  router    : %s' ;;
    redeploy_subnet)  printf '%s' '  subnet    : %s' ;;
    redeploy_mihomo)  printf '%s' '  mihomo IP : %s' ;;
    redeploy_images)  printf '%s' '  images    : %s' ;;
    redeploy_sub)     printf '%s' '  subscription : %s' ;;
    redeploy_sub_none) printf '%s' '(not set)' ;;
    precheck_step)    printf '%s' 'Validating the saved configuration' ;;
    precheck_bad)     printf '%s' '%s in .env is missing or invalid: "%s" - please re-enter it' ;;
    precheck_images)  printf '%s' 'image references are not set in .env - re-running the image step' ;;
    precheck_ok)      printf '%s' 'saved configuration looks valid' ;;
    warn_sub_dirty)   printf '%s' 'the saved subscription URL looks garbled (stray characters / bad paste)' ;;
    redeploy_what)    printf '%s' 'What do you want to do?' ;;
    redeploy_asis)    printf '%s' 'Deploy now (use the saved .env as-is)' ;;
    redeploy_edit)    printf '%s' 'Edit settings (network / DNS / ports), then deploy' ;;
    redeploy_change_ip) printf '%s' "Change mihomo's LAN IP, then deploy" ;;
    redeploy_repick)  printf '%s' 'Re-pick the network interface, then deploy' ;;
    q_new_mihomo_ip)  printf '%s' 'New static LAN IP for mihomo (must be unused)' ;;

    *)                printf '%s' "$1" ;;
  esac
}
_msg_zh() {
  case "$1" in
    # --- ui.sh defensive helpers (used before/around choose_language) ---
    quit)             printf '%s' '已退出。' ;;
    warn_yn)          printf '%s' '请输入 y 或 n' ;;
    warn_num)         printf '%s' '请输入一个数字' ;;
    warn_range)       printf '%s' '超出范围' ;;
    invalid_value)    printf '%s' "无效的值：'%s'" ;;

    # --- install.sh (menu + entry) ---
    title)            printf '%s' 'Mihomo 网关 - 引导式安装程序' ;;
    menu_action)      printf '%s' '请选择操作' ;;
    menu_deploy)      printf '%s' '部署网关（首次运行，端到端）' ;;
    menu_redeploy)    printf '%s' '使用已保存的 .env 部署（可编辑设置或按原样部署）' ;;
    menu_cron)        printf '%s' '设置自动更新（cron）' ;;
    menu_modify)      printf '%s' '修改现有部署' ;;
    menu_quit)        printf '%s' '退出' ;;
    bye)              printf '%s' '再见。' ;;
    warn_deploy_unfinished)   printf '%s' '部署未完成 - 请修复上面的问题后再次选择"部署"' ;;
    warn_redeploy_unfinished) printf '%s' '部署未完成 - 请查看上面的提示' ;;
    warn_cron_unfinished)     printf '%s' 'cron 设置未完成' ;;
    step_installer)   printf '%s' 'Mihomo 网关安装程序' ;;
    info_check_loc)   printf '%s' '正在检查此文件夹的位置...' ;;
    err_loc_blocked)  printf '%s' '文件夹位置修复前无法继续（见上文）。' ;;
    warn_not_root)    printf '%s' '当前不是 root 用户。部署和网络步骤需要 root 权限' ;;
    warn_not_root2)   printf '%s' '（创建 /dev/net/tun、macvlan 网络并运行 docker）。' ;;

    # --- preflight.sh ---
    rerun_root_sudo)  printf '%s' '以 root 身份重新运行：  %ssudo %s%s' ;;
    rerun_root_nosudo) printf '%s' '以 root 用户身份重新运行（未找到 sudo）：%s%s%s' ;;
    rerun_dsm_hint)   printf '%s' "在 DSM 上：启用 SSH，登录后先执行 'sudo -i'（管理员）再运行。" ;;
    diag_resolve_self)       printf '%s' '无法定位安装程序自身所在的文件夹' ;;
    diag_resolve_self_fix)   printf '%s' "重新解压安装包，并在其内部运行 'sh ./install.sh'" ;;
    diag_no_docker_root)     printf '%s' '找不到 Docker 共享文件夹（已查找 /volume*/docker）' ;;
    diag_no_docker_root_fix) printf '%s' "在 DSM 中安装 Container Manager（或 Docker），以创建 'docker' 共享文件夹，然后把本文件夹移入其中。可用 DOCKER_ROOT=/path sh ./install.sh 覆盖路径" ;;
    ok_docker_root)   printf '%s' 'Docker 共享文件夹：%s' ;;
    err_not_under)    printf '%s' '此文件夹不在 Docker 共享文件夹之下。' ;;
    loc_here)         printf '%s' '当前：   %s' ;;
    loc_docker)       printf '%s' 'docker： %s' ;;
    loc_move_hint)    printf '%s' '请将其移动到那里，然后从新位置重新运行：' ;;
    loc_move_fs)      printf '%s' "或在 File Station 中：将本文件夹移入 'docker' 共享文件夹，然后在新位置重新打开。" ;;
    err_not_writable) printf '%s' '当前用户（%s）对此文件夹没有写入权限。' ;;
    loc_fix_perm)     printf '%s' '请修复归属/权限，例如：' ;;
    ok_location)      printf '%s' '位置正常：%s' ;;
    ok_docker_compose) printf '%s' '已检测到 docker + compose' ;;
    diag_no_docker)   printf '%s' 'Docker 或 docker compose 不可用' ;;
    diag_no_docker_fix) printf '%s' "安装/启用 Container Manager（DSM）并确保 'docker' 在 PATH 中；若 docker 需要 root，请用 sudo 重新运行" ;;
    warn_arch)        printf '%s' "此 NAS 架构为 '%s'，但 EXPECTED_ARCH=%s - 请镜像匹配架构的镜像，或在 .env 中设置 EXPECTED_ARCH=%s" ;;
    ok_arch)          printf '%s' '架构：%s' ;;

    # --- netscan.sh ---
    net_ifaces)       printf '%s' '此主机上的网络接口：' ;;
    net_auto_mark)    printf '%s' '  <- 自动检测（推荐）' ;;
    net_manual_entry) printf '%s' '（手动输入接口名称）' ;;
    net_choose)       printf '%s' '为 mihomo 选择 LAN 接口' ;;
    net_iface_name)   printf '%s' '接口名称' ;;
    warn_iface_absent) printf '%s' "接口 '%s' 当前不在此主机上" ;;
    ask_use_anyway)   printf '%s' '仍要使用它吗？' ;;
    diag_no_iface)    printf '%s' '未选择任何接口' ;;
    diag_no_iface_fix) printf '%s' '请重新运行并选择一个编号，或输入有效的接口名称' ;;
    ok_iface)         printf '%s' '接口：%s' ;;
    warn_ovs_macvlan) printf '%s' "'%s' 是 Open vSwitch 端口——其上的 macvlan 路由器可达，但其他局域网设备无法访问，因此仪表盘和网关会从客户端超时。" ;;
    ask_use_ipvlan)   printf '%s' '改用 ipvlan 驱动（Open vSwitch 推荐）？' ;;
    info_ipvlan_set)  printf '%s' '网关网络改用 ipvlan L2 驱动' ;;
    info_ovs_manual)  printf '%s' '保持 macvlan——若客户端无法访问网关，请关闭 Open vSwitch 并改用物理网卡（见故障排查）' ;;
    warn_ip_taken)    printf '%s' 'IP %s 已在 LAN 上有响应 - 很可能被其他设备占用（DHCP？）。' ;;
    ask_use_ip)       printf '%s' '仍要使用 %s 吗？' ;;
    info_ip_unverified) printf '%s' '无法验证 %s 是否空闲（此处无 ping/arping）- 请确保它未被占用' ;;
    step_net_iface)   printf '%s' '网络接口' ;;
    ok_router_gw)     printf '%s' '路由器（网关）：%s' ;;
    ok_lan_subnet)    printf '%s' 'LAN 子网：%s' ;;
    info_net_partial) printf '%s' '无法自动推导出全部网络设置 - 请在下一步确认/编辑' ;;
    step_create_net)  printf '%s' '创建网络（TUN 设备 + macvlan）' ;;
    warn_net_need_root) printf '%s' '创建 /dev/net/tun 和 macvlan 网络需要 root 权限。' ;;
    diag_no_net_params) printf '%s' 'ROUTER_IP / SUBNET_CIDR 未设置' ;;
    diag_no_net_params_fix) printf '%s' '请先运行网络扫描和配置步骤' ;;
    diag_no_iface_sel) printf '%s' '未选择任何网络接口' ;;
    diag_no_iface_sel_fix) printf '%s' '请先运行网络扫描步骤' ;;
    diag_ip_in_use)   printf '%s' '部署已中止：%s 正在被占用' ;;
    diag_ip_in_use_fix) printf '%s' '通过"修改/重新部署"选择一个空闲 IP，然后重试' ;;
    diag_tun_fail)    printf '%s' '无法准备 /dev/net/tun' ;;
    diag_tun_fail_fix) printf '%s' '请以 root 身份（sudo）运行安装程序' ;;
    ok_macvlan)       printf '%s' 'macvlan 网络就绪（parent=%s）' ;;
    diag_macvlan_fail) printf '%s' "在 '%s' 上创建 macvlan 网络失败" ;;
    diag_macvlan_fail_fix) printf '%s' "请确认 .env 中的 ROUTER_IP/SUBNET_CIDR 与此 LAN 匹配，'%s' 是面向 LAN 的网卡，且没有容器仍占用旧网络" ;;

    # --- wizards.sh ---
    step_seed)        printf '%s' '准备配置文件' ;;
    ok_env_keep)      printf '%s' '.env 已存在 - 保留你的设置' ;;
    ok_env_created)   printf '%s' '已从模板创建 .env（chmod 600）' ;;
    diag_env_create)  printf '%s' '无法创建 .env' ;;
    diag_env_create_fix) printf '%s' '请检查此文件夹的写入权限' ;;
    diag_no_example)  printf '%s' '缺少 .env.example' ;;
    diag_no_example_fix) printf '%s' '请重新解压发布安装包' ;;
    ok_sub_created)   printf '%s' '已从模板创建 config/subscription.txt' ;;
    step_env)         printf '%s' '网络与 DNS 配置' ;;
    q_router)         printf '%s' '路由器 / 网关 IP' ;;
    q_subnet)         printf '%s' '家庭 LAN 子网（CIDR）' ;;
    q_mihomo_ip)      printf '%s' 'mihomo 的静态 LAN IP（必须未被占用）' ;;
    info_ip_suggest_scan) printf '%s' '正在扫描 LAN 上靠近 NAS 的空闲静态 IP……' ;;
    q_web_port)       printf '%s' '仪表盘端口（在 NAS 上发布）' ;;
    warn_port_in_use) printf '%s' '端口 %s 似乎已被占用 - 若仪表盘启动失败请另选一个' ;;
    q_controller_port) printf '%s' 'Mihomo 控制器端口' ;;
    q_controller_secret) printf '%s' '控制器密钥（回车表示不鉴权）' ;;
    warn_secret_pipe) printf '%s' "密钥不能包含 '|' 字符" ;;
    q_dns_bootstrap)  printf '%s' '引导 DNS（逗号分隔）' ;;
    q_dns_domestic)   printf '%s' '国内 DNS（逗号分隔）' ;;
    q_dns_fallback)   printf '%s' '海外 / 回退 DNS（逗号分隔）' ;;
    q_tz)             printf '%s' '时区' ;;
    ok_env_saved)     printf '%s' '已将网络与 DNS 设置保存到 .env' ;;
    step_images)      printf '%s' '容器镜像来源' ;;
    images_where)     printf '%s' '网关应从何处拉取容器镜像？' ;;
    images_choose)    printf '%s' '请选择' ;;
    images_opt_acr)   printf '%s' '阿里云 ACR 镜像（推荐，适用于中国大陆）' ;;
    images_opt_docker) printf '%s' 'Docker Hub / ghcr 上游（中国大陆已屏蔽）' ;;
    warn_docker_blocked) printf '%s' '在中国大陆防火墙后，Docker Hub 和 ghcr.io 无法访问。' ;;
    ask_unfiltered)   printf '%s' '此 NAS 是否拥有无过滤的互联网访问（不在 GFW 之后）？' ;;
    warn_keep_acr)    printf '%s' '将继续使用 ACR 镜像作为镜像来源' ;;
    q_acr_host)       printf '%s' 'ACR 仓库地址（例如 registry.cn-shenzhen.aliyuncs.com）' ;;
    q_acr_namespace)  printf '%s' 'ACR 命名空间' ;;
    q_acr_username)   printf '%s' 'ACR 用户名' ;;
    q_acr_password)   printf '%s' 'ACR 密码 / 访问令牌（回车保留现有值）' ;;
    q_mihomo_tag)     printf '%s' 'mihomo 镜像 tag' ;;
    q_metacubexd_tag) printf '%s' 'metacubexd 镜像 tag' ;;
    diag_derive_images) printf '%s' '无法推导出镜像引用' ;;
    diag_derive_images_fix) printf '%s' 'ACR 模式需要同时设置仓库地址和命名空间' ;;
    ok_images)        printf '%s' '镜像：%s' ;;
    ok_images_cont)   printf '%s' '      %s' ;;
    ask_cloudflared)  printf '%s' '是否同时管理 cloudflared 隧道容器？（进阶，可选）' ;;
    q_cf_tag)         printf '%s' 'cloudflared 镜像 tag' ;;
    ok_cf_image)      printf '%s' 'cloudflared 镜像：%s' ;;
    q_cf_token)       printf '%s' 'cloudflared 隧道令牌（回车则复用正在运行的令牌）' ;;
    q_cf_token_new)   printf '%s' 'cloudflared 隧道令牌（必填——没有可复用的运行中隧道）' ;;
    info_cf_detected) printf '%s' "检测到正在运行的 cloudflared 容器 '%s' - 回车即可复用其隧道令牌" ;;
    warn_cf_token_required) printf '%s' '首次部署 cloudflared 容器时必须提供隧道令牌' ;;
    step_sub)         printf '%s' '机场 / 订阅链接' ;;
    sub_current)      printf '%s' '当前：%s' ;;
    ask_replace_sub)  printf '%s' '是否替换现有的订阅链接？' ;;
    ok_sub_kept)      printf '%s' '已保留现有订阅' ;;
    q_sub_url)        printf '%s' '订阅链接（粘贴后将让你确认）' ;;
    warn_sub_required) printf '%s' '必须填写订阅链接' ;;
    warn_sub_scheme)  printf '%s' '链接必须以 http:// 或 https:// 开头' ;;
    sub_confirm)      printf '%s' '已读取：%s' ;;
    ask_sub_ok)       printf '%s' '此链接是否正确且完整（没有被截断）？' ;;
    ok_sub_saved)     printf '%s' '订阅已保存' ;;
    diag_sub_write)   printf '%s' '无法写入 %s' ;;
    diag_sub_write_fix) printf '%s' '请检查此文件夹是否可写' ;;

    # --- preprocess.sh ---
    step_preprocess)  printf '%s' '部署前资源处理' ;;
    step_apply_preprocess) printf '%s' '执行部署前选择' ;;
    prep_container_state) printf '%s' '容器：mihomo=%s，面板=%s' ;;
    prep_network_state) printf '%s' '网络 %s：%s' ;;
    prep_network_attached) printf '%s' '已连接容器：%s' ;;
    prep_net_match)    printf '%s' '与所需 macvlan 配置一致' ;;
    prep_net_drift)    printf '%s' '与所需 macvlan 配置不同' ;;
    prep_net_absent)   printf '%s' '不存在' ;;
    prep_containers_prompt) printf '%s' '如何处理现有网关容器？' ;;
    prep_network_prompt) printf '%s' '如何处理现有 macvlan？' ;;
    prep_preserve)     printf '%s' '保留并复用' ;;
    prep_auto)         printf '%s' '校验完成后自动拆除' ;;
    prep_manual)       printf '%s' '由我手动处理' ;;
    prep_ambiguous)    printf '%s' '同名容器无法确认属于本项目，已禁止自动清理' ;;
    prep_unrelated)    printf '%s' 'macvlan 上连接了无关容器，已禁止自动清理' ;;
    prep_drift_requires_cleanup) printf '%s' '配置不匹配的 macvlan 无法复用，请选择自动或手动清理' ;;
    prep_network_needs_containers) printf '%s' '请同时自动移除已连接的网关容器，或手动处理网络' ;;
    prep_manual_commands) printf '%s' '请在另一个终端中检查并运行以下命令：' ;;
    prep_rescan)       printf '%s' '手动清理是否已完成并立即重新扫描？' ;;
    prep_manual_pending) printf '%s' '部署前的手动清理尚未完成' ;;
    prep_manual_fix)   printf '%s' '只检查/移除列出的资源，然后重新运行安装器' ;;
    prep_applied)      printf '%s' '已执行部署前资源选择' ;;

    # --- flow_deploy.sh ---
    step_deploy_stack) printf '%s' '部署服务栈' ;;
    step_reprovision) printf '%s' '校验现有容器' ;;
    reprov_found)     printf '%s' '  发现本项目容器 %s（%s）' ;;
    reprov_done)      printf '%s' '现有容器归属正确；Compose 将安全地重新创建' ;;
    reprov_none)      printf '%s' '没有同名的现有容器' ;;
    diag_acr_login)   printf '%s' 'ACR 登录失败' ;;
    diag_acr_login_fix) printf '%s' '请检查 .env 中的 DOCKER_USERNAME / ACR_PASSWORD（令牌是否过期？）' ;;
    info_skip_login)  printf '%s' 'REGISTRY_MODE=docker - 跳过仓库登录（公共镜像）' ;;
    info_pulling)     printf '%s' '正在拉取 %s' ;;
    diag_pull_fail)   printf '%s' '无法拉取 %s' ;;
    diag_pull_fail_fix) printf '%s' '请确认镜像存在于你的仓库中，且 NAS 能够访问它' ;;
    diag_arch_mismatch) printf '%s' '%s 的镜像架构不匹配' ;;
    diag_arch_mismatch_fix) printf '%s' '请镜像一个 %s 架构的镜像，或在 .env 中将 EXPECTED_ARCH 设为此 NAS 的架构' ;;
    diag_auto_redirect) printf '%s' 'TUN auto-redirect 与此 DSM 内核/镜像不兼容' ;;
    diag_auto_redirect_fix) printf '%s' '请在 .env 中设置 TUN_AUTO_REDIRECT=false；TUN auto-route 仍会保持启用' ;;
    info_starting)    printf '%s' '正在启动容器（docker compose up -d）' ;;
    info_log_tail)    printf '%s' '--- 部署日志的最后几行（真正的错误）---' ;;
    info_mihomo_logs) printf '%s' '--- docker logs mihomo（真正的崩溃原因）---' ;;
    warn_no_sub)      printf '%s' '尚未配置订阅 URL - mihomo 启动需要它' ;;
    diag_compose_up)  printf '%s' 'docker compose up -d 失败' ;;
    diag_compose_up_fix) printf '%s' '请查看上面的输出以及 %s；核对 macvlan 网络和 .env 中的镜像引用' ;;
    ok_mihomo_healthy) printf '%s' 'mihomo 正在运行且健康' ;;
    diag_unhealthy)   printf '%s' 'mihomo 未能进入健康状态' ;;
    diag_unhealthy_fix) printf '%s' '请查看上面的 mihomo 日志；检查订阅/DNS/geo 数据错误以及 TUN 或 iptables 故障' ;;
    info_egress_test) printf '%s' '正在通过代理测试外网连通性（GET %s）……' ;;
    ok_egress)        printf '%s' '出口正常——已通过代理访问到测试地址（%s 毫秒）' ;;
    diag_egress)      printf '%s' '网关已启动，但无法通过 %s 访问外网（节点超时）' ;;
    diag_egress_fix)  printf '%s' '订阅可能已过期，或其节点已下线/在本网络被阻断——请打开面板（代理 -> 测试节点），选择一个可用节点，或更新订阅链接后重新部署' ;;
    info_egress_skip) printf '%s' '已跳过出口测试（mihomo 镜像中没有 wget/curl）' ;;
    step_deploy_done) printf '%s' '部署完成' ;;
    ok_gateway_up)    printf '%s' '网关已启动。' ;;
    rep_dashboard)    printf '%s' '仪表盘（请从非 NAS 的 LAN 设备打开）：' ;;
    rep_dashboard_url) printf '%s' '    http://<NAS-IP>:%s' ;;
    rep_add_backend)  printf '%s' '  在仪表盘中添加后端：' ;;
    rep_backend_line) printf '%s' '    Host=%s  Port=%s  Secret=<你的控制器密钥>' ;;
    rep_point_client) printf '%s' '将客户端的网关 + DNS 指向 %s，即可让其流量经由代理。' ;;
    rep_warn_isolation) printf '%s' 'NAS 自身无法访问 %s（macvlan 隔离）- 请始终从另一台设备测试。' ;;
    rep_reach_test)   printf '%s' '请从局域网设备验证：curl http://%s:%s/version 应返回 JSON。若超时，说明该 IP 不可达（Open vSwitch？请设 TPROXY_DRIVER=ipvlan 后重新部署）——见故障排查。' ;;
    rep_next)         printf '%s' '下一步：在主菜单设置自动镜像更新（选项 2）。' ;;
    step_deploy_e2e)  printf '%s' '端到端部署' ;;

    # --- flow_cron.sh ---
    cron_need_root)   printf '%s' '安装 crontab 条目需要 root 权限。' ;;
    diag_no_crontab)  printf '%s' '找不到 %s（不是 cron/DSM 主机？）' ;;
    diag_no_crontab_fix) printf '%s' '请改用 DSM 任务计划程序设置' ;;
    ok_cron_exists)   printf '%s' '%s 中已存在自动更新条目 - 不再重复添加' ;;
    ok_cron_installed) printf '%s' '已安装回退 crontab 条目并重新加载 crond' ;;
    warn_cron_reload) printf '%s' '已向 %s 添加条目，但 crond 重新加载失败 - 请改用 DSM 任务计划程序' ;;
    warn_cron_tz)     printf '%s' '注意：BusyBox crond 按 NAS 系统时区触发（忽略逐行 TZ）；请正确设置 NAS 时间。UPDATE_TZ 仅影响任务内日志时间戳。' ;;
    diag_cron_write)  printf '%s' '无法写入 %s' ;;
    diag_cron_write_fix) printf '%s' '请以 root 身份（sudo）运行' ;;
    step_cron)        printf '%s' '自动更新（cron）设置' ;;
    diag_no_env)      printf '%s' '找不到 .env' ;;
    diag_no_env_fix)  printf '%s' '请先执行端到端部署（主菜单选项 1）' ;;
    q_daily_time)     printf '%s' '每日更新时间（HH:MM，24 小时制）' ;;
    cron_tz_prompt)   printf '%s' '更新器日志时间戳时区（DSM 按 NAS 系统时区触发）' ;;
    cron_tz_other)    printf '%s' '其他（手动输入）' ;;
    q_tz_freeform)    printf '%s' '时区（例如 Asia/Singapore）' ;;
    ask_enable_updates) printf '%s' '是否启用自动更新？' ;;
    warn_updates_disabled) printf '%s' '自动更新已禁用（UPDATE_ENABLED=false）- 在重新启用前任务将不执行任何操作' ;;
    ok_schedule)      printf '%s' '计划：按 NAS 系统时区每日 %s；日志时区 %s' ;;
    cron_how)         printf '%s' '你想如何安排它？' ;;
    cron_how_dsm)     printf '%s' '通过 DSM 网页界面（任务计划程序）设置 - 推荐' ;;
    cron_how_cli)     printf '%s' '立即安装 crontab 条目（CLI；DSM 升级时可能覆盖）' ;;
    cron_how_dry)     printf '%s' '立即以 dry-run 验证（会拉取缓存，但不切换容器）' ;;
    cron_how_done)    printf '%s' '完成' ;;
    step_dsm_sched)   printf '%s' 'Synology DSM 任务计划程序设置' ;;
    warn_cron_not_installed) printf '%s' '未安装回退 crontab - 请改用 DSM 网页界面' ;;
    info_dry_run)     printf '%s' '正在运行：scripts/auto_update.sh --dry-run' ;;
    warn_dry_run_nonzero) printf '%s' 'dry-run 以非零状态退出 - 请查看上面的输出（这不会改变部署）' ;;
    ok_cron_complete) printf '%s' 'cron 设置完成。推荐使用 DSM 任务计划程序（网页界面），它在升级后仍能保留。' ;;

    # --- flow_modify.sh ---
    step_apply)       printf '%s' '应用更改（重新部署）' ;;
    warn_nothing_deployed) printf '%s' '尚未部署任何内容 - 请改用端到端部署（主菜单选项 1）' ;;
    warn_acr_login_soft) printf '%s' 'ACR 登录失败 - 已更改的镜像可能拉取失败' ;;
    info_redeploying) printf '%s' '正在重新部署（docker compose up -d；重新渲染配置，拉取已更改的镜像）' ;;
    ok_applied)       printf '%s' '已应用且健康' ;;
    warn_health_rollback) printf '%s' '健康检查未通过 - 正在回滚到上一个正常镜像' ;;
    warn_rolled_back) printf '%s' '已回滚到上一个正常状态（现已健康）- 你的更改未被应用' ;;
    diag_rollback_fail) printf '%s' '重新部署失败且回滚不完整' ;;
    diag_rollback_fail_fix) printf '%s' "请检查 'docker ps -a' 和 'docker logs mihomo'；可能需要手动恢复" ;;
    step_modify)      printf '%s' '修改现有配置' ;;
    info_stack_state) printf '%s' '当前服务栈状态：%s' ;;
    modify_what)      printf '%s' '你想更改什么？' ;;
    modify_net)       printf '%s' '网络与 DNS 设置（.env 向导）' ;;
    modify_images)    printf '%s' '镜像来源 / 仓库 / tag' ;;
    modify_sub)       printf '%s' '订阅链接' ;;
    modify_rerun_net) printf '%s' '重新运行网络设置（接口 / macvlan）' ;;
    modify_apply)     printf '%s' '立即应用更改（带回滚的重新部署）' ;;
    modify_back)      printf '%s' '返回主菜单' ;;

    # --- flow_redeploy.sh ---
    step_redeploy)    printf '%s' '使用已保存的 .env 部署' ;;
    diag_no_env_redeploy) printf '%s' '找不到 .env - 没有可重新部署的内容' ;;
    redeploy_current) printf '%s' '当前配置：' ;;
    redeploy_iface)   printf '%s' '  接口     ：%s' ;;
    redeploy_iface_auto) printf '%s' '（自动检测）' ;;
    redeploy_router)  printf '%s' '  路由器   ：%s' ;;
    redeploy_subnet)  printf '%s' '  子网     ：%s' ;;
    redeploy_mihomo)  printf '%s' '  mihomo IP：%s' ;;
    redeploy_images)  printf '%s' '  镜像     ：%s' ;;
    redeploy_sub)     printf '%s' '  订阅     ：%s' ;;
    redeploy_sub_none) printf '%s' '（未设置）' ;;
    precheck_step)    printf '%s' '正在校验已保存的配置' ;;
    precheck_bad)     printf '%s' '.env 中的 %s 缺失或无效：“%s”——请重新输入' ;;
    precheck_images)  printf '%s' '.env 中未设置镜像引用——将重新执行镜像步骤' ;;
    precheck_ok)      printf '%s' '已保存的配置看起来有效' ;;
    warn_sub_dirty)   printf '%s' '保存的订阅链接似乎已损坏（含异常字符 / 粘贴错误）' ;;
    redeploy_what)    printf '%s' '你想做什么？' ;;
    redeploy_asis)    printf '%s' '立即部署（按原样使用 .env）' ;;
    redeploy_edit)    printf '%s' '编辑设置（网络 / DNS / 端口），然后部署' ;;
    redeploy_change_ip) printf '%s' '更改 mihomo 的 LAN IP，然后部署' ;;
    redeploy_repick)  printf '%s' '重新选择网络接口，然后部署' ;;
    q_new_mihomo_ip)  printf '%s' 'mihomo 的新静态 LAN IP（必须未被占用）' ;;

    *)                printf '%s' "$1" ;;
  esac
}

# choose_language - the FIRST screen. Self-bilingual (cannot use msg yet). Reads a
# saved choice from .env if present; otherwise asks and (if .env exists) persists.
choose_language() {
  if [ -f "$ENV_FILE" ]; then
    _saved="$(env_get INSTALLER_LANG 2>/dev/null || true)"
    case "$_saved" in en|zh) INSTALLER_LANG="$_saved"; export INSTALLER_LANG; return 0 ;; esac
  fi
  ui_say ""
  ui_say "  1) English"
  ui_say "  2) 中文 (Chinese)"
  while :; do
    printf '%s' "Language / 语言 [1-2]: " >&2
    _read_line _pick
    case "$_pick" in
      1|en|EN|english|English) INSTALLER_LANG=en; break ;;
      2|zh|ZH|中文|chinese|Chinese) INSTALLER_LANG=zh; break ;;
      *) ui_say "  please enter 1 or 2 / 请输入 1 或 2" ;;
    esac
  done
  export INSTALLER_LANG
  [ -f "$ENV_FILE" ] && env_set INSTALLER_LANG "$INSTALLER_LANG"
  return 0
}
