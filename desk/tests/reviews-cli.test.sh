#!/usr/bin/env bash
# desk/tests/reviews-cli.test.sh — offline contract tests for Reviews (issue
# #1756): sync-reviews, summary, review --comment, flag's bare note,
# list --unreviewed, and pr-summary-material.sh. Needs no database and never
# connects to one: validation and secret refusal come before any connection
# attempt, which the black-hole URL below proves (a connection attempt would
# take the full 1.5 s deadline). GitHub is a stub (tests/lib/gh-stub.sh)
# serving tests/fixtures/github/, so nothing here reaches the network.
#
# Asserts:
#   - human-queue.sh --help lists sync-reviews and summary; their --help is
#     offline, documents exit codes, and says what is never stored
#   - sync-reviews: a malformed --since, a repeated --since, a stray
#     argument, and a bad HUMAN_QUEUE_SYNC_LIMIT exit 4 without connecting;
#     a date or a zoned time passes validation
#   - summary: missing or unknown actions, Decision ids, an empty id (also
#     one before a real id, which is never used), an empty summary,
#     a terminal-free empty stdin, a first line that is not bold, a line that
#     is not a numbered point, no points at all, too many lines or
#     characters, control characters, and an unreadable --file exit 4 (1 for
#     the file); a secret exits 5 and is never echoed; the shape passes
#   - review --comment and flag's note (bare or --note) are validated like
#     every note: over-long, multi-line, control characters (4), secrets (5)
#   - list: plural kinds, --unreviewed and its conflicts
#   - state set refuses the reserved reviews_watermark
#   - pr-summary-material.sh (Test Plan 5.2): levels 1, 2, and 3 of a PR
#     print the expected sections; --path narrows level 3 to one file (also
#     by a rename, and never by a line inside another file's hunk); caps
#     truncate with a marker; an issue's levels use its body; not found,
#     the wrong kind, a path not in the diff, and a number past GitHub's
#     32-bit range (without calling GitHub) exit 3; usage exits 4; lists
#     GitHub returned in part say how many are missing (labels, closing
#     issues, files Tests touched could not check); control characters in
#     GitHub's text and the diff print as "?" (a CRLF as LF);
#     a GitHub failure and a deadline exit 1 with one stderr line
#
# Every case runs under `bash` on PATH and, when /bin/bash is 3.x (macOS),
# under /bin/bash too. Token-shaped values are assembled at run time so this
# file never contains one verbatim.
set -uo pipefail

# shellcheck source=lib/testlib.sh
. "$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/testlib.sh"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/hq-reviews-cli-test.XXXXXX")
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

BLACKHOLE_URL="postgresql://u:pw@192.0.2.1:5432/db?sslmode=require"
MATERIAL="$HQ_T_DESK_DIR/bin/pr-summary-material.sh"
STUB="$HQ_T_TESTS_DIR/lib/gh-stub.sh"
FIXTURES="$HQ_T_TESTS_DIR/fixtures/github"

SHELLS="bash"
if [ -x /bin/bash ] && [ "$(/bin/bash -c 'echo "${BASH_VERSINFO[0]}"')" = "3" ]; then
  SHELLS="bash /bin/bash"
fi

ALNUM36="abcdefghijklmnopqrstuvwxyz0123456789"
FAKE_GH="gh""p_$ALNUM36"
FAKE_AWS="AK""IA""ABCDEFGHIJKLMNOP"

# Control characters material must never print: C0 but tab and newline, DEL,
# and C1 (U+0080-U+009F, two bytes in UTF-8).
C0_RE=$(printf '[\001-\010\013-\037\177]')
C1_RE=$(printf '\302[\200-\237]')

GOOD_SUMMARY='**Widgets now land in the review queue.**
1. sync-reviews adds one R-n per merged PR.
   It runs from the desk.

2. Tests: reviews.test.sh.'

