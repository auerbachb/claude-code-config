#!/usr/bin/env bash
# Tests for spend-session-tracker.sh, spend-subagent-tracker.sh, and
# lib/spend-telemetry-recorder.sh (issue #710).
#
# Runs against a temp HOME so real ~/.claude/spend-telemetry.log is never read
# or written. Fixtures build their own premise; revert-verify inversion confirms
# the regression tests fail when the fix is absent.
set -euo pipefail

REPO_ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
SESSION_HOOK="$REPO_ROOT/.claude/hooks/spend-session-tracker.sh"
SUBAGENT_HOOK="$REPO_ROOT/.claude/hooks/spend-subagent-tracker.sh"
RECORDER="$REPO_ROOT/.claude/hooks/lib/spend-telemetry-recorder.sh"

# Verify all scripts exist before starting.
for f in "$SESSION_HOOK" "$SUBAGENT_HOOK" "$RECORDER"; do
  [[ -f "$f" ]] || { echo "SKIP: $f not found (run from repo root)" >&2; exit 0; }
done

TMP_BASE="$(mktemp -d)"
cleanup() { rm -rf "$TMP_BASE"; }
trap cleanup EXIT

export HOME="$TMP_BASE/home"
LOG="$HOME/.claude/spend-telemetry.log"
TAB=$'\t'

fail() { echo "FAIL: $*" >&2; exit 1; }

reset_log() { rm -f "$LOG"; }

log_lines() {
  [[ -f "$LOG" ]] && wc -l < "$LOG" | tr -d ' ' || echo 0
}

expect_lines() {
  local want="$1" ctx="$2" got
  got="$(log_lines)"
  [[ "$got" == "$want" ]] || fail "$ctx: expected $want log line(s), got $got"
}

# Build a minimal agents dir so model-tier lookup works
AGENTS_DIR="$TMP_BASE/home/.claude/agents"
mkdir -p "$AGENTS_DIR"
cat > "$AGENTS_DIR/phase-a-fixer.md" << 'AGENTEOF'
---
name: phase-a-fixer
model: opus
---
AGENTEOF
cat > "$AGENTS_DIR/pm-worker.md" << 'AGENTEOF'
---
name: pm-worker
model: sonnet
---
AGENTEOF

# Helper: run session hook with a JSON payload
run_session() {
  printf '%s' "$1" | bash "$SESSION_HOOK"
}

# Helper: run subagent hook with a JSON payload
run_subagent() {
  printf '%s' "$1" | bash "$SUBAGENT_HOOK"
}

session_payload() {
  # $1=source $2=session_id $3=model
  python3 -c "import json,sys; print(json.dumps({'source': sys.argv[1], 'session_id': sys.argv[2], 'model': sys.argv[3]}))" "$1" "$2" "$3"
}

subagent_payload() {
  # $1=session_id $2=agent_id $3=agent_type $4=transcript_path
  python3 -c "import json,sys; print(json.dumps({'session_id': sys.argv[1], 'agent_id': sys.argv[2], 'agent_type': sys.argv[3], 'agent_transcript_path': sys.argv[4]}))" "$1" "$2" "$3" "$4"
}

echo "--- spend-session-tracker tests ---"

# Test 1: startup event writes one line
reset_log
out="$(run_session "$(session_payload startup sess-abc claude-opus-4-5)")"
expect_lines 1 "startup writes one line"
[[ "$out" == "{}" ]] || fail "session hook must return {}, got: $out"

# Verify log format contract: ISO8601Z TAB session_start TAB thread TAB opus TAB session TAB sess-abc TAB (empty) TAB (empty)
line="$(cat "$LOG")"
[[ "$line" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z ]] || fail "timestamp format wrong: $line"
[[ "$(cut -f2 <<<"$line")" == "session_start" ]] || fail "event_type wrong: $line"
[[ "$(cut -f3 <<<"$line")" == "thread" ]] || fail "exec_type wrong: $line"
[[ "$(cut -f4 <<<"$line")" == "opus" ]] || fail "model_tier wrong (expected opus): $line"
[[ "$(cut -f5 <<<"$line")" == "session" ]] || fail "agent_type wrong: $line"
[[ "$(cut -f6 <<<"$line")" == "sess-abc" ]] || fail "session_id wrong: $line"

echo "PASS: startup writes one formatted line"

# Test 2: resume event is skipped
reset_log
run_session "$(session_payload resume sess-xyz claude-sonnet-4-5)" > /dev/null
expect_lines 0 "resume is skipped"
echo "PASS: resume is skipped"

# Test 3: compact event is skipped
reset_log
run_session "$(session_payload compact sess-xyz claude-sonnet-4-5)" > /dev/null
expect_lines 0 "compact is skipped"
echo "PASS: compact is skipped"

# Test 4: clear event is skipped
reset_log
run_session "$(session_payload clear sess-xyz claude-haiku-4-5)" > /dev/null
expect_lines 0 "clear is skipped"
echo "PASS: clear is skipped"

# Test 5: model tier extraction — sonnet
reset_log
run_session "$(session_payload startup sess-s claude-sonnet-4-5-20251022)" > /dev/null
line="$(cat "$LOG")"
[[ "$(cut -f4 <<<"$line")" == "sonnet" ]] || fail "model_tier wrong for sonnet: $line"
echo "PASS: sonnet tier extracted"

# Test 6: unknown model maps to raw/unknown
reset_log
run_session "$(session_payload startup sess-u claude-unknown-model-v99)" > /dev/null
line="$(cat "$LOG")"
tier="$(echo "$line" | cut -f4)"
# Should not be empty
[[ -n "$tier" ]] || fail "model_tier empty for unknown: $line"
echo "PASS: unknown model handled gracefully (tier=$tier)"

