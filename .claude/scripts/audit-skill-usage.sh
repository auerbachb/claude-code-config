#!/usr/bin/env bash
# audit-skill-usage.sh — Monthly skill usage audit
#
# PURPOSE:
#   Reads .claude/data/skill-usage.json and reports skills that have not been
#   used since they were first tracked:
#     - 30–59 days with use_count == 0 → FLAG (review recommended)
#     - 60+  days with use_count == 0 → RECOMMEND REMOVAL
#
#   Also syncs the data file with the current .claude/skills/ directory:
#     - Skills found in .claude/skills/ but missing from the data file get
#       a new entry (first_seen = today, use_count = 0, last_used = null).
#     - Skills in the data file but no longer in .claude/skills/ are noted
#       in the report (orphaned entries are preserved, not deleted).
#
# USAGE:
#   bash .claude/scripts/audit-skill-usage.sh [--help]
#
# IDEMPOTENT: Safe to run multiple times. Running it twice on the same day
# produces the same output and the same data file state.
#
# DEPENDENCIES:
#   - jq  (available at /usr/bin/jq on macOS + standard Linux distros)
#
# DATA SOURCE:
#   .claude/data/skill-usage.json (relative to the repo root).
#   The file is initialized automatically on first run if it does not exist.
#   Use_counts are incremented by the skill-usage-tracker hook (see #121).
#   Until that hook is active, all skills will show use_count == 0.
#
# EXIT STATUS:
#   0 — no removal recommendations (all clean, or only review flags)
#   1 — at least one skill is recommended for removal (60+ days unused)

set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────────
# Help flag
# ──────────────────────────────────────────────────────────────────────────────
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  sed -n '2,/^# EXIT STATUS:/{ /^# EXIT STATUS:/d; s/^# \{0,1\}//; p }' "$0"
  exit 0
fi

# ──────────────────────────────────────────────────────────────────────────────
# Locate repo root (supports running from any subdirectory or a worktree)
# ──────────────────────────────────────────────────────────────────────────────
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$REPO_ROOT" ]]; then
  echo "Error: not inside a git repository. Run this script from within the repo." >&2
  exit 1
fi

SKILLS_DIR="${REPO_ROOT}/.claude/skills"
DATA_FILE="${REPO_ROOT}/.claude/data/skill-usage.json"
TODAY="$(TZ='America/New_York' date +'%Y-%m-%d')"

# ──────────────────────────────────────────────────────────────────────────────
# Ensure jq is available
# ──────────────────────────────────────────────────────────────────────────────
if ! command -v jq &>/dev/null; then
  echo "Error: jq is required but not found in PATH." >&2
  echo "  Install via: brew install jq  OR  apt-get install jq" >&2
  exit 1
fi

# ──────────────────────────────────────────────────────────────────────────────
# Initialize data file if missing
# ──────────────────────────────────────────────────────────────────────────────
if [[ ! -f "$DATA_FILE" ]]; then
  mkdir -p "$(dirname "$DATA_FILE")"
  echo "{}" > "$DATA_FILE"
  echo "Initialized empty data file at $DATA_FILE"
fi

# ──────────────────────────────────────────────────────────────────────────────
# Sync: add entries for skills not yet tracked
# ──────────────────────────────────────────────────────────────────────────────
USAGE_DATA="$(cat "$DATA_FILE")"
NEW_SKILLS=()

