#!/usr/bin/env bash
# desk/tests/drilldown-offline.test.sh — offline tests for the desk's PR
# drill-down (issue #1768): desk/bin/pr-outline.sh and skill/drilldown.md.
# Needs no database and no network: GitHub is tests/lib/gh-stub.sh serving
# tests/fixtures/drilldown/, and the skill's blocks run against a stub CLI.
#
# Asserts:
#   helper   --help documents usage and exit codes (no catalog line); usage
#            errors (arguments, a malformed node, the context cap) exit 4
#            and an issue-N key exits 3, all without calling GitHub.
#            Test 5.1: the outline of a known PR with three source files and
#            two test files lists the three files, their hunks with line
#            ranges and counts, and the two tests as leaves under the files
#            they touch (by stem and by a name in the diff), then a Tests
#            section; it fetches the PR and its file list and nothing else.
#            Test 5.2: `2.3` is the hunk widened to twenty lines below and,
#            above, only up to hunk 2.2 (marked); `2.1` starts at the top of
#            the file, `2.4` stops at its end; `2` is the whole file's patch
#            with [2.k] markers; every node header names its id and the head
#            SHA; several hunks of one file fetch it once; a duplicate node
#            prints once; an added file's hunk needs no fetch; the context
#            cap narrows the window. Edge cases: no patch, a removed file, a
#            patch that does not add up, a rename with no change, a file at
#            head that does not match the patch, a fetch that fails, an
#            unattached test, a partial file list, pages printed one after
#            another, control characters printed as "?". Not found (exit 3),
#            an unknown node (exit 3, naming the ids there are, nothing on
#            stdout), GitHub failing and a deadline (exit 1). No temp file
#            outlives a run, and the helper never touches the store.
#   skill    SKILL.md routes the drill-down verbs to drilldown.md, keeping
#            `open R-<n>` alone for reviews.md; drilldown.md's anchored
#            blocks extract, parse, write nothing, and, run against a stub
#            CLI under bash and zsh, print the header and the outline or
#            the node, `kind=issue` for an issue, and the store's exit;
#            `ask` requires the Read: line naming the nodes and the head.
#   The answer `ask` writes is model behaviour: the PR records a live run.
#
# Every helper case runs under `bash` and, when /bin/bash is 3.x (macOS),
# under /bin/bash too.
set -uo pipefail

TESTS_DIR=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/testlib.sh
. "$TESTS_DIR/lib/testlib.sh"
# shellcheck source=lib/skill-block.sh
. "$TESTS_DIR/lib/skill-block.sh"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/hq-drilldown-offline.XXXXXX")
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

