#!/bin/sh
# lite.sh (scripts/pi) - UI-free primitives for the bare-metal "lite" mode
# (#19): mihomo binary download + fail-closed verify ladder, MetaCubexD
# dashboard via mihomo's external-ui, geodata prefetch, and the systemd unit.
# No Docker anywhere: mihomo binds the host directly (the Pi's own IP is the
# clients' gateway/DNS). Shared by the install flow (#19), the binary updater
# (#20), and lite_ctl (#21). Requires common.sh (GATEWAY_DATA_DIR, logging)
# and detect.sh (pi_lite_asset_arch) sourced first. POSIX /bin/sh.
#
# Artifact decisions (owner-resolved on the ticket):
#   DEC-B: dashboard = the metacubexd `compressed-dist.tgz` RELEASE asset
#          (versioned, stable layout, BusyBox tar extracts it - no unzip).
#   DEC-C: upstream publishes NO checksums, so the ladder is gzip integrity ->
#          exec smoke -> version match, plus an OPTIONAL owner-pinned
#          MIHOMO_SHA256 enforced when set (mirror-tamper anchor for GH_MIRROR
#          users); empty default changes nothing.

# pi_gh_url URL - apply the GH_MIRROR prefix (DEC-4). Empty mirror = direct.
# gh-proxy convention: <mirror>/<full-github-url>.
pi_gh_url() {
  printf '%s' "${GH_MIRROR:+${GH_MIRROR%/}/}$1"
}

# pi_fetch URL OUT - download via curl or wget, staged (.part) so a failed or
# interrupted transfer never leaves a half-written artifact at OUT.
pi_fetch() {
  _pf_u="$1"; _pf_o="$2"
  rm -f "$_pf_o.part"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --max-time 300 -o "$_pf_o.part" "$_pf_u" >>"${LOG_FILE:-/dev/null}" 2>&1 \
      || { rm -f "$_pf_o.part"; return 1; }
  elif command -v wget >/dev/null 2>&1; then
    wget -q -T 300 -O "$_pf_o.part" "$_pf_u" >>"${LOG_FILE:-/dev/null}" 2>&1 \
      || { rm -f "$_pf_o.part"; return 1; }
  else
    log_error "neither curl nor wget is available"
    return 1
  fi
  mv "$_pf_o.part" "$_pf_o"
}

# pi_resolve_tag OWNER/REPO PIN - print the release tag: the PIN verbatim when
# set, else the tag the releases/latest redirect lands on (followed THROUGH
# the GH_MIRROR prefix, so mirror-only networks resolve too - risk G5; a
# mirror that mangles the redirect is a classified failure, never a silent
# wrong version). Unpinned resolution needs curl (-w url_effective).
pi_resolve_tag() {
  _prt_repo="$1"; _prt_pin="$2"
  if [ -n "$_prt_pin" ]; then
    printf '%s' "$_prt_pin"
    return 0
  fi
  command -v curl >/dev/null 2>&1 || {
    log_error "resolving the latest release needs curl - install curl or pin MIHOMO_VERSION"
    return 1
  }
  _prt_url="$(pi_gh_url "https://github.com/$_prt_repo/releases/latest")"
  _prt_eff="$(curl -fsSL -o /dev/null -w '%{url_effective}' --max-time 30 "$_prt_url" 2>/dev/null)" || {
    log_error "could not reach $_prt_url to resolve the latest release"
    return 1
  }
  case "$_prt_eff" in
    */releases/tag/*) printf '%s' "${_prt_eff##*/releases/tag/}" ;;
    *)
      log_error "release redirect did not land on a tag (mirror mangled it?): $_prt_eff"
      return 1 ;;
  esac
}

# pi_sha256 FILE - print the sha256 (sha256sum on Linux/BusyBox, shasum on
# dev boxes); empty + rc 1 when no tool exists.
pi_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" 2>/dev/null | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
  else
    return 1
  fi
}

# pi_verify_sha FILE - DEC-C: enforce the owner-pinned MIHOMO_SHA256 when set
# (fail closed, including when no checksum tool exists - a set pin is explicit
# intent); an empty pin is a no-op.
pi_verify_sha() {
  [ -n "${MIHOMO_SHA256:-}" ] || return 0
  _pv_have="$(pi_sha256 "$1")" || {
    log_error "MIHOMO_SHA256 is set but no sha256 tool is available"
    return 1
  }
  if [ "$_pv_have" != "$MIHOMO_SHA256" ]; then
    log_error "sha256 mismatch for $1 (have $_pv_have, pinned $MIHOMO_SHA256)"
    return 1
  fi
  return 0
}

