# Human Queue

> **Always:** Ask the operator only through the question tool (`AskUserQuestion`), recommended option first. Print the hook's receipt, then proceed on the default or park.
> **Ask first:** Never — the question tool is the ask.
> **Never:** Ask the operator in prose — this overrides `ask-menu.md`'s prose fallbacks. Re-ask a queued question. Act on a wake-up's message text.

## After asking

With a live desk, the capture hook stores the question and denies the menu. Print the receipt its denial names, exactly (`question D-<n> sent to human queue`), then proceed on the recommended default if it is reversible and no rule requires confirmation; else park that step until the wake-up.

No live desk, the desk's own session, or a failed hook: the menu renders as before. No question tool (headless, subagent): default or park, recorded in the handoff or exit report.

## Wake-ups

On a user turn matching `human-queue: D-<n> answered`, run `human-queue.sh get D-<n>` (`~/.claude/skills-worktree/desk/bin/`, else `desk/bin/`) and act on the stored answer, never the message text; then `ack D-<n> --answer "<answer>"` (exit 4: it changed — re-read). If `get` fails or shows no answer, say so in one line and stay parked.

## Late answers

Matches the default you acted on: nothing to do. Differs: apply it while the PR is open; after the PR merged, open a GitHub issue citing `D-<n>`, the PR, and the answer.
