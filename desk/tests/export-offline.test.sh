#!/usr/bin/env bash
# desk/tests/export-offline.test.sh — offline tests for the paper copy of a
# batch (issue #1759). Needs no database and never connects to one:
# validation comes before any connection attempt, which the black-hole URL
# proves (a connection attempt would take the full 1.5 s).
#
# Asserts:
#   CLI        every malformed `export` call exits 4 without a connection
#              attempt (one stderr line, nothing on stdout); valid calls reach
#              the database step; --help documents the contract
#   export.jq  the three renderings of tests/fixtures/export/batch.json: ISO
#              2145 numbering (`n  D-44 · …`, `n.1  A. Yes (Recommended)`),
#              the to-do line (#1769), context, the default, the link, a
#              blank answer line per open item and the answer of one answered
#              since, a Review at level 2 and 1 (each falling back, marked),
#              HTML escaping, the footer with the export time, the Reviews
#              missing a summary
#   renderers  lib/export.sh against stub binaries: the order (pandoc,
#              Chrome, cupsfilter) and fall-through on a failure, a deadline,
#              or a file that is not a PDF; a forced renderer; none at all
#              (test 5.2's Markdown fallback: every renderer named);
#              HUMAN_QUEUE_DATABASE_URL kept out of their environment, their
#              TMPDIR in the scratch directory; Chrome offline, and stopped
#              once it reports the file written; a renderer stopped when the
#              export is interrupted; on macOS, a real cupsfilter (and
#              Chrome, when installed) PDF whose ids `pdftotext` finds, with
#              Chrome's own temp directories in the scratch directory
#   skill      export.md's anchored blocks, run as written against a stub CLI
#              (bash, /bin/bash 3.2, zsh): the default file in a private
#              directory, the operator's path passed through untouched, `~/`
#              expanded; the router and the sweep's hand-off
set -uo pipefail

TESTS_DIR=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/testlib.sh
. "$TESTS_DIR/lib/testlib.sh"
# shellcheck source=lib/skill-block.sh
. "$TESTS_DIR/lib/skill-block.sh"

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: export-offline.test.sh — jq is not installed (export needs it)"
  exit 0
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/hq-export-offline.XXXXXX")
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

BLACKHOLE_URL="postgresql://u:pw@192.0.2.1:5432/db?sslmode=require"
SKILL_DIR="$HQ_T_DESK_DIR/skill"
BIN="$HQ_T_DESK_DIR/bin"
FIX="$TESTS_DIR/fixtures/export"

SHELLS="bash"
if [ -x /bin/bash ] && [ "$(/bin/bash -c 'echo "${BASH_VERSINFO[0]}"')" = "3" ]; then
  SHELLS="bash /bin/bash"
fi
BLOCK_SHELLS="$SHELLS"
if command -v zsh >/dev/null 2>&1; then BLOCK_SHELLS="$BLOCK_SHELLS zsh"; fi

PDFTOTEXT=""
for c in /opt/homebrew/bin/pdftotext /usr/local/bin/pdftotext /usr/bin/pdftotext; do
  if [ -x "$c" ]; then PDFTOTEXT="$c"; break; fi
done

# ----------------------------------------------------------------------- CLI
printf '== CLI\n'

run_cli() {
  local sh="$1"
  shift
  ELAPSED_START=$(hq_t_now)
  RC=0
  env HUMAN_QUEUE_DATABASE_URL="$BLACKHOLE_URL" "$sh" "$HQ_T_CLI" "$@" \
    >"$TMP/out" 2>"$TMP/err" </dev/null || RC=$?
  ELAPSED_END=$(hq_t_now)
  OUT=$(cat "$TMP/out")
  ERR=$(cat "$TMP/err")
}

# expect_rc SHELL LABEL NEEDLE ARGS... — exit 4, one stderr line naming
# NEEDLE, nothing on stdout, no connection attempt.
expect_rc() {
  local sh="$1" label="$2" needle="$3"
  shift 3
  run_cli "$sh" "$@"
  check "[$sh] $label: exit 4" "$RC" "4"
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
  env -u HUMAN_QUEUE_DATABASE_URL -u HUMAN_QUEUE_SCHEMA "$sh" "$HQ_T_CLI" "$@" >/dev/null 2>"$TMP/err" \
    </dev/null || rc=$?
  check "[$sh] $label passes validation (exit 7, URL unset)" "$rc" "7"
}

mkdir -p "$TMP/out-dir" "$TMP/ro-dir" "$TMP/out-dir/dir.pdf"
chmod 555 "$TMP/ro-dir"
OK_OUT="$TMP/out-dir/batch.pdf"

