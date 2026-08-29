#!/usr/bin/env bash
# usage-horizon.sh — Pre-limit usage-horizon evaluator (issue #1427).
#
# PURPOSE
#   Turn the harness-injected in-context remaining-token counter
#   (`<total_tokens>N tokens left</total_tokens>`, present at session start and
#   refreshed after every tool result) into a stable, configurable verdict:
#   clear | approaching | critical | unknown.
#
#   The model reads the number the HARNESS printed into its context and hands
#   it to this script. This script performs COMPARISONS ONLY. It never reads a
#   transcript, never counts or converts tokens, never derives a figure from
#   session history, and has no estimation fallback path of any kind. If no
#   upstream reading was supplied it says `unknown` — it does not invent one.
#
#   Safety rule:  `.claude/rules/safety.md` §"Anthropic Quota & Spend Authority"
#   Probe order:  `.claude/reference/budget-source-probe.md` §"Probe 0"
#   Signal audit: `.claude/reference/usage-limit-signal-audit-2026-07.md`
#
#   Distinct wallet from credit-budget.sh: that script governs Anthropic credit
#   SPEND against a dollar budget; this one governs WINDOW QUOTA runway. Neither
#   reads the other's state, and this script changes nothing in credit-budget.sh.
#
# USAGE
#   usage-horizon.sh --observe <remaining> [--limit <total>] [--session <id>]
#   usage-horizon.sh --check [--session <id>]
#   usage-horizon.sh --help | -h
#
# MODES
#   --observe <remaining>
#              Record one upstream reading. `<remaining>` is the number the
#              harness printed; `--limit <total>` is the window total when the
#              harness also stated one. Appends
#              `{ts, session_id, remaining, limit?}` to the observation log,
#              computes the stable verdict (applying hysteresis against the
#              previous reading in THIS session), and persists both to
#              session-state via session-state.sh --set.
#
#              Exits 0 on a successful record REGARDLESS of the verdict — only
#              --check maps verdicts to exit codes. The verdict is still
#              printed so a caller sees it without a second invocation.
#
#   --check    Read back this session's stored reading, apply the freshness /
#              integrity gate, and emit the persisted verdict. Pure read: it
#              never writes and never takes a lock. The verdict itself was
#              computed at --observe time against the knobs in force then;
#              --check re-evaluates only staleness, session ownership, and
#              stored-value integrity.
#
# FLAGS
#   --limit <total>   Window total for the reading. Positive integer, and
#                     `<remaining>` must not exceed it. Percentage thresholds
#                     apply when given; the absolute floor applies when absent.
#   --session <id>    Session identity override. Resolution order is
#                     --session, then $CLAUDE_SESSION_ID, then a digest of the
#                     nearest ancestor `claude` process (pid + start time).
#
# OUTPUT
#   stdout: exactly two lines —
#             STATUS=clear|approaching|critical|unknown
#             REASON=<slug>
#   stderr: one-line diagnostic on every degraded or failed path.
#
# EXIT STATUS (the gate; unknown is NEVER read as clear)
#   0  clear        — runway above the approaching threshold (--observe: recorded)
#   1  approaching  — at or below the approaching threshold
#   2  critical     — at or below the critical threshold
#   3  unknown      — no reading this session, stale, corrupt, or malformed
#   4  Usage error (missing/invalid mode, unknown flag, malformed argument)
#   5  Write failed (log append, jq failure, session-state.sh refusal)
#   6  Lock timeout (CLAUDE_STATE_LOCK_TIMEOUT; nothing written)
#
#   `clear` is the ONLY code a caller may read as permission. Every degraded
#   input lands on 3, which is a distinct code precisely so `unknown` can never
#   be mistaken for `clear` by an `if script; then proceed; fi` caller.
#
# CONFIGURATION (pm-config.md `## Budget`; env override wins)
#   usage_horizon_approaching_pct   CLAUDE_USAGE_HORIZON_APPROACHING_PCT   25
#   usage_horizon_critical_pct      CLAUDE_USAGE_HORIZON_CRITICAL_PCT      10
#   usage_horizon_floor_tokens      CLAUDE_USAGE_HORIZON_FLOOR_TOKENS      2000000
#   usage_horizon_hysteresis_pct    CLAUDE_USAGE_HORIZON_HYSTERESIS_PCT    3
#   usage_horizon_reading_ttl_s     CLAUDE_USAGE_HORIZON_TTL_SECONDS       1800
#
#   Percentage knobs apply when the reading carries a `limit`. When it does
#   not, the absolute floor stands in for the approaching threshold and the
#   critical threshold scales by the same ratio the percentages express:
#       critical_floor = floor_tokens * critical_pct / approaching_pct
#   so one absolute knob preserves the configured severity ordering. This is
#   the RELEASE_BUILD_FACTOR + RELEASE_NOTIFY_FLOOR_MIN pairing from
#   release-policy.sh: a proportional rule with an absolute stand-in.
#
#   These knobs gate horizon VERDICTS only. They never authorize local token
#   estimation — there is no code path here that could consume one.
#
# HYSTERESIS
#   Worsening is immediate; improving must clear the threshold by the margin.
#   A reading that drops into a more severe band takes effect at once, so the
#   wall is never recognized late. A reading that rises back out holds the
#   previous verdict until it exceeds that band's threshold by
#   `hysteresis_pct` (scaled into token units in floor mode), which is what
#   stops adjacent readings from flapping the verdict. A prior `unknown`, or a
#   reading from a different session, is not a level: it anchors nothing.
#
# CONCURRENT SESSIONS (known limitation, deliberately not papered over)
#   `.usage_horizon` is a SINGLE slot in a machine-wide state file, so the most
#   recent `--observe` from any session owns it. A session whose reading has
#   been overwritten by another session reads `no-reading-this-session` and
#   gets `unknown` — never another session's verdict, and never `clear`. That
#   is the safe failure, but on a machine running several sessions at once it
#   is also a COMMON one, so a consumer must expect `unknown` routinely rather
#   than treating it as an incident.
#
#   The observation LOG is unaffected: every reading from every session is
#   appended, so the evidence series that has to answer the characterization
#   question in budget-source-probe.md §"Probe 0" is complete regardless.
#
#   A per-session map would fix the verdict slot, at the cost of unbounded
#   growth in a hot state file and a pruning race. Not built here: the issue
#   scopes verdict CONSUMPTION to a separate change, and that is where the
#   requirement (if any) belongs.
#
# DEGRADATION CONTRACT (fail closed — mirrors credit-budget.sh)
#   Every one of these produces STATUS=unknown and exit 3, never `clear`:
#     - no state file, or the state file does not parse
#     - no `usage_horizon` reading recorded at all
#     - the stored reading belongs to a different session
#     - the stored reading is older than the configured TTL
#     - the stored timestamp cannot be parsed, names an impossible calendar
#       date, or is otherwise unreadable (an age that cannot be computed is stale)
#     - a stored value (remaining/limit/status) has the wrong shape, or is one
#       `--observe` would itself have refused: a negative, fractional, or
#       >=1e12 token count, a non-positive limit, or remaining above limit
#     - jq is missing or fails
#     - the session identity cannot be resolved
#
# FILES
#   ~/.claude/usage-horizon.jsonl  observation log, mode 600, single-generation
#                                  rotation at 256 KiB (override the directory
#                                  with CLAUDE_USAGE_HORIZON_DIR). The evidence
#                                  source for characterizing what the counter
#                                  actually tracks across sessions and resets.
#   ~/.claude/session-state.json   `.usage_horizon` — last reading + verdict.
#
# DEPENDENCIES
#   - jq
#   - session-state.sh (sibling; --observe only)
#   - shasum or sha256sum (only when no explicit/env session id is available)

