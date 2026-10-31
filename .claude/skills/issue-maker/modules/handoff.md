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

**Reserve before stamping or emitting.** A declined/deferred inline offer may have left no token, so never assume one exists. Before this block, set `CHIP_TOOL_AVAILABLE` from tool discovery and build `ISSUE_ARGS` as one `--issue N` pair for every open issue covered by the hand-off. For a new request with the chip tool available, perform the cap admission and registry reservation first. Exit 7 means the cap was consumed concurrently: defer without stamping or emitting anything, so `/wave` does not hide an offer that was never sent. Any other registry error follows the documented degraded, uncounted path. A successful reservation ID must be persisted before `spawn_task`; if that write fails, do not spawn. If the chip tool is absent, skip reservation and proceed to the printed-block fallback. Do not run these steps for a replay of an already emitted payload.

```bash
REGISTRY=""
CAP_SH=""; CAP_ADMISSION=""
REG_TID=""; REG_TID_RC=0
if [ "$CHIP_TOOL_AVAILABLE" = true ]; then
  for candidate in \
    "$HOME/.claude/skills-worktree/.claude/scripts/active-work-cap.sh" \
    "$HOME/.claude/scripts/active-work-cap.sh" \
    ".claude/scripts/active-work-cap.sh"; do
    [ -x "$candidate" ] && { CAP_SH="$candidate"; break; }
  done
  for candidate in \
    "$HOME/.claude/skills-worktree/.claude/scripts/chip-offer-registry.sh" \
    "$HOME/.claude/scripts/chip-offer-registry.sh" \
    ".claude/scripts/chip-offer-registry.sh"; do
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
    if [ "$CAP_JSON_RC" -ne 0 ] || [ "$FREE_RC" -ne 0 ] || [ "$BASELINE_RC" -ne 0 ] \
       || ! [[ "$FREE" =~ ^[0-9]+$ ]] || ! [[ "$REG_BASELINE" =~ ^[0-9]+$ ]]; then
      echo "DEGRADED: active-work cap could not be read — continuing uncounted" >&2
    elif [ "$FREE" -eq 0 ]; then
      echo "DEFERRED: repo-wide active-work cap is full; no offer was stamped or emitted" >&2
      exit 7
    elif [ -z "$REGISTRY" ]; then
      echo "DEGRADED: chip-offer-registry.sh not found — continuing uncounted" >&2
    else
      CAP_ADMISSION=$((REG_BASELINE + FREE))
      ISSUE_NUMBERS=$(jq -r --arg repo "$REPO" "$MINE_DEF"'.issues[] | mine | .number' "$LOG") || {
        echo "ERROR: could not enumerate the open issues covered by this hand-off" >&2
        exit 1
      }
      [ -n "$ISSUE_NUMBERS" ] || { echo "ERROR: no open session issues to hand off" >&2; exit 1; }
      ISSUE_ARGS=()
      while IFS= read -r issue_number; do
        [ -n "$issue_number" ] && ISSUE_ARGS+=(--issue "$issue_number")
      done <<< "$ISSUE_NUMBERS"
      REG_TID=$("$REGISTRY" --repo "$REPO" --reserve --emitter issue-maker "${ISSUE_ARGS[@]}" \
        --cap-free "$CAP_ADMISSION" 2>/dev/null) || REG_TID_RC=$?
      if [ "$REG_TID_RC" -eq 7 ]; then
        echo "DEFERRED: active-work cap was consumed before handoff reservation; no offer was stamped or emitted" >&2
        exit 7
      elif [ "$REG_TID_RC" -ne 0 ]; then
        echo "DEGRADED: chip registry unavailable (exit $REG_TID_RC) — continuing uncounted" >&2
        REG_TID=""
      fi
    fi
  fi
fi

if [ -n "$REG_TID" ]; then
  if ! set_log '.reg_tid = $reg | .delivery_mode = "chip-pending" | .handoff_checkpoint = {state:"reserved", task_id:null}' \
      --arg reg "$REG_TID"; then
    "$REGISTRY" --retract --task-id "$REG_TID" >/dev/null 2>&1 || true
    echo "ERROR: reservation could not be persisted; no chip was started" >&2
    exit 1
  fi
fi

# Stamp immediately before the first actual emission (spawn or printed block).
OFFER_TOKEN="offer-$(date +%s%N)"
OFFER_MODE=inline
[ -n "$REG_TID" ] && OFFER_MODE=chip-pending
if ! set_log "$MINE_DEF"'.delivery_mode = $mode | (.issues[] | mine | .chip_task_id) = $tok' \
    --arg mode "$OFFER_MODE" --arg tok "$OFFER_TOKEN" --arg repo "$REPO"; then
  if [ -n "$REG_TID" ]; then
    "$REGISTRY" --retract --task-id "$REG_TID" >/dev/null 2>&1 || true
  fi
  echo "ERROR: offer stamp could not be persisted; do not spawn or emit the handoff" >&2
  exit 1
fi
```

