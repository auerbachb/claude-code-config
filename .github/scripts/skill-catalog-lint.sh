#!/usr/bin/env bash
# Lint the README slash-command catalog against .claude/skills/.
#
# Validates:
#   1. The Slash Commands table in README.md matches the actual set of
#      .claude/skills/*/ directories (no drift in either direction).
#   2. No duplicate command rows (a dupe would inflate the count while
#      leaving a command undocumented).
#   3. Every skill directory actually contains a SKILL.md.
#   4. The hardcoded command counts in README prose match the row count.
#
# Companion to rule-lint.sh, which enforces the same index-alignment
# invariant for .claude/rules/*.md against the CLAUDE.md rule index.
# Paths are repo-root-relative, so run it from the repo root.
#
# Output uses GitHub Actions annotations (::error::) so issues surface
# directly on PR checks. Exits 1 on any error condition.

set -euo pipefail
shopt -s nullglob

README="README.md"
SKILLS_DIR=".claude/skills"

errors=0

usage() {
  cat <<'EOF'
Usage: .github/scripts/skill-catalog-lint.sh

  Verifies the README Slash Commands table stays in sync with .claude/skills/.
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

if [[ ! -f "$README" ]]; then
  echo "::error file=${README}::README.md not found at repo root"
  exit 1
fi

if [[ ! -d "$SKILLS_DIR" ]]; then
  echo "::error::${SKILLS_DIR} directory not found"
  exit 1
fi

# --- 1. Catalog alignment check ------------------------------------------
# Table rows look like:
#   | `/pm` | PM | Active PM orchestrator — ... |
# Scoped to the '## Slash Commands' section (up to the next '## ' header) so
# a command-shaped row in an unrelated table elsewhere in the README isn't
# misread as a catalog entry.
# `|| true` keeps a no-match grep (exit 1) from killing the script under
# `set -euo pipefail`; the empty case is handled by the comm logic below.
catalog_section=$(awk '
  /^## Slash Commands/ { in_section=1; next }
  in_section && /^## / { exit }
  in_section { print }
' "$README")

documented_all=$(printf '%s\n' "$catalog_section" \
  | grep -oE '^\| `/[a-z0-9-]+`' \
  | sed 's/^| `\///; s/`$//' \
  | sort || true)
documented=$(printf '%s\n' "$documented_all" | sort -u)

actual=$(find "$SKILLS_DIR" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; \
  | sort -u)

undocumented=$(comm -23 <(printf '%s\n' "$actual") <(printf '%s\n' "$documented") || true)
phantom=$(comm -13 <(printf '%s\n' "$actual") <(printf '%s\n' "$documented") || true)

if [[ -n "$undocumented" ]]; then
  while IFS= read -r s; do
    [[ -z "$s" ]] && continue
    echo "::error file=${README}::Skill '${s}' exists in ${SKILLS_DIR}/ but has no row in the README Slash Commands table"
    errors=$((errors + 1))
  done <<< "$undocumented"
fi

if [[ -n "$phantom" ]]; then
  while IFS= read -r s; do
    [[ -z "$s" ]] && continue
    echo "::error file=${README}::README documents '/${s}' but no such skill exists in ${SKILLS_DIR}/"
    errors=$((errors + 1))
  done <<< "$phantom"
fi

# --- 2. Duplicate row check ----------------------------------------------
row_count=$(printf '%s\n' "$documented_all" | grep -c . || true)
unique_count=$(printf '%s\n' "$documented" | grep -c . || true)

if (( row_count != unique_count )); then
  printf '%s\n' "$documented_all" | uniq -d | while IFS= read -r dupe; do
    [[ -z "$dupe" ]] && continue
    echo "::error file=${README}::Command '/${dupe}' has more than one row in the Slash Commands table"
  done
  errors=$((errors + row_count - unique_count))
fi

# --- 3. SKILL.md presence ------------------------------------------------
# Keeps "directory count" and "documented command count" the same number, so
# `ls -d .claude/skills/*/ | wc -l` stays a valid cross-check of the table.
while IFS= read -r s; do
  [[ -z "$s" ]] && continue
  if [[ ! -f "${SKILLS_DIR}/${s}/SKILL.md" ]]; then
    echo "::error::${SKILLS_DIR}/${s}/ has no SKILL.md — either add one or remove the directory"
    errors=$((errors + 1))
  fi
done <<< "$actual"

if (( errors == 0 )); then
  echo "Skill catalog alignment: OK (${unique_count} commands)"
fi

# --- 4. Hardcoded count check --------------------------------------------
# Each anchor must appear exactly once. Zero matches (someone reworded the
# prose) or several (an ambiguous target) is an error, not a pass — otherwise
# a future edit would silently disable this check instead of failing loudly.
check_count_anchor() {
  local label="$1" regex="$2" matches found
  matches=$(grep -oE "$regex" "$README" || true)
  local n
  n=$(printf '%s\n' "$matches" | grep -c . || true)

  if (( n == 0 )); then
    echo "::error file=${README}::Could not find the ${label} count claim (expected prose matching /${regex}/). If the wording changed, update skill-catalog-lint.sh to match."
    errors=$((errors + 1))
    return
  fi
  if (( n > 1 )); then
    echo "::error file=${README}::The ${label} count claim matched ${n} times (expected exactly 1) — the anchor is ambiguous. Reword README or tighten skill-catalog-lint.sh."
    errors=$((errors + 1))
    return
  fi

  found=$(printf '%s\n' "$matches" | grep -oE '[0-9]+')
  # 10# forces base-10: a leading zero would otherwise be read as octal and
  # abort the script on an invalid digit (same guard rule-lint.sh uses).
  if (( 10#$found != unique_count )); then
    echo "::error file=${README}::The ${label} count says ${found} but the table has ${unique_count} commands"
    errors=$((errors + 1))
  fi
}

check_count_anchor "'What You Get' bullet" '[0-9]+ slash commands'
check_count_anchor "'Slash Commands' intro" 'All [0-9]+ commands are invoked'

if (( errors > 0 )); then
  echo "skill-catalog-lint: ${errors} error(s) found"
  exit 1
fi

echo "skill-catalog-lint: OK"
