#!/usr/bin/env bash
# release-decide.test.sh — Offline unit tests for release-decide.sh (issue #1169).
# Stubs `gh` and `release-policy.sh`; uses the REAL session-state.sh against a
# temp $HOME so the durable-state writes are exercised for real.
# Run from repo root: bash .claude/scripts/tests/release-decide.test.sh
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SRC="$REPO_ROOT/.claude/scripts/release-decide.sh"

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

export HOME="$TMP/home"; mkdir -p "$HOME/.claude"
BIN="$TMP/bin"; mkdir -p "$BIN"
# Mirror the repo layout so session-state.sh finds its sibling state-lock.sh and
# ../reference/session-state-schema.json.
SCRIPTS="$TMP/.claude/scripts"; mkdir -p "$SCRIPTS/lib" "$TMP/.claude/reference"
cp "$SRC" "$SCRIPTS/release-decide.sh"; chmod +x "$SCRIPTS/release-decide.sh"
cp "$REPO_ROOT/.claude/scripts/session-state.sh" "$SCRIPTS/"
cp "$REPO_ROOT/.claude/scripts/state-lock.sh" "$SCRIPTS/"
# session-state.sh sources both of these siblings and exits 5 without them; a
# missing lib made every durable write fail silently (see state_set in the SUT).
cp "$REPO_ROOT/.claude/scripts/lib/repo-normalizer.sh" "$SCRIPTS/lib/"
cp "$REPO_ROOT/.claude/reference/session-state-schema.json" "$TMP/.claude/reference/"
chmod +x "$SCRIPTS/session-state.sh"
SUT="$SCRIPTS/release-decide.sh"
STATE="$HOME/.claude/session-state.json"
export GH_LOG="$TMP/gh.log"

# --- Fake release-policy.sh ---------------------------------------------------
# FAKE_POLICY_RC    exit code (0 enabled, 1 off, 3 no pipeline, 4 malformed)
# FAKE_TRIGGER / FAKE_DEFERRED / FAKE_INTERVAL / FAKE_SUPPRESS / FAKE_EXPEDITE
cat > "$SCRIPTS/release-policy.sh" <<'EOF'
#!/usr/bin/env bash
RC="${FAKE_POLICY_RC:-0}"
SUP="${FAKE_SUPPRESS:-}"; if [ -z "$SUP" ]; then SUP='{"paths":[],"labels":[]}'; fi
EXP="${FAKE_EXPEDITE:-}"; if [ -z "$EXP" ]; then EXP='{"paths":[],"labels":[]}'; fi
jq -cn \
  --arg trigger "${FAKE_TRIGGER:-label:release:ios}" \
  --arg deferred "${FAKE_DEFERRED:-}" \
  --argjson interval "${FAKE_INTERVAL:-60}" \
  --argjson sup "$SUP" --argjson exp "$EXP" \
  --arg reason "${FAKE_POLICY_REASON:-}" \
  '{enabled:true, reason:$reason, policy_source:"api", min_interval_minutes:$interval,
    interval_source:"policy", trigger:$trigger, deferred_trigger:$deferred,
    release_workflows:["mobile-testflight.yml"], suppress:$sup, expedite:$exp,
    max_builds_per_day:8, derivation:{}}'
exit "$RC"
EOF
chmod +x "$SCRIPTS/release-policy.sh"

