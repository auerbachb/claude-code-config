#!/usr/bin/env bash
# Unit tests for chip-model-guard-lint.sh (issue #731)

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
LINT="${REPO_ROOT}/.github/scripts/chip-model-guard-lint.sh"

TMP_ROOT=$(mktemp -d -t chip-model-guard-lint.XXXXXX)
trap 'rm -rf "$TMP_ROOT"' EXIT

failures=0
case_num=0

make_fixture() {
  local dir="$1"
  mkdir -p "$dir/.claude/reference" "$dir/.claude/rules" \
    "$dir/.claude/skills"/{pm,prompt,start-issue,issue-maker,wave}
  cp "$REPO_ROOT/.claude/reference/chip-launching.md" "$dir/.claude/reference/"
  cp "$REPO_ROOT/.claude/reference/chip-model-guard-decision.md" "$dir/.claude/reference/"
  cp "$REPO_ROOT/.claude/rules/chip-spawn.md" "$dir/.claude/rules/"
  cp "$REPO_ROOT/CLAUDE.md" "$dir/CLAUDE.md"
  for skill in pm prompt start-issue issue-maker wave; do
    cp "$REPO_ROOT/.claude/skills/${skill}/SKILL.md" "$dir/.claude/skills/${skill}/"
  done
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

expect "well-formed repo passes" 0 'chip-model-guard-lint: OK' noop

expect "missing MODEL GUARD in chip-launching fails" 1 \
  'Missing required MODEL GUARD preamble marker' \
  sed -i.bak '/MODEL GUARD:/d' .claude/reference/chip-launching.md

expect "missing /pm emitter in chip-launching fails" 1 \
  'chip-launching /pm emitter reference' \
  sed -i.bak '/\/pm/d' .claude/reference/chip-launching.md

expect "missing Fable guidance in chip-launching fails" 1 \
  'Fable pre-click warning guidance' \
  sed -i.bak '/Fable 5 parent/d' .claude/reference/chip-launching.md

expect "missing model-guard in pm skill fails" 1 \
  'pm model-guard requirement' \
  sed -i.bak '/model-guard preamble/d' .claude/skills/pm/SKILL.md

expect "missing first-line placement in wave skill fails" 1 \
  'wave first-line \*\*Model:\*\* placement' \
  sed -i.bak '/Chip model contract/d' .claude/skills/wave/SKILL.md

expect "missing Fable warning in start-issue skill fails" 1 \
  'start-issue Fable pre-click warning requirement' \
  sed -i.bak '/Fable 5/d' .claude/skills/start-issue/SKILL.md

expect "missing chip-spawn rule index fails" 1 \
  'CLAUDE.md chip-spawn rule index entry' \
  sed -i.bak '/chip-spawn\.md/d' CLAUDE.md

if (cd "$REPO_ROOT" && bash "$LINT" >/dev/null 2>&1); then
  echo "ok   — real repo conformance is intact"
else
  echo "FAIL — lint does not pass against the real repo"
  (cd "$REPO_ROOT" && bash "$LINT" 2>&1 | sed 's/^/       /') || true
  failures=$((failures + 1))
fi

if (( failures > 0 )); then
  echo "chip-model-guard-lint.test: ${failures} failure(s)"
  exit 1
fi

echo "OK: chip-model-guard-lint tests passed (${case_num} fixtures)"
