#!/usr/bin/env bash
# Unit tests for script-usage-redirect-lint.sh (issue #1406)
#
# Each case builds a hermetic git-tracked fixture tree and runs the lint
# from inside it. Inversion coverage in both directions:
#   - fail cases prove the lint fires on every rejected shape
#   - pass cases prove the lint stays quiet on canonical usage, comments,
#     tests/ fixtures, and opt-out markers
# The baseline fixture places one canonical append under .claude/scripts/
# and one under .claude/skills/, so BOTH halves of the lint's scan scope are
# load-bearing in the pass direction; case 11 makes the skills half
# load-bearing in the fail direction too.
#
# Auto-discovered by run-hook-tests.sh — no workflow edit needed.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
LINT="${REPO_ROOT}/.github/scripts/script-usage-redirect-lint.sh"

TMP_ROOT=$(mktemp -d -t usage-redirect-lint.XXXXXX)
trap 'rm -rf "$TMP_ROOT"' EXIT

failures=0
case_num=0

# ---------------------------------------------------------------------------
# make_fixture DIR
#
# Minimal well-formed tree: one canonical single-line append under
# .claude/scripts/ and one canonical continuation-line append under
# .claude/skills/ (also satisfies the vacuity canary from both trees).
# Cases add their own files on top, then git-track everything so
# git ls-files works.
# ---------------------------------------------------------------------------
make_fixture() {
  local dir="$1"
  mkdir -p "${dir}/.claude/scripts" "${dir}/.claude/skills/my-skill"

  cat > "${dir}/.claude/scripts/canonical-single.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" 2>/dev/null >> "$HOME/.claude/script-usage.log" || true
echo work
EOF

  cat > "${dir}/.claude/skills/my-skill/telemetry.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" \
  2>/dev/null >> "${HOME:-/tmp}/.claude/script-usage.log" || true
echo work
EOF
}

# ---------------------------------------------------------------------------
# run_lint_expect NAME EXPECTED_RC DIR [MUST_MENTION]
#
# Runs the lint from inside an already git-tracked DIR, checks the exit
# code, and (for fail cases) that the output names MUST_MENTION.
# ---------------------------------------------------------------------------
run_lint_expect() {
  local name="$1" expected_rc="$2" dir="$3" must_mention="${4:-}"
  case_num=$((case_num + 1))

  local rc=0 out
  out="$(cd "$dir" && bash "$LINT" 2>&1)" || rc=$?

  if [[ "$rc" -ne "$expected_rc" ]]; then
    echo "FAIL (case ${case_num}: ${name}): expected rc=${expected_rc}, got rc=${rc}"
    echo "$out" | sed 's/^/    /'
    failures=$((failures + 1))
    return 0
  fi
  if [[ -n "$must_mention" ]] && ! grep -qF "$must_mention" <<<"$out"; then
    echo "FAIL (case ${case_num}: ${name}): output does not mention '${must_mention}'"
    echo "$out" | sed 's/^/    /'
    failures=$((failures + 1))
    return 0
  fi
  echo "PASS (case ${case_num}: ${name})"
}

# run_case NAME EXPECTED_RC DIR [MUST_MENTION] — git-track DIR, then run.
run_case() {
  local dir="$3"
  git -C "$dir" init -q
  git -C "$dir" add -A
  run_lint_expect "$@"
}

# ---------------------------------------------------------------------------
# Case 1: canonical forms only (scripts single-line + skills continuation)
# ---------------------------------------------------------------------------
d="${TMP_ROOT}/case-canonical"; make_fixture "$d"
run_case "canonical forms pass" 0 "$d"

# ---------------------------------------------------------------------------
# Case 2: bad order (guard after the append) -> fail, names the file+line
# ---------------------------------------------------------------------------
d="${TMP_ROOT}/case-bad-order"; make_fixture "$d"
cat > "${d}/.claude/scripts/bad-order.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" >> "$HOME/.claude/script-usage.log" 2>/dev/null || true
EOF
run_case "bad order fails" 1 "$d" "bad-order.sh,line=2"

