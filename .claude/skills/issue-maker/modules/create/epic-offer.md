# Create: recommend a `/pm epic` thread for a big capture

> Load only for: `create:postfile` Step 9c's epic gate printed `EPIC_OFFER=<n>` or `EPIC_OFFER_STATE=<state> PARENT=<n>`
> Prerequisites: session state loaded; Step 9b tier known; Step 9c's cap read, offer stamp, acceptance and decline blocks in context

A capture that ends with a tracking parent bigger than one chain — more than five planned children, or scope still under `## Not yet cut` — is work for several waves. Running it in this thread ties the capture thread up for days, and `/pm epic #N` (`/pm` Step 0d) exists for exactly that. So the closing offer **recommends a new thread running `/pm epic #N`** for that parent and keeps the inline run as the second choice. Every other capture keeps Step 9c's offer word for word.

**What makes it fire, and nothing else.** The parent must be a row this session filed with `role:"parent"` and an `epic_scope` record (`create:doc-gate`), read through `epic_parent` (`session:state`). No title, label, keyword or body text is read, so an issue titled "epic …" never triggers it, and only an explicit `/pm epic #N` ever makes an issue an epic in `/pm`. This is the one place a capture thread recommends a chip; the rule exception it uses is `chip-launching.md` "PM-context inline gate", third non-routing case.

## 1. Read the repo's bound epic

`/pm epic` keeps one epic per repo in `.repos[<key>].epic`, with a single writer for its scope record. A second epic thread for the same repo would fight it, so read it first. Resolve `session-state.sh` to the first executable of `$HOME/.claude/skills-worktree/.claude/scripts/session-state.sh`, `$HOME/.claude/scripts/session-state.sh`, `.claude/scripts/session-state.sh` (skip the installed paths when `HOME` is unset or empty).

<!-- test-anchor: issue-maker-epic-bound -->
```bash
SESSION_STATE_SH=""
for candidate in "${HOME:+$HOME/.claude/skills-worktree/.claude/scripts/session-state.sh}" "${HOME:+$HOME/.claude/scripts/session-state.sh}" ".claude/scripts/session-state.sh"; do
  [ -n "$candidate" ] && [ -x "$candidate" ] && { SESSION_STATE_SH="$candidate"; break; }
done
EPIC_BOUND=""   # a number, "unreadable", or empty for none
if [ -z "$SESSION_STATE_SH" ]; then
  echo "DEGRADED: session-state.sh not found (checked all three paths) — cannot see a bound epic, recommending inline" >&2
  EPIC_BOUND=unreadable
else
  REPO_KEY=$(printf '%s' "$REPO" | tr '[:upper:]' '[:lower:]')
  BOUND_RC=0
  BOUND_JSON=$("$SESSION_STATE_SH" --get-json ".repos[\"$REPO_KEY\"].epic" 2>/dev/null) || BOUND_RC=$?
  case "$BOUND_RC" in
    0) if [ "$BOUND_JSON" != null ]; then
         EPIC_BOUND=$(printf '%s' "$BOUND_JSON" | jq -er 'select(type == "object" and (.number|type) == "number")
           | if .completed_at == null then (.number|tostring) else "" end' 2>/dev/null) || EPIC_BOUND=unreadable
       fi ;;
    3) ;;                       # no state file: nothing bound
    *) EPIC_BOUND=unreadable ;;
  esac
fi
printf 'EPIC_BOUND=%s\n' "${EPIC_BOUND:-none}"
```

A finished epic (`completed_at` set) does not hold the slot. `unreadable` is never read as "free": it gets the bound-epic offer below, naming the read failure.

## 2. Cap, stamp, record

Run Step 9c's repo-wide cap read as written. At `FREE == 0` (or an unreadable count) print Step 9c's deferral line and add one clause: `When work drains, start a new thread with /pm epic #<n> for the tracking parent.` Nothing is stamped, recorded or offered; no chip is suggested in its place.

Otherwise run Step 9c's offer-stamp block unchanged (it stamps every `runnable` row, exactly as an ordinary offer does), then record the offer in the same session — this receipt is what recovery reads:

<!-- test-anchor: issue-maker-epic-offer-record -->
```bash
: "${EPIC_PARENT:?take the parent from EPIC_OFFER=}"
: "${OFFER_TOKEN:?run the Step 9c offer stamp first}"
set_log "$MINE_DEF"'if .epic_offer != null and (.epic_offer.repository == $repo or .epic_offer.state == "offered" or .epic_offer.state == "thread")
    then error("an epic offer is already recorded; follow its state, or reconcile it in its own repository")
  elif ([.issues[] | epic_parent | select(.number == ($p|tonumber))] | length) != 1 then error("not a qualifying tracking parent from this session")
  else .epic_offer = {parent:($p|tonumber), repository:$repo, state:"offered", offer_token:$tok,
    bound_epic:(if $bound == "" or $bound == "none" then null else $bound end),
    offered_at:$ts} end' \
  --arg repo "$REPO" --arg p "$EPIC_PARENT" --arg tok "$OFFER_TOKEN" --arg bound "${EPIC_BOUND:-}" \
  --arg ts "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" || exit 1
```

A failed write stops before the question; the stamps it followed are ordinary offer tokens and the gate re-offers on resume. An answered (`inline` or `declined`) receipt from another repository in a shared log is replaced; an unanswered or `thread` one blocks until reconciled there.

**Refresh before an answer.** When more issues are filed while the offer is still `offered`, stamp the new `runnable` rows with the recorded token and name them in the re-asked question; the receipt itself is not replaced:

<!-- test-anchor: issue-maker-epic-offer-refresh -->
```bash
set_log "$MINE_DEF"'if .epic_offer == null or .epic_offer.repository != $repo or .epic_offer.state != "offered" then error("no open epic offer to refresh")
  else .epic_offer.offer_token as $tok | (.issues[] | runnable | select(.chip_task_id == null) | .chip_task_id) = $tok end' --arg repo "$REPO" || exit 1
```

## 3. Ask

Ask once through `AskUserQuestion` (vehicle `ask-menu.md`; typed prose only when headless), recommended option first. Name the parent, its planned and not-yet-cut counts, the inline tier from Step 9b with its model step-up warning, and the issues an inline run would cover, in filing order. When the gate printed `EPIC_LATER=`, name those parents in one line as next after this epic finishes (`/pm epic #<m>`); a repo runs one epic thread at a time, so there is never a second thread option.

- **No epic bound** (`EPIC_BOUND=none`): `"New thread: /pm epic #{N} (Recommended)"`, `"Run {K} issue(s) inline here"`, `"Leave them filed"`.
- **An epic already bound, or unreadable**: say `Epic #{M} already has the /pm epic thread for this repo` (or `could not read this repo's bound epic`), then `"Run {K} issue(s) inline here (Recommended)"`, `"Leave them filed"` — start `/pm epic #{N}` later, once #{M} finishes. No thread option.

Rapid-fire, one line, keeping Step 9b's step-up warning: `Epic #{N} plans {P} children ({U} not yet cut) — new /pm epic thread (recommended), inline here — {TIER} ({MODEL}/{EFFORT}), or leave filed?`; with an epic bound or unreadable, `Epic #{M} holds this repo's /pm epic thread — run {K} inline here — {TIER} ({MODEL}/{EFFORT}) (recommended), or leave filed?`

**Issues outside the epic.** When the session also filed `runnable` rows that are not on the parent's chain, the inline option covers all of them, as today, and the thread option covers only the parent's children. Say so in the question, naming the others: after a thread answer they stay filed with no pending offer, and the next step for them is `/subagent #x …` here or a fresh `/issue-maker` offer.

## 4. Record the answer

Set `EPIC_ANSWER` only from the user's actual choice: `thread`, `inline`, or `declined`. The write re-checks the parent under the session-log lock, so a parent retracted since the question, an answer for another parent, a repeated answer, or a thread answer while an epic was bound all fail with nothing changed. One switch is allowed: `thread` → `inline` while no handoff receipt exists yet (for example, the handoff's bound-epic re-check stopped it), so the inline choice survives without a second reservation.

<!-- test-anchor: issue-maker-epic-answer -->
```bash
case "${EPIC_ANSWER:-}" in thread|inline|declined) ;; *) echo "HOLD: record the user's actual answer (thread, inline or declined)" >&2; exit 1 ;; esac
: "${EPIC_PARENT:?answer the offer recorded for this parent}"
set_log "$MINE_DEF"'if .epic_offer == null or .epic_offer.repository != $repo or .epic_offer.parent != ($p|tonumber)
    or (.epic_offer.state != "offered" and ($a != "inline" or .epic_offer.state != "thread"))
    then error("no open epic offer for this parent")
  elif (.reg_tid // "") != "" or .handoff_checkpoint != null or .inline_checkpoint != null or .offer_accepted == true
    or .delivery_mode == "chip" or .delivery_mode == "chip-pending" or .delivery_mode == "chip-reserved"
    then error("reconcile existing execution receipt")
  elif $a == "thread" and .epic_offer.bound_epic != null then error("an epic is already bound in this repo; no second thread")
  elif $a == "thread" and ([.issues[] | epic_parent | select(.number == ($p|tonumber))] | length) != 1
    then error("tracking parent no longer qualifies")
  else .epic_offer.state = $a | .epic_offer.answered_at = $ts
    | if $a == "inline" then . else (.issues[] | mine | .chip_task_id) = null end end' \
  --arg repo "$REPO" --arg p "$EPIC_PARENT" --arg a "$EPIC_ANSWER" --arg ts "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" || exit 1
```

Then, by answer:

- **`inline`** — run Step 9c's **On yes** acceptance block with `USER_ACCEPTED=true`, the `/subagent` invocation, and the post-success receipt, unchanged. The recorded `inline` answer is the user's yes.
- **`declined`** — the write above already cleared the offer tokens, as Step 9c's decline does. Leave everything filed; say once that `/pm epic #{N}` in a new thread is still the way to run it later.
- **`thread`** — the write cleared this offer's inline stamps. Load `offer:handoff` with `HANDOFF_EPIC_PARENT={N}` and follow it from its cap check: reservation, frozen payload, `spawn_task` or printed block. Its payload is the epic variant (that module). The user's pick is the explicit request that module requires.

## 5. Recovery

The gate prints `EPIC_OFFER_STATE=<state> PARENT=<n>` while a receipt exists. Never ask again or re-stamp; resume by state:

| State | Next step |
|-------|-----------|
| `offered` | Ask section 3's question again from the recorded parent and `bound_epic` (no new record; only the refresh block stamps rows filed since). A parent retracted meanwhile was already dropped by the gate, and the ordinary offer runs. |
| `inline` | `.inline_checkpoint` set → Step 9c reconciliation only. `offer_accepted` → done. Neither → run the acceptance block from the recorded answer. |
| `thread` | `.handoff_checkpoint` set → `offer:handoff` reconciliation only, never a second reservation. None → load `offer:handoff` fresh with `HANDOFF_EPIC_PARENT`, or, when it stopped on a bound epic or the user now picks inline, record `EPIC_ANSWER=inline` and continue as `inline`. |
| `declined` | Nothing to run. A chip later is the on-request path. |
