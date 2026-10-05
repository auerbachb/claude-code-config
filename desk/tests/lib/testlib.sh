# shellcheck shell=bash
# desk/tests/lib/testlib.sh — shared helpers for desk/tests/*.test.sh.
# Sourced, never executed.

HQ_T_TESTS_DIR=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
HQ_T_DESK_DIR=$(dirname "$HQ_T_TESTS_DIR")
export HQ_T_CLI="$HQ_T_DESK_DIR/bin/human-queue.sh"

HQ_T_PASS=0
HQ_T_FAIL=0

ok()  { HQ_T_PASS=$((HQ_T_PASS + 1)); printf 'ok   — %s\n' "$1"; }
bad() { HQ_T_FAIL=$((HQ_T_FAIL + 1)); printf 'FAIL — %s\n' "$1"; }

# check LABEL ACTUAL EXPECTED
check() {
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$3', got '$2')"; fi
}

# check_contains LABEL HAYSTACK NEEDLE
check_contains() {
  case "$2" in
    *"$3"*) ok "$1" ;;
    *) bad "$1 (missing '$3' in: $2)" ;;
  esac
}

# check_absent LABEL HAYSTACK NEEDLE
check_absent() {
  case "$2" in
    *"$3"*) bad "$1 (found forbidden text)" ;;
    *) ok "$1" ;;
  esac
}

# hq_t_now — wall-clock seconds with millisecond precision (bash 3.2 has no
# sub-second clock of its own).
hq_t_now() { perl -MTime::HiRes=time -e 'printf "%.3f", time'; }

# hq_t_elapsed_under START END LIMIT — true when END-START < LIMIT.
hq_t_elapsed_under() {
  perl -e 'exit(($ARGV[1] - $ARGV[0]) < $ARGV[2] ? 0 : 1)' "$1" "$2" "$3"
}

hq_t_elapsed() { perl -e 'printf "%.3f", $ARGV[1] - $ARGV[0]' "$1" "$2"; }

# hq_t_lines TEXT — number of non-empty lines.
hq_t_lines() {
  if [ -z "$1" ]; then printf '0\n'; return 0; fi
  printf '%s\n' "$1" | grep -c .
}

# hq_t_require_db SUITE — skips the whole suite (exit 0) with a notice when
# HUMAN_QUEUE_DATABASE_URL is unset. With the URL set, an unreachable database
# is a FAILURE, never a skip.
hq_t_require_db() {
  if [ -z "${HUMAN_QUEUE_DATABASE_URL:-}" ]; then
    printf 'SKIP: %s — HUMAN_QUEUE_DATABASE_URL is unset; live database tests skipped\n' "$1"
    exit 0
  fi
}

# hq_t_finish SUITE — prints the tally and RETURNS 1 on any failure. Make it
# the suite's last command so the suite exits with its status: falling off the
# end (rather than calling `exit`) keeps shellcheck able to see that the EXIT
# trap's handler runs.
hq_t_finish() {
  printf '\n%s: %d passed, %d failed\n' "$1" "$HQ_T_PASS" "$HQ_T_FAIL"
  [ "$HQ_T_FAIL" -eq 0 ]
}
