# CR Polling & CI Verification Commands

Full multi-line `gh api` commands referenced from `.claude/rules/cr-github-review.md`. Rule file keeps short one-liner examples inline; this file has the exact expressions.

## Poll commit check-runs for CodeRabbit status

```bash
gh api "repos/{owner}/{repo}/commits/{SHA}/check-runs?per_page=100" \
  --jq '.check_runs[] | select(.name == "CodeRabbit") | {name, status, conclusion, title: .output.title}'
```

**Fallback** — if `check-runs` returns empty for CodeRabbit, use the commit statuses endpoint:

```bash
gh api "repos/{owner}/{repo}/commits/{SHA}/statuses" \
  --jq '.[] | select(.context | test("CodeRabbit"; "i")) | {context, state, description}'
```

**Completion signal:** `status: "completed"` + `conclusion: "success"` = review done.

**Fast-path rate-limit signal:** check-run with `conclusion: "failure"` and `output.title` containing "rate limit" (case-insensitive), OR status `state: "failure"`/`"error"` with `description` containing "rate limit" → check BugBot (`cursor[bot]`) first. If BugBot already posted a review, use it. If not, wait up to 5 min for BugBot. If BugBot also times out, trigger Greptile (see `bugbot.md`).

## CI Health Check — every poll cycle

```bash
gh api "repos/{owner}/{repo}/commits/{SHA}/check-runs?per_page=100" \
  --jq '.check_runs[] | {id, name, status, conclusion, title: .output.title}'
```

Read a specific check-run's output summary:

```bash
gh api "repos/{owner}/{repo}/check-runs/{CHECK_RUN_ID}" --jq '.output.summary'
```

## Pre-Merge CI Verification (NON-NEGOTIABLE)

```bash
SHA=$(gh pr view <PR_NUMBER> --json commits --jq '.commits[-1].oid')

# 1. Incomplete runs (queued or in_progress) — DO NOT merge while any exist
gh api "repos/{owner}/{repo}/commits/$SHA/check-runs?per_page=100" \
  --jq '.check_runs[] | select(.status != "completed") | {name, status}'

# 2. Blocking conclusions among completed runs
gh api "repos/{owner}/{repo}/commits/$SHA/check-runs?per_page=100" \
  --jq '.check_runs[] | select(.conclusion == "failure" or .conclusion == "timed_out" or .conclusion == "action_required" or .conclusion == "startup_failure" or .conclusion == "stale") | {name, conclusion}'
```

If step 1 returns any rows → wait (a null conclusion means "not reported yet", not "passed"). If step 2 returns any rows → fix, commit, push, re-run before merging.