# --- Fake gh ------------------------------------------------------------------
# FAKE_PR_FILES / FAKE_PR_LABELS  JSON arrays for `pr view`
# FAKE_RUNS_JSON                  array returned by `gh run list`
# FAKE_LABEL_RC / FAKE_DISPATCH_RC  non-zero to force a trigger failure
cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
ARGS="$*"
echo "$ARGS" >> "$GH_LOG"
case "$ARGS" in
  "repo view --json nameWithOwner --jq .nameWithOwner") echo "solo/app"; exit 0 ;;
  *"pr view"*)
    F="${FAKE_PR_FILES:-}"; if [ -z "$F" ]; then F='["app/mobile/App.tsx"]'; fi
    L="${FAKE_PR_LABELS:-}"; if [ -z "$L" ]; then L='[]'; fi
    jq -cn --argjson f "$F" --argjson l "$L" \
      '{files: ($f | map({path: .})), labels: ($l | map({name: .}))}'; exit 0 ;;
  "run list"*)
    R="${FAKE_RUNS_JSON:-}"; if [ -z "$R" ]; then R='[]'; fi
    printf '%s\n' "$R"; exit 0 ;;
  *"pr edit"*) exit "${FAKE_LABEL_RC:-0}" ;;
  "workflow run"*) exit "${FAKE_DISPATCH_RC:-0}" ;;
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
expect_rc()    { if [[ "$RC" -eq "$1" ]]; then ok "$2"; else bad "$2 (got rc=$RC: $OUT)"; fi; }
expect_field() { local got; got="$(jq -r "$1" <<<"$OUT" 2>/dev/null)"
                 if [[ "$got" == "$2" ]]; then ok "$3"; else bad "$3 ($1 = '$got', want '$2'; out: $OUT)"; fi; }
# An absent state file reads as `null`: the SUT only creates it when it writes,
# so "no record" and "a null record" are the same claim. A positive assertion
# still fails on an absent file (null never equals a concrete value), so this
# cannot mask a write that failed to land.
expect_state() { local got
                 if [ -f "$STATE" ]; then got="$(jq -r "$1" < "$STATE" 2>/dev/null)"; else got="null"; fi
                 if [[ "$got" == "$2" ]]; then ok "$3"; else bad "$3 (state $1 = '$got', want '$2')"; fi; }
gh_called()    { if grep -q "$1" "$GH_LOG"; then ok "$2"; else bad "$2 (gh log: $(cat "$GH_LOG" | tr '\n' '|'))"; fi; }
gh_absent()    { if grep -q "$1" "$GH_LOG"; then bad "$2 (unexpectedly called: $1)"; else ok "$2"; fi; }

# Runs relative to now so fixtures keep meaning the same thing over time.
mkrun() {
  python3 - "$@" <<'PY'
import sys, json, datetime
mins_ago, dur, status, concl = float(sys.argv[1]), float(sys.argv[2]), sys.argv[3], sys.argv[4]
u = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(minutes=mins_ago)
c = u - datetime.timedelta(minutes=dur)
print(json.dumps({"databaseId": int(sys.argv[5]), "status": status, "conclusion": concl,
                  "createdAt": c.strftime("%Y-%m-%dT%H:%M:%SZ"),
                  "updatedAt": u.strftime("%Y-%m-%dT%H:%M:%SZ")}))
PY
}
PENDING_PATH='.repos["solo/app"].release.pending'
INFLIGHT_PATH='.repos["solo/app"].release.in_flight'

# A build that finished 10 minutes ago, and one that finished 5 hours ago.
RECENT_BUILD=$(mkrun 10 13 completed success 11 | jq -sc .)
OLD_BUILD=$(mkrun 300 13 completed success 12 | jq -sc .)
IN_PROGRESS=$(mkrun 2 0 in_progress "" 13 | jq -sc .)

# 1. Inert states.
reset_state
FAKE_POLICY_RC=1 FAKE_POLICY_REASON="off by default" run --repo solo/app --pr 5 --apply
expect_rc 2 "disabled policy is inert (exit 2)"
expect_field '.decision' 'disabled' "disabled policy reports decision=disabled"
gh_absent "pr edit" "disabled policy applies no label"

reset_state
FAKE_POLICY_RC=3 run --repo solo/app --pr 5 --apply
expect_rc 2 "no pipeline is inert (exit 2)"
expect_field '.decision' 'no_pipeline' "no pipeline reports decision=no_pipeline"

