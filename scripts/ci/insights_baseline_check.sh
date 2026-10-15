#!/bin/sh
# insights_baseline_check.sh - CI driver for scripts/insights_baseline.sh, the
# read-only Gateway Insights baseline probe (#90). Proves, hermetically:
#   - the script parses as POSIX sh and is ASCII-only;
#   - its --self-test is green and says so (the self-test itself carries the
#     positive control, the missing-key / probe-failed / container-down
#     negative controls, and - where python3 exists - the in-container
#     program's fixture layer);
#   - the self-test can go RED: a mutant that drops a key from the required
#     contract list turns the missing-key control into a false pass, which
#     the self-test must report;
#   - a failed probe never prints exception text (it could carry the
#     controller URL) - a static guard on the program text.
# BusyBox-ash safe; no network, no docker (the self-test stubs it).
set -eu

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)"
# shellcheck source=scripts/ci/lib/assert.sh
# shellcheck disable=SC1091 # followed only under -x; the lib is parse-checked by CI
. "$ROOT/scripts/ci/lib/assert.sh"
IB="$ROOT/scripts/insights_baseline.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM

# 1) the probe exists, parses, and is ASCII-only (the shellcheck image chokes
#    on non-ASCII output; the repo rule is ASCII in every shell script)
if [ -f "$IB" ]; then ok; else fail "scripts/insights_baseline.sh is missing"; fi
expect_success "sh -n insights_baseline.sh" sh -n "$IB"
if LC_ALL=C grep -q '[^ -~]' "$IB" 2>/dev/null; then
  fail "insights_baseline.sh contains non-ASCII or control bytes"
else
  ok
fi

# 2) the self-test is green and ends with its OK line
RC=0
OUT="$(sh "$IB" --self-test 2>&1)" || RC=$?
if [ "$RC" = 0 ]; then ok; else fail "self-test rc=$RC: $OUT"; fi
assert_contains "self-test OK line" "$OUT" "OK: insights_baseline"

# 3) the self-test can go red: drop mihomo_version from the required-key
#    contract and the missing-key control must fail the run
sed 's/ mihomo_version / /' "$IB" > "$TMP/mutant.sh"
if grep -q ' mihomo_version ' "$TMP/mutant.sh"; then
  fail "mutant did not drop the key (sed seam moved)"
else
  ok
fi
RC=0
MOUT="$(sh "$TMP/mutant.sh" --self-test 2>&1)" || RC=$?
if [ "$RC" != 0 ]; then ok; else fail "mutant self-test stayed green (rc 0)"; fi
assert_contains "mutant names the missing-key control" "$MOUT" "missing-key"

# 4) static contract: every key in IB_REQUIRED has a matching emit("<key>" in
#    the in-container program - the drift the alpine step can catch without
#    a python3 (the fixture layer itself runs in CI's python image)
KEYS="$(sed -n 's/^IB_REQUIRED=" \(.*\) "$/\1/p' "$IB")"
if [ -n "$KEYS" ]; then ok; else fail "IB_REQUIRED line not found (sed seam moved)"; fi
for k in $KEYS; do
  if grep -q "emit(\"$k\"" "$IB"; then ok; else fail "required key $k has no emit() in the program"; fi
done

# 5) static hygiene: a failed probe names the stage, never the exception
TEXT="$(cat "$IB")"
assert_not_contains "no exception text (str(e))" "$TEXT" "str(e)"
assert_not_contains "no exception text (print(e)" "$TEXT" "print(e"
assert_not_contains "no traceback import" "$TEXT" "import traceback"
assert_contains "probe failure is named" "$TEXT" 'print("probe_failed=" + name)'
assert_contains "parse failure is named" "$TEXT" 'print("probe_failed=parse")'

echo "insights_baseline_check: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
echo "OK: insights_baseline.sh parses (ASCII), its self-test is green and can go red (mutant), every required key is emitted by the program, and a failed probe never prints exception text"
