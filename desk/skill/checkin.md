# /desk — the morning check-in and the reading budget

Loaded on a `desk-tick <GEN> morning` event, when the operator's whole message is `check-in` / `checkin` (any case) or `budget?`, when a new plan starts with no check-in today (`plan.md`, step 1), and for the reply to a check-in card. Every Bash block starts with `SKILL.md`'s prelude (`DESK`, `HQ`, `SID`). Issue #1770; design: `desk/DESIGN.md` 2.8 ("a morning check-in plus yesterday's measured pace sets today's reading budget, starting from the 30 × 20 guess") and 5.5 ("it tells you yesterday's pace and asks how long you have").

**What it is.** Three answers once a day — hours at the desk today, energy in one word, anything planned — plus the pace measured from your own events produce **today's reading budget**: how many Reviews to read today. The desk shows the budget once, keeps the running count in the Reviews view (`reviews.md`), and the day plan schedules at most what is left (`plan.md`). Nothing here changes how often agents ask or what they decide on their own.

**Plain text only, never AskUserQuestion.** In the desk's own session the capture hook queues any menu that lacks the `N. [D-id]` prefix as a new Decision, so the card is a blockquote and the reply is typed.

## When

- **`desk-tick <GEN> morning`**: the first tick of the day from 04:00 until `desk/policy.json`'s `eod_time` (`human-queue.sh checkin due` marks the day, so it comes once). A desk started in the morning gets it from its first tick; a desk left running overnight asks at 04:00 and the card waits for you.
- **`check-in`** (or `checkin`) as the whole message, at any time: the card again; a new answer replaces today's and computes the budget again (an afternoon that turned out shorter, say).
- **`budget?`**: today's budget and the running count (step 4).
- **A new plan with no check-in today** (`plan`, `I need to work on …`): `plan.md` sends it here first; after the check-in is stored or skipped, the plan goes on (step 3).

**Held like a Decision.** A `morning` event that arrives during `away`, a focus, or a plan block (`interrupts.md`) is kept in this conversation and shown after the release; one that arrives while a long-form prompt waits is shown when that group ends (`longform.md`, "Tick events while a prompt waits").

## 1. The card

<!-- test-anchor: desk-checkin-card -->

```bash
CHK_GET=$(mktemp "${TMPDIR:-/tmp}/desk-checkin-get.XXXXXX")
"$HQ" checkin get --json > "$CHK_GET"; rc=$?
if [ "$rc" -eq 0 ]; then
  jq -c '{checked_in: (.checkin != null)}' "$CHK_GET"
  jq -r -L "$DESK/skill" 'include "desk"; checkin_card' "$CHK_GET"
fi
rm -f "$CHK_GET"; echo "exit=$rc"
```

The first line says whether today's check-in is already stored. **From a new plan** with `{"checked_in":true}` → print nothing here and go straight back to `plan.md` step 2. Otherwise print the rest as is: one blockquote and one line.

```text
> **Morning check-in · Thu Oct 8**
> Yesterday: 22 Reviews read in about 3 h at the desk, 7.3 an hour; 6 Decisions answered, median 4 min from shown to answered.
> Waiting now: 18 unreviewed Reviews.
> 1. Hours at the desk today?
> 2. Energy, in one word? (for example low, ok, high)
> 3. Anything planned? (a piece of work and its pace, meetings, or none)

Reply in one line, `hours, energy, plan`: `4, ok, the PRD until noon`. `skip` leaves today without a reading budget.
```

With no measured day in the last week the second line says so, and today starts from the 30 × 20 guess. The card is now **waiting for its reply** (keep that in this conversation until it is answered or skipped). `exit=7` → `Can't reach the store — the check-in waits until it is back; say "check-in" then.`

## 2. The reply

While a check-in waits, a message that `desk.jq`'s `checkin_parse` reads as a reply is one (`SKILL.md`, "Replies the operator types"): hours, energy, and the plan, separated by commas, semicolons, or line breaks (`4, ok, the PRD until noon`; `4h; tired`; `90 min, high, meetings 11-12`), or by spaces (`4h ok the PRD, 30 min a section`). Hours are a number up to 16 (`4`, `4.5`, `4h`, `four`, `half an hour`, `90 min`, `0`); energy is one word (`Pretty tired` → `tired`); the plan may be left out or `none`. `skip` (also `not today`, `no check-in`) skips it. A message missing hours or energy is not a reply: it goes on through the router, and the check-in keeps waiting.

<!-- test-anchor: desk-checkin-store -->

```bash
CHK_MSG=$(mktemp "${TMPDIR:-/tmp}/desk-checkin-msg.XXXXXX"); CHK_P=$(mktemp "${TMPDIR:-/tmp}/desk-checkin-p.XXXXXX")
CHK_OUT=$(mktemp "${TMPDIR:-/tmp}/desk-checkin-out.XXXXXX")
cat > "$CHK_MSG" <<'DESK_CHECKIN_MSG'
<the operator's reply, verbatim>
DESK_CHECKIN_MSG
rc=0
jq -c -Rs -L "$DESK/skill" 'include "desk"; checkin_parse | . + {plan: (.planned | checkin_planned_plan)}' "$CHK_MSG" > "$CHK_P" || rc=$?
if [ "$rc" -eq 0 ]; then cat "$CHK_P"; fi
if [ "$rc" -eq 0 ] && [ "$(jq -r '.skip == false and .missing == []' "$CHK_P")" = true ]; then
  set -- --session "$SID" --hours "$(jq -r '.hours' "$CHK_P")" --energy "$(jq -r '.energy' "$CHK_P")"
  if [ "$(jq -r '.planned != null' "$CHK_P")" = true ]; then set -- "$@" --planned "$(jq -r '.planned' "$CHK_P")"; fi
  "$HQ" checkin set "$@" --json > "$CHK_OUT" || rc=$?
  if [ "$rc" -eq 0 ]; then jq -r -L "$DESK/skill" 'include "desk"; budget_card' "$CHK_OUT"; fi
fi
rm -f "$CHK_MSG" "$CHK_P" "$CHK_OUT"; echo "exit=$rc"
```

