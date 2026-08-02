# `/pause` Step 4 — Portable Handoff Template

Referenced from `pause/SKILL.md` Step 4. The SKILL.md keeps the wind-down, the collection call, and the emit sequence; this file holds the document layout and the rules that keep it readable by an agent that has never seen this repo's conventions.

Everything below is written for one reader: **someone who has the repository and this document, and nothing else.** No rules loaded, no state files, no idea what any of our commands do — possibly not even Claude. Write for a competent engineer joining mid-task who will not ask a follow-up question, because they cannot. When a sentence would only make sense to someone inside this harness, it has failed, and `portable-handoff-lint.sh` will say so.

The per-item fields and the last group of rendering rules exist because of a real cold read (issue #912). A document rendered from live state went to an agent holding the repository and nothing else. It could say what to do first, which pull requests were open, and what each was waiting on — and could not say who owned the half-finished work, whether anything was approved, or how to check that a change worked. Every field added below is one question that reader could not answer.

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
  Owner: {"mine" | "another session, still active — do not touch" | "unowned"}
  Waiting on: {PLAIN_ENGLISH_BLOCKER}
  Approval: {who has approved it and on which commit, or "nobody yet" — and what
  this repository requires before it can merge}
  Files: {the files this change touches}
  What is left: {REMAINING_WORK}
  Verify with: {a command that shows whether it works}

- **Issue {N} — {TITLE}**
  {URL}
  Owner: {as above — and when work has already been started, where the
  uncommitted files are and whether to continue them or leave them alone}
  Status: {PLAIN_ENGLISH_STATUS}

## Decisions made this session

{One bullet per decision, each with its reasoning. Omit-free: a decision without
its "why" is the thing a later reader is most likely to undo by accident. Write
"No significant decisions this session." when there were none.}

- {WHAT_WAS_DECIDED} — {WHY, including the alternative that was rejected}

## Local state on this machine

Branch: {BRANCH_NAME}
Working directory: {ABSOLUTE_PATH}
Uncommitted changes: {FILE_LIST or "none" — and when the directory above is
clean because the work sits in other checkouts, say so on this line}
Unpushed commits: {COUNT_AND_SUMMARY or "none"}
Other checkouts with uncommitted work: {one per line: the absolute path, what
is in it, who owns it} or "none"

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

## Rules the cold read added

Each of these answers a question a real reader asked of a document that had already passed the checker (issue #912). Three are mechanically enforced — ownership by `open-work-ownership`, approval by `pull-request-review-state`, a runnable check by `verification-command` — and even those prove only that the field is present with something in it, never that the answer is any good. The rest are judgement, and no grep can hold them.

- **Every in-flight item says who owns it.** "Mine", "another session, still active — do not touch", or "unowned". This is the highest-cost thing to get wrong: a pull request belonging to someone else looks most inviting exactly when it is approved, green, and one rebase from merging, and two sessions editing one branch lose somebody's work. Silence reads as "unowned", so an unmarked item is an invitation you did not mean to send.
- **Work already started but not committed carries its disposition.** Where the files are (absolute path), and whether the reader should finish them, leave them, or start over. "Being written right now" tells a reader who arrives after you stopped nothing at all.
- **Every pull request says whether it is approved, and what this repository requires before it can merge.** "Waiting on" answers what is blocking; it does not answer whether the thing is allowed to merge once unblocked. Name who approved it and on which commit — an approval attached to an older commit is not an approval of what is there now.
- **Give a command that shows whether the work is done.** Test suite, linter, build — anything the reader can run from a fresh checkout. "The tests named in the pull request body" is a pointer to a pointer. At least one such command must appear in the document.
- **Name the files, and name them in a form the reader can resolve.** Repo-relative is fine. When the path starts with one of this repository's dot-directories, the portability rule forbids writing it, so give the file name plus a command that finds it — `git ls-files '*skill-bash.sh'` — rather than dropping the location entirely.
- **Point at a live list; do not copy it.** Checklists and acceptance criteria live in the pull request or issue and will change after you stop writing. Say where they are and that the copy there is the authoritative one. A transcription is a second version that is wrong the moment either side moves.
- **Say what happens after the first action succeeds.** The next thing to pick up, or "stop and reassess". A document that ends at the first merge leaves the reader guessing at precisely the moment they have earned the right to keep going.
- **If the remaining work changes code, say the review starts over.** A new commit means the checks re-run and any approval attaches to the old one. Writing "then merge" after "make this edit" describes a path that does not exist.
- **A fact with an expiry carries its timestamp and how to re-check it.** "The reviewer is rate-limited for another 13 minutes" is true when written and unknowable when read. Give the wall-clock time it was true and the command that answers it now.
- **Tie a decision to the item it governs.** When a decision in the decisions section bears on an open item — the same argument already settled — say so on that item. Otherwise the reader re-litigates a question this session already answered.
- **Be specific where a reader would otherwise guess.** Name the file rather than gesturing at "a reference index". Name the items behind a count — "five earlier changes merged tonight" is not information until they are listed. And when a name disagrees with its subject — a branch named for one issue, a title closing another — explain it in one line, because an unexplained mismatch reads as a mistake worth investigating.
