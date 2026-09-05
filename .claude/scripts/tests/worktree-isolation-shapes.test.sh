#!/usr/bin/env bash
# Offline tests for the two wrappers that make issue #1470's refused command
# shapes reachable from a worktree-isolated agent: worktree-status.sh (case 1)
# and wait-until.sh (case 2).
#
# WHY THIS SUITE EXISTS
#
# The refusing classifier is the HARNESS's worktree-isolation guard, external to
# this repository — the only in-repo worktree guard, .claude/hooks/worktree-guard.sh,
# inspects Write/Edit/NotebookEdit file targets and never reads a Bash command
# string. So the guard itself cannot be tested here. What CAN be pinned is the
# other half of the fix: that each refused shape has a working single-call
# equivalent, and that the equivalent answers the question the refused form was
# asking — not a plausible-looking substitute for it.
#
# That distinction is the whole point of case 1. `git -C <linked worktree>
# rev-parse HEAD` reports the LINKED worktree's HEAD; resolving through
# repo-root.sh instead would report the MAIN worktree's, and every field would
# still look like a valid answer. T3 fails on that substitution.
#
# NEGATIVE CONTROLS (a suite of only-happy-paths would pass vacuously):
#   T4  --repo must be honoured, not silently ignored — every --repo case runs
#       from a NON-repo cwd, so an ignored flag exits non-zero instead of
#       quietly answering about the test runner's own checkout.
#   T5  a --repo pointing at a real directory that is not a git repo is refused,
#       not answered.
#   T11 a wait-until.sh check that never succeeds is reported as CAP HIT with
#       the cap exit code — never as met.
#   T13 an unlaunchable check command is fatal on tick 1 rather than "polled"
#       to the cap, so a typo cannot masquerade as a timeout.
#
# Requires git. No network. Run from anywhere:
#   bash .claude/scripts/tests/worktree-isolation-shapes.test.sh
set -uo pipefail

# Derived from THIS file's location, not from the caller's cwd: the suite runs
# from anywhere, and `git rev-parse --show-toplevel` would resolve whatever repo
# the caller happens to be standing in — silently testing another checkout's
# scripts, or failing outside a repo entirely.
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || { echo "cannot resolve test dir" >&2; exit 1; }
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
[[ -d "$REPO_ROOT/.claude/scripts" ]] || { echo "cannot resolve repo root from $TEST_DIR" >&2; exit 1; }

TMP="$(mktemp -d)"
TMP_HOME="$(mktemp -d)"
cleanup() {
  # T14b spawns a deliberately hanging check; kill any survivor so a failing
  # assertion cannot leak one into the runner.
  pkill -f "$TMP/hangs" >/dev/null 2>&1 || true
  rm -rf "$TMP" "$TMP_HOME"
}
trap cleanup EXIT
# Every script appends one telemetry line to $HOME/.claude/script-usage.log on
# entry. Redirect HOME so the suite never touches the developer's real state.
export HOME="$TMP_HOME"
mkdir -p "$HOME/.claude"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "ok   — $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL — $1"; }

check_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    pass "$desc"
  else
    fail "$desc (expected '$expected', got '$actual')"
  fi
}

check_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    pass "$desc"
  else
    fail "$desc (missing '$needle' in: $haystack)"
  fi
}

check_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    pass "$desc"
  else
    fail "$desc (unexpectedly found '$needle')"
  fi
}

# --- install a realistic copy of both scripts, with the lib they require ------
# Copied rather than invoked in place so the suite also proves the install shape
# is self-sufficient: both scripts refuse to run git unbounded without
# lib/bounded-run.sh beside them, exactly as a real install has it.
SBIN="$TMP/install/.claude/scripts"
mkdir -p "$SBIN/lib"
cp "$REPO_ROOT/.claude/scripts/worktree-status.sh" "$SBIN/"
cp "$REPO_ROOT/.claude/scripts/wait-until.sh" "$SBIN/"
cp "$REPO_ROOT/.claude/scripts/lib/bounded-run.sh" "$SBIN/lib/"
chmod +x "$SBIN/worktree-status.sh" "$SBIN/wait-until.sh"
WSTATUS="$SBIN/worktree-status.sh"
WAIT="$SBIN/wait-until.sh"

