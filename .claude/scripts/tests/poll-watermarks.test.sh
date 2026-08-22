#!/usr/bin/env bash
# Offline unit tests for poll-watermarks.sh (issue #741).
#
# Stubs pr-state.sh to return deterministic comment bundles and uses the real
# session-state.sh against a temp HOME. Run from repo root:
#   bash .claude/scripts/tests/poll-watermarks.test.sh
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

STUB_DIR="$TMP/scripts"
mkdir -p "$STUB_DIR/lib"
cp "$REPO_ROOT/.claude/scripts/poll-watermarks.sh" "$STUB_DIR/poll-watermarks.sh"
cp "$REPO_ROOT/.claude/scripts/session-state.sh" "$STUB_DIR/session-state.sh"
cp "$REPO_ROOT/.claude/scripts/state-lock.sh" "$STUB_DIR/state-lock.sh"
cp "$REPO_ROOT/.claude/scripts/lib/repo-normalizer.sh" "$STUB_DIR/lib/repo-normalizer.sh"
cp "$REPO_ROOT/.claude/scripts/lib/pr-state-classify.jq" "$STUB_DIR/lib/pr-state-classify.jq"
chmod +x "$STUB_DIR/poll-watermarks.sh" "$STUB_DIR/session-state.sh"

PR=741
STATE_JSON="$TMP/pr-state.json"

cat > "$STUB_DIR/pr-state.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "${PR_STATE_FIXTURE_FILE:?PR_STATE_FIXTURE_FILE not set}"
STUB
chmod +x "$STUB_DIR/pr-state.sh"

POLL_WM="$STUB_DIR/poll-watermarks.sh"
SESSION="$STUB_DIR/session-state.sh"

write_fixture() {
  printf '%s' "$1" > "$STATE_JSON"
  export PR_STATE_FIXTURE_FILE="$STATE_JSON"
}

seed_state() {
  jq -n \
    --argjson pr "$PR" \
    --argjson wm "${1:-null}" \
    '{
      schema_version: 2,
      repos: {
        "auerbachb/claude-code-config": {
          prs: {
            ($pr|tostring): (
              if $wm == null then {phase: "B", head_sha: "abc1234"}
              else {phase: "B", head_sha: "abc1234", poll_watermarks: $wm}
              end
            )
          }
        }
      }
    }' > "$HOME/.claude/session-state.json"
}

base_fixture() {
  jq -n '{
    comments: {
      reviews: [],
      inline: [],
      conversation: []
    }
  }'
}

echo "== Scenario 1: --init snapshots max IDs from all three endpoints =="
write_fixture "$(jq -n '{
  comments: {
    reviews: [{id: 100, user: {login: "coderabbitai[bot]"}, body: "minor issue"}],
    inline: [{id: 200, user: {login: "cursor[bot]"}, body: "critical bug"}],
    conversation: [{id: 50, user: {login: "octocat"}, body: "human"}]
  }
}')"
seed_state null
OUT="$(cd "$REPO_ROOT" && "$POLL_WM" "$PR" --init)"
check_eq "init returns review max" "100" "$(jq -r '.last_review_id' <<<"$OUT")"
check_eq "init returns inline max" "200" "$(jq -r '.last_inline_comment_id' <<<"$OUT")"
check_eq "init returns issue max" "50" "$(jq -r '.last_issue_comment_id' <<<"$OUT")"
STORED="$(cd "$REPO_ROOT" && "$SESSION" --get ".prs[\"$PR\"].poll_watermarks")"
check_eq "init persisted inline watermark" "200" "$(jq -r '.last_inline_comment_id' <<<"$STORED")"

echo "== Scenario 2: --check clean when watermarks current =="
write_fixture "$(jq -n '{
  comments: {
    reviews: [{id: 100, user: {login: "coderabbitai[bot]"}, body: "minor issue"}],
    inline: [{id: 200, user: {login: "cursor[bot]"}, body: "critical bug"}],
    conversation: [{id: 50, user: {login: "octocat"}, body: "human"}]
  }
}')"
seed_state '{"last_review_id":100,"last_inline_comment_id":200,"last_issue_comment_id":50}'
OUT="$(cd "$REPO_ROOT" && "$POLL_WM" "$PR" --check)"
check_eq "no new findings when watermarks match" "NEW_FINDINGS=0" "$(sed -n '1p' <<<"$OUT")"
check_eq "no new inline findings" "NEW_INLINE_FINDINGS=0" "$(sed -n '3p' <<<"$OUT")"

echo "== Scenario 3: --check detects new inline finding (issue #741 gap) =="
write_fixture "$(jq -n '{
  comments: {
    reviews: [{id: 100, user: {login: "coderabbitai[bot]"}, body: "minor issue"}],
    inline: [
      {id: 200, user: {login: "cursor[bot]"}, body: "critical bug"},
      {id: 201, user: {login: "coderabbitai[bot]"}, body: "Prompt for AI Agent: fix null deref"}
    ],
    conversation: [{id: 50, user: {login: "octocat"}, body: "human"}]
  }
}')"
seed_state '{"last_review_id":100,"last_inline_comment_id":200,"last_issue_comment_id":50}'
OUT="$(cd "$REPO_ROOT" && "$POLL_WM" "$PR" --check)"
check_eq "new inline finding trips trigger" "NEW_FINDINGS=1" "$(sed -n '1p' <<<"$OUT")"
check_eq "inline flag set" "NEW_INLINE_FINDINGS=1" "$(sed -n '3p' <<<"$OUT")"
check_eq "review flag clear" "NEW_REVIEW_FINDINGS=0" "$(sed -n '2p' <<<"$OUT")"
STORED_AFTER="$(cd "$REPO_ROOT" && "$SESSION" --get ".prs[\"$PR\"].poll_watermarks")"
check_eq "watermark not advanced on new findings" "200" "$(jq -r '.last_inline_comment_id' <<<"$STORED_AFTER")"

