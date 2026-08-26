# Chip / spawn_task Model + Effort Contract

> **Always:** Run or queue discovered subagent-fit follow-ups inline before considering a chip. Open every chip `prompt` payload with the `**Model:**` and `**Effort:**` lines, followed immediately by the MODEL GUARD preamble. Repeat both lines, and the pre-click Fable warning below, in the visible short summary.
> **Ask first:** Never — chip emission is autonomous.
> **Never:** Emit an ad-hoc `spawn_task` chip from a thread that can execute, or any chip without following `chip-launching.md`. Omit the `**Model:**` or `**Effort:**` line. Use a version number instead of a bare family name. Skip the MODEL GUARD preamble.

## Emission gate — may this chip exist?

**Default: no.** In a thread that can execute, a discovered subagent-fit follow-up is **filed as an issue, then queued or launched inline** through this thread's own subagent pipeline under the existing ceiling and repo-wide cap — cross-repo work included, since a subagent gets its own worktree and the cap is per-repo.

**Ad-hoc `spawn_task` chips are barred.** The legitimate cases are the ones `chip-launching.md` "PM-context inline gate" already enumerates — a named `/subagent` Step 4 criterion-1/2 verdict, an explicit user request for a hand-off or prompt, the capture-mode pre-acceptance offer — each routing through a canonical emitter below.

**Monitor mode never justifies a chip.** Spawning or queueing subagents for discovered work **is** orchestration — permitted and expected in dedicated monitor mode (`monitor-mode.md`; refill per `/pm` Step 3.4). "I can't do substantive work here" routes work inline, never to a chip.

**Wrong chip already on screen?** `dismiss_task` it, keep or file the issue, queue it inline — `chip-launching.md` "Wrong-chip recovery". No user prompt needed. Audit of every emission path: `.claude/reference/chip-emission-audit-2026-08.md`.

## Format contract

Any offer to start a new coding thread via `mcp__ccd_session__spawn_task` or a click-to-launch **task chip** — ad-hoc agent suggestions included — MUST follow `.claude/reference/chip-launching.md`:

1. **`**Model:** {MODEL} — {REASON}`** as the **first line** of the chip `prompt` payload (and of any fallback/printed block). `{MODEL}` is a bare family name — `Opus`, `Sonnet`, `Haiku`, `Fable` — never a version number.
2. **`**Effort:** {LEVEL} — {REASON}`** on the very next line. `{LEVEL}` is a picker label — **Low**, **Medium**, **High**, **Extra**, **Max** — never a bare API token.
3. **MODEL GUARD preamble** immediately after those lines — verbatim from `chip-launching.md`, no blank line between the three.
4. **Both lines** in the visible short summary.

The six canonical chip emitters are `/pm` (Step 3.1), `/prompt` (Step 6), `/start-issue` (Step 7), `/issue-maker` (Step 9c, on request only), `/wave` (Step 7.1), and `/harness-audit` (Step 5) — the last resolves its model name at run time (`chip-launching.md` "Literal vs resolved model names"). When the parent thread is on Fable and the chip recommends a different model, emitters MUST add the pre-click warning from `chip-launching.md` "Upstream requirement" in the short summary.
