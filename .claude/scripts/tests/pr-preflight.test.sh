#!/usr/bin/env bash
# Offline unit tests for pr-preflight.sh (issue #493 — shared PR pre-flight;
# issue #576 — HEAD-SHA reviewer freshness).
# Stubs `gh` (PR view / endpoint scans / commit date / check-runs / pr ready /
# pr comment), cr-review-hourly.sh, and session-state.sh so nothing touches the
# network or real ~/.claude.
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
      # check-runs BEFORE the bare commits match — both start with commits/<sha>.
      *"/commits/"*"/check-runs"*) fixture="${FIX_CHECK_RUNS:-}"; : "${GH_CHECK_RUNS_RC:=0}"
                                   [[ "$GH_CHECK_RUNS_RC" != 0 ]] && exit "$GH_CHECK_RUNS_RC" ;;
      *"/commits/"*)               fixture="${FIX_COMMIT:-}"; : "${GH_COMMIT_RC:=0}"
                                   [[ "$GH_COMMIT_RC" != 0 ]] && exit "$GH_COMMIT_RC" ;;
      *"/issues/"*"/timeline"*)    fixture="${FIX_TIMELINE:-}"; : "${GH_TIMELINE_RC:=0}"
                                   [[ "$GH_TIMELINE_RC" != 0 ]] && exit "$GH_TIMELINE_RC" ;;
      *"/pulls/"*"/reviews"*)  fixture="$FIX_REVIEWS" ;;
      *"/pulls/"*"/comments"*) fixture="$FIX_PULL_COMMENTS" ;;
      *"/issues/"*"/comments"*) fixture="$FIX_ISSUE_COMMENTS" ;;
    esac
    if [[ -z "$fixture" || ! -f "$fixture" ]]; then echo "[]"; exit 0; fi
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

# ---- stub session-state.sh (per-SHA trigger dedupe, issue #576) -------------
# Minimal --get/--set over a JSON file, mirroring the real helper's contract
# closely enough for the dedupe path (jq-path get, JSON-or-bare-string set).
# It resolves the state file the SAME way the real helper does — hardcoded to
# $HOME/.claude/session-state.json (HOME is redirected to a temp dir above).
# Using an env-var override here instead would be a fidelity trap: the real
# session-state.sh ignores such a variable, so the stub would exercise a path
# production never takes.
STATE_STUB="$TMP/session-state.sh"
cat > "$STATE_STUB" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
F="$HOME/.claude/session-state.json"
[[ -f "$F" ]] || echo '{}' > "$F"
case "$1" in
  --get) jq -r "${2} // empty" "$F" 2>/dev/null; exit 0 ;;
  --set)
    shift
    FILTER=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --set) shift ;;
        *)
          path="${1%%=*}"; val="${1#*=}"
          if ! jq -e . >/dev/null 2>&1 <<<"$val"; then val="\"$val\""; fi
          FILTER="${FILTER:+$FILTER | }${path} = ${val}"
          shift ;;
      esac
    done
    jq "$FILTER" "$F" > "$F.tmp" && mv "$F.tmp" "$F"
    exit 0 ;;
esac
exit 0
STUB
chmod +x "$STATE_STUB"

export PATH="$STUB_BIN:$PATH"

# ---- HEAD-SHA constants (issue #576) ---------------------------------------
# HEAD_SHA is what pre-flight judges freshness against; OLD_SHA is a superseded
# commit (the PR #565 rebase scenario). HEAD_DATE is the HEAD commit's committer
# date — the only freshness signal for SHA-less issue comments.
HEAD_SHA="headsha0000000000000000000000000000001"
OLD_SHA="oldsha00000000000000000000000000000002"

# Timestamps are computed RELATIVE TO NOW, never hard-coded. pr-preflight.sh
# compares the HEAD commit date against the wall clock (the future-date
# degradation guard), so absolute fixtures would make this suite time-dependent:
# run it with a clock earlier than the literal, and the script correctly treats
# the commit as future-dated and degrades — failing scenarios whose behavior is
# actually right. Anchoring every fixture to `now` keeps all three in the past
# regardless of when CI runs. (Scenario 18c hard-codes a far-future date on
# purpose — that one is *testing* the future-date guard.)
#
# Portable across GNU (`date -d @epoch`) and BSD/macOS (`date -r epoch`); no
# python/perl dependency added to a bash+jq suite.
iso_from_now() {  # $1 = signed second offset from now
  local target=$(( $(date -u +%s) + $1 ))
  date -u -d "@$target" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -r "$target" +%Y-%m-%dT%H:%M:%SZ
}
HEAD_DATE="$(iso_from_now -3600)"     # HEAD committed 1h ago
BEFORE_HEAD="$(iso_from_now -7200)"   # stale — 2h ago, pre-dates HEAD
AFTER_HEAD="$(iso_from_now -1800)"    # fresh — 30m ago, post-dates HEAD

# ---- fixture writers --------------------------------------------------------
write_view() { printf '%s' "$1" > "$TMP/view.json"; export GH_PR_VIEW_JSON="$TMP/view.json"; }
write_reviews() { printf '%s' "$1" > "$TMP/reviews.json"; export FIX_REVIEWS="$TMP/reviews.json"; }
write_pull_comments() { printf '%s' "$1" > "$TMP/pull_comments.json"; export FIX_PULL_COMMENTS="$TMP/pull_comments.json"; }
write_issue_comments() { printf '%s' "$1" > "$TMP/issue_comments.json"; export FIX_ISSUE_COMMENTS="$TMP/issue_comments.json"; }
write_check_runs() { printf '%s' "$1" > "$TMP/check_runs.json"; export FIX_CHECK_RUNS="$TMP/check_runs.json"; }
write_commit() { printf '%s' "$1" > "$TMP/commit.json"; export FIX_COMMIT="$TMP/commit.json"; }
write_timeline() { printf '%s' "$1" > "$TMP/timeline.json"; export FIX_TIMELINE="$TMP/timeline.json"; }