set -euo pipefail
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" \
  2>/dev/null >> "$HOME/.claude/script-usage.log" || true

SELF_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_FILE="${HOME}/.claude/session-state.json"
mkdir -p "$(dirname "$STATE_FILE")" 2>/dev/null || true

_HORIZON_DIR="${CLAUDE_USAGE_HORIZON_DIR:-${HOME}/.claude}"
OBS_LOG="${_HORIZON_DIR}/usage-horizon.jsonl"
LOCK_DIR="${_HORIZON_DIR}/.usage-horizon.lock"
LOG_MAX_SIZE=262144 # 256 KiB, then rotate to .1

DEFAULT_APPROACHING_PCT=25
DEFAULT_CRITICAL_PCT=10
DEFAULT_FLOOR_TOKENS=2000000
DEFAULT_HYSTERESIS_PCT=3
DEFAULT_TTL_SECONDS=1800

# Accepted magnitude for every token-valued input. 12 digits (< 1e12) leaves
# four orders of magnitude of headroom over the counters observed in the wild
# while keeping the widest product the threshold arithmetic forms
# (`limit * percent`, at most 1e14) far inside 64-bit signed range, so a
# threshold can never silently wrap. A longer digit string is rejected as
# malformed rather than truncated.
TOKEN_RE='^(0|[1-9][0-9]{0,11})$'

EXIT_CLEAR=0
EXIT_APPROACHING=1
EXIT_CRITICAL=2
EXIT_UNKNOWN=3
EXIT_USAGE=4
EXIT_WRITE=5
EXIT_LOCK=6

print_help() {
  sed -n '/^# PURPOSE$/,/^# DEPENDENCIES$/p' "$0" | sed 's/^# \{0,1\}//'
}

die_usage() {
  echo "usage-horizon.sh: $1" >&2
  echo "Run with --help for usage." >&2
  exit "$EXIT_USAGE"
}

# emit <status> <reason> — the entire stdout contract, in one place so no code
# path can print a verdict without also printing why.
emit() {
  printf 'STATUS=%s\n' "$1"
  printf 'REASON=%s\n' "$2"
}

