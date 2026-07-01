#!/bin/sh
# notify.sh - push a short report to the operator.
#
# Channels (independent, never gating each other):
#   - DSM native push (synodsmnotify / synonotify): BEST-EFFORT ONLY. On DSM 7
#     synodsmnotify requires package-registered i18n message strings, so from a
#     plain script it can exit 0 without delivering anything. It is attempted
#     (harmless, still works on DSM 6) but never trusted as "delivered" and
#     never suppresses the webhook.
#   - NOTIFY_WEBHOOK_URL (.env, optional): the reliable opt-in rich channel
#     (Bark / Gotify / Slack-compatible JSON POST). The URL often embeds a
#     token, so it is passed to curl via a stdin --config file, NEVER argv
#     (argv is visible in ps).
#   - The documented DEFAULT path needs no code here at all: DSM Task
#     Scheduler's "send run details by email", driven by the non-zero exit
#     codes every entry point returns (see docs/auto-update.md).
#
# Requires common.sh (log_*) to be sourced first.

_json_escape() {
  # Escape a string for embedding in JSON. Prefer python3; fall back to sed.
  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$1" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'
  else
    printf '"%s"' "$(printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n' ' ')"
  fi
}

# _notify_webhook PAYLOAD - POST the JSON payload to NOTIFY_WEBHOOK_URL with the
# URL supplied via a stdin curl config (quoted per curl config syntax: the only
# characters needing escapes inside "..." are \ and ").
_notify_webhook() {
  _nw_url="$(printf '%s' "$NOTIFY_WEBHOOK_URL" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
  printf 'url = "%s"\n' "$_nw_url" | curl -fsS -m 10 -X POST \
    -H 'Content-Type: application/json' -d "$1" --config - >>"$LOG_FILE" 2>&1
}

notify() {
  # notify TITLE BODY
  _title="$1"; _body="$2"
  _dsm=0; _hook=0

  # Best-effort DSM push; a zero exit here proves nothing on DSM 7.
  if command -v synodsmnotify >/dev/null 2>&1; then
    # @administrators delivers to all admin users per their DSM notification rules.
    synodsmnotify @administrators "$_title" "$_body" >/dev/null 2>&1 && _dsm=1
  elif command -v synonotify >/dev/null 2>&1; then
    synonotify "$_title" "$_body" >/dev/null 2>&1 && _dsm=1
  fi

  # The webhook fires whenever configured - independent of the DSM attempt.
  if [ -n "${NOTIFY_WEBHOOK_URL:-}" ] && command -v curl >/dev/null 2>&1; then
    _payload="$(printf '{"title":%s,"body":%s}' "$(_json_escape "$_title")" "$(_json_escape "$_body")")"
    _notify_webhook "$_payload" && _hook=1
  fi

  if [ "$_hook" -eq 1 ]; then
    log_info "notification sent via webhook (dsm push attempted: $_dsm): $_title"
  elif [ "$_dsm" -eq 1 ]; then
    log_info "notification handed to DSM push (unverifiable on DSM 7 - rely on Task Scheduler email or set NOTIFY_WEBHOOK_URL): $_title"
  else
    log_warn "notification NOT delivered - enable DSM Task Scheduler 'send run details' email or set NOTIFY_WEBHOOK_URL in .env: $_title"
  fi
}
