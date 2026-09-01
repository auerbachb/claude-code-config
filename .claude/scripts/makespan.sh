#!/usr/bin/env bash
# makespan.sh — Model batch makespan from per-issue estimates.
#
# PURPOSE
#   Compute the projected finish time for a batch of issues, respecting the
#   concurrency ceiling, Depends-on chain serialization, and the shared
#   CodeRabbit reviewer throughput cap (~5 reviews/hr).
#
#   Three bounds; makespan = max of all three:
#     parallel-work   = max(max(est_hi), sum(est_hi) / ceiling)
#                       [all independent issues run in parallel up to ceiling]
#     critical-chain  = sum(est_hi) along the longest Depends-on chain
#                       [serialized chains set a hard floor]
#     reviewer-thru   = n_issues x (60 / cr_rate_per_hr)
#                       [at 5 reviews/hr, N PRs take at least Nx12 min]
#
#   The binding bound is reported so it is obvious WHY adding parallelism
#   stops helping.
#
# USAGE
#   makespan.sh --json '<JSON>' [--ceiling N] [--cr-rate N] [--now ISO8601]
#   echo '<JSON>' | makespan.sh [--ceiling N] [--cr-rate N] [--now ISO8601]
#
# JSON INPUT SCHEMA
#   { "issues": [
#       { "num": 42, "est_lo": 45, "est_hi": 90, "deps": [] },
#       { "num": 55, "est_lo": 45, "est_hi": 90, "deps": [42] },
#       { "num": null, "est_lo": null, "est_hi": null, "deps": [] }
#   ] }
#
#   - est_lo / est_hi: minutes (integers); null = unestimated
#     -> unestimated issues use the Standard-tier fallback (45/90 min)
#   - deps: list of issue nums that must finish before this one starts
#
# OPTIONS
#   --ceiling N     Concurrency ceiling (default: 4; from subagent-orchestration.md)
#   --cr-rate N     CodeRabbit reviews per hour (default: 5; from cr-github-review.md)
#   --now ISO8601   Override current time for testing (default: UTC now)
#   --json '<JSON>' Provide input JSON inline rather than via stdin
#
# STDOUT (one line)
#   lo-hi h . binding: <bound> . plan on ~HH:MM AM/PM ET
#   Examples:
#     1.5-3 h . binding: parallel-work . plan on ~8:45 PM ET
#     2.5-4.5 h . binding: critical-chain . plan on ~9:30 PM ET
#     36-72 min . binding: reviewer-throughput (6 issues x 12 min/review) . plan on ~7:00 PM ET
#
# EXIT CODES
#   0  success
#   1  all issues unestimated (used Standard fallback for all)
#   2  usage error
#   4  jq missing
#
# DEPENDENCIES
#   - jq >= 1.5
#   - date (GNU or macOS)

set -euo pipefail
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" \
  2>/dev/null >> "$HOME/.claude/script-usage.log" || true

# ---------------------------------------------------------------------------
# Constants (authoritative sources cited in comments)
# ---------------------------------------------------------------------------
DEFAULT_CEILING=4   # subagent-orchestration.md: keep 3-4 active CR-polled PRs max
DEFAULT_CR_RATE=5   # cr-github-review.md Rate Limits: 5 reviews/hour per developer
# Standard-tier fallback for unestimated issues (time-estimates.md tier table)
FALLBACK_LO=45
FALLBACK_HI=90

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
INPUT_JSON=""
CEILING=$DEFAULT_CEILING
CR_RATE=$DEFAULT_CR_RATE
NOW_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --json)
      [[ $# -lt 2 ]] && { printf 'makespan.sh: --json requires an argument\n' >&2; exit 2; }
      INPUT_JSON="$2"; shift 2 ;;
    --json=*)
      INPUT_JSON="${1#--json=}"; shift ;;
    --ceiling)
      [[ $# -lt 2 ]] && { printf 'makespan.sh: --ceiling requires an argument\n' >&2; exit 2; }
      CEILING="$2"; shift 2 ;;
    --ceiling=*)
      CEILING="${1#--ceiling=}"; shift ;;
    --cr-rate)
      [[ $# -lt 2 ]] && { printf 'makespan.sh: --cr-rate requires an argument\n' >&2; exit 2; }
      CR_RATE="$2"; shift 2 ;;
    --cr-rate=*)
      CR_RATE="${1#--cr-rate=}"; shift ;;
    --now)
      [[ $# -lt 2 ]] && { printf 'makespan.sh: --now requires an argument\n' >&2; exit 2; }
      NOW_OVERRIDE="$2"; shift 2 ;;
    --help|-h)
      awk 'NR == 1 { next } /^$/ { exit } { sub(/^# ?/, ""); print }' "$0"
      exit 0 ;;
    *)
      printf 'makespan.sh: unknown argument: %s\n' "$1" >&2
      exit 2 ;;
  esac
done

# Validate ceiling and cr-rate
if ! [[ "$CEILING" =~ ^[0-9]+$ ]] || [[ "$CEILING" -lt 1 ]]; then
  printf 'makespan.sh: --ceiling must be a positive integer\n' >&2
  exit 2