The reply goes in its own quoted here-document because it holds the operator's words; if it holds a line that is exactly `DESK_CHECKIN_MSG`, pick another delimiter for both lines. The first line printed is the parsed reply (`{"skip", "hours", "energy", "planned", "missing", "plan"}`), then:

- **Stored, exit 0** → print the budget card as is — this is the one time it is shown unasked. The check-in no longer waits.

  ```text
  > **Reading budget today: 28 Reviews (~560 lines at level 2)**
  > Yesterday's pace, 7 an hour × 4 h × energy ok (1) = 28.
  > 18 waiting now · 0 read so far today.
  > Planned: the PRD until noon.
  ```

  Then, when `plan` is `true` (the plan is a piece of work with a pace or an extent, by `plan.md`'s grammar: `the PRD, 30 min a section`, `the deck until 12:30`, `meetings until noon`), go on into `plan.md` step 2 with the planned text as the message and the inputs `{}`: the day plan proposes the blocks, with the budget in its card. A plan sentence that sent you here (step 3 below) takes precedence over the planned text.
- **`skip` true** → nothing stored: `No check-in today — no reading budget; say "check-in" any time.` The check-in no longer waits.
- **`missing` not empty** → not a reply (the message goes on through the router).
- **Exit 4** → its one stderr line (`--hours must be …`, `--planned is longer than 200 characters`, `this session is not the registered control session`); nothing was stored and the check-in still waits. **Exit 5** → `That plan looks like it holds a credential — not stored. Reword it.` **Exit 7** → `Can't reach the store — the check-in was not stored; reply again once it is back.`

## 3. From a new plan

`plan.md`, step 1: a `plan` or a plan sentence while no check-in is stored today runs step 1 here first, keeping the operator's plan sentence in this conversation. After the reply is stored (or skipped), go on with `plan.md` step 2 with **that sentence** as the message, so the plan the operator asked for is the one proposed, now with the budget in its card.

## 4. `budget?`

<!-- test-anchor: desk-budget-show -->

```bash
CHK_GET=$(mktemp "${TMPDIR:-/tmp}/desk-checkin-get.XXXXXX")
"$HQ" checkin get --json > "$CHK_GET"; rc=$?
if [ "$rc" -eq 0 ]; then jq -r -L "$DESK/skill" 'include "desk"; budget_card' "$CHK_GET"; fi
rm -f "$CHK_GET"; echo "exit=$rc"
```

Print it as is: the budget card with the running count, or `No check-in today, so no reading budget. Say "check-in" to set one.` `exit=7` → `Can't reach the store — can't read the budget right now.`

## How the budget is computed

`human-queue.sh checkin set` computes it once, when the check-in is stored (`checkin --help`; the measurements are `stats --help`):

- **The measured pace**: Reviews read (a `reviewed` or `flagged` event) per hour at the desk, on the most recent of the last 7 days with at least 3 Reviews read. Time at the desk is estimated from your own actions (answers, reviews, flags, feedback tags): the minutes since the previous one, when at most 15; else 2 (a break, or the day's first).
- **Budget** = round(that pace × today's hours × the energy factor). With no measured day, the starting guess: round(30 × the energy factor), the 30 × 20 of the design (30 Reviews, 20 lines each at level 2). Zero hours is zero.
- **The running count**: Reviews read today, against the budget; `left` goes negative once you are over. It is shown in the Reviews view (`Reading budget: 9 of 28 Reviews read today · 19 left`) and in the day plan's card, and the plan's clear-first batch takes at most what is left.

### Energy factors

| Word | Factor |
|------|--------|
| `low`, `tired` | 0.7 |
| `ok`, `fine`, `normal`, `good` | 1 |
| `high`, `great` | 1.2 |

A word in neither list counts 1 (the budget card says so). **The operator changes or adds factors** by telling the desk (`energy meh is 0.8`, `make low 0.6`): run `"$HQ" state set energy_factors '<the whole table as JSON>'` with every override the operator has set, for example `{"low": 0.6, "meh": 0.8}`. A word is lowercase letters or hyphens, up to 20; a factor is a number from 0 to 2; anything else in the table is ignored. `"$HQ" state get energy_factors` shows the overrides; `checkin get --json`'s `factors` shows the table in force.

## What is stored

One state row, the reserved key `checkin`: `{"version", "day", "session", "set_at", "hours", "energy", "factor", "factor_known", "planned", "budget", "lines", "basis": {"kind": "measured", "day", "reviewed", "active_min", "rate"} | {"kind": "guess", "items", "lines_per_item"}}`, and the reserved key `checkin_asked` (the day the card was last due). A check-in from another day is not today's (`checkin get` reads `null`). No event is written (`desk/DESIGN.md` 2.5: logging is state changes of items only), and the conversation itself is never stored.
