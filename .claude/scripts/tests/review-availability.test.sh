#!/usr/bin/env bash
# review-availability.test.sh — offline fixture tests for review-availability.sh (issue #2256):
# notice recording, the request-skip decision, the recorded skip and its check. HOME is a
# throwaway directory, so no real session state is read or written. Run under /bin/bash (3.2)
# and a 5.x bash.
# catalog: tests — Tests the account-wide reviewer availability record and the request-skip decision in `review-availability.sh` — recording, decide, mark-skip, check-skip, fail-toward-asking cases
# Run from repo root: bash .claude/scripts/tests/review-availability.test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AV="$SCRIPT_DIR/../review-availability.sh"
[[ -f "$AV" ]] || { echo "FAIL: helper not found at $AV" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
mkdir -p "$HOME/.claude"
STATE_FILE="$HOME/.claude/session-state.json"

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $1 — $2"; }
expect_eq() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "got [$2] want [$3]"; fi; }

NOW=$(date -u +%s)
iso() { jq -rn --argjson s "$1" '$s | todateiso8601'; }
WIN=600   # no-review window: 10 minutes

# Writes a session-state file holding only the given review_availability object (JSON).
# state_with_av <json object>
state_with_av() {
  printf '{"schema_version":1,"review_availability":%s}\n' "$1" > "$STATE_FILE"
}
# av_record <next-available epoch> <notice epoch> — a usable record for one reviewer, as recorded.
av_record() {
  jq -cn --argjson n "$1" --argjson t "$2" \
    '{next_available_epoch: $n, next_available: ($n | todateiso8601), notice_epoch: $t, notice_at: ($t | todateiso8601),
      window_seconds: ($n - $t), notice_excerpt: "next review available in", source_repo: "o/r", source_pr: 1,
      read_at: ($t | todateiso8601)}'
}
# decide_at <now> [window] — prints the decide JSON for the current fixture state.
decide_at() { "$AV" decide --window-s "${2:-$WIN}" --now "$1"; }

# --- Expected response defaults and settings -------------------------------------------
dec=$(state_with_av "{\"coderabbit\":$(av_record $((NOW + 1200)) $NOW),\"codeant\":$(av_record $((NOW + 1200)) $NOW)}"; decide_at "$NOW")
expect_eq "default expected response: CodeRabbit 5 min" "$(jq -r '.expected_s.coderabbit' <<<"$dec")" "300"
expect_eq "default expected response: CodeAnt 4 min" "$(jq -r '.expected_s.codeant' <<<"$dec")" "240"
dec=$(REVIEW_EXPECTED_RESPONSE_CODERABBIT_MIN=1 "$AV" decide --window-s "$WIN" --now "$NOW")
expect_eq "setting honoured: CodeRabbit expected response from env" "$(jq -r '.expected_s.coderabbit' <<<"$dec")" "60"
dec=$(REVIEW_EXPECTED_RESPONSE_CODEANT_MIN=banana "$AV" decide --window-s "$WIN" --now "$NOW")
expect_eq "invalid setting falls back to the default" "$(jq -r '.expected_s.codeant' <<<"$dec")" "240"

# --- Decide: both free reviewers back late -> skip ----------------------------------------
state_with_av "{\"coderabbit\":$(av_record $((NOW + 1200)) $NOW),\"codeant\":$(av_record $((NOW + 1500)) $NOW)}"
dec=$(decide_at "$NOW")
expect_eq "reviewers back in 20 min: skip" "$(jq -r '.skip' <<<"$dec")" "true"
expect_eq "reviewers back in 20 min: reason names the earliest return" \
  "$(jq -r '.reason' <<<"$dec")" "no_reviewer_available_until $(iso $((NOW + 1200)))"

# --- Decide: CodeRabbit back in 3 min -> request as today ----------------------------------
state_with_av "{\"coderabbit\":$(av_record $((NOW + 180)) $NOW),\"codeant\":$(av_record $((NOW + 1500)) $NOW)}"
dec=$(decide_at "$NOW")
expect_eq "CodeRabbit back in 3 min (codeant late): request" "$(jq -r '.skip' <<<"$dec")" "false"
state_with_av "{\"coderabbit\":$(av_record $((NOW + 180)) $NOW),\"codeant\":$(av_record $((NOW + 180)) $NOW)}"
dec=$(decide_at "$NOW")
expect_eq "both back in 3 min: request" "$(jq -r '.skip' <<<"$dec")" "false"
expect_eq "both back in 3 min: reviewer reason is answers_within_window" \
  "$(jq -r '.reviewers.coderabbit.why' <<<"$dec")" "answers_within_window"

