#!/usr/bin/env bash
# Offline unit tests for poll-watermarks.sh (issues #741, #1207, #1853).
# catalog: tests — Tests for `poll-watermarks.sh`
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

# Repo scope for the seeded state (issue #1424).
#
# session-state.sh resolves its .repos["<owner>/<repo>"] scope at run time from
# --repo, then $CLAUDE_SESSION_REPO, then the cwd's origin remote. poll-watermarks.sh
# passes no --repo, so an ambient $CLAUDE_SESSION_REPO (any session working out of
# another repo — these scripts are symlinked into ~/.claude and run repo-wide) or a
# checkout whose origin is a fork/rename silently sent the runtime to a different
# scope than the one seeded here. The seeded watermarks became invisible, every
# pre-existing comment re-read as new, and 4 of 21 cases failed. Pinning the scope
# makes the suite hermetic: it no longer depends on the ambient environment or on
# which remote the checkout points at.
SCOPE_REPO="auerbachb/claude-code-config"
export CLAUDE_SESSION_REPO="$SCOPE_REPO"

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
cp "${POLL_WATERMARKS_TEST_SOURCE:-$REPO_ROOT/.claude/scripts/poll-watermarks.sh}" "$STUB_DIR/poll-watermarks.sh"
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
    --arg repo "$SCOPE_REPO" \
    '{
      schema_version: 2,
      repos: {
        ($repo): {
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

echo "== Scenario 0: seeded scope matches the scope session-state.sh resolves (issue #1424) =="
# Guard for the whole suite. Every scenario below seeds watermarks under
# $SCOPE_REPO and then expects poll-watermarks.sh to read them back. That only
# holds while the runtime resolves the same scope. Without this guard a scope
# mismatch surfaces as 4 unrelated-looking assertion failures in scenarios 2
# and 3 rather than as the one thing that actually broke.
seed_state null
check_eq "runtime resolves the seeded repo scope" "$SCOPE_REPO" \
  "$(cd "$REPO_ROOT" && "$SESSION" --session-view 2>/dev/null | jq -r '.repo')"

echo "== Scenario 1: --init snapshots max IDs from all three endpoints =="
write_fixture "$(jq -n '{
  comments: {
    reviews: [{id: 100, user: {login: "coderabbitai[bot]"}, body: "minor issue"}],
    inline: [{id: 200, user: {login: "cursor[bot]"}, body: "critical bug"}],
    conversation: [{id: 50, user: {login: "octocat"}, body: "human"}]
  }
}')"
seed_state null
OUT="$(cd "$REPO_ROOT" && "$BASH" "$POLL_WM" "$PR" --init)"
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
OUT="$(cd "$REPO_ROOT" && "$BASH" "$POLL_WM" "$PR" --check)"
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
OUT="$(cd "$REPO_ROOT" && "$BASH" "$POLL_WM" "$PR" --check)"
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
OUT="$(cd "$REPO_ROOT" && "$BASH" "$POLL_WM" "$PR" --check)"
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
OUT="$(cd "$REPO_ROOT" && "$BASH" "$POLL_WM" "$PR" --check)"
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
OUT="$(cd "$REPO_ROOT" && "$BASH" "$POLL_WM" "$PR" --reset)"
check_eq "reset advances inline watermark" "305" "$(jq -r '.last_inline_comment_id' <<<"$OUT")"
OUT2="$(cd "$REPO_ROOT" && "$BASH" "$POLL_WM" "$PR" --check)"
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
OUT="$(cd "$REPO_ROOT" && "$BASH" "$POLL_WM" "$PR" --check)"
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
OUT="$(cd "$REPO_ROOT" && "$BASH" "$POLL_WM" "$PR" --check)"
check_eq "real CodeAnt finding (severity badge) still triggers" "NEW_FINDINGS=1" "$(sed -n '1p' <<<"$OUT")"
check_eq "NEW_ISSUE_COMMENT_FINDINGS=1 for real finding" "NEW_ISSUE_COMMENT_FINDINGS=1" "$(sed -n '4p' <<<"$OUT")"

echo "== Scenario 6c: CodeAnt Low Risk PR Risk summary is NOT a finding (issue #1853) =="
# Verbatim codeant-ai[bot] comment 6429014706 (auerbachb/still-point PR #821). As the
# only new bot comment it returned NEW_FINDINGS=1 before the classifier rule.
CODEANT_LOW_RISK_BODY='## <a href="https://codeant.ai/" title="CodeAnt AI"><img src="https://new-codeant-butcket.s3.us-west-1.amazonaws.com/badges/codeant-block-purple-v2.svg" width="28" height="28" align="absmiddle" style="vertical-align:middle" alt="CodeAnt" /></a>&nbsp; CodeAnt PR Risk

**🟢&nbsp; Low Risk**

- The PR appears safe to merge; no actionable issues were identified in the review.

**Assessed commit:** `70995d89a579`'
write_fixture "$(jq -n --arg b "$CODEANT_LOW_RISK_BODY" '{
  comments: {
    reviews: [],
    inline: [],
    conversation: [{id: 602, user: {login: "codeant-ai[bot]"}, body: $b}]
  }
}')"
seed_state '{"last_review_id":0,"last_inline_comment_id":0,"last_issue_comment_id":0}'
OUT="$(cd "$REPO_ROOT" && "$BASH" "$POLL_WM" "$PR" --check)"
check_eq "CodeAnt Low Risk summary is not a finding" "NEW_FINDINGS=0" "$(sed -n '1p' <<<"$OUT")"
check_eq "NEW_ISSUE_COMMENT_FINDINGS=0 for CodeAnt Low Risk summary" "NEW_ISSUE_COMMENT_FINDINGS=0" "$(sed -n '4p' <<<"$OUT")"
STORED_AFTER="$(cd "$REPO_ROOT" && "$SESSION" --get ".prs[\"$PR\"].poll_watermarks")"
check_eq "watermark advanced past CodeAnt Low Risk summary" "602" "$(jq -r '.last_issue_comment_id' <<<"$STORED_AFTER")"


