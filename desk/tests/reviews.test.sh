#!/usr/bin/env bash
# desk/tests/reviews.test.sh — live tests for Reviews (issue #1756):
# sync-reviews, review --comment, flag, summary, list --unreviewed, and the
# tick rule of migration 004, against the database in
# HUMAN_QUEUE_DATABASE_URL. GitHub is the stub tests/lib/gh-stub.sh, serving
# search results this suite writes; one smoke run at the end uses the real
# GitHub API.
#
# ISOLATION: that database is the live queue both machines share, so nothing
# here touches its default schema. Every run creates throwaway schemas named
# hq_test_<pid>_<random>_*, points the CLI at them with HUMAN_QUEUE_SCHEMA,
# and drops them on exit. The suite also asserts that the number of tables in
# `public` is unchanged.
#
# Skips with a notice (exit 0) when HUMAN_QUEUE_DATABASE_URL is unset. With the
# URL set, an unreachable database FAILS the suite. The real-GitHub smoke run
# skips (with a notice) when gh is missing or not authenticated.
#
# Asserts (issue #1756 Test Plan and AC):
#   5.1  three merged PRs (two repositories, one returned twice) and two
#        captured issues (one with the footer above an appended plan), plus
#        an issue that only mentions the footer: the first sync creates five
#        Reviews, each with its link and an `asked` event, and stores the
#        watermark; a second sync creates none and reads from one hour
#        before the watermark (AC 4.1)
#   and: the first sync without --since exits 4 before calling GitHub; a
#        reviewed Review is never re-created, even under another spelling of
#        its repository; a search at its result limit and a failed search
#        write nothing and keep the watermark; a credential-shaped title is
#        withheld; a malformed row is skipped and counted; 120 rows cross
#        the 50-row batches; two concurrent syncs create each Review once;
#        --json reports the same counts
#   5.3  `flag R-n "..."` sets `flagged` and stores the note as a `flagged`
#        event; `review R-n --comment` stores the comment on `reviewed`, and
#        a second comment is a `commented` event (AC 4.3)
#   AC 4.4  `summary set` stores the bold-line-plus-numbered-list text once:
#        get returns it, a different second text exits 4 and changes
#        nothing, the same text is a no-op; with 004 a summary write is not
#        reported by `tick`, while a bump still is
#   AC 4.5  `list --kind reviews --unreviewed` prints the count and the
#        reading estimate (count x 20 lines), flagged and reviewed items
#        excluded; --json gives count and level2_lines, and its items never
#        carry a cached level-2 summary
#   smoke: sync-reviews against the real GitHub API in a throwaway schema,
#        twice, without duplicates; pr-summary-material.sh level 1 of a real
#        merged PR names its closing issue
# On macOS, a share of the calls run under /bin/bash 3.2.
set -uo pipefail

TESTS_DIR=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/testlib.sh
. "$TESTS_DIR/lib/testlib.sh"

hq_t_require_db "reviews.test.sh"

HQ_BIN_DIR="$HQ_T_DESK_DIR/bin"
# shellcheck source=../bin/lib/common.sh
. "$HQ_BIN_DIR/lib/common.sh"
# shellcheck source=../bin/lib/db.sh
. "$HQ_BIN_DIR/lib/db.sh"
HUMAN_QUEUE_SCHEMA=public hq_db_connect

BASE="hq_test_$$_$(printf '%05d' "$RANDOM")"
S_MAIN="${BASE}_reviews"
S_BULK="${BASE}_bulk"
S_LIVE="${BASE}_live"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/hq-reviews-test.XXXXXX")
STUB_DIR="$TMP/stub"
mkdir -p "$STUB_DIR"
export HUMAN_QUEUE_GH="$TESTS_DIR/lib/gh-stub.sh" HQ_GH_STUB_DIR="$STUB_DIR"

admin_sql() { hq_psql -At -c "$1"; }

cleanup() {
  admin_sql "DROP SCHEMA IF EXISTS $S_MAIN CASCADE; DROP SCHEMA IF EXISTS $S_BULK CASCADE; DROP SCHEMA IF EXISTS $S_LIVE CASCADE;" >/dev/null 2>&1 \
    || echo "WARN: could not drop scratch schemas $S_MAIN / $S_BULK / $S_LIVE — drop them by hand" >&2
  rm -rf "$TMP"
  hq__cleanup_tmp
}
trap cleanup EXIT

