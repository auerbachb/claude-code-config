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
    case "$args" in
      *resources.graphql*) if [ -n "${RL_LINE_GRAPHQL:-}" ]; then printf '%b\n' "$RL_LINE_GRAPHQL"; exit 0; fi ;;
    esac
    printf '%b\n' "$RL_LINE"
    ;;
  *state,createdAt*)
    if [ "${CP_META_RATE_LIMIT_ONCE:-0}" = "1" ] && [ ! -f "$STUB_DIR/meta-limited" ]; then
      : >"$STUB_DIR/meta-limited"
      echo "gh: API rate limit exceeded for user ID 1." >&2
      exit 1
    fi
    printf 'OPEN\t2026-07-15T00:00:00Z\n' ;;
  *comments*)
    n=$(cat "$STUB_DIR/comment-calls" 2>/dev/null || echo 0)
    echo $((n + 1)) >"$STUB_DIR/comment-calls"
    if [ "${CP_RATE_LIMIT_ONCE:-0}" = "1" ] && [ "$n" -eq 0 ]; then
      echo "gh: API rate limit exceeded for user ID 1." >&2
      exit 1
    fi
    if [ -n "${CP_PLAN_FROM:-}" ] && [ "$((n + 1))" -lt "$CP_PLAN_FROM" ]; then echo '{"comments":[]}'; exit 0; fi
    cat "$STUB_DIR/comments.json"
    ;;
  *) echo "stub gh: unexpected args: $args" >&2; exit 64 ;;
esac
STUB
chmod +x "$BIN/gh"
cat >"$BIN/fake-sleep" <<'STUB'
#!/usr/bin/env bash
echo "$1" >>"$SLEEP_LOG"
# With ADVANCE_CLOCK=1 the stub `date` sees the slept time as elapsed (no real waiting).
if [ "${ADVANCE_CLOCK:-0}" = "1" ]; then echo $(( $(cat "$STUB_DIR/clock-offset" 2>/dev/null || echo 0) + $1 )) >"$STUB_DIR/clock-offset"; fi
STUB
chmod +x "$BIN/fake-sleep"
cat >"$BIN/date" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "+%s" ] && [ -f "$STUB_DIR/clock-offset" ]; then echo $(( $(/bin/date +%s) + $(cat "$STUB_DIR/clock-offset") )); else exec /bin/date "$@"; fi
STUB
chmod +x "$BIN/date"
export PATH="$BIN:$PATH"
export STUB_LOG="$TMP/gh-calls" SLEEP_LOG="$TMP/sleeps" STUB_DIR="$TMP"
export GH_RATE_SLEEP_CMD="$BIN/fake-sleep"
NOW=1000000
export GH_RATE_NOW=$NOW

reset_state() { rm -rf "$HOME/.claude/gh-rate-budget" "$STUB_LOG" "$SLEEP_LOG" "$TMP/comment-calls" "$TMP/meta-limited" "$TMP/clock-offset"; }
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
reset_state
GH_RATE_RESOURCE=bogus GH_RATE_CACHE_SECS=0 interval 60 >/dev/null
check_eq "junk resource falls back to core (the one call made reads resources.core)" "1 0" "$(grep -c 'resources.core' "$STUB_LOG") $(grep -c 'resources.graphql' "$STUB_LOG")"

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

# ---- the Monitor-command form and the printed pollers (issue #2445, round 2) ----
unset RL_LINE_GRAPHQL
iv() { bash "$LIB" --interval "$1" 2>"$TMP/err"; }

# 17. --interval: base unchanged when healthy, unreadable, garbage or rate-limited; exit 0 always
reset_state; export RL_LINE="4000\t5000\t$((NOW + 1800))"
check_eq "--interval healthy keeps the base" "300" "$(iv 300)"
check_eq "--interval healthy is silent" "" "$(cat "$TMP/err")"
reset_state; export RL_FAIL=1
check_eq "--interval unreadable keeps the base" "300" "$(iv 300)"
check_eq "--interval unreadable prints nothing on stderr" "" "$(cat "$TMP/err")"
check_eq "--interval unreadable exits 0" "0" "$(bash "$LIB" --interval 300 >/dev/null 2>&1; echo $?)"
unset RL_FAIL
reset_state; export RL_LINE='{"message":"API rate limit exceeded for user ID 1."}'
check_eq "--interval treats a rate-limit error body as no data, not a verdict" "300" "$(iv 300)"
check_eq "--interval error body is silent" "" "$(cat "$TMP/err")"
check_eq "--interval bad base exits 0" "0" "$(bash "$LIB" --interval abc >/dev/null 2>&1; echo $?)"
check_eq "--interval bad base echoes it back, inventing no number" "abc" "$(bash "$LIB" --interval abc 2>/dev/null)"
check_eq "--interval without a base exits 0" "0" "$(bash "$LIB" --interval >/dev/null 2>&1; echo $?)"