echo "== Scenario 7: >1 MiB bundles use files in reset and check (#1557) =="
mkdir -p "$TMP/scratch"
export TMPDIR="$TMP/scratch"
python3 - "$STATE_JSON" <<'LARGE_FIXTURE'
import json,sys
body="Full review triggered " + "x"*(1100*1024) + " END-OF-LARGE-FIXTURE"
def c(n):return {"id":n,"user":{"login":"codeant-ai[bot]"},"body":body}
with open(sys.argv[1],"w") as f:json.dump({"comments":{"reviews":[c(701)],"inline":[c(702)],"conversation":[c(703)]}},f)
LARGE_FIXTURE
export PR_STATE_FIXTURE_FILE="$STATE_JSON"
seed_state '{"last_review_id":0,"last_inline_comment_id":0,"last_issue_comment_id":0}'
RC=0
OUT="$(cd "$REPO_ROOT" && "$BASH" "$POLL_WM" "$PR" --reset 2>"$TMP/large-reset.err")" || RC=$?
check_eq "large reset succeeds" "0" "$RC"
check_eq "large reset records all endpoint maxima" "701:702:703:reset" "$(jq -r '[.last_review_id,.last_inline_comment_id,.last_issue_comment_id,.mode]|map(tostring)|join(":")' <<<"$OUT")"
seed_state '{"last_review_id":0,"last_inline_comment_id":0,"last_issue_comment_id":0}'
RC=0
OUT="$(cd "$REPO_ROOT" && "$BASH" "$POLL_WM" "$PR" --check 2>"$TMP/large-check.err")" || RC=$?
check_eq "large acknowledgment check succeeds" "0" "$RC"
check_eq "large acknowledgments are not findings" "NEW_FINDINGS=0" "$(sed -n '1p' <<<"$OUT")"
STORED_AFTER="$(cd "$REPO_ROOT" && "$SESSION" --get ".prs[\"$PR\"].poll_watermarks")"
check_eq "large acknowledgments advance all watermarks" "701:702:703" "$(jq -r '[.last_review_id,.last_inline_comment_id,.last_issue_comment_id]|map(tostring)|join(":")' <<<"$STORED_AFTER")"
python3 - "$STATE_JSON" <<'LARGE_FINDING'
import json,sys
p=sys.argv[1]
with open(p) as f:d=json.load(f)
d['comments']['conversation'][0]['body']='Potential issue: '+ 'x'*(1100*1024)+' FINDING-TAIL'
with open(p,'w') as f:json.dump(d,f)
LARGE_FINDING
seed_state '{"last_review_id":0,"last_inline_comment_id":0,"last_issue_comment_id":0}'
cp "$HOME/.claude/session-state.json" "$TMP/before-large-finding.json"
RC=0
OUT="$(cd "$REPO_ROOT" && "$BASH" "$POLL_WM" "$PR" --check 2>"$TMP/large-finding.err")" || RC=$?
check_eq "large finding check succeeds" "0" "$RC"
check_eq "large finding remains actionable" "NEW_FINDINGS=1" "$(sed -n '1p' <<<"$OUT")"
check_eq "large finding names conversation endpoint" "NEW_ISSUE_COMMENT_FINDINGS=1" "$(sed -n '4p' <<<"$OUT")"
SAME=no
cmp -s "$TMP/before-large-finding.json" "$HOME/.claude/session-state.json" && SAME=yes
check_eq "finding leaves the actual stored state byte-identical" "yes" "$SAME"
LEFT=no
compgen -G "$TMP/scratch/poll-watermarks.*" >/dev/null && LEFT=yes
check_eq "successful large runs clean private scratch" "no" "$LEFT"

