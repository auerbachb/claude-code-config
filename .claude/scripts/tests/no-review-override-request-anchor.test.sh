#!/usr/bin/env bash
# no-review-override-request-anchor.test.sh — offline tests for the review-request
# anchor in no-review-override.sh (issue #2194). Drives the helper directly with
# a fake gh; the helper runs under the same bash that runs this file. Run under
# /bin/bash (3.2) and a 5.x bash.
# catalog: tests — Tests the review-request anchor of the no-review override in `no-review-override.sh` — anchor selection, fallbacks, window timing
# Run from repo root: bash .claude/scripts/tests/no-review-override-request-anchor.test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$SCRIPT_DIR/../no-review-override.sh"
[[ -f "$HELPER" ]] || { echo "FAIL: helper not found at $HELPER" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"
mkdir -p "$BIN"
cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"/pulls/1"*) printf '%s' "$FAKE_PULL_JSON"; exit 0 ;;
  *"/timeline"*) printf '%s' "[]"; exit 0 ;;
  *"actions/runs"*) printf '%s' "$FAKE_RUNS_JSON"; exit 0 ;;
  *"/issues/1/comments?per_page=100"*)
    printf '%s\n' comments >> "$FAKE_CALL_LOG"
    printf '%s' "$FAKE_FRESH_COMMENTS"
    exit "${FAKE_COMMENT_EXIT:-0}" ;;
esac
echo "fake gh: unexpected call: $*" >&2
exit 1
EOF
chmod +x "$BIN/gh"
export PATH="$BIN:$PATH" FAKE_CALL_LOG="$TMP/calls"

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $1 — $2"; }
expect_eq() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "got [$2] want [$3]"; fi; }

NOW=$(date -u +%s)
PUSH=$((NOW - 1800))          # HEAD pushed 30 min ago
CHECK=$((PUSH + 5))           # HEAD check-run started 5 s after the push
HEADSHA=1111111111111111111111111111111111111111
iso() { jq -rn --argjson s "$1" '$s | todateiso8601'; }

FAKE_PULL_JSON=$(jq -cn --arg c "$(iso $((NOW - 7200)))" \
  '{number:1, created_at:$c, draft:false, user:{login:"solo"}, head:{ref:"feature", repo:{full_name:"solo/repo"}}}')
export FAKE_PULL_JSON
FAKE_RUNS_JSON=$(jq -cn --arg t "$(iso $PUSH)" --arg h "$HEADSHA" \
  '{total_count:1, workflow_runs:[{event:"pull_request", created_at:$t, head_branch:"feature", head_sha:$h, head_repository:{full_name:"solo/repo"}}]}')
export FAKE_RUNS_JSON

# comment <login> <epoch seconds, or raw text> <body>
comment() {
  local when="$2"
  case "$when" in
    ''|*[!0-9]*) ;;
    *) when="$(iso "$when")" ;;
  esac
  jq -cn --arg u "$1" --arg t "$when" --arg b "$3" '{user:{login:$u}, body:$b, created_at:$t}'
}

# payload <issue_comments JSON array, or the literal null>
payload() {
  jq -cn --argjson c "$1" --arg cts "$(iso $((PUSH - 3600)))" --arg h "$HEADSHA" --arg chk "$(iso $CHECK)" '
    {owner:"solo", repo:"repo", pr:"1", head_sha:$h, commit_ts:$cts, window_seconds:600,
     tier_gate:"", review_blockers:["no AI reviewer verdict on HEAD"],
     reviews:[], pr_comments:[], issue_comments:$c,
     check_runs_raw:[{name:"build", status:"completed", conclusion:"success",
                      started_at:$chk, app:{slug:"github-actions"}}], hollow:[]}'
}

run_helper() {
  local payload="$1" pages
  pages=${2-$(jq -c .issue_comments <<<"$payload")}
  : > "$FAKE_CALL_LOG"
  printf '%s' "$payload" | FAKE_FRESH_COMMENTS="$pages" FAKE_COMMENT_EXIT="${3:-0}" "$BASH" "$HELPER"
}

