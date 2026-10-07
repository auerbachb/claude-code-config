#!/usr/bin/env bash
# desk/tests/reviews-view.test.sh — live tests for the desk's Reviews view
# (issue #1782), against the database in HUMAN_QUEUE_DATABASE_URL, through
# the skill's own bash blocks (desk/skill/reviews.md). GitHub is the stub
# tests/lib/gh-stub.sh, serving tests/fixtures/github/ and the search results
# this suite writes; it logs every call, which is how 5.1 proves a cached
# `open` makes no GitHub call.
#
# ISOLATION: that database is the live queue both machines share, so nothing
# here touches its default schema. Every run creates a throwaway schema named
# hq_test_<pid>_<random>_reviews_view, points the CLI at it with
# HUMAN_QUEUE_SCHEMA, and drops it on exit. The suite asserts that the number
# of tables in `public` is unchanged.
#
# Skips with a notice (exit 0) when HUMAN_QUEUE_DATABASE_URL is unset or jq or
# python3 is missing. With the URL set, an unreachable database FAILS the
# suite.
#
# Fixture (synced through sync-reviews, ids in merge/filing order):
#   R-1  acme/widgets issue-202, synced today, unreviewed
#   R-2  acme/widgets pr-101, synced today, no summary_l2 (the 5.1 item)
#   R-3  acme/gadgets pr-7, synced two days ago (moved back), unreviewed
#   R-4  acme/widgets pr-102, synced today, already reviewed
#   R-5  acme/widgets pr-103, synced today, flagged through the skill
#
# Asserts (issue #1782):
#   007    migrate applies 007; summary --level 1 caches the one line once (a
#          different line exits 4, the same is a no-op); a level-1 write is
#          not reported by `tick`; a line beginning with `!` is cached and
#          read back by `summary get` as the line, not as an error; list
#          --unreviewed --json carries today, synced_on, and summary_l1
#   4.2    the skill's level-1 blocks: the material block lists exactly the
#          items without a line (a GitHub failure is reported per item and
#          the rest go on); the cache block stores each line; the view block
#          prints one line per unreviewed item, grouped by day and repo,
#          with the title marked where no line could be written
#   5.1    the skill's `open` gate for R-2 calls GitHub (graphql for #101)
#          and prints the level-2 material; the skill's cache block stores
#          summary_l2; a second `open` makes no GitHub call and prints the
#          cached text
#   4.3    the skill's `diff` block fetches level 3 (the whole diff, or one
#          file with a path) and writes nothing to the store
#   5.2    the skill's `reviewed all today` block marks R-1 and R-2 (one
#          `reviewed` event each), leaves R-3 (an earlier day), R-4 (already
#          reviewed, no new event), and R-5 (flagged) as they were; a second
#          run marks nothing
#   4.4    the skill's flag block stores a note full of shell metacharacters
#          byte for byte and runs none of them; the follow-up blocks see the
#          flag; a filing GitHub answers without a URL leaves the item
#          marked `follow-up: filing`, which the check reports as pending;
#          filing again files the issue in the item's own repo with the
#          capture footer, records its URL after the marks, and the check
#          sees it filed (no longer pending); `reviewed R-n` through the skill
#   and    a store without 007: level 1 names `migrate`; the view still
#          renders, from titles
set -uo pipefail

TESTS_DIR=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/testlib.sh
. "$TESTS_DIR/lib/testlib.sh"
# shellcheck source=lib/skill-block.sh
. "$TESTS_DIR/lib/skill-block.sh"

hq_t_require_db "reviews-view.test.sh"
JQ=$(command -v jq 2>/dev/null || true)
if [ -z "$JQ" ]; then
  echo "SKIP: reviews-view.test.sh — jq is not installed (the desk skill needs it)"
  exit 0
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "SKIP: reviews-view.test.sh — python3 is not installed (the desk scripts need it)"
  exit 0
fi

HQ_BIN_DIR="$HQ_T_DESK_DIR/bin"
# shellcheck source=../bin/lib/common.sh
. "$HQ_BIN_DIR/lib/common.sh"
# shellcheck source=../bin/lib/db.sh
. "$HQ_BIN_DIR/lib/db.sh"
HUMAN_QUEUE_SCHEMA=public hq_db_connect

