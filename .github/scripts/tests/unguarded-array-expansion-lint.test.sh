#!/usr/bin/env bash
# Unit tests for unguarded-array-expansion-lint.sh (issue #1389)
#
# Auto-discovered by run-hook-tests.sh — no workflow edit needed.
# Hermetic-fixture pattern, following zsh-special-name-lint.test.sh.
#
# Four layers, because a lint that only proves it stays quiet proves nothing:
#
#   Part 1  fixture behaviour — the hazardous shapes must FAIL and the
#           look-alike safe shapes (guarded idiom, count-gated expansion,
#           never-empty literal, literal heredoc, comment prose) must PASS.
#           This is where the false-positive claim is actually tested.
#   Part 2  canaries — an empty tree, a tree with no `set -u` file, and a tree
#           with no array expansion must each FAIL rather than pass green.
#   Part 3  real-corpus controls — the live repo passes, AND a planted
#           unguarded expansion makes it fail. Without the second half the
#           first half is satisfied by a lint that can never fire. Both halves
#           of the DEFERRED mechanism (a matching entry is honoured; a no-longer-
#           matching one is reported as STALE) are proved against a fixture
#           entry injected into a copy of the lint, so they keep testing
#           something once the live list is empty — which is its healthy state.
#   Part 4  runtime proof on a bash that actually aborts: the hazardous shape
#           really does die with `unbound variable`, the guarded idiom really
#           does survive with zero arguments, and "${a[@]:-}" really does yield
#           one empty argument (so nobody reaches for it as the fix). Prefers
#           /bin/bash, which is 3.2.57 on macOS even when a newer bash leads
#           PATH. SKIPPED, and reported as skipped, when no installed bash
#           aborts — never silently counted as a pass.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)" || { echo "cannot resolve repo root" >&2; exit 1; }
LINT="${REPO_ROOT}/.github/scripts/unguarded-array-expansion-lint.sh"

if [ ! -f "$LINT" ]; then
  echo "FAIL — lint script not found at $LINT"
  exit 1
fi

TMP_ROOT="$(mktemp -d -t unguarded-array-lint.XXXXXX)"

# PLANT_OWNED is set only once THIS run has created the probe file (Part 3b).
# The trap removes it on every exit path — including an interrupt or a CI
# timeout — because a planted file left behind in .claude/scripts/ would fail
# every later lint run and could be committed by accident. It is never removed
# when the path already existed, so a real file at that name is safe.
PLANT=""
PLANT_OWNED=0
cleanup() {
  rm -rf "$TMP_ROOT"
  [ "$PLANT_OWNED" -eq 1 ] && [ -n "$PLANT" ] && rm -f "$PLANT"
  return 0
}
trap cleanup EXIT INT TERM

failures=0
case_num=0
skips=0

ok()   { echo "ok   — $1"; }
bad()  { echo "FAIL — $1"; failures=$((failures + 1)); }
skip() { echo "SKIP — $1"; skips=$((skips + 1)); }

# A minimal fixture: one clean `set -u` script carrying a safe array expansion,
# so both vacuity canaries are satisfied and each case only adds what it tests.
make_fixture() {
  local dir="$1"
  mkdir -p "$dir/scripts"
  cat > "$dir/scripts/clean.sh" <<'CLEAN'
#!/usr/bin/env bash
set -euo pipefail
GIT=(git -C "$PWD")
"${GIT[@]}" status --short
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
    bad "$name — expected exit $want, got $got"
    printf '       output: %s\n' "$(printf '%s' "$out" | tail -3)"
    return
  fi
  if [ -n "$want_re" ] && ! printf '%s' "$out" | grep -qE "$want_re"; then
    bad "$name — exit $got correct but output did not match /$want_re/"
    printf '       output: %s\n' "$(printf '%s' "$out" | tail -3)"
    return
  fi
  ok "$name"
}

echo "--- Part 1: fixture behaviour ---"

# --- must FAIL: the hazardous shapes -------------------------------------
expect 'conditionally-built array expanded bare' 1 'bare .*args\[@\]' <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
args=()
[ -n "${FLAG:-}" ] && args+=(--flag)
cmd "${args[@]}"
EOF

expect 'bare ${arr[*]} aborts exactly like [@]' 1 'bare .*items\[\*\]' <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
items=()
[ -n "${X:-}" ] && items+=(x)
[[ -n "${items[*]}" ]] && echo yes
EOF

