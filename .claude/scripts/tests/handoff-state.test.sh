#!/usr/bin/env bash
# Unit + concurrency tests for handoff-state.sh (issue #682 —
# handoff files had the same unlocked RMW profile session-state.json had before #639;
# concurrent orchestrators (/babysit-pr, /pr-monitor-and-manage, Phase B) silently lost
# each other's array appends when they all read-modify-wrote at once).
#
# Uses a temporary HOME so it never touches the real ~/.claude/. Requires jq.
# Run from repo root:
#   bash .claude/scripts/tests/handoff-state.test.sh
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/.claude/scripts/handoff-state.sh"
LOCK_LIB="$REPO_ROOT/.claude/scripts/state-lock.sh"

if [[ ! -f "$SCRIPT" ]]; then
  echo "FAIL: $SCRIPT not found" >&2; exit 1
fi
if [[ ! -f "$LOCK_LIB" ]]; then
  echo "FAIL: $LOCK_LIB not found" >&2; exit 1
fi

TMP_HOME="$(mktemp -d)"
cleanup() { rm -rf "$TMP_HOME"; }
trap cleanup EXIT
export HOME="$TMP_HOME"
mkdir -p "$HOME/.claude/handoffs"

PR="99"
HANDOFF_FILE="$HOME/.claude/handoffs/pr-${PR}-handoff.json"
LOCK_DIR="$HANDOFF_FILE.lock"

PASS=0
FAIL=0
check_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    PASS=$((PASS + 1)); echo "ok   — $desc"
  else
    FAIL=$((FAIL + 1)); echo "FAIL — $desc (expected '$expected', got '$actual')"
  fi
}

run() { bash "$SCRIPT" "$@"; }
reset_handoff() { rm -rf "$HANDOFF_FILE" "$LOCK_DIR"; }

SEED_JSON='{"schema_version":"1.0","pr_number":99,"head_sha":"aaa","reviewer":"cr",
  "phase_completed":"A","created_at":"2026-01-01T00:00:00Z",
  "findings_fixed":[],"findings_dismissed":[],
  "threads_replied":[],"threads_resolved":[],
  "files_changed":[],"push_timestamp":"2026-01-01T00:00:00Z","notes":""}'

echo "== --create: writes valid JSON =="
reset_handoff
run --create "$PR" "$SEED_JSON"
check_eq "--create exits 0" "0" "$?"
check_eq "file exists after --create" "1" "$([[ -f "$HANDOFF_FILE" ]] && echo 1 || echo 0)"
check_eq "file is valid JSON" "0" "$(jq -e . "$HANDOFF_FILE" >/dev/null 2>&1; echo $?)"
check_eq "pr_number round-trips" "99" "$(jq -r '.pr_number' "$HANDOFF_FILE")"

echo
echo "== --get: lock-free read returns the file =="
reset_handoff
run --create "$PR" "$SEED_JSON"
GOT="$(run --get "$PR")"
check_eq "--get exits 0 when file exists" "0" "$?"
check_eq "--get returns valid JSON" "0" "$(printf '%s' "$GOT" | jq -e . >/dev/null 2>&1; echo $?)"
check_eq "--get on missing file exits 3" "3" "$(run --get "999" 2>/dev/null; echo $?)"

echo
echo "== --set: locked scalar update =="
reset_handoff
run --create "$PR" "$SEED_JSON"
run --set "$PR" ".head_sha=bbb"
check_eq "--set exits 0" "0" "$?"
check_eq ".head_sha updated" "bbb" "$(jq -r '.head_sha' "$HANDOFF_FILE")"
check_eq "other fields preserved after --set" "99" "$(jq -r '.pr_number' "$HANDOFF_FILE")"

echo
echo "== --append: string arrays dedup by exact value =="
reset_handoff
run --create "$PR" "$SEED_JSON"
run --append "$PR" "findings_fixed" '"fix-1"'
run --append "$PR" "findings_fixed" '"fix-2"'
run --append "$PR" "findings_fixed" '"fix-1"'   # duplicate — should be deduplicated
check_eq "--append exits 0" "0" "$?"
check_eq "string array deduped to 2 elements" "2" \
  "$(jq '.findings_fixed | length' "$HANDOFF_FILE")"
check_eq "fix-1 present" "fix-1" \
  "$(jq -r '.findings_fixed[0]' "$HANDOFF_FILE")"
check_eq "fix-2 present" "fix-2" \
  "$(jq -r '.findings_fixed[1]' "$HANDOFF_FILE")"

echo
echo "== --append findings_dismissed: dedup by .id =="
reset_handoff
run --create "$PR" "$SEED_JSON"
run --append "$PR" "findings_dismissed" '{"id":"fd-1","reason":"false positive"}'
run --append "$PR" "findings_dismissed" '{"id":"fd-2","reason":"out of scope"}'
run --append "$PR" "findings_dismissed" '{"id":"fd-1","reason":"updated reason"}'  # same id, dedup
check_eq "findings_dismissed deduped to 2 elements (by .id)" "2" \
  "$(jq '.findings_dismissed | length' "$HANDOFF_FILE")"
IDS="$(jq -r '[.findings_dismissed[].id] | sort | join(",")' "$HANDOFF_FILE")"
check_eq "both .id values present" "fd-1,fd-2" "$IDS"