# --- 1. No request: push anchor unchanged, window elapsed (auto-review repo) ---
out=$(run_helper "$(payload "[]")")
expect_eq "no request: applied" "$(jq -r .applied <<<"$out")" "true"
expect_eq "no request: anchor is the push-side check start" "$(jq -r .anchor_source <<<"$out")" "earliest_head_check_start"
expect_eq "no request: head_anchor_ts" "$(jq -r .head_anchor_ts <<<"$out")" "$(iso $CHECK)"
expect_eq "no request: request_ts null" "$(jq -r .request_ts <<<"$out")" "null"

# --- 2. Request after slow CI: window starts at the request, not the push ---
c=$(comment solo $((NOW - 300)) "@codeant-ai review")
before=$(date -u +%s)
out=$(run_helper "$(payload "[$c]")")
after=$(date -u +%s)
expect_eq "request after slow CI: anchor_source" "$(jq -r .anchor_source <<<"$out")" "review_request"
expect_eq "request after slow CI: head_anchor_ts is the request" "$(jq -r .head_anchor_ts <<<"$out")" "$(iso $((NOW - 300)))"
expect_eq "request after slow CI: request_ts" "$(jq -r .request_ts <<<"$out")" "$(iso $((NOW - 300)))"
expect_eq "request after slow CI: window still running" "$(jq -r .reason <<<"$out")" "window_running"
expect_eq "request after slow CI: not applied" "$(jq -r .applied <<<"$out")" "false"
el=$(jq -r .elapsed_seconds <<<"$out")
if (( el >= 300 + before - NOW && el <= 300 + after - NOW )); then ok "request after slow CI: elapsed from request (${el}s)"; else bad "request after slow CI: elapsed" "got $el want $((300 + before - NOW))..$((300 + after - NOW))"; fi

# --- 3. Full-review spelling and surrounding whitespace match ---
c=$(comment solo $((NOW - 300)) "   @coderabbitai full review  ")
out=$(run_helper "$(payload "[$c]")")
expect_eq "full review trigger counts" "$(jq -r .anchor_source <<<"$out")" "review_request"

# `full` is CodeRabbit's spelling only: `@codeant-ai full review` is not a request,
# so it must not anchor the window ahead of a later valid one.
c1=$(comment solo $((NOW - 900)) "@codeant-ai full review")
c2=$(comment solo $((NOW - 120)) "@codeant-ai review")
out=$(run_helper "$(payload "[$c1,$c2]")")
expect_eq "codeant 'full review' is not a request: valid request anchors" "$(jq -r .head_anchor_ts <<<"$out")" "$(iso $((NOW - 120)))"
expect_eq "codeant 'full review' is not a request: not applied" "$(jq -r .applied <<<"$out")" "false"
out=$(run_helper "$(payload "[$c1]")")
expect_eq "codeant 'full review' alone: push anchor" "$(jq -r .request_ts <<<"$out")" "null"

# --- 4. Two requests on one HEAD: the first wins, later ones never extend ---
c1=$(comment solo $((NOW - 400)) "@codeant-ai review")
c2=$(comment solo $((NOW - 60)) "@coderabbitai review")
out=$(run_helper "$(payload "[$c1,$c2]")")
expect_eq "two requests: first request anchors" "$(jq -r .head_anchor_ts <<<"$out")" "$(iso $((NOW - 400)))"
expect_eq "two requests: still running from the first" "$(jq -r .applied <<<"$out")" "false"

# --- 5. First request already older than the window: applied ---
c=$(comment solo $((NOW - 700)) "@codeant-ai review")
out=$(run_helper "$(payload "[$c]")")
expect_eq "old request: window elapsed from request" "$(jq -r .applied <<<"$out")" "true"
expect_eq "old request: reason" "$(jq -r .reason <<<"$out")" "window_elapsed"

# --- 6. Request on an older HEAD (before the push) is ignored ---
c=$(comment solo $((PUSH - 600)) "@codeant-ai review")
out=$(run_helper "$(payload "[$c]")")
expect_eq "old-HEAD request ignored: anchor_source" "$(jq -r .anchor_source <<<"$out")" "earliest_head_check_start"
expect_eq "old-HEAD request ignored: request_ts null" "$(jq -r .request_ts <<<"$out")" "null"

# --- 7. Trigger text from someone other than the PR author never moves the anchor ---
c=$(comment stranger $((NOW - 300)) "@codeant-ai review")
out=$(run_helper "$(payload "[$c]")")
expect_eq "non-author request ignored" "$(jq -r .anchor_source <<<"$out")" "earliest_head_check_start"

