#!/usr/bin/env bash
# merge-gate-sut-override.test.sh — the script-under-test override contract for
# the merge-gate-*.test.sh family (issue #1485).
#
# The family resolves the scripts it exercises through SUT (merge-gate.sh),
# EVAL_SUT (review-substance.sh), and — in the authorship suite alone —
# MERGE_GATE. Each defaults to the enclosing checkout's copy and is overridable
# from the environment, which is what turns an origin/main negative control from
# a clone-and-overlay into one command. This suite pins all three properties:
#
#   (a) default resolution   -> the enclosing checkout's scripts (positive control)
#   (b) override honoured    -> an env value wins, in the harness AND end-to-end
#                               through a suite that sources it
#   (c) bad path refused     -> exit 1 naming the variable, NOT a wall of failed
#                               assertions that would read as a successful
#                               negative control while proving nothing
#   (d) idiom not re-hardcoded -> every assignment in the family keeps the
#                               ${VAR:-default} form
#
# Run from repo root: bash .claude/scripts/tests/merge-gate-sut-override.test.sh
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
HARNESS="$REPO_ROOT/.claude/scripts/tests/lib/merge-gate-test-fixtures.sh"
RUN_MARKER="$REPO_ROOT/.claude/scripts/tests/merge-gate-codeant-run-marker.test.sh"

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

PASS=0
FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1" >&2; FAIL=$((FAIL + 1)); }

check_eq() { # expected actual label
  if [[ "$1" == "$2" ]]; then ok "$3"; else bad "$3 (expected: $1, got: $2)"; fi
}
check_contains() { # needle haystack label
  case "$2" in
    *"$1"*) ok "$3" ;;
    *) bad "$3 (missing '$1' in: $2)" ;;
  esac
}

# Print the harness's resolved SUT and EVAL_SUT, one per line, in a child shell
# so this suite's own environment cannot leak into the answer. Sourcing the
# harness is cheap: it only resolves paths, mints a temp dir, and writes a gh stub.
resolved() { bash -c 'cd "$1" && source "$2" && printf "%s\n%s\n" "$SUT" "$EVAL_SUT"' _ "$REPO_ROOT" "$HARNESS" 2>&1; }

# --- (a) defaults: the enclosing checkout's scripts ---------------------------
DEFAULTS="$(resolved)"
check_eq "$REPO_ROOT/.claude/scripts/merge-gate.sh" "$(printf '%s\n' "$DEFAULTS" | sed -n 1p)" \
  "(a) SUT defaults to this checkout's merge-gate.sh"
check_eq "$REPO_ROOT/.claude/scripts/review-substance.sh" "$(printf '%s\n' "$DEFAULTS" | sed -n 2p)" \
  "(a) EVAL_SUT defaults to this checkout's review-substance.sh"

# --- (b) an environment value wins -------------------------------------------
# Stand-ins only have to be executable files; nothing here runs them.
FAKE_GATE="$TMP/other-merge-gate.sh"
FAKE_EVAL="$TMP/other-review-substance.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE_GATE"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE_EVAL"
chmod +x "$FAKE_GATE" "$FAKE_EVAL"

OVERRIDDEN="$(SUT="$FAKE_GATE" EVAL_SUT="$FAKE_EVAL" resolved)"
check_eq "$FAKE_GATE" "$(printf '%s\n' "$OVERRIDDEN" | sed -n 1p)" "(b) SUT honours the environment"
check_eq "$FAKE_EVAL" "$(printf '%s\n' "$OVERRIDDEN" | sed -n 2p)" "(b) EVAL_SUT honours the environment"

# Overriding one must not disturb the other — the negative control in the issue
# sets EVAL_SUT alone.
EVAL_ONLY="$(EVAL_SUT="$FAKE_EVAL" resolved)"
check_eq "$REPO_ROOT/.claude/scripts/merge-gate.sh" "$(printf '%s\n' "$EVAL_ONLY" | sed -n 1p)" \
  "(b) overriding EVAL_SUT alone leaves SUT at its default"