S="hq_test_$$_$(printf '%05d' "$RANDOM")_reviews_view"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/hq-reviews-view-test.XXXXXX")
SKILL_DIR="$HQ_T_DESK_DIR/skill"
STUB_DIR="$TMP/stub"
WORK="$TMP/work"
mkdir -p "$STUB_DIR" "$WORK"
cp "$HQ_T_TESTS_DIR"/fixtures/github/* "$STUB_DIR"/
export HUMAN_QUEUE_GH="$TESTS_DIR/lib/gh-stub.sh" HQ_GH_STUB_DIR="$STUB_DIR"

admin_sql() { hq_psql -At -c "$1"; }
cleanup() {
  admin_sql "DROP SCHEMA IF EXISTS $S CASCADE;" >/dev/null 2>&1 \
    || echo "WARN: could not drop scratch schema $S — drop it by hand" >&2
  rm -rf "$TMP"
  hq__cleanup_tmp
}
trap cleanup EXIT

sql_in() { hq_psql -At -c "SET search_path TO $S; $1" 2>&1; }
events_of() { sql_in "SELECT coalesce(string_agg(kind || coalesce(':' || note, ''), ',' ORDER BY id), '') FROM events WHERE item_id = '$1'"; }
status_of() { sql_in "SELECT status FROM items WHERE id = '$1'"; }
id_of() { sql_in "SELECT id FROM items WHERE key = '$1'"; }
gh_calls() { cat "$STUB_DIR/calls.log" 2>/dev/null; }
jqr() { printf '%s' "$1" | "$JQ" -r "$2"; }

# hq ARGS... — the CLI in the scratch schema; sets OUT, ERR, RC.
hq() {
  RC=0
  HUMAN_QUEUE_SCHEMA="$S" bash "$HQ_T_CLI" "$@" >"$TMP/out" 2>"$TMP/err" </dev/null || RC=$?
  OUT=$(cat "$TMP/out")
  ERR=$(cat "$TMP/err")
}

# block NAME — extracts reviews.md's anchored block NAME to $TMP/block-NAME.sh.
block() {
  local out rc=0
  out=$(hq_t_skill_block "$SKILL_DIR/reviews.md" "$1" 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    bad "anchor $1 extracts (rc=$rc: $out)"
    return 1
  fi
  printf '%s\n' "$out" > "$TMP/block-$1.sh"
}
# literal FILE FROM TO — FILE with every FROM replaced by TO, literally.
literal() { FROM="$2" TO="$3" perl -pe 's/\Q$ENV{FROM}\E/$ENV{TO}/g' "$1"; }
# run_block FILE — runs a block as the desk does: the prelude's DESK and HQ
# (desk-cli.sh, which finds the URL in the environment), from a scratch
# directory; sets OUT and RC.
run_block() {
  RC=0
  OUT=$(cd "$WORK" && env DESK="$HQ_T_DESK_DIR" HQ="$HQ_BIN_DIR/desk-cli.sh" HUMAN_QUEUE_SCHEMA="$S" \
    TMPDIR="$BLOCK_TMP" bash "$1" 2>&1) || RC=$?
}
# Every temp file a block (or the CLI under it) makes lands here, so "leaves
# no file behind" is checkable.
BLOCK_TMP="$TMP/block-tmp"
mkdir -p "$BLOCK_TMP"

pr_row() {
  printf '{"repository":{"name":"%s","nameWithOwner":"%s"},"number":%s,"title":"%s","url":"https://github.com/%s/pull/%s","closedAt":"%s"}' \
    "${1#*/}" "$1" "$2" "$3" "$1" "$2" "$4"
}
issue_row() {
  printf '{"repository":{"name":"%s","nameWithOwner":"%s"},"number":%s,"title":"%s","url":"https://github.com/%s/issues/%s","createdAt":"%s","body":"%s"}' \
    "${1#*/}" "$1" "$2" "$3" "$1" "$2" "$4" "$5"
}

PUBLIC_BEFORE=$(admin_sql "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public'")

hq migrate
check "migrate the scratch schema" "$RC" "0"
check_contains "migrate applies 007" "$OUT" "applied 007_reviews_summary_l1.sql"
if [ "$RC" -ne 0 ]; then
  printf '%s\n' "$ERR"
  hq_t_finish "reviews-view.test.sh"
  exit 1
fi
echo "scratch schema: $S"

