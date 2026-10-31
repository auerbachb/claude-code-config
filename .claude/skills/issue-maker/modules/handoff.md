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

Persist a unique attempt claim **before** any external reservation, including for the degraded uncounted path. The locked session writer rejects an existing receipt atomically. Do not retry `--reserve` with the same ID: the helper appends duplicates rather than providing idempotency. After an uncertain response, read the exact ID from `--list` in the same repository; unknown state stops.

Only for this explicitly requested handoff, render the complete prompt as `HANDOFF_PAYLOAD` from a session issue snapshot and supply that snapshot's JSON number array as `HANDOFF_ISSUES_JSON`. Freeze the exact bytes in a private file before claiming/reserving. The locked claim rejects a changed issue list and records the file pointer, SHA-256, and issue IDs in `.handoff_replays[attempt_id]`. Keep that replay receipt through live-offer cleanup. This verifies local saved bytes; this harness cannot attest the actual provider's spawn arguments.

Pass `HANDOFF_ATTEMPT_ID` from the emitted receipt into each later shell invocation. After compaction, recover it from the saved checkpoint for this requested operation; never mint another ID or restart the reservation phase. An absent registry row cannot clear an in-flight reservation intent: only a returned reservation call or an observed committed row proves that boundary complete. Every subsequent write compares the entire expected checkpoint and registry ID under the session-log lock. A different or stale attempt cannot overwrite the receipt. These guards serialize local transitions; they do not prove user acceptance or tool success.

