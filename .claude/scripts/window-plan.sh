#!/usr/bin/env bash
# window-plan.sh — Parse a user-stated planning window into machine values.
#
# PURPOSE
#   Converts a human-readable planning window ("until 5:00 PM", "3 hours",
#   "overnight") into the canonical machine representation used by /pm for
#   batch fitting and by the overrun monitor.
#
# USAGE
#   window-plan.sh --window "until 5:00 PM" [--stall-margin N] [--now ISO8601]
#   window-plan.sh --window "3 hours" [--stall-margin N] [--now ISO8601]
#   window-plan.sh --window "overnight" [--stall-margin N] [--now ISO8601]
#   window-plan.sh --help
#
# OUTPUT (stdout, one line)
#   window_minutes=N stall_margin_min=M effective_window_min=K deadline_epoch=E
#
#   window_minutes      Raw window before stall margin.
#   stall_margin_min    Minutes reserved for reviewer escalation idle time
#                       (from --stall-margin or pm-config.md STALL_MARGIN_MIN;
#                       default 0; unattended default 60).
#   effective_window_min  window_minutes - stall_margin_min (floor 0).
#   deadline_epoch      Unix epoch of window end (now + window_minutes).
#
# WINDOW FORMATS ACCEPTED
#   "until H:MM AM/PM [ET]"     End clock time today in ET
#   "until H:MM"                End clock time today in ET (timezone implied)
#   "N hours" / "N hour"        Duration in whole hours
#   "N.5 hours"                 Duration with half-hour
#   "Nm" / "N min" / "N minutes"  Duration in minutes
#   "overnight"                 Long unattended run — 720 min (12 h)
#   "12-14 hours" / "12–14 h"   Range — use upper bound (14 h = 840 min)
#
# STALL MARGIN
#   For overnight or end-clock-time windows > 6 h, the unattended default
#   stall margin is 60 min (reviewer escalations can idle with nobody there).
#   Override: --stall-margin N.
#   STALL_MARGIN_MIN in pm-config.md also overrides the default.
#   An explicit --stall-margin 0 suppresses the margin.
#
# EXIT CODES
#   0  success
#   1  window would be 0 or negative (deadline already passed)
#   2  usage error (missing --window or conflicting flags)
#   3  unrecognized window format
#   4  system date error
#   70  --help header extraction produced no output (internal defect).

set -euo pipefail
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" \
  2>/dev/null >> "$HOME/.claude/script-usage.log" || true

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
WINDOW_STR=""
STALL_MARGIN_OVERRIDE=""
NOW_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --window)     shift; WINDOW_STR="${1:-}"; [[ $# -gt 0 ]] && shift ;;
    --window=*)   WINDOW_STR="${1#--window=}"; shift ;;
    --stall-margin) shift; STALL_MARGIN_OVERRIDE="${1:-}"; [[ $# -gt 0 ]] && shift ;;
    --stall-margin=*) STALL_MARGIN_OVERRIDE="${1#--stall-margin=}"; shift ;;
    --now)        shift; NOW_OVERRIDE="${1:-}"; [[ $# -gt 0 ]] && shift ;;
    --now=*)      NOW_OVERRIDE="${1#--now=}"; shift ;;
    --help|-h)
      awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; n = 1; next } { exit } END { exit(n ? 0 : 1) }' "$0" ||
        { printf '%s: --help header extraction produced no output\n' "$0" >&2; exit 70; }
      exit 0 ;;
    *) printf 'window-plan.sh: unknown flag: %s\n' "$1" >&2; exit 2 ;;
  esac
done

if [[ -z "$WINDOW_STR" ]]; then
  printf 'window-plan.sh: --window is required\n' >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Resolve current epoch
# ---------------------------------------------------------------------------
if [[ -n "$NOW_OVERRIDE" ]]; then
  NOW_EPOCH=$(TZ=UTC date -j -f '%Y-%m-%dT%H:%M:%SZ' "$NOW_OVERRIDE" '+%s' 2>/dev/null \
    || date -d "$NOW_OVERRIDE" '+%s' 2>/dev/null) \
    || { printf 'window-plan.sh: invalid --now: %s\n' "$NOW_OVERRIDE" >&2; exit 4; }
else
  NOW_EPOCH=$(date +%s)
fi

# ---------------------------------------------------------------------------
# Parse WINDOW_STR into WINDOW_MINUTES
# ---------------------------------------------------------------------------
WINDOW_MINUTES=0
IS_UNATTENDED=false

