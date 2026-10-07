# Utilities

<!-- catalog:category id=utilities order=120 -->
<!-- catalog:covers Miscellaneous helpers used by skills and hooks, plus the Python helpers -->

Miscellaneous helpers used by skills and hooks.

Full contract — flags, exit codes, behavior — lives in each script's `--help` output and header; where a reference doc owns the mechanism, this page names it.

| Script | Purpose |
|--------|---------|
<!-- catalog:rows:begin -->
| [desk-cli.sh](../../../desk/bin/desk-cli.sh) | Human-queue CLI for the desk (`desk/bin/desk-cli.sh`): runs human-queue.sh with the store URL found the way the capture hook finds it |
| [desk-tick.sh](../../../desk/bin/desk-tick.sh) | Human-queue desk tick loop (`desk/bin/desk-tick.sh`): the /desk Monitor command; ticks the store and prints a line only when the desk has something to do |
| [graphite-repo-init.sh](../graphite-repo-init.sh) | Run `gt repo init` to create `.git/.graphite_repo_config` for Graphite CLI |
| [hhg-state.sh](../hhg-state.sh) | Extract a 2-letter USPS state code from HHG-formatted text |
| [human-queue.sh](../../../desk/bin/human-queue.sh) | Human-queue store CLI (`desk/bin/human-queue.sh`): auto-discovers subcommands in `desk/bin/cmd/`, applies `desk/schema/` migrations, and exits 7 within two seconds when the database is unset or unreachable so callers can fail open |
| [model-fleet.sh](../model-fleet.sh) | Resolve the current Claude model fleet from `.claude/model-fleet.json` |
| [portable-handoff-context.sh](../portable-handoff-context.sh) | Emit a bounded, secret-free JSON snapshot of the exact repository/worktree, Git/linkage state, and current-session task recovery metadata for `/end` |
| [portable-handoff-lint.sh](../portable-handoff-lint.sh) | Enforce portable handoff structure, working-copy identity, cross-agent resume guidance, and freedom from harness-only references |
| [portable-handoff-publish.sh](../portable-handoff-publish.sh) | Lint and atomically update one locked canonical manual handoff per repository/session |
| [pr-summary-material.sh](../../../desk/bin/pr-summary-material.sh) | Human-queue Reviews material (`desk/bin/pr-summary-material.sh`): prints a PR's or issue's raw material for a level 1, 2, or 3 summary (title, labels, closing issue; body, commits, files, tests; the bounded diff, narrowed by --path); read-only |
| [reference-catalog-lint.sh](../reference-catalog-lint.sh) | Lint the `.claude/reference/` catalog against the directory contents (index/disk parity, no phantoms, no duplicates) |
| [report-path.sh](../report-path.sh) | Return a collision-free monthly report path for `/review-stack-audit` and `/harness-audit`, so a second same-month audit cannot overwrite the first |
| [verify-exit-report-block.sh](../verify-exit-report-block.sh) | Verify stdin contains a parseable EXIT_REPORT with all required fields |
| [wake-target.sh](../../../desk/bin/wake-target.sh) | Human-queue wake-up address (`desk/bin/wake-target.sh`): maps a Decision's return address to the running session's messaging address; read-only |
<!-- catalog:rows:end -->

## Python helpers

Called by other scripts; run `python3 .claude/scripts/<name>.py --help` for usage.

| Script | Purpose |
|--------|---------|
<!-- catalog:rows:begin kind=py -->
| [cr-plan-filter.py](../cr-plan-filter.py) | Substantive-plan filter for CodeRabbit issue comments (called by `cr-plan.sh`) |
| [memory-audit.py](../memory-audit.py) | Memory-store audit engine behind `/memory-clean` |
<!-- catalog:rows:end -->

---

[← back to the index](../README.md)
