# Retract issue

> Load only for: close/retract request for an existing issue
> Prerequisites: session state loaded; issue number and target repo identified

## Step 12: Retract

Phrases like **"scratch that, close #N"**, **"retract #N"**, **"never mind on #N"**:

### Retracting a member of an increment chain (check this first)

First fetch `gh issue view "$N" --repo "$REPO" --json number,url,state` successfully and retain its URL for the closing line; a missing/unreadable issue is a blocker. Look up `#N`'s `chain` field in `$LOG` before closing anything. If it is `null`, this is an ordinary retract — continue below unchanged. If it names a `chain_id`, check for still-open successors. When one or more exist, **the rest of that chain has to be dealt with in the same breath**, because closing an increment silently strands everything behind it. If `SUCCESSORS` is empty, skip the chain question and continue through the ordinary retract path:

```bash
SUCCESSORS=""
# Read this issue's chain identity first — empty chain_id means an ordinary retract.
CHAIN_ID=$(jq -r --arg n "$N" --arg repo "$REPO" \
  "$MINE_DEF"'first(.issues[] | select(.number == ($n|tonumber) and same_repo) | .chain.chain_id // empty) // empty' "$LOG")
POSITION=$(jq -r --arg n "$N" --arg repo "$REPO" \
  "$MINE_DEF"'first(.issues[] | select(.number == ($n|tonumber) and same_repo) | .chain.position // empty) // empty' "$LOG")

# Successors = same chain_id, higher position, still open. Pass POSITION in as a
# number so the comparison is numeric, not a string compare (10 < 9 as strings).
if [ -n "$CHAIN_ID" ]; then
  SUCCESSORS=$(jq -r --arg c "$CHAIN_ID" --argjson p "${POSITION:-0}" --arg repo "$REPO" \
    "$MINE_DEF"'[.issues[]
      | select(same_repo and .chain.chain_id == $c and .status == "open" and (.chain.position > $p))]
     | sort_by(.chain.position) | .[].number' "$LOG")
fi
```

**Why this cannot be skipped.** A successor's `Depends on #prev` points at the retracted issue, and the chain-release rule (`/subagent` 6.0b) starts queued work only when its predecessor reaches a **genuinely terminal state — `merged` or `blocked`**. A retracted issue is *closed*, which is neither, so every successor waits on a predecessor that will never merge and never blocks: queued forever, with nothing in the system flagging it. Retracting the **head** strands the entire chain; retracting a **middle** increment strands everything after it and leaves the survivors describing slices of a plan that no longer exists.

Only when `SUCCESSORS` is non-empty, name the affected successors and take one of two paths, then proceed with the close below:

- **Retract the whole chain** (the usual call when the head goes, or when the ask itself is cancelled) — close every open member of the chain, each with the same retraction comment, then run the hand-off logic **once, after the last close**: by then no chain member is open, so `SHARERS` reflects only issues outside the chain and the ordinary retract's two branches decide correctly (withdraw if nothing is left, refresh if the session filed other issues too). Running it per member would refresh the hand-off once per close for no benefit.
- **Re-cut the remainder** (when only one slice was wrong) — keep the successors, but repoint the one immediately after `#N` at `#N`'s own predecessor (or drop its `Depends on` line entirely if `#N` was the head), and renumber the `{i}/{n}` markers in the surviving titles so the chain still reads as a chain. This is a `/update` on each survivor (Step 10), not a new filing.

**Present the choice via `AskUserQuestion` when available** (options: `"Retract whole chain (Recommended)"`, `"Re-cut remainder"`; prose fallback in headless runs): it is the rare genuinely blocking call — both outcomes are destructive in different directions, and the increments are not interchangeable. State the successor numbers in the question text. In rapid-fire, ask this one anyway; it is the same class as the two hard bars. See `ask-menu.md` for the full vehicle convention.

### Ordinary retract

Save `OFFER_TOKEN`, `OFFER_ACCEPTED`, `delivery_mode`, and `reg_tid` read-only before closing. Retain this snapshot in the checkpoint for retry/recovery. The cleanup section uses that saved token and computes sharers from the updated log after all intended closes.

**Order is mandatory:** inspect the offer and chain read-only, resolve any required `update:edit`/`create:postfile` module paths before closing, obtain the chain choice and concrete survivor-edit confirmations when needed, then confirm each remote close. Do not mutate offer tokens, registry state, chain metadata, or print withdrawal/refresh success before GitHub confirms the close. If the close is uncertain and verification fails, leave the log and registry untouched.

