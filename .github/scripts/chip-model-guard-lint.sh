#!/usr/bin/env bash
# Lint chip model-guard conformance across canonical emitters (issue #731).
#
# Validates:
#   1. chip-launching.md still defines the MODEL GUARD preamble and lists all
#      five canonical emitters.
#   2. Each canonical emitter SKILL.md still requires spawn_task, **Model:**,
#      model-guard preamble, and short-summary model line.
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
  require_pattern "$CHIP_LAUNCHING" '/wave' 'wave emitter reference'
  require_pattern "$CHIP_LAUNCHING" '/issue-maker' 'issue-maker emitter reference'
  require_pattern "$CHIP_LAUNCHING" 'Upstream requirement' 'upstream requirement section'
  require_pattern "$CHIP_LAUNCHING" '#735' 'upstream tracking issue link'
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
  require_pattern "$skill_file" '\*\*Model:\*\*|`\\*\\*Model:\\*\\*`' "${skill} **Model:** requirement"
  require_pattern "$skill_file" 'model-guard preamble|MODEL GUARD' "${skill} model-guard requirement"

  if ! grep -qiE 'short summary|Short-summary transcript format' "$skill_file"; then
    echo "::error file=${skill_file}::Missing short-summary requirement for ${skill}"
    errors=$((errors + 1))
  fi
  if ! grep -qE '\*\*Model:\*\*|`\\*\\*Model:\\*\\*`' "$skill_file"; then
    echo "::error file=${skill_file}::Missing **Model:** line requirement for ${skill}"
    errors=$((errors + 1))
  fi
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
fi

if [[ -f "$CLAUDE_MD" ]]; then
  require_pattern "$CLAUDE_MD" 'chip-spawn\.md' 'CLAUDE.md chip-spawn rule index entry'
fi

if (( errors > 0 )); then
  echo "chip-model-guard-lint: ${errors} error(s) found"
  exit 1
fi

echo "chip-model-guard-lint: OK (${#CANONICAL_EMITTERS[@]} emitters)"
