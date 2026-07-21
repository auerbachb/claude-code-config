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
#   0  Success — value printed (--get) or write completed (--set). A --get on
#      a corrupted known-typed field (see FIELD-TYPE CONTRACT) also exits 0,
#      printing a safe default instead of the corrupt value.
#   2  Usage error — missing/invalid mode, unknown flag, malformed --set
#      argument (no `=`), or no jq path given for --get.
#   3  State file missing on --get. (--set creates the file from `{}`.)
#   4  jq failed to parse the file or evaluate the path/expression, OR a
#      --set would leave a known-typed field (see FIELD-TYPE CONTRACT) holding
#      the wrong JSON type — the write is rejected and the state file is left
#      unmodified.
#   5  Write failed — could not create temp file, could not mv into place,
#      or jq filter pipeline failed during the atomic write.
#
# FIELD-TYPE CONTRACT (issues #625, #640)
#   A known set of fields always hold a specific JSON type — top-level
#   fields (arrays: active_agents, polling_jobs, polling_failures,
#   polling_backoffs; objects: prs, cr_quota, cr_hourly, greptile_daily,
#   pmm_in_flight, pmm) and per-PR nested fields under `.prs["<N>"]`
#   (objects: last_cron_action, preflight_triggered, babysit, wrap_sweep;
#   array: cr_explicit_triggers; number: digest_streak). Fields outside
#   these lists are unvalidated, preserving forward-compatibility with the
#   "preserve unknown fields" convention.
#
#   The contract is loaded at runtime from
#   .claude/reference/session-state-schema.json's `_field_types` object —
#   that file is the single source of truth, not a hardcoded list in this
#   script, so the two can never drift apart. If the schema file can't be
#   found or parsed (unusual invocation context, e.g. this script copied
#   somewhere without its .claude/reference/ sibling), the contract is
#   disabled for this run with a warning on stderr — --get/--set still work,
#   just without the type guard, rather than hard-failing every state-file
#   operation because a side file is missing.
#
#   --set checks the FINAL value of any touched known field after the whole
#   batch is applied (not just the raw value passed in), so both whole-field
#   writes (`--set '.active_agents=...'`) and element/sub-path writes
#   (`--set '.active_agents[0]=...'` or, for a per-PR nested field,
#   `--set '.prs["287"].babysit.active=...'`) are covered. If a touched
#   known field would end up the wrong type, the entire batch is rejected
#   (exit 4) and the state file is left unmodified — this is what should
#   have caught the original corruption: a caller passed an unevaluated jq
#   filter expression (e.g.
#   `(.active_agents // [] | map(select(.pr_number != 71)))`) as a --set
#   value; since it isn't valid JSON it fell into the --arg (string) branch
#   below and was written verbatim as `.active_agents`'s value. Callers must
#   evaluate any filter locally first (read → jq-filter → pass the
#   resulting JSON array/object as the --set value) — see the
#   read-filter-write pattern in .claude/skills/pr-monitor-and-manage/SKILL.md.
#
#   --get on a known top-level field whose *stored* value doesn't match the
#   contract (state corrupted before this guard existed, or written by
#   something bypassing this script) prints a warning to stderr and returns
#   a safe default (`[]`/`{}`) on stdout instead of the corrupt value,
#   exiting 0 so existing read-modify-write callers keep working — the next
#   validated --set through this same field then heals the corruption for
#   good. Per-PR nested fields are validated on --set only (not --get):
#   callers read them through infer-pr.sh or ad-hoc jq, not this script's
#   --get, so there's no read-modify-write caller to protect symmetrically.
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
#
#   # Rejected: .active_agents is a known array-typed field (issue #625) — a
#   # jq filter expression is not a JSON array, so this exits 4 and leaves
#   # the state file unmodified. Evaluate the filter locally first, then pass
#   # the resulting array (see pr-monitor-and-manage/SKILL.md's read-filter-
#   # write pattern):
#   session-state.sh --set '.active_agents=(.active_agents // [] | map(select(.pr_number != 71)))'
#   # -> exit 4: field '.active_agents' would become type 'string' but must be 'array'
#
#   # Rejected: last_cron_action is a known object-typed per-PR nested field
#   # (issue #640) — a bare string isn't a JSON object, so this exits 4 and
#   # leaves the state file unmodified:
#   session-state.sh --set '.prs["287"].last_cron_action=some bare string'
#   # -> exit 4: field '.prs["287"].last_cron_action' would become type 'string' but must be 'object'

