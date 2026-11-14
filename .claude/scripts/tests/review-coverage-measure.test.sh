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
]' > "$CACHE/fixture_fixture.population.author-fixture.since-2026-10-30.base-main.json"

# 108 post-merge approval: a substantive CodeRabbit APPROVED on HEAD posted an hour
# AFTER the merge. At merge time there was no review, so it is override, not real.
jq -n --arg b "$REAL_BODY" '[[{id: 7, user: {login: "coderabbitai[bot]"}, state: "APPROVED", commit_id: "hhh8", body: $b, submitted_at: "2026-11-08T11:00:00Z"}]]' > "$CACHE/fixture_fixture.pr-108.reviews.json"
echo '[[]]' > "$CACHE/fixture_fixture.pr-108.pr_comments.json"
echo '[[]]' > "$CACHE/fixture_fixture.pr-108.issue_comments.json"

# 101 real: CodeRabbit substantive APPROVED on HEAD.
jq -n --arg b "$REAL_BODY" '[[{id: 1, user: {login: "coderabbitai[bot]"}, state: "APPROVED", commit_id: "aaa1", body: $b, submitted_at: "2026-11-01T10:01:00Z"}]]' > "$CACHE/fixture_fixture.pr-101.reviews.json"
echo '[[]]' > "$CACHE/fixture_fixture.pr-101.pr_comments.json"
echo '[[]]' > "$CACHE/fixture_fixture.pr-101.issue_comments.json"

# 102 override with hollow CodeAnt approval (the PR #2303 shape): empty body, nothing else on HEAD.
jq -n '[[{id: 2, user: {login: "codeant-ai[bot]"}, state: "APPROVED", commit_id: "bbb2", body: "", submitted_at: "2026-11-02T10:01:00Z"}]]' > "$CACHE/fixture_fixture.pr-102.reviews.json"
echo '[[]]' > "$CACHE/fixture_fixture.pr-102.pr_comments.json"
echo '[[]]' > "$CACHE/fixture_fixture.pr-102.issue_comments.json"

# 103 other: CodeRabbit COMMENTED review on HEAD, no approval.
jq -n --arg b "$WALK" '[[{id: 3, user: {login: "coderabbitai[bot]"}, state: "COMMENTED", commit_id: "ccc3", body: $b, submitted_at: "2026-11-03T10:01:00Z"}]]' > "$CACHE/fixture_fixture.pr-103.reviews.json"
echo '[[]]' > "$CACHE/fixture_fixture.pr-103.pr_comments.json"
echo '[[]]' > "$CACHE/fixture_fixture.pr-103.issue_comments.json"

# 104 discounted: hollow CodeAnt approval plus a CodeRabbit COMMENTED verdict on HEAD.
jq -n --arg b "$WALK" '[[
  {id: 4, user: {login: "codeant-ai[bot]"}, state: "APPROVED", commit_id: "ddd4", body: "", submitted_at: "2026-11-04T10:01:00Z"},
  {id: 5, user: {login: "coderabbitai[bot]"}, state: "COMMENTED", commit_id: "ddd4", body: $b, submitted_at: "2026-11-04T10:02:00Z"}
]]' > "$CACHE/fixture_fixture.pr-104.reviews.json"
echo '[[]]' > "$CACHE/fixture_fixture.pr-104.pr_comments.json"
echo '[[]]' > "$CACHE/fixture_fixture.pr-104.issue_comments.json"

# 105 override with no signal at all: no reviews, no comments.
echo '[[]]' > "$CACHE/fixture_fixture.pr-105.reviews.json"
echo '[[]]' > "$CACHE/fixture_fixture.pr-105.pr_comments.json"
echo '[[]]' > "$CACHE/fixture_fixture.pr-105.issue_comments.json"

# 106 override: CodeRabbit APPROVED on an OLDER commit only; HEAD has no verdict.
jq -n --arg b "$REAL_BODY" '[[{id: 6, user: {login: "coderabbitai[bot]"}, state: "APPROVED", commit_id: "old0", body: $b, submitted_at: "2026-11-06T09:00:00Z"}]]' > "$CACHE/fixture_fixture.pr-106.reviews.json"
echo '[[]]' > "$CACHE/fixture_fixture.pr-106.pr_comments.json"
echo '[[]]' > "$CACHE/fixture_fixture.pr-106.issue_comments.json"

