# Global-Settings Hotspot Decision

Reference for Issue #1019 (`global-settings.json` churn hotspot). Not auto-loaded.

## Executive summary

### Verdict: **KEEP** `global-settings.json` as the single source of truth; **retire the duplicated `HOOKS_MANIFEST`**

Keep `global-settings.json` intact as the canonical definition of every hook
event, matcher, script, and timeout. Do not split the file. Retire the
hand-maintained `HOOKS_MANIFEST` bash array in `setup-skills-worktree.sh` — it
is a duplicate that already drifted (4 hooks missing), and `register-hooks.py`
already reads `global-settings.json` directly as the source of truth.

The file's churn is contract churn by construction: every new hook must be
registered somewhere. The only avoidable tax in the history was the parallel
`HOOKS_MANIFEST` array, which required a coordinated two-file edit and failed
to stay current.

## 1. Trigger and current evidence

Issue #1019 flagged 6 merged PRs touching `global-settings.json` since
2026-07-30: PRs #807, #811, #829, #922, #931, and #944.

| Churn class | PRs | Hook / field changed |
|-------------|-----|----------------------|
| Hook registration — new Stop/PostToolUse guards | PR #807 | Added `bgwork-ceiling-arm.sh` (PostToolUse) and `bgwork-ceiling-guard.sh` (Stop) |
| Hook relocation — event migration | PR #811 | Moved `session-start-sync.sh` from PostToolUse to SessionStart |
| Hook registration — StopFailure recorder | PR #829 | Added `usage-limit-record.sh` (StopFailure/rate_limit) |
| Hook registration — tick watchdog | PR #922 | Added `babysit-tick-watchdog.sh` (PostToolUse) |
| statusLine field edit | PR #931 | Updated `statusLine.command` path (not a hook) |
| Hook registration — SubagentStop handoff | PR #944 | Added `checkpoint-handoff.sh` (SubagentStop) |

Five of the six PRs are hook-registration or hook-relocation churn. PR #931 is
the outlier: it edited the `statusLine` field, which is a separate top-level key,
not the `hooks` tree. No 7th PR touched the file after #944.

### Live drift at Issue #1019

The `HOOKS_MANIFEST` bash array in `setup-skills-worktree.sh` is missing four
hooks that are present in `global-settings.json`:

- `bgwork-ceiling-guard.sh` (Stop) — added by PR #807
- `bgwork-ceiling-arm.sh` (PostToolUse) — added by PR #807
- `babysit-tick-watchdog.sh` (PostToolUse) — added by PR #922
- `checkpoint-handoff.sh` (SubagentStop) — added by PR #944

`setup.sh` Step 7 detects this drift at install time and fails with
"global-settings.json has hooks not registered in settings.json".
`register-hooks.py` (called each session by `session-start-sync.sh`) repairs
the drift at session start, but a fresh install will see the Step 7 failure
until a manual `setup-skills-worktree.sh` re-run adds the missing entries — a
maintenance burden that the two-source design created.

## 2. Decision: KEEP the single file, retire the duplicate

**Splitting is rejected.** The `hooks` tree is a cohesive junction: every
install path reads exactly this surface to know which scripts to register and
under which event/matcher. A split would multiply the coordinated-edit surface
without eliminating the root cause. PR #931's `statusLine` edit argues the
opposite: it landed with zero friction because `statusLine` is a single field in
one file, not a split abstraction.

**A documentation-only resolution is rejected.** The drift is measurable and
the fix is straightforward: retire `HOOKS_MANIFEST` and route
`setup-skills-worktree.sh` Step 6 through `register-hooks.py`, which already
reads `global-settings.json`. Documenting the drift class without closing it
would leave future hook additions subject to the same two-file coordination
requirement.

**KEEP + targeted deduplication is chosen.** `global-settings.json` remains
byte-for-byte unchanged. The remediation retires `HOOKS_MANIFEST` by extending
`register-hooks.py` to full install-time parity and routing both
install-time and session-start registration through the same implementation.

## 3. Canonical ownership

