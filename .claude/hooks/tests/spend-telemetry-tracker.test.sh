#!/usr/bin/env bash
# Sanitized integration coverage for spend telemetry schema v3.
set -euo pipefail

REPO_ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
SESSION_HOOK="$REPO_ROOT/.claude/hooks/spend-session-tracker.sh"
SUBAGENT_HOOK="$REPO_ROOT/.claude/hooks/spend-subagent-tracker.sh"
TASK_HOOK="$REPO_ROOT/.claude/hooks/spend-task-tracker.sh"
REPORT="$REPO_ROOT/.claude/scripts/spend-telemetry-report.sh"
LINK="$REPO_ROOT/.claude/scripts/spend-telemetry-link.sh"
TMP_BASE="$(mktemp -d)"
cleanup() { rm -rf "$TMP_BASE"; }
trap cleanup EXIT

unset CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID
export HOME="$TMP_BASE/home"
mkdir -p "$HOME/.claude/skills-worktree/.claude/agents"
LOG="$HOME/.claude/spend-telemetry.log"
TAB=$'\t'
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "PASS: $*"; }

cat > "$HOME/.claude/skills-worktree/.claude/agents/custom-worker.md" <<'AGENTEOF'
---
name: custom-worker
model: sonnet
---
AGENTEOF

run_session() { printf '%s' "$1" | bash "$SESSION_HOOK"; }
run_subagent() { printf '%s' "$1" | bash "$SUBAGENT_HOOK"; }
run_task() { printf '%s' "$1" | bash "$TASK_HOOK"; }
json_payload() { python3 -c 'import json,sys; print(json.dumps(json.loads(sys.argv[1])))' "$1"; }
line_count() { [[ -f "$LOG" ]] && wc -l < "$LOG" | tr -d ' ' || echo 0; }

# Main session transcript and child transcript are deliberately separate. Both
# contain one sentinel in discarded content so the privacy assertion is real.
MAIN_TRANSCRIPT="$TMP_BASE/main.jsonl"
CHILD_TRANSCRIPT="$TMP_BASE/child.jsonl"
cat > "$MAIN_TRANSCRIPT" <<'JEOF'
{"type":"user","message":{"role":"user","content":[{"type":"text","text":"DO_NOT_LOG_PROMPT"}]}}
{"type":"assistant","timestamp":"2026-10-30T12:00:00Z","message":{"id":"main-msg-1","model":"claude-sonnet-4-6","role":"assistant","content":[{"type":"text","text":"DO_NOT_LOG_RESPONSE"}],"usage":{"input_tokens":100,"output_tokens":20,"cache_read_input_tokens":30,"cache_creation_input_tokens":10}}}
JEOF
cat > "$CHILD_TRANSCRIPT" <<'JEOF'
{"type":"assistant","timestamp":"2026-10-30T12:00:01Z","message":{"id":"child-msg-1","model":"claude-opus-5-5","role":"assistant","content":[{"type":"text","text":"DO_NOT_LOG_CHILD"}],"usage":{"input_tokens":1200,"output_tokens":300,"cache_read_input_tokens":400,"cache_creation_input_tokens":50}}}
{"type":"assistant","timestamp":"2026-10-30T12:00:03Z","message":{"id":"child-msg-2","model":"claude-opus-5-5","role":"assistant","content":[],"usage":{"input_tokens":500,"output_tokens":100,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
JEOF

echo "--- session hooks ---"
python3 - "$REPO_ROOT/global-settings.json" <<'PY' || fail "telemetry hooks are not registered in global-settings.json"
import json, sys
hooks = json.load(open(sys.argv[1], encoding="utf-8"))["hooks"]
required = {
    "SessionStart": "spend-session-tracker.sh",
    "SessionEnd": "spend-session-tracker.sh",
    "SubagentStop": "spend-subagent-tracker.sh",
    "TaskCreated": "spend-task-tracker.sh",
    "TaskCompleted": "spend-task-tracker.sh",
}
for event, suffix in required.items():
    entries = [hook for entry in hooks.get(event, []) for hook in entry.get("hooks", [])]
    if not any(hook.get("command", "").endswith(suffix) for hook in entries):
        raise SystemExit(f"missing {event} registration")
    expected_timeout = 30 if event == "SessionEnd" else None
    if expected_timeout and not any(hook.get("command", "").endswith(suffix) and hook.get("timeout") == expected_timeout for hook in entries):
        raise SystemExit(f"{event} transcript scan must have bounded {expected_timeout}s timeout")
PY
ok "SessionStart, SessionEnd, SubagentStop, TaskCreated, and TaskCompleted hooks are registered"

echo "--- preserved startup and hook-failure invariants ---"
for source in resume clear compact; do
  payload=$(python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"SessionStart","source":sys.argv[1],"session_id":"skip-session","model":"claude-sonnet-4-6"}))' "$source")
  run_session "$payload" >/dev/null
done
[[ "$(line_count)" == "0" ]] || fail "resume/clear/compact must not add new session rows"
out="$(run_session "NOT_JSON")"
[[ "$out" == "{}" ]] || fail "malformed SessionStart must keep the hook output contract"
[[ "$(line_count)" == "1" ]] || fail "malformed SessionStart should remain a non-blocking unknown startup row"
: > "$LOG"
out="$(run_subagent "NOT_JSON")"
[[ "$out" == "{}" ]] || fail "malformed SubagentStop must keep the hook output contract"
[[ "$(line_count)" == "1" ]] || fail "malformed SubagentStop should retain its unavailable-event denominator"
: > "$LOG"
tab_payload=$(python3 -c 'import json; print(json.dumps({"hook_event_name":"SessionStart","source":"startup","session_id":"bad\tid","model":"claude-sonnet-4-6"}))')
run_session "$tab_payload" >/dev/null
sanitized_row=$(cat "$LOG")
[[ "$(tr -cd '\t' <<<"$sanitized_row" | wc -c | tr -d ' ')" == "26" ]] || fail "schema-v3 TSV field count changed under tab injection"
[[ "$(cut -f6 <<<"$sanitized_row")" == "badid" ]] || fail "session ID tab injection was not stripped"
placeholder_payload=$(json_payload '{"hook_event_name":"SessionStart","source":"startup","session_id":"${CLAUDE_SESSION_ID:-default}","model":"claude-sonnet-4-6"}')
run_session "$placeholder_payload" >/dev/null
placeholder_row=$(tail -n 1 "$LOG")
[[ "$(cut -f6 <<<"$placeholder_row")" == "unknown" ]] || fail "unresolved skill session placeholder must remain unknown"
ok "resume/clear/compact skip, malformed hooks, and TSV sanitization are preserved"
: > "$LOG"

session_start=$(json_payload '{"hook_event_name":"SessionStart","source":"startup","session_id":"sess-main","model":"claude-sonnet-4-6","cwd":"/tmp/telemetry-repo"}')
out="$(run_session "$session_start")"
[[ "$out" == "{}" ]] || fail "SessionStart must emit {}"
grep -q $'^.*\tsession_start\tthread\tsonnet\tsession\tsess-main\t\t\t3\t' "$LOG" || fail "SessionStart model/provenance row missing"

session_end=$(python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"SessionEnd","session_id":"sess-main","cwd":"/tmp/telemetry-repo","transcript_path":sys.argv[1],"reason":"other"}))' "$MAIN_TRANSCRIPT")
run_session "$session_end" >/dev/null
main_row=$(grep $'\tmain-msg-1\t' "$LOG" || true)
[[ -n "$main_row" ]] || fail "SessionEnd did not record the main transcript message"
[[ "$(cut -f15 <<<"$main_row")" == "claude-sonnet-4-6" ]] || fail "actual model missing from transcript"
[[ "$(cut -f17-20 <<<"$main_row" | tr '\t' ',')" == "100,20,30,10" ]] || fail "usage fields were not captured exactly"
[[ "$(cut -f8 <<<"$main_row")" == "160" ]] || fail "complete total token count wrong"
run_session "$session_end" >/dev/null
[[ "$(grep -c $'\tmain-msg-1\t' "$LOG")" == "1" ]] || fail "replayed SessionEnd appended an already-scanned message"
ok "SessionStart actual model and SessionEnd nested usage captured"