# unknown <reason> <diagnostic> — the single fail-closed exit. Every degraded
# path routes through here, which is what makes "unknown is never clear" a
# property of the code rather than a convention.
unknown() {
  echo "usage-horizon.sh: $2" >&2
  emit unknown "$1"
  exit "$EXIT_UNKNOWN"
}

# --- arg parsing ---------------------------------------------------------------
MODE=""
OBS_REMAINING=""
OBS_LIMIT=""
SESSION_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      print_help
      exit 0
      ;;
    --observe)
      [[ -n "$MODE" ]] && die_usage "only one of --observe, --check may be given"
      [[ $# -lt 2 ]] && die_usage "--observe requires a remaining-token value"
      MODE="observe"
      OBS_REMAINING="$2"
      shift 2
      ;;
    --check)
      [[ -n "$MODE" ]] && die_usage "only one of --observe, --check may be given"
      MODE="check"
      shift
      ;;
    --limit)
      [[ $# -lt 2 ]] && die_usage "--limit requires a value"
      OBS_LIMIT="$2"
      shift 2
      ;;
    --session)
      [[ $# -lt 2 ]] && die_usage "--session requires a value"
      SESSION_OVERRIDE="$2"
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

[[ -z "$MODE" ]] && die_usage "one of --observe, --check is required"
[[ "$MODE" == "check" && -n "$OBS_LIMIT" ]] && die_usage "--limit applies to --observe only"

# --- dependency check ----------------------------------------------------------
# jq missing is an environment failure, not permission. --check degrades to the
# fail-closed verdict; --observe cannot record without it.
if ! command -v jq >/dev/null 2>&1; then
  if [[ "$MODE" == "check" ]]; then
    unknown jq-missing "jq not found on PATH; cannot read stored reading"
  fi
  echo "usage-horizon.sh: 'jq' not found on PATH" >&2
  exit "$EXIT_WRITE"
fi

# --- session identity ----------------------------------------------------------
# Order: --session, $CLAUDE_SESSION_ID, then a digest of the nearest ancestor
# `claude` process. The ancestor walk (rather than $PPID) is what survives the
# varying shell depth between Bash tool calls, documented at length in
# .claude/skills/issue-maker/scripts/resolve-log.sh. The digest is a pure
# function of that identity, so it needs no marker file to stay stable.
sanitize_session() {
  printf '%s' "$1" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_'
}

digest20() {
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print substr($1,1,20)}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print substr($1,1,20)}'
  else
    return 1
  fi
}

# Nearest ancestor process literally named `claude`. Case-sensitive on purpose:
# the desktop app higher in the chain is `Claude` and is shared across
# conversations, so matching it would merge two sessions into one identity.
claude_ancestor_identity() {
  local pid line ppid comm base start depth
  pid="${PPID:-0}"
  depth=0
  while [[ "$depth" -lt 24 ]]; do
    case "$pid" in ''|0|1) return 0 ;; esac
    line="$(ps -o ppid=,comm= -p "$pid" 2>/dev/null)" || line=""
    [[ -n "$line" ]] || return 0
    ppid="$(printf '%s' "$line" | awk '{print $1}')"
    comm="$(printf '%s' "$line" | awk '{$1=""; sub(/^[ \t]+/, ""); print}')"
    base="${comm##*/}"
    if [[ "$base" == "claude" ]]; then
      start="$(ps -o lstart= -p "$pid" 2>/dev/null | tr -s ' ' || true)"
      printf 'claude=%s|start=%s' "$pid" "$start"
      return 0
    fi
    pid="$ppid"
    depth=$((depth + 1))
  done
  return 0
}

resolve_session_id() {
  local raw="${SESSION_OVERRIDE:-${CLAUDE_SESSION_ID:-}}"
  local key=""
  if [[ -n "$raw" ]]; then
    key="$(sanitize_session "$raw")"
    # An id made only of separators sanitizes to a non-empty but meaningless
    # key; treat it as absent rather than letting two such ids collide.
    case "$key" in
      *[A-Za-z0-9]*) printf '%s' "$key"; return 0 ;;
      *) key="" ;;
    esac
  fi
  local ident
  ident="$(claude_ancestor_identity)"
  [[ -n "$ident" ]] || ident="ppid=${PPID:-0}|start=$(ps -o lstart= -p "${PPID:-0}" 2>/dev/null | tr -s ' ' || true)"
  local dg
  dg="$(digest20 "$ident")" || return 1
  [[ -n "$dg" ]] || return 1
  printf 'derived-%s' "$dg"
}

SESSION_ID=""
if ! SESSION_ID="$(resolve_session_id)" || [[ -z "$SESSION_ID" ]]; then
  if [[ "$MODE" == "check" ]]; then
    unknown session-unresolvable \
      "could not resolve a session identity (no --session, no CLAUDE_SESSION_ID, no SHA-256 tool)"
  fi
  echo "usage-horizon.sh: could not resolve a session identity; refusing to record against a shared key" >&2
  exit "$EXIT_WRITE"
