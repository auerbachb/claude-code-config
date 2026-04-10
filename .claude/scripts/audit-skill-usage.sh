#!/bin/bash
# Audit skill usage — manual monthly utility
#
# Reads .claude/skill-usage.csv and reports skills that appear unused:
#   - 30+ days since start_date with use_count == 0 → FLAG (consider removal)
#   - 60+ days since start_date with use_count == 0 → RECOMMEND REMOVAL
#
# Output only — does NOT modify files or remove skills.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CSV="${REPO_ROOT}/.claude/skill-usage.csv"

if [ ! -f "$CSV" ]; then
  echo "Error: skill-usage CSV not found at $CSV" >&2
  exit 1
fi

python3 - "$CSV" <<'PY'
import csv, sys
from datetime import datetime, date

csv_path = sys.argv[1]
today = date.today()

flagged = []    # 30-59 days unused
recommend = []  # 60+ days unused

with open(csv_path, newline="") as f:
    reader = csv.DictReader(f)
    for row in reader:
        name = row.get("skill_name", "").strip()
        start = row.get("start_date", "").strip()
        count_s = row.get("use_count", "0").strip()
        if not name or not start:
            continue
        try:
            count = int(count_s)
        except ValueError:
            count = 0
        if count != 0:
            continue
        try:
            start_d = datetime.strptime(start, "%Y-%m-%d").date()
        except ValueError:
            continue
        age = (today - start_d).days
        if age >= 60:
            recommend.append((name, age))
        elif age >= 30:
            flagged.append((name, age))

total_unused = len(flagged) + len(recommend)

print(f"Skill Usage Audit — {today.isoformat()}")
print("=" * 60)
print()

if not total_unused:
    print("No unused skills found. All tracked skills have use_count > 0")
    print("or are still within their 30-day grace period.")
    sys.exit(0)

if recommend:
    print(f"RECOMMEND REMOVAL ({len(recommend)} skills, 60+ days unused):")
    for name, age in sorted(recommend, key=lambda x: -x[1]):
        print(f"  - {name} (unused for {age} days)")
    print()
    print("  Suggested action: delete these skills from .claude/skills/")
    print("  via a PR. File an issue to track removal.")
    print()

if flagged:
    print(f"FLAGGED ({len(flagged)} skills, 30-59 days unused):")
    for name, age in sorted(flagged, key=lambda x: -x[1]):
        print(f"  - {name} (unused for {age} days)")
    print()
    print("  Suggested action: file a tracking issue. Re-check in 30 days.")
    print()
PY
