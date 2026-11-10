# Self-Hosted AI Code Reviewer — Decision Record

Issues: [Issue #1287](https://github.com/auerbachb/claude-code-config/issues/1287), follow-up measurements [Issue #1301](https://github.com/auerbachb/claude-code-config/issues/1301)
Evidence base: [`self-hosted-reviewer-survey-2026-08.md`](./self-hosted-reviewer-survey-2026-08.md) — point-in-time evaluation and endpoint measurements, 2026-08-23–24
Supersedes: the prior `ocr` CUT verdict in [`skill-prune-audit-2026-07.md`](./skill-prune-audit-2026-07.md) §ocr CUT (Issue #793) — this record re-decides on a broader scope and the same conclusion.

**Verdict: no self-hosted reviewer should be adopted at this time. The local pre-push slot remains CodeRabbit CLI + CodeAnt CLI. No change to the review chain.** Issue #1301 materially corrected the PR-Agent capability evidence (`--stdin` local mode exists) and showed that `ocr` can reproduce a real hosted finding on supported files. The adoption decision still stands because `ocr` excludes this repository's dominant Markdown content, while PR-Agent's measured local output had no line anchors or confirmed true positives.

---

## Decision

| Candidate | Role / Verdict | Slot | Cost rationale |
|---|---|---|---|
| `ocr` (alibaba/open-code-review) | **CUT** | n/a | Excludes every `.md` file; 0 of 2 PR #1292 files were reviewable. On the exact reviewed PR #1295 head it cost $0.79, took 85.92 seconds, and emitted 2 line-anchored findings: 1 hosted overlap and 1 non-actionable suggestion. |
| Qodo PR-Agent | **CUT** | n/a | v0.43.0 `--stdin` local mode is confirmed, correcting the original survey. The revision-matched PR #1295 run cost $0.09 and took 14.35 seconds, but emitted 2 summary findings with no line anchors; neither was a confirmed true positive. |
| CodeRabbit CLI (incumbent) | **KEEP** | Local pre-push, primary | OSS pool caps at 3/~55min on this public repo; still the higher-fidelity finder of the two local CLIs. |
| CodeAnt CLI (incumbent) | **KEEP** | Local pre-push, secondary | Daily cap applies; auth restored 2026-08-23; complements CodeRabbit. |

---

## Reasoning

**Why not `ocr` for the local pre-push pass?**

The local pre-push pass is advisory: it never satisfies the merge gate. A weaker reviewer there costs little — this is why Issue #1287 calls it the "low-risk, high-value" slot for a self-hosted trial. The disqualifier is not quality but **coverage**: in a repository whose every PR diff is predominantly `.md` files (reference docs, rule files, skill files), `ocr` produces 0 findings on the large majority of PRs. The extension exclusion is in the binary; there is no CLI flag to override it. A reviewer that sees no files is equivalent to no reviewer at all. Installing it would add maintenance burden with zero benefit.

**Why not `ocr` for a code-heavy slot?**

`ocr`'s benchmark numbers (higher precision than general-purpose agents at ~1/9 token cost, per its own AACR-Bench data) may still be relevant to a code-file-centric repo. Issue #1301 supplied the previously missing local evidence: against the exact PR #1295 head already reviewed by CodeRabbit and CodeAnt, `ocr` ran for 85.92 seconds, consumed 380,400 input and 7,412 output tokens, and cost $0.79. One of its two line-anchored findings directly reproduced CodeAnt's `offered_issue_nums` defect; the other was a non-actionable error-message suggestion. This is a genuine quality signal on supported files, but one run and one overlap do not offset zero coverage of the repository's dominant file type.

**Why not PR-Agent?**

The original decision said PR-Agent required a GitHub PR URL and therefore could not run before a PR existed. **That claim was wrong.** Issue #1301 confirmed that v0.43.0 accepts a unified diff through `--stdin` without a GitHub token. The revision-matched `review` run was fast and inexpensive (14.35 seconds, 15,650 input + 362 output tokens, $0.09), but returned only two summary-level maintainability ideas without file/line anchors. Neither reproduced one of the five hosted findings on that head or identified a current defect. PR-Agent therefore clears the transport/capability bar but not the measured usefulness bar for the line-level local-review slot.

**Why not adopt either tool as a fallback tier?**

The merge-gate fallback tier (BugBot → Greptile) requires that a tool can satisfy the gate via its approval signal. Neither `ocr` nor PR-Agent posts a GitHub APPROVED review object in the measured local mode. Adding either as a gate-satisfying tier would require a shim; that complexity is not warranted by the measured finding quality.

---

## Promotion bar

A self-hosted reviewer should be reconsidered when **all three** conditions hold:

1. At least 10% of PRs in the 30-day window contain non-`.md` files. Measure: for each merged PR in the window, run `gh pr diff <N> --name-only | grep -v '\.md$'`; count PRs where this returns at least one file. The threshold is: (qualifying PRs) / (total PRs in window) ≥ 0.10.
2. At least 3 completed runs on real non-`.md` diffs produce file/line-anchored findings in the mode intended for the local slot. Issue #1301 supplies one such `ocr` run and zero PR-Agent runs with anchors.
3. At least one finding is validated as a true positive and overlaps a CodeRabbit or CodeAnt finding on the same diff. **Issue #1301 satisfies this condition for `ocr`** with the revision-matched `offered_issue_nums` finding; PR-Agent has not satisfied it.

Until all three hold, the verdict is **no change**.

---

## Rejected options

| Option | Why rejected |
|---|---|
| `ocr` with custom rule config to include `.md` | No such override flag exists in v1.9.10; the extension filter is binary-internal |
| `ocr` delegation mode as a workaround | Delegation mode applies the same extension filter; 0 reviewable files is unchanged |
| PR-Agent `--stdin` local mode | Capability confirmed, but the measured `review` output had no line anchors and 0 confirmed true positives |
| Building a custom wrapper around ocr + local LLM | Maintenance burden without quality evidence; revisit if promotion bar is met |
| Adding PR-Agent as a GitHub App | Out of scope for this survey (Issue #1287 scopes to CLI-reachable tools for the local pre-push slot) |

---

## Prior `ocr` CUT verdict reconciliation

Issue #793 / PR #822 CUT `ocr` on two grounds:
1. `.md` exclusion — **still holds in v1.9.10**; confirmed via `ocr delegate preview` on PR #1292 commit
2. No Anthropic credential available — **resolved by Issue #1301 later on 2026-08-23**; a completed endpoint run replaced the earlier error-only evidence

The prior `ocr` verdict remains confirmed on ground 1; ground 2 was an environmental blocker, not a lasting reason to CUT, and is now closed with measured evidence. The current decision record supersedes §ocr CUT in `skill-prune-audit-2026-07.md` and extends the scope to include PR-Agent. Resurrection path: `git log -- .claude/skills/open-code-review/SKILL.md` shows the removal commit; `git show <SHA>:.claude/skills/open-code-review/SKILL.md` retrieves the skill content to restore it if conditions at the promotion bar above are ever met.

---

## Break-even analysis

For the local pre-push slot, the break-even question is: at what cost is a self-hosted reviewer cheaper than the incumbent CLIs?

**Current incumbent cost (local pass only):**
- CodeRabbit CLI: Pro seat cost is shared with the GitHub App; no marginal cost for CLI use within the OSS pool
- CodeAnt CLI: Premium seat cost is shared with the GitHub App; no marginal cost for CLI use within the daily cap

**Measured self-hosted runs against Claude Opus 4.5:**
- `ocr`: **$0.79/review** on PR #1295 (68 uncached input, 71,557 cache-write, 308,775 cache-read, and 7,412 output tokens). At 50 reviews/month: **$39.36/month** at the measured workload shape.
- PR-Agent: **$0.09/review** on the same diff (15,650 input + 362 output tokens). At 50 reviews/month: **$4.37/month** at the measured workload shape.
- Break-even vs incumbent: **immediately cheaper than incumbents if the incumbents' seats were removed** — but the seats exist for the GitHub App reviews, so the CLI use is a free rider on existing spend

**Conclusion:** The break-even analysis does not motivate adoption. For `ocr`, Markdown coverage is the binding constraint; for PR-Agent, measured finding precision and lack of line anchors are binding. Both add positive marginal endpoint cost while the incumbent CLI calls ride on seats already retained for GitHub App reviews.

---

## Sources

| Source | Retrieval date | What it provides |
|---|---|---|
| `npm info @alibaba-group/open-code-review` | 2026-08-23 | Version, license, install name |
| `ocr --version` | 2026-08-23 | Confirmed v1.9.10 |
| `ocr delegate preview --from <SHA>^ --to <SHA>` | 2026-08-23 | Extension exclusion on PR #1292 |
| `ocr rules check .claude/reference/ai-review-chain-roles-decision.md` | 2026-08-23 | Rule exists but is overridden by extension filter |
| `pip3 index versions pr-agent` | 2026-08-23 | Package name and latest version |
| `python3 -m pr_agent.cli --help` | 2026-08-23 | PR-Agent interface shape |
| GitHub API `pulls/1292/comments` | 2026-08-23 | CodeRabbit inline findings baseline |
| GitHub API `pulls/1292/reviews` | 2026-08-23 | CodeAnt approval baseline |
| `skill-prune-audit-2026-07.md` §ocr CUT | 2026-07-30 | Prior verdict to reconcile |
| Issue #1301 raw `ocr` and PR-Agent stdout (captured in survey §7) | 2026-08-24 | Revision-matched completed runs, wall time, token usage, findings, and model |
| [Anthropic Claude Platform pricing](https://platform.claude.com/docs/en/about-claude/pricing) | 2026-08-24 | Opus 4.5 base input, cache-write, cache-read, and output rates used for cost calculations |
