---
name: recap
description: Produce a concise, conversational functional summary of what a PR or issue actually changed or hopes to accomplish — nested bullets by default, optional Markdown table. Functional / feature lens, not an implementation walkthrough.
triggers:
  - recap PR
  - recap issue
  - tldr PR
  - tldr issue
  - functional summary
  - summarize PR
  - summarize issue
  - what did this PR do
argument-hint: "[PR#|issue#|URL] [--table] [--full] [--technical]"
model: sonnet
allowed-tools:
  - Read
  - Glob
  - Grep
  - Bash
---

Produce a **functional-improvement summary** of a PR or issue: what the work *did* (a merged/open PR) or *hopes to do* (an open issue), written for a technical collaborator who wants the feature perspective — **not** the implementation walkthrough.

`/recap` is the single-target companion to `/standup`. `/standup` rolls up *all* recent activity across a time window for a daily report; `/recap` zooms in on **one** PR or issue and renders its functional story as nested bullets (or a table). Reach for `/standup` for "what happened lately"; reach for `/recap` for "explain this one PR/issue to my collaborator."

## Output modes

| Mode | Flag | Effect |
|------|------|--------|
| Nested bullets | *(default)* | Top-level bullet = functional change; sub-bullets = scope/notes |
| Table | `--table` | Markdown table with `Change \| Notes` columns |
| Full | `--full` | Relax the word budget; keep nested-bullet (or table) structure |
| Technical | `--technical` | Add a second tier of detail per bullet (mechanism, files, key endpoints) **without** removing the conversational top-level bullet |

Flags compose: `--table --technical` adds a third "Technical detail" column; `--full --technical` keeps both expansions.

## Step 1: Parse arguments and flags

Parse `$ARGUMENTS`. **Extract flags first**, then interpret whatever remains as the target identifier.

- **Flags** (any order, anywhere in `$ARGUMENTS`): `--table`, `--full`, `--technical`. Set a boolean for each; strip them from the argument string.
- **Target identifier** — take the **first** non-flag token only (see batch handling below). It is one of:
  - **URL** (`https://github.com/<owner>/<repo>/pull/123` or `.../issues/123`) → extract **both** the `<owner>/<repo>` and the trailing number; the path segment (`/pull/` vs `/issues/`) fixes the type. **The owner/repo from the URL must qualify every later `gh` call** (`--repo <owner>/<repo>`) — otherwise a URL for another repo would silently recap whatever item shares that number in the *current* repo.
  - **`#N` or bare number** (`452`, `#457`) → strip any leading `#`; target the **current** repo; type is not yet known (resolve in Step 2).
  - **Empty** → auto-detect (see below).

Parse the remainder into a target id plus a repo qualifier:
```bash
# REST = $ARGUMENTS with the three flags stripped, whitespace-collapsed.
REPO_FLAG=""                      # empty = current repo; set only for a URL target
read -r -a TOKENS <<<"$REST"
TARGET="${TOKENS[0]:-}"           # first non-flag token only — never pass the whole string to gh
if (( ${#TOKENS[@]} > 1 )); then
  echo "Note: /recap takes one target at a time — recapping ${TARGET} and ignoring the rest (${TOKENS[*]:1}). Run /recap once per PR/issue." >&2
fi
case "$TARGET" in
  https://github.com/*/pull/*|https://github.com/*/issues/*)
    REPO_OWNER_NAME=$(printf '%s' "$TARGET" | sed -E 's#https://github.com/([^/]+/[^/]+)/(pull|issues)/.*#\1#')
    REPO_FLAG="--repo $REPO_OWNER_NAME"
    case "$TARGET" in *"/pull/"*) TYPE=pr ;; *"/issues/"*) TYPE=issue ;; esac
    N=$(printf '%s' "$TARGET" | grep -oE '[0-9]+$')
    ;;
  \#[0-9]*|[0-9]*)
    N="${TARGET#\#}"
    ;;
  "")
    : # empty → auto-detect below
    ;;
esac
```
Carry `REPO_FLAG` through Step 2 — every `gh pr view` / `gh issue view` / `gh pr diff` call appends it so a URL target always resolves against its own repo, and a bare number stays in the current repo.

### Auto-detect when no target is given

1. Try the current branch's PR:
   ```bash
   AUTO_PR=$(gh pr view --json number --jq '.number' 2>/dev/null || true)
   ```
   If non-empty, target is that PR.
