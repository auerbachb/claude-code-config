#!/usr/bin/env bash
# Tests for the SessionStart hook's age-cadence compaction trigger (issue #2433).
#
# The hook spawns session-state-compact.sh detached when the compactor's stamp
# is absent or older than the cadence, for every `source`, and never waits for
# it. A fresh stamp must suppress the spawn.
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
HOOK="$REPO_ROOT/.claude/hooks/session-start-sync.sh"

TMP_DIR="$(mktemp -d)"
cleanup() { chmod -R u+w "$TMP_DIR" 2>/dev/null || true; rm -rf "$TMP_DIR"; }
trap cleanup EXIT

# Inherited compactor overrides must never apply here: each case runs under
# the policy it names, and archives stay inside the fixture HOME.
while IFS= read -r _v; do unset "$_v"; done < <(compgen -e | grep '^CLAUDE_STATE_COMPACT_')
unset CLAUDE_STATE_LOCK_HELD CLAUDE_STATE_LOCK_TOKEN

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok   — $*"; }

# A terminal background task finished long ago: always eligible.
OLD_STATE='{"repos":{"org/a":{"background_tasks":[{"task_id":"t-old","session_id":"s","status":"done","started_at":"2020-01-01T00:00:00Z","updated_at":"2020-01-01T00:00:00Z"}]}}}'

CASE_N=0
STATE=""
run_hook() { # run_hook <source-json> [extra env assignments...]
  CASE_N=$((CASE_N + 1))
  export HOME="$TMP_DIR/home$CASE_N"
  mkdir -p "$HOME/.claude/skills-worktree/.claude/skills"
  : > "$HOME/.claude/skills-worktree/.git"
  STATE="$HOME/.claude/session-state.json"
  printf '%s' "$OLD_STATE" > "$STATE"
  local src="$1"; shift
  printf '%s' "$src" | env CLAUDE_STATE_COMPACT_ARCHIVE_DIR="$HOME/.claude/session-state-archive" "$@" \
    bash "$HOOK" >/dev/null 2>&1
}
wait_for() { local p="$1" n="${2:-200}"; while (( n-- > 0 )); do compgen -G "$p" >/dev/null && return 0; sleep 0.05; done; return 1; }

# --- 1. no stamp: the real compactor is spawned and archives the old entry ---
for SRC in startup resume compact; do
  run_hook "{\"source\":\"$SRC\"}"
  wait_for "$HOME/.claude/session-state-archive/compact-*.json" \
    || fail "source=$SRC: no compaction ran without a stamp"
  for _ in $(seq 1 100); do [[ -f "$STATE.compact.stamp" ]] && break; sleep 0.05; done
  [[ "$(jq '.repos["org/a"].background_tasks // [] | length' "$STATE")" == 0 ]] \
    || fail "source=$SRC: the old terminal task was not archived"
done
ok "a missing stamp spawns compaction for every source"

# --- 2. a fresh stamp gates the spawn ---------------------------------------
STUB="$TMP_DIR/stub-compact.sh"
cat > "$STUB" <<'SH'
#!/bin/bash
: > "$HOME/.claude/stub-ran"
sleep "${STUB_SLEEP:-0}"
SH
chmod +x "$STUB"
CASE_N=$((CASE_N + 1))
export HOME="$TMP_DIR/home$CASE_N"
mkdir -p "$HOME/.claude/skills-worktree/.claude/skills"
: > "$HOME/.claude/skills-worktree/.git"
printf '%s' "$OLD_STATE" > "$HOME/.claude/session-state.json"
: > "$HOME/.claude/session-state.json.compact.stamp"
printf '{"source":"startup"}' | CLAUDE_STATE_COMPACT_BIN="$STUB" bash "$HOOK" >/dev/null 2>&1
sleep 1
[[ ! -e "$HOME/.claude/stub-ran" ]] || fail "a fresh stamp did not gate the spawn"
# Control: the same HOME with the stamp backdated past the cadence spawns.
touch -t 202001010000 "$HOME/.claude/session-state.json.compact.stamp"
printf '{"source":"startup"}' | CLAUDE_STATE_COMPACT_BIN="$STUB" bash "$HOOK" >/dev/null 2>&1
wait_for "$HOME/.claude/stub-ran" || fail "(control) a stale stamp did not spawn the compactor"
ok "a fresh stamp suppresses the spawn; a stale one triggers it"