# --- fixture repo: a main worktree on main + one LINKED worktree --------------
MAIN="$TMP/mainrepo"
mkdir -p "$MAIN"
git init -q -b main "$MAIN"
git -C "$MAIN" config user.email "test@example.com"
git -C "$MAIN" config user.name "Test"
echo "first" > "$MAIN/file.txt"
git -C "$MAIN" add file.txt
git -C "$MAIN" commit -q -m "init"
MAIN_SHA="$(git -C "$MAIN" rev-parse HEAD)"

LINKED="$TMP/wt-linked"
git -C "$MAIN" worktree add -q "$LINKED" -b issue-1470-fixture
echo "second" > "$LINKED/file.txt"
git -C "$LINKED" add file.txt
git -C "$LINKED" commit -q -m "linked commit"
LINKED_SHA="$(git -C "$LINKED" rev-parse HEAD)"

# A cwd that is not inside ANY git repo. Every --repo case runs from here, so a
# --repo that was ignored (or that fell back to cwd resolution) fails loudly
# instead of answering about the test runner's own checkout.
NONREPO="$TMP/nonrepo"
mkdir -p "$NONREPO"

# The two SHAs must differ, or T3's substitution check is vacuous.
if [[ "$MAIN_SHA" != "$LINKED_SHA" ]]; then
  pass "fixture: main and linked worktree are on different commits"
else
  fail "fixture: main and linked worktree share a commit — T3 would pass vacuously"
fi

# =============================================================================
# worktree-status.sh — issue #1470 case 1
#   refused:  git -C <wt> rev-parse HEAD; git -C <wt> branch --show-current
#   allowed:  worktree-status.sh --repo <wt>
# =============================================================================

# ---- T1: the whole refused pair answered by one call, from a non-repo cwd ----
RC=0
OUT="$(cd "$NONREPO" && "$WSTATUS" --repo "$LINKED" 2>&1)" || RC=$?
check_eq "T1: one call replaces the refused \`git -C …; git -C …\` pair" "0" "$RC"
check_contains "T1: reports HEAD" "HEAD=$LINKED_SHA" "$OUT"
check_contains "T1: reports BRANCH" "BRANCH=issue-1470-fixture" "$OUT"
check_contains "T1: reports DETACHED" "DETACHED=false" "$OUT"

# ---- T2: fields are individually readable, the sed idiom the doc names -------
HEAD_FIELD="$(cd "$NONREPO" && "$WSTATUS" --repo "$LINKED" 2>/dev/null | sed -n 's/^HEAD=//p')"
check_eq "T2: HEAD= is readable with the documented sed idiom" "$LINKED_SHA" "$HEAD_FIELD"
BRANCH_FIELD="$(cd "$NONREPO" && "$WSTATUS" --repo "$LINKED" 2>/dev/null | sed -n 's/^BRANCH=//p')"
check_eq "T2: BRANCH= is readable the same way" "issue-1470-fixture" "$BRANCH_FIELD"

# ---- T3: answers for the LINKED worktree, never for the main worktree --------
# This is the substitution guard. Resolving through repo-root.sh would return
# MAIN_SHA and "main" here, and both would look like perfectly valid output.
check_not_contains "T3: does NOT report the main worktree's HEAD" "$MAIN_SHA" "$OUT"
check_not_contains "T3: does NOT report the main worktree's branch" "BRANCH=main" "$OUT"
ROOT_FIELD="$(cd "$NONREPO" && "$WSTATUS" --repo "$LINKED" 2>/dev/null | sed -n 's/^ROOT=//p')"
check_eq "T3: ROOT= is the linked worktree's own top level" \
  "$(cd "$LINKED" && pwd -P)" "$(cd "$ROOT_FIELD" && pwd -P)"

