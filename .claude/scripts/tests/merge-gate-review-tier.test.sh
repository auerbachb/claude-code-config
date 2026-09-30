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
#   - deferred findings (issue #1727): on the two lighter tiers a human reply
#     linking an issue of this repo clears its thread; `full`/`legacy` never
#     defer; a bot reply, a PR number, another repo, a 404, and a failed
#     lookup all keep the thread blocking; `deferred_thread_count` and
#     `deferred_issues` shape; one lookup per number per run
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
  *" api repos/solo/repo/issues/"*)
    # Follow-up-issue lookups (issue #1727). FAKE_ISSUE_KINDS maps a number to
    # issue | pr | fail; anything else is a 404. Every lookup is logged.
    N="${ARGS##* api repos/solo/repo/issues/}"; N="${N%% *}"
    if [[ "$N" =~ ^[0-9]+$ ]]; then
      [[ -n "${FAKE_ISSUE_LOG:-}" ]] && echo "$N" >> "$FAKE_ISSUE_LOG"
      KINDS="${FAKE_ISSUE_KINDS:-}"; [[ -z "$KINDS" ]] && KINDS='{}'
      case "$(jq -r --arg n "$N" '.[$n] // "absent"' <<<"$KINDS")" in
        issue) jq -cn --argjson n "$N" '{number:$n, repository_url:"https://api.github.com/repos/solo/repo"}'; exit 0 ;;
        pr)    jq -cn --argjson n "$N" '{number:$n, repository_url:"https://api.github.com/repos/solo/repo", pull_request:{url:"x"}}'; exit 0 ;;
        moved) jq -cn --argjson n "$N" '{number:$n, repository_url:"https://api.github.com/repos/solo/elsewhere"}'; exit 0 ;;
        fail)  echo "gh: Server Error (HTTP 502)" >&2; exit 1 ;;
        *)     echo '{"message":"Not Found"}'; echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
      esac
    fi ;;
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
check_eq "review_tier" "$(echo "$OUT" | jq -r 'keys_unsorted | .[-3]')" "review_tier is appended after every pre-#1726 key"
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

# A CHANGES_REQUESTED review also proves a round ran, and does not block by
# itself — its findings arrive as threads, which the thread check governs.
FAKE_REVIEWS="$(jq -cn --arg sha "$OLD_SHA" '[{id:3, user:{login:"codeant-ai[bot]", type:"Bot"}, state:"CHANGES_REQUESTED", commit_id:$sha, submitted_at:"2026-07-21T09:00:00Z", body:"2 findings"}]')" \
  FAKE_PR_FILES_JSON="$LEAF_FILES" run_gate
check_eq "0" "$RC" "codeant-one-round: a CHANGES_REQUESTED review on an older commit meets it without blocking"

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

# ------------------------------------ deferred findings (issue #1727) ------
# A bot finding plus one reply. $1 = the reply author's GraphQL __typename,
# $2 = its login, $3 = its body. GraphQL bot logins carry no `[bot]` suffix.
thread() {
  jq -cn --arg t "$1" --arg l "$2" --arg b "$3" '{isResolved:false, comments:{nodes:[
    {databaseId:7, body:"Consider renaming this helper.", author:{login:"coderabbitai", __typename:"Bot"}},
    {databaseId:8, body:$b, author:{login:$l, __typename:$t}}]}}'
}
threads() { printf '[%s]' "$(IFS=,; echo "$*")"; }
lookups() { # the issue numbers looked up since the last reset, comma-joined
  if [[ -s "$FAKE_ISSUE_LOG" ]]; then paste -sd, "$FAKE_ISSUE_LOG"; fi
}
reset_log() { : > "$FAKE_ISSUE_LOG"; }
field() { echo "$OUT" | jq -c "$1"; }
THREAD_REASON="1 unresolved review thread(s) — resolve via GraphQL before merge"
has_exact() { # exact missing[] entry
  echo "$OUT" | jq -e --arg s "$1" '(.missing // []) | index($s) != null' >/dev/null && echo yes || echo no
}
CODEANT_ROUND="$(jq -cn --arg sha "$OLD_SHA" '[{id:2, user:{login:"codeant-ai[bot]", type:"Bot"}, state:"COMMENTED", commit_id:$sha, submitted_at:"2026-07-21T09:00:00Z", body:"2 findings"}]')"
export FAKE_PM_CONFIG="$POLICY"
export FAKE_ISSUE_LOG="$TMP/issue-lookups.log"
export FAKE_ISSUE_KINDS='{"12":"issue","13":"pr","14":"fail","16":"moved","21":"issue"}'
HUMAN_DEFER="$(threads "$(thread User solouser "Deferred to #12 — not severe.")")"