```bash
if ! gh issue close "$N" --repo "$REPO" --comment "Retracted via /issue-maker — not needed."; then
  # The response may be lost after GitHub applied the close. Verify before any
  # retry; unknown state means stop with the log untouched.
  REMOTE_STATE=$(gh issue view "$N" --repo "$REPO" --json state --jq '.state') || {
    echo "ERROR: close result is uncertain and issue state could not be verified; do not retry yet" >&2
    exit 1
  }
  if [[ "$REMOTE_STATE" != "CLOSED" ]]; then
    echo "ERROR: issue #$N remains $REMOTE_STATE; log state was not changed" >&2
    exit 1
  fi
fi

# Only remote confirmation authorizes a local status change. Retain the token
# until offer/registry cleanup confirms success, so cleanup can be retried.
set_log "$MINE_DEF"'(.issues[] | select(.number == ($n|tonumber) and same_repo) | .status) = "closed" |
  if .active_chain.chain_id == $chain and .active_chain.repository == $repo
     and ([.issues[] | mine | select(.chain.chain_id == $chain)] | length) == 0
  then .active_chain = null else . end' \
  --arg n "$N" --arg repo "$REPO" --arg chain "${CHAIN_ID:-}" || {
  echo "ERROR: GitHub confirms the close, but the session log update failed; keep the checkpoint and retry local reconciliation" >&2
  exit 1
}
```

### Re-cut bookkeeping (only after confirmed remote edits)

For a re-cut, resolve/read `update:edit` and use its fetch → concrete diff → confirm → apply → verify path for each surviving member, including predecessors whose title denominator changes. Preserve chain order, replace/drop the immediate successor's dependency, and rename every survivor to its new `{i}/{n}` marker. Stage the complete re-cut plan before closing; after the close, run these approved edits. A failed/uncertain edit stops the re-cut with its next step checkpointed; do not claim that all survivors were repaired. After each survivor's remote edit is verified, persist **both** its title and chain coordinates in the same atomic log update:

```bash
# SURVIVOR_N, NEW_TITLE, NEW_POSITION, NEW_TOTAL come from the confirmed re-cut plan.
set_log "$MINE_DEF"'(.issues[] | select(same_repo and .number == ($n|tonumber)
  and .chain.chain_id == $chain)) |=
  (.title = $title | .chain.position = $position | .chain.total = $total) |
  if .active_chain.chain_id == $chain and .active_chain.repository == $repo
  then .active_chain.total = $total else . end' \
  --arg repo "$REPO" --arg n "$SURVIVOR_N" --arg chain "$CHAIN_ID" \
  --arg title "$NEW_TITLE" --argjson position "$NEW_POSITION" --argjson total "$NEW_TOTAL" || {
  echo "ERROR: remote edit is confirmed but re-cut bookkeeping failed; keep the checkpoint and retry reconciliation" >&2
  exit 1
}
```

Recompute the plan from the log and confirmed remote titles/dependencies after a restart; do not renumber already completed survivors twice. Keep the re-cut checkpoint until every surviving row and issue agrees. A whole-chain retract closes/logs each member independently; on partial failure retain the unclosed members and resume those only. Refresh/withdraw the common offer once after all intended closes succeed, or report the partial result without implying the remainder was cancelled.

### Offer cleanup after confirmed close(s)

**Now deal with the pending inline offer (if any).** Use the pre-close acceptance/token snapshot and count remaining open session-filed issues sharing it:

```bash
# OFFER_ACCEPTED and OFFER_TOKEN are the saved pre-close snapshot.
SHARERS=$(jq -r --arg n "$N" --arg t "$OFFER_TOKEN" --arg repo "$REPO" \
  "$MINE_DEF"'[.issues[] | mine | select(.chip_task_id == $t and .number != ($n|tonumber))] | length' "$LOG")
```

- **Offer already accepted** — execution is in flight; clear only confirmed-closed filed rows, never release a possibly running task's registry entry.
- **No token and no receipt** — no offer cleanup needed.
- **Sharers remain** — refresh only an inline offer. For reserved/unknown/spawned chips, do not re-emit or alter the launched payload: report the close and reconcile the saved handoff. A registry reservation covers the original batch; never infer task termination from issue closure.
- **Last covered issue** — a plain inline token can be withdrawn. A confirmed **unstarted** reservation may be released, followed by atomic local cleanup. A possible/confirmed spawn keeps the receipt and capacity until actual tool lifecycle evidence proves terminal; closing the issue does not dismiss the task. Use the production block below after GitHub confirms all intended closes. For whole-chain cleanup set `CLOSED_NUMBERS_JSON` to the verified closed member list; ordinary retract uses `[N]`.