# ---- T3b: control — pointed at the main worktree it reports main -------------
# Without this, a script that always reported the CURRENT dir would pass T3.
RC=0
OUT_MAIN="$(cd "$NONREPO" && "$WSTATUS" --repo "$MAIN" 2>&1)" || RC=$?
check_eq "T3b: control — --repo <main worktree> succeeds" "0" "$RC"
check_contains "T3b: control — and reports main's HEAD" "HEAD=$MAIN_SHA" "$OUT_MAIN"
check_contains "T3b: control — and reports branch main" "BRANCH=main" "$OUT_MAIN"

# ---- T4: --repo is honoured, not ignored ------------------------------------
# Run with NO --repo from the non-repo cwd: it must FAIL. If this passed, every
# --repo assertion above would be unfalsifiable.
RC=0
OUT_NOFLAG="$(cd "$NONREPO" && "$WSTATUS" 2>&1)" || RC=$?
check_eq "T4: negative control — no --repo from a non-repo cwd exits 1" "1" "$RC"
check_contains "T4: and says why" "not a git repository" "$OUT_NOFLAG"

# ---- T5: a real directory that is not a repo is refused, not answered --------
RC=0
OUT="$(cd "$NONREPO" && "$WSTATUS" --repo "$NONREPO" 2>&1)" || RC=$?
check_eq "T5: negative control — --repo <not a repo> exits 1" "1" "$RC"
check_contains "T5: and names the target" "$NONREPO" "$OUT"

# ---- T6: usage errors ------------------------------------------------------
RC=0
OUT="$(cd "$NONREPO" && "$WSTATUS" --repo "$TMP/does-not-exist" 2>&1)" || RC=$?
check_eq "T6: --repo path that does not exist is a usage error (2)" "2" "$RC"
check_contains "T6: and says so" "--repo path does not exist" "$OUT"

RC=0
OUT="$(cd "$NONREPO" && "$WSTATUS" --nope 2>&1)" || RC=$?
check_eq "T6: unknown flag is a usage error (2)" "2" "$RC"

RC=0
OUT="$(cd "$NONREPO" && "$WSTATUS" "$LINKED" 2>&1)" || RC=$?
check_eq "T6: a bare positional path is a usage error (2)" "2" "$RC"
check_contains "T6: and suggests the flag" "did you mean --repo" "$OUT"

# ---- T7: detached HEAD is reported, not mistaken for a failure ---------------
DETACHED_WT="$TMP/wt-detached"
git -C "$MAIN" worktree add -q --detach "$DETACHED_WT" "$MAIN_SHA"
RC=0
OUT="$(cd "$NONREPO" && "$WSTATUS" --repo "$DETACHED_WT" 2>&1)" || RC=$?
check_eq "T7: detached HEAD still exits 0" "0" "$RC"
check_contains "T7: DETACHED=true" "DETACHED=true" "$OUT"
# An invented branch name is the failure mode here, so assert the field is
# present AND empty rather than merely absent.
check_eq "T7: BRANCH is present and empty, not invented" "" \
  "$(printf '%s\n' "$OUT" | sed -n 's/^BRANCH=//p')"
check_contains "T7: BRANCH= line is emitted at all" "BRANCH=" "$OUT"

