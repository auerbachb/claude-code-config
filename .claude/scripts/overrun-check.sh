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
#   overrun-check.sh --readout --pr N --bound-min M --started-at ISO8601 \
#                    [--now ISO8601]
#   overrun-check.sh --help
#
# OUTPUT
#   exit 0: no breach — print nothing (breach mode) OR print readout line (readout mode)
#   exit 1: first breach — print the alert line to stdout
#   exit 2: already alerted — print nothing (suppress)
#   exit 3: usage error
#   exit 4: session-state read/write error (treated as exit 0 — skip silently)
#
# READOUT MODE (--readout)
#   Computes and prints the progress readout line to stdout; always exits 0.
#   No window required, no state marker read/written. Safe to call every tick.
#   Format (from time-estimates.md §"Progress Readout Format"):
#     Est {bound} · {elapsed} elapsed · on track — likely done in ~{remaining}
#     Est {bound} · {elapsed} elapsed · running slow — revised finish ~{revised_total} total
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
  >> "$HOME/.claude/script-usage.log" 2>/dev/null || true

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
    --help|-h)
      sed -n '2,/^set -/{ /^#/{ s/^# \{0,1\}//; p }; /^set -/q }' "$0"
      exit 0 ;;
    *) printf 'overrun-check.sh: unknown flag: %s\n' "$1" >&2; exit 3 ;;
  esac
done

if [[ -z "$PR_NUMBER" || -z "$BOUND_MIN" || -z "$STARTED_AT" ]]; then
  printf 'overrun-check.sh: --pr, --bound-min, and --started-at are required\n' >&2
  exit 3
fi

if [[ ! "$PR_NUMBER" =~ ^[0-9]+$ ]]; then
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
# Readout mode — compute and print the progress readout; skip breach/state.
# Defined early so it can re-use the epoch/elapsed helpers below and exit
# before any session-state I/O.
# ---------------------------------------------------------------------------
if [[ "$READOUT_MODE" == "true" ]]; then
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

  BOUND_STR=$(format_duration_min "$BOUND_MIN")
  ELAPSED_STR=$(format_duration_min "$READOUT_ELAPSED")

  # Compare in seconds so a task up to 59 s over its bound is not misreported.
  if (( READOUT_ELAPSED_SECS <= BOUND_MIN * 60 )); then
    REMAINING=$(( (BOUND_MIN * 60 - READOUT_ELAPSED_SECS) / 60 ))
    REMAINING_STR=$(format_duration_min "$REMAINING")
    printf 'Est %s · %s elapsed · on track — likely done in ~%s\n' \
      "$BOUND_STR" "$ELAPSED_STR" "$REMAINING_STR"
  else
    # Pace-scaled revised total: elapsed × (elapsed / bound), integer arithmetic
    REVISED=$(( READOUT_ELAPSED * READOUT_ELAPSED / BOUND_MIN ))
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

# Build repo-scoped args
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
  MARKER=$("$SESSION_STATE_SH" "${REPO_ARGS[@]}" \
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

REVISED_FINISH_ET=$(TZ='America/New_York' date -j -f '%s' "$REVISED_FINISH_EPOCH" +'%-I:%M %p ET' 2>/dev/null \
  || TZ='America/New_York' date -d "@$REVISED_FINISH_EPOCH" +'%-I:%M %p ET' 2>/dev/null \
  || date -u -d "@$REVISED_FINISH_EPOCH" +'%H:%M UTC' 2>/dev/null \
  || printf '(unknown)')

ALERT_LINE="⚠ PR #${PR_NUMBER} overrun: ${ELAPSED_STR} elapsed vs ${BOUND_MIN} min plan · revised finish ~${REVISED_FINISH_ET}"

# ---------------------------------------------------------------------------
# Window blown? Add cut suggestion
# ---------------------------------------------------------------------------
CUT_LINE=""
if [[ -n "$WINDOW_DEADLINE" && "$WINDOW_DEADLINE" =~ ^[0-9]+$ ]]; then
  if (( REVISED_FINISH_EPOCH > WINDOW_DEADLINE )); then
    WINDOW_END_ET=$(TZ='America/New_York' date -j -f '%s' "$WINDOW_DEADLINE" +'%-I:%M %p ET' 2>/dev/null \
      || TZ='America/New_York' date -d "@$WINDOW_DEADLINE" +'%-I:%M %p ET' 2>/dev/null \
      || printf '(window end)')

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
"$SESSION_STATE_SH" "${REPO_ARGS[@]}" \
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