# Default view/commit/check-runs for the common case: ready PR, HEAD_SHA, known
# HEAD date, no bot check-runs. Scenarios override as needed.
view_ready() { write_view "{\"isDraft\":false,\"author\":{\"login\":\"me\"},\"state\":\"OPEN\",\"headRefOid\":\"$HEAD_SHA\"}"; }
view_draft() { write_view "{\"isDraft\":true,\"author\":{\"login\":\"$1\"},\"state\":\"OPEN\",\"headRefOid\":\"$HEAD_SHA\"}"; }
commit_ok()  { write_commit "{\"commit\":{\"committer\":{\"date\":\"$HEAD_DATE\"}}}"; }
no_checks()  { write_check_runs '{"check_runs":[]}'; }
# No head_ref_force_pushed/head_ref_pushed event — the common case (PR never
# rebased). Forces every scenario that doesn't opt in to a custom timeline
# fixture to exercise the committer-date fallback, unchanged from #576.
no_timeline() { write_timeline '[]'; unset GH_TIMELINE_RC; }

run_json() {
  export GH_ACTIONS_LOG="$TMP/actions.log"
  : > "$GH_ACTIONS_LOG"
  ( cd "$REPO_ROOT" && bash "$SCRIPT" "$@" --json )
}
actions() { cat "$TMP/actions.log" 2>/dev/null; }

EMPTY='[]'

# Dedupe state is opt-in per scenario: default to a fresh file so markers from
# one scenario never leak into the next. This is the same path the real
# session-state.sh would use — HOME is a temp dir for the whole run.
STATE_JSON="$HOME/.claude/session-state.json"
reset_state() { echo '{}' > "$STATE_JSON"; }
# Most scenarios exercise the GitHub-scan path only; point the helper at a
# non-existent path so the dedupe layer is inert unless a scenario enables it.
export PREFLIGHT_SESSION_STATE_SH="$TMP/no-such-session-state.sh"
enable_state_dedupe()  { export PREFLIGHT_SESSION_STATE_SH="$STATE_STUB"; reset_state; }
disable_state_dedupe() { export PREFLIGHT_SESSION_STATE_SH="$TMP/no-such-session-state.sh"; }

# Every scenario starts from a known-good commit/check-runs/timeline baseline.
commit_ok; no_checks; no_timeline

############################################################################
echo "== Scenario 1: draft + author is me + all 4 reviewers absent =="
export GH_USER="me"
unset CR_CHECK_RC CR_RECORD_RC GH_READY_RC GH_COMMENT_RC
view_draft me
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
echo "== Scenario 2: ready + all 4 engaged ON HEAD → clean no-op =="
view_ready
write_reviews "[{\"user\":{\"login\":\"coderabbitai[bot]\"},\"commit_id\":\"$HEAD_SHA\",\"submitted_at\":\"$HEAD_DATE\",\"body\":\"review\"},{\"user\":{\"login\":\"codeant-ai[bot]\"},\"commit_id\":\"$HEAD_SHA\",\"submitted_at\":\"$HEAD_DATE\",\"body\":\"x\"}]"
write_pull_comments "[{\"user\":{\"login\":\"cursor[bot]\"},\"commit_id\":\"$HEAD_SHA\",\"created_at\":\"$HEAD_DATE\",\"body\":\"y\"}]"
write_issue_comments "[{\"user\":{\"login\":\"graphite-app[bot]\"},\"created_at\":\"$AFTER_HEAD\",\"body\":\"z\"}]"
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
view_draft someone-else
write_reviews "$EMPTY"; write_pull_comments "$EMPTY"; write_issue_comments "$EMPTY"
OUT=$(run_json 493); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "draft_action skipped-not-author" "skipped-not-author" "$(jq -r '.draft_action' <<<"$OUT")"
check_eq "no ready called" "0" "$(actions | grep -c '^READY')"
check_eq "4 reviewers triggered" "4" "$(actions | grep -c '^COMMENT')"
check_eq "clean=false" "false" "$(jq -r '.clean' <<<"$OUT")"

############################################################################
echo "== Scenario 4: CR rate cap exhausted (--check fails) → skip CR, post other 3 =="
view_ready
write_reviews "$EMPTY"; write_pull_comments "$EMPTY"; write_issue_comments "$EMPTY"
OUT=$(CR_CHECK_RC=1 run_json 493); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "coderabbit skipped-rate-cap" "skipped-rate-cap" "$(jq -r '.reviewers.coderabbit.status' <<<"$OUT")"
check_eq "codeant triggered" "triggered" "$(jq -r '.reviewers.codeant.status' <<<"$OUT")"
check_eq "cursor triggered" "triggered" "$(jq -r '.reviewers.cursor.status' <<<"$OUT")"
check_eq "graphite triggered" "triggered" "$(jq -r '.reviewers.graphite.status' <<<"$OUT")"
check_eq "no CR trigger posted" "0" "$(actions | grep -cF '@coderabbitai full review')"
check_eq "3 comments posted" "3" "$(actions | grep -c '^COMMENT')"

############################################################################
echo "== Scenario 4b: CR per-PR cap (--peek-explicit fails) → skip CR only =="
view_ready
write_reviews "$EMPTY"; write_pull_comments "$EMPTY"; write_issue_comments "$EMPTY"
OUT=$(CR_PEEK_RC=1 run_json 493); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "coderabbit skipped-rate-cap" "skipped-rate-cap" "$(jq -r '.reviewers.coderabbit.status' <<<"$OUT")"
check_eq "no CR trigger posted" "0" "$(actions | grep -cF '@coderabbitai full review')"
check_eq "3 comments posted" "3" "$(actions | grep -c '^COMMENT')"

############################################################################
echo "== Scenario 4c: dry-run also respects CR per-PR cap (Fix B coverage) =="
view_ready
write_reviews "$EMPTY"; write_pull_comments "$EMPTY"; write_issue_comments "$EMPTY"
OUT=$(CR_PEEK_RC=1 run_json 493 --dry-run); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "dry-run coderabbit skipped-rate-cap when peek-explicit fails" "skipped-rate-cap" "$(jq -r '.reviewers.coderabbit.status' <<<"$OUT")"
check_eq "no real comments in dry-run" "0" "$(actions | grep -c '^COMMENT')"

