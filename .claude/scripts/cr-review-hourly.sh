#!/usr/bin/env bash
# cr-review-hourly.sh — CodeRabbit account-level hourly review budget + per-PR explicit triggers.
#
# PURPOSE
#   Tracks consumption against CodeRabbit's ~8 PR reviews/hour (Pro) hidden ceiling and
#   records explicit `@coderabbitai full review` posts per PR for the "2/hour" surfacing
#   rule in `cr-github-review.md`. Mutates `cr_hourly` and `.prs[<N>].cr_explicit_triggers`
#   under ~/.claude/session-state.json with the same atomic jq + temp-file + mv pattern as
#   greptile-budget.sh.
#
# USAGE
#   cr-review-hourly.sh --check
#   cr-review-hourly.sh --consume
#   cr-review-hourly.sh --record-explicit <pr_number>
#   cr-review-hourly.sh --help | -h
#
# MODES
#   --check          Prune events older than 1 hour; print JSON snapshot on stdout.
#                    Exit 1 if global budget exhausted (still prints JSON).
#   --consume        Prune → if reviews_used >= budget, exit 1 (no write). Otherwise
#                    append current UTC ISO timestamp to cr_hourly.events, atomic write.
#   --record-explicit <N>
#                    Prune per-PR explicit-trigger timestamps >1h old; append now.
#                    Prints JSON including explicit_triggers_in_window and surface_user
#                    (true when count >= 2 after append — caller must surface to user).
#
# FLAGS
#   (none beyond modes) — default budget 8; env CR_HOURLY_BUDGET overrides for testing.
#
# OUTPUT
#   stdout: single-line JSON.
#   stderr: one-line errors; optional SURFACE line when surface_user is true.
#
# EXIT STATUS
#   0  Success.
#   1  Global hourly budget exhausted (--check or --consume); per-PR explicit-trigger cap (--record-explicit).
#   2  Usage error.
#   5  Write failed.
#
# DEPENDENCIES
#   jq, date (UTC ISO), mktemp, mv; flock optional (Linux — advisory lock; macOS falls back with stderr warning)

STATE_FILE="${HOME}/.claude/session-state.json"
LOCK_FILE="${STATE_FILE}.lock"

set -euo pipefail
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" >> "$HOME/.claude/script-usage.log" 2>/dev/null || true

DEFAULT_BUDGET=8
BUDGET="${CR_HOURLY_BUDGET:-$DEFAULT_BUDGET}"
NOW_ISO="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"

print_help() {
  sed -n '/^# PURPOSE$/,/^# DEPENDENCIES$/p' "$0" | sed 's/^# \{0,1\}//'
}

die_usage() {
  echo "cr-review-hourly.sh: $1" >&2
  echo "Run with --help for usage." >&2
  exit 2
}

