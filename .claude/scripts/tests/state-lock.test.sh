#!/usr/bin/env bash
# Unit + concurrency tests for the session-state write lock (issue #639 —
# session-state.json had no lock, so two writers that both read, both modified,
# and both wrote back silently lost one of the two changes).
# catalog: tests — Tests for `state-lock.sh`
#
# Uses a temporary HOME so it never touches the real ~/.claude/. Requires jq.
# Run from repo root:
#   bash .claude/scripts/tests/state-lock.test.sh
# covers:
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
echo "== Concurrency holds across the per-repo scoped write path (issue #638) =="
reset_state
# #638 rewrites a leading .prs/.root_repo into .repos["<owner>/<name>"], so a
# scoped --set does strictly more work between read and mv than the flat paths
# above. The lock has to cover that rewrite too, not just the plain assignment.
export CLAUDE_SESSION_REPO="auerbachb/claude-code-config"
for i in $(seq 1 20); do
  ( CLAUDE_STATE_LOCK_TIMEOUT=120 run --set ".prs[\"$i\"].phase=B" ) &
done
wait
check_eq "all 20 scoped per-PR writes survive" "20" \
  "$(jq -r '[.repos[]?.prs // {} | keys[]] | length' "$STATE_FILE")"
check_eq "scoped state file is valid JSON" "0" "$(jq -e . "$STATE_FILE" >/dev/null 2>&1; echo $?)"
check_eq "no lock directory left behind (scoped path)" "0" "$([[ -e "$LOCK_DIR" ]] && echo 1 || echo 0)"
unset CLAUDE_SESSION_REPO

echo
echo "== issue #930: age lookup is portable and never invents an ancient lock =="
# The GNU/BSD `stat` split, directly. `-f` means --file-system on GNU coreutils
# and `%m` is then read as a FILE operand, so the old
# `stat -f %m … || stat -c %Y …` chain printed a filesystem dump AND the mtime
# and matched neither as a number — every unreadable owner file aged out to the
# 999999 sentinel, i.e. "instantly stale", on Linux only.
reset_state
mkdir -p "$LOCK_DIR"          # a lock directory with NO owner file yet
AGE="$(bash -c 'source "$1"; _state_lock_age "$2"' _ "$LOCK_LIB" "$LOCK_DIR")"
check_eq "age of a fresh owner-less lock is numeric" "1" \
  "$([[ "$AGE" =~ ^[0-9]+$ ]] && echo 1 || echo 0)"
check_eq "age of a fresh owner-less lock is small, not the old 999999 sentinel" "1" \
  "$([[ "$AGE" =~ ^[0-9]+$ && "$AGE" -lt 60 ]] && echo 1 || echo 0)"
# The other half of the contract: with NEITHER a recorded epoch nor a readable
# directory mtime, _state_lock_age must return non-zero and print nothing —
# never a fabricated age. That "unknown" is what makes the caller fail safe, so
# it needs its own assertion (CodeRabbit, PR #937).
UNKNOWN_OUT="$(bash -c 'source "$1"; _state_lock_age "/nonexistent/lock/path/for/930"' _ "$LOCK_LIB" 2>/dev/null)"; RC=$?
check_eq "unknowable age returns non-zero" "1" "$([[ "$RC" -ne 0 ]] && echo 1 || echo 0)"
check_eq "unknowable age prints nothing (no fabricated number)" "" "$UNKNOWN_OUT"
# Same directory, evaluated through the staleness rule that acts on it.
bash -c 'source "$1"; _state_lock_is_stale "$2" 120' _ "$LOCK_LIB" "$LOCK_DIR"; RC=$?
check_eq "a fresh owner-less lock is NOT stale (mid-acquire, not dead)" "1" "$RC"
# ...but a genuinely orphaned one still ages out, so a holder that died between
# mkdir and publishing `owner` can never wedge the fleet forever.
bash -c 'source "$1"; _state_lock_is_stale "$2" 0' _ "$LOCK_LIB" "$LOCK_DIR"; RC=$?
check_eq "an owner-less lock past STALE_AGE IS still breakable" "0" "$RC"
rm -rf "$LOCK_DIR"

echo
echo "== issue #930: a live holder's lock survives a contending acquirer =="
# The end-to-end shape of the bug: while one process holds the lock, another
# must never conclude "stale" and steal it. Deterministic — the holder is real
# and alive, no timing window is being raced.
reset_state
run --set '.notes=held'
bash -c 'source "$1"; state_lock_acquire "$2" || exit 6; printf "held\n" > "$3"; sleep 30' \
  _ "$LOCK_LIB" "$STATE_FILE" "$TMP_HOME/held930" &
HOLDER930=$!
for _ in $(seq 1 100); do [[ -f "$TMP_HOME/held930" ]] && break; sleep 0.05; done
HELD_TOKEN="$(sed -n 's/^token=//p' "$LOCK_DIR/owner" 2>/dev/null)"
OUT="$(CLAUDE_STATE_LOCK_TIMEOUT=2 run --set '.notes=stolen' 2>&1)"; RC=$?
check_eq "contending writer times out (exit 6) instead of stealing" "6" "$RC"
check_eq "no stale-break was reported against the live holder" "0" \
  "$(grep -c 'broke stale lock' <<<"$OUT")"
check_eq "the live holder still owns the lock (token unchanged)" "$HELD_TOKEN" \
  "$(sed -n 's/^token=//p' "$LOCK_DIR/owner" 2>/dev/null)"
check_eq "the contending write did NOT land" "held" "$(jq -r '.notes' "$STATE_FILE")"
kill -9 "$HOLDER930" 2>/dev/null; wait "$HOLDER930" 2>/dev/null
rm -rf "$LOCK_DIR"

echo
echo "== issue #930: owner metadata carries a per-acquisition token =="
reset_state
T1="$(bash -c 'source "$1"; state_lock_acquire "$2" || exit 6; sed -n "s/^token=//p" "$2.lock/owner"' _ "$LOCK_LIB" "$STATE_FILE")"
T2="$(bash -c 'source "$1"; state_lock_acquire "$2" || exit 6; sed -n "s/^token=//p" "$2.lock/owner"' _ "$LOCK_LIB" "$STATE_FILE")"
check_eq "a token is published" "1" "$([[ -n "$T1" ]] && echo 1 || echo 0)"
# Both must be nonempty before comparing them. An empty T2 — the second acquire
# failing, e.g. a release regression that made it block to timeout — compares
# unequal to T1, so the uniqueness check below would pass having tested nothing
# (CodeRabbit, PR #937).
check_eq "the second acquisition also published a token" "1" "$([[ -n "$T2" ]] && echo 1 || echo 0)"
check_eq "two acquisitions get different tokens" "1" \
  "$([[ -n "$T1" && -n "$T2" && "$T1" != "$T2" ]] && echo 1 || echo 0)"
rm -rf "$LOCK_DIR"

