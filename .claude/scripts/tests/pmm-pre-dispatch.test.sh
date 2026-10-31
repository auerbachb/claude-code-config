#!/usr/bin/env bash
# Offline replay tests for PMM's pre-model Monitor gate (issue #1878).
# catalog: tests — Verify PMM pre-dispatch change detection, silent unchanged polling, retry/ack, and Monitor-loop zero-dispatch behavior
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$ROOT/.claude/scripts/pmm-pre-dispatch.sh"
STATE="$ROOT/.claude/scripts/session-state.sh"
TMP="$(mktemp -d /tmp/pmm-pre-dispatch-test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
TEST_HOME="$TMP/home"
mkdir -p "$TEST_HOME/.claude"
printf '{}\n' > "$TEST_HOME/.claude/session-state.json"
PASS=0; FAIL=0

pass() { printf 'PASS: %s\n' "$1"; PASS=$((PASS+1)); }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAIL=$((FAIL+1)); }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }

BASE_GATE='{"head_sha":"abc123","met":false,"reviewer":"cr","path":"cr","missing":[],"ci_status":{"total":2,"passing":2,"failing":0,"in_progress":0,"blocking":[],"incomplete":[]},"merge_state":"CLEAN","mergeable":"MERGEABLE","review_decision":"REVIEW_REQUIRED","human_changes_requested":[],"unresolved_thread_count":0,"authorship":"mine"}'
snapshot() {
  local out="$1" rows="$2" agents="${3:-}" locks="${4:-}" holds="${5:-}"
  [[ -n "$agents" ]] || agents='{}'
  [[ -n "$locks" ]] || locks='{}'
  [[ -n "$holds" ]] || holds='{}'
  jq -cn --argjson gate "$BASE_GATE" --argjson rows "$rows" --argjson agents "$agents" --argjson locks "$locks" --argjson holds "$holds" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{repo:"org/repo",author:"alice",collected_at:$now,prs:($rows | map(if .gate then . else .gate=$gate end)),evidence:[{pr:7,path:"/tmp/pr-state-7.json"}],orchestration:{active_agents:$agents,pmm_in_flight:$locks,merge_holds:$holds}}' > "$out"
}
row7='[{"number":7,"url":"https://github.com/org/repo/pull/7","findings":[]}]'
snapshot "$TMP/base.json" "$row7"
run_gate() {
  local file="$1"; shift
  HOME="$TEST_HOME" "$SCRIPT" --repo org/repo --author alice --generation gen-a \
    --base-cadence-min 5 --idle-pause-after 99 \
    --skill-args '--author alice --repo org/repo --cadence 5m --max-parallel 2 --auto-wake' --fixture "$file" "$@"
}
event_from() {
  local output="$1" home="${2:-$TEST_HOME}" id
  id="$(sed -n 's#^/pr-monitor-and-manage .*--dispatch-event \([[:xdigit:]]*\).*#\1#p' "$output")"
  [[ -n "$id" ]] || return 0
  jq -c --arg id "$id" '.pmm_pre_dispatch.pending_event | select(.event_id==$id)' "$home/.claude/session-state.json"
}
ack_event() { HOME="$TEST_HOME" "$SCRIPT" --ack "$1"; }
record_pmm_baseline() {
  local file="$1" tuple digest
  tuple="$(jq -cS '[.prs[] | [.number,.gate.head_sha,.gate.merge_state,.gate.review_decision,.gate.ci_status.failing,.gate.unresolved_thread_count]] | sort_by(.[0])' "$file")"
  digest="$(printf '%s' "$tuple" | shasum -a 256 | awk '{print $1}')"
  HOME="$TEST_HOME" "$STATE" --set ".pmm_digest=\"$digest\"" --set '.pmm_digest_streak=0' \
    --set '.pmm_idle_streak=0' --set '.pmm_cadence="5m"'
}

# First observed fleet is actionable and creates one queued event.
run_gate "$TMP/base.json" > "$TMP/initial.out"
INITIAL="$(event_from "$TMP/initial.out")"
INITIAL_ID="$(jq -r '.event_id' <<<"$INITIAL")"
check "initial snapshot queues a fleet event" '[[ -n "$INITIAL_ID" && "$(jq -r ".reasons|index(\"initial\") != null" <<<"$INITIAL")" == true ]]'
check "Monitor output contains exactly one skill dispatch event" '[[ "$(wc -l < "$TMP/initial.out" | tr -d " ")" == 1 ]]'
check "forwarded arguments are validated and shell-quoted as discrete tokens" '[[ "$(tail -n 1 "$TMP/initial.out")" == "/pr-monitor-and-manage --tick --monitor-generation gen-a --dispatch-event $INITIAL_ID --author alice --repo org/repo --cadence 5m --max-parallel 2 --auto-wake" ]]'
set +e
HOME="$TEST_HOME" "$SCRIPT" --repo org/repo --author alice --generation gen-a --fixture "$TMP/base.json" \
  --skill-args '--repo org/repo;touch /tmp/pmm-should-not-exist' > "$TMP/unsafe-args.out" 2>/dev/null
unsafe_rc=$?
set -e
check "shell metacharacters in forwarded args are rejected without evaluation" '[[ "$unsafe_rc" == 2 && ! -e /tmp/pmm-should-not-exist ]]'
printf '{"repo":"org/repo","prs":[]}' > "$TMP/malformed.json"
run_gate "$TMP/malformed.json" > "$TMP/pending-malformed.out"
check "unknown data cannot overwrite a previously pending actionable event" '[[ "$(event_from "$TMP/pending-malformed.out" | jq -r .event_id)" == "$INITIAL_ID" && "$(jq -r .pmm_pre_dispatch.pending_event.event_id "$TEST_HOME/.claude/session-state.json")" == "$INITIAL_ID" ]]'

# Undelivered event is re-emitted byte-for-byte with the same id until ack.
run_gate "$TMP/base.json" > "$TMP/replay.out"
REPLAY="$(event_from "$TMP/replay.out")"
check "restart/retry re-emits the same pending event ID" '[[ "$(jq -r .event_id <<<"$REPLAY")" == "$INITIAL_ID" ]]'
ack_event wrong-id
check "wrong acknowledgement cannot consume pending event" '[[ "$(jq -r ".pmm_pre_dispatch.pending_event.event_id" "$TEST_HOME/.claude/session-state.json")" == "$INITIAL_ID" ]]'
ack_event "$INITIAL_ID"
record_pmm_baseline "$TMP/base.json"
run_gate "$TMP/base.json" > "$TMP/quiet.out"
check "repeated unchanged snapshot produces zero bytes/model events" '[[ ! -s "$TMP/quiet.out" ]]'

# New finding changes the comment projection while the coarse merge-gate row is identical.
jq -e '.prs[0].gate == input.prs[0].gate' "$TMP/base.json" "$TMP/base.json" >/dev/null
OBSERVED_AT="$(date -u -d '60 seconds ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-60S +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
finding_row="$(jq -cn --argjson row "$(jq -c '.prs[0]' "$TMP/base.json")" \
  --arg observed "$OBSERVED_AT" \
  '[$row + {findings:[{endpoint:"inline",id:901,url:"https://github.com/org/repo/pull/7#discussion_r901",observed_at:$observed}]}]')"
snapshot "$TMP/finding.json" "$finding_row"
run_gate "$TMP/finding.json" > "$TMP/finding.out"
FINDING="$(event_from "$TMP/finding.out")"
check "new actionable finding wakes despite unchanged merge-gate projection" '[[ "$(jq -r ".reasons|index(\"actionable_review_finding\") != null" <<<"$FINDING")" == true && "$(jq -r ".delta.changed|length" <<<"$FINDING")" == 0 ]]'
check "finding event contains compact id, evidence path, and measured latency" '[[ "$(jq -r ".delta.new_findings[0].item.id" <<<"$FINDING")" == 901 && "$(jq -r ".evidence[0].path" <<<"$FINDING")" == /tmp/pr-state-7.json && "$(jq -r ".detection_latency_seconds|type" <<<"$FINDING")" == number ]]'
ack_event "$(jq -r .event_id <<<"$FINDING")"
record_pmm_baseline "$TMP/finding.json"
run_gate "$TMP/finding.json" > "$TMP/finding-quiet.out"
check "acknowledged finding does not repeat on unchanged ticks" '[[ ! -s "$TMP/finding-quiet.out" ]]'

# Gate transitions and fleet changes are separately represented in the delta.
ci_rows="$(jq -c '.prs[0].gate.ci_status.failing=1 | .prs[0].gate.ci_status.passing=1 | .prs' "$TMP/finding.json")"
snapshot "$TMP/ci.json" "$ci_rows"
run_gate "$TMP/ci.json" > "$TMP/ci.out"
CI_EVENT="$(event_from "$TMP/ci.out")"
check "CI failure transition wakes with before/after evidence" '[[ "$(jq -r ".reasons|index(\"head_gate_ci_or_blocker\") != null" <<<"$CI_EVENT")" == true && "$(jq -r ".delta.changed[0].after.ci_status.failing" <<<"$CI_EVENT")" == 1 ]]'
ack_event "$(jq -r .event_id <<<"$CI_EVENT")"
head_rows="$(jq -c '.prs[0].gate.head_sha="def456" | .prs' "$TMP/ci.json")"
snapshot "$TMP/head.json" "$head_rows"
run_gate "$TMP/head.json" > "$TMP/head.out"
check "changed HEAD wakes" '[[ "$(event_from "$TMP/head.out" | jq -r ".delta.changed[0].after.head_sha")" == def456 ]]'
ack_event "$(event_from "$TMP/head.out" | jq -r .event_id)"
two_rows="$(jq -cn --argjson base "$head_rows" '$base + [{number:8,url:"https://github.com/org/repo/pull/8",findings:[]}]')"
snapshot "$TMP/fleet.json" "$two_rows"
run_gate "$TMP/fleet.json" > "$TMP/fleet.out"
check "fleet membership change wakes" '[[ "$(event_from "$TMP/fleet.out" | jq -r ".reasons|index(\"fleet\") != null")" == true ]]'
ack_event "$(event_from "$TMP/fleet.out" | jq -r .event_id)"

snapshot "$TMP/hold.json" "$row7" '{}' '{}' '{"7":{"head_sha":"abc123","action":"hold","stall_ticks":2}}'
run_gate "$TMP/hold.json" > "$TMP/hold.out"
check "merge-sequencing hold changes wake as relevant blocker state" '[[ "$(event_from "$TMP/hold.out" | jq -r ".reasons|index(\"merge_hold_state\") != null")" == true && "$(event_from "$TMP/hold.out" | jq -r ".delta.hold_changes|length")" == 2 ]]'
ack_event "$(event_from "$TMP/hold.out" | jq -r .event_id)"

snapshot "$TMP/agent.json" "$row7" '{"pmm-fix-7":{"pr":7,"phase":"A","status":"running","last_seen_at":"2026-10-30T00:00:00Z"}}'
run_gate "$TMP/agent.json" > "$TMP/agent.out"
check "active-agent lifecycle changes wake independently of PR gates" '[[ "$(event_from "$TMP/agent.out" | jq -r ".reasons|index(\"agent_state\") != null")" == true && "$(event_from "$TMP/agent.out" | jq -r ".delta.agent_changes|length")" == 2 ]]'
ack_event "$(event_from "$TMP/agent.out" | jq -r .event_id)"

snapshot "$TMP/lock.json" "$row7" '{}' '{"7":{"status":"active","dispatched_at":"2026-10-30T00:00:00Z","head_sha":"abc123"}}'
run_gate "$TMP/lock.json" > "$TMP/lock.out"
check "active PMM lock changes wake independently of PR gates" '[[ "$(event_from "$TMP/lock.out" | jq -r ".reasons|index(\"pmm_lock_state\") != null")" == true && "$(event_from "$TMP/lock.out" | jq -r ".delta.lock_changes|length")" == 2 ]]'
ack_event "$(event_from "$TMP/lock.out" | jq -r .event_id)"

# PMM agent/lock transitions and recovery deadlines are persisted/deduped.
old_agent='{"pmm-fix-7":{"id":"pmm-fix-7","pr":7,"phase":"A","status":"running","launched":"2020-01-01T00:00:00Z","last_seen_at":"2020-01-01T00:00:00Z"}}'
snapshot "$TMP/deadline.json" "$two_rows" "$old_agent"
run_gate "$TMP/deadline.json" > "$TMP/deadline.out"
DEADLINE="$(event_from "$TMP/deadline.out")"
check "stale PMM-owned Phase A deadline wakes" '[[ "$(jq -r ".reasons|index(\"deadline\") != null" <<<"$DEADLINE")" == true ]]'
ack_event "$(jq -r .event_id <<<"$DEADLINE")"
record_pmm_baseline "$TMP/deadline.json"
run_gate "$TMP/deadline.json" > "$TMP/deadline-quiet.out"
check "reported deadline is not re-emitted forever" '[[ ! -s "$TMP/deadline-quiet.out" ]]'
bad_agent='{"foreign":{"id":"foreign","pr":7,"phase":"A","status":"running"}}'
snapshot "$TMP/deadline-unknown.json" "$two_rows" "$bad_agent"
run_gate "$TMP/deadline-unknown.json" > "$TMP/deadline-unknown.out"
check "unknown recovery deadline wakes diagnostically" '[[ "$(event_from "$TMP/deadline-unknown.out" | jq -r ".reasons|index(\"deadline_state_unknown\") != null")" == true ]]'
ack_event "$(event_from "$TMP/deadline-unknown.out" | jq -r .event_id)"
run_gate "$TMP/deadline-unknown.json" > "$TMP/deadline-unknown-2.out"
run_gate "$TMP/deadline-unknown.json" > "$TMP/deadline-unknown-3.out"
check "identical unknown deadline retries locally for two observations" '[[ ! -s "$TMP/deadline-unknown-2.out" && ! -s "$TMP/deadline-unknown-3.out" && "$(jq -r .pmm_pre_dispatch.deadline_unknown_checks "$TEST_HOME/.claude/session-state.json")" == 3 ]]'
run_gate "$TMP/deadline-unknown.json" > "$TMP/deadline-unknown-4.out"
check "unresolved unknown deadline re-notifies on the three-observation interval" '[[ "$(event_from "$TMP/deadline-unknown-4.out" | jq -r ".reasons|index(\"deadline_state_unknown\") != null")" == true && "$(jq -r .pmm_pre_dispatch.deadline_unknown_checks "$TEST_HOME/.claude/session-state.json")" == 4 ]]'
ack_event "$(event_from "$TMP/deadline-unknown-4.out" | jq -r .event_id)"

