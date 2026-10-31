# Portable prompt export

> Load only for: explicit `--export-prompt` request
> Prerequisites: dispatcher selected export; do not create or edit an issue

## Required targeted source reads (export only)

This module specifies the export, but its literal template and handoff sources must also be available before emitting it. Resolve paths relative to this module's installed skill root, never the caller's cwd. Read only the `## Step 5: Canonical issue body` section through the template's closing fence in `modules/create/reflect-and-draft.md`, and the on-request fenced handoff block (from `**Model:**` through its closing fence, including `## Constraints`) in `modules/handoff.md`. Read `chip-launching.md` via the standard three-candidate reference order for the model-guard preamble, short-summary format, claim line, and merge-authority line. Insert those literal texts into the exported prompt; do not leave a citation or placeholder that requires an installed skill. These bounded source reads are export dependencies, not permission to enter capture mode or follow those modules' create/logging steps. If any required source is missing, stop with its path before emitting an incomplete portable prompt. Include the complete seven-section body template and literal final footer `_Captured via /issue-maker._`, plus the full on-request block with its model/effort lines and literal constraints. The handoff itself remains on explicit request in the portable session.

## Step 13: Portable-prompt emission (`--export-prompt`)

When invoked with `--export-prompt`, **do not create anything** — instead emit a standalone, paste-in prompt that codifies the same capture-mode behavior (reflection surfaced as a post-create decision-points report + LLM pass-through rationale, auto-open with no approval gate, functional-first tone, 7-section body, dedup, refusal of workflow-advancing actions until acceptance, **the always-on summary table**, closing-line URL rule). This lets the user carry the same discipline into a repo or thread where this skill isn't installed. Output the prompt in a fenced block and stop.

**The summary table ships in the export written out, not cited.** A portable session has no Step 9a to read, so the prompt must state the shape itself: every filing closes with a table whose columns are `#`, `Increment`, `Delivers`, `Model`, `Est` — one row for a single issue, one row per member for a batch or chain, printed once after the last member and always in addition to the closing URL line. Write out each derivation too: `#` is a clickable `[Issue #N](url)` link; `Increment` is `{i}/{n}` for a chain member and `—` otherwise; `Delivers` is one plain-English functional clause, kept to a single line with any `|` escaped as `\|` (a raw pipe or newline splits the row); `Model` is the **bare family name** for that issue's inferred tier (`Opus` for Heavy or Standard, `Sonnet` for Light) and never a version number or API token; `Est` is the `plan on` bound from the body's `## Estimate` line rendered at 30-minute granularity — `30min` under an hour, `{h}h` on the hour, `{h}h30` on the half hour, rounding a non-multiple up — read without rewriting the body's `Est:` line. State the chain total row as well, with its scope: **chains only** — a final row summing every increment's bound, rendered by the same rule, labeled `**Chain total**` in `Delivers`, with `#`, `Increment`, and `Model` left blank — and say that a batch of unrelated issues gets no total row. State that the table is always on and that rapid-fire trims the decision points, never the table.

**Both sizing triggers ship in the export.** Include deliverable fit and an independent strict `planning_bound > SPLIT_OVER_MIN` time trigger, with configurable coherent `SPLIT_OVER_MIN`/`INCREMENT_BOUND_MIN` from `split-thresholds.sh` when available and an explicit degraded 180/120 fallback otherwise. A natural seam selects independently mergeable increments bounded by the increment limit; no seam keeps one long issue and reports that scope call. Exact-threshold work does not trip the time trigger.

**The sizing check ships in the export with its bar written out, not cited.** Everywhere else in this skill the bar is a citation to `/subagent` Step 4 criterion 3, because that criterion travels with the installed skill. The export is for a thread that has *no* `/subagent` to read, so a citation there would dangle — state the bar in the prompt itself (one Phase A/B/C pipeline, one reviewable PR, one review cycle, a bounded slice), along with the increment-chain shape it triggers: ordered increments, a boundary line on each ("this increment ends at…", and the final one's terminal variant naming nothing deferred past it), `- Depends on #prev` links, a 5-increment cap that stops before filing, and one offer covering the whole chain in order.

**The session's default ending is an inline-run offer.** The exported prompt states: after the last issue is filed, offer to run all open issues inline only when `/subagent` is available; launch only on explicit yes. If `/subagent` is unavailable, say that this thread cannot execute the batch and leave the issues filed, then offer a copyable handoff prompt on explicit request (or a chip only if the harness exposes its spawn tool). Declining any available offer leaves issues filed with nothing launched. Never make an unavailable execution path sound actionable or launch a handoff silently.

**The exported prompt reproduces the on-request hand-off block verbatim** — one per session — with the `**Model:**` line, `**Effort:**` line, model-guard preamble, and the Constraints block including its merge-authority bullet (`chip-launching.md` "Merge-authority line"). A portable prompt that drops the merge-authority line recreates exactly the gap this exists to close: a thread that reaches merge-readiness in a repo without these rules installed, finds nothing asserting the default, and stops to ask. Never paraphrase the bullet and never soften it into an approval request.

---

## Modes summary

Both modes **auto-open** the issue — no draft reprint, no approval gate — and both auto-apply validated labels. **Both also run the full reflection pass — narrow, expand, split, sizing, ambiguity.** In either mode an oversized ask becomes an increment chain automatically **when it fits in 5 increments or fewer**; above that both modes stop and ask before filing anything (Step 8's cap), and both cover the whole chain with the session's single hand-off (Step 9c). What distinguishes them is the **report** and the **two bars**:

| Mode | Upfront questions | Create | Post-create report | Labels | Dedup pause | Chain cap (Step 8) |
|------|-------------------|--------|--------------------|--------|-------------|--------------------|
| **default** | none (blocking ask only on a genuinely undecidable call) | auto-open | summary + decision points + summary table (Step 9a) | auto-apply validated | strong **or** exact match | asks above 5 |
| **rapid-fire** | none on scope or ambiguity — only its two hard bars (dedup, chain cap) | auto-open | terser — summary table, closing URL, optional one-liner | auto-apply validated | exact title match only | asks above 5, tersely |

Mode is stored in `.mode` in the session log and persists across compaction — both on first invocation (seeded from `/issue-maker rapid-fire`, Step 1) and on an explicit switch. A switch is a log write, not just an in-memory note, so compaction recovery reads the right mode:

```bash
set_log '.mode = $v' --arg v rapid-fire   # or: --arg v default
```

Switch with `"switch to rapid-fire mode"` / `"switch to default mode"`. Neither mode ever suspends the closing-line URL rule or the 7-section body shape.

---