sql_in() { hq_psql -At -c "SET search_path TO $1; $2" 2>&1; }

OLD_BASH=bash
if [ -x /bin/bash ] && [ "$(/bin/bash -c 'echo "${BASH_VERSINFO[0]}"')" = "3" ]; then
  OLD_BASH=/bin/bash
fi

JQ=""
if command -v jq >/dev/null 2>&1; then JQ=$(command -v jq); fi

# hq SHELL SCHEMA ARGS... — runs the CLI; sets OUT, ERR, RC.
hq() {
  local sh="$1" schema="$2"
  shift 2
  RC=0
  HUMAN_QUEUE_SCHEMA="$schema" "$sh" "$HQ_T_CLI" "$@" >"$TMP/out" 2>"$TMP/err" </dev/null || RC=$?
  OUT=$(cat "$TMP/out")
  ERR=$(cat "$TMP/err")
}

# hq_in SHELL SCHEMA INPUT ARGS... — like hq, with INPUT on stdin.
hq_in() {
  local sh="$1" schema="$2"
  printf '%s' "$3" >"$TMP/in"
  shift 3
  RC=0
  HUMAN_QUEUE_SCHEMA="$schema" "$sh" "$HQ_T_CLI" "$@" >"$TMP/out" 2>"$TMP/err" <"$TMP/in" || RC=$?
  OUT=$(cat "$TMP/out")
  ERR=$(cat "$TMP/err")
}

n_items() { sql_in "$1" "SELECT count(*) FROM items"; }
events_of() { sql_in "$1" "SELECT string_agg(kind || coalesce(':' || note, ''), ',' ORDER BY id) FROM events WHERE item_id = '$2'"; }
id_of() { sql_in "$1" "SELECT id FROM items WHERE kind = 'review' AND lower(repo) = lower('$2') AND key = '$3'"; }
watermark() { sql_in "$1" "SELECT coalesce((SELECT value FROM state WHERE key = 'reviews_watermark'), '<none>')"; }
last_tally() { printf '%s\n' "$OUT" | tail -n 1; }

# pr_row REPO N TITLE CLOSED_AT / issue_row REPO N TITLE CREATED_AT BODY —
# one search result, as `gh search --json` prints it.
pr_row() {
  printf '{"repository":{"name":"%s","nameWithOwner":"%s"},"number":%s,"title":"%s","url":"https://github.com/%s/pull/%s","closedAt":"%s"}' \
    "${1#*/}" "$1" "$2" "$3" "$1" "$2" "$4"
}
issue_row() {
  printf '{"repository":{"name":"%s","nameWithOwner":"%s"},"number":%s,"title":"%s","url":"https://github.com/%s/issues/%s","createdAt":"%s","body":"%s"}' \
    "${1#*/}" "$1" "$2" "$3" "$1" "$2" "$4" "$5"
}

# set_search FILE ROW... — writes the rows as one JSON array.
set_search() {
  local f="$STUB_DIR/$1" first=1
  shift
  {
    printf '['
    for r in "$@"; do
      if [ "$first" -eq 0 ]; then printf ','; fi
      first=0
      printf '%s' "$r"
    done
    printf ']\n'
  } >"$f"
}

PUBLIC_BEFORE=$(admin_sql "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public'")

for s in "$S_MAIN" "$S_BULK"; do
  hq bash "$s" migrate
  check "migrate $s" "$RC" "0"
  if [ "$RC" -ne 0 ]; then
    printf '%s\n' "$ERR"
    hq_t_finish "reviews.test.sh"
    exit 1
  fi
done
check_contains "migrate applies 004" "$OUT" "applied 004_reviews_summary.sql"
hq bash "$S_BULK" list --kind reviews --unreviewed
check "4.5 an empty backlog prints only the tally" "$RC|$OUT" "0|0 unreviewed · ~0 lines at level 2"
echo "scratch schema: $S_MAIN (old shell: $OLD_BASH)"

