#!/usr/bin/env bash
# Offline tests for the BugBot spend-refusal suppression in
# maybe-trigger-ai-review.sh (issue #1199).
#
# WHAT IS UNDER TEST
#   BugBot is metered against a Cursor usage/spend limit and refused 64% of PRs
#   in the 2026-08 audit window, while this script kept nudging — 469
#   `@cursor review` comments across 244 PRs. A nudge cannot clear a usage limit,
#   so once cursor[bot] has refused on THIS HEAD, later nudges on the same HEAD
#   are suppressed. The next push is a new HEAD and starts clean.
#
#   The suppression FAILS OPEN: any uncertainty (unreadable comments, missing
#   HEAD timestamp) posts the nudge, because bugbot.md calls a duplicate
#   `@cursor review` harmless while a wrongly-suppressed one costs a review.
#
# HOW IT IS OBSERVED
#   The gh stub appends every posted comment body to $POSTED. Each scenario
#   asserts on that transcript, so "did not post" is proven by the transcript
#   rather than inferred from the absence of an error.

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

PR_NUM="99553"
HEAD_SHA="deadbeef0000000000000000000000000000abcd"

# ---- stub SCRIPT_DIR: real script + real state machinery + stubbed inputs ----
STUB_DIR="$TMP/scripts"
mkdir -p "$STUB_DIR/lib"
cp "$REPO_ROOT/.claude/scripts/maybe-trigger-ai-review.sh" "$STUB_DIR/"
cp "$REPO_ROOT/.claude/scripts/session-state.sh" "$STUB_DIR/"
cp "$REPO_ROOT/.claude/scripts/state-lock.sh" "$STUB_DIR/"
cp "$REPO_ROOT/.claude/scripts/lib/repo-normalizer.sh" "$STUB_DIR/lib/"
# The real normaliser, not a stub: the script disables suppression outright when
# this library will not load, so a missing copy would make every scenario post
# and the suppression cases would fail for a reason unrelated to their subject.
cp "$REPO_ROOT/.claude/scripts/lib/ts-normalizer.sh" "$STUB_DIR/lib/"
chmod +x "$STUB_DIR/maybe-trigger-ai-review.sh" "$STUB_DIR/session-state.sh"

# Gates are not under test here — these two stubs put every scenario past them
# and into the posting block.
printf '#!/usr/bin/env bash\necho 3\n'   > "$STUB_DIR/cycle-count.sh"
printf '#!/usr/bin/env bash\necho 500\n' > "$STUB_DIR/complexity-score.sh"
chmod +x "$STUB_DIR/cycle-count.sh" "$STUB_DIR/complexity-score.sh"

