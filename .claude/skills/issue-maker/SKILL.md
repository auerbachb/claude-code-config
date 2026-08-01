---
name: issue-maker
description: Capture-only thread mode for drafting and opening well-structured GitHub issues. Puts the thread into issue-capture mode — the only job is creating, editing, and closing issues (no implementation, no worktrees, no /start-issue). Auto-opens issues (no approval gate) and reports back a concise summary plus the scope calls it made as decision points; creates canonical 6-section bodies with functional-first tone, runs dedup search, auto-applies validated labels, supports batch + cross-references, and prints the issue URL as the closing line of every create/update. Offers a one-click coding chip alongside every created issue's link (dismissed automatically on retract). Supports /update <N> <statement>, natural-language edit-in-place, and retract. Invoke as `/issue-maker [rapid-fire] [--export-prompt]`.
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
4. **Ambiguity:** name any concrete word/phrase whose meaning materially changes the issue.

Also **surface assumptions explicitly**: when the description leaves something implicit, name the assumption you encoded rather than burying it silently.

**Where the reflection goes.** In default mode you make these calls yourself and **report them as decision points after filing** (Step 9a) — the user reads what you decided and can `/update #N` or `close #N` in one step if a call was wrong (issues are cheap to change). Ask up front **only** when a call is genuinely blocking: the ask spans two clearly separate issues and filing one combined issue would be actively wrong, or a word is so ambiguous the body cannot be written without it. Bias hard toward filing and reporting — a blocking question is the rare exception, not the rhythm.

**Rapid-fire override (leaner escape hatch).** Rapid-fire — per thread (`/issue-maker rapid-fire`, `"switch to rapid-fire mode"`) or per issue (`"just file it"`, `"skip the commentary"`) — is now the *leaner* of two auto-opening modes, not "the one without the gate" (default has no gate either). It never asks up front even on an ambiguous call, blocks dedup only on an exact title match (default pauses on a strong-or-exact match — Step 4), and emits a terser report: the closing URL, optionally a one-line summary, without the decision-points elaboration. It still auto-applies labels, still emits the 6-section body, still prints the closing URL. Switch back with `"switch to default mode"`.

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
  jq -r '"Resuming capture mode for \(.target_repo) — \(.mode) mode. \(([.issues[]|select(.status=="open")]|length)) issue(s) opened so far:",
         (.issues[] | "  #\(.number) — \(.title) [\(.status)]" +
                      (if .chip_task_id then " — chip offered" else "" end))' "$LOG"
fi
```

Chip state survives compaction because it lives in `$LOG` (Step 9c writes `chip_task_id` there, not just in-memory) — the recap line above is what surfaces it back to the user after a fresh invocation.

Then re-affirm: *"Still in capture mode — describe issues to create, or use `/update #N …`, `edit #N …`, or `close #N`."* If the log is corrupt/unreadable, warn the user and offer to start a fresh session log.

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

## Step 2: Refusal behavior — capture mode is a session invariant

If the user asks for workflow-advancing work — **"implement"**, **"code this"**, **"fix the code"**, **"create a worktree"**, **"create a branch"**, **"start working on"**, or invokes `/start-issue`, `/fixpr`, `/wrap` — **politely decline in one line and stay in capture mode**:

> "This thread is in capture mode — I only create, edit, and close issues here. To implement #N, start a fresh thread with `/start-issue #N`."

Never create worktrees/branches, never edit code, and **never poll for a CodeRabbit plan in this thread.** The repo's `.github/workflows/cr-plan-on-issue.yml` auto-comments `@coderabbitai plan` on the issue itself when it's opened (it skips bot-authored issues); the issue's CR plan lands on the *issue*, asynchronously, with no action needed here. Do **not** post `@coderabbitai plan` yourself and do **not** wait on it.

---

## Step 3: Reflect, then draft, then auto-file (the create flow)

For each issue the user describes (see Step 6 for batches):

