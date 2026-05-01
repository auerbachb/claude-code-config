#!/usr/bin/env bash
# greptile-budget.sh — Daily Greptile review budget guard.
#
# PURPOSE
#   Single source of truth for the Greptile daily-budget contract defined in
#   .claude/rules/greptile.md: hard daily cap on paid `@greptileai` reviews to
#   prevent runaway costs when many PRs run in parallel. Reads and mutates the
#   `greptile_daily` subtree of ~/.claude/session-state.json with the same
#   atomic jq + temp-file + mv pattern used by the inline blocks it replaces.
#
#   The script MUST be invoked before every `@greptileai` trigger point (CR
#   rate-limit / CR timeout fallback, BugBot timeout, per-PR re-reviews). No
#   `@greptileai` comment may be posted without a successful `--consume` (or a
#   non-exhausted `--check` followed by `--consume`).
#
# USAGE
#   greptile-budget.sh --check  [--budget N]
#   greptile-budget.sh --consume [--budget N]
#   greptile-budget.sh --reset  [--budget N]
#   greptile-budget.sh --help | -h
#
# MODES
#   --check     Read current state; print JSON {date, reviews_used, budget,
#               exhausted} on stdout. Performs same-day reset in-memory for
#               the reported view, but does NOT mutate session-state on a
#               same-day read. Writes state only on the cross-day boundary
#               (so the first --check of a new ET day zeroes the counter).
#   --consume   Same-day-reset → increment `reviews_used` by 1 → atomically
#               write back. Prints the post-consume JSON. If the pre-consume
#               count is already at or above `budget`, does NOT decrement and
#               exits 1 (exhausted).
#   --reset    Force-zero today's counter. Writes state atomically. Prints
#               the post-reset JSON.
#
# FLAGS
#   --budget N  Override the default budget of 40 reviews/day. If the stored
#               state has no `budget` field yet, it is set to N. If it does,
#               N overrides the stored value on this write.
#
# OUTPUT
#   stdout: single-line JSON object — `{"date":"YYYY-MM-DD","reviews_used":N,
#           "budget":N,"exhausted":bool}`.
#   stderr: one-line error messages on failure.
#
# EXIT STATUS
#   0  Success — consumed / checked OK / reset OK (state printed on stdout).
#   1  Budget exhausted — no decrement performed (--consume) or exhausted
#      snapshot reported (--check). JSON still printed on stdout.
#   2  Usage error (missing/invalid mode, unknown flag, bad --budget value).
#   5  Write failed (jq parse error, mv failed, disk full, etc.).
#
# ATOMICITY
#   All writes go through `jq ... > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp"
#   "$STATE_FILE"`. `mv` within the same filesystem is atomic on POSIX.
#   Concurrent subagents may race on the read, but the window is tiny and
#   the worst case is a single extra decrement — the check+consume sequence
#   is the same race that exists in the inline blocks this script replaces.
#
# DEPENDENCIES
#   - jq
#   - date (BSD or GNU — only uses TZ='America/New_York' +%Y-%m-%d)
#
# EXAMPLES
#   # Gate a @greptileai trigger — exit 1 means "do not trigger":
#   if ! greptile-budget.sh --consume >/dev/null; then
#     echo "Greptile budget exhausted — falling back to self-review" >&2
#     exit 1
#   fi
#   gh pr comment "$PR" --body "@greptileai"
#
#   # Read-only snapshot:
#   greptile-budget.sh --check
#   # -> {"date":"2026-04-16","reviews_used":3,"budget":40,"exhausted":false}

set -euo pipefail
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" >> "$HOME/.claude/script-usage.log" 2>/dev/null || true

STATE_FILE="${HOME}/.claude/session-state.json"
DEFAULT_BUDGET=40

print_help() {
  sed -n '/^# PURPOSE$/,/^# EXAMPLES$/p' "$0" | sed 's/^# \{0,1\}//'
}

die_usage() {
  echo "greptile-budget.sh: $1" >&2
  echo "Run with --help for usage." >&2
  exit 2
}

