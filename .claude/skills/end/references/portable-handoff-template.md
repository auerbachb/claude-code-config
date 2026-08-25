# `/end` Step 4 — Portable Handoff Template

Referenced from `stop/SKILL.md` Step 4. The SKILL.md keeps the wind-down, the collection call, and the emit sequence; this file holds the document layout and the rules that keep it readable by an agent that has never seen this repo's conventions.

Everything below is written for one reader: **someone who has the repository and this document, and nothing else.** No rules loaded, no state files, no idea what any of our commands do — possibly not even Claude. Write for a competent engineer joining mid-task who will not ask a follow-up question, because they cannot. When a sentence would only make sense to someone inside this harness, it has failed, and `portable-handoff-lint.sh` will say so.

The per-item fields and the last group of rendering rules exist because of a real cold read (issue #912). A document rendered from live state went to an agent holding the repository and nothing else. It could say what to do first, which pull requests were open, and what each was waiting on — and could not say who owned the half-finished work, whether anything was approved, or how to check that a change worked. Every field added below is one question that reader could not answer.

## The template

```
# Session handoff — {OWNER}/{REPO} — {LOCAL_DATETIME}

Written when the session was stopped. Everything below reflects that moment;
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

- **Stopped background work — {LOGICAL_NAME}**
  Owner: {"this stopped session" | "another session — do not relaunch"}
  Runtime ID: {EXACT_RUNTIME_ID}
  Type: {agent | workflow | background command | monitor}
  Final status: {stopped | done | failed | stop failed | abandoned | unknown}
  Work item: {WHAT_THE_TASK_WAS_DOING or "not recorded"}
  Output: {PRESERVED_OUTPUT_PATH or "not recorded"}
  Checkpoint: {PRESERVED_CHECKPOINT_PATH or "not recorded"}
  Recovery path: {ABSOLUTE_RECOVERY_PATH or "not recorded"}
  Resume by: {OWNING_SKILL_AND_CONCRETE_ACTION_USING_THE_PRESERVED_CHECKPOINT}

{When neither an output file, checkpoint, nor recovery path exists, add:
"Recovery: UNRESOLVED — no preserved location was recorded; inspect the exact
runtime ID before deciding whether manual recovery or a fresh launch is safe."
Never fabricate a path.}

## Progress and verification

Completed: {WHAT_FINISHED_AND_WHERE_IT_LIVES or "nothing completed yet"}
Remaining: {CONCRETE_WORK_STILL_REQUIRED or "nothing known to remain"}
Blockers and decisions needed: {CURRENT_BLOCKERS_AND_OPEN_CHOICES or "none"}
Tests: {COMMANDS_RUN_AND_RESULTS, plus the next exact test command}
Review: {PR_REVIEW_STATUS_AT_THIS_COMMIT or "not applicable — no pull request"}
Next commands: {SHELL_SAFE_COMMANDS_OR_ENTRYPOINTS_IN_EXECUTION_ORDER}

## Decisions made this session

{One bullet per decision, each with its reasoning. Omit-free: a decision without
its "why" is the thing a later reader is most likely to undo by accident. Write
"No significant decisions this session." when there were none.}

- {WHAT_WAS_DECIDED} — {WHY, including the alternative that was rejected}

## Local state on this machine

Repository identity: {OWNER/REPO or "unknown — no sanitized remote identity was available"}
Repository root: {ABSOLUTE_MAIN_WORKTREE_PATH or "unknown — main root could not be resolved"}
Working directory: {ABSOLUTE_ACTIVE_CHECKOUT_OR_CURRENT_DIRECTORY}
Worktree condition: {"main worktree" | "linked worktree" | "not a git checkout" |
"git checkout; worktree condition unknown"}
Branch: {BRANCH_NAME}
Base branch: {BASE_BRANCH or "unknown — no upstream/default/PR base was available"}
HEAD commit: {FULL_COMMIT_SHA or "unknown — not a git checkout"}
Tracked changes: {COUNT_AND_BOUNDED_FILE_LIST or "none"}
Untracked changes: {COUNT_AND_BOUNDED_FILE_LIST or "none"}
Unpushed commits: {COUNT_AND_SUMMARY or "none"}
Other checkouts with uncommitted work: {one per line: the absolute path, what
is in it, who owns it} or "none"

{Anything else a reader would be surprised by — a stashed change, a half-applied
rebase, a running process, a file deliberately left broken.}

## Resume safely

Resume command: /end-resume {add `--resume-refill` only when the refill queue
also needs reopening; this entrypoint is for the original harness}
For another agent: {START_WITH `cd -- 'ABSOLUTE_WORKING_DIRECTORY'`, then list
the exact ordinary `git`, `gh`, and test commands needed to re-check the note}
Relaunch rule: Inspect every stopped task's final status and preserved output,
checkpoint, and recovery path before launching replacement work. Do not relaunch
a task that is already running, rearming, completed, or owned by another session.
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
- **Commands are allowed when they are universal.** `git status`, `gh pr view 903`, a test runner — anything a fresh checkout can run. Commands that only exist inside this harness are not; describe the intent instead. The sole exception is the dedicated `Resume command: /end-resume` field, paired with ordinary commands for a different agent in the next line.
- **The in-thread block and the file on disk are byte-identical.** Render once into a single buffer, verify that buffer, then write it and print that same buffer. Never re-render for display — a second render is a second document, and the reader has no way to know which one they got.
- **Verify before emitting.** `portable-handoff-lint.sh` is the gate, not a suggestion. If it reports a violation, rewrite the offending line and re-run it; do not emit a document that fails it, and do not narrow the check to make a line pass.

## Rules the cold read added

Each of these answers a question a real reader asked of a document that had already passed the checker (issue #912). Three are mechanically enforced — ownership by `open-work-ownership`, approval by `pull-request-review-state`, a runnable check by `verification-command` — and even those prove only that the field is present with something in it, never that the answer is any good. The rest are judgement, and no grep can hold them.

- **Every in-flight item says who owns it.** "Mine", "another session, still active — do not touch", or "unowned". This is the highest-cost thing to get wrong: a pull request belonging to someone else looks most inviting exactly when it is approved, green, and one rebase from merging, and two sessions editing one branch lose somebody's work. Silence reads as "unowned", so an unmarked item is an invitation you did not mean to send.
- **Work already started but not committed carries its disposition.** Where the files are (absolute path), and whether the reader should finish them, leave them, or start over. "Being written right now" tells a reader who arrives after you stopped nothing at all.
- **Stopped background work carries its exact runtime ID and recovery path.** A
  display name cannot prove which process stopped, and a stop without an output
  or worktree path is not meaningfully resumable. When neither exists, mark the
  item unresolved and require manual recovery; do not call it resumable. Omit
  this block only when no background work was running.
- **Machine and Git facts come from one post-shutdown snapshot.** Repository
  identity, roots, worktree condition, branch/base/HEAD, dirty paths, linkage,
  and task outcomes must describe the same moment. Never combine an early Git
  read with a later task audit and call the result authoritative.
- **Tracked and untracked work stay distinct.** A reader can recover a tracked
  edit from a diff and must locate an untracked file by name. A single "dirty"
  count hides that difference and is not enough for a takeover.
- **A different agent gets ordinary commands.** `/end-resume` is useful to the
  original harness but meaningless in many other tools. Always pair it with the
  exact absolute `cd` command, state inspection, and test/review commands that a
  fresh coding agent can execute.
- **Translate registry task types before rendering.** `agent`, `workflow`, and
  `monitor` keep those names. Registry type `bash` renders as "background
  command"; never expose the internal type token as though it were a shell the
  reader should invoke.
- **Every pull request says whether it is approved, and what this repository requires before it can merge.** "Waiting on" answers what is blocking; it does not answer whether the thing is allowed to merge once unblocked. Name who approved it and on which commit — an approval attached to an older commit is not an approval of what is there now.
- **Give a command that shows whether the work is done.** Test suite, linter, build — anything the reader can run from a fresh checkout. "The tests named in the pull request body" is a pointer to a pointer. At least one such command must appear in the document.
- **Name the files, and name them in a form the reader can resolve.** Repo-relative is fine. When the path starts with one of this repository's dot-directories, the portability rule forbids writing it, so give the file name plus a command that finds it — `git ls-files '*skill-bash.sh'` — rather than dropping the location entirely.
- **Point at a live list; do not copy it.** Checklists and acceptance criteria live in the pull request or issue and will change after you stop writing. Say where they are and that the copy there is the authoritative one. A transcription is a second version that is wrong the moment either side moves.
- **Say what happens after the first action succeeds.** The next thing to pick up, or "stop and reassess". A document that ends at the first merge leaves the reader guessing at precisely the moment they have earned the right to keep going.
- **If the remaining work changes code, say the review starts over.** A new commit means the checks re-run and any approval attaches to the old one. Writing "then merge" after "make this edit" describes a path that does not exist.
- **A fact with an expiry carries its timestamp and how to re-check it.** "The reviewer is rate-limited for another 13 minutes" is true when written and unknowable when read. Give the wall-clock time it was true and the command that answers it now.
- **Tie a decision to the item it governs.** When a decision in the decisions section bears on an open item — the same argument already settled — say so on that item. Otherwise the reader re-litigates a question this session already answered.
- **Be specific where a reader would otherwise guess.** Name the file rather than gesturing at "a reference index". Name the items behind a count — "five earlier changes merged tonight" is not information until they are listed. And when a name disagrees with its subject — a branch named for one issue, a title closing another — explain it in one line, because an unexplained mismatch reads as a mistake worth investigating.
