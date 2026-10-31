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

**First emission stamps the covered issues before either delivery mode.** A declined/deferred inline offer may have left no token, so never assume one exists. For a new explicit handoff request, generate/stamp a fresh token with the repo/origin selector before attempting a spawn or printing fallback. Do not run this block for a replay of an already emitted payload.

```bash
OFFER_TOKEN="offer-$(date +%s%N)"
set_log "$MINE_DEF"'.delivery_mode = "inline" | (.issues[] | mine | .chip_task_id) = $tok' \
  --arg tok "$OFFER_TOKEN" --arg repo "$REPO"
```

- **Chip mode** (`mcp__ccd_session__spawn_task` present): **before calling `spawn_task`, register via the full contract** (see `chip-launching.md` "Offer Registry"): `REG_TID="$(chip-offer-registry.sh --emitter issue-maker --issue <primary-N> --cap-free "$FREE" --reserve 2>/dev/null)"` — exit 7 means defer (same as `FREE=0`); any other non-zero exit means proceed uncounted. **Retain `REG_TID`** separately from `chip_task_id` for later `--transition` calls (`running` on start, `pr-backed` when a PR opens, `done`/`retracted` on terminal events). Call `spawn_task` **once** with `title` (verb-first, ≤60 chars — e.g. `Run 5 captured issues (#1230 first)`), `prompt` (the block above, verbatim), `tldr` (1–2 plain sentences), `cwd` (repo root). On success, update `chip_task_id` on covered issues to the returned `task_id` (replacing the offer token), write `reg_tid` to `$LOG` at the top level (`set_log '.reg_tid = $v' --arg v "$REG_TID"`) so retraction can transition the registry entry if the offer is later withdrawn, and update `delivery_mode` to `"chip"` (`set_log '.delivery_mode = "chip"'`) — this is the unambiguous post-compaction marker that distinguishes a running chip task from a pending inline offer. Print only the short summary per `chip-launching.md` "Short-summary transcript format".
- **Fallback mode** (tool absent or spawn failed): print the full fenced block above once. Leave `chip_task_id` holding the offer token (not null). Note the fallback once. If `REG_TID` was reserved before the spawn failure, transition it to `retracted` (`chip-offer-registry.sh --transition --task-id "$REG_TID" --state retracted`) so active-work-cap.sh stops counting it. Clear the registry identifier only after a confirmed transition. If that transition fails or is uncertain, persist `reg_tid` plus a pending-cleanup checkpoint and report the failure; do not lose the identifier or claim cleanup succeeded. Leave the stamped issue token intact for the copyable handoff.

If the user asks to "print the full prompt for #N", re-emit that issue's complete block verbatim (Model line + guard preamble included) — same as `chip-launching.md` "Print-on-demand replay".
