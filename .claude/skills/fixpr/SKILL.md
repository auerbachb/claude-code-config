---
name: fixpr
description: Bounded-convergence PR cleanup — audit every review thread + every CI check-run, fix all issues, push once per sweep, dismiss stale bot CHANGES_REQUESTED on old commits, resolve all threads via GraphQL, then wait (capped) for bot verdicts + CI on the new SHA, re-sweeping on new findings up to 5 iterations. Zero uncollapsed threads and zero failing checks when done.
---

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
    "$HOME/.claude/skills-worktree/.claude/scripts/$name" \
    "$HOME/.claude/scripts/$name" \
    ".claude/scripts/$name"; do
    if [[ -x "$candidate" ]]; then echo "$candidate"; return 0; fi
  done
  return 1
}
PR_AUTHORSHIP_SH=$(resolve_script pr-authorship.sh || true)
HANDOFF_STATE_SH=$(resolve_script handoff-state.sh || true)
REPLY_THREAD_SH=$(resolve_script reply-thread.sh || true)
RESOLVE_REVIEW_THREADS_SH=$(resolve_script resolve-review-threads.sh || true)
DIFF_SURVIVAL_SH=$(resolve_script diff-survival-check.sh || true)
LOCAL_REVIEW_SH=$(resolve_script local-review.sh || true)
CLEAN_BEHIND_SH=$(resolve_script clean-behind-check.sh || true)
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
if [[ -z "$HANDOFF_STATE_SH" ]]; then
  echo "DEGRADED: handoff-state.sh not found (checked all three paths) — namespaced handoff path unavailable, continuing with legacy flat path" >&2
