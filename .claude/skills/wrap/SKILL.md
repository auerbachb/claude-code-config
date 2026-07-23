---
name: wrap
description: End-of-session command — verify no unresolved findings, squash merge, sync main, detect per-PR follow-ups, run a full-session loose-ends sweep, and extract lessons. Terse by default — output is a concise merged + follow-ups summary; pass `--verbose` for the full per-phase report. Accepts an optional PR reference (`/wrap <URL>`, `/wrap #N`, `/wrap N`); with no argument it infers the PR from the current branch, then thread context, then session-state.
argument-hint: "[URL | #N | N] [--verbose]"
---

Wrap up the current PR and session. This is the "we're done here" command that handles final verification through merge, root-main sync, follow-up detection, a full-session sweep for loose ends, and lessons.

`/wrap` accepts an **optional** PR reference as its argument — a full URL, `#N`, `owner/repo#N`, or a bare number `N`. When invoked with no argument it resolves the target PR through the inference cascade in Step 1.1 (current branch → thread context → session-state). An explicit argument bypasses all inference.

`/wrap` does **not** delete the running worktree or its branch — leaving the thread alive so it can keep working. Stale worktrees and stale local/remote branches are reaped out-of-band by `/pm-update`, which calls `.claude/scripts/stale-cleanup.sh`.

## When to use /wrap vs /merge

- Use **/wrap** at end-of-session. Handles merge + root-main sync + follow-up detection + lessons.
- Use **/merge** for a quick mid-session merge when you'll keep working. Skips follow-up detection and lessons.
- /wrap includes everything /merge does, plus follow-ups and lessons. Don't run both.
- Phase C invokes this skill after gate and AC verification; keep merge, main-sync, follow-up, and cleanup behavior here so Phase C and `/wrap` cannot drift.
- **Target PR:** `/wrap` operates on the PR resolved in Step 1.1. Pass an explicit reference (`/wrap <URL>`, `/wrap #N`, `/wrap N`) to wrap a PR that is **not** on the current branch — common in orchestration threads that ran `/fixpr <URL>` against another worktree. With no argument, Step 1.1's cascade infers the PR; see **Step 1.1: Identify the PR**.
- **Callers of the `/wrap #N` form:** Phase C (`phase-c-merger`), `/pr-monitor-and-manage` (merge-ready fleet PRs), and **`/pm`'s one-shot forgotten-PR triage** (issue #657) all merge an already-open PR by dispatching this workflow rather than reimplementing merge logic — the merge gate, AC verification, and squash-merge live here so every caller stays consistent.

## Execution Model

`/wrap` is a set-and-forget command. Once invoked, it runs all 4 phases end-to-end without mid-run confirmation prompts. It stops early only for explicit stop conditions (for example: no PR on current branch, **human** change requests on HEAD, recovery iteration cap, failed merge gate after recovery, **`/fixpr` delegation failure**, AC verification failure).

> **Always:** Execute all phases end-to-end; proceed immediately between phases when no blocker exists.
> **Ask first:** Never — all phases are autonomous once /wrap is invoked.
> **Never:** Stop to ask "should I continue?" between phases; insert confirmation prompts for non-blocker transitions. Delete the running worktree or its branch — that's `/pm-update`'s job, not /wrap's.

### Follow-up filing is autonomous (issue #633)

Both Phase 3 passes — **Part A** (per-PR follow-ups) and **Part B** (full-session sweep) — file every novel candidate as a GitHub issue **without asking**. There is no opt-out flag and no "file as new issue?" prompt anywhere in this skill. The deal is two-sided: filing is unconditional, and **every** filed issue is reported in the closing message (Step 4.3) with number, title, one-line rationale, and clickable link. Retraction (`gh issue close`) is the escape hatch, not a confirmation round-trip. The norm is stated once for all skills in `.claude/rules/issue-planning.md`.