# --- Decide: stale record -> request -----------------------------------------------------
state_with_av "{\"coderabbit\":$(av_record $((NOW - 30)) $((NOW - 1500))),\"codeant\":$(av_record $((NOW + 1500)) $NOW)}"
dec=$(decide_at "$NOW")
expect_eq "stale CodeRabbit record (past next-available): request" "$(jq -r '.skip' <<<"$dec")" "false"
expect_eq "stale CodeRabbit record is reported as record_past" "$(jq -r '.reviewers.coderabbit.why' <<<"$dec")" "record_past"

# --- Decide: unreadable records -> request -----------------------------------------------
state_with_av '"garbage"'
dec=$(decide_at "$NOW")
expect_eq "non-object review_availability: request" "$(jq -r '.skip' <<<"$dec")" "false"
printf '{"review_availability": {"coderabbit": {"next_available_epoch": "soon"}}' > "$STATE_FILE"
dec=$(decide_at "$NOW")
expect_eq "malformed state file: request (state unreadable)" "$(jq -r '.skip' <<<"$dec")" "false"
state_with_av "{\"coderabbit\":{\"next_available_epoch\":\"soon\"},\"codeant\":$(av_record $((NOW + 1500)) $NOW)}"
dec=$(decide_at "$NOW")
expect_eq "malformed next-available value: request" "$(jq -r '.skip' <<<"$dec")" "false"
state_with_av "{\"coderabbit\":$(av_record $((NOW + 1200)) $NOW)}"
dec=$(decide_at "$NOW")
expect_eq "only CodeRabbit known limited (CodeAnt unknown): request" "$(jq -r '.skip' <<<"$dec")" "false"
expect_eq "unknown CodeAnt reads as no_record" "$(jq -r '.reviewers.codeant.why' <<<"$dec")" "no_record"

# --- Record: timed and untimed reviewer notices preserve their known evidence -----------
rm -f "$STATE_FILE"
T=$(iso $((NOW - 60)))
jq -cn --arg t "$T" '[{user:{login:"coderabbitai[bot]"},
  body:"**Review limit reached**\n**Next review available in:** **20 minutes**", created_at:$t, updated_at:$t}]' > "$TMP/banner.json"
out=$("$AV" record --repo o/r --pr 7 < "$TMP/banner.json") && rc=0 || rc=$?
expect_eq "record: banner accepted (exit 0)" "$rc" "0"
expect_eq "record: CodeRabbit written" "$(jq -c '.written' <<<"$out")" '["coderabbit"]'
expect_eq "record: next-available = banner time + 20 min" \
  "$(jq -r '.review_availability.coderabbit.next_available_epoch' "$STATE_FILE")" "$(( $(jq -rn --arg t "$T" '$t | fromdateiso8601') + 1200 ))"
expect_eq "record: source PR and repo kept" "$(jq -r '.review_availability.coderabbit.source_pr' "$STATE_FILE")" "7"

rm -f "$STATE_FILE"
jq -cn --arg t "$T" '[{user:{login:"coderabbitai[bot]"},
  body:"**Review limit reached** and then nothing readable about when", created_at:$t, updated_at:$t}]' > "$TMP/nowindow.json"
out=$("$AV" record --repo o/r --pr 7 < "$TMP/nowindow.json")
expect_eq "record: unparseable refusal retains provenance" "$(jq -c '.written' <<<"$out")" '["coderabbit"]'
expect_eq "record: untimed refusal has no fabricated deadline" "$(jq -r '.review_availability.coderabbit.next_available_epoch' "$STATE_FILE")" "null"

# A newer statement on file outranks an older notice (no overwrite with an older time).
state_with_av "{\"coderabbit\":$(av_record $((NOW + 3000)) $((NOW + 100)))}"
out=$("$AV" record --repo o/r --pr 8 < "$TMP/banner.json")
expect_eq "record: older notice does not overwrite a newer one" \
  "$(jq -r '.review_availability.coderabbit.next_available_epoch' "$STATE_FILE")" "$((NOW + 3000))"

# A newer untimed notice replaces stale timing with ranking evidence; decide still requests.
state_with_av "{\"coderabbit\":$(av_record $((NOW + 1200)) $((NOW - 600))),\"codeant\":$(av_record $((NOW + 1500)) $NOW)}"
jq -cn --arg t "$(iso $((NOW - 30)))" '[{user:{login:"coderabbitai[bot]"},
  body:"**Review limit reached** with no time given", created_at:$t, updated_at:$t}]' > "$TMP/untimed.json"
out=$("$AV" record --repo o/r --pr 7 < "$TMP/untimed.json")
expect_eq "untimed newer notice: CodeRabbit refusal retained" "$(jq -r '.review_availability.coderabbit.refusal_kind' "$STATE_FILE")" "untimed"
expect_eq "untimed newer notice: the other reviewer's record is untouched (no notice for it)" \
  "$(jq -r '.review_availability.codeant.next_available_epoch != null' "$STATE_FILE")" "true"
