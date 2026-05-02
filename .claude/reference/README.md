# Reference Files

This directory contains full forms of multi-line code snippets, JSON schemas, and GraphQL queries that would otherwise inflate the auto-loaded rule context. Rule files reference these when needed.

Files here are NOT auto-loaded by Claude Code. Agents read them on demand when working with the relevant workflow.

## Contents

### Schemas

- `handoff-file-schema.json` — full JSON schema for `~/.claude/handoffs/pr-{N}-handoff.json`
- `session-state-schema.json` — full JSON schema for `~/.claude/session-state.json`

### Runbooks and long command forms

- `cr-polling-commands.md` — full multi-line `gh api` commands for CR review polling and CI verification
- `graphql-thread-resolution.md` — full GraphQL queries/mutations for resolving PR review threads
- `exit-report-format.md` — full structured exit report block specification
- `greptile-setup.md` — Greptile dashboard setup notes
- `greptile-reply-format.md` — reply conventions for Greptile threads

### Workflow decomposition and PM helpers

- `phase-decomposition.md` — phase split reference material
- `pm-data-patterns.md` — PM skills data patterns and bot filters
- `pm-monitoring-decision.md` — `/loop` vs `CronCreate` hybrid decision
- `scheduling-failure-modes.md` — recurring poll failure analysis
- `skill-sync-hooks.md` — skills worktree sync and hook registration narrative

### Audits and research (point-in-time)

- `ai-review-tool-audit-2026-04.md` — AI review tool chain audit (#368 / #377)
- `repo-audit-2026-05.md` — bundled org + efficiency + best-practices audit (#413–#415)
- `script-extraction-audit.md` — deterministic script extraction inventory (#271)
- `graphite-stacked-prs-research-2026-05.md` — stacked PR economics (#418 / #433)

### Diagrams (mermaid stubs and indexes)

- `diagrams/README.md` — index of diagram stub files
- `diagrams/skills-worktree-symlinks.md` — topology (stub)
- `diagrams/review-merge-pipeline.md` — review chain (stub)
- `diagrams/hook-lifecycle.md` — hook sequence (stub)

### Verification logs

- `issue-162-phase-protocol-verification.md` — static verification log for exit reports, phase B/C protocols, and monitor loop ordering (issue #162)
