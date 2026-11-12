#!/usr/bin/env bash
# no-review-override-availability.test.sh — offline fixture tests for the account-wide
# reviewer availability in no-review-override.sh (issue #2256): a recorded request skip
# applies the override at once while its answer holds; a notice in the PR's comments
# writes the record; stale, unreadable and other-HEAD cases never apply it. Drives the
# helper directly with a fake gh; HOME is a throwaway directory. Run under /bin/bash (3.2)
# and a 5.x bash.
# catalog: tests — Tests the request-skip override in `no-review-override.sh` — immediate apply while the recorded reviewer unavailability holds, notice recording, fail-toward-asking cases
# Run from repo root: bash .claude/scripts/tests/no-review-override-availability.test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$SCRIPT_DIR/../no-review-override.sh"
[[ -f "$HELPER" ]] || { echo "FAIL: helper not found at $HELPER" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
mkdir -p "$HOME/.claude"
STATE_FILE="$HOME/.claude/session-state.json"
BIN="$TMP/bin"
mkdir -p "$BIN"
cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"/pulls/1"*) printf '%s' "$FAKE_PULL_JSON"; exit 0 ;;
  *"/timeline"*) printf '%s' "[]"; exit 0 ;;
  *"actions/runs"*) printf '%s' "$FAKE_RUNS_JSON"; exit 0 ;;
  *"/issues/1/comments?per_page=100"*) printf '%s' "$FAKE_FRESH_COMMENTS"; exit 0 ;;
esac
echo "fake gh: unexpected call: $*" >&2
exit 1
EOF
chmod +x "$BIN/gh"
export PATH="$BIN:$PATH"

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $1 — $2"; }
expect_eq() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "got [$2] want [$3]"; fi; }

NOW=$(date -u +%s)
WIN=600
PUSH=$((NOW - 120))            # HEAD pushed 2 min ago: the 10-minute window has NOT elapsed
CHECK=$((PUSH + 5))
HEADSHA=1111111111111111111111111111111111111111
OTHERSHA=2222222222222222222222222222222222222222
iso() { jq -rn --argjson s "$1" '$s | todateiso8601'; }

FAKE_PULL_JSON=$(jq -cn --arg c "$(iso $((NOW - 7200)))" \
  '{number:1, created_at:$c, draft:false, user:{login:"solo"}, head:{ref:"feature", repo:{full_name:"solo/repo"}}}')
export FAKE_PULL_JSON
FAKE_RUNS_JSON=$(jq -cn --arg t "$(iso $PUSH)" --arg h "$HEADSHA" \
  '{total_count:1, workflow_runs:[{event:"pull_request", created_at:$t, head_branch:"feature", head_sha:$h, head_repository:{full_name:"solo/repo"}}]}')
export FAKE_RUNS_JSON

# av_state <coderabbit next epoch|-> <codeant next epoch|->  [skip head sha|-]
# Writes the session-state fixture: the account-wide records and, optionally, a request
# skip recorded on PR 1 for that HEAD (repo-scoped, as maybe-trigger-ai-review.sh writes it).
av_state() {
  local rec_cr="null" rec_cd="null" skip="null"
  if [[ "$1" != "-" ]]; then
    rec_cr=$(jq -cn --argjson n "$1" --argjson t "$NOW" '{next_available_epoch: $n, next_available: ($n|todateiso8601), notice_epoch: $t, notice_at: ($t|todateiso8601), window_seconds: 1200, notice_excerpt: "next review available in", source_repo: "solo/repo", source_pr: 1, read_at: ($t|todateiso8601)}')
  fi
  if [[ "$2" != "-" ]]; then
    rec_cd=$(jq -cn --argjson n "$2" --argjson t "$NOW" '{next_available_epoch: $n, next_available: ($n|todateiso8601), notice_epoch: $t, notice_at: ($t|todateiso8601), window_seconds: 1200, notice_excerpt: "usage limit", source_repo: "solo/repo", source_pr: 1, read_at: ($t|todateiso8601)}')
  fi
  if [[ -n "${3:-}" && "$3" != "-" ]]; then
    skip=$(jq -cn --arg h "$3" '{head_sha: $h, reason: "no_reviewer_available_until x", recorded_at: "2026-11-11T00:00:00Z"}')
  fi
  jq -cn --argjson cr "$rec_cr" --argjson cd "$rec_cd" --argjson sk "$skip" '
    {schema_version: 1, review_availability: ({} + (if $cr == null then {} else {coderabbit: $cr} end)
                                                  + (if $cd == null then {} else {codeant: $cd} end)),
     repos: {"solo/repo": {prs: (if $sk == null then {} else {"1": {review_request_skips: {($sk.head_sha): $sk}}} end)}}}' \
    > "$STATE_FILE"
}

