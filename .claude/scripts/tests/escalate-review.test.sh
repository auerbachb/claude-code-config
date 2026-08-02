#!/usr/bin/env bash
# Offline unit tests for escalate-review.sh (issue #552 — content-aware BugBot
# failure detection). Copies escalate-review.sh into a temp SCRIPT_DIR
# alongside a stubbed pr-state.sh (so its own $SCRIPT_DIR-relative sibling
# resolution picks up the stub) and the REAL session-state.sh/greptile-budget.sh
# (both are network-free — they only touch $HOME/.claude/session-state.json).
# Stubs `gh` on PATH for the one direct `gh api .../commits` call the script
# makes outside of pr-state.sh. Requires jq + python3. Run from repo root:
#   bash .claude/scripts/tests/escalate-review.test.sh
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"

TMP="$(mktemp -d)"
TMP_HOME="$(mktemp -d)"
cleanup() { rm -rf "$TMP" "$TMP_HOME"; }
trap cleanup EXIT
export HOME="$TMP_HOME"
mkdir -p "$HOME/.claude"

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

# ---- temp SCRIPT_DIR: real script + stub pr-state.sh + real session-state.sh
#      + real greptile-budget.sh (network-free, so safe to use for real) -----
STUB_DIR="$TMP/scripts"
mkdir -p "$STUB_DIR"
cp "$REPO_ROOT/.claude/scripts/escalate-review.sh" "$STUB_DIR/escalate-review.sh"
cp "$REPO_ROOT/.claude/scripts/session-state.sh" "$STUB_DIR/session-state.sh"
cp "$REPO_ROOT/.claude/scripts/greptile-budget.sh" "$STUB_DIR/greptile-budget.sh"
# Real script, not a stub (issue #875): escalate-review.sh fails closed when the
# substance evaluator is unavailable, so omitting it here would turn every
# gate_met scenario into trigger_greptile.
cp "$REPO_ROOT/.claude/scripts/review-substance.sh" "$STUB_DIR/review-substance.sh"
# Sibling write-lock library (issue #639) — session-state.sh and
# greptile-budget.sh source it from their own directory and hard-fail without
# it rather than writing unserialized, so the stub dir needs it too.
cp "$REPO_ROOT/.claude/scripts/state-lock.sh" "$STUB_DIR/state-lock.sh"
# Shared case-normalizer library (issue #704) — session-state.sh sources it
# from $SCRIPT_DIR/lib/ and hard-fails without it, so the stub dir needs the
# lib/ subdirectory mirrored alongside the other siblings.
mkdir -p "$STUB_DIR/lib"
cp "$REPO_ROOT/.claude/scripts/lib/repo-normalizer.sh" "$STUB_DIR/lib/repo-normalizer.sh"
chmod +x "$STUB_DIR/escalate-review.sh" "$STUB_DIR/session-state.sh" "$STUB_DIR/greptile-budget.sh"

cat > "$STUB_DIR/pr-state.sh" <<'STUB'
#!/usr/bin/env bash
# Test stub: ignore all args, just print the path to the fixture the test wrote.
echo "$FIXTURE_STATE_JSON"
STUB
chmod +x "$STUB_DIR/pr-state.sh"

