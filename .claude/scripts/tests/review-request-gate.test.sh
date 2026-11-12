#!/usr/bin/env bash
# Offline tests for review-request-gate.sh, the decision for when the agent's AI review request may post (issue #2195).
# catalog: tests — Tests `review-request-gate.sh` — after-ci waits for CI, requests once per HEAD, never on failed checks, named checks that never report are ignored after the grace, on-push and never, reviewer checks never count
#
# Pure decisions: the gate reads check runs on stdin and takes the clock and the
# HEAD commit time as flags, so every state is a fixture.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
GATE="$REPO_ROOT/.claude/scripts/review-request-gate.sh"
TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

PASS=0
FAIL=0
check_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    PASS=$((PASS + 1)); echo "ok   — $desc"
  else
    FAIL=$((FAIL + 1)); echo "FAIL — $desc (expected '$expected', got '$actual')"
  fi
}

NOW=1000000
HEAD_OLD=$((NOW - 7200))   # past the 900 s grace
HEAD_NEW=$((NOW - 120))    # inside the grace
SHA=cccccccccccccccccccccccccccccccccccccccc
OTHER=dddddddddddddddddddddddddddddddddddddddd

# run <setting> <checks csv> <requested-head> <head-epoch> <check-runs json> -> decision line
run() {
  printf '%s' "$5" | bash "$GATE" --setting "$1" --head "$SHA" --checks "$2" \
    --requested-head "$3" --head-epoch "$4" --now-epoch "$NOW" 2>"$TMP/err"
}
decision() { jq -r '"\(.decision)/\(.reason)"' <<<"$1"; }
ignored() { jq -r '.ignored_checks | join(",")' <<<"$1"; }
run_rc() { # same args, prints the exit status only
  printf '%s' "$5" | bash "$GATE" --setting "$1" --head "$SHA" --checks "$2" \
    --requested-head "$3" --head-epoch "$4" --now-epoch "$NOW" >/dev/null 2>&1
  echo "$?"
}

GREEN='{"check_runs":[{"name":"rule-lint","status":"completed","conclusion":"success","started_at":"2026-11-11T10:00:00Z","app":{"slug":"github-actions"}},{"name":"hook-tests-py39","status":"completed","conclusion":"success","started_at":"2026-11-11T10:00:00Z","app":{"slug":"github-actions"}}]}'
PENDING='{"check_runs":[{"name":"rule-lint","status":"completed","conclusion":"success","started_at":"2026-11-11T10:00:00Z","app":{"slug":"github-actions"}},{"name":"hook-tests-py39","status":"in_progress","conclusion":null,"started_at":"2026-11-11T10:00:00Z","app":{"slug":"github-actions"}}]}'
RED='{"check_runs":[{"name":"rule-lint","status":"completed","conclusion":"failure","started_at":"2026-11-11T10:00:00Z","app":{"slug":"github-actions"}},{"name":"hook-tests-py39","status":"completed","conclusion":"success","started_at":"2026-11-11T10:00:00Z","app":{"slug":"github-actions"}}]}'
REVIEWER_RED='{"check_runs":[{"name":"CodeRabbit","status":"completed","conclusion":"failure","started_at":"2026-11-11T10:00:00Z","app":{"slug":"coderabbitai"}},{"name":"build","status":"completed","conclusion":"success","started_at":"2026-11-11T10:00:00Z","app":{"slug":"github-actions"}}]}'
SLOW_UNNAMED_RED='{"check_runs":[{"name":"rule-lint","status":"completed","conclusion":"success","started_at":"2026-11-11T10:00:00Z","app":{"slug":"github-actions"}},{"name":"full-suite","status":"in_progress","conclusion":null,"started_at":"2026-11-11T10:00:00Z","app":{"slug":"github-actions"}}]}'
EMPTY='{"check_runs":[]}'

echo "== setting: on-push and never ignore CI =="
out="$(run on-push "" "" "$HEAD_NEW" "$RED")"
check_eq "on-push requests at once, whatever CI says" "request/on_push" "$(decision "$out")"
out="$(run never "" "" "$HEAD_OLD" "$GREEN")"
check_eq "never never requests" "none/setting_never" "$(decision "$out")"

