#!/usr/bin/env bash
# release-decide.sh — Decide whether a merge warrants a TestFlight build, and
# optionally pull the trigger that repo already uses (issue #1169).
#
# One rule produces both desired behaviors with no mode switch:
#
#   On merge, build if enough time has passed since the last build FINISHED.
#   Otherwise mark the repo as having a release pending, and cut it the moment
#   the window opens.
#
# When PRs land once an hour the window has always elapsed, so every merge
# ships. When PRs land every five minutes, merges coalesce into roughly one
# build per window. The behavior tracks the actual merge cadence instead of
# needing to be told what it is.
#
# NEVER adds a build path, workflow, or signing config to any repo, and never
# touches the App Store release path — only TestFlight, only through the
# mechanism that repo's policy declares.
#
# GROUND TRUTH, NOT BOOKKEEPING: the last build's completion time and whether a
# build is in flight are read from the repo's GitHub run history, not from our
# own state. Builds cut outside this automation (a manual dispatch, inventory's
# automatic path) are therefore respected, and the state self-heals.
#
# PHASES — the mechanism decides WHEN it can act:
#   --phase pre-merge   acts only for `label:` mechanisms. GitHub does not
#                       re-fire `pull_request: [closed]` for a label added to an
#                       already-closed PR, so the label must land before the
#                       merge. No-op for every other mechanism.
#   --phase post-merge  acts only for `workflow_dispatch:` and `none`. A
#                       dispatch before the merge would build the pre-merge
#                       default branch. No-op for `label:` (already applied).
#   --phase now         (default) sweep/manual context: uses the DEFERRED
#                       mechanism, because the PR is long since merged.
#
# A phase mismatch is a no-op, never a silent wrong-time trigger.
#
# CLASSES (AC7, AC8):
#   expedite  any expedite label, or any changed path matching expedite.paths →
#             build immediately, window ignored. Checked FIRST: an urgent change
#             that also looks docs-shaped is still urgent.
#   suppress  a suppress label, or EVERY changed path matching suppress.paths →
#             no build and NO pending marker. Partial matches are not suppressed:
#             one app-touching file in a docs-heavy PR still counts.
#   normal    everything else — subject to the window.
#
# The concurrency guard outranks expedite: a build is never started while one is
# still processing (AC9). Expedite skips the window, not the guard.
#
# Usage:
#   release-decide.sh --repo <owner/name> [--pr N] [--apply]
#                     [--phase pre-merge|post-merge|now] [--reason <text>]
#   release-decide.sh --help
#
# Without --apply nothing is written and nothing is triggered — the decision is
# printed and that is all. This is the safe way to point it at a repo and see
# what it would do.
#
# Output: single-line JSON on stdout for every exit code except usage errors.
#   {repo, pr, phase, decision, reason, class, interval_minutes, interval_source,
#    last_build_completed_at, window_opens_at, in_flight_run_id, trigger,
#    mechanism_used, applied, applied_detail, pending, state_write_error}
#
# state_write_error is empty on a healthy run and carries session-state.sh's own
# stderr when a durable write did not land.
#
# decision ∈ build_now | pending | suppressed | in_flight | disabled |
#            no_pipeline | deferred | blocked
#
# Exit codes:
#   0  build_now (trigger executed when --apply was passed)
#   1  nothing to do now — pending | suppressed | in_flight | deferred
#   2  inert — disabled | no_pipeline
#   3  blocked — needs a human (malformed policy, no deferred trigger, trigger failed)
#   4  environment/usage error
#
# Env overrides: RELEASE_INTERVAL_CACHE_MIN (60) — how long a derived interval is
# reused from state before re-deriving. Plus every override release-policy.sh reads.
#
# State: ~/.claude/session-state.json at .repos["<owner>/<name>"].release, written
# only through session-state.sh (the lock-respecting path). Schema:
# .claude/reference/session-state-schema.json. Mechanism: .claude/reference/release-cadence.md

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POLICY_SH="$SCRIPT_DIR/release-policy.sh"
STATE_SH="$SCRIPT_DIR/session-state.sh"
# .repos["<owner>/<name>"] keys are ALWAYS lowercase (session-state-schema.json
# _scope_key_contract). Share the one normalizer every other derivation point
# uses, so a mixed-case remote can never open a second scope for the same repo.
NORMALIZER_LIB="$SCRIPT_DIR/lib/repo-normalizer.sh"
if [ -f "$NORMALIZER_LIB" ]; then
  # shellcheck source=./lib/repo-normalizer.sh
  . "$NORMALIZER_LIB"