# ---- stub gh (only the direct .../commits call escalate-review.sh makes) ---
STUB_BIN="$TMP/bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/gh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
sub="$1"; shift || true
case "$sub" in
  api)
    for arg in "$@"; do
      case "$arg" in
        repos/*/pulls/*/commits*)
          cat "$FIXTURE_COMMITS_JSON"
          exit 0
          ;;
        repos/*/git/commits/*)
          # HEAD committer date (issue #875). escalate-review.sh feeds this to
          # review-substance.sh as push_ts, and BOTH the temporal-inversion and
          # capability-failure signals are scoped to "post-push" — an empty
          # push_ts silently disables them, so a stub returning [] here would let
          # every scenario below pass while those branches were never executed.
          cat "$FIXTURE_GIT_COMMIT_JSON"
          exit 0
          ;;
      esac
    done
    echo "[]"
    ;;
  *)
    exit 0
    ;;
esac
STUB
chmod +x "$STUB_BIN/gh"
export PATH="$STUB_BIN:$PATH"

# ---- helpers -----------------------------------------------------------------
PR_NUM="99552"
OWNER="test-owner"
REPO="test-repo"
HEAD_SHA="deadbeef0000000000000000000000000000abcd"

# Timestamp N seconds in the past, ISO 8601 UTC (python3 — already a hard
# dependency of escalate-review.sh, so portable across macOS/Linux).
ts_seconds_ago() {
  python3 -c "
from datetime import datetime, timedelta, timezone
print((datetime.now(timezone.utc) - timedelta(seconds=$1)).strftime('%Y-%m-%dT%H:%M:%SZ'))
"
}

# Reset per-scenario state: fresh session-state.json (no cached bugbot_installed)
# so every run exercises the cache-miss classification branch.
reset_state() {
  rm -f "$HOME/.claude/session-state.json"
}

# Pre-seed `.prs[<PR>].bugbot_installed` the way an EARLIER cycle of the same PR
# would have (issue #948). Uses the same real session-state.sh from $STUB_DIR
# that escalate-review.sh calls, run from the same cwd ($REPO_ROOT), so the
# per-repo scoping resolves to the identical key the script will read back.
#
# Reads the value back and asserts it: a silent seed failure would leave (n6) in
# the same state as (n1), which expects the same verdict — so (n6) would keep
# passing while testing nothing. Assert the setup RAN, not just its outcome.
seed_bugbot_installed() {
  local want="$1" got
  ( cd "$REPO_ROOT" && "$STUB_DIR/session-state.sh" \
      --set ".prs[\"$PR_NUM\"].bugbot_installed=$want" >/dev/null )
  got="$( cd "$REPO_ROOT" && "$STUB_DIR/session-state.sh" \
      --get ".prs[\"$PR_NUM\"].bugbot_installed" 2>/dev/null )"
  check_eq "bugbot_installed pre-seeded to $want" "$want" "$got"
}

write_commits() {
  local push_ts="$1"
  cat > "$TMP/commits.json" <<EOF
[{"sha": "$HEAD_SHA", "commit": {"committer": {"date": "$push_ts"}, "author": {"date": "$push_ts"}}}]
EOF
  export FIXTURE_COMMITS_JSON="$TMP/commits.json"
  # Separate shape: `git/commits/{sha}` returns a single object with .committer.date,
  # not the array `pulls/{n}/commits` returns. escalate-review.sh reads
  # `.committer.date` from it — feeding it the array form yields "" and disables
  # the post-push signals.
  cat > "$TMP/git-commit.json" <<EOF
{"sha": "$HEAD_SHA", "committer": {"date": "$push_ts"}, "author": {"date": "$push_ts"}}
EOF
  export FIXTURE_GIT_COMMIT_JSON="$TMP/git-commit.json"
}

# CodeRabbit rate-limited check-run — included in every scenario so the script
# passes the CR gate and reaches BugBot classification regardless of AGE_SECONDS.
CR_RATE_LIMIT_CHECK_RUN='{"id": 1, "name": "CodeRabbit", "status": "completed", "conclusion": "failure", "title": "Review limit reached — rate limit"}'

write_state() {
  # $1 = extra check_runs.all entries (JSON array literal, e.g. '[{"id":2,...}]')
  # $2 = reviews array, $3 = inline array, $4 = conversation array
  local extra_runs="$1" reviews="$2" inline="$3" conversation="$4"
  jq -n \
    --arg owner "$OWNER" --arg repo "$REPO" --arg sha "$HEAD_SHA" \
    --argjson cr_run "$CR_RATE_LIMIT_CHECK_RUN" \
    --argjson extra_runs "$extra_runs" \
    --argjson reviews "$reviews" --argjson inline "$inline" --argjson conversation "$conversation" \
    '{
      pr: {owner: $owner, repo: $repo, head_sha: $sha},
      check_runs: {all: ([$cr_run] + $extra_runs)},
      commit_statuses: [],
      comments: {reviews: $reviews, inline: $inline, conversation: $conversation}
    }' > "$TMP/state.json"
  export FIXTURE_STATE_JSON="$TMP/state.json"
}

run_script() {
  ( cd "$REPO_ROOT" && bash "$STUB_DIR/escalate-review.sh" "$PR_NUM" )
}

# Every canonical BugBot check-run below carries the PUBLISHING APP the real one
# does (issue #956) — pr-state.sh projects `app: {slug, id}` onto each check-run
# entry, and escalate-review.sh now requires slug `cursor` alongside the name.
# Values confirmed against live data on this repo (app slug `cursor`, app id
# 1210556, app name "Cursor"), reproducible with:
#   gh api repos/auerbachb/claude-code-config/commits/<sha>/check-runs?per_page=100 \
#     --jq '.check_runs[] | select(.name=="Cursor Bugbot") | {slug: .app.slug, id: .app.id}'
CURSOR_APP='"app": {"slug": "cursor", "id": 1210556}'
# A DIFFERENT app publishing a check-run under the very same name — the spoof
# shape the app scope exists to reject. github-actions is the other publisher
# actually seen on this repo's commits, so this is a realistic collision rather
# than an invented slug.
FOREIGN_APP='"app": {"slug": "github-actions", "id": 15368}'

BUGBOT_CHECK_RUN_OK='{"id": 2, "name": "Cursor Bugbot", "status": "completed", "conclusion": "neutral", "title": "", '"$CURSOR_APP"'}'
BUGBOT_CHECK_RUN_FAILED_TITLE='{"id": 2, "name": "Cursor Bugbot", "status": "completed", "conclusion": "neutral", "title": "Bugbot couldn'"'"'t run - usage limit reached", '"$CURSOR_APP"'}'
BUGBOT_CHECK_RUN_TIMED_OUT='{"id": 2, "name": "Cursor Bugbot", "status": "completed", "conclusion": "timed_out", "title": "", '"$CURSOR_APP"'}'
# Silent-pass shape (issue #844): conclusion:success — BugBot found no issues.
# merge-gate.sh now accepts this as a clean BugBot pass, but escalate-review.sh
# still emits switch_bugbot so the caller persists sticky ownership before polling.
BUGBOT_CHECK_RUN_SUCCESS='{"id": 2, "name": "Cursor Bugbot", "status": "completed", "conclusion": "success", "title": "", '"$CURSOR_APP"'}'
# A run that exists on this HEAD but has NOT finished (issue #948). Both
# content-aware flags are false for it — BUGBOT_FAILED needs a definitive
# failure, BUGBOT_GENUINE needs status=completed — so it is the one shape where
# the never-invited branch's footprint term is the only thing that sees it.
BUGBOT_CHECK_RUN_IN_PROGRESS='{"id": 2, "name": "Cursor Bugbot", "status": "in_progress", "conclusion": null, "title": "", '"$CURSOR_APP"'}'

# --- issue #956 fixtures: same check NAME, wrong or absent publisher ----------
# Each is a byte-for-byte twin of a canonical fixture above with only the `app`
# object changed, so any verdict difference is attributable to the app scope and
# nothing else. The NO_APP pair is a bundle written before pr-state.sh carried
# app identity — the missing-slug fallback, which must land on the cheap error
# (a duplicate `@cursor review`) rather than on paid Greptile budget.
BUGBOT_RUN_FOREIGN_IN_PROGRESS='{"id": 2, "name": "Cursor Bugbot", "status": "in_progress", "conclusion": null, "title": "", '"$FOREIGN_APP"'}'
BUGBOT_RUN_NO_APP_IN_PROGRESS='{"id": 2, "name": "Cursor Bugbot", "status": "in_progress", "conclusion": null, "title": ""}'
BUGBOT_RUN_FOREIGN_OK='{"id": 2, "name": "Cursor Bugbot", "status": "completed", "conclusion": "neutral", "title": "", '"$FOREIGN_APP"'}'
BUGBOT_RUN_NO_APP_OK='{"id": 2, "name": "Cursor Bugbot", "status": "completed", "conclusion": "neutral", "title": ""}'
BUGBOT_RUN_FOREIGN_FAILED_TITLE='{"id": 2, "name": "Cursor Bugbot", "status": "completed", "conclusion": "neutral", "title": "Bugbot couldn'"'"'t run - usage limit reached", '"$FOREIGN_APP"'}'

# Comments carry explicit created_at timestamps so "latest event wins" ordering
# (issue #552 CodeRabbit finding) is genuinely exercised, not an accident of
# array-literal order.
failure_comment() {
  printf '{"user": {"login": "cursor[bot]"}, "created_at": "%s", "body": "Bugbot couldn'"'"'t run - usage limit reached. A user or team admin can review and increase usage limits."}' "$1"
}
failure_comment_alt() {
  printf '{"user": {"login": "cursor[bot]"}, "created_at": "%s", "body": "Bugbot is counted against Cursor usage for this user or team, and this run hit a usage or spend limit."}' "$1"
}
genuine_comment() {
  printf '{"user": {"login": "cursor[bot]"}, "created_at": "%s", "body": "Found 1 bug in this PR: possible null dereference on line 42."}' "$1"
}
# The `@cursor review` invitation (issue #935) — posted by CI via
# CURSOR_REVIEW_PAT, or by hand. Author is deliberately NOT cursor[bot]: the
# script ignores the phrase in BugBot's own comments, since quoting it back is
# not an invitation.
trigger_comment() {
  printf '{"user": {"login": "test-user"}, "created_at": "%s", "body": "@cursor review"}' "$1"
}

############################################################################
echo "== Scenario (a): usage-limit failure comment + completed check-run -> trigger_greptile =="
reset_state
write_commits "$(ts_seconds_ago 120)"   # recent push (AGE_SECONDS < 600) — proves grace-window skip
FAILURE_COMMENT="$(failure_comment "$(ts_seconds_ago 60)")"
write_state "[$BUGBOT_CHECK_RUN_OK]" "[]" "[]" "[$FAILURE_COMMENT]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=trigger_greptile" "STATUS=trigger_greptile" "$OUT"

############################################################################
echo "== Scenario (a2): usage-limit failure via check-run title only (no comment) -> trigger_greptile =="
reset_state
write_commits "$(ts_seconds_ago 120)"
write_state "[$BUGBOT_CHECK_RUN_FAILED_TITLE]" "[]" "[]" "[]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=trigger_greptile" "STATUS=trigger_greptile" "$OUT"

############################################################################
echo "== Scenario (b): genuine BugBot findings comment -> switch_bugbot =="
reset_state
write_commits "$(ts_seconds_ago 7200)"
GENUINE_COMMENT="$(genuine_comment "$(ts_seconds_ago 7000)")"
write_state "[$BUGBOT_CHECK_RUN_OK]" "[]" "[]" "[$GENUINE_COMMENT]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=switch_bugbot" "STATUS=switch_bugbot" "$OUT"

############################################################################
echo "== Scenario (c): genuine clean pass via completed check-run, no comment -> switch_bugbot =="
reset_state
write_commits "$(ts_seconds_ago 7200)"
write_state "[$BUGBOT_CHECK_RUN_OK]" "[]" "[]" "[]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=switch_bugbot" "STATUS=switch_bugbot" "$OUT"

############################################################################
echo "== Scenario (d): failure comment followed by a LATER genuine review (by timestamp) -> switch_bugbot =="
reset_state
write_commits "$(ts_seconds_ago 7200)"
FAILURE_COMMENT_D="$(failure_comment "$(ts_seconds_ago 7000)")"
GENUINE_COMMENT_D="$(genuine_comment "$(ts_seconds_ago 3000)")"
write_state "[$BUGBOT_CHECK_RUN_OK]" "[]" "[]" "[$FAILURE_COMMENT_D, $GENUINE_COMMENT_D]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=switch_bugbot" "STATUS=switch_bugbot" "$OUT"

############################################################################
echo "== Scenario (e): alt failure phrasing (\"usage or spend limit\") also detected -> trigger_greptile =="
reset_state
write_commits "$(ts_seconds_ago 120)"
FAILURE_COMMENT_ALT="$(failure_comment_alt "$(ts_seconds_ago 60)")"
write_state "[$BUGBOT_CHECK_RUN_OK]" "[]" "[]" "[$FAILURE_COMMENT_ALT]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=trigger_greptile" "STATUS=trigger_greptile" "$OUT"

############################################################################
echo "== Scenario (f): genuine review followed by a LATER failure comment -> trigger_greptile (CodeRabbit finding) =="
reset_state
write_commits "$(ts_seconds_ago 120)"
GENUINE_COMMENT_F="$(genuine_comment "$(ts_seconds_ago 7000)")"
FAILURE_COMMENT_F="$(failure_comment "$(ts_seconds_ago 60)")"
write_state "[$BUGBOT_CHECK_RUN_OK]" "[]" "[]" "[$GENUINE_COMMENT_F, $FAILURE_COMMENT_F]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=trigger_greptile" "STATUS=trigger_greptile" "$OUT"

############################################################################
echo "== Scenario (g): check-run has a blocking conclusion (timed_out) with a non-matching title, no comment -> trigger_greptile (CodeAnt finding) =="
reset_state
write_commits "$(ts_seconds_ago 120)"
write_state "[$BUGBOT_CHECK_RUN_TIMED_OUT]" "[]" "[]" "[]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=trigger_greptile" "STATUS=trigger_greptile" "$OUT"

############################################################################
echo "== Scenario (h): CR rate-limited + BugBot usage-limit failure + CodeAnt already APPROVED on HEAD -> gate_met (NOT trigger_greptile) =="
reset_state
write_commits "$(ts_seconds_ago 120)"
FAILURE_COMMENT_H="$(failure_comment "$(ts_seconds_ago 60)")"
# The approval body is substantive on purpose (issue #875): escalate-review now
# discounts an APPROVED with no evidence anything read the commit, so a body-less
# fixture would fail for the wrong reason instead of testing the gate_met path.
CODEANT_APPROVED_H='{"user": {"login": "codeant-ai[bot]"}, "commit_id": "'"$HEAD_SHA"'", "state": "APPROVED", "body": "Actionable comments posted: 0. Reviewed the changed files; no issues found.", "submitted_at": "'"$(ts_seconds_ago 90)"'"}'
write_state "[$BUGBOT_CHECK_RUN_OK]" "[$CODEANT_APPROVED_H]" "[]" "[$FAILURE_COMMENT_H]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=gate_met" "STATUS=gate_met" "$OUT"

############################################################################
# Scenarios (h2)-(h4) exist because the gh stub originally returned [] for
# `git/commits/{sha}`, leaving push_ts empty in EVERY scenario above. Both
# post-push signals are `if $push == "" then null` guarded, so temporal
# inversion and capability failure were structurally unreachable from this
# suite — (h) passed and would have kept passing with either branch deleted.
echo "== Scenario (h2): CodeAnt APPROVED before its own run-start marker, nothing else -> trigger_greptile (temporal inversion) =="
reset_state
write_commits "$(ts_seconds_ago 300)"
FAILURE_COMMENT_H2="$(failure_comment "$(ts_seconds_ago 60)")"
# Empty body, no inline comments, no status comment naming HEAD — approved at
# T-200 while the bot only announced it had started at T-190. ccc#867's shape.
CODEANT_APPROVED_H2='{"user": {"login": "codeant-ai[bot]"}, "commit_id": "'"$HEAD_SHA"'", "state": "APPROVED", "body": "", "submitted_at": "'"$(ts_seconds_ago 200)"'"}'
CODEANT_MARKER_H2='{"user": {"login": "codeant-ai[bot]"}, "created_at": "'"$(ts_seconds_ago 190)"'", "body": "CodeAnt AI is running the review on your pull request. Results will be posted shortly."}'
write_state "[$BUGBOT_CHECK_RUN_OK]" "[$CODEANT_APPROVED_H2]" "[]" "[$FAILURE_COMMENT_H2, $CODEANT_MARKER_H2]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=trigger_greptile" "STATUS=trigger_greptile" "$OUT"

############################################################################
echo "== Scenario (h3): same inversion, but inline comments on HEAD prove a real read -> gate_met =="
reset_state
write_commits "$(ts_seconds_ago 300)"
FAILURE_COMMENT_H3="$(failure_comment "$(ts_seconds_ago 60)")"
CODEANT_APPROVED_H3='{"user": {"login": "codeant-ai[bot]"}, "commit_id": "'"$HEAD_SHA"'", "state": "APPROVED", "body": "", "submitted_at": "'"$(ts_seconds_ago 200)"'"}'
CODEANT_MARKER_H3='{"user": {"login": "codeant-ai[bot]"}, "created_at": "'"$(ts_seconds_ago 190)"'", "body": "CodeAnt AI is running the review on your pull request. Results will be posted shortly."}'
# Evidence outside the approval object redeems it even though it lands AFTER the
# approval — the documented bodylen=0 + walkthrough shape (mia#172 396ced5).
CODEANT_INLINE_H3='{"user": {"login": "codeant-ai[bot]"}, "commit_id": "'"$HEAD_SHA"'", "original_commit_id": "'"$HEAD_SHA"'", "created_at": "'"$(ts_seconds_ago 180)"'", "path": "a.sh", "body": "Suggestion: this branch is unreachable."}'
write_state "[$BUGBOT_CHECK_RUN_OK]" "[$CODEANT_APPROVED_H3]" "[$CODEANT_INLINE_H3]" "[$FAILURE_COMMENT_H3, $CODEANT_MARKER_H3]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=gate_met" "STATUS=gate_met" "$OUT"

############################################################################
echo "== Scenario (h4): CodeAnt APPROVED after saying it could not review -> trigger_greptile (capability failure) =="
reset_state
write_commits "$(ts_seconds_ago 300)"
FAILURE_COMMENT_H4="$(failure_comment "$(ts_seconds_ago 60)")"
# The notice is long and names HEAD — before this was fixed it counted as the
# reviewer's own substantive status comment AND, by being the latest evidence,
# suppressed the capability-failure check meant to catch it.
CODEANT_NOSUB_H4='{"user": {"login": "codeant-ai[bot]"}, "created_at": "'"$(ts_seconds_ago 210)"'", "body": "User ci@example.com does not have a PR Review subscription, so commit '"$HEAD_SHA"' was not reviewed. Contact your administrator to enable reviews for this account."}'
CODEANT_APPROVED_H4='{"user": {"login": "codeant-ai[bot]"}, "commit_id": "'"$HEAD_SHA"'", "state": "APPROVED", "body": "", "submitted_at": "'"$(ts_seconds_ago 200)"'"}'
write_state "[$BUGBOT_CHECK_RUN_OK]" "[$CODEANT_APPROVED_H4]" "[]" "[$FAILURE_COMMENT_H4, $CODEANT_NOSUB_H4]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=trigger_greptile" "STATUS=trigger_greptile" "$OUT"

############################################################################
echo "== Scenario (h5): substantive-but-RETRACTED CR + fresh hollow CodeAnt -> trigger_greptile (same reviewer must clear both gates) =="
reset_state
write_commits "$(ts_seconds_ago 300)"
FAILURE_COMMENT_H5="$(failure_comment "$(ts_seconds_ago 60)")"
# CodeRabbit's approval is substantive, so it lands in the evaluator's
# substantive[] — but it is retracted by a later CHANGES_REQUESTED, so it is not
# a valid approval. CodeAnt's approval IS valid but is an empty rubber stamp.
# Testing "substantive[] is non-empty" on its own reported gate_met here, while
# merge-gate.sh rejected both — stranding the PR with no reviewer and no
# escalation in flight.
CR_APPROVED_H5='{"user": {"login": "coderabbitai[bot]"}, "commit_id": "'"$HEAD_SHA"'", "state": "APPROVED", "body": "Actionable comments posted: 0. Reviewed every changed file; behaviour preserved throughout.", "submitted_at": "'"$(ts_seconds_ago 250)"'"}'
CR_RETRACT_H5='{"user": {"login": "coderabbitai[bot]"}, "commit_id": "'"$HEAD_SHA"'", "state": "CHANGES_REQUESTED", "submitted_at": "'"$(ts_seconds_ago 200)"'"}'
CA_HOLLOW_H5='{"user": {"login": "codeant-ai[bot]"}, "commit_id": "'"$HEAD_SHA"'", "state": "APPROVED", "body": "", "submitted_at": "'"$(ts_seconds_ago 150)"'"}'
write_state "[$BUGBOT_CHECK_RUN_OK]" "[$CR_APPROVED_H5, $CR_RETRACT_H5, $CA_HOLLOW_H5]" "[]" "[$FAILURE_COMMENT_H5]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=trigger_greptile" "STATUS=trigger_greptile" "$OUT"

############################################################################
echo "== Scenario (h6): approval RETARGETED onto HEAD but predating the commit -> trigger_greptile (issue #836 freshness) =="
reset_state
write_commits "$(ts_seconds_ago 300)"
FAILURE_COMMENT_H6="$(failure_comment "$(ts_seconds_ago 60)")"
# GitHub retargets commit_id onto HEAD after a force-push without touching
# submitted_at. This approval is substantive AND on HEAD, but it was submitted
# an hour before the commit existed, so merge-gate.sh rejects it — escalation
# must not short-circuit on it either.
CODEANT_STALE_H6='{"user": {"login": "codeant-ai[bot]"}, "commit_id": "'"$HEAD_SHA"'", "state": "APPROVED", "body": "Actionable comments posted: 0. Reviewed every changed file; no blocking issues found.", "submitted_at": "'"$(ts_seconds_ago 3600)"'"}'
write_state "[$BUGBOT_CHECK_RUN_OK]" "[$CODEANT_STALE_H6]" "[]" "[$FAILURE_COMMENT_H6]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=trigger_greptile" "STATUS=trigger_greptile" "$OUT"

############################################################################
echo "== Scenario (h6b): fresh approval spelled +00:00 against a Z commit date -> gate_met (no false stale) =="
reset_state
# Commit date carries an explicit +00:00 offset while the approval uses Z. As
# raw strings "...+00:00" sorts BEFORE "...Z", so without canonicalisation the
# freshness filter would call this fresh approval stale and withhold gate_met.
PUSH_H6B="$(python3 -c "
from datetime import datetime, timedelta, timezone
print((datetime.now(timezone.utc) - timedelta(seconds=300)).strftime('%Y-%m-%dT%H:%M:%S+00:00'))
")"
write_commits "$PUSH_H6B"
FAILURE_COMMENT_H6B="$(failure_comment "$(ts_seconds_ago 60)")"
CODEANT_APPROVED_H6B='{"user": {"login": "codeant-ai[bot]"}, "commit_id": "'"$HEAD_SHA"'", "state": "APPROVED", "body": "Actionable comments posted: 0. Reviewed every changed file; no blocking issues found.", "submitted_at": "'"$(ts_seconds_ago 90)"'"}'
write_state "[$BUGBOT_CHECK_RUN_OK]" "[$CODEANT_APPROVED_H6B]" "[]" "[$FAILURE_COMMENT_H6B]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=gate_met" "STATUS=gate_met" "$OUT"

############################################################################
echo "== Scenario (h6e): fresh approval spelled Z against a +0000 commit date -> gate_met (all three UTC spellings normalise) =="
reset_state
# The compact "+0000" spelling of the same instant. BugBot flagged (on c90b32a)
# that this filter stripped it while norm_ts in merge-gate.sh did not, so the two
# disagreed on identical inputs; norm_ts now strips it too. Pins that the spelling
# is normalised rather than compared raw — as raw strings "...+0000" sorts BEFORE
# "...Z", which would mark this fresh approval stale and withhold gate_met.
PUSH_H6E="$(python3 -c "
from datetime import datetime, timedelta, timezone
print((datetime.now(timezone.utc) - timedelta(seconds=300)).strftime('%Y-%m-%dT%H:%M:%S+0000'))
")"
write_commits "$PUSH_H6E"
FAILURE_COMMENT_H6E="$(failure_comment "$(ts_seconds_ago 60)")"
CODEANT_APPROVED_H6E='{"user": {"login": "codeant-ai[bot]"}, "commit_id": "'"$HEAD_SHA"'", "state": "APPROVED", "body": "Actionable comments posted: 0. Reviewed every changed file; no blocking issues found.", "submitted_at": "'"$(ts_seconds_ago 90)"'"}'
write_state "[$BUGBOT_CHECK_RUN_OK]" "[$CODEANT_APPROVED_H6E]" "[]" "[$FAILURE_COMMENT_H6E]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=gate_met" "STATUS=gate_met" "$OUT"

############################################################################
echo "== Scenario (h6c): approval earlier in the SAME second as a fractional commit date -> trigger_greptile (must agree with merge-gate.sh) =="
reset_state
# BugBot review on 7de2a4c (PR #883): escalate-review.sh and merge-gate.sh
# implement one rule (#836), so they must order the same pair identically. The
# commit date carries fractional seconds and the approval lands earlier within
# that same second, so merge-gate.sh's norm_ts (strip zone suffix, KEEP the
# fraction) rules the approval stale and blocks. The old canon_ts here dropped
# the fraction, collapsing the two to the same instant and reporting gate_met on
# a PR the gate refuses — escalation must never be the more permissive of the two.
PUSH_H6C="$(python3 -c "
from datetime import datetime, timedelta, timezone
print((datetime.now(timezone.utc) - timedelta(seconds=300)).strftime('%Y-%m-%dT%H:%M:%S.900000Z'))
")"
APPROVED_H6C="$(python3 -c "
from datetime import datetime, timedelta, timezone
print((datetime.now(timezone.utc) - timedelta(seconds=300)).strftime('%Y-%m-%dT%H:%M:%SZ'))
")"
write_commits "$PUSH_H6C"
FAILURE_COMMENT_H6C="$(failure_comment "$(ts_seconds_ago 60)")"
CODEANT_APPROVED_H6C='{"user": {"login": "codeant-ai[bot]"}, "commit_id": "'"$HEAD_SHA"'", "state": "APPROVED", "body": "Actionable comments posted: 0. Reviewed every changed file; no blocking issues found.", "submitted_at": "'"$APPROVED_H6C"'"}'
write_state "[$BUGBOT_CHECK_RUN_OK]" "[$CODEANT_APPROVED_H6C]" "[]" "[$FAILURE_COMMENT_H6C]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=trigger_greptile" "STATUS=trigger_greptile" "$OUT"

############################################################################
echo "== Scenario (h6d): fractional-second approval AFTER a whole-second commit date -> gate_met (fraction must not invert the order) =="
reset_state
# The mirror of (h6c), and the reason the fix strips the zone suffix instead of
# rewriting it to "Z": under a trailing "Z", "." (0x2E) sorts below "Z" (0x5A),
# so the LATER instant "…49.900Z" would compare BELOW "…49Z" and a genuinely
# fresh approval would be withheld. With the suffix stripped, plain lexicographic
# order is correct for whole and fractional seconds alike.
PUSH_H6D="$(python3 -c "
from datetime import datetime, timedelta, timezone
print((datetime.now(timezone.utc) - timedelta(seconds=300)).strftime('%Y-%m-%dT%H:%M:%SZ'))
")"
APPROVED_H6D="$(python3 -c "
from datetime import datetime, timedelta, timezone
print((datetime.now(timezone.utc) - timedelta(seconds=300)).strftime('%Y-%m-%dT%H:%M:%S.900000Z'))
")"
write_commits "$PUSH_H6D"
FAILURE_COMMENT_H6D="$(failure_comment "$(ts_seconds_ago 60)")"
CODEANT_APPROVED_H6D='{"user": {"login": "codeant-ai[bot]"}, "commit_id": "'"$HEAD_SHA"'", "state": "APPROVED", "body": "Actionable comments posted: 0. Reviewed every changed file; no blocking issues found.", "submitted_at": "'"$APPROVED_H6D"'"}'
write_state "[$BUGBOT_CHECK_RUN_OK]" "[$CODEANT_APPROVED_H6D]" "[]" "[$FAILURE_COMMENT_H6D]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=gate_met" "STATUS=gate_met" "$OUT"

############################################################################
echo "== Scenario (h7): HEAD commit timestamp unavailable -> fail closed, no gate_met =="
reset_state
write_commits "$(ts_seconds_ago 300)"
# Blank out ONLY the git/commits fixture: freshness becomes unverifiable, which
# merge-gate.sh treats as blocking (CR_APPROVAL_FRESHNESS_UNKNOWN). Escalation
# must match rather than reporting gate_met on an approval it cannot vouch for.
echo '{}' > "$TMP/git-commit-empty.json"
FIXTURE_GIT_COMMIT_JSON="$TMP/git-commit-empty.json"
export FIXTURE_GIT_COMMIT_JSON
FAILURE_COMMENT_H7="$(failure_comment "$(ts_seconds_ago 60)")"
CODEANT_APPROVED_H7='{"user": {"login": "codeant-ai[bot]"}, "commit_id": "'"$HEAD_SHA"'", "state": "APPROVED", "body": "Actionable comments posted: 0. Reviewed every changed file; no blocking issues found.", "submitted_at": "'"$(ts_seconds_ago 90)"'"}'
write_state "[$BUGBOT_CHECK_RUN_OK]" "[$CODEANT_APPROVED_H7]" "[]" "[$FAILURE_COMMENT_H7]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=trigger_greptile" "STATUS=trigger_greptile" "$OUT"

############################################################################
echo "== Scenario (i): CodeAnt APPROVED on an OLDER SHA (not HEAD) -> still trigger_greptile (stale approval doesn't satisfy the gate) =="
reset_state
write_commits "$(ts_seconds_ago 120)"
FAILURE_COMMENT_I="$(failure_comment "$(ts_seconds_ago 60)")"
CODEANT_APPROVED_STALE='{"user": {"login": "codeant-ai[bot]"}, "commit_id": "stale0000000000000000000000000000000000", "state": "APPROVED", "submitted_at": "'"$(ts_seconds_ago 9000)"'"}'
write_state "[$BUGBOT_CHECK_RUN_OK]" "[$CODEANT_APPROVED_STALE]" "[]" "[$FAILURE_COMMENT_I]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=trigger_greptile" "STATUS=trigger_greptile" "$OUT"

############################################################################
echo "== Scenario (j): CodeAnt APPROVED on HEAD but retracted by a LATER CHANGES_REQUESTED on HEAD -> still trigger_greptile =="
reset_state
write_commits "$(ts_seconds_ago 120)"
FAILURE_COMMENT_J="$(failure_comment "$(ts_seconds_ago 60)")"
CODEANT_APPROVED_J='{"user": {"login": "codeant-ai[bot]"}, "commit_id": "'"$HEAD_SHA"'", "state": "APPROVED", "body": "Actionable comments posted: 0. Reviewed the changed files; no issues found.", "submitted_at": "'"$(ts_seconds_ago 200)"'"}'
CODEANT_RETRACT_J='{"user": {"login": "codeant-ai[bot]"}, "commit_id": "'"$HEAD_SHA"'", "state": "CHANGES_REQUESTED", "submitted_at": "'"$(ts_seconds_ago 100)"'"}'
write_state "[$BUGBOT_CHECK_RUN_OK]" "[$CODEANT_APPROVED_J, $CODEANT_RETRACT_J]" "[]" "[$FAILURE_COMMENT_J]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=trigger_greptile" "STATUS=trigger_greptile" "$OUT"

############################################################################
echo "== Scenario (k): CR commit-status rate-limit via state:success + description only (issue #708) -> skips CR gate immediately, no 12-min wait =="
reset_state
write_commits "$(ts_seconds_ago 60)"   # recent push (AGE_SECONDS well under 720) — proves no dependency on the AGE_SECONDS fallback
CR_STATUS_RATE_LIMITED='{"context": "CodeRabbit", "state": "success", "description": "Review rate limited"}'
jq -n \
  --arg owner "$OWNER" --arg repo "$REPO" --arg sha "$HEAD_SHA" \
  --argjson bugbot_run "$BUGBOT_CHECK_RUN_OK" \
  --argjson status "$CR_STATUS_RATE_LIMITED" \
  '{
    pr: {owner: $owner, repo: $repo, head_sha: $sha},
    check_runs: {all: [$bugbot_run]},
    commit_statuses: [$status],
    comments: {reviews: [], inline: [], conversation: []}
  }' > "$TMP/state.json"
export FIXTURE_STATE_JSON="$TMP/state.json"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=switch_bugbot" "STATUS=switch_bugbot" "$OUT"

echo
echo "== Scenario L: check-run data still comes only from pr-state.sh's bundle (#675) =="
# escalate-review.sh reads check-runs via pr-state.sh's `check_runs.all`, which is
# deduped at the source (newest check suite per (app, name)). That inheritance is
# the whole reason this script needs no dedup of its own — so guard it: a direct
# `commits/<sha>/check-runs` fetch added here later would silently reintroduce the
# superseded-run bug, and no behavioral test would catch it.
ESCALATE_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../escalate-review.sh"
if grep -qE 'commits/[^"]*/check-runs' "$ESCALATE_SRC"; then
  check_eq "no direct check-runs fetch in escalate-review.sh" "absent" "present"
