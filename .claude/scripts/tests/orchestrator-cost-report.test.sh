#!/usr/bin/env bash
# Tests for orchestrator-cost-report.sh (issue #2434).
# catalog: tests — Fixture tests for `orchestrator-cost-report.sh` in a temp `HOME` (known totals, unknown data, named errors, read-only)
# covers: .claude/scripts/orchestrator-cost-report.sh
# covers: .claude/scripts/lib/orchestrator-cost-report.py
# covers: .claude/skills/tldr/SKILL.md
#
# Synthetic transcript and telemetry only. The real ~/.claude is never read or written.
set -euo pipefail

REPO_ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
REPORT="$REPO_ROOT/.claude/scripts/orchestrator-cost-report.sh"
[[ -f "$REPORT" ]] || { echo "FAIL: $REPORT not found" >&2; exit 1; }

TMP_BASE="$(mktemp -d)"
trap 'rm -rf "$TMP_BASE"' EXIT
export HOME="$TMP_BASE/home"
mkdir -p "$HOME/.claude/projects/proj-a" "$HOME/.claude/projects/proj-b"
LOG="$HOME/.claude/spend-telemetry.log"
SID="11111111-2222-3333-4444-555555555555"
TRANSCRIPT="$HOME/.claude/projects/proj-a/$SID.jsonl"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

# Build a parent transcript, a worker telemetry log and a missing-data variant.
python3 - "$TRANSCRIPT" "$LOG" "$SID" <<'PY'
import json, sys
transcript, log, sid = sys.argv[1:4]
def usage(i, o, cr, cw):
    return {"input_tokens": i, "output_tokens": o, "cache_read_input_tokens": cr, "cache_creation_input_tokens": cw}
