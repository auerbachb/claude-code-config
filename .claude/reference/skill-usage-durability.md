# Skill-Usage Telemetry Durability (issue #572)

How the skill-usage record survives machine moves, OS reinstalls, and
`~/.claude` cleanups.

## Storage model

| Layer | Where | Written by | Role |
|-------|-------|-----------|------|
| Live log | `~/.claude/skill-usage.log` | `skill-usage-tracker.sh` (PostToolUse hook) | Append-only source of truth: `ISO8601Z \t skill_name \t session_id` |
| Live CSV | `~/.claude/skill-usage.csv` | same hook | Aggregated counts (`skill_name,start_date,use_count,last_used`) |
| Durable snapshot | `skill-telemetry` branch, files `skill-usage.log`, `skill-usage.csv`, `manifest.json` at branch root | `skill-usage-snapshot.sh --push` | Machine-independent copy, refreshed ≤ weekly |
| Seed CSV | `.claude/skill-usage.csv` on `main` | PRs | Bootstrap-only template for first run — NOT the snapshot |

The `skill-usage-snapshot-hook.sh` Stop hook backgrounds `--push --quiet`
when ≥7 days (`SNAPSHOT_INTERVAL_DAYS`) have passed since the last confirmed
push. Pushes go through the GitHub contents API (`gh api`) — no local
checkout, no commits to `main`, no PR noise. When nothing changed, no commit
is created but the throttle still advances. Offline attempts are silent
no-ops that retry on a later Stop. `stale-cleanup.sh` lists `skill-telemetry`
in `PROTECTED_BRANCHES` so idle weeks never make the branch prunable.

Check state anytime: `bash .claude/scripts/skill-usage-snapshot.sh --status`

## Recovery how-to

**Machine move (old machine still alive):** copy the old machine's
`~/.claude/skill-usage.log` and `~/.claude/skill-usage.csv` over
(AirDrop/scp), then on the new machine:

```bash
bash .claude/scripts/skill-usage-merge.sh --log <old.log> --csv <old.csv>
bash .claude/scripts/skill-usage-report.sh     # verify the full window
bash .claude/scripts/skill-usage-snapshot.sh --push --force   # make it durable now
```

Default `--csv-counts sum` is correct here: the two machines' histories are
disjoint. Live files are backed up to `*.bak.<UTC-ts>` before any write.

**Fresh machine / lost `~/.claude` (old machine gone):**

```bash
bash .claude/scripts/skill-usage-snapshot.sh --restore
```

Fetches the snapshot and merges with `--csv-counts recompute`
(`use_count = max(each CSV's count, merged-log count)`) — idempotent and
safe when local files partially survive; on a truly fresh machine it
degrades to a copy. You lose at most the invocations since the last push
(≤ 7 days).

## Fallback baseline (old files declared unrecoverable)

If raw files from the pre-switch machine never arrive, encode a baseline
into the live CSV instead (documented as **approximate**): per-skill rows
with `start_date` 2026-05-01, counts and `last_used` from the best available
snapshot table. Known sources, freshest first:

1. `~/Downloads/skill-usage-report-2026-07-16.md` — rendered on the old
   MacBook on 2026-07-16 (145 invocations through Jul 16).
2. Issue #431's 2026-06-26 comment table — 106 invocations through Jun 26.

Limitations, by design: a CSV baseline cannot back-date the log-derived
"tracking since" line in `skill-usage-report.sh` (that needs real log
lines), and recompute-mode restores preserve baseline counts via the `max`
rule but never regenerate the underlying events.

## Why the skill-first reflex protects this record

Only `Skill`-tool invocations reach `~/.claude/skill-usage.log` — the
PostToolUse hook has nothing to fire on when a skill is hand-rolled from
memory instead. Every hand-rolled run is therefore an invisible use: the
skill looks unused, prune audits (`audit-skill-usage.sh`,
`skill-prune-audit-2026-07.md`) under-count it, and a live skill can be
recommended for deletion. That is the reason `.claude/rules/skill-first.md`
requires the Skill tool rather than merely suggesting it.

## Related

- `skill-usage-merge.sh --help` / `skill-usage-snapshot.sh --help` — full
  semantics, locking, and edge cases
- Issues #416 (tracking), #431 (first audit), #572 (durability)
