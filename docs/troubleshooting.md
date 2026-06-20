# Troubleshooting & FAQ

[← README](../README.md) · [中文](zh/troubleshooting.md)
Manual: [Architecture](architecture.md) · [Installation](installation.md) · [Release Zip](release-packaging.md) · [Configuration](configuration.md) · [Auto-Update](auto-update.md) · [Operations](operations.md) · **Troubleshooting** · [Development](development.md)

---

## Exit codes (auto_update.sh)

| Code | Meaning | What to do |
|---|---|---|
| `0` | success / no-op | nothing |
| `2` | partial failure | read the notification + `logs/auto-update.log` |
| `3` | config / preflight error | fix the reported precondition; nothing was changed |
| `4` | another run holds the lock | wait, or remove a stale `LOCK_DIR` if no run is active |
| `5` | ACR login failed | check `ACR_PASSWORD` / token expiry / registry host |

## macvlan self-reach

**Symptom:** from the NAS, `curl http://MIHOMO_IP:9090` or the dashboard "Add backend" times
out, but other devices work.

**Cause:** by Linux macvlan design a host **cannot** reach its own macvlan container's IP. This
is expected, not a bug.

**Fix / workaround:**
- Open the dashboard and run connectivity tests from a **different LAN device**.
- The updater's mihomo health probe already runs *inside* the container (`docker exec`) to avoid
  this; from the NAS you can do the same: `docker exec mihomo wget -qO- http://127.0.0.1:9090/version`.
- If you genuinely need host→container reach, add a macvlan shim interface on the NAS (advanced).

## Architecture mismatch (ARM NAS)

**Symptom:** updater logs `arch mismatch for … image=amd64 expected=arm64 - refusing to deploy`,
or a container crash-loops with `exec format error`.

**Cause:** `docker-china-sync` mirrors `linux/amd64` by default; your NAS is ARM.

**Fix:** add arm64 to the mirror (`--platform=linux/amd64,linux/arm64` in
`docker-china-sync/images.txt`) and set `EXPECTED_ARCH=arm64`; or run on an Intel NAS. The guard
refusing to deploy is *protecting* you from a crash-loop — it's working as intended.

## Network missing after reboot

**Symptom:** after a NAS reboot, `docker compose up -d` or the updater fails with
`network tproxy_network … could not be found`, or the updater preflight aborts (code `3`).

**Cause:** a CLI-created macvlan does not always survive a reboot / Container Manager restart;
the parent interface can also change (`eth0` ↔ `ovs_eth0`).