reset_state
FAKE_POLICY_RC=4 FAKE_POLICY_REASON="malformed policy" run --repo solo/app --pr 5 --apply
expect_rc 3 "malformed policy blocks (exit 3) rather than releasing"
expect_field '.decision' 'blocked' "malformed policy reports decision=blocked"
gh_absent "pr edit" "malformed policy applies no label"

# 2. Slow cadence — last build well outside the window: exactly one build cut.
reset_state
FAKE_RUNS_JSON="$OLD_BUILD" FAKE_INTERVAL=60 run --repo solo/app --pr 5 --apply --phase pre-merge
expect_rc 0 "window open => build_now (exit 0)"
expect_field '.decision' 'build_now' "open window decides build_now"
expect_field '.applied' 'true' "the trigger is executed under --apply"
gh_called "add-label release:ios" "label applied to the PR"
expect_state "$PENDING_PATH" 'null' "a cut build leaves no pending marker"
expect_state "$INFLIGHT_PATH.awaiting_run" 'true' "a cut build records an in-flight build to follow"

# 3. Fast cadence — inside the window: pending, no trigger, marker set.
reset_state
FAKE_RUNS_JSON="$RECENT_BUILD" FAKE_INTERVAL=60 run --repo solo/app --pr 5 --apply --phase pre-merge
expect_rc 1 "inside the window => pending (exit 1)"
expect_field '.decision' 'pending' "closed window decides pending"
gh_absent "add-label" "no label applied inside the window"
expect_state "$PENDING_PATH.pr" '5' "pending marker records the PR"
expect_state "$PENDING_PATH.count" '1' "pending marker starts a count"

# Two more merges inside the same window keep coalescing into the one marker.
FAKE_RUNS_JSON="$RECENT_BUILD" FAKE_INTERVAL=60 run --repo solo/app --pr 6 --apply --phase pre-merge
FAKE_RUNS_JSON="$RECENT_BUILD" FAKE_INTERVAL=60 run --repo solo/app --pr 7 --apply --phase pre-merge
expect_state "$PENDING_PATH.count" '3' "three merges in one window coalesce into one marker"
expect_state "$PENDING_PATH.pr" '7' "the marker tracks the latest merge"
gh_absent "add-label" "still exactly zero builds cut inside the window"

# 4. The window is measured from COMPLETION, not start (AC6). A build that
#    started 5 hours ago but finished 10 minutes ago is inside a 60m window.
reset_state
LONG_BUILD=$(mkrun 10 290 completed success 14 | jq -sc .)
FAKE_RUNS_JSON="$LONG_BUILD" FAKE_INTERVAL=60 run --repo solo/app --pr 5 --apply --phase pre-merge
expect_field '.decision' 'pending' "a long build that just finished still closes the window"

# 5. Suppress class — no build AND no pending marker.
reset_state
FAKE_RUNS_JSON="$OLD_BUILD" FAKE_INTERVAL=60 \
  FAKE_SUPPRESS='{"paths":["docs/**","**/*.md",".github/**"],"labels":["no-release"]}' \
  FAKE_PR_FILES='["docs/guide.md","README.md",".github/workflows/ci.yml"]' \
  run --repo solo/app --pr 5 --apply --phase pre-merge
expect_rc 1 "a docs/CI-only merge is suppressed (exit 1)"
expect_field '.decision' 'suppressed' "docs-only merge decides suppressed"
expect_field '.class' 'suppress' "docs-only merge is the suppress class"
gh_absent "add-label" "suppressed merge triggers nothing"
if [ -f "$STATE" ] && [ "$(jq -r "$PENDING_PATH" < "$STATE")" != "null" ]; then
  bad "a suppressed merge sets no pending marker"
else ok "a suppressed merge sets no pending marker"; fi

# A suppress LABEL suppresses regardless of paths.
reset_state
FAKE_RUNS_JSON="$OLD_BUILD" FAKE_INTERVAL=60 \
  FAKE_SUPPRESS='{"paths":[],"labels":["no-release"]}' FAKE_PR_LABELS='["no-release"]' \
  run --repo solo/app --pr 5 --apply --phase pre-merge
