#!/usr/bin/env bash
#
# Select the hook/script test suites a pull request can affect (issue #2153).
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
#         modules). The runners ignore `#` lines.
#
# FAIL TOWARD ALL. The selector answers ALL, never a partial list, when:
#   - the event is not pull_request (a push to main is the full backstop run);
#   - the change list is empty or cannot be read (the --base diff fails);
#   - a changed path is neither a docs file nor a dependency of any suite (unmapped);
#   - a shared runner, the selector, the summarizer, a workflow file, or any */lib/*
#     helper changed;
#   - a suite's `# covers:` line names a path that does not exist (a broken mapping);
#   - suite discovery finds nothing.
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
#   basename: a changed file also matches a suite whose text contains that file's
#             basename. This over-selects rather than under-selects, and catches
#             paths built at runtime;
#   self:     a suite always depends on its own file.
# A new suite needs no registration: its literal path mentions are its dependencies.
# If it reads a file only through a constructed path, add a `# covers:` line for it.
#
# Docs allow-list: a *.md file outside any tests/ or fixtures/ directory never forces
# ALL. Rules and references still select the suites that read them as fixtures,
# because the derivation above applies to them too.
#
# Python modules (tests/test_*.py) run in full whenever any non-docs path changes:
# they reach hooks through path construction the derivation cannot see, and the
# whole python run is short. A docs-only change selects only the modules that
# mention the changed path.
#
# Usage:
#   select-hook-tests.sh [--event <name>] [--base <sha>] < changed-paths
#   select-hook-tests.sh --help
#
# Exit codes: 0 a selection was printed (ALL or a list); 1 internal error (callers
# treat any non-zero exit as ALL); 2 usage error.
set -uo pipefail
shopt -s nullglob

emit_all() {
  printf '# reason: %s\n' "$1"
  printf 'ALL\n'
}

EVENT=""
BASE=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --event)
      [ "$#" -ge 2 ] || { echo "::error::select-hook-tests.sh: --event needs a value" >&2; exit 2; }
      EVENT="$2"; shift 2 ;;
    --base)
      [ "$#" -ge 2 ] || { echo "::error::select-hook-tests.sh: --base needs a value" >&2; exit 2; }
      BASE="$2"; shift 2 ;;
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

if [ -n "$EVENT" ] && [ "$EVENT" != "pull_request" ]; then
  emit_all "event '$EVENT' is not pull_request: full run"
  exit 0
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/select-hook-tests-XXXXXX")" || { emit_all "mktemp failed: full run"; exit 1; }
trap 'rm -rf "$TMP"' EXIT

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
  git diff --name-only --no-renames "$BASE...HEAD" > "$CHANGED" 2>/dev/null || { emit_all "git diff $BASE...HEAD failed: full run"; exit 0; }
else
  cat > "$CHANGED" || { emit_all "could not read changed paths: full run"; exit 0; }
fi
sed '/^[[:space:]]*$/d' "$CHANGED" > "$CHANGED.n" || { emit_all "could not normalize changed paths: full run"; exit 0; }
mv "$CHANGED.n" "$CHANGED" || { emit_all "could not normalize changed paths: full run"; exit 0; }

if [ ! -s "$CHANGED" ]; then
  emit_all "no changed paths: full run (an empty diff is never trusted to skip work)"
  exit 0
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
  emit_all "no suites discovered: full run"
  exit 0
fi

# Shared runner, selector, summarizer, workflow, or helper changes select everything.
TRIG=""
while IFS= read -r P; do
  if is_shared "$P"; then TRIG="$P"; break; fi
done < "$CHANGED"
if [ -n "$TRIG" ]; then
  emit_all "shared runner, selector, workflow, or helper changed: $TRIG"
  exit 0
fi

