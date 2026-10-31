# Create: record, report and handoff

> Load only for: after a filing, or an explicit tally/body-reprint/offer-response request
> Prerequisites: session state loaded; confirmed filing receipt for new-row recording; batch module only for a batch or chain

**Report-only routing:** `report:status` performs only the requested tally, body reprint, or existing offer response/refresh below. It does not run the new-row recording block or create another issue. On recovery after a confirmed create, first check `.number` plus `same_repo`: record a missing row from the persisted filing receipt, or reuse the matching existing row; never append the same receipt twice. A failed log write stops reporting/offer emission with the confirmed GitHub URL and pending recording step checkpointed; it never authorizes retrying the remote create.

## Step 9: Record + offer the session's coding hand-off + print the URL (the closing-line rule)

After **every** create — and after every update/close — append/refresh the session log and **print the GitHub issue URL as a clickable markdown link as the final line of the response.** This rule is absolute: the link is never buried in prose, never mid-paragraph — it is the closing line.

**Two orderings sit under that rule, and neither weakens it.** (a) In a batch or chain, each create's URL line is **intermediate** output and only the **last** issue's URL closes the response (Step 6). (b) The summary table (Step 9a) is emitted **immediately before** that final URL, never after it. So the response still ends with an issue URL in every case — what varies is only which URL, and what precedes it.

**Initialize `CHAIN_JSON` before recording.** `create:increment-draft` minted/restored the stable identity before dedup. Every record starts with null so ordinary issues cannot inherit a prior chain object:

```bash
CHAIN_JSON=null
if [ "${IS_INCREMENT:-false}" = true ]; then
  : "${CHAIN_ID:?restore the chain identity before recording}"
  : "${POSITION:?restore this member position before recording}"
  : "${TOTAL:?restore the chain total before recording}"
  CHAIN_JSON=$(jq -nc --arg id "$CHAIN_ID" --argjson i "$POSITION" --argjson n "$TOTAL" \
    '{chain_id:$id, position:$i, total:$n}') || exit 1
fi
```

Build the labels as a JSON array from the accepted labels (the same set passed via `--label` flags in Step 5/7), then record the issue through the `set_log` helper:

```bash
# ACCEPTED_LABELS holds the labels applied to this issue, one per line
# (empty if none). Convert to a JSON array — `[]` when there are none.
LABELS_JSON=$(printf '%s\n' "$ACCEPTED_LABELS" | jq -R . | jq -s 'map(select(length>0))')

set_log '.issues += [{number:($n|tonumber), title:$t, url:$u, labels:$labels,
                      created_at:$ts, origin:"create", status:"open", chip_task_id:null, chain:$chain,
                      tier:$tier, delivers:$delivers, est_bound:($bound|tonumber)}]
         | if $chain != null and $chain.position == $chain.total
              and .active_chain.chain_id == $chain.chain_id
           then .active_chain = null else . end' \
  --arg n "$ISSUE_NUMBER" --arg t "$TITLE" --arg u "$ISSUE_URL" \
  --arg ts "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" --argjson labels "$LABELS_JSON" \
  --argjson chain "$CHAIN_JSON" --arg tier "$ISSUE_TIER" \
  --arg delivers "$DELIVERS" --arg bound "$EST_BOUND"
```

**`DELIVERS` and `EST_BOUND` are the summary table's two per-row inputs, persisted here on purpose.** `DELIVERS` is the row's one-clause `Delivers` text — **one line, with any `|` escaped as `\|`**, since it is dropped straight into a markdown table cell and a raw pipe or newline splits the row — and `EST_BOUND` the raw `plan on` bound in minutes from the body's `## Estimate` line — both already in hand when the issue is drafted (Step 3 sub-step 4, Step 5). Writing them to the log is what lets the running tally re-render the canonical table after compaction, when the in-context values are gone and only `$LOG` survives; `tier` covers the `Model` column the same way. A tally that had to re-derive them would drift from the table printed at filing time. Because they are persisted rather than re-derived, a later `/update` that changes the delivered scope or the estimate has to write them back — Step 10 sub-step 6 owns that refresh.

**`chain_id` is what makes the chain recoverable.** Sibling detection (Step 4), the queued-successor note (Step 9c), and retraction (Step 12) all resolve membership by matching `chain_id` in `$LOG` — never by theme text or position number, which collide across unrelated chains and cannot survive a re-worded title. It also survives compaction: the log is re-read in Step 1, so a chain interrupted mid-filing is still identifiable afterwards, which in-context memory alone would not give you.

