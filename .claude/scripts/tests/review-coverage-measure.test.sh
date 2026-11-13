#!/usr/bin/env bash
# catalog: tests — Offline fixture test for review-coverage-measure.sh: each class, the unknown path, the threshold decision, and the usage exits
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SUT="$ROOT/.claude/scripts/review-coverage-measure.sh"

PASS=0
FAIL=0
check() {
  if [ "$2" = "$3" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s (expected %s, got %s)\n' "$1" "$2" "$3" >&2
  fi
}

TMP=$(mktemp -d "${TMPDIR:-/tmp}/review-coverage-measure-test.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT
CACHE="$TMP/cache"
mkdir -p "$CACHE"

# Review objects. A body of 200 characters is substantive; an empty body is hollow.
LONG=$(printf 'x%.0s' $(seq 1 200))
REAL_BODY="Reviewed the change set end to end: $LONG"
WALK="Walkthrough of the changed files and findings: $LONG"

# Population: eight merged PRs with their head SHAs and file counts. Most merge
# after every fixture review; PR 108 merges before its approval, which must not count.
jq -n '[
  {number: 101, mergedAt: "2026-11-30T12:00:00Z", headRefOid: "aaa1", changedFiles: 3, labels: []},
  {number: 102, mergedAt: "2026-11-30T12:00:00Z", headRefOid: "bbb2", changedFiles: 2, labels: [{name: "merged-unreviewed"}]},
  {number: 103, mergedAt: "2026-11-30T12:00:00Z", headRefOid: "ccc3", changedFiles: 1, labels: []},
  {number: 104, mergedAt: "2026-11-30T12:00:00Z", headRefOid: "ddd4", changedFiles: 4, labels: []},
  {number: 105, mergedAt: "2026-11-30T12:00:00Z", headRefOid: "eee5", changedFiles: 1, labels: []},
  {number: 106, mergedAt: "2026-11-30T12:00:00Z", headRefOid: "fff6", changedFiles: 5, labels: []},
  {number: 107, mergedAt: "2026-11-30T12:00:00Z", headRefOid: "ggg7", changedFiles: 2, labels: []},
  {number: 108, mergedAt: "2026-11-08T10:00:00Z", headRefOid: "hhh8", changedFiles: 1, labels: []}
]' > "$CACHE/population.json"

# 108 post-merge approval: a substantive CodeRabbit APPROVED on HEAD posted an hour
# AFTER the merge. At merge time there was no review, so it is override, not real.
jq -n --arg b "$REAL_BODY" '[[{id: 7, user: {login: "coderabbitai[bot]"}, state: "APPROVED", commit_id: "hhh8", body: $b, submitted_at: "2026-11-08T11:00:00Z"}]]' > "$CACHE/pr-108.reviews.json"
echo '[[]]' > "$CACHE/pr-108.pr_comments.json"
echo '[[]]' > "$CACHE/pr-108.issue_comments.json"

# 101 real: CodeRabbit substantive APPROVED on HEAD.
jq -n --arg b "$REAL_BODY" '[[{id: 1, user: {login: "coderabbitai[bot]"}, state: "APPROVED", commit_id: "aaa1", body: $b, submitted_at: "2026-11-01T10:01:00Z"}]]' > "$CACHE/pr-101.reviews.json"
echo '[[]]' > "$CACHE/pr-101.pr_comments.json"
echo '[[]]' > "$CACHE/pr-101.issue_comments.json"

# 102 override with hollow CodeAnt approval (the PR #2303 shape): empty body, nothing else on HEAD.
jq -n '[[{id: 2, user: {login: "codeant-ai[bot]"}, state: "APPROVED", commit_id: "bbb2", body: "", submitted_at: "2026-11-02T10:01:00Z"}]]' > "$CACHE/pr-102.reviews.json"
echo '[[]]' > "$CACHE/pr-102.pr_comments.json"
echo '[[]]' > "$CACHE/pr-102.issue_comments.json"

# 103 other: CodeRabbit COMMENTED review on HEAD, no approval.
jq -n --arg b "$WALK" '[[{id: 3, user: {login: "coderabbitai[bot]"}, state: "COMMENTED", commit_id: "ccc3", body: $b, submitted_at: "2026-11-03T10:01:00Z"}]]' > "$CACHE/pr-103.reviews.json"
echo '[[]]' > "$CACHE/pr-103.pr_comments.json"
echo '[[]]' > "$CACHE/pr-103.issue_comments.json"

# 104 discounted: hollow CodeAnt approval plus a CodeRabbit COMMENTED verdict on HEAD.
jq -n --arg b "$WALK" '[[
  {id: 4, user: {login: "codeant-ai[bot]"}, state: "APPROVED", commit_id: "ddd4", body: "", submitted_at: "2026-11-04T10:01:00Z"},
  {id: 5, user: {login: "coderabbitai[bot]"}, state: "COMMENTED", commit_id: "ddd4", body: $b, submitted_at: "2026-11-04T10:02:00Z"}
]]' > "$CACHE/pr-104.reviews.json"
echo '[[]]' > "$CACHE/pr-104.pr_comments.json"
echo '[[]]' > "$CACHE/pr-104.issue_comments.json"

