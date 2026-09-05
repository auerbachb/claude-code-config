#!/usr/bin/env bash
# Offline tests for pr-issue-ref.sh — default mode and --all mode (issue #1281).
# catalog: tests — Tests for `pr-issue-ref.sh` — tiered set-valued default mode, `--first` mode, `--all` mode, `owner/repo#N` form, word-boundary guards
# Stubs `gh` with fixture PR bodies; no real GitHub calls.
# Run from repo root:
#   bash .claude/scripts/tests/pr-issue-ref.test.sh
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/.claude/scripts/pr-issue-ref.sh"

TMP="$(mktemp -d)"
TMP_HOME="$(mktemp -d)"
cleanup() { rm -rf "$TMP" "$TMP_HOME"; }
trap cleanup EXIT
export HOME="$TMP_HOME"
mkdir -p "$HOME/.claude"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "ok   — $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL — $1"; }

# Self-check: every check_*/assert_* helper this file calls must be defined in
# this file. A typo'd or cross-suite helper (e.g. calling check_msg where only
# check_contains exists) is command-not-found; with `set -uo pipefail` and no
# `-e` that neither aborts nor increments FAIL, so the suite reports success
# having never run the assertion. That is exactly how two Test 8 message checks
# silently vanished. Portable to bash 3.2 (macOS) as well as CI's bash 5.
# Comment lines are stripped first: prose that merely NAMES a helper (including
# the comment above) is not a call, and scanning it produced a false positive.
_undefined_helpers="$(comm -23 \
  <(grep -v '^[[:space:]]*#' "$0" \
      | grep -ohE '(^|[^a-zA-Z0-9_])(check|assert)_[a-z_]+' \
      | grep -ohE '(check|assert)_[a-z_]+' | sort -u) \
  <(grep -oE '^[a-z_]+\(\)' "$0" | tr -d '()' | sort -u))"
if [[ -n "$_undefined_helpers" ]]; then
  echo "FAIL — assertion helper(s) called but never defined in $0:" >&2
  printf '  %s\n' $_undefined_helpers >&2
  exit 1
fi

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
    fail "$desc (missing '$needle' in '$haystack')"
  fi
}

check_line_present() {
  local desc="$1" line="$2" hay="$3"
  if printf '%s\n' "$hay" | grep -Fxq -- "$line"; then
    pass "$desc"
  else
    fail "$desc (missing exact line '$line')"
  fi
}

# ---------------------------------------------------------------------------
# Fixtures: pr_body per PR number
# ---------------------------------------------------------------------------
mkdir -p "$TMP/pr_body" "$TMP/gh_fail"

# PR 101 — single bare #N reference
echo "Implements the feature. Closes #42" > "$TMP/pr_body/101.txt"

# PR 102 — multiple bare #N references (two different issues)
echo "Fixes #10. Also resolves #20" > "$TMP/pr_body/102.txt"

# PR 103 — cross-repo owner/repo#N only
echo "Closes auerbachb/inventory#55" > "$TMP/pr_body/103.txt"

# PR 104 — both bare #N and cross-repo on same PR
printf 'Closes #30\nFixes auerbachb/inventory#40\n' > "$TMP/pr_body/104.txt"

# PR 105 — no closing keyword
echo "General update, no linked issue" > "$TMP/pr_body/105.txt"

# PR 106 — bare #N that should not match embedded in word
echo "encloses#77 and enclosed #78" > "$TMP/pr_body/106.txt"

# PR 107 — cross-repo ref to a DIFFERENT repo and same issue number in this repo
# Regression for: Closes other-org/other-repo#99 must NOT collide with local #99.
# When GITHUB_REPOSITORY=auerbachb/claude-code-config, the cross-repo ref is filtered out.
printf 'Closes other-org/other-repo#99\nCloses #42\n' > "$TMP/pr_body/107.txt"

# PR 108 — cross-repo ref to the CURRENT repo (should be included like a bare #N)
printf 'Closes auerbachb/claude-code-config#55\n' > "$TMP/pr_body/108.txt"

# PR 109 — issue #1492 VARIANT 1, verbatim shape of live PR #1489: a prose
# closing reference EARLIER in the body than the canonical trailing trailer.
# Pre-fix `head -1` returned 1356, so /wrap released an unrelated closed issue
# and left #1407's claim held. Tier 1 (standalone) must win outright.
printf 'Dedup note\n\nDedup scored this 0.85 against closed #1356, and that was reviewed before filing this PR.\n\nCloses #1407\n' \
  > "$TMP/pr_body/109.txt"

