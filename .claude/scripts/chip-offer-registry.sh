#!/usr/bin/env bash
# chip-offer-registry.sh — Repo-scoped, lifecycle-aware chip offer registry.
#
# PURPOSE
#   Tracks chip offers from all emitters (/pm, /prompt, /wave, /issue-maker,
#   /start-issue) in a single durable, cross-thread store (Issue #1225).
#   Provides an atomic reservation at the creation boundary, closing the race
#   where two concurrent emitters could both observe the same FREE slot and
#   both create offers, together exceeding the cap.
#
#   Data lives at .repos["owner/name"].chip_offers in session-state.json,
#   reusing that file's mkdir-based lock (state-lock.sh) rather than
#   introducing a third state file.
#
# USAGE
#   chip-offer-registry.sh [--repo owner/name] --reserve --emitter <emitter>
#                          --issue <N> [--issue <N> ...] --cap-free <N>
#                          [--task-id <id>]
#   chip-offer-registry.sh [--repo owner/name] --transition --task-id <id>
#                          --state <state>
#   chip-offer-registry.sh [--repo owner/name] --retract --task-id <id>
#   chip-offer-registry.sh [--repo owner/name] --count [--state <state>]
#   chip-offer-registry.sh [--repo owner/name] --list [--state <state>]
#   chip-offer-registry.sh --help | -h
#
# LIFECYCLE STATES
#   offered    Chip has been shown to the user; awaiting their click.
#   running    Chip was clicked; thread is active but no PR opened yet.
#   pr-backed  A PR exists for this work; counted by the open-PR source,
#              NOT by this registry (prevents double-counting with source 1).
#   done       Work is complete (PR merged). Terminal.
#   retracted  Chip explicitly withdrawn. Terminal.
#   expired    TTL elapsed without a state transition. Terminal.
#
#   Capacity-consuming states: offered, running.
#   Terminal (not counted by registry): pr-backed, done, retracted, expired.
#
# COUNTING
#   --count (with no --state) reports the number of entries in capacity-
#   consuming states: offered and running. pr-backed, done, retracted, and
#   expired are not counted here (pr-backed is still counted by
#   active-work-cap.sh's open-PR source; the others are finished or cancelled).
#
# RESERVATION LEASE (--reserve)
#   Atomically: acquires the lock on session-state.json, reads the registry,
#   counts non-expired offered+running entries, and either:
#     (a) creates a new entry and exits 0 — if count < cap-free, or
#     (b) exits 7 (cap exhausted) — if count >= cap-free.
#
#   --cap-free N is the ABSOLUTE ADMISSION LIMIT for registry entries, not
#   the raw FREE count from active-work-cap.sh.  Because active-work-cap.sh
#   already counts existing offered/running registry entries in ACTIVE (and
#   therefore subtracts them from FREE), passing FREE directly would cause
#   false cap exhaustion whenever active_count > 0.  Callers must pass
#   (registry_baseline + FREE), where registry_baseline = chip-offer-registry.sh
#   --count read just before the --reserve call.  The atomic critical section
#   ensures that if two emitters both observe the same snapshot and both call
#   --reserve with the same CAP_ADMISSION, reservations succeed while
#   active_count < CAP_ADMISSION and exit 7 once active_count reaches
#   CAP_ADMISSION — for example, with FREE=1, the first write finds
#   active_count == baseline (< CAP_ADMISSION) and succeeds; the second
#   finds active_count == baseline+1 == CAP_ADMISSION and exits 7.
#
#   ONE ENTRY PER CHIP (not per issue). A batch hand-off covering N issues is
#   ONE chip (one spawn_task call), so --reserve is called ONCE for the batch.
#   Pass --issue for each covered issue (e.g. --issue 10 --issue 11 --issue 12);
#   all are stored in the "issues" array so active-work-cap.sh can exclude them
#   all from the legacy chip-log count, preventing double-counting.
#
# RELEASE ON FAILURE (--retract)
#   If the spawn_task call following --reserve fails, the caller MUST release
#   the reservation immediately via --retract --task-id <tid>. TTL self-heals
#   a crashed turn, but an explicit retract frees the slot in the same turn.
#   --retract is a convenience alias for --transition --state retracted.
#
# TTL
#   CLAUDE_CHIP_OFFER_TTL_S (default 86400 = 24 h). An entry whose offered_at
#   predates now - TTL is treated as expired during --count and --list --count.
#   An entry with no offered_at is never expired (fail-closed: unknown age is
#   not treated as old). Matches the stale-agent guard in active-work-cap.sh.
#
# VALID EMITTERS
#   pm, prompt, wave, issue-maker, start-issue
#
# FLAGS
#   --repo <owner/name>   Registry scope. Defaults to the origin remote of cwd.
#   --emitter <name>      Emitter name. Required for --reserve.
#   --issue <N>           GitHub issue number. May be repeated for batch offers.
#                         Required for --reserve (at least once).
#   --cap-free <N>        Absolute admission limit for registry entries (not
#                         the raw FREE value from active-work-cap.sh). Callers
#                         must pass (registry_baseline + FREE) so the locked
#                         comparison is correct when existing entries are already
#                         reflected in FREE. Required for --reserve.
#   --task-id <id>        Caller-supplied task_id. Optional for --reserve
#                         (generated as "offer-<ts>-<pid>-<random>" when absent).
#                         Required for --transition and --retract.
#   --state <state>       Target state for --transition. Filter for --count/--list.
#
# EXIT CODES
#   0  Success.
#   2  Usage error (unknown flag, missing required arg, invalid value).
#   4  jq parse or evaluation failure.
#   5  Write failure (mktemp, mv, missing lock library).
#   6  Lock timeout (STATE_LOCK_EXIT_TIMEOUT from state-lock.sh).
#   7  Cap exhausted (--reserve only: all FREE slots are claimed).
#
# TASK-ID STABILITY
#   Generated task_ids use timestamp + PID + random to minimise the chance of
#   aliasing across two sessions that start in the same second. Since
#   session-state.json is the persistence layer, an id generated before an app
#   restart can still be transitioned by a later session as long as the entry
#   exists in the file. Caller-supplied --task-id values must be stable and
#   unique across restarts if used for durable cross-session tracking.
#
# STORE
#   ~/.claude/session-state.json, under .repos["<owner/name>"].chip_offers.
#   An absent key reads as [] (empty array); a missing state file means no
#   offers, not an error (for --count and --list; --transition exits 2 when
#   the named task-id is not found).
#
# DEPENDENCIES
#   jq, .claude/scripts/state-lock.sh (sibling library).