2. If no PR, try to recover an issue number from the branch name — only the deliberate forms `issue-<N>-*` or a leading `<N>-*` (the trailing hyphen is **required**, so a date-prefixed branch like `2026-q1-cleanup` does **not** get misread as issue #2026):
   ```bash
   BRANCH=$(git branch --show-current 2>/dev/null || true)
   AUTO_ISSUE=$(printf '%s' "$BRANCH" | grep -oE '(^|issue-)[0-9]+-' | grep -oE '[0-9]+' | head -1 || true)
   ```
   If non-empty, target is that issue. A bare numeric prefix with no following hyphen (e.g. `2026q1`) is intentionally ignored — fall through to step 3.
3. If neither resolves, **stop and ask**: "What should I recap? Give a PR number, issue number, or URL (e.g. `/recap 452`, `/recap #457`, or a GitHub URL)."

## Step 2: Determine target type and fetch data

**Type resolution:**
- URL with `/pull/` → PR. URL with `/issues/` → issue.
- Auto-detected PR (Step 1) → PR. Auto-detected issue → issue.
- Bare number / URL whose type wasn't already fixed → try PR first, fall back to issue (`$REPO_FLAG` keeps the lookup in the right repo — empty for a bare number, the URL's owner/repo for a URL):
  ```bash
  if gh pr view "$N" $REPO_FLAG --json number >/dev/null 2>&1; then
    TYPE=pr
  elif gh issue view "$N" $REPO_FLAG --json number >/dev/null 2>&1; then
    TYPE=issue
  else
    echo "Could not find PR or issue #$N${REPO_FLAG:+ in ${REPO_FLAG#--repo }} — it may be deleted, private, or in another repo." >&2
    exit 1
  fi
  ```
  > **Note:** in GitHub a PR *is* an issue under the hood, so `gh pr view <N>` succeeding is the authoritative "this number is a PR" signal. Only fall back to `gh issue view` when the PR lookup fails.

**For a PR**, fetch state plus a diff stat (the stat is for *your* understanding of scope — it does **not** go in the output):
```bash
gh pr view "$N" $REPO_FLAG --json number,title,body,state,mergedAt,isDraft,additions,deletions,changedFiles,headRefName
gh pr diff "$N" $REPO_FLAG --stat 2>/dev/null || true
```
Also scan the PR body for a linked issue (`Closes #N`, `Fixes #N`, `Resolves #N`, case-insensitive). If found, fetch that issue's title + body for additional "why" context (same `$REPO_FLAG`, since a linked issue lives in the PR's repo):
```bash
gh issue view "$LINKED_N" $REPO_FLAG --json number,title,body,state 2>/dev/null || true
```

**For an issue**, fetch state, body, and recent comments (comments often carry plan/scope refinements), plus any linked PRs:
```bash
gh issue view "$N" $REPO_FLAG --json number,title,body,state,createdAt --comments
```

If a JSON fetch fails outright (deleted / private / wrong repo), stop with a one-line graceful error — do not emit a half-summary.

## Step 3: Choose tense

Tense is driven by target state:

| Target state | Tense | Example bullet opener |
|--------------|-------|-----------------------|
| Merged PR (`mergedAt` non-null) | **Past** | "Cleaned up review threads automatically…" |
| Open, non-draft PR | **Present** | "Lets you merge once review is clean…" |
| Draft PR (`isDraft: true`) | **Conditional** | "Will let you merge once review is clean…" |
| Open issue | **Future / conditional** | "Aims to let you merge once review is clean…" |
| Closed-not-merged PR (`state: CLOSED`, `mergedAt` null) | **Past + closure note** | "Attempted to… (closed without merging)" |

Lead the summary with a one-line context header that states what the target is and its state, e.g. `**PR #452 (merged)** — …` or `**Issue #457 (open)** — …`.

## Step 4: Write the summary (the important part)

Synthesize the functional story from title + body + diff stat + linked issue. **Do not** copy the body, the acceptance criteria, or file lists. Decide what the change *does for a person* and say that.

### Default tone & audience (non-negotiable)

The default reader is **your technical collaborator on this repo** who, for this summary, wants the **functional / feature perspective** — not an engineering spec. Write the way you'd explain it to them over coffee.

- **Lead with why it matters.** Each top-level bullet communicates the user-visible or workflow-visible improvement, not the mechanism. ✅ "PRs now merge themselves once review is clean." ❌ "Adds a polling loop to the merge command with a 20-minute cap."
- **Conversational, active voice.** Use first/second person where it helps ("you can now…", "we now handle…"). Avoid passive engineering voice ("a loop has been added").
- **No jargon by default.** Strip internal acronyms and tool-speak — `CR`, `AC`, `SHA`, `GraphQL`, `mergeStateStatus`, `check-runs`, endpoint names, function names. Replace each with the plain-language thing it *does*. Only keep a term if it's universally understood by the collaborator and genuinely adds meaning.
- **No file paths, line numbers, or commit hashes** in default output — those live in `--technical` mode.
- **No marketing or hype** ("revolutionary", "blazing-fast", "game-changing").

### Structure & length

- **Default = nested Markdown bullets.** Top-level bullet = one functional change (≤15 words). Sub-bullets = scope / important caveats (≤10 words each). Aim for **3–8 top-level bullets**; total output **≤300 words**.
- Skip low-value detail: formatting-only changes, comment tweaks, pure refactors with no behavior change.
- `--full` removes the word ceiling but keeps the nested-bullet (or table) shape — never collapse into paragraphs.