**Fix:** add the **Boot-up** Task Scheduler entry that runs `scripts/setup_network.sh` (see
[Operations › Scheduling](operations.md#scheduling-on-dsm)). To recover now:
`sudo ./scripts/setup_network.sh && docker compose up -d`.

## Dashboard can't connect to the backend

Checklist:
- Using the **NAS IP** (`http://NAS_IP:WEB_UI_PORT`) for the UI, and the **mihomo IP** + 
  `CONTROLLER_PORT` for the *backend*?
- Testing from a non-NAS device (macvlan self-reach)?
- `CONTROLLER_SECRET` entered if you set one?
- Is the controller actually enabled? `docker exec mihomo wget -qO- http://127.0.0.1:9090/version`
  should return JSON. If not, check `docker logs mihomo` for a render/start error.

**Most common cause: CORS.** If the backend is reachable from a LAN device
(`curl http://MIHOMO_IP:CONTROLLER_PORT/version` returns JSON) but MetaCubeXD still reports
*"cannot connect to backend" / "无法连接后端"*, it is a cross-origin block — **not** a network or
secret problem. The dashboard is served from `http://NAS_IP:WEB_UI_PORT` while the controller
answers on `MIHOMO_IP:CONTROLLER_PORT` (a different origin), and recent mihomo ships a
**restrictive** default CORS allow-list (only the bundled/hosted dashboards, not arbitrary LAN
addresses). Confirm in the browser DevTools (F12) → Console — you'll see a CORS error. The config
template now sets:

```yaml
external-controller-cors:
  allow-origins:
    - '*'        # the secret still gates real API access
  allow-private-network: true
```

so a fresh deploy already allows your dashboard. On a gateway deployed **before** this was added,
update `config/config.template.yaml` (or the rendered `…-data/config/config.yaml`) and re-render
with `docker compose up -d --force-recreate mihomo` — the entrypoint re-renders `config.yaml` from
the template on start.

## Containers are healthy but LAN clients have no internet

Run the read-only structural diagnostic first:

```bash
sudo sh scripts/doctor.sh --egress
```

It checks the host TUN device, macvlan, Compose model, image architecture, controller, and the
in-container `mihomo-tun` dataplane. Exit `0` is structurally healthy, `2` is degraded external
proxy egress, and `3` is a local configuration/runtime failure. If it passes, test gateway and
DNS from a different LAN device because the NAS cannot reach its own macvlan child.

## mihomo won't start / crash-loops

```bash
docker logs mihomo --tail 80
```
Common causes:
- **Empty/garbled subscription or DNS** — the renderer fails loudly:
  `ERROR: subscription.txt has no usable URL` or `ERROR: DNS_… must be set`. Fix
  `config/subscription.txt` / the `DNS_*` keys in `.env`, then `docker compose up -d mihomo`.
- **`/dev/net/tun` missing** — run `sudo ./scripts/setup_network.sh`.
- **`iptables (nf_tables): Could not fetch rule set generation id`** — the image's nft-backed
  iptables is incompatible with the DSM kernel. Set `TUN_AUTO_REDIRECT=false` in `.env` and
  redeploy; TUN `auto-route` still provides the gateway dataplane.
- **Wrong arch image** — see above.

## Subscription URL looks wrong in config.yaml

The renderer strips only an optional leading `Name=` label and preserves everything else,
including `?token=…&flag=…`. If your provider URL itself contains a literal `|` or `\`, those are
escaped for `sed`; a stray newline in `subscription.txt` is ignored (first valid line only).
Verify the rendered value:

```bash
docker exec mihomo grep -m1 'url:' /root/.config/mihomo/config.yaml
```

## ACR login fails (code 5)

- Confirm `DOCKER_REGISTRY` host, `DOCKER_USERNAME`, and `ACR_PASSWORD` (the latter is a secret;
  ensure `.env` is `chmod 600`).
- ACR access tokens can expire — regenerate in the Alibaba console.
- Test by hand: `printf '%s' "$ACR_PASSWORD" | docker login "$DOCKER_REGISTRY" -u "$DOCKER_USERNAME" --password-stdin`.

## Pulls are slow / time out

Network flakiness to ACR. The updater retries pulls (`PULL_RETRIES`/`PULL_RETRY_DELAY`) and
pulls **before** swapping, so a failed pull aborts without touching the running container.
Increase the retry env vars if needed, or schedule further from the mirror window.

## DSM 7 scheduled task does not run

1. In **Control Panel → Task Scheduler**, verify the task is enabled and runs as **root**.
2. Re-run `sh scripts/install_scheduler.sh` and copy its exact absolute-path command.
3. Confirm the Schedule time against **Regional Options**; `UPDATE_TZ` only affects log timestamps.
4. Select the task and click **Run**, then inspect its saved result and `logs/auto-update.log`.
5. Exit code `3` with a Docker readiness message means Container Manager did not become ready
   within `DOCKER_READY_TIMEOUT`; verify the package is running or increase the timeout.

If each line appears twice or rotation looks wrong, remove any outer
`>> logs/auto-update.log 2>&1` from the DSM command. The updater logs internally.

## Compose apply failed during auto-update

The updater now treats a failed `compose up` as a rollback event, not only an unhealthy start.
Look for `ROLLED BACK` in the notification/log. If rollback is incomplete, do not prune images:
verify the old IDs with `docker image inspect <id>`, then follow
[Operations › Manual rollback](operations.md#manual-rollback).

## cloudflared tunnel down after an update

The staged path verifies a temporary connector before replacing the canonical container and keeps
that candidate if canonical update and rollback cannot complete. If only
`cloudflared-candidate` is running, do not remove it—it may be the only live connector:

```bash
docker ps -a | grep cloudflared
docker logs --tail 100 cloudflared-candidate
```

Recreate the canonical container from the original run settings while the candidate remains live.
Emergency fallback: rename the candidate to `cloudflared`; its temporary dynamic IP and omitted
host-port bindings remain until you reconstruct the full canonical specification.

## "no image changes" but I expected an update

The updater compares the **running** container's image to the freshly-pulled tag, and only
deploys refs that match `MIHOMO_IMAGE`/`METACUBEXD_IMAGE`/`CF_IMAGE`. If you set `UPDATE_IMAGES`
to a ref that differs from those three, it's pulled **cache-only** and you'll see a `WARN`. Align
them (see [Auto-Update › image refs](auto-update.md#image-refs)). Also confirm the mirror actually
pushed a new digest (check the `docker-china-sync` GitHub Actions run).

## CI didn't run

The pipeline triggers on branches `main` **and** `master`. If you use another branch name, add
it to `.woodpecker.yml`'s `when.branch`.

## Whole house lost internet

If devices use `MIHOMO_IP` as gateway/DNS and mihomo is down, they're cut off. Quickest
recovery: point the affected device's gateway/DNS back to the router, then fix mihomo
(`docker compose up -d mihomo`, check logs). Consider the kill-switch + maintenance windows for
risky changes.