############################################################################
echo "== Scenario 5: 3 engaged on HEAD, 1 missing → trigger only the missing one =="
view_ready
write_reviews "[{\"user\":{\"login\":\"coderabbitai[bot]\"},\"commit_id\":\"$HEAD_SHA\",\"submitted_at\":\"$HEAD_DATE\",\"body\":\"r\"},{\"user\":{\"login\":\"codeant-ai[bot]\"},\"commit_id\":\"$HEAD_SHA\",\"submitted_at\":\"$HEAD_DATE\",\"body\":\"r\"}]"
write_pull_comments "[{\"user\":{\"login\":\"cursor[bot]\"},\"commit_id\":\"$HEAD_SHA\",\"created_at\":\"$HEAD_DATE\",\"body\":\"c\"}]"
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
echo "== Scenario 6: prior @coderabbitai full review trigger FOR HEAD, CR not yet responded =="
view_ready
write_reviews "$EMPTY"; write_pull_comments "$EMPTY"
write_issue_comments "[{\"user\":{\"login\":\"me\"},\"created_at\":\"$AFTER_HEAD\",\"body\":\"@coderabbitai full review\"},{\"user\":{\"login\":\"codeant-ai[bot]\"},\"created_at\":\"$AFTER_HEAD\",\"body\":\"x\"},{\"user\":{\"login\":\"cursor[bot]\"},\"created_at\":\"$AFTER_HEAD\",\"body\":\"y\"},{\"user\":{\"login\":\"graphite-app[bot]\"},\"created_at\":\"$AFTER_HEAD\",\"body\":\"z\"}]"
OUT=$(run_json 493); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "coderabbit already-present (idempotent)" "already-present" "$(jq -r '.reviewers.coderabbit.status' <<<"$OUT")"
check_eq "clean=true" "true" "$(jq -r '.clean' <<<"$OUT")"
check_eq "no comments posted" "0" "$(actions | grep -c '^COMMENT')"

############################################################################
echo "== Scenario 7: Greptile present → ignored, not triggered, not flagged =="
view_ready
write_reviews "[{\"user\":{\"login\":\"greptile-apps[bot]\"},\"commit_id\":\"$HEAD_SHA\",\"submitted_at\":\"$HEAD_DATE\",\"body\":\"g\"},{\"user\":{\"login\":\"coderabbitai[bot]\"},\"commit_id\":\"$HEAD_SHA\",\"submitted_at\":\"$HEAD_DATE\",\"body\":\"r\"},{\"user\":{\"login\":\"codeant-ai[bot]\"},\"commit_id\":\"$HEAD_SHA\",\"submitted_at\":\"$HEAD_DATE\",\"body\":\"r\"},{\"user\":{\"login\":\"cursor[bot]\"},\"commit_id\":\"$HEAD_SHA\",\"submitted_at\":\"$HEAD_DATE\",\"body\":\"c\"},{\"user\":{\"login\":\"graphite-app[bot]\"},\"commit_id\":\"$HEAD_SHA\",\"submitted_at\":\"$HEAD_DATE\",\"body\":\"gp\"}]"
write_pull_comments "$EMPTY"; write_issue_comments "$EMPTY"
OUT=$(run_json 493); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "clean=true" "true" "$(jq -r '.clean' <<<"$OUT")"
check_eq "no greptile in reviewers object" "null" "$(jq -r '.reviewers.greptile // "null"' <<<"$OUT")"
check_eq "no comments posted (no greptile trigger)" "0" "$(actions | grep -c '^COMMENT')"

############################################################################
echo "== Scenario 8: dry-run posts nothing =="
view_draft me
write_reviews "$EMPTY"; write_pull_comments "$EMPTY"; write_issue_comments "$EMPTY"
OUT=$(run_json 493 --dry-run); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "draft_action would-mark-ready (dry-run)" "would-mark-ready" "$(jq -r '.draft_action' <<<"$OUT")"
check_eq "reviewers dry-run-would-trigger" "dry-run-would-trigger" "$(jq -r '.reviewers.cursor.status' <<<"$OUT")"
check_eq "no real ready" "0" "$(actions | grep -c '^READY')"
check_eq "no real comments" "0" "$(actions | grep -c '^COMMENT')"

############################################################################
echo "== Scenario 9: usage + not-found =="
( cd "$REPO_ROOT" && bash "$SCRIPT" >/dev/null 2>&1 ); check_eq "missing PR → exit 2" 2 "$?"
( cd "$REPO_ROOT" && bash "$SCRIPT" abc >/dev/null 2>&1 ); check_eq "non-numeric PR → exit 2" 2 "$?"
# Closed PR → exit 3
write_view "{\"isDraft\":false,\"author\":{\"login\":\"me\"},\"state\":\"CLOSED\",\"headRefOid\":\"$HEAD_SHA\"}"
( cd "$REPO_ROOT" && bash "$SCRIPT" 493 >/dev/null 2>&1 ); check_eq "closed PR → exit 3" 3 "$?"

############################################################################
echo "== Scenario 10: default mode surfaces a clean line + PREFLIGHT_SUMMARY =="
export GH_ACTIONS_LOG="$TMP/actions.log"; : > "$GH_ACTIONS_LOG"
view_ready
write_reviews "[{\"user\":{\"login\":\"coderabbitai[bot]\"},\"commit_id\":\"$HEAD_SHA\",\"submitted_at\":\"$HEAD_DATE\",\"body\":\"r\"},{\"user\":{\"login\":\"codeant-ai[bot]\"},\"commit_id\":\"$HEAD_SHA\",\"submitted_at\":\"$HEAD_DATE\",\"body\":\"r\"},{\"user\":{\"login\":\"cursor[bot]\"},\"commit_id\":\"$HEAD_SHA\",\"submitted_at\":\"$HEAD_DATE\",\"body\":\"c\"},{\"user\":{\"login\":\"graphite-app[bot]\"},\"commit_id\":\"$HEAD_SHA\",\"submitted_at\":\"$HEAD_DATE\",\"body\":\"g\"}]"
write_pull_comments "$EMPTY"; write_issue_comments "$EMPTY"
DEF_OUT=$( cd "$REPO_ROOT" && bash "$SCRIPT" 493 )
check_eq "clean line surfaced" "1" "$(grep -c 'Pre-flight clean — proceeding' <<<"$DEF_OUT")"
check_eq "summary line present" "1" "$(grep -c '^PREFLIGHT_SUMMARY: ' <<<"$DEF_OUT")"
SUM_JSON=$(sed -n 's/^PREFLIGHT_SUMMARY: //p' <<<"$DEF_OUT")
check_eq "summary parses, clean=true" "true" "$(jq -r '.clean' <<<"$SUM_JSON")"

