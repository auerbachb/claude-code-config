## Capture hook

[`desk/hooks/capture.sh`](../hooks/capture.sh) (with its logic in [`desk/hooks/capture.py`](../hooks/capture.py)) is a `PreToolUse`
hook on `AskUserQuestion`, registered as `.claude/hooks/human-queue-capture.sh`,
a symlink to the capture script in `desk/hooks/`, through `global-settings.json` (timeout 15 s). It
registers globally at the next session start.

| Situation | What the asking thread sees | What the store gets |
|-----------|-----------------------------|---------------------|
| No live desk | The menu, as before | Nothing |
| Live desk, the desk's own session | The menu | One Decision per question, except a question in the desk's set format (`1. [D-43] …`), which is a queued item shown again and adds nothing |
| Live desk, any other session | The call denied with the reason below | One Decision per question |
| The hook cannot do its job | The menu, plus one warning line on stderr | Whatever was written before the failure |

- **Live desk.** A control session is registered (`register-control`) and
  `control-status` says the last tick is at most **15 minutes** old: three
  missed ticks at the desk's default five-minute cadence. Override it with
  `live_desk_max_tick_age_min` (1 to 1440) in `desk/policy.json`; an invalid
  value keeps 15 and warns. With no live desk (none registered, never ticked,
  or the desk session died) every menu renders in its thread as before, so no
  question is stranded during rollout or while the desk is down.
- **The reason.** `Queued as D-43. Print exactly: question D-43 sent to human
  queue. Then proceed on your recommended default or park and wait for a
  wake-up.` A call with several questions names every id:
  `Queued as D-43, D-44. Print exactly: questions D-43, D-44 sent to human
  queue. ...`
- **What a Decision carries.** `--kind decision`; the question on one line
  (whitespace collapsed, control characters dropped, at most 500 bytes); each
  option label as `--option`; `--default` is the label ending in
  `(Recommended)`, else the first option (`ask-menu.md` puts the recommended
  one first); context lines for the header, a multi-select note, and the
  option descriptions (600 characters in total); `--session` is the asking
  session, the return address. `--repo` is the `owner/name` of the cwd's
  `origin` (else `local/<directory>`). `--key` is `issue-N` when the branch is
  `issue-N-*`, else `branch:<name>`, else (on `main` or a detached HEAD)
  `session:<id>`, so unrelated threads never share an item. A key over 200
  bytes keeps its start and ends in `~` and 12 hex digits of its SHA-256, so
  two long branch names that share a prefix stay two keys. `add`'s dedupe
  applies: asking the same open question again bumps it.
- **Finding the store.** The desktop app starts hooks without sourcing a
  shell profile, so `HUMAN_QUEUE_DATABASE_URL` is taken from the first of:
  the environment; `${XDG_CONFIG_HOME:-~/.config}/human-queue/database_url`
  (the URL on one line; used only when it is a file you own with mode 600);
  the last `export HUMAN_QUEUE_DATABASE_URL=...` line of the first of
  `~/.zprofile`, `~/.zshenv`, `~/.zshrc`, `~/.bash_profile`, `~/.bashrc`,
  `~/.profile` that sets it. A profile line counts only when its value is a
  literal (single-quoted, double-quoted without `$`, backtick, or backslash,
  or bare): the profile is read, never run. The URL goes only into the CLI's
  environment and is never printed.
- **Failing open.** No URL, no CLI, a CLI exit other than 0 (7: the store is
  unreachable, within two seconds), output it cannot read, malformed input,
  python3 missing, or a call over 6 s (the whole hook gives up at 12 s): the
  menu renders and stderr carries one line, prefixed `human-queue-capture:`.
  The hook never prints the URL, raw CLI output, or exception text, and never
  blocks a thread because of its own failure. A failure after some questions
  of one call were queued names them; those items stay in the store.
- **Cost.** With no live desk the hook makes one `control-status` call
  (about half a second against Neon); with a live desk, one `add` per
  question as well.

### Decisions from Codex, Cursor, and other tools

The same queue can accept a Decision explicitly marked in a Codex or Cursor
assistant message. The hook reads the message field supplied by the tool,
never its transcript. It sends only the Decision's fields to the existing
queue when the desk is live. Native input dialogs still belong to the tool
that showed them.

Put one block at the end of the assistant's message. Keep the question and
each field on one line, give two to four distinct options, and make the
optional default match one option exactly. Omit credentials, transcript
excerpts, and private data the desk does not need.

```desk-decision
{"question":"Ship the compatibility patch this week?","options":["Ship after CI","Wait for the next batch"],"default":"Ship after CI","context":["The existing API stays compatible."]}
```

Enable each adapter in the tool's **user** hook configuration, alongside
existing entries. Set `<installed-desk>` to the absolute path of your trusted
`desk` install. Configure the tool's own instructions to emit the block when
it needs a Decision from the desk.

External adapters use the database URL resolved by the hook and the schema
in the tool process's `HUMAN_QUEUE_SCHEMA` environment variable, which defaults
to `public`. Claude's account bindings apply to the Claude desk and capture
entry points. Before enabling an adapter, verify that its URL and schema match
the live desk's queue. For a custom schema, set it explicitly in the tool's
environment. The source-account nickname on the Decision is attribution only.

- [Codex hooks](https://learn.chatgpt.com/docs/hooks#stop): add a command
  hook to `Stop` in the profile's `hooks.json` and approve it in Codex.
  Command: `python3 "<installed-desk>/hooks/external_capture.py" codex`;
  set a timeout of 15 seconds. To enable same-machine answer pointers, run
  `python3 "<installed-desk>/hooks/external_capture.py" init-route` once
  on that machine. Keep the private route file local; do not sync it.
  Set `DESK_CODEX_BIN` to an absolute trusted launcher path if the control
  thread's host installs Codex outside the standard locations.
- [Cursor hooks](https://cursor.com/docs/hooks#afteragentresponse): add a
  command to `afterAgentResponse` in the user `hooks.json`.
  Command: `python3 "<installed-desk>/hooks/external_capture.py" cursor`.
  The hook needs a single workspace root. Cursor answers stay in the queue.
- **No hook:** Include the same block in a small local handoff file and tell
  the control thread which repository and work key it belongs to. The control
  thread can import it with
  `python3 "$DESK/hooks/external_capture.py" import --repo owner/name --key issue-123 < "$DECISION_FILE"`.
  Import reads that file only, and the answer stays in the queue.

The item shows the tool and registered nickname; an absent or ambiguous
match is `unknown`. Codex profile directories and Cursor account emails
are matched locally and are not stored on the item. The Codex route sends
only a Decision pointer to an exact thread on the same installation; it
does not resume or start a thread. If a route cannot be used, the answer
stays available through `pending-for --repo OWNER/NAME --key KEY`. Add this
instruction to the Codex profile: on a `human-queue: D-<n> answered` pointer,
read `human-queue.sh get D-<n> --json` from the installed desk and use the
stored answer. Confirm the item belongs to the current work before acting.
Acknowledge the stored answer with the queue's `ack` command; if reading fails,
leave it parked. Apply the pending database migration before enabling either hook.
