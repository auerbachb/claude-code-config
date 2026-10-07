#!/usr/bin/env bash
# desk/tests/reviews-view-offline.test.sh — offline tests for the desk's
# Reviews view (issue #1782). Needs no database and never connects to one:
# validation and secret refusal come before any connection attempt, which the
# black-hole URL proves (a connection attempt would take the full 1.5 s
# deadline). The view's rendering runs desk.jq on fixtures.
#
# Asserts:
#   CLI          summary --level: a missing, repeated, or unknown level exits
#                4; a level-1 line on two lines, blank, over 200 characters,
#                or with an escape or a tab exits 4, a secret 5 (never
#                echoed); valid level-1 and level-2 calls reach the
#                database step.
#                review --synced-today: with an id, or neither, exits 4; with
#                --comment it is validated like every comment; valid calls
#                reach the database step. --help documents both.
#   desk.jq      reviews_view (4.2): one line per item, grouped by synced
#                day and repository, newest day first, repositories by name,
#                oldest item first; Today / Yesterday / weekday labels; the
#                owner shown only when two repositories share a name; a
#                missing level-1 line falls back to the marked title; the
#                header carries the count and the level-2 estimate; an empty
#                backlog is one line. reviews_missing_l1 lists exactly the
#                items without a line, U+001F-separated. review_header names
#                the PR or issue, the repository, when it landed, a status
#                other than open, and the link.
#   skill        SKILL.md routes the Reviews verbs to reviews.md and lists it;
#                every anchored block reviews.md names exists; free text (a
#                summary, a note, a path, an issue's title and body) reaches
#                a command only through a quoted here-document, whose
#                text never holds its delimiter; follow up marks the item
#                `follow-up: filing` before filing and stops on an
#                unrecorded mark; the open
#                gate prints the cached level 2 without calling GitHub;
#                diff never writes; the scope note names #1783 and #1784.
#
# Every CLI case runs under `bash` and, when /bin/bash is 3.x (macOS), under
# /bin/bash too. Token-shaped values are assembled at run time.
set -uo pipefail

TESTS_DIR=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/testlib.sh
. "$TESTS_DIR/lib/testlib.sh"
# shellcheck source=lib/skill-block.sh
. "$TESTS_DIR/lib/skill-block.sh"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/hq-reviews-view-offline.XXXXXX")
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

BLACKHOLE_URL="postgresql://u:pw@192.0.2.1:5432/db?sslmode=require"
SKILL_DIR="$HQ_T_DESK_DIR/skill"
FIXTURE="$HQ_T_TESTS_DIR/fixtures/reviews/unreviewed.json"
FAKE_AWS="AK""IA""ABCDEFGHIJKLMNOP"

SHELLS="bash"
if [ -x /bin/bash ] && [ "$(/bin/bash -c 'echo "${BASH_VERSINFO[0]}"')" = "3" ]; then
  SHELLS="bash /bin/bash"
fi

# run_cli SHELL ARGS... — the CLI against the black-hole URL, stdin from
# $TMP/stdin; sets OUT, ERR, RC, and the elapsed time.
run_cli() {
  local sh="$1"
  shift
  ELAPSED_START=$(hq_t_now)
  RC=0
  env HUMAN_QUEUE_DATABASE_URL="$BLACKHOLE_URL" "$sh" "$HQ_T_CLI" "$@" \
    >"$TMP/out" 2>"$TMP/err" <"$TMP/stdin" || RC=$?
  ELAPSED_END=$(hq_t_now)
  OUT=$(cat "$TMP/out")
  ERR=$(cat "$TMP/err")
}

# expect_rc SHELL CODE LABEL NEEDLE ARGS... — exit CODE, one stderr line
# naming NEEDLE, nothing on stdout, no connection attempt.
expect_rc() {
  local sh="$1" code="$2" label="$3" needle="$4"
  shift 4
  run_cli "$sh" "$@"
  check "[$sh] $label: exit $code" "$RC" "$code"
  check "[$sh] $label: one stderr line" "$(hq_t_lines "$ERR")" "1"
  check "[$sh] $label: nothing on stdout" "$OUT" ""
  check_contains "[$sh] $label: names it" "$ERR" "$needle"
  if hq_t_elapsed_under "$ELAPSED_START" "$ELAPSED_END" 1.0; then
    ok "[$sh] $label (no connection attempt)"
  else
    bad "[$sh] $label took $(hq_t_elapsed "$ELAPSED_START" "$ELAPSED_END")s — it tried to connect"
  fi
}

