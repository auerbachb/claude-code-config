#!/usr/bin/env bash
# Offline tests for lib/gh-rate-budget.sh and its wiring into cr-plan.sh (issue #2445).
# catalog: tests — Tests for `lib/gh-rate-budget.sh` (allowance backoff) and the cr-plan.sh poll wiring
# Stubs `gh` and the sleep command: no test calls GitHub or sleeps for real.
# Run from repo root: bash .claude/scripts/tests/gh-rate-budget.test.sh
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
LIB="$REPO_ROOT/.claude/scripts/lib/gh-rate-budget.sh"
CR_PLAN="$REPO_ROOT/.claude/scripts/cr-plan.sh"

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT
export HOME="$TMP/home"
mkdir -p "$HOME/.claude"

PASS=0
FAIL=0
check_eq() {
  if [[ "$3" == "$2" ]]; then PASS=$((PASS + 1)); echo "ok   — $1"
  else FAIL=$((FAIL + 1)); echo "FAIL — $1 (expected '$2', got '$3')"; fi
}

# ---- stub gh ----------------------------------------------------------------
# gh api rate_limit ...  -> prints $RL_LINE (tab-separated remaining/limit/reset), or fails when RL_FAIL=1
# gh issue view ... --json state,createdAt ... -> OPEN line
# gh issue view ... --json comments -> first call rate-limited when CP_RATE_LIMIT_ONCE=1, then the plan
BIN="$TMP/bin"
mkdir -p "$BIN"
cat >"$BIN/gh" <<'STUB'
#!/usr/bin/env bash
args="$*"
case "$args" in
  "api rate_limit"*)
    echo "$args" >>"$STUB_LOG"
    [ "${RL_FAIL:-0}" = "1" ] && { echo "gh: HTTP 502" >&2; exit 1; }
    printf '%b\n' "$RL_LINE"
    ;;
  *state,createdAt*) printf 'OPEN\t2026-07-15T00:00:00Z\n' ;;
  *comments*)
    n=$(cat "$STUB_DIR/comment-calls" 2>/dev/null || echo 0)
    echo $((n + 1)) >"$STUB_DIR/comment-calls"
    if [ "${CP_RATE_LIMIT_ONCE:-0}" = "1" ] && [ "$n" -eq 0 ]; then
      echo "gh: API rate limit exceeded for user ID 1." >&2
      exit 1
    fi
    cat "$STUB_DIR/comments.json"
    ;;
  *) echo "stub gh: unexpected args: $args" >&2; exit 64 ;;
esac
STUB
chmod +x "$BIN/gh"
cat >"$BIN/fake-sleep" <<'STUB'
#!/usr/bin/env bash
echo "$1" >>"$SLEEP_LOG"
STUB
chmod +x "$BIN/fake-sleep"
export PATH="$BIN:$PATH"
export STUB_LOG="$TMP/gh-calls" SLEEP_LOG="$TMP/sleeps" STUB_DIR="$TMP"
export GH_RATE_SLEEP_CMD="$BIN/fake-sleep"
NOW=1000000
export GH_RATE_NOW=$NOW

reset_state() { rm -rf "$HOME/.claude/gh-rate-budget" "$STUB_LOG" "$SLEEP_LOG" "$TMP/comment-calls"; }
calls() { [ -f "$STUB_LOG" ] && wc -l <"$STUB_LOG" | tr -d ' ' || echo 0; }
interval() { bash "$LIB" interval "$1" 2>"$TMP/err"; }

# 1. above the threshold: nothing changes, nothing printed
reset_state; export RL_LINE="4000\t5000\t$((NOW + 1800))"
check_eq "above threshold keeps the interval" "60" "$(interval 60)"
check_eq "above threshold is silent" "" "$(cat "$TMP/err")"

# 2. below the threshold: doubled, announced once
reset_state; export RL_LINE="120\t5000\t$((NOW + 1800))"
check_eq "below threshold doubles the interval" "120" "$(interval 60)"
check_eq "below threshold says so" "1" "$(grep -c 'allowance is low' "$TMP/err")"
interval 60 >/dev/null
check_eq "second tick in the same window is silent" "" "$(cat "$TMP/err")"
mode=$(ls -l "$HOME/.claude/gh-rate-budget/announced" | cut -c1-10)
check_eq "marker is mode 600" "-rw-------" "$mode"