############################################################################
echo "== Scenario 11: draft + gh api user fails (empty GH_USER) → skipped-auth-unknown =="
export GH_USER=""
view_draft me
write_reviews "$EMPTY"; write_pull_comments "$EMPTY"; write_issue_comments "$EMPTY"
OUT=$(run_json 493); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "draft_action skipped-auth-unknown" "skipped-auth-unknown" "$(jq -r '.draft_action' <<<"$OUT")"
check_eq "no ready called" "0" "$(actions | grep -c '^READY')"
check_eq "4 reviewers triggered" "4" "$(actions | grep -c '^COMMENT')"
check_eq "clean=false" "false" "$(jq -r '.clean' <<<"$OUT")"
export GH_USER="me"  # restore

############################################################################
# Issue #576 — HEAD-SHA reviewer freshness.
############################################################################

echo "== Scenario 12: THE #565 REGRESSION — every reviewer only on an OLD sha =="
# Pre-#576 this returned all four already-present + clean:true while merge-gate
# correctly said "need an APPROVED review on HEAD". Each reviewer must now be
# seen as stale and re-triggered.
export GH_USER="me"
unset CR_CHECK_RC CR_PEEK_RC CR_RECORD_RC GH_COMMENT_RC
view_ready; commit_ok; no_checks
write_reviews "[{\"user\":{\"login\":\"codeant-ai[bot]\"},\"commit_id\":\"$OLD_SHA\",\"submitted_at\":\"$BEFORE_HEAD\",\"state\":\"APPROVED\",\"body\":\"approved on the previous commit\"},{\"user\":{\"login\":\"coderabbitai[bot]\"},\"commit_id\":\"$OLD_SHA\",\"submitted_at\":\"$BEFORE_HEAD\",\"body\":\"r\"}]"
write_pull_comments "[{\"user\":{\"login\":\"cursor[bot]\"},\"commit_id\":\"$OLD_SHA\",\"created_at\":\"$BEFORE_HEAD\",\"body\":\"c\"}]"
write_issue_comments "[{\"user\":{\"login\":\"graphite-app[bot]\"},\"created_at\":\"$BEFORE_HEAD\",\"body\":\"g\"}]"
OUT=$(run_json 565); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "head_sha reported" "$HEAD_SHA" "$(jq -r '.head_sha' <<<"$OUT")"
check_eq "stale codeant NOT already-present" "triggered" "$(jq -r '.reviewers.codeant.status' <<<"$OUT")"
check_eq "stale coderabbit NOT already-present" "triggered" "$(jq -r '.reviewers.coderabbit.status' <<<"$OUT")"
check_eq "stale cursor NOT already-present" "triggered" "$(jq -r '.reviewers.cursor.status' <<<"$OUT")"
check_eq "stale graphite NOT already-present" "triggered" "$(jq -r '.reviewers.graphite.status' <<<"$OUT")"
check_eq "clean=false (pre-#576 said true)" "false" "$(jq -r '.clean' <<<"$OUT")"
check_eq "all 4 re-triggered" "4" "$(actions | grep -c '^COMMENT')"
check_eq "still no greptile" "0" "$(actions | grep -ciF 'greptile')"

############################################################################
echo "== Scenario 12b: GitHub re-points commit_id on stale inline comments =="
# Found by dogfooding the fix on PR #586, NOT by a stub: GitHub updates an inline
# comment's .commit_id to the newest commit it still applies to, so a comment
# written against an OLD sha reports commit_id == HEAD after a force-push. Only
# .original_commit_id records what the reviewer actually reviewed. Keying off
# .commit_id would re-introduce #576 through a different field.
view_ready; commit_ok; no_checks
write_reviews "$EMPTY"
# Exactly the shape observed live: commit_id re-pointed to HEAD, original on OLD.
write_pull_comments "[{\"user\":{\"login\":\"codeant-ai[bot]\"},\"commit_id\":\"$HEAD_SHA\",\"original_commit_id\":\"$OLD_SHA\",\"created_at\":\"$BEFORE_HEAD\",\"body\":\"finding on the old commit\"}]"
write_issue_comments "$EMPTY"
OUT=$(run_json 493); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "re-pointed commit_id does NOT count as engaged on HEAD" "triggered" "$(jq -r '.reviewers.codeant.status' <<<"$OUT")"
check_eq "codeant re-triggered" "1" "$(actions | grep -cF '@codeant-ai review')"

echo "== Scenario 12c: a genuine inline comment ON HEAD still counts =="
# Guard the opposite direction: original_commit_id == HEAD means the reviewer
# really did review HEAD, so it must remain already-present (no re-trigger).
view_ready; commit_ok; no_checks
write_reviews "$EMPTY"
write_pull_comments "[{\"user\":{\"login\":\"codeant-ai[bot]\"},\"commit_id\":\"$HEAD_SHA\",\"original_commit_id\":\"$HEAD_SHA\",\"created_at\":\"$AFTER_HEAD\",\"body\":\"finding on HEAD\"}]"
write_issue_comments "$EMPTY"
OUT=$(run_json 493)
check_eq "inline comment genuinely on HEAD is already-present" "already-present" "$(jq -r '.reviewers.codeant.status' <<<"$OUT")"
check_eq "codeant not re-triggered" "0" "$(actions | grep -cF '@codeant-ai review')"