set -uo pipefail
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" \
  >> "${HOME}/.claude/script-usage.log" 2>/dev/null || true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCK_LIB="${SCRIPT_DIR}/state-lock.sh"
NORMALIZER_LIB="${SCRIPT_DIR}/lib/repo-normalizer.sh"
STATE_FILE="${HOME}/.claude/session-state.json"

ORIG_ARGS=("$@")

_retry_or_fail() {
  local n="${CLAUDE_STATE_RMW_RETRY:-0}" max="${CLAUDE_STATE_RMW_MAX_RETRY:-8}"
  if (( n < max )); then
    export CLAUDE_STATE_RMW_RETRY=$(( n + 1 ))
    sleep "0.0$(( (RANDOM % 8) + 1 ))"
    exec bash "$0" ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}
  fi
  echo "chip-offer-registry.sh: lock was broken $max times; giving up" >&2
  exit 6
}

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; }

die_usage() { echo "chip-offer-registry.sh: $1" >&2; echo "Run with --help for usage." >&2; exit 2; }
die_parse() { echo "chip-offer-registry.sh: $1" >&2; exit 4; }
die_write() { echo "chip-offer-registry.sh: $1" >&2; exit 5; }

# Load the lock library — required for all write paths (--reserve, --transition).
load_lock_lib() {
  if [[ ! -f "$LOCK_LIB" ]]; then
    die_write "state-lock.sh not found at $LOCK_LIB"
  fi
  # shellcheck source=state-lock.sh
  source "$LOCK_LIB"
}

