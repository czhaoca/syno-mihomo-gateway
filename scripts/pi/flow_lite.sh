#!/bin/sh
# flow_lite.sh (scripts/pi) - the interactive bare-metal "lite" install flow
# (#19) plus the Pi cron-scheduling flow (#20, pi_flow_cron - both flavors).
# Wizard -> subscription -> render (fail-fast) -> binary -> dashboard ->
# geodata -> systemd unit -> start -> readiness probe -> mode marker -> report.
# Reuses the stock subscription wizard and validation/prompt primitives; the
# network-topology wizards are deliberately SKIPPED (no macvlan in lite mode -
# clients point at the Pi's own IP). Requires the full installer module set +
# detect.sh, preflight.sh (pi), i18n_pi.sh, lite.sh sourced first. POSIX sh.

# pi_lite_wizard - the lite-mode subset of wizard_env plus the lite-only
# settings. Same prompt/persist idiom (prefill from .env, Enter keeps saved);
# the secret keep/'-'/clear semantics mirror wizards.sh:wizard_env exactly.
pi_lite_wizard() {
  ui_step "$(msg pi_step_lite_wizard)"

  ui_ask_validated CONTROLLER_PORT "$(msg q_controller_port)" "$(env_get CONTROLLER_PORT || example_default CONTROLLER_PORT)" is_port
  env_set CONTROLLER_PORT "$CONTROLLER_PORT"

  _plw_secret_cur="$(env_get CONTROLLER_SECRET 2>/dev/null || echo '')"
  while :; do
    if [ -n "$_plw_secret_cur" ]; then
      ui_ask_secret CONTROLLER_SECRET "$(msg q_controller_secret_keep)"
    else
      ui_ask_secret CONTROLLER_SECRET "$(msg q_controller_secret)"
    fi
    case "$CONTROLLER_SECRET" in
      *"|"*) ui_warn "$(msg warn_secret_pipe)" ;;
      *) break ;;
    esac
  done
  _plw_secret_cleared=0
  if [ -n "$_plw_secret_cur" ] && [ -z "$CONTROLLER_SECRET" ]; then
    CONTROLLER_SECRET="$_plw_secret_cur"
  elif [ "$CONTROLLER_SECRET" = "-" ]; then
    CONTROLLER_SECRET=""; _plw_secret_cleared=1
  fi
  env_set CONTROLLER_SECRET "$CONTROLLER_SECRET"
  if [ "$_plw_secret_cleared" = 1 ]; then
    ui_warn "$(msg warn_secret_none)"
  else
    _secret_guard
  fi

  # A hand-rolled / pre-split .env keeps rendering the legacy DNS profile -
  # offer the v2 upgrade BEFORE the prompts below, so they pre-fill from the
  # migrated values (fresh installs seed .env from .env.example, where the
  # split pair is already set, and the offer no-ops). Shared helper from
  # scripts/installer/wizards.sh (same catalog keys, same default-No).
  offer_dns_privacy_upgrade

  ui_ask_validated DNS_DEFAULT_NAMESERVER "$(msg q_dns_bootstrap)" "$(env_get DNS_DEFAULT_NAMESERVER || example_default DNS_DEFAULT_NAMESERVER)" is_dns_list
  env_set DNS_DEFAULT_NAMESERVER "$DNS_DEFAULT_NAMESERVER"
  ui_ask_validated DNS_NAMESERVER "$(msg q_dns_domestic)" "$(env_get DNS_NAMESERVER || example_default DNS_NAMESERVER)" is_dns_list
  env_set DNS_NAMESERVER "$DNS_NAMESERVER"
  ui_ask_validated DNS_FALLBACK "$(msg q_dns_fallback)" "$(env_get DNS_FALLBACK || example_default DNS_FALLBACK)" is_dns_list
  env_set DNS_FALLBACK "$DNS_FALLBACK"

  ui_ask TZ "$(msg q_tz)" "$(env_get TZ || example_default TZ)"
  env_set TZ "$TZ"

  # Lite-only artifact settings (DEC-4 / DEC-C): mirror prefix, optional
  # version pin, and - only alongside a pin - an optional sha256 anchor.
  ui_say "$(msg pi_lite_ghmirror_hint)"
  ui_ask GH_MIRROR "$(msg pi_lite_q_ghmirror)" "$(env_get GH_MIRROR 2>/dev/null || echo '')"
  env_set GH_MIRROR "$GH_MIRROR"
  ui_ask MIHOMO_VERSION "$(msg pi_lite_q_version)" "$(env_get MIHOMO_VERSION 2>/dev/null || echo '')"
  env_set MIHOMO_VERSION "$MIHOMO_VERSION"
  if [ -n "$MIHOMO_VERSION" ]; then
    ui_ask MIHOMO_SHA256 "$(msg pi_lite_q_sha)" "$(env_get MIHOMO_SHA256 2>/dev/null || echo '')"
    env_set MIHOMO_SHA256 "$MIHOMO_SHA256"
  fi

  # The dashboard folder mihomo serves at /ui - the render fence (Seq 10)
  # emits external-ui only because this is set.
  env_set EXTERNAL_UI_DIR "$GATEWAY_DATA_DIR/ui/metacubexd"
  ui_ok "$(msg ok_env_saved)"
  return 0
}

