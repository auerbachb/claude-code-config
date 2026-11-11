#!/usr/bin/env bash
# catalog: tests — Exercises the exact cancelled-required-job retry, GitHub identity checks and repo-scoped CAS.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
# shellcheck source=lib/skill-bash.sh
source "$TEST_DIR/lib/skill-bash.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/sut/lib" "$TMP/bin"
cp "$TEST_DIR/../rerun-cancelled-required-ci.sh" "$TMP/sut/"
cp "$TEST_DIR/../lib/repo-normalizer.sh" "$TMP/sut/lib/"
export REAL_STATE="$TEST_DIR/../session-state.sh"
export PATH="$TMP/bin:$PATH"
export FIXTURE_HEAD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
export OTHER_HEAD=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
export FIXTURE_JOB=101
export POST_LOG="$TMP/post"
export RELEASE_POST="$TMP/release-post"
export FIXTURE_MODE=normal

cat > "$TMP/sut/session-state.sh" <<'SH'
#!/usr/bin/env bash
exec "$REAL_STATE" "$@"
SH
cat > "$TMP/sut/merge-gate.sh" <<'SH'
#!/usr/bin/env bash
[[ "$1" == 11 ]] || exit 4
candidate=null
[[ "$FIXTURE_MODE" == optional ]] ||
  candidate=$(jq -cn --argjson id "$FIXTURE_JOB" '{id:$id,name:"build"}')
jq -cn --arg head "$FIXTURE_HEAD" --argjson candidate "$candidate" '
  {owner_repo:"Fixture/Repo",head_sha:$head,required_contexts:{cancelled_retry:$candidate}}'