# ---- T7b: a control character in the path — refused in text, escaped in JSON -
# A directory name may legally contain a newline, and the KEY=VALUE protocol
# cannot represent one: emitting it would inject a fake `KEY=` line that a
# consumer's `sed -n 's/^HEAD=//p'` would read as a real field.
CTRL_WT="$TMP/wt-$(printf 'a\tb')-ctl"
if git -C "$MAIN" worktree add -q "$CTRL_WT" -b issue-1470-ctl 2>/dev/null && [[ -d "$CTRL_WT" ]] \
   && [[ "$(cd "$CTRL_WT" && pwd -P)" == *$'\t'* ]]; then
  # The guard on the right proves the filesystem KEPT the tab. Without it, a
  # filesystem that normalizes the name away would make every assertion below
  # pass vacuously against an ordinary path.
  RC=0
  OUT="$(cd "$NONREPO" && "$WSTATUS" --repo "$CTRL_WT" 2>&1)" || RC=$?
  check_eq "T7b: a control character in ROOT is refused by the line protocol" "1" "$RC"
  check_contains "T7b: and names --json as the way to read it" "--json" "$OUT"

  RC=0
  JOUT="$(cd "$NONREPO" && "$WSTATUS" --repo "$CTRL_WT" --json 2>/dev/null)" || RC=$?
  check_eq "T7b: --json still answers for that worktree" "0" "$RC"
  check_not_contains "T7b: and emits no raw control character" "$(printf '\t')" "$JOUT"
  check_contains "T7b: escaping it as \\t instead" '\t' "$JOUT"
  if command -v jq >/dev/null 2>&1; then
    check_eq "T7b: and the JSON parses, round-tripping the real path" \
      "$(cd "$CTRL_WT" && pwd -P)" "$(printf '%s' "$JOUT" | jq -r .root)"
  fi
else
  # Some filesystems reject or normalize such a name; skip rather than fail.
  pass "T7b: SKIP — this filesystem rejects or normalizes a tab in a directory name"
fi

# ---- T7c: a NEWLINE in the path — the truncation case, not just the tab -----
# Sharper than T7b: `head -n 1` on the git capture would silently truncate ROOT
# to its first line, producing a DIFFERENT path that still looks valid and never
# reaches the control-character guard. The refusal (default) and the round-trip
# (--json) together pin that the whole path survives.
NL_WT="$TMP/wt-$(printf 'a\nb')-nl"
if git -C "$MAIN" worktree add -q "$NL_WT" -b issue-1470-nl 2>/dev/null && [[ -d "$NL_WT" ]] \
   && [[ "$(cd "$NL_WT" && pwd -P)" == *$'\n'* ]]; then
  # Same vacuity guard as T7b: the embedded newline must have survived creation.
  RC=0
  OUT="$(cd "$NONREPO" && "$WSTATUS" --repo "$NL_WT" 2>&1)" || RC=$?
  check_eq "T7c: a newline in ROOT is refused by the line protocol" "1" "$RC"
  check_contains "T7c: and names ROOT as the offending field" "ROOT contains a control character" "$OUT"

  RC=0
  JOUT="$(cd "$NONREPO" && "$WSTATUS" --repo "$NL_WT" --json 2>/dev/null)" || RC=$?
  check_eq "T7c: --json still answers" "0" "$RC"
  check_eq "T7c: and the JSON is exactly one line (no injected record)" "1" \
    "$(printf '%s\n' "$JOUT" | wc -l | tr -d ' ')"
  if command -v jq >/dev/null 2>&1; then
    check_eq "T7c: and round-trips the FULL path, untruncated" \
      "$(cd "$NL_WT" && pwd -P)" "$(printf '%s' "$JOUT" | jq -r .root)"
  else
    check_contains "T7c: escaping the newline as \\n (no jq)" '\n' "$JOUT"
  fi
else
  pass "T7c: SKIP — this filesystem rejects or normalizes a newline in a directory name"
fi

