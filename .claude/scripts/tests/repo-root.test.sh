#!/usr/bin/env bash
# repo-root.test.sh — Offline tests for repo-root.sh's resolution contract and
# its wall-clock bound (issue #1363).
#
# The incident: `git worktree list --porcelain` opens two files per registered
# worktree, and on a filesystem that stalls per file it blocked for 20+ minutes
# with no output — taking admin-merge.sh, /wrap and /merge down silently with
# it. So this suite locks two things: the cheap resolver answers EXACTLY what
# the enumeration used to answer (T1-T8), and a wedged git now fails fast and
# loudly instead of hanging (T9-T12).
#
# Everything runs offline against throwaway git repos; git is stubbed on PATH
# to simulate the stall and to record which subcommands were actually invoked.
#
# Requires git. Run from repo root: bash .claude/scripts/tests/repo-root.test.sh
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SUT="$REPO_ROOT/.claude/scripts/repo-root.sh"
REAL_GIT="$(command -v git)"

TMP="$(mktemp -d)"
cleanup() {
  # Anything the stall stubs left behind dies with the suite, so a failing
  # process-group test cannot leak sleepers into the runner.
  pkill -f "$TMP/bin/stub-sleeper" >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT

# Redirect HOME: repo-root.sh appends to $HOME/.claude/script-usage.log, and the
# temp git identity must not leak into (or depend on) the real ~/.gitconfig.
export HOME="$TMP/home"
mkdir -p "$HOME/.claude"
git config --global user.email "test@example.com"
git config --global user.name "Test"
git config --global init.defaultBranch main

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "ok   — $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL — $1"; }

