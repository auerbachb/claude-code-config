#!/usr/bin/env bash
# Tests for the SessionStart hook's scheduling-reconcile gate (issue #827).
#
# SessionStart fires on startup | resume | clear | compact. Only `startup` is a
# genuinely new session; the others fire inside a LIVE one, where purging state
# would orphan a running job and race a watcher about to refresh itself.
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
HOOK="$REPO_ROOT/.claude/hooks/session-start-sync.sh"

TMP_DIR="$(mktemp -d)"
cleanup() { chmod -R u+w "$TMP_DIR" 2>/dev/null || true; rm -rf "$TMP_DIR"; }
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok   — $*"; }

# Build state fixtures.  The reconcile script is fail-closed: only records with
# a verifiable dead-owner stamp are purged.  The STAMPED variant carries a dead
# PID so startup can provably purge it; UNSTAMPED has no stamp and must survive
# startup unchanged (fail-closed guarantee).
( : ) &
_DEAD_PID=$!
wait "$_DEAD_PID" 2>/dev/null || true
_THIS_HOST="${HOSTNAME:-$(hostname 2>/dev/null || echo "localhost")}"
STAMPED_STATE="$(printf \
  '{"polling_jobs":[{"id":"live_job","owner_session":{"pid":%s,"host":"%s"}}],"pmm":{"auto_wake_cron_id":"live_cron","auto_wake_owner_session":{"pid":%s,"host":"%s"}}}' \
  "$_DEAD_PID" "$_THIS_HOST" "$_DEAD_PID" "$_THIS_HOST")"
UNSTAMPED_STATE='{"polling_jobs":[{"id":"live_job"}],"pmm":{"auto_wake_cron_id":"live_cron"}}'

CASE_N=0
OUT=""
STATE=""
# run_hook <source-json> [initial-state] — fresh HOME seeded with scheduling state.
# Sets $STATE and $OUT in the CALLER's scope: a command substitution would run
# this in a subshell and the $STATE assignment would never escape it.
# The optional second argument overrides the initial state written to $STATE;
# defaults to UNSTAMPED_STATE when omitted.
run_hook() {
  CASE_N=$((CASE_N + 1))
  export HOME="$TMP_DIR/home$CASE_N"
  mkdir -p "$HOME/.claude"
  # Pre-create a worktree-shaped stub so the hook's bootstrap branch is skipped.
  # Without it every case shells out to setup-skills-worktree.sh, which runs
  # `git fetch origin main` — making a pure state-reconciliation test
  # network-dependent, slow, and flaky offline.
  mkdir -p "$HOME/.claude/skills-worktree/.claude/skills"
  : > "$HOME/.claude/skills-worktree/.git"
  STATE="$HOME/.claude/session-state.json"
  printf '%s' "${2:-$UNSTAMPED_STATE}" > "$STATE"
  OUT="$(printf '%s' "$1" | bash "$HOOK" 2>/dev/null)"
}

# --- 1. startup purges dead-stamped records ----------------------------------
run_hook '{"source":"startup"}' "$STAMPED_STATE"
[[ "$(jq -c '.polling_jobs' "$STATE")" == "[]" ]] \
  || fail "startup should purge dead-stamped polling_jobs, got $(jq -c '.polling_jobs' "$STATE")"
[[ "$(jq -r '.pmm.auto_wake_cron_id' "$STATE")" == "null" ]] \
  || fail "startup should clear dead-stamped auto_wake_cron_id"
ok "source=startup purges dead-stamped scheduling bookkeeping"

# --- 1b. fail-closed: startup must NOT purge unstamped records ---------------
run_hook '{"source":"startup"}'
[[ "$(jq -c '.polling_jobs' "$STATE")" == '[{"id":"live_job"}]' ]] \
  || fail "startup must NOT purge unstamped polling_jobs (fail-closed), got $(jq -c '.polling_jobs' "$STATE")"
[[ "$(jq -r '.pmm.auto_wake_cron_id' "$STATE")" == "live_cron" ]] \
  || fail "startup must NOT clear unstamped auto_wake_cron_id (fail-closed)"
ok "source=startup preserves unstamped records (fail-closed)"

# --- 2. compact/resume/clear must NOT purge ----------------------------------
# These fire inside a live session: the recorded job may still be running.
for SRC in compact resume clear; do
  run_hook "{\"source\":\"$SRC\"}"
  [[ "$(jq -c '.polling_jobs' "$STATE")" == '[{"id":"live_job"}]' ]] \
    || fail "source=$SRC must not purge polling_jobs (a live job would be orphaned)"
  [[ "$(jq -r '.pmm.auto_wake_cron_id' "$STATE")" == "live_cron" ]] \
    || fail "source=$SRC must not clear auto_wake_cron_id"
done
ok "source=compact/resume/clear leaves live bookkeeping untouched"

# --- 3. An absent source fails safe (treated as not-startup) -----------------
run_hook '{}'
[[ "$(jq -c '.polling_jobs' "$STATE")" == '[{"id":"live_job"}]' ]] \
  || fail "an absent source must NOT purge — clearing a live record is the costlier error"
ok "an absent source fails safe: no purge"

run_hook 'not json at all'
[[ "$(jq -c '.polling_jobs' "$STATE")" == '[{"id":"live_job"}]' ]] \
  || fail "unparseable stdin must not purge"
ok "unparseable stdin fails safe: no purge"

# --- 4. Output stays valid JSON on every path --------------------------------
for SRC in '{"source":"startup"}' '{"source":"compact"}' '{}' 'garbage'; do
  run_hook "$SRC"
  [[ -z "$OUT" ]] && fail "hook produced no output for stdin: $SRC"
  jq -e . <<<"$OUT" >/dev/null 2>&1 \
    || fail "hook emitted invalid JSON for stdin $SRC: $OUT"
done
ok "hook emits valid JSON for startup, compact, absent, and garbage stdin"

echo
echo "All session-start-sync reconcile-gate tests passed."
