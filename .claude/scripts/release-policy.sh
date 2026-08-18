#!/usr/bin/env bash
# release-policy.sh — Resolve a repo's agent-initiated TestFlight release policy (issue #1169).
#
# Reads `.claude/release-policy.json` from the repo's DEFAULT BRANCH via the
# GitHub contents API and emits a normalized policy as single-line JSON. When
# `min_interval` is `"auto"`, derives the minimum inter-build interval from that
# repo's OWN history — release-workflow run durations and recent merge
# timestamps — rather than a hardcoded constant.
#
# DEFAULT IS OFF. A repo with no policy file never auto-releases. This script
# never triggers a build, never applies a label, and never writes state; it only
# reports what a repo's policy says. `release-decide.sh` owns the decision and
# `release-sweep.sh` owns deferred execution.
#
# WHY THE DEFAULT BRANCH, NOT THE WORKING TREE: the policy that governs a merge
# is the one on `main`, not whatever a feature branch happens to have edited.
# Reading through the API keeps one code path and the right semantics.
#
# POLICY SCHEMA (all fields optional except `enabled`):
#   {
#     "enabled": true,                       // false or absent file => OFF
#     "min_interval": "auto",                // "auto" | "45m" | "2h" | 90
#     "trigger": "label:release:ios",        // label:<name> | workflow_dispatch:<file> | none
#     "deferred_trigger": "workflow_dispatch:mobile-testflight.yml",
#     "release_workflows": ["mobile-testflight.yml"],
#     "suppress": {"paths": ["docs/**"], "labels": ["no-release"]},
#     "expedite": {"paths": [], "labels": ["hotfix"]},
#     "max_builds_per_day": 8
#   }
#
# TRIGGER MECHANISMS are respected, never normalized (issue #1169 AC2):
#   label:<name>              apply the label to the PR — IMMEDIATE ONLY. GitHub
#                             does not re-fire `pull_request: [closed]` for a
#                             label added to an already-closed PR, so this
#                             mechanism cannot be used by the deferred sweep.
#   workflow_dispatch:<file>  dispatch that workflow on the default branch.
#                             Usable immediately and deferred. The file MUST be
#                             one of `release_workflows` — this is what keeps the
#                             App Store release path unreachable (AC3).
#   none                      the repo already builds automatically; do nothing.
#   anything else             FAILS CLOSED (exit 4). Never silently remapped.
#
# `deferred_trigger` defaults to `trigger` when that mechanism supports
# deferral, and to "" (unavailable) for `label:`.
#
# AUTO DERIVATION (AC5):
#   median_build_min = median duration of SUCCESSFUL runs of `release_workflows`
#                      from the last 90 days — duration >= 5 min, any single run
#                      over 120 min discarded as an outlier. Widens past the
#                      90-day window only when it holds fewer than 3 samples,
#                      and falls back to failed/timed-out runs only when there
#                      are no successes at all.
#                      Three filters, three real failure modes measured on these
#                      repos: `skipped` runs would derive a 1-second build time
#                      (a label-gated workflow that fires and skips); sub-5-minute
#                      "successes" are runs where the build job itself was
#                      skipped, since GitHub concludes a run successful when its
#                      only real job never ran; and stale runs from a pipeline's
#                      setup months ago outnumber the builds it does today.
#   merges_per_day   = merged PRs in the trailing 14 days / 14, counted through
#                      the search API's exact `total_count` (a `gh pr list`
#                      --limit would silently cap the observed rate below the
#                      budget and make the budget term unreachable).
#   compute_term     = RELEASE_BUILD_FACTOR x median_build_min  (never build back-to-back)
#   budget_term      = merges_per_day > max_builds_per_day ? 1440/max_builds_per_day : 0
#   interval         = clamp(max(compute_term, budget_term, notify_floor), 15, 240)
#   No building runs in history => documented 60-minute default.
#
#   Both history axes are load-bearing: build duration sets the compute floor,
#   and the merge rate is what turns a tester-notification budget into a widened
#   interval — binding only when the repo would otherwise exceed that budget.
#
# An EXPLICIT `min_interval` is honored as written (the owner's override) and is
# NOT clamped; only the derived value is.
#
# Usage:
#   release-policy.sh [--repo <owner/name>] [--no-derive]
#   release-policy.sh --detect [--repo <owner/name>]
#   release-policy.sh --help
#
# --no-derive   skip the `auto` derivation API calls; emits
#               min_interval_minutes: null with interval_source "auto-undetermined".
#               Callers that cache a derived interval pass this on warm reads.
# --detect      print the detected release-workflow filenames, one per line,
#               and exit 0; exit 3 when none are found. No policy file needed.
#
# Output: single-line JSON on stdout for every exit code EXCEPT usage errors, so
# a caller can always read `.reason`.
#
# Exit codes:
#   0  policy resolved and agent-initiated releases are ENABLED
#   1  OFF — file absent, or "enabled": false (the default; not an error)
#   3  no iOS release pipeline detected in this repo (inert)
#   4  environment/usage error, or a malformed policy (FAIL CLOSED — do not release)
#
# Env overrides (testing / tuning):
#   RELEASE_BUILD_FACTOR (3)            RELEASE_NOTIFY_FLOOR_MIN (20)
#   RELEASE_INTERVAL_MIN_CLAMP (15)     RELEASE_INTERVAL_MAX_CLAMP (240)
#   RELEASE_DEFAULT_INTERVAL_MIN (60)   RELEASE_HISTORY_RUNS (40)
#   RELEASE_MERGE_LOOKBACK_DAYS (14)    RELEASE_BUILD_OUTLIER_CAP_MIN (120)
#   RELEASE_BUILD_MIN_MINUTES (5)       RELEASE_MAX_BUILDS_PER_DAY (8)
#   RELEASE_HISTORY_WINDOW_DAYS (90)    RELEASE_MIN_SAMPLE (3)
#
# Mechanism, per-repo notes, and the pre-merge-label finding:
#   .claude/reference/release-cadence.md