else
  normalize_repo_key() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
fi
INTERVAL_CACHE_MIN="${RELEASE_INTERVAL_CACHE_MIN:-60}"

usage() { sed -n '2,/^set -uo pipefail$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//; $d'; }
die_usage() { echo "release-decide.sh: $1" >&2; echo "Run --help for usage." >&2; exit 4; }

REPO=""; PR=""; APPLY=0; PHASE="now"; REASON_TEXT=""

while [ $# -gt 0 ]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --repo)   REPO="${2:-}"; [ -n "$REPO" ] || die_usage "--repo requires <owner/name>"; shift 2 ;;
    --pr)     PR="${2:-}";   [ -n "$PR" ]   || die_usage "--pr requires a number"; shift 2 ;;
    --apply)  APPLY=1; shift ;;
    --phase)  [ $# -ge 2 ] || die_usage "--phase must be pre-merge, post-merge, or now"
              PHASE="$2"; shift 2
              case "$PHASE" in pre-merge|post-merge|now) ;; *) die_usage "--phase must be pre-merge, post-merge, or now" ;; esac ;;
    # Arity, not emptiness: `--reason ""` is a legitimate caller choice, but a
    # trailing bare `--reason` must not spin. (`shift 2` on one remaining
    # positional is a no-op that returns non-zero, and set -e is off.)
    --reason) [ $# -ge 2 ] || die_usage "--reason requires <text>"
              REASON_TEXT="$2"; shift 2 ;;
    *) die_usage "unknown argument: $1" ;;
  esac
done

command -v gh >/dev/null 2>&1 || { echo "release-decide.sh: gh not found" >&2; exit 4; }
command -v jq >/dev/null 2>&1 || { echo "release-decide.sh: jq not found" >&2; exit 4; }
[ -x "$POLICY_SH" ] || [ -f "$POLICY_SH" ] || { echo "release-decide.sh: release-policy.sh not found next to this script" >&2; exit 4; }

if [ -z "$REPO" ]; then
  REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null)
  [ -n "$REPO" ] || { echo "release-decide.sh: could not resolve repo (pass --repo owner/name)" >&2; exit 4; }
fi
REPO="$(normalize_repo_key "$REPO")"

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
NOW_EPOCH=$(date -u +%s)

