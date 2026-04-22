#!/usr/bin/env bash
# off-peak-minute.sh — Deterministic per-repo off-peak cron minute selector.
#
# PURPOSE
#   Centralizes the minute-selection contract used by `/pm` Step 2.3 when
#   scheduling CronCreate polling jobs. Each repo gets a stable minute in
#   [0, 59] derived from its `owner/name` string, then nudged off the
#   fleet pile-up minutes (0, 5, 30, 55) where every agent's schedule
#   collides on the API. Deterministic so the same repo always lands on
#   the same minute; spread so different repos fan out across the hour.
#
#   With --every-n-min N the script also emits a cron-friendly step-range
#   string like "7-59/10". The base minute is first reduced to its ones-
#   digit (MINUTE % N) because cron's `A-59/N` form truncates whenever
#   A > N-1 — e.g. `47-59/10` would fire only at :47 and :57, missing the
#   other expected slots. After reduction the value is re-nudged off 0/5
#   to preserve the anti-pile-up guarantee. See memory note
#   `feedback_cron_step_range_truncation.md`.
#
# USAGE
#   off-peak-minute.sh [--repo <owner/name>] [--every-n-min N]
#   off-peak-minute.sh --help | -h
#
#   --repo <owner/name>   Repo identifier. Defaults to the output of
#                         `gh repo view --json nameWithOwner --jq .nameWithOwner`
#                         (the current working directory's repo).
#   --every-n-min N       Positive integer 1..59. When set, emits a
#                         cron-friendly step-range in addition to the
#                         chosen minute.
#
# OUTPUT
#   Without --every-n-min:
#     stdout line 1: MINUTE (0-59), the hashed + nudged base minute.
#
#   With --every-n-min N:
#     stdout line 1: MINUTE (0 .. N-1), the reduced + re-nudged minute.
#     stdout line 2: cron step-range "MINUTE-59/N" (e.g. "7-59/10").
#
# EXIT STATUS
#   0  OK (value printed on stdout)
#   2  Usage error (missing value, unknown flag, non-numeric N, or
#      --every-n-min outside [1, 59])
#
# EXAMPLES
#   # Hourly cron — stable per-repo minute, 7 days a week.
#   MINUTE=$(off-peak-minute.sh --repo auerbachb/claude-code-config)
#   echo "cron: \"$MINUTE * * * *\""
#
#   # Every-10-min cron — capture both lines.
#   { read -r MINUTE; read -r RANGE; } < <(off-peak-minute.sh --repo foo/bar --every-n-min 10)
#   echo "cron: \"$RANGE * * * *\"   # fires at :$MINUTE, :$(($MINUTE+10)), ..."

set -euo pipefail

print_help() {
  # Print the header comment block (from shebang's next line until the first
  # blank comment line). Matches the pattern used by hhg-state.sh /
  # reply-thread.sh: skip line 1 (shebang), strip leading "# " or "#", stop
  # at the first blank line.
  awk 'NR == 1 { next } /^$/ { exit } { sub(/^# ?/, ""); print }' "$0"
}

usage_error() {
  local msg="$1"
  echo "off-peak-minute.sh: $msg" >&2
  echo "Run with --help for usage." >&2
  exit 2
}

# Nudge MINUTE off the fleet pile-up minutes 0, 5, 30, 55 by adding 2
# (mod 60). The +2 pattern is the same one used historically inline in
# `/pm` Step 2.3 — kept for compatibility with any existing crons whose
# minutes were computed that way.
nudge_pileup() {
  local m="$1"
  case "$m" in
    0|5|30|55) m=$(( (m + 2) % 60 )) ;;
  esac
  printf '%s' "$m"
}

