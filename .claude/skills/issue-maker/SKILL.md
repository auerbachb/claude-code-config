---
name: issue-maker
description: Capture-only thread mode for drafting and opening well-structured GitHub issues. Puts the thread into issue-capture mode — the only job is creating, editing, and closing issues (no implementation, no worktrees, no /start-issue). Auto-opens issues (no approval gate) and reports back a concise summary plus the scope calls it made as decision points; creates canonical 6-section bodies with functional-first tone, runs dedup search, auto-applies validated labels, supports batch + cross-references, and prints the issue URL as the closing line of every create/update. After the last issue is filed, offers to run the whole batch inline via /subagent — say yes to execute right here, no to keep issues filed with a chip available on request. Supports /update <N> <statement>, natural-language edit-in-place, and retract. Invoke as `/issue-maker [rapid-fire] [--export-prompt]`.
triggers:
  - open an issue
  - new issue
  - make an issue
  - file an issue
  - track this
  - log this
  - capture this
  - issue-maker
argument-hint: "<issue description | 'batch: ...' | '/update #N: ...' | 'close #N' | rapid-fire | --export-prompt>"
---

# /issue-maker — capture-only issue thread

This skill switches the **whole thread** into issue-capture mode and keeps it there. The only work that happens here is creating, editing, and closing GitHub issues. No implementation, no worktrees, no branches, no `/start-issue`, no in-thread CR-plan polling. Capture mode is a **session invariant** — it never turns off mid-thread.

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

**Fails the bar → file a chain, not a monolith** — an ordered set of increment issues, each independently mergeable and each saying where its slice ends (Step 5 for the body, Step 8 for the links and the 5-increment cap, Step 9a for the report, Step 9c for the hand-off). **Clears the bar → nothing changes.** Small asks are untouched: no chain, no commentary, no mention of sizing at all.

