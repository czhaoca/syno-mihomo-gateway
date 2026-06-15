#!/bin/sh
# notify.sh - push a short report to the operator.
# Order of preference:
#   1. Synology DSM native push (synodsmnotify / synonotify) - local, runs as root,
#      reaches the Synology mobile app via Synology's relay (does NOT route through
#      the mihomo gateway, so it still works when the gateway itself is down).
#   2. Optional NOTIFY_WEBHOOK_URL (Bark / Gotify / Slack-compatible JSON POST).
# Requires common.sh (log_*) to be sourced first.

_json_escape() {
  # Escape a string for embedding in JSON. Prefer python3; fall back to sed.
  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$1" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'
  else
    printf '"%s"' "$(printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n' ' ')"
  fi
}

notify() {
  # notify TITLE BODY
  _title="$1"; _body="$2"
  _sent=0

  if command -v synodsmnotify >/dev/null 2>&1; then
    # @administrators delivers to all admin users per their DSM notification rules.
    synodsmnotify @administrators "$_title" "$_body" >/dev/null 2>&1 && _sent=1
  elif command -v synonotify >/dev/null 2>&1; then
    synonotify "$_title" "$_body" >/dev/null 2>&1 && _sent=1
  fi

  if [ "$_sent" -eq 0 ] && [ -n "${NOTIFY_WEBHOOK_URL:-}" ] && command -v curl >/dev/null 2>&1; then
    _payload="$(printf '{"title":%s,"body":%s}' "$(_json_escape "$_title")" "$(_json_escape "$_body")")"
    curl -fsS -m 10 -X POST "$NOTIFY_WEBHOOK_URL" \
      -H 'Content-Type: application/json' -d "$_payload" >>"$LOG_FILE" 2>&1 && _sent=1
  fi

  if [ "$_sent" -eq 1 ]; then
    log_info "notification sent: $_title"
  else
    log_warn "notification NOT delivered (no synodsmnotify/synonotify/webhook): $_title"
  fi
}