dec=$(decide_at "$NOW")
expect_eq "timed notice then newer untimed notice: decide requests" "$(jq -r '.skip' <<<"$dec")" "false"

# An OLDER untimed notice never clears a newer timed record.
state_with_av "{\"coderabbit\":$(av_record $((NOW + 1200)) $NOW),\"codeant\":$(av_record $((NOW + 1500)) $NOW)}"
jq -cn --arg t "$(iso $((NOW - 300)))" '[{user:{login:"coderabbitai[bot]"},
  body:"**Review limit reached** with no time given", created_at:$t, updated_at:$t}]' > "$TMP/older-untimed.json"
out=$("$AV" record --repo o/r --pr 7 < "$TMP/older-untimed.json")
expect_eq "older untimed notice: newer record kept, nothing cleared" "$(jq -c '.cleared' <<<"$out")" '[]'
dec=$(decide_at "$NOW")
expect_eq "older untimed notice: skip still decided from the newer record" "$(jq -r '.skip' <<<"$dec")" "true"

# A stored record without a notice time or window is unreadable: no skip from it (#2256).
state_with_av "{\"coderabbit\":{\"next_available_epoch\":$((NOW + 1500))},\"codeant\":$(av_record $((NOW + 1500)) $NOW)}"
dec=$(decide_at "$NOW")
expect_eq "record without notice time or window: reads as no_record" "$(jq -r '.reviewers.coderabbit.why' <<<"$dec")" "no_record"
expect_eq "record without notice time or window: request, not skip" "$(jq -r '.skip' <<<"$dec")" "false"

out=$(printf 'not json' | "$AV" record --repo o/r --pr 7 2>/dev/null) && rc=0 || rc=$?
expect_eq "record: malformed comments exit 4" "$rc" "4"

# --- Mark-skip and check-skip ------------------------------------------------------------
state_with_av "{\"coderabbit\":$(av_record $((NOW + 1200)) $NOW),\"codeant\":$(av_record $((NOW + 1500)) $NOW)}"
"$AV" mark-skip --repo o/r --pr 9 --head aaa111 --reason "no_reviewer_available_until x" >/dev/null
expect_eq "mark-skip: skip recorded on the PR, keyed by HEAD (repo-scoped)" \
  "$(jq -r '.repos["o/r"].prs["9"].review_request_skips["aaa111"].head_sha' "$STATE_FILE")" "aaa111"
out=$("$AV" check-skip --repo o/r --pr 9 --head aaa111 --window-s "$WIN" --now "$NOW")
expect_eq "check-skip: same HEAD, still in force: applies" "$(jq -r '.applies' <<<"$out")" "true"
out=$("$AV" check-skip --repo o/r --pr 9 --head bbb222 --window-s "$WIN" --now "$NOW")
expect_eq "check-skip: other HEAD does not apply" "$(jq -r '.applies' <<<"$out")" "false"
out=$("$AV" check-skip --repo o/r --pr 9 --head aaa111 --window-s "$WIN" --now $((NOW + 1400)))
expect_eq "check-skip: reviewer back in time since the skip (CodeRabbit at +1200, now +1400): does not apply" \
  "$(jq -r '.applies' <<<"$out")" "false"
out=$("$AV" check-skip --repo o/r --pr 9 --head aaa111 --window-s "$WIN" --now $((NOW + 60)))
expect_eq "check-skip: still unavailable a minute later: applies" "$(jq -r '.applies' <<<"$out")" "true"

# A late skip for an OLDER HEAD must not replace the current HEAD's skip (#4546742968).
state_with_av "{\"coderabbit\":$(av_record $((NOW + 1200)) $NOW),\"codeant\":$(av_record $((NOW + 1500)) $NOW)}"
"$AV" mark-skip --repo o/r --pr 9 --head bbb222 --reason "no_reviewer_available_until y" >/dev/null
"$AV" mark-skip --repo o/r --pr 9 --head aaa111 --reason "no_reviewer_available_until stale" >/dev/null
expect_eq "out-of-order skip: current HEAD's skip survives a stale HEAD's write" \
  "$(jq -r '.repos["o/r"].prs["9"].review_request_skips["bbb222"].reason' "$STATE_FILE")" "no_reviewer_available_until y"
out=$("$AV" check-skip --repo o/r --pr 9 --head bbb222 --window-s "$WIN" --now "$NOW")
expect_eq "out-of-order skip: current HEAD still applies after the stale write" "$(jq -r '.applies' <<<"$out")" "true"

