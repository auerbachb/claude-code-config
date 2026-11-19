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
# Blocked and exhaustion reports raised before any PR exists may carry `none`.
none_report() { # phase outcome
  printf 'EXIT_REPORT\nPHASE_COMPLETE: %s\nPR_NUMBER: none\nHEAD_SHA: none\nREVIEWER: none\nOUTCOME: %s\nFILES_CHANGED: \nVERDICTS_POSTED: 0/0\nNEXT_PHASE: none\nHANDOFF_FILE: none\n' "$1" "$2"
}
for spec in "A blocked" "A exhaustion" "B blocked" "C blocked"; do
  set -- $spec
  none_report "$1" "$2" > "$TMP/r.txt"
  run --phase "$1" "$TMP/r.txt"
  [[ $RC -eq 0 && "$(field PR)" == none && "$(field OUTCOME)" == "$2" && "$(field FILES_COUNT)" == 0 ]] \
    || fail "$1/$2 with PR none should extract (rc=$RC out=$OUT)"
done
pass "blocked/exhaustion reports with no PR accept none"

# Phase B blocked_self_review is valid and needs a real PR.
report B blocked_self_review B > "$TMP/r.txt"; run --phase B "$TMP/r.txt"
[[ $RC -eq 0 && "$(field OUTCOME)" == blocked_self_review ]] || fail "blocked_self_review (rc=$RC)"
none_report B blocked_self_review > "$TMP/r.txt"; run "$TMP/r.txt"
[[ $RC -eq 1 ]] || fail "blocked_self_review with PR none must fail closed (rc=$RC)"
pass "blocked_self_review accepted with a PR, rejected without"

# PR-claiming outcomes reject none and blank required values.
for spec in "A pushed_fixes" "A no_findings" "B clean" "B fixes_pushed" "B merge_ready" "C merged"; do
  set -- $spec
  report "$1" "$2" B | sed 's/^PR_NUMBER: 618/PR_NUMBER: none/' > "$TMP/r.txt"; run "$TMP/r.txt"
  [[ $RC -eq 1 ]] || fail "$1/$2 with PR none must exit 1 (rc=$RC)"
  for key in HEAD_SHA REVIEWER HANDOFF_FILE; do
    report "$1" "$2" B | sed "s/^$key: .*/$key:/" > "$TMP/r.txt"; run "$TMP/r.txt"
    [[ $RC -eq 1 ]] || fail "$1/$2 with blank $key must exit 1 (rc=$RC)"
  done
done
pass "PR-claiming outcomes need an integer PR and non-blank identity fields"

# Unknown outcome for B, and a missing report, still fail closed.
report B pushed_fixes B > "$TMP/r.txt"; run "$TMP/r.txt"
[[ $RC -eq 1 ]] || fail "unknown outcome for B must exit 1 (rc=$RC)"
pass "unknown outcome fails closed"

# Extra prose before the block, and a multi-line NOTES field with a field after it.
{ printf 'Some prose before the report.\nPR looks fine.\n\n'
  report B merge_ready C $'NOTES: first line\nsecond line of notes\n  third line\nFIXPR_WAIT_FINAL: clean\n'
  printf '\ntrailing prose\n'; } > "$TMP/r.txt"
run --phase B "$TMP/r.txt"
[[ $RC -eq 0 && "$(field OUTCOME)" == merge_ready && "$(field FIXPR_WAIT_FINAL)" == clean ]] \
  || fail "prose before and multi-line NOTES (rc=$RC out=$OUT)"
pass "extra prose and multi-line NOTES handled"

# pm-worker completed needs a RESULT; blocked does not.
pmw() { printf 'EXIT_REPORT\nPHASE_COMPLETE: pm-worker\nPR_NUMBER: none\nHEAD_SHA: none\nREVIEWER: none\nOUTCOME: %s\nFILES_CHANGED:\nNEXT_PHASE: none\nHANDOFF_FILE: none\n%s' "$1" "${2:-}"; }
pmw completed > "$TMP/r.txt"; run "$TMP/r.txt"
[[ $RC -eq 1 ]] || fail "pm-worker completed without RESULT must exit 1 (rc=$RC)"
pmw completed "RESULT: created issue 2460" > "$TMP/r.txt"; run "$TMP/r.txt"
[[ $RC -eq 0 && "$(field RESULT)" == "created issue 2460" ]] || fail "pm-worker completed with RESULT (rc=$RC out=$OUT)"
pmw blocked > "$TMP/r.txt"; run "$TMP/r.txt"
[[ $RC -eq 0 ]] || fail "pm-worker blocked needs no RESULT (rc=$RC)"
pass "pm-worker completed requires RESULT"

# Optional RESULT line is carried and bounded.
report A pushed_fixes B "RESULT: created issue 2460" > "$TMP/r.txt"; run "$TMP/r.txt"
[[ "$(field RESULT)" == "created issue 2460" ]] || fail "RESULT lost: $OUT"
pass "RESULT field extracted"

# A blocked report carries its one-line blocker reason in RESULT; blocked without RESULT stays valid.
{ none_report A blocked; printf 'RESULT: unresolvable conflict in foo.ts\n'; } > "$TMP/r.txt"
run --phase A "$TMP/r.txt"
[[ $RC -eq 0 && "$(field OUTCOME)" == blocked && "$(field RESULT)" == "unresolvable conflict in foo.ts" ]] || fail "blocked RESULT (rc=$RC out=$OUT)"
pass "blocked report forwards its RESULT blocker reason"

# OWNER_ACTION lines above the last report reach the parent (issue #2561);
# ones above an earlier, quoted report do not.
{ printf 'OWNER_ACTION: sign-in: old example — quoted\n'; report B clean B
  printf '\nprose\nOWNER_ACTION: secret-value: Fill in STRIPE_PUBLISHABLE in .env — only he holds it\nOWNER_ACTION: sign-in: Run railway login — 2FA\n'
  report B merge_ready C; } > "$TMP/r.txt"
run --phase B "$TMP/r.txt"
actions=$(printf '%s\n' "$OUT" | grep -c '^OWNER_ACTION=' || true)
[[ $RC -eq 0 && "$(field OUTCOME)" == merge_ready && "$actions" == 2 \
   && "$(printf '%s\n' "$OUT" | grep -m1 '^OWNER_ACTION=')" == "OWNER_ACTION=secret-value: Fill in STRIPE_PUBLISHABLE in .env — only he holds it" ]] \
  || fail "OWNER_ACTION lines (rc=$RC out=$OUT)"
report B clean B > "$TMP/r.txt"; run --phase B "$TMP/r.txt"
[[ $RC -eq 0 && "$OUT" != *OWNER_ACTION* ]] || fail "no OWNER_ACTION expected (rc=$RC out=$OUT)"
pass "OWNER_ACTION lines above the last report are forwarded"

echo "All exit-report-extract tests passed."
