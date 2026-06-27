---
name: issue-maker
description: Capture-only thread mode for drafting and opening well-structured GitHub issues. Puts the thread into issue-capture mode — the only job is creating, editing, and closing issues (no implementation, no worktrees, no /start-issue). Always reflects before writing (1–3 scope/clarifying questions), creates canonical 6-section bodies with functional-first tone, runs dedup search, suggests labels, supports batch + cross-references, and prints the issue URL as the closing line of every create/update. Supports /update <N> <statement>, natural-language edit-in-place, and retract. Invoke as `/issue-maker [rapid-fire] [--export-prompt]`.
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

## TOP-LEVEL RULE — reflect before you write (NON-NEGOTIABLE)

> **Always pause and ask 1–3 clarifying / scope questions before drafting any issue.** This rule is first on purpose — it is not a checklist item to skim past.

**Why this is rule #1 — the LLM pass-through bias.** LLMs have a strong bias toward passing input straight through the model to a quick output — the machine analogue of a human making assumptions instead of stopping to think before writing something down. Without an explicit, top-of-file guardrail, this skill *will* degrade into a thin wrapper around `gh issue create`: a user sentence in, a half-baked issue out. The reflection discipline below is the entire point of the skill. **Do not water it down, move it lower, or "optimize" it away under time pressure.** A future maintainer reading this should treat any change that weakens the reflection step as a regression.

Before drafting **every** issue, ask 1–3 questions drawn from:

1. **Scope check (narrow):** "Is this tighter than it sounds — is the real ask just X?"
2. **Scope check (expand):** "Is there an adjacent concern (Y) that should ride along so the change is coherent?"
3. **Split check:** "This sounds like 2+ distinct issues — should I split it into subsidiary issues?"
4. **Ambiguity:** name any concrete word/phrase whose meaning materially changes the issue and ask what was meant.

Also: **surface assumptions explicitly.** When the description leaves something implicit, restate the assumption and ask for confirmation rather than silently encoding it in the body.

**Rapid-fire override (escape hatch).** The user can opt out of questions — per issue (`"just create it"`, `"skip questions"`) or per thread (`/issue-maker rapid-fire`, `"switch to rapid-fire mode"`). Rapid-fire skips the clarifying questions and confirmation prompts and auto-applies suggested labels, but **still** runs dedup (blocking only on an exact title match), still emits the canonical body, and still prints the issue URL as the closing line. Switch back with `"switch to default mode"`.

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
         (.issues[] | "  #\(.number) — \(.title) [\(.status)]")' "$LOG"
fi
```

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

Banner: *"Thread is now in issue-capture mode. I will only create, edit, or close issues — no implementation, no worktrees, no branches. Describe an issue and I'll ask a couple of scope questions before drafting."*

**Repo detection (AC):** the `gh repo view` above auto-detects the target repo from cwd. If it returns empty (not a git repo / `gh` failed / ambiguous), **ask the user** which `owner/repo` to target before creating anything, then **persist it to the log** so compaction recovery and later `--repo` calls see it:

```bash
REPO="<owner/repo the user supplied>"
set_log '.target_repo = $v' --arg v "$REPO"   # see the write-log helper below
```

Every `gh issue …` call below passes `--repo "$REPO"`.

### Writing to the session log (one canonical helper)

Every mutation of `$LOG` — recording a created issue, switching mode, marking an issue closed, saving the target repo — goes through one atomic read-modify-write helper so no snippet ever leaves the log stale. Define it once per invocation and reuse it everywhere below:

```bash
# set_log <jq-filter> [--argjson|--arg NAME VALUE ...]
# Applies <jq-filter> to $LOG and refreshes .last_updated_at, atomically.
set_log() {
  local filter="$1"; shift
  local now; now=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
  local tmp; tmp=$(mktemp)
  if jq "$@" --arg __now "$now" "$filter | .last_updated_at = \$__now" "$LOG" > "$tmp"; then
    mv "$tmp" "$LOG"
  else
    rm -f "$tmp"; echo "WARN: failed to update session log ($filter)" >&2; return 1
  fi
}
```

Examples used below: `set_log '.target_repo = $v' --arg v "$REPO"`, `set_log '.mode = $v' --arg v rapid-fire`, and the create/close updates in Steps 9 and 12.

---

## Step 2: Refusal behavior — capture mode is a session invariant

If the user asks for workflow-advancing work — **"implement"**, **"code this"**, **"fix the code"**, **"create a worktree"**, **"create a branch"**, **"start working on"**, or invokes `/start-issue`, `/fixpr`, `/wrap` — **politely decline in one line and stay in capture mode**:

> "This thread is in capture mode — I only create, edit, and close issues here. To implement #N, start a fresh thread with `/start-issue #N`."