exit 1
SH
cat > "$TMP/bin/gh" <<'SH'
#!/usr/bin/env bash
set -eu
case "$1/$2" in
  repo/view) printf 'Fixture/Repo\n' ;;
  pr/view)
    [[ "$3" == 11 && "$5" == fixture/repo ]] || exit 90
    head="$FIXTURE_HEAD"
    [[ "$FIXTURE_MODE" != moved ]] || head="$OTHER_HEAD"
    draft=false
    [[ "$FIXTURE_MODE" != draft ]] || draft=true
    jq -cn --arg sha "$head" --argjson draft "$draft" '{state:"OPEN",headRefOid:$sha,isDraft:$draft}'
    ;;
  api/--method)
    [[ "$3" == POST && "$4" == "repos/fixture/repo/actions/jobs/$FIXTURE_JOB/rerun" ]] || exit 91
    printf '%s\n' "$4" >> "$POST_LOG"
    if [[ "$FIXTURE_MODE" == held_post ]]; then
      for _ in {1..200}; do
        [[ ! -e "$RELEASE_POST" ]] || exit 0
        sleep .05
      done
      exit 94
    fi
    [[ "$FIXTURE_MODE" != rejected ]]
    ;;
  api/repos/fixture/repo/actions/jobs/*)
    [[ "$2" == "repos/fixture/repo/actions/jobs/$FIXTURE_JOB" ]] || exit 92
    url="https://api.github.com/repos/fixture/repo/check-runs/$FIXTURE_JOB"
    [[ "$FIXTURE_MODE" != wrong_repo ]] || url="https://api.github.com/repos/other/repo/check-runs/$FIXTURE_JOB"
    head="$FIXTURE_HEAD"
    [[ "$FIXTURE_MODE" != wrong_job_head ]] || head="$OTHER_HEAD"
    jq -cn --argjson id "$FIXTURE_JOB" --arg sha "$head" --arg url "$url" '
      {id:$id,name:"build",head_sha:$sha,status:"completed",conclusion:"cancelled",check_run_url:$url}'
    ;;
  *) exit 93 ;;
esac
SH
chmod +x "$TMP/sut/"*.sh "$TMP/bin/gh"

PASS=0
check_eq() {
  if [[ "$1" != "$2" ]]; then
    printf 'FAIL: %s (expected %s, got %s)\n' "$3" "$1" "$2" >&2
    exit 1
  fi
  PASS=$(( PASS + 1 ))
  printf 'PASS: %s\n' "$3"
}
reset() {
  export HOME="$TMP/home-$1"
  mkdir -p "$HOME/.claude"
  : > "$POST_LOG"
}
run_retry() {
  RC=0
  OUT=$("$TMP/sut/rerun-cancelled-required-ci.sh" 11) || RC=$?
}
value() { jq -r "$1" <<<"$OUT"; }
posts() { wc -l < "$POST_LOG" | tr -d ' '; }

reset exact
run_retry
check_eq 0 "$RC" "valid job is requested"
check_eq requested "$(value .status)" "helper reports the request"
check_eq true "$(value .wait_for_ci)" "request waits for real CI"
check_eq 1 "$(posts)" "one exact native request"
entry=$(jq -r --arg sha "$FIXTURE_HEAD" '.repos["fixture/repo"].prs["11"].required_ci_reruns[$sha].status' "$HOME/.claude/session-state.json")
check_eq requested "$entry" "receipt is scoped to repo, PR and HEAD"
run_retry
check_eq already_recorded "$(value .status)" "same job cannot be re-requested"
check_eq 1 "$(posts)" "same HEAD does not cause another request"
FIXTURE_JOB=102 run_retry
check_eq retry_exhausted "$(value .reason)" "newly cancelled job on same HEAD is exhausted"
check_eq false "$(value .wait_for_ci)" "second cancellation is a visible blocker"
check_eq 1 "$(posts)" "a second job on the same HEAD still cannot rerun"
FIXTURE_HEAD="$OTHER_HEAD" FIXTURE_JOB=102 run_retry
check_eq requested "$(value .status)" "new HEAD can claim its own job"
check_eq 2 "$(posts)" "new HEAD contributes one additional request"

for mode in optional wrong_repo wrong_job_head moved draft rejected; do
  reset "$mode"
  FIXTURE_MODE="$mode" run_retry
  case "$mode" in
    optional) check_eq not_eligible "$(value .status)" "optional cancellation is ignored" ;;
    wrong_repo|wrong_job_head) check_eq validation_failed "$(value .status)" "$mode is rejected" ;;
    moved|draft) check_eq superseded "$(value .status)" "$mode after claim sends no request" ;;
    rejected) check_eq request_failed "$(value .status)" "GitHub rejection is recorded" ;;
  esac
  if [[ "$mode" == rejected ]]; then
    check_eq 1 "$RC" "rejected request exits nonzero"
    run_retry
    check_eq request_failed "$(value .reason)" "the failed attempt remains reserved"
    check_eq 1 "$(posts)" "a rejected request never retries automatically"
  else
    check_eq 0 "$(posts)" "$mode sends no mutation"
  fi
done

reset race
"$TMP/sut/rerun-cancelled-required-ci.sh" 11 > "$TMP/race-1" &
first=$!
"$TMP/sut/rerun-cancelled-required-ci.sh" 11 > "$TMP/race-2" &
second=$!
wait "$first"
wait "$second"
check_eq 1 "$(posts)" "two simultaneous owners still send one exact request"
check_eq '["already_recorded","requested"]' "$(jq -sc 'map(.status)|sort' "$TMP/race-1" "$TMP/race-2")" "concurrent loser reports the durable winning claim"

reset held
FIXTURE_MODE=held_post "$TMP/sut/rerun-cancelled-required-ci.sh" 11 > "$TMP/held-result" &
winner=$!
for _ in {1..100}; do
  [[ ! -s "$POST_LOG" ]] || break
  sleep .05
done
check_eq 1 "$(posts)" "winner reached the exact job request"
run_retry
touch "$RELEASE_POST"
wait "$winner"
check_eq request_pending "$(value .reason)" "concurrent caller observes the in-flight request"
check_eq true "$(value .wait_for_ci)" "watcher keeps waiting during a fresh claim"
check_eq requested "$(jq -r .status "$TMP/held-result")" "winner records the confirmed request"
check_eq 1 "$(posts)" "a pending claim never authorizes a second request"

reset abandoned
"$REAL_STATE" --repo fixture/repo --set \
  ".prs[\"11\"].required_ci_reruns[\"$FIXTURE_HEAD\"]={\"status\":\"claimed\",\"job_id\":101,\"claimed_at\":\"2000-01-01T00:00:00Z\"}"
run_retry
check_eq claim_uncertain "$(value .reason)" "an abandoned claim names the uncertain outcome"
check_eq false "$(value .wait_for_ci)" "watchers surface an abandoned request after the wait"
check_eq 0 "$(posts)" "an old claim cannot be acquired again"

# Exercise the actual entry-point blocks with one stubbed helper.
FIXPR_BLOCK=$(extract_skill_bash "$REPO_ROOT/.claude/skills/fixpr/SKILL.md" fixpr-required-ci-rerun)
BABYSIT_BLOCK=$(extract_skill_bash "$REPO_ROOT/.claude/skills/babysit-pr/SKILL.md" babysit-required-ci-rerun)
PMM_BLOCK=$(extract_skill_bash "$REPO_ROOT/.claude/skills/pr-monitor-and-manage/SKILL.md" pmm-required-ci-rerun)
export STUB_RETRY="$TMP/stub-retry"
export STUB_LOG="$TMP/stub-log"
export STUB_OUT='{"status":"requested","wait_for_ci":true,"job_id":101}'
cat > "$STUB_RETRY" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$STUB_LOG"
printf '%s\n' "$STUB_OUT"
SH
chmod +x "$STUB_RETRY"
resolve_script() { [[ "$1" == rerun-cancelled-required-ci.sh ]] && printf '%s\n' "$STUB_RETRY"; }
export -f resolve_script
export AUDIT="$TMP/audit.json"
printf '%s\n' '{"check_runs":{"all":[{"app":{"slug":"github-actions"},"status":"completed","conclusion":"cancelled"}]}}' > "$AUDIT"
OUT=$(PR_NUMBER=11 "$BASH" -uc "$FIXPR_BLOCK"$'\nprintf "%s\\n" "$REQUIRED_CI_RESULT"')
check_eq requested "$(value .status)" "fixpr reaches the exact helper from its cancelled check audit"
OUT=$(CLASS=required-ci-rerun PR=11 "$BASH" -uc "$BABYSIT_BLOCK"$'\nprintf "%s\\n" "$CLASS"')
check_eq waiting-on-bots "$OUT" "babysit resumes gate waiting after a requested rerun"
OUT=$(CLASS=required-ci-rerun PR=11 STUB_OUT='{"status":"already_recorded","reason":"request_pending","wait_for_ci":true}' \
  "$BASH" -uc "$BABYSIT_BLOCK"$'\nprintf "%s\\n" "$CLASS"')
check_eq waiting-on-bots "$OUT" "babysit waits for another caller's pending rerun"
OUT=$(CLASS=required-ci-rerun PR=11 WATCH_LAUNCH_OK=false "$BASH" -uc "$BABYSIT_BLOCK"$'\nprintf "%s\\n" "$CLASS"')
check_eq required-ci-rerun "$OUT" "babysit horizon hold leaves the pending action untouched"
OUT=$(VERDICT=required-ci-rerun N=11 "$BASH" -uc "$PMM_BLOCK"$'\nprintf "%s\\n" "$TICK_HAD_ACTION"')
check_eq true "$OUT" "fleet path records the rerun as action"
OUT=$(VERDICT=required-ci-rerun N=11 TICK_HAD_ACTION=false TICK_HAS_PENDING_CI_RETRY=false \
  STUB_OUT='{"status":"already_recorded","reason":"request_pending","wait_for_ci":true}' \
  "$BASH" -uc "$PMM_BLOCK"$'\nprintf "%s|%s\n" "$TICK_HAD_ACTION" "$TICK_HAS_PENDING_CI_RETRY"')
check_eq 'false|true' "$OUT" "fleet path recognizes a pending retry without reporting a new action"
check_eq $'11\n11\n11\n11\n11' "$(cat "$STUB_LOG")" "each authorized entry uses the same exact PR helper"

printf 'OK: %s required CI retry checks passed\n' "$PASS"