echo "== Scenario 13: idempotent — reviewers fresh on HEAD stay a clean no-op =="
view_ready; commit_ok; no_checks
write_reviews "[{\"user\":{\"login\":\"codeant-ai[bot]\"},\"commit_id\":\"$HEAD_SHA\",\"submitted_at\":\"$AFTER_HEAD\",\"body\":\"r\"},{\"user\":{\"login\":\"coderabbitai[bot]\"},\"commit_id\":\"$HEAD_SHA\",\"submitted_at\":\"$AFTER_HEAD\",\"body\":\"r\"}]"
write_pull_comments "[{\"user\":{\"login\":\"cursor[bot]\"},\"commit_id\":\"$HEAD_SHA\",\"created_at\":\"$AFTER_HEAD\",\"body\":\"c\"}]"
write_issue_comments "[{\"user\":{\"login\":\"graphite-app[bot]\"},\"created_at\":\"$AFTER_HEAD\",\"body\":\"g\"}]"
OUT=$(run_json 493); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "actions=0" "0" "$(jq -r '.actions' <<<"$OUT")"
check_eq "clean=true" "true" "$(jq -r '.clean' <<<"$OUT")"
check_eq "no comments posted" "0" "$(actions | grep -c '^COMMENT')"
# Run twice: repeated runs on an already-fresh SHA must stay a no-op.
OUT2=$(run_json 493)
check_eq "second run still clean" "true" "$(jq -r '.clean' <<<"$OUT2")"
check_eq "second run posts nothing" "0" "$(actions | grep -c '^COMMENT')"

############################################################################
echo "== Scenario 14: check-run on HEAD alone proves engagement (no review/comment) =="
# Cursor's real signal on this repo: app slug `cursor`, check name "Cursor Bugbot".
view_ready; commit_ok
write_check_runs '{"check_runs":[{"app":{"slug":"cursor"},"name":"Cursor Bugbot","conclusion":"neutral"}]}'
write_reviews "$EMPTY"; write_pull_comments "$EMPTY"; write_issue_comments "$EMPTY"
OUT=$(run_json 493); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "cursor already-present via HEAD check-run" "already-present" "$(jq -r '.reviewers.cursor.status' <<<"$OUT")"
check_eq "cursor not re-triggered" "0" "$(actions | grep -cF '@cursor review')"
check_eq "others still triggered" "3" "$(actions | grep -c '^COMMENT')"
no_checks

############################################################################
echo "== Scenario 14b: re-run check suites on one SHA still prove engagement (#675) =="
# The check-run fetch now reads whole run objects and pipes them through
# check-runs-dedup.sh before pulling app.slug. A reviewer whose check re-ran on
# this SHA (superseded suite 100 + current suite 200) must still read as engaged:
# the dedup keeps the newest suite's run, which carries the same slug.
view_ready; commit_ok
write_check_runs '{"check_runs":[
  {"app":{"slug":"cursor","id":1},"name":"Cursor Bugbot","status":"completed","conclusion":"failure","check_suite":{"id":100}},
  {"app":{"slug":"cursor","id":1},"name":"Cursor Bugbot","status":"completed","conclusion":"neutral","check_suite":{"id":200}}]}'
write_reviews "$EMPTY"; write_pull_comments "$EMPTY"; write_issue_comments "$EMPTY"
OUT=$(run_json 493); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "cursor still already-present after dedup" "already-present" "$(jq -r '.reviewers.cursor.status' <<<"$OUT")"
check_eq "cursor not re-triggered" "0" "$(actions | grep -cF '@cursor review')"
no_checks

############################################################################
echo "== Scenario 14c: same check name from two apps keeps BOTH slugs (#675) =="
# Grouping is per (app, name), so two vendors publishing an identically named
# check never collapse into one another — both reviewers stay recognized.
view_ready; commit_ok
write_check_runs '{"check_runs":[
  {"app":{"slug":"cursor","id":1},"name":"review","status":"completed","conclusion":"success","check_suite":{"id":100}},
  {"app":{"slug":"codeant-ai","id":2},"name":"review","status":"completed","conclusion":"success","check_suite":{"id":200}}]}'
write_reviews "$EMPTY"; write_pull_comments "$EMPTY"; write_issue_comments "$EMPTY"
OUT=$(run_json 493); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "both apps recognized from one check name" "already-present already-present" \
  "$(jq -r '[.reviewers.cursor.status, .reviewers.codeant.status] | join(" ")' <<<"$OUT")"
check_eq "only the 2 reviewers without a check-run are triggered" "2" "$(actions | grep -c '^COMMENT')"
no_checks

############################################################################
echo "== Scenario 15: issue comment BEFORE head date is stale → re-triggered =="
view_ready; commit_ok; no_checks
write_reviews "$EMPTY"; write_pull_comments "$EMPTY"
write_issue_comments "[{\"user\":{\"login\":\"graphite-app[bot]\"},\"created_at\":\"$BEFORE_HEAD\",\"body\":\"stale finding\"}]"
OUT=$(run_json 493); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "graphite triggered (comment pre-dates HEAD)" "triggered" "$(jq -r '.reviewers.graphite.status' <<<"$OUT")"

############################################################################
echo "== Scenario 16: STALE trigger comment must NOT suppress a fresh trigger =="
# A trigger posted before HEAD existed was aimed at the old commit.
view_ready; commit_ok; no_checks
write_reviews "$EMPTY"; write_pull_comments "$EMPTY"
write_issue_comments "[{\"user\":{\"login\":\"me\"},\"created_at\":\"$BEFORE_HEAD\",\"body\":\"@coderabbitai full review\"}]"
OUT=$(run_json 493); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "stale CR trigger → re-triggered" "triggered" "$(jq -r '.reviewers.coderabbit.status' <<<"$OUT")"
check_eq "CR trigger actually posted" "1" "$(actions | grep -cF '@coderabbitai full review')"

