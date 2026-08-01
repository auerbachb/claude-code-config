#!/usr/bin/env bash
# Tests for session-scheduling-reconcile.sh — session-start reconciliation of
# durable scheduling state (issues #827, #874).
#
# HOME is redirected into a temp dir for every case, so the suite never reads
# or writes the real ~/.claude/session-state.json or audit watermark.
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/.claude/scripts/session-scheduling-reconcile.sh"

TMP_DIR="$(mktemp -d)"
cleanup() { chmod -R u+w "$TMP_DIR" 2>/dev/null || true; rm -rf "$TMP_DIR"; }
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok   — $*"; }

CASE_N=0
# new_home [state-json] [watermark-json] — fresh isolated HOME per case.
new_home() {
  CASE_N=$((CASE_N + 1))
  export HOME="$TMP_DIR/home$CASE_N"
  mkdir -p "$HOME/.claude/harness-audit"
  [[ -n "${1:-}" ]] && printf '%s' "$1" > "$HOME/.claude/session-state.json"
  [[ -n "${2:-}" ]] && printf '%s' "$2" > "$HOME/.claude/harness-audit/last-run.json"
  STATE="$HOME/.claude/session-state.json"
}

# A watcher is judged by /babysit-pr's own freshness window,
# max(3 x cadence, BABYSIT_DISPATCH_TTL_MIN=30m) — not by "older than now".
PAST="2020-01-01T00:00:00Z"
FUTURE="2099-01-01T00:00:00Z"

# Relative stamps — never a hard-coded date, which flips past/future over time.
stamp_minutes_ago() {
  date -u -v-"$1"M +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
    || date -u -d "$1 minutes ago" +"%Y-%m-%dT%H:%M:%SZ"
}

# Get a provably dead PID and the current hostname for ownership-stamp tests
# (issue #874). A subshell that exits immediately guarantees the PID is dead
# by the time we read it, with no race on macOS or Linux.
( : ) &
_DEAD_PID=$!
wait $_DEAD_PID 2>/dev/null || true
CURRENT_HOST="$(hostname 2>/dev/null || echo "localhost")"

# FULL_STATE: polling_jobs and auto_wake_cron_id carry owner_session stamps
# pointing at the dead PID above. Tests that expect purging require stamped
# records; unstamped-record behaviour is tested separately in test 1a.
FULL_STATE=$(cat <<JSON
{
  "polling_jobs": [
    {"id":"cron_a","owner":"harness-audit","owner_session":{"pid":${_DEAD_PID},"host":"${CURRENT_HOST}"}},
    {"id":"cron_b","owner":"pmm","owner_session":{"pid":${_DEAD_PID},"host":"${CURRENT_HOST}"}}
  ],
  "pmm": {
    "auto_wake_cron_id": "cron_b",
    "auto_wake_owner_session": {"pid":${_DEAD_PID},"host":"${CURRENT_HOST}"}
  },
  "repos": {"o/r": {"prs": {
    "10": {"babysit": {"active": true, "cron_job_id": "cron_c", "last_tick_at": "$PAST"}},
    "11": {"babysit": {"active": true, "cron_job_id": null, "last_tick_at": "$FUTURE"}}
  }}},
  "root_repo": "/keep/me"
}
JSON
)

# UNSTAMPED_STATE: same structure but polling_jobs/auto_wake carry NO
# owner_session stamp. The fail-closed rule (issue #874) must NOT purge these.
UNSTAMPED_STATE=$(cat <<JSON
{
  "polling_jobs": [{"id":"cron_a","owner":"harness-audit"},{"id":"cron_b","owner":"pmm"}],
  "pmm": {"auto_wake_cron_id": "cron_b"},
  "repos": {"o/r": {"prs": {
    "10": {"babysit": {"active": true, "cron_job_id": "cron_c", "last_tick_at": "$PAST"}},
    "11": {"babysit": {"active": true, "cron_job_id": null, "last_tick_at": "$FUTURE"}}
  }}},
  "root_repo": "/keep/me"
}
JSON
)

# --- 0. The embedded jq program is quote-safe --------------------------------
# The jq filter lives in a single-quoted heredoc-less block, so one apostrophe
# in a comment (`A2's`) closes the quote and the rest parses as shell. The
# script is fail-soft by design, so that breakage exits 0 and silently purges
# nothing — caught here rather than in production.
awk 'NR>1 && /^  . "\$STATE_FILE"/{inblock=0} inblock && /'"'"'/{print NR; found=1}
     /--argjson ttl/{inblock=1} END{exit found?1:0}' "$SCRIPT" >/dev/null \
  || fail "apostrophe inside the single-quoted jq program — it will break quoting"
