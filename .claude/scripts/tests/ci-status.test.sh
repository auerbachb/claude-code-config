#!/usr/bin/env bash
# ci-status.test.sh — Offline unit tests for ci-status.sh check-run dedup (issue #675).
# catalog: tests — Tests for `ci-status.sh`
#
# Most cases drive the `--check-runs-stdin` path with a full 40-char SHA, which
# makes zero gh calls — no stub, no network. A separate section stubs `gh` to prove
# the live-fetch path dedups identically, since the acceptance criteria cover both.
#
# Run from repo root: bash .claude/scripts/tests/ci-status.test.sh
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
# Run the real script in place: it resolves check-runs-dedup.sh next to itself.
SUT="$REPO_ROOT/.claude/scripts/ci-status.sh"
SHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

export HOME="$TMP/home"; mkdir -p "$HOME/.claude"

PASS=0
FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1" >&2; FAIL=$((FAIL + 1)); }

check_eq() { # expected actual label
  if [[ "$1" == "$2" ]]; then ok "$3"; else bad "$3 (expected: $1, got: $2)"; fi
}

OUT=""
RC=0
run_stdin() { OUT=$(printf '%s' "$1" | "$SUT" "$SHA" --format json --check-runs-stdin 2>/dev/null); RC=$?; }

field() { echo "$OUT" | jq -r "$1"; }

cr() { # id name conclusion suite_id [app_slug] [status]
  jq -cn --argjson id "$1" --arg name "$2" --arg concl "$3" --argjson suite "$4" \
         --arg slug "${5:-gha}" --arg status "${6:-completed}" \
    '{id:$id, name:$name, status:$status,
      conclusion:(if $concl == "null" then null else $concl end),
      check_suite:{id:$suite}, app:{slug:$slug, id:1}}'
}
bundle() { printf '{"check_runs":[%s]}' "$(IFS=,; echo "$*")"; }

# --------------------------------------------------------------------------
# 1. Superseded failure — the reported bug. Old failed run + newer passing run
#    of the same check on one SHA must read as clean.
# --------------------------------------------------------------------------
run_stdin "$(bundle "$(cr 1 test failure 100)" "$(cr 2 test failure 200)" "$(cr 3 test success 300)")"
check_eq 0 "$RC" "superseded failure: exit 0 (clean), not 3"
check_eq 0 "$(field .failing)" "superseded failure: failing == 0"
check_eq 1 "$(field .total)" "superseded failure: only the newest suite's run is counted"
check_eq 1 "$(field .passing)" "superseded failure: the newest run is the passing one"
check_eq "[]" "$(echo "$OUT" | jq -c '.blocking')" "superseded failure: nothing in blocking"

# Summary format must agree with the JSON.
SUMMARY=$(printf '%s' "$(bundle "$(cr 1 test failure 100)" "$(cr 3 test success 300)")" \
  | "$SUT" "$SHA" --format summary --check-runs-stdin 2>/dev/null)
check_eq "CI: 1/1 passed" "$SUMMARY" "superseded failure: summary line is clean"

# --------------------------------------------------------------------------
# 2. Matrix legs sharing a name inside the newest suite are all classified;
#    a failing leg must not be masked by a passing sibling.
# --------------------------------------------------------------------------
run_stdin "$(bundle "$(cr 1 test failure 100)" "$(cr 2 test success 200)" "$(cr 3 test failure 200)")"
check_eq 3 "$RC" "matrix legs: failing leg still exits 3"
check_eq 1 "$(field .failing)" "matrix legs: the failing leg is counted"
check_eq 2 "$(field .total)" "matrix legs: both legs of the newest suite are counted"
check_eq 3 "$(field '.blocking[0].id')" "matrix legs: the failing leg appears in blocking"

# --------------------------------------------------------------------------
# 3. Newest run in progress while an older run of that name failed -> WAIT.
# --------------------------------------------------------------------------
run_stdin "$(bundle "$(cr 1 test failure 100)" "$(cr 2 test null 200 gha in_progress)")"
check_eq 1 "$RC" "newest run in progress: exit 1 (WAIT), not 3"
check_eq 0 "$(field .failing)" "newest run in progress: superseded failure is not counted"
check_eq 1 "$(field .in_progress)" "newest run in progress: counted as in progress"
check_eq "test" "$(field '.in_progress_runs[0].name')" "newest run in progress: named in in_progress_runs"

