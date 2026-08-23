#!/usr/bin/env bash
# bgwork-ceiling.sh — hard ceiling on chat silence while background work runs.
#
# PURPOSE
#   The silence-by-default rule (CLAUDE.md #3, Issue #1253) is enforced
#   in-turn by silence-detector.sh, a PostToolUse hook. That hook cannot fire
#   when the thread spawns a subagent (or any background work), ends its turn,
#   and waits for a completion notification — there are no tool calls to hook.
#   The launchd watchdog (silence-watchdog.sh) reads the same heartbeat file
#   out-of-turn but can only raise an OS notification, and it deliberately
#   skips sessions whose /tmp/claude-active-<id> marker is absent — which is
#   exactly the "ended its turn and is waiting" state. Result: silence with no
#   ceiling and no observer that can force a turn.
#
#   This script is the enforcement layer for that gap and the SOLE OWNER of the
#   ceiling number. Rule files describe the behavior ("arm the ceiling") and
#   never state a duration — keeping the ceiling number unpublished prevents
#   it from being read as a target cadence.
#
#   Measurement is NOT re-implemented here: /tmp/claude-heartbeat-<session-id>,
#   touched by the silence-detector-ack.sh Stop hook on every visible response,
#   already means "time of last user-visible message". This script only adds an
#   out-of-turn observer of it plus the state a fail-closed guard needs.
#
# USAGE
#   bgwork-ceiling.sh --note-started <kind> [--session ID]
#   bgwork-ceiling.sh --record-armed        [--session ID]
#   bgwork-ceiling.sh --check               [--session ID]
#   bgwork-ceiling.sh --tick                [--session ID]
#   bgwork-ceiling.sh --arm-command         [--session ID]
#   bgwork-ceiling.sh --status              [--session ID]
#   bgwork-ceiling.sh --clear               [--session ID]
#   bgwork-ceiling.sh --ceiling-seconds
#   bgwork-ceiling.sh --help | -h
#
# MODES
#   --note-started  Record that background work the thread will wait on has
#                   started (subagent spawn, backgrounded Bash, Workflow,
#                   Monitor). <kind> is a free-form label recorded for the
#                   status view. Idempotent.
#   --record-armed  Record that the ceiling watch is armed for this session.
#                   Resets the guard's consecutive-block counter and clears any
#                   degraded-guard breach record.
#   --check         Gate used by the Stop hook. Exit 0 when there is nothing to
#                   guard (no background work started) or the watch is armed;
#                   exit 1 when background work is in flight and unarmed.
#   --tick          What the armed watch runs on a loop. Prints ONE breach line
#                   when the heartbeat file is stale past the trip point, and
#                   prints nothing otherwise, so a thread emitting status at
#                   each turn-end never produces a ceiling message.
#                   Deduped per heartbeat mtime: one breach line per silence,
#                   not one per poll. Always exits 0 — a watch that exits stops
#                   watching.
#   --arm-command   Print the exact shell command to hand to the Monitor tool.
#                   The command embeds this script's absolute path and the
#                   resolved session id, and contains the `--tick` sentinel the
#                   PostToolUse hook matches to detect arming.
#   --status        Print a single-line JSON snapshot on stdout.
#   --clear         Remove this session's markers (test/teardown helper).
#
# WHY Monitor AND NOT ScheduleWakeup / CronCreate
#   ScheduleWakeup is the /loop dynamic-mode scheduler and is unavailable in a
#   plain coding thread — exactly where the hole is. CronCreate fires on a
#   wall-clock cadence regardless of whether the thread is actually silent, so
#   a healthy thread would get spurious ceiling messages, and its jitter (up to
#   10% of the period) eats into the ceiling. A Monitor runs an out-of-turn
#   process whose stdout lines become chat events: turn-independent, silent
#   unless there is a real breach, persistent for the session (so the ceiling is
#   armed once, not once per spawn), and reachable only by TaskStop — the
#   stable-state backoff in scheduling-reliability.md widens and deletes CRON
#   jobs, so it structurally cannot widen or delete this watch.
#
# TUNING
#   CLAUDE_BGWORK_CEILING_S  Override the ceiling, in seconds. Must be a
#                            positive integer > CEILING_MARGIN_S; anything else
#                            falls back to the default and warns on stderr.
#   The poll interval and trip point are DERIVED from the ceiling, never set
#   independently: the watch must emit early enough that poll granularity plus
#   the time the model needs to compose the message still lands inside the
#   ceiling. Deriving them keeps that invariant true for any override.
#
# OUTPUT
#   stdout: mode-dependent (breach line, JSON status, arm command, or nothing).
#   stderr: one-line diagnostics. State-write failures are always surfaced —
#           this guard fails CLOSED, so a marker it cannot write is reported
#           rather than swallowed (feedback_guard_must_fail_closed.md).
#
# EXIT STATUS
#   0  Success (and, for --check, nothing to guard or watch armed).
#   1  --check only: background work is in flight and the ceiling is unarmed.
#   2  Usage error (missing/unknown mode, bad flag value).
#   5  State write failed (unwritable marker directory, disk full, ...).

