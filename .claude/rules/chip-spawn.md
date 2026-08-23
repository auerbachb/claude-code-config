# Chip / spawn_task Model + Effort Contract

> **Always:** Open every chip `prompt` payload with the `**Model:**` and `**Effort:**` lines, followed immediately by the MODEL GUARD preamble. Repeat both lines in the visible short summary. Add the pre-click Fable warning when the parent thread is on Fable.
> **Ask first:** Never — chip emission is autonomous.
> **Never:** Omit the `**Model:**` or `**Effort:**` line. Use a version number instead of a bare family name. Skip the MODEL GUARD preamble. Emit a chip from the six canonical emitters without following `chip-launching.md`.

Any offer to start a new coding thread via `mcp__ccd_session__spawn_task` or a click-to-launch **task chip** — including ad-hoc agent suggestions outside the six canonical emitters — MUST follow `.claude/reference/chip-launching.md`:

1. **`**Model:** {MODEL} — {REASON}`** as the **first line** of the chip `prompt` payload (and of any fallback/printed block). `{MODEL}` is a bare family name — `Opus`, `Sonnet`, `Haiku`, `Fable` — never a version number.
2. **`**Effort:** {LEVEL} — {REASON}`** on the very next line. `{LEVEL}` is a picker label — **Low**, **Medium**, **High**, **Extra**, **Max** — never a bare API token.
3. **MODEL GUARD preamble** immediately after those lines — verbatim from `chip-launching.md`, no blank line between the three.
4. **Both lines** in the visible short summary so the user can set the picker before clicking. The picker has two controls; naming one is half a recommendation.

The six canonical chip emitters are `/pm` (Step 3.1), `/prompt` (Step 6), `/start-issue` (Step 7), `/issue-maker` (Step 9c, on-request hand-off only — its default session ending is an inline-run offer, not a chip), `/wave` (Step 7.1), and `/harness-audit` (Step 5) — the last resolves its model name at run time rather than writing one (`chip-launching.md` "Literal vs resolved model names"). When the parent thread is on Fable and the chip recommends a different model, emitters MUST add the pre-click warning from `chip-launching.md` "Upstream requirement" in the short summary.