# PR 110 — issue #1492 VARIANT 2, verbatim shape of live PR #1546: TWO canonical
# trailers, both standalone. GitHub closed both; pre-fix `head -1` returned only
# 1531 and stranded #1541's claim. "Prefer the last reference" would merely
# strand the other one — the output has to be set-valued.
printf 'Two nits batched into one PR.\n\nCloses #1531\nCloses #1541\n' \
  > "$TMP/pr_body/110.txt"

# PR 111 — standalone grammar boundary: a Markdown bullet trailer and a trailer
# with trailing punctuation both count as tier 1; a mid-sentence `fixes #700`
# is tier 2 and must therefore lose.
printf 'This also fixes #700 in passing.\n\n- Closes #801\nResolves #802.\n' \
  > "$TMP/pr_body/111.txt"

# PR 112 — CRLF body (what GitHub stores when a body is edited in the web UI).
# An unstripped CR breaks the tier-1 end-of-line anchor, silently demoting a
# real trailer to prose and handing the prose reference the win.
printf 'Some prose closed #66 here.\r\n\r\nCloses #55\r\n' > "$TMP/pr_body/112.txt"

# PR 113 — word-boundary guard across the tier-2 scan resume. `closed` here is
# preceded by a digit, so the documented `enclosed #56` guard must reject it;
# only `fixes #1` is a legal match. See Test 19.
printf 'edge fixes #1closed #56 tail\n' > "$TMP/pr_body/113.txt"

# PR 114 — control for PR 113: two genuinely separated embedded refs on ONE
# line, so a resume that swallowed the rest of the line would show up here.
printf 'This fixes #10 and also resolves #20 today.\n' > "$TMP/pr_body/114.txt"

# ---------------------------------------------------------------------------
# gh stub — serves pr body files for `pr view N ...` calls
# ---------------------------------------------------------------------------
STUB_BIN="$TMP/bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/gh" <<STUB
#!/usr/bin/env bash
set -uo pipefail
args="\$*"
case "\$args" in
  "pr view "*)
    n=\$(echo "\$args" | sed -n 's/^pr view \([0-9]*\).*/\1/p')
    # A failure marker's CONTENTS become stderr, so a test picks the not-found
    # shape (exit 3) or a generic API error (exit 4) -- the distinction
    # pr-issue-ref.sh branches on. Previously an unknown PR returned an empty
    # body with exit 0, so neither failure path was reachable from this suite.
    if [ -f "$TMP/gh_fail/pr_\${n}.txt" ]; then
      cat "$TMP/gh_fail/pr_\${n}.txt" >&2
      exit 1
    fi
    if [ -f "$TMP/pr_body/\${n}.txt" ]; then
      cat "$TMP/pr_body/\${n}.txt"
    else
      echo ""
    fi
    ;;
  "repo view "*)
    # Tests 13/14 set GITHUB_REPOSITORY directly; this branch is unreachable for them.
    # Failing here is what lets a test reach the unfiltered fallback -- but ONLY when
    # GITHUB_REPOSITORY is also empty. Every test that depends on a particular repo
    # context must set GITHUB_REPOSITORY explicitly (to a value, or to "" for the
    # fallback): GitHub Actions always sets it, so a test that merely omits it reads
    # the ambient repo in CI and silently exercises a different branch than it does
    # locally. That leak is what made Tests 8 and 9 pass locally and fail in CI.
    exit 1
    ;;
  *)
    echo "gh stub: unhandled args: \$args" >&2
    exit 1
    ;;
esac
STUB
chmod +x "$STUB_BIN/gh"
export PATH="$STUB_BIN:$PATH"

# ---------------------------------------------------------------------------
# Test 1: default mode — single bare #N reference
# ---------------------------------------------------------------------------
OUT="$(bash "$SCRIPT" 101 2>/dev/null)"
check_eq "Test1: default mode extracts single bare #N" "42" "$OUT"