# 3. the widening is capped
reset_state
check_eq "widening is capped" "1800" "$(GH_RATE_MAX_INTERVAL=1800 interval 1500)"

# 4. a new reset window announces again
reset_state; export RL_LINE="120\t5000\t$((NOW + 1800))"; interval 60 >/dev/null
export RL_LINE="100\t5000\t$((NOW + 5400))"; GH_RATE_CACHE_SECS=0 interval 60 >/dev/null
check_eq "a new reset window announces again" "1" "$(grep -c 'allowance is low' "$TMP/err")"

# 5. a lost marker repeats one notice, never changes the interval
rm -rf "$HOME/.claude/gh-rate-budget"
check_eq "lost marker, same interval" "120" "$(interval 60)"

# 6. zero: wait for the reset GitHub reported (+2s)
reset_state; export RL_LINE="0\t5000\t$((NOW + 600))"
check_eq "zero waits for the reset" "602" "$(interval 60)"
check_eq "zero says so once" "1" "$(grep -c 'used up' "$TMP/err")"
interval 60 >/dev/null
check_eq "zero repeat is silent" "" "$(cat "$TMP/err")"

# 7. zero with a far reset is capped at an hour; a reset in the past changes nothing
reset_state; export RL_LINE="0\t5000\t$((NOW + 90000))"
check_eq "zero wait capped at an hour" "3600" "$(interval 60)"
reset_state; export RL_LINE="0\t5000\t$((NOW - 5))"
check_eq "zero with the reset already passed keeps the interval" "60" "$(interval 60)"

# 8. unreadable figure: normal interval, no message, in every shape
reset_state; export RL_FAIL=1
check_eq "failed read keeps the interval" "60" "$(interval 60)"
check_eq "failed read is silent" "" "$(cat "$TMP/err")"
unset RL_FAIL
reset_state; export RL_LINE="not-a-number"
check_eq "garbage figure keeps the interval" "60" "$(interval 60)"
check_eq "garbage figure is silent" "" "$(cat "$TMP/err")"
reset_state; export RL_LINE="12\t5000"
check_eq "missing reset keeps the interval" "60" "$(interval 60)"
reset_state; export RL_LINE="-5\t5000\t$((NOW + 60))"
check_eq "negative figure keeps the interval" "60" "$(interval 60)"

# 9. the threshold is configurable; junk falls back to the default
reset_state; export RL_LINE="400\t5000\t$((NOW + 1800))"
check_eq "threshold raised: 400 is now low" "120" "$(GH_RATE_LOW_AT=500 interval 60)"
reset_state
check_eq "junk threshold falls back to 300" "60" "$(GH_RATE_LOW_AT=lots interval 60)"

# 10. one read per cycle: the cache serves the next call within the window
reset_state; export RL_LINE="4000\t5000\t$((NOW + 1800))"
interval 60 >/dev/null; interval 60 >/dev/null
check_eq "two reads inside the cache window cost one rate_limit call" "1" "$(calls)"
GH_RATE_NOW=$((NOW + 31)) interval 60 >/dev/null
check_eq "an expired cache reads again" "2" "$(calls)"

# 10b. the resource is selectable and cached separately
reset_state; export RL_LINE="120\t5000\t$((NOW + 1800))"
GH_RATE_RESOURCE=graphql interval 60 >/dev/null
check_eq "graphql resource reads the graphql bucket" "1" "$(grep -c 'resources.graphql' "$STUB_LOG")"
check_eq "graphql notice names GraphQL" "1" "$(grep -c 'GraphQL allowance is low' "$TMP/err")"
interval 60 >/dev/null
check_eq "core is read separately from graphql (own cache)" "2" "$(calls)"
check_eq "junk resource falls back to core" "1" "$(GH_RATE_RESOURCE=bogus GH_RATE_CACHE_SECS=0 interval 60 >/dev/null; grep -c 'resources.core' "$STUB_LOG" | awk '{print ($1>=1)}')"