set -uo pipefail

BUILD_FACTOR="${RELEASE_BUILD_FACTOR:-3}"
NOTIFY_FLOOR_MIN="${RELEASE_NOTIFY_FLOOR_MIN:-20}"
INTERVAL_MIN_CLAMP="${RELEASE_INTERVAL_MIN_CLAMP:-15}"
INTERVAL_MAX_CLAMP="${RELEASE_INTERVAL_MAX_CLAMP:-240}"
DEFAULT_INTERVAL_MIN="${RELEASE_DEFAULT_INTERVAL_MIN:-60}"
HISTORY_RUNS="${RELEASE_HISTORY_RUNS:-40}"
MERGE_LOOKBACK_DAYS="${RELEASE_MERGE_LOOKBACK_DAYS:-14}"
BUILD_OUTLIER_CAP_MIN="${RELEASE_BUILD_OUTLIER_CAP_MIN:-120}"
BUILD_MIN_MINUTES="${RELEASE_BUILD_MIN_MINUTES:-5}"
DEFAULT_MAX_BUILDS_PER_DAY="${RELEASE_MAX_BUILDS_PER_DAY:-8}"
HISTORY_WINDOW_DAYS="${RELEASE_HISTORY_WINDOW_DAYS:-90}"
MIN_SAMPLE="${RELEASE_MIN_SAMPLE:-3}"
NOW_EPOCH_POLICY=$(date -u +%s)

POLICY_PATH=".claude/release-policy.json"

usage() { sed -n '2,/^set -uo pipefail$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//; $d'; }

die_usage() { echo "release-policy.sh: $1" >&2; echo "Run --help for usage." >&2; exit 4; }

# Emit the JSON envelope and exit. $1 = exit code, $2 = reason, $3 = extra jq object (may be "{}").
emit() {
  # Plain guard, NOT ${3:-{}} — a brace parameter-expansion default terminates
  # at the first literal `}` and would mangle any JSON default.
  local code="$1" reason="$2" extra="${3:-}"
  if [ -z "$extra" ]; then extra='{}'; fi
  jq -cn \
    --arg repo "$REPO" \
    --arg reason "$reason" \
    --argjson enabled "$([ "$code" = "0" ] && echo true || echo false)" \
    --argjson extra "$extra" \
    '{repo:$repo, enabled:$enabled, reason:$reason} + $extra'
  exit "$code"
}

# Portable "N days ago" as YYYY-MM-DD (GNU date first, BSD/macOS fallback).
lookback_date() {
  local days="$1" out
  out=$(date -u -d "${days} days ago" +%Y-%m-%d 2>/dev/null) && { echo "$out"; return 0; }
  date -u -v-"${days}"d +%Y-%m-%d 2>/dev/null
}

