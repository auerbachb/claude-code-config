---
name: quota
description: Report today's API spend from the local usage ledger and project end-of-day spend against the daily cap. Triggers on "quota", "spend", "how much have I spent", "budget today", "am I over budget".
triggers:
  - quota
  - api spend
  - how much have I spent today
  - daily budget
  - end of day projection
  - am I over budget
model: sonnet
allowed-tools:
  - Read
  - Glob
  - Grep
  - Bash
---

Report today's API spend and project end-of-day spend versus the daily cap.

Spend is tracked locally: the `quota-usage-hook.sh` PostToolUse hook appends one
tab-separated line per assistant response to `~/.claude/quota-usage.log` (the
same append-only family as `script-usage.log` / `skill-usage.log`), costing each
response with the per-model pricing in `quota-config.json`. `quota-budget.sh`
aggregates that ledger; this skill formats its output.

## Steps

### Step 1: Read the spend snapshot

Run the budget script from the repo root (so it resolves `quota-config.json`):

```bash
.claude/scripts/quota-budget.sh --project
```

It prints a single-line JSON object and caches it under `quota_daily` in
`~/.claude/session-state.json`. Parse these fields:

- `date` — the ET day being reported.
- `spend_usd` — actual spend so far today.
- `cap_usd` — the daily cap from `quota-config.json` (`daily_cap_usd`).
- `remaining_usd` — `cap − spend`, clamped at 0.
- `responses` — number of assistant responses counted today.
- `fraction_of_day_elapsed` — fraction (0–1) of the ET day that has passed.
- `projected_eod_usd` — `spend ÷ fraction_of_day_elapsed` (linear run-rate projection).
- `over_cap` — already past the cap.
- `exhausted` — `spend ≥ cap`.
- `projected_exhausted` — projection exceeds the cap.

If the ledger does not exist yet, the script reports `spend_usd: 0` (no spend
recorded) — say so rather than erroring.

### Step 2: Classify the day

- **Under budget** — `projected_exhausted` is false.
- **Trending over** — `projected_exhausted` is true but `over_cap` is false (on
  pace to exceed the cap; not over yet).
- **Over budget** — `over_cap` (or `exhausted`) is true.

### Step 3: Report

Output a compact summary, e.g.:

```
Quota — 2026-06-25 (ET)
Spent today : $29.55 of $100.00 cap   (70% remaining)
Responses   : 2
Day elapsed : 81%
Projected   : $36.50 by end of day  ✅ under budget
```

Use the projection verdict in the last line:
- `✅ under budget` when `projected_exhausted` is false.
- `⚠️ trending over` when `projected_exhausted` is true and `over_cap` is false —
  add the projected overage (`projected_eod_usd − cap_usd`).
- `🛑 over budget` when `over_cap`/`exhausted` is true — add the actual overage
  (`spend_usd − cap_usd`).

### Step 4 (optional): Inspect or adjust

- Per-model breakdown for today:

```bash
TODAY=$(TZ='America/New_York' date +%F)
awk -F'\t' -v d="$TODAY" '$2==d {c[$5]+=$10} END {for (m in c) printf "%-28s $%.2f\n", m, c[m]}' ~/.claude/quota-usage.log
```

- A specific past ET day: `.claude/scripts/quota-budget.sh --date YYYY-MM-DD`.
- Gate spend-sensitive work: `.claude/scripts/quota-budget.sh --check` exits `1`
  when today's spend is at or above the cap.
- Change the cap or pricing by editing `quota-config.json` (`daily_cap_usd` and
  the per-model `pricing` map, USD per 1,000,000 tokens).

## Notes

- The hook fires on `PostToolUse`, so a final text-only response (no tool call)
  is not counted; the ledger captures the large majority of spend, which is what
  the run-rate projection needs.
- The projection is a simple linear run-rate (`spend ÷ fraction_of_day_elapsed`);
  early in the day a few large responses can inflate it. Weight the actual
  `spend_usd` more heavily before noon ET.