# Replace only .review_availability: the PR 9 skip written above must still be on file, so the
# assertion below proves check-skip re-reads the availability and does not just find no skip.
jq --argjson c "$(av_record $((NOW + 180)) $NOW)" --argjson d "$(av_record $((NOW + 180)) $NOW)" \
  '.review_availability = {coderabbit: $c, codeant: $d}' "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
expect_eq "check-skip: the recorded skip is still on file" \
  "$(jq -r '.repos["o/r"].prs["9"].review_request_skips["aaa111"].head_sha' "$STATE_FILE")" "aaa111"
out=$("$AV" check-skip --repo o/r --pr 9 --head aaa111 --window-s "$WIN" --now "$NOW")
expect_eq "check-skip: record no longer justifies the skip: does not apply" "$(jq -r '.applies' <<<"$out")" "false"

printf '{"schema_version":1' > "$STATE_FILE"
out=$("$AV" check-skip --repo o/r --pr 9 --head aaa111 --window-s "$WIN" --now "$NOW")
expect_eq "check-skip: unreadable state fails closed" "$(jq -r '.applies' <<<"$out")" "false"

# --- Observe: a completed review newer than the read time clears that reviewer (#2256) ----
READ_T=$((NOW - 600))
rec_at() { # <record json> with read_at fixed to the epoch given
  jq -c --arg r "$(iso "$2")" '.read_at = $r' <<<"$1"
}
base_cr=$(av_record $((NOW + 1200)) $NOW)
base_cr=$(rec_at "$base_cr" "$READ_T")
base_cd=$(rec_at "$(av_record $((NOW + 1200)) $NOW)" "$READ_T")
state_with_av "{\"coderabbit\":$base_cr,\"codeant\":$base_cd}"
approved_now=$(jq -cn --arg t "$(iso $((NOW - 60)))" '[{user:{login:"coderabbitai[bot]"},state:"APPROVED",submitted_at:$t,body:"ok"}]')
out=$("$AV" observe --repo o/r <<<"$approved_now")
expect_eq "observe: CodeRabbit APPROVED after read time clears its record" "$(jq -c '.cleared' <<<"$out")" '["coderabbit"]'
expect_eq "observe: the other reviver's record is kept" "$(jq -r '.review_availability.codeant.next_available_epoch != null' "$STATE_FILE")" "true"
expect_eq "observe: cleared record reads as absent (a tombstone with no next-available time)" "$(jq -r '.review_availability.coderabbit.next_available_epoch' "$STATE_FILE")" "null"
expect_eq "observe: the tombstone names the notice it cleared" "$(jq -r '.review_availability.coderabbit.cleared_notice_epoch | type' "$STATE_FILE")" "number"
dec=$("$AV" decide --window-s "$WIN" --now "$NOW" --repo o/r)
expect_eq "observe: after a clear the skip no longer holds" "$(jq -r '.skip' <<<"$dec")" "false"

# A clear survives the next record run, which re-reads the same notice still in the PR.
# Without the tombstone, record would rewrite it with a fresh read time and the skip would
# return while CodeRabbit is answering (#2263 review).
rm -f "$STATE_FILE"
"$AV" record --repo o/r --pr 7 < "$TMP/banner.json" >/dev/null
jq --argjson d "$(av_record $((NOW + 1500)) $NOW)" '.review_availability.codeant = $d' "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
later=$(jq -cn --arg t "$(iso $(( $(date -u +%s) + 120 )))" '[{user:{login:"coderabbitai[bot]"},state:"APPROVED",submitted_at:$t,body:"ok"}]')
out=$("$AV" observe --repo o/r <<<"$later")
expect_eq "observe then record: the answered reviewer is cleared" "$(jq -c '.cleared' <<<"$out")" '["coderabbit"]'
"$AV" record --repo o/r --pr 7 < "$TMP/banner.json" >/dev/null
expect_eq "observe then record: the same old notice is not written again" \
  "$(jq -r '.review_availability.coderabbit.next_available_epoch' "$STATE_FILE")" "null"
dec=$("$AV" decide --window-s "$WIN" --now "$NOW" --repo o/r)
expect_eq "observe then record: the skip stays off" "$(jq -r '.skip' <<<"$dec")" "false"
T2=$(iso $((NOW + 30)))
jq -cn --arg t "$T2" '[{user:{login:"coderabbitai[bot]"},
  body:"**Review limit reached**\n**Next review available in:** **20 minutes**", created_at:$t, updated_at:$t}]' > "$TMP/banner-newer.json"
"$AV" record --repo o/r --pr 7 < "$TMP/banner-newer.json" >/dev/null
expect_eq "a newer notice after the clear is recorded again" \
  "$(jq -r '.review_availability.coderabbit.next_available_epoch | type' "$STATE_FILE")" "number"

