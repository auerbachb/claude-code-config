# Budget Cap Raise Decision (#879)

## Decision

**The ratchet cap is a visibility mechanism, not the budget ceiling.** It remains a **blocking CI check**: `.claude/rules/.budget-soft-cap` continues to hold `max(count + 750, 8500)` and `rule-lint.sh` continues to fail when the corpus exceeds it. "Not the gate" describes its *role*, not its severity — the blocking is what forces every increment to appear as a deliberate, reviewable line in a diff, while the absolute budget it is not allowed to raise past lives in the 12,000/13,000 limits below. What changes is when raising it is legitimate:

- **Raising the cap is permitted when it accommodates a justified addition.** The raise requires an explicit **PR-body justification line** naming what was added and why it belongs in the auto-loaded corpus rather than in `.claude/reference/`. No accompanying cuts are required.
- **The 12,000-word soft warning and 13,000-word hard fail are the actual gate.** They are absolute: no justification line raises them, and `rule-lint.sh` errors above 13,000 regardless of the cap.
- **`--update-cap` still only lowers or holds.** The one-way ratchet is unchanged, so a cap raise never happens as a side effect of running the tool.
- **The justification line is a review-time convention, not a CI check.** No workflow reads PR-body text today, and adding that infrastructure is out of proportion to the problem. Reviewers and the merge gate enforce it.

Prior wording in `CLAUDE.md` — "`--update-cap` only after intentional cuts" — is superseded by this record.

### How a raise is actually performed (`config-protection.py`)

**An agent cannot hand-edit the cap.** `.claude/rules/.budget-soft-cap` and `.github/scripts/rule-lint.sh` are both in `PROTECTED_RELATIVE_SUFFIXES` in `.claude/hooks/config-protection.py`, which blocks every Write/Edit/Bash modification of either one. That guard is deliberate and stays — it is what stops a reflexive "raise the number until CI goes green," which this decision does **not** authorize. Permitted-with-justification is not permitted-on-impulse.

Two paths remain, and they cover the cases that matter:

