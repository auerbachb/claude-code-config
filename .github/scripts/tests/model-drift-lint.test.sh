#!/usr/bin/env bash
# Unit tests for model-drift-lint.sh (issue #752)
#
# Auto-discovered by run-hook-tests.sh — no workflow edit needed.
# Follows the hermetic fixture pattern from chip-model-guard-lint.test.sh.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
LINT="${REPO_ROOT}/.github/scripts/model-drift-lint.sh"

TMP_ROOT=$(mktemp -d -t model-drift-lint.XXXXXX)
trap 'rm -rf "$TMP_ROOT"' EXIT

failures=0
case_num=0

# Build a minimal hermetic fixture tree that mirrors the live-surface layout.
# Only the paths the lint actually scans are needed:
#   CLAUDE.md, .claude/rules/, .claude/skills/, .claude/agents/
# .claude/reference/ is intentionally NOT in the scan set — the exemption test
# plants drift there and verifies the lint stays silent.
make_fixture() {
  local dir="$1"
  mkdir -p "$dir/.claude/rules" \
            "$dir/.claude/skills/example-skill" \
            "$dir/.claude/agents" \
            "$dir/.claude/reference"
  # Minimal clean CLAUDE.md — no legacy model references.
  cat > "$dir/CLAUDE.md" <<'CLAUDE'
# Claude configuration
Fleet: Fable, Opus, Sonnet, Haiku 4.5
CLAUDE
  # Minimal clean rule file.
  cat > "$dir/.claude/rules/subagent-orchestration.md" <<'RULE'
# Subagent Model Selection
Use Opus for Phase A, Sonnet for Phase C.
RULE
  # Minimal clean skill file — contains generational prose that must NOT fire.
  cat > "$dir/.claude/skills/example-skill/SKILL.md" <<'SKILL'
# Example skill
Legacy models (Opus 4.x, Sonnet 4.x) are no longer recommended.
Use the bare family name instead.
SKILL
  # Minimal clean agent file.
  cat > "$dir/.claude/agents/phase-a-fixer.md" <<'AGENT'
---
model: opus
---
Phase A fixer agent. Uses Opus for heavy lifting.
AGENT
  # Reference file — this is intentionally exempt even when it has legacy names.
  cat > "$dir/.claude/reference/harness-model-audit-2026-06.md" <<'REF'
Current fleet (assumed authoritative for this audit): Opus 4.8, Sonnet 4.6, Haiku 4.5.
REF
}

# expect NAME WANT_EXIT WANT_REGEX MUTATION_CMD [MUTATION_ARGS...]
#
# Builds a fixture, applies the mutation, runs the lint, and checks:
#   - exit code matches WANT_EXIT
#   - combined stdout+stderr matches WANT_REGEX (ERE)
expect() {
  local name="$1" want="$2" want_re="$3"; shift 3
  case_num=$((case_num + 1))
  local dir="${TMP_ROOT}/case${case_num}"
  make_fixture "$dir"

  # Apply mutation in the fixture directory.
  if ! ( cd "$dir" && "$@" ); then
    echo "FAIL — ${name}: fixture mutation failed"
    failures=$((failures + 1))
    return
  fi

  local out got
  out=$(cd "$dir" && bash "$LINT" 2>&1) && got=0 || got=$?

  if (( got != want )); then
    echo "FAIL — ${name}: expected exit ${want}, got ${got}"
    echo "$out" | sed 's/^/       /'
    failures=$((failures + 1))
    return
  fi

  if ! grep -qE "$want_re" <<< "$out"; then
    echo "FAIL — ${name}: exit ${got} as expected, but output did not match /${want_re}/"
    echo "$out" | sed 's/^/       /'
    failures=$((failures + 1))
    return
  fi

  echo "ok   — ${name}"
}

noop() { :; }

# mutate FILE SED_EXPR — apply a sed in-place mutation and verify it took effect.
# A no-op mutation (pattern not found) fails loudly so the test proves nothing.
mutate() {
  local file="$1" expr="$2" before after
  before=$(cksum < "$file")
  sed -i.bak "$expr" "$file"
  after=$(cksum < "$file")
  if [[ "$before" == "$after" ]]; then
    echo "       FIXTURE ERROR — no-op mutation on ${file}: ${expr}" >&2
    return 90
  fi
}

append_line() { printf '\n%s\n' "$2" >> "$1"; }

# ---------------------------------------------------------------------------
# Test cases
# ---------------------------------------------------------------------------

# 1. Clean fixture passes.
expect "clean fixture passes" 0 'model-drift-lint: OK' noop

# 2. Opus 4.8 in a live rules file fails.
expect "Opus 4.8 in rules file fails" 1 \
  'Legacy model version in live surface' \
  append_line .claude/rules/subagent-orchestration.md \
    'Historical note: Opus 4.8 was previously used for Phase A.'