echo "== Scenario 16b: prose mention of a trigger still never suppresses =="
view_ready; commit_ok; no_checks
write_reviews "$EMPTY"; write_pull_comments "$EMPTY"
write_issue_comments "[{\"user\":{\"login\":\"me\"},\"created_at\":\"$AFTER_HEAD\",\"body\":\"I ran @coderabbitai full review earlier and it stalled\"}]"
OUT=$(run_json 493)
check_eq "prose mention does not suppress" "triggered" "$(jq -r '.reviewers.coderabbit.status' <<<"$OUT")"

############################################################################
echo "== Scenario 17: stale SHA + CR cap hit → CR still capped, other 3 posted =="
# SHA-freshness must never bypass the <=2/PR/hour CodeRabbit cap.
view_ready; commit_ok; no_checks
write_reviews "[{\"user\":{\"login\":\"coderabbitai[bot]\"},\"commit_id\":\"$OLD_SHA\",\"submitted_at\":\"$BEFORE_HEAD\",\"body\":\"r\"}]"
write_pull_comments "$EMPTY"; write_issue_comments "$EMPTY"
OUT=$(CR_PEEK_RC=1 run_json 493); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "coderabbit skipped-rate-cap (cap NOT bypassed)" "skipped-rate-cap" "$(jq -r '.reviewers.coderabbit.status' <<<"$OUT")"
check_eq "no CR trigger posted" "0" "$(actions | grep -cF '@coderabbitai full review')"
check_eq "other 3 posted" "3" "$(actions | grep -c '^COMMENT')"

############################################################################
echo "== Scenario 18: HEAD commit date unavailable → degrade, no trigger storm =="
# Fail toward silence: SHA-less issue comments count as present.
view_ready; no_checks
write_reviews "$EMPTY"; write_pull_comments "$EMPTY"
write_issue_comments "[{\"user\":{\"login\":\"graphite-app[bot]\"},\"created_at\":\"$BEFORE_HEAD\",\"body\":\"g\"},{\"user\":{\"login\":\"codeant-ai[bot]\"},\"created_at\":\"$BEFORE_HEAD\",\"body\":\"x\"},{\"user\":{\"login\":\"cursor[bot]\"},\"created_at\":\"$BEFORE_HEAD\",\"body\":\"y\"},{\"user\":{\"login\":\"coderabbitai[bot]\"},\"created_at\":\"$BEFORE_HEAD\",\"body\":\"z\"}]"
OUT=$(GH_COMMIT_RC=1 run_json 493); RC=$?
check_eq "exit 0 (degradation is not an error)" 0 "$RC"
check_eq "no trigger storm — all treated present" "0" "$(actions | grep -c '^COMMENT')"
check_eq "clean=true" "true" "$(jq -r '.clean' <<<"$OUT")"
commit_ok

echo "== Scenario 18c: FUTURE-dated HEAD commit → degrade, no needless triggers =="
# Committer date comes from the committing machine's clock. If it is ahead, every
# real comment looks older than HEAD and every reviewer would read as stale.
view_ready; no_checks
write_commit '{"commit":{"committer":{"date":"2099-01-01T00:00:00Z"}}}'
write_reviews "$EMPTY"; write_pull_comments "$EMPTY"
write_issue_comments "[{\"user\":{\"login\":\"graphite-app[bot]\"},\"created_at\":\"$BEFORE_HEAD\",\"body\":\"g\"},{\"user\":{\"login\":\"codeant-ai[bot]\"},\"created_at\":\"$BEFORE_HEAD\",\"body\":\"x\"},{\"user\":{\"login\":\"cursor[bot]\"},\"created_at\":\"$BEFORE_HEAD\",\"body\":\"y\"},{\"user\":{\"login\":\"coderabbitai[bot]\"},\"created_at\":\"$BEFORE_HEAD\",\"body\":\"z\"}]"
OUT=$(run_json 493); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "future HEAD date → no triggers (degraded to present)" "0" "$(actions | grep -c '^COMMENT')"
check_eq "clean=true" "true" "$(jq -r '.clean' <<<"$OUT")"
commit_ok

echo "== Scenario 18d: a SHA-bearing artifact must not act as our trigger =="
# Only issue comments (no commit_id) can be a trigger WE posted via `gh pr
# comment`. A review/inline comment whose body merely equals the trigger string
# is someone else quoting it and must not suppress a real trigger.
view_ready; commit_ok; no_checks
write_reviews "[{\"user\":{\"login\":\"someone\"},\"commit_id\":\"$OLD_SHA\",\"submitted_at\":\"$AFTER_HEAD\",\"body\":\"@coderabbitai full review\"}]"
write_pull_comments "$EMPTY"; write_issue_comments "$EMPTY"
OUT=$(run_json 493)
check_eq "SHA-bearing lookalike does not suppress" "triggered" "$(jq -r '.reviewers.coderabbit.status' <<<"$OUT")"
check_eq "CR trigger actually posted" "1" "$(actions | grep -cF '@coderabbitai full review')"

echo "== Scenario 18b: check-runs fetch failure → other signals still decide =="
view_ready; commit_ok
write_reviews "[{\"user\":{\"login\":\"cursor[bot]\"},\"commit_id\":\"$HEAD_SHA\",\"submitted_at\":\"$AFTER_HEAD\",\"body\":\"c\"}]"
write_pull_comments "$EMPTY"; write_issue_comments "$EMPTY"
OUT=$(GH_CHECK_RUNS_RC=1 run_json 493); RC=$?
check_eq "exit 0 (check-runs failure is non-fatal)" 0 "$RC"
check_eq "cursor still present via HEAD review" "already-present" "$(jq -r '.reviewers.cursor.status' <<<"$OUT")"
# The other three have no HEAD artifact — assert they are still triggered, so an
# implementation that swallowed the failure by marking everyone present fails here.
check_eq "other 3 still triggered (failure not read as 'all present')" "triggered triggered triggered" \
  "$(jq -r '[.reviewers.codeant.status, .reviewers.coderabbit.status, .reviewers.graphite.status] | join(" ")' <<<"$OUT")"
check_eq "exactly 3 comments posted" "3" "$(actions | grep -c '^COMMENT')"
no_checks

