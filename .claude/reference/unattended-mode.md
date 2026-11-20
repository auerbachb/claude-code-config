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
| `.claude/scripts/unattended.sh` | `on [--for 12h \| --until-epoch E \| --open-ended]`, `off`, `status`, `is-active`, `window-ended`, `record`, `update`, `answer`, `dismiss`, `pending`, `digest [--all]`, `list [--all]`, `seen` (hooks). |
| `~/.claude/session-state.json` `.unattended` | `{active, since_epoch, until_epoch}`. Global, not per repo: the operator is one person, and a declaration made in one repo's thread covers every session. Written only through `session-state.sh`; read with `jq` directly because hooks run on every prompt. |
| `~/.claude/unattended/<owner>__<repo>.jsonl` | Append-only per-repo questions file: `question` records (`U-<n>`, question, options, recommended, did, session, source), `update` records (a later `did`), and `answered` / `dismissed` records (issue #2352). Old `listed` watermarks are ignored. |
| `unattended-question-guard.sh` (PreToolUse, `AskUserQuestion` and `mcp__ccd_session__start_session`) | While unattended: records every question in the call (recommended = first option, the `ask-menu.md` convention), then denies the call with the receipt to print. No menu opens. A `start_session` call is denied with a reason that says to use a sub-agent. Attended: prints nothing. |
| `question-leak-warn.sh` (Stop) | Accepts `question [U-<n>] recorded for the operator's return` as a receipt. While unattended, its warning points at `unattended.sh record`, never at the question tool. |
| `unattended-digest.sh` (UserPromptSubmit) | Injects the unresolved questions on the operator's next message (any prompt that is not a wrapped automated event); marks nothing. Issue #2294: also notices an expired window on an automated prompt and returns the operator on his message after one ran out (below). |
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

- **No menus, no waiting.** Record (`unattended.sh record --question ... --now ... --change ... --why ... --risk ... --links ... --recommended ... --did ...`;
  see §Writing a question),
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


## Writing a question (issues #2592, #2598)

The operator reads saved questions hours or days later, often in another thread, having forgotten
this one. `/back` shows the record word for word and never fills it in, so a record that cannot be
answered as written stays unanswerable: the fix belongs here, when it is written.

Length does not make a question answerable; shape does. Every agent record carries four short
plain sentences, and `record` refuses it without them (exit 2):

| Flag | Says |
|------|------|
| `--now` | what happens today |
| `--change` | what would change if he says yes |
| `--why` | why that change is worth it |
| `--risk` | the real risk of saying yes |

The question, those four and `--did` refuse ticket numbers (`#12`, `PR 12`, `owner/repo#12`),
links, backticks, `snake_case` code names, pipeline labels (`PM-A`), question ids (`U-25`) and
commit hashes. Those go in `--links`, which `/back` prints as one line at the end. Define any
term a newcomer would not know ("a human sales rep", not "rep").

**Answerable** (the operator's own rewrite of a question he could not follow):

> Code marks imported leads who a human rep previously emailed as do-not-contact. But for the ones
> who never replied we should add them back into the cold-email drip pool because maybe if we take
> a second crack at them they will reply. Risk is that maybe they called or texted the sales rep
> and we can't see that, so maybe they should be in a separate human review list.

**Unanswerable** (sales-kit U-25, as recorded):

> PM-A: PR #4421 (Issue #3994) adds two predicate definitions (a lead's rep status; an inbox
> declared no longer watched) and holds rep leads on every send path. Until core Issue #4419
> lands, it refuses WHOLE any lead file that carries a rep_list_status. Merge and activate it
> before the first real import?

- **`--did`** stays what the thread already did meanwhile, in plain words ("held the change, not
  merged"), never review or CI bookkeeping (check counts, review rounds).
- A hook-captured menu arrives without the fields; add them at once with `update U-<n> --now …
  --change … --why … --risk …`.
- `--context` (issue #2592) is still read on old records and shown as Background; it no longer
  satisfies a new record.

## Past decisions

Before asking the operator about a past decision, read the full memory note (not its index line), the
assigned issue's body and first comment, and the task brief. A question whose answer is in any of them
is not asked. When the task as written by the operator or the parent disagrees with a remembered
note, the task wins: proceed on it and flag the doubt in the report.

When a note is edited to mark a decision superseded or reversed, the same edit rewrites its
`MEMORY.md` line to state the current decision first. `memory-audit.py --check --strict` catches the
miss.

## Listing the questions

The rule (issue #2352): **a saved question is listed until it is answered or dismissed; listing never
hides it.** `unattended.sh digest` prints each unresolved question with its recommended option, its
options, and what was done meanwhile. It is a pure read: no lock, nothing appended, so no process death
can lose a question. `--mark` is still accepted and does nothing. The UserPromptSubmit hook runs it on
the operator's next message; `unattended.sh off` runs it when he ends the mode in chat.

Resolving is explicit. When the operator answers in chat the thread records it:
`unattended.sh answer U-<n> --answer '<his answer>' --by operator`; when he drops one,
`unattended.sh dismiss U-<n> [U-<m> ...] --reason '<why>'`. Each validates every id first (strict
`U-<digits>`, recorded, not already resolved) and writes nothing when any is bad. Only an answer he
gave is recorded. `pending` counts unresolved questions; `unattended.sh list [--all]` prints EVERY
recorded question with its status (open, answered, dismissed) regardless of what was shown, which is
the way to read the questions after anything unexpected.

To avoid a flood, `digest --session ID --shown-file PATH` splits the unresolved questions into those
this session has not been shown in full during the current return (full text) and those it has (one
line with the count, every id, and the command that prints the full text). The hook passes the file,
prints its output, and only then runs `seen --session ID --from PATH`, which writes
`~/.claude/unattended/seen/<repo file key>/<session>.json = {key, ids}`. `key` is
`.unattended.since_epoch` (each away arming writes a new one, `here` and `closing` leave it), so a new
return lists in full again. The record can only shorten a repeat. No usable session id means no record
and the full list every time. A hook killed before it prints leaves no record, so the next prompt lists
the same questions in full; killed after printing, before the record, it repeats the full list once.
Why the earlier design (mark on listing, then confirm delivery) was removed, and the tests that pin the
rule: `presence-windows.md` §Listing the saved questions, `unattended-mode.test.sh`.

## When the window runs out (issue #2294)

A declared window's end no longer ends away handling. Mechanism and rationale for the whole
lifecycle: `presence-windows.md` §Expiry and return. What changes here:

- `is-active` stays true after the window's end until the operator speaks (`presence.sh return`) or
  runs `off`; an at-computer presence window that ran out reads as active too. So the guard keeps
  denying menus, questions keep being recorded, and `question-leak-warn.sh` keeps pointing at
  `unattended.sh record`. `window-ended` still reports the deadline; `status` says
  `active (window ended ...; until you send a message)`.
- `digest --all` lists every repo's unresolved questions, each block labelled `[owner/name]`, because the
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
