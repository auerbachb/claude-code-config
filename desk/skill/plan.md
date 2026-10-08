# /desk — the day plan

Loaded when the operator's whole message is a plan verb (`plan`, `plan?`, `plan off`, `plan: …`), a plan sentence (`I need to work on …`), or a reply to a plan being agreed (`yes`, `no`, `4 sections`). Every Bash block starts with `SKILL.md`'s prelude (`DESK`, `HQ`, `SID`). Issue #1784; design: `desk/DESIGN.md` 2.8 ("the day is planned in conversation"), 5.5, and figure 5.4.

**What a plan is.** A short conversation that ends in stored blocks: what the operator works on, at what pace, until when, and what to clear first. The desk proposes the order; the operator confirms it or changes it in one sentence. Once stored (`human-queue.sh plan set`), each block **holds new Decisions until it ends**, exactly like `focus until <the block's end>` (`interrupts.md`): they wait in the store, and the first tick after the block shows them in sets. Blocks are a tick cadence apart, so that tick always lands between two blocks. Nothing here changes how often agents ask or what they decide on their own.

**Plain text only, never AskUserQuestion.** In the desk's own session the capture hook queues any menu that lacks the `N. [D-id]` prefix as a new Decision, so every card here is a blockquote and the reply is typed.

## The grammar

`desk.jq`'s `desk_plan_parse` reads the whole message, so a plan is never guessed out of prose:

| The whole message (any case; a final period is fine) | Is |
|------------------------------------------------------|----|
| `plan` | start a plan: the desk asks what and how fast |
| `plan?` | show today's plan |
| `plan off`, `plan clear`, `no plan`, `drop the plan` | clear it (or drop the one being agreed) |
| `plan: <text>` | change today's plan with `<text>` (or start one when there is none) |
| `I need to work on <text>` — also `I have to`, `I want to`, `I will`, `I'm going to work on`, `I'm working on`, `let me` / `let's work on`, `today is for`, `this morning is for`, `this afternoon is for` | a new plan for `<text>` |
| While a plan is being agreed: `yes`, `ok`, `sounds right` … / `no`, `cancel`, `never mind` … / a sentence with a pace or an extent in it (`4 sections`, `45 min a section`, `until 12:30`, `for 90 min`) | confirm / drop / change it |

In `<text>` the item is what comes before the first comma, colon, semicolon, dash, or field (`the PRD`); a **pace** is `30 min a section`, `an hour a chapter`, `each section takes about 30 minutes`, or `20 min each`; an **extent** is `4 sections`, `until 12:30` (`3pm`, `noon`; the next time it comes, a bare `3` the sooner of am and pm), or `for 90 min`. A plan sentence is a plan only when no long-form prompt waits and no discussion is open: there it is an answer or part of the discussion. The `plan` verbs work at any time.

## 1. Parse

<!-- test-anchor: desk-plan-parse -->

```bash
PLAN_MSG=$(mktemp "${TMPDIR:-/tmp}/desk-plan-msg.XXXXXX")
cat > "$PLAN_MSG" <<'DESK_PLAN_MSG'
<the operator's message, verbatim>
DESK_PLAN_MSG
jq -c -Rs -L "$DESK/skill" --argjson pending <false|true|"item"> 'include "desk"; desk_plan_parse($pending)' "$PLAN_MSG"; rc=$?; rm -f "$PLAN_MSG"; echo "exit=$rc"
```

`pending` is `false` when no plan is being agreed, `"item"` when the desk's last plan card asked what the plan is for, and `true` while any other plan card waits for its reply. It prints `{"trigger": "work", "confirm": false, "cancel": false, "fields": {"item": "the PRD", "pace_min": 30, "chunk": "section", "count": null, "until": null, "for_min": null}}`. If the message holds a line that is exactly `DESK_PLAN_MSG`, pick another delimiter for both lines. Then:

| It printed | Do |
|------------|----|
| `trigger` `show` | step 6 |
| `trigger` `off` | a plan being agreed → drop it: `Dropped the proposed plan.` Else step 7 |
| `confirm` true, a proposal with blocks waiting | step 3 |
| `cancel` true, a plan being agreed | `Dropped the proposed plan.` |
| `trigger` `work` or `plan` | step 2, with the inputs `{}` (a new plan replaces one being agreed) |
| `trigger` `revise` | a plan being agreed → step 2 with its inputs; else step 4 |
| `trigger` null, a plan being agreed, any field not null | step 2 with its inputs |
| anything else | not about the plan: back to `SKILL.md`'s reply order, at the step after this one. A plan being agreed stays waiting |

## 2. Propose

<!-- test-anchor: desk-plan-propose -->