# Stale state and collection errors cannot become an unchanged result.
HOME="$TEST_HOME" "$STATE" --set '.pmm_pre_dispatch.snapshot.recorded_at="2020-01-01T00:00:00Z"'
run_gate "$TMP/deadline-unknown.json" > "$TMP/stale.out"
check "stale cached snapshot creates a wake" '[[ "$(event_from "$TMP/stale.out" | jq -r ".reasons|index(\"snapshot_stale\") != null")" == true ]]'
ack_event "$(event_from "$TMP/stale.out" | jq -r .event_id)"
set +e
run_gate "$TMP/missing.json" > "$TMP/error.out"
error_rc=$?
set -e
check "collector failure wakes with a durable diagnostic event" '[[ "$error_rc" == 5 && "$(event_from "$TMP/error.out" | jq -r .diagnostic)" == true ]]'

check "direct owner turns bypass the scheduled gate" 'grep -Fq "Direct owner messages remain normal interactive turns" "$ROOT/.claude/skills/pr-monitor-and-manage/SKILL.md"'

# Existing PMM backoff and idle-pause counters keep advancing without model calls.
SCHED_HOME="$TMP/scheduler-home"
mkdir -p "$SCHED_HOME/.claude"
printf '{}\n' > "$SCHED_HOME/.claude/session-state.json"
HOME="$SCHED_HOME" "$SCRIPT" --repo org/repo --author alice --generation gen-s --base-cadence-min 5 \
  --idle-pause-after 99 --fixture "$TMP/base.json" > "$TMP/scheduler-initial.out"
SCHED_EVENT="$(event_from "$TMP/scheduler-initial.out" "$SCHED_HOME")"
HOME="$SCHED_HOME" "$SCRIPT" --ack "$(jq -r .event_id <<<"$SCHED_EVENT")"
SCHED_TUPLE="$(jq -cS '[.prs[] | [.number,.gate.head_sha,.gate.merge_state,.gate.review_decision,.gate.ci_status.failing,.gate.unresolved_thread_count]] | sort_by(.[0])' "$TMP/base.json")"
SCHED_DIGEST="$(printf '%s' "$SCHED_TUPLE" | shasum -a 256 | awk '{print $1}')"
HOME="$SCHED_HOME" "$STATE" --set ".pmm_digest=\"$SCHED_DIGEST\"" --set '.pmm_digest_streak=0' --set '.pmm_idle_streak=0' --set '.pmm_cadence="5m"'
for tick in 1 2 3 4 5 6 7 8; do
  HOME="$SCHED_HOME" "$SCRIPT" --repo org/repo --author alice --generation gen-s --base-cadence-min 5 \
    --idle-pause-after 99 --fixture "$TMP/base.json" > "$TMP/scheduler-$tick.out"
done
check "stable backoff ticks stay silent and widen existing PMM cadence" '[[ ! -s "$TMP/scheduler-3.out" && "$(jq -r .pmm_cadence "$SCHED_HOME/.claude/session-state.json")" == 15m && "$(jq -r .pmm_digest_streak "$SCHED_HOME/.claude/session-state.json")" == 8 ]]'
HOME="$SCHED_HOME" "$SCRIPT" --repo org/repo --author alice --generation gen-s --base-cadence-min 5 \
  --idle-pause-after 99 --fixture "$TMP/base.json" > "$TMP/scheduler-9.out"
check "ninth stable tick emits one lifecycle event to pause" '[[ "$(event_from "$TMP/scheduler-9.out" "$SCHED_HOME" | jq -r ".reasons|index(\"stable_freeze_due\") != null")" == true ]]'

IDLE_HOME="$TMP/idle-home"
mkdir -p "$IDLE_HOME/.claude"
printf '{}\n' > "$IDLE_HOME/.claude/session-state.json"
HOME="$IDLE_HOME" "$SCRIPT" --repo org/repo --author alice --generation gen-i --base-cadence-min 5 \
  --idle-pause-after 2 --fixture "$TMP/base.json" > "$TMP/idle-initial.out"
IDLE_EVENT="$(event_from "$TMP/idle-initial.out" "$IDLE_HOME")"
HOME="$IDLE_HOME" "$SCRIPT" --ack "$(jq -r .event_id <<<"$IDLE_EVENT")"
HOME="$IDLE_HOME" "$STATE" --set ".pmm_digest=\"$SCHED_DIGEST\"" --set '.pmm_digest_streak=0' --set '.pmm_idle_streak=0'
HOME="$IDLE_HOME" "$SCRIPT" --repo org/repo --author alice --generation gen-i --base-cadence-min 5 \
  --idle-pause-after 2 --fixture "$TMP/base.json" > "$TMP/idle-1.out"
HOME="$IDLE_HOME" "$SCRIPT" --repo org/repo --author alice --generation gen-i --base-cadence-min 5 \
  --idle-pause-after 2 --fixture "$TMP/base.json" > "$TMP/idle-2.out"
check "idle-pause threshold wakes once after quiet ticks" '[[ ! -s "$TMP/idle-1.out" && "$(event_from "$TMP/idle-2.out" "$IDLE_HOME" | jq -r ".reasons|index(\"idle_pause_due\") != null")" == true ]]'

# Collector-path replay with the exact persisted Monitor shell loop. The fake
# event sink counts skill-dispatch lines; unchanged collector output remains
# empty, so the simulated model-dispatch counter stays at zero.
LIVE="$TMP/live-scripts"
BIN="$TMP/live-bin"
LIVE_HOME="$TMP/live-home"
mkdir -p "$LIVE/lib" "$BIN" "$LIVE_HOME/.claude"
cp "$SCRIPT" "$LIVE/pmm-pre-dispatch.sh"
cp "$ROOT/.claude/scripts/lib/bounded-run.sh" "$LIVE/lib/bounded-run.sh"
cp "$ROOT/.claude/scripts/lib/pr-state-classify.jq" "$LIVE/lib/pr-state-classify.jq"
cp "$STATE" "$LIVE/session-state.sh"
cp "$ROOT/.claude/scripts/state-lock.sh" "$LIVE/state-lock.sh"
cp "$ROOT/.claude/scripts/lib/repo-normalizer.sh" "$LIVE/lib/repo-normalizer.sh"
mkdir -p "$LIVE/../reference"
cp "$ROOT/.claude/reference/session-state-schema.json" "$LIVE/../reference/session-state-schema.json"
cat > "$LIVE/merge-gate.sh" <<'SH'
#!/usr/bin/env bash
if [[ "${STUB_GATE_DELAY:-0}" =~ ^[1-9][0-9]*$ ]]; then /bin/sleep "$STUB_GATE_DELAY"; fi
printf '%s\n' "$STUB_GATE_JSON"
SH
cat > "$LIVE/pr-state.sh" <<'SH'
#!/usr/bin/env bash
if [[ "${3:-}" == --stdout ]]; then cat "$STUB_BUNDLE_PATH"; else printf '%s\n' "$STUB_BUNDLE_PATH"; fi
SH
cat > "$BIN/gh" <<'SH'
#!/usr/bin/env bash
if [[ "$1 $2" == "pr list" ]]; then
  [[ -z "${GH_ARGS_PATH:-}" ]] || printf '%s\n' "$@" > "$GH_ARGS_PATH"
  # Match gh's real --limit behavior, so overflow fixtures cannot pass merely
  # because this stub returned more rows than the production request permitted.
  limit=30; previous=""
  for arg in "$@"; do
    [[ "$previous" != --limit ]] || limit="$arg"
    previous="$arg"
  done
  printf '%s\n' "$STUB_PULLS_JSON" | jq --argjson limit "$limit" '.[0:$limit]'
else
  exit 2
