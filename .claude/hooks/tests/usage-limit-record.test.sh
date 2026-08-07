#!/usr/bin/env bash
# Tests for usage-limit-record.sh — the StopFailure recorder (issue #824).
#
# Covers the behavior the issue's Test Plan requires: the recorder fires only
# on the upstream rate-limit signal, a healthy session is completely
# unaffected, and no code path computes a local spend estimate.
#
# Repo-invariant checks (registration, HOOKS_MANIFEST absence, no-spend
# estimation, safety.md wording, audit-doc existence) live in
# usage-limit-record-registration.test.sh (split by Issue #1071).
#
# Portable-handoff-pointer tests live in
# usage-limit-record-handoff-pointer.test.sh (split by Issue #1071).
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
HOOK="$REPO_ROOT/.claude/hooks/usage-limit-record.sh"

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

# --- 6. State files are owner-only ---
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

# --- 7. Concurrent invocations lose no records ---
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

# --- 8. Non-string fields are truncated too ---
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

# --- 9. Rotation fires at the cap and preserves the archive ---
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

echo "PASS: usage-limit-record.sh"