# --- 8. Quoted or prose triggers, and bot-authored text, never move the anchor ---
c1=$(comment 'coderabbitai[bot]' $((NOW - 300)) "@coderabbitai review")
c2=$(comment solo $((NOW - 300)) "please run @coderabbitai review now")
c3=$(comment solo $((NOW - 300)) "> @codeant-ai review")
out=$(run_helper "$(payload "[$c1,$c2,$c3]")")
expect_eq "bot and prose triggers ignored" "$(jq -r .anchor_source <<<"$out")" "earliest_head_check_start"

# --- 9. Fail closed: malformed timestamp on a matching request ---
c=$(comment solo "not-a-time" "@codeant-ai review")
out=$(run_helper "$(payload "[$c]")")
expect_eq "malformed request timestamp: not applied" "$(jq -r .applied <<<"$out")" "false"
expect_eq "malformed request timestamp: eligible" "$(jq -r .eligible <<<"$out")" "false"
case "$(jq -r .reason <<<"$out")" in
  anchor_malformed*) ok "malformed request timestamp: reason" ;;
  *) bad "malformed request timestamp: reason" "$(jq -r .reason <<<"$out")" ;;
esac

# --- 9b. An edited request counts at its latest edit, never its creation time ---
c=$(jq -cn --arg c "$(iso $((NOW - 1200)))" --arg u "$(iso $((NOW - 300)))" \
  '{user:{login:"solo"}, body:"@codeant-ai review", created_at:$c, updated_at:$u}')
out=$(run_helper "$(payload "[$c]")")
expect_eq "edited request: anchored at the edit" "$(jq -r .request_ts <<<"$out")" "$(iso $((NOW - 300)))"
expect_eq "edited request: still running from the edit" "$(jq -r .applied <<<"$out")" "false"

# --- 10. The decision-time read sees an edited request on a later page ---
c=$(jq -cn --arg c "$(iso $((NOW - 1200)))" --arg u "$(iso $((NOW - 300)))" \
  '{user:{login:"solo"}, body:"@codeant-ai review", created_at:$c, updated_at:$u}')
old=$(comment solo $((NOW - 1200)) "CI is running")
out=$(run_helper "$(payload "[$old]")" $'[]\n'"[$c]")
expect_eq "fresh second page: edit time anchors" "$(jq -r .request_ts <<<"$out")" "$(iso $((NOW - 300)))"
expect_eq "fresh second page: no waiver" "$(jq -r .applied <<<"$out")" "false"
expect_eq "one paginated read per evaluation" "$(cat "$FAKE_CALL_LOG")" "comments"

# --- 11. Fail closed: bad page shape, truncated JSON, missing author or HTTP failure ---
for pages in null $'[]\n{}' $'[]\n[' '[{"user":null,"body":"anything"}]' '[{"user":{"login":"solo"},"body":null}]'; do
  out=$(run_helper "$(payload '[]')" "$pages")
  expect_eq "bad fresh data holds ($pages)" "$(jq -r .reason <<<"$out")" "anchor_unavailable: comment list unreadable"
done
out=$(run_helper "$(payload '[]')" '[]' 1)
expect_eq "HTTP failure after a valid page holds" "$(jq -r .applied <<<"$out")" "false"
expect_eq "HTTP failure reason" "$(jq -r .reason <<<"$out")" "anchor_unavailable: comment list unreadable"

# --- 12. No additional comment read on early returns ---
for edit in '.window_seconds = null' '.review_blockers = []' '.tier_gate = "ci-only"' \
  '.reviews = [{user:{login:"codeant-ai[bot]"},commit_id:.head_sha,state:"CHANGES_REQUESTED"}]'; do
  run_helper "$(payload '[]' | jq -c "$edit")" '[]' 1 >/dev/null
  expect_eq "early return skips comment read ($edit)" "$(cat "$FAKE_CALL_LOG")" ""
done

# --- 13. Fail closed: unreadable comment list ---
out=$(run_helper "$(payload "null")")
expect_eq "unreadable comments: not applied" "$(jq -r .applied <<<"$out")" "false"
expect_eq "unreadable comments: reason" "$(jq -r .reason <<<"$out")" "anchor_unavailable: comment list unreadable"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