ok "the embedded jq program contains no quote-breaking apostrophes"

# --- 1. Dead-owner stamped records are purged (issue #874) -------------------
# polling_jobs and auto_wake_cron_id with owner_session stamps pointing at a
# verifiably dead PID must be reaped, just like they were before the fix.
new_home "$FULL_STATE"
"$SCRIPT" >/dev/null
[[ "$(jq -c '.polling_jobs' "$STATE")" == "[]" ]] \
  || fail "polling_jobs with dead-owner stamp should be emptied, got $(jq -c '.polling_jobs' "$STATE")"
[[ "$(jq -r '.pmm.auto_wake_cron_id' "$STATE")" == "null" ]] \
  || fail "pmm.auto_wake_cron_id with dead-owner stamp should be null"
[[ "$(jq -r '.repos["o/r"].prs["10"].babysit.cron_job_id' "$STATE")" == "null" ]] \
  || fail "babysit.cron_job_id should be null"
ok "purges dead-stamped polling_jobs, auto_wake_cron_id, and babysit.cron_job_id"

# --- 1a. Unstamped records are NOT purged — fail-closed (issue #874) ---------
# If an entry in polling_jobs or auto_wake_cron_id has no owner_session stamp
# we cannot verify liveness. Fail-closed: skip the purge and surface a notice.
# This is the core regression test for the concurrent-session bug.
new_home "$UNSTAMPED_STATE"
BEFORE_PJ="$(jq -c '.polling_jobs' "$STATE")"
"$SCRIPT" >/dev/null
[[ "$(jq -c '.polling_jobs' "$STATE")" == "$BEFORE_PJ" ]] \
  || fail "unstamped polling_jobs must NOT be purged (fail-closed), got $(jq -c '.polling_jobs' "$STATE")"
[[ "$(jq -r '.pmm.auto_wake_cron_id' "$STATE")" != "null" ]] \
  || fail "unstamped auto_wake_cron_id must NOT be cleared (fail-closed)"
ok "unstamped polling_jobs and auto_wake_cron_id are preserved (fail-closed)"

# Babysit bookkeeping (freshness-window path) is still reconciled normally even
# when polling_jobs is unstamped.
[[ "$(jq -r '.repos["o/r"].prs["10"].babysit.cron_job_id' "$STATE")" == "null" ]] \
  || fail "babysit.cron_job_id should still be cleared for stale watcher"
[[ "$(jq -r '.repos["o/r"].prs["10"].babysit.active' "$STATE")" == "false" ]] \
  || fail "stale babysit watcher should still be deactivated"
ok "babysit freshness-window path is unaffected when polling_jobs are unstamped"

# A skip notice must be surfaced so the operator knows the record was seen.
SKIP_OUT="$("$SCRIPT")"
echo "$SKIP_OUT" | grep -q "scheduling-reconcile:" \
  || fail "skipped unstamped records should emit a notice, got: $SKIP_OUT"
ok "a skip notice is surfaced when polling_jobs have no owner stamp"

# --- 1b. Live-session records are NOT purged ---------------------------------
# A polling_job stamped with the CURRENT session PID (kill -0 succeeds)
# must not be reaped — that record belongs to this running session.
LIVE_PID=$$
LIVE_STATE=$(cat <<JSON
{
  "polling_jobs": [
    {"id":"live_cron","owner":"pmm","owner_session":{"pid":${LIVE_PID},"host":"${CURRENT_HOST}"}}
  ],
  "pmm": {
    "auto_wake_cron_id": "live_cron",
    "auto_wake_owner_session": {"pid":${LIVE_PID},"host":"${CURRENT_HOST}"}
  }
}
JSON
)
new_home "$LIVE_STATE"
"$SCRIPT" >/dev/null
PJ_AFTER="$(jq -c '.polling_jobs' "$STATE")"
[[ "$PJ_AFTER" != "[]" ]] \
  || fail "polling_job owned by a live PID must not be reaped, got: $PJ_AFTER"
[[ "$(jq -r '.pmm.auto_wake_cron_id' "$STATE")" != "null" ]] \
  || fail "auto_wake_cron_id owned by a live PID must not be cleared"
ok "polling_jobs and auto_wake_cron_id owned by a live PID are preserved"

