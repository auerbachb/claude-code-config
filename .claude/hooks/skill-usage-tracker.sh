#!/bin/bash
# Skill usage tracker — PostToolUse hook (matcher: Skill)
#
# On each Skill tool invocation: appends one line to ~/.claude/skill-usage.log,
# then increments use_count and updates last_used in the live skill-usage CSV.
#
# Input  (stdin) : JSON with {tool_name, tool_input, cwd, ...}
# Output (stdout): empty JSON object (non-blocking)
# Exit code      : always 0 — never blocks tool execution
#
# Storage model:
#   - Append-only log: ~/.claude/skill-usage.log — one tab-separated line per
#     invocation (ISO8601 UTC, skill_name, session_id). Mirrors script-usage.log
#     (#310); used by skill-usage-report.sh (#416). NEVER in the skills worktree.
#   - Live CSV: ~/.claude/skill-usage.csv — aggregated counts for legacy audits.
#   - Seed CSV: ~/.claude/skills-worktree/.claude/skill-usage.csv — git-tracked
#     template used to bootstrap the live CSV on first run.
#
# Log line is best-effort (append may fail silently). CSV bootstrap + increment
# run inside a single locked Python transaction so concurrent first-use
# invocations cannot clobber each other.

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

# Append-only telemetry log (same family as ~/.claude/script-usage.log).
USAGE_LOG="${HOME}/.claude/skill-usage.log"
mkdir -p "$(dirname "$USAGE_LOG")" 2>/dev/null || exit 0
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)
SESSION_ID="${SESSION_ID:-${CLAUDE_SESSION_ID:-}}"
SESSION_ID="${SESSION_ID//[^[:alnum:]_.-]/_}"
SESSION_ID="${SESSION_ID:-unknown}"
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$SKILL_NAME" "$SESSION_ID" >> "$USAGE_LOG" 2>/dev/null || true

LIVE_CSV="${HOME}/.claude/skill-usage.csv"
SEED_CSV="${HOME}/.claude/skills-worktree/.claude/skill-usage.csv"

# Ensure the parent directory exists (cheap, idempotent, race-free).
mkdir -p "$(dirname "$LIVE_CSV")" 2>/dev/null || exit 0

# Serialized bootstrap + update inside a single Python transaction, protected
# by fcntl.flock on a sidecar lock file. Works on macOS + Linux; degrades
# gracefully on platforms without fcntl.
python3 - "$LIVE_CSV" "$SEED_CSV" "$SKILL_NAME" <<'PY' 2>/dev/null || true
import csv, os, sys, tempfile
from datetime import datetime
try:
    import zoneinfo
    today = datetime.now(zoneinfo.ZoneInfo("America/New_York")).date().isoformat()
except Exception:
    # Fallback: machine local date (matches audit-skill-usage.sh fallback).
    today = datetime.now().date().isoformat()

csv_path, seed_path, skill = sys.argv[1], sys.argv[2], sys.argv[3]
lock_path = csv_path + ".lock"

# Acquire advisory lock via a sidecar file (works on macOS + Linux).
# Fail closed: if we cannot acquire the exclusive lock, abort without writing.
# Unlocked writes under concurrency could lose increments.
lock_fd = None
try:
    import fcntl
except Exception:
    # Platform has no fcntl (e.g. Windows). Concurrent writes are then
    # theoretically racy, but Skill invocations are rare enough in practice
    # that we proceed without a lock on such platforms.
    fcntl = None

if fcntl is not None:
    try:
        lock_fd = open(lock_path, "w")
        fcntl.flock(lock_fd.fileno(), fcntl.LOCK_EX)
    except Exception:
        # Lock acquisition failed — abort to avoid clobbering concurrent writes.
        if lock_fd is not None:
            try: lock_fd.close()
            except Exception: pass
        sys.exit(0)

def atomic_write(path, header, data):
    dir_ = os.path.dirname(path) or "."
    fd, tmp = tempfile.mkstemp(prefix=".skill-usage.", dir=dir_)
    try:
        with os.fdopen(fd, "w", newline="") as f:
            w = csv.writer(f)
            w.writerow(header)
            w.writerows(data)
        os.replace(tmp, path)
    except Exception:
        try: os.unlink(tmp)
        except Exception: pass
        raise

try:
    # BOOTSTRAP (under lock): if the live CSV does not exist, create it
    # from the seed (preferred) or from a bare header. This happens inside
    # the lock so a concurrent invocation cannot clobber our first update.
    if not os.path.exists(csv_path):
        if os.path.exists(seed_path):
            try:
                with open(seed_path, "r", newline="") as sf:
                    seed_rows = list(csv.reader(sf))
            except Exception:
                seed_rows = []
        else:
            seed_rows = []
        if not seed_rows:
            seed_rows = [["skill_name", "start_date", "use_count", "last_used"]]
        try:
            atomic_write(csv_path, seed_rows[0], seed_rows[1:])
        except Exception:
            sys.exit(0)

    # UPDATE (same lock): read the freshly-bootstrapped-or-existing CSV and
    # apply the increment.
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
        # Skill not in tracker yet — seed it (count=1, start_date=today)
        data.append([skill, today, "1", today])

    try:
        atomic_write(csv_path, header, data)
    except Exception:
        sys.exit(0)
finally:
    if lock_fd is not None:
        try: lock_fd.close()
        except Exception: pass
PY

exit 0
