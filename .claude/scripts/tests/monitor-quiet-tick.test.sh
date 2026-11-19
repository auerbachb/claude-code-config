#!/usr/bin/env bash
# Tests for monitor-quiet-tick.sh and its wiring into the /babysit-pr and /pm day Monitors (issue #2459).
# catalog: tests — Unchanged Monitor tick is silent with counters advanced shell-side; change, cadence widen, streak-9 pause and N-blocker terminal emit on the same tick as before
# covers: .claude/scripts/monitor-quiet-tick.sh
#
# Drives the real script against a real session-state.sh in a throwaway $HOME.
# Ticks pass --input-digest so no GitHub call is made; the digest projection is
# exercised separately with stub merge-gate.sh / pr-state.sh / gh siblings.
# The Monitor loops are the real fenced bash pulled from the skills by anchor.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
GATE="$ROOT/.claude/scripts/monitor-quiet-tick.sh"
REAL_STATE="$ROOT/.claude/scripts/session-state.sh"
# shellcheck source=lib/skill-bash.sh
source "$ROOT/.claude/scripts/tests/lib/skill-bash.sh"
[[ -x "$GATE" ]] || { echo "FAIL: $GATE not executable" >&2; exit 1; }
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
mkdir -p "$HOME/.claude"
export MONITOR_QUIET_STATE_HELPER="$REAL_STATE"
STATE="$HOME/.claude/session-state.json"
REPO="acme/widgets"
PASS=0
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }

# tick ARGS... — runs a babysit tick; sets RC and OUT (stdout must always be empty in tick mode).
tick() {
  set +e; OUT=$("$GATE" "$@" 2>"$TMP/err"); RC=$?; set -e
  [[ -z "$OUT" ]] || fail "tick mode printed to stdout: $OUT"
}
bget() { jq -r --arg r "$REPO" "$1" "$STATE"; }
B='.repos[$r].prs["7"]'
D='.repos[$r].day'

seed_babysit() { # streak eff blocker counting freeze tick_count [extra-jq]
  local streak="$1" eff="$2" blocker="$3" counting="$4" freeze="$5" tc="$6" extra="${7:-.}"
  jq -n --arg r "$REPO" --argjson s "$streak" --argjson e "$eff" --argjson b "$blocker" \
    --argjson c "$counting" --argjson f "$freeze" --argjson tc "$tc" '
    {schema_version: 2, repos: {($r): {prs: {"7": {
      digest: "sha256:model", digest_streak: $s,
      babysit: {active: true, stop_requested: false, cadence_transition: false,
        monitor_generation: "g1", monitor_task_id: "t1", dispatch_in_flight: null,
        cadence_base_minutes: 5, cadence_effective_minutes: $e, tick_count: $tc,
        blocker_streak: $b, max_blocker_ticks: 6, last_tick_at: "2026-01-01T00:00:00Z",
        quiet: {input_digest: "D1", quiet_ok: true, tick_count: $tc, widen_at: 3,
                freeze_at: $f, blocker_counting: $c, quiet_ticks: 0}}}}}}}' | jq "$extra" > "$STATE"
}
seed_day() { # streak eff tick_count
  jq -n --arg r "$REPO" --argjson s "$1" --argjson e "$2" --argjson tc "$3" '
    {schema_version: 2, repos: {($r): {day: {
      active: true, stop_requested: false, monitor_generation: "d1", monitor_task_id: "t9",
      cadence_base_minutes: 5, cadence_effective_minutes: $e, tick_count: $tc,
      digest: "sha256:board", digest_streak: $s, paused_at: null, parked_until: null,
      last_tick_at: "2026-01-01T00:00:00Z",
      quiet: {input_digest: "P1", quiet_ok: true, tick_count: $tc, widen_at: 3,
              freeze_at: 9, blocker_counting: false, quiet_ticks: 0}}}}}' > "$STATE"
}
BT=(--kind babysit --pr 7 --repo "$REPO" --generation g1)
DT=(--kind pm-day --repo "$REPO" --generation d1)

