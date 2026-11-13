#!/usr/bin/env bash
# no-review-override-ack-replies.test.sh — offline tests for which reviewer artifacts count
# as a verdict on HEAD in no-review-override.sh (issue #2268). Drives the helper directly
# with a fake gh and a throwaway HOME. Run under /bin/bash (3.2) and a 5.x bash.
# catalog: tests — Tests the verdict inventory of the no-review override: empty-body COMMENTED reviews and inline thread replies are acknowledgements, not verdicts
# Run from repo root: bash .claude/scripts/tests/no-review-override-ack-replies.test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$SCRIPT_DIR/../no-review-override.sh"
[[ -f "$HELPER" ]] || { echo "FAIL: helper not found at $HELPER" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
mkdir -p "$HOME/.claude"
BIN="$TMP/bin"
mkdir -p "$BIN"
cat > "$BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
case "$*" in
  *"/pulls/1"*) printf '%s' "$FAKE_PULL_JSON"; exit 0 ;;
  *"/timeline"*) printf '%s' "[]"; exit 0 ;;
  *"actions/runs"*) printf '%s' "$FAKE_RUNS_JSON"; exit 0 ;;
  *"/issues/1/comments?per_page=100"*) printf '%s' "[]"; exit 0 ;;
esac
echo "fake gh: unexpected call: $*" >&2
exit 1
GHEOF
chmod +x "$BIN/gh"
export PATH="$BIN:$PATH"

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $1 — $2"; }
expect_eq() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "got [$2] want [$3]"; fi; }

NOW=$(date -u +%s)
PUSH=$((NOW - 1800))          # HEAD pushed 30 min ago; the 600 s window has elapsed
CHECK=$((PUSH + 5))           # HEAD check-run started 5 s after the push
HEADSHA=1111111111111111111111111111111111111111
iso() { jq -rn --argjson s "$1" '$s | todateiso8601'; }

FAKE_PULL_JSON=$(jq -cn --arg c "$(iso $((NOW - 7200)))" \
  '{number:1, created_at:$c, draft:false, user:{login:"solo"}, head:{ref:"feature", repo:{full_name:"solo/repo"}}}')
export FAKE_PULL_JSON
FAKE_RUNS_JSON=$(jq -cn --arg t "$(iso $PUSH)" --arg h "$HEADSHA" \
  '{total_count:1, workflow_runs:[{event:"pull_request", created_at:$t, head_branch:"feature", head_sha:$h, head_repository:{full_name:"solo/repo"}}]}')
export FAKE_RUNS_JSON

# review <login> <state> <body> — a review on HEAD
review() {
  jq -cn --arg u "$1" --arg s "$2" --arg b "$3" --arg c "$HEADSHA" --arg t "$(iso $((NOW - 1200)))" \
    '{user:{login:$u, type:"Bot"}, state:$s, body:$b, commit_id:$c, submitted_at:$t}'
}

# inline <login> <body> <in_reply_to_id or null> — an inline PR comment anchored to HEAD
inline() {
  jq -cn --arg u "$1" --arg b "$2" --argjson r "$3" --arg c "$HEADSHA" \
    '{user:{login:$u, type:"Bot"}, body:$b, commit_id:$c, original_commit_id:$c, in_reply_to_id:$r}'
}

# payload <reviews JSON array> <pr_comments JSON array> <hollow JSON array>
payload() {
  jq -cn --argjson r "$1" --argjson p "$2" --argjson h "$3" \
    --arg cts "$(iso $((PUSH - 3600)))" --arg hs "$HEADSHA" --arg chk "$(iso $CHECK)" '
    {owner:"solo", repo:"repo", pr:"1", head_sha:$hs, commit_ts:$cts, window_seconds:600,
     tier_gate:"", review_blockers:["no AI reviewer verdict on HEAD"],
     reviews:$r, pr_comments:$p, issue_comments:[],
     check_runs_raw:[{name:"build", status:"completed", conclusion:"success",
                      started_at:$chk, app:{slug:"github-actions"}}], hollow:$h}'
}

run_helper() { printf '%s' "$1" | "$BASH" "$HELPER"; }

CR="coderabbitai[bot]"
CA="codeant-ai[bot]"
CU="cursor[bot]"

