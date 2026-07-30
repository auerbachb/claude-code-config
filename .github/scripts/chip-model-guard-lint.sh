#!/usr/bin/env bash
# Lint chip model-guard conformance across canonical emitters (issues #731, #791).
#
# Validates:
#   1. chip-launching.md defines the full contract: MODEL GUARD preamble,
#      the **Model:**/**Effort:** unit, all six canonical emitters,
#      first-line/no-blank-line placement, short-summary format, and the
#      parent/chip model-mismatch pre-click warning.
#   2. Each canonical emitter SKILL.md requires spawn_task, **Model:** as
#      first prompt line, an **Effort:** line, model-guard preamble (no blank
#      line), short-summary repetition, and the pre-click warning.
#   3. chip-model-guard-decision.md references all six emitters.
#   4. Global enforcement exists in chip-spawn.md (indexed from CLAUDE.md).
#   5. No versioned model name ("Opus 5", "Haiku 4.5", ...) appears anywhere
#      in the operative corpus — families only (#791). Dated .claude/reference/
#      audit records are deliberately out of scan scope; they are point-in-time
#      history (see .claude/reference/README.md).
#
# Two emitter classes (issue #770):
#   LITERAL emitters name the model directly, so the pre-click warning is
#   checked by grepping for the literal top-tier name.
#   RESOLVER emitters deliberately carry NO model name — they resolve the tier
#   at run time via .claude/scripts/model-fleet.sh so a fleet change is a
#   one-file edit. Grepping them for a literal would enforce the very drift the
#   resolver exists to remove, so for those the check INVERTS: require the
#   resolver reference and the pre-click warning, and FORBID any model literal.
#   That is strictly stronger than the literal check, not a carve-out.
#
# Companion to rule-lint.sh / skill-catalog-lint.sh. Run from repo root.
# Output uses GitHub Actions annotations. Exits 1 on any error.

set -euo pipefail

CHIP_LAUNCHING=".claude/reference/chip-launching.md"
CHIP_DECISION=".claude/reference/chip-model-guard-decision.md"
CHIP_RULE=".claude/rules/chip-spawn.md"
CLAUDE_MD="CLAUDE.md"
SKILLS_DIR=".claude/skills"

CANONICAL_EMITTERS=(pm prompt start-issue issue-maker wave harness-audit)

# Emitters that resolve the model tier at run time instead of naming it.
RESOLVER_EMITTERS=(harness-audit)

# Model literals a resolver emitter must never contain. Kept broad on purpose:
# a display name, an API id, or a bare alias in a `model:`/`**Model:**` slot all
# reintroduce the drift the resolver removes.
MODEL_LITERAL_RE='Fable 5|Opus 5|Sonnet 5|Haiku 4\.5|claude-fable|claude-opus|claude-sonnet|claude-haiku'

# Bare aliases (opus/sonnet/haiku/fable) are ordinary English-adjacent words and
# appear legitimately in prose, so matching them anywhere would false-positive.
# Match them only where they are being used AS the model value — a `model:`
# frontmatter/spawn field or a `**Model:**` chip line.
MODEL_ALIAS_RE='(\*\*Model:\*\*|\bmodel:)[[:space:]]*[`"'"'"'*]*(opus|sonnet|haiku|fable)\b'