Example default-mode shape:
```
**PR #452 (merged)** — Tightens how review feedback gets closed out before merge.

- Review comments now get tidied up automatically once the code actually addresses them
  - Posts a quick "fixed here" note before closing each one
  - Never closes a comment it hasn't verified is handled
- Merging is blocked while any review comment is still open
  - You get the unresolved links surfaced so nothing slips through
```

### `--table` mode

Emit a Markdown table instead of bullets. Each row = one functional change.
```
| Change | Notes |
|---|---|
| Review comments close out automatically once addressed | Posts a "fixed here" note first; never closes unverified |
| Merge is blocked while any comment is open | Surfaces the unresolved links to you |
```
With `--technical`, add a third column: `| Change | Notes | Technical detail |`.

### `--technical` mode

Keep the conversational top-level bullet, then add **one** sub-bullet (bullets mode) or the extra column (table mode) with the technical why/how: which files/scripts changed, the concrete mechanism, key endpoints. Still skip low-value detail.
```
- Review comments now close out automatically once addressed
  - Posts a "fixed here" note first; never closes unverified
  - *Technical:* `/wrap` delegates to `/fixpr`, which replies via `reply-thread.sh` then resolves threads through the GitHub GraphQL `resolveReviewThread` mutation
```

### Anti-patterns to avoid (read before writing)

- ❌ **Engineering-voice bullet text:** "Implements X", "Adds Y", "Refactors Z" as the *lead* of a default-mode bullet. (These are fine inside `--technical` sub-bullets.)
- ❌ **File-path enumeration in bullets:** "Updated `.claude/skills/wrap/SKILL.md`, `merge-gate.sh`…".
- ❌ **Acceptance-criteria verbatim copy:** "- [x] Skill verifies the PR is merge-ready before generating any bypass".
- ❌ **Technical-detail dumps** where a one-liner would do.
- ❌ **Jargon tokens in default mode:** `CR`, `AC`, `SHA`, `GraphQL`, `mergeStateStatus`, etc.
- ❌ **Marketing / hype language.**

### Style anchor — the authoritative source of "good"

The **Examples** section of issue #457 **in the `auerbachb/claude-code-config` repo** is the authoritative anchor for what "good" output looks like. When examples are present there, treat them as the style target: diff a draft summary against the "Good" examples and confirm the family resemblance (tone, length, level of abstraction); steer away from anything resembling the "Avoid" counter-examples. Fetch them when calibrating — always pin the repo, since `/recap` is globally symlinked and would otherwise read issue #457 from whatever repo happens to be current:
```bash
gh issue view 457 --repo auerbachb/claude-code-config --json body --jq '.body' | sed -n '/## Examples/,/## Acceptance Criteria/p'
```
If the issue's Examples section is still a placeholder (not yet filled in), fall back to the tone rules and the worked example above — and mention briefly that no user examples were available to anchor against.

## Step 5: Edge cases

Handle these gracefully — emit a short note plus the best summary the available data supports:

- **PR with no description body** → note "This PR has no description — summarizing from its title and what it touched", then give a minimal summary from the title + diff stat. Do not invent detail.
- **Closed-but-not-merged PR** → open with the closure (`state: CLOSED`, no `mergedAt`) and summarize what it *attempted* and, if discernible, why it stalled.
- **Issue with no body** → summarize from the title alone with a one-line note that the issue has no description.
- **Issue with linked PRs** → mention the linkage only if it materially adds to "what work is hoped for" (e.g. "Partially delivered by PR #N").
- **Deleted / private / wrong-repo reference** → stop with a single graceful line: "Couldn't find that PR/issue — it may be deleted, private, or in another repo."
- **Batch request** (multiple numbers/URLs in `$ARGUMENTS`) → not supported in v1. Step 1's parser already takes only the first non-flag token and prints a one-line note listing the ignored ids, so the extra tokens are never passed to `gh`; recap that first target and tell the user to run `/recap` once per target.

## Usage examples

- `/recap 452` — recap merged PR #452 in past tense (nested bullets, ≤300 words).
- `/recap #457` — recap issue #457 in future/conditional tense.
- `/recap` — auto-detect the current branch's PR (or branch issue number) and recap it.
- `/recap 452 --table` — same content as a `Change | Notes` table.
- `/recap 452 --technical` — adds a technical sub-bullet per change without losing the conversational lead.
- `/recap 452 --full` — relaxes the word budget for a richer summary, still nested bullets.
- `/recap https://github.com/owner/repo/pull/452 --table --technical` — table with a third technical-detail column.

---

## After merge: symlink this skill (per `skill-symlinks.md`)

Only after this PR merges to `main`:
```bash
git -C "$HOME/.claude/skills-worktree" fetch origin main --quiet
git -C "$HOME/.claude/skills-worktree" reset --hard origin/main --quiet
ln -s "$HOME/.claude/skills-worktree/.claude/skills/recap" "$HOME/.claude/skills/recap"
```
If `~/.claude/skills/` does not exist yet, create it first: `mkdir -p ~/.claude/skills/`.