echo
echo "== issue #930: a robbed holder fails closed instead of committing =="
# Simulate the theft deterministically: acquire, then let a DIFFERENT process
# take the path over (exactly what breaking a stale lock does), and confirm the
# original holder notices. Without this the victim would commit a value it
# computed from a snapshot the thief has already replaced — a silent lost
# update, which is the whole failure in issue #930.
reset_state
OUT="$(bash -c '
  source "$1"
  # Positive control first: without this, every "theft detected" assertion below
  # would also pass against a library that simply lacks the function (the call
  # fails, the `||` branch fires) — a guard that passes by not running.
  declare -F state_lock_assert_held >/dev/null && echo "assert-fn-exists=yes"
  state_lock_acquire "$2" || exit 6
  state_lock_assert_held && echo "held-before=yes"
  # Someone else breaks our lock and takes it: the directory is replaced and a
  # new token published.
  mv "$2.lock" "$2.lock.stolen"
  mkdir "$2.lock"
  printf "pid=1\nhost=%s\nepoch=%s\ntoken=someone-else\n" "$(hostname)" "$(date +%s)" > "$2.lock/owner"
  state_lock_assert_held || echo "detected-theft=yes"
  # ...and our release must not delete the thief lock we no longer own.
  state_lock_release
  [[ -d "$2.lock" ]] && echo "thief-lock-intact=yes"
' _ "$LOCK_LIB" "$STATE_FILE" 2>&1)"
check_eq "state_lock_assert_held exists (positive control)" "1" "$(grep -c 'assert-fn-exists=yes' <<<"$OUT")"
check_eq "assert_held is true while genuinely held" "1" "$(grep -c 'held-before=yes' <<<"$OUT")"
check_eq "assert_held detects the theft" "1" "$(grep -c 'detected-theft=yes' <<<"$OUT")"
check_eq "release leaves the thief's lock alone" "1" "$(grep -c 'thief-lock-intact=yes' <<<"$OUT")"
rm -rf "$STATE_FILE.lock" "$STATE_FILE.lock.stolen"

echo
echo "== issue #930: a stolen read-modify-write is retried, never committed blind =="
# The theft has to land MID-FLIGHT — after the writer has acquired the lock and
# read its snapshot, but before it commits. Stealing the lock beforehand only
# proves that acquire times out; the writer never reaches assert_held, the
# commit, or the retry, so a regression in any of them would still pass
# (CodeAnt, PR #937).
#
# A `jq` shim earlier on PATH makes the timing deterministic instead of raced:
# the writer's first post-acquire jq call parks on a FIFO-style sentinel, the
# test steals the lock while it is parked, then releases it to continue into
# its commit.
reset_state
run --set '.keep="original"'
BEFORE="$(cat "$STATE_FILE")"
SHIM_BIN="$TMP_HOME/shimbin"; mkdir -p "$SHIM_BIN"
REAL_JQ="$(command -v jq)"
cat > "$SHIM_BIN/jq" <<SHIM
#!/usr/bin/env bash
# Park exactly once — on the first call made while the arm file exists — so we
# interpose after state_lock_acquire and before the commit.
if [[ -e "$TMP_HOME/arm" ]]; then
  rm -f "$TMP_HOME/arm"
  : > "$TMP_HOME/parked"
  for _ in \$(seq 1 200); do [[ -e "$TMP_HOME/go" ]] && break; sleep 0.05; done
fi
exec "$REAL_JQ" "\$@"
SHIM
chmod +x "$SHIM_BIN/jq"
rm -f "$TMP_HOME/arm" "$TMP_HOME/parked" "$TMP_HOME/go"
: > "$TMP_HOME/arm"
# max-retry 0 forces the give-up path, so the assertion below proves the writer
# REFUSED to commit rather than merely having been lucky on a retry.
( PATH="$SHIM_BIN:$PATH" CLAUDE_STATE_RMW_MAX_RETRY=0 CLAUDE_STATE_LOCK_TIMEOUT=5 \
    bash "$SCRIPT" --set '.keep="clobbered"' >"$TMP_HOME/w.out" 2>&1; echo "$?" > "$TMP_HOME/w.rc" ) &
WRITER=$!
for _ in $(seq 1 200); do [[ -e "$TMP_HOME/parked" ]] && break; sleep 0.05; done
check_eq "writer parked mid-transform while holding the lock" "1" \
  "$([[ -e "$TMP_HOME/parked" && -d "$LOCK_DIR" ]] && echo 1 || echo 0)"
# Steal it: replace the lock directory and publish a different token, exactly
# as breaking a stale lock and re-acquiring would.
rm -rf "$LOCK_DIR.thief"; mv "$LOCK_DIR" "$LOCK_DIR.thief" 2>/dev/null
mkdir -p "$LOCK_DIR"
printf 'pid=1\nhost=%s\nepoch=%s\ntoken=thief-token\n' "$(hostname)" "$(date +%s)" > "$LOCK_DIR/owner"
: > "$TMP_HOME/go"
wait "$WRITER" 2>/dev/null
WRC="$(cat "$TMP_HOME/w.rc" 2>/dev/null)"
check_eq "robbed writer exits 6 (unchanged, retry) instead of committing" "6" "$WRC"
check_eq "it reported the broken lock rather than failing silently" "1" \
  "$(grep -c 'lock was broken' "$TMP_HOME/w.out")"
check_eq "the file it would have clobbered is byte-identical" "$BEFORE" "$(cat "$STATE_FILE")"
rm -rf "$LOCK_DIR" "$LOCK_DIR.thief" "$SHIM_BIN" "$TMP_HOME/arm" "$TMP_HOME/parked" "$TMP_HOME/go"

# ── issue #1567: STATE_LOCK_WAITED ──────────────────────────────────────────
# state_lock_acquire reports whether it had to wait. Every case below is
# deterministic: contention is produced through the lock itself — a real
# holder process, or a lock directory planted on disk — and a live holder lets
# go only on an explicit hand-off, never after a sleep. Each case is paired with
# a control that would fail if the flag were hard-coded to the value it expects.
#
# The probe pre-seeds STATE_LOCK_WAITED with a sentinel AFTER sourcing, so a
# path that forgets to assign the flag prints "sentinel" instead of passing on
# the library's load-time default.
ACQ_PROBE="$TMP_HOME/acquire-probe.sh"
cat > "$ACQ_PROBE" <<'SH'
#!/usr/bin/env bash
# acquire-probe.sh <lock-lib> <state-file> <timeout> [handoff-dir]
# Prints "rc=<acquire status> waited=<STATE_LOCK_WAITED>". With a handoff dir,
# the first mkdir that LOSES to the existing lock touches <handoff-dir>/lost —
# the signal a holder waits for before letting go.
source "$1"
if [[ -n "${4:-}" ]]; then
  _probe_lock="$2.lock"
  _probe_hand="$4"
  mkdir() {
    command mkdir "$@" && return 0
    local rc=$?
    if [[ "$#" -eq 1 && "$1" == "$_probe_lock" ]]; then : > "$_probe_hand/lost"; fi
    return "$rc"
  }