# 105 override with no signal at all: no reviews, no comments.
echo '[[]]' > "$CACHE/pr-105.reviews.json"
echo '[[]]' > "$CACHE/pr-105.pr_comments.json"
echo '[[]]' > "$CACHE/pr-105.issue_comments.json"

# 106 override: CodeRabbit APPROVED on an OLDER commit only; HEAD has no verdict.
jq -n --arg b "$REAL_BODY" '[[{id: 6, user: {login: "coderabbitai[bot]"}, state: "APPROVED", commit_id: "old0", body: $b, submitted_at: "2026-11-06T09:00:00Z"}]]' > "$CACHE/pr-106.reviews.json"
echo '[[]]' > "$CACHE/pr-106.pr_comments.json"
echo '[[]]' > "$CACHE/pr-106.issue_comments.json"

# 107 unknown: the issue-comments payload was never fetched (missing file).
echo '[[]]' > "$CACHE/pr-107.reviews.json"
echo '[[]]' > "$CACHE/pr-107.pr_comments.json"

LEDGER="$TMP/ledger.json"
jq -n '[{repo: "fixture/fixture", pr: 102, head_sha: "bbb2", backfill_status: "pending"}]' > "$LEDGER"

OUT="$TMP/out.json"
"$SUT" --from-cache --repo fixture/fixture --author fixture --since 2026-10-30 \
  --cache-dir "$CACHE" --ledger-json "$LEDGER" > "$OUT" 2>"$TMP/err"
check "run exits 0 from cache" 0 "$?"

CLS="$CACHE/classified.jsonl"
cls_of() { jq -r --argjson n "$1" 'select(.number == $n) | .class' "$CLS"; }
sub_of() { jq -r --argjson n "$1" 'select(.number == $n) | .sub' "$CLS"; }

check "101 is real" "real" "$(cls_of 101)"
check "102 is override" "override" "$(cls_of 102)"
check "102 discounted approval recorded" "override_discounted_approval" "$(sub_of 102)"
check "102 hollow_any" "true" "$(jq -r --argjson n 102 'select(.number == $n) | .hollow_any' "$CLS")"
check "103 is other" "other" "$(cls_of 103)"
check "104 is discounted" "discounted" "$(cls_of 104)"
check "105 is override with no signal" "override_no_signal" "$(sub_of 105)"
check "106 old-SHA approval does not count" "override" "$(cls_of 106)"
check "107 is unknown" "unknown" "$(cls_of 107)"
check "107 unknown reason" "fetch_or_parse_failed" "$(sub_of 107)"
check "108 post-merge approval ignored" "override_no_signal" "$(sub_of 108)"

check "prs_total" "8" "$(jq -r '.prs_total' "$OUT")"
check "prs_unknown" "1" "$(jq -r '.prs_unknown' "$OUT")"
check "real count" "1" "$(jq -r '.classes.real.prs' "$OUT")"
check "real share of PRs (1/8)" "12.5" "$(jq -r '.shares.real_prs_pct' "$OUT")"
check "lacking PRs lower bound (known non-real)" "75" "$(jq -r '.shares.lacking_prs_pct.lower' "$OUT")"
check "lacking PRs upper bound (unknown counted lacking)" "87.5" "$(jq -r '.shares.lacking_prs_pct.upper' "$OUT")"
check "decision on PRs is warranted" "warranted" "$(jq -r '.decision.prs' "$OUT")"
check "ledger overlaps override 102" "1" "$(jq -r '.ledger_cross_check.override_in_ledger' "$OUT")"
check "label merged-unreviewed matches override" "0" "$(jq -r '.labels.merged_unreviewed_not_override' "$OUT")"
check "CodeRabbit tally has one real" "1" "$(jq -r '.per_reviewer["coderabbitai[bot]"].real' "$OUT")"

