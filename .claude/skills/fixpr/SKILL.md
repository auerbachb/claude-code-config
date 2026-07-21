---
name: fixpr
description: Bounded-convergence PR cleanup — audit every review thread + every CI check-run, fix all issues, push once per sweep, dismiss stale bot CHANGES_REQUESTED on old commits, resolve all threads via GraphQL, then wait (capped) for bot verdicts + CI on the new SHA, re-sweeping on new findings up to 5 iterations. Zero uncollapsed threads and zero failing checks when done.
---

Bounded-convergence cleanup of the current branch's PR (issue #454 added the post-push review-wait loop to the original single-pass design). After this completes:

1. **Zero uncollapsed review threads** in the browser (all resolved via GraphQL)
2. **Zero failing CI checks** (all fixed and passing)
3. **Every finding replied to** with what was done
4. **A definitive bot verdict on the final SHA** — or an explicit cap-hit report naming what is still pending (never a silent "we pushed, bye" exit)

### Batching before burning CR quota (Issue #28)

CodeRabbit caps **~8 GitHub PR reviews per hour** per account; **each push** consumes one. **Multi-round PRs** exhaust that budget fast if you fix-and-push repeatedly.

**Coalesce locally first:** Before opening `/fixpr` on minor iterations, run the dual-CLI local review (**`coderabbit review --agent`** + **`codeant review --uncommitted --headless`**) per `cr-local-review.md` on uncommitted changes when feasible — catch issues **before** they cost a GitHub review.

**Coalesce inside `/fixpr`:** Steps 1–3 intentionally gather **every** unresolved finding + every failing CI check, then fix **all** actionable items and **`git push` once**. Never push once per finding. One `/fixpr` cycle should produce **at most one** consume-side CR review per completed push (tracked below).

## How this skill is structured

> **pr-state.sh first (NON-NEGOTIABLE):** Before calling `gh api .../pulls/{N}/reviews`, `pulls/{N}/comments`, or `issues/{N}/comments` directly, call `pr-state.sh --pr N` first and read the cached JSON bundle. Inline `gh api` calls for these three endpoints are only permitted inside Step 3b's reviewer-activity detection block, which requires a custom post-push timestamp filter that `pr-state.sh` does not expose. Every other polling or review-state lookup MUST go through `pr-state.sh`.

All mechanical GitHub API work — pagination, GraphQL queries, comment classification — lives in the shared script `.claude/scripts/pr-state.sh`. This file tells the AI layer how to invoke the script and what to do with its output (the JSON bundle).