# If a parent and child transcript expose the same message key, the report
# keeps both scope-specific sources instead of conflating them.
python3 - "$main_row" >> "$LOG" <<'PY'
import sys
fields = sys.argv[1].split("\t")
fields[2] = "inline"
fields[6] = "agent-overlap"
fields[24] = "subagent"
print("\t".join(fields))
PY
[[ "$(grep -F "main-msg-1" "$LOG" | cut -f25 | sort -u | wc -l | tr -d ' ')" == "2" ]] || fail "matching parent/child message keys lost transcript scope"
ok "matching parent and child message keys remain separate scoped records"

echo "--- subagent transcript attribution ---"
payload=$(python3 -c 'import json,sys; print(json.dumps({"session_id":"sess-main","agent_id":"agent-custom","agent_type":"custom-worker","cwd":"/tmp/telemetry-repo","agent_transcript_path":sys.argv[1]}))' "$CHILD_TRANSCRIPT")
run_subagent "$payload" >/dev/null
run_subagent "$payload" >/dev/null # replay; byte cursor prevents a second append
child_rows=$(grep $'\tchild-msg-' "$LOG" | wc -l | tr -d ' ')
[[ "$child_rows" == "2" ]] || fail "replayed transcript messages should not be appended again"
child_row=$(grep $'\tchild-msg-1\t' "$LOG" | head -n 1)
[[ "$(cut -f13 <<<"$child_row")" == "sonnet" ]] || fail "frontmatter default was not kept as requested model"
[[ "$(cut -f14 <<<"$child_row")" == "agent_frontmatter_default" ]] || fail "requested model provenance missing"
[[ "$(cut -f15 <<<"$child_row")" == "claude-opus-5-5" ]] || fail "runtime override was not attributed as actual model"
[[ "$(cut -f16 <<<"$child_row")" == "transcript.message.model" ]] || fail "actual model provenance missing"
ok "explicit model override is distinct from requested frontmatter default; replay keys stable"

