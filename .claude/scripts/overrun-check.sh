#!/usr/bin/env bash
# overrun-check.sh — Per-pipeline planning-bound breach check for the monitor loop.
#
# PURPOSE
#   Called once per poll cycle per active PR pipeline. Detects when the elapsed
#   time since Phase A launch has exceeded the issue's planning bound. Emits
#   exactly one alert line on the FIRST breach (bounded exception to
#   silence-by-default). Subsequent calls for the same PR are suppressed once
#   the marker is written.
#
#   When a window deadline is provided and the revised projected finish exceeds
#   it, the alert also includes a concrete cut suggestion (one line, suggestion
#   only — never auto-drops anything).
#
# USAGE
#   overrun-check.sh --pr N --bound-min M --started-at ISO8601 \
#                    [--window-deadline EPOCH] [--window-issues "N1,N2,..."] \
#                    [--repo owner/repo] [--now ISO8601]
#   overrun-check.sh --readout [--pr N] --bound-min M --started-at ISO8601 \
#                    [--now ISO8601]
#   overrun-check.sh --readout-cells [--pr N] --bound-min M --started-at ISO8601 \
#                    [--now ISO8601]
#   overrun-check.sh --help
#
#   --pr is REQUIRED for the breach path (it keys the session-state record read
#   and written there) and OPTIONAL for --readout / --readout-cells, which are
#   pure computation over --bound-min/--started-at and never touch session
#   state. Phase A pipelines have a started_at but no PR yet, so requiring one
#   in cell mode blanked their row on every heartbeat tick. When supplied it is
#   validated in every mode.
#
# OUTPUT
#   exit 0: no breach — print nothing (breach mode) OR print readout line (readout mode)
#           OR print the tab-separated table cells (cell mode)
#   exit 1: first breach — print the alert line to stdout
#   exit 2: already alerted — print nothing (suppress)
#   exit 3: usage error (including --readout and --readout-cells together)
#   exit 4: session-state read/write error (treated as exit 0 — skip silently)
#
# READOUT MODE (--readout)
#   Computes and prints the progress readout line to stdout; always exits 0.
#   No window required, no state marker read/written. Safe to call every tick.
#   Format (from time-estimates.md §"Progress Readout Format"):
#     Est {bound} · {elapsed} elapsed · on track — likely done in ~{remaining}
#     Est {bound} · {elapsed} elapsed · running slow — revised finish ~{revised_total} total
#
# CELL MODE (--readout-cells)
#   Same inputs and same pace model as --readout, but emits the three discrete
#   values a "Running now" table row needs (time-estimates.md §"Running now
#   Table") instead of a sentence. ONE line, TAB-separated, always exits 0:
#
#     {start ET}\t{projected end ET}\t{remaining | overrun marker}
#
#   - {start ET} / {projected end ET} — ET wall-clock, `%-I:%M %p` (e.g.
#     `12:18 PM`). No "ET" suffix: the table's column headers carry the zone.
#   - CONTRACT: the FIRST cell is INDEPENDENT OF --bound-min — that argument
#     moves cells 2 and 3 only. It is not a pure function of --started-at:
#     --now still decides whether the start is in the future (in which case the
#     whole line is suppressed, see below), and the rendered zone depends on
#     whether ET resolves. /board relies on the bound-independence to format a
#     merged row's two clocks (start, delivered) without hand-rolling a `date`
#     call that would bypass the tzdata guard below (#1529), so keep cell 1
#     bound-independent.
#   - On track: projected end = start + bound; third cell = remaining duration.
#   - Over the bound: projected end = start + pace-scaled revised total, floored
#     at `--now` so it is NEVER a clock time in the past; third cell is the
#     overrun marker `+{over} over plan` (e.g. `+22 min over plan`).
#   - All three cells are always non-empty, so `cut -f1/-f2/-f3` is the consumer
#     idiom. Do NOT parse with `IFS=$'\t' read` — it collapses empty fields and
#     shifts the rest, which would silently mis-column a future format change.
#   - Prints NOTHING (still exit 0) when a timestamp will not parse or the start
#     is in the future — identical to --readout, so both modes share one
#     degradation contract and the caller renders `—`.
#
# ALERT LINE FORMAT (stdout, only on exit 1)
#   ⚠ PR #N overrun: {elapsed} h elapsed vs {bound} min plan · revised finish ~HH:MM ET
#   (when window blown): · drop #M to still land the rest by HH:MM ET
#
# SESSION-STATE MARKER
#   Writes via session-state.sh:
#     .repos["owner/repo"].prs["N"].overrun = {alerted_at: ISO8601, bound_min: M}
#   Reads it back on subsequent calls to suppress re-alerts.
#
# DEPENDENCIES
#   - session-state.sh (resolved via candidate order)
#   - jq
#   - date (BSD or GNU)