# run_cli SHELL ARGS... — runs the CLI against the black-hole URL with stdin
# from $TMP/stdin (empty unless a case writes it); sets OUT, ERR, RC,
# ELAPSED_START, ELAPSED_END.
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
# containing NEEDLE, nothing on stdout, and no connection attempt.
expect_rc() {
  local sh="$1" code="$2" label="$3" needle="$4"
  shift 4
  run_cli "$sh" "$@"
  check "[$sh] $label: exit $code" "$RC" "$code"
  check "[$sh] $label: one stderr line" "$(hq_t_lines "$ERR")" "1"
  check "[$sh] $label: nothing on stdout" "$OUT" ""
  if [ -n "$needle" ]; then check_contains "[$sh] $label: names it" "$ERR" "$needle"; fi
  if hq_t_elapsed_under "$ELAPSED_START" "$ELAPSED_END" 1.0; then
    ok "[$sh] $label (no connection attempt)"
  else
    bad "[$sh] $label took $(hq_t_elapsed "$ELAPSED_START" "$ELAPSED_END")s — it tried to connect"
  fi
}

# expect_db SHELL LABEL ARGS... — valid input reaches the database step: with
# the URL unset that is exit 7.
expect_db() {
  local sh="$1" label="$2" rc=0
  shift 2
  env -u HUMAN_QUEUE_DATABASE_URL "$sh" "$HQ_T_CLI" "$@" >/dev/null 2>"$TMP/err" <"$TMP/stdin" || rc=$?
  check "[$sh] $label passes validation (exit 7, URL unset)" "$rc" "7"
}

# summary_rc SHELL CODE LABEL NEEDLE TEXT — `summary set R-1` with TEXT on stdin.
summary_rc() {
  local sh="$1" code="$2" label="$3" needle="$4"
  printf '%s' "$5" >"$TMP/stdin"
  expect_rc "$sh" "$code" "$label" "$needle" summary set R-1
  : >"$TMP/stdin"
}

# material SHELL ARGS... — runs pr-summary-material.sh against the stub;
# sets OUT, ERR, RC.
material() {
  local sh="$1"
  shift
  RC=0
  env HUMAN_QUEUE_GH="$STUB" HQ_GH_STUB_DIR="$STUB_DIR" "$sh" "$MATERIAL" "$@" \
    >"$TMP/out" 2>"$TMP/err" </dev/null || RC=$?
  OUT=$(cat "$TMP/out")
  ERR=$(cat "$TMP/err")
}

# material_rc SHELL CODE LABEL NEEDLE ARGS... — exit CODE, one stderr line.
material_rc() {
  local sh="$1" code="$2" label="$3" needle="$4"
  shift 4
  material "$sh" "$@"
  check "[$sh] material: $label: exit $code" "$RC" "$code"
  check "[$sh] material: $label: one stderr line" "$(hq_t_lines "$ERR")" "1"
  check_contains "[$sh] material: $label: names it" "$ERR" "$needle"
}

# section_lines TEXT NAME — the lines under `## NAME`, up to the next section.
section_lines() {
  printf '%s\n' "$1" | awk -v want="## $2" '
    /^## / { inside = ($0 == want); next }
    inside { print }'
}