# --- Durable state helpers (repo-scoped; --raw-path because auto-scoping only
# --- rewrites .prs / .root_repo, and --session-view drops the .repos block) ---
state_get() {  # $1 = subpath under .release (e.g. "pending"); prints JSON or "null"
  [ -f "$STATE_SH" ] || { echo null; return 0; }
  "$STATE_SH" --raw-path --get ".repos[\"$REPO\"].release.$1" 2>/dev/null || echo null
}
# A discarded write here would be the worst failure this script has: it would
# report `pending` — "the sweep will cut this later" — while the marker that the
# sweep reads never landed, and the merge would silently never ship. So the
# write's exit code is propagated and its stderr kept; callers decide whether
# their write was load-bearing. Non-zero from session-state.sh includes 5
# (missing sibling library) and 6 (lock timeout).
STATE_WRITE_ERR=""
state_set() {  # pairs of subpath / json-value; non-zero when the write did NOT land
  local args=() sub val rc=0
  if [ ! -f "$STATE_SH" ]; then
    STATE_WRITE_ERR="session-state.sh not found at $STATE_SH"
    return 1
  fi
  while [ $# -gt 0 ]; do
    sub="$1"; val="$2"; shift 2
    args+=(--set ".repos[\"$REPO\"].release.$sub=$val")
  done
  STATE_WRITE_ERR="$("$STATE_SH" --raw-path "${args[@]}" 2>&1 >/dev/null)" || rc=$?
  if [ "$rc" -eq 0 ]; then
    STATE_WRITE_ERR=""
  elif [ -z "$STATE_WRITE_ERR" ]; then
    STATE_WRITE_ERR="session-state.sh exited $rc"
  fi
  return "$rc"
}

# Final emit. $1 exit code, $2 decision, $3 reason, $4 extra JSON object.
APPLIED=0; APPLIED_DETAIL=""; MECHANISM_USED=""
CLASS="unknown"; INTERVAL="null"; INTERVAL_SOURCE=""; LAST_BUILD="null"
WINDOW_OPENS="null"; IN_FLIGHT_RUN="null"; TRIGGER=""; PENDING_JSON="null"

emit() {
  local code="$1" decision="$2" reason="$3"
  jq -cn \
    --arg repo "$REPO" --arg phase "$PHASE" --arg decision "$decision" \
    --arg reason "$reason" --arg class "$CLASS" --arg isource "$INTERVAL_SOURCE" \
    --arg trigger "$TRIGGER" --arg mech "$MECHANISM_USED" --arg detail "$APPLIED_DETAIL" \
    --arg swerr "$STATE_WRITE_ERR" \
    --argjson pr "${PR:-null}" --argjson interval "$INTERVAL" \
    --argjson last "$LAST_BUILD" --argjson window "$WINDOW_OPENS" \
    --argjson inflight "$IN_FLIGHT_RUN" --argjson applied "$([ "$APPLIED" = "1" ] && echo true || echo false)" \
    --argjson pending "$PENDING_JSON" '
    {repo:$repo, pr:$pr, phase:$phase, decision:$decision, reason:$reason,
     class:$class, interval_minutes:$interval, interval_source:$isource,
     last_build_completed_at:$last, window_opens_at:$window,
     in_flight_run_id:$inflight, trigger:$trigger, mechanism_used:$mech,
     applied:$applied, applied_detail:$detail, pending:$pending,
     state_write_error:$swerr}'
  exit "$code"
}

# --- Resolve policy, reusing a cached derived interval when it is still fresh --
CACHED_INTERVAL=$(state_get "interval_minutes")
CACHED_AT=$(state_get "derived_at" | tr -d '"')
USE_CACHE=0
if [ -n "$CACHED_INTERVAL" ] && [ "$CACHED_INTERVAL" != "null" ] && [ -n "$CACHED_AT" ] && [ "$CACHED_AT" != "null" ]; then
  CACHED_EPOCH=$(date -u -d "$CACHED_AT" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$CACHED_AT" +%s 2>/dev/null)
  if [ -n "$CACHED_EPOCH" ] && [ $(( (NOW_EPOCH - CACHED_EPOCH) / 60 )) -lt "$INTERVAL_CACHE_MIN" ]; then
    USE_CACHE=1
  fi
fi

POLICY_RC=0
if [ "$USE_CACHE" = "1" ]; then
  POLICY_JSON=$(bash "$POLICY_SH" --repo "$REPO" --no-derive 2>/dev/null) || POLICY_RC=$?
else
  POLICY_JSON=$(bash "$POLICY_SH" --repo "$REPO" 2>/dev/null) || POLICY_RC=$?
fi
[ -n "$POLICY_JSON" ] || POLICY_JSON='{"reason":"release-policy.sh produced no output"}'

POLICY_REASON=$(printf '%s' "$POLICY_JSON" | jq -r '.reason // ""')
case "$POLICY_RC" in
  0) ;;
  1) emit 2 "disabled" "$POLICY_REASON" ;;
  3) emit 2 "no_pipeline" "$POLICY_REASON" ;;
  *) emit 3 "blocked" "${POLICY_REASON:-release-policy.sh failed (rc=$POLICY_RC)}" ;;
esac