expect 'local -a with no initialiser' 1 'bare .*acc\[@\]' <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
collect() { local -a acc; [ -n "${X:-}" ] && acc+=(x); printf '%s\n' "${acc[@]}"; }
EOF

expect 'unset then expanded' 1 'bare .*arr\[@\]' <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
arr=(a b); unset arr; printf '%s\n' "${arr[@]}"
EOF

expect 'set -o nounset counts as set -u' 1 'bare .*args\[@\]' <<'EOF'
#!/usr/bin/env bash
set -o nounset
args=()
cmd "${args[@]}"
EOF

expect 'waiver marker with no reason is itself an error' 1 'with no reason' <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
args=()
[ -n "${FLAG:-}" ] && args+=(--flag)
cmd "${args[@]}"  # empty-array-ok
EOF

# --- must PASS: the safe look-alikes -------------------------------------
expect 'guarded expansion idiom' 0 'OK' <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
args=()
[ -n "${FLAG:-}" ] && args+=(--flag)
cmd ${args[@]+"${args[@]}"}
EOF

expect 'count-gated expansion' 0 'OK' <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
args=()
[ -n "${FLAG:-}" ] && args+=(--flag)
if (( ${#args[@]} )); then cmd "${args[@]}"; fi
EOF

expect 'same-line count guard' 0 'OK' <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
args=()
[ -n "${FLAG:-}" ] && args+=(--flag)
(( ${#args[@]} )) && cmd "${args[@]}"
EOF

expect 'never-empty literal is not reported' 0 'OK' <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
GIT=(git -C "$root")
"${GIT[@]}" status
EOF

expect 'local -a WITH a non-empty initialiser' 0 'OK' <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
collect() { local -a acc=(seed); printf '%s\n' "${acc[@]}"; }
EOF

expect 'literal heredoc body never expands' 0 'OK' <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
args=()
cat <<'USAGE'
example: cmd "${args[@]}"
USAGE
EOF

expect 'comment prose is not code' 0 'OK' <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
args=()
# never write cmd "${args[@]}" — use the guarded form below
cmd ${args[@]+"${args[@]}"}
EOF

expect 'waiver marker WITH a reason' 0 'OK.*1 waived' <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
args=()
[ -n "${FLAG:-}" ] && args+=(--flag)
cmd "${args[@]}"  # empty-array-ok: caller validates argv before this point
EOF

expect 'array never assigned in this file is not our call' 0 'OK' <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "${SOME_GLOBAL_FROM_ELSEWHERE[@]}"
EOF

# A generator script whose ONLY `set -u` is literal text inside a quoted
# heredoc is not itself a `set -u` script, so its own bare expansion must not
# be reported. This is why the set -u gate runs inside the main loop, after
# heredoc bookkeeping, rather than as a raw pre-pass over the file.
expect 'set -u inside a quoted heredoc does not arm the file' 0 'OK' <<'EOF'
#!/usr/bin/env bash
emit() {
  cat <<'INNER'
set -euo pipefail
args=()
cmd "${args[@]}"
INNER
}
args=()
cmd "${args[@]}"
EOF

echo
echo "--- Part 2: vacuity canaries ---"

canary() {  # NAME  SETUP_FN  WANT_REGEX
  local name="$1" setup="$2" want_re="$3"
  case_num=$((case_num + 1))
  local dir="${TMP_ROOT}/canary${case_num}"
  mkdir -p "$dir"
  "$setup" "$dir"
  local out got
  out=$(cd "$dir" && bash "$LINT" 2>&1) && got=0 || got=$?
  if [ "$got" -eq 0 ]; then
    bad "$name — canary passed green instead of failing"
    return
  fi
  if ! printf '%s' "$out" | grep -qE "$want_re"; then
    bad "$name — failed, but not with the expected canary message"
    printf '       output: %s\n' "$(printf '%s' "$out" | tail -2)"
    return
  fi
  ok "$name"
}

setup_empty()   { mkdir -p "$1/scripts"; }
setup_no_setu() { mkdir -p "$1/scripts"; printf '#!/usr/bin/env bash\na=()\ncmd "${a[@]}"\n' > "$1/scripts/x.sh"; }
setup_no_expn() { mkdir -p "$1/scripts"; printf '#!/usr/bin/env bash\nset -euo pipefail\necho hi\n' > "$1/scripts/x.sh"; }

canary 'empty tree fails rather than passing green'      setup_empty   'discovery found no shell files'
canary 'no set -u file fails rather than passing green'  setup_no_setu "none enabled 'set -u'"
canary 'no array expansion fails rather than green'      setup_no_expn 'examined 0 array expansions'

echo
echo "--- Part 3: real-corpus controls ---"

# 3a. The live repo must pass. If it does not, the remediation is incomplete.
if out=$(cd "$REPO_ROOT" && bash "$LINT" 2>&1); then
  ok "live repo passes the lint"
else
  bad "live repo FAILS the lint — remediation incomplete"
  printf '%s\n' "$out" | grep '^::error' | head -5 | sed 's/^/       /'
fi

# 3b. …and it must fail when a real violation is planted. Without this half,
#     3a is satisfied by a lint that can never fire at all.
PLANT_CANDIDATE="${REPO_ROOT}/.claude/scripts/zzz-unguarded-array-lint-probe.sh"
# -e alone is FALSE for a dangling symlink, and the `cat >` below would then
# follow the link and write through to its target. -L catches that case.
if [ -e "$PLANT_CANDIDATE" ] || [ -L "$PLANT_CANDIDATE" ]; then
  bad "probe path already exists, refusing to overwrite: $PLANT_CANDIDATE"
else
  PLANT="$PLANT_CANDIDATE"
  PLANT_OWNED=1
  cat > "$PLANT" <<'PLANTED'
#!/usr/bin/env bash
set -euo pipefail
planted=()
[ -n "${FLAG:-}" ] && planted+=(--flag)
cmd "${planted[@]}"
PLANTED
  if (cd "$REPO_ROOT" && bash "$LINT" >/dev/null 2>&1); then
    bad "planted violation did NOT trip the lint — the live-repo pass is vacuous"
  else
    ok "planted violation trips the lint"
  fi
  rm -f "$PLANT"
  PLANT_OWNED=0
fi

# 3c/3d. Both halves of the DEFERRED mechanism. The live list is EMPTY in the
#     healthy state (issue #1617 retired its only entry), so these cases must
#     not read the shipped list — a test that did would go vacuous the moment a
#     deferral is retired, exactly when the expiry check matters most. Instead
#     inject a fixture entry into a COPY of the lint, and assert the injection
#     landed before trusting either verdict.
DEFERRED_LINT="${TMP_ROOT}/lint-with-deferral.sh"
awk '
  $0 == "DEFERRED=()" {
    print "DEFERRED=("
    print "  '\''.claude/scripts/deferral-fixture.sh|ITEMS|test fixture (unguarded-array-expansion-lint.test.sh)'\''"
    print ")"
    injected = 1
    next
  }
  { print }
  END { exit(injected ? 0 : 1) }
' "$LINT" > "$DEFERRED_LINT" || {
  bad "could not inject a fixture deferral — 'DEFERRED=()' no longer appears verbatim in the lint; the deferral cases below would pass vacuously"
  DEFERRED_LINT=""
}

if [ -n "$DEFERRED_LINT" ]; then
  # 3c. A deferral that DOES match a live finding is honoured, not reported.
  HONOURED_DIR="${TMP_ROOT}/deferral-honoured"
  mkdir -p "${HONOURED_DIR}/.claude/scripts"
  cat > "${HONOURED_DIR}/.claude/scripts/clean.sh" <<'CLEAN'
#!/usr/bin/env bash
set -euo pipefail
GIT=(git -C "$PWD")
"${GIT[@]}" status
CLEAN
  # The deferred path, still carrying the violation the entry describes.
  cat > "${HONOURED_DIR}/.claude/scripts/deferral-fixture.sh" <<'BROKEN'
#!/usr/bin/env bash
set -euo pipefail
ITEMS=()
printf '%s\n' "${ITEMS[@]}"
BROKEN
  out=$(cd "$HONOURED_DIR" && bash "$DEFERRED_LINT" 2>&1) && got=0 || got=$?
  if [ "${got:-0}" -eq 0 ] && printf '%s' "$out" | grep -q 'DEFERRED .*deferral-fixture.sh'; then
    ok "a matching deferral is honoured rather than reported as an error"
  else
    bad "a matching deferral did NOT suppress its finding — the escape hatch is broken"
    printf '       output: %s\n' "$(printf '%s' "$out" | tail -2)"
  fi

  # 3d. A stale deferral must be reported. The DEFERRED list is the one part of
  #     this lint that could silently outlive its justification, so prove the
  #     expiry check fires when the deferred file is present but clean.
  STALE_DIR="${TMP_ROOT}/stale"
  mkdir -p "${STALE_DIR}/.claude/scripts"
  cat > "${STALE_DIR}/.claude/scripts/clean.sh" <<'CLEAN'
#!/usr/bin/env bash
set -euo pipefail
GIT=(git -C "$PWD")
"${GIT[@]}" status
CLEAN
  # The deferred path, present but carrying no violation.
  cat > "${STALE_DIR}/.claude/scripts/deferral-fixture.sh" <<'FIXED'
#!/usr/bin/env bash
set -euo pipefail
ITEMS=()
COPY=(${ITEMS[@]+"${ITEMS[@]}"})
printf '%s\n' ${COPY[@]+"${COPY[@]}"}
FIXED
  out=$(cd "$STALE_DIR" && bash "$DEFERRED_LINT" 2>&1) && got=0 || got=$?
  if [ "${got:-0}" -ne 0 ] && printf '%s' "$out" | grep -q 'STALE deferral'; then
    ok "stale deferral is reported once its site is clean"
  else
    bad "stale deferral was NOT reported — the allowlist can rot silently"
    printf '       output: %s\n' "$(printf '%s' "$out" | tail -2)"
  fi
fi

echo
echo "--- Part 4: runtime proof ---"

# Find a bash that actually ABORTS on an empty-array expansion. On macOS that
# is /bin/bash (3.2.57) even when a newer bash leads PATH, so prefer it — the
# proof is worth running on the developer machine where the bug actually bites.
# Probe the BEHAVIOUR rather than parsing a version string: a behavioural probe
# cannot drift from the thing it gates.
PROBE_BASH=""
for cand in /bin/bash "$(command -v bash 2>/dev/null || true)"; do
  [ -n "$cand" ] && [ -x "$cand" ] || continue
  if ! "$cand" -c 'set -u; a=(); : "${a[@]}"' >/dev/null 2>&1; then  # empty-array-ok: the bare expansion IS the probe — this line deliberately triggers the abort it is measuring
    PROBE_BASH="$cand"
    break
  fi
done

if [ -z "$PROBE_BASH" ]; then
  skip "runtime proof — no bash on this machine aborts on empty-array expansion (bash >= 4.4 tolerates it); the abort this lint guards is unobservable here"
else
  hazard_out=$("$PROBE_BASH" -c 'set -u; args=(); cmd() { :; }; cmd "${args[@]}"; echo SURVIVED' 2>&1) && hazard_rc=0 || hazard_rc=$?  # empty-array-ok: reproducing the abort under test is the whole point of this assertion
  if [ "$hazard_rc" -ne 0 ] && printf '%s' "$hazard_out" | grep -q 'unbound variable'; then
    ok "hazardous shape really aborts with 'unbound variable' under $PROBE_BASH"
  else
    bad "hazardous shape did NOT abort as expected (rc=$hazard_rc): $hazard_out"
  fi

  guarded_out=$("$PROBE_BASH" -c 'set -u; args=(); cmd() { echo "argc=$#"; }; cmd ${args[@]+"${args[@]}"}' 2>&1) && guarded_rc=0 || guarded_rc=$?
  if [ "$guarded_rc" -eq 0 ] && [ "$guarded_out" = "argc=0" ]; then
    ok "guarded idiom survives and passes zero arguments under $PROBE_BASH"
  else
    bad "guarded idiom misbehaved (rc=$guarded_rc): $guarded_out"
  fi

  # The other half of the pair: "${args[@]:-}" is NOT a drop-in replacement —
  # it yields one empty-string argument. Pin that, so nobody "fixes" a finding
  # by reaching for it and silently changes an argument list.
  colon_out=$("$PROBE_BASH" -c 'set -u; args=(); cmd() { echo "argc=$#"; }; cmd "${args[@]:-}"' 2>&1) || true
  if [ "$colon_out" = "argc=1" ]; then
    ok '"${args[@]:-}" yields ONE empty argument — correctly not the sanctioned fix'
  else
    bad "expected argc=1 from \"\${args[@]:-}\", got: $colon_out"
  fi
fi

echo
if [ "$failures" -eq 0 ]; then
  echo "PASS — ${case_num} lint case(s), 0 failures, ${skips} skipped"
  exit 0
fi
echo "FAIL — ${failures} failure(s) across ${case_num} lint case(s), ${skips} skipped"
exit 1
