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
# AUDIT_LOG interleaves state writes with gh calls so ordering is assertable.
# The real session-state.sh is wrapped rather than replaced, so writes still go
# through the genuine implementation.
export AUDIT_LOG="$TMP/audit.log"
mv "$SCRIPTS/session-state.sh" "$SCRIPTS/session-state.impl.sh"
cat > "$SCRIPTS/session-state.sh" <<'WRAP'
#!/usr/bin/env bash
case " $* " in
  *" --set "*) for a in "$@"; do case "$a" in *in_flight*) echo "STATE_SET in_flight" >> "$AUDIT_LOG";; esac; done ;;
esac
exec "$(dirname "$0")/session-state.impl.sh" "$@"
WRAP
chmod +x "$SCRIPTS/session-state.sh"
cp "$SCRIPTS/session-state.impl.sh" "$TMP/session-state.real"

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
  --arg isource "${FAKE_INTERVAL_SOURCE:-policy}" \
  '{enabled:true, reason:$reason, policy_source:"api", min_interval_minutes:$interval,
    interval_source:$isource, trigger:$trigger, deferred_trigger:$deferred,
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
case "$ARGS" in *"--add-label"*) echo "GH add-label" >> "$AUDIT_LOG" ;; *"workflow run"*) echo "GH workflow-run" >> "$AUDIT_LOG" ;; esac
case "$ARGS" in
  "repo view --json nameWithOwner --jq .nameWithOwner") echo "solo/app"; exit 0 ;;
  # Paginated changed-file list. Without this case the call fell through to the
  # exit-90 default, the SUT silently used the capped `pr view` list, and the
  # pagination path shipped untested.
  *"api"*"/files"*)
    F="${FAKE_PR_FILES:-}"; if [ -z "$F" ]; then F='["app/mobile/App.tsx"]'; fi
    if [ "${FAKE_FILES_API_RC:-0}" != "0" ]; then exit "${FAKE_FILES_API_RC}"; fi
    printf '%s\n' "$F" | jq -r '.[]'; exit 0 ;;
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
reset_state() { rm -f "$STATE"; : > "$GH_LOG"; : > "$AUDIT_LOG"; }
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
# Backed up ONCE, before anything can break it. Re-copying inside break_state
# would promote the stub to "the backup" the first time a case forgets its
# fix_state, and every later case would then pass against a broken script —
# precisely the pass-for-the-wrong-reason failure this suite exists to catch.
break_state() {
  cat > "$SCRIPTS/session-state.impl.sh" <<'STUB'
#!/usr/bin/env bash
echo "session-state.sh: missing sibling library: lib/repo-normalizer.sh" >&2
exit 5
STUB
  chmod +x "$SCRIPTS/session-state.impl.sh"
}
fix_state() { cp "$TMP/session-state.real" "$SCRIPTS/session-state.impl.sh"; }

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

# 16. State that cannot be written means the build is NEVER STARTED, rather than
# started and then lost. The in-flight claim is staked before the trigger
# precisely so an unfollowable build is never cut: if the claim cannot be
# persisted, nothing fires and a human is told.
reset_state; break_state
FAKE_RUNS_JSON="$OLD_BUILD" FAKE_INTERVAL=60 run --repo solo/app --pr 5 --apply --phase pre-merge
expect_rc 3 "an unstakeable claim blocks the dispatch (exit 3)"
expect_field '.decision' 'blocked' "an unstakeable claim reports blocked"
expect_field '.applied' 'false' "nothing is reported as applied"
gh_absent "add-label" "no label is applied when the claim cannot be staked"
if jq -e '.reason | test("can be duplicated by a concurrent evaluation")' >/dev/null <<<"$OUT"; then
  ok "the blocker explains why an unclaimed trigger is refused"
else bad "the blocker explains why an unclaimed trigger is refused (reason: $(jq -r .reason <<<"$OUT"))"; fi
fix_state

# 16b. The claim is staked BEFORE the trigger, not after — this is what closes the
# window in which two overlapping evaluations both see "no build running" and
# both fire. Asserted on ordering, since a claim written afterwards would still
# leave the record looking correct at rest.
reset_state
FAKE_RUNS_JSON="$OLD_BUILD" FAKE_INTERVAL=60 run --repo solo/app --pr 5 --apply --phase pre-merge
expect_rc 0 "a healthy claim-then-trigger succeeds (exit 0)"
expect_state '.repos["solo/app"].release.in_flight.awaiting_run' 'true' "the claim survives as the in-flight record"
expect_state '.repos["solo/app"].release.in_flight.pr' '5' "the claim names the PR"
gh_called "add-label" "the trigger still fires on the healthy path"

# 16c. A trigger that FAILS releases the claim, so a failed attempt cannot wedge
# the repo as permanently "building" and block every later merge.
reset_state
FAKE_RUNS_JSON="$OLD_BUILD" FAKE_INTERVAL=60 FAKE_LABEL_RC=1 \
  run --repo solo/app --pr 5 --apply --phase pre-merge
expect_rc 3 "a failed trigger blocks (exit 3)"
expect_state '.repos["solo/app"].release.in_flight' 'null' "a failed trigger releases its claim"

# 17. With state healthy again, the same call is a clean exit 0 — proving the
# three cases above fail for the reason claimed and not from a broken fixture.
reset_state
FAKE_RUNS_JSON="$OLD_BUILD" FAKE_INTERVAL=60 run --repo solo/app --pr 5 --apply --phase pre-merge
expect_rc 0 "the identical call succeeds once state writes work again"
expect_field '.state_write_error' '' "a healthy run carries no write error"

