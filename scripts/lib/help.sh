#!/bin/sh
# help.sh - GENERATED from scripts/cli/spec.yaml - DO NOT EDIT.
# Regenerate: python3 scripts/ci/cli_contract_check.py --write
# Runtime --help text for scripts/gateway.sh. English only by decision
# (DEC-9): Chinese ships as docs/zh/cli.md + docs/CLI.zh.txt from the
# same spec. POSIX /bin/sh, BusyBox-safe.

usage() {
  cat <<'SMG_HELP_EOF'
Usage: sh ./scripts/gateway.sh <verb> [options]

Non-interactive command surface for the Mihomo transparent-proxy gateway on Synology DSM. Other procedures (DSM Task Scheduler, scripts, CI) call these verbs directly; the interactive installer (sh ./install.sh, or the platform entry install-linux.sh / install-pi.sh) is the guided front-end over the same functions.

Verbs:
  deploy     Bring the gateway up end-to-end from the saved .env (derives image refs when absent).
  redeploy   Deploy strictly from the saved, complete .env (never derives or prompts).
  modify     Change one thing, then re-apply the full fail-closed pipeline.
  cron       Persist the auto-update schedule; optionally write a crontab entry.
  status     Read-only deployment state (stack, containers, network, dashboard URL).
  doctor     Read-only diagnostics (exit 0 healthy / 2 degraded / 3 broken). Human mode runs scripts/doctor.sh; --json runs the same check set natively.
  update     Run the unattended updater (execs scripts/auto_update.sh; args pass through) or manage its generic targets.
  policy     Dynamic device policy via the gateway panel (list entries, or set one device's mode) - a thin token-authed proxy over the panel HTTP API.

Guardrails:
  - Mutating verbs (deploy, redeploy, modify, update, cron --apply-crontab) require an explicit --yes; without it they exit 7 and change nothing.
  - Mutating verbs require root (exit 6 otherwise); status and doctor do not.
  - --dry-run never mutates the gateway or any container and needs neither --yes nor root (update --dry-run still pulls images into the local cache - that is its job).
  - Every verb accepts --help/-h for its own help; -y is a short alias for --yes.
  - Secrets are never accepted on the command line (argv is visible in ps) - set them in .env.
  - --json (status and doctor only) prints exactly one JSON object on stdout; every log line goes to the log file and stderr.
  - policy verbs are EXEMPT from --yes and root: they change only the panel's own policy database over its authenticated HTTP API - no host state, no container, no file on the gateway is touched directly, and the panel itself re-verifies every apply (parity read-back). The panel token comes from .env (PANEL_SECRET), never the command line.

Exit codes:
  0  success or clean no-op
  2  one component failed, others applied
  3  config / preflight error - nothing changed
  4  another run holds the lock
  5  registry login failed - nothing attempted
  6  this verb needs root - nothing changed
  7  mutating verb refused without an explicit --yes - nothing changed

Logs: gateway.sh writes <data-dir>/logs/gateway.log (lines carry verb= and run= fields). Direct auto_update.sh runs write auto-update.log - a link to gateway.log when gateway.sh ran first, otherwise a separate file - without those fields.
Full reference: docs/CLI.txt (developers: docs/cli.md)
SMG_HELP_EOF
}

# gw_help VERB - per-verb help; unknown verbs fall back to the global text.
gw_help() {
  case "$1" in
    deploy)
      cat <<'SMG_HELP_EOF'
Usage: gateway.sh deploy [options]

Bring the gateway up end-to-end from the saved .env (derives image refs when absent).

Options:
  --cleanup-containers preserve|auto  what to do with existing gateway containers before deploying (default preserve)
  --cleanup-network preserve|auto     what to do with an existing tproxy network before deploying (default preserve)
  --interface IFACE                   LAN parent interface for the macvlan (persisted to .env)
  --yes                               confirm the mutation (required when actually deploying)
  --dry-run                           print the deployment plan and exit without changing anything

Pipeline: validate config -> preflight -> plan cleanup -> pull + validate images -> apply cleanup -> network -> compose up + health gate (auto-rollback to the last-good images on failure).

Global help: gateway.sh --help
SMG_HELP_EOF
      ;;
    redeploy)
      cat <<'SMG_HELP_EOF'
Usage: gateway.sh redeploy [options]

Deploy strictly from the saved, complete .env (never derives or prompts).

Options:
  --cleanup-containers preserve|auto  same as deploy
  --cleanup-network preserve|auto     same as deploy
  --interface IFACE                   same as deploy
  --yes                               confirm the mutation
  --dry-run                           print the plan and exit without changing anything

Global help: gateway.sh --help
SMG_HELP_EOF
      ;;
    modify)
      cat <<'SMG_HELP_EOF'
Usage: gateway.sh modify [options]

Change one thing, then re-apply the full fail-closed pipeline.