```bash
# OFFER_TOKEN is the pre-close snapshot. Never sweep unrelated closed rows.
if jq -e '.inline_checkpoint != null' "$LOG" >/dev/null; then
  echo "HOLD: inline execution may be running; close confirmed, retain invocation receipt" >&2
  exit 1
fi
CLOSED_NUMBERS_JSON=${CLOSED_NUMBERS_JSON:-[$N]}
# Reconstruct operation inputs in a new shell; no prior variable is a receipt.
OFFER_TOKEN=$(jq -er --arg repo "$REPO" --argjson closed "$CLOSED_NUMBERS_JSON" "$MINE_DEF"'
 [.issues[] | select(same_repo and session_filed and .status == "closed" and (.number as $n | $closed | index($n))) | .chip_task_id // ""] | unique |
 if length>1 then error("different offer tokens require separate cleanup") else .[0] // "" end' "$LOG") || exit 1
SHARERS=$(jq -er --arg repo "$REPO" --arg t "$OFFER_TOKEN" "$MINE_DEF"'[.issues[] | mine | select(.chip_task_id == $t)] | length' "$LOG") || exit 1
DELIVERY_MODE=$(jq -r '.delivery_mode // "inline"' "$LOG") || exit 1
REG_TID=$(jq -r '.reg_tid // empty' "$LOG") || exit 1
SPAWN_STATUS=$(jq -r '.handoff_checkpoint.spawn_status // "unknown"' "$LOG") || exit 1
RECEIPT_REPO=$(jq -r '.handoff_checkpoint.repository // .target_repo // empty' "$LOG") || exit 1
[[ "$RECEIPT_REPO" == "$REPO" ]] || { echo "ERROR: handoff repository mismatch; preserve receipt" >&2; exit 1; }
CLEAR_REGISTRY=false
if [ "$SHARERS" -eq 0 ] && [ -n "$REG_TID" ]; then
  if ! jq -e '.handoff_checkpoint.spawn_status == "not-started" and .handoff_checkpoint.task_id == null and (.handoff_checkpoint.state == "reservation-intent" or .handoff_checkpoint.state == "reserved" or .handoff_checkpoint.state == "cleanup-pending")' "$LOG" >/dev/null; then
    echo "HOLD: task may be running; issue closed, but reservation/launch receipt retained" >&2
    exit 1
  fi
  # Resolve REGISTRY via the standard three executable paths; fail closed if absent.
  REGISTRY=""
  for candidate in "$HOME/.claude/skills-worktree/.claude/scripts/chip-offer-registry.sh" "$HOME/.claude/scripts/chip-offer-registry.sh" ".claude/scripts/chip-offer-registry.sh"; do
    [ -x "$candidate" ] && { REGISTRY="$candidate"; break; }
  done
  [ -n "$REGISTRY" ] || { echo "ERROR: registry unavailable; preserve cleanup receipt" >&2; exit 1; }
  SNAPSHOT=$("$REGISTRY" --repo "$REPO" --list) || exit 1
  REG_STATE=$(printf '%s' "$SNAPSHOT" | jq -er --arg id "$REG_TID" '
    if type != "array" then error("registry array required") else
    [.[] | select(.task_id == $id)] as $m |
    if ($m|length)==0 then "absent" elif ($m|length)==1 and $m[0].emitter=="issue-maker" then $m[0].state else error("ambiguous ID") end end') || exit 1
  case "$REG_STATE" in
    offered) "$REGISTRY" --repo "$REPO" --retract --task-id "$REG_TID" || { echo "ERROR: release uncertain; receipt retained" >&2; exit 1; } ;;
    absent|retracted|expired) : ;;
    *) echo "HOLD: registry task is $REG_STATE; reconcile actual task lifecycle" >&2; exit 1 ;;
  esac
  # Only confirmed release/absence AND no-spawn permits clearing the receipt.
  CLEAR_REGISTRY=true
elif [ "$DELIVERY_MODE" = chip ] || [ "$DELIVERY_MODE" = chip-pending ]; then
  echo "HOLD: preserve possibly running handoff, including uncounted launch receipts" >&2
  exit 1
fi
set_log "$MINE_DEF"'(.issues[] | select(same_repo and session_filed and .status == "closed" and (.number as $n | $closed | index($n)) and .chip_task_id == $tok) | .chip_task_id) = null | if $clear then .reg_tid = null | .delivery_mode = "inline" | .handoff_checkpoint = null else . end' --argjson clear "$CLEAR_REGISTRY" --arg repo "$REPO" --arg tok "$OFFER_TOKEN" --argjson closed "$CLOSED_NUMBERS_JSON" || exit 1
```

**Cleanup failure:** retain the affected tokens and registry/launch receipt when an external or local operation fails. A successful release followed by failed local cleanup is recoverable by the exact repo-scoped registry read; never reserve a replacement before reconciliation. Report withdrawal only after both stores confirm it. For possible/confirmed tasks say the issue was closed while task reconciliation remains pending, not that the chip was withdrawn.

Clearing `chip_task_id` to `null` in `$LOG` is the shared-record cleanup — `/wave` and `/pm` read this same log, so nulled entries stop counting as offered work for them too. In chip mode, the registry entry (`reg_tid`) is a second store — clear it as described above.


Then print: *"Issue #N closed."* — append *"(chip withdrawal failed — it may still be clickable)"* only in the genuine-failure case above. Issue link as the closing line either way.

---
