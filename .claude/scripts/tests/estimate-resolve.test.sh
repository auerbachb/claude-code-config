#!/usr/bin/env bash
# Offline tests for estimate-resolve.sh (issue #1371 — GH_ARGS[@] unbound).
# catalog: tests — Tests for `estimate-resolve.sh`, including the empty-`GH_ARGS` unbound-variable regression
#
# The 2026-08-26 failure: with no extra flags GH_ARGS is EMPTY, and expanding a
# bare "${GH_ARGS[@]}" under `set -u` aborts on macOS bash 3.2 (and bash
# 4.0-4.3). Every lookup died at the gh call and reported exit 4 with an empty
# error string, so callers silently lost their estimates.
#
# Stubs `gh` so nothing touches the network or the real ~/.claude, and records
# the stub's argv so the --repo pass-through is asserted verbatim. Case 1a is a
# NEGATIVE CONTROL guarding against a vacuous pass, in two halves:
#
#   * A structural check that the production script still carries the guarded
#     idiom. This holds on EVERY bash, and on modern bash it is the only thing
#     standing between a revert and macOS breakage.
#   * A behavioral check that the rebuilt pre-fix form still aborts — run ONLY
#     where the abort is reproducible. bash >= 4.4 tolerates expanding an empty
#     array under `set -u`, so on CI's modern bash the pre-fix form runs clean
#     and the complementary assertion is made instead.
#
# Run from repo root: bash .claude/scripts/tests/estimate-resolve.test.sh
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/.claude/scripts/estimate-resolve.sh"

# Does the `bash` that runs the child scripts abort when an EMPTY array is
# expanded under `set -u`? bash < 4.4 (macOS ships 3.2) aborts; bash >= 4.4
# tolerates it. Probe the BEHAVIOR rather than parsing a version string: the
# child `bash` resolved from PATH need not be the one running this suite, and a
# behavioral probe cannot drift from the thing it gates.
if bash -c 'set -u; a=(); : "${a[@]}"' >/dev/null 2>&1; then  # empty-array-ok: the bare expansion IS the probe — this line deliberately triggers the abort it is measuring
  EMPTY_EXPANSION_ABORTS=0
else
  EMPTY_EXPANSION_ABORTS=1
fi

TMP="$(mktemp -d)"
TMP_HOME="$(mktemp -d)"
cleanup() { rm -rf "$TMP" "$TMP_HOME"; }
trap cleanup EXIT
export HOME="$TMP_HOME"
mkdir -p "$HOME/.claude"

PASS=0
FAIL=0
check_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    PASS=$((PASS + 1)); echo "ok   — $desc"
  else
    FAIL=$((FAIL + 1)); echo "FAIL — $desc (expected '$expected', got '$actual')"
  fi
}
check_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    PASS=$((PASS + 1)); echo "ok   — $desc"
  else
    FAIL=$((FAIL + 1)); echo "FAIL — $desc (output does not contain '$needle')"
  fi
}
check_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    PASS=$((PASS + 1)); echo "ok   — $desc"
  else
    FAIL=$((FAIL + 1)); echo "FAIL — $desc (output unexpectedly contains '$needle')"
  fi
}

# ---- stub gh ----------------------------------------------------------------
# estimate-resolve.sh makes exactly one call:
#   gh issue view N [--repo owner/repo] --json body,labels
# The stub records its full argv so pass-through can be asserted verbatim.
STUB_BIN="$TMP/bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/gh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
printf '%s\n' "$*" > "$GH_ARGV_FILE"
if [[ "${GH_FAIL:-0}" == "1" ]]; then
  echo "gh: HTTP 500 from api.github.com" >&2
  exit 1
fi
cat "$GH_ISSUE_JSON"
STUB
chmod +x "$STUB_BIN/gh"
export PATH="$STUB_BIN:$PATH"
export GH_ARGV_FILE="$TMP/gh-argv"

# ---- fixtures ---------------------------------------------------------------
EN_DASH=$(printf '\xe2\x80\x93')
MIDDLE_DOT=$(printf '\xc2\xb7')
EST_LINE="Est: 90${EN_DASH}180 min ${MIDDLE_DOT} plan on 180"

write_fixture() {  # write_fixture <path> <body> <labels-json>
  jq -n --arg body "$2" --argjson labels "$3" '{body: $body, labels: $labels}' > "$1"
}

write_fixture "$TMP/issue-estimated.json" \
  "$(printf '## Background\n\nSome text.\n\n## Estimate\n\n%s\n' "$EST_LINE")" '[]'
write_fixture "$TMP/issue-heavy-label.json" \
  "$(printf '## Background\n\nNo estimate section here.\n')" \
  '[{"name":"complexity:heavy"}]'
write_fixture "$TMP/issue-bare.json" \
  "$(printf '## Background\n\nNothing to go on.\n')" '[]'

run_script() {  # run_script <command...> — captures stdout in OUT, stderr in ERR, rc in RC
  OUT="$("$@" 2>"$TMP/stderr")"
  RC=$?
  ERR="$(cat "$TMP/stderr")"
}

# =============================================================================
# 1. The #1371 shape: no extra flags, so GH_ARGS is empty.
# =============================================================================
run_script env GH_ISSUE_JSON="$TMP/issue-estimated.json" bash "$SCRIPT" 1367 || true
check_eq "no-flags exits 0" "0" "$RC"
check_eq "no-flags prints the Est: line" "$EST_LINE" "$OUT"
check_not_contains "no-flags does not abort on the empty array" "unbound variable" "$ERR"
check_not_contains "no-flags never reaches the gh-error path" "gh error fetching" "$ERR"
check_eq "no-flags passes no --repo to gh" \
  "issue view 1367 --json body,labels" "$(cat "$TMP/gh-argv")"

