#!/usr/bin/env bash
# Offline tests for the review-tier BugBot skip in maybe-trigger-ai-review.sh
# (issue #1728).
# catalog: tests — Tests the review-tier `@cursor review` skip in `maybe-trigger-ai-review.sh`
#
# WHAT IS UNDER TEST
#   A repo may declare review tiers (.claude/reference/review-policy.md). BugBot
#   is invited only on the `full` gate or with no policy (`legacy`), so on a
#   ci-only or ci+codeant-one-round PR this script posts the CodeAnt nudge but
#   NOT `@cursor review`, and says so in --json.
#
#   The skip FAILS OPEN: a missing helper or an unresolvable tier posts, the
#   same direction as the refusal guard (maybe-trigger-bugbot-suppression.test.sh).
#
# HOW IT IS OBSERVED
#   The REAL bugbot-tier-excluded.sh runs against a stub review-tier.sh whose
#   answer each scenario sets. The gh stub appends every posted comment body to
#   $POSTED, so "did not post" is read off the transcript. The gh stub serves no
#   BugBot refusal, so the refusal guard never suppresses here — any missing
#   `@cursor review` is the tier skip's doing.

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

PR_NUM="99554"
HEAD_SHA="deadbeef0000000000000000000000000000abce"

# ---- stub SCRIPT_DIR: real script + real helpers + stubbed inputs ------------
STUB_DIR="$TMP/scripts"
mkdir -p "$STUB_DIR/lib"
cp "$REPO_ROOT/.claude/scripts/check-runs-snapshot.sh" "$REPO_ROOT/.claude/scripts/required-checks.sh" "$STUB_DIR/"
cp "$REPO_ROOT/.claude/scripts/lib/check_run_workflows.py" "$REPO_ROOT/.claude/scripts/lib/required-context-state.jq" "$REPO_ROOT/.claude/scripts/lib/check-run-conclusions.jq" "$STUB_DIR/lib/"
cp "$REPO_ROOT/.claude/scripts/maybe-trigger-ai-review.sh" "$STUB_DIR/"
cp "$REPO_ROOT/.claude/scripts/session-state.sh" "$STUB_DIR/"
cp "$REPO_ROOT/.claude/scripts/state-lock.sh" "$STUB_DIR/"
cp "$REPO_ROOT/.claude/scripts/review-request-gate.sh" "$STUB_DIR/"
cp "$REPO_ROOT/.claude/scripts/check-runs-dedup.sh" "$STUB_DIR/"
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB_DIR/pr-authorship.sh"; chmod +x "$STUB_DIR/pr-authorship.sh"
cp "$REPO_ROOT/.claude/scripts/lib/repo-normalizer.sh" "$STUB_DIR/lib/"
cp "$REPO_ROOT/.claude/scripts/lib/ts-normalizer.sh" "$STUB_DIR/lib/"
cp "$REPO_ROOT/.claude/scripts/bugbot-refused-head.sh" "$STUB_DIR/"
# The helper under test is REAL — it owns the excluded-gate list and the
# fail-open mapping. Only the resolver behind it is stubbed.
cp "$REPO_ROOT/.claude/scripts/bugbot-tier-excluded.sh" "$STUB_DIR/"
chmod +x "$STUB_DIR/maybe-trigger-ai-review.sh" "$STUB_DIR/session-state.sh" \
  "$STUB_DIR/bugbot-refused-head.sh" "$STUB_DIR/bugbot-tier-excluded.sh"

# Stub resolver: logs its arguments, prints FIXTURE_TIER_OUT, exits FIXTURE_TIER_RC.
cat > "$STUB_DIR/review-tier.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TIER_CALLS"
if [[ -n "${FIXTURE_TIER_OUT:-}" ]]; then printf '%s\n' "$FIXTURE_TIER_OUT"; fi
exit "${FIXTURE_TIER_RC:-0}"
STUB
export TIER_CALLS="$TMP/tier-calls"

# Gates are not under test here — these two stubs put every scenario past them.
printf '#!/usr/bin/env bash\necho 3\n'   > "$STUB_DIR/cycle-count.sh"
printf '#!/usr/bin/env bash\necho 500\n' > "$STUB_DIR/complexity-score.sh"
chmod +x "$STUB_DIR/cycle-count.sh" "$STUB_DIR/complexity-score.sh"

