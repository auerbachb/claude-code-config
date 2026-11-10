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
# Body-supplied estimate. Deliberately a RETIRED seed value (the pre-#1670
# 90–180 Heavy row): a body line is echoed verbatim on the exit-0 path, so this
# fixture also proves that recalibrating the tier table did not stop older
# issues' estimate lines from parsing.
EST_LINE="Est: 90${EN_DASH}180 min ${MIDDLE_DOT} plan on 180"
# The current Heavy tier-table row (time-estimates.md), used on the exit-1
# label-fallback path.
HEAVY_ROW="Est: 210${EN_DASH}300 min ${MIDDLE_DOT} plan on 300"

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
check_eq "tier fallback prints the Heavy row" "$HEAVY_ROW" "$OUT"

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

# =============================================================================
# 4. The XL row and the strict boundary at the split line (issue #1680).
#
# The time trigger fires on `bound > SPLIT_OVER_MIN` (default 180), strictly.
# This script does not evaluate that comparison — it produces the bound the
# comparison reads — so what is asserted here is that the bound each input
# yields is the one the trigger needs to see. Every case runs a REAL value
# through the script; none asserts on a fixture the non-XL path would have
# accepted anyway.
# =============================================================================
XL_ROW="Est: 180${EN_DASH}360 min ${MIDDLE_DOT} plan on 360"
STANDARD_ROW="Est: 120${EN_DASH}180 min ${MIDDLE_DOT} plan on 180"

write_fixture "$TMP/issue-xl-body.json" \
  "$(printf '## Background\n\nA long one.\n\n## Estimate\n\n%s\n' "$XL_ROW")" '[]'
write_fixture "$TMP/issue-size-xl-label.json" \
  "$(printf '## Background\n\nNo estimate section here.\n')" \
  '[{"name":"size:XL"}]'
write_fixture "$TMP/issue-size-xxl-label.json" \
  "$(printf '## Background\n\nNo estimate section here.\n')" \
  '[{"name":"size:XXL"}]'
# Both labels at once: the owner said "bigger than Heavy" and Heavy's 300 would
# silently discard that claim, so XL must win the priority chain.
write_fixture "$TMP/issue-xl-and-heavy-labels.json" \
  "$(printf '## Background\n\nNo estimate section here.\n')" \
  '[{"name":"complexity:heavy"},{"name":"size:XL"}]'
# The boundary fixture: `plan on 180` EXACTLY. Deliberately the Standard row —
# the modal size of a full issue — because that is the value a `>=` boundary
# would wrongly split.
write_fixture "$TMP/issue-standard-180.json" \
  "$(printf '## Background\n\nOrdinary.\n\n## Estimate\n\n%s\n' "$STANDARD_ROW")" '[]'

bound_of() {  # bound_of <line> — extract `plan on N` exactly as the callers do
  printf '%s' "$1" | sed 's/.*plan on \([0-9]*\).*/\1/'
}

# ---- 4a. The XL line resolves unchanged (boundary: above the line) ----------
run_script env GH_ISSUE_JSON="$TMP/issue-xl-body.json" bash "$SCRIPT" 1680 || true
check_eq "4a XL body line exits 0" "0" "$RC"
check_eq "4a XL body line is echoed verbatim" "$XL_ROW" "$OUT"
check_eq "4a XL bound is 360, above the 180 split line" "360" "$(bound_of "$OUT")"

# ---- 4b. size:XL / size:XXL fall back to the XL row ------------------------
run_script env GH_ISSUE_JSON="$TMP/issue-size-xl-label.json" bash "$SCRIPT" 42 || true
check_eq "4b size:XL label exits 1 (tier fallback)" "1" "$RC"
check_eq "4b size:XL label yields the XL row" "$XL_ROW" "$OUT"

run_script env GH_ISSUE_JSON="$TMP/issue-size-xxl-label.json" bash "$SCRIPT" 42 || true
check_eq "4b size:XXL label exits 1 (tier fallback)" "1" "$RC"
check_eq "4b size:XXL label yields the XL row" "$XL_ROW" "$OUT"

run_script env GH_ISSUE_JSON="$TMP/issue-xl-and-heavy-labels.json" bash "$SCRIPT" 42 || true
check_eq "4b XL beats Heavy when both labels are present" "$XL_ROW" "$OUT"
check_not_contains "4b XL+Heavy does not resolve to the Heavy row" "300" "$OUT"

# Labels are matched WHOLE, not as substrings. `size:xlarge` CONTAINS `size:xl`,
# so a substring match would resolve a label whose owner never asked for XL to
# the 360-minute row — and, downstream, would fire the split trigger on it.
# `complexity:heavyweight` is the same defect on the pre-existing heavy check.
write_fixture "$TMP/issue-size-xlarge-label.json" \
  "$(printf '## Background\n\nNo estimate section here.\n')" \
  '[{"name":"size:xlarge"}]'
run_script env GH_ISSUE_JSON="$TMP/issue-size-xlarge-label.json" bash "$SCRIPT" 42 || true
check_eq "4b size:xlarge is NOT size:xl — exits 2, unestimated" "2" "$RC"
check_eq "4b size:xlarge does not resolve to the XL row" "unestimated" "$OUT"

write_fixture "$TMP/issue-heavyweight-label.json" \
  "$(printf '## Background\n\nNo estimate section here.\n')" \
  '[{"name":"complexity:heavyweight"}]'
run_script env GH_ISSUE_JSON="$TMP/issue-heavyweight-label.json" bash "$SCRIPT" 42 || true
check_eq "4b complexity:heavyweight is NOT complexity:heavy" "unestimated" "$OUT"

# A label carrying a comma must not split into two names — which is why the
# label list is newline-delimited rather than comma-delimited.
write_fixture "$TMP/issue-comma-label.json" \
  "$(printf '## Background\n\nNo estimate section here.\n')" \
  '[{"name":"needs triage, maybe"},{"name":"size:XL"}]'
run_script env GH_ISSUE_JSON="$TMP/issue-comma-label.json" bash "$SCRIPT" 42 || true
check_eq "4b a comma inside another label does not break matching" "$XL_ROW" "$OUT"

# ---- 4c. `plan on 180` exactly stays Standard and does NOT become XL -------
# The boundary is strict `>`: 180 is not above 180. A `>=` reading would make
# this the split trigger's most common false positive.
run_script env GH_ISSUE_JSON="$TMP/issue-standard-180.json" bash "$SCRIPT" 42 || true
check_eq "4c plan-on-180 body exits 0" "0" "$RC"
check_eq "4c plan-on-180 body is echoed verbatim, not upgraded" "$STANDARD_ROW" "$OUT"
check_eq "4c plan-on-180 bound is exactly 180 (boundary excluded)" "180" "$(bound_of "$OUT")"
if [[ "$(bound_of "$OUT")" -gt 180 ]]; then
  FAIL=$((FAIL + 1)); echo "FAIL — 4c boundary value must NOT be above the split line"
else
  PASS=$((PASS + 1)); echo "ok   — 4c boundary value is not above the split line (strict >)"
fi

# The Heavy row clears the line too — XL is not a precondition for the trigger.
run_script env GH_ISSUE_JSON="$TMP/issue-heavy-label.json" bash "$SCRIPT" 42 || true
check_eq "4c Heavy's 300 is above the split line (boundary inclusive of Heavy)" \
  "300" "$(bound_of "$OUT")"

echo
echo "estimate-resolve.test.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
