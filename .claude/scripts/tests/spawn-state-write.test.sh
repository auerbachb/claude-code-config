#!/usr/bin/env bash
# catalog: tests — Exercises real PMM/subagent spawn batches, atomic failure, exact lock retry and unconfirmed-registration recovery evidence
set -uo pipefail
TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$TEST_DIR/../../.." && pwd)
# shellcheck source=lib/skill-bash.sh
source "$TEST_DIR/lib/skill-bash.sh"
TMP=$(mktemp -d) || exit 1
LOCK_PID=""
cleanup() {
  if [[ -n "$LOCK_PID" ]]; then kill "$LOCK_PID" 2>/dev/null || true; wait "$LOCK_PID" 2>/dev/null || true; fi
  rm -rf "$TMP"
}
trap cleanup EXIT
export HOME="$TMP/home" CLAUDE_SESSION_REPO=fixture/project
mkdir -p "$HOME/.claude" "$TMP/bin"
STATE_FILE="$HOME/.claude/session-state.json"
REAL_STATE="$ROOT/.claude/scripts/session-state.sh"
REAL_JQ=$(command -v jq)
CALLS="$TMP/writes"
export REAL_STATE REAL_JQ CALLS
PASS=0; FAIL=0
check() {
  if [[ "$2" == "$3" ]]; then PASS=$((PASS + 1)); echo "ok — $1"
  else FAIL=$((FAIL + 1)); echo "FAIL — $1 (expected '$2', actual '$3')"; fi
}
seed() {
  printf '%s\n' '{"last_updated":"before","monitoring_active":false,"active_agents":{"other":{"id":"other","status":"working"}},"repos":{"fixture/project":{"pipelines":{"61":{"started_at":"2026-10-01T00:00:00Z","pr":777,"claim_renewed_at":"2026-10-02T00:00:00Z","claim_holder":"fixture-holder"}}}}}' > "$STATE_FILE"
  printf '0\n' > "$CALLS"
}
PMM=$(extract_skill_bash "$ROOT/.claude/skills/pr-monitor-and-manage/references/pmm-act.md" pmm-spawn-record) || exit 1
SUB=$(extract_skill_bash "$ROOT/.claude/skills/subagent/SKILL.md" subagent-spawn-record) || exit 1
SUB=$(printf '%s' "$SUB" | sed 's/{ISSUE_NUMBER}/61/g')
OLD_PMM=$(extract_skill_bash "$TEST_DIR/fixtures/spawn-record-pre1642.md" old-pmm-spawn-record) || exit 1
OLD_SUB=$(extract_skill_bash "$TEST_DIR/fixtures/spawn-record-pre1642.md" old-subagent-spawn-record) || exit 1
OLD_SUB=$(printf '%s' "$OLD_SUB" | sed 's/{ISSUE_NUMBER}/61/g')
cat > "$TMP/bin/state" <<'STATE_WRAPPER'
#!/usr/bin/env bash
set -uo pipefail
is_write=false
for arg do [[ "$arg" != --set ]] || is_write=true; done
if [[ "$is_write" != true ]]; then
  case "${FAKE_READ_MODE:-}:$*" in
    key-error:--repo-key) exit 4 ;;
    key-invalid:--repo-key) echo invalid-key; exit 0 ;;
    pipeline-lock:*started_at*) exit 6 ;;
    claim-error:*claim_renewed_at*) exit 4 ;;
  esac
  exec "$REAL_STATE" --repo fixture/project "$@"
fi
read -r count < "$CALLS"
count=$((count + 1)); printf '%s\n' "$count" > "$CALLS"
printf '%s\0' "$@" > "$CALLS.argv.$count"
case "${WRITE_MODE:-success}" in
  transient) [[ "$count" -ne 1 ]] || exit 6 ;;
  lock) exit 6 ;;
  failure) exit 5 ;;
  type) exit 4 ;;
  missing) exit 127 ;;