fi
if ! [[ "$CR_RATE" =~ ^[0-9]+$ ]] || [[ "$CR_RATE" -lt 1 ]]; then
  printf 'makespan.sh: --cr-rate must be a positive integer\n' >&2
  exit 2
fi

# Read JSON from stdin if not provided inline
if [[ -z "$INPUT_JSON" ]]; then
  if [[ -t 0 ]]; then
    printf 'makespan.sh: provide JSON via --json or stdin\n' >&2
    exit 2
  fi
  INPUT_JSON=$(cat)
fi

# ---------------------------------------------------------------------------
# Dependency check
# ---------------------------------------------------------------------------
if ! command -v jq >/dev/null 2>&1; then
  printf 'makespan.sh: missing dependency: jq\n' >&2
  exit 4
fi

# ---------------------------------------------------------------------------
# Write jq filter to a temp file (avoids shell quoting issues with single quotes)
# ---------------------------------------------------------------------------
JQ_FILTER_FILE=$(mktemp /tmp/makespan-XXXXXX.jq)
# shellcheck disable=SC2064
trap "rm -f '$JQ_FILTER_FILE'" EXIT

# NOTE: reduce EXPR as $var (INIT; UPDATE) as $result requires parens around
# the whole reduce expression when binding the result: (reduce ...) as $result
cat > "$JQ_FILTER_FILE" << 'JQEOF'
# makespan.jq
# Args: $ceiling (int), $cr_rate (int), $fallback_lo (int), $fallback_hi (int)

.issues as $issues |
($issues | length) as $n |

