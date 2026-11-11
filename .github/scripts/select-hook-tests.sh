#!/usr/bin/env bash
#
# Select the hook/script test suites a pull request can affect (issues #2153, #2177).
#
# Every PR used to run every discovered suite (40-80 minutes on the hosted runners).
# This selector reads a PR's changed paths and prints what the runners should run;
# run-hook-tests.sh and run-python-tests.sh take that answer through --only-file.
# Each hook-test job still starts and completes on every PR. Only the work inside it
# shrinks, and the job names never change, so the merge gate never waits on a check
# that will not arrive.
#
# Input:  changed paths, one per line, on stdin; or --base <sha> to diff
#         <sha>...HEAD in this repo.
# Output (stdout): one `# reason: ...` line, then EITHER the single line `ALL` OR one
#         suite path per line (bash *.test.sh suites and python tests/test_*.py
#         modules), then the terminator line `# end-of-selection`. A selection without
#         the terminator was cut short; the runners treat it as ALL. Other `#` lines
#         are ignored by the runners.
#
# Batch mode (--per-path): the same derivation, answered for every changed path in one
#         run. Output is one line per path: `<path><TAB>ALL<TAB><reason>` or
#         `<path><TAB><suite> <suite> ...` (empty when no suite depends on a docs path).
#         The under-selection sweep test uses it so the whole tree is checked in one pass.
#
# FAIL TOWARD ALL. The selector answers ALL, never a partial list, when:
#   - the event is not pull_request (a push to main is the full backstop run);
#   - the change list is empty or cannot be read (the --base diff fails);
#   - a changed path is neither a docs file nor a dependency of any suite (unmapped);
#   - a shared runner, the selector, the summarizer, a workflow file, or any */lib/*
#     helper changed;
#   - a suite's `# covers:` line names a path that does not exist (a broken mapping);
#   - suite discovery finds nothing, or a scan of the tree fails.
# The workflow also runs ALL when this script exits non-zero (hook-scripts.yml).
#
# How a suite depends on a changed path (derived first, declared second):
#   derived:  each repo path the suite text literally mentions under .claude/,
#             .github/, desk/ or tests/. A file mention matches that file. A
#             directory the suite names on disk also matches docs beneath it (a
#             lint that reads the rules directory). A directory it globs
#             (`.claude/scripts/*.sh`) matches docs beneath it too, but a code path
#             needs a literal or basename match: a glob alone is not proof the suite
#             checks a given file, so an unnamed code path fails toward ALL;
#   covers:   an optional `# covers: <path> <path> ...` line adds paths the text
#             cannot spell out (for example, paths assembled from variables);
#   self:     a suite always depends on its own file.
#
# DECLARED SUITES (issue #2177). A suite with a `# covers:` line depends on docs (*.md)
# ONLY through that line. Its prose mentions of markdown paths, markdown basenames, and
# directory names beneath which docs sit no longer select it. Its code dependencies
# (literal code paths, code basenames, covers, self) are derived exactly as before. An
# undeclared suite keeps today's derivation unchanged, so declaring one suite never
# loosens another. The declaration honesty test (select-hook-covers-honesty.test.sh)
# fails when a declared suite names a markdown file on a non-comment line without
# declaring it. The generic basenames README.md and SKILL.md name many files, so a declared
# suite that names one keeps today's derivation for it (fail toward running more), and the
# honesty test does not require declaring them.
#
# A basename mention is never coverage: a suite that names a code file's basename in
# unrelated text does not depend on that file. A code path with no derived, declared,
# or self match fails toward ALL.
#
# A basename mention is ADDITIVE for a code or docs path: every suite that names the file's
# basename as a whole token is selected too, even when another suite names the literal path
# (a constructed path like "$DIR/x.sh" would otherwise be skipped). It still adds nothing to
# coverage, so a code path with only basename mentions fails toward ALL.
#
# CALLERS (issue #2177). A non-suite code file that mentions a changed code path's basename
# makes that path a dependency of every suite (a hook sourcing a helper, a script invoking
# a script), so the path fails toward ALL. A mention counts as a caller unless the line is
# a comment (first non-blank character `#`) or the line sits inside a data-only heredoc
# (`cat <<'DELIM'` with a QUOTED delimiter, ending its line, with no pipe, redirect or other
# command, read to the matching DELIM line; an unquoted heredoc body is expanded, so it counts). Any other line, including a trailing comment after code, counts.
#
# Docs allow-list: a *.md file outside any tests/ or fixtures/ directory never forces
# ALL. A docs file still selects the undeclared suites that read it: literal path
# mentions (rules and references read as fixtures) AND every undeclared suite that names
# its basename as a whole token. A docs file no suite mentions selects nothing and does
# not force ALL.
#
# Python modules (tests/test_*.py) ALWAYS run in full, for every selection, including a
# docs-only change and an empty bash selection. They reach hooks through path construction
# the derivation cannot see, and the whole python run takes a few minutes, so selecting
# among them is not worth the risk.
#
# Usage:
#   select-hook-tests.sh [--event <name>] [--base <sha>] < changed-paths
#   select-hook-tests.sh --per-path < changed-paths
#   select-hook-tests.sh --help
#
# Exit codes: 0 a selection was printed in full (ALL or a list); 1 internal error or a
# failed write of the output (callers treat any non-zero exit as ALL); 2 usage error.
set -uo pipefail
shopt -s nullglob
export LC_ALL=C