# ---- T7d: a TRAILING newline — the other end of the truncation class --------
# `$( )` strips EVERY trailing newline, so a path that ends in one would come
# back silently shortened and pass the control-character guard as a different,
# valid-looking path. The sentinel read in worktree-status.sh is what preserves
# it — and the sentinel idiom is needed HERE too, because the same stripping
# would quietly make both sides of every comparison below equal.
TRAIL_WT="$TMP/wt-trail-x"$'\n'
if git -C "$MAIN" worktree add -q "$TRAIL_WT" -b issue-1470-trail 2>/dev/null && [[ -d "$TRAIL_WT" ]]; then
  # Guard the fixture itself: if the shell or git normalized the name away,
  # every assertion below would pass vacuously.
  TRAIL_REAL="$(cd "$TRAIL_WT" && pwd -P; printf 'x')"
  TRAIL_REAL="${TRAIL_REAL%x}"
  TRAIL_REAL="${TRAIL_REAL%$'\n'}"
  if [[ "$TRAIL_REAL" == *$'\n' ]]; then
    pass "T7d: fixture really ends in a newline"

    RC=0
    OUT="$(cd "$NONREPO" && "$WSTATUS" --repo "$TRAIL_WT" 2>&1)" || RC=$?
    check_eq "T7d: a trailing newline in ROOT is refused, not silently trimmed" "1" "$RC"
    check_contains "T7d: and names ROOT" "ROOT contains a control character" "$OUT"

    if command -v jq >/dev/null 2>&1; then
      JOUT="$(cd "$NONREPO" && "$WSTATUS" --repo "$TRAIL_WT" --json 2>/dev/null)"
      JROOT="$(printf '%s' "$JOUT" | jq -r .root; printf 'x')"
      JROOT="${JROOT%x}"
      JROOT="${JROOT%$'\n'}"
      check_eq "T7d: and --json round-trips it with the newline intact" "$TRAIL_REAL" "$JROOT"
    fi
  else
    pass "T7d: SKIP — the trailing newline did not survive fixture creation"
  fi
else
  pass "T7d: SKIP — this filesystem rejects a trailing newline in a directory name"
fi

# ---- T8: --json carries the same four fields --------------------------------
RC=0
JOUT="$(cd "$NONREPO" && "$WSTATUS" --repo "$LINKED" --json 2>&1)" || RC=$?
check_eq "T8: --json exits 0" "0" "$RC"
if command -v jq >/dev/null 2>&1; then
  check_eq "T8: .head" "$LINKED_SHA" "$(printf '%s' "$JOUT" | jq -r .head)"
  check_eq "T8: .branch" "issue-1470-fixture" "$(printf '%s' "$JOUT" | jq -r .branch)"
  check_eq "T8: .detached is a real boolean" "false" "$(printf '%s' "$JOUT" | jq -r '.detached | tostring')"
else
  check_contains "T8: .head (no jq — substring check)" "\"head\":\"$LINKED_SHA\"" "$JOUT"
fi

# ---- T9: --help answers and writes nothing to stderr ------------------------
HELP_ERR="$TMP/help.err"
RC=0
HELP_OUT="$(cd "$NONREPO" && "$WSTATUS" --help 2>"$HELP_ERR")" || RC=$?
check_eq "T9: --help exits 0" "0" "$RC"
check_eq "T9: --help writes nothing to stderr" "" "$(cat "$HELP_ERR")"
check_contains "T9: --help documents --repo" "--repo <path>" "$HELP_OUT"
check_contains "T9: --help keeps its EXIT STATUS section" "EXIT STATUS" "$HELP_OUT"

# =============================================================================
# wait-until.sh — issue #1470 case 2
#   refused:  until [ "$(gh run view … --jq .status)" = "completed" ]; do sleep 10; done
#   allowed:  wait-until.sh --expect completed -- <check>
# =============================================================================

# ---- T10: condition already true — no wait at all ---------------------------
RC=0
OUT="$("$WAIT" --interval 1 --timeout 5 --quiet -- true 2>/dev/null)" || RC=$?
check_eq "T10: a check that passes immediately exits 0" "0" "$RC"

# ---- T11: negative control — a check that never passes hits the cap ----------
RC=0
ERROUT="$("$WAIT" --interval 1 --timeout 2 -- false 2>&1 >/dev/null)" || RC=$?
check_eq "T11: negative control — never-met condition exits 4 (cap), not 0" "4" "$RC"
check_contains "T11: and says CAP HIT rather than reporting success" "CAP HIT" "$ERROUT"
check_not_contains "T11: and never claims the condition was met" "condition met" "$ERROUT"