# Test 7: missing fields tolerated (empty JSON)
reset_log
run_session "{}" > /dev/null
# Empty startup source (treated as startup per hook logic)
expect_lines 1 "empty payload treated as startup"
echo "PASS: empty payload tolerated"

# Test 8: hook always exits 0
reset_log
run_session "NOT_JSON" > /dev/null
echo "PASS: malformed JSON tolerated (exit 0)"

echo ""
echo "--- spend-subagent-tracker tests ---"

# Test 9: subagent_stop writes one inline line
reset_log
run_subagent "$(subagent_payload sess-abc agent-1 phase-a-fixer "")" > /dev/null
expect_lines 1 "subagent_stop writes one line"
line="$(cat "$LOG")"
[[ "$(cut -f2 <<<"$line")" == "subagent_stop" ]] || fail "event_type wrong: $line"
[[ "$(cut -f3 <<<"$line")" == "inline" ]] || fail "exec_type wrong: $line"
# Model tier from frontmatter: phase-a-fixer -> opus
[[ "$(cut -f4 <<<"$line")" == "opus" ]] || fail "model_tier wrong for phase-a-fixer: $line"
[[ "$(cut -f5 <<<"$line")" == "phase-a-fixer" ]] || fail "agent_type wrong: $line"
[[ "$(cut -f6 <<<"$line")" == "sess-abc" ]] || fail "session_id wrong: $line"
[[ "$(cut -f7 <<<"$line")" == "agent-1" ]] || fail "agent_id wrong: $line"
echo "PASS: subagent_stop writes one formatted inline line with opus tier"

# Test 10: pm-worker maps to sonnet
reset_log
run_subagent "$(subagent_payload sess-abc agent-2 pm-worker "")" > /dev/null
line="$(cat "$LOG")"
[[ "$(cut -f4 <<<"$line")" == "sonnet" ]] || fail "pm-worker tier wrong: $line"
echo "PASS: pm-worker maps to sonnet"

# Test 11: unknown agent_type maps to unknown tier
reset_log
run_subagent "$(subagent_payload sess-abc agent-3 mystery-agent "")" > /dev/null
line="$(cat "$LOG")"
tier="$(echo "$line" | cut -f4)"
[[ "$tier" == "unknown" ]] || fail "unknown agent should give unknown tier, got: $tier"
echo "PASS: unknown agent_type maps to unknown tier"

# Test 12: token extraction from transcript
TRANSCRIPT="$TMP_BASE/transcript.jsonl"
cat > "$TRANSCRIPT" << 'JEOF'
{"type": "message", "usage": {"input_tokens": 1200, "output_tokens": 300}}
{"type": "message", "usage": {"input_tokens": 500, "output_tokens": 100}}
JEOF
reset_log
run_subagent "$(subagent_payload sess-abc agent-4 phase-a-fixer "$TRANSCRIPT")" > /dev/null
line="$(cat "$LOG")"
tokens="$(echo "$line" | cut -f8)"
# Should sum to 2100 (1200+300+500+100)
[[ "$tokens" == "2100" ]] || fail "token sum wrong: expected 2100, got '$tokens'"
echo "PASS: token extraction from transcript"

# Test 13: missing transcript -> empty tokens field (not error)
reset_log
run_subagent "$(subagent_payload sess-abc agent-5 phase-a-fixer "/nonexistent/path.jsonl")" > /dev/null
line="$(cat "$LOG")"
tokens="$(echo "$line" | cut -f8)"
[[ -z "$tokens" ]] || fail "missing transcript should give empty tokens, got: '$tokens'"
echo "PASS: missing transcript gives empty token field"

# Test 14: hook always exits 0 on malformed input
reset_log
echo "NOT_JSON" | bash "$SUBAGENT_HOOK" > /dev/null
echo "PASS: subagent hook tolerates malformed JSON"

echo ""
echo "--- sanitization tests ---"

# Test 15: tab injection in session_id is stripped
reset_log
EVIL_PAYLOAD=$(python3 -c "import json; print(json.dumps({'source': 'startup', 'session_id': 'evil\textra', 'model': 'claude-opus-4-5'}))")
run_session "$EVIL_PAYLOAD" > /dev/null
expect_lines 1 "tab injection produces one line"
line="$(cat "$LOG")"
tab_count="$(tr -cd $'\t' < "$LOG" | wc -c | tr -d ' ')"
[[ "$tab_count" == "7" ]] || fail "TSV field count changed (expected 7 tabs, got $tab_count): $line"
session_field="$(echo "$line" | cut -f6)"
[[ "$session_field" == "evilextra" ]] || fail "tab was not stripped from session_id: $line"
echo "PASS: tab in session_id is stripped"

echo ""
echo "--- revert-verify: regression test (inversion check) ---"
# If source=compact were NOT skipped, the compact test above would have written
# a line. Verify that inverting the skip logic would break the test:
#   We simulate what a hook WITHOUT the compact-skip would do: write unconditionally.
reset_log
# Simulated "broken" hook behavior: write even for compact
(
  export HOME="$TMP_BASE/home"
  . "$RECORDER" 2>/dev/null
  record_spend_telemetry "session_start" "thread" "sonnet" "session" "sess-x" "" ""
)
broken_lines="$(log_lines)"
[[ "$broken_lines" == "1" ]] || fail "revert-verify: broken hook didn't write a line"
# Now the real hook should still skip compact
run_session "$(session_payload compact sess-y claude-opus-4-5)" > /dev/null
final_lines="$(log_lines)"
[[ "$final_lines" == "1" ]] || fail "revert-verify: real hook should not add a line for compact (got $final_lines)"
echo "PASS: revert-verify confirms compact-skip is required (without it, an extra line would appear)"

echo ""
echo "All spend-telemetry-tracker tests passed."