# ci-only: a human reply linking an issue clears the thread.
reset_log; FAKE_THREADS="$HUMAN_DEFER" FAKE_PR_FILES_JSON="$DOCS_FILES" run_gate
check_eq "0"    "$RC"                                "deferred ci-only: human 'Deferred to #12' → gate met"
check_eq "0"    "$(field '.unresolved_thread_count')" "deferred ci-only: unresolved_thread_count is the blocking count"
check_eq "1"    "$(field '.deferred_thread_count')"   "deferred ci-only: deferred_thread_count"
check_eq "[12]" "$(field '.deferred_issues')"         "deferred ci-only: deferred_issues"
check_eq "12"   "$(lookups)"                          "deferred ci-only: the issue was verified"

# ci+codeant-one-round: the same, once CodeAnt's round is in.
reset_log; FAKE_REVIEWS="$CODEANT_ROUND" FAKE_THREADS="$HUMAN_DEFER" FAKE_PR_FILES_JSON="$LEAF_FILES" run_gate
check_eq "0"    "$RC"                                "deferred codeant-one-round: human 'Deferred to #12' → gate met"
check_eq "1"    "$(field '.deferred_thread_count')"   "deferred codeant-one-round: deferred_thread_count"
check_eq "[12]" "$(field '.deferred_issues')"         "deferred codeant-one-round: deferred_issues"

# full and legacy: a follow-up link changes nothing, and nothing is looked up.
reset_log; FAKE_THREADS="$HUMAN_DEFER" FAKE_PR_FILES_JSON="$CORE_FILES" run_gate
check_eq "yes" "$(has_exact "$THREAD_REASON")"       "deferred full: the thread still blocks, reason unchanged"
check_eq "1"   "$(field '.unresolved_thread_count')" "deferred full: unresolved_thread_count unchanged"
check_eq "0"   "$(field '.deferred_thread_count')"   "deferred full: deferred_thread_count is 0"
check_eq "[]"  "$(field '.deferred_issues')"         "deferred full: deferred_issues is []"
check_eq ""    "$(lookups)"                          "deferred full: no issue lookup"
reset_log; FAKE_PM_CONFIG="" FAKE_THREADS="$HUMAN_DEFER" FAKE_PR_FILES_JSON="$DOCS_FILES" run_gate
check_eq "legacy" "$(field '.review_tier.gate' | tr -d '"')" "deferred legacy: fixture resolves to legacy"
check_eq "yes" "$(has_exact "$THREAD_REASON")"       "deferred legacy: the thread still blocks"
check_eq "0"   "$(field '.deferred_thread_count')"   "deferred legacy: deferred_thread_count is 0"
check_eq ""    "$(lookups)"                          "deferred legacy: no issue lookup"

# Replies that never qualify.
reset_log; FAKE_THREADS="$(threads "$(thread Bot coderabbitai "Tracked in #12.")")" FAKE_PR_FILES_JSON="$DOCS_FILES" run_gate
check_eq "yes" "$(has_exact "$THREAD_REASON")" "deferred: a bot reply linking an issue blocks"
check_eq ""    "$(lookups)"                    "deferred: a bot reply is never looked up"
reset_log; FAKE_THREADS="$(threads "$(thread User solouser "Deferred to #13.")")" FAKE_PR_FILES_JSON="$DOCS_FILES" run_gate
check_eq "yes" "$(has_exact "$THREAD_REASON")"        "deferred: #N naming a PR blocks"
check_eq "13"  "$(lookups)"                           "deferred: the PR number was checked"
check_eq "no"  "$(has_missing "could not be verified")" "deferred: a PR is a clean no, not a lookup failure"
reset_log; FAKE_THREADS="$(threads "$(thread User solouser "Deferred to other/repo#12.")")" FAKE_PR_FILES_JSON="$DOCS_FILES" run_gate
check_eq "yes" "$(has_exact "$THREAD_REASON")" "deferred: a cross-repo owner/repo#N blocks"
check_eq ""    "$(lookups)"                    "deferred: a cross-repo reference is never looked up"
reset_log; FAKE_THREADS="$(threads "$(thread User solouser "See https://github.com/other/repo/issues/12")")" FAKE_PR_FILES_JSON="$DOCS_FILES" run_gate
check_eq "yes" "$(has_exact "$THREAD_REASON")" "deferred: a cross-repo issue URL blocks"
reset_log; FAKE_THREADS="$(threads "$(thread User solouser "See https://github.com/solo/repo/pull/12")")" FAKE_PR_FILES_JSON="$DOCS_FILES" run_gate
check_eq "yes" "$(has_exact "$THREAD_REASON")" "deferred: a /pull/ URL blocks"
check_eq ""    "$(lookups)"                    "deferred: a /pull/ URL is never looked up"
reset_log; FAKE_THREADS="$(threads "$(thread User solouser "Deferred to #14.")")" FAKE_PR_FILES_JSON="$DOCS_FILES" run_gate
check_eq "1"   "$RC"                                              "deferred: an issue lookup failure blocks"
check_eq "yes" "$(has_exact "$THREAD_REASON")"                    "deferred: lookup failure leaves the thread blocking"
check_eq "yes" "$(has_missing "follow-up issue #14 could not be verified")" "deferred: lookup failure has its own reason"
reset_log; FAKE_THREADS="$(threads "$(thread User solouser "Deferred to #15.")")" FAKE_PR_FILES_JSON="$DOCS_FILES" run_gate
check_eq "yes" "$(has_exact "$THREAD_REASON")"          "deferred: a 404 blocks"
check_eq "no"  "$(has_missing "could not be verified")" "deferred: a 404 is a clean no, not a lookup failure"
reset_log; FAKE_THREADS="$(threads "$(thread User solouser "Deferred to #16.")")" FAKE_PR_FILES_JSON="$DOCS_FILES" run_gate
check_eq "yes" "$(has_exact "$THREAD_REASON")"          "deferred: an issue transferred to another repo blocks"
check_eq "no"  "$(has_missing "could not be verified")" "deferred: a transferred issue is a clean no, not a lookup failure"
reset_log; FAKE_THREADS="$(threads "$(thread User solouser "> Same root cause as #12.

Will fix in the next push.")")" FAKE_PR_FILES_JSON="$DOCS_FILES" run_gate
check_eq "yes" "$(has_exact "$THREAD_REASON")" "deferred: a number only inside a quoted line blocks"
check_eq ""    "$(lookups)"                    "deferred: a quoted number is never looked up"
reset_log; FAKE_THREADS="$(jq -cn '[{isResolved:false, comments:{nodes:[{databaseId:7, body:"Tracked in #12", author:{login:"solouser", __typename:"User"}}]}}]')" \
  FAKE_PR_FILES_JSON="$DOCS_FILES" run_gate