# 3. Sonnet 4.6 in a live rules file fails.
expect "Sonnet 4.6 in rules file fails" 1 \
  'Legacy model version in live surface' \
  append_line .claude/rules/subagent-orchestration.md \
    'Historical note: Sonnet 4.6 was previously used for Phase C.'

# 4. Opus 4.8 in CLAUDE.md fails.
expect "Opus 4.8 in CLAUDE.md fails" 1 \
  'Legacy model version in live surface' \
  append_line CLAUDE.md 'Phase A default: Opus 4.8'

# 5. Opus 4.8 in a skills file fails.
expect "Opus 4.8 in skills file fails" 1 \
  'Legacy model version in live surface' \
  append_line .claude/skills/example-skill/SKILL.md \
    'Step up to Opus 4.8 for heavy analysis.'

# 6. Opus 4.8 in an agents file fails.
expect "Opus 4.8 in agents file fails" 1 \
  'Legacy model version in live surface' \
  append_line .claude/agents/phase-a-fixer.md \
    'Previous generation used Opus 4.8.'

# 7. Reference dir is EXEMPT — Opus 4.8 there does NOT fail.
# (The reference file already contains legacy names — see make_fixture.)
expect "Opus 4.8 in reference dir is exempt (passes)" 0 \
  'model-drift-lint: OK' \
  noop

# 8. Haiku 4.5 in a live file does NOT fire (Haiku excluded by design).
expect "Haiku 4.5 in live surface passes (Haiku excluded)" 0 \
  'model-drift-lint: OK' \
  append_line CLAUDE.md 'Light tier: Haiku 4.5'

# 9. Generational prose "Opus 4.x" does NOT fire (x is not a digit).
# The base fixture already has "Opus 4.x" in the skills file — verify clean.
expect "Opus 4.x generational prose passes (not a digit)" 0 \
  'model-drift-lint: OK' \
  noop

# 10. Sonnet 4.x generational prose passes.
expect "Sonnet 4.x generational prose passes" 0 \
  'model-drift-lint: OK' \
  append_line .claude/rules/subagent-orchestration.md \
    'Legacy tier includes Sonnet 4.x models.'

# 11. Error output names the offending file for actionability.
expect "error output names the offending file" 1 \
  'subagent-orchestration\.md' \
  append_line .claude/rules/subagent-orchestration.md \
    'Was: Opus 4.8 for Phase A.'

# 12. Multiple hits produce multiple errors.
plant_two_hits() {
  append_line .claude/rules/subagent-orchestration.md 'Was: Opus 4.8.'
  append_line CLAUDE.md 'Was: Sonnet 4.6.'
}
expect "multiple hits produce multiple error lines" 1 \
  'model-drift-lint: 2 legacy' \
  plant_two_hits

# ---------------------------------------------------------------------------
# Revert-verify: confirm the test suite itself would catch an unguarded repo.
# Plant drift into the real repo tree and assert the lint fails there too.
# This ensures the test is not trivially passing against a misbuilt lint.
# ---------------------------------------------------------------------------
echo ""
echo "--- revert-verify: lint must fail on planted drift in real repo ---"

REAL_PLANTED=$(mktemp "${TMPDIR:-/tmp}/model-drift-revert-verify-XXXXXX.md")
# Write a planted-drift file into a live-surface directory of the real repo.
# We use a temp file in .claude/rules/ so the lint scans it, then clean up.
# Declare PLANTED_FILE before the trap so the trap covers it on interruption.
REAL_RULES_DIR="${REPO_ROOT}/.claude/rules"
PLANTED_FILE="${REAL_RULES_DIR}/_model-drift-lint-revert-verify-$$.md"
trap 'rm -f "$REAL_PLANTED" "$PLANTED_FILE"; rm -rf "$TMP_ROOT"' EXIT
printf 'Legacy tier: Opus 4.8 was used for Phase A.\n' > "$PLANTED_FILE"

revert_verify_ok=0
if ( cd "$REPO_ROOT" && bash "$LINT" >/dev/null 2>&1 ); then
  echo "FAIL — revert-verify: lint passed on repo with planted drift (should have failed)"
  failures=$((failures + 1))
  revert_verify_ok=1
else
  echo "ok   — revert-verify: lint correctly failed on planted drift"
fi

rm -f "$PLANTED_FILE"

# Clean repo should pass.
if ! ( cd "$REPO_ROOT" && bash "$LINT" >/dev/null 2>&1 ); then
  echo "FAIL — real repo conformance: lint fails on the real repo (unexpected)"
  ( cd "$REPO_ROOT" && bash "$LINT" 2>&1 | sed 's/^/       /') || true
  failures=$((failures + 1))
else
  echo "ok   — real repo conformance is intact"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
if (( failures > 0 )); then
  echo ""
  echo "model-drift-lint.test: ${failures} failure(s)"
  exit 1
fi

echo ""
echo "OK: model-drift-lint tests passed (${case_num} fixtures + revert-verify)"
