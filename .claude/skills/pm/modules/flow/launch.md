<!-- pm-routing:begin -->
Start the selected eligible work only after the universal launch gates.
On a day arming turn, check the authoritative credit budget immediately
before delegating the initial 1B.5 launch. The budget carve-out in
`safety.md` applies to day mode and refill. Ordinary cold start proceeds
through its existing gates. Use the same helper as 3.4. Set
`PM_INITIAL_USER_DIRECTED=true` only for work explicitly named for launch
by the user in chat. The default batch is autonomous.

<!-- test-anchor: pm-initial-launch-credit-budget -->
```bash
PM_INITIAL_BUDGET=not-applicable
if [ "${DAY_MODE:-false}" = true ]; then
  PM_INITIAL_BUDGET=unknown
  for candidate in \
    "${HOME:+$HOME/.claude/skills-worktree/.claude/scripts/credit-budget.sh}" \
    "${HOME:+$HOME/.claude/scripts/credit-budget.sh}" \
    ".claude/scripts/credit-budget.sh"; do
    if [ -x "$candidate" ]; then
      CREDIT_RC=0
      CREDIT_RESULT=$("$candidate" --check) || CREDIT_RC=$?
      CREDIT_STATUS=$(jq -ser 'select(length == 1) | .[0].status | strings' <<<"$CREDIT_RESULT" 2>/dev/null) || CREDIT_STATUS=""
      case "$CREDIT_RC:$CREDIT_STATUS" in
        0:ok) PM_INITIAL_BUDGET=ok ;;
        1:reached) PM_INITIAL_BUDGET=reached ;;
      esac
      break
    fi
  done
  if [ "$PM_INITIAL_BUDGET" != ok ] && [ "${PM_INITIAL_USER_DIRECTED:-false}" = true ]; then
    PM_INITIAL_BUDGET=explicit-override
  fi
fi
printf 'PM_INITIAL_BUDGET=%s\n' "$PM_INITIAL_BUDGET"
```

Proceed on `ok` or `not-applicable`. On `explicit-override`, use the existing
`[budget spent/unknown today] Proceeding at your request.` note once.
On `reached` or `unknown`, report the corresponding budget hold and
start no new pipeline from this batch. Keep the ranked plan and finish
already-running work.
<!-- pm-routing:end -->

On cold start, only surviving `BATCH_ISSUES` are eligible for immediate inline launch. Keep ranked overflow in the unclaimed standing queue for 3.4. Before an overflow pick can launch, 3.4 revalidates it, including the ownership sweep and current gates. Apply the existing thread-prompt and decomposition paths to the separately routed picks.

**The selection arrives already made.** 1B.5 hands over the top-ranked batch by default, 1A.4/3.4 hand over refill picks the same way, and an `adjust` from the user replaces the set — there is no separate "which of these?" turn to wait for. **Partition the batch** with the "too big for any subagent" test from `/subagent` Step 4 — the implementation can't be carried across sequential subagent turns, needs interactive human judgment mid-build, or should be split into multiple PRs. This is a judgment call about *resumability and interactivity*, not tier, and not file/AC/dependency counts. Neither sheer size, nor touching `.claude/rules` / `CLAUDE.md` / `.claude/skills`, nor a full inline pipeline makes an issue too big — past-ceiling work queues inline (#776). **The partition is three-way, not two:** the third criterion decomposes rather than routing out (#1193), so only criteria 1 and 2 produce a thread. Then:

