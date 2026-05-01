#!/usr/bin/env bash
# session-state.sh — Surgical read/write helper for ~/.claude/session-state.json.
#
# PURPOSE
#   Single helper for read-modify-write operations on ~/.claude/session-state.json
#   with sibling-field preservation and atomic replace. Replaces the verbose
#   inline `jq … > tmp && mv tmp file` blocks scattered across agents and skills,
#   and provides the canonical handle for ad-hoc inspection/mutation of the
#   state file. Models the same atomic-write pattern as
#   .claude/scripts/repair-trust-all.sh and .claude/scripts/greptile-budget.sh.
#
#   Multiple --set flags merge into ONE atomic write (not N sequential writes),
#   so callers can mutate several paths in a single transaction without a
#   partial-write race window between them.
#
# USAGE
#   session-state.sh --get <jq-path>
#   session-state.sh --set <jq-path>=<value> [--set <jq-path>=<value> ...]
#   session-state.sh --help | -h
#
# MODES
#   --get <jq-path>    Read the value at <jq-path> from the state file and
#                      print it on stdout (raw via `jq -r`). Exits 3 if the
#                      state file does not exist; exits 4 on jq parse errors.
#                      Returns "null" with exit 0 if the path is absent but
#                      the file is a valid JSON object — matches jq semantics.
#
#   --set <path>=<v>   Set <jq-path> to <value> in the state file, preserving
#                      all other top-level fields. <value> may be:
#                        • A JSON literal — number, boolean, null, JSON object,
#                          JSON array, or quoted string. Detected by attempting
#                          to parse <value> as JSON first.
#                        • A bare string — anything that fails JSON parsing is
#                          treated as a literal string.
#                      Multiple --set flags accumulate into ONE atomic jq
#                      pipeline → ONE temp-file → ONE mv. If the state file is
#                      missing, it is initialized with `{}` and the writes are
#                      applied to that fresh object (exit 0, NOT 3).
#                      Auto-updates `.last_updated` to the current ISO 8601
#                      timestamp on every write — matches the pattern in
#                      greptile-budget.sh and reviewer-of.sh.
#
# EXIT STATUS
#   0  Success — value printed (--get) or write completed (--set).
#   2  Usage error — missing/invalid mode, unknown flag, malformed --set
#      argument (no `=`), or no jq path given for --get.
#   3  State file missing on --get. (--set creates the file from `{}`.)
#   4  jq failed to parse the file or evaluate the path/expression.
#   5  Write failed — could not create temp file, could not mv into place,
#      or jq filter pipeline failed during the atomic write.
#
# OUTPUT
#   --get: raw value on stdout (one line per jq output, like `jq -r`).
#   --set: nothing on stdout when the write succeeds.
#   stderr: one-line error messages on failure.
#
# ATOMICITY
#   The state file is read into a temp file (or seeded as `{}` if missing),
#   piped through a jq pipeline that builds all --set assignments + the
#   `.last_updated` refresh, written to `${STATE_FILE}.tmp.$$`, and then
#   atomically renamed via `mv`. `mv` within the same filesystem is atomic
#   on POSIX. Sibling fields outside the assigned paths are preserved
#   verbatim — a fresh top-level key added by some other writer between our
#   read and write will survive (subject to the standard last-writer-wins
#   race that exists in the inline blocks this helper replaces).
#
# DEPENDENCIES
#   - jq
#   - mktemp, mv (POSIX)
#   - date (any platform — only TZ-agnostic `date -u +'%Y-%m-%dT%H:%M:%SZ'`)
#
# EXAMPLES
#   # Read a value:
#   session-state.sh --get '.greptile_daily.reviews_used'
#   # -> 3
#
#   # Set a single value (string auto-detected):
#   session-state.sh --set '.prs["287"].reviewer=greptile'
#
#   # Set multiple values atomically (all in one write):
#   session-state.sh \
#     --set '.prs["287"].phase=B' \
#     --set '.prs["287"].head_sha=abc1234'
#
#   # Set a JSON object literal:
#   session-state.sh --set '.greptile_daily={"date":"","reviews_used":0,"budget":40}'
#
#   # Cache that BugBot is installed for PR 287 (used by escalate-review.sh):
#   session-state.sh --set '.prs["287"].bugbot_installed=true'

