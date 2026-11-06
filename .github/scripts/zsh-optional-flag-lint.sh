#!/usr/bin/env bash
# doc-lint: reject zsh-unsafe optional-flag argv in published skill shell blocks
# (issue #1857).
#
# === The defect this exists to prevent ===
#
# Skill snippets run in the session's Bash tool, which on macOS is zsh. zsh
# does not word-split an unquoted expansion, so the bash idiom that adds an
# optional flag only when its variable is set,
#
#     helper ${REPO:+--repo "$REPO"}
#
# reaches the helper as ONE argument, `--repo owner/name`, under zsh (two under
# bash). Every helper rejects that as an unknown option. The same holds for a
# flag string kept in a scalar and expanded bare:
#
#     REPO_FLAG="--repo $REPO"; gh pr view 1 $REPO_FLAG
#
# Fix shape: build an argument array and expand it with the bash-3.2-safe
# `${ARR[@]+"${ARR[@]}"}` (or a quoted `"${ARR[@]}"` where the array is never
# empty under `set -u`).
#
# === What is flagged (fenced shell blocks only) ===
#
#   1. An UNQUOTED `${NAME:+WORD}` / `${NAME+WORD}` whose WORD — after peeling
#      nested `${OTHER:+` prefixes and an opening quote — starts with `-` and
#      contains unquoted whitespace. Nested form included:
#      `${A:+${B:+--flag "$B"}}`. A WORD that continues onto the next line is
#      judged on its first-line part (the unquoted newline counts as
#      whitespace).
#   2. An UNQUOTED scalar `$NAME` / `${NAME}` whose most recent earlier
#      assignment in the same file was a multi-word flag string
#      (`NAME="--repo $X"`); a later single-word reassignment clears it. Array
#      expansions and subscripts are untouched.
#
# NOT flagged: a single-word expansion (`${ALL_REPOS:+--all-repos}`), any
# expansion inside a double-quoted string (`"${X:+ in $X}"` is one word in
# both shells), comments, and heredoc bodies. Quote state is tracked across
# lines and through `$( … )`; a line-level regex cannot see quoting, so the
# scanner prefers a miss over a false positive.
#
# === Scan scope ===
#
#   .claude/skills/*/SKILL.md, references/*.md and modules/**/*.md
#   .claude/agents/*.md
#
# The bash helper scripts under .claude/scripts/ use the same idiom correctly:
# they run under bash through their shebang. They are deliberately out of scope.
#
# === Opt-out marker ===
#
#   # zsh-optional-flag-ok      (same line; for a block that SHOWS the bad form)
#
# === Canaries ===
#
# A missing surface exits 3; a scan that enters zero shell fences exits 1 —
# never a vacuous green.
#
# CI wiring: named .github/scripts/*-lint.sh, so run-doc-lints.sh discovers it
# with no workflow edit. Companion: .github/scripts/tests/zsh-optional-flag-lint.test.sh
#
# Usage: bash .github/scripts/zsh-optional-flag-lint.sh [--help]
# Run from the repo root (discovery is relative to the current directory).
# Exits 0 clean, 1 on any finding or canary, 2 on a usage error, 3 when a
# guarded surface is missing from disk.

set -uo pipefail

