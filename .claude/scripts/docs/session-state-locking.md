# Session State & Locking

<!-- catalog:category id=session-state-locking order=60 -->
<!-- catalog:covers Scripts that read and write `~/.claude/session-state.json` and per-PR handoff files -->

Scripts that read and write `~/.claude/session-state.json` and per-PR handoff files.

Full contract — flags, exit codes, behavior — lives in each script's `--help` output and header (for a sourced library, the header); where a reference doc owns the mechanism, this page names it.

| Script | Purpose |
|--------|---------|
<!-- catalog:rows:begin -->
| [background-task-registry.sh](../background-task-registry.sh) | Locked exact-runtime-ID registry for current and historical Agent, Bash, Monitor, and Workflow tasks |
| [chip-claim-receipt.sh](../chip-claim-receipt.sh) | Save or recover an acquired Form A claim in its assigned Git worktree |
| [execution-pause.sh](../execution-pause.sh) | Arm, inspect, or explicitly clear a repo/session-scoped background-launch gate |
| [handoff-migrate.sh](../handoff-migrate.sh) | One-time migration of flat handoff files to per-repo scoped paths |
| [handoff-state.sh](../handoff-state.sh) | Locked read/write helper for per-repo handoff files (`~/.claude/handoffs/`) |
| [issue-completion.sh](../issue-completion.sh) | Independently verify merged-issue completion and reconcile one explicitly scope-verified issue |
| [recovery-evidence.sh](../recovery-evidence.sh) | Capture and classify raw recovery verdict evidence without turning parse/execution failure into success |
| [safe-close-inventory.sh](../safe-close-inventory.sh) | Read-only inventory of everything a thread started or still owns, with a safe-to-close verdict; each item tagged lost / keeps_running / orphaned / harmless, unreadable categories reported unknown |
| [session-state-audit.sh](../session-state-audit.sh) | Audit and guarded repair of `~/.claude/session-state.json` |
| [session-state.sh](../session-state.sh) | Canonical read/write helper for `~/.claude/session-state.json` (atomic, scoped, field-typed) |
| [state-lock.sh](../state-lock.sh) | *(library — source, do not execute)* Portable mkdir-based advisory lock for session-state writes |
<!-- catalog:rows:end -->

---

[← back to the index](../README.md)