# 1. Unchanged digest: silent, and the counters advance exactly as a model tick would.
seed_babysit 1 5 0 false null 1
tick "${BT[@]}" --input-digest D1
[[ $RC -eq 10 ]] || fail "unchanged tick should be quiet (rc=$RC: $(cat "$TMP/err"))"
[[ "$(bget "$B.digest_streak")" == 2 && "$(bget "$B.babysit.tick_count")" == 2 && "$(bget "$B.babysit.quiet.tick_count")" == 2 ]] ||
  fail "quiet tick did not advance streak/tick_count"
[[ "$(bget "$B.babysit.last_tick_at")" != "2026-01-01T00:00:00Z" ]] || fail "quiet tick did not refresh last_tick_at (watchdog liveness)"
[[ "$(bget "$B.digest")" == "sha256:model" && "$(bget "$B.babysit.blocker_streak")" == 0 ]] || fail "quiet tick touched the model digest or a non-counting blocker streak"
pass "unchanged tick emits nothing and advances digest_streak, tick_count, last_tick_at"

# 2. A changed digest emits once, moves no counter, and disarms the contract so a tick that
#    lands while the model is still handling the event wakes it again instead of going quiet.
counters() { bget "[$B.digest_streak, $B.babysit.tick_count, $B.babysit.blocker_streak, $B.babysit.last_tick_at] | @csv"; }
seed_babysit 1 5 0 false null 1
before=$(counters)
tick "${BT[@]}" --input-digest D2
[[ $RC -eq 0 ]] || fail "changed digest should emit (rc=$RC)"
[[ "$(counters)" == "$before" ]] || fail "emit path moved a counter"
[[ "$(bget "$B.babysit.quiet.quiet_ok")" == false && "$(bget "$B.babysit.quiet.disarmed_reason")" == "input digest changed" ]] ||
  fail "emit did not disarm the contract: $(bget "$B.babysit.quiet") err=$(cat "$TMP/err")"
tick "${BT[@]}" --input-digest D1
[[ $RC -eq 0 && "$(counters)" == "$before" ]] || fail "a disarmed contract must keep emitting until the model re-records"
pass "changed digest emits, moves no counter, and disarms until the model re-records"

# 3. Cadence widen: the tick reaching streak 3 is emitted (model widens + re-arms), not absorbed.
seed_babysit 1 5 0 false null 1
tick "${BT[@]}" --input-digest D1; [[ $RC -eq 10 ]] || fail "streak 1->2 should be quiet"
tick "${BT[@]}" --input-digest D1
[[ $RC -eq 0 ]] || fail "streak 2->3 must emit so the model widens the cadence (rc=$RC)"
[[ "$(bget "$B.digest_streak")" == 2 ]] || fail "threshold tick advanced the streak itself"
grep -q threshold-cadence "$TMP/err" || fail "widen emit reason missing"
pass "the widen-at-3 tick emits on the same tick a model tick would have widened"

# 4. waiting-on-bots (freeze none, already widened) stays quiet past streak 9, like T6 keeps the wait.
seed_babysit 3 15 0 false null 3
for _ in 1 2 3 4 5 6 7 8; do tick "${BT[@]}" --input-digest D1; [[ $RC -eq 10 ]] || fail "widened wait should stay quiet (rc=$RC)"; done
[[ "$(bget "$B.digest_streak")" == 11 ]] || fail "streak should be 11 after 8 quiet ticks"
pass "a widened pending-review wait stays quiet past streak 9, as T6 keeps its Monitor"

