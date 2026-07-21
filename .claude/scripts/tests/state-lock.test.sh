#!/usr/bin/env bash
# Unit + concurrency tests for the session-state write lock (issue #639 —
# session-state.json had no lock, so two writers that both read, both modified,
# and both wrote back silently lost one of the two changes).
#
# Uses a temporary HOME so it never touches the real ~/.claude/. Requires jq.
# Run from repo root:
#   bash .claude/scripts/tests/state-lock.test.sh
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/.claude/scripts/session-state.sh"
LOCK_LIB="$REPO_ROOT/.claude/scripts/state-lock.sh"

TMP_HOME="$(mktemp -d)"
cleanup() { rm -rf "$TMP_HOME"; }
trap cleanup EXIT
export HOME="$TMP_HOME"
mkdir -p "$HOME/.claude"
STATE_FILE="$HOME/.claude/session-state.json"
LOCK_DIR="$STATE_FILE.lock"

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
reset_state() { rm -rf "$STATE_FILE" "$LOCK_DIR"; }

echo "== Two concurrent writers to different paths: both changes survive =="
reset_state
run --set '.seed=1'
( run --set '.alpha="a"' ) &
( run --set '.beta="b"' ) &
wait
check_eq "alpha survived" 'a' "$(jq -r '.alpha' "$STATE_FILE")"
check_eq "beta survived" 'b' "$(jq -r '.beta' "$STATE_FILE")"
check_eq "pre-existing sibling preserved" '1' "$(jq -r '.seed' "$STATE_FILE")"

echo
echo "== 20 concurrent writers: valid JSON and every write present =="
reset_state
RC_LOG="$TMP_HOME/rc.log"
: > "$RC_LOG"
# Generous explicit timeout: `mkdir` contention is not FIFO, so on a loaded
# box an unlucky writer can lose several rounds. That tail is a scheduling
# property, not a correctness one — the assertions below still require every
# single writer to succeed, so a genuine wedge fails the test loudly.
for i in $(seq 1 20); do
  ( CLAUDE_STATE_LOCK_TIMEOUT=120 run --set ".w$i=$i"; echo "$?" >> "$RC_LOG" ) &
done
wait
check_eq "every writer exited 0" "" "$(grep -v '^0$' "$RC_LOG" | tr '\n' ' ' | sed 's/ $//')"
check_eq "file is valid JSON" "0" "$(jq -e . "$STATE_FILE" >/dev/null 2>&1; echo $?)"
check_eq "exactly one top-level JSON document" "true" "$(jq -s 'length == 1' "$STATE_FILE" 2>/dev/null)"
check_eq "all 20 writes present" "20" "$(jq -r '[keys[] | select(startswith("w"))] | length' "$STATE_FILE")"
check_eq "each write holds its own value" "true" \
  "$(jq -r '. as $root | all(range(1;21); $root["w" + tostring] == .)' "$STATE_FILE")"
check_eq "no lock directory left behind" "0" "$([[ -e "$LOCK_DIR" ]] && echo 1 || echo 0)"

echo
echo "== Holder killed mid-write: lock is recoverable, state file intact =="
reset_state
run --set '.before="kept"'
# Hold the lock in a background process, then SIGKILL it (no traps run, so the
# lock directory survives its death — exactly the stale case mkdir locking has
# to handle explicitly since the kernel does not release it for us).
bash -c 'source "$1"; state_lock_acquire "$2" || exit 6; printf "held\n" > "$3"; sleep 60' \
  _ "$LOCK_LIB" "$STATE_FILE" "$TMP_HOME/held" &
HOLDER=$!
for _ in $(seq 1 100); do [[ -f "$TMP_HOME/held" ]] && break; sleep 0.05; done
check_eq "lock directory exists while held" "1" "$([[ -d "$LOCK_DIR" ]] && echo 1 || echo 0)"
kill -9 "$HOLDER" 2>/dev/null
wait "$HOLDER" 2>/dev/null
check_eq "lock survives the killed holder (stale, not auto-released)" "1" "$([[ -d "$LOCK_DIR" ]] && echo 1 || echo 0)"
OUT="$(CLAUDE_STATE_LOCK_TIMEOUT=5 run --set '.after="written"' 2>&1)"; RC=$?
check_eq "next writer recovers the stale lock (exit 0)" "0" "$RC"
check_eq "stale-break is reported on stderr" "1" "$(grep -c 'broke stale lock' <<<"$OUT")"
check_eq "new write landed" 'written' "$(jq -r '.after' "$STATE_FILE")"
check_eq "pre-kill data intact" 'kept' "$(jq -r '.before' "$STATE_FILE")"
check_eq "state file still valid JSON" "0" "$(jq -e . "$STATE_FILE" >/dev/null 2>&1; echo $?)"

