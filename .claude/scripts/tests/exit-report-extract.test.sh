#!/usr/bin/env bash
# Tests for exit-report-extract.sh (issue #2435).
# catalog: tests — Extractor returns the completion-protocol fields per phase and outcome, fails closed on absent or malformed reports
# covers: .claude/scripts/exit-report-extract.sh
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
EX="$ROOT/.claude/scripts/exit-report-extract.sh"
[[ -f "$EX" ]] || { echo "FAIL: $EX not found" >&2; exit 1; }
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

run() { set +e; OUT=$(bash "$EX" "$@" 2>/dev/null); RC=$?; set -e; }
field() { printf '%s\n' "$OUT" | sed -n "s/^$1=//p"; }

report() { # phase outcome next [extra lines]
  printf 'EXIT_REPORT\nPHASE_COMPLETE: %s\nPR_NUMBER: 618\nHEAD_SHA: abc1234\nREVIEWER: cr\nOUTCOME: %s\nFILES_CHANGED: a.sh, b.md\n' "$1" "$2"
  if [[ "$1" != C ]]; then printf 'VERDICTS_POSTED: 3/3\n'; fi
  printf 'NEXT_PHASE: %s\nHANDOFF_FILE: /h/pr-618.json\n%s' "$3" "${4:-}"
}

for spec in "A pushed_fixes B" "A no_findings B" "A exhaustion A" "A blocked none" \
            "B clean B" "B fixes_pushed B" "B merge_ready C" "B exhaustion B" \
            "C merged none" "C blocked none"; do
  set -- $spec
  report "$1" "$2" "$3" > "$TMP/r.txt"
  run --phase "$1" "$TMP/r.txt"
  [[ $RC -eq 0 ]] || fail "$1/$2 should extract (rc=$RC)"
  [[ "$(field OUTCOME)" == "$2" && "$(field PHASE)" == "$1" && "$(field PR)" == 618 \
     && "$(field HEAD)" == abc1234 && "$(field NEXT)" == "$3" && "$(field FILES_COUNT)" == 2 ]] \
    || fail "$1/$2 fields wrong: $OUT"
  pass "phase $1 outcome $2"
done

# FIXPR fields carried when present.
report A pushed_fixes B $'FIXPR_WAIT_ITERATIONS: 2\nFIXPR_TOTAL_WAIT_SECS: 90\nFIXPR_WAIT_FINAL: clean\n' > "$TMP/r.txt"
run "$TMP/r.txt"
[[ "$(field FIXPR_WAIT_FINAL)" == clean && "$(field FIXPR_WAIT_ITERATIONS)" == 2 ]] || fail "FIXPR fields lost: $OUT"
pass "FIXPR fields extracted"

# Researcher reduced schema.
printf 'EXIT_REPORT\nAGENT: researcher\nOUTCOME: findings\n' > "$TMP/r.txt"
run "$TMP/r.txt"
[[ $RC -eq 0 && "$(field PHASE)" == researcher ]] || fail "researcher schema (rc=$RC)"
pass "researcher reduced schema"

# Absent report: exit 3 so crash / limit-park classification stays reachable.
printf 'long log\nno report here\n' > "$TMP/r.txt"
run "$TMP/r.txt"
[[ $RC -eq 3 && "$OUT" == "EXTRACT=absent" ]] || fail "absent report must exit 3 (rc=$RC)"
pass "absent report exits 3"

# Malformed reports fail closed (exit 1).
printf 'EXIT_REPORT\nPHASE_COMPLETE: A\nOUTCOME: pushed_fixes\n' > "$TMP/r.txt"
run "$TMP/r.txt"
[[ $RC -eq 1 ]] || fail "missing fields must exit 1 (rc=$RC)"
report A merged B > "$TMP/r.txt"; run "$TMP/r.txt"
[[ $RC -eq 1 ]] || fail "outcome invalid for phase must exit 1 (rc=$RC)"
report A pushed_fixes B > "$TMP/r.txt"; run --phase B "$TMP/r.txt"
[[ $RC -eq 1 ]] || fail "phase mismatch must exit 1 (rc=$RC)"
printf 'EXIT_REPORT\n' > "$TMP/r.txt"; run "$TMP/r.txt"
[[ $RC -eq 1 ]] || fail "header-only block must exit 1 (rc=$RC)"
report A pushed_fixes B | sed 's/^PR_NUMBER: 618/PR_NUMBER: x/' > "$TMP/r.txt"; run "$TMP/r.txt"
[[ $RC -eq 1 ]] || fail "non-numeric PR must exit 1 (rc=$RC)"
report B 'clean fixes_pushed' B > "$TMP/r.txt"; run "$TMP/r.txt"
[[ $RC -eq 1 ]] || fail "combined outcome values must exit 1 (rc=$RC)"
pass "malformed reports fail closed"

# Last block wins; huge log stays bounded; stdin works.
{ report A no_findings B; head -c 500000 /dev/zero | tr '\0' 'z'; printf '\n'; report A pushed_fixes B; } > "$TMP/r.txt"
run "$TMP/r.txt"
[[ "$(field OUTCOME)" == pushed_fixes ]] || fail "last block must win: $OUT"
(( ${#OUT} < 1200 )) || fail "output unbounded (${#OUT})"
set +e; OUT=$(bash "$EX" --phase A < "$TMP/r.txt" 2>/dev/null); RC=$?; set -e
[[ $RC -eq 0 && "$(field OUTCOME)" == pushed_fixes ]] || fail "stdin input (rc=$RC)"
pass "last block wins, output bounded, stdin accepted"
echo "All exit-report-extract tests passed."