Never create worktrees/branches, never edit code, and **never poll for a CodeRabbit plan in this thread.** The repo's `.github/workflows/cr-plan-on-issue.yml` auto-comments `@coderabbitai plan` on the issue itself when it's opened (it skips bot-authored issues); the issue's CR plan lands on the *issue*, asynchronously, with no action needed here. Do **not** post `@coderabbitai plan` yourself and do **not** wait on it.

---

## Step 3: Reflect, then draft (the create flow)

For each issue the user describes (see Step 6 for batches):

1. **Reflect** — unless rapid-fire is active, ask the 1–3 scope/clarifying questions from the top-level rule. If the description plausibly spans two or more distinct concerns, **explicitly propose splitting** into subsidiary issues and let the user decide. Surface assumptions for confirmation.
2. **Dedup search** (Step 4) — surface likely duplicates before drafting further.
3. **Draft the body** using the canonical 6-section template (Step 5), honoring the tone defaults. Detect any explicit-ask override and flip to technical-first for that issue only.
4. **Title** — concise, **≤70 characters**. If it would exceed 70, propose a trimmed version (or, in rapid-fire, auto-trim and note it).
5. **Labels** (Step 7) and **cross-references** (Step 8).
6. **Confirm** — default mode shows the draft title + body and asks *"Create this issue? (Y / n / edit)"*. Rapid-fire skips this.
7. **Create**, record in the log (Step 9), and **print the URL as the closing line** (Step 9).

---

## Step 4: Dedup search

Before creating, search open and recently-closed issues for likely duplicates and surface any matches.

```bash
# Extract 2–5 significant keywords from the proposed title (drop stopwords/punctuation).
KEYWORDS="<significant words from the title>"
if [ -n "$KEYWORDS" ]; then
  gh issue list --repo "$REPO" --state open \
    --search "$KEYWORDS in:title" --json number,title,url --limit 5
  gh issue list --repo "$REPO" --state closed \
    --search "$KEYWORDS in:title closed:>$(date -d '30 days ago' +%F 2>/dev/null || date -v-30d +%F)" \
    --json number,title,url --limit 5
fi
```

- **Guard:** if no significant keywords remain, skip the dedup search.
- **Matches found (default mode):** list them and ask *"Similar issues found — create anyway? (y/N)"*.
- **Rapid-fire:** show matches but proceed unless there is an **exact title match** (then block and ask).

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

**Complexity hint (optional):** if the user states or the description clearly implies a tier, tag the issue with `complexity:quick|light|medium|heavy` (only if that label exists in the repo — see Step 7) so `/prompt` and `/prioritize` can pick it up later.

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

If the user describes multiple issues in one message (a numbered/bulleted list, or a `batch:` prefix), treat each as its own issue: run the full per-issue flow (reflect → dedup → draft → labels → confirm-unless-rapid-fire → create) **sequentially**, one `gh issue create` per issue. After the batch, print a summary table (number, title, labels, URL) — each URL still a clickable link.

---

## Step 7: Label suggestion

Suggest labels from the content, but only labels that actually exist in the repo.

```bash
REPO_LABELS=$(gh label list --repo "$REPO" --json name --jq '.[].name')
```

Keyword → label mapping: `bug`/`fix`/`broken` → `bug`; `feature`/`add`/`new` → `feature`; `refactor`/`clean` → `refactor`; `docs`/`documentation` → `docs`; `skill` → `skill`; `rule` → `rule`. Intersect suggestions with `$REPO_LABELS` and drop any that don't exist.

- **Default mode:** propose — *"Suggested labels: `skill`, `docs` — accept? (Y / n / edit)"*.
- **Rapid-fire:** auto-apply the validated suggestions without asking.

Pass accepted labels as repeated `--label` flags (`LABEL_FLAGS="--label skill --label docs"`).

---

## Step 8: Cross-references

Detect `#N` mentions in the user's description and verify each exists (`gh issue view N --repo "$REPO" --json number` succeeds). Add a `## Related Issues` section using phrasing that matches the user's intent:

- "related to #N" → `- Related to #N`
- "depends on #N" / "blocked by #N" → `- Depends on #N`
- "blocks #N" → `- Blocks #N`

---

