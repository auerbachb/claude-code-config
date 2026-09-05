#!/usr/bin/env bash
# Unit tests for pipefail-grep-q-lint.sh (issue #1648)
#
# Auto-discovered by run-hook-tests.sh — no workflow edit needed.
# Hermetic-fixture pattern, following zsh-special-name-lint.test.sh.
#
# Three layers, because a lint that only proves it stays quiet proves nothing:
#
#   Part 1  fixture behaviour — the hazardous shapes must FAIL, the look-alike
#           shapes (grep -c / -v, `||`, single-quoted data, quoted heredocs,
#           comments, files without pipefail) must PASS, the waiver must work
#           and a bare waiver must be rejected, and every canary must trip.
#   Part 2  real-corpus controls — the live repo passes, AND a planted pre-fix
#           assertion makes it fail. Without the second half the first half is
#           satisfied by a lint that can never fire.
#   Part 3  runtime proof: the hazard is real. A producer larger than the pipe
#           buffer piped into `grep -q` under pipefail returns NON-ZERO on a
#           successful match, and the here-string form returns 0 on the same
#           data. This is the mechanism the lint exists to keep out.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)" || { echo "cannot resolve repo root" >&2; exit 1; }
LINT="${REPO_ROOT}/.github/scripts/pipefail-grep-q-lint.sh"

if [ ! -f "$LINT" ]; then
  echo "FAIL — lint script not found at $LINT"
  exit 1
fi

TMP_ROOT="$(mktemp -d -t pipefail-grep-q-lint.XXXXXX)"
PLANT=""
cleanup() {
  rm -rf "$TMP_ROOT"
  [ -n "$PLANT" ] && [ -f "$PLANT" ] && rm -f "$PLANT"
  return 0
}
trap cleanup EXIT

failures=0
case_num=0

ok()   { echo "ok   — $1"; }
bad()  { echo "FAIL — $1"; failures=$((failures + 1)); }

# A minimal fixture: one clean pipefail script carrying a safe here-string grep
# AND a read-to-EOF `| grep -c` pipeline, so both canaries (a pipefail file was
# scanned, a grep pipeline was examined) are satisfied and each case only adds
# what it is testing.
make_fixture() {
  local dir="$1"
  mkdir -p "$dir/scripts"
  cat > "$dir/scripts/clean.sh" <<'CLEAN'
#!/usr/bin/env bash
set -uo pipefail
out="$(printf 'alpha\nbeta\n')"
grep -q alpha <<<"$out" || exit 1
count=$(printf '%s\n' "$out" | grep -c a)
echo "$count"
CLEAN
}

# expect NAME WANT_EXIT WANT_REGEX  (fixture body arrives on stdin as extra.sh)
expect() {
  local name="$1" want="$2" want_re="$3"
  case_num=$((case_num + 1))
  local dir="${TMP_ROOT}/case${case_num}"
  make_fixture "$dir"
  cat > "$dir/scripts/extra.sh"

  local out got
  out=$(cd "$dir" && bash "$LINT" 2>&1) && got=0 || got=$?

  if [ "$got" -ne "$want" ]; then
    bad "${name}: expected exit ${want}, got ${got}"
    sed 's/^/       /' <<<"$out"
    return
  fi
  if [ -n "$want_re" ] && ! grep -qE "$want_re" <<<"$out"; then
    bad "${name}: exit ${got} as expected, but output did not match /${want_re}/"
    sed 's/^/       /' <<<"$out"
    return
  fi
  ok "$name"
}

HIT='producer piped into an early-exit grep'

echo "=== Part 1: fixture behaviour ==="

# --- hazardous shapes: must FAIL --------------------------------------------

expect "printf piped into grep -q under pipefail is a finding" 1 "$HIT" <<'FIX'
#!/usr/bin/env bash
set -uo pipefail
big="$1"
printf '%s\n' "$big" | grep -q needle || echo missing
FIX

expect "echo piped into grep -qE is a finding" 1 "$HIT" <<'FIX'
#!/usr/bin/env bash
set -euo pipefail
if echo "$out" | grep -qE '^ok'; then echo yes; fi
FIX

expect "a command piped into grep --quiet is a finding" 1 "$HIT" <<'FIX'
#!/usr/bin/env bash
set -o pipefail
launchctl list | grep --quiet "$LABEL" && echo running
FIX

expect "q buried in an option cluster (-Eqi) is a finding" 1 "$HIT" <<'FIX'
#!/usr/bin/env bash
set -uo pipefail
"$SCRIPT" | grep -Eqi 'due' || echo no
FIX

expect "-q after the pattern is a finding" 1 "$HIT" <<'FIX'
#!/usr/bin/env bash
set -uo pipefail
cat "$f" | grep needle -q || echo no
FIX