else
  check_eq "no direct check-runs fetch in escalate-review.sh" "absent" "absent"
fi
# ...and it does still read the bundle, so the guard above cannot pass by the
# script having dropped check-runs entirely.
if grep -q 'check_runs\.all' "$ESCALATE_SRC"; then
  check_eq "escalate-review.sh reads check_runs.all from the bundle" "present" "present"
else
  check_eq "escalate-review.sh reads check_runs.all from the bundle" "present" "absent"
fi

############################################################################
echo
echo "== Scenario (m): silent-pass shape — conclusion:success check-run, no comments -> switch_bugbot (issue #844) =="
# BUGBOT_GENUINE is true for a completed/non-failure check-run with no failure comment,
# regardless of conclusion:success vs neutral. escalate-review.sh must still emit
# switch_bugbot so the caller persists sticky ownership; merge-gate.sh's new check-run
# path (issue #844 primary fix) then accepts the success shape as gate-satisfied.
reset_state
write_commits "$(ts_seconds_ago 7200)"
write_state "[$BUGBOT_CHECK_RUN_SUCCESS]" "[]" "[]" "[]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=switch_bugbot" "STATUS=switch_bugbot" "$OUT"

############################################################################
# "BugBot never invited" vs "BugBot failed" (issue #935)
#
# Every scenario above hands the script a `Cursor Bugbot` check-run, so the
# never-invited state — no check-run AND no cursor[bot] comment, the signature
# an unprovisioned CURSOR_REVIEW_PAT produces (issue #905) — was never
# exercised, and the script escalated straight to a PAID Greptile review on a
# tier nobody had asked. Seen live on PRs #929 and #932; both Phase B agents
# declined the verdict, posted `@cursor review` by hand, and BugBot answered in
# seconds.
#
# n1/n2/n3 are Scenarios A/B/C of the implementation plan. n4 and n5 are the
# negative controls that keep the two new terms from being deletable in silence:
# without n4 the freshness filter is dead weight, without n5 the new branch
# could preempt the grace window and nothing would notice.
############################################################################
echo
echo "== Scenario (n1): never invited — no check-run, no cursor[bot] comment, past the grace window -> switch_bugbot (issue #935) =="
reset_state
write_commits "$(ts_seconds_ago 7200)"
write_state "[]" "[]" "[]" "[]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=switch_bugbot" "STATUS=switch_bugbot" "$OUT"