# ---- T12: the ticket's exact shape — --expect against a status-printing check -
# Stands in for `until [ "$(gh run view <id> --json status --jq .status)" =
# "completed" ]; do sleep 10; done`: the stub prints "in_progress" twice, then
# "completed", so the wrapper must actually POLL rather than answer on tick 1.
STUB_STATE="$TMP/run-status"
echo 0 > "$STUB_STATE"
cat > "$TMP/gh-run-status" <<EOF
#!/usr/bin/env bash
# Stand-in for: gh run view <id> --json status --jq .status
n=\$(cat "$STUB_STATE")
n=\$((n + 1))
echo "\$n" > "$STUB_STATE"
if [[ "\$n" -ge 3 ]]; then echo "completed"; else echo "in_progress"; fi
EOF
chmod +x "$TMP/gh-run-status"
RC=0
OUT="$("$WAIT" --interval 1 --timeout 20 --expect completed -- "$TMP/gh-run-status" 2>"$TMP/wait.err")" || RC=$?
check_eq "T12: the until-loop shape exits 0 once the status flips" "0" "$RC"
check_eq "T12: and the matched output reaches stdout" "completed" "$OUT"
check_eq "T12: and it really polled (3 checks, not 1)" "3" "$(cat "$STUB_STATE")"
check_contains "T12: and emitted a per-tick heartbeat" "[WAIT] tick 1" "$(cat "$TMP/wait.err")"

# ---- T12b: control — --expect that never matches is NOT reported as met ------
# Without this, an --expect implementation that ignored its argument would pass
# T12 on the very first tick.
echo 0 > "$STUB_STATE"
RC=0
"$WAIT" --interval 1 --timeout 2 --quiet --expect never-this -- "$TMP/gh-run-status" >/dev/null 2>&1 || RC=$?
check_eq "T12b: negative control — a non-matching --expect hits the cap" "4" "$RC"

# ---- T13: negative control — an unlaunchable check is fatal, not polled ------
RC=0
# A BARE name, so this exercises the PATH lookup rather than the file test —
# the typo case the preflight exists for.
ERROUT="$("$WAIT" --interval 1 --timeout 30 -- definitely-not-a-real-binary-1470 2>&1 >/dev/null)" || RC=$?
check_eq "T13: negative control — an unresolvable check exits 3, before polling" "3" "$RC"
check_contains "T13: and names the launch failure" "could not be launched" "$ERROUT"
check_not_contains "T13: and does not disguise it as a cap timeout" "CAP HIT" "$ERROUT"

# ---- T13b: negative control — the preflight decides, not the child's status --
# A check that exits 127 ON PURPOSE must keep polling: reinterpreting the
# CHILD's 126/127 as a launch failure would end the wait early on an ordinary
# not-yet-met result. The preflight is what decides "cannot be launched".
cat > "$TMP/exits127" <<'EOF'
#!/usr/bin/env bash
exit 127
EOF
chmod +x "$TMP/exits127"
RC=0
ERROUT="$("$WAIT" --interval 1 --timeout 2 -- "$TMP/exits127" 2>&1 >/dev/null)" || RC=$?
check_eq "T13b: a check that exits 127 itself polls to the cap (4), not 3" "4" "$RC"
check_not_contains "T13b: and is not misreported as a launch failure" "could not be launched" "$ERROUT"

# A path that exists but is not executable is a launch failure, decided up front.
touch "$TMP/not-executable"
chmod -x "$TMP/not-executable"
RC=0
ERROUT="$("$WAIT" --interval 1 --timeout 30 -- "$TMP/not-executable" 2>&1 >/dev/null)" || RC=$?
check_eq "T13b: a non-executable path exits 3 before any polling" "3" "$RC"
check_contains "T13b: and says so" "not an executable file" "$ERROUT"