# 5. N-blocker terminal: a counting contract emits exactly on the tick blocker_streak would reach max.
#    Old behaviour: blocker 4 -> 5 (tick 1) -> 6 = cap (tick 2). New: tick 1 quiet, tick 2 emits.
seed_babysit 4 15 4 true 9 4
tick "${BT[@]}" --input-digest D1
[[ $RC -eq 10 && "$(bget "$B.babysit.blocker_streak")" == 5 ]] || fail "blocker 4->5 should be quiet and counted"
tick "${BT[@]}" --input-digest D1
[[ $RC -eq 0 ]] || fail "blocker 5->6 must emit for blocker-tick-cap (rc=$RC)"
grep -q threshold-blocker-cap "$TMP/err" || fail "blocker cap emit reason missing"
[[ "$(bget "$B.babysit.blocker_streak")" == 5 ]] || fail "cap tick advanced blocker_streak itself"
pass "N-blocker terminal tick emits on the same tick as before, counter left to the model"

# 6. pm day streak-9 pause: tick to 8 is quiet, the tick that reaches 9 emits.
seed_day 7 15 7
tick "${DT[@]}" --input-digest P1
[[ $RC -eq 10 && "$(bget "$D.digest_streak")" == 8 && "$(bget "$D.tick_count")" == 8 ]] || fail "pm day 7->8 should be quiet (rc=$RC)"
tick "${DT[@]}" --input-digest P1
[[ $RC -eq 0 ]] || fail "pm day 8->9 must emit for stable-frozen (rc=$RC)"
grep -q threshold-freeze "$TMP/err" || fail "freeze emit reason missing"
pass "pm day streak-9 stable-frozen tick emits on the same tick as before"

# 7. pm day cadence widen and change.
seed_day 1 5 1
tick "${DT[@]}" --input-digest P1; [[ $RC -eq 10 ]] || fail "pm day 1->2 should be quiet"
tick "${DT[@]}" --input-digest P1; [[ $RC -eq 0 ]] || fail "pm day 2->3 must emit (widen)"
seed_day 4 15 4
tick "${DT[@]}" --input-digest P2; [[ $RC -eq 0 ]] || fail "pm day changed digest must emit"
pass "pm day widen and change both emit"

# 8. Every guard fails toward emitting.
check_emits() { # label jq-mutation
  seed_babysit 1 5 0 false null 1 "$2"
  local before; before=$(cat "$STATE")
  tick "${BT[@]}" --input-digest D1
  [[ $RC -ne 10 ]] || fail "$1 should emit"
  [[ "$(cat "$STATE")" == "$before" ]] || fail "$1 wrote state"
}
P='.repos["acme/widgets"].prs["7"]'
check_emits "stale generation" "$P.babysit.monitor_generation = \"g0\""
check_emits "stop requested" "$P.babysit.stop_requested = true"
check_emits "inactive watcher" "$P.babysit.active = false"
check_emits "cadence transition" "$P.babysit.cadence_transition = true"
check_emits "dispatch in flight" "$P.babysit.dispatch_in_flight = {started_at: \"x\"}"
check_emits "quiet_ok false" "$P.babysit.quiet.quiet_ok = false"
check_emits "stale contract" "$P.babysit.tick_count = 2"
check_emits "missing contract" "del($P.babysit.quiet)"
check_emits "unreadable streak" "$P.digest_streak = \"x\""
check_emits "unreadable cadence" "del($P.babysit.cadence_effective_minutes)"
seed_day 1 5 1; jq '.repos["acme/widgets"].day.parked_until = "2026-01-01T05:00:00Z"' "$STATE" > "$TMP/s" && mv "$TMP/s" "$STATE"
tick "${DT[@]}" --input-digest P1; [[ $RC -ne 10 ]] || fail "parked day should emit"
printf '{not json' > "$STATE"
tick "${BT[@]}" --input-digest D1; [[ $RC -ne 10 ]] || fail "corrupt state should emit"
rm -f "$STATE"
tick "${BT[@]}" --input-digest D1; [[ $RC -ne 10 ]] || fail "missing state file should emit"
# A lost compare-and-set emits rather than claiming a quiet tick it did not record.
cat > "$TMP/cas-fails.sh" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do [[ "\$a" == --cas ]] && exit 7; done
exec "$REAL_STATE" "\$@"
EOF
chmod +x "$TMP/cas-fails.sh"
seed_babysit 1 5 0 false null 1
before=$(cat "$STATE")
set +e; OUT=$(MONITOR_QUIET_STATE_HELPER="$TMP/cas-fails.sh" "$GATE" "${BT[@]}" --input-digest D1 2>/dev/null); RC=$?; set -e
[[ $RC -eq 0 && -z "$OUT" && "$(cat "$STATE")" == "$before" ]] || fail "lost CAS should emit with state unchanged (rc=$RC)"
pass "stale generation, stop, transition, in-flight dispatch, stale/missing contract, park, corrupt state and lost CAS all emit"