W=acme/widgets
G=acme/gadgets
FOOTER='_Captured via /issue-maker._'
PR1=$(pr_row "$W" 101 "feat(#90): widgets become reviewable" 2026-10-05T21:34:47Z)
PR2=$(pr_row "$W" 102 "fix: widget count" 2026-10-05T22:00:00Z)
PR3=$(pr_row "$G" 7 "docs: gadget guide" 2026-10-04T09:00:00Z)
PR1_AGAIN=$(pr_row "$W" 101 "feat(#90): widgets become reviewable" 2026-10-05T21:34:47Z)
IS1=$(issue_row "$W" 202 "Idea: export widgets" 2026-10-05T16:49:52Z "## Background\\n\\nOn paper.\\n\\n$FOOTER")
IS2=$(issue_row "$G" 8 "Idea: gadget plan" 2026-10-03T12:00:00Z "Plan it.\\n\\n$FOOTER\\n\\n## Implementation Plan\\n\\n1. Do it.")
IS_MENTION=$(issue_row "$G" 9 "Talk about the footer" 2026-10-03T13:00:00Z "We print $FOOTER at the end of each issue.")

# --- the first sync needs --since ------------------------------------------------
set_search search-prs.json "$PR1" "$PR2" "$PR3" "$PR1_AGAIN"
set_search search-issues.json "$IS1" "$IS2" "$IS_MENTION"
: >"$STUB_DIR/calls.log"
hq bash "$S_MAIN" sync-reviews
check "first sync without --since exits 4" "$RC" "4"
check_contains "first sync without --since asks for it" "$ERR" "give the first window with --since"
check "first sync without --since calls no GitHub search" "$(cat "$STUB_DIR/calls.log")" ""
check "first sync without --since writes nothing" "$(n_items "$S_MAIN")|$(watermark "$S_MAIN")" "0|<none>"

# --- 5.1: three PRs and two captured issues make five Reviews ---------------------
hq "$OLD_BASH" "$S_MAIN" sync-reviews --since 2026-10-01
check "5.1 first sync exits 0" "$RC" "0"
check "5.1 first sync is silent on stderr" "$ERR" ""
check "5.1 first sync reports five new" "$(last_tally)" \
  "sync-reviews: 5 new, 0 already queued (3 merged PRs, 2 captured issues since 2026-10-01T00:00:00Z)"
check "5.1 five Reviews in the store" "$(n_items "$S_MAIN")" "5"
check "5.1 one line per new Review" "$(printf '%s\n' "$OUT" | grep -c '^R-[0-9]* · ')" "5"
check "5.1 keyed on repo and number" \
  "$(sql_in "$S_MAIN" "SELECT string_agg(repo || ' ' || key, ',' ORDER BY substring(id FROM 3)::int) FROM items")" \
  "acme/gadgets issue-8,acme/gadgets pr-7,acme/widgets issue-202,acme/widgets pr-101,acme/widgets pr-102"
check "5.1 ids follow merge/filing time" "$(id_of "$S_MAIN" "$G" issue-8)|$(id_of "$S_MAIN" "$W" pr-102)" "R-1|R-5"
check "5.1 the issue that only mentions the footer is left out" "$(id_of "$S_MAIN" "$G" issue-9)" ""
R101=$(id_of "$S_MAIN" "$W" pr-101)
check "5.1 a Review's question is the title" \
  "$(sql_in "$S_MAIN" "SELECT question FROM items WHERE id = '$R101'")" "feat(#90): widgets become reviewable"
check "5.1 a Review's context is the link and the merge time" \
  "$(sql_in "$S_MAIN" "SELECT array_to_string(context, '|') FROM items WHERE id = '$R101'")" \
  "https://github.com/acme/widgets/pull/101|Merged 2026-10-05 21:34 UTC"
check "5.1 a captured issue's context says filed" \
  "$(sql_in "$S_MAIN" "SELECT context[2] FROM items WHERE key = 'issue-202'")" "Filed 2026-10-05 16:49 UTC"
