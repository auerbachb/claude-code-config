# On-request chip or handoff block

> Load only for: explicit request for a chip, handoff block, or replay of a prior handoff
> Prerequisites: session state loaded; session-filed issue list exists; explicit request recorded

Use only `mine` rows for the issue list and maximum tier. For first emission, resolve/read `create:postfile` only if its shared Step 9b tier and Step 9c active-work cap procedure are not already in context; perform the same cap check before reserving or spawning. Replays use the saved emitted payload and do not re-infer or re-launch. Do not file issues in this operation.

**On-request hand-off (chip or fallback block).** When the user explicitly requests a chip or printed block — `"give me the chip"`, `"print the hand-off"`, `"I want to run this in a new thread"` — emit the block below. This is no longer the default session ending; it is an on-request fallback. Its content is unchanged and required verbatim for lint compliance.

**Model + effort contract (non-negotiable for the on-request block):** The block `prompt` MUST open with the `**Model:**` line from Step 9b, then that step's `**Effort:**` line, then the model-guard preamble from `chip-launching.md` — no blank line between the three. Both values are the session's *most demanding* tier (Step 9b). The visible short summary MUST repeat both lines per `chip-launching.md` "Short-summary transcript format". When the parent thread is on Fable and the block recommends a different model, add the pre-click warning from `chip-launching.md` "Upstream requirement."

```
**Model:** {MODEL from Step 9b} — {one-line reason, e.g. "rules + skill wiring across the batch"}
**Effort:** {LEVEL from Step 9b} — {one-line reason, e.g. "hardest issue in the batch is rules-touching"}
{Model-guard preamble — insert verbatim from `chip-launching.md` "Model-guard preamble", immediately after these lines, no blank line between}

You are picking up {N} freshly captured issue(s) from an `/issue-maker` capture thread — no CR plans, worktrees, or codebase exploration have happened yet.

## Task
Work through these issues, in this order:

1. #{a} — {title}
   {url}
2. #{b} — {title}
   {url}
{…one entry per open issue filed in this session, in filing order}

{Increment chains only: "#{b}–#{d} are increments 2–4 of one chain behind #{a}; they land in that order."}

## Workflow
Run `/subagent #{a} #{b} …` in this thread. It claims each issue, serializes any that overlap on a file, and drives each one A→B→C to a merged PR — keeping at most the concurrent-pipeline ceiling (`PIPELINE_CEILING`, default 4) in flight and queueing the rest. Any issue it judges too big for a subagent it routes to its own thread, naming the criterion; that judgment belongs here, with the code in front of you, not back in the capture thread.