echo
echo "== --delete: removes the file, idempotent =="
reset_handoff
run --create "$PR" "$SEED_JSON"
run --delete "$PR"
check_eq "--delete exits 0" "0" "$?"
check_eq "file absent after --delete" "0" "$([[ -f "$HANDOFF_FILE" ]] && echo 1 || echo 0)"
run --delete "$PR"   # second delete: idempotent
check_eq "--delete again exits 0 (idempotent)" "0" "$?"

echo
echo "== Two concurrent --append writers: both appends survive =="
reset_handoff
run --create "$PR" "$SEED_JSON"
# Two writers race to append different values to the same string array.
# Without the lock, one append would be lost; with it, both must survive.
( run --append "$PR" "threads_replied" '"thread-alpha"' ) &
( run --append "$PR" "threads_replied" '"thread-beta"' ) &
wait
COUNT="$(jq '.threads_replied | length' "$HANDOFF_FILE")"
check_eq "both concurrent appends survived (length=2)" "2" "$COUNT"
VALS="$(jq -r '.threads_replied | sort | join(",")' "$HANDOFF_FILE")"
check_eq "thread-alpha present" "1" "$(grep -c 'thread-alpha' <<<"$VALS")"
check_eq "thread-beta present" "1" "$(grep -c 'thread-beta' <<<"$VALS")"
check_eq "file is still valid JSON after concurrent writes" "0" \
  "$(jq -e . "$HANDOFF_FILE" >/dev/null 2>&1; echo $?)"

echo
echo "== 20 concurrent --append writers: all appends present =="
reset_handoff
run --create "$PR" "$SEED_JSON"
RC_LOG="$TMP_HOME/rc.log"
: > "$RC_LOG"
for i in $(seq 1 20); do
  ( CLAUDE_STATE_LOCK_TIMEOUT=120 run --append "$PR" "files_changed" "\"file-${i}.sh\""; \
    echo "$?" >> "$RC_LOG" ) &
done
wait
check_eq "every concurrent --append exited 0" "" \
  "$(grep -v '^0$' "$RC_LOG" | tr '\n' ' ' | sed 's/ $//')"
check_eq "file is valid JSON after 20 concurrent appends" "0" \
  "$(jq -e . "$HANDOFF_FILE" >/dev/null 2>&1; echo $?)"
check_eq "all 20 unique filenames present" "20" \
  "$(jq '.files_changed | length' "$HANDOFF_FILE")"

echo
echo "== Holder killed mid-write: lock is recoverable, handoff intact =="
reset_handoff
run --create "$PR" "$SEED_JSON"
run --set "$PR" ".notes=before_kill"
bash -c 'source "$1"; state_lock_acquire "$2" || exit 6; printf "held\n" > "$3"; sleep 60' \
  _ "$LOCK_LIB" "$HANDOFF_FILE" "$TMP_HOME/held" &
HOLDER=$!
for _ in $(seq 1 100); do [[ -f "$TMP_HOME/held" ]] && break; sleep 0.05; done
check_eq "lock directory exists while held" "1" \
  "$([[ -d "$LOCK_DIR" ]] && echo 1 || echo 0)"
kill -9 "$HOLDER" 2>/dev/null
wait "$HOLDER" 2>/dev/null
OUT="$(CLAUDE_STATE_LOCK_TIMEOUT=5 run --set "$PR" ".notes=after_kill" 2>&1)"; RC=$?
check_eq "next writer recovers the stale lock (exit 0)" "0" "$RC"
check_eq "stale-break reported on stderr" "1" "$(grep -c 'broke stale lock' <<<"$OUT")"
check_eq "new write landed" "after_kill" "$(jq -r '.notes' "$HANDOFF_FILE")"
check_eq "handoff file still valid JSON" "0" \
  "$(jq -e . "$HANDOFF_FILE" >/dev/null 2>&1; echo $?)"

echo
echo "== Lock timeout: exit 6, handoff file unmodified =="
reset_handoff
run --create "$PR" "$SEED_JSON"
run --set "$PR" ".notes=untouched"
BEFORE="$(cat "$HANDOFF_FILE")"
mkdir -p "$LOCK_DIR"
{
  printf 'pid=%s\n' "$$"
  printf 'host=%s\n' "$(hostname)"
  printf 'epoch=%s\n' "$(date +%s)"
} > "$LOCK_DIR/owner"
OUT="$(CLAUDE_STATE_LOCK_TIMEOUT=1 run --set "$PR" ".notes=should_not_land" 2>&1)"; RC=$?
check_eq "timed-out writer exits 6" "6" "$RC"
check_eq "handoff file byte-identical after timeout" "$BEFORE" "$(cat "$HANDOFF_FILE")"
check_eq "live holder's lock NOT broken" "1" "$([[ -d "$LOCK_DIR" ]] && echo 1 || echo 0)"
rm -rf "$LOCK_DIR"

echo
echo "== Usage errors: exit 2 on bad args =="
run --create 2>/dev/null; check_eq "--create missing args exits 2" "2" "$?"
run --set 2>/dev/null;    check_eq "--set missing args exits 2" "2" "$?"
run --append 2>/dev/null; check_eq "--append missing args exits 2" "2" "$?"
run --delete 2>/dev/null; check_eq "--delete missing args exits 2" "2" "$?"
run --bogus 2>/dev/null;  check_eq "unknown flag exits 2" "2" "$?"

echo
echo "==================================="
echo "Results: $PASS passed, $FAIL failed"
echo "==================================="

[[ $FAIL -eq 0 ]]