# 18. The derived-interval cache seam. With interval_source "policy" (an explicit
# owner override) none of this code runs, which is why the stub now varies it.
reset_state
FAKE_RUNS_JSON="$OLD_BUILD" FAKE_INTERVAL=90 FAKE_INTERVAL_SOURCE=auto \
  run --repo solo/app --pr 5 --apply --phase pre-merge
expect_rc 0 "a derived interval decides normally (exit 0)"
expect_state '.repos["solo/app"].release.interval_minutes' '90' "a derived interval is cached"
expect_state '.repos["solo/app"].release.interval_source' 'auto' "the cache records the derived source"
if [ -f "$STATE" ] && [ "$(jq -r '.repos["solo/app"].release.derived_at // "null"' < "$STATE")" != "null" ]; then
  ok "the cache is stamped with derived_at"
else bad "the cache is stamped with derived_at"; fi

# 19. An explicit min_interval must beat a FRESH cached derived interval. Without
# this, switching a repo from "auto" to an explicit value would keep using the
# stale derived number for a whole cache TTL.
FAKE_RUNS_JSON="$RECENT_BUILD" FAKE_INTERVAL=5 FAKE_INTERVAL_SOURCE=policy \
  run --repo solo/app --pr 6 --apply --phase pre-merge
expect_field '.interval_minutes' '5' "an explicit min_interval overrides a fresh cached one"
expect_field '.interval_source' 'policy' "the explicit source is reported, not the cached one"
expect_rc 0 "the explicit 5m window is open 10m after the last build (exit 0)"

# 20. ...and the cached derived value is still used when the policy says auto,
# so 19 proves precedence rather than that caching is simply broken.
FAKE_RUNS_JSON="$RECENT_BUILD" FAKE_INTERVAL=5 FAKE_INTERVAL_SOURCE=auto \
  run --repo solo/app --pr 7 --apply --phase pre-merge
expect_field '.interval_minutes' '90' "an auto policy still reads the cached derived interval"
expect_rc 1 "the cached 90m window is still closed 10m after the last build (exit 1)"

# 21. The changed-file list must come from the PAGINATED api call, not the capped
# `pr view` list. Asserted explicitly because the fake previously had no `api`
# case: the call fell through to exit 90 and the SUT silently used the old path,
# so the pagination fix shipped green while never running.
reset_state
FAKE_RUNS_JSON="$OLD_BUILD" FAKE_INTERVAL=60 FAKE_PR_FILES='["docs/x.md"]' \
  FAKE_SUPPRESS='{"paths":["docs/**"],"labels":[]}' \
  run --repo solo/app --pr 5 --apply --phase pre-merge
gh_called "api" "the changed-file list is read through the paginated api call"
expect_field '.class' 'suppress' "a docs-only PR read through that path is suppressed"

# 22. A capped `pr view` fallback must never drive a suppression: truncation can
# only make a PR look MORE ignorable than it is.
reset_state
BIG=$(python3 -c "import json;print(json.dumps(['docs/f%d.md'%i for i in range(100)]))")
FAKE_RUNS_JSON="$OLD_BUILD" FAKE_INTERVAL=60 FAKE_FILES_API_RC=1 FAKE_PR_FILES="$BIG" \
  FAKE_SUPPRESS='{"paths":["docs/**"],"labels":[]}' \
  run --repo solo/app --pr 5 --apply --phase pre-merge
expect_rc 3 "a possibly-truncated file list blocks rather than suppressing (exit 3)"
expect_field '.decision' 'blocked' "the truncated-list case reports blocked"

# 23. ORDER, not just presence. Asserting "a claim exists" and "the label was
# applied" is satisfied by either ordering — including the broken one this fix
# exists to prevent, where the trigger fires first and the claim lands after.
# The audit log interleaves both, so the property is actually tested.
reset_state
FAKE_RUNS_JSON="$OLD_BUILD" FAKE_INTERVAL=60 run --repo solo/app --pr 5 --apply --phase pre-merge
expect_rc 0 "the ordered claim-then-trigger path succeeds (exit 0)"
CLAIM_LINE=$(grep -n "STATE_SET in_flight" "$AUDIT_LOG" | head -1 | cut -d: -f1)
TRIG_LINE=$(grep -n "GH add-label" "$AUDIT_LOG" | head -1 | cut -d: -f1)
if [ -n "$CLAIM_LINE" ] && [ -n "$TRIG_LINE" ] && [ "$CLAIM_LINE" -lt "$TRIG_LINE" ]; then
  ok "the in-flight claim is written BEFORE the trigger fires"
else
  bad "the in-flight claim is written BEFORE the trigger fires (claim=$CLAIM_LINE trigger=$TRIG_LINE; audit: $(tr '\n' '|' < "$AUDIT_LOG"))"
fi

# 24. Same ordering for the dispatch mechanism, not just the label one.
reset_state
FAKE_RUNS_JSON="$OLD_BUILD" FAKE_INTERVAL=60 FAKE_TRIGGER="workflow_dispatch:mobile-testflight.yml" \
  run --repo solo/app --pr 5 --apply --phase post-merge
expect_rc 0 "the dispatch path succeeds (exit 0)"
CLAIM_LINE=$(grep -n "STATE_SET in_flight" "$AUDIT_LOG" | head -1 | cut -d: -f1)
TRIG_LINE=$(grep -n "GH workflow-run" "$AUDIT_LOG" | head -1 | cut -d: -f1)
if [ -n "$CLAIM_LINE" ] && [ -n "$TRIG_LINE" ] && [ "$CLAIM_LINE" -lt "$TRIG_LINE" ]; then
  ok "the claim precedes a workflow_dispatch trigger too"
else
  bad "the claim precedes a workflow_dispatch trigger too (claim=$CLAIM_LINE trigger=$TRIG_LINE; audit: $(tr '\n' '|' < "$AUDIT_LOG"))"
fi

echo "----------------------------------------"
echo "release-decide.test.sh: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
