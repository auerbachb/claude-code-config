---
name: fixpr
description: Bounded-convergence PR cleanup — audit every review thread + every CI check-run, fix all issues, push once per sweep, dismiss stale bot CHANGES_REQUESTED on old commits, resolve all threads via GraphQL, then wait (capped) for bot verdicts + CI on the new SHA, re-sweeping on new findings up to 5 iterations. Zero uncollapsed threads and zero failing checks when done.
---

> **Human output:** Follow `.claude/reference/decision-only-output.md` over older heartbeat, timestamp, mandatory-table, startup/teardown, or report examples below. Routine checks, dispatches and automatic recovery stay silent; immediately surface owner-action blockers, safety events or exhausted recovery. Explicit status/verbose requests retain tables and reports. Preserve every machine footer, full diagnostic log, gate result and resumable state; use bounded JSON projections before targeted evidence recovery.

Bounded-convergence cleanup of the current branch's PR (issue #454 added the post-push review-wait loop to the original single-pass design). After this completes:

1. **Zero uncollapsed review threads** in the browser (all resolved via GraphQL)
2. **Zero failing CI checks** (all fixed and passing)
3. **Every finding replied to** with what was done
4. **A definitive bot verdict on the final SHA** — or an explicit cap-hit report naming what is still pending (never a silent "we pushed, bye" exit)

## Portable helper resolution

Resolve the helpers used by executable examples before Step 0. The handoff-path helper has a documented legacy fallback; every write/safety helper is required.

```bash
resolve_script() {
  local name="$1" candidate
  for candidate in \
    "${HOME:+$HOME/.claude/skills-worktree/.claude/scripts/$name}" \
    "${HOME:+$HOME/.claude/scripts/$name}" \
    ".claude/scripts/$name"; do
    if [[ -x "$candidate" ]]; then echo "$candidate"; return 0; fi
  done
  return 1
}
PR_AUTHORSHIP_SH=$(resolve_script pr-authorship.sh || true)
HANDOFF_STATE_SH=$(resolve_script handoff-state.sh || true)
RECOVERY_EVIDENCE_SH=$(resolve_script recovery-evidence.sh || true)
REPLY_THREAD_SH=$(resolve_script reply-thread.sh || true)
RESOLVE_REVIEW_THREADS_SH=$(resolve_script resolve-review-threads.sh || true)
DIFF_SURVIVAL_SH=$(resolve_script diff-survival-check.sh || true)
LOCAL_REVIEW_SH=$(resolve_script local-review.sh || true)
CLEAN_BEHIND_SH=$(resolve_script clean-behind-check.sh || true)
PAID_GRANT_SH=$(resolve_script paid-review-grant.sh || true)  # owner-approved paid reviews (#1898)
ADMIN_MERGE_SH=$(resolve_script admin-merge.sh || true)
MERGE_GATE_SH=$(resolve_script merge-gate.sh || true)
[[ -n "$PR_AUTHORSHIP_SH" ]] || { echo "ERROR: pr-authorship.sh not found (checked all three paths) — fix workflow authorship gate unavailable" >&2; exit 1; }
[[ -n "$REPLY_THREAD_SH" ]] || { echo "ERROR: reply-thread.sh not found (checked all three paths) — review replies unavailable" >&2; exit 1; }
[[ -n "$RESOLVE_REVIEW_THREADS_SH" ]] || { echo "ERROR: resolve-review-threads.sh not found (checked all three paths) — thread resolution unavailable" >&2; exit 1; }
[[ -n "$DIFF_SURVIVAL_SH" ]] || { echo "ERROR: diff-survival-check.sh not found (checked all three paths) — rebase survival gate unavailable" >&2; exit 1; }
[[ -n "$LOCAL_REVIEW_SH" ]] || { echo "ERROR: local-review.sh not found (checked all three paths) — local review unavailable" >&2; exit 1; }
[[ -n "$CLEAN_BEHIND_SH" ]] || { echo "ERROR: clean-behind-check.sh not found (checked all three paths) — clean-BEHIND verification unavailable" >&2; exit 1; }
[[ -n "$ADMIN_MERGE_SH" ]] || { echo "ERROR: admin-merge.sh not found (checked all three paths) — clean-BEHIND recovery unavailable" >&2; exit 1; }
[[ -n "$MERGE_GATE_SH" ]] || { echo "ERROR: merge-gate.sh not found (checked all three paths) — residual merge verification unavailable" >&2; exit 1; }
[[ -n "$RECOVERY_EVIDENCE_SH" ]] || { echo "ERROR: recovery-evidence.sh not found (checked all three paths) — wait capture unavailable; no clean verdict" >&2; exit 1; }
if [[ -z "$HANDOFF_STATE_SH" ]]; then
  echo "DEGRADED: handoff-state.sh not found (checked all three paths) — namespaced handoff path unavailable, continuing with legacy flat path" >&2
fi
```

### Batching before burning CR quota (Issue #28)

**Coalesce locally first:** Before opening `/fixpr` on minor iterations, run the dual-CLI local review (**`"$LOCAL_REVIEW_SH" --tool coderabbit --scope uncommitted`** + **`--tool codeant --scope uncommitted`**) per `cr-local-review.md` on uncommitted changes when feasible. The wrapper returns one compact line per CLI; the raw capture stays at its `log_path`.

**Coalesce inside `/fixpr`:** Steps 1–3 intentionally gather **every** unresolved finding + every failing CI check, then fix **all** actionable items and **`git push` once**. Never push once per finding. One `/fixpr` cycle should produce **at most one** consume-side CR review per completed push (tracked below).

## How this skill is structured

[Workflow history and rationale](../../reference/fixpr-workflow-history.md)

> **pr-state.sh first (NON-NEGOTIABLE):** Before calling `gh api .../pulls/{N}/reviews`, `pulls/{N}/comments`, or `issues/{N}/comments` directly, call `pr-state.sh --pr N` first and read bounded `jq` projections of the cached JSON bundle; select specific finding IDs/bodies only for diagnosis or replies. Inline `gh api` calls for these three endpoints are permitted only inside `reviewer-activity.sh` and `fixpr-reviewer-triggers.sh` (Step 3b delegates), using their post-push timestamp filter, and Step 5d's projected all-author invitation check. Every other polling or review-state lookup MUST go through `pr-state.sh`.

| Step | Kind | Done by |
|------|------|---------|
| 0a. Resolve target PR (arg or infer) | Judgment + Mechanical | AI thread scan + `pr-state.sh --infer-candidates` |
| 0. Gather PR state | Mechanical | `pr-state.sh` writes `/tmp/pr-state-<PR>-<epoch>.json` |
| 1. Classify review findings | Judgment | AI reads JSON + source files |
| 2. Classify CI failures | Judgment | AI reads `check-runs/<id>.output.summary` |
| 3. Fix & push | Judgment | AI edits files, commits, pushes |
| 3a. Dismiss stale bot `CHANGES_REQUESTED` | Mechanical | `dismiss-stale-bot-changes.sh` after push when `DID_PUSH=1`; optional `--handoff-file` append |
| 3b. Trigger missing AI reviewers | Mechanical | wait 2 minutes, then `fixpr-reviewer-triggers.sh` on the pushed SHA: no review policy → post triggers for missing free bots, `@cursor review` only by spending an owner grant for that SHA; tier-aware repo → only what `review-triggers-allowed.sh` allows |
| 4. Reply & resolve | Mechanical | `gh api` calls against IDs from the JSON |
| 4c. Post-push thread verify (if Step 3 pushed) | Mechanical | Re-fetch threads on new HEAD; explicitly resolve any touched thread still `isResolved: false`, then `--verify-only` |
| 4d. Review-wait loop | Mechanical | Poll `pr-state.sh` on the pushed SHA every 30–60s, capped at 20 min; early-exit on full bot+CI verdict; new findings → next sweep |
| 5. Verify | Mechanical | Re-run `pr-state.sh --since $RUN_STARTED_AT` |
| 6. Merge blockers | Judgment | AI reads `.merge_state` from the JSON |
| 7. Final summary | Judgment | AI emits the status |

Execute the steps sequentially. Steps 0–4c form one **fix sweep**. After a sweep that pushed, Step 4d waits — bounded — for bot verdicts and CI on the **new HEAD SHA**; when new findings or blocking CI arrive mid-wait, start the next sweep at Step 0 (outer cap: `FIXPR_MAX_ITERATIONS`, default 5). `/fixpr` exits when the wait predicate is clean, a cap fires, or a non-loopable status arises (conflicts, human changes requested, stuck threads). This in-turn loop runs within a single agent turn — no `/loop`, `CronCreate`, or `ScheduleWakeup`.

**Environment knobs:**

| Variable | Default | Purpose |
|----------|---------|---------|
| `FIXPR_WAIT_CAP_SECS` | `1200` | Hard cap per wait iteration (20 min) |
| `FIXPR_WAIT_POLL_SECS` | `60` | Poll cadence inside the wait loop (valid range 30–60) |
| `FIXPR_MAX_ITERATIONS` | `5` | Outer cap on fix-sweep + wait iterations |

---

## Step 0: Run the initial audit

Initialize the wait-loop counters **once per `/fixpr` invocation** (NOT per sweep — re-entering Step 0 for sweep 2+ must preserve them):

```bash
FIXPR_WAIT_CAP_SECS="${FIXPR_WAIT_CAP_SECS:-1200}"
FIXPR_WAIT_POLL_SECS="${FIXPR_WAIT_POLL_SECS:-60}"
FIXPR_MAX_ITERATIONS="${FIXPR_MAX_ITERATIONS:-5}"
# Clamp cadence to the 30–60s contract
(( FIXPR_WAIT_POLL_SECS < 30 )) && FIXPR_WAIT_POLL_SECS=30
(( FIXPR_WAIT_POLL_SECS > 60 )) && FIXPR_WAIT_POLL_SECS=60
FIXPR_WAIT_ITER="${FIXPR_WAIT_ITER:-0}"          # wait iterations entered so far
FIXPR_TOTAL_WAIT_SECS="${FIXPR_TOTAL_WAIT_SECS:-0}"    # cumulative wall-clock wait across iterations
FIXPR_WAIT_FINAL="${FIXPR_WAIT_FINAL:-}"        # clean | cap-exhausted | new-findings-pending (set by 4d / outer-cap logic)
```

