<!-- go-on-routing:begin -->
Route `review:merge`.

**Trigger:** the lane reaches Step 8.

**Prerequisites:** the `token-exhaustion` or `unplanned` kind module routed the lane here, and the lane preflight resolved every review module. `review:prepare` ran, and Step 7 found no unresolved findings.

**Loop-backs:** Step 8 returns to Steps 6 and 7 in `review:respond`. Its non-clean `BEHIND` path uses Step 1's exit table in `review:prepare`. Step 9a returns to Step 9 on an authoritative AC failure.
<!-- go-on-routing:end -->

## Step 8: Check merge gate

Run the shared merge-gate verifier (implements CR 1 explicit APPROVED on current HEAD / BugBot 1-clean / Greptile severity + CI + BEHIND checks):

```bash
# CLEAN_BEHIND is state derived from THIS evaluation only. Clear it on entry —
# before the gate runs, ahead of every branch below, including exit 0 — because
# /go-on re-enters Step 8 (the rebase branch re-runs the gate, and Step 7 loops
# back through Step 6). A value left over from an earlier pass would re-enter
# Step 9a on a PR that is no longer BEHIND, where the re-probe returns exit 1
# ("mergeStateStatus is …, not BEHIND"), item 3 reads that as "genuinely not
# clean", and the branch is rebased and force-pushed a second time for nothing.
# Resetting inside the BEHIND bullet alone is NOT enough: the gate-exit-0 path
# never reaches that bullet.
CLEAN_BEHIND=0

GATE_JSON=$("$MERGE_GATE_SH" "$PR_NUM")
GATE_EXIT=$?
```

Branch on the exit code:

- `0` → `[DONE]` — Merge gate satisfied. Proceed to Step 9 (AC verification). `CLEAN_BEHIND` stays `0` here, so Step 9a correctly `[SKIP]`s: nothing about this pass is a clean-`BEHIND` follow-through.
- `1` → `[ACTION]` — Gate not met. Parse `missing` from the JSON output and act accordingly:
  - CR path with **"need 1 explicit CR APPROVED review on HEAD"**: if the current SHA is still within the 12-minute CR polling window, return to **Step 6** and keep polling — do NOT re-trigger yet. Only after the 12-minute timeout, and only within the 2-trigger-per-hour budget, post `@coderabbitai full review` once and return to **Step 6**.
  - CR path with **"CR approval on HEAD ... retracted by later CHANGES_REQUESTED"**: CR retracted approval. Return to **Step 7** to process the findings. Re-trigger only after fixes are pushed (the new SHA invalidates prior reviews regardless).
  - CR path with **"CodeRabbit check-run not green on HEAD"** or **"latest CR review on HEAD requests changes"**: CR has findings; return to **Step 7** to process them.
  - BugBot path with **"no BugBot review on HEAD"**: BugBot hasn't reviewed the current HEAD yet; return to **Step 6** to poll for the review.
  - BugBot path with **"latest BugBot review on HEAD has findings"**: return to **Step 7** to process findings.
  - Greptile path with **"unresolved Greptile thread(s)"**: return to **Step 7** to process; if P0 remains after fix, a re-trigger is a new paid review: ask the owner, and post `@greptileai` only on their approval in chat (subject to the 3-review cap per `.claude/rules/greptile.md`).
  - **"branch is BEHIND base"**: **probe before prescribing anything** (issue #1564). A *verified clean* `BEHIND` is an auto-merge, not a rebase — canonical in `.claude/rules/cr-merge-gate.md` Step 1d and `CLAUDE.md` "PR MERGE AUTHORIZATION" (issue #754), and encoded the same way in `.claude/agents/phase-c-merger.md` (issue #1563) and `fixpr/SKILL.md` Step 6. Rebasing a clean `BEHIND` moves HEAD, discarding the bot approval that had already satisfied the rest of the gate and restarting CI — the treadmill the carve-out exists to avoid.

    **Re-resolve the reviewer before probing — never reuse Step 5's variable.**
    Step 5 leaves `$REVIEWER` as the literal string `unknown` on its exit-`1`
    branch (its "treat as CR" instruction changes the *routing*, not the
    variable), and Step 6's escalations persist the new owner with
    `"$REVIEWER_OF_SH" --sticky …` **without** reassigning the shell variable. A
    bare `-n` guard therefore admits two wrong values: `--reviewer unknown` is a
    usage error (exit `2` → `[BLOCKED]`), and a stale `cr` after a
    BugBot/Greptile escalation gates the *wrong* path — a gate that can never go
    green, whose residual blocker reads as "not clean" and buys exactly the
    rebase this step exists to prevent. Validate the value and pass the flag
    **only** when it is one of the three the script accepts; otherwise omit it
    and let `merge-gate.sh` auto-detect, which reads the same sticky assignment
    Step 6 persisted. Same shape as `.claude/agents/phase-c-merger.md` Step 1
    (issue #1563).

    ```bash
    # Re-read rather than reuse: session-state holds any sticky escalation
    # Step 6 persisted, which never reached this shell's $REVIEWER.
    CB_REVIEWER=""
    RESOLVED_EXIT=0
    RESOLVED=$("$REVIEWER_OF_SH" "$PR_NUM") || RESOLVED_EXIT=$?
    if [[ "$RESOLVED_EXIT" -eq 5 ]]; then
      # Malformed session-state — STOP HERE, do not probe. Exit 5 is Step 5's
      # documented fail-fast, and omitting --reviewer would not be a safe
      # degradation: it lets merge-gate.sh fall through to a live-history guess
      # that can mis-route an already-escalated PR back to CR, mark a clean
      # BEHIND as unclean, and prescribe the rebase this step exists to prevent.
      # Report [BLOCKED] and leave CLEAN_BEHIND at 0; repair or remove
      # ~/.claude/session-state.json and re-run /go-on.
      echo "reviewer-of.sh exit 5: session-state malformed — blocking, not probing." >&2
      # → [BLOCKED]: skip the probe entirely.
    else
      case "$RESOLVED" in
        cr|bugbot|greptile) CB_REVIEWER="$RESOLVED" ;;
        *) CB_REVIEWER="" ;;   # `unknown` and anything else → omit the flag
      esac

      # Reached ONLY when the resolution above did not block. `|| CB_EXIT=$?`,
      # not a bare assignment: exit 1 is the EXPECTED pre-tick result here, and
      # under `set -e` a bare assignment would abort the block before the status
      # was ever captured.
      CB_EXIT=0
      if [[ -n "$CB_REVIEWER" ]]; then
        CB_JSON=$("$CLEAN_BEHIND_SH" "$PR_NUM" --reviewer "$CB_REVIEWER") || CB_EXIT=$?
      else
        CB_JSON=$("$CLEAN_BEHIND_SH" "$PR_NUM") || CB_EXIT=$?
      fi
    fi
    ```

    An omitted `--reviewer` is safe **only** on the non-blocking branch, where
    `reviewer-of.sh` returned a usable answer that simply was not one of the
    three enum values (`unknown` — no bot has reviewed yet). It is never a
    substitute for a resolution that failed.

    Read the JSON, never `$?` after a pipe. `CLEAN_BEHIND` was already cleared at
    Step 8 entry, so only the two clean outcomes below can raise it:

    - `0` (`safe_to_offer: true`) → `[ACTION]` — **verified clean `BEHIND`.** No snapshot, no rebase, no force-push. Set `CLEAN_BEHIND=1` and continue to **Step 9**: this path is **AC-first**, Step 9a finishes the verification, and Step 10 hands the merge to `/wrap`.
    - `1` whose `reasons_not_safe` / `residual_blockers` are **only** the unchecked-Test-Plan-checkbox count and/or a sole `ac-gate` check-run — **failing *or* still incomplete** — → `[ACTION]` — **clean-`BEHIND` candidate**, i.e. "waiting on Step 9", not a blocker. `clean-behind-check.sh` counts unticked boxes as `reasons_not_safe`, so a pre-tick exit `1` is bookkeeping rather than a real blocker. Treat exactly as `0`: set `CLEAN_BEHIND=1`, continue to Step 9.
    - `1` with **any other** residual blocker → genuinely non-clean `BEHIND`. Surface `reasons_not_safe`, then `[ACTION]` — `diff-survival-check.sh snapshot`, rebase onto base, then `diff-survival-check.sh verify` (Step 1 branch table) and force-push **only** on exit 0; wait for a fresh review, then re-run the gate.
    - `2`/`3`/`4` → `[BLOCKED]` — usage error / PR not found or not open / `gh`-network-jq error. Surface the JSON or stderr. Nothing was reported *about this `BEHIND`*, so it is neither clean nor unclean — **never** read a non-`1` failure as a rebase signal, which would buy a rebase on evidence you do not have.

    `churn.advisory` is context, never a gate.
  - **"CI has N failing check-run(s)"** or **"CI has N incomplete check-run(s)"**: fix CI or wait for incomplete runs, then re-run the gate — **except when the BEHIND bullet above already claimed this pass.** The ordinary pre-tick candidate is a `missing[]` of exactly `BEHIND` + a sole failing-or-incomplete `ac-gate`, so both bullets match the same JSON; the BEHIND bullet wins and this one is `[SKIP]`ped for that `ac-gate` entry. Following this bullet instead would re-enter Step 8 after Step 9's body PATCH, and that read returns `merge_state: "UNKNOWN"` with the `BEHIND` entry **gone from `missing[]`** — so the probe never fires, `CLEAN_BEHIND` stays `0`, Step 9a `[SKIP]`s, and the clean-`BEHIND` path is lost silently. Precedence, concretely: if `missing[]` contains a `BEHIND` entry, resolve the BEHIND bullet first and act on its verdict; only CI entries **other than** that sole pre-tick `ac-gate` (or any CI entry on a pass with no `BEHIND`) belong to this bullet.
- `3` → `[BLOCKED]` — PR not found (closed or merged).
- `2`/`4` → `[BLOCKED]` — script or gh error; surface the message to the user.

---

## Step 9: Verify acceptance criteria

Run the acceptance criteria check via the shared helper:

```bash
ITEMS=$("$AC_CHECKBOXES_SH" "$PR_NUM" --extract)
AC_EXIT=$?
```

Branch on exit code:
- `0` → `$ITEMS` is a JSON array of `{index, checked, text}`. For each item with `checked == false`, read the relevant source files and verify the criterion. Tick passing items by index with `"$AC_CHECKBOXES_SH" "$PR_NUM" --tick "0,2,3"` (or `--all-pass` if every unchecked item passed). On a clean-`BEHIND` candidate (`CLEAN_BEHIND=1`), establish `TICK_AT` **on every path through this step, including the one where nothing needs ticking** — Step 9a item 1 compares it against the `ac-gate` run's `started_at`, and an unset baseline makes that comparison meaningless. A candidate can arrive here already fully ticked (Step 8 admits a `missing[]` of `BEHIND` + a sole `ac-gate` with every box already checked), in which case the tick command never runs:

  ```bash
  if [[ -n "$TICKED_ANY" ]]; then
    # A --tick/--all-pass actually ran: the body reached its final state now.
    TICK_AT=$(date -u +%FT%TZ)
  else
    # Nothing to tick — the body was already final before this step. Use the
    # PR's updatedAt as a conservative upper bound on the last body write: a
    # body edit always bumps it, so a run started after it definitely read the
    # final body. (Other events bump it too, which only makes the baseline
    # later — erring toward "pre-tick suspect", the safe direction.)
    TICK_AT=$(gh pr view "$PR_NUM" --json updatedAt --jq .updatedAt)
  fi
  ```

  If neither can be established, do **not** guess: treat every failing `ac-gate` as pre-tick-suspect and take item 1's single-rerun path, which is bounded and cannot loop.
- `1` → `[BLOCKED]` — PR body is missing a Test Plan section. Every PR must include one (per CLAUDE.md). The PR is NOT merge-ready until the body is fixed — report this to the user and do not continue to the merge decision.
- `3` → `[BLOCKED]` — PR not found.
- `2`/`4` → `[BLOCKED]` — script or gh error; surface stderr to user.

- If all items pass after ticking: `[DONE]` — All acceptance criteria verified and checked off.
- If any item fails: `[ACTION]` — Fix the failing criteria, then re-verify.

---

## Step 9a: Clean-`BEHIND` follow-through (candidates only)

`[SKIP]` unless Step 8 set `CLEAN_BEHIND=1`. Ticking AC has two after-effects; both must settle before Step 10, and they overlap, so run them in this order and wait once. Mirrors `.claude/agents/phase-c-merger.md` Step 2a (issue #1563).

1. **Re-run the `ac-gate` check — but only if it is terminal and failing.** `ac-gate.yml` triggers on `opened`/`synchronize`/`reopened`, so a PR-body edit never re-fires it — a red `ac-gate` on an unticked PR is by design and stays red until rerun. Read the `ac-gate` check-run's **current** status on HEAD first and branch on it; `merge-gate.sh` reports only *failing* checks in `ci_status.blocking[]`, so an absent id means "not failing", never "green":
   - **`completed` + failing** → rerun it. The id in `ci_status.blocking[].id` is a **job** id: `gh run rerun --job "$AC_GATE_JOB_ID"`. A rejected rerun (stale id, permissions, GitHub error) means `ac-gate` was never re-fired, so waiting would burn the whole deadline for nothing → `[BLOCKED]`, reporting the `gh` error and the job id, without entering the wait. The rerun publishes a **new** job id on the same run, so poll that one (or re-read the check-run by name from the HEAD SHA); the old id stays `failure` forever, so polling it would never terminate.
   - **`queued` / `in_progress`** (the Step 8 candidate shape admits this) → **do not rerun *yet*.** GitHub rejects a rerun of a run that is still going, and an in-flight job only publishes another id to chase. But do **not** record this run as authoritative either: by this step's own premise it was fired by the last `synchronize`, i.e. **before** Step 9's tick, and whether its body read lands before or after the PATCH is a race. So wait it out under item 2's deadline, then judge it by **when it started, not by its conclusion** — compare the check-run's `started_at` against `TICK_AT`, the body's final-state baseline that Step 9 establishes on every path (post-`--tick`/`--all-pass` clock reading, or the PR's `updatedAt` when nothing needed ticking):
     - `started_at` **after** `TICK_AT` → the run definitively read the ticked body; its conclusion is authoritative (green → item 2's mergeability wait; failing → a real AC failure, back to Step 9).
     - `started_at` **at or before** `TICK_AT` → pre-tick-suspect. A green conclusion is still trustworthy (it passed on a body that was *less* complete). A **failing** one is not evidence of anything — it is the by-design pre-tick red — so once the run is terminal, rerun it **once** via the `completed` + failing branch above and wait again on the new job id. One rerun only: a second failing conclusion from a run started after `TICK_AT` is a real AC failure.
   - **`completed` + green** → nothing to rerun, but do **not** skip item 2: the body PATCH still invalidated mergeability, and that has to settle before the re-probe.
2. **Wait out the mergeability recompute.** `ac-checkboxes.sh --tick` / `--all-pass` PATCHes the PR body, and GitHub invalidates mergeability on any body write — the next gate read returns `merge_state: "UNKNOWN"` with the `BEHIND` entry **gone from `missing[]`**. That is not a new blocker and never a reason to rebase. Proceed only when **both** hold: the `ac-gate` check-run on HEAD has reached a terminal `status: "completed"` (any conclusion), **and** `gh pr view "$PR_NUM" --json mergeStateStatus` is no longer `UNKNOWN` (~30–60s). Advancing on mergeability alone hands item 3 a still-queued `ac-gate`, which `clean-behind-check.sh` reports as an *incomplete*-CI residual — read as a non-clean `BEHIND`, that triggers exactly the rebase this path exists to prevent. **Both waits share one 10-minute deadline, started on entry to this item** — `WAIT_UNTIL=$(( $(date -u +%s) + 600 ))` as the first thing item 2 does. Anchoring it to "the rerun" would leave two of item 1's three branches with no clock at all (`queued`/`in_progress` and `completed` + green both arrive here having reran nothing), so the wait would either have no bound or compare against an unset value and `[BLOCKED]` on its first tick. Item 1's single rerun, when it fires, **restarts** the deadline from that moment — a fresh job id is fresh work, and it must not inherit time already spent waiting on the run it replaced. The deadline is a stop condition, never a licence to proceed with a condition unmet. Either still unmet at the deadline → `[BLOCKED]`, naming which one did not settle plus the job's URL and status: do **not** re-probe and do **not** rebase — an unsettled wait is not evidence the `BEHIND` is unclean. An `ac-gate` that completes with a **failing** conclusion is a real AC failure → back to Step 9, not a rerun loop — but only once item 1 has established the run actually started **after** `TICK_AT`. A failing conclusion from a pre-tick run is the by-design red, not an AC failure; item 1 sends that one back for its single rerun instead.
3. **Re-probe.** Run `clean-behind-check.sh` again — same invocation *and the same exit-code table* as Step 8, so `2`/`3`/`4` block here too rather than being read as an unclean `BEHIND`. Exit `0` / `safe_to_offer: true` is the authorization Step 10 carries. A still-**incomplete** `ac-gate` in `residual_blockers` here means item 2's wait was left early — go back and finish it. Exit `1` once AC is ticked and `ac-gate` has completed **green** → the `BEHIND` genuinely is not clean: take the Step 8 non-clean rebase path.

---

## Step 10: Report completion

Output a summary:

```
=== /go-on complete ===

Stoppage: <pause | end | token_exhaustion | unplanned> (recorded <record_at>)
Branch: $BRANCH
PR: #$PR_NUM
Reviewer: CR / Greptile
Merge gate: MET / MET (clean BEHIND — cleared by /wrap Step 2.4) / NOT MET
Acceptance criteria: ALL PASSED / N FAILED
Refill: <still paused — clear with /go-on --resume-refill | cleared via <command> --resume-refill | not paused>
Status: Ready for wrap
```

A delegated lane (`pause` / `end`) reports the companion command's own board instead of this block, plus the `Stoppage:` and `Refill:` lines. Ranks 4 and unclassifiable report only what was found — no board, no status line, no state change.

If the merge gate is met and all AC pass, run `/wrap` immediately — no pre-merge prompt (`CLAUDE.md` "PR MERGE AUTHORIZATION"). Honor an explicit user opt-out ("don't merge" / "wait for my approval") if given in chat.

**A verified clean `BEHIND` counts as met for this hand-off (issue #1564).** `BEHIND` is cleared *by* the merge, so on that path the gate still reports exit `1` with the `BEHIND` entry present — the same loop-exit rule `/wrap` applies to itself (gate exit `1` with `BEHIND` as the sole `missing[]` item; issue #1425). When Step 9a's re-probe returned exit `0`, dispatch `/wrap` on that basis rather than reporting NOT MET. **`/wrap` Step 2.4 is the merge executor** — it runs `admin-merge.sh "$PR_NUM" --auto-plain --ac-verified` itself, with no `AskUserQuestion` (issue #754): the plain shape modifies no branch protection, so it needs no user turn. **Do not run `admin-merge.sh` from `/go-on`** — `--auto-plain` carries a repeat guard, so a call here would consume the one attempt and `/wrap`'s would then refuse with exit `8`, merging nothing. Step 2.4 owns that script's semantics; its exits map as: `0` → merged, relay the `AUTO_PLAIN_MERGED` evidence block; `8` → the shape needs a protection change (or an auto attempt already ran) → **surface `/admin-merge $PR_NUM` as a user choice and never auto-run it**; `1` → the clean state no longer held at merge time (main advanced) → Step 2.4's own rebase fall-through and recovery loop.