set -euo pipefail
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" \
  2>/dev/null >> "$HOME/.claude/script-usage.log" || true

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
PR_NUMBER=""
BOUND_MIN=""
STARTED_AT=""
WINDOW_DEADLINE=""      # Unix epoch
WINDOW_ISSUES=""        # comma-separated list of other PR numbers in window
REPO=""
NOW_OVERRIDE=""
READOUT_MODE=false      # --readout: print progress readout, skip breach/state logic
CELLS_MODE=false        # --readout-cells: print table cells, skip breach/state logic

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pr)               shift; PR_NUMBER="${1:-}"; [[ $# -gt 0 ]] && shift ;;
    --pr=*)             PR_NUMBER="${1#--pr=}"; shift ;;
    --bound-min)        shift; BOUND_MIN="${1:-}"; [[ $# -gt 0 ]] && shift ;;
    --bound-min=*)      BOUND_MIN="${1#--bound-min=}"; shift ;;
    --started-at)       shift; STARTED_AT="${1:-}"; [[ $# -gt 0 ]] && shift ;;
    --started-at=*)     STARTED_AT="${1#--started-at=}"; shift ;;
    --window-deadline)  shift; WINDOW_DEADLINE="${1:-}"; [[ $# -gt 0 ]] && shift ;;
    --window-deadline=*) WINDOW_DEADLINE="${1#--window-deadline=}"; shift ;;
    --window-issues)    shift; WINDOW_ISSUES="${1:-}"; [[ $# -gt 0 ]] && shift ;;
    --window-issues=*)  WINDOW_ISSUES="${1#--window-issues=}"; shift ;;
    --repo)             shift; REPO="${1:-}"; [[ $# -gt 0 ]] && shift ;;
    --repo=*)           REPO="${1#--repo=}"; shift ;;
    --now)              shift; NOW_OVERRIDE="${1:-}"; [[ $# -gt 0 ]] && shift ;;
    --now=*)            NOW_OVERRIDE="${1#--now=}"; shift ;;
    --readout)          READOUT_MODE=true; shift ;;
    --readout-cells)    CELLS_MODE=true; shift ;;
    --help|-h)
      awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; n = 1; next } { exit } END { exit(n ? 0 : 1) }' "$0" ||
        { printf '%s: --help header extraction produced no output\n' "$0" >&2; exit 70; }
      exit 0 ;;
    *) printf 'overrun-check.sh: unknown flag: %s\n' "$1" >&2; exit 3 ;;
  esac
done

if [[ "$READOUT_MODE" == "true" && "$CELLS_MODE" == "true" ]]; then
  # Refuse rather than silently picking one: the two modes emit different shapes,
  # and a caller that asked for both has a bug worth surfacing.
  printf 'overrun-check.sh: --readout and --readout-cells are mutually exclusive\n' >&2
  exit 3
fi

