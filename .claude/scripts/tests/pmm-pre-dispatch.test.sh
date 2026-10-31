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
printf '%s\n' "$STUB_BUNDLE_PATH"
SH
cat > "$BIN/gh" <<'SH'
#!/usr/bin/env bash
if [[ "$1 $2" == "pr list" ]]; then
  [[ -z "${GH_ARGS_PATH:-}" ]] || printf '%s\n' "$@" > "$GH_ARGS_PATH"
  printf '%s\n' "$STUB_PULLS_JSON"
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
check "production fleet discovery requests the skill's 500-PR cap" '[[ "$(grep -Fxc -- "--limit" "$GH_ARGS_PATH")" == 1 && "$(tail -n 1 "$GH_ARGS_PATH")" == 500 ]]'
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
assert 'second null' not in json.dumps(read()['pmm_pre_dispatch']['snapshot']),'full bodies leaked into compact state'
print('PASS: real collector detects new and edited findings with stable gate and endpoint identity')
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
r=skill_run('PMM_DISPATCH_EVENT='+eid+'\n'+block('pmm-pre-dispatch-actions-receipt'));assert r.returncode==0,r.stderr
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
step4_script='FLEET_TUPLE_SORTED=$(jq -cS \'[.prs[] | [.number,.gate.head_sha,.gate.merge_state,.gate.review_decision,.gate.ci_status.failing,.gate.unresolved_thread_count]] | sort_by(.[0])\' "$STEP4_SNAPSHOT")\nDIGEST=$(printf "%s" "$FLEET_TUPLE_SORTED" | shasum -a 256 | awk \'{print $1}\')\nPREV="$DIGEST"\nROW_DIGEST=step4-row\nPMM_CADENCE=5m\nPMM_INTERNAL_TICK=true\nTICK_HAD_ACTION=false\nSEQ=""\n'+block('pmm-pre-dispatch-backoff')+'\n'+block('pmm-pre-dispatch-idle')+'\nprintf "%s|%s|%s" "$STREAK" "$IDLE_STREAK" "$EFFECTIVE_CADENCE"'
step4_code='SESSION_STATE_SH='+shlex.quote(str(live/'session-state.sh'))+'\nSTEP4_SNAPSHOT='+shlex.quote(str(tmp/'base.json'))+'\n'+step4_script
r=subprocess.run(['bash','-eu','-c',step4_code],env=step4_env,text=True,capture_output=True);assert r.returncode==0 and r.stdout=='1|1|5m',(r.stdout,r.stderr)
quiet=run(e=step4_env);assert quiet.returncode==0 and quiet.stdout=='',(quiet.stdout,quiet.stderr,step4_state.read_text())
print('PASS: Step 4 fleet digest plus actual Step 6 blocks persists the baseline and the following collector tick is quiet')
# Actions-receipt replay must restore completed Step 6 state without advancing
# either counter or changing the cadence a second time.
step4_data=json.loads(step4_state.read_text());step4_data.update(pmm_digest_streak=4,pmm_idle_streak=7,pmm_cadence='15m');step4_state.write_text(json.dumps(step4_data))
replay_code='SESSION_STATE_SH='+shlex.quote(str(live/'session-state.sh'))+'\nPMM_SKIP_ACTIONS=true\nPMM_INTERNAL_TICK=true\nDIGEST=changed\nPREV=old\nROW_DIGEST=changed-row\nPMM_CADENCE=5m\nTICK_HAD_ACTION=false\nSEQ=""\n'+block('pmm-pre-dispatch-backoff')+'\n'+block('pmm-pre-dispatch-idle')+'\nprintf "%s|%s|%s" "$STREAK" "$IDLE_STREAK" "$EFFECTIVE_CADENCE"'
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

