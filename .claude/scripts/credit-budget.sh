#!/usr/bin/env bash
# credit-budget.sh — Daily Anthropic credit budget guard (issue #1289).
#
# PURPOSE
#   Evaluate the daily autonomous-dispatch credit budget against authoritative
#   usage signals only. Never computes or consults a local token/dollar
#   estimate. Reads the harness overage/limit signal written by
#   `.claude/hooks/usage-limit-record.sh`, tracks per-ET-day budget state in
#   ~/.claude/session-state.json (global top-level `credit_budget` field), and
#   exits with a stable code that dispatch logic treats as fail-closed.
#
#   Probe order and degradation contract: `.claude/reference/budget-source-probe.md`
#   Safety rule: `.claude/rules/safety.md` §"Anthropic Quota & Spend Authority"
#
#   Governs Anthropic credit spend ONLY. Third-party reviewer-tool costs are
#   tracked in pricing-matrix.md / spend-telemetry-pipeline.md.
#
# USAGE
#   credit-budget.sh --check  [--budget N]
#   credit-budget.sh --reset  [--budget N]
#   credit-budget.sh --help | -h
#
# MODES
#   --check    Probe authoritative signals, update per-day state if needed,
#              print JSON result on stdout. Exit 0 (ok), 1 (reached), or
#              2 (unknown) per the dispatch table below.
#   --reset    Force-clear today's `reached` state back to `ok`. Useful after
#              a manual account review confirms budget is actually available.
#              Prints the post-reset JSON. Exits 0.
#
# FLAGS
#   --budget N  Override daily_credit_budget_usd for this invocation only.
#               Must be a non-negative number. Does not write back to config.
#
# OUTPUT
#   stdout: single-line JSON — {"date":"YYYY-MM-DD","status":"ok|reached|unknown",
#           "budget_usd": N, "source": "<reason string>"}
#   stderr: one-line diagnostic on any failure.
#
# EXIT STATUS (the dispatch gate; unreadable state is never permission)
#   0  ok      — no authoritative overage signal today; dispatch may proceed
#   1  reached — authoritative overage signal found this ET day; park
#   2  unknown — probe failed or state unreadable; conservative posture
#   3  Usage error (missing/invalid mode, unknown flag)
#   5  Write failed (jq parse error, mv failed, disk full)
#   6  Lock timeout (CLAUDE_STATE_LOCK_TIMEOUT; nothing written)
#   70  --help header extraction produced no output (internal defect).
#
# AUTHORITATIVE PROBE (Probe 1 only — see budget-source-probe.md)
#   Reads ~/.claude/usage-limit-events.jsonl (written by usage-limit-record.sh
#   on StopFailure error == "rate_limit") and looks for an event, recorded
#   within the current ET calendar day, that is an OVERAGE.
#
#   WHICH EVENTS COUNT (issue #1633)
#     `reason == "rate_limit"` says a limit was hit; it does NOT say which one.
#     A plan-window wall (rolling 5-hour or weekly) is the OPPOSITE of a credit
#     overage: it means the account is on plan and paid nothing per token.
#     Counting one as the other is how four weekly-limit hits before 07:15Z on
#     2026-09-04 froze autonomous dispatch for the entire day, reporting a $25
#     credit budget as spent when nothing had been spent.
#
#     So an event gates only when BOTH hold:
#       1. its kind is `overage` — read from the `limit_kind` field the
#          recorder writes, or, for legacy records lacking it, classified from
#          `last_assistant_message` through the SAME library the recorder uses
#          (lib/usage-limit-classify.sh — the prose is parsed in one place); and
#       2. its reset time, when one is known, has not yet passed. A window that
#          has already reopened never gates, whatever its kind.
#
#     `plan_window` and `unclassified` events never gate. This probe exists to
#     detect overage; an event not classified as one is not evidence of credit
#     spend. The conservative fail-closed posture stays where it belongs — on
#     UNREADABLE signal state, which still reports `unknown` (exit 2).
#
#   No local token/dollar math is performed at any point in this script.
#
# ATOMICITY
#   All writes use jq + temp-file + mv, serialized through state-lock.sh.
#
# DEPENDENCIES
#   - jq
#   - state-lock.sh (sibling library)
#   - lib/usage-limit-classify.sh (sibling library; the ONE parser of limit prose)

set -euo pipefail
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" \
  2>/dev/null >> "$HOME/.claude/script-usage.log" || true