# --pr identifies the session-state record the breach path reads and writes, so
# it is required there. Readout and cell modes are pure computation over
# --bound-min/--started-at and exit before any session-state I/O, so requiring a
# PR there would blank the row for exactly the pipelines that need it most:
# during Phase A no PR exists yet, while started_at DOES (issue-keyed). Demanding
# one made a launch table that showed real clocks decay to em dashes on the next
# heartbeat tick. A PR number is still accepted, and still validated when given.
if [[ "$READOUT_MODE" == "true" || "$CELLS_MODE" == "true" ]]; then
  if [[ -z "$BOUND_MIN" || -z "$STARTED_AT" ]]; then
    printf 'overrun-check.sh: --bound-min and --started-at are required\n' >&2
    exit 3
  fi
elif [[ -z "$PR_NUMBER" || -z "$BOUND_MIN" || -z "$STARTED_AT" ]]; then
  printf 'overrun-check.sh: --pr, --bound-min, and --started-at are required\n' >&2
  exit 3
fi

if [[ -n "$PR_NUMBER" && ! "$PR_NUMBER" =~ ^[0-9]+$ ]]; then
  printf 'overrun-check.sh: --pr must be a positive integer\n' >&2
  exit 3
fi

if [[ ! "$BOUND_MIN" =~ ^[0-9]+$ || "$BOUND_MIN" -eq 0 ]]; then
  printf 'overrun-check.sh: --bound-min must be a positive integer\n' >&2
  exit 3
fi

# ---------------------------------------------------------------------------
# Duration formatting helper (minutes → human-readable string)
# ---------------------------------------------------------------------------
format_duration_min() {
  local min="$1"
  if (( min < 60 )); then
    printf '%d min' "$min"
  else
    # Round to nearest tenth: total_tenths = (min * 10 + 30) / 60
    local total_tenths=$(( (min * 10 + 30) / 60 ))
    local h=$(( total_tenths / 10 ))
    local tenth=$(( total_tenths % 10 ))
    if (( tenth == 0 )); then
      printf '%d h' "$h"
    else
      printf '%d.%d h' "$h" "$tenth"
    fi
  fi
}

# ---------------------------------------------------------------------------
# Does America/New_York actually resolve? (issue #1529)
#
# Exit status is NOT a reliable tell. On glibc with missing tzdata,
# `TZ='America/New_York'` does not fail — libc silently falls back to UTC and
# `date` exits 0, so a UTC time renders in 12-hour form under an "(ET)" column
# header or with an " ET" suffix: a four- or five-hour error that reads as a
# plausible clock. PR #1522's own cross-platform verification hit exactly this
# in a container with no tzdata installed.
#
# Probe the resolved OFFSET instead. Eastern is UTC-5 (EST) or UTC-4 (EDT) and
# is never +0000, so anything else means the zone did not resolve and we must
# fall through to the explicitly labelled UTC branch. Matching the two expected
# Eastern offsets rather than merely "not +0000" also catches a TZ that
# resolved to some unrelated zone.
#
# Memoised: cell mode formats two clocks and the breach path up to two more.
# ---------------------------------------------------------------------------
ET_ZONE_STATE=""   # "" = not yet probed, "yes" = resolves, "no" = fell back
et_zone_available() {
  if [[ -z "$ET_ZONE_STATE" ]]; then
    local off
    off=$(TZ='America/New_York' date +%z 2>/dev/null) || off=""
    if [[ "$off" == "-0500" || "$off" == "-0400" ]]; then
      ET_ZONE_STATE="yes"
    else
      ET_ZONE_STATE="no"
    fi
  fi
  [[ "$ET_ZONE_STATE" == "yes" ]]
}

