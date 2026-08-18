#!/usr/bin/env bash
# release-sweep.test.sh — Offline unit tests for release-sweep.sh (issue #1169).
# Stubs `gh`, `release-policy.sh`, and `release-decide.sh`; uses the REAL
# session-state.sh against a temp $HOME so durable reads and writes are exercised.
# Run from repo root: bash .claude/scripts/tests/release-sweep.test.sh
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SRC="$REPO_ROOT/.claude/scripts/release-sweep.sh"

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

export HOME="$TMP/home"; mkdir -p "$HOME/.claude"
BIN="$TMP/bin"; mkdir -p "$BIN"
# Mirror the repo layout so session-state.sh finds its siblings: state-lock.sh
# and lib/repo-normalizer.sh. Without the lib it exits 5 and every write fails.
SCRIPTS="$TMP/.claude/scripts"; mkdir -p "$SCRIPTS/lib" "$TMP/.claude/reference"
cp "$SRC" "$SCRIPTS/release-sweep.sh"; chmod +x "$SCRIPTS/release-sweep.sh"
cp "$REPO_ROOT/.claude/scripts/session-state.sh" "$SCRIPTS/"
cp "$REPO_ROOT/.claude/scripts/state-lock.sh" "$SCRIPTS/"
cp "$REPO_ROOT/.claude/scripts/lib/repo-normalizer.sh" "$SCRIPTS/lib/"
cp "$REPO_ROOT/.claude/reference/session-state-schema.json" "$TMP/.claude/reference/"
chmod +x "$SCRIPTS/session-state.sh"
SUT="$SCRIPTS/release-sweep.sh"
STATE_SH="$SCRIPTS/session-state.sh"
STATE="$HOME/.claude/session-state.json"
export GH_LOG="$TMP/gh.log"

# --- Fake release-policy.sh: only `release_workflows` matters to the sweep ----
cat > "$SCRIPTS/release-policy.sh" <<'EOF'
#!/usr/bin/env bash
RC="${FAKE_POLICY_RC:-0}"
WF="${FAKE_WORKFLOWS:-}"; if [ -z "$WF" ]; then WF='["mobile-testflight.yml"]'; fi
jq -cn --argjson wf "$WF" '{enabled:true, release_workflows:$wf, trigger:"label:release:ios"}'
exit "$RC"
EOF
chmod +x "$SCRIPTS/release-policy.sh"

# --- Fake release-decide.sh: the sweep only reads its exit code + .reason -----
cat > "$SCRIPTS/release-decide.sh" <<'EOF'
#!/usr/bin/env bash
echo "decide $*" >> "$GH_LOG"
# NOT a ${VAR:-{...}} brace default: that expansion terminates at the first
# literal `}` and emits mangled JSON (see feedback on brace-default truncation).
DEC_JSON="${FAKE_DECIDE_JSON:-}"
if [ -z "$DEC_JSON" ]; then DEC_JSON='{"decision":"build_now","reason":"window open"}'; fi
printf '%s\n' "$DEC_JSON"
exit "${FAKE_DECIDE_RC:-0}"
EOF
chmod +x "$SCRIPTS/release-decide.sh"

# --- Fake gh -----------------------------------------------------------------
cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
ARGS="$*"
echo "$ARGS" >> "$GH_LOG"
case "$ARGS" in
  # Resolve a run by id. Without this case the id lookup fell through to exit 90
  # and every test silently exercised the old list-scan path instead.
  *"api repos/"*"/actions/runs/"*)
    if [ "${FAKE_RUN_BY_ID_RC:-0}" != "0" ]; then exit "${FAKE_RUN_BY_ID_RC}"; fi
    R="${FAKE_RUN_BY_ID:-}"
    if [ -z "$R" ]; then
      # Default: mirror whatever FAKE_RUNS_JSON holds, matched on the trailing id.
      RID="${ARGS##*/actions/runs/}"; RID="${RID%% *}"
      R=$(printf '%s' "${FAKE_RUNS_JSON:-[]}" | jq -c --argjson id "${RID:-0}" 'map(select(.databaseId == $id)) | first // empty')
    fi
    [ -n "$R" ] || exit 1
    printf '%s\n' "$R"; exit 0 ;;
  "run list"*)
    R="${FAKE_RUNS_JSON:-}"; if [ -z "$R" ]; then R='[]'; fi
    printf '%s\n' "$R"; exit 0 ;;