is_resolver_emitter() {
  local candidate="$1" emitter
  for emitter in "${RESOLVER_EMITTERS[@]}"; do
    [[ "$emitter" == "$candidate" ]] && return 0
  done
  return 1
}

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
  require_pattern "$CHIP_LAUNCHING" 'six canonical emitters' 'canonical emitters preamble'
  require_pattern "$CHIP_LAUNCHING" 'first line of the `prompt`' 'first-line placement rule'
  require_pattern "$CHIP_LAUNCHING" 'no blank line' 'no-blank-line placement rule'
  require_pattern "$CHIP_LAUNCHING" 'Short-summary transcript format' 'short-summary format section'
  require_pattern "$CHIP_LAUNCHING" '\*\*Effort:\*\*' 'Effort line contract'
  require_pattern "$CHIP_LAUNCHING" 'Model and effort lines' 'model+effort placement section'
  require_pattern "$CHIP_LAUNCHING" 'Ultra code' 'Ultra-code-is-not-a-level guidance'
  require_pattern "$CHIP_LAUNCHING" 'Fable parent' 'Fable pre-click warning guidance'
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
  require_pattern "$skill_file" '\*\*Effort:\*\*' "${skill} **Effort:** requirement"
  require_pattern "$skill_file" 'model-guard preamble|MODEL GUARD' "${skill} model-guard requirement"
  require_pattern "$skill_file" 'first line|first prompt|MUST open|open the chip|MUST open with|first content|base block' "${skill} first-line **Model:** placement"
  require_pattern "$skill_file" 'no blank line' "${skill} no-blank-line guard placement"
  require_pattern "$skill_file" 'short summary|Short-summary transcript format' "${skill} short-summary repetition"

  if is_resolver_emitter "$skill"; then
    # Resolver emitter: the tier is looked up at run time, so the pre-click
    # warning cannot be checked by grepping for a model name. Require the
    # resolver and the warning, and forbid the literal outright.
    require_pattern "$skill_file" 'model-fleet\.sh' "${skill} model-fleet.sh resolver reference"
    require_pattern "$skill_file" 'pre-click' "${skill} pre-click warning requirement"
    # Case-insensitive: "OPUS", "Sonnet", and "claude-Fable-5" are the same
    # hardcoded name as their lowercase spellings, and a guard that only
    # catches one casing is a guard an author trips past by accident.
    if grep -qiE "$MODEL_LITERAL_RE" "$skill_file"; then
      echo "::error file=${skill_file}::Resolver emitter must not hardcode a model name (matched /${MODEL_LITERAL_RE}/i) — resolve it via .claude/scripts/model-fleet.sh instead"
      errors=$((errors + 1))
    fi
    if grep -qiE "$MODEL_ALIAS_RE" "$skill_file"; then
      echo "::error file=${skill_file}::Resolver emitter must not hardcode a bare model alias in a model field (matched /${MODEL_ALIAS_RE}/i) — resolve it via .claude/scripts/model-fleet.sh instead"
      errors=$((errors + 1))
    fi
  else
    # Literal emitter: require the pre-click warning in context, not a bare
    # mention of the model. Before #791 the literal "Fable 5" supplied that
    # context by itself; the versionless rename would have reduced it to a
    # match on any passing use of the word, so the phrase carries it now.
    require_pattern "$skill_file" 'parent thread is on Fable' "${skill} Fable pre-click warning requirement"
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
  require_pattern "$CHIP_RULE" '\*\*Effort:\*\*' 'chip-spawn.md Effort line rule'
  require_pattern "$CHIP_RULE" 'chip-launching\.md' 'chip-spawn.md chip-launching reference'
  require_pattern "$CHIP_RULE" 'parent thread is on Fable' 'chip-spawn.md Fable pre-click warning rule'
fi

if [[ -f "$CLAUDE_MD" ]]; then
  require_pattern "$CLAUDE_MD" 'chip-spawn\.md' 'CLAUDE.md chip-spawn rule index entry'
fi

# --- 5. No versioned model names in the operative corpus (#791) -----------
# Families only. `claude-opus-5` and `claude-haiku-4-5-20251001` do not match:
# the pattern requires "Family<space>digit", and those IDs are lowercase and
# hyphenated. Scope is the operative corpus plus the two living contract docs
# in .claude/reference/ — dated audit records there keep their versioned names
# by design (.claude/reference/README.md, "Audits and research").
VERSIONED_RE='(Opus|Sonnet|Fable|Haiku) [0-9]+(\.[0-9]+)?'

scan_targets=()
for target in "$CLAUDE_MD" .claude/rules .claude/skills .claude/agents \
              "$CHIP_LAUNCHING" "$CHIP_DECISION"; do
  # A missing path is not a violation — the lint's own test harness builds a
  # partial tree, and a repo may legitimately lack a directory.
  [[ -e "$target" ]] && scan_targets+=("$target")
done

if (( ${#scan_targets[@]} > 0 )); then
  while IFS= read -r hit; do
    [[ -n "$hit" ]] || continue
    hit_file="${hit%%:*}"
    hit_rest="${hit#*:}"
    hit_line="${hit_rest%%:*}"
    echo "::error file=${hit_file},line=${hit_line}::Versioned model name — use the bare family name (Opus/Sonnet/Fable/Haiku). See .claude/agents/README.md \"Model naming\" (#791)"
    errors=$((errors + 1))
  done < <(grep -rnE "$VERSIONED_RE" --include='*.md' "${scan_targets[@]}" || true)
fi

if (( errors > 0 )); then
  echo "chip-model-guard-lint: ${errors} error(s) found"
  exit 1
fi

echo "chip-model-guard-lint: OK (${#CANONICAL_EMITTERS[@]} emitters)"