fi
STATE_LOCK_WAITED=sentinel
state_lock_acquire "$2" "$3"
rc=$?
printf 'rc=%s waited=%s\n' "$rc" "$STATE_LOCK_WAITED"
state_lock_release
SH
probe() { bash "$ACQ_PROBE" "$LOCK_LIB" "$@"; }
# Bounded poll for a hand-off sentinel. The bound only stops a broken run from
# hanging; no assertion depends on how long anything takes.
wait_for() {
  local path="$1" tries=400
  while (( tries-- > 0 )); do [[ -e "$path" ]] && return 0; sleep 0.05; done
  return 1
}
plant_lock() { # plant_lock <pid> <epoch>: a lock directory owned by <pid> on this host
  mkdir -p "$LOCK_DIR"
  { printf 'pid=%s\n' "$1"; printf 'host=%s\n' "$(hostname)"; printf 'epoch=%s\n' "$2"
    printf 'token=planted-%s\n' "$1"; } > "$LOCK_DIR/owner"
}

echo
echo "== issue #1567: an immediate acquire reports STATE_LOCK_WAITED=0 =="
reset_state
check_eq "free lock: acquired on the first attempt, not waited" "rc=0 waited=0" \
  "$(probe "$STATE_FILE" 5 2>&1)"
# Neither clearing the legacy flock artifact nor creating a missing parent
# directory is another holder, so neither may read as a wait.
reset_state
: > "$LOCK_DIR"
check_eq "legacy flock FILE cleared first: still not waited" "rc=0 waited=0" \
  "$(probe "$STATE_FILE" 5 2>&1)"
