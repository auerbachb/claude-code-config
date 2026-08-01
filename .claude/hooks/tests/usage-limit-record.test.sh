#!/usr/bin/env bash
# Tests for usage-limit-record.sh — the StopFailure recorder (issue #824).
#
# Covers the behavior the issue's Test Plan requires: the recorder fires only
# on the upstream rate-limit signal, a healthy session is completely
# unaffected, and no code path computes a local spend estimate.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
HOOK="$REPO_ROOT/.claude/hooks/usage-limit-record.sh"
SETTINGS="$REPO_ROOT/global-settings.json"
SETUP_SCRIPT="$REPO_ROOT/setup-skills-worktree.sh"
AUDIT_DOC="$REPO_ROOT/.claude/reference/usage-limit-signal-audit-2026-07.md"
SAFETY_RULE="$REPO_ROOT/.claude/rules/safety.md"

fail() { echo "FAIL: $*" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

run_hook() {
  # $1 = JSON payload. Both dirs are isolated so tests never touch ~/.claude:
  # CLAUDE_USAGE_LIMIT_DIR for the hook's own records, CLAUDE_HANDOFF_DIR for
  # the portable-handoff lookup. Leaving the latter unset would read the
  # developer's real ~/.claude/handoffs, making resume_hint depend on whether
  # they happen to have run /pause — green here, different there.
  printf '%s' "$1" \
    | CLAUDE_USAGE_LIMIT_DIR="$TMP_DIR" CLAUDE_HANDOFF_DIR="$TMP_DIR/handoffs" bash "$HOOK"
}

EVENTS="$TMP_DIR/usage-limit-events.jsonl"
LAST="$TMP_DIR/usage-limit-last.json"

# --- 1. Executable ---
[[ -x "$HOOK" ]] || fail "hook is not executable"

# --- 2. Fires on the upstream rate_limit signal ---
run_hook '{"hook_event_name":"StopFailure","error":"rate_limit","session_id":"sess-abc","cwd":"/tmp/work","transcript_path":"/tmp/t.jsonl","last_assistant_message":"was mid-fix on PR #1"}'

[[ -f "$EVENTS" ]] || fail "rate_limit did not append to the events log"
[[ -f "$LAST" ]] || fail "rate_limit did not write usage-limit-last.json"
[[ "$(wc -l <"$EVENTS" | tr -d ' ')" == "1" ]] || fail "expected exactly one event record"

jq -e '.reason == "rate_limit"' "$LAST" >/dev/null || fail "record reason is not rate_limit"
jq -e '.session_id == "sess-abc"' "$LAST" >/dev/null || fail "session_id not captured"
jq -e '.transcript_path == "/tmp/t.jsonl"' "$LAST" >/dev/null || fail "transcript_path not captured"
jq -e '.cwd == "/tmp/work"' "$LAST" >/dev/null || fail "cwd not captured"
jq -e '.last_assistant_message | test("mid-fix")' "$LAST" >/dev/null || fail "last_assistant_message not captured"
jq -e '.resume_hint | length > 0' "$LAST" >/dev/null || fail "resume_hint missing"
jq -e '.recorded_at | length > 0' "$LAST" >/dev/null || fail "recorded_at missing"

# The durable log is what a later session actually reads — assert the record
# landed there with its context, not just that usage-limit-last.json is right.
jq -e '.reason == "rate_limit"' <"$EVENTS" >/dev/null || fail "events record reason is not rate_limit"
jq -e '.session_id == "sess-abc"' <"$EVENTS" >/dev/null || fail "events record lost session_id"
jq -e '.transcript_path == "/tmp/t.jsonl"' <"$EVENTS" >/dev/null || fail "events record lost transcript_path"
jq -e '.cwd == "/tmp/work"' <"$EVENTS" >/dev/null || fail "events record lost cwd"

# --- 3. Healthy session unaffected: non-rate-limit errors record nothing ---
# A drifted/removed matcher must not turn every API failure into a usage-limit
# record. Each of these is a real StopFailure `error` value from the runtime.
# Snapshot BOTH files by content: a line-count check alone would miss a
# non-rate-limit error overwriting usage-limit-last.json.
EVENTS_SNAP="$(cat "$EVENTS")"
LAST_SNAP="$(cat "$LAST")"
for other in overloaded authentication_failed billing_error server_error max_output_tokens unknown; do
  run_hook "{\"hook_event_name\":\"StopFailure\",\"error\":\"$other\",\"session_id\":\"s\"}"
done
[[ "$(cat "$EVENTS")" == "$EVENTS_SNAP" ]] || fail "a non-rate_limit error mutated the events log"
[[ "$(cat "$LAST")" == "$LAST_SNAP" ]] || fail "a non-rate_limit error mutated usage-limit-last.json"

# --- 4. Malformed / empty payloads never append a broken line ---
run_hook 'not json at all'
run_hook '{}'
run_hook ''
[[ "$(cat "$EVENTS")" == "$EVENTS_SNAP" ]] || fail "a malformed payload mutated the events log"
[[ "$(cat "$LAST")" == "$LAST_SNAP" ]] || fail "a malformed payload mutated usage-limit-last.json"
while read -r line; do
  printf '%s' "$line" | jq -e . >/dev/null 2>&1 || fail "events log contains a non-JSON line"
done <"$EVENTS"

# --- 5. Long fields are truncated (resume hint, not a transcript dump) ---
# Assert the new record was actually written before asserting its length —
# checking length alone would pass against the *previous* record if this
# invocation silently recorded nothing.
LONG=$(printf 'x%.0s' $(seq 1 5000))
run_hook "{\"hook_event_name\":\"StopFailure\",\"error\":\"rate_limit\",\"last_assistant_message\":\"$LONG\"}"
[[ "$(wc -l <"$EVENTS" | tr -d ' ')" == "2" ]] || fail "long-field invocation did not append a second record"
jq -e '.last_assistant_message | test("^x+$")' "$LAST" >/dev/null \
  || fail "usage-limit-last.json does not hold the long-field record"
LEN=$(jq -r '.last_assistant_message | length' "$LAST")
[[ "$LEN" -le 1000 ]] || fail "last_assistant_message not truncated (len=$LEN)"

# --- 6. Registration: one entry carrying matcher + command + timeout together ---
# Checked as a single conjunction on purpose. Split assertions would accept a
# matcher on one group and the timeout on another — a registration that looks
# valid to the tests but is not the one the runtime fires.
python3 - "$SETTINGS" <<'PY' || fail "no single StopFailure entry has matcher rate_limit + usage-limit-record.sh + timeout 5"
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
ok = any(
    g.get("matcher") == "rate_limit"
    and any(
        h.get("command", "").endswith("usage-limit-record.sh") and h.get("timeout") == 5
        for h in g.get("hooks", [])
    )
    for g in data.get("hooks", {}).get("StopFailure", [])
)
sys.exit(0 if ok else 1)
PY

# --- 7. Registration: HOOKS_MANIFEST entry, timeout must match global-settings.json ---
# Two sources of truth for the same timeout; they drift silently otherwise.
grep -qF "StopFailure"$'\t'"rate_limit"$'\t'"usage-limit-record.sh"$'\t'"5" "$SETUP_SCRIPT" \
  || grep -qF "StopFailure\\trate_limit\\tusage-limit-record.sh\\t5" "$SETUP_SCRIPT" \
  || fail "HOOKS_MANIFEST missing StopFailure/rate_limit entry for usage-limit-record.sh with timeout 5"

# --- 8. No local spend/quota estimation in any executable line ---
# The whole point of the issue: the trigger must be the upstream signal only.
# Comments are stripped first — the hook's own header *describes* the ban, and
# matching that prose would fail the test for saying the right thing.
CODE_ONLY="$TMP_DIR/hook-code-only.sh"
sed -e 's/[[:space:]]*#.*$//' "$HOOK" | grep -v '^[[:space:]]*$' >"$CODE_ONLY"
if grep -nEi 'input_tokens|output_tokens|cache_read|used_percentage|spend|budget_remaining|estimate' "$CODE_ONLY"; then
  fail "hook computes/reads token or spend accounting — the trigger must be the upstream error signal only"
fi

# --- 9. safety.md's quota prohibition is intact and unamended ---
grep -q 'MUST NOT gate agent decisions' "$SAFETY_RULE" \
  || fail "safety.md quota prohibition text is missing or was altered"

# --- 10. The gating finding doc exists and states the verdict ---
[[ -f "$AUDIT_DOC" ]] || fail "signal-investigation finding doc is missing"
grep -q 'Verdict' "$AUDIT_DOC" || fail "finding doc does not state a verdict"

# --- 11. State files are owner-only ---
# The record embeds conversation content and absolute paths.
# Switch on uname, matching the hook's own file_size() helper: GNU `stat -f`
# means "filesystem status" and SUCCEEDS with unrelated output, so a
# `stat -f ... || stat -c ...` fallback never reaches the GNU form on Linux.
file_mode() {
  if [[ "$(uname -s)" == "Darwin" ]]; then
    stat -f '%Lp' "$1" 2>/dev/null
  else
    stat -c '%a' "$1" 2>/dev/null
  fi
}
for f in "$EVENTS" "$LAST"; do
  MODE=$(file_mode "$f")
  [[ "$MODE" == "600" ]] || fail "$(basename "$f") is mode '$MODE', expected 600 (owner-only)"
done

# --- 12. Concurrent invocations lose no records ---
# This is the expected case, not an edge case: one account hitting its limit
# fails every active session at once.
CONC_DIR="$TMP_DIR/concurrent"
mkdir -p "$CONC_DIR"
N=25
for i in $(seq 1 "$N"); do
  printf '%s' "{\"hook_event_name\":\"StopFailure\",\"error\":\"rate_limit\",\"session_id\":\"s$i\"}" \
    | CLAUDE_USAGE_LIMIT_DIR="$CONC_DIR" CLAUDE_HANDOFF_DIR="$CONC_DIR/handoffs" bash "$HOOK" &
done
wait

CONC_LOG="$CONC_DIR/usage-limit-events.jsonl"
COUNT=$(wc -l <"$CONC_LOG" | tr -d ' ')
[[ "$COUNT" == "$N" ]] || fail "concurrent writes lost records: got $COUNT, expected $N"

while read -r line; do
  printf '%s' "$line" | jq -e . >/dev/null 2>&1 || fail "concurrent writes produced an interleaved/non-JSON line"
done <"$CONC_LOG"

UNIQ=$(jq -r '.session_id' "$CONC_LOG" | sort -u | wc -l | tr -d ' ')
[[ "$UNIQ" == "$N" ]] || fail "concurrent writes clobbered records: $UNIQ distinct sessions, expected $N"

[[ -d "$CONC_DIR/.usage-limit-record.lock" ]] && fail "lock directory was left behind"
true

# --- 13. Non-string fields are truncated too ---
# A structured error_details object must not bypass the breadcrumb limit.
STRUCT_DIR="$TMP_DIR/struct"
mkdir -p "$STRUCT_DIR"
BIG_VAL=$(printf 'y%.0s' $(seq 1 4000))
printf '%s' "{\"hook_event_name\":\"StopFailure\",\"error\":\"rate_limit\",\"error_details\":{\"blob\":\"$BIG_VAL\"},\"last_assistant_message\":{\"nested\":\"$BIG_VAL\"}}" \
  | CLAUDE_USAGE_LIMIT_DIR="$STRUCT_DIR" CLAUDE_HANDOFF_DIR="$STRUCT_DIR/handoffs" bash "$HOOK"

STRUCT_LAST="$STRUCT_DIR/usage-limit-last.json"
[[ -f "$STRUCT_LAST" ]] || fail "structured payload produced no record"
jq -e . "$STRUCT_LAST" >/dev/null || fail "structured payload produced invalid JSON"
ED_LEN=$(jq -r '.error_details | length' "$STRUCT_LAST")
LAM_LEN=$(jq -r '.last_assistant_message | length' "$STRUCT_LAST")
[[ "$ED_LEN" -le 500 ]] || fail "object error_details not truncated (len=$ED_LEN)"
[[ "$LAM_LEN" -le 1000 ]] || fail "object last_assistant_message not truncated (len=$LAM_LEN)"

# --- 14. Rotation fires at the cap and preserves the archive ---
ROT_DIR="$TMP_DIR/rotate"
mkdir -p "$ROT_DIR"
ROT_LOG="$ROT_DIR/usage-limit-events.jsonl"
# Seed just past the 256 KiB cap so the next append must rotate.
head -c 262200 /dev/zero | tr '\0' 'a' >"$ROT_LOG"
printf '\n' >>"$ROT_LOG"
printf '%s' '{"hook_event_name":"StopFailure","error":"rate_limit","session_id":"rot","last_assistant_message":"em—dashes—are—multibyte"}' \
  | CLAUDE_USAGE_LIMIT_DIR="$ROT_DIR" CLAUDE_HANDOFF_DIR="$ROT_DIR/handoffs" bash "$HOOK"

[[ -f "$ROT_LOG.1" ]] || fail "rotation did not create the .1 archive"
[[ "$(wc -l <"$ROT_LOG" | tr -d ' ')" == "1" ]] || fail "post-rotation log should hold exactly the new record"
jq -e '.session_id == "rot"' <"$ROT_LOG" >/dev/null || fail "post-rotation log lost the new record"

# --- 15. Portable handoff pointer (issue #901) ---------------------------
# The breadcrumb should name the document /pause already wrote, when there is
# one. This is a filesystem lookup only — see the code-body grep in case 8,
# which also covers the lines added for this.
BASE_HINT="Turn ended on an Anthropic usage limit. Reconstruct in-flight state from the transcript above, then resume; see .claude/reference/usage-limit-signal-audit-2026-07.md."

# Fixture mtimes MUST be derived from the current clock. The hook filters with
# `find -mtime -N`, which is relative to now, so a hard-coded calendar date is a
# time bomb: fine on the day it is written, then silently future-dated before it
# and aged out after it. `date -r` is BSD, `date -d @` is GNU.
stamp_ago() { # $1 = seconds before now -> YYYYMMDDhhmm for `touch -t`
  local epoch=$(( $(date -u +%s) - $1 ))
  date -u -r "$epoch" +%Y%m%d%H%M 2>/dev/null && return 0
  date -u -d "@$epoch" +%Y%m%d%H%M 2>/dev/null && return 0
  return 1
}
touch_ago() { local when; when=$(stamp_ago "$2") || fail "cannot compute a relative timestamp on this platform"; touch -t "$when" "$1"; }

# 15a. No handoff on disk: byte-identical to the hint this hook always wrote.
# Asserted as full equality, not a substring — an appended sentence in the
# no-handoff case is exactly the regression this pins down.
NONE_DIR="$TMP_DIR/handoff-none"
mkdir -p "$NONE_DIR"
printf '%s' '{"hook_event_name":"StopFailure","error":"rate_limit","session_id":"none"}' \
  | CLAUDE_USAGE_LIMIT_DIR="$NONE_DIR" CLAUDE_HANDOFF_DIR="$NONE_DIR/handoffs" bash "$HOOK"
NONE_LAST="$NONE_DIR/usage-limit-last.json"
[[ -f "$NONE_LAST" ]] || fail "no-handoff case produced no record"
GOT_HINT=$(jq -r '.resume_hint' "$NONE_LAST")
[[ "$GOT_HINT" == "$BASE_HINT" ]] \
  || fail "resume_hint changed when no portable handoff exists:"$'\n'"got:  $GOT_HINT"$'\n'"want: $BASE_HINT"
jq -e '.portable_handoff == null' "$NONE_LAST" >/dev/null \
  || fail "portable_handoff should be null when none is on disk"

# 15b. An empty handoffs directory is the same as no directory at all.
EMPTY_DIR="$TMP_DIR/handoff-empty"
mkdir -p "$EMPTY_DIR/handoffs"
printf '%s' '{"hook_event_name":"StopFailure","error":"rate_limit","session_id":"empty"}' \
  | CLAUDE_USAGE_LIMIT_DIR="$EMPTY_DIR" CLAUDE_HANDOFF_DIR="$EMPTY_DIR/handoffs" bash "$HOOK"
[[ "$(jq -r '.resume_hint' "$EMPTY_DIR/usage-limit-last.json")" == "$BASE_HINT" ]] \
  || fail "an empty handoffs/ directory must not alter resume_hint"

# 15c. With handoffs present, the NEWEST by mtime is named. The newer file is
# given the LEXICALLY SMALLER name on purpose: with the name-based tie-break in
# play, naming the newer file `zzz` would let this pass even if mtime ordering
# were broken entirely.
SOME_DIR="$TMP_DIR/handoff-some"
mkdir -p "$SOME_DIR/handoffs"
OLDER="$SOME_DIR/handoffs/portable-handoff-zzz-older.md"
NEWER="$SOME_DIR/handoffs/portable-handoff-aaa-newer.md"
DECOY="$SOME_DIR/handoffs/issue-maker-zzz-log.json"
printf 'older\n' >"$OLDER"
printf 'newer\n' >"$NEWER"
printf '{}\n' >"$DECOY"
touch_ago "$OLDER" 7200    # 2h ago
touch_ago "$NEWER" 3600    # 1h ago — newer mtime, smaller name
touch_ago "$DECOY" 60      # newest file in the dir, but not a handoff

printf '%s' '{"hook_event_name":"StopFailure","error":"rate_limit","session_id":"some"}' \
  | CLAUDE_USAGE_LIMIT_DIR="$SOME_DIR" CLAUDE_HANDOFF_DIR="$SOME_DIR/handoffs" bash "$HOOK"
SOME_LAST="$SOME_DIR/usage-limit-last.json"

jq -e --arg p "$NEWER" '.portable_handoff == $p' "$SOME_LAST" >/dev/null \
  || fail "portable_handoff is not the newest handoff by mtime (got $(jq -r '.portable_handoff' "$SOME_LAST"))"
jq -e --arg p "$NEWER" '.resume_hint | contains($p)' "$SOME_LAST" >/dev/null \
  || fail "resume_hint does not name the portable handoff"
jq -e --arg p "$OLDER" '.resume_hint | contains($p) | not' "$SOME_LAST" >/dev/null \
  || fail "resume_hint names the older handoff"
jq -e --arg h "$BASE_HINT" '.resume_hint | startswith($h)' "$SOME_LAST" >/dev/null \
  || fail "the handoff pointer replaced the base hint instead of extending it"

# 15d. Only portable-handoff-*.md is eligible — a newer unrelated file in the
# same directory must not be advertised as a handoff. The in-progress temp file
# /pause stages before its atomic rename is deliberately dot-prefixed and
# suffix-less for exactly this reason: an unverified draft must never be
# advertised as a finished handoff.
DRAFT="$SOME_DIR/handoffs/.portable-handoff.aBcDeF"
printf 'half-written\n' >"$DRAFT"
touch_ago "$DRAFT" 30
printf '%s' '{"hook_event_name":"StopFailure","error":"rate_limit","session_id":"draft"}' \
  | CLAUDE_USAGE_LIMIT_DIR="$SOME_DIR" CLAUDE_HANDOFF_DIR="$SOME_DIR/handoffs" bash "$HOOK"
jq -e '.portable_handoff | test("issue-maker") | not' "$SOME_LAST" >/dev/null \
  || fail "a non-handoff file in handoffs/ was picked up as the pointer"
jq -e --arg p "$NEWER" '.portable_handoff == $p' "$SOME_LAST" >/dev/null \
  || fail "an in-progress temp draft was advertised as the handoff"

# 15e. Equal mtimes resolve deterministically to the lexically greater name.
# This pins DETERMINISM, not chronology: two handoffs written in the same second
# carry the same embedded timestamp, so nothing about their names identifies the
# later one. Without the tie-break the winner would vary with directory
# iteration order, which is the actual defect being guarded against.
TIE_EARLIER="$SOME_DIR/handoffs/portable-handoff-ccc-tie.md"
TIE_LATER="$SOME_DIR/handoffs/portable-handoff-ddd-tie.md"
printf 'earlier\n' >"$TIE_EARLIER"
printf 'later\n' >"$TIE_LATER"
TIE_STAMP=$(stamp_ago 600) || fail "cannot compute a relative timestamp"
touch -t "$TIE_STAMP" "$TIE_EARLIER" "$TIE_LATER"
printf '%s' '{"hook_event_name":"StopFailure","error":"rate_limit","session_id":"tie"}' \
  | CLAUDE_USAGE_LIMIT_DIR="$SOME_DIR" CLAUDE_HANDOFF_DIR="$SOME_DIR/handoffs" bash "$HOOK"
jq -e --arg p "$TIE_LATER" '.portable_handoff == $p' "$SOME_LAST" >/dev/null \
  || fail "equal-mtime handoffs did not use the lexical tie-breaker (got $(jq -r '.portable_handoff' "$SOME_LAST"))"
jq -e --arg p "$TIE_LATER" '.resume_hint | contains($p)' "$SOME_LAST" >/dev/null \
  || fail "resume_hint does not name the tie-break winner"

# 15f. The handoff directory is its OWN concept, not a subdirectory of this
# hook's output dir. /pause writes to ~/.claude/handoffs regardless of where the
# recorder keeps its records, so deriving one from the other would point the
# lookup at a directory no handoff is ever written to.
SPLIT_REC="$TMP_DIR/split-records"     # where the recorder writes
SPLIT_HAND="$TMP_DIR/split-handoffs"   # where handoffs actually live
mkdir -p "$SPLIT_REC/handoffs" "$SPLIT_HAND"
DECOY_UNDER_RECORDS="$SPLIT_REC/handoffs/portable-handoff-decoy-20260801T235959Z.md"
REAL_HANDOFF="$SPLIT_HAND/portable-handoff-real-20260801T090000Z.md"
printf 'decoy\n' >"$DECOY_UNDER_RECORDS"   # newer name, wrong directory
printf 'real\n'  >"$REAL_HANDOFF"
printf '%s' '{"hook_event_name":"StopFailure","error":"rate_limit","session_id":"split"}' \
  | CLAUDE_USAGE_LIMIT_DIR="$SPLIT_REC" CLAUDE_HANDOFF_DIR="$SPLIT_HAND" bash "$HOOK"
jq -e --arg p "$REAL_HANDOFF" '.portable_handoff == $p' "$SPLIT_REC/usage-limit-last.json" >/dev/null \
  || fail "handoff lookup did not use the handoff dir (got $(jq -r '.portable_handoff' "$SPLIT_REC/usage-limit-last.json"))"

# 15g. Handoffs age out. A document from a different project weeks ago must not
# stay advertised as the resume pointer — a stale pointer presented as current
# reads as an answer and is worse than no pointer at all.
AGED_DIR="$TMP_DIR/aged"
mkdir -p "$AGED_DIR/handoffs"
STALE_HANDOFF="$AGED_DIR/handoffs/portable-handoff-ancient.md"
printf 'ancient\n' >"$STALE_HANDOFF"
touch_ago "$STALE_HANDOFF" 2592000   # 30 days ago — well outside the 7-day window
printf '%s' '{"hook_event_name":"StopFailure","error":"rate_limit","session_id":"aged"}' \
  | CLAUDE_USAGE_LIMIT_DIR="$AGED_DIR" CLAUDE_HANDOFF_DIR="$AGED_DIR/handoffs" bash "$HOOK"
AGED_LAST="$AGED_DIR/usage-limit-last.json"
jq -e '.portable_handoff == null' "$AGED_LAST" >/dev/null \
  || fail "a handoff far past the age bound was still advertised"
[[ "$(jq -r '.resume_hint' "$AGED_LAST")" == "$BASE_HINT" ]] \
  || fail "an aged-out handoff must leave resume_hint at its unchanged base value"

# A fresh handoff in that same directory is still found — the bound filters by
# age, it does not disable the lookup.
FRESH_HANDOFF="$AGED_DIR/handoffs/portable-handoff-fresh.md"
printf 'fresh\n' >"$FRESH_HANDOFF"
touch_ago "$FRESH_HANDOFF" 300       # 5 minutes ago
printf '%s' '{"hook_event_name":"StopFailure","error":"rate_limit","session_id":"aged2"}' \
  | CLAUDE_USAGE_LIMIT_DIR="$AGED_DIR" CLAUDE_HANDOFF_DIR="$AGED_DIR/handoffs" bash "$HOOK"
jq -e --arg p "$FRESH_HANDOFF" '.portable_handoff == $p' "$AGED_LAST" >/dev/null \
  || fail "the age bound suppressed a fresh handoff too"

# 15h. A bad age setting must not cost the user the pointer. Passed straight to
# `find`, a non-numeric value makes it fail — and its stderr is discarded, so a
# perfectly good handoff would vanish from the breadcrumb with no trace.
BADAGE_DIR="$TMP_DIR/bad-age"
mkdir -p "$BADAGE_DIR/handoffs"
BADAGE_HANDOFF="$BADAGE_DIR/handoffs/portable-handoff-present.md"
printf 'present\n' >"$BADAGE_HANDOFF"
touch_ago "$BADAGE_HANDOFF" 300
for bad in "not-a-number" "" "-3" "7; rm -rf /" "0"; do
  printf '%s' '{"hook_event_name":"StopFailure","error":"rate_limit","session_id":"badage"}' \
    | CLAUDE_USAGE_LIMIT_DIR="$BADAGE_DIR" CLAUDE_HANDOFF_DIR="$BADAGE_DIR/handoffs" \
      CLAUDE_HANDOFF_MAX_AGE_DAYS="$bad" bash "$HOOK"
  jq -e --arg p "$BADAGE_HANDOFF" '.portable_handoff == $p' "$BADAGE_DIR/usage-limit-last.json" >/dev/null \
    || fail "a fresh handoff was lost with CLAUDE_HANDOFF_MAX_AGE_DAYS='$bad'"
done
[[ -e / ]] || fail "the injection fixture did something catastrophic"

echo "PASS: usage-limit-record.sh"