check "5.1 each Review has one asked event" "$(events_of "$S_MAIN" "$R101")" "asked:synced from GitHub"
check "5.1 Reviews are open, kind review, no session" \
  "$(sql_in "$S_MAIN" "SELECT DISTINCT status || '/' || kind || '/' || coalesce(session_id, '-') FROM items")" "open/review/-"
check "5.1 nothing stored beyond title and links" \
  "$(sql_in "$S_MAIN" "SELECT count(*) FROM items WHERE summary_l2 IS NOT NULL OR answer IS NOT NULL OR cardinality(context) <> 2")" "0"
check_contains "5.1 the PR search asked for merged PRs since --since" "$(cat "$STUB_DIR/calls.log")" \
  "search prs --author @me --merged --merged-at >=2026-10-01T00:00:00Z"
check_contains "5.1 the issue search asked for captured issues since --since" "$(cat "$STUB_DIR/calls.log")" \
  "--match body --author @me --created >=2026-10-01T00:00:00Z"
WM1=$(watermark "$S_MAIN")
if [[ $WM1 =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
  ok "5.1 the watermark is stored in the database ($WM1)"
else
  bad "5.1 the watermark is stored in the database (got '$WM1')"
fi
hq bash "$S_MAIN" state get reviews_watermark
check "5.1 the watermark reads back through state get" "$OUT" "$WM1"
SINCE2=$(sql_in "$S_MAIN" "SELECT to_char((value::timestamptz - interval '1 hour') AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"') FROM state WHERE key = 'reviews_watermark'")

# A second sync over the same results creates nothing.
sleep 1
: >"$STUB_DIR/calls.log"
hq bash "$S_MAIN" sync-reviews
check "5.1 second sync exits 0" "$RC" "0"
check "5.1 second sync creates none" "$OUT" \
  "sync-reviews: 0 new, 5 already queued (3 merged PRs, 2 captured issues since $SINCE2)"
check "5.1 still five Reviews" "$(n_items "$S_MAIN")" "5"
check_contains "5.1 the second window starts an hour before the watermark" "$(cat "$STUB_DIR/calls.log")" \
  "--merged-at >=$SINCE2"
WM2=$(watermark "$S_MAIN")
if [[ $WM2 > $WM1 ]]; then ok "5.1 the watermark moved forward"; else bad "5.1 the watermark moved forward ($WM1 -> $WM2)"; fi

# --json gives the same counts.
if [ -n "$JQ" ]; then
  hq bash "$S_MAIN" sync-reviews --json
  check "sync --json exits 0" "$RC" "0"
  check "sync --json counts" \
    "$(printf '%s' "$OUT" | "$JQ" -r '[.merged_prs, .captured_issues, .already_queued, .skipped, (.created | length)] | join(",")')" \
    "3,2,5,0,0"
else
  printf 'skip — sync --json (jq not installed)\n'
fi

# --- reviewed is never re-created; the repository match ignores case ------------
R7=$(id_of "$S_MAIN" "$G" pr-7)
hq bash "$S_MAIN" review "$R7"
check "review of a synced Review" "$RC|$OUT" "0|$R7"
PR3_UPPER=$(pr_row "Acme/Gadgets" 7 "docs: gadget guide" 2026-10-04T09:00:00Z)
PR4=$(pr_row "$G" 10 "feat: gadgets ship" 2026-10-06T08:00:00Z)
set_search search-prs.json "$PR1" "$PR2" "$PR3_UPPER" "$PR4"
hq "$OLD_BASH" "$S_MAIN" sync-reviews --since 2026-10-01
check "a later sync adds only the new PR" "$(last_tally)" \
  "sync-reviews: 1 new, 5 already queued (4 merged PRs, 2 captured issues since 2026-10-01T00:00:00Z)"
check "the reviewed Review is not re-created" \
  "$(sql_in "$S_MAIN" "SELECT count(*) || '/' || min(status) FROM items WHERE lower(repo) = 'acme/gadgets' AND key = 'pr-7'")" "1/reviewed"
check "six Reviews" "$(n_items "$S_MAIN")" "6"

# --- a search at its limit, and a failed search, write nothing -------------------
WM_BEFORE=$(watermark "$S_MAIN")
PR5=$(pr_row "$G" 11 "fix: never stored" 2026-10-06T09:00:00Z)
set_search search-prs.json "$PR1" "$PR2" "$PR4" "$PR5"
RC=0
HUMAN_QUEUE_SCHEMA="$S_MAIN" HUMAN_QUEUE_SYNC_LIMIT=4 bash "$HQ_T_CLI" sync-reviews >"$TMP/out" 2>"$TMP/err" </dev/null || RC=$?
check "a search at its limit exits 1" "$RC" "1"
check_contains "a search at its limit says so" "$(cat "$TMP/err")" "returned 4 results, its limit"
check "a search at its limit writes nothing" "$(n_items "$S_MAIN")|$(watermark "$S_MAIN")" "6|$WM_BEFORE"
printf '1\n' >"$STUB_DIR/search-issues.rc"
printf 'HTTP 401: Bad credentials\n' >"$STUB_DIR/search-issues.err"
hq bash "$S_MAIN" sync-reviews
rm -f "$STUB_DIR/search-issues.rc" "$STUB_DIR/search-issues.err"
check "a failed search exits 1" "$RC" "1"
check "a failed search is one stderr line" "$(hq_t_lines "$ERR")" "1"
check_contains "a failed search names GitHub's error" "$ERR" "captured issues failed: HTTP 401: Bad credentials"
check "a failed search writes nothing" "$(n_items "$S_MAIN")|$(watermark "$S_MAIN")|$(id_of "$S_MAIN" "$G" pr-11)" "6|$WM_BEFORE|"

# --- withheld titles and malformed rows --------------------------------------------
FAKE_AWS="AK""IA""ABCDEFGHIJKLMNOP"
PR_SECRET=$(pr_row "$G" 12 "fix: rotate $FAKE_AWS" 2026-10-06T10:00:00Z)
PR_BAD='{"repository":{"nameWithOwner":"acme/gadgets"},"number":13,"title":"no link","url":"","closedAt":"2026-10-06T11:00:00Z"}'
set_search search-prs.json "$PR_SECRET" "$PR_BAD"
set_search search-issues.json
hq bash "$S_MAIN" sync-reviews
check "a sync with a withheld title and a malformed row exits 0" "$RC" "0"
check "the malformed row is skipped and counted" "$(last_tally)" \
  "sync-reviews: 1 new, 0 already queued (2 merged PRs, 0 captured issues since $(sql_in "$S_MAIN" "SELECT to_char(('$WM_BEFORE'::timestamptz - interval '1 hour') AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"')"), 1 skipped (malformed))"
check "a credential-shaped title is withheld" \
  "$(sql_in "$S_MAIN" "SELECT question FROM items WHERE key = 'pr-12'")" "PR #12 (title withheld: it looks like a credential)"
check_absent "the credential never reaches the store" "$(sql_in "$S_MAIN" "SELECT string_agg(question || array_to_string(context, ' '), ' ') FROM items")" "$FAKE_AWS"
check_absent "the credential is never printed" "$OUT$ERR" "$FAKE_AWS"
check "the malformed row is not stored" "$(id_of "$S_MAIN" "$G" pr-13)" ""

# --- 120 rows cross the 50-row batches; two concurrent syncs create each once ------
BULK=()
i=1
while [ "$i" -le 120 ]; do
  BULK[${#BULK[@]}]=$(pr_row "acme/bulk" "$i" "bulk change $i" "2026-10-05T$(printf '%02d' $((i % 24))):$(printf '%02d' $((i % 60))):00Z")
  i=$((i + 1))
done
set_search search-prs.json "${BULK[@]}"
set_search search-issues.json "$IS1"
HUMAN_QUEUE_SCHEMA="$S_BULK" bash "$HQ_T_CLI" sync-reviews --since 2026-10-01 >"$TMP/a.out" 2>"$TMP/a.err" </dev/null &
PA=$!
HUMAN_QUEUE_SCHEMA="$S_BULK" "$OLD_BASH" "$HQ_T_CLI" sync-reviews --since 2026-10-01 >"$TMP/b.out" 2>"$TMP/b.err" </dev/null &
PB=$!
RA=0; wait "$PA" || RA=$?
RB=0; wait "$PB" || RB=$?
check "two concurrent syncs both exit 0" "$RA|$RB" "0|0"
check "two concurrent syncs are silent on stderr" "$(cat "$TMP/a.err" "$TMP/b.err")" ""
check "121 Reviews across the batches, each once" \
  "$(sql_in "$S_BULK" "SELECT count(*) || '/' || count(DISTINCT lower(repo) || key) FROM items")" "121/121"
NEW_A=$(tail -n 1 "$TMP/a.out" | sed -n 's/^sync-reviews: \([0-9]*\) new.*/\1/p')
NEW_B=$(tail -n 1 "$TMP/b.out" | sed -n 's/^sync-reviews: \([0-9]*\) new.*/\1/p')
check "the two syncs split the new Reviews between them" "$((NEW_A + NEW_B))" "121"
check "each new Review has exactly one asked event" \
  "$(sql_in "$S_BULK" "SELECT count(*) FROM (SELECT item_id FROM events GROUP BY item_id HAVING count(*) <> 1) x")" "0"
hq bash "$S_BULK" sync-reviews
check "a third bulk sync creates none" "$(last_tally | sed -n 's/^sync-reviews: \([0-9]*\) new, \([0-9]*\) already.*/\1|\2/p')" "0|121"

# --- 5.3: flag stores the note as an event; review takes a comment -----------------
R102=$(id_of "$S_MAIN" "$W" pr-102)
hq "$OLD_BASH" "$S_MAIN" flag "$R102" "add a test for the empty widget"
check "5.3 flag with a bare note exits 0" "$RC|$OUT|$ERR" "0|$R102|"
check "5.3 flag sets flagged" "$(sql_in "$S_MAIN" "SELECT status FROM items WHERE id = '$R102'")" "flagged"
check "5.3 flag stores the note as a flagged event" "$(events_of "$S_MAIN" "$R102")" \
  "asked:synced from GitHub,flagged:add a test for the empty widget"
hq bash "$S_MAIN" flag "$R102" --note "add a test for the empty widget"
check "5.3 the same flag again records nothing" "$RC|$(events_of "$S_MAIN" "$R102")" \
  "0|asked:synced from GitHub,flagged:add a test for the empty widget"
hq bash "$S_MAIN" review "$R101" --comment "matches the issue"
check "review --comment exits 0" "$RC|$OUT" "0|$R101"
check "review --comment puts the comment on the reviewed event" "$(events_of "$S_MAIN" "$R101")" \
  "asked:synced from GitHub,reviewed:matches the issue"
hq "$OLD_BASH" "$S_MAIN" review "$R101" --comment "second look: still fine"
check "a comment on a reviewed Review is a commented event" "$RC|$(events_of "$S_MAIN" "$R101")" \
  "0|asked:synced from GitHub,reviewed:matches the issue,commented:second look: still fine"
hq bash "$S_MAIN" review "$R101"
check "reviewing a reviewed Review again records nothing" "$RC|$(sql_in "$S_MAIN" "SELECT count(*) FROM events WHERE item_id = '$R101'")" "0|3"

# --- AC 4.5: the unreviewed backlog and its reading estimate -------------------------
EXPECT_OPEN=$(sql_in "$S_MAIN" "SELECT count(*) FROM items WHERE kind = 'review' AND status = 'open'")
hq bash "$S_MAIN" list --kind reviews --unreviewed
check "4.5 list --unreviewed exits 0" "$RC" "0"
check "4.5 the last line is the count and the estimate" "$(last_tally)" \
  "$EXPECT_OPEN unreviewed · ~$((EXPECT_OPEN * 20)) lines at level 2"
check "4.5 every open Review is listed" "$(printf '%s\n' "$OUT" | grep -c '^R-[0-9]* · review · open · ')" "$EXPECT_OPEN"
check_absent "4.5 flagged Reviews are left out" "$OUT" "$R102 · "
check_absent "4.5 reviewed Reviews are left out" "$OUT" "$R101 · "
if [ -n "$JQ" ]; then
  hq bash "$S_MAIN" list --unreviewed --json
  check "4.5 --json count and estimate" "$(printf '%s' "$OUT" | "$JQ" -r '"\(.count)|\(.level2_lines)|\(.items | length)"')" \
    "$EXPECT_OPEN|$((EXPECT_OPEN * 20))|$EXPECT_OPEN"
fi
hq bash "$S_MAIN" list --kind reviews --status reviewed
check "list --kind reviews (plural) still filters" "$(printf '%s\n' "$OUT" | grep -c '^R-[0-9]* · review · reviewed · ')" "2"
check "4.5 the bulk backlog's tally" \
  "$(HUMAN_QUEUE_SCHEMA="$S_BULK" bash "$HQ_T_CLI" list --unreviewed --kind review </dev/null | tail -n 1)" \
  "121 unreviewed · ~2420 lines at level 2"

# --- AC 4.4: the level-2 summary is cached once ------------------------------------
R202=$(id_of "$S_MAIN" "$W" issue-202)
SUMMARY='**Widgets can be exported to paper from the desk.**
1. What changed: an export command.
   It prints one page per widget.
2. Judgment call: A4 by default.
3. Deferred: color.
4. Tests: export.test.sh.
5. Links: https://github.com/acme/widgets/issues/202'
hq bash "$S_MAIN" summary get "$R202"
check "4.4 summary get before a summary exits 4" "$RC" "4"
check_contains "4.4 summary get says none is cached" "$ERR" "no level-2 summary is cached for $R202"
hq bash "$S_MAIN" tick
check "tick baseline" "$RC" "0"
hq_in "$OLD_BASH" "$S_MAIN" "$SUMMARY" summary set "$R202"
check "4.4 summary set exits 0" "$RC|$OUT|$ERR" "0|$R202|"
hq bash "$S_MAIN" summary get "$R202"
check "4.4 summary get returns it exactly" "$OUT" "$SUMMARY"
check "4.4 stored in summary_l2" "$(sql_in "$S_MAIN" "SELECT summary_l2 = \$s\$$SUMMARY\$s\$ FROM items WHERE id = '$R202'")" "t"
check "4.4 a summary write records no event" "$(events_of "$S_MAIN" "$R202")" "asked:synced from GitHub"
hq bash "$S_MAIN" tick
check "4.4 tick does not report a summary write (004)" "$OUT" "[]"
hq_in bash "$S_MAIN" "$SUMMARY" summary set "$R202"
check "4.4 the same summary again is a no-op" "$RC|$OUT" "0|$R202"
hq_in bash "$S_MAIN" "**A different take.**
1. Regenerated." summary set "$R202"
check "4.4 a different second summary exits 4" "$RC" "4"
check_contains "4.4 it is never regenerated" "$ERR" "never regenerated"
hq bash "$S_MAIN" summary get "$R202"
check "4.4 the stored summary is unchanged" "$OUT" "$SUMMARY"
printf '%s\n' "$SUMMARY" >"$TMP/summary.md"
R8=$(id_of "$S_MAIN" "$G" issue-8)
hq bash "$S_MAIN" summary set "$R8" --file "$TMP/summary.md"
check "4.4 summary set --file" "$RC|$(sql_in "$S_MAIN" "SELECT summary_l2 IS NOT NULL FROM items WHERE id = '$R8'")" "0|t"
hq bash "$S_MAIN" summary set R-999 --file "$TMP/summary.md"
check "4.4 summary set of an unknown id exits 4" "$RC" "4"
check_contains "4.4 summary set names the unknown id" "$ERR" "no item R-999"
hq bash "$S_MAIN" tick
check "4.4 tick after summaries still reports nothing" "$OUT" "[]"
hq bash "$S_MAIN" bump "$R202"
hq bash "$S_MAIN" tick
if [ -n "$JQ" ]; then
  check "4.4 a bump is still reported by tick" "$(printf '%s' "$OUT" | "$JQ" -r '[.[].id] | join(",")')" "$R202"
else
  check_contains "4.4 a bump is still reported by tick" "$OUT" "\"$R202\""
fi
hq bash "$S_MAIN" show "$R202" --json
check_contains "show --json carries the cached summary" "$OUT" "Widgets can be exported to paper"
if [ -n "$JQ" ]; then
  hq bash "$S_MAIN" list --unreviewed --json
  check "the unreviewed --json backlog lists $R202 without its cached summary" \
    "$RC|$(printf '%s' "$OUT" | HQ_T_ID="$R202" "$JQ" -r '[.items[] | select(.id == env.HQ_T_ID)] | "\(length)|\(.[0] | has("summary_l2"))"')" \
    "0|1|false"
fi
check_absent "the unreviewed backlog never carries a cached summary" \
  "$(HUMAN_QUEUE_SCHEMA="$S_MAIN" bash "$HQ_T_CLI" list --unreviewed --json </dev/null)" "Widgets can be exported to paper"

# --- smoke: the real GitHub API ---------------------------------------------------------
REAL_GH=""
if [ -x /opt/homebrew/bin/gh ]; then REAL_GH=/opt/homebrew/bin/gh
elif command -v gh >/dev/null 2>&1; then REAL_GH=$(command -v gh); fi
if [ -z "$REAL_GH" ] || ! (unset HUMAN_QUEUE_DATABASE_URL; "$REAL_GH" auth status >/dev/null 2>&1 </dev/null); then
  echo "SKIP: real-GitHub smoke — gh is missing or not authenticated"
else
  hq bash "$S_LIVE" migrate
  check "smoke: migrate the live-GitHub schema" "$RC" "0"
  SINCE_LIVE=$(perl -MPOSIX -e 'print strftime("%Y-%m-%dT%H:%M:%SZ", gmtime(time - 6 * 3600))')
  RC=0
  HUMAN_QUEUE_SCHEMA="$S_LIVE" env -u HUMAN_QUEUE_GH -u HQ_GH_STUB_DIR bash "$HQ_T_CLI" sync-reviews \
    --since "$SINCE_LIVE" >"$TMP/out" 2>"$TMP/err" </dev/null || RC=$?
  OUT=$(cat "$TMP/out")
  check "smoke: sync-reviews against GitHub exits 0" "$RC" "0"
  check "smoke: silent on stderr" "$(cat "$TMP/err")" ""
  check_contains "smoke: tally line" "$(last_tally)" "since $SINCE_LIVE"
  FIRST=$(n_items "$S_LIVE")
  echo "smoke: $FIRST Reviews from the last six hours"
  check "smoke: every key is pr-N or issue-N" \
    "$(sql_in "$S_LIVE" "SELECT count(*) FROM items WHERE key !~ '^(pr|issue)-[1-9][0-9]*\$' OR context[1] !~ '^https://github.com/'")" "0"
  RC=0
  HUMAN_QUEUE_SCHEMA="$S_LIVE" env -u HUMAN_QUEUE_GH -u HQ_GH_STUB_DIR bash "$HQ_T_CLI" sync-reviews \
    >"$TMP/out" 2>"$TMP/err" </dev/null || RC=$?
  OUT=$(cat "$TMP/out")
  check "smoke: a second sync exits 0" "$RC" "0"
  NEW2=$(last_tally | sed -n 's/^sync-reviews: \([0-9]*\) new.*/\1/p')
  check "smoke: the second sync adds only what merged in between" "$(n_items "$S_LIVE")" "$((FIRST + ${NEW2:-0}))"
  check "smoke: no Review twice" \
    "$(sql_in "$S_LIVE" "SELECT count(*) - count(DISTINCT lower(repo) || key) FROM items")" "0"
  RC=0
  OUT=$(env -u HUMAN_QUEUE_GH -u HQ_GH_STUB_DIR -u HUMAN_QUEUE_DATABASE_URL bash \
    "$HQ_T_DESK_DIR/bin/pr-summary-material.sh" auerbachb/claude-code-config 1787 --level 1 2>"$TMP/err" </dev/null) || RC=$?
  check "smoke: material level 1 of a real PR exits 0" "$RC" "0"
  check_contains "smoke: material names the closing issue" "$OUT" "auerbachb/claude-code-config#1776 — "
fi

PUBLIC_AFTER=$(admin_sql "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public'")
check "public schema table count unchanged" "$PUBLIC_AFTER" "$PUBLIC_BEFORE"

hq_t_finish "reviews.test.sh"