FRESH_PARENT="$TMP_HOME/no-such-dir-yet/state.json"
check_eq "(setup) the parent directory is genuinely missing" "0" \
  "$([[ -d "${FRESH_PARENT%/*}" ]] && echo 1 || echo 0)"
check_eq "missing parent created first: still not waited" "rc=0 waited=0" \
  "$(probe "$FRESH_PARENT" 5 2>&1)"
rm -rf "${FRESH_PARENT%/*}"
# Control: the same probe against a lock that IS held reports 1, so a flag
# hard-coded to 0 fails here (the waited cases below are the full proof).
reset_state
plant_lock "$$" "$(date +%s)"
check_eq "(control) a live holder makes even a zero-timeout attempt report waited=1" \
  "rc=6 waited=1" "$(probe "$STATE_FILE" 0 2>/dev/null)"
rm -rf "$LOCK_DIR"

echo
echo "== issue #1567: an acquire that waits out a live holder reports STATE_LOCK_WAITED=1 =="
reset_state
HAND="$TMP_HOME/handoff"; rm -rf "$HAND"; mkdir -p "$HAND"
# The holder is a real process holding the lock through the library. It lets go
# ONLY after the acquirer has demonstrably lost an attempt to it.
bash -c 'source "$1"; state_lock_acquire "$2" 5 || exit 6; : > "$3/held"
         while [[ ! -e "$3/release" ]]; do sleep 0.05; done
         state_lock_release' _ "$LOCK_LIB" "$STATE_FILE" "$HAND" &
HOLDER1567=$!
wait_for "$HAND/held"
check_eq "(setup) the holder took the lock" "1" "$([[ -e "$HAND/held" && -d "$LOCK_DIR" ]] && echo 1 || echo 0)"
( probe "$STATE_FILE" 20 "$HAND" > "$HAND/acq.out" 2>&1 ) &
ACQ1567=$!
wait_for "$HAND/lost"; LOST_RC=$?
: > "$HAND/release"   # unconditional, so a failed hand-off can never wedge the holder
wait "$ACQ1567" 2>/dev/null; wait "$HOLDER1567" 2>/dev/null
check_eq "(setup) the acquirer lost an attempt to the live holder before the release" "0" "$LOST_RC"
check_eq "it then acquired, reporting waited=1" "rc=0 waited=1" "$(cat "$HAND/acq.out" 2>/dev/null)"
# Control: the identical probe, hand-off wrapper and all, against a free lock.
# A flag hard-coded to 1 fails here.
reset_state; rm -f "$HAND/lost"
check_eq "(control) the same probe on a free lock reports waited=0" "rc=0 waited=0" \
  "$(probe "$STATE_FILE" 20 "$HAND" 2>&1)"
check_eq "(control) and recorded no lost attempt" "0" "$([[ -e "$HAND/lost" ]] && echo 1 || echo 0)"
rm -rf "$HAND" "$LOCK_DIR"

echo
echo "== issue #1567: stale-lock recovery reports STATE_LOCK_WAITED=1 =="
# Documented choice: another holder existed — it died or wedged, possibly mid-
# write — so the acquire that broke its lock is a waited acquire, not a fresh one.
# The age rule, with this live process as the recorded pid: a pid that has
# merely exited could be reused before the probe looks, reading as a live
# holder and timing out. Which staleness rule fires does not matter to the
# flag — it is set on the lost attempt, before the stale check runs.
reset_state
plant_lock "$$" "$(( $(date +%s) - 9999 ))"
OUT="$(probe "$STATE_FILE" 5 2>"$TMP_HOME/stale.err")"
check_eq "(setup) the ancient lock was broken, not timed out" "1" "$(grep -c 'broke stale lock' "$TMP_HOME/stale.err")"
check_eq "stale lock broken and taken: waited=1" "rc=0 waited=1" "$OUT"
# Control: with nothing to break, the same call reports 0 — a flag hard-coded to
# 1 fails here.
reset_state
check_eq "(control) no stale lock to break: waited=0" "rc=0 waited=0" "$(probe "$STATE_FILE" 5 2>&1)"
rm -f "$TMP_HOME/stale.err"

echo
echo "== issue #1567: a re-entrant acquire reports STATE_LOCK_WAITED=0 =="
# The nested writer inherits CLAUDE_STATE_LOCK_HELD and attempts nothing, so it
# waited for nothing — even though, from its point of view, the lock is held.
reset_state
OUT="$(bash -c 'source "$1"; state_lock_acquire "$2" 5 || exit 9
  bash "$3" "$1" "$2" 0
  env -u CLAUDE_STATE_LOCK_HELD -u CLAUDE_STATE_LOCK_TOKEN bash "$3" "$1" "$2" 0' \
  _ "$LOCK_LIB" "$STATE_FILE" "$ACQ_PROBE" 2>/dev/null)"
check_eq "nested acquire under the inherited lock: rc 0, waited=0" "rc=0 waited=0" "$(sed -n 1p <<<"$OUT")"
# Control: the SAME call with the inheritance stripped is an ordinary contender
# against the same live lock, so it loses and reports 1. A flag hard-coded to 0,
# or a re-entrant path that merely fell through, fails one of these two checks.
check_eq "(control) without the inherited marker it is a contender: rc 6, waited=1" "rc=6 waited=1" \
  "$(sed -n 2p <<<"$OUT")"
check_eq "the flag is a shell global, not exported to children" "0" \
  "$(bash -c 'source "$1"; state_lock_acquire "$2" 5 || exit 9; env | grep -c "^STATE_LOCK_WAITED="' \
       _ "$LOCK_LIB" "$STATE_FILE" 2>/dev/null)"

echo
echo "== issue #1567: state_lock_release resets STATE_LOCK_WAITED =="
reset_state
check_eq "set after acquire, empty after release" "before=0 after=[]" \
  "$(bash -c 'source "$1"; state_lock_acquire "$2" 5 || exit 9; b="$STATE_LOCK_WAITED"
              state_lock_release; printf "before=%s after=[%s]" "$b" "$STATE_LOCK_WAITED"' \
       _ "$LOCK_LIB" "$STATE_FILE" 2>/dev/null)"
check_eq "a library that is only sourced starts with no acquisition in effect" "[]" \
  "$(bash -c 'source "$1"; printf "[%s]" "$STATE_LOCK_WAITED"' _ "$LOCK_LIB")"
rm -rf "$LOCK_DIR"

# ---------------------------------------------------------------------------
# issue #2433: truthful timeout diagnostics and a bounded deadline.
# ---------------------------------------------------------------------------
# contend <state-file> <timeout>: one acquire attempt in a child; prints
# "rc=<n>" on stdout line 1, then the child's stderr, plus "self=<pid>@<host>"
# so the tests can prove the waiter's own identity is never reported.
contend() {
  bash -c 'source "$1"; state_lock_acquire "$2" "$3" 2>&1; rc=$?
           printf "rc=%s\nself=%s@%s\n" "$rc" "$$" "$(_state_lock_hostname)"' \
    _ "$LOCK_LIB" "$1" "$2"
}

echo
echo "== issue #2433: a real holder is named by pid and host in one line =="
reset_state
run --set '.held_by_real="yes"'
BEFORE="$(cat "$STATE_FILE")"
H2433="$TMP_HOME/h2433"; rm -rf "$H2433"; mkdir -p "$H2433"
bash -c 'source "$1"; state_lock_acquire "$2" 5 || exit 6; : > "$3/held"
         while [[ ! -e "$3/release" ]]; do sleep 0.05; done
         state_lock_release' _ "$LOCK_LIB" "$STATE_FILE" "$H2433" &
HOLDER=$!
wait_for "$H2433/held"
HPID="$(sed -n 's/^pid=//p' "$LOCK_DIR/owner")"
HHOST="$(sed -n 's/^host=//p' "$LOCK_DIR/owner")"
HTOKEN="$(sed -n 's/^token=//p' "$LOCK_DIR/owner")"
OUT="$(contend "$STATE_FILE" 1)"
MSG="$(grep 'timed out' <<<"$OUT")"
SELF="$(sed -n 's/^self=//p' <<<"$OUT")"
check_eq "contender exits 6" "rc=6" "$(grep '^rc=' <<<"$OUT")"
check_eq "published host is non-empty" "1" "$([[ -n "$HHOST" ]] && echo 1 || echo 0)"
check_eq "message names the holder pid and host" "1" "$(grep -cF "held by pid $HPID on $HHOST (cmd " <<<"$MSG")"
check_eq "diagnostic is exactly one stderr line" "1" "$(grep -vc '^rc=\|^self=' <<<"$OUT")"
check_eq "message never names the waiter's own pid" "0" "$(grep -cF "pid ${SELF%@*} " <<<"$MSG")"
check_eq "legacy substrings preserved" "1" "$(grep -c 'timed out after 1s waiting.*refusing to write unserialized' <<<"$MSG")"
check_eq "holder token unchanged" "$HTOKEN" "$(sed -n 's/^token=//p' "$LOCK_DIR/owner")"
check_eq "state bytes unchanged" "$BEFORE" "$(cat "$STATE_FILE")"
: > "$H2433/release"; wait "$HOLDER" 2>/dev/null

echo
echo "== issue #2433: an ownerless fresh lock reports pid unknown with a reason =="
reset_state
mkdir -p "$LOCK_DIR"
OUT="$(contend "$STATE_FILE" 1)"
MSG="$(grep 'timed out' <<<"$OUT")"
SELF="$(sed -n 's/^self=//p' <<<"$OUT")"
check_eq "contender exits 6" "rc=6" "$(grep '^rc=' <<<"$OUT")"
check_eq "message says pid unknown with the ownerless reason" "1" \
  "$(grep -c 'held by pid unknown on unknown (owner not published or unreadable; lock age [0-9]*s)' <<<"$MSG")"
check_eq "message never names the waiter's own pid" "0" "$(grep -cF "pid ${SELF%@*} " <<<"$MSG")"
check_eq "no empty pid/host fields" "0" "$(grep -c 'pid  on \|on )' <<<"$MSG")"
check_eq "the fresh ownerless lock was NOT broken" "1" "$([[ -d "$LOCK_DIR" ]] && echo 1 || echo 0)"
rm -rf "$LOCK_DIR"

echo
echo "== issue #2433: a holder that vanished mid-wait is reported as last observed =="
reset_state
plant_lock 4242 "$(date +%s)"
# 4242 is not a live pid on most hosts — make the pid check meaningless by
# planting a foreign host, so only the (fresh) age rule applies.
sed -i.bak 's/^host=.*/host=foreign-host-2433/' "$LOCK_DIR/owner"; rm -f "$LOCK_DIR/owner.bak"
# Start the contender FIRST (it samples the owner on its first lost poll),
# and only then remove the owner file, so the sample cannot be skipped.
( contend "$STATE_FILE" 3 > "$TMP_HOME/vanish.out" 2>&1 ) &
VPID=$!
sleep 1
rm -f "$LOCK_DIR/owner"
wait "$VPID"
OUT="$(cat "$TMP_HOME/vanish.out")"
MSG="$(grep 'timed out' <<<"$OUT")"
check_eq "contender exits 6" "rc=6" "$(grep '^rc=' <<<"$OUT")"
check_eq "labelled last observed with the vanished holder's fields" "1" \
  "$(grep -c 'last observed held by pid 4242 on foreign-host-2433 ([0-9]*s ago)' <<<"$MSG")"
check_eq "no mixed current-holder form" "0" "$(grep -c '(cmd ' <<<"$MSG")"
rm -rf "$LOCK_DIR"

echo
echo "== issue #2433: an ownerless holder that left is contention, not a creation failure =="
reset_state
SHIM2="$TMP_HOME/mkdir-shim-seen"; rm -rf "$SHIM2"; mkdir -p "$SHIM2"
REAL_MKDIR="$(command -v mkdir)"
# The lock mkdir always fails here, so the contender can never take the lock
# that the test planted and then removed.
cat > "$SHIM2/mkdir" <<SH
#!/bin/bash
for a in "\$@"; do case "\$a" in *.lock) exit 1 ;; esac; done
exec "$REAL_MKDIR" "\$@"
SH
chmod +x "$SHIM2/mkdir"
mkdir -p "$LOCK_DIR"
( PATH="$SHIM2:$PATH" contend "$STATE_FILE" 2 > "$TMP_HOME/seen.out" 2>&1 ) &
SPID=$!
sleep 0.7
rm -rf "$LOCK_DIR"
wait "$SPID"
check_eq "not misreported as a creation failure" "0" "$(grep -c 'not contention' "$TMP_HOME/seen.out")"
check_eq "reported as a holder that released unobserved" "1" \
  "$(grep -c 'held by pid unknown on unknown (holder released before its owner was observed)' "$TMP_HOME/seen.out")"