usage() {
  cat <<'EOF'
Usage: bash .github/scripts/zsh-optional-flag-lint.sh [--help]

  Scans the fenced shell blocks of published skills and agent definitions for
  optional-flag argv built as ${VAR:+--flag "$VAR"} or a bare $X_FLAG scalar,
  which zsh passes as ONE argument (issue #1857). Use an argument array.

  Run from the repo root. Suppress one deliberate line with a trailing
  # zsh-optional-flag-ok marker.

  Exit status: 0 clean, 1 finding or canary, 2 usage error, 3 surface missing.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    *) echo "::error::zsh-optional-flag-lint.sh: unknown argument: $1"; usage; exit 2 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=.github/scripts/lib/lint-common.sh
source "${SCRIPT_DIR}/lib/lint-common.sh"

FILES=()
SKILLS=()
while IFS= read -r skill; do
  SKILLS+=("$skill")
done < <(published_skills . || true)

if [ "${#SKILLS[@]}" -eq 0 ]; then
  echo "::error::zsh-optional-flag-lint: .claude/skills/ contains no published skill directories"
  exit 3
fi

missing=0
for skill in "${SKILLS[@]}"; do
  f=".claude/skills/${skill}/SKILL.md"
  if [ ! -f "$f" ]; then
    echo "::error::zsh-optional-flag-lint: guarded surface missing from disk: $f"
    missing=$((missing + 1))
    continue
  fi
  FILES+=("$f")
  for sub in references modules; do
    [ -d ".claude/skills/${skill}/${sub}" ] || continue
    while IFS= read -r ref; do
      FILES+=("$ref")
    done < <(find ".claude/skills/${skill}/${sub}" -type f -name '*.md' | LC_ALL=C sort)
  done
done

if [ -d .claude/agents ]; then
  agent_count=0
  while IFS= read -r agent; do
    FILES+=("$agent"); agent_count=$((agent_count + 1))
  done < <(find .claude/agents -name '*.md' | LC_ALL=C sort)
  if [ "$agent_count" -eq 0 ]; then
    echo "::error::zsh-optional-flag-lint: .claude/agents/ exists but contains no *.md"
    missing=$((missing + 1))
  fi
else
  echo "::error::zsh-optional-flag-lint: guarded surface missing from disk: .claude/agents/"
  missing=$((missing + 1))
fi

[ "$missing" -eq 0 ] || exit 3

SCAN_OUT="$(mktemp)"
trap 'rm -f "$SCAN_OUT"' EXIT

# One FINDING line per hit (file, line, kind, text) plus a FENCES total.
# Quote state: 0 = unquoted, 1 = single, 2 = double. `$(` pushes the current
# state and starts unquoted; its matching `)` pops it.
scan_awk='
function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }

function finding(kind, text) {
  if (ok_line) return
  printf "FINDING\t%s\t%d\t%s\t%s\n", FILENAME, FNR, kind, text
}

# Starting at index i (just past "${NAME:+"), return the index of the closing
# brace of this expansion, or 0 if it does not close on this line. Sets
# W_SPACE when the word holds whitespace outside inner quotes. On a 0 return,
# W_OPEN is 1 when the line ends unquoted and unescaped, so the newline is
# itself unquoted whitespace inside the word.
function word_end(s, i,   depth, q, c, n, esc) {
  depth = 1; q = 0; W_SPACE = 0; W_OPEN = 0; esc = 0; n = length(s)
  for (; i <= n; i++) {
    c = substr(s, i, 1)
    if (q == 1) { if (c == "\047") q = 0; continue }
    if (c == "\\") { if (i == n) esc = 1; i++; continue }
    if (q == 2) { if (c == "\"") q = 0; continue }
    if (c == "\047") { q = 1; continue }
    if (c == "\"") { q = 2; continue }
    if (c == "$" && substr(s, i + 1, 1) == "{") { depth++; i++; continue }
    if (c == "}") { depth--; if (depth == 0) return i; continue }
    if (c ~ /[ \t]/) W_SPACE = 1
  }
  W_OPEN = (q == 0 && !esc)
  return 0
}