### Step 9a: The post-create report — summary + decision points + the summary table

The report is what replaces the old draft-reprint-and-approve gate, and it is the safety valve that makes auto-filing low-risk. It has three parts, on **two different cadences**: parts 1 and 2 are **per issue** — emit them immediately after logging that issue, before the hand-off (Step 9c) and before its closing URL — while part 3, the summary table, is **per filing** and lands once, at the end. For a single issue the two cadences coincide and all three parts appear together; in a batch or chain, each member gets parts 1 and 2 as it is filed and the table arrives once, after the last one. An early member of a batch is never expected to carry the table.

1. **Summary (1–3 sentences).** What issue you just opened, in plain functional terms — the same voice as the body's lead sections, not a section-by-section readout.
2. **Decision points (1–3 sentences).** The actual calls you made that the user might want to revisit — scope you narrowed or expanded, a split you considered but did *not* make, **a sizing split you did make**, assumptions you encoded, the labels you auto-applied, a weak-duplicate pointer (Step 4). **Name the concrete call** (e.g. *"scoped to the create flow only; assumed rapid-fire keeps its narrower dedup bar; applied `skill`, `enhancement`"*), never boilerplate like "made some scope decisions." If you genuinely made no non-obvious call, say so in one line rather than padding.

   **A sizing split is a decision point like any other** — report it once, on the chain head, naming the count and *why* the ask exceeded one pipeline: *"sized as a 4-increment chain because one pipeline can't land hero, services page, contact form, and SEO metadata as one reviewable PR."* Say what the increments are and that they're linked; the user re-cuts the chain with `/update` or `close` if the boundaries are wrong. Successor increments do not each repeat the split rationale.

3. **The summary table (always, no exceptions).** Every filing closes with the canonical table defined below. It is the part of the report that actually gets read — one glance says what was filed, in what order, on which model, and how much calendar time to block. Parts 1 and 2 are per-issue; this part closes the **filing** (see "Emitted once per filing" below), so in a batch or chain it appears once, after the last member, rather than after each create.

#### The canonical summary table (the one shape)

**This is the skill's only issue-table format.** Step 6's batch summary, the running tally (Step 9), and the exported prompt (Step 13) all render *this* table; no second column set exists anywhere in the skill. Everywhere inside the skill, **cite this definition rather than restating the shape** — Step 13 is the single deliberate exception, because an exported prompt lands where this file cannot be read. Five columns, in this order:

| Column | Contents |
|--------|----------|
| `#` | The issue as a clickable link — `[Issue #N](url)`. The `Issue #` prefix is `CLAUDE.md`'s GitHub-reference rule, which binds inside link text too. |
| `Increment` | `{i}/{n}` for a chain member (the Step 5 marker), `—` for a standalone issue or a member of an unrelated batch. |
| `Delivers` | One plain-English clause, functional voice — what the issue gets you, not how. Not the title restated verbatim. |
| `Model` | The bare family name for the issue's tier (below). |
| `Est` | The issue's planning bound at 30-minute granularity (below). |

**Emitted once per filing, always.** A filing is one single issue, one batch, or one chain — so a single filed issue produces a **one-row** table, and a batch or chain produces **one row per member**, printed once after the last member is filed rather than re-printed and re-grown after each create. There is no mode, size, or shape in which the table is skipped: it is the closing summary of every filing this skill makes.

**It never displaces the closing URL line.** The table is emitted **in addition to** the `Created #N: …` closing line (Step 9), which stays the final line of the response. A table row's link is a summary, not the closing line.

**`Model` — the bare family name for the inferred tier.** Read `ISSUE_TIER` for that row's issue, already inferred in Step 3 sub-step 4, and take the model its tier maps to in `references/tier-inference.md` — that file owns the mapping; do not restate it here. Per-row, never the session's `BATCH_TIER` — that running maximum belongs to the Step 9c offer, and using it here would report a Light issue as Opus work. **Never a version number or an API token** — the same bare-family-names bar Step 9b states.

**`Est` — the body's `plan on` bound, rendered at 30-minute granularity.** Read the `{bound}` from that issue's `## Estimate` line (`Est: {lo}–{hi} min · plan on {bound}`, Step 5) and render the bound alone; the range stays in the body, because the table exists to block calendar time. Two steps, in this order:

1. **Round up to the next multiple of 30** if the bound is not already one — `45` becomes `60`. The tier bounds in `time-estimates.md` are all multiples of 30 already, so this bites only when Step 5's scope adjustment produced something else. Rounding *up*: the column is a planning bound, and rounding down under-books the day.
2. **Render the rounded value**, taking the first case that matches:
   - **Under 60 minutes → `30min`** — the only sub-hour value that survives step 1. (`0h30` reads worse.)
   - **A whole number of hours → `{h}h`** — `180` → `3h`, `300` → `5h`.
   - **A trailing half hour → `{h}h30`** — `90` → `1h30`, `210` → `3h30`.

**Reading the bound never rewrites it.** The table consumes the `## Estimate` line as filed; the body's own `Est:` line keeps the exact machine-parse shape `time-estimates.md` fixes (`^Est:\s+(\d+)–(\d+)\s+min\s+·\s+plan\s+on\s+(\d+)$`), which `/pm` and `/subagent` parse. Whatever the seed values are — issue #1670 recalibrated them to a rounds-based figure — this table only reads the bound and is agnostic to how it was computed.

**Chains get a total row.** A chain is one theme delivered in sequence, so a final row sums the `plan on` bounds of every increment (in minutes) and renders the sum with the same rule above, so the whole theme's planning bound is visible at a glance. The row leaves `#` and `Increment` empty, labels itself `**Chain total**` in `Delivers`, leaves `Model` empty, and carries the bolded total in `Est`. A **batch of unrelated issues gets no total row** — independent asks that will not be worked as one sequence have no meaningful joint bound.

A chain filed as two increments, each Standard (`plan on 180`) — a real chain from before
the `INCREMENT_BOUND_MIN` rule above, kept because it is what the rendering teaches; a chain
filed today would carry Light-tier increments:

```markdown
| # | Increment | Delivers | Model | Est |
|---|-----------|----------|-------|-----|
| [Issue #1670](https://github.com/auerbachb/claude-code-config/issues/1670) | 1/2 | Rounds-based `Est:` formula so estimates track real merge time | Opus | 3h |
| [Issue #1671](https://github.com/auerbachb/claude-code-config/issues/1671) | 2/2 | Always-on summary table with Model and Est columns | Opus | 3h |
| | | **Chain total** | | **6h** |
```

Close by reminding the user the issue is cheap to change — a wrong call is one `/update #N …` or `close #N` away. This report is emitted **in addition to**, never in place of, the closing URL line (Step 9). **Rapid-fire** emits a terser version, in this order: the table, optionally a one-line summary, then the closing URL as the final line — and no decision-points elaboration. **Rapid-fire trims the decision points, never the table** — the table is the leanest part of the report and the reason the leaner mode is still readable. In both modes the closing URL is last: nothing in this report, the table included, is ever emitted after it.

Tone precedent: `/wrap`'s terse "here's what I decided — flag anything wrong" framing and `issue-planning.md`'s number/title/rationale/link quartet. Keep the whole report to a few lines; its value is signal density, not length.

### Step 9b: Infer a coding tier (for the offer's tier statement and model step-up warning)

The inline-run offer (Step 9c) names the batch's inferred tier so the user knows what model/effort the work warrants. **Reuse `BATCH_TIER` accumulated in Step 3 sub-step 4** — each issue's tier was already inferred there to compute the `## Estimate` section, and the running maximum was kept. Re-infer only if Step 3 was skipped or `BATCH_TIER` is unavailable. Full signal definitions, tier table, and evaluation rules: `references/tier-inference.md`. Summary:

| Tier | Trigger (any is sufficient) | Model / effort |
|------|-----------------------------|----------------|
| **Heavy** | `touches_rules`, `touches_claude_md`, `has_orchestration_keywords`, or `file_count > 5` | Opus, Extra |
| **Standard** | not Heavy, and (`file_count` 2–5, `ac_count > 3`, or `touches_skill`) | Opus, High |
| **Light** | not Heavy/Standard, **and** a positive Light signal (`scope_keywords` or `file_count ≤ 1` with clear scope) | Sonnet, Low |

Default to **Standard** when signals are sparse. Values are bare family names / picker labels — never version numbers or API tokens.

**A session's offer covers several issues, so it takes the most demanding tier among them** — the same batch-tier rule `/prompt` Step 4 uses ("a batch of 3 issues where one is Heavy makes the batch tier Heavy"). Infer each issue's tier as it is filed and keep the running maximum.