############################################################################
echo "== Scenario 19: per-SHA session-state dedupe =="
# Guards the window where our comment is posted but not yet visible to the scan.
enable_state_dedupe
view_ready; commit_ok; no_checks
write_reviews "$EMPTY"; write_pull_comments "$EMPTY"; write_issue_comments "$EMPTY"
OUT=$(run_json 493)
check_eq "first run triggers all 4" "4" "$(actions | grep -c '^COMMENT')"
check_eq "marker records HEAD sha" "$HEAD_SHA" "$(jq -r '.prs["493"].preflight_trigger_head_sha' "$STATE_JSON")"
# Second run: GitHub has not yet surfaced our comments (fixtures still empty).
OUT=$(run_json 493)
check_eq "second run posts nothing (dedupe held)" "0" "$(actions | grep -c '^COMMENT')"
check_eq "second run all already-present" "already-present already-present already-present already-present" \
  "$(jq -r '[.reviewers[].status] | join(" ")' <<<"$OUT")"

echo "== Scenario 19a: --dry-run writes NO dedupe state =="
# --dry-run must stay side-effect-free now that a successful trigger persists a
# marker; a dry-run that recorded one would suppress the real trigger later.
enable_state_dedupe
view_ready; commit_ok; no_checks
write_reviews "$EMPTY"; write_pull_comments "$EMPTY"; write_issue_comments "$EMPTY"
STATE_BEFORE="$(jq -cS . "$STATE_JSON")"
OUT=$(run_json 493 --dry-run)
check_eq "dry-run posts nothing" "0" "$(actions | grep -c '^COMMENT')"
# Compare the WHOLE state, not just the sha field — a field-specific assertion
# would miss a dry-run that mutated preflight_triggered or any sibling key.
check_eq "dry-run leaves entire state untouched" "$STATE_BEFORE" "$(jq -cS . "$STATE_JSON")"
reset_state

# Re-establish the old-HEAD marker that 19b needs. Without this precondition
# 19b runs against empty state, so "new HEAD re-triggers all 4" would pass
# vacuously — there would be no stale marker for the new HEAD to invalidate.
view_ready
run_json 493 >/dev/null
check_eq "precondition: marker tracks the OLD head" "$HEAD_SHA" \
  "$(jq -r '.prs["493"].preflight_trigger_head_sha' "$STATE_JSON")"

echo "== Scenario 19b: dedupe marker is invalidated when HEAD moves =="
# Flags from the PREVIOUS sha must never mark a reviewer engaged on the NEW one.
NEW_SHA="newsha00000000000000000000000000000003"
write_view "{\"isDraft\":false,\"author\":{\"login\":\"me\"},\"state\":\"OPEN\",\"headRefOid\":\"$NEW_SHA\"}"
OUT=$(run_json 493)
check_eq "new HEAD re-triggers all 4" "4" "$(actions | grep -c '^COMMENT')"
check_eq "marker now tracks the new sha" "$NEW_SHA" "$(jq -r '.prs["493"].preflight_trigger_head_sha' "$STATE_JSON")"

echo "== Scenario 19c: HEAD moves again; only the ONE stale reviewer is triggered =="
# The map must be REPLACED (not merged) when the sha changes. Merging would keep
# the four flags from NEW_SHA while stamping NEWER_SHA — marking reviewers
# triggered-for-HEAD that were only triggered for the parent commit, suppressing
# exactly the re-trigger #576 exists to perform.
# Here three reviewers are genuinely fresh on NEWER_SHA and only graphite is not:
# the map must end up with graphite ONLY, and only graphite may be posted.
NEWER_SHA="newersha000000000000000000000000000004"
write_view "{\"isDraft\":false,\"author\":{\"login\":\"me\"},\"state\":\"OPEN\",\"headRefOid\":\"$NEWER_SHA\"}"
write_reviews "[{\"user\":{\"login\":\"codeant-ai[bot]\"},\"commit_id\":\"$NEWER_SHA\",\"submitted_at\":\"$AFTER_HEAD\",\"body\":\"r\"},{\"user\":{\"login\":\"coderabbitai[bot]\"},\"commit_id\":\"$NEWER_SHA\",\"submitted_at\":\"$AFTER_HEAD\",\"body\":\"r\"}]"
write_pull_comments "[{\"user\":{\"login\":\"cursor[bot]\"},\"commit_id\":\"$NEWER_SHA\",\"created_at\":\"$AFTER_HEAD\",\"body\":\"c\"}]"
write_issue_comments "$EMPTY"
OUT=$(run_json 493)
check_eq "only graphite posted" "1" "$(actions | grep -c '^COMMENT')"
check_eq "the post is graphite" "1" "$(actions | grep -cF '@graphite-app re-review')"
check_eq "map REPLACED — holds graphite only, no carry-over" "graphite" \
  "$(jq -r '[.prs["493"].preflight_triggered | to_entries[] | select(.value == true) | .key] | sort | join(",")' "$STATE_JSON")"
disable_state_dedupe

############################################################################
# Issue #590 — timeline-based freshness anchor for SHA-less issue comments,
# replacing the committer-date-only proxy.
############################################################################

