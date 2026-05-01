# Contributing to claude-code-config

This repo is the single source of truth for Claude Code skills, rules, hooks, and `CLAUDE.md`. Any change here affects every session that uses this config, so every change must go through the standard issue → PR → review → squash-merge flow.

For deep-dive architecture (symlink topology, hook lifecycle, multi-agent orchestration, review loop internals), see [ARCHITECTURE.md](ARCHITECTURE.md).

## PR Workflow (general)

- **Every PR links to a GitHub issue.** Create one first via `gh issue create` if none exists. Reference it with `Closes #N` in the PR body.
- **Branch naming:** `issue-N-short-description`. Never work on `main`.
- **Always use a worktree** for isolated work — see the "Always use a worktree" section of [CLAUDE.md](CLAUDE.md).
- **Local review before push:** run `coderabbit review --prompt-only` until one clean pass, then commit and push. See [`.claude/rules/cr-local-review.md`](.claude/rules/cr-local-review.md).
- **Merge gate:** 1 explicit CodeRabbit APPROVED on current HEAD (plus CodeAnt clean signal when CodeAnt has run on that SHA), or 1 clean BugBot pass, or a clean Greptile severity gate. See [`.claude/rules/cr-merge-gate.md`](.claude/rules/cr-merge-gate.md).
- **CI must pass before merge** (including the `rule-lint` check that verifies rule-file sizes and index alignment).
- **Squash merge only:** `gh pr merge --squash --delete-branch`.
- **Test plan required:** every PR body must include a `## Test plan` section with a checkbox for each acceptance criterion.

## Adding a New Skill

Skills live in `.claude/skills/<name>/SKILL.md`.

1. **Create `SKILL.md`** with YAML frontmatter:
   - `name` (required)
   - `description` (required — used by the model for discovery; be specific about when to trigger)
   - `model` (optional: `sonnet` or `opus` override)
   - `triggers` (optional: natural-language invocation phrases)
   - `allowed-tools` (optional: restrict the skill to specific tools)
   - `disable-model-invocation` (optional: prevents auto-trigger AND hides from slash-command autocomplete — avoid unless you really mean both)
2. **Skill body:** step-by-step instructions, exact bash commands with absolute paths, and clear exit criteria. Subagents skip prose rules — prefer numbered checklists with explicit STOP conditions.
3. **Symlink checklist after merge** (via the skills worktree — never symlink directly to the root repo):

   ```bash
   # Update the skills worktree to pick up the new skill
   git -C ~/.claude/skills-worktree fetch origin main --quiet
   git -C ~/.claude/skills-worktree reset --hard origin/main --quiet

   # Create/update the global symlink (idempotent)
   ln -sfn ~/.claude/skills-worktree/.claude/skills/<name> ~/.claude/skills/<name>
   ```

See [`.claude/rules/skill-symlinks.md`](.claude/rules/skill-symlinks.md) for the full symlink rules and verification commands.

## Adding a New Rule

Rules live in `.claude/rules/<name>.md` and auto-load in every parent-agent session.

1. **Create the file** at `.claude/rules/<name>.md`.
2. **File size limits** (see CLAUDE.md "Rule File Size Guidelines"):
   - **Soft cap:** ~150 lines / ~1,500 words per file — consider splitting if exceeded.
   - **Hard cap:** 200 lines / 2,000 words per file — must split.
3. **Total budget:** CLAUDE.md + all rule files ≤ **10,000 words** (matches `.coderabbit.yaml`).
4. **Verification command:**

   ```bash
   { cat CLAUDE.md; find .claude/rules -name '*.md' -exec cat {} +; } | wc -w
   ```

   Run this on any PR that touches CLAUDE.md or `.claude/rules/`. If the total exceeds 10,000, condense before merging.
5. **Update the CLAUDE.md rule index table** with a new row for the file (file name + one-line contents summary).
6. **CI will verify** index alignment and the word-count budget via the `rule-lint` check.

## Adding a New Hook

Hooks live in `.claude/hooks/` and run automatically during Claude Code sessions.

1. **Create the script** at `.claude/hooks/<name>.sh` (bash) or `.claude/hooks/<name>.py` (Python). Make it executable: `chmod +x .claude/hooks/<name>.sh` (or `.py`).
2. **Implement the JSON contract** for the event type (`PreToolUse`, `PostToolUse`, `Stop`, etc.) — see existing hooks in `.claude/hooks/` for reference patterns.
3. **Register the hook** in `global-settings.json` under `hooks.{event}` using the `/path/to/claude-code-config` placeholder path.
4. **Auto-registration** handles the rest: the `session-start-sync.sh` hook resolves placeholders to the skills-worktree hooks directory and adds the entry to each user's `~/.claude/settings.json` on the next session start. Existing entries (including user-customized timeouts) are preserved.
5. **Test locally** by running the script directly with a sample JSON payload on stdin before pushing.

See [ARCHITECTURE.md](ARCHITECTURE.md) "Hook Lifecycle" and "Hook Auto-Registration" for details on event types and the registration flow.

## Git Pre-commit Hook (Worktree Enforcement)

`setup.sh` installs `.claude/git-hooks/pre-commit` into the shared git hooks directory on first run (and reuses it on later runs when unchanged). When this hook is installed and not bypassed, it rejects commits made on `main` in the root checkout, enforcing the "never work on main" rule at the git level for any committer — human, Claude, Cursor, Codex, or a random terminal session.

- **Blocks:** `git commit` while on `main` in the root checkout.
- **Allows:** any other branch, detached HEAD, and commits on `main` inside a worktree (rare but not this hook's concern).
- **Bypass:** `git commit --no-verify` still works for genuine emergencies — left functional on purpose.
- **User customization:** if `.git/hooks/pre-commit` already exists with different content, `setup.sh` warns and leaves your hook in place.

## Modifying CLAUDE.md

- CLAUDE.md is the **executive summary** — high-level non-negotiables and pointers to rule files. Target: **≤ 1,000 words**.
- **Detailed protocols, step-by-step procedures, and edge cases belong in `.claude/rules/*.md`**, not in CLAUDE.md.
- **Do not duplicate** content between CLAUDE.md and rule files. When the same topic appears in both, CLAUDE.md should link to the rule file as the authoritative source.
- Any change that touches CLAUDE.md must re-run the word-count verification command above.

## Deep-Dive Reference

For symlink topology, the skills worktree rationale, hook lifecycle, session lifecycle, multi-agent orchestration, the review loop fallback chain, and key design decisions, see [ARCHITECTURE.md](ARCHITECTURE.md).