Options:
  --network                           re-apply the network (TUN device + macvlan) from the saved settings
  --images                            re-derive the image refs and redeploy with them
  --mihomo-tag TAG                    with --images, pin the mihomo tag (persisted to .env)
  --metacubexd-tag TAG                with --images, pin the metacubexd tag (persisted to .env)
  --subscription URL                  replace the stored subscription URL (cleaned + validated first)
  --cleanup-containers preserve|auto  same as deploy
  --cleanup-network preserve|auto     same as deploy
  --yes                               confirm the mutation
  --dry-run                           validate the change and print the plan without applying it

Global help: gateway.sh --help
SMG_HELP_EOF
      ;;
    cron)
      cat <<'SMG_HELP_EOF'
Usage: gateway.sh cron [options]

Persist the auto-update schedule; optionally write a crontab entry.

Options:
  --time HH:MM            daily update time (24h clock; becomes a five-field cron expression)
  --schedule 'M H * * *'  a full five-field cron expression (validated)
  --tz ZONE               sets UPDATE_TZ, which only labels the updater's log timestamps - DSM Task Scheduler and crontab fire on the NAS SYSTEM timezone (Control Panel > Regional Options)
  --enable                set UPDATE_ENABLED=true
  --disable               set UPDATE_ENABLED=false
  --apply-crontab         append the entry to the system crontab (mutating - needs --yes and root)

Without --apply-crontab the verb only writes .env and prints the DSM Task Scheduler command to schedule (the recommended, DSM-native path).
Needs an existing .env (deploy first). When --time and --schedule are both given, --time wins. --apply-crontab manages its own entry: a changed schedule replaces the previous auto_update.sh line.

Global help: gateway.sh --help
SMG_HELP_EOF
      ;;
    status)
      cat <<'SMG_HELP_EOF'
Usage: gateway.sh status [options]

Read-only deployment state (stack, containers, network, dashboard URL).

Options:
  --json  emit one machine-readable JSON object on stdout

Exits 2 (ok:false) when docker/compose is unavailable or .env is malformed - the JSON object is still emitted; else 0.

Global help: gateway.sh --help
SMG_HELP_EOF
      ;;
    doctor)
      cat <<'SMG_HELP_EOF'
Usage: gateway.sh doctor [options]

Read-only diagnostics (exit 0 healthy / 2 degraded / 3 broken). Human mode runs scripts/doctor.sh; --json runs the same check set natively.

Options:
  --json    emit one machine-readable JSON object on stdout (--egress is human-mode only)
  --egress  also probe real proxy egress through the controller API

Global help: gateway.sh --help
SMG_HELP_EOF
      ;;
    update)
      cat <<'SMG_HELP_EOF'
Usage: gateway.sh update [options]

Run the unattended updater (execs scripts/auto_update.sh; args pass through) or manage its generic targets.

Options:
  --yes           confirm the mutation (not forwarded)
  --dry-run       pull + detect + report without swapping anything (forwarded)
  --force         ignore the UPDATE_ENABLED=false kill-switch (forwarded)
  --list-targets  read-only, no --yes/root; list enrolled generic targets and their eligibility
  --last          read-only, no --yes/root; show the outcome of the last updater run
  --enable NAME   enroll a container for generic auto-update (writes the managed list only; warns when NAME is not running or does not exist yet, and when the image looks like a database - recreate has no quiesce)
  --disable NAME  remove a container from generic auto-update (writes the managed list only)

--list-targets/--last/--enable/--disable are handled locally and reject any other flag; --dry-run cannot combine with them (it would bypass the --yes/root gates that protect the managed list).

Global help: gateway.sh --help
SMG_HELP_EOF
      ;;
    policy)
      cat <<'SMG_HELP_EOF'
Usage: gateway.sh policy [options]

Dynamic device policy via the gateway panel (list entries, or set one device's mode) - a thin token-authed proxy over the panel HTTP API.

Options:
  --list                                  print the panel's devices document (JSON, machine-readable passthrough)
  --set ADDRESS                           set the policy for an IPv4 address or CIDR (requires --mode; the panel validates and canonicalizes fail-closed)
  --mode full-tunnel|full-direct|default  with --set: the target mode; 'default' removes the entry
  --name NAME                             with --set: a display name for the device (optional)
  --note NOTE                             with --set: a note recorded on the audit entry (optional)

The verbs reach the panel API from INSIDE the mihomo-panel container (a macvlan child is unreachable from its own host); the panel is the SINGLE write path - nothing here touches SQLite or the provider files directly. The set output carries the panel's honest applied/parity answer: applied=false means the change is SAVED but did NOT reach mihomo yet (see doctor's policy_parity).
Requires the panel companion (deployed at gateway install/upgrade); PANEL_SECRET must be set in .env for mutations - the panel refuses writes without it (fail closed).

Global help: gateway.sh --help
SMG_HELP_EOF
      ;;
    *) usage ;;
  esac
}