Autonomy does not mean filing blind: every candidate goes through the body-aware duplicate check in **Step 3.0** first (issue #652). That check can only ever *redirect* a filing onto an existing issue or *annotate* it — it never drops a finding, and every filing it suppresses is named in the closing report alongside the issue it deferred to.

### Phase Transition Autonomy

| Transition | Action | Classification |
|------------|--------|----------------|
| Phase 1 complete (findings scan finished — may have flagged bot findings) | Begin Phase 2 recovery + merge | **Always do** |
| Unresolved review threads detected (Phase 1 scan) | Record `WRAP_UNRESOLVED_THREADS` (thread count — distinct from `WRAP_PHASE1_FINDINGS`, which counts classified bot *finding* comments); proceed to Phase 2 Branch B, which auto-invokes `/fixpr` when threads are the sole gate blocker (issue #455) | **Auto-recover** |
| Unresolved review threads only (Phase 2.1 — `merge-gate.sh` `missing` contains only `unresolved review thread(s)` entries) | Auto-invoke `/fixpr` (Branch B), then re-fetch HEAD + re-run `merge-gate.sh` | **Auto-recover** |
| Phase 2 recovery loop exits cleanly (gate met, ready to merge) | AC check → squash merge → Phase 3 | **Always do** |
| Phase 3 per-PR follow-ups + full-session sweep processed | Begin Phase 4 | **Always do** |
| Phase 4 lessons complete (or skipped as trivial) | Output final report | **Always do** |
| Human `CHANGES_REQUESTED` on current HEAD (`human_changes_requested` non-empty in `merge-gate.sh` JSON) | Stop with reviewer names — **never** auto-dismiss | **Genuine block** |
| Recovery iteration cap or non-recoverable gate failure | Stop with full audit + last `missing` | **Stop and report** |
| AC checkbox verification fails (Phase 2.2) | Stop and report | **Stop and report** |

> **Anti-pattern:** If you find yourself composing "Should I proceed?" or presenting a confirmation button, the answer is always yes — execute immediately.

> **"Threads only" defined (issue #455):** the unresolved-review-threads auto-recovery rows above apply when unresolved review threads are the **sole** blocker — i.e. no other blocker category is present (no CI failing/incomplete, no `BEHIND`/`DIRTY`/`CONFLICTING` merge state, no stale or human `CHANGES_REQUESTED`, no missing fresh bot `APPROVED`). When any of those co-occur, the broader Step 2.1 decision tree (issue #452) owns dispatch — first matching branch wins — rather than a single threads-only pass. The single-attempt / stop-on-mixed-blocker semantics from #455 are realized here as the threads-only branch of the bounded #452 loop, not a separate one-shot path.

## Output modes

`/wrap` is **terse by default**: it runs all four phases in full but collapses its human-facing output to a short merged + follow-ups summary. Pass `--verbose` for the complete per-phase narration and the detailed final report.

| Mode | Flag | Effect |
|------|------|--------|
| **Terse** | *(default)* | Two concise blocks — **Merged** (≤3 sentences) and **Follow-ups** (≤3 sentences, or "No follow-ups opened.") — plus a one-line lessons ack and, only when the sweep left decisions pending, a one-line verdict. Per-phase narration is suppressed. |
| **Verbose** | `--verbose` | The full report: per-cycle recovery heartbeats, the Session Lessons block, and the multi-section "Wrap-Up Complete" report (Issues filed, Filings suppressed as duplicates, Session sweep, Verdict, Lessons). |

**Verbosity is additive and human-facing only.** Every phase — inference, the merge-gate recovery loop, `/fixpr` delegation, the follow-up + full-session sweep, and the lessons/memory write — executes **identically** in both modes; only narration differs (the `babysit-pr --silent` "work continues, output suppressed" model). Three things always print regardless of mode:

- **State-changing blockers and stop conditions** — a merge that can't proceed, `CONFLICTING`, human `CHANGES_REQUESTED`, no PR found, the recovery cap — surface as a short one-line reason even in terse mode (Step 4.3 **Blocker path**). Terseness never swallows a blocker.
- **The `[INFERRED]` merge-safety checkpoint** (Step 1.1). It is the user's only catch point for a mis-inferred **merge**, so it is a safety guardrail rather than phase chatter — it prints in both modes (it fires only on the inference path, never on the normal branch path, so it barely affects terseness).
- **The CLAUDE.md 5-minute heartbeat** during long `/fixpr` waits. Terse mode suppresses the *routine* per-cycle recovery heartbeat, but never the obligation to break silence during a long-running operation.

When `/wrap` is invoked by a phase-C subagent, the machine **`EXIT_REPORT`** block (per `phase-protocols.md`) is emitted **identically regardless of verbosity** — `--verbose` governs only the prose report, never the structured exit contract.

## Phase 1: Pre-Merge Verification — Check for Unresolved Findings

Before merging, verify that all reviewer feedback has been addressed.

### Step 1.1: Identify the PR

**Parse flags first (before any PR resolution).** Following `recap`'s "extract flags first, then interpret the remainder as the target" rule, scan `$ARGUMENTS` for `--verbose` (anywhere, any order), set `WRAP_VERBOSE`, and **strip it** so only the PR reference remains for the cascade below. Absence of the flag ⇒ terse mode (the default). See **Output modes** above for what each mode prints.

```bash
WRAP_VERBOSE=0
REST=""
for tok in ${ARGUMENTS:-}; do
  if [ "$tok" = "--verbose" ]; then WRAP_VERBOSE=1; else REST="${REST:+$REST }$tok"; fi
done
ARGUMENTS="$REST"   # remainder is a clean PR reference for 1.1a onward (may be empty)
```

`/wrap` resolves its target PR through an ordered inference cascade. The first sub-step that yields a PR wins; later sub-steps are skipped. The shared helper `.claude/scripts/infer-pr.sh` handles explicit-argument normalization and session-state lookup (issue #448 — the same helper `/fixpr` adopts under issue #447, so the two skills cannot drift). Thread scanning (1.1c) is judgment the AI layer performs directly.

> **Merge-safety wrinkle:** `/wrap` implicitly authorizes the squash merge, so an incorrect inference would merge the **wrong** PR. Only auto-proceed when the target is unambiguous (1.1a explicit, 1.1b branch PR, or a single inferred candidate). When candidates are tied or genuinely ambiguous, **stop and prompt** — never guess for a merge. The `[INFERRED]` line emitted at the end of this step (before any Phase 1 verification work in Step 1.2 onward) is the user's only catch point, since `/wrap` runs end-to-end without confirmation prompts.

Resolve the helper once (global install preferred, in-repo fallback):

```bash
INFER_PR=""
for candidate in \
  "$HOME/.claude/skills-worktree/.claude/scripts/infer-pr.sh" \
  "$HOME/.claude/scripts/infer-pr.sh" \
  ".claude/scripts/infer-pr.sh"; do
  if [[ -x "$candidate" ]]; then INFER_PR="$candidate"; break; fi
done
```

**1.1a — Explicit argument.** If `$ARGUMENTS` is non-empty the user named a specific PR: resolve it explicitly and **skip 1.1b–1.1e entirely**. A non-empty `$ARGUMENTS` must **never** fall through to the current-branch path (1.1b) — that could wrap a *different* PR than the one requested. If the reference cannot be resolved (helper missing or unparseable), **stop** rather than guessing:

```bash
OWNER_REPO=""   # repo the resolved PR lives in, when known (used by the guard below)
if [[ -n "${ARGUMENTS:-}" ]]; then
  if [[ -z "$INFER_PR" ]]; then
    echo "STOP: /wrap was given '$ARGUMENTS' but infer-pr.sh was not found — cannot safely resolve an explicit PR reference. Install .claude/scripts/infer-pr.sh, or run /wrap with no argument from the PR's branch." >&2
    # STOP — do NOT fall through to 1.1b (would risk wrapping the wrong PR).
  elif EXPLICIT_JSON=$("$INFER_PR" --explicit "$ARGUMENTS"); then
    PR_NUM=$(jq -r '.most_recent.number' <<<"$EXPLICIT_JSON")
    OWNER_REPO=$(jq -r '.most_recent.owner_repo // empty' <<<"$EXPLICIT_JSON")
    INFERRED_SOURCE="explicit argument"
  else
    echo "STOP: could not parse '$ARGUMENTS' as a PR reference (URL, owner/repo#N, #N, or N)." >&2
    # STOP — do NOT fall through to inference for a malformed explicit arg.
  fi
  # Either PR_NUM is now set, or we stopped. An explicit argument never reaches 1.1b–1.1e.
fi
```

**1.1b — Current branch.** If no explicit argument, try the branch's PR (existing behavior — preferred when present):

```bash
BRANCH_PR=$(gh pr view --json number,title,headRefName,body,state \
  --jq '{number, title, headRefName, body, state}' 2>/dev/null || true)
```

If `gh pr view` finds a PR, use it (`PR_NUM` = its number, `INFERRED_SOURCE` unset — this is the normal, non-inferred path) and skip 1.1c–1.1e.

**1.1c — Scan thread context** *(AI judgment)*. If 1.1a and 1.1b found nothing, scan the **current conversation** (most recent first) for PRs this thread just operated on:

- The most recent `/fixpr <URL>` or `/wrap <URL>` invocation in this thread.
- Explicit PR references the thread acted on — `PR #N`, `github.com/<owner>/<repo>/pull/N`, or a `=== fixpr complete === PR: #N` footer.

Collect each distinct PR number with the position it was last mentioned (more recent = stronger). Thread-context recency outranks session-state in 1.1e. If the chosen thread reference was a full `github.com/<owner>/<repo>/pull/N` URL, also capture its `<owner>/<repo>` into `OWNER_REPO` so the repo-scoping guard below can catch a cross-repo target.

**1.1d — Query session-state.** Also gather candidates the session is tracking, scoped to this repo. Capture the helper's **real** exit code — do **not** append `|| true`, which would force `$?` to `0` and mask exit `1` (multiple), `2` (none), or `4` (error):

```bash
ROOT_TOPLEVEL=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
if SESSION_JSON=$("$INFER_PR" --root-repo "$ROOT_TOPLEVEL"); then
  SESSION_RC=0
else
  SESSION_RC=$?
fi   # 0 single, 1 multiple, 2 none, 3/4 error
```

**1.1e — Merge, deduplicate, resolve.** Combine the thread-context candidates (1.1c) and session-state candidates (1.1d), deduplicating by PR number. Rank by recency, **preferring thread-context order over session-state `last_activity`**. Then apply the resolution rules:

- **Single candidate** (exactly one across both sources): proceed on it.
- **Most-recent-unambiguous** (multiple candidates, but one was mentioned/active distinctly more recently — e.g. the top thread mention, or active within the last ~5 minutes while the others are stale): proceed on the most-recent one and surface the rest with an `Also tracking:` line.
- **Ambiguous** (candidates tied in recency, or no clear most-recent winner): **stop** — list each candidate with its source/last-activity and ask the user to specify: `Multiple PRs in scope — please specify: /wrap <N>`.
- **No candidates** (1.1b empty, 1.1c found nothing, `SESSION_RC == 2`): stop — but pick the stop message that matches the situation, per **1.1f** below. Either way `/wrap` does no work: Phases 1–4 are all skipped, nothing is created, and the skill exits.

**1.1f — Choose the no-candidates stop message** *(AI judgment, same layer and style as 1.1c — no script, no state file)*. Scan the **current conversation** for signals that this thread never contained coding work. Count a signal only when it is actually present in the thread:

- The thread ran `/issue-maker`, or otherwise declared itself capture-only / issue-only mode.
- The thread's entire output was creating, editing, commenting on, or closing GitHub issues — no implementation.
- The thread is PM/monitoring/orchestration only (`/pm`, `/status`, `/standup`, `/recap`) with no code written here.
- The thread explicitly concluded the work was already solved elsewhere, or that there is nothing to implement.
- No branch, worktree, commit, push, or PR was ever created or discussed in this thread.

**Tiebreak — this bias is mandatory.** Emit the no-coding message **only** when the thread affirmatively shows those signals. If the signals are absent, weak, mixed, or you are unsure at all, emit the lookup-failed message. Telling someone "nothing to wrap" while they are sitting on a real PR is the worse failure; a redundant `/wrap <N>` hint costs nothing.

- **Non-coding thread detected** — state it plainly; this is a normal outcome, not an error. Do not use "failed", "could not", "unable to find", and do not imply the user should go fix anything:

  ```text
  This thread has no coding work in it, so there's nothing to wrap. No action needed.
  ```

- **No detection signal (default)** — keep today's meaning and name the escape hatch:

  ```text
  No PR found for the current branch. If you meant a specific PR, name it: /wrap <N>
  ```

**Emit the inference result before verification.** Once a PR is resolved by inference (any of 1.1a, 1.1c, or 1.1d/e — i.e. `INFERRED_SOURCE` is set, *not* the plain 1.1b branch path), print the `[INFERRED]` line **immediately, before any Phase 1 verification work (Step 1.2 onward)**, so the user has a visible checkpoint to abort a mismatch:

```text
[INFERRED] PR #462 from thread context
Also tracking: PR #458   ← only when other candidates exist
```

Use a `<source>` of `explicit argument`, `thread context`, or `session-state` as applicable. After emitting the line, pause briefly to let the user interrupt if the inferred PR is wrong — this is the only abort point, since `/wrap` runs end-to-end without confirmation prompts.

**Repo-scoping guard (merge-safety).** `/wrap`'s verification and merge steps — `merge-gate.sh`, `pr-state.sh`, `ac-checkboxes.sh`, `gh pr merge`, and the root-main sync (Step 2.5) — all operate on the **current checkout** and take no cross-repo override. So if the resolved PR lives in a *different* repo than this checkout, proceeding would target the wrong PR (or sync the wrong `main`). When `OWNER_REPO` is known (set from an explicit URL / `owner/repo#N` in 1.1a, or a thread URL in 1.1c) and differs from the current repo, **stop**:

```bash
CURRENT_REPO=$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || echo "")
if [[ -n "${OWNER_REPO:-}" && -n "$CURRENT_REPO" && "$OWNER_REPO" != "$CURRENT_REPO" ]]; then
  echo "STOP: the target resolves to $OWNER_REPO#$PR_NUM, but this checkout is $CURRENT_REPO. /wrap's merge, AC, and main-sync steps are scoped to the current checkout — re-run /wrap from a $OWNER_REPO checkout (or its worktree)." >&2
fi
```

References without an `owner_repo` (`#N`, bare `N`, the 1.1b branch PR, or session-state candidates — which `infer-pr.sh --root-repo` already scopes to this repo) are assumed to live in the current checkout, so the guard is a no-op for them.

Once `PR_NUM` is fixed (and the guard above passed), fetch its details for the rest of Phase 1:

```bash
gh pr view "$PR_NUM" --json number,title,headRefName,body,state \
  --jq '{number, title, headRefName, body, state}'
```

If the PR is already merged or closed, skip to Phase 3 (follow-up detection).

### Step 1.2: Scan for unresolved review findings

> **pr-state.sh first (NON-NEGOTIABLE):** Before calling `gh api .../pulls/{N}/reviews`, `pulls/{N}/comments`, or `issues/{N}/comments` directly, call `pr-state.sh --pr N` first and read the cached JSON bundle. All review-state queries in this skill read from the `$BUNDLE` returned by `pr-state.sh` — do not add inline `gh api` calls to these three endpoints.

Use the shared `pr-state.sh` helper to fetch and pre-classify review activity from all three endpoints in one call. It filters to `coderabbitai[bot]`, `greptile-apps[bot]`, and `cursor[bot]` (BugBot) and tags each comment with `classification.class` (`finding` vs `acknowledgment`). The classifier only runs when `--since <iso>` is passed — pass the PR's `createdAt` to include every bot comment on the PR. The helper writes the JSON bundle to a tempfile and prints its **path** on stdout — capture the path, then read with `jq < "$BUNDLE"`:

`$PR_NUM` is already fixed by Step 1.1's cascade — reuse it; do **not** re-derive it from `gh pr view` (a bare call would target the current branch's PR, not the inferred one):

```bash
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

**Unresolved-threads detection (issue #455).** Pull the unresolved-thread count from the same bundle and **record it**. Phase 1 runs *before* `merge-gate.sh`, so it **cannot** yet know whether threads are the *sole* blocker (CI, `BEHIND`/`DIRTY`, a missing fresh approval, etc. only surface in Step 2.1's gate JSON). The threads-only determination and the auto-recovery decision therefore live in Step 2.1 Branch B — Phase 1 only surfaces that unresolved threads exist:

```bash
# Same $BUNDLE captured above. pr-state.sh exposes threads.unresolved_count.
# This is the thread count — distinct from WRAP_PHASE1_FINDINGS (classified
# bot *finding* comments). A threads-only gate failure can occur with zero
# Phase 1 findings (e.g. an older thread that produced no new finding-class
# comment in this baseline scan), so the two are tracked separately.
WRAP_UNRESOLVED_THREADS=$(jq -r '.threads.unresolved_count // 0' < "$BUNDLE")
```

If `WRAP_UNRESOLVED_THREADS > 0`, record it. In `--verbose` mode, also emit a timestamped detection heartbeat (terse mode suppresses this narration — the detection and the Step 2.1 routing happen either way). Do **not** assert that threads are the sole blocker or that recovery will happen — that is Branch B's call once the gate's full `missing` set is known:

```bash
if [ "$WRAP_VERBOSE" = "1" ]; then
  TS=$(TZ='America/New_York' date +'%a %b %-d %I:%M %p ET')
  echo "[$TS] Phase 1: $WRAP_UNRESOLVED_THREADS unresolved review thread(s) detected — Step 2.1 will route to /fixpr if they are the sole gate blocker (issue #455)"
fi
```

**Do not invoke `/fixpr` from Phase 1** — that would double-invoke against Phase 2 Branch B and re-burn a CR review. Phase 1 only *detects and records*; the single delegation point is Step 2.1 Branch B. The actual threads-only stop-or-recover decision (single bounded pass, code-verified resolution, re-check) lives there. This preserves the single-`/fixpr`-per-blocker contract and the bounded loop (no infinite delegation).

Proceed immediately to Phase 2 — do not ask.

## Phase 2: Merge

### Step 2.1: Merge gate + autonomous recovery loop (issue #452)

**Authority:** `.claude/scripts/merge-gate.sh` JSON on stdout is the single source of truth for merge readiness. After **every** recovery action, re-fetch the PR HEAD SHA (`gh pr view "$PR_NUM" --json headRefOid,state`) and re-run `merge-gate.sh` — **no stale cache** of gate JSON across iterations.

**Environment (optional):** Assign defaults once before looping:

```bash
WRAP_RECOVERY_MAX_ITERATIONS="${WRAP_RECOVERY_MAX_ITERATIONS:-5}"
```

| Variable | Default | Purpose |
|----------|---------|---------|
| `WRAP_RECOVERY_MAX_ITERATIONS` | `5` | Hard cap on recovery cycles |

**Polling ownership (issue #454):** `/wrap` has NO polling cadence of its own — no sleeps, no micro-polls between gate checks. All waiting for bot verdicts and CI happens inside `/fixpr`'s Step 4d review-wait loop (30–60s cadence, 20-min cap per iteration, outer cap 5). `/wrap` delegates, trusts the returned verdict, and re-runs `merge-gate.sh` immediately.

**Per-iteration heartbeat:** In `--verbose` mode, before acting, emit one user-visible line per cycle:

```bash
if [ "$WRAP_VERBOSE" = "1" ]; then
  TS=$(TZ='America/New_York' date +'%a %b %-d %I:%M %p ET')
  echo "[$TS] /wrap recovery cycle $i/$WRAP_RECOVERY_MAX_ITERATIONS — gate check"
fi
```

The verbose cycle line includes Eastern time (same `TZ='America/New_York' date` pattern as `CLAUDE.md`); optionally append **`— blocker → action → result`** for scanability.

**Terse mode keeps two non-negotiable recovery-loop signals** (the `babysit-pr --silent` model — routine ticks quiet, meaningful transitions loud), so the *routine* per-cycle "gate check" line above is verbose-only but recovery never runs invisibly:

- **The CLAUDE.md 5-minute heartbeat is never suppressed.** Recovery may delegate to `/fixpr`, which can wait minutes for bots/CI. If a wait approaches 5 minutes, emit a brief timestamped progress line even in terse mode — silence during a long op is a heartbeat-rule violation, not terseness.
- **Dispatch and blocker transitions always print.** When this loop invokes `/fixpr` (the Branch B/C/D delegate heartbeats below) or hits a genuine block/stop, that short line prints in both modes — it doubles as the "recovery underway" / long-wait anchor and only ever fires on the non-merge-ready path (a merge-ready `/wrap` skips the loop entirely).

After each action, append to **`WRAP_RECOVERY_AUDIT`** (free-form lines or bullets): cycle number, blocker summary, action taken, result (`merge-gate` exit code + short `missing` summary or success). Include any **`FIXPR_WRAP_STATUS:…`** / **`Status:`** line parsed from a delegated `/fixpr` run. The audit is always built (it backs the stop-condition report and the verbose final report); it is *rendered* to the user only under `--verbose`.

**Merge-ready shortcut:** Before entering the loop, run `merge-gate.sh` once. If exit `0` **and** Phase 1 recorded no `WRAP_PHASE1_FINDINGS`, **and** you are not carrying forward a half-applied recovery from a prior turn, skip straight to Step 2.2 — **no extra overhead**.

**Recovery loop:** For `i` from `1` through `$WRAP_RECOVERY_MAX_ITERATIONS`:

1. **Terminal checks**
   - If `gh pr view "$PR_NUM" --json state --jq '.state'` returns `MERGED` → exit loop for Phase 3 (merged terminal — Phase 3 + 4 unchanged). Use `state`, **not** a `merged` field — `gh` has no `merged` JSON field and `--json merged` fails with `Unknown JSON field: "merged"` (issue #608).
   - If it returns `CLOSED` → PR closed without merge; stop with status (do not merge).

2. **Refresh gate (always)**  
   ```bash
   GATE_JSON=$(.claude/scripts/merge-gate.sh "$PR_NUM")
   GATE_EXIT=$?
   HEAD_NOW=$(printf '%s' "$GATE_JSON" | jq -r '.head_sha // empty')
   ```
   Pipe JSON with `printf '%s'`, never `echo` — zsh's builtin `echo` interprets escape sequences and corrupts the payload, yielding a parse error or an empty `HEAD_NOW` that defeats the no-stale-SHA contract (issue #574).
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

   **Threads-only detection + delegate heartbeat (issue #455 / #479).** Before delegating, classify whether unresolved review threads are the *only* blocker using `merge-gate.sh`'s **structured** signals — not by string-matching the prose. The gate emits `unresolved_thread_count` (the count behind the thread `missing` entry) and adds exactly **one** `missing` entry for the unresolved-thread gate, so "threads only" is `unresolved_thread_count > 0` **and** `missing` has length 1:

   ```bash
   THREADS_ONLY=$(printf '%s' "$GATE_JSON" | jq -r '
     ((.unresolved_thread_count // 0) > 0)
     and (((.missing // []) | length) == 1)')
   TS=$(TZ='America/New_York' date +'%a %b %-d %I:%M %p ET')
   if [ "$THREADS_ONLY" = "true" ]; then
     echo "[$TS] Phase 2.1: merge gate blocked by unresolved review threads only — invoking /fixpr (issue #455)"
   else
     echo "[$TS] Phase 2.1: gate blocked (mixed/other blockers) — invoking /fixpr per #452 decision tree"
   fi
   ```

   The threads-only case is the narrow #455 path; mixed blockers fall through to the broader #452 dispatch above (Branch A stale-dismiss, `CONFLICTING` stop, etc. — first matching branch already won this iteration). Either way the delegation target is the same `/fixpr` workflow; the heartbeat just makes the trigger legible.

   **Execution contract:** Do **not** shell out to an opaque “run fixpr” wrapper. Execute the **full** `.claude/skills/fixpr/SKILL.md` workflow (Steps 0–7, including the Step 4d review-wait loop): `pr-state.sh`, classify findings, fix + single push when needed, `dismiss-stale-bot-changes.sh` after push when applicable, `reply-thread.sh`, `resolve-review-threads.sh`, the bounded wait for bot verdicts + CI on the new SHA, verify passes, etc. If spawning a Phase A subagent to carry the skill, use **`mode: "bypassPermissions"`**, explicit **`model`**, SAFETY block from `.claude/rules/safety.md`, and handoff path per `.claude/rules/subagent-orchestration.md` — parent stays in **monitor mode** (orchestration only).

   Parse the **`=== fixpr complete ===`** footer for **`Status:`**, **`FIXPR_WRAP_STATUS`**, and **`FIXPR_WAIT_SUMMARY`** (iterations, total wait secs, final state — see fixpr skill and the `/wrap → /fixpr` delegation contract in `.claude/rules/phase-protocols.md`). On return, emit a timestamped **control-returned heartbeat** (issue #455 AC) so the delegation is visible end-to-end:

   ```bash
   TS=$(TZ='America/New_York' date +'%a %b %-d %I:%M %p ET')
   echo "[$TS] Phase 2.1: /fixpr returned — Status: $FIXPR_WRAP_STATUS ($FIXPR_WAIT_SUMMARY)"
   ```

   Echo status + wait summary into the heartbeat for this cycle and append them to `WRAP_RECOVERY_AUDIT`. **Trust the verdict (issue #454):** `/fixpr` already waited for the bots and CI on the new SHA — re-fetch HEAD and re-run `merge-gate.sh` **immediately**; never sleep or re-poll on top. For the threads-only case this satisfies #455's "re-fetch HEAD SHA, re-run `pr-state.sh` + `merge-gate.sh`; if clean continue to merge, else stop/loop" — `/fixpr` ran `pr-state.sh` internally and `merge-gate.sh` re-enforces resolved threads (Step 1c of `cr-merge-gate.md`).

   **Stop conditions after `/fixpr`:**

   - **`CI_FAILING`** with deterministic code/test failures you cannot fix in-session → stop; surface `missing` / CI summary + audit (matches “unfixable CI” scenario).
   - **`THREADS_STUCK`**, **`NEEDS_HUMAN_REVIEW`**, or **`NEW_FINDINGS`** where unresolved → stop with audit; instruct re-run `/wrap` or `/fixpr`. (`NEW_FINDINGS` now means `/fixpr` exhausted its own 5-iteration budget — `FIXPR_WAIT_SUMMARY: … final=new-findings-pending`.) For **`THREADS_STUCK`** specifically (issue #455 single-attempt boundary), the hard-stop message must **list each residual unresolved thread** — copy the `[STUCK] <url> — <reason>` lines from `/fixpr`'s footer — so the user sees exactly which threads `/fixpr` could not code-verify (it never resolves a thread without verification — that safety boundary is never overridden by `/wrap`).
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

   **E. Branch-protection block a bot re-review can't clear (`enforce_admins`)** — When the **only** outstanding blocker is `missing` reporting `branch protection reviewDecision is … not APPROVED, with <bot> in CODEOWNERS` **and** that bot already has a fresh `APPROVED` on HEAD (so Branch C's re-trigger won't help — the AI reviewer auto-skipped the code-owner path), this is the solo-owner `enforce_admins` bypass scenario. **Stop** and suggest **`/admin-merge <PR>`** — never tell the user to toggle `enforce_admins` in the GitHub UI, and never modify branch protection yourself. `/admin-merge` prints a user-runnable bypass command (gate is re-verified first). Record the suggestion in the audit.

   **`merge_state == UNKNOWN`** — GitHub is still computing mergeability; re-run `merge-gate.sh` on the next iteration (the gate call itself provides the spacing — no sleep). If still unknown at cap, stop with audit.

4. **End of iteration:** If no branch matched and gate still fails, append “unclassified blocker” + full `missing` to audit and proceed to next `i`.

**Loop exit:**

- **Success:** `merge-gate.sh` exit `0` → Step 2.2.
- **Iteration cap:** Stop. Report **last `missing` array** verbatim + **full `WRAP_RECOVERY_AUDIT`** + guidance to re-run `/wrap`.
- **Genuine block:** Human changes requested, `CONFLICTING`, rate-limit stop, or hard `/fixpr` failure as above.

**Safety (non-negotiable, issue #452 / #450):**

- **Never** call GitHub APIs that modify **branch protection** (`.../branches/.../protection`). When a merge is blocked by `enforce_admins` on a solo-owner repo, suggest **`/admin-merge`** (Branch E) — it prints a command for the **user** to run — instead of toggling protection or pointing the user at the GitHub UI.
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
# Verbose-only narration. Both values are captured above and reused by the
# final report either way. Terse surfaces main-sync status in the Merged block
# ONLY when noteworthy (an `aborted:` outcome or a quarantine actually ran);
# a clean/up-to-date sync adds no line.
if [ "$WRAP_VERBOSE" = "1" ]; then
  echo "Main quarantine: $QUARANTINE_STATUS"
  echo "Main sync: $MAIN_SYNC_STATUS"
fi
```

See `.claude/scripts/main-sync.sh --help` and `.claude/scripts/dirty-main-guard.sh --help` for the full contracts.

**If `MAIN_SYNC_STATUS` starts with `aborted:`** (local main has unpushed commits that didn't come from origin), do NOT attempt recovery automatically. Surface the full status line in the final report so the user can run `git log origin/main..main` against the root repo and decide. The PR merge itself has already succeeded — main-sync failure does not un-merge anything.

Store `MAIN_SYNC_STATUS` and `QUARANTINE_STATUS` for the final report at the end of Phase 4.

## Phase 3: Follow-Up Detection and Full-Session Sweep

Phase 3 has **two parts**, run in order:

- **Part A — Per-PR follow-up detection (Steps 3.1–3.4):** derive follow-ups from the **merging PR** and its linked issue (HHG two-ticket pattern, linked-issue sub-tasks), dedup, and **auto-create** GitHub issues.
- **Part B — Full-session sweep (Steps 3.5–3.13):** answer "is there anything I should have ticketed but didn't?" across the **entire session**, not just the PR. Seven categories: loose ends, ticket coverage, external/process state, memory persistence, PM hygiene, time-sensitive items, future-self handoff. Each finding is either **auto-handled** (safe process cleanup, or an auto-filed ticket) or **surfaced** to the user under "needs your decision".

**Shared filed-issue registry (`WRAP_FILED_ISSUES`) — initialize before Step 3.1.** Both parts file into the *same* run-scoped registry, so a loose end visible to both produces exactly **one** issue and every filing lands in one closing announcement. Each entry is `{number, title, keywords, rationale}` — `rationale` being the one-line "why" rendered in Step 4.3 (e.g. `follow-up from PR #471`, `loose end: retry cap never revisited`). Part A appends in Step 3.3; Part B checks the registry *before* its own dedup search in Step 3.7 and appends there. The registry is per-run and in-memory; it composes with — and never replaces — the cross-run `SWEEP_PRIOR_FILED` record persisted in Step 3.13.

Both parts feed the Phase 4 final report, which announces every registry entry in a single block (Step 4.3).

### Step 3.0: Dedup helper setup (both parts — issue #652)

Autonomous filing without a duplicate check files rival tickets: issue #647 was filed thirteen minutes after issue #638 restating its second acceptance criterion, because the sweep searched titles only and the two share almost no title words. Both parts therefore run the same **body-aware** check before every filing.

Resolve the helper once, before Step 3.1, with the standard three-candidate lookup:

```bash
ISSUE_DEDUP=""
for candidate in \
  "$HOME/.claude/skills-worktree/.claude/scripts/issue-dedup.sh" \
  "$HOME/.claude/scripts/issue-dedup.sh" \
  ".claude/scripts/issue-dedup.sh"; do
  if [[ -x "$candidate" ]]; then ISSUE_DEDUP="$candidate"; break; fi
done
DEDUP_EXCLUDE=""   # comma-separated issue numbers filed earlier in THIS run
DEDUP_DEGRADED=""      # THIS search only — reset on every dedup_search call
DEDUP_ANY_DEGRADED=""  # sticky across the run — drives the Step 4.3 report line

# Both parts call this; it is the ONLY dedup entry point. Exit 1 ("searched,
# found nothing") is the sole status that may be read as "no duplicate" —
# a missing helper or a gh/env error (exit 2/4) degrades to the title-only
# check and is reported, never silently treated as a clean no-match.
dedup_search() {   # dedup_search <keywords> -> sets DEDUP_JSON/DUP_NUM/DUP_STATE
  local kw="$1" rc=0
  DEDUP_JSON='[]'
  DEDUP_DEGRADED=""   # per-call: a candidate is classified on ITS OWN search,
                      # never on an earlier one's transient failure
  if [ -n "$ISSUE_DEDUP" ] && [ -n "$kw" ]; then
    DEDUP_JSON=$("$ISSUE_DEDUP" "$kw" ${DEDUP_EXCLUDE:+--exclude "$DEDUP_EXCLUDE"}) || rc=$?
    if [ "$rc" -gt 1 ]; then
      DEDUP_DEGRADED="helper exit $rc"
      DEDUP_ANY_DEGRADED="$DEDUP_DEGRADED"
      DEDUP_JSON=$(gh issue list --search "${kw} in:title" --state open \
        --json number,title,state --jq '[.[0] // empty]' 2>/dev/null || echo '[]')
    fi
  elif [ -n "$kw" ]; then
    DEDUP_DEGRADED="helper not installed"
    DEDUP_ANY_DEGRADED="$DEDUP_DEGRADED"
    DEDUP_JSON=$(gh issue list --search "${kw} in:title" --state open \
      --json number,title,state --jq '[.[0] // empty]' 2>/dev/null || echo '[]')
  fi
  DUP_NUM=$(printf '%s' "$DEDUP_JSON" | jq -r '.[0].number // empty')
  DUP_STATE=$(printf '%s' "$DEDUP_JSON" | jq -r '.[0].state // empty' | tr '[:lower:]' '[:upper:]')
  WEAK_DUP_NUM=""   # set to $DUP_NUM by the weak/closed branch at each call site
}
```

`issue-dedup.sh <keywords>` prints ranked candidates as JSON (`number`, `title`, `state`, `coverage`, `terms_matched`, …), scoring **title and body** across open plus recently-closed issues. Exit `0` = candidates, `1` = none (the only "no duplicate" verdict), `2`/`4` = usage or gh/environment failure.

**A degraded search is never a strong match.** When `DEDUP_DEGRADED` is non-empty *for that candidate's own search*, the check saw titles only, so it cannot satisfy the strong-match criteria — file. `DEDUP_DEGRADED` resets per call precisely so one transient `gh` hiccup does not force every later candidate in the run down the degraded path; `DEDUP_ANY_DEGRADED` is the sticky flag, and it drives one line in the Step 4.3 report, not any classification.

**The helper only finds candidates — it never decides.** The strong / weak / none classification, the four strong-match criteria, and the comment-vs-file rule are specified once in **`.claude/reference/autofile-dedup.md`**; both Step 3.3 and Step 3.7 apply them unchanged. Two invariants carry across every branch:

- **Bias toward filing.** A duplicate ticket is noise you close in one command; a real finding appended to an issue whose scope never covered it is simply lost. Ambiguity resolves to "file, with a `Possibly duplicates #N` line".
- **Suppression is never silent.** Every filing the check suppressed appears in the Step 4.3 report naming the issue it deferred to.

**If `ISSUE_DEDUP` is empty** (helper not installed), fall back to the pre-#652 title-only `gh issue list --search "$KEYWORDS in:title"` check, and note the degraded check once in the Step 4.3 report — never skip dedup entirely, and never let a missing helper block a filing.

> **Phase C / subagent context:** When `/wrap` is invoked by a Phase C subagent (per `subagent-orchestration.md`), the subagent's transcript is narrow and short-lived. Part B degrades gracefully: transcript-derived categories (1, 6, 7) will usually find nothing and the verdict will be "Clear to archive". Part A and the state-file-derived categories (3, 5) still run normally. Never block a Phase C merge on a Part B finding — Part B is advisory.

### Part A — Per-PR follow-up detection

### Step 3.1: Detect follow-up items

1. Extract the linked issue number from the PR body via `pr-issue-ref.sh` (matches all nine GitHub closing keywords — `close`/`closes`/`closed`/`fix`/`fixes`/`fixed`/`resolve`/`resolves`/`resolved`, case-insensitive) and fetch its title and body. Distinguish exit `1` (no link — expected) from exits `2`/`3`/`4` (real errors) so genuine failures surface:
   ```bash
   # Reuse the PR fixed by Step 1.1 (the inferred PR may not be the current
   # branch's PR — a bare `gh pr view` would resolve the wrong one).
   PR_NUMBER="$PR_NUM"
   PR_TITLE=$(gh pr view "$PR_NUMBER" --json title --jq '.title')
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

1. **Dedup check** — run the shared helper (Step 3.0), which scores **titles and bodies** of open and recently-closed issues. Classify the top candidate as **strong / weak / none** per `.claude/reference/autofile-dedup.md`. **Guard against empty keywords**: with no usable keywords the helper exits 1 with `[]`, which means *file* — never treat "couldn't search" as "duplicate found".
   ```bash
   dedup_search "$KEYWORDS"   # Step 3.0 — sets DEDUP_JSON, DUP_NUM, DUP_STATE, WEAK_DUP_NUM
   ```
   Then take the branch the classification names:
   - **Strong** (open issue, same primary artifact, a quotable covering criterion, `coverage ≥ 0.6`) → **do not file**. Comment the follow-up onto `#{DUP_NUM}` with the template in `autofile-dedup.md`, and record `"{title}" — appended to #{DUP_NUM} instead of filing` for the Step 4.3 report.
   - **Weak / ambiguous**, or the top candidate is **closed** → set `WEAK_DUP_NUM="$DUP_NUM"` and **file**; step 2 renders it as a `Possibly duplicates #{DUP_NUM}` line in the body, and the ambiguity is recorded in the report.
   - **None** → file exactly as before.

   When in doubt, file. A duplicate ticket is recoverable; a finding buried as a comment on an unrelated issue is not.

2. **Create the issue** (strong match excepted). Check the exit status and validate the parsed number before logging — if creation fails or the URL doesn't parse, record the failure in the report and continue with the next item. **Guard the `Linked source` line** — only include it when `ISSUE_N` is non-empty, otherwise the body will render a broken `#` reference on GitHub. `POSSIBLE_DUP` carries the weak-match pointer and is empty otherwise:
   ```bash
   LINKED_SOURCE=""
   if [ -n "$ISSUE_N" ]; then
     LINKED_SOURCE=$'\n\n'"Linked source: #${ISSUE_N}"
   fi
   POSSIBLE_DUP=""   # weak-match pointer only; empty on a clean no-match
   if [ -n "${WEAK_DUP_NUM:-}" ]; then
     POSSIBLE_DUP=$'\n\n'"Possibly duplicates #${WEAK_DUP_NUM} — {one line on the overlap and what is unclear}."
   fi
   if NEW_URL=$(gh issue create \
     --title "{derived title}" \
     --body "Follow-up from PR #${PR_NUMBER}.${POSSIBLE_DUP}

   {context from detection}${LINKED_SOURCE}

   _Filed via /wrap._" 2>&1); then
     NEW_NUM=$(echo "$NEW_URL" | grep -oE '[0-9]+$')
     if [ -z "$NEW_NUM" ]; then
       echo "WARNING: created issue but could not parse number from: $NEW_URL"
       # record as failure and continue
     fi
     # Append to the run-scoped registry: {number, title, keywords, rationale}.
     # Rationale for Part A items is "follow-up from PR #${PR_NUMBER}".
   else
     echo "WARNING: gh issue create failed: $NEW_URL"
     # record as failure and continue — do not abort Phase 3
   fi
   ```

   Every successful creation appends `{number, title, keywords, rationale: "follow-up from PR #${PR_NUMBER}"}` to **`WRAP_FILED_ISSUES`** and appends `$NEW_NUM` to **`DEDUP_EXCLUDE`**, so an issue this run just opened cannot come back as its own dedup candidate a step later. The `_Filed via /wrap._` footer is the audit marker that makes automation-opened issues findable later (same role as `/issue-maker`'s `_Captured via /issue-maker._`); it is zero-config and requires no repo label to exist.

**Non-HHG PRs still get generic follow-up creation** — any items collected in Step 3.1 that are not overridden by the HHG path go through the dedup + create flow above.

### Step 3.4: Carry Part A results into the unified report

Part A does **not** print its own "Created" list — every issue it filed is already in `WRAP_FILED_ISSUES` and is announced once, alongside Part B's filings, in the single closing block rendered by Step 4.3. Printing here too would report the same issue twice.

What Part A *does* carry forward:

- **Filed** — already in `WRAP_FILED_ISSUES` (number, title, rationale `follow-up from PR #{PR_NUMBER}`).
- **Suppressed as duplicates** — record as `Appended to #{DUP_NUM} instead of filing — "{title}"` for the Step 4.3 **Filings suppressed as duplicates** section (not the follow-ups line).
- **Filed with a duplicate caveat** — weak matches were filed; note `"{title}" — filed, possible duplicate of #{DUP_NUM}` so the ambiguity shows in the report as well as the issue body.
- **Failures** — any `gh issue create` that failed or whose number would not parse; these must appear in the report so a dropped follow-up is never silent.

If nothing was detected and nothing was filed, the Step 4.3 follow-ups line reads "No follow-up items detected."
If HHG was detected but no state code was found (so auto-creation was skipped): append "⚠️ HHG detected but no state code found in PR/issue — auto-creation skipped. Create the scraping and ETL issues manually once you know the state."

After the per-PR follow-up report: proceed immediately to **Part B** — do not ask.

### Part B — Full-session sweep

Part B sweeps the **whole session** for loose ends the per-PR detection in Part A cannot see — deferred ideas, stale process state, decisions worth persisting, drifted tickets, time-sensitive reminders. It produces two buckets — **Auto-handled** and **Needs your decision** — and a one-line **verdict**, all rendered in the Phase 4 final report (Step 4.3).

**Out of scope (explicit):** the sweep only runs as part of `/wrap`, which already requires a PR (Step 1.1 stops via its 1.1f no-candidates branch otherwise). Pure non-PR threads (issue-capture, PM-only, monitoring-only) never reach Part B — a standalone `/session-wrap` is a separate ticket, not this skill (issue #471 Notes).

**Safety boundaries for the entire sweep (non-negotiable — issue #471):**

- **Never auto-file a ticket without surfacing its body** in the report. Filing is unconditional (issue #633), so this boundary is what keeps it honest: every created issue's title + body is printed in the closing report.
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

Each entry should be one short bullet. **Cap each rendered section at 3–5 bullets** (issue #471 final-report-length note); if a category produces more, keep the top items, summarize the rest as one bullet ("+ N more — see session-state log"), and write the full list to `.prs["$PR_NUMBER"].wrap_sweep` in Step 3.13. **Exception:** auto-filed tickets are **never** capped away — every created issue's title + body must be surfaced (Step 3.7 contract), so they render in full regardless of the 3–5 cap (count summary-only bullets toward the cap, not auto-filed-ticket bullets).

#### Step 3.6: Category 1 — Session loose ends (transcript introspection)

This is the **load-bearing capability** (issue #471): scan **this session's conversation** for deferred work — there is no shell command that can read the transcript, so this is a model-introspection step.

**Heuristic (document for future maintainers):** review your own recent messages and tool-call history in this session for deferral signals — `later`, `TODO`, `follow-up`, `come back to`, `worth investigating`, `for now`, `deferred`, `out of scope`, `punt`, `we should eventually`, `not in this PR`, `leaving X for a separate change`. If transcript introspection is limited (e.g. after compaction), fall back to **tool-call history**: issues/PRs/files you touched, and any `// TODO` / `FIXME` you wrote into the diff. Scan the actual diff for new `TODO`/`FIXME` comments via `git diff origin/main...HEAD`.

Collect each loose end as `{summary, context, keywords}` where `keywords` is a 2–5 word phrase for the Step 3.7 dedup search. If none found, Category 1 produces no output.

#### Step 3.7: Category 2 — Ticket coverage (dedup, then file)

For **each** loose end from Step 3.6, dedup **before** filing anything (AC: never file a new ticket without checking first). Dedup runs in two stages:

**Stage 1 — cross-batch (this run).** Check the candidate against `WRAP_FILED_ISSUES` first. **Keyword overlap alone is not enough to collapse** — two unrelated findings about the same script share keywords, and collapsing them loses one silently. Apply the same bar as a cross-session strong match: same primary artifact, and the already-filed issue's stated scope covers this finding. Only then — **do not file**. Record it as `Collapsed into #{N} (filed earlier this run) — "<summary>"` in `SWEEP_AUTO_HANDLED`. This is what guarantees a loose end visible to both passes, or two findings in one sweep that restate each other, yield exactly one issue — and the collapse is reported rather than silently dropped.

**Stage 2 — cross-session (the repo).** Run the shared helper from Step 3.0, which scores **titles and bodies** of open plus recently-closed issues — the coverage a title-only search lacked when issue #647 duplicated issue #638:

```bash
dedup_search "$KEYWORDS"   # Step 3.0 — sets DEDUP_JSON, DUP_NUM, DUP_STATE, WEAK_DUP_NUM
```

Empty or unusable keywords make the helper exit `1` with `[]`, which means **file** — a loose end with no usable keywords is still a loose end, and the surfaced body plus the closing report give the user everything needed to retract it. Never read "couldn't search" as "duplicate found".

**Idempotency** is provided by the dedup search above, **not** by `SWEEP_PRIOR_FILED`: an issue auto-filed by a previous `/wrap` sweep is still an open issue, so a recurring loose end matches it through `issue-dedup.sh` and resolves to `DUP_NUM` — and because that issue was written from the same finding, the match is normally a **strong** one. `SWEEP_PRIOR_FILED` is a JSON array of **issue numbers** (not keywords) recorded by earlier sweeps; when `DUP_NUM` is one of those numbers, treat the loose end as **already handled by this sweep** — do not re-file it and do not re-surface it as a new "needs decision" item.

Then classify the top candidate **strong / weak / none** per `.claude/reference/autofile-dedup.md` and take exactly one of three paths — there is no fourth "ask the user" path:

- **Strong match** (`DUP_STATE` is `OPEN`, same primary artifact, a quotable criterion in that issue already covers the finding, `coverage ≥ 0.6`) → **do not file**. Comment the finding onto `#{DUP_NUM}` using the `autofile-dedup.md` template, and record `Appended to #{DUP_NUM} instead of filing — "<summary>"` in `SWEEP_AUTO_HANDLED`. If `DUP_NUM` is in `SWEEP_PRIOR_FILED`, **omit** entirely — this sweep already filed it on a prior run (idempotent), and re-commenting on every re-run would spam it. That omission is conditional on the strong-match test above having passed, `DUP_STATE` included: a prior-run issue that has since been **closed** fails criterion 1, so it falls through to the weak branch and is re-filed with the `Possibly duplicates #{DUP_NUM}` caveat rather than vanishing into a closed ticket.
- **Weak / ambiguous match**, or the top candidate is **CLOSED** (a closed issue cannot absorb a finding) → set `WEAK_DUP_NUM="$DUP_NUM"` and **file**, which puts `Possibly duplicates #{DUP_NUM} — <what is unclear>` in the body, and add `"<summary>" — filed, possible duplicate of #{DUP_NUM}` to `SWEEP_NEEDS_DECISION` so the ambiguity is visible outside the issue body too.
- **No match** → file exactly as before.

On both filing paths: **create the issue immediately**, **surface its title + body**, append it to `WRAP_FILED_ISSUES` with rationale `loose end: <summary>`, append the new number to `DEDUP_EXCLUDE`, and add it to `SWEEP_AUTO_HANDLED`. Use the same robust `gh issue create` guard as Step 3.3 (validate the parsed number; on failure record and continue — never abort Phase 3):

  ```bash
  POSSIBLE_DUP=""   # weak-match pointer only; empty on a clean no-match
  if [ -n "${WEAK_DUP_NUM:-}" ]; then
    POSSIBLE_DUP=$'\n\n'"Possibly duplicates #${WEAK_DUP_NUM} — <one line on the overlap and what is unclear>."
  fi
  if NEW_URL=$(gh issue create \
      --title "<derived title>" \
      --body "Follow-up surfaced by /wrap session sweep on PR #${PR_NUMBER}.${POSSIBLE_DUP}

  <context from transcript>

  _Filed via /wrap._" 2>&1); then
    NEW_NUM=$(echo "$NEW_URL" | grep -oE '[0-9]+$')
    if [ -n "$NEW_NUM" ]; then
      SWEEP_FILED="${SWEEP_FILED} ${NEW_NUM}"
      # Append {number, title, keywords, rationale} to WRAP_FILED_ISSUES.
    else
      echo "WARNING: created issue but could not parse number from: $NEW_URL"
    fi
  else
    echo "WARNING: gh issue create failed: $NEW_URL"
  fi
  ```

**No cap on how many issues one run may file.** A cap would reintroduce the confirmation round-trip this design removes; instead every filing is announced in full (Step 4.3), and closing an unwanted issue is one command. Never file without printing the body.

#### Step 3.8: Category 3 — External / process state

Read session/process state and clean up only what is **provably dead**; surface the rest.

```bash
[ -n "$SESSION_STATE_SH" ] && POLLING_JOBS=$("$SESSION_STATE_SH" --get '.polling_jobs' 2>/dev/null || echo "null")
[ -n "$SESSION_STATE_SH" ] && ACTIVE_AGENTS=$("$SESSION_STATE_SH" --get '.active_agents' 2>/dev/null || echo "null")
```

- **Dead `/loop` jobs (auto-stop).** For each non-durable `/loop` poll in `polling_jobs[]` (or per-PR `babysit` watcher) whose target PR is **merged or closed**, stop it: set the watcher's stop flag (`.prs["$N"].babysit.stop_requested=true` via `session-state.sh --set`, same as `/babysit-pr-stop`) so the next tick exits, and record `Stopped stale /loop job (PR #N watcher — PR already merged)` in `SWEEP_AUTO_HANDLED`. The PR just merged in Phase 2 is the most common case.
- **Stale handoffs (auto-delete).** Scan both the legacy flat glob (`~/.claude/handoffs/pr-*.json`) and the scoped layout (`~/.claude/handoffs/*/*/pr-*.json`, issue #655). For each file, parse the PR number `N` from the filename or `.pr_number` field. If PR `N` is **merged** (`gh pr view N --json state --jq '.state == "MERGED"'`), resolve the canonical path with `handoff-state.sh [--owner-repo <owner_repo_from_file>] --path N` and delete via `handoff-state.sh [--owner-repo ...] --delete N`, then record `Deleted handoff file pr-N-handoff.json (PR merged)` in `SWEEP_AUTO_HANDLED`. Deleting an already-gone file is a no-op (idempotent — `handoff-state.sh --delete` exits 0 when the file is absent). Do **not** delete handoffs for open/un-merged PRs. Never `rm -f` the file directly — that bypasses the shared state-lock.sh advisory lock (issue #682).
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
  # filed_issues: UNION this run's auto-filed numbers with any recorded by a
  # prior sweep — never overwrite. A re-run with no new filings (empty
  # SWEEP_FILED) must NOT erase the earlier record, or idempotency breaks and
  # the next run re-files duplicates.
  NEW_FILED_JSON=$(printf '%s\n' $SWEEP_FILED | jq -R 'select(length>0)' | jq -cs 'map(tonumber? // .)')
  PRIOR_FILED_JSON="$SWEEP_PRIOR_FILED"
  case "$PRIOR_FILED_JSON" in ""|null) PRIOR_FILED_JSON='[]' ;; esac
  FILED_JSON=$(jq -cn --argjson a "$PRIOR_FILED_JSON" --argjson b "$NEW_FILED_JSON" '($a + $b) | unique')
  # Persist the FULL sweep, not just filed numbers, so the report's
  # "+ N more — see session-state log" overflow pointer resolves to real data.
  # SWEEP_AUTO_HANDLED / SWEEP_NEEDS_DECISION are newline-separated bullets.
  AUTO_JSON=$(printf '%s\n' "$SWEEP_AUTO_HANDLED" | jq -R 'select(length>0)' | jq -cs .)
  NEEDS_JSON=$(printf '%s\n' "$SWEEP_NEEDS_DECISION" | jq -R 'select(length>0)' | jq -cs .)
  # Do NOT swallow this write: wrap_sweep.filed_issues is the idempotency
  # record, so a silent failure risks re-filing duplicate tickets next run.
  # Surface it loudly (the merge already succeeded, so don't abort wrap —
  # the Step 3.7 dedup search is the backstop, but the user must know the
  # record may be stale).
  if ! "$SESSION_STATE_SH" \
    --set ".prs[\"$PR_NUMBER\"].wrap_sweep.swept_at=\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"" \
    --set ".prs[\"$PR_NUMBER\"].wrap_sweep.filed_issues=$FILED_JSON" \
    --set ".prs[\"$PR_NUMBER\"].wrap_sweep.auto_handled=$AUTO_JSON" \
    --set ".prs[\"$PR_NUMBER\"].wrap_sweep.needs_decision=$NEEDS_JSON"; then
    echo "WARNING: failed to persist wrap_sweep state — a re-run may not be idempotent (could re-file sweep tickets); the Step 3.7 dedup search still guards against open duplicates." >&2
  fi
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

**If trivial:** no lessons to capture — set `WRAP_LESSONS_COUNT=0` and skip to Step 4.3. (Verbose prints "Clean session — no lessons to capture."; terse folds it into the one-line lessons ack.)

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

**The memory writes above happen in both modes.** Record the number saved as `WRAP_LESSONS_COUNT`. How the outcome is *presented* depends on the output mode:

- **Verbose (`--verbose`):** print the full block —

  ```
  ## Session Lessons

  ### Saved to memory:
  1. **<title>** — <summary> (saved as <type>)

  ### Observations (not saved):
  - <things noted but not actionable>
  ```

- **Terse (default):** suppress the block; carry a one-line acknowledgment into the Step 4.3 terse report — `{WRAP_LESSONS_COUNT} lesson(s) captured to memory` (or `Clean session — no lessons` when `WRAP_LESSONS_COUNT` is 0).

After lessons (or skip): emit the final report below — do not ask.

### Step 4.3: Final report

`/wrap` renders one of two **success** reports based on the output mode parsed in Step 1.1; the **Blocker path** below prints in *both* modes. The mode governs only the verbosity of the success report — it never suppresses a stop.

#### Terse report (default)

Two concise blocks drawn from the already-structured data (`WRAP_FILED_ISSUES`, the Step 3.13 verdict, `WRAP_LESSONS_COUNT`, the Step 2.5 statuses), plus at most two one-line acks — nothing else:

```
## Wrapped up

**Merged:** PR #{N} ({title}) — {≤3 sentences on the gist of what changed}.{ Only when main-sync was noteworthy — an `aborted:` outcome or a quarantine actually ran: " Main: {one-line status}."}

**Follow-ups:** {either "Opened [#{a}](url) — {one line}; [#{b}](url) — {one line}." listing every `WRAP_FILED_ISSUES` entry as number + one-line + link (≤3 sentences), or "No follow-ups opened."}{ When any filing was suppressed as a duplicate: " {M} finding(s) appended to existing issues." — never drop a suppressed finding silently.}

{lessons ack, one line: "{WRAP_LESSONS_COUNT} lesson(s) captured to memory." | "Clean session — no lessons."}
{sweep line — ONLY when the Step 3.13 verdict is "N items pending your decision before archive": "Session sweep: {N} item(s) pending your decision — run `/wrap --verbose` for detail." Omit this line entirely on "Clear to archive".}
```

Rules for the terse report:

- **Merged ≤3 sentences; Follow-ups ≤3 sentences.** These two blocks are the whole point of terse mode — keep them skimmable.
- **Every opened issue is listed** (number + one-line + clickable link) from `WRAP_FILED_ISSUES`; an opened issue that isn't listed is indistinguishable from one silently dropped. However many were opened, list them all (they are the payload), one line each.
- **Suppressed-as-duplicate findings are never silently dropped** — surface the count in one clause. The full "who deferred to which issue" detail lives in the verbose report and `session-state.json`.
- The **sweep verdict** appears only when decisions are pending; a routine "Clear to archive" adds no line. Full Auto-handled / Needs-your-decision detail is persisted in Step 3.13 and shown under `--verbose`.

#### Blocker path (both modes)

If `/wrap` stopped instead of merging, print a **single short line** naming the reason. Reuse the canonical stop strings already defined elsewhere in this skill (Phase Transition Autonomy table; Step 1.1f no-candidates messages; Step 2.1 stop conditions) rather than inventing new wording; under `--verbose`, append the full `WRAP_RECOVERY_AUDIT` / `missing` detail:

- **Merge gate not met after the recovery cap** → `Merge blocked: {last missing summary}. Re-run /wrap or /fixpr.`
- **`mergeable == CONFLICTING`** → `Merge blocked: merge conflicts — run /merge-conflict.`
- **Human `CHANGES_REQUESTED` on HEAD** → `Merge blocked: changes requested by {login(s)}.`
- **No PR found** → the Step 1.1f message verbatim ("This thread has no coding work…" or "No PR found for the current branch…").

The blocker line is **mandatory in terse mode** — terseness must never swallow a stop.

#### Verbose report (`--verbose`)

Emit the full multi-section report with the existing capping/omission rules unchanged:

```
## Wrap-Up Complete

- **PR #{N}** merged ({title})
- **Main quarantine** {QUARANTINE_STATUS from Step 2.5 — e.g. "clean" (literal output of `dirty-main-guard.sh --check` on a clean main), "quarantined: recovery/dirty-main-20260424-003012 (uncommitted)", or "no-op: main is clean" (only produced if `--quarantine` ran on an already-clean tree)}
- **Main branch** {MAIN_SYNC_STATUS from Step 2.5 — e.g. "reset abc1234 → def5678", "up to date (abc1234)", "aborted: local main has 1 unpushed commit(s) — inspect: git log origin/main..main, resolve manually before re-running", or "failed: ..."}
- **Follow-ups:** {skipped-as-duplicate items and any creation failures from Part A, or "No follow-up items detected." — filed issues are listed under "Issues filed" below, not here}

## Issues filed

- [#{number}](https://github.com/{owner}/{repo}/issues/{number}) — {title} — {rationale}
- [#{number}](https://github.com/{owner}/{repo}/issues/{number}) — {title} — {rationale}

{One line per `WRAP_FILED_ISSUES` entry, Part A and Part B together, in one message. Omit the whole section only when the registry is empty.}

## Filings suppressed as duplicates

- Appended to [#{N}](https://github.com/{owner}/{repo}/issues/{N}) instead of filing — "{finding summary}"
- Collapsed into [#{N}](https://github.com/{owner}/{repo}/issues/{N}) (filed earlier this run) — "{finding summary}"

{One line per suppressed filing, from Part A's Step 3.3 and Part B's Step 3.7 Stage 1/Stage 2 strong-match branches. Omit the whole section only when nothing was suppressed. A suppressed filing that does not appear here is indistinguishable from a finding that was silently dropped — see `.claude/reference/autofile-dedup.md`.}

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

**Rendering rules for the verbose report's Session sweep section** (terse mode uses only the single verdict line from the Terse report above):

- Cap **Auto-handled** and **Needs your decision** at **3–5 bullets** each; if more, show the top items and summarize the remainder as one bullet linking to `.prs["$PR_NUMBER"].wrap_sweep`. **Auto-filed tickets are exempt from the cap** — every created issue's title + body is surfaced in full (never collapsed into the "+ N more" summary), since silently hiding a ticket you just created would violate the Step 3.7 surface-the-body contract.
- The **Issues filed** section is never capped or truncated, however many issues the run opened: one line per issue, each a clickable link with its number, title, and one-line rationale. An issue filed but not reported is the one failure mode this design cannot tolerate — it can't be retracted if it was never seen.
- The **Filings suppressed as duplicates** section is likewise never capped: every finding the dedup check kept out of a new issue names the issue it deferred to (issue #652). Suppression is the higher-risk direction — a wrongly filed ticket is visible, a wrongly suppressed finding is not — so it always renders in full.
- Omit an empty subsection rather than printing "none".
- The **Verdict** line is mandatory and is one of the two canonical strings only.
- If Part B was skipped (e.g. Phase C subagent with an empty transcript and no state findings), still print `### Verdict` → `Clear to archive`.

The worktree and feature branch are intentionally left in place. They are reaped out-of-band by `/pm-update`'s stale-cleanup pass once they age past the threshold (default 7 days, configurable via `STALE_DAYS`). See `.claude/scripts/stale-cleanup.sh --help`.