# 107 unknown: the issue-comments payload was never fetched (missing file).
echo '[[]]' > "$CACHE/fixture_fixture.pr-107.reviews.json"
echo '[[]]' > "$CACHE/fixture_fixture.pr-107.pr_comments.json"

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
        {number: 202, mergedAt: "2026-11-30T12:00:00Z", headRefOid: "r2", changedFiles: 2, labels: []}]' > "$ALL/fixture_fixture.population.author-fixture.since-2026-10-30.base-main.json"
for n in 201 202; do
  h=$(jq -r --argjson n "$n" '.[] | select(.number == $n) | .headRefOid' "$ALL/fixture_fixture.population.author-fixture.since-2026-10-30.base-main.json")
  jq -n --arg h "$h" --arg b "$REAL_BODY" '[[{id: 9, user: {login: "coderabbitai[bot]"}, state: "APPROVED", commit_id: $h, body: $b, submitted_at: "2026-11-01T10:01:00Z"}]]' > "$ALL/fixture_fixture.pr-$n.reviews.json"
  echo '[[]]' > "$ALL/fixture_fixture.pr-$n.pr_comments.json"
  echo '[[]]' > "$ALL/fixture_fixture.pr-$n.issue_comments.json"
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
        {number: 302, mergedAt: "2026-11-30T12:00:00Z", headRefOid: "zz2", changedFiles: 2, labels: []}]' > "$EMPTY/fixture_fixture.population.author-fixture.since-2026-10-30.base-main.json"
jq -n '[[{id: 1, user: {login: "coderabbitai[bot]"}, state: "COMMENTED", commit_id: "zz1", body: "<!-- ack -->", submitted_at: "2026-11-30T11:00:00Z"},
          {id: 2, user: {login: "codeant-ai[bot]"}, state: "APPROVED", commit_id: "zz1", body: "", submitted_at: "2026-11-30T11:01:00Z"}]]' > "$EMPTY/fixture_fixture.pr-301.reviews.json"
echo '[[]]' > "$EMPTY/fixture_fixture.pr-301.pr_comments.json"
echo '[[]]' > "$EMPTY/fixture_fixture.pr-301.issue_comments.json"
jq -n '[[{id: 3, user: {login: "coderabbitai[bot]"}, state: "COMMENTED", commit_id: "zz2", body: "Actionable findings follow.", submitted_at: "2026-11-30T11:00:00Z"},
          {id: 4, user: {login: "codeant-ai[bot]"}, state: "APPROVED", commit_id: "zz2", body: "", submitted_at: "2026-11-30T11:01:00Z"}]]' > "$EMPTY/fixture_fixture.pr-302.reviews.json"
echo '[[]]' > "$EMPTY/fixture_fixture.pr-302.pr_comments.json"
echo '[[]]' > "$EMPTY/fixture_fixture.pr-302.issue_comments.json"
"$SUT" --from-cache --repo fixture/fixture --author fixture --since 2026-10-30 \
  --cache-dir "$EMPTY" --ledger-json "$LEDGER" > "$TMP/empty.json" 2>/dev/null
check "empty-body COMMENTED is not a verdict (override)" "override" "$(jq -r 'select(.number == 301) | .class' "$EMPTY/classified.jsonl")"
check "non-empty COMMENTED beside hollow approval is discounted" "discounted" "$(jq -r 'select(.number == 302) | .class' "$EMPTY/classified.jsonl")"