############################################################################
echo "== Scenario (n2): genuine BugBot failure in the SAME no-check-run shape -> trigger_greptile (parity with pre-#935) =="
# Differs from (n1) by exactly one thing: a cursor[bot] usage-limit comment. A
# classified failure means BugBot WAS asked and could not run, so escalation is
# still correct — the fix must not swallow it. Scenario (a) covers this with a
# check-run present; this pins it in the shape (n1) now diverts.
reset_state
write_commits "$(ts_seconds_ago 7200)"
FAILURE_COMMENT_N2="$(failure_comment "$(ts_seconds_ago 3000)")"
write_state "[]" "[]" "[]" "[$FAILURE_COMMENT_N2]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=trigger_greptile" "STATUS=trigger_greptile" "$OUT"

############################################################################
echo "== Scenario (n3): invited but silent — fresh @cursor review, no BugBot response, past the grace window -> trigger_greptile =="
# Loop avoidance (the issue #552 hazard in reverse): once the invite exists on
# this HEAD and BugBot still says nothing, re-emitting switch_bugbot would just
# post another invite forever. Escalation is the right answer here.
reset_state
write_commits "$(ts_seconds_ago 7200)"
TRIGGER_COMMENT_N3="$(trigger_comment "$(ts_seconds_ago 3000)")"
write_state "[]" "[]" "[]" "[$TRIGGER_COMMENT_N3]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=trigger_greptile" "STATUS=trigger_greptile" "$OUT"