# Resolve the repo key (owner/name, lowercase) from --repo or cwd origin.
resolve_repo_key() {
  local raw="$1"
  if [[ -n "$raw" ]]; then
    # Validate shape before lowercasing.
    if [[ ! "$raw" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
      die_usage "--repo must look like owner/name (got: $raw)"
    fi
    printf '%s' "$raw" | tr '[:upper:]' '[:lower:]'
    return
  fi
  # Infer from git remote.
  local out rc=0
  out="$(git remote get-url origin 2>&1)" || rc=$?
  if [[ $rc -ne 0 || -z "$out" ]]; then
    die_usage "could not infer repo from git remote (pass --repo owner/name): $out"
  fi
  # Support both https://github.com/owner/name(.git) and git@github.com:owner/name.git
  # Strip the .git suffix first so that repository names containing dots (e.g.
  # owner/repo.v2) are preserved in full rather than being truncated at the first
  # dot by the [^/.] character class (feedback_codeant_remote_dot_truncation.md).
  local slug
  slug="$(printf '%s' "$out" | sed -e 's|\.git$||' -e 's|.*github\.com[:/]\([^/]*/[^/]*\)$|\1|')"
  if [[ ! "$slug" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
    die_usage "could not extract owner/name from remote URL '$out' (pass --repo owner/name)"
  fi
  printf '%s' "$slug" | tr '[:upper:]' '[:lower:]'
}

# Read the chip_offers array for a given repo key from session-state.json.
# Prints the JSON array on stdout. Prints "[]" if the file/key is absent.
# Exits 4 on a parse error.
read_offers() {
  local repo_key="$1"
  if [[ ! -f "$STATE_FILE" ]]; then
    printf '[]'
    return 0
  fi
  local out rc=0
  out="$(jq -r --arg k "$repo_key" \
    '(.repos[$k].chip_offers // [])' "$STATE_FILE" 2>&1)" || rc=$?
  if [[ $rc -ne 0 ]]; then
    die_parse "could not read chip_offers from $STATE_FILE: $out"
  fi
  printf '%s' "$out"
}

# Write the chip_offers array back into session-state.json under the repo key.
# Caller must already hold the state-lock on STATE_FILE.
write_offers() {
  local repo_key="$1"
  local offers_json="$2"
  local state_dir
  state_dir="$(dirname "$STATE_FILE")"
  mkdir -p "$state_dir" 2>/dev/null || true

  # Read the whole state file, or seed with {} if absent.
  local doc rc=0
  if [[ -f "$STATE_FILE" ]]; then
    doc="$(cat "$STATE_FILE" 2>&1)" || rc=$?
    if [[ $rc -ne 0 ]]; then
      die_write "could not read $STATE_FILE: $doc"
    fi
  else
    doc="{}"
  fi

  # Validate that the current doc is a JSON object.
  local doctype rc2=0
  doctype="$(printf '%s' "$doc" | jq -r 'type' 2>&1)" || rc2=$?
  if [[ $rc2 -ne 0 || "$doctype" != "object" ]]; then
    die_write "$STATE_FILE is not a JSON object (type=$doctype)"
  fi

  # Merge: set .repos["key"].chip_offers = new array, preserving all else.
  local new_doc rc3=0
  new_doc="$(printf '%s' "$doc" | jq \
    --arg k "$repo_key" \
    --argjson offers "$offers_json" \
    '.repos[$k].chip_offers = $offers' 2>&1)" || rc3=$?
  if [[ $rc3 -ne 0 ]]; then
    die_parse "could not merge chip_offers into state: $new_doc"
  fi

  # Verify the result is still a JSON object.
  local newtype rc4=0
  newtype="$(printf '%s' "$new_doc" | jq -r 'type' 2>&1)" || rc4=$?
  if [[ $rc4 -ne 0 || "$newtype" != "object" ]]; then
    die_write "merge produced a non-object result ($newtype); $STATE_FILE left unchanged"
  fi

  # Atomic write via same-directory temp.
  local tmp rc5=0
  tmp="$(mktemp "${state_dir}/.chip-offers.XXXXXX")" || die_write "mktemp failed in $state_dir"
  printf '%s\n' "$new_doc" > "$tmp" || {
    rm -f "$tmp" 2>/dev/null || true
    die_write "write to temp file failed"
  }

  # Verify lock is still held before committing.
  if ! state_lock_assert_held; then
    rm -f "$tmp" 2>/dev/null || true
    state_lock_release
    _retry_or_fail
  fi

  if ! mv "$tmp" "$STATE_FILE"; then
    rm -f "$tmp" 2>/dev/null || true
    die_write "mv to $STATE_FILE failed"
  fi
}

# Count capacity-consuming entries, respecting TTL.
# Capacity-consuming: state in (offered, running).
# Entry is expired if offered_at is set and is older than TTL_S.
count_active_offers() {
  local offers_json="$1"
  local ttl_s="${CLAUDE_CHIP_OFFER_TTL_S:-86400}"
  [[ "$ttl_s" =~ ^[0-9]+$ ]] || {
    echo "chip-offer-registry.sh: CLAUDE_CHIP_OFFER_TTL_S is not an integer ('$ttl_s') — using 86400" >&2
    ttl_s=86400
  }
  local now
  now="$(date -u +%s)"
  local n rc=0
  n="$(printf '%s' "$offers_json" | jq -r \
    --argjson now "$now" --argjson ttl "$ttl_s" '
    [ .[]
      | select(.state == "offered" or .state == "running")
      # Entries whose TTL has elapsed are treated as expired.
      | select(
          (.offered_at // "") as $t
          | if $t == "" then true
            else ($t | fromdateiso8601? // null) as $e
                 | if $e == null then true else ($now - $e) < $ttl end
            end
        )
    ] | length' 2>&1)" || rc=$?
  if [[ $rc -ne 0 || ! "$n" =~ ^[0-9]+$ ]]; then
    die_parse "could not count chip_offers: $n"
  fi
  printf '%s' "$n"
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
MODE=""
REPO_OPT=""
EMITTER=""
ISSUE_NUMS=()   # accumulates --issue values; batch offers pass more than one
CAP_FREE=""
TASK_ID_OPT=""
TARGET_STATE=""
STATE_FILTER=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --repo)
      [[ $# -ge 2 && -n "${2:-}" ]] || die_usage "--repo requires a value"
      REPO_OPT="$2"; shift 2 ;;
    --repo=*)
      REPO_OPT="${1#--repo=}"
      [[ -n "$REPO_OPT" ]] || die_usage "--repo requires a value"
      shift ;;
    --reserve)
      [[ -z "$MODE" ]] || die_usage "conflicting modes"
      MODE="reserve"; shift ;;
    --transition)
      [[ -z "$MODE" ]] || die_usage "conflicting modes"
      MODE="transition"; shift ;;
    --retract)
      [[ -z "$MODE" ]] || die_usage "conflicting modes"
      MODE="retract"; shift ;;
    --count)
      [[ -z "$MODE" ]] || die_usage "conflicting modes"
      MODE="count"; shift ;;
    --list)
      [[ -z "$MODE" ]] || die_usage "conflicting modes"
      MODE="list"; shift ;;
    --emitter)
      [[ $# -ge 2 && -n "${2:-}" ]] || die_usage "--emitter requires a value"
      EMITTER="$2"; shift 2 ;;
    --emitter=*)
      EMITTER="${1#--emitter=}"
      [[ -n "$EMITTER" ]] || die_usage "--emitter requires a value"
      shift ;;
    --issue)
      [[ $# -ge 2 && -n "${2:-}" ]] || die_usage "--issue requires a value"
      [[ "${2}" =~ ^[1-9][0-9]*$ ]] || die_usage "--issue must be a positive integer (got: ${2})"
      ISSUE_NUMS+=("$2"); shift 2 ;;
    --issue=*)
      _iv="${1#--issue=}"
      [[ -n "$_iv" ]] || die_usage "--issue requires a value"
      [[ "$_iv" =~ ^[1-9][0-9]*$ ]] || die_usage "--issue must be a positive integer (got: $_iv)"
      ISSUE_NUMS+=("$_iv"); shift ;;
    --cap-free)
      [[ $# -ge 2 && -n "${2:-}" ]] || die_usage "--cap-free requires a value"
      CAP_FREE="$2"; shift 2 ;;
    --cap-free=*)
      CAP_FREE="${1#--cap-free=}"
      [[ -n "$CAP_FREE" ]] || die_usage "--cap-free requires a value"
      shift ;;
    --task-id)
      [[ $# -ge 2 && -n "${2:-}" ]] || die_usage "--task-id requires a value"
      TASK_ID_OPT="$2"; shift 2 ;;
    --task-id=*)
      TASK_ID_OPT="${1#--task-id=}"
      [[ -n "$TASK_ID_OPT" ]] || die_usage "--task-id requires a value"
      shift ;;
    --state)
      [[ $# -ge 2 && -n "${2:-}" ]] || die_usage "--state requires a value"
      case "$1" in
        --state) TARGET_STATE="$2"; STATE_FILTER="$2"; shift 2 ;;
      esac ;;
    --state=*)
      TARGET_STATE="${1#--state=}"
      STATE_FILTER="$TARGET_STATE"
      [[ -n "$TARGET_STATE" ]] || die_usage "--state requires a value"
      shift ;;
    *) die_usage "unknown argument: $1" ;;
  esac
