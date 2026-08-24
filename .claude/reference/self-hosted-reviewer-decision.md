# Self-Hosted AI Code Reviewer — Decision Record

Issue: [#1287](https://github.com/auerbachb/claude-code-config/issues/1287)
Evidence base: [`self-hosted-reviewer-survey-2026-08.md`](./self-hosted-reviewer-survey-2026-08.md) — point-in-time evaluation, 2026-08-23
Supersedes: the prior `ocr` CUT verdict in [`skill-prune-audit-2026-07.md`](./skill-prune-audit-2026-07.md) §ocr CUT (Issue #793) — this record re-decides on a broader scope and the same conclusion.

**Verdict: no self-hosted reviewer should be adopted at this time. The local pre-push slot remains CodeRabbit CLI + CodeAnt CLI. No change to the review chain.**

---

## Decision

| Candidate | Role / Verdict | Slot | Cost rationale |
|---|---|---|---|
| `ocr` (alibaba/open-code-review) | **CUT** | n/a | In this repo, `ocr` excludes every `.md` file; 0 of 2 PR #1292 files were reviewable. The cost-per-review model (own LLM endpoint) is sound in principle, but the coverage is zero in practice for this doc/config repo. |
| Qodo PR-Agent | **CUT** | n/a | No local diff mode. Designed for GitHub PR review with a configured LLM + GitHub token. Does not fit the local pre-push slot. |
| CodeRabbit CLI (incumbent) | **KEEP** | Local pre-push, primary | OSS pool caps at 3/~55min on this public repo; still the higher-fidelity finder of the two local CLIs. |
| CodeAnt CLI (incumbent) | **KEEP** | Local pre-push, secondary | Daily cap applies; auth restored 2026-08-23; complements CodeRabbit. |

---

## Reasoning

**Why not `ocr` for the local pre-push pass?**

The local pre-push pass is advisory: it never satisfies the merge gate. A weaker reviewer there costs little — this is why Issue #1287 calls it the "low-risk, high-value" slot for a self-hosted trial. The disqualifier is not quality but **coverage**: in a repository whose every PR diff is predominantly `.md` files (reference docs, rule files, skill files), `ocr` produces 0 findings on the large majority of PRs. The extension exclusion is in the binary; there is no CLI flag to override it. A reviewer that sees no files is equivalent to no reviewer at all. Installing it would add maintenance burden with zero benefit.

**Why not `ocr` for a code-heavy slot?**

`ocr`'s benchmark numbers (higher precision than general-purpose agents at ~1/9 token cost, per its own AACR-Bench data) are plausible for a code-file-centric repo. If this repo's diff profile shifts toward `.sh`, `.go`, `.py`, or `.json` files, `ocr` should be re-evaluated. The evidence for or against finding quality on code files was not collected in this session (no API key).

**Why not PR-Agent?**

PR-Agent is designed as a drop-in for the GitHub review loop (commenting on open PRs), not for local pre-push diff review. Running it locally requires a GitHub PR URL, a GitHub API token, and an LLM key — the same dependencies as posting to GitHub. It does not fit the pre-push slot, which runs before a PR exists.

**Why not adopt either tool as a fallback tier?**

The merge-gate fallback tier (BugBot → Greptile) requires that a tool can satisfy the gate via its approval signal. Neither `ocr` nor PR-Agent posts a GitHub APPROVED review object. Adding either as a gate-satisfying tier would require a shim; that complexity is not warranted by the finding quality evidence available (none for this repo type).

---

## Promotion bar

A self-hosted reviewer should be reconsidered when **all three** conditions hold:

1. At least 10% of PRs in the 30-day window contain non-`.md` files. Measure: for each merged PR in the window, run `gh pr diff <N> --name-only | grep -v '\.md$'`; count PRs where this returns at least one file. The threshold is: (qualifying PRs) / (total PRs in window) ≥ 0.10.
2. A session with `ANTHROPIC_API_KEY` configured is available to run `ocr review --from <base> --to <head> --format json` on at least 3 real diffs with non-`.md` content
3. Measured findings from step 2 overlap with at least 1 CodeRabbit or CodeAnt finding in the same PR (quality signal)

Until all three hold, the verdict is **no change**.

---

## Rejected options

| Option | Why rejected |
|---|---|
| `ocr` with custom rule config to include `.md` | No such override flag exists in v1.9.10; the extension filter is binary-internal |
| `ocr` delegation mode as a workaround | Delegation mode applies the same extension filter; 0 reviewable files is unchanged |
| PR-Agent local mode | PR-Agent has no local diff mode; it requires a GitHub PR URL |
| Building a custom wrapper around ocr + local LLM | Maintenance burden without quality evidence; revisit if promotion bar is met |
| Adding PR-Agent as a GitHub App | Out of scope for this survey (Issue #1287 scopes to CLI-reachable tools for the local pre-push slot) |

---

## Prior `ocr` CUT verdict reconciliation

Issue #793 / PR #822 CUT `ocr` on two grounds:
1. `.md` exclusion — **still holds in v1.9.10**; confirmed via `ocr delegate preview` on PR #1292 commit
2. No Anthropic credential available — **still true in the 2026-08-23 session**; error confirmed via `ocr review` exit message

The prior verdict is confirmed on both grounds by this survey. The current decision record supersedes §ocr CUT in `skill-prune-audit-2026-07.md` and extends the scope to include PR-Agent. Resurrection path: `git log -- .claude/skills/open-code-review/SKILL.md` shows the removal commit; `git show <SHA>:.claude/skills/open-code-review/SKILL.md` retrieves the skill content to restore it if conditions at the promotion bar above are ever met.

---

## Break-even analysis

For the local pre-push slot, the break-even question is: at what cost is a self-hosted reviewer cheaper than the incumbent CLIs?

**Current incumbent cost (local pass only):**
- CodeRabbit CLI: Pro seat cost is shared with the GitHub App; no marginal cost for CLI use within the OSS pool
- CodeAnt CLI: Premium seat cost is shared with the GitHub App; no marginal cost for CLI use within the daily cap

**Self-hosted (`ocr` against claude-sonnet-4-6 at $3/M input + $15/M output):**
- Approximate token usage per review: ~50k input + ~3k output tokens (per ocr's ~1/9 token claim relative to general-purpose agents processing a ~450k-token diff)
- Cost per review: (50k × $3/1M) + (3k × $15/1M) ≈ **$0.15–0.20/review**
- At 50 PRs/month (historical rate): ≈ $7.50–$10/month
- Break-even vs incumbent: **immediately cheaper than incumbents if the incumbents' seats were removed** — but the seats exist for the GitHub App reviews, so the CLI use is a free rider on existing spend

**Conclusion:** The break-even analysis does not motivate adoption. The `.md` coverage gap is the binding constraint, not cost.

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