############################################################################
echo "== Scenario (n4): trigger comment PREDATES the HEAD commit -> switch_bugbot (a stale invite must not mask an unprovisioned one) =="
# Same fixture as (n3) with the timestamps swapped: the invite is older than the
# push, so it belongs to an earlier SHA. Without the freshness filter this reads
# as "already invited" and every subsequent push escalates to paid Greptile.
reset_state
write_commits "$(ts_seconds_ago 7200)"
TRIGGER_COMMENT_N4="$(trigger_comment "$(ts_seconds_ago 9000)")"
write_state "[]" "[]" "[]" "[$TRIGGER_COMMENT_N4]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=switch_bugbot" "STATUS=switch_bugbot" "$OUT"

############################################################################
echo "== Scenario (n5): never invited but still INSIDE the 600s grace window -> polling_cr (the new branch must not preempt the wait) =="
# (n1) with a recent push. BugBot may simply not have reported yet, so the
# grace window still owns this cycle; switch_bugbot here would cut it short.
reset_state
write_commits "$(ts_seconds_ago 120)"
write_state "[]" "[]" "[]" "[]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=polling_cr" "STATUS=polling_cr" "$OUT"

############################################################################
# Stale `bugbot_installed` cache vs. the never-invited branch (issue #948)
#
# PR #945 shipped (n1)-(n5) with the branch gated on BUGBOT_INSTALLED, which is
# read from a per-PR cache that is written once and never reset. n6-n8 pin the
# swap to BUGBOT_CHECK_PRESENT — the same question asked of THIS commit's
# check-run bundle instead of the PR's history.
#
# Against the pre-fix script only n6 fails (trigger_greptile), which is the whole
# behavioural delta: the two terms can only disagree when the cache reads true
# while this commit has no BugBot footprint. n7 and n8 pass before and after, and
# are here so the term cannot be DELETED rather than swapped — a bare deletion
# flips both to switch_bugbot and re-invites a BugBot already running on HEAD.
############################################################################
echo
echo "== Scenario (n6): bugbot_installed cached true from an EARLIER SHA, zero footprint on HEAD, past the grace window -> switch_bugbot (issue #948) =="
# (n1) with the cache pre-seeded, i.e. BugBot answered earlier in this PR's life
# and then a later push went uninvited (issue #905). The cache made the branch
# read "already invited here" forever, so this fell through to a PAID Greptile
# review instead of the free `@cursor review` that resolves it in seconds.
reset_state
seed_bugbot_installed true
write_commits "$(ts_seconds_ago 7200)"
write_state "[]" "[]" "[]" "[]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=switch_bugbot" "STATUS=switch_bugbot" "$OUT"

