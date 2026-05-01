#!/usr/bin/env bash
# skill-usage-report.sh — Roll up Skill tool telemetry from ~/.claude/skill-usage.log
#
# PURPOSE:
#   Reads ~/.claude/skill-usage.log (append-only, one line per Skill invocation;
#   written by skill-usage-tracker.sh PostToolUse hook) and cross-references
#   .claude/skills/*/SKILL.md in the repo. Prints a markdown table: per-skill
#   invocation counts, last-used timestamps, skills never seen in the log, and
#   dead-skill *candidates* (human review only — never auto-delete).
#
# DEAD SKILL THRESHOLD (editable — change DEAD_DAYS_STALE / DEAD_DAYS_NEVER_INVOKED in Python):
#   A skill is flagged as a removal *candidate* when either:
#     (A) Last invocation was more than DEAD_DAYS_STALE days ago, or
#     (B) Zero log lines for that skill AND tracking has been live at least
#         DEAD_DAYS_NEVER_INVOKED days (first log line timestamp = tracking start).
#   Autonomous invocations (orchestrator, /wrap, subagents) still append the same
#   log line; interpret high counts on workflow skills as "load-bearing" before pruning.
#
# USAGE:
#   skill-usage-report.sh [--days N]
#   skill-usage-report.sh --help
#
#   --days N  Optional second table: invocations in the last N UTC days only.
#
# LOG FORMAT (~/.claude/skill-usage.log, tab-separated):
#   ISO8601 UTC timestamp \t skill_name \t session_id
#
# STORAGE: ~/.claude/ only (not the skills worktree — see feedback_hook_storage_location).
#
# RELATED:
#   audit-skill-usage.sh — legacy JSON/CSV audit; prefer this report for log-based AC.

set -euo pipefail
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" >> "$HOME/.claude/script-usage.log" 2>/dev/null || true

usage() {
  sed -n '2,35p' "$0" | sed 's/^# \{0,1\}//'
}

DAYS=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --days)
      DAYS="${2:-}"
      if [[ -z "$DAYS" ]]; then
        echo "ERROR: --days requires a value" >&2
        exit 2
      fi
      shift 2
      ;;
    --days=*)
      DAYS="${1#--days=}"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -n "$DAYS" ]] && { ! [[ "$DAYS" =~ ^[0-9]+$ ]] || [[ "$DAYS" -lt 1 ]]; }; then
  echo "ERROR: --days must be a positive integer" >&2
  exit 2
fi

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$REPO_ROOT" ]]; then
  echo "Error: not inside a git repository." >&2
  exit 1
fi

python3 - "$REPO_ROOT" "${DAYS:-0}" "$HOME/.claude/skill-usage.log" <<'PY'
import os
import sys
from collections import defaultdict
from datetime import datetime, timedelta, timezone

repo_root = sys.argv[1]
days_arg = int(sys.argv[2])
log_path = sys.argv[3]

# Dead-skill thresholds (issue #416) — edit here only.
DEAD_DAYS_STALE = 90
DEAD_DAYS_NEVER_INVOKED = 30

skills_dir = os.path.join(repo_root, ".claude", "skills")
repo_skills = []
if os.path.isdir(skills_dir):
    for name in sorted(os.listdir(skills_dir)):
        if os.path.isfile(os.path.join(skills_dir, name, "SKILL.md")):
            repo_skills.append(name)

now = datetime.now(timezone.utc)
cutoff = now - timedelta(days=days_arg) if days_arg > 0 else None

# Parse log: skill -> list of (dt, session)
per_skill_events = defaultdict(list)
tracking_start = None

