#!/usr/bin/env bash
# merge-gate-review-tier.test.sh — Offline tests for per-repo review tiers in
# merge-gate.sh (issue #1726, part of #1724).
# catalog: tests — Tests per-repo review tiers in `merge-gate.sh` — ci-only, ci+codeant-one-round, full/legacy parity, resolver failure
#
# Covers:
#   - No `## Review policy` → legacy: the reviewer gate is exactly today's
#   - ci-only: CI green meets the gate with no reviewer; red CI and an
#     unresolved thread still block
#   - ci+codeant-one-round: a completed CodeAnt round on ANY commit meets it —
#     a `done` run-record row, a COMMENTED/CHANGES_REQUESTED review, or a
#     completed CodeAnt check-run on HEAD; an APPROVED alone does not
#   - full behaves like legacy; an invalid policy resolves to full
#   - a resolver failure blocks with its own reason AND runs the full gate
#   - the policy comes from the base branch only: an environment variable
#     cannot re-point it
#   - `review_tier` output shape
#
# Built on tests/lib/merge-gate-test-fixtures.sh without editing it: the fixture's
# fake gh is kept as gh.base, and a wrapper answers only the calls the tier
# resolver makes (the base-branch pm-config read, the PR's labels/file listing)
# plus an optional review-thread payload, delegating everything else.
# Run from repo root: bash .claude/scripts/tests/merge-gate-review-tier.test.sh
# shellcheck source=tests/lib/merge-gate-test-fixtures.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/merge-gate-test-fixtures.sh"

mv "$BIN/gh" "$BIN/gh.base"
cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
ARGS=" $* "
jq_arg() { local prev="" a; for a in "$@"; do [[ "$prev" == "--jq" ]] && { printf '%s' "$a"; return; }; prev="$a"; done; }
case "$ARGS" in
  *" repos/solo/repo/contents/.claude/pm-config.md "*)
    [[ "${FAKE_TIER_FAIL:-0}" == "1" ]] && { echo "gh: Server Error (HTTP 500)" >&2; exit 1; }
    [[ -z "${FAKE_PM_CONFIG:-}" ]] && { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
    case "$ARGS" in *" ref=main "*) ;; *) echo "fake gh: pm-config read not pinned to the base ref: $*" >&2; exit 96 ;; esac
    jq -cn --arg c "$(printf '%s' "$FAKE_PM_CONFIG" | base64 | tr -d '\n')" \
      '{type:"file", encoding:"base64", content:$c}'
    exit 0 ;;
  *" pr view 1 --repo solo/repo --json labels,changedFiles "*)
    jq -cn --argjson files "${FAKE_PR_FILES_JSON:-[]}" --argjson labels "${FAKE_LABELS:-[]}" \
      '{labels: $labels, changedFiles: ($files | length)}'
    exit 0 ;;
  *" repos/solo/repo/pulls/1/files?per_page=100 "*)
    case "$ARGS" in *" --paginate "*) ;; *) echo "fake gh: files call must paginate" >&2; exit 96 ;; esac
    jq -r "$(jq_arg "$@")" <<<"${FAKE_PR_FILES_JSON:-[]}"
    exit 0 ;;
  *graphql*)
    if [[ -n "${FAKE_THREADS:-}" ]]; then
      jq -cn --argjson nodes "$FAKE_THREADS" \
        '{data:{repository:{pullRequest:{reviewThreads:{pageInfo:{hasNextPage:false, endCursor:null}, nodes:$nodes}}}}}'
      exit 0
    fi ;;
esac
exec "$(dirname "$0")/gh.base" "$@"
EOF
chmod +x "$BIN/gh"

