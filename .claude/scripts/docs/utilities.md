# Utilities

Miscellaneous helpers used by skills and hooks.

| Script | Purpose |
|--------|---------|
| [model-fleet.sh](../model-fleet.sh) | Resolve the current Claude model fleet from `.claude/model-fleet.json` |
| [portable-handoff-context.sh](../portable-handoff-context.sh) | Emit a bounded, secret-free JSON snapshot of the exact repository/worktree, Git/linkage state, and current-session task recovery metadata for `/end` |
| [portable-handoff-lint.sh](../portable-handoff-lint.sh) | Enforce portable handoff structure, working-copy identity, cross-agent resume guidance, and freedom from harness-only references |
| [portable-handoff-publish.sh](../portable-handoff-publish.sh) | Lint and atomically update one locked canonical manual handoff per repository/session |
| [verify-exit-report-block.sh](../verify-exit-report-block.sh) | Verify stdin contains a parseable EXIT_REPORT with all required fields |
| [graphite-repo-init.sh](../graphite-repo-init.sh) | Run `gt repo init` to create `.git/.graphite_repo_config` for Graphite CLI |
| [hhg-state.sh](../hhg-state.sh) | Extract a 2-letter USPS state code from HHG-formatted text |
| [reference-catalog-lint.sh](../reference-catalog-lint.sh) | Lint the `.claude/reference/` catalog against the directory contents (index/disk parity, no phantoms, no duplicates) |

## Python helpers

Called by other scripts; run `python3 .claude/scripts/<name>.py --help` for usage.

| Script | Purpose |
|--------|---------|
| [cr-plan-filter.py](../cr-plan-filter.py) | Substantive-plan filter for CodeRabbit issue comments (called by `cr-plan.sh`) |
| [memory-audit.py](../memory-audit.py) | Memory-store audit engine behind `/memory-clean` |

---

[← back to the index](../README.md)