# General-purpose workers have no model frontmatter. Custom and general-purpose
# workers still get their runtime model from the assistant transcript envelope.
GENERAL="$TMP_BASE/general.jsonl"
cat > "$GENERAL" <<'JEOF'
{"type":"assistant","timestamp":"2026-10-30T12:00:05Z","message":{"id":"general-msg-1","model":"claude-haiku-4-5","role":"assistant","content":[],"usage":{"input_tokens":9,"output_tokens":3}}}
{"type":"assistant","timestamp":"2026-10-30T12:00:06Z","message":{"id":"general-msg-unknown","role":"assistant","content":[],"usage":{"input_tokens":7}}}
JEOF
general_payload=$(python3 -c 'import json,sys; print(json.dumps({"session_id":"sess-main","agent_id":"agent-general","agent_type":"general-purpose","cwd":"/tmp/telemetry-repo","agent_transcript_path":sys.argv[1]}))' "$GENERAL")
run_subagent "$general_payload" >/dev/null
general_row=$(grep $'\tgeneral-msg-1\t' "$LOG")
[[ "$(cut -f13 <<<"$general_row")" == "" ]] || fail "general-purpose requested model must stay unknown"
[[ "$(cut -f14 <<<"$general_row")" == "unavailable" ]] || fail "unknown requested-model provenance missing"
[[ "$(cut -f15 <<<"$general_row")" == "claude-haiku-4-5" ]] || fail "general-purpose actual model missing"
[[ "$(cut -f17 <<<"$general_row")" == "9" && "$(cut -f18 <<<"$general_row")" == "3" ]] || fail "partial usage values missing"
[[ -z "$(cut -f19-20 <<<"$general_row" | tr -d '\t')" ]] || fail "missing cache fields must not become zero"
ok "general-purpose worker uses runtime model and missing cache fields remain blank"
unknown_row=$(grep $'\tgeneral-msg-unknown\t' "$LOG")
[[ "$(cut -f15 <<<"$unknown_row")" == "" ]] || fail "missing runtime model must stay unknown"
[[ "$(cut -f16 <<<"$unknown_row")" == "unavailable" ]] || fail "missing actual-model provenance must remain unavailable"
[[ "$(cut -f17 <<<"$unknown_row")" == "7" && "$(cut -f18 <<<"$unknown_row")" == "" ]] || fail "partial nested usage should preserve only supported fields"
[[ "$(cut -f26 <<<"$unknown_row")" == "transcript.message.usage" ]] || fail "nested usage source provenance missing"
ok "unknown actual model and partial usage are represented as unknown coverage"

# An incomplete final JSONL record remains unread until its newline arrives.
PARTIAL="$TMP_BASE/partial.jsonl"
printf '%s' '{"type":"assistant","timestamp":"2026-10-30T12:00:07Z","message":{"id":"partial-msg-1","model":"claude-sonnet-4-6","usage":{"input_tokens":1}}}' > "$PARTIAL"
partial_payload=$(python3 -c 'import json,sys; print(json.dumps({"session_id":"sess-partial","agent_id":"agent-partial","agent_type":"general-purpose","cwd":"/tmp/telemetry-repo","agent_transcript_path":sys.argv[1]}))' "$PARTIAL")
run_subagent "$partial_payload" >/dev/null
[[ "$(grep -c $'\tpartial-msg-1\t' "$LOG" || true)" == "0" ]] || fail "incomplete transcript record must not be consumed"
printf '\n' >> "$PARTIAL"
run_subagent "$partial_payload" >/dev/null
[[ "$(grep -c $'\tpartial-msg-1\t' "$LOG")" == "1" ]] || fail "completed transcript record was lost after partial write"
ok "partial transcript tail is retried when the JSONL record completes"

missing_payload=$(python3 -c 'import json; print(json.dumps({"session_id":"sess-main","agent_id":"agent-missing","agent_type":"general-purpose","cwd":"/tmp/telemetry-repo","agent_transcript_path":"/missing/sanitized-transcript.jsonl"}))')
run_subagent "$missing_payload" >/dev/null
missing_row=$(grep $'\tsubagent_stop\t' "$LOG" | tail -n 1)
[[ "$(cut -f10 <<<"$missing_row")" != "" ]] || fail "missing-transcript event needs a stable dedup key"
[[ "$(cut -f26 <<<"$missing_row")" == "unsupported:agent_transcript_path_missing" ]] || fail "missing transcript path was not recorded explicitly"
ok "missing transcript paths retain an explicit, deduplicable source-status row"

echo "--- task lifecycle metadata ---"
created=$(json_payload '{"hook_event_name":"TaskCreated","session_id":"sess-main","cwd":"/tmp/telemetry-repo","agent_id":"agent-custom","task_id":"task-1","task_subject":"DO_NOT_LOG_SUBJECT","task_description":"DO_NOT_LOG_DESCRIPTION"}')
completed=$(json_payload '{"hook_event_name":"TaskCompleted","session_id":"sess-main","cwd":"/tmp/telemetry-repo","agent_id":"agent-custom","task_id":"task-1","task_subject":"DO_NOT_LOG_SUBJECT","task_description":"DO_NOT_LOG_DESCRIPTION"}')
run_task "$created" >/dev/null
run_task "$completed" >/dev/null
other_session_task=$(json_payload '{"hook_event_name":"TaskCreated","session_id":"sess-other","cwd":"/tmp/telemetry-repo","agent_id":"agent-other","task_id":"task-1"}')
run_task "$other_session_task" >/dev/null
grep -q $'\ttask-1\tcreated\ttask_lifecycle' "$LOG" || fail "TaskCreated ID was not recorded"
grep -q $'\ttask-1\tcompleted\ttask_lifecycle' "$LOG" || fail "TaskCompleted ID was not recorded"
if grep -Eq 'DO_NOT_LOG_(PROMPT|RESPONSE|CHILD|SUBJECT|DESCRIPTION)' "$LOG"; then fail "transcript/task content leaked into metadata log"; fi
ok "task IDs and outcomes are captured without subject, description, or transcript content"