check_eq "yes" "$(has_exact "$THREAD_REASON")" "deferred: a link in the finding itself (no reply) blocks"
reset_log; FAKE_THREADS="$(jq -cn '[{isResolved:false, comments:{nodes:[{databaseId:7, author:{login:"coderabbitai"}}, {databaseId:8, body:"Deferred to #12", author:{login:"solouser"}}]}}]')" \
  FAKE_PR_FILES_JSON="$DOCS_FILES" run_gate
check_eq "yes" "$(has_exact "$THREAD_REASON")" "deferred: a reply with no author __typename blocks"

# The other accepted forms, and a mixed page.
reset_log; FAKE_THREADS="$(threads "$(thread User solouser "Deferred to Solo/Repo#12")")" FAKE_PR_FILES_JSON="$DOCS_FILES" run_gate
check_eq "0" "$RC" "deferred: same-repo owner/repo#N (any case) qualifies"
reset_log; FAKE_THREADS="$(threads "$(thread User solouser "Tracked in https://github.com/solo/repo/issues/12#issuecomment-1")")" FAKE_PR_FILES_JSON="$DOCS_FILES" run_gate
check_eq "0" "$RC" "deferred: the issue URL form qualifies"
reset_log; FAKE_THREADS="$(threads "$(thread User solouser "Deferred to #14 and #21")")" FAKE_PR_FILES_JSON="$DOCS_FILES" run_gate
check_eq "0"    "$RC"                          "deferred: one verified issue suffices even if another lookup fails"
check_eq "[21]" "$(field '.deferred_issues')"  "deferred: deferred_issues lists only verified issues"
reset_log; FAKE_THREADS="$(threads "$(thread User solouser "Deferred to #12")" "$(thread User reviewer2 "Also #12")" "$(thread User solouser "Will fix.")")" \
  FAKE_PR_FILES_JSON="$DOCS_FILES" run_gate
check_eq "1"    "$RC"                                "deferred: one undeferred thread still blocks"
check_eq "yes"  "$(has_exact "$THREAD_REASON")"      "deferred: the thread reason is byte-identical, with the blocking count"
check_eq "1"    "$(field '.unresolved_thread_count')" "deferred: unresolved_thread_count counts only the blocking thread"
check_eq "2"    "$(field '.deferred_thread_count')"   "deferred: deferred_thread_count counts both deferred threads"
check_eq "[12]" "$(field '.deferred_issues')"         "deferred: deferred_issues is unique"
check_eq "12"   "$(lookups)"                          "deferred: each number is looked up once per run"
check_eq '["deferred_thread_count","deferred_issues"]' "$(echo "$OUT" | jq -c 'keys_unsorted | .[-2:]')" \
  "deferred fields are appended after review_tier"

echo
echo "merge-gate-review-tier.test.sh: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
