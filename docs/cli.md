# Command-line reference (gateway.sh)

<!-- This page is GENERATED from scripts/cli/spec.yaml - DO NOT EDIT. Regenerate: python3 scripts/ci/cli_contract_check.py --write -->

Non-interactive command surface for the Mihomo transparent-proxy gateway on Synology DSM. Other procedures (DSM Task Scheduler, scripts, CI) call these verbs directly; the interactive installer (sh ./install.sh, or the platform entry install-linux.sh / install-pi.sh) is the guided front-end over the same functions.

## Invocation

```sh
sh ./scripts/gateway.sh <verb> [options]
```

## Guardrails

- Mutating verbs (deploy, redeploy, modify, update, cron --apply-crontab) require an explicit --yes; without it they exit 7 and change nothing.
- Mutating verbs require root (exit 6 otherwise); status and doctor do not.
- --dry-run never mutates the gateway or any container and needs neither --yes nor root (update --dry-run still pulls images into the local cache - that is its job).
- Every verb accepts --help/-h for its own help; -y is a short alias for --yes.
- Secrets are never accepted on the command line (argv is visible in ps) - set them in .env.
- --json (status and doctor only) prints exactly one JSON object on stdout; every log line goes to the log file and stderr.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | success or clean no-op |
| 2 | one component failed, others applied |
| 3 | config / preflight error - nothing changed |
| 4 | another run holds the lock |
| 5 | registry login failed - nothing attempted |
| 6 | this verb needs root - nothing changed |
| 7 | mutating verb refused without an explicit --yes - nothing changed |

## Verbs

### `deploy`

Bring the gateway up end-to-end from the saved .env (derives image refs when absent).

| Flag | Description |
|---|---|
| `--cleanup-containers preserve|auto` | what to do with existing gateway containers before deploying (default preserve) |
| `--cleanup-network preserve|auto` | what to do with an existing tproxy network before deploying (default preserve) |
| `--interface IFACE` | LAN parent interface for the macvlan (persisted to .env) |
| `--yes` | confirm the mutation (required when actually deploying) |
| `--dry-run` | print the deployment plan and exit without changing anything |

Pipeline: validate config -> preflight -> plan cleanup -> pull + validate images -> apply cleanup -> network -> compose up + health gate (auto-rollback to the last-good images on failure).


### `redeploy`

Deploy strictly from the saved, complete .env (never derives or prompts).

| Flag | Description |
|---|---|
| `--cleanup-containers preserve|auto` | same as deploy |
| `--cleanup-network preserve|auto` | same as deploy |
| `--interface IFACE` | same as deploy |
| `--yes` | confirm the mutation |
| `--dry-run` | print the plan and exit without changing anything |


### `modify`

Change one thing, then re-apply the full fail-closed pipeline.

| Flag | Description |
|---|---|
| `--network` | re-apply the network (TUN device + macvlan) from the saved settings |
| `--images` | re-derive the image refs and redeploy with them |
| `--mihomo-tag TAG` | with --images, pin the mihomo tag (persisted to .env) |
| `--metacubexd-tag TAG` | with --images, pin the metacubexd tag (persisted to .env) |
| `--subscription URL` | replace the stored subscription URL (cleaned + validated first) |
| `--cleanup-containers preserve|auto` | same as deploy |
| `--cleanup-network preserve|auto` | same as deploy |
| `--yes` | confirm the mutation |
| `--dry-run` | validate the change and print the plan without applying it |


### `cron`

Persist the auto-update schedule; optionally write a crontab entry.

| Flag | Description |
|---|---|
| `--time HH:MM` | daily update time (24h clock; becomes a five-field cron expression) |
| `--schedule 'M H * * *'` | a full five-field cron expression (validated) |
| `--tz ZONE` | sets UPDATE_TZ, which only labels the updater's log timestamps - DSM Task Scheduler and crontab fire on the NAS SYSTEM timezone (Control Panel > Regional Options) |
| `--enable` | set UPDATE_ENABLED=true |
| `--disable` | set UPDATE_ENABLED=false |
| `--apply-crontab` | append the entry to the system crontab (mutating - needs --yes and root) |

Without --apply-crontab the verb only writes .env and prints the DSM Task Scheduler command to schedule (the recommended, DSM-native path).

Needs an existing .env (deploy first). When --time and --schedule are both given, --time wins. --apply-crontab manages its own entry: a changed schedule replaces the previous auto_update.sh line.


### `status`

Read-only deployment state (stack, containers, network, dashboard URL).

