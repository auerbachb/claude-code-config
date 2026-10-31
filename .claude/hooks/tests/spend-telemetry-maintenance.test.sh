#!/usr/bin/env bash
# catalog: tests — Verifies durable telemetry backlogs and bounded child cursor refresh
set -euo pipefail
ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
TMP="$(mktemp -d)"
RELEASE_LOCK="$TMP/release-lock"
cleanup() {
  if [[ -n "${LOCK_PID:-}" ]]; then
    : > "$RELEASE_LOCK"
    wait "$LOCK_PID" 2>/dev/null || true
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT
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
python3 - "$LOG" "$RELEASE_LOCK" >"$READY" <<'PY' &
import fcntl,os,sys,time
with open(sys.argv[1]+".lock","a") as lock:
    fcntl.flock(lock.fileno(),fcntl.LOCK_EX)
    print("locked",flush=True)
    while not os.path.exists(sys.argv[2]): time.sleep(.01)
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
: > "$RELEASE_LOCK"
wait "$LOCK_PID"
LOCK_PID=""
PENDING="$HOME/.claude/spend-telemetry-pending"
PENDING_COUNT="$(find "$PENDING" -maxdepth 1 -name 'pending-*.tsv' -type f | wc -l | tr -d ' ')"
[[ "$PENDING_COUNT" -ge 3 ]] || fail "lock timeout queued $PENDING_COUNT row(s); expected lifecycle and two transcript messages"
! grep -q $'\ttask_completed\t.*contended-task' "$LOG" 2>/dev/null || fail "contended event bypassed held lock"
python3 - "$HOME/.claude/spend-telemetry-cursors" "$TRANSCRIPT" <<'PY'
import json,pathlib,sys
cursors=list(pathlib.Path(sys.argv[1]).glob('*.offset'))
assert len(cursors)==1
saved=json.loads(cursors[0].read_text())
assert saved['offset']==pathlib.Path(sys.argv[2]).stat().st_size
PY
if ! grep -q $'\ttranscript_scan\t' "$LOG" 2>/dev/null && ! grep -h -q $'\ttranscript_scan\t' "$PENDING"/pending-*.tsv 2>/dev/null; then
  fail "cursor checkpoint advanced without a visible or spooled scan status row"
fi
OUT="$(bash "$REPORT")"
grep -q "Queued hook writes awaiting explicit drain: $PENDING_COUNT" <<<"$OUT" || fail "report hid the pending write"
[[ "$(find "$PENDING" -maxdepth 1 -name 'pending-*.tsv' -type f | wc -l | tr -d ' ')" == "$PENDING_COUNT" ]] || fail "ordinary report mutated the pending queue"
OUT="$(bash "$REPORT" --resume-pending)"
grep -q "drained $PENDING_COUNT queued write(s)" <<<"$OUT" || fail "explicit refresh did not drain the event"
[[ "$(grep -c $'\ttask_completed\t.*contended-task' "$LOG")" == "1" ]] || fail "pending event was lost or duplicated"
[[ "$(grep -c $'\tassistant_message\t.*contended-message-' "$LOG")" == "2" ]] || fail "pending transcript messages were lost or duplicated"
[[ "$(grep -c $'\ttranscript_scan\t.*contended-worker' "$LOG")" == "1" ]] || fail "transcript scan status was lost or duplicated"

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
import hashlib,importlib.util,json,os,pathlib,shutil,subprocess,sys
root=pathlib.Path(sys.argv[1]); base=pathlib.Path(sys.argv[2]); base.mkdir()
home=base/'home'; (home/'.claude').mkdir(parents=True)
env=dict(os.environ,HOME=str(home),CLAUDE_CODE_SESSION_ID='',CLAUDE_SESSION_ID='')
report_env=dict(env,CLAUDE_CODE_SESSION_ID='report-session')
log=home/'.claude/spend-telemetry.log'; cursors=home/'.claude/spend-telemetry-cursors'
transcript=base/'child.jsonl'
old_cwd=base/'deleted-worktree'; old_cwd.mkdir()
subprocess.run(['git','init','-q',str(old_cwd)],check=True)
subprocess.run(['git','-C',str(old_cwd),'remote','add','origin','https://github.com/example/telemetry-test.git'],check=True)
with transcript.open('w') as stream:
    for i in range(500):
        row={'type':'assistant','timestamp':'2026-10-30T12:00:00Z','message':{'id':f'refresh-msg-{i}','model':'claude-sonnet-4-6','content':[{'text':'NEVER_LOG_CHILD_CONTENT'}],'usage':{'input_tokens':i+1,'output_tokens':1}}}
        stream.write(json.dumps(row)+'\n')
relative_transcript=os.path.relpath(transcript,old_cwd)
payload=json.dumps({'session_id':'unknown','agent_id':'refresh-agent','agent_type':'general-purpose','cwd':str(old_cwd),'agent_transcript_path':relative_transcript})
cutoff_env=dict(env,CLAUDE_SPEND_TELEMETRY_TEST_MODE='1',CLAUDE_SPEND_TELEMETRY_TEST_INLINE_BUDGET='0.000001')
subagent=root/'.claude/hooks/spend-subagent-tracker.sh'; report=root/'.claude/scripts/spend-telemetry-report.sh'
subprocess.run(['bash',str(subagent)],input=payload,text=True,env=cutoff_env,capture_output=True,check=True,timeout=10,cwd=old_cwd)
other_transcript=base/'other'/'child.jsonl'; other_transcript.parent.mkdir()
other_cwd=other_transcript.parent/'deleted-worktree'; other_cwd.mkdir()
subprocess.run(['git','init','-q',str(other_cwd)],check=True)
subprocess.run(['git','-C',str(other_cwd),'remote','add','origin','https://github.com/example/telemetry-test.git'],check=True)
other_transcript.write_text(json.dumps({'type':'assistant','timestamp':'2026-10-30T12:00:00Z','message':{'id':'second-relative-msg','model':'claude-sonnet-4-6','usage':{'input_tokens':2}}})+'\n')
other_relative=os.path.relpath(other_transcript,other_cwd)
assert other_relative==relative_transcript
other_payload=json.dumps({'session_id':'unknown','agent_id':'refresh-agent','agent_type':'general-purpose','cwd':str(other_cwd),'agent_transcript_path':other_relative})
subprocess.run(['bash',str(subagent)],input=other_payload,text=True,env=cutoff_env,capture_output=True,check=True,timeout=10,cwd=other_cwd)
cursor_files=list(cursors.glob('*.offset')); assert len(cursor_files)==2
cursors_by_path={}
for cursor_file in cursor_files:
    saved=json.loads(cursor_file.read_text(encoding='utf-8'))
    cursors_by_path[saved['metadata']['transcript_path']]=(cursor_file,saved)
assert set(cursors_by_path)=={os.path.realpath(transcript),os.path.realpath(other_transcript)}
cursor_file,cursor=cursors_by_path[os.path.realpath(transcript)]
assert cursor['offset'] < transcript.stat().st_size
assert cursor['metadata']['session_id']=='unknown'
assert cursor['metadata']['cursor_path_input']==os.path.realpath(transcript)
assert cursor['metadata']['repo_root']==str(old_cwd.resolve())
assert cursor['metadata']['repo_slug']=='example/telemetry-test'
assert len({saved['metadata']['cursor_identity'] for _,saved in cursors_by_path.values()})==2
assert all(cursor_file.stat().st_mode & 0o777 == 0o600 for cursor_file,_ in cursors_by_path.values())
assert cursors.stat().st_mode & 0o777 == 0o700
assert 'NEVER_LOG_CHILD_CONTENT' not in cursor_file.read_text(encoding='utf-8')
# A cursor from the previous raw-relative identity scheme remains usable only
# when its saved absolute source confirms that it belongs to this transcript.
legacy_identity=hashlib.sha256('\0'.join(('unknown','refresh-agent','subagent',relative_transcript)).encode()).hexdigest()
legacy_file=cursors/(legacy_identity+'.offset')
cursor['metadata']['cursor_identity']=legacy_identity
cursor['metadata']['cursor_path_input']=relative_transcript
legacy_file.write_text(json.dumps(cursor),encoding='utf-8'); legacy_file.chmod(0o600)
cursor_file.unlink()
subprocess.run(['bash',str(subagent)],input=payload,text=True,env=cutoff_env,capture_output=True,check=True,timeout=10,cwd=old_cwd)
legacy_saved=json.loads(legacy_file.read_text(encoding='utf-8'))
assert legacy_saved['metadata']['cursor_identity']==legacy_identity
assert legacy_saved['metadata']['cursor_path_input']==relative_transcript
assert len(list(cursors.glob('*.offset')))==2
shutil.rmtree(old_cwd)
shutil.rmtree(other_cwd)
observed=subprocess.run(['bash',str(report)],env=report_env,text=True,capture_output=True,check=True,timeout=15).stdout
assert 'pending child transcript sources: 1' in observed, observed
refreshed=subprocess.run(['bash',str(report),'--resume-pending'],env=report_env,text=True,capture_output=True,check=True,timeout=30).stdout
assert 'resumed 1 child source(s)' in refreshed and 'pending child sources: 0' in refreshed
spec=importlib.util.spec_from_file_location('telemetry_report',root/'.claude/scripts/lib/spend-telemetry-report-v2.py')
module=importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
def message_ids():
    records=[module.parse_row(line.split('\t'),n) for n,line in enumerate(log.read_text().splitlines())]
    return [row['event_key'] for row in module.dedupe(records) if row['event_type']=='assistant_message' and (row['event_key'].startswith('refresh-msg-') or row['event_key']=='second-relative-msg')]
assert len(message_ids())==501 and len(set(message_ids()))==501
raw_rows=[line.split('\t') for line in log.read_text().splitlines()]
raw_messages=[parts for parts in raw_rows if len(parts)>9 and parts[1]=='assistant_message' and (parts[9].startswith('refresh-msg-') or parts[9]=='second-relative-msg')]
assert len(raw_messages)==501 and all(parts[5]=='unknown' for parts in raw_messages)
records=[module.parse_row(parts,n) for n,parts in enumerate(raw_rows)]
messages=[row for row in records if row['event_type']=='assistant_message' and (row['event_key'].startswith('refresh-msg-') or row['event_key']=='second-relative-msg')]
assert all(row['session_id']=='' for row in messages)
assert all(row['repo_root']==str(old_cwd.resolve()) for row in messages if row['event_key'].startswith('refresh-msg-'))
assert next(row for row in messages if row['event_key']=='second-relative-msg')['repo_root']==str(other_cwd.resolve())
assert all(json.loads(row['evidence_json'])['session_source']=='unavailable' for row in messages)
assert len(list(cursors.glob('*.offset')))==2
subprocess.run(['bash',str(report),'--resume-pending'],env=report_env,text=True,capture_output=True,check=True,timeout=30)
assert len(message_ids())==501 and len(set(message_ids()))==501
assert 'NEVER_LOG_CHILD_CONTENT' not in log.read_text(encoding='utf-8')
print('PASS: relative child source identities stay distinct and a bounded cursor resumes after cwd deletion')
PY

echo "PASS: contention spools durably, report exposes pending count, and duplicate drain is idempotent"
