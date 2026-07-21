---
name: wave
description: Use when starting several backlog issues at once and needing to know which can safely run in parallel — "wave", "next wave", "what can I run in parallel". Returns a dependency- and overlap-filtered independent set, capped at the pipeline ceiling, offered as click-to-launch chips. Never launches anything.
triggers:
  - wave
  - next wave
  - what can I run in parallel
  - parallel batch
  - batch of issues
argument-hint: "[N] (optional — request at most N issues in the wave; never raises the ceiling)"
---

Answer one question: **what is the largest set of backlog issues I can start right now without them stepping on each other?**

`/wave` ranks nothing itself, launches nothing itself, and writes no code. It selects, caps, and offers.

> **NON-NEGOTIABLE — `/wave` never auto-launches.** Every issue in the wave is *offered* as a chip (or a printed prompt block in fallback mode). **The user's click is the only launch path.** `/wave` does not spawn Agent-tool subagents, does not invoke `/subagent`, and does not treat its own selection as go-ahead. Selecting an issue for the wave is the recommendation; it is not permission. See "Execution boundary" at the end of this file.

---

## Step 0: Parse arguments

`$ARGUMENTS` is either empty or a single count.

- **Empty** → `REQUESTED=unset` (the cap alone decides the size).
- **A positive integer `N`** (with or without a leading `#`-free form, e.g. `/wave 2`) → `REQUESTED=N`. This can only make the wave **smaller** — it never raises the ceiling computed in Step 6.
- **Anything else** (zero, negative, non-numeric, multiple tokens) → print one line: "`/wave` takes an optional positive count, e.g. `/wave 3`." and stop.

---

## Step 1: Get the ranked backlog — delegate, never re-rank

Ranking is `/pm`'s job. `/wave` consumes a ranking; it does not produce one.

**1.1 — Reuse a live ranking when the thread already has one.** Scan the conversation from the most recent `/pm` invocation forward for `## Suggested Next Issues`, a tiered ranking (`## Critical` / `## High` / …), or an `## Active Work` table. If any is present, that ranking **is** the input — take its order verbatim.

**1.2 — Otherwise cold-start `/pm`.** No PM context in the thread (running `/wave` first thing in a fresh session is normal): invoke `/pm` via the Skill tool with no business goal, let it produce its ranking and Active Work state, then continue at Step 2 with that output. Say so in one line — "No ranking in this thread; ran `/pm` to rank the backlog first." — so the extra output is not a surprise.

**1.3 — If `/pm` yields no rankable candidates** (empty backlog, everything in flight), report that in one line and stop. There is no wave to offer.

> **Prohibition.** Do not re-score, re-tier, or re-order `/pm`'s output. Do not apply your own priority heuristics on top of it. `/wave` may only *remove* issues from that order (Steps 2, 5, 6) — never promote one, never reorder. If the ranking looks wrong, say so and let the user re-run `/pm`; do not silently fix it.

---

## Step 2: Build the candidate pool

Start from the ranked order and remove, in this sequence:

1. **Already offered or already running.** Drop any issue whose row in `/pm`'s `## Active Work` table has Thread status `Chip offered`, `Inline`, `Active`, or `Prompt generated`. The first three are the acceptance criterion; `Prompt generated` joins them because `/pm` 3.2 defines it and `Chip offered` as the same state — offered, not yet started — and `chip-launching.md` treats an issue with a live offer as already offered. Re-running `/wave` immediately must therefore produce **no** duplicate chips.
2. **Already in flight on GitHub.** Drop any issue referenced by a closing keyword (`close`/`closes`/`closed`, `fix`/`fixes`/`fixed`, `resolve`/`resolves`/`resolved`, case-insensitive) in an open PR body — local (`#N`) and cross-repo (`owner/repo#N`) forms both. Reuse the open-PR data `/pm` already fetched; do not re-query.
3. **Explicitly blocked labels.** Drop `blocked`, `on-hold`, `wontfix`, `duplicate` (`/pm` 1B.4 already excludes these — this is a cheap re-check, not a re-ranking).

Every issue removed here is **silent** — it is not a wave exclusion and does not appear in the excluded list (Step 9). The excluded list is for issues that were genuine candidates and lost on independence or cap.

Record `IN_FLIGHT` = the count of rows dropped by (1) and (2) — Step 6 subtracts it. Offered-but-unstarted issues count toward it deliberately: a chip the user clicks a minute from now consumes the same reviewer budget as one already running, and the point of the cap is to avoid discovering that after the fact.