echo
echo "== issue #2433: a lock mkdir that fails without contention says so =="
reset_state
SHIM="$TMP_HOME/mkdir-shim"; rm -rf "$SHIM"; mkdir -p "$SHIM"
REAL_MKDIR="$(command -v mkdir)"
cat > "$SHIM/mkdir" <<SH
#!/bin/bash
for a in "\$@"; do case "\$a" in *.lock) exit 1 ;; esac; done
exec "$REAL_MKDIR" "\$@"
SH
chmod +x "$SHIM/mkdir"
OUT="$(PATH="$SHIM:$PATH" contend "$STATE_FILE" 1)"
MSG="$(grep 'timed out' <<<"$OUT")"
check_eq "contender exits 6" "rc=6" "$(grep '^rc=' <<<"$OUT")"
check_eq "message classifies it as not contention" "1" \
  "$(grep -c 'held by pid unknown on unknown (lock directory could not be created; not contention)' <<<"$MSG")"

echo
echo "== issue #2433: the deadline bounds a parent that cannot be created =="
BLOCKER="$TMP_HOME/blocker-file"; : > "$BLOCKER"
# Watchdog: a regression retries parent creation forever, so bound the child.
( contend "$BLOCKER/sub/state.json" 1 > "$TMP_HOME/parent.out" 2>&1 ) &
PPID_C=$!
T0=$SECONDS
while kill -0 "$PPID_C" 2>/dev/null && (( SECONDS - T0 < 15 )); do sleep 0.1; done
ELAPSED=$(( SECONDS - T0 ))
kill -9 "$PPID_C" 2>/dev/null; wait "$PPID_C" 2>/dev/null
OUT="$(cat "$TMP_HOME/parent.out")"
check_eq "exits 6" "rc=6" "$(grep '^rc=' <<<"$OUT")"
check_eq "names the parent-creation failure as not contention" "1" \
  "$(grep -c 'parent directory .* could not be created; not contention' <<<"$OUT")"
check_eq "returns within timeout + margin (<=4s)" "1" "$(( ELAPSED <= 4 ))"

echo
echo "== issue #2433: the deadline bounds a stale break that keeps failing =="
RO="$TMP_HOME/ro-parent"; rm -rf "$RO"; mkdir -p "$RO/state.json.lock"
{ printf 'pid=1\n'; printf 'host=foreign-host-2433\n'; printf 'epoch=1\n'; } > "$RO/state.json.lock/owner"
chmod 555 "$RO"
if touch "$RO/probe" 2>/dev/null; then
  # root (or similar) ignores directory write permission, so the break would
  # succeed and the case would test nothing. Skip rather than fail falsely.
  rm -f "$RO/probe"
  echo "skip — directory permissions are not enforced for this user"
else
  # Watchdog: a regression loops forever here, so bound the child externally.
  ( contend "$RO/state.json" 1 > "$TMP_HOME/ro.out" 2>&1 ) &
  CPID=$!
  T0=$SECONDS
  while kill -0 "$CPID" 2>/dev/null && (( SECONDS - T0 < 15 )); do sleep 0.1; done
  ELAPSED=$(( SECONDS - T0 ))
  kill -9 "$CPID" 2>/dev/null; wait "$CPID" 2>/dev/null
  check_eq "(setup) the stale lock could not be broken" "1" "$([[ -d "$RO/state.json.lock" ]] && echo 1 || echo 0)"
  check_eq "exits 6" "rc=6" "$(grep '^rc=' "$TMP_HOME/ro.out")"
  check_eq "returns within timeout + margin (<=4s)" "1" "$(( ELAPSED <= 4 ))"
fi
chmod 755 "$RO"
rm -rf "$RO"

echo
echo "== issue #2433: a free lock is still acquired immediately (positive control) =="
reset_state
check_eq "free lock: rc 0, not waited" "rc=0 waited=0" "$(probe "$STATE_FILE" 5 2>&1)"
rm -rf "$LOCK_DIR"

echo
echo "== issue #2433: a newline in HOSTNAME cannot inject owner-file records =="
reset_state
OUT="$(HOSTNAME=$'evil\ntoken=forged' bash -c '
  source "$1"; state_lock_acquire "$2" 5 || exit 6
  printf "%s|" "$(grep -c "^token=" "$2.lock/owner")" "$(grep "^host=" "$2.lock/owner")"
  state_lock_release
  [[ -d "$2.lock" ]] && echo leaked || echo released' _ "$LOCK_LIB" "$STATE_FILE")"
check_eq "one token line, host truncated at the newline, lock released" "1|host=evil|released" "$OUT"
rm -rf "$LOCK_DIR"