state_with_av "{\"coderabbit\":$base_cr,\"codeant\":$base_cd}"
banner_now=$(jq -cn --arg t "$(iso $((NOW - 60)))" '[{user:{login:"coderabbitai[bot]"},state:"COMMENTED",submitted_at:$t,body:"Review limit reached. Next review available in 20 minutes."}]')
out=$("$AV" observe --repo o/r <<<"$banner_now")
expect_eq "observe: a CodeRabbit limit notice as a review does not clear" "$(jq -c '.cleared' <<<"$out")" '[]'
old_approve=$(jq -cn --arg t "$(iso $((READ_T - 60)))" '[{user:{login:"coderabbitai[bot]"},state:"APPROVED",submitted_at:$t,body:""}]')
out=$("$AV" observe --repo o/r <<<"$old_approve")
expect_eq "observe: a review older than the read time does not clear" "$(jq -c '.cleared' <<<"$out")" '[]'
human=$(jq -cn --arg t "$(iso $((NOW - 60)))" '[{user:{login:"someone"},state:"APPROVED",submitted_at:$t,body:""}]')
out=$("$AV" observe --repo o/r <<<"$human")
expect_eq "observe: a human review does not clear a bot's record" "$(jq -c '.cleared' <<<"$out")" '[]'
codeant_cmt=$(jq -cn --arg t "$(iso $((NOW - 60)))" '[{user:{login:"codeant-ai[bot]"},state:"COMMENTED",submitted_at:$t,body:"Review finished, no issues."}]')
out=$("$AV" observe --repo o/r <<<"$codeant_cmt")
expect_eq "observe: a CodeAnt non-notice review clears only CodeAnt" "$(jq -c '.cleared' <<<"$out")" '["codeant"]'

state_with_av "{\"coderabbit\":$base_cr,\"codeant\":$base_cd}"
"$AV" observe --repo o/r <<<'{"not":"an array"}' >/dev/null 2>&1 && rc=0 || rc=$?
expect_eq "observe: malformed reviews exit 4" "$rc" "4"
expect_eq "observe: malformed reviews clear nothing" "$(jq -r '.review_availability.coderabbit.next_available_epoch != null' "$STATE_FILE")" "true"



# A walkthrough discussing the notice is not itself an explicit refusal.
rm -f "$STATE_FILE"
jq -cn --arg t "$(iso $((NOW - 60)))" '[{user:{login:"coderabbitai[bot]"},body:"The change preserves Review rate limited. notices and improves reviewer selection.",created_at:$t,updated_at:$t}]' > "$TMP/discussion.json"
out=$("$AV" record --repo other/repo --pr 1213 < "$TMP/discussion.json")
expect_eq "ordinary discussion of literal refusal is not a refusal" "$(jq -c '.written' <<<"$out")" '[]'


# Legacy broad matchers must not give ordinary prose the new untimed meaning.
for phrase in 'review limit reached handling' 'usage limit handling' 'rate limit handling'; do
  for login in 'coderabbitai[bot]' 'codeant-ai[bot]'; do
    rm -f "$STATE_FILE"
    discussion=$(jq -cn --arg t "$(iso $NOW)" --arg l "$login" --arg p "$phrase" '[{user:{login:$l},body:("This change improves " + $p + " and preserves the review queue."),created_at:$t,updated_at:$t}]')
    out=$("$AV" record --repo o/r --pr 7 <<<"$discussion")
    expect_eq "legacy prose creates no refusal: $login $phrase" "$(jq -c '.written' <<<"$out")" '[]'
  done
done
for login in 'coderabbitai[bot]' 'codeant-ai[bot]'; do
  rm -f "$STATE_FILE"
  notices=$(jq -cn --arg old "$(iso $((NOW - 60)))" --arg new "$(iso $NOW)" --arg l "$login" '[{user:{login:$l},body:"**Review limit reached**",created_at:$old,updated_at:$old},{user:{login:$l},body:"This change improves review limit reached handling and preserves the queue.",created_at:$new,updated_at:$new}]')
  "$AV" record --repo o/r --pr 7 <<<"$notices" >/dev/null
  key=coderabbit; [[ "$login" == 'codeant-ai[bot]' ]] && key=codeant
  expect_eq "newer prose in same page cannot hide real refusal: $login" "$(jq -r --arg k "$key" '.review_availability[$k].notice_epoch' "$STATE_FILE")" "$((NOW - 60))"
  before=$(jq -c '.review_availability' "$STATE_FILE")
  "$AV" record --repo o/r --pr 7 <<<"$(jq '[.[1]]' <<<"$notices")" >/dev/null
  expect_eq "prose-only refresh preserves existing refusal: $login" "$(jq -c '.review_availability' "$STATE_FILE")" "$before"
