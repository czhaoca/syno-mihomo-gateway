# Offline Install (Release Zip)

[← README](../README.md) · [中文](zh/release-packaging.md)
Manual: [Architecture](architecture.md) · [Installation](installation.md) · **Release Zip** · [Configuration](configuration.md) · [Auto-Update](auto-update.md) · [Operations](operations.md) · [CLI](cli.md) · [Troubleshooting](troubleshooting.md) · [Development](development.md)

---

The standard [Installation](installation.md) starts with `git clone` from GitHub. In **mainland China
github.com is unreachable**, so that first step fails. This guide is the alternative: build a
**release zip** on a machine that *does* have access, carry it to the NAS, unpack it into
`/volume1/docker/syno-mihomo-gateway`, and configure it locally — **no git, no GitHub on the NAS**.

The zip is **source-only** (compose file, scripts, config templates, and the plain-text guides —
see [what's inside the bundle](#profiles-whats-inside-the-bundle)). It deliberately does
**not** carry container images. Those reach the NAS the same way the auto-updater already uses them:
mirrored to your **Alibaba ACR** by [`docker-china-sync`](https://github.com/czhaoca/docker-china-sync),
then pulled from that ACR (step 4). So an offline install is a two-track setup — **code via this zip,
images via your ACR mirror** — and the NAS never needs to reach github.com or Docker Hub/ghcr.

## When to use this

- The NAS cannot reach **github.com** (mainland China, or a network that blocks it) → use the zip
  instead of [Installation › Option A (git clone)](installation.md#1-get-the-code).
- You simply prefer not to install/run `git` on the NAS.
- If the NAS *does* have GitHub access, the standard `git clone` install is simpler — use that.

## 1. Get the release zip (on a machine with access)

**Fast path — download it.** Every GitHub release already publishes exactly the four artifacts
listed below (zip, tar.gz, and both `.sha256` sidecars). On any machine that can reach github.com,
download the latest release's assets and skip straight to step 2 — no clone, no build.

**Or build it yourself** from a clone:

```bash
git clone https://github.com/czhaoca/syno-mihomo-gateway.git
cd syno-mihomo-gateway
sh scripts/package.sh                    # end-user DSM bundle (default profile)
```

For a personal offline bundle that single command is enough. Maintainers cutting a *published*
release run the full check battery first — see
[Development › Cutting a release](development.md#cutting-a-release) and
[Development › Local checks before pushing](development.md#local-checks-before-pushing).

Either way you end up with:

```text
dist/syno-mihomo-gateway-<version>.zip            # File Station GUI friendly (no SSH needed to extract)
dist/syno-mihomo-gateway-<version>.tar.gz         # preserves script exec bits through extraction
dist/syno-mihomo-gateway-<version>.zip.sha256     # integrity sidecars
dist/syno-mihomo-gateway-<version>.tar.gz.sha256
```

The version comes from the repo's `VERSION` file (override with `--version X.Y.Z`). The archive is
built with `git archive`, so it contains **only tracked files** — your `.env`,
`config/subscription.txt`, and `config/config.yaml` can never be in it. `.env.example` and
`config/subscription.txt.example` *are* included as templates.

### Profiles: what's inside the bundle

`scripts/package.sh` builds one of two profiles:

- **`--profile enduser` (default)** — the curated, self-contained distribution: runtime files, the
  interactive installer, and the **plain-text guides only**. All Markdown docs (`README.md`,
  `docs/*.md`, `docs/zh/`), the dev/CI tooling (`scripts/ci`, `scripts/cli`, `.woodpecker.yml`),
  and `scripts/package.sh` itself are stripped. On the NAS the manuals are `docs/README.txt`,
  `INSTALL.txt`, `CONFIGURE.txt`, `TROUBLESHOOTING.txt`, `AUTO-UPDATE.txt`, and `CLI.txt` (plus
  `.zh.txt` Chinese variants). This page — and [Installation](installation.md), and every other
  `.md` cross-link in this guide — is **not** in the bundle; read the `.md` manual on the
  connected machine or online.
- **`--profile dev`** — the full tracked tree (docs, CI, metadata). Internal use; it is what CI's
  package check builds.

### Builder guards (why the build may refuse)

`package.sh` fails closed (exit 3) rather than ship something wrong:

- **Dirty working tree** — refused unless you pass `--allow-dirty`, which archives the committed
  `HEAD` (**not** your local edits) and appends `-dirty` to the version.
- **Tracked secrets** — refused if `.env`, `config/subscription.txt`, `config/config.yaml`, or
  anything under `logs/` is tracked by git (`git archive` would ship it); untrack with
  `git rm --cached <path>` first.
- **Not a git checkout** — it must run from the source clone, not an unpacked release bundle.
- **Identity leak-gate** (enduser profile only) — before writing any artifact, the staged tree is
  scanned for developer/identifying strings (plus an email-address regex). Any hit aborts with
  `IDENTITY LEAK`, names the offending string and file, and writes **no artifact**. The fix is to
  scrub the string from the offending *tracked* file, commit, and rebuild — re-running without a
  fix changes nothing.

Other flags: `--no-zip` / `--no-tar` skip one artifact (passing both is an error).

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
  sha256sum -c syno-mihomo-gateway-<version>.zip.sha256     # optional integrity check
  unzip syno-mihomo-gateway-<version>.zip                   # or: tar -xzf syno-mihomo-gateway-<version>.tar.gz
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
- in the next step you keep `REGISTRY_MODE=acr` (the default) and give the installer your
  `DOCKER_REGISTRY`, `ACR_NAMESPACE`, and credentials — it **derives** `MIHOMO_IMAGE` /
  `METACUBEXD_IMAGE` from those plus the `*_TAG` values, so you do not normally edit the image
  refs by hand — full reference in [Configuration](configuration.md) and
  [Auto-Update › ACR setup](auto-update.md#acr-setup).

The NAS only needs to reach your ACR — never github.com.

## 5. Configure and start

Run the first-run helper from the unpacked folder:

```bash
sh bootstrap.sh
```

It seeds `../syno-mihomo-gateway-data/.env` and its `config/subscription.txt` from the shipped
examples (only if absent), migrates legacy in-tree files, restores script exec bits, and prints
the next steps. It writes no secrets and runs nothing privileged.

Then run the **interactive installer** — the recommended flow the bundle is built for:

```bash
sudo sh ./install.sh
```

It walks you through `.env` (including `REGISTRY_MODE`/ACR and the derived image refs), the
subscription, the network + TUN device, and start-up. The bundled `docs/INSTALL.txt` and
`docs/CONFIGURE.txt` cover the same ground offline.

Prefer to configure by hand? The manual steps are **identical to the standard install** — follow
them in [Installation](installation.md) (on the connected machine; the `.md` manual is not in the
bundle):

1. [Configure `.env`](installation.md#2-configure-env) — set `ROUTER_IP`, `MIHOMO_IP`, DNS, and
   your ACR registry/credentials from step 4 (keep `REGISTRY_MODE=acr`).
2. [Add your subscription](installation.md#3-add-your-subscription).
3. [Create the network + TUN device](installation.md#4-create-the-network--tun-device) —
   `sudo ./scripts/setup_network.sh`.
4. [Start the stack](installation.md#5-start-the-stack) —
   `sudo docker compose --env-file ../syno-mihomo-gateway-data/.env up -d`.

## 6. Verify

- [ ] Tree is at `/volume1/docker/syno-mihomo-gateway`.
- [ ] `../syno-mihomo-gateway-data/.env` exists (`chmod 600`); `REGISTRY_MODE=acr` and the derived
      image refs point at your ACR.
- [ ] `../syno-mihomo-gateway-data/config/subscription.txt` contains your real URL.
- [ ] `docker images` shows the mihomo and metacubexd images pulled from your ACR.
- [ ] `sudo ./scripts/setup_network.sh` succeeded (macvlan + TUN created).
- [ ] The guided installer reports the containers healthy.
- [ ] The dashboard opens from a **non-NAS** LAN device at `http://<NAS_IP>:<WEB_UI_PORT>`.

## Updating an offline install

There is no `git pull` here. To update the **code**:

1. On the connected machine, download the newest release's assets (or rebuild:
   `git pull && sh scripts/package.sh`) and transfer the zip.
2. On the **first** upgrade from the legacy in-tree layout, unpack over the existing tree and run
   `sh bootstrap.sh`; do not delete the old tree until `.env` and the subscription have migrated.
   After `/volume1/docker/syno-mihomo-gateway-data` exists, future release directories can be
   replaced safely.
3. `sh bootstrap.sh` (a no-op for existing config; just restores exec bits), then run
   `sudo sh ./install.sh` and choose **Redeploy**. This forces Mihomo to render and activate
   the updated gateway configuration; a plain `docker compose up -d` may leave it unchanged.

Updating the **images** is unchanged: `scripts/auto_update.sh` (DSM Task Scheduler) pulls from your
ACR — not GitHub — so the normal [Auto-Update](auto-update.md) flow works on an offline install too.
