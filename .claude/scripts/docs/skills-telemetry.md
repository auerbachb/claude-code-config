# Skills & Telemetry

Scripts that audit, report, and sync skill and script usage telemetry.

Full contract — flags, exit codes, behavior — lives in each script's `--help` output and header; where a reference doc owns the mechanism, this page names it.

| Script | Purpose |
|--------|---------|
| [skill-usage-report.sh](../skill-usage-report.sh) | Read `~/.claude/skill-usage.log` and print usage tables and dead-skill candidates |
| [skill-usage-snapshot.sh](../skill-usage-snapshot.sh) | Push/restore skill telemetry to/from the repo's dedicated `skill-telemetry` branch |
| [skill-usage-merge.sh](../skill-usage-merge.sh) | Merge another machine's skill-usage telemetry into the live log files |
| [audit-skill-usage.sh](../audit-skill-usage.sh) | Legacy monthly skill-usage audit against `.claude/data/skill-usage.json` |
| [skill-conventions-audit.sh](../skill-conventions-audit.sh) | Static audit that `.claude/skills/*/SKILL.md` files match repo conventions |
| [script-usage-report.sh](../script-usage-report.sh) | Summarize script adherence telemetry from `~/.claude/script-usage.log` |

---

[← back to the index](../README.md)