**Model step-up warning (best-effort).** An inline run inherits the thread's model — there is no picker to set. When the thread's self-reported model sits below the inferred tier, the offer states the gap before asking:

> "Note: this thread is running on {CURRENT_MODEL} but the batch infers {INFERRED_TIER} ({INFERRED_MODEL}/{INFERRED_EFFORT}). An inline run will use {CURRENT_MODEL}."

For a **large gap** (e.g. Heavy batch on a Haiku or Sonnet thread), additionally recommend declining: *"For best results, consider declining and either switching this thread's model before accepting, or requesting the on-request hand-off below (which has a model picker)."* The offer never blocks — the user's explicit yes is the only gate. The inline path carries **no MODEL GUARD preamble** (that preamble stays only in the on-request chip/fallback block).

**Both the tier name and recommended model/effort reach Step 9c** — named in the offer text before the acceptance question. A tier computed here and then dropped is the defect #791 fixed.

### Step 9c: Offer the inline run (default ending, alongside the closing link)

A capture session ends by **offering to run every open issue it filed, right here in this thread, via `/subagent`** — not by emitting a separate-thread chip. The offer is made **once per session** after the last issue is filed, **in addition to**, never in place of, each issue's closing URL line. No auto-start: execution begins only on an explicit "yes" in chat.

**Repo-wide cap (before the offer, for a single issue or batch).** Resolve `active-work-cap.sh` to the first executable of `$HOME/.claude/skills-worktree/.claude/scripts/active-work-cap.sh`, `$HOME/.claude/scripts/active-work-cap.sh`, or `.claude/scripts/active-work-cap.sh` — this repo may carry no `.claude/` directory. Read the census once per session; the default output line gives `CAP`, `ACTIVE`, and `FREE` together. Offer inline while `FREE > 0`; at `FREE == 0` **defer**, naming `{ACTIVE}/{CAP}` and the scope: `hand-off deferred — repo-wide active-work cap ({ACTIVE}/{CAP} in motion across all threads)`. If the script does not resolve, print `DEGRADED: active-work-cap.sh not found (checked all three paths) — offering inline without a repo-wide bound` and offer it anyway (the run applies its own ceiling; withholding it strands the issues). A **non-zero exit** from a script that did resolve means the count could not be read — treat it as `FREE = 0` and defer, naming the read failure rather than a fabricated count.

**Offer stamp.** When the offer is emitted, generate a local offer token (e.g. `offer-$(date +%s%N)`) and write it into `chip_task_id` on every open issue the offer covers — this is what stops `/wave` or `/pm` from launching a second offer for work already covered. The stamp is **not** a `spawn_task` return; it is a locally-generated string. It is written through `mine` (the write-helper section), so it reaches only `$REPO`'s session-filed open rows and can never overwrite a token that belongs to another session's batch.

<!-- test-anchor: issue-maker-step9c-offer-stamp -->
```bash
OFFER_TOKEN="offer-$(date +%s%N)"
set_log "$MINE_DEF"'.delivery_mode = "inline" | (.issues[] | mine | .chip_task_id) = $tok' \
  --arg tok "$OFFER_TOKEN" --arg repo "$REPO"
```

**Offer text.** Include the batch's inferred tier (Step 9b) and the model step-up warning when applicable. In default mode, ask explicitly:

```text
Ready to run {N} issue(s) inline via /subagent — inferred tier: {TIER} ({MODEL}/{EFFORT}).
{Model step-up warning if applicable — see Step 9b.}

Issues to run, in filing order:
1. #{a} — {title}
2. #{b} — {title}
{…one per open issue, in filing order}
{Increment chains: "#{b}–#{d} are increments 2–4 of one chain behind #{a}; they land in that order."}

Say **yes** to run them now in this thread. Say **no** to leave them filed; you can request the hand-off chip at any time.
```

In **rapid-fire mode**, use terser framing: *"Run {N} issue(s) inline — {TIER} ({MODEL}/{EFFORT})? [yes/no]"*; prepend the same applicable model step-up warning from Step 9b (including the Heavy-on-lower-tier recommendation), keeping it to one concise line. Rapid-fire trims commentary, never the pre-acceptance model/effort information