END_MARK='# end-of-selection'
emit_all() {
  printf '# reason: %s\n' "$1" || exit 1
  printf 'ALL\n' || exit 1
  printf '%s\n' "$END_MARK" || exit 1
}

EVENT=""
BASE=""
BATCH=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --event)
      [ "$#" -ge 2 ] || { echo "::error::select-hook-tests.sh: --event needs a value" >&2; exit 2; }
      EVENT="$2"; shift 2 ;;
    --base)
      [ "$#" -ge 2 ] || { echo "::error::select-hook-tests.sh: --base needs a value" >&2; exit 2; }
      BASE="$2"; shift 2 ;;
    --per-path)
      BATCH=1; shift ;;
    -h|--help)
      awk 'NR == 1 { next } /^#/ { print; n = 1; next } { exit } END { exit(n ? 0 : 1) }' "$0" ||
        { printf '%s: --help header extraction produced no output\n' "$0" >&2; exit 70; }
      exit 0 ;;
    *)
      echo "::error::select-hook-tests.sh: unknown argument: $1" >&2
      exit 2 ;;
  esac
done

# Resolve to the repo root regardless of caller cwd, like the runners do.
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || { emit_all "cannot cd to repo root: full run"; exit 1; }

if [ "$BATCH" -eq 0 ] && [ -n "$EVENT" ] && [ "$EVENT" != "pull_request" ]; then
  emit_all "event '$EVENT' is not pull_request: full run"
  exit 0
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/select-hook-tests-XXXXXX")" || { emit_all "mktemp failed: full run"; exit 1; }
trap 'rm -rf "$TMP"' EXIT

# A whole-run failure: single mode answers ALL, batch mode exits non-zero (the sweep fails).
run_fail() {
  if [ "$BATCH" -eq 1 ]; then
    printf 'select-hook-tests.sh: %s\n' "$1" >&2
    exit 1
  fi
  emit_all "$1"
  exit 0
}