# ---------------------------------------------------------------------------
# Explicitly labelled UTC formatter — the honest fallback for every ET site.
# GNU (`-u -d @`) then BSD (`-u -r`). The old chain carried only the GNU form,
# which was unreachable on macOS because the BSD ET branch always won; now that
# the guard above can route a macOS run here, the BSD form has to exist.
#
# GNU is tried FIRST deliberately, and the order is load-bearing: GNU `date -r`
# takes a FILE and prints its mtime, so a BSD-first chain on a GNU host prints
# the mtime of whatever file happens to be named for the epoch (a `1788402843`
# in the cwd) as if it were the clock — silently, exit 0. That is the same
# wrong-time-without-a-marker class this script exists to eliminate (#1529), so
# it cannot ride in the fallback that is supposed to be the honest one.
# Measured both ways: GNU always satisfies `-d @`, so it never reaches `-r`;
# BSD rejects `-d` with "illegal option" (status 1, zero bytes on stdout), so it
# falls through to `-r` unchanged. Pinned by overrun-check-tzdata.test.sh.
# ---------------------------------------------------------------------------
format_utc_clock() {
  local epoch="$1"
  date -u -d "@$epoch" +'%H:%M UTC' 2>/dev/null \
    || date -u -r "$epoch" +'%H:%M UTC' 2>/dev/null \
    || printf '(unknown)'
}

# ---------------------------------------------------------------------------
# ET wall-clock formatter (epoch -> "12:18 PM"), same BSD-then-GNU fallback
# chain the breach alert uses below, now behind the resolve guard.
#
# $2 is an optional suffix: cell mode passes none (its column headers carry the
# zone), the breach alert passes " ET". One formatter for all three sites, so
# the guard lives in exactly one place.
#
# Never returns empty: a blank cell means "not started" in the table, so a
# formatting failure must be visible as "(unknown)" rather than mimic it. The
# self-labelling UTC branch is preserved deliberately — the CodeAnt finding
# declined in PR #1522 targeted that branch, which is honest; the silent case
# was the ET branch being reached without checking that ET had resolved.
# ---------------------------------------------------------------------------
format_et_clock() {
  local epoch="$1" suffix="${2:-}"
  if et_zone_available; then
    TZ='America/New_York' date -j -f '%s' "$epoch" +"%-I:%M %p${suffix}" 2>/dev/null \
      || TZ='America/New_York' date -d "@$epoch" +"%-I:%M %p${suffix}" 2>/dev/null \
      || format_utc_clock "$epoch"
  else
    format_utc_clock "$epoch"
  fi
}