esac
exec "$REAL_STATE" --repo fixture/project "$@"
STATE_WRAPPER
cat > "$TMP/bin/issue-ref" <<'ISSUE_REF'
#!/usr/bin/env bash
if [[ "${ISSUE_REF_MODE:-}" == invalid && "$2" == 101 ]]; then echo not-json; else echo null; fi
ISSUE_REF
chmod +x "$TMP/bin/state" "$TMP/bin/issue-ref"
export SESSION_STATE_SH="$TMP/bin/state" PR_ISSUE_REF_SH="$TMP/bin/issue-ref"
export WRITE_MODE FAKE_READ_MODE ISSUE_REF_MODE
WRITE_MODE=success; FAKE_READ_MODE=''; ISSUE_REF_MODE=''
SETUP=$(cat <<'CALLER_SETUP'
set -uo pipefail
GATE_BY_PR=()
GATE_BY_PR[101]='{"head_sha":"head-a"}'
GATE_BY_PR[102]='{"head_sha":"head-b"}'
SPAWNED_PR_NUMS="${TEST_PR_NUMS-101 102}"
if [[ "${TEST_BAD_HEAD:-}" == 1 ]]; then GATE_BY_PR[101]='{"head_sha":null}'; fi
AGENT_ID="${TEST_AGENT_ID-fixture-agent}"
TASK="${TEST_TASK-fixture task}"
CLAIM_HOLDER=fixture-holder
SUCCESSOR_KIND="${TEST_SUCCESSOR_KIND:-}"
date() {
  # Only the caller gets this clock. Native state-helper children retain date.
  printf '%s\n' '2026-11-08T21:00:00Z'
}
CALLER_SETUP
)
run_block() {
  RC=0
  OUT=$(bash -c "$SETUP"$'\n'"$1" 2>&1) || RC=$?
}
get() { jq -r "$1" "$STATE_FILE"; }
state_footer() { printf '%s\n' "$OUT" | sed -n 's/^SPAWN_STATE=//p'; }
check_pending() {
  local pending valid=0
  pending=$(printf '%s\n' "$OUT" | sed -n 's/^SPAWN_STATE_PENDING=//p')
  PENDING_JSON="$pending" python3 - "$CALLS.argv.1" <<'CHECK_PENDING' || valid=$?
import json,os,pathlib,sys
x=json.loads(os.environ['PENDING_JSON'])
assert x['registration']=='unconfirmed' and x['requires_task_observation'] is True
assert x['agent_keys']
args=pathlib.Path(sys.argv[1]).read_bytes().split(b'\0')[:-1]
assert x['args']==[a.decode() for a in args]
CHECK_PENDING
  check 'pending checkpoint retains exact original argv' 0 "$valid"
}
for SITE in pmm subagent; do
  if [[ "$SITE" == pmm ]]; then BLOCK="$PMM"; else BLOCK="$SUB"; fi
  for WRITE_MODE in success transient lock failure type missing; do
    seed
    BEFORE=$(cat "$STATE_FILE")
    run_block "$BLOCK"
    case "$WRITE_MODE" in
      success|transient)
        check "$SITE $WRITE_MODE: succeeds" 0 "$RC"
        check "$SITE $WRITE_MODE: confirmed registration" recorded "$(state_footer)"
        if [[ "$WRITE_MODE" == transient ]]; then EXPECT_WRITES=2; else EXPECT_WRITES=1; fi
        check "$SITE $WRITE_MODE: bounded attempts" "$EXPECT_WRITES" "$(cat "$CALLS")"
        check "$SITE $WRITE_MODE: sibling agent preserved" working "$(get '.active_agents.other.status')"
        if [[ "$SITE" == pmm ]]; then
          check 'PMM: both agents are objects' 'object|object' "$(jq -r '[.active_agents["pmm-fix-101"],.active_agents["pmm-fix-102"]]|map(type)|join("|")' "$STATE_FILE")"
          check 'PMM: each lock keeps its own head' 'head-a|head-b' "$(jq -r '[.pmm_in_flight["101"].head_sha,.pmm_in_flight["102"].head_sha]|join("|")' "$STATE_FILE")"
        else
          check 'subagent: pipeline and monitoring match its agent' '2026-11-08T21:00:00Z|null|true|spawned' "$(jq -r '[.repos["fixture/project"].pipelines["61"].started_at,(.repos["fixture/project"].pipelines["61"].pr|tostring),(.monitoring_active|tostring),.active_agents["fixture-agent"].status]|join("|")' "$STATE_FILE")"
          check 'subagent: existing claim age remains intact' 2026-10-02T00:00:00Z "$(get '.repos["fixture/project"].pipelines["61"].claim_renewed_at')"
        fi
        if [[ "$WRITE_MODE" == transient ]]; then
          SAME=0; cmp "$CALLS.argv.1" "$CALLS.argv.2" || SAME=$?
          check "$SITE: lock retry keeps every original arg/timestamp/ID" 0 "$SAME"
        fi ;;
      *)
        case "$WRITE_MODE" in lock) EXPECT_RC=6; EXPECT_WRITES=2 ;; failure) EXPECT_RC=5; EXPECT_WRITES=1 ;; type) EXPECT_RC=4; EXPECT_WRITES=1 ;; missing) EXPECT_RC=127; EXPECT_WRITES=1 ;; esac
        check "$SITE $WRITE_MODE: real failure status preserved" "$EXPECT_RC" "$RC"
        check "$SITE $WRITE_MODE: exact attempt count" "$EXPECT_WRITES" "$(cat "$CALLS")"
        check "$SITE $WRITE_MODE: previous state byte-identical" "$BEFORE" "$(cat "$STATE_FILE")"
        check "$SITE $WRITE_MODE: registration explicitly unconfirmed" "failed rc=$EXPECT_RC reason=write" "$(state_footer)"
        check_pending ;;
    esac
  done