- **Chip mode** (`mcp__ccd_session__spawn_task` present): use the reserved `REG_TID` above. **Retain it** separately from `chip_task_id` for later `--transition` calls (`running` on start, `pr-backed` when a PR opens, `done`/`retracted` on terminal events). Call `spawn_task` **once** with `title` (verb-first, ≤60 chars — e.g. `Run 5 captured issues (#1230 first)`), `prompt` (the block above, verbatim), `tldr` (1–2 plain sentences), `cwd` (repo root). After success, make one checked atomic log write that replaces the offer token with returned `task_id`, retains `reg_tid`, sets `delivery_mode` to `"chip"`, and clears the pending checkpoint. If that write fails, the pre-spawn reservation record remains in `$LOG`; stop and report that the chip started as `$TASK_ID` but its receipt needs reconciliation. Do not clear or overwrite `reg_tid`. Print only the short summary per `chip-launching.md` "Short-summary transcript format".
- **Fallback mode** (tool absent or spawn failed): print the full fenced block above once. Leave `chip_task_id` holding the offer token (not null). Note the fallback once. If `REG_TID` was reserved before the spawn failure, run the cleanup below before printing. Leave the stamped issue token intact for the copyable handoff.

```bash
if [ -n "$REG_TID" ]; then
  if "$REGISTRY" --retract --task-id "$REG_TID" >/dev/null 2>&1; then
    if ! set_log '.reg_tid = null | .delivery_mode = "inline" | .handoff_checkpoint = null'; then
      echo "ERROR: reservation released but session cleanup could not be persisted; retry local reconciliation before another offer" >&2
      exit 1
    fi
  else
    set_log '.handoff_checkpoint = {state:"cleanup-pending", task_id:null}' || true
    echo "ERROR: chip reservation cleanup is uncertain; reg_tid remains persisted" >&2
  fi
fi
```

After a successful spawn, persist its receipt in one checked write:

```bash
if ! set_log "$MINE_DEF"'.delivery_mode = "chip" | .reg_tid = $reg | .handoff_checkpoint = null | (.issues[] | mine | .chip_task_id) = $task' \
    --arg reg "$REG_TID" --arg task "$TASK_ID" --arg repo "$REPO"; then
  # Best-effort checkpoint-only recovery keeps the returned task ID too.
  set_log '.handoff_checkpoint = {state:"spawned-receipt-pending", task_id:$task}' \
    --arg task "$TASK_ID" || true
  echo "ERROR: chip started as $TASK_ID but its receipt needs reconciliation; the pre-spawn reg_tid remains persisted" >&2
  exit 1
fi
```

If the user asks to "print the full prompt for #N", re-emit that issue's complete block verbatim (Model line + guard preamble included) — same as `chip-launching.md` "Print-on-demand replay".