: >"$TMP/stdin"
STUB_DIR="$TMP/stub"
mkdir -p "$STUB_DIR"
cp "$FIXTURES"/* "$STUB_DIR"/

for SH in $SHELLS; do
  echo "=== shell: $SH — $("$SH" --version 2>&1 | sed -n 1p) ==="

  # --- help --------------------------------------------------------------------
  RC=0
  OUT=$(env -u HUMAN_QUEUE_DATABASE_URL "$SH" "$HQ_T_CLI" --help 2>&1) || RC=$?
  check "[$SH] human-queue.sh --help exits 0" "$RC" "0"
  for c in sync-reviews summary; do
    check_contains "[$SH] --help lists $c" "$OUT" "  $c "
  done
  for c in sync-reviews summary review flag list; do
    RC=0
    OUT=$(env -u HUMAN_QUEUE_DATABASE_URL "$SH" "$HQ_T_CLI" "$c" --help 2>"$TMP/err") || RC=$?
    check "[$SH] $c --help exits 0 without a database" "$RC" "0"
    check_contains "[$SH] $c --help documents exit codes" "$OUT" "EXIT CODES"
    check "[$SH] $c --help is silent on stderr" "$(cat "$TMP/err")" ""
  done
  check_contains "[$SH] sync-reviews --help names the footer" \
    "$(env -u HUMAN_QUEUE_DATABASE_URL "$SH" "$HQ_T_CLI" sync-reviews --help)" "_Captured via /issue-maker._"
  check_contains "[$SH] summary --help says level 3 is never stored" \
    "$(env -u HUMAN_QUEUE_DATABASE_URL "$SH" "$HQ_T_CLI" summary --help)" "fetched live, never stored"
  check_contains "[$SH] review --help documents --comment" \
    "$(env -u HUMAN_QUEUE_DATABASE_URL "$SH" "$HQ_T_CLI" review --help)" "review ID [--comment TEXT]"
  check_contains "[$SH] list --help documents --unreviewed" \
    "$(env -u HUMAN_QUEUE_DATABASE_URL "$SH" "$HQ_T_CLI" list --help)" "lines at level 2"

  # --- sync-reviews ------------------------------------------------------------
  expect_rc "$SH" 4 "sync-reviews with a malformed --since" "--since" sync-reviews --since yesterday
  expect_rc "$SH" 4 "sync-reviews with an impossible date" "not a real date" sync-reviews --since 2026-02-30
  expect_rc "$SH" 4 "sync-reviews with a zoneless time" "time zone" sync-reviews --since 2026-10-05T12:00
  expect_rc "$SH" 4 "sync-reviews with --since twice" "given more than once" \
    sync-reviews --since 2026-10-01 --since 2026-10-02
  expect_rc "$SH" 4 "sync-reviews with --since and no value" "needs a value" sync-reviews --since
  expect_rc "$SH" 4 "sync-reviews with a stray argument" "unknown argument" sync-reviews everything
  expect_rc "$SH" 4 "sync-reviews with an unknown flag" "unknown option '--all'" sync-reviews --all
  for lim in 0 1001 abc 007 99999999999999999999; do
    RC=0
    env HUMAN_QUEUE_DATABASE_URL="$BLACKHOLE_URL" HUMAN_QUEUE_SYNC_LIMIT="$lim" "$SH" "$HQ_T_CLI" \
      sync-reviews --since 2026-10-01 >/dev/null 2>"$TMP/err" </dev/null || RC=$?
    check "[$SH] HUMAN_QUEUE_SYNC_LIMIT=$lim exits 4" "$RC" "4"
  done
  expect_db "$SH" "sync-reviews with a date" sync-reviews --since 2026-10-01
  expect_db "$SH" "sync-reviews with a zoned time" sync-reviews --since 2026-10-05T14:00-04:00 --json
  expect_db "$SH" "sync-reviews from the watermark" sync-reviews

  # --- summary -----------------------------------------------------------------
  expect_rc "$SH" 4 "summary without an action" "missing action" summary
  expect_rc "$SH" 4 "summary with an unknown action" "unknown action" summary show R-1
  expect_rc "$SH" 4 "summary get without an id" "missing item id" summary get
  expect_rc "$SH" 4 "summary get of a Decision" "D-1 is a Decision" summary get D-1
  expect_rc "$SH" 4 "summary get with two ids" "takes one item id" summary get R-1 R-2
  expect_rc "$SH" 4 "summary set with an empty id before a real one" "takes one item id" summary set "" R-1
  expect_rc "$SH" 4 "summary get of an empty id" "invalid item id" summary get ""
  expect_rc "$SH" 4 "summary get with --file" "unknown option '--file'" summary get R-1 --file x
  expect_db "$SH" "summary get" summary get r-1
  summary_rc "$SH" 4 "summary set of nothing" "the summary is empty" ""
  summary_rc "$SH" 4 "summary set without a bold line" "line 1 must be one bold statement" \
    "Widgets.
1. One."
  summary_rc "$SH" 4 "summary set with an empty bold line" "line 1 must be one bold statement" \
    "****
1. One."
  summary_rc "$SH" 4 "summary set without points" "followed by numbered points" "**Widgets.**"
  summary_rc "$SH" 4 "summary set with a stray line" "line 3 is not a numbered point" \
    "**Widgets.**
1. One.
stray prose"
  summary_rc "$SH" 4 "summary set of a diff" "line 2 is not a numbered point" \
    "**Widgets.**
diff --git a/x b/x
1. One."
  summary_rc "$SH" 4 "summary set over the line cap" "longer than 40 lines" \
    "**Widgets.**
$(i=1; while [ "$i" -le 40 ]; do printf '%s. point\n' "$i"; i=$((i + 1)); done)"
  summary_rc "$SH" 4 "summary set over the character cap" "longer than 4000 characters" \
    "**Widgets.**
1. $(printf '%4000s' x)"
  summary_rc "$SH" 4 "summary set with an escape" "contains a control character" \
    "**Widgets.**
1. $(printf 'x\033[0m')"
  summary_rc "$SH" 5 "summary set with a secret" "the summary looks like" \
    "**Widgets.**
1. key $FAKE_AWS"
  check_absent "[$SH] the summary secret is not echoed" "$OUT$ERR" "$FAKE_AWS"
  printf '%s' "$GOOD_SUMMARY" >"$TMP/stdin"
  expect_rc "$SH" 4 "summary set of a Decision" "D-1 is a Decision" summary set D-1
  expect_db "$SH" "summary set from stdin" summary set R-1
  : >"$TMP/stdin"
  printf '%s\n' "$GOOD_SUMMARY" >"$TMP/summary.md"
  expect_db "$SH" "summary set --file" summary set R-1 --file "$TMP/summary.md"
  RC=0
  env HUMAN_QUEUE_DATABASE_URL="$BLACKHOLE_URL" "$SH" "$HQ_T_CLI" summary set R-1 --file "$TMP/missing.md" \
    >/dev/null 2>"$TMP/err" </dev/null || RC=$?
  check "[$SH] summary set with an unreadable --file exits 1" "$RC" "1"
  check_contains "[$SH] summary set names the unreadable --file" "$(cat "$TMP/err")" "cannot read --file"

  # --- review --comment, flag's note ---------------------------------------------
  expect_rc "$SH" 4 "review with an over-long comment" "--comment is longer than 200" \
    review R-1 --comment "$(printf '%201s' x)"
  expect_rc "$SH" 4 "review with a two-line comment" "--comment must be a single line" \
    review R-1 --comment "$(printf 'a\nb')"
  expect_rc "$SH" 4 "review with a comment escape" "--comment contains a control character" \
    review R-1 --comment "$(printf 'x\033[0m')"
  expect_rc "$SH" 4 "review with --comment twice" "given more than once" review R-1 --comment a --comment b
  expect_rc "$SH" 4 "review with --comment and no value" "needs a value" review R-1 --comment
  expect_rc "$SH" 5 "review with a secret comment" "--comment looks like" review R-1 --comment "token $FAKE_GH"
  check_absent "[$SH] the review comment is not echoed" "$OUT$ERR" "$FAKE_GH"
  expect_rc "$SH" 4 "review of a Decision with a comment" "D-1 is a Decision" review D-1 --comment fine
  expect_db "$SH" "review with a comment" review R-1 --comment "looks right"
  expect_db "$SH" "review with the comment first" review --comment "looks right" R-1
  expect_rc "$SH" 4 "flag with a bare note and --note" "give the note once" flag R-1 first --note second
  expect_rc "$SH" 4 "flag with --note and a bare note" "give the note once" flag R-1 --note first second
  expect_rc "$SH" 4 "flag with an over-long bare note" "the note is longer than 200" flag R-1 "$(printf '%201s' x)"
  expect_rc "$SH" 5 "flag with a secret bare note" "the note looks like" flag R-1 "key $FAKE_AWS"
  check_absent "[$SH] the bare flag note is not echoed" "$OUT$ERR" "$FAKE_AWS"
  expect_db "$SH" "flag with a quoted bare note" flag R-1 "add a test for the empty case"

  # --- list, state ---------------------------------------------------------------
  expect_db "$SH" "list --kind reviews" list --kind reviews
  expect_db "$SH" "list --kind decisions" list --kind decisions --json
  expect_db "$SH" "list --kind reviews --unreviewed" list --kind reviews --unreviewed
  expect_db "$SH" "list --unreviewed --json" list --unreviewed --json
  expect_rc "$SH" 4 "list --unreviewed with --status" "drop --status" list --unreviewed --status open
  expect_rc "$SH" 4 "list --unreviewed of Decisions" "cannot take --kind decision" list --kind decisions --unreviewed
  expect_rc "$SH" 4 "list with a plural unknown kind" "--kind must be decision or review" list --kind ideas
  expect_rc "$SH" 4 "state set reviews_watermark" "only sync-reviews writes it" state set reviews_watermark x
  expect_db "$SH" "state get reviews_watermark" state get reviews_watermark

  # --- pr-summary-material.sh (Test Plan 5.2) ------------------------------------
  RC=0
  OUT=$("$SH" "$MATERIAL" --help 2>"$TMP/err") || RC=$?
  check "[$SH] material --help exits 0" "$RC" "0"
  check_contains "[$SH] material --help documents the levels" "$OUT" "LEVELS (a PR)"
  check_contains "[$SH] material --help documents exit codes" "$OUT" "EXIT CODES"
  check_absent "[$SH] material --help leaves out the catalog line" "$OUT" "catalog:"
  check "[$SH] material --help is silent on stderr" "$(cat "$TMP/err")" ""

  : >"$STUB_DIR/calls.log"
  material_rc "$SH" 4 "no arguments" "missing OWNER/REPO"
  material_rc "$SH" 4 "no level" "missing --level" acme/widgets 101
  material_rc "$SH" 4 "level 4" "--level must be 1, 2, or 3" acme/widgets 101 --level 4
  material_rc "$SH" 4 "a bad repository" "OWNER/REPO" acme 101 --level 1
  material_rc "$SH" 4 "a bad number" "positive whole number" acme/widgets 1a --level 1
  material_rc "$SH" 4 "a bad key" "positive whole number" acme/widgets pr- --level 1
  material_rc "$SH" 4 "--path at level 2" "give --level 3" acme/widgets 101 --level 2 --path src/widget.sh
  material_rc "$SH" 4 "an empty --path" "--path is empty" acme/widgets 101 --level 3 --path ""
  material_rc "$SH" 4 "three positionals" "takes OWNER/REPO and one number" acme/widgets 101 102 --level 1
  RC=0
  env HUMAN_QUEUE_GH="$STUB" HQ_GH_STUB_DIR="$STUB_DIR" HQ_MATERIAL_DIFF_LINES=0 "$SH" "$MATERIAL" \
    acme/widgets 101 --level 3 >/dev/null 2>"$TMP/err" </dev/null || RC=$?
  check "[$SH] material: a zero cap exits 4" "$RC" "4"
  check_contains "[$SH] material: a zero cap is named" "$(cat "$TMP/err")" "HQ_MATERIAL_DIFF_LINES"
  check "[$SH] material: usage errors never call GitHub" "$(cat "$STUB_DIR/calls.log")" ""

  # Level 1 of a PR: title, labels, the closing issue with its title.
  material "$SH" acme/widgets 101 --level 1
  check "[$SH] material L1: exit 0" "$RC" "0"
  check "[$SH] material L1: silent on stderr" "$ERR" ""
  check "[$SH] material L1: header" "$(printf '%s\n' "$OUT" | sed -n 1p)" \
    "PR acme/widgets#101 · merged 2026-10-05 21:34 UTC"
  check "[$SH] material L1: sections" "$(printf '%s\n' "$OUT" | grep '^## ' | paste -sd, -)" \
    "## Title,## Labels,## Closes"
  check "[$SH] material L1: labels" "$(section_lines "$OUT" Labels)" "enhancement, desk"
  check "[$SH] material L1: the closing issue's title" "$(section_lines "$OUT" Closes)" \
    "acme/widgets#90 — Make widgets reviewable"

  # Level 2: level 1 plus body, commits, files, tests, links.
  material "$SH" acme/widgets 101 --level 2
  check "[$SH] material L2: exit 0" "$RC" "0"
  check "[$SH] material L2: sections" "$(printf '%s\n' "$OUT" | grep '^## ' | grep -v '^## Summary$' | paste -sd, -)" \
    "## Title,## Labels,## Closes,## Size,## Body,## Commits (3),## Files changed (4),## Tests touched,## Links"
  check "[$SH] material L2: size" "$(section_lines "$OUT" Size)" "4 files · +75 -3 · 3 commits"
  check_contains "[$SH] material L2: the body" "$OUT" "Widgets now land in the review queue."
  check "[$SH] material L2: commit subjects" "$(section_lines "$OUT" 'Commits (3)' | paste -sd'|' -)" \
    "- feat(#90): widgets become reviewable|- test(#90): cover the widget queue|- docs(#90): describe reviews"
  check_contains "[$SH] material L2: files with line counts" "$(section_lines "$OUT" 'Files changed (4)')" \
    "- src/widget.sh +40 -2"
  check "[$SH] material L2: tests touched" "$(section_lines "$OUT" 'Tests touched')" "- tests/widget.test.sh"
  check "[$SH] material L2: links" "$(section_lines "$OUT" Links | paste -sd'|' -)" \
    "- PR: https://github.com/acme/widgets/pull/101|- Closes: https://github.com/acme/widgets/issues/90"

  # Level 3: the diff, every file; --path narrows it to one.
  material "$SH" acme/widgets 101 --level 3
  check "[$SH] material L3: exit 0" "$RC" "0"
  check "[$SH] material L3: every file's diff" "$(printf '%s\n' "$OUT" | grep -c '^diff --git ')" "4"
  check_absent "[$SH] material L3: no level-2 sections" "$OUT" "## Title"
  material "$SH" acme/widgets pr-101 --level 3 --path src/widget.sh
  check "[$SH] material L3 --path: exit 0" "$RC" "0"
  check "[$SH] material L3 --path: one file" "$(printf '%s\n' "$OUT" | grep '^diff --git ')" \
    "diff --git a/src/widget.sh b/src/widget.sh"
  check_contains "[$SH] material L3 --path: titled with the path" "$OUT" "## Diff: src/widget.sh"
  check_contains "[$SH] material L3 --path: its hunk" "$OUT" "+echo widget"
  check_absent "[$SH] material L3 --path: not a line inside another file's hunk" "$OUT" "# Widgets"
  material "$SH" acme/widgets 101 --level 3 --path src/old_name.sh
  check "[$SH] material L3 --path by a rename's old name" "$(printf '%s\n' "$OUT" | grep '^diff --git ')" \
    "diff --git a/src/old_name.sh b/src/new_name.sh"
  material_rc "$SH" 3 "a path not in the diff" "no file 'src/nope.sh'" acme/widgets 101 --level 3 --path src/nope.sh

  # Caps.
  RC=0
  OUT=$(env HUMAN_QUEUE_GH="$STUB" HQ_GH_STUB_DIR="$STUB_DIR" HQ_MATERIAL_DIFF_LINES=5 "$SH" "$MATERIAL" \
    acme/widgets 101 --level 3 2>/dev/null) || RC=$?
  check "[$SH] material: the diff line cap" "$(printf '%s\n' "$OUT" | tail -n 1)" \
    "[truncated: 5 of 28 lines shown (caps: 5 lines, 200000 bytes); narrow with --path]"
  OUT=$(env HUMAN_QUEUE_GH="$STUB" HQ_GH_STUB_DIR="$STUB_DIR" HQ_MATERIAL_DIFF_BYTES=60 "$SH" "$MATERIAL" \
    acme/widgets 101 --level 3 2>/dev/null) || RC=$?
  check_contains "[$SH] material: the diff byte cap" "$OUT" "[truncated: 1 of 28 lines shown"
  OUT=$(env HUMAN_QUEUE_GH="$STUB" HQ_GH_STUB_DIR="$STUB_DIR" HQ_MATERIAL_BODY_CHARS=10 "$SH" "$MATERIAL" \
    acme/widgets 101 --level 2 2>/dev/null) || RC=$?
  check_contains "[$SH] material: the body cap" "$OUT" "[truncated: 10 of 74 characters shown]"

  # Lists GitHub returned in part, and untrusted text (fixture 303).
  material "$SH" acme/widgets 303 --level 2
  check "[$SH] material 303: exit 0, silent on stderr" "$RC|$ERR" "0|"
  check "[$SH] material 303: labels left out are counted" "$(section_lines "$OUT" Labels | paste -sd'|' -)" \
    "big, desk|… and 21 more labels not listed"
  check "[$SH] material 303: closing issues left out are counted" "$(section_lines "$OUT" Closes | paste -sd'|' -)" \
    "acme/widgets#91 — Large change|… and 11 more closing issues not listed"
  check "[$SH] material 303: Links counts them too" "$(section_lines "$OUT" Links | tail -n 1)" \
    "… and 11 more closing issues not listed"
  check "[$SH] material 303: Tests touched says what it could not check" \
    "$(section_lines "$OUT" 'Tests touched' | paste -sd'|' -)" \
    "- tests/big.test.sh|… 148 more files not checked (GitHub lists the first 2)"
  check "[$SH] material 303: control characters print as ?" "$(section_lines "$OUT" Title)" \
    "feat: a ?[31mloud?[0m title"
  check "[$SH] material 303: a CRLF body reads as lines" "$(section_lines "$OUT" Body | paste -sd'|' -)" \
    "First line|an escape ?]0;pwned? here|a C1 ?2J control"
  check "[$SH] material 303: no C0 or DEL byte is printed" "$(printf '%s\n' "$OUT" | LC_ALL=C grep -c "$C0_RE")" "0"
  check "[$SH] material 303: no C1 character is printed" "$(printf '%s\n' "$OUT" | LC_ALL=C grep -c "$C1_RE")" "0"
  material "$SH" acme/widgets 303 --level 3
  check "[$SH] material 303 L3: exit 0" "$RC" "0"
  check "[$SH] material 303 L3: escapes in the diff print as ?" "$(printf '%s\n' "$OUT" | grep '^+echo' | paste -sd'|' -)" \
    '+echo "?[2J cleared"|+echo "? c1"'
  check "[$SH] material 303 L3: a CRLF line ends as LF" "$(printf '%s\n' "$OUT" | grep -c '^-old$')" "1"
  check "[$SH] material 303 L3: no C0 or DEL byte is printed" "$(printf '%s\n' "$OUT" | LC_ALL=C grep -c "$C0_RE")" "0"
  check "[$SH] material 303 L3: no C1 character is printed" "$(printf '%s\n' "$OUT" | LC_ALL=C grep -c "$C1_RE")" "0"

  # An issue: levels 1 and 2 use the body, level 3 is the whole body.
  material "$SH" acme/widgets issue-202 --level 1
  check "[$SH] material issue L1: exit 0" "$RC" "0"
  check "[$SH] material issue L1: header" "$(printf '%s\n' "$OUT" | sed -n 1p)" \
    "Issue acme/widgets#202 · open · filed 2026-10-05 16:49 UTC"
  check "[$SH] material issue L1: sections" "$(printf '%s\n' "$OUT" | grep -E '^## (Title|Labels|Body|Links)' | paste -sd, -)" \
    "## Title,## Labels,## Body (excerpt)"
  OUT=$(env HUMAN_QUEUE_GH="$STUB" HQ_GH_STUB_DIR="$STUB_DIR" HQ_MATERIAL_EXCERPT_CHARS=20 "$SH" "$MATERIAL" \
    acme/widgets 202 --level 1 2>/dev/null) || RC=$?
  check_contains "[$SH] material issue L1: the excerpt cap" "$OUT" "[truncated: 20 of"
  material "$SH" acme/widgets 202 --level 2
  check "[$SH] material issue L2: sections" "$(printf '%s\n' "$OUT" | grep -E '^## (Title|Labels|Body|Links)' | paste -sd, -)" \
    "## Title,## Labels,## Body,## Links"
  check_contains "[$SH] material issue L2: the body" "$OUT" "The operator wants widgets on paper."
  material "$SH" acme/widgets 202 --level 3
  check "[$SH] material issue L3: exit 0" "$RC" "0"
  check_contains "[$SH] material issue L3: the full body" "$OUT" "_Captured via /issue-maker._"
  check_absent "[$SH] material issue L3: no title section" "$OUT" "## Title"
  material_rc "$SH" 4 "--path on an issue" "is an issue" acme/widgets 202 --level 3 --path x

  # Not found, the wrong kind, GitHub failures.
  material_rc "$SH" 3 "a number GitHub does not know" "no PR or issue acme/widgets#404" acme/widgets 404 --level 1
  : >"$STUB_DIR/calls.log"
  material_rc "$SH" 3 "a number past GitHub's 32-bit range" "no PR or issue acme/widgets#2147483648" \
    acme/widgets 2147483648 --level 1
  check "[$SH] material: a number past the range never calls GitHub" "$(cat "$STUB_DIR/calls.log")" ""
  material_rc "$SH" 3 "an issue key on a PR" "is a PR, not an issue" acme/widgets issue-101 --level 1
  material_rc "$SH" 3 "a PR key on an issue" "is an issue, not a PR" acme/widgets pr-202 --level 2
  material_rc "$SH" 1 "a missing fixture (GitHub failed)" "GitHub failed" acme/widgets 555 --level 1
  printf '1\n' >"$STUB_DIR/pr-101.rc"
  printf 'HTTP 406: the diff exceeded the maximum number of files\n' >"$STUB_DIR/pr-101.err"
  material_rc "$SH" 1 "a diff GitHub refuses" "did not return the diff: HTTP 406" acme/widgets 101 --level 3
  rm -f "$STUB_DIR/pr-101.rc" "$STUB_DIR/pr-101.err"
  printf '3\n' >"$STUB_DIR/sleep"
  START=$(hq_t_now)
  RC=0
  env HUMAN_QUEUE_GH="$STUB" HQ_GH_STUB_DIR="$STUB_DIR" HUMAN_QUEUE_GH_TIMEOUT=1 "$SH" "$MATERIAL" \
    acme/widgets 101 --level 1 >"$TMP/out" 2>"$TMP/err" </dev/null || RC=$?
  END=$(hq_t_now)
  rm -f "$STUB_DIR/sleep"
  check "[$SH] material: a deadline exits 1" "$RC" "1"
  check "[$SH] material: a deadline is one stderr line" "$(hq_t_lines "$(cat "$TMP/err")")" "1"
  check_contains "[$SH] material: a deadline names it" "$(cat "$TMP/err")" "did not answer within 1s"
  if hq_t_elapsed_under "$START" "$END" 2.9; then
    ok "[$SH] material: the deadline stops the call"
  else
    bad "[$SH] material: the deadline took $(hq_t_elapsed "$START" "$END")s"
  fi
  RC=0
  env HUMAN_QUEUE_GH="$TMP/no-such-gh" "$SH" "$MATERIAL" acme/widgets 101 --level 1 \
    >/dev/null 2>"$TMP/err" </dev/null || RC=$?
  check "[$SH] material: a missing gh exits 1" "$RC" "1"
  check_contains "[$SH] material: a missing gh is named" "$(cat "$TMP/err")" "gh not found"
done

hq_t_finish "reviews-cli.test.sh"