echo "== after-ci, unnamed: every non-reviewer check must be green =="
out="$(run after-ci "" "" "$HEAD_OLD" "$PENDING")"
check_eq "CI pending → wait (no request)" "wait/ci_pending" "$(decision "$out")"
out="$(run after-ci "" "" "$HEAD_OLD" "$GREEN")"
check_eq "CI green → one request" "request/ci_green" "$(decision "$out")"
out="$(run after-ci "" "" "$HEAD_OLD" "$RED")"
check_eq "a failed check on the HEAD → no request" "none/ci_failed" "$(decision "$out")"
out="$(run after-ci "" "" "$HEAD_OLD" "$REVIEWER_RED")"
check_eq "a failed REVIEWER check never counts as CI" "request/ci_green" "$(decision "$out")"
out="$(run after-ci "" "" "$HEAD_NEW" "$EMPTY")"
check_eq "no checks yet, inside the grace → wait" "wait/no_checks_yet" "$(decision "$out")"
out="$(run after-ci "" "" "$HEAD_OLD" "$EMPTY")"
check_eq "no checks at all past the grace (no CI) → request" "request/no_checks" "$(decision "$out")"
out="$(run after-ci "" "" "" "$EMPTY")"
check_eq "unknown HEAD age and no checks → wait, never a blind request" "wait/no_checks_yet" "$(decision "$out")"

echo "== requests are once per HEAD =="
out="$(run after-ci "" "$SHA" "$HEAD_OLD" "$GREEN")"
check_eq "second poll on a requested HEAD → no second request" "none/already_requested" "$(decision "$out")"
out="$(run after-ci "" "$OTHER" "$HEAD_OLD" "$GREEN")"
check_eq "a new push (new HEAD) is eligible again" "request/ci_green" "$(decision "$out")"

echo "== named checks: the fast list decides, the slow suite is not awaited =="
out="$(run after-ci "rule-lint,hook-tests-py39" "" "$HEAD_OLD" "$SLOW_UNNAMED_RED")"
check_eq "named fast checks green while the slow suite runs → request" "request/named_checks_green" "$(decision "$out")"
FAST_GREEN='{"check_runs":[{"name":"rule-lint","status":"completed","conclusion":"success","started_at":"2026-11-11T10:00:00Z","app":{"slug":"github-actions"}},{"name":"hook-tests-py39","status":"completed","conclusion":"success","started_at":"2026-11-11T10:00:00Z","app":{"slug":"github-actions"}},{"name":"full-suite","status":"in_progress","conclusion":null,"started_at":"2026-11-11T10:00:00Z","app":{"slug":"github-actions"}}]}'
out="$(run after-ci "rule-lint,hook-tests-py39" "" "$HEAD_OLD" "$FAST_GREEN")"
check_eq "both named fast checks green, slow suite running → request" "request/named_checks_green" "$(decision "$out")"
check_eq "  … with no named check ignored" "" "$(ignored "$out")"
out="$(run after-ci "rule-lint,hook-tests-py39" "" "$HEAD_OLD" "$PENDING")"
check_eq "a named check still running → wait" "wait/named_checks_pending" "$(decision "$out")"
out="$(run after-ci "rule-lint,hook-tests-py39" "" "$HEAD_OLD" "$RED")"
check_eq "a named check failed → no request" "none/ci_failed" "$(decision "$out")"
out="$(run after-ci "rule-lint,hook-tests-py39" "" "$HEAD_NEW" '{"check_runs":[{"name":"rule-lint","status":"completed","conclusion":"success","app":{"slug":"github-actions"}}]}')"
check_eq "a named check that has not reported, inside the grace → wait" "wait/named_checks_pending" "$(decision "$out")"
out="$(run after-ci "rule-lint,hook-tests-py39" "" "$HEAD_OLD" '{"check_runs":[{"name":"rule-lint","status":"completed","conclusion":"success","app":{"slug":"github-actions"}}]}')"
check_eq "a named check that never reports is ignored past the grace → request" "request/named_checks_green" "$(decision "$out")"
check_eq "  … and it is listed as ignored" "hook-tests-py39" "$(ignored "$out")"
out="$(run after-ci "never-reports" "" "$HEAD_OLD" "$SLOW_UNNAMED_RED")"
check_eq "every named check ignored past the grace → request, never held forever" "request/named_checks_not_reporting" "$(decision "$out")"
out="$(run after-ci "never-reports" "" "$HEAD_NEW" "$SLOW_UNNAMED_RED")"
check_eq "the same names inside the grace still wait" "wait/named_checks_pending" "$(decision "$out")"
out="$(run after-ci " rule-lint , " "" "$HEAD_OLD" "$GREEN")"
check_eq "names are trimmed and empty entries dropped" "request/named_checks_green" "$(decision "$out")"