# 11. a bad base interval is refused
check_eq "non-numeric base is refused" "2" "$(bash "$LIB" interval abc >/dev/null 2>&1; echo $?)"
check_eq "status exits 1 when unreadable" "1" "$(RL_FAIL=1 GH_RATE_CACHE_SECS=0 bash "$LIB" status >/dev/null 2>&1; echo $?)"

# 12. gh_rate_sleep passes the computed wait to the injected sleep
reset_state; export RL_LINE="0\t5000\t$((NOW + 600))"
( . "$LIB"; gh_rate_sleep 60 ) 2>/dev/null
check_eq "gh_rate_sleep sleeps until the reset, through the injected command" "602" "$(cat "$SLEEP_LOG")"

# 13. no credential handling: the helper never reads a token or gh config
check_eq "helper handles no token" "0" "$(grep -Ec 'auth token|GH_TOKEN|GITHUB_TOKEN|GH_ENTERPRISE_TOKEN|hosts\.yml' "$LIB")"

# ---- cr-plan.sh poll wiring ---------------------------------------------------
python3 - "$TMP" <<'PY'
import json, pathlib, sys
tmp = pathlib.Path(sys.argv[1])
plan = ("<!-- This is an auto-generated reply by CodeRabbit -->\n## Coding Plan\n\n### Summary\n\n"
        + "1. A concrete implementation step with enough detail to act on.\n" * 10)
(tmp / "comments.json").write_text(json.dumps({"comments": [{"author": {"login": "coderabbitai"}, "body": plan}]}))
PY

# 14. rate-limited poll waits (injected sleep, stretched to the reset) then finds the plan
reset_state; export RL_LINE="0\t5000\t$((NOW + 600))"
out=$(CP_RATE_LIMIT_ONCE=1 bash "$CR_PLAN" 7 --poll 20 2>"$TMP/err"); rc=$?
check_eq "rate-limited poll then plan exits 0" "0" "$rc"
check_eq "rate-limited poll waited until the reset" "602" "$(cat "$SLEEP_LOG")"
check_eq "plan returned after the wait" "1" "$(printf '%s' "$out" | grep -c 'Coding Plan')"

# 14b. the wait never runs past the end of the poll window (--poll 5 = 300s; the reset is 600s away)
reset_state; export RL_LINE="0\t5000\t$((NOW + 600))"
CP_RATE_LIMIT_ONCE=1 bash "$CR_PLAN" 7 --poll 5 >/dev/null 2>&1
slept=$(cat "$SLEEP_LOG")
check_eq "wait is capped at the remaining poll window" "1" "$([ "$slept" -ge 1 ] && [ "$slept" -le 300 ] && echo 1 || echo 0)"
check_eq "gh_rate_sleep honours a max" "45" "$(reset_state; ( . "$LIB"; gh_rate_sleep 60 45 ) 2>/dev/null; cat "$SLEEP_LOG")"

# 15. without a rate limit, a non-rate-limit failure still exits 4 (no data is never "no plan")
reset_state; export RL_LINE="4000\t5000\t$((NOW + 600))"
bash -c '
  gh() { case "$*" in *state,createdAt*) printf "OPEN\t2026-07-15T00:00:00Z\n";; *comments*) echo "gh: HTTP 500" >&2; return 1;; *) return 64;; esac; }
  export -f gh
  bash "$0" 7 --poll 5' "$CR_PLAN" >/dev/null 2>&1
check_eq "ordinary failure still exits 4" "4" "$?"

# 16. unreadable allowance during a poll: normal 60s sleep
reset_state; export RL_FAIL=1
CP_RATE_LIMIT_ONCE=1 bash "$CR_PLAN" 7 --poll 5 >/dev/null 2>&1
check_eq "unreadable figure during poll sleeps the normal 60s" "60" "$(cat "$SLEEP_LOG")"
unset RL_FAIL

echo
echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
