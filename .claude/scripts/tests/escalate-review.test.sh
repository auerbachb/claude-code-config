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

write_commits() {
  local push_ts="$1"
  cat > "$TMP/commits.json" <<EOF
[{"sha": "$HEAD_SHA", "commit": {"committer": {"date": "$push_ts"}, "author": {"date": "$push_ts"}}}]
EOF
  export FIXTURE_COMMITS_JSON="$TMP/commits.json"
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

BUGBOT_CHECK_RUN_OK='{"id": 2, "name": "Cursor Bugbot", "status": "completed", "conclusion": "neutral", "title": ""}'
BUGBOT_CHECK_RUN_FAILED_TITLE='{"id": 2, "name": "Cursor Bugbot", "status": "completed", "conclusion": "neutral", "title": "Bugbot couldn'"'"'t run - usage limit reached"}'
BUGBOT_CHECK_RUN_TIMED_OUT='{"id": 2, "name": "Cursor Bugbot", "status": "completed", "conclusion": "timed_out", "title": ""}'

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

echo
echo "== summary: $PASS passed, $FAIL failed =="
[[ "$FAIL" -eq 0 ]] || exit 1
echo "OK: escalate-review.sh tests passed"