# ---- gh stub -----------------------------------------------------------------
STUB_BIN="$TMP/bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/gh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
sub="${1-}"; shift || true
case "$sub" in
  pr)
    case "${1-}" in
      view) if [[ "$*" == *baseRefName* ]]; then echo main; elif [[ "$*" == *isDraft* ]]; then echo '{"state":"OPEN","isDraft":false}'; else echo "$FIXTURE_HEAD_SHA"; fi; exit 0 ;;
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
    # No refusal anywhere: the refusal guard always answers "post". The review
    # request waits for a green CI check on a HEAD that is past its grace (#2195).
    case "$*" in
      *actions/runs*) jq -cn --arg head "$FIXTURE_HEAD_SHA" '{total_count:1,workflow_runs:[{id:1,workflow_id:1,event:"push",head_branch:"fixture",head_sha:$head,pull_requests:[],check_suite_id:1,html_url:"https://github.com/fixture/repo/actions/runs/1",status:"completed",conclusion:"success"}]}' ;;
      */branches/*) echo '{"name":"main","protected":false}' ;;
      *check-runs*) echo '{"total_count":1,"check_runs":[{"id":1,"check_suite":{"id":1},"name":"build","status":"completed","conclusion":"success","app":{"slug":"github-actions"}}]}' ;;
      */commits/*) jq -rn 'now - 7200 | todate' ;;
      *) echo "[]" ;;
    esac
    ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$STUB_BIN/gh"
export PATH="$STUB_BIN:$PATH"
export FIXTURE_HEAD_SHA="$HEAD_SHA"

tier_json() { printf '{"policy":"present","gate":"%s","tier":"t","source":"base:main","error":null,"matches":[]}' "$1"; }

setup() { # <resolver stdout> [resolver exit code]
  rm -f "$HOME/.claude/session-state.json"
  export FIXTURE_TIER_OUT="$1" FIXTURE_TIER_RC="${2:-0}"
  export FIXTURE_POST_FAIL=""
  export POSTED="$TMP/posted.txt"
  : > "$POSTED"; : > "$TIER_CALLS"
}

JSON_OUT=""
run_script() {
  JSON_OUT="$( cd "$REPO_ROOT" && bash "$STUB_DIR/maybe-trigger-ai-review.sh" "$PR_NUM" --json "$@" 2>/dev/null )"
}
posted_cursor() { grep -cFx "@cursor review" "$POSTED" 2>/dev/null | tr -d ' '; }
posted_all()    { tr '\n' ';' < "$POSTED"; }
read_step() {
  ( cd "$REPO_ROOT" && "$STUB_DIR/session-state.sh" \
      --get ".prs[\"$PR_NUM\"].ai_review_trigger_steps.$1" 2>/dev/null )
}

############################################################################
for gate in ci-only ci+codeant-one-round; do
  echo "== (a): gate $gate -> no @cursor review; CodeAnt still posts =="
  setup "$(tier_json "$gate")"
  run_script; RC=$?
  check_eq "exit 0" "0" "$RC"
  check_eq "no @cursor review posted" "0" "$(posted_cursor)"
  check_eq "CodeAnt posted, nothing else" "@codeant-ai review;" "$(posted_all)"
  check_eq "--json reports the tier skip" \
    "{\"reason\":\"review_tier\",\"gate\":\"$gate\"}" "$(jq -c '.bugbot_skipped' <<<"$JSON_OUT")"
  check_eq "--json status stays triggered" "triggered" "$(jq -r '.status' <<<"$JSON_OUT")"
  check_eq "resolver asked about THIS PR" "$PR_NUM --json;" "$(tr '\n' ';' < "$TIER_CALLS")"
done

############################################################################
for gate in full legacy; do
  echo "== (b): gate $gate -> CodeAnt posts; BugBot needs owner approval (#1897) =="
  setup "$(tier_json "$gate")"
  run_script; RC=$?
  check_eq "exit 0" "0" "$RC"
  check_eq "@cursor review NOT posted — paid, owner approval required (#1897)" "0" "$(posted_cursor)"
  check_eq "only the free nudge posted" \
    "@codeant-ai review;" "$(posted_all)"
  check_eq "--json reports the approval skip" '{"reason":"approval_required","gate":null}' "$(jq -c '.bugbot_skipped' <<<"$JSON_OUT")"
done

############################################################################
echo "== (c): FAILS OPEN — the resolver fails -> the cursor step reaches the owner-approval skip =="
setup "" 4
run_script; RC=$?
check_eq "exit 0" "0" "$RC"
check_eq "@cursor review NOT posted — paid, owner approval required (#1897)" "0" "$(posted_cursor)"
check_eq "--json reports the approval skip" '{"reason":"approval_required","gate":null}' "$(jq -c '.bugbot_skipped' <<<"$JSON_OUT")"
check_eq "the resolver was actually consulted" "1" "$(grep -c . "$TIER_CALLS" | tr -d ' ')"

############################################################################
echo "== (d): FAILS OPEN — the helper is missing -> the cursor step reaches the owner-approval skip =="
setup "$(tier_json ci-only)"
mv "$STUB_DIR/bugbot-tier-excluded.sh" "$TMP/helper.bak"
run_script; RC=$?
mv "$TMP/helper.bak" "$STUB_DIR/bugbot-tier-excluded.sh"
check_eq "exit 0" "0" "$RC"
check_eq "@cursor review NOT posted despite a ci-only resolver — paid, owner approval required (#1897)" "0" "$(posted_cursor)"

############################################################################
echo "== (e): a tier skip leaves the cursor step open, so a resume re-asks the tier =="
# No post follows the cursor step any more (Graphite retired 2026-11-03, #1889),
# so a partial record is seeded instead of produced by a failing later post. Its
# shape is the pre-#1889 one, `graphite: false` included: an old record must
# resume cleanly and post nothing for the retired step.
seed_partial() {
  ( cd "$REPO_ROOT" && "$STUB_DIR/session-state.sh" --set \
      ".prs[\"$PR_NUM\"].ai_review_trigger_steps={\"head_sha\":\"$HEAD_SHA\",\"cr_rounds\":3,\"codeant\":true,\"cursor\":false,\"graphite\":false}" >/dev/null )
}
setup "$(tier_json ci-only)"
seed_partial
check_eq "precondition: cursor step open in the seeded record" "false" "$(read_step cursor)"
run_script; RC=$?
check_eq "resume exits 0" "0" "$RC"
check_eq "no @cursor review posted" "0" "$(posted_cursor)"
check_eq "codeant not re-posted on the resume" "0" "$(grep -cFx "@codeant-ai review" "$POSTED" | tr -d ' ')"
check_eq "nothing posted for the retired graphite step" "0" "$(grep -c graphite "$POSTED" | tr -d ' ')"

echo "== (e2): the tier changes to full before the resume -> the resumed run reaches the owner-approval skip =="
setup "$(tier_json full)"
seed_partial
run_script; RC=$?
check_eq "resume exits 0" "0" "$RC"
check_eq "@cursor review NOT posted, now that the tier invites BugBot — paid, owner approval required (#1897)" "0" "$(posted_cursor)"
check_eq "codeant not re-posted on the resume" "0" "$(grep -cFx "@codeant-ai review" "$POSTED" | tr -d ' ')"
check_eq "resume --json reports the approval skip" '{"reason":"approval_required","gate":null}' "$(jq -c '.bugbot_skipped' <<<"$JSON_OUT")"

############################################################################
echo "== (f): --dry-run reports the same answer the real run acts on =="
setup "$(tier_json ci-only)"
run_script --dry-run; RC=$?
check_eq "exit 0" "0" "$RC"
check_eq "dry run posted nothing" "" "$(posted_all)"
check_eq "dry-run --json reports the tier skip" \
  '{"reason":"review_tier","gate":"ci-only"}' "$(jq -c '.bugbot_skipped' <<<"$JSON_OUT")"
setup "$(tier_json full)"
run_script --dry-run
check_eq "dry-run --json on full reports the approval skip" '{"reason":"approval_required","gate":null}' "$(jq -c '.bugbot_skipped' <<<"$JSON_OUT")"

for gate in full legacy; do
  tier_off=$(tier_json "$gate" | jq -c '. + {escalation:"off"}')
  setup "$tier_off"
  run_script
  check_eq "escalation off JSON: $gate" "{\"reason\":\"escalation_off\",\"gate\":\"$gate\"}" "$(jq -c '.bugbot_skipped' <<<"$JSON_OUT")"
  check_eq "escalation off never posts paid review: $gate" 0 "$(posted_cursor)"
  setup "$tier_off"
  run_script --dry-run
  check_eq "dry JSON escalation off: $gate" escalation_off "$(jq -r '.bugbot_skipped.reason' <<<"$JSON_OUT")"
  setup "$tier_off"
  TEXT_OUT=$(cd "$REPO_ROOT" && bash "$STUB_DIR/maybe-trigger-ai-review.sh" "$PR_NUM" --dry-run 2>&1)
  check_eq "dry text names escalation off: $gate" yes "$( [[ "$TEXT_OUT" == *'REVIEW_ESCALATION=off'* && "$TEXT_OUT" != *'excludes BugBot'* ]] && echo yes || echo no )"
  setup "$tier_off"
  TEXT_OUT=$(cd "$REPO_ROOT" && bash "$STUB_DIR/maybe-trigger-ai-review.sh" "$PR_NUM" 2>&1)
  check_eq "real text names escalation off: $gate" yes "$( [[ "$TEXT_OUT" == *'REVIEW_ESCALATION=off'* && "$TEXT_OUT" != *'excludes BugBot'* ]] && echo yes || echo no )"
done

echo
echo "== summary: $PASS passed, $FAIL failed =="
[[ "$FAIL" -eq 0 ]] || exit 1
echo "OK: maybe-trigger-ai-review.sh review-tier BugBot skip tests passed"