set -uo pipefail

CEILING_S_DEFAULT=1200   # 20 minutes — the guarantee. Not published in rules.
CEILING_MARGIN_S=90      # poll granularity + time for the model to reply
CEILING_POLL_S=30        # how often the armed watch re-checks the heartbeat

SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
LOG_DIR="${CLAUDE_BGWORK_LOG_DIR:-$HOME/.claude/logs}"
LOG_FILE="$LOG_DIR/bgwork-ceiling.log"
MARKER_DIR="${CLAUDE_BGWORK_MARKER_DIR:-/tmp}"

usage() {
  sed -n '2,/^$/p' "$SCRIPT_PATH" | sed 's/^# \{0,1\}//'
}

die_usage() {
  printf 'bgwork-ceiling.sh: %s\n' "$1" >&2
  printf 'Run with --help for usage.\n' >&2
  exit 2
}

resolve_ceiling() {
  local raw="${CLAUDE_BGWORK_CEILING_S:-}"
  if [[ -z "$raw" ]]; then
    printf '%s' "$CEILING_S_DEFAULT"
    return
  fi
  if [[ ! "$raw" =~ ^[0-9]+$ ]] || (( raw <= CEILING_MARGIN_S )); then
    printf 'bgwork-ceiling.sh: ignoring invalid CLAUDE_BGWORK_CEILING_S=%s (need integer > %s); using %s\n' \
      "$raw" "$CEILING_MARGIN_S" "$CEILING_S_DEFAULT" >&2
    printf '%s' "$CEILING_S_DEFAULT"
    return
  fi
  printf '%s' "$raw"
}