done
WRITE_MODE=success
seed
TEST_PR_NUMS='' run_block "$PMM"
check 'zero PMM spawns is an explicit no-op' none "$(state_footer)"
check 'zero PMM spawns never invoke a write' 0 "$(cat "$CALLS")"
for SITE in pmm subagent; do
  seed; BEFORE=$(cat "$STATE_FILE")
  if [[ "$SITE" == pmm ]]; then
    ISSUE_REF_MODE=invalid run_block "$PMM"
  else
    BAD_SUB=$(printf '%s' "$SUB" | sed 's/--argjson issue "61"/--argjson issue "not-json"/')
    run_block "$BAD_SUB"
  fi
  check "$SITE: invalid entry construction fails before writes" 4 "$RC"
  check "$SITE: no semantic partial/string entry is committed" 0 "$(cat "$CALLS")"
  check "$SITE: metadata failure preserves previous state" "$BEFORE" "$(cat "$STATE_FILE")"
  # Published callers let empty ENTRY fall through to the writer's string mode.
  seed
  if [[ "$SITE" == pmm ]]; then
    ISSUE_REF_MODE=invalid run_block "$OLD_PMM"
    KIND=$(get '.active_agents["pmm-fix-101"]|type')
  else
    BAD_OLD=$(printf '%s' "$OLD_SUB" | sed 's/--argjson issue "61"/--argjson issue "not-json"/')
    run_block "$BAD_OLD"
    KIND=$(get '.active_agents["fixture-agent"]|type')
  fi
  check "$SITE negative: old caller falsely succeeds on invalid entry" 0 "$RC"
  check "$SITE negative: old caller stores a string agent" string "$KIND"
  check "$SITE negative: old caller has no outcome classification" '' "$(state_footer)"
done
seed; BEFORE=$(cat "$STATE_FILE")
TEST_BAD_HEAD=1 run_block "$PMM"
check 'missing per-PR head declines the complete PMM record batch' 4 "$RC"
check 'missing per-PR head never commits the other valid sibling' 0 "$(cat "$CALLS")"
check 'missing head leaves state unchanged' "$BEFORE" "$(cat "$STATE_FILE")"
seed
TEST_SUCCESSOR_KIND=retry run_block "$SUB"
check 'explicit retry succeeds' 0 "$RC"
check 'explicit retry preserves original Start and PR link' '2026-10-01T00:00:00Z|777' "$(jq -r '[.repos["fixture/project"].pipelines["61"].started_at,(.repos["fixture/project"].pipelines["61"].pr|tostring)]|join("|")' "$STATE_FILE")"
for FAKE_READ_MODE in pipeline-lock claim-error key-error key-invalid; do
  seed; BEFORE=$(cat "$STATE_FILE")
  if [[ "$FAKE_READ_MODE" == pipeline-lock ]]; then
    TEST_SUCCESSOR_KIND=retry run_block "$SUB"; EXPECT_RC=6
  else run_block "$SUB"; EXPECT_RC=4; fi
  check "$FAKE_READ_MODE: required read failure stays failed" "$EXPECT_RC" "$RC"
  check "$FAKE_READ_MODE: a read failure cannot trigger a write retry" 0 "$(cat "$CALLS")"
  check "$FAKE_READ_MODE: no unknown state is treated as absence" "$BEFORE" "$(cat "$STATE_FILE")"