expect "a pipeline inside a double-quoted eval string is a finding" 1 "$HIT" <<'FIX'
#!/usr/bin/env bash
set -uo pipefail
assert() { eval "$2"; }
assert "reports PASS" "printf '%s' \"\$out\" | grep -q '^PASS:'"
FIX

expect "a pipeline on the same line as set -o pipefail is a finding" 1 "$HIT" <<'FIX'
#!/usr/bin/env bash
set -o pipefail; printf '%s\n' "$big" | grep -q needle
FIX

expect "a quoted # before the pipe does not hide it" 1 "$HIT" <<'FIX'
#!/usr/bin/env bash
set -uo pipefail
echo "$x # not a comment" | grep -q needle
printf '%s\n' "#tag $y" | grep -q needle
FIX

expect "re-enabling after set +o pipefail re-arms the scan" 1 'extra\.sh:6:' <<'FIX'
#!/usr/bin/env bash
set -uo pipefail
set +o pipefail
printf '%s\n' "$big" | grep -q needle
set -o pipefail
printf '%s\n' "$big" | grep -q needle
FIX

expect "separated options (set -e -o pipefail) arm the scan" 1 "$HIT" <<'FIX'
#!/usr/bin/env bash
set -e -u -o pipefail
printf '%s\n' "$big" | grep -q needle
FIX

expect "a comment opened right after ; is stripped before the pipe is judged" 0 'OK' <<'FIX'
#!/usr/bin/env bash
set -uo pipefail
echo start;# was: printf '%s\n' "$big" | grep -q needle
FIX

expect "a quoted-heredoc OPENER line is still scanned" 1 'extra\.sh:3:' <<'FIX'
#!/usr/bin/env bash
set -uo pipefail
cat <<'STUB' | grep -q needle
printf '%s\n' "$big" | grep -q needle
STUB
FIX

expect "the marker inside a string literal is not a waiver" 1 "$HIT" <<'FIX'
#!/usr/bin/env bash
set -uo pipefail
msg="# pipefail-grep-ok: not a comment"; printf '%s\n' "$big" | grep -q needle
FIX

expect "a pipeline split across a backslash-continued line is a finding" 1 'extra\.sh:3:' <<'FIX'
#!/usr/bin/env bash
set -uo pipefail
printf '%s\n' "$(jq -r .title "$f")" \
  | grep -qi needle || echo missing
FIX

expect "set glued to a control operator (;set -o pipefail) arms the scan" 1 "$HIT" <<'FIX'
#!/usr/bin/env bash
cd "$dir";set -o pipefail
printf '%s\n' "$big" | grep -q needle
FIX

expect "|& grep -q is a finding" 1 "$HIT" <<'FIX'
#!/usr/bin/env bash
set -uo pipefail
"$SCRIPT" |& grep -q 'warning' && echo warned
FIX

expect "the finding names the file and line" 1 'extra\.sh:4:' <<'FIX'
#!/usr/bin/env bash
set -uo pipefail
x=1
printf '%s\n' "$big" | grep -q needle
FIX

expect "the finding points at the here-string fix" 1 'grep -q pattern <<<' <<'FIX'
#!/usr/bin/env bash
set -uo pipefail
printf '%s\n' "$big" | grep -q needle
FIX

# --- look-alikes: must PASS -------------------------------------------------

expect "the same shape without pipefail is not a finding" 0 'OK' <<'FIX'
#!/usr/bin/env bash
set -u
printf '%s\n' "$big" | grep -q needle || echo missing
FIX

expect "the shape BEFORE the pipefail line is not a finding" 0 'OK' <<'FIX'
#!/usr/bin/env bash
printf '%s\n' "$big" | grep -q needle || echo missing
set -uo pipefail
echo after
FIX

expect "the shape after set +o pipefail is not a finding" 0 'OK' <<'FIX'
#!/usr/bin/env bash
set -uo pipefail
set +o pipefail
printf '%s\n' "$big" | grep -q needle || echo missing
FIX

expect "separated disable (set +e +o pipefail) disarms the scan" 0 'OK' <<'FIX'
#!/usr/bin/env bash
set -euo pipefail
set +e +o pipefail
printf '%s\n' "$big" | grep -q needle || echo missing
FIX

expect "| grep -c reads to EOF and is not a finding" 0 'OK' <<'FIX'
#!/usr/bin/env bash
set -uo pipefail
n=$(printf '%s\n' "$big" | grep -c needle)
FIX

expect "| grep -v is not a finding" 0 'OK' <<'FIX'
#!/usr/bin/env bash
set -uo pipefail
printf '%s\n' "$big" | grep -v noise
FIX