echo "--- report coverage and dedup ---"
# Simulate a crash after log append but before cursor update: report-level
# event-key dedup remains a second idempotency guard.
printf '%s\n' "$child_row" >> "$LOG"
# Preserve a legacy row to prove mixed-schema readability and the old report's
# model-column heading regression remains fixed.
printf '2026-10-30T12:00:00Z\tsubagent_stop\tinline\tunknown\told-worker\tlegacy-sess\told-agent\t\n' >> "$LOG"
report="$(bash "$REPORT" --days 30)"
grep -q 'Assistant-message denominator.*6 unique message record(s)' <<<"$report" || fail "duplicate transcript messages were not deduplicated"
grep -q 'Actual model.*5/6 known' <<<"$report" || fail "actual model coverage denominator wrong"
grep -q '| sonnet | agent_frontmatter_default | claude-opus-5-5 | transcript.message.model | 2 |' <<<"$report" || fail "requested/actual model provenance table missing override"
grep -q '| Cache-read tokens | 3/6 | 430 |' <<<"$report" || fail "cache-read coverage/sum wrong"
grep -q '| Cache-write tokens | 3/6 | 60 |' <<<"$report" || fail "cache-write coverage/sum wrong"
grep -q 'TaskCreated IDs: 2; TaskCompleted IDs: 1' <<<"$report" || fail "session-scoped task lifecycle IDs collided"
grep -q 'unique explicit session/repo/worker-to-task mappings: 0' <<<"$report" || fail "session-scoped worker/task pairs were not counted"
grep -q 'does not verify acceptance criteria' <<<"$report" || fail "generic TaskCompleted overclaimed as verified"
grep -q 'no supported per-event cost source' <<<"$report" || fail "cost limitation missing"
grep -q 'estimate ledger has PR/issue/elapsed/commit-round data but no session/task ID' <<<"$report" || fail "separate estimate source join limitation missing"
grep -q '| exec_type | unknown | total |' <<<"$report" || fail "legacy report headings are not unique"
ok "mixed legacy/v2 report has denominators, message dedup, lifecycle evidence, and explicit limitations"

echo "--- explicit issue/PR/task correlation ---"
LINK_HOME="$TMP_BASE/link-home"
LINK_REPO="$TMP_BASE/link-repo"
FAKE_BIN="$TMP_BASE/fake-bin"
GH_FIXTURES="$TMP_BASE/gh-fixtures"
PASSING_GATE_JSON='{"met":true,"missing":[],"head_sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","ci_status":{"failing":0,"in_progress":0},"unresolved_thread_count":0}'
mkdir -p "$LINK_HOME/.claude" "$LINK_REPO" "$FAKE_BIN" "$GH_FIXTURES"
git -C "$LINK_REPO" init -q
git -C "$LINK_REPO" remote add origin https://github.com/owner/repo.git
cat > "$GH_FIXTURES/7.json" <<'JEOF'
{"number":7,"url":"https://github.com/owner/repo/pull/7","state":"MERGED","mergedAt":"2026-10-30T12:10:00Z","headRefOid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","mergeCommit":{"oid":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"},"closingIssuesReferences":[{"number":42,"repository":{"name":"repo","owner":{"login":"owner"}}}],"reviewDecision":"APPROVED","statusCheckRollup":[{"state":"SUCCESS"},{"__typename":"CheckRun","status":"COMPLETED","conclusion":"NEUTRAL"}],"commits":[{"oid":"a"},{"oid":"b"},{"oid":"c"},{"oid":"d"},{"oid":"e"}]}
JEOF
cat > "$GH_FIXTURES/8.json" <<'JEOF'
{"number":8,"state":"MERGED","mergedAt":"2026-10-30T12:20:00Z","headRefOid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","mergeCommit":{"oid":"cccccccccccccccccccccccccccccccccccccccc"},"closingIssuesReferences":[{"number":42,"repository":{"nameWithOwner":"owner/repo"}}],"reviewDecision":"CHANGES_REQUESTED","statusCheckRollup":[{"state":"FAILURE"}],"commits":[{"oid":"a"}]}
JEOF
cat > "$GH_FIXTURES/other-7.json" <<'JEOF'
{"number":7,"state":"MERGED","mergedAt":"2026-10-30T12:30:00Z","headRefOid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","mergeCommit":{"oid":"dddddddddddddddddddddddddddddddddddddddd"},"closingIssuesReferences":[{"number":42,"repository":{"nameWithOwner":"other/repo"}}],"reviewDecision":"APPROVED","statusCheckRollup":[{"state":"SUCCESS"}],"commits":[{"oid":"a"}]}
JEOF
cat > "$GH_FIXTURES/9.json" <<'JEOF'
{"number":9,"state":"MERGED","mergedAt":"2026-10-30T12:40:00Z","headRefOid":"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee","mergeCommit":{"oid":"ffffffffffffffffffffffffffffffffffffffff"},"closingIssuesReferences":[{"number":42,"repository":{"nameWithOwner":"owner/repo"}}],"reviewDecision":"APPROVED","statusCheckRollup":[{"state":"SUCCESS"}],"commits":[{"oid":"a"}]}
JEOF
cat > "$GH_FIXTURES/10.json" <<'JEOF'
{"number":10,"state":"MERGED","mergedAt":"2026-10-30T12:50:00Z","headRefOid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","mergeCommit":{"oid":"ffffffffffffffffffffffffffffffffffffffff"},"closingIssuesReferences":[{"number":42,"repository":{"nameWithOwner":"owner/repo"}}],"reviewDecision":"APPROVED","statusCheckRollup":[{"state":"IN_PROGRESS"}],"commits":[{"oid":"a"}]}
JEOF
cat > "$FAKE_BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
case "${3:-}" in
  7)
    if [[ "${4:-}" == "--repo" && "${5:-}" == "other/repo" ]]; then cat "$GH_FIXTURES/other-7.json"; else cat "$GH_FIXTURES/7.json"; fi
    ;;
  8) cat "$GH_FIXTURES/8.json" ;;
  9) cat "$GH_FIXTURES/9.json" ;;
  10) cat "$GH_FIXTURES/10.json" ;;
  *) exit 1 ;;