Locate `pr-state.sh`. Prefer the global install; fall back to the in-repo copy when developing the skill itself. The legacy `audit.sh` wrapper is kept for back-compat — call it only if `pr-state.sh` cannot be found.

```bash
SCRIPT=""
for candidate in \
  "${HOME:+$HOME/.claude/skills-worktree/.claude/scripts/pr-state.sh}" \
  "${HOME:+$HOME/.claude/scripts/pr-state.sh}" \
  ".claude/scripts/pr-state.sh" \
  "${HOME:+$HOME/.claude/skills/fixpr/audit.sh}" \
  ".claude/skills/fixpr/audit.sh"; do
  if [[ -x "$candidate" ]]; then
    SCRIPT="$candidate"
    break
  fi
done
if [[ -z "$SCRIPT" ]]; then
  echo "ERROR: pr-state.sh not found (checked ~/.claude/scripts/, ~/.claude/skills-worktree/.claude/scripts/, and in-repo .claude/scripts/)" >&2
  exit 1
fi
```

### Step 0a: Resolve the target PR (explicit argument → thread/session inference)

`/fixpr` may be invoked **with** a PR (`/fixpr <url>` or `/fixpr <N>`) or **with no argument**. Resolve the target into `$PR_NUMBER_ARG` *before* calling `pr-state.sh`. The session-state half of this inference is shared verbatim with `/wrap` via `pr-state.sh --infer-candidates` — do not re-implement it.

**1. Capture and parse the explicit argument.** Put whatever the user typed after `/fixpr` into `$FIXPR_ARG` (empty when none). Accept a full PR URL or a bare PR number:

```bash
PR_NUMBER_ARG=""
if [[ -n "${FIXPR_ARG:-}" ]]; then
  if [[ "$FIXPR_ARG" =~ ^https?://github\.com/[^/]+/[^/]+/pull/([0-9]+) ]]; then
    PR_NUMBER_ARG="${BASH_REMATCH[1]}"          # extracted from pull/<N>
  elif [[ "$FIXPR_ARG" =~ ^[0-9]+$ ]]; then
    PR_NUMBER_ARG="$FIXPR_ARG"                   # bare positive integer
  else
    echo "ERROR: /fixpr argument not recognized: '$FIXPR_ARG' (expected a PR URL or number)" >&2
    exit 2
  fi
  echo "[CONTEXT] Using explicitly provided PR #$PR_NUMBER_ARG"
fi
```

**2. When no argument was given, infer the target.** Skip this entire step when `$PR_NUMBER_ARG` is already set. Build a candidate set from two sources, then resolve:

- **Thread scan (AI layer).** Read back through *this* conversation for the most recent `/fixpr <url-or-number>` and `/wrap <url-or-number>` invocations and any PR the thread just operated on (pushed to, audited). Extract PR numbers from the `pull/<N>` pattern. Record them **in order, most-recently-mentioned first** — thread recency is the strongest signal.
- **Session state (script layer).** Pull the PRs this session is actively tracking, newest activity first:

```bash
CANDIDATES_JSON=$("$SCRIPT" --infer-candidates 2>/dev/null || echo "[]")
# Prefer same-repo candidates; same_repo==null means "unknown repo, keep it".
SESSION_CANDIDATES=$(jq -c '[ .[] | select(.same_repo != false) ]' <<<"$CANDIDATES_JSON")
jq -r '.[] | "  session-candidate: #\(.number) (phase=\(.phase // "?"), needs=\(.needs // "?"), last_action=\(.last_action_at // "?"))"' <<<"$SESSION_CANDIDATES"
```

`--infer-candidates` reads `~/.claude/session-state.json`. A nonzero exit leaves thread-only inference.

**3. Resolve candidates → `$PR_NUMBER_ARG` (or prompt).** Merge the thread list and `SESSION_CANDIDATES` into a unique set keyed by PR number, tracking each PR's source(s) (`thread`, `session`) and recency:

| Situation | Action |
|-----------|--------|
| **Exactly one unique candidate** (from either source) | Select it. Set `PR_NUMBER_ARG=<N>` and print the `[INFERRED]` line (formats below). Proceed — do **not** ask. |
| **Multiple candidates, one clearly most recent** | Pick the most-recently-mentioned. **Thread recency outranks session timestamps:** if any PR appeared in the thread scan, the newest thread mention wins; otherwise use the session candidate with the newest `last_action_at` (only when it is strictly newer than the next — not tied). Set `PR_NUMBER_ARG`, print the `[INFERRED]` line **and** the one-line `Also tracking:` note. |
| **Genuinely ambiguous** (two+ tied on recency) | Do **not** guess. Print `[CONTEXT] No PR argument and no branch PR; multiple candidates:` followed by the candidate list with sources, and ask the user which PR they meant. Leave `PR_NUMBER_ARG` empty. |
| **No candidates at all** | Leave `PR_NUMBER_ARG` empty and fall through to branch auto-detection below — `pr-state.sh` with no `--pr` either finds the branch's PR or exits `3`/`4` and you report it. |

`[INFERRED]` log formats (print exactly one, before the `[CONTEXT]`/audit output below):

```text
[INFERRED] PR #462 from thread context (last /fixpr invocation)
[INFERRED] PR #462 from session state (most recent activity at 2026-05-04T16:48:00Z)
[INFERRED] PR #462 (most recent of 2 active PRs); override with /fixpr #458 if needed
```

When inference picked from multiple candidates, append the override hint on its own line (one line; annotate each other PR with its session `needs`/`phase`):

```text
Also tracking: PR #458 (bugbot_review_poll), PR #445 (cr_confirmation_pass)
```

