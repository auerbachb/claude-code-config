---
name: admin-merge
description: Merge a solo-owner PR whose only blocker is branch protection, after verifying the merge gate. Two shapes with different authority — Claude auto-runs the plain shape (a bare `gh pr merge --squash --admin`, no protection change); the `enforce_admins` toggle shape stays print-only for the repo admin. Triggers on /admin-merge and when /wrap or /babysit-pr hits a branch-protection block.
---

Merge a PR whose only remaining blocker is branch protection on a **solo-owner** repo — either by auto-running the no-protection-change shape, or by printing the protection-toggle command for the user.

## Portable helper resolution

Before any step, resolve the required helper. Stop visibly if it is unavailable.

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
ADMIN_MERGE_SH=$(resolve_script admin-merge.sh || true)
[[ -n "$ADMIN_MERGE_SH" ]] || { echo "ERROR: admin-merge.sh not found (checked all three paths) — admin merge unavailable" >&2; exit 1; }
```

## The safety boundary (non-negotiable) — a split, not a blanket

Claude's safety rules **permanently prohibit Claude from modifying branch protection** — non-negotiable, applies to every user and repo regardless of authorization or workflow history. That prohibition is about **protection modification**, not about the `--admin` flag, and the two bypass shapes fall on opposite sides of it (issues #720, #754):

| Shape | Condition | Command | Authority |
|-------|-----------|---------|-----------|
| **plain** | `enforce_admins: false` + `required_status_checks.strict: true` + verified clean-`BEHIND` | `gh pr merge --squash --admin` — nothing else | **Claude auto-runs it** via `--auto-plain` |
| **toggle** | `enforce_admins: true` | DELETE `…/enforce_admins` → merge → POST `…/enforce_admins` | **Print-only. The user runs it.** |

- Claude **MAY** execute the **plain** shape via `"$ADMIN_MERGE_SH" <PR> --auto-plain`. It modifies no setting and steps over a *staleness* requirement, not a review; every safety condition is re-verified programmatically immediately before the merge. No user turn is required.
- Claude **NEVER** executes `gh api -X DELETE .../protection/enforce_admins`, `gh api -X POST .../protection/...`, or any other protection-modification command — not directly, not via a subprocess, not via `--execute`. For the **toggle** shape Claude only ever prints (or clipboards) the command.
- The skill invokes `admin-merge.sh` with `--auto-plain`, `--print`, or `--launch-terminal`. It must **never** invoke `--execute` (that mode can run the toggle dance and is reserved for the *user* in their own terminal).
- `--auto-plain` is structurally incapable of the toggle shape: its branch contains no protection-modifying call, and any non-plain shape is a hard refusal (exit 8) that falls back to printing. Mechanism: `.claude/reference/admin-merge-auto-plain.md`.

If you ever find yourself about to run a protection-modifying `gh api` call, stop — that is the exact action this skill exists to avoid.

## When this triggers

1. **Explicit:** the user runs `/admin-merge <PR> [--launch-terminal]`.
2. **From `/wrap`:** `/wrap` detected a merge blocked by `enforce_admins` + a code-owner requirement and suggested `/admin-merge` as the next step.
3. **From the clean-BEHIND path (issues #631, #754):** on a green PR whose only remaining blocker is a *clean* `mergeStateStatus: BEHIND`, `cr-merge-gate.md` Step 1d, `/fixpr`, `/wrap`, or `/babysit-pr` routed here instead of looping rebases. This is the **plain** shape, so it goes straight to Step 1b and merges without a user turn; a non-plain shape falls back to the Step 2 print flow.

## Scope: solo-owner repos only

This bypass is only legitimate when it does **not** skip a real human review. The script enforces a solo-owner heuristic (1 human admin = current user, ≤1 human code owner = current user; review bots in CODEOWNERS don't count). On a multi-contributor repo (extra human admin or human code owner), the script **refuses** and the skill must point the user back to the standard review flow. Do not pass `--force-solo` unless the user explicitly confirms the repo is solo-owned.

## Steps

### Step 1: Identify the PR

```bash
PR_NUM="${1:-$(gh pr view --json number --jq .number)}"
gh pr view "$PR_NUM" --json number,title,state,baseRefName --jq '{number,title,state,baseRefName}'
```

If no PR is found, stop: "No PR found — pass a PR number: `/admin-merge <PR>`." If already merged/closed, stop and say so.

### Step 1b: Auto-path — execute the plain shape (do this first)

**Skip this step entirely when the user asked for the command rather than a merge** — `--launch-terminal`, "give me the command", "open a terminal", "just print it". An explicit request for the command outranks the auto path; go straight to Step 2/3. Step 1b is for the cases that arrive *without* a stated preference: `/admin-merge <PR>` on its own, and the `/wrap`, `/fixpr`, `/babysit-pr`, and clean-`BEHIND` routes.

**First complete `cr-merge-gate.md` Step 2** — read the PR body's Test Plan and verify **every** checkbox against the source at the current SHA. `clean-behind-check.sh` only confirms the boxes are *ticked*, which is a proxy; an unattended merge must not rest on it. If any criterion fails, fix it first — do not merge. Only then attest with `--ac-verified` (the script refuses without it):

```bash
"$ADMIN_MERGE_SH" "$PR_NUM" --auto-plain --ac-verified
AUTO_EXIT=$?
```

It runs the **same** pre-flight as `--print` and refuses (exit 8) unless the diagnosed shape is `plain`, so it is safe to attempt without diagnosing the shape yourself:

- `0` → **merged.** Relay the script's `AUTO_PLAIN_MERGED` evidence block verbatim (PR, shape, head SHA, `base_ahead_by`, file overlap + granularity, AC counts, solo-owner note) — every auto-executed bypass must be reported after the fact. Skip Steps 2–4 and go to Step 5.
- `8` → **refused, nothing executed.** The stderr line names which: `shape=toggle` (protection modification — Claude must not run it), `reason=ac-unverified` (you skipped Step 2 — go do it, then re-run), `reason=repeat` (an auto attempt already ran), or `reason=guard-unwritable` (the repeat-guard marker could not be written, so the retry guard could not be armed). The script has already printed the command; continue with Step 2's exit-code handling and Step 4's user warning as if you had run `--print`. Do **not** retry `--auto-plain` except after fixing an `ac-unverified` or `guard-unwritable` cause.
- `1` → not merge-ready, refused by the authorship guard, or the clean-BEHIND state no longer held at merge time (`main` advanced). Surface the reason and route to rebase / `/fixpr`. **Do not** print a bypass. Stop.
- `5`/`6`/`3`/`2`/`4`/`7` → same handling as Step 2's table (`7` = the merge ran but did not confirm; verify manually, do not retry).

Never pass `--force-solo` or `--allow-nonauthor` here, and never pass `--ac-verified` without having actually done Step 2 — it is an attestation, and a false one merges unverified work. `--auto-plain` runs one attempt per PR by design; if it refuses with `reason=repeat`, that is a signal a human should look, not a marker to delete.

### Step 2: Generate the bypass (script does pre-flight)

Reached when Step 1b returned exit 8 (already printed the command — reuse that output, don't re-run the script) or when the user explicitly asked for the command rather than a merge. It performs all pre-flight checks itself and only prints a command when every check passes:

```bash
"$ADMIN_MERGE_SH" "$PR_NUM" --print
ADMIN_EXIT=$?
```

The script, before printing anything:

1. **Verifies merge-readiness** via `merge-gate.sh` — CI green, primary reviewer (CR/CodeAnt) APPROVED on HEAD, all threads resolved, no human `CHANGES_REQUESTED`, not CONFLICTING. It steps over exactly two protection-mechanical blockers: the branch-protection `reviewDecision` (the thing the bypass addresses) and a **clean `BEHIND`** — a `mergeStateStatus: BEHIND` that `clean-behind-check.sh` confirms is safe (gate green except BEHIND, `mergeable != CONFLICTING`, AC verified, and the base delta's changed line ranges do **not** intersect the PR's changed line ranges at hunk level; conservative file-level fallback when patches are unavailable; issues #631, #667). A non-clean BEHIND (overlapping hunks at hunk level, or file-level overlap when patch data is absent) or any other missing reason is a hard blocker → the script refuses and points back to the rebase → re-run path.
2. **Confirms solo-owner** (heuristic above).
3. **Diagnoses the protection blocker and selects the bypass shape** — if `enforce_admins` is enabled, it builds the toggle chain (disable → merge → re-enable); if `enforce_admins` is off but `required_status_checks.strict` is blocking a clean-BEHIND branch, it uses a plain `--admin` merge (no protection changes); otherwise it refuses with exit 6. It does **not** print a generic "disable everything" command.
4. **Resolves the local clone's absolute path** and prepends `cd "<abs-path>" && ` so the command runs from any cwd.

Handle the exit code — **do not** print a bypass yourself when the script refused:

- `0` → command printed. Relay the script's full output (warning block + command) to the user verbatim. The printed command is either the protection-toggle chain (`enforce_admins=true` shape: DELETE + merge + POST) or a plain `gh pr merge --squash --admin` (`enforce_admins=false` + `required_status_checks.strict=true` + clean-BEHIND shape); relay whichever was printed without substituting. Proceed to Step 4.
- `1` → not merge-ready. Surface the script's listed blockers; tell the user to fix them (run `/fixpr`) first. **Do not** generate any bypass. Stop.
- `5` → not solo-owned. Tell the user the bypass is refused because it would skip a real review; point to the standard review flow. Stop.
- `6` → `enforce_admins` is off **and** the blocker is not an explainable `strict` + clean-BEHIND case — the merge is blocked by something else. Tell the user to inspect `gh api repos/<owner>/<repo>/branches/<branch>/protection`. Stop.
- `3` → PR not found/closed. Stop.
- `2`/`4` → usage or gh/network error. Surface stderr and stop.

### Step 3 (optional): `--launch-terminal`

If the user passed `--launch-terminal` (or asks to "open a terminal"), run:

```bash
"$ADMIN_MERGE_SH" "$PR_NUM" --launch-terminal
```

On macOS this opens a new **iTerm2** window (preferred when installed, else **Terminal.app**) `cd`'d to the repo, copies the bypass command to the clipboard (`pbcopy`), and echoes a marker line — the user just pastes (⌘V) and hits Enter. It **never** auto-executes the command. On Linux/Windows it prints a clear "macOS-only" note and falls back to inline copy-paste. Exit-code handling is the same as Step 2.

### Step 4: One-line warning to the user

Along with the printed command, tell the user what the command does — the framing depends on which shape was printed (the warning block in the script's output identifies it):

- **Toggle shape** (command includes DELETE + POST calls, `enforce_admins=true`): *"Claude can't run this — modifying branch protection is prohibited by Claude's safety rules. Run the command above yourself; it disables `enforce_admins`, squash-merges with `--admin`, then re-enables `enforce_admins`."* Note the inline `&&` failure mode: if the merge fails, the final re-enable is skipped and protection stays OFF until the user re-runs the bare `POST`. Offer the trap-protected `--execute` alternative the resolved script prints (the **user** runs this — never Claude).
- **Plain shape** (command is just `gh pr merge --squash --admin`, no protection calls) — only reached when Step 1b refused with `reason=repeat`, or the user asked for the command instead of a merge: *"Run the command above; it does an ordinary admin squash-merge that bypasses the strict up-to-date requirement on a verified clean-BEHIND branch. No protection settings are modified."* Say which of the two reasons applies — a repeat refusal means an earlier auto attempt did not confirm, so the PR is worth a look before re-running.

### Step 5: Confirm the merge, then run `/wrap` follow-ups

If Step 1b exited `0` the merge is already verified (`state == MERGED`, retried) — skip straight to the follow-ups below. Otherwise, after the user reports running the command (or you detect it), poll until the PR is merged:

```bash
gh pr view "$PR_NUM" --json state --jq '{state}'
```

Once `state: MERGED`, if the **toggle shape** was used (the command included protection changes), confirm protection was restored:

```bash
# owner/repo/branch come from the PR; <branch> is the PR base branch
gh api repos/<owner>/<repo>/branches/<branch>/protection/enforce_admins --jq '.enabled'
```

If `enabled` is not `true`, warn the user and give them the bare re-enable command:
`gh api -X POST repos/<owner>/<repo>/branches/<branch>/protection/enforce_admins`.

Then run the standard `/wrap` follow-ups: sync root `main`, detect follow-up issues, extract lessons (see `wrap/SKILL.md` Phases 3–4). Do not re-run the merge gate — the PR is already merged.

## Notes

- **Auto-path mechanism** (shape gate, repeat guard, TOCTOU re-validation, exit-code contract, evidence-report shape, and the resolved #754 open questions): `.claude/reference/admin-merge-auto-plain.md`.
- **API contract (verified on PR #535):** the re-enable `POST .../protection/enforce_admins` is sent with **no body**. A body (`-f enabled=true`) returns HTTP 422 "`enabled` is not a permitted key". `admin-merge.sh` generates the bare POST — never add a field flag.
- **Repo path:** if the script can't resolve the local clone, pass `--repo-path <abs-path>`. The `cd`-prefix is what makes the command safe to run from any directory.
- **Other protection blockers** (required signed commits, required linear history, required status checks): start with `enforce_admins`; the script surfaces adjacent settings as informational notes. Extend as new cases come up.
- **Symlink (post-merge):** after this skill merges to `main`, symlink it globally per `skill-symlinks.md`:

```bash
git -C "$HOME/.claude/skills-worktree" fetch origin main --quiet
git -C "$HOME/.claude/skills-worktree" reset --hard origin/main --quiet
ln -s "$HOME/.claude/skills-worktree/.claude/skills/admin-merge" "$HOME/.claude/skills/admin-merge"
```