# ---------------------------------------------------------------------------
# Test 2: default mode — no standalone trailer, so every embedded reference is
# returned (deliberate contract change, issue #1492).
#
# This body is `Fixes #10. Also resolves #20` — both references sit in prose, so
# tier 1 is empty and the tier-2 fallback emits both. It previously returned
# just "10"; that `head -1` is the exact mechanism that stranded issue claims on
# live PRs #1489 and #1546, and GitHub closes both #10 and #20 for this body.
# ---------------------------------------------------------------------------
OUT="$(bash "$SCRIPT" 102 2>/dev/null)"
check_eq "Test2: default mode returns every embedded ref when no trailer exists" "$(printf '10\n20')" "$OUT"
OUT="$(bash "$SCRIPT" --first 102 2>/dev/null)"
check_eq "Test2b: --first narrows the same body to one primary" "10" "$OUT"

# ---------------------------------------------------------------------------
# Test 3: default mode — cross-repo form NOT matched (bare #N only)
# ---------------------------------------------------------------------------
RC=0
OUT="$(bash "$SCRIPT" 103 2>/dev/null)" || RC=$?
[[ "$RC" -eq 1 ]] && pass "Test3: default mode does not match cross-repo form (exit 1)" \
  || fail "Test3: default mode should exit 1 for cross-repo-only body (got RC=$RC, OUT='$OUT')"

# ---------------------------------------------------------------------------
# Test 4: default mode output unchanged when both forms present
# PR 104 has both "Closes #30" and cross-repo ref; default returns "30"
# ---------------------------------------------------------------------------
OUT="$(bash "$SCRIPT" 104 2>/dev/null)"
check_eq "Test4: default mode still returns first bare #N when cross-repo also present" "30" "$OUT"

# ---------------------------------------------------------------------------
# Test 5: default mode — no closing keyword exits 1
# ---------------------------------------------------------------------------
RC=0
bash "$SCRIPT" 105 2>/dev/null || RC=$?
[[ "$RC" -eq 1 ]] && pass "Test5: default mode exits 1 when no reference found" \
  || fail "Test5: expected exit 1 for no closing keyword (got $RC)"

# ---------------------------------------------------------------------------
# Test 6: --all mode — single bare #N
# ---------------------------------------------------------------------------
OUT="$(bash "$SCRIPT" --all 101 2>/dev/null)"
check_eq "Test6: --all returns single bare #N" "42" "$OUT"

# ---------------------------------------------------------------------------
# Test 7: --all mode — multiple bare #N references
# ---------------------------------------------------------------------------
OUT="$(bash "$SCRIPT" --all 102 2>/dev/null)"
check_line_present "Test7a: --all includes first ref #10" "10" "$OUT"
check_line_present "Test7b: --all includes second ref #20" "20" "$OUT"
LINE_COUNT="$(printf '%s\n' "$OUT" | grep -c . || true)"
[[ "$LINE_COUNT" -eq 2 ]] && pass "Test7c: --all emits exactly 2 lines for 2 refs" \
  || fail "Test7c: expected 2 lines, got $LINE_COUNT"

# ---------------------------------------------------------------------------
# Test 8: --all mode — cross-repo owner/repo#N form detected separately
# PR 103 has only "Closes auerbachb/inventory#55" (no bare #N)
# With no resolvable repo context, --all must REFUSE rather than guess: including
# the ref risks a false collision with a local issue, excluding it risks missing a
# genuine self-reference. Both are wrong answers, so it exits 4.
# Qualified-ref PARSING is still covered with real context by Tests 13 and 14.
# ---------------------------------------------------------------------------
RC=0
MSG="$(GITHUB_REPOSITORY="" bash "$SCRIPT" --all 103 2>&1 >/dev/null)" || RC=$?
[[ "$RC" -eq 4 ]] && pass "Test8: --all refuses qualified refs with no repo context (exit 4)" \
  || fail "Test8: expected exit 4 with no repo context, got $RC"
check_contains "Test8: message names the missing repo context" "cannot resolve the current repository" "$MSG"
check_contains "Test8: message names the fix" "GITHUB_REPOSITORY" "$MSG"

# ---------------------------------------------------------------------------
# Test 9: --all mode — both bare #N and owner/repo#N
# PR 104 has "Closes #30" and "Fixes auerbachb/inventory#40"
# Mixed bare + qualified with no repo context: still refuses (exit 4), because the
# qualified ref cannot be classified. With real context the same body yields the
# bare ref only -- asserted immediately below.
# ---------------------------------------------------------------------------
RC=0
GITHUB_REPOSITORY="" bash "$SCRIPT" --all 104 >/dev/null 2>&1 || RC=$?
[[ "$RC" -eq 4 ]] && pass "Test9a: mixed refs with no repo context refuse (exit 4)" \
  || fail "Test9a: expected exit 4 with no repo context, got $RC"