expect "a plain | grep pattern is not a finding" 0 'OK' <<'FIX'
#!/usr/bin/env bash
set -uo pipefail
printf '%s\n' "$big" | grep needle
FIX

expect "|| grep -q is an OR, not a pipe" 0 'OK' <<'FIX'
#!/usr/bin/env bash
set -uo pipefail
grep -q a <<<"$out" || grep -q a "$file"
FIX

expect "a here-string grep -q is the fixed shape" 0 'OK' <<'FIX'
#!/usr/bin/env bash
set -uo pipefail
grep -q needle <<<"$big" || echo missing
grep -q needle <<<"$(producer --flag)" || echo missing
FIX

expect "| grep -q inside single quotes is data, not code" 0 'OK' <<'FIX'
#!/usr/bin/env bash
set -uo pipefail
check "never leaks" sh -c '! printf "%s" "$1" | grep -q ghp_SECRET' _ "$DOC"
classify 'until gh api x | grep -q true; do sleep 60; done'
FIX

expect "| grep -q inside a quoted heredoc body is not a finding" 0 'OK' <<'FIX'
#!/usr/bin/env bash
set -uo pipefail
cat > "$stub" <<'STUB'
printf '%s\n' "$big" | grep -q needle
STUB
FIX

expect "pipefail that is only heredoc text does not arm the gate" 0 'OK' <<'FIX'
#!/usr/bin/env bash
cat > "$stub" <<'STUB'
set -uo pipefail
STUB
printf '%s\n' "$big" | grep -q needle
FIX

expect "a commented-out pipeline is not a finding" 0 'OK' <<'FIX'
#!/usr/bin/env bash
set -uo pipefail
# was: printf '%s\n' "$big" | grep -q needle
echo "$x" # printf '%s\n' "$big" | grep -q needle
FIX

expect "grep -q on a file with no pipe is not a finding" 0 'OK' <<'FIX'
#!/usr/bin/env bash
set -uo pipefail
grep -q needle "$file" || echo missing
FIX

# --- waiver -----------------------------------------------------------------

expect "a waiver with a reason suppresses the finding" 0 'OK.*1 waived' <<'FIX'
#!/usr/bin/env bash
set -uo pipefail
printf '%s\n' "$big" | grep -q needle  # pipefail-grep-ok: deliberate repro of the hazard
FIX

expect "a bare waiver marker is itself an error" 1 'no reason after the colon' <<'FIX'
#!/usr/bin/env bash
set -uo pipefail
printf '%s\n' "$big" | grep -q needle  # pipefail-grep-ok
FIX

expect "a waiver marker with an empty reason is an error" 1 'no reason after the colon' <<'FIX'
#!/usr/bin/env bash
set -uo pipefail
printf '%s\n' "$big" | grep -q needle  # pipefail-grep-ok:
FIX

# --- canaries ---------------------------------------------------------------

case_num=$((case_num + 1))
empty_dir="${TMP_ROOT}/case${case_num}"
mkdir -p "$empty_dir/docs"
if out=$(cd "$empty_dir" && bash "$LINT" 2>&1); then
  bad "no shell files: expected exit 1, got 0"
else
  if grep -q 'found no shell files' <<<"$out"; then
    ok "no shell files trips the discovery canary"
  else
    bad "no shell files: exit non-zero but output did not name the canary: $out"
  fi
fi

case_num=$((case_num + 1))
nopf_dir="${TMP_ROOT}/case${case_num}"
mkdir -p "$nopf_dir/scripts"
cat > "$nopf_dir/scripts/plain.sh" <<'PLAIN'
#!/usr/bin/env bash
set -u
printf '%s\n' "$big" | grep -q needle
PLAIN
if out=$(cd "$nopf_dir" && bash "$LINT" 2>&1); then
  bad "no pipefail file: expected exit 1, got 0"
else
  if grep -q "none enabled 'set -o pipefail'" <<<"$out"; then
    ok "shell files but no pipefail trips the gate canary"
  else
    bad "no pipefail file: exit non-zero but output did not name the canary: $out"
  fi
fi

case_num=$((case_num + 1))
nopipe_dir="${TMP_ROOT}/case${case_num}"
mkdir -p "$nopipe_dir/scripts"
cat > "$nopipe_dir/scripts/quiet.sh" <<'QUIET'
#!/usr/bin/env bash
set -uo pipefail
grep -q needle <<<"$big"
QUIET
if out=$(cd "$nopipe_dir" && bash "$LINT" 2>&1); then
  bad "no grep pipelines: expected exit 1, got 0"