# `queued` is the other non-completed status.
run_stdin "$(bundle "$(cr 1 test failure 100)" "$(cr 2 test null 200 gha queued)")"
check_eq 1 "$RC" "newest run queued: exit 1 (WAIT), not 3"

# --------------------------------------------------------------------------
# 4. Regression guard — the ordinary single-run-per-name case is unchanged.
# --------------------------------------------------------------------------
run_stdin "$(bundle "$(cr 1 lint success 100)" "$(cr 2 test failure 100)")"
check_eq 3 "$RC" "distinct names, one failing: exit 3 unchanged"
check_eq 1 "$(field .failing)" "distinct names: the failing check is still counted"
check_eq 2 "$(field .total)" "distinct names: nothing is collapsed away"

run_stdin "$(bundle "$(cr 1 lint success 100)" "$(cr 2 test success 100)")"
check_eq 0 "$RC" "distinct names, all passing: exit 0 unchanged"

# A genuinely failing newest run still blocks even with an older passing run.
run_stdin "$(bundle "$(cr 1 test success 100)" "$(cr 2 test failure 200)")"
check_eq 3 "$RC" "newest run failing (older passed): exit 3 — dedup does not hide live failures"

# Every blocking conclusion in the documented set survives dedup.
for concl in failure timed_out action_required startup_failure stale; do
  run_stdin "$(bundle "$(cr 1 test success 100)" "$(cr 2 test "$concl" 200)")"
  check_eq 3 "$RC" "blocking conclusion '$concl' on the newest run still exits 3"
done

# Non-blocking conclusions stay non-blocking. `cancelled` here is the preserved
# policy for checks that are NOT required (issues #211, #1361): this script counts
# every check-run and has no notion of required contexts. A cancelled REQUIRED
# check is held by merge-gate.sh instead — merge-gate-required-cancelled.test.sh
# (issue #1846) — so do not tighten this loop to "fix" that case.
for concl in success neutral skipped cancelled; do
  run_stdin "$(bundle "$(cr 1 test failure 100)" "$(cr 2 test "$concl" 200)")"
  check_eq 0 "$RC" "non-blocking conclusion '$concl' on the newest run exits 0"
done

# Fail closed (issue #1846): the non-blocking set is a whitelist, so a conclusion
# nobody has listed — one GitHub adds later — blocks instead of passing silently.
run_stdin "$(bundle "$(cr 1 test success 100)" "$(cr 2 test brand_new_conclusion 200)")"
check_eq 3 "$RC" "unknown conclusion on the newest run: exit 3, not a silent pass"
check_eq 1 "$(field .failing)" "unknown conclusion: counted failing"
check_eq 0 "$(field .passing)" "unknown conclusion: not counted passing"
check_eq "brand_new_conclusion" "$(field '.blocking[0].conclusion')" "unknown conclusion: named in blocking"

# A run marked completed that carries no conclusion cannot be read as a pass either.
run_stdin "$(bundle "$(cr 1 test null 100 gha completed)")"
check_eq 3 "$RC" "completed with no conclusion: exit 3"
check_eq "none" "$(field '.blocking[0].conclusion')" "completed with no conclusion: reported as 'none'"

# ...while a run that has not completed is still WAIT, never a failure.
run_stdin "$(bundle "$(cr 1 test null 100 gha in_progress)")"
check_eq 1 "$RC" "in-progress run with no conclusion: exit 1 (WAIT), unchanged"
check_eq 0 "$(field .failing)" "in-progress run with no conclusion: not failing"

# --------------------------------------------------------------------------
# 5. Same name from two different apps must not collapse into each other.
# --------------------------------------------------------------------------
run_stdin "$(bundle "$(cr 1 lint failure 100 appA)" "$(cr 2 lint success 200 appB)")"
check_eq 3 "$RC" "same name, two apps: appA's failure is not masked by appB's success"
check_eq 2 "$(field .total)" "same name, two apps: both are counted"