TRIGGER=$(printf '%s' "$POLICY_JSON" | jq -r '.trigger')
DEFERRED_TRIGGER=$(printf '%s' "$POLICY_JSON" | jq -r '.deferred_trigger')
WORKFLOWS_JSON=$(printf '%s' "$POLICY_JSON" | jq -c '.release_workflows')
SUPPRESS_JSON=$(printf '%s' "$POLICY_JSON" | jq -c '.suppress')
EXPEDITE_JSON=$(printf '%s' "$POLICY_JSON" | jq -c '.expedite')
INTERVAL_SOURCE=$(printf '%s' "$POLICY_JSON" | jq -r '.interval_source')
INTERVAL=$(printf '%s' "$POLICY_JSON" | jq '.min_interval_minutes')

if [ "$USE_CACHE" = "1" ] && [ "$INTERVAL_SOURCE" = "policy" ]; then
  # The repo switched from "auto" to an explicit min_interval since the cache was
  # written. The owner's override wins immediately — never after a cache TTL.
  USE_CACHE=0
fi

# A cached value is read back from JSON and feeds `$(( ))`; anything non-integer
# (a hand-edited 22.5) would abort the arithmetic rather than degrade.
case "$CACHED_INTERVAL" in ''|*[!0-9]*) USE_CACHE=0 ;; esac

if [ "$USE_CACHE" = "1" ]; then
  INTERVAL="$CACHED_INTERVAL"
  INTERVAL_SOURCE=$(state_get "interval_source" | tr -d '"')
  [ -n "$INTERVAL_SOURCE" ] && [ "$INTERVAL_SOURCE" != "null" ] || INTERVAL_SOURCE="auto"
elif [ "$INTERVAL" != "null" ] && [ "$INTERVAL_SOURCE" != "policy" ]; then
  # Caching the derived interval only saves a re-derivation next run; it can
  # never make a decision wrong. This is the one write allowed to fail without
  # blocking — it still surfaces via state_write_error, and the load-bearing
  # writes below fail loudly on their own.
  state_set "interval_minutes" "$INTERVAL" \
            "interval_source" "\"$INTERVAL_SOURCE\"" \
            "derived_at" "\"$(now_iso)\"" || true
fi

if [ "$INTERVAL" = "null" ]; then
  emit 3 "blocked" "could not resolve a minimum interval for $REPO"
fi

# --- Which mechanism applies in this phase ------------------------------------
case "$PHASE" in
  pre-merge)
    case "$TRIGGER" in
      label:*) MECHANISM_USED="$TRIGGER" ;;
      *)       emit 1 "deferred" "trigger '$TRIGGER' acts after the merge, not before it" ;;
    esac ;;
  post-merge)
    case "$TRIGGER" in
      label:*) emit 1 "deferred" "label mechanisms are applied before the merge; nothing to do here" ;;
      *)       MECHANISM_USED="$TRIGGER" ;;
    esac ;;
  now)
    MECHANISM_USED="$DEFERRED_TRIGGER" ;;
esac

# --- Classify the change ------------------------------------------------------
PENDING_JSON=$(state_get "pending")
[ -n "$PENDING_JSON" ] || PENDING_JSON="null"