```bash
PLAN_MSG=$(mktemp "${TMPDIR:-/tmp}/desk-plan-msg.XXXXXX"); PLAN_PREV=$(mktemp "${TMPDIR:-/tmp}/desk-plan-prev.XXXXXX")
PLAN_FC=$(mktemp "${TMPDIR:-/tmp}/desk-plan-fc.XXXXXX"); PLAN_DEC=$(mktemp "${TMPDIR:-/tmp}/desk-plan-dec.XXXXXX")
PLAN_REV=$(mktemp "${TMPDIR:-/tmp}/desk-plan-rev.XXXXXX"); PLAN_OUT=$(mktemp "${TMPDIR:-/tmp}/desk-plan-out.XXXXXX")
cat > "$PLAN_MSG" <<'DESK_PLAN_MSG'
<the operator's message, verbatim>
DESK_PLAN_MSG
cat > "$PLAN_PREV" <<'DESK_PLAN_PREV'
<the inputs agreed so far, as JSON: {} for a new plan>
DESK_PLAN_PREV
rc=0
"$HQ" plan forecast --json > "$PLAN_FC" || rc=$?
if [ "$rc" -eq 0 ]; then "$HQ" list --kind decision --status open --json > "$PLAN_DEC" || rc=$?; fi
if [ "$rc" -eq 0 ]; then "$HQ" list --kind reviews --unreviewed --json > "$PLAN_REV" || rc=$?; fi
if [ "$rc" -eq 0 ]; then
  TZ=America/New_York jq -c -Rs -L "$DESK/skill" --slurpfile prev "$PLAN_PREV" --slurpfile fc "$PLAN_FC" \
    --slurpfile dec "$PLAN_DEC" --slurpfile rev "$PLAN_REV" --argjson gap <N> \
    'include "desk"; ($prev[0] // {}) as $p
     | desk_plan_parse(if $p.item == null then "item" else true end) as $m
     | {inputs: ((if $m.trigger == "work" then {} else $p end) | desk_plan_merge($m.fields)),
        forecast: $fc[0], decisions: $dec[0], reviews: ($rev[0].items // []), gap: $gap, batch_min: 10}
     | desk_plan_propose' "$PLAN_MSG" > "$PLAN_OUT" || rc=$?
fi
if [ "$rc" -eq 0 ]; then cat "$PLAN_OUT"; TZ=America/New_York jq -r -L "$DESK/skill" 'include "desk"; plan_card' "$PLAN_OUT"; fi
rm -f "$PLAN_MSG" "$PLAN_PREV" "$PLAN_FC" "$PLAN_DEC" "$PLAN_REV" "$PLAN_OUT"; echo "exit=$rc"
```

`<N>` is the desk's tick cadence in minutes (5 unless `/desk --cadence` set another): the gap between blocks. The inputs go in their own quoted here-document because they hold the operator's words. The first line printed is the proposal (JSON); keep its `inputs` in this conversation as the plan being agreed. The rest is the card: print it as is, and nothing else.

- **A question** (`missing` is `["item"]` or `["pace"]`): what the plan is for, or how fast it will go and in what chunks, with what is waiting now and the forecast. The reply comes back through step 1 with `pending` `"item"` or `true`.
- **A proposal** (`blocks` not empty): the forecast; `1. Clear first, about 10 min: D-44, D-41, D-42, D-43, R-7.`; one line per block, `09:10–09:40 ET · the PRD, section 1 of 4 · everything held.`; then what was held, and the Decisions left for later. Waiting for `yes`, `no`, or one sentence that changes it.
- **`problem`** (no block fits, for example `until 9:05` at 9:00): the card says so; one sentence changes it.

How the order is built (`desk_plan_propose`): the **clear-first batch** is the parked menu-shaped Decisions, then the other menu-shaped ones, then unreviewed Reviews, while they fit in ten minutes (a Decision at its declared minutes cost, else 2; a Review at 2). Long-form Decisions and what does not fit are **later**: shown at the first block's end. The first block starts when the batch is done; with no count, `until`, or `for`, the plan is one chunk; `for 90 min` counts from the first block's start, so the minute it takes to say `yes` never shortens it; at most 24 blocks, all within a day (when fewer fit than were asked for, the card says so). The **forecast** reads `plan forecast`: the Decisions asked in the last three hours, by how many threads, and so how many more to expect by the last block's end, all held until each block ends.

`exit=7` → `Can't reach the store — can't plan right now; nothing was stored.` and keep the plan being agreed. Any other non-zero exit is the CLI's or jq's one line to show.

## 3. Store it (`yes`)