| Flag | Description |
|---|---|
| `--json` | emit one machine-readable JSON object on stdout |

Exits 2 (ok:false) when docker/compose is unavailable or .env is malformed - the JSON object is still emitted; else 0.


### `doctor`

Read-only diagnostics (exit 0 healthy / 2 degraded / 3 broken). Human mode runs scripts/doctor.sh; --json runs the same check set natively.

| Flag | Description |
|---|---|
| `--json` | emit one machine-readable JSON object on stdout (--egress is human-mode only) |
| `--egress` | also probe real proxy egress through the controller API |


### `update`

Run the unattended updater (execs scripts/auto_update.sh; args pass through) or manage its generic targets.

| Flag | Description |
|---|---|
| `--yes` | confirm the mutation (not forwarded) |
| `--dry-run` | pull + detect + report without swapping anything (forwarded) |
| `--force` | ignore the UPDATE_ENABLED=false kill-switch (forwarded) |
| `--list-targets` | read-only, no --yes/root; list enrolled generic targets and their eligibility |
| `--last` | read-only, no --yes/root; show the outcome of the last updater run |
| `--enable NAME` | enroll a container for generic auto-update (writes the managed list only; warns when NAME is not running or does not exist yet, and when the image looks like a database - recreate has no quiesce) |
| `--disable NAME` | remove a container from generic auto-update (writes the managed list only) |

--list-targets/--last/--enable/--disable are handled locally and reject any other flag; --dry-run cannot combine with them (it would bypass the --yes/root gates that protect the managed list).

## Machine-readable output (--json)

status --json emits one flat object: {"verb","ok","exit_code","stack_state","mihomo_ip","dashboard_url", "checks":[{"name","value"},...],"last_update":{...}|null} (last_update mirrors state/last-run.json; null before the first run). Its check names are env, docker, mihomo_container, ui_container, network, subscription, tun_enable. last-run.json carries {"ts","exit_code","dry_run","updated","unchanged","failed", "rolled_back","updated_names","failed_names","rolled_back_names"}. doctor --json emits {"verb","ok","exit_code","checks":[...]} with check names env, docker, arch, tun_device, network, compose, mihomo, tun_gateway, controller, image_arch, proxy_groups, dashboard, update_task, boot_task, cloudflared, subscription, host_dns, geodata, dns_privacy, config_rejected, ipv6_bypass, full_proxy (update_task/boot_task verify the DSM Task Scheduler deployment; proxy_groups is ok|default-empty|country-empty|provider-empty for the generated "<Country> Auto" url-test groups - default-empty means the country group selected in Country Pick matches no provider node (default-route traffic is REJECTED, fail closed), country-empty means some other COUNTRY_GROUPS entr(ies) match no node, provider-empty means EVERY url-test group is empty (a cold or dead provider - seed it, not a filter problem); cloudflared is ok|down|absent for the optional tunnel container; host_dns probes every host resolver; geodata is cached|missing; dns_privacy is v2|v1|legacy for the rendered DNS profile - v2 = split-horizon foreign-by-default, v1 = a pre-v1.3.10 render whose fallback dual-query still copies long-tail lookups to the domestic resolvers, legacy = the domestic resolvers see every lookup; config_rejected is ok|render-failed|config-test-failed|rejected - non-ok means the entrypoint gate refused the LAST rendered config (the .config.yaml.rejected marker exists), mihomo is running on the previous config and the latest .env/subscription edit is NOT applied ('rejected' = marker present but its reason line is unreadable); a green redeploy clears it; ipv6_bypass is ok|exposed - exposed means internet-routable global IPv6 (not a private ULA) is live on the LAN interface, a path dual-stack clients use around the IPv4-only gateway; full_proxy is disabled|ok|parity-drift|chain-violation for the per-device full-proxy band (FULL_PROXY_SOURCES) - disabled means the band is not in use, parity-drift means the rendered SRC-IP-CIDR rules differ from the knob (the band edit is not live - redeploy), chain-violation means a non-LAN flow from a band source bypassed the Full Proxy group (usually the documented UDP/QUIC fallthrough when the exit node lacks UDP relay; the guarantee also assumes no routable LAN IPv6 - see ipv6_bypass); "unknown" means the surface is not probeable on this box). Exactly one object on stdout; logs never interleave.

Logs: gateway.sh writes <data-dir>/logs/gateway.log (lines carry verb= and run= fields). Direct auto_update.sh runs write auto-update.log - a link to gateway.log when gateway.sh ran first, otherwise a separate file - without those fields.
