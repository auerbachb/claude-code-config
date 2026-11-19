#!/usr/bin/env bash
# Offline regression suite for `/markdown-audit` (issue #2353).
# catalog: tests — Tests the `/markdown-audit` helper (inventory, segment, pairs, report, read-only check) and the skill's real snapshot block
# covers: .claude/skills/markdown-audit/SKILL.md .claude/skills/markdown-audit/mdaudit.py .claude/skills/markdown-audit/references/levels.md
#
# Every case runs in a throwaway git fixture under mktemp with an isolated HOME
# and TMPDIR; the real checkout is never touched. The snapshot block is pulled
# out of SKILL.md by its test anchor (lib/skill-bash.sh), so the suite runs the
# skill's own instructions, not a copy.
#
# Requires: bash 3.2+, git, jq, python3. Offline.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
SKILL_DIR="$REPO/.claude/skills/markdown-audit"
MDAUDIT="$SKILL_DIR/mdaudit.py"
# shellcheck source=lib/skill-bash.sh
source "$HERE/lib/skill-bash.sh"

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); echo "ok   - $1"; }
bad()  { FAIL=$((FAIL + 1)); echo "FAIL - $1"; [ "$#" -gt 1 ] && printf '       %s\n' "$2"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3] got [$2]"; fi; }
# Run a command with a 20s limit using only python3 (no extra prerequisite).
with_timeout() {
  python3 -I -B -c 'import subprocess, sys
try:
    sys.exit(subprocess.run(sys.argv[1:], timeout=20).returncode)
except subprocess.TimeoutExpired:
    sys.exit(124)' "$@"
}
# Call one helper function directly: mda_py '<expr using mdaudit and a>' args...
mda_py() { local expr="$1"; shift
  with_timeout python3 -I -B -c 'import sys; sys.path.insert(0, sys.argv[1]); import mdaudit; a = sys.argv[2:]; print('"$expr"')' "$(dirname "$MDAUDIT")" "$@"; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/markdown-audit-test.XXXXXX")" || exit 1
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home" TMPDIR="$WORK/tmp"
mkdir -p "$HOME/.claude/skills" "$TMPDIR"
ln -s "$SKILL_DIR" "$HOME/.claude/skills/markdown-audit"
# A git hook running this suite may export repository variables; clear them so
# fixture commits can never land in the caller's checkout.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_COMMON_DIR GIT_PREFIX
export GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com \
  GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com

FX="$WORK/fx"
mkdir -p "$FX/.claude/skills/alpha" "$FX/.claude/skills/beta" "$FX/docs/sub dir" "$WORK/outside"
SHARED="When the merge gate passes and every test plan box verifies, run the full wrap flow without an approval pause and report the merged pull request number once."

cat > "$FX/.claude/skills/alpha/SKILL.md" <<EOF
# Alpha

Intro paragraph one.
Still intro.

## Steps

- one
- two

\`\`\`bash
# Not a heading inside a fence
echo hi
\`\`\`

## Merge

$SHARED

### Detail

| a | b |
|---|---|
| 1 | 2 |
EOF

cat > "$FX/.claude/skills/beta/SKILL.md" <<EOF
# Beta

## Gate

$SHARED

## Other

Unrelated words here about something else entirely.
EOF

printf '# Spaced\n\nA file in a folder with a space.\n' > "$FX/docs/sub dir/spaced fixture-note.md"
printf '# Outside\n\nOutside text.\n' > "$WORK/outside/out.md"
ln -s "$WORK/outside/out.md" "$FX/docs/escape.md"
ln -s "../.claude/skills/beta/SKILL.md" "$FX/docs/beta-link.md"
printf 'x\n' > "$FX/notes.txt"
git -C "$FX" init -q && git -C "$FX" add -A && git -C "$FX" commit -qm init

run_md() { (cd "${MDA_CWD:-$FX}" && python3 "$MDAUDIT" "$@"); }

# --------------------------------------------------------------- levels
check "levels: file default 1-7" "$(run_md levels --kind file)" "1 7"
check "levels: repo default 5-7" "$(run_md levels --kind repo)" "5 7"
check "levels: stop at section by name" "$(run_md levels --kind folder --stop-at section)" "1 3"
check "levels: repo --from 1" "$(run_md levels --kind repo --from sentence)" "1 7"
run_md levels --kind file --from 5 --stop-at 3 >/dev/null 2>&1; check "levels: from above stop fails" "$?" "2"
run_md levels --kind file --stop-at bogus >/dev/null 2>&1; check "levels: unknown level fails" "$?" "2"
run_md levels --kind repo --stop-at 3 >/dev/null 2>&1; check "levels: repo below 5 without --from fails" "$?" "2"

# --------------------------------------------------------------- inventory
SNAP="$WORK/snap-repo.json"
run_md inventory > "$SNAP"
check "inventory: repo kind" "$(jq -r .target_kind "$SNAP")" "repo"
check "inventory: corpus (symlink escape dropped, link deduplicated)" \
  "$(jq -r '.corpus | join(",")' "$SNAP")" \
  ".claude/skills/alpha/SKILL.md,.claude/skills/beta/SKILL.md,docs/sub dir/spaced fixture-note.md"
check "inventory: escape recorded" "$(jq -r '[.excluded[] | select(.path=="docs/escape.md") | .reason] | .[0]' "$SNAP")" \
  "symlink resolves outside the checkout"
check "inventory: link recorded as duplicate" "$(jq -r '[.excluded[] | select(.path=="docs/beta-link.md")] | length' "$SNAP")" "1"
check "inventory: skills form one sibling group" "$(jq -r '.groups[".claude/skills"] | length' "$SNAP")" "2"

FSNAP="$WORK/snap-file.json"
MDA_CWD="$FX/.claude/skills" run_md inventory --target alpha/SKILL.md > "$FSNAP"
check "inventory: relative file target from a subdirectory" "$(jq -r '[.target_kind, (.in_scope|join(","))] | join(" ")' "$FSNAP")" \
  "file .claude/skills/alpha/SKILL.md"
check "inventory: folder with spaces" "$(run_md inventory --target "docs/sub dir" | jq -r '.target_kind + " " + (.in_scope|join(","))')" \
  "folder docs/sub dir/spaced fixture-note.md"
run_md inventory --target "$WORK/outside" >/dev/null 2>&1; check "inventory: outside target rejected" "$?" "2"
run_md inventory --target notes.txt >/dev/null 2>&1; check "inventory: non-Markdown target rejected" "$?" "2"
check "inventory: checkout root is a repo run" "$(MDA_CWD="$FX/docs" run_md inventory --target .. | jq -r .target_kind)" "repo"

# --------------------------------------------------------------- segment
SEG="$(run_md segment --snapshot "$FSNAP")"
A='.files[".claude/skills/alpha/SKILL.md"]'
check "segment: fenced '#' line is not a heading" "$(jq -r "$A.sections | map(.title) | join(\",\")" <<<"$SEG")" "Alpha,Steps,Merge,Detail"
check "segment: section ranges" "$(jq -r "$A.sections | map(\"\(.start)-\(.end)\") | join(\",\")" <<<"$SEG")" "1-24,6-14,16-24,20-24"
check "segment: block kinds" "$(jq -r "$A.blocks | map(.kind) | join(\",\")" <<<"$SEG")" \
  "heading,paragraph,heading,list,fence,heading,paragraph,heading,table"
check "segment: fence is one block" "$(jq -r "$A.blocks[] | select(.kind==\"fence\") | \"\(.start)-\(.end)\"" <<<"$SEG")" "11-14"
check "segment: pages split at repeated top-level headings" "$(jq -r "$A.pages | map(\"\(.start)-\(.end)\") | join(\",\")" <<<"$SEG")" "1-4,6-14,16-24"

# Edge cases through a dedicated fixture: CRLF, unclosed and nested fences, long file.
EDGE="$WORK/edge"
mkdir -p "$EDGE"
printf '# T\r\n\r\nline\r\n\r\n````md\r\n```\r\n# inner\r\n```\r\n````\r\n\r\n## After\r\n\r\ntext\r\n' > "$EDGE/crlf.md"
printf '# U\n\n```\n# never closed\nstill fence\n' > "$EDGE/unclosed.md"
printf '# I\n\n```foo``` opens a paragraph.\n\n## Later\n\ntext\n' > "$EDGE/inline.md"
printf '# W\n\n~~~ a`b\n# tilde inner\n~~~\n\n  ````py\n```\n# long inner\n  ````\n\n## End\n' > "$EDGE/tilde.md"
{ echo "# Long"; for i in $(seq 1 120); do echo; echo "para $i"; done; } > "$EDGE/long.md"
git -C "$EDGE" init -q && git -C "$EDGE" add -A && git -C "$EDGE" commit -qm init
ESNAP="$WORK/snap-edge.json"
MDA_CWD="$EDGE" run_md inventory > "$ESNAP"
ESEG="$(MDA_CWD="$EDGE" run_md segment --snapshot "$ESNAP")"
check "segment: CRLF + nested fence keeps inner heading out" "$(jq -r '.files["crlf.md"].sections | map(.title) | join(",")' <<<"$ESEG")" "T,After"
check "segment: nested fence spans outer fence" "$(jq -r '.files["crlf.md"].blocks[] | select(.kind=="fence") | "\(.start)-\(.end)"' <<<"$ESEG")" "5-9"
check "segment: unclosed fence flagged and runs to EOF" \
  "$(jq -r '.files["unclosed.md"] | "\(.unclosed_fence) \(.blocks[-1].kind) \(.blocks[-1].end)"' <<<"$ESEG")" "true fence 5"
check "segment: inline code with backticks is not a fence" \
  "$(jq -r '.files["inline.md"] | "\(.unclosed_fence) \(.sections | map(.title) | join(",")) \([.blocks[] | select(.kind=="fence")] | length)"' <<<"$ESEG")" "false I,Later 0"
check "segment: tilde fence with backtick info and indented long fence still fence" \
  "$(jq -r '.files["tilde.md"] | "\(.unclosed_fence) \(.sections | map(.title) | join(",")) \([.blocks[] | select(.kind=="fence") | "\(.start)-\(.end)"] | join(","))"' <<<"$ESEG")" "false W,End 3-5,7-10"
check "segment: no page longer than 50 lines" "$(jq -r '[.files["long.md"].pages[] | .end - .start + 1] | max <= 50' <<<"$ESEG")" "true"
check "segment: pages cover the long file" "$(jq -r '.files["long.md"].pages | "\(.[0].start) \(.[-1].end) \(length)"' <<<"$ESEG")" "1 241 5"

# --------------------------------------------------------------- pairs
P6="$(run_md pairs --snapshot "$SNAP" --level 6)"
check "pairs: one level-6 candidate naming both files" "$(jq -r '.pairs | map(.a + "|" + .b) | join(",")' <<<"$P6")" \
  ".claude/skills/alpha/SKILL.md|.claude/skills/beta/SKILL.md"
check "pairs: ranges in both files hit the shared paragraph" \
  "$(jq -r '.pairs[0] | "\(.ranges_a[0].start) \(.ranges_b[0].start)"' <<<"$P6")" "18 5"
check "pairs: --limit 0 reports what it dropped" \
  "$(run_md pairs --snapshot "$SNAP" --level 6 --limit 0 | jq -r '"\(.total_candidates) \(.dropped_by_limit)"')" "1 1"

# --------------------------------------------------------------- report / tally
F="$WORK/findings.jsonl"
{
  echo '{"level":1,"file":".claude/skills/alpha/SKILL.md","start":3,"end":4,"action":"cut","reason":"filler"}'
  echo '{"level":2,"file":".claude/skills/alpha/SKILL.md","start":3,"end":4,"action":"cut","reason":"same lines again"}'
  echo '{"level":3,"file":".claude/skills/alpha/SKILL.md","start":20,"end":24,"action":"move","target":"docs/x.md","reason":"belongs elsewhere"}'
  echo '{"level":3,"file":".claude/skills/alpha/SKILL.md","start":6,"end":9,"action":"keep","reason":"caller contract"}'
  echo '{"level":2,"file":".claude/skills/alpha/SKILL.md","start":3,"end":99,"action":"cut","reason":"bad range"}'
  echo '{"level":2,"file":".claude/skills/alpha/SKILL.md","start":3,"end":3,"action":"merge","reason":"no target"}'
  echo '{"level":6,"file":".claude/skills/alpha/SKILL.md","start":18,"end":18,"action":"merge","target":"beta","reason":"no other file"}'
  echo '{"level":2,"file":".claude/skills/alpha/SKILL.md","start":3,"end":3,"action":"zap","reason":"bad action"}'
  echo '{"level":2,"file":".claude/skills/alpha/SKILL.md","start":3,"end":3,"action":"cut","reason":"two\nlines"}'
  echo '{"level":4,"file":".claude/skills/alpha/SKILL.md","start":3,"end":3,"action":"cut","reason":"above stop level"}'
  echo '{"level":2,"file":".claude/skills/alpha/SKILL.md","start":3.9,"end":4,"action":"cut","reason":"fractional line"}'
} > "$F"
R="$(run_md report --snapshot "$FSNAP" --findings "$F" --stop-at section --format json)"
check "report: per-level removal counted per level" "$(jq -r '"\(.per_level["1"].removed) \(.per_level["2"].removed)"' <<<"$R")" "5 5"
check "report: overlapping ranges counted once in total" "$(jq -r .total_removed <<<"$R")" "5"
check "report: move words are relocated, not removed" "$(jq -r '"\(.per_level["3"].removed) \(.total_moved)"' <<<"$R")" "0 13"
check "report: malformed findings rejected (fractional line included)" "$(jq -r '.invalid | length' <<<"$R")" "7"
MD="$(run_md report --snapshot "$FSNAP" --findings "$F" --stop-at section)"
check "report: stop at section reports no level above 3" "$(grep -c '^## Level [4-7]' <<<"$MD")" "0"
check "report: levels in order" "$(grep '^## Level' <<<"$MD" | cut -c10 | tr -d '\n')" "123"
if grep -q '^## What NOT to change (1)' <<<"$MD"; then ok "report: keep rows listed"; else bad "report: keep rows listed"; fi

F2="$WORK/findings2.jsonl"
{
  echo '{"level":1,"file":".claude/skills/alpha/SKILL.md","start":3,"end":3,"action":"cut","reason":"filler"}'
  echo '{"level":3,"file":".claude/skills/alpha/SKILL.md","start":3,"end":4,"action":"move","target":"docs/x.md","reason":"belongs elsewhere"}'
  echo '{"level":2,"file":".claude/skills/alpha/SKILL.md","start":8,"end":9,"action":"keep","reason":"caller contract"}'
  echo '{"level":1,"file":".claude/skills/alpha/SKILL.md","start":9,"end":9,"action":"cut","reason":"overlaps a keep"}'
  echo 'null'
  echo '[1,2]'
  echo '{"level":2,"file":".claude/skills/alpha/SKILL.md","start":3,"end":3,"other_file":".claude/skills/beta/SKILL.md","action":"cut","reason":"second file at level 2"}'
  echo '{"level":6,"file":".claude/skills/alpha/SKILL.md","start":3,"end":3,"other_file":"docs/sub dir/spaced fixture-note.md","other_start":1,"other_end":1,"action":"merge","target":"x","reason":"not one sibling group"}'
  echo '{"level":6,"file":[],"start":1,"end":1,"other_file":".claude/skills/beta/SKILL.md","other_start":1,"other_end":1,"action":"cut","reason":"file is not a string"}'
  echo '{"level":7,"file":".claude/skills/beta/SKILL.md","start":1,"end":1,"other_file":"docs/sub dir/spaced fixture-note.md","other_start":1,"other_end":1,"action":"merge","target":"x","reason":"neither file in scope"}'
} > "$F2"
R2="$(run_md report --snapshot "$FSNAP" --findings "$F2" --format json)"
check "report: moved line also removed counts only as removed" "$(jq -r '"\(.total_removed) \(.total_moved)"' <<<"$R2")" "3 2"
check "report: proposal overlapping a keep is a conflict" "$(jq -r '.conflicts | map(.start) | join(",")' <<<"$R2")" "9"
check "report: non-object rows, stray second file, bad pair scope rejected" "$(jq -r '.invalid | length' <<<"$R2")" "6"

FP="$WORK/f6.jsonl"
echo '{"level":6,"file":".claude/skills/alpha/SKILL.md","start":18,"end":18,"other_file":".claude/skills/beta/SKILL.md","other_start":5,"other_end":5,"action":"merge","target":".claude/skills/beta/SKILL.md","reason":"same gate paragraph"}' > "$FP"
run_md pairs --snapshot "$SNAP" --level 6 > "$WORK/p6.json"
MD6="$(run_md report --snapshot "$SNAP" --findings "$FP" --pairs "$WORK/p6.json")"
if grep -q 'alpha/SKILL.md:18 <-> .claude/skills/beta/SKILL.md:5' <<<"$MD6"; then ok "report: level-6 row names both files"; else bad "report: level-6 row names both files"; fi
if grep -q 'unreviewed pair (level 6)' <<<"$MD6"; then ok "report: pair without coverage is unreviewed"; else bad "report: pair without coverage is unreviewed"; fi
FK="$WORK/fk.jsonl"
{
  echo '{"level":6,"file":".claude/skills/beta/SKILL.md","start":5,"end":5,"other_file":".claude/skills/alpha/SKILL.md","other_start":1,"other_end":1,"action":"keep","reason":"beta owns the gate wording"}'
  echo '{"level":6,"file":".claude/skills/alpha/SKILL.md","start":18,"end":18,"other_file":".claude/skills/beta/SKILL.md","other_start":5,"other_end":5,"action":"merge","target":"beta","reason":"conflicts only in other_file"}'
} > "$FK"
C6="$WORK/c6.jsonl"
{
  echo '{"level":6,"pair":[".claude/skills/alpha/SKILL.md",null],"status":"reviewed"}'
  echo '{"level":6,"pair":[".claude/skills/beta/SKILL.md",".claude/skills/alpha/SKILL.md"],"status":"reviewed"}'
} > "$C6"
check "report: keep conflict detected at the second pair location" \
  "$(run_md report --snapshot "$SNAP" --findings "$FK" --coverage "$C6" --pairs "$WORK/p6.json" --format json | jq -r '.conflicts | length')" "1"
check "report: pair finding without a reviewed pair is kept out of filing" \
  "$(run_md report --snapshot "$SNAP" --findings "$FP" --format json | jq -r '"\(.findings | length) \(.unreviewed_pair_findings | length)"')" "0 1"
check "report: pair finding with a reviewed pair is offered" \
  "$(run_md report --snapshot "$SNAP" --findings "$FP" --coverage "$C6" --pairs "$WORK/p6.json" --format json | jq -r '"\(.findings | length) \(.unreviewed_pair_findings | length)"')" "1 0"
check "report: reviewed pair outside the candidate list is not offered" \
  "$(run_md report --snapshot "$SNAP" --findings "$FP" --coverage "$C6" --format json | jq -r '"\(.findings | length) \(.unreviewed_pair_findings | length)"')" "0 1"
C9="$WORK/c9.jsonl"
echo '{"level":6.9,"pair":[".claude/skills/beta/SKILL.md",".claude/skills/alpha/SKILL.md"],"status":"reviewed"}' > "$C9"
check "report: fractional coverage level is not counted as reviewed" \
  "$(run_md report --snapshot "$SNAP" --findings "$FP" --coverage "$C9" --pairs "$WORK/p6.json" --format json | jq -r '.coverage.pairs.reviewed | length')" "0"
FBAD="$WORK/fbad.jsonl"
{
  echo '{"level":Infinity,"file":".claude/skills/alpha/SKILL.md","start":3,"end":3,"action":"cut","reason":"inf level"}'
  echo '{"level":1e999,"file":".claude/skills/alpha/SKILL.md","start":3,"end":3,"action":"cut","reason":"overflow level"}'
  echo '{"level":1,"file":".claude/skills/alpha/SKILL.md","start":3,"end":3,"action":"cut","reason":"agent field","_parse_error":7}'
  echo '{"level":1,"file":".claude/skills/alpha/SKILL.md","start":3,"end":3,"action":"cut","reason":"carriage\rreturn"}'
  echo '{"level":1,"file":".claude/skills/alpha/SKILL.md","start":3,"end":3,"action":"cut","reason":"\rleading"}'
  echo '{"level":1,"file":".claude/skills/alpha/SKILL.md","start":3,"end":3,"action":"cut","reason":"trailing\r"}'
} > "$FBAD"
RB="$(run_md report --snapshot "$FSNAP" --findings "$FBAD" --format json)"; RC=$?
check "report: non-finite level and CR reason rejected without a crash" "$RC $(jq -r '.invalid | length' <<<"$RB")" "0 5"
check "report: an agent _parse_error field is just a field" "$(jq -r '.findings | length' <<<"$RB")" "1"
if run_md report --snapshot "$FSNAP" --findings "$FBAD" >/dev/null; then ok "report: markdown renders with malformed rows"; else bad "report: markdown renders with malformed rows"; fi
check "report: malformed coverage pair skipped, valid pair in either order counted" \
  "$(run_md report --snapshot "$SNAP" --findings "$FP" --coverage "$C6" --pairs "$WORK/p6.json" --format json | jq -r '"\(.coverage.pairs.reviewed | length) \(.coverage.pairs.unreviewed | length)"')" "1 0"

# --------------------------------------------------------------- the skill's own snapshot block
BLOCK="$(extract_skill_bash "$SKILL_DIR/SKILL.md" markdown-audit-snapshot)" || { bad "extract snapshot block"; BLOCK=""; }
REPBLOCK="$(extract_skill_bash "$SKILL_DIR/SKILL.md" markdown-audit-report)" || { bad "extract report block"; REPBLOCK=""; }
run_block() { (cd "$FX" && MDA_TARGET="$1" MDA_FROM="$2" MDA_STOP="$3" bash -c "$BLOCK" 2>&1); }
fx_state() { (cd "$FX" && git rev-parse HEAD && git status --porcelain=v1 && find . -path ./.git -prune -o -type f -print0 | sort -z | xargs -0 shasum); }

BEFORE="$(fx_state)"
OUT="$(run_block .claude/skills/alpha/SKILL.md "" section)"
RUN="$(sed -n 's/^MDA_RUN=//p' <<<"$OUT")"
check "block: stop at section runs levels 1-3" "$(sed -n 's/^LEVELS=//p' <<<"$OUT")" "1-3"
if [ -n "$RUN" ] && [ -f "$RUN/segments.json" ]; then ok "block: segments built"; else bad "block: segments built" "$OUT"; fi
if [ -n "$RUN" ] && [ ! -e "$RUN/pairs-6.json" ] && [ ! -e "$RUN/pairs-7.json" ]; then ok "block: no pair work above the stop level"; else bad "block: no pair work above the stop level"; fi
case "$RUN" in "$(cd "$TMPDIR" && pwd -P)"/*) ok "block: run directory outside the checkout" ;; *) bad "block: run directory outside the checkout" "$RUN" ;; esac
if [ -n "$RUN" ]; then
  REP="$(cd "$FX" && MDAUDIT="$MDAUDIT" MDA_RUN="$RUN" MDA_LO=1 MDA_HI=3 bash -c "$REPBLOCK" 2>&1)"
  check "report block: runs with no findings" "$?" "0"
  [ -s "$RUN/report.md" ] || bad "report block: wrote a report" "$REP"
  check "report block: renders levels 1-3 only" "$(grep -c '^## Level' "$RUN/report.md")" "3"
  check "report block: writes the validated JSON the filing gate reads" "$(jq -r '.findings | length' "$RUN/report.json")" "0"
  check "verify-unchanged: clean fixture" "$(cd "$FX" && python3 "$MDAUDIT" verify-unchanged --snapshot "$RUN/snapshot.json" --before "$RUN/before.json")" "UNCHANGED"
fi
check "block: clean fixture unchanged (HEAD, status, hashes)" "$(fx_state)" "$BEFORE"

OUT="$(run_block "" "" "")"
check "block: repo run defaults to 5-7" "$(sed -n 's/^LEVELS=//p' <<<"$OUT")" "5-7"
RUN="$(sed -n 's/^MDA_RUN=//p' <<<"$OUT")"
if [ -n "$RUN" ] && [ -f "$RUN/pairs-6.json" ] && [ -f "$RUN/pairs-7.json" ]; then ok "block: repo run builds pairs"; else bad "block: repo run builds pairs" "$OUT"; fi

OUT="$(run_block .claude/skills/alpha/SKILL.md 5 3)"; RC=$?
if [ "$RC" -ne 0 ] && grep -q 'above --stop-at' <<<"$OUT"; then ok "block: --from 5 --stop-at 3 fails"; else bad "block: --from 5 --stop-at 3 fails" "$OUT"; fi

# Dirty fixture: the check must hold, and must catch a real edit.
printf '\nlocal edit\n' >> "$FX/.claude/skills/beta/SKILL.md"
printf '# New\n\nuntracked draft\n' > "$FX/docs/draft.md"
BEFORE="$(fx_state)"
OUT="$(run_block "" "" "")"
RUN="$(sed -n 's/^MDA_RUN=//p' <<<"$OUT")"
check "block: dirty fixture unchanged by a run" "$(fx_state)" "$BEFORE"
check "verify-unchanged: dirty fixture" "$(cd "$FX" && python3 "$MDAUDIT" verify-unchanged --snapshot "$RUN/snapshot.json" --before "$RUN/before.json")" "UNCHANGED"
printf 'edit\n' >> "$FX/docs/draft.md"
(cd "$FX" && python3 "$MDAUDIT" verify-unchanged --snapshot "$RUN/snapshot.json" --before "$RUN/before.json" >/dev/null)
check "verify-unchanged: detects an edit" "$?" "1"

# A second edit to an already-dirty non-Markdown file must also be caught.
printf 'y\n' >> "$FX/notes.txt"
(cd "$FX" && python3 "$MDAUDIT" inventory > "$WORK/snap-dirty.json" && python3 "$MDAUDIT" fingerprint --snapshot "$WORK/snap-dirty.json" > "$WORK/before-dirty.json")
printf 'z\n' >> "$FX/notes.txt"
(cd "$FX" && python3 "$MDAUDIT" verify-unchanged --snapshot "$WORK/snap-dirty.json" --before "$WORK/before-dirty.json" >/dev/null)
check "verify-unchanged: detects a second edit to a dirty non-Markdown file" "$?" "1"

# Fingerprint never follows a dirty symlink out of the checkout and never
# opens a FIFO.
printf 'outside\n' > "$WORK/outside.txt"
ln -s "$WORK/outside.txt" "$FX/ext-link"
mkfifo "$FX/pipe"
(cd "$FX" && python3 "$MDAUDIT" inventory > "$WORK/snap-special.json")
FP="$(cd "$FX" && with_timeout python3 "$MDAUDIT" fingerprint --snapshot "$WORK/snap-special.json")"; RC=$?
check "fingerprint: FIFO in the checkout does not block" "$RC" "0"
check "fingerprint: dirty symlink hashed by its target string" "$(jq -r '.files["ext-link"][0:5]' <<<"$FP")" "link:"
check "fingerprint: a FIFO is never opened (metadata only)" \
  "$(with_timeout python3 -I -B -c 'import sys; sys.path.insert(0, sys.argv[1]); import mdaudit; print(mdaudit.path_digest(sys.argv[2])[0:5])' "$(dirname "$MDAUDIT")" "$FX/pipe")" "meta:"
printf '%s\n' "$FP" > "$WORK/before-special.json"
printf 'changed outside\n' >> "$WORK/outside.txt"
check "verify-unchanged: an out-of-tree symlink target is not read" \
  "$(cd "$FX" && with_timeout python3 "$MDAUDIT" verify-unchanged --snapshot "$WORK/snap-special.json" --before "$WORK/before-special.json")" "UNCHANGED"
rm -f "$FX/ext-link" "$FX/pipe"

# A parent directory swapped for a link out of the checkout is never read.
mkdir -p "$WORK/outdir" "$WORK/fx-parent"
printf 'secret\n' > "$WORK/outdir/a.md"
ln -s "$WORK/outdir" "$WORK/fx-parent/docs"
check "fingerprint: file under an out-of-tree parent link is not read" \
  "$(mda_py 'mdaudit.path_digest(a[0], a[1])[0:8]' "$WORK/fx-parent/docs/a.md" "$WORK/fx-parent")" "outside:"

# A corpus file replaced by a FIFO is refused without blocking.
mkfifo "$WORK/swapped.md"
check "read: a FIFO is refused without blocking" "$(mda_py 'mdaudit.read_regular(a[0])' "$WORK/swapped.md")" "None"

# Environment files are never read, even behind a Markdown-named link.
check "env: names recognised" "$(mda_py 'mdaudit.is_env_file(a[0]) and mdaudit.is_env_file(a[1]) and not mdaudit.is_env_file(a[2])' "x/.env" "x/.env.local" "x/env.md")" "True"
mkdir -p "$WORK/fx-env"
printf '# Ok\n\ntext\n' > "$WORK/fx-env/ok.md"
ln -s "cfg/.env.local" "$WORK/fx-env/notes.md"
git -C "$WORK/fx-env" init -q && git -C "$WORK/fx-env" add -A && git -C "$WORK/fx-env" commit -qm init
check "inventory: Markdown link to an environment file excluded unread" \
  "$(cd "$WORK/fx-env" && python3 "$MDAUDIT" inventory | jq -r '[(.corpus | join(",")), ([.excluded[] | select(.path=="notes.md") | .reason] | .[0])] | join(" | ")')" \
  "ok.md | environment file (never read)"
(cd "$WORK/fx-env" && python3 "$MDAUDIT" inventory > "$WORK/snap-env.json" && python3 "$MDAUDIT" fingerprint --snapshot "$WORK/snap-env.json" > "$WORK/before-env.json")
check "verify-unchanged: environment-file link leaves the run UNCHANGED" \
  "$(cd "$WORK/fx-env" && python3 "$MDAUDIT" verify-unchanged --snapshot "$WORK/snap-env.json" --before "$WORK/before-env.json")" "UNCHANGED"

# The descriptor walk refuses a symlinked parent, including one swapped in
# after the walk starts (simulated by swapping on the first os.open).
mkdir -p "$WORK/fx-race/docs" "$WORK/race-out"
printf 'in\n' > "$WORK/fx-race/docs/a.md"
printf 'outside secret\n' > "$WORK/race-out/a.md"
RACE="$(with_timeout python3 -I -B -c '
import os, sys
sys.path.insert(0, sys.argv[1])
import mdaudit
top, out = sys.argv[2], sys.argv[3]
real_open, state = os.open, {"swapped": False}
def swapping_open(path, flags, *a, **k):
    if not state["swapped"] and path == top:
        state["swapped"] = True
        os.rename(os.path.join(top, "docs"), os.path.join(top, "docs-old"))
        os.symlink(out, os.path.join(top, "docs"))
    return real_open(path, flags, *a, **k)
os.open = swapping_open
try:
    mdaudit.open_in_checkout(top, "docs/a.md", read=True)
    print("read")
except mdaudit.EscapeError:
    print("refused")
' "$(dirname "$MDAUDIT")" "$WORK/fx-race" "$WORK/race-out")"
check "walk: parent swapped for an outside link mid-walk is refused" "$RACE" "refused"
# A leaf link is read on the parent descriptor: swapping the parent after the
# leaf check (simulated on the leaf stat) still yields the in-checkout link.
mkdir -p "$WORK/fx-lrace/docs" "$WORK/lrace-out"
ln -s inside-target "$WORK/fx-lrace/docs/l.md"
ln -s outside-target "$WORK/lrace-out/l.md"
LRACE="$(with_timeout python3 -I -B -c '
import os, sys
sys.path.insert(0, sys.argv[1])
import mdaudit
top, out = sys.argv[2], sys.argv[3]
real_stat, state = os.stat, {"swapped": False}
def swapping_stat(path, *a, **k):
    r = real_stat(path, *a, **k)
    if not state["swapped"] and path == "l.md":
        state["swapped"] = True
        os.rename(os.path.join(top, "docs"), os.path.join(top, "docs-old"))
        os.symlink(out, os.path.join(top, "docs"))
    return r
os.stat = swapping_stat
st, data = mdaudit.open_in_checkout(top, "docs/l.md")
print(data.decode())
' "$(dirname "$MDAUDIT")" "$WORK/fx-lrace" "$WORK/lrace-out")"
check "walk: leaf link read on the parent descriptor despite a parent swap" "$LRACE" "inside-target"

# HEAD recorded by inventory must match the baseline.
jq '.head = "0000000000000000000000000000000000000000"' "$WORK/snap-special.json" > "$WORK/snap-oldhead.json"
OUTH="$(cd "$FX" && python3 "$MDAUDIT" verify-unchanged --snapshot "$WORK/snap-oldhead.json" --before "$WORK/before-special.json")"; RC=$?
if [ "$RC" -eq 1 ] && grep -q 'between inventory and baseline' <<<"$OUTH"; then ok "verify-unchanged: inventory HEAD differs from baseline"; else bad "verify-unchanged: inventory HEAD differs from baseline" "$OUTH"; fi

# A quote line holding only ">" separates two quoted paragraphs.
check "segment: blank quote line splits quoted paragraphs" \
  "$(mda_py '[ (b["start"], b["end"]) for b in mdaudit.segment_lines(["> one", ">", "> two"])["blocks"] ]')" "[(1, 1), (3, 3)]"

# TMPDIR inside the checkout is refused before anything is written there.
OUT="$(cd "$FX" && TMPDIR="$FX/docs" MDA_TARGET="" MDA_FROM="" MDA_STOP="" bash -c "$BLOCK" 2>&1)"; RC=$?
if [ "$RC" -ne 0 ] && grep -q 'TMPDIR resolves inside the checkout' <<<"$OUT" && [ -z "$(find "$FX/docs" -name 'markdown-audit.*')" ]; then
  ok "block: TMPDIR inside the checkout refused"; else bad "block: TMPDIR inside the checkout refused" "$OUT"; fi
# ...and refused before mktemp is ever called: a logging mktemp shim stays silent.
mkdir -p "$WORK/shim"
REAL_MKTEMP="$(command -v mktemp)"
printf '#!/bin/sh\necho "$*" >> "%s"\nexec "%s" "$@"\n' "$WORK/mktemp.log" "$REAL_MKTEMP" > "$WORK/shim/mktemp"
chmod +x "$WORK/shim/mktemp"
: > "$WORK/mktemp.log"
(cd "$FX" && PATH="$WORK/shim:$PATH" TMPDIR="$FX/docs" MDA_TARGET="" MDA_FROM="" MDA_STOP="" bash -c "$BLOCK" >/dev/null 2>&1)
check "block: in-checkout TMPDIR never reaches mktemp" "$(wc -l < "$WORK/mktemp.log" | tr -d ' ')" "0"
(cd "$FX" && PATH="$WORK/shim:$PATH" MDA_TARGET=".claude/skills/alpha/SKILL.md" MDA_FROM="" MDA_STOP="section" bash -c "$BLOCK" >/dev/null 2>&1)
check "block: the mktemp shim is exercised on a normal run" "$(wc -l < "$WORK/mktemp.log" | tr -d ' ')" "1"

# --------------------------------------------------------------- SKILL.md contract
S="$SKILL_DIR/SKILL.md"
if grep -q 'Skip first' "$S" && grep -q 'Skip wins' "$S"; then ok "skill: Skip-first, Skip-wins filing gate"; else bad "skill: Skip-first, Skip-wins filing gate"; fi
if grep -q 'only the accepted' "$S"; then ok "skill: only accepted groups reach /issue-maker"; else bad "skill: only accepted groups reach /issue-maker"; fi
if grep -q '/.claude/reports/markdown-audit' "$S"; then ok "skill: report stored outside the checkout"; else bad "skill: report stored outside the checkout"; fi
if grep -q 'never edits' "$S"; then ok "skill: read-only boundary stated"; else bad "skill: read-only boundary stated"; fi

echo
echo "markdown-audit: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
