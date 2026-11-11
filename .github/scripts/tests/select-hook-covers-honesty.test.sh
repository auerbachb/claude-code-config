#!/usr/bin/env bash
# select-hook-covers-honesty.test.sh — Declaration honesty for the hook-test selector (issue #2177).
#
# A suite with a covers line depends on markdown files ONLY through that line (see the selector
# header). So a declared suite that reads a markdown file the declaration does not list would be
# skipped for a change to that file. This check fails when a declared suite names a repo markdown
# file on a non-comment line (a literal path, or a basename that matches a repo markdown file)
# without the declaration covering it. Comment lines are prose and are not reads.
#
# Mechanical limits: the check reads text, not behaviour. It cannot see a file a suite reads
# through a path that never appears in its text, nor tell a string literal from a read. Both are
# over-approximated in the safe direction: a string that names a markdown file must be declared
# too, so that file's change runs the suite. Undeclared suites are not checked (they keep the
# derivation that already runs them).
#
# Written to run under macOS bash 3.2 and bash 5 (no associative arrays, mapfile, GNU-only syntax).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)" || {
  echo "FAIL: cannot resolve repo root"
  exit 1
}

passes=0
failures=0
ok()  { passes=$((passes + 1)); printf 'PASS: %s\n' "$1"; }
bad() { failures=$((failures + 1)); printf 'FAIL: %s\n' "$1"; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/select-hook-covers-XXXXXX")" || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "$TMP"' EXIT
export LC_ALL=C

# check_root ROOT OUT: writes "suite<TAB>doc" for each violation under ROOT; returns 0 when the
# scan ran (violations are output, not a failure of the scan), 1 when the scan itself failed.
check_root() {
  local root="$1" out="$2" S
  : > "$out"
  ( cd "$root" || exit 1
    # Every scan below writes to a file and checks its status: grep exit 1 means no match, and exit
    # 2 or more is a read or write error. An error fails the scan (exit 1), never an empty result.
    find . -name '*.md' -not -path './.git/*' -not -path './worktrees/*' -not -path '*/node_modules/*' 2>/dev/null > "$TMP/docs-raw" || exit 1
    sed 's#^\./##' "$TMP/docs-raw" > "$TMP/docs-rel" || exit 1
    LC_ALL=C sort "$TMP/docs-rel" > "$TMP/docs" || exit 1
    for S in .claude/hooks/tests/*.test.sh .claude/scripts/tests/*.test.sh .github/scripts/tests/*.test.sh desk/tests/*.test.sh; do
      [ -f "$S" ] || continue
      grep -q '^# covers:' "$S"
      case $? in
        0) ;;
        1) continue ;;
        *) exit 1 ;;
      esac
      sed -n 's/^# covers:[[:space:]]*//p' "$S" > "$TMP/cov-s" || exit 1
      awk '{ for (i = 1; i <= NF; i++) print $i }' "$TMP/cov-s" > "$TMP/cov-raw" || exit 1
      : > "$TMP/cov" || exit 1
      while IFS= read -r c; do
        [ -n "$c" ] || continue
        if [ -d "$c" ]; then printf 'D\t%s\n' "$c" >> "$TMP/cov" || exit 1; else printf 'F\t%s\n' "$c" >> "$TMP/cov" || exit 1; fi
      done < "$TMP/cov-raw"
      grep -vE '^[[:space:]]*#' "$S" > "$TMP/body"
      case $? in 0|1) ;; *) exit 1 ;; esac
      grep -oE '(\.claude|\.github|desk|tests)/[[:alnum:]_./-]+\.md' "$TMP/body" > "$TMP/lit"
      case $? in 0|1) ;; *) exit 1 ;; esac
      grep -oE '[[:alnum:]_.-]+\.md' "$TMP/body" > "$TMP/bn"
      case $? in 0|1) ;; *) exit 1 ;; esac
      awk -v S="$S" -v covf="$TMP/cov" -v docf="$TMP/docs" -v litf="$TMP/lit" -v bnf="$TMP/bn" '
        BEGIN { FS = "\t" }
        FILENAME == covf { if ($1 == "F") covset[$2] = 1; else covdir[$2] = 1; next }
        FILENAME == docf { ndoc++; docs[ndoc] = $0; isdoc[$0] = 1; k = split($0, parts, "/"); base[ndoc] = parts[k]; next }
        FILENAME == litf { lit[$0] = 1; next }
        FILENAME == bnf { bnt[$0] = 1; next }
        function covered(p,   c) {
          if (p in covset) return 1
          for (c in covdir) if (index(p, c "/") == 1) return 1
          return 0
        }
        END {
          for (L in lit) {
            if ((L in isdoc) && !covered(L) && !(("L:" L) in seen)) { seen["L:" L] = 1; printf "%s\t%s\n", S, L }
          }
          for (B in bnt) {
            if (B == "README.md" || B == "SKILL.md") continue   # generic: keeps the derivation (selector header)
            for (i = 1; i <= ndoc; i++) {
              if (base[i] == B && !covered(docs[i]) && !(("B:" docs[i]) in seen)) {
                seen["B:" docs[i]] = 1
                printf "%s\t%s\n", S, docs[i]
              }
            }
          }
        }' "$TMP/cov" "$TMP/docs" "$TMP/lit" "$TMP/bn" >> "$out" || exit 1
    done
  ) || return 1
  return 0
}