done

[[ -n "$MODE" ]] || die_usage "no mode specified (--reserve|--transition|--retract|--count|--list)"

REPO_KEY="$(resolve_repo_key "$REPO_OPT")"

VALID_STATES="offered running pr-backed done retracted expired"

# ---------------------------------------------------------------------------
# --count: count capacity-consuming entries (or filter by --state).
# ---------------------------------------------------------------------------
if [[ "$MODE" == "count" ]]; then
  offers="$(read_offers "$REPO_KEY")"
  if [[ -n "$STATE_FILTER" ]]; then
    # Filter to specific state.
    local_n="$(printf '%s' "$offers" | jq -r --arg s "$STATE_FILTER" \
      '[.[] | select(.state == $s)] | length' 2>&1)" || die_parse "jq failed: $local_n"
    [[ "$local_n" =~ ^[0-9]+$ ]] || die_parse "expected integer count, got: $local_n"
    printf '%s\n' "$local_n"
  else
    n="$(count_active_offers "$offers")"
    printf '%s\n' "$n"
  fi
  exit 0
fi

# ---------------------------------------------------------------------------
# --list: print entries as a JSON array (optionally filtered by --state).
# ---------------------------------------------------------------------------
if [[ "$MODE" == "list" ]]; then
  offers="$(read_offers "$REPO_KEY")"
  if [[ -n "$STATE_FILTER" ]]; then
    out="$(printf '%s' "$offers" | jq -r --arg s "$STATE_FILTER" \
      '[.[] | select(.state == $s)]' 2>&1)" || die_parse "jq failed: $out"
    printf '%s\n' "$out"
  else
    printf '%s\n' "$offers"
  fi
  exit 0