is_shared() {
  case "$1" in
    .github/scripts/run-hook-tests.sh|.github/scripts/run-python-tests.sh) return 0 ;;
    .github/scripts/summarize-test-run.sh|.github/scripts/select-hook-tests.sh) return 0 ;;
    .github/workflows/*) return 0 ;;
    */lib/*|lib/*) return 0 ;;
  esac
  return 1
}

is_docs() {
  case "$1" in
    */tests/*|tests/*|*/fixtures/*|fixtures/*) return 1 ;;
  esac
  case "$1" in
    *.md) return 0 ;;
  esac
  return 1
}

CHANGED="$TMP/changed"
if [ -n "$BASE" ]; then
  git diff --name-only --no-renames "$BASE...HEAD" > "$CHANGED" 2>/dev/null || run_fail "git diff $BASE...HEAD failed: full run"
else
  cat > "$CHANGED" || run_fail "could not read changed paths: full run"
fi
sed '/^[[:space:]]*$/d' "$CHANGED" > "$CHANGED.n" || run_fail "could not normalize changed paths: full run"
mv "$CHANGED.n" "$CHANGED" || run_fail "could not normalize changed paths: full run"

if [ ! -s "$CHANGED" ]; then
  run_fail "no changed paths: full run (an empty diff is never trusted to skip work)"
fi

# Discovery: the same globs run-hook-tests.sh and run-python-tests.sh use.
DISC="$TMP/discovered"
{
  for f in .claude/hooks/tests/*.test.sh .claude/scripts/tests/*.test.sh \
           .github/scripts/tests/*.test.sh desk/tests/*.test.sh tests/test_*.py; do
    printf '%s\n' "$f"
  done
} > "$DISC"
if [ ! -s "$DISC" ]; then
  run_fail "no suites discovered: full run"
fi

# Shared runner, selector, summarizer, workflow, or helper changes select everything.
TRIG=""
while IFS= read -r P; do
  if is_shared "$P"; then TRIG="$P"; break; fi
done < "$CHANGED"
if [ -n "$TRIG" ] && [ "$BATCH" -eq 0 ]; then
  emit_all "shared runner, selector, workflow, or helper changed: $TRIG"
  exit 0
fi

# Derived and declared dependencies: one "suite<TAB>path<TAB>mode" line per pair.
#   F  a file the suite names (matches that exact path only)
#   D  a directory the suite names on disk (also matches docs beneath it)
#   G  a directory the suite globs, e.g. .claude/scripts/*.sh (matches everything beneath it)
# Declared suites keep their derived code pairs only (see the header); their covers pairs
# go to COVP with the same modes.
PAIRS="$TMP/pairs"
COVP="$TMP/covers-pairs"
BAD="$TMP/bad-covers"
DECLARED="$TMP/declared"
: > "$PAIRS"
: > "$COVP"
: > "$BAD"
: > "$DECLARED"
while IFS= read -r S; do
  SP="$TMP/suite-pairs"
  : > "$SP"
  DECL=0
  if grep -q '^# covers:' "$S" 2>/dev/null; then DECL=1; printf '%s\n' "$S" >> "$DECLARED" || run_fail "could not record declarations: full run"; fi
  grep -oE '(\.claude|\.github|desk|tests)/[[:alnum:]_./-]*\*' "$S" 2>/dev/null \
    | sed 's#\*$##; s#[./]*$##' \
    | awk -v s="$S" 'length($0) > 0 { printf "%s\t%s\tG\n", s, $0 }' >> "$SP"
  grep -oE '(\.claude|\.github|desk|tests)/[[:alnum:]_./-]+' "$S" 2>/dev/null \
    | sed 's#[./]*$##' \
    | while IFS= read -r tok; do
        [ -n "$tok" ] || continue
        if [ -d "$tok" ]; then m=D; else m=F; fi
        printf '%s\t%s\t%s\n' "$S" "$tok" "$m" >> "$SP"
      done
  if [ "$DECL" -eq 1 ]; then
    # Declared: drop docs-only derivations (directory and glob matches, markdown file mentions).
    awk -F'\t' -v OFS='\t' '!($3 == "G" || $3 == "D" || $2 ~ /\.md$/)' "$SP" >> "$PAIRS"
  else
    cat "$SP" >> "$PAIRS"
  fi
  sed -n 's/^# covers:[[:space:]]*//p' "$S" 2>/dev/null | awk '{ for (i = 1; i <= NF; i++) print $i }' | while IFS= read -r tok; do
    [ -n "$tok" ] || continue
    if [ -d "$tok" ]; then
      printf '%s\t%s\tD\n' "$S" "$tok" >> "$COVP"
    elif [ -e "$tok" ]; then
      printf '%s\t%s\tF\n' "$S" "$tok" >> "$COVP"
    else
      printf '%s -> %s\n' "$S" "$tok" >> "$BAD"
    fi
  done
done < "$DISC"
if [ -s "$BAD" ]; then
  emit_all "suite covers a path that does not exist (broken mapping): $(head -n 1 "$BAD")"
  exit 0
fi

# Basename-token index, built once: every whole token of every suite, one "suite<TAB>token"
# line each. A token is a maximal run of name characters with at most one trailing dot removed,
# which is exactly the whole-token rule (the character before and after a basename is not a
# name character; a dot may follow only as the last character of the token).
TOKIDX="$TMP/tokens"
xargs grep -HoE '[[:alnum:]_.-]+' < "$DISC" > "$TMP/tok-raw" 2>/dev/null
RC=$?
[ "$RC" -le 1 ] || run_fail "basename scan of the suites failed: full run"
awk -F: '{
    s = $1
    t = substr($0, length(s) + 2)
    if (substr(t, length(t), 1) == ".") t = substr(t, 1, length(t) - 1)
    if (t != "") printf "%s\t%s\n", s, t
  }' "$TMP/tok-raw" > "$TOKIDX" || run_fail "could not index tokens: full run"

