#!/usr/bin/env bash
# catalog: tests — Verifies durable telemetry backlogs and bounded child cursor refresh
set -euo pipefail
ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
mkdir -p "$HOME/.claude"
LOG="$HOME/.claude/spend-telemetry.log"
REPORT="$ROOT/.claude/scripts/spend-telemetry-report.sh"
TASK="$ROOT/.claude/hooks/spend-task-tracker.sh"
SUBAGENT="$ROOT/.claude/hooks/spend-subagent-tracker.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }

# A held append lock must produce a durable private row without extending the
# hook's bounded wait. The ordinary report remains observational/read-only.
READY="$TMP/lock-ready"
python3 - "$LOG" >"$READY" <<'PY' &
import fcntl,sys,time
with open(sys.argv[1]+".lock","a") as lock:
    fcntl.flock(lock.fileno(),fcntl.LOCK_EX)
    print("locked",flush=True)
    time.sleep(1.2)
PY
LOCK_PID=$!
for _ in $(seq 1 100); do grep -q locked "$READY" 2>/dev/null && break; sleep .01; done
grep -q locked "$READY" || fail "test lock holder did not acquire telemetry lock"
printf '%s\n' '{"hook_event_name":"TaskCompleted","session_id":"session-lock","task_id":"contended-task"}' | bash "$TASK" >/dev/null
TRANSCRIPT="$TMP/contended-child.jsonl"
printf '%s\n' \
  '{"type":"assistant","sessionId":"session-lock","message":{"id":"contended-message-1","model":"claude-sonnet-4-6","usage":{"input_tokens":3}}}' \
  '{"type":"assistant","sessionId":"session-lock","message":{"id":"contended-message-2","model":"claude-sonnet-4-6","usage":{"input_tokens":4}}}' > "$TRANSCRIPT"
printf '%s\n' "{\"session_id\":\"session-lock\",\"agent_id\":\"contended-worker\",\"agent_type\":\"general-purpose\",\"agent_transcript_path\":\"$TRANSCRIPT\"}" | bash "$SUBAGENT" >/dev/null
wait "$LOCK_PID"
PENDING="$HOME/.claude/spend-telemetry-pending"
PENDING_COUNT="$(find "$PENDING" -maxdepth 1 -name 'pending-*.tsv' -type f | wc -l | tr -d ' ')"
[[ "$PENDING_COUNT" == "3" ]] || fail "lock timeout queued $PENDING_COUNT row(s); expected lifecycle and two transcript messages"
! grep -q $'\ttask_completed\t.*contended-task' "$LOG" 2>/dev/null || fail "contended event bypassed held lock"
python3 - "$HOME/.claude/spend-telemetry-cursors" "$TRANSCRIPT" <<'PY'
import json,pathlib,sys
cursors=list(pathlib.Path(sys.argv[1]).glob('*.offset'))
assert len(cursors)==1
saved=json.loads(cursors[0].read_text())
assert saved['offset']==pathlib.Path(sys.argv[2]).stat().st_size
PY
grep -q $'\ttranscript_scan\t' "$LOG" || fail "cursor checkpoint advanced without a visible or spooled scan status"
OUT="$(bash "$REPORT")"
grep -q 'Queued hook writes awaiting explicit drain: 3' <<<"$OUT" || fail "report hid the pending write"
[[ "$(find "$PENDING" -maxdepth 1 -name 'pending-*.tsv' -type f | wc -l | tr -d ' ')" == "3" ]] || fail "ordinary report mutated the pending queue"
OUT="$(bash "$REPORT" --resume-pending)"
grep -q 'drained 3 queued write(s)' <<<"$OUT" || fail "explicit refresh did not drain the event"
[[ "$(grep -c $'\ttask_completed\t.*contended-task' "$LOG")" == "1" ]] || fail "pending event was lost or duplicated"
[[ "$(grep -c $'\tassistant_message\t.*contended-message-' "$LOG")" == "2" ]] || fail "pending transcript messages were lost or duplicated"