# Derived and declared dependencies: one "suite<TAB>path<TAB>mode" line per pair.
#   F  a file the suite names (matches that exact path only)
#   D  a directory the suite names on disk (also matches docs beneath it)
#   G  a directory the suite globs, e.g. .claude/scripts/*.sh (matches everything beneath it)
PAIRS="$TMP/pairs"
BAD="$TMP/bad-covers"
: > "$PAIRS"
: > "$BAD"
while IFS= read -r S; do
  grep -oE '(\.claude|\.github|desk|tests)/[[:alnum:]_./-]*\*' "$S" 2>/dev/null \
    | sed 's#\*$##; s#[./]*$##' \
    | awk -v s="$S" 'length($0) > 0 { printf "%s\t%s\tG\n", s, $0 }' >> "$PAIRS"
  grep -oE '(\.claude|\.github|desk|tests)/[[:alnum:]_./-]+' "$S" 2>/dev/null \
    | sed 's#[./]*$##' \
    | while IFS= read -r tok; do
        [ -n "$tok" ] || continue
        if [ -d "$tok" ]; then m=D; else m=F; fi
        printf '%s\t%s\t%s\n' "$S" "$tok" "$m" >> "$PAIRS"
      done
  sed -n 's/^# covers:[[:space:]]*//p' "$S" 2>/dev/null | tr ' \t' '\n\n' | while IFS= read -r tok; do
    [ -n "$tok" ] || continue
    if [ -d "$tok" ]; then
      printf '%s\t%s\tD\n' "$S" "$tok" >> "$PAIRS"
    elif [ -e "$tok" ]; then
      printf '%s\t%s\tF\n' "$S" "$tok" >> "$PAIRS"
    else
      printf '%s -> %s\n' "$S" "$tok" >> "$BAD"
    fi
  done
done < "$DISC"
if [ -s "$BAD" ]; then
  emit_all "suite covers a path that does not exist (broken mapping): $(head -n 1 "$BAD")"
  exit 0
fi

SEL="$TMP/selected"
HIT="$TMP/hit"
CALLERS="$TMP/callers"
: > "$SEL"
HAS_CODE=0
UNMAPPED=""
NCHANGED=0
while IFS= read -r P; do
  NCHANGED=$((NCHANGED + 1))
  DOC=0
  if is_docs "$P"; then DOC=1; else HAS_CODE=1; fi
  : > "$HIT"
  awk -F'\t' -v p="$P" -v d="$DOC" '
    length($2) > 0 && ($2 == p || (d == 1 && index(p, $2 "/") == 1 && ($3 == "G" || $3 == "D"))) { print $1 }
  ' "$PAIRS" >> "$HIT"
  base="${P##*/}"
  while IFS= read -r S; do
    if [ "$S" = "$P" ]; then
      printf '%s\n' "$S" >> "$HIT"
    elif [ "$DOC" -eq 0 ] && grep -Fq -- "$base" "$S" 2>/dev/null; then
      printf '%s\n' "$S" >> "$HIT"
    fi
  done < "$DISC"
  # Transitive dependencies (fail toward ALL). A suite names only what its own text names,
  # so a non-suite code file that mentions this path (a hook sourcing a helper, a script
  # invoking a script) can carry the path into suites that never name it. Any such caller
  # forces ALL, even when some suite already names the path. Docs and JSON execute nothing
  # and are ignored. A failed scan forces ALL too.
  if [ "$DOC" -eq 0 ] && ! grep -Fxq -- "$P" "$DISC"; then
    grep -rIlF --exclude-dir=.git --exclude-dir=worktrees --exclude-dir=node_modules -- "$base" . > "$CALLERS" 2>/dev/null
    CALL_RC=$?
    if [ "$CALL_RC" -gt 1 ]; then
      UNMAPPED="$P (caller scan failed)"
      break
    fi
    CALLER=""
    while IFS= read -r C; do
      C="${C#./}"
      case "$C" in *.md|*.json) continue ;; esac
      [ "$C" = "$P" ] && continue
      grep -Fxq -- "$C" "$DISC" && continue
      CALLER="$C"
      break
    done < "$CALLERS"
    if [ -n "$CALLER" ]; then
      UNMAPPED="$P (called by $CALLER)"
      break
    fi
  fi
  if [ "$DOC" -eq 0 ] && [ ! -s "$HIT" ]; then
    UNMAPPED="$P"
    break
  fi
  cat "$HIT" >> "$SEL"
done < "$CHANGED"

if [ -n "$UNMAPPED" ]; then
  emit_all "no suite depends on changed path $UNMAPPED: full run"
  exit 0
fi

# Python modules run in full whenever a non-docs path changed (see header).
if [ "$HAS_CODE" -eq 1 ]; then
  grep -E '^tests/test_.*\.py$' "$DISC" >> "$SEL"
fi

SORTED="$(LC_ALL=C sort -u "$SEL" | sed '/^$/d')" || { emit_all "sort failed: full run"; exit 1; }
NSEL=0
if [ -n "$SORTED" ]; then
  NSEL="$(printf '%s\n' "$SORTED" | awk 'END { print NR }')"
fi
printf '# reason: %s changed path(s), %s suite(s) selected\n' "$NCHANGED" "$NSEL"
if [ -n "$SORTED" ]; then
  printf '%s\n' "$SORTED"
fi
exit 0