# pi_lite_render_config - host-side render through the SAME CI-tested renderer
# the container entrypoint runs; explicit env passing (dotenv values are data,
# never exported wholesale). Fails loudly before anything is downloaded.
# The split-horizon knobs are read from .env via env_get: the lite wizard
# never prompts for them (they ship pre-set in .env.example), so unlike the
# prompted DNS_* vars above there is no shell variable to expand - and the
# boot-time render (the systemd unit's load_env) must see the SAME values.
pi_lite_render_config() {
  MIHOMO_CONFIG_DIR="$CONFIG_STATE_DIR" \
  MIHOMO_TEMPLATE="$REPO_ROOT/config/config.template.yaml" \
  CONTROLLER_PORT="${CONTROLLER_PORT:-$(example_default CONTROLLER_PORT)}" \
  CONTROLLER_SECRET="${CONTROLLER_SECRET:-}" \
  DNS_DEFAULT_NAMESERVER="${DNS_DEFAULT_NAMESERVER:-}" \
  DNS_NAMESERVER="${DNS_NAMESERVER:-}" \
  DNS_FALLBACK="${DNS_FALLBACK:-}" \
  DNS_CN_NAMESERVER="$(env_get DNS_CN_NAMESERVER 2>/dev/null || echo '')" \
  DNS_FOREIGN_NAMESERVER="$(env_get DNS_FOREIGN_NAMESERVER 2>/dev/null || echo '')" \
  DNS_GEOIP_NO_RESOLVE="$(env_get DNS_GEOIP_NO_RESOLVE 2>/dev/null || echo false)" \
  SNIFFER_ENABLE="$(env_get SNIFFER_ENABLE 2>/dev/null || echo false)" \
  TUN_ENABLE="${TUN_ENABLE:-true}" \
  TUN_AUTO_REDIRECT="${TUN_AUTO_REDIRECT:-false}" \
  EXTERNAL_UI_DIR="${EXTERNAL_UI_DIR:-}" \
  sh "$REPO_ROOT/scripts/render_config.sh" >>"${LOG_FILE:-/dev/null}" 2>&1
}

# pi_flow_lite - the end-to-end lite install.
pi_flow_lite() {
  ui_step "$(msg pi_step_lite)"
  if ! is_root; then
    diagnose "$(msg pi_diag_lite_root)" "$(msg pi_diag_lite_root_fix)"
    return 1
  fi
  seed_config || return 1
  load_env
  pi_lite_wizard || return 1
  wizard_subscription || return 1
  load_env

  # mihomo's DNS binds :53; a stock resolver (systemd-resolved, dnsmasq) in
  # the way is the most common first-start failure on Pi OS variants (G7).
  # Warn now - the unit still starts and the doctor (#21) diagnoses it fully.
  if [ "$(pf_port_free 53; echo $?)" = 1 ]; then
    ui_warn "$(msg pi_warn_port53)"
    ui_say "      $(msg pi_warn_port53_fix)"
  fi

  ui_info "$(msg pi_lite_info_render)"
  pi_lite_render_config || {
    diagnose "$(msg diag_cfg_render)" "$(msg diag_cfg_render_fix)"
    return 1
  }

  _pfl_tag="$(pi_resolve_tag MetaCubeX/mihomo "${MIHOMO_VERSION:-}")" || {
    diagnose "$(msg pi_lite_diag_tag)" "$(msg pi_lite_diag_tag_fix)"
    return 1
  }
  ui_info "$(msgf pi_lite_fetch_bin "$_pfl_tag")"
  pi_lite_install_binary "$_pfl_tag" || {
    diagnose "$(msg pi_lite_diag_bin)" "$(msg pi_lite_diag_bin_fix)"
    return 1
  }
  ui_ok "$(msgf pi_lite_ok_bin "$_pfl_tag")"

  ui_info "$(msg pi_lite_fetch_ui)"
  pi_lite_install_dashboard || {
    diagnose "$(msg pi_lite_diag_ui)" "$(msg pi_lite_diag_ui_fix)"
    return 1
  }
  ui_ok "$(msg pi_lite_ok_ui)"

  pi_lite_prefetch_geodata

  pi_lite_render_unit || {
    diagnose "$(msg pi_lite_diag_unit)" "$(msg pi_lite_diag_unit_fix)"
    return 1
  }
  ui_info "$(msg pi_lite_info_start)"
  pi_lite_enable_start || {
    diagnose "$(msg pi_lite_diag_start)" "$(msg pi_lite_diag_start_fix)"
    return 1
  }
  if pi_lite_controller_probe; then
    ui_ok "$(msg pi_lite_probe_ok)"
  else
    ui_warn "$(msg pi_lite_probe_warn)"
  fi
  pi_write_mode_marker pi-lite

  _pfl_ip="$(_iface_ipv4 "$(detect_parent_interface '')" 2>/dev/null)"
  [ -n "$_pfl_ip" ] || _pfl_ip='<Pi-IP>'
  ui_step "$(msg step_deploy_done)"
  ui_say "$(msgf pi_lite_rep_dashboard "$_pfl_ip" "${CONTROLLER_PORT:-$(example_default CONTROLLER_PORT)}")"
  ui_say "$(msgf pi_lite_rep_client "$_pfl_ip")"
  return 0
}