**Where the reflection goes.** In default mode you make these calls yourself and **report them as decision points after filing** (Step 9a) — the user reads what you decided and can `/update #N` or `close #N` in one step if a call was wrong (issues are cheap to change). Ask up front **only** when a call is genuinely blocking: the ask spans two clearly separate issues and filing one combined issue would be actively wrong, a word is so ambiguous the body cannot be written without it, or the sizing check would need **more than 5 increments** (Step 8's cap — the one case where the count itself is the question). Bias hard toward filing and reporting — a blocking question is the rare exception, not the rhythm. A sizing split *within* the cap is not one of these: file the chain and report it (Step 9a).

**Rapid-fire override (leaner escape hatch).** Rapid-fire — per thread (`/issue-maker rapid-fire`, `"switch to rapid-fire mode"`) or per issue (`"just file it"`, `"skip the commentary"`) — is now the *leaner* of two auto-opening modes, not "the one without the gate" (default has no gate either). It never asks about **scope or ambiguity** — not even on a genuinely ambiguous call — and emits a terser report: the closing URL, optionally a one-line summary, without the decision-points elaboration. It still auto-applies labels, still emits the 6-section body, still prints the closing URL. **It also still runs the full reflection pass, sizing check included** — rapid-fire trades away *report verbosity*, never a judgment, so an oversized ask still becomes an increment chain.

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

## Step 1: Establish (or recover) capture mode

The thread's capture state lives in a session log so it survives context compaction.

```bash
mkdir -p "$HOME/.claude/handoffs"
SESSION_ID="${CLAUDE_SESSION_ID:-default}"
LOG="$HOME/.claude/handoffs/issue-maker-${SESSION_ID}-log.json"
```

**If `$LOG` exists (compaction recovery / re-invocation):** read it and lead with a recap before accepting new input — this is the first action after a compaction.

```bash
if [ -f "$LOG" ]; then
  OFFER_ACCEPTED=$(jq -r '.offer_accepted // false' "$LOG")
  jq -r --argjson accepted "$OFFER_ACCEPTED" \
    '"Resuming \(if $accepted then "execution" else "capture" end) mode for \(.target_repo) — \(.mode) mode. \(([.issues[]|select(.status=="open")]|length)) issue(s) opened so far:",
     (.issues[] | "  #\(.number) — \(.title) [\(.status)]" +
                  (if .chip_task_id and ($accepted | not) then " — offer pending"
                   elif .chip_task_id and $accepted then " — offer accepted, running"
                   else "" end))' "$LOG"
fi
```

Offer state survives compaction because it lives in `$LOG` (Step 9c writes `chip_task_id` and `offer_accepted` there, not just in-memory) — the recap line above surfaces it back after a fresh invocation. `chip_task_id` on an issue means a locally-generated offer token was stamped at offer-emit time (not a `spawn_task` return); `offer_accepted: true` means the user said yes and `/subagent` was invoked.

If `OFFER_ACCEPTED` is false, re-affirm: *"Still in capture mode — describe issues to create, or use `/update #N …`, `edit #N …`, or `close #N`."* If `OFFER_ACCEPTED` is true, re-affirm: *"Offer accepted — execution mode active. New issues filed here will be run inline via `/subagent`."* If the log is corrupt/unreadable, warn the user and offer to start a fresh session log.

**If `$LOG` does not exist:** initialize it and print the mode banner.

```bash
REPO=$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || true)
# Mode is seeded from the invocation: `/issue-maker rapid-fire` (or the word
# "rapid-fire" in $ARGUMENTS) starts in rapid-fire; otherwise default.
MODE="default"; case "$ARGUMENTS" in *rapid-fire*) MODE="rapid-fire";; esac
NOW=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
TMP=$(mktemp)
jq -n --arg repo "$REPO" --arg now "$NOW" --arg sid "$SESSION_ID" --arg mode "$MODE" \
  '{schema_version:"1", session_id:$sid, target_repo:$repo, mode:$mode,
    created_at:$now, last_updated_at:$now, issues:[]}' > "$TMP" && mv "$TMP" "$LOG"
```

Banner: *"Thread is now in issue-capture mode. I will only create, edit, or close issues — no implementation, no worktrees, no branches. Describe an issue and I'll open it, then report a quick summary and the scope calls I made."*

**Repo detection (AC):** the `gh repo view` above auto-detects the target repo from cwd. If it returns empty (not a git repo / `gh` failed / ambiguous), **ask the user** which `owner/repo` to target before creating anything, then **persist it to the log** so compaction recovery and later `--repo` calls see it:

```bash
REPO="<owner/repo the user supplied>"
set_log '.target_repo = $v' --arg v "$REPO"   # see the write-log helper below
```

Every `gh issue …` call below passes `--repo "$REPO"`.

### Writing to the session log (one canonical helper)

Every mutation of `$LOG` goes through `scripts/set-log.sh` (skill-local) — an atomic read-modify-write helper. Resolve and bind it once per invocation:

```bash
SET_LOG=""
for candidate in \
  "$HOME/.claude/skills-worktree/.claude/skills/issue-maker/scripts/set-log.sh" \
  "$HOME/.claude/skills/issue-maker/scripts/set-log.sh"; do
  [ -x "$candidate" ] && { SET_LOG="$candidate"; break; }
done
[[ -n "$SET_LOG" ]] || { echo "FATAL: scripts/set-log.sh not found — is the issue-maker skill installed?" >&2; exit 1; }
set_log() { "$SET_LOG" "$LOG" "$@"; }
```

Examples used below: `set_log '.target_repo = $v' --arg v "$REPO"`, `set_log '.mode = $v' --arg v rapid-fire`, and the create/close updates in Steps 9 and 12.

---

## Step 2: Refusal behavior — capture mode holds until acceptance

If the user asks for workflow-advancing work — **"implement"**, **"code this"**, **"fix the code"**, **"create a worktree"**, **"create a branch"**, **"start working on"**, or invokes `/start-issue`, `/fixpr`, `/wrap` — **politely decline in one line and stay in capture mode**:

> "This thread is in capture mode — I only create, edit, and close issues here. Finish filing issues and I'll offer to run them inline, or start a fresh thread with `/start-issue #N`."

**Capture mode holds until the user accepts the end-of-session inline offer (Step 9c).** Since [#1229](https://github.com/auerbachb/claude-code-config/issues/1229) every other thread runs subagent-fit work inline rather than handing it to a new tab (`chip-launching.md` "PM-context inline gate"); this invariant is the exception, scoped to **until acceptance** — not for the thread's lifetime. An accepted offer ends capture mode: the thread becomes execution-capable and runs the filed batch through `/subagent`. Until that acceptance, the thread refuses implement/code/worktree/branch requests and never polls for a CR plan.

Never create worktrees/branches, never edit code, and **never poll for a CodeRabbit plan in this thread** while in capture mode. The repo's `.github/workflows/cr-plan-on-issue.yml` auto-comments `@coderabbitai plan` on the issue itself when it's opened (it skips bot-authored issues); the issue's CR plan lands on the *issue*, asynchronously, with no action needed here. Do **not** post `@coderabbitai plan` yourself and do **not** wait on it.

---

## Step 3: Reflect, then draft, then auto-file (the create flow)

For each issue the user describes (see Step 6 for batches):

1. **Reflect** — run the reflection pass from the top-level rule (narrow / expand / split / **sizing** / ambiguity / assumptions). You make these calls yourself; they resurface as decision points in the report (Step 9a). Ask up front only on a genuinely blocking call (top-level rule); otherwise proceed. **If the sizing check fails**, this one ask becomes an ordered increment chain: run each increment through sub-steps 2–7 below in order, head first, so each one can link to the increment before it (Step 8).
2. **Dedup search** (Step 4) — surface likely duplicates; pause before filing only on a strong or exact match.
3. **Draft the body** using the canonical 6-section template (Step 5), honoring the tone defaults. Detect any explicit-ask override and flip to technical-first for that issue only.
4. **Title** — concise, **≤70 characters**. If it would exceed 70, auto-trim and note the trim in the decision points.
5. **Labels** (Step 7, auto-applied) and **cross-references** (Step 8).
6. **Create automatically** — no full-body reprint, no "Create this issue? (Y/n/edit)" gate. Record in the log (Step 9).
7. **Report + print the URL** — emit the concise summary + decision points (Step 9a) and **print the URL as the closing line** (Step 9).

**The hand-off is not part of this per-issue loop.** Step 9c fires **once, after the last issue of the batch is filed** (Step 6) — never after the first. Emitting it mid-batch offers a launch the user can click before the remaining issues exist, and a hand-off that has already been clicked cannot absorb them (Step 9c's refresh rule covers only an *unclicked* offer). A single-issue session reaches "after the last issue" immediately, so nothing is delayed there.

---

## Step 4: Dedup search

Before creating, search open and recently-closed issues for likely duplicates and surface any matches. Use the shared helper `.claude/scripts/issue-dedup.sh`, which scores **titles and bodies** — a title-only search misses the case that motivated it (issue #647 restated issue #638's second acceptance criterion while sharing almost no title words; issue #652):

```bash
# 2–6 significant keywords from the proposed title AND the problem statement —
# body scoring is what catches a duplicate that was worded differently.
KEYWORDS="<significant words from the title and problem statement>"
ISSUE_DEDUP=""
for candidate in \
  "$HOME/.claude/skills-worktree/.claude/scripts/issue-dedup.sh" \
  "$HOME/.claude/scripts/issue-dedup.sh" \
  ".claude/scripts/issue-dedup.sh"; do
  if [ -x "$candidate" ]; then ISSUE_DEDUP="$candidate"; break; fi
done
DEDUP_RC=0
if [ -n "$KEYWORDS" ] && [ -n "$ISSUE_DEDUP" ]; then
  "$ISSUE_DEDUP" "$KEYWORDS" ${REPO:+--repo "$REPO"} || DEDUP_RC=$?
fi
# Only exit 1 means "searched, found nothing". Exit 2/4 (usage, gh/env failure)
# means the check did not run — fall back below and say so; never present an
# unrun check as a clean result.
```

- **Guard:** if no significant keywords remain, skip the dedup search.
- **Helper missing, or `DEDUP_RC` ≥ 2:** fall back to the title-only `gh issue list --search "$KEYWORDS in:title"` over open and recently-closed issues, and say so in one line when surfacing results — `DEGRADED: issue-dedup.sh not found (checked all three paths) — title-only duplicate search` for the missing-helper case, naming the exit code instead when the helper ran and failed. Never present an unrun or downgraded check as a clean result.
- **Filter same-run increment siblings out of the candidate list first** — before anything below reads a "top" candidate. See the sibling bullet at the end of this list for why; the ordering matters because every rule below acts on whichever candidate ranks first.
- **Interpreting matches:** `/issue-maker` always has a human in the loop, so it only ever *surfaces* candidates — it never auto-comments in place of filing. Use the strong/weak/none thresholds in `autofile-dedup.md` — read through the standard candidate order, `$HOME/.claude/skills-worktree/.claude/reference/` first, then `$HOME/.claude/reference/`, then `.claude/reference/` (`portable-skill-resolution.md`) — to classify the **top surviving** candidate: a **strong match** or an **exact title match** is a genuine pause point; weak/ambiguous matches are not.
- **Default mode — pause only on a strong or exact match:** if the top candidate clears that bar, surface it and ask *"Looks like a duplicate of #N — file anyway? (y/N)"* before creating. On a weak/ambiguous match, **do not block** — file, and name the near-duplicate as a decision point (Step 9a: "possibly overlaps #N"). No match → file normally.
- **Rapid-fire:** show any matches but proceed unless there is an **exact title match** (then block and ask).
- **Siblings in the same increment chain are never duplicates of each other.** Increments share a theme prefix and most of their keywords by design, so filing `Landing page 2/4` right after `Landing page 1/4` will surface increment 1 as a strong match. That is the chain working, not a duplicate. **Drop every candidate sharing this issue's `chain_id` (Step 9's log record) from the list, then classify what remains** — an exclusion, not an override. Match on `chain_id`, never on the theme prefix: two unrelated chains can share wording, and a re-worded title would silently stop matching. Excluding them only after the top candidate is chosen would let a sibling outrank a genuine duplicate and carry the "file anyway" verdict with it, so a real duplicate ranked second would never be evaluated at all. Note the skipped siblings in one line; duplicates *outside* the chain still pause normally, in both modes. If nothing survives the filter, that is a clean "no match" — file normally.

---

## Step 5: Canonical issue body — the 6-section shape

Every issue the skill creates includes all six sections (presence is mandatory):

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
```

Optional sections, appended when relevant:

- `## Related Issues` — cross-references (Step 8).
- `## Related Files` — auto-added footer when the user names paths under `.claude/rules/…` or `.claude/skills/…` (or any concrete repo path).
- `## Implementation notes` — only for deep hand-offs, or when the explicit-ask override is in effect (then the walkthrough leads).

**Complexity hint (optional):** if the user states or the description clearly implies a tier, tag the issue with `complexity:quick|light|medium|heavy` (only if that label exists in the repo — see Step 7) so `/prompt` and `/pm` can pick it up later.

### Increment issues — the variant shape for a chain (sizing check failed)

When the top-level rule's sizing check fails, each increment is a normal 6-section issue with two additions. An increment is not a sub-task: it is a **complete, independently mergeable issue** that happens to be one slice of a larger theme.

**Title — carry the parent theme and the position.** `{Parent theme} {i}/{n}: {what this slice delivers}` — e.g. `Landing page 1/4: hero + layout shell`, `Landing page 2/4: services page`. The theme prefix is what keeps a backlog of increments scannable instead of looking like four unrelated tickets.

The existing **≤70-character** title rule still applies to the composed whole, so budget for all three parts rather than trimming only the tail:

1. **Reserve the `{i}/{n}` marker** — never trimmed, never abbreviated; it is what makes the chain readable.
2. **Bound the parent theme** to roughly the first 25 characters, and keep it identical across every increment in the chain — a theme that shifts wording between increments defeats the point of having one.
3. **Trim the slice description** to fit what's left.

If the title still exceeds 70 after all three, the theme itself is too long — shorten it once, apply that shortened form to the whole chain, and note the trim in the decision points.

**Acceptance Criteria — one boundary line, always.** Every increment's `## Acceptance Criteria` opens with a line stating where the slice stops. Non-final increments hand the remainder forward; the **final** increment has nothing to hand forward and says so instead:

```markdown
- [ ] This increment ends at <the boundary>; <what's explicitly out of scope> lands in the next increment.
```

```markdown
- [ ] Final increment — this completes <the parent theme>; it ends at <the boundary>, with nothing deferred past it.
```

The boundary line is what keeps a pipeline from scope-creeping across the whole theme — without it, an agent picking up increment 1 has nothing telling it to stop at the hero. Write the boundary in concrete terms ("ends at a static hero and layout shell — no services content, no form"), never as a vague "part 1 of the work." Never point the last increment at a successor that will not exist.

Everything else is unchanged: the same functional-first tone, the same six sections, the same labels, the same capture-mode footer.

**Capture-mode footer:** append a trailing line to every created body so capture-mode issues are identifiable:

```
_Captured via /issue-maker._
```

Create with a heredoc to preserve formatting:

```bash
BODY=$(cat <<'EOF'
## Background
...
_Captured via /issue-maker._
EOF
)
ISSUE_URL=$(gh issue create --repo "$REPO" --title "$TITLE" --body "$BODY" $LABEL_FLAGS)
ISSUE_NUMBER=$(echo "$ISSUE_URL" | grep -oE '[0-9]+$')
```

---

## Step 6: Batch input

If the user describes multiple issues in one message (a numbered/bulleted list, or a `batch:` prefix), treat each as its own issue: run the full per-issue flow (reflect → dedup → draft → labels → auto-create → report) **sequentially**, one `gh issue create` per issue. After the batch, print a summary table (number, title, labels, URL) — each URL still a clickable link.

**Every issue is still created; the session hands them off once.** Since [#1229](https://github.com/auerbachb/claude-code-config/issues/1229), Step 9c emits **one batch hand-off per capture session** covering every open issue filed in it — not one chip per issue, and not `FREE` chips out of N. A batch of six issues yields six issues and **one** hand-off. Resolve `active-work-cap.sh` to the first executable of `$HOME/.claude/skills-worktree/.claude/scripts/active-work-cap.sh`, `$HOME/.claude/scripts/active-work-cap.sh`, `.claude/scripts/active-work-cap.sh` — this repo may carry no `.claude/` directory — and read its census **once per session**: the default output line gives `CAP`, `ACTIVE`, and `FREE` together, all of which the deferral message below needs (`chip-launching.md` "Repo-wide active-work cap").

That single read now gates a single offer. **`FREE > 0` → offer the hand-off; `FREE == 0` → defer it**, naming the count and the scope: "hand-off deferred — repo-wide active-work cap ({ACTIVE}/{CAP} in motion across all threads)". Every issue is still created, logged, and its URL printed; only the hand-off is withheld, and it becomes offerable again as active work drains. Offering one chip per issue with nothing counted against it is what produced roughly twenty simultaneously active threads on 2026-08-18 (#1191); one hand-off cannot reproduce that shape, because the thread it opens bounds its own launches by `min(pipeline_ceiling, active_work_cap)`.

**An increment chain is covered by the same one hand-off.** The sizing check above turns one oversized ask into up to five increment issues — exactly the shape that used to emit five chips. The chain is ordered and its increments land in sequence, so the hand-off **names the chain and its order** rather than chipping the head and queuing the tail; the launched thread's `/subagent` Step 6.0b serializes them from there.

**What the hand-off costs the count, and why that is the right trade.** Step 9c stamps the hand-off's `task_id` on **every** issue it covers, because that is what `active-work-cap.sh` and the cross-skill dedup read per issue (`chip-launching.md` "Cross-skill chip visibility") — without it, `/wave` or `/pm` would offer a second launch for work this hand-off already carries. The census therefore counts a covered issue as one unit of pending work, exactly as it counted a per-issue chip before. The visible consequence: a session filing more issues than `FREE` can push `ACTIVE` past `CAP`, which **defers the next session's hand-off** until work drains. That overshoot is bounded to one session and self-corrects, and it is the right side to err on — the alternative, covering only `FREE` of the issues, strands the rest with no launch path at all, which AC5 of #1229 exists to prevent. Concurrency itself is never overshot: the launched thread still runs at most `min(pipeline_ceiling, active_work_cap)` at a time.

**If the script does not resolve, still offer the one hand-off.** Print `DEGRADED: active-work-cap.sh not found (checked all three paths) — offering the batch hand-off without a repo-wide bound` and offer it. The hand-off is a single offer whose thread applies its own ceiling, so it is the safe shape to fall back to; withholding it would strand every issue in the session. A **non-zero exit** from a script that did resolve means a count source could not be read — treat it as `FREE = 0` and defer the hand-off, naming the read failure rather than a fabricated count.

---

## Step 7: Label suggestion

Suggest labels from the content, but only labels that actually exist in the repo.

```bash
REPO_LABELS=$(gh label list --repo "$REPO" --json name --jq '.[].name')
```

Keyword → label mapping: `bug`/`fix`/`broken` → `bug`; `feature`/`add`/`new` → `feature`; `refactor`/`clean` → `refactor`; `docs`/`documentation` → `docs`; `skill` → `skill`; `rule` → `rule`. Intersect suggestions with `$REPO_LABELS` and drop any that don't exist.

- **Default mode:** auto-apply the validated suggestions (intersected with `$REPO_LABELS`) and name them in the decision points (Step 9a) — no separate accept prompt.
- **Rapid-fire:** auto-apply the validated suggestions the same way (they just don't get a decision-points line — see the terser report).

Pass accepted labels as repeated `--label` flags (`LABEL_FLAGS="--label skill --label docs"`).

---

## Step 8: Cross-references

Detect `#N` mentions in the user's description and verify each exists (`gh issue view N --repo "$REPO" --json number` succeeds). Add a `## Related Issues` section using phrasing that matches the user's intent:

- "related to #N" → `- Related to #N`
- "depends on #N" / "blocked by #N" → `- Depends on #N`
- "blocks #N" → `- Blocks #N`

### Linking an increment chain (sizing check failed)

File the increments **in order**, head first, so each one can reference the number of the increment before it. Every increment after the head gets a `## Related Issues` entry pointing at its **immediate predecessor** — not at the head, and not at all of them:

```markdown
## Related Issues

- Depends on #<previous increment>
```

This is the existing `- Depends on #N` phrasing above, reused deliberately rather than invented: `/pm` Step 1B.3 collects `depends on #N` as a blocked-direction marker, and `/wave` 5.1 consumes that same set and **excludes any candidate blocked by an open, unmerged issue.** A predecessor link is therefore what makes `/wave` admit only the chain head and serialize the rest — inventing a new marker would leave the chain looking parallelizable.

**Cap: at most 5 increments per ask without pausing.** Five is a chain; twenty is a confetti backlog nobody will triage. If an ask genuinely needs more than 5, **stop before filing anything** and say so — name the count you'd need and what the increments would be, and ask whether to file them all or re-cut the theme into fewer, larger slices. This mirrors the Step 4 dedup pause bar: clear the bar and proceed silently, exceed it and ask first.

**Both modes stop at this bar.** It is one of rapid-fire's two hard bars, enumerated in the "Rapid-fire override" paragraph of the top-level rule — rapid-fire asks in one terse line instead of default's fuller framing, but it never files a 6+ chain unasked and never silently re-cuts one down to 5 on its own. Re-cutting changes what gets built; that call is the user's.

---

## Step 9: Record + offer the session's coding hand-off + print the URL (the closing-line rule)

After **every** create — and after every update/close — append/refresh the session log and **print the GitHub issue URL as a clickable markdown link as the final line of the response.** This rule is absolute: the link is never buried in prose, never mid-paragraph — it is the closing line.

Build the labels as a JSON array from the accepted labels (the same set passed via `--label` flags in Step 5/7), then record the issue through the `set_log` helper:

```bash
# ACCEPTED_LABELS holds the labels applied to this issue, one per line
# (empty if none). Convert to a JSON array — `[]` when there are none.
LABELS_JSON=$(printf '%s\n' "$ACCEPTED_LABELS" | jq -R . | jq -s 'map(select(length>0))')

set_log '.issues += [{number:($n|tonumber), title:$t, url:$u, labels:$labels,
                      created_at:$ts, status:"open", chip_task_id:null, chain:$chain}]' \
  --arg n "$ISSUE_NUMBER" --arg t "$TITLE" --arg u "$ISSUE_URL" \
  --arg ts "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" --argjson labels "$LABELS_JSON" \
  --argjson chain "$CHAIN_JSON"
```

**`CHAIN_JSON` — `null` for an ordinary issue, an object for an increment.** A standalone ask sets `CHAIN_JSON=null` and nothing below applies. An increment records which chain it belongs to and where it sits:

```bash
# Increment issues only. CHAIN_ID is minted once per chain (any stable string —
# the head's slug is fine) and is IDENTICAL across every increment in it.
CHAIN_JSON=$(jq -nc --arg id "$CHAIN_ID" --argjson i "$POSITION" --argjson n "$TOTAL" \
  '{chain_id:$id, position:$i, total:$n}')
```

**`chain_id` is what makes the chain recoverable.** Sibling detection (Step 4), the queued-successor note (Step 9c), and retraction (Step 12) all resolve membership by matching `chain_id` in `$LOG` — never by theme text or position number, which collide across unrelated chains and cannot survive a re-worded title. It also survives compaction: the log is re-read in Step 1, so a chain interrupted mid-filing is still identifiable afterwards, which in-context memory alone would not give you.

### Step 9a: The post-create report — summary + decision points

The report is what replaces the old draft-reprint-and-approve gate, and it is the safety valve that makes auto-filing low-risk. Emit it **immediately after logging the issue** — before the hand-off (Step 9c) and before the closing URL. Two short parts:

1. **Summary (1–3 sentences).** What issue you just opened, in plain functional terms — the same voice as the body's lead sections, not a section-by-section readout.
2. **Decision points (1–3 sentences).** The actual calls you made that the user might want to revisit — scope you narrowed or expanded, a split you considered but did *not* make, **a sizing split you did make**, assumptions you encoded, the labels you auto-applied, a weak-duplicate pointer (Step 4). **Name the concrete call** (e.g. *"scoped to the create flow only; assumed rapid-fire keeps its narrower dedup bar; applied `skill`, `enhancement`"*), never boilerplate like "made some scope decisions." If you genuinely made no non-obvious call, say so in one line rather than padding.

   **A sizing split is a decision point like any other** — report it once, on the chain head, naming the count and *why* the ask exceeded one pipeline: *"sized as a 4-increment chain because one pipeline can't land hero, services page, contact form, and SEO metadata as one reviewable PR."* Say what the increments are and that they're linked; the user re-cuts the chain with `/update` or `close` if the boundaries are wrong. Successor increments do not each repeat the split rationale.

Close by reminding the user the issue is cheap to change — a wrong call is one `/update #N …` or `close #N` away. This report is emitted **in addition to**, never in place of, the closing URL line (Step 9). **Rapid-fire** emits a terser version instead: the closing URL, optionally a one-line summary, and no decision-points elaboration.

Tone precedent: `/wrap`'s terse "here's what I decided — flag anything wrong" framing and `issue-planning.md`'s number/title/rationale/link quartet. Keep the whole report to a few lines; its value is signal density, not length.

### Step 9b: Infer a coding tier (for the offer's tier statement and model step-up warning)

`/issue-maker` does no tier classification during capture, but the inline-run offer (Step 9c) names the batch's inferred tier so the user knows what model/effort the work warrants. Infer the tier directly from the body just drafted in Step 5. Full signal definitions, tier table, and evaluation rules: `references/tier-inference.md`. Summary:

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

**Repo-wide cap (before the offer).** Step 6 owns the arithmetic and reads the census once per session: offer inline while `FREE > 0`; at `FREE == 0` **defer**, naming `{ACTIVE}/{CAP}` and the scope. If the script does not resolve, print `DEGRADED: active-work-cap.sh not found (checked all three paths) — offering inline without a repo-wide bound` and offer it anyway (a single inline run applies its own ceiling; withholding it strands every issue). A **non-zero exit** from a script that did resolve means the count could not be read — treat it as `FREE = 0` and defer, naming the read failure.

**Offer stamp.** When the offer is emitted, generate a local offer token (e.g. `offer-$(date +%s%N)`) and write it into `chip_task_id` on every open issue the offer covers — this is what stops `/wave` or `/pm` from launching a second offer for work already covered. The stamp is **not** a `spawn_task` return; it is a locally-generated string.

```bash
OFFER_TOKEN="offer-$(date +%s%N)"
set_log '(.issues[] | select(.status == "open") | .chip_task_id) = $tok' --arg tok "$OFFER_TOKEN"
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

In **rapid-fire mode**, use terser framing: *"Run {N} issue(s) inline ({TIER})? [yes/no]"*

**On yes — acceptance.** Invoke `/subagent #{a} #{b} …` first; if it succeeds, end capture mode (`offer_accepted: true`) and clear `chip_task_id` from all covered issues so they are no longer counted as pending offered work in the cap census. If the invocation fails, leave `offer_accepted` unset so the offer can be re-attempted or withdrawn via Step 12. Issue-maker adds no orchestration: claims, the pipeline ceiling, Step 6.0b chain serialization, and too-big routing all belong to `/subagent`.

```bash
# /subagent #{a} #{b} ...  ← invoke first
set_log '.offer_accepted = true'
set_log '(.issues[] | select(.status == "open") | .chip_task_id) = null'
```

**On no — decline.** Leave all issues filed and launch nothing. Clear `chip_task_id` from all covered issues so they are no longer counted as pending offered work in the cap census. The inline offer is withdrawn; the on-request hand-off block below remains available on explicit request (`"give me the chip"`, `"print the hand-off"`, etc.).

```bash
set_log '(.issues[] | select(.status == "open") | .chip_task_id) = null'
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

**On-request hand-off (chip or fallback block).** When the user explicitly requests a chip or printed block — `"give me the chip"`, `"print the hand-off"`, `"I want to run this in a new thread"` — emit the block below. This is no longer the default session ending; it is an on-request fallback. Its content is unchanged and required verbatim for lint compliance.

**Model + effort contract (non-negotiable for the on-request block):** The block `prompt` MUST open with the `**Model:**` line from Step 9b, then that step's `**Effort:**` line, then the model-guard preamble from `chip-launching.md` — no blank line between the three. Both values are the session's *most demanding* tier (Step 9b). The visible short summary MUST repeat both lines per `chip-launching.md` "Short-summary transcript format". When the parent thread is on Fable and the block recommends a different model, add the pre-click warning from `chip-launching.md` "Upstream requirement."

```
**Model:** {MODEL from Step 9b} — {one-line reason, e.g. "rules + skill wiring across the batch"}
**Effort:** {LEVEL from Step 9b} — {one-line reason, e.g. "hardest issue in the batch is rules-touching"}
{Model-guard preamble — insert verbatim from `chip-launching.md` "Model-guard preamble", immediately after these lines, no blank line between}

You are picking up {N} freshly captured issue(s) from an `/issue-maker` capture thread — no CR plans, worktrees, or codebase exploration have happened yet.

## Task
Work through these issues, in this order:

1. #{a} — {title}
   {url}
2. #{b} — {title}
   {url}
{…one entry per open issue filed in this session, in filing order}

{Increment chains only: "#{b}–#{d} are increments 2–4 of one chain behind #{a}; they land in that order."}

## Workflow
Run `/subagent #{a} #{b} …` in this thread. It claims each issue, serializes any that overlap on a file, and drives each one A→B→C to a merged PR — keeping at most the 3–4 concurrent-pipeline ceiling in flight and queueing the rest. Any issue it judges too big for a subagent it routes to its own thread, naming the criterion; that judgment belongs here, with the code in front of you, not back in the capture thread.

If this thread has no `## Active Work` table, bootstrap one (`/pm` Step 3.2's schema) and track the issues there. Do not open a separate thread per issue.

## Constraints
- Claim the issue before anything else. Resolve `issue-claim.sh` to the first executable of `$HOME/.claude/skills-worktree/.claude/scripts/issue-claim.sh`, `$HOME/.claude/scripts/issue-claim.sh`, `.claude/scripts/issue-claim.sh` — this repo may carry no `.claude/` directory. Run `<N> --check` on it, and if it clears, `<N> --claim`. Do this after the model-guard check and before any repo read, edit, or planning. Exit 1 (`claimed`) or 4 (`unknown`) → stop and report the claim rather than proceeding; `stale` → say so and continue. If `--claim` itself fails, stop — a passing check is not a held claim. If no candidate resolves, print `DEGRADED: issue-claim.sh not found (checked all three paths) — proceeding unclaimed` and continue; never skip the claim silently.
  - The bullet above applies to **each** issue in the list, one at a time as you pick it up — `/subagent` Step 6.0 performs exactly that per issue, so running the workflow discharges it.
- Do NOT work on main — each pipeline works in its own worktree
- Do NOT modify .env files
- Merging is automatic and yours to do: once the merge gate passes and every Test Plan / AC checkbox verifies, run the full `/wrap` yourself to squash-merge — no approval pause, no pre-merge message (`CLAUDE.md` "PR MERGE AUTHORIZATION")
```

The merge-authority bullet is the shared contract from `chip-launching.md` "Merge-authority line" — reproduce it **verbatim**, never softened into an approval request. The claim bullet is **Form A** of that file's "Claim line" — `/issue-maker` holds no claim, so the launched thread takes each one. Both are written out here as literal text rather than cited, for the same reason that file gives: a generated hand-off may land in a repo where `chip-launching.md` does not resolve, and a rule that lives only in prose never reaches the prompt. The only local addition is the **nested sub-bullet** scoping the claim to each issue in the list — kept off the canonical line on purpose, because `skill-portability-lint.sh` compares that whole line byte-for-byte and an appended clause fails it.

- **Chip mode** (`mcp__ccd_session__spawn_task` present): **before calling `spawn_task`, register via the full contract** (see `chip-launching.md` "Offer Registry"): `REG_TID="$(chip-offer-registry.sh --emitter issue-maker --issue <primary-N> --cap-free "$FREE" --reserve 2>/dev/null)"` — exit 7 means defer (same as `FREE=0`); any other non-zero exit means proceed uncounted. **Retain `REG_TID`** separately from `chip_task_id` for later `--transition` calls (`running` on start, `pr-backed` when a PR opens, `done`/`retracted` on terminal events). Call `spawn_task` **once** with `title` (verb-first, ≤60 chars — e.g. `Run 5 captured issues (#1230 first)`), `prompt` (the block above, verbatim), `tldr` (1–2 plain sentences), `cwd` (repo root). On success, update `chip_task_id` on covered issues to the returned `task_id` (replacing the offer token). Print only the short summary per `chip-launching.md` "Short-summary transcript format".
- **Fallback mode** (tool absent or spawn failed): print the full fenced block above once. Leave `chip_task_id` holding the offer token (not null). Note the fallback once. If `REG_TID` was reserved before the spawn failure, transition it to `retracted` (`chip-offer-registry.sh --transition --task-id "$REG_TID" --state retracted`) so active-work-cap.sh stops counting it.

If the user asks to "print the full prompt for #N", re-emit that issue's complete block verbatim (Model line + guard preamble included) — same as `chip-launching.md` "Print-on-demand replay".

**Print the full issue for #N (on demand).** Because default mode no longer reprints the body at create time, the whole body is available on request instead: when the user asks to **"print the full issue for #N"** (or "show me the whole body of #N"), re-emit that issue's complete 6-section canonical body, sourced from GitHub as the source of truth so the reprint always matches what was filed:

```bash
gh issue view "$N" --repo "$REPO" --json body --jq .body
```

This is distinct from the "print the full prompt for #N" replay just above, which re-emits the coding-chip *prompt*, not the issue body. Printing is not a state change — the issue stays exactly as-is (mirrors `chip-launching.md` "Print-on-demand replay").

Closing line format:

```
Created #N: [<owner>/<repo>#N — <title>](<ISSUE_URL>)
```

**Running tally:** the log is the source of truth for "issues opened in this thread." Surface a tally after every 5 issues and on explicit request — a compact table of number / title / labels / status / chip. The compaction recap in Step 1 reads the same log.

---

## Step 10: `/update <issue#> <statement>` — structured update

A first-class command for adding information to an existing issue **without leaving capture mode**. It is *not* a raw append — it follows a disciplined process:

1. **Fetch** current state:
   ```bash
   gh issue view "$N" --repo "$REPO" --json body,title,comments
   ```
2. **Classify** the statement — is it best added as:
   - a new checkbox under `## Acceptance Criteria` (precise, implementer-facing detail), or
   - an addendum to an existing section (Background / Problem / Notes), or
   - a new top-level section, or
   - a **comment** on the issue rather than a body edit (status/context that doesn't belong in the canonical spec)?

   Default bias: prefer **body edits** for AC/scope, prefer **comments** for status/context.
3. **Reflect** — apply the same scope / split / reflection discipline as a fresh issue. If the new statement implies the issue should be **split**, surface that instead of blindly appending.
4. **Propose** the concrete diff (the edited body, or the comment text) and ask for confirmation.
5. **Apply** once confirmed:
   ```bash
   gh issue edit "$N" --repo "$REPO" --body "$NEW_BODY"   # body edit
   # or
   gh issue comment "$N" --repo "$REPO" --body "$COMMENT" # comment
   ```
   Use the fetch → modify → write-whole-body pattern (`gh issue edit --body` replaces the entire body — never truncate the existing content).
6. **Record** `edited_at` on the log entry and **print the updated issue URL as the closing line.** If the issue isn't already tracked in this thread's log (e.g. you're updating an issue opened elsewhere), add a minimal entry for it instead of silently skipping:

   ```bash
   set_log 'if any(.issues[]; .number == ($n|tonumber))
            then (.issues[] | select(.number == ($n|tonumber)) | .edited_at) = $ts
            else .issues += [{number:($n|tonumber), title:$t, url:$u, labels:[],
                              created_at:$ts, edited_at:$ts, status:"open", chip_task_id:null}] end' \
     --arg n "$N" --arg t "$TITLE" --arg u "$ISSUE_URL" \
     --arg ts "$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
   ```

   **Chips are create-time only.** `/update`/edit-in-place never spawns or refreshes a chip — a chip offered at Step 9 stays as-is even if the body changes materially afterward. Re-planning the chip itself is out of scope for this skill (open question in issue #635's Notes); if the drift matters, retract and re-create. This also means `/update` can never cause the reverse double-offer (`/wave` or `/pm` already offered a chip for this issue, then someone edits it here via `/update`): the step above never *reads* an existing `chip_task_id` to decide anything, and the only value it ever *writes* is `null` (when backfilling a minimal entry for an issue this thread's log didn't already track) — never a live one, so it has no way to spawn a competing chip.

---

## Step 11: Natural-language edit-in-place

Phrases like **"also add X to issue #N"**, **"edit #N …"**, **"update #N with …"** route through the same fetch → classify → propose → confirm → apply → print-link path as `/update` (Step 10) — they edit the existing issue via `gh issue edit`, never create a duplicate. The explicit `/update` command and natural-language edits are two front doors to one mechanism.

---

## Step 12: Retract

Phrases like **"scratch that, close #N"**, **"retract #N"**, **"never mind on #N"**:

### Retracting a member of an increment chain (check this first)

Look up `#N`'s `chain` field in `$LOG` before closing anything. If it is `null`, this is an ordinary retract — continue below unchanged. If it names a `chain_id`, **the rest of that chain has to be dealt with in the same breath**, because closing an increment silently strands everything behind it:

```bash
# Read this issue's chain identity first — empty chain_id means an ordinary retract.
CHAIN_ID=$(jq -r --arg n "$N" \
  'first(.issues[] | select(.number == ($n|tonumber)) | .chain.chain_id // empty) // empty' "$LOG")
POSITION=$(jq -r --arg n "$N" \
  'first(.issues[] | select(.number == ($n|tonumber)) | .chain.position // empty) // empty' "$LOG")

# Successors = same chain_id, higher position, still open. Pass POSITION in as a
# number so the comparison is numeric, not a string compare (10 < 9 as strings).
if [ -n "$CHAIN_ID" ]; then
  SUCCESSORS=$(jq -r --arg c "$CHAIN_ID" --argjson p "${POSITION:-0}" \
    '[.issues[]
      | select(.chain.chain_id == $c and .status == "open" and (.chain.position > $p))]
     | sort_by(.chain.position) | .[].number' "$LOG")
fi
```

**Why this cannot be skipped.** A successor's `Depends on #prev` points at the retracted issue, and the chain-release rule (`/subagent` 6.0b) starts queued work only when its predecessor reaches a **genuinely terminal state — `merged` or `blocked`**. A retracted issue is *closed*, which is neither, so every successor waits on a predecessor that will never merge and never blocks: queued forever, with nothing in the system flagging it. Retracting the **head** strands the entire chain; retracting a **middle** increment strands everything after it and leaves the survivors describing slices of a plan that no longer exists.

Name the affected successors and take one of two paths, then proceed with the close below:

- **Retract the whole chain** (the usual call when the head goes, or when the ask itself is cancelled) — close every open member of the chain, each with the same retraction comment, then run the hand-off logic **once, after the last close**: by then no chain member is open, so `SHARERS` reflects only issues outside the chain and the ordinary retract's two branches decide correctly (withdraw if nothing is left, refresh if the session filed other issues too). Running it per member would refresh the hand-off once per close for no benefit.
- **Re-cut the remainder** (when only one slice was wrong) — keep the successors, but repoint the one immediately after `#N` at `#N`'s own predecessor (or drop its `Depends on` line entirely if `#N` was the head), and renumber the `{i}/{n}` markers in the surviving titles so the chain still reads as a chain. This is a `/update` on each survivor (Step 10), not a new filing.

**Ask which one** — it is the rare genuinely blocking call: both outcomes are destructive in different directions, and the increments are not interchangeable. State the successor numbers in the question. In rapid-fire, ask this one anyway; it is the same class as the two hard bars.

### Ordinary retract

**First, deal with the pending inline offer (if any).** Check whether the offer was accepted and how many other open issues still share the same offer token:

```bash
OFFER_ACCEPTED=$(jq -r '.offer_accepted // false' "$LOG")
OFFER_TOKEN=$(jq -r --arg n "$N" '(.issues[] | select(.number == ($n|tonumber)) | .chip_task_id) // empty' "$LOG")
SHARERS=$(jq -r --arg n "$N" --arg t "$OFFER_TOKEN" \
  '[.issues[] | select(.status == "open" and .chip_task_id == $t and .number != ($n|tonumber))] | length' "$LOG")
```

- **Offer already accepted** (`OFFER_ACCEPTED == true`) — the batch is already running via `/subagent`. Close the issue and clear `chip_task_id` to `null`; the running pipeline will skip a claimed issue it can no longer reach. Do not attempt to withdraw the offer — execution is in flight.
- **No `OFFER_TOKEN`** (never offered, or already cleared) — skip straight to closing the issue.
- **`OFFER_TOKEN` present (offer pending, not yet accepted) and `SHARERS > 0`** — shed this issue from the pending offer: recompute the batch tier from the remaining open issues (Step 9b rules — take the maximum across what remains), re-emit the offer text covering only those issues (refresh in-thread, including the recomputed tier), and clear this issue's `chip_task_id` to `null`. The offer token on remaining issues is unchanged — no new token needed.
- **`OFFER_TOKEN` present (offer pending) and `SHARERS == 0`** — this was the last issue the offer covered. Withdraw the offer entirely: clear `chip_task_id` to `null` and say so (*"Offer withdrawn — no remaining open issues."*). No `dismiss_task` call is needed (there is no chip to dismiss).

Clearing `chip_task_id` to `null` in `$LOG` is the shared-record cleanup — `/wave` and `/pm` read this same log, so nulled entries stop counting as offered work for them too. There is no second store to clear.

```bash
gh issue close "$N" --repo "$REPO" --comment "Retracted via /issue-maker — not needed."

# Flip status to closed and clear chip_task_id only if the dismiss above succeeded (or found none to dismiss).
# $CHIP_RESULT is empty on success/no-op (clears the field), or the still-live $TASK_ID string on genuine
# dismiss failure (--arg, not --argjson: a bare task-id string isn't valid JSON on its own).
set_log '(.issues[] | select(.number == ($n|tonumber)) | .status) = "closed" |
         (.issues[] | select(.number == ($n|tonumber)) | .chip_task_id) =
           (if $chip == "" then null else $chip end)' \
  --arg n "$N" --arg chip "${CHIP_RESULT:-}"
```

Then print: *"Issue #N closed."* — append *"(chip withdrawal failed — it may still be clickable)"* only in the genuine-failure case above. Issue link as the closing line either way.

---

## Step 13: Portable-prompt emission (`--export-prompt`)

When invoked with `--export-prompt`, **do not create anything** — instead emit a standalone, paste-in prompt that codifies the same capture-mode behavior (reflection surfaced as a post-create decision-points report + LLM pass-through rationale, auto-open with no approval gate, functional-first tone, 6-section body, dedup, refusal of workflow-advancing actions until acceptance, closing-line URL rule). This lets the user carry the same discipline into a repo or thread where this skill isn't installed. Output the prompt in a fenced block and stop.

**The sizing check ships in the export with its bar written out, not cited.** Everywhere else in this skill the bar is a citation to `/subagent` Step 4 criterion 3, because that criterion travels with the installed skill. The export is for a thread that has *no* `/subagent` to read, so a citation there would dangle — state the bar in the prompt itself (one Phase A/B/C pipeline, one reviewable PR, one review cycle, a bounded slice), along with the increment-chain shape it triggers: ordered increments, a boundary line on each ("this increment ends at…", and the final one's terminal variant naming nothing deferred past it), `- Depends on #prev` links, a 5-increment cap that stops before filing, and one offer covering the whole chain in order.

**The session's default ending is an inline-run offer.** The exported prompt states: after the last issue is filed, offer to run all open issues inline via `/subagent` on explicit yes; declining leaves issues filed with nothing launched, and a hand-off chip is available on explicit request. The prompt must describe this accurately so a portable capture session does not revert to silent chip-only behavior.

**The exported prompt reproduces the on-request hand-off block verbatim** — one per session — with the `**Model:**` line, `**Effort:**` line, model-guard preamble, and the Constraints block including its merge-authority bullet (`chip-launching.md` "Merge-authority line"). A portable prompt that drops the merge-authority line recreates exactly the gap this exists to close: a thread that reaches merge-readiness in a repo without these rules installed, finds nothing asserting the default, and stops to ask. Never paraphrase the bullet and never soften it into an approval request.

---

## Modes summary

Both modes **auto-open** the issue — no draft reprint, no approval gate — and both auto-apply validated labels. **Both also run the full reflection pass — narrow, expand, split, sizing, ambiguity.** In either mode an oversized ask becomes an increment chain automatically **when it fits in 5 increments or fewer**; above that both modes stop and ask before filing anything (Step 8's cap), and both cover the whole chain with the session's single hand-off (Step 9c). What distinguishes them is the **report** and the **two bars**:

| Mode | Upfront questions | Create | Post-create report | Labels | Dedup pause | Chain cap (Step 8) |
|------|-------------------|--------|--------------------|--------|-------------|--------------------|
| **default** | none (blocking ask only on a genuinely undecidable call) | auto-open | summary + decision points (Step 9a) | auto-apply validated | strong **or** exact match | asks above 5 |
| **rapid-fire** | none on scope or ambiguity — only its two hard bars (dedup, chain cap) | auto-open | terser — closing URL, optional one-liner | auto-apply validated | exact title match only | asks above 5, tersely |

Mode is stored in `.mode` in the session log and persists across compaction — both on first invocation (seeded from `/issue-maker rapid-fire`, Step 1) and on an explicit switch. A switch is a log write, not just an in-memory note, so compaction recovery reads the right mode:

```bash
set_log '.mode = $v' --arg v rapid-fire   # or: --arg v default
```

Switch with `"switch to rapid-fire mode"` / `"switch to default mode"`. Neither mode ever suspends the closing-line URL rule or the 6-section body shape.

---

## After merge: symlink the skill (post-merge, per `skill-symlinks.md`)

Symlinking is **not** part of this PR's code — it happens after the skill reaches `main`. Per `.claude/rules/skill-symlinks.md`, once merged:

```bash
git -C "$HOME/.claude/skills-worktree" fetch origin main --quiet
git -C "$HOME/.claude/skills-worktree" reset --hard origin/main --quiet
ln -s "$HOME/.claude/skills-worktree/.claude/skills/issue-maker" "$HOME/.claude/skills/issue-maker"
```

---

## Usage examples

- `/issue-maker` — enter capture mode; describe an issue and the skill auto-opens it, then reports a concise summary + the scope calls it made as decision points.
- `/issue-maker rapid-fire` — leaner capture mode: same auto-open, terser report (URL only), dedup blocks only on an exact title match.
- `/update 449 "add an edge case for empty input"` — fetch #449, classify the statement, propose a diff/comment, confirm, apply, print the link.
- `"also add a Test Plan item to #312"` — natural-language edit-in-place.
- `"scratch that, close #318"` — retract.
- `"print the full issue for #312"` — re-emit #312's complete 6-section body (fetched from GitHub).
- `/issue-maker --export-prompt` — emit a portable capture-mode prompt for use elsewhere.
