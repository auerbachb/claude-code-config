# Reference Files

This directory contains full forms of multi-line code snippets, JSON schemas, and GraphQL queries that would otherwise inflate the auto-loaded rule context. Rule files reference these when needed.

Files here are NOT auto-loaded by Claude Code. Agents read them on demand when working with the relevant workflow.

## Contents

### Schemas

- `handoff-file-schema.json` — full JSON schema for `~/.claude/handoffs/{owner}/{repo}/pr-{N}-handoff.json`
- `session-state-schema.json` — full JSON schema for `~/.claude/session-state.json`

### Runbooks and long command forms

- `cli-tool-defaults.md` — installed service CLIs (vercel, neonctl, railway, cloudinary) and common commands; CLI-first over web dashboards
- `cr-polling-commands.md` — full multi-line `gh api` commands for CR review polling and CI verification
- `cr-rate-limits.md` — full CR rate-limit caps, hourly-state mechanics, and `cr-review-hourly.sh` flags
- `codeowner-bot-approvals.md` — CODEOWNERS handling for review bots and stale-approval re-trigger commands
- `capability-discovery-examples.md` — false-walls vs real-walls catalog for try-CLI-before-handoff (`safety.md` Capability Discovery)
- `merge-gate-reviewer-paths.md` — per-reviewer merge-gate path details (CR/CodeAnt, BugBot, Greptile)
- `codeant-graphite-supplemental.md` — CodeAnt and Graphite supplemental polling on the CR path
- `local-review-cli-failure-modes.md` — how CodeAnt/CodeRabbit fake a clean pass on failure, 403 triage, 15-file cap, and binary-absent detection (#642, #819)
- `wrap-fixpr-delegation.md` — `/wrap` Step 2.1 → full `/fixpr` recovery handoff contract
- `state-file-contracts.md` — expanded scoping, write-lock, migration, and field-type mechanics for `session-state.json` + handoffs (`handoff-files.md`; #625, #638, #639, #651, #655, #682, #687, #704)
- `authorship-guard.md` — `pr-authorship.sh` exit-code semantics, the three shared-script fail-safes, and `--allow-nonauthor` override plumbing (`safety.md` §Authorship; #733)
- `autofile-dedup.md` — duplicate-check thresholds for autonomous issue filing (`/wrap` Phase 3, `/harness-audit` Step 7); strong/weak/none classification, exact-artifact dedup, and the comment-vs-file rule
- `harness-audit.md` — `/harness-audit` design record: two-pass split, the step-up chip that preserves the top-tier spawn invariant, the model-fleet resolver, dual watermarks, and the out-of-repo report default (#770)
- `graphql-thread-resolution.md` — full GraphQL queries/mutations for resolving PR review threads
- `exit-report-format.md` — full structured exit report block specification
- `greptile-setup.md` — Greptile dashboard setup notes
- `greptile-reply-format.md` — reply conventions for Greptile threads

### Workflow decomposition and PM helpers

- `phase-decomposition.md` — phase split reference material
- `pm-data-patterns.md` — PM skills data patterns and bot filters
- `pm-monitoring-decision.md` — `/pm` vs `/pr-monitor-and-manage` division of responsibility
- `continuous-work-posture.md` — why free capacity (not a finish) triggers refill, fill-vs-ramp, queue vs backlog refill, the human-in-chat stop, and the idle-reason taxonomy (`CLAUDE.md` "KEEP THE PIPELINE FULL"; #823)
- `pm-handoff-chips-decision.md` — decision record: `/pm-handoff` intentionally does not offer task chips; its portable prompt text is the deliverable (#562)
- `chip-model-guard-decision.md` — decision record: the chip model-guard preamble rides in both the chip `prompt` and the fallback block, redefining the fallback baseline (#601)
- `scheduling-failure-modes.md` — recurring poll failure analysis
- `bgwork-ceiling.md` — why background work arms a turn-independent silence ceiling, why `Monitor` over `ScheduleWakeup`/`CronCreate`, and why the number stays unpublished (#803)
- `skill-sync-hooks.md` — skills worktree sync and hook registration narrative
- `skill-symlink-setup.md` — why a dedicated worktree, session-start bootstrap, symlink install, and migration commands (`skill-symlinks.md`)
- `trust-dialog-repair.md` — why `~/.claude.json` re-prompts per worktree, the three flags, and repair-script behavior (`trust-dialog-fix.md`)
- `double-loading-fix.md` — decision record for suppressing the duplicate global CLAUDE.md + rules copy via project-local `claudeMdExcludes` (#461)
- `skill-authoring-patterns.md` — authoring *judgment* for skills/rules (description-as-trigger, match-form-to-failure, bulletproofing); complements CONTRIBUTING.md mechanics
- `verification-evidence-patterns.md` — claim→evidence checklist for AC, exit reports, and merge claims; complements phase protocols (#417 harvest from superpowers)

### Living trackers (updated each cycle — not point-in-time)

- `skill-repo-diff.md` — cross-repo pattern-harvest tracker (#417): gap analysis vs superpowers / everything-claude-code, prioritized import backlog, and import log; re-surveyed and appended each cycle

### Audits and research (point-in-time)

> **Exempt from corpus-wide rewrites (#791).** Every file in this section is a dated snapshot of what was true when it was written. Sweeping renames — the versionless model-name rename is the standing example — **must skip them**: rewriting a record to match today's vocabulary falsifies the history it exists to preserve. A versioned model name (`Opus 5`, `Haiku 4.5`) inside one of these files is correct by construction, not drift. The rename applies to the operative corpus — `CLAUDE.md`, `.claude/rules/`, `.claude/skills/`, `.claude/agents/` — plus the living contract docs in this directory that those files consume normatively (`chip-launching.md`, `chip-model-guard-decision.md`). Enforced by `.github/scripts/chip-model-guard-lint.sh`, whose scan is scoped to exactly that set.

- `ai-review-tool-audit-2026-04.md` — AI review tool chain audit (#368 / #377)
- `ai-review-tool-audit-2026-06.md` — 30-day AI review tool value audit + keep/cut verdicts (#376)
- `repo-audit-2026-05.md` — bundled org + efficiency + best-practices audit (#413–#415)
- `harness-model-audit-2026-06.md` — harness components vs current model fleet (#49)
- `script-extraction-audit.md` — deterministic script extraction inventory (#271)
- `graphite-stacked-prs-research-2026-05.md` — stacked PR economics (#418 / #433)
- `codeant-code-quality-eval-2026-06.md` — deeper CodeAnt Code Quality integration eval; verdict: keep advisory (#444)
- `instruction-set-audit-2026-07.md` — 1-month instruction-set size & optimization re-check; verdict: keep caps (#462)
- `token-efficiency-audit-2026-07.md` — token-efficiency playbook: adopt/skip/adapt verdicts, ranked cuts, shipped v1 (one-line heartbeats, delta PMM table, silence-detector dedupe) + FU-1…FU-7 (#773)
- `pm-routing-audit-2026-07.md` — thread-vs-inline routing effectiveness audit of #613; ground-truth attribution + the shared PM-context inline gate for chip surfaces (#701)
- `too-big-recalibration-2026-07.md` — re-derivation of the "too big for a subagent" fit bar against current capability: criterion 1 narrowed from size to non-resumability, A/B/C confirmed on grounds independent of the unverified 32K figure, ceiling held, and the chip-gate overflow defect fixed (#776)

### Diagrams (mermaid stubs and indexes)

- `diagrams/README.md` — index of diagram stub files
- `diagrams/skills-worktree-symlinks.md` — topology (stub)
- `diagrams/review-merge-pipeline.md` — review chain (stub)
- `diagrams/hook-lifecycle.md` — hook sequence (stub)

### Verification logs

- `issue-162-phase-protocol-verification.md` — static verification log for exit reports, phase B/C protocols, and monitor loop ordering (issue #162)