# ---- T14: a cap smaller than one interval still costs exactly one check ------
echo 0 > "$STUB_STATE"
RC=0
"$WAIT" --interval 60 --timeout 1 --quiet --expect completed -- "$TMP/gh-run-status" >/dev/null 2>&1 || RC=$?
check_eq "T14: cap < interval exits 4 without sleeping past the cap" "4" "$RC"
check_eq "T14: and ran the check exactly once" "1" "$(cat "$STUB_STATE")"

# ---- T14b: negative control — a HANGING check is killed at the cap ----------
# Without a bound on the check itself, --timeout is a fiction: one wedged call
# holds the caller indefinitely with no output (the issue #1363 shape). The
# elapsed-time assertion is what makes this falsifiable — an unbounded check
# would still "fail" with a non-zero status eventually, but only after 120s.
cat > "$TMP/hangs" <<'EOF'
#!/usr/bin/env bash
sleep 120
EOF
chmod +x "$TMP/hangs"
HANG_START="$(date -u +%s)"
RC=0
ERROUT="$("$WAIT" --interval 1 --timeout 3 -- "$TMP/hangs" 2>&1 >/dev/null)" || RC=$?
HANG_ELAPSED=$(( $(date -u +%s) - HANG_START ))
check_eq "T14b: negative control — a hanging check exits 4 at the cap" "4" "$RC"
check_contains "T14b: and says the check itself was still running" "still running" "$ERROUT"
if (( HANG_ELAPSED <= 20 )); then
  pass "T14b: and returned near the cap (${HANG_ELAPSED}s), not after the check's own 120s"
else
  fail "T14b: overran the cap — took ${HANG_ELAPSED}s, so the check was NOT bounded"
fi
# The killed child must not outlive the run; a survivor would keep polling the
# runner's process table and leak into whatever runs next.
if pgrep -f "$TMP/hangs" >/dev/null 2>&1; then
  fail "T14b: the hanging check survived the kill"
else
  pass "T14b: and the hanging check was actually killed"
fi

# ---- T15: usage errors ------------------------------------------------------
RC=0
OUT="$("$WAIT" 2>&1)" || RC=$?
check_eq "T15: no command is a usage error (2)" "2" "$RC"
check_contains "T15: and says so" "no check command given" "$OUT"

RC=0
OUT="$("$WAIT" --interval 0 -- true 2>&1)" || RC=$?
check_eq "T15: --interval 0 is a usage error (2)" "2" "$RC"

RC=0
OUT="$("$WAIT" --interval abc -- true 2>&1)" || RC=$?
check_eq "T15: non-numeric --interval is a usage error (2)" "2" "$RC"

# A leading zero must be normalized at parse time, not stored raw: `08`/`09` are
# all-digits and pass validation, but every later `$(( ))` reads them as octal,
# where they are not valid literals — the arithmetic errors and the cap silently
# collapses. Exit 4 alone would NOT catch that (a collapsed cap also exits 4), so
# the assertion is on the TICK COUNT: a real 8s cap at a 1s interval polls
# several times, a collapsed one caps before the first tick completes.
RC=0
ERROUT="$("$WAIT" --timeout 08 --interval 01 -- false 2>&1 >/dev/null)" || RC=$?
check_eq "T15: a leading-zero bound still caps (4), not an arithmetic error" "4" "$RC"
LZ_TICKS="$(printf '%s\n' "$ERROUT" | grep -c '\[WAIT\] tick ' || true)"
if (( LZ_TICKS >= 4 )); then
  pass "T15: and the leading-zero bound was read as base 10 ($LZ_TICKS ticks in 8s)"
else
  fail "T15: leading-zero bound collapsed — only $LZ_TICKS tick(s), so 08 was not normalized"
fi

RC=0
OUT="$("$WAIT" --nope -- true 2>&1)" || RC=$?
check_eq "T15: unknown flag is a usage error (2)" "2" "$RC"

