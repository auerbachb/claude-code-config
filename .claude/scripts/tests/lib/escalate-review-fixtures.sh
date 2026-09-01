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
        repos/*/issues/*/timeline*)
          # PR timeline — source of the head-observation anchor (issue #1517).
          # Defaults to an empty timeline so every suite written before this
          # existed keeps the behaviour the stub's `[]` fallback already gave
          # them: no force-push event, anchor falls back to the commit date.
          if [[ -n "${FIXTURE_TIMELINE_JSON:-}" ]]; then
            cat "$FIXTURE_TIMELINE_JSON"
          else
            echo "[]"
          fi
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

# The same instant as ts_seconds_ago in GitHub's OTHER UTC spelling.
# ts-normalizer.sh documents "…Z", "…+00:00", and "…+0000" as all live on the
# wire, so a shape test keyed on one of them is a silent single-spelling
# dependency. Used by the head-observation anchor suite to prove its test is
# ANCHORED rather than narrowed.
ts_seconds_ago_utc_offset() {
  python3 -c "
from datetime import datetime, timedelta, timezone
print((datetime.now(timezone.utc) - timedelta(seconds=$1)).strftime('%Y-%m-%dT%H:%M:%S') + '+00:00')
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
  # Issue #1517: reset the timeline on every scenario. Clearing it HERE rather
  # than in write_force_push is what stops a force-push event leaking from one
  # scenario into the next — every suite calls write_commits per scenario, so an
  # event set once would otherwise silently apply to everything after it.
  printf '[]\n' > "$TMP/timeline.json"
  export FIXTURE_TIMELINE_JSON="$TMP/timeline.json"
}

