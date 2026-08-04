# CLAUDE.md Hotspot Decision

Reference for Issue #928 (`CLAUDE.md` churn hotspot). Not auto-loaded.

## Executive summary

### Verdict: **KEEP** the single executive contract; make **no content change**

Keep `CLAUDE.md` as the one auto-loaded executive summary for repository-wide agent behavior. Do
not split it, extract one of its directives, or make a target-driven wording pass in this
remediation. Its recent churn records intentional changes to cross-cutting policy plus four
deliberate compression passes; it is not evidence that unrelated concerns have accumulated in one
implementation file.

This decision is intentionally reference-only. `CLAUDE.md`, every `.claude/rules/*.md` file, and
`.claude/rules/.budget-soft-cap` remain byte-for-byte unchanged.

## 1. Trigger and current evidence

Issue #928 originally recorded 14 merged PRs touching `CLAUDE.md` after 2026-07-18. Current `main`
adds PRs #919, #932, and #982, producing 17 touches:

| Churn class | PRs | What changed |
|-------------|-----|--------------|
| Executive policy and behavior | PRs #717, #736, #737, #760, #761, #774, #825, #828, #862, #878, #922, #982 | Monitoring, merge authority, issue claiming, pipeline posture, output, and rule-index routing |
| Deliberate corpus compression | PRs #660, #742, #804, #919 | Removed restatement and relocated mechanism while preserving binding rules |
| Budget-policy decision | PR #932 | Clarified the ratchet's role and paid for the wording with same-file cuts |

The adjudication was measured on 2026-08-04 at `main`
`3422676b74bdb125523b318c368a770fe0480736`. `wc -l CLAUDE.md` reports 121 lines and
`wc -w CLAUDE.md` reports 1,358 words, 58 above the contributor target of 1,300 and below the
2,000-word per-file warning. The merge commit for PR #919 measures 1,450 words before and 1,360
after with the same command; that PR explicitly preserves the remaining output-policy and no-main
prohibitions instead of deleting load-bearing repetition just to hit a number. PR #982 then replaced
the recurring-poll directive and reduced the file by two more words to the current 1,358. The
current file contains no large executable command block.

The hotspot detector reports zero recorded conflict rounds. The signal is therefore edit
frequency, not measured merge pain.

## 2. Why the initial CodeRabbit prescription is superseded

CodeRabbit's plan correctly proposed checking duplicated scheduling, admin-merge, and rule-budget
text and verifying the corpus mechanically. Its concrete edits were generated before three later
changes:

- PR #982 replaced the proposed `/loop` wording with the persistent `Monitor` contract.
- PR #932 reviewed the ratchet summary, added the canonical budget decision record, and removed
  nearby restatement to fund it.
- PR #919 completed a broad corpus-slimming pass, including a 90-word `CLAUDE.md` reduction, and
  documented why the remaining prohibitions should not be cut.

Replaying the older edits would either restore obsolete scheduling language or reopen wording that
was reviewed with newer context. The plan's useful ownership and verification goals remain part of
this adjudication; its stale patch list does not.

## 3. Options considered

### Option 1: Split `CLAUDE.md` into smaller executive files

**Rejected.** Every split child would still need to auto-load, so total context and coordinated
policy churn would not fall. The current sections share one purpose: bootstrap the parent agent's
non-negotiable repository posture before specialized rules apply. A split would add discovery and
index boundaries without isolating independently consumed behavior.

### Option 2: Extract a section into a script or skill

**Rejected.** Deterministic operations already route to scripts and detailed workflow procedures
already live in rules and skills. What remains in `CLAUDE.md` is executive policy: merge authority,
message behavior, autonomy, worktree discipline, issue flow, rule routing, and memory posture.
Moving those directives behind an on-demand surface would weaken their always-loaded role.

### Option 3: Perform another deduplication pass

**Rejected for this remediation.** PRs #919 and #932 just performed that work, and PR #919 recorded
the constraint-level reasons for retaining the apparent duplicates. A new micro-pass whose only
goal was moving 58 words below the contributor target would itself create more churn without
establishing a clearer owner.

