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
| `PHASE_COMPLETE` | `A`, `B`, `C` | Which phase just finished |
| `PR_NUMBER` | integer | The PR number |
| `HEAD_SHA` | string | HEAD SHA after last push (or current HEAD) |
| `REVIEWER` | `cr`, `greptile` | Which reviewer owns this PR |
| `OUTCOME` | see below | What happened |
| `FILES_CHANGED` | comma-separated paths | Files modified (empty string if none) |
| `NEXT_PHASE` | `B`, `C`, `none` | What parent should launch next |
| `HANDOFF_FILE` | path | Handoff file path |

## Valid OUTCOME Values

| Phase | Outcome | Meaning |
|-------|---------|---------|
| A | `pushed_fixes` | Findings fixed, code pushed |
| A | `no_findings` | Review already clean, code pushed as-is |
| A | `exhaustion` | Token budget low — partial fixes, replacement needed |
| B | `clean` | Review passed with no findings |
| B | `fixes_pushed` | Fixed findings, pushed — needs re-review |
| B | `merge_ready` | All checks green, merge gate satisfied |
| B | `exhaustion` | Token budget low — replacement needed |
| C | `ac_verified` | All AC verified and checked off |
| C | `blocked` | Merge blocked (CI failure, missing approvals, unchecked AC) |

## Rules

- Exit report MUST be the very last output before exiting.
- `EXIT_REPORT` header line is required — parent uses it to locate the block.
- One field per line, colon-separated, no extra whitespace.
- On token exhaustion: print the report (with `OUTCOME: exhaustion`) **before** hitting the hard limit.
