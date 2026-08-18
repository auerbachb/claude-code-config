#!/usr/bin/env bash
# release-sweep.sh — Follow triggered TestFlight builds to a terminal state and
# cut pending builds once their window opens (issue #1169).
#
# The half of the automation that outlives the thread that started it. A merge
# inside the build window leaves a durable "release pending" marker; this sweep
# is what turns that marker into an actual build later, from whatever session
# happens to be running — the originating PM thread does not have to still exist.
#
# A build you cannot confirm shipped is not automation: every build this system
# triggers is followed to a terminal state, and a failed, cancelled, or
# unexpectedly skipped release is SURFACED rather than disappearing (AC10).
#
# Per repo carrying release state:
#   1. Resolve the in-flight build. A trigger that produced no run inside the
#      grace window is reported as a trigger that did not take. A completed run
#      that failed, timed out, was cancelled, or was skipped is reported.
#   2. If a pending marker exists and the window has opened, cut the build
#      through `release-decide.sh --apply --phase now`, which uses the repo's
#      DEFERRED mechanism.
#
# A pending marker on a `label:`-only repo cannot be cut here — GitHub does not
# re-fire `pull_request: [closed]` for a label added to a merged PR. That is
# reported ONCE per marker (not once per sweep) and the marker is kept, so the
# repo's next merge ships the accumulated work.
#
# Output (AC11): one line per action. A cut build is a single line. Failures and
# blockers get one line each. A sweep with nothing to do prints nothing.
#
# Usage:
#   release-sweep.sh [--repo <owner/name>] [--json] [--quiet]
#   release-sweep.sh --help
#
# --repo    sweep only this repo (default: every repo with release state)
# --json    emit a JSON array of events instead of human lines
# --quiet   suppress the human lines; exit code still reports attention needed
#
# Exit codes:
#   0  swept; nothing needs attention
#   1  swept; one or more items need attention (printed unless --quiet)
#   4  environment error
#
# Env overrides:
#   RELEASE_RUN_APPEAR_GRACE_MIN (15)  how long to wait for a triggered run to
#                                      appear before calling the trigger failed
#
# Invoked from: session start (session-scheduling-reconcile.sh), each
# /pr-monitor-and-manage tick, and each /wrap post-merge step.
# Mechanism: .claude/reference/release-cadence.md

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_SH="$SCRIPT_DIR/session-state.sh"
DECIDE_SH="$SCRIPT_DIR/release-decide.sh"
POLICY_SH="$SCRIPT_DIR/release-policy.sh"
GRACE_MIN="${RELEASE_RUN_APPEAR_GRACE_MIN:-15}"

usage() { sed -n '2,/^set -uo pipefail$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//; $d'; }
die_usage() { echo "release-sweep.sh: $1" >&2; echo "Run --help for usage." >&2; exit 4; }

ONLY_REPO=""; AS_JSON=0; QUIET=0
while [ $# -gt 0 ]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --repo)  ONLY_REPO="${2:-}"; [ -n "$ONLY_REPO" ] || die_usage "--repo requires <owner/name>"; shift 2 ;;
    --json)  AS_JSON=1; shift ;;
    --quiet) QUIET=1; shift ;;
    *) die_usage "unknown argument: $1" ;;
  esac
done

command -v gh >/dev/null 2>&1 || { echo "release-sweep.sh: gh not found" >&2; exit 4; }
command -v jq >/dev/null 2>&1 || { echo "release-sweep.sh: jq not found" >&2; exit 4; }
[ -f "$STATE_SH" ] || { echo "release-sweep.sh: session-state.sh not found next to this script" >&2; exit 4; }

EVENTS='[]'
ATTENTION=0

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
NOW_EPOCH=$(date -u +%s)

to_epoch() {  # $1 = ISO-8601 Z timestamp; prints epoch seconds or nothing
  local ts="$1"
  [ -n "$ts" ] && [ "$ts" != "null" ] || return 1
  date -u -d "$ts" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$ts" +%s 2>/dev/null
}

record() {  # $1 = kind, $2 = repo, $3 = line, $4 = needs_attention (0|1)
  EVENTS=$(jq -cn --argjson prev "$EVENTS" --arg kind "$1" --arg repo "$2" \
                  --arg line "$3" --argjson att "$([ "$4" = "1" ] && echo true || echo false)" \
           '$prev + [{kind:$kind, repo:$repo, line:$line, needs_attention:$att}]')
  [ "$4" = "1" ] && ATTENTION=1
  if [ "$AS_JSON" = "0" ] && [ "$QUIET" = "0" ]; then
    echo "$3"
  fi
  return 0
}