done
FAKE_READ_MODE=''
for BAD in agent task; do
  seed; BEFORE=$(cat "$STATE_FILE")
  if [[ "$BAD" == agent ]]; then TEST_AGENT_ID='' run_block "$SUB"; else TEST_TASK='' run_block "$SUB"; fi
  check "missing $BAD metadata declines registration" 4 "$RC"
  check "missing $BAD metadata makes no write" 0 "$(cat "$CALLS")"
  check "missing $BAD metadata preserves prior state" "$BEFORE" "$(cat "$STATE_FILE")"
done

# JSON checkpoint failure must not mask the original writer failure. Bash's
# quoted-argv fallback keeps evidence without executing any pending payload.
cat > "$TMP/bin/jq" <<'JQ_WRAPPER'
#!/usr/bin/env bash
for arg do [[ "$arg" != --args ]] || exit 73; done
exec "$REAL_JQ" "$@"
JQ_WRAPPER
chmod +x "$TMP/bin/jq"
seed; BEFORE=$(cat "$STATE_FILE")
PATH="$TMP/bin:$PATH" WRITE_MODE=failure run_block "$SUB"
check 'checkpoint JSON failure preserves the writer exit' 5 "$RC"
check 'checkpoint JSON failure leaves state unchanged' "$BEFORE" "$(cat "$STATE_FILE")"
case "$OUT" in *SPAWN_STATE_PENDING_AGENT_KEYS_BEGIN*SPAWN_STATE_PENDING_ARGV_BEGIN*--set*SPAWN_STATE_PENDING_ARGV_END*) check 'checkpoint falls back to quoted data' yes yes ;; *) check 'checkpoint falls back to quoted data' yes "$OUT" ;; esac
rm -f "$TMP/bin/jq"

# The actual writer's transaction contract: a late path/type failure cannot
# leave a pipeline/monitor flag behind without its agent records, or vice versa.
for FAILURE in path type; do
  seed; BEFORE=$(cat "$STATE_FILE"); RC=0
  if [[ "$FAILURE" == path ]]; then BAD_SET='.broken[=1'; else BAD_SET='.active_agents=false'; fi
  "$REAL_STATE" --repo fixture/project \
    --set '.repos["fixture/project"].pipelines["9"].started_at="new"' \
    --set '.monitoring_active=true' --set '.active_agents["new"]={"id":"new"}' \
    --set "$BAD_SET" > "$TMP/native-$FAILURE.log" 2>&1 || RC=$?
  check "$FAILURE: native invalid batch fails" false "$(if [[ "$RC" -eq 0 ]]; then echo true; else echo false; fi)"
  check "$FAILURE: native invalid batch is byte-atomic" "$BEFORE" "$(cat "$STATE_FILE")"
done
seed
"$REAL_STATE" --repo fixture/project --set '.repos["fixture/project"].pipelines["9"].started_at="new"' \
  --set '.monitoring_active=true' --set '.active_agents["new"]={"id":"new"}' > "$TMP/native-valid.log" 2>&1
check 'native valid batch commits all related keys' 'new|true|new|working' "$(jq -r '[.repos["fixture/project"].pipelines["9"].started_at,(.monitoring_active|tostring),.active_agents.new.id,.active_agents.other.status]|join("|")' "$STATE_FILE")"
seed; BEFORE=$(cat "$STATE_FILE")
STATE_LOCK_SH="$ROOT/.claude/scripts/state-lock.sh"
READY="$TMP/lock-ready"; RELEASE="$TMP/lock-release"
export STATE_LOCK_SH STATE_FILE READY RELEASE
bash -c 'source "$STATE_LOCK_SH"; state_lock_acquire "$STATE_FILE" 2 || exit; : > "$READY"; while [[ ! -e "$RELEASE" ]]; do sleep 0.1; done; state_lock_release' &
LOCK_PID=$!
for ((i=0;i<50;i++)); do [[ ! -f "$READY" ]] || break; sleep 0.1; done
[[ -f "$READY" ]] || { echo 'fixture lock did not acquire'; exit 1; }
RC=0
CLAUDE_STATE_LOCK_TIMEOUT=1 "$REAL_STATE" --repo fixture/project \
  --set '.monitoring_active=true' --set '.active_agents["new"]={"id":"new"}' > "$TMP/native-lock.log" 2>&1 || RC=$?
check 'native lock contention returns six' 6 "$RC"
check 'native lock contention leaves state byte-identical' "$BEFORE" "$(cat "$STATE_FILE")"
: > "$RELEASE"; wait "$LOCK_PID"; LOCK_PID=''
printf 'Passed: %s  Failed: %s\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