STATE_FILE="${HOME}/.claude/session-state.json"
# Ensure the state directory exists before any read or write attempt.
mkdir -p "$(dirname "$STATE_FILE")" 2>/dev/null || true
# Mirror the hook's configurable event directory so the two always agree on
# where overage events are written (usage-limit-record.sh §CLAUDE_USAGE_LIMIT_DIR).
_USAGE_LIMIT_DIR="${CLAUDE_USAGE_LIMIT_DIR:-${HOME}/.claude}"
EVENTS_LOG="${_USAGE_LIMIT_DIR}/usage-limit-events.jsonl"
DEFAULT_BUDGET_USD=25

# Shared session-state write lock (mirrors greptile-budget.sh pattern).
SELF_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ ! -f "$SELF_DIR/state-lock.sh" || ! -r "$SELF_DIR/state-lock.sh" ]]; then
  echo "credit-budget.sh: missing sibling library: $SELF_DIR/state-lock.sh" >&2
  exit 5
fi
# shellcheck source=./state-lock.sh
if ! source "$SELF_DIR/state-lock.sh"; then
  echo "credit-budget.sh: failed to load $SELF_DIR/state-lock.sh" >&2
  exit 5
fi

# Shared usage-limit classifier (issue #1633). REQUIRED here, unlike in the
# recorder: without it this script cannot tell a plan-window wall from a credit
# overage, and the only two ways to proceed would be to gate on every
# rate_limit event (the #1633 defect) or on none (a gate that never fires).
# Failing loudly is the honest third option.
if [[ ! -f "$SELF_DIR/lib/usage-limit-classify.sh" || ! -r "$SELF_DIR/lib/usage-limit-classify.sh" ]]; then
  echo "credit-budget.sh: missing sibling library: $SELF_DIR/lib/usage-limit-classify.sh" >&2
  exit 5
fi
# shellcheck source=./lib/usage-limit-classify.sh
if ! source "$SELF_DIR/lib/usage-limit-classify.sh"; then
  echo "credit-budget.sh: failed to load $SELF_DIR/lib/usage-limit-classify.sh" >&2
  exit 5
fi

# --- helpers ---

print_help() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; n = 1; next } { exit } END { exit(n ? 0 : 1) }' "$0" ||
    { printf '%s: --help header extraction produced no output\n' "$0" >&2; exit 70; }
}

