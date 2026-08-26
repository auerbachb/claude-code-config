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

echo
echo "passed: $PASS  failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
