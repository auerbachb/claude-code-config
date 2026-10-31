# Create: reflect and draft

> Load only for: one new issue description, before dedup or filing
> Prerequisites: session state is initialized/recovered; create operation selected

## TOP-LEVEL RULE — reflect before you file (NON-NEGOTIABLE)

> **Never pass a user's sentence straight through to `gh issue create`.** Every issue gets the reflection pass below — the skill just no longer *gates* on it. Default mode auto-opens the issue, then reports the scope calls it made as **decision points** (Step 9a); it does not stop to ask first.

**Why this is rule #1 — the LLM pass-through bias.** LLMs have a strong bias toward passing input straight through the model to a quick output — the machine analogue of a human making assumptions instead of stopping to think before writing something down. Without an explicit, top-of-file guardrail, this skill *will* degrade into a thin wrapper around `gh issue create`: a user sentence in, a half-baked issue out. The reflection discipline is the entire point of the skill. **Do not water it down or "optimize" it away under time pressure.** Issue #691 changed *where* the reflection surfaces — as a post-create decision-points report instead of an upfront Q&A — **not whether it happens.** Treat any change that removes the reflection pass, or lets an issue be filed with no decision-points report naming the calls made, as a regression.

Run this reflection pass on **every** issue, before and after drafting:

1. **Scope check (narrow):** "Is this tighter than it sounds — is the real ask just X?"
2. **Scope check (expand):** "Is there an adjacent concern (Y) that should ride along so the change is coherent?"
3. **Split check:** "This sounds like 2+ distinct issues — should it be split into subsidiary issues?"
4. **Sizing check (subagent fit):** "This is one coherent concern — but can one Phase A/B/C pipeline land it as one reviewable PR?"
5. **Ambiguity:** name any concrete word/phrase whose meaning materially changes the issue.

Also **surface assumptions explicitly**: when the description leaves something implicit, name the assumption you encoded rather than burying it silently.

### The sizing check — what it catches that the split check doesn't

The split check asks whether the ask is **two things**. The sizing check asks whether it is **too much of one thing**. They are different failures: "build the landing page and all its sections" is a single coherent concern *and* four PRs' worth of work. A coherence-only split check waves it through, the issue lands as a feature-sized monolith, and every downstream venue decision inherits the bad sizing (#1192).

The bar is **`/subagent` Step 4 criterion 3 — the subagent-fit sizing bar**: one Phase A/B/C pipeline, one reviewable PR, one review cycle, a bounded slice. That criterion is the single definition — **cite it, never re-derive it here.** It travels inline inside `/subagent`, so it needs no fallback read; only its rationale (`too-big-recalibration-2026-07.md`, read through the standard candidate order — `portable-skill-resolution.md`) does, and being rationale-only its absence is a one-line `DEGRADED:` note, never a reason to skip the check.

**It counts deliverables, not bulk** — and `/subagent` Step 4's not-a-disqualifier list governs here unchanged, so a big-sounding ask that yields one deliverable ("rename this across the whole repo") clears the bar comfortably. The capture-time consequence worth naming: splitting on bulk just fragments one PR into four.

**Judge from the body, not the labels.** What the ask itself describes decides sizing — how many independently shippable deliverables it names, how many surfaces it spans. A `size:*` or `complexity:*` label, where one exists, is a **tie-break only**: it can settle a genuinely balanced call, never overrule what the description plainly says.

