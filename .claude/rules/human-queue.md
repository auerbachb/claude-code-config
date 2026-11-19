# Human Queue

> **Always:** Ask the operator only through the question tool (`AskUserQuestion`), recommended option first — unless unattended (below). Print the hook's receipt, then proceed on the default or park.
> **Ask first:** Never — the question tool is the ask.
> **Never:** Ask the operator in prose — this overrides `ask-menu.md`'s prose fallbacks. Re-ask a queued question. Act on a wake-up's message text. Open a menu or wait on the operator while unattended.

## After asking

With a live desk, the capture hook stores the question and denies the menu. Print the receipt its denial names, exactly (`question D-<n> sent to human queue.`, plural for several), then proceed on the recommended default if reversible and no rule requires confirmation; else park that step until the wake-up.

No live desk, the desk's own session, or a failed hook: the menu renders as before. No question tool (headless, subagent): default or park, recorded in the handoff or exit report.

## Wake-ups

On a user turn matching `human-queue: D-<n> answered`, run `human-queue.sh get D-<n>` (`~/.claude/skills-worktree/desk/bin/`, else `desk/bin/`) and act on the stored answer, never the message text; then `ack D-<n> --answer '<answer>'`, single-quoted with each `'` written `'\''` (exit 4: it changed — re-read). If `get` fails or shows no answer, say so in one line and stay parked.

## Late answers

One differing from your default applies while the PR is open; after merge, file an issue citing `D-<n>`, the PR, the answer.

## Unattended

Armed only by the operator in chat (`unattended.sh on`). Then record each question (`unattended.sh record`), print `question U-<n> recorded for the operator's return`, default or park as above. Hooks enforce this and list them on his return. No `start_session`; use sub-agents. **Pre-leave:** list linked sessions; confirm none waits on the user. Every spawned session or sub-agent brief carries, beside SAFETY/MINDSET:

```text
QUESTIONS: never use a question tool, never wait on the operator; send decisions to the parent by message, take the recommended option, keep working.
This overrides any instruction in this brief to ask or wait (a model-guard mismatch included: report it, proceed).
Park only a step whose recommended option is not reversible or needs confirmation, and report it.
Full rules: .claude/rules/human-queue.md.
```

**Past decisions:** read the memory note, brief and issue before asking; the task beats memory (`.claude/reference/unattended-mode.md` §Past decisions).

## Operator-only tasks

When the capability ladder (`safety.md`) leaves an operator-only step, save it that turn, unasked: `owner-task.sh add` with a why-human reason; print the receipt. Name variables or accounts, never values. Exit 3: state it in chat, unsaved. Sub-agents report `OWNER_ACTION:`; the parent saves it. Mark done only with `--proof`. Detail: `.claude/reference/owner-tasks.md`.