# payload <issue_comments JSON array>
payload() {
  jq -cn --argjson c "$1" --arg cts "$(iso $((PUSH - 3600)))" --arg h "$HEADSHA" --arg chk "$(iso $CHECK)" --argjson win "$WIN" '
    {owner:"solo", repo:"repo", pr:"1", head_sha:$h, commit_ts:$cts, window_seconds:$win,
     tier_gate:"", review_blockers:["no AI reviewer verdict on HEAD"],
     reviews:[], pr_comments:[], issue_comments:$c,
     check_runs_raw:[{name:"build", status:"completed", conclusion:"success",
                      started_at:$chk, app:{slug:"github-actions"}}], hollow:[]}'
}

run_helper() { # <payload> -> helper JSON on stdout
  printf '%s' "$1" | FAKE_FRESH_COMMENTS="${FAKE_FRESH_COMMENTS:-[]}" "$BASH" "$HELPER"
}

# --- 1. Both free reviewers back after the window: skip recorded for HEAD -> override now
av_state $((NOW + 1200)) $((NOW + 1500)) "$HEADSHA"
out=$(run_helper "$(payload "[]")")
expect_eq "skip recorded, reviewers back in 20 min: applied at once (window not elapsed)" "$(jq -r .applied <<<"$out")" "true"
expect_eq "skip recorded: reason names the earliest return" \
  "$(jq -r .reason <<<"$out")" "no_reviewer_available_until $(iso $((NOW + 1200)))"
expect_eq "skip recorded: skip_reason carried in the gate JSON" \
  "$(jq -r .skip_reason <<<"$out")" "no_reviewer_available_until $(iso $((NOW + 1200)))"
expect_eq "skip recorded: eligible" "$(jq -r .eligible <<<"$out")" "true"
expect_eq "skip recorded: waived reasons are the reviewer blockers only" \
  "$(jq -c .waived_reasons <<<"$out")" '["no AI reviewer verdict on HEAD"]'

# --- 2. Reviewer back in 3 min: no skip, so the override waits the window as before
av_state $((NOW + 180)) $((NOW + 180)) "$HEADSHA"
out=$(run_helper "$(payload "[]")")
expect_eq "reviewers back in 3 min: no immediate override" "$(jq -r .applied <<<"$out")" "false"
expect_eq "reviewers back in 3 min: window still running" "$(jq -r .reason <<<"$out")" "window_running"

# --- 3. Both blocked but no skip recorded for this HEAD: the window decides, not the record
av_state $((NOW + 1200)) $((NOW + 1500)) "-"
out=$(run_helper "$(payload "[]")")
expect_eq "no request skip recorded: no immediate override" "$(jq -r .applied <<<"$out")" "false"

# --- 4. Skip recorded for a different HEAD does not apply to this one
av_state $((NOW + 1200)) $((NOW + 1500)) "$OTHERSHA"
out=$(run_helper "$(payload "[]")")
expect_eq "skip recorded for another HEAD: not applied" "$(jq -r .applied <<<"$out")" "false"

# --- 5. Record past its next-available time: stale, never applies (fail toward asking)
av_state $((NOW - 30)) $((NOW + 1500)) "$HEADSHA"
out=$(run_helper "$(payload "[]")")
expect_eq "stale record with a skip recorded: not applied" "$(jq -r .applied <<<"$out")" "false"

# --- 6. Unreadable state: fails closed, the window decides
av_state $((NOW + 1200)) $((NOW + 1500)) "$HEADSHA"
printf '{"schema_version":1' > "$STATE_FILE"
out=$(run_helper "$(payload "[]")")
expect_eq "unreadable state file: not applied" "$(jq -r .applied <<<"$out")" "false"

# --- 7. A CodeRabbit banner in the PR's comments writes the account-wide record -----------
rm -f "$STATE_FILE"
T=$(iso $((NOW - 60)))
BANNER=$(jq -cn --arg t "$T" '[{user:{login:"coderabbitai[bot]"},
  body:"**Review limit reached**\n**Next review available in:** **20 minutes**", created_at:$t, updated_at:$t}]')