set -euo pipefail
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" >> "$HOME/.claude/script-usage.log"

STATE_FILE="${HOME}/.claude/session-state.json"

# Sibling reference file that is the single source of truth for the
# FIELD-TYPE CONTRACT (issues #625, #640) — resolved relative to this
# script's own location (not $STATE_FILE's directory) so it works from every
# known invocation path (repo-local .claude/scripts/, the skills worktree,
# or a caller's own $SELF_DIR-relative lookup) without hardcoding an
# absolute path.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCHEMA_FILE="${SCRIPT_DIR}/../reference/session-state-schema.json"

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

# Field-type contract (issues #625, #640) — loaded once, lazily, from
# .claude/reference/session-state-schema.json's `_field_types` object (the
# single source of truth; see the FIELD-TYPE CONTRACT header comment). Two
# newline-separated "key=type" caches, one for top-level fields and one for
# per-PR nested fields, parsed by known_field_type()/known_nested_field_type()
# below. Plain variables (not associative arrays) so this script stays
# compatible with bash 3.2 (macOS system bash has no `declare -A`).
FIELD_TYPES_LOADED=0
FIELD_TYPES_TOP=""
FIELD_TYPES_NESTED=""

load_field_types() {
  if [[ "$FIELD_TYPES_LOADED" -eq 1 ]]; then
    return 0
  fi
  FIELD_TYPES_LOADED=1
  if [[ ! -f "$SCHEMA_FILE" ]]; then
    echo "session-state.sh: warning: field-type contract schema not found at $SCHEMA_FILE — type guard disabled for this run (see issue #640)" >&2
    return 0
  fi
  local top nested
  if ! top="$(jq -r '._field_types.top_level // {} | to_entries[] | "\(.key)=\(.value)"' "$SCHEMA_FILE" 2>/dev/null)"; then
    echo "session-state.sh: warning: could not parse field-type contract from $SCHEMA_FILE — type guard disabled for this run (see issue #640)" >&2
    return 0
  fi
  nested="$(jq -r '._field_types.pr_nested // {} | to_entries[] | "\(.key)=\(.value)"' "$SCHEMA_FILE" 2>/dev/null)" || nested=""
  FIELD_TYPES_TOP="$top"
  FIELD_TYPES_NESTED="$nested"
}

# Prints the expected JSON type ("array"/"object"/etc) for a known top-level
# field per the schema-driven contract, or nothing for fields outside it
# (left unvalidated for forward-compatibility).
known_field_type() {
  load_field_types
  local key="$1" line
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    if [[ "${line%%=*}" == "$key" ]]; then
      printf '%s' "${line#*=}"
      return 0
    fi
  done <<<"$FIELD_TYPES_TOP"
}

# Prints the expected JSON type for a known per-PR nested field (e.g.
# "last_cron_action" -> "object"), or nothing for fields outside the
# contract. Field name only — callers resolve the concrete `.prs["<N>"].<key>`
# check path themselves via pr_number_of()/pr_nested_key_of() below.
known_nested_field_type() {
  load_field_types
  local key="$1" line
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    if [[ "${line%%=*}" == "$key" ]]; then
      printf '%s' "${line#*=}"
      return 0
    fi
  done <<<"$FIELD_TYPES_NESTED"
}