# Scope and evidence cuts. Each case below changes behaviour that the code before the
# fix got wrong, so each would fail on the old script.
SCOPE="$TMP/scope"
mkdir -p "$SCOPE"
# 901: merged into a release branch, not main; must leave the denominator (old: counted).
# 902: CodeRabbit inline verdict on HEAD created before the merge but EDITED after it;
#      the at-merge cut uses updated_at, so the verdict is gone (old: counted as other).
# 903: a Cursor APPROVED review on HEAD before the merge; it is not CodeRabbit or CodeAnt,
#      so the PR must be other with cursor[bot] named (old: override).
jq -n '[{number: 901, mergedAt: "2026-11-30T12:00:00Z", headRefOid: "s1", changedFiles: 1, labels: [], baseRefName: "release"},
        {number: 902, mergedAt: "2026-11-30T12:00:00Z", headRefOid: "s2", changedFiles: 1, labels: []},
        {number: 903, mergedAt: "2026-11-30T12:00:00Z", headRefOid: "s3", changedFiles: 1, labels: []},
        {number: 904, mergedAt: "2026-11-30T12:00:00Z", headRefOid: "s4", changedFiles: 1, labels: []},
        {number: 905, mergedAt: "2026-11-30T12:00:00Z", headRefOid: "s5", changedFiles: 1, labels: []},
        {number: 906, mergedAt: "2026-11-30T12:00:00Z", headRefOid: "s6", changedFiles: 1, labels: []},
        {number: 907, mergedAt: "2026-11-30T12:00:00Z", headRefOid: "s7", changedFiles: 1, labels: []}]' > "$SCOPE/fixture_fixture.population.author-fixture.since-2026-10-30.base-main.json"
# 905: github-actions[bot] comment naming HEAD. Not a reviewer, so override (not other).
echo '[[]]' > "$SCOPE/fixture_fixture.pr-905.reviews.json"; echo '[[]]' > "$SCOPE/fixture_fixture.pr-905.pr_comments.json"
jq -n '[[{id: 51, user: {login: "github-actions[bot]"}, body: "Deploy preview for s5 is ready", created_at: "2026-11-29T10:00:00Z", updated_at: "2026-11-29T10:00:00Z"}]]' > "$SCOPE/fixture_fixture.pr-905.issue_comments.json"
# 906: Greptile summary that names HEAD (full SHA): a reviewer, so other.
echo '[[]]' > "$SCOPE/fixture_fixture.pr-906.reviews.json"; echo '[[]]' > "$SCOPE/fixture_fixture.pr-906.pr_comments.json"
jq -n '[[{id: 61, user: {login: "greptile-apps[bot]"}, body: "Last reviewed commit: s6 with no findings", created_at: "2026-11-29T10:00:00Z", updated_at: "2026-11-29T10:00:00Z"}]]' > "$SCOPE/fixture_fixture.pr-906.issue_comments.json"
# 907: Greptile comment that names no HEAD (an earlier commit): not on HEAD, so override.
echo '[[]]' > "$SCOPE/fixture_fixture.pr-907.reviews.json"; echo '[[]]' > "$SCOPE/fixture_fixture.pr-907.pr_comments.json"
jq -n '[[{id: 71, user: {login: "greptile-apps[bot]"}, body: "Last reviewed commit: 0ldc0mmit", created_at: "2026-11-29T10:00:00Z", updated_at: "2026-11-29T10:00:00Z"}]]' > "$SCOPE/fixture_fixture.pr-907.issue_comments.json"
# 904: only Graphite's stack comment on the PR; it is not a reviewer, so override stands.
echo '[[]]' > "$SCOPE/fixture_fixture.pr-904.reviews.json"; echo '[[]]' > "$SCOPE/fixture_fixture.pr-904.pr_comments.json"
jq -n '[[{id: 41, user: {login: "graphite-app[bot]"}, body: "stack", created_at: "2026-11-29T10:00:00Z", updated_at: "2026-11-29T10:00:00Z"}]]' > "$SCOPE/fixture_fixture.pr-904.issue_comments.json"
echo '[[]]' > "$SCOPE/fixture_fixture.pr-901.reviews.json"; echo '[[]]' > "$SCOPE/fixture_fixture.pr-901.pr_comments.json"; echo '[[]]' > "$SCOPE/fixture_fixture.pr-901.issue_comments.json"
jq -n '[[]]' > "$SCOPE/fixture_fixture.pr-902.reviews.json"
jq -n '[[{id: 21, user: {login: "coderabbitai[bot]"}, commit_id: "s2", body: "Looks fine.", created_at: "2026-11-20T10:00:00Z", updated_at: "2026-12-02T10:00:00Z"}]]' > "$SCOPE/fixture_fixture.pr-902.pr_comments.json"
echo '[[]]' > "$SCOPE/fixture_fixture.pr-902.issue_comments.json"
jq -n --arg b "$REAL_BODY" '[[{id: 31, user: {login: "cursor[bot]"}, state: "APPROVED", commit_id: "s3", body: $b, submitted_at: "2026-11-29T10:00:00Z"}]]' > "$SCOPE/fixture_fixture.pr-903.reviews.json"
echo '[[]]' > "$SCOPE/fixture_fixture.pr-903.pr_comments.json"
echo '[[]]' > "$SCOPE/fixture_fixture.pr-903.issue_comments.json"
"$SUT" --from-cache --repo fixture/fixture --author fixture --since 2026-10-30 \
  --cache-dir "$SCOPE" --ledger-json "$LEDGER" > "$TMP/scope.json" 2>/dev/null