# Basename maps, built once for every changed path. BMAP is "basename<TAB>suite" for each suite
# that names the basename as a whole token (any line). It is one pass over the token index.
ABN="$TMP/all-basenames"
BMAP="$TMP/basename-map"
awk -F/ '{ print $NF }' "$CHANGED" | LC_ALL=C sort -u > "$ABN" || run_fail "could not record basenames: full run"
awk -F'\t' -v bf="$ABN" 'FILENAME == bf { want[$0] = 1; next } ($2 in want) { printf "%s\t%s\n", $2, $1 }' \
  "$ABN" "$TOKIDX" | LC_ALL=C sort -u > "$BMAP" || run_fail "could not build basename map: full run"

# Caller index, built once for every changed code path that is not itself a suite. Two passes:
# grep finds the lines that mention a changed basename anywhere in the tree (substring, as before);
# awk then reads each candidate file whole, so a data-only heredoc is tracked from its opening
# line, and keeps a hit only when that line is code (not a comment, not inside a heredoc). Docs
# and JSON never execute, so they are never callers. The index is "basename<TAB>file".
CBN="$TMP/caller-basenames"
CALLIDX="$TMP/callers"
CALLER_FAIL=0
: > "$CBN"
: > "$CALLIDX"
while IFS= read -r P; do
  if is_docs "$P" || grep -Fxq -- "$P" "$DISC"; then continue; fi
  printf '%s\n' "${P##*/}" >> "$CBN"
