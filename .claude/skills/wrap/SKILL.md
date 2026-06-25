---
name: wrap
description: End-of-session command — verify no unresolved findings, squash merge, sync main, detect per-PR follow-ups, run a full-session loose-ends sweep, and extract lessons.
---

Wrap up the current PR and session. This is the "we're done here" command that handles final verification through merge, root-main sync, follow-up detection, a full-session sweep for loose ends, and lessons.

`/wrap` does **not** delete the running worktree or its branch — leaving the thread alive so it can keep working. Stale worktrees and stale local/remote branches are reaped out-of-band by `/pm-update`, which calls `.claude/scripts/stale-cleanup.sh`.

## When to use /wrap vs /merge

- Use **/wrap** at end-of-session. Handles merge + root-main sync + follow-up detection + lessons.
- Use **/merge** for a quick mid-session merge when you'll keep working. Skips follow-up detection and lessons.
- /wrap includes everything /merge does, plus follow-ups and lessons. Don't run both.
- Phase C invokes this skill after gate and AC verification; keep merge, main-sync, follow-up, and cleanup behavior here so Phase C and `/wrap` cannot drift.

## Execution Model

`/wrap` is a set-and-forget command. Once invoked, it runs all 4 phases end-to-end without mid-run confirmation prompts. It stops early only for explicit stop conditions (for example: no PR on current branch, **human** change requests on HEAD, recovery iteration cap, failed merge gate after recovery, **`/fixpr` delegation failure**, AC verification failure).

> **Always:** Execute all phases end-to-end; proceed immediately between phases when no blocker exists.
> **Ask first:** Never — all phases are autonomous once /wrap is invoked.
> **Never:** Stop to ask "should I continue?" between phases; insert confirmation prompts for non-blocker transitions. Delete the running worktree or its branch — that's `/pm-update`'s job, not /wrap's.

### Invocation flags

| Flag | Default | Effect |
|------|---------|--------|
| `--auto-file-followups` | off | When set, Phase 3 **Part B** session-sweep loose ends (category 2) are auto-filed as GitHub issues (with the issue body surfaced in the report) instead of being surfaced under "Needs your decision". The per-PR follow-ups in **Part A** (HHG + linked-issue sub-tasks) always auto-file regardless of this flag — they are derived from the PR/issue, not from ambiguous transcript signal. |