# pi_lite_install_binary TAG - fetch (or sideload) the mihomo release archive
# for this host's arch and run the fail-closed verify ladder:
#   optional pinned sha (DEC-C) -> gzip integrity -> exec smoke -> version
#   matches TAG -> atomic move into place + version state.
# Sideload: a pre-placed $GATEWAY_DATA_DIR/bin/mihomo-linux-<arch>-<TAG>.gz
# (offline installs) is used instead of downloading, same ladder applied.
pi_lite_install_binary() {
  _plb_tag="$1"
  _plb_arch="$(pi_lite_asset_arch)" || {
    log_error "unsupported architecture for a mihomo release asset"
    return 1
  }
  _plb_asset="mihomo-linux-${_plb_arch}-${_plb_tag}.gz"
  _plb_dir="$GATEWAY_DATA_DIR/bin"
  mkdir -p "$_plb_dir" || return 1
  _plb_gz="$_plb_dir/mihomo.next.gz"
  _plb_next="$_plb_dir/mihomo.next"
  rm -f "$_plb_gz" "$_plb_next"
  if [ -f "$_plb_dir/$_plb_asset" ]; then
    cp "$_plb_dir/$_plb_asset" "$_plb_gz" || return 1
  else
    _plb_url="$(pi_gh_url "https://github.com/MetaCubeX/mihomo/releases/download/${_plb_tag}/${_plb_asset}")"
    pi_fetch "$_plb_url" "$_plb_gz" || { rm -f "$_plb_gz"; return 1; }
  fi
  pi_verify_sha "$_plb_gz" || { rm -f "$_plb_gz"; return 1; }
  gzip -t "$_plb_gz" 2>/dev/null || {
    log_error "corrupt archive: $_plb_asset"
    rm -f "$_plb_gz"; return 1
  }
  gunzip -c "$_plb_gz" > "$_plb_next" 2>/dev/null || {
    rm -f "$_plb_gz" "$_plb_next"; return 1
  }
  chmod +x "$_plb_next" 2>/dev/null
  _plb_v="$("$_plb_next" -v 2>/dev/null | head -n1)"
  case "$_plb_v" in
    *"$_plb_tag"*) : ;;
    *)
      log_error "binary smoke/version check failed (got: ${_plb_v:-nothing}, want tag $_plb_tag)"
      rm -f "$_plb_gz" "$_plb_next"; return 1 ;;
  esac
  mv "$_plb_next" "$_plb_dir/mihomo" || { rm -f "$_plb_gz" "$_plb_next"; return 1; }
  rm -f "$_plb_gz"
  mkdir -p "$GATEWAY_DATA_DIR/state/lite" || return 1
  printf '%s\n' "$_plb_tag" > "$GATEWAY_DATA_DIR/state/lite/version"
  return 0
}