esac
GHEOF
chmod +x "$FAKE_BIN/gh"
export HOME="$LINK_HOME"
export GH_FIXTURES
export PATH="$FAKE_BIN:$PATH"
LOG="$HOME/.claude/spend-telemetry.log"
export ESTIMATE_LOG_FILE="$HOME/.claude/estimate-log.jsonl"
rc=0
"$LINK" --repo owner/repo --issue 1 --pr 7 --source wrap_post_merge --gate-passed >/dev/null 2>&1 || rc=$?
[[ "$rc" == "2" ]] || fail "gate proof without the full observed head SHA must be rejected"
rc=0
env GH_REPO=owner/repo CLAUDE_SESSION_ID='${CLAUDE_SESSION_ID:-default}' "$LINK" --session '${CLAUDE_SESSION_ID:-default}' --issue 102 --source start_issue_claim >/dev/null 2>&1 || rc=$?
[[ "$rc" == "0" ]] || fail "unresolved session placeholder should fail open"
[[ ! -e "$LOG" || "$(grep -c $'\ttask_correlation\t' "$LOG" || true)" == "0" ]] || fail "unresolved session placeholder was persisted as correlation"
printf '%s\n' \
  '{"repo":"owner/repo","pr":7,"issue":42,"actual_min":12.5,"rounds":5,"merge_ts":"2026-10-30T12:10:00Z"}' \
  '{"repo":"other/repo","pr":7,"issue":42,"actual_min":99,"rounds":13,"merge_ts":"2026-10-30T12:30:00Z"}' \
  > "$ESTIMATE_LOG_FILE"
CORRELATION_REPO="$LINK_REPO"
link_transcript="$TMP_BASE/linked-task.jsonl"
cat > "$link_transcript" <<'JEOF'
{"type":"assistant","timestamp":"2026-10-30T12:00:00Z","message":{"id":"linked-msg-1","model":"claude-sonnet-4-6","usage":{"input_tokens":10,"output_tokens":4,"cache_read_input_tokens":2,"cache_creation_input_tokens":1}}}
JEOF
link_task_payload=$(python3 -c 'import json,sys; print(json.dumps({"session_id":"session-verified","agent_id":"worker-verified","agent_type":"general-purpose","cwd":sys.argv[1],"agent_transcript_path":sys.argv[2]}))' "$CORRELATION_REPO" "$link_transcript")
run_subagent "$link_task_payload" >/dev/null
run_task "$(json_payload "{\"hook_event_name\":\"TaskCreated\",\"session_id\":\"session-verified\",\"agent_id\":\"worker-verified\",\"task_id\":\"task-verified\",\"cwd\":\"$CORRELATION_REPO\"}")" >/dev/null
run_task "$(json_payload "{\"hook_event_name\":\"TaskCompleted\",\"session_id\":\"session-verified\",\"agent_id\":\"worker-verified\",\"task_id\":\"task-verified\",\"cwd\":\"$CORRELATION_REPO\"}")" >/dev/null
"$LINK" --session session-verified --repo owner/repo --issue 42 --source start_issue_claim >/dev/null
"$LINK" --session session-verified --repo owner/repo --issue 42 --pr 7 --task task-verified --agent worker-verified --source wrap_post_merge --gate-passed --gate-head-sha aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --gate-result "$PASSING_GATE_JSON" >/dev/null
# Replayed correlation capture is collapsed by its stable key.
"$LINK" --session session-verified --repo owner/repo --issue 42 --pr 7 --task task-verified --agent worker-verified --source wrap_post_merge --gate-passed --gate-head-sha aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --gate-result "$PASSING_GATE_JSON" >/dev/null
"$LINK" --repo owner/repo --issue 42 --pr 8 --source wrap_post_merge >/dev/null
"$LINK" --session session-no-gate --repo owner/repo --issue 42 --pr 7 --source wrap_post_merge >/dev/null
"$LINK" --session session-stale --repo owner/repo --issue 42 --pr 9 --source wrap_post_merge --gate-passed --gate-head-sha aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --gate-result "$PASSING_GATE_JSON" >/dev/null
"$LINK" --session session-partial --repo owner/repo --issue 42 --pr 10 --source wrap_post_merge --gate-passed --gate-head-sha aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --gate-result "$PASSING_GATE_JSON" >/dev/null
"$LINK" --session session-ambiguous --repo owner/repo --issue 42 --source start_issue_claim >/dev/null
"$LINK" --session session-orphan --repo owner/repo --issue 99 --source start_issue_claim >/dev/null
GH_REPO=owner/repo "$LINK" --session session-ghrepo --issue 100 --source start_issue_claim >/dev/null
(cd "$LINK_REPO" && env -u GH_REPO "$LINK" --session session-origin --issue 101 --source start_issue_claim >/dev/null)
"$LINK" --session session-other-repo --repo other/repo --issue 42 --pr 7 --source wrap_post_merge >/dev/null
linked_report="$(bash "$REPORT")"
grep -q 'TaskCompleted + merged gate verified' <<<"$linked_report" || fail "explicit completed-task + verified PR join missing"
grep -q '| owner/repo | 42 | 7 | session-verified | task-verified | 1 | TaskCompleted + merged gate verified | yes | APPROVED | 1/2 success; 1 nonblocking' <<<"$linked_report" || fail "verified task evidence fields are wrong"
grep -q '| owner/repo | 42 | 7 | session-verified | task-verified | 1 | TaskCompleted + merged gate verified | yes | APPROVED | 1/2 success; 1 nonblocking; 0 unknown | bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb | 12.5 | 5 |' <<<"$linked_report" || fail "exact repo/PR estimate join or squash SHA distinction is wrong"
grep -q '| other/repo | 42 | 7 | session-other-repo | session | 0 | merged; unverified session-level | unavailable | APPROVED | 1/1 success; 0 unknown | dddddddddddddddddddddddddddddddddddddddd | 99.0 | 13 |' <<<"$linked_report" || fail "same-number PR from another repository collided"
grep -q '| owner/repo | 42 | 7 | session-no-gate | session | 0 | merged; unverified session-level' <<<"$linked_report" || fail "merged evidence without wrap gate proof was treated as verified"
grep -q '| owner/repo | 42 | 9 | session-stale | session | 0 | merged; unverified session-level' <<<"$linked_report" || fail "approval on a stale/different PR head was treated as fresh"
grep -q '| owner/repo | 42 | 10 | session-partial | session | 0 | merged; unverified session-level | yes | APPROVED | 0/1 success; 1 unknown' <<<"$linked_report" || fail "partial current check state was treated as passing"
grep -q 'session-ambiguous: ambiguous PR mapping' <<<"$linked_report" || fail "conflicting same-issue PR links must remain ambiguous"
grep -q 'session-orphan: no PR evidence' <<<"$linked_report" || fail "missing PR mapping must remain unavailable"
grep -q 'session-ghrepo: no PR evidence' <<<"$linked_report" || fail "GH_REPO fallback did not record an explicit repository mapping"
grep -q 'session-origin: no PR evidence' <<<"$linked_report" || fail "origin remote fallback did not record an explicit repository mapping"
grep -q 'Exact paid review rounds, historical CI reruns, and escalation reasons remain unavailable' <<<"$linked_report" || fail "unsupported review/retry evidence was overclaimed"
[[ "$(grep -c $'\ttask_correlation\t' "$LOG")" -gt "$(grep -c 'linked-msg-1' "$LOG")" ]] || fail "explicit correlation metadata was not recorded"
ok "explicit session/task-to-issue/PR joins verify only supported outcomes; ambiguous/missing links and repo collisions stay unknown"