# --- 1. PR #2263 shape: CodeRabbit acknowledgement replies, empty COMMENTED reviews, a hollow
#        CodeAnt APPROVED, no real verdict. The window has elapsed, so the override applies.
R1=$(jq -cn --argjson a "$(review "$CR" COMMENTED "")" --argjson b "$(review "$CR" COMMENTED "")" \
      --argjson c "$(review "$CR" COMMENTED "   ")" --argjson d "$(review "$CA" APPROVED "")" '[$a,$b,$c,$d]')
P1=$(jq -cn --argjson a "$(inline "$CR" "Addressed in the latest commit." 1001)" \
      --argjson b "$(inline "$CR" "Thanks, this is fixed now." 1002)" '[$a,$b]')
out=$(run_helper "$(payload "$R1" "$P1" "[\"$CA\"]")")
expect_eq "PR #2263 shape: applied after the window" "$(jq -r .applied <<<"$out")" "true"
expect_eq "PR #2263 shape: reason is window_elapsed" "$(jq -r .reason <<<"$out")" "window_elapsed"
expect_eq "PR #2263 shape: no verdicts on HEAD" "$(jq -c .verdicts_on_head <<<"$out")" "[]"

# --- 2. Empty-body COMMENTED review alone is not a verdict (no inline replies)
out=$(run_helper "$(payload "[$(review "$CR" COMMENTED "")]" '[]' '[]')")
expect_eq "empty COMMENTED review: applied" "$(jq -r .applied <<<"$out")" "true"

# --- 2b. A COMMENTED review whose body is only HTML comments is not a verdict either
out=$(run_helper "$(payload "[$(review "$CR" COMMENTED "$(printf '<!-- coderabbit-ai-generated:v1 -->\n  <!-- marker\nspanning lines -->\n')")]" '[]' '[]')")
expect_eq "HTML-comment-only COMMENTED review: applied" "$(jq -r .applied <<<"$out")" "true"
out=$(run_helper "$(payload "[$(review "$CR" COMMENTED "<!-- marker --> Found a bug in line 3.")]" '[]' '[]')")
expect_eq "COMMENTED review with text beside a comment: verdict" "$(jq -r .reason <<<"$out")" "verdict_on_head"

# --- 3. A COMMENTED review with a real body is still a verdict
out=$(run_helper "$(payload "[$(review "$CR" COMMENTED "Review completed.")]" '[]' '[]')")
expect_eq "COMMENTED review with body: verdict" "$(jq -r .reason <<<"$out")" "verdict_on_head"
expect_eq "COMMENTED review with body: kind" "$(jq -r '.verdicts_on_head[0].kind' <<<"$out")" "review_commented"

# --- 4. A new top-level inline finding (no in_reply_to_id) is still a verdict
out=$(run_helper "$(payload '[]' "[$(inline "$CR" "Possible null deref here." null)]" '[]')")
expect_eq "new top-level inline finding: verdict" "$(jq -r .reason <<<"$out")" "verdict_on_head"
expect_eq "new top-level inline finding: kind" "$(jq -r '.verdicts_on_head[0].kind' <<<"$out")" "inline_comment"

# --- 5. CHANGES_REQUESTED on HEAD is a verdict even with an empty body and only ack replies
out=$(run_helper "$(payload "[$(review "$CR" CHANGES_REQUESTED "")]" "[$(inline "$CR" "Fixed." 1001)]" '[]')")
expect_eq "CHANGES_REQUESTED: verdict" "$(jq -r .reason <<<"$out")" "verdict_on_head"
expect_eq "CHANGES_REQUESTED: kind" "$(jq -r '.verdicts_on_head[0].kind' <<<"$out")" "review_changes_requested"

# --- 6. A non-hollow APPROVED on HEAD is still a verdict
out=$(run_helper "$(payload "[$(review "$CA" APPROVED "Looks good.")]" '[]' '[]')")
expect_eq "substantive APPROVED: verdict" "$(jq -r .reason <<<"$out")" "verdict_on_head"

# --- 7. A hollow APPROVED stays excluded, as before
out=$(run_helper "$(payload "[$(review "$CA" APPROVED "")]" '[]' "[\"$CA\"]")")
expect_eq "hollow APPROVED: excluded, applied" "$(jq -r .applied <<<"$out")" "true"

# --- 8. A bot reply in an existing thread is not a verdict even when its body reads like a finding
out=$(run_helper "$(payload '[]' "[$(inline "$CU" "Still a bug: the guard fails open." 1001)]" '[]')")
expect_eq "inline reply reading like a finding: not a verdict" "$(jq -r .applied <<<"$out")" "true"

# --- 9. Issue #2325 / MIA PR #1121: old findings retargeted onto a new HEAD
# must not block the clock; acknowledgement replies and hollow approval add no verdict.
OLDSHA=2222222222222222222222222222222222222222
retargeted=$(inline "$CA" "Old finding, now fixed." null | jq --arg old "$OLDSHA" '.original_commit_id = $old | .id = 1001')
ack=$(inline "$CA" "Verified fixed on the new commit." 1001 | jq --arg old "$OLDSHA" '.original_commit_id = $old')
old_findings=$(jq -cn --argjson finding "$retargeted" --argjson ack "$ack" '[$finding,$ack]')
out=$(run_helper "$(payload "[$(review "$CA" APPROVED "")]" "$old_findings" "[\"$CA\"]")")
expect_eq "retargeted old finding plus hollow approval: applied" "$(jq -r .applied <<<"$out")" "true"
expect_eq "retargeted old finding: no HEAD verdict" "$(jq -c .verdicts_on_head <<<"$out")" "[]"
expect_eq "retargeted old finding: eligible" "$(jq -r .eligible <<<"$out")" "true"
expect_eq "retargeted old finding: elapsed window" "$(jq -r .reason <<<"$out")" "window_elapsed"
expect_eq "retargeted old finding: normal check anchor" "$(jq -r .anchor_source <<<"$out")" "earliest_head_check_start"
expect_eq "retargeted old finding: full window elapsed" "$(jq -r '.elapsed_seconds >= 600' <<<"$out")" "true"

# The inverse mismatch is not a current finding either.
inverse=$(inline "$CA" "Old location with current original ID." null | jq --arg old "$OLDSHA" '.commit_id = $old')
out=$(run_helper "$(payload '[]' "[$inverse]" '[]')")
expect_eq "old commit with current original: excluded" "$(jq -r .applied <<<"$out")" "true"

# Legacy absent original IDs follow review-substance's fallback to commit_id.
legacy=$(inline "$CA" "Current legacy finding." null | jq 'del(.original_commit_id)')
out=$(run_helper "$(payload '[]' "[$legacy]" '[]')")
expect_eq "absent original current finding: blocks" "$(jq -r .reason <<<"$out")" "verdict_on_head"
legacy_old=$(printf '%s' "$legacy" | jq --arg old "$OLDSHA" '.commit_id = $old')
out=$(run_helper "$(payload '[]' "[$legacy_old]" '[]')")
expect_eq "absent original old finding: excluded" "$(jq -r .applied <<<"$out")" "true"

# A fresh genuine top-level finding still blocks even beside the resolved old one.
mixed=$(jq -cn --argjson old "$retargeted" --argjson current "$(inline "$CA" "A new current finding." null)" '[$old,$current]')
out=$(run_helper "$(payload "[$(review "$CA" APPROVED "")]" "$mixed" "[\"$CA\"]")")
expect_eq "genuine current finding beside old finding: blocks" "$(jq -r .reason <<<"$out")" "verdict_on_head"
expect_eq "genuine current finding: verdict kind" "$(jq -r '.verdicts_on_head[0].kind' <<<"$out")" "inline_comment"

# Null uses the same legacy fallback; empty strings and missing current IDs do not.
null_original=$(printf '%s' "$legacy" | jq '.original_commit_id = null')
out=$(run_helper "$(payload '[]' "[$null_original]" '[]')")
expect_eq "null original current finding: blocks" "$(jq -r .reason <<<"$out")" "verdict_on_head"
empty_original=$(printf '%s' "$legacy" | jq '.original_commit_id = ""')
out=$(run_helper "$(payload '[]' "[$empty_original]" '[]')")
expect_eq "empty original current finding: excluded" "$(jq -r .applied <<<"$out")" "true"
missing_current=$(inline "$CA" "No current origin." null | jq 'del(.commit_id)')
out=$(run_helper "$(payload '[]' "[$missing_current]" '[]')")
expect_eq "missing current with HEAD original: excluded" "$(jq -r .applied <<<"$out")" "true"
out=$(run_helper "$(payload "[$(review "$CA" APPROVED "Reviewed this current change.")]" "$old_findings" '[]')")
expect_eq "real approval beside retargeted finding: blocks" "$(jq -r .reason <<<"$out")" "verdict_on_head"

echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
