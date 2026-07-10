#!/bin/sh
# detect.sh (scripts/pi) - Raspberry Pi hardware detection + install-mode
# recommendation (epic raspberry-pi-port, #18). UI-free pure readers/deciders
# so the CI suite can assert the mode table without a TTY. The SMG_PI_*
# overrides exist for the test suites only (CI has no /proc/device-tree) -
# same convention as scheduler.sh's SMG_SCHED_*. POSIX /bin/sh, BusyBox-safe.

# pi_model - human-readable board name from the device tree ('unknown' when
# unreadable). The kernel pads the node with a trailing NUL - strip it.
pi_model() {
  _pm_f="${SMG_PI_MODEL_FILE:-/proc/device-tree/model}"
  if [ -r "$_pm_f" ]; then
    tr -d '\0' < "$_pm_f"
  else
    printf 'unknown'
  fi
}

# pi_mem_mb - MemTotal in whole MB (0 when unreadable). A Pi reports LESS than
# its nominal SKU size (GPU/firmware reservation): a 1 GB board shows ~926 MB.
pi_mem_mb() {
  _pm_mi="${SMG_PI_MEMINFO:-/proc/meminfo}"
  awk '/^MemTotal:/ { printf "%d", $2 / 1024; found = 1; exit }
       END { if (!found) printf "0" }' "$_pm_mi" 2>/dev/null || printf '0'
}

# pi_lite_asset_arch - this host's mihomo release-asset arch token. The Docker
# naming (amd64/arm64/arm) stays in registry.sh:host_arch; THIS token matches
# the upstream asset files (mihomo-linux-<armv6|armv7|arm64>-<tag>.gz).
pi_lite_asset_arch() {
  _pa_m="${SMG_PI_ARCH:-$(uname -m)}"
  case "$_pa_m" in
    aarch64|arm64) echo arm64 ;;
    armv7*)        echo armv7 ;;
    armv6*)        echo armv6 ;;
    x86_64|amd64)  echo amd64 ;;
    *)             printf '%s\n' "$_pa_m"; return 1 ;;
  esac
}

# pi_available_modes - which install modes this host can run AT ALL:
#   armv6 -> lite only (no arm/v6 container images exist upstream)
#   armv7 -> lite only (DEC-A #18: metacubexd publishes linux/amd64+arm64 only,
#            so compose predictably fails at the dashboard pull on a 32-bit OS)
#   arm64 -> compose + lite (amd64 dev boxes treated the same, for testing)
pi_available_modes() {
  case "$(pi_lite_asset_arch)" in
    armv6|armv7) echo 'lite' ;;
    *)           echo 'compose lite' ;;
  esac
}

# pi_recommend_mode - the owner-decided mode table (#18 constraints):
#   >=2 GB class -> compose; 1 GB class -> compose-tuned (low-RAM guidance,
#   lite offered); 512 MB class or any 32-bit OS -> lite; ARMv6 additionally
#   sits behind the explicit best-effort acknowledgment in the wizard (DEC-5).
# Thresholds carry headroom below the nominal sizes because the SoC reserves
# memory: a nominal 2 GB board reports ~1870 MB and a 1 GB board ~926 MB.
pi_recommend_mode() {
  case "$(pi_lite_asset_arch)" in
    armv6|armv7) echo lite; return 0 ;;
  esac
  _pr_mem="$(pi_mem_mb)"
  if [ "${_pr_mem:-0}" -ge 1700 ]; then
    echo compose
  elif [ "${_pr_mem:-0}" -ge 850 ]; then
    echo compose-tuned
  else
    echo lite
  fi
}

# pi_write_mode_marker MODE - persist pi-compose|pi-lite under the data dir so
# later tooling can tell the install flavors apart; an ABSENT marker means a
# DSM install. Idempotent single-line write.
pi_write_mode_marker() {
  mkdir -p "$GATEWAY_DATA_DIR/state" 2>/dev/null || return 1
  printf '%s\n' "$1" > "$GATEWAY_DATA_DIR/state/install-mode"
}