# --------------------------------------------------------------------------
# 6. Zero-check-runs sentinel is untouched by dedup.
# --------------------------------------------------------------------------
run_stdin '{"check_runs":[]}'
check_eq 1 "$RC" "empty check-run list: exit 1 (sentinel), not 0"
check_eq 0 "$(field .total)" "empty check-run list: total 0"
check_eq 1 "$(field .in_progress)" "empty check-run list: sentinel counted as in progress"
check_eq "(no check-runs reported yet)" "$(field '.in_progress_runs[0].name')" "empty check-run list: sentinel entry preserved"
check_eq "null" "$(field '.in_progress_runs[0].id')" "empty check-run list: sentinel id is null"

# --------------------------------------------------------------------------
# 7. Error contracts on the stdin path are unchanged.
# --------------------------------------------------------------------------
printf '' | "$SUT" "$SHA" --format json --check-runs-stdin >/dev/null 2>&1
check_eq 2 "$?" "empty stdin with --check-runs-stdin exits 2"

run_stdin 'not json'
check_eq 5 "$RC" "unparseable stdin exits 5"

# --------------------------------------------------------------------------
# 8. Live-fetch path — same dedup, proven with a gh stub.
# --------------------------------------------------------------------------
BIN="$TMP/bin"; mkdir -p "$BIN"
cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
ARGS="$*"
case "$ARGS" in
  "repo view --json nameWithOwner --jq .nameWithOwner")
    echo "solo/repo"; exit 0 ;;
  *check-runs*)
    printf '%s' "$FAKE_CHECK_RUNS"; exit 0 ;;
esac
echo "unexpected gh call: $ARGS" >&2
exit 1
EOF
chmod +x "$BIN/gh"

run_live() { OUT=$(PATH="$BIN:$PATH" FAKE_CHECK_RUNS="$1" "$SUT" "$SHA" --format json 2>/dev/null); RC=$?; }

run_live "$(bundle "$(cr 1 test failure 100)" "$(cr 2 test failure 200)" "$(cr 3 test success 300)")"
check_eq 0 "$RC" "live fetch: superseded failure exits 0"
check_eq 0 "$(field .failing)" "live fetch: failing == 0"
check_eq 1 "$(field .total)" "live fetch: only the newest suite's run is counted"

run_live "$(bundle "$(cr 1 test success 100)" "$(cr 2 test failure 200)")"
check_eq 3 "$RC" "live fetch: a failing newest run still exits 3"

# Paginated responses are flattened and deduped across pages.
run_live "$(bundle "$(cr 1 test failure 100)")$(bundle "$(cr 2 test success 200)")"
check_eq 0 "$RC" "live fetch: dedup spans pages of a --paginate response"
check_eq 1 "$(field .total)" "live fetch: cross-page duplicate collapsed to the newest suite"

# --------------------------------------------------------------------------
# 9. Telemetry must never change the contract (issue #1430; cf. repo-root
#    T16j). The usage-log append runs before argument parsing; unguarded, an
#    unset HOME aborted under `set -u` with exit 1 — the documented
#    "incomplete, wait" code, so merge-gate.sh would wait on CI forever — and
#    a missing ~/.claude leaked bash's redirect diagnostic onto stderr ahead
#    of the real output (issue #1406 ordering).
# --------------------------------------------------------------------------
RC=0
ERR="$(env -u HOME "$SUT" --help 2>&1 >/dev/null)" || RC=$?
check_eq 0 "$RC" "telemetry: --help exits 0 with HOME unset (set -u)"
check_eq "" "$ERR" "telemetry: no stderr with HOME unset"

NOHOME="$TMP/no-such-home"
RC=0
ERR="$(HOME="$NOHOME" "$SUT" --help 2>&1 >/dev/null)" || RC=$?
check_eq 0 "$RC" "telemetry: --help exits 0 when \$HOME/.claude is missing"
check_eq "" "$ERR" "telemetry: no shell diagnostic when the log dir is missing"

# The full stdin path still classifies with an unwritable log — exit code,
# stdout, and stderr all intact.
ERR_FILE="$TMP/telemetry-stderr.cap"
OUT=$(printf '%s' "$(bundle "$(cr 1 test success 100)")" \
  | HOME="$NOHOME" "$SUT" "$SHA" --format json --check-runs-stdin 2>"$ERR_FILE"); RC=$?
