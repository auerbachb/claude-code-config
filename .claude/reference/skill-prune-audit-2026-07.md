# Skill prune audit — 2026-07-02 (#431)

Follow-up to #416 skill-usage telemetry. Audit date: 2026-07-02.

## Telemetry

- Log: `~/.claude/skill-usage.log` (global, not in repo)
- Tracking since: 2026-05-01 (~62 days as of audit date)
- Thresholds (`skill-usage-report.sh`): 90d stale **or** never invoked after ≥30d of telemetry
- 90d stale rule: **not yet met** for any previously-invoked skill (re-check ~2026-07-30)

## Invoked skills (active)

| Skill | Invocations | Last used |
|-------|------------|-----------|
| wrap | 36 | 2026-06-25 |
| prompt | 25 | 2026-06-25 |
| fixpr | 10 | 2026-06-25 |
| start-issue | 8 | 2026-06-15 |
| merge-conflict | 1 | 2026-06-25 |
| status | 1 | 2026-05-25 |

## Dead-skill candidates (26 — never invoked, tracking ≥30d)

### Added on/after log start (2026-05-01)

`go-on`, `babysit-pr`, `babysit-pr-stop`, `pr-monitor-and-manage`, `pr-monitor-and-manage-stop`, `admin-merge`, `issue-maker`, `monitor`, `open-code-review`, `recap`

### Pre-May skills with external references (load-bearing)

| Skill | Referenced by |
|-------|---------------|
| check-acceptance-criteria | `ac-checkboxes.sh`, README — removed 2026-07-16 (#582); see addendum |
| lessons | `phase-c-merger.md`, `cr-merge-gate.md`, `wrap/SKILL.md` — removed 2026-07-16 (#582); see addendum |
| merge | phase A/B/C agents, orchestration rules |
| pm + pm-* suite | `pm-worker.md`, cross-skill refs, `stale-cleanup.sh`, README |
| pr-review-help | `subagent-orchestration.md`, `pm-config.md` |
| prioritize *(retired)* | *Historical, as of this audit:* `issue-maker/SKILL.md`, reference docs. Folded into `/pm` and retired (#583) — those references now point at `/pm`. |
| standup | `workday.sh`, `pm-okr/SKILL.md` |
| subagent | phase A/B/C agents, orchestration rules |

## Outcome (original audit, 2026-07-02)

**Zero skills pruned.** All 26 candidates are either too new or referenced by agents, rules, scripts, or other skills. Autonomous invocation (orchestrator, `/wrap`, subagents) explains zero log lines for skills like `subagent`, `merge`, `lessons`, and the PM suite. *(2026-07-16: six of these candidates were subsequently removed — see addendum below.)*

Run `bash .claude/scripts/skill-usage-report.sh` locally for live rollups; confirm each deletion out-of-band before removing any skill directory.

## Addendum — 2026-07-16 (#582): July early trim

The 75-day usage report recovered from the old MacBook (#572) plus owner confirmation ("never typed either") resolved six of the candidates above, removed ahead of the October audit (#573):

- **PM rituals** — `pm-rate-team`, `pm-team-standup`, `pm-sprint-review`, `pm-sprint-plan`: multi-contributor ceremonies never exercised in this solo workflow.
- **`lessons` / `check-acceptance-criteria`** — the prior "load-bearing" classification is resolved: their external references were call-site listings and mentions of `/wrap`'s inline lessons phase, not delegations. `/wrap`'s lessons phase (Steps 4.1–4.3) and the merge gate's AC verification (`cr-merge-gate.md` Step 2 + `ac-checkboxes.sh`) are self-contained, so nothing functional was lost.