MODE="policy"
REPO=""
DERIVE=1

while [ $# -gt 0 ]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --detect)  MODE="detect"; shift ;;
    --no-derive) DERIVE=0; shift ;;
    --repo)    REPO="${2:-}"; [ -n "$REPO" ] || die_usage "--repo requires <owner/name>"; shift 2 ;;
    *)         die_usage "unknown argument: $1" ;;
  esac
done

command -v gh >/dev/null 2>&1 || { echo "release-policy.sh: gh not found" >&2; exit 4; }
command -v jq >/dev/null 2>&1 || { echo "release-policy.sh: jq not found" >&2; exit 4; }

if [ -z "$REPO" ]; then
  REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null)
  [ -n "$REPO" ] || { echo "release-policy.sh: could not resolve repo (pass --repo owner/name)" >&2; exit 4; }
fi

# --- Release-pipeline detection (AC12: by pipeline presence, never a repo list) ---
# A TestFlight pipeline is a workflow whose filename mentions testflight. The App
# Store release path is excluded by name so it can never be picked up here.
detect_workflows() {
  gh api "repos/$REPO/contents/.github/workflows" --jq '.[].name' 2>/dev/null \
    | grep -i 'testflight' \
    | grep -vi 'app-store' \
    || true
}

if [ "$MODE" = "detect" ]; then
  DETECTED=$(detect_workflows)
  if [ -z "$DETECTED" ]; then
    echo "release-policy.sh: no TestFlight release workflow detected in $REPO" >&2
    exit 3
  fi
  printf '%s\n' "$DETECTED"
  exit 0
fi

# --- Read the policy file from the default branch ------------------------------
RAW=""
API_RC=0
POLICY_ERR_FILE=$(mktemp -t release-policy-err.XXXXXX)
trap 'rm -f "$POLICY_ERR_FILE"' EXIT
API_ERR=""
RAW=$(gh api "repos/$REPO/contents/$POLICY_PATH" --jq '.content' 2>"$POLICY_ERR_FILE") || API_RC=$?
[ -s "$POLICY_ERR_FILE" ] && API_ERR=$(tr '\n' ' ' < "$POLICY_ERR_FILE")

if [ "$API_RC" -ne 0 ] || [ -z "$RAW" ]; then
  # A 404 means the repo never opted in. Anything else (rate limit, auth,
  # network) means the policy was never READ — the same inert outcome, but a
  # different fact, and reporting it as "off by default" hides an outage.
  if [ "$API_RC" -ne 0 ] && [ -n "$API_ERR" ] && ! printf '%s' "$API_ERR" | grep -qiE '404|not found'; then
    emit 1 "could not read $POLICY_PATH in $REPO — treating as off, but this is a lookup failure, not an opt-out: $API_ERR" \
      '{"policy_source":"unreadable"}'
  fi
  emit 1 "no $POLICY_PATH in $REPO — agent-initiated releases are off by default" \
    '{"policy_source":"absent"}'
fi

POLICY=$(printf '%s' "$RAW" | tr -d '\n' | base64 --decode 2>/dev/null)
if [ -z "$POLICY" ] || ! printf '%s' "$POLICY" | jq -e . >/dev/null 2>&1; then
  emit 4 "malformed $POLICY_PATH in $REPO — not valid JSON (failing closed: no release)" \
    '{"policy_source":"api"}'
fi

ENABLED=$(printf '%s' "$POLICY" | jq -r '.enabled // false')
if [ "$ENABLED" != "true" ]; then
  emit 1 "$POLICY_PATH sets enabled=false in $REPO — agent-initiated releases are off" \
    '{"policy_source":"api"}'
fi

# --- Release workflows ---------------------------------------------------------
WORKFLOWS_JSON=$(printf '%s' "$POLICY" | jq -c '.release_workflows // []')
WORKFLOW_SOURCE="policy"
if [ "$(printf '%s' "$WORKFLOWS_JSON" | jq 'length')" -eq 0 ]; then
  DETECTED=$(detect_workflows)
  if [ -z "$DETECTED" ]; then
    emit 3 "no TestFlight release workflow detected in $REPO and none declared" \
      '{"policy_source":"api"}'
  fi
  WORKFLOWS_JSON=$(printf '%s\n' "$DETECTED" | jq -R . | jq -sc .)
  WORKFLOW_SOURCE="detected"
fi