done < "$CHANGED"
if [ -s "$CBN" ]; then
  sort -u "$CBN" > "$CBN.u" && mv "$CBN.u" "$CBN" || run_fail "could not record caller basenames: full run"
  grep -rIn -F -f "$CBN" --exclude-dir=.git --exclude-dir=worktrees --exclude-dir=node_modules . > "$TMP/caller-hits" 2>/dev/null
  CRC=$?
  if [ "$CRC" -gt 1 ]; then
    CALLER_FAIL=1
  elif [ "$CRC" -eq 0 ]; then
    awk -F: '{ print $1 }' "$TMP/caller-hits" | LC_ALL=C sort -u > "$TMP/cand-files" || run_fail "could not list candidates: full run"
    awk -v bf="$CBN" -v hf="$TMP/caller-hits" -v lf="$TMP/cand-files" '
      BEGIN {
        n = 0
        while ((getline b < bf) > 0) { if (b != "") bn[++n] = b }
        while ((getline h < hf) > 0) {
          p = index(h, ":")
          rest = substr(h, p + 1)
          q = index(rest, ":")
          hit[substr(h, 1, p - 1) SUBSEP substr(rest, 1, q - 1)] = 1
        }
        while ((getline fn < lf) > 0) {
          f = fn
          sub(/^\.\//, "", f)
          if (f ~ /\.(md|json)$/) continue
          heredoc = ""
          ln = 0
          while ((getline content < fn) > 0) {
            ln++
            if (heredoc != "") {
              c = content
              sub(/^[[:space:]]*/, "", c)
              if (c == heredoc) heredoc = ""
              continue
            }
            if (content ~ /^[[:space:]]*#/) continue
            if (content ~ /(^|[ \t;&(])cat[ \t]+<<-?[\047\042][A-Za-z_][A-Za-z_0-9]*[\047\042][ \t]*$/) {
              d = content
              sub(/[ \t]*$/, "", d)
              sub(/.*<<-?/, "", d)
              gsub(/[\047\042]/, "", d)
              heredoc = d
            }
            if (!((fn SUBSEP ln) in hit)) continue
            for (i = 1; i <= n; i++) if (index(content, bn[i]) > 0) printf "%s\t%s\n", bn[i], f
          }
          close(fn)
        }
      }' /dev/null > "$CALLIDX" || run_fail "caller index failed: full run"
  fi
fi

# Per-path derivation. Sets RES_ALL to a reason when the path fails toward ALL, otherwise
# writes the selected suites to "$TMP/res". Returns non-zero only on a failed write.
resolve_path() {
  local P="$1" base DOC H B CALLER
  RES_ALL=""
  base="${P##*/}"
  : > "$TMP/res" || return 1
  if is_shared "$P"; then RES_ALL="shared runner, selector, workflow, or helper changed: $P"; return 0; fi
  DOC=0
  if is_docs "$P"; then DOC=1; fi
  H="$TMP/hit"
  : > "$H" || return 1
  awk -F'\t' -v p="$P" -v d="$DOC" '
    length($2) > 0 && ($2 == p || (d == 1 && index(p, $2 "/") == 1 && ($3 == "G" || $3 == "D"))) { print $1 }
  ' "$PAIRS" "$COVP" >> "$H" || return 1
  # A suite always depends on its own file.
  if grep -Fxq -- "$P" "$DISC"; then
    printf '%s\n' "$P" >> "$H" || return 1
  fi
  # Transitive dependencies (fail toward ALL): a non-suite code file that mentions the path
  # (a hook sourcing a helper, a script invoking a script) can carry the path into suites that
  # never name it. Docs and JSON execute nothing and are ignored.
  if [ "$DOC" -eq 0 ] && ! grep -Fxq -- "$P" "$DISC"; then
    if [ "$CALLER_FAIL" -eq 1 ]; then RES_ALL="$P (caller scan failed)"; return 0; fi
    awk -F'\t' -v b="$base" '$1 == b { print $2 }' "$CALLIDX" | sort -u > "$TMP/callers-for-path" || return 1
    CALLER=""
    while IFS= read -r C; do
      [ "$C" = "$P" ] && continue
      grep -Fxq -- "$C" "$DISC" && continue
      CALLER="$C"
      break
    done < "$TMP/callers-for-path"
    if [ -n "$CALLER" ]; then RES_ALL="$P (called by $CALLER)"; return 0; fi
  fi
  if [ "$DOC" -eq 0 ] && [ ! -s "$H" ]; then RES_ALL="$P"; return 0; fi
  # Basename mentions are ADDITIVE (see the header). A declared suite is not selected by a
  # docs basename mention, so a docs path skips declared suites here.
  B="$TMP/bhit"
  awk -F'\t' -v b="$base" '$1 == b { print $2 }' "$BMAP" | sort -u > "$B" || return 1
  # Generic basenames (README.md, SKILL.md) name many files, and a constructed path to them is
  # indistinguishable from a prose mention, so they keep the undeclared derivation everywhere.
  case "$base" in
    README.md|SKILL.md) GENERIC=1 ;;
    *) GENERIC=0 ;;
  esac
  if [ "$DOC" -eq 1 ] && [ "$GENERIC" -eq 0 ] && [ -s "$DECLARED" ]; then
    awk 'NR == FNR { d[$0] = 1; next } !($0 in d)' "$DECLARED" "$B" > "$B.u" || return 1
    mv "$B.u" "$B" || return 1
  fi
  cat "$H" "$B" | sort -u >> "$TMP/res" || return 1
  return 0
}

if [ "$BATCH" -eq 1 ]; then
  OUT="$TMP/batch-out"
  : > "$OUT"
  while IFS= read -r P; do
    resolve_path "$P" || run_fail "could not resolve $P"
    if [ -n "$RES_ALL" ]; then
      printf '%s\tALL\t%s\n' "$P" "$RES_ALL" >> "$OUT" || exit 1
    else
      printf '%s\t%s\n' "$P" "$(tr '\n' ' ' < "$TMP/res" | sed 's/ *$//')" >> "$OUT" || exit 1
    fi
  done < "$CHANGED"
  cat "$OUT" || exit 1
  exit 0
fi

SEL="$TMP/selected"
: > "$SEL"
NCHANGED=0
while IFS= read -r P; do
  NCHANGED=$((NCHANGED + 1))
  resolve_path "$P" || { emit_all "could not record selection: full run"; exit 1; }
  if [ -n "$RES_ALL" ]; then
    emit_all "no suite depends on changed path $RES_ALL: full run"
    exit 0
  fi
  cat "$TMP/res" >> "$SEL" || { emit_all "could not record selection: full run"; exit 1; }
done < "$CHANGED"

# Python modules run in full for every selection, docs-only and empty bash selections included
# (see header). Listing them keeps the one-line-per-suite shape the runners already read.
grep -E '^tests/test_.*\.py$' "$DISC" >> "$SEL" || { emit_all "could not record selection: full run"; exit 1; }

SORTED="$(LC_ALL=C sort -u "$SEL" | sed '/^$/d')" || { emit_all "sort failed: full run"; exit 1; }
NSEL=0
if [ -n "$SORTED" ]; then
  NSEL="$(printf '%s\n' "$SORTED" | awk 'END { print NR }')"
fi
printf '# reason: %s changed path(s), %s suite(s) selected\n' "$NCHANGED" "$NSEL" || exit 1
if [ -n "$SORTED" ]; then
  printf '%s\n' "$SORTED" || exit 1
fi
printf '%s\n' "$END_MARK" || exit 1
exit 0
