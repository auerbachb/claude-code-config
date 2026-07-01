#!/usr/bin/env bash
# Offline unit tests for pr-preflight.sh (issue #493 — shared PR pre-flight).
# Stubs `gh` (PR view / endpoint scans / pr ready / pr comment) and
# cr-review-hourly.sh so nothing touches the network or real ~/.claude.
# Requires jq. Run from repo root: bash .claude/scripts/tests/pr-preflight.test.sh
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/.claude/scripts/pr-preflight.sh"

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

# ---- stub gh ----------------------------------------------------------------
# Behavior is driven by fixture files + env written before each run.
STUB_BIN="$TMP/bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/gh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
LOG="${GH_ACTIONS_LOG:-/dev/null}"
sub="$1"; shift || true
case "$sub" in
  pr)
    action="$1"; shift || true
    case "$action" in
      view)
        cat "$GH_PR_VIEW_JSON"
        ;;
      ready)
        echo "READY $1" >>"$LOG"
        exit "${GH_READY_RC:-0}"
        ;;
      comment)
        pr="$1"; shift
        body=""
        while [[ $# -gt 0 ]]; do
          case "$1" in
            --body) body="$2"; shift 2 ;;
            *) shift ;;
          esac
        done
        echo "COMMENT $pr :: $body" >>"$LOG"
        exit "${GH_COMMENT_RC:-0}"
        ;;
    esac
    ;;
  api)
    # gh api user --jq .login  OR  gh api --paginate <endpoint> --jq <filter>
    endpoint=""; filter=""; is_user=0
    while [[ $# -gt 0 ]]; do
      case "$1" in
        user) is_user=1; shift ;;
        --jq) filter="$2"; shift 2 ;;
        --paginate) shift ;;
        repos/*) endpoint="$1"; shift ;;
        *) shift ;;
      esac
    done
    if [[ "$is_user" -eq 1 ]]; then
      echo "${GH_USER:-}"
      exit 0
    fi
    fixture=""
    case "$endpoint" in
      *"/pulls/"*"/reviews"*)  fixture="$FIX_REVIEWS" ;;
      *"/pulls/"*"/comments"*) fixture="$FIX_PULL_COMMENTS" ;;
      *"/issues/"*"/comments"*) fixture="$FIX_ISSUE_COMMENTS" ;;
    esac
    if [[ -z "$fixture" || ! -f "$fixture" ]]; then echo "[]" >/dev/null; exit 0; fi
    jq -r "$filter" "$fixture"
    exit 0
    ;;
esac
exit 0
STUB
chmod +x "$STUB_BIN/gh"

# ---- stub cr-review-hourly.sh ----------------------------------------------
CR_STUB="$TMP/cr-review-hourly.sh"
cat > "$CR_STUB" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  --check) exit "${CR_CHECK_RC:-0}" ;;
  --peek-explicit) exit "${CR_PEEK_RC:-0}" ;;
  --record-explicit) exit "${CR_RECORD_RC:-0}" ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$CR_STUB"
export PREFLIGHT_CR_HOURLY_SH="$CR_STUB"

export PATH="$STUB_BIN:$PATH"

# ---- fixture writers --------------------------------------------------------
write_view() { printf '%s' "$1" > "$TMP/view.json"; export GH_PR_VIEW_JSON="$TMP/view.json"; }
write_reviews() { printf '%s' "$1" > "$TMP/reviews.json"; export FIX_REVIEWS="$TMP/reviews.json"; }
write_pull_comments() { printf '%s' "$1" > "$TMP/pull_comments.json"; export FIX_PULL_COMMENTS="$TMP/pull_comments.json"; }
write_issue_comments() { printf '%s' "$1" > "$TMP/issue_comments.json"; export FIX_ISSUE_COMMENTS="$TMP/issue_comments.json"; }

run_json() {
  export GH_ACTIONS_LOG="$TMP/actions.log"
  : > "$GH_ACTIONS_LOG"
  ( cd "$REPO_ROOT" && bash "$SCRIPT" "$@" --json )
}
actions() { cat "$TMP/actions.log" 2>/dev/null; }

EMPTY='[]'

############################################################################
echo "== Scenario 1: draft + author is me + all 4 reviewers absent =="
export GH_USER="me"
unset CR_CHECK_RC CR_RECORD_RC GH_READY_RC GH_COMMENT_RC
write_view '{"isDraft":true,"author":{"login":"me"},"state":"OPEN"}'
write_reviews "$EMPTY"; write_pull_comments "$EMPTY"; write_issue_comments "$EMPTY"
OUT=$(run_json 493); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "draft_action marked-ready" "marked-ready" "$(jq -r '.draft_action' <<<"$OUT")"
check_eq "actions=5" "5" "$(jq -r '.actions' <<<"$OUT")"
check_eq "clean=false" "false" "$(jq -r '.clean' <<<"$OUT")"
check_eq "codeant triggered" "triggered" "$(jq -r '.reviewers.codeant.status' <<<"$OUT")"
check_eq "coderabbit triggered" "triggered" "$(jq -r '.reviewers.coderabbit.status' <<<"$OUT")"
check_eq "cursor triggered" "triggered" "$(jq -r '.reviewers.cursor.status' <<<"$OUT")"
check_eq "graphite triggered" "triggered" "$(jq -r '.reviewers.graphite.status' <<<"$OUT")"
check_eq "ready was called" "1" "$(actions | grep -c '^READY 493$')"
check_eq "4 comments posted" "4" "$(actions | grep -c '^COMMENT 493 ::')"
check_eq "cr trigger literal" "1" "$(actions | grep -cF 'COMMENT 493 :: @coderabbitai full review')"
check_eq "no greptile trigger" "0" "$(actions | grep -ciF 'greptile')"

############################################################################
echo "== Scenario 2: ready + all 4 engaged → clean no-op =="
write_view '{"isDraft":false,"author":{"login":"me"},"state":"OPEN"}'
write_reviews '[{"user":{"login":"coderabbitai[bot]"},"body":"review"},{"user":{"login":"codeant-ai[bot]"},"body":"x"}]'
write_pull_comments '[{"user":{"login":"cursor[bot]"},"body":"y"}]'
write_issue_comments '[{"user":{"login":"graphite-app[bot]"},"body":"z"}]'
OUT=$(run_json 493); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "draft_action not-draft" "not-draft" "$(jq -r '.draft_action' <<<"$OUT")"
check_eq "actions=0" "0" "$(jq -r '.actions' <<<"$OUT")"
check_eq "clean=true" "true" "$(jq -r '.clean' <<<"$OUT")"
check_eq "all already-present" "already-present already-present already-present already-present" \
  "$(jq -r '[.reviewers[].status] | join(" ")' <<<"$OUT")"
check_eq "no comments posted" "0" "$(actions | grep -c '^COMMENT')"
check_eq "no ready called" "0" "$(actions | grep -c '^READY')"

############################################################################
echo "== Scenario 3: draft + NOT author → skip ready, still trigger reviewers =="
export GH_USER="me"
write_view '{"isDraft":true,"author":{"login":"someone-else"},"state":"OPEN"}'
write_reviews "$EMPTY"; write_pull_comments "$EMPTY"; write_issue_comments "$EMPTY"
OUT=$(run_json 493); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "draft_action skipped-not-author" "skipped-not-author" "$(jq -r '.draft_action' <<<"$OUT")"
check_eq "no ready called" "0" "$(actions | grep -c '^READY')"
check_eq "4 reviewers triggered" "4" "$(actions | grep -c '^COMMENT')"
check_eq "clean=false" "false" "$(jq -r '.clean' <<<"$OUT")"

############################################################################
echo "== Scenario 4: CR rate cap exhausted (--check fails) → skip CR, post other 3 =="
write_view '{"isDraft":false,"author":{"login":"me"},"state":"OPEN"}'
write_reviews "$EMPTY"; write_pull_comments "$EMPTY"; write_issue_comments "$EMPTY"
CR_CHECK_RC=1 OUT=$(CR_CHECK_RC=1 run_json 493); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "coderabbit skipped-rate-cap" "skipped-rate-cap" "$(jq -r '.reviewers.coderabbit.status' <<<"$OUT")"
check_eq "codeant triggered" "triggered" "$(jq -r '.reviewers.codeant.status' <<<"$OUT")"
check_eq "cursor triggered" "triggered" "$(jq -r '.reviewers.cursor.status' <<<"$OUT")"
check_eq "graphite triggered" "triggered" "$(jq -r '.reviewers.graphite.status' <<<"$OUT")"
check_eq "no CR trigger posted" "0" "$(actions | grep -cF '@coderabbitai full review')"
check_eq "3 comments posted" "3" "$(actions | grep -c '^COMMENT')"

############################################################################
echo "== Scenario 4b: CR per-PR cap (--peek-explicit fails) → skip CR only =="
write_view '{"isDraft":false,"author":{"login":"me"},"state":"OPEN"}'
write_reviews "$EMPTY"; write_pull_comments "$EMPTY"; write_issue_comments "$EMPTY"
OUT=$(CR_PEEK_RC=1 run_json 493); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "coderabbit skipped-rate-cap" "skipped-rate-cap" "$(jq -r '.reviewers.coderabbit.status' <<<"$OUT")"
check_eq "no CR trigger posted" "0" "$(actions | grep -cF '@coderabbitai full review')"
check_eq "3 comments posted" "3" "$(actions | grep -c '^COMMENT')"

############################################################################
echo "== Scenario 5: 3 engaged, 1 missing → trigger only the missing one =="
write_view '{"isDraft":false,"author":{"login":"me"},"state":"OPEN"}'
write_reviews '[{"user":{"login":"coderabbitai[bot]"},"body":"r"},{"user":{"login":"codeant-ai[bot]"},"body":"r"}]'
write_pull_comments '[{"user":{"login":"cursor[bot]"},"body":"c"}]'
write_issue_comments "$EMPTY"
OUT=$(run_json 493); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "graphite triggered" "triggered" "$(jq -r '.reviewers.graphite.status' <<<"$OUT")"
check_eq "codeant present" "already-present" "$(jq -r '.reviewers.codeant.status' <<<"$OUT")"
check_eq "coderabbit present" "already-present" "$(jq -r '.reviewers.coderabbit.status' <<<"$OUT")"
check_eq "cursor present" "already-present" "$(jq -r '.reviewers.cursor.status' <<<"$OUT")"
check_eq "only 1 comment posted" "1" "$(actions | grep -c '^COMMENT')"
check_eq "the comment is graphite" "1" "$(actions | grep -cF '@graphite-app re-review')"

############################################################################
echo "== Scenario 6: prior @coderabbitai full review trigger, CR not yet responded =="
write_view '{"isDraft":false,"author":{"login":"me"},"state":"OPEN"}'
write_reviews "$EMPTY"; write_pull_comments "$EMPTY"
write_issue_comments '[{"user":{"login":"me"},"body":"@coderabbitai full review"},{"user":{"login":"codeant-ai[bot]"},"body":"x"},{"user":{"login":"cursor[bot]"},"body":"y"},{"user":{"login":"graphite-app[bot]"},"body":"z"}]'
OUT=$(run_json 493); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "coderabbit already-present (idempotent)" "already-present" "$(jq -r '.reviewers.coderabbit.status' <<<"$OUT")"
check_eq "clean=true" "true" "$(jq -r '.clean' <<<"$OUT")"
check_eq "no comments posted" "0" "$(actions | grep -c '^COMMENT')"

############################################################################
echo "== Scenario 7: Greptile present → ignored, not triggered, not flagged =="
write_view '{"isDraft":false,"author":{"login":"me"},"state":"OPEN"}'
write_reviews '[{"user":{"login":"greptile-apps[bot]"},"body":"g"},{"user":{"login":"coderabbitai[bot]"},"body":"r"},{"user":{"login":"codeant-ai[bot]"},"body":"r"},{"user":{"login":"cursor[bot]"},"body":"c"},{"user":{"login":"graphite-app[bot]"},"body":"gp"}]'
write_pull_comments "$EMPTY"; write_issue_comments "$EMPTY"
OUT=$(run_json 493); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "clean=true" "true" "$(jq -r '.clean' <<<"$OUT")"
check_eq "no greptile in reviewers object" "null" "$(jq -r '.reviewers.greptile // "null"' <<<"$OUT")"
check_eq "no comments posted (no greptile trigger)" "0" "$(actions | grep -c '^COMMENT')"

############################################################################
echo "== Scenario 8: dry-run posts nothing =="
write_view '{"isDraft":true,"author":{"login":"me"},"state":"OPEN"}'
write_reviews "$EMPTY"; write_pull_comments "$EMPTY"; write_issue_comments "$EMPTY"
OUT=$(run_json 493 --dry-run); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "draft_action marked-ready (would)" "marked-ready" "$(jq -r '.draft_action' <<<"$OUT")"
check_eq "reviewers dry-run-would-trigger" "dry-run-would-trigger" "$(jq -r '.reviewers.cursor.status' <<<"$OUT")"
check_eq "no real ready" "0" "$(actions | grep -c '^READY')"
check_eq "no real comments" "0" "$(actions | grep -c '^COMMENT')"

############################################################################
echo "== Scenario 9: usage + not-found =="
( cd "$REPO_ROOT" && bash "$SCRIPT" >/dev/null 2>&1 ); check_eq "missing PR → exit 2" 2 "$?"
( cd "$REPO_ROOT" && bash "$SCRIPT" abc >/dev/null 2>&1 ); check_eq "non-numeric PR → exit 2" 2 "$?"
# Closed PR → exit 3
write_view '{"isDraft":false,"author":{"login":"me"},"state":"CLOSED"}'
( cd "$REPO_ROOT" && bash "$SCRIPT" 493 >/dev/null 2>&1 ); check_eq "closed PR → exit 3" 3 "$?"

############################################################################
echo "== Scenario 10: default mode surfaces a clean line + PREFLIGHT_SUMMARY =="
export GH_ACTIONS_LOG="$TMP/actions.log"; : > "$GH_ACTIONS_LOG"
write_view '{"isDraft":false,"author":{"login":"me"},"state":"OPEN"}'
write_reviews '[{"user":{"login":"coderabbitai[bot]"},"body":"r"},{"user":{"login":"codeant-ai[bot]"},"body":"r"},{"user":{"login":"cursor[bot]"},"body":"c"},{"user":{"login":"graphite-app[bot]"},"body":"g"}]'
write_pull_comments "$EMPTY"; write_issue_comments "$EMPTY"
DEF_OUT=$( cd "$REPO_ROOT" && bash "$SCRIPT" 493 )
check_eq "clean line surfaced" "1" "$(grep -c 'Pre-flight clean — proceeding' <<<"$DEF_OUT")"
check_eq "summary line present" "1" "$(grep -c '^PREFLIGHT_SUMMARY: ' <<<"$DEF_OUT")"
SUM_JSON=$(sed -n 's/^PREFLIGHT_SUMMARY: //p' <<<"$DEF_OUT")
check_eq "summary parses, clean=true" "true" "$(jq -r '.clean' <<<"$SUM_JSON")"

echo
echo "== summary: $PASS passed, $FAIL failed =="
[[ "$FAIL" -eq 0 ]] || exit 1
echo "OK: pr-preflight.sh tests passed"