check "scope run exits 0" "0" "$?"
check "release-branch PR is out of the denominator" "6" "$(jq -r '.prs_total' "$TMP/scope.json")"
check "Graphite stack comment is not a foreign reviewer (override)" "override_no_signal" "$(jq -r 'select(.number == 904) | .sub' "$SCOPE/classified.jsonl")"
check "github-actions[bot] comment on HEAD is not a reviewer (override)" "override_no_signal" "$(jq -r 'select(.number == 905) | .sub' "$SCOPE/classified.jsonl")"
check "Greptile summary naming HEAD is other" "other" "$(jq -r 'select(.number == 906) | .class' "$SCOPE/classified.jsonl")"
check "Greptile comment not naming HEAD is override" "override_no_signal" "$(jq -r 'select(.number == 907) | .sub' "$SCOPE/classified.jsonl")"
check "edited-after-merge verdict is cut (override)" "override_no_signal" "$(jq -r 'select(.number == 902) | .sub' "$SCOPE/classified.jsonl")"
check "foreign bot on HEAD is other, not override" "other" "$(jq -r 'select(.number == 903) | .class' "$SCOPE/classified.jsonl")"
check "foreign reviewer is named" "cursor[bot]" "$(jq -r 'select(.number == 903) | .foreign[0]' "$SCOPE/classified.jsonl")"
check "foreign sub-reason" "foreign_reviewer_activity" "$(jq -r 'select(.number == 903) | .sub' "$SCOPE/classified.jsonl")"

# Offline runs without --repo must name a cache; the default path is repo-derived.
"$SUT" --from-cache >/dev/null 2>"$TMP/nocache.err"
check "--from-cache without --repo or --cache-dir exits 2" "2" "$?"
check "message names the missing cache" "1" "$(grep -c 'needs --cache-dir' "$TMP/nocache.err")"

# Threshold: 404 PRs, 81 lacking (81/404 = 20.05%). Rounded to one decimal that is 20.0,
# which a strict > 20 test wrongly reads as at-threshold. Exact integers say warranted.
EDGE="$TMP/edge"
mkdir -p "$EDGE"
jq -n '[range(1; 405) | {number: ., mergedAt: "2026-11-30T12:00:00Z", headRefOid: ("h" + tostring), changedFiles: 1, labels: []}]' > "$EDGE/fixture_fixture.population.author-fixture.since-2026-10-30.base-main.json"
for n in $(seq 1 404); do
  if [ "$n" -le 81 ]; then
    echo '[[]]' > "$EDGE/fixture_fixture.pr-$n.reviews.json"
  else
    jq -n --argjson n "$n" --arg h "h$n" --arg b "$REAL_BODY" '[[{id: $n, user: {login: "coderabbitai[bot]"}, state: "APPROVED", commit_id: $h, body: $b, submitted_at: "2026-11-01T10:01:00Z"}]]' > "$EDGE/fixture_fixture.pr-$n.reviews.json"
  fi
  echo '[[]]' > "$EDGE/fixture_fixture.pr-$n.pr_comments.json"
  echo '[[]]' > "$EDGE/fixture_fixture.pr-$n.issue_comments.json"
done
"$SUT" --from-cache --repo fixture/fixture --author fixture --since 2026-10-30 \
  --cache-dir "$EDGE" --ledger-json "$LEDGER" > "$TMP/edge.json" 2>/dev/null
