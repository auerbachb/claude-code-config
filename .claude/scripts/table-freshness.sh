#!/usr/bin/env bash
# table-freshness.sh — hourly freshness floor on the "Running now" table.
#
# PURPOSE
#   The silence ceiling (bgwork-ceiling.sh) bounds how long a thread can go
#   without SAYING anything while background work runs. It measures MESSAGES,
#   so a bare "still running, nothing new" one-liner satisfies it — and a
#   thread can stay technically live for hours while the last full board the
#   user saw goes stale. The user plans testing rounds around that board.
#
#   This script is the complementary bound: message-freshness is the ceiling's
#   job, TABLE-freshness is this one's. While at least one pipeline is running
#   or queued, a full "Running now" table is never more than an hour old. The
#   two bounds are deliberately separate and a future consolidation must not
#   drop either — see .claude/reference/time-estimates.md §"Table freshness".
#
#   This script is the SOLE OWNER of the floor number and of the stale/fresh
#   verdict. Skills describe the behavior ("render the table when --check says
#   stale") and never re-derive the arithmetic.
#
# IDLE THREADS ARE EXEMPT
#   The floor is scoped to ACTIVE ROUNDS. When nothing is running or queued,
#   the round-end board is terminal and the thread stays quiet: no always-on
#   hourly pulse, which would fight the stable-state backoff design in
#   scheduling-reliability.md. Activity is caller-declared at render time
#   (--active N, the count of running + queued pipelines) because it is the
#   caller that knows its queue — no durable field tracks queued issues, and
#   .repos[...].pipelines is append-only, so it cannot answer "still active?".
#
# DURABILITY
#   The render timestamp lives in ~/.claude/session-state.json at
#   .repos["<key>"].table_render["<session>"], written through
#   session-state.sh (never inline jq — handoff-files.md). On disk is the
#   point: a context compaction wipes the thread's memory of when it last
#   rendered, and the clock has to survive that. Session-keyed under the repo
#   block, exactly like execution_pauses, so two orchestration threads in one
#   repo keep independent board clocks. Shared field — /board (issue #1581)
#   reads and writes the same record; contract in session-state-schema.json.
#
# USAGE
#   table-freshness.sh --note-rendered --active <N> [--surface LABEL]
#                                      [--session ID] [--repo OWNER/NAME]
#   table-freshness.sh --check [--active <N>] [--session ID] [--repo OWNER/NAME]
#   table-freshness.sh --tick                 [--session ID] [--repo OWNER/NAME]
#   table-freshness.sh --arm-command          [--session ID] [--repo OWNER/NAME]
#   table-freshness.sh --status               [--session ID] [--repo OWNER/NAME]
#   table-freshness.sh --clear                [--session ID] [--repo OWNER/NAME]
#   table-freshness.sh --floor-seconds
#   table-freshness.sh --help | -h
#
# MODES
#   --note-rendered  Record that a full "Running now" table was just emitted.
#                    --active <N> is REQUIRED: the number of pipelines running
#                    or queued at render time. N=0 records the round-end
#                    terminal board and disarms the floor. Every render site —
#                    dispatch, heartbeat, on-demand, /board — calls this.
#   --check          Gate for a status message about to be emitted. Prints ONE
#                    verdict word on stdout and exits:
#                      fresh      (0) last render is inside the floor
#                      idle       (0) nothing running or queued — exempt
#                      unrecorded (0) no render recorded and no --active given
#                      stale      (1) THIS message must carry the full table
#                    Pass --active <N> when known (a heartbeat always knows):
#                    with no recorded render it makes the verdict fail closed
#                    to `stale` rather than guessing `unrecorded`.
#   --tick           What the armed Monitor runs on a loop. Prints ONE floor
#                    line when the hour elapses with work still active, and
#                    prints nothing otherwise — a thread that re-renders on its
#                    own cadence never produces a floor message. Deduped per
#                    recorded render timestamp: one line per stale stretch, not
#                    one per poll. Always exits 0 — a watch that exits stops
#                    watching.
#   --arm-command    Print the exact shell command to hand to the Monitor tool.
#                    Embeds this script's absolute path, the resolved session
#                    id, and the resolved repo key — the tick runs out-of-turn
#                    from an arbitrary cwd and cannot re-derive the repo.
#   --status         Print a single-line JSON snapshot on stdout.
#   --clear          Drop this session's render record and dedupe marker
#                    (teardown for /pause, /end, and tests).
#   --floor-seconds  Print the floor in seconds and exit.
#
# WHY Monitor AND NOT CronCreate / ScheduleWakeup
#   Same reasoning as bgwork-ceiling.sh, and the same rule
#   (scheduling-reliability.md): CronCreate is reproducibly zero-tick and
#   session-only, and a chain of one-shot ScheduleWakeup calls is exactly the
#   hand-rolled recurrence that rule bans. A Monitor runs an out-of-turn
#   process whose stdout becomes a chat event: turn-independent, silent unless
#   the floor actually trips, and reachable only by TaskStop — so the
#   stable-state backoff, which widens and deletes polls, structurally cannot
#   widen or delete this floor.
#
# TUNING
#   CLAUDE_TABLE_FLOOR_S  Override the floor, in seconds. Must be a positive
#                         integer > FLOOR_MARGIN_S; anything else falls back to
#                         the default and warns on stderr.
#   The trip point is DERIVED from the floor (floor − margin), never set
#   independently, and the margin covers the fixed 60-second poll interval plus
#   the time the model needs to compose and render the table. That is the
#   invariant: trip + poll must land inside the floor, for the default and for
#   any override — which is why lowering the floor to at or below the margin is
#   rejected rather than honored.
#
# OUTPUT
#   stdout: mode-dependent (verdict word, floor line, JSON status, arm command,
#           or nothing).
#   stderr: one-line diagnostics. State-write failures are always surfaced —
#           a clock this script cannot record is reported, never swallowed.
#
# EXIT STATUS
#   0  Success (and, for --check, a one-liner is acceptable).
#   1  --check only: the message being composed MUST carry the full table.
#   2  Usage error (missing/unknown mode, bad flag value).
#   5  State write failed (session-state.sh could not persist the record).

