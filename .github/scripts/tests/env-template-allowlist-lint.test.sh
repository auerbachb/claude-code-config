#!/usr/bin/env bash
# Unit tests for env-template-allowlist-lint.sh (issue #877)
#
# Covers the three required cases per the acceptance criteria:
#   (a) clean repo passes with exit 0
#   (b) a drifted surface fails naming the specific file
#   (c) a missing required token fails

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
LINT="${REPO_ROOT}/.github/scripts/env-template-allowlist-lint.sh"

TMP_ROOT=$(mktemp -d -t env-template-allowlist-lint.XXXXXX)
trap 'rm -rf "$TMP_ROOT"' EXIT

failures=0
case_num=0

make_fixture() {
  local dir="$1"
  mkdir -p \
    "$dir/.claude/agents" \
    "$dir/.claude/rules" \
    "$dir/.claude/skills/pr-review-help"
  for agent in phase-a-fixer phase-b-reviewer phase-c-merger pm-worker README; do
    cp "$REPO_ROOT/.claude/agents/${agent}.md" "$dir/.claude/agents/"
  done
  cp "$REPO_ROOT/.claude/skills/pr-review-help/SKILL.md" \
     "$dir/.claude/skills/pr-review-help/"
  cp "$REPO_ROOT/.claude/rules/safety.md" "$dir/.claude/rules/"
}

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

# Injects drift into a prompt surface by adding the forbidden suffixes back.
inject_dist_tpl() {
  local file="$1"
  sed -i.bak 's/\.env\.<example|sample|template>/.env.<example|sample|template|dist|tpl>/g' "$file"
}

# Injects partial drift: adds only |dist after the canonical suffixes (no |tpl).
inject_dist_only() {
  local file="$1"
  sed -i.bak 's/\.env\.<example|sample|template>/.env.<example|sample|template|dist>/g' "$file"
}

# Removes the canonical token from a file to simulate a missing allow-list.
remove_prompt_token() {
  local file="$1"
  sed -i.bak 's/\.env\.<example|sample|template>//g' "$file"
}

# Removes the prose token from safety.md.
remove_prose_token() {
  sed -i.bak 's/\.env\.{example,sample,template}//g' .claude/rules/safety.md
}

# --- Positive case -----------------------------------------------------------
expect "well-formed repo passes" 0 'env-template-allowlist-lint: OK' noop

# --- Drift injection cases ---------------------------------------------------
expect "phase-a-fixer with dist|tpl suffix fails" 1 \
  'phase-a-fixer.md' \
  inject_dist_tpl .claude/agents/phase-a-fixer.md

expect "phase-a-fixer with dist-only suffix fails (partial-append gap)" 1 \
  'phase-a-fixer.md' \
  inject_dist_only .claude/agents/phase-a-fixer.md

expect "phase-b-reviewer with dist|tpl suffix fails" 1 \
  'phase-b-reviewer.md' \
  inject_dist_tpl .claude/agents/phase-b-reviewer.md

expect "phase-c-merger with dist|tpl suffix fails" 1 \
  'phase-c-merger.md' \
  inject_dist_tpl .claude/agents/phase-c-merger.md

expect "pm-worker with dist|tpl suffix fails" 1 \
  'pm-worker.md' \
  inject_dist_tpl .claude/agents/pm-worker.md

expect "pr-review-help SKILL.md with dist|tpl suffix fails" 1 \
  'SKILL.md' \
  inject_dist_tpl .claude/skills/pr-review-help/SKILL.md

# --- Missing canonical token cases -------------------------------------------
expect "phase-a-fixer missing prompt token fails" 1 \
  'phase-a-fixer.md' \
  remove_prompt_token .claude/agents/phase-a-fixer.md

expect "safety.md missing prose token fails" 1 \
  'safety.md' \
  remove_prose_token

# --- Real repo conformance ---------------------------------------------------
if (cd "$REPO_ROOT" && bash "$LINT" >/dev/null 2>&1); then
  echo "ok   — real repo conformance is intact"
else
  echo "FAIL — lint does not pass against the real repo"
  (cd "$REPO_ROOT" && bash "$LINT" 2>&1 | sed 's/^/       /') || true
  failures=$((failures + 1))
fi

if (( failures > 0 )); then
  echo "env-template-allowlist-lint.test: ${failures} failure(s)"
  exit 1
fi

echo "OK: env-template-allowlist-lint tests passed (${case_num} fixtures)"