echo "== Scenario 8: invalid snapshots fail closed before any watermark write =="
for invalid in empty malformed array boolean comments-boolean endpoint-boolean unsafe-id missing; do
  case "$invalid" in
    empty) : > "$STATE_JSON" ;;
    malformed) printf '{' > "$STATE_JSON" ;;
    array) printf '[]' > "$STATE_JSON" ;;
    boolean) printf 'false' > "$STATE_JSON" ;;
    comments-boolean) printf '{"comments":false}' > "$STATE_JSON" ;;
    endpoint-boolean) printf '{"comments":{"reviews":false}}' > "$STATE_JSON" ;;
    unsafe-id) printf '{"comments":{"reviews":[{"id":"unbounded-string-id"}]}}' > "$STATE_JSON" ;;
    missing) rm -f "$STATE_JSON" ;;
  esac
  for mode in --reset --check --init; do
    seed_state '{"last_review_id":81,"last_inline_comment_id":82,"last_issue_comment_id":83}'
    cp "$HOME/.claude/session-state.json" "$TMP/before-invalid.json"
    RC=0
    OUT="$(cd "$REPO_ROOT" && "$BASH" "$POLL_WM" "$PR" "$mode" 2>"$TMP/invalid.err")" || RC=$?
    check_eq "$invalid/$mode refuses with documented state error" "4" "$RC"
    check_eq "$invalid/$mode never emits a clean finding result" "" "$OUT"
    SAME=no
    cmp -s "$TMP/before-invalid.json" "$HOME/.claude/session-state.json" && SAME=yes
    check_eq "$invalid/$mode preserves actual state bytes" "yes" "$SAME"
  done
done
write_fixture '{"comments":{"reviews":[],"inline":[],"conversation":[]}}'
printf 'not valid jq !!!' > "$STUB_DIR/lib/pr-state-classify.jq"
seed_state '{"last_review_id":81,"last_inline_comment_id":82,"last_issue_comment_id":83}'
cp "$HOME/.claude/session-state.json" "$TMP/before-classifier-failure.json"
RC=0
OUT="$(cd "$REPO_ROOT" && "$BASH" "$POLL_WM" "$PR" --reset 2>"$TMP/classifier-failure.err")" || RC=$?
check_eq "classifier failure maps to exit4" "4" "$RC"
check_eq "classifier failure emits no result" "" "$OUT"
SAME=no
cmp -s "$TMP/before-classifier-failure.json" "$HOME/.claude/session-state.json" && SAME=yes
check_eq "classifier failure leaves actual state byte-identical" "yes" "$SAME"
LEFT=no
compgen -G "$TMP/scratch/poll-watermarks.*" >/dev/null && LEFT=yes
check_eq "failure paths clean private scratch" "no" "$LEFT"


echo "== Scenario 9: stored-state read failure cannot invent a zero baseline =="
cp "$REPO_ROOT/.claude/scripts/lib/pr-state-classify.jq" "$STUB_DIR/lib/pr-state-classify.jq"
mv "$SESSION" "$STUB_DIR/session-state-real.sh"
cat > "$SESSION" <<'FAILED_STATE_READ'
#!/usr/bin/env bash
for arg in "$@"; do
  if [[ "$arg" == --get ]]; then
    printf 'fixture stored-state read failed\n' >&2
    exit 17
  fi
done
exec "$(dirname "$0")/session-state-real.sh" "$@"
FAILED_STATE_READ
chmod +x "$SESSION"
# Preserve a nonzero baseline. A swallowed read failure would reset this to 0.
for mode in --reset --check --init; do
  for root_mode in implicit explicit; do
    cp "$HOME/.claude/session-state.json" "$TMP/before-stored-read.json"
    RC=0
    if [[ "$root_mode" == explicit ]]; then
      OUT="$(cd "$REPO_ROOT" && "$BASH" "$POLL_WM" "$PR" "$mode" --root-repo "$REPO_ROOT" 2>"$TMP/stored-read.err")" || RC=$?
    else
      OUT="$(cd "$REPO_ROOT" && "$BASH" "$POLL_WM" "$PR" "$mode" 2>"$TMP/stored-read.err")" || RC=$?
    fi
    check_eq "stored read failure/$mode/$root_mode returns exit4" "4" "$RC"
    check_eq "stored read failure/$mode/$root_mode emits no result" "" "$OUT"
    SAME=no
    cmp -s "$TMP/before-stored-read.json" "$HOME/.claude/session-state.json" && SAME=yes
    check_eq "stored read failure/$mode/$root_mode preserves state bytes" "yes" "$SAME"
    DIAGNOSTIC=no
    grep -q 'fixture stored-state read failed' "$TMP/stored-read.err" && DIAGNOSTIC=yes
    check_eq "stored read failure/$mode/$root_mode keeps original diagnostic" "yes" "$DIAGNOSTIC"
  done
done
LEFT=no
compgen -G "$TMP/scratch/poll-watermarks.*" >/dev/null && LEFT=yes
check_eq "stored-state read failures clean scratch" "no" "$LEFT"

echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