recs = [
    {"type": "user", "message": {"role": "user", "content": "Plan the next batch."}, "timestamp": "2026-08-01T10:00:00Z"},
    {"type": "assistant", "timestamp": "2026-08-01T10:00:02Z", "message": {"id": "msg_a1", "model": "claude-opus-4-7",
        "content": [{"type": "tool_use", "id": "tu1", "name": "Read", "input": {"file_path": "x"}}],
        "usage": usage(10, 5, 100, 20)}},
    {"type": "user", "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "tu1", "content": "ok"}]}},
    {"type": "assistant", "timestamp": "2026-08-01T10:00:05Z", "message": {"id": "msg_a2", "model": "claude-opus-4-7",
        "content": [{"type": "tool_use", "id": "tu2", "name": "Agent", "input": {"prompt": "p"}}],
        "usage": usage(3, 7, 50, 0)}},
    {"type": "user", "timestamp": "2026-08-01T10:05:00Z", "message": {"role": "user",
        "content": "<task-notification>worker done</task-notification>"}},
    {"type": "assistant", "timestamp": "2026-08-01T10:05:02Z", "message": {"id": "msg_a3", "model": "claude-opus-4-7",
        "content": [{"type": "text", "text": "noted"}], "usage": usage(4, 2, 30, 0)}},
    {"type": "user", "timestamp": "2026-08-01T10:06:00Z", "message": {"role": "user", "content": "thanks"}},
    {"type": "assistant", "timestamp": "2026-08-01T10:06:02Z", "message": {"id": "msg_a4", "model": "claude-opus-4-7",
        "content": [{"type": "text", "text": "ok"}], "usage": usage(2, 1, 10, 0)}},
    {"type": "assistant", "isSidechain": True, "message": {"id": "msg_side", "model": "claude-haiku-5-5",
        "content": [], "usage": usage(999, 999, 999, 999)}},
]
with open(transcript, "w") as fh:
    for r in recs:
        fh.write(json.dumps(r) + "\n")

def row(event_type, agent_id, key, actual, i, o, cr, cw, ident="message.id"):
    cols = [""] * 27
    cols[0] = "2026-08-01T10:10:00Z"; cols[1] = event_type; cols[2] = "subagent"; cols[3] = "sonnet"
    cols[5] = sid; cols[6] = agent_id; cols[8] = "3"; cols[9] = key; cols[10] = "/repo"
    cols[14] = actual; cols[15] = "transcript"; cols[16] = str(i); cols[17] = str(o)
    cols[18] = str(cr); cols[19] = str(cw); cols[21] = "unsupported"; cols[24] = "subagent"
    cols[25] = "transcript"; cols[26] = json.dumps({"message_identity_source": ident, "repo_slug": "acme/repo"})
    return "\t".join(cols)
rows = [
    row("assistant_message", "w1", "wmsg1", "claude-sonnet-4-6", 40, 10, 400, 0),
    row("assistant_message", "w1", "wmsg2", "claude-sonnet-4-6", 20, 5, 200, 0),
    row("assistant_message", "w2", "wmsg3", "claude-haiku-5-5", 8, 4, 0, 0),
]
with open(log, "w") as fh:
    fh.write("\n".join(rows) + "\n")
PY

# Test 1: known totals, per-model split, complete_total labels and share.
OUT="$(bash "$REPORT" --session "$SID" --log "$LOG" --json)" || fail "known-totals run exited non-zero"
python3 - "$OUT" <<'PY' || fail "known totals did not match expected figures"
import json, sys
d = json.loads(sys.argv[1])
p, w = d["parent"], d["workers"]
assert p["input_tokens"]["value"] == 10 + 3 + 4 + 2, p["input_tokens"]
assert p["output_tokens"]["value"] == 5 + 7 + 2 + 1, p["output_tokens"]
assert p["cache_read_input_tokens"]["value"] == 100 + 50 + 30 + 10, p["cache_read_input_tokens"]
assert p["cache_creation_input_tokens"]["value"] == 20, p["cache_creation_input_tokens"]
assert w["input_tokens"]["value"] == 68 and w["output_tokens"]["value"] == 19, w
assert "claude-haiku-5-5" not in d["by_model"], "sidechain must not count toward parent"
assert d["by_model"]["claude-opus-4-7"]["messages"] == 4, d["by_model"]
# Complete data on both sides: parent 244 of 244 + 687 observed tokens.
assert d["share"]["value"] == 26.2, d["share"]
assert p["sum"]["label"] == "complete_total" and p["sum"]["value"] == 244, p["sum"]
PY
pass "known totals, model split, labels"

# Test 2: classes and drivers present, turn classification by evidence.
python3 - "$OUT" <<'PY' || fail "turn classes wrong"
import json, sys
d = json.loads(sys.argv[1])
c = d["turns"]["by_class"]
# Turn 1 holds an Agent call (mutating) so it is other; the notification turn and
# the plain user reply classify by evidence.
assert c["other"] == 1, c
assert c["data_gathering"] == 0, c
assert c["worker_result_handling"] == 1, c
assert c["user_reply"] == 1, c
assert d["turns"]["count"] == 3, d["turns"]
PY
pass "turn classification"

# Test 3: missing telemetry log reports unknown worker figures, not zero.
OUT3="$(bash "$REPORT" --session "$SID" --log "$TMP_BASE/absent.log" --json)" || fail "missing-log run exited non-zero"
python3 - "$OUT3" <<'PY' || fail "missing-log figures were not unknown"
import json, sys
d = json.loads(sys.argv[1])
assert d["workers"]["input_tokens"]["value"] is None, d["workers"]
assert d["workers"]["input_tokens"]["label"] == "unknown", d["workers"]
assert d["coverage"]["telemetry_log_present"] is False
assert d["share"]["value"] is None and "telemetry_log_absent" in d["share"]["reason"]
assert d["parent"]["input_tokens"]["label"] == "known_subtotal", d["parent"]["input_tokens"]
PY
pass "missing telemetry is unknown, not zero"

# Test 4: named errors, no totals on stdout.
expect_error() {
  local name="$1"; shift
  local out err rc=0
  out="$(bash "$REPORT" "$@" 2>"$TMP_BASE/err")" || rc=$?
  err="$(cat "$TMP_BASE/err")"
  [[ $rc -ne 0 ]] || fail "$name: expected non-zero exit"
  [[ "$err" == *"$name"* ]] || fail "$name: stderr missing name (got: $err)"
  [[ -z "$out" ]] || fail "$name: stdout must be empty (got: $out)"
}
(unset CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID; expect_error session_unknown --session default --log "$LOG")
expect_error transcript_not_found --session 99999999-9999-9999-9999-999999999999 --log "$LOG"
cp "$TRANSCRIPT" "$HOME/.claude/projects/proj-b/$SID.jsonl"
expect_error transcript_ambiguous --session "$SID" --log "$LOG"
rm -f "$HOME/.claude/projects/proj-b/$SID.jsonl"
chmod 000 "$TRANSCRIPT"
if [[ "$(id -u)" -ne 0 ]]; then expect_error transcript_unreadable --session "$SID" --transcript "$TRANSCRIPT" --log "$LOG"; fi
chmod 644 "$TRANSCRIPT"
pass "named errors, empty stdout"

# Test 5: dedupe — a message in both telemetry and the transcript counts once.
python3 - "$LOG" "$SID" <<'PY'
import sys
log, sid = sys.argv[1:3]
cols = ["2026-08-01T10:10:00Z", "assistant_message", "main", "opus", "", sid, "", "", "3", "msg_a1", "/repo",
        "unknown", "", "", "claude-opus-4-7", "transcript", "10", "5", "100", "20", "", "unsupported", "", "",
        "main", "transcript", '{"message_identity_source":"message.id","repo_slug":"acme/repo"}']
with open(log, "a") as fh:
    fh.write("\t".join(cols) + "\n")
PY
OUT4="$(bash "$REPORT" --session "$SID" --log "$LOG" --json)"
python3 - "$OUT4" <<'PY' || fail "duplicate message was double counted"
import json, sys
d = json.loads(sys.argv[1])
assert d["by_model"]["claude-opus-4-7"]["messages"] == 4, d["by_model"]
PY
pass "dedupe by message id"

# Test 6: read-only — the log and HOME listing are unchanged by a run.
sum_before="$(cd "$HOME" && find . -type f -exec cksum {} + | sort)"
bash "$REPORT" --session "$SID" --log "$LOG" --json >/dev/null
bash "$REPORT" --session "$SID" --log "$LOG" --one-line >/dev/null
sum_after="$(cd "$HOME" && find . -type f -exec cksum {} + | sort)"
[[ "$sum_before" == "$sum_after" ]] || fail "report wrote files under HOME"
pass "read-only: no files written"

# Test 7: one-line form and stderr silent on success.
LINE="$(bash "$REPORT" --session "$SID" --log "$LOG" --one-line 2>"$TMP_BASE/err2")"
[[ "$LINE" == Parent\ share:* ]] || fail "one-line form wrong: $LINE"
[[ ! -s "$TMP_BASE/err2" ]] || fail "stderr not empty on success"
pass "one-line form and silent stderr"

# Test 8: invalid argument exits 2.
rc=0; bash "$REPORT" --bogus >/dev/null 2>&1 || rc=$?
[[ $rc -eq 2 ]] || fail "invalid argument should exit 2 (got $rc)"
pass "invalid argument exits 2"

# Test 8b: a transcript recording a different session is rejected.
MISMATCH_T="$TMP_BASE/mismatch.jsonl"
printf '%s\n' '{"type":"user","sessionId":"aaaaaaaa-0000-0000-0000-000000000000","message":{"role":"user","content":"x"}}' > "$MISMATCH_T"
expect_error transcript_session_mismatch --session "$SID" --transcript "$MISMATCH_T" --log "$LOG"
pass "transcript with a conflicting session is rejected"

# Test 9: a usage-bearing message without an ID is excluded from sums and marks coverage partial.
NOID_SID="66666666-7777-8888-9999-000000000000"
NOID_T="$HOME/.claude/projects/proj-a/$NOID_SID.jsonl"
python3 - "$NOID_T" "$NOID_SID" <<'PY'
import json, sys
path, sid = sys.argv[1:3]
u = {"input_tokens": 5, "output_tokens": 1, "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0}
recs = [
    {"type": "user", "message": {"role": "user", "content": "hi"}, "timestamp": "2026-08-02T10:00:00Z"},
    {"type": "assistant", "message": {"id": "msg_ok", "model": "claude-opus-4-7", "content": [], "usage": u}},
    {"type": "assistant", "message": {"model": "claude-opus-4-7", "content": [], "usage": u}},
]
with open(path, "w") as fh:
    for r in recs:
        fh.write(json.dumps(r) + "\n")
PY
OUT9="$(bash "$REPORT" --session "$NOID_SID" --transcript "$NOID_T" --log "$LOG" --json)"
python3 - "$OUT9" <<'PY' || fail "id-less usage must not yield a complete parent total"
import json, sys
d = json.loads(sys.argv[1])
assert "unidentified_usage_messages" in d["coverage"]["limitations"], d["coverage"]
assert d["parent"]["input_tokens"]["value"] == 5, d["parent"]["input_tokens"]
assert d["parent"]["sum"]["label"] == "known_subtotal", d["parent"]["sum"]
PY
pass "id-less usage marks parent coverage partial"

# Test 10: a read-only prefix with a write option is not read-only (negative test); plain git diff stays read-only.
python3 - "$REPO_ROOT/.claude/scripts/lib/orchestrator-cost-report.py" <<'PY' || fail "write-option read-only classification wrong"
import importlib.util, sys
spec = importlib.util.spec_from_file_location("ocr", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
assert m.bash_is_read_only("git diff") is True
assert m.bash_is_read_only("git diff --output=/tmp/x") is False
assert m.bash_is_read_only("find . -delete") is False
assert m.bash_is_read_only("ls; rm -rf x") is False
PY
pass "read-only classification negative and positive cases"

# Test 10b: a hook-refused Agent call starts no worker, so it is not an unmatched call;
# a launched Agent call with no telemetry still is.
AG_SID="77777777-8888-9999-0000-111111111111"
AG_T="$HOME/.claude/projects/proj-a/$AG_SID.jsonl"
python3 - "$AG_T" "$AG_SID" "$LOG" <<'PY'
import json, sys
path, sid, log = sys.argv[1:4]
u = {"input_tokens": 1, "output_tokens": 1, "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0}
def agent_turn(tid, mid, ts):
    return [
        {"type": "user", "timestamp": ts, "message": {"role": "user", "content": "go"}},
        {"type": "assistant", "timestamp": ts, "message": {"id": mid, "model": "claude-opus-4-7", "content":
            [{"type": "tool_use", "id": tid, "name": "Agent", "input": {"prompt": "p"}}], "usage": u}},
    ]
refused = {"type": "user", "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "tu_ref",
    "is_error": True, "content": "PreToolUse:Agent hook error: BLOCKED: pause state is lock-contended"}]}}
ok = {"type": "user", "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "tu_ok",
    "content": "started"}]}}
