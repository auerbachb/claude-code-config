# `/pause` Step 4 — Portable Handoff Template

Referenced from `pause/SKILL.md` Step 4. The SKILL.md keeps the wind-down, the collection call, and the emit sequence; this file holds the document layout and the rules that keep it readable by an agent that has never seen this repo's conventions.

Everything below is written for one reader: **someone who has the repository and this document, and nothing else.** No rules loaded, no state files, no idea what any of our commands do — possibly not even Claude. Write for a competent engineer joining mid-task who will not ask a follow-up question, because they cannot. When a sentence would only make sense to someone inside this harness, it has failed, and `portable-handoff-lint.sh` will say so.

## The template

```
# Session handoff — {OWNER}/{REPO} — {LOCAL_DATETIME}

Written when the session was paused. Everything below reflects that moment;
check the current state of anything you are about to change before changing it.

## Start here

{ONE_CONCRETE_FIRST_ACTION — the single thing to do first, in the imperative,
naming the file, pull request number, or directory it happens in. If the right
first move is to verify something rather than change it, say that.}

## What we're working on

{OBJECTIVE_IN_PLAIN_PROSE — two to four sentences: what is being built or fixed
and why it matters. Enough that someone can judge whether a later decision still
serves the goal.}

## Open work

{One block per in-flight pull request or issue. Omit the whole list and write
"Nothing is in flight." when there is none.}

- **Pull request {N} — {TITLE}**
  {URL}
  Waiting on: {PLAIN_ENGLISH_BLOCKER}
  What is left: {REMAINING_WORK}

- **Issue {N} — {TITLE}**
  {URL}
  Status: {PLAIN_ENGLISH_STATUS}

## Decisions made this session

{One bullet per decision, each with its reasoning. Omit-free: a decision without
its "why" is the thing a later reader is most likely to undo by accident. Write
"No significant decisions this session." when there were none.}

- {WHAT_WAS_DECIDED} — {WHY, including the alternative that was rejected}

## Local state on this machine

Branch: {BRANCH_NAME}
Working directory: {ABSOLUTE_PATH}
Uncommitted changes: {FILE_LIST or "none"}
Unpushed commits: {COUNT_AND_SUMMARY or "none"}

{Anything else a reader would be surprised by — a stashed change, a half-applied
rebase, a running process, a file deliberately left broken.}
```

## Rendering rules

- **Fill every placeholder.** An unfilled `{TOKEN}` fails the lint, and rightly — it is the document telling the reader that a section was skipped.
- **Never emit an empty section.** When a category has nothing in it, say so in a sentence ("Nothing is in flight.", "No significant decisions this session."). A heading with nothing under it reads as data loss; a sentence reads as an answer.
- **Translate, do not transcribe.** Internal state names are meaningless outside this harness. Say what a reader can act on:

  | Internal state | Write instead |
  |---|---|
  | Phase A / Phase B / Phase C | "being fixed" / "waiting on review" / "being merged" |
  | `merge_ready` | "reviewed and ready to merge" |
  | reviewer is CodeRabbit / BugBot / Greptile | "waiting on the automated reviewer" |
  | merge gate not met | name the actual blocker — a failing check, an unanswered comment |
  | `mergeStateStatus: BEHIND` | "the branch needs updating against the main branch first" |
  | a slash command as the next step | the plain action — "merge it once the checks pass" |

- **Name things by number and URL, always.** "Pull request 903" plus its full URL. A reader with no access to this session cannot resolve "the PR we were on".
- **Absolute paths, not repo-relative ones.** The reader may be in a different checkout. An absolute working-directory path is required and is the one path form the lint permits.
- **A path containing spaces goes in the `Working directory:` field**, whose whole value is one path by definition. Elsewhere the checker reads a path as a whitespace-delimited token, because free prose cannot distinguish a path continuing across a space from two separate words. If you need to mention a spaced path in a sentence, quote it or point back to the field.
- **Commands are allowed when they are universal.** `git status`, `gh pr view 903`, a test runner — anything a fresh checkout can run. Commands that only exist inside this harness are not; describe the intent instead.
- **The in-thread block and the file on disk are byte-identical.** Render once into a single buffer, verify that buffer, then write it and print that same buffer. Never re-render for display — a second render is a second document, and the reader has no way to know which one they got.
- **Verify before emitting.** `portable-handoff-lint.sh` is the gate, not a suggestion. If it reports a violation, rewrite the offending line and re-run it; do not emit a document that fails it, and do not narrow the check to make a line pass.