CLASS="normal"
if [ -n "$PR" ]; then
  PR_JSON=$(gh pr view "$PR" -R "$REPO" --json files,labels 2>/dev/null) || PR_JSON=""
  if [ -z "$PR_JSON" ]; then
    emit 3 "blocked" "could not read PR #$PR in $REPO to classify its changes"
  fi
  LABELS_JSON=$(printf '%s' "$PR_JSON" | jq -c '[.labels[].name]')

  # `gh pr view --json files` returns at most 100 entries with no truncation
  # signal. Suppression asks whether EVERY changed path is ignorable, so a
  # truncated list can only ever make a PR look MORE suppressible than it is —
  # the one direction that silently skips a build for real app changes. Page the
  # REST endpoint instead, and fail closed if the full list cannot be read.
  FILES_JSON=$(gh api --paginate "repos/$REPO/pulls/$PR/files" --jq '.[].path' 2>/dev/null \
                 | jq -Rsc 'split("\n") | map(select(length > 0))') || FILES_JSON=""
  if [ -z "$FILES_JSON" ] || [ "$FILES_JSON" = "null" ]; then
    # Fall back to the capped list rather than blocking, but never let a capped
    # list drive a suppression: 100 entries means "possibly truncated".
    FILES_JSON=$(printf '%s' "$PR_JSON" | jq -c '[.files[].path]')
    if [ "$(printf '%s' "$FILES_JSON" | jq 'length')" -ge 100 ]; then
      emit 3 "blocked" "could not read the complete changed-file list for PR #$PR in $REPO (capped at 100) — refusing to classify, since a truncated list can only make a PR look more suppressible than it is"
    fi
  fi

  LABEL_CLASS=$(jq -rn \
    --argjson labels "$LABELS_JSON" --argjson sup "$SUPPRESS_JSON" --argjson exp "$EXPEDITE_JSON" '
    if ($labels | any(. as $l | $exp.labels | index($l))) then "expedite"
    elif ($labels | any(. as $l | $sup.labels | index($l))) then "suppress"
    else "" end')

  # Glob matching lives in python3: `**` must cross directory separators while a
  # single `*` must not, which fnmatch alone does not express.
  PATH_CLASS=$(FILES_JSON="$FILES_JSON" SUPPRESS_JSON="$SUPPRESS_JSON" EXPEDITE_JSON="$EXPEDITE_JSON" \
    python3 -c '
import json, os, re

def to_regex(glob):
    out, i, n = [], 0, len(glob)
    while i < n:
        c = glob[i]
        if c == "*":
            if glob[i:i+3] == "**/":
                out.append("(?:.*/)?"); i += 3; continue
            if glob[i:i+2] == "**":
                out.append(".*"); i += 2; continue
            out.append("[^/]*"); i += 1; continue
        if c == "?":
            out.append("[^/]"); i += 1; continue
        out.append(re.escape(c)); i += 1
    return re.compile("^" + "".join(out) + "$")

files = json.loads(os.environ["FILES_JSON"])
sup = [to_regex(p) for p in json.loads(os.environ["SUPPRESS_JSON"]).get("paths", [])]
exp = [to_regex(p) for p in json.loads(os.environ["EXPEDITE_JSON"]).get("paths", [])]

if exp and any(r.match(f) for f in files for r in exp):
    print("expedite")
elif files and sup and all(any(r.match(f) for r in sup) for f in files):
    print("suppress")
else:
    print("")
')
  PATH_CLASS_RC=$?
  if [ "$PATH_CLASS_RC" -ne 0 ]; then
    # Never let a failed classification masquerade as "nothing matched": that
    # silently builds suppress-only PRs and delays expedite ones.
    emit 3 "blocked" "path classification failed (python3 exited $PATH_CLASS_RC) — refusing to classify $REPO PR #$PR rather than treating every path as unmatched"
  fi

  if [ "$LABEL_CLASS" = "expedite" ] || [ "$PATH_CLASS" = "expedite" ]; then
    CLASS="expedite"
  elif [ "$LABEL_CLASS" = "suppress" ] || [ "$PATH_CLASS" = "suppress" ]; then
    CLASS="suppress"
  fi
fi

if [ "$CLASS" = "suppress" ]; then
  # No build and no pending marker — a change that cannot affect the app never
  # starts the clock. An existing marker from earlier real work is left alone.
  emit 1 "suppressed" "changes cannot affect the app (suppress class) — no build, no pending marker"
fi

# --- Build history: last completion + anything still processing ---------------
RUNS='[]'
while IFS= read -r wf; do
  [ -n "$wf" ] || continue
  ONE=$(gh run list -R "$REPO" --workflow="$wf" --limit 20 \
          --json databaseId,status,conclusion,createdAt,updatedAt 2>/dev/null) || ONE=""
  [ -n "$ONE" ] || continue
  printf '%s' "$ONE" | jq -e 'type == "array"' >/dev/null 2>&1 || continue
  RUNS=$(jq -cn --argjson a "$RUNS" --argjson b "$ONE" '$a + $b')
done < <(printf '%s' "$WORKFLOWS_JSON" | jq -r '.[]')

IN_FLIGHT_RUN=$(printf '%s' "$RUNS" | jq '
  [ .[] | select(.status != "completed") ] | sort_by(.createdAt) | last | .databaseId // null')

# Same floor as release-policy.sh's median derivation: GitHub concludes a run
# successful when its only real job was skipped, so duration is what separates a
# build from a no-op.
BUILD_MIN_SEC=$(( ${RELEASE_BUILD_MIN_MINUTES:-5} * 60 ))
LAST_BUILD=$(printf '%s' "$RUNS" | jq -c --argjson minsec "$BUILD_MIN_SEC" '
  [ .[]
    | select(.status == "completed")
    | select(.conclusion == "success" or .conclusion == "failure" or .conclusion == "timed_out")
    | select(((.updatedAt | fromdateiso8601) - (.createdAt | fromdateiso8601)) >= $minsec)
    | .updatedAt
  ] | sort | last // null')

if [ "$IN_FLIGHT_RUN" != "null" ]; then
  # Concurrency guard outranks expedite (AC9). Keep/refresh the pending marker so
  # the sweep cuts it once the in-flight build lands and the window opens.
  if [ "$APPLY" = "1" ]; then
    PENDING_JSON=$(jq -cn --argjson prev "$PENDING_JSON" --argjson pr "${PR:-null}" --arg now "$(now_iso)" '
      if $prev == null then {since:$now, pr:$pr, count:1, reason:"build in flight"}
      else $prev + {pr:(if $pr == null then $prev.pr else $pr end), count:(($prev.count // 0) + 1), reason:"build in flight"} end')
    if ! state_set "pending" "$PENDING_JSON"; then
      emit 3 "blocked" "a build of $REPO is still processing (run $IN_FLIGHT_RUN) but the pending marker could not be saved, so no sweep will cut this work later: $STATE_WRITE_ERR"
    fi
  fi
  emit 1 "in_flight" "a build of $REPO is still processing (run $IN_FLIGHT_RUN) — not starting a second one"
fi

# --- Window ------------------------------------------------------------------
BUILD_NOW=0
WINDOW_REASON=""
if [ "$CLASS" = "expedite" ]; then
  BUILD_NOW=1; WINDOW_REASON="expedite class — window skipped"
elif [ "$LAST_BUILD" = "null" ]; then
  BUILD_NOW=1; WINDOW_REASON="no prior build in history"
else
  LAST_CLEAN=$(printf '%s' "$LAST_BUILD" | tr -d '"')
  LAST_EPOCH=$(date -u -d "$LAST_CLEAN" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$LAST_CLEAN" +%s 2>/dev/null)
  if [ -z "$LAST_EPOCH" ]; then
    BUILD_NOW=1; WINDOW_REASON="could not parse last build completion — treating window as open"
  else
    WINDOW_EPOCH=$(( LAST_EPOCH + INTERVAL * 60 ))
    WINDOW_OPENS="\"$(date -u -r "$WINDOW_EPOCH" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$WINDOW_EPOCH" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)\""
    ELAPSED_MIN=$(( (NOW_EPOCH - LAST_EPOCH) / 60 ))
    if [ "$ELAPSED_MIN" -ge "$INTERVAL" ]; then
      BUILD_NOW=1; WINDOW_REASON="${ELAPSED_MIN}m since the last build finished (window ${INTERVAL}m)"
    else
      WINDOW_REASON="only ${ELAPSED_MIN}m since the last build finished (window ${INTERVAL}m)"
    fi
  fi
fi

if [ "$BUILD_NOW" = "0" ]; then
  if [ "$APPLY" = "1" ]; then
    PENDING_JSON=$(jq -cn --argjson prev "$PENDING_JSON" --argjson pr "${PR:-null}" --arg now "$(now_iso)" '
      if $prev == null then {since:$now, pr:$pr, count:1, reason:"inside the build window"}
      else $prev + {pr:(if $pr == null then $prev.pr else $pr end), count:(($prev.count // 0) + 1), reason:"inside the build window"} end')
    if ! state_set "pending" "$PENDING_JSON"; then
      emit 3 "blocked" "$WINDOW_REASON, but the pending marker could not be saved, so no sweep will cut this work later: $STATE_WRITE_ERR"
    fi
  fi
  emit 1 "pending" "$WINDOW_REASON — release pending"
fi

# --- build_now: execute the mechanism ----------------------------------------
if [ "$APPLY" = "0" ]; then
  emit 0 "build_now" "$WINDOW_REASON (dry run — nothing triggered)"
fi

if [ -z "$MECHANISM_USED" ]; then
  # Sweep-time on a label-only repo: the label cannot re-fire on a merged PR, so
  # the pending marker stays and the repo's next merge ships it. Surfaced, never
  # silently dropped.
  emit 3 "blocked" "window is open but $REPO has no deferred trigger (label mechanisms cannot fire on an already-merged PR) — it will ship on the next merge"
fi

# The claim is staked before any trigger runs. session-state.sh --cas stakes
# the claim atomically: it reads the current value and writes the claim record
# only when the path is currently null — all under one lock hold. Exit 7 means
# another evaluation already owns the slot; the GitHub-history check still backs
# it up as a second line of defence. `none` repos are skipped — their build is
# not ours to claim.
CLAIM_WRITTEN=0
RELEASE_CLAIM_UNVERIFIED=0
# Release the claim if the trigger never actually fired, so a failed attempt does
# not wedge the repo as permanently "building".
# Uses --cas (issue #1195): clears the in_flight record only when it still holds
# exactly our CLAIM_RECORD — atomically, under one lock hold. Exit 7 means
# another evaluator already replaced our claim; their record is left intact.
release_claim() {
  [ "$CLAIM_WRITTEN" = "1" ] || return 0
  local rc=0
  "$STATE_SH" --raw-path \
    --cas ".repos[\"$REPO\"].release.in_flight=null" \
    --expect "$CLAIM_RECORD" 2>/dev/null || rc=$?
  # rc=0: cleared successfully (we owned it)
  # rc=7: someone else replaced our claim — leave their record intact
  # other: I/O or lock error — leave the record; the sweep's grace window heals it
  if [ "$rc" -ne 0 ] && [ "$rc" -ne 7 ]; then
    RELEASE_CLAIM_UNVERIFIED=1
  fi
}

if [ "$MECHANISM_USED" != "none" ]; then
  # Build the claim record. The token is retained for diagnostic output only;
  # the atomic guarantee now comes from --cas --expect null (issue #1195).
  CLAIM_TOKEN="$(date -u +%Y%m%dT%H%M%SZ)-$$-${RANDOM:-0}"
  CLAIM_RECORD=$(jq -cn --argjson pr "${PR:-null}" --arg mech "$MECHANISM_USED" --arg now "$(now_iso)" \
    --arg tok "$CLAIM_TOKEN" \
    '{pr:$pr, mechanism:$mech, triggered_at:$now, detail:"claim staked before trigger", run_id:null, awaiting_run:true, claim_token:$tok}')
  # Atomic claim: write only when the slot is currently null (no concurrent claim).
  # Exit 0 = won; 7 = lost (someone else's claim is now on record); other = I/O error.
  # Capture stderr so blocked-path emits can include the error in state_write_error.
  CAS_CLAIM_RC=0
  CAS_CLAIM_ERR=""
  CAS_CLAIM_ERR=$("$STATE_SH" --raw-path \
    --cas ".repos[\"$REPO\"].release.in_flight=$CLAIM_RECORD" \
    --expect null 2>&1 >/dev/null) || CAS_CLAIM_RC=$?
  if [ "$CAS_CLAIM_RC" -eq 0 ]; then
    CLAIM_WRITTEN=1
  elif [ "$CAS_CLAIM_RC" -eq 7 ]; then
    # Another evaluation already owns the slot — stand down rather than
    # starting a second concurrent build.
    emit 1 "in_flight" "another evaluation claimed the build for $REPO first — standing down rather than starting a second one"
  else
    STATE_WRITE_ERR="${CAS_CLAIM_ERR:-session-state.sh exited $CAS_CLAIM_RC}"
    emit 3 "blocked" "could not stake the in-flight claim for $REPO before triggering ($STATE_WRITE_ERR) — refusing to dispatch, since an unclaimed trigger can be duplicated by a concurrent evaluation"
  fi
fi

# Release the claim if the trigger never actually fired, so a failed attempt does
# not wedge the repo as permanently "building".
TRIGGER_RC=0
case "$MECHANISM_USED" in
  none)
    APPLIED=1
    APPLIED_DETAIL="repo builds automatically on merge — nothing to trigger"
    ;;
  label:*)
    LABEL="${MECHANISM_USED#label:}"
    [ -n "$PR" ] || { release_claim; emit 3 "blocked" "label mechanism needs a PR number (--pr)"; }
    OUT=$(gh pr edit "$PR" -R "$REPO" --add-label "$LABEL" 2>&1) || TRIGGER_RC=$?
    if [ "$TRIGGER_RC" -ne 0 ]; then
      release_claim
      emit 3 "blocked" "could not apply label '$LABEL' to PR #$PR in $REPO: $OUT"
    fi
    APPLIED=1
    APPLIED_DETAIL="applied label '$LABEL' to PR #$PR"
    ;;
  workflow_dispatch:*)
    WF="${MECHANISM_USED#workflow_dispatch:}"
    DISPATCH_REASON="${REASON_TEXT:-agent-initiated TestFlight build (release cadence, issue #1169)}"
    # Every dispatchable release workflow in this fleet declares a `reason`
    # input (required on longlove and inventory, optional on skingod). Try with
    # it, then once without, so a workflow that declares none still dispatches.
    OUT=$(gh workflow run "$WF" -R "$REPO" -f reason="$DISPATCH_REASON" 2>&1) || TRIGGER_RC=$?
    if [ "$TRIGGER_RC" -ne 0 ] && printf '%s' "$OUT" | grep -qiE 'unexpected inputs?|invalid input|input.*reason|reason.*not.*(defined|expected|accepted)'; then
      # Only this failure shape proves the dispatch was REJECTED rather than
      # possibly-accepted-then-lost, so only this one is safe to retry.
      TRIGGER_RC=0
      OUT=$(gh workflow run "$WF" -R "$REPO" 2>&1) || TRIGGER_RC=$?
    fi
    if [ "$TRIGGER_RC" -ne 0 ]; then
      release_claim
      emit 3 "blocked" "could not dispatch $WF in $REPO: $OUT"
    fi
    APPLIED=1
    APPLIED_DETAIL="dispatched $WF"
    ;;
  *)
    release_claim
    emit 3 "blocked" "unrecognized mechanism '$MECHANISM_USED' (failing closed)"
    ;;
esac

# Record: the pending marker is satisfied, and a build is now in flight for us to
# follow to a terminal state (AC10). `none` repos get no in-flight record — their
# build was not ours to trigger and is not ours to chase.
STATE_OK=1
if [ "$MECHANISM_USED" = "none" ]; then
  state_set "pending" "null" || STATE_OK=0
else
  # Updates the claim staked above rather than creating the record: triggered_at
  # keeps the claim's timestamp so the sweep's grace window measures from when we
  # committed to building, not from when the API call happened to return.
  IN_FLIGHT_RECORD=$(printf '%s' "$CLAIM_RECORD" | jq -c --arg detail "$APPLIED_DETAIL" '.detail = $detail')
  state_set "pending" "null" "in_flight" "$IN_FLIGHT_RECORD" || STATE_OK=0
fi
PENDING_JSON="null"

if [ "$STATE_OK" = "0" ]; then
  # Both halves are true and both get said: the build really was triggered
  # (applied stays true, applied_detail says what fired), and without the
  # in-flight record the sweep cannot follow it to a terminal state (AC10).
  # Exit 3 so a human looks, rather than a 0 that reads as fully handled.
  emit 3 "build_now" "$WINDOW_REASON — build triggered ($APPLIED_DETAIL) but its state could not be saved, so the outcome will not be followed automatically: $STATE_WRITE_ERR"
fi

emit 0 "build_now" "$WINDOW_REASON"