# expect_db SHELL LABEL ARGS... — valid input reaches the database step (exit
# 7 with the URL unset).
expect_db() {
  local sh="$1" label="$2" rc=0
  shift 2
  env -u HUMAN_QUEUE_DATABASE_URL "$sh" "$HQ_T_CLI" "$@" >/dev/null 2>"$TMP/err" <"$TMP/stdin" || rc=$?
  check "[$sh] $label passes validation (exit 7, URL unset)" "$rc" "7"
}

# l1_rc SHELL CODE LABEL NEEDLE TEXT — `summary set R-1 --level 1` with TEXT on stdin.
l1_rc() {
  local sh="$1" code="$2" label="$3" needle="$4"
  printf '%s' "$5" >"$TMP/stdin"
  expect_rc "$sh" "$code" "$label" "$needle" summary set R-1 --level 1
  : >"$TMP/stdin"
}

: >"$TMP/stdin"

for SH in $SHELLS; do
  echo "=== shell: $SH — $("$SH" --version 2>&1 | sed -n 1p) ==="

  HELP=$(env -u HUMAN_QUEUE_DATABASE_URL "$SH" "$HQ_T_CLI" summary --help 2>&1)
  check_contains "[$SH] summary --help documents --level" "$HELP" "summary set ID [--level 1|2] [--file PATH]"
  check_contains "[$SH] summary --help names 007" "$HELP" "migration 007"
  HELP=$(env -u HUMAN_QUEUE_DATABASE_URL "$SH" "$HQ_T_CLI" review --help 2>&1)
  check_contains "[$SH] review --help documents --synced-today" "$HELP" "review --synced-today [--comment TEXT]"
  check_contains "[$SH] review --help keeps the single-id form" "$HELP" "review ID [--comment TEXT]"
  HELP=$(env -u HUMAN_QUEUE_DATABASE_URL "$SH" "$HQ_T_CLI" list --help 2>&1)
  check_contains "[$SH] list --help documents synced_on" "$HELP" "synced_on"

  # --- summary --level ----------------------------------------------------------
  expect_rc "$SH" 4 "summary --level with no value" "--level needs a value" summary get R-1 --level
  expect_rc "$SH" 4 "summary --level 3" "--level must be 1 or 2" summary get R-1 --level 3
  expect_rc "$SH" 4 "summary --level x" "--level must be 1 or 2" summary set R-1 --level x
  expect_rc "$SH" 4 "summary --level twice" "--level given more than once" summary get R-1 --level 1 --level 2
  expect_rc "$SH" 4 "summary --level 1 of a Decision" "D-1 is a Decision" summary get D-1 --level 1
  l1_rc "$SH" 4 "level 1 on two lines" "the level-1 line must be a single line" "$(printf 'One line.\nTwo lines.')"
  l1_rc "$SH" 4 "level 1 blank" "the summary is empty" "   "
  l1_rc "$SH" 4 "level 1 over 200 characters" "longer than 200 characters" "$(printf '%201s' x | tr ' ' y)"
  l1_rc "$SH" 4 "level 1 with an escape" "contains a control character" "$(printf 'Widgets \033[0mship.')"
  l1_rc "$SH" 4 "level 1 with a tab" "contains a control character (a tab)" "$(printf 'Widgets\tship.')"
  l1_rc "$SH" 5 "level 1 with a secret" "the summary looks like" "Rotated $FAKE_AWS for the widgets."
  check_absent "[$SH] the level-1 secret is not echoed" "$OUT$ERR" "$FAKE_AWS"
  printf '%s' "Widgets become reviewable from the desk." >"$TMP/stdin"
  expect_db "$SH" "summary set --level 1" summary set r-1 --level 1
  : >"$TMP/stdin"
  expect_db "$SH" "summary get --level 1" summary get R-1 --level 1
  expect_db "$SH" "summary get --level 2" summary get R-1 --level 2
  printf '%s\n' "**Widgets.**" "1. Changed." >"$TMP/stdin"
  expect_db "$SH" "summary set (level 2 by default)" summary set R-1
  : >"$TMP/stdin"
  # A level-2 shape is not a level-1 line, nor the other way round.
  l1_rc "$SH" 4 "a level-2 summary given as level 1" "must be a single line" "$(printf '**Widgets.**\n1. Changed.')"
  printf '%s' "Widgets become reviewable from the desk." >"$TMP/stdin"
  expect_rc "$SH" 4 "a level-1 line given as level 2" "line 1 must be one bold statement" summary set R-1
  : >"$TMP/stdin"

  # --- review --synced-today -------------------------------------------------------
  expect_rc "$SH" 4 "review with an id and --synced-today" "not both" review R-1 --synced-today
  expect_rc "$SH" 4 "review --synced-today then an id" "not both" review --synced-today R-1
  expect_rc "$SH" 4 "review with neither" "missing item id" review
  expect_rc "$SH" 4 "review --synced-today with a two-line comment" "--comment must be a single line" \
    review --synced-today --comment "$(printf 'a\nb')"
  expect_rc "$SH" 5 "review --synced-today with a secret comment" "--comment looks like" \
    review --synced-today --comment "key $FAKE_AWS"
  check_absent "[$SH] the --synced-today comment secret is not echoed" "$OUT$ERR" "$FAKE_AWS"
  expect_db "$SH" "review --synced-today" review --synced-today
  expect_db "$SH" "review --synced-today --comment" review --synced-today --comment "read them all"
  expect_db "$SH" "review of one id" review r-2