| Content | Canonical owner | Consumers |
|---------|-----------------|-----------|
| Hook event tree (events, matchers, scripts, timeouts) | `global-settings.json` | `register-hooks.py`, `setup.sh` drift check |
| statusLine command | `global-settings.json` | `register-hooks.py` (both install-time and session-start) |
| Permissions, model, env | `global-settings.json` | `setup.sh` (seeded at install; never overwritten on re-run) |
| Hook registration implementation | `register-hooks.py` | `setup-skills-worktree.sh` (install-time), `session-start-sync.sh` (session-start) |

## 4. What is preserved

- `bypassPermissions` mode — see `repo-audit-2026-05.md` for the deliberate
  choice; this field is never touched by the remediation.
- The placeholder-path convention (`/path/to/claude-code-config/...`) in
  `global-settings.json` stays unchanged; `register-hooks.py` resolves it at
  install time and session start.
- `setup.sh`'s merge-not-overwrite behavior for permissions, model, and env
  keys is not touched.
- All user-customized timeouts, extra hooks not in the template, and the
  `statusLine` sibling keys (`padding`, `refreshInterval`) are preserved by
  `register-hooks.py`'s in-place repair behavior.

## 5. Targeted remediation

1. **Extend `register-hooks.py` to full install-time parity** with the retired
   inline Python:
   - Add `command_argv0()` to extract the executable path from a hook command
     string that may carry arguments (e.g. `foo.sh --check`); fix
     `find_existing()` to use argv0 rather than the raw command for basename
     matching.
   - Add decommissioned-hook pruning: when a hook script is absent from the
     manifest, resides in a managed hooks directory, and its script file no
     longer exists, remove the stale registration. Restrict pruning to managed
     roots (`hooks_dir` + `MANAGED_LEGACY_HOOKS_DIR` env var) so third-party
     hook registrations are never touched.
2. **Retire `HOOKS_MANIFEST` from `setup-skills-worktree.sh`**: replace the
   300-line inline Python heredoc and the separate `--statusline-only` Step 6b
   call with a single full-mode `register-hooks.py` invocation. Full mode
   already registers hooks, prunes stale registrations, and syncs statusLine
   in one atomic write.
3. **Update `setup.sh` Step 7 remediation text** to name `setup-skills-worktree.sh`
   rather than `HOOKS_MANIFEST` as the fix path, since `HOOKS_MANIFEST` no
   longer exists.
4. **Register this decision** in the reference catalog.

After this remediation, a new hook requires exactly one edit:
1. Add the hook script to `.claude/hooks/`.
2. Add the entry to `global-settings.json`.
3. `register-hooks.py` (at session start or install) picks it up automatically
   with no manifest to update.

## 6. Future edits and reconsideration

For a new hook:
- Add the script to `.claude/hooks/`.
- Add one entry to the `hooks` tree in `global-settings.json`.
- No `HOOKS_MANIFEST` update is needed.
- `setup.sh` Step 7's drift check will report the new hook absent until
  `setup-skills-worktree.sh` runs (or until session-start-sync.sh fires at
  session start), which is the expected repair path.

Reconsider this KEEP verdict only if:
- Separate concerns within `global-settings.json` begin changing on independent
  cadences and causing merge conflicts.
- The hooks tree grows large enough that a separate tracked file would be
  meaningfully easier to audit.

The `model: "opus"` hardcoded field is noted in `repo-audit-2026-05.md` and
is deliberately out of scope for this remediation: none of the 6 churn PRs
touched that field, and extending `model-fleet.sh` with a settings-default
alias mode is a separate audit item.

<!-- churn-hotspot: global-settings.json -->

## Related precedent

- `.claude/reference/session-state-schema-hotspot-decision.md` — KEEP + targeted
  deduplication when churn follows one cohesive contract.
- `.claude/reference/fixpr-hotspot-decision.md` — extraction is justified when
  independently changing deterministic blocks drive the churn.
- `.claude/reference/start-issue-hotspot-decision.md` — KEEP/no-operative-change
  when churn is required propagation rather than independent growth.
- `.claude/reference/churn-hotspots.md` — observational detector semantics and
  adjudication goal.