# _pi_default_hhmm - HH:MM default from the saved UPDATE_SCHEDULE (mirrors
# flow_cron.sh's _default_hhmm; that DSM module is not sourced by install-pi.sh).
_pi_default_hhmm() {
  _pdh_s="$(env_get UPDATE_SCHEDULE 2>/dev/null || echo '0 2 * * *')"
  cron_daily_hhmm "$_pdh_s" 2>/dev/null || printf '02:00'
}

# pi_flow_cron (#20) - schedule the auto-updater on a Pi: crontab ONLY (no DSM
# Task Scheduler exists here), targeting the flavor the install-mode marker
# records - pi-lite runs scripts/pi/auto_update_lite.sh, anything else the
# stock scripts/auto_update.sh (verified portable: the compose updater runs
# unchanged from cron). Root is gated up front: .env lives under the
# root-owned data dir and /etc/crontab needs it too.
pi_flow_cron() {
  ui_step "$(msg step_cron)"
  if ! is_root; then
    ui_warn "$(msg cron_need_root)"
    pi_sudo_rerun_hint
    return 1
  fi
  if [ ! -f "$ENV_FILE" ]; then
    diagnose "$(msg diag_no_env)" "$(msg diag_no_env_fix)"
    return 1
  fi
  load_env

  # --- daily time (HH:MM, local) -> cron "M H * * *" ---
  ui_ask_validated _pfc_time "$(msg q_daily_time)" "$(_pi_default_hhmm)" is_hhmm
  _pfc_hh="${_pfc_time%%:*}"; _pfc_mm="${_pfc_time#*:}"
  # Strip a leading zero by hand: printf %d (and $((...))) octal-parse "08"
  # and "09" to 0 on POSIX shells, silently corrupting the schedule.
  case "$_pfc_hh" in 0?) _pfc_hh="${_pfc_hh#0}" ;; esac
  case "$_pfc_mm" in 0?) _pfc_mm="${_pfc_mm#0}" ;; esac
  UPDATE_SCHEDULE="$_pfc_mm $_pfc_hh * * *"
  env_set UPDATE_SCHEDULE "$UPDATE_SCHEDULE"

  # Pre-fill from .env.example (#27). The DSM cron twin (installer/flow_cron.sh)
  # still carries its timezone literal - outside #27's file surface; tracked on
  # the issue alongside the UPDATE_SCHEDULE fallback for a later hygiene pass.
  ui_ask UPDATE_TZ "$(msg q_tz_freeform)" "$(env_get UPDATE_TZ 2>/dev/null || example_default UPDATE_TZ)"
  env_set UPDATE_TZ "$UPDATE_TZ"

  if ui_yesno "$(msg ask_enable_updates)" y; then
    env_set UPDATE_ENABLED true
  else
    env_set UPDATE_ENABLED false
    ui_warn "$(msg warn_updates_disabled)"
  fi
  load_env
  ui_ok "$(msgf pi_ok_schedule "$_pfc_time" "$UPDATE_TZ")"

  # --- the managed crontab entry, per install flavor ---
  # The retired flavor's entry is removed after a successful install (#31,
  # DEC-R7): an install-mode switch would otherwise leave it lingering, and
  # its preflight aborts loudly on every scheduled run. The two match strings
  # are substring-disjoint, so removal can never touch the fresh entry.
  _pfc_mode="$(cat "$GATEWAY_DATA_DIR/state/install-mode" 2>/dev/null)"
  case "$_pfc_mode" in
    pi-lite)
      _pfc_match='scripts/pi/auto_update_lite.sh'
      _pfc_stale='scripts/auto_update.sh'
      _pfc_cmd="$(pi_lite_update_command)" || return 1
      _pfc_dry="$REPO_ROOT/scripts/pi/auto_update_lite.sh" ;;
    *)
      _pfc_match='scripts/auto_update.sh'
      _pfc_stale='scripts/pi/auto_update_lite.sh'
      _pfc_cmd="$(scheduler_update_command)" || return 1
      _pfc_dry="$REPO_ROOT/scripts/auto_update.sh" ;;
  esac
  if ! pi_install_crontab_entry "$_pfc_match" "$_pfc_cmd"; then
    ui_warn "$(msg pi_warn_cron_not_installed)"
    return 1
  fi
  # Removal failure is non-fatal by design (the helper logs it): the fresh
  # entry is installed and correct; a lingering stale line only notifies.
  pi_remove_crontab_entry "$_pfc_stale" || :
  ui_ok "$(msg pi_ok_cron_installed)"
  ui_warn "$(msg pi_warn_cron_tz)"

  if ui_yesno "$(msg pi_ask_dryrun)" n; then
    sh "$_pfc_dry" --dry-run || ui_warn "$(msg warn_dry_run_nonzero)"
  fi
  return 0
}
