#!/usr/bin/env bash
# Detect a CodeRabbit implementation-plan comment on a GitHub issue.
#
# Usage: cr-plan.sh <issue_number> [--poll <minutes>] [--max-age-minutes N]
#        cr-plan.sh --help
#
# Scans issue comments for a substantive plan from `coderabbitai` (no [bot]
# suffix — issue comments use the bare name). Filters out ack-only comments
# ("Actions performed — ...") and short/non-substantive replies, returning
# the latest plan body on stdout.
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
#   4  gh / network error
#
# See .claude/rules/issue-planning.md for the plan-merge workflow this feeds into.

set -euo pipefail

usage() {
  sed -n '3,29p' "$0" | sed 's/^# \{0,1\}//'
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

if ! printf '%s' "$ISSUE_NUMBER" | grep -Eq '^[1-9][0-9]*$'; then
  echo "cr-plan.sh: issue_number must be a positive integer (got: $ISSUE_NUMBER)" >&2
  exit 2
fi

if ! printf '%s' "$POLL_MINUTES" | grep -Eq '^[0-9]+$'; then
  echo "cr-plan.sh: --poll value must be a non-negative integer (got: $POLL_MINUTES)" >&2
  exit 2
fi

if ! printf '%s' "$MAX_AGE_MINUTES" | grep -Eq '^[0-9]+$'; then
  echo "cr-plan.sh: --max-age-minutes value must be a non-negative integer (got: $MAX_AGE_MINUTES)" >&2
  exit 2
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "cr-plan.sh: gh CLI not found on PATH" >&2
  exit 4
fi

# Fetch issue metadata once up-front so we can (a) error out cleanly on missing/
# closed issues with exit 3 and (b) compute age for --max-age-minutes.
# Keep stderr separate from stdout so incidental gh warnings (auth refresh,
# deprecation notices) never contaminate the JSON we pipe to jq.
ISSUE_META_JSON=""
ISSUE_META_STDERR=""
ISSUE_META_STDERR_FILE=$(mktemp)
trap 'rm -f "$ISSUE_META_STDERR_FILE"' EXIT
if ! ISSUE_META_JSON=$(gh issue view "$ISSUE_NUMBER" --json number,state,createdAt 2>"$ISSUE_META_STDERR_FILE"); then
  ISSUE_META_STDERR=$(cat "$ISSUE_META_STDERR_FILE")
  if printf '%s' "$ISSUE_META_STDERR" | grep -qi 'could not resolve\|not found\|no issue found\|HTTP 404'; then
    echo "cr-plan.sh: issue #$ISSUE_NUMBER not found" >&2
    exit 3
  fi
  echo "cr-plan.sh: gh error fetching issue #$ISSUE_NUMBER:" >&2
  printf '%s\n' "$ISSUE_META_STDERR" >&2
  exit 4
fi

ISSUE_STATE=$(printf '%s' "$ISSUE_META_JSON" | jq -r '.state // ""')
if [ "$ISSUE_STATE" != "OPEN" ]; then
  echo "cr-plan.sh: issue #$ISSUE_NUMBER is $ISSUE_STATE (expected OPEN)" >&2
  exit 3
fi

CREATED_AT=$(printf '%s' "$ISSUE_META_JSON" | jq -r '.createdAt // ""')

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

# Canonical filter: latest substantive coderabbitai comment, skipping ack lines
# ("Actions performed — ...") and anything under 200 characters.
CR_PLAN_JQ='[.comments[]
  | select(.author.login == "coderabbitai")
  | .body
  | select((test("(?i)^\\s*actions performed\\b") | not))
  | select(length > 200)
] | last // empty'

fetch_plan() {
  # Single-shot lookup. Prints plan body (possibly empty) on stdout; prints gh
  # error text to stderr and returns 4 on API failure. Keeps stderr separate
  # from stdout so incidental gh warnings never contaminate the plan body.
  local out err err_file
  err_file=$(mktemp)
  if ! out=$(gh issue view "$ISSUE_NUMBER" --json comments --jq "$CR_PLAN_JQ" 2>"$err_file"); then
    err=$(cat "$err_file")
    rm -f "$err_file"
    echo "cr-plan.sh: gh error fetching comments for issue #$ISSUE_NUMBER:" >&2
    printf '%s\n' "$err" >&2
    return 4
  fi
  rm -f "$err_file"
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
