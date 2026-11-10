#!/usr/bin/env bash
# Detect a CodeRabbit implementation-plan comment on a GitHub issue.
# catalog: review-escalation — Detect a substantive CodeRabbit implementation-plan comment on a GitHub issue
#
# Usage: cr-plan.sh <issue_number> [--poll <minutes>] [--max-age-minutes N]
#        cr-plan.sh --help
#
# Scans issue comments for a substantive plan from `coderabbitai` (no [bot]
# suffix — issue comments use the bare name). Filters out ack-only comments
# ("Actions performed — ..."), short/non-substantive replies, and the
# issue-enrichment / Issue-Planner-checkbox boilerplate (issue #541),
# returning the latest plan body on stdout. The substantive-plan filter
# lives in cr-plan-filter.py (same directory; requires python3).
#
# Options:
#   --poll <minutes>         Poll every 60s for up to this many minutes, returning
#                            as soon as a plan is found. Without this flag, a single
#                            check is performed.
#   --max-age-minutes N      Cap polling by issue age: stop polling once the issue
#                            is N minutes old (from createdAt). Useful for fresh-issue
#                            detection (CR typically posts within ~30s of creation).
#                            Ignored when --poll is not specified.
#
# Exit codes:
#   0  Plan found (printed to stdout)
#   1  No plan found after poll window (or on single check)
#   2  Usage error
#   3  Issue not found or closed
#   4  gh / network / environment error (incl. python3 or filter failure)
#
# See .claude/rules/issue-planning.md for the plan-merge workflow this feeds into.

set -euo pipefail
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" 2>/dev/null >> "$HOME/.claude/script-usage.log" || true

usage() {
  sed -n '3,31p' "$0" | sed 's/^# \{0,1\}//'
}

if [ "$#" -eq 0 ]; then
  usage >&2
  exit 2
fi

case "$1" in
  -h|--help)
    usage
    exit 0
    ;;
esac

ISSUE_NUMBER=""
POLL_MINUTES=0
MAX_AGE_MINUTES=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --poll)
      if [ "$#" -lt 2 ]; then
        echo "cr-plan.sh: --poll requires a value" >&2
        exit 2
      fi
      POLL_MINUTES="$2"
      shift 2
      ;;
    --max-age-minutes)
      if [ "$#" -lt 2 ]; then
        echo "cr-plan.sh: --max-age-minutes requires a value" >&2
        exit 2
      fi
      MAX_AGE_MINUTES="$2"
      shift 2
      ;;
    --)
      shift
      if [ -z "$ISSUE_NUMBER" ] && [ "$#" -gt 0 ]; then
        ISSUE_NUMBER="$1"
        shift
      fi
      ;;
    -*)
      echo "cr-plan.sh: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      if [ -n "$ISSUE_NUMBER" ]; then
        echo "cr-plan.sh: unexpected extra argument: $1" >&2
        exit 2
      fi
      ISSUE_NUMBER="$1"
      shift
      ;;
  esac
done

if [ -z "$ISSUE_NUMBER" ]; then
  echo "cr-plan.sh: issue_number is required" >&2
  usage >&2
  exit 2
fi

if ! grep -Eq '^[1-9][0-9]*$' <<<"$ISSUE_NUMBER"; then
  echo "cr-plan.sh: issue_number must be a positive integer (got: $ISSUE_NUMBER)" >&2
  exit 2
fi

if ! grep -Eq '^[0-9]+$' <<<"$POLL_MINUTES"; then
  echo "cr-plan.sh: --poll value must be a non-negative integer (got: $POLL_MINUTES)" >&2
  exit 2
fi

if ! grep -Eq '^[0-9]+$' <<<"$MAX_AGE_MINUTES"; then
  echo "cr-plan.sh: --max-age-minutes value must be a non-negative integer (got: $MAX_AGE_MINUTES)" >&2
  exit 2
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "cr-plan.sh: gh CLI not found on PATH" >&2
  exit 4
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "cr-plan.sh: python3 not found on PATH (required by cr-plan-filter.py)" >&2
  exit 4
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILTER_PY="$SCRIPT_DIR/cr-plan-filter.py"
if [ ! -f "$FILTER_PY" ]; then
  echo "cr-plan.sh: missing companion filter: $FILTER_PY" >&2
  exit 4
fi

# Fetch issue metadata once up-front so we can (a) error out cleanly on missing/
# closed issues with exit 3 and (b) compute age for --max-age-minutes. Use
# `gh --jq` for the field projection so we don't take an external `jq`
# dependency beyond what `gh` already bundles. Keep stderr separate from stdout
# so incidental gh warnings (auth refresh, deprecation notices) never
# contaminate the tab-separated output.
# Single tmpdir tracks every temp file this script creates (here + fetch_plan),
# torn down by one EXIT trap so fetch_plan's err_file can't leak if the script
# aborts mid-call.
TMPDIR_CR_PLAN=$(mktemp -d)
trap 'rm -rf "$TMPDIR_CR_PLAN"' EXIT