############################################################################
echo "== Scenario (n7): cache true AND an in-flight Cursor Bugbot run on HEAD -> trigger_greptile (a live footprint still shuts the branch) =="
# The negative control for (n6): dropping the term outright — rather than
# swapping the cached proxy for the live one — would emit switch_bugbot here and
# re-invite a BugBot that is already running on this very commit. Escalation is
# unchanged from pre-fix behaviour.
reset_state
seed_bugbot_installed true
write_commits "$(ts_seconds_ago 7200)"
write_state "[$BUGBOT_CHECK_RUN_IN_PROGRESS]" "[]" "[]" "[]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=trigger_greptile" "STATUS=trigger_greptile" "$OUT"

############################################################################
echo "== Scenario (n8): same in-flight run on HEAD, cache NOT readable-true -> trigger_greptile (the derived path shuts the branch too) =="
# (n7)'s mirror over the other cache state, so the live-footprint guard is pinned
# on both paths into BUGBOT_INSTALLED rather than only the cached one.
# Note the seeded `false` is deliberately never read back: escalate-review.sh
# reads the cache as `bugbot_installed // ""`, and jq's `//` treats false exactly
# like null, so a cached false falls through to the derivation below it. That is
# what makes this the DERIVED-true path (BUGBOT_CHECK_PRESENT sets it) rather
# than a second cached-value case.
reset_state
seed_bugbot_installed false
write_commits "$(ts_seconds_ago 7200)"
write_state "[$BUGBOT_CHECK_RUN_IN_PROGRESS]" "[]" "[]" "[]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=trigger_greptile" "STATUS=trigger_greptile" "$OUT"