echo "== Scenario 20: REBASE WINDOW — comment on the OLD sha lands between rebase and push =="
# The committer date is stamped at REBASE time (earliest), a bot comment about
# the pre-rebase sha lands next, and the actual force-push (GitHub's clock, via
# the timeline event) happens last. Under the old committer-date-only proxy the
# comment (after the committer date) read as fresh; the timeline anchor (after
# the comment) correctly reads it as stale, so the reviewer is re-triggered.
REBASE_TIME="$(iso_from_now -3700)"
COMMENT_ON_OLD_SHA="$(iso_from_now -3500)"
PUSH_TIME_A="$(iso_from_now -3400)"
view_ready
write_commit "{\"commit\":{\"committer\":{\"date\":\"$REBASE_TIME\"}}}"
write_timeline "[{\"event\":\"head_ref_force_pushed\",\"created_at\":\"$PUSH_TIME_A\",\"commit_id\":\"$HEAD_SHA\"}]"
no_checks
write_reviews "[{\"user\":{\"login\":\"codeant-ai[bot]\"},\"commit_id\":\"$HEAD_SHA\",\"submitted_at\":\"$PUSH_TIME_A\",\"body\":\"r\"},{\"user\":{\"login\":\"coderabbitai[bot]\"},\"commit_id\":\"$HEAD_SHA\",\"submitted_at\":\"$PUSH_TIME_A\",\"body\":\"r\"}]"
write_pull_comments "[{\"user\":{\"login\":\"cursor[bot]\"},\"commit_id\":\"$HEAD_SHA\",\"created_at\":\"$PUSH_TIME_A\",\"body\":\"c\"}]"
write_issue_comments "[{\"user\":{\"login\":\"graphite-app[bot]\"},\"created_at\":\"$COMMENT_ON_OLD_SHA\",\"body\":\"finding on the pre-rebase commit\"}]"
OUT=$(run_json 493); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "rebase-window comment judged stale — graphite re-triggered" "triggered" "$(jq -r '.reviewers.graphite.status' <<<"$OUT")"
check_eq "codeant already-present via HEAD review (unaffected)" "already-present" "$(jq -r '.reviewers.codeant.status' <<<"$OUT")"
check_eq "coderabbit already-present via HEAD review (unaffected)" "already-present" "$(jq -r '.reviewers.coderabbit.status' <<<"$OUT")"
check_eq "cursor already-present via HEAD comment (unaffected)" "already-present" "$(jq -r '.reviewers.cursor.status' <<<"$OUT")"
check_eq "only graphite re-triggered" "1" "$(actions | grep -c '^COMMENT')"
check_eq "the trigger is graphite" "1" "$(actions | grep -cF '@graphite-app re-review')"
check_eq "clean=false" "false" "$(jq -r '.clean' <<<"$OUT")"
no_timeline; commit_ok; no_checks

echo "== Scenario 21: CLOCK SKEW — fresh comment precedes the committer date but follows the push event =="
# Mirrors the live PR #586 observation: the committer date (local git clock)
# can read LATER than the timeline's push event (GitHub's clock) even though
# the push happened after the commit in real time. A bot comment posted right
# after the real push can therefore carry a timestamp before the committer
# date. The old committer-date-only proxy misread it as stale (wasting a
# rate-limited CodeRabbit slot); the timeline anchor correctly reads it as
# fresh.
COMMITTER_DATE_SKEWED="$(iso_from_now -3600)"
PUSH_TIME_B="$(iso_from_now -3660)"
COMMENT_AFTER_PUSH="$(iso_from_now -3650)"
view_ready
write_commit "{\"commit\":{\"committer\":{\"date\":\"$COMMITTER_DATE_SKEWED\"}}}"
write_timeline "[{\"event\":\"head_ref_force_pushed\",\"created_at\":\"$PUSH_TIME_B\",\"commit_id\":\"$HEAD_SHA\"}]"
no_checks
write_reviews "[{\"user\":{\"login\":\"codeant-ai[bot]\"},\"commit_id\":\"$HEAD_SHA\",\"submitted_at\":\"$PUSH_TIME_B\",\"body\":\"r\"},{\"user\":{\"login\":\"cursor[bot]\"},\"commit_id\":\"$HEAD_SHA\",\"submitted_at\":\"$PUSH_TIME_B\",\"body\":\"c\"},{\"user\":{\"login\":\"graphite-app[bot]\"},\"commit_id\":\"$HEAD_SHA\",\"submitted_at\":\"$PUSH_TIME_B\",\"body\":\"g\"}]"
write_pull_comments "$EMPTY"
write_issue_comments "[{\"user\":{\"login\":\"coderabbitai[bot]\"},\"created_at\":\"$COMMENT_AFTER_PUSH\",\"body\":\"fresh finding, GitHub clock slightly behind the committer's\"}]"
OUT=$(run_json 493); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "clock-skew comment judged fresh — coderabbit stays already-present" "already-present" "$(jq -r '.reviewers.coderabbit.status' <<<"$OUT")"
check_eq "codeant already-present via HEAD review (unaffected)" "already-present" "$(jq -r '.reviewers.codeant.status' <<<"$OUT")"
check_eq "cursor already-present via HEAD review (unaffected)" "already-present" "$(jq -r '.reviewers.cursor.status' <<<"$OUT")"
check_eq "graphite already-present via HEAD review (unaffected)" "already-present" "$(jq -r '.reviewers.graphite.status' <<<"$OUT")"
check_eq "no CR trigger posted (budget not spent)" "0" "$(actions | grep -cF '@coderabbitai full review')"
check_eq "fully clean — no comments posted at all" "0" "$(actions | grep -c '^COMMENT')"
check_eq "clean=true" "true" "$(jq -r '.clean' <<<"$OUT")"
no_timeline; commit_ok; no_checks

echo "== Scenario 22: timeline fetch fails → falls back to committer date, no trigger storm =="
view_ready; commit_ok; no_checks
write_reviews "$EMPTY"; write_pull_comments "$EMPTY"
write_issue_comments "[{\"user\":{\"login\":\"graphite-app[bot]\"},\"created_at\":\"$AFTER_HEAD\",\"body\":\"g\"},{\"user\":{\"login\":\"codeant-ai[bot]\"},\"created_at\":\"$AFTER_HEAD\",\"body\":\"x\"},{\"user\":{\"login\":\"cursor[bot]\"},\"created_at\":\"$AFTER_HEAD\",\"body\":\"y\"},{\"user\":{\"login\":\"coderabbitai[bot]\"},\"created_at\":\"$AFTER_HEAD\",\"body\":\"z\"}]"
OUT=$(GH_TIMELINE_RC=1 run_json 493); RC=$?
check_eq "exit 0 (timeline fetch failure is not an error)" 0 "$RC"
check_eq "falls back to committer date — no trigger storm" "0" "$(actions | grep -c '^COMMENT')"
check_eq "clean=true" "true" "$(jq -r '.clean' <<<"$OUT")"
no_timeline

echo
echo "== summary: $PASS passed, $FAIL failed =="
[[ "$FAIL" -eq 0 ]] || exit 1
echo "OK: pr-preflight.sh tests passed"
