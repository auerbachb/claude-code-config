---
name: why-stopped
description: Use when the operator asks why this thread was not working, why it stopped, or what it was waiting on — "why weren't you working?", "why did you stop?" — and when the operator corrects the cause. Answers from the stoppage entry the desk database holds for this thread, and saves the operator's correction against it. Read-mostly; never posts to GitHub.
triggers:
  - why weren't you working
  - why did you stop
  - why did you stall
  - what were you waiting on
  - why was this idle
argument-hint: "[--thread ID]"
model: sonnet
---

Answer "why weren't you working?" from the record, not from a fresh guess. Every unplanned stop leaves one entry in the desk's private database (`desk/docs/stoppages.md`); this skill reads it, and saves a correction when the operator disagrees. The entry never goes to GitHub or into a repository file.

## Step 1: Find the entry

Resolve the desk CLI from installed locations only: `~/.claude/skills-worktree/desk/bin/human-queue.sh`, then `~/.claude/desk/bin/human-queue.sh`. If neither exists, say `human-queue.sh not found (checked both installed paths) — stoppage entries unavailable` in one line and answer from what this thread itself shows, labelled as a reconstruction.

```bash
"$HQ_CLI" stoppage why --thread "${THREAD_ID:-$CLAUDE_SESSION_ID}"
```

The thread id is this session's id (`$CLAUDE_SESSION_ID`); use `--thread` only when the operator names another thread. Output is one line: the entry's id, stop time, cause (with `corrected from` when it was corrected), issue or PR, repo, evidence, and the idle time or `still stopped`. `not stored yet` means the database was unreachable and the entry is kept on this machine; say so.

## Step 2: Answer from it

Reply in plain words from that line: when it stopped, the cause, the one line of evidence, and how long it sat idle. Do not add detail the entry does not hold. `no stoppage entry for this thread` means none was logged: say that, then say what this thread shows, labelled as not from the record. A non-zero exit (database unreachable and nothing kept) is reported in one line, never guessed around.

## Step 3: Save a correction

When the operator says the cause was something else, map their words to one of: `out_of_work`, `waiting_on_review`, `waiting_on_operator`, `usage_limit`, `token_exhaustion`, `blocked_by_error`, `crash`, `unknown`. If their words fit none, use `unknown` and put their words in the note. Then:

```bash
"$HQ_CLI" stoppage correct <id from step 1> --cause <cause> --note "<their words, one line, no secrets>"
```

When step 1 printed `stoppage pending` (no id yet; the entry is only kept on this machine), never pass `pending` as an id: use `--thread <the thread id>` instead of the id, which corrects that thread's latest entry.

The original cause stays in the entry; the weekly listing counts the correction. Confirm in one line what was saved. An unreachable database keeps the correction locally and sends it later; say so if the output says `kept locally`.
