#!/usr/bin/env bash
# monitor-quiet-tick.sh — Shell-side quiet-tick gate for the /babysit-pr and /pm day Monitors (issue #2459).
# catalog: scheduling-monitoring — Keep a /babysit-pr or /pm day Monitor silent on an unchanged tick while advancing its streak counters shell-side; emit on change, threshold or error
#
# Runs inside the Monitor loop, before the loop prints its tick line. A quiet
# tick starts no model turn, so the counters that turn would have advanced are
# advanced here instead, exactly as the turn would have: digest_streak +1,
# blocker_streak +1 when the last tick counted it, tick_count +1, last_tick_at
# now (so the tick watchdog still sees a live watcher). The tick that would cross a
# threshold is never quiet: it is emitted and the counter is left for the
# model, which then widens the cadence, pauses (stable-frozen) or terminates
# (blocker-tick-cap) exactly as before.
#
# The model writes the contract at the end of each tick it runs (--record):
# whether the next unchanged tick may be quiet, plus the input digest. The
# tick takes that digest with --print-digest BEFORE it classifies and passes it
# back as --tick-start-digest, so an event that lands while the tick runs is
# outside the recorded digest and the next Monitor tick emits for it. Without
# a current contract every tick emits, as before this script existed.
#
# USAGE
#   monitor-quiet-tick.sh --kind babysit --pr N --generation G [--repo owner/name] [--input-digest D]
#   monitor-quiet-tick.sh --kind pm-day --repo owner/name --generation G [--input-digest D]
#   monitor-quiet-tick.sh --record --kind babysit --pr N [--repo owner/name] --quiet-ok true|false
#       [--blocker-counting true|false] [--widen-at N] [--freeze-at N|none]
#       [--tick-start-digest D | --input-digest D]
#   monitor-quiet-tick.sh --record --kind pm-day --repo owner/name --quiet-ok true|false
#       [--widen-at N] [--freeze-at N|none] [--tick-start-digest D | --input-digest D]
#   monitor-quiet-tick.sh --print-digest --kind babysit|pm-day (--pr N | --repo owner/name)
#   monitor-quiet-tick.sh --disarm --kind babysit|pm-day (--pr N | --repo owner/name)
#   monitor-quiet-tick.sh --help
#
#   --disarm sets an armed contract to quiet_ok=false, prints nothing and exits 0.
#   A Monitor loop runs it on any tick it prints without the gate (the babysit
#   review-deadline tick), so no later tick goes quiet while that one is handled.
#   Every disarm (this mode and the tick-mode emits) retries a lost compare-and-set
#   against the fresh watcher object, then writes quiet_ok=false blind, then sets
#   a forced-emit flag under ~/.claude/monitor-quiet/. While that flag exists every
#   tick emits; a successful disarm or a fresh --record clears it.
#
#   --tick-start-digest (record only) is the --print-digest value the tick took
#   before classifying. babysit stores it as is. pm day keeps its external part
#   and re-reads only the .repos[R] keys the tick itself writes.
#   An empty value (the tick-start read failed) stores quiet_ok=false.
#   --input-digest replaces the shell read with a supplied value verbatim. It is
#   for tests; a Monitor loop never passes it, because a stale value would let a
#   changed tick pass as unchanged.
#   For babysit, reads resolve the PR from the working directory's repository, as
#   the skill's own tick does; --repo scopes session state and must name that same
#   repository, or the read fails and the tick emits.
#
# TICK MODE (default) — prints nothing on stdout, ever.
#   Quiet (exit 10) only when ALL hold: the watcher is active, not stopped,
#   not in a cadence transition, on this Monitor's generation; babysit has no
#   dispatch in flight, pm day is neither parked nor paused; the contract is
#   current (its tick_count equals the watcher's) with quiet_ok=true; the next
#   streak keeps the stored effective cadence (base below widen_at, else
#   max(15, 3 x base)), stays below freeze_at and, when counting, below
#   max_blocker_ticks; the freshly computed input digest equals the recorded
#   one; and the counter write wins its compare-and-set.
#   Anything else exits 0 (emit): a changed digest, a threshold crossing, a
#   stale or missing contract, unreadable state, a failed read, a read slower
#   than MONITOR_QUIET_DIGEST_TIMEOUT_S seconds (default 120), a lost write.
#   An emit from a quiet-eligible contract (change, threshold, digest read
#   failure) also disarms it (quiet_ok=false), so every tick emits until the
#   model's next tick records a fresh contract — no counter moves while the
#   model is handling the event. Failure always goes toward waking the model,
#   never toward silence.
#
# RECORD MODE — the model's end-of-tick call.
#   Stores {input_digest, quiet_ok, tick_count, widen_at, freeze_at,
#   blocker_counting, recorded_at, quiet_ticks:0} at .prs[N].babysit.quiet or
#   .repos[R].day.quiet. --quiet-ok true with neither --tick-start-digest nor
#   --input-digest, or a failed repo-state read, stores quiet_ok=false and exits 1.
#   Defaults: --widen-at 3, --freeze-at 9, --blocker-counting false.
#
# INPUT DIGEST (sha256 of a canonical projection, no clock-derived text)
#   Forms: babysit sha256:<hex>; pm day sha256:<external hex>.<own hex>.
#   babysit: merge-gate.sh (head, met, merge state, mergeable, human changes
#     requested, CI counts and blocking conclusions, stale bot changes,
#     missing[], no-review-override reason, cancelled retry, CodeAnt run),
#     pr-state.sh --stdout (unresolved threads, new findings, bot states,
#     check-runs), cr-review-hourly.sh / greptile-budget.sh --check exits,
#     usage-horizon.sh --check status.
#   pm-day external: .active_agents and the .repos[R] keys the tick does not own
#     (refill pause, window, leave, any other) with tick bookkeeping stripped, open
#     PRs by @me (head, updatedAt, merge state, review decision), open issues
#     (number, updatedAt), operator priority from pm-priority.sh show --json
#     (order and the parks in force today, so an overnight park expiry or a /desk
#     edit changes it), credit-budget.sh --check exit, horizon status.
#   pm-day own: the tick-owned .repos[R] keys (day, prs, pipelines,
#     pm_backlog_scan_at, pm_standing_queues, pm_receipts), bookkeeping stripped.
#
# EXIT STATUS
#   tick:   10 quiet; 0 emit; 2 usage (caller emits — any non-10 means emit)
#   record: 0 stored; 1 not stored or stored as quiet_ok=false after a read failure; 2 usage
#   print-digest: 0 printed; 1 read failure; 2 usage
set -uo pipefail
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" 2>/dev/null >> "${HOME:-/tmp}/.claude/script-usage.log" || true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_HELPER="${MONITOR_QUIET_STATE_HELPER:-$SCRIPT_DIR/session-state.sh}"

