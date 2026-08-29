# `admin-merge.sh --auto-plain` — the Claude-invocable plain-shape executor (issue #754)

Not auto-loaded. Mechanism, contracts, and rationale for the one admin-merge shape Claude may execute itself. Rules-corpus summary: `.claude/rules/cr-merge-gate.md` Step 1d. Skill entry point: `.claude/skills/admin-merge/SKILL.md`.

## Why the boundary moved (and where it didn't)

Claude may never modify branch protection. That prohibition is about *protection modification*, not about the `--admin` flag — and #720 made the difference mechanically detectable by splitting the bypass into two shapes:

| Shape | Condition | What it runs | Claude |
|-------|-----------|--------------|--------|
| **plain** | `enforce_admins == false` **and** `required_status_checks.strict == true` **and** `CLEAN_BEHIND_OK == true` | `gh pr merge --squash --admin` — nothing else | **May execute** via `--auto-plain` |
| **toggle** | `enforce_admins == true` | DELETE `…/protection/enforce_admins` → merge → POST `…/protection/enforce_admins` | **Print-only, forever** |

The plain shape modifies no setting, needs no privilege the thread lacks, and steps over a *staleness* requirement — not a review. Every condition that makes it safe was verified programmatically moments earlier. Printing it bought nothing: the alternative to pasting was a rebase, which invalidates the approvals and re-runs the whole review round.

Before #754 both shapes were gated behind `--execute`, which is user-only *because* it can also run the toggle dance. `--auto-plain` exists so the plain shape has an entry point that is structurally incapable of the toggle — rather than relaxing `--execute`'s prose and relying on an agent to stay on the right branch.

## Structural guarantee

The auto path's safety is structural, not textual:

1. The `--auto-plain` branch in `admin-merge.sh` **contains no protection-modifying call.** `$DELETE_CALL` and `$REENABLE_CALL` are never invoked from it. Asserted statically by `admin-merge.test.sh` (test 25) so a future edit that reintroduces one fails CI.
2. **The shape gate is a refusal, not a warning.** `BYPASS_MODE != plain` → print the command exactly as `--print` would, emit `AUTO_PLAIN_REFUSED: shape=<mode>` on stderr, exit `8`. It is evaluated after `BYPASS_MODE` is computed and before any write; test 26 asserts it precedes the merge call.
3. `--auto-plain` never passes `--force-solo`, so the solo-owner heuristic always applies.

A degraded-context agent, or one following an injected instruction, cannot reach protection modification through this mode — there is nothing there to reach.

## Order of operations

Everything before the shape gate is the existing `--print` pre-flight, unchanged:

1. Authorship guard (#733) — `pr-authorship.sh`, fail-closed. `--auto-plain` never passes `--allow-nonauthor`.
2. `merge-gate.sh` hard-blocker filter — steps over exactly two protection-mechanical blockers (the branch-protection `reviewDecision` note, and a `BEHIND` whose mechanical safety `clean-behind-check.sh` confirms). A normal helper exit 0 is accepted directly. If the helper exits 1 only because its bundled gate still includes the branch-protection `reviewDecision` note, `admin-merge.sh` accepts the JSON evidence only when the PR is `BEHIND`, mergeable, zero-overlap, all AC boxes are checked, and every residual blocker is that reviewDecision note. Every other helper error or blocker remains a refusal.
3. Solo-owner heuristic.
4. Branch-protection read → `BYPASS_MODE`.

Then, `--auto-plain` only:

5. **Hard shape gate** → exit `8` on anything but `plain`.
6. **Repeat guard** → exit `8` if a marker already exists.
7. `cd` into the resolved `REPO_PATH` so `gh pr merge` targets the intended repo from any cwd.
8. **Mandatory re-validation** — re-run `clean-behind-check.sh`, capturing its JSON and applying the same clean-BEHIND evidence test used at pre-flight. Unsafe mechanics, any non-reviewDecision residual, or a helper error → exit `1` ("rebase and re-run instead of bypassing").
9. Write the repeat-guard marker.
10. `gh pr merge <N> --squash --admin`, then the 3-attempt `state == MERGED` read-after-write retry.
11. Evidence report on stdout.

### Why step 8 cannot be skipped

`CLEAN_BEHIND_OK == true` is a precondition of `BYPASS_MODE == plain`, and it can only be true if `clean-behind-check.sh` was found and either exited `0` or supplied the narrowly accepted safe-mechanics JSON described above. So a missing helper can never reach the auto path — but the branch still checks `-z "$CBC"` and refuses rather than assuming.

The re-validation exists for TOCTOU: `main` can advance between the pre-flight snapshot and the merge, turning a clean `BEHIND` into one whose base delta now overlaps this PR's lines. Test 22 drives a stub that returns safe on call 1 and unsafe on call 2, and asserts both that the merge is refused and that the helper genuinely ran twice.

Refusals distinguish the routing decision. Any non-BEHIND blocker keeps the general "not merge-ready apart from branch protection" message. When the only blocker is a BEHIND whose mechanical evidence is unsafe, the script says it is "not safe to skip a rebase" and prints the helper's `reasons_not_safe` entries. A verified clean-BEHIND proceeds without listing BEHIND as outstanding.

## Exit-code contract

| Code | Meaning | Caller action |
|------|---------|---------------|
| `0` | Merged. Evidence report on stdout. | Relay the report; continue with `/wrap` follow-ups. |
| `1` | Refused — not merge-ready, authorship guard, or the clean-BEHIND state no longer holds. | Rebase / `/fixpr`. **Never** print a bypass. |
| `2` / `3` / `4` | Usage / PR not found / gh-jq error. | Surface stderr, stop. |
| `5` | Not solo-owned. | Standard review flow. |
| `6` | No bypass path detected. | Inspect branch protection. |
| `7` | Unusable repo path (refused right after argument parsing, before any `gh` call — issue #1439), merge failed, or the PR never reported `state=MERGED`. | Verify manually; do not retry blindly (if the merge itself ran, the marker is already written). A path refusal is safe to retry with a corrected `--repo-path`: nothing ran. |
| `8` | Refused by the auto path: shape is not `plain`, or an attempt already ran. The command is printed. | Fall back to the normal `/admin-merge` print flow. |

Exit `8` is deliberately distinct from `1`: `1` means *the merge is not safe*, `8` means *the merge may be safe but Claude must not be the one to run it*.

## Repeat guard

Marker: `$HOME/.claude/admin-merge-auto/<owner>__<repo>__<pr>`, holding a UTC timestamp and the head SHA.

Written immediately **before** the merge call, so a crash mid-merge also disarms the auto path — the failure mode that matters is an `--admin` merge whose outcome is unknown, and re-firing it on every `/babysit-pr` tick would hammer the API and mask the real blocker. A refusal at steps 5, 6, or 8 writes nothing: nothing was attempted, so nothing is burned.

One auto attempt per PR. Re-arm deliberately:

```bash
rm "$HOME/.claude/admin-merge-auto/<owner>__<repo>__<pr>"
```

The marker is per-machine local state, not session state — it intentionally survives session restarts and context compaction, which is what makes it a guard rather than a hint.

## Evidence report

Printed on stdout after a verified merge, sourced from the **re-validation** JSON (step 8) — not the pre-flight snapshot — so it describes the state that actually authorized the merge:

```
# ───────────────────────────────────────────────────────────────────
# AUTO_PLAIN_MERGED: PR #742 (auerbachb/claude-code-config @ main)
# shape:      plain — bare 'gh pr merge --squash --admin'; NO branch-protection call
# head SHA:   abc1234def…
# authorized by clean-behind-check.sh, re-validated immediately before the merge:
#   base ahead by:  2 commit(s)
#   file overlap:   0 (hunk granularity)
#   AC checkboxes:  6/6 checked
# solo-owner verified: 1 human admin (auerbachb), 1 human code owner(s)
# ───────────────────────────────────────────────────────────────────
```

Missing or unparseable evidence fields render as `?` — a cosmetic report field must never abort a merge that was already verified safe.

## Resolved open questions (#754)

**Keep the solo-owner heuristic on the auto path.** The plain shape skips a staleness requirement rather than a review, so dropping the heuristic would arguably still be safe — but "arguably safe" is the wrong standard for an unattended write. Keeping it means the auto path's blast radius is never wider than the print path it replaces. The heuristic is cheap and fails closed.

**One attempt per PR, then fall back to printing.** A successful auto-merge is terminal, so a second attempt can only follow a failure the pre-flight could not see — exactly the case where a human should look.

## Related

Issues #754 (this mode), #720 (shape split), #631 / #667 (`clean-behind-check.sh`), #733 (authorship guard), #451 (original toggle bypass) · `.claude/reference/authorship-guard.md` · `.claude/reference/merge-gate-reviewer-paths.md`