# ---- T16: `--` lets a dashed command through --------------------------------
RC=0
OUT="$("$WAIT" --interval 1 --timeout 5 --quiet -- printf -- '%s\n' ready 2>/dev/null)" || RC=$?
check_eq "T16: a command whose args start with a dash runs after --" "0" "$RC"
check_eq "T16: and its stdout is relayed verbatim" "ready" "$OUT"

# ---- T17: --help answers and writes nothing to stderr -----------------------
RC=0
HELP_OUT="$("$WAIT" --help 2>"$HELP_ERR")" || RC=$?
check_eq "T17: --help exits 0" "0" "$RC"
check_eq "T17: --help writes nothing to stderr" "" "$(cat "$HELP_ERR")"
check_contains "T17: --help names gh run watch as the CI shortcut" "gh run watch" "$HELP_OUT"
check_contains "T17: --help keeps its EXIT STATUS section" "EXIT STATUS" "$HELP_OUT"

# =============================================================================
# Documentation contract for the shapes that have no script of their own
# =============================================================================

# ---- T18: the canonical doc exists and covers all three ticket cases ---------
DOC="$REPO_ROOT/.claude/reference/worktree-isolation-command-shapes.md"
if [[ -r "$DOC" ]]; then
  pass "T18: canonical command-shapes doc exists"
  DOC_TEXT="$(cat "$DOC")"
  check_contains "T18: quotes the external refusal verbatim" \
    "too complex to verify that it stays inside the worktree" "$DOC_TEXT"
  check_contains "T18: names the case-1 wrapper" "worktree-status.sh --repo" "$DOC_TEXT"
  check_contains "T18: names the case-2 wrappers" "wait-until.sh" "$DOC_TEXT"
  check_contains "T18: names the CI shortcut" "gh run watch" "$DOC_TEXT"
  check_contains "T18: names the case-3 flag" "admin-merge.sh --repo-path" "$DOC_TEXT"
  check_contains "T18: records the no-git compound escape (bash <file>)" "bash <file>" "$DOC_TEXT"
  check_contains "T18: states the guard is external to this repo" "external to this repository" "$DOC_TEXT"
else
  fail "T18: canonical command-shapes doc missing at $DOC"
fi

# ---- T19: case 3 has no cd-wrapped admin-merge.sh call site to regress -------
# `admin-merge.sh --repo-path` enters the path itself; a `cd` before it is the
# exact shape the guard refuses. This is a structural guard against one being
# reintroduced, and it also pins the claim the doc makes.
# Excluded by FILENAME, not by filtering matched lines: the canonical doc quotes
# the refused form on purpose, but a `grep -v` on its name would also hide a
# genuine violation in any other file whose line happens to mention that doc.
CD_SITES="$(grep -rn --exclude=worktree-isolation-command-shapes.md \
  "cd [^;&|]*&&[^;&|]*admin-merge\.sh" \
  "$REPO_ROOT/.claude/skills" "$REPO_ROOT/.claude/rules" "$REPO_ROOT/.claude/reference" \
  2>/dev/null || true)"
check_eq "T19: no skill/rule/reference wraps admin-merge.sh in a cd" "" "$CD_SITES"

# ---- T20: the two cross-links the doc is meant to replace prose at ----------
check_contains "T20: wrap/SKILL.md Step 2.5 links the canonical doc" \
  "worktree-isolation-command-shapes.md" "$(cat "$REPO_ROOT/.claude/skills/wrap/SKILL.md")"
check_contains "T20: fixpr/SKILL.md links the canonical doc" \
  "worktree-isolation-command-shapes.md" "$(cat "$REPO_ROOT/.claude/skills/fixpr/SKILL.md")"
check_contains "T20: reference/dirty-main-guard.md links the canonical doc" \
  "worktree-isolation-command-shapes.md" "$(cat "$REPO_ROOT/.claude/reference/dirty-main-guard.md")"

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
echo "OK: issue #1470 command shapes — worktree-status.sh (case 1), wait-until.sh (case 2), and the canonical doc contract locked in"