echo "--- runtime, cursor, and workflow contract regressions ---"
python3 - "$REPO_ROOT" "$TMP_BASE/deep" <<'PY'
import concurrent.futures, importlib.util, json, os, pathlib, re, subprocess, sys
root=pathlib.Path(sys.argv[1]); base=pathlib.Path(sys.argv[2]);base.mkdir()
env=dict(os.environ,HOME=str(base/'home'),CLAUDE_CODE_SESSION_ID='runtime-primary',CLAUDE_SESSION_ID='runtime-legacy')
pathlib.Path(env['HOME'],'.claude').mkdir(parents=True)
log=pathlib.Path(env['HOME'],'.claude/spend-telemetry.log')
repo=base/'repo';repo.mkdir()
subprocess.run(['git','init','-q',str(repo)],check=True)
subprocess.run(['git','-C',str(repo),'remote','add','origin','https://github.com/OWNER/REPO.git'],check=True)
spec=importlib.util.spec_from_file_location('report',root/'.claude/scripts/lib/spend-telemetry-report-v2.py');report=importlib.util.module_from_spec(spec);spec.loader.exec_module(report)
def hook(name,payload,custom=None):
    result=subprocess.run(['bash',str(root/'.claude/hooks'/name)],input=json.dumps(payload),text=True,capture_output=True,env=custom or env,timeout=15)
    assert result.returncode==0 and result.stdout.strip()=='{}',(name,result.returncode,result.stdout)
def rows():
    return [report.parse_row(line.split('\t'),n) for n,line in enumerate(log.read_text().splitlines())]
def messages(): return report.unique_messages([r for r in report.dedupe(rows()) if r['event_type']=='assistant_message'])
def assistant(mid,**kwargs):
    return dict(type='assistant',timestamp='2026-10-30T12:00:00Z',sessionId='transcript-session',uuid='uuid-'+mid,requestedModel='claude-sonnet-4-6',message=dict(id=mid,model='claude-opus-5-5',content=[dict(text='PRIVATE_CONTENT_SENTINEL')],usage=kwargs))