esac
echo "unexpected gh call: $ARGS" >&2; exit 90
EOF
chmod +x "$BIN/gh"
export PATH="$BIN:$PATH"

PASS=0; FAIL=0
ok()  { echo "ok   - $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL - $1"; FAIL=$((FAIL+1)); }

reset_state() { rm -f "$STATE"; : > "$GH_LOG"; }
run() { OUT="$("$SUT" "$@" 2>&1)"; RC=$?; }

# Seed goes through the real session-state.sh, so a seeding bug surfaces as a
# seeding failure rather than as a mysterious sweep result.
seed() {  # $1 repo, $2 subpath, $3 json value
  "$STATE_SH" --raw-path --set ".repos[\"$1\"].release.$2=$3" >/dev/null || {
    echo "SEED FAILED for $1 .$2" >&2; return 1; }
}

expect_rc()     { if [[ "$RC" -eq "$1" ]]; then ok "$2"; else bad "$2 (got rc=$RC; out: $OUT)"; fi; }
says()          { if grep -qF "$1" <<<"$OUT"; then ok "$2"; else bad "$2 (out: $OUT)"; fi; }
says_not()      { if grep -qF "$1" <<<"$OUT"; then bad "$2 (unexpected: $1; out: $OUT)"; else ok "$2"; fi; }
expect_state()  { local got
                  if [ -f "$STATE" ]; then got="$(jq -r "$1" < "$STATE" 2>/dev/null)"; else got="null"; fi
                  if [[ "$got" == "$2" ]]; then ok "$3"; else bad "$3 (state $1 = '$got', want '$2')"; fi; }
kinds()         { printf '%s' "$OUT" | jq -r '[.[].kind] | join(",")' 2>/dev/null; }
expect_kinds()  { local got; got="$(kinds)"
                  if [[ "$got" == "$1" ]]; then ok "$2"; else bad "$2 (kinds = '$got'; out: $OUT)"; fi; }

# Runs relative to now so fixtures keep meaning the same thing over time.
mkrun() {  # mins_ago dur_min status conclusion id
  python3 - "$@" <<'PY'
import sys, json, datetime
mins_ago, dur, status, concl = float(sys.argv[1]), float(sys.argv[2]), sys.argv[3], sys.argv[4]
u = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(minutes=mins_ago)
c = u - datetime.timedelta(minutes=dur)
print(json.dumps({"databaseId": int(sys.argv[5]), "status": status,
                  "conclusion": (concl or None),
                  "url": "https://gh/run/" + sys.argv[5],
                  "createdAt": c.strftime("%Y-%m-%dT%H:%M:%SZ"),
                  "updatedAt": u.strftime("%Y-%m-%dT%H:%M:%SZ")}))
PY
}
ago_iso() { python3 -c "import sys,datetime;print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(minutes=float(sys.argv[1]))).strftime('%Y-%m-%dT%H:%M:%SZ'))" "$1"; }

R_SUCCESS=$(mkrun 3 12 completed success 101 | jq -sc .)
R_FAILURE=$(mkrun 3 12 completed failure 102 | jq -sc .)
R_SKIPPED=$(mkrun 3 0 completed skipped 103 | jq -sc .)
R_CANCELLED=$(mkrun 3 4 completed cancelled 104 | jq -sc .)
R_RUNNING=$(mkrun 2 0 in_progress "" 105 | jq -sc .)

inflight() {  # $1 = run_id or "null", $2 = minutes since trigger
  jq -cn --argjson id "$1" --arg at "$(ago_iso "$2")" \
    '{pr:7, mechanism:"workflow_dispatch:mobile-testflight.yml", triggered_at:$at,
      detail:"dispatched mobile-testflight.yml", run_id:$id, awaiting_run:($id == null)}'
}

echo "== release-sweep.test.sh =="

# 1. Nothing to sweep: no repo carries release state.
reset_state
run
expect_rc 0 "an empty sweep needs no attention (exit 0)"
if [ -z "$OUT" ]; then ok "an empty sweep prints nothing"; else bad "an empty sweep prints nothing (out: $OUT)"; fi

