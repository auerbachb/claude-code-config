---
name: admin-merge
description: Print a user-runnable script that bypasses branch protection (enforce_admins) to squash-merge a solo-owner PR, after verifying the merge gate. Claude NEVER modifies branch protection itself — it only prints (or clipboards) the command for the repo admin to run. Triggers on /admin-merge and when /wrap hits an enforce_admins-style block.
---

Print a user-runnable bypass command to squash-merge a PR whose only remaining blocker is branch protection (`enforce_admins: true` plus a code-owner review an AI reviewer auto-skipped) on a **solo-owner** repo.

## The safety boundary (non-negotiable)

Claude's safety rules **permanently prohibit Claude from modifying branch protection** — non-negotiable, applies to every user and repo regardless of authorization or workflow history. This skill stays inside that boundary:

- Claude **prints** (or copies to the clipboard) the exact bypass command. **The user runs it.**
- Claude **NEVER** executes `gh api -X DELETE .../protection/enforce_admins`, `gh api -X POST .../protection/...`, or any other protection-modification command — not directly, not via a subprocess, not via `--execute`.
- The skill invokes `.claude/scripts/admin-merge.sh` **only** with `--print` or `--launch-terminal`. It must **never** invoke it with `--execute` (that mode is reserved for the *user* running the script in their own terminal).

If you ever find yourself about to run a protection-modifying `gh api` call, stop — that is the exact action this skill exists to avoid.

## When this triggers

1. **Explicit:** the user runs `/admin-merge <PR> [--launch-terminal]`.
2. **From `/wrap`:** `/wrap` detected a merge blocked by `enforce_admins` + a code-owner requirement and suggested `/admin-merge` as the next step.

## Scope: solo-owner repos only

This bypass is only legitimate when it does **not** skip a real human review. The script enforces a solo-owner heuristic (1 human admin = current user, ≤1 human code owner = current user; review bots in CODEOWNERS don't count). On a multi-contributor repo (extra human admin or human code owner), the script **refuses** and the skill must point the user back to the standard review flow. Do not pass `--force-solo` unless the user explicitly confirms the repo is solo-owned.

## Steps

### Step 1: Identify the PR

```bash
PR_NUM="${1:-$(gh pr view --json number --jq .number)}"
gh pr view "$PR_NUM" --json number,title,state,merged,baseRefName --jq '{number,title,state,merged,baseRefName}'
```

If no PR is found, stop: "No PR found — pass a PR number: `/admin-merge <PR>`." If already merged/closed, stop and say so.

### Step 2: Generate the bypass (script does pre-flight)

Run the helper in `--print` mode. It performs all pre-flight checks itself and only prints a command when every check passes:

```bash
.claude/scripts/admin-merge.sh "$PR_NUM" --print
ADMIN_EXIT=$?
```

The script, before printing anything:

1. **Verifies merge-readiness** via `merge-gate.sh` — CI green, primary reviewer (CR/CodeAnt) APPROVED on HEAD, all threads resolved, no human `CHANGES_REQUESTED`, not BEHIND/CONFLICTING. The **only** blocker it steps over is the branch-protection `reviewDecision` (the thing the bypass addresses). Any other missing reason is a hard blocker.
2. **Confirms solo-owner** (heuristic above).
3. **Diagnoses the protection blocker** — confirms `enforce_admins` is actually enabled and tailors the command to it (it does **not** print a generic "disable everything" command).
4. **Resolves the local clone's absolute path** and prepends `cd "<abs-path>" && ` so the command runs from any cwd.

Handle the exit code — **do not** print a bypass yourself when the script refused:

- `0` → command printed. Relay the script's full output (warning block + command) to the user verbatim. Proceed to Step 4.
- `1` → not merge-ready. Surface the script's listed blockers; tell the user to fix them (run `/fixpr`) first. **Do not** generate any bypass. Stop.
- `5` → not solo-owned. Tell the user the bypass is refused because it would skip a real review; point to the standard review flow. Stop.
- `6` → `enforce_admins` is not enabled — the merge is blocked by something else. Tell the user to inspect `gh api repos/<owner>/<repo>/branches/<branch>/protection`. Stop.
- `3` → PR not found/closed. Stop.
- `2`/`4` → usage or gh/network error. Surface stderr and stop.

### Step 3 (optional): `--launch-terminal`

If the user passed `--launch-terminal` (or asks to "open a terminal"), run:

```bash
.claude/scripts/admin-merge.sh "$PR_NUM" --launch-terminal
```

On macOS this opens a new **iTerm2** window (preferred when installed, else **Terminal.app**) `cd`'d to the repo, copies the bypass command to the clipboard (`pbcopy`), and echoes a marker line — the user just pastes (⌘V) and hits Enter. It **never** auto-executes the command. On Linux/Windows it prints a clear "macOS-only" note and falls back to inline copy-paste. Exit-code handling is the same as Step 2.

### Step 4: One-line warning to the user

Along with the printed command, tell the user plainly: *"Claude can't run this — modifying branch protection is prohibited by Claude's safety rules. Run the command above yourself; it disables `enforce_admins`, squash-merges with `--admin`, then re-enables `enforce_admins`."*

Note the inline `&&` failure mode loudly: if the merge fails, the final re-enable is skipped and protection stays OFF until the user re-runs the bare `POST`. Offer the trap-protected alternative the script prints: `bash .claude/scripts/admin-merge.sh <PR> --execute` (the **user** runs this in their terminal — never Claude).

### Step 5: Confirm the merge, then run `/wrap` follow-ups

After the user reports running the command (or you detect it), poll until the PR is merged:

```bash
gh pr view "$PR_NUM" --json merged,state --jq '{merged,state}'
```

Once `merged: true`, also confirm protection was restored:

```bash
# owner/repo/branch come from the PR; <branch> is the PR base branch
gh api repos/<owner>/<repo>/branches/<branch>/protection/enforce_admins --jq '.enabled'
```

If `enabled` is not `true`, warn the user and give them the bare re-enable command:
`gh api -X POST repos/<owner>/<repo>/branches/<branch>/protection/enforce_admins`.

Then run the standard `/wrap` follow-ups: sync root `main`, detect follow-up issues, extract lessons (see `wrap/SKILL.md` Phases 3–4). Do not re-run the merge gate — the PR is already merged.

## Notes

- **API contract (verified on PR #535):** the re-enable `POST .../protection/enforce_admins` is sent with **no body**. A body (`-f enabled=true`) returns HTTP 422 "`enabled` is not a permitted key". `admin-merge.sh` generates the bare POST — never add a field flag.
- **Repo path:** if the script can't resolve the local clone, pass `--repo-path <abs-path>`. The `cd`-prefix is what makes the command safe to run from any directory.
- **Other protection blockers** (required signed commits, required linear history, required status checks): start with `enforce_admins`; the script surfaces adjacent settings as informational notes. Extend as new cases come up.
- **Symlink (post-merge):** after this skill merges to `main`, symlink it globally per `skill-symlinks.md`:

```bash
git -C "$HOME/.claude/skills-worktree" fetch origin main --quiet
git -C "$HOME/.claude/skills-worktree" reset --hard origin/main --quiet
ln -s "$HOME/.claude/skills-worktree/.claude/skills/admin-merge" "$HOME/.claude/skills/admin-merge"
```