If this thread has no `## Active Work` table, bootstrap one (`/pm` Step 3.2's schema) and track the issues there. Do not open a separate thread per issue.

## Constraints
- Claim the issue before anything else. Resolve `issue-claim.sh` to the first executable of `$HOME/.claude/skills-worktree/.claude/scripts/issue-claim.sh`, `$HOME/.claude/scripts/issue-claim.sh`, `.claude/scripts/issue-claim.sh` — this repo may carry no `.claude/` directory. Run `<N> --check` on it, and if it clears, `<N> --claim`. Do this after the model-guard check and before any repo read, edit, or planning. Exit 1 (`claimed`) or 4 (`unknown`) → stop and report the claim rather than proceeding; `stale` → say so and continue. If `--claim` itself fails, stop — a passing check is not a held claim. If no candidate resolves, print `DEGRADED: issue-claim.sh not found (checked all three paths) — proceeding unclaimed` and continue; never skip the claim silently.
  - The bullet above applies to **each** issue in the list, one at a time as you pick it up — `/subagent` Step 6.0 performs exactly that per issue, so running the workflow discharges it.
- Do NOT work on main — each pipeline works in its own worktree
- Do NOT modify .env files
- Merging is automatic and yours to do: once the merge gate passes and every Test Plan / AC checkbox verifies, run the full `/wrap` yourself to squash-merge — no approval pause, no pre-merge message (`CLAUDE.md` "PR MERGE AUTHORIZATION")
```

The merge-authority bullet is the shared contract from `chip-launching.md` "Merge-authority line" — reproduce it **verbatim**, never softened into an approval request. The claim bullet is **Form A** of that file's "Claim line" — `/issue-maker` holds no claim, so the launched thread takes each one. Both are written out here as literal text rather than cited, for the same reason that file gives: a generated hand-off may land in a repo where `chip-launching.md` does not resolve, and a rule that lives only in prose never reaches the prompt. The only local addition is the **nested sub-bullet** scoping the claim to each issue in the list — kept off the canonical line on purpose, because `skill-portability-lint.sh` compares that whole line byte-for-byte and an appended clause fails it.

**Reservation and launch receipts.** Replays use the saved payload and never reserve or launch again. A fresh handoff must have no outstanding registry/launch receipt. Registry `--reserve` creates an `offered` entry; that is capacity accounting, not proof that `spawn_task` happened. Every registry call, including reads and cleanup, uses the exact target `--repo "$REPO"`. Resolve the helpers and cap as below. Exit 7 defers without emitting or stamping an offer. Missing helpers/read failures before reservation retain the documented degraded uncounted path.

Persist a unique caller-generated registry ID **before** the external reservation. Do not retry `--reserve` with that ID: the helper appends duplicates rather than providing idempotency. After an uncertain response, read the exact ID from `--list` in the same repository; unknown state stops. All local writes use the atomic session writer. These receipts distinguish `reservation-intent`, `reserved`, `spawn-uncertain`, `spawned-receipt-pending`, and `cleanup-pending`; only confirmed tool success establishes a task ID. Keep the checkpoint repository and registry ID until confirmed cleanup or terminal reconciliation.

```bash
# The release function is legal ONLY before spawn or after an explicit result
# proving no task was created. Never call it for a timeout/lost spawn response.
handoff_release_unstarted() {
  # Validate the persisted phase/owner even when called after a restart.
  if ! jq -e --arg repo "$REPO" --arg reg "$REG_TID" '
    ((.reg_tid // "") == $reg) and
    ((.handoff_checkpoint.repository // .target_repo) == $repo) and
    (if .handoff_checkpoint == null then ((.delivery_mode // "inline") == "inline")
     else (.handoff_checkpoint.spawn_status == "not-started" and .handoff_checkpoint.task_id == null and (.handoff_checkpoint.state == "reservation-intent" or .handoff_checkpoint.state == "reserved" or .handoff_checkpoint.state == "cleanup-pending")) end)' "$LOG" >/dev/null; then
    echo "HOLD: receipt does not prove an unstarted handoff in this repository; do not release" >&2
    return 1
  fi
  if [ -n "$REG_TID" ]; then
    SNAPSHOT=$("$REGISTRY" --repo "$REPO" --list 2>/dev/null) || return 1
    if ! printf '%s' "$SNAPSHOT" | jq -e --arg id "$REG_TID" '
      type == "array" and ([.[] | select(.task_id == $id)] as $m |
      ($m|length)==0 or (($m|length)==1 and $m[0].emitter=="issue-maker" and ($m[0].state=="offered" or $m[0].state=="retracted" or $m[0].state=="expired")))' >/dev/null; then
      echo "HOLD: registry identity/state may represent running work; preserve receipt" >&2
      return 1
    fi
    if ! "$REGISTRY" --repo "$REPO" --retract --task-id "$REG_TID" >/dev/null 2>&1; then
      set_log '.handoff_checkpoint = {state:"cleanup-pending", spawn_status:"not-started", repository:$repo, task_id:null}' --arg repo "$REPO" || true
      echo "ERROR: reservation cleanup uncertain; keep reg_tid and retry cleanup only" >&2
      return 1
    fi
  fi
  set_log '.reg_tid = null | .delivery_mode = "inline" | .handoff_checkpoint = null' || {
    echo "ERROR: reservation released but session cleanup could not be persisted; reconcile before another offer" >&2
    return 1
  }
  REG_TID=""
}
```

```bash
if jq -e '(.reg_tid // "") != "" or .handoff_checkpoint != null or .delivery_mode == "chip" or .delivery_mode == "chip-pending" or .delivery_mode == "chip-reserved" or .offer_accepted == true' "$LOG" >/dev/null; then
  echo "ERROR: reconcile the saved handoff receipt before reserving or spawning again" >&2
  exit 1
fi
REGISTRY=""
CAP_SH=""; CAP_ADMISSION=""
REG_TID=""; REG_TID_RC=0
if [ "$CHIP_TOOL_AVAILABLE" = true ]; then
  for candidate in     "$HOME/.claude/skills-worktree/.claude/scripts/active-work-cap.sh"     "$HOME/.claude/scripts/active-work-cap.sh"     ".claude/scripts/active-work-cap.sh"; do
    [ -x "$candidate" ] && { CAP_SH="$candidate"; break; }
  done
  for candidate in     "$HOME/.claude/skills-worktree/.claude/scripts/chip-offer-registry.sh"     "$HOME/.claude/scripts/chip-offer-registry.sh"     ".claude/scripts/chip-offer-registry.sh"; do
    [ -x "$candidate" ] && { REGISTRY="$candidate"; break; }
  done
fi
if [ "$CHIP_TOOL_AVAILABLE" = true ]; then
  if [ -z "$CAP_SH" ]; then
    echo "DEGRADED: active-work-cap.sh not found — continuing uncounted" >&2
  else
    CAP_JSON_RC=0
    CAP_JSON=$("$CAP_SH" --json --repo "$REPO" 2>/dev/null) || CAP_JSON_RC=$?
    FREE_RC=0; FREE=$(printf '%s' "$CAP_JSON" | jq -r '.free // empty' 2>/dev/null) || FREE_RC=$?
    BASELINE_RC=0; REG_BASELINE=$(printf '%s' "$CAP_JSON" | jq -r '.registry_baseline // empty' 2>/dev/null) || BASELINE_RC=$?
    if [ "$CAP_JSON_RC" -ne 0 ] || [ "$FREE_RC" -ne 0 ] || [ "$BASELINE_RC" -ne 0 ]        || ! [[ "$FREE" =~ ^[0-9]+$ ]] || ! [[ "$REG_BASELINE" =~ ^[0-9]+$ ]]; then
      echo "DEFERRED: resolved active-work cap is unreadable; no reservation, stamp, or spawn attempted" >&2
      exit 1
    elif [ "$FREE" -eq 0 ]; then
      echo "DEFERRED: repo-wide active-work cap is full; no offer was stamped or emitted" >&2
      exit 7
    elif [ -z "$REGISTRY" ]; then
      echo "DEGRADED: chip-offer-registry.sh not found — continuing uncounted" >&2
    else
      CAP_ADMISSION=$((REG_BASELINE + FREE))
      ISSUE_NUMBERS=$(jq -r --arg repo "$REPO" "$MINE_DEF"'.issues[] | mine | .number' "$LOG") || exit 1
      [ -n "$ISSUE_NUMBERS" ] || { echo "ERROR: no open session issues to hand off" >&2; exit 1; }
      ISSUE_ARGS=()
      while IFS= read -r issue_number; do
        [ -n "$issue_number" ] && ISSUE_ARGS+=(--issue "$issue_number")
      done <<< "$ISSUE_NUMBERS"
      REG_TID="offer-$(date -u +%s)-$$-$RANDOM-$RANDOM"
      if ! set_log '.reg_tid = $reg | .delivery_mode = "chip-reserved" | .handoff_checkpoint = {state:"reservation-intent", spawn_status:"not-started", repository:$repo, task_id:null}' --arg reg "$REG_TID" --arg repo "$REPO"; then
        echo "ERROR: reservation intent could not be persisted; no reservation or spawn attempted" >&2
        exit 1
      fi
      REG_RESPONSE=$("$REGISTRY" --repo "$REPO" --reserve --emitter issue-maker "${ISSUE_ARGS[@]}"         --cap-free "$CAP_ADMISSION" --task-id "$REG_TID" 2>/dev/null) || REG_TID_RC=$?
      if [ "$REG_TID_RC" -eq 7 ]; then
        handoff_release_unstarted || exit 1
        echo "DEFERRED: active-work cap was consumed before handoff reservation; no offer was stamped or emitted" >&2
        exit 7
      fi
      # A failed response can follow a committed write; inspect, never re-reserve.
      REG_SNAPSHOT=$("$REGISTRY" --repo "$REPO" --list 2>/dev/null) || {
        echo "ERROR: reservation result unknown; retain reservation-intent receipt and do not spawn" >&2; exit 1;
      }
      REG_STATE=$(printf '%s' "$REG_SNAPSHOT" | jq -er --arg id "$REG_TID" '
        if type != "array" then error("registry array required") else
        [.[] | select(.task_id == $id)] as $matches |
        if ($matches|length)==0 then "absent"
        elif ($matches|length)==1 and $matches[0].emitter=="issue-maker" then $matches[0].state
        else error("ambiguous reservation identity") end end') || exit 1
      if [ "$REG_STATE" = absent ]; then
        handoff_release_unstarted || exit 1
        echo "DEGRADED: registry confirms no reservation — continuing uncounted" >&2
      elif [ "$REG_STATE" != offered ]; then
        echo "ERROR: reservation is $REG_STATE; reconcile without spawning" >&2; exit 1
      elif ! set_log '.handoff_checkpoint.state = "reserved"'; then
        handoff_release_unstarted || exit 1
        echo "ERROR: reserved receipt failed; no chip was started" >&2; exit 1
      fi
    fi
  fi
fi

# Stamp before first emission; chip-reserved does not imply a task was started.
OFFER_TOKEN="offer-$(date -u +%s)-$$-$RANDOM-$RANDOM"
OFFER_MODE=inline
[ -n "$REG_TID" ] && OFFER_MODE=chip-reserved
if ! set_log "$MINE_DEF"'.delivery_mode = $mode | (.issues[] | mine | .chip_task_id) = $tok'     --arg mode "$OFFER_MODE" --arg tok "$OFFER_TOKEN" --arg repo "$REPO"; then
  handoff_release_unstarted || exit 1
  echo "ERROR: offer stamp could not be persisted; no spawn or emission occurred" >&2
  exit 1
fi
```

**Before the tool call**, persist this checked write. A crash after it is an uncertain launch, even if the tool had not yet been invoked; that conservative uncertainty prevents duplicate work. Failure stops before calling the tool.

```bash
if ! set_log '.delivery_mode = "chip-pending" | .handoff_checkpoint = {state:"spawn-uncertain", spawn_status:"unknown", repository:$repo, task_id:null}' --arg repo "$REPO"; then
  handoff_release_unstarted || exit 1
  echo "ERROR: launch intent failed; no spawn attempted" >&2
  exit 1
fi
```

**Chip mode:** call `mcp__ccd_session__spawn_task` **once** with verb-first title (≤60 chars), the prompt above verbatim, plain tldr, and repo-root cwd. Classify the actual result: `spawned` only with returned `TASK_ID`; `not-started` only if the tool was absent or its explicit result guarantees no task was created; otherwise `unknown` (timeout, disconnect, lost response). Never classify generic tool failure as proof of non-creation. Retain `REG_TID` separately for lifecycle transitions using `chip-offer-registry.sh --repo "$REPO" --transition --task-id "$REG_TID" --state <running|pr-backed|done>`; closing a captured issue is not a terminal event for the task. A replay never launches again.

After confirmed success, persist the returned task ID. If both writes fail, the prior `spawn-uncertain` receipt remains; report the returned ID for reconciliation without claiming it is recorded. Never release capacity or print an executable fallback after possible/confirmed spawn. Print the short summary per `chip-launching.md` only for confirmed success.

```bash
[ -n "$TASK_ID" ] || { echo "ERROR: no confirmed task ID; retain unknown spawn receipt" >&2; exit 1; }
if ! set_log "$MINE_DEF"'.delivery_mode = "chip" | .reg_tid = $reg | .handoff_checkpoint = {state:"spawned", spawn_status:"spawned", repository:$repo, task_id:$task} | (.issues[] | mine | .chip_task_id) = $task'     --arg reg "$REG_TID" --arg task "$TASK_ID" --arg repo "$REPO"; then
  set_log '.handoff_checkpoint = {state:"spawned-receipt-pending", spawn_status:"spawned", repository:$repo, task_id:$task}' --arg task "$TASK_ID" --arg repo "$REPO" || true
  echo "ERROR: chip started as $TASK_ID but its receipt needs reconciliation; preserve reg_tid" >&2
  exit 1
fi
```

**Fallback mode:** only when no task was created, set `SPAWN_OUTCOME=not-started` from the actual result (or tool absence), then run this cleanup before printing the full fenced prompt once. Keep the stamped issue token for the printed block. Unknown/possibly running tasks stop without releasing, re-spawning, or printing another executable handoff. The release function above must be loaded from this same handoff phase after recovery; it is not a reason to load unrelated modules.

```bash
if [ "$SPAWN_OUTCOME" != not-started ]; then
  echo "ERROR: spawn outcome uncertain; preserve receipt and reservation, reconcile the tool result" >&2
  exit 1
fi
if ! set_log '.handoff_checkpoint = {state:"cleanup-pending", spawn_status:"not-started", repository:$repo, task_id:null}' --arg repo "$REPO"; then
  echo "ERROR: no task was created but cleanup intent could not be persisted; reconcile before fallback" >&2
  exit 1
fi
handoff_release_unstarted || exit 1
```

If the user asks to "print the full prompt for #N", re-emit the saved prompt verbatim (Model line + guard preamble included) as a replay; never re-reserve or infer a successful launch from an offer token.