# 2. A successful build resolves quietly: in-flight cleared, build recorded, and
#    NOT reported — AC11 keeps a healthy outcome silent.
reset_state
seed "solo/app" "in_flight" "$(inflight 101 5)"
FAKE_RUNS_JSON="$R_SUCCESS" run
expect_rc 0 "a successful build needs no attention (exit 0)"
if [ -z "$OUT" ]; then ok "a successful build prints nothing"; else bad "a successful build prints nothing (out: $OUT)"; fi
expect_state '.repos["solo/app"].release.in_flight' 'null' "a resolved build clears the in-flight record"
expect_state '.repos["solo/app"].release.last_seen_build.conclusion' 'success' "the successful build is recorded"
expect_state '.repos["solo/app"].release.last_seen_build.run_id' '101' "the recorded build names the run"

# 3. A failed build is surfaced, not dropped (AC10).
reset_state
seed "solo/app" "in_flight" "$(inflight 102 5)"
FAKE_RUNS_JSON="$R_FAILURE" run
expect_rc 1 "a failed build needs attention (exit 1)"
says "TestFlight release failure" "the failure is surfaced"
says "solo/app" "the failure names the repo"
says "https://gh/run/102" "the failure links the run"
expect_state '.repos["solo/app"].release.in_flight' 'null' "a failed build still clears the in-flight record"
expect_state '.repos["solo/app"].release.last_seen_build.conclusion' 'failure' "the failure is recorded as the last build"

# 4. A silently-skipped release is the exact failure mode this issue exists to
#    end: the trigger fired, the workflow's own guard did not match, and nothing
#    shipped. It must never pass as success.
reset_state
seed "solo/app" "in_flight" "$(inflight 103 5)"
FAKE_RUNS_JSON="$R_SKIPPED" run
expect_rc 1 "a skipped release needs attention (exit 1)"
says "TestFlight release skipped" "a skipped release is surfaced"
says "produced no build" "the skip explains that nothing shipped"
expect_state '.repos["solo/app"].release.in_flight' 'null' "a skipped release clears the in-flight record"

# 5. Cancelled is a failure to ship like any other.
reset_state
seed "solo/app" "in_flight" "$(inflight 104 5)"
FAKE_RUNS_JSON="$R_CANCELLED" run
expect_rc 1 "a cancelled build needs attention (exit 1)"
says "cancelled" "a cancelled build is surfaced"

# 6. Still building: silence is correct, and the record must survive so the next
#    sweep can resolve it.
reset_state
seed "solo/app" "in_flight" "$(inflight 105 5)"
FAKE_RUNS_JSON="$R_RUNNING" run
expect_rc 0 "an in-progress build needs no attention (exit 0)"
if [ -z "$OUT" ]; then ok "an in-progress build prints nothing"; else bad "an in-progress build prints nothing (out: $OUT)"; fi
expect_state '.repos["solo/app"].release.in_flight.run_id' '105' "the in-flight record survives an unfinished build"

# 7. A trigger that produced no run at all, past the grace window, is a trigger
#    that did not take — reported rather than waited on forever.
reset_state
seed "solo/app" "in_flight" "$(inflight null 30)"
FAKE_RUNS_JSON='[]' run
expect_rc 1 "a trigger that produced no run needs attention (exit 1)"
says "did not start" "a trigger that produced no run is surfaced"
expect_state '.repos["solo/app"].release.in_flight' 'null' "a trigger that did not take stops being awaited"

# 8. Inside the grace window the same state is not yet an error.
reset_state
seed "solo/app" "in_flight" "$(inflight null 5)"
FAKE_RUNS_JSON='[]' run
expect_rc 0 "a just-triggered build is still within grace (exit 0)"
expect_state '.repos["solo/app"].release.in_flight.awaiting_run' 'true' "a just-triggered build is still awaited"

# 9. An awaited build adopts the run that appeared, so later sweeps track it.
reset_state
seed "solo/app" "in_flight" "$(inflight null 5)"
FAKE_RUNS_JSON="$R_RUNNING" run
expect_rc 0 "adopting a run needs no attention (exit 0)"
expect_state '.repos["solo/app"].release.in_flight.run_id' '105' "the appeared run is adopted"
expect_state '.repos["solo/app"].release.in_flight.awaiting_run' 'false' "an adopted run is no longer awaited"