**On yes — acceptance.** Invoke `/subagent #{a} #{b} …` first; if it succeeds, end capture mode (`offer_accepted: true`) and clear `chip_task_id` from all covered issues so they are no longer counted as pending offered work in the cap census. If the invocation fails, leave `offer_accepted` unset so the offer can be re-attempted or withdrawn via Step 12. Issue-maker adds no orchestration: claims, the pipeline ceiling, Step 6.0b chain serialization, and too-big routing all belong to `/subagent`.

```bash
# /subagent #{a} #{b} ...  ← invoke first
set_log '.offer_accepted = true'
set_log "$MINE_DEF"'(.issues[] | mine | .chip_task_id) = null' --arg repo "$REPO"
```

**On no — decline.** Leave all issues filed and launch nothing. Clear `chip_task_id` from all covered issues so they are no longer counted as pending offered work in the cap census. The inline offer is withdrawn; the on-request hand-off block below remains available on explicit request (`"give me the chip"`, `"print the hand-off"`, etc.).

```bash
set_log "$MINE_DEF"'(.issues[] | mine | .chip_task_id) = null' --arg repo "$REPO"
```

**Refresh before acceptance.** When more issues arrive in later turns before acceptance, refresh the offer: re-emit the offer text covering all open issues (including the new ones), update `chip_task_id` on the new issues to the same offer token, and append the new issues to the offer.

**After acceptance.** New issues filed in later turns join the running batch (call `/subagent #newN` for each one as it is filed) rather than triggering a fresh offer.

**Increment chains.** The offer names the chain and its order; `/subagent` Step 6.0b serializes the increments behind their predecessor. Never split a chain across two offers.

A capture session ends with exactly one of **four** outcomes for its filed issues; never none, and never two:

1. **inline-run offer** — the user is asked in-thread; yes ends capture mode and starts `/subagent`, no leaves issues filed;
2. **deferred offer** — the repo-wide cap left no headroom (`FREE == 0`, or the count could not be read);
3. **inline-run offer (DEGRADED)** — active-work-cap.sh did not resolve; offer is still made without a repo-wide bound (a single inline run applies its own ceiling);
4. **on-request hand-off only** — the user explicitly asked for a chip instead of the inline path.

Outcome 2 defers the offer, never the issues: every issue is still filed, logged, and its URL still printed. Say so in one line and give the retry:

```text
Inline-run offer deferred — repo-wide active-work cap ({ACTIVE}/{CAP} in motion across all threads). All {N} issues are filed; re-run `/issue-maker` once work drains to offer inline execution.
```

---

**On-request hand-off:** only when explicitly requested, resolve/read `offer:handoff`; the chip/fallback template and registry mechanics are deferred to that module.

**Print the full issue for #N (on demand).** Because default mode no longer reprints the body at create time, the whole body is available on request instead: when the user asks to **"print the full issue for #N"** (or "show me the whole body of #N"), re-emit that issue's complete body **exactly as filed**, sourced from GitHub as the source of truth so the reprint always matches what is actually on the issue. Reprint what is there rather than asserting a shape: an issue this skill created carries the canonical 7 sections, but one opened elsewhere may not, and the reprint never implies otherwise.

```bash
gh issue view "$N" --repo "$REPO" --json body --jq .body
```

This is distinct from the "print the full prompt for #N" replay just above, which re-emits the coding-chip *prompt*, not the issue body. Printing is not a state change — the issue stays exactly as-is (mirrors `chip-launching.md` "Print-on-demand replay").

Closing line format:

```
Created #N: [<owner>/<repo>#N — <title>](<ISSUE_URL>)
```

**Running tally:** the log is the source of truth for "issues opened in this thread." Surface a tally after every 5 issues and on explicit request — rendered as the **canonical summary table from Step 9a** (`#`, `Increment`, `Delivers`, `Model`, `Est`), one row per open issue in filing order — including a `**Chain total**` row for each open chain it covers, since it is the same table under the same rules. **Rows come from `mine`, not from every open row** (`set_log`'s selector above): "issues opened in this thread" means this repo's, and a shared log otherwise renders another repo's URL, `Delivers`, `Model`, and `Est` here as if they were ours — the read-side counterpart of the write scoping — so the tally and the post-filing table are the same object rather than two competing shapes. Anything closed or retracted since is named in one line beneath the table instead of earning columns of its own. Every cell comes from the log record above — `delivers`, `tier`, and `est_bound` are stored there for exactly this reason — so the tally survives compaction; a row missing one renders `—` (Step 10's backfill rule), never a guess. The compaction recap in Step 1 reads the same log.

---
