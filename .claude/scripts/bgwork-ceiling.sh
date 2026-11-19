#!/usr/bin/env bash
# bgwork-ceiling.sh — hard ceiling on chat silence while background work runs.
# catalog: scheduling-monitoring — Hard ceiling on chat silence while background work (subagents, watchers) runs
#
# PURPOSE
#   The silence-by-default rule (CLAUDE.md #3, Issue #1253) is enforced
#   in-turn by silence-detector.sh, a PostToolUse hook. That hook cannot fire
#   when the thread spawns a subagent (or any background work), ends its turn,
#   and waits for a completion notification — there are no tool calls to hook.
#   The launchd watchdog (silence-watchdog.sh) reads the same heartbeat file
#   out-of-turn but can only raise an OS notification, and it deliberately
#   historically skipped inactive sessions; its background-work exception now
#   retains desktop warnings there, but cannot inject a turn. This watch also
#   checks child artifacts independently of the parent's message heartbeat.
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
#                   guard (no background work started) or the watch is armed
#                   and ticking; exit 1 when background work is in flight and
#                   unarmed; exit 3 when it was armed but has not ticked within
#                   the stale threshold (the Monitor most likely expired —
#                   .claude/reference/monitor-expiry.md). Silent on stdout.
#   --tick          What the armed watch runs on a loop. Every tick touches the
#                   claude-bgceiling-ticked-<id> liveness marker that --check
#                   and --status read, so a watch that expired is detectable
#                   by something that did not expire with it. Checks registered Agent
#                   artifacts independently; prints investigative unknown/stall
#                   notices once per task/progress generation. Prints ONE breach line
#                   when the heartbeat file is stale past the trip point, and
#                   prints nothing otherwise. Parent freshness is not evidence
#                   of child progress; artifact activity is not task success.
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
# SESSION RESOLUTION
#   --session ID, else CLAUDE_BGCEILING_SESSION_ID (exported by the
#   session-start-sync.sh SessionStart hook through CLAUDE_ENV_FILE where the
#   host supports it), else CLAUDE_SESSION_ID, else CLAUDE_CODE_SESSION_ID.
#   --arm-command and --check never guess: with no id they exit 4 rather than
#   print a `default` watch the arm hook would reject (Issue #2201), and an
#   empty or flag-looking --session value is a usage error. Other modes keep
#   the historical `default` fallback; the hooks always pass --session.
#
# WHY Monitor AND NOT ScheduleWakeup / CronCreate
#   ScheduleWakeup is the /loop dynamic-mode scheduler and is unavailable in a
#   plain coding thread — exactly where the hole is. CronCreate fires on a
#   wall-clock cadence regardless of whether the thread is actually silent, so
#   a healthy thread would get spurious ceiling messages, and its jitter (up to
#   10% of the period) eats into the ceiling. A Monitor runs an out-of-turn
#   process whose stdout lines become chat events: turn-independent and silent
#   unless there is a real breach. It is NOT necessarily persistent: on runtimes
#   that cap `timeout_ms` (the desktop app: 30 minutes) it expires and must be
#   re-armed on its expiry notice. The tick marker above is what lets the Stop
#   guard and the launchd watchdog notice a missed re-arm.
#
# TUNING
#   CLAUDE_BGWORK_CEILING_S  Override the ceiling, in seconds. Must be a
#                            positive integer > CEILING_MARGIN_S; anything else
#                            falls back to the default and warns on stderr.
#   CLAUDE_BGCEILING_TICK_STALE_SECONDS
#                            Seconds without a tick (measured from the later of
#                            arming and the last tick) after which an armed
#                            watch counts as lapsed. Default 150 (five polls).
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
#   3  --check only: armed, but no tick within the stale threshold (lapsed).
#   4  --arm-command / --check: no session id resolved (see SESSION RESOLUTION).
#   5  State write failed (unwritable marker directory, disk full, ...).

set -uo pipefail