for SH in $SHELLS; do
  echo "=== shell: $SH — $("$SH" --version 2>&1 | sed -n 1p) ==="
  HELP=$(env -u HUMAN_QUEUE_DATABASE_URL "$SH" "$HQ_T_CLI" --help 2>&1)
  check_contains "[$SH] --help lists export" "$HELP" "export       write a numbered PDF of a batch"
  HELP=$(env -u HUMAN_QUEUE_DATABASE_URL "$SH" "$HQ_T_CLI" export --help 2>&1)
  for needle in "--kind decisions|reviews" "--ids ID" "--set N" "--level 1|2" "--dry-run" \
                "LAYOUT (ISO 2145)" "\`n.1  A. Yes (Recommended)\`" "pandoc" "cupsfilter" \
                "the Markdown is written next to FILE" "migration 013" "exported"; do
    check_contains "[$SH] export --help: $needle" "$HELP" "$needle"
  done

  expect_rc "$SH" "nothing to export named" "say what to export" export --out "$OK_OUT"
  expect_rc "$SH" "an unknown kind" "--kind must be decisions or reviews" export --kind ideas --out "$OK_OUT"
  expect_rc "$SH" "--kind twice" "--kind given more than once" export --kind decisions --kind reviews --out "$OK_OUT"
  expect_rc "$SH" "a missing --out" "missing --out FILE.pdf" export --kind decisions
  expect_rc "$SH" "--out not a .pdf" "--out must name a .pdf file" export --kind decisions --out "$TMP/out-dir/x.txt"
  expect_rc "$SH" "--out only the extension" "not just the extension" export --kind decisions --out "$TMP/out-dir/.pdf"
  expect_rc "$SH" "--out in a missing directory" "directory does not exist" export --kind decisions --out "$TMP/nope/x.pdf"
  expect_rc "$SH" "--out a directory" "names a directory" export --kind decisions --out "$TMP/out-dir/dir.pdf"
  if [ "$(id -u)" != 0 ]; then
    expect_rc "$SH" "--out in a read-only directory" "is not writable" export --kind decisions --out "$TMP/ro-dir/x.pdf"
  fi
  expect_rc "$SH" "--out with a control character" "control character" export --kind decisions --out "$TMP/out-dir/a$(printf '\033')b.pdf"
  expect_rc "$SH" "--level 3" "--level must be 1 or 2" export --kind reviews --level 3 --out "$OK_OUT"
  expect_rc "$SH" "--set 0" "--set must be a set id" export --set 0 --out "$OK_OUT"
  expect_rc "$SH" "--set abc" "--set must be a set id" export --set 1a --out "$OK_OUT"
  expect_rc "$SH" "--set past bigint" "--set is out of range" export --set 9223372036854775808 --out "$OK_OUT"
  expect_rc "$SH" "--set with --kind" "--set goes alone" export --set 3 --kind decisions --out "$OK_OUT"
  expect_rc "$SH" "--set with --ids" "--set goes alone" export --set 3 --ids D-1 --out "$OK_OUT"
  expect_rc "$SH" "--ids with none" "--ids needs at least one item id" export --ids --out "$OK_OUT"
  expect_rc "$SH" "a malformed id" "invalid item id" export --ids D-1 X-2 --out "$OK_OUT"
  expect_rc "$SH" "an id twice" "D-1 is given twice" export --ids D-1 d-1 --out "$OK_OUT"
  expect_rc "$SH" "an id of the other kind" "R-2 is not a decision" export --kind decisions --ids D-1 R-2 --out "$OK_OUT"
  expect_rc "$SH" "--today with decisions" "--today goes only with --kind reviews" export --kind decisions --today --out "$OK_OUT"
  expect_rc "$SH" "--today with --ids" "--today goes only with --kind reviews" export --ids R-1 --today --out "$OK_OUT"
  expect_rc "$SH" "a stray argument" "stray argument" export --kind decisions D-1 --out "$OK_OUT"
  expect_rc "$SH" "an unknown flag" "unknown option '--pages'" export --kind decisions --pages 2 --out "$OK_OUT"
  run_cli "$SH" export --kind decisions --out "$OK_OUT" --set
  check "[$SH] a flag with no value: exit 4" "$RC" "4"
  RC=0
  env HUMAN_QUEUE_DATABASE_URL="$BLACKHOLE_URL" HUMAN_QUEUE_EXPORT_RENDERER=word "$SH" "$HQ_T_CLI" \
    export --kind decisions --out "$OK_OUT" >/dev/null 2>"$TMP/err" </dev/null || RC=$?
  check "[$SH] HUMAN_QUEUE_EXPORT_RENDERER=word: exit 4" "$RC" "4"
  check_contains "[$SH] HUMAN_QUEUE_EXPORT_RENDERER=word: names the choices" "$(cat "$TMP/err")" "auto, pandoc, chrome, cupsfilter, or markdown"
  ids=()
  for i in $(seq 1 100); do ids[${#ids[@]}]="D-$i"; done
  expect_rc "$SH" "100 ids" "at most 99 items per export" export --ids "${ids[@]}" --out "$OK_OUT"

  expect_db "$SH" "--kind decisions" export --kind decisions --out "$OK_OUT"
  expect_db "$SH" "--kind reviews --today --level 1" export --kind reviews --today --level 1 --out "$OK_OUT"
  expect_db "$SH" "--ids, spaces and commas" export --ids d-1,R-2 D-3 --out "$OK_OUT" --json
  expect_db "$SH" "--set" export --set 31 --out "$OK_OUT"
  expect_db "$SH" "--dry-run without --out" export --kind decisions --dry-run
  check "[$SH] nothing was written" "$(find "$TMP/out-dir" -type f | wc -l | tr -d ' ')" "0"
done
chmod 755 "$TMP/ro-dir"

# ----------------------------------------------------------------- export.jq
printf '== export.jq\n'
# ejq FILTER [FILE] — FILTER after export.jq's own definitions, as the CLI runs
# them (lib/export.sh's hq_export_jq: never `include "export"`, which jq 1.8
# aborts on). EJQ_JQ picks the jq (default: the one on PATH).
EXPORT_JQ_TEXT=$(cat "$BIN/lib/export.jq")
ejq() { "${EJQ_JQ:-jq}" -r -L "$SKILL_DIR" "$EXPORT_JQ_TEXT
$1" "${2:-$FIX/batch.json}"; }
MD=$(ejq export_markdown)
TXT=$(ejq export_text)
HTML=$(ejq export_html)

check "md: the title" "$(printf '%s\n' "$MD" | sed -n 1p)" "# Desk export · Set 31"
check "md: the header line" "$(printf '%s\n' "$MD" | sed -n 3p)" \
  "set 31 · 5 items · Reviews at level 2 · exported Thu 2026-10-08 17:31 ET"
check_contains "md: how to reply" "$MD" "or by number (2: B) while set 31 is the desk's latest set."
check "md: one section per item, its number and id first (ISO 2145), the item's text escaped" "$(printf '%s\n' "$MD" | grep '^## ')" \
  '## 1  D-44 · Retry the flaky upload test once?
## 2  D-41 · Ship \<b\>the\</b\> migration \& the "backfill" first?
## 3  D-45 · How should the importer handle partial rows?
## 4  R-9 · PR \#283
## 5  R-10 · Issue \#202'
check "md: options as n.k with the letter, the default marked once" "$(printf '%s\n' "$MD" | grep -E '^[0-9]+\.[0-9]+  ' | sed 's/ *$//')" \
  "1.1  A. Yes (Recommended)
1.2  B. No
2.1  A. Yes
2.2  B. No
2.3  C. Split it"
check_contains "md: the triage line" "$MD" 'widgets · pr-12 · parked · Impact: high · Cost: \~2 min'
check_contains "md: the context" "$MD" "- The upload test failed twice on CI."
check_contains "md: the default and when" "$MD" "Default: A. Yes — the thread takes it at 2026-10-09 18:00 UTC if unanswered"
check_contains "md: the to-do line (#1769)" "$MD" "P2 · tags: prd, urgent · note: ask Sam first"
check "md: only D-44 carries a to-do line" "$(printf '%s\n' "$MD" | grep -cE '^P[1-5] · |tags: ')" "1"
check_contains "md: the link" "$MD" 'Link: PR \#12 — https://github.com/acme/widgets/pull/12'
check "md: a blank answer line per open Decision" "$(printf '%s\n' "$MD" | grep -c '^Answer: ____')" "2"
check "md: a Review's answer line" "$(printf '%s\n' "$MD" | grep -c '^Reviewed \[ \]   Flag, and why: ____')" "2"
check_contains "md: an answered item shows its answer" "$MD" "Answered: Skip them and log each one."
check_contains "md: a long-form Decision is marked" "$MD" "widgets · issue-13 · answered · long-form · Cost: 1h · Focus: deep focus"
check_contains "md: level 2: the twenty-line summary" "$MD" "1. What changed: a procedure has versions."
check "md: level 2: a Review with nothing cached shows its title, marked (lines kept apart)" \
  "$(printf '%s\n' "$MD" | grep -A1 '^Idea: export gadgets' | sed 's/ *$//')" "Idea: export gadgets
(title; not summarized yet)"
check "md: lines that must stay lines end in a Markdown line break" \
  "$(printf '%s\n' "$MD" | grep -c '^Idea: export gadgets  $')" "1"
check "md: the footer, last" "$(printf '%s\n' "$MD" | tail -1)" "Exported Thu 2026-10-08 17:31 ET · set 31 · 5 items"
check "md: the Reviews missing a summary at level 2" "$(ejq 'export_missing | tojson')" '["R-10"]'

jq '.level = 1 | .items[4].summary_l1 = null' "$FIX/batch.json" > "$TMP/l1.json"
MD1=$(ejq export_markdown "$TMP/l1.json")
check_contains "md: level 1: the cached line" "$MD1" "Procedures can be instantiated, checked, and moved to a new version."
check_absent "md: level 1: not the twenty lines" "$MD1" "1. What changed"
check "md: level 1: the header" "$(printf '%s\n' "$MD1" | sed -n 3p)" \
  "set 31 · 5 items · Reviews at level 1 · exported Thu 2026-10-08 17:31 ET"
jq '.items[3].summary_l2 = null' "$FIX/batch.json" > "$TMP/l2-missing.json"
check_contains "md: level 2 with only a line cached: the line, marked" "$(ejq export_markdown "$TMP/l2-missing.json")" \
  "(level-2 summary not written yet; its one-line summary is shown)"
check "missing at level 2 with only a line cached" "$(ejq 'export_missing | tojson' "$TMP/l2-missing.json")" '["R-9","R-10"]'

jq '.source = "decisions" | .set_id = null | .items |= map(select(.kind == "decision")) | .count = 3 | .more = 2' \
  "$FIX/batch.json" > "$TMP/no-set.json"
MDN=$(ejq export_markdown "$TMP/no-set.json")
check "md: a batch with no set" "$(printf '%s\n' "$MDN" | sed -n '1p;3p')" "# Desk export · Decisions
3 items · exported Thu 2026-10-08 17:31 ET"
check_contains "md: no set: reply by id only" "$MDN" "or flag R-9 \"why\")."
check_contains "md: more left out" "$MDN" "… and 2 more items left out (an export holds at most 99)."

# An item's text is Markdown pandoc reads literally: an image in it is never
# fetched, math never reaches the PDF engine as TeX, emphasis and links stay
# text, and a line break in it cannot start a block. A Review's summary keeps
# its **bold** runs.
jq '.items[0].question = "see ![x](https://example.invalid/p.png)\n# not a heading"
    | .items[0].context = ["![y][r] costs $\\input{/etc/hosts}$", "**loud** _x_ [l](u) 2^10^ H~2~O {.c} a|b `c`"]
    | .items[0].options = ["Yes *please*", "No"] | .items[0].default_option = "Yes *please*"
    | .items[0].my_note = "<i>ask</i> & see"
    | .items[3].summary_l2 = "**Bold kept.** *one* $x$\n1. A line"' \
  "$FIX/batch.json" > "$TMP/literal.json"
MDI=$(ejq export_markdown "$TMP/literal.json")
check_contains "md: an image in the text is escaped, on one line" "$MDI" \
  '## 1  D-44 · see \!\[x\](https://example.invalid/p.png) \# not a heading'
check_contains "md: a reference image and math in the text are escaped" "$MDI" '- \!\[y\]\[r\] costs \$\\input\{/etc/hosts\}\$'
check_contains "md: emphasis, links, sub/superscripts, attributes, tables, code stay text" "$MDI" \
  '- \*\*loud\*\* \_x\_ \[l\](u) 2\^10\^ H\~2\~O \{.c\} a\|b \`c\`'
check_contains "md: an option's text is escaped" "$MDI" '1.1  A. Yes \*please\* (Recommended)'
check_contains "md: the default's label is escaped" "$MDI" 'Default: A. Yes \*please\*'
check_contains "md: the operator's note is escaped" "$MDI" 'note: \<i\>ask\</i\> \& see'
check_contains "md: a summary keeps its bold, the rest escaped, its lines kept" "$MDI" \
  "$(printf '%s\n%s' '**Bold kept.** \*one\* \$x\$  ' '1. A line  ')"
check_absent "md: no image syntax survives" "$MDI" '!['
check_absent "md: no math survives" "$MDI" ' $\'

# Two repositories with the same name keep their owners; others drop them.
jq '.items[1].repo = "other/widgets"' "$FIX/batch.json" > "$TMP/same-name.json"
MDS=$(ejq export_markdown "$TMP/same-name.json")
check_contains "md: same-named repositories keep their owners" "$MDS" "acme/widgets · pr-12 · parked"
check_contains "md: ... both of them" "$MDS" "other/widgets · issue-11"
check_contains "md: a repository with a unique name drops its owner" "$MDS" "gadgets · Merged"

check "txt: the title, underlined" "$(printf '%s\n' "$TXT" | sed -n '1,2p')" "Desk export · Set 31
===================="
check_contains "txt: a heading" "$TXT" "1  D-44 · Retry the flaky upload test once?"
check_contains "txt: an option" "$TXT" "   2.3  C. Split it"
check_contains "txt: the to-do line" "$TXT" "   P2 · tags: prd, urgent · note: ask Sam first"
check_contains "txt: a summary line without Markdown bold" "$TXT" "   Procedures can be instantiated, checked, and moved to a new version."
check_absent "txt: no Markdown bold" "$TXT" "**"
check "txt: the footer, last" "$(printf '%s\n' "$TXT" | tail -1)" "Exported Thu 2026-10-08 17:31 ET · set 31 · 5 items"

check_contains "html: the question escaped" "$HTML" "D-41 · Ship &lt;b&gt;the&lt;/b&gt; migration &amp; the &quot;backfill&quot; first?"
check_absent "html: no raw markup from the store" "$HTML" "<b>the</b>"
check "html: five sections" "$(printf '%s\n' "$HTML" | grep -o '<section class="item">' | wc -l | tr -d ' ')" "5"
check_contains "html: an option" "$HTML" '<li><span class="num">1.1</span> <b>A.</b> Yes <em>(Recommended)</em></li>'
check_contains "html: a summary's bold run" "$HTML" "<p><strong>Procedures can be instantiated, checked, and moved to a new version.</strong></p>"
check_contains "html: the footer on every page" "$HTML" '@bottom-left { content: "Exported Thu 2026-10-08 17:31 ET · set 31 · 5 items";'
check_contains "html: page numbers" "$HTML" 'counter(page) " of " counter(pages)'
check "css strings escape quotes and backslashes" \
  "$(jq -n -r -L "$SKILL_DIR" "$EXPORT_JQ_TEXT"'
"a\"b\\c\nd" | ex_css_string')" '"a\"b\\c d"'
# The rename and the pending record's clear run with INT, TERM, and HUP
# ignored (a signal between them would undo a placed export), and nothing
# else does: a failed place restores them before hq__export_fail, whose undo
# needs the connect watchdog's TERM to reach psql.
SETTLE=$(sed -n '/^hq__export_settle() {/,/^}/p' "$BIN/cmd/export.sh")
check "export.sh: hq__export_settle ignores signals, places, clears, restores" \
  "$(printf '%s\n' "$SETTLE" | grep -oE "trap '' INT TERM HUP|hq__export_place|HQ_EXPORT_PENDING=\"\"|trap - INT TERM HUP" | tr '\n' ' ')" \
  "trap '' INT TERM HUP hq__export_place HQ_EXPORT_PENDING=\"\" trap - INT TERM HUP trap - INT TERM HUP "
check "export.sh: both placements go through hq__export_settle" \
  "$(grep -cE '^ +hq__export_settle "\$HQ_EXPORT_WORK/export\.(pdf|md)"' "$BIN/cmd/export.sh")" "2"
check "export.sh: no failure path runs with the signals ignored" \
  "$(awk "/trap '' INT TERM HUP/ { g = 1; next } /trap - INT TERM HUP/ { g = 0; next } g && /hq__export_fail|hq_die|hq__export_undo/ { print }" "$BIN/cmd/export.sh")" ""
check_absent "export.sh never includes export.jq as a module (jq 1.8 aborts on it)" \
  "$(grep -v '^ *#' "$BIN/cmd/export.sh" "$BIN/lib/export.sh")" 'include "export"'
# The renderings through hq_export_jq itself, and through every other jq this
# machine has (Homebrew's, the system's): the paper is the same on each.
HQX=$(printf '%s' "$(cat "$FIX/batch.json")" | bash -c 'HQ_BIN_DIR="$1"; HQ_DESK_DIR="$2"
  . "$HQ_BIN_DIR/lib/common.sh"; . "$HQ_BIN_DIR/lib/github.sh"; . "$HQ_BIN_DIR/lib/export.sh"
  hq_jq_find && hq_export_jq -r export_markdown' _ "$BIN" "$HQ_T_DESK_DIR" 2>&1)
check "hq_export_jq renders what ejq does" "$HQX" "$MD"
for other_jq in /opt/homebrew/bin/jq /usr/local/bin/jq /usr/bin/jq ${HQ_T_EXTRA_JQ:-}; do
  [ -x "$other_jq" ] || continue
  check "$("$other_jq" --version 2>/dev/null) renders the same Markdown and HTML" \
    "$(EJQ_JQ="$other_jq" ejq export_markdown 2>&1)$(EJQ_JQ="$other_jq" ejq export_html 2>&1)" "$MD$HTML"
done

# ----------------------------------------------------------------- renderers
printf '== renderers\n'
STUBS="$TMP/stubs"
mkdir -p "$STUBS"
# A stub writes a PDF where its renderer would and logs what it saw: its
# arguments, whether the store's URL reached its environment, its temp
# directories, and its pid.
cat > "$STUBS/pdf-writer" <<'EOF'
#!/usr/bin/env bash
name="${0##*/}"
printf '%s\n' "$*" > "$STUB_LOG/$name.args"
if [ -n "${HUMAN_QUEUE_DATABASE_URL+x}" ]; then echo leaked > "$STUB_LOG/$name.env"; else echo clean > "$STUB_LOG/$name.env"; fi
printf '%s %s\n' "${TMPDIR:-}" "${MAC_CHROMIUM_TMPDIR:-}" > "$STUB_LOG/$name.tmp"
echo "$$" > "$STUB_LOG/$name.pid"
out=""
prev=""
for a in "$@"; do
  case "$a" in --print-to-pdf=*) out="${a#--print-to-pdf=}" ;; esac
  if [ "$prev" = --output ]; then out="$a"; fi
  prev="$a"
done
case "${STUB_MODE:-ok}" in
  fail) exit 3 ;;
  hang) exec sleep 30 ;;
  slow) sleep 1 ;;
  notpdf) if [ -n "$out" ]; then echo "not a pdf" > "$out"; else echo "not a pdf"; fi; exit 0 ;;
  linger)
    printf '%%PDF-1.4 stub\n' > "$out"
    echo "123 bytes written to file $out" >&2
    sleep 30; exit 0 ;;