# --- arg parsing ---
REPO=""
EVERY_N=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      print_help
      exit 0
      ;;
    --repo)
      [[ $# -ge 2 ]] || usage_error "--repo requires a value"
      [[ -n "$2" ]] || usage_error "--repo value cannot be empty"
      REPO="$2"
      shift 2
      ;;
    --repo=*)
      REPO="${1#--repo=}"
      [[ -n "$REPO" ]] || usage_error "--repo value cannot be empty"
      shift
      ;;
    --every-n-min)
      [[ $# -ge 2 ]] || usage_error "--every-n-min requires a value"
      EVERY_N="$2"
      shift 2
      ;;
    --every-n-min=*)
      EVERY_N="${1#--every-n-min=}"
      shift
      ;;
    --)
      shift
      break
      ;;
    -*)
      usage_error "unknown flag: $1"
      ;;
    *)
      usage_error "unexpected positional argument: $1"
      ;;
  esac
done

if [[ $# -gt 0 ]]; then
  usage_error "unexpected positional argument: $1"
fi

# Validate --every-n-min as integer in [1, 59]. Regex first so "10abc" or
# " 10" don't slip through arithmetic coercion. Then force decimal base
# via `10#` so a leading-zero input like "08" or "09" doesn't crash the
# arithmetic context as invalid octal (`08: value too great for base`).
if [[ -n "$EVERY_N" ]]; then
  if ! [[ "$EVERY_N" =~ ^[0-9]+$ ]]; then
    usage_error "--every-n-min must be a positive integer (got: $EVERY_N)"
  fi
  EVERY_N=$((10#$EVERY_N))
  if (( EVERY_N < 1 || EVERY_N > 59 )); then
    usage_error "--every-n-min must be in [1, 59] (got: $EVERY_N)"
  fi
fi

# --- resolve repo ---
if [[ -z "$REPO" ]]; then
  if ! REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null); then
    usage_error "--repo not set and gh repo view failed (are you inside a GitHub repo?)"
  fi
  if [[ -z "$REPO" ]]; then
    usage_error "--repo not set and gh repo view returned empty output"
  fi
fi

# --- hash repo name → minute ∈ [0, 59] ---
# `cksum` output is "<crc> <size> [<file>]"; take the first field.
MINUTE=$(printf '%s' "$REPO" | cksum | awk '{print $1 % 60}')
MINUTE=$(nudge_pileup "$MINUTE")

# --- hourly mode: single-line output ---
if [[ -z "$EVERY_N" ]]; then
  printf '%s\n' "$MINUTE"
  exit 0
fi

# --- every-N-min mode: reduce ones-digit, re-nudge, emit range ---
# Cron's `A-59/N` range truncates silently when A > N-1 (e.g. 47-59/10 only
# fires at :47 and :57). Reducing MINUTE mod N keeps the full /N cadence.
# The reduced value may itself land on a pile-up minute (0/5/30/55), and
# the nudge (+2 mod 60) may push back over N-1 for small N, so we iterate
# a bounded "nudge then clamp" loop. Two passes suffice for all N ∈ [1,59]:
#   - N ≥ 6:  converges in 1-2 passes to a non-pile-up value < N.
#   - N ≤ 5:  stabilizes within [0, N-1] but may land back on a pile-up
#             minute (notably 0 when N=2) — unavoidable since the
#             non-pile-up nudge targets (2, 7, 32, 57) exceed N-1 and clamp
#             back via mod N. The exact stabilized set depends on
#             MINUTE % N: N=2 → {0, 1}; N=3 → {1, 2}; N=4 → {1, 2, 3};
#             N=5 → {1, 2, 3, 4}. Small-N pile-ups are accepted rather
#             than worked around — the deterministic spread across repos
#             still dominates the collision risk.
M_REDUCED=$(( MINUTE % EVERY_N ))
for _ in 1 2; do
  M_REDUCED=$(nudge_pileup "$M_REDUCED")
  M_REDUCED=$(( M_REDUCED % EVERY_N ))
done

printf '%s\n' "$M_REDUCED"
printf '%s-59/%s\n' "$M_REDUCED" "$EVERY_N"
exit 0