############################################################################
# Same check NAME, different publishing app (issue #956)
#
# `Cursor Bugbot` used to be matched on the name alone, in both places this
# script reads check-runs: the $run content classifier and BUGBOT_CHECK_PRESENT.
# Any GitHub App may publish a check-run under any name, so a same-named run from
# a foreign app read as BugBot's footprint on this commit — which shuts the
# never-invited branch and spends a PAID Greptile review instead of the FREE
# `@cursor review` that arm posts.
#
# o1/o4/o7 are the three behavioural deltas, one per term the old name-only match
# fed (footprint / genuine / failed). Against the pre-fix script all three return
# the opposite verdict. o2/o5 are the parity controls: the SAME fixtures
# published by the real Cursor app must keep their pre-fix verdicts, so the scope
# cannot be satisfied by refusing every check-run. o3/o6 pin the missing-slug
# fallback on both paths.
############################################################################
echo
echo "== Scenario (o1): foreign app publishes a same-named in-flight run, zero real footprint -> switch_bugbot (issue #956) =="
# (n1) with a spoofed footprint bolted on. Pre-fix this is trigger_greptile: the
# foreign run satisfies BUGBOT_CHECK_PRESENT and the never-invited branch shuts.
reset_state
write_commits "$(ts_seconds_ago 7200)"
write_state "[$BUGBOT_RUN_FOREIGN_IN_PROGRESS]" "[]" "[]" "[]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=switch_bugbot" "STATUS=switch_bugbot" "$OUT"