---

## Step 3: Extract each candidate's file footprint

For every candidate, produce a footprint (a set of paths) using the **first** source that yields anything:

1. **CR implementation plan file list** — parse the issue's comments exactly as `/prompt` Step 2 does: headings containing "Files", "Files likely touched", "File list", or "Touched files" (case-insensitive), then the following bullet/numbered list or fenced block, plus inline backticked paths.
2. **`## Related Files` section** of the issue body — one path per bullet.
3. **Backticked paths anywhere in the body or acceptance criteria** — strings containing `/` or ending in a known extension (`.md`, `.sh`, `.py`, `.json`, `.yml`, `.yaml`, `.ts`), excluding anything starting with `http://` or `https://`.
4. **Subject inference** — the issue names a component without a path (e.g. "the `/pm` skill", "the merge gate rule", "the polling script"). Map it to the obvious file(s). Mark the footprint `inferred`.
5. **Nothing at all** → footprint is `undeclared`. Step 5 has a specific rule for these; do not guess a footprint for them.

Normalize before comparing: trim, strip leading `./`, drop trailing slashes, deduplicate.

---

## Step 4: Map paths to collision surfaces

Two issues collide when they touch the same **surface**, which is usually the same file — but not always. Expand each footprint path into surfaces:

| Path | Surface |
|------|---------|
| `CLAUDE.md`, `.claude/rules/*.md`, `.claude/rules/.budget-soft-cap` | **`rule-corpus`** — one shared surface for all of them |
| `global-settings.json` | `global-settings` |
| `.claude/settings.json` | `project-settings` |
| Anything else | the exact normalized path |

**Why the rule corpus is one surface:** `rule-lint.sh` fails when the corpus exceeds the committed ratchet cap in `.claude/rules/.budget-soft-cap`, so two branches that each add words to *different* rule files still collide — the second to merge inherits a cap the first already consumed. Same mechanical collision for shared settings files, where two branches append different keys to one JSON object.

**Repo-declared surfaces.** If `.claude/pm-config.md` has a `## Dependency Rules` section, read it (`.claude/scripts/pm-config-get.sh --section "Dependency Rules"`) and honor any coupling it declares — e.g. "changes to X require regenerating Y" makes X and Y one surface. A repo that knows its own coupling outranks this table.

**What is NOT a surface:** a shared *directory*. Two different skills under `.claude/skills/`, two different scripts under `.claude/scripts/`, two different hooks — these are independent. Directory-level matching would exclude nearly every pair in a config repo and collapse every wave to one issue. Match on files and the named coarse surfaces above; nothing wider.

---

## Step 5: Select the independent set (conservative)

Walk the candidates in `/pm`'s ranked order and admit each one only if it survives every check against the already-admitted set. **When a check is ambiguous, exclude.**

**5.1 — Dependency edges (hard).** Using the markers `/pm` 1B.3 already collected — `blocked by #N`, `depends on #N`, `after #N`, `prerequisite for #N`, and the inverse forms `unblocks`/`enables`/`required by`/`before` — exclude a candidate when:

- it is blocked by another issue **in this wave** → the blocker keeps its slot, the blocked issue is excluded ("blocked by #N, which is in this wave"); or
- it is blocked by any **open, unmerged** issue at all → excluded ("blocked by #N, still open"). A wave is for work that can start *now*.

**Circular pairs** (A blocks B, B blocks A) → exclude **both** and flag them for human resolution, matching `/pm` 1B.4's treatment. Do not guess which direction is real.

**5.2 — Declared overlap (hard).** Any surface shared with an already-admitted issue → exclude, naming the surface: "overlaps #M on `.claude/skills/pm/SKILL.md`".

**5.3 — Inferred overlap (conservative).** Exclude when the two issues plainly work on the same thing even though only one declared a path — same skill, same rule file, same script, same hook, same workflow file. An issue whose footprint is `inferred` (Step 3 source 4) is compared on exactly the same terms as a declared one; a guess in favor of collision is the correct guess here.

**5.4 — Undeclared footprints: at most one per wave.** With zero footprint information you cannot establish that two such issues are independent, so:

- the **first** `undeclared` candidate in rank order may be admitted;
- every later `undeclared` candidate is excluded — "footprint undeclared; can't rule out overlap with #N";
- an `undeclared` candidate is not assumed to collide with *declared* candidates unless 5.3's subject match fires.