# 9. Record mode writes the contract against the current tick_count.
seed_babysit 1 5 0 false null 2 "del($P.babysit.quiet)"
"$GATE" --record --kind babysit --pr 7 --repo "$REPO" --quiet-ok true --freeze-at none --input-digest D9 2>/dev/null ||
  fail "record should succeed"
[[ "$(bget "$B.babysit.quiet | [.input_digest, .quiet_ok, .tick_count, .widen_at, .freeze_at, .blocker_counting] | @csv")" == '"D9",true,2,3,,false' ]] ||
  fail "record contract wrong: $(bget "$B.babysit.quiet")"
tick "${BT[@]}" --input-digest D9; [[ $RC -eq 10 ]] || fail "freshly recorded contract should allow a quiet tick"
"$GATE" --record --kind babysit --pr 7 --repo "$REPO" --quiet-ok false 2>/dev/null || fail "record false should succeed"
tick "${BT[@]}" --input-digest D9; [[ $RC -eq 0 ]] || fail "quiet_ok=false contract must emit"
seed_day 0 5 3
"$GATE" --record --kind pm-day --repo "$REPO" --quiet-ok true --input-digest P5 2>/dev/null || fail "pm day record should succeed"
[[ "$(bget "$D.quiet | [.tick_count, .freeze_at] | @csv")" == '3,9' ]] || fail "pm day contract wrong"
set +e; "$GATE" --record --kind pm-day --repo "$REPO" --quiet-ok maybe 2>/dev/null; rc=$?; set -e
[[ $rc -eq 2 ]] || fail "bad --quiet-ok should be a usage error"
pass "record mode stores the contract at the current tick_count; quiet_ok=false disables quiet"

