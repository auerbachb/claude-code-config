#!/usr/bin/env bash
# usage-horizon.test.sh — coverage for .claude/scripts/usage-horizon.sh (issue #2416).
# catalog: tests — Tests for `usage-horizon.sh` — the shim always answers clear, records nothing, and still rejects malformed invocations
#
# Since #2416 the in-thread tokens-left figure is not a launch input, so the
# script answers `clear` whatever it is handed. This suite pins that, plus:
#   - a low, zero, absurd or missing figure never produces another verdict
#   - nothing is written (no observation log, no session-state touch)
#   - usage errors keep exit 4, so a typo is never read as permission
#   - the account-usage protections stay separate files this one never reads

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="$ROOT/.claude/scripts/usage-horizon.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAILED=0
ok() { PASS=$((PASS + 1)); echo "ok   — $*"; }
bad() { FAILED=$((FAILED + 1)); echo "FAIL — $*" >&2; }
check_eq() { if [[ "$1" == "$2" ]]; then ok "$3"; else bad "$3 (got '$1', want '$2')"; fi; }

export HOME="$TMP/home"
mkdir -p "$HOME/.claude"

run() { OUT=$("$SCRIPT" "$@" 2>/dev/null); RC=$?; }

echo "== --check answers clear, whatever the history =="
run --check
check_eq "$RC|$OUT" $'0|STATUS=clear\nREASON=not-a-launch-input' "--check with nothing recorded is clear"
run --check --counter-never-seen
check_eq "$RC|$OUT" $'0|STATUS=clear\nREASON=not-a-launch-input' "--check --counter-never-seen is clear"

echo "== a low figure never holds or parks (regression for #2416) =="
for remaining in 0 1 1000 200000 1999999; do
  run --observe "$remaining" --limit 1000000
  check_eq "$RC" "0" "--observe $remaining exits 0"
  run --check
  check_eq "$OUT" $'STATUS=clear\nREASON=not-a-launch-input' "--check after --observe $remaining is still clear"
done
run --observe 5
run --check --session some-other-session
check_eq "$RC|$(printf '%s' "$OUT" | head -1)" "0|STATUS=clear" "a session override changes nothing"

echo "== nothing is written =="
WRITTEN=$(find "$HOME" -type f 2>/dev/null)
if [[ -n "$WRITTEN" ]]; then bad "the script wrote a file under HOME: $WRITTEN"; else ok "no file was written"; fi

echo "== malformed invocations still fail closed =="
run
check_eq "$RC" "4" "no mode is a usage error"
run --check --observe 5
check_eq "$RC" "4" "two modes are a usage error"
run --observe
check_eq "$RC" "4" "--observe without a value is a usage error"
run --bogus
check_eq "$RC" "4" "an unknown flag is a usage error"
run --check -- stray
check_eq "$RC" "4" "an argument after -- is a usage error"
run --check stray
check_eq "$RC" "4" "a stray positional is a usage error"

echo "== help =="
run --help
case "$OUT" in *"not a launch input"*|*"not-a-launch-input"*) ok "--help says the figure is not a launch input" ;; *) bad "--help missing the explanation" ;; esac

echo "== the script never reads account-usage state =="
if grep -Eq 'quota-reserve|credit-budget|session-state|total_tokens>' <(grep -v '^#' "$SCRIPT"); then
  bad "the shim's code references account-usage or session state"
else
  ok "the shim's code references neither account-usage nor session state"
fi

echo
echo "Results: $PASS passed, $FAILED failed"
[[ "$FAILED" -eq 0 ]]