1. **Reflect** — run the reflection pass from the top-level rule (narrow / expand / split / ambiguity / assumptions). You make these calls yourself; they resurface as decision points in the report (Step 9a). Ask up front only on a genuinely blocking call (top-level rule); otherwise proceed.
2. **Dedup search** (Step 4) — surface likely duplicates; pause before filing only on a strong or exact match.
3. **Draft the body** using the canonical 6-section template (Step 5), honoring the tone defaults. Detect any explicit-ask override and flip to technical-first for that issue only.
4. **Title** — concise, **≤70 characters**. If it would exceed 70, auto-trim and note the trim in the decision points.
5. **Labels** (Step 7, auto-applied) and **cross-references** (Step 8).
6. **Create automatically** — no full-body reprint, no "Create this issue? (Y/n/edit)" gate. Record in the log (Step 9).
7. **Report + print the URL** — emit the concise summary + decision points (Step 9a), offer the coding chip (Step 9c), and **print the URL as the closing line** (Step 9).

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
- **Helper missing, or `DEDUP_RC` ≥ 2:** fall back to the title-only `gh issue list --search "$KEYWORDS in:title"` over open and recently-closed issues, and say the check was degraded when surfacing results.
- **Interpreting matches:** `/issue-maker` always has a human in the loop, so it only ever *surfaces* candidates — it never auto-comments in place of filing. Use the strong/weak/none thresholds in `.claude/reference/autofile-dedup.md` to classify the **top** candidate: a **strong match** or an **exact title match** is a genuine pause point; weak/ambiguous matches are not.
- **Default mode — pause only on a strong or exact match:** if the top candidate clears that bar, surface it and ask *"Looks like a duplicate of #N — file anyway? (y/N)"* before creating. On a weak/ambiguous match, **do not block** — file, and name the near-duplicate as a decision point (Step 9a: "possibly overlaps #N"). No match → file normally.
- **Rapid-fire:** show any matches but proceed unless there is an **exact title match** (then block and ask).

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

If the user describes multiple issues in one message (a numbered/bulleted list, or a `batch:` prefix), treat each as its own issue: run the full per-issue flow (reflect → dedup → draft → labels → auto-create → report) **sequentially**, one `gh issue create` per issue. Step 9's chip offering also runs once per issue — a batch of N issues yields N independent chip-or-block outcomes, not one chip for the batch. After the batch, print a summary table (number, title, labels, URL) — each URL still a clickable link.

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

---

## Step 9: Record + offer a coding chip + print the URL (the closing-line rule)

After **every** create — and after every update/close — append/refresh the session log and **print the GitHub issue URL as a clickable markdown link as the final line of the response.** This rule is absolute: the link is never buried in prose, never mid-paragraph — it is the closing line.

Build the labels as a JSON array from the accepted labels (the same set passed via `--label` flags in Step 5/7), then record the issue through the `set_log` helper:

```bash
# ACCEPTED_LABELS holds the labels applied to this issue, one per line
# (empty if none). Convert to a JSON array — `[]` when there are none.
LABELS_JSON=$(printf '%s\n' "$ACCEPTED_LABELS" | jq -R . | jq -s 'map(select(length>0))')

set_log '.issues += [{number:($n|tonumber), title:$t, url:$u, labels:$labels,
                      created_at:$ts, status:"open", chip_task_id:null}]' \
  --arg n "$ISSUE_NUMBER" --arg t "$TITLE" --arg u "$ISSUE_URL" \
  --arg ts "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" --argjson labels "$LABELS_JSON"
```

### Step 9a: The post-create report — summary + decision points

The report is what replaces the old draft-reprint-and-approve gate, and it is the safety valve that makes auto-filing low-risk. Emit it **immediately after logging the issue** — before the chip (Step 9c) and before the closing URL. Two short parts:

1. **Summary (1–3 sentences).** What issue you just opened, in plain functional terms — the same voice as the body's lead sections, not a section-by-section readout.
2. **Decision points (1–3 sentences).** The actual calls you made that the user might want to revisit — scope you narrowed or expanded, a split you considered but did *not* make, assumptions you encoded, the labels you auto-applied, a weak-duplicate pointer (Step 4). **Name the concrete call** (e.g. *"scoped to the create flow only; assumed rapid-fire keeps its narrower dedup bar; applied `skill`, `enhancement`"*), never boilerplate like "made some scope decisions." If you genuinely made no non-obvious call, say so in one line rather than padding.

Close by reminding the user the issue is cheap to change — a wrong call is one `/update #N …` or `close #N` away. This report is emitted **in addition to**, never in place of, the closing URL line (Step 9). **Rapid-fire** emits a terser version instead: the closing URL, optionally a one-line summary, and no decision-points elaboration.

Tone precedent: `/wrap`'s terse "here's what I decided — flag anything wrong" framing and `issue-planning.md`'s number/title/rationale/link quartet. Keep the whole report to a few lines; its value is signal density, not length.

### Step 9b: Infer a coding tier (for the chip's Model and Effort lines)