fi
```

### Batching before burning CR quota (Issue #28)

CodeRabbit caps **~8 GitHub PR reviews per hour** per account; **each push** consumes one. **Multi-round PRs** exhaust that budget fast if you fix-and-push repeatedly.

**Coalesce locally first:** Before opening `/fixpr` on minor iterations, run the dual-CLI local review (**`"$LOCAL_REVIEW_SH" --tool coderabbit --scope uncommitted`** + **`--tool codeant --scope uncommitted`**) per `cr-local-review.md` on uncommitted changes when feasible — catch issues **before** they cost a GitHub review. The wrapper returns one compact line per CLI; the raw capture stays at its `log_path`.

**Coalesce inside `/fixpr`:** Steps 1–3 intentionally gather **every** unresolved finding + every failing CI check, then fix **all** actionable items and **`git push` once**. Never push once per finding. One `/fixpr` cycle should produce **at most one** consume-side CR review per completed push (tracked below).

## How this skill is structured

> **pr-state.sh first (NON-NEGOTIABLE):** Before calling `gh api .../pulls/{N}/reviews`, `pulls/{N}/comments`, or `issues/{N}/comments` directly, call `pr-state.sh --pr N` first and read the cached JSON bundle. Inline `gh api` calls for these three endpoints are only permitted inside the `reviewer-activity.sh` script (Step 3b delegate), which requires a custom post-push timestamp filter that `pr-state.sh` does not expose. Every other polling or review-state lookup MUST go through `pr-state.sh`.

All mechanical GitHub API work — pagination, GraphQL queries, comment classification — lives in the shared `pr-state.sh` script. This file tells the AI layer how to invoke the script and what to do with its output (the JSON bundle).

| Step | Kind | Done by |
|------|------|---------|
| 0a. Resolve target PR (arg or infer) | Judgment + Mechanical | AI thread scan + `pr-state.sh --infer-candidates` (no-arg inference, issue #447) |
| 0. Gather PR state | Mechanical | `pr-state.sh` writes `/tmp/pr-state-<PR>-<epoch>.json` |
| 1. Classify review findings | Judgment | AI reads JSON + source files |
| 2. Classify CI failures | Judgment | AI reads `check-runs/<id>.output.summary` |
| 3. Fix & push | Judgment | AI edits files, commits, pushes |
| 3a. Dismiss stale bot `CHANGES_REQUESTED` | Mechanical | `dismiss-stale-bot-changes.sh` after push when `DID_PUSH=1`; optional `--handoff-file` append |
| 3b. Trigger missing AI reviewers | Mechanical | wait 2 minutes, detect CR/Graphite/CodeAnt activity on the new SHA, post triggers for missing bots, post `@cursor review` unless BugBot already refused this HEAD |
| 4. Reply & resolve | Mechanical | `gh api` calls against IDs from the JSON |
| 4c. Post-push thread verify (if Step 3 pushed) | Mechanical | Re-fetch threads on new HEAD; explicitly resolve any touched thread still `isResolved: false` (fixes unchanged-line orphans), then `--verify-only` |
| 4d. Review-wait loop (issue #454) | Mechanical | Poll `pr-state.sh` on the pushed SHA every 30–60s, capped at 20 min; early-exit on full bot+CI verdict; new findings → next sweep |
| 5. Verify | Mechanical | Re-run `pr-state.sh --since $RUN_STARTED_AT` |
| 6. Merge blockers | Judgment | AI reads `.merge_state` from the JSON |
| 7. Final summary | Judgment | AI emits the status |

Execute the steps sequentially. Steps 0–4c form one **fix sweep**. After a sweep that pushed, Step 4d waits — bounded — for bot verdicts and CI on the **new HEAD SHA**; when new findings or blocking CI arrive mid-wait, start the next sweep at Step 0 (outer cap: `FIXPR_MAX_ITERATIONS`, default 5). `/fixpr` exits when the wait predicate is clean, a cap fires, or a non-loopable status arises (conflicts, human changes requested, stuck threads). This in-turn loop runs within a single agent turn — no `/loop`, `CronCreate`, or `ScheduleWakeup`.

**Environment knobs (issue #454):**

| Variable | Default | Purpose |
|----------|---------|---------|
| `FIXPR_WAIT_CAP_SECS` | `1200` | Hard cap per wait iteration (20 min = P93 of bot-response times from a 30-PR sample) |
| `FIXPR_WAIT_POLL_SECS` | `60` | Poll cadence inside the wait loop (valid range 30–60) |
| `FIXPR_MAX_ITERATIONS` | `5` | Outer cap on fix-sweep + wait iterations (matches `/wrap` recovery cap, issue #452) |

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
  "$HOME/.claude/skills-worktree/.claude/scripts/pr-state.sh" \
  "$HOME/.claude/scripts/pr-state.sh" \
  ".claude/scripts/pr-state.sh" \
  "$HOME/.claude/skills/fixpr/audit.sh" \
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

`/fixpr` may be invoked **with** a PR (`/fixpr <url>` or `/fixpr <N>`) or **with no argument**. Resolve the target into `$PR_NUMBER_ARG` *before* calling `pr-state.sh`, so a no-argument re-run is a fast convenience instead of a dead end (issue #447). The session-state half of this inference is shared verbatim with `/wrap` (issue #448) via `pr-state.sh --infer-candidates` — do not re-implement it.

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

- **Thread scan (AI layer).** Read back through *this* conversation for the most recent `/fixpr <url-or-number>` and `/wrap <url-or-number>` invocations and any PR the thread just operated on (pushed to, audited). Extract PR numbers from the `pull/<N>` pattern. Record them **in order, most-recently-mentioned first** — thread recency is the strongest signal (the issue's motivating case: a `/fixpr <url>` ran moments ago, then a bare `/fixpr`).
- **Session state (script layer).** Pull the PRs this session is actively tracking, newest activity first:

```bash
CANDIDATES_JSON=$("$SCRIPT" --infer-candidates 2>/dev/null || echo "[]")
# Prefer same-repo candidates; same_repo==null means "unknown repo, keep it".
SESSION_CANDIDATES=$(jq -c '[ .[] | select(.same_repo != false) ]' <<<"$CANDIDATES_JSON")
jq -r '.[] | "  session-candidate: #\(.number) (phase=\(.phase // "?"), needs=\(.needs // "?"), last_action=\(.last_action_at // "?"))"' <<<"$SESSION_CANDIDATES"
```

(`--infer-candidates` is a pure read of `~/.claude/session-state.json`; a global `pr-state.sh` too old to know the flag exits non-zero and the `|| echo "[]"` fallback degrades gracefully to thread-only inference.)

**3. Resolve candidates → `$PR_NUMBER_ARG` (or prompt).** Merge the thread list and `SESSION_CANDIDATES` into a unique set keyed by PR number, tracking each PR's source(s) (`thread`, `session`) and recency:

| Situation | Action |
|-----------|--------|
| **Exactly one unique candidate** (from either source) | Select it. Set `PR_NUMBER_ARG=<N>` and print the `[INFERRED]` line (formats below). Proceed — do **not** ask. |
| **Multiple candidates, one clearly most recent** | Pick the most-recently-mentioned. **Thread recency outranks session timestamps:** if any PR appeared in the thread scan, the newest thread mention wins; otherwise use the session candidate with the newest `last_action_at` (only when it is strictly newer than the next — not tied). Set `PR_NUMBER_ARG`, print the `[INFERRED]` line **and** the one-line `Also tracking:` note. |
| **Genuinely ambiguous** (two+ tied on recency, e.g. two thread PRs mentioned equally recently or session candidates tied on `last_action_at`) | Do **not** guess. Print `[CONTEXT] No PR argument and no branch PR; multiple candidates:` followed by the candidate list with sources, and ask the user which PR they meant — same behavior as before #447. Leave `PR_NUMBER_ARG` empty. |
| **No candidates at all** | Leave `PR_NUMBER_ARG` empty and fall through to branch auto-detection below — `pr-state.sh` with no `--pr` either finds the branch's PR or exits `3`/`4` and you report it (unchanged pre-#447 behavior). |

`[INFERRED]` log formats (print exactly one, before the `[CONTEXT]`/audit output below — it is the user's only catch point for a misfire):

```text
[INFERRED] PR #462 from thread context (last /fixpr invocation)
[INFERRED] PR #462 from session state (most recent activity at 2026-05-04T16:48:00Z)
[INFERRED] PR #462 (most recent of 2 active PRs); override with /fixpr #458 if needed
```

When inference picked from multiple candidates, append the override hint on its own line (one line; annotate each other PR with its session `needs`/`phase`):

```text
Also tracking: PR #458 (bugbot_review_poll), PR #445 (cr_confirmation_pass)
```

> **Authorship guard (issue #733, `safety.md`) — gate before Step 0c.** `/fixpr` pushes commits, force-pushes rebases, posts review triggers, and resolves threads — all writes. Once `$PR_NUMBER_ARG` is resolved, confirm you authored it:
> ```bash
> "$PR_AUTHORSHIP_SH" "$PR_NUMBER_ARG"   # exit 0 = yours
> ```
> Not yours (exit 1) or undetermined (exit 4) → **stop** with one line: "PR #$PR_NUMBER_ARG is authored by someone else — the authorship guard blocks automated writes; name this PR explicitly to override." Continue only under an explicit per-PR user override (say you are operating under it). Do this **before** Step 0c, since the pre-flight posts reviewer triggers.

### Step 0c: Pre-flight — draft→ready + four-reviewer trigger (issue #493)

Run the shared pre-flight **before** the audit so the PR is out of draft and all four conditionally-triggered reviewers (CodeAnt, CodeRabbit, Cursor, Graphite) are engaged on the current SHA before any finding-classification work begins. This is the same `pr-preflight.sh` invoked by `/babysit-pr` and `/pr-monitor-and-manage`, so the behavior is identical across all three skills — do **not** re-implement the draft flip or trigger logic inline.

```bash
PREFLIGHT_SH=""
for candidate in \
  "$HOME/.claude/skills-worktree/.claude/scripts/pr-preflight.sh" \
  "$HOME/.claude/scripts/pr-preflight.sh" \
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

`pr-preflight.sh` is idempotent and rate-cap safe: it marks the PR ready only when **you** authored it, never overrides someone else's intentional draft, never triggers Greptile, and skips `@coderabbitai full review` (still posting the other three) when `cr-review-hourly.sh` reports the cap hit. On a PR that is already ready with all four reviewers engaged **on the current HEAD SHA** it prints `Pre-flight clean — proceeding` and does nothing. Since #576 engagement is judged against HEAD rather than PR-wide history, a reviewer whose only artifact is on a superseded commit — the normal state after `/fixpr`'s own rebase + force-push — is re-triggered instead of being counted as present. Keep `$PREFLIGHT_SUMMARY_JSON` for the Step 7 "Pre-flight" line.