MODE=""
PR_EXPLICIT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      print_help
      exit 0
      ;;
    --check|--consume)
      if [[ -n "$MODE" ]]; then
        die_usage "only one mode flag allowed"
      fi
      MODE="${1#--}"
      shift
      ;;
    --record-explicit)
      if [[ -n "$MODE" ]]; then
        die_usage "only one mode flag allowed"
      fi
      MODE="record_explicit"
      if [[ $# -lt 2 ]]; then
        die_usage "--record-explicit requires a PR number"
      fi
      PR_EXPLICIT="$2"
      if ! [[ "$PR_EXPLICIT" =~ ^[0-9]+$ ]]; then
        die_usage "--record-explicit PR must be numeric, got: $PR_EXPLICIT"
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
  die_usage "one of --check, --consume, --record-explicit is required"
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "cr-review-hourly.sh: 'jq' not found on PATH" >&2
  exit 5
fi

USE_FLOCK=0
if command -v flock >/dev/null 2>&1; then
  USE_FLOCK=1
else
  echo "cr-review-hourly.sh: WARNING: 'flock' not found — proceeding without cross-process lock (macOS/default); parallel agents may race like greptile-budget.sh" >&2
fi

if ! [[ "$BUDGET" =~ ^[0-9]+$ ]]; then
  die_usage "CR_HOURLY_BUDGET must be a non-negative integer"
fi

STATE_DIR="$(dirname "$STATE_FILE")"
if ! mkdir -p "$STATE_DIR" 2>/dev/null; then
  echo "cr-review-hourly.sh: could not create state dir: $STATE_DIR" >&2
  exit 5
fi

# jq filter: prune cr_hourly.events to last 3600s; prune each .prs[].cr_explicit_triggers similarly.
# Events are ISO8601 Z strings; jq's fromdateiso8601 parses them.
PRUNE_GLOBAL='def prune_events($events):
  ($events // []) as $e
  | [ $e[] | select((.|fromdateiso8601) > (now - 3600)) ];

def prune_pr_triggers($prs):
  ($prs // {}) as $p
  | if ($p | type) != "object" then $p
    else
      reduce ($p | keys_unsorted[]) as $k ({};
        .[$k] = (
          ($p[$k] // {}) as $entry
          | if ($entry | type) == "object" and ($entry.cr_explicit_triggers | type) == "array" then
              ($entry | .cr_explicit_triggers = prune_events(.cr_explicit_triggers))
            else $entry end
        ))
    end;

. as $root
| .cr_hourly = (($root.cr_hourly // {}) | .events = prune_events(.events))
| .prs = prune_pr_triggers(.prs)'

write_merged_state() {
  local jq_post="$1"
  local tmp="$STATE_FILE.tmp.$$"
  local input_file="$STATE_FILE"
  local seeded=""
  if [[ ! -f "$STATE_FILE" ]] || ! jq -e . "$STATE_FILE" >/dev/null 2>&1; then
    seeded="$(mktemp)"
    printf '%s\n' '{}' > "$seeded"
    input_file="$seeded"
  fi

  local jq_err
  jq_err="$(mktemp)"
  cleanup_tmp() {
    rm -f "$jq_err" "$tmp" ${seeded:+"$seeded"} 2>/dev/null || true
  }
  # shellcheck disable=SC2064
  trap cleanup_tmp EXIT

  if ! jq --arg now_iso "$NOW_ISO" \
    "$PRUNE_GLOBAL | $jq_post | .last_updated = \$now_iso" \
    "$input_file" >"$tmp" 2>"$jq_err"; then
    echo "cr-review-hourly.sh: jq failed updating $STATE_FILE: $(cat "$jq_err")" >&2
    exit 5
  fi

  if ! mv "$tmp" "$STATE_FILE" 2>/dev/null; then
    echo "cr-review-hourly.sh: could not write $STATE_FILE" >&2
    exit 5
  fi
  cleanup_tmp
  trap - EXIT
}

case "$MODE" in
  check)
    if [[ ! -f "$STATE_FILE" ]] || ! jq -e . "$STATE_FILE" >/dev/null 2>&1; then
      OUT="$(jq -n -c \
        --argjson budget "$BUDGET" \
        --arg now_iso "$NOW_ISO" \
        '{reviews_used: 0, budget: $budget, remaining: ($budget | if . < 0 then 0 else . end), exhausted: ($budget == 0), window_note: "rolling_3600s", checked_at: $now_iso}'
      )"
      echo "$OUT"
      EXH="$(echo "$OUT" | jq -r '.exhausted')"
      if [[ "$EXH" == "true" ]]; then
        exit 1
      fi
      exit 0
    fi
    # Read pruned counts without persisting (unless we want to prune on read — greptile persists cross-day)
    OUT="$(jq -c \
      --argjson budget "$BUDGET" \
      --arg now_iso "$NOW_ISO" \
      "$PRUNE_GLOBAL
      | . as \$root
      | (\$root.cr_hourly.events // []) as \$ev
      | (\$ev | length) as \$n
      | {
          reviews_used: \$n,
          budget: \$budget,
          remaining: ((\$budget - \$n) | if . < 0 then 0 else . end),
          exhausted: (\$n >= \$budget),
          window_note: \"rolling_3600s\",
          checked_at: \$now_iso
        }" "$STATE_FILE")"
    echo "$OUT"
    EXH="$(echo "$OUT" | jq -r '.exhausted')"
    if [[ "$EXH" == "true" ]]; then
      exit 1
    fi
    exit 0
    ;;

  consume)
    inner_consume() {
      if [[ ! -f "$STATE_FILE" ]] || ! jq -e . "$STATE_FILE" >/dev/null 2>&1; then
        PRE=0
      else
        PRE="$(jq "$PRUNE_GLOBAL | (.cr_hourly.events // []) | length" "$STATE_FILE")"
      fi
      if (( PRE >= BUDGET )); then
        jq -n -c \
          --argjson budget "$BUDGET" \
          --argjson used "$PRE" \
          --arg now_iso "$NOW_ISO" \
          '{reviews_used: $used, budget: $budget, remaining: 0, exhausted: true, consumed: false, checked_at: $now_iso}'
        exit 1
      fi

      write_merged_state '.cr_hourly.events += [$now_iso]'
      POST="$(jq -c \
        --argjson budget "$BUDGET" \
        --arg now_iso "$NOW_ISO" \
        "$PRUNE_GLOBAL
      | (.cr_hourly.events | length) as \$n
      | {
          reviews_used: \$n,
          budget: \$budget,
          remaining: ((\$budget - \$n) | if . < 0 then 0 else . end),
          exhausted: (\$n >= \$budget),
          consumed: true,
          checked_at: \$now_iso
        }" "$STATE_FILE")"
      echo "$POST"
      exit 0
    }
    if [[ "$USE_FLOCK" -eq 1 ]]; then
      (
        flock -w 120 9 || {
          echo "cr-review-hourly.sh: could not acquire lock on $LOCK_FILE (timeout)" >&2
          exit 5
        }
        inner_consume
      ) 9>>"$LOCK_FILE"
    else
      inner_consume
    fi
    exit $?
    ;;

  record_explicit)
    inner_record() {
      PR_KEY="$PR_EXPLICIT"
      if [[ ! -f "$STATE_FILE" ]] || ! jq -e . "$STATE_FILE" >/dev/null 2>&1; then
        PRE_EXPLICIT=0
      else
        PRE_EXPLICIT="$(jq "$PRUNE_GLOBAL | (.prs[\"$PR_KEY\"].cr_explicit_triggers // []) | length" "$STATE_FILE")"
      fi
      if ! [[ "$PRE_EXPLICIT" =~ ^[0-9]+$ ]]; then
        PRE_EXPLICIT=0
      fi
      GLOBAL_USED="$(jq "$PRUNE_GLOBAL | (.cr_hourly.events // []) | length" "$STATE_FILE" 2>/dev/null || echo 0)"
      if ! [[ "$GLOBAL_USED" =~ ^[0-9]+$ ]]; then GLOBAL_USED=0; fi
      if (( GLOBAL_USED >= BUDGET )); then
        jq -n -c \
          --argjson pr "$PR_EXPLICIT" \
          --argjson budget "$BUDGET" \
          --argjson used "$GLOBAL_USED" \
          --arg now_iso "$NOW_ISO" \
          '{pr: ($pr | tonumber), global_exhausted: true, reviews_used: $used, budget: $budget, recorded: false, recorded_at: $now_iso}'
        echo "cr-review-hourly.sh: global CR budget exhausted ($GLOBAL_USED/$BUDGET); cannot record explicit trigger" >&2
        exit 1
      fi
      if (( PRE_EXPLICIT >= 2 )); then
        jq -n -c \
          --argjson pr "$PR_EXPLICIT" \
          --argjson c "$PRE_EXPLICIT" \
          --arg now_iso "$NOW_ISO" \
          '{pr: ($pr | tonumber), explicit_triggers_in_window: $c, surface_user: true, recorded: false, recorded_at: $now_iso}'
        echo "cr-review-hourly.sh: SURFACE — PR #${PR_EXPLICIT} already at explicit-trigger cap (>=2/hour); not recording another timestamp." >&2
        exit 1
      fi

      write_merged_state \
        ".prs[\"$PR_KEY\"] = ((.prs[\"$PR_KEY\"] // {}) + {})
         | .prs[\"$PR_KEY\"].cr_explicit_triggers = (
             ((.prs[\"$PR_KEY\"].cr_explicit_triggers // []) + [\$now_iso])
           )
         | .cr_hourly.events = ((.cr_hourly.events // []) + [\$now_iso])"

      OUT="$(jq -c \
        --arg pr "$PR_EXPLICIT" \
        --arg now_iso "$NOW_ISO" \
        "$PRUNE_GLOBAL
      | (.prs[\$pr].cr_explicit_triggers // []) as \$t
      | (\$t | length) as \$c
      | {
          pr: (\$pr | tonumber),
          explicit_triggers_in_window: \$c,
          surface_user: (\$c >= 2),
          recorded: true,
          recorded_at: \$now_iso
        }" "$STATE_FILE")"
      echo "$OUT"
      if [[ "$(echo "$OUT" | jq -r '.surface_user')" == "true" ]]; then
        echo "cr-review-hourly.sh: SURFACE — PR #${PR_EXPLICIT} has reached 2 explicit @coderabbitai full review triggers in the rolling hour; tell the user CodeRabbit may be rate-limited or defer further triggers." >&2
      fi
      exit 0
    }
    if [[ "$USE_FLOCK" -eq 1 ]]; then
      (
        flock -w 120 9 || {
          echo "cr-review-hourly.sh: could not acquire lock on $LOCK_FILE (timeout)" >&2
          exit 5
        }
        inner_record
      ) 9>>"$LOCK_FILE"
    else
      inner_record
    fi
    exit $?
    ;;
esac
