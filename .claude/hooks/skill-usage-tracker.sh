#!/bin/bash
# Skill usage tracker — PostToolUse hook (matcher: Skill)
# Increments the use_count and updates last_used in .claude/skill-usage.csv
# whenever the Skill tool is invoked.
#
# Input (stdin): JSON with {tool_name, tool_input, cwd, ...}
# Output (stdout): empty JSON object (non-blocking)
# Exit code: always 0 (never block tool execution)
#
# The CSV lives in the claude-code-config repo (source of truth for skills).
# We locate it via the skills worktree, which is always checked out to main.

set -uo pipefail

# Consume stdin
INPUT=$(cat)

# Always emit empty JSON and never fail — this hook is non-blocking
trap 'echo "{}"; exit 0' EXIT

# Parse tool_name and skill name from tool_input. The Skill tool's input
# has a "skill" parameter (e.g. {"skill": "commit"}).
SKILL_NAME=$(printf '%s' "$INPUT" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
tool = (d.get("tool_name") or "").strip()
if tool != "Skill":
    sys.exit(0)
ti = d.get("tool_input") or {}
skill = (ti.get("skill") or "").strip()
# Strip plugin prefix (e.g. "anthropic-skills:pdf" -> "pdf")
if ":" in skill:
    skill = skill.split(":", 1)[1]
# Basic sanitization: reject anything that is not safe for a CSV key
if not skill or any(c in skill for c in [",", "\n", "\r", "\"", "/"]):
    sys.exit(0)
print(skill)
' 2>/dev/null) || exit 0

[ -z "$SKILL_NAME" ] && exit 0

# Locate the CSV via the skills worktree (always on main, always present once set up)
CSV="${HOME}/.claude/skills-worktree/.claude/skill-usage.csv"
[ -f "$CSV" ] || exit 0

TODAY=$(TZ='America/New_York' date +'%Y-%m-%d')

# Use flock if available to serialize concurrent writes
LOCK_FILE="${CSV}.lock"
update_csv() {
  python3 - "$CSV" "$SKILL_NAME" "$TODAY" <<'PY' 2>/dev/null || true
import csv, os, sys, tempfile

csv_path, skill, today = sys.argv[1], sys.argv[2], sys.argv[3]

try:
    with open(csv_path, "r", newline="") as f:
        rows = list(csv.reader(f))
except FileNotFoundError:
    sys.exit(0)

if not rows:
    sys.exit(0)

header, data = rows[0], rows[1:]
found = False
for row in data:
    if len(row) >= 4 and row[0] == skill:
        try:
            row[2] = str(int(row[2]) + 1)
        except ValueError:
            row[2] = "1"
        row[3] = today
        found = True
        break

if not found:
    # Skill not in tracker yet — seed it (count starts at 1 since this is its first use)
    data.append([skill, today, "1", today])

# Atomic write
dir_ = os.path.dirname(csv_path) or "."
fd, tmp = tempfile.mkstemp(prefix=".skill-usage.", dir=dir_)
try:
    with os.fdopen(fd, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(header)
        w.writerows(data)
    os.replace(tmp, csv_path)
except Exception:
    try: os.unlink(tmp)
    except Exception: pass
    sys.exit(0)
PY
}

if command -v flock >/dev/null 2>&1; then
  (
    flock -w 2 9 || exit 0
    update_csv
  ) 9>"$LOCK_FILE"
else
  update_csv
fi

exit 0