state_get() { "$STATE_SH" --raw-path --get ".repos[\"$1\"].release.$2" 2>/dev/null || echo null; }
# Every write here is load-bearing. A discarded failure would leave the in-flight
# record uncleared, which both re-reports the same terminal event on the next
# sweep and permanently blocks step 2's "never start a second build" guard — the
# marker would sit stuck forever while looking exactly like a healthy wait. So a
# failed write is reported as an attention event rather than dropped. The sweep
# continues to the next repo: one repo's unwritable state is not a reason to stop
# following every other repo's builds.
STATE_WRITE_ERR=""
state_set() {
  local repo="$1"; shift
  local args=() sub val rc=0
  while [ $# -gt 0 ]; do
    sub="$1"; val="$2"; shift 2
    args+=(--set ".repos[\"$repo\"].release.$sub=$val")
  done
  STATE_WRITE_ERR="$("$STATE_SH" --raw-path "${args[@]}" 2>&1 >/dev/null)" || rc=$?
  if [ "$rc" -eq 0 ]; then
    STATE_WRITE_ERR=""
  else
    [ -n "$STATE_WRITE_ERR" ] || STATE_WRITE_ERR="session-state.sh exited $rc"
    record "state_write_failed" "$repo" \
      "release state could not be saved — $repo: $STATE_WRITE_ERR (until this clears, the build outcome is not being followed)" 1
  fi
  return "$rc"
}

# --- Which repos to sweep -----------------------------------------------------
if [ -n "$ONLY_REPO" ]; then
  REPOS="$ONLY_REPO"
else
  REPOS=$("$STATE_SH" --raw-path --get '[(.repos // {}) | to_entries[] | select(.value.release != null) | .key] | .[]' 2>/dev/null)
fi

while IFS= read -r REPO; do
  [ -n "$REPO" ] || continue

  # ---- 1. Resolve the in-flight build to a terminal state --------------------
  IN_FLIGHT=$(state_get "$REPO" "in_flight")
  if [ -n "$IN_FLIGHT" ] && [ "$IN_FLIGHT" != "null" ]; then
    RUN_ID=$(printf '%s' "$IN_FLIGHT" | jq -r '.run_id // empty')
    TRIGGERED_AT=$(printf '%s' "$IN_FLIGHT" | jq -r '.triggered_at // empty')
    IF_PR=$(printf '%s' "$IN_FLIGHT" | jq -r '.pr // empty')

    # The policy tells us which workflows count as this repo's pipeline. A repo
    # whose policy has since been disabled or removed still gets its in-flight
    # build resolved — dropping it silently is the failure mode this prevents.
    POLICY_JSON=$(bash "$POLICY_SH" --repo "$REPO" --no-derive 2>/dev/null)
    # Plain guard, NOT ${POLICY_JSON:-{}} — a brace parameter-expansion default
    # terminates at the first literal `}`, which mangles any JSON default.
    if [ -z "$POLICY_JSON" ]; then POLICY_JSON='{}'; fi
    WORKFLOWS_JSON=$(printf '%s' "$POLICY_JSON" | jq -c '.release_workflows // []' 2>/dev/null)
    [ -n "$WORKFLOWS_JSON" ] || WORKFLOWS_JSON='[]'

    RUNS='[]'
    while IFS= read -r wf; do
      [ -n "$wf" ] || continue
      ONE=$(gh run list -R "$REPO" --workflow="$wf" --limit 20 \
              --json databaseId,status,conclusion,createdAt,updatedAt,url 2>/dev/null) || ONE=""
      [ -n "$ONE" ] || continue
      printf '%s' "$ONE" | jq -e 'type == "array"' >/dev/null 2>&1 || continue
      RUNS=$(jq -cn --argjson a "$RUNS" --argjson b "$ONE" '$a + $b')
    done < <(printf '%s' "$WORKFLOWS_JSON" | jq -r '.[]')

    RUN=''
    if [ -n "$RUN_ID" ]; then
      RUN=$(printf '%s' "$RUNS" | jq -c --argjson id "$RUN_ID" 'map(select(.databaseId == $id)) | first // empty')
    elif [ -n "$TRIGGERED_AT" ]; then
      # The oldest run created at or after the trigger — the one we caused.
      # 60s of slack absorbs clock skew between us and GitHub.
      RUN=$(printf '%s' "$RUNS" | jq -c --arg t "$TRIGGERED_AT" '
        map(select((.createdAt | fromdateiso8601) >= (($t | fromdateiso8601) - 60)))
        | sort_by(.createdAt) | first // empty')
    fi

    if [ -z "$RUN" ]; then
      TRIG_EPOCH=$(to_epoch "$TRIGGERED_AT") || TRIG_EPOCH=""
      if [ -n "$TRIG_EPOCH" ] && [ $(( (NOW_EPOCH - TRIG_EPOCH) / 60 )) -ge "$GRACE_MIN" ]; then
        record "trigger_no_run" "$REPO" \
          "TestFlight release did not start — $REPO: no run appeared within ${GRACE_MIN}m of $(printf '%s' "$IN_FLIGHT" | jq -r '.detail // "the trigger"')" 1
        state_set "$REPO" "in_flight" "null"
      fi
    else
      R_STATUS=$(printf '%s' "$RUN" | jq -r '.status')
      R_CONCL=$(printf '%s' "$RUN" | jq -r '.conclusion // ""')
      R_ID=$(printf '%s' "$RUN" | jq -r '.databaseId')
      R_URL=$(printf '%s' "$RUN" | jq -r '.url // ""')
      if [ -z "$RUN_ID" ]; then
        state_set "$REPO" "in_flight" "$(printf '%s' "$IN_FLIGHT" | jq -c --argjson id "$R_ID" '.run_id = $id | .awaiting_run = false')"
      fi
      if [ "$R_STATUS" = "completed" ]; then
        case "$R_CONCL" in
          success)
            state_set "$REPO" "in_flight" "null" \
              "last_seen_build" "$(jq -cn --argjson id "$R_ID" --arg at "$(printf '%s' "$RUN" | jq -r '.updatedAt')" \
                                    '{run_id:$id, conclusion:"success", completed_at:$at}')"
            ;;
          skipped)
            record "release_skipped" "$REPO" \
              "TestFlight release skipped — $REPO run $R_ID produced no build (the trigger fired but the workflow's own guard did not match): $R_URL" 1
            state_set "$REPO" "in_flight" "null"
            ;;
          *)
            record "release_failed" "$REPO" \
              "TestFlight release ${R_CONCL:-did not complete} — $REPO run $R_ID${IF_PR:+ (PR #$IF_PR)}: $R_URL" 1
            state_set "$REPO" "in_flight" "null" \
              "last_seen_build" "$(jq -cn --argjson id "$R_ID" --arg c "$R_CONCL" --arg at "$(printf '%s' "$RUN" | jq -r '.updatedAt')" \
                                    '{run_id:$id, conclusion:$c, completed_at:$at}')"
            ;;
        esac
      fi
      # status != completed: still building. Nothing to say — silence here is
      # correct, and the next sweep resolves it.
    fi
  fi

  # ---- 2. Cut a pending build whose window has opened ------------------------
  PENDING=$(state_get "$REPO" "pending")
  [ -n "$PENDING" ] && [ "$PENDING" != "null" ] || continue

  # Re-read in-flight: step 1 may have just cleared or kept it.
  IN_FLIGHT=$(state_get "$REPO" "in_flight")
  if [ -n "$IN_FLIGHT" ] && [ "$IN_FLIGHT" != "null" ]; then
    continue  # a build is still processing; never start a second one (AC9)
  fi

  P_PR=$(printf '%s' "$PENDING" | jq -r '.pr // empty')
  DEC_RC=0
  DEC=$(bash "$DECIDE_SH" --repo "$REPO" --phase now --apply 2>/dev/null) || DEC_RC=$?
  case "$DEC_RC" in
    0)
      record "build_cut" "$REPO" "cut TestFlight build — $REPO${P_PR:+ (PR #$P_PR)}" 0
      ;;
    3)
      # Report a blocker once per marker, not once per sweep. A label-only repo
      # sits here until its next merge; repeating that every tick is noise.
      NOTIFIED=$(printf '%s' "$PENDING" | jq -r '.notified_at // empty')
      if [ -z "$NOTIFIED" ]; then
        if [ -z "$DEC" ]; then DEC='{}'; fi
        record "pending_blocked" "$REPO" \
          "TestFlight release pending but not cuttable — $REPO: $(printf '%s' "$DEC" | jq -r '.reason // "unknown reason"')" 1
        state_set "$REPO" "pending" "$(printf '%s' "$PENDING" | jq -c --arg at "$(now_iso)" '.notified_at = $at')"
      fi
      ;;
    *)
      # 1 = still inside the window or nothing to do; 2 = policy now off. Both
      # are ordinary states, not events.
      ;;
  esac
done <<< "$REPOS"

if [ "$AS_JSON" = "1" ]; then
  printf '%s\n' "$EVENTS"
fi

exit "$ATTENTION"