OUTLINE="$HQ_T_DESK_DIR/bin/pr-outline.sh"
STUB="$HQ_T_TESTS_DIR/lib/gh-stub.sh"
SKILL_DIR="$HQ_T_DESK_DIR/skill"
STUB_DIR="$TMP/stub"
RUN_TMP="$TMP/runtmp"
mkdir -p "$STUB_DIR" "$RUN_TMP"
cp "$HQ_T_TESTS_DIR"/fixtures/drilldown/* "$STUB_DIR/"

SHELLS="bash"
if [ -x /bin/bash ] && [ "$(/bin/bash -c 'echo "${BASH_VERSINFO[0]}"')" = "3" ]; then
  SHELLS="bash /bin/bash"
fi

# po SHELL ARGS... — runs pr-outline.sh against the stub, with its own TMPDIR
# (so a leftover temp file shows); sets OUT, ERR, RC.
po() {
  local sh="$1"
  shift
  RC=0
  env HUMAN_QUEUE_GH="$STUB" HQ_GH_STUB_DIR="$STUB_DIR" TMPDIR="$RUN_TMP" "$sh" "$OUTLINE" "$@" \
    >"$TMP/out" 2>"$TMP/err" </dev/null || RC=$?
  OUT=$(cat "$TMP/out")
  ERR=$(cat "$TMP/err")
}

# po_rc SHELL CODE LABEL NEEDLE ARGS... — exit CODE, one stderr line naming
# NEEDLE, nothing on stdout.
po_rc() {
  local sh="$1" code="$2" label="$3" needle="$4"
  shift 4
  po "$sh" "$@"
  check "[$sh] $label: exit $code" "$RC" "$code"
  check "[$sh] $label: one stderr line" "$(hq_t_lines "$ERR")" "1"
  check "[$sh] $label: nothing on stdout" "$OUT" ""
  check_contains "[$sh] $label: names it" "$ERR" "$needle"
}

# calls PATTERN — how many stub calls since the last reset match PATTERN.
calls() { grep -c -- "$1" "$STUB_DIR/calls.log" 2>/dev/null || true; }
reset_calls() { : >"$STUB_DIR/calls.log"; }

# node_section TEXT ID — the lines of node ID's section, its === line first.
node_section() {
  printf '%s\n' "$1" | awk -v id="$2" '
    /^=== / { on = (index($0, "=== " id " ") == 1) }
    on && $0 == "" { on = 0 }
    on { print }'
}

EXPECTED_505='PR acme/widgets#505 · head 5a5e505 · 5 files · +16 -5
1 docs/guide.md · modified · +1 -1
  1.1 lines 3-9 · +1 -1
  test T2 tests/gizmo_test.sh · +2 -0
2 src/widget.sh · modified · +6 -3
  2.1 lines 1-5 · +1 -1
  2.2 lines 28-35 · +2 -0
  2.3 lines 44-51 · +2 -1 · widget_count()
  2.4 lines 110-116 · +1 -1
  test T1 tests/widget.test.sh · +6 -0
3 src/gadget.sh → src/gizmo.sh · renamed · +1 -1
  3.1 lines 2-8 · +1 -1
  test T2 tests/gizmo_test.sh · +2 -0

Tests
T1 tests/widget.test.sh · added · +6 -0 · touches 2
  T1.1 lines 1-6 · +6 -0
T2 tests/gizmo_test.sh · modified · +2 -0 · touches 1, 3
  T2.1 lines 4-10 · +2 -0'

# The widget lines numbered A..B, each as a context line.
widget_ctx() {
  local i="$1"
  while [ "$i" -le "$2" ]; do
    printf ' # widget line %d\n' "$i"
    i=$((i + 1))
  done
}

for SH in $SHELLS; do
  echo "=== shell: $SH — $("$SH" --version 2>&1 | sed -n 1p) ==="

  # --- help and usage ----------------------------------------------------------
  RC=0
  OUT=$("$SH" "$OUTLINE" --help 2>"$TMP/err") || RC=$?
  check "[$SH] --help exits 0" "$RC" "0"
  check_contains "[$SH] --help documents the nodes" "$OUT" "F.H    a hunk (2.3)"
  check_contains "[$SH] --help documents exit codes" "$OUT" "EXIT CODES"
  check_contains "[$SH] --help says nothing is stored" "$OUT" "no store, no cache"
  check_absent "[$SH] --help leaves out the catalog line" "$OUT" "catalog:"
  check "[$SH] --help is silent on stderr" "$(cat "$TMP/err")" ""

  reset_calls
  po_rc "$SH" 4 "no arguments" "missing OWNER/REPO"
  po_rc "$SH" 4 "no number" "missing OWNER/REPO or number" acme/widgets
  po_rc "$SH" 4 "a bad repository" "OWNER/REPO" acme 505
  po_rc "$SH" 4 "a bad number" "positive whole number" acme/widgets 5a5
  po_rc "$SH" 4 "an empty key" "positive whole number" acme/widgets pr-
  po_rc "$SH" 4 "an unknown option" "unknown option" acme/widgets 505 --json
  po_rc "$SH" 4 "a malformed node" "not '2.x'" acme/widgets 505 2.x
  po_rc "$SH" 4 "a node with a shell character" "a node is F, F.H, Tn, or Tn.H" acme/widgets 505 '2;id'
  po_rc "$SH" 4 "node zero" "a node is" acme/widgets 505 0
  po_rc "$SH" 4 "a lowercase test node" "a node is" acme/widgets 505 t1
  RC=0
  env HUMAN_QUEUE_GH="$STUB" HQ_GH_STUB_DIR="$STUB_DIR" HQ_OUTLINE_CONTEXT=0 "$SH" "$OUTLINE" \
    acme/widgets 505 >/dev/null 2>"$TMP/err" </dev/null || RC=$?
  check "[$SH] a zero context cap exits 4" "$RC" "4"
  check_contains "[$SH] the cap is named" "$(cat "$TMP/err")" "HQ_OUTLINE_CONTEXT"
  RC=0
  env HUMAN_QUEUE_GH="$STUB" HQ_GH_STUB_DIR="$STUB_DIR" HQ_OUTLINE_CONTEXT=501 "$SH" "$OUTLINE" \
    acme/widgets 505 >/dev/null 2>"$TMP/err" </dev/null || RC=$?
  check "[$SH] a context cap over 500 exits 4" "$RC" "4"
  po_rc "$SH" 3 "an issue key" "is an issue: it has no diff" acme/widgets issue-7
  check "[$SH] usage errors and an issue key never call GitHub" "$(cat "$STUB_DIR/calls.log")" ""

  # --- 5.1: the outline ----------------------------------------------------------
  reset_calls
  po "$SH" acme/widgets pr-505
  check "[$SH] 5.1 outline: exit 0" "$RC" "0"
  check "[$SH] 5.1 outline: silent on stderr" "$ERR" ""
  check "[$SH] 5.1 outline: the whole tree" "$OUT" "$EXPECTED_505"
  check "[$SH] 5.1 three numbered files" "$(printf '%s\n' "$OUT" | grep -cE '^[0-9]+ ')" "3"
  check "[$SH] 5.1 file 2's hunks" "$(printf '%s\n' "$OUT" | grep -oE '^  2\.[0-9]+' | tr -d ' ' | paste -sd, -)" \
    "2.1,2.2,2.3,2.4"
  check "[$SH] 5.1 the two test files" "$(printf '%s\n' "$OUT" | grep -oE '^T[0-9]+ [^ ]+' | paste -sd, -)" \
    "T1 tests/widget.test.sh,T2 tests/gizmo_test.sh"
  check "[$SH] 5.1 test leaves: T1 under 2 (stem), T2 under 1 (named in its diff) and 3 (stem)" \
    "$(printf '%s\n' "$OUT" | awk '/^[0-9]+ /{f=$1} /^  test /{print f ":" $2}' | paste -sd, -)" "1:T2,2:T1,3:T2"
  check "[$SH] 5.1 fetches the PR and its file list only" \
    "$(calls 'repos/acme/widgets/pulls/505'),$(calls 'git/blobs')" "2,0"
  check_contains "[$SH] 5.1 the file list is paginated" "$(cat "$STUB_DIR/calls.log")" \
    "api --paginate repos/acme/widgets/pulls/505/files?per_page=100"

  # --- 5.2: opening nodes --------------------------------------------------------
  reset_calls
  po "$SH" acme/widgets 505 2.3
  check "[$SH] 5.2 open 2.3: exit 0" "$RC" "0"
  check "[$SH] 5.2 open 2.3: silent on stderr" "$ERR" ""
  EXPECTED_23="=== 2.3 src/widget.sh · lines 44-51 · +2 -1 · widget_count() · head 5a5e505
(context above stops at hunk 2.2)
@@ -34,35 +36,36 @@
$(widget_ctx 34 44)
-# widget line 45
+# widget line 45, counted
+# widget line 45, extra
$(widget_ctx 46 68)"
  check "[$SH] 5.2 open 2.3: eight lines above (to hunk 2.2), the hunk, twenty below" "$OUT" "$EXPECTED_23"
  check_absent "[$SH] 5.2 open 2.3: no line of hunk 2.2 as context" "$OUT" "inserted after 30"
  check "[$SH] 5.2 open 2.3 fetches the file once, by its blob" \
    "$(calls 'api -H Accept: application/vnd.github.raw repos/acme/widgets/git/blobs/2222222222222222222222222222222222222222')" "1"

  po "$SH" acme/widgets 505 2.1
  check "[$SH] open 2.1: the top of the file, twenty below" "$OUT" "=== 2.1 src/widget.sh · lines 1-5 · +1 -1 · head 5a5e505
(start of file)
@@ -1,25 +1,25 @@
$(widget_ctx 1 1)
-# widget line 2
+# widget line 2, renamed
$(widget_ctx 3 25)"
  po "$SH" acme/widgets 505 2.4
  check "[$SH] open 2.4: twenty above, then the end of the file" "$OUT" "=== 2.4 src/widget.sh · lines 110-116 · +1 -1 · head 5a5e505
@@ -87,34 +90,34 @@
$(widget_ctx 87 109)
-# widget line 110
+# widget line 110, near the end
$(widget_ctx 111 120)
(end of file)"

  reset_calls
  po "$SH" acme/widgets 505 2
  check "[$SH] 5.2 open 2: exit 0" "$RC" "0"
  check "[$SH] 5.2 open 2: the header" "$(printf '%s\n' "$OUT" | sed -n 1p)" \
    "=== 2 src/widget.sh · modified · +6 -3 · head 5a5e505"
  check "[$SH] 5.2 open 2: a marker before each of its four hunks" \
    "$(printf '%s\n' "$OUT" | grep -E '^\[2\.[0-9]+\]$' | paste -sd, -)" "[2.1],[2.2],[2.3],[2.4]"
  check "[$SH] 5.2 open 2: the patch's own hunk headers" "$(printf '%s\n' "$OUT" | grep -c '^@@ ')" "4"
  check_contains "[$SH] 5.2 open 2: the hunk heading kept" "$OUT" "@@ -42,7 +44,8 @@ widget_count()"
  # The header, four markers, four @@ lines, and the hunks' 6 + 8 + 9 + 8 lines.
  check "[$SH] 5.2 open 2: every line of the patch" "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" "40"
  check "[$SH] open 2 needs no fetch" "$(calls 'git/blobs')" "0"

  reset_calls
  po "$SH" acme/widgets 505 2.1 2.3 2.4 2.3 T1.1 T2.1
  check "[$SH] several nodes: exit 0" "$RC" "0"
  check "[$SH] several nodes: in order, a duplicate once" \
    "$(printf '%s\n' "$OUT" | grep -oE '^=== [^ ]+' | paste -sd, -)" "=== 2.1,=== 2.3,=== 2.4,=== T1.1,=== T2.1"
  check "[$SH] several nodes: every header names the head" "$(printf '%s\n' "$OUT" | grep '^=== ' | grep -vc ' · head 5a5e505$')" "0"
  check "[$SH] several hunks of one file fetch it once" \
    "$(calls 'git/blobs/2222222222222222222222222222222222222222'),$(calls 'git/blobs/5555555555555555555555555555555555555555'),$(calls 'git/blobs')" "1,1,2"
  check "[$SH] an added file's hunk is the whole file" "$(node_section "$OUT" T1.1 | sed -n 2p)" \
    "(new file: the hunk is the whole file)"
  check "[$SH] a test hunk widens like any other" "$(node_section "$OUT" T2.1 | sed -n '2p;3p' | paste -sd'|' -)" \
    "(start of file)|@@ -1,8 +1,10 @@"
  check "[$SH] a test hunk ends at the end of its file" "$(node_section "$OUT" T2.1 | tail -n 1)" "(end of file)"

  RC=0
  env HUMAN_QUEUE_GH="$STUB" HQ_GH_STUB_DIR="$STUB_DIR" HQ_OUTLINE_CONTEXT=5 "$SH" "$OUTLINE" \
    acme/widgets 505 2.3 >"$TMP/out" 2>/dev/null </dev/null || RC=$?
  OUT=$(cat "$TMP/out")
  check "[$SH] HQ_OUTLINE_CONTEXT=5: five lines each side, no stop marker" \
    "$(printf '%s\n' "$OUT" | sed -n '2p')|$(printf '%s\n' "$OUT" | sed -n '3p')|$(printf '%s\n' "$OUT" | tail -n 1)" \
    "@@ -37,17 +39,18 @@| # widget line 37| # widget line 53"

  # --- edge cases (PR 506) -------------------------------------------------------
  po "$SH" acme/widgets 506
  check "[$SH] edge outline: exit 0" "$RC" "0"
  check "[$SH] edge outline: two pages read as one list" "$(printf '%s\n' "$OUT" | grep -cE '^([0-9]+|T[0-9]+) ')" "7"
  check_contains "[$SH] a file with no patch says so" "$OUT" \
    "1 assets/logo.png · added · +0 -0 · no patch (binary, or too large for GitHub to show)"
  check_contains "[$SH] a removed file's hunk is old lines" "$OUT" "  2.1 old lines 1-3 · +0 -3"
  check_contains "[$SH] a patch that does not add up is incomplete" "$OUT" \
    "3 src/big.sh · modified · +50 -1 · patch incomplete (GitHub returned +1 -1)"
  check_contains "[$SH] a rename with no change" "$OUT" \
    "4 src/was.sh → src/moved.sh · renamed · +0 -0 · renamed only: no content change"
  check_contains "[$SH] a test that touches nothing" "$OUT" \
    "T1 tests/helpers/fixture.json · added · +1 -0 · touches no file above"
  check_contains "[$SH] a single-line hunk" "$OUT" "  T1.1 line 1 · +1 -0"
  check "[$SH] a partial file list says so" "$(printf '%s\n' "$OUT" | tail -n 1)" \
    "GitHub listed 7 of 9 changed files; the rest are not in this outline."

  po "$SH" acme/widgets 506 2.1 5.1 6.1 1 4
  check "[$SH] edge nodes: exit 0" "$RC" "0"
  check "[$SH] a removed file's hunk is the whole file" "$(node_section "$OUT" 2.1 | sed -n 2p)" \
    "(removed file: the hunk is the whole file)"
  check "[$SH] a file at head that does not match the patch" "$(node_section "$OUT" 5.1 | sed -n '2p;3p' | paste -sd'|' -)" \
    "(more context unavailable: the file at head does not match the patch)|@@ -2,7 +2,7 @@"
  check_contains "[$SH] control characters print as ?" "$(node_section "$OUT" 5.1)" "+mis 5, ?[31mred?[0m"
  check_absent "[$SH] no escape reaches the output" "$OUT" "$(printf '\033')"
  check_contains "[$SH] a fetch that fails" "$(node_section "$OUT" 6.1 | sed -n 2p)" \
    "(more context unavailable: GitHub did not return the file: gh-stub: no fixture blob-6000000000000000000000000000000000000006)"
  check "[$SH] a file with no patch opens to its header" "$(node_section "$OUT" 1)" \
    "=== 1 assets/logo.png · added · +0 -0 · no patch (binary, or too large for GitHub to show) · head 5a5e506"
  check "[$SH] a rename with no change opens to its header" "$(node_section "$OUT" 4)" \
    "=== 4 src/was.sh → src/moved.sh · renamed · +0 -0 · renamed only: no content change · head 5a5e506"

  # --- not found, unknown nodes, failures -----------------------------------------
  po_rc "$SH" 3 "a PR that does not exist" "no PR acme/widgets#404" acme/widgets 404
  po_rc "$SH" 3 "an unknown hunk" "no hunk 2.9: 2 has 2.1-2.4" acme/widgets 505 2.9
  po_rc "$SH" 3 "an unknown file" "no node 9 in acme/widgets#505 (it has files 1-3 and tests T1-T2)" acme/widgets 505 9
  po_rc "$SH" 3 "an unknown node after a good one prints nothing" "no node T3" acme/widgets 505 2.3 T3
  po_rc "$SH" 3 "a hunk of a file with none" "no hunk 1.1: 1 has no hunks" acme/widgets 506 1.1
  po_rc "$SH" 1 "GitHub failing on the file list" "GitHub did not list the files: gh: Server Error (HTTP 502)" \
    acme/widgets 507
  printf '3\n' >"$STUB_DIR/sleep"
  RC=0
  env HUMAN_QUEUE_GH="$STUB" HQ_GH_STUB_DIR="$STUB_DIR" HUMAN_QUEUE_GH_TIMEOUT=1 TMPDIR="$RUN_TMP" "$SH" "$OUTLINE" \
    acme/widgets 505 >"$TMP/out" 2>"$TMP/err" </dev/null || RC=$?
  rm -f "$STUB_DIR/sleep"
  check "[$SH] a deadline exits 1" "$RC" "1"
  check_contains "[$SH] a deadline says so" "$(cat "$TMP/err")" "GitHub did not answer within 1s"

  # The same runs left nothing behind in their TMPDIR, success or failure.
  check "[$SH] no temp file outlives a run" "$(find "$RUN_TMP" -type f | wc -l | tr -d ' ')" "0"
done

# The helper reads GitHub and nothing else: no store, no psql, no state.
HELPER_SRC=$(cat "$OUTLINE")
for needle in human-queue.sh desk-cli.sh hq_db psql HUMAN_QUEUE_DATABASE_URL session-state; do
  check_absent "pr-outline.sh never touches the store ($needle)" "$HELPER_SRC" "$needle"
done

# ------------------------------------------------------------------- skill
printf '== skill\n'
SKILL=$(cat "$SKILL_DIR/SKILL.md")
DRILL=$(cat "$SKILL_DIR/drilldown.md")
REVIEWS=$(cat "$SKILL_DIR/reviews.md")
contract() {
  local label="$1" text="$2" needle
  while IFS= read -r needle; do
    [ -n "$needle" ] || continue
    check_contains "$label: $needle" "$text" "$needle"
  done
}
contract SKILL.md "$SKILL" <<'NEEDLES'
| `drilldown.md` |
**A drill-down verb** as the whole message — `outline R-<n>`, `open R-<n>` followed by one or more node ids
`open R-<n>` alone stays the Reviews view's level 2
`ask R-<n>: <question>` → load `drilldown.md`
NEEDLES
contract drilldown.md "$DRILL" <<'NEEDLES'
**Nothing is stored.**
no `summary set`, no `comment`, no `flag`, no `review`, no `state set`, and no file that outlives the block
`T?[0-9]+(\.[0-9]+)?`
The question in `ask` never goes into a command
`kind=issue` → `R-2 is an issue: it has no diff.
**End with the `Read:` line**
Read: 2.3, 2.4, T1.1 · head 5a5e505
An answer without this line is incomplete.
never fill a gap from memory of the codebase or a guess
Open them in one call
Plain text only, never AskUserQuestion.
NEEDLES
contract reviews.md "$REVIEWS" <<'NEEDLES'
`drilldown.md` (#1768)
`outline R-2 or diff R-2 [path] for the code
NEEDLES

for a in desk-outline desk-open-node; do
  rc=0
  BODY=$(hq_t_skill_block "$SKILL_DIR/drilldown.md" "$a" 2>&1) || rc=$?
  check "anchor $a extracts" "$rc" "0"
  if [ "$rc" -eq 0 ] && bash -n <(printf '%s\n' "$BODY") 2>"$TMP/syntax"; then
    ok "anchor $a is valid bash"
  else
    bad "anchor $a is valid bash ($(cat "$TMP/syntax" 2>/dev/null))"
  fi
  for verb in 'summary set' ' comment ' ' flag ' ' review ' ' state set' 'sync-reviews'; do
    check_absent "the $a block never runs$verb" "$BODY" "$verb"
  done
  check "the $a block writes no file" "$(printf '%s\n' "$BODY" | grep -cE '>[[:space:]]*"?[^&|[:space:]]')" "0"
  check_contains "the $a block reads the item only through get" "$BODY" "\"\$HQ\" get R-2 --json"
done

# The blocks, run as the desk runs them: against a stub CLI that serves the
# item (or fails like an unreachable store) and the gh stub, under bash and,
# when it is installed, zsh (the desk's own shell on macOS).
JQ=$(command -v jq 2>/dev/null || true)
if [ -z "$JQ" ]; then
  echo "SKIP: skill blocks — jq is not installed"
else
  mkdir -p "$TMP/bin"
  printf '%s\n' '#!/usr/bin/env bash' 'if [ -n "${STUB_RC:-}" ]; then echo "human-queue: unreachable" >&2; exit "$STUB_RC"; fi' \
    'cat "$STUB_ITEM"' >"$TMP/bin/hq-stub"
  chmod +x "$TMP/bin/hq-stub"
  printf '%s' '{"id":"R-2","kind":"review","status":"open","repo":"acme/widgets","key":"pr-505","question":"feat: widgets","context":["https://github.com/acme/widgets/pull/505","Merged 2026-10-07 14:00 UTC"]}' >"$TMP/pr.json"
  printf '%s' '{"id":"R-3","kind":"review","status":"open","repo":"acme/widgets","key":"issue-7","question":"Export widgets","context":["https://github.com/acme/widgets/issues/7","Filed 2026-10-07 13:00 UTC"]}' >"$TMP/issue.json"
  hq_t_skill_block "$SKILL_DIR/drilldown.md" desk-outline >"$TMP/outline.sh"
  hq_t_skill_block "$SKILL_DIR/drilldown.md" desk-open-node >"$TMP/open.sh"
  HEADER='R-2 · PR #505 · acme/widgets · Merged 2026-10-07 14:00 UTC
https://github.com/acme/widgets/pull/505'
  BLOCK_SHELLS="bash"
  if command -v zsh >/dev/null 2>&1; then BLOCK_SHELLS="$BLOCK_SHELLS zsh"; fi
  for BSH in $BLOCK_SHELLS; do
    blk() {
      env DESK="$HQ_T_DESK_DIR" HQ="$TMP/bin/hq-stub" STUB_ITEM="$2" ${3:+STUB_RC="$3"} \
        HUMAN_QUEUE_GH="$STUB" HQ_GH_STUB_DIR="$STUB_DIR" "$BSH" "$1" 2>&1
    }
    check "[$BSH] outline block: the header, the outline, exit=0" "$(blk "$TMP/outline.sh" "$TMP/pr.json")" \
      "$HEADER
$EXPECTED_505
exit=0"
    OUT=$(blk "$TMP/open.sh" "$TMP/pr.json")
    check "[$BSH] open block: the header, then node 2.3" "$(printf '%s\n' "$OUT" | sed -n '1,3p')" \
      "$HEADER
=== 2.3 src/widget.sh · lines 44-51 · +2 -1 · widget_count() · head 5a5e505"
    check "[$BSH] open block: ends exit=0" "$(printf '%s\n' "$OUT" | tail -n 1)" "exit=0"
    check "[$BSH] outline block of an issue" "$(blk "$TMP/outline.sh" "$TMP/issue.json")" "kind=issue"
    check "[$BSH] open block of an issue" "$(blk "$TMP/open.sh" "$TMP/issue.json")" "kind=issue"
    check "[$BSH] outline block, store unreachable" "$(blk "$TMP/outline.sh" "$TMP/pr.json" 7 | tail -n 1)" "exit=7"
  done
fi

hq_t_finish "drilldown-offline.test.sh"