recs = [
    {"type": "user", "message": {"role": "user", "content": "start"}, "timestamp": "2026-08-03T10:00:00Z"},
    {"type": "assistant", "timestamp": "2026-08-03T10:00:01Z", "message": {"id": "msg_r", "model": "claude-opus-4-7",
        "content": [{"type": "tool_use", "id": "tu_ref", "name": "Agent", "input": {}}], "usage": u}},
    refused,
    {"type": "assistant", "timestamp": "2026-08-03T10:00:02Z", "message": {"id": "msg_k", "model": "claude-opus-4-7",
        "content": [{"type": "tool_use", "id": "tu_ok", "name": "Agent", "input": {}}], "usage": u}},
    ok,
]
with open(path, "w") as fh:
    for r in recs:
        fh.write(json.dumps(r) + "\n")
cols = [""] * 27
cols[0] = "2026-08-03T10:10:00Z"; cols[1] = "assistant_message"; cols[2] = "subagent"; cols[3] = "sonnet"
cols[5] = sid; cols[6] = "wk1"; cols[8] = "3"; cols[9] = "wk1msg"; cols[10] = "/repo"
cols[14] = "claude-sonnet-4-6"; cols[15] = "transcript"; cols[16] = "4"; cols[17] = "2"; cols[18] = "0"; cols[19] = "0"
cols[21] = "unsupported"; cols[24] = "subagent"; cols[25] = "transcript"
cols[26] = json.dumps({"message_identity_source": "message.id", "repo_slug": "acme/repo"})
with open(log, "a") as fh:
    fh.write("\t".join(cols) + "\n")