# Inject real production Step6/Step7 schedule publication AFTER the collector's
# coherent read, immediately before its CAS. First race changes ROOT ONLY so the
# old gate-only CAS would overwrite it. Second race also publishes an outbox.
skill_text=(root/'.claude/skills/pr-monitor-and-manage/SKILL.md').read_text()
backoff=re.search(r'<!-- test-anchor: pmm-pre-dispatch-backoff -->\s*```bash\n(.*?)\n```',skill_text,re.S).group(1)
publication=next(b for b in re.findall(r'```bash\n(.*?)\n```',skill_text,re.S) if b.startswith('NOW=$(date -u +%FT%TZ)') and 'pmm_pre_dispatch_version' in b)
for outbox_race in (False,True):
 hf=home('schedule-race-'+str(outbox_race));ef=dict(env,HOME=str(hf));write_bundle()
 r=run(e=ef);initial=json.loads((hf/'.claude/session-state.json').read_text())['pmm_pre_dispatch']['pending_event']
 run([str(live/'pmm-pre-dispatch.sh'),'--ack',initial['event_id']],e=ef)
 sf=hf/'.claude/session-state.json';d=json.loads(sf.read_text());d['pmm_digest']=hashlib.sha256(subprocess.check_output(['jq','-cnS','[[7,"abc123","CLEAN","REVIEW_REQUIRED",0,0]]']).rstrip(b'\n')).hexdigest();d['pmm_digest_streak']=0;d['pmm_idle_streak']=0;sf.write_text(json.dumps(d))
 before_gate=d['pmm_pre_dispatch'];writer=tmp/('schedule-writer-'+str(outbox_race)+'.sh');winner=tmp/('schedule-winner-'+str(outbox_race)+'.json');once=tmp/('schedule-once-'+str(outbox_race))
 setup='set -eu\nSESSION_STATE_SH='+shlex.quote(str(real_state))+'\nPMM_INTERNAL_TICK=true\nDIGEST=owner-digest\nPREV=old-digest\nROW_DIGEST=owner-row\nPMM_CADENCE=10m\n'
 setup+=backoff+'\nIDLE_STREAK=17\nEFFECTIVE_CADENCE=30m\nMONITOR_TASK_ID=77\nMONITOR_GENERATION=gen-live\nPMM_MONITOR_CONFIG={}\nPMM_AUTHOR=alice\n'+publication+'\n'
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
 assert after['pmm_digest']=='owner-digest' and after['pmm_row_digest']=='owner-row' and after['pmm_cadence']=='30m' and after['pmm_idle_streak']==17 and after['pmm_next_expected_tick_at']=='2099-01-01T00:00:00Z'
 if not outbox_race: assert after['pmm_pre_dispatch']==before_gate
 else: assert after['pmm_pre_dispatch']['pending_event']['event_id']=='c'*64 and after['pmm_pre_dispatch']['actions_completed_event_id']=='owner-actions'
 shutil.copy2(real_state,state_helper)
 if not outbox_race:
  r=run(e=ef);fresh=json.loads(sf.read_text())['pmm_pre_dispatch']['pending_event']
  assert r.returncode==0 and 'state_digest' in fresh['reasons'],(r.stdout,r.stderr,fresh)
  # Fresh owner processing (actual Step6) aligns the changed digest, then ack.
  fresh_digest=hashlib.sha256(subprocess.check_output(['jq','-cnS','[[7,"abc123","CLEAN","REVIEW_REQUIRED",0,0]]']).rstrip(b'\n')).hexdigest()
  fresh_owner='set -eu\nSESSION_STATE_SH='+shlex.quote(str(real_state))+'\nPMM_INTERNAL_TICK=true\nPMM_CADENCE=30m\nDIGEST='+fresh_digest+'\nPREV=owner-digest\nROW_DIGEST=fresh-row\n'+backoff
  subprocess.run(['bash','-c',fresh_owner],env=ef,check=True,capture_output=True,text=True)
  assert run([str(live/'pmm-pre-dispatch.sh'),'--ack',fresh['event_id']],e=ef).returncode==0
  r=run(e=ef);assert r.returncode==0 and r.stdout=='',(r.stdout,r.stderr)
print('PASS: real production schedule-writer race preserves whole winning transaction and outbox; stale diagnostic cannot write; fresh quiet retry is silent')

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


PYTEST

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