```bash
# Run this definitions fence together with EACH later handoff phase block;
# shell functions and variables do not survive separate tool invocations.
handoff_restore() {
  [ -n "${HANDOFF_ATTEMPT_ID:-}" ] || { echo "HOLD: supply the saved handoff attempt ID" >&2; return 1; }
  HANDOFF_SNAPSHOT=$(jq -ec --arg repo "$REPO" --arg attempt "$HANDOFF_ATTEMPT_ID" '
    if .target_repo == $repo and .handoff_checkpoint.repository == $repo
       and .handoff_checkpoint.attempt_id == $attempt
       and ((.reg_tid // "") == "" or .reg_tid == $attempt) then
      {reg_tid:(.reg_tid // ""),checkpoint:.handoff_checkpoint}
    else error("handoff attempt/repository mismatch") end' "$LOG") || return 1
  REG_TID=$(printf '%s' "$HANDOFF_SNAPSHOT" | jq -r '.reg_tid') || return 1
  EXPECTED_HANDOFF=$(printf '%s' "$HANDOFF_SNAPSHOT" | jq -c '.checkpoint') || return 1
  OFFER_TOKEN=$(printf '%s' "$EXPECTED_HANDOFF" | jq -r '.offer_token // empty') || return 1
  REGISTRY=""
  if [ -n "$REG_TID" ]; then
    for candidate in "$HOME/.claude/skills-worktree/.claude/scripts/chip-offer-registry.sh" "$HOME/.claude/scripts/chip-offer-registry.sh" ".claude/scripts/chip-offer-registry.sh"; do
      [ -x "$candidate" ] && { REGISTRY="$candidate"; break; }
    done
    [ -n "$REGISTRY" ] || return 1
  fi
}
handoff_read_payload() {
: "${HANDOFF_ATTEMPT_ID:?select the saved attempt to replay}"
REPLAY_RECEIPT=$(jq -ec --arg attempt "$HANDOFF_ATTEMPT_ID" --arg repo "$REPO" '
  .handoff_replays[$attempt] | select(.attempt_id == $attempt and .repository == $repo)' "$LOG") || exit 1
printf '%s' "$REPLAY_RECEIPT" | python3 -c '
import hashlib, json, os, stat, sys
receipt = json.load(sys.stdin)
path = receipt["path"]
if os.path.islink(path) or not stat.S_ISREG(os.stat(path).st_mode) or stat.S_IMODE(os.stat(path).st_mode) & 0o077:
    raise SystemExit("HOLD: saved handoff payload is not a private regular file")
with open(path, "rb") as saved:
    data = saved.read()
if hashlib.sha256(data).hexdigest() != receipt["sha256"]:
    raise SystemExit("HOLD: saved handoff payload hash mismatch; do not regenerate")
sys.stdout.buffer.write(data)
' || exit 1
}
handoff_write() {
  local change="$1"; shift
  set_log "$MINE_DEF"'if .target_repo != $repo or (.reg_tid // "") != $reg
      or .handoff_checkpoint != $expected then error("stale handoff receipt") else . end | '"$change" --arg repo "$REPO" --arg reg "$REG_TID" --argjson expected "$EXPECTED_HANDOFF" "$@"
}
# Legal ONLY before spawn or after an explicit result proving no task exists.
# Claim cleanup under the log lock BEFORE retracting, so launch cannot race it.
handoff_release_unstarted() {
  local clear_token="${1:-}"
  handoff_restore || return 1
  printf '%s' "$EXPECTED_HANDOFF" | jq -e '
    .spawn_status == "not-started" and .task_id == null and
    (.state == "reservation-intent" or .state == "reserved" or .state == "cleanup-pending")' >/dev/null || {
    echo "HOLD: receipt does not prove an unstarted handoff; do not release" >&2; return 1;
  }
  handoff_write '.handoff_checkpoint.state = "cleanup-pending"' || return 1
  handoff_restore || return 1
  if [ -n "$REG_TID" ]; then
    SNAPSHOT=$("$REGISTRY" --repo "$REPO" --list 2>/dev/null) || return 1
    if ! printf '%s' "$SNAPSHOT" | jq -e --arg id "$REG_TID" '
      type == "array" and ([.[] | select(.task_id == $id)] as $m |
      ($m|length)==0 or (($m|length)==1 and $m[0].emitter=="issue-maker" and ($m[0].state=="offered" or $m[0].state=="retracted" or $m[0].state=="expired")))' >/dev/null; then
      echo "HOLD: registry identity/state may represent running work; preserve receipt" >&2
      return 1
    fi
    if ! printf '%s' "$SNAPSHOT" | jq -e --arg id "$REG_TID" 'any(.[]; .task_id == $id)' >/dev/null \
       && ! printf '%s' "$EXPECTED_HANDOFF" | jq -e '.reservation_complete == true' >/dev/null; then
      echo "HOLD: reservation call may still be in flight; absence alone cannot clear its intent" >&2
      return 1
    fi
    if ! "$REGISTRY" --repo "$REPO" --retract --task-id "$REG_TID" >/dev/null 2>&1; then
      # The cleanup claim retains attempt, registry ID, covered issues and token.
      echo "ERROR: reservation cleanup uncertain; keep receipt and retry cleanup only" >&2
      return 1
    fi
  fi
  handoff_write '.reg_tid = null | .delivery_mode = "inline" | .handoff_checkpoint = null |
    if $clear == "" then . else
      (.issues[] | select(same_repo and session_filed and .chip_task_id == $clear) | .chip_task_id) = null end' --arg clear "$clear_token" || {
    echo "ERROR: reservation released but session cleanup could not be persisted; reconcile before another offer" >&2
    return 1
  }
  REG_TID=""
}
```

