---
name: status
description: Show a dashboard of all open PRs with review state, unresolved findings, and blockers.
triggers:
  - show PRs
  - PR dashboard
  - what's open
  - review status
model: sonnet
allowed-tools:
  - Read
  - Glob
  - Grep
  - Bash
  - WebFetch
  - WebSearch
---

Build a status dashboard of all open PRs in this repo.

Resolve dashboard helpers before listing PRs:

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
PR_STATE_SH=$(resolve_script pr-state.sh || true)
MERGE_GATE_SH=$(resolve_script merge-gate.sh || true)
CR_HOURLY_SH=$(resolve_script cr-review-hourly.sh || true)
[[ -n "$PR_STATE_SH" ]] || { echo "ERROR: pr-state.sh not found (checked all three paths) — PR dashboard unavailable" >&2; exit 1; }
[[ -n "$MERGE_GATE_SH" ]] || { echo "ERROR: merge-gate.sh not found (checked all three paths) — merge status unavailable" >&2; exit 1; }
[[ -n "$CR_HOURLY_SH" ]] || { echo "ERROR: cr-review-hourly.sh not found (checked all three paths) — review quota status unavailable" >&2; exit 1; }
```

> **Invoking-repo scope (issue #687).** "in this repo" is load-bearing: the `gh pr list`
> below is cwd-repo-scoped by `gh`, and `pr-state.sh --pr N` resolves the repo via
> `gh repo view` — so the dashboard never surfaces another repo's PRs. `/status`
> reads no cross-repo session-state aggregate; if that ever changes, use
> `session-state.sh --session-view` (repo-scoped), never `--get .`.

## Steps

### Step 1: List open PRs

```bash
gh pr list --state open --json number,title,headRefName,updatedAt,author,additions,deletions --limit 50
```

If no open PRs, say "No open PRs." and stop.

### Step 2: For each PR, gather review state

> **pr-state.sh first (NON-NEGOTIABLE):** Before calling `gh api .../pulls/{N}/reviews`, `pulls/{N}/comments`, or `issues/{N}/comments` directly, call `pr-state.sh --pr N` first and read the cached JSON bundle. All review-state queries in this skill read from the `$STATE` bundle — do not add inline `gh api` calls to these three endpoints.

For each open PR, run the shared PR-state helper once per PR. One invocation returns reviews, inline comments, issue comments, unresolved threads, check-runs, and bot status rollups — all derived from the same HEAD SHA:

```bash
STATE=$("$PR_STATE_SH" --pr "$N")
```

All subsequent queries read from `$STATE`:

```bash
# Last review from CR, BugBot, or Greptile (state: APPROVED / COMMENTED / CHANGES_REQUESTED)
jq '[.comments.reviews[]
     | select(.user.login == "coderabbitai[bot]" or .user.login == "cursor[bot]" or .user.login == "greptile-apps[bot]")
     | {user: .user.login, state, submitted: .submitted_at}]
     | sort_by(.submitted) | if length == 0 then {} else last end' "$STATE"

# Unresolved thread count
jq '.threads.unresolved_count' "$STATE"

# CR/BugBot/Greptile issue-comment count (summaries, acks, PR-level findings)
jq '[.comments.conversation[]
     | select(.user.login == "coderabbitai[bot]" or .user.login == "cursor[bot]" or .user.login == "greptile-apps[bot]")]
     | length' "$STATE"

# CodeRabbit check-run status (also serves as rate-limit signal via title).
# Falls back to the commit-status rollup for repos that report CR via the legacy statuses API.
CR_CHECK=$(jq '.check_runs.all[] | select(.name == "CodeRabbit") | {status, conclusion, title}' "$STATE")
if [ -z "$CR_CHECK" ] || [ "$CR_CHECK" = "null" ]; then
  jq '.bot_statuses.CodeRabbit' "$STATE"    # legacy commit-status path
else
  echo "$CR_CHECK"
fi

# BugBot (Cursor) check-run — included so PRs on the BugBot path show review status
jq '.check_runs.all[] | select(.name == "Cursor Bugbot") | {name, status, conclusion}' "$STATE"
```

### Step 3: Determine status for each PR

For a structured merge-readiness call per PR, run the shared merge-gate verifier:

```bash
"$MERGE_GATE_SH" "$PR_NUM"
```

Exit `0` → Clean (merge-ready). Exit `1` → parse `.missing[]` to classify: entries about findings/threads = **Has findings**, entries about CI incomplete or review not yet posted = **Review pending**, entries about rate limits = **Rate-limited**. Exit `3` → PR not found. Exit `2`/`4` → script/gh error.

The JSON also surfaces `.reviewer`, `.head_sha`, `.ci_status`, `.merge_state`, and `.mergeable` — use these to populate the dashboard columns without re-querying.

Classifications to present in the table:
- **Clean (merge-ready)** — script exit `0`.
- **Has findings** — gate not met because of unresolved threads, CR check-run red, or findings on HEAD.
- **Review pending** — gate not met because no review yet / CI still running / `mergeStateStatus` is `UNKNOWN` (GitHub still computing mergeability).
- **Behind base** — gate not met with `merge_state == "BEHIND"` or `missing` mentions BEHIND — show **Rebase** (invoke `/fixpr`); do not conflate with generic `BLOCKED`.
- **Rate-limited** — gate not met with a CR rate-limit signal in `missing`.

### Step 4: Session-state + CR hourly quota

Always run `"$CR_HOURLY_SH" --check` from the repo root (same `HOME` as the agent). Parse JSON on stdout and put **`CR quota: <reviews_used>/<budget>`** (or **`CR quota: exhausted`**) in the footer **every time**, even when `~/.claude/session-state.json` does not exist yet (`--check` then reports 0 used).

If `session-state.json` exists, also cross-reference:

- Active agents and tasks
- Phase assignments (A/B/C)

### Step 5: Format the dashboard

Output a table like:

```
PR    | Title                          | Reviewer | State          | Findings | HEAD SHA | Updated
------|--------------------------------|----------|----------------|----------|----------|--------
#40   | Add slash commands             | CR       | Review pending | 0        | 517690c  | 2 min ago
#38   | Fix auth middleware            | Greptile | Has findings   | 3        | d0e4fef  | 15 min ago
#35   | Add post-merge hook            | CR       | Clean          | 0        | 7b2cfbf  | 1 hr ago
```

Below the table, add:
- **Blocked:** List any PRs that are blocked and why
- **CR quota:** From `cr-review-hourly.sh --check` — **CR quota: N/M** or **exhausted** (deterministic; do not gate on session-state.json existing)
- **Active agents:** List any running agents and their tasks (only when present in session-state)