fi

# ---------------------------------------------------------------------------
# --reserve and --transition need the lock library.
# ---------------------------------------------------------------------------
load_lock_lib

# ---------------------------------------------------------------------------
# --reserve: atomically check cap and create a new entry.
# ---------------------------------------------------------------------------
if [[ "$MODE" == "reserve" ]]; then
  # Validate required args.
  [[ -n "$EMITTER" ]] || die_usage "--reserve requires --emitter"
  (( ${#ISSUE_NUMS[@]} > 0 )) || die_usage "--reserve requires at least one --issue"
  [[ -n "$CAP_FREE" ]] || die_usage "--reserve requires --cap-free"
  [[ "$CAP_FREE" =~ ^[0-9]+$ ]] || die_usage "--cap-free must be a non-negative integer (got: $CAP_FREE)"

  # Validate emitter name — must match one of the six canonical spawn_task emitters
  # listed in chip-launching.md. harness-audit is included here because chip-launching.md
  # §"Literal vs resolved model names" names it as the sixth canonical emitter.
  case "$EMITTER" in
    pm|prompt|wave|issue-maker|start-issue|harness-audit) ;;
    *) die_usage "--emitter must be one of: pm, prompt, wave, issue-maker, start-issue, harness-audit (got: $EMITTER)" ;;
  esac

  # Build the JSON array of issue numbers (already validated as integers during parsing).
  ISSUES_JSON="$(printf '%s\n' "${ISSUE_NUMS[@]}" | jq -Rn '[inputs | tonumber]' 2>&1)" || \
    die_parse "could not build issues array: $ISSUES_JSON"
  FIRST_ISSUE="${ISSUE_NUMS[0]}"

  # Generate task-id if not provided.
  # Use timestamp + PID + two RANDOM words for entropy across concurrent sessions
  # that might start in the same second (deferral 3 fix: ts-only ids could alias).
  local_task_id="$TASK_ID_OPT"
  if [[ -z "$local_task_id" ]]; then
    local_task_id="offer-$(date -u +%s)-$$-$(printf '%04x%04x' "$RANDOM" "$RANDOM")"
  fi

  NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  TTL_S="${CLAUDE_CHIP_OFFER_TTL_S:-86400}"
  [[ "$TTL_S" =~ ^[0-9]+$ ]] || TTL_S=86400
  NOW_EPOCH="$(date -u +%s)"
  EXPIRES_EPOCH=$(( NOW_EPOCH + TTL_S ))
  EXPIRES_AT="$(date -u -d "@$EXPIRES_EPOCH" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -r "$EXPIRES_EPOCH" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || printf '%s' "${NOW}")"  # Fallback: no strict TTL expiry

  # Acquire the lock before reading + writing.
  state_lock_acquire "$STATE_FILE" || exit "$STATE_LOCK_EXIT_TIMEOUT"

  existing="$(read_offers "$REPO_KEY")"
  active_count="$(count_active_offers "$existing")"

  if (( active_count >= CAP_FREE )); then
    state_lock_release
    echo "chip-offer-registry.sh: cap exhausted ($active_count >= $CAP_FREE admission limit; repo=$REPO_KEY)" >&2
    exit 7
  fi

  # Build the new entry.
  # "issue" (scalar) is the primary/first issue for backward compat.
  # "issues" (array) is the full set — active-work-cap.sh reads all of them so
  # that every covered issue is excluded from the legacy chip-log count,
  # preventing double-counting when the emitter also stamps chip_task_id in the
  # legacy log (deferral 1 fix).
  new_entry="$(jq -cn \
    --arg tid "$local_task_id" \
    --arg emitter "$EMITTER" \
    --argjson issue "$FIRST_ISSUE" \
    --argjson issues "$ISSUES_JSON" \
    --arg now "$NOW" \
    --arg expires "$EXPIRES_AT" \
    '{task_id: $tid, emitter: $emitter, issue: $issue, issues: $issues, state: "offered",
      offered_at: $now, expires_at: $expires, pr: null, last_updated: $now}' 2>&1)" || {
      state_lock_release
      die_parse "could not build registry entry: $new_entry"
    }

  # Append to the array.
  updated="$(printf '%s' "$existing" | jq ". += [$new_entry]" 2>&1)" || {
    state_lock_release
    die_parse "could not append entry: $updated"
  }

  write_offers "$REPO_KEY" "$updated"
  state_lock_release

  # Print the task_id so callers can record it.
  printf '%s\n' "$local_task_id"
  exit 0