expect_field '.decision' 'suppressed' "a suppress label suppresses on its own"

# One app-touching file in a docs-heavy PR is NOT suppressed.
reset_state
FAKE_RUNS_JSON="$OLD_BUILD" FAKE_INTERVAL=60 \
  FAKE_SUPPRESS='{"paths":["docs/**","**/*.md"],"labels":[]}' \
  FAKE_PR_FILES='["docs/a.md","docs/b.md","app/mobile/App.tsx"]' \
  run --repo solo/app --pr 5 --apply --phase pre-merge
expect_field '.class' 'normal' "a partial docs match is not suppression"
expect_field '.decision' 'build_now' "one app file in a docs PR still ships"

# Nested paths: `**` crosses directory separators, a single `*` does not.
reset_state
FAKE_RUNS_JSON="$OLD_BUILD" FAKE_INTERVAL=60 \
  FAKE_SUPPRESS='{"paths":["web/*"],"labels":[]}' FAKE_PR_FILES='["web/src/deep/page.tsx"]' \
  run --repo solo/app --pr 5 --apply --phase pre-merge
expect_field '.class' 'normal' "a single * does not cross directory separators"

reset_state
FAKE_RUNS_JSON="$OLD_BUILD" FAKE_INTERVAL=60 \
  FAKE_SUPPRESS='{"paths":["web/**"],"labels":[]}' FAKE_PR_FILES='["web/src/deep/page.tsx"]' \
  run --repo solo/app --pr 5 --apply --phase pre-merge
expect_field '.class' 'suppress' "** crosses directory separators"

# 6. Expedite class — builds immediately inside an open window.
reset_state
FAKE_RUNS_JSON="$RECENT_BUILD" FAKE_INTERVAL=60 \
  FAKE_EXPEDITE='{"paths":[],"labels":["hotfix"]}' FAKE_PR_LABELS='["hotfix"]' \
  run --repo solo/app --pr 5 --apply --phase pre-merge
expect_rc 0 "an expedite-labelled merge builds inside the window (exit 0)"
expect_field '.class' 'expedite' "expedite label sets the expedite class"
gh_called "add-label release:ios" "expedited merge is triggered immediately"

reset_state
FAKE_RUNS_JSON="$RECENT_BUILD" FAKE_INTERVAL=60 \
  FAKE_EXPEDITE='{"paths":["app/mobile/crash/**"],"labels":[]}' \
  FAKE_PR_FILES='["app/mobile/crash/handler.ts"]' \
  run --repo solo/app --pr 5 --apply --phase pre-merge
expect_field '.decision' 'build_now' "an expedite path builds inside the window"

# Expedite beats suppress when a change matches both.
reset_state
FAKE_RUNS_JSON="$RECENT_BUILD" FAKE_INTERVAL=60 \
  FAKE_SUPPRESS='{"paths":["**/*.md"],"labels":[]}' \
  FAKE_EXPEDITE='{"paths":[],"labels":["hotfix"]}' \
  FAKE_PR_FILES='["docs/x.md"]' FAKE_PR_LABELS='["hotfix"]' \
  run --repo solo/app --pr 5 --apply --phase pre-merge
expect_field '.class' 'expedite' "expedite outranks suppress"

# 7. Concurrency guard (AC9) — never two builds at once, expedite included.
reset_state
FAKE_RUNS_JSON="$IN_PROGRESS" FAKE_INTERVAL=60 \
  FAKE_EXPEDITE='{"paths":[],"labels":["hotfix"]}' FAKE_PR_LABELS='["hotfix"]' \
  run --repo solo/app --pr 5 --apply --phase pre-merge
expect_rc 1 "a build in flight blocks a second one (exit 1)"
expect_field '.decision' 'in_flight' "in-flight build decides in_flight"
gh_absent "add-label" "no second build is started while one is processing"
expect_state "$PENDING_PATH.count" '1' "the blocked merge is remembered as pending"

