# Offline Install (Release Zip)

[← README](../README.md) · [中文](zh/release-packaging.md)
Manual: [Architecture](architecture.md) · [Installation](installation.md) · **Release Zip** · [Configuration](configuration.md) · [Auto-Update](auto-update.md) · [Operations](operations.md) · [Troubleshooting](troubleshooting.md) · [Development](development.md)

---

The standard [Installation](installation.md) starts with `git clone` from GitHub. In **mainland China
github.com is unreachable**, so that first step fails. This guide is the alternative: build a
**release zip** on a machine that *does* have access, carry it to the NAS, unpack it into
`/volume1/docker/syno-mihomo-gateway`, and configure it locally — **no git, no GitHub on the NAS**.

The zip is **source-only** (compose file, scripts, config templates, docs). It deliberately does
**not** carry container images. Those reach the NAS the same way the auto-updater already uses them:
mirrored to your **Alibaba ACR** by [`docker-china-sync`](https://github.com/czhaoca/docker-china-sync),
then pulled from that ACR (step 4). So an offline install is a two-track setup — **code via this zip,
images via your ACR mirror** — and the NAS never needs to reach github.com or Docker Hub/ghcr.

## When to use this

- The NAS cannot reach **github.com** (mainland China, or a network that blocks it) → use the zip
  instead of [Installation › Option A (git clone)](installation.md#1-get-the-code).
- You simply prefer not to install/run `git` on the NAS.
- If the NAS *does* have GitHub access, the standard `git clone` install is simpler — use that.

## 1. Build the release zip (on a machine with access)

On any workstation that can reach github.com (your laptop, a VPS, a CI box):

```bash
git clone https://github.com/czhaoca/syno-mihomo-gateway.git
cd syno-mihomo-gateway
sh scripts/ci/dsm_installer_check.sh
sh scripts/ci/lifecycle_check.sh
sh scripts/ci/auto_update_check.sh
sh scripts/ci/cloudflared_check.sh
python3 scripts/ci/package_check.py
python3 scripts/ci/privacy_check.py
python3 scripts/ci/privacy_check_test.py
docker compose --env-file .env.example config --quiet
sh scripts/package.sh                    # end-user DSM bundle (default profile)
```

Do not publish a release unless these commands and the Woodpecker pipeline pass. The updater tests
use fake Docker/Compose CLIs to exercise pull retries, image-ID comparison, architecture rejection,
Compose apply failure, health rollback, scheduler quoting, and staged cloudflared cutover/rollback without
touching a real daemon.

This writes to `dist/`:

```text
dist/syno-mihomo-gateway-1.0.0.zip            # File Station GUI friendly (no SSH needed to extract)
dist/syno-mihomo-gateway-1.0.0.tar.gz         # preserves script exec bits through extraction
dist/syno-mihomo-gateway-1.0.0.zip.sha256     # integrity sidecars
dist/syno-mihomo-gateway-1.0.0.tar.gz.sha256
```

The version comes from the repo's `VERSION` file. The archive is built with `git archive`, so it
contains **only tracked files** — your `.env`, `config/subscription.txt`, and `config/config.yaml`
can never be in it. `.env.example` and `config/subscription.txt.example` *are* included as templates.
(Maintainers: see [Development › Cutting a release](development.md#cutting-a-release).)

## 2. Transfer the zip to the NAS

Move `dist/syno-mihomo-gateway-<version>.zip` (or `.tar.gz`) to the NAS by any out-of-band channel:

- **USB drive** — copy the file, plug it into a DSM USB port, copy it off in File Station; or
- **File Station upload** — drag-drop the file over your LAN into, e.g., `/volume1/docker`.

Carry the matching `.sha256` too if you want to verify integrity after transfer.

## 3. Unpack into `/volume1/docker`

Both archives extract into a top-level `syno-mihomo-gateway/` folder, so unpacking inside
`/volume1/docker` lands the tree at exactly `/volume1/docker/syno-mihomo-gateway` — the path every
doc and the DSM scheduler command assume.

- **File Station (no SSH):** right-click the `.zip` → **Extract** → extract into `/volume1/docker`.
- **SSH:**
  ```bash
  cd /volume1/docker
  sha256sum -c syno-mihomo-gateway-1.0.0.zip.sha256     # optional integrity check
  unzip syno-mihomo-gateway-1.0.0.zip                   # or: tar -xzf syno-mihomo-gateway-1.0.0.tar.gz
  cd syno-mihomo-gateway
  ```

> **Exec bits:** File Station's `.zip` extraction drops the Unix executable bit. `bootstrap.sh`
> (next step) restores it. If you extract over SSH and want the bits preserved without bootstrap,
> use the `.tar.gz` instead.

## 4. Make sure your images are in your ACR

Because Docker Hub/ghcr are blocked too, the NAS pulls its images from **your Alibaba ACR**, kept
current by [`docker-china-sync`](https://github.com/czhaoca/docker-china-sync). Before starting the
stack, confirm:

- `docker-china-sync` is mirroring `metacubex/mihomo` and `ghcr.io/metacubex/metacubexd` into your
  ACR namespace (see its
  [Using with syno-mihomo-gateway](https://github.com/czhaoca/docker-china-sync#using-with-syno-mihomo-gateway)
  section), and
- in the next step you point `MIHOMO_IMAGE` / `METACUBEXD_IMAGE` (and `DOCKER_REGISTRY` /
  `ACR_NAMESPACE` / credentials) in `.env` at that ACR — full reference in
  [Configuration](configuration.md) and [Auto-Update › ACR setup](auto-update.md#acr-setup).

The NAS only needs to reach your ACR — never github.com.

## 5. Configure and start

Run the first-run helper from the unpacked folder:

```bash
sh bootstrap.sh
```

It seeds `../syno-mihomo-gateway-data/.env` and its `config/subscription.txt` from the shipped
examples (only if absent), migrates legacy in-tree files, restores script exec bits, and prints
the next steps. It writes no secrets and runs nothing privileged.

From here the steps are **identical to the standard install** — follow them in
[Installation](installation.md):

1. [Configure `.env`](installation.md#2-configure-env) — set `ROUTER_IP`, `MIHOMO_IP`, DNS, and your
   ACR registry/credentials + image refs from step 4.
2. [Add your subscription](installation.md#3-add-your-subscription).
3. [Create the network + TUN device](installation.md#4-create-the-network--tun-device) —
   `sudo ./scripts/setup_network.sh`.
4. [Start the stack](installation.md#5-start-the-stack) — use the guided installer, or pass the
   persistent env file explicitly to Compose.

## 6. Verify

- [ ] Tree is at `/volume1/docker/syno-mihomo-gateway`.
- [ ] `../syno-mihomo-gateway-data/.env` exists (`chmod 600`); image refs point at your ACR.
- [ ] `../syno-mihomo-gateway-data/config/subscription.txt` contains your real URL.
- [ ] `docker images` shows the mihomo and metacubexd images pulled from your ACR.
- [ ] `sudo ./scripts/setup_network.sh` succeeded (macvlan + TUN created).
- [ ] The guided installer reports the containers healthy.
- [ ] The dashboard opens from a **non-NAS** LAN device at `http://<NAS_IP>:<WEB_UI_PORT>`.

## Updating an offline install

There is no `git pull` here. To update the **code**:

1. Rebuild the zip on the connected machine (`git pull && sh scripts/package.sh`) and transfer it.
2. Replace or unpack the release tree. Runtime data is preserved independently in
   `/volume1/docker/syno-mihomo-gateway-data`, so removing the old release directory is safe.
3. `sh bootstrap.sh` (a no-op for existing config; just restores exec bits), then run
   `sudo sh ./install.sh` and choose **Redeploy**. This forces Mihomo to render and activate
   the updated gateway configuration; a plain `docker compose up -d` may leave it unchanged.

Updating the **images** is unchanged: `scripts/auto_update.sh` (DSM Task Scheduler) pulls from your
ACR — not GitHub — so the normal [Auto-Update](auto-update.md) flow works on an offline install too.
