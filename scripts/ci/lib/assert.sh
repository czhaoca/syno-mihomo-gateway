#!/bin/sh
# assert.sh - shared assertion vocabulary for the scripts/ci/*_check.sh suites.
# Sourced, not executed. POSIX/BusyBox sh. Counters PASS/FAIL are owned by the
# sourcing suite's summary block; this file only initializes them when unset so
# sourcing twice (or after the suite set them) never resets a running count.

PASS="${PASS:-0}"
FAIL="${FAIL:-0}"

ok() { PASS=$((PASS + 1)); }
fail() { printf 'FAIL: %s\n' "$*" >&2; FAIL=$((FAIL + 1)); }
expect_success() { _name="$1"; shift; if "$@"; then ok; else fail "$_name"; fi; }
expect_failure() { _name="$1"; shift; if "$@"; then fail "$_name"; else ok; fi; }
assert_contains() {
  _name="$1"; _text="$2"; _needle="$3"
  case "$_text" in *"$_needle"*) ok ;; *) fail "$_name (missing: $_needle)" ;; esac
}
assert_not_contains() {
  _name="$1"; _text="$2"; _needle="$3"
  case "$_text" in *"$_needle"*) fail "$_name (unexpected: $_needle)" ;; *) ok ;; esac
}