# ---- 1a. NEGATIVE CONTROL ---------------------------------------------------
# Half one, portable: the production script must still carry the guarded idiom.
# On bash >= 4.4 a revert changes no observable behavior, so this is the only
# assertion that can catch one there — and the macOS breakage it prevents is
# exactly what issue #1371 was.
if grep -qF '${GH_ARGS[@]+"${GH_ARGS[@]}"}' "$SCRIPT"; then
  PASS=$((PASS + 1)); echo "ok   — production script still carries the guarded GH_ARGS idiom"
else
  FAIL=$((FAIL + 1)); echo "FAIL — production script no longer carries the guarded GH_ARGS idiom"
fi

# Half two: rebuild the pre-fix expansion in a copy and assert it STILL aborts,
# where that abort is reproducible at all.
PREFIX_SCRIPT="$TMP/estimate-resolve-prefix.sh"
sed 's/\${GH_ARGS\[@\]+"\${GH_ARGS\[@\]}"}/"${GH_ARGS[@]}"/g' "$SCRIPT" > "$PREFIX_SCRIPT"
if grep -q '"\${GH_ARGS\[@\]}"' "$PREFIX_SCRIPT" && \
   ! grep -q 'GH_ARGS\[@\]+' "$PREFIX_SCRIPT"; then
  PASS=$((PASS + 1)); echo "ok   — negative control rebuilt the pre-fix expansion"
else
  FAIL=$((FAIL + 1)); echo "FAIL — negative control could not rebuild the pre-fix expansion"
fi
run_script env GH_ISSUE_JSON="$TMP/issue-estimated.json" bash "$PREFIX_SCRIPT" 1367 || true
if [[ "$EMPTY_EXPANSION_ABORTS" -eq 1 ]]; then
  check_contains "negative control: pre-fix form aborts on the empty array" \
    "unbound variable" "$ERR"
  check_eq "negative control: pre-fix form exits 4" "4" "$RC"
else
  # bash >= 4.4 tolerates the pre-fix expansion, so the #1371 abort cannot be
  # reproduced here. Assert the complementary fact rather than nothing: if this
  # ever fails, the probe and the child run have disagreed and the gating above
  # is no longer trustworthy.
  check_not_contains "negative control: modern bash tolerates the pre-fix form" \
    "unbound variable" "$ERR"
  check_eq "negative control: modern bash runs the pre-fix form to completion" "0" "$RC"
fi

# =============================================================================
# 2. Flagged invocations pass their arguments through unchanged.
# =============================================================================
run_script env GH_ISSUE_JSON="$TMP/issue-estimated.json" \
  bash "$SCRIPT" 1367 --repo auerbachb/claude-code-config || true
check_eq "--repo exits 0" "0" "$RC"
check_eq "--repo reaches gh unchanged" \
  "issue view 1367 --repo auerbachb/claude-code-config --json body,labels" \
  "$(cat "$TMP/gh-argv")"

run_script env GH_ISSUE_JSON="$TMP/issue-estimated.json" \
  bash "$SCRIPT" 1367 --repo=auerbachb/claude-code-config || true
check_eq "--repo= exits 0" "0" "$RC"
check_eq "--repo= reaches gh unchanged" \
  "issue view 1367 --repo auerbachb/claude-code-config --json body,labels" \
  "$(cat "$TMP/gh-argv")"

# Flag before the issue number — same argv, order-independent parsing.
run_script env GH_ISSUE_JSON="$TMP/issue-estimated.json" \
  bash "$SCRIPT" --repo auerbachb/claude-code-config 1367 || true
check_eq "--repo before the number exits 0" "0" "$RC"
check_eq "--repo before the number reaches gh unchanged" \
  "issue view 1367 --repo auerbachb/claude-code-config --json body,labels" \
  "$(cat "$TMP/gh-argv")"

# =============================================================================
# 3. The rest of the exit-code contract still holds on the no-flags path.
# =============================================================================
run_script env GH_ISSUE_JSON="$TMP/issue-heavy-label.json" bash "$SCRIPT" 42 || true
check_eq "tier fallback exits 1" "1" "$RC"
check_eq "tier fallback prints the Heavy row" "$EST_LINE" "$OUT"

run_script env GH_ISSUE_JSON="$TMP/issue-bare.json" bash "$SCRIPT" 42 || true
check_eq "unestimated exits 2" "2" "$RC"
check_eq "unestimated prints the sentinel" "unestimated" "$OUT"

run_script env GH_ISSUE_JSON="$TMP/issue-bare.json" bash "$SCRIPT" || true
check_eq "no issue number exits 3" "3" "$RC"

run_script env GH_ISSUE_JSON="$TMP/issue-bare.json" bash "$SCRIPT" abc || true
check_eq "non-numeric issue number exits 3" "3" "$RC"

run_script env GH_ISSUE_JSON="$TMP/issue-bare.json" bash "$SCRIPT" 42 --bogus || true
check_eq "unknown flag exits 3" "3" "$RC"

# A real gh failure must still surface the real error — not the empty string the
# pre-fix abort produced.
run_script env GH_FAIL=1 GH_ISSUE_JSON="$TMP/issue-bare.json" bash "$SCRIPT" 42 || true
check_eq "gh failure exits 4" "4" "$RC"
check_contains "gh failure surfaces the underlying error" "HTTP 500" "$ERR"

echo
echo "estimate-resolve.test.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
