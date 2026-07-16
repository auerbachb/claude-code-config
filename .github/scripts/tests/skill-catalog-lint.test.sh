#!/usr/bin/env bash
# Unit tests for skill-catalog-lint.sh (issue #591)
#
# The lint reads repo-root-relative paths, so each case builds a throwaway
# fixture tree and runs the script with that tree as cwd.
#
# Every failure mode gets an explicit case: a guard asserted only on
# well-formed input would pass without proving it catches anything.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
LINT="${REPO_ROOT}/.github/scripts/skill-catalog-lint.sh"

TMP_ROOT=$(mktemp -d -t skill-catalog-lint.XXXXXX)
trap 'rm -rf "$TMP_ROOT"' EXIT

failures=0
case_num=0

# Build a well-formed fixture: 2 skills, 2 matching rows, both counts = 2.
make_fixture() {
  local dir="$1"
  mkdir -p "$dir/.claude/skills/alpha" "$dir/.claude/skills/beta"
  echo "alpha" > "$dir/.claude/skills/alpha/SKILL.md"
  echo "beta" > "$dir/.claude/skills/beta/SKILL.md"
  cat > "$dir/README.md" <<'EOF'
# Fixture

- **Manage your project** — 2 slash commands for testing.

## Slash Commands

All 2 commands are invoked as `/command` in a Claude Code session.

| Command | Category | Description |
|---------|----------|-------------|
| `/alpha` | PM | First |
| `/beta` | Workflow | Second |
EOF
}

# expect <name> <expected-exit> <expected-output-regex> <mutator...>
# Builds a fresh fixture, applies the mutator, then asserts BOTH the exit
# status and that the output matches the regex. Asserting the message too
# is what stops a case from passing on an unrelated error (a typo or a
# syntax break also exits non-zero, and would otherwise look like a pass).
expect() {
  local name="$1" want="$2" want_re="$3"; shift 3
  case_num=$((case_num + 1))
  local dir="${TMP_ROOT}/case${case_num}"
  make_fixture "$dir"
  ( cd "$dir" && "$@" )

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

# Inserts a command-shaped row ("| `/decoy` | ... |") before the
# '## Slash Commands' header, simulating an unrelated table elsewhere in the
# README that happens to start a row the same way a catalog row does.
insert_decoy_row_before_catalog() {
  local tmp
  tmp=$(mktemp)
  awk '
    { print }
    /^# Fixture/ && !done { print "\n| `/decoy` | Fake | Should be ignored |"; done=1 }
  ' README.md > "$tmp"
  mv "$tmp" README.md
}

# --- passing case ---------------------------------------------------------
expect "well-formed catalog passes" 0 'skill-catalog-lint: OK' noop

# --- alignment failures ---------------------------------------------------
# Each mutator isolates one failure mode: the added skill gets a SKILL.md so
# only the missing-row error fires, and the phantom case deletes a directory
# (rather than adding a row) so the row count still matches both anchors.
expect "skill dir with no README row fails" 1 \
  "Skill 'gamma' exists in .* but has no row" \
  bash -c 'mkdir -p .claude/skills/gamma && echo gamma > .claude/skills/gamma/SKILL.md'

expect "README row with no skill dir fails" 1 \
  "README documents '/beta' but no such skill exists" \
  rm -rf .claude/skills/beta

# --- structural failures --------------------------------------------------
expect "duplicate row fails" 1 \
  "Command '/alpha' has more than one row" \
  bash -c 'printf "%s\n" "| \`/alpha\` | PM | Dupe |" >> README.md'

expect "skill dir without SKILL.md fails" 1 \
  'gamma/ has no SKILL.md' \
  bash -c 'mkdir -p .claude/skills/gamma && printf "%s\n" "| \`/gamma\` | PM | No skill file |" >> README.md'

# --- section-scoping regression (CodeAnt finding on PR #594) ---------------
expect "row outside Slash Commands section is ignored" 0 \
  'skill-catalog-lint: OK' \
  insert_decoy_row_before_catalog

# --- count-anchor failures ------------------------------------------------
expect "stale 'slash commands' count fails" 1 \
  "count says 9 but the table has 2" \
  sed -i.bak 's/2 slash commands/9 slash commands/' README.md

expect "stale 'All N commands' count fails" 1 \
  "count says 9 but the table has 2" \
  sed -i.bak 's/All 2 commands/All 9 commands/' README.md

expect "missing 'slash commands' anchor fails" 1 \
  'Could not find.*count claim' \
  sed -i.bak '/slash commands/d' README.md

expect "missing 'All N commands' anchor fails" 1 \
  'Could not find.*count claim' \
  sed -i.bak '/All 2 commands are invoked/d' README.md

expect "ambiguous duplicated anchor fails" 1 \
  'matched 2 times.*anchor is ambiguous' \
  bash -c 'printf "%s\n" "All 2 commands are invoked again." >> README.md'

# --- CLI contract ---------------------------------------------------------
case_num=$((case_num + 1))
help_dir="${TMP_ROOT}/case${case_num}"
make_fixture "$help_dir"
if (cd "$help_dir" && bash "$LINT" --help >/dev/null 2>&1); then
  echo "ok   — --help exits 0"
else
  echo "FAIL — --help should exit 0"
  failures=$((failures + 1))
fi

got=0
(cd "$help_dir" && bash "$LINT" --bogus >/dev/null 2>&1) || got=$?
if (( got == 2 )); then
  echo "ok   — unknown arg exits 2"
else
  echo "FAIL — unknown arg: expected exit 2, got ${got}"
  failures=$((failures + 1))
fi

# --- real repo ------------------------------------------------------------
if (cd "$REPO_ROOT" && bash "$LINT" >/dev/null 2>&1); then
  echo "ok   — real repo catalog is in sync"
else
  echo "FAIL — lint does not pass against the real repo"
  (cd "$REPO_ROOT" && bash "$LINT" 2>&1 | sed 's/^/       /') || true
  failures=$((failures + 1))
fi

if (( failures > 0 )); then
  echo "skill-catalog-lint.test: ${failures} failure(s)"
  exit 1
fi

echo "OK: skill-catalog-lint tests passed (${case_num} fixtures)"