check_eq 0 "$RC" "telemetry: full stdin-path run exits 0 with missing log dir"
check_eq "" "$(cat "$ERR_FILE")" "telemetry: full run leaves stderr empty"
check_eq 1 "$(field .passing)" "telemetry: JSON output intact under missing log dir"

# Positive control: with the sandbox ~/.claude present the invocation is
# logged — the guard must not silence telemetry on healthy machines.
: > "$HOME/.claude/script-usage.log"
printf '%s' "$(bundle "$(cr 1 test success 100)")" \
  | "$SUT" "$SHA" --format json --check-runs-stdin >/dev/null 2>&1
check_eq 1 "$(grep -c 'ci-status.sh' "$HOME/.claude/script-usage.log")" \
  "telemetry: append still lands when ~/.claude exists"

# --------------------------------------------------------------------------
# 10. --exclude-reviewers (issue #1749): build CI only. A reviewer's own check
#     can neither hold the verdict pending nor turn it red, and identity is the
#     exact app slug — never the check name.
# --------------------------------------------------------------------------
run_excl() { OUT=$(printf '%s' "$1" | "$SUT" "$SHA" --format json --check-runs-stdin --exclude-reviewers 2>/dev/null); RC=$?; }

PENDING_REVIEWER="$(bundle "$(cr 1 build success 100)" "$(cr 2 "Cursor Bugbot" null 200 cursor in_progress)")"
run_stdin "$PENDING_REVIEWER"
check_eq 1 "$RC" "exclude-reviewers control: without the flag a pending reviewer check is pending"
run_excl "$PENDING_REVIEWER"
check_eq 0 "$RC" "exclude-reviewers: a pending reviewer check with green build checks is clean"
check_eq 1 "$(field .total)" "exclude-reviewers: only the build check is counted"

FAILED_REVIEWER="$(bundle "$(cr 1 build success 100)" "$(cr 2 "CodeAnt AI" failure 200 codeant-ai)" "$(cr 3 review failure 300 coderabbitai)")"
run_stdin "$FAILED_REVIEWER"
check_eq 3 "$RC" "exclude-reviewers control: without the flag a failed reviewer check is red"
run_excl "$FAILED_REVIEWER"
check_eq 0 "$RC" "exclude-reviewers: failed reviewer checks with green build checks are clean"

for slug in codeant cursor-com coderabbit graphite-app graphite greptile-apps greptile; do
  run_excl "$(bundle "$(cr 1 build success 100)" "$(cr 2 r failure 200 "$slug")")"
  check_eq 0 "$RC" "exclude-reviewers: slug $slug is a reviewer"
done

# A check NAMED after a reviewer but published by a workflow is build CI.
run_excl "$(bundle "$(cr 1 build success 100)" "$(cr 2 "CodeAnt AI" failure 200 github-actions)")"
check_eq 3 "$RC" "exclude-reviewers: a reviewer-named check from another app still counts"
run_excl "$(bundle "$(cr 1 build success 100)" "$(cr 2 lint failure 200 codeant-ai-fork)")"
check_eq 3 "$RC" "exclude-reviewers: a look-alike slug still counts"

# Build failures and pending build checks are unaffected.
run_excl "$(bundle "$(cr 1 build failure 100)" "$(cr 2 "Cursor Bugbot" success 200 cursor)")"
check_eq 3 "$RC" "exclude-reviewers: a failing build check still exits 3"
run_excl "$(bundle "$(cr 1 build null 100 gha in_progress)")"
check_eq 1 "$RC" "exclude-reviewers: a pending build check still exits 1"

# Only reviewer checks left: pending, exactly like an empty list.
run_excl "$(bundle "$(cr 1 "CodeAnt AI" success 100 codeant-ai)")"
check_eq 1 "$RC" "exclude-reviewers: no build check left reads as pending"
check_eq "(no check-runs reported yet)" "$(field '.in_progress_runs[0].name')" "exclude-reviewers: empty build list carries the sentinel"

echo "----------------------------------------"
echo "ci-status.test.sh: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
