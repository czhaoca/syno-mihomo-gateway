#!/bin/sh
# migrate_legacy_check.sh - behavioral suite for scripts/migrate_legacy.sh,
# the legacy flat-install importer. Until now the only fully-untested root-run
# entry point (headless, pre-wizard, copies into user state as root) - the
# same risk profile as the 2026-07 incident scripts.
#
# Asserts the documented contract (header of migrate_legacy.sh):
#   rc 0 imported or clean no-op | 2 copy failure | 3 no legacy dir / bad args
#   | 6 needs root | 7 refused without --yes
# plus the never-clobber import rules (configured subscription untouched;
# placeholder overridden; second run idempotent) and the .env hints.
#
# Every invocation is HERMETIC (env -i, tree copy, stub id/cp seams only) so
# the suite itself cannot mask an env-dependence bug the way the LOCK_DIR
# incident was masked. Runs under BusyBox ash (alpine) and any POSIX sh.
set -eu

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)"

pass=0; failn=0
ok()   { pass=$((pass+1)); }
fail() { echo "FAIL: $*" >&2; failn=$((failn+1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM

# --- hermetic tree copy: the default data-dir path lands inside $TMP ------------
TREE="$TMP/syno-mihomo-gateway"
DATA="$TMP/syno-mihomo-gateway-data"     # dirname(REPO_ROOT)/syno-mihomo-gateway-data
mkdir -p "$TREE"
cp -R "$ROOT/scripts" "$TREE/scripts"
cp -R "$ROOT/config" "$TREE/config"      # subscription.txt.example (placeholder compare)
# a dev tree may hold REAL gitignored runtime files under config/ - never let
# them ride into the sandbox.
rm -f "$TREE/config/subscription.txt" "$TREE/config/config.yaml"
ML="$TREE/scripts/migrate_legacy.sh"

# --- stub seams -----------------------------------------------------------------
STUB="$TMP/bin"; mkdir -p "$STUB"
cat > "$STUB/id" <<'EOF'
#!/bin/sh
[ "${1:-}" = "-u" ] && { echo "${FAKE_UID:-0}"; exit 0; }
exit 0
EOF
chmod +x "$STUB/id"
# A cp that always fails, for the rc-2 (EXIT_PARTIAL) case: root in CI cannot
# be blocked by permissions, so the copy failure is injected via PATH instead.
BADSTUB="$TMP/badbin"; mkdir -p "$BADSTUB"
cat > "$BADSTUB/cp" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "$BADSTUB/cp"

# --- legacy fixture (the pre-1.3 flat layout triple + geodata + cache) -----------
LEG="$TMP/legacy"; mkdir -p "$LEG"
cat > "$LEG/config.yaml" <<'EOF'
external-controller: 0.0.0.0:9091
secret: "legacy-secret"
EOF
cat > "$LEG/docker-compose.yml" <<'EOF'
services:
  mihomo:
    networks:
      tproxy:
        ipv4_address: 192.0.2.161
EOF
printf '%s\n' 'Legacy=https://legacy.example/sub?token=abc' > "$LEG/subscription.txt"
printf 'geodata-bytes' > "$LEG/GeoSite.dat"
printf 'cache-bytes' > "$LEG/cache.db"

# run [FAKE_UID=n] [PATH_OVERRIDE] -- migrate_legacy args...; captures out/err/rc.
run() {
  _r_uid="$1"; _r_path="$2"; shift 2
  RC=0
  env -i PATH="$_r_path" FAKE_UID="$_r_uid" SMG_LEGACY_DIR="$LEG" \
    sh "$ML" "$@" </dev/null >"$TMP/out" 2>"$TMP/err" || RC=$?
}

# --- usage / bad args -> 0 / 3 ---------------------------------------------------
run 0 "$STUB:/usr/bin:/bin" --help
[ "$RC" = 0 ] && ok || fail "--help exited $RC (want 0)"
grep -q 'Usage:' "$TMP/out" || fail "--help lacks usage text"
run 0 "$STUB:/usr/bin:/bin" --definitely-bogus
[ "$RC" = 3 ] && ok || fail "unknown argument exited $RC (want 3)"
run 0 "$STUB:/usr/bin:/bin" --from
[ "$RC" = 3 ] && ok || fail "--from with no value exited $RC (want 3)"

# --- a dir that is not a flat install -> 3 ---------------------------------------
mkdir -p "$TMP/notlegacy"
run 0 "$STUB:/usr/bin:/bin" --from "$TMP/notlegacy" --dry-run
[ "$RC" = 3 ] && ok || fail "--from non-install exited $RC (want 3)"
grep -q 'does not look like' "$TMP/err" || fail "non-install rejection lacks the reason"

# --- dry-run: no root needed, plan only, writes NOTHING ---------------------------
run 1000 "$STUB:/usr/bin:/bin" --dry-run
[ "$RC" = 0 ] && ok || fail "--dry-run exited $RC (want 0; stderr: $(tail -n2 "$TMP/err" | tr '\n' ' '))"
grep -q 'plan  copy' "$TMP/out" || fail "--dry-run printed no plan lines"
[ ! -d "$DATA" ] && ok || fail "--dry-run created the data dir"

# --- mutating run gates: root (6) then --yes (7) ----------------------------------
run 1000 "$STUB:/usr/bin:/bin"
[ "$RC" = 6 ] && ok || fail "non-root mutating run exited $RC (want 6)"
run 0 "$STUB:/usr/bin:/bin"
[ "$RC" = 7 ] && ok || fail "root run without --yes exited $RC (want 7)"
[ ! -d "$DATA" ] && ok || fail "refused runs still created the data dir"

# --- the real import: subscription + geodata + cache, mode 600, .env hints -------
run 0 "$STUB:/usr/bin:/bin" --yes
[ "$RC" = 0 ] && ok || fail "import exited $RC (want 0; stderr: $(tail -n2 "$TMP/err" | tr '\n' ' '))"
cmp -s "$DATA/config/subscription.txt" "$LEG/subscription.txt" \
  && ok || fail "subscription.txt was not imported verbatim"
cmp -s "$DATA/config/GeoSite.dat" "$LEG/GeoSite.dat" || fail "GeoSite.dat was not imported"
cmp -s "$DATA/config/cache.db" "$LEG/cache.db" || fail "cache.db was not imported"
case "$(ls -l "$DATA/config/subscription.txt" | cut -c1-10)" in
  -rw-------) ok ;;
  *) fail "imported subscription is not mode 600: $(ls -l "$DATA/config/subscription.txt")" ;;
esac
grep -q 'MIHOMO_IP=192.0.2.161' "$TMP/out" || fail ".env hint MIHOMO_IP missing/wrong"
grep -q 'CONTROLLER_PORT=9091' "$TMP/out" || fail ".env hint CONTROLLER_PORT missing/wrong"
grep -q 'CONTROLLER_SECRET' "$TMP/out" || fail "secret presence hint missing"

# --- idempotence: a second run only skips and changes nothing ---------------------
run 0 "$STUB:/usr/bin:/bin" --yes
[ "$RC" = 0 ] && ok || fail "second import exited $RC (want 0)"
grep -q 'skip' "$TMP/out" || fail "second run printed no skip lines"
cmp -s "$DATA/config/GeoSite.dat" "$LEG/GeoSite.dat" || fail "second run altered GeoSite.dat"

# --- a CONFIGURED subscription is never clobbered ---------------------------------
printf '%s\n' 'Mine=https://mine.example/sub?token=real' > "$DATA/config/subscription.txt"
run 0 "$STUB:/usr/bin:/bin" --yes
[ "$RC" = 0 ] && ok || fail "import over configured subscription exited $RC (want 0)"
grep -q 'configured subscription' "$TMP/out" || fail "no skip notice for the configured subscription"
grep -q 'mine.example' "$DATA/config/subscription.txt" \
  && ok || fail "a configured subscription was clobbered by the import"

# --- a PLACEHOLDER subscription is imported over ----------------------------------
cp "$TREE/config/subscription.txt.example" "$DATA/config/subscription.txt"
run 0 "$STUB:/usr/bin:/bin" --yes
[ "$RC" = 0 ] && ok || fail "import over placeholder exited $RC (want 0)"
cmp -s "$DATA/config/subscription.txt" "$LEG/subscription.txt" \
  && ok || fail "the shipped placeholder subscription was not replaced by the legacy one"

# --- copy failure -> rc 2 (EXIT_PARTIAL), reported not fatal ----------------------
rm -f "$DATA/config/GeoSite.dat"
run 0 "$BADSTUB:$STUB:/usr/bin:/bin" --yes
[ "$RC" = 2 ] && ok || fail "copy failure exited $RC (want 2)"
grep -qi 'could not' "$TMP/err" || fail "copy failure was not reported on stderr"

echo "migrate_legacy: $pass checks passed, $failn failed"
[ "$failn" -eq 0 ] || exit 1
echo "OK: migrate_legacy.sh contract (usage/arg/rc gates, dry-run plans without writing, root + --yes gates, verbatim never-clobber import with mode 600, placeholder override, idempotent re-run, .env hints, partial-copy rc 2)"