# The head ref MOVED BY FORCE at $1 (issue #1517). The head-observation anchor is
# max(commit date, newest force-push), so this is how a scenario says "the commit
# is old but it only became HEAD just now" — the case a commit date cannot
# express. Call AFTER write_commits, which resets the timeline.
write_force_push() {
  local ts="$1"
  cat > "$TMP/timeline.json" <<EOF
[{"event": "head_ref_force_pushed", "created_at": "$ts"}]
EOF
  export FIXTURE_TIMELINE_JSON="$TMP/timeline.json"
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

# CodeRabbit `Review limit reached` banner (issue #1199). Reproduces the live
# shape: a blockquoted WARNING admonition whose retry window is wrapped in
# markdown emphasis (`**Next review available in:** **12 minutes**`), which is
# why the parser strips asterisks before matching. $1 = created_at, $2 = the
# window text ("12 minutes"), or "" for a banner carrying no readable window.
cr_limit_banner() {
  local ts="$1" window="${2-}" tail=""
  [[ -n "$window" ]] && tail=" **Next review available in:** **${window}**"
  printf '{"user": {"login": "coderabbitai[bot]"}, "created_at": "%s", "body": "> [!WARNING]\\n> ## Review limit reached\\n> You have reached a temporary PR review limit under our Fair Usage Limits Policy.%s"}' "$ts" "$tail"
}
# The SAME banner in CodeRabbit's CURRENT wording (issue #1364), captured
# verbatim from auerbachb/still-point PR #676 on 2026-08-26: the word `included`
# is inserted between "Next" and "review", the colon after "in" is gone, the
# window ends in a period, and the whole comment is preceded by the auto-
# generated `rate limited by coderabbit.ai` marker. Two drifts from
# `cr_limit_banner` in one rewording — which is why the parser is keyed on the
# stable anchors rather than the sentence. $1 = created_at, $2 = window text
# ("27 minutes"), or "" for a banner carrying no readable window.
cr_limit_banner_included() {
  local ts="$1" window="${2-}" tail=""
  [[ -n "$window" ]] && tail="\\n>\\n> **Next included review available in ${window}.**"
  printf '{"user": {"login": "coderabbitai[bot]"}, "created_at": "%s", "body": "<!-- This is an auto-generated comment: rate limited by coderabbit.ai -->\\n\\n> [!WARNING]\\n> ## Review limit reached\\n> You have reached a temporary PR review limit under our Fair Usage Limits Policy.%s"}' "$ts" "$tail"
}
# The FUTURE-TENSE window sentence (CodeAnt review of PR #1393). CodeRabbit ships
# `will be` between "review" and "available" — captured verbatim on PR #554 as
# `Your next review will be available in 22 minutes.` and tolerated by
# `lib/pr-state-classify.jq` since #557, while this parser's inserted-word
# allowance sat on the far side of "review" and could never reach it. The wording
# is carried here on a `Review limit reached` banner because that is the family
# the grace admits: the #554 body itself is an adaptive-limits notice wrapped in
# `Full review finished.`, which reports a landed review and earns no wait (see
# cr-rate-limits.md). $1 = created_at, $2 = window text, or "" for none.
cr_limit_banner_will_be() {
  local ts="$1" window="${2-}" tail=""
  [[ -n "$window" ]] && tail="\\n>\\n> **Your next review will be available in ${window}.**"
  printf '{"user": {"login": "coderabbitai[bot]"}, "created_at": "%s", "body": "> [!WARNING]\\n> ## Review limit reached\\n> You have reached a temporary PR review limit under our Fair Usage Limits Policy.%s"}' "$ts" "$tail"
}
# The same banner with an UNRECOGNISED copula. Bounds the widening: the slot is a
# literal `will be`, not a free bridge, so this yields no window and the PR
# escalates. Pins the failure DIRECTION of the next unlogged drift — degraded to
# escalation, never a stalled PR.
#
# The copula here is exactly TWO words on purpose. A longer one ("is once again")
# would also be rejected by a generic `(?:\s+\w+){0,2}` bridge, so the scenario
# would pass whether the slot were literal or widened — proving nothing. `is now`
# is the shortest phrasing that a bridge WOULD swallow and the literal does not,
# which is what makes this case fail if someone widens the slot in either file.
# $1 = created_at, $2 = window text.
cr_limit_banner_unknown_copula() {
  printf '{"user": {"login": "coderabbitai[bot]"}, "created_at": "%s", "body": "> [!WARNING]\\n> ## Review limit reached\\n>\\n> **Your next review is now available in %s.**"}' "$1" "$2"
}
# MARKER ONLY: the auto-generated marker present, the `Review limit reached`
# heading prose absent. Pins the wording-independent half of banner detection —
# if CodeRabbit drops or rewrites the heading entirely, this shape is all that is
# left to key on. $1 = created_at, $2 = window text.
cr_limit_banner_marker_only() {
  printf '{"user": {"login": "coderabbitai[bot]"}, "created_at": "%s", "body": "<!-- This is an auto-generated comment: rate limited by coderabbit.ai -->\\n\\n> [!WARNING]\\n> You have hit a temporary cap under our Fair Usage Limits Policy.\\n>\\n> **Next included review available in %s.**"}' "$1" "$2"
}
# CodeRabbit PROSE that names the marker phrase without being the marker: the
# words appear in body text rather than inside the `<!-- ... -->` machine comment,
# and a future-tense window sentence sits alongside them. The author gate cannot
# separate this from a real banner — both are coderabbitai[bot] — so only the
# HTML-comment anchor can. Grants no grace.
cr_marker_phrase_in_prose() {
  printf '{"user": {"login": "coderabbitai[bot]"}, "created_at": "%s", "body": "Actionable comments posted: 1\\n\\nThis PR was rate limited by coderabbit.ai on its previous run. Next included review available in 27 minutes was the banner it emitted; the retry helper should assert that string."}' "$1"
}
# A CodeRabbit comment carrying NEITHER signal — no heading prose, no marker —
# but which does name a number and a unit. Guards the direction the banner select
# exists to hold: an ordinary CodeRabbit comment must buy no grace no matter what
# numbers it happens to contain.
cr_non_banner_comment() {
  printf '{"user": {"login": "coderabbitai[bot]"}, "created_at": "%s", "body": "Actionable comments posted: 2\\n\\nThe retry helper waits 12 minutes between attempts; see the docs at coderabbit.ai for details."}' "$1"
}
# Same banner text from a NON-CodeRabbit author — a quote or a human paraphrase
# must not buy the PR a grace period.
cr_limit_banner_foreign_author() {
  printf '{"user": {"login": "test-user"}, "created_at": "%s", "body": "## Review limit reached **Next review available in:** **%s**"}' "$1" "$2"
}
# The banner as it actually lives on a PR: EDITED IN PLACE (issue #1440).
# CodeRabbit rewrites this one comment as the allowance recovers — `created_at`
# stays frozen at the banner's birth while `updated_at` tracks the window the
# body currently states. Observed on PR #1436: created 01:55:37Z saying 43
# minutes, updated 02:05:02Z saying 33.
#
# Every OTHER banner helper above deliberately omits `updated_at`, which makes
# the rest of this suite the missing-field control for the max() fallback: if
# the selector ever reads the edit time bare instead of taking the max, those
# scenarios lose their timestamp entirely and go red as a group.
#
# $1 = created_at, $2 = updated_at (pass "" for the empty-field shape a payload
# that stopped projecting the field would produce), $3 = window text, or "" for
# a banner carrying no readable window. Built by editing the CURRENT-wording
# banner so the two helpers cannot drift apart.
cr_limit_banner_edited() {
  cr_limit_banner_included "$1" "${3-}" | jq -c --arg u "$2" '.updated_at = $u'
}

# A CodeRabbit review object on the current HEAD — proves CR has already
# answered, so there is nothing left to wait for.
cr_review_on_head() {
  printf '{"user": {"login": "coderabbitai[bot]"}, "commit_id": "%s", "state": "COMMENTED", "submitted_at": "%s"}' "$HEAD_SHA" "$1"
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
