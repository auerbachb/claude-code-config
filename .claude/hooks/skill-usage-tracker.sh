#!/bin/bash
# Skill usage tracker — PostToolUse hook (matcher: Skill)
#
# Increments use_count and updates last_used in the live skill-usage CSV
# whenever the Skill tool is invoked.
#
# Input  (stdin) : JSON with {tool_name, tool_input, cwd, ...}
# Output (stdout): empty JSON object (non-blocking)
# Exit code      : always 0 — never blocks tool execution
#
# Storage model:
#   - Live CSV: ~/.claude/skill-usage.csv (NEVER in the skills worktree;
#     session-start-sync.sh does `git reset --hard`, which would wipe counters
#     stored inside the worktree).
#   - Seed CSV: ~/.claude/skills-worktree/.claude/skill-usage.csv — the
#     git-tracked template, used to bootstrap the live CSV on first run and
#     to carry new skills over to the live CSV.

set -uo pipefail

# Consume stdin
INPUT=$(cat)

# Always emit empty JSON and never fail — this hook is non-blocking
trap 'echo "{}"; exit 0' EXIT

# Parse tool_name and skill name from tool_input.
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

LIVE_CSV="${HOME}/.claude/skill-usage.csv"
SEED_CSV="${HOME}/.claude/skills-worktree/.claude/skill-usage.csv"

# Bootstrap live CSV if missing (copy the seed, or create an empty header)
if [ ! -f "$LIVE_CSV" ]; then
  mkdir -p "$(dirname "$LIVE_CSV")" 2>/dev/null || exit 0
  if [ -f "$SEED_CSV" ]; then
    cp "$SEED_CSV" "$LIVE_CSV" 2>/dev/null || exit 0
  else
    printf 'skill_name,start_date,use_count,last_used\n' > "$LIVE_CSV" 2>/dev/null || exit 0
  fi
fi

# Serialized atomic update using Python's fcntl.flock (cross-platform on
# macOS/Linux; Windows is not supported and silently falls back to no lock).
python3 - "$LIVE_CSV" "$SKILL_NAME" <<'PY' 2>/dev/null || true
import csv, os, sys, tempfile
from datetime import datetime
try:
    import zoneinfo
    today = datetime.now(zoneinfo.ZoneInfo("America/New_York")).date().isoformat()
except Exception:
    from datetime import timezone
    today = datetime.now(timezone.utc).date().isoformat()

csv_path, skill = sys.argv[1], sys.argv[2]
lock_path = csv_path + ".lock"

# Acquire advisory lock via a sidecar file (works on macOS + Linux).
lock_fd = None
try:
    import fcntl
    lock_fd = open(lock_path, "w")
    try:
        fcntl.flock(lock_fd.fileno(), fcntl.LOCK_EX)
    except Exception:
        pass
except Exception:
    lock_fd = None

try:
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
        # Skill not in tracker yet — seed it (count starts at 1, start_date = today)
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
finally:
    if lock_fd is not None:
        try: lock_fd.close()
        except Exception: pass
PY

exit 0