# --- The real tree: every declared suite is honest --------------------------------------
REAL="$TMP/real-violations"
if check_root "$ROOT" "$REAL"; then
  NREAL="$(awk 'END { print NR }' "$REAL")"
  if [ "$NREAL" -eq 0 ]; then
    ok "every declared suite in the repo covers each markdown file it names outside comments"
  else
    bad "$NREAL declared-suite markdown read(s) missing from covers (suite<TAB>doc):"
    sed 's/^/  /' "$REAL"
  fi
else
  bad "honesty scan of the repo failed"
fi

# --- Fixtures: the check fails where it should and nowhere else -------------------------
F="$TMP/fixture"
mkdir -p "$F/.claude/rules" "$F/.claude/hooks/tests" "$F/.claude/scripts"
echo '# rule' > "$F/.claude/rules/x.md"
echo '# other' > "$F/.claude/rules/y.md"
echo 'echo a' > "$F/.claude/scripts/a.sh"

# An undeclared suite reads an undeclared markdown file: not checked (it keeps its derivation).
printf 'cat .claude/rules/x.md >/dev/null\nexit 0\n' > "$F/.claude/hooks/tests/undeclared.test.sh"
check_root "$F" "$TMP/fx1" && NFX1="$(awk 'END { print NR }' "$TMP/fx1")"
if [ "${NFX1:-1}" -eq 0 ]; then
  ok "an undeclared suite is not checked and reports nothing"
else
  bad "an undeclared suite was reported: $(cat "$TMP/fx1")"
fi

# A declared suite reads a markdown file its covers line does not list: violation.
printf '# covers: .claude/scripts/a.sh\ncat .claude/rules/x.md >/dev/null\nexit 0\n' > "$F/.claude/hooks/tests/declared.test.sh"
check_root "$F" "$TMP/fx2"
if grep -Fq 'declared.test.sh' "$TMP/fx2" && grep -Fq '.claude/rules/x.md' "$TMP/fx2"; then
  ok "a declared suite that reads an undeclared markdown file fails the check"
else
  bad "declared suite reading an undeclared file was not reported: $(cat "$TMP/fx2")"
fi

# The same suite, with the file declared: no violation.
printf '# covers: .claude/scripts/a.sh .claude/rules/x.md\ncat .claude/rules/x.md >/dev/null\nexit 0\n' > "$F/.claude/hooks/tests/declared.test.sh"
check_root "$F" "$TMP/fx3"
if [ "$(awk 'END { print NR }' "$TMP/fx3")" -eq 0 ]; then
  ok "a declared suite whose covers line lists the markdown file it reads passes"
else
  bad "declared and listed markdown file was still reported: $(cat "$TMP/fx3")"
fi

# A directory declaration covers the markdown files beneath it.
printf '# covers: .claude/scripts/a.sh .claude/rules\ncat .claude/rules/y.md >/dev/null\nexit 0\n' > "$F/.claude/hooks/tests/declared.test.sh"
check_root "$F" "$TMP/fx4"
if [ "$(awk 'END { print NR }' "$TMP/fx4")" -eq 0 ]; then
  ok "a declared directory covers the markdown files beneath it"
else
  bad "a declared directory did not cover a file beneath it: $(cat "$TMP/fx4")"
fi

# A markdown mention only in a comment is prose, not a read: no violation.
printf '# covers: .claude/scripts/a.sh\n# this suite used to read .claude/rules/x.md\nexit 0\n' > "$F/.claude/hooks/tests/declared.test.sh"
check_root "$F" "$TMP/fx5"
if [ "$(awk 'END { print NR }' "$TMP/fx5")" -eq 0 ]; then
  ok "a markdown path named only in a comment is not a read"
else
  bad "a comment-only markdown mention was reported: $(cat "$TMP/fx5")"
fi

# A declared suite that names a markdown file by basename only (a constructed path): violation.
printf '# covers: .claude/scripts/a.sh\nDIR=rules\ncat "$DIR/x.md" >/dev/null\nexit 0\n' > "$F/.claude/hooks/tests/declared.test.sh"
check_root "$F" "$TMP/fx6"
if grep -Fq '.claude/rules/x.md' "$TMP/fx6"; then
  ok "a declared suite that names an undeclared markdown file by basename fails the check"
else
  bad "a basename-only read of an undeclared markdown file was not reported: $(cat "$TMP/fx6")"
fi

# A declared suite the scan cannot read is a failed scan, not a clean one (grep exit 2, not 1).
# Needs a non-root user: root reads a mode-000 file anyway.
printf '# covers: .claude/scripts/a.sh\ncat .claude/rules/x.md >/dev/null\nexit 0\n' > "$F/.claude/hooks/tests/unreadable.test.sh"
chmod 000 "$F/.claude/hooks/tests/unreadable.test.sh"
if check_root "$F" "$TMP/fx7"; then
  bad "an unreadable declared suite passed the honesty scan as clean"
else
  ok "a scan error on a declared suite fails the honesty check"
fi
chmod 644 "$F/.claude/hooks/tests/unreadable.test.sh"

printf '\n%s passed, %s failed\n' "$passes" "$failures"
[ "$failures" -eq 0 ]
