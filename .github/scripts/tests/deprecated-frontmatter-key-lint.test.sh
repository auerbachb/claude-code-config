#!/usr/bin/env bash
# Unit tests for deprecated-frontmatter-key-lint.sh (issue #1170)
#
# Each case builds a hermetic git-tracked fixture tree and runs the lint.
# Inversion tests cover both flag directions:
#   - a case that should fail proves the lint fires on violations
#   - a case that should pass proves the lint does NOT fire on correct usage
#
# Auto-discovered by run-hook-tests.sh — no workflow edit needed.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
LINT="${REPO_ROOT}/.github/scripts/deprecated-frontmatter-key-lint.sh"

TMP_ROOT=$(mktemp -d -t dep-fm-lint.XXXXXX)
trap 'rm -rf "$TMP_ROOT"' EXIT

failures=0
case_num=0

# ---------------------------------------------------------------------------
# make_fixture DIR
#
# Build a minimal well-formed fixture tree with:
#   - one restricted agent (phase-c-merger.md with tools:)
#   - one restricted agent (researcher.md with tools:)
#   - one unrestricted agent (phase-a-fixer.md, no tools:)
#   - one skill file (.claude/skills/my-skill/SKILL.md) with allowed-tools:
#     frontmatter (correct for skills — must NOT be flagged)
#
# The fixture is initialized as a git repo so git ls-files works.
# ---------------------------------------------------------------------------
make_fixture() {
  local dir="$1"
  mkdir -p "${dir}/.claude/agents" \
            "${dir}/.claude/skills/my-skill" \
            "${dir}/.claude/reference"

  # Restricted agent — must retain tools: for canary to pass
  cat > "${dir}/.claude/agents/phase-c-merger.md" <<'EOF'
---
name: phase-c-merger
description: Phase C merger agent.
model: sonnet
tools: Read, Glob, Grep, Bash
---

Phase C merger body.
EOF

  # Second restricted agent
  cat > "${dir}/.claude/agents/researcher.md" <<'EOF'
---
name: researcher
description: Read-only researcher agent.
model: sonnet
tools: Read, Glob, Grep
---

Researcher body.
EOF

  # Unrestricted agent (no tools:) — canary should not fire on this one
  cat > "${dir}/.claude/agents/phase-a-fixer.md" <<'EOF'
---
name: phase-a-fixer
description: Phase A fixer agent.
model: opus
---

Phase A fixer body.
EOF

  # Skill file with allowed-tools: in frontmatter — correct and must NOT be flagged
  cat > "${dir}/.claude/skills/my-skill/SKILL.md" <<'EOF'
---
name: my-skill
description: Example skill.
allowed-tools:
  - Read
  - Bash
---

Skill body text.
EOF

  # Reference file with allowed-tools: mention but NOT agent-scoped — must NOT be flagged
  cat > "${dir}/.claude/reference/browser-cap.md" <<'EOF'
## Subagent reachability

The deprecated `allowed-tools:` key is the skill frontmatter key and is
silently ignored on an agent definition.
EOF

  # Initialize git and stage all files
  ( cd "$dir" && git init -q && git add . )
}