done
rm -f "$STATE_FILE"
banner=$(jq -cn --arg t "$(iso $NOW)" '[{user:{login:"coderabbitai[bot]"},body:"<!-- coderabbit-ai-generated:v1 -->\n<!-- This is an auto-generated comment: rate limited by coderabbit.ai -->\n> ## Review limit reached",created_at:$t,updated_at:$t},{user:{login:"codeant-ai[bot]"},body:"Usage limit reached. Please try later.",created_at:$t,updated_at:$t}]')
"$AV" record --repo o/r --pr 7 <<<"$banner" >/dev/null
expect_eq "opening generated banner and CodeAnt explicit refusal are retained" "$(jq -r '[.review_availability[].refusal_kind]|unique|join(",")' "$STATE_FILE")" "untimed"
expect_eq "both explicit reviewer records written" "$(jq -r '.review_availability|length' "$STATE_FILE")" "2"
rm -f "$STATE_FILE"
prose_banner=$(jq -cn --arg t "$(iso $NOW)" '[{user:{login:"coderabbitai[bot]"},body:"This change documents the following marker.\n<!-- rate limited by coderabbit.ai -->",created_at:$t,updated_at:$t}]')
out=$("$AV" record --repo o/r --pr 7 <<<"$prose_banner")
expect_eq "generated marker quoted after prose is not a refusal" "$(jq -c '.written' <<<"$out")" '[]'
rate_notice=$(jq -cn --arg t "$(iso $NOW)" '[{user:{login:"codeant-ai[bot]"},body:"Rate limit exceeded. Please try later.",created_at:$t,updated_at:$t}]')
"$AV" record --repo o/r --pr 7 <<<"$rate_notice" >/dev/null
expect_eq "explicit CodeAnt rate refusal retained" "$(jq -r '.review_availability.codeant.refusal_kind' "$STATE_FILE")" "untimed"

# Timed legacy wording keeps its existing interpretation without a new opening guard.
rm -f "$STATE_FILE"
timed=$(jq -cn --arg t "$(iso $NOW)" '[{user:{login:"codeant-ai[bot]"},body:"Notice: usage limit reached. Next review available in 20 minutes.",created_at:$t,updated_at:$t}]')
"$AV" record --repo o/r --pr 7 <<<"$timed" >/dev/null
expect_eq "dated legacy CodeAnt notice retains parsed deadline" "$(jq -r '.review_availability.codeant.next_available_epoch' "$STATE_FILE")" "$((NOW + 1200))"

# Literal production notice, provenance, and conservative recovery (#2336).
rm -f "$STATE_FILE"
jq -cn --arg t "$(iso $((NOW - 60)))" '[{user:{login:"coderabbitai[bot]"},body:"Review rate limited.",created_at:$t,updated_at:$t}]' > "$TMP/literal.json"
"$AV" record --repo other/repo --pr 1213 < "$TMP/literal.json" >/dev/null
expect_eq "literal refusal: source repo preserved account-wide" "$(jq -r '.review_availability.coderabbit.source_repo' "$STATE_FILE")" "other/repo"
expect_eq "literal refusal: no next-available timestamp" "$(jq -r '.review_availability.coderabbit.next_available' "$STATE_FILE")" "null"
for body in '' 'Review triggered. Your full review will begin shortly.' 'Review rate limited. All analysis steps were skipped.' 'Automatically resolved outdated comments from an earlier review.'; do
  review=$(jq -cn --arg b "$body" --arg t "$(iso $((NOW + 120)))" '[{user:{login:"coderabbitai[bot]"},state:"APPROVED",commit_id:("a"*40),submitted_at:$t,body:$b}]')
  out=$("$AV" observe --repo other/repo <<<"$review")
  expect_eq "untimed recovery refuses blank/ACK/refusal/auto-resolution: $body" "$(jq -c '.cleared' <<<"$out")" '[]'
done
review=$(jq -cn --arg t "$(iso $((NOW - 120)))" '[{user:{login:"coderabbitai[bot]"},state:"APPROVED",commit_id:("a"*40),submitted_at:$t,body:"Reviewed the changed selector and regression tests; no actionable findings."}]')
out=$("$AV" observe --repo other/repo <<<"$review")
expect_eq "old substantive review cannot clear newer refusal" "$(jq -c '.cleared' <<<"$out")" '[]'
review=$(jq -cn --arg t "$(iso $((NOW + 120)))" '[{user:{login:"coderabbitai[bot]"},state:"APPROVED",commit_id:("a"*40),submitted_at:$t,body:"Reviewed the changed selector and regression tests; no actionable findings."}]')
for state in PENDING DISMISSED; do
  out=$(jq --arg s "$state" '.[0].state=$s' <<<"$review" | "$AV" observe --repo other/repo)
  expect_eq "unfinished/dismissed review cannot clear refusal: $state" "$(jq -c '.cleared' <<<"$out")" '[]'