# --- arg parsing ---
MODE=""
BUDGET_OVERRIDE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      print_help
      exit 0
      ;;
    --check|--consume|--reset)
      if [[ -n "$MODE" ]]; then
        die_usage "only one of --check, --consume, --reset may be given"
      fi
      MODE="${1#--}"
      shift
      ;;
    --budget)
      if [[ $# -lt 2 ]]; then
        die_usage "--budget requires a value"
      fi
      BUDGET_OVERRIDE="$2"
      if ! [[ "$BUDGET_OVERRIDE" =~ ^[0-9]+$ ]]; then
        die_usage "--budget must be a non-negative integer, got: $BUDGET_OVERRIDE"
      fi
      shift 2
      ;;
    --)
      shift
      break
      ;;
    -*)
      die_usage "unknown flag: $1"
      ;;
    *)
      die_usage "unexpected positional argument: $1"
      ;;
  esac
done

if [[ -z "$MODE" ]]; then
  die_usage "one of --check, --consume, --reset is required"
fi

# --- dependency check ---
if ! command -v jq >/dev/null 2>&1; then
  echo "greptile-budget.sh: 'jq' not found on PATH" >&2
  exit 5
fi

# --- ensure state-file directory exists ---
STATE_DIR="$(dirname "$STATE_FILE")"
if ! mkdir -p "$STATE_DIR" 2>/dev/null; then
  echo "greptile-budget.sh: could not create state dir: $STATE_DIR" >&2
  exit 5
fi

TODAY="$(TZ='America/New_York' date +'%Y-%m-%d')"

# --- read (or initialize) greptile_daily subtree ---
# Handle three cases: file missing, file empty/corrupt JSON, file valid.
# On corrupt/missing, we fall back to the default state but do NOT rewrite the
# whole file here — only the write path (consume/reset or cross-day --check)
# will rewrite, and it always merges into the existing file so sibling fields
# are preserved when the JSON is valid.
read_state() {
  if [[ -f "$STATE_FILE" ]] && jq -e . "$STATE_FILE" >/dev/null 2>&1; then
    # File exists AND parses as valid JSON. Inject DEFAULT_BUDGET so the
    # jq fallback tracks the shell constant — changing DEFAULT_BUDGET at the
    # top of the script flows through to every default site.
    jq -r --argjson default_budget "$DEFAULT_BUDGET" \
      '.greptile_daily // {"date":"","reviews_used":0,"budget":$default_budget}' \
      "$STATE_FILE"
  else
    # File missing or corrupt — return default, do not mutate on read.
    printf '{"date":"","reviews_used":0,"budget":%s}\n' "$DEFAULT_BUDGET"
  fi
}

CURRENT_RAW="$(read_state)"
# Extract fields with defaults.
CURRENT_DATE="$(printf '%s' "$CURRENT_RAW" | jq -r '.date // ""')"
CURRENT_USED="$(printf '%s' "$CURRENT_RAW" | jq -r '.reviews_used // 0')"
# Mirror the EFFECTIVE_BUDGET validation below — if the JSON is malformed
# with a non-numeric reviews_used, bash arithmetic would silently treat it
# as 0. Be explicit instead so corrupt state is handled consistently.
if ! [[ "$CURRENT_USED" =~ ^[0-9]+$ ]]; then
  CURRENT_USED=0
fi
CURRENT_BUDGET="$(printf '%s' "$CURRENT_RAW" | jq -r --argjson default_budget "$DEFAULT_BUDGET" '.budget // $default_budget')"

# Apply --budget override.
if [[ -n "$BUDGET_OVERRIDE" ]]; then
  EFFECTIVE_BUDGET="$BUDGET_OVERRIDE"
else
  EFFECTIVE_BUDGET="$CURRENT_BUDGET"
fi
if ! [[ "$EFFECTIVE_BUDGET" =~ ^[0-9]+$ ]]; then
  EFFECTIVE_BUDGET="$DEFAULT_BUDGET"
fi

# Compute the "view after same-day reset" — what the counter would be if we
# applied the cross-day rule. Used by all three modes.
if [[ "$CURRENT_DATE" != "$TODAY" ]]; then
  VIEW_USED=0
else
  VIEW_USED="$CURRENT_USED"
fi

