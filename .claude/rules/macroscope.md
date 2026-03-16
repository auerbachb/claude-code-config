# Macroscope Fallback (CodeRabbit Rate Limit Recovery)

> **Always:** Trigger Macroscope after 8 min with no CR review OR on fast-path rate limit detection. Poll all 3 endpoints. Reply to every thread.
> **Ask first:** Never — fix findings autonomously.
> **Never:** Run Macroscope and CR simultaneously on the same push. Manually re-trigger `@coderabbitai full review` on the same SHA within 15 min of a rate limit. (Fresh SHA from a new push = poll immediately, no wait.)

When CodeRabbit is rate-limited on GitHub, fall back to Macroscope for code review. Macroscope is **disabled by default** on all repos — it only runs when explicitly triggered via PR comment.

## When to trigger Macroscope

Trigger Macroscope when **any** of these are true — check ALL of them every polling cycle:
- **FAST PATH (check every cycle):** The commit's check-runs or statuses API shows CodeRabbit rate limiting (see "Fast-path rate limit detection" in GitHub review rules). This catches rate limits within ~60-120 seconds — **trigger Macroscope immediately, do not wait 8 minutes.**
- **SLOW PATH (8-minute timeout):** 8 minutes have passed since pushing or triggering `@coderabbitai full review` and no review content has appeared. This fires regardless of whether you see an explicit rate-limit signal.
- CR's review comment explicitly mentions rate limiting or throttling
- CR's issue comment (on `issues/{N}/comments`) contains the text "Rate limit exceeded"
- CR posts a "Actions performed" ack but **no actual review body or inline comments appear within 8 minutes** — the ack alone is NOT a review

> **THE #1 SUBAGENT FAILURE MODE:** Agents see the "Actions performed" ack and interpret it as "CR is reviewing, keep waiting." But when CR is rate-limited, it posts the ack and then **never delivers the actual review**. The result: the agent polls forever, waiting for a review that will never come. **If 8 minutes pass after the ack with no review content, CR is rate-limited — trigger Macroscope immediately.**

## Triggering Macroscope review

When a CodeRabbit rate limit is detected:

1. **Post a review request on the PR:**
   ```bash
   gh pr comment <PR_NUMBER> --body "@macroscope-app review"
   ```

2. **Poll for Macroscope's response** using the same polling pattern as CodeRabbit:
   - Poll every 60 seconds via `gh api` for new review comments from `macroscope-app[bot]`
   - Check all three endpoints:
     - `repos/{owner}/{repo}/pulls/{N}/reviews?per_page=100`
     - `repos/{owner}/{repo}/pulls/{N}/comments?per_page=100`
     - `repos/{owner}/{repo}/issues/{N}/comments?per_page=100`
   - Timeout after **10 minutes** — if no response, fall back to **self-review** and inform the user that both CR and Macroscope are unavailable

3. **Process Macroscope findings** the same way as CR findings:
   - Fix all valid findings in a single commit
   - **Reply to every Macroscope comment thread** confirming the fix or explaining why it was declined. Use the same `gh api` reply pattern as CR:
     - For inline review comments: `gh api repos/{owner}/{repo}/pulls/comments/{id}/replies -f body="Fixed in \`abc1234\`: <what changed>"`
     - For issue-level comments: `gh api repos/{owner}/{repo}/issues/{N}/comments -f body="@macroscope-app Fixed: <summary of all fixes>"`
   - Pushing a code fix does NOT resolve a comment thread — you must post an explicit reply. Unreplied threads show as unresolved in the PR.
   - Push once (single commit for all fixes)

4. **Use reactions** on Macroscope comments to provide feedback (same as CR workflow)

## Detecting a Clean Macroscope Pass