OUT=""
RC=0
GREEN="$(bundle "$(cr 1 "hook-tests" success 100)")"
run_gate() { # env: FAKE_* ; $1 = check-runs bundle (default: one green check)
  OUT=$(PATH="$BIN:$PATH" FAKE_CHECK_RUNS="${1:-$GREEN}" \
        FAKE_REVIEWS="${FAKE_REVIEWS:-[]}" \
        FAKE_PR_COMMENTS="${FAKE_PR_COMMENTS:-[]}" \
        FAKE_ISSUE_COMMENTS="${FAKE_ISSUE_COMMENTS:-[]}" \
        "$SUT" 1 2>/dev/null)
  RC=$?
}
has_missing() { # substring
  echo "$OUT" | jq -e --arg s "$1" '[.missing[]? | select(contains($s))] | length > 0' >/dev/null && echo yes || echo no
}

POLICY='# PM Config

## Review policy

| Tier | Gate | Paths | Labels |
|------|------|-------|--------|
| core | full | src/ledger/** | tier:core |
| leaf | ci+codeant-one-round | src/adapters/** | |
| docs | ci-only | docs/**, *.md | |
'
DOCS_FILES='[{"filename":"docs/guide.md"}]'
LEAF_FILES='[{"filename":"src/adapters/fake.ts"}]'
CORE_FILES='[{"filename":"src/ledger/post.ts"}]'
NEED_APPROVAL="need 1 explicit CodeRabbit or CodeAnt APPROVED review"
NO_ROUND="no completed CodeAnt round on any commit"
OLD_SHA="0123456789abcdef0123456789abcdef01234567"

# -------------------------------------------------------------- legacy -----
unset FAKE_PM_CONFIG FAKE_PR_FILES_JSON FAKE_THREADS FAKE_TIER_FAIL
run_gate
check_eq "1"      "$RC"                                        "legacy: no approval → exit 1"
check_eq "yes"    "$(has_missing "$NEED_APPROVAL")"            "legacy: the reviewer requirement is today's"
check_eq "legacy" "$(echo "$OUT" | jq -r '.review_tier.gate')" "legacy: review_tier.gate"
check_eq "absent" "$(echo "$OUT" | jq -r '.review_tier.policy')" "legacy: review_tier.policy"
check_eq "null"   "$(echo "$OUT" | jq -r '.review_tier.tier')" "legacy: review_tier.tier is null"
check_eq "review_tier" "$(echo "$OUT" | jq -r 'keys_unsorted | last')" "review_tier is appended after every existing key"
check_eq "no"     "$(has_missing "review tier")"               "legacy: no tier reason added"

# ------------------------------------------------------------- ci-only -----
export FAKE_PM_CONFIG="$POLICY"
FAKE_PR_FILES_JSON="$DOCS_FILES" run_gate
check_eq "0"       "$RC"                                         "ci-only: green CI, no reviews → gate met"
check_eq "ci-only" "$(echo "$OUT" | jq -r '.review_tier.gate')"  "ci-only: review_tier.gate"
check_eq "docs"    "$(echo "$OUT" | jq -r '.review_tier.tier')"  "ci-only: review_tier.tier names the row"
check_eq "false"   "$(echo "$OUT" | jq -r '.primary_review_met')" "ci-only: primary_review_met keeps its meaning (no approval exists)"
check_eq "cr"      "$(echo "$OUT" | jq -r '.reviewer')"          "ci-only: reviewer field unchanged"

FAKE_PR_FILES_JSON="$DOCS_FILES" run_gate "$(bundle "$(cr 1 "hook-tests" failure 100)")"
check_eq "1"   "$RC"                                "ci-only: red CI still blocks"
check_eq "yes" "$(has_missing "failing check-run")" "ci-only: the CI reason is today's"

FAKE_THREADS='[{"isResolved":false,"comments":{"nodes":[{"databaseId":7,"author":{"login":"codeant-ai"}}]}}]' \
  FAKE_PR_FILES_JSON="$DOCS_FILES" run_gate
check_eq "1"   "$RC"                                          "ci-only: an unresolved thread still blocks"
check_eq "yes" "$(has_missing "1 unresolved review thread")" "ci-only: the thread reason is today's"

# ------------------------------------------------ ci+codeant-one-round -----
FAKE_PR_FILES_JSON="$LEAF_FILES" run_gate
check_eq "1"   "$RC"                            "codeant-one-round: no CodeAnt round → blocked"
check_eq "yes" "$(has_missing "$NO_ROUND")"     "codeant-one-round: names the missing round"
check_eq "no"  "$(has_missing "$NEED_APPROVAL")" "codeant-one-round: no CodeRabbit/CodeAnt APPROVED requirement"
check_eq "ci+codeant-one-round" "$(echo "$OUT" | jq -r '.review_tier.gate')" "codeant-one-round: review_tier.gate"

# A pre-run stub APPROVED is not a round (#1365, #1432).
FAKE_REVIEWS="$(jq -cn --arg sha "$HEAD_SHA" '[{id:1, user:{login:"codeant-ai[bot]", type:"Bot"}, state:"APPROVED", commit_id:$sha, submitted_at:"2026-07-21T10:00:00Z", body:""}]')" \
  FAKE_PR_FILES_JSON="$LEAF_FILES" run_gate
check_eq "1"   "$RC"                        "codeant-one-round: an APPROVED alone is not a round"
check_eq "yes" "$(has_missing "$NO_ROUND")" "codeant-one-round: stub approval still names the missing round"

# (a) a done row in CodeAnt's run record — on an OLDER commit.
RECORD="<!-- codeant-review-status:[{\"label\":\"Reviewed your PR\",\"commit\":\"$OLD_SHA\",\"started\":\"2026-07-21T09:00:00.1\",\"finished\":\"2026-07-21T09:05:00.1\",\"done\":true}] -->"
FAKE_ISSUE_COMMENTS="$(jq -cn --arg b "🤖 CodeAnt AI — Review Status $RECORD" '[{id:9, user:{login:"codeant-ai[bot]"}, body:$b, created_at:"2026-07-21T09:05:00Z", updated_at:"2026-07-21T09:05:00Z"}]')" \
  FAKE_PR_FILES_JSON="$LEAF_FILES" run_gate
check_eq "0" "$RC" "codeant-one-round: a done run-record row on an older commit meets it"

RECORD_RUNNING="${RECORD/\"done\":true/\"done\":false}"
FAKE_ISSUE_COMMENTS="$(jq -cn --arg b "🤖 CodeAnt AI — Review Status $RECORD_RUNNING" '[{id:9, user:{login:"codeant-ai[bot]"}, body:$b, created_at:"2026-07-21T09:05:00Z", updated_at:"2026-07-21T09:05:00Z"}]')" \
  FAKE_PR_FILES_JSON="$LEAF_FILES" run_gate
check_eq "1" "$RC" "codeant-one-round: an in-flight (done:false) row is not a round"

FAKE_ISSUE_COMMENTS="$(jq -cn --arg b "quoting CodeAnt: $RECORD" '[{id:9, user:{login:"someone"}, body:$b, created_at:"2026-07-21T09:05:00Z", updated_at:"2026-07-21T09:05:00Z"}]')" \
  FAKE_PR_FILES_JSON="$LEAF_FILES" run_gate
check_eq "1" "$RC" "codeant-one-round: a run record quoted by someone else is not a round"

# (b) a COMMENTED review on an older commit — CodeAnt posted findings, so it ran.
FAKE_REVIEWS="$(jq -cn --arg sha "$OLD_SHA" '[{id:2, user:{login:"codeant-ai[bot]", type:"Bot"}, state:"COMMENTED", commit_id:$sha, submitted_at:"2026-07-21T09:00:00Z", body:"2 findings"}]')" \
  FAKE_PR_FILES_JSON="$LEAF_FILES" run_gate
check_eq "0" "$RC" "codeant-one-round: a COMMENTED review on an older commit meets it"

# (c) a completed CodeAnt check-run on HEAD.
FAKE_PR_FILES_JSON="$LEAF_FILES" run_gate "$(bundle "$(cr 1 "hook-tests" success 100)" "$(cr 2 "CodeAnt AI" neutral 200 codeant-ai)")"
check_eq "0" "$RC" "codeant-one-round: a completed CodeAnt check-run on HEAD meets it"
FAKE_PR_FILES_JSON="$LEAF_FILES" run_gate "$(bundle "$(cr 1 "hook-tests" success 100)" "$(cr 2 "CodeAnt AI" cancelled 200 codeant-ai)")"
check_eq "1" "$RC" "codeant-one-round: a cancelled CodeAnt check-run is not a round"
# A check NAME is not identity: any workflow can name a job "CodeAnt AI".
FAKE_PR_FILES_JSON="$LEAF_FILES" run_gate "$(bundle "$(cr 1 "hook-tests" success 100)" "$(cr 2 "CodeAnt AI" success 200 github-actions)")"
check_eq "1" "$RC" "codeant-one-round: a check named CodeAnt from another app is not a round"
FAKE_PR_FILES_JSON="$LEAF_FILES" run_gate "$(bundle "$(cr 1 "hook-tests" success 100)" "$(cr 2 "review" success 200 codeant-ai-fork)")"
check_eq "1" "$RC" "codeant-one-round: a look-alike app slug is not a round"

# ---------------------------------------------------------------- full -----
FAKE_PR_FILES_JSON="$CORE_FILES" run_gate
check_eq "1"    "$RC"                                         "full: no approval → blocked"
check_eq "yes"  "$(has_missing "$NEED_APPROVAL")"             "full: the reviewer requirement is today's"
check_eq "full" "$(echo "$OUT" | jq -r '.review_tier.gate')"  "full: review_tier.gate"
check_eq "core" "$(echo "$OUT" | jq -r '.review_tier.tier')"  "full: review_tier.tier"

# A docs PR carrying the core label is core.
FAKE_LABELS='[{"name":"tier:core"}]' FAKE_PR_FILES_JSON="$DOCS_FILES" run_gate
check_eq "full" "$(echo "$OUT" | jq -r '.review_tier.gate')" "a stricter label raises a docs PR to full"

# An invalid policy fails closed to full.
FAKE_PM_CONFIG='# PM Config

## Review policy

| Tier | Gate | Paths |
|---|---|---|
| docs | ci-only-please | docs/** |
' FAKE_PR_FILES_JSON="$DOCS_FILES" run_gate
check_eq "full"    "$(echo "$OUT" | jq -r '.review_tier.gate')"   "invalid policy → full"
check_eq "invalid" "$(echo "$OUT" | jq -r '.review_tier.policy')" "invalid policy → review_tier.policy invalid"
check_eq "yes"     "$(has_missing "$NEED_APPROVAL")"              "invalid policy → the full reviewer gate runs"

# ---------------------------------------------------- resolver failure -----
FAKE_TIER_FAIL=1 FAKE_PR_FILES_JSON="$DOCS_FILES" run_gate
check_eq "1"    "$RC"                                     "resolver failure: gate not met (exit 1, not 4)"
check_eq "yes"  "$(has_missing "review tier unresolved")" "resolver failure: its own reason"
check_eq "yes"  "$(has_missing "$NEED_APPROVAL")"         "resolver failure: the full reviewer gate still runs"
check_eq "null" "$(echo "$OUT" | jq -c '.review_tier')"   "resolver failure: review_tier is null"

# ------------------------------------------------ no ambient override ------
LENIENT="$TMP/lenient.md"
printf '# PM Config\n\n## Review policy\n\n| Tier | Gate |\n|---|---|\n| default | ci-only |\n' > "$LENIENT"
unset FAKE_PM_CONFIG
CLAUDE_REVIEW_POLICY_FILE="$LENIENT" FAKE_PR_FILES_JSON="$CORE_FILES" run_gate
check_eq "legacy" "$(echo "$OUT" | jq -r '.review_tier.gate')" "CLAUDE_REVIEW_POLICY_FILE cannot re-point the gate"
check_eq "1"      "$RC"                                        "…and the approval requirement stands"

echo
echo "merge-gate-review-tier.test.sh: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