```bash
REGISTRY=""; CAP_SH=""; CAP_ADMISSION=""; REG_TID=""; REG_TID_RC=0
if [ "$CHIP_TOOL_AVAILABLE" = true ]; then
  for candidate in "$HOME/.claude/skills-worktree/.claude/scripts/active-work-cap.sh" "$HOME/.claude/scripts/active-work-cap.sh" ".claude/scripts/active-work-cap.sh"; do
    [ -x "$candidate" ] && { CAP_SH="$candidate"; break; }
  done
  for candidate in "$HOME/.claude/skills-worktree/.claude/scripts/chip-offer-registry.sh" "$HOME/.claude/scripts/chip-offer-registry.sh" ".claude/scripts/chip-offer-registry.sh"; do
    [ -x "$candidate" ] && { REGISTRY="$candidate"; break; }
  done
  if [ -z "$CAP_SH" ]; then
    echo "DEGRADED: active-work-cap.sh not found — continuing uncounted" >&2
  else
    CAP_JSON_RC=0
    CAP_JSON=$("$CAP_SH" --json --repo "$REPO" 2>/dev/null) || CAP_JSON_RC=$?
    FREE_RC=0; FREE=$(printf '%s' "$CAP_JSON" | jq -r '.free // empty' 2>/dev/null) || FREE_RC=$?
    BASELINE_RC=0; REG_BASELINE=$(printf '%s' "$CAP_JSON" | jq -r '.registry_baseline // empty' 2>/dev/null) || BASELINE_RC=$?
    if [ "$CAP_JSON_RC" -ne 0 ] || [ "$FREE_RC" -ne 0 ] || [ "$BASELINE_RC" -ne 0 ] \
       || ! [[ "$FREE" =~ ^[0-9]+$ ]] || ! [[ "$REG_BASELINE" =~ ^[0-9]+$ ]]; then
      echo "DEFERRED: resolved active-work cap is unreadable; no reservation, stamp, or spawn attempted" >&2
      exit 1
    elif [ "$FREE" -eq 0 ]; then
      echo "DEFERRED: repo-wide active-work cap is full; no offer was stamped or emitted" >&2
      exit 7
    elif [ -z "$REGISTRY" ]; then
      echo "DEGRADED: chip-offer-registry.sh not found — continuing uncounted" >&2
    else
      CAP_ADMISSION=$((REG_BASELINE + FREE))
    fi
  fi
fi
# Payload preparation/save must succeed before any external reservation/spawn.
: "${HANDOFF_PAYLOAD:?render the complete explicitly requested handoff prompt}"
: "${HANDOFF_ISSUES_JSON:?supply the issue snapshot used to render that prompt}"
printf '%s' "$HANDOFF_ISSUES_JSON" | jq -e 'type == "array" and length > 0 and all(.[]; type == "number")' >/dev/null || exit 1
HANDOFF_ATTEMPT_ID="handoff-$(date -u +%s)-$$-$RANDOM-$RANDOM"
PAYLOAD_RECEIPT=$(printf '%s' "$HANDOFF_PAYLOAD" | python3 -c '
import hashlib, json, os, sys, tempfile
log, attempt = sys.argv[1:]
data = sys.stdin.buffer.read()
fd, path = tempfile.mkstemp(prefix=os.path.basename(log)+".handoff-"+attempt+".", dir=os.path.dirname(os.path.abspath(log)))
try:
    with os.fdopen(fd, "wb") as out:
        out.write(data)
        out.flush()
        os.fsync(out.fileno())
    os.chmod(path, 0o400)
except BaseException:
    os.unlink(path)
    raise
print(json.dumps({"path":path,"sha256":hashlib.sha256(data).hexdigest()}))
' "$LOG" "$HANDOFF_ATTEMPT_ID") || { echo "ERROR: handoff payload save failed; no reservation or spawn attempted" >&2; exit 1; }
[ -z "$CAP_ADMISSION" ] || REG_TID="$HANDOFF_ATTEMPT_ID"
# This condition is evaluated by set-log inside its actual read/modify/write lock.
if ! set_log "$MINE_DEF"'if .target_repo != $repo or (.reg_tid // "") != "" or .handoff_checkpoint != null
    or .inline_checkpoint != null or .offer_accepted == true
    or (.delivery_mode == "chip" or .delivery_mode == "chip-pending" or .delivery_mode == "chip-reserved")
    then error("reconcile existing execution receipt before a fresh handoff") else
    [.issues[] | mine | .number] as $covered | if $covered != $rendered then error("handoff issue snapshot changed") else
    .handoff_replays = ((.handoff_replays // {}) + {($attempt):{attempt_id:$attempt,repository:$repo,
      path:$payload.path,sha256:$payload.sha256,issues:$covered}}) |
    .reg_tid = (if $reg == "" then null else $reg end) | .delivery_mode = "chip-reserved" |
    .handoff_checkpoint = {attempt_id:$attempt,state:"reservation-intent",spawn_status:"not-started",
      repository:$repo,task_id:null,offer_token:null,issues:$covered,reservation_complete:false} end end' \
    --arg reg "$REG_TID" --arg repo "$REPO" --arg attempt "$HANDOFF_ATTEMPT_ID" \
    --argjson rendered "$HANDOFF_ISSUES_JSON" --argjson payload "$PAYLOAD_RECEIPT"; then
  echo "ERROR: handoff claim failed; no reservation, stamp, or spawn attempted" >&2
  exit 1
fi
handoff_restore || exit 1
if [ -n "$REG_TID" ]; then
  ISSUE_ARGS=()
  while IFS= read -r issue_number; do
    ISSUE_ARGS+=(--issue "$issue_number")
  done < <(printf '%s' "$EXPECTED_HANDOFF" | jq -r '.issues[]')
  REG_RESPONSE=$("$REGISTRY" --repo "$REPO" --reserve --emitter issue-maker "${ISSUE_ARGS[@]}" \
    --cap-free "$CAP_ADMISSION" --task-id "$REG_TID" 2>/dev/null) || REG_TID_RC=$?
  if [ "$REG_TID_RC" -eq 7 ]; then
    handoff_write '.handoff_checkpoint.reservation_complete = true' || exit 1
    handoff_release_unstarted || exit 1
    echo "DEFERRED: active-work cap was consumed before handoff reservation; no offer was stamped or emitted" >&2
    exit 7
  fi
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
    handoff_write '.reg_tid = null | .handoff_checkpoint.reservation_complete = true' || exit 1
    handoff_restore || exit 1
    echo "DEGRADED: registry confirms no reservation — continuing uncounted" >&2
  elif [ "$REG_STATE" != offered ]; then
    echo "ERROR: reservation is $REG_STATE; reconcile without spawning" >&2; exit 1
  fi
fi
if ! handoff_write '.handoff_checkpoint.state = "reserved" | .handoff_checkpoint.reservation_complete = true'; then
  handoff_release_unstarted || exit 1
  echo "ERROR: reserved receipt failed; no chip was started" >&2; exit 1
fi
handoff_restore || exit 1
# Stamp only the issue snapshot covered by this reservation.
OFFER_TOKEN="offer-$(date -u +%s)-$$-$RANDOM-$RANDOM"
OFFER_MODE=inline
[ -z "$REG_TID" ] || OFFER_MODE=chip-reserved
if ! handoff_write '.handoff_checkpoint.issues as $covered | .delivery_mode = $mode |
    .handoff_checkpoint.offer_token = $tok |
    (.issues[] | mine | select(.number as $n | $covered | index($n)) | .chip_task_id) = $tok' \
    --arg mode "$OFFER_MODE" --arg tok "$OFFER_TOKEN"; then
  handoff_release_unstarted "$OFFER_TOKEN" || exit 1
  echo "ERROR: offer stamp could not be persisted; no spawn or emission occurred" >&2
  exit 1
fi
printf 'HANDOFF_ATTEMPT_ID=%s\n' "$HANDOFF_ATTEMPT_ID"
```