echo
echo "== Lock timeout: distinct exit 6, state file unmodified =="
reset_state
run --set '.untouched="yes"'
BEFORE="$(cat "$STATE_FILE")"
# A live holder (this test process) with a fresh timestamp is NOT stale, so the
# waiter must time out rather than break the lock.
mkdir -p "$LOCK_DIR"
{
  printf 'pid=%s\n' "$$"
  printf 'host=%s\n' "$(hostname)"
  printf 'epoch=%s\n' "$(date +%s)"
} > "$LOCK_DIR/owner"
OUT="$(CLAUDE_STATE_LOCK_TIMEOUT=1 run --set '.blocked="should not land"' 2>&1)"; RC=$?
check_eq "timed-out writer exits 6" "6" "$RC"
check_eq "timeout message names the lock" "1" "$(grep -c 'timed out after 1s waiting' <<<"$OUT")"
check_eq "timeout message refuses to write unserialized" "1" "$(grep -c 'refusing to write unserialized' <<<"$OUT")"
check_eq "state file byte-identical after the timeout" "$BEFORE" "$(cat "$STATE_FILE")"
check_eq "the live holder's lock was NOT broken" "1" "$([[ -d "$LOCK_DIR" ]] && echo 1 || echo 0)"
rm -rf "$LOCK_DIR"

echo
echo "== Age-based staleness: a lock older than STALE_AGE is broken =="
reset_state
run --set '.x=1'
mkdir -p "$LOCK_DIR"
{
  printf 'pid=%s\n' "$$"          # alive, but the lock is ancient
  printf 'host=%s\n' "$(hostname)"
  printf 'epoch=%s\n' "$(( $(date +%s) - 9999 ))"
} > "$LOCK_DIR/owner"
CLAUDE_STATE_LOCK_TIMEOUT=5 run --set '.y=2' 2>/dev/null; RC=$?
check_eq "ancient lock broken, write succeeds" "0" "$RC"
check_eq "write landed" "2" "$(jq -r '.y' "$STATE_FILE")"

echo
echo "== Foreign-host lock: pid check skipped, age rule still applies =="
reset_state
mkdir -p "$LOCK_DIR"
{
  printf 'pid=%s\n' "1"
  printf 'host=%s\n' "some-other-machine"
  printf 'epoch=%s\n' "$(date +%s)"
} > "$LOCK_DIR/owner"
CLAUDE_STATE_LOCK_TIMEOUT=1 run --set '.z=3' 2>/dev/null; RC=$?
check_eq "fresh foreign lock is respected (exit 6, not stolen)" "6" "$RC"
rm -rf "$LOCK_DIR"

echo
echo "== Legacy flock artifact: a regular FILE at the lock path is cleared =="
reset_state
: > "$LOCK_DIR"   # what the old flock(1) path in cr-review-hourly.sh created
CLAUDE_STATE_LOCK_TIMEOUT=3 run --set '.legacy=true' 2>/dev/null; RC=$?
check_eq "write succeeds despite the legacy lock file" "0" "$RC"
check_eq "value landed" "true" "$(jq -r '.legacy' "$STATE_FILE")"

echo
echo "== Re-entrancy: a holder shelling out to the script does not deadlock =="
reset_state
OUT="$(bash -c 'source "$1"; state_lock_acquire "$2" || exit 6; CLAUDE_STATE_LOCK_TIMEOUT=2 bash "$3" --set ".nested=1"; echo "rc=$?"' \
  _ "$LOCK_LIB" "$STATE_FILE" "$SCRIPT" 2>&1)"
check_eq "nested write under a held lock succeeds" "1" "$(grep -c 'rc=0' <<<"$OUT")"
check_eq "nested value landed" "1" "$(jq -r '.nested' "$STATE_FILE")"

