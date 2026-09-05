#!/usr/bin/env bash
# No exit path of escalate-review.sh is silent (issue #1600).
# catalog: tests — Loud-exit contract tests for `escalate-review.sh` — every non-zero exit emits exactly one `escalate-review.sh: …` stderr diagnostic, the `EXIT` trap normalizes a raw 126/127 to exit 4 without fabricating a `STATUS=` verdict, and a negative control reproduces the pre-fix zero-output 126 on a copy with only the trap line removed
#
# THE BUG: during PR #1553's review loop `escalate-review.sh 1553` exited 126
# with ZERO output on both stdout and stderr — by path and via `bash <path>`
# alike. The file was present, executable and freshly synced, and the same
# invocation had worked minutes earlier. The caller could not tell "the script
# died" from "the script ran and produced no verdict", so it had to walk
# cr-github-review.md's three-tier chain by hand.
#
# THE MECHANISM: under `set -euo pipefail` an UNGUARDED command substitution
# propagates the failing command's status straight out of the script with
# nothing printed. escalate-review.sh has three such substitutions
# (PUSH_TIMESTAMP, BUGBOT_CHECK_PRESENT, BUDGET_EXHAUSTED). The dependency
# preflight cannot close that window: `command -v` proves a NAME resolves, not
# that the file will exec, and PATH can change under a long run.
#
# THE FIX: an EXIT trap at the boundary. 126/127 — the shell could not launch
# something — normalize to the documented exit 4 with one stderr line; any other
# non-zero exit that reaches the boundary without having spoken gets one generic
# line. The handler NEVER fabricates a STATUS= verdict: a broken environment is
# not a bounded helper outage (contrast issue #1465, which does degrade to
# polling_cr for a fault the script diagnosed itself).
#
# WHAT THIS SUITE PROVES, in order: the healthy path is untouched (A); a genuine
# shell 126 is now loud and normalized (B); a non-126 silent failure hits the
# generic backstop (C); the pre-fix script reproduces the original zero-output
# 126 on the identical fixture (D, the negative control); and a path that
# already printed its own diagnostic is not double-printed (E, F).
#
# SCOPE: this covers exits from a script that STARTED. A failure to launch the
# interpreter at all (corrupted PATH, `env: bash: No such file or directory` —
# issue #1556) runs no in-script trap and is out of reach here by construction.
#
# Shared fixtures live in tests/lib/escalate-review-fixtures.sh.
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/escalate-review-fixtures.sh
source "$TEST_DIR/lib/escalate-review-fixtures.sh"

# The jq program text of the UNGUARDED PUSH_TIMESTAMP substitution. Unique in
# the script (the two `is_cursor_bugbot_check` blocks would trip a guarded site
# first and never reach the silent path this suite is about).
UNGUARDED_JQ='.commit.committer.date'

# Ordinary, healthy fixture. Old enough (900 s) that the BugBot grace window has
# closed, so the run reaches the BugBot classification and returns a real
# verdict rather than an early polling_cr.
AGE=900
silent_fixture() {
  reset_state
  write_commits "$(ts_seconds_ago "$AGE")"
  write_state "[]" "[]" "[]" "[]"
}

# Count the script's own one-line diagnostics. "Exactly one" is the contract, so
# both zero and two are failures and this has to be a count, not a presence test.
count_diag() { grep -c '^escalate-review\.sh: ' "$1" || true; }

check_stderr_has() { # label file needle
  if grep -qF -- "$3" "$2"; then
    check_eq "$1" "present" "present"
  else
    check_eq "$1" "present" "absent — stderr was: $(tr '\n' '|' < "$2")"
  fi
}

############################################################################
echo "== Scenario (A): healthy control — the trap does not disturb a normal run =="
# Without this, a trap that broke every run would still satisfy every assertion
# below, because they all expect failure.
silent_fixture
OUT=$(run_script 2>"$TMP/a-stderr.txt"); RC=$?
check_eq "(A) exit 0" 0 "$RC"
check_eq "(A) a real verdict is still printed" "STATUS=switch_bugbot" "$OUT"
check_eq "(A) no diagnostic on a clean run" "0" "$(count_diag "$TMP/a-stderr.txt")"