fi

# ---------------------------------------------------------------------------
# --transition: move an entry to a new lifecycle state.
# ---------------------------------------------------------------------------
if [[ "$MODE" == "transition" ]]; then
  [[ -n "$TASK_ID_OPT" ]] || die_usage "--transition requires --task-id"
  [[ -n "$TARGET_STATE" ]] || die_usage "--transition requires --state"

  # Validate target state.
  valid=0
  for s in $VALID_STATES; do
    [[ "$s" == "$TARGET_STATE" ]] && valid=1 && break
  done
  (( valid )) || die_usage "--state must be one of: $VALID_STATES (got: $TARGET_STATE)"

  NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  state_lock_acquire "$STATE_FILE" || exit "$STATE_LOCK_EXIT_TIMEOUT"

  existing="$(read_offers "$REPO_KEY")"

  # Check the task_id exists.
  found="$(printf '%s' "$existing" | jq -r --arg tid "$TASK_ID_OPT" \
    '[.[] | select(.task_id == $tid)] | length' 2>&1)" || {
    state_lock_release
    die_parse "jq failed looking up task_id: $found"
  }
  if [[ "$found" == "0" ]]; then
    state_lock_release
    echo "chip-offer-registry.sh: task_id '$TASK_ID_OPT' not found in registry (repo=$REPO_KEY)" >&2
    exit 2
  fi

  updated="$(printf '%s' "$existing" | jq \
    --arg tid "$TASK_ID_OPT" --arg state "$TARGET_STATE" --arg now "$NOW" '
    [ .[]
      | if .task_id == $tid
        then .state = $state | .last_updated = $now
        else .
        end
    ]' 2>&1)" || {
    state_lock_release
    die_parse "could not update entry state: $updated"
  }

  write_offers "$REPO_KEY" "$updated"
  state_lock_release
  exit 0
