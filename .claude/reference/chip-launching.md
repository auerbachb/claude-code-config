# Chip Launching — One-Click Coding Threads

Canonical mechanics for offering a coding-thread prompt as a **task chip** the user can click to spin off a new session. Shared by `/pm` (Step 3.1), `/prompt` (Step 6), and `/start-issue` (Step 7). Skill-specific wiring stays in each SKILL.md; everything below is defined once, here.

**Out of scope (explicit):** `/pm-handoff` does not offer chips and will not — its handoff prompt is a context-turnover artifact whose visible, portable text is the deliverable, and it has no issue number, model line, or lifecycle for these mechanics to key on. Decided in #562; rationale in `pm-handoff-chips-decision.md`.

**Model-guard placement:** the guard defined below rides in both the chip `prompt` and the fallback block — it is part of the baseline, not a chip-only addition. Decided in #601; rationale in `chip-model-guard-decision.md`.

> **NON-NEGOTIABLE — execution boundary.** Offering a chip is NOT launching a thread. Skills NEVER auto-launch: no Agent-tool spawn, no session start, no work begun on the user's behalf. **The user's chip click is the only launch path.** This does not widen any skill's existing explicit-ask exception (e.g. `/pm`'s "go ahead and run those") — it narrows nothing and grants nothing new.

## Availability detection

Chip mode is active **only** when the `mcp__ccd_session__spawn_task` tool is present in the session. Otherwise (CLI, headless, older client) the skill is in **fallback mode**.

**Any `spawn_task` failure is treated as "unavailable"** — emit that issue's full fallback block instead. Failures are per-emission: one issue's failed spawn does not force the rest of the batch into fallback, but every issue must end up with either a chip or a full block. Never leave an issue with neither. Degrade quietly and note the fallback once; do not retry the same spawn.

## `spawn_task` invocation shape

| Param | Value |
|-------|-------|
| `title` | ≤60 chars, **starts with a verb**, includes the issue number — e.g. `Fix #42 stale worktree warning` |
| `prompt` | The **complete self-contained thread prompt** — byte-identical to what fallback mode would print inside its fence |
| `tldr` | 1–2 plain-English sentences: what the spawned session will do and why. No file paths, no jargon |
| `cwd` | Repo root |

**Chips carry no model or effort preset.** The tool has no such parameter and cannot drive the picker. Therefore the recommended model **MUST** appear as a `**Model:** {MODEL} — {REASON}` line inside the `prompt` text itself, so the spawned session sees the recommendation, **and** in the visible short summary, so the user can set the picker before clicking. The `**Model:**` line is immediately followed by the model-guard preamble below — the two travel together as a unit.

## Model-guard preamble

The recommended model is worthless if nothing checks it at launch time. Every `prompt` payload — chip or fallback — MUST include this preamble immediately after the `**Model:** {MODEL} — {REASON}` line (no blank line in between, matching the existing fence-adjacent placement of the `**Model:**` line itself). Reproduce it **verbatim** — do not reword it per skill, the same way `safety.md`'s `SAFETY:`/`MINDSET:` blocks are copied into subagent prompts unchanged:

```text
MODEL GUARD: Your very first action — before any repo reads, file edits, or
other tool calls — is to compare the model you are actually running as
against the recommendation on the **Model:** line above.
- Match: state "Running on {MODEL} as recommended." (one line) and proceed
  immediately — no further prompts.
- Mismatch, in EITHER direction (under- or over-powered): STOP. Do no other
  work. Report, in one message, the model you are actually running as and the
  model recommended above, then wait. Resume only on an explicit user reply
  (e.g. "continue anyway"), proceeding on the current model — switching
  models and relaunching is the recommended path instead.
This is a best-effort self-report: no runtime API exists to introspect the
active model, so the check relies on the model naming itself accurately.
```

**Placement rule:** for every emitter, the `**Model:**` line is the first line of the `prompt` payload and this preamble is the content that immediately follows it — see each skill's Step for how its own template maps onto this shape.

**Why prompt-level, not tooling-level:** there is no `spawn_task` model/effort parameter and no runtime mechanism for a thread to introspect its own active model — model identity is always asserted by the caller, never read back. The guard is therefore a best-effort self-report, not a hard technical guarantee. Full trade-off: `chip-model-guard-decision.md`.

## Short-summary transcript format (chip mode)

In chip mode the transcript shows **only** the short summary per issue — the full prompt rides inside the chip:

```text
- **#42 — {Title}** — chip offered
  **Model:** {MODEL} — {REASON}
  {One-line rationale}
```

Nothing else. No prompt block, no context dump, no acceptance criteria. The whole point of chip mode is that the transcript stays scannable status output rather than a wall of prompt text.

## Chip state tracking

Record the `task_id` returned by each successful `spawn_task`, keyed by issue number, **immediately** — before any dependent step. Track it wherever the skill already tracks that issue's state (`/pm`'s Active Work table is the canonical home; `/prompt` writes there in a PM thread, and keeps session state otherwise). A chip whose `task_id` was not recorded cannot be dismissed — it is a live offer with no handle, so recording is not bookkeeping, it is the thing that makes withdrawal possible at all.

An issue with a live recorded chip is **already offered**: skip it when re-running, rather than spawning a second chip for the same work.

## Stale-chip hygiene — `dismiss_task`

Withdraw a tracked chip via `mcp__ccd_session__dismiss_task` (pass the recorded `task_id` and a short `reason`) on any of these three triggers:

1. **Gained an open PR** — someone is already doing the work.
2. **Superseded** — a later batch replaced the suggestion.
3. **Re-planned** — the issue's plan or scope changed, so the chip's prompt is stale. Spawn the replacement chip *first*, then dismiss the old one.

**Fail-closed:** only clear tracked chip state once the dismiss outcome is known. Distinguish the two non-error outcomes from a real failure:

- **Dismissed** — the chip is withdrawn. Clear the tracked state.
- **Already clicked or already dismissed** — the tool says so and nothing changes. The offer is gone either way, so the goal is met: treat it as a successful no-op, clear the state, and do not retry.
- **Genuine failure** — the chip is still live. Keep the `task_id` tracked; the chip is still withdrawable, and dropping the handle would strand it.

## Print-on-demand replay

In chip mode, "print the full prompt for #N" (or any equivalent ask) re-emits that issue's **complete block verbatim**, in the same fenced form fallback mode would have printed — including the model-guard preamble. The chip's prompt is the source of truth — the printed block and the chip must match. The chip stays offered; printing is not dismissing.

## Fallback mode

When chip mode is unavailable, output is **byte-identical to the chip `prompt`**: full fenced blocks, every existing fence and label contract preserved (`/prompt`'s mandatory `~~~` outer fence and first-line `**Model:**` label especially), model-guard preamble included. This redefines the pre-#601 baseline of "byte-for-byte identical to pre-chip behavior" — the guard is a universal addition, not a chip-only one, so fallback output gained it rather than the chip `prompt` and fallback block diverging. See `chip-model-guard-decision.md` for the full trade-off. Fallback remains the *baseline* representation, not a degraded variant — a CLI thread simply receives the same content a chip-mode session would.