`/issue-maker` does no tier classification during capture, but the chip requires a `**Model:** {MODEL} — {REASON}` line **and** an `**Effort:** {LEVEL} — {REASON}` line (`chip-launching.md`). Rather than invoking `/prompt` for two lines, infer the tier directly from the body just drafted in Step 5. Full signal definitions, tier table, and evaluation rules: `references/tier-inference.md`. Summary:

| Tier | Trigger (any is sufficient) | Model / effort |
|------|-----------------------------|----------------|
| **Heavy** | `touches_rules`, `touches_claude_md`, `has_orchestration_keywords`, or `file_count > 5` | Opus, Extra |
| **Standard** | not Heavy, and (`file_count` 2–5, `ac_count > 3`, or `touches_skill`) | Opus, High |
| **Light** | not Heavy/Standard, **and** a positive Light signal (`scope_keywords` or `file_count ≤ 1` with clear scope) | Sonnet, Low |

Default to **Standard** when signals are sparse. Values are bare family names / picker labels — never version numbers or API tokens (`chip-launching.md` "Model and effort lines").

**Both values from this step reach Step 9c** — the model on the `**Model:**` line and the effort on the `**Effort:**` line, in the chip `prompt` and in the visible short summary. A tier computed here and then dropped is the defect #791 fixed.

### Step 9c: Offer a coding chip (default-on, alongside the closing link)

Immediately after logging the issue, offer a one-click coding chip **in addition to**, never in place of, the closing URL line below. This is default-on — including in rapid-fire mode, with no extra confirmation and no opt-out flag today.