# Extract the leading top-level key from a jq path, e.g.
# ".active_agents[0].id" -> "active_agents", `.prs["287"].reviewer` -> "prs".
# Also handles bracket notation for the top-level key itself, e.g.
# `.["active_agents"]` -> "active_agents" — without this, a path starting
# with `[` fell straight through the dot-form pattern below (which cuts at
# the first `.` or `[`) and produced an empty string, silently exempting
# that field from the contract (CodeAnt finding on PR #630, issue #625).
# Used to look up known_field_type() regardless of how deep the caller's
# path indexes below that top-level field.
top_level_key_of() {
  local path="${1#.}"
  if [[ "$path" == \[* ]]; then
    path="${path#\[}"
    path="${path%%]*}"
    path="${path#[\"\']}"
    path="${path%[\"\']}"
    printf '%s' "$path"
  else
    printf '%s' "${path%%[.[]*}"
  fi
}

# Extract the PR-number key from a path whose top-level key is "prs", e.g.
# `.prs["287"].last_cron_action` -> "287". Every known caller uses bracket
# notation for the PR-number selector (`.prs["<N>"]`), so only that form is
# recognized; a bare `.prs.287...` (unusual — jq requires bracket or quoted-
# dot notation for a numeric key) returns empty, same as an absent selector.
pr_number_of() {
  local path="${1#.prs}"
  if [[ "$path" != \[* ]]; then
    printf '%s' ""
    return 0
  fi
  path="${path#\[}"
  path="${path%%]*}"
  path="${path#[\"\']}"
  path="${path%[\"\']}"
  printf '%s' "$path"
}

# Extract the per-PR nested field name immediately after the PR-number
# selector, e.g. `.prs["287"].babysit.active` -> "babysit" (the known field
# two levels up from a subpath write — the same principle top_level_key_of()
# applies for top-level fields, e.g. `.active_agents[0].id` -> "active_agents").
# Returns empty if the path's top-level key isn't "prs", there's no bracket
# PR-number selector, or nothing follows it (a whole-`.prs["<N>"]` entry
# replacement isn't checked here — the existing top-level object-type check
# on `prs` itself still applies).
pr_nested_key_of() {
  if [[ "$(top_level_key_of "$1")" != "prs" ]]; then
    printf '%s' ""
    return 0
  fi
  local path
  path="$(pr_number_of "$1")"
  if [[ -z "$path" ]]; then
    printf '%s' ""
    return 0
  fi
  # Re-derive the remainder after the PR-number selector (pr_number_of()
  # only returns the extracted number, not the leftover path).
  path="${1#.prs}"
  path="${path#\[*\]}"
  path="${path#.}"
  if [[ -z "$path" ]]; then
    printf '%s' ""
    return 0
  fi
  if [[ "$path" == \[* ]]; then
    path="${path#\[}"
    path="${path%%]*}"
    path="${path#[\"\']}"
    path="${path%[\"\']}"
    printf '%s' "$path"
  else
    printf '%s' "${path%%[.[]*}"
  fi
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

  # Read-time type guard (issue #625): if GET_PATH addresses a known
  # top-level field exactly (not a deeper sub-path) and the stored value's
  # type doesn't match the field-type contract, warn and return a safe
  # default instead of the corrupt value — a "null" (field absent) is not
  # corruption and falls through to the normal read below, matching existing
  # caller idioms like `[ "$X" = "null" ] && X='[]'`. Callers that
  # read-modify-write this field (e.g. pr-monitor-and-manage/SKILL.md) then
  # self-heal it on their next validated --set.
  #
  # "Exactly" is checked against both dot form (.active_agents) and jq's
  # equivalent bracket form (.["active_agents"]) — comparing only against
  # the dot form let a bracket-form GET_PATH slip past this guard even after
  # top_level_key_of() learned to parse it (CodeAnt finding on PR #630). A
  # bracket group with no leading dot (`["active_agents"]`) is deliberately
  # NOT matched here — in jq that's an array-literal constructor, not a way
  # to index the input document, so it never reads the real field either way.
  get_top_level_key="$(top_level_key_of "$GET_PATH")"
  get_expected_type="$(known_field_type "$get_top_level_key")"
  if [[ -n "$get_expected_type" ]]; then
    case "$GET_PATH" in
      ".$get_top_level_key"|".[\"$get_top_level_key\"]") ;;
      *) get_expected_type="" ;;
    esac
  fi
  if [[ -n "$get_expected_type" ]]; then
    get_actual_type="$(jq -r "$GET_PATH | type" "$STATE_FILE" 2>/dev/null)"
    if [[ "$get_actual_type" != "$get_expected_type" && "$get_actual_type" != "null" ]]; then
      echo "session-state.sh: field '$GET_PATH' is corrupted — expected $get_expected_type but found $get_actual_type; returning a safe default (see issue #625)" >&2
      if [[ "$get_expected_type" == "array" ]]; then
        echo '[]'
      else
        echo '{}'
      fi
      exit 0
    fi
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
TOUCHED_KNOWN_FIELDS=""
TOUCHED_NESTED_CHECKS=""
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
  # Track known-typed fields touched by this batch (deduped) for the
  # post-write field-type contract check below — see FIELD-TYPE CONTRACT.
  set_top_level_key="$(top_level_key_of "$path")"
  if [[ -n "$(known_field_type "$set_top_level_key")" ]]; then
    case " $TOUCHED_KNOWN_FIELDS " in
      *" $set_top_level_key "*) ;;
      *) TOUCHED_KNOWN_FIELDS="$TOUCHED_KNOWN_FIELDS $set_top_level_key" ;;
    esac
  fi
  # Same tracking for per-PR nested fields (issue #640): a touched path whose
  # top-level key is "prs" and whose immediate post-PR-number segment is a
  # known nested field (e.g. `.prs["287"].last_cron_action` or a deeper
  # subpath like `.prs["287"].babysit.active`) is recorded as a "<PR>:<key>"
  # pair so the post-write loop below can check that specific PR entry's
  # field, not every PR in the file.
  set_nested_key="$(pr_nested_key_of "$path")"
  if [[ -n "$set_nested_key" ]] && [[ -n "$(known_nested_field_type "$set_nested_key")" ]]; then
    set_pr_number="$(pr_number_of "$path")"
    # PR numbers are always plain digits (GitHub PR numbers). Requiring that
    # shape here — before $set_pr_number gets interpolated into the jq
    # filter string built for nested_check_path below — keeps that
    # interpolation injection-safe without needing full jq-string escaping.
    if [[ "$set_pr_number" =~ ^[0-9]+$ ]]; then
      nested_pair="${set_pr_number}:${set_nested_key}"
      case " $TOUCHED_NESTED_CHECKS " in
        *" $nested_pair "*) ;;
        *) TOUCHED_NESTED_CHECKS="$TOUCHED_NESTED_CHECKS $nested_pair" ;;
      esac
    fi
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

