# /desk — interrupts, the policy, and feedback tags

Loaded at start (`SKILL.md` step 2 reads the policy here), when the operator's whole message is an interrupt verb, and when it is feedback tags (below). Both work at any time: with nothing on screen, after a menu, while a long-form prompt waits, or during a discussion. Every Bash block starts with `SKILL.md`'s prelude (`DESK`, `HQ`, `SID`, `SESSION_STATE_SH`). Issue #1783; design: `desk/DESIGN.md` 2.6 (one point of contact) and 4.1.4 (no state line printed unasked).

**Loud by default.** Every new Decision reaches the desk at the next tick, in sets. The operator tunes that down item by item, by telling the desk which interrupts were not worth it, and holds the desk while away or focused. Nothing here changes how often agents ask or what they may decide on their own: a held Decision waits in the store, and its thread waits for the answer or takes its default as it always would. A question never renders anywhere but the desk, held or not: the desk keeps ticking during a hold, so it stays live and worker threads' menus are still queued.

## The policy

`desk/policy.json` holds the defaults, read through the capture hook's own parser (one parser for the hook, `desk-tick.sh`, and the skill):

| Key | Default | Means |
|-----|---------|-------|
| `tick_cadence_min` | `5` | Minutes between ticks, 1 to 60 and shorter than `live_desk_max_tick_age_min`. `/desk --cadence Nm` overrides it for one desk |
| `interrupt_rule` | `everything` | The rule in force while the desk has set none: `everything` or `away`. The loop reads it again every 30 seconds, so an edit applies at the next tick |
| `eod_time` | `17:30` | The end of the working day, `HH:MM` in America/New_York (the end-of-day sweep, #1784, uses it) |
| `set_size` | `4` | Decisions per menu, 1 to 4 (four questions is the menu tool's limit) |
| `live_desk_max_tick_age_min` | `15` | How old the last tick may be for the capture hook to queue questions, 1 to 1440. Lowered to a running desk's cadence or below, the loop (which reads the policy every 30 seconds) ticks 30 seconds inside it, even mid-sleep |

An invalid file (unreadable, not a JSON object, or any value out of range) is the defaults, every key, with one warning; one bad value never leaves the others half-applied. Unknown keys are ignored. A missing file is the defaults, silently.

<!-- test-anchor: desk-policy -->

```bash
"$DESK/bin/desk-policy.sh"; echo "exit=$?"
```

It prints the effective policy as one JSON object, then `exit=0`. A line starting `desk-policy: ` (on stderr) is the one warning: print it once, as is, in the start report. `exit=1` (python3 missing) → the defaults hold; say so in the start report in one line.

## Interrupt rules

| Rule | While it holds |
|------|----------------|
| `everything` | Every new Decision is shown at the next tick, in sets of `set_size` (`decisions.md`). The default |
| `away` | Nothing is shown until the operator is available again |
| `focus` until a time | Nothing is shown until that time; the first tick after it shows everything that arrived meanwhile |

The rule is stored in the queue (`human-queue.sh interrupt`, state key `interrupt`) and belongs to this desk session: a desk registered later starts from the policy's `interrupt_rule`. While a rule holds, each tick still stamps the tick time (the desk stays live) but reports nothing and leaves the change feed where it is, so nothing that arrived during the hold is lost or reported twice: the first tick after the hold reports all of it, in the usual set order.

### The verbs

| The whole message (any case) | Does |
|------------------------------|------|
| `away` | Hold everything |
| `available`, or `back` outside a discussion (in one, `back` ends the discussion: `discuss.md`) | Show everything again, starting with what was held |
| `focus until <time>` | Hold until `<time>`: `15:30`, `3:30`, `3:30pm`, `3pm`, optionally ending ` ET`, the next time it comes in America/New_York (a 12-hour time without am or pm: whichever comes first); or an ISO 8601 time with a zone, `2026-10-07T19:30Z`, as `interrupt set focus --until` takes it; at most a day ahead |
| `focus for <N> min` | Hold for N minutes, 1 to 1440 (`<N>` digits only) |
| `focus off` | The same as `available` |
| `interrupts?` | Show the rule in force. Changes nothing |

Anything that does not fit this grammar exactly is not an interrupt verb: go back to `SKILL.md`'s reply order. Never guess one out of prose. The rule is set here, in conversation, and is **never printed unasked**: no tick, menu, or turn mentions it, except the start report of a desk that starts held and the acknowledgement of the verb just typed.

### Setting it

`away`, `available`, `back`, `focus off`:

<!-- test-anchor: desk-interrupt-set -->

```bash
"$HQ" interrupt set <away|everything> --session "$SID" --json; echo "exit=$?"
```

`focus until <time>`: the time goes through a quoted here-document, never into the command line (it is the operator's own text):

<!-- test-anchor: desk-interrupt-focus -->

```bash
WHEN_FILE=$(mktemp "${TMPDIR:-/tmp}/desk-when.XXXXXX")
cat > "$WHEN_FILE" <<'DESK_WHEN'
<the time, as typed after "focus until">
DESK_WHEN
"$HQ" interrupt set focus --session "$SID" --until "$(cat "$WHEN_FILE")" --json; rc=$?; rm -f "$WHEN_FILE"; echo "exit=$rc"
```

`focus for <N> min`: the same command with `--for <N>` in place of `--until …`.

- Exit 0 → `{"rule": "focus", "until": "2026-10-07T19:30:00Z", "until_local": "15:30", "held": true, "source": "desk"}`. Acknowledge in one line: `Away — new Decisions wait in the queue until you say "available".` or `Focus until 15:30 ET — new Decisions wait until then.` A focus ends back in the policy's rule, so when its `interrupt_rule` is `away` (`RULE` in block `desk-interrupt-get`), say `Focus until 15:30 ET — new Decisions wait until then, and after it until you say "available".` For `available`, the line is `Available.`, followed by the release (below).
- Exit 4 → nothing changed. Show its one stderr line (`the focus time is in the past`, `… more than a day ahead (use away instead)`, a time it could not read, or `this session is not the registered control session`).
- Exit 7 → the store is unreachable; nothing changed. `Can't reach the store — the interrupt rule is unchanged.`

### The release

After `available`, `back`, or `focus off`, run one tick now, so what was held renders at once instead of at the next cadence. Use the generation the Monitor runs with (`.desk.generation`, or the `GEN` in this conversation):

<!-- test-anchor: desk-release -->

```bash
"$DESK/bin/desk-tick.sh" --session "$SID" --generation "<GEN>" --once
```

Handle each line it prints exactly as the Monitor's (`SKILL.md`, "Monitor events"): a `new` line goes to `decisions.md`, "Showing items". No line means nothing arrived during the hold (or the Monitor's own tick got there first, and its `new` event arrives as a notification). A focus ends on its own, back in the policy's rule: when that is `everything`, the first tick after its time reports what was held, as a `new` event like any other; when it is `away`, the hold goes on until `available`.

When `/desk` started under the hold, its backlog has not been shown yet (`SKILL.md`, step 8): a tick reports only what changed during the hold, never the older open items. So the release does step 8's read instead, whole, whether or not the tick printed a line (the read covers that line's ids), and step 8's rule for the first `new` event after it applies. A focus that ends on its own into `everything` does the same at the first `new` event after its time, or at the operator's next message after it when no event comes.

A parked notice (`wakeups.md`) that arrives during a hold is held too: keep it in this conversation and print it after the release, or once the first `new` event after a focus ends has been shown. Wake-up retries themselves keep running during a hold; they show nothing.

### Reading it: `interrupts?`

<!-- test-anchor: desk-interrupt-get -->

```bash
RULE=$("$DESK/bin/desk-policy.sh" 2>/dev/null | jq -r '.interrupt_rule' 2>/dev/null); case "$RULE" in everything|away) ;; *) RULE=everything ;; esac
"$HQ" interrupt get --session "$SID" --default "$RULE"; echo "exit=$?"
```

It prints one line, `everything`, `away`, or `focus until 15:30 ET (2026-10-07 19:30 UTC)`, ending ` (default)` when no rule was set at this desk and the policy's applies. Print that line, `Interrupts: <it>`, and nothing else. `exit=7` → `Can't reach the store — can't read the interrupt rule right now.`

## Feedback tags

How the operator tunes the desk: after an item reached them, they say whether it was worth it.

| The operator types | Tag |
|--------------------|-----|
| `2: not important` | `not-important`: this should not have interrupted me |
| `2: should have defaulted` | `should-have-defaulted`: the agent should have taken its default |
| `2: good interrupt` | `good-interrupt`: this was worth the interruption |

The item is named by its number in the latest set this session opened (`decisions.md`, "Typed replies") or by its id (`D-43: not important`); a Review's `R-<n>` is not a tag's item, because a Review never interrupts. Several pairs may share one message (`1: good interrupt, 3: not important`). Any case; hyphens or spaces between the words; a trailing period is fine. **A tag is never an answer:** a message whose every pair is one of these three phrases is feedback, whatever the item's options say, and it answers nothing. A message that mixes tags with answers (`2: not important, 3: B`) is not feedback: it goes to `decisions.md` as a typed reply.

1. **Parse.** Confirm it is feedback, through a quoted here-document (the message is the operator's own text):

   <!-- test-anchor: desk-feedback-parse -->

   ```bash
   MSG_FILE=$(mktemp "${TMPDIR:-/tmp}/desk-msg.XXXXXX")
   cat > "$MSG_FILE" <<'DESK_MSG'
   <the operator's message, verbatim>
   DESK_MSG
   jq -c -Rs -L "$DESK/skill" 'include "desk"; desk_feedback' "$MSG_FILE"; rc=$?; rm -f "$MSG_FILE"; echo "exit=$rc"
   ```

   It prints `[{"ref": "2", "tag": "not-important"}, {"ref": "D-43", "tag": "good-interrupt"}]`, or `null` when the message is not feedback: go back to `SKILL.md`'s reply order at the next step. If the message contains a line that is exactly `DESK_MSG`, pick another delimiter for both lines.

2. **Record each pair**, in order. `ref` and `tag` come from step 1's output, never from the message itself:

   <!-- test-anchor: desk-feedback -->

   ```bash
   "$HQ" feedback <ref> <tag> --set <latest set_id> --json; echo "exit=$?"
   ```

   A number resolves through `--set`, the latest set this session opened; an id is used as it is (with no set opened yet, leave `--set` out). When the ref is a number and this session has opened no set yet, record nothing for it: `No set on screen — name the item, for example D-43: not important.`

   - Exit 0 → `{"id": "D-43", "tag": "not-important", "session": "…", "recorded": true}`: one `feedback` event, its note the tag and its session the asking thread (the item's return address). `"recorded": false` means the item already had that tag; nothing new was written.
   - Exit 4 → `no item D-43` or `set 12 has no item 5`: nothing was written for that pair. Exit 1 naming `migrate` → the store predates migration 008: run `"$HQ" migrate`, then this pair again.
   - Exit 7 → the store is unreachable; nothing was written. Say so in the acknowledgement; the operator can repeat it later.

3. **Acknowledge in one line** for the whole message: `Noted: D-43 not important, D-44 good interrupt.` (`(already noted)` after a pair with `"recorded": false`; a failed pair named with its reason). Nothing else: no menu, no state line. The tags are what later tuning and the attention report read; the desk does not change the rule on its own.