A Macroscope review is **complete** when EITHER of these is true:
1. **Check-run signal:** `Macroscope - Correctness Check` shows `status: "completed"` with `conclusion: "success"` on the PR's HEAD commit. Check via:
   ```bash
   gh api "repos/{owner}/{repo}/commits/{SHA}/check-runs" \
     --jq '.check_runs[] | select(.app.slug == "macroscopeapp") | {name, status, conclusion}'
   ```
2. **Review comment signal:** `macroscope-app[bot]` posts a review or issue comment on the PR.

A Macroscope review is **clean** (no findings) when:
- The check-run shows completed/success AND
- No new review objects or inline comments from `macroscope-app[bot]` appeared since the trigger

**Important:** Macroscope may complete its review via check-runs WITHOUT posting any review comments. `conclusion: "success"` with no comments = clean pass. This is different from CodeRabbit, which always posts a review object.

A clean Macroscope pass counts as 1 of the 2 required reviews for merge readiness (but at least 1 must come from CodeRabbit).

## Important constraints

- **Never run both reviewers simultaneously on the same push.** Trigger Macroscope only after CR fails to deliver a review within 8 minutes.
- **Macroscope has no CLI.** It only operates via GitHub PR comments — there is no local pre-push review fallback from Macroscope.
- **Macroscope counts as 1 of the 2 required clean reviews**, but at least 1 must come from CodeRabbit (see Completion criteria in GitHub review rules).

## After Macroscope: Always Try CR Next

After fixing Macroscope findings and pushing a new commit:
1. **Do NOT wait 15 minutes.** The push creates a new commit with fresh check-runs — the old "Review rate limit exceeded" was on the previous SHA and is irrelevant. CR auto-triggers on every push, so the new commit gets a fresh CR review attempt.
2. Enter the normal polling loop on the **new** commit's SHA (fast-path + 8-minute slow-path).
3. On each poll cycle, check the **new** commit's check-runs for rate limit (fast path). The new commit won't have a stale rate-limit message — it's a clean slate.
4. If CR reviews successfully -> process findings normally. This counts toward the required "at least 1 CR review."
5. If CR rate-limits again on the new commit (fast-path detects within ~2 min) -> trigger Macroscope again.
6. **The alternation is automatic:** push -> try CR (fresh SHA) -> rate-limited? -> Macroscope -> fix + push (new SHA) -> try CR -> etc. Each push gives CR a fresh chance.

> **The 15-minute wait only applies when requesting a re-review of the SAME SHA** (e.g., `@coderabbitai full review` without pushing new code). If you pushed new code, skip the wait — the push is the trigger.

---

## Self-Review Fallback

When CodeRabbit is unavailable and Macroscope cannot help (non-rate-limit timeout, CLI failure, neither tool configured), Claude performs its own review as a last-resort fallback. This is not a replacement for CR or Macroscope — it's a safety net so the flow doesn't break.

### When to trigger

- CR CLI hangs or errors out twice during the local review loop
- Both CR and Macroscope are unavailable on GitHub (CR didn't deliver within 8 min + Macroscope timed out after 10 min)
- Neither CR nor Macroscope is configured for the repo

### How to self-review

Review the full diff (`git diff main...HEAD`) and check for:
1. **Bugs** — logic errors, off-by-one, null/undefined access, race conditions
2. **Security** — SQL injection, XSS, secrets in code, unsafe input handling
3. **Error handling** — missing try/catch, unhandled promise rejections, silent failures
4. **Types** — wrong types, missing null checks, implicit any
5. **Naming & clarity** — misleading names, dead code, confusing control flow
6. **Edge cases** — empty arrays, zero values, missing fields, boundary conditions

### Output format

List findings the same way you would process CR findings: verify each against the code, fix valid issues, and note what you checked. If no issues found, that counts as a clean pass for the exit criteria.

### Important

- Self-review is a **fallback**, not a substitute. When CR is available, always prefer it.
- Self-review counts toward the "two consecutive clean reviews" exit criteria only when CR is genuinely unavailable.
- If CR comes back online mid-flow (e.g., it comments on the PR after you've moved on), process those findings in the next round.