# 10. Input digest projection (stub siblings): stable for unchanged input, ignores clock text, sensitive to state.
BIN="$TMP/bin"; mkdir -p "$BIN" "$TMP/path"
cp "$GATE" "$BIN/monitor-quiet-tick.sh"
cat > "$BIN/merge-gate.sh" <<'EOF'
#!/usr/bin/env bash
cat "$GATE_FIXTURE"; exit "${GATE_RC:-1}"
EOF
cat > "$BIN/pr-state.sh" <<'EOF'
#!/usr/bin/env bash
cat "$BUNDLE_FIXTURE"
EOF
cat > "$TMP/path/gh" <<'EOF'
#!/usr/bin/env bash
if [[ "$1 $2" == "repo view" ]]; then echo "${CWD_REPO:-Acme/Widgets}"; exit 0; fi
echo "2026-01-01T00:00:00Z"
EOF
chmod +x "$BIN"/*.sh "$TMP/path/gh"
export GATE_FIXTURE="$TMP/gate.json" BUNDLE_FIXTURE="$TMP/bundle.json"
mkgate() { jq -n --arg reason "$1" --arg miss "$2" '{head_sha:"abc", met:false, merge_state:"BLOCKED", mergeable:"MERGEABLE",
  human_changes_requested:[], ci_status:{failing:0,in_progress:1,blocking:[]}, missing:[$miss],
  no_review_override:{reason:"window_running", pending_reason:$reason}}' > "$GATE_FIXTURE"; }
printf '%s' '{"threads":{"unresolved_count":0},"bot_statuses":{"CodeRabbit":{"state":"pending"}},"check_runs":{"all":[{"name":"ci","status":"in_progress"}]}}' > "$BUNDLE_FIXTURE"
dig() { PATH="$TMP/path:$PATH" "$BIN/monitor-quiet-tick.sh" --print-digest --kind babysit --pr 7 --repo "$REPO" 2>/dev/null; }
mkgate "7 minutes left" "CI has 1 incomplete check-run(s): ci"; d1=$(dig)
mkgate "6 minutes left" "CI has 1 incomplete check-run(s): ci"; d2=$(dig)
[[ "$d1" == sha256:* && "$d1" == "$d2" ]] || fail "digest must ignore clock-derived pending text ($d1 vs $d2)"
mkgate "6 minutes left" "need 1 explicit CodeRabbit or CodeAnt APPROVED review"; d3=$(dig)
[[ "$d3" != "$d1" ]] || fail "digest must change when the gate's blockers change"
set +e; GATE_RC=4 dig >/dev/null; rc=$?; set -e
[[ $rc -eq 1 ]] || fail "a merge-gate tooling failure must not yield a digest (rc=$rc)"
d4=$(GATE_RC=3 dig); [[ "$d4" == sha256:* && "$d4" != "$d3" ]] || fail "a closed/merged PR must change the digest"
: > "$GATE_FIXTURE"
set +e; dig >/dev/null; rc=$?; set -e
[[ $rc -eq 1 ]] || fail "an empty merge-gate read must not project to a constant digest (rc=$rc)"
mkgate "6 minutes left" "x"
set +e; CWD_REPO=other/repo dig >/dev/null; rc=$?; set -e
[[ $rc -eq 1 ]] || fail "--repo naming another repository than the working directory must fail the read (rc=$rc)"
pass "input digest is stable, clock-free, state-sensitive, and fails closed on tooling, empty and wrong-repo reads"

# 11. The real Monitor loops: quiet exits print nothing; emits, failures and deadline ticks print the line.
mkdir -p "$HOME/.claude/scripts"
cat > "$HOME/.claude/scripts/monitor-quiet-tick.sh" <<'EOF'
#!/usr/bin/env bash
n=$(cat "$QUIET_SEQ_FILE.n" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$QUIET_SEQ_FILE.n"
echo "$*" >> "$QUIET_SEQ_FILE.args"
exit "$(sed -n "${n}p" "$QUIET_SEQ_FILE")"
EOF
chmod +x "$HOME/.claude/scripts/monitor-quiet-tick.sh"
export QUIET_SEQ_FILE="$TMP/seq"
printf '10\n0\n10\n3\n' > "$QUIET_SEQ_FILE"; rm -f "$QUIET_SEQ_FILE.n" "$QUIET_SEQ_FILE.args"
LOOP=$(extract_skill_bash "$ROOT/.claude/skills/babysit-pr/SKILL.md" babysit-pr-monitor-loop)
out=$(cd "$TMP" && PR=7 MONITOR_GENERATION=g1 MONITOR_CADENCE=5 MONITOR_REVIEW_DEADLINE=0 \
  bash -c 'n=0; sleep() { n=$((n+1)); (( n <= 4 )); }; '"$LOOP" 2>/dev/null)
[[ "$(printf '%s\n' "$out" | grep -c -- '--tick')" == 2 ]] || fail "babysit loop should print only the 2 non-quiet ticks: $out"
grep -q -- '--kind babysit --pr 7 --generation g1' "$QUIET_SEQ_FILE.args" || fail "babysit loop passed wrong gate args"
printf '10\n' > "$QUIET_SEQ_FILE"; rm -f "$QUIET_SEQ_FILE.n" "$QUIET_SEQ_FILE.args"
out=$(cd "$TMP" && PR=7 MONITOR_GENERATION=g1 MONITOR_CADENCE=5 MONITOR_REVIEW_DEADLINE="$(( $(date +%s) + 30 ))" \
  bash -c 'n=0; sleep() { n=$((n+1)); (( n <= 1 )); }; '"$LOOP" 2>/dev/null)
[[ "$(printf '%s\n' "$out" | grep -c -- '--tick')" == 1 && ! -e "$QUIET_SEQ_FILE.args" ]] ||
  fail "the review-deadline tick must always print, without consulting the gate"
printf '10\n0\n10\n' > "$QUIET_SEQ_FILE"; rm -f "$QUIET_SEQ_FILE.n" "$QUIET_SEQ_FILE.args"
LOOP=$(extract_skill_bash "$ROOT/.claude/skills/pm/modules/day-arm.md" pm-day-monitor-loop)
out=$(cd "$TMP" && DAY_CADENCE_MIN=5 DAY_GENERATION=d1 REPO_KEY="$REPO" \
  bash -c 'n=0; sleep() { n=$((n+1)); (( n <= 3 )); }; '"$LOOP" 2>/dev/null)
[[ "$(printf '%s\n' "$out" | grep -c -- '/pm day --tick')" == 1 ]] || fail "pm day loop should print only the non-quiet tick: $out"
grep -q -- "--kind pm-day --repo $REPO --generation d1" "$QUIET_SEQ_FILE.args" || fail "pm day loop passed wrong gate args"
rm -f "$HOME/.claude/scripts/monitor-quiet-tick.sh"
out=$(cd "$TMP" && DAY_CADENCE_MIN=5 DAY_GENERATION=d1 REPO_KEY="$REPO" \
  bash -c 'n=0; sleep() { n=$((n+1)); (( n <= 2 )); }; '"$LOOP" 2>/dev/null)
[[ "$(printf '%s\n' "$out" | grep -c -- '/pm day --tick')" == 2 ]] || fail "without the helper every pm day tick prints"
pass "the real Monitor loops print nothing on exit 10 and the tick line otherwise"

# 12. The skills record the contract only where a repeat tick would do nothing new.
REC=$(extract_skill_bash "$ROOT/.claude/skills/babysit-pr/SKILL.md" babysit-pr-t6a-quiet-record)
rec() { (QUIET_SH="$TMP/rec.sh" PR=7 bash -c "$REC" >/dev/null 2>&1); cat "$TMP/rec.args"; }
printf '#!/usr/bin/env bash\necho "$*" > "%s/rec.args"\n' "$TMP" > "$TMP/rec.sh"; chmod +x "$TMP/rec.sh"
a=$(CLASS=waiting-on-bots BACKOFF_STOP_REASON="" rec)
[[ "$a" == *"--quiet-ok true"*"--blocker-counting false --freeze-at none"* ]] || fail "waiting-on-bots contract wrong: $a"
a=$(CLASS=has-recoverable-blockers BACKOFF_STOP_REASON="" rec)
[[ "$a" == *"--quiet-ok false"* ]] || fail "a dispatching class must not be quiet: $a"
a=$(CLASS=has-recoverable-blockers DISPATCH_SUPPRESSED=true HORIZON_STATUS=unknown BACKOFF_STOP_REASON="" rec)
[[ "$a" == *"--quiet-ok true --blocker-counting true --freeze-at 9"* ]] || fail "suppressed dispatch contract wrong: $a"
a=$(CLASS=waiting-on-bots HORIZON_STATUS=critical BACKOFF_STOP_REASON="" rec)
[[ "$a" == *"--quiet-ok false"* ]] || fail "critical horizon must not be quiet: $a"
a=$(CLASS=waiting-on-bots DISPATCH_BLOCKING=1 BACKOFF_STOP_REASON="" rec)
[[ "$a" == *"--quiet-ok false"* ]] || fail "dispatch in flight must not be quiet: $a"
DREC=$(extract_skill_bash "$ROOT/.claude/skills/pm/modules/day-tick.md" pm-day-tick-quiet-record)
drec() { (REPO_KEY="$REPO" bash -c "resolve_script() { echo '$TMP/rec.sh'; }; $DREC" >/dev/null 2>&1); cat "$TMP/rec.args"; }
a=$(IDLE_REASON='ceiling reached' DAY_TICK_ACTED=false drec); [[ "$a" == *"--quiet-ok true"* ]] || fail "idle pm day tick should be quiet-eligible: $a"
a=$(IDLE_REASON='ceiling reached' DAY_TICK_ACTED=true drec); [[ "$a" == *"--quiet-ok false"* ]] || fail "acting pm day tick must not be quiet: $a"
a=$(IDLE_REASON='paused (horizon unknown)' DAY_TICK_ACTED=false drec); [[ "$a" == *"--quiet-ok false"* ]] || fail "horizon hold must stay loud: $a"
a=$(IDLE_REASON='nothing eligible' drec); [[ "$a" == *"--quiet-ok false"* ]] || fail "unbound DAY_TICK_ACTED must default to loud: $a"
pass "skill contracts allow quiet only for no-op repeats (wait, held dispatch, idle board)"

# 13. The contract carries the tick-START digest (Graphite review on PR #2491): an event that lands
#     while the model tick runs is outside the recorded digest, so the next Monitor tick emits for it.
mkgate "6 minutes left" "x"
QT() { PATH="$TMP/path:$PATH" "$BIN/monitor-quiet-tick.sh" "$@"; }
seed_babysit 1 5 0 false null 2 "del($P.babysit.quiet)"
set +e; QT --record --kind babysit --pr 7 --repo "$REPO" --quiet-ok true --freeze-at none 2>"$TMP/err"; rc=$?; set -e
[[ $rc -eq 1 && "$(bget "$B.babysit.quiet.quiet_ok")" == false ]] ||
  fail "record without a tick-start digest must store quiet_ok=false and exit 1 (rc=$rc: $(cat "$TMP/err"))"
start=$(dig)
mkgate "6 minutes left" "need 1 explicit CodeRabbit or CodeAnt APPROVED review"   # event lands mid-tick
QT --record --kind babysit --pr 7 --repo "$REPO" --quiet-ok true --freeze-at none --tick-start-digest "$start" 2>/dev/null ||
  fail "record with a tick-start digest should succeed"
[[ "$(bget "$B.babysit.quiet.input_digest")" == "$start" ]] || fail "babysit must store the tick-start digest as is"
set +e; OUT=$(QT --kind babysit --pr 7 --repo "$REPO" --generation g1 2>"$TMP/err"); RC=$?; set -e
[[ $RC -eq 0 && -z "$OUT" ]] || fail "a mid-tick event must make the next Monitor tick emit (rc=$RC)"
grep -q "input digest changed" "$TMP/err" || fail "mid-tick event emit reason missing: $(cat "$TMP/err")"
seed_babysit 1 5 0 false null 2 "del($P.babysit.quiet)"
start=$(dig)
QT --record --kind babysit --pr 7 --repo "$REPO" --quiet-ok true --freeze-at none --tick-start-digest "$start" 2>/dev/null
set +e; QT --kind babysit --pr 7 --repo "$REPO" --generation g1 2>"$TMP/err"; RC=$?; set -e
[[ $RC -eq 10 ]] || fail "no event since tick start should allow a quiet tick (rc=$RC: $(cat "$TMP/err"))"
set +e; QT --record --kind babysit --pr 7 --repo "$REPO" --quiet-ok true --tick-start-digest bogus 2>/dev/null; rc=$?; set -e
[[ $rc -eq 2 ]] || fail "a malformed tick-start digest should be a usage error (rc=$rc)"
# pm day: the external part is pinned at tick start; the repo-state part (the tick's own writes) is read at record.
cat > "$TMP/path/gh" <<'EOF'
#!/usr/bin/env bash
if [[ "$1 $2" == "repo view" ]]; then echo "${CWD_REPO:-Acme/Widgets}"; exit 0; fi
if [[ "$1 $2" == "pr list" ]]; then cat "$PRS_FIXTURE"; exit 0; fi
if [[ "$1 $2" == "issue list" ]]; then echo '[{"number":3,"updatedAt":"2026-01-01T00:00:00Z"}]'; exit 0; fi
echo "2026-01-01T00:00:00Z"
EOF
chmod +x "$TMP/path/gh"
export PRS_FIXTURE="$TMP/prs.json"
echo '[{"number":9,"headRefOid":"a1","updatedAt":"2026-01-01T00:00:00Z"}]' > "$PRS_FIXTURE"
seed_day 0 5 3; jq '.active_agents = []' "$STATE" > "$TMP/s" && mv "$TMP/s" "$STATE"
dstart=$(QT --print-digest --kind pm-day --repo "$REPO" 2>/dev/null)
[[ "$dstart" =~ ^sha256:[0-9a-f]{64}\.[0-9a-f]{64}$ ]] || fail "pm day digest form wrong: $dstart"
jq --arg r "$REPO" '.repos[$r].day.slots_free = 0' "$STATE" > "$TMP/s" && mv "$TMP/s" "$STATE"   # the tick's own write
QT --record --kind pm-day --repo "$REPO" --quiet-ok true --tick-start-digest "$dstart" 2>/dev/null || fail "pm day record should succeed"
rec_d=$(bget "$D.quiet.input_digest")
[[ "${rec_d%%.*}" == "${dstart%%.*}" && "$rec_d" != "$dstart" ]] || fail "pm day must pin the external part and re-read repo state ($rec_d)"
set +e; QT --kind pm-day --repo "$REPO" --generation d1 2>"$TMP/err"; RC=$?; set -e
[[ $RC -eq 10 ]] || fail "pm day: the tick's own state write must not defeat quiet (rc=$RC: $(cat "$TMP/err"))"
seed_day 0 5 3; jq '.active_agents = []' "$STATE" > "$TMP/s" && mv "$TMP/s" "$STATE"
dstart=$(QT --print-digest --kind pm-day --repo "$REPO" 2>/dev/null)
echo '[{"number":9,"headRefOid":"b2","updatedAt":"2026-01-01T00:09:00Z"}]' > "$PRS_FIXTURE"   # PR pushed mid-tick
QT --record --kind pm-day --repo "$REPO" --quiet-ok true --tick-start-digest "$dstart" 2>/dev/null
set +e; QT --kind pm-day --repo "$REPO" --generation d1 2>"$TMP/err"; RC=$?; set -e
[[ $RC -eq 0 ]] || fail "pm day: a PR event during the tick must make the next Monitor tick emit (rc=$RC)"
pass "contracts carry the tick-start digest: mid-tick events emit, missing digests fail closed, pm day own writes stay quiet"

# 14. A hung digest read is bounded: the tick emits (and disarms) instead of holding the Monitor loop silent.
cat > "$BIN/merge-gate.sh" <<'EOF'
#!/usr/bin/env bash
sleep "${GATE_SLEEP:-0}"; cat "$GATE_FIXTURE"; exit "${GATE_RC:-1}"
EOF
chmod +x "$BIN/merge-gate.sh"
seed_babysit 1 5 0 false null 2 "del($P.babysit.quiet)"
start=$(dig)
QT --record --kind babysit --pr 7 --repo "$REPO" --quiet-ok true --freeze-at none --tick-start-digest "$start" 2>/dev/null
t0=$(date +%s)
set +e; GATE_SLEEP=30 MONITOR_QUIET_DIGEST_TIMEOUT_S=2 QT --kind babysit --pr 7 --repo "$REPO" --generation g1 2>"$TMP/err"; RC=$?; set -e
elapsed=$(( $(date +%s) - t0 ))
[[ $RC -eq 0 && $elapsed -lt 15 ]] || fail "a hung read must emit within the bound (rc=$RC, ${elapsed}s)"
[[ "$(bget "$B.babysit.quiet.quiet_ok")" == false ]] || fail "a timed-out read must disarm the contract"
pass "a hung digest read emits within MONITOR_QUIET_DIGEST_TIMEOUT_S"

echo "ALL $PASS PASSED"
