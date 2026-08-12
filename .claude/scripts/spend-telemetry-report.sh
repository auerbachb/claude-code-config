#!/usr/bin/env bash
# spend-telemetry-report.sh — Summarize thread-vs-inline spend/model-tier telemetry
#
# PURPOSE:
#   Reads ~/.claude/spend-telemetry.log (append-only, one line per event;
#   written by spend-session-tracker.sh and spend-subagent-tracker.sh hooks)
#   and emits Markdown tables summarizing the thread-vs-inline split and
#   model-tier distribution, for use in PM routing audits (issue #710).
#
#   This replaces the proxy-based thread-count method from pm-routing-audit-2026-07.md
#   with real execution-type attribution. See .claude/reference/spend-telemetry-pipeline.md
#   for the full schema, reliability caveats, and audit re-run methodology.
#
# RELIABILITY CAVEATS:
#   - Token spend columns show "n/a" when the runtime does not expose token data
#     to hooks (the common case). Do NOT interpret "n/a" as zero spend.
#   - Model tier for inline runs is derived from agent_type frontmatter, not
#     measured at runtime. If an agent's model changes without a file update,
#     the tier may be stale.
#   - SessionStart fires on compact/resume/clear too; the hook skips non-startup
#     sources, but an absent source field is treated as startup — see the hook.
#   - Data only exists from the point this pipeline was installed. Pre-install
#     history is proxy-only (see pm-routing-audit-2026-07.md §Phase 1 Task 1).
#   - Per safety.md §"Anthropic Quota & Spend Authority", this data is
#     OBSERVATIONAL ONLY and must never gate agent decisions or quota checks.
#
# USAGE:
#   spend-telemetry-report.sh [--days N]
#   spend-telemetry-report.sh --help
#
#   --days N  Optional: also emit a table for the most recent N UTC days.
#             N must be a positive integer.
#
# LOG FORMAT (~/.claude/spend-telemetry.log, tab-separated):
#   ISO8601Z  event_type  exec_type  model_tier  agent_type  session_id  agent_id  tokens
#
# EXIT STATUS:
#   0  Success (including empty log — prints a "No telemetry log" message).
#   2  Argument error (unknown flag, invalid --days value).
#
# RELATED:
#   .claude/reference/spend-telemetry-pipeline.md — schema, caveats, audit methodology
#   .claude/hooks/spend-session-tracker.sh         — SessionStart capture
#   .claude/hooks/spend-subagent-tracker.sh        — SubagentStop capture

set -euo pipefail
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" >> "$HOME/.claude/script-usage.log" 2>/dev/null || true

