# Chip / spawn_task Model Contract

Any offer to start a new coding thread via `mcp__ccd_session__spawn_task` or a click-to-launch **task chip** — including ad-hoc agent suggestions outside the five canonical skills — MUST follow `.claude/reference/chip-launching.md`:

1. **`**Model:** {MODEL} — {REASON}`** as the **first line** of the chip `prompt` payload (and of any fallback/printed block).
2. **MODEL GUARD preamble** immediately after that line — verbatim from `chip-launching.md`, no blank line between.
3. **Same `**Model:**` line** in the visible short summary so the user can set the picker before clicking.

The five canonical chip emitters are `/pm` (Step 3.1), `/prompt` (Step 6), `/start-issue` (Step 7), `/issue-maker` (Step 9c), and `/wave` (Step 7.1). Until `spawn_task` gains a `model` parameter (Issue #735), the guard is the only enforcement at launch time — see `chip-model-guard-decision.md`.