fi

# ---------------------------------------------------------------------------
# --retract: convenience alias — move entry to retracted (release on failure).
# Call this immediately after a failed spawn_task to free the reserved slot
# without waiting for TTL expiry (deferral 2 fix).
# ---------------------------------------------------------------------------
if [[ "$MODE" == "retract" ]]; then
  [[ -n "$TASK_ID_OPT" ]] || die_usage "--retract requires --task-id"

  NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  state_lock_acquire "$STATE_FILE" || exit "$STATE_LOCK_EXIT_TIMEOUT"

  existing="$(read_offers "$REPO_KEY")"

  # Treat an unknown task_id as a no-op success — idempotent retract.
  found="$(printf '%s' "$existing" | jq -r --arg tid "$TASK_ID_OPT" \
    '[.[] | select(.task_id == $tid)] | length' 2>&1)" || {
    state_lock_release
    die_parse "jq failed looking up task_id: $found"
  }
  if [[ "$found" == "0" ]]; then
    state_lock_release
    exit 0  # no-op: entry already absent or already terminal
  fi

  updated="$(printf '%s' "$existing" | jq \
    --arg tid "$TASK_ID_OPT" --arg now "$NOW" '
    [ .[]
      | if .task_id == $tid
        then .state = "retracted" | .last_updated = $now
        else .
        end
    ]' 2>&1)" || {
    state_lock_release
    die_parse "could not retract entry: $updated"
  }

  write_offers "$REPO_KEY" "$updated"
  state_lock_release
  exit 0
fi
