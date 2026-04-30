# AI Review Tool Audit - 2026-04

Issue: [#368](https://github.com/auerbachb/claude-code-config/issues/368)

Date reviewed: 2026-04-28

## Executive summary

This repository has one in-repo AI review configuration today: `.coderabbit.yaml`.
The remaining tools are configured through vendor dashboards or GitHub apps, and
no repo-local config was found for codeant.ai, BugBot, Vercel Agent, Greptile, or
Graphite.

No safe no-tradeoff config change was identified in this audit.

Changes intentionally not applied:

- Raising CodeRabbit's token-footprint threshold from 10,000 to 14,000 words.
  The repo currently treats 10,000 words as the soft budget and 14,000 words as
  a transitional hard limit, so raising the CodeRabbit threshold would remove
  early-warning coverage and has a real tradeoff.
- Dashboard settings for codeant.ai, BugBot, Vercel Agent, Greptile, and
  Graphite. These affect spend, reviewer noise, automation scope, or external
  app behavior and should be reviewed by the user before activation.
- New repo-local configs for tools that do not currently have committed config.
  Adding them would implicitly opt in to new review behavior without a validated
  first-month signal baseline.

Recommended default chain for the next month:

1. CodeRabbit: primary local and GitHub reviewer.
2. BugBot: second-tier fallback and independent clean-review gate.
3. codeant.ai: parallel security/code-health observer during the trial month;
   do not make it merge-blocking until true-positive rate is measured.
4. Vercel Agent: only for Vercel-connected app repos or PRs with Vercel runtime,
   deployment, or performance implications.
5. Graphite Agent: keep disabled/non-blocking until the GitHub app is actually
   posting reviews.
6. Greptile: last-resort paid fallback only. Keep auto-review disabled.

## Current reviewer chain placement

Current repo rules define the merge-gate review chain as:

`CodeRabbit -> BugBot -> Greptile -> self-review`

Only three tools currently participate in the formal merge gate:

- CodeRabbit: primary path; requires one explicit `APPROVED` review on current
  HEAD.
- BugBot: fallback path; one clean BugBot pass on current HEAD satisfies the
  gate when BugBot owns the PR.
- Greptile: last-resort path; severity-gated pass after CodeRabbit and BugBot
  fail.

codeant.ai, Vercel Agent, and Graphite were not in `cr-merge-gate.md` at audit time. **Update (#367):** CodeAnt is now encoded on the CR path in `cr-merge-gate.md` and `merge-gate.sh` when it has participated on the current SHA; Graphite remains supplemental until it posts reliably.

## Tool: CodeRabbit

### Current config

Repo-local config: `.coderabbit.yaml`.

- Review profile: `assertive`.
- Path instructions:
  - `**/*`: review this repo as Claude Code configuration, emphasizing clarity,
    workflow correctness, consistency, and token efficiency.
  - `CLAUDE.md`: enforce structural review criteria for token footprint,
    hierarchy, redundancy, and density.
  - `.claude/rules/**/*.md`: same structural review criteria for rule files.
- Knowledge base code guidelines:
  - enabled for `CLAUDE.md`
  - enabled for `.claude/rules/**/*.md`
- GitHub workflow: `.github/workflows/cr-plan-on-issue.yml` auto-comments
  `@coderabbitai plan` on newly opened non-bot issues.
- Local workflow: `.claude/rules/cr-local-review.md` requires
  `coderabbit review --prompt-only` before push when the CLI is available.
- GitHub workflow: `.claude/rules/cr-github-review.md` polls CodeRabbit after
  push and requires current-HEAD approval for the CR merge path.

### Max-config recommendations

Flag for user review before applying:

- Decide whether to keep CodeRabbit's token-footprint threshold at the
  10,000-word soft budget or raise it to the temporary 14,000-word hard limit.
  Recommendation: keep 10,000 for early-warning coverage until the rule set is
  condensed below the soft budget. Tradeoff: a 10,000-word threshold can produce
  more review noise while the repo is intentionally above the soft budget; a
  14,000-word threshold would miss drift until the hard limit is nearly failing.
- Enable or tune CodeRabbit pre-merge checks. Useful candidates:
  - PR title and description checks aligned to issue linkage and Test Plan
    requirements.
  - Custom pre-merge checks for "every PR links an issue", "Test plan is
    present", and "no rule-file budget overflow".
  Tradeoff: more blocking comments and potential false positives on docs-only or
  maintenance PRs.
- Decide whether `reviews.request_changes_workflow` should remain off.
  Enabling it would let CodeRabbit formally request changes for failures.
  Tradeoff: stricter GitHub gating and more bot-authored blocking state.
- Decide whether to explicitly configure `reviews.auto_review.drafts`.
  Draft reviews give earlier feedback but spend review quota on WIP PRs.
- Consider custom finishing-touch recipes for repo-maintenance tasks such as
  "condense rule-file text" or "normalize rule index".
  Tradeoff: CodeRabbit agent actions can introduce churn; keep manual until
  trust is measured.
- Review CodeRabbit learnings in the dashboard and prune stale/conflicting
  preferences. Keep `knowledge_base.code_guidelines` enabled.

### Unused or underused features

- Learnings management and learning scope review.
- Pre-merge checks and custom pre-merge checks.
- Finishing touches: docstrings, unit tests, simplify, custom recipes.
- Built-in linters/SAST integrations. Many are enabled by default, but this repo
  is mostly markdown/shell/yaml, so the meaningful ones are markdownlint,
  actionlint, ShellCheck, YAMLlint, secret scanning, and LanguageTool.
- Linked repository analysis. Probably low value for this repo unless shared
  workflows/rules are split across multiple repositories.
- CodeRabbit Plan / issue planning is active through issue comments, but the
  failed plan on #368 shows it needs reliability monitoring.

### Monthly cost

Official pricing reviewed 2026-04-28:

- Free: PR summarization only; code reviews through IDE/CLI with lower limits.
- Pro: $24/developer/month billed annually, or $30 month-to-month.
- Pro+: $48/developer/month billed annually, or $60 month-to-month.
- Rate limits per developer: Pro 5 PR reviews/hour, Pro+ 10 PR reviews/hour.
- Usage-based add-on is available for Pro, Pro+, and Enterprise.

Source: <https://docs.coderabbit.ai/management/plans>

### Chain placement

Primary reviewer. Local CodeRabbit CLI is the first review loop before push.
GitHub CodeRabbit is the primary merge-gate path after push.

## Tool: codeant.ai

### Current config

Repo-local config: none found.

Observed issue context says codeant.ai is newly active and auto-commenting.
Configuration is therefore presumed to live in the CodeAnt dashboard/GitHub app,
not in this repository.

### Max-config recommendations

Flag for user review before applying:

- Scope codeant.ai to this repo and verify it is reviewing PRs on every update,
  not only manually triggered reviews.
- Enable PR review dashboards for this repo so the 30-day follow-up can collect:
  findings count, accepted/fixed count, false-positive count, and unique
  findings not also caught by CodeRabbit/BugBot.
- Enable SAST on pull requests and keep it advisory during the first month.
  Tradeoff: security scanners can produce noise in a markdown/config repo.
- Define custom rules for this repo:
  - no linter suppression comments unless explained
  - every workflow PR keeps issue linkage and Test Plan checkboxes
  - rule-file changes must respect the word budget
  - no secrets in docs, examples, or shell snippets
  Tradeoff: org-wide custom rules may affect other repositories if scoped
  incorrectly.
- Enable CI/CD integration only after measuring noise. If enabled, start with
  non-blocking checks.

### Unused or underused features

- Custom AI review rules.
- Static Analysis and SAST on pull requests.
- Secret scanning and unified security/code-health dashboard.
- CLI/IDE integrations for local checks.
- Developer metrics and PR analytics.
- Jira/Azure Boards integrations.
- Compliance reports and Scan Center dashboard.

### Monthly cost

Official pricing reviewed 2026-04-28:

- Free trial: 14 days, 100 PR reviews included, all premium features unlocked.
- Premium: $24/user/month with unlimited PR reviews, AI review dashboards,
  Static Analysis and SAST on PRs, Jira/Azure Boards integrations, CI/CD
  integration, Slack support, onboarding, and SOC2/HIPAA/VAPT reports.
- Enterprise: custom pricing.
- Open source: advertised as 100% off.

Source: <https://www.codeant.ai/pricing>

### Chain placement

Not in the merge-gate chain today. Recommended placement for the next month:
parallel advisory reviewer after CodeRabbit/BugBot, with findings processed when
valid but not used as the blocking merge gate until signal quality is measured.

## Tool: BugBot (Cursor)

### Current config

Repo-local config: none found.

Current repo rules define BugBot as:

- Bot username: `cursor[bot]`.
- Auto-trigger: on every push and PR open.
- Manual trigger: `@cursor review`.
- GitHub check-run: `Cursor Bugbot`.
- Reply format: plain text, no `@cursor` mention in replies.
- Merge gate: one clean BugBot pass on current HEAD satisfies the gate when
  BugBot is the active reviewer.

Dashboard/project-rule status is external and should be checked in Cursor's
BugBot dashboard. No `.cursor/BUGBOT.md` file exists in this repo.

### Max-config recommendations

Flag for user review before applying:

- Add repo-local `.cursor/BUGBOT.md` with this repository's core review
  expectations:
  - treat files as agent workflow configuration, not application code
  - flag stale docs/rule contradictions
  - enforce no linter suppression comments
  - enforce issue/PR/Test Plan workflow expectations
  Tradeoff: another always-loaded rule surface can drift from `CLAUDE.md` if not
  kept concise.
- In the BugBot dashboard, ensure this repository is enabled and not set to
  "only when mentioned" or "only once per PR" unless spend/noise requires it.
- Enable learned rules for the repository after confirming the learning source
  is high-signal. Use `@cursor remember ...` sparingly.
- Set team/repository manual rules scoped to `.claude/rules/**`, `.claude/skills/**`,
  `.claude/scripts/**`, and `.github/workflows/**`.
- Keep BugBot Autofix off for this repo until it has a measured true-positive
  baseline. Tradeoff: autofix can push to PR branches and create loops.
- If BugBot Pro is enabled, set a monthly seat cap in the dashboard.

### Unused or underused features

- Team rules and repository rules.
- Project rules via `.cursor/BUGBOT.md`.
- Learned rules and rule analytics.
- Autofix via Cursor Cloud Agent.
- MCP support on Team/Enterprise plans.
- Admin Configuration API for repository/user provisioning.
- Verbose troubleshooting trigger for request IDs.

### Monthly cost

Official pricing reviewed 2026-04-28:

- Free tier: limited monthly PR reviews per user on Cursor Teams and Individual
  plans.
- Individual Pro flat rate: $40/month for up to 200 PRs/month across all repos.
- Team Pro: $40/user/month for PR authors reviewed by BugBot that month.
- Abuse guardrail: pooled cap of 200 PRs/month per BugBot license, with
  increases available through support.
- Autofix uses Cloud Agent credits and requires usage-based pricing plus
  storage enabled.

Source: <https://cursor.com/docs/bugbot>

### Chain placement

Second-tier reviewer. Current rules use BugBot after CodeRabbit fails or times
out and before Greptile. A clean BugBot pass on current HEAD satisfies the merge
gate for the BugBot path.

## Tool: Vercel Agent Code Review

### Current config

Repo-local config: none found.

No Vercel project files or Vercel-specific repo config were found in this repo.
Vercel Agent configuration lives in the Vercel dashboard and applies to
repositories connected to Vercel projects.

### Max-config recommendations

Flag for user review before applying:

- Keep Vercel Agent enabled only for repositories connected to Vercel projects,
  or only when PRs touch Vercel runtime/deployment/performance concerns.
  Tradeoff: broad automatic review spends credits on non-Vercel config changes.
- In the Vercel dashboard, set repository scope deliberately:
  - All repositories only if every connected repo is a Vercel app.
  - Choose Public-only or Private-only if the app split maps to value.
- Keep draft PR review disabled unless early Vercel-specific feedback is worth
  credit spend.
- Configure auto-recharge with a monthly spending limit if Agent is enabled.
- Track per-review cost, file count, suggestion count, and review time during
  the 30-day follow-up.

### Unused or underused features

- Validated patch generation in Vercel secure sandboxes.
- Running builds/tests/linters before surfacing suggestions.
- `@vercel` interactive PR comments, including `@vercel run a review`,
  `@vercel fix the type errors`, and `@vercel why is this failing?`.
- Automatic guideline detection from `CLAUDE.md`, `.cursorrules`, `.cursor/rules`,
  `AGENTS.md`, and related files.
- Agent cost/spend dashboards and CSV-style review metrics.
- Auto-reload with monthly spending limits.

### Monthly cost

Official pricing reviewed 2026-04-28:

- $0.30 fixed per Code Review or additional investigation.
- Plus pass-through token costs at the underlying AI provider rate, with no
  Vercel markup.
- Pro teams can redeem a one-time $100 promotional credit for two weeks when
  enabling Agent.
- No separate seat license for Agent reviews; available on Pro and Enterprise.

Sources:

- <https://vercel.com/docs/agent/pricing>
- <https://vercel.com/docs/agent/pr-review>

### Chain placement

Not in the merge-gate chain today. Recommended placement: Vercel-specific
advisory reviewer only. It should not replace CodeRabbit/BugBot/Greptile for
this repo because this repository is agent configuration, not a Vercel app.

## Tool: Greptile

### Current config

Repo-local config: none found (`greptile.json` / `.greptile.json` absent).

Current repo rules define Greptile as:

- Bot username: `greptile-apps[bot]`.
- Trigger: comment `@greptileai`.
- Auto-trigger: off through dashboard filter documented in
  `.claude/reference/greptile-setup.md`.
- Dashboard filter: Labels includes `greptile`, which this workflow never adds.
- Automatically trigger on new commits: off.
- Review draft PRs: off.
- File change limit: 100.
- Excluded authors: `dependabot[bot]`, `renovate[bot]`.
- Daily budget: tracked through `~/.claude/session-state.json` and enforced via
  `.claude/scripts/greptile-budget.sh`.
- Re-review policy: only re-trigger for P0 findings after initial Greptile
  review.

### Max-config recommendations

No repo-local change applied. Current last-resort posture is correct for the
cost concern.

Flag for user review before applying:

- Add root `greptile.json` only if dashboard settings need source-control backup.
  Candidate minimal config:

  ```json
  {
    "excludeAuthors": ["dependabot[bot]", "renovate[bot]"]
  }
  ```

  Tradeoff: repo config may diverge from dashboard filters and can imply broader
  review behavior if future fields are added casually.
- In the dashboard, confirm auto-review remains effectively disabled:
  - label include filter stays `greptile`
  - auto-review on new commits remains off
  - draft PR review remains off
- Lower the default daily budget from 40 reviews/day unless there is evidence it
  is needed. At $1 per overage review, 40/day is too high for a last-resort-only
  fallback if the monthly included quota is already exhausted.
- Use thumbs-up/thumbs-down reactions consistently on Greptile findings during
  the measurement month because reactions are its feedback/training mechanism.

### Unused or underused features

- Custom context and learnings.
- Greptile MCP.
- Root `greptile.json` for committed author exclusions.
- Dashboard usage and billing reports.
- Feedback reactions on every valid/invalid finding.
- Enterprise controls such as SSO/SAML, self-hosting, dedicated Slack, GitHub
  Enterprise, and custom DPA if needed later.

### Monthly cost

Official pricing reviewed 2026-04-28:

- Cloud: $30/active developer/month.
- Includes 50 completed code reviews per active developer.
- Additional completed reviews: $1/review.
- Billing is per active PR author with at least one completed Greptile review in
  the billing period.
- Overages are per-author, not pooled across the team.

Sources:

- <https://www.greptile.com/pricing>
- <https://greptile.mintlify.dev/docs/code-review-bot/billing-seats>

### Chain placement

Last-resort paid fallback after CodeRabbit and BugBot both fail. Once Greptile
is triggered for a PR, current rules make it sticky for that PR.

### Greptile-specific value assessment

Current hypothesis: Greptile is likely poor value as a routine reviewer for this
repo, but still useful as emergency fallback insurance.

Reasons:

- It costs more than CodeRabbit Pro on a per-seat basis ($30 vs. $24 annually)
  while also charging $1 per completed review after 50 reviews per active
  developer.
- BugBot is already the free/paid second-tier reviewer with reliable completion
  signals and a clean-pass merge-gate path.
- codeant.ai adds a security/code-health angle at $24/user/month with unlimited
  PR reviews, which may overlap or exceed Greptile's routine-review value.
- This repository is mostly markdown, shell, and workflow configuration. The
  highest-value findings are likely contradictions, stale workflow instructions,
  unsafe shell snippets, and missing gates; CodeRabbit path instructions and
  BugBot project rules can cover much of that surface.
- Greptile's value is strongest when CodeRabbit is rate-limited/down and BugBot
  also fails. That makes it an availability hedge rather than a primary reviewer.

One-month measurement standard:

- Keep Greptile auto-review off.
- Trigger Greptile only through the existing last-resort rule.
- For every Greptile invocation, record:
  - whether CR failed by rate limit or timeout
  - whether BugBot failed or was absent
  - number of Greptile findings by severity
  - number of true positives fixed
  - number of unique findings not found by CR/BugBot/codeant
  - billable review count and overage cost
- Cut Greptile if it produces no unique P0/P1 true positives during the month or
  if its unique true-positive cost is materially higher than CodeRabbit,
  BugBot, or codeant.ai.
- Keep Greptile if it catches at least one material issue missed by both
  CodeRabbit and BugBot in a scenario where those tools were unavailable or
  demonstrably less capable.

## Tool: Graphite Agent (formerly Diamond)

### Current config

Repo-local config: none found.

Issue context says Graphite is turned on but not yet functioning. Current repo
rules do not mention Graphite/Diamond, and no merge-gate script or polling helper
currently recognizes Graphite as a reviewer.

### Max-config recommendations

Flag for user review before applying:

- Fix GitHub app/repository installation before adding any repo rules. Confirm
  Graphite can see the repository and comment on a test PR.
- Keep Graphite Agent non-blocking during the first month. Do not add it to
  `.claude/rules/cr-merge-gate.md` until it posts reliable, inspectable review
  output and a stable bot identity/check-run name.
- If using Graphite as a broader PR platform, decide separately whether the
  value is review quality or workflow consolidation:
  - stacked PRs
  - merge queue
  - inbox/notifications
  - CI optimizer
  - AI chat/reviews
- Configure review customization, automation, filters, and rules in Graphite
  once the app functions. Start advisory and measure unique findings.

### Unused or underused features

- Graphite Agent AI PR reviews and chat.
- Review customization with automation, filters, and rules.
- Suggested fixes and CI summaries.
- Stacked PR workflow, stack merge, and Graphite CLI/VSCode/MCP.
- Merge queue and automations.
- Insights and CI optimizer.
- Code indexing controls and AI privacy controls.

### Monthly cost

Official pricing reviewed 2026-04-28:

- Hobby: free for personal projects.
- Starter: $20/seat/month billed annually, with limited Agent reviews/chat.
- Team: $40/seat/month billed annually, with unlimited AI reviews/chat plus
  team workflow features.
- Enterprise: custom.
- Team trial: 30 days.

Sources:

- <https://graphite.com/docs/billing-plans>
- <https://graphite.com/blog/introducing-graphite-agent-and-pricing>

### Chain placement

Not in the merge-gate chain today. Recommended placement: no chain placement
until Graphite is functioning. If it later proves reliable, consider it a
parallel advisory reviewer or a replacement workflow platform, not a fourth
fallback reviewer layered after Greptile.

## Follow-up audit scheduled for 2026-05-28

Follow-up target: 2026-05-28, 30 days after this audit.

Scheduled follow-up issue: [#376](https://github.com/auerbachb/claude-code-config/issues/376)

Follow-up issue title:

`Follow-up: 30-day AI review tool value audit for #368`

Recommended labels:

- `audit-followup`

Recommended issue body:

```markdown
## Context

Follow-up for #368 after one month of using/auditing CodeRabbit, codeant.ai,
BugBot, Vercel Agent, Greptile, and Graphite.

## Review questions

- Compare findings volume by tool.
- Compare true-positive and false-positive rate by tool.
- Identify unique value-add not duplicated by another reviewer.
- Compare each tool's monthly or usage cost against accepted findings.
- Decide whether Greptile should remain enabled as a paid fallback.
- Decide whether codeant.ai and/or Graphite should enter the formal review chain.
- Decide whether Vercel Agent should remain Vercel-only.

## Test plan

- [ ] 30-day findings volume summarized for all 6 tools
- [ ] True-positive and false-positive rate estimated for all 6 tools
- [ ] Monthly/usage cost compared against unique value-add
- [ ] Greptile keep/cut recommendation made
- [ ] Final review-chain recommendation documented

References #368.
```

Scheduling note: issue #376 is the 30-day audit reminder because no durable cron
tool is available in this execution environment.

## 30-day measurement template

Use this table in the follow-up:

| Tool | Reviews run | Findings | True positives fixed | False positives | Unique findings not caught by others | Monthly cost | Keep/cut recommendation |
|------|-------------|----------|----------------------|-----------------|--------------------------------------|--------------|-------------------------|
| CodeRabbit | TBD | TBD | TBD | TBD | TBD | TBD | TBD |
| codeant.ai | TBD | TBD | TBD | TBD | TBD | TBD | TBD |
| BugBot | TBD | TBD | TBD | TBD | TBD | TBD | TBD |
| Vercel Agent | TBD | TBD | TBD | TBD | TBD | TBD | TBD |
| Greptile | TBD | TBD | TBD | TBD | TBD | TBD | TBD |
| Graphite | TBD | TBD | TBD | TBD | TBD | TBD | TBD |

## Config-change decisions

| Change | Status | Reason |
|--------|--------|--------|
| Raise CodeRabbit token threshold from 10,000 to 14,000 words | User review | 10,000 is the soft budget and preserves early-warning coverage; 14,000 is only the transitional hard limit. |
| Add `.cursor/BUGBOT.md` | User review | Useful, but adds another rule surface that can drift. |
| Enable BugBot Autofix | User review | Can push commits and consume Cloud Agent credits. |
| Enable codeant.ai SAST/CI as blocking | User review | Needs one-month false-positive baseline first. |
| Broaden Vercel Agent auto-review | User review | Direct credit/token spend; this repo is not a Vercel app. |
| Add `greptile.json` | User review | Dashboard is current source of truth; repo config could drift. |
| Raise Greptile usage | Rejected for now | Cost concern and last-resort-only role. |
| Add Graphite to merge gate | Rejected for now | Tool is not yet functioning on this repo. |
