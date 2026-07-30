# PMM Scope, Prohibitions, and Anti-patterns

Reference doc for `.claude/skills/pr-monitor-and-manage/SKILL.md`. Contains the
parent/subagent scope table, prohibited actions, refusal template, and common
misreads that are too verbose to keep in the main dispatcher body.

---

## Parent vs Subagent scope

| Scope | Role | Allowed | Disallowed |
|-------|------|---------|------------|
| **Parent (this thread)** | Fleet orchestrator | Discover PRs, classify state, dispatch subagents, aggregate exit reports, update the fleet table, decide next tick; git rebase/force-push for `BEHIND` (Step 5a); stale-bot dismiss + re-trigger (Steps 5b/5b′); inline `/wrap` for merge-ready PRs | Direct code edits; direct git beyond discovery/rebase/dismiss; direct merges (`gh pr merge`); starting new issues; unrelated work |
| **Subagents (spawned per PR)** | Fix worker | Edit files, resolve merge conflicts, fix CR/CI findings, push commits, reply to threads, resolve bot threads — one PR each, per `.claude/rules/subagent-orchestration.md` and #509 (parallel subagents) | Modify branch protection; dismiss human reviews; bypass SAFETY rules |

Spawn pattern reference: `.claude/rules/subagent-orchestration.md` (Phase A fixer / Phase C merger). Every spawn includes the verbatim `SAFETY:` block from `.claude/rules/safety.md`.

---

## Prohibited for the parent thread (refuse and redirect)

- Writing or editing **feature code directly** — dispatch a `phase-a-fixer` subagent instead (merge conflicts, CR findings, CI failures are all dispatch cases, not refusal cases).
- Invoking `/start-issue`, `/prompt`, or spawning subagents for **new work unrelated to the discovered fleet**.
- Creating issues or PRs (other than the follow-ups `/wrap` itself creates on merge).
- Any task unrelated to managing the discovered PR fleet.

**Refusal template** when asked for genuinely out-of-scope *parent* work (not dispatchable fleet fix work):

> That's outside PR-fleet-manager mode. I'm keeping this thread focused on monitoring your open PRs. Start a separate thread (e.g. `/start-issue`) for that work — say `/pmm-stop` first if you want me to stop monitoring here.

---

## Common misreads / Anti-patterns

> If you catch yourself telling the user "I can't edit code in this thread" as a reason to **stop** rather than **dispatch**, that's wrong — the parent doesn't edit code, but its subagents do, and that's the whole point. Merge conflicts, CR findings, and CI failures are all handled by spawning fix subagents, not by refusing or hard-blocking pre-dispatch.

The parent is orchestration-only with respect to source edits: the only direct writes it performs are git rebase/force-push (Step 5a), stale-bot review dismissal + owning-bot re-trigger (Steps 5b/5b′), and the bounded mutations that `phase-a-fixer` subagents and `/wrap` already own. Fix work — including merge-conflict resolution — is delegated to parallel `phase-a-fixer` subagents (`.claude/agents/phase-a-fixer.md`); merge work stays sequential via `/wrap`. The parent never reimplements fix/merge logic beyond the shared dismiss/re-trigger helpers that `/fixpr` also uses.

---

## `--repo` constraint (load-bearing)

`--repo` scopes **discovery** (`gh pr list`) and the GraphQL/REST reads. But the per-PR helpers (`merge-gate.sh`, `pr-issue-ref.sh`, `cr-review-hourly.sh`, `dismiss-stale-bot-changes.sh`) and all git actions (rebase, force-push, fix subagents, `/wrap`) operate on the **current checkout** — they resolve the repo via `gh repo view`, not a flag. So managing a repo requires running this skill from a worktree of **that** repo. If `--repo` names a repo other than the current checkout, **stop and reconcile** (same multi-repo hazard guard as `cr-github-review.md`) rather than acting against the wrong repo.

**Invoking-repo scope (issue #687).** The `--repo` constraint above already keeps discovery + actions in one repo's lane. The one shared-state read that spans repos is the global `.active_agents` array; PMM already scopes its own work by `id` prefix (`pmm-fix-`) and treats foreign entries as read-only. When a broader, repo-scoped view of session state is needed, prefer `session-state.sh --session-view` (drops other repos' PRs and their agents) over `--get .`. Cross-repo fleet management is never implicit — point it at one repo per invocation.