| Step | Kind | Done by |
|------|------|---------|
| 0a. Resolve target PR (arg or infer) | Judgment + Mechanical | AI thread scan + `pr-state.sh --infer-candidates` (no-arg inference, issue #447) |
| 0. Gather PR state | Mechanical | `pr-state.sh` writes `/tmp/pr-state-<PR>-<epoch>.json` |
| 1. Classify review findings | Judgment | AI reads JSON + source files |
| 2. Classify CI failures | Judgment | AI reads `check-runs/<id>.output.summary` |
| 3. Fix & push | Judgment | AI edits files, commits, pushes |
| 3a. Dismiss stale bot `CHANGES_REQUESTED` | Mechanical | `dismiss-stale-bot-changes.sh` after push when `DID_PUSH=1`; optional `--handoff-file` append |
| 3b. Trigger missing AI reviewers | Mechanical | wait 2 minutes, detect CR/Graphite/CodeAnt activity on the new SHA, post triggers for missing bots, always post `@cursor review` |
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
HANDOFF_JSON="${HANDOFF_JSON:-$HOME/.claude/handoffs/pr-${PR_NUMBER}-handoff.json}"
# mkdir -p "$(dirname "$HANDOFF_JSON")"  # if the file may not exist yet
```

Run dismissal (idempotent where PUT succeeds or review already **DISMISSED**; genuine dismissal failures cause **exit 4**). Handoff: append **only** when `--handoff-file` exists and parses as JSON; missing path logs a warn and skips append (caller creates full handoff); invalid JSON exits **4**.

```bash
if [[ "${DID_PUSH:-0}" -eq 1 ]]; then
  if [[ -n "$DISMISS_STALE_SCRIPT" ]]; then
    if [[ -n "${HANDOFF_JSON:-}" ]]; then
      "$DISMISS_STALE_SCRIPT" "$PR_NUMBER" --handoff-file "$HANDOFF_JSON"
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

Use the `$PUSHED_AT` captured immediately before `git push` in Step 3. Capturing it before the push avoids a race where a fast bot starts between push completion and the timestamp capture. After the push completes, wait exactly 2 minutes before checking reviewer status so CodeRabbit / Graphite / CodeAnt auto-triggers have time to post activity (BugBot is covered separately — always trigger `@cursor review` unconditionally; see `bugbot.md` and memory `feedback_bugbot_auto_trigger_unreliable.md`):

```bash
PUSHED_SHA=$(git rev-parse HEAD)
echo "[REVIEWERS] waiting 120s for auto-triggered reviewers on ${PUSHED_SHA:0:7}"
sleep 120
```

Detect activity from the 3 conditionally triggered reviewers (CodeRabbit, Graphite, CodeAnt) on the pushed SHA. Check all three PR comment endpoints plus check-runs for activity after `$PUSHED_AT`. Conversation-level comments do not expose a `commit_id`, so they only count as activity on the pushed SHA when the body mentions the full SHA or short SHA; otherwise, use SHA-scoped reviews, inline comments, or check-runs to avoid treating a late summary from the previous SHA as coverage for the new one:

```bash
REVIEWS=$(gh api --paginate "repos/$OWNER/$REPO/pulls/$PR_NUMBER/reviews?per_page=100" | jq -s 'add // []')
INLINE=$(gh api --paginate "repos/$OWNER/$REPO/pulls/$PR_NUMBER/comments?per_page=100" | jq -s 'add // []')
CONVO=$(gh api --paginate "repos/$OWNER/$REPO/issues/$PR_NUMBER/comments?per_page=100" | jq -s 'add // []')
CHECK_RUNS=$(gh api --paginate "repos/$OWNER/$REPO/commits/$PUSHED_SHA/check-runs?per_page=100" --jq '.check_runs[]' | jq -s '.')

REVIEWER_ACTIVITY=$(jq -n \
  --arg pushed_at "$PUSHED_AT" \
  --arg sha "$PUSHED_SHA" \
  --argjson reviews "$REVIEWS" \
  --argjson inline "$INLINE" \
  --argjson convo "$CONVO" \
  --argjson checks "$CHECK_RUNS" \
  '
  def recent($ts): ($ts // "") >= $pushed_at;
  def matches_any($value; $needles):
    ($value // "" | ascii_downcase) as $haystack
    | any($needles[]; (. | ascii_downcase) as $needle | $haystack | contains($needle));
  def check_by($names):
    any($checks[]?;
      (((.name // "") as $name
        | (.app.slug // "") as $slug
        | (.app.name // "") as $app
        | (matches_any($name; $names) or matches_any($slug; $names) or matches_any($app; $names))))
      and recent(.started_at // .created_at // .completed_at));
  def convo_by($login):
    any($convo[]?;
      .user.login == $login
      and recent(.created_at)
      and (((.body // "") | contains($sha)) or ((.body // "") | contains($sha[0:7]))));
  {
    coderabbit:
      (any($reviews[]?; .user.login == "coderabbitai[bot]" and .commit_id == $sha and recent(.submitted_at))
       or any($inline[]?; .user.login == "coderabbitai[bot]" and ((.commit_id // .original_commit_id // "") == $sha) and recent(.created_at))
       or convo_by("coderabbitai[bot]")
       or check_by(["CodeRabbit", "coderabbitai"])),
    graphite:
      (any($reviews[]?; .user.login == "graphite-app[bot]" and .commit_id == $sha and recent(.submitted_at))
       or any($inline[]?; .user.login == "graphite-app[bot]" and ((.commit_id // .original_commit_id // "") == $sha) and recent(.created_at))
       or convo_by("graphite-app[bot]")
       or check_by(["Graphite", "graphite-app"])),
    codeant:
      (any($reviews[]?; .user.login == "codeant-ai[bot]" and .commit_id == $sha and recent(.submitted_at))
       or any($inline[]?; .user.login == "codeant-ai[bot]" and ((.commit_id // .original_commit_id // "") == $sha) and recent(.created_at))
       or convo_by("codeant-ai[bot]")
       or check_by(["CodeAnt", "codeant-ai"])),
  }')
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
gh pr comment "$PR_NUMBER" --body "@cursor review"
```

Cost/rate-limit note: `@codeant-ai review` may consume CodeAnt’s review budget, so skip it when auto-trigger activity is already present on the new SHA. **`@cursor review` is always posted** after a `/fixpr` push (composes with CI and issue #370’s four-reviewer triggers); BugBot is per-seat with no per-call charges — duplicates are acceptable. Greptile is intentionally NOT part of this proactive trigger set; it remains last-resort only per `greptile.md`.

**Composition with issue #362:** `cr-github-review.md` runs `.claude/scripts/maybe-trigger-ai-review.sh` on each poll tick when there is **no** `/fixpr` trigger (no new findings, CI green, not `BEHIND`/`CONFLICTING`). That path fires three single-mention comments — `@codeant-ai review`, `@cursor review`, `@graphite-app re-review` — for **complexity + CR round count**, not because of a push. This differs from Step 3b, which additionally posts `@coderabbitai full review` (subject to the 2/hour cap) when CodeRabbit has not yet auto-triggered on the new SHA. State for the #362 path is tracked in `session-state.json` so it does not batch with Step 3b on the same cause.

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
.claude/scripts/reply-thread.sh "$DBID" --reviewer "$REVIEWER" \
  --body "$REPLY" --pr "$PR_NUMBER"
```

The script strips any `@greptileai` tokens from the body in greptile mode and any `@cursor` tokens in bugbot mode — so even a stray mention in `$REPLY` cannot trigger a paid Greptile re-review ($0.50–$1.00). `@greptileai` is reserved exclusively for intentionally requesting a new review. See `.claude/scripts/reply-thread.sh --help` for the full exit-code contract.

### 4b. Resolve via shared helper

After all replies are posted, resolve and verify exactly the threads `/fixpr` touched. Build the expected-resolved set from the GraphQL thread IDs for every item replied to in 4a (same set you will re-verify in Step 4c after a push):

```bash
TOUCHED_THREADS=$(mktemp -t fixpr-touched-threads.XXXXXX)
# append one GraphQL thread node id per unresolved thread from the Step 0 audit
jq -r '.threads.unresolved[].id' "$AUDIT" > "$TOUCHED_THREADS"

THREAD_RESOLUTION_OUTPUT=$(bash .claude/scripts/resolve-review-threads.sh "$PR_NUMBER" \
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
  POST_PUSH_THREAD_OUTPUT=$(bash .claude/scripts/resolve-review-threads.sh "$PR_NUMBER" \
    --thread-ids-file "$TOUCHED_THREADS" --max-attempts 2 2>&1) || POST_PUSH_RESOLVE_FAILED=1
  echo "$POST_PUSH_THREAD_OUTPUT"
  POST_PUSH_VERIFY_OUTPUT=$(bash .claude/scripts/resolve-review-threads.sh "$PR_NUMBER" \
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
  WAIT_STATE=$(jq -c --arg sha "$WATCH_SHA" '
    . as $root
    | ["coderabbitai[bot]","cursor[bot]","codeant-ai[bot]","greptile-apps[bot]","graphite-app[bot]"] as $botlist
    | {"coderabbitai[bot]":"coderabbit","cursor[bot]":"bugbot","codeant-ai[bot]":"codeant",
       "greptile-apps[bot]":"greptile","graphite-app[bot]":"graphite"} as $needles
    | def is_review_check($n):
        ($n // "" | ascii_downcase) as $name
        | any("coderabbit","graphite","codeant","cursor","bugbot","greptile";
              . as $x | $name | contains($x));
    ([$root.comments.reviews[]?.user.login,
      $root.comments.inline[]?.user.login,
      $root.comments.conversation[]?.user.login]
     | map(select(. as $l | $botlist | index($l) != null)) | unique) as $participants
    | ($root.check_runs.all // []) as $checks
    | ($root.bot_statuses // {}) as $bstat
    | ($participants | map(. as $bot
        | $needles[$bot] as $needle
        | {bot: $bot,
           done: (
             ( $bot != "cursor[bot]"
               and any($root.comments.reviews[]?;
                       .user.login == $bot and (.commit_id // "") == $sha) )
             or any($checks[]?;
                    ((.name // "") | ascii_downcase | contains($needle))
                    and .status == "completed")
             or ( $bot == "coderabbitai[bot]" and (($bstat.CodeRabbit.state // "pending") != "pending") )
             or ( $bot == "greptile-apps[bot]" and (($bstat.Greptile.state // "pending") != "pending") )
           )})) as $bots
    | {head_moved: ($root.pr.head_sha != $sha),
       bots_pending: ($bots | map(select(.done | not) | .bot)),
       ci_pending: [ $checks[] | select((is_review_check(.name) | not) and .status != "completed") | .name ],
       ci_failing: [ $checks[] | select((is_review_check(.name) | not)
                     and (.conclusion == "failure" or .conclusion == "timed_out"
                          or .conclusion == "action_required" or .conclusion == "startup_failure"
                          or .conclusion == "stale")) | .name ],
       new_findings: ($root.new_since_baseline.finding_count // 0)}
  ' "$TICK")
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
  WAIT_STATE=$(jq -c --arg sha "$WATCH_SHA" '
    . as $root
    | ["coderabbitai[bot]","cursor[bot]","codeant-ai[bot]","greptile-apps[bot]","graphite-app[bot]"] as $botlist
    | {"coderabbitai[bot]":"coderabbit","cursor[bot]":"bugbot","codeant-ai[bot]":"codeant",
       "greptile-apps[bot]":"greptile","graphite-app[bot]":"graphite"} as $needles
    | def is_review_check($n):
        ($n // "" | ascii_downcase) as $name
        | any("coderabbit","graphite","codeant","cursor","bugbot","greptile";
              . as $x | $name | contains($x));
    ([$root.comments.reviews[]?.user.login,
      $root.comments.inline[]?.user.login,
      $root.comments.conversation[]?.user.login]
     | map(select(. as $l | $botlist | index($l) != null)) | unique) as $participants
    | ($root.check_runs.all // []) as $checks
    | ($root.bot_statuses // {}) as $bstat
    | ($participants | map(. as $bot
        | $needles[$bot] as $needle
        | {bot: $bot,
           done: (
             # Review object pinned to the watched SHA. EXCLUDED for BugBot:
             # cursor[bot] commit_id is stale/unreliable — gate BugBot by its
             # check-run only (memory feedback_bugbot_commit_id_stale).
             ( $bot != "cursor[bot]"
               and any($root.comments.reviews[]?;
                       .user.login == $bot and (.commit_id // "") == $sha) )
             # Completed check-run on the watched SHA (check_runs are fetched per
             # HEAD SHA, so SHA scoping is implicit). conclusion neutral still
             # counts as complete — BugBot uses neutral for "findings posted".
             or any($checks[]?;
                    ((.name // "") | ascii_downcase | contains($needle))
                    and .status == "completed")
             # CR/Greptile also report via commit statuses on the watched SHA.
             or ( $bot == "coderabbitai[bot]" and (($bstat.CodeRabbit.state // "pending") != "pending") )
             or ( $bot == "greptile-apps[bot]" and (($bstat.Greptile.state // "pending") != "pending") )
           )})) as $bots
    | {head_moved: ($root.pr.head_sha != $sha),
       bots_pending: ($bots | map(select(.done | not) | .bot)),
       ci_pending: [ $checks[] | select((is_review_check(.name) | not) and .status != "completed") | .name ],
       ci_failing: [ $checks[] | select((is_review_check(.name) | not)
                     and (.conclusion == "failure" or .conclusion == "timed_out"
                          or .conclusion == "action_required" or .conclusion == "startup_failure"
                          or .conclusion == "stale")) | .name ],
       new_findings: ($root.new_since_baseline.finding_count // 0)}
  ' "$TICK")

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
- If the resolver's dangling count is `0` but unrelated reviewer threads remain unresolved → run `bash .claude/scripts/resolve-review-threads.sh "$PR_NUMBER"` once to resolve them too. `/fixpr` never leaves reviewer threads open as a paper trail.
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

**Classification rules** (these live in `pr-state.sh`; the list below is the contract — keep the two in sync if either changes). Patterns are checked in this order; first match wins:

1. **Explicit-resolution / clean-pass overrides** (checked first — these signals mean CR or BugBot has issued a clean pass, reported a rate/usage limit instead of reviewing, posted a review-started ack, or emitted a transient error. They win even if the body still contains finding language from a quoted earlier review):
   - HTML marker `<!-- <review_comment_addressed> -->` → `acknowledgment`
   - HTML marker `<!-- <review_comment_withdrawn> -->` → `acknowledgment` (CR retracts its own finding after you push back — "Withdrawing the finding"; observed on PR #601). Marker-only, mirroring the addressed marker, so the prose phrase alone never reclassifies (#557 generic-phrase risk). Safe in tier 1 unlike the walkthrough marker in §4: a withdrawal retracts the single finding in its own thread, so it cannot mask another active finding.
   - `actionable comments posted: 0` → `acknowledgment`. This specific zero-count pattern MUST be checked before the general `actionable comments posted` pattern below — otherwise the general finding pattern would swallow the zero case.
   - `no actionable comments were generated` → `acknowledgment`
   - CR rate-limit notices — `rate limit exceeded`, `rate[- ]limited by coderabbit`, `currently rate limited`, `review limit reached`, or `next review (will be) available in` → `acknowledgment`. CR wraps its Fair-Usage notice in a "Full review **finished**" ack, so the `full review triggered` rule below does not cover it — these phrases must. Every phrase names CR's own notice wording: a bare `fair usage limits policy` was tried and rejected (#557) because a real finding *quoting* the policy would classify as an ack. Each observed CR variant matches ≥2 of these phrases, so no single generic phrase carries it.
   - BugBot usage-limit notices — `couldn't run - usage limit reached` (apostrophe and dash variants tolerated) or `this run hit a usage or spend limit` → `acknowledgment` (BugBot did not review at all, so there is nothing actionable). Both patterns quote BugBot's boilerplate closely on purpose: a looser `hit a usage or spend limit` would swallow a genuine finding *about* rate-limit code, which this repo's PRs frequently touch.
   - `full review triggered` → `acknowledgment`
   - `found no new issues` (case-insensitive) → `acknowledgment` (BugBot clean-pass review body: "✅ Bugbot reviewed your changes and found no new issues!")
   - `<!-- BUGBOT_REVIEW -->` marker present AND body does NOT match `found [1-9][0-9]* potential issue` → `acknowledgment` (BugBot zero-issue summary). This MUST be checked before the generic `issues? found` finding pattern below. Non-zero BugBot summaries ("found 3 potential issues") keep the `<!-- BUGBOT_REVIEW -->` marker but match the non-zero guard and fall through to the finding tier.
   - `Oops, something went wrong` (case-insensitive) → `acknowledgment` (CodeRabbit transient error stub — not an actionable finding)
2. **Finding patterns**:
   - Severity keywords `\b(critical|major|minor|nitpick|p[0-2])\b` or badges `🔴|🟠|🟡`
   - Actionable phrases: `actionable comments posted` (non-zero), `issues? found`, `findings?:`, `potential[_ ]issue`
   - Fix markers: a fenced ```` ```suggestion ```` block, or a `Prompt for AI Agent` heading
3. **Weak-ack fallbacks** (only if no finding matched):
   - LGTM variants: `lgtm`, `looks good`, `approved`, `confirmed`, `resolved`
4. **CR walkthrough/summary override** (the LAST override, checked immediately before the default):
   - Marker `<!-- This is an auto-generated comment: summarize by coderabbit.ai -->` → `acknowledgment` (CR's walkthrough boilerplate, posted on nearly every PR; it matched no rule at all and fell through to `default → finding`, producing phantom findings on PRs where CR posted zero reviews — #575).
   - **Its late position is load-bearing — do not hoist it into the tier-1 override group.** The walkthrough can carry `actionable comments posted: N` (N>0) and severity keywords for the findings it summarizes, so an early override would classify a real-finding summary as an acknowledgment and drop it from `finding_count` — a false clean on the review gate, strictly worse than the phantom-finding noise it fixes. Every finding pattern in tier 2 must be evaluated first and win. Ordering alone supplies that guard, so no AND-not guard (of the `BUGBOT_REVIEW` kind) is needed. Guarded by `Bug6a`/`Bug6b` in `pr-state-classify.test.sh`.
   - Distinct trigger from #557's rate-limit/usage-limit family in tier 1. Note CR edits this comment in place and may merge a rate-limit notice into the same body, in which case the tier-1 rate-limit rule matches it first — both yield `acknowledgment`.
5. **Default** (no pattern matched) → `finding`. The safer default — under-classifying here is the failure mode this whole skill exists to prevent.

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

- `state: success` → review completed on this SHA. Clean-pass signal.
- `state: pending` or check-run `status != "completed"` → bot still running. **Do NOT declare CLEAN.** Emit `REVIEW_PENDING` and stop.
- `state: failure` / `error` with "rate limit" in `description` → CR rate-limited, fall back to Greptile per `cr-github-review.md`.
- No activity from CodeRabbit, Graphite, CodeAnt, or Cursor after a pushed fix commit → the Step 3b trigger check should already have posted the reviewer-specific comment. Emit `REVIEW_PENDING` and re-run `/fixpr` after the reviewer responds.

---

## Step 6: Check merge blockers

```bash
jq -r '.merge_state | "[MERGE] mergeable=\(.mergeable), status=\(.mergeStateStatus), review=\(.reviewDecision)"' "$VERIFY"
```

| Field | Blocking value | Action |
|-------|---------------|--------|
| `mergeable` | `CONFLICTING` | Rebase onto main: `git fetch origin main && git rebase origin/main`. Fix conflicts (optionally run **`/merge-conflict`** — `.claude/skills/merge-conflict/SKILL.md` — to fetch main, auto-resolve *simple* hunks, stage clean files, and list *complex* hunks), continue, force-push. |
| `mergeable` | `UNKNOWN` | GitHub still computing — note and re-run `/fixpr` later. |
| `mergeStateStatus` | `BEHIND` | Rebase onto main: `git fetch origin main && git rebase origin/main`. If conflicts arise mid-rebase (replaying commits individually can conflict even when a three-way merge wouldn't), resolve them the same way as `CONFLICTING` above (including optional **`/merge-conflict`**), then `git rebase --continue`. Force-push. When `FIXPR_WAIT_ITER < FIXPR_MAX_ITERATIONS`, treat the force-push as push-equivalent: set `PUSHED_SHA=$(git rev-parse HEAD)`, `PUSHED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")`, `DID_PUSH=1`, run **Step 3a** (dismiss stale bot reviews), **Step 3b** (reviewer triggers + 120s wait), then **Step 4d** on the new SHA. Do **not** jump straight to Step 4d without 3a/3b — bots are never kicked on the rebased SHA otherwise. |
| `mergeStateStatus` | `BLOCKED` | Required checks/reviews missing — already covered by 5c/5d. If CodeRabbit, Greptile, or CodeAnt is in CODEOWNERS and the last approval is stale/dismissed after a push, recover by triggering that bot (`@coderabbitai full review`, `@greptileai`, or `@codeant-ai review`) instead of escalating to the author. |
| `mergeStateStatus` | `UNSTABLE` | A non-required check pending/failing — typically CR/Greptile on the new SHA. If 5d emitted `REVIEW_PENDING`, stop with that status. |
| `reviewDecision` | `CHANGES_REQUESTED` | Changes were requested. **Stale** bot `CHANGES_REQUESTED` (wrong `commit_id` vs HEAD) are cleared by Step 3a after each push — not escalation. If a **human** left `CHANGES_REQUESTED` on the current HEAD, report as non-automatable. |

When residual branch protection says review is missing or `reviewDecision != "APPROVED"`, run `.claude/scripts/merge-gate.sh "$PR_NUMBER"` and read `.code_owner_bots`. If it lists `coderabbitai[bot]`, `greptile-apps[bot]`, or `codeant-ai[bot]`, a current-HEAD **`APPROVED`** review from that bot satisfies GitHub's code-owner requirement. CodeAnt **check-run success** only covers the supplemental CR-path cleanliness rule in `cr-merge-gate.md`; it does **not** replace an `APPROVED` when CodeAnt is a code owner. A stale/dismissed bot approval is recoverable review debt: trigger the matching bot and re-run the gate after it responds. Do not ask the PR author for an approval GitHub will not accept.

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
- `CONFLICTS` — merge conflicts could not be auto-resolved (needs manual intervention).
- `BEHIND` — branch behind base, auto-rebased and force-pushed, and the wait budget was already exhausted (Step 6 enters the Step 4d wait on the new SHA when iterations remain). Re-run `/fixpr` after CI completes.
- `NEEDS_HUMAN_REVIEW` — a human reviewer requested changes, or no configured code-owner bot can satisfy the missing required approval. If CR/Greptile is in CODEOWNERS and only its approval is stale/dismissed, downgrade to `REVIEW_PENDING` after triggering the bot re-review.
