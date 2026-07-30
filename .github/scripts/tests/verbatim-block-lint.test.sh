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
# The substitution target must be a string that appears inside the MINDSET block
# and nowhere else in the copy file — otherwise the sed is a no-op there, no drift
# is injected, and this negative test silently passes for the wrong reason (#810).
# The guard below fails loudly if a future reword breaks that assumption.
DRIFT_TOKEN='ANY provider'

# The token is used unescaped as a sed pattern, so keep it metacharacter-free.
if [[ ! "$DRIFT_TOKEN" =~ ^[A-Za-z0-9\ ]+$ ]]; then
  echo "FAIL — drift token '${DRIFT_TOKEN}' must contain only letters, digits, and spaces"
  failures=$(( failures + 1 ))
fi

# Count fixed-string OCCURRENCES, not matching lines: grep -c collapses two hits
# on one line to 1, which would let a non-unique token slip through this guard.
for copy in .claude/skills/subagent/SKILL.md; do
  # grep exits 1 on no match; under `set -euo pipefail` that would abort the whole
  # script before this guard could report — the exact case it exists to catch. Fail
  # closed to 0 instead, which trips the != 1 branch below.
  occurrences=$(grep -o -F -- "$DRIFT_TOKEN" "${REPO_ROOT}/${copy}" 2>/dev/null | wc -l | tr -d '[:space:]') || occurrences=0
  [[ "$occurrences" =~ ^[0-9]+$ ]] || occurrences=0
  if (( occurrences != 1 )); then
    echo "FAIL — drift fixture token '${DRIFT_TOKEN}' occurs ${occurrences}x in ${copy};" \
         "pick a token that appears exactly once, inside the MINDSET block"
    failures=$(( failures + 1 ))
  fi
done

expect "drifted MINDSET in subagent SKILL.md fails naming file and block" 1 \
  'MINDSET.*drifted|drifted.*MINDSET' \
  sed -i.bak "s/${DRIFT_TOKEN}/DRIFTED provider/" \
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
