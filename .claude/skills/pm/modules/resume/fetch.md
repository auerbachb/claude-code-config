<!-- pm-routing:begin -->
Route `resume:fetch`. Verify the recovered work against live GitHub. Reconcile a merged delivery before ranking or relaunching. Continue to resume:present.
<!-- pm-routing:end -->
### 1A.3: Verify against live GitHub

For tracked merged PRs, run [completion reconciliation](../../../../reference/issue-completion.md) before re-ranking or relaunching their issues. Automatically close only an individually verified complete issue with a GitHub closing link and matching revision. Preserve pending evidence and update only the matching repo task.

State files may be stale. Cross-reference with live data. When `$GH_USER` is set (Step 0a), also fetch the user-scoped views so resumed state can be annotated with "yours" vs. "others":

```bash
gh pr list --state open --json number,title,headRefName,author,updatedAt
gh pr list --state merged --limit 10 --json number,title,mergedAt
gh issue list --state open --json number,title,labels,assignees --limit 500

# User-scoped views (only if $GH_USER is set)
if [ -n "$GH_USER" ]; then
  gh pr list --state open --search "author:$GH_USER" --json number,title,updatedAt
  gh pr list --state open --search "review-requested:$GH_USER" --json number,title,author,updatedAt
  gh issue list --state open --assignee "$GH_USER" --json number,title,labels
fi
```

> **Authorship guard (issue #733, `safety.md`).** `/pm` ranks and suggests, but any PR work it **dispatches** (monitoring, `/fixpr`, `/wrap`, `/subagent` against an existing PR) is a write and is scoped to PRs **you** authored. The unscoped `gh pr list` above is for context only — annotate each PR "yours" vs "others" (as this step already does) and treat collaborator PRs as **read-only** (AC6): never dispatch a fix/merge/trigger against one. The per-PR helpers (`merge-gate.sh`, `polling-state-gate.sh --ensure-session`, `pr-authorship.sh`) enforce this as a fail-safe. Override only when the user names a specific PR in chat.

**Truncation check:** If the returned issue count equals 500, warn: "Showing 500 issues — repo may have more. Results may be incomplete."

- PRs that have merged since the handoff: mark as complete, remove from assignments.
- Issues that have been closed: remove from backlog.
- New PRs not in the state file: note them as untracked.