1. **`bash .github/scripts/rule-lint.sh --update-cap --allow-raise`** — the sanctioned in-repo escape hatch (#832). It writes the formula value `count + 750` and prints `old → new (+delta) [--allow-raise]`, so the raise is audited in CI output as well as in the diff. Use this when the formula value is the value you want.

   To be precise about why this works: `config-protection.py` inspects the **tool call**, not a script's internal file writes, so *no* `rule-lint.sh` invocation is intercepted — there is no argument-aware allowlist, and `--allow-raise` is not specially blessed. What the hook actually blocks is a hand-edit of the cap file. The practical effect is still the wanted one — a cap change that goes through the tool is the one that prints its own delta — but do not read the hook as enforcing that.
2. **An owner edit of `.claude/rules/.budget-soft-cap`** — required when the cap must land on a *specific* number rather than `count + 750`. A human keystroke is the accountability mechanism here, and it is a stronger one than a PR-body line.

Either way the PR-body justification line is still required.

### Pending owner action: align the cap to 12,000

The owner's decision comment on #879 called for a first deliberate application — raising the cap `11749 → 12000` so the ratchet sits exactly on the soft-warning limit, rather than drifting above it where a corpus could cross 12,000 with only a warning. `--allow-raise` cannot produce that number (`count + 750` was ~12,470 here, *above* the soft warning and so self-defeating), and path 2 is an owner action, so **the PR that implemented this decision did not raise the cap**. It did not need to: its `CLAUDE.md` amendment was funded by restatement cuts in the same file, leaving the corpus slightly *below* where it started.

The raise remains worth doing on its own merits, as a one-line owner edit:

```bash
printf '%s' 12000 > .claude/rules/.budget-soft-cap   # run outside a Claude session; the hook blocks agents
```

Once it lands, headroom between the cap and the hard fail is 1,000 words, and any future raise runs out of room at 13,000 — where no justification line helps. That is the gate the ratchet is deliberately not.

## Rationale

**The ratchet is a rolling window, not a ceiling.** Because the formula is `count + 750`, every legitimate raise permanently enlarges the corpus that loads into every session. Raising freely defeats the purpose. But `main` sat at 11,732 words against a cap of 11,749 when #879 was filed — under a cuts-only rule, *no* rule addition could land until someone first cut unrelated rules. That makes the corpus effectively immutable and couples every rules change to an unrelated slimming pass.

**A guard that blocks all forward progress gets bypassed.** PR #739 and PR #736 both raised the cap to accommodate an addition with no accompanying cuts, and PR #787's Phase B agent proposed the same. Written rule and practice had already diverged twice before the tension became load-bearing. A rule nobody follows is worse than a weaker rule everyone follows — the honest fix is to write down the rule that is actually being applied, and attach the accountability (a named justification) that makes it defensible.

**Two numbers with clear roles beat one number doing two jobs.** The 12,000/13,000 limits answer "is the corpus too expensive?" — a question about absolute cost, paid on every turn. The ratchet answers "did this PR grow the corpus, and did anyone notice?" — a question about visibility. Collapsing them into a single hard ceiling loses the second signal; dropping the ratchet to a warning loses the first enforcement point. Keeping both, with distinct roles, is what the ticket recommended and what the owner adopted.

**Why the ratchet stays an error rather than becoming a warning.** CodeRabbit's plan for this issue proposed converting the ratchet-cap breach in `rule-lint.sh` from `::error` to `::warning`. That was declined: a warning is not visible in a diff and does not require anyone to act, so the visibility the ratchet exists to provide would be delivered by a line of CI output nobody has to read. Keeping the error means a raise is a committed file change with a justification attached — exactly the accountability that distinguishes this decision from "growth is free". The `.github/scripts/tests/rule-lint.test.sh` case `(h)` pins the hard-fail behavior so a future edit cannot silently soften it back.

**Resolved stale string.** The breach message in `rule-lint.sh` now points readers to this decision record instead of repeating the superseded cuts-only rule. The same phrase in `instruction-set-audit-2026-07.md` is deliberately left alone: that file is a point-in-time audit, exempt from corpus-wide rewrites per `.claude/reference/README.md`.

## Explicitly Rejected

- **Option 1 — enforce the written rule as-is** (every addition paid for by cuts in the same PR). Rejected: it couples unrelated changes, makes #796's weekly slimming pass a hard prerequisite for all rules work, and is the rule that practice had already routed around three times. It also produces a perverse incentive to cut whatever is cheapest to cut rather than whatever is least valuable.
- **Option 4 — route additions to `.claude/reference/` by default**, treating any auto-loaded growth as needing owner sign-off. Rejected: it turns every rules PR into a judgment call escalated to one person, and the "does this belong in the corpus?" question is already answered — as a written justification — under Option 2's line. `CLAUDE.md`'s standing "Keep growth out of the corpus" guidance already applies the same pressure without the sign-off bottleneck.
- **A CI check that greps the PR body for the justification line.** Rejected: no existing workflow reads PR-body text, so this is net-new infrastructure for a convention the merge gate already covers at review time. Revisit only if the convention is observably skipped.
- **Raising the cap via `--update-cap --allow-raise` in the implementing PR**, as a substitute for the 12,000 the owner asked for. Rejected: `count + 750` was ~12,470 at the time, which puts the ratchet *above* the 12,000 soft warning and hands back the drift the alignment was meant to remove. A number that defeats the reason for the change is not a close-enough version of it.
- **Removing `.claude/rules/.budget-soft-cap` from `config-protection.py` so agents could perform the raise directly.** Rejected: it deletes a live guard to save one owner keystroke, in a PR authored by the very agent the guard constrains — and the two sanctioned paths above already cover both the formula case and the specific-number case. Revisit only if cap raises become frequent enough that the owner keystroke is the actual bottleneck.

## Retroactive: PR #787

PR #787 (issue #785, the `rm`-of-verified-untracked-files exception) is where this tension surfaced: its Phase B agent raised the cap `11749 → 12537` to fit a ~66-word `safety.md` addition, and the parent rejected the raise and sent it back to pay with cuts. It merged that way on 2026-08-01, funding the addition from `cr-github-review.md`, `cr-merge-gate.md`, `scheduling-reliability.md`, and `skill-first.md`.

**That resolution is consistent with this decision and needs no retroactive change.** Paying with cuts is permitted under every option considered — the decision widens the set of legitimate paths, it does not narrow it. What changes going forward is that #787 would no longer have been *required* to cut: a justification line naming the `rm` exception and why a safety prohibition belongs in the auto-loaded corpus would have sufficed. The cap raise it originally proposed was rejected on process grounds (a written rule the owner authored should not be silently overridden), not on the merits — and #879 is the process that resolves it.

## References

- Issue [#879](https://github.com/auerbachb/claude-code-config/issues/879) — this decision; owner-delegated verdict recorded as an issue comment (Option 3 + Option 2's justification line)
- PR [#787](https://github.com/auerbachb/claude-code-config/pull/787) / Issue [#785](https://github.com/auerbachb/claude-code-config/issues/785) — where the tension surfaced; see the retroactive note above
- PR [#739](https://github.com/auerbachb/claude-code-config/pull/739), PR [#736](https://github.com/auerbachb/claude-code-config/pull/736) — prior cap raises without cuts, the practice this decision legitimizes and puts a justification behind
- Issue [#796](https://github.com/auerbachb/claude-code-config/issues/796) — weekly rule-corpus slimming pass; the pressure-relief valve that keeps raises rare rather than routine
- Issue [#832](https://github.com/auerbachb/claude-code-config/issues/832) — the one-way ratchet and `--allow-raise` escape hatch this decision leaves mechanically unchanged
- `CLAUDE.md` "Rule File Size Guidelines" — the amended wording this record backs
- `CONTRIBUTING.md` "Adding a New Rule" — the contributor-facing statement of the same policy
- `.github/scripts/rule-lint.sh` — enforcement: soft/hard limits, ratchet-cap error, `--update-cap` / `--allow-raise` mechanics
- `.github/scripts/tests/rule-lint.test.sh` case `(h)` — regression guard pinning the ratchet breach as a hard fail
- `.claude/rules/.budget-soft-cap` — the committed cap; edit directly to raise, with a PR-body justification line
- `chip-model-guard-decision.md`, `pm-handoff-chips-decision.md` — the house style this record follows (`## Decision` / `## Rationale` / `## Explicitly Rejected` / `## References`)
