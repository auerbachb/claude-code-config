---
name: monitor
description: Audit every open PR for engagement from all four AI reviewers (CodeRabbit, CodeAnt, BugBot, Graphite). Builds a ✅/❌ gap matrix from pr-state.sh (reviews + comments + check-runs on HEAD), detects blockers (draft PRs, CR rate-limit), and posts the missing trigger comments after confirmation. Read-only audit by default; never auto-flips drafts or auto-merges. Triggers on "/monitor", "check all PRs for reviewer engagement", "make sure all 4 reviewers ran", "did codeant/cursor/graphite review #N".
triggers:
  - monitor
  - check all PRs for reviewer engagement
  - make sure all 4 reviewers ran
  - did codeant review
  - did cursor review
  - did graphite review
  - reviewer engagement matrix
model: sonnet
argument-hint: "[<PR>] [--apply] [--repo <owner/repo>] (default: audit all open PRs, confirm before posting)"
allowed-tools:
  - Read
  - Glob
  - Grep
  - Bash
---

Audit the open PR backlog and confirm that **all four AI code reviewers** have actually engaged on each PR, then post the missing trigger comments. The four reviewers and their exact bot logins / trigger strings are:

| Reviewer | Bot login | Trigger string |
|----------|-----------|----------------|
| CodeRabbit | `coderabbitai[bot]` | `@coderabbitai full review` |
| CodeAnt | `codeant-ai[bot]` | `@codeant-ai review` |
| BugBot (Cursor) | `cursor[bot]` | `@cursor review` |
| Graphite | `graphite-app[bot]` | `@graphite-app re-review` |

