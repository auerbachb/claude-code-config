#!/usr/bin/env bash
# Unit tests for chip-model-guard-lint.sh (issue #731)

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
LINT="${REPO_ROOT}/.github/scripts/chip-model-guard-lint.sh"

TMP_ROOT=$(mktemp -d -t chip-model-guard-lint.XXXXXX)
trap 'rm -rf "$TMP_ROOT"' EXIT

failures=0
case_num=0

# Canonical emitters, split by class (issue #770). Literal emitters name the
# model; resolver emitters look it up via model-fleet.sh and must contain no
# model literal at all.
LITERAL_EMITTERS=(pm prompt start-issue issue-maker wave)
RESOLVER_EMITTERS=(harness-audit)
ALL_EMITTERS=("${LITERAL_EMITTERS[@]}" "${RESOLVER_EMITTERS[@]}")

make_fixture() {
  local dir="$1" skill
  mkdir -p "$dir/.claude/reference" "$dir/.claude/rules"
  for skill in "${ALL_EMITTERS[@]}"; do
    mkdir -p "$dir/.claude/skills/${skill}"
  done
  cp "$REPO_ROOT/.claude/reference/chip-launching.md" "$dir/.claude/reference/"
  cp "$REPO_ROOT/.claude/reference/chip-model-guard-decision.md" "$dir/.claude/reference/"
  cp "$REPO_ROOT/.claude/rules/chip-spawn.md" "$dir/.claude/rules/"
  cp "$REPO_ROOT/CLAUDE.md" "$dir/CLAUDE.md"
  for skill in "${ALL_EMITTERS[@]}"; do
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

# --- sixth emitter + resolver class (issue #770) -----------------------------

expect "missing /harness-audit emitter in chip-launching fails" 1 \
  'chip-launching /harness-audit emitter reference' \
  sed -i.bak '/harness-audit/d' .claude/reference/chip-launching.md

expect "missing /harness-audit in decision record fails" 1 \
  'decision record /harness-audit reference' \
  sed -i.bak '/harness-audit/d' .claude/reference/chip-model-guard-decision.md

expect "deleted harness-audit skill fails" 1 \
  'canonical chip emitter missing' \
  rm -f .claude/skills/harness-audit/SKILL.md

# The resolver emitter is checked on the resolver reference, NOT on a model
# literal — dropping model-fleet.sh means it can no longer resolve a tier.
expect "resolver emitter without model-fleet.sh fails" 1 \
  'harness-audit model-fleet.sh resolver reference' \
  sed -i.bak '/model-fleet\.sh/d' .claude/skills/harness-audit/SKILL.md

expect "resolver emitter without pre-click warning fails" 1 \
  'harness-audit pre-click warning requirement' \
  sed -i.bak '/pre-click/d' .claude/skills/harness-audit/SKILL.md

# The inverted check: a hardcoded model name in a resolver emitter is an error,
# because it reintroduces exactly the drift the resolver removes (#749).
plant_model_literal() {
  printf '\nRecommend Opus 5 for this pass.\n' >> .claude/skills/harness-audit/SKILL.md
}
expect "model literal planted in resolver emitter fails" 1 \
  'must not hardcode a model name' \
  plant_model_literal

plant_api_id_literal() {
  printf '\nUse claude-fable-5 for the judgment pass.\n' >> .claude/skills/harness-audit/SKILL.md
}
expect "api-id model literal in resolver emitter fails" 1 \
  'must not hardcode a model name' \
  plant_api_id_literal

# Bare aliases are caught only in a model-value position, so both field spellings
# must trip the check.
plant_alias_model_field() {
  printf '\nmodel: opus\n' >> .claude/skills/harness-audit/SKILL.md
}
expect "bare alias in a model: field fails" 1 \
  'must not hardcode a bare model alias' \
  plant_alias_model_field

plant_capitalized_alias() {
  printf '\nmodel: Opus\n' >> .claude/skills/harness-audit/SKILL.md
}
expect "capitalized alias in a model: field fails" 1 \
  'must not hardcode a bare model alias' \
  plant_capitalized_alias

plant_uppercase_literal() {
  printf '\nUse CLAUDE-OPUS-5 for this pass.\n' >> .claude/skills/harness-audit/SKILL.md
}
expect "uppercase api-id literal fails" 1 \
  'must not hardcode a model name' \
  plant_uppercase_literal

plant_alias_chip_line() {
  printf '\n**Model:** sonnet — cheap pass\n' >> .claude/skills/harness-audit/SKILL.md
}
expect "bare alias on a **Model:** line fails" 1 \
  'must not hardcode a bare model alias' \
  plant_alias_chip_line

# ...and prose that merely contains the word must NOT trip it, or the check is
# unusable in any document that discusses model tiers.
plant_alias_in_prose() {
  printf '\nThe fleet spans fable, opus, sonnet, and haiku tiers.\n' >> .claude/skills/harness-audit/SKILL.md
}
expect "bare alias in ordinary prose still passes" 0 \
  'chip-model-guard-lint: OK' \
  plant_alias_in_prose

# A literal emitter must NOT be subject to the inverted rule — naming the model
# is the whole point there. This guards against the classes being swapped.
plant_literal_in_pm() {
  printf '\nFable 5 remains the top tier for this pass.\n' >> .claude/skills/pm/SKILL.md
}
expect "model literal in a literal emitter still passes" 0 \
  'chip-model-guard-lint: OK' \
  plant_literal_in_pm

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