# ---------------------------------------------------------------------------
# Case 3: unsuppressed append (no 2>/dev/null at all) -> fail
# ---------------------------------------------------------------------------
d="${TMP_ROOT}/case-unsuppressed"; make_fixture "$d"
cat > "${d}/.claude/scripts/unsuppressed.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" >> "$HOME/.claude/script-usage.log" || true
EOF
run_case "unsuppressed fails" 1 "$d" "unsuppressed.sh"

# ---------------------------------------------------------------------------
# Case 4: grouped form -> fail (safe at runtime, but not the single shape)
# ---------------------------------------------------------------------------
d="${TMP_ROOT}/case-grouped"; make_fixture "$d"
cat > "${d}/.claude/scripts/grouped.sh" <<'EOF'
#!/usr/bin/env bash
{ printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" >> "$HOME/.claude/script-usage.log"; } 2>/dev/null || true
EOF
run_case "grouped form fails" 1 "$d" "grouped.sh"

# ---------------------------------------------------------------------------
# Case 5: canonical guard position but missing '|| true' -> fail
# ---------------------------------------------------------------------------
d="${TMP_ROOT}/case-no-true"; make_fixture "$d"
cat > "${d}/.claude/scripts/no-true.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" 2>/dev/null >> "$HOME/.claude/script-usage.log"
EOF
run_case "missing || true fails" 1 "$d" "no-true.sh"

# ---------------------------------------------------------------------------
# Case 6: unquoted append target -> fail
# ---------------------------------------------------------------------------
d="${TMP_ROOT}/case-unquoted"; make_fixture "$d"
cat > "${d}/.claude/scripts/unquoted.sh" <<'EOF'
#!/usr/bin/env bash
printf 'x\n' 2>/dev/null >> $HOME/.claude/script-usage.log || true
EOF
run_case "unquoted target fails" 1 "$d" "unquoted.sh"

# ---------------------------------------------------------------------------
# Case 7: rejected shape carrying the opt-out marker -> pass
# ---------------------------------------------------------------------------
d="${TMP_ROOT}/case-opt-out"; make_fixture "$d"
cat > "${d}/.claude/scripts/deliberate.sh" <<'EOF'
#!/usr/bin/env bash
printf 'x\n' >> "$HOME/.claude/script-usage.log" 2>/dev/null || true # script-usage-redirect-ok
EOF
run_case "opt-out marker passes" 0 "$d"

# ---------------------------------------------------------------------------
# Case 8: rejected shape inside a comment line -> pass (comments skipped)
# ---------------------------------------------------------------------------
d="${TMP_ROOT}/case-comment"; make_fixture "$d"
cat > "${d}/.claude/scripts/commented.sh" <<'EOF'
#!/usr/bin/env bash
# Historical form (do not use): printf ... >> "$HOME/.claude/script-usage.log" 2>/dev/null || true
echo work
EOF
run_case "comment mention passes" 0 "$d"

# ---------------------------------------------------------------------------
# Case 9: rejected shape inside a tests/ dir -> pass (tests excluded)
# ---------------------------------------------------------------------------
d="${TMP_ROOT}/case-tests-dir"; make_fixture "$d"
mkdir -p "${d}/.claude/scripts/tests"
cat > "${d}/.claude/scripts/tests/fixture.test.sh" <<'EOF'
#!/usr/bin/env bash
printf 'x\n' >> "$HOME/.claude/script-usage.log" 2>/dev/null || true
EOF
run_case "tests/ fixture excluded" 0 "$d"

# ---------------------------------------------------------------------------
# Case 10: zero append lines anywhere -> fail (vacuity canary)
# ---------------------------------------------------------------------------
d="${TMP_ROOT}/case-vacuous"
mkdir -p "${d}/.claude/scripts"
cat > "${d}/.claude/scripts/no-telemetry.sh" <<'EOF'
#!/usr/bin/env bash
echo work
EOF
run_case "zero appends trips canary" 1 "$d" "ZERO script-usage.log append"

# ---------------------------------------------------------------------------
# Case 11: violation under .claude/skills/ -> fail (skills scope is
# load-bearing in the fail direction, not just via the baseline fixture)
# ---------------------------------------------------------------------------
d="${TMP_ROOT}/case-skills-scope"; make_fixture "$d"
cat > "${d}/.claude/skills/my-skill/bad-order.sh" <<'EOF'
#!/usr/bin/env bash
printf 'x\n' >> "${HOME:-/tmp}/.claude/script-usage.log" 2>/dev/null || true
EOF
run_case "skills-scope violation fails" 1 "$d" "my-skill/bad-order.sh"

# ---------------------------------------------------------------------------
# Case 12: laundering — bad append whose trailing comment quotes the
# canonical form; the line's tail matches the canonical regex, so only the
# one-mention-per-line rule catches it -> fail
# ---------------------------------------------------------------------------
d="${TMP_ROOT}/case-launder"; make_fixture "$d"
cat > "${d}/.claude/scripts/launder.sh" <<'EOF'
#!/usr/bin/env bash
printf 'x\n' >> "$HOME/.claude/script-usage.log" 2>/dev/null || true # see: 2>/dev/null >> "$HOME/.claude/script-usage.log" || true
EOF
run_case "canonical-tail laundering fails" 1 "$d" "launder.sh"

# ---------------------------------------------------------------------------
# Case 13: partially-quoted target ("$HOME"/.claude/...) -> fail (matched
# by neither a fully-quoted nor an unquoted reading; detection must key on
# the log basename regardless of quoting)
# ---------------------------------------------------------------------------
d="${TMP_ROOT}/case-partial-quote"; make_fixture "$d"
cat > "${d}/.claude/scripts/partial-quote.sh" <<'EOF'
#!/usr/bin/env bash
printf 'x\n' >> "$HOME"/.claude/script-usage.log 2>/dev/null || true
EOF
run_case "partially-quoted target fails" 1 "$d" "partial-quote.sh"

# ---------------------------------------------------------------------------
# Case 14: violation in a non-ASCII filename -> fail (corpus must arrive
# NUL-delimited with core.quotePath=false; a C-quoted path would be
# silently dropped by the -f test and the violation never seen)
# ---------------------------------------------------------------------------
d="${TMP_ROOT}/case-nonascii"; make_fixture "$d"
cat > "${d}/.claude/scripts/café.sh" <<'EOF'
#!/usr/bin/env bash
printf 'x\n' >> "$HOME/.claude/script-usage.log" 2>/dev/null || true
EOF
run_case "non-ASCII filename still scanned" 1 "$d" "café.sh"

# ---------------------------------------------------------------------------
# Case 15: listed file the scanner cannot read -> fail loudly as NOT
# scanned (a partially scanned corpus must never report as a clean pass).
# Root reads through 000 perms, so skip there (CI runners are non-root).
# ---------------------------------------------------------------------------
if [[ "${EUID}" -eq 0 ]]; then
  echo "SKIP (case: unreadable file) — running as root, 000 perms are readable"
else
  d="${TMP_ROOT}/case-unreadable"; make_fixture "$d"
  cat > "${d}/.claude/scripts/locked.sh" <<'EOF'
#!/usr/bin/env bash
printf 'x\n' >> "$HOME/.claude/script-usage.log" 2>/dev/null || true
EOF
  git -C "$d" init -q
  git -C "$d" add -A
  chmod 000 "${d}/.claude/scripts/locked.sh"
  run_lint_expect "unreadable file fails loudly" 1 "$d" "NOT scanned"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
if (( failures > 0 )); then
  echo "script-usage-redirect-lint.test: ${failures} of ${case_num} case(s) FAILED"
  exit 1
fi
echo "script-usage-redirect-lint.test: all ${case_num} case(s) passed"