# The flag word of an expansion: strip nested ${OTHER:+ prefixes and one
# opening quote, so `${A:+${B:+"--flag ..."` reads as `--flag ...`.
function peel(word,   p) {
  p = word
  while (match(p, /^\$\{[A-Za-z_][A-Za-z0-9_]*:?\+/)) p = substr(p, RLENGTH + 1)
  sub(/^["\047]/, "", p)
  return p
}

function scan_line(s,   n, i, c, rest, m, name, cl, word, peeled) {
  n = length(s)
  for (i = 1; i <= n; i++) {
    c = substr(s, i, 1)
    if (st == 1) { if (c == "\047") st = 0; continue }
    if (c == "\\") { i++; continue }
    if (st == 2) {
      if (c == "\"") { st = 0; continue }
      if (c == "$" && substr(s, i + 1, 1) == "(") { stack[++sp] = 2; st = 0; i++ }
      continue
    }
    # unquoted
    if (c == "#" && (i == 1 || substr(s, i - 1, 1) ~ /[ \t;(]/)) return
    if (c == "\047") { st = 1; continue }
    if (c == "\"") { st = 2; continue }
    if (c == "(") { if (substr(s, i - 1, 1) == "$") { stack[++sp] = 0 } else { pdepth[sp]++ } ; continue }
    if (c == ")") {
      if (pdepth[sp] > 0) { pdepth[sp]--; continue }
      if (sp > 0) { st = stack[sp]; delete pdepth[sp]; sp--; }
      continue
    }
    if (c != "$") continue
    rest = substr(s, i)
    # Shape 1: ${NAME:+WORD} / ${NAME+WORD}
    if (match(rest, /^\$\{[A-Za-z_][A-Za-z0-9_]*:?\+/)) {
      cl = word_end(s, i + RLENGTH)
      if (cl == 0) {
        # The expansion continues onto the next line. Its first-line part is
        # still judged: a flag word followed by whitespace or an unquoted
        # newline is the same unsafe shape. Report once per line (an inner
        # nested opener would otherwise repeat the finding).
        peeled = peel(substr(s, i + RLENGTH))
        if ((W_SPACE || W_OPEN) && peeled ~ /^-/ && open_fnr != FNR) {
          open_fnr = FNR
          finding("optional-flag", substr(s, i))
        }
        continue
      }
      word = substr(s, i + RLENGTH, cl - i - RLENGTH)
      peeled = peel(word)
      if (W_SPACE && peeled ~ /^-/) finding("optional-flag", substr(s, i, cl - i + 1))
      i = cl
      continue
    }
    # Shape 2: a bare $NAME / ${NAME} whose earlier assignment in this file held
    # a multi-word flag string (NAME="--repo $X"). Arrays and subscripts excluded.
    if (match(rest, /^\$\{?[A-Za-z_][A-Za-z0-9_]*\}?/)) {
      m = substr(rest, 1, RLENGTH)
      if (substr(m, 2, 1) == "{" && substr(m, length(m), 1) != "}") continue
      if (substr(m, 2, 1) != "{" && substr(m, length(m), 1) == "}") m = substr(m, 1, length(m) - 1)
      name = m; gsub(/[${}]/, "", name)
      if ((name in flagvars) && substr(rest, length(m) + 1, 1) !~ /[A-Za-z0-9_\[]/) finding("flag-string", m)
      i += length(m) - 1
    }
  }
}

BEGIN { fences = 0 }

FNR == 1 { in_fence = 0; shellish = 0; st = 0; sp = 0; heredoc = ""; open_fnr = 0; split("", flagvars) }

{
  line = $0
  if (match(line, /^[ \t]*(```+|~~~+)/)) {
    marker = substr(line, RSTART, RLENGTH); sub(/^[[:space:]]+/, "", marker)
    tok = substr(marker, 1, 1); len = length(marker)
    rest = trim(substr(line, RSTART + RLENGTH))
    if (!in_fence) {
      in_fence = 1; fence_tok = tok; fence_len = len
      info = tolower(rest); sub(/[[:space:]].*$/, "", info)
      sub(/^\{+/, "", info); sub(/\}+$/, "", info); sub(/^\.+/, "", info)
      shellish = (info == "" || info ~ /^(bash|sh|shell|zsh|console|shellsession)$/)
      if (shellish) fences++
      st = 0; sp = 0; heredoc = ""
      next
    } else if (tok == fence_tok && len >= fence_len && rest == "") {
      in_fence = 0; shellish = 0; st = 0; sp = 0; heredoc = ""
      next
    }
  }
  if (!in_fence || !shellish) next
  if (heredoc != "") { if (trim(line) == heredoc) heredoc = ""; next }
  ok_line = (line ~ /zsh-optional-flag-ok/)
  # Track scalar assignments in order: NAME="-x value" (a multi-word flag
  # string) marks NAME; any other assignment to NAME clears the mark, so a
  # later safe reassignment is not reported. A comment line is not an
  # assignment.
  if (st == 0 && line !~ /^[ \t]*#/) {
    probe = line
    while (match(probe, /(^|[ \t;&|(])[A-Za-z_][A-Za-z0-9_]*=/)) {
      a = substr(probe, RSTART, RLENGTH); sub(/^[ \t;&|(]/, "", a); sub(/=$/, "", a)
      probe = substr(probe, RSTART + RLENGTH)
      if (match(probe, /^["\047]-[^"\047]*[ \t][^"\047]*["\047]/)) flagvars[a] = 1
      else delete flagvars[a]
    }
  }
  scan_line(line)
  # A heredoc opener (outside quotes at end of line) skips its body.
  # A here-string (<<<) is not a heredoc, so a "<<" touching another "<" is skipped.
  if (st == 0 && line !~ /^[ \t]*#/) {
    probe = line; off = 0
    while (match(probe, /<<-?[ \t]*["\047]?[A-Za-z_][A-Za-z0-9_]*["\047]?/)) {
      if (substr(line, off + RSTART - 1, 1) != "<" && substr(probe, RSTART + 2, 1) != "<") {
        h = substr(probe, RSTART, RLENGTH); sub(/^<<-?[ \t]*["\047]?/, "", h); sub(/["\047]$/, "", h)
        heredoc = h
        break
      }
      off += RSTART + 1; probe = substr(probe, RSTART + 2)
    }
  }
}

END { printf "FENCES\t%d\n", fences }
'

if ! awk "$scan_awk" ${FILES[@]+"${FILES[@]}"} > "$SCAN_OUT"; then
  echo "::error::zsh-optional-flag-lint: the Markdown scan failed — treating as an error rather than a clean pass"
  exit 1
fi

fences="$(awk -F'\t' '$1 == "FENCES" { t += $2 } END { print t + 0 }' "$SCAN_OUT")"
errors=0
while IFS="$(printf '\t')" read -r kind file lineno what text; do
  [ "$kind" = "FINDING" ] || continue
  case "$what" in
    optional-flag) detail="zsh passes an unquoted '\${VAR:+--flag \"\$VAR\"}' to the command as ONE argument ('--flag value'), so the helper rejects it as an unknown option. Build an argument array and expand it as \${ARR[@]+\"\${ARR[@]}\"}" ;;
    *) detail="a flag string kept in a scalar and expanded bare is ONE argument under zsh. Store it in an array (ARGS=(--repo \"\$X\")) and expand it as \${ARGS[@]+\"\${ARGS[@]}\"}" ;;
  esac
  echo "::error file=${file},line=${lineno}::${file}:${lineno}: ${text} — ${detail} (issue #1857)."
  errors=$((errors + 1))
done < "$SCAN_OUT"

if [ "$fences" -eq 0 ]; then
  echo "::error::zsh-optional-flag-lint: scanned ${#FILES[@]} file(s) but entered 0 shell fences — refusing to report a vacuous pass"
  exit 1
fi

if [ "$errors" -gt 0 ]; then
  echo "zsh-optional-flag-lint: ${errors} error(s) across ${#FILES[@]} files (${fences} shell fences scanned)"
  exit 1
fi

echo "zsh-optional-flag-lint: OK (${#FILES[@]} files, ${fences} shell fences scanned)"
