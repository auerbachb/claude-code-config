#!/usr/bin/env bash
# skill-conventions-audit.sh — Static audit of skill files against repo conventions
#
# Adapted from affaan-m/everything-claude-code skill-comply / skill-stocktake (issue #417).
# ECC runs LLM-driven behavioral compliance tests; we only check static conventions
# documented in CONTRIBUTING.md and skill-authoring-patterns.md.
#
# USAGE:
#   bash .claude/scripts/skill-conventions-audit.sh [--strict] [--help]
#
# EXIT STATUS:
#   0 — no errors (warnings may still print unless --strict)
#   1 — at least one ERROR (or any finding when --strict)

set -euo pipefail
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" >> "$HOME/.claude/script-usage.log" 2>/dev/null || true

STRICT=0
if [[ "${1:-}" == "--strict" ]]; then
  STRICT=1
elif [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  sed -n '2,/^# EXIT STATUS:/{ /^# EXIT STATUS:/d; s/^# \{0,1\}//; p }' "$0"
  exit 0
fi

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$REPO_ROOT" ]]; then
  echo "Error: not inside a git repository." >&2
  exit 1
fi

SKILLS_DIR="${REPO_ROOT}/.claude/skills"
ERRORS=0
WARNINGS=0

err() { echo "ERROR: $*" >&2; ERRORS=$((ERRORS + 1)); }
warn() { echo "WARN:  $*" >&2; WARNINGS=$((WARNINGS + 1)); }

audit_skill() {
  local skill_md="$1"
  local skill_dir skill_name
  skill_dir="$(dirname "$skill_md")"
  skill_name="$(basename "$skill_dir")"

  # Frontmatter: name + description required
  local fm
  fm="$(python3 - "$skill_md" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
m = re.match(r"^---\s*\n(.*?)\n---", text, re.DOTALL)
if not m:
    print("MISSING_FM")
    sys.exit(0)
block = m.group(1)
name = desc = ""
for line in block.splitlines():
    if line.startswith("name:"):
        name = line.split(":", 1)[1].strip().strip('"').strip("'")
    elif line.startswith("description:"):
        desc = line.split(":", 1)[1].strip().strip('"').strip("'")
print(f"{name}|{desc}")
PY
)"

  if [[ "$fm" == "MISSING_FM" ]]; then
    err "${skill_name}: missing YAML frontmatter (--- block)"
    return
  fi

  local declared_name description
  declared_name="${fm%%|*}"
  description="${fm#*|}"

  if [[ -z "$declared_name" ]]; then
    err "${skill_name}: frontmatter missing 'name:'"
  elif [[ "$declared_name" != "$skill_name" ]]; then
    err "${skill_name}: frontmatter name '${declared_name}' != directory name '${skill_name}'"
  fi

  if [[ -z "$description" ]]; then
    err "${skill_name}: frontmatter missing 'description:'"
  else
    # Heuristic: very long descriptions often leak full workflow (see skill-authoring-patterns.md)
    if [[ ${#description} -gt 320 ]]; then
      warn "${skill_name}: description is ${#description} chars (>320) — may summarize workflow instead of trigger conditions"
    fi
    # Soft nudge: trigger-first descriptions are easier to discover
    if ! echo "$description" | grep -qiE '(^use when|^when |^for when|trigger|invoked when|run when)'; then
      warn "${skill_name}: description does not lead with a trigger phrase (Use when… / When…)"
    fi
  fi

  # Body: expect explicit exit/stop criteria for operational skills
  if ! grep -qiE '(exit criteria|STOP|## exit|when done|zero uncollapsed|merge gate|do not exit)' "$skill_md"; then
    warn "${skill_name}: body may lack explicit exit/stop criteria"
  fi
}

echo "Skill conventions audit — ${SKILLS_DIR}"
echo "Date: $(TZ='America/New_York' date +'%Y-%m-%d %H:%M %Z')"
echo "---"

shopt -s nullglob
skill_files=("${SKILLS_DIR}"/*/SKILL.md)
if [[ ${#skill_files[@]} -eq 0 ]]; then
  err "no SKILL.md files found under ${SKILLS_DIR}"
else
  for skill_md in "${skill_files[@]}"; do
    audit_skill "$skill_md"
  done
fi

echo "---"
echo "Summary: ${ERRORS} error(s), ${WARNINGS} warning(s) across ${#skill_files[@]} skill(s)"

if [[ "$ERRORS" -gt 0 ]]; then
  exit 1
fi
if [[ "$STRICT" -eq 1 && "$WARNINGS" -gt 0 ]]; then
  exit 1
fi
exit 0
