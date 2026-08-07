# setup-skills-worktree.sh Hotspot Decision

Reference for Issue #1063 (`setup-skills-worktree.sh` churn hotspot). Not auto-loaded.

## Executive summary

### Verdict: **KEEP + extract** — one shared `migrate_symlink` helper collapses the triplicated state machine in Steps 4 and 5

Keep `setup-skills-worktree.sh` as the single installer surface. All 4 cited PRs
touched the hook/statusLine registration concern (Step 6), which was already
remediated by Issue #1019 (retired `HOOKS_MANIFEST`, delegated to
`register-hooks.py`). The one remaining evidence-backed defect is the triplicated
symlink-migration state machine spread across Steps 4 and 5. A single
`migrate_symlink` function extracted inside the same file collapses it without
changing any observable behavior.

## 1. Trigger and current evidence

Issue #1063 flagged 4 distinct merged PRs touching `setup-skills-worktree.sh`
since 2026-07-28: PRs #811, #829, #931, and #1027.

| PR | Section | What changed | Classification |
|----|---------|-------------|----------------|
| #811 | Step 6 — `HOOKS_MANIFEST` | Hook relocation: migrated `session-start-sync.sh` from PostToolUse to SessionStart in the inline manifest array | already-remediated (#1019) |
| #829 | Step 6 — `HOOKS_MANIFEST` | Hook registration: added `usage-limit-record.sh` (StopFailure/rate_limit) to the inline manifest array | already-remediated (#1019) |
| #931 | Step 6 / Step 6b — hook + statusLine | statusLine concern: added Step 6b block calling `register-hooks.py --statusline-only`; updated comment in hooks README | already-remediated (#1019) |
| #1027 | Step 6 — `HOOKS_MANIFEST` retirement | IS the #1019 remediation: retired the inline `HOOKS_MANIFEST` array (~300 lines of inline Python), replaced with a single `register-hooks.py` full-mode call | is the remediation |

**All 4 PRs map exclusively to the hook/statusLine registration concern (Step 6).**
None touched Steps 1–5 (worktree lifecycle, skill symlinking, or symlink migration).

### #1019-remediation verification

PR #1027 removed `HOOKS_MANIFEST=` and its ~300-line inline Python heredoc, replacing
it with:

```bash
MANAGED_LEGACY_HOOKS_DIR="$REPO_ROOT/.claude/hooks" \
  python3 "$REGISTER_HOOKS_PY" "$SKILLS_WORKTREE"
```

The `session-start-sync.test.sh` and `usage-limit-record.test.sh` tests now assert
that `HOOKS_MANIFEST=` does NOT appear in the script. The hook-churn class is closed.

### Remaining defect: triplicated symlink-migration state machine

After the #1019 remediation, the script still carries three near-identical state
machines, each independently classifying a symlink and taking the same five-branch
action:

| Block | Location | Purpose |
|-------|----------|---------|
| Step 4 per-skill loop | lines 126–143 (before refactor) | Migrate skills still pointing to the old root-repo location |
| Step 5 CLAUDE.md block | lines 155–175 | Migrate CLAUDE.md symlink to the skills worktree |
| Step 5 rules block | lines 178–198 | Migrate rules symlink to the skills worktree |

The Step 5 CLAUDE.md and rules blocks were byte-for-byte copies of the same
20-line state machine, differing only in variable names and labels. Step 4's inner
`if/else` was a two-branch subset of the same logic (legacy-migrate and
legacy-warn). All three blocks would need to be updated if the migration semantics
ever changed — the textbook drift-risk pattern.

## 2. Decision: KEEP the script, extract one shared helper

**Splitting is rejected.** `setup-skills-worktree.sh` is a cohesive
single-purpose installer: create the skills worktree, symlink skills, migrate
global symlinks, register hooks. Every step is install-time-only. There is no
independent-cadence churn between concerns, only the hook-registration concern
that has already been remediated.

**Documentation-only resolution is rejected.** The triplication is mechanical
and fixable. Documenting it without closing it leaves the drift risk in place.

**KEEP + extract is chosen.** A single `migrate_symlink` function defined inside
the same file — no new file needed for a single-consumer helper — handles all five
states. Steps 4 and 5 route through it. The script's external behavior is
unchanged: identical echo strings, identical branch outcomes.

## 3. Canonical ownership after this change

| Concern | Owner | State |
|---------|-------|-------|
| Skills worktree lifecycle | `setup-skills-worktree.sh` Step 1 | unchanged |
| Skill directory symlinking | `setup-skills-worktree.sh` Steps 2–3b | unchanged |
| Symlink migration state machine | `migrate_symlink` helper (inside the script) | **new — collapses Steps 4+5** |
| Hook and statusLine registration | `register-hooks.py` via Step 6 | unchanged (#1019) |

## 4. What is preserved

- All user-visible echo strings — identical output on every branch:
  - `$label — already correct`
  - `$label — migrating from root repo to worktree`
  - `$label — WARNING: exists in root repo but not in worktree (skill may not be on main yet)`
  - `$label — symlink points elsewhere ($current_target), updating to worktree`
  - `WARNING: $link is not a symlink — skipping (will not overwrite)`
  - `$label — creating symlink to worktree`
- Step 4's outer `if [[ "$current_target" == "$REPO_ROOT/.claude/skills/$skill_name" ]]` guard — only root-repo-pointing symlinks trigger `migrate_symlink`; other skill symlinks are not re-pointed
- `set -euo pipefail` semantics — `migrate_symlink` uses no subshells that could swallow errors
- Idempotency — multiple calls with the same state produce the same result

## 5. Verification

- **Sandboxed smoke test (7 cases × 2 assertions = 14 total)** — all 14 passed.
  Tested via `HOME`-overridden temporary directories; the live `~/.claude/` was
  never touched. Cases: missing+target-exists create; missing+target-absent no-op;
  already-correct no-op; legacy+exists migrate; legacy+absent warn; regular-file
  warn; other-target repoint.
- **Hook tests** — `session-start-sync.test.sh` and `usage-limit-record.test.sh`
  pass; the `HOOKS_MANIFEST=` absence assertions confirm no regression.
- **reference-catalog-lint.sh** — new entry in `README.md` passes the lint.
- **rule-lint.sh** and **verbatim-block-lint.sh** — both pass (no rule files changed).

## 6. Future edits

To change migration semantics (e.g. add a new symlink to manage), edit
`migrate_symlink` once and add a call site — no need to update three parallel
state machines.

<!-- churn-hotspot: setup-skills-worktree.sh -->

## Related precedent

- `.claude/reference/global-settings-hotspot-decision.md` — KEEP + targeted-dedup
  adjudication for Issue #1019; the hook-churn class (PRs #811, #829, #931, #1027)
  was already remediated there. That decision is the direct predecessor of this one.
- `.claude/reference/fixpr-hotspot-decision.md` — extraction is justified when
  independently changing deterministic blocks drive the churn; the extract-not-split
  precedent applied here.
- `.claude/reference/merge-gate-hotspot-decision.md` — extraction of a state
  machine into a shared helper inside the same file (same pattern as
  `migrate_symlink`).
- `.claude/reference/churn-hotspots.md` — observational detector semantics and
  adjudication goal.