done
out=$("$AV" observe --repo other/repo <<<"$review")
expect_eq "fresh substantive formal review clears untimed refusal" "$(jq -c '.cleared' <<<"$out")" '["coderabbit"]'
"$AV" record --repo other/repo --pr 1213 < "$TMP/literal.json" >/dev/null
expect_eq "cleared untimed refusal cannot resurrect from the same notice" "$(jq -r '.review_availability.coderabbit.refusal_kind' "$STATE_FILE")" "null"


# A parsed zero-minute reset is known timing, not an unknown refusal (6871668555 #1).
for login in 'coderabbitai[bot]' 'codeant-ai[bot]'; do
  rm -f "$STATE_FILE"
  zero=$(jq -cn --arg t "$(iso $NOW)" --arg l "$login" '[{user:{login:$l},body:"Review limit reached. Next review available in 0 minutes.",created_at:$t,updated_at:$t}]')
  out=$("$AV" record --repo o/r --pr 7 <<<"$zero")
  expect_eq "zero-minute reset creates no unknown refusal: $login" "$(jq -c '.written' <<<"$out")" '[]'
  older=$(jq -cn --arg t "$(iso $((NOW - 60)))" --arg l "$login" '[{user:{login:$l},body:"**Review limit reached**",created_at:$t,updated_at:$t}]')
  "$AV" record --repo o/r --pr 7 <<<"$older" >/dev/null
  "$AV" record --repo o/r --pr 7 <<<"$zero" >/dev/null
  key=coderabbit; [[ "$login" == 'codeant-ai[bot]' ]] && key=codeant
  expect_eq "new zero-minute reset clears prior unknown refusal: $login" "$(jq -r --arg k "$key" '.review_availability[$k].refusal_kind' "$STATE_FILE")" 'null'
done

# A valid recovery after the refusal but before discovery must count (6871668555 #2).
rm -f "$STATE_FILE"
"$AV" record --repo other/repo --pr 1213 < "$TMP/literal.json" >/dev/null
recovered=$(jq -cn --arg t "$(iso $((NOW - 30)))" '[{user:{login:"coderabbitai[bot]"},state:"APPROVED",commit_id:("a"*40),submitted_at:$t,body:"Reviewed the changed selector and regression tests; no actionable findings."}]')
out=$("$AV" observe --repo other/repo <<<"$recovered")
expect_eq "post-notice pre-discovery substantive recovery clears refusal" "$(jq -c '.cleared' <<<"$out")" '["coderabbit"]'
"$AV" record --repo other/repo --pr 1213 < "$TMP/literal.json" >/dev/null
expect_eq "pre-discovery recovery tombstone prevents replay" "$(jq -r '.review_availability.coderabbit.refusal_kind' "$STATE_FILE")" 'null'
# After a newer refusal arrives, the same successful review cannot clear it.
newer=$(jq -cn --arg t "$(iso $((NOW - 10)))" '[{user:{login:"coderabbitai[bot]"},body:"Review rate limited.",created_at:$t,updated_at:$t}]')
"$AV" record --repo other/repo --pr 1213 <<<"$newer" >/dev/null
out=$("$AV" observe --repo other/repo <<<"$recovered")
expect_eq "newer refusal survives earlier recovery replay" "$(jq -c '.cleared' <<<"$out")" '[]'


# Substantive prose may discuss the review machinery without being an acknowledgment.
for body in 'Reviewed the review request chooser and regression tests; no actionable findings.' 'Reviewed rate limit handling and queued review request tests; no actionable findings.' $'<!-- coderabbit-ai-generated:v1 -->\n\nReviewed the review request chooser and regression tests; no actionable findings.'; do
  rm -f "$STATE_FILE"
  "$AV" record --repo one/repo --pr 1 < "$TMP/literal.json" >/dev/null
  valid=$(jq -cn --arg b "$body" --arg t "$(iso $((NOW - 30)))" '[{user:{login:"coderabbitai[bot]"},state:"APPROVED",commit_id:("a"*40),submitted_at:$t,body:$b}]')
  out=$("$AV" observe --repo one/repo <<<"$valid")
  expect_eq "substantive recovery accepts review-request prose: $body" "$(jq -c '.cleared' <<<"$out")" '["coderabbit"]'