echo
echo "== Reads are not blocked by a held lock =="
reset_state
run --set '.readable="yes"'
mkdir -p "$LOCK_DIR"
{ printf 'pid=%s\n' "$$"; printf 'host=%s\n' "$(hostname)"; printf 'epoch=%s\n' "$(date +%s)"; } > "$LOCK_DIR/owner"
GOT="$(CLAUDE_STATE_LOCK_TIMEOUT=1 run --get '.readable')"; RC=$?
check_eq "--get succeeds while a writer holds the lock" "0" "$RC"
check_eq "--get returns the value" "yes" "$GOT"
rm -rf "$LOCK_DIR"

echo
echo "== Failed write releases the lock (rejected type-contract batch) =="
reset_state
run --set '.active_agents=notjson' 2>/dev/null; RC=$?
check_eq "rejected write still exits 4 (field-type contract preserved)" "4" "$RC"
check_eq "lock released after the rejected write" "0" "$([[ -e "$LOCK_DIR" ]] && echo 1 || echo 0)"

echo
echo "== Release only deletes a lock we still own (CodeAnt, PR #662) =="
reset_state
# Ours was broken as stale and re-acquired by someone else: release must
# leave the new holder's lock alone.
bash -c 'source "$1"; state_lock_acquire "$2" || exit 6
         printf "pid=999999\nhost=%s\nepoch=%s\n" "$(hostname)" "$(date +%s)" > "$2.lock/owner"
         state_lock_release' _ "$LOCK_LIB" "$STATE_FILE"
check_eq "foreign-owned lock is NOT deleted by our release" "1" "$([[ -d "$LOCK_DIR" ]] && echo 1 || echo 0)"
rm -rf "$LOCK_DIR"
# Empty/unwritten owner file is the mkdir-then-stamp window of ANOTHER
# process — also not ours, so it must survive our release.
bash -c 'source "$1"; state_lock_acquire "$2" || exit 6
         : > "$2.lock/owner"
         state_lock_release' _ "$LOCK_LIB" "$STATE_FILE"
check_eq "empty-owner lock is NOT deleted by our release" "1" "$([[ -d "$LOCK_DIR" ]] && echo 1 || echo 0)"
rm -rf "$LOCK_DIR"
# Sanity: the normal case still releases.
bash -c 'source "$1"; state_lock_acquire "$2" || exit 6; state_lock_release' _ "$LOCK_LIB" "$STATE_FILE"
check_eq "our own lock IS released normally" "0" "$([[ -e "$LOCK_DIR" ]] && echo 1 || echo 0)"

echo
echo "== Read-only greptile-budget --check never blocks on the lock (CodeAnt, PR #662) =="
reset_state
GB="$REPO_ROOT/.claude/scripts/greptile-budget.sh"
# Seed today's counter so --check has nothing to persist (no cross-day
# rollover, no --budget override) — the read-only common case.
bash "$GB" --consume >/dev/null 2>&1
mkdir -p "$LOCK_DIR"
{ printf 'pid=%s\n' "$$"; printf 'host=%s\n' "$(hostname)"; printf 'epoch=%s\n' "$(date +%s)"; } > "$LOCK_DIR/owner"
OUT="$(CLAUDE_STATE_LOCK_TIMEOUT=1 bash "$GB" --check 2>/dev/null)"; RC=$?
check_eq "read-only --check succeeds while a writer holds the lock" "0" "$RC"
check_eq "--check still reports the seeded counter" "1" "$(printf '%s' "$OUT" | jq -r '.reviews_used')"
# The write path (cross-day rollover) DOES serialize: with the lock held it
# must time out with 6 rather than write unserialized.
CLAUDE_STATE_LOCK_TIMEOUT=1 bash "$GB" --check --budget 99 >/dev/null 2>&1; RC=$?
check_eq "--check that must persist still respects the lock (exit 6)" "6" "$RC"
rm -rf "$LOCK_DIR"

echo
echo "== summary: $PASS passed, $FAIL failed =="
if [[ "$FAIL" -gt 0 ]]; then
  echo "FAILED: state-lock tests" >&2
  exit 1
fi
echo "OK: session-state write-lock tests passed"