fi

# --- configuration -------------------------------------------------------------
# Precedence: env override -> pm-config.md `## Budget` -> hardcoded default.
# The Budget section is read ONCE and every knob parsed from that one capture.
BUDGET_SECTION=""
BUDGET_SECTION_LOADED=0

load_budget_section() {
  [[ $BUDGET_SECTION_LOADED -eq 1 ]] && return 0
  BUDGET_SECTION_LOADED=1
  local getter="$SELF_DIR/pm-config-get.sh"
  [[ -x "$getter" ]] || return 0
  local root=""
  if [[ -x "$SELF_DIR/repo-root.sh" ]]; then
    root="$("$SELF_DIR/repo-root.sh" 2>/dev/null)" || root=""
  fi
  [[ -n "$root" ]] || return 0
  local config="$root/.claude/pm-config.md"
  [[ -r "$config" ]] || return 0
  BUDGET_SECTION="$("$getter" --section "Budget" --file "$config" 2>/dev/null)" || BUDGET_SECTION=""
  return 0
}

# config_value <ini_key> — print the value of `key = value` from the Budget
# section, or nothing. Comments and surrounding whitespace are stripped.
config_value() {
  load_budget_section
  [[ -n "$BUDGET_SECTION" ]] || return 0
  printf '%s\n' "$BUDGET_SECTION" | awk -v key="$1" '
    {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      split(line, parts, /[=:]/)
      k = parts[1]
      sub(/[[:space:]]+$/, "", k)
      if (tolower(k) != tolower(key)) next
      sub(/^[^=:]*[=:][[:space:]]*/, "", line)
      sub(/[[:space:]]+#.*$/, "", line)
      sub(/[[:space:]]*$/, "", line)
      print line
      exit
    }'
}

# resolve_knob <ini_key> <env_var_name> <default> <validation_regex>
# A value that fails validation is reported and replaced by the default: a
# typo in a config file must not silently disable the gate, and it must not
# abort a session either.
resolve_knob() {
  local ini_key="$1" env_name="$2" default="$3" re="$4"
  local val="${!env_name:-}"
  local origin="env $env_name"
  if [[ -z "$val" ]]; then
    val="$(config_value "$ini_key")"
    origin="pm-config.md $ini_key"
  fi
  if [[ -z "$val" ]]; then
    printf '%s' "$default"
    return 0
  fi
  if ! [[ "$val" =~ $re ]]; then
    echo "usage-horizon.sh: invalid value '${val}' from ${origin}; using default ${default}" >&2
    printf '%s' "$default"
    return 0
  fi
  printf '%s' "$val"
}

PCT_RE='^(0|[1-9][0-9]?|100)$'

TTL_SECONDS="$(resolve_knob usage_horizon_reading_ttl_s \
  CLAUDE_USAGE_HORIZON_TTL_SECONDS "$DEFAULT_TTL_SECONDS" '^[1-9][0-9]{0,8}$')"

# --- timestamps ----------------------------------------------------------------
# Fail-closed ISO-8601 -> epoch. Implemented in awk with the civil-from-days
# algorithm (the shape issue-claim.sh uses) rather than a `date -j` / `date -d`
# fallback chain: it is identical on BSD and GNU, and an input it cannot parse
# produces EMPTY OUTPUT, which the caller treats as "older than any TTL".
# escalate-review.sh's fail-open age helper is deliberately not reused here.
iso_to_epoch() {
  local ts="$1"
  [[ -z "$ts" ]] && { printf ''; return 0; }
  printf '%s' "$ts" | awk '
    match($0, /^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})Z?$/) {
      y = substr($0,1,4)+0; mo = substr($0,6,2)+0; d = substr($0,9,2)+0
      h = substr($0,12,2)+0; mi = substr($0,15,2)+0; s = substr($0,18,2)+0
      if (mo < 1 || mo > 12 || d < 1) next
      if (h > 23 || mi > 59 || s > 60) next
      # The day must exist in THAT month. A range-only `d > 31` check would let
      # an impossible date through: civil-from-days is total, so 2026-02-31
      # would not fail — it would silently become 2026-03-03, an invented epoch
      # the freshness gate would then age as if it were a real reading.
      split("31 28 31 30 31 30 31 31 30 31 30 31", mlen, " ")
      dmax = mlen[mo]
      if (mo == 2 && y % 4 == 0 && (y % 100 != 0 || y % 400 == 0)) dmax = 29
      if (d > dmax) next
      yy = y - (mo <= 2 ? 1 : 0)
      era = int((yy >= 0 ? yy : yy - 399) / 400)
      yoe = yy - era * 400
      doy = int((153 * (mo + (mo > 2 ? -3 : 9)) + 2) / 5) + d - 1
      doe = yoe * 365 + int(yoe/4) - int(yoe/100) + doy
      days = era * 146097 + doe - 719468
      print days * 86400 + h * 3600 + mi * 60 + s
    }'
}

