# Reference Files

This directory contains full forms of multi-line code snippets, JSON schemas, and GraphQL queries that would otherwise inflate the auto-loaded rule context. Rule files reference these when needed.

Files here are NOT auto-loaded by Claude Code. Agents read them on demand when working with the relevant workflow.

## Contents

### Schemas

- [Schemas](catalog/schemas.md)

### Runbooks and long command forms

- [Runbooks and long command forms](catalog/runbooks.md)

### Workflow decomposition and PM helpers

- [Workflow decomposition and PM helpers](catalog/workflow-pm-helpers.md)

### Living trackers (updated each cycle — not point-in-time)

- [Living trackers (updated each cycle — not point-in-time)](catalog/living-trackers.md)

### Audits and research (point-in-time)

- [Audits and research (point-in-time)](catalog/audits-and-research.md)

> **Exempt from corpus-wide rewrites (#791).** Every file in this section is a dated snapshot of what was true when it was written. Sweeping renames — the versionless model-name rename is the standing example — **must skip them**: rewriting a record to match today's vocabulary falsifies the history it exists to preserve. A versioned model name (`Opus 5`, `Haiku 4.5`) inside one of these files is correct by construction, not drift. The rename applies to the operative corpus — `CLAUDE.md`, `.claude/rules/`, `.claude/skills/`, `.claude/agents/` — plus the living contract docs in this directory that those files consume normatively (`chip-launching.md`, `chip-model-guard-decision.md`). Enforced by `.github/scripts/chip-model-guard-lint.sh`, whose scan is scoped to exactly that set.

### Diagrams (mermaid stubs and indexes)

- [Diagrams (mermaid stubs and indexes)](catalog/diagrams.md)

### Verification logs

- [Verification logs](catalog/verification-logs.md)

New entries go in the matching catalog page, not here. Edit this index only to add a category: add its `###` heading and page link, then add the page under `catalog/`. `.claude/scripts/reference-catalog-lint.sh` checks every root-level entry across the pages (the `diagrams/` rows are not parity-checked) and that each link sits under its matching heading.