**Before the tool call**, persist this checked write. Only the invocation whose compare-and-swap succeeds may call the tool. A crash after it is an uncertain launch, even if the tool had not yet been invoked. Failure stops; cleanup is legal only if the saved receipt still proves no launch.

```bash
handoff_restore || exit 1
printf '%s' "$EXPECTED_HANDOFF" | jq -e '.state == "reserved" and .spawn_status == "not-started" and .task_id == null' >/dev/null || {
  echo "HOLD: launch intent already exists; reconcile, never spawn twice" >&2; exit 1;
}
if [ -n "$REG_TID" ]; then
  READY=$("$REGISTRY" --repo "$REPO" --list) || exit 1
  printf '%s' "$READY" | jq -e --arg id "$REG_TID" '[.[] | select(.task_id == $id and .emitter == "issue-maker" and .state == "offered")] | length == 1' >/dev/null || { echo "HOLD: reservation no longer offered; reconcile before launch" >&2; exit 1; }
fi
[ -n "$OFFER_TOKEN" ] || { echo "ERROR: offer receipt missing before launch" >&2; exit 1; }
handoff_read_payload >/dev/null || exit 1
if ! handoff_write '.delivery_mode = "chip-pending" | .handoff_checkpoint.state = "spawn-uncertain" | .handoff_checkpoint.spawn_status = "unknown"'; then
  handoff_release_unstarted "$OFFER_TOKEN" || exit 1
  echo "ERROR: launch intent failed; no spawn attempted" >&2
  exit 1
fi
# Supply these verified frozen bytes as the tool prompt in the next action.
handoff_read_payload || exit 1
```