# 10. The whole point of the sweep: a pending marker becomes a build after the
#     originating thread is gone.
reset_state
seed "solo/app" "pending" '{"since":"2026-08-01T00:00:00Z","pr":7,"count":3,"reason":"inside the build window"}'
FAKE_RUNS_JSON='[]' FAKE_DECIDE_RC=0 run
expect_rc 0 "cutting a pending build needs no attention (exit 0)"
says "cut TestFlight build" "a cut build is reported"
says "PR #7" "the cut build names the PR that is shipping"
if [ "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" = "1" ]; then
  ok "a cut build is a single line (AC11)"
else bad "a cut build is a single line (got: $OUT)"; fi
if grep -qF "decide --repo solo/app --phase now --apply" "$GH_LOG"; then
  ok "the cut goes through release-decide with the deferred phase"
else bad "the cut goes through release-decide with the deferred phase (log: $(tr '\n' '|' < "$GH_LOG"))"; fi

# 11. Two builds are never started for one repo (AC9): a pending marker while a
#     build is still processing must not be cut.
reset_state
seed "solo/app" "in_flight" "$(inflight 105 5)"
seed "solo/app" "pending" '{"since":"2026-08-01T00:00:00Z","pr":7,"count":1,"reason":"inside the build window"}'
FAKE_RUNS_JSON="$R_RUNNING" run
expect_rc 0 "a pending marker behind an in-flight build is not an error (exit 0)"
if grep -qF "decide --repo" "$GH_LOG"; then
  bad "no second build is started while one is processing"
else ok "no second build is started while one is processing"; fi
expect_state '.repos["solo/app"].release.pending.pr' '7' "the pending marker survives to be cut later"

# 12. A label-only repo cannot be cut by the sweep. Reported ONCE per marker —
#     repeating it every tick would be the noise AC11 forbids — and the marker is
#     kept so the repo's next merge ships the accumulated work.
reset_state
seed "solo/app" "pending" '{"since":"2026-08-01T00:00:00Z","pr":7,"count":2,"reason":"inside the build window"}'
FAKE_RUNS_JSON='[]' FAKE_DECIDE_RC=3 \
  FAKE_DECIDE_JSON='{"decision":"blocked","reason":"no deferred trigger — it will ship on the next merge"}' run
expect_rc 1 "an uncuttable pending marker needs attention (exit 1)"
says "pending but not cuttable" "the uncuttable marker is surfaced"
says "ship on the next merge" "the blocker explains what happens instead"
expect_state '.repos["solo/app"].release.pending.pr' '7' "an uncuttable marker is kept, not discarded"
expect_state '.repos["solo/app"].release.pending.count' '2' "the accumulated merge count is kept"

# 13. ...and the second sweep over the same marker is silent.
: > "$GH_LOG"
FAKE_RUNS_JSON='[]' FAKE_DECIDE_RC=3 \
  FAKE_DECIDE_JSON='{"decision":"blocked","reason":"no deferred trigger — it will ship on the next merge"}' run
expect_rc 0 "an already-reported blocker is not re-reported (exit 0)"
if [ -z "$OUT" ]; then ok "a re-swept blocker prints nothing"; else bad "a re-swept blocker prints nothing (out: $OUT)"; fi

# 14. Inside the window, decide exits 1 — an ordinary state, not an event.
reset_state
seed "solo/app" "pending" '{"since":"2026-08-01T00:00:00Z","pr":7,"count":1,"reason":"inside the build window"}'
FAKE_RUNS_JSON='[]' FAKE_DECIDE_RC=1 run
expect_rc 0 "a still-closed window needs no attention (exit 0)"
if [ -z "$OUT" ]; then ok "a still-closed window prints nothing"; else bad "a still-closed window prints nothing (out: $OUT)"; fi
expect_state '.repos["solo/app"].release.pending.notified_at' 'null' "a still-closed window is not marked as notified"

# 15. --repo scopes the sweep; other repos with state are untouched.
reset_state
seed "solo/app" "in_flight" "$(inflight 102 5)"
seed "other/app" "in_flight" "$(inflight 102 5)"
FAKE_RUNS_JSON="$R_FAILURE" run --repo solo/app
expect_rc 1 "a scoped sweep still reports its own repo (exit 1)"
says "solo/app" "the scoped repo is swept"
says_not "other/app" "an out-of-scope repo is left alone"
expect_state '.repos["other/app"].release.in_flight.run_id' '102' "an out-of-scope repo keeps its in-flight record"