# ---------------------------------------------------------------------------
# Readout / cell mode — compute and print the progress readout or the table
# cells; skip breach/state. Defined early so both re-use the epoch/elapsed
# helpers below and exit before any session-state I/O.
# ---------------------------------------------------------------------------
if [[ "$READOUT_MODE" == "true" || "$CELLS_MODE" == "true" ]]; then
  # Compute NOW_EPOCH
  if [[ -n "$NOW_OVERRIDE" ]]; then
    READOUT_NOW=$(TZ=UTC date -j -f '%Y-%m-%dT%H:%M:%SZ' "$NOW_OVERRIDE" '+%s' 2>/dev/null \
      || date -d "$NOW_OVERRIDE" '+%s' 2>/dev/null) || { exit 0; }
  else
    READOUT_NOW=$(date +%s)
  fi
  # Parse STARTED_AT
  READOUT_START=$(TZ=UTC date -j -f '%Y-%m-%dT%H:%M:%SZ' "$STARTED_AT" '+%s' 2>/dev/null \
    || date -d "$STARTED_AT" '+%s' 2>/dev/null) || { exit 0; }
  READOUT_ELAPSED_SECS=$(( READOUT_NOW - READOUT_START ))
  READOUT_ELAPSED=$(( READOUT_ELAPSED_SECS / 60 ))
  # Clamp to 0 — future start timestamps produce negative elapsed; skip silently.
  (( READOUT_ELAPSED_SECS < 0 )) && exit 0

  if [[ "$CELLS_MODE" == "true" ]]; then
    CELL_START=$(format_et_clock "$READOUT_START")
    if (( READOUT_ELAPSED_SECS <= BOUND_MIN * 60 )); then
      # On track: the plan still holds, so the finish clock is start + bound.
      CELL_END=$(format_et_clock "$(( READOUT_START + BOUND_MIN * 60 ))")
      CELL_REMAINING=$(format_duration_min "$(( (BOUND_MIN * 60 - READOUT_ELAPSED_SECS) / 60 ))")
    else
      # Over the bound: same pace-scaled revised total as --readout's running-slow
      # branch. Floor the projected finish at NOW: truncating the revised total to
      # whole minutes can land a hair behind the clock in the first seconds past
      # the bound, and the table must never show an ETA in the past.
      REVISED=$(( READOUT_ELAPSED_SECS * READOUT_ELAPSED_SECS / (BOUND_MIN * 60) / 60 ))
      PROJECTED_EPOCH=$(( READOUT_START + REVISED * 60 ))
      (( PROJECTED_EPOCH < READOUT_NOW )) && PROJECTED_EPOCH="$READOUT_NOW"
      CELL_END=$(format_et_clock "$PROJECTED_EPOCH")
      # Excess is truncated to whole minutes, so the first 59 s past the bound
      # would render "+0 min over plan" — a row that reads as on-plan while
      # sitting in the overrun branch. Same sub-minute boundary the --readout
      # branch below guards; say "<1 min" rather than round a real overrun to 0.
      CELL_OVER_SECS=$(( READOUT_ELAPSED_SECS - BOUND_MIN * 60 ))
      if (( CELL_OVER_SECS < 60 )); then
        CELL_REMAINING="+<1 min over plan"
      else
        CELL_REMAINING="+$(format_duration_min "$(( CELL_OVER_SECS / 60 ))") over plan"
      fi
    fi
    printf '%s\t%s\t%s\n' "$CELL_START" "$CELL_END" "$CELL_REMAINING"
    exit 0
  fi

  BOUND_STR=$(format_duration_min "$BOUND_MIN")
  ELAPSED_STR=$(format_duration_min "$READOUT_ELAPSED")

  # Compare in seconds so a task up to 59 s over its bound is not misreported.
  if (( READOUT_ELAPSED_SECS <= BOUND_MIN * 60 )); then
    REMAINING=$(( (BOUND_MIN * 60 - READOUT_ELAPSED_SECS) / 60 ))
    REMAINING_STR=$(format_duration_min "$REMAINING")
    printf 'Est %s · %s elapsed · on track — likely done in ~%s\n' \
      "$BOUND_STR" "$ELAPSED_STR" "$REMAINING_STR"
  else
    # Pace-scaled revised total: compute in seconds for precision, then convert to minutes.
    # Using truncated-minute READOUT_ELAPSED would produce a contradictory readout when
    # elapsed exceeds the bound by less than one minute (e.g. "running slow — ~90 min total"
    # when the bound IS 90 min and elapsed is 90m30s).
    REVISED=$(( READOUT_ELAPSED_SECS * READOUT_ELAPSED_SECS / (BOUND_MIN * 60) / 60 ))
    REVISED_STR=$(format_duration_min "$REVISED")
    printf 'Est %s · %s elapsed · running slow — revised finish ~%s total\n' \
      "$BOUND_STR" "$ELAPSED_STR" "$REVISED_STR"
  fi
  exit 0
fi

# ---------------------------------------------------------------------------
# Resolve session-state.sh
# ---------------------------------------------------------------------------
SESSION_STATE_SH=""
for candidate in \
  "$HOME/.claude/skills-worktree/.claude/scripts/session-state.sh" \
  "$HOME/.claude/scripts/session-state.sh" \
  ".claude/scripts/session-state.sh"; do
  if [[ -x "$candidate" ]]; then SESSION_STATE_SH="$candidate"; break; fi
done

if [[ -z "$SESSION_STATE_SH" ]]; then
  # Without session-state, cannot track first-breach — skip silently
  exit 0
fi

# Build repo-scoped args. Every expansion below uses ${ARR[@]+"${ARR[@]}"}: under
# `set -u`, a bare "${REPO_ARGS[@]}" on an EMPTY array aborts on macOS bash 3.2
# (and bash 4.0-4.3), i.e. on every invocation that omits --repo (issue #1371).
REPO_ARGS=()
if [[ -n "$REPO" ]]; then
  REPO_ARGS=(--repo "$REPO")