check_eq "$FAKE_EVAL" "$(printf '%s\n' "$EVAL_ONLY" | sed -n 2p)" \
  "(b) overriding EVAL_SUT alone still takes effect"

# --- (c) a bad path is refused, loudly ---------------------------------------
# Asserted on the harness AND end-to-end on a suite that sources it: a value that
# reaches the harness in isolation but not a real suite would be no use at all.
MISSING_OUT="$(EVAL_SUT="$TMP/no-such-evaluator.sh" resolved)"; MISSING_RC=$?
check_eq "1" "$MISSING_RC" "(c) a nonexistent EVAL_SUT exits 1"
check_contains "FAIL: EVAL_SUT is not an executable file:" "$MISSING_OUT" \
  "(c) the refusal names the offending variable"

# Existing but not executable is the likelier typo of the two (a copied path with
# no chmod, an overlay of a .md), and it must not slip through as a usable value.
NOEXEC="$TMP/not-executable.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$NOEXEC"
chmod -x "$NOEXEC"
NOEXEC_OUT="$(SUT="$NOEXEC" resolved)"; NOEXEC_RC=$?
check_eq "1" "$NOEXEC_RC" "(c) a non-executable SUT exits 1"
check_contains "FAIL: SUT is not an executable file:" "$NOEXEC_OUT" \
  "(c) the non-executable refusal names SUT"

# Every directory satisfies `-x`, so a path that stops one component short of the
# script would pass a bare executability test and only fail later, at exec.
DIR_OUT="$(SUT="$TMP" resolved)"; DIR_RC=$?
check_eq "1" "$DIR_RC" "(c) a directory is not accepted as SUT"
check_contains "FAIL: SUT is not an executable file:" "$DIR_OUT" \
  "(c) the directory refusal names SUT"

E2E_OUT="$(cd "$REPO_ROOT" && EVAL_SUT="$TMP/no-such-evaluator.sh" bash "$RUN_MARKER" 2>&1)"; E2E_RC=$?
check_eq "1" "$E2E_RC" "(c) the override reaches a real suite — run-marker exits 1 on a bad EVAL_SUT"
check_contains "FAIL: EVAL_SUT is not an executable file:" "$E2E_OUT" \
  "(c) run-marker refuses with the harness message"
# The refusal must PRE-EMPT the assertions rather than sit among them; a run that
# still emitted its 100+ cases would mean the bad path had been used for real.
check_eq "0" "$(printf '%s\n' "$E2E_OUT" | grep -c '^PASS:')" \
  "(c) the refusal short-circuits before any assertion runs"

# --- (d) the idiom stays in place --------------------------------------------
# A future edit that re-hardcodes any of these paths silently re-breaks the
# negative control, so scan the whole family rather than the files touched today.
CHECKED=0
VIOLATIONS=""
# The glob covers this file too — deliberately: a hardcoded assignment added here
# later should be caught like any other.
for f in "$HARNESS" "$REPO_ROOT"/.claude/scripts/tests/merge-gate-*.test.sh; do
  while IFS= read -r line; do
    CHECKED=$((CHECKED + 1))
    var="${line%%=*}"
    case "$line" in
      "$var=\"\${$var:-"*) : ;;
      *) VIOLATIONS="$VIOLATIONS$(basename "$f"): $line"$'\n' ;;
    esac
  done < <(grep -E '^(SUT|EVAL_SUT|MERGE_GATE)=' "$f")
done
# Zero assignments would make the loop above pass by never running (the family
# was renamed, moved, or the grep drifted) — that is a failure, not a clean scan.
if [[ "$CHECKED" -ge 8 ]]; then
  ok "(d) scanned $CHECKED script-under-test assignments across the family"
else
  bad "(d) expected at least 8 script-under-test assignments in the family, scanned $CHECKED"
fi
check_eq "" "$VIOLATIONS" "(d) every assignment keeps the \${VAR:-default} form"

echo "----------------------------------------"
echo "merge-gate-sut-override.test.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