### Step 0b: Run the audit

Call `pr-state.sh` with the resolved PR when inference or an explicit argument produced one; otherwise fall back to branch auto-detection:

```bash
if [[ -n "$PR_NUMBER_ARG" ]]; then
  AUDIT=$("$SCRIPT" --pr "$PR_NUMBER_ARG")
else
  AUDIT=$("$SCRIPT")
fi
```

If `pr-state.sh` itself exits non-zero it prints the reason to stderr (no PR, closed PR, detached HEAD, etc.). Stop and report. Exit codes: `0` OK, `2` usage error, `3` no branch and no `--pr`, `4` PR closed/not found, `5` gh/network error. With Step 0a in place, exit `3` (no branch and no `--pr`) only reaches you when inference also found **no** candidate — that is the genuine "which PR did you mean?" case.

Pull the values that the later steps need out of the JSON once:

```bash
PR_NUMBER=$(jq -r '.pr.number' "$AUDIT")
OWNER=$(jq -r '.pr.owner' "$AUDIT")
REPO=$(jq -r '.pr.repo' "$AUDIT")
# Combined form for handoff scoping. Step 3a's path resolution reads
# ${OWNER_REPO:-}; leaving it unset skips handoff-state.sh entirely and takes
# Step 3a's own hard-coded literal flat path, which the phase agents never read
# back (issue #1302) — that is this skill's last-ditch fallback, not a helper
# fall-through. Since issue #1366 the helper resolves an omitted --owner-repo
# from $CLAUDE_SESSION_REPO, then the cwd's `origin`, and when neither yields an
# owner/repo it "exits 2 having written nothing.  It does NOT fall back to the
# flat path" (handoff-state.sh header) — reaching that path through the helper
# takes an explicit --legacy-flat. Set OWNER_REPO here so both branches stay
# scoped.
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

Do not ask the user before deciding. GitHub is the audit surface and chat is the decision surface: every thread touched by `/fixpr` must end resolved on GitHub, whether the decision was fix or decline.

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
  "$HOME/.claude/skills-worktree/.claude/scripts/cr-review-hourly.sh" \
  "$HOME/.claude/scripts/cr-review-hourly.sh" \
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

Only run when Step 3 made a push (`DID_PUSH=1`). Runs **after** `git push` and **before** Step 3b (reviewer triggers) so GitHub does not keep `reviewDecision: CHANGES_REQUESTED` from an obsolete bot review on an older commit.

Resolve the helper (same pattern as `pr-state.sh` / `cr-review-hourly.sh`):

```bash
DISMISS_STALE_SCRIPT=""
for candidate in \
  "$HOME/.claude/skills-worktree/.claude/scripts/dismiss-stale-bot-changes.sh" \
  "$HOME/.claude/scripts/dismiss-stale-bot-changes.sh" \
  ".claude/scripts/dismiss-stale-bot-changes.sh"; do
  if [[ -x "$candidate" ]]; then
    DISMISS_STALE_SCRIPT="$candidate"
    break
  fi
done
```

Optional handoff path (per `handoff-files.md`, one JSON file per PR):

```bash
# Resolve the canonical handoff path (issue #655: scoped per repo when owner_repo is known).
# OWNER_REPO is set in Step 0b from the pr-state.sh bundle; the `gh repo view
# --json nameWithOwner` form works too for a standalone invocation.
# With --owner-repo: ~/.claude/handoffs/{owner}/{repo}/pr-{N}-handoff.json
# The literal flat path below is only a fallback for when handoff-state.sh cannot
# be resolved at all — it is NOT what omitting --owner-repo does. Since issue
# #1366 an omitted scope derives owner/repo from the cwd, or exits 2 writing
# nothing; reaching the flat path through the helper needs --legacy-flat.
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
      # --owner-repo scopes the handoff append to the same file --handoff-file
      # names. Step 0b sets OWNER_REPO on every /fixpr run, so this is the
      # branch taken here. Without the flag dismiss-stale-bot-changes.sh
      # "[d]efaults to the `gh repo view` value" (its own header), which for a
      # /fixpr worktree need not match the PR being dismissed — so the IDs can
      # land in a different repo's scoped file, the split-brain that issue #1302
      # is about. Omission does not reach the flat path: that branch fires only
      # when --handoff-file already IS the flat path, and declares itself
      # --legacy-flat (issue #1366).
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

The script only dismisses **`CHANGES_REQUESTED`** reviews where **`commit_id` ≠ current PR HEAD** and the author is a **Bot** on the literal allowlist (`coderabbitai[bot]`, `cursor[bot]`, `greptile-apps[bot]`, `codeant-ai[bot]`, `graphite-app[bot]`). Human reviews are never dismissed. Logged lines look like `[DISMISS-STALE] dismissed stale bot CHANGES_REQUESTED review_id=…`.

---

## Step 3b: Trigger missing AI reviewers after a push

Only run this step when Step 3 made a push. If Step 3 skipped the commit/push, skip this step too.