OUT="$(GITHUB_REPOSITORY=auerbachb/claude-code-config bash "$SCRIPT" --all 104 2>/dev/null)"
check_line_present "Test9b: with real context, bare #30 is included" "30" "$OUT"
if printf '%s\n' "$OUT" | grep -Fxq -- "40"; then
  fail "Test9c: cross-repo #40 (auerbachb/inventory) must be excluded under real context"
else
  pass "Test9c: cross-repo #40 correctly excluded under real context"
fi

# ---------------------------------------------------------------------------
# Test 9d: no repo context is fine when the body has NO qualified refs --
# there is nothing to classify, so the refusal must not fire.
# ---------------------------------------------------------------------------
OUT="$(GITHUB_REPOSITORY="" bash "$SCRIPT" --all 102 2>/dev/null)"
check_line_present "Test9d: bare-only body works with no repo context (#10)" "10" "$OUT"
check_line_present "Test9d: bare-only body works with no repo context (#20)" "20" "$OUT"

# ---------------------------------------------------------------------------
# Test 9e/9f: gh-failure paths (issue #1305). An unknown PR previously returned
# an empty body with exit 0, so exit 3 and exit 4 were both unreachable here and
# a regression collapsing either into a successful empty result would have
# passed the suite.
# ---------------------------------------------------------------------------
printf 'Could not resolve to a PullRequest with the number of 9001.\n' \
  > "$TMP/gh_fail/pr_9001.txt"
RC=0
MSG="$(bash "$SCRIPT" --all 9001 2>&1 >/dev/null)" || RC=$?
[[ "$RC" -eq 3 ]] && pass "Test9e: not-found gh failure exits 3" \
  || fail "Test9e: expected exit 3, got $RC"
check_contains "Test9e: message names the missing PR" "not found" "$MSG"

printf 'HTTP 502: Bad Gateway (https://api.github.com/graphql)\n' \
  > "$TMP/gh_fail/pr_9002.txt"
RC=0
MSG="$(bash "$SCRIPT" --all 9002 2>&1 >/dev/null)" || RC=$?
[[ "$RC" -eq 4 ]] && pass "Test9f: generic gh failure exits 4, not 3" \
  || fail "Test9f: expected exit 4, got $RC"
check_contains "Test9f: message names the failed lookup" "gh pr view failed" "$MSG"

# ---------------------------------------------------------------------------
# Test 10: --all mode — no reference exits 1
# ---------------------------------------------------------------------------
RC=0
bash "$SCRIPT" --all 105 2>/dev/null || RC=$?
[[ "$RC" -eq 1 ]] && pass "Test10: --all exits 1 when no reference found" \
  || fail "Test10: expected exit 1 for no closing keyword (got $RC)"

# ---------------------------------------------------------------------------
# Test 11: word-boundary — "encloses#77" should NOT match (not in --all either)
# "enclosed #78" → "closed" is a prefix issue: left boundary blocks "enclosed"
# ---------------------------------------------------------------------------
RC=0
bash "$SCRIPT" --all 106 2>/dev/null || RC=$?
[[ "$RC" -eq 1 ]] && pass "Test11: word-boundary prevents match inside 'encloses#77' and 'enclosed #78'" \
  || fail "Test11: boundary test failed (expected exit 1, got $RC)"

# ---------------------------------------------------------------------------
# Test 12: usage errors
# ---------------------------------------------------------------------------
RC=0
bash "$SCRIPT" 2>/dev/null || RC=$?
[[ "$RC" -eq 2 ]] && pass "Test12a: missing pr_number exits 2" || fail "Test12a: expected 2, got $RC"

RC=0
bash "$SCRIPT" --bogus 2>/dev/null || RC=$?
[[ "$RC" -eq 2 ]] && pass "Test12b: unknown flag exits 2" || fail "Test12b: expected 2, got $RC"

RC=0
bash "$SCRIPT" --all 2>/dev/null || RC=$?
[[ "$RC" -eq 2 ]] && pass "Test12c: --all with no pr_number exits 2" || fail "Test12c: expected 2, got $RC"