############################################################################
echo "== Scenario (B): a genuine shell 126 at an unguarded substitution =="
# `exec` of a real non-executable file: the shell's own 126, not a fabricated
# one, with its "Permission denied" swallowed so the observable matches the
# incident — zero bytes out of the failing command.
break_jq_on "$UNGUARDED_JQ" exec
silent_fixture
OUT=$(run_script 2>"$TMP/b-stderr.txt"); RC=$?
check_eq "(B) 126 is normalized to the documented exit 4" 4 "$RC"
check_eq "(B) stdout carries NO fabricated verdict" "" "$OUT"
check_eq "(B) exactly one diagnostic line" "1" "$(count_diag "$TMP/b-stderr.txt")"
check_stderr_has "(B) the diagnostic names the shell-launch cause" "$TMP/b-stderr.txt" \
  "a required command could not be launched (shell exit 126)"
check_stderr_has "(B) the diagnostic names the PR" "$TMP/b-stderr.txt" "for PR #$PR_NUM"
check_stderr_has "(B) the diagnostic says no verdict was reached" "$TMP/b-stderr.txt" \
  "no STATUS verdict was reached"

############################################################################
echo "== Scenario (C): a NON-126 silent failure at the same site =="
# A jq that runs and dies on, say, a parse error exits 5-ish, not 126, so the
# normalizer above never sees it. Only the generic backstop makes it loud.
break_jq_on "$UNGUARDED_JQ" code 3
silent_fixture
OUT=$(run_script 2>"$TMP/c-stderr.txt"); RC=$?
check_eq "(C) the original status is preserved, not rewritten" 3 "$RC"
check_eq "(C) stdout carries NO fabricated verdict" "" "$OUT"
check_eq "(C) exactly one diagnostic line" "1" "$(count_diag "$TMP/c-stderr.txt")"
check_stderr_has "(C) the generic backstop fired" "$TMP/c-stderr.txt" \
  "exited 3 before emitting a STATUS verdict"

############################################################################
echo "== Scenario (D): NEGATIVE CONTROL — the pre-fix script reproduces the bug =="
# Same fixture, same trip, one line removed: `trap on_exit EXIT`. That is the
# whole fix, so a copy without it IS the pre-fix script. If this scenario ever
# stops reproducing the silent 126, the assertions above are passing for some
# reason other than the trap.
PRETRAP="$STUB_DIR/escalate-review-pretrap.sh"
grep -v '^trap on_exit EXIT$' "$STUB_DIR/escalate-review.sh" > "$PRETRAP"
chmod +x "$PRETRAP"
# Assert the surgery landed, in both directions — a no-op sed would leave this
# scenario running the FIXED script and quietly reporting the bug as unfixed.
check_eq "(D) the trap line is present in the shipped script" "1" \
  "$(grep -c '^trap on_exit EXIT$' "$STUB_DIR/escalate-review.sh" || true)"
check_eq "(D) the trap line is absent from the pre-fix copy" "0" \
  "$(grep -c '^trap on_exit EXIT$' "$PRETRAP" || true)"
break_jq_on "$UNGUARDED_JQ" exec
silent_fixture
OUT=$( cd "$REPO_ROOT" && bash "$PRETRAP" "$PR_NUM" 2>"$TMP/d-stderr.txt" ); RC=$?
check_eq "(D) pre-fix: the raw shell 126 escapes" 126 "$RC"
check_eq "(D) pre-fix: stdout is empty" "" "$OUT"
check_eq "(D) pre-fix: stderr is empty — the reported zero-output failure" "0" \
  "$(wc -c < "$TMP/d-stderr.txt" | tr -d ' ')"

restore_jq

############################################################################
echo "== Scenario (E): a path that already spoke is not double-printed =="
# The state-read failure below prints its own diagnostic through die(), so the
# backstop must stay quiet. This is what DIAG_PRINTED exists for.
silent_fixture
FIXTURE_STATE_JSON="$TMP/no-such-state.json"
export FIXTURE_STATE_JSON
OUT=$(run_script 2>"$TMP/e-stderr.txt"); RC=$?
check_eq "(E) exit 4" 4 "$RC"
check_eq "(E) exactly one diagnostic line" "1" "$(count_diag "$TMP/e-stderr.txt")"
check_stderr_has "(E) it is the site's own message, not the backstop" "$TMP/e-stderr.txt" \
  "failed to gather PR state for #$PR_NUM"

############################################################################
echo "== Scenario (F): usage errors keep their own single diagnostic =="
silent_fixture
OUT=$( cd "$REPO_ROOT" && bash "$STUB_DIR/escalate-review.sh" 2>"$TMP/f-stderr.txt" ); RC=$?
check_eq "(F) exit 2" 2 "$RC"
check_eq "(F) exactly one escalate-review.sh: line" "1" "$(count_diag "$TMP/f-stderr.txt")"
check_stderr_has "(F) it is the usage message" "$TMP/f-stderr.txt" \
  "<pr_number> is required"

finish_escalate_review_tests "silent-exit"