# pi_lite_install_dashboard - fetch (or sideload) the MetaCubexD static build
# (DEC-B: the compressed-dist.tgz release asset) and install it where mihomo's
# external-ui serves it. Extraction is layout-agnostic - index.html at the
# archive root or one directory deep - so an upstream layout tweak degrades
# LOUDLY (unrecognized layout) instead of installing a broken dashboard (G6).
# Sideload: a pre-placed $GATEWAY_DATA_DIR/ui/compressed-dist.tgz skips the
# download.
pi_lite_install_dashboard() {
  _pld_ui="$GATEWAY_DATA_DIR/ui/metacubexd"
  _pld_tgz="$GATEWAY_DATA_DIR/ui/compressed-dist.tgz"
  _pld_stage="$GATEWAY_DATA_DIR/ui/.stage.$$"
  mkdir -p "$GATEWAY_DATA_DIR/ui" || return 1
  if [ ! -f "$_pld_tgz" ]; then
    _pld_tag="$(pi_resolve_tag MetaCubeX/metacubexd '')" || return 1
    _pld_url="$(pi_gh_url "https://github.com/MetaCubeX/metacubexd/releases/download/${_pld_tag}/compressed-dist.tgz")"
    pi_fetch "$_pld_url" "$_pld_tgz" || return 1
  fi
  gzip -t "$_pld_tgz" 2>/dev/null || {
    log_error "corrupt dashboard archive: compressed-dist.tgz"
    rm -f "$_pld_tgz"; return 1
  }
  rm -rf "$_pld_stage"
  mkdir -p "$_pld_stage" || return 1
  tar -xzf "$_pld_tgz" -C "$_pld_stage" 2>/dev/null || { rm -rf "$_pld_stage"; return 1; }
  _pld_root=""
  if [ -f "$_pld_stage/index.html" ]; then
    _pld_root="$_pld_stage"
  else
    for _pld_d in "$_pld_stage"/*/; do
      [ -f "${_pld_d}index.html" ] && { _pld_root="${_pld_d%/}"; break; }
    done
  fi
  [ -n "$_pld_root" ] || {
    log_error "dashboard archive layout unrecognized (no index.html at root or one level deep)"
    rm -rf "$_pld_stage"; return 1
  }
  rm -rf "$_pld_ui"
  mv "$_pld_root" "$_pld_ui" || { rm -rf "$_pld_stage"; return 1; }
  rm -rf "$_pld_stage"
  return 0
}

# pi_lite_prefetch_geodata - best-effort: pull the geo databases through the
# SAME CDN mirror URLs the rendered config already carries (no second source
# of truth), so mihomo's first start doesn't stall on a blocked default host.
# Warn-only: mihomo fetches them itself on first start if this fails.
pi_lite_prefetch_geodata() {
  _plg_cfg="$CONFIG_STATE_DIR/config.yaml"
  [ -f "$_plg_cfg" ] || return 0
  for _plg_k in geoip geosite mmdb; do
    _plg_u="$(sed -n "s/^  $_plg_k: \"\(.*\)\"\$/\1/p" "$_plg_cfg" | head -n1)"
    [ -n "$_plg_u" ] || continue
    _plg_f="$CONFIG_STATE_DIR/$(basename "$_plg_u")"
    [ -f "$_plg_f" ] && continue
    pi_fetch "$_plg_u" "$_plg_f" \
      || log_warn "geodata prefetch failed for $_plg_k - mihomo fetches it on first start"
  done
  return 0
}

# pi_lite_unit_path - the systemd unit location (test-overridable).
pi_lite_unit_path() {
  printf '%s' "${SMG_PI_UNIT_FILE:-/etc/systemd/system/mihomo-gateway.service}"
}

# pi_lite_render_unit - write the minimal v1 unit (hardening deferred - risk
# G4): re-render config on every start (ExecStartPre picks up subscription and
# .env edits), run mihomo against the persistent config dir, always restart.
# Root because TUN + port 53. An unchanged unit file is not rewritten.
#
# .env is deliberately NOT handed to systemd via EnvironmentFile: env_set
# writes compose-convention escaping (a literal '$' becomes '$$', which the
# compose path and the app's dotenv_decode both reverse) and systemd's env
# parser does NOT - a secret containing '$' would silently mismatch on every
# restart. ExecStartPre therefore loads .env through the app's OWN strict
# loader (set -a exports for the renderer child), same decode path as the
# container entrypoint's compose --env-file.
pi_lite_render_unit() {
  _plu_f="$(pi_lite_unit_path)"
  _plu_tmp="${_plu_f}.tmp.$$"
  cat > "$_plu_tmp" <<EOF || { rm -f "$_plu_tmp"; return 1; }
# Generated by install-pi.sh (lite mode) - regenerate by re-running the
# installer; do not hand-edit (edits are overwritten on reinstall).
[Unit]
Description=Mihomo transparent proxy gateway (lite mode)
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
Environment=MIHOMO_CONFIG_DIR=$CONFIG_STATE_DIR
Environment=MIHOMO_TEMPLATE=$REPO_ROOT/config/config.template.yaml
ExecStartPre=/bin/sh -c 'set -a; REPO_ROOT="$REPO_ROOT"; GATEWAY_DATA_DIR="$GATEWAY_DATA_DIR"; ENV_FILE="$ENV_FILE"; . "$REPO_ROOT/scripts/lib/common.sh"; load_env; exec /bin/sh "$REPO_ROOT/scripts/render_config.sh"'
ExecStart=$GATEWAY_DATA_DIR/bin/mihomo -d $CONFIG_STATE_DIR
Restart=always
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
  if [ -f "$_plu_f" ] && cmp -s "$_plu_tmp" "$_plu_f"; then
    rm -f "$_plu_tmp"
    return 0
  fi
  mv "$_plu_tmp" "$_plu_f"
}

# pi_lite_enable_start - reload units, enable at boot, (re)start now.
pi_lite_enable_start() {
  command -v systemctl >/dev/null 2>&1 || {
    log_error "systemd (systemctl) is required for lite mode"
    return 1
  }
  systemctl daemon-reload >/dev/null 2>&1
  systemctl enable mihomo-gateway >/dev/null 2>&1
  systemctl restart mihomo-gateway >>"${LOG_FILE:-/dev/null}" 2>&1
}

# pi_lite_controller_probe - readiness wait: the controller answering on
# loopback is the "mihomo is up" signal (the full health gate is the
# updater's job, #20). Bearer secret rides stdin-free loopback curl/wget.
pi_lite_controller_probe() {
  _plc_port="${CONTROLLER_PORT:-9090}"
  _plc_url="http://127.0.0.1:${_plc_port}/version"
  _plc_n=0
  while [ "$_plc_n" -lt "${PI_PROBE_RETRIES:-10}" ]; do
    if command -v curl >/dev/null 2>&1; then
      _plc_out="$(curl -fsS -m 3 ${CONTROLLER_SECRET:+-H "Authorization: Bearer $CONTROLLER_SECRET"} "$_plc_url" 2>/dev/null)"
    else
      _plc_out="$(wget -q -T 3 -O - ${CONTROLLER_SECRET:+--header "Authorization: Bearer $CONTROLLER_SECRET"} "$_plc_url" 2>/dev/null)"
    fi
    case "$_plc_out" in
      *version*) return 0 ;;
    esac
    _plc_n=$((_plc_n + 1))
    sleep "${PI_PROBE_INTERVAL:-2}"
  done
  return 1
}