### Option 4: Keep the file and record the ownership decision

**Chosen.** The file is cohesive, below the enforced per-file threshold, already points detailed
mechanism outward, and has no demonstrated conflict cost. A reference-only adjudication closes the
observational ticket without perturbing the contract it measured.

## 4. Canonical ownership boundaries

| Content | Executive owner | Detailed owner |
|---------|-----------------|----------------|
| Merge authorization and human-chat opt-out | `CLAUDE.md` | `cr-merge-gate.md`, `phase-protocols.md`, and `/wrap` own verification and execution |
| Timestamp, output, heartbeat, and monitoring posture | `CLAUDE.md` | `monitor-mode.md` applies the posture; `scheduling-reliability.md` owns primitive selection and liveness |
| Autonomous phase transitions and pipeline refill | `CLAUDE.md` | `subagent-orchestration.md` and `phase-protocols.md` own spawn and completion procedures |
| Session-start sync and worktree prohibition | `CLAUDE.md` | `main-hygiene.md` owns quarantine behavior and recovery handling |
| Issue-to-PR flow and mandatory Test Plan | `CLAUDE.md` | `issue-planning.md` and review rules own the procedural gates |
| Safety routing | `CLAUDE.md` routes the rule corpus | `safety.md`, `repo-bootstrap.md`, and the other safety/hygiene rules own the constraints |
| Rule inventory and corpus budget summary | `CLAUDE.md` | `CONTRIBUTING.md`, `rule-lint.sh`, and `budget-cap-raise-decision.md` own contributor mechanics and rationale |

`CLAUDE.md` may summarize a binding rule when always-loaded visibility is the point. Detailed owners
must not introduce a competing policy, and callers should point to named sections instead of
copying procedures.

## 5. Preserved invariants

- Session start remains guard check, quarantine on a dirty result, fast-forward pull, and isolated
  worktree entry; no work lands directly on `main`.
- Merge remains automatic only after the reviewer gate, CI, resolved threads, and Test Plan pass;
  protection-modifying bypasses remain hard stops.
- Every parent message retains the exact timestamp, heartbeat, output-suppression, recurring
  `Monitor`, and Dedicated Monitor Mode obligations.
- Phase A → B → C autonomy, issue claiming/planning, reviewer escalation, and pipeline refill retain
  their current owners and cross-rule links.
- The rule index stays aligned, the 12,000/13,000 corpus gates stay visible, and the committed
  ratchet cap does not move.
- Safety, skill-first routing, and memory guidance remain loaded exactly as before.

## 6. Remediation and verification

The remediation adds only this decision record and its reference-catalog entry. Verification must
prove:

- no diff under `CLAUDE.md`, `.claude/rules/*.md`, or `.claude/rules/.budget-soft-cap`;
- `reference-catalog-lint.sh` and `rule-lint.sh` pass;
- the hotspot detector tests pass; and
- the full Bash and Python suites remain green.

## 7. Future edits and reconsideration

Future PRs should edit `CLAUDE.md` only when a repository-wide executive obligation changes or its
rule index must change. Mechanism, examples, compatibility notes, and rationale continue to belong
in `.claude/reference/`; specialized procedures continue to belong in their named rule or skill.

Address the 1,300-word contributor target in a scheduled corpus-slimming pass when a safe ownership
cut exists, not through isolated synonym churn. Reconsider splitting only if the file crosses the
enforced per-file threshold, develops independently consumed sections that should not all auto-load,
or accumulates unrelated implementation machinery. Reconsider extraction only when a deterministic
operation appears that agents currently reproduce from prose.

## Related precedent

- `.claude/reference/monitor-mode-hotspot-decision.md` — KEEP + dedup when one concrete downstream
  restatement existed.
- `.claude/reference/session-state-schema-hotspot-decision.md` — KEEP a cohesive contract despite
  frequent feature-driven updates.
- `.claude/reference/fixpr-hotspot-decision.md` — extraction is justified when deterministic command
  forms, rather than executive policy, drive churn.
- `.claude/reference/churn-hotspots.md` — the detector is observational; adjudication decides whether
  a structural remedy exists.
