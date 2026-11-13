# Phone push for a question that waits too long

Mechanism and rationale for `.claude/scripts/phone-push-wait.sh` (issue #2291). No rule file
carries this: the instruction reaches a thread at the moment it parks, in the capture hook's denial
text (`desk/hooks/capture.py`), and `arm`'s own output carries the rest.

## The problem

An operator who walks away without declaring it (`unattended-mode.md` covers the declared case) leaves
every thread that asked a question waiting. Nothing told his phone. Two different waits exist, and they
need different mechanisms, because **a thread stopped on an open question menu cannot act for itself**
and **a shell (hook or script) cannot call a model tool**.

| Wait | Who is alive while it waits | Mechanism |
|---|---|---|
| An open `AskUserQuestion` menu | Nobody in that thread: the turn is blocked on the menu | The Claude app's own push, `inputNeededNotifEnabled` ("Push when actions required"). Documented as covering permission prompts and questions, with Remote Control connected. |
| A parked step (the human queue captured the question, the thread printed the receipt and stopped on the answer) | The thread is live: no menu is open, its turn can end, and a persistent `Monitor` can wake it | `phone-push-wait.sh`: the thread arms a delay; if the question is still unanswered when it ends, the Monitor wakes the thread, which calls `PushNotification` once. |

A captured-but-unanswered Decision counts as waiting only when the thread **parks** on it. A thread
that proceeds on the recommended default is not waiting, so it arms nothing.

## Flow (parked step)

1. The capture hook denies the menu; its reason ends with "If you park, first arm the phone push: ...".
2. The parking thread runs `phone-push-wait.sh arm D-<n> --thread <name> --question '<one line>'`. The
   script writes `~/.claude/phone-push/D-<n>.json` and prints the Monitor command and the two follow-ups.
   Arming is refused for a key already armed: one push per question.
3. The thread starts the printed persistent `Monitor` (`watch D-<n>`). The delay is `--delay` seconds, else
   `PHONE_PUSH_DELAY_SEC`, else 300.
4. Answer arrives inside the delay: the thread runs `answer D-<n>`; `watch` finds the record answered and
   exits without printing. Nothing is sent.
5. Delay passes first: `watch` claims the push with one atomic file create (`<KEY>.claim`, no lock, no
   pid file) and prints one line carrying the push text. Only one process can create that file, which is
   what makes the push once-only with any number of watchers, and a process killed mid-step leaves no
   half state. `sent`/`missed` are the same kind of one-shot create (`<KEY>.outcome`). A record left `due`
   past the grace period (`PHONE_PUSH_GRACE_SEC`, default 180) with neither outcome lost its wake: the next
   `watch`/`status`/`doctor`/`arm` records it `missed` (reason "wake lost"), once. No push is retried.
6. The woken thread calls `PushNotification` with that exact text, then runs `sent D-<n>`. If the call
   reports the push could not be delivered (for example Remote Control is not connected), it runs
   `missed D-<n> --reason '<why>'`. The miss stays in the record, `status` lists it, and the thread
   says so; it is never dropped silently.
7. The operator taps the push and replies in the Claude mobile app; with Remote Control that reply
   reaches the desktop thread as an ordinary message, which the thread treats as the answer.

The push text is `[<thread>] waiting on you: <question>`, at most 190 characters, with links, emails,
absolute paths, token-like strings and non-ASCII removed. The caller passes a one-line summary, never
transcript text. `doctor` checks that both app push toggles are on.

## What was ruled out

- **A hook calling the push.** A hook is a shell process; `PushNotification` is a model tool.
- **The thread itself, after the delay, while a menu is open.** Its turn is blocked on the menu.
- **`asyncRewake` or an async hook to wake a menu-blocked thread.** The documented behavior wakes an
  idle session on exit code 2, or delivers output on the next turn; neither is documented to act while a
  tool call is pending, and an untestable mechanism is not designed around here.
- **A `Notification` hook for the menu case.** The documented matchers (`permission_prompt`,
  `idle_prompt`, `elicitation_dialog`, `agent_needs_input`) do not name `AskUserQuestion`, the delays
  (about 6 s and 60 s) are not configurable, and the hook would still only be a shell.
- **A detached timer started from a `PreToolUse` hook on `AskUserQuestion`.** It could count the delay
  but has no way to push; its only outputs would be a desktop notification or a call to an outside
  service this repo does not use.
- **The desk's GitHub phone inbox (`desk/skill/mobile.md`).** It projects a captured Decision to a private
  repository whose pushes depend on GitHub settings. It is a separate, opt-in, fuller inbox, and the issue
  keeps it a separate backlog item.
- **Unattended mode** (`unattended.sh`): while declared, no menu opens and nothing parks on the
  operator, so no push is armed.

## Gaps (stated, not papered over)

- **Open menu, delay and once-only.** The app's own push has no documented delay and no documented
  once-only guarantee, and its delay is not configurable here. Whether it fires for a menu, and how
  soon, is unverified. `doctor` only confirms the toggles.
- **Phone rendering.** Whether a menu renders as tappable options in the mobile app is undocumented.
  Assume a typed reply.
- **Live delivery.** The tests cover the timer, once-only and answered-inside-the-delay logic. No phone was
  in the loop; the smoke test is a separate follow-up issue.
- **Compliance.** Arming depends on the parking thread following the denial text. A hook cannot arm for
  it, because a hook cannot tell a parked thread from one that proceeded on the default.
- **Monitor lifetime.** A desktop `Monitor` can expire (about 30 minutes); the default delay is well
  inside that.