check_eq() {
  local desc="$1" want="$2" got="$3"
  if [[ "$want" == "$got" ]]; then
    pass "$desc"
  else
    fail "$desc (want '$want', got '$got')"
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

# The historic answer, computed the old way, so every success case is asserted
# against the contract this change had to preserve rather than a hand-written
# expectation.
historic_root() {
  git -C "$1" worktree list --porcelain 2>/dev/null \
    | awk '/^worktree /{sub(/^worktree /, ""); print; exit}'
}

# ---- fixtures ---------------------------------------------------------------
MAIN="$TMP/main"
mkdir -p "$MAIN"
git -C "$MAIN" init -q
echo base > "$MAIN/README.md"
git -C "$MAIN" add README.md
git -C "$MAIN" commit -q -m base
git -C "$MAIN" worktree add -q "$TMP/linked" -b issue-1-linked >/dev/null 2>&1

SPACED="$TMP/with space/repo"
mkdir -p "$SPACED"
git -C "$SPACED" init -q
echo s > "$SPACED/README.md"
git -C "$SPACED" add README.md
git -C "$SPACED" commit -q -m base

BARE="$TMP/bare.git"
git init -q --bare "$BARE"

# `--separate-git-dir` straddles the fast-path test, which keys on the common
# dir's NAME: a separate dir named `.git` passes it, `repo.git` does not. Both
# must still print the historic answer, so the split is invisible to callers.
SEPDOT="$TMP/sepdot/work"
mkdir -p "$TMP/sepdot"
git init -q --separate-git-dir="$TMP/sepdot/elsewhere/.git" "$SEPDOT"
git -C "$SEPDOT" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base

SEPNAMED="$TMP/sepnamed/work"
mkdir -p "$TMP/sepnamed"
git init -q --separate-git-dir="$TMP/sepnamed/elsewhere/repo.git" "$SEPNAMED"
git -C "$SEPNAMED" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base

PLAIN="$TMP/plain"
mkdir -p "$PLAIN"

# ---- T1: main worktree ------------------------------------------------------
OUT="$(cd "$MAIN" && "$SUT" 2>/dev/null)"
check_eq "T1 main worktree resolves to the historic root" "$(historic_root "$MAIN")" "$OUT"

# ---- T2: single-line stdout contract ---------------------------------------
LINES="$(cd "$MAIN" && "$SUT" 2>/dev/null | wc -l | tr -d ' ')"
check_eq "T2 stdout is exactly one line" "1" "$LINES"

# ---- T3: linked worktree resolves to the MAIN root, not its own path -------
OUT="$(cd "$TMP/linked" && "$SUT" 2>/dev/null)"
check_eq "T3 linked worktree resolves to the main root" "$(historic_root "$MAIN")" "$OUT"
if [[ "$OUT" == "$TMP/linked" ]]; then
  fail "T3b linked worktree must not return its own path"
else
  pass "T3b linked worktree does not return its own path"
fi

# ---- T4: [path] argument ----------------------------------------------------
OUT="$(cd "$PLAIN" && "$SUT" "$TMP/linked" 2>/dev/null)"
check_eq "T4 [path] argument resolves from another worktree" "$(historic_root "$MAIN")" "$OUT"

# ---- T5: whitespace in the path (the reason porcelain was adopted) ---------
OUT="$(cd "$SPACED" && "$SUT" 2>/dev/null)"
check_eq "T5 path containing a space survives intact" "$(historic_root "$SPACED")" "$OUT"

# ---- T6: bare repo still answers the historic way (fallback path) ----------
OUT="$(cd "$BARE" && "$SUT" 2>/dev/null)"
check_eq "T6 bare repo keeps the historic answer" "$(historic_root "$BARE")" "$OUT"

# ---- T6b/T6c: --separate-git-dir keeps the historic answer on BOTH sides ---
# of the fast-path name test. T6b takes the fast path (common dir is named
# `.git`); T6c falls through to the enumeration (`repo.git`). Asserting both
# against historic_root is what makes the name-based split safe: the two paths
# have to agree, not merely be reachable.
OUT="$(cd "$SEPDOT" && "$SUT" 2>/dev/null)"
check_eq "T6b separate-git-dir named .git keeps the historic answer" \
  "$(historic_root "$SEPDOT")" "$OUT"

OUT="$(cd "$SEPNAMED" && "$SUT" 2>/dev/null)"
check_eq "T6c separate-git-dir named repo.git keeps the historic answer" \
  "$(historic_root "$SEPNAMED")" "$OUT"

# ---- T7: not a git repo -> exit 1, named cause -----------------------------
RC=0
ERR="$(cd "$PLAIN" && "$SUT" 2>&1 >/dev/null)" || RC=$?
check_eq "T7 non-repo exits 1" "1" "$RC"
check_contains "T7b non-repo names the cause" "not inside a git repo" "$ERR"

# ---- T8: usage errors -------------------------------------------------------
RC=0
ERR="$(cd "$MAIN" && "$SUT" --bogus 2>&1 >/dev/null)" || RC=$?
check_eq "T8 unknown flag exits 2" "2" "$RC"
check_contains "T8b unknown flag names the flag" "unknown flag: --bogus" "$ERR"

RC=0
(cd "$MAIN" && "$SUT" a b) >/dev/null 2>&1 || RC=$?
check_eq "T8c two positional args exit 2" "2" "$RC"

RC=0
HELP="$(cd "$MAIN" && "$SUT" --help 2>&1)" || RC=$?
check_eq "T8d --help exits 0" "0" "$RC"
check_contains "T8e --help documents the timeout exit code" "3  Timed out" "$HELP"
check_contains "T8f --help documents the exit-4 contract" \
  "4  Nothing could be determined" "$HELP"
# Exit 4 covers two causes and the help has to name BOTH, or a caller reading it
# learns only the half that happened to be written first.
check_contains "T8g --help still names git as an exit-4 cause" \
  "git could not run" "$HELP"
check_contains "T8h --help names the helpers the script itself needs" \
  "REQUIREMENTS" "$HELP"

# ---- T9: the happy path must not enumerate worktrees -----------------------
# This is the regression itself: the incident was one `git worktree list` over
# 62 registered entries. A recording stub proves the subcommand is never
# reached when common-dir resolution succeeds.
STUB="$TMP/bin"
mkdir -p "$STUB"
export GIT_ARGV_LOG="$TMP/git-argv.log"
export REAL_GIT
cat > "$STUB/git" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GIT_ARGV_LOG"
exec "$REAL_GIT" "$@"
EOF
chmod +x "$STUB/git"

: > "$GIT_ARGV_LOG"
OUT="$(cd "$MAIN" && PATH="$STUB:$PATH" "$SUT" 2>/dev/null)"
ARGV="$(cat "$GIT_ARGV_LOG")"
check_eq "T9 recording stub still returns the historic root" "$(historic_root "$MAIN")" "$OUT"
check_contains "T9b happy path calls rev-parse --git-common-dir" "--git-common-dir" "$ARGV"
check_not_contains "T9c happy path never enumerates worktrees" "worktree list" "$ARGV"

: > "$GIT_ARGV_LOG"
(cd "$TMP/linked" && PATH="$STUB:$PATH" "$SUT" >/dev/null 2>&1) || true
ARGV="$(cat "$GIT_ARGV_LOG")"
# The `|| true` above swallows a total SUT failure, and check_not_contains
# passes on an empty log — so assert the stub was reached at all before
# asserting what it did not see.
check_contains "T9d the stub was actually reached from the linked worktree" \
  "--git-common-dir" "$ARGV"
check_not_contains "T9e linked worktree never enumerates worktrees" \
  "worktree list" "$ARGV"

# ---- T10: a wedged git fails fast, loudly, with exit 3 ---------------------
# The stub also spawns a descendant that keeps ticking, so the assertions below
# can tell "we killed the process group" from "we killed one pid and walked
# away while its children kept the stalled handles open".
export TICK_FILE="$TMP/tick"
cat > "$STUB/stub-sleeper" <<'EOF'
#!/usr/bin/env bash
# Descendant of the stubbed git: ticks until killed, self-limited so a failing
# process-group kill cannot leave a sleeper behind for the rest of the run.
for _ in $(seq 1 50); do
  printf 'tick\n' >> "$TICK_FILE"
  sleep 0.2
done
EOF
chmod +x "$STUB/stub-sleeper"

cat > "$STUB/git" <<'EOF'
#!/usr/bin/env bash
"$STUB/stub-sleeper" &
sleep 30
EOF
chmod +x "$STUB/git"
export STUB

# A 3s bound, not 1s: `date +%s` is whole-second, so an N-second bound can trip
# anywhere in (N-1, N] of real time — at N=1 the kill can land ~20ms in, before
# the descendant below has even been exec'd, and T11 would measure nothing.
: > "$TICK_FILE"
START="$(date +%s)"
RC=0
ERR="$(cd "$MAIN" && PATH="$STUB:$PATH" REPO_ROOT_TIMEOUT_SECS=3 "$SUT" 2>&1 >/dev/null)" || RC=$?
ELAPSED=$(( $(date +%s) - START ))

check_eq "T10 wedged git exits 3 (timeout), not 0 and not a hang" "3" "$RC"
check_contains "T10b diagnostic names the bound that tripped" "timed out after 3s" "$ERR"
check_contains "T10c diagnostic names the command that was killed" "git rev-parse" "$ERR"
if (( ELAPSED < 15 )); then
  pass "T10d returned in ${ELAPSED}s, well inside the bound + grace"
else
  fail "T10d took ${ELAPSED}s — the bound did not hold"
fi

# ---- T11: the kill reaches the whole process group -------------------------
# The sleeper self-limits at 50 ticks (~10s) and T10 returned in ~4s, so the
# sampling window below must sit strictly INSIDE its natural life — an unkilled
# descendant would still be ticking there. Both bounds matter: 0 ticks means it
# never started, and 50 means it had already finished on its own, which is what
# happens against the unbounded pre-change script (it waits out the full 30s
# stub) and would make T11b pass without any kill having occurred.
BEFORE="$(wc -l < "$TICK_FILE" | tr -d ' ')"
if (( BEFORE > 0 && BEFORE < 50 )); then
  pass "T11 descendant sampled mid-life (${BEFORE}/50 ticks), so T11b is a live check"
else
  fail "T11 descendant at ${BEFORE}/50 ticks — outside its life, T11b would pass vacuously"
fi
sleep 2
AFTER="$(wc -l < "$TICK_FILE" | tr -d ' ')"
check_eq "T11b descendants of the killed git stop ticking too" "$BEFORE" "$AFTER"

# ---- T12: the enumeration fallback is bounded as well ----------------------
# Forward everything to real git EXCEPT `worktree list`, and point it at the
# bare repo so resolution has to reach the fallback.
cat > "$STUB/git" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do
  if [[ "$a" == "list" ]]; then sleep 30; fi
done
exec "$REAL_GIT" "$@"
EOF
chmod +x "$STUB/git"

START="$(date +%s)"
RC=0
ERR="$(cd "$BARE" && PATH="$STUB:$PATH" REPO_ROOT_TIMEOUT_SECS=1 "$SUT" 2>&1 >/dev/null)" || RC=$?
ELAPSED=$(( $(date +%s) - START ))
check_eq "T12 wedged fallback exits 3 too" "3" "$RC"
check_contains "T12b fallback diagnostic names worktree list" "git worktree list --porcelain" "$ERR"
if (( ELAPSED < 15 )); then
  pass "T12c fallback returned in ${ELAPSED}s"
else
  fail "T12c fallback took ${ELAPSED}s — the bound did not hold"
fi

# ---- T13: a junk bound falls back to the default, never to "no bound" ------
OUT="$(cd "$MAIN" && REPO_ROOT_TIMEOUT_SECS=abc "$SUT" 2>/dev/null)"
check_eq "T13 non-numeric REPO_ROOT_TIMEOUT_SECS still resolves" "$(historic_root "$MAIN")" "$OUT"

# Zero must not read as "no bound". Re-install the stalling-enumeration stub
# here rather than relying on T12 having left it in place — an ordering
# dependency would let a block inserted above change what this test means
# without failing it. The bare repo forces resolution to reach the fallback.
cat > "$STUB/git" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do
  if [[ "$a" == "list" ]]; then sleep 30; fi
done
exec "$REAL_GIT" "$@"
EOF
chmod +x "$STUB/git"

RC=0
ERR="$(cd "$BARE" && PATH="$STUB:$PATH" REPO_ROOT_TIMEOUT_SECS=0 "$SUT" 2>&1 >/dev/null)" || RC=$?
check_eq "T13b zero bound is rejected, not treated as unbounded" "3" "$RC"
check_contains "T13c zero bound falls back to the 10s default" "timed out after 10s" "$ERR"

# The failure class that plain digit-validation misses: `08` and `09` are
# all-digits and pass `-gt 0`, but `(( ))` reads a leading zero as octal, where
# they are not valid literals — the arithmetic errors, the comparison is false
# on every pass, and the bound silently disappears. `010` is worse in a quieter
# way: accepted, silently meaning 8, while the diagnostic prints "010s".
START="$(date +%s)"
RC=0
ERR="$(cd "$BARE" && PATH="$STUB:$PATH" REPO_ROOT_TIMEOUT_SECS=08 "$SUT" 2>&1 >/dev/null)" || RC=$?
ELAPSED=$(( $(date +%s) - START ))
check_eq "T13d leading-zero bound (08) still bounds the call" "3" "$RC"
check_contains "T13e leading-zero bound is normalized to decimal in the message" \
  "timed out after 8s" "$ERR"
check_not_contains "T13f arithmetic never errors on the octal-looking value" \
  "value too great for base" "$ERR"
if (( ELAPSED < 20 )); then
  pass "T13g leading-zero bound returned in ${ELAPSED}s"
else
  fail "T13g leading-zero bound took ${ELAPSED}s — the bound did not hold"
fi

# ---- T14: an unreadable clock must not silently remove the bound -----------
# Inside `(( ))` an empty variable is 0, so a blank `date` result would make the
# elapsed-time comparison go negative and never trip — the bound would vanish
# without a word. Fail closed instead, and say which failure it was.
cat > "$STUB/git" <<'EOF'
#!/usr/bin/env bash
sleep 30
EOF
chmod +x "$STUB/git"
cat > "$STUB/date" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$STUB/date"

START="$(date +%s)"
RC=0
ERR="$(cd "$MAIN" && PATH="$STUB:$PATH" REPO_ROOT_TIMEOUT_SECS=5 "$SUT" 2>&1 >/dev/null)" || RC=$?
ELAPSED=$(( $(date +%s) - START ))
check_eq "T14 unreadable clock exits 3, not an unbounded wait" "3" "$RC"
check_contains "T14b diagnostic names the clock, not a fake elapsed time" \
  "could not read the clock" "$ERR"
check_not_contains "T14c does not claim an elapsed-time timeout" "timed out after" "$ERR"
if (( ELAPSED < 15 )); then
  pass "T14d returned in ${ELAPSED}s instead of waiting out the stalled call"
else
  fail "T14d took ${ELAPSED}s — the bound did not hold without a clock"
fi
rm -f "$STUB/date"

# ---- T15: git that cannot run at all -> exit 4, never exit 1 ---------------
# The split issue #1403 asked for. "not a git repo" (1) is a DETERMINATE answer
# a caller may act on; "git never started" is not, and admin-merge.sh's fallback
# chain keys on that difference. Both fixtures below are REAL exec failures, not
# a stub that hardcodes an rc: the shell decides 126/127 before any git code
# runs, which is exactly the signal the script keys on.
#
# A dedicated stub dir, not the shared $STUB: every earlier group rewrites
# $STUB/git, so reusing it would make this group's meaning depend on which
# block last ran above.
NOGIT="$TMP/nogit"
mkdir -p "$NOGIT"

# 126 — the file is there and executable, but its interpreter is not, so exec
# fails. This is the "not executable / unusable binary" half of the contract.
cat > "$NOGIT/git" <<'EOF'
#!/nonexistent/interpreter
echo unreachable
EOF
chmod +x "$NOGIT/git"

RC=0
ERR="$(cd "$MAIN" && PATH="$NOGIT:$PATH" "$SUT" 2>&1 >/dev/null)" || RC=$?
check_eq "T15 an unexecutable git exits 4, not 1" "4" "$RC"
check_contains "T15b diagnostic names the cause" "git could not run" "$ERR"
# Assert the path of the git we broke — the ONLY token both platforms emit.
# Bash words this failure two incompatible ways, and neither half is portable:
#   macOS: <stub>: /nonexistent/interpreter: bad interpreter: No such file...
#   Linux: <stub>: cannot execute: required file not found
# So "bad interpreter" is absent on Linux (it is also gettext-translated —
# fr prints "mauvais interpréteur"), and "/nonexistent/interpreter" is absent
# on Linux, which never names the interpreter at all. Only the stub's own path
# appears in both. It is a value this test owns, no locale rewrites it, and it
# is the detail an operator acts on. Same reasoning as T15g below, which
# asserts the missing binary's name rather than the wording around it.
check_contains "T15c the exec failure itself is relayed" "$NOGIT/git" "$ERR"
# The negative control that makes T15 mean something: before this change every
# one of these landed on the determinate non-repo sentence, which is what let
# callers substitute a guess.
check_not_contains "T15d never claims the directory is not a repo" \
  "not inside a git repo" "$ERR"

# 127 — the command cannot be found. Produced genuinely by exec'ing a missing
# binary from inside the stub (the shell emits its own "command not found" and
# exits 127), because emptying PATH to remove git would also remove the date,
# awk and mktemp the script legitimately needs.
cat > "$NOGIT/git" <<'EOF'
#!/usr/bin/env bash
exec definitely-not-a-real-git-binary-xyz "$@"
EOF
chmod +x "$NOGIT/git"

RC=0
ERR="$(cd "$MAIN" && PATH="$NOGIT:$PATH" "$SUT" 2>&1 >/dev/null)" || RC=$?
check_eq "T15e a git that cannot be found exits 4" "4" "$RC"
check_contains "T15f rc-127 diagnostic names the cause" "git could not run" "$ERR"
# Assert the name the shell could not find, not the wording around it: `exec`
# says "not found" where a plain command says "command not found", and the
# prefix differs again on Linux. The name is what an operator acts on.
check_contains "T15g the shell's own message is relayed" \
  "definitely-not-a-real-git-binary-xyz" "$ERR"
# The helper guard exercised by T16 must not preempt this diagnosis: when git is
# the broken thing, the message has to name git rather than blaming helpers that
# are all present. Without this control the guard could pass T16 by firing on
# every run.
check_not_contains "T15l a broken git is diagnosed as git, not as a missing helper" \
  "required helper" "$ERR"

# With an explicit [path] argument the message must name that path, not the cwd
# — the operator's next move depends on which one git failed to read.
RC=0
ERR="$(cd "$PLAIN" && PATH="$NOGIT:$PATH" "$SUT" "$MAIN" 2>&1 >/dev/null)" || RC=$?
check_eq "T15h [path] argument also exits 4" "4" "$RC"
check_contains "T15i diagnostic names the target path, not the cwd" "$MAIN" "$ERR"

# The other half of the split: a genuinely non-git directory must STILL exit 1
# with the determinate sentence while a real git is on PATH. Without this, an
# implementation that returned 4 for every failure would pass T15 and quietly
# break every caller that acts on the determinate answer.
RC=0
ERR="$(cd "$PLAIN" && "$SUT" 2>&1 >/dev/null)" || RC=$?
check_eq "T15j a real non-repo still exits 1, so the split is a split" "1" "$RC"
check_not_contains "T15k non-repo is never reported as a broken git" \
  "git could not run" "$ERR"

# ---- T16: a missing HELPER is also "nothing determined" (4), not the shell's
# ---- own 127 ---------------------------------------------------------------
# Besides git, repo-root.sh calls mktemp, awk, head, date, sleep, dirname and
# basename. Before the guard, the first absent one killed the run through
# `set -e` at the `mktemp`, and what reached the caller was the SHELL's 127 — a
# status the contract never named. admin-merge.sh refuses only on 3 and 4 and
# reads everything else as determinate, so 127 took its `git rev-parse` / $PWD
# fallback: the exact substitution the exit-4 split exists to prevent, reached
# through the one door the split had left open.
#
# The fixture is a REAL environment, not a stub that hardcodes a status: a
# directory of genuine symlinks used as the entire PATH, with the helper under
# test simply absent. `bash` is included deliberately — the shebang is
# `#!/usr/bin/env bash`, so without it the failure lands at interpreter
# resolution and the script never starts, which is a different case and not one
# this script can answer from the inside.
# The fixture carries every command the script touches — ps, tr, sed and rm
# included — so that removing one really is the only absence, and a failure
# cannot be blamed on a helper the fixture merely forgot.
NOHELP="$TMP/nohelp"
mkdir -p "$NOHELP"
populate_helpers() { # dir
  local d="$1" h hp
  for h in bash git mktemp awk head date sleep dirname basename ps tr rm sed; do
    hp="$(command -v "$h" 2>/dev/null)" && ln -sf "$hp" "$d/$h"
  done
}
populate_helpers "$NOHELP"

# Drop exactly ONE helper — CodeAnt's reported case — so this proves the guard
# fires on a single absence rather than only on a wholesale wipe. git is still
# present and working here, which is what makes the exit-4 meaningful: the run
# failed on the environment, not on the repo.
rm -f "$NOHELP/mktemp"
RC=0
ERR="$(cd "$MAIN" && env -i HOME="$HOME" PATH="$NOHELP" TMPDIR=/tmp "$SUT" 2>&1 >/dev/null)" || RC=$?
check_eq "T16 a missing mktemp exits 4, not the shell's 127" "4" "$RC"
check_contains "T16b the diagnostic names the helper that is missing" "mktemp" "$ERR"
# The negative control that gives T16 its meaning: 127 used to escape here, and
# exit 1 would be worse still — both let a caller act on a non-answer.
check_not_contains "T16c never claims the directory is not a repo" \
  "not inside a git repo" "$ERR"

# A wholesale wipe (only the interpreter left) must report the same way, and
# must name the helpers rather than dying at whichever one the code reaches
# first — the guard runs before any of them is called.
BAREBIN="$TMP/barebin"
mkdir -p "$BAREBIN"
ln -sf "$(command -v bash)" "$BAREBIN/bash"
RC=0
ERR="$(cd "$MAIN" && env -i HOME="$HOME" PATH="$BAREBIN" TMPDIR=/tmp "$SUT" 2>&1 >/dev/null)" || RC=$?
check_eq "T16d a wholesale PATH wipe also exits 4" "4" "$RC"
check_contains "T16e the diagnostic lists the missing helpers" "awk" "$ERR"
# The header promises "stderr: one-line error message on failure". The usage-log
# line runs before the preflight, so if it calls helpers unguarded the shell
# narrates the broken PATH first and an operator gets three messages where the
# contract promised one. Count the lines rather than trusting the wording.
check_eq "T16e2 stderr is exactly one line, per the OUTPUT contract" \
  "1" "$(printf '%s\n' "$ERR" | grep -c .)"
check_not_contains "T16e3 no raw shell command-not-found reaches stderr" \
  "command not found" "$ERR"

# `rm` is required for a non-obvious reason and needs its own case: it runs only
# in the EXIT trap, but a failing trap overwrites the status. Unguarded, this
# run printed the CORRECT root on stdout and still exited 127 — the worst shape,
# because admin-merge.sh discards a right answer on a non-{0,3,4} status.
rm -rf "$NOHELP"; mkdir -p "$NOHELP"; populate_helpers "$NOHELP"
rm -f "$NOHELP/rm"
RC=0
OUT="$(cd "$MAIN" && env -i HOME="$HOME" PATH="$NOHELP" TMPDIR=/tmp "$SUT" 2>/dev/null)" || RC=$?
check_eq "T16f a missing rm exits 4, not 127-with-a-correct-answer" "4" "$RC"
check_eq "T16f2 and prints nothing, rather than an answer the caller must discard" "" "$OUT"

# ---- T16g/T16h: the guard must NOT over-reach ------------------------------
# `ps` and `tr` are used by kill_child, and a reviewer proposed requiring them.
# They are deliberately excluded: their absence is absorbed by design — the pgid
# lookup yields empty, the group kill is skipped, and the builtin single-pid
# `kill` still stops the child. Requiring them would refuse to resolve in an
# environment where the script works. These pin the decline so it is not
# "completed" by reflex later; if the exclusion is ever revisited, these are the
# assertions that must be argued with.
for drop in ps tr; do
  rm -rf "$NOHELP"; mkdir -p "$NOHELP"; populate_helpers "$NOHELP"
  rm -f "$NOHELP/$drop"
  RC=0
  OUT="$(cd "$MAIN" && env -i HOME="$HOME" PATH="$NOHELP" TMPDIR=/tmp "$SUT" 2>/dev/null)" || RC=$?
  if [[ "$drop" == "ps" ]]; then
    check_eq "T16g a missing ps still resolves (exit 0), guard does not fire" "0" "$RC"
    check_eq "T16g2 and the answer is still the historic root" "$(historic_root "$MAIN")" "$OUT"
  else
    check_eq "T16h a missing tr still resolves (exit 0), guard does not fire" "0" "$RC"
    check_eq "T16h2 and the answer is still the historic root" "$(historic_root "$MAIN")" "$OUT"
  fi
done

echo
echo "passed: $PASS  failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
