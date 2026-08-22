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

> **NON-NEGOTIABLE — `/wave` never auto-launches.** Every issue in the wave reaches exactly one of three visible outcomes: *offered* as a chip (or a printed prompt block in fallback mode); *recommended* for inline execution via `/subagent` in a live PM thread (Step 7.0); or explicitly reported as **queued inline / deferred** when the ceiling is full (Step 6). Never a fourth — no issue is silently dropped. **The user's action (a chip click, or running `/subagent`) is the only launch path.** `/wave` never spawns Agent-tool subagents and never invokes `/subagent` itself, and does not treat its own selection as go-ahead. Selecting an issue for the wave is the recommendation; it is not permission. See "Execution boundary" at the end of this file.

---

## Step 0: Resolve shared tooling

`/wave` is symlinked into every repo, but its helper scripts and reference docs are not — most repos carry no `.claude/` directory. Resolve them; never invoke a bare `.claude/scripts/…` path. Full contract and the classified dependency inventory: `.claude/reference/portable-skill-resolution.md` (issue #1189).

```bash
resolve_script() {
  local name="$1" candidate
  for candidate in \
    "$HOME/.claude/skills-worktree/.claude/scripts/$name" \
    "$HOME/.claude/scripts/$name" \
    ".claude/scripts/$name"; do
    if [[ -x "$candidate" ]]; then echo "$candidate"; return 0; fi
  done
  return 1
}
ISSUE_CLAIM=$(resolve_script issue-claim.sh || true)
PM_CONFIG_GET=$(resolve_script pm-config-get.sh || true)
ACTIVE_WORK_CAP_SH=$(resolve_script active-work-cap.sh || true)
```

Read `chip-launching.md` the same way — `$HOME/.claude/skills-worktree/.claude/reference/chip-launching.md` first, then `$HOME/.claude/reference/`, then `.claude/reference/` — and `cr-rate-limits.md` likewise.

**When something does not resolve, say so in one line; never skip the contract silently.**

- `chip-launching.md` unreadable → **required**. Print `ERROR: chip-launching.md not found (checked all three paths) — PM-context inline gate unavailable`, and stop before offering any chip. A `/wave` that cannot read its own routing gate is exactly the run that fans out one thread per issue (#1189); refusing is the safe failure.
- `ISSUE_CLAIM` empty → **optional**. Print `DEGRADED: issue-claim.sh not found (checked all three paths) — claim filter skipped, in-flight detection is PR-only` and continue with Step 2's other filters.
- `PM_CONFIG_GET` empty → **optional**. Print `DEGRADED: pm-config-get.sh not found (checked all three paths) — repo Wave override unavailable` and use `CEILING` as computed. An *absent* `.claude/pm-config.md` in a repo that has the script is a normal state, not a degradation — say nothing.
- `ACTIVE_WORK_CAP_SH` empty → **optional, but say so**. Print `DEGRADED: active-work-cap.sh not found (checked all three paths) — repo-wide cap unenforced, sizing on the per-thread ceiling only` and drop `FREE` from the `SLOTS` formula. `/wave` still has `EFFECTIVE - IN_FLIGHT`, so the wave stays bounded; what is lost is only the cross-thread term, and a run that silently dropped it would look identical to one where the repo genuinely had headroom. A **non-zero exit** from the script is different from a missing script: it means a count source could not be read, so treat it as `FREE = 0` and defer, rather than sizing as if nothing were in flight (`active-work-cap.md` "Resolution order and failure behavior").

The pipeline ceiling itself needs no fallback: `.claude/rules/subagent-orchestration.md` auto-loads at user scope in every project, so the number is already in context wherever `/wave` runs.

---

## Step 0a: Parse arguments

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

1. **Already offered, already running, or already decomposed.** Drop any issue whose row in `/pm`'s `## Active Work` table has Thread status `Chip offered`, `Inline`, `Active`, `Prompt generated`, or `Tracking`. The first three are the acceptance criterion; `Prompt generated` joins them because `/pm` 3.2 defines it and `Chip offered` as the same state — offered, not yet started — and `chip-launching.md` treats an issue with a live offer as already offered. Re-running `/wave` immediately must therefore produce **no** duplicate chips.

   **`Tracking` is the decomposed-parent case (#1193), and it is the one that bites hardest if missed.** A criterion-3 parent whose children are already building inline stays *open*, is deliberately never claimed, carries no `Depends on` marker, and is subagent-fit by `chip-launching.md`'s check — so every other filter here waves it through. Offering it would hand the user a chip to start a second thread implementing exactly what the running chain is already building. Drop it: its children are the real work and are counted individually.
2. **Already offered by `/issue-maker` in another thread.** The Active Work table check above only sees chips offered inside this PM thread — `/issue-maker` runs in its own capture-only thread and never writes to it (`chip-launching.md` "Cross-skill chip visibility"). Consult the shared cross-thread record instead:

   ```bash
   # TARGET_SLUG is this run's repo, e.g. `gh repo view --json nameWithOwner --jq .nameWithOwner`.
   for f in "$HOME"/.claude/handoffs/issue-maker-*-log.json; do
     [ -f "$f" ] || continue
     jq -r --arg slug "$TARGET_SLUG" '
       .issues[]
       | select(.status == "open" and .chip_task_id != null)
       | select(((if (.url | type) == "string" then .url else "" end)
                 | (try capture("^https?://[^/]+/(?<r>[^/]+/[^/]+)/issues/") catch {r:""}) // {r:""}
                 | .r | ascii_downcase) == ($slug | ascii_downcase))
       | .number' "$f"
   done | sort -u
   ```

   Three things in that filter are load-bearing, and each was a real defect:

   - **Extract the slug, then compare it literally — never interpolate it into a regex.** Repo names may contain regex metacharacters, and `.` is common (`api.v2`, `foo.github.io`); built into a pattern it matches any character, so a run in `acme/api.v2` would silently accept a chip from `acme/apiXv2`.
   - **Compare case-insensitively.** GitHub repo identities are case-insensitive, so a URL recorded as `Owner/Repo` is the same repo as a slug resolved as `owner/repo`. A case-sensitive compare would call it foreign and drop a live chip.
   - **Guard the URL's type.** `.url // ""` does not coerce an object or array to a string, and `capture` on a non-string aborts jq — taking every *later* entry in that log with it, so `/wave` would miss live chips and emit duplicate offers.

   `active-work-cap.sh` applies the same three rules; the two must agree on what "this repo" means or the counts diverge again.

   Leave jq's stderr unredirected — a malformed log file should surface as a visible error, not look identical to "no live chip found" (`chip-launching.md` "Cross-skill chip visibility"). Drop any candidate whose number appears in the command's output, silently — same treatment as (1). An issue-maker thread already offering a chip for #N is the same "already offered" state as a `Chip offered` row, just recorded in a different store.

   **Filter on the chip's repo, not just its number.** These logs are written one per capture thread and span *every* repo worked in, so an unfiltered read mixes `owner/other-repo#42` into a wave for this repo — where it would both suppress a legitimate `#42` here and consume an `IN_FLIGHT` slot that `FREE` (Step 6) scopes to this repo alone. The `select` on `.url` above is what keeps the two counts talking about the same thing. An entry with no usable `url` cannot be attributed and is **not** dropped from the candidate set — a bare number is not evidence that *this* repo's issue was offered.
3. **Already in flight on GitHub (dedup — any author).** Drop any issue referenced by a closing keyword (`close`/`closes`/`closed`, `fix`/`fixes`/`fixed`, `resolve`/`resolves`/`resolved`, case-insensitive) in an open PR body — local (`#N`) and cross-repo (`owner/repo#N`) forms both, **regardless of who authored the PR**: you don't want to start work a collaborator is already doing. Reuse the open-PR data `/pm` already fetched (it carries the `author` field); do not re-query. As you drop each one, note whether the covering PR is **yours** (`author.login` equals your authenticated login — `$GH_USER`, else `gh api user --jq .login`) or a **collaborator's** — only your own feed the ceiling count below.
4. **Already claimed by another thread (no PR yet).** Item 3 only sees issues that have reached a PR; a thread that picked an issue twenty minutes ago and is still planning is invisible to it. Consult the claim instead (issue #873). **Batch the lookup** — one call for the whole backlog, then the helper only for the intersection, because a candidate without the label cannot hold a claim:

   ```bash
   CLAIMED=$(gh issue list --label in-progress --state open --limit 100 --json number --jq '.[].number')
   # then, only for candidates whose number appears in $CLAIMED:
   "$ISSUE_CLAIM" <N> --check   # $ISSUE_CLAIM from Step 0; empty → the DEGRADED line there, then skip this filter
   ```

   The label is a safe pre-filter because `issue-claim.sh` maintains it as a **superset** of the claim: `--claim` writes the label before the claim comment and rolls the label back if the comment fails, and `--release` deletes the comment before removing the label. So a claim that exists at all carries the label at every intermediate point — there is no "comment but no label" state for this filter to miss.

   Drop a candidate whose verdict is `claimed` (exit 1) or `unknown` (exit 4), naming the claim as the reason. `unknown` is treated exactly as `claimed` — it never reads as permission. `stale` is **not** an exclusion: keep the candidate and surface the stale warning alongside it.

   Respect issue #732 the same way item 3 does: a **collaborator's** fresh claim drops the issue as context, but it never counts toward *your* `IN_FLIGHT` ceiling and is never overwritten.
5. **Explicitly blocked labels.** Drop `blocked`, `on-hold`, `wontfix`, `duplicate` (`/pm` 1B.4 already excludes these — this is a cheap re-check, not a re-ranking).

Every issue removed here is **silent** — it is not a wave exclusion and does not appear in the excluded list (Step 9). The excluded list is for issues that were genuine candidates and lost on independence or cap.

Record `IN_FLIGHT` = the number of **distinct in-flight pipelines of yours**: each Active Work row from (1), each issue-maker chip from (2), and each **distinct open PR you authored** that covers one or more issues dropped in (3) **and is not already the PR backing an Active Work row counted in (1)**. Count PRs, not issue rows — a single PR that closes several issues is **one** pipeline consuming **one** reviewer slot, not several — and cross-reference PR numbers against (1) so a PR that closed one issue already tracked in Active Work *and* covers another still-candidate issue is not counted twice (once as its Active Work row, once as its (3) contribution). Step 6 subtracts it. Collaborator-covered issues are still dropped from candidates (they are already being worked), but they **never count toward your ceiling**: a collaborator's backlog must not consume your slots (issue #732 — count only your own PRs; shared-budget contention is at most FYI context, never a gate). Offered-but-unstarted issues of yours count toward it deliberately: a chip the user clicks a minute from now consumes the same reviewer budget as one already running, and the point of the cap is to avoid discovering that after the fact.

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

**Repo-declared surfaces.** If `.claude/pm-config.md` has a `## Dependency Rules` section, read it (`"$PM_CONFIG_GET" --section "Dependency Rules"` — Step 0) and honor any coupling it declares — e.g. "changes to X require regenerating Y" makes X and Y one surface. A repo that knows its own coupling outranks this table.

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
FREE       = "$ACTIVE_WORK_CAP_SH"         # default line: CAP=n ACTIVE=n FREE=n
SLOTS      = min(REQUESTED?, EFFECTIVE - IN_FLIGHT, FREE)
```

`REQUESTED` caps *new* chips; `EFFECTIVE - IN_FLIGHT` caps *total* concurrent work. Applying them separately means `/wave 2` with one issue already in flight still offers 2 (total 3, under the ceiling) rather than being penalized twice.

- **`CEILING = 4`** comes from `.claude/rules/subagent-orchestration.md` ("Keep 3-4 active CR-polled PRs max"). It binds chip-launched threads too: the scarce resource is **reviewer throughput** — CodeRabbit serves 5 PR reviews per developer per hour, shared across every open PR you own (`.claude/reference/cr-rate-limits.md`) — not subagent slots. Four threads started at once become four PRs competing for that same hourly budget.
- **`FREE`** is the repo-wide headroom from `"$ACTIVE_WORK_CAP_SH"` (Step 0). Read its **default output**, not `--free`: the one line carries `CAP`, `ACTIVE`, and `FREE`, and the cap-bound message below quotes `{ACTIVE}/{CAP}`, which `--free` cannot supply (`chip-launching.md` "Repo-wide active-work cap"). `CEILING` bounds *this thread*; `FREE` bounds **every thread on the repo at once**, counting your open PRs, live chips offered from any capture thread, and pipelines not yet at a PR. It is the term that stops a fresh `/wave` in a new tab from re-filling a board that other tabs already filled. Never read the cap's number into this file — the script owns it, and its derivation is `active-work-cap.md`.
- **`CONFIG`** is an optional `MAX_WAVE=N` line in a `## Wave` section of `.claude/pm-config.md`:

  ```bash
  "$PM_CONFIG_GET" --section Wave 2>/dev/null | sed -n 's/^ *MAX_WAVE *= *\([0-9][0-9]*\).*/\1/p' | head -1
  ```

  Absent, unparseable, or out of range → ignore it and use `CEILING`. A config value **may lower the cap and may never raise it** past the auto-loaded rule; clamp rather than error. Changing the ceiling itself means editing `subagent-orchestration.md`, which is a reviewed rule change. (`## Wave` is a non-canonical section, so `/pm-update` preserves it verbatim.)
- **`IN_FLIGHT`** is the count from Step 2 — issues already offered or already running consume the same reviewer budget.

If `SLOTS <= 0`, print one line naming what is already in flight and **whose** — the count is your own PRs only ("your 4 open pipelines fill the 4-slot ceiling — merge or park one before starting more."). Never phrase it as a bare "N open PRs": a collaborator's PRs are not in this count, and naming the scope is what makes a wrong count visible at a glance (issue #732, AC4). Then, **in every thread** — `/wave` is always execution-capable, so there is no PM-context branch to take (#1229; `chip-launching.md` "Precedence when the ceiling is full", case 1) — name the subagent-fit issues as **queued inline** behind the running pipelines, bootstrapping the `## Active Work` table if this thread has none, and list any **too-big** ones as *deferred*: they need a thread, and opening one now would spend the same reviewer budget the ceiling exists to protect, so they wait for a slot too. "Stop" means no new work starts, not that issues go unnamed. A full ceiling **never** produces a chip — slot state schedules, it never routes work to a thread (#776 AC4) — and **nothing is silently dropped**: every excluded issue is named with its reason. The repo-wide cap binding is the same shape: an issue it holds back is **deferred and named**, never given a chip and never quietly omitted, so every issue in the independent set ends as running, queued, or deferred.

**Name the term that actually bound.** `SLOTS` has three inputs and they fail for different reasons, so a block message must say which one is tight — "the ceiling is full" when the repo-wide cap is what stopped you sends the user to merge a PR in *this* thread when the work is in another tab. Record the limiting term as you compute `SLOTS`, rather than re-deriving it from the numbers afterwards. **When two bounds tie, name the repo-wide cap**: it is the one the user cannot see from this thread, so it is the one worth saying out loud; `REQUESTED` is named last, since the user chose it and already knows.

- **`FREE` bound** → "the repo is at its active-work cap ({ACTIVE} of {CAP} in motion — your open PRs, offered chips, and running pipelines across all threads)". `active-work-cap.sh --json` gives the per-source breakdown when the split is worth showing.
- **`EFFECTIVE - IN_FLIGHT` bound** → the existing per-thread message, naming your own in-flight pipelines.
- **Capacity could not be read** — the script resolved but exited non-zero → **not the same as `FREE = 0`**, and it must not borrow that wording. There is no `{ACTIVE}/{CAP}` to quote, because the count is precisely what failed. Say "could not read the repo-wide active-work figure ({reason}) — deferring rather than assuming the repo is idle" and defer. Reporting an unread count as a cap of zero is a fabricated number; reporting it as headroom is the unsafe direction. The missing-script case is different again and is a `DEGRADED:` line at Step 0, not a deferral.

Take the first `SLOTS` issues from the independent set. Anything past that is excluded, with the reason matching the term that bound: "cap reached ({SLOTS} slot(s); {IN_FLIGHT} already in flight)" for the per-thread ceiling, "deferred — repo-wide active-work cap ({ACTIVE}/{CAP})" for `FREE`, or "deferred — repo-wide capacity unreadable ({reason})" when the figure could not be obtained. Deferred issues are re-offered as work drains; they are never dropped.

---

## Step 7: Offer the wave — inline by default, chips only for too-big issues

**7.0 — PM-context inline gate (before offering any chip).** Apply the gate from `chip-launching.md` "PM-context inline gate", read through the Step 0 candidate order. **`/wave` is always execution-capable** — the one exception the gate names is a capture thread, which runs no waves — so the subagent-fit wave issues are **recommended for inline parallel execution in this thread**: lead with a single `/subagent #{a} #{b} …` line for them rather than spawning chips. Inline runs them in parallel up to the ceiling, which is exactly what a wave is for, and it keeps them in one thread instead of scattering tabs (#613). **A thread with no `## Active Work` table bootstraps one** (`/pm` 3.2's schema) and proceeds — its absence is a bootstrap instruction, never a reason to chip (#1229). Slot availability decides only **how many start now versus queue behind the ceiling** (Step 6) — it never sends a subagent-fit issue to a separate thread (#776, AC4). Fall through to the chip offer below **only** for issues that are **too big** for a subagent, each naming which criterion fired in one line — normally criterion 1 or 2, since #1193's criterion 3 decomposes into an inline chain rather than routing out (`chip-launching.md` "PM-context inline gate" carries the one case where it still routes). That is now the sole structural reason a `/wave` chip exists, and one with no nameable criterion is a bug. `/wave` still launches nothing: recommending `/subagent` is not running it (Execution boundary); the user's `/subagent` or click is the only launch path.

**Bootstrapping vs. the Step 1.2 cold start — one route each, for different things.** Step 1.2 cold-starts `/pm` when the thread has no *ranking*, and a table falls out of that as a side effect. The bootstrap here is the fallback for the remaining case: a thread that has a ranking (or was given issues directly) but no table. There is exactly one table-bootstrap route — this one — and it never re-runs `/pm`.

**7.1 — Offer the (remaining) wave as chips.** Follow `chip-launching.md` (Step 0 candidate order) **verbatim** — availability detection, `spawn_task` shape, model-guard preamble, short-summary format, per-issue fallback on spawn failure. Nothing in this section overrides it.

**Chip model + effort contract (non-negotiable):** For each chip, the `prompt` MUST open with `**Model:** {MODEL} — {REASON}`, then `**Effort:** {LEVEL} — {REASON}`, then the model-guard preamble — no blank line between the three. The visible short summary MUST repeat both lines. `{MODEL}` is a bare family name and `{LEVEL}` a picker label (`chip-launching.md` "Model and effort lines"). When the parent thread is on Fable and the chip recommends a different model, add the pre-click warning from `chip-launching.md` "Upstream requirement."

For each issue still offered as a chip:

- **`prompt`** — the full self-contained thread prompt from `/pm` Step 3.1's template (`**Model:**` line first, `**Effort:**` line next, model-guard preamble immediately after with no blank line between the three, then the task / issue body / codebase context / workflow / constraints sections). Reuse that template as written; `/wave` does not define a prompt format of its own. That includes its **Constraints** block and, within it, the merge-authority bullet — the shared contract from `chip-launching.md` "Merge-authority line", which asserts that the launched thread merges itself via full `/wrap` once the merge gate passes and every AC checkbox verifies. Carry it **verbatim**; never fork a `/wave`-local copy and never soften it into an approval request.
- **`title`** — ≤60 chars, starts with a verb, includes the issue number.
- **`tldr`** — 1–2 plain sentences, no paths, no jargon.
- **`cwd`** — repo root.
- **Model and effort lines** (`**Model:** {MODEL} — {REASON}` then `**Effort:** {LEVEL} — {REASON}`) — take both recommendations from `/prompt`'s tier classification if it ran in this thread; otherwise infer them from the issue's signals with the same Heavy/Standard/Light mapping (`/prompt` Steps 4–5). Both lines appear **both** inside the chip prompt and in the visible summary, because chips preset neither picker control.

Print only the short summary per issue. A failed `spawn_task` falls back to a printed block **for that issue alone**; the rest of the wave keeps its chips. Every issue in the wave ends with exactly one of: a chip, or a printed block — never both, never neither.

---

## Step 8: Record every `task_id`

Immediately after each successful spawn — before printing anything else — write the returned `task_id` into `/pm`'s `## Active Work` table with Thread `Chip offered`, Status `Awaiting thread start`. That table is the canonical home for chip state (`chip-launching.md`, `/pm` 3.2); `/wave` writes to it rather than keeping a parallel ledger. If no table is present, create one in `/pm` 3.2's exact format — the bootstrap from Step 7.0, which does not re-run `/pm` (Step 1.2's cold start is a separate, ranking-only route).

An unrecorded chip cannot be dismissed later — recording is what makes withdrawal possible at all, not bookkeeping.

**Inline rows are deliberately *not* recorded here, and that is not the same gap.** `/wave` only *recommends* inline execution; the user's `/subagent` is what starts it, and that is what marks the rows `Inline` (Execution boundary — writing `Inline` for an issue `/wave` merely named would claim work that has not started). The asymmetry is safe because the two re-run hazards are different: re-spawning a chip creates a **second live offer** for one issue, which is why Step 2 case 1 must see it; re-printing an inline recommendation creates nothing, so an unchanged wave on a re-run is correct rather than duplicated. `IN_FLIGHT` is unaffected either way — Step 2 derives it from your own open PRs, and an issue nobody has started is genuinely not in flight.

---

## Step 9: Print the wave

```
## Wave — {K} issue(s) ready to run in parallel

- **#42 — {Title}** — recommended inline
  {one-line rationale, carried from /pm's ranking}

- **#55 — {Title}** — recommended inline, queued behind #42
  {one-line rationale}

- **#67 — {Title}** — chip offered
  **Model:** Opus — {reason}
  **Effort:** Extra — {reason}
  too big for a subagent — {which /subagent Step 4 criterion fired, and why}

Running #42 #55 inline here: `/subagent #42 #55`. Click the chip to start #67 in its own thread.

### Excluded from this wave
- **#61** — overlaps #42 on `.claude/skills/pm/SKILL.md`
- **#38** — blocked by #42, which is in this wave
- **#70** — footprint undeclared; can't rule out overlap with #55
- **#71** — cap reached (2 slots; 2 already in flight)
```

Rules for this block:

- **Inline is the default row shape** (#1229). `recommended inline` rows carry no `**Model:**` / `**Effort:**` lines — an inline pipeline picks its own model at spawn time, so there is no picker for the user to set. Only a `chip offered` row carries them, and every such row **names its `/subagent` Step 4 criterion on its rationale line**; a chip row without one is a bug (`chip-launching.md`). "Recommended" is the honest word: `/wave` names the set, the user's `/subagent` starts it (Execution boundary).
- **Every candidate that reached Step 5 appears exactly once** — in the wave or in the excluded list. Issues dropped in Step 2 (already offered, already in flight, blocked-labelled) appear in neither; they were never candidates.
- **One line, one reason** per exclusion. The reason names the *specific* blocker or surface — "overlaps #M" without saying on what is not a reason. Never emit a bare "excluded".
- Omit the `### Excluded from this wave` heading entirely when nothing was excluded.
- Flag circular dependency pairs on their own line: "**#80 / #81** — circular dependency; needs human resolution."
- No methodology narration. The wave and the reasons are the output; the ladder that produced them is not.

---

## Step 10: Fallback mode (no `spawn_task`)

When chip mode is unavailable (CLI, headless, older client), the **too-big** issues are delivered as printed prompt blocks — content byte-identical to what their chips would have carried, model-guard preamble included, per `chip-launching.md` "Fallback mode". Inline rows are unaffected: `/subagent` needs no `spawn_task`, so the inline recommendation is identical in both modes and never degrades to a printed block (#1229).

- Print the full block for each **too-big** wave issue instead of the short summary.
- The Excluded section is unchanged.
- **Do not mention chips, clicking, or `task_id`s** — none of that exists in this mode. Replace the *chip* half of the launch line with "Paste a block into a new thread to start it." The inline half stays as written: `Running #{a} #{b} inline here: /subagent #{a} #{b}`.
- Track offered issues in this thread's state so a re-run still skips them (Step 2 case 1 reads `Prompt generated` for exactly this).

---

## Execution boundary (CRITICAL)

`/wave` **offers**. It never starts work.

| Rationalization | Reality |
|---|---|
| "The user asked for a wave, so they clearly want these running." | They asked for the *set*. Which ones actually run is the click. |
| "These are all small — I'll just run them inline myself like `/pm` does." | *Recommending* inline via `/subagent` (Step 7.0) is the default in **any** execution-capable thread since #1229 — but `/wave` *running them itself* is not, and that did not change. Launch stays elective: which issues run, and how, is the user's action (a chip click or their own `/subagent`), never `/wave`'s. |
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
