# Structured Exit Report Format

Referenced from `.claude/rules/phase-protocols.md`. Every subagent MUST print this block as its final output before exiting.

## Format

```text
EXIT_REPORT
PHASE_COMPLETE: A
PR_NUMBER: 618
HEAD_SHA: abc1234
REVIEWER: cr
OUTCOME: pushed_fixes
FILES_CHANGED: src/foo.ts, src/bar.ts
NEXT_PHASE: B
HANDOFF_FILE: ~/.claude/handoffs/pr-618-handoff.json
```

## Field Reference

| Field | Values | Description |
|-------|--------|-------------|
| `PHASE_COMPLETE` | `A`, `B`, `C`, or non-phase agent name (e.g. `pm-worker`) | Which phase or agent just finished. `researcher` uses a distinct reduced schema with an `AGENT:` field instead; it has no `PHASE_COMPLETE` field. |
| `PR_NUMBER` | integer, or `none` for non-phase agents | The PR number |
| `HEAD_SHA` | string, or `none` for non-phase agents | HEAD SHA after last push (or current HEAD) |
| `REVIEWER` | `cr`, `bugbot`, `greptile`, or `none` for non-phase agents | Which reviewer owns this PR |
| `OUTCOME` | see below | What happened |
| `FILES_CHANGED` | comma-separated paths | Files modified (empty string if none) |
| `NEXT_PHASE` | `B`, `C`, `none` | What parent should launch next |
| `HANDOFF_FILE` | path | Handoff file path |
| `FIXPR_WAIT_ITERATIONS` | integer | (when the phase ran `/fixpr`) wait-loop iterations executed — issue #454 |
| `FIXPR_TOTAL_WAIT_SECS` | integer | (when the phase ran `/fixpr`) cumulative post-push review-wait time |
| `FIXPR_WAIT_FINAL` | `clean`, `cap-exhausted`, `new-findings-pending` | (when the phase ran `/fixpr`) final wait-loop state from `FIXPR_WAIT_SUMMARY` |

The three `FIXPR_*` fields are required whenever the phase executed the `/fixpr` workflow (copy them from its `FIXPR_WAIT_SUMMARY` footer line); omit them otherwise.

## Valid OUTCOME Values

| Phase | Outcome | Meaning |
|-------|---------|---------|
| A | `pushed_fixes` | Findings fixed, code pushed |
| A | `no_findings` | Review already clean, code pushed as-is |
| A | `exhaustion` | Token budget low — partial fixes, replacement needed |
| A | `blocked` | Unresolvable merge conflict or other fix blocker — needs human judgment (freeform reason above the report) |
| B | `clean` | Review passed with no findings |
| B | `fixes_pushed` | Fixed findings, pushed — needs re-review |
| B | `merge_ready` | All checks green, merge gate satisfied |
| B | `exhaustion` | Token budget low — replacement needed |
| C | `merged` | All AC verified and checked off; `/wrap` completed the squash merge and follow-up flow |
| C | `blocked` | Merge blocked (CI failure, missing approvals, unchecked AC) |
| `pm-worker` | `completed` | Task finished — specific result (issue number, deferral target, etc.) is in the prose body above the report |
| `pm-worker` | `blocked` | Could not complete autonomously — reason above (e.g. branch protection change requires user confirmation) |
| `pm-worker` | `exhaustion` | Token budget low — partial work applied, replacement needed |
| `researcher` | `findings` | Investigation complete — evidence and findings are in the body above |
| `researcher` | `inconclusive` | Investigated but could not reach a confident answer — gaps noted above |
| `researcher` | `blocked` | Could not investigate — reason above (e.g. required file unreadable, GitHub API error, out of scope for read-only access) |

## Non-Phase Agent Handling

`pm-worker` and `researcher` emit an exit report for consistency with the Phase A/B/C orchestration model. However, the parent has **no `OUTCOME` branch protocol** for these agents (the A/B/C completion protocols in `phase-protocols.md` do not apply to them) — the parent reads the prose result directly and acts on it. The OUTCOME field on non-phase exit reports is informational, not a branch key.

`researcher` uses a distinct reduced schema: no `PHASE_COMPLETE` field; `AGENT: researcher` carries agent identity. See `.claude/agents/researcher.md` for the full reduced-schema template.

## Rules

- Exit report MUST be the very last output before exiting.
- `EXIT_REPORT` header line is required — parent uses it to locate the block.
- One field per line, colon-separated, no extra whitespace.
- On token exhaustion: print the report (with `OUTCOME: exhaustion`) **before** hitting the hard limit.