check "edge run exits 0" "0" "$?"
check "20.05% lacking is warranted, not rounded to threshold" "warranted" "$(jq -r '.decision.prs' "$TMP/edge.json")"

# Two runs with different windows and authors share one cache directory (issue #2323).
# Sequential runs, so the check is the outcome: each run reads its own population key,
# the second run never changes the first key's file, and a window with no file is refused
# instead of served another window's population.
OVL="$TMP/overlap"
mkdir -p "$OVL"
cp "$CACHE"/fixture_fixture.pr-*.json "$OVL/"
POP_A="$OVL/fixture_fixture.population.author-fixture.since-2026-10-30.base-main.json"
POP_B="$OVL/fixture_fixture.population.author-other.since-2026-11-20.base-main.json"
cp "$CACHE/fixture_fixture.population.author-fixture.since-2026-10-30.base-main.json" "$POP_A"
jq '[.[] | select(.number == 101 or .number == 102)]' "$POP_A" > "$POP_B"
"$SUT" --from-cache --repo fixture/fixture --author fixture --since 2026-10-30 \
  --cache-dir "$OVL" --ledger-json "$LEDGER" > "$TMP/ov1.json" 2>/dev/null
check "overlap run 1 exits 0" "0" "$?"
cp "$POP_A" "$TMP/popA.before"
"$SUT" --from-cache --repo fixture/fixture --author other --since 2026-11-20 \
  --cache-dir "$OVL" --ledger-json "$LEDGER" > "$TMP/ov2.json" 2>/dev/null
check "overlap run 2 exits 0" "0" "$?"
check "run 1 reports its own prs_total" "8" "$(jq -r '.prs_total' "$TMP/ov1.json")"
check "run 2 reports its own prs_total" "2" "$(jq -r '.prs_total' "$TMP/ov2.json")"
check "run 2 does not change run 1's population key" "0" "$(cmp -s "$POP_A" "$TMP/popA.before"; echo $?)"
check "run 1 population key still holds 8 PRs" "8" "$(jq 'length' "$POP_A")"
"$SUT" --from-cache --repo fixture/fixture --author fixture --since 2026-11-20 \
  --cache-dir "$OVL" --ledger-json "$LEDGER" > "$TMP/ov3.json" 2>/dev/null
check "a window with no population file is refused (exit 2)" "2" "$?"
check "a refused window prints no report" "0" "$(wc -c < "$TMP/ov3.json" | tr -d ' ')"
"$SUT" --from-cache --repo fixture/fixture --author other --since 2026-10-30 \
  --cache-dir "$OVL" --ledger-json "$LEDGER" >/dev/null 2>&1
check "an author with no population file is refused (exit 2)" "2" "$?"
"$SUT" --from-cache --repo fixture/fixture --author 'a/b' --since 2026-10-30 \
  --cache-dir "$OVL" >/dev/null 2>&1
check "an author that is not a login is refused (exit 2)" "2" "$?"

# Run directories. A successful run, a refused run (exit 2) and a --fail-on-unknown run
# (exit 4) must each leave no .run.* directory behind, and the exit status must survive
# the cleanup trap.
"$SUT" --from-cache --repo fixture/fixture --author nobody --since 2026-10-30 \
  --cache-dir "$CACHE" >/dev/null 2>&1
check "refused run keeps exit 2 through cleanup" "2" "$?"
check "no run directory left after a refused run" "0" "$(ls -A "$CACHE" | grep -c '^\.run\.')"
"$SUT" --from-cache --repo fixture/fixture --author fixture --since 2026-10-30 \
  --cache-dir "$CACHE" --ledger-json "$LEDGER" --fail-on-unknown >/dev/null 2>&1
check "--fail-on-unknown keeps exit 4 through cleanup" "4" "$?"
check "no run directory left after a failing run" "0" "$(ls -A "$CACHE" | grep -c '^\.run\.')"
"$SUT" --from-cache --repo fixture/fixture --author fixture --since 2026-10-30 \
  --cache-dir "$OVL" --ledger-json "$LEDGER" >/dev/null 2>&1
check "no run directory left after a successful run" "0" "$(ls -A "$OVL" | grep -c '^\.run\.')"

printf 'review-coverage-measure tests: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