# 18. --interval widens when REST is low, with the notice on stderr only
reset_state; export RL_LINE="120\t5000\t$((NOW + 1800))" RL_LINE_GRAPHQL="4000\t5000\t$((NOW + 1800))"
check_eq "--interval doubles when REST is low" "600" "$(iv 300)"
check_eq "--interval notice names REST" "1" "$(grep -c 'REST allowance is low' "$TMP/err")"
reset_state
check_eq "--interval notice stays off stdout" "600" "$(bash "$LIB" --interval 300 2>/dev/null)"
iv 300 >/dev/null
check_eq "--interval notice prints once per reset window" "" "$(cat "$TMP/err")"

# 19. either allowance low is enough: GraphQL low, REST healthy
reset_state; export RL_LINE="4000\t5000\t$((NOW + 1800))" RL_LINE_GRAPHQL="120\t5000\t$((NOW + 1800))"
check_eq "--interval doubles when only GraphQL is low" "600" "$(iv 300)"
check_eq "--interval notice names GraphQL" "1" "$(grep -c 'GraphQL allowance is low' "$TMP/err")"

# 20. zero on either: wait for the reset GitHub reported, capped
reset_state; export RL_LINE="4000\t5000\t$((NOW + 1800))" RL_LINE_GRAPHQL="0\t5000\t$((NOW + 900))"
check_eq "--interval waits for the GraphQL reset at zero" "902" "$(iv 300)"
reset_state; export RL_LINE="0\t5000\t$((NOW + 1200))" RL_LINE_GRAPHQL="0\t5000\t$((NOW + 900))"
check_eq "--interval takes the longer of two zero waits" "1202" "$(iv 300)"
check_eq "--interval at zero says so" "1" "$(grep -c 'used up' "$TMP/err" | awk '{print ($1>=1)}')"
iv 300 >/dev/null
check_eq "--interval zero repeat is silent" "" "$(cat "$TMP/err")"

# 21. the helper never sleeps inside its own --interval call
check_eq "--interval does not sleep" "" "$([ -f "$SLEEP_LOG" ] && cat "$SLEEP_LOG")"

# 22. only `gh api rate_limit` is ever asked of GitHub; state files are 600 and leave no temp files
reset_state; export RL_LINE="120\t5000\t$((NOW + 1800))" RL_LINE_GRAPHQL="120\t5000\t$((NOW + 1800))"
iv 300 >/dev/null
check_eq "helper only asks GitHub for rate_limit" "0" "$(grep -vc '^api rate_limit' "$STUB_LOG")"
check_eq "helper state files are all mode 600" "0" "$(ls -l "$HOME/.claude/gh-rate-budget" | tail -n +2 | grep -vc '^-rw-------')"
check_eq "helper leaves no temp files behind" "0" "$(ls -A "$HOME/.claude/gh-rate-budget" | grep -c '^\.')"
check_eq "helper keeps only cache and marker files" "announced cache-core cache-graphql" "$(ls "$HOME/.claude/gh-rate-budget" | tr '\n' ' ' | sed 's/ $//')"

# 23. merge paths never use the helper
merge_hits=0
for f in merge-gate.sh polling-state-gate.sh escalate-review.sh admin-merge.sh clean-behind-check.sh pr-state.sh ci-status.sh; do
  if grep -q 'gh-rate-budget' "$REPO_ROOT/.claude/scripts/$f"; then merge_hits=$((merge_hits + 1)); fi
done
for f in wrap merge admin-merge; do
  if [ -f "$REPO_ROOT/.claude/skills/$f/SKILL.md" ] && grep -q 'gh-rate-budget' "$REPO_ROOT/.claude/skills/$f/SKILL.md"; then merge_hits=$((merge_hits + 1)); fi
done
check_eq "no merge-path script or skill references the helper" "0" "$merge_hits"