This keeps under-specified issues eligible (they are often the top of the backlog) without ever admitting two blind ones together.

**5.5 — Tie-breaking is rank, always.** When two candidates overlap, the higher-ranked one keeps the slot and the lower-ranked one is excluded. Never swap in a lower-ranked issue because it "fits better" — that is re-ranking, which Step 1 forbids.

Record the exclusion reason for every candidate that fails a check — Step 9 prints them.

---

## Step 6: Cap the wave

```
CEILING    = 4                        # top of the 3–4 concurrent-pipeline band
CONFIG     = MAX_WAVE from pm-config  # optional; clamped to [1, CEILING]
EFFECTIVE  = min(CEILING, CONFIG?)    # total concurrent work allowed
SLOTS      = min(REQUESTED?, EFFECTIVE - IN_FLIGHT)
```

`REQUESTED` caps *new* chips; `EFFECTIVE - IN_FLIGHT` caps *total* concurrent work. Applying them separately means `/wave 2` with one issue already in flight still offers 2 (total 3, under the ceiling) rather than being penalized twice.

- **`CEILING = 4`** comes from `.claude/rules/subagent-orchestration.md` ("Keep 3-4 active CR-polled PRs max"). It binds chip-launched threads too: the scarce resource is **reviewer throughput** — roughly 8 CodeRabbit reviews/hour shared across every open PR (`.claude/reference/cr-rate-limits.md`) — not subagent slots. Four threads started at once become four PRs competing for that same hourly budget.
- **`CONFIG`** is an optional `MAX_WAVE=N` line in a `## Wave` section of `.claude/pm-config.md`:

  ```bash
  .claude/scripts/pm-config-get.sh --section Wave 2>/dev/null | sed -n 's/^ *MAX_WAVE *= *\([0-9][0-9]*\).*/\1/p' | head -1
  ```

  Absent, unparseable, or out of range → ignore it and use `CEILING`. A config value **may lower the cap and may never raise it** past the auto-loaded rule; clamp rather than error. Changing the ceiling itself means editing `subagent-orchestration.md`, which is a reviewed rule change. (`## Wave` is a non-canonical section, so `/pm-update` preserves it verbatim.)
- **`IN_FLIGHT`** is the count from Step 2 — issues already offered or already running consume the same reviewer budget.

If `SLOTS <= 0`, print one line naming what is already in flight ("4 issues already in flight — the pipeline is full; merge or park one before starting more.") and stop. Do not offer a single chip.

Take the first `SLOTS` issues from the independent set. Anything past that is excluded with reason "cap reached ({SLOTS} slot(s); {IN_FLIGHT} already in flight)".

---

## Step 7: Offer the wave as chips

Follow `.claude/reference/chip-launching.md` **verbatim** — availability detection, `spawn_task` shape, model-guard preamble, short-summary format, per-issue fallback on spawn failure. Nothing in this section overrides it.

For each issue in the final wave:

- **`prompt`** — the full self-contained thread prompt from `/pm` Step 3.1's template (`**Model:**` line first, model-guard preamble immediately after with no blank line between, then the task / issue body / codebase context / workflow / constraints sections). Reuse that template as written; `/wave` does not define a prompt format of its own.
- **`title`** — ≤60 chars, starts with a verb, includes the issue number.
- **`tldr`** — 1–2 plain sentences, no paths, no jargon.
- **`cwd`** — repo root.
- **Model line** (`**Model:** {MODEL} — {REASON}`) — take the recommendation from `/prompt`'s tier classification if it ran in this thread; otherwise infer it from the issue's signals with the same Heavy/Standard/Light mapping (`/prompt` Steps 4–5). The line appears **both** inside the chip prompt and in the visible summary, because chips cannot preset the model picker.

Print only the short summary per issue. A failed `spawn_task` falls back to a printed block **for that issue alone**; the rest of the wave keeps its chips. Every issue in the wave ends with exactly one of: a chip, or a printed block — never both, never neither.

---

## Step 8: Record every `task_id`

Immediately after each successful spawn — before printing anything else — write the returned `task_id` into `/pm`'s `## Active Work` table with Thread `Chip offered`, Status `Awaiting thread start`. That table is the canonical home for chip state (`chip-launching.md`, `/pm` 3.2); `/wave` writes to it rather than keeping a parallel ledger.

Outside a PM thread (Step 1.2 cold-started `/pm`, so the table exists either way), the same rule holds. If for any reason no table is present, create one in `/pm` 3.2's exact format.

