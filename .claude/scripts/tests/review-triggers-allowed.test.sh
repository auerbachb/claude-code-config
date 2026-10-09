#!/usr/bin/env bash
# Offline tests for review-triggers-allowed.sh (issue #1749).
# catalog: tests — Tests `review-triggers-allowed.sh` — legacy pass-through, every tier row, fail-closed probe, settled HEAD, lifetime caps across comments and the ledger, the CodeAnt-unavailable fallback, BugBot's refused-HEAD and daily-cap guards, and racing claims
#
# WHAT IS UNDER TEST
#   The one helper every reviewer-trigger path asks before posting. Each
#   scenario stages a review-tier answer, the PR's comments, reviews, HEAD
#   check-runs and timeline, then asserts the per-reviewer decision.
#
# HOW IT IS OBSERVED
#   The REAL helper runs from a stub script dir beside the REAL ci-status.sh,
#   check-runs-dedup.sh, session-state.sh, state-lock.sh and
#   lib/codeant-round.jq — the gate's CodeAnt-round definition and the
#   build-CI rule are the shipped ones. Stubbed: review-tier.sh (each
#   scenario sets its answer), bugbot-refused-head.sh, review-daily-cap.sh,
#   and `gh`, which logs every call so "read nothing" is asserted positively.
#   HOME is a temp dir, so the ledger is a real, isolated session-state.json.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
TMP="$(mktemp -d)"
TMP_HOME="$(mktemp -d)"
cleanup() { rm -rf "$TMP" "$TMP_HOME"; }
trap cleanup EXIT
export HOME="$TMP_HOME"
mkdir -p "$HOME/.claude"

PASS=0
FAIL=0
check_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    PASS=$((PASS + 1)); echo "ok   — $desc"
  else
    FAIL=$((FAIL + 1)); echo "FAIL — $desc (expected '$expected', got '$actual')"
  fi
}

PR=4242
REPO=acme/one
HEAD="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
OLD="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

# ---- stub script dir ---------------------------------------------------------
S="$TMP/scripts"
mkdir -p "$S/lib"
for f in review-triggers-allowed.sh ci-status.sh check-runs-dedup.sh session-state.sh state-lock.sh; do
  cp "$REPO_ROOT/.claude/scripts/$f" "$S/"
done
cp "$REPO_ROOT/.claude/scripts/lib/repo-normalizer.sh" "$REPO_ROOT/.claude/scripts/lib/codeant-round.jq" "$S/lib/"
mkdir -p "$TMP/reference"
cp "$REPO_ROOT/.claude/reference/session-state-schema.json" "$TMP/reference/"
SUT="$S/review-triggers-allowed.sh"

cat > "$S/review-tier.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TIER_CALLS"
if [[ " $* " == *" --files-from "* ]]; then
  [[ -n "${FIXTURE_PROBE_OUT:-}" ]] && printf '%s\n' "$FIXTURE_PROBE_OUT"
  exit "${FIXTURE_PROBE_RC:-0}"
fi
[[ -n "${FIXTURE_TIER_OUT:-}" ]] && printf '%s\n' "$FIXTURE_TIER_OUT"
exit "${FIXTURE_TIER_RC:-0}"
EOF
cat > "$S/bugbot-refused-head.sh" <<'EOF'
#!/usr/bin/env bash
printf 'refused %s GH_REPO=%s\n' "$*" "${GH_REPO:-}" >> "$GUARD_CALLS"
# Race injection: another claimer bumps the cursor ledger AFTER this run's
# evaluation read it and BEFORE its CAS — exactly once.
if [[ -n "${FIXTURE_BUMP_CURSOR_TO:-}" && ! -e "$GUARD_CALLS.bumped" ]]; then
  : > "$GUARD_CALLS.bumped"
  bash "$(dirname "$0")/session-state.sh" --repo "$FIXTURE_REPO" \
    --set ".prs[\"$FIXTURE_PR\"].review_trigger_ledger.cursor.count=$FIXTURE_BUMP_CURSOR_TO" >/dev/null 2>&1