echo
echo "== issue #2460: a paused cleaner must not remove a successor's fresh lock =="
# Forced interleaving: cleaner B judges the lock stale and pauses; cleaner A
# breaks it and re-takes it; B resumes. B must not remove A's lock.
# LIB_UNDER_TEST lets the same scenarios be pointed at an older copy of the
# library to confirm they fail there.
LIB_UNDER_TEST="${STATE_LOCK_LIB_UNDER_TEST:-$LOCK_LIB}"
SYNC="$TMP_HOME/sync"
wait_for() { local i; for i in $(seq 1 200); do [[ -e "$1" ]] && return 0; sleep 0.05; done; return 1; }
make_dead_lock() {   # lock held by a long-dead pid on this host
  mkdir -p "$LOCK_DIR"
  printf 'pid=999999\nhost=%s\nepoch=%s\nstarted=x\ncmd=t\ntoken=OLD\n' \
    "${HOSTNAME:-$(hostname)}" "$(date +%s)" > "$LOCK_DIR/owner"
}
reset_state; rm -rf "$SYNC"; mkdir -p "$SYNC"
make_dead_lock
( SYNC="$SYNC" bash -c '
    source "$1"
    eval "$(declare -f _state_lock_is_stale | sed "1s/.*/_orig_is_stale ()/")"
    calls=0
    _state_lock_is_stale() {
      _orig_is_stale "$@"; local rc=$?
      calls=$((calls + 1))
      if (( calls == 1 )); then touch "$SYNC/judged"; while [[ ! -e "$SYNC/go" ]]; do sleep 0.05; done; fi
      return $rc
    }
    _state_lock_break "$2" 120; echo "rc=$?" > "$SYNC/b.rc"
  ' _ "$LIB_UNDER_TEST" "$LOCK_DIR" 2>/dev/null ) &
B_PID=$!
wait_for "$SYNC/judged" || echo "FAIL — cleaner B never reached its pause point"
( SYNC="$SYNC" bash -c '
    source "$1"
    state_lock_acquire "$2" 10 || exit 9
    printf "%s" "$STATE_LOCK_TOKEN" > "$SYNC/a.token"
    touch "$SYNC/a.held"
    while [[ ! -e "$SYNC/a.release" ]]; do sleep 0.05; done
    state_lock_release
  ' _ "$LIB_UNDER_TEST" "$STATE_FILE" 2>/dev/null ) &
A_PID=$!
wait_for "$SYNC/a.held" || echo "FAIL — cleaner A never re-took the lock"
touch "$SYNC/go"
wait "$B_PID" 2>/dev/null
check_eq "A's fresh lock still exists after B resumed" "1" "$([[ -d "$LOCK_DIR" ]] && echo 1 || echo 0)"
check_eq "the surviving lock is A's instance (token unchanged)" "$(cat "$SYNC/a.token" 2>/dev/null)" \
  "$(sed -n 's/^token=//p' "$LOCK_DIR/owner" 2>/dev/null)"
check_eq "B abandoned the break (non-zero rc)" "rc=1" "$(cat "$SYNC/b.rc" 2>/dev/null)"
touch "$SYNC/a.release"; wait "$A_PID" 2>/dev/null
check_eq "A released cleanly; no lock or gate left behind" "0" \
  "$([[ -e "$LOCK_DIR" || -e "$LOCK_DIR.gate" ]] && echo 1 || echo 0)"

echo
echo "== issue #2460: an older writer must not commit over a newer one =="
# Writer W1 passes its ownership check and pauses inside the commit `mv`
# (shadowed below). The lock is aged so a second writer W2 considers it
# stale. W2 must NOT be able to break in and commit; once W1 lands, W2's
# newer value is the one that survives.
DEST="$TMP_HOME/protected.json"
reset_state; rm -rf "$SYNC"; mkdir -p "$SYNC"; echo '"initial"' > "$DEST"
( SYNC="$SYNC" DEST="$DEST" LOCK_DIR="$LOCK_DIR" bash -c '
    source "$1"
    state_lock_acquire "$2" 10 || exit 9
    sed -i.bak "s/^epoch=.*/epoch=1/" "$LOCK_DIR/owner"; rm -f "$LOCK_DIR/owner.bak"
    printf "\"old\"\n" > "$DEST.w1"
    mv() {
      if [[ "$1" == "$DEST.w1" ]]; then
        touch "$SYNC/w1.in_commit"
        while [[ ! -e "$SYNC/w1.go" ]]; do sleep 0.05; done
      fi
      command mv "$@"
    }
    state_lock_commit "$DEST.w1" "$DEST"; echo "rc=$?" > "$SYNC/w1.rc"
    state_lock_release
  ' _ "$LIB_UNDER_TEST" "$STATE_FILE" 2>/dev/null ) &
W1_PID=$!
wait_for "$SYNC/w1.in_commit" || echo "FAIL — W1 never reached its commit"
OUT_W2="$(bash -c '
    source "$1"
    state_lock_acquire "$2" 2; rc=$?
    if [[ $rc -eq 0 ]]; then printf "\"new\"\n" > "$3.w2"; state_lock_commit "$3.w2" "$3"; state_lock_release; fi
    echo "acquire_rc=$rc"
  ' _ "$LIB_UNDER_TEST" "$STATE_FILE" "$DEST" 2>/dev/null)"
check_eq "W2 cannot break the lock while W1 is mid-commit" "acquire_rc=6" "$OUT_W2"
touch "$SYNC/w1.go"; wait "$W1_PID" 2>/dev/null
check_eq "W1's commit landed" "rc=0" "$(cat "$SYNC/w1.rc" 2>/dev/null)"
check_eq "W1's value is on disk, nothing overwrote it behind its back" '"old"' "$(cat "$DEST")"
OUT_W2="$(bash -c '
    source "$1"
    state_lock_acquire "$2" 10 || exit 9
    printf "\"new\"\n" > "$3.w2"; state_lock_commit "$3.w2" "$3"; echo "commit_rc=$?"; state_lock_release
  ' _ "$LIB_UNDER_TEST" "$STATE_FILE" "$DEST" 2>/dev/null)"
check_eq "W2 commits after W1 released" "commit_rc=0" "$OUT_W2"
check_eq "the newer state survives" '"new"' "$(cat "$DEST")"
check_eq "no gate directory left behind" "0" "$([[ -e "$LOCK_DIR.gate" ]] && echo 1 || echo 0)"

echo
echo "== issue #2460: a writer broken BEFORE its commit is refused, newer state kept =="
reset_state; rm -rf "$SYNC"; mkdir -p "$SYNC"; echo '"initial"' > "$DEST"
( SYNC="$SYNC" DEST="$DEST" LOCK_DIR="$LOCK_DIR" bash -c '
    source "$1"
    state_lock_acquire "$2" 10 || exit 9
    sed -i.bak "s/^epoch=.*/epoch=1/" "$LOCK_DIR/owner"; rm -f "$LOCK_DIR/owner.bak"
    printf "\"old\"\n" > "$DEST.w1"
    touch "$SYNC/w1.ready"
    while [[ ! -e "$SYNC/w1.go" ]]; do sleep 0.05; done
    state_lock_commit "$DEST.w1" "$DEST"; echo "rc=$?" > "$SYNC/w1.rc"
  ' _ "$LIB_UNDER_TEST" "$STATE_FILE" 2>/dev/null ) &
W1_PID=$!
wait_for "$SYNC/w1.ready" || echo "FAIL — W1 never became ready"
bash -c '
    source "$1"
    state_lock_acquire "$2" 10 || exit 9
    printf "\"new\"\n" > "$3.w2"; state_lock_commit "$3.w2" "$3"; state_lock_release
  ' _ "$LIB_UNDER_TEST" "$STATE_FILE" "$DEST" 2>/dev/null
touch "$SYNC/w1.go"; wait "$W1_PID" 2>/dev/null
check_eq "stale W1 refused (exit 6)" "rc=6" "$(cat "$SYNC/w1.rc" 2>/dev/null)"
check_eq "newer state survives" '"new"' "$(cat "$DEST")"

echo
echo "== issue #2460: an aged gate is reaped only when its holder is gone =="
# A commit stalled mid-gate (SIGSTOP, suspended laptop) keeps its gate however
# old it gets; only a dead holder's gate, or a pid-less one past the stale age,
# may be removed.
GATE="$LOCK_DIR.gate"
# Bounded: a library that spins on an unremovable gate reports "hung", not a stalled suite.
gate_try() {
  local out="$SYNC/gate_try.out" p i
  : > "$out"
  bash -c 'source "$1"; _state_lock_gate_take "$2" 0 && echo taken || echo refused' \
    _ "$LIB_UNDER_TEST" "$LOCK_DIR" > "$out" 2>/dev/null &
  p=$!
  for i in $(seq 1 60); do kill -0 "$p" 2>/dev/null || break; sleep 0.05; done
  kill "$p" 2>/dev/null; wait "$p" 2>/dev/null
  [[ -s "$out" ]] && cat "$out" || echo hung
}
age_gate() { touch -t 200001010000 "$GATE"; }
reset_state; rm -rf "$GATE"; mkdir -p "$SYNC"
sleep 300 & LIVE_PID=$!
mkdir -p "$GATE"; echo "$LIVE_PID" > "$GATE/pid"; age_gate
check_eq "an old gate whose holder is alive is NOT reaped" "refused" "$(gate_try)"
check_eq "the live holder's gate is still in place" "$LIVE_PID" "$(cat "$GATE/pid" 2>/dev/null)"
kill "$LIVE_PID" 2>/dev/null; wait "$LIVE_PID" 2>/dev/null
check_eq "once its holder is dead the gate is reaped and taken" "taken" "$(gate_try)"
rm -rf "$GATE"; mkdir -p "$GATE"
check_eq "a fresh pid-less gate (holder mid-take) is NOT reaped" "refused" "$(gate_try)"
age_gate
check_eq "an old pid-less gate (holder killed mid-take) is reaped" "taken" "$(gate_try)"
rm -rf "$GATE"

echo
echo "== issue #2460: release removes the lock only under the gate =="
# A breaker re-checks the token under the gate and then renames; a release
# that ignored the gate could release-and-re-take in between. Release waits.
reset_state; rm -rf "$SYNC" "$GATE"; mkdir -p "$SYNC"
( SYNC="$SYNC" bash -c '
    source "$1"
    state_lock_acquire "$2" 10 || exit 9
    touch "$SYNC/held"
    while [[ ! -e "$SYNC/release" ]]; do sleep 0.05; done
    state_lock_release; touch "$SYNC/released"
  ' _ "$LIB_UNDER_TEST" "$STATE_FILE" 2>/dev/null ) &
R_PID=$!
wait_for "$SYNC/held" || echo "FAIL — holder never acquired"
sleep 300 & LIVE_PID=$!
mkdir -p "$GATE"; echo "$LIVE_PID" > "$GATE/pid"
touch "$SYNC/release"; sleep 1
check_eq "release waits while another process holds the gate" "1" "$([[ -d "$LOCK_DIR" ]] && echo 1 || echo 0)"
rm -f "$GATE/pid"; rmdir "$GATE"
wait "$R_PID" 2>/dev/null
kill "$LIVE_PID" 2>/dev/null; wait "$LIVE_PID" 2>/dev/null
check_eq "release completes once the gate is free; nothing left behind" "0" \
  "$([[ -e "$LOCK_DIR" || -e "$GATE" ]] && echo 1 || echo 0)"

echo
echo "== issue #2402: stale lock-aside sweep =="
SWEEP="$REPO_ROOT/.claude/scripts/state-lock-sweep.sh"
reset_state; run --set '.seed=1'
OLD=202601010000   # touch -t stamp, months older than the 1h grace
mk_aside() { # name [entries...] ; created old unless AGE=young
  local d="$STATE_FILE.$1"; shift
  mkdir -p "$d"
  local e; for e in "$@"; do printf 'pid=1\n' > "$d/$e"; done
  [[ "${AGE:-old}" == young ]] || touch -t "$OLD" "$d"
}
mk_aside lock.rel.111-1 owner
mk_aside lock.rel.222-2 .owner.222
mk_aside lock.stale.333-3
AGE=young mk_aside lock.rel.444-4 owner
mk_aside lock.rel.555-5 owner unexpected.txt
mk_aside lock.rel.666-6 owner; mkdir "$STATE_FILE.lock.rel.666-6/nested"; touch -t "$OLD" "$STATE_FILE.lock.rel.666-6"
VICTIM="$HOME/victim-2402"; mkdir -p "$VICTIM"; printf 'keep\n' > "$VICTIM/owner"
ln -s "$VICTIM" "$STATE_FILE.lock.rel.777-7"
printf 'x\n' > "$STATE_FILE.lock.rel.888-8"; touch -t "$OLD" "$STATE_FILE.lock.rel.888-8"
mk_aside lock.rel.999-9 owner; ln -s "$VICTIM/owner" "$STATE_FILE.lock.rel.999-9/.owner.9"; touch -t "$OLD" "$STATE_FILE.lock.rel.999-9"
mkdir -p "$LOCK_DIR"; printf 'pid=1\n' > "$LOCK_DIR/owner"; touch -t "$OLD" "$LOCK_DIR"
inv="$(bash "$SWEEP")"; inv_rc=$?
check_eq "inventory exits 0" "0" "$inv_rc"
check_eq "inventory lists the three valid old asides as removable" "3" "$(grep -c '^removable' <<<"$inv")"
check_eq "inventory deletes nothing" "9" "$(find "$HOME/.claude" -maxdepth 1 -name 'session-state.json.lock.*' | wc -l | tr -d ' ')"
check_eq "inventory totals" "removed=0 removable=3 retained=6 failed=0 unexamined=0" "$(grep '^totals' <<<"$inv" | cut -f2)"
app="$(bash "$SWEEP" --apply)"; app_rc=$?
check_eq "apply exits 0" "0" "$app_rc"
check_eq "apply totals" "removed=3 removable=0 retained=6 failed=0 unexamined=0" "$(grep '^totals' <<<"$app" | cut -f2)"
for a in lock.rel.111-1 lock.rel.222-2 lock.stale.333-3; do
  check_eq "removed valid old aside $a" "0" "$([[ -e "$STATE_FILE.$a" ]] && echo 1 || echo 0)"
done
for a in lock.rel.444-4 lock.rel.555-5 lock.rel.666-6 lock.rel.777-7 lock.rel.888-8 lock.rel.999-9; do
  check_eq "retained $a" "1" "$([[ -e "$STATE_FILE.$a" || -L "$STATE_FILE.$a" ]] && echo 1 || echo 0)"
done
check_eq "young aside retained as too young" "1" "$(grep -c $'^retained\ttoo young.*lock.rel.444-4$' <<<"$app")"
check_eq "symlink aside retained as symlink" "1" "$(grep -c $'^retained\tsymlink\t.*lock.rel.777-7$' <<<"$app")"
check_eq "symlink victim untouched" "keep" "$(cat "$VICTIM/owner")"
check_eq "aside with a symlinked owner file retained" "1" "$(grep -c $'^retained\tsymlink entry .owner.9\t' <<<"$app")"
check_eq "live lock untouched" "1" "$([[ -f "$LOCK_DIR/owner" ]] && echo 1 || echo 0)"
check_eq "state file untouched" "1" "$(jq -r '.seed' "$STATE_FILE")"
again="$(bash "$SWEEP" --apply)"
check_eq "second apply is idempotent" "removed=0 removable=0 retained=6 failed=0 unexamined=0" "$(grep '^totals' <<<"$again" | cut -f2)"
capped="$(bash "$SWEEP" --max 2)"
check_eq "candidates beyond --max are unexamined, not zero" "unexamined=4" \
  "$(grep '^totals' <<<"$capped" | cut -f2 | grep -o 'unexamined=[0-9]*')"
check_eq "entries past --max share one summary line" "1" "$(grep -c '^unexamined' <<<"$capped")"
# CodeAnt 4630497918: malformed names that match the glob count toward --max
# too, so they cannot make one sweep examine past the cap.
for i in $(seq 1 20); do mkdir -p "$STATE_FILE.lock.rel.bad-$i-x"; done
malformed="$(bash "$SWEEP" --max 3)"
check_eq "malformed names count toward --max" "removed=0 removable=0 retained=3 failed=0 unexamined=23" \
  "$(grep '^totals' <<<"$malformed" | cut -f2)"
check_eq "only --max entries examined among malformed names" "3" "$(grep -c '^retained' <<<"$malformed")"
check_eq "output stays bounded past --max" "5" "$(wc -l <<<"$malformed" | tr -d ' ')"
for i in $(seq 1 20); do rmdir "$STATE_FILE.lock.rel.bad-$i-x"; done
check_eq "bad --max is a usage error" "2" "$(bash "$SWEEP" --max x >/dev/null 2>&1; echo $?)"
other="$HOME/other-2402.json"; mkdir -p "$other.lock.rel.1-1"; touch -t "$OLD" "$other.lock.rel.1-1"
multi="$(bash "$SWEEP" --apply --state-file "$STATE_FILE" --state-file "$other")"
check_eq "repeated --state-file sweeps each scope" "2" "$(grep -c '^totals' <<<"$multi")"
check_eq "second scope's aside removed" "0" "$([[ -e "$other.lock.rel.1-1" ]] && echo 1 || echo 0)"
check_eq "--quiet prints nothing for an empty scope" "" "$(bash "$SWEEP" --quiet --state-file "$HOME/none-2402.json")"
rm -rf "$LOCK_DIR" "$STATE_FILE".lock.rel.* "$VICTIM"
# A zero-padded grace is decimal, not octal: "010" is ten seconds, so a
# nine-second-old aside is still too young (octal would make it eight).
# Fixed clock: mtime 1000000, "now" 1000009 — no wall-clock boundary.
mkdir -p "$STATE_FILE.lock.rel.123-4"; printf 'pid=1\n' > "$STATE_FILE.lock.rel.123-4/owner"
python3 -c 'import os,sys; os.utime(sys.argv[1],(1000000,1000000))' "$STATE_FILE.lock.rel.123-4"
padded="$(bash -c 'source "$1"; _state_lock_now() { printf 1000009; }; state_lock_sweep_asides "$2" apply 010' \
  _ "$LOCK_LIB" "$STATE_FILE")"
check_eq "zero-padded grace is read as decimal" "1" "$(grep -c $'^retained\ttoo young' <<<"$padded")"
check_eq "oversized --grace-seconds is a usage error" "2" "$(bash "$SWEEP" --grace-seconds 99999999999 >/dev/null 2>&1; echo $?)"
rm -rf "$STATE_FILE.lock.rel.123-4"

# Swap races between validation and deletion. Each case replaces the aside's
# NAME at a fixed point inside the sweep (deterministic hooks: `pwd` and `rm`
# are shadowed by functions that swap once, then defer to the real command):
# with a symlink to the live lock (pwd, rm) or with a fresh same-name real
# directory (pwd-dir). Nothing outside the validated inode may be deleted.
swap_case() { # hook(pwd|pwd-dir|rm) -> prints sweep output; leaves fixtures for asserts
  bash -c '
    source "$1"; c="$2"; lock="$3"; flag="$4"; hook="$5"
    swap() {
      [[ -e "$flag" ]] && return; : > "$flag"; mv "$c" "$c.moved"
      if [[ "$hook" == pwd-dir ]]; then
        # Same-name replacement: a real, owned, old directory with an owner file.
        mkdir "$c"; printf "pid=new\n" > "$c/owner"; touch -t 202601010000 "$c"
      else
        ln -s "$lock" "$c"
      fi
    }
    if [[ "$hook" == pwd || "$hook" == pwd-dir ]]; then
      # First pwd = the parent-path probe, i.e. after re-validation and
      # before the sweep enters the aside.
      pwd() { swap; builtin pwd "$@"; }
    else
      # First rm = the first unlink, i.e. after the sweep entered the aside.
      rm() { swap; command rm "$@"; }
    fi
    state_lock_sweep_asides "$6" apply
  ' _ "$LOCK_LIB" "$STATE_FILE.lock.rel.42-1" "$LOCK_DIR" "$HOME/swap-2402.flag" "$1" "$STATE_FILE"
}
for hook in pwd pwd-dir rm; do
  reset_state; command rm -rf "$STATE_FILE".lock.rel.* "$HOME/swap-2402.flag"
  mkdir -p "$LOCK_DIR"; printf 'pid=live\n' > "$LOCK_DIR/owner"
  mk_aside lock.rel.42-1 owner
  swap_out="$(swap_case "$hook")"; swap_rc=$?
  check_eq "swap via $hook: the swap fired" "1" "$([[ -e "$STATE_FILE.lock.rel.42-1.moved" ]] && echo 1 || echo 0)"
  check_eq "swap via $hook: live lock owner survives" "pid=live" "$(cat "$LOCK_DIR/owner" 2>/dev/null)"
  if [[ "$hook" == pwd-dir ]]; then
    check_eq "same-name replacement refused as a different directory" "1" "$(grep -c $'^failed\tchanged before removal: different directory\t' <<<"$swap_out")"
    check_eq "same-name replacement keeps its owner file" "pid=new" "$(cat "$STATE_FILE.lock.rel.42-1/owner" 2>/dev/null)"
    check_eq "same-name replacement: original keeps its file" "1" "$([[ -f "$STATE_FILE.lock.rel.42-1.moved/owner" ]] && echo 1 || echo 0)"
  else
    check_eq "swap via $hook: symlink itself not followed or removed" "1" "$([[ -L "$STATE_FILE.lock.rel.42-1" ]] && echo 1 || echo 0)"
  fi
  check_eq "swap via $hook: reported failed, not removed" "1" "$(grep -c $'^failed\t' <<<"$swap_out")"
  check_eq "swap via $hook: sweep exits 1" "1" "$swap_rc"
  if [[ "$hook" == pwd ]]; then
    check_eq "swap before entry: refused as resolving elsewhere" "1" "$(grep -c $'^failed\tchanged before removal: resolves elsewhere\t' <<<"$swap_out")"
    check_eq "swap before entry: moved original keeps its file" "1" "$([[ -f "$STATE_FILE.lock.rel.42-1.moved/owner" ]] && echo 1 || echo 0)"
  elif [[ "$hook" == rm ]]; then
    check_eq "swap after entry: final rmdir refuses the symlink" "1" "$(grep -c $'^failed\trmdir failed\t' <<<"$swap_out")"
    check_eq "swap after entry: unlink stayed bound to the original inode" "0" "$([[ -e "$STATE_FILE.lock.rel.42-1.moved/owner" ]] && echo 1 || echo 0)"
  fi
done
command rm -rf "$STATE_FILE".lock.rel.* "$LOCK_DIR" "$HOME/swap-2402.flag"

# The sweep runs while a real holder acquires and releases in a loop: every
# write survives and the active lock is never removed by the sweep.
reset_state; run --set '.loop=0'
LOOP_STOP="$HOME/loop-2402.stop"
( for i in $(seq 1 40); do [[ -e "$LOOP_STOP" ]] && break; run --set ".loop=$i" >/dev/null 2>&1; done ) &
LOOP_PID=$!
for _ in $(seq 1 20); do bash "$SWEEP" --apply --grace-seconds 0 >/dev/null 2>&1; done
wait "$LOOP_PID" 2>/dev/null
touch "$LOOP_STOP"
check_eq "concurrent writer's last update survives the sweep" "40" "$(jq -r '.loop' "$STATE_FILE")"
check_eq "no lock or aside left after the loop" "0" "$(find "$HOME/.claude" -maxdepth 1 -name 'session-state.json.lock*' | wc -l | tr -d ' ')"

echo
echo "== summary: $PASS passed, $FAIL failed =="
if [[ "$FAIL" -gt 0 ]]; then
  echo "FAILED: state-lock tests" >&2
  exit 1
fi
echo "OK: session-state write-lock tests passed"