MODE=tick KIND="" PR="" REPO="" GENERATION="" INPUT_DIGEST="" TICK_START_DIGEST=""
QUIET_OK="" BLOCKER_COUNTING=false WIDEN_AT=3 FREEZE_AT=9

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; n = 1; next } { exit } END { exit(n ? 0 : 1) }' "$0" ||
    { printf '%s: --help header extraction produced no output\n' "$0" >&2; exit 70; }
}
usage_fail() { echo "monitor-quiet-tick.sh: $*" >&2; exit 2; }
emit() { echo "monitor-quiet-tick.sh: emit — $*" >&2; exit 0; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --record) MODE=record; shift ;;
    --print-digest) MODE=print; shift ;;
    --disarm) MODE=disarm; shift ;;
    --kind|--pr|--repo|--generation|--input-digest|--tick-start-digest|--quiet-ok|--blocker-counting|--widen-at|--freeze-at)
      [[ $# -ge 2 ]] || usage_fail "$1 needs a value"
      case "$1" in
        --kind) KIND="$2" ;; --pr) PR="$2" ;; --repo) REPO="$2" ;; --generation) GENERATION="$2" ;;
        --input-digest) INPUT_DIGEST="$2" ;; --tick-start-digest) TICK_START_DIGEST="$2" ;; --quiet-ok) QUIET_OK="$2" ;;
        --blocker-counting) BLOCKER_COUNTING="$2" ;; --widen-at) WIDEN_AT="$2" ;; --freeze-at) FREEZE_AT="$2" ;;
      esac
      shift 2 ;;
    *) usage_fail "unknown argument: $1" ;;
  esac