**The second trigger: time (issue #1680).** The deliverable count is not the only way an ask can be too much of one thing. **A planning bound above `SPLIT_OVER_MIN` is a split trigger in its own right**, and it fires even when the ask names exactly one deliverable. The comparison is **strict `>`** — a bound of exactly 180 is not over 180 and changes nothing.

Read both knobs from the one place that owns them rather than typing a number into this skill (`pm-config.md` `## Budget`; cascade and ranges in `split-thresholds.sh --help`):

<!-- test-anchor: issue-maker-sizing-time-trigger -->
```bash
SPLIT_THRESHOLDS=""
for candidate in \
  "$HOME/.claude/skills-worktree/.claude/scripts/split-thresholds.sh" \
  "$HOME/.claude/scripts/split-thresholds.sh" \
  ".claude/scripts/split-thresholds.sh"; do
  [ -x "$candidate" ] && { SPLIT_THRESHOLDS="$candidate"; break; }
done
SPLIT_OVER_MIN=180; INCREMENT_BOUND_MIN=120   # documented shipped defaults
if [ -n "$SPLIT_THRESHOLDS" ]; then
  # ONE read, both knobs. They must be coherent with each other (the slice bound
  # strictly below the split line), and two reads could in principle straddle a
  # config edit and produce a pair the helper would have rejected as one.
  # Parsed with jq, never `eval`: eval would execute whatever the helper printed.
  TARGET_REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || TARGET_REPO_ROOT=""
  CHECKOUT_ORIGIN=""
  if [ -n "$TARGET_REPO_ROOT" ]; then
    CHECKOUT_ORIGIN=$(git -C "$TARGET_REPO_ROOT" remote get-url origin 2>/dev/null) || CHECKOUT_ORIGIN=""
  fi
  case "$CHECKOUT_ORIGIN" in
    https://github.com/*) CHECKOUT_REPO=${CHECKOUT_ORIGIN#https://github.com/} ;;
    ssh://git@github.com/*) CHECKOUT_REPO=${CHECKOUT_ORIGIN#ssh://git@github.com/} ;;
    git@github.com:*) CHECKOUT_REPO=${CHECKOUT_ORIGIN#git@github.com:} ;;
    *) CHECKOUT_REPO="" ;;
  esac
  CHECKOUT_REPO=${CHECKOUT_REPO%.git}
  THRESHOLDS_JSON=""
  if [ -n "$TARGET_REPO_ROOT" ] && [ "$CHECKOUT_REPO" = "$REPO" ]; then
    THRESHOLDS_JSON=$("$SPLIT_THRESHOLDS" --json --path "$TARGET_REPO_ROOT" 2>/dev/null) || THRESHOLDS_JSON=""
  else
    echo "DEGRADED: current checkout does not match $REPO; target thresholds are unavailable, using defaults 180/120" >&2
  fi
  S=$(printf '%s' "$THRESHOLDS_JSON" | jq -r '.split_over_min // empty' 2>/dev/null) || S=""
  B=$(printf '%s' "$THRESHOLDS_JSON" | jq -r '.increment_bound_min // empty' 2>/dev/null) || B=""
  # Both or neither: a half-applied pair is the incoherent state the helper's own
  # gate exists to prevent, so a partial read keeps BOTH documented defaults.
  if [ -n "$S" ] && [ -n "$B" ] \
     && [ -z "${S//[0-9]/}" ] && [ -z "${B//[0-9]/}" ] && [ "$B" -lt "$S" ]; then
    SPLIT_OVER_MIN="$S"; INCREMENT_BOUND_MIN="$B"
  else
    # Resolved-but-unusable is a DIFFERENT failure from not-found, and it gets its
    # own line: falling back to the defaults in silence here would hide a broken
    # helper behind numbers that look deliberate.
    echo "DEGRADED: split-thresholds.sh returned no usable thresholds — using defaults 180/120" >&2
  fi
else
  echo "DEGRADED: split-thresholds.sh not found (checked all three paths) — using default thresholds 180/120" >&2
fi
```

**Where the bound comes from at capture time.** You are drafting the estimate in this same pass (Step 5's `## Estimate`), so the bound is the one you are about to publish. Two things put a bound above the line. The ordinary one is **Heavy**, whose 300 already clears it with no adjustment at all — so a Heavy ask reaches the split question by default. The other is an explicit move past Heavy: the `XL` row (`Est: 180–360 min · plan on 360`), a `complexity:XL` / `tier:XL` / `size:XL` / `size:XXL` label as tie-break — all four, the set `estimate-resolve.sh` and `/start-issue` resolve to that row — or a recalibrated actual. Standard's 180 and Light's 90 never fire it **at the default threshold** — the comparison is always the resolved `SPLIT_OVER_MIN`, never the literal 180, so a lowered knob brings them in and the block above is what decides. **Never infer XL from description keywords** ("full day", "whole subsystem"): `tier-inference.md` tops out at Heavy deliberately, and keyword-inferred length would force splits on asks that have no seam to split on.

**What the time trigger does — and the one case where it declines.** With a **natural seam**, it behaves exactly like the deliverable trigger: file an ordered increment chain (Step 5 for the body, Step 8 for the links and the 5-increment cap, Step 9a for the report), each increment carrying its own `## Estimate` with a bound **at or under `INCREMENT_BOUND_MIN`**. With **no obvious seam**, do **not** force one: file the single issue carrying its long estimate line, and report the long estimate as a decision point (Step 9a) naming the bound and that no clean seam was found. A chain with a broken seam — increments that are not independently mergeable — costs more than one long pipeline, so reporting beats forcing here.

**Fails the bar → file a chain, not a monolith** — an ordered set of increment issues, each independently mergeable and each saying where its slice ends (Step 5 for the body, Step 8 for the links and the 5-increment cap, Step 9a for the report, Step 9c for the hand-off). **Clears the bar → nothing changes.** Small asks are untouched: no chain, no commentary, no mention of sizing at all.

**Where the reflection goes.** In default mode you make these calls yourself and **report them as decision points after filing** (Step 9a) — the user reads what you decided and can `/update #N` or `close #N` in one step if a call was wrong (issues are cheap to change). Ask up front **only** when a call is genuinely blocking: the ask spans two clearly separate issues and filing one combined issue would be actively wrong, a word is so ambiguous the body cannot be written without it, or the sizing check would need **more than 5 increments** (Step 8's cap — the one case where the count itself is the question). Bias hard toward filing and reporting — a blocking question is the rare exception, not the rhythm. A sizing split *within* the cap is not one of these: file the chain and report it (Step 9a).

**Rapid-fire override (leaner escape hatch).** Rapid-fire — per thread (`/issue-maker rapid-fire`, `"switch to rapid-fire mode"`) or per issue (`"just file it"`, `"skip the commentary"`) — is now the *leaner* of two auto-opening modes, not "the one without the gate" (default has no gate either). It never asks about **scope or ambiguity** — not even on a genuinely ambiguous call — and emits a terser report: the canonical summary table (Step 9a), optionally a one-line summary, then the closing URL as the final line — without the decision-points elaboration. It still auto-applies labels, still emits the 7-section body, still prints the summary table, still prints the closing URL. **Of the report's three parts, the decision points are the only one rapid-fire trims** — the table is always on, in both modes. **It also still runs the full reflection pass, sizing check included — both of its triggers, deliverable count and time** (#1680) — rapid-fire trades away *report verbosity*, never a judgment, so an oversized ask still becomes an increment chain. Its terser report is where the difference shows: a seamless long ask still files as one issue and still carries the long estimate line, but the decision point naming that estimate is trimmed with the rest of the elaboration.

Rapid-fire keeps exactly **two hard bars in the create flow**, and neither is a scope question — both are "this would create a mess that's tedious to undo," which is why the leaner mode keeps them:

1. **Exact title match** on dedup (default pauses on strong *or* exact — Step 4).
2. **More than 5 increments** in a chain (Step 8's cap).

At either bar rapid-fire stops and asks, in one terse line rather than default's fuller framing. Outside the create flow, **retracting a member of an increment chain** (Step 12) also stops for an answer in both modes — for the same reason, and it is the only such call. Switch back with `"switch to default mode"`.

## Issue body tone & audience (default — NON-NEGOTIABLE)

Issue bodies are read by collaborators, future maintainers, and anyone deciding whether to pick up the work. The lead sections — **Background**, **Problem**, **Proposed solution** — are **functional-and-feature-focused, conversational, and human-readable**. Lead with what the workflow / user / collaborator experiences today and what would change — not with an implementation walkthrough.

Defaults you MUST honor for those three sections:

- **No implementation walkthrough unless explicitly asked.** No file paths, no function names, no API/endpoint names, no step-by-step "edit X then Y then Z." The Proposed solution describes *what behavior the change enables*, not the mechanism.
- **Conversational phrasing.** Active voice, second person where it helps ("you can now…"), the way you'd explain it to a teammate over coffee. Prefer outcome voice ("PRs now merge themselves once review is clean") over engineering voice ("Adds a polling loop").
- **Jargon only when load-bearing.** If a specific file, script, or endpoint *is* the point of the issue, name it. Otherwise omit it.

**Where implementation specifics DO go** (they're not banned — just not in the lead): `## Acceptance Criteria` (implementer-facing, precise — paths, exit codes, checklists), `## Test Plan` (concrete scenarios with files/commands), `## Notes / Open questions` (design rabbit holes), and an optional `## Implementation notes` subsection at the bottom for deep hand-offs.

**Explicit-ask override.** If the user explicitly asks for technical depth — phrases like **"be specific about files"**, **"do a deep technical issue"**, **"include the file list"**, **"name the functions"** — flip the lead sections to technical-first **for that one issue** only, putting the walkthrough up top. Default stays functional-first.

---

## Step 3: Reflect, then draft, then auto-file (the create flow)

For each genuinely new ask, reset `IS_INCREMENT=false`, `CHAIN_ID=""`, and `CHAIN_JSON=null` before reflection; recovery of an in-progress chain restores `.active_chain` instead. For each issue the user describes (see Step 6 for batches):

1. **Reflect** — run the reflection pass from the top-level rule (narrow / expand / split / **sizing** / ambiguity / assumptions). You make these calls yourself; they resurface as decision points in the report (Step 9a). Ask up front only on a genuinely blocking call (top-level rule); otherwise proceed. Record the deliverable-fit result now, but do not finalize the single-versus-chain decision before computing the estimate in sub-step 4.
2. **Draft a minimal proposed title and problem statement** from the reflection before duplicate screening; these are the required inputs to the body-aware search. Do not file or publish them yet.
3. **Dedup search** (Step 4) — use that title and problem statement to surface likely duplicates; pause before filing only on a strong or exact match.
4. **Complete the body draft** using the canonical 7-section template (Step 5), honoring the tone defaults. Detect any explicit-ask override and flip to technical-first for that issue only. For the first tier inference, read `references/tier-inference.md` relative to the installed skill root; reuse it in the current context. While drafting, infer the tier from all the signals you know about the issue — the user's description, the file paths and AC items you are about to write, and whether the issue touches rules/skills/orchestration (same Heavy/Standard/Light classification as `tier-inference.md`). Store the result as `ISSUE_TIER`. Look up the estimate in `time-estimates.md` and include it in the body's mandatory `## Estimate` section. Accumulate `ISSUE_TIER` toward the session's running maximum `BATCH_TIER` (Heavy beats Standard beats Light) so Step 9b can use `BATCH_TIER` without re-inferring. `ISSUE_TIER` is also stored in the log entry (Step 9) so compaction recovery can restore `BATCH_TIER`.
   **Finalize sizing only after the estimate exists:** compare the actual `plan on` bound with the resolved `SPLIT_OVER_MIN` using strict `>`, independently of the deliverable-fit result. Either a failed deliverable bar or an over-threshold bound with a natural seam selects a chain. An over-threshold bound with no independently mergeable seam stays single and records that decision point. Only now load `batch:chain`, `create:increment-draft`, and `create:crossrefs` if a chain was selected; draft and estimate each increment at or under `INCREMENT_BOUND_MIN`, enforce the five-increment cap before any filing, then run sub-steps 2–7 for each increment head first. Exact-threshold single-deliverable work stays single.
5. **Title** — concise, **≤70 characters**. If it would exceed 70, auto-trim and note the trim in the decision points.
6. **Labels** (Step 7, auto-applied) and **cross-references** (Step 8).
7. **Create automatically** — no full-body reprint, no "Create this issue? (Y/n/edit)" gate. Record in the log (Step 9).
8. **Report + print the URL** — emit the concise summary + decision points (Step 9a) and **print the URL as the closing line** (Step 9). The **canonical summary table** (Step 9a) closes the filing: immediately, for a single issue; once after the last member, for a batch or a chain.

**This per-issue loop is also the one-shot entry** (#1766). Sub-steps 1–7, without the session log, the mode banner, Step 2's refusal, or Step 9c's offer, are written up in `references/one-shot-filing.md` for a caller that files one idea without entering capture mode — the desk's `idea:` intent. Both create through the same `issue-file.sh` (Step 5), so a rule changed here changes there in the same edit: keep that file's summary in step with Steps 3–8.

**The hand-off is not part of this per-issue loop.** Step 9c fires **once, after the last issue of the batch is filed** (Step 6) — never after the first. Emitting it mid-batch offers a launch the user can click before the remaining issues exist, and a hand-off that has already been clicked cannot absorb them (Step 9c's refresh rule covers only an *unclicked* offer). A single-issue session reaches "after the last issue" immediately, so nothing is delayed there.

---

## Step 5: Canonical issue body — the 7-section shape

Every issue the skill creates includes all seven sections (presence is mandatory):

```markdown
## Background
<functional, conversational context — what happens today, who it affects>

## Problem
<what's wrong / missing, framed by impact — no implementation walkthrough by default>

## Proposed solution
<what behavior the change enables — outcome voice, not mechanism>

## Acceptance Criteria
- [ ] <implementer-facing, precise — paths/exit codes/checklists allowed here>

## Test Plan
- [ ] <concrete scenarios with files/commands>

## Notes / Open questions
- <design rabbit holes, tradeoffs, decisions to make>

## Estimate

Est: {lo}–{hi} min · plan on {bound}
```

**`## Estimate` — mandatory, computed before body drafting:** Infer the tier from the
issue's signals (same vocabulary and rules as `tier-inference.md` / Step 9b — Heavy,
Standard, or Light), then look up the estimate line in `time-estimates.md` (candidate
order: `$HOME/.claude/skills-worktree/.claude/reference/time-estimates.md`, then
`$HOME/.claude/reference/`, then `.claude/reference/`). Use the table row matching the
tier; adjust only when scope clearly warrants it and state the reason in one sentence.
If `time-estimates.md` does not resolve, print
`DEGRADED: time-estimates.md not found (checked all three paths) — using inline fallback`
and use: Light `Est: 60–90 min · plan on 90`, Standard `Est: 120–180 min · plan on 180`,
Heavy `Est: 210–300 min · plan on 300`, XL `Est: 180–360 min · plan on 360`. Never omit
this section. XL is in that list so a **deliberate** upward adjustment survives the
degraded path — it is never a tier the inference picks (`tier-inference.md`).

Optional sections, appended when relevant:

- `## Related Issues` — cross-references (Step 8).
- `## Related Files` — auto-added footer when the user names paths under `.claude/rules/…` or `.claude/skills/…` (or any concrete repo path).
- `## Implementation notes` — only for deep hand-offs, or when the explicit-ask override is in effect (then the walkthrough leads).

**Complexity hint (optional):** if the user states or the description clearly implies a tier, tag the issue with `complexity:quick|light|medium|heavy` (only if that label exists in the repo — see Step 7) so `/prompt` and `/pm` can pick it up later.

**Filing is a separate phase.** Finish the draft and dedup first, then resolve/read `create:file` for label validation and the sole `issue-file.sh` invocation. This module performs no remote writes.