# Field-type contract (issue #625): reject the write if any known
# array/object-typed field touched by this batch would end up the wrong
# type in the FINAL document — not just the raw --set value, so subpath/
# element writes (e.g. `.active_agents[0]=...`) are covered too, not just
# whole-field writes. This is what should have caught the original
# corruption: an unevaluated jq filter expression passed as a --set value
# falls into the --arg (string) branch above and would otherwise be written
# verbatim, turning an array field into a literal string. Checked before
# the atomic mv below, so a rejected batch leaves $STATE_FILE untouched.
for set_touched_key in $TOUCHED_KNOWN_FIELDS; do
  set_expected_type="$(known_field_type "$set_touched_key")"
  set_actual_type="$(jq -r ".${set_touched_key} | type" "$OUT_TMP" 2>/dev/null)"
  if [[ "$set_actual_type" != "$set_expected_type" ]]; then
    echo "session-state.sh: refusing to write — field '.$set_touched_key' would become type '$set_actual_type' but must be '$set_expected_type' (see issue #625); $STATE_FILE left unmodified" >&2
    exit 4
  fi
done

# Field-type contract, per-PR nested fields (issue #640): same principle as
# the top-level loop above, extended to reach fields nested under a specific
# `.prs["<N>"]` entry — e.g. PR #542's `last_cron_action` holding a bare
# string where every consumer (infer-pr.sh, wrap, babysit-pr) expects an
# object. Checked against the FINAL value at the concrete `.prs["<N>"].<key>`
# path, so sub-path writes (e.g. `.prs["287"].babysit.active=...`) are
# covered by checking the whole `babysit` object's final type, not just the
# raw --set value.
for nested_pair in $TOUCHED_NESTED_CHECKS; do
  nested_pr_number="${nested_pair%%:*}"
  nested_field_key="${nested_pair#*:}"
  nested_expected_type="$(known_nested_field_type "$nested_field_key")"
  nested_check_path=".prs[\"${nested_pr_number}\"].${nested_field_key}"
  nested_actual_type="$(jq -r "${nested_check_path} | type" "$OUT_TMP" 2>/dev/null)"
  if [[ "$nested_actual_type" != "$nested_expected_type" ]]; then
    echo "session-state.sh: refusing to write — field '$nested_check_path' would become type '$nested_actual_type' but must be '$nested_expected_type' (see issue #640); $STATE_FILE left unmodified" >&2
    exit 4
  fi
done

if ! mv "$OUT_TMP" "$STATE_FILE" 2>/dev/null; then
  echo "session-state.sh: could not write $STATE_FILE" >&2
  exit 5
fi

exit 0