echo "== superseded runs, through the merge gate's dedup rule (check-runs-dedup.sh) =="
dedup_gate() { # <setting> <checks> <head-epoch> <raw check runs> -> decision line
  printf '%s' "$4" | bash "$REPO_ROOT/.claude/scripts/check-runs-dedup.sh" \
    | bash "$GATE" --setting "$1" --head "$SHA" --checks "$2" --requested-head "" \
      --head-epoch "$3" --now-epoch "$NOW" 2>"$TMP/err"
}
SUPERSEDED='{"check_runs":[{"id":1,"name":"rule-lint","status":"completed","conclusion":"failure","started_at":"2026-11-11T09:00:00Z","check_suite":{"id":10},"app":{"slug":"github-actions"}},{"id":2,"name":"rule-lint","status":"completed","conclusion":"success","started_at":"2026-11-11T10:00:00Z","check_suite":{"id":11},"app":{"slug":"github-actions"}}]}'
out="$(dedup_gate after-ci "" "$HEAD_OLD" "$SUPERSEDED")"
check_eq "an older failed run superseded by a newer successful suite → request" "request/ci_green" "$(decision "$out")"
NEWEST_FAILS='{"check_runs":[{"id":1,"name":"rule-lint","status":"completed","conclusion":"success","started_at":"2026-11-11T09:00:00Z","check_suite":{"id":10},"app":{"slug":"github-actions"}},{"id":2,"name":"rule-lint","status":"completed","conclusion":"failure","started_at":"2026-11-11T10:00:00Z","check_suite":{"id":11},"app":{"slug":"github-actions"}}]}'
out="$(dedup_gate after-ci "" "$HEAD_OLD" "$NEWEST_FAILS")"
check_eq "a failing run in the newest suite → held (none)" "none/ci_failed" "$(decision "$out")"
CURSOR_CI='{"check_runs":[{"id":3,"name":"cursor-pagination","status":"completed","conclusion":"failure","app":{"slug":"github-actions"}},{"id":4,"name":"build","status":"completed","conclusion":"success","app":{"slug":"github-actions"}}]}'
out="$(dedup_gate after-ci "" "$HEAD_OLD" "$CURSOR_CI")"
check_eq "a check whose name merely contains 'cursor' is CI, not a reviewer (fails the gate)" "none/ci_failed" "$(decision "$out")"
NAMED_REVIEWER='{"check_runs":[{"id":5,"name":"CodeRabbit","status":"completed","conclusion":"failure"},{"id":6,"name":"build","status":"completed","conclusion":"success","app":{"slug":"github-actions"}}]}'
out="$(dedup_gate after-ci "" "$HEAD_OLD" "$NAMED_REVIEWER")"
check_eq "an exact-named reviewer check with no publisher is excluded → request" "request/ci_green" "$(decision "$out")"

echo "== bad input fails closed =="
check_eq "non-JSON check-run input → exit 4" "4" "$(echo bogus | bash "$GATE" --setting after-ci --head "$SHA" --now-epoch "$NOW" >/dev/null 2>&1; echo $?)"
check_eq "unknown setting → usage exit 2" "2" "$(echo "$EMPTY" | bash "$GATE" --setting sometimes --head "$SHA" >/dev/null 2>&1; echo $?)"
check_eq "missing --head → usage exit 2" "2" "$(echo "$EMPTY" | bash "$GATE" --setting after-ci >/dev/null 2>&1; echo $?)"
check_eq "a flag with no value → usage exit 2" "2" "$(echo "$EMPTY" | bash "$GATE" --setting >/dev/null 2>&1; echo $?)"
QUEUED='{"check_runs":[{"id":2,"name":"rule-lint","status":"queued","conclusion":null,"check_suite":{"id":21},"app":{"slug":"github-actions"}},{"id":1,"name":"rule-lint","status":"completed","conclusion":"success","started_at":"2026-11-11T10:00:00Z","check_suite":{"id":20},"app":{"slug":"github-actions"}}]}'
out="$(run after-ci "rule-lint" "" "$HEAD_OLD" "$QUEUED")"
check_eq "a newer queued re-run (higher id, no start time) is the one that counts → wait" "wait/named_checks_pending" "$(decision "$out")"
RERUN_GREEN='{"check_runs":[{"id":1,"name":"rule-lint","status":"queued","conclusion":null,"app":{"slug":"github-actions"}},{"id":2,"name":"rule-lint","status":"completed","conclusion":"success","started_at":"2026-11-11T10:00:00Z","app":{"slug":"github-actions"}}]}'
out="$(run after-ci "rule-lint" "" "$HEAD_OLD" "$RERUN_GREEN")"
check_eq "an older queued run followed by a newer successful re-run → request" "request/named_checks_green" "$(decision "$out")"
CANCELLED='{"check_runs":[{"name":"rule-lint","status":"completed","conclusion":"cancelled","started_at":"2026-11-11T10:00:00Z","app":{"slug":"github-actions"}}]}'
out="$(run after-ci "" "" "$HEAD_OLD" "$CANCELLED")"
check_eq "a cancelled check is not green → no request" "none/ci_failed" "$(decision "$out")"

echo
echo "review-request-gate.test.sh: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