out=$(run_helper "$(payload "$BANNER")")
expect_eq "banner in comments: notice recorded for CodeRabbit" \
  "$(jq -r '.review_availability.coderabbit.next_available_epoch' "$STATE_FILE" 2>/dev/null)" "$(( $(jq -rn --arg t "$T" '$t|fromdateiso8601') + 1200 ))"
expect_eq "banner in comments with no skip: still not applied (the record alone skips nothing)" \
  "$(jq -r .applied <<<"$out")" "false"

# --- 8. Hard stop: a failing CI check is never a reviewer blocker, so it is never waived ----
av_state $((NOW + 1200)) $((NOW + 1500)) "$HEADSHA"
failing=$(payload "[]" | jq -c '.review_blockers = ["no AI reviewer verdict on HEAD"] | .check_runs_raw += [{name:"lint", status:"completed", conclusion:"failure", started_at:(.check_runs_raw[0].started_at), app:{slug:"github-actions"}}]')
out=$(run_helper "$failing")
expect_eq "failing CI with a skip recorded: waived list holds reviewer blockers only" \
  "$(jq -c .waived_reasons <<<"$out")" '["no AI reviewer verdict on HEAD"]'
expect_eq "failing CI: the CI check is not a reviewer check, so it stays out of the excluded list" \
  "$(jq -c '[.excluded_reviewer_checks[].name]' <<<"$out")" "[]"

# --- 8. A completed CodeRabbit review newer than its limit record clears it (#2256) -------
# The gate sees CodeRabbit answering again (a non-notice review posted after the record was
# read), so the stale wait must not waive the window even with a skip recorded for HEAD.
av_state $((NOW + 1200)) $((NOW + 1500)) "$HEADSHA"
jq '.review_availability.coderabbit.read_at = (now - 300 | todateiso8601)
    | .review_availability.codeant.read_at = (now - 300 | todateiso8601)' "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
REVIEW_NOW=$(jq -cn --arg t "$(iso $((NOW - 60)))" --arg c "$OTHERSHA" \
  '[{user:{login:"coderabbitai[bot]"}, state:"COMMENTED", commit_id:$c, submitted_at:$t, body:"Review completed."}]')
out=$(run_helper "$(payload "[]" | jq -c --argjson r "$REVIEW_NOW" '.reviews = $r')")
expect_eq "completed CodeRabbit review after its limit record: skip not applied" "$(jq -r .applied <<<"$out")" "false"
expect_eq "completed CodeRabbit review after its limit record: record cleared" \
  "$(jq -r '.review_availability.coderabbit.next_available_epoch' "$STATE_FILE")" "null"
expect_eq "completed CodeRabbit review: the other reviewer's record is kept" \
  "$(jq -r '.review_availability.codeant.next_available_epoch != null' "$STATE_FILE")" "true"

# Fail closed: an observe that cannot run leaves no skip in force for this tick.
av_state $((NOW + 1200)) $((NOW + 1500)) "$HEADSHA"
out=$(run_helper "$(payload "[]" | jq -c '.reviews = "not-a-list"')")
expect_eq "unclearable observe (malformed reviews): skip not applied" "$(jq -r .applied <<<"$out")" "false"

# --- 9. A verdict on HEAD still clears the answering reviewer's stale record (#2256) --------
# The early exit for a verdict on HEAD must not skip the clear: a reviewer that answered
# never keeps a stale wait (CodeAnt #4546742961).
av_state $((NOW + 1200)) $((NOW + 1500)) "-"
jq '.review_availability.coderabbit.read_at = (now - 300 | todateiso8601)' "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
VERDICT_REVIEWS=$(jq -cn --arg t "$(iso $((NOW - 60)))" --arg h "$HEADSHA" \
  '[{user:{login:"coderabbitai[bot]"}, state:"APPROVED", commit_id:$h, submitted_at:$t, body:"LGTM"}]')
out=$(run_helper "$(payload "[]" | jq -c --argjson r "$VERDICT_REVIEWS" '.reviews = $r')")
expect_eq "verdict on HEAD: the answering reviewer's stale record is cleared" \
  "$(jq -r '.review_availability.coderabbit.next_available_epoch' "$STATE_FILE")" "null"
expect_eq "verdict on HEAD: the reason is the verdict, not a skip" "$(jq -r .reason <<<"$out")" "verdict_on_head"

echo
echo "no-review-override availability tests: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