transcript=base/'runtime.jsonl'
transcript.write_text(json.dumps(assistant('changing',input_tokens=11,output_tokens=True,cache_read_input_tokens=0,cache_creation_input_tokens=-1))+'\n')
payload=dict(session_id='${CLAUDE_CODE_SESSION_ID:-default}',agent_id='worker',agent_type='general-purpose',cwd=str(repo),agent_transcript_path=str(transcript))
hook('spend-subagent-tracker.sh',payload)
m=messages()[0]
assert m['session_id']=='runtime-primary' and m['requested_model']=='claude-sonnet-4-6' and m['requested_source']=='transcript.requestedModel'
assert m['actual_model']=='claude-opus-5-5' and m['input_tokens']==11 and m['output_tokens'] is None and m['cache_read_tokens']==0 and m['cache_write_tokens'] is None
# Sparse repeated snapshots enrich one provider response; zero is retained.
with transcript.open('a') as f: f.write(json.dumps(assistant('changing',output_tokens=0,cache_creation_input_tokens=3))+'\n')
hook('spend-subagent-tracker.sh',payload)
m=messages()[0];assert len(messages())==1 and (m['input_tokens'],m['output_tokens'],m['cache_read_tokens'],m['cache_write_tokens'])==(11,0,0,3)
# Same-length replacement on same inode must invalidate a cursor at EOF.
text=transcript.read_text();transcript.write_text(text.replace('changing','replaced'))
hook('spend-subagent-tracker.sh',payload)
assert {m['event_key'] for m in messages()}=={'changing','replaced'}
# A same-length usage correction retains IDs/timestamps but must rescan after mtime changes.
text=transcript.read_text();transcript.write_text(text.replace('"input_tokens": 11','"input_tokens": 12'))
hook('spend-subagent-tracker.sh',payload)
assert next(m for m in messages() if m['event_key']=='replaced')['input_tokens']==12
# A variable-length edit before the saved boundary shifts its byte offset. The
# boundary marker must invalidate the stale cursor even though the inode is same.
text=transcript.read_text();transcript.write_text(text.replace('"id": "replaced"','"id": "replaced-with-longer-id"'))
hook('spend-subagent-tracker.sh',payload)
assert any(m['event_key']=='replaced-with-longer-id' for m in messages())
# Atomic replacement, truncation, malformed lines, and incomplete final record.
replacement=base/'replacement';replacement.write_text(json.dumps(assistant('atomic',input_tokens=2))+'\n');replacement.replace(transcript)
hook('spend-subagent-tracker.sh',payload)
transcript.write_text('not-json\n'+json.dumps(assistant('after-truncate',input_tokens=3))+'\n'+json.dumps(assistant('tail',input_tokens=4)))
hook('spend-subagent-tracker.sh',payload)
assert 'tail' not in {m['event_key'] for m in messages()}
with transcript.open('a') as f:f.write('\n')
hook('spend-subagent-tracker.sh',payload)
assert {'atomic','after-truncate','tail'} <= {m['event_key'] for m in messages()}
# Real concurrent hooks serialize cursor+append; one source record per response.
transcript.write_text(''.join(json.dumps(assistant('batch-'+str(i),input_tokens=i,output_tokens=0,cache_read_input_tokens=0,cache_creation_input_tokens=0))+'\n' for i in range(300)))
with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:list(pool.map(lambda _:hook('spend-subagent-tracker.sh',payload),range(3)))
assert sum(r['event_key'].startswith('batch-') for r in rows())==300
cursors=list(pathlib.Path(env['HOME'],'.claude/spend-telemetry-cursors').glob('*.offset'))
assert any(json.loads(p.read_text())['offset']==transcript.stat().st_size for p in cursors)
# All event types use one runtime resolver, including legacy fallback and transcript-only fallback.
hook('spend-task-tracker.sh',dict(hook_event_name='TaskCreated',session_id='unknown',task_id='runtime-task',agent_id='creator',cwd=str(repo)))
assert any(r['task_id']=='runtime-task' and r['session_id']=='runtime-primary' for r in rows())
legacy=dict(env,CLAUDE_CODE_SESSION_ID='${UNRESOLVED}')
hook('spend-session-tracker.sh',dict(source='startup',session_id='default',model='claude-sonnet-4-6'),legacy)
assert rows()[-1]['session_id']=='runtime-legacy'
unknown=dict(env,CLAUDE_CODE_SESSION_ID='',CLAUDE_SESSION_ID='')
transcript.write_text(json.dumps(assistant('transcript-only',input_tokens=1))+'\n')
hook('spend-subagent-tracker.sh',dict(payload,session_id='unknown'),unknown)
assert any(r['event_key']=='transcript-only' and r['session_id']=='transcript-session' for r in rows())
# Malformed payloads remain nonblocking, and object values never become text metadata.
for name in ('spend-session-tracker.sh','spend-task-tracker.sh','spend-subagent-tracker.sh'):
    for invalid in ([],None,dict(agent_type={'PRIVATE_OBJECT_SENTINEL':'secret'},model=['PRIVATE_OBJECT_SENTINEL'])):hook(name,invalid,unknown)
assert 'PRIVATE_CONTENT_SENTINEL' not in log.read_text() and 'PRIVATE_OBJECT_SENTINEL' not in log.read_text()
# Parent/child source rows without message.id or transcript uuid cannot be
# safely deduplicated from shared request/time/usage metadata alone. Preserve
# both raw observations but exclude their usage from unique-message totals.
anonymous=dict(type='assistant',timestamp='2026-10-30T12:01:00Z',sessionId='runtime-primary',requestId='same-provider-request',message=dict(model='claude-sonnet-4-6',usage=dict(input_tokens=5,output_tokens=2)))
parent_transcript=base/'anonymous-parent.jsonl';child_transcript=base/'anonymous-child.jsonl'
parent_transcript.write_text(json.dumps(anonymous)+'\n');child_transcript.write_text(json.dumps(anonymous)+'\n')
hook('spend-session-tracker.sh',dict(hook_event_name='SessionEnd',session_id='runtime-primary',cwd=str(repo),transcript_path=str(parent_transcript)))
hook('spend-subagent-tracker.sh',dict(session_id='runtime-primary',agent_id='anonymous-worker',agent_type='general-purpose',cwd=str(repo),agent_transcript_path=str(child_transcript)))
anonymous_rows=[r for r in rows() if r['event_type']=='assistant_message' and r['evidence'].get('message_identity_source')=='transcript_scope_offset']
assert len(anonymous_rows)==2 and anonymous_rows[0]['event_key']!=anonymous_rows[1]['event_key']
assert not any(m['event_key'] in {r['event_key'] for r in anonymous_rows} for m in messages())
out=subprocess.run(['bash',str(root/'.claude/scripts/spend-telemetry-report.sh')],env=env,capture_output=True,text=True,check=True).stdout
assert 'unidentifiable observations excluded from message totals: 2' in out and 'usage is excluded because parent/child duplicates cannot be recognized' in out
# Actual workflow fences: real runtime IDs, gate met:false cannot be promoted by a SHA.
link=root/'.claude/scripts/spend-telemetry-link.sh'
start=(root/'.claude/skills/start-issue/SKILL.md').read_text()
wrap=(root/'.claude/skills/wrap/SKILL.md').read_text()
start_block=next(b for b in re.findall(r'```bash\n(.*?)```',start,re.S) if b.startswith('TELEMETRY_SESSION_ID='))
wrap_block=next(b for b in re.findall(r'```bash\n(.*?)```',wrap,re.S) if b.startswith('if [[ -n "$SPEND_TELEMETRY_LINK" && -n "$MERGED_ISSUES"'))
workflow_env=dict(env,SPEND_TELEMETRY_LINK=str(link),GH_REPO='OWNER/REPO',ISSUE_NUMBER='42',MERGED_ISSUES='42',PR_NUM='7')
subprocess.run(['bash','-c',start_block],cwd=repo,env=workflow_env,check=True,timeout=15)
assert rows()[-1]['event_type']=='task_correlation' and rows()[-1]['session_id']=='runtime-primary' and rows()[-1]['evidence']['repo']=='owner/repo'
fake=base/'bin';fake.mkdir();gh=fake/'gh'
fixture=dict(number=7,url='https://github.com/owner/repo/pull/7',state='MERGED',mergedAt='2026-10-30T12:10:00Z',headRefOid='a'*40,mergeCommit={'oid':'b'*40},closingIssuesReferences=[{'number':42,'repository':{'owner':{'login':'owner'},'name':'repo'}}],reviewDecision='REVIEW_REQUIRED',statusCheckRollup=[{'__typename':'CheckRun','status':'COMPLETED','conclusion':'NEUTRAL'}],commit_count=5)
gh.write_text('#!/usr/bin/env python3\nimport json\nprint('+repr(json.dumps(fixture))+')\n');gh.chmod(0o755)
gate=dict(met=False,missing=['review'],head_sha='a'*40,ci_status={'failing':0,'in_progress':0},unresolved_thread_count=0)
workflow_env.update(PATH=str(fake)+os.pathsep+env['PATH'],GATE_JSON=json.dumps(gate))
subprocess.run(['bash','-c',wrap_block],cwd=repo,env=workflow_env,check=True,timeout=15)
assert not rows()[-1]['evidence']['verified_completion'] and not rows()[-1]['evidence']['acceptance_verified']
gate.update(met=True,missing=[]);workflow_env['GATE_JSON']=json.dumps(gate)
subprocess.run(['bash','-c',wrap_block],cwd=repo,env=workflow_env,check=True,timeout=15)
assert report.verified_pr(rows()[-1]['evidence']) and rows()[-1]['evidence']['commit_count']==5
# Missing flag values fail promptly; no shift/infinite-loop regression.
for flag in ('--session','--task','--gate-result','--repo'):
    assert subprocess.run(['bash',str(link),flag],env=workflow_env,capture_output=True,timeout=2).returncode==2
