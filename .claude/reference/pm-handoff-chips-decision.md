# `/pm-handoff` Chips Decision (#562, follow-up from #548 / PR #555)

## Decision

**`/pm-handoff` does not offer task chips, and will not.** Its output stays what it is today: the complete handoff prompt printed to stdout, optionally copied to the clipboard via the `copy` argument. No `spawn_task` / `dismiss_task` wiring, no chip-mode branch, no availability detection.

PR #555 wired chips into `/pm` (Step 3.1) and `/prompt` (Step 6). Issue #548 deferred `/pm-handoff` by explicit scope decision rather than on the merits; this record settles it on the merits so it stays decided.

## Rationale

**Chip mechanics are keyed to an issue; a handoff has no issue.** Every mechanic in `chip-launching.md` assumes a per-issue coding thread:

- `title` must include the issue number.
- `prompt` must carry a `**Model:** {MODEL} — {REASON}` line, because chips cannot drive the model picker. A handoff prompt has no model recommendation to carry.
- Chip state is tracked *keyed by issue number*, and the "already offered — skip it on re-run" dedupe is per-issue.
- All three `dismiss_task` triggers — gained an open PR, superseded by a later batch, re-planned scope — are issue-lifecycle events.

A handoff prompt has no issue number, no model recommendation, and no lifecycle those triggers can observe. Supporting this would mean **inventing non-issue chip semantics**, which #562's own scope explicitly rules out ("no new chip semantics"). The port is not mechanical; it is a redesign of the chip contract.

**The portable text is the deliverable, not friction.** `/pm-handoff` exists for context-window turnover: it emits a self-contained prompt the user pastes into a deliberately fresh PM thread. The skill's own docs target "a new Claude Code session (**web or CLI**)", and it ships a `copy` argument that pipes the prompt to `pbcopy`. Both are the design conceding that getting the visible, portable full text into the user's hands *is* the point. Chips are client-local: one cannot cross to the web app, to another machine, or into a later moment the user chooses. Wrapping the handoff in a chip would hide exactly the text the user invoked the skill to obtain.

**The strongest "yes" argument, and why it loses.** `spawn_task` genuinely does start a fresh session seeded with a given prompt — which is, narrowly, what turnover wants. But that case holds only for "turnover, in this same client, right now." It still hides the artifact, still cannot reach the web app or a second machine, and still requires the non-issue semantics above. It trades the skill's whole purpose for one keystroke in its narrowest use case.

**Context, not work:** chip `task_id` state is conversation-memory-only and is not captured by any file `/pm-handoff` reads (`session-state.json`, `~/.claude/handoffs/pr-*-handoff.json`, `MEMORY.md`). So no chip-continuity requirement pulls toward "yes" either — there is nothing about live chips a handoff is currently failing to carry across.

## Explicitly Rejected (considered and declined)

- **Mechanical port per `chip-launching.md`** (availability detection, `spawn_task` with `title`/`prompt`/`tldr`/`cwd`, short-summary transcript, `task_id` tracking, `dismiss_task` hygiene, byte-identical fallback, print-on-demand replay) — rejected: chip semantics are per-issue coding-thread launches, so a handoff fits none of the required fields or dismiss triggers, and wrapping the prompt hides the portable text that is the artifact's whole purpose.
- **A handoff-specific chip variant** (chips without issue numbers, model lines, or lifecycle-based dismissal) — rejected: that is new chip semantics, explicitly out of scope for #562, and it would fork the single-source contract that PR #555 deliberately centralized.

## References

- Issue [#548](https://github.com/auerbachb/claude-code-config/issues/548) — original chip work; deferred `/pm-handoff` by scope decision
- PR [#555](https://github.com/auerbachb/claude-code-config/pull/555) — wired chips into `/pm` and `/prompt`
- Issue [#562](https://github.com/auerbachb/claude-code-config/issues/562) — this decision
- `chip-launching.md` — canonical chip mechanics (the contract this decision declines to extend)
- `.claude/skills/pm-handoff/SKILL.md` — the skill whose behavior is intentionally unchanged