An unrecorded chip cannot be dismissed later — recording is what makes withdrawal possible at all, not bookkeeping.

---

## Step 9: Print the wave

```
## Wave — {K} issue(s) ready to run in parallel

- **#42 — {Title}** — chip offered
  **Model:** Opus 4.8 — {reason}
  {one-line rationale, carried from /pm's ranking}

- **#55 — {Title}** — chip offered
  **Model:** Sonnet 5 — {reason}
  {one-line rationale}

Click a chip to start that thread. To run these inline in this thread instead, say `/subagent #42 #55`.

### Excluded from this wave
- **#61** — overlaps #42 on `.claude/skills/pm/SKILL.md`
- **#38** — blocked by #42, which is in this wave
- **#70** — footprint undeclared; can't rule out overlap with #55
- **#71** — cap reached (2 slots; 2 already in flight)
```

Rules for this block:

- **Every candidate that reached Step 5 appears exactly once** — in the wave or in the excluded list. Issues dropped in Step 2 (already offered, already in flight, blocked-labelled) appear in neither; they were never candidates.
- **One line, one reason** per exclusion. The reason names the *specific* blocker or surface — "overlaps #M" without saying on what is not a reason. Never emit a bare "excluded".
- Omit the `### Excluded from this wave` heading entirely when nothing was excluded.
- Flag circular dependency pairs on their own line: "**#80 / #81** — circular dependency; needs human resolution."
- No methodology narration. The wave and the reasons are the output; the ladder that produced them is not.

---

## Step 10: Fallback mode (no `spawn_task`)

When chip mode is unavailable (CLI, headless, older client), the wave is delivered as printed prompt blocks — content byte-identical to what the chips would have carried, model-guard preamble included, per `chip-launching.md` "Fallback mode".

- Print the full block for each wave issue instead of the short summary.
- The Excluded section is unchanged.
- **Do not mention chips, clicking, or `task_id`s** — none of that exists in this mode. Replace the launch line with: "Paste a block into a new thread to start it."
- Track offered issues in this thread's state so a re-run still skips them (Step 2 case 1 reads `Prompt generated` for exactly this).

---

## Execution boundary (CRITICAL)

`/wave` **offers**. It never starts work.

| Rationalization | Reality |
|---|---|
| "The user asked for a wave, so they clearly want these running." | They asked for the *set*. Which ones actually run is the click. |
| "These are all small — running them inline is what `/pm` would do." | `/pm`'s inline default is `/pm`'s. `/wave`'s whole contract is that launch is elective; running them inline deletes the choice this skill exists to give. |
| "I'll just start the top one to save a round-trip." | One auto-launch is the whole violation. There is no partial version of this rule. |
| "Fallback mode has no chips, so I'll spawn subagents instead." | Fallback prints blocks. Absent chips means fewer delivery options, not a different execution boundary. |
| "The user said 'go' after seeing the wave." | An explicit user instruction to run specific issues is honored by `/subagent` — invoke that, and only for the issues they named. `/wave` still never launches on its own. |

**STOP if you catch yourself** reaching for the Agent tool, invoking `/subagent` unprompted, marking a wave issue `Inline`, or describing a wave issue as "started". None of those belong to this skill.

---

## Edge cases

- **No PM context and `/pm` finds nothing rankable** — one line, stop (Step 1.3).
- **Every candidate overlaps the top one** — a wave of 1 is a valid, correct answer. Emit it with the full excluded list; do not pad the wave by relaxing Step 5.
- **`SLOTS <= 0`** — no chips at all; name the in-flight work (Step 6).
- **`/wave N` larger than the ceiling** — silently clamped to the ceiling; note it in one line ("requested 8, capped at 4").
- **Ranking exists but every issue was already offered** — "Everything currently ranked is already offered or in flight." No chips, no excluded list.
- **Spawn fails mid-wave** — printed block for that issue only; the rest keep their chips (`chip-launching.md`). Do not retry.
- **User asks to print the full prompt for a wave issue** — re-emit that issue's complete block verbatim, guard included. The chip stays offered.
- **An offered wave issue later gains a PR** — stale-chip hygiene belongs to `/pm` 3.3, which already dismisses chips for issues that gained a PR. `/wave` does not run its own dismissal pass.

---

## Usage

```
/wave        # as many independent issues as the cap allows
/wave 2      # at most 2
```