# A declared workflow that names the App Store path is a configuration error, not
# something to quietly drop — the whole point of AC3 is that this path is never
# reachable, so say so loudly rather than releasing with a half-honored policy.
if printf '%s' "$WORKFLOWS_JSON" | jq -e 'map(ascii_downcase) | any(test("app-store"))' >/dev/null 2>&1; then
  emit 4 "release_workflows names an App Store release workflow — TestFlight only (failing closed)" \
    '{"policy_source":"api"}'
fi

# --- Trigger mechanisms (respected, not normalized) ---------------------------
TRIGGER=$(printf '%s' "$POLICY" | jq -r '.trigger // "none"')
DEFERRED=$(printf '%s' "$POLICY" | jq -r '.deferred_trigger // ""')

validate_mechanism() {  # $1 = mechanism string, $2 = field name
  local m="$1" field="$2"
  case "$m" in
    none) return 0 ;;
    label:?*) return 0 ;;
    workflow_dispatch:?*)
      local wf="${m#workflow_dispatch:}"
      if ! printf '%s' "$WORKFLOWS_JSON" | jq -e --arg w "$wf" 'index($w)' >/dev/null 2>&1; then
        emit 4 "$field names workflow '$wf', which is not in release_workflows (failing closed)" \
          '{"policy_source":"api"}'
      fi
      return 0 ;;
    *) emit 4 "unrecognized $field mechanism '$m' — expected label:<name>, workflow_dispatch:<file>, or none (failing closed)" \
         '{"policy_source":"api"}' ;;
  esac
}

validate_mechanism "$TRIGGER" "trigger"

if [ -z "$DEFERRED" ]; then
  # Default: reuse the immediate mechanism when it can be deferred. `label:`
  # cannot — a label on an already-closed PR fires nothing.
  case "$TRIGGER" in
    label:*) DEFERRED="" ;;
    *)       DEFERRED="$TRIGGER" ;;
  esac
else
  validate_mechanism "$DEFERRED" "deferred_trigger"
  case "$DEFERRED" in
    label:*) emit 4 "deferred_trigger cannot be a label mechanism — GitHub does not re-fire pull_request:[closed] for a label on a closed PR (failing closed)" \
               '{"policy_source":"api"}' ;;
  esac
fi

SUPPRESS=$(printf '%s' "$POLICY" | jq -c '{paths: (.suppress.paths // []), labels: (.suppress.labels // [])}')
EXPEDITE=$(printf '%s' "$POLICY" | jq -c '{paths: (.expedite.paths // []), labels: (.expedite.labels // [])}')
MAX_BUILDS=$(printf '%s' "$POLICY" | jq -r --argjson d "$DEFAULT_MAX_BUILDS_PER_DAY" '.max_builds_per_day // $d')
case "$MAX_BUILDS" in
  ''|*[!0-9]*) emit 4 "max_builds_per_day must be a positive integer (failing closed)" '{"policy_source":"api"}' ;;
esac
[ "$MAX_BUILDS" -gt 0 ] || emit 4 "max_builds_per_day must be > 0 (failing closed)" '{"policy_source":"api"}'

# --- Interval: explicit override, or derived from this repo's own history -----
MIN_INTERVAL_RAW=$(printf '%s' "$POLICY" | jq -r '.min_interval // "auto"')
INTERVAL_MINUTES="null"
INTERVAL_SOURCE=""
DERIVATION='{}'

parse_duration() {  # echoes minutes, or nothing when unparseable
  local v="$1" n
  if [[ "$v" =~ ^([0-9]+)[[:space:]]*(m|min|mins|minute|minutes)?$ ]]; then
    echo "${BASH_REMATCH[1]}"; return 0
  fi
  if [[ "$v" =~ ^([0-9]+)[[:space:]]*(h|hr|hrs|hour|hours)$ ]]; then
    n="${BASH_REMATCH[1]}"; echo $(( n * 60 )); return 0
  fi
  return 1
}

if [ "$MIN_INTERVAL_RAW" != "auto" ]; then
  EXPLICIT=$(parse_duration "$MIN_INTERVAL_RAW") || EXPLICIT=""
  if [ -z "$EXPLICIT" ] || [ "$EXPLICIT" -le 0 ]; then
    emit 4 "min_interval '$MIN_INTERVAL_RAW' is not 'auto' or a positive duration like 45m / 2h / 90 (failing closed)" \
      '{"policy_source":"api"}'
  fi
  # An explicit value is the owner's override — honored as written, never clamped.
  INTERVAL_MINUTES="$EXPLICIT"
  INTERVAL_SOURCE="policy"