# ---------------------------------------------------------------------------
# Test 13: REGRESSION — cross-repo ref to a DIFFERENT repo is excluded from --all.
# PR 107 has "Closes other-org/other-repo#99" and "Closes #42".
# With GITHUB_REPOSITORY set to this repo, only the bare #42 is returned.
# ---------------------------------------------------------------------------
OUT="$(GITHUB_REPOSITORY=auerbachb/claude-code-config bash "$SCRIPT" --all 107 2>/dev/null)"
check_line_present "Test13a: bare #42 included (same PR, different issue)" "42" "$OUT"
if printf '%s\n' "$OUT" | grep -Fxq -- "99"; then
  fail "Test13b: other-repo#99 must be excluded (got '99' in output)"
else
  pass "Test13b: other-repo#99 correctly excluded from --all output"
fi

# ---------------------------------------------------------------------------
# Test 14: REGRESSION — cross-repo ref to the CURRENT repo IS included in --all.
# PR 108 has "Closes auerbachb/claude-code-config#55".
# With GITHUB_REPOSITORY matching, issue 55 should be returned.
# ---------------------------------------------------------------------------
OUT="$(GITHUB_REPOSITORY=auerbachb/claude-code-config bash "$SCRIPT" --all 108 2>/dev/null)"
check_eq "Test14: same-repo cross-ref included in --all" "55" "$OUT"

# ---------------------------------------------------------------------------
# Tests 15-18 — issue #1492: the selector must be tiered AND set-valued.
#
# NEGATIVE CONTROL. `legacy_pick` is a frozen copy of the pre-fix selector — the
# exact `head -1` one-liner that shipped before this fix. Asserting what IT
# returns on each fixture proves the fixture actually discriminates: a fixture
# both implementations agree on pins nothing. Freezing the old logic here rather
# than reading it back from `origin/main` keeps the control meaningful after this
# fix merges, at which point origin/main would contain the NEW selector and a
# git-based control would silently invert.
# ---------------------------------------------------------------------------
legacy_pick() {
  printf '%s\n' "$1" \
    | grep -oiE '(^|[^[:alnum:]_])(close|closes|closed|fix|fixes|fixed|resolve|resolves|resolved)[[:space:]]*#[0-9]+' \
    | head -1 | grep -oE '[0-9]+' | head -1 || true
}

# --- Test 15: VARIANT 1 (live PR #1489) — trailer beats earlier prose ---------
BODY109="$(cat "$TMP/pr_body/109.txt")"
check_eq "Test15a: NEGATIVE CONTROL — pre-fix selector picks the prose ref (the bug)" \
  "1356" "$(legacy_pick "$BODY109")"
OUT="$(bash "$SCRIPT" 109 2>/dev/null)"
check_eq "Test15b: default mode returns ONLY the standalone trailer" "1407" "$OUT"
LINE_COUNT="$(printf '%s\n' "$OUT" | grep -c . || true)"
[[ "$LINE_COUNT" -eq 1 ]] && pass "Test15c: variant-1 body yields exactly 1 line" \
  || fail "Test15c: expected 1 line, got $LINE_COUNT"
if printf '%s\n' "$OUT" | grep -Fxq -- "1356"; then
  fail "Test15d: prose ref #1356 must not appear in default output"
else
  pass "Test15d: prose ref #1356 correctly excluded by the standalone tier"
fi
check_eq "Test15e: --first agrees with default on a single-trailer body" \
  "1407" "$(bash "$SCRIPT" --first 109 2>/dev/null)"
# --all is deliberately UNCHANGED: no tier filtering, so both refs still appear.
OUT="$(GITHUB_REPOSITORY=auerbachb/claude-code-config bash "$SCRIPT" --all 109 2>/dev/null)"
check_line_present "Test15f: --all still reports the prose ref (unfiltered by design)" "1356" "$OUT"
check_line_present "Test15g: --all still reports the trailer ref" "1407" "$OUT"

# --- Test 16: VARIANT 2 (live PR #1546) — both trailers returned --------------
BODY110="$(cat "$TMP/pr_body/110.txt")"
check_eq "Test16a: NEGATIVE CONTROL — pre-fix selector returns only the first trailer (the bug)" \
  "1531" "$(legacy_pick "$BODY110")"
OUT="$(bash "$SCRIPT" 110 2>/dev/null)"
check_eq "Test16b: default mode returns BOTH trailers in document order" \
  "$(printf '1531\n1541')" "$OUT"
LINE_COUNT="$(printf '%s\n' "$OUT" | grep -c . || true)"
[[ "$LINE_COUNT" -eq 2 ]] && pass "Test16c: variant-2 body yields exactly 2 lines" \
  || fail "Test16c: expected 2 lines, got $LINE_COUNT"