for a in desk-reviews-sync desk-reviews-l1-material desk-reviews-l1-cache desk-reviews-view desk-open \
         desk-open-cache desk-diff desk-reviewed desk-reviewed-today desk-flag desk-follow-up-check desk-follow-up; do
  block "$a"
done

# --- the fixture, through the skill's sync block ------------------------------------
W=acme/widgets
G=acme/gadgets
printf '[%s,%s,%s,%s]\n' \
  "$(pr_row "$W" 101 "feat(#90): widgets become reviewable" 2026-10-05T10:00:00Z)" \
  "$(pr_row "$G" 7 "docs: gadget guide" 2026-10-06T09:00:00Z)" \
  "$(pr_row "$W" 102 "fix: widget count" 2026-10-06T12:00:00Z)" \
  "$(pr_row "$W" 103 "feat: widget colors" 2026-10-06T13:00:00Z)" >"$STUB_DIR/search-prs.json"
printf '[%s]\n' "$(issue_row "$W" 202 "Idea: let the desk export widgets" 2026-10-04T16:00:00Z \
  "Export them.\\n\\n_Captured via /issue-maker._")" >"$STUB_DIR/search-issues.json"

run_block "$TMP/block-desk-reviews-sync.sh"
check_contains "the sync block without a watermark asks for --since" "$OUT" "give the first window with --since"
check "the sync block without a watermark: exit 4, one stderr line" "$(printf '%s\n' "$OUT" | tail -n 1)|$(hq_t_lines "$OUT")" "exit=4|2"
literal "$TMP/block-desk-reviews-sync.sh" 'sync-reviews >' 'sync-reviews --since 2026-10-01 >' >"$TMP/sync-since.sh"
run_block "$TMP/sync-since.sh"
check "the sync block with --since: exit 0, nothing else printed" "$OUT" "exit=0"
check "five Reviews, in merge/filing order" \
  "$(sql_in "SELECT string_agg(id || ' ' || key, ',' ORDER BY length(id), id) FROM items")" \
  "R-1 issue-202,R-2 pr-101,R-3 pr-7,R-4 pr-102,R-5 pr-103"
sql_in "UPDATE items SET created_at = created_at - interval '2 days' WHERE id = 'R-3'" >/dev/null
EARLIER=$(sql_in "SELECT to_char(created_at AT TIME ZONE 'America/New_York', 'FMDy Mon FMDD') FROM items WHERE id = 'R-3'")
hq review R-4
check "setup: R-4 is already reviewed" "$RC:$(status_of R-4)" "0:reviewed"
R4_EVENTS=$(events_of R-4)

# --- 4.4: flag through the skill, with shell metacharacters ----------------------
# The note is meant literally: nothing in it may run or expand.
D='$'
B='`'
NOTE="check the \"colors\" ${D}(touch pwned) ${B}touch pwned2${B} & it's ${D}HOME; \\n done"
literal "$TMP/block-desk-flag.sh" '<the note, verbatim, without its surrounding quotes>' "$NOTE" \
  | literal /dev/stdin 'R-2' 'R-5' >"$TMP/flag.sh"
run_block "$TMP/flag.sh"
check "4.4 the flag block prints the id and exits 0" "$OUT" "R-5
exit=0"
check "4.4 R-5 is flagged" "$(status_of R-5)" "flagged"
check "4.4 the note is stored byte for byte" \
  "$(sql_in "SELECT note FROM events WHERE item_id = 'R-5' AND kind = 'flagged'")" "$NOTE"
if [ -e "$WORK/pwned" ] || [ -e "$WORK/pwned2" ]; then bad "4.4 the note's commands ran"; else ok "4.4 nothing in the note ran"; fi

# --- 007: the one-line summary, cached once --------------------------------------------
hq tick
check "tick baseline" "$RC" "0"
run_block "$TMP/block-desk-reviews-l1-material.sh"
check "4.2 the material block exits cleanly" "$RC" "0"
# In list order: oldest first, and R-3 was synced two days ago.
check "4.2 it lists exactly the unreviewed items without a line" \
  "$(printf '%s\n' "$OUT" | grep '^=====' | tr '\n' ' ')" "===== R-3 ===== R-1 ===== R-2 "
check_contains "4.2 R-1's material is the issue's" "$OUT" "Issue acme/widgets#202"
check_contains "4.2 R-2's material is the PR's" "$OUT" "PR acme/widgets#101"
check "4.2 one exit line per item: R-3's GitHub failure first, and the loop went on" \
  "$(printf '%s\n' "$OUT" | grep '^exit=' | tr '\n' ' ')" "exit=1 exit=0 exit=0 "
check_contains "4.2 the material block asked GitHub for #202" "$(gh_calls)" "number=202"

L1_R1="Captured idea: the desk can export widgets to paper."
L1_R2="Widgets become reviewable from the desk, one line each."
literal "$TMP/block-desk-reviews-l1-cache.sh" '<the one line>' "$L1_R1" | literal /dev/stdin 'R-3' 'R-1' >"$TMP/l1-r1.sh"
literal "$TMP/block-desk-reviews-l1-cache.sh" '<the one line>' "$L1_R2" | literal /dev/stdin 'R-3' 'R-2' >"$TMP/l1-r2.sh"
run_block "$TMP/l1-r1.sh"
check "4.2 the cache block stores R-1's line" "$OUT" "R-1
exit=0"
run_block "$TMP/l1-r2.sh"
check "4.2 the cache block stores R-2's line" "$OUT" "R-2
exit=0"
check "007 summary_l1 holds the line" "$(sql_in "SELECT summary_l1 FROM items WHERE id = 'R-1'")" "$L1_R1"
hq summary get R-2 --level 1
check "007 summary get --level 1 returns it" "$RC|$OUT" "0|$L1_R2"
run_block "$TMP/l1-r1.sh"
check "007 the same line again is a no-op" "$OUT" "R-1
exit=0"
literal "$TMP/l1-r1.sh" "$L1_R1" "A different line." >"$TMP/l1-r1-other.sh"
run_block "$TMP/l1-r1-other.sh"
check_contains "007 a different line is refused" "$OUT" "already has a level-1 summary"
check_contains "007 ... with exit 4" "$OUT" "exit=4"
check "007 the stored line is unchanged" "$(sql_in "SELECT summary_l1 FROM items WHERE id = 'R-1'")" "$L1_R1"
check "007 a level-1 write records no event" "$(events_of R-1)" "asked:synced from GitHub"
hq tick
check "007 tick does not report a level-1 write" "$RC|$OUT" "0|[]"
hq summary get R-3 --level 1
check "007 summary get --level 1 with none cached exits 4" "$RC" "4"
check_contains "007 ... and says so" "$ERR" "no level-1 summary is cached for R-3"
# A level-1 line may begin with `!`, the CLI's own failure sentinel on stdout:
# get must still return it as the line, not as an error. R-4 (reviewed) is
# never in the view, so the view checks below are unaffected.
L1_BANG='!Widget counts are right again after the off-by-one.'
printf '%s' "$L1_BANG" >"$TMP/l1-bang.txt"
hq summary set R-4 --level 1 --file "$TMP/l1-bang.txt"
check "007 a level-1 line beginning with ! is cached" "$RC|$OUT" "0|R-4"
hq summary get R-4 --level 1
check "007 ... and summary get returns it, not an error" "$RC|$OUT|$ERR" "0|$L1_BANG|"

hq list --kind reviews --unreviewed --json
TODAY=$(sql_in "SELECT to_char(statement_timestamp() AT TIME ZONE 'America/New_York', 'YYYY-MM-DD')")
check "4.2 --json carries today (America/New_York)" "$(jqr "$OUT" .today)" "$TODAY"
R3_DAY=$(sql_in "SELECT to_char(created_at AT TIME ZONE 'America/New_York', 'YYYY-MM-DD') FROM items WHERE id = 'R-3'")
check "4.2 --json items carry synced_on" "$(jqr "$OUT" '[.items[] | "\(.id)=\(.synced_on)"] | join(" ")')" \
  "R-3=$R3_DAY R-1=$TODAY R-2=$TODAY"
check "4.2 --json items carry summary_l1, never summary_l2" \
  "$(jqr "$OUT" '[.items[] | "\(.id)=\(has("summary_l1"))/\(has("summary_l2"))"] | join(" ")')" \
  "R-3=true/false R-1=true/false R-2=true/false"

# --- 4.2: the view -------------------------------------------------------------------
run_block "$TMP/block-desk-reviews-view.sh"
check "4.2 the view block prints the grouped view" "$OUT" "Reviews · 3 unreviewed · ~60 lines at level 2

Today · widgets (2)
R-1 · Issue #202 · $L1_R1
R-2 · PR #101 · $L1_R2

$EARLIER · gadgets (1)
R-3 · PR #7 · docs: gadget guide (title; not summarized yet)

Next: open R-<n> · diff R-<n> [path] · reviewed R-<n> · reviewed all today · flag R-<n> \"…\""
check_absent "4.2 the flagged item is not in the view" "$OUT" "R-5"
check_absent "4.2 the reviewed item is not in the view" "$OUT" "R-4"

# --- 5.1: open R-2 generates and caches level 2; a second open makes no GitHub call ---
: >"$STUB_DIR/calls.log"
run_block "$TMP/block-desk-open.sh"
check "5.1 the first open exits cleanly" "$RC" "0"
check_contains "5.1 the first open prints the header" "$OUT" "R-2 · PR #101 · acme/widgets · Merged 2026-10-05 10:00 UTC
https://github.com/acme/widgets/pull/101"
check_contains "5.1 the first open has nothing cached" "$OUT" "LEVEL 2 NOT CACHED — material follows"
check_contains "5.1 the first open fetches the level-2 material" "$OUT" "## Files changed"
check_contains "5.1 ... which exits 0" "$OUT" "exit=0"
check_contains "5.1 the first open called GitHub for #101" "$(gh_calls)" "number=101"
check "5.1 the first open called GitHub exactly once" "$(hq_t_lines "$(gh_calls)")" "1"
check "5.1 nothing is cached by fetching" "$(sql_in "SELECT summary_l2 IS NULL FROM items WHERE id = 'R-2'")" "t"

L2='**Widgets become reviewable: each merged PR lands in the desk as one line.**
1. What changed: sync-reviews adds one R-n per merged PR.
   The desk lists them one line each.
2. Judgment calls: none stated in the PR.
3. Deferred: nothing stated.
4. Tests: tests/widget.test.sh.
5. Links: https://github.com/acme/widgets/pull/101'
literal "$TMP/block-desk-open-cache.sh" '<the level-2 summary>' "$L2" >"$TMP/open-cache.sh"
run_block "$TMP/open-cache.sh"
check "5.1 the cache block stores level 2" "$OUT" "R-2
exit=0"
check "5.1 summary_l2 holds it exactly" "$(sql_in "SELECT summary_l2 FROM items WHERE id = 'R-2'")" "$L2"
check "5.1 caching level 2 records no event" "$(events_of R-2)" "asked:synced from GitHub"

: >"$STUB_DIR/calls.log"
run_block "$TMP/block-desk-open.sh"
check "5.1 the second open prints the header and the cached text" "$RC|$OUT" "0|R-2 · PR #101 · acme/widgets · Merged 2026-10-05 10:00 UTC
https://github.com/acme/widgets/pull/101

$L2"
check "5.1 the second open makes no GitHub call" "$(gh_calls)" ""

# --- 4.3: diff is level 3, live, never stored ------------------------------------------
STATE_BEFORE=$(sql_in "SELECT md5(string_agg(i::text, '|' ORDER BY i.id)) FROM items i")
EVENTS_BEFORE=$(sql_in "SELECT count(*) FROM events")
: >"$STUB_DIR/calls.log"
literal "$TMP/block-desk-diff.sh" '<the path the operator named, or nothing>' '' >"$TMP/diff.sh"
run_block "$TMP/diff.sh"
check_contains "4.3 diff prints the header" "$OUT" "R-2 · PR #101 · acme/widgets"
check_contains "4.3 diff prints the whole diff" "$OUT" "diff --git a/docs/README.md b/docs/README.md"
check_contains "4.3 ... and exits 0" "$OUT" "exit=0"
check_contains "4.3 diff asked GitHub for the PR's diff" "$(gh_calls)" "pr diff 101 --repo acme/widgets"
: >"$STUB_DIR/calls.log"
literal "$TMP/block-desk-diff.sh" '<the path the operator named, or nothing>' 'src/widget.sh' >"$TMP/diff-path.sh"
run_block "$TMP/diff-path.sh"
check_contains "4.3 diff with a path keeps that file" "$OUT" "diff --git a/src/widget.sh b/src/widget.sh"
check_absent "4.3 diff with a path drops the others" "$OUT" "docs/README.md"
literal "$TMP/block-desk-diff.sh" '<the path the operator named, or nothing>' 'no/such/file.sh' >"$TMP/diff-missing.sh"
run_block "$TMP/diff-missing.sh"
check_contains "4.3 a path not in the diff exits 3" "$OUT" "exit=3"
check "4.3 diff writes nothing to the store" \
  "$(sql_in "SELECT md5(string_agg(i::text, '|' ORDER BY i.id)) FROM items i")|$(sql_in "SELECT count(*) FROM events")" \
  "$STATE_BEFORE|$EVENTS_BEFORE"
check "4.3 diff leaves no file behind" "$(ls -A "$WORK")|$(ls -A "$BLOCK_TMP")" "|"

# --- 5.2: reviewed all today -------------------------------------------------------------
R3_EVENTS=$(events_of R-3)
R5_EVENTS=$(events_of R-5)
run_block "$TMP/block-desk-reviewed-today.sh"
check "5.2 reviewed all today marks R-1 and R-2" "$OUT" "R-1
R-2
exit=0"
check "5.2 R-1 and R-2 are reviewed" "$(status_of R-1)|$(status_of R-2)" "reviewed|reviewed"
check "5.2 one reviewed event each" "$(events_of R-1)|$(events_of R-2)" \
  "asked:synced from GitHub,reviewed|asked:synced from GitHub,reviewed"
check "5.2 R-3, synced on an earlier day, is untouched" "$(status_of R-3)|$(events_of R-3)" "open|$R3_EVENTS"
check "5.2 R-4, already reviewed, gets no second event" "$(status_of R-4)|$(events_of R-4)" "reviewed|$R4_EVENTS"
check "5.2 R-5 keeps its flag" "$(status_of R-5)|$(events_of R-5)" "flagged|$R5_EVENTS"
run_block "$TMP/block-desk-reviewed-today.sh"
check "5.2 a second run marks nothing" "$OUT" "exit=0"
hq review --synced-today --comment "read them all"
check "5.2 --synced-today with nothing left: exit 0, no output" "$RC|$OUT|$ERR" "0||"

# reviewed R-n through the skill.
literal "$TMP/block-desk-reviewed.sh" 'R-2' 'R-3' >"$TMP/reviewed.sh"
run_block "$TMP/reviewed.sh"
check "4.4 reviewed R-3 through the skill" "$OUT|$(status_of R-3)" "R-3
exit=0|reviewed"

# --- 4.4: the follow-up issue ------------------------------------------------------------
literal "$TMP/block-desk-follow-up-check.sh" 'R-2' 'R-5' >"$TMP/fu-check.sh"
run_block "$TMP/fu-check.sh"
check "4.4 the check sees the flag, the repo, the link, and the note" "$OUT" "status=flagged
repo=acme/widgets
link=https://github.com/acme/widgets/pull/103
note=$NOTE"
BODY='## Background

R-5 (https://github.com/acme/widgets/pull/103) added widget colors.

## Problem

check the colors

_Captured via /issue-maker._'
literal "$TMP/block-desk-follow-up.sh" '<the title>' 'Widget colors need a contrast check' \
  | literal /dev/stdin '<the body>' "$BODY" | literal /dev/stdin 'R-2' 'R-5' >"$TMP/fu.sh"
# A filing GitHub answers without an issue URL: R-5 stays marked as filing, and
# the check stops the next `follow up` instead of filing a second issue.
: >"$STUB_DIR/issue-create.txt"
printf '1\n' >"$STUB_DIR/issue-create.rc"
printf 'HTTP 502: Bad Gateway\n' >"$STUB_DIR/issue-create.err"
: >"$STUB_DIR/calls.log"
run_block "$TMP/fu.sh"
check "4.4 a failed filing records no URL" "$OUT" "HTTP 502: Bad Gateway
create-exit=1 url="
check "4.4 ... but R-5 is marked as filing" \
  "$(sql_in "SELECT string_agg(note, ',' ORDER BY id) FROM events WHERE item_id = 'R-5' AND kind = 'commented'")" \
  "follow-up: filing"
run_block "$TMP/fu-check.sh"
check_contains "4.4 the check sees the unrecorded filing" "$OUT" "pending=yes"
check_absent "4.4 ... and nothing filed" "$OUT" "filed="
rm -f "$STUB_DIR/issue-create.rc" "$STUB_DIR/issue-create.err"
# `follow up R-5 again`: the same block, now answered with the issue's URL.
printf 'https://github.com/acme/widgets/issues/999\n' >"$STUB_DIR/issue-create.txt"
: >"$STUB_DIR/calls.log"
run_block "$TMP/fu.sh"
check "4.4 the follow-up is filed and recorded" "$OUT" "create-exit=0 url=https://github.com/acme/widgets/issues/999
R-5
comment-exit=0"
check_contains "4.4 filed in the item's own repo" "$(gh_calls)" "issue create --repo acme/widgets --title Widget colors need a contrast check --body-file "
check_contains "4.4 the body carries the capture footer" "$(cat "$STUB_DIR/issue-create.body")" "_Captured via /issue-maker._"
check "4.4 the filing marks come first, the URL last" \
  "$(sql_in "SELECT string_agg(note, ',' ORDER BY id) FROM events WHERE item_id = 'R-5' AND kind = 'commented'")" \
  "follow-up: filing,follow-up: filing,follow-up: https://github.com/acme/widgets/issues/999"
check "4.4 R-5 is still flagged" "$(status_of R-5)" "flagged"
run_block "$TMP/fu-check.sh"
check_contains "4.4 the check now sees it filed" "$OUT" "filed=https://github.com/acme/widgets/issues/999"
check_absent "4.4 ... and no longer pending" "$OUT" "pending="
check_absent "4.4 ... and never reads the mark as a URL" "$OUT" "filed=filing"
check "4.4 the follow-up blocks leave no file behind" "$(ls -A "$WORK")|$(ls -A "$BLOCK_TMP")" "|"

# --- a store without 007 -------------------------------------------------------------------
# One more merged PR to show: synced before 007 is taken away.
printf '[%s]\n' "$(pr_row "$W" 104 "feat: widget sizes" 2026-10-07T09:00:00Z)" >"$STUB_DIR/search-prs.json"
printf '[]\n' >"$STUB_DIR/search-issues.json"
hq sync-reviews
check "setup: R-6 is synced" "$RC|$(id_of pr-104)" "0|R-6"
OLD=$(sql_in "CREATE OR REPLACE FUNCTION items_mark_change() RETURNS trigger LANGUAGE plpgsql AS \$f\$
BEGIN
  IF TG_OP = 'UPDATE'
     AND NEW.summary_l2 IS DISTINCT FROM OLD.summary_l2
     AND to_jsonb(NEW) - ARRAY['summary_l2', 'change_xid', 'updated_at']
       = to_jsonb(OLD) - ARRAY['summary_l2', 'change_xid', 'updated_at'] THEN
    NEW.change_xid := OLD.change_xid;
    RETURN NEW;
  END IF;
  NEW.change_xid := pg_current_xact_id();
  RETURN NEW;
END;
\$f\$; ALTER TABLE items DROP COLUMN summary_l1;")
check "setup: the store is 006's again (no error)" "$OLD" ""
hq summary get R-1 --level 1
check "before 007: summary get --level 1 exits 1" "$RC" "1"
check_contains "before 007: ... naming migrate" "$ERR" "run human-queue.sh migrate"
printf '%s' "$L1_R1" >"$TMP/l1.txt"
hq summary set R-5 --level 1 --file "$TMP/l1.txt"
check "before 007: summary set --level 1 exits 1 naming migrate" "$RC|$ERR" \
  "1|human-queue: summary set: the store is not migrated (run human-queue.sh migrate)"
hq summary get R-2
check "before 007: level 2 still reads" "$RC|$OUT" "0|$L2"
run_block "$TMP/block-desk-reviews-view.sh"
check "before 007: the view still renders, from titles" "$OUT" "Reviews · 1 unreviewed · ~20 lines at level 2

Today · widgets (1)
R-6 · PR #104 · feat: widget sizes (title; not summarized yet)

Next: open R-<n> · diff R-<n> [path] · reviewed R-<n> · reviewed all today · flag R-<n> \"…\""
run_block "$TMP/block-desk-reviewed-today.sh"
check "before 007: reviewed all today still works" "$OUT|$(status_of R-6)" "R-6
exit=0|reviewed"
run_block "$TMP/block-desk-reviews-view.sh"
check "with nothing unreviewed, the view is one line" "$OUT" "No unreviewed Reviews."

PUBLIC_AFTER=$(admin_sql "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public'")
check "public schema table count unchanged" "$PUBLIC_AFTER" "$PUBLIC_BEFORE"

hq_t_finish "reviews-view.test.sh"