**Chip mode:** call `mcp__ccd_session__spawn_task` **once** with verb-first title (≤60 chars), the verified frozen prompt bytes emitted by the pre-tool fence, plain tldr, and repo-root cwd. Classify the actual result: `spawned` only with returned `TASK_ID`; `not-started` only if the tool was absent or its explicit result guarantees no task was created; otherwise `unknown` (timeout, disconnect, lost response). Never classify generic tool failure as proof of non-creation. Retain `REG_TID` separately for lifecycle transitions using `chip-offer-registry.sh --repo "$REPO" --transition --task-id "$REG_TID" --state <running|pr-backed|done>`; closing a captured issue is not a terminal event for the task. A replay never launches again.

After confirmed success, persist the returned task ID against the saved attempt. If both writes fail, the prior `spawn-uncertain` receipt remains; report the returned ID for reconciliation without claiming it is recorded. Never release capacity or print an executable fallback after possible/confirmed spawn. Print the short summary per `chip-launching.md` only for confirmed success.

```bash
handoff_restore || exit 1
[ -n "$TASK_ID" ] || { echo "ERROR: no confirmed task ID; retain unknown spawn receipt" >&2; exit 1; }
printf '%s' "$EXPECTED_HANDOFF" | jq -e '.state == "spawn-uncertain" and .spawn_status == "unknown" and .task_id == null' >/dev/null || { echo "HOLD: stale spawn result; preserve saved receipt" >&2; exit 1; }
if ! handoff_write '.delivery_mode = "chip" | .reg_tid = (if $reg == "" then null else $reg end) |
    .handoff_checkpoint.state = "spawned" | .handoff_checkpoint.spawn_status = "spawned" | .handoff_checkpoint.task_id = $task |
    .handoff_checkpoint.issues as $covered |
    (.issues[] | select(same_repo and session_filed and (.number as $n | $covered | index($n))) | .chip_task_id) = $task' --arg task "$TASK_ID"; then
  handoff_write '.handoff_checkpoint.state = "spawned-receipt-pending" | .handoff_checkpoint.spawn_status = "spawned" | .handoff_checkpoint.task_id = $task' --arg task "$TASK_ID" || true
  echo "ERROR: chip started as $TASK_ID but its receipt needs reconciliation; preserve reg_tid" >&2
  exit 1
fi
```

**Fallback mode:** only when no task was created, set `SPAWN_OUTCOME=not-started` from the actual result (or tool absence), then run this cleanup before printing the full fenced prompt once. Keep the stamped issue token for the printed block. Unknown/possibly running tasks stop without releasing, re-spawning, or printing another executable handoff. The release function above must be loaded from this same handoff phase after recovery; it is not a reason to load unrelated modules.

```bash
handoff_restore || exit 1
printf '%s' "$EXPECTED_HANDOFF" | jq -e '.task_id == null and (.state == "reserved" or .state == "spawn-uncertain") and .spawn_status != "spawned"' >/dev/null || { echo "HOLD: confirmed/stale task receipt cannot become a fallback" >&2; exit 1; }
if [ "$SPAWN_OUTCOME" != not-started ]; then
  echo "ERROR: spawn outcome uncertain; preserve receipt and reservation, reconcile the tool result" >&2
  exit 1
fi
handoff_read_payload >/dev/null || exit 1
if ! handoff_write '.handoff_checkpoint.state = "cleanup-pending" | .handoff_checkpoint.spawn_status = "not-started"'; then
  echo "ERROR: no task was created but cleanup intent could not be persisted; reconcile before fallback" >&2
  exit 1
fi
handoff_release_unstarted || exit 1
handoff_read_payload || exit 1
```

If the user asks to "print the full prompt for #N", select the saved attempt covering that issue and run only this replay fence. It reads and verifies the frozen bytes; a missing/tampered/private-file failure stops. Never regenerate from mutable issue bodies or the current template, reserve again, or infer a successful launch from an offer token. A replay is explicit output only and grants no new execution authority.

```bash
# Load the definitions fence above; this needs no live reservation checkpoint.
handoff_read_payload || exit 1
```
