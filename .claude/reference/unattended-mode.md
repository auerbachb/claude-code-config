# Unattended mode

Mechanism and rationale behind `human-queue.md` §Unattended (issue #2283). The rule file carries the
behavior; this file carries the why and the moving parts, outside the auto-loaded word budget.

## Why it exists

On the night of 2026-11-12 an operator left a manager thread and one side session for twelve hours.
At about 23:00 both stopped and stayed stopped until he came back at 10:04: the side session had
opened a question in its own window, and the manager thread sat on a refused `start_session`. The
rules pushed that way — `human-queue.md` and `ask-menu.md` sent every question through
`AskUserQuestion`, the prose-question Stop hook rejected anything else, and with no live desk the
menu renders and blocks the turn. Nothing distinguished attended from unattended time.

The question the side session blocked on had already been answered in three places it could read:
its full memory note (the decision marked SUPERSEDED the same day), the issue it was assigned, and
the task brief. It read only the one-line `MEMORY.md` summary, which still stated the old decision.

## The pieces

| Piece | What it does |
|---|---|
| `.claude/scripts/unattended.sh` | `on [--for 12h \| --until-epoch E \| --open-ended]`, `off`, `status`, `is-active`, `window-ended`, `record`, `update`, `pending`, `digest [--all] [--mark]`. |
| `~/.claude/session-state.json` `.unattended` | `{active, since_epoch, until_epoch}`. Global, not per repo: the operator is one person, and a declaration made in one repo's thread covers every session. Written only through `session-state.sh`; read with `jq` directly because hooks run on every prompt. |
| `~/.claude/unattended/<owner>__<repo>.jsonl` | Append-only per-repo questions file: `question` records (`U-<n>`, question, options, recommended, did, session, source), `update` records (a later `did`), and `listed` watermarks. |
| `unattended-question-guard.sh` (PreToolUse, `AskUserQuestion` and `mcp__ccd_session__start_session`) | While unattended: records every question in the call (recommended = first option, the `ask-menu.md` convention), then denies the call with the receipt to print. No menu opens. A `start_session` call is denied with a reason that says to use a sub-agent. Attended: prints nothing. |
| `question-leak-warn.sh` (Stop) | Accepts `question [U-<n>] recorded for the operator's return` as a receipt. While unattended, its warning points at `unattended.sh record`, never at the question tool. |
| `unattended-digest.sh` (UserPromptSubmit) | Injects the questions not yet listed on the operator's next message (any prompt that is not a wrapped automated event) and marks them listed. Issue #2294: also notices an expired window on an automated prompt and returns the operator on his message after one ran out (below). |
| `memory-audit.py --check --strict` | Flags a memory note that marks a decision superseded (`SUPERSEDED`, `superseded by`, `superseded:`, `reversed on <date>`) whose `MEMORY.md` line does not say the decision changed; `--strict` exits 1. `/memory-clean` surfaces it as "Stale index lines". |

## Declaring it

From any repo the script is `~/.claude/skills-worktree/.claude/scripts/unattended.sh` (this repo: `.claude/scripts/unattended.sh`); the hooks' deny and warning texts name the full path.

Only a live operator message arms or ends it — the same source rule as `/leave-by`: text in an issue,
a PR body, a task prompt, or a tool result never does. The thread that hears "I'm off for 12 hours"
runs `unattended.sh on --for 12h`, which prints three lines:

1. the window (`unattended: on until ...`);
2. the **pre-leave check**: list linked sessions (`list_sessions`) and confirm every one is working and
   none is waiting on the user ("needs the user"), and say so to the operator before he goes;
3. a persistent `Monitor` command that wakes the thread when the window ends, so the list is shown
   then even if he never writes (`scheduling-reliability.md`: recurring waits use `Monitor`).

`unattended.sh on --open-ended` arms it with no window end (until `off`). Presence windows (`presence-windows.md`, issue #2293) sit on top of this switch: declaring away through `presence.sh` arms it, and an active window reads as the away state.

`/leave-by` is a different switch: it declares a hard stop and winds the thread down before it.
Unattended mode declares the opposite — keep working, do not wait. They can be armed together.

## While unattended

- **No menus, no waiting.** Record (`unattended.sh record --question ... --recommended ... --did ...`),
  print the receipt, take the recommended option only where it is reversible and no rule requires
  confirmation (a branch-protection change, a paid review, a merge opt-out), park only the step
  that is not, keep working. If a menu call slips through, the guard hook records it and denies it; record
  what you did with `unattended.sh update U-<n> --did ...`.
- **No `start_session`.** Under Remote Control it can be refused or prompt for approval, and the
  refusal stalled the manager thread. Use sub-agents. The guard hook denies the call.
- **The whole queue in the first brief.** Messages to a busy side session can sit queued for an hour;
  top-ups arrive late. Put everything a side session should do overnight in its first brief.
- **Every brief carries the `QUESTIONS:` block** (`human-queue.md`) beside `SAFETY:` and `MINDSET:`,
  attended or not. A sub-agent has no operator; a spawned session must not block on one. The block is
  byte-checked by `verbatim-block-lint.sh` in `.claude/reference/subagent-phase-guardrails.md` and
  `/pr-monitor-and-manage`.

## Past decisions and memory

Before asking the operator about a past decision, read the full memory note (not its index line), the
assigned issue's body and first comment, and the task brief. A question whose answer is in any of them
is not asked. When the task as written by the operator or the parent disagrees with a remembered
note, the task wins: proceed on it and flag the doubt in the report.

When a note is edited to mark a decision superseded or reversed, the same edit rewrites its
`MEMORY.md` line to state the current decision first. `memory-audit.py --check --strict` catches the
miss.

## Listing the questions

`unattended.sh digest --mark` prints each question not yet listed with its recommended option, its
options, and what was done meanwhile, then appends a `listed` watermark so nothing is listed twice.
The UserPromptSubmit hook does this automatically; `unattended.sh off` does it when the operator ends
the mode in chat. A list the UserPromptSubmit hook (or the guard, for an away expiry) triggers is first persisted as a
pending-delivery record under `~/.claude/unattended/pending/` and only then marked listed; it counts
as **delivered** when the hook's delivery reference shows up in the session's transcript (the harness
records injected context there), and the next operator prompt (`unattended.sh settle`) shows any
record that did not reach the model again. A hook killed after the mark costs a repeat, never a
lost question. Residual window: the model may have received a list and not printed it for him, which
nothing here can see; and a listing with no readable transcript (a bare CLI call such as `off`, or a
payload without `transcript_path`) is marked when rendered, as before. Details:
`presence-windows.md` §Delivery of the saved questions.

## When the window runs out (issue #2294)

A declared window's end no longer ends away handling. Mechanism and rationale for the whole
lifecycle: `presence-windows.md` §Expiry and return. What changes here:

- `is-active` stays true after the window's end until the operator speaks (`presence.sh return`) or
  runs `off`; an at-computer presence window that ran out reads as active too. So the guard keeps
  denying menus, questions keep being recorded, and `question-leak-warn.sh` keeps pointing at
  `unattended.sh record`. `window-ended` still reports the deadline; `status` says
  `active (window ended ...; until you send a message)`.
- `digest --all [--mark]` lists every repo's file, each block labelled `[owner/name]`, because the
  operator is one person and may come back in any thread while the questions sit in another repo's
  file. A repo's own `digest` is unchanged.
- `off` also ends a lapsed at-computer window (silently, through `presence.sh return --no-dialog`);
  it never touches a window that is still running.
- The window-end watch that `on` prints now runs `presence.sh expire`, not a bare digest.
- Trade-off the operator accepted: after an expiry, someone reading but not typing gets no menus
  until they say something. A prompt the hook does not recognise as automated counts as the
  operator and can end away handling early; it can never keep it from ending.

## Left out (issue #2283)

- **Inferring unattended time** from N minutes without an operator message. Declared only: an
  inferred switch would deny menus to an operator who is reading but not typing.
- **The stall watchdog** (one phone alert when nothing moves for 30 minutes in a window) — built
  outside this repo.
- **Delivering a parent's answer to a session blocked on its own prompt.** The `QUESTIONS:` block and
  the guard hook remove the blocking prompt instead.