> **Authorship guard (issue #733, `safety.md`) — gate before Step 0c.** Once `$PR_NUMBER_ARG` is resolved, confirm you authored it:
> ```bash
> "$PR_AUTHORSHIP_SH" "$PR_NUMBER_ARG"   # exit 0 = yours
> ```
> Not yours (exit 1) or undetermined (exit 4) → **stop** with one line: "PR #$PR_NUMBER_ARG is authored by someone else — the authorship guard blocks automated writes; name this PR explicitly to override." Continue only under an explicit per-PR user override (say you are operating under it). Do this **before** Step 0c, since the pre-flight posts reviewer triggers.

### Step 0c: Pre-flight — draft→ready + reviewer trigger (issue #493)

Run the shared pre-flight **before** the audit so the PR is out of draft and each conditionally-triggered reviewer (CodeAnt, CodeRabbit, Cursor) gets a recorded per-reviewer status on the current SHA — engaged (already present or triggered), skipped (excluded by the PR's review tier — on `ci-only`, all three — tier-deferred, rate-capped, or awaiting owner approval for BugBot), or trigger-failed — before any finding-classification work begins. Use `pr-preflight.sh` for the draft flip and reviewer triggers.

```bash
PREFLIGHT_SH=""
for candidate in \
  "${HOME:+$HOME/.claude/skills-worktree/.claude/scripts/pr-preflight.sh}" \
  "${HOME:+$HOME/.claude/scripts/pr-preflight.sh}" \
  ".claude/scripts/pr-preflight.sh"; do
  if [[ -x "$candidate" ]]; then PREFLIGHT_SH="$candidate"; break; fi
done

# Resolve a PR number for the pre-flight. Prefer the explicit/inferred arg from
# Step 0a; otherwise fall back to the current branch's PR (the same PR the
# Step 0b audit will resolve). Empty ⇒ no PR yet — skip; Step 0b reports it.
PREFLIGHT_PR="${PR_NUMBER_ARG:-$(gh pr view --json number --jq .number 2>/dev/null || true)}"

PREFLIGHT_SUMMARY_JSON=""
if [[ -n "$PREFLIGHT_SH" && -n "$PREFLIGHT_PR" ]]; then
  PREFLIGHT_OUT=$("$PREFLIGHT_SH" "$PREFLIGHT_PR") || echo "[PREFLIGHT] pr-preflight.sh exited non-zero (exit $?) — continuing to audit" >&2
  echo "$PREFLIGHT_OUT"
  PREFLIGHT_SUMMARY_JSON=$(sed -n 's/^PREFLIGHT_SUMMARY: //p' <<<"$PREFLIGHT_OUT")
elif [[ -z "$PREFLIGHT_SH" ]]; then
  echo "[PREFLIGHT] pr-preflight.sh not found — skipping draft/reviewer pre-flight (install from repo .claude/scripts/)"
fi
```

`pr-preflight.sh` is idempotent and rate-cap safe: it marks the PR ready only when **you** authored it, never overrides someone else's intentional draft, never triggers Greptile, posts `@cursor review` only by spending an owner grant for HEAD, and skips `@coderabbitai full review` (still posting the other free reviewers) when `cr-review-hourly.sh` reports the cap hit. On a PR that is already ready with every reviewer already engaged **on the current HEAD SHA** or skipped (BugBot without owner approval and no grant, a tier-excluded reviewer) it prints `Pre-flight clean — proceeding` and does nothing — so a clean pre-flight does **not** mean any reviewer was engaged (on `ci-only`, none is). The helper evaluates engagement on current HEAD and applies the same trigger gates when earlier artifacts are stale. Keep `$PREFLIGHT_SUMMARY_JSON` for the Step 7 "Pre-flight" line.

### Step 0b: Run the audit

Call `pr-state.sh` with the resolved PR when inference or an explicit argument produced one; otherwise fall back to branch auto-detection:

```bash
if [[ -n "$PR_NUMBER_ARG" ]]; then
  AUDIT=$("$SCRIPT" --pr "$PR_NUMBER_ARG")
else
  AUDIT=$("$SCRIPT")
fi
```

If `pr-state.sh` itself exits non-zero it prints the reason to stderr. Stop and report. Exit codes: `0` OK, `2` usage error, `3` no branch and no `--pr`, `4` PR closed/not found, `5` gh/network error. With Step 0a in place, exit `3` (no branch and no `--pr`) only reaches you when inference also found **no** candidate.

Pull the values that the later steps need out of the JSON once:

```bash
PR_NUMBER=$(jq -r '.pr.number' "$AUDIT")
OWNER=$(jq -r '.pr.owner' "$AUDIT")
REPO=$(jq -r '.pr.repo' "$AUDIT")
# Scope the Step 3a handoff to the PR repository.
OWNER_REPO="$OWNER/$REPO"
BRANCH=$(jq -r '.pr.branch' "$AUDIT")
HEAD_SHA=$(jq -r '.pr.head_sha' "$AUDIT")
RUN_STARTED_AT=$(jq -r '.run_started_at' "$AUDIT")
```

Print the context and a one-line audit summary:

```bash
jq -r '
  "[CONTEXT] PR #\(.pr.number) on \(.pr.owner)/\(.pr.repo) (branch: \(.pr.branch), HEAD: \(.pr.head_sha[0:7]))",
  "[AUDIT] Threads: \(.threads.total) total — \(.threads.unresolved_count) unresolved, \(.threads.resolved_count) resolved",
  "[AUDIT] CI checks: \(.check_runs.total) total (\(.check_runs.passing) passing, \(.check_runs.failing) failing, \(.check_runs.in_progress) in-progress)"
' "$AUDIT"

jq -r '.threads.unresolved[] | "  unresolved: \(.comments.nodes[0].path // "?"):\(.comments.nodes[0].line // "?") — \(.comments.nodes[0].body | split("\n")[0] | .[:120])"' "$AUDIT"
jq -r '.check_runs.failing_runs[] | "  failing: \(.name) — \(.title // "no title")"' "$AUDIT"
```

---

## Step 1: Classify every unresolved finding (judgment)

For each entry in `.threads.unresolved`:

1. Read the first comment (`.comments.nodes[0].body`) plus its `path` + `line`
2. Read the current file at that location
3. Auto-decide the disposition:
   - **fix** — code still has the issue, or the conservative change is safe → must fix
   - **decline-high-confidence** — finding is invalid, obsolete, or intentionally not applicable with confidence >= 50% → reply with rationale and resolve silently
   - **surface-low-confidence** — confidence < 50% because this is a genuine design/product/user-preference decision → still reply and resolve on GitHub, then list it in the final chat summary with rationale and override prompt
   - **already-fixed** — code no longer matches the finding → resolve only
   - **outdated** — file/line no longer exists → resolve only

Do not ask the user before deciding. Every thread touched by `/fixpr` must end resolved on GitHub, whether the decision was fix or decline.

Print the numbered list:

```text
[FINDING 1] fix — src/foo.ts:42 — "unused import" (coderabbitai[bot]) — confidence 90%
[FINDING 2] decline-high-confidence — src/bar.ts:10 — "missing null check" (coderabbitai[bot]) — confidence 80%
[FINDING 3] surface-low-confidence — src/baz.ts:55 — "change retry policy" (cursor[bot]) — confidence 40%
[FINDING 4] outdated — src/deleted.ts:5 — file removed (greptile-apps[bot])
```

Keep running counters for final chat output:

- `FIXED_COUNT`: findings classified `fix` and changed in code
- `DECLINED_SILENT_COUNT`: findings classified `decline-high-confidence`, `already-fixed`, or `outdated`
- `SURFACED_COUNT`: findings classified `surface-low-confidence`

For every `surface-low-confidence` item, capture file, finding, decision, rationale, alternative considered, and the override prompt for Step 7.

---

## Step 2: Classify every CI failure (judgment)

For each entry in `.check_runs.failing_runs` (blocking conclusions: `failure`, `timed_out`, `action_required`, `startup_failure`, `stale`):

1. Fetch the detailed output:
   ```bash
   gh api "repos/$OWNER/$REPO/check-runs/<id>" --jq '.output.summary, .output.text'
   ```
   If both are empty, follow `.html_url` to the run log.
2. Classify:
   - **lint / typecheck** — read the errors, fix the code
   - **test** — read the failing output, fix the code or test
   - **build** — read the build error, fix the code
   - **security / audit** (gitleaks, npm audit, etc.) — read the finding, fix
   - **infra / transient** (timeout, runner failure) — note it, cannot fix locally

Print per check:

```text
[CI:FAIL] "lint" — 3 errors in src/foo.ts → fixing
[CI:INFRA] "deploy-preview" — timed_out (transient)
```

**Every entry in `.check_runs.failing_runs` must be accounted for — do not skip any.**

---

## Step 3: Fix everything, push once

Combine actionable findings + non-transient CI failures into a single commit.

Rules:

- **Never suppress linter errors** (`eslint-disable`, `@ts-ignore`, `@ts-expect-error`, `noqa`) — fix the actual code.
- Verify each fix against the original message — partial fixes count as unresolved.
- If ambiguous, fix conservatively.

```bash
git add <modified files>
git commit -m "fix: resolve all review findings and CI failures

Fixes N review findings and M CI errors."
PUSHED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
git push
DID_PUSH=1
```

Print: `[PUSH] committed and pushed (SHA: $(git rev-parse --short HEAD))`.

If nothing needed fixing (all already-fixed/outdated, CI all green), skip the commit/push and set `DID_PUSH=0` (do not run Step 4c).

**Record hourly CR consumption** after a successful push (atomic budget guard):

```bash
CR_HOURLY_SCRIPT=""
for candidate in \
  "${HOME:+$HOME/.claude/skills-worktree/.claude/scripts/cr-review-hourly.sh}" \
  "${HOME:+$HOME/.claude/scripts/cr-review-hourly.sh}" \
  ".claude/scripts/cr-review-hourly.sh"; do
  if [[ -x "$candidate" ]]; then
    CR_HOURLY_SCRIPT="$candidate"
    break
  fi
done
if [[ -n "$CR_HOURLY_SCRIPT" ]]; then
  if ! CR_SNAPSHOT="$("$CR_HOURLY_SCRIPT" --consume)"; then
    echo "[CR-HOURLY] WARNING: hourly CR budget appears exhausted — $CR_SNAPSHOT"
    echo "[CR-HOURLY] Prefer local coderabbit review + cooldown before more pushes; see cr-github-review.md"
  else
    echo "[CR-HOURLY] recorded push-level review event — $CR_SNAPSHOT"
  fi
else
  echo "[CR-HOURLY] cr-review-hourly.sh not found — skip consumption tracking"
fi
```

---

## Step 3a: Dismiss stale bot `CHANGES_REQUESTED` reviews (Issue #426)

Only run when Step 3 made a push (`DID_PUSH=1`). Runs **after** `git push` and **before** Step 3b (reviewer triggers).

Resolve the helper (same pattern as `pr-state.sh` / `cr-review-hourly.sh`):

```bash
DISMISS_STALE_SCRIPT=""
for candidate in \
  "${HOME:+$HOME/.claude/skills-worktree/.claude/scripts/dismiss-stale-bot-changes.sh}" \
  "${HOME:+$HOME/.claude/scripts/dismiss-stale-bot-changes.sh}" \
  ".claude/scripts/dismiss-stale-bot-changes.sh"; do
  if [[ -x "$candidate" ]]; then
    DISMISS_STALE_SCRIPT="$candidate"
    break
  fi
done
```

Optional handoff path (per `handoff-files.md`, one JSON file per PR):

```bash
# Use the scoped handoff when the repo is known. This caller owns the flat fallback.
if [[ -n "${OWNER_REPO:-}" ]]; then
  HANDOFF_JSON="${HANDOFF_JSON:-$([[ -n "$HANDOFF_STATE_SH" ]] && "$HANDOFF_STATE_SH" --owner-repo "$OWNER_REPO" --path "$PR_NUMBER" 2>/dev/null || echo "$HOME/.claude/handoffs/pr-${PR_NUMBER}-handoff.json")}"
else
  HANDOFF_JSON="${HANDOFF_JSON:-$HOME/.claude/handoffs/pr-${PR_NUMBER}-handoff.json}"
fi
```

Run dismissal (idempotent where PUT succeeds or review already **DISMISSED**; genuine dismissal failures cause **exit 4**). Handoff: append **only** when `--handoff-file` exists and parses as JSON; missing path logs a warn and skips append (caller creates full handoff); invalid JSON exits **4**.

```bash
if [[ "${DID_PUSH:-0}" -eq 1 ]]; then
  if [[ -n "$DISMISS_STALE_SCRIPT" ]]; then
    if [[ -n "${HANDOFF_JSON:-}" ]]; then
      # Scope dismissal to the same repo as the handoff file.
      if [[ -n "${OWNER_REPO:-}" ]]; then
        "$DISMISS_STALE_SCRIPT" "$PR_NUMBER" --handoff-file "$HANDOFF_JSON" --owner-repo "$OWNER_REPO"
      else
        "$DISMISS_STALE_SCRIPT" "$PR_NUMBER" --handoff-file "$HANDOFF_JSON"
      fi
    else
      "$DISMISS_STALE_SCRIPT" "$PR_NUMBER"
    fi
  else
    echo "[DISMISS-STALE] dismiss-stale-bot-changes.sh not found — skipping (install from repo .claude/scripts/)"
  fi
fi
```

The script only dismisses **`CHANGES_REQUESTED`** reviews where **`commit_id` ≠ current PR HEAD** and the author is a **Bot** on the literal allowlist (`coderabbitai[bot]`, `cursor[bot]`, `greptile-apps[bot]`, `codeant-ai[bot]`, plus the retired `graphite-app[bot]`). Human reviews are never dismissed. Logged lines look like `[DISMISS-STALE] dismissed stale bot CHANGES_REQUESTED review_id=…`.

---

## Step 3b: Trigger missing AI reviewers after a push

Only run this step when Step 3 made a push. If Step 3 skipped the commit/push, skip this step too.

Use the `$PUSHED_AT` captured immediately before `git push` in Step 3. After the push completes, wait exactly 2 minutes before checking reviewer status (BugBot is covered separately — post `@cursor review` once per push, but not again on a HEAD it has already refused for spend; see `bugbot.md` and memory `feedback_bugbot_auto_trigger_unreliable.md`):

```bash
PUSHED_SHA=$(git rev-parse HEAD)
echo "[REVIEWERS] waiting 120s for auto-triggered reviewers on ${PUSHED_SHA:0:7}"
sleep 120
```

Then run the extracted trigger script once, with the SHA you just pushed. It detects which reviewers already auto-triggered on the pushed SHA (`reviewer-activity.sh`) and posts one dedicated PR-level comment per missing reviewer — never batched:

```bash
FIXPR_TRIGGERS_SH=""
for _candidate in \
  "${HOME:+$HOME/.claude/skills-worktree/.claude/scripts/fixpr-reviewer-triggers.sh}" \
  "${HOME:+$HOME/.claude/scripts/fixpr-reviewer-triggers.sh}" \
  ".claude/scripts/fixpr-reviewer-triggers.sh"; do
  if [[ -x "$_candidate" ]]; then FIXPR_TRIGGERS_SH="$_candidate"; break; fi
done
if [[ -n "$FIXPR_TRIGGERS_SH" ]]; then
  "$FIXPR_TRIGGERS_SH" "$PR_NUMBER" --repo "$OWNER/$REPO" --pushed-sha "$PUSHED_SHA" --pushed-at "$PUSHED_AT"
else
  echo "ERROR: fixpr-reviewer-triggers.sh not found (checked all three paths) — post-push reviewer triggers unavailable; pr-preflight.sh (Step 0c, /babysit-pr) still invites them" >&2
fi
```

What it posts depends on the repo's review policy (`.claude/reference/review-policy.md` "Trigger eligibility"):

- **No `## Review policy` (`legacy`)** — `@coderabbitai full review` for a missing CodeRabbit unless 2 were posted on the PR in the trailing hour (a successful post records the slot via `cr-review-hourly.sh --record-explicit`), then `@codeant-ai review`, each only when missing on the pushed SHA, then BugBot — posted **only** by spending an owner grant for the pushed SHA through `paid-review-grant.sh --trigger`; otherwise the step prints `BugBot not invited — paid review requires owner approval`. The earlier BugBot skips still apply first and keep their wording: when `bugbot-tier-excluded.sh` excludes it, then when `bugbot-refused-head.sh` says BugBot already refused the pushed SHA, then — **last** — when the account daily cap (`review-daily-cap.sh`) answers a validated `over`; that skip appends `BugBot skipped: daily cap ($X of $Y today)` once per HEAD under the PR body's `## Review notes`.
- **A tier-aware repo** — only what `review-triggers-allowed.sh` allows on the pushed SHA: CodeAnt once per PR, BugBot only by spending an owner grant at its `approval_required` step, CodeRabbit only as the CodeAnt-unavailable fallback. Each post is claimed first and released if it fails; the BugBot refusal and daily-cap guards run inside the helper, and a daily-cap skip still writes the PR-body note. `pr-preflight.sh` (Step 0c, every `/babysit-pr` and `/pr-monitor-and-manage` tick) and `maybe-trigger-ai-review.sh` ask again once CI is green.

Skip the CodeAnt nudge if it already acted on this HEAD. Respect any BugBot spend refusal on `$PUSHED_SHA`. Greptile stays last-resort only per `greptile.md`.

The `cr-github-review.md` polling path invokes `maybe-trigger-ai-review.sh` with no `/fixpr` trigger, no new findings, green CI, and a non-`BEHIND`/`CONFLICTING` merge state. Its individual CodeAnt and Cursor comments follow complexity and CR-round thresholds and the tier helper. It records state in `session-state.json` to avoid duplicate triggers for the same cause. Step 3b separately applies the pushed-HEAD and CodeRabbit hourly rules above.

---

## Step 4: Reply and resolve every thread

For every entry in `.threads.unresolved` — fix, decline-high-confidence, surface-low-confidence, already-fixed, or outdated:

### 4a. Reply

Pull the IDs from the JSON:

```bash
# index <i> in each call — iterate 0..unresolved_count-1
DBID=$(jq -r ".threads.unresolved[$i].comments.nodes[0].databaseId" "$AUDIT")
```

Reply text by classification:

- **fix:** `"Fixed in \`<short-sha>\`: <one-line description>"`
- **decline-high-confidence:** `"Reviewed and intentionally declined: <one-line rationale>. Resolving so GitHub stays an audit surface."`
- **surface-low-confidence:** `"Reviewed and resolved on GitHub; surfacing the decision in chat because confidence is <50%: <one-line rationale>."`
- **already-fixed:** `"Addressed in a prior commit — current code no longer has this issue. Resolving."`
- **outdated:** `"Referenced code no longer exists after refactoring. Resolving."`

Post the reply via the shared helper — it handles inline-first, PR-comment-fallback, and reviewer-specific `@mention` rules automatically:

```bash
# $REVIEWER: cr | bugbot | greptile (from the audit classification)
# $VERDICT / $DEFECT: per entry, from the mapping below (mandatory — issue #1842)
# $FIX: as-given | adapted | wrong | none — per entry (mandatory — issue #1843)
"$REPLY_THREAD_SH" "$DBID" --reviewer "$REVIEWER" \
  --body "$REPLY" --pr "$PR_NUMBER" \
  --verdict "$VERDICT" --defect "$DEFECT" --fix "$FIX"
```

**`--verdict` and `--defect` are mandatory on every reply**. Set them per entry: **fix** and **already-fixed** → `--verdict fixed`; **decline-high-confidence**, **surface-low-confidence**, and **outdated** → `--verdict declined` (usually `--defect not`); a finding deferred to a follow-up issue → `--verdict deferred`. `--defect real` only when the finding named a behaviour the code would actually have gotten wrong; `--defect not` for style, duplication, or a reviewer misreading. `--fix` is required with `--defect real`: `as-given` (suggestion applied as proposed), `adapted` (right direction, code rewritten), `wrong` (proposed fix incorrect), `none` (no fix suggested). Set `$FIX` on every entry (it is ignored unless `--defect real`). Leave `--agent` at its default. The helper writes the review ledger marker. Rationale and the mandate's landing date: `.claude/reference/review-stack-audit.md` §The marker.

The script strips any `@greptileai` tokens from the body in greptile mode and any `@cursor` tokens in bugbot mode — so even a stray mention in `$REPLY` cannot trigger a paid Greptile re-review. `@greptileai` is reserved exclusively for intentionally requesting a new review. See `reply-thread.sh --help` for the full exit-code contract.

### 4b. Resolve via shared helper

After all replies are posted, resolve and verify exactly the threads `/fixpr` touched. Build the expected-resolved set from the GraphQL thread IDs for every item replied to in 4a (same set you will re-verify in Step 4c after a push):

```bash
TOUCHED_THREADS=$(mktemp -t fixpr-touched-threads.XXXXXX)
# append one GraphQL thread node id per unresolved thread from the Step 0 audit
jq -r '.threads.unresolved[].id' "$AUDIT" > "$TOUCHED_THREADS"

THREAD_RESOLUTION_OUTPUT=$("$RESOLVE_REVIEW_THREADS_SH" "$PR_NUMBER" \
  --thread-ids-file "$TOUCHED_THREADS" --max-attempts 2 2>&1)
echo "$THREAD_RESOLUTION_OUTPUT"
```

> **NEVER call `resolveReviewThread` inline** (e.g., `for TID in ...; do gh api graphql resolveReviewThread ...; done`). Always use `resolve-review-threads.sh <PR> --thread-ids <id1,id2>` (or `--thread-ids-file`). The script handles retries and the `minimizeComment` fallback automatically.

Pass every addressed thread to `--thread-ids-file`, including threads on unchanged lines, declined findings, and threads GitHub already closed.

The resolver re-fetches `pullRequest.reviewThreads` after each mutation pass and before exit, retrying `resolveReviewThread` and falling back to `minimizeComment(classifier: RESOLVED)` for touched threads still unresolved. Exit codes: `0` means every touched thread was verified resolved; `1` means at least one dangling thread remains and `/fixpr` must not declare success; `3` PR not found; `4` gh error. It prints `[VERIFY] addressed=N resolved=M dangling=K` plus `[STUCK]` lines with URLs/reasons for every dangling thread.

Keep `$TOUCHED_THREADS` until after Step 4c (same path as Step 4b).

### 4c. Post-push: re-resolve and verify touched threads on the new HEAD

Run **only when Step 3 pushed** (`DID_PUSH=1`).

1. Run the same resolve pass again against the **same** `TOUCHED_THREADS` file (fresh GraphQL fetch on current HEAD).
2. Run a read-only verification pass so completion is blocked until a **second** GraphQL read shows every addressed id as `isResolved: true`.

```bash
POST_PUSH_RESOLVE_FAILED=0
POST_PUSH_VERIFY_FAILED=0
POST_PUSH_THREAD_OUTPUT=""
POST_PUSH_VERIFY_OUTPUT=""
if [[ "${DID_PUSH:-0}" -eq 1 ]]; then
  POST_PUSH_THREAD_OUTPUT=$("$RESOLVE_REVIEW_THREADS_SH" "$PR_NUMBER" \
    --thread-ids-file "$TOUCHED_THREADS" --max-attempts 2 2>&1) || POST_PUSH_RESOLVE_FAILED=1
  echo "$POST_PUSH_THREAD_OUTPUT"
  POST_PUSH_VERIFY_OUTPUT=$("$RESOLVE_REVIEW_THREADS_SH" "$PR_NUMBER" \
    --thread-ids-file "$TOUCHED_THREADS" --verify-only 2>&1) || POST_PUSH_VERIFY_FAILED=1
  echo "$POST_PUSH_VERIFY_OUTPUT"
fi
```

Treat non-zero exit from either sub-step as `THREADS_STUCK` in Step 7 (do not declare `CLEAN`). On success, both lines print `[VERIFY] addressed=N resolved=N dangling=0`.

When `TOUCHED_THREADS` is empty (no threads from Step 0’s `.threads.unresolved`, e.g. CI-only fix with a push), `--verify-only` still runs but is a **no-op**: it prints `[VERIFY] addressed=0 resolved=0 dangling=0` and exits 0 — do not treat that as failure.

When `DID_PUSH=0`, omit Step 4c; Step 4b’s resolver output alone is authoritative for touched threads.

---

## Step 4d: Post-push review-wait loop (issue #454)

Wait — bounded — for the bots and CI to deliver a verdict on the **current HEAD SHA only** (never the pre-push SHA), so `/fixpr` returns with a definitive answer instead of "we pushed, bye". This is the single owner of post-push polling: `/wrap` trusts this loop's verdict and never adds its own polling cadence on top.

**Entry conditions:**

- `DID_PUSH=1` → always enter. Watch the pushed SHA: `WATCH_SHA=$PUSHED_SHA`, baseline `WAIT_BASELINE=$PUSHED_AT`. Step 3b's fixed 120s reviewer-trigger wait already ran; it does **not** count against this loop's cap (the cap clock starts at loop entry).
- `DID_PUSH=0` (idempotent path) → run **one** snapshot tick first on the current HEAD (`WATCH_SHA=$HEAD_SHA`, `WAIT_BASELINE=$RUN_STARTED_AT`) using the same `pr-state.sh` + jq predicate as the loop below, **without incrementing `FIXPR_WAIT_ITER`**. If `bots_pending`, `ci_pending`, and `ci_failing` are all empty and `new_findings == 0`, set `FIXPR_WAIT_FINAL=clean` and **skip the wait loop entirely — zero wait, zero iterations, no push** — proceed to Step 5. If bots or CI are still pending on the current SHA, fall through to the wait loop (which increments `FIXPR_WAIT_ITER` once at entry).

**Per-tick snapshot — reuse `pr-state.sh`, do not re-invent endpoint polling.** Set `WATCH_SHA` / `WAIT_BASELINE` from the entry path above (`PUSHED_SHA`/`PUSHED_AT` when `DID_PUSH=1`, else `HEAD_SHA`/`RUN_STARTED_AT`). Each tick fetches one fresh bundle (all 3 comment endpoints + check-runs + commit statuses, `per_page=100`, classification since baseline):

Persist the latest snapshot before classifying it, including the zero-wait pre-check. The per-PR handoff must already exist (initialize it through `polling-state-gate.sh --ensure-session`); an unavailable helper or failed write stops this wait without a clean verdict. Pin the selected handoff for this wait; verified legacy records use guarded in-place writes. Missing attribution requires explicit repair, not a scoped shadow. Raw stdout/stderr and a private copy of each readable bundle remain at recorded paths. Failed snapshots are indexed separately from the latest status, so a later clean tick cannot erase them. A failed evaluator/fetch or malformed verdict stops after recording, never becomes clean. Lifecycle and read-only retrieval: `recovery-evidence.md`.

<!-- test-anchor: fixpr-persist-wait-evidence -->
```bash
FIXPR_WAIT_LIBRARY=""
if [[ -n "${RECOVERY_EVIDENCE_SH:-}" && -r "${RECOVERY_EVIDENCE_SH%/*}/lib/fixpr-wait-evidence.sh" ]]; then
  FIXPR_WAIT_LIBRARY="${RECOVERY_EVIDENCE_SH%/*}/lib/fixpr-wait-evidence.sh"
else
  for candidate in "${HOME:+$HOME/.claude/skills-worktree/.claude/scripts/lib/fixpr-wait-evidence.sh}" \
    "${HOME:+$HOME/.claude/scripts/lib/fixpr-wait-evidence.sh}" ".claude/scripts/lib/fixpr-wait-evidence.sh"; do
    if [[ -r "$candidate" ]]; then FIXPR_WAIT_LIBRARY="$candidate"; break; fi
  done
fi
[[ -n "$FIXPR_WAIT_LIBRARY" ]] || { echo "ERROR: wait evidence library unavailable; no clean verdict" >&2; return 1 2>/dev/null || exit 1; }
source "$FIXPR_WAIT_LIBRARY"
unset FIXPR_WAIT_LIBRARY
```

```bash
# Idempotent pre-check (DID_PUSH=0 only) — one tick, no iter increment
SKIP_WAIT_LOOP=0
if [[ "${DID_PUSH:-0}" -eq 0 ]]; then
  WATCH_SHA=$HEAD_SHA
  WAIT_BASELINE=$RUN_STARTED_AT
  capture_fixpr_wait_evidence || { echo "ERROR: wait snapshot failed; no clean verdict" >&2; exit 1; }
  BOTS_PENDING=$(jq -r '.bots_pending | join(", ") | if . == "" then "none" else . end' <<<"$WAIT_STATE")
  CI_PENDING=$(jq -r '.ci_pending | join(", ") | if . == "" then "none" else . end' <<<"$WAIT_STATE")
  if [[ "$BOTS_PENDING" == "none" && "$CI_PENDING" == "none"
        && "$(jq -r '.ci_failing | length' <<<"$WAIT_STATE")" -eq 0
        && "$(jq -r '.new_findings' <<<"$WAIT_STATE")" -eq 0
        && "$(jq -r '.head_moved' <<<"$WAIT_STATE")" != "true" ]]; then
    FIXPR_WAIT_FINAL=clean
    SKIP_WAIT_LOOP=1
    echo "[WAIT] idempotent pre-check: clean on ${WATCH_SHA:0:7} — zero wait, zero iterations"
  fi
fi

if [[ "$SKIP_WAIT_LOOP" -eq 0 ]]; then
  if [[ "${DID_PUSH:-0}" -eq 1 ]]; then
    WATCH_SHA=$PUSHED_SHA
    WAIT_BASELINE=$PUSHED_AT
  else
    WATCH_SHA=$HEAD_SHA
    WAIT_BASELINE=$RUN_STARTED_AT
  fi
  FIXPR_WAIT_ITER=$((FIXPR_WAIT_ITER + 1))
  WAIT_STARTED=$(date +%s)
  WAIT_OUTCOME=""          # clean | cap-exhausted | new-findings | ci-failing | head-moved
  RETRIGGERED_THIS_WAIT=0
  while :; do
  capture_fixpr_wait_evidence || { echo "ERROR: wait snapshot failed; no clean verdict" >&2; exit 1; }

  ELAPSED=$(( $(date +%s) - WAIT_STARTED ))
  BOTS_PENDING=$(jq -r '.bots_pending | join(", ") | if . == "" then "none" else . end' <<<"$WAIT_STATE")
  CI_PENDING=$(jq -r '.ci_pending | join(", ") | if . == "" then "none" else . end' <<<"$WAIT_STATE")

  # The snapshot was saved before classification; routine waits stay silent.

  if [[ "$(jq -r '.head_moved' <<<"$WAIT_STATE")" == "true" ]]; then
    WAIT_OUTCOME="head-moved"; break          # external push — re-audit from Step 0
  fi
  if [[ "$(jq -r '.new_findings' <<<"$WAIT_STATE")" -gt 0 ]]; then
    WAIT_OUTCOME="new-findings"; break        # bots posted findings — next sweep
  fi
  if [[ "$(jq -r '.ci_failing | length' <<<"$WAIT_STATE")" -gt 0 ]]; then
    WAIT_OUTCOME="ci-failing"; break          # blocking CI on the new SHA — next sweep
  fi
  if [[ "$BOTS_PENDING" == "none" && "$CI_PENDING" == "none" ]]; then
    WAIT_OUTCOME="clean"; break               # full verdict in — early exit
  fi
  if (( ELAPSED >= FIXPR_WAIT_CAP_SECS )); then
    WAIT_OUTCOME="cap-exhausted"
    echo "[WAIT] CAP HIT at ${FIXPR_WAIT_CAP_SECS}s on ${WATCH_SHA:0:7} — NOT falling through silently:"
    echo "[WAIT]   bots still pending: $BOTS_PENDING"
    echo "[WAIT]   CI still incomplete: $CI_PENDING"
    break
  fi
  sleep "$FIXPR_WAIT_POLL_SECS"
done
FIXPR_TOTAL_WAIT_SECS=$((FIXPR_TOTAL_WAIT_SECS + ELAPSED))
fi   # end SKIP_WAIT_LOOP
```

**Running this block as a worktree-isolated subagent.** Write the loop to a session scratchpad file and run `bash <file>` as one plain call.

**Include the persistence helper in the child file.** Copy the **entire** `fixpr-persist-wait-evidence` loader block into that same file before the pre-check/loop, and pass `HANDOFF_STATE_SH` plus the verified `OWNER_REPO` alongside the inputs below. Keep `WAIT_BASELINE` and the entry-path inputs (`DID_PUSH`, `HEAD_SHA`, `PUSHED_SHA`, `PUSHED_AT`) available there too; the snapshots assign `TICK` and `WAIT_STATE` inside the child. Missing helper/scope or failed evidence writes must stop, never fabricate a clean wait.

**Child inputs and outputs.** Pass `PR_NUMBER`, `WATCH_SHA`, `SCRIPT`, `RUN_STARTED_AT`, `FIXPR_WAIT_ITER`, `FIXPR_MAX_ITERATIONS`, `FIXPR_WAIT_CAP_SECS`, `FIXPR_WAIT_POLL_SECS` and `FIXPR_TOTAL_WAIT_SECS` into the child file or its invocation environment. Print `WAIT_OUTCOME` and `ELAPSED` on its last line and capture them in the caller. Reapply `FIXPR_TOTAL_WAIT_SECS=$((FIXPR_TOTAL_WAIT_SECS + ELAPSED))` in the caller.

Keep this classifier in place. Do not substitute `wait-until.sh`. See `.claude/reference/worktree-isolation-command-shapes.md` for allowed command shapes.

**Participating-bot set is DYNAMIC** — computed fresh each tick from the bot logins seen in any review or comment on this PR, intersected with the allowlist. A CR-only PR never waits on Greptile/BugBot signals. Never use a static list.

**Optional CR re-trigger inside the wait** (per `cr-merge-gate.md` re-trigger policy): if `coderabbitai[bot]` is participating and still pending after **12 min** (`ELAPSED >= 720`) and `RETRIGGERED_THIS_WAIT=0`, you may post one `@coderabbitai full review` — but ONLY when `cr-review-hourly.sh --check` exits 0 AND `cr-review-hourly.sh --record-explicit "$PR_NUMBER"` succeeds (it enforces the ≤2 explicit triggers/PR/hour cap atomically and exits 1 at the cap — at the cap, skip the trigger and keep waiting). Set `RETRIGGERED_THIS_WAIT=1` — at most one re-trigger per wait iteration. The wait loop never triggers any other reviewer; Step 3b owns those.

**Routing on `WAIT_OUTCOME`:**

| Outcome | Action |
|---------|--------|
| `clean` | Set `FIXPR_WAIT_FINAL=clean`. Proceed to Step 5 — the verify pass gives the authoritative classification of what the bots posted. |
| `new-findings`, `ci-failing`, or `head-moved` | If `FIXPR_WAIT_ITER < FIXPR_MAX_ITERATIONS` → start the **next sweep at Step 0** with a fresh `$RUN_STARTED_AT`. Else at outer cap, set `FIXPR_WAIT_FINAL` and Status **per outcome** — do not blanket-label everything `new-findings-pending`: `new-findings` → `FIXPR_WAIT_FINAL=new-findings-pending`, Status `NEW_FINDINGS`; `ci-failing` → `FIXPR_WAIT_FINAL=cap-exhausted`, Status `CI_FAILING`; `head-moved` → `FIXPR_WAIT_FINAL=cap-exhausted`, Status note external push in summary (re-run `/fixpr`). |
| `cap-exhausted` | Set `FIXPR_WAIT_FINAL=cap-exhausted`. Proceed to Step 5/7 — the cap-hit lines above (pending bots + incomplete CI) MUST appear in the final summary; the status will be `REVIEW_PENDING` or `CI_PENDING` per what is outstanding. |

**Safety (non-negotiable, issues #450/#452/#454):** this loop is read-only plus the single rate-capped CR re-trigger above. It never calls branch-protection APIs, never dismisses human reviews, and never resolves threads — thread resolution happens only in Steps 1–4 after code-verification.

---

## Step 5: Verify

Run the audit script again with `--since $RUN_STARTED_AT`. This picks up the new HEAD SHA (post-push) **and** pre-classifies any bot comment that landed between Step 0 and now:

```bash
VERIFY=$("$SCRIPT" --pr "$PR_NUMBER" --since "$RUN_STARTED_AT")
```

### 5a. Threads

Re-state the latest `[VERIFY]` from `THREAD_RESOLUTION_OUTPUT` and, if Step 4c ran, `POST_PUSH_THREAD_OUTPUT` / `POST_PUSH_VERIFY_OUTPUT`. Verify those exact threads independently of `.threads.unresolved_count`.

```bash
UNRESOLVED=$(jq -r '.threads.unresolved_count' "$VERIFY")
```

- If the resolver's dangling count is `0` and `UNRESOLVED == 0` → `[CLEAN] All threads resolved — zero uncollapsed in browser.`
- If the resolver's dangling count is `0` but unrelated reviewer threads remain unresolved → run `"$RESOLVE_REVIEW_THREADS_SH" "$PR_NUMBER"` once to resolve them too. `/fixpr` never leaves reviewer threads open as a paper trail.
- If the resolver reports dangling threads → emit `THREADS_STUCK` and list each `[STUCK]` URL/reason. Do not declare success.

### 5b. New bot comments since `$RUN_STARTED_AT`

`audit.sh` has already classified every bot comment posted after `$RUN_STARTED_AT`. Read the rollup:

```bash
jq -r '
  "[VERIFY-COMMENTS] new findings: \(.new_since_baseline.finding_count), acknowledgments: \(.new_since_baseline.acknowledgment_count)",
  (.new_since_baseline.reviews[], .new_since_baseline.inline[], .new_since_baseline.conversation[]
   | select(.classification.class == "finding")
   | "  finding: \(.url) — \(.classification.reason)")
' "$VERIFY"
```

Use `pr-state.sh --since`'s unchanged `new_since_baseline` classification fields. `.claude/scripts/lib/pr-state-classify.jq` defines and applies the authoritative precedence, including the default finding classification. Use that result without reimplementing the rules.

**If `finding_count > 0`:** If `FIXPR_WAIT_ITER < FIXPR_MAX_ITERATIONS`, start the next sweep at Step 0. At the outer cap: set `FIXPR_WAIT_FINAL=new-findings-pending`, emit `NEW_FINDINGS` in Step 7, and stop — re-running `/fixpr` resets the iteration budget.

### 5c. CI (if a push was made; exclude review-bot check-runs from CI pending)

The verify audit's `.check_runs` reflects the new HEAD.

<!-- test-anchor: fixpr-step-5c-check-buckets -->
```bash
jq -r '.check_runs.all[] | "[CI] \(.name): \(.status)\(if .conclusion then " — \(.conclusion)" else "" end)"' "$VERIFY"

CHECK_BUCKETS=$(jq '
  # Graphite: retired 2026-11-03. Its leftover check-run is never CI, matched by the
  # publishing app slug only (#1953) so another app naming a check "Graphite …" stays CI.
  def is_graphite: (.app.slug // "") as $s | $s == "graphite-app" or $s == "graphite";
  # Every review bot is identified by its publishing app when the run carries one:
  # a GitHub Actions job named "post-cursor-review" is CI, not a reviewer. The check
  # name decides only when no app slug is present at all.
  def is_review_bot:
    (.app.slug // "" | ascii_downcase) as $slug
    | if $slug != "" then
        ($slug | contains("coderabbit") or contains("codeant") or contains("cursor"))
        or is_graphite
      else
        (.name // "" | ascii_downcase)
        | contains("coderabbit") or contains("codeant") or contains("cursor")
      end;
  {
    ci: [.check_runs.all[] | select(is_review_bot | not)],
    review: [.check_runs.all[] | select(is_review_bot)]
  }
' "$VERIFY")
CI_CHECKS=$(jq '.ci' <<<"$CHECK_BUCKETS")
REVIEW_BOT_CHECKS=$(jq '.review' <<<"$CHECK_BUCKETS")

FAILING=$(jq '[.[] | select(.conclusion == "failure" or .conclusion == "timed_out" or .conclusion == "action_required" or .conclusion == "startup_failure" or .conclusion == "stale")] | length' <<<"$CI_CHECKS")
IN_PROGRESS=$(jq '[.[] | select(.status != "completed")] | length' <<<"$CI_CHECKS")
# A retired Graphite check-run is bucketed as review but never awaited (matches 5d).
REVIEW_IN_PROGRESS=$(jq '[.[] | select(.status != "completed") | select((.app.slug // "") as $s | ($s == "graphite-app" or $s == "graphite") | not)] | length' <<<"$REVIEW_BOT_CHECKS")
```

Decide from the non-review CI counts before review-bot pending counts:

- `IN_PROGRESS > 0` on non-review-bot checks → emit `CI_PENDING` in Step 7. Re-run `/fixpr` after CI finishes.
- `REVIEW_IN_PROGRESS > 0` with no non-review-bot CI pending/failing → defer to Step 5d and emit `REVIEW_PENDING`, not `CI_PENDING`.
- `IN_PROGRESS == 0 && FAILING > 0` → read each entry in `.check_runs.failing_runs` from the VERIFY audit. Classify:
  - **deterministic** (lint/typecheck/test/build/security reports a real error) → emit `CI_FAILING` in Step 7 and stop. Re-run `/fixpr` so Steps 2–3 can retry the fix on the newly-visible error.
  - **transient** (runner timeout, startup failure, flaky external dep) → emit `CI_FAILING` in Step 7, note the specific checks, and continue to Step 6 — local fixes aren't possible and the user decides whether to retry.
- `IN_PROGRESS == 0 && FAILING == 0` → non-review-bot CI is clean on this SHA.

Do NOT poll here — Step 4d is the single owner of post-push polling. CI still pending at this point means the 4d cap fired (or 4d was skipped on the no-push path); report it, don't wait.

### 5d. Review-bot commit statuses on the current HEAD

CR and Greptile report review completion via commit *statuses*, while CodeAnt and Cursor may report via check-runs. `pending` means a bot is still analyzing the current HEAD.

```bash
jq -r '
  .bot_statuses | to_entries[] | "[VERIFY-BOTS] \(.key): \(.value.state) (\(.value.updated_at))"
' "$VERIFY"
```

For each bot present in `.bot_statuses` or the current-head check-runs:

- **CodeRabbit specifically** (by status `context` / bot name) with `description` containing "rate limit" (case-insensitive) → CR rate-limited, fall back to Greptile per `cr-github-review.md`. CodeRabbit reports this as non-blocking `state: "success"` — check this **before** the `state: success` clean-pass rule below, not just on `failure`/`error`. Other bots are not subject to this rule.
- `state: success` (and not the CodeRabbit rate-limit case above) → review completed on this SHA. Clean-pass signal.
- `state: pending` or check-run `status != "completed"` → bot still running. **Do NOT declare CLEAN.** Emit `REVIEW_PENDING` and stop. Not for a retired Graphite check-run: Step 5c already excludes it from CI and nothing waits on it.
- No activity from CodeRabbit, CodeAnt, or Cursor after a pushed fix commit → expect the Step 3b trigger (on a tier-aware repo, only once CI is green and the tier allows it). Emit `REVIEW_PENDING` and re-run `/fixpr` after the reviewer responds. Exception: a CodeRabbit or CodeAnt that Step 3b logged as `skipping … — review tier …` (kind `excluded`) was never invited, so its silence is not `REVIEW_PENDING`; only a `deferring …` one is still awaited.
- **BugBot silence**: await `REVIEW_PENDING` only for a verified current-HEAD invitation or unused matching owner grant. Step 3b deferral or a daily-cap skip alone is not an invitation. Require the portable `bugbot-invitation.sh` reader; missing tooling or unknown/unreadable evidence remains awaited. On no-push reruns, ignore inherited `PUSHED_AT`/`PUSHED_SHA` and retain qualifying invitations posted before the rerun. Keep `BUGBOT_INVITATION_RESULT` and its `evidence_path` in Step 5 recovery evidence, never as future authorization. The reader only reads/checks grants; it never triggers or consumes. Window, bounds and diagnostic details: `bugbot-invitation.sh --help`.

<!-- test-anchor: fixpr-step-5d-bugbot-invited -->
```bash
BUGBOT_AWAITED=1   # unknown/missing tooling never means "not invited"
BUGBOT_INVITATION_SH=""
for _candidate in \
  "${HOME:+$HOME/.claude/skills-worktree/.claude/scripts/bugbot-invitation.sh}" \
  "${HOME:+$HOME/.claude/scripts/bugbot-invitation.sh}" \
  ".claude/scripts/bugbot-invitation.sh"; do
  if [[ -x "$_candidate" ]]; then BUGBOT_INVITATION_SH="$_candidate"; break; fi
done
INVITATION_HEAD="${HEAD_SHA:-}"
INVITATION_ARGS=(--repo "$OWNER/$REPO" --pr "$PR_NUMBER" --head "$INVITATION_HEAD" --grant-helper "${PAID_GRANT_SH:-}")
if [[ "${DID_PUSH:-0}" == 1 ]]; then
  INVITATION_HEAD="${PUSHED_SHA:-}"
  INVITATION_ARGS=(--repo "$OWNER/$REPO" --pr "$PR_NUMBER" --head "$INVITATION_HEAD" --grant-helper "${PAID_GRANT_SH:-}" --pushed-sha "${PUSHED_SHA:-}" --pushed-at "${PUSHED_AT:-}")
fi
if [[ -z "$BUGBOT_INVITATION_SH" ]]; then
  echo "DEGRADED: bugbot-invitation.sh not found (checked all three paths) — invitation verdict unknown"
elif BUGBOT_INVITATION_RESULT=$("$BUGBOT_INVITATION_SH" "${INVITATION_ARGS[@]}") && \
  jq -s -e --arg sha "$INVITATION_HEAD" 'length == 1 and (.[0] | type == "object" and .head_sha == $sha and (.awaited|type == "boolean") and (.certainty == "known" or .certainty == "unknown"))' <<<"$BUGBOT_INVITATION_RESULT" >/dev/null; then
  if jq -e '.certainty == "known" and .awaited == false' <<<"$BUGBOT_INVITATION_RESULT" >/dev/null; then
    BUGBOT_AWAITED=0
  elif jq -e '.certainty == "unknown"' <<<"$BUGBOT_INVITATION_RESULT" >/dev/null; then
    jq -r '"DEGRADED: BugBot invitation unknown (" + .reason + "); evidence: " + .evidence_path' <<<"$BUGBOT_INVITATION_RESULT"
  fi
else
  echo "DEGRADED: BugBot invitation reader failed — retain pending state and recovery evidence"
fi
echo "BUGBOT_AWAITED=$BUGBOT_AWAITED"
```

---

## Step 6: Check merge blockers

```bash
jq -r '.merge_state | "[MERGE] mergeable=\(.mergeable), status=\(.mergeStateStatus), review=\(.reviewDecision)"' "$VERIFY"
```

### 6a. Diff-survival guard — MANDATORY around every rebase (issue #757)

Wrap **every** rebase below — interactive and safe-only alike — in this pair:

```bash
GUARD="$DIFF_SURVIVAL_SH"

# BEFORE `git fetch origin main && git rebase origin/main`:
"$GUARD" snapshot                    # records which files carry substantive changes

# AFTER the rebase is fully complete (`git rebase --continue` returned 0) and
# BEFORE the force-push:
"$GUARD" verify; GUARD_RC=$?
```

Branch on `GUARD_RC`:

- **`0`** — intact (or `deferred`, meaning commits are still queued for replay; finish the rebase and re-run). Proceed to the force-push.
- **`1`** — the branch's entire diff vanished. **Do not force-push.** Report the guard's output verbatim; it names the one legitimate case (main independently landed the identical change → **close the PR**, never force-push an empty branch). Return `Status: CONFLICTS` / `FIXPR_WRAP_STATUS: CONFLICTS`.
- **`2`** — named files lost their changes. **Do not force-push, do not trigger reviewers, do not run Step 3a/3b/4d.** Report the named files and return `Status: CONFLICTS` / `FIXPR_WRAP_STATUS: CONFLICTS`.
- **`4`** — unresolved conflicts remain, the snapshot is for another branch, or verdict `unverifiable`. On `unverifiable` **do not force-push** — report the resolution as UNVERIFIED and treat it as unresolved.
- **`5`** — no snapshot exists. Run `"$GUARD" snapshot --if-absent`, then `verify`. **This only reconstructs a real baseline while the rebase is still in progress**. If the rebase has **already finished**, no baseline can be reconstructed after the fact: `verify` returns `unverifiable` (exit 4). Do not push on that verdict — say the resolution could not be verified and let a human decide.

The guard **never repairs anything**; recovery (`git rebase --abort`, or resetting to `ORIG_HEAD`) stays a deliberate human step. In **safe-only mode** (`BABYSIT_SAFE_CONFLICT_MODE=1`) a non-zero verify is surfaced upstream exactly like a complex hunk — emit the `CONFLICT_COMPLEX_REPORT_JSON:` line (use the guard's `--json` object as the value) plus `FIXPR_WRAP_STATUS: CONFLICTS`, so `/babysit-pr` T4 terminates `hard-blocked` with the lost-file report. Full contract: `.claude/reference/diff-survival-guard.md`.

| Field | Blocking value | Action |
|-------|---------------|--------|
| `mergeable` | `CONFLICTING` | **Run `diff-survival-check.sh snapshot` before the rebase and `verify` before the force-push — Step 6a is mandatory on both branches of this row.** **Default (interactive):** Rebase onto main: `git fetch origin main && git rebase origin/main`. Fix conflicts (optionally run **`/merge-conflict`** — `.claude/skills/merge-conflict/SKILL.md` — to fetch main, auto-resolve *simple* hunks, stage clean files, and list *complex* hunks), continue, force-push. **Safe-only mode (`BABYSIT_SAFE_CONFLICT_MODE=1`):** invoked by `/babysit-pr --auto-resolve-conflicts` for unattended resolution. After `git fetch origin main && git rebase origin/main` stops on conflicts, locate and invoke `resolve_merge_conflicts.py --repo "$(git rev-parse --show-toplevel)" --json` directly (candidate-path lookup: skills-worktree first, then in-repo). Branch on exit code: exit `0` (all hunks simple, files staged, empty `complex_report`) → run `git rebase --continue`, then **run the Step 6a `verify` gate before anything else** and only on `GUARD_RC == 0` treat it as push-equivalent (force-push, run Step 3a + Step 3b + Step 4d on the new SHA); exit `1` (any complex hunk, partial resolution, or stage failure) → run `git rebase --abort`, do NOT attempt any manual/semantic resolution, and emit the following lines so the caller can capture the structured report — then return with `Status: CONFLICTS` and `FIXPR_WRAP_STATUS: CONFLICTS`: <br><br>```text`<br>CONFLICT_COMPLEX_REPORT_JSON: <the raw JSON value of complex_report from the resolver's --json output>`<br>```<br><br>Store the emitted `CONFLICT_COMPLEX_REPORT_JSON` line into `.babysit.last_dispatch.complex_report` (or parse it from the fixpr output) so T-END can render each `{file, location, reason}` entry verbatim in the termination report. In safe-only mode, **never** attempt to hand-resolve or semantically merge a complex hunk — abort and report only. |
| `mergeable` | `UNKNOWN` | GitHub still computing — note and re-run `/fixpr` later. |
| `mergeStateStatus` | `BEHIND` | **First run `"$CLEAN_BEHIND_SH" "$PR_NUMBER"`.** Exit 0 (`safe_to_offer`: gate green except BEHIND, not CONFLICTING, AC verified, no touching or overlapping changed lines between the base delta and the PR — rules: the `clean-behind-check.sh` header) → **stop looping rebases and run `"$ADMIN_MERGE_SH" "$PR_NUMBER" --auto-plain --ac-verified`** — but **only after completing `cr-merge-gate.md` Step 2** (verify every Test Plan checkbox against the source at this SHA; ticked boxes are the proxy `clean-behind-check.sh` already checked, not verification). Any criterion that fails → fix it, do not merge; the script refuses without `--ac-verified`. Exit 0 → merged; relay its `AUTO_PLAIN_MERGED` evidence block. **No `AskUserQuestion`** — the plain shape modifies no branch protection, so it needs no user turn. Exit 8 → the shape needs a protection change (or an auto attempt already ran): **offer `/admin-merge` as a user choice** (AskUserQuestion, or print the command when running non-interactively) and **never auto-run** it. Exit 1 → not safe after re-validation (e.g. main advanced); fall through to the rebase path below. The `churn.advisory` field is context, not a gate (sensitivity configurable via `--churn-threshold N` or `CHURN_THRESHOLD` env var, default 1). Exit 1 (not safe — especially a base-delta↔PR-file overlap, or any residual blocker) → **capture the Step 6a snapshot (`diff-survival-check.sh snapshot`), then** rebase onto main: `git fetch origin main && git rebase origin/main`. If conflicts arise mid-rebase, resolve them the same way as `CONFLICTING` above (including optional **`/merge-conflict`**), then `git rebase --continue`. **Run the Step 6a `verify` gate; force-push only on `GUARD_RC == 0`** — a non-zero verdict blocks the push and returns `Status: CONFLICTS`. When `FIXPR_WAIT_ITER < FIXPR_MAX_ITERATIONS`, treat the force-push as push-equivalent: set `PUSHED_SHA=$(git rev-parse HEAD)`, `PUSHED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")`, `DID_PUSH=1`, run **Step 3a** (dismiss stale bot reviews), **Step 3b** (reviewer triggers + 120s wait), then **Step 4d** on the new SHA. Do **not** jump straight to Step 4d without 3a/3b. |
| `mergeStateStatus` | `BLOCKED` | Required checks/reviews missing — already covered by 5c/5d. If CodeRabbit, Greptile, or CodeAnt is in CODEOWNERS and the last approval is stale/dismissed after a push, recover by triggering that bot (`@coderabbitai full review` or `@codeant-ai review`; `@greptileai` is paid: only under an owner grant via `"$PAID_GRANT_SH" --trigger <PR> --vendor greptile` (#1898; an empty `PAID_GRANT_SH` is `DEGRADED: paid-review-grant.sh not found (checked all three paths)` — report it, never read it as "no grant"); otherwise ask for one (attended sessions only — `paid-review-approval.md`) or report a human blocker — never emit a pending review for a trigger that did not run, #1897) instead of escalating to the author — on a tier-aware repo, only a CodeRabbit or CodeAnt trigger `review-triggers-allowed.sh` allows (claim it first). |
| `mergeStateStatus` | `UNSTABLE` | A non-required check pending/failing — typically CR/Greptile on the new SHA. If 5d emitted `REVIEW_PENDING`, stop with that status. |
| `reviewDecision` | `CHANGES_REQUESTED` | Changes were requested. **Stale** bot `CHANGES_REQUESTED` (wrong `commit_id` vs HEAD) are cleared by Step 3a after each push — not escalation. If a **human** left `CHANGES_REQUESTED` on the current HEAD, report as non-automatable. |

When residual branch protection says review is missing or `reviewDecision != "APPROVED"`, run `"$MERGE_GATE_SH" "$PR_NUMBER"` and read `.code_owner_bots`. If it lists `coderabbitai[bot]`, `greptile-apps[bot]`, or `codeant-ai[bot]`, a current-HEAD **`APPROVED`** review from that bot satisfies GitHub's code-owner requirement. CodeAnt **check-run success** only covers the supplemental CR-path cleanliness rule in `cr-merge-gate.md`; it does **not** replace an `APPROVED` when CodeAnt is a code owner. A stale/dismissed bot approval is recoverable review debt: trigger the matching bot and re-run the gate after it responds. Do not ask the PR author for an approval GitHub will not accept.

After any rebase + force-push: `[MERGE] rebase complete, force-pushed (SHA: <new-sha>) — CI re-triggered. Re-run /fixpr after CI completes.`

---

## Step 7: Final summary

```text
=== fixpr complete ===
PR:              #$PR_NUMBER ($BRANCH)
Pre-flight:      $PREFLIGHT_LINE (rendered below from $PREFLIGHT_SUMMARY_JSON)
Threads:         N total, M were unresolved
  - Addressed:   A threads replied to by /fixpr
  - Resolved:    Y addressed threads verified isResolved=true
  - Dangling:    Z addressed threads (0 = clean; list each URL below)
Decisions:       X fixed, D declined silently, K surfaced
  - Surfaced:    <file/thread URL> — finding; decision; rationale; alternative considered; "Reply if you want me to override this decision."
CI checks:       P total, Q were failing
  - Fixed:       R failures in code
  - Transient:   S (cannot fix locally)
Merge state:     mergeable=..., status=..., review=...
Push:            <sha> or "no push needed"
Wait loop:       $FIXPR_WAIT_ITER iteration(s), total wait ${FIXPR_TOTAL_WAIT_SECS}s, final state: clean | cap-exhausted | new-findings-pending
  - Pending at cap: <bots-pending list + CI-pending list when final state is cap-exhausted; omit otherwise>
Status:          CLEAN | THREADS_STUCK | REVIEW_PENDING | CI_PENDING | CI_FAILING | CONFLICTS | BEHIND | NEEDS_HUMAN_REVIEW | NEW_FINDINGS
FIXPR_WRAP_STATUS: <exact same token as Status — single-line machine-parseable copy for /wrap issue #452>
FIXPR_WAIT_SUMMARY: iterations=<N> total_wait_secs=<S> final=<clean|cap-exhausted|new-findings-pending>
```

After a push, when Step 5 accounted for every finding, advance the three poll watermarks through the exact verified audit. Use its current HEAD and leave any later arrivals for the next poll. If the audit is missing, has findings or unresolved threads, or was from a different push, keep the old watermarks.

<!-- test-anchor: fixpr-verified-watermarks -->

```bash
if [[ "${DID_PUSH:-0}" == 1 && -n "${VERIFY:-}" && -n "${PUSHED_SHA:-}" ]] &&
   jq -e --arg head "$PUSHED_SHA" '
     .pr.head_sha == $head and .new_since_baseline.finding_count == 0 and .threads.unresolved_count == 0
   ' "$VERIFY" >/dev/null; then
  POLL_WATERMARKS_SH=$(resolve_script poll-watermarks.sh || true)
  if [[ -n "$POLL_WATERMARKS_SH" ]]; then
    "$POLL_WATERMARKS_SH" "$PR_NUMBER" --reset --audit-file "$VERIFY" >/dev/null ||
      echo "[POLL] Verified audit watermark could not be saved; keep polling."
  fi
fi
```

Render the **Pre-flight** line from the per-reviewer `.status` values in `$PREFLIGHT_SUMMARY_JSON` (Step 0c), never from `.clean` alone. Print `$PREFLIGHT_LINE` verbatim:

<!-- test-anchor: fixpr-step-7-preflight-line -->
```bash
if [[ -z "${PREFLIGHT_SUMMARY_JSON:-}" ]]; then
  PREFLIGHT_LINE="skipped"   # no PR resolved yet, or pr-preflight.sh missing
else
  PREFLIGHT_LINE="$(jq -r '
    def status_name: {
      "skipped-tier-excluded": "review tier excludes",
      "skipped-approval-required": "awaiting owner approval:",
      "skipped-tier-deferred": "tier-deferred:",
      "skipped-rate-cap": "rate-capped:",
      "triggered": "triggered:",
      "trigger-failed": "trigger failed:",
      "dry-run-would-trigger": "would trigger:"
    }[.] // (. + ":");
    def draft: {
      "not-draft": "already ready", "marked-ready": "marked ready",
      "would-mark-ready": "would mark ready", "ready-failed": "ready flip failed",
      "skipped-not-author": "still draft (not author)",
      "skipped-auth-unknown": "still draft (author unknown)"
    }[.] // .;
    if (.reviewers | type) != "object" or (.reviewers | length) == 0
       or ([.reviewers[] | (.status | type) == "string"] | all | not)
       or ((.draft_action | type) != "string")
    then error("incomplete summary") else . end
    | (.reviewers | to_entries) as $r
    | ($r | length) as $n
    | ([$r[] | select(.value.status == "already-present")] | length) as $k
    | (if .clean == true then "clean — already ready" else (.draft_action | draft) end) as $head
    | if $k == $n then $head + ", all " + ($n | tostring) + " reviewers engaged"
      else $head + ", " + ($k | tostring) + " of " + ($n | tostring) + " reviewers engaged; "
        + ([$r[] | select(.value.status != "already-present")]
           | group_by(.value.status)
           | map((.[0].value.status | status_name) + " " + (map(.key) | join(", ")))
           | join("; "))
      end
  ' <<<"$PREFLIGHT_SUMMARY_JSON" 2>/dev/null)" || PREFLIGHT_LINE=""
  [[ -n "$PREFLIGHT_LINE" ]] || PREFLIGHT_LINE="unreadable — pr-preflight.sh summary did not parse; see the Step 0c output"
fi
```

Legacy repos (no `## Review policy`) never produce `skipped-tier-excluded`, so a fully engaged legacy PR still reads `all N reviewers engaged`. N is counted from the summary, never a literal.

`/wrap` recovery may delegate here; parents grep **`FIXPR_WRAP_STATUS:`** and **`FIXPR_WAIT_SUMMARY:`** (and echo **`Status:`**) into heartbeats without re-parsing prose. `/wrap` re-runs `merge-gate.sh` immediately with no polling of its own. `final=clean` when the last wait exited on a full bot+CI verdict (or the idempotent no-push path was already clean — `iterations=0`); `final=cap-exhausted` when the last wait hit `FIXPR_WAIT_CAP_SECS`; `final=new-findings-pending` when the outer iteration cap exhausted with findings still arriving.

**Status definitions:**

- `CLEAN` — **all four conditions simultaneously:** zero unresolved threads (5a), `new_since_baseline.finding_count == 0` (5b), every present review-bot status/check-run for the current HEAD is complete/successful (5d), no merge blockers (6). Missing any one disqualifies `CLEAN` — pick the more specific status below.
- `THREADS_STUCK` — some threads could not be resolved via GraphQL (report which).
- `REVIEW_PENDING` — a review-bot status/check-run is still pending on the current HEAD after the Step 4d wait (i.e., the 20-min cap fired with bots outstanding — `FIXPR_WAIT_FINAL=cap-exhausted`). The footer's "Pending at cap" line names them. Re-run `/fixpr` for a fresh iteration budget. Do NOT declare CLEAN.
- `NEW_FINDINGS` — findings still arriving at the outer iteration cap (`FIXPR_WAIT_FINAL=new-findings-pending`). Stop the run. A fresh `/fixpr` resets the budget and re-audits from Step 0.
- `CI_PENDING` — push was made, and non-review-bot CI was still incomplete when the Step 4d cap fired. Re-run `/fixpr` after CI.
- `CI_FAILING` — transient CI failures that cannot be fixed locally (report which).
- `CONFLICTS` — merge conflicts could not be auto-resolved (needs manual intervention), **or** the Step 6a diff-survival guard blocked the push because the resolution dropped the PR's own changes (name the lost files, or the vanished-diff guidance).
- `BEHIND` — branch behind base, auto-rebased and force-pushed, and the wait budget was already exhausted (Step 6 enters the Step 4d wait on the new SHA when iterations remain). Re-run `/fixpr` after CI completes.
- `NEEDS_HUMAN_REVIEW` — a human reviewer requested changes, or no configured code-owner bot can satisfy the missing required approval. If CR/Greptile is in CODEOWNERS and only its approval is stale/dismissed, downgrade to `REVIEW_PENDING` after triggering the bot re-review.