# An explicit completed task uses its actor only as lifecycle evidence, not assignee.
hook('spend-task-tracker.sh',dict(hook_event_name='TaskCompleted',session_id='runtime-primary',task_id='allocated',agent_id='parent-actor',cwd=str(repo)))
args=['bash',str(link),'--session','runtime-primary','--repo','owner/repo','--issue','42','--pr','7','--task','allocated','--agent','worker','--gate-passed','--gate-head-sha','a'*40,'--gate-result',json.dumps(gate)]
subprocess.run(args,cwd=repo,env=workflow_env,check=True,timeout=15)
out=subprocess.run(['bash',str(root/'.claude/scripts/spend-telemetry-report.sh')],env=workflow_env,capture_output=True,text=True,check=True).stdout
assert 'TaskCompleted + merged gate verified' in out and 'owner/repo / PR 7 / allocated' in out
# Task completion needs task identity, not an optional worker/assignee. It can
# verify the outcome while usage stays unknown without an explicit assignment.
hook('spend-task-tracker.sh',dict(hook_event_name='TaskCompleted',session_id='runtime-primary',task_id='unassigned-completed',cwd=str(repo)))
subprocess.run(['bash',str(link),'--session','runtime-primary','--repo','owner/repo','--issue','42','--pr','7','--task','unassigned-completed','--gate-passed','--gate-head-sha','a'*40,'--gate-result',json.dumps(gate)],cwd=repo,env=workflow_env,check=True,timeout=15)
out=subprocess.run(['bash',str(root/'.claude/scripts/spend-telemetry-report.sh')],env=workflow_env,capture_output=True,text=True,check=True).stdout
assert re.search(r'\| owner/repo \| 42 \| 7 \| runtime-primary \| unassigned-completed \| unknown \| TaskCompleted \+ merged gate verified \|',out)
assert re.search(r'\| owner/repo / PR 7 / unassigned-completed \| unknown \| unknown \| unknown \| unknown \| unknown \| unavailable \|',out)
# Reusing the same worker for another task cannot allocate its entire transcript twice.
args[args.index('allocated')]='second-task';subprocess.run(args,cwd=repo,env=workflow_env,check=True,timeout=15)
out=subprocess.run(['bash',str(root/'.claude/scripts/spend-telemetry-report.sh')],env=workflow_env,capture_output=True,text=True,check=True).stdout
assert re.search(r'\| owner/repo \| 42 \| 7 \| runtime-primary \| allocated \| unknown \|',out)
# Foreign/partial evidence and malformed estimates cannot crash or verify.
for evidence in ({'checks':[]},{'checks':{'total':'x'}},{'verified_completion':True,'checks':{'total':True}}):assert not report.verified_pr(evidence)
pathlib.Path(env['HOME'],'.claude/estimate-log.jsonl').write_text('[]\nnull\n'+json.dumps(dict(repo='owner/repo',pr=7,actual_min=float('nan'),rounds=True))+'\n')
subprocess.run(['bash',str(root/'.claude/scripts/spend-telemetry-report.sh'),'--days','999999999999'],env=workflow_env,capture_output=True,text=True,check=True)
assert report.parse_ts('2026-10-30T12:00:00') is None
print('PASS: runtime IDs, nested metadata, sparse/repeated usage, cursor replacement/truncation/tails, concurrent scans, workflow fences, actual gate schema, actor vs assignment, ambiguous allocation, and malformed evidence')
PY

echo "All spend-telemetry-tracker tests passed."