# Simulate a crash after log append but before spool unlink: refresh recognizes
# the exact existing row and cleans the duplicate without appending it again.
grep $'\ttask_completed\t.*contended-task' "$LOG" > "$PENDING/pending-crash-replay.tsv"
before="$(wc -l < "$LOG" | tr -d ' ')"
OUT="$(bash "$REPORT" --resume-pending)"
grep -q 'removed 1 duplicate spool row(s)' <<<"$OUT" || fail "duplicate spool replay was not recognized"
[[ "$(wc -l < "$LOG" | tr -d ' ')" == "$before" ]] || fail "duplicate spool replay changed the log"
[[ "$(find "$PENDING" -maxdepth 1 -name 'pending-*.tsv' -type f | wc -l | tr -d ' ')" == "0" ]] || fail "duplicate spool entry was not removed"

# Force an incremental child scan cutoff, then explicitly resume from its
# private cursor. No transcript rows are printed or logged.
python3 - "$ROOT" "$TMP/child-refresh" <<'PY'
import importlib.util,json,os,pathlib,subprocess,sys
root=pathlib.Path(sys.argv[1]); base=pathlib.Path(sys.argv[2]); base.mkdir()
home=base/'home'; (home/'.claude').mkdir(parents=True)
env=dict(os.environ,HOME=str(home),CLAUDE_CODE_SESSION_ID='refresh-session',CLAUDE_SESSION_ID='')
log=home/'.claude/spend-telemetry.log'; cursors=home/'.claude/spend-telemetry-cursors'
transcript=base/'child.jsonl'
with transcript.open('w') as stream:
    for i in range(500):
        row={'type':'assistant','sessionId':'refresh-session','timestamp':'2026-10-30T12:00:00Z','message':{'id':f'refresh-msg-{i}','model':'claude-sonnet-4-6','content':[{'text':'NEVER_LOG_CHILD_CONTENT'}],'usage':{'input_tokens':i+1,'output_tokens':1}}}
        stream.write(json.dumps(row)+'\n')
payload=json.dumps({'session_id':'refresh-session','agent_id':'refresh-agent','agent_type':'general-purpose','cwd':'','agent_transcript_path':str(transcript)})
cutoff_env=dict(env,CLAUDE_SPEND_TELEMETRY_TEST_MODE='1',CLAUDE_SPEND_TELEMETRY_TEST_INLINE_BUDGET='0.000001')
subagent=root/'.claude/hooks/spend-subagent-tracker.sh'; report=root/'.claude/scripts/spend-telemetry-report.sh'
subprocess.run(['bash',str(subagent)],input=payload,text=True,env=cutoff_env,capture_output=True,check=True,timeout=10)
cursor_files=list(cursors.glob('*.offset')); assert len(cursor_files)==1
cursor=json.loads(cursor_files[0].read_text(encoding='utf-8'))
assert cursor['offset'] < transcript.stat().st_size
assert cursor['metadata']['transcript_path']==os.path.abspath(transcript)
assert cursors.stat().st_mode & 0o777 == 0o700 and cursor_files[0].stat().st_mode & 0o777 == 0o600
assert 'NEVER_LOG_CHILD_CONTENT' not in cursor_files[0].read_text(encoding='utf-8')
observed=subprocess.run(['bash',str(report)],env=env,text=True,capture_output=True,check=True,timeout=15).stdout
assert 'pending child transcript sources: 1' in observed
refreshed=subprocess.run(['bash',str(report),'--resume-pending'],env=env,text=True,capture_output=True,check=True,timeout=30).stdout
assert 'resumed 1 child source(s)' in refreshed and 'pending child sources: 0' in refreshed
spec=importlib.util.spec_from_file_location('telemetry_report',root/'.claude/scripts/lib/spend-telemetry-report-v2.py')
module=importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
def message_ids():
    records=[module.parse_row(line.split('\t'),n) for n,line in enumerate(log.read_text().splitlines())]
    return [row['event_key'] for row in module.dedupe(records) if row['event_type']=='assistant_message' and row['event_key'].startswith('refresh-msg-')]
assert len(message_ids())==500 and len(set(message_ids()))==500
subprocess.run(['bash',str(report),'--resume-pending'],env=env,text=True,capture_output=True,check=True,timeout=30)
assert len(message_ids())==500 and len(set(message_ids()))==500
assert 'NEVER_LOG_CHILD_CONTENT' not in log.read_text(encoding='utf-8')
print('PASS: a bounded child cursor resumes explicitly and records each message once')
PY

echo "PASS: contention spools durably, report exposes pending count, and duplicate drain is idempotent"