# --- 3. the hook never waits for the compactor -------------------------------
rm -f "$HOME/.claude/stub-ran" "$HOME/.claude/session-state.json.compact.stamp"
SECONDS=0
printf '{"source":"startup"}' | CLAUDE_STATE_COMPACT_BIN="$STUB" STUB_SLEEP=25 bash "$HOOK" >/dev/null 2>&1
ELAPSED=$SECONDS
wait_for "$HOME/.claude/stub-ran" || fail "(setup) the slow stub never started"
(( ELAPSED < 20 )) || fail "the hook waited for the compactor (${ELAPSED}s)"
ok "the hook returns without waiting for a slow compactor"

# --- 4. CLAUDE_STATE_COMPACT_AUTO=0 disables the trigger ---------------------
rm -f "$HOME/.claude/stub-ran"
printf '{"source":"startup"}' | CLAUDE_STATE_COMPACT_BIN="$STUB" CLAUDE_STATE_COMPACT_AUTO=0 bash "$HOOK" >/dev/null 2>&1
sleep 1
[[ ! -e "$HOME/.claude/stub-ran" ]] || fail "CLAUDE_STATE_COMPACT_AUTO=0 did not disable the trigger"
ok "CLAUDE_STATE_COMPACT_AUTO=0 disables the trigger"

# --- 5. a fresh run guard gates the spawn; an abandoned one does not ---------
rm -f "$HOME/.claude/stub-ran" "$HOME/.claude/session-state.json.compact.stamp"
mkdir -p "$HOME/.claude/session-state.json.compact.run"
printf '{"source":"startup"}' | CLAUDE_STATE_COMPACT_BIN="$STUB" bash "$HOOK" >/dev/null 2>&1
sleep 1
[[ ! -e "$HOME/.claude/stub-ran" ]] || fail "a fresh run guard did not gate the spawn"
touch -t 202001010000 "$HOME/.claude/session-state.json.compact.run"
printf '{"source":"startup"}' | CLAUDE_STATE_COMPACT_BIN="$STUB" bash "$HOOK" >/dev/null 2>&1
wait_for "$HOME/.claude/stub-ran" || fail "an abandoned (old) run guard blocked the spawn forever"
ok "a fresh run guard suppresses the spawn; an abandoned one does not"

# --- 6. a fresh guard whose published owner pid is dead does not block ------
rm -f "$HOME/.claude/stub-ran" "$HOME/.claude/session-state.json.compact.stamp"
rm -rf "$HOME/.claude/session-state.json.compact.run"
mkdir -p "$HOME/.claude/session-state.json.compact.run"
( : ) & _dead=$!; wait "$_dead"
printf '%s\n' "$_dead" > "$HOME/.claude/session-state.json.compact.run/pid"
printf '{"source":"startup"}' | CLAUDE_STATE_COMPACT_BIN="$STUB" bash "$HOOK" >/dev/null 2>&1
wait_for "$HOME/.claude/stub-ran" || fail "a fresh guard with a dead owner pid blocked the spawn"
# Control: the same fresh guard owned by a live pid still suppresses it.
rm -f "$HOME/.claude/stub-ran"
printf '%s\n' "$$" > "$HOME/.claude/session-state.json.compact.run/pid"
printf '{"source":"startup"}' | CLAUDE_STATE_COMPACT_BIN="$STUB" bash "$HOOK" >/dev/null 2>&1
sleep 1
[[ ! -e "$HOME/.claude/stub-ran" ]] || fail "a fresh guard with a live owner did not gate the spawn"
ok "a dead owner pid frees the guard; a live owner still gates the spawn"

echo "OK: session-start compaction trigger tests passed"