# --- 2. Only watchers that cannot be alive are deactivated -------------------
# The freshness test is what keeps this from reaping a watcher armed seconds
# ago in the current session — the exact failure that would make a re-arm
# reconciler worse than no reconciler at all.
new_home "$FULL_STATE"
"$SCRIPT" >/dev/null
[[ "$(jq -r '.repos["o/r"].prs["10"].babysit.active' "$STATE")" == "false" ]] \
  || fail "stale watcher (last tick in the past) should be deactivated"
[[ "$(jq -r '.repos["o/r"].prs["11"].babysit.active' "$STATE")" == "true" ]] \
  || fail "watcher that ticked after process start must stay active"
ok "deactivates a watcher whose last tick is far outside the freshness window"

# --- 2b. A live watcher survives a mid-session run (compact/resume/fork) -----
# SessionStart also fires on compact, so this script runs while a watcher is
# genuinely alive with a last tick minutes old. Reaping it there would kill the
# watcher for real: its next tick sees active=false and T0-terminates.
for AGO in 1 4 9 29; do
  new_home "$(cat <<JSON
{"repos":{"o/r":{"prs":{"42":{"babysit":{"active":true,"cadence_effective_minutes":5,
 "last_tick_at":"$(stamp_minutes_ago $AGO)"}}}}}}
JSON
)"
  "$SCRIPT" >/dev/null
  [[ "$(jq -r '.repos["o/r"].prs["42"].babysit.active' "$STATE")" == "true" ]] \
    || fail "watcher that ticked ${AGO}m ago (5m cadence, 30m window) must stay active"
done
ok "a live watcher ticking 1–29m ago survives a compact-fired run"

# Past the window it is reclaimable again — the guard must not be unbounded.
new_home "$(cat <<JSON
{"repos":{"o/r":{"prs":{"42":{"babysit":{"active":true,"cadence_effective_minutes":5,
 "last_tick_at":"$(stamp_minutes_ago 45)"}}}}}}
JSON
)"
"$SCRIPT" >/dev/null
[[ "$(jq -r '.repos["o/r"].prs["42"].babysit.active' "$STATE")" == "false" ]] \
  || fail "watcher 45m stale (past the 30m window) should be deactivated"
ok "a watcher past the freshness window is still reclaimed"

# A slow cadence widens the window: 20m cadence -> max(60, 30) = 60m.
new_home "$(cat <<JSON
{"repos":{"o/r":{"prs":{"42":{"babysit":{"active":true,"cadence_effective_minutes":20,
 "last_tick_at":"$(stamp_minutes_ago 45)"}}}}}}
JSON
)"
"$SCRIPT" >/dev/null
[[ "$(jq -r '.repos["o/r"].prs["42"].babysit.active' "$STATE")" == "true" ]] \
  || fail "45m-old tick on a 20m cadence is inside max(3x20,30)=60m — must stay active"
ok "the window scales with the watcher's own cadence"

# --- 2c. Writes go through session-state.sh, never a raw jq+mv ---------------
# handoff-files.md: session-state.sh is the only writer. A raw rewrite here
# would clobber a concurrent --set that legitimately held the lock.
grep -q 'session-state.sh' "$SCRIPT" \
  || fail "the reconciler must write via session-state.sh"
grep -qE 'mv -f?[[:space:]]+"?\$\{?(TMP|STATE_FILE)' "$SCRIPT" \
  && fail "the reconciler must not mv over session-state.json directly"
ok "writes are delegated to session-state.sh, not a raw jq+mv"

# A concurrent writer's field must survive the purge.
new_home "$FULL_STATE"
"$REPO_ROOT/.claude/scripts/session-state.sh" --raw-path --set '.concurrent_field="must_survive"' >/dev/null 2>&1
"$SCRIPT" >/dev/null
[[ "$(jq -r '.concurrent_field' "$STATE")" == "must_survive" ]] \
  || fail "a field written by another writer must survive the purge"
[[ "$(jq -c '.polling_jobs' "$STATE")" == "[]" ]] \
  || fail "the purge itself must still have applied"
ok "purge preserves another writer's fields"

# --- 3. Unrelated siblings survive the rewrite -------------------------------
# Value-not-location: writing through session-state.sh also performs its
# documented legacy->scoped migration, so a top-level `root_repo` is relocated
# under `.repos[...]`. Preserved, not lost — assert the value survives somewhere
# rather than pinning the layout the canonical writer is entitled to change.
jq -e --arg v "/keep/me" '[.. | strings] | index($v) != null' "$STATE" >/dev/null \
  || fail "unrelated state values must survive the purge (got: $(jq -c . "$STATE"))"
ok "preserves unrelated state values across the canonical writer's migration"

