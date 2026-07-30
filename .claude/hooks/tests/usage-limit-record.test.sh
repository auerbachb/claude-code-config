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
  # $1 = JSON payload. Isolated output dir so tests never touch ~/.claude.
  printf '%s' "$1" | CLAUDE_USAGE_LIMIT_DIR="$TMP_DIR" bash "$HOOK"
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
for f in "$EVENTS" "$LAST"; do
  MODE=$(stat -f '%Lp' "$f" 2>/dev/null || stat -c '%a' "$f" 2>/dev/null)
  [[ "$MODE" == "600" ]] || fail "$(basename "$f") is mode $MODE, expected 600 (owner-only)"
done

# --- 12. Concurrent invocations lose no records ---
# This is the expected case, not an edge case: one account hitting its limit
# fails every active session at once.
CONC_DIR="$TMP_DIR/concurrent"
mkdir -p "$CONC_DIR"
N=25
for i in $(seq 1 "$N"); do
  printf '%s' "{\"hook_event_name\":\"StopFailure\",\"error\":\"rate_limit\",\"session_id\":\"s$i\"}" \
    | CLAUDE_USAGE_LIMIT_DIR="$CONC_DIR" bash "$HOOK" &
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

echo "PASS: usage-limit-record.sh"