else
  if grep -q "examined 0 '| grep' pipelines" <<<"$out"; then
    ok "pipefail files with zero grep pipelines trip the pipe canary"
  else
    bad "no grep pipelines: exit non-zero but output did not name the canary: $out"
  fi
fi

# --- CLI contract -------------------------------------------------------------

if out=$(bash "$LINT" --help 2>&1) && grep -q 'Usage:' <<<"$out"; then
  ok "--help prints usage and exits 0"
else
  bad "--help should print usage and exit 0"
fi

bash "$LINT" --bogus >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 2 ]; then
  ok "unknown flag exits 2"
else
  bad "unknown flag: expected exit 2, got ${rc}"
fi

echo
echo "=== Part 2: real-corpus controls ==="

if out=$(cd "$REPO_ROOT" && bash "$LINT" 2>&1); then
  ok "live repo passes the lint"
else
  bad "live repo should pass the lint"
  sed 's/^/       /' <<<"$out"
fi

# Plant an untracked file carrying the exact pre-fix table-freshness.test.sh
# shape. `--others` discovery must pick it up and the lint must fail on it —
# proving the guard can fire against the real tree, not only a fixture.
PLANT="${REPO_ROOT}/.claude/scripts/tests/zz-pipefail-grep-q-plant-$$.sh"
cat > "$PLANT" <<'PLANT_EOF'
#!/usr/bin/env bash
set -uo pipefail
STEP8="$(sed -n '/^## Step 8/,$p' "$SUBAGENT")"
for VAR in REPO_KEY TF_SESSION ACTIVE_COUNT; do
  printf '%s\n' "$STEP8" | grep -qE "^ *${VAR}=" || \
    fail "/subagent Step 8 uses \$$VAR without re-deriving it after a compaction"
done
PLANT_EOF
if out=$(cd "$REPO_ROOT" && bash "$LINT" 2>&1); then
  bad "planted pre-fix shape: lint passed — the guard cannot fire on the real tree"
else
  if grep -q "zz-pipefail-grep-q-plant-$$.sh:5:" <<<"$out"; then
    ok "planted pre-fix shape makes the live repo fail, at the right line"
  else
    bad "planted pre-fix shape: lint failed but did not name the plant"
    sed 's/^/       /' <<<"$out"
  fi
fi
rm -f "$PLANT"; PLANT=""

echo
echo "=== Part 3: the hazard is real ==="

# 200k short lines (~400 KiB) — far past any pipe buffer, so printf cannot
# finish before grep -q reads its first block, matches on line 1, and exits;
# what is left of printf's output then hits a closed pipe. Many LINES, not one
# long one: grep must read a whole line before it can match, so a single
# newline-free blob would be consumed in full and never reproduce the race.
BIGFILE="${TMP_ROOT}/big.txt"
awk 'BEGIN { for (i = 0; i < 200000; i++) print "x" }' > "$BIGFILE"

# Each probe runs in its own bash so the pipefail in force is exactly the one
# under test, and so a SIGPIPE death cannot take this test process with it.
# The payload travels by file, not argv: 1 MiB is past the per-argument limit.
rc_pipe=$(bash -c 'set -o pipefail; BIG=$(cat "$1"); printf "%s\n" "$BIG" | grep -q x 2>/dev/null; echo $?' _ "$BIGFILE")
rc_here=$(bash -c 'set -o pipefail; BIG=$(cat "$1"); grep -q x <<<"$BIG"; echo $?' _ "$BIGFILE")

if [ "$rc_pipe" != "0" ]; then
  ok "producer piped into grep -q under pipefail returns ${rc_pipe} on a SUCCESSFUL match (the false failure)"
else
  bad "producer piped into grep -q under pipefail returned 0 — the hazard did not reproduce; is the payload past the pipe buffer?"
fi

if [ "$rc_here" = "0" ]; then
  ok "grep -q <<<\"\$BIG\" returns 0 on the same data (the fix)"
else
  bad "here-string form returned ${rc_here} on data that matches"
fi

# Control: the same pipeline WITHOUT pipefail reports grep's own status, which
# is why the lint only scans files that enable it.
rc_nopf=$(bash -c 'BIG=$(cat "$1"); printf "%s\n" "$BIG" | grep -q x 2>/dev/null; echo $?' _ "$BIGFILE")
if [ "$rc_nopf" = "0" ]; then
  ok "(control) the same pipeline without pipefail returns 0"
else
  bad "(control) without pipefail the pipeline returned ${rc_nopf}; expected grep's own 0"
fi

echo
if [ "$failures" -gt 0 ]; then
  echo "FAIL: ${failures} pipefail-grep-q-lint test(s) failed"
  exit 1
fi
echo "PASS: all pipefail-grep-q-lint tests passed"
