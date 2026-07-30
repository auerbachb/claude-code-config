#!/usr/bin/env bash
# Unit tests for verbatim-block-lint.sh (issue #767)
#
# Covers three required cases per the acceptance criteria:
#   (a) clean repo passes with exit 0
#   (b) a drifted verbatim copy fails naming the specific file/block
#   (c) a missing copy file fails
# Plus a bonus case:
#   (d) a missing block within a copy file fails

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
LINT="${REPO_ROOT}/.github/scripts/verbatim-block-lint.sh"

TMP_ROOT=$(mktemp -d -t verbatim-block-lint.XXXXXX)
trap 'rm -rf "$TMP_ROOT"' EXIT

failures=0
case_num=0

make_fixture() {
  local dir="$1"
  mkdir -p \
    "$dir/.claude/rules" \
    "$dir/.claude/skills/subagent" \
    "$dir/.claude/skills/pr-monitor-and-manage"
  cp "$REPO_ROOT/.claude/rules/safety.md" "$dir/.claude/rules/"
  cp "$REPO_ROOT/.claude/rules/skill-first.md" "$dir/.claude/rules/"
  cp "$REPO_ROOT/.claude/skills/subagent/SKILL.md" \
     "$dir/.claude/skills/subagent/"
  cp "$REPO_ROOT/.claude/skills/pr-monitor-and-manage/SKILL.md" \
     "$dir/.claude/skills/pr-monitor-and-manage/"
}

expect() {
  local name="$1" want="$2" want_re="$3"; shift 3
  case_num=$(( case_num + 1 ))
  local dir="${TMP_ROOT}/case${case_num}"
  make_fixture "$dir"
  ( cd "$dir" && "$@" )

  local out got
  out=$(cd "$dir" && bash "$LINT" 2>&1) && got=0 || got=$?

  if (( got != want )); then
    echo "FAIL — ${name}: expected exit ${want}, got ${got}"
    echo "$out" | sed 's/^/       /'
    failures=$(( failures + 1 ))
    return
  fi

  if ! grep -qE "$want_re" <<< "$out"; then
    echo "FAIL — ${name}: exit ${got} as expected, but output did not match /${want_re}/"
    echo "$out" | sed 's/^/       /'
    failures=$(( failures + 1 ))
    return
  fi

  echo "ok   — ${name}"
}

noop() { :; }

# (a) Clean repo passes
expect "well-formed repo passes" 0 'verbatim-block-lint: OK' noop

# (b) Drifted verbatim copy fails naming the file and block
expect "drifted MINDSET in subagent SKILL.md fails naming file and block" 1 \
  'MINDSET.*drifted|drifted.*MINDSET' \
  sed -i.bak 's/capability ladder/DRIFTED ladder/' \
    .claude/skills/subagent/SKILL.md

# (c) Missing copy file fails
expect "missing copy file fails" 1 \
  'Required file not found' \
  rm -f .claude/skills/subagent/SKILL.md

# (d) Missing block within a copy file fails
expect "missing SKILLS block in subagent SKILL.md fails" 1 \
  'Missing SKILLS|SKILLS.*not found' \
  sed -i.bak 's/^SKILLS: /REMOVED: /' \
    .claude/skills/subagent/SKILL.md

# Final: real repo conformance
if (cd "$REPO_ROOT" && bash "$LINT" >/dev/null 2>&1); then
  echo "ok   — real repo conformance is intact"
else
  echo "FAIL — lint does not pass against the real repo"
  (cd "$REPO_ROOT" && bash "$LINT" 2>&1 | sed 's/^/       /') || true
  failures=$(( failures + 1 ))
fi

if (( failures > 0 )); then
  echo "verbatim-block-lint.test: ${failures} failure(s)"
  exit 1
fi

echo "OK: verbatim-block-lint tests passed (${case_num} fixtures)"