# --- write helper (atomic jq + temp-file + mv) ---
# Writes greptile_daily and last_updated, preserving all other top-level
# fields. On any failure, emits exit 5.
write_state() {
  local new_used="$1"
  local new_budget="$2"

  local tmp="$STATE_FILE.tmp.$$"
  # If file is missing or corrupt, seed with an empty object so jq has input.
  local input_file="$STATE_FILE"
  if [[ ! -f "$STATE_FILE" ]] || ! jq -e . "$STATE_FILE" >/dev/null 2>&1; then
    input_file="$(mktemp)"
    printf '%s\n' '{}' > "$input_file"
    # shellcheck disable=SC2064
    trap "rm -f '$input_file' '$tmp' 2>/dev/null" EXIT
  else
    # shellcheck disable=SC2064
    trap "rm -f '$tmp' 2>/dev/null" EXIT
  fi

  # Capture jq stderr separately so a failure surfaces the underlying cause
  # (e.g., unexpected input) instead of being swallowed. Stdout still goes to
  # $tmp so the atomic rename below is unaffected.
  local jq_err
  jq_err="$(mktemp)"
  if ! jq \
    --arg today "$TODAY" \
    --argjson used "$new_used" \
    --argjson budget "$new_budget" \
    '.greptile_daily = {"date": $today, "reviews_used": $used, "budget": $budget}
     | .last_updated = (now | todate)' \
    "$input_file" > "$tmp" 2>"$jq_err"; then
    echo "greptile-budget.sh: jq failed updating $STATE_FILE: $(cat "$jq_err")" >&2
    rm -f "$jq_err" 2>/dev/null || true
    exit 5
  fi
  rm -f "$jq_err" 2>/dev/null || true

  if ! mv "$tmp" "$STATE_FILE" 2>/dev/null; then
    echo "greptile-budget.sh: could not write $STATE_FILE" >&2
    exit 5
  fi
}

print_state() {
  local used="$1"
  local budget="$2"
  local exhausted="$3"
  jq -n -c \
    --arg date "$TODAY" \
    --argjson used "$used" \
    --argjson budget "$budget" \
    --argjson exhausted "$exhausted" \
    '{date: $date, reviews_used: $used, budget: $budget, exhausted: $exhausted}'
}

case "$MODE" in
  check)
    # Read-only semantics on same-day. On cross-day (stored date != today),
    # persist the reset so subsequent --consume starts from 0.
    if [[ "$CURRENT_DATE" != "$TODAY" ]]; then
      write_state 0 "$EFFECTIVE_BUDGET"
    elif [[ -n "$BUDGET_OVERRIDE" && "$BUDGET_OVERRIDE" != "$CURRENT_BUDGET" ]]; then
      # Budget override on same day — persist so later calls pick it up.
      write_state "$VIEW_USED" "$EFFECTIVE_BUDGET"
    fi
    if (( VIEW_USED >= EFFECTIVE_BUDGET )); then
      print_state "$VIEW_USED" "$EFFECTIVE_BUDGET" true
      exit 1
    fi
    print_state "$VIEW_USED" "$EFFECTIVE_BUDGET" false
    exit 0
    ;;

  consume)
    # VIEW_USED was already reset to 0 earlier on cross-day (see the
    # "view after same-day reset" block above), so this check covers
    # same-day exhaustion and the --budget 0 edge case.
    if (( VIEW_USED >= EFFECTIVE_BUDGET )); then
      print_state "$VIEW_USED" "$EFFECTIVE_BUDGET" true
      exit 1
    fi
    NEW_USED=$(( VIEW_USED + 1 ))
    write_state "$NEW_USED" "$EFFECTIVE_BUDGET"
    EXHAUSTED_AFTER=false
    if (( NEW_USED >= EFFECTIVE_BUDGET )); then
      EXHAUSTED_AFTER=true
    fi
    print_state "$NEW_USED" "$EFFECTIVE_BUDGET" "$EXHAUSTED_AFTER"
    exit 0
    ;;

  reset)
    write_state 0 "$EFFECTIVE_BUDGET"
    print_state 0 "$EFFECTIVE_BUDGET" false
    exit 0
    ;;
esac