# ---- babysit-pr Monitor loop (the SKILL.md fence the pinned tests also run) ----
LOOP="$(bash -c 'source "$1"; extract_skill_bash "$2" "$3"' -- "$REPO_ROOT/.claude/scripts/tests/lib/skill-bash.sh" "$REPO_ROOT/.claude/skills/babysit-pr/SKILL.md" babysit-pr-monitor-loop)"
baby_sleeps() {   # first sleep the loop asks for; fake sleep, no real waiting
  (cd "$REPO_ROOT" && PR=123 MONITOR_GENERATION=g MONITOR_CADENCE=5 MONITOR_REVIEW_DEADLINE="${1:-0}" \
    bash -uc 'sleep() { printf "sleep=%s\n" "$1"; return 1; }; '"$LOOP" 2>"$TMP/err" | sed -n 's/^sleep=//p' | head -1)
}
reset_state; export RL_LINE="4000\t5000\t$((NOW + 1800))" RL_LINE_GRAPHQL="4000\t5000\t$((NOW + 1800))"
check_eq "babysit loop keeps 300s with a healthy allowance" "300" "$(baby_sleeps)"
reset_state; export RL_FAIL=1
check_eq "babysit loop keeps 300s when the allowance is unreadable" "300" "$(baby_sleeps)"
unset RL_FAIL
reset_state; export RL_LINE="120\t5000\t$((NOW + 1800))" RL_LINE_GRAPHQL="4000\t5000\t$((NOW + 1800))"
check_eq "babysit loop widens to 600s when REST is low" "600" "$(baby_sleeps)"
reset_state; export RL_LINE="4000\t5000\t$((NOW + 1800))" RL_LINE_GRAPHQL="120\t5000\t$((NOW + 1800))"
check_eq "babysit loop widens to 600s when only GraphQL is low" "600" "$(baby_sleeps)"
reset_state; export RL_LINE="0\t5000\t$((NOW + 900))" RL_LINE_GRAPHQL="4000\t5000\t$((NOW + 1800))"
check_eq "babysit loop waits for the reset at zero" "902" "$(baby_sleeps)"
check_eq "babysit loop notice goes to stderr" "1" "$(grep -c 'used up' "$TMP/err")"
# a nearer review deadline still shortens a widened wait (the deadline compares against the real clock)
reset_state; export RL_LINE="120\t5000\t$((NOW + 1800))" RL_LINE_GRAPHQL="4000\t5000\t$((NOW + 1800))"
unset GH_RATE_NOW
got=$(baby_sleeps "$(( $(date +%s) + 100 ))")
export GH_RATE_NOW=$NOW
check_eq "babysit loop still honours a nearer review deadline" "1" "$([ "$got" -le 100 ] && echo 1 || echo 0)"
# no helper on disk: the plain cadence
mkdir -p "$TMP/nolib"
nolib=$(cd "$TMP/nolib" && PR=1 MONITOR_GENERATION=g MONITOR_CADENCE=5 MONITOR_REVIEW_DEADLINE=0 HOME="$TMP/nohome" \
  bash -uc 'sleep() { printf "sleep=%s\n" "$1"; return 1; }; '"$LOOP" 2>/dev/null | sed -n 's/^sleep=//p' | head -1)
check_eq "babysit loop with no helper on disk keeps 300s" "300" "$nolib"

# ---- the printed /pr-monitor-and-manage Monitor command ------------------------
check_eq "pmm printed command resolves the helper beside the script" "1" "$(grep -c 'lib/gh-rate-budget.sh' "$REPO_ROOT/.claude/scripts/pmm-pre-dispatch.sh" | awk '{print ($1>=1)}')"

# ---- round 2 review fixes ---------------------------------------------------------
# 24. used-up allowance waits for the reset even when the threshold is 0
reset_state; export RL_LINE="0\t5000\t$((NOW + 600))"; unset RL_LINE_GRAPHQL
check_eq "zero remaining waits for the reset with GH_RATE_LOW_AT=0" "602" "$(GH_RATE_LOW_AT=0 interval 60)"
reset_state; export RL_LINE="1\t5000\t$((NOW + 600))"
check_eq "one remaining is not low with GH_RATE_LOW_AT=0" "60" "$(GH_RATE_LOW_AT=0 interval 60)"

# 25. a rate-limited FIRST read (issue metadata) in --poll mode waits and retries; without --poll it exits 4
reset_state; export RL_LINE="0\t5000\t$((NOW + 600))"
out=$(CP_META_RATE_LIMIT_ONCE=1 bash "$CR_PLAN" 7 --poll 5 2>"$TMP/err"); rc=$?
check_eq "rate-limited metadata read in --poll mode retries and finds the plan" "0" "$rc"
check_eq "the metadata retry waited, capped at the poll window" "1" "$(s=$(head -n 1 "$SLEEP_LOG"); [ "$s" -ge 1 ] && [ "$s" -le 300 ] && echo 1 || echo 0)"
reset_state; export RL_LINE="4000\t5000\t$((NOW + 600))"
CP_META_RATE_LIMIT_ONCE=1 bash "$CR_PLAN" 7 >/dev/null 2>&1
check_eq "rate-limited metadata read without --poll still exits 4" "4" "$?"

# 26. deadline after every sleep: a plan on the final in-window attempt counts; no attempt starts past it
reset_state; export RL_LINE="4000\t5000\t$((NOW + 600))"
out=$(ADVANCE_CLOCK=1 CP_PLAN_FROM=2 bash "$CR_PLAN" 7 --poll 1 2>/dev/null); rc=$?
check_eq "a plan found on the final in-window attempt counts" "0" "$rc"
reset_state
ADVANCE_CLOCK=1 CP_PLAN_FROM=3 bash "$CR_PLAN" 7 --poll 1 >/dev/null 2>&1; rc=$?
check_eq "a plan that only exists after the window is not waited for (exit 1)" "1" "$rc"
check_eq "no comment read starts after the window ended" "2" "$(cat "$TMP/comment-calls")"

echo
echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