# "Prefer the last reference" was one of the directions proposed on the issue;
# it would return 1541 alone and strand #1531 instead. Pin that it did not happen.
check_line_present "Test16d: the FIRST trailer is not dropped (rules out prefer-last)" "1531" "$OUT"
check_eq "Test16e: --first yields one primary from a two-trailer body" \
  "1531" "$(bash "$SCRIPT" --first 110 2>/dev/null)"

# --- Test 17: standalone grammar — bullets and trailing punctuation -----------
BODY111="$(cat "$TMP/pr_body/111.txt")"
check_eq "Test17a: NEGATIVE CONTROL — pre-fix selector picks the mid-sentence ref" \
  "700" "$(legacy_pick "$BODY111")"
OUT="$(bash "$SCRIPT" 111 2>/dev/null)"
check_eq "Test17b: bullet trailer and punctuated trailer both count as standalone" \
  "$(printf '801\n802')" "$OUT"
if printf '%s\n' "$OUT" | grep -Fxq -- "700"; then
  fail "Test17c: mid-sentence 'fixes #700' must lose to the standalone trailers"
else
  pass "Test17c: mid-sentence 'fixes #700' correctly excluded"
fi

# --- Test 18: CRLF bodies, and --first/--all mutual exclusion -----------------
BODY112="$(cat "$TMP/pr_body/112.txt")"
check_eq "Test18a: NEGATIVE CONTROL — pre-fix selector picks the prose ref on a CRLF body" \
  "66" "$(legacy_pick "$BODY112")"
check_eq "Test18b: CRLF trailer still recognised as standalone" \
  "55" "$(bash "$SCRIPT" 112 2>/dev/null)"

RC=0
bash "$SCRIPT" --first --all 101 >/dev/null 2>&1 || RC=$?
[[ "$RC" -eq 2 ]] && pass "Test18c: --first with --all is a usage error (exit 2)" \
  || fail "Test18c: expected exit 2 for --first --all, got $RC"
MSG="$(bash "$SCRIPT" --first --all 101 2>&1 >/dev/null || true)"
check_contains "Test18d: message names the conflict" "mutually exclusive" "$MSG"

RC=0
bash "$SCRIPT" --first 105 2>/dev/null || RC=$?
[[ "$RC" -eq 1 ]] && pass "Test18e: --first exits 1 when no reference found" \
  || fail "Test18e: expected exit 1, got $RC"

# ---------------------------------------------------------------------------
# Test 19 — the word-boundary guard must survive the tier-2 SCAN RESUME.
#
# Tier 2 walks each line with a loop, re-matching on the remainder after every
# hit. If the remainder is taken from RSTART+RLENGTH, the `^` alternative in
# the pattern matches at the start of that remainder and manufactures a word
# boundary the line never contained — so `fixes #1closed #56` would report 56,
# even though the character before `closed` is a digit and the documented
# `enclosed #56` guard rejects exactly that. Issue #1492 requires the guard to
# be preserved, so the pre-fix selector is the oracle here: it and the new
# selector must AGREE, and Test19a proves the fixture is not vacuous by pinning
# that the number the guard excludes is a real number appearing in the line.
# ---------------------------------------------------------------------------
BODY113="$(cat "$TMP/pr_body/113.txt")"
check_eq "Test19a: NEGATIVE CONTROL — pre-fix selector yields only the boundary-legal ref" \
  "1" "$(legacy_pick "$BODY113")"
OUT="$(bash "$SCRIPT" 113 2>/dev/null)"
check_eq "Test19b: scan-resume does not manufacture a word boundary" "1" "$OUT"
if printf '%s\n' "$OUT" | grep -Fxq -- "56"; then
  fail "Test19c: '#1closed #56' must not match — the char before 'closed' is alnum"
else
  pass "Test19c: digit-adjacent keyword correctly rejected after scan resume"
fi
# Control: a genuine boundary on the same line shape still yields BOTH refs, so
# Test19b is not passing merely because the resume dropped everything after the
# first hit.
check_eq "Test19d: genuinely separated refs on one line still both match" \
  "$(printf '10\n20')" "$(bash "$SCRIPT" 114 2>/dev/null)"

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
echo "OK: pr-issue-ref.sh — all fixtures passed (issue #1281)"