set -uo pipefail

# Captured BEFORE parsing consumes them, for the usage-telemetry append below.
# The append itself is deferred until the mode is known: --tick runs on a
# 60-second Monitor loop for the life of the session, and logging that would
# add ~1,400 lines a day of pure noise to script-usage.log. Every
# human/skill-invoked mode is logged; only the loop body is exempt.
RAW_ARGS="${*//$'\n'/ }"

FLOOR_S_DEFAULT=3600   # 60 minutes — the guarantee, and deliberately public:
                       # the user plans rounds against "never older than an hour".
FLOOR_MARGIN_S=120     # poll granularity + time to compose and render the table
FLOOR_POLL_S=60        # how often the armed watch re-checks the recorded render

SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
SESSION_STATE_SH="$SCRIPT_DIR/session-state.sh"
MARKER_DIR="${CLAUDE_TABLE_FRESHNESS_MARKER_DIR:-/tmp}"

usage() {
  sed -n '2,/^$/p' "$SCRIPT_PATH" | sed 's/^# \{0,1\}//'
}

die_usage() {
  printf 'table-freshness.sh: %s\n' "$1" >&2
  printf 'Run with --help for usage.\n' >&2
  exit 2
}

resolve_floor() {
  local raw="${CLAUDE_TABLE_FLOOR_S:-}"
  if [[ -z "$raw" ]]; then
    printf '%s' "$FLOOR_S_DEFAULT"
    return
  fi
  # The digit-count bound is checked BEFORE any arithmetic, and that order is the
  # point. `^[0-9]+$` admits a value of any length, but every use of the floor —
  # the `<=` just below, `TRIP_S = FLOOR_S - FLOOR_MARGIN_S`, and the age
  # comparisons — is 64-bit Bash arithmetic, which WRAPS rather than erroring.
  # A wrapped floor is not merely a strange number: it can come out negative, and
  # a negative TRIP_S makes `age >= TRIP_S` true forever, so the floor fires on
  # every single tick. Validating with arithmetic that has already overflowed
  # cannot catch that — the check would be reading the corrupted value.
  # FLOOR_MAX_DIGITS=9 allows up to ~31 years, far past any real floor and far
  # short of the 19 digits where wrapping begins.
  local FLOOR_MAX_DIGITS=9
  if [[ ! "$raw" =~ ^[0-9]+$ ]] || (( ${#raw} > FLOOR_MAX_DIGITS )) || (( raw <= FLOOR_MARGIN_S )); then
    printf 'table-freshness.sh: ignoring invalid CLAUDE_TABLE_FLOOR_S=%s (need integer > %s, at most %s digits); using %s\n' \
      "$raw" "$FLOOR_MARGIN_S" "$FLOOR_MAX_DIGITS" "$FLOOR_S_DEFAULT" >&2
    printf '%s' "$FLOOR_S_DEFAULT"
    return
  fi
  printf '%s' "$raw"
}

# ISO-8601 UTC -> epoch seconds. BSD/macOS syntax first, GNU second — the same
# dual-syntax idiom overrun-check.sh uses. Prints nothing when it will not parse.
iso_to_epoch() {
  TZ=UTC date -j -f '%Y-%m-%dT%H:%M:%SZ' "$1" '+%s' 2>/dev/null \
    || date -d "$1" '+%s' 2>/dev/null
}

# Strip leading zeros from an already-digit-validated count: "007" -> "7",
# "000" -> "0". A zero-padded count passes the `^[0-9]+$` guards below, and jq
# is lenient enough to store it correctly (`--argjson active 010` records 10),
# which is exactly what makes this dangerous: the RECORD is right and the SHELL
# is wrong, so the two disagree silently.
#
#   `(( 010 > 0 ))`  reads octal — the value becomes 8, not 10.
#   `(( 08 > 0 ))`   is a hard "value too great for base" error, and an erroring
#                    `(( ))` returns NON-ZERO. In --tick that lands on
#                    `(( ACTIVE_RECORDED > 0 )) || exit 0`, so the tick exits
#                    silently and the hourly floor never fires at all.
#   `printf '%d' 010` reads octal too (prints 8), and `printf '%d' 08` prints 0
#                    after an "invalid octal number" warning — so the floor line
#                    would report a count that contradicts the stored record.
#
# Normalising once, at each point a count is admitted, removes all three.
# Done textually rather than with `$(( 10#$v ))` on purpose: the arithmetic form
# would also silently wrap a count wider than 64 bits, turning an absurd input
# into a plausible wrong number instead of leaving it intact.
#
# A count longer than COUNT_MAX_DIGITS is rejected outright (empty result) rather
# than normalised. `^[0-9]+$` admits any length, and every consumer is 64-bit
# Bash arithmetic that WRAPS: `(( ACTIVE_RECORDED > 0 ))` on a wrapped-negative
# value exits the tick silently, and `(( ACTIVE == 0 ))` on a value that wraps to
# exactly zero reports `idle` for a round that is running. Both suppress the
# floor for active work, which is the failure this whole file is built to avoid.
# Nine digits allows 999,999,999 concurrent pipelines — absurd headroom, and ten
# orders of magnitude short of where wrapping starts.
COUNT_MAX_DIGITS=9
normalize_count() {
  local v="$1"
  while [[ "$v" == 0?* ]]; do v="${v#0}"; done
  (( ${#v} > COUNT_MAX_DIGITS )) && { printf ''; return 1; }
  printf '%s' "$v"
}

# POSIX single-quote a value for --arm-command. That output is shell TEXT handed
# to the Monitor tool, so an unquoted argument is interpreted, not passed: a
# script path containing a space would split into two words. The session id is
# sanitised and the repo key is validated as a plausible owner/name before it
# reaches here, so the script path is the one interpolated value that can still
# legitimately carry a space — quoting all three anyway keeps this the single
# place that has to be right. `printf %q` is avoided because it can emit
# bash-only `$'…'` forms.
shq() {
  printf "'%s'" "${1//\'/\'\\\'\'}"
}

MODE=""
ACTIVE=""
SURFACE=""
SESSION_ID="${CLAUDE_SESSION_ID:-}"
REPO_KEY=""

while (( $# > 0 )); do
  case "$1" in
    --note-rendered|--check|--tick|--arm-command|--status|--clear|--floor-seconds)
      [[ -n "$MODE" ]] && die_usage "only one mode may be given (already have --$MODE)"
      MODE="${1#--}"
      ;;
    --active)
      (( $# >= 2 )) || die_usage "--active requires a count"
      [[ "$2" =~ ^[0-9]+$ ]] || die_usage "--active must be a non-negative integer, got: $2"
      ACTIVE="$(normalize_count "$2")" \
        || die_usage "--active is too large to be a pipeline count (max $COUNT_MAX_DIGITS digits), got: $2"
      shift
      ;;
    --surface)
      (( $# >= 2 )) || die_usage "--surface requires an argument"
      SURFACE="$2"
      shift
      ;;
    # An EXPLICIT empty value is a usage error for both of these, not a request
    # to fall back. Omitting the flag legitimately defaults (session from the
    # environment, repo from --repo-key); passing `--session ""` means the
    # caller's own variable was empty — typically a shell variable that did not
    # survive a compaction or a fresh process — and silently substituting
    # `default` or the cwd repo is how the render gets written to one record
    # while the armed watch polls another. That mismatch is invisible: both
    # sides succeed, and the floor simply fires forever, or never. The two flags
    # whose whole purpose is to pin the record must refuse to guess.
    --session)
      (( $# >= 2 )) || die_usage "--session requires an argument"
      [[ -n "$2" ]] || die_usage "--session was given an empty value; omit the flag to default, or pass the real session id"
      SESSION_ID="$2"
      shift
      ;;
    --repo)
      (( $# >= 2 )) || die_usage "--repo requires an argument"
      [[ -n "$2" ]] || die_usage "--repo was given an empty value; omit the flag to resolve from the checkout, or pass the real owner/name"
      REPO_KEY="$2"
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

if [[ "$MODE" != "tick" && "${CLAUDE_SCRIPT_USAGE_LOG:-1}" != "0" && -n "${HOME:-}" ]]; then
  printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "$RAW_ARGS" \
    2>/dev/null >> "$HOME/.claude/script-usage.log" || true
fi

FLOOR_S="$(resolve_floor)"
TRIP_S=$(( FLOOR_S - FLOOR_MARGIN_S ))

if [[ "$MODE" == "floor-seconds" ]]; then
  printf '%s\n' "$FLOOR_S"
  exit 0
fi

[[ "$MODE" == "note-rendered" && -z "$ACTIVE" ]] && \
  die_usage "--note-rendered requires --active <N> (running + queued pipelines)"

# The session id has TWO destinations with different requirements, and squashing
# it once for both is what made them collide. `${id//[^[:alnum:]_.-]/_}` maps `/`
# to `_` while letting `_` through, so sessions `a/b` and `a_b` sanitise to the
# same string — and then SHARE one clock record, each render resetting the
# other's hour. That is the same collision the repo component solves with a
# checksum a few lines below; the session component simply had not been given
# the same treatment.
#
#   SESSION_ID   — raw, for the jq state path. A `/` is perfectly legal inside a
#                  jq string key, so nothing needs squashing here; only the
#                  jq-hostile characters are rejected, exactly as REPO_KEY is.
#                  For an ordinary UUID session id this is byte-identical to the
#                  old sanitised value, so existing records — including the ones
#                  /board (#1581) reads — keep their current key.
#   SESSION_SLUG — sanitised AND checksummed, for the marker FILENAME, where a
#                  `/` really would escape the directory. Same slug+checksum
#                  shape as the repo component, for the same reason.
SESSION_ID="${SESSION_ID:-default}"
if [[ ! "$SESSION_ID" =~ ^[A-Za-z0-9._/@:+-]+$ ]]; then
  die_usage "--session value contains characters that cannot be used as a state key: $SESSION_ID"
fi
SESSION_SLUG="${SESSION_ID//[^[:alnum:]_.-]/_}"
SESSION_SLUG="${SESSION_SLUG:-default}"
SESSION_SUM="$(printf '%s' "$SESSION_ID" | cksum 2>/dev/null | cut -d' ' -f1)"
[[ "$SESSION_SUM" =~ ^[0-9]+$ ]] || SESSION_SUM=""
SESSION_SLUG="${SESSION_SLUG}${SESSION_SUM:+-$SESSION_SUM}"

if [[ -z "$REPO_KEY" ]]; then
  REPO_KEY="$("$SESSION_STATE_SH" --repo-key 2>/dev/null)" || REPO_KEY=""
fi
REPO_KEY="${REPO_KEY:-_unknown}"

# REPO_KEY is interpolated into the jq path below, so it gets the SAME guard
# session-state.sh applies to its own --repo (`is_valid_repo_key`): reject
# quotes, brackets and backslashes outright rather than try to escape them —
# no legitimate owner/name contains one. Without this, a --repo value carrying
# `"` or `]` closes the path's string early and the rest is read as jq syntax:
# the write lands under a different key, or the path stops parsing and every
# freshness call fails. SESSION_ID is sanitised just above for this same reason;
# the repo key reaching the path unchecked was the gap. Rejecting (not
# squashing) is what keeps the `/` in `owner/name` intact, so the state path
# stays byte-identical to the one /board (#1581) reads.
if [[ ! "$REPO_KEY" =~ ^[A-Za-z0-9._/-]+$ ]]; then
  die_usage "--repo value is not a plausible repo key: $REPO_KEY"
fi

# Lowercase it, for the same reason session-state.sh, handoff-state.sh and
# polling-state-gate.sh do (issue #704). The validator above accepts mixed case
# because a repo key legitimately has it; the SCOPE KEY must not. `--repo
# Org/Repo` would otherwise read and write `.repos["Org/Repo"]` while every
# other consumer — including /board (#1581) sharing this exact record — resolves
# `.repos["org/repo"]`, so the render would be recorded where nothing looks and
# the tick would poll a record no render ever writes: a floor firing forever, or
# never, depending on which side you stand on. `--repo-key` already returns a
# normalized value; this covers the caller-supplied path.
NORMALIZER_LIB="${SCRIPT_DIR}/lib/repo-normalizer.sh"
if [[ -f "$NORMALIZER_LIB" ]]; then
  # shellcheck source=./lib/repo-normalizer.sh
  source "$NORMALIZER_LIB"
else
  normalize_repo_key() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
fi
REPO_KEY="$(normalize_repo_key "$REPO_KEY")"

STATE_PATH=".repos[\"${REPO_KEY}\"].table_render[\"${SESSION_ID}\"]"

# The dedupe marker is keyed by REPO **and** session, matching the durable clock
# above. Keying it by session alone would let one session watching two repos
# share a single marker: each repo's tick would overwrite the other's recorded
# timestamp, so neither would ever match on the next poll and BOTH would re-emit
# the floor line every 60 seconds — dedupe inverted into a repeater.
#
# The repo component is a readable slug PLUS a checksum of the raw key. The slug
# alone would not do: sanitising squashes `/` to `_`, and `_` is itself allowed
# through, so `org/repo` and `org_repo` collide back into one marker and
# reintroduce the repeater for the exact pair the sanitising was meant to
# separate. The slug keeps the filename greppable; the checksum makes it
# distinct. `cksum` is POSIX and needs no external hash tool; an empty result
# (no `cksum` at all) degrades to the slug alone rather than to an unkeyed marker.
REPO_SLUG="${REPO_KEY//[^[:alnum:]_.-]/_}"
REPO_SLUG="${REPO_SLUG:-_unknown}"
REPO_SUM="$(printf '%s' "$REPO_KEY" | cksum 2>/dev/null | cut -d' ' -f1)"
[[ "$REPO_SUM" =~ ^[0-9]+$ ]] || REPO_SUM=""
EMITTED_FILE="${MARKER_DIR}/claude-tablefloor-emitted-${REPO_SLUG}${REPO_SUM:+-$REPO_SUM}-${SESSION_SLUG}"

state_get() {
  local value
  value="$("$SESSION_STATE_SH" --get "${STATE_PATH}${1}" 2>/dev/null)" || return 1
  [[ "$value" == "null" ]] && return 1
  printf '%s' "$value"
}

# Age of the recorded render in seconds, floored at the trip point when the
# record is dated in the FUTURE.
#
# A future timestamp makes `now - rendered` negative, and every comparison here
# is `age >= TRIP_S`, so a negative age reads as maximally fresh: --check says
# `fresh` and --tick stays silent, suppressing the floor until the wall clock
# catches up — which for a badly skewed clock or a hand-edited record could be
# hours or never. That is the floor failing silently in the one direction it
# must not, and it fails that way for a record that is self-evidently unusable.
#
# So a negative age is treated as a TRIPPED one, not clamped to zero. This
# follows the rule the rest of the file already states — an unusable clock fails
# closed, because rendering a table that was not strictly due is harmless while
# skipping one that was is the whole failure mode. The stderr line names the
# skew so it is diagnosable rather than merely surprising.
record_age() {
  local now age
  now="$(date +%s)"
  age=$(( now - RENDERED_EPOCH ))
  if (( age < 0 )); then
    printf 'table-freshness.sh: recorded render is %ss in the FUTURE (%s) — clock skew or an edited record; treating the board as stale rather than suppressing the floor\n' \
      "$(( -age ))" "$RENDERED_AT" >&2
    printf '%s' "$TRIP_S"
    return
  fi
  printf '%s' "$age"
}

# Read the recorded render into RENDERED_AT / ACTIVE_RECORDED / SURFACE_RECORDED.
# Returns 1 when there is no usable record (missing file, absent key,
# unparseable timestamp).
#
# ONE read of the WHOLE record, not a field at a time. Each state_get is its own
# process reading the file afresh, so field-by-field reads can straddle a
# concurrent --note-rendered and combine an old timestamp with the new count —
# the two values that decide `stale` versus `idle`. Pairing a pre-render
# timestamp with a post-render `0` reports idle for a board that is an hour old;
# the reverse keeps an ended round armed. --note-rendered already writes the
# record as a single atomic --set for this reason; reading it whole is the other
# half of that guarantee. It is also strictly cheaper: one subprocess per call
# instead of two or three, on a loop that runs every 60 seconds.
read_record() {
  RENDERED_AT=""
  ACTIVE_RECORDED=""
  SURFACE_RECORDED=""
  RENDERED_EPOCH=""
  local record
  record="$(state_get '')" || return 1
  [[ -n "$record" ]] || return 1

  RENDERED_AT="$(printf '%s' "$record" | jq -r '.last_rendered_at // empty' 2>/dev/null)"
  [[ -n "$RENDERED_AT" ]] || return 1
  RENDERED_EPOCH="$(iso_to_epoch "$RENDERED_AT")"
  [[ -n "$RENDERED_EPOCH" ]] || return 1

  ACTIVE_RECORDED="$(printf '%s' "$record" | jq -r '.active_pipelines // empty' 2>/dev/null)"
  [[ "$ACTIVE_RECORDED" =~ ^[0-9]+$ ]] || ACTIVE_RECORDED=""
  # Normalised on the way in as well: this record is shared with /board (#1581)
  # and is a plain JSON file a human can edit, so a leading-zero count can reach
  # us without having passed the --active guard above.
  # An over-long persisted count is emptied, not carried through — which routes
  # it to the "no usable active_pipelines" path in --tick, so it fires with a
  # diagnostic instead of wrapping into a silent `exit 0`.
  [[ -n "$ACTIVE_RECORDED" ]] && \
    { ACTIVE_RECORDED="$(normalize_count "$ACTIVE_RECORDED")" || ACTIVE_RECORDED=""; }

  SURFACE_RECORDED="$(printf '%s' "$record" | jq -r '.surface // empty' 2>/dev/null)"
  return 0
}

case "$MODE" in
  note-rendered)
    SURFACE_VALUE="${SURFACE:-unspecified}"
    # Every write goes through session-state.sh: it holds the lock, preserves
    # siblings, and writes atomically (handoff-files.md). One atomic --set of
    # the whole record, so a reader never sees a half-updated clock.
    #
    # The timestamp is stamped as LATE as possible — immediately before the
    # record is built, not at the top of the branch — because session-state.sh
    # takes its lock inside the --set below. Two concurrent renders stamp before
    # they queue for that lock, so the one that stamped EARLIER can acquire it
    # LAST and write the older time, nudging the durable clock backward. Stamping
    # late shrinks that window to a single jq invocation. It does not close it:
    # closing it needs a read-compare-write under one lock, and the only
    # primitive for that (--cas) can exhaust its retries and FAIL the write —
    # trading a clock that is a moment stale for one that was never recorded,
    # which is the failure that silently disarms the floor. The residual skew is
    # bounded by the gap between two near-simultaneous renders and always errs
    # toward reporting the board as OLDER, so it costs at most one extra table.
    NOW_ISO="$(date -u +%FT%TZ)"
    RECORD="$(jq -nc \
      --arg at "$NOW_ISO" \
      --argjson active "$ACTIVE" \
      --arg surface "$SURFACE_VALUE" \
      '{last_rendered_at: $at, active_pipelines: $active, surface: $surface}')" || {
      printf 'table-freshness.sh: cannot build render record — clock not updated\n' >&2
      exit 5
    }
    if ! "$SESSION_STATE_SH" --set "${STATE_PATH}=${RECORD}" >/dev/null 2>&1; then
      printf 'table-freshness.sh: cannot write %s — table-render clock not updated\n' \
        "$STATE_PATH" >&2
      exit 5
    fi
    # A fresh render ends the current stale stretch, so the next genuine breach
    # is reportable again even if its timestamp somehow repeats.
    rm -f "$EMITTED_FILE" 2>/dev/null || true
    ;;

  check)
    # An explicit --active 0 is the idle exemption and outranks any stale
    # record: the round is over, the terminal board already printed.
    if [[ -n "$ACTIVE" ]] && (( ACTIVE == 0 )); then
      printf 'idle\n'
      exit 0
    fi
    if ! read_record; then
      # No usable record. With a caller-declared active round, fail closed:
      # there is no evidence any table was ever rendered, and rendering one is
      # never wrong. Without it there is nothing to measure and nothing to say.
      if [[ -n "$ACTIVE" ]]; then
        printf 'stale\n'
        exit 1
      fi
      printf 'unrecorded\n'
      exit 0
    fi
    # No --active given: fall back to the count recorded at the last render.
    EFFECTIVE_ACTIVE="${ACTIVE:-$ACTIVE_RECORDED}"
    if [[ "$EFFECTIVE_ACTIVE" =~ ^[0-9]+$ ]] && (( EFFECTIVE_ACTIVE == 0 )); then
      printf 'idle\n'
      exit 0
    fi
    AGE="$(record_age)"
    if (( AGE >= TRIP_S )); then
      printf 'stale\n'
      exit 1
    fi
    printf 'fresh\n'
    exit 0
    ;;

  tick)
    # No record means the thread has not rendered a table for this session yet.
    # There is nothing to measure from — and, critically, nothing that proves a
    # round is active, so an idle thread stays silent (the AC-4 exemption).
    read_record || exit 0
    # A count of 0 is the round-end terminal board and legitimately disarms the
    # floor. A MISSING or malformed count is a different thing entirely, and
    # treating the two alike was a silent suppression: --note-rendered always
    # writes active_pipelines (it is a required argument), so a record that has
    # a usable timestamp but no usable count has been corrupted or hand-edited.
    # Exiting quietly there withholds an overdue floor line on the strength of a
    # field that is not there to be read. Same rule as the future-dated clock
    # above: an unusable record fails CLOSED and says why. The dedupe marker
    # still bounds it to one line per stale stretch, not one per poll.
    if [[ -z "$ACTIVE_RECORDED" ]]; then
      printf 'table-freshness.sh: render record for %s has no usable active_pipelines — treating the round as active rather than suppressing the floor\n' \
        "$SESSION_ID" >&2
      ACTIVE_RECORDED_MISSING=1
    else
      ACTIVE_RECORDED_MISSING=0
      (( ACTIVE_RECORDED > 0 )) || exit 0
    fi

    AGE="$(record_age)"
    (( AGE >= TRIP_S )) || exit 0

    # Never write THROUGH a symlink, and check for one BEFORE the dedupe read
    # below rather than only before the write: `-f` follows links, so a marker
    # symlinked at a regular file would be READ for that comparison, and a target
    # whose contents happened to match would suppress the floor line outright.
    # Discarding it first makes both the read and the write see a real file.
    #
    # The default marker directory is /tmp — a
    # deliberate choice, matching bgwork-ceiling.sh, whose heartbeat file must
    # live at a hook-fixed path — and in a world-writable directory any name not
    # yet taken can be pre-created by another local process as a symlink. Without
    # this, the redirect would land an ISO timestamp in whatever that link points
    # at. The filename already carries a cksum of the repo AND session (session
    # ids are UUIDs), so guessing it is not easy; that is a cost to the attacker,
    # not a defense. Removing a non-regular file first is the defense, and it is
    # free. This does NOT reopen the marker-directory decision recorded in the PR
    # body: the fix is the same in /tmp or anywhere else.
    if [[ -L "$EMITTED_FILE" || ( -e "$EMITTED_FILE" && ! -f "$EMITTED_FILE" ) ]]; then
      printf 'table-freshness.sh: marker path %s is a symlink or non-regular file — removing it rather than writing through it\n' \
        "$EMITTED_FILE" >&2
      rm -f "$EMITTED_FILE" 2>/dev/null || true
    fi

    # Dedupe on the recorded render timestamp: one floor line per stale stretch,
    # not one per poll. When the thread re-renders, --note-rendered rewrites the
    # timestamp and clears this marker, so the next hour is reportable again.
    if [[ -f "$EMITTED_FILE" ]]; then
      emitted="$(cat "$EMITTED_FILE" 2>/dev/null)"
      [[ "$emitted" == "$RENDERED_AT" ]] && exit 0
    fi
    printf '%s' "$RENDERED_AT" > "$EMITTED_FILE" 2>/dev/null || \
      printf 'table-freshness.sh: cannot write %s — floor line may repeat\n' "$EMITTED_FILE" >&2

    # The count is printed as %s, not %d, so the unusable-count path above can
    # say "unknown" instead of forcing a fabricated number into the message.
    printf 'TABLE FLOOR: the "Running now" table is %dm old with %s pipeline(s) running or queued. Re-render the full table NOW (time-estimates.md §"Running now Table") — a one-liner does not satisfy this floor — then record it with `table-freshness.sh --note-rendered --active <N>`.\n' \
      "$(( AGE / 60 ))" \
      "$( (( ACTIVE_RECORDED_MISSING )) && printf 'an unknown number of' || printf '%d' "$ACTIVE_RECORDED" )"
    ;;

  arm-command)
    # The `--tick` substring is the sentinel that marks this command as ARMING
    # the floor rather than as new background work, mirroring bgwork-ceiling.sh.
    # Every interpolated value is single-quoted: this is shell text, and the
    # script path and repo key are the two that can legitimately carry a space.
    printf 'while true; do %s --tick --session %s --repo %s; sleep %s; done\n' \
      "$(shq "$SCRIPT_PATH")" "$(shq "$SESSION_ID")" "$(shq "$REPO_KEY")" "$FLOOR_POLL_S"
    ;;

  status)
    rendered_at="null"
    age=-1
    active_json="null"
    surface="null"
    if read_record; then
      rendered_at="$(jq -nc --arg v "$RENDERED_AT" '$v')"
      age=$(( $(date +%s) - RENDERED_EPOCH ))
      [[ -n "$ACTIVE_RECORDED" ]] && active_json="$ACTIVE_RECORDED"
      # From the SAME single read as the two fields above — a separate --get for
      # surface would reintroduce exactly the straddled-write race read_record
      # was changed to close, and report a snapshot that never existed on disk.
      [[ -n "$SURFACE_RECORDED" ]] && surface="$(jq -nc --arg v "$SURFACE_RECORDED" '$v')"
    fi
    emitted=false
    [[ -f "$EMITTED_FILE" ]] && emitted=true

    jq -nc \
      --arg session "$SESSION_ID" \
      --arg repo "$REPO_KEY" \
      --argjson last_rendered_at "$rendered_at" \
      --argjson active_pipelines "$active_json" \
      --argjson surface "$surface" \
      --argjson age_s "$age" \
      --argjson floor_s "$FLOOR_S" \
      --argjson trip_s "$TRIP_S" \
      --argjson poll_s "$FLOOR_POLL_S" \
      --argjson floor_emitted "$emitted" \
      '{session: $session, repo: $repo, last_rendered_at: $last_rendered_at,
        active_pipelines: $active_pipelines, surface: $surface, age_s: $age_s,
        floor_s: $floor_s, trip_s: $trip_s, poll_s: $poll_s,
        floor_emitted: $floor_emitted}'
    ;;

  clear)
    rm -f "$EMITTED_FILE" 2>/dev/null || true
    # Report a clear that did not clear. Swallowing this leaves a stale record
    # behind with the marker gone — the one combination that makes the floor
    # re-fire on a board nobody is looking at, and it would do so silently.
    if ! "$SESSION_STATE_SH" --set "${STATE_PATH}=null" >/dev/null 2>&1; then
      printf 'table-freshness.sh: cannot clear %s — stale render record left in place\n' \
        "$STATE_PATH" >&2
      exit 5
    fi
    ;;

  *)
    die_usage "unhandled mode: $MODE"
    ;;
esac

exit 0