esac
if [ -n "$out" ]; then printf '%%PDF-1.4 stub\n' > "$out"; else printf '%%PDF-1.4 stub\n'; fi
EOF
chmod +x "$STUBS/pdf-writer"
for n in pandoc chrome cupsfilter; do cp "$STUBS/pdf-writer" "$STUBS/$n"; done
mkdir -p "$TMP/log"

# render ENV... — runs hq_export_pdf on the fixture's renderings in a fresh
# shell with ENV; prints `rc renderer | tried` and leaves the PDF in $TMP/w.
render() {
  rm -rf "$TMP/w"
  mkdir -p "$TMP/w"
  rm -f "$TMP/log"/*
  env HUMAN_QUEUE_DATABASE_URL="$BLACKHOLE_URL" STUB_LOG="$TMP/log" "$@" bash -c '
    HQ_BIN_DIR="$1"; . "$HQ_BIN_DIR/lib/common.sh"; . "$HQ_BIN_DIR/lib/export.sh"
    rc=0; hq_export_pdf used "$2/r.md" "$2/r.txt" "$2/r.html" "$2/w/out.pdf" "$2/w" || rc=$?
    printf "%s %s | %s\n" "$rc" "${used:--}" "$HQ_EXPORT_TRIED"' _ "$BIN" "$TMP"
}
printf '%s' "$MD" > "$TMP/r.md"
printf '%s' "$TXT" > "$TMP/r.txt"
printf '%s' "$HTML" > "$TMP/r.html"
P="$STUBS/pandoc" C="$STUBS/chrome" U="$STUBS/cupsfilter"

check "pandoc first" "$(render HUMAN_QUEUE_PANDOC="$P" HUMAN_QUEUE_CHROME="$C" HUMAN_QUEUE_CUPSFILTER="$U")" "0 pandoc | "
check "pandoc gets the Markdown" "$(sed 's/.*--output [^ ]* //' "$TMP/log/pandoc.args")" "$TMP/r.md"
check_contains "pandoc reads raw TeX, HTML, attributes, YAML blocks, and math as text, without smart punctuation" "$(cat "$TMP/log/pandoc.args")" \
  "--from markdown-raw_tex-raw_html-raw_attribute-yaml_metadata_block-tex_math_dollars-smart "
check "pandoc: its temp files in the scratch directory" "$(cat "$TMP/log/pandoc.tmp")" "$TMP/w/tmp $TMP/w/tmp"
check "the PDF is where it was asked for" "$(head -c 5 "$TMP/w/out.pdf")" "%PDF-"
check "the store's URL never reaches a renderer" "$(cat "$TMP/log/pandoc.env")" "clean"
check "a failing renderer falls through to the next" \
  "$(render STUB_MODE=fail HUMAN_QUEUE_PANDOC="$P" HUMAN_QUEUE_CHROME="$P" HUMAN_QUEUE_CUPSFILTER="$U")" \
  "1 - | pandoc: exit 3; chrome: exit 3; cupsfilter: exit 3"
check "pandoc not installed: Chrome" "$(render HUMAN_QUEUE_PANDOC= HUMAN_QUEUE_CHROME="$C" HUMAN_QUEUE_CUPSFILTER="$U")" \
  "0 chrome | pandoc: not installed"
ARGS=$(cat "$TMP/log/chrome.args")
check_contains "Chrome: headless" "$ARGS" "--headless"
check_contains "Chrome: a profile of its own, in the scratch directory" "$ARGS" "--user-data-dir=$TMP/w/chrome-profile"
check_contains "Chrome: no header or footer of its own" "$ARGS" "--no-pdf-header-footer"
check_contains "Chrome: the HTML as a file URL" "$ARGS" "file://$TMP/r.html"
check_contains "Chrome: offline, no host name resolves" "$ARGS" "--host-resolver-rules=MAP * ~NOTFOUND "
check_contains "Chrome: no background fetches" "$ARGS" "--disable-background-networking"
check "Chrome: the store's URL never reaches it" "$(cat "$TMP/log/chrome.env")" "clean"
check "Chrome: its temp files in the scratch directory" "$(cat "$TMP/log/chrome.tmp")" "$TMP/w/tmp $TMP/w/tmp"
START=$(hq_t_now)
check "Chrome that keeps running after writing is stopped, and counts" \
  "$(render STUB_MODE=linger HUMAN_QUEUE_PANDOC= HUMAN_QUEUE_CHROME="$C" HUMAN_QUEUE_CUPSFILTER=)" "0 chrome | pandoc: not installed"
END=$(hq_t_now)
if hq_t_elapsed_under "$START" "$END" 10; then ok "Chrome stopped promptly"; else bad "Chrome took $(hq_t_elapsed "$START" "$END")s"; fi
check "a renderer past its deadline falls through" \
  "$(render STUB_MODE=hang HUMAN_QUEUE_EXPORT_TIMEOUT=1 HUMAN_QUEUE_PANDOC= HUMAN_QUEUE_CHROME="$C" HUMAN_QUEUE_CUPSFILTER=)" \
  "1 - | pandoc: not installed; chrome: timed out; cupsfilter: not installed"
check "a huge HUMAN_QUEUE_EXPORT_TIMEOUT keeps the default deadline (no overflow into an instant timeout)" \
  "$(render STUB_MODE=slow HUMAN_QUEUE_EXPORT_TIMEOUT=1844674407370955162 HUMAN_QUEUE_PANDOC= HUMAN_QUEUE_CHROME="$C" HUMAN_QUEUE_CUPSFILTER=)" \
  "0 chrome | pandoc: not installed"
limit_of() {
  env HUMAN_QUEUE_EXPORT_TIMEOUT="$1" bash -c 'HQ_BIN_DIR="$1"; . "$HQ_BIN_DIR/lib/common.sh"; . "$HQ_BIN_DIR/lib/export.sh"; hq__export_limit 60' _ "$BIN"
}
check "HUMAN_QUEUE_EXPORT_TIMEOUT: 1 to 86400 is taken, anything else keeps the default" \
  "$(limit_of 5) $(limit_of 86400) $(limit_of 86401) $(limit_of 99999999999999999999) $(limit_of 1844674407370955162) $(limit_of 0) $(limit_of 007) $(limit_of 1.5)" \
  "5 86400 60 60 60 60 60 60"
check "a renderer past its deadline is not left running" \
  "$(if kill -0 "$(cat "$TMP/log/chrome.pid")" 2>/dev/null; then echo running; else echo stopped; fi)" "stopped"

# An export interrupted mid-render (SIGTERM) leaves no renderer running: the
# EXIT trap's hq_export_stop_renderer stops it (export.sh's cleanup runs it).
rm -rf "$TMP/w"
mkdir -p "$TMP/w"
rm -f "$TMP/log"/*
env STUB_LOG="$TMP/log" STUB_MODE=hang HUMAN_QUEUE_PANDOC= HUMAN_QUEUE_CHROME="$C" HUMAN_QUEUE_CUPSFILTER= bash -c '
  HQ_BIN_DIR="$1"; . "$HQ_BIN_DIR/lib/common.sh"; . "$HQ_BIN_DIR/lib/export.sh"
  trap hq_export_stop_renderer EXIT
  hq_export_pdf used "$2/r.md" "$2/r.txt" "$2/r.html" "$2/w/out.pdf" "$2/w"' _ "$BIN" "$TMP" &
OUTER=$!
i=0
while [ ! -s "$TMP/log/chrome.pid" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
STUB_PID=$(cat "$TMP/log/chrome.pid" 2>/dev/null)
kill -TERM "$OUTER" 2>/dev/null
wait "$OUTER" 2>/dev/null
if [ -z "$STUB_PID" ]; then
  bad "an interrupted export: the renderer never started"
elif kill -0 "$STUB_PID" 2>/dev/null; then
  bad "an interrupted export left its renderer running (pid $STUB_PID)"
  kill -KILL "$STUB_PID" 2>/dev/null
else
  ok "an interrupted export stops its renderer"
fi
check_contains "export.sh's cleanup stops a running renderer first" \
  "$(sed -n '/^hq__export_cleanup()/,/^}/p' "$BIN/cmd/export.sh")" "  hq_export_stop_renderer"
check "a file that is not a PDF falls through" \
  "$(render STUB_MODE=notpdf HUMAN_QUEUE_PANDOC= HUMAN_QUEUE_CHROME= HUMAN_QUEUE_CUPSFILTER="$U")" \
  "1 - | pandoc: not installed; chrome: not installed; cupsfilter: no PDF written"
check "cupsfilter: the text, as plain text to PDF" \
  "$(render HUMAN_QUEUE_PANDOC= HUMAN_QUEUE_CHROME= HUMAN_QUEUE_CUPSFILTER="$U")" \
  "0 cupsfilter | pandoc: not installed; chrome: not installed"
check "cupsfilter's arguments" "$(cat "$TMP/log/cupsfilter.args")" "-m application/pdf -i text/plain $TMP/w/export.folded.txt"
check "a forced renderer is the only one tried" \
  "$(render HUMAN_QUEUE_EXPORT_RENDERER=cupsfilter HUMAN_QUEUE_PANDOC="$P" HUMAN_QUEUE_CHROME="$C" HUMAN_QUEUE_CUPSFILTER="$U")" \
  "0 cupsfilter | "
check "5.2 no renderer at all: each one named" \
  "$(render HUMAN_QUEUE_PANDOC= HUMAN_QUEUE_CHROME= HUMAN_QUEUE_CUPSFILTER=)" \
  "1 - | pandoc: not installed; chrome: not installed; cupsfilter: not installed"
check "a path that is not executable counts as not installed" \
  "$(render HUMAN_QUEUE_PANDOC="$TMP/r.md" HUMAN_QUEUE_CHROME=/nonexistent HUMAN_QUEUE_CUPSFILTER=)" \
  "1 - | pandoc: not installed; chrome: not installed; cupsfilter: not installed"
check "markdown: no renderer, by choice" "$(render HUMAN_QUEUE_EXPORT_RENDERER=markdown HUMAN_QUEUE_PANDOC="$P")" \
  "1 - | HUMAN_QUEUE_EXPORT_RENDERER=markdown"
check "file URLs escape what a URL would misread" \
  "$(bash -c 'HQ_BIN_DIR="$1"; . "$HQ_BIN_DIR/lib/common.sh"; . "$HQ_BIN_DIR/lib/export.sh"; hq__export_file_url "/a b/#c?%.html"' _ "$BIN")" \
  "file:///a%20b/%23c%3F%25.html"

# The real ones, on macOS.
if [ "$(uname -s)" = Darwin ] && [ -n "$PDFTOTEXT" ]; then
  if [ -x /usr/sbin/cupsfilter ]; then
    check "real cupsfilter: a PDF" "$(render HUMAN_QUEUE_EXPORT_RENDERER=cupsfilter)" "0 cupsfilter | "
    TEXT=$("$PDFTOTEXT" "$TMP/w/out.pdf" - 2>/dev/null | tr -d '\f')
    for id in D-44 D-41 D-45 R-9 R-10; do check_contains "real cupsfilter: pdftotext finds $id" "$TEXT" "$id"; done
  fi
  if [ -x "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" ]; then
    check "real Chrome: a PDF" "$(render HUMAN_QUEUE_EXPORT_RENDERER=chrome)" "0 chrome | "
    # Chrome leaves its singleton-socket directory (and a fetcher's) behind in
    # the per-user temp directory; on macOS only MAC_CHROMIUM_TMPDIR moves
    # them, here into the scratch directory, which the export removes.
    check_contains "real Chrome: its temp directories in the scratch directory" \
      "$(find "$TMP/w/tmp" -mindepth 1 -maxdepth 1 -name 'com.google.Chrome.*' 2>/dev/null)" "$TMP/w/tmp/com.google.Chrome."
    TEXT=$("$PDFTOTEXT" -layout "$TMP/w/out.pdf" - 2>/dev/null | tr -d '\f')
    for id in D-44 D-41 D-45 R-9 R-10; do check_contains "real Chrome: pdftotext finds $id" "$TEXT" "$id ·"; done
    check "real Chrome: five sections" "$(printf '%s\n' "$TEXT" | grep -cE '^ *[0-9]+ +[DR]-[0-9]+ ·')" "5"
    check_contains "real Chrome: the footer" "$TEXT" "Exported Thu 2026-10-08 17:31 ET"
    check "real Chrome: none left running" "$(pgrep -f "$TMP/w/chrome-profile" | wc -l | tr -d ' ')" "0"
  fi
else
  echo "NOTICE: not macOS or no pdftotext — the real-renderer checks skip"
fi

# --------------------------------------------------------------------- skill
printf '== skill\n'
EXPORT_MD="$SKILL_DIR/export.md"
for anchor in desk-export-missing desk-export; do
  RC=0
  hq_t_skill_block "$EXPORT_MD" "$anchor" > "$TMP/block-$anchor.sh" 2>"$TMP/err" || RC=$?
  check "export.md: anchor $anchor extracts" "$RC:$(cat "$TMP/err")" "0:"
done

# The stub CLI the blocks run against: it logs each call's arguments, one per
# line, so a path with spaces is seen as one argument.
HSTUB="$TMP/hq-stub.sh"
cat > "$HSTUB" <<'EOF'
#!/usr/bin/env bash
: > "$STUB_DIR/hq-args"
for a in "$@"; do printf '%s\n' "$a" >> "$STUB_DIR/hq-args"; done
echo '{"path": "/x.pdf", "format": "pdf", "set_id": 31, "new_set": false, "count": 4, "more": 0, "missing_summary": []}'
EOF
chmod +x "$HSTUB"
STUB_DIR="$TMP/stub"
mkdir -p "$STUB_DIR" "$TMP/run" "$TMP/blocktmp"

literal() { FROM="$2" TO="$3" perl -pe 's/\Q$ENV{FROM}\E/$ENV{TO}/g' "$1"; }
with_line() { awk -v ph="$2" -v t="$3" '$0 == ph { print t; next } { print }' "$1"; }
run_block() {
  (cd "$TMP/run" && env -u TZ DESK="$HQ_T_DESK_DIR" HQ="$HSTUB" SID="desk-1" STUB_DIR="$STUB_DIR" \
     HOME="$TMP/home" HUMAN_QUEUE_EXPORT_DIR="${EXPORT_DIR_OVERRIDE:-}" TMPDIR="$TMP/blocktmp" "$1" "$2") 2>&1
}
args() { tr '\n' '|' < "$STUB_DIR/hq-args"; }
mkdir -p "$TMP/home"

literal "$TMP/block-desk-export-missing.sh" '<the flags>' '--kind reviews' > "$TMP/missing.sh"
PH='<the path after "to", verbatim, or nothing>'
literal "$TMP/block-desk-export.sh" '<the flags>' '--set 31' | literal /dev/stdin '<what>' 'sweep' \
  | with_line /dev/stdin "$PH" "" > "$TMP/default.sh"
HOSTILE='/tmp/my "paper" $(touch pwned) `touch pwned2`.pdf'
literal "$TMP/block-desk-export.sh" '<the flags>' '--kind decisions' | literal /dev/stdin '<what>' 'decisions' \
  | with_line /dev/stdin "$PH" "$HOSTILE" > "$TMP/hostile.sh"
literal "$TMP/block-desk-export.sh" '<the flags>' '--ids D-43 R-9' | literal /dev/stdin '<what>' 'items' \
  | with_line /dev/stdin "$PH" "$(printf '%s' '~')/Desktop/today.pdf" > "$TMP/tilde.sh"

for SH in $BLOCK_SHELLS; do
  OUT=$(run_block "$SH" "$TMP/missing.sh")
  check "[$SH] desk-export-missing: a dry run of the batch" "$(args)" "export|--kind|reviews|--dry-run|--json|"
  check "[$SH] desk-export-missing: exit=0" "$(printf '%s\n' "$OUT" | tail -1)" "exit=0"

  rm -rf "$TMP/home/.claude"
  OUT=$(run_block "$SH" "$TMP/default.sh")
  check "[$SH] desk-export: exit=0" "$(printf '%s\n' "$OUT" | tail -1)" "exit=0"
  A=$(args)
  case "$A" in
    "export|--set|31|--out|$TMP/home/.claude/desk-exports/desk-sweep-"[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]".pdf|--json|")
      ok "[$SH] desk-export: the default file, named for the batch and the time" ;;
    *) bad "[$SH] desk-export: the default file (got $A)" ;;
  esac
  check "[$SH] desk-export: the default directory is private" "$(ls -ld "$TMP/home/.claude/desk-exports" 2>/dev/null | cut -c1-10)" "drwx------"
  check "[$SH] desk-export: removes its temp file" "$(find "$TMP/blocktmp" -type f | wc -l | tr -d ' ')" "0"

  OUT=$(run_block "$SH" "$TMP/hostile.sh")
  check "[$SH] desk-export: the operator's path arrives as typed" "$(sed -n 5p "$STUB_DIR/hq-args")" "$HOSTILE"
  check "[$SH] desk-export: nothing in it ran" "$(find "$TMP/run" -name 'pwned*' | wc -l | tr -d ' ')" "0"
  OUT=$(run_block "$SH" "$TMP/tilde.sh")
  check "[$SH] desk-export: ~/ is the home directory" "$(args)" "export|--ids|D-43|R-9|--out|$TMP/home/Desktop/today.pdf|--json|"
done

# The router and the files around it.
contract() {
  local name="$1" text="$2" needle
  while IFS= read -r needle; do
    [ -n "$needle" ] || continue
    check_contains "$name: $needle" "$text" "$needle"
  done
}
contract SKILL.md "$(cat "$SKILL_DIR/SKILL.md")" <<'NEEDLES'
| `export.md` |
**An export verb** as the whole message
→ load `export.md` (#1759)
**`sweep`** → load `sweep.md`
NEEDLES
contract sweep.md "$(cat "$SKILL_DIR/sweep.md")" <<'NEEDLES'
`export` after a sweep → load `export.md`
`--set <the set id>`
NEEDLES
check_absent "sweep.md: no Markdown copy of its own any more" "$(cat "$SKILL_DIR/sweep.md")" "md="
contract export.md "$(cat "$EXPORT_MD")" <<'NEEDLES'
**Plain text only, never AskUserQuestion.**
<<'DESK_EXPORT_PATH'
`--set <the sweep's set id>`
"missing_summary"
`reviews.md`, "`open R-<n>`: level 2, cached"
`"format": "markdown"`
`"new_set": true`
NEEDLES
contract skill/README.md "$(cat "$SKILL_DIR/README.md")" <<'NEEDLES'
| `export.md` |
NEEDLES

hq_t_finish export-offline.test.sh