# 8. Phase gating — the mechanism decides when it can act.
reset_state
FAKE_RUNS_JSON="$OLD_BUILD" FAKE_TRIGGER="workflow_dispatch:mobile-testflight.yml" \
  run --repo solo/app --pr 5 --apply --phase pre-merge
expect_rc 1 "a dispatch mechanism does not fire before the merge (exit 1)"
expect_field '.decision' 'deferred' "pre-merge phase defers a dispatch mechanism"
gh_absent "workflow run" "no dispatch before the merge"

reset_state
FAKE_RUNS_JSON="$OLD_BUILD" FAKE_TRIGGER="label:release:ios" \
  run --repo solo/app --pr 5 --apply --phase post-merge
expect_rc 1 "a label mechanism is a no-op after the merge (exit 1)"
expect_field '.decision' 'deferred' "post-merge phase defers a label mechanism"
if [ -f "$STATE" ] && [ "$(jq -r "$PENDING_PATH" < "$STATE")" != "null" ]; then
  bad "a phase no-op writes no state"
else ok "a phase no-op writes no state"; fi

reset_state
FAKE_RUNS_JSON="$OLD_BUILD" FAKE_TRIGGER="workflow_dispatch:mobile-testflight.yml" \
  run --repo solo/app --pr 5 --apply --phase post-merge
expect_rc 0 "a dispatch mechanism fires after the merge (exit 0)"
gh_called "workflow run mobile-testflight.yml" "the declared workflow is dispatched"

# 9. `none` — the repo already builds itself; do nothing but clear the marker.
reset_state
FAKE_RUNS_JSON="$OLD_BUILD" FAKE_TRIGGER="none" \
  run --repo solo/app --pr 5 --apply --phase post-merge
expect_rc 0 "an already-automatic repo decides build_now (exit 0)"
expect_field '.applied_detail' 'repo builds automatically on merge — nothing to trigger' \
  "an already-automatic repo triggers nothing"
gh_absent "workflow run" "no dispatch for an already-automatic repo"
gh_absent "add-label" "no label for an already-automatic repo"
expect_state "$INFLIGHT_PATH" 'null' "an already-automatic repo records no in-flight build of ours"

# 10. Sweep phase with no deferred mechanism — surfaced, never silently dropped.
reset_state
FAKE_RUNS_JSON="$OLD_BUILD" FAKE_TRIGGER="label:release:ios" FAKE_DEFERRED="" \
  run --repo solo/app --apply --phase now
expect_rc 3 "a label-only repo cannot be cut by the sweep (exit 3)"
expect_field '.decision' 'blocked' "label-only sweep reports blocked"
if printf '%s' "$OUT" | grep -q 'next merge'; then ok "the blocker explains it ships on the next merge"
else bad "the blocker explains it ships on the next merge (out: $OUT)"; fi

# 11. Without --apply nothing is written and nothing is triggered.
reset_state
FAKE_RUNS_JSON="$OLD_BUILD" FAKE_INTERVAL=60 run --repo solo/app --pr 5 --phase pre-merge
expect_rc 0 "a dry run still reports build_now (exit 0)"
expect_field '.applied' 'false' "a dry run applies nothing"
gh_absent "add-label" "a dry run triggers nothing"
if [ -f "$STATE" ] && [ "$(jq -r "$PENDING_PATH" < "$STATE")" != "null" ]; then
  bad "a dry run writes no state"
else ok "a dry run writes no state"; fi

# 12. A failing trigger blocks loudly instead of reporting a build that never started.
reset_state
FAKE_RUNS_JSON="$OLD_BUILD" FAKE_INTERVAL=60 FAKE_LABEL_RC=1 \
  run --repo solo/app --pr 5 --apply --phase pre-merge