ISSUE_META=""
ISSUE_META_STDERR_FILE="$TMPDIR_CR_PLAN/issue-meta-stderr"
if ! ISSUE_META=$(gh issue view "$ISSUE_NUMBER" --json state,createdAt --jq '"\(.state)\t\(.createdAt)"' 2>"$ISSUE_META_STDERR_FILE"); then
  ISSUE_META_STDERR=$(cat "$ISSUE_META_STDERR_FILE")
  if grep -qi 'could not resolve\|not found\|no issue found\|HTTP 404' <<<"$ISSUE_META_STDERR"; then
    echo "cr-plan.sh: issue #$ISSUE_NUMBER not found" >&2
    exit 3
  fi
  echo "cr-plan.sh: gh error fetching issue #$ISSUE_NUMBER:" >&2
  printf '%s\n' "$ISSUE_META_STDERR" >&2
  exit 4
fi

ISSUE_STATE="${ISSUE_META%%$'\t'*}"
CREATED_AT="${ISSUE_META#*$'\t'}"
if [ "$ISSUE_STATE" != "OPEN" ]; then
  echo "cr-plan.sh: issue #$ISSUE_NUMBER is $ISSUE_STATE (expected OPEN)" >&2
  exit 3
fi

# Returns seconds since the issue was created (0 on any parse failure).
issue_age_seconds() {
  if [ -z "$CREATED_AT" ]; then
    echo 0
    return
  fi
  python3 - "$CREATED_AT" <<'PY' 2>/dev/null || echo 0
import datetime, sys
try:
    created = datetime.datetime.strptime(sys.argv[1], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
    now = datetime.datetime.now(datetime.timezone.utc)
    print(int((now - created).total_seconds()))
except Exception:
    print(0)
PY
}

# Canonical filter: latest substantive coderabbitai comment. Substance rules
# (ack skip, boilerplate stripping, length + plan-structure requirements) live
# in cr-plan-filter.py so they are unit-testable offline — `gh --jq` runs
# gojq, whose regex semantics diverge from jq/Oniguruma, making an inline jq
# filter unsafe to extend (issue #541).
fetch_plan() {
  # Single-shot lookup. Prints plan body (possibly empty) on stdout; prints
  # gh/filter error text to stderr and returns 4 on failure. gh output is
  # staged to a temp file (the ac-checkboxes.sh pattern) so a gh/network
  # failure surfaces on its own, without a knock-on parse error from the
  # filter reading a truncated stream. Keeps stderr separate from stdout so
  # incidental gh warnings never contaminate the plan body. Temp files live
  # under TMPDIR_CR_PLAN so the single EXIT trap cleans them up even if the
  # script aborts mid-call.
  local out err_file json_file
  err_file="$TMPDIR_CR_PLAN/fetch-plan-stderr"
  json_file="$TMPDIR_CR_PLAN/comments.json"
  if ! gh issue view "$ISSUE_NUMBER" --json comments >"$json_file" 2>"$err_file"; then
    echo "cr-plan.sh: gh error fetching comments for issue #$ISSUE_NUMBER:" >&2
    cat "$err_file" >&2
    return 4
  fi
  if ! out=$(python3 "$FILTER_PY" "$json_file" 2>"$err_file"); then
    echo "cr-plan.sh: cr-plan-filter.py failed for issue #$ISSUE_NUMBER:" >&2
    cat "$err_file" >&2
    return 4
  fi
  printf '%s' "$out"
}

# One-shot check (no polling).
if [ "$POLL_MINUTES" -eq 0 ]; then
  if ! PLAN=$(fetch_plan); then
    exit 4
  fi
  if [ -n "$PLAN" ]; then
    printf '%s\n' "$PLAN"
    exit 0
  fi
  exit 1
fi

# Polling loop: check immediately, then sleep 60s between checks until either
# the plan arrives, the poll window elapses, or the issue age cap is reached.
DEADLINE_SECONDS=$(( POLL_MINUTES * 60 ))
MAX_AGE_SECONDS=$(( MAX_AGE_MINUTES * 60 ))
START_EPOCH=$(date +%s)

while :; do
  if ! PLAN=$(fetch_plan); then
    exit 4
  fi
  if [ -n "$PLAN" ]; then
    printf '%s\n' "$PLAN"
    exit 0
  fi

  NOW_EPOCH=$(date +%s)
  ELAPSED=$(( NOW_EPOCH - START_EPOCH ))
  if [ "$ELAPSED" -ge "$DEADLINE_SECONDS" ]; then
    exit 1
  fi

  if [ "$MAX_AGE_SECONDS" -gt 0 ]; then
    AGE=$(issue_age_seconds)
    if [ "$AGE" -ge "$MAX_AGE_SECONDS" ]; then
      exit 1
    fi
  fi

  sleep 60
done
