#!/usr/bin/env bash
# Shared offline fixture, GitHub stub, and assertion harness for the
# concern-based escalate-review.sh test suites. This file intentionally does
# not end in .test.sh, so run-hook-tests.sh will not execute it directly.

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

seed_bugbot_absent() {
  local has_key
  ( cd "$REPO_ROOT" && "$STUB_DIR/session-state.sh" \
      --set ".prs[\"$PR_NUM\"].reviewer=cr" >/dev/null )
  has_key="$( cd "$REPO_ROOT" && "$STUB_DIR/session-state.sh" \
      --get ".prs[\"$PR_NUM\"] | has(\"bugbot_installed\")" 2>/dev/null )"
  check_eq "bugbot_installed key absent on existing PR state" "false" "$has_key"
}

read_bugbot_installed() {
  ( cd "$REPO_ROOT" && "$STUB_DIR/session-state.sh" \
      --get ".prs[\"$PR_NUM\"].bugbot_installed" 2>/dev/null )
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
# These globals are consumed by the sourcing concern suites. Referencing them
# here keeps standalone static analysis honest without exporting fixture JSON
# into the stubbed child-process environment.
: "$BUGBOT_CHECK_RUN_OK" "$BUGBOT_CHECK_RUN_FAILED_TITLE"
: "$BUGBOT_CHECK_RUN_TIMED_OUT" "$BUGBOT_CHECK_RUN_SUCCESS"
: "$BUGBOT_CHECK_RUN_IN_PROGRESS" "$BUGBOT_RUN_FOREIGN_IN_PROGRESS"
: "$BUGBOT_RUN_NO_APP_IN_PROGRESS" "$BUGBOT_RUN_FOREIGN_OK"
: "$BUGBOT_RUN_NO_APP_OK" "$BUGBOT_RUN_FOREIGN_FAILED_TITLE"

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

ESCALATE_SRC="$REPO_ROOT/.claude/scripts/escalate-review.sh"
: "$ESCALATE_SRC"

finish_escalate_review_tests() {
  local suite="$1"
  echo
  echo "== summary: $PASS passed, $FAIL failed =="
  [[ "$FAIL" -eq 0 ]] || exit 1
  echo "OK: escalate-review.sh ${suite} tests passed"
}