# --- 4. Idempotent: a second run purges nothing and says nothing -------------
OUT2="$("$SCRIPT")"
grep -q "Cleared" <<<"$OUT2" && fail "second run should have nothing left to clear, got: $OUT2"
ok "idempotent — a clean state produces no purge notice"

# --- 5. --check makes no writes, and does not claim it did -------------------
new_home "$FULL_STATE"
BEFORE="$(cat "$STATE")"
CHECK_OUT="$("$SCRIPT" --check)"
[[ "$(cat "$STATE")" == "$BEFORE" ]] || fail "--check must not modify the state file"
ok "--check reports without writing"

grep -q "Cleared" <<<"$CHECK_OUT" \
  && fail "--check must not report work as done; got: $CHECK_OUT"
grep -q "Would clear" <<<"$CHECK_OUT" \
  || fail "--check should say what it would clear; got: $CHECK_OUT"
ok "--check says 'would clear', never 'cleared'"

# --- 5b. A string-typed cadence gets the same window as a numeric one --------
# /babysit-pr A2 tests cadence with a bash numeric regex, so "20" is live there.
# Reading it as non-numeric here would fall back to 5 and SHRINK the window
# below A2's — reaping a backed-off watcher A2 still considers fresh.
for CAD in 20 '"20"'; do
  new_home "$(cat <<JSON
{"repos":{"o/r":{"prs":{"42":{"babysit":{"active":true,"cadence_effective_minutes":$CAD,
 "last_tick_at":"$(stamp_minutes_ago 45)"}}}}}}
JSON
)"
  "$SCRIPT" >/dev/null
  [[ "$(jq -r '.repos["o/r"].prs["42"].babysit.active' "$STATE")" == "true" ]] \
    || fail "cadence $CAD: 45m-old tick is inside max(3x20,30)=60m — must stay active"
done
ok "a string-typed cadence yields the same freshness window as a number"

# --- 5c. An unparseable last_tick_at is NOT treated as dead ------------------
# Deliberate: this runs unattended on every compact, and clearing `active` on a
# stamp we merely failed to parse would T0-terminate a live watcher. A truly
# corrupt stamp is reclaimed by A2's bounded parse-failure counter instead.
new_home '{"repos":{"o/r":{"prs":{"42":{"babysit":{"active":true,"last_tick_at":"not-a-timestamp"}}}}}}'
"$SCRIPT" >/dev/null
[[ "$(jq -r '.repos["o/r"].prs["42"].babysit.active' "$STATE")" == "true" ]] \
  || fail "an unparseable last_tick_at must not deactivate a watcher"
ok "an unparseable last_tick_at leaves the watcher alone (A2 owns that reclaim)"

# A genuinely absent stamp is still dead — the guard must not swallow that too.
new_home '{"repos":{"o/r":{"prs":{"42":{"babysit":{"active":true}}}}}}'
"$SCRIPT" >/dev/null
[[ "$(jq -r '.repos["o/r"].prs["42"].babysit.active' "$STATE")" == "false" ]] \
  || fail "a watcher with no last_tick_at at all should be deactivated"
ok "a watcher with no last_tick_at is still reclaimed"

# --- 6. A legacy (unmigrated, top-level .prs) file is reconciled too ---------
new_home '{"prs":{"7":{"babysit":{"active":true,"cron_job_id":"cron_z","last_tick_at":"2020-01-01T00:00:00Z"}}}}'
"$SCRIPT" >/dev/null
# Assert on EVERY babysit record in the document, not just the top-level one.
# session-state.sh migrates legacy `.prs` into `.repos[...]` as a side effect of
# writing, so checking only `.prs["7"]` would pass while a migrated scoped copy
# kept the stale values that real consumers actually read.
STALE=$(jq -c '[.. | objects | select(has("cron_job_id")) | select(.cron_job_id != null or .active == true)]' "$STATE")
[[ "$STALE" == "[]" ]] \
  || fail "every babysit record must be reconciled, incl. the migrated scoped copy; stale: $STALE"
COUNT=$(jq '[.. | objects | select(has("cron_job_id"))] | length' "$STATE")
[[ "$COUNT" == "1" ]] \
  || fail "expected exactly one babysit record after migration, got $COUNT (a duplicate means the purge recreated a legacy record beside the migrated one)"
ok "reconciles the legacy layout without leaving a stale migrated copy"

# --- 7. harness-audit watermark drives the nudge -----------------------------
MONTH="$(TZ='America/New_York' date +%Y-%m)"

new_home '{}' "{\"nudge_enabled\":true,\"last_completed_month\":\"2000-01\"}"
"$SCRIPT" | grep -q "harness-audit is due" || fail "a due month should nudge"
ok "nudges when the audit month is due"