if [[ -d "$SKILLS_DIR" ]]; then
  for skill_dir in "$SKILLS_DIR"/*/; do
    [[ -f "${skill_dir}SKILL.md" ]] || continue
    skill_name="$(basename "$skill_dir")"
    # Check if already in data file
    existing=$(echo "$USAGE_DATA" | jq -r --arg n "$skill_name" '.[$n] // empty')
    if [[ -z "$existing" ]]; then
      # New skill — add with first_seen=today, use_count=0, last_used=null
      USAGE_DATA=$(echo "$USAGE_DATA" | jq \
        --arg name "$skill_name" \
        --arg date "$TODAY" \
        '.[$name] = {"use_count": 0, "first_seen": $date, "last_used": null}')
      NEW_SKILLS+=("$skill_name")
    fi
  done
fi

# Write back the (possibly updated) data file
_tmp="$(mktemp "$(dirname "$DATA_FILE")/skill-usage.XXXXXX.json")"
echo "$USAGE_DATA" | jq '.' > "$_tmp" && mv "$_tmp" "$DATA_FILE"

# ──────────────────────────────────────────────────────────────────────────────
# Detect orphaned entries (in data file but no longer in skills dir)
# ──────────────────────────────────────────────────────────────────────────────
ORPHANS=()
while IFS= read -r skill_name; do
  [[ -n "$skill_name" ]] || continue
  if [[ ! -d "${SKILLS_DIR}/${skill_name}" ]]; then
    ORPHANS+=("$skill_name")
  fi
done < <(echo "$USAGE_DATA" | jq -r 'keys[]')

# ──────────────────────────────────────────────────────────────────────────────
# Age-based flagging
# ──────────────────────────────────────────────────────────────────────────────
FLAGGED=()      # 30–59 days unused
RECOMMEND=()    # 60+ days unused

# today as epoch seconds (portable: works on macOS and Linux)
today_epoch=$(date -j -f "%Y-%m-%d" "$TODAY" "+%s" 2>/dev/null \
  || date -d "$TODAY" "+%s")

while IFS= read -r skill_name; do
  [[ -n "$skill_name" ]] || continue

  use_count=$(echo "$USAGE_DATA" | jq -r --arg n "$skill_name" '.[$n].use_count // 0')
  # Skip skills with any recorded usage
  [[ "$use_count" -eq 0 ]] || continue

  first_seen=$(echo "$USAGE_DATA" | jq -r --arg n "$skill_name" '.[$n].first_seen // ""')
  [[ -n "$first_seen" ]] || continue

  # Parse first_seen date to epoch seconds
  first_epoch=$(date -j -f "%Y-%m-%d" "$first_seen" "+%s" 2>/dev/null \
    || date -d "$first_seen" "+%s" 2>/dev/null) || continue

  age_days=$(( (today_epoch - first_epoch) / 86400 ))

  if (( age_days >= 60 )); then
    RECOMMEND+=("${skill_name}	${age_days}")
  elif (( age_days >= 30 )); then
    FLAGGED+=("${skill_name}	${age_days}")
  fi
done < <(echo "$USAGE_DATA" | jq -r 'keys[]')

# ──────────────────────────────────────────────────────────────────────────────
# Report output
# ──────────────────────────────────────────────────────────────────────────────
TOTAL_SKILLS=$(echo "$USAGE_DATA" | jq 'keys | length')

echo "Skill Usage Audit — ${TODAY}"
echo "============================================================"
printf "Total skills tracked: %s\n" "$TOTAL_SKILLS"

# New skills added during this run
if (( ${#NEW_SKILLS[@]} > 0 )); then
  echo ""
  printf "NEW (added to tracking today, %d skill(s)):\n" "${#NEW_SKILLS[@]}"
  for s in "${NEW_SKILLS[@]}"; do
    printf "  + %s\n" "$s"
  done
fi

# Orphaned entries
if (( ${#ORPHANS[@]} > 0 )); then
  echo ""
  printf "ORPHANED entries (%d) — in data file but no skill directory found:\n" "${#ORPHANS[@]}"
  for s in "${ORPHANS[@]}"; do
    printf "  ? %s\n" "$s"
  done
  echo "  (These entries are preserved. Remove manually if the skill was deleted.)"
fi

echo ""

# Early exit if nothing to flag
if (( ${#RECOMMEND[@]} == 0 && ${#FLAGGED[@]} == 0 )); then
  echo "No unused skills found. All tracked skills have use_count > 0"
  echo "or are still within their 30-day grace period."
  exit 0
fi

# Removal recommendations (60+ days unused)
if (( ${#RECOMMEND[@]} > 0 )); then
  printf "RECOMMEND REMOVAL (%d skill(s), 60+ days unused):\n" "${#RECOMMEND[@]}"
  # Sort by age descending
  sorted=()
  while IFS= read -r entry; do
    sorted+=("$entry")
  done < <(printf '%s\n' "${RECOMMEND[@]}" | sort -t$'\t' -k2 -rn)
  for entry in "${sorted[@]}"; do
    skill_name="${entry%%$'\t'*}"
    age_days="${entry##*$'\t'}"
    printf "  - %s (unused for %d days)\n" "$skill_name" "$age_days"
  done
  echo ""
  echo "  Suggested action: open a PR to delete these skills from .claude/skills/"
  echo "  and remove their entries from .claude/data/skill-usage.json."
  echo ""
fi

# Review flags (30–59 days unused)
if (( ${#FLAGGED[@]} > 0 )); then
  printf "FLAGGED — REVIEW RECOMMENDED (%d skill(s), 30–59 days unused):\n" "${#FLAGGED[@]}"
  sorted=()
  while IFS= read -r entry; do
    sorted+=("$entry")
  done < <(printf '%s\n' "${FLAGGED[@]}" | sort -t$'\t' -k2 -rn)
  for entry in "${sorted[@]}"; do
    skill_name="${entry%%$'\t'*}"
    age_days="${entry##*$'\t'}"
    printf "  - %s (unused for %d days)\n" "$skill_name" "$age_days"
  done
  echo ""
  echo "  Suggested action: file a tracking issue. Re-check in 30 days."
  echo ""
fi

# Exit 1 if any removal recommendations exist
if (( ${#RECOMMEND[@]} > 0 )); then
  exit 1
fi
exit 0