set -euo pipefail
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" >> "$HOME/.claude/script-usage.log"

STATE_FILE="${HOME}/.claude/session-state.json"

print_help() {
  sed -n '/^# PURPOSE$/,/^$/p' "$0" | sed '$d; s/^# \{0,1\}//'
}

die_usage() {
  echo "session-state.sh: $1" >&2
  echo "Run with --help for usage." >&2
  exit 2
}

# Validate that the state file contains exactly ONE top-level JSON object.
# `jq empty` and `jq -e 'type == "object"'` both succeed on multi-document
# files like `{}\n{}` because jq processes documents independently — the
# slurp (-s) check folds them into an array so we can assert length == 1.
# Without this guard, --get returns N values per path and --set rewrites N
# objects, corrupting the state file. Non-zero exit on any of: parse error,
# multi-document, scalar/array/null at top level.
is_single_object_state_file() {
  jq -s -e 'length == 1 and (.[0] | type == "object")' "$1" >/dev/null 2>&1
}

# --- arg parsing ---
MODE=""
GET_PATH=""
# Parallel arrays for --set: SET_PATHS[i] is the jq path, SET_VALUES[i] is
# the literal text the user passed after the `=`. They are interpreted as
# JSON-or-string at write time so we keep their raw form here.
SET_PATHS=()
SET_VALUES=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      print_help
      exit 0
      ;;
    --get)
      if [[ -n "$MODE" && "$MODE" != "get" ]]; then
        die_usage "--get cannot be combined with --set"
      fi
      if [[ $# -lt 2 ]]; then
        die_usage "--get requires a jq path"
      fi
      if [[ -n "$GET_PATH" ]]; then
        die_usage "--get may only be given once"
      fi
      MODE="get"
      GET_PATH="$2"
      shift 2
      ;;
    --set)
      if [[ -n "$MODE" && "$MODE" != "set" ]]; then
        die_usage "--set cannot be combined with --get"
      fi
      if [[ $# -lt 2 ]]; then
        die_usage "--set requires <jq-path>=<value>"
      fi
      MODE="set"
      local_arg="$2"
      # Split on the FIRST `=` only — values may contain `=` (e.g., a JSON
      # string with `=` inside it).
      if [[ "$local_arg" != *=* ]]; then
        die_usage "--set argument must be <jq-path>=<value>, got: $local_arg"
      fi
      # Reject empty LHS so `--set =foo` fails at the usage-error stage
      # (exit 2) instead of falling through to a cryptic jq pipeline error
      # (exit 5). The `*=*` glob above accepts "=foo"; this guard rejects it.
      if [[ -z "${local_arg%%=*}" ]]; then
        die_usage "--set requires a non-empty jq path, got: $local_arg"
      fi
      SET_PATHS+=("${local_arg%%=*}")
      SET_VALUES+=("${local_arg#*=}")
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
  die_usage "one of --get or --set is required"
fi

# --- dependency check ---
if ! command -v jq >/dev/null 2>&1; then
  echo "session-state.sh: 'jq' not found on PATH" >&2
  exit 5
fi

# --- ensure state-file directory exists (only needed for --set) ---
STATE_DIR="$(dirname "$STATE_FILE")"

# ============================================================================
# --get
# ============================================================================
if [[ "$MODE" == "get" ]]; then
  if [[ -z "$GET_PATH" ]]; then
    die_usage "--get requires a jq path"
  fi
  if [[ ! -f "$STATE_FILE" ]]; then
    echo "session-state.sh: state file not found: $STATE_FILE" >&2
    exit 3
  fi
  # Reject multi-document, scalar/array/null, and unparseable state files
  # before evaluating the user's path — see is_single_object_state_file().
  if ! is_single_object_state_file "$STATE_FILE"; then
    echo "session-state.sh: $STATE_FILE must contain exactly one top-level JSON object" >&2
    exit 4
  fi
  # Use jq -r so callers get the raw value (string without quotes, number
  # as-is, etc.). jq exits non-zero on parse errors — translate to 4.
  jq_err="$(mktemp)"
  trap "rm -f '$jq_err' 2>/dev/null" EXIT
  if ! jq -r "$GET_PATH" "$STATE_FILE" 2>"$jq_err"; then
    echo "session-state.sh: jq failed reading $STATE_FILE: $(cat "$jq_err")" >&2
    exit 4
  fi
  exit 0
fi

# ============================================================================
# --set
# ============================================================================
if [[ "${#SET_PATHS[@]}" -eq 0 ]]; then
  die_usage "--set requires at least one <jq-path>=<value>"
fi

if ! mkdir -p "$STATE_DIR" 2>/dev/null; then
  echo "session-state.sh: could not create state dir: $STATE_DIR" >&2
  exit 5
fi

# Build the input file: existing state if present + valid; seeded `{}` otherwise.
# Require a single top-level JSON object — see is_single_object_state_file().
# Every assignment in the pipeline indexes the root with a string key, so
# arrays/scalars/null would parse fine but fail downstream with confusing
# "Cannot index <type> with string" errors; multi-document files would write
# back N modified objects, corrupting the state file.
SEEDED_TMP=""
input_file="$STATE_FILE"
if [[ ! -f "$STATE_FILE" ]]; then
  SEEDED_TMP="$(mktemp)"
  printf '%s\n' '{}' > "$SEEDED_TMP"
  input_file="$SEEDED_TMP"
elif ! is_single_object_state_file "$STATE_FILE"; then
  echo "session-state.sh: $STATE_FILE must contain exactly one top-level JSON object; refusing to overwrite" >&2
  exit 4
fi

OUT_TMP="$STATE_FILE.tmp.$$"
JQ_ERR="$(mktemp)"
# shellcheck disable=SC2064
trap "rm -f '$OUT_TMP' '$JQ_ERR' ${SEEDED_TMP:+'$SEEDED_TMP'} 2>/dev/null" EXIT

# Build the jq pipeline. Each --set becomes one assignment in the pipeline,
# bound to a unique --argjson or --arg variable. The final stage refreshes
# `.last_updated`. All assignments + the timestamp run in a single jq
# invocation → single atomic write.
JQ_FILTER=""
JQ_ARGS=()
for i in "${!SET_PATHS[@]}"; do
  path="${SET_PATHS[$i]}"
  value="${SET_VALUES[$i]}"
  varname="v$i"
  # Try to parse as JSON; fall back to string. Use `jq empty` (not `jq -e .`)
  # because `-e` exits non-zero on null/false even when parse succeeds — so
  # legitimate JSON values null and false would be silently coerced to the
  # strings "null" and "false". `empty` validates parse only.
  #
  # Empty value short-circuit: `jq empty` accepts zero-value stdin and exits 0,
  # but `--argjson v ""` then fails ("invalid JSON text"). Treat an empty
  # `--set <path>=` as the literal empty string.
  if [[ -n "$value" ]] && printf '%s' "$value" | jq empty >/dev/null 2>&1; then
    JQ_ARGS+=(--argjson "$varname" "$value")
  else
    JQ_ARGS+=(--arg "$varname" "$value")
  fi
  if [[ -z "$JQ_FILTER" ]]; then
    JQ_FILTER="$path = \$$varname"
  else
    JQ_FILTER="$JQ_FILTER | $path = \$$varname"
  fi
done

# Append the .last_updated refresh — done in jq (not bash) so it shares the
# atomic write. Use UTC ISO 8601 to match `(now | todate)` semantics in
# greptile-budget.sh / reviewer-of.sh; jq's `now | todate` would also work
# but emitting from bash keeps the path injection-free.
LAST_UPDATED="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
JQ_ARGS+=(--arg __last_updated "$LAST_UPDATED")
JQ_FILTER="$JQ_FILTER | .last_updated = \$__last_updated"

if ! jq "${JQ_ARGS[@]}" "$JQ_FILTER" "$input_file" > "$OUT_TMP" 2>"$JQ_ERR"; then
  # Write-stage pipeline failure → exit 5 per the contract documented in the
  # EXIT STATUS block above. (Exit 4 is reserved for read-stage parse errors.)
  echo "session-state.sh: jq failed updating $STATE_FILE: $(cat "$JQ_ERR")" >&2
  exit 5
fi

if ! mv "$OUT_TMP" "$STATE_FILE" 2>/dev/null; then
  echo "session-state.sh: could not write $STATE_FILE" >&2
  exit 5
fi

exit 0