# Resolve null estimates to Standard-tier fallback
($issues | map(
  .num as $num |
  .deps as $deps |
  if (.est_lo == null or .est_hi == null) then
    {num: $num, lo: $fallback_lo, hi: $fallback_hi, deps: ($deps // []), was_unestimated: true}
  else
    {num: $num, lo: .est_lo, hi: .est_hi, deps: ($deps // []), was_unestimated: false}
  end
)) as $resolved |

($resolved | map(select(.was_unestimated)) | length) as $n_unestimated |

# -----------------------------------------------------------------------
# Bound 1: parallel-work = max(max(hi), sum(hi) / ceiling)
# -----------------------------------------------------------------------
($resolved | map(.lo) | add // 0) as $sum_lo |
($resolved | map(.hi) | add // 0) as $sum_hi |
($resolved | map(.lo) | max // 0) as $max_lo |
($resolved | map(.hi) | max // 0) as $max_hi |

([$max_lo, (($sum_lo / $ceiling) | ceil)] | max) as $par_lo |
([$max_hi, (($sum_hi / $ceiling) | ceil)] | max) as $par_hi |

# -----------------------------------------------------------------------
# Bound 2: critical-chain (longest-path DP)
# cp[num] = hi(num) + max(cp[dep] for dep in deps)
# Iterate n times to propagate chains of length up to n.
# IMPORTANT: (reduce ...) must be wrapped in parens when bound with "as".
# -----------------------------------------------------------------------
($resolved | map({key: (.num | tostring), value: .hi}) | from_entries) as $cp_hi_init |
($resolved | map({key: (.num | tostring), value: .lo}) | from_entries) as $cp_lo_init |

(reduce range($n) as $_ (
  $cp_hi_init;
  . as $cp |
  reduce $resolved[] as $issue (
    $cp;
    ($issue.deps |
      map(. as $dep | ($cp[$dep | tostring] // 0)) |
      if length == 0 then 0 else max end
    ) as $max_dep |
    .[$issue.num | tostring] = ([.[$issue.num | tostring], ($issue.hi + $max_dep)] | max)
  )
)) as $cp_hi_final |

(reduce range($n) as $_ (
  $cp_lo_init;
  . as $cp |
  reduce $resolved[] as $issue (
    $cp;
    ($issue.deps |
      map(. as $dep | ($cp[$dep | tostring] // 0)) |
      if length == 0 then 0 else max end
    ) as $max_dep |
    .[$issue.num | tostring] = ([.[$issue.num | tostring], ($issue.lo + $max_dep)] | max)
  )
)) as $cp_lo_final |

($cp_hi_final | to_entries | map(.value) | max // 0) as $chain_hi |
($cp_lo_final | to_entries | map(.value) | max // 0) as $chain_lo |

# -----------------------------------------------------------------------
# Bound 3: reviewer-throughput = ceil(n * 60 / cr_rate)
# NOTE: jq division is always floating-point, so use ($n * 60 / $cr_rate) | ceil
# directly. The integer-ceiling formula ($n * 60 + $cr_rate - 1) / $cr_rate | ceil
# is WRONG for jq: when n*60 is divisible by cr_rate the pre-ceil value is
# non-integer (e.g. 304/5 = 60.8 instead of 60), so ceil overcounts by 1 minute.
# -----------------------------------------------------------------------
(($n * 60 / $cr_rate) | ceil) as $reviewer_hi |
$reviewer_hi as $reviewer_lo |

# -----------------------------------------------------------------------
# Makespan = max of all three bounds
# -----------------------------------------------------------------------
([$par_hi, $chain_hi, $reviewer_hi] | max) as $makespan_hi |
([$par_lo, $chain_lo, $reviewer_lo] | max) as $makespan_lo |

# lo cannot exceed hi
([$makespan_lo, $makespan_hi] | min) as $makespan_lo_clamped |

# Binding bound label.
# Tie-breaking priority: reviewer-throughput > critical-chain > parallel-work.
# Use strict > so a tie between chain and parallel resolves to parallel-work
# (dependencies don't exist, so "parallel-work" is the honest label).
(if ($reviewer_hi >= $par_hi and $reviewer_hi >= $chain_hi) then
  "reviewer-throughput (\($n) issue(s) x \(60 / $cr_rate | ceil) min/review at \($cr_rate)/hr)"
elif ($chain_hi > $par_hi) then
  "critical-chain"
else
  "parallel-work"
end) as $binding |

{
  makespan_lo_min: $makespan_lo_clamped,
  makespan_hi_min: $makespan_hi,
  binding: $binding,
  n_issues: $n,
  n_unestimated: $n_unestimated,
  par_hi: $par_hi,
  chain_hi: $chain_hi,
  reviewer_hi: $reviewer_hi
}
JQEOF

RESULT=$(printf '%s' "$INPUT_JSON" | jq -r \
  --argjson ceiling "$CEILING" \
  --argjson cr_rate "$CR_RATE" \
  --argjson fallback_lo "$FALLBACK_LO" \
  --argjson fallback_hi "$FALLBACK_HI" \
  -f "$JQ_FILTER_FILE")

# ---------------------------------------------------------------------------
# Extract results
# ---------------------------------------------------------------------------
MAKESPAN_HI=$(printf '%s' "$RESULT" | jq -r '.makespan_hi_min')
MAKESPAN_LO=$(printf '%s' "$RESULT" | jq -r '.makespan_lo_min')
BINDING=$(printf '%s' "$RESULT" | jq -r '.binding')
N_UNESTIMATED=$(printf '%s' "$RESULT" | jq -r '.n_unestimated')
N_ISSUES=$(printf '%s' "$RESULT" | jq -r '.n_issues')

# ---------------------------------------------------------------------------
# Format duration as human-readable string
# ---------------------------------------------------------------------------
fmt_duration() {
  local min_val="$1"
  if (( min_val < 60 )); then
    printf '%d min' "$min_val"
  else
    # Convert to tenths of hours: round to nearest 0.5h
    local tenths=$(( (min_val * 10 + 30) / 60 ))  # round to nearest 0.5h in tenths
    tenths=$(( (tenths + 4) / 5 * 5 ))             # snap to 5-tenths (=0.5h) steps
    local whole=$(( tenths / 10 ))
    local frac=$(( tenths % 10 ))
    if (( frac == 0 )); then
      printf '%d h' "$whole"
    else
      printf '%d.5 h' "$whole"
    fi
  fi
}

LO_STR=$(fmt_duration "$MAKESPAN_LO")
HI_STR=$(fmt_duration "$MAKESPAN_HI")

# ---------------------------------------------------------------------------
# Compute projected finish time in ET
# ---------------------------------------------------------------------------
if [[ -n "$NOW_OVERRIDE" ]]; then
  NOW_EPOCH=$(date -j -f '%Y-%m-%dT%H:%M:%SZ' "$NOW_OVERRIDE" '+%s' 2>/dev/null \
    || date -d "$NOW_OVERRIDE" '+%s' 2>/dev/null) \
    || { printf 'makespan.sh: invalid --now value: %s (expected ISO8601 UTC, e.g. 2026-01-01T12:00:00Z)\n' \
           "$NOW_OVERRIDE" >&2; exit 2; }
else
  NOW_EPOCH=$(date +%s)
fi

FINISH_EPOCH=$(( NOW_EPOCH + MAKESPAN_HI * 60 ))

FINISH_ET=$(TZ='America/New_York' date -j -f '%s' "$FINISH_EPOCH" +'%-I:%M %p ET' 2>/dev/null \
  || TZ='America/New_York' date -d "@$FINISH_EPOCH" +'%-I:%M %p ET' 2>/dev/null \
  || date -u -d "@$FINISH_EPOCH" +'%H:%M UTC' 2>/dev/null \
  || date -u +'%H:%M UTC')

# ---------------------------------------------------------------------------
# Build output line
# ---------------------------------------------------------------------------
if [[ "$LO_STR" == "$HI_STR" ]]; then
  RANGE_STR="$HI_STR"
else
  RANGE_STR="${LO_STR}–${HI_STR}"
fi

FALLBACK_NOTE=""
if [[ "$N_UNESTIMATED" -gt 0 ]]; then
  FALLBACK_NOTE=" (${N_UNESTIMATED} unestimated → Standard fallback)"
fi

printf '%s%s · binding: %s · plan on ~%s\n' \
  "$RANGE_STR" "$FALLBACK_NOTE" "$BINDING" "$FINISH_ET"

if [[ "$N_UNESTIMATED" -eq "$N_ISSUES" ]]; then
  exit 1
fi
exit 0