The plan is built again from now with the same inputs (a minute's wait moves the times), then stored:

<!-- test-anchor: desk-plan-store -->

```bash
PLAN_PREV=$(mktemp "${TMPDIR:-/tmp}/desk-plan-prev.XXXXXX"); PLAN_FC=$(mktemp "${TMPDIR:-/tmp}/desk-plan-fc.XXXXXX")
PLAN_DEC=$(mktemp "${TMPDIR:-/tmp}/desk-plan-dec.XXXXXX"); PLAN_REV=$(mktemp "${TMPDIR:-/tmp}/desk-plan-rev.XXXXXX")
PLAN_OUT=$(mktemp "${TMPDIR:-/tmp}/desk-plan-out.XXXXXX"); PLAN_REC=$(mktemp "${TMPDIR:-/tmp}/desk-plan-rec.XXXXXX")
PLAN_SET=$(mktemp "${TMPDIR:-/tmp}/desk-plan-set.XXXXXX")
cat > "$PLAN_PREV" <<'DESK_PLAN_PREV'
<the inputs of the proposal on screen, as JSON>
DESK_PLAN_PREV
rc=0
"$HQ" plan forecast --json > "$PLAN_FC" || rc=$?
if [ "$rc" -eq 0 ]; then "$HQ" list --kind decision --status open --json > "$PLAN_DEC" || rc=$?; fi
if [ "$rc" -eq 0 ]; then "$HQ" list --kind reviews --unreviewed --json > "$PLAN_REV" || rc=$?; fi
if [ "$rc" -eq 0 ]; then
  TZ=America/New_York jq -c -n -L "$DESK/skill" --slurpfile prev "$PLAN_PREV" --slurpfile fc "$PLAN_FC" \
    --slurpfile dec "$PLAN_DEC" --slurpfile rev "$PLAN_REV" --argjson gap <N> \
    'include "desk"; {inputs: ($prev[0].inputs // $prev[0]), forecast: $fc[0], decisions: $dec[0],
                      reviews: ($rev[0].items // []), gap: $gap, batch_min: 10} | desk_plan_propose' > "$PLAN_OUT" || rc=$?
fi
if [ "$rc" -eq 0 ]; then jq -c -L "$DESK/skill" 'include "desk"; plan_record' "$PLAN_OUT" > "$PLAN_REC" || rc=$?; fi
if [ "$rc" -eq 0 ]; then
  "$HQ" plan set --session "$SID" --json < "$PLAN_REC" > "$PLAN_SET" || rc=$?
fi
if [ "$rc" -eq 0 ]; then
  jq -c '{batch_decisions: .batch.decisions, batch_reviews: .batch.reviews}' "$PLAN_OUT"
  TZ=America/New_York jq -r -L "$DESK/skill" 'include "desk"; plan_show' "$PLAN_SET"
  jq -r -L "$DESK/skill" --slurpfile out "$PLAN_OUT" \
    'include "desk"; .items[] | select(.id as $i | $out[0].batch.reviews | index($i)) | review_line' "$PLAN_REV"
fi
rm -f "$PLAN_PREV" "$PLAN_FC" "$PLAN_DEC" "$PLAN_REV" "$PLAN_OUT" "$PLAN_REC" "$PLAN_SET"; echo "exit=$rc"
```

- **Exit 0** prints the batch's ids (`{"batch_decisions": [...], "batch_reviews": [...]}`), then today's plan as a card (print it), then one line per Review in the batch (print them under the card). The plan is no longer being agreed. Then show the batch's Decisions now: `decisions.md`, "Showing items", with those ids (long-form ones never come here: they are `later`). From the first block's start, new Decisions are held; `interrupts?` reads `focus until 09:40 ET (… UTC) (plan)`.
- **Exit 4** from `plan set` → nothing was stored; its one stderr line names why (`the blocks overlap`, `every block has already ended`, `this session is not the registered control session`). Show it; the plan is still being agreed.
- **Exit 7** → `Can't reach the store — the plan was not stored; say yes again once it is back.` Keep the plan being agreed.

## 4. Change it in one sentence (`plan: …`)

With a plan stored today and none being agreed, `plan: <text>` changes it at once: the chunks still to do are planned again from now (from the first block's start, when none has begun), keeping what to clear first and what waits for later. A count in the sentence is the chunks still to do (`plan: 2 sections` → two more); without one, the old count less the blocks already over.

<!-- test-anchor: desk-plan-revise -->

```bash
PLAN_MSG=$(mktemp "${TMPDIR:-/tmp}/desk-plan-msg.XXXXXX"); PLAN_ST=$(mktemp "${TMPDIR:-/tmp}/desk-plan-st.XXXXXX")
PLAN_FC=$(mktemp "${TMPDIR:-/tmp}/desk-plan-fc.XXXXXX"); PLAN_OUT=$(mktemp "${TMPDIR:-/tmp}/desk-plan-out.XXXXXX")
PLAN_REC=$(mktemp "${TMPDIR:-/tmp}/desk-plan-rec.XXXXXX")
cat > "$PLAN_MSG" <<'DESK_PLAN_MSG'
<the operator's message, verbatim>
DESK_PLAN_MSG
rc=0
"$HQ" plan get --json > "$PLAN_ST" || rc=$?
if [ "$rc" -eq 0 ] && [ "$(jq -r '.plan == null' "$PLAN_ST")" = true ]; then echo "no-plan"; rc=3; fi
if [ "$rc" -eq 0 ]; then "$HQ" plan forecast --json > "$PLAN_FC" || rc=$?; fi
if [ "$rc" -eq 0 ]; then
  TZ=America/New_York jq -c -Rs -L "$DESK/skill" --slurpfile st "$PLAN_ST" --slurpfile fc "$PLAN_FC" --argjson gap <N> \
    'include "desk"; desk_plan_parse(true) as $m
     | {inputs: ($st[0].plan.inputs | desk_plan_merge($m.fields)), forecast: $fc[0], stored: $st[0].plan, gap: $gap}
     | desk_plan_propose' "$PLAN_MSG" > "$PLAN_OUT" || rc=$?
fi
if [ "$rc" -eq 0 ] && [ "$(jq -r '.missing == [] and .problem == null' "$PLAN_OUT")" = true ]; then
  jq -c -L "$DESK/skill" 'include "desk"; plan_record' "$PLAN_OUT" > "$PLAN_REC" || rc=$?
  if [ "$rc" -eq 0 ]; then "$HQ" plan set --session "$SID" --json < "$PLAN_REC" > /dev/null || rc=$?; fi
fi
if [ "$rc" -eq 0 ]; then TZ=America/New_York jq -r -L "$DESK/skill" 'include "desk"; plan_card' "$PLAN_OUT"; fi
rm -f "$PLAN_MSG" "$PLAN_ST" "$PLAN_FC" "$PLAN_OUT" "$PLAN_REC"; echo "exit=$rc"
```

- **Exit 0** → print the card: `Plan revised: …` and the blocks still to come, already stored (a `problem` card stores nothing; the old plan stands).
- **`no-plan`, exit 3** → there is no plan today: run step 2 with the inputs `{}` and the same message, as a new plan.
- Exit 4 and 7 as in step 3 (the old plan stands).

## 5. While a block runs, and after it

- **The hold.** `tick` holds new Decisions while a block is in force, the way it holds for a focus (`interrupts.md`, "The release"): nothing is lost, and the first tick after the block reports everything that arrived during it, shown through `decisions.md` as usual. The desk keeps ticking, so worker threads keep queueing their questions here.
- **Later.** At the first `new` event after the first block's end (or at the operator's next message after it, when no event comes), also show the plan's `later` Decisions that are still open (`plan get --json`, `.plan.later`): `decisions.md`, "Showing items", with those ids, then the long-form ones (`longform.md`).
- **The operator's own rule wins.** `away` holds until `available`, plan or not. `focus until …` holds until its own time. `available` (or `focus off`) during a block releases **that block only**: the next block holds again. `plan off` ends every hold the plan made.
- **Nothing is printed unasked** about blocks starting or ending; the held Decisions arriving is the signal.

## 6. `plan?`

<!-- test-anchor: desk-plan-show -->

```bash
PLAN_ST=$(mktemp "${TMPDIR:-/tmp}/desk-plan-st.XXXXXX")
"$HQ" plan get --json > "$PLAN_ST"; rc=$?
if [ "$rc" -eq 0 ]; then TZ=America/New_York jq -r -L "$DESK/skill" 'include "desk"; plan_show' "$PLAN_ST"; fi
rm -f "$PLAN_ST"; echo "exit=$rc"
```

Print it: today's plan with each block's times, `over` or `now, everything held`, and what waits for later; or `No plan for today.` `exit=7` → `Can't reach the store — can't read the plan right now.`

## 7. `plan off`

<!-- test-anchor: desk-plan-clear -->

```bash
"$HQ" plan clear --session "$SID" --json; echo "exit=$?"
```

`{"cleared": true}` → `Plan cleared — new Decisions show at the next tick again.` (run the release, `interrupts.md` block `desk-release`, so what the block held shows now). `{"cleared": false}` → `No plan to clear.` Exit 4 → its one line; exit 7 → `Can't reach the store — the plan is unchanged.`

## What is stored

One state row, the reserved key `plan`: `{"version", "day", "session", "set_at", "item", "pace", "inputs", "clear_first", "later", "blocks": [{"item", "label", "pace", "start", "until"}]}`. A plan from another day is not today's (`plan get` reads `null`) and holds nothing, even a block of it that runs past midnight. No event is written (`desk/DESIGN.md` 2.5: logging is state changes of items only), and the dialogue itself is never stored.