done

# ------------------------------------------------------------------ desk.jq
printf '== desk.jq\n'
JQ=$(command -v jq 2>/dev/null || true)
if [ -z "$JQ" ]; then
  echo "SKIP: desk.jq cases — jq is not installed"
else
  jqd() { "$JQ" -r -L "$SKILL_DIR" "include \"desk\"; $1" "${2:-$FIXTURE}"; }
  VIEW=$(jqd reviews_view)
  EXPECTED='Reviews · 6 unreviewed · ~120 lines at level 2

Today · acme/widgets (3)
R-1 · PR #101 · Widgets become reviewable from the desk.
R-2 · PR #102 · fix: widget count (title; not summarized yet)
R-10 · Issue #202 · Captured issue: widgets can be exported to paper.

Today · gadgets (1)
R-5 · PR #8 · feat: gadgets (title; not summarized yet)

Yesterday · other/widgets (1)
R-4 · PR #9 · Other widgets ship.

Mon Oct 5 · gadgets (1)
R-3 · PR #7 · The gadget guide explains setup end to end.

Next: open R-<n> · diff R-<n> [path] · reviewed R-<n> · reviewed all today · flag R-<n> "…"'
  check "4.2 reviews_view: grouped by day and repo, one line each" "$VIEW" "$EXPECTED"
  check "4.2 one line per item" "$(printf '%s\n' "$VIEW" | grep -c '^R-[0-9]* · ')" "6"
  check "reviews_view of an empty backlog" \
    "$(printf '%s' '{"count":0,"level2_lines":0,"today":"2026-10-07","items":[]}' | "$JQ" -r -L "$SKILL_DIR" 'include "desk"; reviews_view')" \
    "No unreviewed Reviews."
  check "a day eleven days back is a weekday label" \
    "$(printf '%s' '"2026-09-26"' | "$JQ" -r -L "$SKILL_DIR" 'include "desk"; day_label("2026-10-07")')" "Sat Sep 26"
  check "a malformed day is Undated" \
    "$(printf '%s' 'null' | "$JQ" -r -L "$SKILL_DIR" 'include "desk"; day_label("2026-10-07")')" "Undated"
  check "yesterday across a month boundary" \
    "$(printf '%s' '"2026-09-30"' | "$JQ" -r -L "$SKILL_DIR" 'include "desk"; day_label("2026-10-01")')" "Yesterday"
  MISSING=$(jqd reviews_missing_l1 | tr '\037' '|')
  check "reviews_missing_l1: exactly the items without a line" "$MISSING" "R-2|acme/widgets|pr-102
R-5|acme/gadgets|pr-8"
  check "review_header of an open PR" "$(jqd '.items[2] | review_header')" \
    "R-2 · PR #102 · acme/widgets · Merged 2026-10-07 14:00 UTC
https://github.com/acme/widgets/pull/102"
  check "review_header names a status other than open" "$(jqd '.items[1] + {status: "flagged"} | review_header')" \
    "R-10 · Issue #202 · acme/widgets · Filed 2026-10-07 13:00 UTC · flagged
https://github.com/acme/widgets/issues/202"
fi