# 16. --json emits structured events; --quiet suppresses the human lines but
#     still reports through the exit code.
reset_state
seed "solo/app" "in_flight" "$(inflight 102 5)"
FAKE_RUNS_JSON="$R_FAILURE" run --json
expect_rc 1 "--json still reports attention through the exit code"
expect_kinds "release_failed" "--json names the event kind"

reset_state
seed "solo/app" "in_flight" "$(inflight 102 5)"
FAKE_RUNS_JSON="$R_FAILURE" run --quiet
expect_rc 1 "--quiet still reports attention through the exit code"
if [ -z "$OUT" ]; then ok "--quiet prints nothing"; else bad "--quiet prints nothing (out: $OUT)"; fi

# 17. A state write that does not land is surfaced. Left silent it would both
#     re-report the same terminal event forever and permanently wedge the
#     "never start a second build" guard, while looking like a healthy wait.
reset_state
seed "solo/app" "in_flight" "$(inflight 101 5)"
cp "$STATE_SH" "$TMP/session-state.real"
cat > "$STATE_SH" <<'STUB'
#!/usr/bin/env bash
# Reads succeed so the sweep gets far enough to attempt a write; writes fail.
case " $* " in
  *" --get "*) exec "$0.real" "$@" ;;
esac
echo "session-state.sh: could not acquire lock" >&2
exit 6
STUB
cp "$TMP/session-state.real" "$STATE_SH.real"; chmod +x "$STATE_SH" "$STATE_SH.real"
FAKE_RUNS_JSON="$R_SUCCESS" run
expect_rc 1 "an unwritable state file needs attention (exit 1)"
says "release state could not be saved" "the failed write is surfaced"
says "could not acquire lock" "the underlying write error is carried"
cp "$TMP/session-state.real" "$STATE_SH"; rm -f "$STATE_SH.real"

# 18. With writes working again the identical sweep is silent — proving 17 fails
#     for the reason claimed rather than from a broken fixture.
reset_state
seed "solo/app" "in_flight" "$(inflight 101 5)"
FAKE_RUNS_JSON="$R_SUCCESS" run
expect_rc 0 "the identical sweep is clean once writes work again (exit 0)"
if [ -z "$OUT" ]; then ok "a healthy sweep prints nothing"; else bad "a healthy sweep prints nothing (out: $OUT)"; fi

# 19. An unknown argument is a usage error, not a silent no-op sweep.
run --nonsense
expect_rc 4 "an unknown argument exits 4"

# 20. A known run_id is resolved by id, not by scanning the list. The list scan is
# capped per workflow, so on a busy repo an adopted run falls off it and a shipped
# build would read as "never started".
reset_state
seed "solo/app" "in_flight" "$(inflight 101 5)"
FAKE_RUNS_JSON='[]' FAKE_RUN_BY_ID="$(printf '%s' "$R_SUCCESS" | jq -c '.[0]')" run
expect_rc 0 "a run absent from the list scan still resolves by id (exit 0)"
expect_state '.repos["solo/app"].release.last_seen_build.conclusion' 'success' "the id-resolved run is followed to its terminal state"
if grep -qF "api repos/solo/app/actions/runs/101" "$GH_LOG"; then
  ok "the run is fetched by id"
else bad "the run is fetched by id (log: $(tr '\n' '|' < "$GH_LOG"))"; fi

# 21. release-decide.sh exit 4 is an environment error, not an ordinary
# "nothing to do" — it must surface rather than being swallowed by the default.
reset_state
seed "solo/app" "pending" '{"since":"2026-08-01T00:00:00Z","pr":7,"count":1,"reason":"inside the build window"}'
FAKE_RUNS_JSON='[]' FAKE_DECIDE_RC=4 run
expect_rc 1 "a decide environment error needs attention (exit 1)"
says "could not be evaluated" "the environment error is surfaced"

# 22. --help exits cleanly and documents the usage.
run --help
expect_rc 0 "--help exits 0"
says "release-sweep.sh" "--help names the script"

echo "----------------------------------------"
echo "release-sweep.test.sh: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