if os.path.isfile(log_path):
    with open(log_path, "r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.rstrip("\n")
            if not line:
                continue
            parts = line.split("\t")
            if len(parts) < 2:
                continue
            ts_raw, skill = parts[0].strip(), parts[1].strip()
            sess = parts[2].strip() if len(parts) > 2 else ""
            if not skill:
                continue
            ts = ts_raw
            if ts.endswith("Z"):
                ts = ts[:-1] + "+00:00"
            try:
                dt = datetime.fromisoformat(ts)
            except ValueError:
                continue
            if dt.tzinfo is None:
                dt = dt.replace(tzinfo=timezone.utc)
            else:
                dt = dt.astimezone(timezone.utc)
            if tracking_start is None or dt < tracking_start:
                tracking_start = dt
            per_skill_events[skill].append((dt, sess))

counts_all = {s: len(ev) for s, ev in per_skill_events.items()}
last_used = {}
for s, ev in per_skill_events.items():
    last_used[s] = max(t for t, _ in ev)

counts_window = defaultdict(int)
if cutoff is not None:
    for s, ev in per_skill_events.items():
        for dt, _ in ev:
            if dt >= cutoff:
                counts_window[s] += 1

def fmt_ts(dt):
    if dt is None:
        return "—"
    return dt.strftime("%Y-%m-%d %H:%M UTC")

# --- Markdown output ---
print("# Skill usage report")
print()
print(f"- Log file: `{log_path}`")
print(f"- Repo skills dir: `{skills_dir}`")
print(f"- Dead-skill rule: last use **>{DEAD_DAYS_STALE}d** ago, **or** zero log lines and tracking live **≥{DEAD_DAYS_NEVER_INVOKED}d** (since first log line).")
print(f"- Generated: {fmt_ts(now)}")
if tracking_start:
    age = (now - tracking_start).days
    print(f"- Tracking since (first log entry): {fmt_ts(tracking_start)} (~{age} day(s) of history)")
else:
    print("- Tracking since: *(no log file or empty log — run Claude with the Skill hook to populate)*")
print()

# Table: all skills in repo
print("## Per-skill summary (repository skills)")
print()
print("| Skill | Invocations (all time) | Last invoked |")
print("|-------|------------------------:|---------------|")
for s in repo_skills:
    c = counts_all.get(s, 0)
    lu = last_used.get(s)
    print(f"| {s} | {c} | {fmt_ts(lu)} |")
print()

if cutoff is not None:
    print(f"## Invocations in last {days_arg} day(s) (UTC window)")
    print()
    print("| Skill | Invocations |")
    print("|-------|------------:|")
    for s in repo_skills:
        w = counts_window.get(s, 0)
        print(f"| {s} | {w} |")
    print()

never = [s for s in repo_skills if s not in per_skill_events]
if never:
    print("## Never invoked (no lines in log for this skill)")
    print()
    for s in never:
        print(f"- `{s}`")
    print()

tracking_days = (now - tracking_start).days if tracking_start else 0

def is_dead_candidate(s):
    if s in per_skill_events:
        return (now - last_used[s]).days > DEAD_DAYS_STALE
    if not tracking_start:
        return False
    return tracking_days >= DEAD_DAYS_NEVER_INVOKED

# Only skills that meet the dead threshold (human review before deletion).
candidates = []
for s in repo_skills:
    if not is_dead_candidate(s):
        continue
    if s in per_skill_events:
        lu = last_used[s]
        idle = (now - lu).days
        candidates.append((s, f"last use {idle}d ago (> {DEAD_DAYS_STALE}d)"))
    else:
        candidates.append((s, f"never in log; tracking live {tracking_days}d (≥ {DEAD_DAYS_NEVER_INVOKED}d)"))

print("## Dead-skill candidates (review only — confirm before any deletion)")
print()
if not tracking_start:
    print("*(No telemetry yet — nothing to evaluate.)*")
    print()
elif not candidates:
    n_grace = sum(1 for s in repo_skills if s not in per_skill_events)
    if n_grace and tracking_days < DEAD_DAYS_NEVER_INVOKED:
        print(
            f"*(No skills meet the threshold yet. {n_grace} skill(s) have zero log lines; "
            f"never-invoked pruning applies after {DEAD_DAYS_NEVER_INVOKED}d of telemetry.)*"
        )
    else:
        print("*(No skills currently meet the dead-skill threshold.)*")
    print()
else:
    print("| Skill | Reason |")
    print("|-------|--------|")
    for s, reason in candidates:
        print(f"| {s} | {reason} |")
    print()
    print("Confirm each removal out-of-band; autonomous skills may log without explicit user `/skill` commands.")
PY
