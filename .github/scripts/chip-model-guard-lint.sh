#!/usr/bin/env bash
# Lint chip model-guard conformance across canonical emitters (issue #731).
#
# Validates:
#   1. chip-launching.md defines the full contract: MODEL GUARD preamble,
#      all five canonical emitters, first-line/no-blank-line placement,
#      short-summary format, and Fable pre-click warning guidance.
#   2. Each canonical emitter SKILL.md requires spawn_task, **Model:** as
#      first prompt line, model-guard preamble (no blank line), short-summary
#      repetition, and Fable pre-click warning when parent/chip models differ.
#   3. chip-model-guard-decision.md references all five emitters.
#   4. Global enforcement exists in chip-spawn.md (indexed from CLAUDE.md).
#
# Companion to rule-lint.sh / skill-catalog-lint.sh. Run from repo root.
# Output uses GitHub Actions annotations. Exits 1 on any error.

set -euo pipefail

CHIP_LAUNCHING=".claude/reference/chip-launching.md"
CHIP_DECISION=".claude/reference/chip-model-guard-decision.md"
CHIP_RULE=".claude/rules/chip-spawn.md"
CLAUDE_MD="CLAUDE.md"
SKILLS_DIR=".claude/skills"

CANONICAL_EMITTERS=(pm prompt start-issue issue-maker wave)

errors=0

usage() {
  cat <<'EOF'
Usage: .github/scripts/chip-model-guard-lint.sh

  Verifies chip model-line + MODEL GUARD requirements have not drifted.
  No options. Run from the repo root. Exits 1 on any error.
EOF
}

while (( $# > 0 )); do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "::error::Unknown argument: $1"
      usage >&2
      exit 2
      ;;
  esac
  shift
done

require_file() {
  local f="$1"
  if [[ ! -f "$f" ]]; then
    echo "::error file=${f}::Required file not found"
    errors=$((errors + 1))
    return 1
  fi
}

require_pattern() {
  local file="$1" pattern="$2" label="$3"
  if ! grep -qE "$pattern" "$file"; then
    echo "::error file=${file}::Missing required ${label} (expected /${pattern}/)"
    errors=$((errors + 1))
  fi
}

require_file "$CHIP_LAUNCHING" || true
require_file "$CHIP_DECISION" || true
require_file "$CHIP_RULE" || true
require_file "$CLAUDE_MD" || true

# --- 1. chip-launching.md contract ---------------------------------------
if [[ -f "$CHIP_LAUNCHING" ]]; then
  require_pattern "$CHIP_LAUNCHING" 'MODEL GUARD:' 'MODEL GUARD preamble marker'
  require_pattern "$CHIP_LAUNCHING" 'Your very first action' 'guard first-action text'
  require_pattern "$CHIP_LAUNCHING" 'five canonical emitters' 'canonical emitters preamble'
  require_pattern "$CHIP_LAUNCHING" 'first line of the `prompt`' 'first-line placement rule'
  require_pattern "$CHIP_LAUNCHING" 'no blank line' 'no-blank-line placement rule'
  require_pattern "$CHIP_LAUNCHING" 'Short-summary transcript format' 'short-summary format section'
  require_pattern "$CHIP_LAUNCHING" 'Fable 5 parent' 'Fable pre-click warning guidance'
  require_pattern "$CHIP_LAUNCHING" 'Upstream requirement' 'upstream requirement section'
  require_pattern "$CHIP_LAUNCHING" '#735' 'upstream tracking issue link'

  for skill in "${CANONICAL_EMITTERS[@]}"; do
    require_pattern "$CHIP_LAUNCHING" "/${skill}" "chip-launching /${skill} emitter reference"
  done
fi

# --- 2. Canonical emitter skills -----------------------------------------
for skill in "${CANONICAL_EMITTERS[@]}"; do
  skill_file="${SKILLS_DIR}/${skill}/SKILL.md"
  if [[ ! -f "$skill_file" ]]; then
    echo "::error::${skill_file} not found — canonical chip emitter missing"
    errors=$((errors + 1))
    continue
  fi

  require_pattern "$skill_file" 'spawn_task' "${skill} spawn_task reference"
  require_pattern "$skill_file" '\*\*Model:\*\*' "${skill} **Model:** requirement"
  require_pattern "$skill_file" 'model-guard preamble|MODEL GUARD' "${skill} model-guard requirement"
  require_pattern "$skill_file" 'first line|first prompt|MUST open|open the chip|MUST open with|first content|base block' "${skill} first-line **Model:** placement"
  require_pattern "$skill_file" 'no blank line' "${skill} no-blank-line guard placement"
  require_pattern "$skill_file" 'short summary|Short-summary transcript format' "${skill} short-summary repetition"
  require_pattern "$skill_file" 'Fable 5' "${skill} Fable pre-click warning requirement"
done

# --- 3. Decision record lists all five -----------------------------------
if [[ -f "$CHIP_DECISION" ]]; then
  for skill in "${CANONICAL_EMITTERS[@]}"; do
    require_pattern "$CHIP_DECISION" "/${skill}" "decision record /${skill} reference"
  done
fi

# --- 4. Global rule indexed from CLAUDE.md --------------------------------
if [[ -f "$CHIP_RULE" ]]; then
  require_pattern "$CHIP_RULE" 'spawn_task' 'chip-spawn.md spawn_task rule'
  require_pattern "$CHIP_RULE" 'MODEL GUARD' 'chip-spawn.md MODEL GUARD rule'
  require_pattern "$CHIP_RULE" 'chip-launching\.md' 'chip-spawn.md chip-launching reference'
  require_pattern "$CHIP_RULE" 'Fable 5' 'chip-spawn.md Fable pre-click warning rule'
fi

if [[ -f "$CLAUDE_MD" ]]; then
  require_pattern "$CLAUDE_MD" 'chip-spawn\.md' 'CLAUDE.md chip-spawn rule index entry'
fi

if (( errors > 0 )); then
  echo "chip-model-guard-lint: ${errors} error(s) found"
  exit 1
fi

echo "chip-model-guard-lint: OK (${#CANONICAL_EMITTERS[@]} emitters)"