fi
SH
chmod +x "$LIVE"/*.sh "$BIN/gh"
export GH_ARGS_PATH="$TMP/gh-args"
printf '%s\n' '{"pmm_active":true,"pmm_monitor_generation":"gen-live"}' > "$LIVE_HOME/.claude/session-state.json"
jq -cn --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{run_started_at:$now,pr:{owner:"org",repo:"repo",number:7,head_sha:"abc123"},threads:{unresolved_count:0},comments:{reviews:[],inline:[],conversation:[]},check_runs:{all:[],passing_runs:[],failing_runs:[],in_progress_runs:[]},commit_statuses:[],new_since_baseline:null}' > "$TMP/bundle.json"
STUB_PULLS_JSON='[{"number":7,"url":"https://github.com/org/repo/pull/7","headRefOid":"abc123","title":"Test PR"}]'
STUB_GATE_JSON="$BASE_GATE"
HOME="$LIVE_HOME" PATH="$BIN:$PATH" STUB_PULLS_JSON="$STUB_PULLS_JSON" STUB_GATE_JSON="$STUB_GATE_JSON" STUB_BUNDLE_PATH="$TMP/bundle.json" \
  "$LIVE/pmm-pre-dispatch.sh" --repo org/repo --author alice --generation gen-live --base-cadence-min 5 \
  --idle-pause-after 99 > "$TMP/live-initial.out"
LIVE_EVENT="$(event_from "$TMP/live-initial.out" "$LIVE_HOME")"
check "production discovery requests a 501 sentinel for the supported 500-PR fleet" '[[ "$(grep -Fxc -- "--limit" "$GH_ARGS_PATH")" == 1 && "$(tail -n 1 "$GH_ARGS_PATH")" == 501 ]]'
LIVE_TUPLE="$(jq -cnS '[[7,"abc123","CLEAN","REVIEW_REQUIRED",0,0]]')"
LIVE_DIGEST="$(printf '%s' "$LIVE_TUPLE" | shasum -a 256 | awk '{print $1}')"
HOME="$LIVE_HOME" "$LIVE/session-state.sh" --set ".pmm_digest=\"$LIVE_DIGEST\"" --set '.pmm_digest_streak=0' --set '.pmm_idle_streak=0' --set '.pmm_cadence="5m"'
HOME="$LIVE_HOME" "$LIVE/pmm-pre-dispatch.sh" --ack "$(jq -r .event_id <<<"$LIVE_EVENT")"
cat > "$BIN/sleep" <<'SH'
#!/usr/bin/env bash
if [[ "$1" =~ ^[0-9]+$ && "$1" -ge 60 ]]; then
count=0
[[ -f "$SLEEP_COUNT" ]] && count="$(cat "$SLEEP_COUNT")"
count=$((count + 1))
printf '%s' "$count" > "$SLEEP_COUNT"
if [[ "$count" -ge 2 ]]; then exit 1; fi
exit 0
fi
/bin/sleep "$@"
SH
chmod +x "$BIN/sleep"
MONITOR_COMMAND=$(HOME="$LIVE_HOME" "$LIVE/pmm-pre-dispatch.sh" --monitor-command \
  --repo org/repo --author alice --generation gen-live --base-cadence-min 5 \
  --idle-pause-after 99 --skill-args '--author alice --repo org/repo --cadence 5m')
set +e
HOME="$LIVE_HOME" PATH="$BIN:$PATH" SLEEP_COUNT="$TMP/sleep-count" \
  STUB_PULLS_JSON="$STUB_PULLS_JSON" STUB_GATE_JSON="$STUB_GATE_JSON" STUB_BUNDLE_PATH="$TMP/bundle.json" \
  bash -c "$MONITOR_COMMAND" > "$TMP/live-quiet.out" 2>"$TMP/live-quiet.err"
monitor_rc=$?
set -e
check "exact generated Monitor loop collects before zero-output pre-model dispatch" '[[ "$monitor_rc" == 0 && ! -s "$TMP/live-quiet.out" && "$(cat "$TMP/sleep-count")" == 2 ]]'
MISSING_BOUND_COMMAND="${MONITOR_COMMAND//$LIVE\/lib\/bounded-run.sh/$TMP\/missing-bounded-run.sh}"
set +e
HOME="$LIVE_HOME" PATH="$BIN:$PATH" SLEEP_COUNT="$TMP/missing-bound-sleep-count" \
  bash -c "$MISSING_BOUND_COMMAND" > "$TMP/missing-bound.out" 2> "$TMP/missing-bound.err"
missing_bound_rc=$?
set -e
check "missing bounded-run support emits diagnosis and stops before polling" '[[ "$missing_bound_rc" == 1 && "$(wc -l < "$TMP/missing-bound.out" | tr -d " ")" == 1 && "$(grep -F -- "--pre-dispatch-diagnostic" "$TMP/missing-bound.out")" ]]'
set +e
HOME="$LIVE_HOME" PATH="$BIN:$PATH" SLEEP_COUNT="$TMP/timeout-sleep-count" PMM_PRE_DISPATCH_TIMEOUT_SECS=1 \
  STUB_PULLS_JSON="$STUB_PULLS_JSON" STUB_GATE_JSON="$STUB_GATE_JSON" STUB_BUNDLE_PATH="$TMP/bundle.json" STUB_GATE_DELAY=2 \
  bash -c "$MONITOR_COMMAND" > "$TMP/timeout.out" 2> "$TMP/timeout.err"
timeout_monitor_rc=$?
set -e
check "bounded collector timeout wakes diagnosis instead of returning a quiet tick" '[[ "$timeout_monitor_rc" == 0 && "$(wc -l < "$TMP/timeout.out" | tr -d " ")" == 1 && "$(grep -F -- "--pre-dispatch-diagnostic" "$TMP/timeout.out")" && "$(grep -F "inside its bound" "$TMP/timeout.err")" ]]'
# Historical pre-pilot Monitor template, with only its cadence/args placeholders
# concretized. Execute it under the same fake sleep and count actual stdout events.
BASELINE_COMMAND='while sleep 300; do printf "%s\n" "/pr-monitor-and-manage --tick --monitor-generation gen-live --author alice --repo org/repo"; done'
HOME="$LIVE_HOME" PATH="$BIN:$PATH" SLEEP_COUNT="$TMP/baseline-sleep-count" \
  bash -c "$BASELINE_COMMAND" > "$TMP/baseline-events.out"
check "before/after identical quiet poll: one old model event versus zero gated events" '[[ "$(grep -c "^/pr-monitor-and-manage " "$TMP/baseline-events.out")" == 1 && ! -s "$TMP/live-quiet.out" ]]'
jq --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.comments.inline=[{id:45,body:"Fix this new regression in the changed function.",user:{login:"coderabbitai[bot]"},created_at:$now,updated_at:$now,html_url:"https://github.com/org/repo/pull/7#discussion_r45"}]' "$TMP/bundle.json" > "$TMP/changed-bundle.json"
HOME="$LIVE_HOME" PATH="$BIN:$PATH" SLEEP_COUNT="$TMP/changed-sleep-count" \
  STUB_PULLS_JSON="$STUB_PULLS_JSON" STUB_GATE_JSON="$STUB_GATE_JSON" STUB_BUNDLE_PATH="$TMP/changed-bundle.json" \
  bash -c "$MONITOR_COMMAND" > "$TMP/live-changed.out" 2>"$TMP/live-changed.err"
check "exact generated Monitor loop emits one compact event for a new finding" '[[ "$(wc -l < "$TMP/live-changed.out" | tr -d " ")" == 1 && "$(event_from "$TMP/live-changed.out" "$LIVE_HOME" | jq -r .trigger)" == pmm-classify-review-findings ]]'
HOME="$LIVE_HOME" "$LIVE/pmm-pre-dispatch.sh" --ack "$(event_from "$TMP/live-changed.out" "$LIVE_HOME" | jq -r .event_id)"
printf '{"pr":{"number":7,"head_sha":"abc123"},"comments":{}}\n' > "$TMP/malformed-bundle.json"
set +e
HOME="$LIVE_HOME" PATH="$BIN:$PATH" STUB_PULLS_JSON="$STUB_PULLS_JSON" STUB_GATE_JSON="$STUB_GATE_JSON" STUB_BUNDLE_PATH="$TMP/malformed-bundle.json" \
  "$LIVE/pmm-pre-dispatch.sh" --repo org/repo --author alice --generation gen-live --base-cadence-min 5 --idle-pause-after 99 > "$TMP/malformed-bundle.out"
bundle_rc=$?
set -e
check "missing PR-state comment/check data wakes diagnostically rather than as unchanged" '[[ "$bundle_rc" == 5 && "$(event_from "$TMP/malformed-bundle.out" "$LIVE_HOME" | jq -r .diagnostic)" == true && "$(event_from "$TMP/malformed-bundle.out" "$LIVE_HOME" | jq -r .reason)" == "pr-state bundle malformed for PR #7" ]]'
check "completed-event receipts distinguish actions from lifecycle completion" 'grep -Fq "actions_completed_event_id" "$ROOT/.claude/skills/pr-monitor-and-manage/SKILL.md" && grep -Fq "lifecycle_completed_event_id" "$ROOT/.claude/skills/pr-monitor-and-manage/SKILL.md" && grep -Fq "last_acknowledged_event_id" "$ROOT/.claude/skills/pr-monitor-and-manage/SKILL.md" && grep -Fq "fresh gate is unreadable" "$ROOT/.claude/skills/pr-monitor-and-manage/SKILL.md" && grep -Fq "PMM_SKIP_ACTIONS=true" "$ROOT/.claude/skills/pr-monitor-and-manage/SKILL.md"'

python3 - "$ROOT" "$TMP" "$LIVE" "$BIN" "$BASE_GATE" <<'PYTEST'
import datetime, hashlib, json, os, pathlib, subprocess, sys, re, shlex
root,tmp,live,binpath,gate=sys.argv[1:];root=pathlib.Path(root);tmp=pathlib.Path(tmp);live=pathlib.Path(live)
real_gate=json.loads(gate)
now=lambda: datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
def home(name):
    h=tmp/name;(h/'.claude').mkdir(parents=True);(h/'.claude/session-state.json').write_text(json.dumps({'pmm_active':True,'pmm_monitor_generation':'gen-live'}));return h
h=home('deep-home');state=h/'.claude/session-state.json'
bundle=tmp/'deep-bundle.json'
def write_bundle(comments=None,**extra):
    d={'pr':{'number':7,'owner':'org','repo':'repo','head_sha':'abc123'},'run_started_at':now(),'comments':{'reviews':[],'inline':comments or [],'conversation':[]},'check_runs':{'all':[],'passing_runs':[],'failing_runs':[],'in_progress_runs':[]},'commit_statuses':[]};d.update(extra);bundle.write_text(json.dumps(d));return d
write_bundle()
env=dict(os.environ,HOME=str(h),PATH=binpath+':'+os.environ['PATH'],STUB_PULLS_JSON=json.dumps([{'number':7,'url':'https://github.com/org/repo/pull/7','headRefOid':'abc123'}]),STUB_GATE_JSON=gate,STUB_BUNDLE_PATH=str(bundle))
argv=[str(live/'pmm-pre-dispatch.sh'),'--repo','org/repo','--author','alice','--generation','gen-live','--idle-pause-after','99']
def run(args=None,e=None,bash=None):
    cmd=args or argv
    if bash:cmd=[bash]+cmd
    return subprocess.run(cmd,env=e or env,text=True,capture_output=True)
def read():return json.loads(state.read_text())
def put(d):state.write_text(json.dumps(d))
def packet(r):
    assert len(r.stdout.splitlines())==1 and r.stdout.startswith('/pr-monitor-and-manage '),(r.returncode,r.stdout,r.stderr)
    return read()['pmm_pre_dispatch']['pending_event']
def ack(p):
    r=run([str(live/'pmm-pre-dispatch.sh'),'--ack',p['event_id']]);assert r.returncode==0,r.stderr
    d=read();d['pmm_digest']=subprocess.check_output(['jq','-cnS','[[7,"abc123","CLEAN","REVIEW_REQUIRED",0,0]]']).decode().rstrip('\n');import hashlib
    d['pmm_digest']=hashlib.sha256(d['pmm_digest'].encode()).hexdigest();d['pmm_digest_streak']=0;d['pmm_idle_streak']=0;put(d)
p=packet(run());ack(p)
# Real collector new/edited body and endpoint identity, no coarse gate movement.
comment={'id':91,'body':'Fix the null dereference in this changed function.','user':{'login':'coderabbitai[bot]'},'created_at':now(),'updated_at':now(),'html_url':'https://github.com/org/repo/pull/7#discussion_r91'}
write_bundle([comment]);r=run();p=packet(r);assert p['delta']['new_findings'][0]['item']['endpoint']=='inline' and not p['delta']['changed'];ack(p)
assert not run().stdout
comment['body']='Fix the second null dereference as well.';write_bundle([comment]);p=packet(run());assert len(p['delta']['new_findings'])==1;ack(p)
d=write_bundle([]);d['comments']['conversation']=[comment];bundle.write_text(json.dumps(d));p=packet(run());assert p['delta']['new_findings'][0]['item']['endpoint']=='conversation';ack(p)
assert read()['pmm_pre_dispatch']['snapshot']['data']['evidence'][0]['items'][0]['body_excerpt']==comment['body']
assert 'body' not in read()['pmm_pre_dispatch']['snapshot']['data']['evidence'][0]['items'][0]
print('PASS: real collector detects new and edited findings with stable gate and endpoint identity')
deleted=dict(comment,user=None,id=92);write_bundle([deleted]);p=packet(run())
assert p['delta']['new_findings'][0]['item']['id']==92 and not p.get('diagnostic')
item=p['evidence'][0]['items'][0];assert item['actor'] is None and item['body_excerpt']==deleted['body'] and item['id']==92 and item['created_at']==deleted['created_at']
assert bundle.exists(),'collector deleted a shared source fixture'
# Restart/outbox replay needs no temp bundle; acknowledgement preserves latest
# bounded snapshot evidence and clears only its pending delivery.
bundle.unlink();replayed=packet(run());assert replayed==p;ack(p);write_bundle()
print('PASS: deleted actor findings preserve identity/body/time as unknown and survive replay without source files')
large_comments=[dict(comment,id=110+i,body='x'*1024+' P1: fix the late regression '+str(i)) for i in range(4)]
write_bundle(large_comments);p=packet(run());ev=p['evidence'][0]
assert len(p['delta']['new_findings'])==3 and len(ev['items'])==3 and ev['item_count']==4 and ev['items_truncated'] is True
assert all(len(x['body_excerpt'])==256 and x['body_truncated'] for x in ev['items']);ack(p)
large_comments[0]['body']+=' changed beyond sampled IDs/excerpts';write_bundle(large_comments);p=packet(run());assert len(p['delta']['new_findings'])==1 and p['delta']['new_findings'][0]['item']['endpoint']=='aggregate' and p['delta']['new_findings'][0]['requires_source_recovery'];ack(p)
print('PASS: compact evidence caps3x256 while full classification/body hashes retain every finding and detect edits beyond excerpts')

missing_time=dict(comment);missing_time.pop('created_at');write_bundle([missing_time]);r=run();p=packet(r);assert r.returncode==5 and p['diagnostic'],(r.stdout,r.stderr);ack(p)
print('PASS: missing actionable-comment timestamps diagnose rather than disappearing during classification')

# Stale, partial, mismatched identity/HEAD and malformed inputs cannot be quiet.
last_error_count=read().get('pmm_pre_dispatch',{}).get('errors',0)
for name,mutate in [('old-cache',lambda d:d.update(run_started_at='2020-01-01T00:00:00Z')),('wrong-pr',lambda d:d['pr'].update(number=8)),('wrong-repo',lambda d:d['pr'].update(repo='elsewhere')),('wrong-head',lambda d:d['pr'].update(head_sha='new-head')),('partial-checks',lambda d:d.update(check_runs={})),('future',lambda d:d.update(run_started_at='2099-01-01T00:00:00Z'))]:
    d=write_bundle();mutate(d);bundle.write_text(json.dumps(d));prior=read()['pmm_pre_dispatch']['snapshot'];r=run();d=read();assert r.returncode in (0,5) and d['pmm_pre_dispatch']['errors']==last_error_count+1 and d['pmm_pre_dispatch']['error_streak']>0 and d['pmm_pre_dispatch']['snapshot']==prior,(name,r.returncode,r.stdout,r.stderr,d)
    if r.stdout:
        p=d['pmm_pre_dispatch']['pending_event'];assert p['diagnostic'];ack(p)
    else:
        assert d['pmm_pre_dispatch']['pending_event'] is None,(name,d)
    last_error_count=d['pmm_pre_dispatch']['errors']
print('PASS: stale/partial/wrong PR/repo/HEAD/future evidence stays unresolved, locally retries, and re-notifies on schedule')
# Unknown state parse errors must not get reset to {}.
state.write_text('{broken');r=run();assert r.returncode==5 and '--pre-dispatch-diagnostic' in r.stdout and len(r.stdout.splitlines())==1 and state.read_text()=='{broken'
put({'pmm_active':True,'pmm_monitor_generation':'gen-live'});write_bundle()
p=packet(run());old=p['event_id']
# New generation supersedes old outbox; old process cannot reclaim it.
d=read();d['pmm_monitor_generation']='gen-next';put(d)
r=run();assert r.returncode==0 and not r.stdout
nargv=argv.copy();nargv[nargv.index('gen-live')]='gen-next';r=run(nargv);p=packet(r);assert p['generation']=='gen-next' and read()['pmm_pre_dispatch']['superseded_event']['event_id']==old
d=read();d['pmm_pre_dispatch']['pending_event']['author']='bob';put(d);before=state.read_bytes();r=run(nargv);assert r.returncode==5 and '--pre-dispatch-diagnostic' in r.stdout and state.read_bytes()==before,(r.stdout,r.stderr)
print('PASS: corrupted state diagnoses without replacement; re-arm fences old processes and outbox generations')
# Bash 3.2 empty args and empty cadence branch execute production code.
if pathlib.Path('/bin/bash').exists():
    hb=home('bash32-home');eb=dict(env,HOME=str(hb));r=run(e=eb,bash='/bin/bash');assert r.returncode==0,(r.stdout,r.stderr)
    pb=json.loads((hb/'.claude/session-state.json').read_text())['pmm_pre_dispatch']['pending_event'];run([str(live/'pmm-pre-dispatch.sh'),'--ack',pb['event_id']],e=eb)
    db=json.loads((hb/'.claude/session-state.json').read_text());db['pmm_digest']=hashlib.sha256(subprocess.check_output(['jq','-cnS','[[7,"abc123","CLEAN","REVIEW_REQUIRED",0,0]]']).rstrip(b'\n')).hexdigest();db['pmm_digest_streak']=0;db['pmm_idle_streak']=0;(hb/'.claude/session-state.json').write_text(json.dumps(db))
    write_bundle([comment]);r=run(e=eb,bash='/bin/bash');assert r.returncode==0,(r.stdout,r.stderr)
    assert 'actionable_review_finding' in json.dumps(json.loads((hb/'.claude/session-state.json').read_text())['pmm_pre_dispatch']['pending_event'])
    write_bundle()
    print('PASS: production collector runs with empty forwarded args on system Bash')
# Exercise actual skill tick/receipt blocks against the real session-state helper.
skill=(root/'.claude/skills/pr-monitor-and-manage/SKILL.md').read_text()
def block(anchor):
    tail=skill.split('<!-- test-anchor: '+anchor+' -->',1)[1];return re.search(r'```bash\n(.*?)\n```',tail,re.S).group(1)
hs=home('receipt-home');es=dict(env,HOME=str(hs));rs=run(e=es);ps=json.loads((hs/'.claude/session-state.json').read_text())['pmm_pre_dispatch']['pending_event'];eid=ps['event_id']
base='SESSION_STATE_SH='+str(live/'session-state.sh')+'\nPMM_PRE_DISPATCH_SH='+str(live/'pmm-pre-dispatch.sh')+'\nARGUMENTS="--tick --monitor-generation gen-live --dispatch-event '+eid+'"\n'
def skill_run(code):return subprocess.run(['bash','-eu','-c',base+code],env=es,text=True,capture_output=True)
r=skill_run(block('pmm-pre-dispatch-tick-gate')+'\nprintf "%s|%s" "$PMM_SKIP_ACTIONS" "$PMM_DUPLICATE_COMPLETED_EVENT"');assert r.returncode==0 and r.stdout=='false|false',(r.stdout,r.stderr)
r=skill_run('PMM_DISPATCH_EVENT='+eid+'\n'+block('pmm-pre-dispatch-actions-receipt'));assert r.returncode!=0 and 'Step6 did not commit' in r.stderr
receipt_stage6='PMM_DISPATCH_EVENT='+eid+'\nPMM_TICK_GENERATION=gen-live\nPMM_INTERNAL_TICK=true\nDIGEST=receipt-digest\nROW_DIGEST=receipt-row\nPMM_CADENCE=5m\nTICK_HAD_ACTION=true\nSEQ=""\n'
r=skill_run(receipt_stage6+block('pmm-pre-dispatch-backoff')+'\n'+block('pmm-pre-dispatch-idle')+'\n'+block('pmm-pre-dispatch-actions-receipt'));assert r.returncode==0,r.stderr
r=skill_run(block('pmm-pre-dispatch-tick-gate')+'\nprintf "%s|%s" "$PMM_SKIP_ACTIONS" "$PMM_DUPLICATE_COMPLETED_EVENT"');assert r.returncode==0 and r.stdout=='true|false',(r.stdout,r.stderr)
r=skill_run('PMM_DISPATCH_EVENT='+eid+'\n'+block('pmm-pre-dispatch-lifecycle-receipt'));assert r.returncode==0,r.stderr
r=skill_run(block('pmm-pre-dispatch-tick-gate'));assert r.returncode==0 and 'already-acknowledged' in r.stdout
print('PASS: actual tick/actions/lifecycle blocks distinguish action replay and late acknowledged delivery')
missing_helper_home=home('missing-helper-home');missing_helper_env=dict(env,HOME=str(missing_helper_home));missing_helper_run=run(e=missing_helper_env)
assert missing_helper_run.returncode==0 and missing_helper_run.stdout.startswith('/pr-monitor-and-manage '),(missing_helper_run.stdout,missing_helper_run.stderr)
missing_helper_event=json.loads((missing_helper_home/'.claude/session-state.json').read_text())['pmm_pre_dispatch']['pending_event'];missing_helper_id=missing_helper_event['event_id']
missing_helper_base='SESSION_STATE_SH='+shlex.quote(str(live/'session-state.sh'))+'\nPMM_PRE_DISPATCH_SH=""\nARGUMENTS="--tick --monitor-generation gen-live --dispatch-event '+missing_helper_id+'"\n'
missing_helper_code=subprocess.run(['bash','-eu','-c',missing_helper_base+block('pmm-pre-dispatch-tick-gate')],env=missing_helper_env,text=True,capture_output=True)
assert missing_helper_code.returncode==1 and 'leaving event '+missing_helper_id+' queued' in missing_helper_code.stderr,(missing_helper_code.stdout,missing_helper_code.stderr)
assert json.loads((missing_helper_home/'.claude/session-state.json').read_text())['pmm_pre_dispatch']['pending_event']['event_id']==missing_helper_id
print('PASS: a dispatch-event tick fails before action when the helper is unavailable and leaves its event queued')
# Reconstruct Step 4's sorted fleet tuple, run its actual digest command and Step 6
# blocks, then prove the next collector tick stays quiet against that digest.
step4_home=home('step4-digest-home');step4_env=dict(env,HOME=str(step4_home));step4_state=step4_home/'.claude/session-state.json'
initial=run(e=step4_env);assert initial.returncode==0 and initial.stdout.startswith('/pr-monitor-and-manage '),(initial.stdout,initial.stderr)
step4_event=json.loads(step4_state.read_text())['pmm_pre_dispatch']['pending_event'];ack_result=run([str(live/'pmm-pre-dispatch.sh'),'--ack',step4_event['event_id']],e=step4_env);assert ack_result.returncode==0,ack_result.stderr
step4_script='FLEET_TUPLE_SORTED=$(jq -cS \'[.prs[] | [.number,.gate.head_sha,.gate.merge_state,.gate.review_decision,.gate.ci_status.failing,.gate.unresolved_thread_count]] | sort_by(.[0])\' "$STEP4_SNAPSHOT")\nDIGEST=$(printf "%s" "$FLEET_TUPLE_SORTED" | shasum -a 256 | awk \'{print $1}\')\nPREV="$DIGEST"\n"$SESSION_STATE_SH" --set ".pmm_digest=\\"$DIGEST\\""\nROW_DIGEST=step4-row\nPMM_CADENCE=5m\nPMM_INTERNAL_TICK=true\nPMM_TICK_GENERATION=gen-live\nTICK_HAD_ACTION=false\nSEQ=""\n'+block('pmm-pre-dispatch-backoff')+'\n'+block('pmm-pre-dispatch-idle')+'\nprintf "%s|%s|%s" "$STREAK" "$IDLE_STREAK" "$EFFECTIVE_CADENCE"'
step4_code='SESSION_STATE_SH='+shlex.quote(str(live/'session-state.sh'))+'\nSTEP4_SNAPSHOT='+shlex.quote(str(tmp/'base.json'))+'\n'+step4_script
r=subprocess.run(['bash','-eu','-c',step4_code],env=step4_env,text=True,capture_output=True);assert r.returncode==0 and r.stdout=='1|1|5m',(r.stdout,r.stderr)
quiet=run(e=step4_env);assert quiet.returncode==0 and quiet.stdout=='',(quiet.stdout,quiet.stderr,step4_state.read_text())
print('PASS: Step 4 fleet digest plus actual Step 6 blocks persists the baseline and the following collector tick is quiet')
# Actions-receipt replay must restore completed Step 6 state without advancing
# either counter or changing the cadence a second time.
step4_data=json.loads(step4_state.read_text());step4_data.update(pmm_digest_streak=4,pmm_idle_streak=7,pmm_cadence='15m');step4_state.write_text(json.dumps(step4_data))
replay_code='SESSION_STATE_SH='+shlex.quote(str(live/'session-state.sh'))+'\nPMM_SKIP_ACTIONS=true\nPMM_INTERNAL_TICK=true\nPMM_TICK_GENERATION=gen-live\nDIGEST=changed\nPREV=old\nROW_DIGEST=changed-row\nPMM_CADENCE=5m\nTICK_HAD_ACTION=false\nSEQ=""\n'+block('pmm-pre-dispatch-backoff')+'\n'+block('pmm-pre-dispatch-idle')+'\nprintf "%s|%s|%s" "$STREAK" "$IDLE_STREAK" "$EFFECTIVE_CADENCE"'
r=subprocess.run(['bash','-eu','-c',replay_code],env=step4_env,text=True,capture_output=True);assert r.returncode==0 and r.stdout=='4|7|15m',(r.stdout,r.stderr)
after=json.loads(step4_state.read_text());assert (after['pmm_digest_streak'],after['pmm_idle_streak'],after['pmm_cadence'])==(4,7,'15m'),after
print('PASS: actions-receipt replay restores completed counters and cadence without incrementing or writing them')
r=skill_run('DIGEST=same\nROW_DIGEST=same-row\nPREV=same\nPMM_CADENCE=5m\nPMM_INTERNAL_TICK=false\nTICK_HAD_ACTION=false\n'+block('pmm-pre-dispatch-backoff')+'\n'+block('pmm-pre-dispatch-idle')+'\nprintf "%s|%s|%s" "$STREAK" "$IDLE_STREAK" "$EFFECTIVE_CADENCE"')
assert r.returncode==0 and r.stdout=='0|0|5m',(r.stdout,r.stderr)
print('PASS: real owner-turn scheduling blocks reset backoff and idle counters without shell filtering')

r=subprocess.run(['bash','-eu','-c',base+'ARGUMENTS="--tick --monitor-generation gen-live --pre-dispatch-diagnostic"\n'+block('pmm-pre-dispatch-tick-gate')],env=es,text=True,capture_output=True)
assert r.returncode==1 and 'no PR action is authorized' in r.stderr,(r.stdout,r.stderr)
print('PASS: non-durable diagnostic invocation stops for repair before reading gates or authorizing actions')

# Failed computations and writes have exactly one diagnostic slash event, never quiet success.
import shutil, shlex
real_jq=shutil.which('jq');state_helper=live/'session-state.sh';real_state=live/'session-state-real.sh';shutil.copy2(state_helper,real_state)
def executable(path,code):path.write_text('#!/usr/bin/env bash\n'+code);path.chmod(0o755)
q=pathlib.Path(binpath)/'jq'
executable(q,'for arg in "$@"; do [[ "$arg" != \'.snapshot.data // null\' ]] || exit 9; done\nexec '+shlex.quote(real_jq)+' "$@"\n')
hf=home('computation-fault');ef=dict(env,HOME=str(hf));write_bundle();r=run(e=ef);assert r.returncode==5 and len(r.stdout.splitlines())==1 and json.loads((hf/'.claude/session-state.json').read_text())['pmm_pre_dispatch']['pending_event']['diagnostic'],(r.stdout,r.stderr)
q.unlink()
executable(state_helper,'for arg in "$@"; do [[ "$arg" != --cas ]] || exit 5; done\nexec '+shlex.quote(str(real_state))+' "$@"\n')
hf=home('write-fault');ef=dict(env,HOME=str(hf));before=(hf/'.claude/session-state.json').read_bytes();r=run(e=ef);assert r.returncode==5 and len(r.stdout.splitlines())==1 and '--pre-dispatch-diagnostic' in r.stdout and (hf/'.claude/session-state.json').read_bytes()==before,(r.stdout,r.stderr)
# Inject another writer between read and CAS: its receipt survives both retries.
executable(state_helper,'for arg in "$@"; do if [[ "$arg" == --cas ]]; then '+shlex.quote(str(real_state))+' --set \'.pmm_pre_dispatch.actions_completed_event_id="external-receipt"\' >/dev/null; fi; done\nexec '+shlex.quote(str(real_state))+' "$@"\n')
hf=home('cas-race');ef=dict(env,HOME=str(hf));r=run(e=ef);assert r.returncode==5 and '--pre-dispatch-diagnostic' in r.stdout and json.loads((hf/'.claude/session-state.json').read_text())['pmm_pre_dispatch']['actions_completed_event_id']=='external-receipt',(r.stdout,r.stderr)
shutil.copy2(real_state,state_helper)
print('PASS: failed jq/write and concurrent receipt CAS produce diagnostics and preserve state')

# One atomic Step6 batch owns all counters/cadence and the actions receipt.
# Execute real fences without errexit: explicit failures must stop completion.
step6_backoff=block('pmm-pre-dispatch-backoff');step6_idle=block('pmm-pre-dispatch-idle');step6_verify=block('pmm-pre-dispatch-actions-receipt')
step6_home=home('step6-atomic');step6_env=dict(env,HOME=str(step6_home));write_bundle()
step6_initial=run(e=step6_env);assert step6_initial.returncode==0,(step6_initial.stdout,step6_initial.stderr)
step6_file=step6_home/'.claude/session-state.json';step6_seed=json.loads(step6_file.read_text());step6_event=step6_seed['pmm_pre_dispatch']['pending_event']['event_id']
step6_seed.update(pmm_digest='same',pmm_row_digest='old-row',pmm_digest_streak=2,pmm_idle_streak=2,pmm_cadence='5m');step6_file.write_text(json.dumps(step6_seed))
def step6_call(code,helper=real_state,extra=''):
 prefix='SESSION_STATE_SH='+shlex.quote(str(helper))+'\nPMM_PRE_DISPATCH_SH='+shlex.quote(str(live/'pmm-pre-dispatch.sh'))+'\nPMM_INTERNAL_TICK=true\nPMM_TICK_GENERATION=gen-live\nPMM_DISPATCH_EVENT='+step6_event+'\nARGUMENTS="--tick --monitor-generation gen-live --dispatch-event '+step6_event+'"\nDIGEST=same\nROW_DIGEST=new-row\nPMM_CADENCE=5m\nTICK_HAD_ACTION=false\nSEQ=""\n'+extra
 return subprocess.run(['bash','-u','-c',prefix+code],env=step6_env,text=True,capture_output=True)
step6_code=step6_backoff+'\n'+step6_idle+'\n'+step6_verify
step6_fault=tmp/'step6-write-fault.sh';executable(step6_fault,'for arg in "$@"; do [[ "$arg" != --cas ]] || exit 5; done\nexec '+shlex.quote(str(real_state))+' "$@"\n')
step6_before=step6_file.read_bytes();r=step6_call(step6_code,helper=step6_fault);assert r.returncode!=0 and step6_file.read_bytes()==step6_before,(r.stdout,r.stderr)
r=step6_call(step6_verify);assert r.returncode!=0 and step6_file.read_bytes()==step6_before,(r.stdout,r.stderr)
r=step6_call(block('pmm-pre-dispatch-tick-gate')+'\nprintf "%s" "$PMM_SKIP_ACTIONS"');assert r.returncode==0 and r.stdout=='false',(r.stdout,r.stderr)
# A writer that starts /wrap after the snapshot defeats the whole CAS; it cannot
# create a false completion receipt or advance only one of the counters.
step6_race=tmp/'step6-live-race.sh';step6_once=tmp/'step6-race-once'
step6_lock={'status':'active','dispatched_at':now(),'head_sha':'abc123'}
executable(step6_race,'for arg in "$@"; do if [[ "$arg" == --cas ]] && mkdir '+shlex.quote(str(step6_once))+' 2>/dev/null; then '+shlex.quote(str(real_state))+' --set '+shlex.quote('.pmm_in_flight["7"]='+json.dumps(step6_lock))+'; fi; done\nexec '+shlex.quote(str(real_state))+' "$@"\n')
r=step6_call(step6_code,helper=step6_race);step6_after=json.loads(step6_file.read_text());assert r.returncode!=0 and step6_after['pmm_in_flight']['7']['status']=='active',(r.stdout,r.stderr)
for key in ['pmm_digest','pmm_row_digest','pmm_digest_streak','pmm_idle_streak','pmm_cadence','pmm_pre_dispatch']:assert step6_after.get(key)==step6_seed.get(key),(key,step6_after)
# Retry refreshes live work, resets idle, and commits receipt+all counters at once.
r=step6_call(step6_code,extra='ACTIVE_WRAPS=0\nACTIVE_FIXERS=0\nHELD_COUNT=0\n');assert r.returncode==0,(r.stdout,r.stderr)
step6_done=json.loads(step6_file.read_text());assert (step6_done['pmm_digest_streak'],step6_done['pmm_idle_streak'],step6_done['pmm_cadence'])==(3,0,'15m') and step6_done['pmm_pre_dispatch']['actions_completed_event_id']==step6_event
step6_before=step6_file.read_bytes();r=step6_call(step6_code,extra='PMM_SKIP_ACTIONS=true\n');assert r.returncode==0 and step6_file.read_bytes()==step6_before,(r.stdout,r.stderr)
print('PASS: failed/stale Step6 atomic commit cannot advance counters or fabricate actions completion; fresh retry sees /wrap and replay never double-counts')
# A delayed receipt replay must observe work that started after an earlier idle
# commit, suppress idle routing, and leave the original counters untouched.
step6_delayed=json.loads(json.dumps(step6_done));step6_delayed['pmm_idle_streak']=9;step6_file.write_text(json.dumps(step6_delayed));step6_before=step6_file.read_bytes()
r=step6_call(step6_code+'\nprintf "%s" "$IDLE_STREAK"',extra='PMM_SKIP_ACTIONS=true\n');assert r.returncode==0 and r.stdout=='0' and step6_file.read_bytes()==step6_before,(r.stdout,r.stderr)

# Canonical live-work classes, with stale shell flags deliberately set to zero.
for step6_name,step6_work,step6_idle_expected in [
 ('active-wrap',{'pmm_in_flight':{'7':step6_lock}},0),
 ('completed-wrap',{'pmm_in_flight':{'7':{'status':'complete'}}},3),
 ('unreleased-hold',{'pmm_merge_holds':{'7':{'released':False}}},0),
 ('released-hold',{'pmm_merge_holds':{'7':{'released':True}}},3),
 ('active-agent',{'active_agents':{'worker':{'phase':'A','status':'running'}}},0),
 ('completed-agent',{'active_agents':{'worker':{'phase':'A','status':'complete'}}},3)]:
 step6_case=json.loads(json.dumps(step6_seed));step6_case.update(step6_work);step6_file.write_text(json.dumps(step6_case))
 r=step6_call(step6_code,extra='ACTIVE_WRAPS=0\nACTIVE_FIXERS=0\nHELD_COUNT=0\n');step6_result=json.loads(step6_file.read_text());assert r.returncode==0 and step6_result['pmm_idle_streak']==step6_idle_expected,(step6_name,r.stdout,r.stderr,step6_result)
step6_file.write_text(json.dumps(step6_seed));step6_before=step6_file.read_bytes();r=step6_call(step6_code,extra='SEQ='+shlex.quote('{"bogus":true}')+'\n');assert r.returncode!=0 and step6_file.read_bytes()==step6_before
step6_case=json.loads(json.dumps(step6_seed));step6_case['pmm_in_flight']={'7':{}};step6_file.write_text(json.dumps(step6_case));step6_before=step6_file.read_bytes();r=step6_call(step6_code);assert r.returncode!=0 and step6_file.read_bytes()==step6_before
# The quiet collector also treats a partial lock as unknown, not an idle fleet.
assert run([str(live/'pmm-pre-dispatch.sh'),'--ack',step6_event],e=step6_env).returncode==0
r=run(e=step6_env);step6_result=json.loads(step6_file.read_text());assert r.returncode==5 and step6_result['pmm_pre_dispatch']['pending_event']['diagnostic'],(r.stdout,r.stderr)
step6_case=json.loads(json.dumps(step6_seed));step6_case['pmm_monitor_generation']='new-owner';step6_file.write_text(json.dumps(step6_case));step6_before=step6_file.read_bytes();r=step6_call(step6_code);assert r.returncode!=0 and step6_file.read_bytes()==step6_before
print('PASS: refreshed active wraps/agents/unreleased holds block idle; completed/released work permits idle; partial locks and stale generations cannot complete')

# Inject real production Step6/Step7 schedule publication AFTER the collector's
# coherent read, immediately before its CAS. First race changes ROOT ONLY so the
# old gate-only CAS would overwrite it. Second race also publishes an outbox.
skill_text=(root/'.claude/skills/pr-monitor-and-manage/SKILL.md').read_text()
backoff=re.search(r'<!-- test-anchor: pmm-pre-dispatch-backoff -->\s*```bash\n(.*?)\n```',skill_text,re.S).group(1)
claim=re.search(r'<!-- test-anchor: pmm-pre-dispatch-lifecycle-claim -->\s*```bash\n(.*?)\n```',skill_text,re.S).group(1)
authorize=re.search(r'<!-- test-anchor: pmm-pre-dispatch-lifecycle-authorize -->\s*```bash\n(.*?)\n```',skill_text,re.S).group(1)
armed=re.search(r'<!-- test-anchor: pmm-pre-dispatch-lifecycle-armed-receipt -->\s*```bash\n(.*?)\n```',skill_text,re.S).group(1)
publication=next(b for b in re.findall(r'```bash\n(.*?)\n```',skill_text,re.S) if b.startswith('NOW=$(date -u +%FT%TZ)') and 'pmm_pre_dispatch_version' in b)
for outbox_race in (False,True):
 hf=home('schedule-race-'+str(outbox_race));ef=dict(env,HOME=str(hf));write_bundle()
 r=run(e=ef);initial=json.loads((hf/'.claude/session-state.json').read_text())['pmm_pre_dispatch']['pending_event']
 run([str(live/'pmm-pre-dispatch.sh'),'--ack',initial['event_id']],e=ef)
 sf=hf/'.claude/session-state.json';d=json.loads(sf.read_text());d['pmm_digest']=hashlib.sha256(subprocess.check_output(['jq','-cnS','[[7,"abc123","CLEAN","REVIEW_REQUIRED",0,0]]']).rstrip(b'\n')).hexdigest();d['pmm_digest_streak']=0;d['pmm_idle_streak']=0;sf.write_text(json.dumps(d))
 before_gate=d['pmm_pre_dispatch'];writer=tmp/('schedule-writer-'+str(outbox_race)+'.sh');winner=tmp/('schedule-winner-'+str(outbox_race)+'.json');once=tmp/('schedule-once-'+str(outbox_race))
 setup='set -eu\nSESSION_STATE_SH='+shlex.quote(str(real_state))+'\nPMM_INTERNAL_TICK=true\nPMM_TICK_GENERATION=gen-live\nTICK_HAD_ACTION=false\nSEQ=""\nDIGEST=owner-digest\nPREV=old-digest\nROW_DIGEST=owner-row\nPMM_CADENCE=10m\n'
 setup+=backoff+'\n'+block('pmm-pre-dispatch-idle')+'\nIDLE_STREAK=17\nEFFECTIVE_CADENCE=30m\nMONITOR_TASK_ID=77\nMONITOR_GENERATION=gen-live\nPMM_MONITOR_CONFIG={}\nPMM_AUTHOR=alice\nPMM_TICK_GENERATION=gen-live\nNEW_MONITOR_GENERATION=fixture-next\n'+claim+'\n'+publication+'\n'
 setup+='"$SESSION_STATE_SH" --set '+shlex.quote('.pmm_next_expected_tick_at="2099-01-01T00:00:00Z"')+' --set '+shlex.quote('.unrelated_owner_marker="keep"')+'\n'
 if outbox_race:
  owner_event=dict(initial,event_id='c'*64)
  setup+='"$SESSION_STATE_SH" --set '+shlex.quote('.pmm_pre_dispatch.pending_event='+json.dumps(owner_event))+' --set '+shlex.quote('.pmm_pre_dispatch.actions_completed_event_id="owner-actions"')+'\n'
 setup+='cp "$HOME/.claude/session-state.json" '+shlex.quote(str(winner))+'\n'
 writer.write_text(setup)
 executable(state_helper,'for arg in "$@"; do if [[ "$arg" == --cas ]] && mkdir '+shlex.quote(str(once))+' 2>/dev/null; then bash '+shlex.quote(str(writer))+' || exit $?; fi; done\nexec '+shlex.quote(str(real_state))+' "$@"\n')
 r=run(e=ef);after=json.loads(sf.read_text());expected=json.loads(winner.read_text())
 assert r.returncode==5 and len(r.stdout.splitlines())==1 and '--pre-dispatch-diagnostic' in r.stdout,(r.stdout,r.stderr)
 assert after==expected,'stale collector/diagnostic overwrote concurrent schedule or outbox'
 assert after['pmm_digest']=='owner-digest' and after['pmm_row_digest']=='owner-row' and after['pmm_cadence']=='30m' and after['pmm_idle_streak']==0 and after['pmm_next_expected_tick_at']=='2099-01-01T00:00:00Z'
 if not outbox_race: assert after['pmm_pre_dispatch']==before_gate
 else: assert after['pmm_pre_dispatch']['pending_event']['event_id']=='c'*64 and after['pmm_pre_dispatch']['actions_completed_event_id']=='owner-actions'
 shutil.copy2(real_state,state_helper)
 if not outbox_race:
  r=run(e=ef);fresh=json.loads(sf.read_text())['pmm_pre_dispatch']['pending_event']
  assert r.returncode==0 and 'state_digest' in fresh['reasons'],(r.stdout,r.stderr,fresh)
  # Fresh owner processing (actual Step6) aligns the changed digest, then ack.
  fresh_digest=hashlib.sha256(subprocess.check_output(['jq','-cnS','[[7,"abc123","CLEAN","REVIEW_REQUIRED",0,0]]']).rstrip(b'\n')).hexdigest()
  fresh_owner='set -eu\nSESSION_STATE_SH='+shlex.quote(str(real_state))+'\nPMM_INTERNAL_TICK=true\nPMM_TICK_GENERATION=gen-live\nTICK_HAD_ACTION=false\nSEQ=""\nPMM_CADENCE=30m\nDIGEST='+fresh_digest+'\nPREV=owner-digest\nROW_DIGEST=fresh-row\n'+backoff+'\n'+block('pmm-pre-dispatch-idle')
  subprocess.run(['bash','-c',fresh_owner],env=ef,check=True,capture_output=True,text=True)
  assert run([str(live/'pmm-pre-dispatch.sh'),'--ack',fresh['event_id']],e=ef).returncode==0
  r=run(e=ef);assert r.returncode==0 and r.stdout=='',(r.stdout,r.stderr)
print('PASS: real production schedule-writer race preserves whole winning transaction and outbox; stale diagnostic cannot write; fresh quiet retry is silent')

# Actual lifecycle fences: a tick that passed Step0 cannot adopt a later owner;
# direct starts race on one claim and uncertain remote outcomes retain it.
hc=home('lifecycle-claim');ec=dict(env,HOME=str(hc));sc=hc/'.claude/session-state.json'
def lifecycle(body):
 return subprocess.run(['bash','-c','set -eu\nNEW_MONITOR_GENERATION=fixture-next\nSESSION_STATE_SH='+shlex.quote(str(real_state))+'\n'+body],env=ec,text=True,capture_output=True)
lifecycle_base='PMM_INTERNAL_TICK=true\nPMM_TICK_GENERATION=gen-live\nPMM_MONITOR_CONFIG={}\n'
sc.write_text(json.dumps({'pmm_active':True,'pmm_monitor_generation':'new-owner','pmm_monitor_task_id':222,'pmm_pre_dispatch_config':{'repo':'new'}}));winner=sc.read_bytes()
r=lifecycle(lifecycle_base+claim);assert r.returncode!=0 and sc.read_bytes()==winner,(r.stdout,r.stderr)
sc.write_text(json.dumps({'pmm_active':True,'pmm_monitor_generation':'gen-live','pmm_monitor_task_id':111}))
r=lifecycle(lifecycle_base+claim+'\nprintf "%s\n%s" "$PMM_REARM_CLAIM" "$PMM_LIFECYCLE_EXPECT"');assert r.returncode==0,r.stderr
lines=r.stdout.splitlines();owned_claim=json.loads(lines[-2]);owned_expect=json.loads(lines[-1]);claimed=sc.read_bytes()
r=lifecycle('PMM_INTERNAL_TICK=false\nPMM_MONITOR_CONFIG={"other":true}\n'+claim);assert r.returncode!=0 and sc.read_bytes()==claimed
# Authorization before a tool call rejects a later stop/owner write without
# rewriting it; conditional publication likewise cannot overwrite that owner.
d=json.loads(claimed);d.update(pmm_monitor_generation='winner',pmm_monitor_task_id=333);sc.write_text(json.dumps(d));winner=sc.read_bytes()
restore='PMM_REARM_CLAIM='+shlex.quote(json.dumps(owned_claim))+'\nPMM_LIFECYCLE_EXPECT='+shlex.quote(json.dumps(owned_expect))+'\n'
r=lifecycle(restore+authorize);assert r.returncode!=0 and sc.read_bytes()==winner
r=lifecycle(restore+'MONITOR_TASK_ID=444\nMONITOR_GENERATION=stale-arm\nPMM_MONITOR_CONFIG={}\nEFFECTIVE_CADENCE=5m\nPMM_AUTHOR=alice\nIDLE_STREAK=0\n'+publication);assert r.returncode!=0 and sc.read_bytes()==winner
# Successful direct claim/publication releases the claim atomically. A crash or
# unknown tool result prior to publication keeps the stop guard + receipt.
sc.write_text('{}');r=lifecycle('PMM_INTERNAL_TICK=false\nPMM_MONITOR_CONFIG={}\nNEW_MONITOR_GENERATION=direct-start\n'+claim+'\n'+authorize+'\nMONITOR_TASK_ID=555\nNEW_MONITOR_GENERATION=direct-start\n'+armed+'\nEFFECTIVE_CADENCE=5m\nPMM_AUTHOR=alice\nIDLE_STREAK=0\n'+publication);assert r.returncode==0,(r.stdout,r.stderr)
d=json.loads(sc.read_text());assert d['pmm_rearm'] is None and d['pmm_monitor_task_id']==555 and d['pmm']['stop_requested'] is False
print('PASS: production lifecycle claim/action authorization/publication reject stale generations and concurrent starts, preserve uncertain receipts and newer owner')
for missing_id in ('','null'):
 before=sc.read_bytes();r=lifecycle('MONITOR_TASK_ID='+shlex.quote(missing_id)+'\nNEW_MONITOR_GENERATION=direct-start\n'+armed)
 assert r.returncode!=0 and sc.read_bytes()==before,(r.stdout,r.stderr)
print('PASS: missing/unknown Monitor task IDs cannot create an armed receipt')


# Identical acknowledged collector errors retry locally, with a durable wake every
# third observation; new fingerprints wake immediately and clean collection resets them.
def ack_home(home_path, env_args, event):
    result=run([str(live/'pmm-pre-dispatch.sh'),'--ack',event['event_id']],e=env_args);assert result.returncode==0,result.stderr
hf=home('diagnostic-retry');ef=dict(env,HOME=str(hf));g=json.loads(gate);g['authorship']='unknown';ef['STUB_GATE_JSON']=json.dumps(g)
r=run(e=ef);assert r.returncode==5 and r.stdout.startswith('/pr-monitor-and-manage '),(r.stdout,r.stderr);first=json.loads((hf/'.claude/session-state.json').read_text())['pmm_pre_dispatch']['pending_event'];assert first['diagnostic'];ack_home(hf,ef,first)
for expected in (2,3):
    r=run(e=ef);d=json.loads((hf/'.claude/session-state.json').read_text());assert r.returncode==0 and r.stdout=='' and d['pmm_pre_dispatch']['pending_event'] is None and d['pmm_pre_dispatch']['error_streak']==expected,(expected,r.stdout,r.stderr,d)
r=run(e=ef);d=json.loads((hf/'.claude/session-state.json').read_text());fourth=d['pmm_pre_dispatch']['pending_event'];assert r.returncode==5 and fourth['diagnostic'] and fourth['event_id']!=first['event_id'] and d['pmm_pre_dispatch']['error_streak']==4,(r.stdout,r.stderr,d)
# A pending diagnostic takes precedence over newly observed bad data.
replayed_env=dict(ef,STUB_GATE_JSON='{}');r=run(e=replayed_env);d=json.loads((hf/'.claude/session-state.json').read_text());replayed_id=re.search(r'--dispatch-event ([a-f0-9]{64})',r.stdout).group(1);assert r.returncode==0 and replayed_id==fourth['event_id'] and d['pmm_pre_dispatch']['errors']==4,(r.stdout,r.stderr,d)
ack_home(hf,ef,fourth)
# A different failure fingerprint is a new diagnosis and wakes immediately.
r=run(e=replayed_env);d=json.loads((hf/'.claude/session-state.json').read_text());new_error=d['pmm_pre_dispatch']['pending_event'];assert r.returncode==5 and new_error['diagnostic'] and new_error['event_id']!=fourth['event_id'] and d['pmm_pre_dispatch']['error_streak']==1,(r.stdout,r.stderr,d)
ack_home(hf,replayed_env,new_error)
# Once collection recovers, it records a normal meaningful event and clears only
# collector-error throttling state.
recovered_env=dict(env,HOME=str(hf));r=run(e=recovered_env);d=json.loads((hf/'.claude/session-state.json').read_text());assert r.returncode==0 and not d['pmm_pre_dispatch']['pending_event'].get('diagnostic',False) and d['pmm_pre_dispatch']['error_streak']==0 and d['pmm_pre_dispatch']['diagnostic_fingerprint'] is None,(r.stdout,r.stderr,d)
print('PASS: collector diagnostic fingerprints retry locally, re-notify at threshold, preserve pending events, and reset on recovery')
# Deadline-unknown cadence and collector-error cadence keep independent fingerprints.
hf=home('deadline-error-independent');statefile=hf/'.claude/session-state.json';state_data=json.loads(statefile.read_text());state_data['pmm_digest']=hashlib.sha256(b'[[7,"abc123","CLEAN","REVIEW_REQUIRED",0,0]]').hexdigest();state_data['pmm_digest_streak']=0;state_data['pmm_idle_streak']=0;statefile.write_text(json.dumps(state_data));ef=dict(env,HOME=str(hf))
# Establish a prior snapshot so only the deadline and collector failure state
# participate in the retry assertions below.
r=run(e=ef);assert r.returncode==0 and r.stdout.startswith('/pr-monitor-and-manage '),(r.stdout,r.stderr);ack_home(hf,ef,json.loads(statefile.read_text())['pmm_pre_dispatch']['pending_event'])
state_data=json.loads(statefile.read_text());state_data['active_agents']={'foreign':{'pr':7,'phase':'A','status':'running'}};statefile.write_text(json.dumps(state_data))
r=run(e=ef);assert r.returncode==0 and r.stdout.startswith('/pr-monitor-and-manage '),(r.stdout,r.stderr);deadline_event=json.loads(statefile.read_text())['pmm_pre_dispatch']['pending_event'];assert deadline_event['reasons'].count('deadline_state_unknown')==1;ack_home(hf,ef,deadline_event)
bad_gate=json.loads(gate);bad_gate['merge_state']='UNKNOWN';bad_env=dict(ef,STUB_GATE_JSON=json.dumps(bad_gate));r=run(e=bad_env);d=json.loads(statefile.read_text());assert r.returncode==5 and d['pmm_pre_dispatch']['error_streak']==1 and d['pmm_pre_dispatch']['deadline_unknown_checks']==1,(r.stdout,r.stderr,d)
ack_home(hf,bad_env,d['pmm_pre_dispatch']['pending_event'])
for expected in (2,3):
    retry_result=run(e=ef);d=json.loads(statefile.read_text());assert retry_result.stdout=='' and d['pmm_pre_dispatch']['deadline_unknown_checks']==expected,(retry_result.returncode,retry_result.stdout,retry_result.stderr,d)
r=run(e=ef);d=json.loads(statefile.read_text());assert r.returncode==0 and d['pmm_pre_dispatch']['pending_event']['reasons'].count('deadline_state_unknown')==1 and d['pmm_pre_dispatch']['deadline_unknown_checks']==4 and d['pmm_pre_dispatch']['error_streak']==0,(r.stdout,r.stderr,d)
print('PASS: acknowledged unknown deadlines re-notify on their own interval despite separate collector diagnostics')
# Snapshot freshness scales to the persisted poll cadence, while remaining bounded.
hf=home('stale-cadence');stale_file=hf/'.claude/session-state.json';stale_env=dict(env,HOME=str(hf));r=run(e=stale_env);assert r.returncode==0 and r.stdout.startswith('/pr-monitor-and-manage '),(r.stdout,r.stderr)
stale_data=json.loads(stale_file.read_text());first=stale_data['pmm_pre_dispatch']['pending_event'];assert run([str(live/'pmm-pre-dispatch.sh'),'--ack',first['event_id']],e=stale_env).returncode==0
stale_data=json.loads(stale_file.read_text());stale_data['pmm_digest']=hashlib.sha256(b'[[7,"abc123","CLEAN","REVIEW_REQUIRED",0,0]]').hexdigest();stale_data['pmm_cadence']='60m';stale_data['pmm_pre_dispatch']['snapshot']['recorded_at']=(datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(minutes=70)).strftime('%Y-%m-%dT%H:%M:%SZ');stale_file.write_text(json.dumps(stale_data))
r=run(e=stale_env);assert r.returncode==0 and r.stdout=='',(r.returncode,r.stdout,r.stderr,stale_file.read_text())
stale_data=json.loads(stale_file.read_text());stale_data['pmm_pre_dispatch']['snapshot']['recorded_at']=(datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(minutes=130)).strftime('%Y-%m-%dT%H:%M:%SZ');stale_file.write_text(json.dumps(stale_data))
r=run(e=stale_env);d=json.loads(stale_file.read_text());assert r.returncode==0 and 'snapshot_stale' in d['pmm_pre_dispatch']['pending_event']['reasons'],(r.stdout,r.stderr,d)
print('PASS: snapshot freshness tolerates one widened 60-minute interval and still wakes after two')
# Unknown gate state never becomes a quiet unchanged comparison.
hf=home('unknown-gate');eg=dict(env,HOME=str(hf));g=json.loads(gate);g['authorship']='unknown';eg['STUB_GATE_JSON']=json.dumps(g);r=run(e=eg);pg=json.loads((hf/'.claude/session-state.json').read_text())['pmm_pre_dispatch']['pending_event'];assert r.returncode==5 and pg['diagnostic'],(r.stdout,r.stderr)
print('PASS: unknown ownership/merge evidence always wakes diagnosis')
hu=home('unknown-identity');du=json.loads((hu/'.claude/session-state.json').read_text());du.pop('pmm_monitor_generation');(hu/'.claude/session-state.json').write_text(json.dumps(du));eu=dict(env,HOME=str(hu));r=run(e=eu);assert r.returncode==5 and '--pre-dispatch-diagnostic' in r.stdout,(r.stdout,r.stderr)
print('PASS: unknown Monitor identity diagnoses instead of suppressing a tick as stale')
hu=home('unknown-stop');du=json.loads((hu/'.claude/session-state.json').read_text());du['pmm']={'stop_requested':'bad'};(hu/'.claude/session-state.json').write_text(json.dumps(du));r=run(e=dict(env,HOME=str(hu)));assert r.returncode==5 and '--pre-dispatch-diagnostic' in r.stdout,(r.stdout,r.stderr)
partial=tmp/'partial-snapshot.json';partial.write_text(json.dumps({'repo':'org/repo','author':'alice','collected_at':now(),'prs':[],'evidence':[]}));hu=home('partial-snapshot');r=run(argv+['--fixture',str(partial)],e=dict(env,HOME=str(hu)));assert r.returncode==5 and json.loads((hu/'.claude/session-state.json').read_text())['pmm_pre_dispatch']['pending_event']['diagnostic'],(r.stdout,r.stderr)
print('PASS: partial orchestration and malformed stop state cannot take the quiet path')


# Verify delayed A after B acknowledgement, and completed-action replay gate failure.
# These execute actual skill blocks, not a copied event state machine.
dh=hs/'.claude/session-state.json';d=json.loads(dh.read_text());d['pmm_pre_dispatch']['last_acknowledged_event_id']='b'*64;dh.write_text(json.dumps(d))
r=skill_run(block('pmm-pre-dispatch-tick-gate'));assert r.returncode==0 and 'already-acknowledged' in r.stdout,(r.stdout,r.stderr)
r=skill_run('PMM_DUPLICATE_COMPLETED_EVENT=true\nPMM_DISPATCH_EVENT='+eid+'\nVERDICTS_JSON=broken\n'+block('pmm-pre-dispatch-replay-guard'));assert r.returncode==1 and 'fresh gate is unreadable' in r.stderr,(r.stdout,r.stderr)
print('PASS: bounded ack history handles delayed old events and malformed fresh gates refuse acknowledgement')
# Telemetry distinguishes cumulative errors from a recoverable consecutive streak.
hm=home('metric-home');em=dict(env,HOME=str(hm));bad=write_bundle();bad['check_runs']={};bundle.write_text(json.dumps(bad));ids=[]
r=run(e=em);md=json.loads((hm/'.claude/session-state.json').read_text());mp=md['pmm_pre_dispatch']['pending_event'];assert r.returncode==5;ids.append(mp['event_id'])
assert run([str(live/'pmm-pre-dispatch.sh'),'--ack',mp['event_id']],e=em).returncode==0
r=run(e=em);md=json.loads((hm/'.claude/session-state.json').read_text());assert r.returncode==0 and r.stdout=='' and md['pmm_pre_dispatch']['pending_event'] is None
assert md['pmm_pre_dispatch']['errors']==2 and md['pmm_pre_dispatch']['ticks']==2 and md['pmm_pre_dispatch']['error_streak']==2
write_bundle();r=run(e=em);mp=json.loads((hm/'.claude/session-state.json').read_text())['pmm_pre_dispatch']['pending_event'];run([str(live/'pmm-pre-dispatch.sh'),'--ack',mp['event_id']],e=em)
md=json.loads((hm/'.claude/session-state.json').read_text());md['pmm_digest']=hashlib.sha256(subprocess.check_output(['jq','-cnS','[[7,"abc123","CLEAN","REVIEW_REQUIRED",0,0]]']).rstrip(b'\n')).hexdigest();md['pmm_digest_streak']=0;md['pmm_idle_streak']=0;(hm/'.claude/session-state.json').write_text(json.dumps(md))
r=run(e=em);md=json.loads((hm/'.claude/session-state.json').read_text())['pmm_pre_dispatch'];assert r.returncode==0 and not r.stdout and md['errors']==2 and md['error_streak']==0 and md['last_error_at']
print('PASS: error/recovery metrics retain cumulative counts and new transitions get distinct sequence IDs')


# Wake carries the configured bound and invokes only the canonical main lifecycle.
# Execute its actual flag/request/result fences; no live Skill/Monitor API exists
# on this host, so tool invocation itself is deliberately not simulated as proof.
lifecycle_text=(root/'.claude/skills/pr-monitor-and-manage/references/pmm-lifecycle.md').read_text()
wake_text=(root/'.claude/skills/pr-monitor-and-manage-wake/SKILL.md').read_text()
pause_config=next(b for b in re.findall(r'```bash\n(.*?)\n```',lifecycle_text,re.S) if 'CONFIG_AT_PAUSE=$(jq' in b)
wake_flags=next(b for b in re.findall(r'```bash\n(.*?)\n```',wake_text,re.S) if b.startswith('CONFIG=$(jq') and 'PMM_FLAGS=' in b)
wake_request=re.search(r'<!-- test-anchor: pmm-wake-resume-request -->\s*```bash\n(.*?)\n```',wake_text,re.S).group(1)
wake_verify=re.search(r'<!-- test-anchor: pmm-wake-resume-verify -->\s*```bash\n(.*?)\n```',wake_text,re.S).group(1)
sc.write_text('{}')
pause_setup='PMM_AUTHOR=alice\nOWNER_REPO=org/repo\nPMM_CADENCE=5m\nPMM_MAX_PARALLEL=3\nPMM_MAX_DEEP_PRS=7\nPMM_IDLE_PAUSE_AFTER=3\nPMM_AUTO_WAKE=false\nPMM_AUTO_WAKE_CADENCE=60m\nPMM_CONFIRM_MERGES=true\nPR_LIST="[]"\n'
r=lifecycle(pause_setup+pause_config+'\n"$SESSION_STATE_SH" --set ".pmm.config_at_pause=$CONFIG_AT_PAUSE"\nPMM_WAKE_EXPECT=$(jq -cn --argjson cfg "$CONFIG_AT_PAUSE" \'{paused_at:"2026-10-31T02:00:00Z",config:$cfg}\')\n'+wake_flags+'\n'+wake_request)
assert r.returncode==0 and '--max-deep-prs 7' in r.stdout and r.stdout.startswith('/pr-monitor-and-manage '),(r.stdout,r.stderr)
assert 'while sleep' not in wake_text[wake_text.index('## Step 4b:'):]
# Bind a delayed wake to its original pause/config before work, and again at
# claimed publication. Unknown/changed state cannot turn it into a fresh start.
bound_request=r.stdout.strip()
saved=json.loads(sc.read_text())['pmm']['config_at_pause']
paused='2026-10-31T02:00:00Z'
paused_state={'pmm_active':False,'pmm_monitor_task_id':None,'pmm_monitor_generation':None,'pmm':{'paused_at':paused,'config_at_pause':saved,'stop_requested':False}}
sc.write_text(json.dumps(paused_state))
bound_setup='ARGUMENTS='+shlex.quote(bound_request.split(' ',1)[1])+'\nPMM_PRE_DISPATCH_SH='+shlex.quote(str(live/'pmm-pre-dispatch.sh'))+'\n'
r=lifecycle(bound_setup+block('pmm-pre-dispatch-tick-gate'));assert r.returncode==0,(r.stdout,r.stderr)
for changed in [dict(paused_state,pmm={'paused_at':paused,'config_at_pause':dict(saved,author='bob')}),{'pmm_active':True,'pmm_monitor_task_id':999,'pmm_monitor_generation':'new-owner','pmm':{}}]:
 sc.write_text(json.dumps(changed));winner=sc.read_bytes();r=lifecycle(bound_setup+block('pmm-pre-dispatch-tick-gate'));assert r.returncode!=0 and sc.read_bytes()==winner,(r.stdout,r.stderr)
# Also catch a change AFTER the early gate, before lifecycle claim.
sc.write_text(json.dumps(paused_state));resume_expected={'paused_at':paused,'config':saved}
resume_setup='NEW_MONITOR_GENERATION=resumed\nPMM_INTERNAL_TICK=false\nRESUMING_FROM_PAUSE=true\nPMM_RESUME_EXPECT='+shlex.quote(json.dumps(resume_expected))+'\nPMM_MONITOR_CONFIG={}\n'
changed=dict(paused_state,pmm_monitor_generation='newer',pmm_monitor_task_id=777);sc.write_text(json.dumps(changed));winner=sc.read_bytes()
r=lifecycle(resume_setup+claim);assert r.returncode!=0 and sc.read_bytes()==winner,(r.stdout,r.stderr)
sc.write_text(json.dumps(paused_state));r=lifecycle(resume_setup+claim+'\n'+authorize+'\nMONITOR_TASK_ID=555\nNEW_MONITOR_GENERATION=resumed\n'+armed+'\nEFFECTIVE_CADENCE=5m\nPMM_AUTHOR=alice\nIDLE_STREAK=8\n'+publication);assert r.returncode==0,(r.stdout,r.stderr)
d=json.loads(sc.read_text());assert d['pmm']['paused_at'] is None and d['pmm']['config_at_pause'] is None and d['pmm_idle_streak']==0 and d['pmm_rearm'] is None and d['pmm_monitor_task_id']==555
r=lifecycle('ARGUMENTS="--resume-paused-at= --resume-config-sha="\nPMM_PRE_DISPATCH_SH=x\n'+block('pmm-pre-dispatch-tick-gate'));assert r.returncode==2,(r.stdout,r.stderr)
print('PASS: actual bound wake entry and resume claim reject newer owner/config; successful claimed publication clears pause/digests atomically; malformed binding never becomes direct start')
# Execute resume capture/authorize/confirmed-clear in independent processes.
# Stop itself is a typed fake result; there is no live Claude tool on this host.
capture=re.search(r'<!-- test-anchor: pmm-resume-capture -->\s*```bash\n(.*?)\n```',skill_text,re.S).group(1)
stop_authorize=re.search(r'<!-- test-anchor: pmm-resume-stop-authorize -->\s*```bash\n(.*?)\n```',lifecycle_text,re.S).group(1)
stop_record=re.search(r'<!-- test-anchor: pmm-resume-stop-record -->\s*```bash\n(.*?)\n```',lifecycle_text,re.S).group(1)
sc.write_text(json.dumps({'pmm_active':False,'pmm_monitor_task_id':111,'pmm_monitor_generation':'old-main','pmm':{'paused_at':paused,'config_at_pause':saved,'auto_wake_monitor_task_id':222,'auto_wake_monitor_generation':'old-auto'}}))
r=lifecycle(capture);assert r.returncode==0,(r.stdout,r.stderr)
frozen=json.loads(next(x for x in r.stdout.splitlines() if x.startswith('PMM_RESUME_EXPECT=')).split('=',1)[1])
restore_stop='PMM_RESUME_EXPECT='+shlex.quote(json.dumps(frozen))+'\nPMM_RESUME_TASK_KIND=main\n'
r=lifecycle(restore_stop+stop_authorize);assert r.returncode==0 and 'TASK_ID=111' in r.stdout,(r.stdout,r.stderr)
frozen=json.loads(next(x for x in r.stdout.splitlines() if x.startswith('PMM_RESUME_EXPECT=')).split('=',1)[1])
restore_stop='PMM_RESUME_EXPECT='+shlex.quote(json.dumps(frozen))+'\nPMM_RESUME_TASK_KIND=main\n'
assert json.loads(sc.read_text())['pmm']['stop_requested'] is True
# Even if the day interlock marked active, a queued tick cannot treat a pause
# as a fresh resume or reach teardown.
r=lifecycle('PMM_INTERNAL_TICK=true\n'+capture);assert r.returncode==0 and 'Ignoring a queued' in r.stdout

original=sc.read_bytes();d=json.loads(original);d['pmm_monitor_task_id']=999;d['pmm_monitor_generation']='newer';sc.write_text(json.dumps(d));winner=sc.read_bytes()
r=lifecycle(restore_stop+stop_authorize);assert r.returncode!=0 and sc.read_bytes()==winner
r=lifecycle(restore_stop+'PMM_RESUME_STOP_REQUIRED=true\nPMM_RESUME_STOP_CONFIRMED=true\nPMM_CONFIRMED_STOP_TASK_ID=111\n'+stop_record);assert r.returncode!=0 and sc.read_bytes()==winner
sc.write_bytes(original)
r=lifecycle(restore_stop+'PMM_RESUME_STOP_REQUIRED=true\nPMM_RESUME_STOP_CONFIRMED=false\nPMM_CONFIRMED_STOP_TASK_ID=111\n'+stop_record);assert r.returncode!=0 and sc.read_bytes()==original
r=lifecycle(restore_stop+'PMM_RESUME_STOP_REQUIRED=true\nPMM_RESUME_STOP_CONFIRMED=true\nPMM_CONFIRMED_STOP_TASK_ID=999\n'+stop_record);assert r.returncode!=0 and sc.read_bytes()==original
r=lifecycle(restore_stop+'PMM_RESUME_STOP_REQUIRED=true\nPMM_RESUME_STOP_CONFIRMED=true\nPMM_CONFIRMED_STOP_TASK_ID=111\n'+stop_record);assert r.returncode==0,(r.stdout,r.stderr)
frozen=json.loads(next(x for x in r.stdout.splitlines() if x.startswith('PMM_RESUME_EXPECT=')).split('=',1)[1]);d=json.loads(sc.read_text());assert d['pmm_monitor_task_id'] is None and d['pmm']['auto_wake_monitor_task_id']==222 and d['pmm']['paused_at']==paused
r=lifecycle('PMM_RESUME_EXPECT='+shlex.quote(json.dumps(frozen))+'\nPMM_RESUME_TASK_KIND=auto\n'+stop_authorize+'\nPMM_RESUME_STOP_CONFIRMED=true\nPMM_CONFIRMED_STOP_TASK_ID=222\n'+stop_record);assert r.returncode==0,(r.stdout,r.stderr)
d=json.loads(sc.read_text());assert d['pmm']['auto_wake_monitor_task_id'] is None and d['pmm']['config_at_pause']==saved
print('PASS: separate-process resume teardown targets frozen IDs, rejects newer owner/wrong or uncertain tool results, and conditionally clears only confirmed old identities')


sc.write_text(json.dumps({'pmm_active':True,'pmm_monitor_task_id':555,'pmm_monitor_generation':'wake','pmm_pre_dispatch_version':2,'pmm_pre_dispatch_config':{'repo':'org/repo','author':'alice','base':'5m','max_deep':'7'},'pmm':{}}))
r=lifecycle('CONFIG='+shlex.quote(json.dumps(saved))+'\n'+wake_verify);assert r.returncode==0,(r.stdout,r.stderr)
d=json.loads(sc.read_text());d['pmm_pre_dispatch_config']['repo']='other/repo';sc.write_text(json.dumps(d));winner=sc.read_bytes()
r=lifecycle('CONFIG='+shlex.quote(json.dumps(saved))+'\n'+wake_verify);assert r.returncode!=0 and sc.read_bytes()==winner
print('PASS: actual pause/wake fences retain configured bound, delegate arming, verify canonical publication, and reject a different fleet without writes')

# Count actual deep-helper invocations at the configured default fleet limit.
countlog=tmp/'fleet-call-count';fleet_home=home('bounded-fleet');fleet_env=dict(env,HOME=str(fleet_home),FLEET_CALLS=str(countlog))
(live/'merge-gate.sh').write_text('#!/usr/bin/env bash\nprintf "gate %s\\n" "$1" >> "$FLEET_CALLS"\nprintf "%s" "$STUB_GATE_JSON"\n')
(live/'pr-state.sh').write_text('#!/usr/bin/env bash\nprintf "state %s\\n" "$2" >> "$FLEET_CALLS"\njq --argjson n "$2" \'.pr.number=$n\' "$STUB_BUNDLE_PATH"\n')
write_bundle()
fleet_env['STUB_PULLS_JSON']=json.dumps([{'number':n,'headRefOid':'abc123','url':f'https://github.com/org/repo/pull/{n}'} for n in range(1,26)])
r=run(e=fleet_env);assert r.returncode==0,(r.stdout,r.stderr)
fs=fleet_home/'.claude/session-state.json';d=json.loads(fs.read_text());fp=d['pmm_pre_dispatch']['pending_event'];assert len(d['pmm_pre_dispatch']['snapshot']['data']['prs'])==25
assert len(countlog.read_text().splitlines())==50
fleet_env['STUB_PULLS_JSON']=json.dumps([{'number':n,'headRefOid':'abc123','url':f'https://github.com/org/repo/pull/{n}'} for n in range(1,501)])
r=run(e=fleet_env);assert json.loads(fs.read_text())['pmm_pre_dispatch']['pending_event']==fp and len(countlog.read_text().splitlines())==50
assert run([str(live/'pmm-pre-dispatch.sh'),'--ack',fp['event_id']],e=fleet_env).returncode==0
prior=json.loads(fs.read_text())['pmm_pre_dispatch']['snapshot'];r=run(e=fleet_env);d=json.loads(fs.read_text())
assert r.returncode==5 and d['pmm_pre_dispatch']['snapshot']==prior and d['pmm_pre_dispatch']['pending_event']['diagnostic'] and len(countlog.read_text().splitlines())==50
fleet_env['HOME']=str(home('small-bound'));small=argv+['--max-deep-prs','2'];r=run(small,e=fleet_env);assert r.returncode==5 and len(countlog.read_text().splitlines())==50
print('PASS: default25 fleet executes50 helper calls;500 discovery and smaller configured bound perform zero deep polls, retain prior snapshot/pending evidence, and diagnose')
# Boundary proof without issuing 1000 fake deep fetches: exactly500 passes the
# production preflight and enters the first injected-failure helper.501 must
# stop before every deep helper, even with max-deep-prs500.
cap_records=[{'number':n,'headRefOid':'abc123','url':f'https://github.com/org/repo/pull/{n}','mergeStateStatus':'CLEAN'} for n in range(1,502)]
cap_calls=tmp/'sentinel-helper-calls';cap_calls.write_text('')
cap_gate_path=live/'merge-gate.sh';cap_gate_saved=cap_gate_path.read_text()
cap_gate_path.write_text('#!/usr/bin/env bash\nprintf "gate %s\\n" "$1" >> "$FLEET_CALLS"\nexit 4\n')
cap500_home=home('exact500-preflight');cap500_env=dict(env,HOME=str(cap500_home),FLEET_CALLS=str(cap_calls),STUB_PULLS_JSON=json.dumps(cap_records[:500]))
cap_args=argv+['--max-deep-prs','500']
r=run(cap_args,e=cap500_env);cap500_data=json.loads((cap500_home/'.claude/session-state.json').read_text())
assert r.returncode==5 and cap_calls.read_text().splitlines()==['gate 1'] and cap500_data['pmm_pre_dispatch']['last_error'].startswith('merge-gate unavailable'),(r.stdout,r.stderr,cap500_data)
cap_calls.write_text('');cap_home=home('overflow501');cap_env=dict(env,HOME=str(cap_home),FLEET_CALLS=str(cap_calls),STUB_PULLS_JSON=json.dumps(cap_records))
cap_snapshot=tmp/'prior-known501.json';cap_snapshot.write_text(json.dumps({'repo':'org/repo','author':'alice','collected_at':now(),'prs':[dict(number=501,url=cap_records[-1]['url'],gate=real_gate,findings=[])],'evidence':[{'pr':501,'source':'prior-confirmed'}],'orchestration':{'active_agents':{},'pmm_in_flight':{},'merge_holds':{}}}))
r=run(argv+['--fixture',str(cap_snapshot)],e=cap_env);assert r.returncode==0,(r.stdout,r.stderr)
cap_state=cap_home/'.claude/session-state.json';cap_data=json.loads(cap_state.read_text());cap_pending=cap_data['pmm_pre_dispatch']['pending_event'];cap_previous=cap_data['pmm_pre_dispatch']['snapshot']
# Negative control models the real CLI: an old limit500 response omits the
# previously known still-open501st PR and cannot establish that it closed.
cap_truncated=subprocess.run(['gh','pr','list','--limit','500'],env=cap_env,text=True,capture_output=True);assert cap_truncated.returncode==0
assert len(json.loads(cap_truncated.stdout))==500 and 501 not in [x['number'] for x in json.loads(cap_truncated.stdout)]
r=run(cap_args,e=cap_env);cap_data=json.loads(cap_state.read_text())
assert r.returncode==0 and cap_data['pmm_pre_dispatch']['pending_event']==cap_pending and cap_data['pmm_pre_dispatch']['snapshot']==cap_previous and cap_calls.read_text()==''
assert run([str(live/'pmm-pre-dispatch.sh'),'--ack',cap_pending['event_id']],e=cap_env).returncode==0
r=run(cap_args,e=cap_env);cap_data=json.loads(cap_state.read_text());cap_diag=cap_data['pmm_pre_dispatch']['pending_event']
assert r.returncode==5 and cap_diag['diagnostic'] and 'at least 501' in cap_diag['reason'] and cap_calls.read_text()==''
assert cap_data['pmm_pre_dispatch']['snapshot']==cap_previous and cap_data['pmm_pre_dispatch']['snapshot']['data']['prs'][0]['number']==501 and 'delta' not in cap_diag
cap_gate_path.write_text(cap_gate_saved)
print('PASS: exactly500 enters deep preflight;501 sentinel preserves pending/prior known omitted501 and diagnoses before all helpers/snapshot pruning')

# Execute the other two production discovery fences against the same CLI-limit
# stub: the normal main entry and paused wake scan also refuse partial fleets.
cap_main=re.search(r'<!-- test-anchor: pmm-discovery-cap -->\s*```bash\n(.*?)\n```',skill_text,re.S).group(1)
cap_main_prefix='PMM_AUTHOR=alice\nREPO_FLAG=(--repo org/repo)\n'
cap_main500=subprocess.run(['bash','-c',cap_main_prefix+cap_main+'\nprintf "COUNT=%s" "$PR_COUNT"'],env=cap500_env,text=True,capture_output=True)
assert cap_main500.returncode==0 and cap_main500.stdout=='COUNT=500',(cap_main500.stdout,cap_main500.stderr)
cap_before=cap_state.read_bytes();cap_main501=subprocess.run(['bash','-c',cap_main_prefix+cap_main],env=cap_env,text=True,capture_output=True)
assert cap_main501.returncode!=0 and 'at least 501' in cap_main501.stderr and cap_state.read_bytes()==cap_before
cap_wake_scan=re.search(r'<!-- test-anchor: pmm-wake-step-4a-scan -->\s*```bash\n(.*?)\n```',wake_text,re.S).group(1)
cap_wake_compare=re.search(r'<!-- test-anchor: pmm-wake-step-4a-compare -->\s*```bash\n(.*?)\n```',wake_text,re.S).group(1)
cap_wake_home=home('sentinel-paused-wake');cap_wake_file=cap_wake_home/'.claude/session-state.json'
cap_wake_saved=[{'pr':x['number'],'head_sha':x['headRefOid'],'state':'CLEAN'} for x in cap_records[:500]]
cap_wake_file.write_text(json.dumps({'pmm':{'paused_at':now(),'config_at_pause':{'author':'alice','repo':'org/repo'},'fleet_at_pause':cap_wake_saved}}))
cap_wake_env=dict(cap500_env,HOME=str(cap_wake_home));cap_before=cap_wake_file.read_bytes()
cap_wake_prefix='SESSION_STATE_SH='+shlex.quote(str(real_state))+'\n'
cap_wr=subprocess.run(['bash','-c',cap_wake_prefix+cap_wake_scan+'\n'+cap_wake_compare],env=cap_wake_env,text=True,capture_output=True)
assert cap_wr.returncode==0 and 'Fleet unchanged' in cap_wr.stdout and cap_wake_file.read_bytes()==cap_before,(cap_wr.stdout,cap_wr.stderr)
cap_wr=subprocess.run(['bash','-c',cap_wake_prefix+cap_wake_scan+'\n'+cap_wake_compare],env=dict(cap_wake_env,STUB_PULLS_JSON=json.dumps(cap_records)),text=True,capture_output=True)
assert cap_wr.returncode!=0 and 'at least 501' in cap_wr.stderr and cap_wake_file.read_bytes()==cap_before,(cap_wr.stdout,cap_wr.stderr)
print('PASS: actual main and paused-wake fences accept complete500, reject501 high-water, and preserve state instead of treating omitted members as closed')
cap_jq_dir=tmp/'cap-count-fault';cap_jq_dir.mkdir();cap_jq=cap_jq_dir/'jq'
cap_jq.write_text('#!/usr/bin/env bash\n[[ "${1:-}" != length ]] || exit 7\nexec '+shlex.quote(shutil.which('jq'))+' "$@"\n');cap_jq.chmod(0o755)
cap_fault_env=dict(cap500_env,PATH=str(cap_jq_dir)+':'+cap500_env['PATH'])
cap_mr=subprocess.run(['bash','-c',cap_main_prefix+cap_main],env=cap_fault_env,text=True,capture_output=True)
assert cap_mr.returncode!=0 and 'fleet count failed' in cap_mr.stderr,(cap_mr.stdout,cap_mr.stderr)
cap_before=cap_wake_file.read_bytes()
cap_wr=subprocess.run(['bash','-c',cap_wake_prefix+cap_wake_scan+'\n'+cap_wake_compare],env=dict(cap_wake_env,PATH=str(cap_jq_dir)+':'+cap_wake_env['PATH']),text=True,capture_output=True)
assert cap_wr.returncode!=0 and 'could not count' in cap_wr.stderr and cap_wake_file.read_bytes()==cap_before,(cap_wr.stdout,cap_wr.stderr)
print('PASS: failed main/wake sentinel count computation cannot be mistaken for a complete fleet')


# Raw history exceeds this host's argv limit, multiplied across the default25
# fleet. Complete IDs/bodies stay on stdin; persisted/model-visible state remains
# fixed-size samples + per-PR aggregate hashes/counts, including unsampled edits.
stress_home=home('large-review-fleet');stress_env=dict(fleet_env,HOME=str(stress_home))
stress_env['STUB_PULLS_JSON']=json.dumps([{'number':n,'headRefOid':'abc123','url':f'https://github.com/org/repo/pull/{n}'} for n in range(1,26)])
long_path='/'.join(['fixture']*180)
stress_comments=[dict(comment,id=10000+i,body='Minor fix',path=long_path) for i in range(2000)]
write_bundle(stress_comments);raw_size=bundle.stat().st_size;assert raw_size>os.sysconf('SC_ARG_MAX'),raw_size
r=run(e=stress_env);assert r.returncode==0 and 'Argument list too long' not in r.stderr,(r.stdout,r.stderr)
stress_file=stress_home/'.claude/session-state.json';sd=json.loads(stress_file.read_text());sp=sd['pmm_pre_dispatch']['pending_event'];sr=sd['pmm_pre_dispatch']['snapshot']['data']['prs']
assert len(sr)==25 and all(x['finding_count']==2000 and len(x['findings'])==3 and len(x['finding_fingerprint'])==64 for x in sr)
assert len(json.dumps(sp).encode())<os.sysconf('SC_ARG_MAX')//4 and stress_file.stat().st_size<os.sysconf('SC_ARG_MAX')//2
assert run([str(live/'pmm-pre-dispatch.sh'),'--ack',sp['event_id']],e=stress_env).returncode==0
stress_comments[0]['body']='Minor edited finding outside every retained ID sample';write_bundle(stress_comments)
r=run(e=stress_env);assert r.returncode==0,(r.stdout,r.stderr)
sd=json.loads(stress_file.read_text());sp=sd['pmm_pre_dispatch']['pending_event'];assert not sp['delta']['changed'] and len(sp['delta']['new_findings'])==25 and all(x['item']['endpoint']=='aggregate' and x['requires_source_recovery'] for x in sp['delta']['new_findings'])
assert len(json.dumps(sp).encode())<os.sysconf('SC_ARG_MAX')//4 and stress_file.stat().st_size<os.sysconf('SC_ARG_MAX')//2
print('PASS:25x2000 comments (raw per-PR bytes='+str(raw_size)+') exceed ARG_MAX without E2BIG; bounded persisted packets and aggregate changes detect unsampled edits on all25PRs')


PYTEST

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