> **Graphite known outage (issue #610):** Graphite has shown zero engagement — no comments, no check-runs — on every PR since 2026-05-08 (confirmed repo-wide, not per-PR or docs-only). A ❌ in the Graphite column most likely reflects this ongoing outage, not a fresh gap; see `.claude/reference/codeant-graphite-supplemental.md` for evidence and the re-enablement path. Still triggered per Step 5 — the outage is a user-side fix (GitHub App reinstall/billing), not a reason to stop auditing.

`/monitor` is **audit-and-trigger only**. It is the action-oriented sibling of read-only `/status`: where `/status` reports merge-readiness, `/monitor` reports *reviewer coverage* and closes gaps. It does **not** drive the fix/resolve loop (that stays with `/fixpr` and the per-PR coding threads) and it never auto-flips drafts, auto-merges, or modifies review-bot config.

## Scope boundaries (HARD STOPS)

- **Never auto-flip a draft to ready-for-review.** Surface it and ask; only the user runs `gh pr ready <N>`.
- **Never post `@coderabbitai full review` when CodeRabbit is rate-limited**, or when the per-PR 2-explicit-triggers/hour cap is reached, or when the account hourly budget is exhausted (`cr-review-hourly.sh`).
- **Never auto-merge, dismiss reviews, or resolve threads** — that is `/fixpr` / `/wrap` territory.
- The other three triggers (`@codeant-ai review`, `@cursor review`, `@graphite-app re-review`) are not hourly-capped, but none is free of consequence — BugBot is per-seat **and spend-metered** (#1199) — so only post for a *missing* reviewer, and never re-nudge a BugBot that already refused this HEAD.

## Arguments

Parse from `$ARGUMENTS`:

| Argument | Default | Meaning |
|----------|---------|---------|
| `<PR>` (bare integer) | — | Audit only this PR instead of the whole backlog. |
| `--apply` | off | Skip the confirmation prompt and post missing triggers immediately. Blockers (draft, CR rate-limit/cap) are still honored — `--apply` never overrides a HARD STOP. |
| `--repo <owner/repo>` | current repo | Target a different repo. Implemented by `export GH_REPO=<owner/repo>` so both `gh` and `pr-state.sh` resolve the same repo. |

## Resolve the shared scripts (once)

Use the standard three-candidate lookup (same pattern as `fixpr`/`babysit-pr`). Prefer the global install; fall back to the in-repo copy when developing the skill itself.

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

PR_STATE_SH=$(resolve_script pr-state.sh)        || { echo "ERROR: pr-state.sh not found" >&2; exit 1; }
CR_HOURLY_SH=$(resolve_script cr-review-hourly.sh) || true   # optional; degrade gracefully if absent

# --repo: point every gh / pr-state.sh call at the target repo.
[[ -n "$REPO_ARG" ]] && export GH_REPO="$REPO_ARG"
```

> **Invoking-repo scope (issue #687).** With no `--repo`, every `gh pr list` /
> `pr-state.sh` call is cwd-repo-scoped by `gh`, so `/monitor` audits only the
> invoking repo. `--repo` is the explicit, user-initiated opt-in to a *different*
> single repo — it never fans out across repos. `/monitor` reads no cross-repo
> session-state aggregate.

---

## Step 1 — Inventory open PRs

```bash
# Cover the WHOLE open backlog, not just the first page. gh pr list paginates
# internally up to --limit, so set it well above any realistic backlog (raise it
# further if a repo can exceed this). A low cap would silently skip later PRs.
# Authorship guard (issue #733): resolve the authenticated user so Step 4 can
# block trigger posts (a WRITE) on PRs you did not author. Fetch `author` so each
# row carries it. Fail-closed: an empty GH_USER treats every PR as not-yours.
GH_USER=$(gh api user --jq .login 2>/dev/null || echo "")
PRS=$(gh pr list --state open --limit 1000 --json number,title,isDraft,headRefOid,url,author)

# Narrow to a single PR BEFORE counting, so a targeted audit of a closed/missing
# PR yields COUNT == 0 (an open-list count would mask the empty result).
if [[ -n "$PR_ARG" ]]; then
  PRS=$(jq --argjson n "$PR_ARG" 'map(select(.number == $n))' <<<"$PRS")
fi
COUNT=$(jq 'length' <<<"$PRS")
```

If `COUNT == 0`, say **"No open PRs to audit."** and stop. (A bare `<PR>` that is closed or not found leaves `PRS` empty, so this also covers "the requested PR is not open.")

---

## Step 2 — Per-PR engagement scan (reuse `pr-state.sh`)

For each PR, run the shared state helper **once** — it aggregates the 3 comment endpoints (`pulls/{N}/reviews`, `pulls/{N}/comments`, `issues/{N}/comments`, `per_page=100`) plus check-runs and commit statuses from a single HEAD-SHA pull. **Do not re-issue per-PR REST loops in this skill** — read everything from the bundle via `jq`.

```bash
BUNDLE=$("$PR_STATE_SH" --pr "$N") || { echo "skip #$N: pr-state.sh failed"; continue; }
```

Build the 4-reviewer matrix from the bundle. A reviewer is **engaged** when it produced, **on the current HEAD SHA**, any of: a **review object**, a **check-run** whose name matches the reviewer, OR a **finding-bearing comment**. Pure ack comments (e.g. CR's "Actions performed — Full review triggered", "actionable comments posted: 0", rate-limit notices) do **not** count.

The HEAD scoping matters: a reviewer that only ran on an older commit must show ❌ so its trigger is re-posted after a push. Check-runs and commit statuses in the bundle are already pulled from the HEAD SHA, so they are inherently current; reviews and inline comments are filtered by `commit_id == head_sha` (`.pr.head_sha` from the bundle), and conversation comments (which carry no `commit_id`) only count when their body references the HEAD SHA (full or short) — the same SHA-scoping `fixpr` uses in its "detect reviewer activity on the pushed SHA" step.

```bash
MATRIX=$(jq -c '
  def reviewers: [
    {key:"coderabbit", login:"coderabbitai[bot]", needles:["coderabbit"]},
    {key:"codeant",    login:"codeant-ai[bot]",   needles:["codeant"]},
    {key:"bugbot",     login:"cursor[bot]",        needles:["cursor","bugbot"]},
    {key:"graphite",   login:"graphite-app[bot]",  needles:["graphite"]}
  ];
  # Pure-acknowledgment comments that must NOT count as engagement.
  def is_ack($body):
    ($body // "") as $b
    | ($b == "")
      or ($b | test("actions performed"; "i"))
      or ($b | test("full review triggered"; "i"))
      or ($b | test("actionable comments posted:\\s*0\\b"; "i"))
      or ($b | test("no actionable comments were generated"; "i"))
      or ($b | test("rate limit"; "i"));
  . as $b
  | (.pr.head_sha // "") as $head
  | ($head[0:7]) as $short
  | reviewers
  | map(. as $r
      | {
          # Review object on the current HEAD SHA.
          has_review:
            ([$b.comments.reviews[]?
               | select(.user.login == $r.login and (.commit_id == $head))] | length > 0),
          # Check-run (or CR legacy commit-status) — both already HEAD-scoped by pr-state.sh.
          has_check:
            (([$b.check_runs.all[]?
               | (.name // "" | ascii_downcase) as $n
               | select(any($r.needles[]; . as $needle | $n | contains($needle)))] | length > 0)
             or ($r.key == "coderabbit" and ($b.bot_statuses.CodeRabbit != null))),
          # Finding-bearing comment on HEAD: inline scoped by commit_id; conversation by SHA mention.
          has_finding_comment:
            (([$b.comments.inline[]?
               | select(.user.login == $r.login
                        and ((.commit_id // .original_commit_id // "") == $head)
                        and (is_ack(.body) | not))] | length > 0)
             or ($head != "" and ([$b.comments.conversation[]?
               | select(.user.login == $r.login
                        and (is_ack(.body) | not)
                        and (((.body // "") | contains($head)) or ((.body // "") | contains($short))))] | length > 0)))
        }
      | . + {key: $r.key, engaged: (.has_review or .has_check or .has_finding_comment)}
    )
  | { coderabbit: (map(select(.key=="coderabbit"))[0].engaged),
      codeant:    (map(select(.key=="codeant"))[0].engaged),
      bugbot:     (map(select(.key=="bugbot"))[0].engaged),
      graphite:   (map(select(.key=="graphite"))[0].engaged) }
' "$BUNDLE")
```

`$MATRIX` is `{coderabbit, codeant, bugbot, graphite}` booleans for PR `$N`. Collect one per PR alongside `number`, `title`, `isDraft`, and a short HEAD SHA.

Also capture the CR check-run health for Step 4:

```bash
CR_HEALTH=$(jq -c '
  ([.check_runs.all[]? | (.name // "" | ascii_downcase) as $n | select($n | contains("coderabbit"))] | last) as $cr
  | { status: ($cr.status // null),
      conclusion: ($cr.conclusion // null),
      title: ($cr.title // null),
      legacy: (.bot_statuses.CodeRabbit.description // null) }
' "$BUNDLE")
```

---

## Step 3 — Render the gap matrix

Print a markdown table; ✅ = engaged on HEAD, ❌ = missing. Include the draft flag.

```
PR    | Draft | Title                          | CodeRabbit | CodeAnt | BugBot | Graphite
------|-------|--------------------------------|------------|---------|--------|---------
#481  |       | Add /monitor skill             | ✅          | ✅       | ✅      | ✅
#479  | draft | Refactor pr-state bundle       | ❌          | ❌       | ✅      | ❌
#476  |       | Fix merge-gate exit codes      | ✅          | ❌       | ✅      | ❌
```

Below the table, summarize:
- **Fully covered:** PRs with all four ✅.
- **Gaps:** one line per PR listing the missing reviewers, e.g. `PR #476 — missing: CodeAnt, Graphite`.
- If every PR is fully covered, say so and skip Steps 4–5.

---

## Step 4 — Detect blockers before triggering

Run these checks per PR with gaps; they gate (or annotate) the triggers proposed in Step 5.

### Step 4.0 — Authorship guard (issue #733, `safety.md`) — HARD STOP for triggers

Posting a reviewer trigger (`@coderabbitai` / `@codeant-ai` / `@cursor` / `@graphite-app`) is a **write** — it spends the PR author's reviewer budgets and notifies people. So triggers are proposed/posted **only for PRs you authored**:

```bash
# Per PR row: mine iff GH_USER is known AND the row's author == GH_USER (fail-closed).
IS_MINE=$(jq -r --arg me "$GH_USER" '($me != "" and .author.login == $me)' <<<"$PR_ROW")
```

If `IS_MINE == false`, **do not propose or post any trigger** for that PR. It still appears in the Step 3 gap matrix as **read-only context**, clearly separated from your actionable rows (AC6) — annotate its row `read-only (not yours)`. Override only if the user named that specific PR in chat this session (per-PR override; say you are operating under it). This is a hard stop even under `--apply`.

### 4a. Draft state

If a PR `isDraft == true` and any reviewer is missing, surface it: drafts cause reviewers (especially CodeRabbit) to skip silently. **Do not auto-flip.** Recommend the user run `gh pr ready <N>` and re-run `/monitor`. Still list the proposed triggers, but flag that CR will not act while the PR is a draft.

### 4b. CodeRabbit rate-limit / cooldown

Using `$CR_HEALTH` from Step 2: if the CR check-run is `completed` **and** a rate-limit signal appears in its `title` or `legacy` description (matches `rate limit`, case-insensitive), do **not** propose `@coderabbitai full review`. Surface the cooldown and recommend escalation to BugBot/Greptile per `cr-github-review.md` ("Reviewer escalation gate"). The other three triggers are unaffected.

### 4c. CR explicit-trigger budget (2/hour per PR + account hourly cap)

Before proposing `@coderabbitai full review` for any PR, check the account hourly budget once. Map the script's exit code explicitly — `cr-review-hourly.sh --check` exits `0` (budget available), `1` (account budget exhausted), or another code (`2` usage, `5` write failure). Treat **only exit `1`** as exhausted; a missing script or any other nonzero is a helper problem, not an exhausted budget, so surface it and keep CR proposable rather than silently dropping it:

```bash
CR_BUDGET_OK=1            # 1 = propose CR; 0 = budget exhausted, drop CR
if [[ -n "$CR_HOURLY_SH" ]]; then
  "$CR_HOURLY_SH" --check >/dev/null 2>&1; RC=$?
  case "$RC" in
    0) ;;                                  # budget available
    1) CR_BUDGET_OK=0 ;;                    # account budget exhausted — drop CR
    *) echo "warn: cr-review-hourly.sh --check failed (exit $RC) — not assuming exhausted; CR stays proposable" >&2 ;;
  esac
fi
```

`CR_BUDGET_OK=0` ⇒ account budget exhausted — drop CR from the proposed triggers this run and say so. A missing `cr-review-hourly.sh` (or any non-`1` failure) leaves `CR_BUDGET_OK=1` (degrade gracefully — surface the error, don't silently suppress CR). The per-PR **2 explicit `@coderabbitai full review`/hour** cap is enforced atomically at post time by `cr-review-hourly.sh --record-explicit <N>` (Step 5), which uses the same exit-code contract (exit `1` = cooldown/cap reached; other nonzero = helper error).

---

## Step 5 — Post the missing triggers (confirmation by default)

Build, per PR, the list of trigger comments for each missing reviewer (skipping any CR trigger blocked by Step 4):

| Missing reviewer | Comment to post |
|------------------|-----------------|
| CodeRabbit | `@coderabbitai full review` |
| CodeAnt | `@codeant-ai review` |
| BugBot | `@cursor review` |
| Graphite | `@graphite-app re-review` |

**Default (no `--apply`):** print the full proposed plan (PR → comments) and **ask the user to confirm** before posting anything. Do not post on a bare `/monitor` run without confirmation.

**`--apply`:** skip the prompt and post immediately — but Step 4 HARD STOPs still apply (no CR trigger on a rate-limited/cap-hit/budget-exhausted PR; drafts are reported, not flipped).

On confirmation, post each comment. For a CodeRabbit trigger, record it against the cap **before/at** posting and honor the result:

```bash
post_trigger() {  # $1=PR  $2=comment  $3=reviewer-key
  if [[ "$3" == "coderabbit" && -n "$CR_HOURLY_SH" ]]; then
    OUT=$("$CR_HOURLY_SH" --record-explicit "$1"); RC=$?
    case "$RC" in
      0) ;;                                  # recorded — clear to post
      1) echo "skip CR on #$1: cooldown/cap or account budget reached — not posting"; return 0 ;;
      *) echo "skip CR on #$1: cr-review-hourly.sh --record-explicit failed (exit $RC) — surfacing, not posting" >&2; return 0 ;;
    esac
  fi
  gh pr comment "$1" --body "$2" && echo "posted on #$1: $2"
}
```

Post the four reviewers as separate comments (never batch mentions — combined-mention comments do not trigger reliably). After posting, report what landed where, then suggest re-running `/monitor` after a short delay to confirm the bots picked up.

---

## Step 6 — Optional: emit a "fix all findings" prompt for coding threads

When a PR already has bot findings (unresolved review threads: `jq '.threads.unresolved_count' "$BUNDLE"` > 0) and the user is about to hand it to its coding session, output a copy-pasteable prompt block. This encodes the same anti-loop discipline as `cr-github-review.md` ("Processing CR Feedback"):

```
Fix every bot finding on PR #<N>:
1. Verify each finding against the actual code (CR labels duplicates — a "duplicate" is NOT resolved).
2. Fix all valid findings in ONE commit; push once (batch — don't push per finding; every push spends CodeRabbit's included-review allowance, `.claude/reference/cr-rate-limits.md`).
3. Reply to every thread with what changed ("Fixed in <sha>: …"). Plain text — do NOT include @cursor in replies.
4. Resolve each thread via GraphQL (resolveReviewThread); replies alone don't resolve.
5. Manually mark Resolved any thread GitHub didn't auto-resolve when the line changed.
6. Do NOT request a new review until every touched thread shows isResolved: true.
```

Keep this wording in the SKILL so it can be iterated without touching other files.

---

## Notes

- **Reuse, don't reimplement:** Step 2 must go through `pr-state.sh`; the matrix is pure `jq` over the bundle. No ad-hoc `gh api pulls/.../comments` loops in this skill.
- **Relationship to `/status`:** `/status` is the read-only merge-readiness dashboard; `/monitor` audits *reviewer coverage* and posts the missing triggers. Use `/fixpr` to actually process findings.
- **Post-merge install:** after this skill lands on `main`, symlink it globally via the skills worktree per `skill-symlinks.md`:

  ```bash
  git -C "$HOME/.claude/skills-worktree" fetch origin main --quiet
  git -C "$HOME/.claude/skills-worktree" reset --hard origin/main --quiet
  ln -s "$HOME/.claude/skills-worktree/.claude/skills/monitor" "$HOME/.claude/skills/monitor"
  ```

  No script changes are needed — `session-start-sync.sh` syncs the worktree to `origin/main` on session start, so the symlink target resolves automatically after merge.