CEILING_S_DEFAULT=1200   # 20 minutes — the guarantee. Not published in rules.
CEILING_MARGIN_S=90      # poll granularity + time for the model to reply
CEILING_POLL_S=30        # how often the armed watch re-checks the heartbeat
TICK_STALE_S_DEFAULT=150 # five polls without a tick = the watch has lapsed

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

resolve_tick_stale() {
  local raw="${CLAUDE_BGCEILING_TICK_STALE_SECONDS:-}"
  # Force base 10: a leading zero would otherwise read as octal ("060" -> 48).
  if [[ "$raw" =~ ^[0-9]+$ ]] && (( 10#$raw > 0 )); then
    printf '%s' "$(( 10#$raw ))"
  else
    printf '%s' "$TICK_STALE_S_DEFAULT"
  fi
}

MODE=""
KIND=""
SESSION_ID=""
SESSION_GIVEN=0

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
      SESSION_GIVEN=1
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

if (( SESSION_GIVEN == 0 )); then
  SESSION_ID="${CLAUDE_BGCEILING_SESSION_ID:-${CLAUDE_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-}}}"
fi

# The two agent-facing modes refuse to guess. A bare --arm-command used to
# print `--session default`, which the arm hook (keyed on the payload session
# id) then rejected — a watch that ran but never counted (Issue #2201).
if [[ "$MODE" == "arm-command" || "$MODE" == "check" ]]; then
  if (( SESSION_GIVEN == 1 )) && [[ -z "$SESSION_ID" || "$SESSION_ID" == -* ]]; then
    die_usage "--session needs a real session id with --$MODE, got '${SESSION_ID}'"
  fi
  if [[ -z "$SESSION_ID" ]]; then
    printf 'bgwork-ceiling.sh: session unknown — no --session and none of CLAUDE_BGCEILING_SESSION_ID, CLAUDE_SESSION_ID, CLAUDE_CODE_SESSION_ID is set. Use the exact command from the bgwork-ceiling hook advisory, or pass --session <id>.\n' >&2
    exit 4
  fi
fi

# Match the session-id sanitising the silence hooks apply, so this script and
# silence-detector-ack.sh derive the SAME heartbeat path from the same raw id.
SESSION_ID="${SESSION_ID:-default}"
RUNTIME_SESSION_ID="$SESSION_ID"
SESSION_ID="${SESSION_ID//[^[:alnum:]_.-]/_}"
SESSION_ID="${SESSION_ID:-default}"

HEARTBEAT_FILE="${MARKER_DIR}/claude-heartbeat-${SESSION_ID}"
BGWORK_FILE="${MARKER_DIR}/claude-bgwork-${SESSION_ID}"
ARMED_FILE="${MARKER_DIR}/claude-bgceiling-armed-${SESSION_ID}"
EMITTED_FILE="${MARKER_DIR}/claude-bgceiling-emitted-${SESSION_ID}"
BLOCKS_FILE="${MARKER_DIR}/claude-bgceiling-blocks-${SESSION_ID}"
BREACH_FILE="${MARKER_DIR}/claude-bgceiling-unguarded-${SESSION_ID}"
ADVISED_FILE="${MARKER_DIR}/claude-bgceiling-advised-${SESSION_ID}"
TICKED_FILE="${MARKER_DIR}/claude-bgceiling-ticked-${SESSION_ID}"
LAPSE_FILE="${MARKER_DIR}/claude-bgceiling-lapsenotice-${SESSION_ID}"
TICK_STALE_S="$(resolve_tick_stale)"

# tick_age — seconds since the later of arming and the last tick, or empty
# when the watch was never armed (or its markers are unreadable).
tick_age() {
  [[ -f "$ARMED_FILE" ]] || return 0
  local base t
  base="$(file_mtime "$ARMED_FILE")"
  [[ -n "$base" ]] || return 0
  if [[ -f "$TICKED_FILE" ]]; then
    t="$(file_mtime "$TICKED_FILE")"
    [[ -n "$t" ]] && (( t > base )) && base="$t"
  fi
  printf '%s' "$(( $(date +%s) - base ))"
}

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
    rm -f "$BLOCKS_FILE" "$BREACH_FILE" "$ADVISED_FILE" "$TICKED_FILE" "$LAPSE_FILE" 2>/dev/null || true
    log_event "armed" "ceiling_s=${CEILING_S}"
    ;;

  check)
    # Nothing started -> nothing to guard.
    [[ -f "$BGWORK_FILE" ]] || exit 0
    [[ -f "$ARMED_FILE" ]] || exit 1
    # Armed: the trip point is silence-based, so one live watch covers every
    # later spawn. But "armed" only proves arming was observed; a watch on a
    # runtime that caps timeout_ms expires, so require a recent tick too.
    # An unreadable marker mtime is unknown liveness, not a healthy tick.
    age="$(tick_age)"
    [[ "$age" =~ ^-?[0-9]+$ ]] || exit 3
    (( age > TICK_STALE_S )) && exit 3
    exit 0
    ;;

  tick)
    # Liveness first, before any early exit: this marker is what proves the
    # watch is still running. A failed touch must never fail the tick.
    touch "$TICKED_FILE" 2>/dev/null || true
    # Run before the independent parent-heartbeat early exits. Read only exact
    # session/runtime registry rows; never mutate or stop another task.
    if [[ -f "$BGWORK_FILE" ]]; then
      python3 "${SCRIPT_PATH%/*}/lib/bgwork-child-progress.py" --tick "$RUNTIME_SESSION_ID" \
        "$MARKER_DIR/claude-bgprogress-${SESSION_ID}" || \
        printf 'CHILD PROGRESS UNKNOWN: progress helper unavailable; investigate; parent heartbeat is not child health.\n'
    fi
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
    printf 'CEILING BREACH: no user-visible message in %dm (%ds). Check child evidence (monitor-mode.md Liveness): a fresh parent heartbeat is not child progress. Surface a verified stall, unknown health, blocker, failure, decision, safety event, stopped/exhausted recovery, explicit status request or requested periodic report. Continue silently only when progress is verified and no notice is required; never send routine unchanged status.\n' \
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
    tick_age_s="$(tick_age)"
    [[ "$tick_age_s" =~ ^[0-9]+$ ]] || tick_age_s=-1
    tick_stale=false
    (( tick_age_s > TICK_STALE_S )) && tick_stale=true

    jq -nc \
      --argjson tick_age_s "$tick_age_s" \
      --argjson tick_stale "$tick_stale" \
      --argjson tick_stale_after_s "$TICK_STALE_S" \
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
        silence_s: $silence_s, consecutive_blocks: $blocks, unguarded: $unguarded,
        tick_age_s: $tick_age_s, tick_stale: $tick_stale,
        tick_stale_after_s: $tick_stale_after_s}'
    ;;

  clear)
    rm -f "$BGWORK_FILE" "$ARMED_FILE" "$EMITTED_FILE" "$BLOCKS_FILE" "$BREACH_FILE" \
          "$ADVISED_FILE" "$TICKED_FILE" "$LAPSE_FILE" 2>/dev/null || true
    python3 "${SCRIPT_PATH%/*}/lib/bgwork-child-progress.py" --clear "$RUNTIME_SESSION_ID" \
      "$MARKER_DIR/claude-bgprogress-${SESSION_ID}" || \
      printf 'bgwork-ceiling: child observation cleanup unavailable\n' >&2
    rm -f "$MARKER_DIR/claude-bgprogress-${SESSION_ID}.json" \
      "$MARKER_DIR/claude-bgprogress-${SESSION_ID}.unknown" \
      "$MARKER_DIR/claude-bgprogress-${SESSION_ID}.diagnostic" 2>/dev/null || true
    ;;

  *)
    die_usage "unhandled mode: $MODE"
    ;;
esac

exit 0