# --- state read ----------------------------------------------------------------
# Read-only, lock-free, exactly like credit-budget.sh's read_state(). Returns
# non-zero when the file is absent or does not parse, so the caller can tell
# "nothing recorded yet" from "state unreadable" without inspecting the payload.
read_horizon_state() {
  [[ -f "$STATE_FILE" ]] || return 3
  jq -e . "$STATE_FILE" >/dev/null 2>&1 || return 4
  jq -c '.usage_horizon // null' "$STATE_FILE" 2>/dev/null || return 4
}

# prior_reading_is_fresh <horizon-json> — true when the stored reading is still
# inside the TTL, using the SAME window --check applies: a future timestamp is
# as untrustworthy as a stale one, and an age that cannot be computed is stale.
# Both modes must agree on which readings are still alive, because a reading
# --check already calls `unknown` is not a level (see HYSTERESIS above) and so
# must not anchor a new verdict either.
prior_reading_is_fresh() {
  local ts epoch now age
  ts="$(printf '%s' "$1" | jq -r '.reading.ts // ""' 2>/dev/null)" || return 1
  epoch="$(iso_to_epoch "$ts")"
  [[ -n "$epoch" ]] || return 1
  now="$(date -u +%s 2>/dev/null)" || return 1
  [[ "$now" =~ ^[0-9]+$ ]] || return 1
  age=$(( now - epoch ))
  (( age >= 0 && age <= TTL_SECONDS ))
}

# --- verdict arithmetic --------------------------------------------------------
# severity_rank <status> — ordering used to decide whether a raw verdict is a
# worsening (applied immediately) or an improvement (must clear hysteresis).
severity_rank() {
  case "$1" in
    critical) printf '3' ;;
    approaching) printf '2' ;;
    clear) printf '1' ;;
    *) printf '0' ;;
  esac
}

# compute_verdict <remaining> <limit-or-empty> <prior-status>
#
# Both modes compare in TOKEN space, so a boundary is exact: the percentage
# knobs are converted into a token threshold (limit * pct / 100) rather than
# the reading being converted into a percentage. Converting the reading
# instead would quantize it — at a 15,000,000-token window a whole percentage
# point spans 150,000 tokens, so a reading one token above the threshold would
# round back onto it and read as approaching. Floor mode works in the same
# space already, with the critical threshold and the hysteresis margin scaled
# off the single absolute knob by the ratio the percentage knobs express — one
# knob, same severity ordering, no second floor to keep in sync.
#
# Hysteresis is applied by RAISING the entry thresholds for bands the prior
# verdict already occupies. A more severe band is therefore entered at its
# nominal threshold (immediate), while leaving a band requires exceeding that
# band's threshold by the margin (sticky).
compute_verdict() {
  local remaining="$1" limit="$2" prior="$3"
  local approaching_pct critical_pct hysteresis_pct floor_tokens

  approaching_pct="$(resolve_knob usage_horizon_approaching_pct \
    CLAUDE_USAGE_HORIZON_APPROACHING_PCT "$DEFAULT_APPROACHING_PCT" "$PCT_RE")"
  critical_pct="$(resolve_knob usage_horizon_critical_pct \
    CLAUDE_USAGE_HORIZON_CRITICAL_PCT "$DEFAULT_CRITICAL_PCT" "$PCT_RE")"
  hysteresis_pct="$(resolve_knob usage_horizon_hysteresis_pct \
    CLAUDE_USAGE_HORIZON_HYSTERESIS_PCT "$DEFAULT_HYSTERESIS_PCT" "$PCT_RE")"
  floor_tokens="$(resolve_knob usage_horizon_floor_tokens \
    CLAUDE_USAGE_HORIZON_FLOOR_TOKENS "$DEFAULT_FLOOR_TOKENS" "$TOKEN_RE")"

  # An inverted or degenerate pair would make `critical` unreachable or make
  # every reading critical. Fall back to the shipped defaults and say so
  # rather than emitting a verdict from a nonsensical configuration.
  if (( critical_pct >= approaching_pct )) || (( approaching_pct == 0 )); then
    echo "usage-horizon.sh: critical_pct (${critical_pct}) must be below approaching_pct (${approaching_pct}); using defaults ${DEFAULT_CRITICAL_PCT}/${DEFAULT_APPROACHING_PCT}" >&2
    approaching_pct="$DEFAULT_APPROACHING_PCT"
    critical_pct="$DEFAULT_CRITICAL_PCT"
  fi

  local prior_rank
  prior_rank="$(severity_rank "$prior")"

  local eff_critical eff_approaching value
  value="$remaining"
  if [[ -n "$limit" ]]; then
    eff_critical=$(( limit * critical_pct / 100 ))
    eff_approaching=$(( limit * approaching_pct / 100 ))
    local margin=$(( limit * hysteresis_pct / 100 ))
    (( prior_rank >= 3 )) && eff_critical=$(( eff_critical + margin ))
    (( prior_rank >= 2 )) && eff_approaching=$(( eff_approaching + margin ))
  else
    eff_approaching="$floor_tokens"
    eff_critical=$(( floor_tokens * critical_pct / approaching_pct ))
    local margin=$(( floor_tokens * hysteresis_pct / approaching_pct ))
    (( prior_rank >= 3 )) && eff_critical=$(( eff_critical + margin ))
    (( prior_rank >= 2 )) && eff_approaching=$(( eff_approaching + margin ))
  fi

  if (( value <= eff_critical )); then
    printf 'critical'
  elif (( value <= eff_approaching )); then
    printf 'approaching'
  else
    printf 'clear'
  fi
}