done
for body in 'Review request has been queued. The analysis will begin shortly.' 'Review requested. The complete analysis will begin shortly.' $'<!-- coderabbit-ai-generated:v1 -->\n\nReview request has been queued. The analysis will begin shortly.' $'<!-- coderabbit-ai-generated:v1 -->\n\nReview rate limited.' $'<!-- coderabbit-ai-generated:v1 -->\n<!-- review-status:complete -->' $'<!-- coderabbit-ai-generated:v1 -->\n<!-- review-status:complete -->\nLGTM'; do
  rm -f "$STATE_FILE"
  "$AV" record --repo one/repo --pr 1 < "$TMP/literal.json" >/dev/null
  ack=$(jq -cn --arg b "$body" --arg t "$(iso $((NOW - 30)))" '[{user:{login:"coderabbitai[bot]"},state:"APPROVED",commit_id:("a"*40),submitted_at:$t,body:$b}]')
  out=$("$AV" observe --repo one/repo <<<"$ack")
  expect_eq "opening acknowledgment cannot recover: $body" "$(jq -c '.cleared' <<<"$out")" '[]'
done

# Recovery is account-wide event evidence, including notices first seen on another PR.
rm -f "$STATE_FILE"
"$AV" record --repo one/repo --pr 1 < "$TMP/literal.json" >/dev/null
recoveries=$(jq -cn --arg a "$(iso $((NOW - 40)))" --arg b "$(iso $((NOW - 30)))" '[$b,$a]|map({user:{login:"coderabbitai[bot]"},state:"APPROVED",commit_id:("a"*40),submitted_at:.,body:"Reviewed the selector and regression tests; no actionable findings."})')
"$AV" observe --repo one/repo <<<"$recoveries" >/dev/null
expect_eq "recovery stores max qualifying event time, not discovery" "$(jq -r '.review_availability.coderabbit.recovery_epoch' "$STATE_FILE")" "$((NOW - 30))"
for t in "$((NOW - 45))" "$((NOW - 30))"; do
  hidden=$(jq -cn --arg t "$(iso "$t")" '[{user:{login:"coderabbitai[bot]"},body:"Review rate limited.",created_at:$t,updated_at:$t}]')
  "$AV" record --repo two/repo --pr 2 <<<"$hidden" >/dev/null
  expect_eq "cross-PR untimed notice at/before recovery cannot resurrect: $t" "$(jq -r '.review_availability.coderabbit.refusal_kind' "$STATE_FILE")" null
done
later_review=$(jq --arg t "$(iso $((NOW - 20)))" '.[0].submitted_at=$t|.[0:1]' <<<"$recoveries")
"$AV" observe --repo one/repo <<<"$later_review" >/dev/null
expect_eq "new substantive review advances existing recovery tombstone" "$(jq -r '.review_availability.coderabbit.recovery_epoch' "$STATE_FILE")" "$((NOW - 20))"
# Timed evidence remains governed by its old notice boundary, not the untimed watermark.
timed=$(jq -cn --arg t "$(iso $((NOW - 25)))" '[{user:{login:"coderabbitai[bot]"},body:"Review limit reached. Next review available in 20 minutes.",created_at:$t,updated_at:$t}]')
"$AV" record --repo two/repo --pr 2 <<<"$timed" >/dev/null
expect_eq "recovery watermark does not reject legacy timed notice" "$(jq -r '.review_availability.coderabbit.window_seconds' "$STATE_FILE")" 1200
zero=$(jq -cn --arg t "$(iso $((NOW - 15)))" '[{user:{login:"coderabbitai[bot]"},body:"Review limit reached. Next review available in 0 minutes.",created_at:$t,updated_at:$t}]')
"$AV" record --repo two/repo --pr 2 <<<"$zero" >/dev/null
expect_eq "known zero clears timing while preserving proven recovery" "$(jq -r '.review_availability.coderabbit|[.next_available_epoch,.recovery_epoch]|@json' "$STATE_FILE")" "[null,$((NOW - 20))]"
"$AV" record --repo two/repo --pr 2 <<<"$hidden" >/dev/null
expect_eq "intermediate record replacement cannot erase recovery watermark" "$(jq -r '.review_availability.coderabbit.refusal_kind' "$STATE_FILE")" null
"$AV" record --repo two/repo --pr 2 <<<"$newer" >/dev/null
expect_eq "untimed refusal after successful recovery remains valid" "$(jq -r '.review_availability.coderabbit.notice_epoch' "$STATE_FILE")" "$((NOW - 10))"

# --- Usage ---------------------------------------------------------------------------------
"$AV" decide --window-s 0 >/dev/null 2>&1 && rc=0 || rc=$?
expect_eq "decide: zero window is a usage error" "$rc" "2"
"$AV" bogus >/dev/null 2>&1 && rc=0 || rc=$?
expect_eq "unknown subcommand is a usage error" "$rc" "2"

echo
echo "review-availability tests: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
