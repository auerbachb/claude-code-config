#!/bin/bash
# Audit skill usage — manual monthly utility
#
# Reads the LIVE skill-usage CSV (~/.claude/skill-usage.csv, bootstrapped
# by skill-usage-tracker.sh on first Skill invocation). Reports skills that
# appear unused:
#   - 30-59 days since start_date with use_count == 0 → FLAG (tracking issue)
#   - 60+  days since start_date with use_count == 0 → RECOMMEND REMOVAL
#
# Output only — does NOT modify files or remove skills.
#
# Override the CSV path with SKILL_USAGE_CSV env var (useful for testing
# or for auditing the committed seed file directly).

set -euo pipefail

CSV="${SKILL_USAGE_CSV:-${HOME}/.claude/skill-usage.csv}"

if [ ! -f "$CSV" ]; then
  echo "Error: skill-usage CSV not found at $CSV" >&2
  echo "  (the tracker hook creates it on first Skill invocation)" >&2
  exit 1
fi

python3 - "$CSV" <<'PY'
import csv, sys
from datetime import datetime

try:
    import zoneinfo
    today = datetime.now(zoneinfo.ZoneInfo("America/New_York")).date()
except Exception:
    # Fallback: machine local date (Python 3.8 or unusual environments)
    today = datetime.now().date()

csv_path = sys.argv[1]

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