w=$(printf '%s' "$WINDOW_STR" | tr '[:upper:]' '[:lower:]')  # lowercase

if [[ "$w" == "overnight" ]]; then
  WINDOW_MINUTES=720   # 12 h default
  IS_UNATTENDED=true

elif [[ "$w" =~ ^until[[:space:]]+([0-9]+):([0-9]{2})([[:space:]]*([ap]m)?)?([[:space:]]*(et|est|edt))?$ ]]; then
  # "until H:MM AM/PM [ET]"
  HR="${BASH_REMATCH[1]}"
  MIN="${BASH_REMATCH[2]}"
  AMPM="${BASH_REMATCH[4]}"

  # Validate and convert to 24h
  HR_24=$((10#$HR))
  MIN_DEC=$((10#$MIN))
  if [[ "$MIN_DEC" -gt 59 ]]; then
    printf 'window-plan.sh: invalid minute value %s (must be 0-59)\n' "$MIN" >&2; exit 3
  fi
  if [[ -n "$AMPM" ]]; then
    if [[ "$HR_24" -lt 1 || "$HR_24" -gt 12 ]]; then
      printf 'window-plan.sh: invalid 12-hour value %s (must be 1-12 with am/pm)\n' "$HR" >&2; exit 3
    fi
    if [[ "$AMPM" == "pm" && "$HR_24" -lt 12 ]]; then
      HR_24=$(( HR_24 + 12 ))
    elif [[ "$AMPM" == "am" && "$HR_24" -eq 12 ]]; then
      HR_24=0
    fi
  else
    if [[ "$HR_24" -gt 23 ]]; then
      printf 'window-plan.sh: invalid 24-hour value %s (must be 0-23 without am/pm)\n' "$HR" >&2; exit 3
    fi
  fi

  # Compute target epoch in ET (America/New_York) — derive from NOW_EPOCH for
  # consistency when --now is provided (avoids using real wall-clock date)
  TODAY_ET=$(TZ='America/New_York' date -j -f '%s' "$NOW_EPOCH" +'%Y-%m-%d' 2>/dev/null \
    || TZ='America/New_York' date -d "@$NOW_EPOCH" +'%Y-%m-%d' 2>/dev/null) \
    || { printf 'window-plan.sh: date error computing today in ET\n' >&2; exit 4; }
  TARGET_SPEC="${TODAY_ET}T$(printf '%02d:%02d:00' "$HR_24" "$MIN_DEC")"
  TARGET_EPOCH=$(TZ='America/New_York' date -j -f '%Y-%m-%dT%H:%M:%S' "$TARGET_SPEC" '+%s' 2>/dev/null \
    || TZ='America/New_York' date -d "$TARGET_SPEC" '+%s' 2>/dev/null) \
    || { printf 'window-plan.sh: could not compute target epoch for %s\n' "$TARGET_SPEC" >&2; exit 4; }

  DIFF=$(( TARGET_EPOCH - NOW_EPOCH ))
  if (( DIFF <= 0 )); then
    # Try next-day: maybe user said "until midnight" meaning tomorrow
    printf 'window-plan.sh: window deadline already passed (%s ET) — %d s ago\n' \
      "$(TZ='America/New_York' date -j -f '%s' "$TARGET_EPOCH" +'%I:%M %p' 2>/dev/null \
         || TZ='America/New_York' date -d "@$TARGET_EPOCH" +'%I:%M %p' 2>/dev/null)" \
      "$(( -DIFF ))" >&2
    exit 1
  fi
  # Round up to nearest minute so a deadline 5 min 30 s away gives 6 min, not 5.
  WINDOW_MINUTES=$(( (DIFF + 59) / 60 ))
  # Unattended heuristic: > 6 h
  if (( WINDOW_MINUTES > 360 )); then IS_UNATTENDED=true; fi

elif [[ "$w" =~ ^([0-9]+)[[:space:]]*-[[:space:]]*([0-9]+)[[:space:]]*(h|hour|hours)$ ]] ||
     [[ "$w" =~ ^([0-9]+)[[:space:]]*–[[:space:]]*([0-9]+)[[:space:]]*(h|hour|hours)$ ]]; then
  # "12-14 hours" range — use upper bound
  UPPER="${BASH_REMATCH[2]}"
  WINDOW_MINUTES=$(( 10#$UPPER * 60 ))
  if (( WINDOW_MINUTES > 360 )); then IS_UNATTENDED=true; fi

elif [[ "$w" =~ ^([0-9]+)\.5[[:space:]]*(h|hour|hours)$ ]]; then
  # "2.5 hours"
  WHOLE="${BASH_REMATCH[1]}"
  WINDOW_MINUTES=$(( 10#$WHOLE * 60 + 30 ))
  if (( WINDOW_MINUTES > 360 )); then IS_UNATTENDED=true; fi

elif [[ "$w" =~ ^([0-9]+)[[:space:]]*(h|hour|hours)$ ]]; then
  WINDOW_MINUTES=$(( 10#${BASH_REMATCH[1]} * 60 ))
  if (( WINDOW_MINUTES > 360 )); then IS_UNATTENDED=true; fi

elif [[ "$w" =~ ^([0-9]+)[[:space:]]*(m|min|mins|minute|minutes)$ ]]; then
  WINDOW_MINUTES=$(( 10#${BASH_REMATCH[1]} ))

elif [[ "$w" =~ ^([0-9]+)m$ ]]; then
  WINDOW_MINUTES=$(( 10#${BASH_REMATCH[1]} ))

else
  printf 'window-plan.sh: unrecognized window format: %s\n' "$WINDOW_STR" >&2
  exit 3
fi

if (( WINDOW_MINUTES <= 0 )); then
  printf 'window-plan.sh: computed window is 0 or negative\n' >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Determine stall margin
# ---------------------------------------------------------------------------
DEFAULT_STALL=0
if $IS_UNATTENDED; then DEFAULT_STALL=60; fi

if [[ -n "$STALL_MARGIN_OVERRIDE" ]]; then
  if [[ ! "$STALL_MARGIN_OVERRIDE" =~ ^[0-9]+$ ]]; then
    printf 'window-plan.sh: --stall-margin must be a non-negative integer\n' >&2
    exit 2
  fi
  STALL_MARGIN_MIN=$((10#$STALL_MARGIN_OVERRIDE))
else
  # Try to read STALL_MARGIN_MIN from pm-config.md
  PM_CONFIG_GET=""
  for candidate in \
    "$HOME/.claude/skills-worktree/.claude/scripts/pm-config-get.sh" \
    "$HOME/.claude/scripts/pm-config-get.sh" \
    ".claude/scripts/pm-config-get.sh"; do
    if [[ -x "$candidate" ]]; then PM_CONFIG_GET="$candidate"; break; fi
  done

  CONFIG_MARGIN=""
  if [[ -n "$PM_CONFIG_GET" ]]; then
    RAW=$("$PM_CONFIG_GET" --section Budget 2>/dev/null || true)
    if [[ -n "$RAW" ]]; then
      # Strip comment-only lines so bootstrapped placeholder "# STALL_MARGIN_MIN: 60"
      # is not mistakenly parsed as an active setting.
      RAW_ACTIVE=$(printf '%s\n' "$RAW" | grep -v '^[[:space:]]*#' || true)
      # Look for "STALL_MARGIN_MIN: N" or "STALL_MARGIN_MIN = N"
      if [[ "$RAW_ACTIVE" =~ STALL_MARGIN_MIN[[:space:]]*[:=][[:space:]]*([0-9]+) ]]; then
        CONFIG_MARGIN="${BASH_REMATCH[1]}"
      fi
    fi
  fi

  if [[ -n "$CONFIG_MARGIN" ]]; then
    STALL_MARGIN_MIN=$((10#$CONFIG_MARGIN))
  else
    STALL_MARGIN_MIN=$DEFAULT_STALL
  fi
fi

EFFECTIVE=$(( WINDOW_MINUTES - STALL_MARGIN_MIN ))
if (( EFFECTIVE < 0 )); then EFFECTIVE=0; fi

# ---------------------------------------------------------------------------
# Compute deadline epoch
# ---------------------------------------------------------------------------
DEADLINE_EPOCH=$(( NOW_EPOCH + WINDOW_MINUTES * 60 ))

# ---------------------------------------------------------------------------
# Emit result
# ---------------------------------------------------------------------------
printf 'window_minutes=%d stall_margin_min=%d effective_window_min=%d deadline_epoch=%d\n' \
  "$WINDOW_MINUTES" "$STALL_MARGIN_MIN" "$EFFECTIVE" "$DEADLINE_EPOCH"