# A decision that is not warranted: every PR real, so the upper bound is zero.
ALL="$TMP/allreal"
mkdir -p "$ALL"
jq -n '[{number: 201, mergedAt: "2026-11-30T12:00:00Z", headRefOid: "r1", changedFiles: 2, labels: []},
        {number: 202, mergedAt: "2026-11-30T12:00:00Z", headRefOid: "r2", changedFiles: 2, labels: []}]' > "$ALL/population.json"
for n in 201 202; do
  h=$(jq -r --argjson n "$n" '.[] | select(.number == $n) | .headRefOid' "$ALL/population.json")
  jq -n --arg h "$h" --arg b "$REAL_BODY" '[[{id: 9, user: {login: "coderabbitai[bot]"}, state: "APPROVED", commit_id: $h, body: $b, submitted_at: "2026-11-01T10:01:00Z"}]]' > "$ALL/pr-$n.reviews.json"
  echo '[[]]' > "$ALL/pr-$n.pr_comments.json"
  echo '[[]]' > "$ALL/pr-$n.issue_comments.json"
done
"$SUT" --from-cache --repo fixture/fixture --author fixture --since 2026-10-30 \
  --cache-dir "$ALL" --ledger-json "$LEDGER" > "$TMP/all.json" 2>/dev/null
check "all-real run: decision not_warranted" "not_warranted" "$(jq -r '.decision.prs' "$TMP/all.json")"

# --fail-on-unknown turns an unknown PR into exit 4.
"$SUT" --from-cache --repo fixture/fixture --author fixture --since 2026-10-30 \
  --cache-dir "$CACHE" --ledger-json "$LEDGER" --fail-on-unknown >/dev/null 2>&1
check "--fail-on-unknown exits 4" "4" "$?"

"$SUT" --help >/dev/null 2>&1
check "--help exits 0" "0" "$?"
"$SUT" --no-such-option >/dev/null 2>&1
check "unknown option exits 2" "2" "$?"
"$SUT" --from-cache --since 2026-13-99 --cache-dir "$CACHE" >/dev/null 2>&1
check "bad --since exits 2" "2" "$?"

# Empty-body COMMENTED review on HEAD (the PR #2290 shape) is an acknowledgement, not a
# verdict (issue #2268), so a hollow approval beside it stays override. A COMMENTED
# review with a body, or a reply inside an existing thread, is handled as the gate does.
EMPTY="$TMP/emptycomment"
mkdir -p "$EMPTY"
jq -n '[{number: 301, mergedAt: "2026-11-30T12:00:00Z", headRefOid: "zz1", changedFiles: 2, labels: []},
        {number: 302, mergedAt: "2026-11-30T12:00:00Z", headRefOid: "zz2", changedFiles: 2, labels: []}]' > "$EMPTY/population.json"
jq -n '[[{id: 1, user: {login: "coderabbitai[bot]"}, state: "COMMENTED", commit_id: "zz1", body: "<!-- ack -->", submitted_at: "2026-11-30T11:00:00Z"},
          {id: 2, user: {login: "codeant-ai[bot]"}, state: "APPROVED", commit_id: "zz1", body: "", submitted_at: "2026-11-30T11:01:00Z"}]]' > "$EMPTY/pr-301.reviews.json"
echo '[[]]' > "$EMPTY/pr-301.pr_comments.json"
echo '[[]]' > "$EMPTY/pr-301.issue_comments.json"
jq -n '[[{id: 3, user: {login: "coderabbitai[bot]"}, state: "COMMENTED", commit_id: "zz2", body: "Actionable findings follow.", submitted_at: "2026-11-30T11:00:00Z"},
          {id: 4, user: {login: "codeant-ai[bot]"}, state: "APPROVED", commit_id: "zz2", body: "", submitted_at: "2026-11-30T11:01:00Z"}]]' > "$EMPTY/pr-302.reviews.json"
echo '[[]]' > "$EMPTY/pr-302.pr_comments.json"
echo '[[]]' > "$EMPTY/pr-302.issue_comments.json"
"$SUT" --from-cache --repo fixture/fixture --author fixture --since 2026-10-30 \
  --cache-dir "$EMPTY" --ledger-json "$LEDGER" > "$TMP/empty.json" 2>/dev/null
check "empty-body COMMENTED is not a verdict (override)" "override" "$(jq -r 'select(.number == 301) | .class' "$EMPTY/classified.jsonl")"
check "non-empty COMMENTED beside hollow approval is discounted" "discounted" "$(jq -r 'select(.number == 302) | .class' "$EMPTY/classified.jsonl")"

printf 'review-coverage-measure tests: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