Parse the flag from the invocation arguments once at the top of the run; record it as `WRAP_AUTO_FILE_FOLLOWUPS` (`true`/`false`, default `false`) for Phase 3 Part B. Without the flag, the safe default is **ask first** — surface candidate tickets, never silently create them (issue #471 Confirmation-UX note).

### Phase Transition Autonomy

| Transition | Action | Classification |
|------------|--------|----------------|
| Phase 1 complete (findings scan finished — may have flagged bot findings) | Begin Phase 2 recovery + merge | **Always do** |
| Phase 2 recovery loop exits cleanly (gate met, ready to merge) | AC check → squash merge → Phase 3 | **Always do** |
| Phase 3 per-PR follow-ups + full-session sweep processed | Begin Phase 4 | **Always do** |
| Phase 4 lessons complete (or skipped as trivial) | Output final report | **Always do** |
| Human `CHANGES_REQUESTED` on current HEAD (`human_changes_requested` non-empty in `merge-gate.sh` JSON) | Stop with reviewer names — **never** auto-dismiss | **Genuine block** |
| Recovery iteration cap or non-recoverable gate failure | Stop with full audit + last `missing` | **Stop and report** |
| AC checkbox verification fails (Phase 2.2) | Stop and report | **Stop and report** |

> **Anti-pattern:** If you find yourself composing "Should I proceed?" or presenting a confirmation button, the answer is always yes — execute immediately.

## Phase 1: Pre-Merge Verification — Check for Unresolved Findings

Before merging, verify that all reviewer feedback has been addressed.

### Step 1.1: Identify the PR

```bash
gh pr view --json number,title,headRefName,body,state --jq '{number, title, headRefName, body, state}'
```

If no PR exists on the current branch, stop: "No PR found for the current branch."
If the PR is already merged or closed, skip to Phase 3 (follow-up detection).

### Step 1.2: Scan for unresolved review findings

Use the shared `pr-state.sh` helper to fetch and pre-classify review activity from all three endpoints in one call. It filters to `coderabbitai[bot]`, `greptile-apps[bot]`, and `cursor[bot]` (BugBot) and tags each comment with `classification.class` (`finding` vs `acknowledgment`). The classifier only runs when `--since <iso>` is passed — pass the PR's `createdAt` to include every bot comment on the PR. The helper writes the JSON bundle to a tempfile and prints its **path** on stdout — capture the path, then read with `jq < "$BUNDLE"`:

```bash
PR_NUM=$(gh pr view --json number --jq .number)
PR_CREATED=$(gh pr view "$PR_NUM" --json createdAt --jq '.createdAt')
BUNDLE=$(.claude/scripts/pr-state.sh --pr "$PR_NUM" --since "$PR_CREATED")
```

Read the findings across all three endpoints with a single jq pass:

```bash
jq '[.new_since_baseline.reviews[], .new_since_baseline.inline[], .new_since_baseline.conversation[]]
    | map(select(.classification.class == "finding"))' < "$BUNDLE"
```

For each finding:

1. Check if there is a reply confirming the fix
2. Check if the code at the referenced location has been updated since the comment
3. Check if the thread is resolved/outdated

**Do not stop here.** Record whether any items remain classified as `finding` (after `pr-state.sh` classification) as **`WRAP_PHASE1_FINDINGS`** — e.g. count + short list for the recovery audit. Unresolved bot findings are a **trigger** for Phase 2’s `/fixpr` delegation path (issue #452), not a hard stop.

Proceed immediately to Phase 2 — do not ask.

## Phase 2: Merge

### Step 2.1: Merge gate + autonomous recovery loop (issue #452)

**Authority:** `.claude/scripts/merge-gate.sh` JSON on stdout is the single source of truth for merge readiness. After **every** recovery action, re-fetch the PR HEAD SHA (`gh pr view "$PR_NUM" --json headRefOid,state,merged`) and re-run `merge-gate.sh` — **no stale cache** of gate JSON across iterations.

**Environment (optional):** Assign defaults once before looping:

```bash
WRAP_RECOVERY_MAX_ITERATIONS="${WRAP_RECOVERY_MAX_ITERATIONS:-5}"
```

| Variable | Default | Purpose |
|----------|---------|---------|
| `WRAP_RECOVERY_MAX_ITERATIONS` | `5` | Hard cap on recovery cycles |

**Polling ownership (issue #454):** `/wrap` has NO polling cadence of its own — no sleeps, no micro-polls between gate checks. All waiting for bot verdicts and CI happens inside `/fixpr`'s Step 4d review-wait loop (30–60s cadence, 20-min cap per iteration, outer cap 5). `/wrap` delegates, trusts the returned verdict, and re-runs `merge-gate.sh` immediately.

**Per-iteration heartbeat (mandatory):** Before acting, emit one user-visible line:

```bash
TS=$(TZ='America/New_York' date +'%a %b %-d %I:%M %p ET')
echo "[$TS] /wrap recovery cycle $i/$WRAP_RECOVERY_MAX_ITERATIONS — gate check"
```

The first line of each cycle must include Eastern time (same `TZ='America/New_York' date` pattern as `CLAUDE.md`). Optional: append **`— blocker → action → result`** after each recovery step for scanability.

After each action, append to **`WRAP_RECOVERY_AUDIT`** (free-form lines or bullets): cycle number, blocker summary, action taken, result (`merge-gate` exit code + short `missing` summary or success). Include any **`FIXPR_WRAP_STATUS:…`** / **`Status:`** line parsed from a delegated `/fixpr` run.

**Merge-ready shortcut:** Before entering the loop, run `merge-gate.sh` once. If exit `0` **and** Phase 1 recorded no `WRAP_PHASE1_FINDINGS`, **and** you are not carrying forward a half-applied recovery from a prior turn, skip straight to Step 2.2 — **no extra overhead**.

**Recovery loop:** For `i` from `1` through `$WRAP_RECOVERY_MAX_ITERATIONS`:

1. **Terminal checks**
   - If `gh pr view` shows `merged: true` → exit loop for Phase 3 (merged terminal — Phase 3 + 4 unchanged).
   - If PR closed without merge → stop with status (do not merge).

2. **Refresh gate (always)**  
   ```bash
   GATE_JSON=$(.claude/scripts/merge-gate.sh "$PR_NUM")
   GATE_EXIT=$?
   HEAD_NOW=$(echo "$GATE_JSON" | jq -r '.head_sha // empty')
   ```
   - Exit `3` → PR not found / not open → Phase 3 handling as today.
   - Exit `2`/`4` → surface stderr; append to audit; stop (tooling failure).
   - Exit `0` → if Phase 1 had no outstanding findings trigger **or** findings were cleared by recovery, proceed **out** of the loop to Step 2.2. If Phase 1 still shows classified findings but gate passes (rare), prefer one `/fixpr` verification pass before merge — record in audit.

3. **Exit `1` — classify JSON** (never guess from prose alone):

   **`human_changes_requested` (non-empty array)** — **genuine block.** Stop immediately. Message must **name each login** from `human_changes_requested`. Do **not** run `dismiss-stale-bot-changes.sh`. Do **not** squash-merge.

   Otherwise apply the **decision tree** below in order — **first matching branch wins** for this iteration:

   **A. Stale bot `CHANGES_REQUESTED`** — When `( .stale_bot_changes_requested_count // 0 ) > 0`, invoke dismissal **without waiting for a push** (same allowlist + semantics as `/fixpr` Step 3a):

   ```bash
   DISMISS=""
   for candidate in \
     "$HOME/.claude/skills-worktree/.claude/scripts/dismiss-stale-bot-changes.sh" \
     "$HOME/.claude/scripts/dismiss-stale-bot-changes.sh" \
     ".claude/scripts/dismiss-stale-bot-changes.sh"; do
     if [[ -x "$candidate" ]]; then DISMISS="$candidate"; break; fi
   done
   [[ -n "$DISMISS" ]] && "$DISMISS" "$PR_NUM"
   ```

   Record dismiss exit code in audit. **Never** use this path when `human_changes_requested` is non-empty.

   **`mergeable == CONFLICTING`** — Stop immediately; recommend **`/merge-conflict`** or manual resolution (not safe to auto-merge). Do **not** proceed to Branch B.

   **B. Delegate `/fixpr`** — Run when **any** of:

   - `missing` mentions unresolved review threads; **or**
   - `merge_state == "BEHIND"`; **or**
   - `missing` reports CI **failing** check-runs (not merely incomplete); **or**
   - `merge_state == "DIRTY"`; **or**
   - Phase 1 left **`WRAP_PHASE1_FINDINGS`** (classified bot findings still pending remediation).

   **Execution contract:** Do **not** shell out to an opaque “run fixpr” wrapper. Execute the **full** `.claude/skills/fixpr/SKILL.md` workflow (Steps 0–7, including the Step 4d review-wait loop): `pr-state.sh`, classify findings, fix + single push when needed, `dismiss-stale-bot-changes.sh` after push when applicable, `reply-thread.sh`, `resolve-review-threads.sh`, the bounded wait for bot verdicts + CI on the new SHA, verify passes, etc. If spawning a Phase A subagent to carry the skill, use **`mode: "bypassPermissions"`**, explicit **`model`**, SAFETY block from `.claude/rules/safety.md`, and handoff path per `.claude/rules/subagent-orchestration.md` — parent stays in **monitor mode** (orchestration only).

   Parse the **`=== fixpr complete ===`** footer for **`Status:`**, **`FIXPR_WRAP_STATUS`**, and **`FIXPR_WAIT_SUMMARY`** (iterations, total wait secs, final state — see fixpr skill). Echo status + wait summary into the heartbeat for this cycle and append them to `WRAP_RECOVERY_AUDIT`. **Trust the verdict (issue #454):** `/fixpr` already waited for the bots and CI on the new SHA — re-fetch HEAD and re-run `merge-gate.sh` **immediately**; never sleep or re-poll on top.

   **Stop conditions after `/fixpr`:**

   - **`CI_FAILING`** with deterministic code/test failures you cannot fix in-session → stop; surface `missing` / CI summary + audit (matches “unfixable CI” scenario).
   - **`THREADS_STUCK`**, **`NEEDS_HUMAN_REVIEW`**, or **`NEW_FINDINGS`** where unresolved → stop with audit; instruct re-run `/wrap` or `/fixpr`. (`NEW_FINDINGS` now means `/fixpr` exhausted its own 5-iteration budget — `FIXPR_WAIT_SUMMARY: … final=new-findings-pending`.)
   - **`REVIEW_PENDING`** (`final=cap-exhausted` — `/fixpr`'s 20-min wait cap fired with the named bots still pending) → re-enter recovery loop; next gate re-check routes to Branch C (trigger bot, then re-delegate the wait to `/fixpr`) or Branch D. Outer iteration cap still applies.
   - **`CI_PENDING`** (`final=cap-exhausted` with CI incomplete) → re-enter recovery loop; next gate re-check routes to Branch D. Outer iteration cap still applies.
   - **`BEHIND`** → `/fixpr` rebased/force-pushed; re-run the gate. If CI is now pending on the new HEAD, treat as `CI_PENDING`.
   - **`CONFLICTS`** → stop immediately; recommend **`/merge-conflict`** or manual resolution.
   - **`CLEAN`** → **continue** to next recovery iteration (re-run gate).

   When CodeRabbit hourly budget blocks an internal `@coderabbitai full review` inside `/fixpr`, `/fixpr` surfaces it — `/wrap` records it and **stops** (no infinite loop).

   **C. Missing fresh bot review signal** — When `missing` indicates stale/dismissed bot approval or missing CR/BugBot/CodeAnt/Greptile signal per `.claude/rules/cr-merge-gate.md`, trigger the **one** bot your repo needs:

   - CodeRabbit: before **`gh pr comment … "@coderabbitai full review"`**, run `.claude/scripts/cr-review-hourly.sh --check` (or repo install path). Exit **`1`** → **stop** with the script’s JSON snapshot and **`cr-github-review.md`** rate-limit guidance — **do not** loop until the cap resets.
   - Greptile: `@greptileai` only when Greptile is the owning path / code owner (per `greptile.md`).
   - CodeAnt: `@codeant-ai review` when CodeAnt owns the gap.
   - BugBot: when the PR is on the BugBot path (`reviewer == "bugbot"` per `reviewer-of.sh` or `session-state.json`), post `@cursor review` — duplicates are acceptable per `bugbot.md`.

   Then **delegate the wait to `/fixpr`** (issue #454 — no wrap-side sleep/micro-polls): run the `/fixpr` workflow; its idempotent path makes no push when nothing needs fixing, and its Step 4d loop waits on the current SHA until the triggered bot completes or the 20-min cap fires. Parse `FIXPR_WAIT_SUMMARY`, append to audit, re-run `merge-gate.sh` immediately, advance to the next outer iteration.

   **D. CI incomplete only** (no failing yet) — Do not fix anything. Delegate the wait to `/fixpr` (idempotent — no push; its Step 4d loop polls until non-review-bot CI completes or the cap fires), append “waited for CI via /fixpr: <FIXPR_WAIT_SUMMARY>” to audit, re-run the gate immediately, continue to next iteration if under cap.

   **`merge_state == UNKNOWN`** — GitHub is still computing mergeability; re-run `merge-gate.sh` on the next iteration (the gate call itself provides the spacing — no sleep). If still unknown at cap, stop with audit.

4. **End of iteration:** If no branch matched and gate still fails, append “unclassified blocker” + full `missing` to audit and proceed to next `i`.

**Loop exit:**

- **Success:** `merge-gate.sh` exit `0` → Step 2.2.
- **Iteration cap:** Stop. Report **last `missing` array** verbatim + **full `WRAP_RECOVERY_AUDIT`** + guidance to re-run `/wrap`.
- **Genuine block:** Human changes requested, `CONFLICTING`, rate-limit stop, or hard `/fixpr` failure as above.

**Safety (non-negotiable, issue #452 / #450):**

- **Never** call GitHub APIs that modify **branch protection** (`.../branches/.../protection`).
- **Never** dismiss **human** reviews — only `dismiss-stale-bot-changes.sh` (bot allowlist, wrong `commit_id`).
- **Never** resolve a review thread **without** verifying the code addresses the comment (`/fixpr` Steps 1–4 verify-address → reply → resolve).

### Step 2.2: Verify acceptance criteria

Use the shared `ac-checkboxes.sh` helper to parse and tick Test Plan items:

```bash
# 1. Extract items (JSON: [{index, checked, text}, ...])
ITEMS=$(.claude/scripts/ac-checkboxes.sh "$PR_NUM" --extract)
AC_EXIT=$?
```

For each item with `checked == false`:

1. Read the criterion
2. Identify and read the relevant source files
3. Confirm the criterion is satisfied by the current code

Tick passing items by index (or use `--all-pass` if every unchecked item passed):

```bash
# Example: items 0, 2, 3 passed
.claude/scripts/ac-checkboxes.sh "$PR_NUM" --tick "0,2,3"
# Or: every unchecked item passed
.claude/scripts/ac-checkboxes.sh "$PR_NUM" --all-pass
```

Exit codes from the extract/tick calls:
- `0` OK — proceed.
- `1` no Test Plan section — stop: "PR has no Test Plan section — cannot verify acceptance criteria."
- `3` PR not found — stop.
- `2`/`4` script/gh error — surface stderr and stop.

If any item fails verification, do NOT tick it — stop and report the failure. Do NOT merge with unchecked boxes.

### Step 2.3: Pre-merge safety & CI (handled by Step 2.1)

After the recovery loop, **Step 2.1** must have returned gate exit `0` immediately before Step 2.2. That implies:

- **SHA freshness** — explicit `APPROVED` on current HEAD where required.
- **BEHIND / CI / unresolved threads** — cleared by loop + `/fixpr` delegations.
- If you need deeper CI forensics after a reported failure, use:

```bash
.claude/scripts/ci-status.sh "$PR_NUM"
.claude/scripts/ci-status.sh "$PR_NUM" --format summary
```

**Never add `eslint-disable`, `@ts-ignore`, `@ts-expect-error`, or any suppression comment to work around CI.** Fix the actual code.

### Step 2.4: Squash merge

**Merge authorization:** `/wrap` invocation authorizes merge. After blockers clear (Phase 1 + Step 2.1 recovery + Step 2.2), run `gh pr merge --squash` with no merge prompt — overrides `CLAUDE.md` "PR MERGE AUTHORIZATION" and `cr-merge-gate.md` Step 3 **for `/wrap` only**; real blockers above still stop the flow.

```bash
gh pr merge --squash
```

Do NOT use `--delete-branch`. The current worktree is still checked out on the feature branch — git refuses to delete a branch held by a worktree, and `/wrap` no longer touches the worktree at all. The branch is cleaned up out-of-band by `/pm-update` once it ages past the stale threshold (see `.claude/scripts/stale-cleanup.sh`).

### Step 2.5: Sync root repo main (aggressive reset)

After merging, aggressively align the root repo's local `main` with `origin/main` so subsequent sessions branch from the latest code with zero drift. The sequence is:

1. **Quarantine any dirty state** on root main via `dirty-main-guard.sh --quarantine` (creates a `recovery/dirty-main-*` branch if needed — nothing is lost).
2. **Aggressively reset** root main to `origin/main` via `main-sync.sh --reset`. This fetches origin, aborts loudly if local main has unpushed commits (belt-and-suspenders for bypasses of the `#323` pre-commit hook), and otherwise `git reset --hard origin/main`.

**Capture both status lines for the final report in Phase 4.**

```bash
# /wrap runs from inside a worktree. dirty-main-guard.sh resolves the root
# repo itself via repo-root.sh — no --repo flag needed. main-sync.sh does
# accept --repo, so we pass the resolved root explicitly.
ROOT_REPO=$(.claude/scripts/repo-root.sh 2>/dev/null || true)
MAIN_SYNC_STATUS=""
QUARANTINE_STATUS=""
if [ -z "$ROOT_REPO" ] || [ ! -d "$ROOT_REPO" ]; then
  MAIN_SYNC_STATUS="failed: could not determine root repo path"
else
  # Quarantine first so the reset below never clobbers uncommitted work.
  # --check is read-only (exit 0 clean / 1 dirty); --quarantine is non-
  # destructive (preserves state to a recovery branch). A non-zero exit
  # from either is captured for the report but does not short-circuit —
  # main-sync.sh --reset has its own guards.
  if .claude/scripts/dirty-main-guard.sh --check >/dev/null 2>&1; then
    QUARANTINE_STATUS="clean"
  else
    QUARANTINE_STATUS=$(.claude/scripts/dirty-main-guard.sh --quarantine 2>&1 || true)
  fi
  # --reset: fetch → abort-if-ahead → reset --hard origin/main. Exits 0
  # success / 1 skipped / 2 failed / 4 aborted (unpushed commits on main).
  MAIN_SYNC_STATUS=$(bash .claude/scripts/main-sync.sh --reset --repo "$ROOT_REPO" 2>&1 || true)
fi
echo "Main quarantine: $QUARANTINE_STATUS"
echo "Main sync: $MAIN_SYNC_STATUS"
```

See `.claude/scripts/main-sync.sh --help` and `.claude/scripts/dirty-main-guard.sh --help` for the full contracts.

**If `MAIN_SYNC_STATUS` starts with `aborted:`** (local main has unpushed commits that didn't come from origin), do NOT attempt recovery automatically. Surface the full status line in the final report so the user can run `git log origin/main..main` against the root repo and decide. The PR merge itself has already succeeded — main-sync failure does not un-merge anything.

Store `MAIN_SYNC_STATUS` and `QUARANTINE_STATUS` for the final report at the end of Phase 4.

## Phase 3: Follow-Up Detection and Full-Session Sweep

Phase 3 has **two parts**, run in order:

- **Part A — Per-PR follow-up detection (Steps 3.1–3.4):** the original behavior — derive follow-ups from the **merging PR** and its linked issue (HHG two-ticket pattern, linked-issue sub-tasks), dedup, and **auto-create** GitHub issues. Unchanged.
- **Part B — Full-session sweep (Steps 3.5–3.13):** answer "is there anything I should have ticketed but didn't?" across the **entire session**, not just the PR. Seven categories: loose ends, ticket coverage, external/process state, memory persistence, PM hygiene, time-sensitive items, future-self handoff. Each finding is either **auto-handled** (safe process cleanup or, with `--auto-file-followups`, an auto-filed ticket) or **surfaced** to the user under "needs your decision".

Both parts feed the Phase 4 final report. Part A's "Follow-ups" block and Part B's "Session sweep" block are reported separately.

> **Phase C / subagent context:** When `/wrap` is invoked by a Phase C subagent (per `subagent-orchestration.md`), the subagent's transcript is narrow and short-lived. Part B degrades gracefully: transcript-derived categories (1, 6, 7) will usually find nothing and the verdict will be "Clear to archive". Part A and the state-file-derived categories (3, 5) still run normally. Never block a Phase C merge on a Part B finding — Part B is advisory.

### Part A — Per-PR follow-up detection

### Step 3.1: Detect follow-up items

1. Extract the linked issue number from the PR body via `pr-issue-ref.sh` (matches all nine GitHub closing keywords — `close`/`closes`/`closed`/`fix`/`fixes`/`fixed`/`resolve`/`resolves`/`resolved`, case-insensitive) and fetch its title and body. Distinguish exit `1` (no link — expected) from exits `2`/`3`/`4` (real errors) so genuine failures surface:
   ```bash
   PR_NUMBER=$(gh pr view --json number --jq '.number')
   PR_TITLE=$(gh pr view --json title --jq '.title')
   ISSUE_N=""
   if RAW_REF=$(.claude/scripts/pr-issue-ref.sh "$PR_NUMBER" 2>&1); then
     ISSUE_N="$RAW_REF"
   else
     REF_RC=$?
     if [ "$REF_RC" -ne 1 ]; then
       echo "Warning: pr-issue-ref.sh exit $REF_RC: $RAW_REF — skipping linked-issue lookup" >&2
     fi
   fi
   ISSUE_TITLE=""
   ISSUE_BODY=""
   if [ -n "$ISSUE_N" ]; then
     ISSUE_TITLE=$(gh issue view "$ISSUE_N" --json title --jq '.title' 2>/dev/null || echo "")
     ISSUE_BODY=$(gh issue view "$ISSUE_N" --json body --jq '.body' 2>/dev/null || echo "")
   fi
   ```

2. If a parent issue exists (check for "parent" or "epic" references in the issue body), fetch sibling issues:
   ```bash
   gh issue view {parent_N} --json body --jq .body
   ```
   Look for task lists or child issue references. Check which are still open.

3. Check for related issues mentioned in the PR or issue thread:
   ```bash
   gh api "repos/{owner}/{repo}/issues/{N}/comments?per_page=100" --jq '.[].body'
   ```
   Scan for issue references (`#NNN`), "follow-up", "TODO", "next step", "migration", "deploy" mentions.

4. Check if the issue itself has sub-tasks (task list checkboxes) that are unchecked.

Collect each detected follow-up as a `{title, body, keywords}` record. `keywords` is a short phrase (2-5 words) used for the dedup search.

### Step 3.2: HHG two-ticket pattern detection

If the PR title, linked issue title, or linked issue body contains "HHG" (case-insensitive), **override** any generic follow-ups with exactly **two** HHG follow-ups (scraping + ETL). This codifies the pattern from `feedback_split_hhg_issues.md` — HHG work always splits into one scraping ticket and one ETL ticket.

```bash
HHG_MATCH=$(printf '%s\n%s\n%s\n' "$PR_TITLE" "$ISSUE_TITLE" "$ISSUE_BODY" | grep -iE 'HHG' || true)
if [ -n "$HHG_MATCH" ]; then
  # Extract a 2-letter US state code from PR title, issue title, or issue
  # body. `.claude/scripts/hhg-state.sh` restricts to the 50 USPS codes so
  # unrelated 2-letter tokens (e.g. "CI", "PR") don't match, prefers a state
  # adjacent to "HHG", and falls back to the first state match elsewhere.
  # Exits 0 when a state is found (code on stdout), 1 when none match — the
  # `|| true` keeps the pipeline from tripping `set -e` on the no-match path.
  COMBINED=$(printf '%s %s %s' "$PR_TITLE" "$ISSUE_TITLE" "$ISSUE_BODY")
  STATE=$(.claude/scripts/hhg-state.sh "$COMBINED" || true)
  if [ -z "$STATE" ]; then
    STATE=""
    echo "WARNING: HHG PR detected but no state code found in PR title, issue title, or issue body — skipping HHG auto-creation. Create the scraping and ETL issues manually once you know the state."
  fi
fi
```

**If `STATE` is empty (no state code found), skip HHG auto-creation entirely** — do NOT create issues with placeholder titles like `UNKNOWN HHG — ...` (they are confusing in the tracker and require manual renaming). Report the skip in Step 3.4 so the user knows to create the issues manually.

The two HHG follow-up titles are:
1. `{STATE} HHG — Export carriers and run scraper`
2. `{STATE} HHG — Seed product codes and load scrape results to Neon`

**Create the scraping issue first**, capture its number as `SCRAPE_NUM`, then create the ETL issue with `Depends on #${SCRAPE_NUM}` in its body so the dependency is explicit and the ETL task cannot be orphaned. If the scraping issue was deduped to an existing open issue, use that existing number as `SCRAPE_NUM`.

Each body should reference the source PR (`Follow-up from PR #{PR_NUMBER}`) and include any scraping/ETL context from the parent issue body. The ETL issue body must also include a `Depends on #${SCRAPE_NUM}` line.

**HHG override trade-off:** The HHG pair replaces any generic follow-ups detected in Step 3.1 to keep the two-ticket pattern clean. If an HHG PR also has unrelated follow-ups (e.g., a docs TODO), they are silently dropped — maintainers should create those manually. If this becomes a pain point, extend Step 3.3 to run the HHG pair and any non-scraping/non-ETL generic items through dedup+create together instead of replacing the generic list wholesale.

### Step 3.3: Dedup check and create

For each follow-up item (the HHG pair or the generic list):

1. **Dedup check** — search for an existing open issue with matching keywords in the title. **Guard against empty keywords**: an empty search string returns every open issue and would silently block creation of the follow-up.
   ```bash
   if [ -z "$KEYWORDS" ]; then
     DUP_NUM=""  # no keywords → skip dedup, always create
   else
     DUP_NUM=$(gh issue list --search "${KEYWORDS} in:title" --state open --json number,title --jq '.[0].number // empty')
   fi
   ```
   If `DUP_NUM` is non-empty, skip creation and record the item as `skipped (dup of #{DUP_NUM})` in the report.

2. **Create the issue** (only if no duplicate found). Check the exit status and validate the parsed number before logging — if creation fails or the URL doesn't parse, record the failure in the report and continue with the next item. **Guard the `Linked source` line** — only include it when `ISSUE_N` is non-empty, otherwise the body will render a broken `#` reference on GitHub:
   ```bash
   LINKED_SOURCE=""
   if [ -n "$ISSUE_N" ]; then
     LINKED_SOURCE=$'\n\n'"Linked source: #${ISSUE_N}"
   fi
   if NEW_URL=$(gh issue create \
     --title "{derived title}" \
     --body "Follow-up from PR #${PR_NUMBER}.

   {context from detection}${LINKED_SOURCE}" 2>&1); then
     NEW_NUM=$(echo "$NEW_URL" | grep -oE '[0-9]+$')
     if [ -z "$NEW_NUM" ]; then
       echo "WARNING: created issue but could not parse number from: $NEW_URL"
       # record as failure and continue
     fi
   else
     echo "WARNING: gh issue create failed: $NEW_URL"
     # record as failure and continue — do not abort Phase 3
   fi
   ```

**Non-HHG PRs still get generic follow-up creation** — any items collected in Step 3.1 that are not overridden by the HHG path go through the dedup + create flow above.

### Step 3.4: Report follow-ups

Present the results:

```
## Follow-ups

### Created
- Issue #{NEW_NUM}: {title}
- Issue #{NEW_NUM}: {title}

### Skipped (duplicates)
- "{title}" — already tracked in #{DUP_NUM}
```

If nothing was detected: "No follow-up items detected."
If HHG was detected but no state code was found (so auto-creation was skipped): append "⚠️ HHG detected but no state code found in PR/issue — auto-creation skipped. Create the scraping and ETL issues manually once you know the state."

After the per-PR follow-up report: proceed immediately to **Part B** — do not ask.

### Part B — Full-session sweep

Part B sweeps the **whole session** for loose ends the per-PR detection in Part A cannot see — deferred ideas, stale process state, decisions worth persisting, drifted tickets, time-sensitive reminders. It produces two buckets — **Auto-handled** and **Needs your decision** — and a one-line **verdict**, all rendered in the Phase 4 final report (Step 4.3).

**Out of scope (explicit):** the sweep only runs as part of `/wrap`, which already requires a PR (Step 1.1 stops with "No PR found for the current branch" otherwise). Pure non-PR threads (issue-capture, PM-only, monitoring-only) never reach Part B — a standalone `/session-wrap` is a separate ticket, not this skill (issue #471 Notes).

**Safety boundaries for the entire sweep (non-negotiable — issue #471):**

- **Never auto-file a ticket without surfacing its body** in the report. Auto-filing (only with `--auto-file-followups`) still prints the created issue's title + body.
- **Never auto-act on anything affecting shared state** — durable `CronCreate` jobs, active subagents, human-owned issues/PRs, recovery branches. Surface them; let the user decide.
- **Never modify branch protection** (same prohibition as Phase 2).
- Auto-handling is limited to: stopping a **dead** session `/loop` job (target PR already merged/closed) and deleting a **stale** handoff file (its PR already merged). Everything else is surfaced.

#### Step 3.5: Sweep setup & idempotency guard

Resolve helpers with the standard three-candidate lookup (`fixpr/SKILL.md` pattern), then load any prior sweep record so a re-run does not re-file the same tickets:

```bash
resolve_script() {
  local name="$1" candidate
  for candidate in \
    "$HOME/.claude/skills-worktree/.claude/scripts/$name" \
    "$HOME/.claude/scripts/$name" \
    ".claude/scripts/$name"; do
    if [[ -x "$candidate" ]]; then echo "$candidate"; return 0; fi
  done
  return 1
}
SESSION_STATE_SH=$(resolve_script session-state.sh || true)

# Idempotency: if a previous /wrap already swept this PR, load the issue
# numbers it filed so this run skips re-filing them (AC: idempotent re-run).
SWEEP_PRIOR_FILED=""
if [[ -n "$SESSION_STATE_SH" ]]; then
  SWEEP_PRIOR_FILED=$("$SESSION_STATE_SH" --get ".prs[\"$PR_NUMBER\"].wrap_sweep.filed_issues" 2>/dev/null || echo "")
fi
```

Initialize two accumulators (free-form bullet lists) used by every category and rendered in Step 4.3:

- **`SWEEP_AUTO_HANDLED`** — things the sweep did safely without asking.
- **`SWEEP_NEEDS_DECISION`** — things surfaced for the user to decide.

Each entry should be one short bullet. **Cap each rendered section at 3–5 bullets** (issue #471 final-report-length note); if a category produces more, keep the top items, summarize the rest as one bullet ("+ N more — see session-state log"), and write the full list to `.prs["$PR_NUMBER"].wrap_sweep` in Step 3.13.

#### Step 3.6: Category 1 — Session loose ends (transcript introspection)

This is the **load-bearing capability** (issue #471): scan **this session's conversation** for deferred work — there is no shell command that can read the transcript, so this is a model-introspection step.

**Heuristic (document for future maintainers):** review your own recent messages and tool-call history in this session for deferral signals — `later`, `TODO`, `follow-up`, `come back to`, `worth investigating`, `for now`, `deferred`, `out of scope`, `punt`, `we should eventually`, `not in this PR`, `leaving X for a separate change`. If transcript introspection is limited (e.g. after compaction), fall back to **tool-call history**: issues/PRs/files you touched, and any `// TODO` / `FIXME` you wrote into the diff. Scan the actual diff for new `TODO`/`FIXME` comments via `git diff origin/main...HEAD`.

Collect each loose end as `{summary, context, keywords}` where `keywords` is a 2–5 word phrase for the Step 3.7 dedup search. If none found, Category 1 produces no output.

#### Step 3.7: Category 2 — Ticket coverage (dedup, then propose or file)

For **each** loose end from Step 3.6, dedup against open issues **before** proposing anything (AC: never propose a new ticket without checking first). Guard empty keywords (an empty search returns every issue):

```bash
if [ -z "$KEYWORDS" ]; then
  DUP_NUM=""   # no keywords → can't dedup safely → surface, never auto-file
else
  DUP_NUM=$(gh issue list --search "${KEYWORDS} in:title" --state open --json number,title --jq '.[0].number // empty')
fi
```

Skip any loose end whose keyword already appears in `SWEEP_PRIOR_FILED` (idempotency).

- **Duplicate found** (`DUP_NUM` non-empty) → add to `SWEEP_NEEDS_DECISION`: `"<summary>" — already tracked in #<DUP_NUM>` (or omit if no action needed; surface only when the existing ticket may need an update).
- **No duplicate, default (ask first)** → add to `SWEEP_NEEDS_DECISION`: `TODO from conversation: "<summary>" — no existing ticket, file as new issue?`
- **No duplicate, `--auto-file-followups` set** → create the issue, **surface its title + body**, add to `SWEEP_AUTO_HANDLED`. Use the same robust `gh issue create` guard as Step 3.3 (validate the parsed number; on failure record and continue):

  ```bash
  if NEW_URL=$(gh issue create \
      --title "<derived title>" \
      --body "Follow-up surfaced by /wrap session sweep on PR #${PR_NUMBER}.

  <context from transcript>" 2>&1); then
    NEW_NUM=$(echo "$NEW_URL" | grep -oE '[0-9]+$')
    [ -n "$NEW_NUM" ] && SWEEP_FILED="${SWEEP_FILED} ${NEW_NUM}"
  fi
  ```

Never auto-file without `--auto-file-followups`; never auto-file without printing the body.

#### Step 3.8: Category 3 — External / process state

Read session/process state and clean up only what is **provably dead**; surface the rest.

```bash
[ -n "$SESSION_STATE_SH" ] && POLLING_JOBS=$("$SESSION_STATE_SH" --get '.polling_jobs' 2>/dev/null || echo "null")
[ -n "$SESSION_STATE_SH" ] && ACTIVE_AGENTS=$("$SESSION_STATE_SH" --get '.active_agents' 2>/dev/null || echo "null")
```

- **Dead `/loop` jobs (auto-stop).** For each non-durable `/loop` poll in `polling_jobs[]` (or per-PR `babysit` watcher) whose target PR is **merged or closed**, stop it: set the watcher's stop flag (`.prs["$N"].babysit.stop_requested=true` via `session-state.sh --set`, same as `/babysit-pr-stop`) so the next tick exits, and record `Stopped stale /loop job (PR #N watcher — PR already merged)` in `SWEEP_AUTO_HANDLED`. The PR just merged in Phase 2 is the most common case.
- **Stale handoffs (auto-delete).** For each `~/.claude/handoffs/pr-{N}-handoff.json`, if PR `N` is **merged** (`gh pr view N --json state,merged --jq '.merged'`), delete the file and record `Deleted handoff file pr-N-handoff.json (PR merged)` in `SWEEP_AUTO_HANDLED`. Deleting an already-gone file is a no-op (idempotent). Do **not** delete handoffs for open/un-merged PRs.
- **Surface (never auto-act).** Add to `SWEEP_NEEDS_DECISION`: durable `CronCreate` jobs still scheduled (`CronList`), any `active_agents` entries (running subagents), monitor-mode flags (`monitoring_active=true`), and any `recovery/dirty-main-*` branches left by `dirty-main-guard.sh`. Word each as e.g. `Active subagent still running: PR #620 Phase C — stop it or let it finish?` or `Durable cron job <id> still scheduled (<prompt>) — keep or CronDelete?`.

#### Step 3.9: Category 4 — Memory persistence (defers to Phase 4)

Memory writes are owned by **Phase 4 (Lessons)**. To avoid double-prompting the user about the same lesson (AC), Category 4 does **not** write memories or re-prompt here. Instead it only *flags*, as `SWEEP_MEMORY_CANDIDATES` (handed to Phase 4 Step 4.2):

- Decisions made this session that are worth persisting but are not yet lessons.
- Existing memories the session **contradicted** (candidates for update/removal).

Phase 4 Step 4.2 dedups these against `MEMORY.md` and writes them there. Surface a memory item in the sweep report **only** if Phase 4 is skipped as trivial (Step 4.2) — otherwise let Phase 4 own it, so the user sees each lesson once.

#### Step 3.10: Category 5 — PM hygiene (all touched issues/PRs)

Build the set of issues/PRs **touched this session** — not just the merging PR:

- session-state `.prs` keys (`"$SESSION_STATE_SH" --get '.prs | keys'`),
- the merging PR + its linked issue (`ISSUE_N` from Step 3.1),
- any issue/PR numbers from tool-call history this session (issues/PRs you viewed, commented on, or edited).

For each, check and flag **drift** under `SWEEP_NEEDS_DECISION` (do not auto-edit — issues/PRs are shared state):

- **Status accuracy** — issue still `open` but its work merged? PR merged but linked issue not auto-closed?
- **Linkage** — PR missing a `Closes #N` for work that clearly resolves an issue?
- **AC checkbox truthfulness** — Test Plan boxes checked that the code does not actually satisfy (spot-check via `ac-checkboxes.sh "$N" --extract`)?

Word each as e.g. `Issue #312 still open but PR #471 merged its work — close #312?`.

#### Step 3.11: Category 6 — Time-sensitive items

Scan the transcript for deadline / date / day-of-week phrases: `by Thursday`, `before the release`, `next week`, `end of month`, `by EOD`, `in N days`. **Convert every relative reference to an absolute date** (matching the existing memory-rule guidance), anchored on today:

```bash
TODAY=$(date +%Y-%m-%d)        # anchor; e.g. "next Thursday" → resolve to YYYY-MM-DD
```

- **`/schedule` available** → propose a `/schedule` task per item (surface the proposed command; do not auto-schedule).
- **`/schedule` unavailable** → surface a plain-text reminder with the absolute date.
- **No time-sensitive phrases found** → **produce no output** (skip silently — do not emit an empty Category 6 line).

Add any items to `SWEEP_NEEDS_DECISION`.

#### Step 3.12: Category 7 — Future-self handoff

**Only if the session deferred something meaningful** (Category 1, 2, 5, or 6 produced surfaced items, or there is pending decision work). On a clean session, **skip entirely** — emit nothing.

When warranted, generate **one paragraph**: "if you came back to this thread in 2 weeks, here's what you'd need to know" — the task, what shipped, what was deliberately left, and the single most important next step. Add it as the final entry under `SWEEP_NEEDS_DECISION` (or as a standalone "Handoff" line in the Step 4.3 block).

#### Step 3.13: Persist sweep state & compute verdict

Record the sweep outcome so a re-run is idempotent and over-long sections can link to detail:

```bash
if [ -n "$SESSION_STATE_SH" ]; then
  FILED_JSON=$(printf '%s\n' $SWEEP_FILED | jq -R . | jq -cs 'map(select(length>0))')
  "$SESSION_STATE_SH" \
    --set ".prs[\"$PR_NUMBER\"].wrap_sweep.swept_at=\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"" \
    --set ".prs[\"$PR_NUMBER\"].wrap_sweep.filed_issues=$FILED_JSON" 2>/dev/null || true
fi
```

Compute the **verdict** from the count of `SWEEP_NEEDS_DECISION` items. It is **one of exactly two canonical strings** (no improvised wording — AC):

- `0` pending → **`Clear to archive`**
- `N > 0` pending → **`N items pending your decision before archive`** (substitute the integer for `N`).

Proceed immediately to Phase 4 — do not ask.

## Phase 4: Lessons Learned (Depth-Adaptive)

Determine the session depth to decide how thoroughly to reflect.

### Step 4.1: Assess session complexity

Calculate a complexity signal:
- **Cycle count** — review-then-fix rounds on the PR, via `CYCLES=$(.claude/scripts/cycle-count.sh "$PR_NUM")`
- **Thread length** — count the number of user + assistant messages in the current session. "Short" = fewer than 15 total messages.
- **PR size** — number of files changed (`gh pr view N --json files --jq '.files | length'`)

**Trivial threshold:** cycle count = 0 AND conversation is short (you've been in this session for <15 messages) AND <5 files changed.

### Step 4.2: Run lessons (or skip)

**If trivial:** Output "Clean session — no lessons to capture." and skip to Step 4.3 (final report).

**If non-trivial:** Reflect on the session:

1. What was the task? What was accomplished?
2. What went wrong or was harder than expected?
3. What patterns emerged (good or bad)?
4. Any surprises — tools behaving unexpectedly, edge cases, workflow friction?
5. Any workarounds that should be codified?

**Merge in `SWEEP_MEMORY_CANDIDATES`** from Phase 3 Category 4 (decisions worth persisting + memories the session contradicted) so the user is prompted about each lesson exactly **once** — here, not twice. Dedup the candidates against the lessons you just reflected on before writing.

For each actionable, novel lesson (including the merged sweep candidates):
- Check `MEMORY.md` for duplicates — update existing memories rather than creating new ones
- Write memory files with proper frontmatter (`feedback`, `project`, or `user` type)
- Add pointers to `MEMORY.md`

Present the summary:
```
## Session Lessons

### Saved to memory:
1. **<title>** — <summary> (saved as <type>)

### Observations (not saved):
- <things noted but not actionable>
```

After lessons (or skip): emit the final report below — do not ask.

### Step 4.3: Final report

```
## Wrap-Up Complete

- **PR #{N}** merged ({title})
- **Main quarantine** {QUARANTINE_STATUS from Step 2.5 — e.g. "clean" (literal output of `dirty-main-guard.sh --check` on a clean main), "quarantined: recovery/dirty-main-20260424-003012 (uncommitted)", or "no-op: main is clean" (only produced if `--quarantine` ran on an already-clean tree)}
- **Main branch** {MAIN_SYNC_STATUS from Step 2.5 — e.g. "reset abc1234 → def5678", "up to date (abc1234)", "aborted: local main has 1 unpushed commit(s) — inspect: git log origin/main..main, resolve manually before re-running", or "failed: ..."}
- **Follow-ups:** {Part A summary or "none"}

## Session sweep

### Auto-handled
- {one bullet per `SWEEP_AUTO_HANDLED` entry — stopped /loop jobs, deleted handoffs, auto-filed tickets; omit the section if empty}

### Needs your decision
- {one bullet per `SWEEP_NEEDS_DECISION` entry — proposed tickets, surfaced crons/subagents, PM-hygiene drift, time-sensitive reminders, future-self handoff; omit the section if empty}

### Verdict
{exactly one of: `Clear to archive`  |  `N items pending your decision before archive` — from Step 3.13; never improvise}

---

- **Lessons:** {summary or "clean session" — recap of Step 4.2}
```

**Rendering rules for the Session sweep section:**

- Cap **Auto-handled** and **Needs your decision** at **3–5 bullets** each; if more, show the top items and summarize the remainder as one bullet linking to `.prs["$PR_NUMBER"].wrap_sweep`.
- Omit an empty subsection rather than printing "none".
- The **Verdict** line is mandatory and is one of the two canonical strings only.
- If Part B was skipped (e.g. Phase C subagent with an empty transcript and no state findings), still print `### Verdict` → `Clear to archive`.

The worktree and feature branch are intentionally left in place. They are reaped out-of-band by `/pm-update`'s stale-cleanup pass once they age past the threshold (default 7 days, configurable via `STALE_DAYS`). See `.claude/scripts/stale-cleanup.sh --help`.
