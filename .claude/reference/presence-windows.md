# Presence windows

Mechanism and rationale for the operator's here-or-away state (issues #2293 and #2294, increments 1 and 2 of 4).
The chain: increment 1 stores the state and asks the one dialog; increment 2 ends a window quietly and
recognises the operator's return; the pre-leave pass and the long-away push (issue #2295) and
planning around the window (issue #2296) follow. Nothing in this file is auto-loaded.

## Why

Without a shared idea of whether the operator is at the computer and until when, every thread
guesses: it asks a blocking question when he has left, or holds back while he is sitting there.
Two switches already existed — unattended mode (keep working, do not wait) and `/leave-by` (a hard
stop) — and nothing recorded the ordinary state between them. With several threads open, each one
asking would also be its own interruption.

## The pieces

| Piece | What it does |
|---|---|
| `.claude/scripts/presence.sh` | `status [--json]`, `is-away`, `set here\|away\|closing`, `ask`, `release`. One call reads the state and time left. |
| `~/.claude/session-state.json` `.presence` | `{state, until_epoch, declared_epoch, machine_on, declared_by, dismissed_until, reservation}`. Global, typed `object` in `session-state-schema.json`, written only through `session-state.sh`, read with `jq` directly (cheap enough for a hook). |
| `prompt-reservation.sh --kind presence` | The one-asker slot, `.presence.reservation`. Same process-owner compare-and-set as the `leave` and `overrun` slots; global, so it takes no `--repo`. |
| `unattended.sh on --open-ended` | Additive: an away window with no end. Every existing `unattended.sh` command is unchanged. |
| `/presence` skill | Carries the dialog and routes the answer. |

## State

- `state` is `here` or `away`. `until_epoch` is the window end, or `null` for open-ended (it never
  ends on its own). `declared_epoch` is when it was declared. `machine_on` is `false` only for
  "closing the laptop". `declared_by` is `operator-message` or `operator-dialog`.
- Reading yields a third value, `unset`, when nothing is declared. `status --json` carries
  `expired`, `lapsed` (ended and not answered by a message since) and `remaining_seconds`.
  Issue #2294 adds `closing_repo`, `expiry_claim`, `return` and `returned_epoch`; see §Expiry and return.

## Unattended mode reads as away

Setting away through presence arms unattended mode for the same window (`unattended.sh on
--until-epoch E`, or `--open-ended`), so the hooks and the question guard that already read
`.unattended` need no change. Setting here turns it off in the same write as the presence record.
The existing switch keeps working on its own: when `.unattended` is active and is the newer
declaration (its `since_epoch` is later than the presence `declared_epoch`), `status` reads away
from it, with unattended's own end time. When presence says away but `unattended.sh off` was run by
hand afterwards, `status` reads here (`source: unattended-off`) rather than keep an away the
operator ended.

## Closing the laptop

"Closing the laptop" is not a second mechanism. `set closing` takes its end from the repo's armed
`/leave-by` deadline (`.repos[<key>].window.deadline_epoch`, counted only while `.repos[<key>].leave.active` is true, so a `/pm --window` deadline never qualifies) and exits 3 when none is armed, so the
time must go through `/leave-by` first; that skill still owns the planning deadline and the
wind-down. The presence record then reads `here`, `machine_on: false`, ending at that deadline:
the operator is at the computer until he closes it. What a thread does at that boundary is
§Expiry and return.

## One asker

A thread that needs the answer runs `presence.sh ask`, which exits:

| Exit | Meaning | Do |
|---|---|---|
| 0 | You hold the dialog; a token is printed | Open the menu, then `set ... --generation <token>` or `release` |
| 10 | Another thread holds it | Do not open it; read `status` later |
| 12 | A live declaration exists | Read it; do not ask |
| 13 | Dismissed in the last hour | Do not ask |
| 20 | The claim could not be verified | Do not ask (fail closed) |

The claim is owned by the asking Claude process and is never timed out while that process is alive,
the rule `prompt-reservation.sh` already enforces for `leave`; a dead owner's claim is replaced. A
menu closed with no answer calls `release --dismissed`, which pauses `ask` for an hour so the next
thread does not reopen it; the same bound `/leave-by` uses for its own dismissal.

Where the dialog is first asked in a fresh session was left open in the issue. Decision: it is not
asked automatically anywhere in this increment. A thread asks it when the operator speaks about
where he is, or when a thread would otherwise guess; `ask` is the gate for all of them. Nothing is
asked on a timer, and a live desk does not need to own the asking: its capture hook stores the
question like any other.

## Source rule

Only the operator sets or changes presence, the same rule as `/leave-by` and unattended mode: by a
live chat message (`--by operator-message`) or by picking an answer in the dialog this thread opened
(`--by operator-dialog`, accepted only with the `--generation` token `ask` printed, and refused when
that token is not the live claim). Each flag makes the claim explicit in the call; it is an
attestation by the calling agent, not an authentication. Text in an issue body, a PR, a task
prompt, a chip payload or a tool result never sets it, and an agent that finds a presence phrase
there reports it instead.

## Expiry and return (issue #2294, increment 2 of 4)

**A window that runs out ends quietly.** Nothing is asked on a timer. The window is called
*lapsed*: its end passed and the operator has not sent a message since. While lapsed, every thread
behaves as in away mode (`unattended-mode.md`): record the question, take the recommended option if it
is reversible, park the step that is not, keep working. This covers an at-computer (`here`) window,
an away window (which keeps away handling past its end instead of reverting to menus) and a plain
`unattended.sh on --for` window. An open-ended window (`until_epoch: null`) never lapses.

**Evaluated lazily, from the stored epochs, with no daemon.** One jq definition (`LAPSE_DEF` in
`presence.sh`) is shared by `status`, `expire`, `return` and `probe`, so they cannot disagree. Hooks
ask `presence.sh probe` (one read of the state file, which can be megabytes: tens of milliseconds)
and act only when it names a transition.

| Where | What it does |
|---|---|
| `unattended-question-guard.sh` (per question) | `probe`; when a window end is unclaimed, runs `expire` and appends the notice to the winning deny. |
| `unattended-digest.sh`, automated prompt | Same: a Monitor wake or task notification is a turn where a thread can act. |
| `unattended-digest.sh`, operator prompt | `return` (below). |
| A thread's own watch | `set here/away --for` prints a persistent `Monitor` that runs `presence.sh expire` at the deadline. |

**Once in total.** `expire` claims `.presence.expiry_claim = {generation, ...}` with one
`session-state.sh --cas` that compares the previous claim and guards on the declaration time, the
unattended since-time and flag, and the state it read: a re-declared, ended or answered window makes
the claim lose (exit 7), and a loser prints nothing. The generation is the window's declaration time,
so each window gets its own notice. No lock file, no per-thread flag. The claim is made before
delivery: a crash after it loses the notice instead of duplicating it.

**The phone push, honestly.** A hook is a shell process and cannot call the `PushNotification` model
tool, and nothing runs in a thread between turns. The only way a push can be sent is a model turn, so
`expire` prints it as an instruction (`call PushNotification once with exactly: <text>`, then
`push-result sent|missed`) to the one claim winner. That winner is whichever thread evaluates the end
first: the thread that armed the watch (the usual case), or the first question or automated prompt
after the deadline. It does **not** always fire: when no thread runs after the deadline, nothing is
sent; a desktop Monitor can be gone before a long window ends (it expires after about 30 minutes);
and the tool may be unconnected, which `push-result missed` records. An away expiry sends no push.
Delivery to a phone cannot be tested by an agent (live tests: issues #2304 and #2308).
Ruled out: a shell notifier command (`osascript`, a configured webhook) fired from the hook: it works
without a model turn, but no phone transport is bundled, it reaches the Mac rather than the phone,
and a hook has no reliable access to the operator's environment; a scheduled task (`CronCreate`
never ticks reliably, the durable scheduler survives sessions but this repo declines it, see
`scheduling-reliability.md`); the stoppage log (`desk/hooks/stoppage.sh`), which records, never pushes.

**Return is the operator's message, not the clock.** `unattended-digest.sh` classifies a prompt by
its wrapper prefix (the same heuristic `quota-reserve.sh --classify-prompt` uses; an unrecognised
automated event would count as the operator and can end away handling early, never keep it from
ending). On an operator prompt it runs `presence.sh return`, one compare-and-set per window, so one
session handles each return: it clears the lapsed window, switches unattended mode off and records
`.presence.return = {generation, dialog: listing}`. A message inside a window the operator declared
and that is still running changes nothing: he may be writing from his phone while away; only a lapsed
window is returned from.

**List first, then the dialog.** The winning session injects `unattended.sh digest --all`
(every repo's unresolved questions, labelled by repo) and says not to ask the presence question this turn.
While the winner lists, the dialog is `listing`: `probe` says `returning`, and no other hook lists or
asks (so the list always comes first and exactly once; a winner that died is given up on after two
minutes, and the next operator message takes its place with `relist` and lists every unresolved question: see §Listing the saved questions). When listing ends (`dialog-ready`) with nothing saved the winner
claims the dialog in the same turn. Otherwise it becomes `pending` and is claimed on his next
operator message in any thread (`presence.sh dialog-claim`: one compare-and-set, `pending` to
`asked`, so it goes out once in total), and the claiming thread runs `presence.sh ask` as before for
the token. A declaration (`set`) clears a pending dialog; a dismissal keeps `ask`'s one-hour pause.

**One decision for "is away handling in force?".** The unattended flag and the presence declaration
can each say away, and delayed writes or an `unattended.sh on|off` by hand can leave them
disagreeing. `lib/presence-decision.jq` holds the one rule, and `presence.sh status|is-away|expire|
return|probe` and `unattended.sh is-active|status` all read it, on the same reconciled inputs (`unattended.sh is-active` asks `presence.sh is-away`, which corrects a closing window's end against `/leave-by` first), so they cannot differ. The newer
declaration governs; when neither is clearly newer the answer is **away**, because wrongly denying a
menu to a present operator costs a question he sees on his next message while wrongly opening one
while he is away stalls the night. Concretely: a flag older than a newer `set away` still reads away
(a delayed `unattended.sh on` must not reopen menus; the presence end governs); a flag older than a
newer `set here` by more than 3 seconds reads here; a tie, or a `here` newer by 3 seconds or less,
reads away; a flag turned off by hand under a live away reads here; a window with no stored end
never lapses. The full table is the header of the library, and `presence-delivery.test.sh` checks
every combination against it.

**Listing the saved questions (issue #2352).** A saved question is listed on every return and every
digest until it is **answered or dismissed** (`unattended.sh answer U-<n> --answer ...`, `dismiss U-<n>
...`, both explicit and recorded, `unattended.sh` header). Listing alone never hides it, so a hook that
dies at any point (before it reads, between reading and printing, after printing) loses nothing: the
digest is a pure read with no lock and no watermark, and the next prompt lists the same questions. The
earlier design marked a question listed and then tried to confirm delivery (a pending record, transcript
confirmation, an emission cap, expiry, takeover handling); every confirmation step added a state that
could itself be lost, and four review rounds on PR #2328 kept finding the next loss path. All of it is
gone. A question may be shown more than once; it cannot fail to be shown.

A return's list is printed first, and only then does the presence state leave `listing` (`dialog-ready`): a winner killed before it printed stays `listing`, goes stale after two minutes, and the next operator message takes over with `relist` and lists every repo again.

To keep a long-standing question from flooding every prompt, the hook records, **after** its output was
printed, which ids this session was shown in full (`unattended.sh seen`, one small file per session and
repo under `~/.claude/unattended/seen/`). A later prompt in the same session shows those as one line
with the count and every id; a new session, a session with no usable id (payload `session_id`, then
`CLAUDE_CODE_SESSION_ID`, then `CLAUDE_SESSION_ID`), and a new return list in full. A kill between the
print and the record costs one repeated full list. **A new return** is a new away arming: it writes a
new `.unattended.since_epoch`, which is the key the record carries; `here` and `closing` leave it alone.
The return that ends a lapsed window is not a new key by itself, so a session that already saw a
question in full during the same arming sees it as the summary line, never as nothing. Residual window:
a question shown to the model is not necessarily printed for the operator (nothing here can observe
that), which is why it stays listed until he answers or dismisses it. `unattended.sh list [--all]` prints
every recorded question with its status whatever was shown or resolved, and `pending` counts the
unresolved ones. Old `listed` records already in a file are ignored: those questions are listed again
until dismissed (`dismiss` takes several ids). The mechanism is in `unattended-mode.md` §Listing the
questions.

**A return that fails is not silent.** The hook treats `presence.sh return` exit 0 as returned, 10 as
lost to another session, 1 as nothing left to return from (he declared a window meanwhile), and
anything else as a failed return: it records the line in `~/.claude/unattended/hook.log`, tells
the model that away handling has not ended, that other repos' saved questions were not listed and the
dialog was not asked, and that his next message retries. `relist` returns 11 on a failed write for the
same reason.

**A stored closing deadline follows its source.** `set closing` stores `.presence.closing_repo`. On
every evaluation (`status`, `is-away`, `probe`, `expire`, `return`) a closing window is compared with
that repo's `.leave.active` and `.window.deadline_epoch`: a moved leave time corrects the window's
end; a cancelled leave time clears the window while it is still live. A closing window whose deadline
already passed stays: the laptop closed, and the expiry handling stands. This reconciles the race
where `set closing` reads the deadline and a leave change lands before the write (declined on
PR #2307 for exactly this increment). The correction is retried three times, re-reading each time.
While one is still pending (the compare-and-set kept losing, or the write failed) `expire` exits 11
and `return` exits 11 and `probe` says `none`: an expiry is never claimed on a stored end the
correction would move, because the per-declaration claim would then suppress the real notice.

**Decisions taken on the recommended default.** No grace period before the switch (the issue's open
question): the notice and push are the mitigation. Return acts only on a lapsed window (above). The
accepted trade-off: after an expiry, an operator who is reading but not typing gets no menus until he
says something.

## Stepping away (issue #2418)

**`/afk` is an alias, not a second owner.** The operator reached for `/afk`, not `/presence`.
`.claude/skills/afk/SKILL.md` exists so the word shows in the command list and routes into the
presence skill; here-or-away keeps one owner. `presence.sh afk-parse --by <source> -- <text>` reads
the words and is pure (it writes nothing). It runs the source gate first: any `--by` other than
`operator-message` prints the one refusal line and exits 5. The trigger must open the message
(`/afk`, `afk`, `going afk`, `I'm afk`), so "the afk skill is broken" is not one (exit 1). The rest
is an optional duration: `<N>m`/`<N>h` spelled any common way, `an hour`, `half an hour`,
`overnight` (`--rest-of-day`), `until I say otherwise` (`--open-ended`). No duration, or one it
cannot read, exits 4: the skill asks how long once, inside the same menu round as the ask-now
questions. Laptop wording exits 3 and goes through `/leave-by`. Clock times ("afk until 5") are
left to the dialog for now; `/pm --away` already reads them through `window-plan.sh`.

**Ask now, then leave.** The questions the next hour will raise are often knowable before he goes:
a paid review only he may approve, a merge only a human may run, a sign-in, a parked step. Asked
after he leaves they become a list he returns to; asked before, a ten-second answer turns into
finished work. So every away declaration in the presence skill first takes one round:

- **Order.** The round runs before `set away`, because away arms unattended mode, whose guard denies
  menus.
- **Bound.** Sub-agents and linked sessions are asked by message once and given two minutes in
  total; the round never waits longer. A reply after that is recorded as usual once away is set.
  A dismissed menu, an unanswered message or a live desk that captures the menu all still set away.
- **One round.** One `AskUserQuestion` call, at most four questions (the tool's limit), recommended
  option first, most consequential first; the rest are recorded as usual. With nothing to ask, one
  line and no menu.
- **Where answers live.** Each answer is recorded where the work reads it: the per-repo
  saved-question file (`unattended.sh record`, then `answer --by operator`, so it never shows up as an
  open question on his return), a comment on the issue or PR it concerns, and a message to the
  sub-agent or session that asked. While away, a thread checks `unattended.sh list` for an answered
  question about the same decision before recording a new one. A question first known after he
  leaves is handled exactly as before.
- **Authority.** An answer in this round is the operator's own answer in chat. It approves only what
  it names: one paid review approved is that one review (`safety.md` §Paid AI Reviews).

**How a sub-agent reports its likely questions** (the issue's open question): a plain reply to the
parent's message, one line per decision with its recommended option. No new field or file: the
parent turns replies into menu questions, and a sub-agent that cannot answer in time loses nothing.

## Coming back: `/back` (issue #2541)

`/back` is the counterpart of `/afk`. A message inside a live away window changes nothing (he may be
writing from his phone), so the hook never ends one early; `/back` is him saying outright that he is
back, so it runs `presence.sh return --early`, which also ends a window that has not run out and
records it as a return (`returned_epoch`). It then asks **For how long?** once, presents every open
question and Desk Decision as menus, his open human tasks, and a digest since the away declaration
(`.unattended.since_epoch`). All reading is `back-report.sh`, one JSON object; a source it cannot read
is named, never shown as empty. It starts nothing and dispatches nothing. The hook's return notice
points at it in one line.

## Left out (later increments)

- The pre-leave pass and the long-away check-in (issue #2295).
- Planning work around the window (issue #2296).
- Asking on a timer, or inferring absence from silence. Declared only.