- **Inline-eligible issues (the default — most issues):** run them inline through the `/subagent` A→B→C flow. This is the default action; the issue landing in the batch **is** the go-ahead — neither a selection turn nor a "go ahead and run those" is waited on. Invoke `/subagent #{a} #{b} …` with the eligible set **through the Skill tool** (`skill: "subagent"`) — never by starting a `phase-a-fixer` / `phase-b-reviewer` / `phase-c-merger` with the `Agent` tool from this thread, which skips Step 7.1's launch record (no Start, no estimate, no table). A repo rule that lets the parent merge directly replaces Phase C only, never this launch (#1903). It runs Phase A then Phase B under Dedicated Monitor Mode, driving each to `merge_ready`, then **auto-launches Phase C** (full `/wrap`, silent merge). Keep prospective standing picks outside this Skill call until Step 3.4 promotes them. Launch up to the **`LIMIT` concurrent-pipeline** limit (Step 0 — `min(CEILING, ACTIVE_WORK_CAP)`) from `subagent-orchestration.md` and queue the rest, starting a queued pipeline as each running one **merges or blocks** — a pipeline parked at `merge_ready` keeps its slot through Phase C (see 3.4, which refills on free capacity, not only on a finish). Mark each such issue `Inline` in the Active Work table (3.2). `/subagent` Step 7.2 supplies the round's launch and queue records, including queued rows with `—` clocks. **A dispatch is not finished until its machine-readable launch and queue records exist.** Use `/board` (3.3a) for an explicit request or a scheduled report when due. `/board` shows every recorded Step 7.1 clock; name the launches with no record separately in one line — `/board` may show them as a queued row or not at all (`No active round`), so a row never proves a launch happened — and never backfill a Start. If launch records are missing, name the affected launches and stop further launches for this round. Issues in the set that **overlap on a file** are serialized rather than started together — `/subagent` Step 6.0b owns that; expect a chained issue to start later than a free slot alone would suggest.
- **Criterion-3 issues — decomposed, never chipped whole (#1193):** an issue that fails the fit bar because it *should be split into multiple PRs* is split here rather than handed out. `/subagent` Step 5.1 files its increment children, links them, writes the tracking checklist into the parent, and queues the chain inline; the parent stays open as the tracking issue and takes no row of its own beyond the parent/children group in 3.2. **Never generate a chip or a prompt block for a criterion-3 parent** — that is the fan-out this rule exists to end. Report the split (one line per child, the rationale once on the head) exactly as Step 5.1 specifies. If the split needs more than 5 children, if a clean split cannot be articulated, or if Step 5.1's dependencies did not resolve, Step 5.1 routes the parent out instead — then and only then it reaches the thread-prompt path below. Its one-line reason is **criterion 3 plus why decomposition was unavailable** ("needs 7 increments, past the 5 cap"), which is the one shape in which criterion 3 is a valid route-to-thread verdict (`chip-launching.md`). A bare "criterion 3" is not: it would be rejected as invalid and the issue would stall, neither routed nor decomposed.
- **Criterion-1/2 issues (the exception):** hand these out as thread prompts for the user to launch in a separate thread, each with a **one-line reason** naming which criterion fired.

**Prompt and chip generation has exactly two triggers.** Nothing else reaches the thread-prompt path below. Call the issues one of these two triggers puts there **thread-prompt issues**; everything from here to the end of 3.1 governs that set only:

1. **A named `/subagent` Step 4 criterion 1 or 2 disqualifier, quoted in the offer** — which of the two thread-routing criteria fired, and why, in one line. **Criterion 3 is not on this list**: it decomposes (bullet above), and naming it here is not a valid route-to-thread verdict. A verdict you cannot pin to a named criterion is not valid either: queue the issue inline instead (`chip-launching.md` "PM-context inline gate").
2. **An explicit user ask** — "give me prompts instead", or a request naming specific issues. **Scope it to what the ask names:** a bare "give me prompts instead" covers the **whole current batch**; an ask naming issues covers **those issues only**, and the rest of the batch still dispatches inline. Generate prompts for that set: those issues are not dispatched inline, and no chip is offered beyond it. The block is the one below, unchanged — model and effort lines, verbatim model-guard preamble, verbatim merge-authority bullet. Never widen an ask past what it named. These issues have **no** too-big criterion, so their one-line reason names the request itself ("prompt requested") — never invent a disqualifier to fill the slot. The user directing a hand-off is not a routing verdict, so `chip-launching.md`'s inline gate is not being overridden for anything the user did not name.

**Inline-eligible issues are never turned into chips by default** — not for size, not for a batch that looks large, and not because the pipeline is full (past-ceiling work queues inline — `/subagent` Step 7). A `/pm` run over a subagent-fit backlog ends with pipelines running and a queue, not a wall of chips (#1190).

**Thread-prompt delivery.** For each issue that reached this path — too-big, or named in an explicit prompt request — generate a self-contained prompt. The prompt content below is the same in both delivery modes — only how it reaches the user differs.

**Before offering anything, consult the shared issue-maker record** (`chip-launching.md` "Cross-skill chip visibility") — `/issue-maker` runs in its own capture-only thread and can't write to this thread's Active Work table, so a chip it already offered is invisible to the table alone. Glob `~/.claude/handoffs/issue-maker-*-log.json` the same way this step's session-view read already globs both `~/.claude/handoffs/pr-*-handoff.json` (legacy flat) and `~/.claude/handoffs/*/*/pr-*-handoff.json` (scoped, issue #655), and for any thread-prompt issue with a live issue-maker chip (`status: "open"` and non-null `chip_task_id`): skip spawning or printing a new chip for it, and instead add (or refresh) its Active Work row directly — Thread `Chip offered`, Task ID the issue-maker `chip_task_id`, Status `Awaiting thread start`. This is the one case where an Active Work row's Task ID didn't come from a `spawn_task` call this thread made itself. Run the remaining thread-prompt issues (the ones with no live issue-maker chip) through the normal flow below.

**Then bound the batch against the repo-wide cap.** Before the `spawn_task` loop below, read the census from `"$ACTIVE_WORK_CAP_SH"` (resolved in Step 0) — its default output is one line, `CAP=<n> ACTIVE=<n> FREE=<n>`, and you need all three because the deferral message below quotes `{ACTIVE}/{CAP}`; `--free` alone cannot render it (`chip-launching.md` "Repo-wide active-work cap"). Offer **at most `FREE`** new chips this turn. Report the remainder as **deferred**, naming the count and the scope — "3 deferred — repo-wide active-work cap ({ACTIVE}/{CAP} in motion across all threads)" — and give each deferred issue an Active Work row with Thread `—` and Status `Deferred (cap)` so it is visible and re-offerable rather than forgotten. Never silently shorten the list. This is separate from the `CEILING` pipeline ceiling: that one governs *inline* work in this thread, while `FREE` counts every thread on the repo, so a PM thread can be under its own ceiling and still have nothing to offer. Deferred issues are re-offered as active work drains (3.4).

**First, check chip availability** per `.claude/reference/chip-launching.md`, then branch:

- **Chip mode** (`mcp__ccd_session__spawn_task` present): for each thread-prompt issue, **register via `chip-offer-registry.sh --reserve` before calling `spawn_task`** (see `chip-launching.md` "Offer Registry" for the full contract — exit 7 defers that issue). Then call `spawn_task` once per issue with `title` / `prompt` / `tldr` / `cwd`, where `prompt` is the full self-contained prompt below, unchanged. Print **only** the short summary per issue (issue, title, `**Model:**` line, `**Effort:**` line, one-line reason) — see the reference for the exact format. Record each returned `task_id` in the Active Work table (3.2) and set that issue's status to `Chip offered`.
- **Fallback mode** (tool absent): emit the full prompt blocks for every thread-prompt issue — same fences, same content, model-guard preamble included. `chip-launching.md` redefines the fallback baseline as byte-identical to the chip `prompt` (guard included), not pre-chip output — see `chip-model-guard-decision.md`.

**Spawn outcomes are tracked per issue.** A failed `spawn_task` falls back for **that issue alone** — print its full block and leave it at `Prompt generated`. Issues whose spawns succeeded keep their chip, their `task_id`, and their `Chip offered` status; never re-print their block as well, or the same issue is offered twice. Every thread-prompt issue ends with exactly one of: a chip, a printed block, or a `Deferred (cap)` row — deferral is a third terminal outcome, not a missing one, and an issue held back by the repo-wide cap gets neither a chip nor a block (printing its block would hand over the launch the cap just withheld).

Chips preset neither picker control, so the `**Model:**` and `**Effort:**` lines must appear both in the visible summary and inside the chip's prompt text — the `**Model:**` line as the **first line** of the `prompt`, the `**Effort:**` line next, the model-guard preamble immediately after (no blank line between the three). Get both recommendations from `/prompt`'s tier classification when it ran; otherwise infer them from the issue's signals using the same Heavy/Standard/Light mapping. `{MODEL}` is a bare family name (`Opus`, `Sonnet`, `Haiku`, `Fable`) and `{LEVEL}` is a picker label (**Low**/**Medium**/**High**/**Extra**/**Max**). Insert the mandatory model-guard preamble defined in `chip-launching.md` verbatim, never reworded. When the parent thread is on Fable and the chip recommends a different model, add the pre-click warning from `chip-launching.md` "Upstream requirement" in the short summary.

If the user asks to "print the full prompt for #N" while in chip mode, re-emit that issue's complete block verbatim, guard included — the chip stays offered.

Each thread-prompt issue's prompt must include:

```
**Model:** {MODEL} — {REASON}
**Effort:** {LEVEL} — {REASON}
{Model-guard preamble — insert verbatim from `chip-launching.md` "Model-guard preamble", immediately after these lines, no blank line between}

You are a coding agent working on {repo URL}.

## Task
Fix/implement issue #{N}: {title}
{Full issue URL}

## Issue Details
{Issue body — paste the full body so the thread has context}

## Relevant Codebase Context
{Based on the issue body and recent PRs, describe:}
- Key files likely involved (from issue body references, labels, or educated guess from architecture)
- Patterns to reuse (from pm-config Architecture section)
- Dependencies that are already met

## Workflow
1. Create a worktree for isolated work
2. Read the issue body — this is the canonical implementation plan (includes merged CodeRabbit recommendations when available)
3. Check issue comments only to detect any plan content not yet merged into the body — if found, merge it first
4. Implement the changes
5. Run the local dual-CLI review per `cr-local-review.md` — resolve `local-review.sh` to the first executable of `$HOME/.claude/skills-worktree/.claude/scripts/local-review.sh`, `$HOME/.claude/scripts/local-review.sh`, `.claude/scripts/local-review.sh`, then run it `--tool coderabbit` + `--tool codeant` — fix all findings; read the compact verdict, not the raw log
6. One clean pass on each available CLI (dropped-CLI and outage fallbacks per `cr-local-review.md`), then commit and push
7. Create a PR with `Closes #{N}` in the body
8. Include a Test Plan section with checkboxes for acceptance criteria
9. Enter the review polling loop and fix any findings

## Constraints
- Claim the issue before anything else. After the model guard, resolve `issue-claim.sh` to the first executable of `$HOME/.claude/skills-worktree/.claude/scripts/issue-claim.sh`, `$HOME/.claude/scripts/issue-claim.sh`, `.claude/scripts/issue-claim.sh`, and resolve `chip-claim-receipt.sh` in the same order (skip installed paths if `HOME` is unset or empty; use absolute helper paths across checkouts). If the workflow delegates the listed issues directly to `/subagent`, only check ownership read-only for each issue before sizing or decomposition; skip live foreign or unreadable claims and let `/subagent` Step 6.0 acquire each eligible claim. For direct execution, give a fresh launch its own `CLAIM_HOLDER` (host, epoch, shell PID and two Bash random values) before any repo read, edit or planning. Run `<N> --check --holder "$CLAIM_HOLDER"` and, if it clears, `<N> --claim --holder "$CLAIM_HOLDER" --json`, both with `--repo <owner/repo>`. Report stale before takeover; stop on failure or unless the result is `mine` for the exact holder. Require the receipt helper before acquiring. Keep that acquisition JSON locally and, as soon as the launch creates its assigned worktree, pipe it to `chip-claim-receipt.sh save WORKTREE OWNER/REPO N "$CLAIM_HOLDER"` before switching or coding; stop if saving fails. On resume of that same launch, get the holder only from `chip-claim-receipt.sh read WORKTREE OWNER/REPO N` for its own known worktree and confirm with `<N> --renew --holder "$CLAIM_HOLDER"` (also pass `--repo`). Stop on missing or failed recovery; never read a receipt on a fresh launch or infer ownership from a GitHub marker. Renew before every review or CI wait and at least every 30 minutes of long coding; stop if renewal fails. Pass the issue and same holder to `/wrap` as `CLAIM_PAIRS`. If the claim helper is unavailable on a fresh direct launch, print `DEGRADED: issue-claim.sh not found (checked all three paths) — proceeding unclaimed` and continue.
- Do NOT work on main — use a worktree or feature branch
- Do NOT modify .env files
- Merging is automatic and yours to do: once the merge gate passes and every Test Plan / AC checkbox verifies, run the full `/wrap` yourself to squash-merge — no approval pause, no pre-merge message (`CLAUDE.md` "PR MERGE AUTHORIZATION")
```

The merge-authority bullet is the shared contract from `chip-launching.md` "Merge-authority line" — reproduce it **verbatim**, the same way the model-guard preamble is copied unchanged. Never soften it into an approval request; a specific PR that genuinely needs a hold is the user saying so in chat, never a line in a generated block.

For thread-prompt issues, offer or present the prompt — never execute it: in chip mode the user's click is the only launch path, and in fallback mode the user pastes the block into a thread. Inline-eligible issues are the opposite — PM runs them itself via `/subagent` per the default at the top of 3.1, no extra "go ahead and run those" required.


Mark `3.1 ran` when the dispatch or offer and its required records are verified.
Mark `3.1 failed` for a launch or record failure and `3.1 skipped` for a known
hold or an empty selection. Use the actual reason.

After recording verified launches and their queue state, refresh the
[project page](../../../../reference/pm-output-templates.md#persistent-project-board)
once in the dispatch turn. Coalesce this with any terminal or scheduled
refresh in Step 3.3a.

