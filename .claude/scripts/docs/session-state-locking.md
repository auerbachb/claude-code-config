# Session State & Locking

Scripts that read and write `~/.claude/session-state.json` and per-PR handoff files.

| Script | Purpose |
|--------|---------|
| [session-state.sh](../session-state.sh) | Canonical read/write helper for `~/.claude/session-state.json` (atomic, scoped, field-typed) |
| [background-task-registry.sh](../background-task-registry.sh) | Locked exact-runtime-ID registry for current and historical Agent, Bash, Monitor, and Workflow tasks |
| [execution-pause.sh](../execution-pause.sh) | Arm, inspect, or explicitly clear a repo/session-scoped background-launch gate |
| [state-lock.sh](../state-lock.sh) | *(library — source, do not execute)* Portable mkdir-based advisory lock for session-state writes |
| [session-state-audit.sh](../session-state-audit.sh) | Audit and guarded repair of `~/.claude/session-state.json` |
| [handoff-state.sh](../handoff-state.sh) | Locked read/write helper for per-repo handoff files (`~/.claude/handoffs/`) |
| [handoff-migrate.sh](../handoff-migrate.sh) | One-time migration of flat handoff files to per-repo scoped paths |

---

[← back to the index](../README.md)
