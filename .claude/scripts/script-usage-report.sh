#!/usr/bin/env bash
# script-usage-report.sh — Summarize script adherence telemetry.
#
# PURPOSE:
#   Reads ~/.claude/script-usage.log and ~/.claude/script-bypass.log, then
#   reports script invocations, likely bypasses, and adherence ratios.
#
# USAGE:
#   script-usage-report.sh [--days N]
#   script-usage-report.sh --help
#
# OUTPUT:
#   Human-readable table:
#     Script | Invocations | Bypasses | Adherence %
#   plus the top 5 bypass contexts grouped by cwd.
#
# LOG FORMATS:
#   script-usage.log  : timestamp UTC, script basename, args
#   script-bypass.log : timestamp UTC, cwd, matched pattern, suggested script,
#                       command truncated to 200 chars
#   Both logs are tab-separated and stored under ~/.claude/.

set -euo pipefail
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" >> "$HOME/.claude/script-usage.log"

usage() {
  sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'
}

DAYS=7

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

if ! [[ "$DAYS" =~ ^[0-9]+$ ]] || [[ "$DAYS" -lt 1 ]]; then
  echo "ERROR: --days must be a positive integer" >&2
  exit 2
fi

python3 - "$DAYS" "$HOME/.claude/script-usage.log" "$HOME/.claude/script-bypass.log" <<'PY'
import os
import sys
from collections import Counter
from datetime import datetime, timedelta, timezone

days = int(sys.argv[1])
usage_path = sys.argv[2]
bypass_path = sys.argv[3]
cutoff = datetime.now(timezone.utc) - timedelta(days=days)


def parse_ts(value):
    value = (value or "").strip()
    if not value:
        return None
    if value.endswith("Z"):
        value = value[:-1] + "+00:00"
    try:
        parsed = datetime.fromisoformat(value)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def in_window(ts_value):
    parsed = parse_ts(ts_value)
    return parsed is not None and parsed >= cutoff


def best_effort_context(cwd):
    cwd = cwd or "(unknown cwd)"
    parts = [part for part in cwd.split(os.sep) if part]
    if ".claude" in parts:
        idx = parts.index(".claude")
        if idx + 2 < len(parts) and parts[idx + 1] == "skills":
            return f"skill:{parts[idx + 2]}"
        if idx + 2 < len(parts) and parts[idx + 1] == "worktrees":
            return f"worktree:{parts[idx + 2]}"
    for marker in ("skills-worktree", "claude-code-config", "workspace"):
        if marker in parts:
            idx = parts.index(marker)
            if idx + 1 < len(parts):
                return f"{marker}/{parts[idx + 1]}"
            return marker
    return cwd


usage_counts = Counter()
bypass_counts = Counter()
contexts = Counter()

if os.path.exists(usage_path):
    with open(usage_path, "r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.rstrip("\n")
            if not line:
                continue
            fields = line.split("\t")
            if len(fields) < 2 or not in_window(fields[0]):
                continue
            script = fields[1].strip() or "(unknown)"
            usage_counts[script] += 1

if os.path.exists(bypass_path):
    with open(bypass_path, "r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.rstrip("\n")
            if not line:
                continue
            fields = line.split("\t")
            if len(fields) < 4 or not in_window(fields[0]):
                continue
            cwd = fields[1].strip() or "(unknown cwd)"
            script = fields[3].strip() or "(unknown)"
            bypass_counts[script] += 1
            contexts[best_effort_context(cwd)] += 1

scripts = sorted(set(usage_counts) | set(bypass_counts))
total_usage = sum(usage_counts.values())
total_bypass = sum(bypass_counts.values())
total_events = total_usage + total_bypass
overall = (total_usage / total_events * 100.0) if total_events else 0.0

print(f"Script usage adherence report (last {days} day{'s' if days != 1 else ''})")
print(f"Usage log : {usage_path}")
print(f"Bypass log: {bypass_path}")
print()
print(f"{'Script':<32} {'Invocations':>12} {'Bypasses':>9} {'Adherence %':>12}")
print("-" * 70)
if scripts:
    for script in scripts:
        invocations = usage_counts[script]
        bypasses = bypass_counts[script]
        denominator = invocations + bypasses
        adherence = (invocations / denominator * 100.0) if denominator else 0.0
        print(f"{script:<32} {invocations:>12} {bypasses:>9} {adherence:>11.1f}%")
else:
    print(f"{'(no telemetry in window)':<32} {0:>12} {0:>9} {'n/a':>12}")
print("-" * 70)
print(f"{'TOTAL':<32} {total_usage:>12} {total_bypass:>9} {overall:>11.1f}%")
print()
print("Top bypass contexts")
print("-------------------")
if contexts:
    for context, count in contexts.most_common(5):
        print(f"{count:>5}  {context}")
else:
    print("No bypasses recorded in window.")
PY