fi
[[ -n "${FIXTURE_REFUSED:-}" ]]
EOF
cat > "$S/review-daily-cap.sh" <<'EOF'
#!/usr/bin/env bash
if [[ " $* " == *" --rate "* ]]; then echo "${FIXTURE_RATE:-1.58}"; exit 0; fi
printf 'cap %s\n' "$*" >> "$GUARD_CALLS"
printf '%s\n' "${FIXTURE_CAP_OUT:-}"
exit "${FIXTURE_CAP_RC:-0}"
EOF
chmod +x "$S"/*.sh

# ---- gh stub -----------------------------------------------------------------
export FX="$TMP/fx"
mkdir -p "$FX" "$TMP/bin"
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_CALLS"
args="$*"
jqexpr=""; prev=""
for a in "$@"; do [[ "$prev" == "--jq" ]] && jqexpr="$a"; prev="$a"; done
serve() {
  [[ -n "${2:-}" ]] && { echo "HTTP 502" >&2; exit 1; }
  if [[ -n "$jqexpr" ]]; then jq -r "$jqexpr" "$1"; else cat "$1"; fi
}
case "$args" in
  "repo view"*) echo "acme/one" ;;
  "pr view"*)
    [[ -n "${FIXTURE_PR_FAIL:-}" ]] && exit 1
    printf '{"headRefOid":"%s","state":"%s"}\n' "$FIXTURE_HEAD" "${FIXTURE_PR_STATE:-OPEN}" ;;
  *"/issues/"*"/comments"*) serve "$FX/comments.json" "${FAIL_COMMENTS:-}" ;;
  *"/pulls/"*"/reviews"*) serve "$FX/reviews.json" "${FAIL_REVIEWS:-}" ;;
  *"/check-runs"*) serve "$FX/checks.json" "${FAIL_CHECKS:-}" ;;
  *"/timeline"*) serve "$FX/timeline.json" "${FAIL_TIMELINE:-}" ;;
  *"/commits/"*) serve "$FX/commit.json" "${FAIL_COMMIT:-}" ;;
  *) echo "unexpected gh call: $args" >&2; exit 1 ;;
esac
EOF
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"
export GH_CALLS="$TMP/gh-calls" TIER_CALLS="$TMP/tier-calls" GUARD_CALLS="$TMP/guard-calls"

# A real checkout to run from: the fail-closed probe and the config read look
# at it. Its origin is the PR's repo unless a scenario says otherwise.
WORK="$TMP/work"
mkdir -p "$WORK/.claude"
git -C "$WORK" init -q
git -C "$WORK" remote add origin https://github.com/acme/one.git

# ---- fixture builders ----------------------------------------------------------
ago() { jq -rn --argjson s "$1" 'now - $s | floor | todate'; }
tier_json() { # <policy> <gate> [escalation]
  printf '{"policy":"%s","gate":"%s","tier":"t","source":"base:main","error":null,"matches":[],"escalation":"%s"}' "$1" "$2" "${3:-on}"
}
run_check() { # <name> <conclusion|null> <slug> <started secs ago> [status]
  jq -cn --arg n "$1" --arg c "$2" --arg s "$3" --arg at "$(ago "$4")" --arg st "${5:-completed}" \
    '{id: ($n | length), name: $n, status: $st, conclusion: (if $c == "null" then null else $c end),
      check_suite: {id: 1}, app: {slug: $s, id: 1}, started_at: $at, created_at: $at}'
}
set_checks() { printf '{"check_runs":[%s]}' "$(IFS=,; echo "$*")" > "$FX/checks.json"; }
comment() { # <login> <body> <secs ago>
  jq -cn --arg l "$1" --arg b "$2" --arg at "$(ago "$3")" '{user: {login: $l}, body: $b, created_at: $at, updated_at: $at}'
}
set_comments() { printf '[%s]' "$(IFS=,; echo "$*")" > "$FX/comments.json"; }
review() { # <login> <state> <commit> <secs ago>
  jq -cn --arg l "$1" --arg st "$2" --arg c "$3" --arg at "$(ago "$4")" \
    '{user: {login: $l}, state: $st, commit_id: $c, submitted_at: $at, body: "x"}'
}
set_reviews() { printf '[%s]' "$(IFS=,; echo "$*")" > "$FX/reviews.json"; }

GREEN_OLD="$(run_check build success github-actions 7200)"
reset() { # <tier json> [tier rc]
  export FIXTURE_TIER_OUT="$1" FIXTURE_TIER_RC="${2:-0}"
  export FIXTURE_PROBE_OUT="" FIXTURE_PROBE_RC=0 FIXTURE_HEAD="$HEAD" FIXTURE_PR_STATE=OPEN FIXTURE_PR_FAIL=""
  export FIXTURE_REFUSED="" FIXTURE_CAP_OUT='{"platform":"bugbot","date":"2026-10-08","spent_usd":1,"add_usd":1.58,"cap_usd":10,"status":"ok"}' FIXTURE_CAP_RC=0
  export FIXTURE_BUMP_CURSOR_TO="" FIXTURE_REPO="$REPO" FIXTURE_PR="$PR"
  rm -f "$GUARD_CALLS.bumped"
  export FAIL_COMMENTS="" FAIL_REVIEWS="" FAIL_CHECKS="" FAIL_TIMELINE="" FAIL_COMMIT=""
  unset COMPLEXITY_TRIGGER_SETTLE_SECONDS COMPLEXITY_CODEANT_UNAVAILABLE_SECONDS
  rm -f "$HOME/.claude/session-state.json" "$WORK/.claude/pm-config.md"
  : > "$GH_CALLS"; : > "$TIER_CALLS"; : > "$GUARD_CALLS"
  set_comments; set_reviews; set_checks "$GREEN_OLD"
  echo '[]' > "$FX/timeline.json"
  jq -cn --arg d "$(ago 7200)" '{commit: {committer: {date: $d}}}' > "$FX/commit.json"
}
OUT=""; RC=0; ERR=""
run() { RC=0; OUT="$(cd "$WORK" && bash "$SUT" "$PR" --repo "$REPO" "$@" 2>"$TMP/err")" || RC=$?; ERR="$(cat "$TMP/err")"; }
f() { jq -r "$1" <<<"$OUT" 2>/dev/null; }
dec() { f ".reviewers.$1 | \"\(.kind):\(.reason)\""; }
ledger() { ( cd "$WORK" && bash "$S/session-state.sh" --repo "$REPO" --get-json ".prs[\"$PR\"].review_trigger_ledger.$1.count" 2>/dev/null ) || echo null; }

############################################################################
echo "== legacy: no ## Review policy -> pass-through, nothing else read =="
reset "$(tier_json absent legacy)"
run
check_eq "exit 0" "0" "$RC"
check_eq "mode legacy" "legacy" "$(f .mode)"
check_eq "no per-reviewer decisions" "null" "$(f .reviewers)"
check_eq "no gh call at all" "0" "$(grep -c . "$GH_CALLS" | tr -d ' ')"
check_eq "the resolver was asked about this PR and repo" "$PR --repo $REPO --json" "$(head -1 "$TIER_CALLS")"
run --claim cursor
check_eq "a legacy claim is a no-op that exits 0" "0:true" "$RC:$(f .claim.claimed)"
check_eq "  and writes no ledger" "null" "$(ledger cursor)"
reset "$(tier_json absent legacy off)"
run
check_eq "an ini-only (absent) policy is still legacy" "legacy" "$(f .mode)"
check_eq "  and reports its switch" "off" "$(f .escalation)"
reset "$(tier_json absent legacy)"
run --base develop
check_eq "--base is forwarded to the resolver" "$PR --repo $REPO --base develop --json" "$(head -1 "$TIER_CALLS")"

echo "== ci-only: every reviewer excluded, even with CI pending =="
reset "$(tier_json present ci-only)"
set_checks "$(run_check build null github-actions 30 in_progress)"
run
check_eq "mode tiered" "tiered" "$(f .mode)"
for r in codeant cursor coderabbit graphite; do
  check_eq "$r excluded" "excluded:tier_excluded" "$(dec "$r")"
done
check_eq "nothing allowed" "[]" "$(f '.allowed | tostring')"
check_eq "nothing deferred" "[]" "$(f '.deferred | tostring')"
check_eq "a docs PR costs no PR read at all" "0" "$(grep -c . "$GH_CALLS" | tr -d ' ')"
check_eq "  and reports CI as not read" "null" "$(f .ci)"

echo "== ci+codeant-one-round =="
reset "$(tier_json present ci+codeant-one-round)"
run
check_eq "no round, CI green: codeant allowed" "allowed:tier_allows" "$(dec codeant)"
check_eq "cursor excluded" "excluded:tier_excluded" "$(dec cursor)"
check_eq "coderabbit excluded" "excluded:tier_excluded" "$(dec coderabbit)"
check_eq "graphite excluded" "excluded:tier_excluded" "$(dec graphite)"
check_eq "allowed list" '["codeant"]' "$(f '.allowed | tostring')"

reset "$(tier_json present ci+codeant-one-round)"
set_reviews "$(review "codeant-ai[bot]" COMMENTED "$OLD" 3600)"
run
check_eq "a COMMENTED CodeAnt review on an older commit is a round" "excluded:round_completed" "$(dec codeant)"
reset "$(tier_json present ci+codeant-one-round)"
# Hoisted: bash 3.2 mis-parses escaped quotes inside a nested $( ).
RECORD_BODY="Status <!-- codeant-review-status:[{\"commit\":\"$OLD\",\"done\":true}] -->"
set_comments "$(comment "codeant-ai[bot]" "$RECORD_BODY" 3600)"
run
check_eq "a done run-record row is a round" "excluded:round_completed" "$(dec codeant)"
reset "$(tier_json present ci+codeant-one-round)"
set_reviews "$(review "codeant-ai[bot]" APPROVED "$HEAD" 60)"
run
check_eq "an APPROVED alone is not a round" "allowed:tier_allows" "$(dec codeant)"
reset "$(tier_json present ci+codeant-one-round)"
set_checks "$GREEN_OLD" "$(run_check "CodeAnt AI" neutral codeant-ai 600)"
run
check_eq "a completed codeant-ai check on HEAD is a round" "excluded:round_completed" "$(dec codeant)"
reset "$(tier_json present ci+codeant-one-round)"
set_comments "$(comment someone "@codeant-ai review" 3600)"
run
check_eq "one prior invitation: never re-invite" "excluded:lifetime_cap" "$(dec codeant)"
check_eq "  counted" "1" "$(f .reviewers.codeant.invitations)"
reset "$(tier_json present ci+codeant-one-round)"
set_comments "$(comment "codeant-ai[bot]" "@codeant-ai review" 3600)" "$(comment someone "please @codeant-ai review this" 3600)"
run
check_eq "the bot's own echo and a prose mention are not invitations" "allowed:0" "$(f '.reviewers.codeant | "\(.kind):\(.invitations)"')"
reset "$(tier_json present ci+codeant-one-round)"
set_comments "$(comment someone "  @codeant-ai review  " 3600)"
run
check_eq "a trimmed exact trigger counts" "excluded:lifetime_cap" "$(dec codeant)"

reset "$(tier_json present ci+codeant-one-round)"
set_checks "$(run_check build null github-actions 30 in_progress)"
run
check_eq "CI pending: codeant deferred" "deferred:ci_pending" "$(dec codeant)"
check_eq "  listed as deferred" '["codeant"]' "$(f '.deferred | tostring')"
reset "$(tier_json present ci+codeant-one-round)"
set_checks "$(run_check build failure github-actions 600)"
run
check_eq "CI red: codeant deferred" "deferred:ci_red" "$(dec codeant)"
reset "$(tier_json present ci+codeant-one-round)"
set_checks "$GREEN_OLD" "$(run_check "Cursor Bugbot" null cursor 30 in_progress)" "$(run_check "review" failure coderabbitai 30)"
run
check_eq "a pending/failed REVIEWER check does not hold CI" "allowed:tier_allows" "$(dec codeant)"
check_eq "  CI reads green" "green" "$(f .ci)"
reset "$(tier_json present ci+codeant-one-round)"
set_checks
run
check_eq "no check-runs at all: pending" "deferred:ci_pending" "$(dec codeant)"

echo "== full =="
reset "$(tier_json present full)"
run
check_eq "codeant allowed" "allowed:tier_allows" "$(dec codeant)"
check_eq "cursor allowed (green, settled, 0 invites)" "allowed:tier_allows" "$(dec cursor)"
check_eq "coderabbit is not needed while CodeAnt is fine" "excluded:not_fallback" "$(dec coderabbit)"
check_eq "graphite never on a tier-aware repo" "excluded:tier_excluded" "$(dec graphite)"
check_eq "settled" "true" "$(f .settled.settled)"
check_eq "threshold default 600" "600" "$(f .settled.threshold_s)"
check_eq "the refusal guard was asked about HEAD in this repo" "refused $PR $HEAD GH_REPO=$REPO" "$(grep '^refused' "$GUARD_CALLS")"
check_eq "the daily cap was asked with the rate" "cap bugbot --add-usd 1.58" "$(grep '^cap' "$GUARD_CALLS")"
check_eq "the tally rides on the cursor decision" "ok" "$(f .reviewers.cursor.daily_cap.status)"

reset "$(tier_json invalid full)"
run
check_eq "an invalid policy is tiered full" "tiered:full" "$(f '"\(.mode):\(.gate)"')"

reset "$(tier_json present full)"
set_comments "$(comment me "@cursor review" 3600)"
run
check_eq "cursor: one prior invitation still allowed" "allowed:1" "$(f '.reviewers.cursor | "\(.kind):\(.invitations)"')"
set_comments "$(comment me "@cursor review" 3600)" "$(comment me "@cursor review" 1800)"
: > "$GUARD_CALLS"
run
check_eq "cursor: two invitations is the cap" "excluded:lifetime_cap" "$(dec cursor)"
check_eq "  and neither BugBot guard was asked" "0" "$(grep -c . "$GUARD_CALLS" | tr -d ' ')"

reset "$(tier_json present full)"
set_checks "$(run_check build success github-actions 60)"
jq -cn --arg d "$(ago 60)" '{commit: {committer: {date: $d}}}' > "$FX/commit.json"
run
check_eq "HEAD observed 60s ago: cursor deferred" "deferred:head_not_settled" "$(dec cursor)"
check_eq "  codeant is not held by settling" "allowed:tier_allows" "$(dec codeant)"
check_eq "  neither BugBot guard was asked" "0" "$(grep -c . "$GUARD_CALLS" | tr -d ' ')"
export COMPLEXITY_TRIGGER_SETTLE_SECONDS=30
run
check_eq "env override 30s: settled" "allowed:tier_allows" "$(dec cursor)"
check_eq "  threshold reported" "30" "$(f .settled.threshold_s)"
export COMPLEXITY_TRIGGER_SETTLE_SECONDS=soon
run
check_eq "a junk override warns and keeps the default" "deferred:head_not_settled" "$(dec cursor)"
check_eq "  warned" "yes" "$( [[ "$ERR" == *"COMPLEXITY_TRIGGER_SETTLE_SECONDS='soon'"* ]] && echo yes || echo no )"
unset COMPLEXITY_TRIGGER_SETTLE_SECONDS
printf '## Complexity triggers\n\n```ini\nTRIGGER_SETTLE_SECONDS=45\n```\n\n## Notes\nTRIGGER_SETTLE_SECONDS=999999\n' > "$WORK/.claude/pm-config.md"
run
check_eq "pm-config key (section-scoped) sets 45s" "45:true" "$(f '"\(.settled.threshold_s):\(.settled.settled)"')"
export COMPLEXITY_TRIGGER_SETTLE_SECONDS=soon
run
check_eq "a junk override beside a valid pm-config value is the default, not 45" "600" "$(f .settled.threshold_s)"
unset COMPLEXITY_TRIGGER_SETTLE_SECONDS

reset "$(tier_json present full)"
set_checks "$(run_check build success github-actions 7200)"
jq -cn --arg d "$(ago 7200)" '{commit: {committer: {date: $d}}}' > "$FX/commit.json"
jq -cn --arg d "$(ago 120)" '[{event: "head_ref_force_pushed", created_at: $d}]' > "$FX/timeline.json"
run
check_eq "a force-push 2 min ago resets the clock" "deferred:head_not_settled" "$(dec cursor)"
reset "$(tier_json present full)"
set_checks "$GREEN_OLD"
export FAIL_TIMELINE=1
set_checks "$(run_check build success github-actions 7200)"
run
check_eq "timeline unreadable: never settled, though the check-run anchor is old" "deferred:head_not_settled" "$(dec cursor)"
check_eq "  codeant is not held by it" "allowed:tier_allows" "$(dec codeant)"
check_eq "  warned" "yes" "$( [[ "$ERR" == *"could not read PR #$PR's timeline"* ]] && echo yes || echo no )"
export FAIL_TIMELINE="" FAIL_COMMIT=1
run
check_eq "commit unreadable: never settled either" "deferred:head_not_settled" "$(dec cursor)"
export FAIL_COMMIT=""
run
check_eq "  control — both readable: the same old anchors settle" "allowed:tier_allows" "$(dec cursor)"

reset "$(tier_json present full)"
set_checks "$(run_check build null github-actions 30 in_progress)"
run
check_eq "CI pending: cursor deferred on CI first" "deferred:ci_pending" "$(dec cursor)"
check_eq "  codeant too" "deferred:ci_pending" "$(dec codeant)"

reset "$(tier_json present full off)"
run
check_eq "REVIEW_ESCALATION=off: cursor excluded" "excluded:escalation_off" "$(dec cursor)"
check_eq "  codeant still allowed" "allowed:tier_allows" "$(dec codeant)"

echo "== full: BugBot guards compose, the cap last =="
reset "$(tier_json present full)"
export FIXTURE_REFUSED=1
run
check_eq "refused HEAD: cursor excluded" "excluded:refused_head" "$(dec cursor)"
check_eq "  the cap was never asked" "0" "$(grep -c '^cap' "$GUARD_CALLS" | tr -d ' ')"
reset "$(tier_json present full)"
export FIXTURE_CAP_OUT='{"platform":"bugbot","date":"2026-10-08","spent_usd":9.5,"add_usd":1.58,"cap_usd":10,"status":"over"}' FIXTURE_CAP_RC=1
run
check_eq "daily cap over: cursor deferred" "deferred:daily_cap" "$(dec cursor)"
check_eq "  with the tally" "9.5" "$(f .reviewers.cursor.daily_cap.spent_usd)"
check_eq "  not in allowed" '["codeant"]' "$(f '.allowed | tostring')"
export FIXTURE_CAP_RC=0
run
check_eq "over with a disagreeing exit: unknown, allowed" "allowed:unknown" "$(f '.reviewers.cursor | "\(.kind):\(.daily_cap.status)"')"
export FIXTURE_CAP_OUT='{"platform":"bugbot","date":"2026-10-08","spent_usd":null,"add_usd":1.58,"cap_usd":10,"status":"unknown"}'
run
check_eq "unknown tally: allowed (fail open)" "allowed:tier_allows" "$(dec cursor)"
check_eq "  and says so" "yes" "$( [[ "$ERR" == *"daily cap is unknown"* ]] && echo yes || echo no )"
mv "$S/review-daily-cap.sh" "$TMP/cap.bak"
run
mv "$TMP/cap.bak" "$S/review-daily-cap.sh"
check_eq "cap helper missing: allowed, DEGRADED" "allowed:yes" "$(dec cursor | cut -d: -f1):$( [[ "$ERR" == *"DEGRADED: review-daily-cap.sh not found"* ]] && echo yes || echo no )"

echo "== full: CodeRabbit only as the CodeAnt-unavailable fallback =="
reset "$(tier_json present full)"
set_comments "$(comment me "@codeant-ai review" 600)"
run
check_eq "codeant invited 10 min ago: once only" "excluded:lifetime_cap" "$(dec codeant)"
check_eq "coderabbit waits inside the window" "deferred:codeant_pending" "$(dec coderabbit)"
check_eq "  availability not yet known" "null" "$(f .codeant.available)"
set_comments "$(comment me "@codeant-ai review" 2400)"
run
check_eq "40 min and no CodeAnt artifact: fallback allowed" "allowed:codeant_unavailable" "$(dec coderabbit)"
check_eq "  CodeAnt unavailable" "false" "$(f .codeant.available)"
export COMPLEXITY_CODEANT_UNAVAILABLE_SECONDS=3600
run
check_eq "timeout override 1h: still pending" "deferred:codeant_pending" "$(dec coderabbit)"
unset COMPLEXITY_CODEANT_UNAVAILABLE_SECONDS
set_comments "$(comment me "@codeant-ai review" 2400)" "$(comment "codeant-ai[bot]" "Reviewing…" 2300)"
run
check_eq "CodeAnt answered after the invitation: no fallback" "excluded:not_fallback" "$(dec coderabbit)"
check_eq "  available" "true" "$(f .codeant.available)"
set_comments "$(comment "codeant-ai[bot]" "old summary" 9000)" "$(comment me "@codeant-ai review" 2400)"
run
check_eq "a CodeAnt artifact from BEFORE the invitation is not an answer" "allowed:codeant_unavailable" "$(dec coderabbit)"
set_checks "$GREEN_OLD" "$(run_check "CodeAnt AI" null codeant-ai 30 in_progress)"
run
check_eq "a codeant-ai check on HEAD started after the invitation is an answer" "excluded:not_fallback" "$(dec coderabbit)"
set_checks "$GREEN_OLD" "$(run_check "CodeAnt AI" success codeant-ai 9000)"
run
check_eq "a codeant-ai check from BEFORE the invitation is not" "allowed:codeant_unavailable" "$(dec coderabbit)"
set_checks "$(run_check build failure github-actions 600)"
run
check_eq "the fallback still waits for green CI" "deferred:ci_red" "$(dec coderabbit)"

echo "== --head: a moved HEAD defers everything not statically excluded =="
reset "$(tier_json present full)"
run --head "$OLD"
check_eq "codeant deferred" "deferred:head_moved" "$(dec codeant)"
check_eq "cursor deferred" "deferred:head_moved" "$(dec cursor)"
check_eq "graphite still excluded" "excluded:tier_excluded" "$(dec graphite)"
run --head "${HEAD:0:7}"
check_eq "an abbreviated matching HEAD is the same HEAD" "allowed:tier_allows" "$(dec codeant)"

echo "== unreadable facts defer, never allow =="
reset "$(tier_json present full)"
export FAIL_COMMENTS=1
run
check_eq "exit 0" "0" "$RC"
check_eq "comments unreadable: codeant deferred" "deferred:facts_unreadable" "$(dec codeant)"
check_eq "  cursor deferred" "deferred:facts_unreadable" "$(dec cursor)"
reset "$(tier_json present ci-only)"
export FAIL_CHECKS=1
run
check_eq "static exclusions hold without facts" "excluded:tier_excluded" "$(dec codeant)"
reset "$(tier_json present full)"
export FIXTURE_PR_FAIL=1
run
check_eq "PR view unreadable: deferred" "deferred:facts_unreadable" "$(dec codeant)"
reset "$(tier_json present full)"
export FIXTURE_PR_STATE=MERGED
run
check_eq "a merged PR: excluded" "excluded:pr_not_open" "$(dec codeant)"

echo "== unresolvable tier: fail closed unless the checkout proves legacy =="
reset "" 4
export FIXTURE_PROBE_OUT="$(tier_json absent legacy)"
run
check_eq "resolver exit 4 + local checkout with no policy: legacy" "legacy" "$(f .mode)"
check_eq "  the probe ran offline" "yes" "$(grep -q -- '--files-from - --json' "$TIER_CALLS" && echo yes || echo no)"
check_eq "  and says why" "yes" "$( [[ "$ERR" == *"declares no ## Review policy"* ]] && echo yes || echo no )"
export FIXTURE_PROBE_OUT="$(tier_json present full)"
run
check_eq "resolver exit 4 + local policy section: fail_closed" "fail_closed" "$(f .mode)"
for r in codeant cursor coderabbit graphite; do
  check_eq "$r deferred tier_unresolved" "deferred:tier_unresolved" "$(dec "$r")"
done
check_eq "  no PR facts read" "0" "$(grep -c . "$GH_CALLS" | tr -d ' ')"
run --claim codeant
check_eq "a fail-closed claim is denied" "1" "$RC"
export FIXTURE_PROBE_OUT="" FIXTURE_PROBE_RC=4
run
check_eq "probe unreadable: fail_closed" "fail_closed" "$(f .mode)"
reset "not json"
export FIXTURE_PROBE_OUT="$(tier_json present ci-only)"
run
check_eq "unusable resolver output: probe, then fail_closed" "fail_closed" "$(f .mode)"
reset "" 4
export FIXTURE_PROBE_OUT="$(tier_json absent legacy)"
git -C "$WORK" remote set-url origin https://github.com/acme/other.git
run
git -C "$WORK" remote set-url origin https://github.com/acme/one.git
check_eq "checkout is another repo: no probe, fail_closed" "fail_closed:0" "$(f .mode):$(grep -c -- '--files-from' "$TIER_CALLS" | tr -d ' ')"
reset "" 3
run
check_eq "PR not found: exit 3" "3" "$RC"

echo "== --mode-only =="
reset "$(tier_json present full)"
run --mode-only
check_eq "tiered, and no PR fact read" "tiered:0" "$(f .mode):$(grep -c . "$GH_CALLS" | tr -d ' ')"

echo "== claims: the ledger bounds lifetime caps before GitHub lists a comment =="
reset "$(tier_json present ci+codeant-one-round)"
run --claim codeant
check_eq "first codeant claim: exit 0" "0:true" "$RC:$(f .claim.claimed)"
check_eq "  ledger count 1" "1" "$(ledger codeant)"
run --claim codeant
check_eq "second codeant claim (no comment visible yet): denied" "1:lifetime_cap" "$RC:$(f .reviewers.codeant.reason)"
check_eq "  ledger unchanged" "1" "$(ledger codeant)"
run
check_eq "a plain evaluation sees the ledger too" "excluded:lifetime_cap" "$(dec codeant)"
run --release codeant
check_eq "release after a failed post" "0:0" "$RC:$(ledger codeant)"
run --claim codeant
check_eq "  so the cap is free again" "0" "$RC"
run --claim cursor
check_eq "claiming an excluded reviewer: denied, nothing written" "1:null" "$RC:$(ledger cursor)"

reset "$(tier_json present full)"
run --claim codeant
check_eq "a codeant claim on full: claimed" "0:1" "$RC:$(ledger codeant)"
check_eq "  without spending BugBot's refusal lookup or cap tally" "0" "$(grep -c . "$GUARD_CALLS" | tr -d ' ')"

reset "$(tier_json present full)"
set_comments "$(comment me "@cursor review" 3600)"
run --claim cursor
check_eq "cursor: comment count 1 -> ledger 2" "0:2" "$RC:$(ledger cursor)"
run --claim cursor
check_eq "  then the cap" "1:lifetime_cap" "$RC:$(f .reviewers.cursor.reason)"
reset "$(tier_json present full)"
export FIXTURE_CAP_OUT='{"platform":"bugbot","date":"2026-10-08","spent_usd":9.5,"add_usd":1.58,"cap_usd":10,"status":"over"}' FIXTURE_CAP_RC=1
run --claim cursor
check_eq "a capped cursor claim is denied" "1:daily_cap:null" "$RC:$(f .reviewers.cursor.reason):$(ledger cursor)"

echo "== claims race: exactly one of four concurrent codeant claims wins =="
reset "$(tier_json present ci+codeant-one-round)"
for i in 1 2 3 4; do
  ( cd "$WORK" && bash "$SUT" "$PR" --repo "$REPO" --claim codeant >/dev/null 2>&1; echo "$?" > "$TMP/race.$i" ) &
done
wait
WINS=0
for i in 1 2 3 4; do [[ "$(cat "$TMP/race.$i")" == "0" ]] && WINS=$((WINS + 1)); done
check_eq "one winner" "1" "$WINS"
check_eq "ledger count 1" "1" "$(ledger codeant)"

echo "== a claim that lands between evaluation and CAS is caught, never claimed on a stale answer =="
reset "$(tier_json present full)"
set_comments "$(comment me "@cursor review" 3600)"
# This run evaluates cursor at 1 invitation (allowed); while its BugBot guards
# run, another claimer takes the second slot. The CAS must fail and the
# re-evaluation must see the cap.
export FIXTURE_BUMP_CURSOR_TO=2
run --claim cursor
check_eq "denied at the cap after re-evaluating" "1:lifetime_cap" "$RC:$(f .reviewers.cursor.reason)"
check_eq "  the other claimer's count stands, nothing over it" "2" "$(ledger cursor)"
check_eq "  the first pass reached the guards; the re-evaluation stopped at the cap before them" "1" "$(grep -c '^refused' "$GUARD_CALLS" | tr -d ' ')"

echo "== usage =="
RC=0; bash "$SUT" >/dev/null 2>&1 || RC=$?
check_eq "no PR: exit 2" "2" "$RC"
RC=0; bash "$SUT" 12 --claim bugbot >/dev/null 2>&1 || RC=$?
check_eq "unknown reviewer: exit 2" "2" "$RC"
RC=0; bash "$SUT" 12 --claim cursor --release cursor >/dev/null 2>&1 || RC=$?
check_eq "claim + release: exit 2" "2" "$RC"
RC=0; bash "$SUT" 12 --head 'zz;rm' >/dev/null 2>&1 || RC=$?
check_eq "a non-SHA --head: exit 2" "2" "$RC"
check_eq "--help prints the header" "yes" "$(grep -q '^PURPOSE' <<<"$(bash "$SUT" --help)" && echo yes || echo no)"

echo
echo "== summary: $PASS passed, $FAIL failed =="
[[ "$FAIL" -eq 0 ]] || exit 1
echo "OK: review-triggers-allowed.sh tests passed"