fi

# ---------------------------------------------------------------------------
# Current epoch
# ---------------------------------------------------------------------------
if [[ -n "$NOW_OVERRIDE" ]]; then
  NOW_EPOCH=$(TZ=UTC date -j -f '%Y-%m-%dT%H:%M:%SZ' "$NOW_OVERRIDE" '+%s' 2>/dev/null \
    || date -d "$NOW_OVERRIDE" '+%s' 2>/dev/null) \
    || { exit 0; }  # date error — skip silently
else
  NOW_EPOCH=$(date +%s)
fi

# ---------------------------------------------------------------------------
# Parse STARTED_AT to epoch
# ---------------------------------------------------------------------------
STARTED_EPOCH=$(TZ=UTC date -j -f '%Y-%m-%dT%H:%M:%SZ' "$STARTED_AT" '+%s' 2>/dev/null \
  || date -d "$STARTED_AT" '+%s' 2>/dev/null) \
  || { exit 0; }  # parse error — skip silently

ELAPSED_MIN=$(( (NOW_EPOCH - STARTED_EPOCH) / 60 ))

# ---------------------------------------------------------------------------
# Check for breach
# ---------------------------------------------------------------------------
if (( ELAPSED_MIN <= BOUND_MIN )); then
  # No breach
  exit 0
fi

# ---------------------------------------------------------------------------
# Breach detected — check if already alerted
# ---------------------------------------------------------------------------
REPO_KEY=""
if [[ -n "$REPO" ]]; then
  REPO_KEY=$(printf '%s' "$REPO" | tr '[:upper:]' '[:lower:]')
else
  REPO_KEY=$("$SESSION_STATE_SH" --repo-key 2>/dev/null) || REPO_KEY=""
fi

ALREADY_ALERTED=false
STATE_READABLE=true
if [[ -n "$REPO_KEY" ]]; then
  READ_RC=0
  MARKER=$("$SESSION_STATE_SH" ${REPO_ARGS[@]+"${REPO_ARGS[@]}"} \
    --get ".repos[\"$REPO_KEY\"].prs[\"$PR_NUMBER\"].overrun.alerted_at" 2>/dev/null) \
    || READ_RC=$?
  if [[ "$READ_RC" -eq 0 && -n "$MARKER" && "$MARKER" != "null" ]]; then
    ALREADY_ALERTED=true
  elif [[ "$READ_RC" -ne 0 && "$READ_RC" -ne 3 ]]; then
    # Read failed (rc=3 = no state file yet, treat as unalerted); other failures
    # mean we cannot guarantee first-breach-only semantics — skip silently.
    STATE_READABLE=false
  fi
else
  # No repo key — cannot track state; skip silently to avoid untracked alerts.
  STATE_READABLE=false
fi

if $ALREADY_ALERTED; then
  exit 2
fi

if ! $STATE_READABLE; then
  exit 0
fi

# ---------------------------------------------------------------------------
# First breach — compute alert components
# ---------------------------------------------------------------------------
ELAPSED_H_WHOLE=$(( ELAPSED_MIN / 60 ))
ELAPSED_H_FRAC=$(( (ELAPSED_MIN % 60) * 10 / 60 ))  # tenths

if (( ELAPSED_H_FRAC == 0 )); then
  ELAPSED_STR="${ELAPSED_H_WHOLE} h"
elif (( ELAPSED_H_WHOLE == 0 )); then
  ELAPSED_STR="${ELAPSED_MIN} min"
else
  ELAPSED_STR="${ELAPSED_H_WHOLE}.${ELAPSED_H_FRAC} h"
fi