elif [ "$DERIVE" -eq 0 ]; then
  INTERVAL_SOURCE="auto-undetermined"
else
  # Build-duration sample across every declared/detected release workflow.
  RUNS='[]'
  while IFS= read -r wf; do
    [ -n "$wf" ] || continue
    ONE=$(gh run list -R "$REPO" --workflow="$wf" --limit "$HISTORY_RUNS" \
            --json status,conclusion,createdAt,updatedAt 2>/dev/null) || ONE=""
    [ -n "$ONE" ] || continue
    printf '%s' "$ONE" | jq -e 'type == "array"' >/dev/null 2>&1 || continue
    RUNS=$(jq -cn --argjson a "$RUNS" --argjson b "$ONE" '$a + $b')
  done < <(printf '%s' "$WORKFLOWS_JSON" | jq -r '.[]')

  # SUCCESSFUL builds are the sample: "how expensive is this repo's build" is a
  # question about a build that ran to completion. A failure that aborts in
  # under two minutes (tag collision, missing secret) never built anything, and
  # mixing those in halves the median — measured on still-point, where the real
  # ~13-minute builds derived a 3-minute median once its short failures were
  # counted. Failures are the fallback only, so a repo whose builds are
  # currently red still derives something rather than falling to the default.
  durations_for() {  # $1 = comma-separated conclusions, $2 = oldest createdAt epoch (0 = no bound)
    printf '%s' "$RUNS" | jq -c \
      --argjson floor "$BUILD_MIN_MINUTES" \
      --argjson cap "$BUILD_OUTLIER_CAP_MIN" \
      --argjson since "$2" \
      --arg sel "$1" '
      [ .[]
        | select(.status == "completed")
        | select(.conclusion as $c | ($sel | split(",") | index($c)) != null)
        | select((.createdAt | fromdateiso8601) >= $since)
        | ((.updatedAt | fromdateiso8601) - (.createdAt | fromdateiso8601)) / 60
        | select(. >= $floor and . <= $cap)
      ] | sort'
  }

  # Recency matters as much as the conclusion. still-point's pipeline logged
  # 1-2 minute "successes" while it was being set up in the spring; by count
  # they outnumber this summer's real 13-19 minute builds and drag the median
  # to 2.8. A build time from four months ago is not this repo's build time.
  # Widen back to the full list only when the recent window is too thin to
  # median meaningfully.
  WINDOW_EPOCH_CUTOFF=$(( NOW_EPOCH_POLICY - HISTORY_WINDOW_DAYS * 86400 ))
  DURATIONS=$(durations_for "success" "$WINDOW_EPOCH_CUTOFF")
  DURATION_BASIS="success"
  DURATION_WINDOWED=true
  if [ "$(printf '%s' "$DURATIONS" | jq 'length')" -lt "$MIN_SAMPLE" ]; then
    WIDER=$(durations_for "success" 0)
    if [ "$(printf '%s' "$WIDER" | jq 'length')" -ge "$MIN_SAMPLE" ]; then
      DURATIONS="$WIDER"; DURATION_WINDOWED=false
    fi
  fi
  if [ "$(printf '%s' "$DURATIONS" | jq 'length')" -eq 0 ]; then
    DURATIONS=$(durations_for "failure,timed_out" 0)
    DURATION_BASIS="failure"
    DURATION_WINDOWED=false
  fi

  SAMPLE=$(printf '%s' "$DURATIONS" | jq 'length')
  MEDIAN=$(printf '%s' "$DURATIONS" | jq '
    if length == 0 then null
    elif (length % 2) == 1 then .[(length - 1) / 2]
    else ((.[length/2 - 1] + .[length/2]) / 2) end')

  SINCE=$(lookback_date "$MERGE_LOOKBACK_DAYS")
  MERGE_COUNT=0
  MERGE_COUNT_SATURATED=false
  if [ -n "$SINCE" ]; then
    # The search API returns an exact total_count with no page cap. `gh pr list`
    # cannot substitute as the primary: it tops out at its --limit, and a cap of
    # 100 over a 14-day lookback saturates at 7.14 merges/day — below the default
    # 8/day budget, so the budget term could never fire no matter how fast the
    # repo actually merges. >= (not >) so the boundary day is not dropped.
    SEARCH_COUNT=$(gh api -X GET search/issues \
                     -f q="repo:$REPO is:pr is:merged merged:>=$SINCE" \
                     -f per_page=1 --jq '.total_count' 2>/dev/null)
    if [ -n "$SEARCH_COUNT" ] && [ -z "${SEARCH_COUNT//[0-9]/}" ]; then
      MERGE_COUNT="$SEARCH_COUNT"
    else
      # Fallback only: flag saturation so a capped count is never mistaken for a
      # genuinely low merge rate.
      MERGED_JSON=$(gh pr list -R "$REPO" --state merged --limit 100 \
                      --search "merged:>=$SINCE" --json number 2>/dev/null) || MERGED_JSON=""
      if [ -n "$MERGED_JSON" ] && printf '%s' "$MERGED_JSON" | jq -e 'type == "array"' >/dev/null 2>&1; then
        MERGE_COUNT=$(printf '%s' "$MERGED_JSON" | jq 'length')
        [ "$MERGE_COUNT" -ge 100 ] && MERGE_COUNT_SATURATED=true
      fi
    fi
  fi

  DERIVATION=$(jq -cn \
    --argjson median "$MEDIAN" \
    --argjson sample "$SAMPLE" \
    --argjson merges "$MERGE_COUNT" \
    --argjson saturated "$MERGE_COUNT_SATURATED" \
    --arg basis "$DURATION_BASIS" \
    --argjson windowed "$DURATION_WINDOWED" \
    --argjson windowdays "$HISTORY_WINDOW_DAYS" \
    --argjson days "$MERGE_LOOKBACK_DAYS" \
    --argjson factor "$BUILD_FACTOR" \
    --argjson floor "$NOTIFY_FLOOR_MIN" \
    --argjson budget "$MAX_BUILDS" \
    --argjson lo "$INTERVAL_MIN_CLAMP" \
    --argjson hi "$INTERVAL_MAX_CLAMP" \
    --argjson fallback "$DEFAULT_INTERVAL_MIN" '
    ($merges / $days) as $per_day
    | (if $median == null then null else ($factor * $median) end) as $compute
    | (if $per_day > $budget then (1440 / $budget) else 0 end) as $budget_term
    | (if $compute == null then $fallback
       else ([$compute, $budget_term, $floor] | max
             | if . < $lo then $lo elif . > $hi then $hi else . end)
       end) as $raw
    | {
        median_build_minutes: (if $median == null then null else ($median * 10 | round / 10) end),
        sample_size: $sample,
        sample_basis: $basis,
        sample_windowed: $windowed,
        sample_window_days: $windowdays,
        merged_prs: $merges,
        merged_prs_saturated: $saturated,
        lookback_days: $days,
        merges_per_day: ($per_day * 100 | round / 100),
        compute_term: (if $compute == null then null else ($compute * 10 | round / 10) end),
        budget_term: ($budget_term * 10 | round / 10),
        notify_floor: $floor,
        interval_minutes: ($raw | round),
        history_absent: ($median == null)
      }')

  INTERVAL_MINUTES=$(printf '%s' "$DERIVATION" | jq '.interval_minutes')
  if [ "$(printf '%s' "$DERIVATION" | jq -r '.history_absent')" = "true" ]; then
    INTERVAL_SOURCE="default"
  else
    INTERVAL_SOURCE="auto"
  fi
fi

EXTRA=$(jq -cn \
  --arg source "api" \
  --arg trigger "$TRIGGER" \
  --arg deferred "$DEFERRED" \
  --arg isource "$INTERVAL_SOURCE" \
  --arg wsource "$WORKFLOW_SOURCE" \
  --argjson interval "$INTERVAL_MINUTES" \
  --argjson workflows "$WORKFLOWS_JSON" \
  --argjson suppress "$SUPPRESS" \
  --argjson expedite "$EXPEDITE" \
  --argjson maxbuilds "$MAX_BUILDS" \
  --argjson derivation "$DERIVATION" '
  {
    policy_source: $source,
    min_interval_minutes: $interval,
    interval_source: $isource,
    trigger: $trigger,
    deferred_trigger: $deferred,
    release_workflows: $workflows,
    release_workflows_source: $wsource,
    suppress: $suppress,
    expedite: $expedite,
    max_builds_per_day: $maxbuilds,
    derivation: $derivation
  }')

emit 0 "" "$EXTRA"