echo "== Scenario 4: inline-only bot finding without review/summary still detected =="
write_fixture "$(jq -n '{
  comments: {
    reviews: [],
    inline: [{id: 301, user: {login: "greptile-apps[bot]"}, body: "major: off-by-one"}],
    conversation: []
  }
}')"
seed_state '{"last_review_id":0,"last_inline_comment_id":0,"last_issue_comment_id":0}'
OUT="$(cd "$REPO_ROOT" && "$POLL_WM" "$PR" --check)"
check_eq "inline-only finding detected" "NEW_FINDINGS=1" "$(sed -n '1p' <<<"$OUT")"
check_eq "inline-only inline flag" "NEW_INLINE_FINDINGS=1" "$(sed -n '3p' <<<"$OUT")"

echo "== Scenario 4b: canonical Greptile clean summary is not a finding =="
write_fixture "$(jq -n '{
  comments: {
    reviews: [],
    inline: [],
    conversation: [{id: 401, user: {login: "greptile-apps[bot]"}, body: "<h3>Greptile Summary</h3> No issues found."}]
  }
}')"
seed_state '{"last_review_id":0,"last_inline_comment_id":0,"last_issue_comment_id":0}'
OUT="$(cd "$REPO_ROOT" && "$POLL_WM" "$PR" --check)"
check_eq "Greptile clean summary is acknowledgment" "NEW_FINDINGS=0" "$(sed -n '1p' <<<"$OUT")"
STORED_AFTER="$(cd "$REPO_ROOT" && "$SESSION" --get ".prs[\"$PR\"].poll_watermarks")"
check_eq "acknowledgment advances issue watermark" "401" "$(jq -r '.last_issue_comment_id' <<<"$STORED_AFTER")"

echo "== Scenario 5: --reset re-baselines after fixpr push =="
write_fixture "$(jq -n '{
  comments: {
    reviews: [{id: 110, user: {login: "coderabbitai[bot]"}, body: "full review triggered"}],
    inline: [{id: 305, user: {login: "cursor[bot]"}, body: "found no new issues"}],
    conversation: []
  }
}')"
seed_state '{"last_review_id":100,"last_inline_comment_id":200,"last_issue_comment_id":50}'
OUT="$(cd "$REPO_ROOT" && "$POLL_WM" "$PR" --reset)"
check_eq "reset advances inline watermark" "305" "$(jq -r '.last_inline_comment_id' <<<"$OUT")"
OUT2="$(cd "$REPO_ROOT" && "$POLL_WM" "$PR" --check)"
check_eq "clean after reset on ack-only comments" "NEW_FINDINGS=0" "$(sed -n '1p' <<<"$OUT2")"

echo "== Scenario 6: CodeAnt review-status table is NOT a finding (issue #1207) =="
# Reproduces the exact failure mode: poll-watermarks.sh --check reported
# NEW_ISSUE_COMMENT_FINDINGS=1 for a CodeAnt status comment (with the
# codeant-review-status HTML marker) when the merge gate was simultaneously met.
# Only new comment has the CodeAnt status marker — must NOT trigger /fixpr.
write_fixture "$(jq -n '{
  comments: {
    reviews: [],
    inline: [],
    conversation: [{
      id: 600,
      user: {login: "codeant-ai[bot]"},
      body: "✅ Reviewed your PR | 8646511 | 18:36 | 18:36\n<!-- codeant-review-status:[{\"label\":\"Reviewed your PR\",\"commit\":\"8646511abc\",\"done\":true}] -->"
    }]
  }
}')"
seed_state '{"last_review_id":0,"last_inline_comment_id":0,"last_issue_comment_id":0}'
OUT="$(cd "$REPO_ROOT" && "$POLL_WM" "$PR" --check)"
check_eq "CodeAnt review-status table is not a finding" "NEW_FINDINGS=0" "$(sed -n '1p' <<<"$OUT")"
check_eq "NEW_ISSUE_COMMENT_FINDINGS=0 for CodeAnt status" "NEW_ISSUE_COMMENT_FINDINGS=0" "$(sed -n '4p' <<<"$OUT")"
STORED_AFTER="$(cd "$REPO_ROOT" && "$SESSION" --get ".prs[\"$PR\"].poll_watermarks")"
check_eq "watermark advanced past CodeAnt status comment" "600" "$(jq -r '.last_issue_comment_id' <<<"$STORED_AFTER")"

echo "== Scenario 6b: real CodeAnt finding without marker stays a finding =="
# Verifies the fix did not over-classify: genuine CodeAnt findings (severity badge,
# no codeant-review-status marker) still produce NEW_FINDINGS=1.
write_fixture "$(jq -n '{
  comments: {
    reviews: [],
    inline: [],
    conversation: [{
      id: 601,
      user: {login: "codeant-ai[bot]"},
      body: "🔴 Critical: the input is not validated before calling exec()."
    }]
  }
}')"
seed_state '{"last_review_id":0,"last_inline_comment_id":0,"last_issue_comment_id":0}'
OUT="$(cd "$REPO_ROOT" && "$POLL_WM" "$PR" --check)"
check_eq "real CodeAnt finding (severity badge) still triggers" "NEW_FINDINGS=1" "$(sed -n '1p' <<<"$OUT")"
check_eq "NEW_ISSUE_COMMENT_FINDINGS=1 for real finding" "NEW_ISSUE_COMMENT_FINDINGS=1" "$(sed -n '4p' <<<"$OUT")"

echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
