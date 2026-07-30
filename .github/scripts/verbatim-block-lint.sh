#!/usr/bin/env bash
# Lint verbatim SAFETY/MINDSET/SKILLS block conformance across declared copies (issue #767).
#
# Validates that every declared verbatim copy of a canonical block is byte-identical
# to the canonical block extracted from its rule file.
#
# Canonical sources:
#   SAFETY:  → .claude/rules/safety.md
#   MINDSET: → .claude/rules/safety.md
#   SKILLS:  → .claude/rules/skill-first.md
#
# Verbatim-copy surfaces (byte-compared):
#   .claude/skills/subagent/SKILL.md
#   .claude/skills/pr-monitor-and-manage/SKILL.md
#
# Paraphrased surfaces (out of scope for byte comparison — intentionally excluded):
#   .claude/agents/README.md
#   .claude/agents/phase-a-fixer.md
#   .claude/agents/phase-b-reviewer.md
#   .claude/agents/phase-c-merger.md
#   .claude/agents/pm-worker.md
#   These files carry abbreviated/reworded versions of the blocks as prompt examples
#   and cannot be byte-compared without false positives.
#
# Extraction: each block is delimited by its marker line (^BLOCK:) as the start
# anchor and the next line that is exactly ``` as the end anchor (excluded). This
# works uniformly for the canonical rule files (inside ```text…``` fences) and for
# the copy files that use the same fence format.
#
# Companion to rule-lint.sh / chip-model-guard-lint.sh. Run from repo root.
# Output uses GitHub Actions annotations. Exits 1 on any error.
# Compatible with bash 3.2+ (no associative arrays).

set -euo pipefail

errors=0

usage() {
  cat <<'EOF'
Usage: .github/scripts/verbatim-block-lint.sh

  Verifies SAFETY/MINDSET/SKILLS verbatim blocks have not drifted from canonical.
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

# ---------------------------------------------------------------------------
# Canonical source map: block name → canonical rule file (bash 3.2 compatible).
# One-line change to remap a block to a different canonical source.
# ---------------------------------------------------------------------------
canonical_src() {
  local block="$1"
  case "$block" in
    SAFETY|MINDSET) printf '%s\n' ".claude/rules/safety.md" ;;
    SKILLS)         printf '%s\n' ".claude/rules/skill-first.md" ;;
    *) printf '::error::Internal error: no canonical source registered for block %s\n' "$block" >&2
       return 1 ;;
  esac
}

# All distinct canonical source files (for the pre-flight existence check).
CANONICAL_FILES=(
  ".claude/rules/safety.md"
  ".claude/rules/skill-first.md"
)

# ---------------------------------------------------------------------------
# Verbatim-copy surface list: "BLOCK|copy_file" pairs.
# One-line change to add or remove a copy surface.
# ---------------------------------------------------------------------------
VERBATIM_COPIES=(
  "SAFETY|.claude/skills/subagent/SKILL.md"
  "MINDSET|.claude/skills/subagent/SKILL.md"
  "SKILLS|.claude/skills/subagent/SKILL.md"
  "SAFETY|.claude/skills/pr-monitor-and-manage/SKILL.md"
  "MINDSET|.claude/skills/pr-monitor-and-manage/SKILL.md"
  "SKILLS|.claude/skills/pr-monitor-and-manage/SKILL.md"
)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

require_file() {
  local f="$1"
  if [[ ! -f "$f" ]]; then
    echo "::error file=${f}::Required file not found"
    errors=$(( errors + 1 ))
    return 1
  fi
  return 0
}

# Extract a verbatim block from a file.
# Arguments: BLOCK_MARKER  FILE
# Output: all lines from the first line matching ^BLOCK_MARKER: through all
# subsequent lines up to (but NOT including) the next line that is exactly ```.
# Returns nothing and exits non-zero if the block is not found.
extract_block() {
  local marker="$1" file="$2"
  awk -v m="^${marker}:" '
    !found && $0 ~ m { found = 1 }
    found {
      if ($0 == "```") { exit }
      print
    }
  ' "$file"
}

# ---------------------------------------------------------------------------
# Pre-flight: verify canonical source files exist
# ---------------------------------------------------------------------------
for cf in "${CANONICAL_FILES[@]}"; do
  require_file "$cf" || true
done

# ---------------------------------------------------------------------------
# Main: compare each declared verbatim copy against its canonical block
# ---------------------------------------------------------------------------
for entry in "${VERBATIM_COPIES[@]}"; do
  block="${entry%%|*}"
  copy_file="${entry##*|}"

  # Guard against missing copy file
  require_file "$copy_file" || continue

  # Resolve canonical source file
  canon_file=""
  RC=0; canon_file="$(canonical_src "$block")" || RC=$?
  if (( RC != 0 )) || [[ -z "$canon_file" ]]; then
    echo "::error::Internal error: no canonical source registered for block ${block}"
    errors=$(( errors + 1 ))
    continue
  fi

  # Guard against missing canonical file (already checked above, but be safe)
  if [[ ! -f "$canon_file" ]]; then
    continue  # error already recorded above
  fi

  # Extract canonical block
  canonical_block="$(extract_block "$block" "$canon_file")"
  if [[ -z "$canonical_block" ]]; then
    echo "::error file=${canon_file}::${block}: block not found in canonical source ${canon_file}"
    errors=$(( errors + 1 ))
    continue
  fi

  # Extract block from copy file
  copy_block="$(extract_block "$block" "$copy_file")"
  if [[ -z "$copy_block" ]]; then
    echo "::error file=${copy_file}::Missing ${block}: block not found in declared copy ${copy_file}"
    errors=$(( errors + 1 ))
    continue
  fi

  # Byte-compare
  RC=0
  diff_out="$(diff <(printf '%s\n' "$canonical_block") <(printf '%s\n' "$copy_block") 2>&1)" || RC=$?
  if (( RC != 0 )); then
    echo "::error file=${copy_file}::${block} block has drifted from canonical (${canon_file})"
    printf '%s\n' "$diff_out" | sed 's/^/  /'
    errors=$(( errors + 1 ))
  fi
done

if (( errors > 0 )); then
  echo "verbatim-block-lint: ${errors} error(s) found"
  exit 1
fi

echo "verbatim-block-lint: OK (${#VERBATIM_COPIES[@]} copy surfaces)"