# --- observation log -----------------------------------------------------------
file_size() {
  if [[ "$(uname -s)" == "Darwin" ]]; then
    stat -f %z "$1" 2>/dev/null
  else
    stat -c %s "$1" 2>/dev/null
  fi
}

# mkdir is the portable atomic mutex — macOS ships no flock(1). The wait is
# bounded; a lock that cannot be taken is a hard failure here rather than an
# unlocked append, because an unserialized rotation can discard history.
take_log_lock() {
  local _
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if mkdir "$LOCK_DIR" 2>/dev/null; then
      return 0
    fi
    # Reap a lock orphaned by a killed process (mtime older than a minute).
    if [[ -n "$(find "$LOCK_DIR" -maxdepth 0 -mmin +1 2>/dev/null)" ]]; then
      rmdir "$LOCK_DIR" 2>/dev/null || true
      continue
    fi
    sleep 0.1
  done
  return 1
}

append_observation() { # $1 = one-line JSON record
  local record="$1"
  if ! take_log_lock; then
    echo "usage-horizon.sh: could not acquire the observation-log lock at $LOCK_DIR" >&2
    return "$EXIT_LOCK"
  fi
  # shellcheck disable=SC2064
  trap "rmdir '$LOCK_DIR' 2>/dev/null || true" EXIT

  local size record_bytes
  size="$(file_size "$OBS_LOG")"
  [[ -n "$size" ]] || size=0
  # Byte count, not ${#record}: a character count would under-measure multibyte
  # UTF-8 and defer rotation past the cap.
  record_bytes="$(printf '%s\n' "$record" | wc -c | tr -d '[:space:]')"
  [[ "$record_bytes" =~ ^[0-9]+$ ]] || record_bytes=${#record}
  if [[ -f "$OBS_LOG" ]] && (( size + record_bytes >= LOG_MAX_SIZE )); then
    # A rotation that cannot happen must not pass as one. The append below still
    # runs on failure — dropping an authoritative reading is worse than an
    # oversized log — but the log is then past its documented bound, so say so
    # instead of swallowing it. Only the `mv` verdict is reported: `rm -f` on an
    # absent `.1` is a success, and its failure alone is harmless because the
    # `mv` that follows either overwrites `.1` anyway or fails and is caught here.
    rm -f "${OBS_LOG}.1" 2>/dev/null || true
    if ! mv "$OBS_LOG" "${OBS_LOG}.1" 2>/dev/null; then
      echo "usage-horizon.sh: could not rotate $OBS_LOG to ${OBS_LOG}.1; the log will exceed its ${LOG_MAX_SIZE}-byte bound" >&2
    fi
  fi

  if ! printf '%s\n' "$record" >> "$OBS_LOG" 2>/dev/null; then
    echo "usage-horizon.sh: could not append to $OBS_LOG" >&2
    return "$EXIT_WRITE"
  fi
  # umask only constrains newly created files; tighten anything an earlier run
  # left behind so the log is owner-only on a shared machine.
  chmod 600 "$OBS_LOG" 2>/dev/null || true

  # Release before returning rather than leaving it to the EXIT trap: the
  # caller goes on to write session-state, and holding this lock across that
  # write would serialize concurrent sessions on a lock neither of them needs
  # by then. The trap stays armed for the error returns above.
  rmdir "$LOCK_DIR" 2>/dev/null || true
  trap - EXIT
  return 0
}

# --- dispatch ------------------------------------------------------------------
case "$MODE" in
  observe)
    [[ "$OBS_REMAINING" =~ $TOKEN_RE ]] || \
      die_usage "--observe requires a non-negative integer below 1e12, got: $OBS_REMAINING"
    if [[ -n "$OBS_LIMIT" ]]; then
      [[ "$OBS_LIMIT" =~ $TOKEN_RE ]] || \
        die_usage "--limit requires a non-negative integer below 1e12, got: $OBS_LIMIT"
      # A zero total is not a denominator, and a reading claiming more runway
      # than the window holds is incoherent. Both are caller errors, refused
      # here rather than turned into a verdict.
      (( OBS_LIMIT > 0 )) || die_usage "--limit must be greater than zero"
      (( OBS_REMAINING <= OBS_LIMIT )) || \
        die_usage "--observe value ($OBS_REMAINING) exceeds --limit ($OBS_LIMIT)"
    fi

    NOW_TS="$(date -u +'%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)" || NOW_TS=""
    [[ -n "$NOW_TS" ]] || {
      echo "usage-horizon.sh: could not read the current time; refusing to record an undatable reading" >&2
      exit "$EXIT_WRITE"
    }

    # Prior verdict for hysteresis. It anchors the new verdict ONLY when the
    # previous reading came from this same session AND is still inside the TTL:
    # another session's level is not this session's runway, and a prior
    # `unknown` is not a level at all. The TTL half matters as much as the
    # session half — a reading past the TTL is precisely what --check reports as
    # `unknown`/`reading-stale`, so letting it anchor here would let a verdict
    # this script has already declared dead drag a fresh reading into a more
    # severe band (an hour-old `critical` holding a healthy reading at
    # `approaching`).
    PRIOR_STATUS=""
    PRIOR_RAW=""
    if PRIOR_RAW="$(read_horizon_state)"; then
      PRIOR_SESSION="$(printf '%s' "$PRIOR_RAW" | jq -r '.reading.session_id // ""' 2>/dev/null)" || PRIOR_SESSION=""
      if [[ "$PRIOR_SESSION" == "$SESSION_ID" ]] && prior_reading_is_fresh "$PRIOR_RAW"; then
        PRIOR_STATUS="$(printf '%s' "$PRIOR_RAW" | jq -r '.status // ""' 2>/dev/null)" || PRIOR_STATUS=""
      fi
    fi
    case "$PRIOR_STATUS" in
      clear|approaching|critical) ;;
      *) PRIOR_STATUS="" ;;
    esac

    VERDICT="$(compute_verdict "$OBS_REMAINING" "$OBS_LIMIT" "$PRIOR_STATUS")"

    # `--argjson limit` carries a real JSON null when no limit was supplied, so
    # the record shape is `{ts, session_id, remaining, limit}` with limit null
    # rather than a string "null" a reader would have to special-case.
    LIMIT_JSON="null"
    [[ -n "$OBS_LIMIT" ]] && LIMIT_JSON="$OBS_LIMIT"

    RECORD="$(jq -nc \
      --arg ts "$NOW_TS" \
      --arg session_id "$SESSION_ID" \
      --argjson remaining "$OBS_REMAINING" \
      --argjson limit "$LIMIT_JSON" \
      '{ts: $ts, session_id: $session_id, remaining: $remaining, limit: $limit}')" || {
      echo "usage-horizon.sh: jq failed building the observation record" >&2
      exit "$EXIT_WRITE"
    }

    # Owner-only: the log carries session identifiers and account runway.
    umask 077
    mkdir -p "$_HORIZON_DIR" 2>/dev/null || true
    APPEND_RC=0
    append_observation "$RECORD" || APPEND_RC=$?
    if [[ $APPEND_RC -ne 0 ]]; then
      exit "$APPEND_RC"
    fi

    HORIZON_JSON="$(jq -nc \
      --argjson reading "$RECORD" \
      --arg status "$VERDICT" \
      --arg status_at "$NOW_TS" \
      '{reading: $reading, status: $status, status_at: $status_at, source: "observed"}')" || {
      echo "usage-horizon.sh: jq failed building the session-state payload" >&2
      exit "$EXIT_WRITE"
    }

    SESSION_STATE_SH="$SELF_DIR/session-state.sh"
    if [[ ! -x "$SESSION_STATE_SH" ]]; then
      echo "usage-horizon.sh: missing sibling helper: $SESSION_STATE_SH" >&2
      exit "$EXIT_WRITE"
    fi

    # One --set call carries the whole object, so reading and verdict can never
    # land in the state file as two half-applied writes. Exit 6 is the shared
    # lock-timeout code: retry once, then surface it rather than writing
    # unserialized (session-state.sh never does, and neither may we).
    SET_RC=0
    "$SESSION_STATE_SH" --set ".usage_horizon=$HORIZON_JSON" >/dev/null 2>&1 || SET_RC=$?
    if [[ $SET_RC -eq 6 ]]; then
      SET_RC=0
      "$SESSION_STATE_SH" --set ".usage_horizon=$HORIZON_JSON" >/dev/null 2>&1 || SET_RC=$?
      if [[ $SET_RC -eq 6 ]]; then
        echo "usage-horizon.sh: session-state.sh lock timeout; reading appended to $OBS_LOG but not persisted to session-state" >&2
        exit "$EXIT_LOCK"
      fi
    fi
    if [[ $SET_RC -ne 0 ]]; then
      echo "usage-horizon.sh: session-state.sh failed (exit $SET_RC); reading appended to $OBS_LOG but not persisted to session-state" >&2
      exit "$EXIT_WRITE"
    fi

    emit "$VERDICT" recorded
    exit 0
    ;;

  check)
    STATE_RC=0
    HORIZON_RAW="$(read_horizon_state)" || STATE_RC=$?
    if [[ $STATE_RC -eq 3 ]]; then
      unknown no-state-file "no session-state file at $STATE_FILE"
    elif [[ $STATE_RC -ne 0 ]]; then
      unknown state-unreadable "$STATE_FILE is missing, unreadable, or does not parse as JSON"
    fi
    if [[ -z "$HORIZON_RAW" || "$HORIZON_RAW" == "null" ]]; then
      unknown no-reading "no usage_horizon reading has been recorded"
    fi

    READ_SESSION="$(printf '%s' "$HORIZON_RAW" | jq -r '.reading.session_id // ""' 2>/dev/null)" || \
      unknown reading-malformed "stored usage_horizon does not parse"
    if [[ -z "$READ_SESSION" ]]; then
      unknown reading-malformed "stored reading carries no session_id"
    fi
    if [[ "$READ_SESSION" != "$SESSION_ID" ]]; then
      unknown no-reading-this-session \
        "stored reading belongs to session $READ_SESSION, not $SESSION_ID"
    fi

    # Shape check before any value is trusted. This mirrors every constraint
    # --observe enforces on the way in (TOKEN_RE plus the limit-consistency
    # rules), because `type == "number"` alone is a strictly weaker gate than
    # the writer's: it admits negatives, fractions, values at or above 1e12,
    # and a `remaining` exceeding its own `limit`. Since --check trusts the
    # stored verdict rather than recomputing it, a value the writer would have
    # refused must not be able to arrive carrying `status: clear`. Reading and
    # writing therefore accept exactly the same set.
    SHAPE_OK="$(printf '%s' "$HORIZON_RAW" | jq -r '
      def tokenish: (type == "number") and (. == floor) and (. >= 0) and (. < 1e12);
      (.reading.remaining as $r
       | .reading.limit as $l
       | ($r | tokenish)
         and (($l == null)
              or (($l | tokenish) and ($l > 0) and ($r <= $l))))
      | tostring' 2>/dev/null)" || SHAPE_OK="false"
    if [[ "$SHAPE_OK" != "true" ]]; then
      unknown reading-malformed \
        "stored remaining/limit is not the non-negative integer below 1e12 that --observe accepts, or remaining exceeds limit"
    fi

    STORED_STATUS="$(printf '%s' "$HORIZON_RAW" | jq -r '.status // ""' 2>/dev/null)" || STORED_STATUS=""
    case "$STORED_STATUS" in
      clear|approaching|critical) ;;
      *)
        unknown status-malformed "stored verdict is not one of clear/approaching/critical (got: ${STORED_STATUS:-<empty>})"
        ;;
    esac

    READ_TS="$(printf '%s' "$HORIZON_RAW" | jq -r '.reading.ts // ""' 2>/dev/null)" || READ_TS=""
    READ_EPOCH="$(iso_to_epoch "$READ_TS")"
    if [[ -z "$READ_EPOCH" ]]; then
      # An age that cannot be computed is treated as older than any TTL. This
      # is the whole point of not reusing a fail-open age helper.
      unknown timestamp-unparseable "stored reading timestamp is unparseable (got: ${READ_TS:-<empty>})"
    fi
    NOW_EPOCH="$(date -u +%s 2>/dev/null)" || NOW_EPOCH=""
    if [[ -z "$NOW_EPOCH" || ! "$NOW_EPOCH" =~ ^[0-9]+$ ]]; then
      unknown timestamp-unparseable "could not read the current time to age the stored reading"
    fi
    AGE=$(( NOW_EPOCH - READ_EPOCH ))
    # A reading stamped in the future is as untrustworthy as a stale one: a
    # negative age would otherwise pass every TTL comparison forever.
    if (( AGE < 0 )); then
      unknown reading-stale "stored reading is timestamped ${AGE}s in the future"
    fi
    if (( AGE > TTL_SECONDS )); then
      unknown reading-stale "stored reading is ${AGE}s old, past the ${TTL_SECONDS}s TTL"
    fi

    # Resolve the exit code BEFORE emitting, with a `*)` arm that cannot fall
    # through. Written this way on purpose: a `case` that emits first and then
    # selects an exit code would, on an unmatched value, print a verdict and
    # then run off the end of the script — exiting 0, which is `clear`. The
    # value is already validated above, so this arm is unreachable today; it
    # exists so that a future edit to the validation cannot silently turn a
    # degraded reading into permission.
    VERDICT_RC=""
    case "$STORED_STATUS" in
      clear) VERDICT_RC="$EXIT_CLEAR" ;;
      approaching) VERDICT_RC="$EXIT_APPROACHING" ;;
      critical) VERDICT_RC="$EXIT_CRITICAL" ;;
      *) unknown status-malformed "stored verdict has no exit-code mapping (got: $STORED_STATUS)" ;;
    esac
    emit "$STORED_STATUS" reading-fresh
    exit "$VERDICT_RC"
    ;;
esac
