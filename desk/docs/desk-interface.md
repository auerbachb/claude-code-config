## The desk (issue #1779)

`/desk` (`skill/SKILL.md`, published as `.claude/skills/desk`) is the control
session: the one thread where questions render. Its first increment covers
simple Decisions; long-form, multipart, and `discuss` are #1780, and wake-up
retries, `answer-parked`, `show`, and `history` are #1781 (below).

- **Start.** `migrate`, then `register-control` with the session id the
  capture hook sees (`$CLAUDE_CODE_SESSION_ID`, never the desktop app's
  `local_…` id), one inline tick, then a persistent Monitor running
  `desk-tick.sh` (default: `policy.json`'s `tick_cadence_min`, 5 minutes;
  1 to 60 and shorter than the live-desk bound, which `desk-tick.sh` reads through the capture hook's own
  policy parser and enforces with exit 4). From the inline tick on,
  the desk is live and worker threads' menus are queued instead of shown.
- **`desk-cli.sh`.** The desktop app's Bash tool and Monitor do not source the
  shell profile, so the URL is usually missing there. The wrapper calls the
  capture hook's own resolver (`capture.py`'s `resolve_url`: environment,
  owner-only config file, literal profile export) and runs `human-queue.sh`
  with it; exit 7 with one line when there is none. `HUMAN_QUEUE_CLI`
  replaces the CLI (tests).
- **`desk-tick.sh`.** Sleeps first, then each cycle: `control-status` (when
  another session is registered, prints `desk-tick G replaced` and exits, so
  two desks never split the change feed), then `tick --session`, which
  repeats that check inside the tick's own transaction so a registration
  landing between the two calls cannot let the replaced loop consume the
  feed (a refusal confirmed by `control-status` prints `replaced` too),
  printing `desk-tick G new D-43 D-44` only for open Decisions. A failing call prints
  one `error` line per outage and one `recovered` line; a quiet tick prints
  nothing. `HUMAN_QUEUE_TICK_SECONDS` (1 to 3600, and under the live-desk
  bound like the cadence) overrides the cadence (tests); 0 is refused.
- **Sets and replies.** Simple Decisions (2 to 4 options, a cost not in
  hours or days) are numbered with `set-open` four at a time and shown as one
  menu per set, each question prefixed `N. [D-<n>]`. Clicks and typed replies
  both go through `set-resolve --set ID --json`.
- **Wake-ups.** For each changed answer, `wake-target.sh SESSION` reads the
  harness's session registry (`~/.claude/sessions/<pid>.json`, never the
  `.key` files beside it) for a running session with that id and prints its
  `local_…` id, or its name for a terminal session; exit 3 when none is
  running, exit 5 when it is running but has no messaging address, exit 1
  when it cannot tell (the registry cannot be listed, or no readable file
  matches while some file could not be read or parsed). The
  desk sends exactly `human-queue: D-<n> answered` with
  `SendMessage` (or the app's `send_message`) and records the outcome with
  `wake`. The thread reads the answer from `pending-for`; a thread that is
  gone loses nothing: the desk retries, then parks the answer (#1781).