new_home '{}' "{\"nudge_enabled\":true,\"last_completed_month\":\"$MONTH\"}"
"$SCRIPT" | grep -q "harness-audit" && fail "an audited month must not nudge"
ok "silent when this month is already audited"

new_home '{}' "{\"nudge_enabled\":true,\"last_offered_month\":\"$MONTH\"}"
"$SCRIPT" | grep -q "already offered" || fail "a pending chip should be named, not re-offered"
ok "names the pending chip instead of re-offering"

new_home '{}' "{\"nudge_enabled\":false,\"last_completed_month\":\"2000-01\"}"
"$SCRIPT" | grep -q "harness-audit" && fail "--stop (nudge_enabled:false) must silence the nudge"
ok "nudge_enabled:false silences the audit nudge"

# --- 8. A paused fleet is surfaced (the real cross-session continuity) -------
new_home '{"pmm":{"paused_at":"2026-07-30T10:00:00Z"}}'
"$SCRIPT" | grep -q "paused PR fleet" || fail "a pause marker should be surfaced"
ok "surfaces a paused PR fleet from the durable marker"

# --- 9. Fail-soft: never block a session start -------------------------------
# Each of these would be a plausible crash site; all must exit 0 and leave the
# session startable, because this runs on the SessionStart path.
new_home
"$SCRIPT" >/dev/null 2>&1 || fail "missing state file must still exit 0"
ok "exits 0 when the state file is absent"

new_home '{ this is not json'
"$SCRIPT" >/dev/null 2>&1 || fail "corrupt state file must still exit 0"
[[ "$(cat "$STATE")" == '{ this is not json' ]] \
  || fail "a corrupt state file must be left untouched, not truncated"
ok "exits 0 and leaves a corrupt state file untouched"

new_home '{"pmm":{"paused_at":"2026-07-30T10:00:00Z"}}' '{ bad json'
"$SCRIPT" >/dev/null 2>&1 || fail "corrupt watermark must still exit 0"
ok "exits 0 when the audit watermark is corrupt"

new_home '{}'
"$SCRIPT" --bogus-flag >/dev/null 2>&1 || fail "unknown flag must still exit 0"
ok "exits 0 on an unknown flag rather than failing the hook"

# --- 10. JSON output is well-formed for the hook to embed --------------------
new_home "$FULL_STATE"
J="$("$SCRIPT" --format json)"
jq -e '.purged and (.notices | type == "array")' <<<"$J" >/dev/null \
  || fail "--format json should emit {purged, notices}, got: $J"
jq -e '.purged.polling_jobs == 2 and .purged.babysit_watchers == 1' <<<"$J" >/dev/null \
  || fail "purge counts should describe the write that landed, got: $J"
ok "--format json emits well-formed counts and notices"

new_home '{}'
jq -e '.notices == []' <<<"$("$SCRIPT" --format json)" >/dev/null \
  || fail "an empty state should yield an empty notices array, not [\"\"]"
ok "--format json emits an empty notices array when there is nothing to say"

# Unstamped records produce a non-zero skip count in the purged object.
new_home "$UNSTAMPED_STATE"
J_SKIP="$("$SCRIPT" --format json)"
jq -e '(.purged.polling_jobs_skip // 0) >= 1' <<<"$J_SKIP" >/dev/null \
  || fail "unstamped polling_jobs should appear as polling_jobs_skip, got: $J_SKIP"
ok "--format json reports skipped unstamped records in polling_jobs_skip"

# --- 11. A failed write must not report counts it did not land ---------------
# `purged` is a claim about what changed. If the write fails, reporting the
# planned counts tells a JSON consumer the cleanup succeeded when it did not.
new_home "$FULL_STATE"
chmod 500 "$HOME/.claude" 2>/dev/null || true
J="$("$SCRIPT" --format json 2>/dev/null)"
chmod 700 "$HOME/.claude" 2>/dev/null || true
if jq -e '[.purged[]] | add > 0' <<<"$J" >/dev/null 2>&1; then
  jq -e '.notices | length > 0' <<<"$J" >/dev/null     || fail "reported non-zero purged counts with no notice: $J"
  # counts > 0 only legitimate if the write actually landed
  [[ "$(jq -c '.polling_jobs' "$STATE")" == "[]" ]] \
    || fail "purged counts reported but state file unchanged: $J"
fi
ok "purged counts never claim work the write did not land"

echo
echo "All session-scheduling-reconcile.sh tests passed."