############################################################################
echo "== Scenario (o2): identical fixture published by the REAL Cursor app -> trigger_greptile (parity control for o1) =="
# Differs from (o1) by the app slug and nothing else. This is (n7) without the
# cache seed: a live Cursor run on HEAD is a genuine footprint, so the
# never-invited branch must stay shut and escalation is unchanged from pre-fix.
reset_state
write_commits "$(ts_seconds_ago 7200)"
write_state "[$BUGBOT_CHECK_RUN_IN_PROGRESS]" "[]" "[]" "[]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=trigger_greptile" "STATUS=trigger_greptile" "$OUT"

############################################################################
echo "== Scenario (o3): same-named in-flight run with NO app identity -> switch_bugbot (missing-slug fallback) =="
# A bundle written before pr-state.sh carried `app`. Unverifiable identity fails
# toward "not a footprint", so the cost is one duplicate `@cursor review`
# (harmless per bugbot.md) rather than a paid Greptile review on an unverified run.
reset_state
write_commits "$(ts_seconds_ago 7200)"
write_state "[$BUGBOT_RUN_NO_APP_IN_PROGRESS]" "[]" "[]" "[]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=switch_bugbot" "STATUS=switch_bugbot" "$OUT"

############################################################################
echo "== Scenario (o4): foreign app's completed run must not read as a genuine BugBot pass -> trigger_greptile =="
# The $run classifier path, isolated from the footprint path by a fresh
# `@cursor review` invite: BugBot WAS asked on this HEAD and never answered, so
# the never-invited branch is closed either way and only BUGBOT_GENUINE decides.
# Pre-fix the foreign completed/neutral run makes BUGBOT_GENUINE true and this
# returns switch_bugbot — i.e. a foreign app got to certify BugBot as responsive.
reset_state
write_commits "$(ts_seconds_ago 7200)"
TRIGGER_COMMENT_O4="$(trigger_comment "$(ts_seconds_ago 3000)")"
write_state "[$BUGBOT_RUN_FOREIGN_OK]" "[]" "[]" "[$TRIGGER_COMMENT_O4]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=trigger_greptile" "STATUS=trigger_greptile" "$OUT"

############################################################################
echo "== Scenario (o5): identical fixture published by the REAL Cursor app -> switch_bugbot (parity control for o4) =="
# Cursor's own completed/neutral run on HEAD is still a genuine response, invite
# or no invite. Without this control the o4 assertion could be satisfied by the
# classifier having stopped recognising check-runs at all.
reset_state
write_commits "$(ts_seconds_ago 7200)"
TRIGGER_COMMENT_O5="$(trigger_comment "$(ts_seconds_ago 3000)")"
write_state "[$BUGBOT_CHECK_RUN_OK]" "[]" "[]" "[$TRIGGER_COMMENT_O5]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=switch_bugbot" "STATUS=switch_bugbot" "$OUT"

############################################################################
echo "== Scenario (o6): completed run with NO app identity, invited on HEAD -> trigger_greptile (missing-slug fallback, classifier path) =="
# (o4)'s fallback twin. The invite postdates the push and nothing verifiable
# answered it, which is exactly (n3)'s invited-but-silent state — escalation,
# not another invite, is the non-looping answer here.
reset_state
write_commits "$(ts_seconds_ago 7200)"
TRIGGER_COMMENT_O6="$(trigger_comment "$(ts_seconds_ago 3000)")"
write_state "[$BUGBOT_RUN_NO_APP_OK]" "[]" "[]" "[$TRIGGER_COMMENT_O6]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=trigger_greptile" "STATUS=trigger_greptile" "$OUT"

############################################################################
echo "== Scenario (o7): foreign app cannot forge a BugBot FAILURE either -> switch_bugbot =="
# The third term the name-only match fed. Pre-fix the foreign run's usage-limit
# title sets BUGBOT_FAILED, which both skips the grace window and shuts the
# never-invited branch, so a stranger's check title alone sent the PR to paid
# Greptile. (a2) pins the same title as a real failure when Cursor publishes it.
reset_state
write_commits "$(ts_seconds_ago 7200)"
write_state "[$BUGBOT_RUN_FOREIGN_FAILED_TITLE]" "[]" "[]" "[]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=switch_bugbot" "STATUS=switch_bugbot" "$OUT"

############################################################################
echo
echo "== Scenario (o8): the app scope is not removable one selector at a time (issue #956) =="
# Structural guard. The behavioural scenarios above cover both selectors today,
# but they check verdicts, not that BOTH matches stayed scoped — a future edit
# could re-widen one of them in a shape no current fixture distinguishes. The
# predicate is a single-line jq def in each of the two programs, so every
# occurrence of the quoted check name must share its line with the app.slug term.
NAME_LINES="$(grep -c '"Cursor Bugbot"' "$ESCALATE_SRC" || true)"
SCOPED_LINES="$(grep '"Cursor Bugbot"' "$ESCALATE_SRC" | grep -c 'app\.slug' || true)"
# Positive control first: without it the equality below passes vacuously if the
# selectors are deleted outright (0 == 0). Two programs read check-runs, so two.
check_eq "both Cursor Bugbot selectors present and app-scoped" "2" "$SCOPED_LINES"
check_eq "no unscoped Cursor Bugbot selector remains" "$NAME_LINES" "$SCOPED_LINES"

echo
echo "== summary: $PASS passed, $FAIL failed =="
[[ "$FAIL" -eq 0 ]] || exit 1
echo "OK: escalate-review.sh tests passed"