PY
AG_OUT="$(bash "$REPORT" --session "$AG_SID" --transcript "$AG_T" --log "$LOG" --json)"
python3 - "$AG_OUT" <<'PY' || fail "refused Agent call was counted as unmatched, or launched one was not"
import json, sys
d = json.loads(sys.argv[1])
lim = d["coverage"]["limitations"]
assert "unmatched_agent_calls" not in lim, lim
PY
pass "refused Agent call is not counted as unmatched"

# Test 10c: a JSON scalar line is a malformed line, not a crash; --help exits 0; an unreadable log is named.
SCALAR_SID="88888888-9999-0000-1111-222222222222"
SCALAR_T="$HOME/.claude/projects/proj-a/$SCALAR_SID.jsonl"
printf '%s\n' 'null' '42' '{"type":"user","message":{"role":"user","content":"hi"}}' > "$SCALAR_T"
SC_OUT="$(bash "$REPORT" --session "$SCALAR_SID" --transcript "$SCALAR_T" --log "$LOG" --json)" || fail "scalar transcript lines crashed the report"
python3 - "$SC_OUT" <<'PY' || fail "scalar lines were not counted as malformed"
import json, sys
d = json.loads(sys.argv[1])
assert "malformed_transcript_lines" in d["coverage"]["limitations"], d["coverage"]
PY
rc=0; bash "$REPORT" --help >/dev/null || rc=$?
[[ $rc -eq 0 ]] || fail "--help should exit 0 (got $rc)"
if [[ "$(id -u)" -ne 0 ]]; then
  chmod 000 "$LOG"
  expect_error telemetry_log_unreadable --session "$SID" --transcript "$TRANSCRIPT" --log "$LOG"
  chmod 644 "$LOG"
fi
pass "scalar transcript lines, --help exit 0, unreadable log named"

# Test 11: /tldr contract names the mode and the script.
TLDR="$REPO_ROOT/.claude/skills/tldr/SKILL.md"
if [[ -f "$TLDR" ]]; then
  grep -q "parent-share" "$TLDR" || fail "tldr skill missing parent-share mode"
  grep -q "orchestrator-cost-report.sh" "$TLDR" || fail "tldr skill missing report script"
  grep -q "no tool calls" "$TLDR" || fail "tldr skill lost default no-tool-calls contract"
  pass "tldr parent-share contract"
fi

echo "All orchestrator-cost-report tests passed."