die_usage() {
  echo "credit-budget.sh: $1" >&2
  echo "Run with --help for usage." >&2
  exit 3
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
    --check|--reset)
      [[ -n "$MODE" ]] && die_usage "only one of --check, --reset may be given"
      MODE="${1#--}"
      shift
      ;;
    --budget)
      [[ $# -lt 2 ]] && die_usage "--budget requires a value"
      BUDGET_OVERRIDE="$2"
      if ! [[ "$BUDGET_OVERRIDE" =~ ^(0|[1-9][0-9]*)(\.[0-9]+)?$ ]]; then
        die_usage "--budget must be a non-negative number, got: $BUDGET_OVERRIDE"
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

[[ -z "$MODE" ]] && die_usage "one of --check, --reset is required"

# --- dependency check ---
if ! command -v jq >/dev/null 2>&1; then
  echo "credit-budget.sh: 'jq' not found on PATH" >&2
  exit 5
fi

# --- ET calendar day ---
TODAY="$(TZ='America/New_York' date +'%Y-%m-%d')"

# --- resolve budget value ---
# Precedence: env override -> pm-config.md -> hardcoded default.
# Never reads a local token/dollar estimate.
resolve_budget_usd() {
  local val="${CLAUDE_DAILY_CREDIT_BUDGET_USD:-}"
  if [[ -n "$val" ]]; then
    printf '%s' "$val"
    return
  fi
  # Try pm-config-get.sh
  local getter="$SELF_DIR/pm-config-get.sh"
  if [[ -x "$getter" ]]; then
    local root=""
    if [[ -x "$SELF_DIR/repo-root.sh" ]]; then
      root="$("$SELF_DIR/repo-root.sh" 2>/dev/null)" || root=""
    fi
    local config=""
    [[ -n "$root" ]] && config="$root/.claude/pm-config.md"
    if [[ -n "$config" && -r "$config" ]]; then
      local body rc=0
      body="$("$getter" --section "Budget" --file "$config" 2>/dev/null)" || rc=$?
      if [[ $rc -eq 0 && -n "$body" ]]; then
        local extracted
        extracted="$(printf '%s\n' "$body" | awk '
          tolower($0) ~ /^[[:space:]]*daily_credit_budget_usd[[:space:]]*[=:]/ {
            line = $0
            sub(/^[^=:]*[=:][[:space:]]*/, "", line)
            sub(/[[:space:]]+#.*$/, "", line)
            sub(/[[:space:]]*$/, "", line)
            print line
            exit
          }
        ')"
        if [[ -n "$extracted" ]]; then
          printf '%s' "$extracted"
          return
        fi
      fi
    fi
  fi
  printf '%s' "$DEFAULT_BUDGET_USD"
}

EFFECTIVE_BUDGET="${BUDGET_OVERRIDE:-$(resolve_budget_usd)}"
# Validate that the resolved value is a non-negative number. An invalid
# config value (e.g. "abc", "$25") would cause jq to abort; fall back to
# the default to keep the gate functional.
if ! [[ "$EFFECTIVE_BUDGET" =~ ^(0|[1-9][0-9]*)(\.[0-9]+)?$ ]]; then
  echo "credit-budget.sh: invalid budget value '${EFFECTIVE_BUDGET}' from config; using default ${DEFAULT_BUDGET_USD}" >&2
  EFFECTIVE_BUDGET="$DEFAULT_BUDGET_USD"
fi

# --- read persisted credit_budget state ---
# Returns a JSON object; "not-cached" status signals "no prior state — go probe".
# This default is NOT a dispatch permission — the probe in --check mode always
# runs when no today-reached state is found; this just seeds the variables.
read_state() {
  if [[ -f "$STATE_FILE" ]] && jq -e . "$STATE_FILE" >/dev/null 2>&1; then
    jq -r '.credit_budget // {"date":"","status":"not-cached","source":"init"}' "$STATE_FILE"
  else
    printf '{"date":"","status":"not-cached","source":"init"}\n'
  fi
}

# --- classify one candidate event -------------------------------------------
# Decides whether a single event is evidence of credit overage RIGHT NOW.
# Prints nothing; returns 0 when the event gates, 1 when it does not.
#
# param 1: the event as a compact JSON object (one line).
# param 2: current epoch, passed in so every event in a sweep is judged against
#          the same instant rather than a clock that moves mid-loop.
event_gates() {
  local event="$1" now_epoch="$2"
  local kind reset_at recorded_at message

  kind="$(printf '%s' "$event" | jq -r '.limit_kind // ""' 2>/dev/null)" || kind=""
  reset_at="$(printf '%s' "$event" | jq -r '.reset_at // ""' 2>/dev/null)" || reset_at=""
  recorded_at="$(printf '%s' "$event" | jq -r '.recorded_at // ""' 2>/dev/null)" || recorded_at=""
  message="$(printf '%s' "$event" | jq -r '.last_assistant_message // ""' 2>/dev/null)" || message=""

  # Legacy record (written before the recorder classified at write time):
  # derive the kind from the same library, so there is still exactly one parser.
  if [[ -z "$kind" || "$kind" == "null" ]]; then
    kind="$(usage_limit_kind "$message")"
  fi

  # Only an overage is evidence of credit spend. plan_window and unclassified
  # events are not, and gating on them is issue #1633.
  [[ "$kind" == "overage" ]] || return 1

  if [[ -z "$reset_at" || "$reset_at" == "null" ]]; then
    reset_at="$(usage_limit_reset_at "$message" "$recorded_at")"
  fi

  # A window the message says has already reopened never gates. Applied to
  # every kind, not only plan_window: a stated reopening is a stated end of the
  # condition. An unparseable reset time is simply not known — it never becomes
  # a reason to stop gating.
  if usage_limit_reset_passed "$reset_at" "$now_epoch"; then
    return 1
  fi

  return 0
}

# --- probe authoritative overage signal (Probe 1 from budget-source-probe.md) ---
# Reads the usage-limit events log; collects every rate_limit event recorded
# during the current ET calendar day AND after reset_after_epoch (if set), then
# asks event_gates() which (if any) is a live overage.
# Returns "reached", "ok", or "unknown". NEVER performs any token/cost computation.
#
# param 1: reset_after_epoch — integer epoch (0 = no filter). Events at or before
#          this epoch are skipped, allowing --reset to permanently override them.
#
# Timestamp note: recorded_at is UTC ISO-8601. We compare against the ET calendar
# day using DST-safe epoch BOUNDARIES: the epoch of today's ET midnight and
# tomorrow's ET midnight are computed via the kernel's timezone database, so
# historical events recorded under a different DST offset are classified correctly.
# Fallback: if epoch boundary computation fails, use the current ET offset (less
# accurate across DST transitions but still functional).
probe_overage_signal() {
  local reset_after_epoch="${1:-0}"

  # Log has truly never been created → fresh install with no rate_limit events → ok.
  # Use both -L (is a symlink?) and -e (does the target exist?) to distinguish:
  #   - No file, no symlink → never created → ok
  #   - Broken symlink (! -e but -L) → unusual state → unknown (not a clean "never created")
  if [[ ! -L "$EVENTS_LOG" && ! -e "$EVENTS_LOG" ]]; then
    printf 'ok'
    return
  fi
  # Anything that is not a readable regular file (directory, broken symlink,
  # unreadable file, etc.) → conservative unknown.
  if [[ ! -f "$EVENTS_LOG" || ! -r "$EVENTS_LOG" ]]; then
    printf 'unknown'
    return
  fi

  # Compute DST-safe ET day epoch boundaries.
  # BSD (macOS): date -j -f FORMAT; GNU: date -d SPEC.
  # Try BSD first, then GNU; if both fail, fall back to offset method.
  local et_start="" et_end="" tomorrow=""
  tomorrow="$(TZ='America/New_York' date -j -v+1d -f '%Y-%m-%d' "$TODAY" '+%Y-%m-%d' 2>/dev/null)" \
    || tomorrow="$(TZ='America/New_York' date -d "${TODAY} + 1 day" '+%Y-%m-%d' 2>/dev/null)" \
    || tomorrow=""
  if [[ -n "$tomorrow" ]]; then
    et_start="$(TZ='America/New_York' date -j -f '%Y-%m-%d %H:%M:%S' "${TODAY} 00:00:00" '+%s' 2>/dev/null)" \
      || et_start="$(TZ='America/New_York' date -d "${TODAY} 00:00:00" '+%s' 2>/dev/null)" \
      || et_start=""
    et_end="$(TZ='America/New_York' date -j -f '%Y-%m-%d %H:%M:%S' "${tomorrow} 00:00:00" '+%s' 2>/dev/null)" \
      || et_end="$(TZ='America/New_York' date -d "${tomorrow} 00:00:00" '+%s' 2>/dev/null)" \
      || et_end=""
  fi

  # Emit EVERY in-window candidate, one compact JSON object per line, rather
  # than `first(inputs | …)`. The first candidate is no longer necessarily the
  # deciding one — a plan-window hit at 06:23 must not shadow an overage at
  # 11:00 — so the whole day's window is collected and judged below.
  # `jq -c` guarantees one line per object even when the captured message
  # contains newlines, which is what keeps the read loop safe.
  # No `head -1` anywhere: it would SIGPIPE jq under `set -o pipefail` and turn
  # a valid `reached` into `unknown`.
  local candidates rc=0

  if [[ -n "$et_start" && -n "$et_end" ]]; then
    # Primary: DST-accurate epoch boundary check.
    candidates="$(jq -cn \
      --argjson et_start "$et_start" \
      --argjson et_end "$et_end" \
      --argjson reset_after "$reset_after_epoch" \
      'inputs |
        select(.reason == "rate_limit") |
        select(
          (.recorded_at // "") |
          if . == "" then false
          else
            (fromdateiso8601 as $ep |
              $ep >= $et_start and $ep < $et_end and
              ($reset_after <= 0 or $ep > $reset_after))
          end
        ) |
        {recorded_at: (.recorded_at // ""),
         limit_kind: (.limit_kind // ""),
         reset_at: (.reset_at // ""),
         last_assistant_message: (
           (.last_assistant_message // "")
           | if type == "string" then . else "" end)}' \
      "$EVENTS_LOG" 2>/dev/null)" || rc=$?
  else
    # Fallback: current-session ET offset (less accurate at DST transitions).
    local et_zone_str
    et_zone_str="$(TZ='America/New_York' date +'%z' 2>/dev/null)" || et_zone_str="-0400"
    local sign="${et_zone_str:0:1}" hh="${et_zone_str:1:2}" mm="${et_zone_str:3:2}"
    hh="${hh#0}"; mm="${mm#0}"
    local et_offset_secs=$(( (${hh:-0} * 3600 + ${mm:-0} * 60) ))
    [[ "$sign" == "-" ]] && et_offset_secs=$(( -et_offset_secs ))
    candidates="$(jq -cn \
      --arg today "$TODAY" \
      --argjson offset "$et_offset_secs" \
      --argjson reset_after "$reset_after_epoch" \
      'inputs |
        select(.reason == "rate_limit") |
        select(
          (.recorded_at // "") |
          if . == "" then false
          else
            (fromdateiso8601 as $ep |
              (($ep + $offset) | todate | split("T")[0] == $today) and
              ($reset_after <= 0 or $ep > $reset_after))
          end
        ) |
        {recorded_at: (.recorded_at // ""),
         limit_kind: (.limit_kind // ""),
         reset_at: (.reset_at // ""),
         last_assistant_message: (
           (.last_assistant_message // "")
           | if type == "string" then . else "" end)}' \
      "$EVENTS_LOG" 2>/dev/null)" || rc=$?
  fi

  # rc non-0 = jq error or file unreadable. Unreadable is never permission.
  if [[ $rc -ne 0 ]]; then
    printf 'unknown'
    return
  fi

  local now_epoch
  now_epoch="$(date -u +'%s' 2>/dev/null)" || now_epoch=""
  # Without a clock the "already reopened" test cannot run. Skipping the test
  # is the conservative direction — it can only keep an event gating — so the
  # sweep proceeds with a sentinel no reset time can be at or below.
  [[ -n "$now_epoch" && "$now_epoch" =~ ^[0-9]+$ ]] || now_epoch=0

  local ev
  while IFS= read -r ev; do
    [[ -n "$ev" ]] || continue
    if event_gates "$ev" "$now_epoch"; then
      printf 'reached'
      return
    fi
  done <<< "$candidates"

  printf 'ok'
}

# --- write state (atomic, through the lock) ---
# Parameters:
#   $1  new_status  — ok | reached | unknown
#   $2  new_source  — one-word reason string
#   $3  new_reset_at — epoch integer (as string) or "" to clear.
#       Set by --reset to record the manual-override timestamp; persisted so
#       --check's probe can skip events recorded at or before this epoch.
#   $4  fail_on_corrupt — "1" to fail instead of silently skipping the write
#       when state is corrupt. Only --reset mode passes "1", because reporting
#       a successful manual reset without persisting it would be misleading.
write_state() {
  local new_status="$1"
  local new_source="$2"
  local new_reset_at="${3:-}"  # epoch integer string or empty
  local fail_on_corrupt="${4:-0}"

  # Build the jq-ready reset_at literal: a number when set, null otherwise.
  local reset_at_jq="null"
  if [[ -n "$new_reset_at" ]] && [[ "$new_reset_at" =~ ^[0-9]+$ ]]; then
    reset_at_jq="$new_reset_at"
  fi

  local tmp="$STATE_FILE.cb.tmp.$$"
  local input_file="$STATE_FILE"

  if [[ ! -f "$STATE_FILE" ]]; then
    # State file absent — seed from empty object (no sibling fields to lose).
    input_file="$(mktemp)"
    printf '%s\n' '{}' > "$input_file"
    # shellcheck disable=SC2064
    trap "state_lock_release; rm -f '$input_file' '$tmp' 2>/dev/null" EXIT
  elif ! jq -e . "$STATE_FILE" >/dev/null 2>&1; then
    # State file exists but is corrupt (fails jq parse). Two paths:
    # - Autonomous --check (fail_on_corrupt=0): skip the write entirely to
    #   avoid destroying sibling session fields. The probe result is still
    #   returned correctly to stdout; the next call will re-probe from scratch.
    # - Explicit --reset (fail_on_corrupt=1): fail without writing. A budget
    #   override never authorizes destroying unrelated orchestration state.
    if [[ "$fail_on_corrupt" != "1" ]]; then
      echo "credit-budget.sh: WARNING: session-state.json is corrupt; skipping credit_budget write to avoid destroying sibling session state" >&2
      state_lock_release
      return 0
    fi
    echo "credit-budget.sh: session-state.json is corrupt; refusing reset to preserve unrelated session state" >&2
    state_lock_release
    return 5
  else
    # shellcheck disable=SC2064
    trap "state_lock_release; rm -f '$tmp' 2>/dev/null" EXIT
  fi

  local jq_err
  jq_err="$(mktemp)"
  if ! jq \
    --arg today "$TODAY" \
    --arg status "$new_status" \
    --arg source "$new_source" \
    --argjson budget "$EFFECTIVE_BUDGET" \
    --argjson reset_at "$reset_at_jq" \
    '.credit_budget = {
       "date": $today,
       "status": $status,
       "budget_usd": $budget,
       "source": $source,
       "reset_at": $reset_at
     }
     | .last_updated = (now | todate)' \
    "$input_file" > "$tmp" 2>"$jq_err"; then
    echo "credit-budget.sh: jq failed: $(cat "$jq_err")" >&2
    rm -f "$jq_err" 2>/dev/null || true
    exit 5
  fi
  rm -f "$jq_err" 2>/dev/null || true
  state_lock_commit "$tmp" "$STATE_FILE" || exit $?
}

print_state() {
  local status="$1"
  local source="$2"
  jq -n -c \
    --arg date "$TODAY" \
    --arg status "$status" \
    --argjson budget "$EFFECTIVE_BUDGET" \
    --arg source "$source" \
    '{"date": $date, "status": $status, "budget_usd": $budget, "source": $source}'
}

# --- dispatch ---
case "$MODE" in
  check)
    # Read persisted state first. If it is from today and already `reached`,
    # return immediately without re-probing — the probe is post-hoc, so the
    # signal only adds new reached events, never clears them intraday.
    # Note: `local` is only valid inside functions. Use plain variable
    # declarations here at script scope.
    _CB_RC_READ=0
    _CB_CURRENT_RAW="$(read_state)" || _CB_RC_READ=$?
    if [[ $_CB_RC_READ -ne 0 ]]; then
      # Cannot read state at all — conservative
      print_state "unknown" "state-read-failed"
      exit 2
    fi

    STORED_DATE="$(printf '%s' "$_CB_CURRENT_RAW" | jq -r '.date // ""')"
    STORED_STATUS="$(printf '%s' "$_CB_CURRENT_RAW" | jq -r '.status // "ok"')"

    if [[ "$STORED_DATE" == "$TODAY" && "$STORED_STATUS" == "reached" ]]; then
      # Already reached today — no need to re-probe
      print_state "reached" "persisted-today"
      exit 1
    fi

    # Recover any manual --reset override recorded today. The reset_at epoch
    # is passed to probe_overage_signal so it skips events recorded at or
    # before the reset timestamp (preventing the same historical event from
    # immediately re-triggering reached after a reset).
    STORED_RESET_AT="$(printf '%s' "$_CB_CURRENT_RAW" | jq -r '.reset_at // empty')"
    RESET_AFTER_EPOCH=0
    if [[ -n "$STORED_RESET_AT" && "$STORED_RESET_AT" =~ ^[0-9]+$ && "$STORED_DATE" == "$TODAY" ]]; then
      RESET_AFTER_EPOCH="$STORED_RESET_AT"
    fi

    # Cross-day rollover: stored date != today -> reset to ok, then re-probe
    # Same day but not reached -> re-probe to pick up any new events

    # Probe the authoritative signal (skipping events before any same-day reset)
    PROBE_RESULT="$(probe_overage_signal "$RESET_AFTER_EPOCH")"

    case "$PROBE_RESULT" in
      reached)
        # A new event found AFTER any prior reset — the reset is superseded.
        # Persist reached with reset_at cleared (the new event is the authority).
        state_lock_acquire "$STATE_FILE" || exit "$STATE_LOCK_EXIT_TIMEOUT"
        write_state "reached" "overage-event-today" ""
        print_state "reached" "overage-event-today"
        exit 1
        ;;
      ok)
        # Persist ok for today (handles cross-day rollover); on cross-day,
        # clear reset_at — a new day's probe starts fresh.
        if [[ "$STORED_DATE" != "$TODAY" ]]; then
          state_lock_acquire "$STATE_FILE" || exit "$STATE_LOCK_EXIT_TIMEOUT"
          write_state "ok" "no-overage-event-today" ""
        fi
        print_state "ok" "no-overage-event-today"
        exit 0
        ;;
      unknown)
        # Probe failed — conservative posture; do not persist unknown
        print_state "unknown" "probe-failed"
        exit 2
        ;;
    esac
    ;;

  reset)
    # Record the current epoch as reset_at so --check can skip events recorded
    # before this point. This prevents the same rate_limit event from
    # immediately re-triggering `reached` after a manual reset.
    RESET_TIMESTAMP="$(date -u +'%s' 2>/dev/null || echo 0)"
    state_lock_acquire "$STATE_FILE" || exit "$STATE_LOCK_EXIT_TIMEOUT"
    write_state "ok" "manual-reset" "$RESET_TIMESTAMP" "1"
    print_state "ok" "manual-reset"
    exit 0
    ;;
esac