## Step 9: Record + print the URL (the closing-line rule)

After **every** create — and after every update/close — append/refresh the session log and **print the GitHub issue URL as a clickable markdown link as the final line of the response.** This rule is absolute: the link is never buried in prose, never mid-paragraph — it is the closing line.

Build the labels as a JSON array from the accepted labels (the same set passed via `--label` flags in Step 5/7), then record the issue through the `set_log` helper:

```bash
# ACCEPTED_LABELS holds the labels applied to this issue, one per line
# (empty if none). Convert to a JSON array — `[]` when there are none.
LABELS_JSON=$(printf '%s\n' "$ACCEPTED_LABELS" | jq -R . | jq -s 'map(select(length>0))')

set_log '.issues += [{number:($n|tonumber), title:$t, url:$u, labels:$labels,
                      created_at:$ts, status:"open"}]' \
  --arg n "$ISSUE_NUMBER" --arg t "$TITLE" --arg u "$ISSUE_URL" \
  --arg ts "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" --argjson labels "$LABELS_JSON"
```

Closing line format:

```
Created #N: [<owner>/<repo>#N — <title>](<ISSUE_URL>)
```

**Running tally:** the log is the source of truth for "issues opened in this thread." Surface a tally after every 5 issues and on explicit request — a compact table of number / title / labels / status. The compaction recap in Step 1 reads the same log.

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
3. **Reflect** — apply the same scope / split / clarifying-question discipline as a fresh issue. If the new statement implies the issue should be **split**, surface that instead of blindly appending.
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
                              created_at:$ts, edited_at:$ts, status:"open"}] end' \
     --arg n "$N" --arg t "$TITLE" --arg u "$ISSUE_URL" \
     --arg ts "$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
   ```

---

## Step 11: Natural-language edit-in-place

Phrases like **"also add X to issue #N"**, **"edit #N …"**, **"update #N with …"** route through the same fetch → classify → propose → confirm → apply → print-link path as `/update` (Step 10) — they edit the existing issue via `gh issue edit`, never create a duplicate. The explicit `/update` command and natural-language edits are two front doors to one mechanism.

---

## Step 12: Retract

Phrases like **"scratch that, close #N"**, **"retract #N"**, **"never mind on #N"**:

```bash
gh issue close "$N" --repo "$REPO" --comment "Retracted via /issue-maker — not needed."

# Flip the matching log entry to closed so tallies + compaction recaps stay accurate.
set_log '(.issues[] | select(.number == ($n|tonumber)) | .status) = "closed"' --arg n "$N"
```

Then print: *"Issue #N closed."* (with the issue link as the closing line).

---

## Step 13: Portable-prompt emission (`--export-prompt`)

When invoked with `--export-prompt`, **do not create anything** — instead emit a standalone, paste-in prompt that codifies the same capture-mode behavior (reflection discipline + LLM pass-through rationale, functional-first tone, 6-section body, dedup, refusal of workflow-advancing actions, closing-line URL rule). This lets the user carry the same discipline into a repo or thread where this skill isn't installed. Output the prompt in a fenced block and stop.

---

## Modes summary

| Mode | Clarifying questions | Confirmation prompt | Labels | Dedup |
|------|---------------------|---------------------|--------|-------|
| **default** | ask 1–3 | show draft, ask Y/n/edit | propose, confirm | surface matches, ask |
| **rapid-fire** | skipped | skipped | auto-apply validated | run; block only on exact title match |

Mode is stored in `.mode` in the session log and persists across compaction — both on first invocation (seeded from `/issue-maker rapid-fire`, Step 1) and on an explicit switch. A switch is a log write, not just an in-memory note, so compaction recovery reads the right mode:

```bash
set_log '.mode = $v' --arg v rapid-fire   # or: --arg v default
```

Switch with `"switch to rapid-fire mode"` / `"switch to default mode"`. Rapid-fire never suspends the closing-line URL rule or the 6-section body shape.

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

- `/issue-maker` — enter capture mode; describe issues and the skill asks scope questions before drafting each.
- `/issue-maker rapid-fire` — capture mode with questions/confirmations skipped (URL + 6-section body still enforced).
- `/update 449 "add an edge case for empty input"` — fetch #449, classify the statement, propose a diff/comment, confirm, apply, print the link.
- `"also add a Test Plan item to #312"` — natural-language edit-in-place.
- `"scratch that, close #318"` — retract.
- `/issue-maker --export-prompt` — emit a portable capture-mode prompt for use elsewhere.