usage() {
  sed -n '2,43p' "$0" | sed 's/^# \{0,1\}//'
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

LOG_PATH="${HOME}/.claude/spend-telemetry.log"

python3 - "${DAYS:-0}" "$LOG_PATH" <<'PY'
import sys
from collections import defaultdict
from datetime import datetime, timedelta, timezone

days_arg = int(sys.argv[1])
log_path = sys.argv[2]

import os
if not os.path.exists(log_path):
    print("## Spend / Thread-Type Telemetry Report\n")
    print(f"No telemetry log found at `{log_path}`.")
    print("The log is created automatically when the spend-telemetry hooks fire.")
    print("Run a new Claude Code session to generate the first record.")
    sys.exit(0)

EXEC_TYPES = ("thread", "inline")
# Model tiers in display order
MODEL_TIERS_ORDER = ("opus", "sonnet", "haiku", "fable", "unknown")

class Record:
    __slots__ = ("ts", "ts_str", "event_type", "exec_type", "model_tier",
                 "agent_type", "session_id", "agent_id", "tokens")

records = []
tracking_start = None

with open(log_path, encoding="utf-8", errors="replace") as f:
    for lineno, raw in enumerate(f, 1):
        raw = raw.rstrip("\n")
        if not raw:
            continue
        parts = raw.split("\t")
        if len(parts) < 3:
            # Tolerate short/malformed lines — skip silently
            continue
        r = Record()
        r.ts_str = parts[0] if parts[0] else ""
        r.event_type = parts[1] if len(parts) > 1 else ""
        r.exec_type = parts[2] if len(parts) > 2 else ""
        r.model_tier = (parts[3] if len(parts) > 3 else "") or "unknown"
        r.agent_type = parts[4] if len(parts) > 4 else ""
        r.session_id = parts[5] if len(parts) > 5 else ""
        r.agent_id = parts[6] if len(parts) > 6 else ""
        tok_raw = parts[7].strip() if len(parts) > 7 else ""
        try:
            r.tokens = int(tok_raw) if tok_raw else None
        except ValueError:
            r.tokens = None

        # Parse timestamp for windowing
        try:
            r.ts = datetime.fromisoformat(r.ts_str.replace("Z", "+00:00"))
        except Exception:
            r.ts = None

        records.append(r)
        if r.ts and tracking_start is None:
            tracking_start = r.ts

now = datetime.now(timezone.utc)

def summarize(recs):
    """Return (counts, token_sums, token_counts) dicts keyed by (exec_type, model_tier).

    token_sums:   sum of tokens for records that have token data (None = no data at all)
    token_counts: number of records in the group that had token data
    counts:       total records in the group (including those with no token data)
    """
    counts = defaultdict(int)
    token_sums = defaultdict(lambda: None)  # None = no data
    token_counts = defaultdict(int)         # records with token data
    for r in recs:
        et = r.exec_type if r.exec_type in EXEC_TYPES else "unknown"
        mt = r.model_tier if r.model_tier else "unknown"
        counts[(et, mt)] += 1
        if r.tokens is not None:
            cur = token_sums[(et, mt)]
            token_sums[(et, mt)] = (cur or 0) + r.tokens
            token_counts[(et, mt)] += 1
    return counts, token_sums, token_counts

def all_model_tiers(counts):
    seen = {mt for (_, mt) in counts}
    ordered = [t for t in MODEL_TIERS_ORDER if t in seen]
    extras = sorted(seen - set(MODEL_TIERS_ORDER))
    return ordered + extras

def format_tokens(val, bearing=None, total=None):
    """Format a token value.

    If bearing and total are provided and bearing < total, appends a partial
    indicator so the user knows the sum is incomplete (e.g. '1.5K (partial: 1/3)').
    """
    if val is None:
        return "n/a"
    if val >= 1_000_000:
        s = f"{val/1_000_000:.2f}M"
    elif val >= 1_000:
        s = f"{val/1_000:.1f}K"
    else:
        s = str(val)
    if bearing is not None and total is not None and bearing < total:
        s += f" (partial: {bearing}/{total})"
    return s

def render_table(recs, heading):
    counts, token_sums, token_counts = summarize(recs)
    tiers = all_model_tiers(counts)

    if not tiers:
        print(f"\n{heading}\n")
        print("No records in this window.\n")
        return

    total_thread = sum(counts[(et, mt)] for (et, mt) in counts if et == "thread")
    total_inline = sum(counts[(et, mt)] for (et, mt) in counts if et == "inline")
    grand_total = sum(counts.values())

    print(f"\n{heading}\n")
    print(f"**Total events:** {grand_total} "
          f"(thread: {total_thread}, inline: {total_inline})\n")

    # Summary table: exec_type rows, model_tier columns
    col_widths = {mt: max(len(mt), 6) for mt in tiers}
    hdr_exec = "exec_type"
    print(f"| {hdr_exec:<12} | " +
          " | ".join(f"{'count':>{col_widths[mt]}}" for mt in tiers) +
          " | tokens |")
    print(f"| {'-'*12} | " +
          " | ".join(f"{'-'*col_widths[mt]}" for mt in tiers) +
          " | ------ |")

    for exec_type in ("thread", "inline", "unknown"):
        row_counts = {mt: counts.get((exec_type, mt), 0) for mt in tiers}
        row_total = sum(row_counts.values())
        if row_total == 0 and exec_type == "unknown":
            continue
        # Aggregate token sum for this exec_type across all tiers
        tok_total = None
        tok_bearing = 0
        for mt in tiers:
            v = token_sums.get((exec_type, mt))
            if v is not None:
                tok_total = (tok_total or 0) + v
                tok_bearing += token_counts.get((exec_type, mt), 0)
        print(f"| {exec_type:<12} | " +
              " | ".join(f"{row_counts[mt]:>{col_widths[mt]}}" for mt in tiers) +
              f" | {format_tokens(tok_total, tok_bearing if tok_total is not None else None, row_total)} |")

    print()

    # Per-model-tier breakdown
    print("**Per-model-tier breakdown:**\n")
    print(f"| model_tier | thread | inline | total | tokens |")
    print(f"| ---------- | ------ | ------ | ----- | ------ |")
    for mt in tiers:
        t = counts.get(("thread", mt), 0)
        i = counts.get(("inline", mt), 0)
        mt_total = sum(counts.get((et, mt), 0) for et in ("thread", "inline", "unknown"))
        tok = None
        tok_bear = 0
        for et in ("thread", "inline", "unknown"):
            v = token_sums.get((et, mt))
            if v is not None:
                tok = (tok or 0) + v
                tok_bear += token_counts.get((et, mt), 0)
        print(f"| {mt:<10} | {t:>6} | {i:>6} | {mt_total:>5} | {format_tokens(tok, tok_bear if tok is not None else None, mt_total)} |")
    print()

# --- All-time table ---
tracking_label = (
    f"Tracking since: `{tracking_start.strftime('%Y-%m-%d')}`"
    if tracking_start else "Tracking start: unknown (empty log)"
)
print("## Spend / Thread-Type Telemetry Report")
print()
print(f"> {tracking_label}")
print(f"> Data source: `~/.claude/spend-telemetry.log` ({len(records)} record(s))")
print(f"> Generated: `{now.strftime('%Y-%m-%dT%H:%M:%SZ')}`")
print(f">")
print(f"> **Token columns show `n/a` when the runtime did not expose token data**")
print(f"> **(the common case). `n/a` is NOT zero spend.**")
print()

render_table(records, "### All-time thread-vs-inline breakdown")

# --- Windowed table ---
if days_arg > 0:
    cutoff = now - timedelta(days=days_arg)
    windowed = [r for r in records if r.ts and r.ts >= cutoff]
    render_table(windowed, f"### Last {days_arg} day(s) (from {cutoff.strftime('%Y-%m-%d')} UTC)")

# --- Agent-type inventory (for inline runs) ---
inline_by_agent = defaultdict(int)
for r in records:
    if r.exec_type == "inline" and r.agent_type:
        inline_by_agent[r.agent_type] += 1

if inline_by_agent:
    print("### Inline agent-type inventory\n")
    print("| agent_type | invocations |")
    print("| ---------- | ----------- |")
    for at, cnt in sorted(inline_by_agent.items(), key=lambda x: -x[1]):
        print(f"| {at} | {cnt} |")
    print()

print("---")
print()
print("*Re-run methodology: see `.claude/reference/spend-telemetry-pipeline.md`*")
PY
