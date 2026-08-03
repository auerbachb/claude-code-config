#!/bin/bash
# PostToolUse hook: warn when an armed /babysit-pr watcher has stopped ticking.
#
# Issue #914. An armed CronCreate watcher stayed listed in CronList and produced
# ZERO ticks across an 11-minute idle window (reproduced 2026-08-01; see
# .claude/reference/scheduling-failure-modes.md Pattern 7). Nothing in the
# harness distinguished "poll armed" from "poll ticking": the pre-exit checklist
# verified presence only, and a listed job read as proof of a working poll.
# This hook is the liveness half — it watches last_tick_at, not the job list.
#
# Registered WITHOUT a matcher (all tools), unlike its Bash-only sibling
# polling-backoff-warn.sh. That is deliberate: a stalled poll issues no
# babysit-state commands and runs no gh calls, so a Bash-matcher hook would
# never fire in exactly the failure case this exists to catch.
#
# Advisory only — emits additionalContext, never blocks a turn.
#
# Fails SILENT, not loud, on every ambiguity (missing state, absent watcher,
# unparseable timestamp, clock skew, unwritable dedupe marker). A watchdog that
# cannot read the clock has no evidence a poll is dead, and a false alarm
# replayed on every tool call would train the reader to ignore the one that is
# real. The marker case is the sharpest: without a marker there is nothing to
# suppress the repeat, so emitting anyway is not "one extra warning" — it is a
# warning on every subsequent tool call until the poll recovers.

input=$(cat)

emit_context() {
  jq -n --arg message "$1" '{
    hookSpecificOutput: {
      hookEventName: "PostToolUse",
      additionalContext: $message
    }
  }'
}

json_field() {
  printf '%s' "$input" | jq -r "$1 // empty" 2>/dev/null
}

# Portable ISO-8601 UTC -> epoch seconds. Echoes nothing and returns non-zero
# when neither GNU nor BSD date can parse it; callers MUST check the exit code
# rather than trust a possibly-empty result (#634).
to_epoch() {
  local iso="$1"
  date -u -d "$iso" +%s 2>/dev/null && return 0
  date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$iso" +%s 2>/dev/null && return 0
  return 1
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
state_helper="${script_dir%/.claude/hooks}/.claude/scripts/session-state.sh"
state_file="${HOME}/.claude/session-state.json"

[[ -x "$state_helper" && -f "$state_file" ]] || exit 0

# Auto-scoped to the active repo by session-state.sh; a bare `.prs` path is
# rewritten into .repos["<owner>/<name>"].prs, so this never reads another
# repo's watchers (handoff-files.md read-scope rule).
prs_json=$("$state_helper" --get '.prs' 2>/dev/null) || exit 0
[[ -n "$prs_json" && "$prs_json" != "null" ]] || exit 0

# One record per live watcher: PR, last tick, effective cadence. Unit-separator
# delimited, never tab — a tab IFS silently collapses an empty field and shifts
# every field after it (memory: bash-tab-ifs-collapses-empty-fields).
records=$(printf '%s' "$prs_json" | jq -r '
  if type != "object" then empty else
    to_entries[]
    | select(.value.babysit != null)
    | select(.value.babysit.active == true)
    | select((.value.babysit.stop_requested // false) != true)
    | select((.value.babysit.last_tick_at // null) != null)
    | select((.value.babysit.last_tick_at | type) == "string")
    | [ .key,
        .value.babysit.last_tick_at,
        ((.value.babysit.cadence_effective_minutes
          // .value.babysit.cadence_base_minutes // 5) | tostring)
      ] | join("\u001f")
  end' 2>/dev/null) || exit 0

[[ -n "$records" ]] || exit 0

session_id=$(json_field '.session_id')
session_id="${session_id:-${CLAUDE_SESSION_ID:-default}}"
session_id="${session_id//[^[:alnum:]_.-]/_}"
marker_dir="${CLAUDE_BABYSIT_WATCHDOG_MARKER_DIR:-/tmp}"

now=$(date -u +%s)
stalled=()

while IFS=$'\x1f' read -r pr last_tick cadence; do
  [[ -n "$pr" && -n "$last_tick" ]] || continue

  [[ "$cadence" =~ ^[0-9]+$ ]] || cadence=5
  (( cadence > 0 )) || cadence=5

  # The early-warning window. Deliberately NOT the reap window — see
  # .claude/reference/cross-session-durability.md.
  warn_min=$(( cadence * 2 ))
  (( warn_min < 2 )) && warn_min=2

  tick_epoch=$(to_epoch "$last_tick") || continue   # unparseable -> no evidence
  [[ "$tick_epoch" =~ ^-?[0-9]+$ ]] || continue

  age_min=$(( ( now - tick_epoch ) / 60 ))
  (( age_min < 0 )) && continue                     # future-dated -> clock skew
  (( age_min >= warn_min )) || continue

  # Dedupe on PR + the exact last_tick_at, so one dead stretch warns once. A
  # real tick moves last_tick_at, which re-arms the warning for the next stall.
  # Sanitize the PR component: state keys are normally bare numbers, but a
  # corrupted key containing "/" would make this write land on a path that does
  # not exist. That write fails silently, no marker is recorded, and the
  # advisory then re-fires on EVERY tool call — the nag loop this hook's
  # fail-silent policy exists to avoid.
  pr_safe="${pr//[^[:alnum:]_.-]/_}"
  marker="${marker_dir}/claude-babysit-tickwarn-${session_id}-${pr_safe}"
  if [[ -f "$marker" ]] && [[ "$(cat "$marker" 2>/dev/null)" == "$last_tick" ]]; then
    continue
  fi

  # No marker, no warning. If the write fails there is nothing to suppress the
  # repeat, so emitting anyway would replay this advisory on EVERY tool call for
  # as long as the poll stays dead — the nag loop this hook exists to avoid.
  # Deliberately the opposite of silence-detector.sh's fail-open dedupe: that one
  # degrades to a duplicated timestamp, this one would degrade to a wall of
  # identical warnings. Surface on stderr (hook logs) rather than failing silently.
  if ! printf '%s' "$last_tick" > "$marker" 2>/dev/null; then
    echo "babysit-tick-watchdog: cannot write $marker — suppressing the PR #${pr} advisory rather than repeating it every tool call" >&2
    continue
  fi

  stalled+=( "PR #${pr}: last tick ${age_min}m ago (cadence ${cadence}m, warn at ${warn_min}m)" )
done <<< "$records"

(( ${#stalled[@]} > 0 )) || exit 0

printf -v body '%s; ' "${stalled[@]}"
emit_context "BABYSIT WATCHER NOT TICKING — ${body%; }. A recorded Monitor task can still be stale, so treat this as a dead poll, not a quiet one (issues #914 and #924; scheduling-failure-modes.md Pattern 7). TO RECOVER, run /babysit-pr-stop <PR> FIRST, then /babysit-pr <PR>: re-arming on its own is refused as a duplicate until the watcher ages past max(3 x cadence, 30m), which is deliberately wider than this warning's 2 x cadence window — so a bare re-arm here silently no-ops. /babysit-pr records the replacement persistent Monitor task ID; never substitute CronCreate, either /loop mode, or a chained one-shot wake-up. If the watch is simply finished, /babysit-pr-stop alone is enough. The silence ceiling is a backstop, not this poll's cadence."

exit 0