**PM-context inline gate (before the chip).** Apply the gate from `.claude/reference/chip-launching.md` "PM-context inline gate". In the rare case this capture thread also carries live PM context (a `## Active Work` table) and the freshly-created issue is subagent-fit, **prefer noting it can be picked up inline via `/subagent #N` in the PM thread** over offering a standalone-thread chip (#613) — **even when every inline slot is busy**, in which case it queues behind them rather than becoming a chip (#776, AC4). This is a recommendation in the report, not an in-thread action — capture mode still performs no worktree/branch/implementation work (Step 2). In the common case — a dedicated capture thread with no PM context — there is no inline pipeline to use, so the chip is the right hand-off and Step 9c proceeds unchanged.

Check chip availability per `.claude/reference/chip-launching.md`. The coding-thread prompt is the same regardless of mode:

**Chip model + effort contract (non-negotiable):** The chip `prompt` MUST open with the `**Model:**` line from Step 9b, then that step's `**Effort:**` line, then the model-guard preamble from `chip-launching.md` — no blank line between the three. The visible short summary MUST repeat both lines (not the guard) per `chip-launching.md` "Short-summary transcript format". When the parent thread is on Fable and the chip recommends a different model, add the pre-click warning from `chip-launching.md` "Upstream requirement."

```
**Model:** {MODEL from Step 9b} — {one-line reason, e.g. "rules + skill wiring" or "single-file addition"}
**Effort:** {LEVEL from Step 9b} — {one-line reason, e.g. "rules-touching change" or "single-file addition"}
{Model-guard preamble — insert verbatim from `chip-launching.md` "Model-guard preamble", immediately after these lines, no blank line between}

You are picking up a freshly captured issue from an `/issue-maker` capture thread — no CR plan, worktree, or codebase exploration has happened yet.

## Task
Start coding issue #{ISSUE_NUMBER}: {TITLE}
{ISSUE_URL}

## Workflow
Run `/start-issue {ISSUE_NUMBER}`. It polls for CodeRabbit's implementation plan, merges it into the issue body, creates a worktree and branch, and hands you a ready-to-code summary — continue from there.

## Constraints
- Claim the issue before anything else: run `.claude/scripts/issue-claim.sh <N> --check`, and if it clears, `.claude/scripts/issue-claim.sh <N> --claim`. Do this after the model-guard check and before any repo read, edit, or planning. Exit 1 (`claimed`) or 4 (`unknown`) → stop and report the claim rather than proceeding; `stale` → say so and continue. If `--claim` itself fails, stop — a passing check is not a held claim.
- Do NOT work on main — use the worktree /start-issue creates
- Do NOT modify .env files
- Merging is automatic and yours to do: once the merge gate passes and every Test Plan / AC checkbox verifies, run the full `/wrap` yourself to squash-merge — no approval pause, no pre-merge message (`CLAUDE.md` "PR MERGE AUTHORIZATION")
```

The merge-authority bullet is the shared contract from `chip-launching.md` "Merge-authority line" — reproduce it **verbatim**, never softened into an approval request.

- **Chip mode** (`mcp__ccd_session__spawn_task` present): call `spawn_task` with `title` (verb-first, ≤60 chars, includes the issue number, e.g. `Fix #42 stale worktree warning`), `prompt` (the block above, verbatim), `tldr` (1–2 plain sentences from `TITLE`), `cwd` (repo root — no worktree exists yet at capture time, unlike `/start-issue`'s own chip, which points at the worktree it just created). On success, **record the returned `task_id` immediately** — before printing anything else:

  ```bash
  set_log '(.issues[] | select(.number == ($n|tonumber)) | .chip_task_id) = $tid' \
    --arg n "$ISSUE_NUMBER" --arg tid "$TASK_ID"
  ```

  This write is not just local bookkeeping — `$LOG` is the shared, cross-thread record other chip-offering skills consult (`chip-launching.md` "Cross-skill chip visibility"), so recording `chip_task_id` here is what makes this chip visible to `/wave` and `/pm` before either offers a second one for the same issue.

  Print only the short summary per issue (per `chip-launching.md` "Short-summary transcript format") — never the full block in chip mode.
- **Fallback mode** (tool absent, or this issue's `spawn_task` call failed): print the full fenced block above and leave `chip_task_id` as `null`. A failed spawn degrades **only that issue** — note the fallback once per batch; the rest keep their chips.

Every created issue ends with exactly one of: a chip, a printed block, or — when the PM-context inline gate above routed it — an inline `/subagent` recommendation; never neither, and never two of them. (Batches: this repeats once per issue in the loop — see Step 6.)

If the user asks to "print the full prompt for #N" while in chip mode, re-emit that issue's complete block verbatim (Model line + guard preamble included) — the chip stays offered (`chip-launching.md` "Print-on-demand replay").

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

**First, dismiss any live chip** (`chip-launching.md` "Stale-chip hygiene" — "gained an open PR" / "superseded" both cover a retracted issue, since the work is now cancelled). Look up the tracked `task_id`:

```bash
TASK_ID=$(jq -r --arg n "$N" '(.issues[] | select(.number == ($n|tonumber)) | .chip_task_id) // empty' "$LOG")
```

- **No `TASK_ID`** (never offered, or already cleared) — skip straight to closing the issue.
- **`TASK_ID` present** — call `mcp__ccd_session__dismiss_task` with that `task_id` and a reason (e.g. `"Issue retracted via /issue-maker"`). Apply the fail-closed outcome rules from `chip-launching.md`:
  - **Dismissed**, or **already clicked/already dismissed** — both mean the offer is gone; clear `chip_task_id` to `null`.
  - **Genuine failure** — the chip is still live. Leave `chip_task_id` set (don't strand the handle) and say so when reporting the close, but proceed to close the issue anyway — a live chip on a closed issue is a stale-but-recoverable state, not a reason to block the retract.

Clearing `chip_task_id` to `null` in `$LOG` below **is** the shared-record cleanup (`chip-launching.md` "Cross-skill chip visibility") — `/wave` and `/pm` read this same log, so the moment the field goes to `null` the issue stops being "already offered" for them too. There is no second store to clear.

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

When invoked with `--export-prompt`, **do not create anything** — instead emit a standalone, paste-in prompt that codifies the same capture-mode behavior (reflection surfaced as a post-create decision-points report + LLM pass-through rationale, auto-open with no approval gate, functional-first tone, 6-section body, dedup, refusal of workflow-advancing actions, closing-line URL rule). This lets the user carry the same discipline into a repo or thread where this skill isn't installed. Output the prompt in a fenced block and stop.

**The exported prompt reproduces Step 9c's coding-chip block verbatim** — `**Model:**` line, `**Effort:**` line, model-guard preamble, and the Constraints block including its merge-authority bullet (`chip-launching.md` "Merge-authority line"). A portable prompt that drops the merge-authority line recreates exactly the gap this exists to close: a thread that reaches merge-readiness in a repo without these rules installed, finds nothing asserting the default, and stops to ask. Never paraphrase the bullet and never soften it into an approval request.

---

## Modes summary

Both modes **auto-open** the issue — no draft reprint, no approval gate — and both auto-apply validated labels. What distinguishes them is the **report** and the **dedup bar**:

| Mode | Upfront questions | Create | Post-create report | Labels | Dedup pause |
|------|-------------------|--------|--------------------|--------|-------------|
| **default** | none (blocking ask only on a genuinely undecidable call) | auto-open | summary + decision points (Step 9a) | auto-apply validated | strong **or** exact match |
| **rapid-fire** | none, ever | auto-open | terser — closing URL, optional one-liner | auto-apply validated | exact title match only |

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
