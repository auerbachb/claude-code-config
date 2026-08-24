# Portable Handoff Artifact

The cross-agent document `/stop` produces (Issues #901, #912, and #1311). It is
plain Markdown for a person or coding agent that has the note and repository but
none of the stopped conversation.

Not auto-loaded.

## Two producers, two lifecycles

- A manual `/stop` writes **one canonical note per repository/session** after
  the shutdown audit has final task outcomes. A later stop in that same scope
  atomically updates the canonical note.
- `checkpoint-handoff.sh` writes timestamped `-checkpoint.md` observations
  while work is still running. Checkpoints form a history and never claim the
  session or its background tasks were stopped.

Both match `~/.claude/handoffs/portable-handoff-*.md`, so the usage-limit
recorder can continue selecting the newest by modification time.

## Canonical naming and publication

`portable-handoff-publish.sh` validates `owner/repo`, combines it with the
session ID, and derives a stable keyed filename:

```text
~/.claude/handoffs/portable-handoff-{owner-repo}-{key}.md
```

The key keeps sanitized repository/session filename collisions from choosing
the same note. The source document records the readable repository and session
identity; the filename is routing, not the only identity check.

Publication is fail-closed:

1. Render once into a destination-directory draft.
2. Run `portable-handoff-lint.sh` against those exact bytes.
3. Acquire the canonical file's advisory `state-lock.sh` lock.
4. Copy to a same-directory `mktemp`, assert lock ownership, and atomically
   rename it over the canonical path.

A reader therefore sees the previous complete note or the new complete note,
never a partial file. A lint, lock, staging, or rename failure leaves the input
draft available and produces no success claim. Draft names begin with
`.portable-handoff.` and cannot match the recorder glob.

Historical timestamped manual notes remain readable. New `/stop` writes do not
delete them; they simply converge on the canonical name for future updates.

## Required takeover content

`portable-handoff-context.sh` supplies a bounded JSON snapshot after shutdown:

- sanitized repository `owner/repo` identity and absolute main root;
- absolute active checkout path and main/linked/non-worktree condition;
- branch, base branch, full HEAD, upstream/unpushed state;
- separately capped tracked and untracked path lists;
- an unambiguous current-branch pull request and linked issue when available;
- current-session task IDs, logical names, types, final statuses, work items,
  preserved outputs, checkpoint paths, and recovery paths.

The helper reads only those named facts. It never dumps the environment,
credential-bearing remote URLs, arbitrary file contents, or raw state. An
unavailable read is an explicit `unknown`, `not applicable`, or `could not be
read` result, never an empty category or guessed identifier.

The human/agent-rendered note adds the context scripts cannot infer: objective,
completed and remaining work, blockers and decisions, tests, review status,
and exact next commands. Its Resume safely section includes `/stop-resume` for
the original harness plus ordinary `cd`, `git`, `gh`, and test commands for a
different agent. It tells the reader to inspect every task's final status and
preserved output before relaunching anything, preventing duplicate work.

## Portability lint

`portable-handoff-lint.sh` rejects harness paths, internal phase/state jargon,
unfilled placeholders, missing or duplicate required sections, incomplete
open-work ownership/review fields, relative working directories, missing
repository/worktree/Git facts, and unsafe resume guidance.

The sole skill-invocation exception is `/stop-resume` in the dedicated
`Resume command:` field. Automatic checkpoints instead say it is not
applicable because they stop nothing. Both forms must carry a `Relaunch rule:`
and a different-agent path using ordinary commands.

An absolute path containing `/.claude/worktrees/` remains allowed because it is
the exact address of the work. Relative paths under that directory remain
unportable. Full rule list:

```bash
portable-handoff-lint.sh --list-rules
```

## Readers and retention

- A human or another coding agent uses the canonical note to locate and take
  over the exact checkout.
- `usage-limit-record.sh` points its resume breadcrumb at the newest matching
  handoff by modification time without parsing content or estimating usage.
- Automatic checkpoints point to the most recent richer manual note for intent
  while keeping their newer repository-state observation distinct.

Manual canonical notes are retained until explicitly replaced by a later stop
for the same repository/session or removed by a person. Existing checkpoint
retention remains unchanged.