# ---- gh stub -----------------------------------------------------------------
# FIXTURE_COMMENTS_JSON — issues/{n}/comments payload
# FIXTURE_HEAD_TS       — commit committer date (the script reads it via --jq,
#                         which real gh applies; the stub returns the value)
# FIXTURE_API_FAIL=1    — every `gh api` call fails (fail-open probe)
# FIXTURE_POST_FAIL     — a comment body whose post fails (partial-run probe)
# POSTED                — transcript of posted comment bodies
STUB_BIN="$TMP/bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/gh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
sub="${1-}"; shift || true
case "$sub" in
  pr)
    case "${1-}" in
      view) echo "$FIXTURE_HEAD_SHA"; exit 0 ;;
      comment)
        prev=""
        for a in "$@"; do
          if [[ "$prev" == "--body" ]]; then
            if [[ -n "${FIXTURE_POST_FAIL:-}" && "$a" == "$FIXTURE_POST_FAIL" ]]; then exit 1; fi
            echo "$a" >> "$POSTED"
            exit 0
          fi
          prev="$a"
        done
        exit 0
        ;;
    esac
    exit 0
    ;;
  api)
    if [[ "${FIXTURE_API_FAIL:-0}" == "1" ]]; then exit 1; fi
    for arg in "$@"; do
      case "$arg" in
        repos/*/commits/*)          printf '%s\n' "$FIXTURE_HEAD_TS"; exit 0 ;;
        repos/*/issues/*/comments*) cat "$FIXTURE_COMMENTS_JSON";     exit 0 ;;
      esac
    done
    echo "[]"
    ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$STUB_BIN/gh"
export PATH="$STUB_BIN:$PATH"
export FIXTURE_HEAD_SHA="$HEAD_SHA"

ts_seconds_ago() {
  python3 -c "
from datetime import datetime, timedelta, timezone
print((datetime.now(timezone.utc) - timedelta(seconds=$1)).strftime('%Y-%m-%dT%H:%M:%SZ'))
"
}

setup() {
  local head_age="$1" comments_json="$2"
  rm -f "$HOME/.claude/session-state.json"
  FIXTURE_HEAD_TS="$(ts_seconds_ago "$head_age")"
  export FIXTURE_HEAD_TS
  printf '%s\n' "$comments_json" > "$TMP/comments.json"
  export FIXTURE_COMMENTS_JSON="$TMP/comments.json"
  export FIXTURE_API_FAIL=0
  export FIXTURE_POST_FAIL=""
  export POSTED="$TMP/posted.txt"
  : > "$POSTED"
}

refusal() {
  printf '{"user": {"login": "cursor[bot]"}, "created_at": "%s", "body": "<h3>Bugbot couldn'"'"'t run - usage limit reached</h3> this run hit a usage or spend limit."}' "$1"
}
ordinary_cursor_comment() {
  printf '{"user": {"login": "cursor[bot]"}, "created_at": "%s", "body": "Found 1 bug: possible null dereference."}' "$1"
}

run_script() {
  ( cd "$REPO_ROOT" && bash "$STUB_DIR/maybe-trigger-ai-review.sh" "$PR_NUM" >/dev/null 2>&1 )
}
posted_cursor() { grep -cFx "@cursor review" "$POSTED" 2>/dev/null | tr -d ' '; }
posted_count()  { wc -l < "$POSTED" | tr -d ' '; }
read_step() {
  ( cd "$REPO_ROOT" && "$STUB_DIR/session-state.sh" \
      --get ".prs[\"$PR_NUM\"].ai_review_trigger_steps.$1" 2>/dev/null )
}

############################################################################
echo "== (a): refusal POSTDATES the HEAD commit -> @cursor review suppressed =="
setup 600 "[$(refusal "$(ts_seconds_ago 60)")]"
run_script
check_eq "no @cursor review posted" "0" "$(posted_cursor)"
check_eq "the other two nudges still posted" "2" "$(posted_count)"

############################################################################
echo "== (b): refusal PREDATES the HEAD commit -> nudge posts (new push, clean slate) =="
setup 60 "[$(refusal "$(ts_seconds_ago 600)")]"
run_script
check_eq "@cursor review posted once" "1" "$(posted_cursor)"
check_eq "all three nudges posted" "3" "$(posted_count)"

############################################################################
echo "== (c): cursor[bot] active but never refused -> nudge posts =="
setup 600 "[$(ordinary_cursor_comment "$(ts_seconds_ago 60)")]"
run_script
check_eq "@cursor review posted once" "1" "$(posted_cursor)"
check_eq "all three nudges posted" "3" "$(posted_count)"

############################################################################
echo "== (d): no comments at all -> nudge posts =="
setup 600 "[]"
run_script
check_eq "@cursor review posted once" "1" "$(posted_cursor)"
check_eq "all three nudges posted" "3" "$(posted_count)"

############################################################################
echo "== (e): FAILS OPEN — gh api unreadable -> nudge posts anyway =="
# The refusal fixture would suppress if it could be read, so the API failure is
# the only difference from (a). A green (e) therefore proves the fail-open
# direction rather than proving the fixture was never a refusal.
setup 600 "[$(refusal "$(ts_seconds_ago 60)")]"
export FIXTURE_API_FAIL=1
run_script
check_eq "@cursor review posted despite the unreadable API" "1" "$(posted_cursor)"
check_eq "all three nudges posted" "3" "$(posted_count)"

############################################################################
echo "== (f): suppression records the cursor step, so a resume cannot re-post it =="
# A completed run clears the whole steps record (`ai_review_trigger_steps=null`),
# so the resume hazard only exists when a LATER step fails. Failing the graphite
# post keeps the record alive and makes the recorded cursor value observable.
setup 600 "[$(refusal "$(ts_seconds_ago 60)")]"
export FIXTURE_POST_FAIL="@graphite-app re-review"
run_script; RC_F=$?
check_eq "run failed at the graphite step" "5" "$RC_F"
check_eq "cursor step recorded true (suppressed counts as done)" "true" "$(read_step cursor)"
# Negative control: the surviving record is genuinely partial, so the `true`
# above is the value this branch wrote and not everything defaulting true.
check_eq "graphite step still false (record is partial, not all-true)" "false" "$(read_step graphite)"
check_eq "no @cursor review posted" "0" "$(posted_cursor)"

echo
echo "== summary: $PASS passed, $FAIL failed =="
[[ "$FAIL" -eq 0 ]] || exit 1
echo "OK: maybe-trigger-ai-review.sh BugBot suppression tests passed"