file_mtime() {
  if [[ "$(uname -s)" == "Darwin" ]]; then
    stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

# Fail closed: a marker we cannot write means the guard cannot do its job, so
# say so loudly and exit non-zero rather than degrading into a silent no-op.
write_marker() {
  local path="$1" body="${2:-}"
  if ! printf '%s' "$body" > "$path" 2>/dev/null; then
    printf 'bgwork-ceiling.sh: cannot write %s — ceiling state not recorded\n' "$path" >&2
    return 1
  fi
  return 0
}

log_event() {
  local event="$1" detail="${2:-}"
  mkdir -p "$LOG_DIR" 2>/dev/null || return 0
  printf '%s\t%s\t%s\t%s\n' \
    "$(date -u +%FT%TZ)" "$SESSION_ID" "$event" "$detail" >> "$LOG_FILE" 2>/dev/null || true
}

MODE=""
KIND=""
SESSION_ID="${CLAUDE_SESSION_ID:-}"

while (( $# > 0 )); do
  case "$1" in
    --note-started)
      [[ -n "$MODE" ]] && die_usage "only one mode may be given (already have --$MODE)"
      MODE="note-started"
      if (( $# < 2 )) || [[ "$2" == --* ]]; then
        die_usage "--note-started requires a <kind> argument"
      fi
      KIND="$2"
      shift
      ;;
    --record-armed|--check|--tick|--arm-command|--status|--clear|--ceiling-seconds)
      [[ -n "$MODE" ]] && die_usage "only one mode may be given (already have --$MODE)"
      MODE="${1#--}"
      ;;
    --session)
      (( $# >= 2 )) || die_usage "--session requires an argument"
      SESSION_ID="$2"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die_usage "unknown argument: $1"
      ;;
  esac
  shift
done

[[ -n "$MODE" ]] || die_usage "no mode given"

CEILING_S="$(resolve_ceiling)"
TRIP_S=$(( CEILING_S - CEILING_MARGIN_S ))

if [[ "$MODE" == "ceiling-seconds" ]]; then
  printf '%s\n' "$CEILING_S"
  exit 0
fi

# Match the session-id sanitising the silence hooks apply, so this script and
# silence-detector-ack.sh derive the SAME heartbeat path from the same raw id.
SESSION_ID="${SESSION_ID:-default}"
SESSION_ID="${SESSION_ID//[^[:alnum:]_.-]/_}"
SESSION_ID="${SESSION_ID:-default}"

HEARTBEAT_FILE="${MARKER_DIR}/claude-heartbeat-${SESSION_ID}"
BGWORK_FILE="${MARKER_DIR}/claude-bgwork-${SESSION_ID}"
ARMED_FILE="${MARKER_DIR}/claude-bgceiling-armed-${SESSION_ID}"
EMITTED_FILE="${MARKER_DIR}/claude-bgceiling-emitted-${SESSION_ID}"
BLOCKS_FILE="${MARKER_DIR}/claude-bgceiling-blocks-${SESSION_ID}"
BREACH_FILE="${MARKER_DIR}/claude-bgceiling-unguarded-${SESSION_ID}"
ADVISED_FILE="${MARKER_DIR}/claude-bgceiling-advised-${SESSION_ID}"

case "$MODE" in
  note-started)
    if [[ -f "$BGWORK_FILE" ]] && grep -qxF "$KIND" "$BGWORK_FILE" 2>/dev/null; then
      exit 0   # already recorded — idempotent
    fi
    if ! printf '%s\n' "$KIND" >> "$BGWORK_FILE" 2>/dev/null; then
      printf 'bgwork-ceiling.sh: cannot write %s — background work not tracked\n' "$BGWORK_FILE" >&2
      exit 5
    fi
    log_event "note-started" "$KIND"
    ;;

  record-armed)
    write_marker "$ARMED_FILE" "$(date -u +%FT%TZ)" || exit 5
    rm -f "$BLOCKS_FILE" "$BREACH_FILE" "$ADVISED_FILE" 2>/dev/null || true
    log_event "armed" "ceiling_s=${CEILING_S}"
    ;;

  check)
    # Nothing started -> nothing to guard.
    [[ -f "$BGWORK_FILE" ]] || exit 0
    # Armed once, armed for the session: the watch is persistent and its trip
    # point is silence-based, so it covers every later spawn too.
    [[ -f "$ARMED_FILE" ]] && exit 0
    exit 1
    ;;

  tick)
    # No heartbeat file yet means the session has not produced a visible
    # message for the hooks to stamp; there is nothing to measure from.
    [[ -f "$HEARTBEAT_FILE" ]] || exit 0
    last_ack="$(file_mtime "$HEARTBEAT_FILE")"
    [[ -n "$last_ack" ]] || exit 0

    age=$(( $(date +%s) - last_ack ))
    (( age >= TRIP_S )) || exit 0

    # Dedupe on the heartbeat's mtime: one breach line per stretch of silence.
    # When the agent finally speaks, the Stop hook re-touches the heartbeat, the
    # mtime changes, and the next genuine breach is reportable again.
    if [[ -f "$EMITTED_FILE" ]]; then
      emitted="$(cat "$EMITTED_FILE" 2>/dev/null)"
      [[ "$emitted" == "$last_ack" ]] && exit 0
    fi
    printf '%s' "$last_ack" > "$EMITTED_FILE" 2>/dev/null || \
      printf 'bgwork-ceiling.sh: cannot write %s — breach line may repeat\n' "$EMITTED_FILE" >&2

    log_event "breach" "age_s=${age}"
    printf 'CEILING BREACH: no user-visible message in %dm (%ds) while background work is in flight. Send a one-line status NOW (monitor-mode.md "Liveness"): [<ET timestamp>] <state> · next: <action>. "Still running, nothing new" is a complete and correct status line — say that rather than staying silent.\n' \
      "$(( age / 60 ))" "$age"
    ;;

  arm-command)
    # The `--tick` substring is the sentinel bgwork-ceiling-arm.sh matches to
    # recognise this call as ARMING rather than as new background work.
    printf 'while true; do %s --tick --session %s; sleep %s; done\n' \
      "$SCRIPT_PATH" "$SESSION_ID" "$CEILING_POLL_S"
    ;;

  status)
    started="[]"
    if [[ -f "$BGWORK_FILE" ]]; then
      started="$(sort -u "$BGWORK_FILE" 2>/dev/null | jq -Rsc 'split("\n") | map(select(length > 0))' 2>/dev/null || printf '[]')"
    fi
    armed=false
    [[ -f "$ARMED_FILE" ]] && armed=true
    silence=-1
    if [[ -f "$HEARTBEAT_FILE" ]]; then
      hb="$(file_mtime "$HEARTBEAT_FILE")"
      [[ -n "$hb" ]] && silence=$(( $(date +%s) - hb ))
    fi
    blocks=0
    [[ -f "$BLOCKS_FILE" ]] && blocks="$(cat "$BLOCKS_FILE" 2>/dev/null)"
    [[ "$blocks" =~ ^[0-9]+$ ]] || blocks=0
    unguarded=false
    [[ -f "$BREACH_FILE" ]] && unguarded=true

    jq -nc \
      --arg session "$SESSION_ID" \
      --argjson started "$started" \
      --argjson armed "$armed" \
      --argjson ceiling_s "$CEILING_S" \
      --argjson trip_s "$TRIP_S" \
      --argjson poll_s "$CEILING_POLL_S" \
      --argjson silence_s "$silence" \
      --argjson blocks "$blocks" \
      --argjson unguarded "$unguarded" \
      '{session: $session, background_work: $started, armed: $armed,
        ceiling_s: $ceiling_s, trip_s: $trip_s, poll_s: $poll_s,
        silence_s: $silence_s, consecutive_blocks: $blocks, unguarded: $unguarded}'
    ;;

  clear)
    rm -f "$BGWORK_FILE" "$ARMED_FILE" "$EMITTED_FILE" "$BLOCKS_FILE" "$BREACH_FILE" \
          "$ADVISED_FILE" 2>/dev/null || true
    ;;

  *)
    die_usage "unhandled mode: $MODE"
    ;;
esac

exit 0