# ---------------------------------------------------------------------------
# expect NAME WANT_EXIT WANT_REGEX [MUTATOR CMD...]
#
# Builds a fresh fixture, applies the optional mutator (run from inside the
# fixture dir), runs the lint, and asserts exit code + output regex.
# ---------------------------------------------------------------------------
expect() {
  local name="$1" want="$2" want_re="$3"; shift 3
  case_num=$((case_num + 1))
  local dir="${TMP_ROOT}/case${case_num}"
  make_fixture "$dir"

  if [[ "$#" -gt 0 ]] && [[ "$1" != "noop" ]]; then
    ( cd "$dir" && "$@" )
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

# ---------------------------------------------------------------------------
# Test cases
# ---------------------------------------------------------------------------

# 1. Clean fixture passes.
expect "clean fixture passes" 0 \
  'deprecated-frontmatter-key-lint: OK' \
  noop

# 2. INVERSION — Agent file (in .claude/agents/) with allowed-tools: and no
#    marker FAILS. This is the core detection case.
expect "agent file with allowed-tools: and no marker fails" 1 \
  "Deprecated frontmatter key 'allowed-tools:'" \
  bash -c 'printf "\nThe deprecated allowed-tools: key was renamed to tools:.\n" >> .claude/agents/phase-a-fixer.md && git add .'

# 3. INVERSION — Prose line containing .claude/agents/ path AND allowed-tools:
#    with no marker FAILS (agent-scoped via line co-occurrence).
expect "prose co-occurrence of allowed-tools: and .claude/agents/ path fails" 1 \
  "Deprecated frontmatter key 'allowed-tools:'" \
  bash -c 'printf "\nUse tools: not allowed-tools: in .claude/agents/*.md frontmatter.\n" >> .claude/reference/browser-cap.md && git add .'

# 4. INVERSION — Skill file with allowed-tools: in frontmatter PASSES
#    (NOT agent-scoped — skill files are exempt).
expect "skill file with allowed-tools: in frontmatter passes" 0 \
  'deprecated-frontmatter-key-lint: OK' \
  noop

# 5. Opt-out marker on same line suppresses the error.
expect "opt-out marker on same line suppresses error" 0 \
  'deprecated-frontmatter-key-lint: OK' \
  bash -c 'printf "\nThe allowed-tools: key was renamed to tools:. <!-- deprecated-key-ok: allowed-tools -->\n" >> .claude/agents/phase-a-fixer.md && git add .'

# 6. Opt-out marker on immediately preceding line suppresses the error.
expect "opt-out marker on preceding line suppresses error" 0 \
  'deprecated-frontmatter-key-lint: OK' \
  bash -c 'printf "\n<!-- deprecated-key-ok: allowed-tools -->\nThe allowed-tools: key was renamed to tools:.\n" >> .claude/agents/phase-a-fixer.md && git add .'

# 7. Fenced code block with .claude/agents/ AND allowed-tools: with no marker
#    FAILS (agent-scoped via fenced block).
expect "fenced block with agents path and allowed-tools: fails" 1 \
  "Deprecated frontmatter key 'allowed-tools:'" \
  bash -c 'cat >> .claude/reference/browser-cap.md <<'"'"'MDEOF'"'"'

```bash
for f in .claude/agents/*.md; do
  grep "^allowed-tools:" "$f" || echo "(none)"
done
```
MDEOF
git add .'

# 8. Fenced code block with .claude/agents/ AND opt-out marker in block PASSES.
expect "fenced block with agents path and opt-out marker in block passes" 0 \
  'deprecated-frontmatter-key-lint: OK' \
  bash -c 'cat >> .claude/reference/browser-cap.md <<'"'"'MDEOF'"'"'

```bash
# <!-- deprecated-key-ok: allowed-tools -->
for f in .claude/agents/*.md; do
  grep "^allowed-tools:" "$f" || echo "(none)"
done
```
MDEOF
git add .'

# 9. CANARY — Restricted agent loses tools: key → FAILS.
expect "canary fails when restricted agent loses tools: key" 1 \
  "Canary:" \
  bash -c 'sed -i.bak "/^tools: Read/d" .claude/agents/phase-c-merger.md && git add .'

# 10. Reference file with allowed-tools: mention NOT in agent-scoped context
#     PASSES (the non-scoped prose in .claude/reference/ is exempt).
expect "non-agent-scoped allowed-tools: in reference file passes" 0 \
  'deprecated-frontmatter-key-lint: OK' \
  noop

# 11. Both opt-out marker forms: fenced block marker covers all occurrences in block.
expect "single marker in fenced block covers multiple occurrences" 0 \
  'deprecated-frontmatter-key-lint: OK' \
  bash -c 'cat >> .claude/reference/browser-cap.md <<'"'"'MDEOF'"'"'

```bash
# <!-- deprecated-key-ok: allowed-tools -->
# allowed-tools: was used before, now tools: is correct
for f in .claude/agents/*.md; do
  grep "^allowed-tools:" "$f" || echo "(none)"
done
```
MDEOF
git add .'

# 12. --help exits 0.
case_num=$((case_num + 1))
help_dir="${TMP_ROOT}/case${case_num}"
make_fixture "$help_dir"
if (cd "$help_dir" && bash "$LINT" --help >/dev/null 2>&1); then
  echo "ok   — --help exits 0"
else
  echo "FAIL — --help should exit 0"
  failures=$((failures + 1))
fi

# 13. Unknown argument exits 2.
case_num=$((case_num + 1))
bogus_dir="${TMP_ROOT}/case${case_num}"
make_fixture "$bogus_dir"
got_exit=0
(cd "$bogus_dir" && bash "$LINT" --bogus >/dev/null 2>&1) || got_exit=$?
if (( got_exit == 2 )); then
  echo "ok   — unknown arg exits 2"
else
  echo "FAIL — unknown arg: expected exit 2, got ${got_exit}"
  failures=$((failures + 1))
fi

# ---------------------------------------------------------------------------
# Revert-verify: plant a live-surface violation in the real repo and confirm
# the lint catches it.  This proves the test is not trivially passing against
# a broken lint.
# ---------------------------------------------------------------------------
echo ""
echo "--- revert-verify: lint must fail on planted violation in real repo ---"

AGENTS_DIR="${REPO_ROOT}/.claude/agents"
PLANTED_FILE="${AGENTS_DIR}/_dep-key-lint-revert-verify-$$.md"
trap 'rm -f "$PLANTED_FILE"; rm -rf "$TMP_ROOT"' EXIT

cat > "$PLANTED_FILE" <<'EOF'
---
name: _revert-verify-placeholder
description: Temporary revert-verify fixture — must not survive the test.
model: sonnet
---

This is a test fixture. The following line should be flagged by the lint:
The deprecated allowed-tools: key was renamed to tools:.
EOF
( cd "$REPO_ROOT" && git add "$PLANTED_FILE" 2>/dev/null ) || true

revert_verify_ok=0
if ( cd "$REPO_ROOT" && bash "$LINT" >/dev/null 2>&1 ); then
  echo "FAIL — revert-verify: lint passed on repo with planted violation (should have failed)"
  failures=$((failures + 1))
  revert_verify_ok=1
else
  echo "ok   — revert-verify: lint correctly failed on planted violation"
fi

rm -f "$PLANTED_FILE"
( cd "$REPO_ROOT" && git rm --cached "$PLANTED_FILE" 2>/dev/null ) || true

# Real-repo conformance: the actual repo should pass after fixture cleanup.
if ! ( cd "$REPO_ROOT" && bash "$LINT" >/dev/null 2>&1 ); then
  echo "FAIL — real-repo conformance: lint fails on the real repo (unexpected)"
  ( cd "$REPO_ROOT" && bash "$LINT" 2>&1 | sed 's/^/       /') || true
  failures=$((failures + 1))
else
  echo "ok   — real-repo conformance is intact"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
if (( failures > 0 )); then
  echo ""
  echo "deprecated-frontmatter-key-lint.test: ${failures} failure(s)"
  exit 1
fi

echo ""
echo "OK: deprecated-frontmatter-key-lint tests passed (${case_num} fixtures + revert-verify)"