> **Graphite known outage (issue #610):** the `@graphite-app re-review` trigger below has produced zero engagement (no comments, no check-runs) on any PR since 2026-05-08 — a confirmed external GitHub App issue, not something this step can fix. Still posted (cheap, self-healing); see `.claude/reference/codeant-graphite-supplemental.md` for evidence and the re-enablement path.

Re-resolve the hourly helper path (Step 3 may not have run in the same shell):

```bash
CR_HOURLY_SCRIPT=""
for candidate in \
  "$HOME/.claude/skills-worktree/.claude/scripts/cr-review-hourly.sh" \
  "$HOME/.claude/scripts/cr-review-hourly.sh" \
  ".claude/scripts/cr-review-hourly.sh"; do
  if [[ -x "$candidate" ]]; then
    CR_HOURLY_SCRIPT="$candidate"
    break
  fi
done
```

Use the `$PUSHED_AT` captured immediately before `git push` in Step 3. Capturing it before the push avoids a race where a fast bot starts between push completion and the timestamp capture. After the push completes, wait exactly 2 minutes before checking reviewer status so CodeRabbit / Graphite / CodeAnt auto-triggers have time to post activity (BugBot is covered separately — post `@cursor review` once per push, but not again on a HEAD it has already refused for spend; see `bugbot.md` and memory `feedback_bugbot_auto_trigger_unreliable.md`):

```bash
PUSHED_SHA=$(git rev-parse HEAD)
echo "[REVIEWERS] waiting 120s for auto-triggered reviewers on ${PUSHED_SHA:0:7}"
sleep 120
```

Detect activity from the 3 conditionally triggered reviewers (CodeRabbit, Graphite, CodeAnt) on the pushed SHA. Check all three PR comment endpoints plus check-runs for activity after `$PUSHED_AT`. Conversation-level comments do not expose a `commit_id`, so they only count as activity on the pushed SHA when the body mentions the full SHA or short SHA; otherwise, use SHA-scoped reviews, inline comments, or check-runs to avoid treating a late summary from the previous SHA as coverage for the new one:

```bash
# Delegate reviewer-activity detection to the extracted script.
# The script fetches all 3 comment endpoints + check-runs and emits
# { coderabbit, graphite, codeant } booleans. The trigger rate-cap /
# @coderabbitai full review decision logic stays below (in-turn judgment).
# Full detection logic: .claude/scripts/reviewer-activity.sh
REVIEWER_ACTIVITY_SH=""
for _candidate in \
  "$HOME/.claude/skills-worktree/.claude/scripts/reviewer-activity.sh" \
  "$HOME/.claude/scripts/reviewer-activity.sh" \
  ".claude/scripts/reviewer-activity.sh"; do
  if [[ -x "$_candidate" ]]; then REVIEWER_ACTIVITY_SH="$_candidate"; break; fi
done
if [[ -n "$REVIEWER_ACTIVITY_SH" ]]; then
  REVIEWER_ACTIVITY=$("$REVIEWER_ACTIVITY_SH" "$PR_NUMBER" "$PUSHED_SHA" "$PUSHED_AT")
else
  echo "[REVIEWERS] reviewer-activity.sh not found — re-run after .claude/scripts/ is synced from main" >&2
  REVIEWER_ACTIVITY='{"coderabbit":false,"graphite":false,"codeant":false}'
fi
```

For each of **coderabbit**, **graphite**, **codeant** whose value is `false`, post exactly one dedicated PR-level trigger comment. Do not batch mentions; combined-mention comments fail to trigger reliably. Post these comments sequentially in this order, skipping reviewers that already auto-triggered. CodeRabbit is additionally capped at 2 manual `@coderabbitai full review` triggers per PR in the trailing hour:

```bash
jq -r 'to_entries[] | "[REVIEWERS] \(.key): \(if .value then "auto-triggered" else "missing" end)"' <<<"$REVIEWER_ACTIVITY"

CR_TRIGGER_COUNT_LAST_HOUR=$(gh api --paginate "repos/$OWNER/$REPO/issues/$PR_NUMBER/comments?per_page=100" | jq -s '
  (add // [])
  | map(select(
      (.body // "") == "@coderabbitai full review"
      and ((.created_at // "") >= (now - 3600 | strftime("%Y-%m-%dT%H:%M:%SZ")))
    ))
  | length
')

if [[ "$(jq -r '.coderabbit' <<<"$REVIEWER_ACTIVITY")" != "true" ]]; then
  if [[ "$CR_TRIGGER_COUNT_LAST_HOUR" -lt 2 ]]; then
    if gh pr comment "$PR_NUMBER" --body "@coderabbitai full review"; then
      # Persist explicit trigger only when the comment actually posted (avoid ghost timestamps on gh failure)
      if [[ -n "$CR_HOURLY_SCRIPT" ]]; then
        "$CR_HOURLY_SCRIPT" --record-explicit "$PR_NUMBER" || true
      fi
    else
      echo "[REVIEWERS] FAILED to post @coderabbitai full review — check gh auth scopes; not recording explicit trigger" >&2
    fi
  else
    echo "[REVIEWERS] coderabbit trigger budget exhausted (>=2 in the last hour); skipping manual trigger"
    if [[ -n "$CR_HOURLY_SCRIPT" ]]; then
      echo "[REVIEWERS] Surface to user: this PR has hit 2 explicit @coderabbitai full review posts in the last hour — CodeRabbit may be rate-limited; wait for reviews or use local CR (cr-local-review.md)."
    fi
  fi
fi
if [[ "$(jq -r '.graphite' <<<"$REVIEWER_ACTIVITY")" != "true" ]]; then
  gh pr comment "$PR_NUMBER" --body "@graphite-app re-review"
fi
if [[ "$(jq -r '.codeant' <<<"$REVIEWER_ACTIVITY")" != "true" ]]; then
  gh pr comment "$PR_NUMBER" --body "@codeant-ai review"
fi
# BugBot may ALREADY have refused this fresh HEAD: it auto-runs on push, so by
# the time Step 3b executes a usage-limit refusal can be sitting on the very
# commit we just created (observed on PR #1203 — refusal, CI nudge, second
# refusal, all within seven seconds). One shared check answers it; it fails open,
# so an unreadable or unattributable state still posts.
BUGBOT_REFUSED_SH=""
for candidate in \
  "$HOME/.claude/skills-worktree/.claude/scripts/bugbot-refused-head.sh" \
  "$HOME/.claude/scripts/bugbot-refused-head.sh" \
  ".claude/scripts/bugbot-refused-head.sh"; do
  if [[ -x "$candidate" ]]; then BUGBOT_REFUSED_SH="$candidate"; break; fi
done
if [[ -n "$BUGBOT_REFUSED_SH" ]] && "$BUGBOT_REFUSED_SH" "$PR_NUMBER" "$PUSHED_SHA" >/dev/null 2>&1; then
  echo "[REVIEWERS] skipping @cursor review — BugBot already refused this HEAD for a Cursor usage/spend limit (#1204)"
else
  gh pr comment "$PR_NUMBER" --body "@cursor review"
fi
```

Cost/rate-limit note: `@codeant-ai review` may consume CodeAnt’s review budget, so skip it when auto-trigger activity is already present on the new SHA. **`@cursor review` is posted once per push, gated on `bugbot-refused-head.sh`** (composes with CI and issue #370’s four-reviewer triggers). BugBot is per-seat but **spend-metered** — the stack's largest cost line, refusing 64% of PRs (#1199/#1204) — and no nudge clears a usage limit, so the trigger is skipped when `cursor[bot]` has already refused *this* HEAD. It auto-runs on push, so that refusal can land before Step 3b even executes; the check is shared with `maybe-trigger-ai-review.sh` and fails open. Greptile is intentionally NOT part of this proactive trigger set; it remains last-resort only per `greptile.md`.

**Composition with issue #362:** `cr-github-review.md` runs `maybe-trigger-ai-review.sh` on each poll tick when there is **no** `/fixpr` trigger (no new findings, CI green, not `BEHIND`/`CONFLICTING`). That path fires three single-mention comments — `@codeant-ai review`, `@cursor review`, `@graphite-app re-review` — for **complexity + CR round count**, not because of a push. This differs from Step 3b, which additionally posts `@coderabbitai full review` (subject to the 2/hour cap) when CodeRabbit has not yet auto-triggered on the new SHA. State for the #362 path is tracked in `session-state.json` so it does not batch with Step 3b on the same cause.

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
"$REPLY_THREAD_SH" "$DBID" --reviewer "$REVIEWER" \
  --body "$REPLY" --pr "$PR_NUMBER"
```

The script strips any `@greptileai` tokens from the body in greptile mode and any `@cursor` tokens in bugbot mode — so even a stray mention in `$REPLY` cannot trigger a paid Greptile re-review ($0.50–$1.00). `@greptileai` is reserved exclusively for intentionally requesting a new review. See `reply-thread.sh --help` for the full exit-code contract.

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

**Unchanged-line threads:** GitHub only auto-resolves a review thread when the **exact** commented line changes. If `/fixpr` fixed the issue by editing nearby code (or declined/OBE), the thread can stay `isResolved: false` after Step 4b until the script runs `resolveReviewThread` / `minimizeComment` on that thread id. The explicit `--thread-ids-file` set forces resolution for **every** addressed thread, not only those GitHub auto-closed.

The script re-fetches `pullRequest.reviewThreads` via GraphQL after each mutation pass and again before exit. For any touched thread still reporting `isResolved: false`, it retries `resolveReviewThread` and falls back to `minimizeComment(classifier: RESOLVED)`. Exit codes: `0` means every touched thread was verified resolved; `1` means at least one dangling thread remains and `/fixpr` must not declare success; `3` PR not found; `4` gh error. It prints `[VERIFY] addressed=N resolved=M dangling=K` plus `[STUCK]` lines with URLs/reasons for every dangling thread.

Keep `$TOUCHED_THREADS` until after Step 4c (same path as Step 4b).

### 4c. Post-push: re-resolve and verify touched threads on the new HEAD

Run **only when Step 3 pushed** (`DID_PUSH=1`). A new commit can reopen threads that were resolved on the prior HEAD (or leave unchanged-line threads still open until an explicit resolve sees the post-push graph).

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
- `DID_PUSH=0` (idempotent path) → run **one** snapshot tick first on the current HEAD (`WATCH_SHA=$HEAD_SHA`, `WAIT_BASELINE=$RUN_STARTED_AT`) using the same `pr-state.sh` + jq predicate as the loop below, **without incrementing `FIXPR_WAIT_ITER`**. If `bots_pending`, `ci_pending`, and `ci_failing` are all empty and `new_findings == 0`, set `FIXPR_WAIT_FINAL=clean` and **skip the wait loop entirely — zero wait, zero iterations, no push** — proceed to Step 5. If bots or CI are still pending on the current SHA (e.g. `/wrap` delegated here mid-review), fall through to the wait loop (which increments `FIXPR_WAIT_ITER` once at entry).

**Per-tick snapshot — reuse `pr-state.sh`, do not re-invent endpoint polling.** Set `WATCH_SHA` / `WAIT_BASELINE` from the entry path above (`PUSHED_SHA`/`PUSHED_AT` when `DID_PUSH=1`, else `HEAD_SHA`/`RUN_STARTED_AT`). Each tick fetches one fresh bundle (all 3 comment endpoints + check-runs + commit statuses, `per_page=100`, classification since baseline — the same primitives as `cr-github-review.md`):

```bash
# Idempotent pre-check (DID_PUSH=0 only) — one tick, no iter increment
SKIP_WAIT_LOOP=0
if [[ "${DID_PUSH:-0}" -eq 0 ]]; then
  WATCH_SHA=$HEAD_SHA
  WAIT_BASELINE=$RUN_STARTED_AT
  TICK=$("$SCRIPT" --pr "$PR_NUMBER" --since "$WAIT_BASELINE")
  WAIT_STATE=$("$SCRIPT" --wait-state-eval "$WATCH_SHA" "$TICK")
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
  TICK=$("$SCRIPT" --pr "$PR_NUMBER" --since "$WAIT_BASELINE")
  WAIT_STATE=$("$SCRIPT" --wait-state-eval "$WATCH_SHA" "$TICK")

  ELAPSED=$(( $(date +%s) - WAIT_STARTED ))
  BOTS_PENDING=$(jq -r '.bots_pending | join(", ") | if . == "" then "none" else . end' <<<"$WAIT_STATE")
  CI_PENDING=$(jq -r '.ci_pending | join(", ") | if . == "" then "none" else . end' <<<"$WAIT_STATE")

  # Heartbeat — every tick, user-visible, ET-timestamped
  TS=$(TZ='America/New_York' date +'%a %b %-d %I:%M %p ET')
  echo "[$TS] [WAIT] iter $FIXPR_WAIT_ITER/$FIXPR_MAX_ITERATIONS — ${ELAPSED}s/${FIXPR_WAIT_CAP_SECS}s on ${WATCH_SHA:0:7} — bots pending: $BOTS_PENDING — CI pending: $CI_PENDING"

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

**Running this block as a worktree-isolated subagent.** The block above is a multi-line loop, which the harness's worktree-isolation guard refuses when pasted directly — it classifies by command shape, and the refusal names git operations that are not in it (issue #1470). Write the block to a file in the session scratchpad and run `bash <file>`: a single plain call is an allowed shape, and everything inside it then runs in a child process the guard does not gate. Do **not** try to flatten it onto `wait-until.sh` — that wrapper answers met/not-met, while this loop is a five-way classifier (`clean` / `new-findings` / `ci-failing` / `head-moved` / `cap-exhausted`) whose outcome routes the rest of the skill. Catalog of refused vs allowed shapes: `.claude/reference/worktree-isolation-command-shapes.md`.

**Participating-bot set is DYNAMIC** — computed fresh each tick from the bot logins seen in any review or comment on this PR, intersected with the allowlist. A CR-only PR never waits on Greptile/BugBot signals. Never use a static list.

**Optional CR re-trigger inside the wait** (per `cr-merge-gate.md` re-trigger policy): if `coderabbitai[bot]` is participating and still pending after **12 min** (`ELAPSED >= 720`) and `RETRIGGERED_THIS_WAIT=0`, you may post one `@coderabbitai full review` — but ONLY when `cr-review-hourly.sh --check` exits 0 AND `cr-review-hourly.sh --record-explicit "$PR_NUMBER"` succeeds (it enforces the ≤2 explicit triggers/PR/hour cap atomically and exits 1 at the cap — at the cap, skip the trigger and keep waiting). Set `RETRIGGERED_THIS_WAIT=1` — at most one re-trigger per wait iteration. The wait loop never triggers any other reviewer; Step 3b owns those.

**Routing on `WAIT_OUTCOME`:**

| Outcome | Action |
|---------|--------|
| `clean` | Set `FIXPR_WAIT_FINAL=clean`. Proceed to Step 5 — the verify pass gives the authoritative classification of what the bots posted. |
| `new-findings`, `ci-failing`, or `head-moved` | If `FIXPR_WAIT_ITER < FIXPR_MAX_ITERATIONS` → start the **next sweep at Step 0** (fresh `$RUN_STARTED_AT` picks up the new findings; the sweep fixes, pushes once, and re-enters this wait on the new SHA). Else at outer cap, set `FIXPR_WAIT_FINAL` and Status **per outcome** — do not blanket-label everything `new-findings-pending`: `new-findings` → `FIXPR_WAIT_FINAL=new-findings-pending`, Status `NEW_FINDINGS`; `ci-failing` → `FIXPR_WAIT_FINAL=cap-exhausted`, Status `CI_FAILING`; `head-moved` → `FIXPR_WAIT_FINAL=cap-exhausted`, Status note external push in summary (re-run `/fixpr`). |
| `cap-exhausted` | Set `FIXPR_WAIT_FINAL=cap-exhausted`. Proceed to Step 5/7 — the cap-hit lines above (pending bots + incomplete CI) MUST appear in the final summary; the status will be `REVIEW_PENDING` or `CI_PENDING` per what is outstanding. |

**Safety (non-negotiable, issues #450/#452/#454):** this loop is read-only plus the single rate-capped CR re-trigger above. It never calls branch-protection APIs, never dismisses human reviews, and never resolves threads — thread resolution happens only in Steps 1–4 after code-verification.

---

## Step 5: Verify

Run the audit script again with `--since $RUN_STARTED_AT`. This picks up the new HEAD SHA (post-push) **and** pre-classifies any bot comment that landed between Step 0 and now:

```bash
VERIFY=$("$SCRIPT" --since "$RUN_STARTED_AT")
```

### 5a. Threads

The Step 4b resolver (and, when `DID_PUSH=1`, Step 4c’s resolve + `--verify-only` passes) re-fetched `pullRequest.reviewThreads` via GraphQL, retried `resolveReviewThread`, used `minimizeComment(classifier: RESOLVED)` as fallback, and printed addressed/resolved/dangling counts. Re-state the **latest** `[VERIFY]` line(s) here from `THREAD_RESOLUTION_OUTPUT` plus `POST_PUSH_THREAD_OUTPUT` / `POST_PUSH_VERIFY_OUTPUT` when Step 4c ran; do not recompute from `.threads.unresolved_count` alone because `/fixpr` must verify the specific threads it replied to.

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

**Classification rules** live in `.claude/scripts/lib/pr-state-classify.jq` (the block comment above `def classify:` is the authoritative contract — do NOT duplicate it here). `pr-state.sh --since` supplies the endpoint arrays and timestamp bindings, then exposes the result through the unchanged `new_since_baseline` bundle fields. Key ordering invariants: tier-1 explicit-resolution overrides (addressed/withdrawn markers, zero-actionable phrases, rate-limit notices, BugBot usage-limit notices, full-review-triggered ack, clean-pass phrases, error stub, auto-reply ack) are checked first and win even if finding language appears in quoted context. Finding patterns (severity, badges, actionable phrases, suggestion blocks) come next. Weak-ack fallbacks (lgtm variants) follow. The CR walkthrough summary override and Greptile clean-pass summary come LAST — their late placement is load-bearing (a walkthrough can carry N>0 finding count; hoisting it would produce false-clean verdicts). Default → finding (under-classifying is the failure mode).

**If `finding_count > 0`:** findings landed between the Step 4d wait exit and this verify. If `FIXPR_WAIT_ITER < FIXPR_MAX_ITERATIONS`, start the next sweep at Step 0 (a fresh `$RUN_STARTED_AT` re-audits and picks them up). At the outer cap: set `FIXPR_WAIT_FINAL=new-findings-pending`, emit `NEW_FINDINGS` in Step 7, and stop — re-running `/fixpr` resets the iteration budget.

### 5c. CI (if a push was made; exclude review-bot check-runs from CI pending)

The verify audit's `.check_runs` reflects the new HEAD.

```bash
jq -r '.check_runs.all[] | "[CI] \(.name): \(.status)\(if .conclusion then " — \(.conclusion)" else "" end)"' "$VERIFY"

CHECK_BUCKETS=$(jq '
  def is_review_bot:
    (.name // "" | ascii_downcase) as $name
    | (.app.slug // "" | ascii_downcase) as $slug
    | (.app.name // "" | ascii_downcase) as $app
    | ($name | contains("coderabbit")
       or contains("graphite")
       or contains("codeant")
       or contains("cursor"))
      or ($slug | contains("coderabbit")
         or contains("graphite")
         or contains("codeant")
         or contains("cursor"))
      or ($app | contains("coderabbit")
         or contains("graphite")
         or contains("codeant")
         or contains("cursor"));
  {
    ci: [.check_runs.all[] | select(is_review_bot | not)],
    review: [.check_runs.all[] | select(is_review_bot)]
  }
' "$VERIFY")
CI_CHECKS=$(jq '.ci' <<<"$CHECK_BUCKETS")
REVIEW_BOT_CHECKS=$(jq '.review' <<<"$CHECK_BUCKETS")

FAILING=$(jq '[.[] | select(.conclusion == "failure" or .conclusion == "timed_out" or .conclusion == "action_required" or .conclusion == "startup_failure" or .conclusion == "stale")] | length' <<<"$CI_CHECKS")
IN_PROGRESS=$(jq '[.[] | select(.status != "completed")] | length' <<<"$CI_CHECKS")
REVIEW_IN_PROGRESS=$(jq '[.[] | select(.status != "completed")] | length' <<<"$REVIEW_BOT_CHECKS")
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

CR and Greptile report review completion via commit *statuses*, while Graphite, CodeAnt, and Cursor may report via check-runs. `pending` means a bot is still analyzing the current HEAD — declaring CLEAN while pending is the exact failure mode this verify step was built to prevent.

```bash
jq -r '
  .bot_statuses | to_entries[] | "[VERIFY-BOTS] \(.key): \(.value.state) (\(.value.updated_at))"
' "$VERIFY"
```

For each bot present in `.bot_statuses` or the current-head check-runs:

- **CodeRabbit specifically** (by status `context` / bot name) with `description` containing "rate limit" (case-insensitive) → CR rate-limited, fall back to Greptile per `cr-github-review.md`. CodeRabbit reports this as non-blocking `state: "success"` — check this **before** the `state: success` clean-pass rule below, not just on `failure`/`error`. Other bots are not subject to this rule — a Greptile or other status whose text happens to contain "rate limit" is not CR rate-limiting and falls through to the rules below.
- `state: success` (and not the CodeRabbit rate-limit case above) → review completed on this SHA. Clean-pass signal.
- `state: pending` or check-run `status != "completed"` → bot still running. **Do NOT declare CLEAN.** Emit `REVIEW_PENDING` and stop.
- No activity from CodeRabbit, Graphite, CodeAnt, or Cursor after a pushed fix commit → the Step 3b trigger check should already have posted the reviewer-specific comment. Emit `REVIEW_PENDING` and re-run `/fixpr` after the reviewer responds.

---

## Step 6: Check merge blockers

```bash
jq -r '.merge_state | "[MERGE] mergeable=\(.mergeable), status=\(.mergeStateStatus), review=\(.reviewDecision)"' "$VERIFY"
```

### 6a. Diff-survival guard — MANDATORY around every rebase (issue #757)

A conflict resolution with no markers still satisfies git even when it silently kept the other side and dropped the entire change the PR exists to deliver. Nothing else in this workflow catches that: status is clean, CI is green, review sees a PR that no longer contains its own fix. Wrap **every** rebase below — interactive and safe-only alike — in this pair:

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
- **`2`** — named files lost their changes. **Do not force-push, do not trigger reviewers, do not run Step 3a/3b/4d.** Report the named files and return `Status: CONFLICTS` / `FIXPR_WRAP_STATUS: CONFLICTS` — a vaporized diff is an *unresolved* conflict, not a push.
- **`4`** — unresolved conflicts remain, the snapshot is for another branch, or verdict `unverifiable`. On `unverifiable` the snapshot's baseline commit *is* the commit being checked, so the comparison proves nothing: **do not force-push** — report the resolution as UNVERIFIED and treat it as unresolved.
- **`5`** — no snapshot exists (the rebase was started by an earlier session). Run `"$GUARD" snapshot --if-absent`, then `verify`. **This only reconstructs a real baseline while the rebase is still in progress** — mid-rebase the guard reads the rebase's `orig-head` rather than the half-replayed HEAD. If the rebase has **already finished**, no baseline can be reconstructed after the fact: `verify` returns `unverifiable` (exit 4) rather than a false pass. Do not push on that verdict — say the resolution could not be verified and let a human decide.

The guard **never repairs anything**; recovery (`git rebase --abort`, or resetting to `ORIG_HEAD`) stays a deliberate human step. In **safe-only mode** (`BABYSIT_SAFE_CONFLICT_MODE=1`) a non-zero verify is surfaced upstream exactly like a complex hunk — emit the `CONFLICT_COMPLEX_REPORT_JSON:` line (use the guard's `--json` object as the value) plus `FIXPR_WRAP_STATUS: CONFLICTS`, so `/babysit-pr` T4 terminates `hard-blocked` with the lost-file report instead of counting a vaporized push as forward progress. Full contract: `.claude/reference/diff-survival-guard.md`.

| Field | Blocking value | Action |
|-------|---------------|--------|
| `mergeable` | `CONFLICTING` | **Run `diff-survival-check.sh snapshot` before the rebase and `verify` before the force-push — Step 6a is mandatory on both branches of this row.** **Default (interactive):** Rebase onto main: `git fetch origin main && git rebase origin/main`. Fix conflicts (optionally run **`/merge-conflict`** — `.claude/skills/merge-conflict/SKILL.md` — to fetch main, auto-resolve *simple* hunks, stage clean files, and list *complex* hunks), continue, force-push. **Safe-only mode (`BABYSIT_SAFE_CONFLICT_MODE=1`):** invoked by `/babysit-pr --auto-resolve-conflicts` for unattended resolution. After `git fetch origin main && git rebase origin/main` stops on conflicts, locate and invoke `resolve_merge_conflicts.py --repo "$(git rev-parse --show-toplevel)" --json` directly (candidate-path lookup: skills-worktree first, then in-repo). Branch on exit code: exit `0` (all hunks simple, files staged, empty `complex_report`) → run `git rebase --continue`, then **run the Step 6a `verify` gate before anything else** and only on `GUARD_RC == 0` treat it as push-equivalent (force-push, run Step 3a + Step 3b + Step 4d on the new SHA); exit `1` (any complex hunk, partial resolution, or stage failure) → run `git rebase --abort`, do NOT attempt any manual/semantic resolution, and emit the following lines so the caller can capture the structured report — then return with `Status: CONFLICTS` and `FIXPR_WRAP_STATUS: CONFLICTS`: <br><br>```text`<br>CONFLICT_COMPLEX_REPORT_JSON: <the raw JSON value of complex_report from the resolver's --json output>`<br>```<br><br>Store the emitted `CONFLICT_COMPLEX_REPORT_JSON` line into `.babysit.last_dispatch.complex_report` (or parse it from the fixpr output) so T-END can render each `{file, location, reason}` entry verbatim in the termination report. In safe-only mode, **never** attempt to hand-resolve or semantically merge a complex hunk — abort and report only. |
| `mergeable` | `UNKNOWN` | GitHub still computing — note and re-run `/fixpr` later. |
| `mergeStateStatus` | `BEHIND` | **First run `"$CLEAN_BEHIND_SH" "$PR_NUMBER"` (issues #631, #667).** Exit 0 (`safe_to_offer`: gate green except BEHIND, not CONFLICTING, AC verified, base delta line ranges don't intersect PR line ranges at hunk level — conservative file-level fallback when patches unavailable) → **stop looping rebases and run `"$ADMIN_MERGE_SH" "$PR_NUMBER" --auto-plain --ac-verified`** (issue #754) — but **only after completing `cr-merge-gate.md` Step 2** (verify every Test Plan checkbox against the source at this SHA; ticked boxes are the proxy `clean-behind-check.sh` already checked, not verification). Any criterion that fails → fix it, do not merge; the script refuses without `--ac-verified`. Exit 0 → merged; relay its `AUTO_PLAIN_MERGED` evidence block. **No `AskUserQuestion`** — the plain shape modifies no branch protection, so it needs no user turn. Exit 8 → the shape needs a protection change (or an auto attempt already ran): **offer `/admin-merge` as a user choice** (AskUserQuestion, or print the command when running non-interactively) and **never auto-run** it. Exit 1 → not safe after re-validation (e.g. main advanced); fall through to the rebase path below. The `churn.advisory` field is context, not a gate (sensitivity configurable via `--churn-threshold N` or `CHURN_THRESHOLD` env var, default 1). Exit 1 (not safe — especially a base-delta↔PR-file overlap, or any residual blocker) → **capture the Step 6a snapshot (`diff-survival-check.sh snapshot`), then** rebase onto main: `git fetch origin main && git rebase origin/main`. If conflicts arise mid-rebase (replaying commits individually can conflict even when a three-way merge wouldn't), resolve them the same way as `CONFLICTING` above (including optional **`/merge-conflict`**), then `git rebase --continue`. **Run the Step 6a `verify` gate; force-push only on `GUARD_RC == 0`** — a non-zero verdict blocks the push and returns `Status: CONFLICTS`. When `FIXPR_WAIT_ITER < FIXPR_MAX_ITERATIONS`, treat the force-push as push-equivalent: set `PUSHED_SHA=$(git rev-parse HEAD)`, `PUSHED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")`, `DID_PUSH=1`, run **Step 3a** (dismiss stale bot reviews), **Step 3b** (reviewer triggers + 120s wait), then **Step 4d** on the new SHA. Do **not** jump straight to Step 4d without 3a/3b — bots are never kicked on the rebased SHA otherwise. |
| `mergeStateStatus` | `BLOCKED` | Required checks/reviews missing — already covered by 5c/5d. If CodeRabbit, Greptile, or CodeAnt is in CODEOWNERS and the last approval is stale/dismissed after a push, recover by triggering that bot (`@coderabbitai full review`, `@greptileai`, or `@codeant-ai review`) instead of escalating to the author. |
| `mergeStateStatus` | `UNSTABLE` | A non-required check pending/failing — typically CR/Greptile on the new SHA. If 5d emitted `REVIEW_PENDING`, stop with that status. |
| `reviewDecision` | `CHANGES_REQUESTED` | Changes were requested. **Stale** bot `CHANGES_REQUESTED` (wrong `commit_id` vs HEAD) are cleared by Step 3a after each push — not escalation. If a **human** left `CHANGES_REQUESTED` on the current HEAD, report as non-automatable. |

When residual branch protection says review is missing or `reviewDecision != "APPROVED"`, run `"$MERGE_GATE_SH" "$PR_NUMBER"` and read `.code_owner_bots`. If it lists `coderabbitai[bot]`, `greptile-apps[bot]`, or `codeant-ai[bot]`, a current-HEAD **`APPROVED`** review from that bot satisfies GitHub's code-owner requirement. CodeAnt **check-run success** only covers the supplemental CR-path cleanliness rule in `cr-merge-gate.md`; it does **not** replace an `APPROVED` when CodeAnt is a code owner. A stale/dismissed bot approval is recoverable review debt: trigger the matching bot and re-run the gate after it responds. Do not ask the PR author for an approval GitHub will not accept.

After any rebase + force-push: `[MERGE] rebase complete, force-pushed (SHA: <new-sha>) — CI re-triggered. Re-run /fixpr after CI completes.`

---

## Step 7: Final summary

```text
=== fixpr complete ===
PR:              #$PR_NUMBER ($BRANCH)
Pre-flight:      <draft→ready action if any + reviewers triggered, from $PREFLIGHT_SUMMARY_JSON; "clean" when nothing was done; "skipped" when no PR/script>
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

Render the **Pre-flight** line from `$PREFLIGHT_SUMMARY_JSON` (Step 0c): when `.clean == true` print `clean — already ready, all 4 reviewers engaged`; otherwise summarize `.draft_action` (e.g. `marked ready`) plus the reviewer keys whose `.status == "triggered"` (and note any `skipped-rate-cap`). When the pre-flight was skipped (no PR resolved yet, or the script was missing) print `skipped`.

`/wrap` recovery may delegate here; parents grep **`FIXPR_WRAP_STATUS:`** and **`FIXPR_WAIT_SUMMARY:`** (and echo **`Status:`**) into heartbeats without re-parsing prose. `FIXPR_WAIT_SUMMARY` is the issue #454 contract: `/wrap` trusts this verdict — the bots and CI were already waited on here, so `/wrap` re-runs `merge-gate.sh` immediately with no polling of its own. `final=clean` when the last wait exited on a full bot+CI verdict (or the idempotent no-push path was already clean — `iterations=0`); `final=cap-exhausted` when the last wait hit `FIXPR_WAIT_CAP_SECS`; `final=new-findings-pending` when the outer iteration cap exhausted with findings still arriving.

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