# ------------------------------------------------------------------- skill
printf '== skill\n'
SKILL=$(cat "$SKILL_DIR/SKILL.md")
REVIEWS=$(cat "$SKILL_DIR/reviews.md")
contract() {
  local label="$1" text="$2" needle
  while IFS= read -r needle; do
    [ -n "$needle" ] || continue
    check_contains "$label: $needle" "$text" "$needle"
  done
}
contract SKILL.md "$SKILL" <<'NEEDLES'
| `reviews.md` |
→ load `reviews.md`
`open R-<n>`, `diff R-<n> [path]`, `reviewed` (`reviewed R-<n>`, `reviewed all today`), `flag R-<n> "…"`
`follow up R-<n>` (`follow up R-<n> again`)
(#1783)
(#1784)
007_reviews_summary_l1.sql
NEEDLES
check_absent "SKILL.md: still no deferred increment phrase" "$SKILL" "next increment"
contract reviews.md "$REVIEWS" <<'NEEDLES'
"$HQ" sync-reviews >/dev/null; echo "exit=$?"
'include "desk"; reviews_missing_l1'
--level 1 </dev/null; echo "exit=$?"
"$HQ" summary set R-3 --level 1 <<'DESK_L1'
'include "desk"; reviews_view'
"$HQ" summary set R-2 <<'DESK_SUMMARY'
"$HQ" review --synced-today; echo "exit=$?"
"$HQ" flag R-2 --note "$(cat "$NOTE_FILE")"
<<'DESK_NOTE'
<<'DESK_PATH'
<<'DESK_TITLE'
<<'DESK_BODY'
A here-document's text never holds its own delimiter.
pick another one that no line of the text equals, for both lines
"$HQ" comment R-2 "follow-up: filing" >/dev/null; rc=$?
then "pending=yes" else empty end
reply "follow up R-2 again" to file it anyway
--level 3
never stored
Never invent.
_Captured via /issue-maker._
the item's own repository
#1783
#1784
#1768
NEEDLES

for a in desk-reviews-sync desk-reviews-l1-material desk-reviews-l1-cache desk-reviews-view desk-open \
         desk-open-cache desk-diff desk-reviewed desk-reviewed-today desk-flag desk-follow-up-check desk-follow-up; do
  rc=0
  BODY=$(hq_t_skill_block "$SKILL_DIR/reviews.md" "$a" 2>&1) || rc=$?
  check "anchor $a extracts" "$rc" "0"
  if [ "$rc" -eq 0 ] && bash -n <(printf '%s\n' "$BODY") 2>"$TMP/syntax"; then
    ok "anchor $a is valid bash"
  else
    bad "anchor $a is valid bash ($(cat "$TMP/syntax" 2>/dev/null))"
  fi
done

# The open gate, against a stub CLI and a gh that fails the test if called:
# with summary_l2 cached it prints it and calls nothing on GitHub.
if [ -n "$JQ" ]; then
  mkdir -p "$TMP/bin"
  printf '%s\n' '#!/usr/bin/env bash' 'cat "$STUB_ITEM"' >"$TMP/bin/hq-stub"
  printf '%s\n' '#!/usr/bin/env bash' 'echo called >>"$GH_CALLS"; exit 99' >"$TMP/bin/gh"
  chmod +x "$TMP/bin/hq-stub" "$TMP/bin/gh"
  printf '%s' '{"id":"R-2","kind":"review","status":"open","repo":"acme/widgets","key":"pr-102","question":"fix","context":["https://github.com/acme/widgets/pull/102","Merged 2026-10-07 14:00 UTC"],"summary_l2":"**Widget counts are right again.**\n1. Tests: count.test.sh."}' >"$TMP/item.json"
  hq_t_skill_block "$SKILL_DIR/reviews.md" desk-open >"$TMP/open.sh"
  : >"$TMP/gh-calls"
  OUT=$(env DESK="$HQ_T_DESK_DIR" HQ="$TMP/bin/hq-stub" STUB_ITEM="$TMP/item.json" GH_CALLS="$TMP/gh-calls" \
    HUMAN_QUEUE_GH="$TMP/bin/gh" PATH="$TMP/bin:$PATH" bash "$TMP/open.sh" 2>&1)
  check "open gate, cached: header, blank line, the summary" "$OUT" "R-2 · PR #102 · acme/widgets · Merged 2026-10-07 14:00 UTC
https://github.com/acme/widgets/pull/102

**Widget counts are right again.**
1. Tests: count.test.sh."
  check "open gate, cached: no GitHub call" "$(cat "$TMP/gh-calls")" ""
fi

# Level 3 is never written: the diff block holds no store write and no
# redirect into a lasting file.
DIFF_BLOCK=$(hq_t_skill_block "$SKILL_DIR/reviews.md" desk-diff 2>/dev/null || true)
for verb in 'summary set' ' comment ' ' flag ' ' review ' ' state set'; do
  check_absent "the diff block never runs$verb" "$DIFF_BLOCK" "$verb"
done
check "the diff block's only file is the path's own temp file" \
  "$(printf '%s\n' "$DIFF_BLOCK" | grep -c '> "')" "1"

hq_t_finish "reviews-view-offline.test.sh"