# Revised finish: now + (bound_min - elapsed_min) remaining ... but since we
# already exceeded the bound, estimate remaining work as 0 and project that
# the pipeline finishes at NOW + a small typical review completion (30 min).
# Actually the issue asks for a "revised batch finish" — which means we project
# when the *current pipeline* will finish. The planning bound is already
# expired, so we use the elapsed ratio to estimate remaining time:
# revised_remaining = bound_min * (bound_min / elapsed_min)  -- not great
# Better: since we're past the bound, revised finish is "now + typical phase
# completion" (30 min), or if we just report "now + 0" that's the floor.
# The simplest honest estimate is: the pipeline is overrunning; revised finish ≈ now + 30 min.
REVISED_EXTRA_MIN=30  # conservative: assume ~30 min more to complete
REVISED_FINISH_EPOCH=$(( NOW_EPOCH + REVISED_EXTRA_MIN * 60 ))

# " ET" is spelled into the alert text, so the resolve guard matters most here:
# without it a no-tzdata host prints a UTC clock labelled "ET" (issue #1529).
REVISED_FINISH_ET=$(format_et_clock "$REVISED_FINISH_EPOCH" ' ET')

ALERT_LINE="⚠ PR #${PR_NUMBER} overrun: ${ELAPSED_STR} elapsed vs ${BOUND_MIN} min plan · revised finish ~${REVISED_FINISH_ET}"

# ---------------------------------------------------------------------------
# Window blown? Add cut suggestion
# ---------------------------------------------------------------------------
CUT_LINE=""
if [[ -n "$WINDOW_DEADLINE" && "$WINDOW_DEADLINE" =~ ^[0-9]+$ ]]; then
  if (( REVISED_FINISH_EPOCH > WINDOW_DEADLINE )); then
    # Same guard; this site also gains the labelled-UTC branch it never had.
    # Its distinct "(window end)" sentinel is preserved for the total-failure
    # case, so the cut suggestion's wording is unchanged.
    WINDOW_END_ET=$(format_et_clock "$WINDOW_DEADLINE" ' ET')
    [[ "$WINDOW_END_ET" == "(unknown)" ]] && WINDOW_END_ET='(window end)'

    # Build cut suggestion: name the overrunning PR as the candidate to drop
    if [[ -n "$WINDOW_ISSUES" ]]; then
      CUT_LINE=" · drop #${PR_NUMBER} to still land the rest by ${WINDOW_END_ET}"
    else
      CUT_LINE=" · window blown (${WINDOW_END_ET}) — consider dropping PR #${PR_NUMBER}"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Atomically claim the first-breach marker via CAS (null → value).
# This prevents two concurrent checks from both observing no marker and
# both emitting an alert (TOCTOU). Only the winner of the CAS emits.
# ---------------------------------------------------------------------------
# Guard: REPO_KEY must be present (STATE_READABLE guarantees this, but make it
# explicit at the write site so the marker block is self-contained).
if [[ -z "$REPO_KEY" ]]; then exit 0; fi
NOW_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)
MARKER_JSON="{\"alerted_at\":\"${NOW_ISO}\",\"bound_min\":${BOUND_MIN}}"
CAS_RC=0
"$SESSION_STATE_SH" ${REPO_ARGS[@]+"${REPO_ARGS[@]}"} \
  --cas ".repos[\"$REPO_KEY\"].prs[\"$PR_NUMBER\"].overrun=${MARKER_JSON}" \
  --expect null \
  2>/dev/null || CAS_RC=$?
if [[ "$CAS_RC" -eq 7 ]]; then
  # CAS loss — another concurrent check already claimed the marker; treat as
  # already alerted so we do not double-emit.
  exit 2
fi
if [[ "$CAS_RC" -ne 0 ]]; then
  # I/O or lock failure — first-breach-only semantics cannot be guaranteed;
  # skip silently rather than risk a repeated alert on the next tick.
  exit 0
fi

# ---------------------------------------------------------------------------
# Emit the alert line and exit 1 (first breach)
# ---------------------------------------------------------------------------
printf '%s%s\n' "$ALERT_LINE" "$CUT_LINE"
exit 1