expect_rc 3 "a failed label application blocks (exit 3)"
expect_field '.decision' 'blocked' "a failed trigger reports blocked"
expect_state "$INFLIGHT_PATH" 'null' "a failed trigger records no in-flight build"

# 13. No prior build in history at all => build (nothing to wait for).
reset_state
FAKE_RUNS_JSON='[]' FAKE_INTERVAL=60 run --repo solo/app --pr 5 --apply --phase pre-merge
expect_rc 0 "a repo that has never built ships immediately (exit 0)"
expect_field '.last_build_completed_at' 'null' "no prior build is reported as null"

# 14. A durable write that does not land is never reported as a quiet success.
# The whole point of `pending` is that a later sweep reads the marker; if the
# marker did not land, reporting `pending` promises a build that will never come.
break_state() {
  cp "$SCRIPTS/session-state.sh" "$TMP/session-state.real"
  cat > "$SCRIPTS/session-state.sh" <<'STUB'
#!/usr/bin/env bash
echo "session-state.sh: missing sibling library: lib/repo-normalizer.sh" >&2
exit 5
STUB
  chmod +x "$SCRIPTS/session-state.sh"
}
fix_state() { cp "$TMP/session-state.real" "$SCRIPTS/session-state.sh"; }

reset_state; break_state
FAKE_RUNS_JSON="$RECENT_BUILD" FAKE_INTERVAL=60 run --repo solo/app --pr 5 --apply --phase pre-merge
expect_rc 3 "an unsaved pending marker blocks instead of reporting pending (exit 3)"
expect_field '.decision' 'blocked' "an unsaved pending marker reports blocked"
if jq -e '.reason | test("no sweep will cut this work later")' >/dev/null <<<"$OUT"; then
  ok "the blocker says the work will not be swept"
else bad "the blocker says the work will not be swept (reason: $(jq -r .reason <<<"$OUT"))"; fi
if jq -e '.state_write_error | test("repo-normalizer")' >/dev/null <<<"$OUT"; then
  ok "the underlying write error is carried, not just its existence"
else bad "the underlying write error is carried (got: $(jq -r .state_write_error <<<"$OUT"))"; fi
fix_state

# 15. Same for the in-flight branch: a second build must never be silently lost.
reset_state; break_state
FAKE_RUNS_JSON="$IN_PROGRESS" FAKE_INTERVAL=60 run --repo solo/app --pr 5 --apply --phase pre-merge
expect_rc 3 "an unsaved in-flight pending marker blocks (exit 3)"
expect_field '.decision' 'blocked' "an unsaved in-flight marker reports blocked"
fix_state

# 16. A trigger that fired, with bookkeeping that did not: BOTH facts get said.
# Reporting only the failure would hide a real build; reporting only the success
# would hide that nothing will follow it to a terminal state (AC10).
reset_state; break_state
FAKE_RUNS_JSON="$OLD_BUILD" FAKE_INTERVAL=60 run --repo solo/app --pr 5 --apply --phase pre-merge
expect_rc 3 "a triggered build with unsaved state needs a human (exit 3)"
expect_field '.decision' 'build_now' "the build that really fired is still reported as build_now"
expect_field '.applied' 'true' "the trigger that fired is not disowned"
gh_called "add-label" "the label really was applied"
if jq -e '.reason | test("will not be followed automatically")' >/dev/null <<<"$OUT"; then
  ok "the report says the outcome will not be followed"
else bad "the report says the outcome will not be followed (reason: $(jq -r .reason <<<"$OUT"))"; fi
fix_state

# 17. With state healthy again, the same call is a clean exit 0 — proving the
# three cases above fail for the reason claimed and not from a broken fixture.
reset_state
FAKE_RUNS_JSON="$OLD_BUILD" FAKE_INTERVAL=60 run --repo solo/app --pr 5 --apply --phase pre-merge
expect_rc 0 "the identical call succeeds once state writes work again"
expect_field '.state_write_error' '' "a healthy run carries no write error"

echo "----------------------------------------"
echo "release-decide.test.sh: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