done

case "$KIND" in babysit|pm-day) ;; *) usage_fail "--kind must be babysit or pm-day" ;; esac
[[ -z "$REPO" || "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || usage_fail "--repo must be owner/name"
if [[ "$KIND" == babysit ]]; then
  [[ "$PR" =~ ^[1-9][0-9]*$ ]] || usage_fail "--pr must be a positive integer"
  OBJ_PATH=".prs[\"$PR\"]"
else
  [[ -n "$REPO" ]] || usage_fail "--kind pm-day needs --repo owner/name"
  OBJ_PATH=".repos[\"$REPO\"].day"
fi
if [[ "$MODE" == tick ]]; then
  [[ -n "$GENERATION" ]] || usage_fail "tick mode needs --generation"
fi
if [[ "$MODE" == record ]]; then
  [[ "$QUIET_OK" == true || "$QUIET_OK" == false ]] || usage_fail "--quiet-ok must be true or false"
  [[ "$BLOCKER_COUNTING" == true || "$BLOCKER_COUNTING" == false ]] || usage_fail "--blocker-counting must be true or false"
  [[ "$WIDEN_AT" =~ ^[1-9][0-9]*$ ]] || usage_fail "--widen-at must be a positive integer"
  [[ "$FREEZE_AT" == none || "$FREEZE_AT" =~ ^[1-9][0-9]*$ ]] || usage_fail "--freeze-at must be a positive integer or none"
  [[ "$KIND" == babysit || "$BLOCKER_COUNTING" == false ]] || usage_fail "--blocker-counting applies to --kind babysit only"
fi
# An empty --tick-start-digest (the tick-start read failed) is accepted and fails closed in record mode.
if [[ -n "$TICK_START_DIGEST" ]]; then
  [[ "$MODE" == record ]] || usage_fail "--tick-start-digest applies to --record only"
  if [[ "$KIND" == babysit ]]; then
    [[ "$TICK_START_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] || usage_fail "--tick-start-digest must be a babysit --print-digest value"
  else
    [[ "$TICK_START_DIGEST" =~ ^sha256:[0-9a-f]{64}\.[0-9a-f]{64}$ ]] || usage_fail "--tick-start-digest must be a pm-day --print-digest value"
  fi
fi

state() { if [[ -n "$REPO" ]]; then "$STATE_HELPER" --repo "$REPO" "$@"; else "$STATE_HELPER" "$@"; fi; }

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 | awk '{print $1}'
  else return 1; fi
}

# check_rc SCRIPT ARGS... — exit status of an optional helper's --check, or "na" when absent.
check_rc() {
  local s="$SCRIPT_DIR/$1"; shift
  [[ -x "$s" ]] || { echo na; return 0; }
  local rc=0
  "$s" "$@" >/dev/null 2>&1 || rc=$?
  echo "$rc"
}
# Horizon verdict; a present helper that prints no STATUS line is a failed read, never a value.
horizon_status() {
  local s="$SCRIPT_DIR/usage-horizon.sh" out st
  [[ -x "$s" ]] || { echo na; return 0; }
  out=$("$s" --check 2>/dev/null || true)
  st=$(printf '%s\n' "$out" | sed -n 's/^STATUS=//p' | head -1)
  [[ -n "$st" ]] || return 1
  echo "$st"
}

# Large JSON (a pr-state bundle carries full comment bodies) goes through files, never argv.
TMPD=""
tmpdir() {
  [[ -n "$TMPD" ]] && return 0
  TMPD=$(mktemp -d "${TMPDIR:-/tmp}/monitor-quiet-tick.XXXXXX") || return 1
  trap 'rm -f "$TMPD"/*.json "$TMPD"/digest.out; rmdir "$TMPD" 2>/dev/null' EXIT
}

# babysit reads, like the skill's own tick, resolve the PR from the working directory's
# repository; --repo only scopes session state, so a --repo naming another repository
# makes the read fail (emit) rather than digest a different repository's PR.
babysit_projection() {
  local grc=0 created hz cwd_repo
  tmpdir || return 1
  if [[ -n "$REPO" ]]; then
    cwd_repo=$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null) || return 1
    [[ "$(printf '%s' "$cwd_repo" | tr '[:upper:]' '[:lower:]')" == "$(printf '%s' "$REPO" | tr '[:upper:]' '[:lower:]')" ]] || return 1
  fi
  "$SCRIPT_DIR/merge-gate.sh" "$PR" > "$TMPD/gate.json" 2>/dev/null || grc=$?
  case "$grc" in
    0|1) ;;
    3) jq -cn '{gone:true}'; return 0 ;;   # closed/merged/not found: a change the model must classify
    *) return 1 ;;
  esac
  created=$(gh pr view "$PR" --json createdAt --jq '.createdAt' 2>/dev/null) || return 1
  [[ -n "$created" ]] || return 1
  "$SCRIPT_DIR/pr-state.sh" --pr "$PR" --since "$created" --stdout > "$TMPD/bundle.json" 2>/dev/null || return 1
  hz=$(horizon_status) || return 1
  # A degenerate read (empty or non-object output) must fail, never project to constants.
  jq -cnS --slurpfile gs "$TMPD/gate.json" --slurpfile bs "$TMPD/bundle.json" \
    --arg cr "$(check_rc cr-review-hourly.sh --check)" --arg gr "$(check_rc greptile-budget.sh --check)" \
    --arg hz "$hz" '
    if ($gs | length) != 1 or ($gs[0] | type) != "object" or ($gs[0].head_sha | type) != "string"
       or $gs[0].head_sha == "" or ($bs | length) != 1 or ($bs[0] | type) != "object"
       or ($bs[0].threads | type) != "object" or ($bs[0].check_runs | type) != "object"
    then error("degenerate merge-gate or pr-state read") else . end |
    $gs[0] as $g | $bs[0] as $b | {
      head: ($g.head_sha // ""), met: $g.met, merge_state: ($g.merge_state // ""), mergeable: ($g.mergeable // ""),
      human_cr: (($g.human_changes_requested // []) | length),
      ci: {failing: ($g.ci_status.failing // 0), in_progress: ($g.ci_status.in_progress // 0),
           blocking: ([($g.ci_status.blocking // [])[] | .conclusion] | sort)},
      stale_bot_cr: ($g.stale_bot_changes_requested_count // 0),
      missing: (($g.missing // []) | sort),
      nro: ($g.no_review_override.reason // null),
      cancelled_retry: (($g.required_contexts.cancelled_retry // null) != null),
      codeant_run: ($g.review_evidence.reviewers["codeant-ai[bot]"] // {} | {run_started_at, run_done}),
      unresolved: ($b.threads.unresolved_count // null),
      new_findings: ($b.new_since_baseline.finding_count // 0),
      bots: (($b.bot_statuses // {}) | with_entries(.value |= (.state // null))),
      checks: ([($b.check_runs.all // [])[] | {name: (.name // ""), status: (.status // ""), conclusion: (.conclusion // "")}] | sort_by(.name, .status, .conclusion)),
      cr_budget: $cr, greptile_budget: $gr, horizon: $hz}'
}

JQ_STRIP='def strip: walk(if type == "object"
  then del(.last_tick_at, .tick_count, .digest, .digest_streak, .blocker_streak, .quiet, .last_tick_parse_failures)
  else . end);'

# pm day digest has two parts (issue #2459). The external part is what a model tick
# classifies on, so the contract pins it from the tick's start: agents, GitHub, budget,
# horizon, and every .repos[R] key this tick does not own — the human refill pause, the
# leave/window deadline, and any key added later. The own part is the keys the tick
# itself writes (TICK_OWN); the contract re-reads only those at record time, so the
# tick's own writes do not defeat quiet while another session's write still emits.
JQ_OWN='def own_keys: ["day", "prs", "pipelines", "pm_backlog_scan_at", "pm_standing_queues", "pm_receipts"];
  def own: with_entries(select(.key as $k | own_keys | index($k)));
  def foreign: with_entries(select(.key as $k | own_keys | index($k) | not));'

read_repo_state() {
  tmpdir || return 1
  state --get-json ".repos[\"$REPO\"]" > "$TMPD/repo.json" 2>/dev/null || return 1
}

# Operator priority as D2's refill applies it today: the /desk order and the parks still
# in force. pm-priority.sh filters parks by today's date (America/New_York), so a park that
# expires overnight leaves this list and changes the digest with no file write. `today`,
# `updated_at` and the file path are dropped: they move without changing what refill does.
# An absent helper is "na", as /pm's own read degrades; any failed or malformed read fails.
priority_projection() {
  local s="$SCRIPT_DIR/pm-priority.sh"
  [[ -x "$s" ]] || { printf '%s\n' '"na"'; return 0; }
  "$s" --repo "$REPO" show --json > "$TMPD/prio.json" 2>/dev/null || return 1
  jq -cS 'if type == "object" and (.order | type) == "array" and (.parked | type) == "array"
          then {present, order, parked} else error("malformed pm-priority read") end' "$TMPD/prio.json" 2>/dev/null
}

pm_day_external_projection() {
  local hz
  tmpdir || return 1
  hz=$(horizon_status) || return 1
  priority_projection > "$TMPD/prio-proj.json" || return 1
  [[ -s "$TMPD/prio-proj.json" ]] || return 1
  read_repo_state || return 1
  state --get-json '.active_agents' > "$TMPD/agents.json" 2>/dev/null || return 1
  gh pr list --repo "$REPO" --author "@me" --state open --limit 200 \
    --json number,headRefOid,updatedAt,mergeStateStatus,reviewDecision > "$TMPD/prs.json" 2>/dev/null || return 1
  gh issue list --repo "$REPO" --state open --limit 300 --json number,updatedAt > "$TMPD/issues.json" 2>/dev/null || return 1
  jq -cnS --slurpfile ss "$TMPD/repo.json" --slurpfile ags "$TMPD/agents.json" \
    --slurpfile ps "$TMPD/prs.json" --slurpfile iss "$TMPD/issues.json" --slurpfile pri "$TMPD/prio-proj.json" \
    --arg budget "$(check_rc credit-budget.sh --check)" --arg hz "$hz" "$JQ_STRIP$JQ_OWN"'
    if ([$ss, $ags, $ps, $iss, $pri] | any(length != 1)) or ($ss[0] | type) != "object"
       or ($ps[0] | type) != "array" or ($iss[0] | type) != "array"
    then error("degenerate state or GitHub read") else . end |
    {repo_foreign: ($ss[0] | foreign | strip), agents: ($ags[0] | strip),
     prs: ($ps[0] | sort_by(.number)), issues: ($iss[0] | sort_by(.number)), priority: $pri[0],
     budget: $budget, horizon: $hz}'
}

pm_day_state_projection() {
  read_repo_state || return 1
  jq -cnS --slurpfile ss "$TMPD/repo.json" "$JQ_STRIP$JQ_OWN"'
    if ($ss | length) != 1 or ($ss[0] | type) != "object" then error("degenerate state read") else . end |
    {repo_own: ($ss[0] | own | strip)}'
}

# hex_of PROJECTION — sha256 hex of a projection; fails on an empty one.
hex_of() {
  local d
  [[ -n "$1" ]] || return 1
  d=$(printf '%s' "$1" | sha256) || return 1
  [[ "$d" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s' "$d"
}
state_hex() { local p; p=$(pm_day_state_projection) || return 1; hex_of "$p"; }

# Digest forms: babysit sha256:<hex>; pm day sha256:<external hex>.<state hex>.
compute_digest() {
  local p e s
  if [[ "$KIND" == babysit ]]; then
    p=$(babysit_projection) || return 1
    e=$(hex_of "$p") || return 1
    printf 'sha256:%s\n' "$e"
  else
    p=$(pm_day_external_projection) || return 1
    e=$(hex_of "$p") || return 1
    s=$(state_hex) || return 1
    printf 'sha256:%s.%s\n' "$e" "$s"
  fi
}

# bounded_digest — compute_digest with a wall-clock bound. A hung GitHub read must not
# hold the Monitor loop before it prints: past the bound the read counts as failed, so
# the tick emits. MONITOR_QUIET_DIGEST_TIMEOUT_S overrides the bound (default 120).
bounded_digest() {
  local limit="${MONITOR_QUIET_DIGEST_TIMEOUT_S:-120}" pid wd rc=0
  [[ "$limit" =~ ^[1-9][0-9]*$ ]] || limit=120
  tmpdir || return 1
  compute_digest > "$TMPD/digest.out" & pid=$!
  ( i=0; while (( i < limit )); do kill -0 "$pid" 2>/dev/null || exit 0; sleep 1; i=$((i + 1)); done
    kill -KILL "$pid" 2>/dev/null ) & wd=$!   # TERM waits for the subshell's running $(...) to return
  wait "$pid" || rc=$?
  kill "$wd" 2>/dev/null; wait "$wd" 2>/dev/null
  (( rc == 0 )) || return 1
  [[ -s "$TMPD/digest.out" ]] || return 1
  cat "$TMPD/digest.out"
}

# W selects the watcher object inside OBJ: .babysit for a PR, the day object itself for pm day.
JQ_W='def W: if $kind == "babysit" then .babysit else . end;'
if [[ "$KIND" == babysit ]]; then QUIET_PATH="$OBJ_PATH.babysit.quiet"; else QUIET_PATH="$OBJ_PATH.quiet"; fi

# Forced-emit flag: the last resort when a contract cannot be disarmed in session state.
# While it exists every tick emits; a successful disarm or a fresh --record clears it.
force_flag() {
  local key="${REPO:-}"
  [[ -n "$key" ]] || key=$(git config --get remote.origin.url 2>/dev/null) || key=""
  key="$KIND-${key:-unknown}-${PR:-day}"
  printf '%s/.claude/monitor-quiet/force-emit-%s' "${HOME:-/tmp}" "$(printf '%s' "$key" | tr -c 'A-Za-z0-9._-' '_')"
}

# disarm_contract REASON — set an armed contract to quiet_ok=false. A lost compare-and-set
# (another writer touched the watcher object) retries against the fresh object; after three
# losses it writes quiet_ok=false blind, which can only ever cost quietness; if even that
# fails it sets the forced-emit flag. Exit 0 = nothing armed or disarmed; 1 = flag fallback.
disarm_contract() {
  local reason="$1" obj new now
  for _ in 1 2 3; do
    obj=$(state --get-json "$OBJ_PATH" 2>/dev/null) || break
    jq -e --arg kind "$KIND" "$JQ_W"' type == "object" and (W | type == "object") and W.quiet.quiet_ok == true' \
      >/dev/null 2>&1 <<<"$obj" || return 0
    now=$(date -u +%FT%TZ)
    new=$(jq -c --arg kind "$KIND" --arg r "$reason" --arg now "$now" "$JQ_W"'
      W.quiet.quiet_ok = false | W.quiet.disarmed_reason = $r | W.quiet.disarmed_at = $now' <<<"$obj") || break
    state --cas "$OBJ_PATH=$new" --expect "$obj" >/dev/null 2>&1 && return 0
  done
  state --set "$QUIET_PATH.quiet_ok=false" --set "$QUIET_PATH.disarmed_reason=$reason" >/dev/null 2>&1 && return 0
  if mkdir -p "$(dirname "$(force_flag)")" 2>/dev/null && : > "$(force_flag)" 2>/dev/null; then
    echo "monitor-quiet-tick.sh: contract could not be disarmed; forced-emit flag set" >&2
  else
    echo "monitor-quiet-tick.sh: contract could not be disarmed and the forced-emit flag could not be set" >&2
  fi
  return 1
}

if [[ "$MODE" == disarm ]]; then
  # A tick the loop prints without consulting the gate (the babysit review-deadline tick)
  # must not leave an armed contract behind, or the next unchanged tick could go quiet and
  # advance counters while the model is still handling that printed tick.
  disarm_contract "forced emit" || true
  exit 0
fi

if [[ "$MODE" == print ]]; then
  bounded_digest || { echo "monitor-quiet-tick.sh: input digest unavailable" >&2; exit 1; }
  exit 0
fi

if [[ "$MODE" == record ]]; then
  OBJ=$(state --get-json "$OBJ_PATH" 2>/dev/null) || { echo "monitor-quiet-tick.sh: watcher state unreadable; no contract stored" >&2; exit 1; }
  jq -e --arg kind "$KIND" "$JQ_W"' type == "object" and (W | type == "object")' >/dev/null 2>&1 <<<"$OBJ" ||
    { echo "monitor-quiet-tick.sh: no watcher at $OBJ_PATH; no contract stored" >&2; exit 1; }
  RC=0
  DIGEST="$INPUT_DIGEST"
  if [[ "$QUIET_OK" == true && -z "$DIGEST" ]]; then
    if [[ -z "$TICK_START_DIGEST" ]]; then
      # A digest read now would absorb any event that arrived after the tick classified,
      # and the next ticks would stay quiet over it. Without the tick-start digest, fail closed.
      QUIET_OK=false; RC=1
      echo "monitor-quiet-tick.sh: no --tick-start-digest supplied; storing quiet_ok=false" >&2
    elif [[ "$KIND" == babysit ]]; then
      DIGEST="$TICK_START_DIGEST"
    elif STATE_HEX=$(state_hex); then
      DIGEST="${TICK_START_DIGEST%%.*}.$STATE_HEX"
    else
      QUIET_OK=false; RC=1
      echo "monitor-quiet-tick.sh: repo state unreadable; storing quiet_ok=false" >&2
    fi
  fi
  NOW=$(date -u +%FT%TZ)
  NEW=$(jq -c --arg kind "$KIND" --arg d "$DIGEST" --argjson ok "$QUIET_OK" --argjson bc "$BLOCKER_COUNTING" \
    --argjson widen "$WIDEN_AT" --arg freeze "$FREEZE_AT" --arg now "$NOW" "$JQ_W"'
    (W.tick_count | if type == "number" and . >= 0 and floor == . then . else null end) as $tc
    | W.quiet = {input_digest: (if $d == "" then null else $d end),
                 quiet_ok: ($ok and $d != "" and $tc != null), tick_count: $tc,
                 widen_at: $widen, freeze_at: (if $freeze == "none" then null else ($freeze | tonumber) end),
                 blocker_counting: $bc, recorded_at: $now, quiet_ticks: 0}' <<<"$OBJ") ||
    { echo "monitor-quiet-tick.sh: could not build the contract" >&2; exit 1; }
  state --cas "$OBJ_PATH=$NEW" --expect "$OBJ" >/dev/null 2>&1 ||
    { echo "monitor-quiet-tick.sh: contract write lost or failed; the next tick will emit" >&2; exit 1; }
  # A model tick that recorded a fresh contract has handled whatever a failed disarm flagged.
  rm -f "$(force_flag)" 2>/dev/null || true
  exit "$RC"
fi

# ---- tick mode -----------------------------------------------------------------
if [[ -e "$(force_flag)" ]]; then
  # An earlier disarm failed: emit, and drop the flag only once the contract is disarmed.
  disarm_contract "forced-emit flag" && rm -f "$(force_flag)"
  emit "forced-emit flag"
fi
OBJ=$(state --get-json "$OBJ_PATH" 2>/dev/null) || emit "watcher state unreadable"
# Cheap precheck first: no GitHub read unless the contract could allow a quiet tick.
PRE=$(jq -r --arg kind "$KIND" --arg gen "$GENERATION" "$JQ_W"'
  def int: type == "number" and . >= 0 and floor == .;
  if type != "object" or (W | type) != "object" then "no-watcher"
  elif W.active != true then "inactive"
  elif W.stop_requested == true then "stop-requested"
  elif W.cadence_transition == true then "cadence-transition"
  elif W.monitor_generation != $gen then "generation-mismatch"
  elif $kind == "babysit" and W.dispatch_in_flight != null then "dispatch-in-flight"
  elif $kind == "pm-day" and (W.parked_until != null or W.paused_at != null) then "parked-or-paused"
  elif (W.quiet | type) != "object" or W.quiet.quiet_ok != true then "no-quiet-contract"
  elif (W.quiet.input_digest | type) != "string" or W.quiet.input_digest == "" then "no-recorded-digest"
  elif (W.tick_count | int | not) or W.quiet.tick_count != W.tick_count then "stale-contract"
  elif (.digest_streak | int | not) then "streak-unreadable"
  elif (W.cadence_base_minutes | int | not) or W.cadence_base_minutes < 1
       or (W.cadence_effective_minutes | int | not) then "cadence-unreadable"
  elif (W.quiet.widen_at | int | not) then "contract-unreadable"
  else
    (.digest_streak + 1) as $next
    | W.cadence_base_minutes as $base
    | ([15, 3 * $base, $base] | max) as $wide
    | (if $next >= W.quiet.widen_at then $wide else $base end) as $implied
    | if $implied != W.cadence_effective_minutes then "threshold-cadence"
      elif W.quiet.freeze_at != null and $next >= W.quiet.freeze_at then "threshold-freeze"
      elif W.quiet.blocker_counting == true and
           ((W.blocker_streak | int | not) or (W.max_blocker_ticks | int | not) or W.max_blocker_ticks < 1
            or (W.blocker_streak + 1) >= W.max_blocker_ticks) then "threshold-blocker-cap"
      else "ok" end
  end' <<<"$OBJ" 2>/dev/null) || emit "watcher state malformed"
# disarm REASON — emit from a quiet-eligible contract, first marking it quiet_ok=false so
# every later tick also emits until the model's own tick records a fresh contract. A
# Monitor tick that lands while the model is still handling this event therefore wakes
# it again, as before, instead of advancing counters under the running tick's feet. A
# lost write retries against the fresh object, then falls back to a blind quiet_ok=false
# and finally to the forced-emit flag (disarm_contract); this tick emits in every case.
disarm() {
  disarm_contract "$1" || true
  emit "$1"
}
case "$PRE" in
  ok) ;;
  threshold-*) disarm "$PRE" ;;
  *) emit "$PRE" ;;
esac

DIGEST="$INPUT_DIGEST"
if [[ -z "$DIGEST" ]]; then DIGEST=$(bounded_digest) || disarm "input digest unavailable"; fi
RECORDED=$(jq -r --arg kind "$KIND" "$JQ_W"' W.quiet.input_digest' <<<"$OBJ") || emit "recorded digest unreadable"
[[ "$DIGEST" == "$RECORDED" ]] || disarm "input digest changed"

NOW=$(date -u +%FT%TZ)
NEW=$(jq -c --arg kind "$KIND" --arg now "$NOW" "$JQ_W"'
  .digest_streak += 1
  | W.tick_count += 1
  | W.last_tick_at = $now
  | (if W.quiet.blocker_counting == true then W.blocker_streak += 1 else . end)
  | W.quiet.tick_count = W.tick_count
  | W.quiet.quiet_ticks = ((W.quiet.quiet_ticks // 0) + 1)
  | W.quiet.last_quiet_at = $now' <<<"$OBJ") || emit "could not build the quiet update"
state --cas "$OBJ_PATH=$NEW" --expect "$OBJ" >/dev/null 2>&1 || emit "counter write lost or failed"
exit 10
