# Per-repo review policy (`## Review policy`)

A repo can declare **review tiers** in its own `.claude/pm-config.md`, so the review a PR needs follows the risk of what it touches rather than one harness-wide rule. This is issue #1724. Its increments, all landed, are:

| Issue | Part | Status |
|---|---|---|
| #1725 | Tier resolver | Landed |
| #1726 | Merge gate | Landed |
| #1727 | Deferred findings | Landed |
| #1728 | BugBot triggering | Landed |
| #1729 | Pipeline ceiling | Landed |

A follow-up, #1807, lets a repo [turn off escalation](#turning-off-escalation) to BugBot and Greptile altogether. Another, #1749, makes every reviewer **trigger** follow the tier, not just the merge gate: see [Trigger eligibility](#trigger-eligibility). A separate, account-wide control, the [daily cap on paid triggers](#account-level-daily-cap) (#1812), is set once for every repo rather than per repo.

This file is the mechanism reference. The rule files only point here, because the rule corpus has no word headroom.

A repo **without** the section keeps today's behaviour exactly. The resolver reports gate `legacy`, and every consumer takes its existing path.

## Declaring tiers

Add a markdown table under `## Review policy`. The resolver reads the **first** table in the section, matching columns by header name: case-insensitive, any order, unknown columns ignored.

```markdown
## Review policy

| Tier    | Gate                 | Paths                                  | Labels    |
|---------|----------------------|----------------------------------------|-----------|
| core    | full                 | src/ledger/**, src/auth/**, migrations/ | tier:core |
| leaf    | ci+codeant-one-round | src/adapters/**, src/reports/**        | tier:leaf |
| docs    | ci-only              | docs/**, specs/**, *.md, .github/**    | tier:docs |
| default | full                 |                                        |           |
```

| Column | Meaning |
|---|---|
| `Tier` | Required. The name reported back to you. Names must be unique, compared case-insensitively. |
| `Gate` | Required. One of `ci-only`, `ci+codeant-one-round`, or `full`. |
| `Paths` | Comma-separated shell globs, matched against the repo-relative path. `*` also crosses `/`, so `*.md` means every markdown file anywhere. `**/` also matches zero directories, as in CODEOWNERS, so `**/migrations/**` covers a root-level `migrations/`. A trailing `/` means everything under that directory. Backticks around a glob are ignored. Brace lists such as `src/{a,b}/**` are refused, because the comma split would cut them into two globs that match nothing; list each path separately. |
| `Labels` | Comma-separated PR labels, compared case-insensitively. |

A row named **`default`** classifies files that no `Paths` glob matches. Without a `default` row, those files are `full`.

Declare every tier in **one contiguous table**. The table is found the way GitHub finds one: a header line followed by a delimiter row (`|---|---|`). The edge pipes are optional, and the table runs to the first blank line or heading. Prose that merely contains a `|` is ignored.

Fenced code blocks and `<!-- -->` comments are removed from the whole file before the section is looked up, following CommonMark fence rules. So an inactive example table, or even a fenced example carrying its own `## Review policy` heading elsewhere in the file, never becomes the live policy. The one fenced block the resolver does read is the section's own ` ```ini ` block for the [escalation switch](#turning-off-escalation).

A row-shaped line (one starting with `|`) that belongs to no table makes the policy invalid rather than being silently dropped. So does a second table. Examples are rows separated from the table by a blank line or a comment, or a table missing its delimiter row.

## Resolution — strictest wins

The gates rank `full` > `ci+codeant-one-round` > `ci-only`. The candidate tiers for a PR are:

1. every tier whose `Paths` match **any** changed file. For a renamed file, both the old path and the new path count, so moving a file out of a core directory still touches core.
2. every tier whose `Labels` include a label on the PR.
3. `default` (or `full`, with no `default` row) when some file matched no path **and** no tier label is present.

The PR gets the strictest candidate gate. `tier` names the first table row carrying that gate.

Three consequences follow:

- **A label classifies what the paths leave open.** It never lowers a file that a path already matched.
- **A PR with no files and no tier label gets `default`.**
- **If GitHub lists fewer files than the PR changed, `full` is added.** This happens past GitHub's 3000-file listing cap. Files the resolver cannot see are never assumed to be light. A changed path containing a newline cannot be classified either, and adds `full` the same way.

## Fail-closed behaviour

| Condition | Result |
|---|---|
| No section, no `pm-config.md`, or a section with no table | `policy: absent`, gate `legacy`. A prose-only section also warns on stderr. |
| Unknown gate, missing `Tier`/`Gate` column, header but no data rows, empty or duplicate tier name, a brace glob, a `\|` row outside the table, a second table, or a near-miss heading such as `## Review Policy` | `policy: invalid`, gate **`full`**, and one stderr warning. `full` is today's gate, so a typo can never loosen review. |
| A policy source that exists but cannot be read: a failed `gh` call, a base-branch object that is not a base64 file (a symlink, an over-size blob), a missing `changedFiles` count, an unreadable, directory, or dangling-symlink `--config` or checkout `pm-config.md`, or offline mode outside a git checkout | exit 4 with nothing on stdout. The consumer fails closed. Only a source that does not *exist* reads as absent. |

CRLF line endings are stripped before parsing, so a Windows checkout reads the same policy as CI.

## Deferred findings

On the `ci-only` and `ci+codeant-one-round` tiers, a non-severe finding can be answered with a follow-up issue instead of a fix. Reply in the review thread with a link to the issue, for example `Deferred to #1234 — not severe.` The merge gate then stops counting that thread as a blocker (#1727).

On `full` and `legacy`, a follow-up link changes nothing: resolve the thread or it blocks. The same holds when the tier could not be resolved. On those tiers the gate makes no issue lookups at all.

"Severe" stays the agent's judgment. Fix a failing test, a security or data-integrity finding, or a contradiction with a design doc; never defer it. The gate only checks that a finding left unfixed points at a real issue.

### What counts as a follow-up reply

A reply qualifies only when all of these hold:

- It is a comment **after** the first one in the thread. The first comment is the finding itself.
- Its author is a GitHub user account (GraphQL `__typename` `User`): the PR author, a collaborator, or an agent posting as the user. A bot, an app, or a deleted account never qualifies, so a reviewer's own `#123` cannot clear its thread.
- Its body references an issue in one of three forms:
  - `#N`
  - `<owner>/<repo>#N` naming this repo, compared case-insensitively
  - `https://github.com/<owner>/<repo>/issues/N`

A `/pull/` URL never matches. Neither does a reference to another repo, or a number glued to a word or a path (`abc#12`, `a/b/c#12`). Quoted lines (`> …`) are skipped, so quoting a bot's finding cannot defer the thread on an issue number the bot wrote.

The parser for these forms and the quoted-line rule is `.claude/scripts/lib/deferred-refs.jq`. The merge gate and the `/review-stack-audit` ledger's verdict classifier (Issue #1810) both load that one file, so they cannot disagree on what a follow-up link is.

Two read limits apply, both on the blocking side. Only the first 100 comments of a thread are read, so a follow-up link posted after the 100th stays unseen. An issue number has at most nine digits, which keeps it exact through `tonumber`. A link past either limit leaves the thread blocking; post the follow-up reply earlier in the thread, or resolve the thread instead.

### How a link is verified

Each distinct number is looked up once per gate run through `repos/<owner>/<repo>/issues/N`, with at most 25 lookups per run. A number counts only when the object exists, has no `pull_request` key (so it is an issue, not a PR), and its `repository_url` names this repo, which rules out an issue since transferred elsewhere. The issue's open or closed state is not checked.

| Lookup result | Thread | Extra `missing` reason |
|---|---|---|
| An issue of this repo | Deferred | None |
| A PR, a 404 or 410, or a transferred issue | Blocks | None |
| Any other failure, a malformed response, or a number past the 25-lookup cap | Blocks | `follow-up issue #N could not be verified — its review thread stays blocking (issue #1727)` |

A thread with several links is deferred as soon as one of them verifies, and a failed lookup on another link then adds no reason. Every doubt keeps the thread blocking, and a lookup failure never reads as "no such issue".

### What the gate reports

- `unresolved_thread_count` counts only the **blocking** threads on these two tiers. `/wrap`'s threads-only branch keys off it, so a deferred thread never sends a merge-ready PR to `/fixpr`. On `full` and `legacy` it still counts every unresolved thread.
- The `missing` reason keeps its exact text, `N unresolved review thread(s) — resolve via GraphQL before merge`, with N the blocking count.
- `deferred_thread_count` is the number of deferred threads, always `0` off these tiers.
- `deferred_issues` is the sorted, de-duplicated list of the verified issue numbers that deferred a thread, and `[]` when there are none.
- A stderr line names the deferred issues, so the deferral is never silent.

Only the blocker count changes. The Greptile P0 check still sees a deferred thread as unresolved, and so does the list of resolved comments that `review-substance.sh` reads. A deferral clears a blocker; it is never review evidence.

GitHub's own **Require conversation resolution** branch-protection setting is separate. When a repo turns it on, GitHub still refuses the merge until the thread is resolved.

## Where the policy is read from

In PR mode, the policy comes from the PR's **base branch**, through the contents API. It is read **before** the PR's files and labels are fetched, so a repo with no policy pays for that single read and nothing more. `--base <ref>` supplies the base branch when the caller already knows it, as `merge-gate.sh` does, which saves the `gh pr view` too. It never comes from the local checkout. A PR that edits `## Review policy` therefore cannot re-tier itself. Once such an edit merges, the new policy applies to every PR the gate evaluates from then on, including PRs that were already open. The policy is read fresh at each gate run, never cached per PR.

`--config <path>` overrides the source. The CI workflow uses it with its base-branch checkout, and the tests use it with fixtures. It is a flag only, never an environment variable, so ambient state cannot re-point a review-enforcing consumer at a looser policy. The merge gate never passes it.

## What each gate means

`merge-gate.sh` resolves the tier once per run (#1726). The tier selects **only** the reviewer-approval requirement:

| Gate | Reviewer requirement |
|---|---|
| `legacy` | The reviewer-path gate in `cr-merge-gate.md`, unchanged. CodeRabbit/CodeAnt, BugBot, and Greptile keep their current rules. |
| `full` | The same gate as `legacy`. The only difference is that `full` was declared by a policy. |
| `ci-only` | None. |
| `ci+codeant-one-round` | One **completed** CodeAnt round on any commit of the PR, not necessarily HEAD. |

**Every tier** keeps the merge-wide checks:

- authorship
- merge state (`BEHIND`, `CONFLICTING`, `DIRTY`, `UNKNOWN`)
- failing or incomplete CI
- branch-protection required contexts
- unresolved review threads
- a human `CHANGES_REQUESTED`
- CODEOWNERS `reviewDecision`

A completed CodeAnt round is any one of these:

- a `done: true` row in CodeAnt's `<!-- codeant-review-status:[…] -->` run record, posted by `codeant-ai[bot]`
- a `codeant-ai[bot]` review in state `COMMENTED` or `CHANGES_REQUESTED` (CodeAnt posts those only once it has run)
- a completed check-run on HEAD whose conclusion is `success`, `neutral`, or `failure`, published by the CodeAnt app itself (slug `codeant-ai`, the app behind the `codeant-ai[bot]` login). A check's *name* is not identity: any workflow in the PR can name a job "CodeAnt".

An `APPROVED` on its own is **not** a round. CodeAnt posts an approval stub before it has analysed anything (#1365, #1432). A CodeAnt `CHANGES_REQUESTED` does not block on its own either: its findings arrive as review threads, and the thread check governs them.

The gate's JSON adds `review_tier: {gate, tier, policy}`. The `reviewer`, `path`, and `primary_review_met` fields keep their meaning. So on the lighter tiers `primary_review_met` stays `false`, because no approval exists; `met` is the readiness signal.

If the tier cannot be resolved, the gate fails closed. The resolver may be missing, exit non-zero, or return an unusable answer. In each case the gate:

- adds `review tier unresolved: …` to `missing`
- still runs the full reviewer path
- reports `review_tier: null`

The run never ends up less strict than legacy.

The later increments cover the rest:

- **#1727** (landed): a follow-up-issue reply clears a deferred finding in the `ci-only` and `ci+codeant-one-round` tiers. See [Deferred findings](#deferred-findings).
- **#1728** (landed): BugBot is invited only on `full` and `legacy`. See [BugBot triggering](#bugbot-triggering).
- **#1729** (landed): a repo sets its own per-thread pipeline ceiling with `PIPELINE_CEILING` in the `## Active work` section of its `.claude/pm-config.md`, which `/subagent`, `/pm`, `/wave` and `/pm-forgotten-pr`'s merge dispatch honour; it stays subordinate to `ACTIVE_WORK_CAP` (`min()`, never `max()`). See [`active-work-cap.md` §Subordination](active-work-cap.md#subordination--min-never-max).

The two-round cap on core PRs stays a process limit, not gate logic.

## BugBot triggering

BugBot is the most expensive reviewer in the stack, so the `ci-only` and `ci+codeant-one-round` gates no longer invite it (#1728). Only one of those two recognised gates suppresses the invitation, or any gate in a repo that [turned escalation off](#turning-off-escalation). Otherwise `full`, `legacy`, a usage error, and a tier that cannot be resolved all still invite BugBot, because the helper fails open. Every path that could invite it asks one helper first, so they cannot disagree:

```bash
.claude/scripts/bugbot-tier-excluded.sh <pr_number> [--repo owner/name] [--base <ref>]
```

| Exit | Meaning | What the caller does |
|---|---|---|
| `0` | The gate is `ci-only` or `ci+codeant-one-round`, or escalation is off on any gate. The gate is printed on stdout. | Skips `@cursor review` and says so. |
| `1` | The gate is `full` or `legacy`, and escalation is on. The gate is printed on stdout. | Posts, as before. |
| `2` | A usage error, or the tier could not be resolved: the resolver is missing, exits non-zero, or returns no recognised gate. | Posts, as before. |

The helper wraps `review-tier.sh --json`. A resolver failure **posts**, which is the opposite of the merge gate's direction. That is deliberate: `legacy` behaviour is to post, and the BugBot refusal guard (`bugbot-refused-head.sh`) fails the same way. An unreadable policy can cost one BugBot review, never a missing one. The merge gate is unaffected, because it resolves the tier on its own and fails closed.

Since #1749, the trigger paths below ask [`review-triggers-allowed.sh`](#trigger-eligibility) first, and on a repo with a `## Review policy` they act on its answer instead. The table below is therefore what they do when that helper is missing from the install; `escalate-review.sh` still asks this helper directly.

| Path | On a `ci-only` or `ci+codeant-one-round` PR, without the #1749 helper |
|---|---|
| `maybe-trigger-ai-review.sh` | Posts the CodeAnt nudge only. It leaves the cursor step open, so a resumed run asks the tier again and posts only if the tier now invites BugBot. `--json` adds `bugbot_skipped: {"reason": "review_tier", "gate": …}`, on real and `--dry-run` runs alike. When escalation is off on full/legacy, the reason is `escalation_off` with the gate. On a real run only, the field reads `{"reason": "refused_head", "gate": null}` when the refusal guard skipped the nudge instead: a dry run exits before that guard runs (Issue #1735). It is `null` when nothing was skipped. |
| `pr-preflight.sh` | Gives the cursor reviewer status `skipped-tier-excluded`, which counts as clean. |
| `/fixpr` Step 3b | Prints `[REVIEWERS] skipping @cursor review — review tier <gate> excludes BugBot`. |
| `cursor-review-pr-comment.yml` | Never posts a comment and runs no helper (issue #1897): one notice step only. |
| `escalate-review.sh` | Emits `STATUS=tier_gate` at the BugBot point, where it would otherwise emit `no_reviewer` ([Paid review authorization](#paid-review-authorization)). |

`STATUS=tier_gate` means the review tier, not the escalation chain, governs the PR. The caller does not make BugBot the reviewer and posts nothing. It keeps the current reviewer and keeps polling, and `merge-gate.sh` applies the tier's gate. It is not a stop and not self-review. Every other verdict keeps its meaning, including `no_reviewer` at the Greptile point for a BugBot that reviewed the PR on its own and then failed. The one exception is a repo that [turned escalation off](#turning-off-escalation).

`pmm-act.md` and `wrap-merge-gate-recovery.md` never post `@cursor review` without the owner's approval (issue #1897). `tier_gate` keeps a lighter-tier PR from reaching that state.

## Trigger eligibility

The merge gate honours the tier, and since #1749 so does every path that **invites** a reviewer. Before it posts, each one asks one helper which reviewers it may invite on the PR's current HEAD. Without that, a docs-only PR still drew CodeRabbit, CodeAnt, and (then) Graphite triggers from the agent itself, and a core PR drew BugBot on every intermediate HEAD.

```bash
.claude/scripts/review-triggers-allowed.sh <pr> [--repo owner/name] [--base <ref>] [--head <sha>] [--mode-only]
.claude/scripts/review-triggers-allowed.sh <pr> --claim <reviewer> [--repo …] [--head <sha>]
.claude/scripts/review-triggers-allowed.sh <pr> --release <reviewer> [--repo …]
```

`<reviewer>` is `codeant`, `cursor`, or `coderabbit` (Graphite was retired 2026-11-03, #1889, and is rejected). The full contract is in `--help`.

### Modes

| Mode | When | What callers do |
|---|---|---|
| `legacy` | The repo has no `## Review policy` (`review-tier.sh` reports policy `absent`). | Run their unchanged pre-#1749 code. Nothing else is read. |
| `tiered` | A policy is present, or invalid (which resolves to `full`). | Post only what the per-reviewer decision allows. |
| `fail_closed` | The tier cannot be resolved, and the local checkout has a `## Review policy`, cannot be read, or is not the PR's repo. | Post nothing. Every reviewer is deferred with `tier_unresolved`. |

When `review-tier.sh` fails, the helper probes the local checkout offline (`review-tier.sh --files-from - --json`). Only a checkout of the PR's own repo with no policy at all falls back to `legacy`. So an unreadable policy never spends on a paid reviewer, and a repo without one keeps today's behaviour. A caller that finds the helper **missing** also takes its legacy path, and says so on stderr. A caller whose helper answers nothing usable posts nothing that run.

### Rules (mode `tiered`)

The first matching row wins for each reviewer.

| Gate | Reviewer | Decision |
|---|---|---|
| `ci-only` | all | Excluded, `tier_excluded`. |
| `ci+codeant-one-round` | `cursor`, `coderabbit` | Excluded, `tier_excluded`. |
| `ci+codeant-one-round` | `codeant` | Excluded `round_completed` once a [completed CodeAnt round](#what-each-gate-means) exists on any commit, or `lifetime_cap` once one invitation exists. Otherwise the CI gate applies, then allowed. Never re-invited. |
| `full` | `codeant` | Excluded `lifetime_cap` once the invitations reach the cap. The cap is `1`, unless the policy sets [`CODEANT_LIFETIME_CAP_FULL`](#codeant-lifetime-cap-on-full). The output reports it as `reviewers.codeant.cap`. Otherwise the CI gate applies, then allowed. |
| `full` | `cursor` | Excluded `escalation_off` when the policy sets `REVIEW_ESCALATION=off`, or `lifetime_cap` after two invitations (REV-2). Otherwise the CI gate applies, then deferred `head_not_settled` until HEAD settles, then excluded `refused_head` if BugBot already refused this HEAD for a usage limit. **Last**, it is deferred `daily_cap` on a validated [daily cap](#account-level-daily-cap) `over`. Otherwise allowed. |
| `full` | `coderabbit` | Only as the fallback when CodeAnt is unavailable: allowed `codeant_unavailable` after the CI gate. It is deferred `codeant_pending` while the CodeAnt invitation is inside its timeout, and excluded `not_fallback` otherwise. It has **no lifetime cap**: while CodeAnt is down the gate needs a CodeRabbit `APPROVED` on every HEAD, so a cap would strand the PR after its first fix push. Each caller's per-HEAD already-present check and `cr-review-hourly.sh` bound it, and its ledger count is reported, never capped. |

Before the per-gate rows, after the static exclusions, two conditions defer every reviewer. One is `head_moved`: `--head` names a SHA the PR's live HEAD no longer matches. The other is `facts_unreadable`: a PR read failed. A closed PR is excluded with `pr_not_open`. Greptile is never in scope, and stays `escalate-review.sh`'s last resort. The CodeRabbit hourly caps (`cr-review-hourly.sh`) stay with the callers.

| Kind | Meaning | Callers |
|---|---|---|
| `allowed` | Invite now. | Claim, then post. |
| `excluded` | Waiting will not change the answer. | Skip. `pr-preflight.sh` reports `skipped-tier-excluded`, which counts as clean. |
| `deferred` | Not now. The answer can change by itself: CI finishes, HEAD settles, or the ET day rolls over. | Skip, and ask again later. `pr-preflight.sh` reports `skipped-tier-deferred`, which is not clean. `maybe-trigger-ai-review.sh` leaves its step record open so the next tick is not a `duplicate_poll_tick`. |

### The CI gate and settled HEAD

Nothing is invited while CI on HEAD is red or pending. The gate is **build CI only**: `ci-status.sh --exclude-reviewers` drops the reviewers' own check-runs, matched by exact app slug (`codeant-ai`, `cursor`, `coderabbitai`, `greptile-apps`, the retired `graphite-app`, and their short forms). Otherwise a reviewer that was never invited would hold CI pending forever, and one that failed would hold it red. With no build check left, the verdict is pending, as for an empty check list. The reasons are `ci_pending`, `ci_red`, and `ci_unknown`.

A HEAD is **settled** when build CI is green and the HEAD has been observed for at least the settle threshold, 600 s by default. The observation time is the **latest** of three times:

- the HEAD commit's committer date
- the newest `head_ref_pushed` or `head_ref_force_pushed` timeline event (the anchor `pr-preflight.sh` uses)
- the earliest check-run created on HEAD, GitHub's own clock at about push time

An anchor that cannot be read is never settled. Only BugBot waits for a settled HEAD, so a fast-passing intermediate HEAD does not draw it.

### Lifetime counts and the claim ledger

A reviewer's invitation count is the **maximum** of two sources:

- **Visible trigger comments** on the PR, on any commit. These are issue comments whose trimmed body is exactly the trigger, from any author except the four reviewer bots themselves. They cover other machines and the CI workflow.
- **This machine's ledger**, `.prs["<N>"].review_trigger_ledger.<reviewer>` in `~/.claude/session-state.json`, scoped to the repo. It covers the seconds before GitHub lists a fresh comment, and concurrent local runs.

Every caller runs `--claim <reviewer>` immediately **before** it posts. The claim re-evaluates the decision. When the reviewer is still allowed, it raises the ledger count with `session-state.sh --cas`, so of two claims racing at a cap only one wins; the loser re-evaluates, up to three times. Exit `0` means post now, and exit `1` means do not post. A post that definitely failed runs `--release`, so a failed attempt never counts against a cap. A dry run evaluates, but never claims.

### CodeAnt unavailable

CodeAnt is **unavailable** when it was invited and no CodeAnt artifact appeared at or after the newest invitation within the timeout, 1800 s by default. An artifact is a `codeant-ai[bot]` comment (created or edited), a `codeant-ai[bot]` review, or a `codeant-ai` check-run on HEAD. CLI failures are never evidence: only the GitHub App's own artifacts count. A "no PR Review subscription" comment from the App is an artifact, so it reads as available.

### Configuration

Two optional keys in the repo's `.claude/pm-config.md`, section `## Complexity triggers`, are read from the local checkout. Each has an environment override:

| Key | Default | Env override |
|---|---|---|
| `TRIGGER_SETTLE_SECONDS` | `600` | `COMPLEXITY_TRIGGER_SETTLE_SECONDS` |
| `CODEANT_UNAVAILABLE_SECONDS` | `1800` | `COMPLEXITY_CODEANT_UNAVAILABLE_SECONDS` |

A value must be a non-negative integer. Anything else warns on stderr and keeps the default. These keys only delay or permit an invitation, so they never loosen the merge gate.

### Spend

Issue #1749 section 2.4 proposed a per-repo daily spend check. It is superseded by the account-level [daily cap](#account-level-daily-cap) (#1812), which the helper's `full`-tier BugBot rule asks last, exactly as `maybe-trigger-ai-review.sh` always has: only a validated `over` defers BugBot, and an `unknown` tally allows it. The refusal guard (`bugbot-refused-head.sh`) runs just before the cap, so on a tier-aware repo every caller, `pr-preflight.sh` included, gets both BugBot guards.

### Trigger paths on a tier-aware repo

| Path | On a tier-aware repo |
|---|---|
| `maybe-trigger-ai-review.sh` | After its round and complexity gates, each of its steps (CodeAnt, BugBot) posts only when allowed, and claims first. A refused HEAD marks the cursor step done, as before. A deferred step leaves the step record open. `--json` adds `trigger_mode`, `trigger_skips` (reviewer → `{kind, reason}`), and `deferred`. Its status is `triggered` when something posted, and otherwise `skipped` with reason `tier_deferred` or `tier_excluded`. `bugbot_skipped` keeps its shape: `review_tier`, `escalation_off`, `refused_head`, `daily_cap` with the tally, or the new reason with the gate. |
| `pr-preflight.sh` | After its HEAD-scoped already-present check, a reviewer is claimed and triggered when allowed (CodeRabbit is still behind `cr-review-hourly.sh`). Otherwise it is `skipped-tier-excluded` or `skipped-tier-deferred`. |
| `/fixpr` Step 3b | `fixpr-reviewer-triggers.sh` skips reviewers already active on the pushed SHA and posts only the allowed ones, with claims. A `daily_cap` skip still writes the `## Review notes` line. Right after a push CI is usually still pending, so it often posts nothing; `pr-preflight.sh` and `maybe-trigger-ai-review.sh` ask again once CI is green. |
| `cursor-review-pr-comment.yml` | Never posts a comment and runs no helper (issue #1897): one notice step only. |
| Manual re-triggers (`pmm-act.md`, `wrap-merge-gate-recovery.md`, the Phase B agent, `/fixpr`'s stale-approval recovery) | Post only a reviewer the helper allows, and claim it first. |

## Account-level daily cap

The review vendors cap the **account**, not a repo. CodeRabbit's usage pool is org-wide, Cursor's spend limit covers every repo, and Greptile's flex cap is per org. Two repos that each honour their own $10 can still draw $20 from one cap, and neither can see the other. So the harness keeps one soft cap per paid platform per day, evaluated across every registered repo, and asks it before it posts a paid trigger. This is issue #1812, the last increment of the cross-repo cost ledger (#1747).

### Where the cap is read from

The cap is set once, in the account config, not per repo: the `## Review daily caps` section of `.claude/account-config.md`. That file is published to `~/.claude/account-config.md`, and the helper reads it with `pm-config-get.sh --file "${CLAUDE_ACCOUNT_CONFIG:-$HOME/.claude/account-config.md}"`.

```ini
REVIEW_DAILY_CAP_USD_BUGBOT = 10
REVIEW_DAILY_CAP_USD_CODERABBIT = 10
REVIEW_DAILY_CAP_USD_GREPTILE = 10
```

| Source | Precedence |
|---|---|
| Env `REVIEW_DAILY_CAP_USD_<PLATFORM>` | First. Set but blank counts as unset. |
| The account config section | Second. `KEY = value` or `KEY: value`. The key matches in any case, and the first occurrence wins. A trailing `# note` is dropped, and HTML comments are ignored. |
| Default | `10`. |

A value must be a non-negative decimal. Anything else, such as `$10`, warns on stderr and falls back to the default, and so does a config file that exists but cannot be read. A missing file or section uses the default silently.

### What is tallied

```bash
.claude/scripts/review-daily-cap.sh <platform> [--add-usd X] [--fixture <path>]
.claude/scripts/review-daily-cap.sh <platform> --rate
```

The day is the **America/New_York** calendar day, the same boundary `greptile-budget.sh` uses. The UTC date never decides it. The helper lists the repos from `review-repos.sh` (the tracked `## Review repos` list plus the optional untracked overlay `~/.claude/account-config.local.md`, #1860, so private repo names never enter a tracked file), reads every PR updated since ET midnight, and prices that day's events with `lib/review_ledger.py`, the `/review-stack-audit` ledger's own rules:

| Platform | Spend |
|---|---|
| `bugbot` | `Cursor Bugbot` check-runs from the `cursor` app, deduplicated by run id, times the per-review rate. |
| `coderabbit` | `Charged: $X` receipts in `coderabbitai[bot]` comments. |
| `greptile` | Non-bot `@greptileai` comments, times credits per review, times $/credit. |

Rates come only from the `review-stack-rates` block in `pricing-matrix.md`. A known tally is cached per platform and ET day in `~/.claude/review-daily-cap/` for 5 minutes. Only the spend is cached, so a cap edit takes effect at once.

It prints one line, `{"platform","date","spent_usd","add_usd","cap_usd","status"}`:

| Status | When | Exit | The caller |
|---|---|---|---|
| `ok` | `spent + add <= cap` | `0` | Posts. |
| `over` | `spent + add > cap`. The comparison is strict. | `1` | Skips the trigger and says so. |
| `unknown` | The tally cannot be read. A rate is null, `review-repos.sh` lists nothing or fails, `gh` fails or returns errors, or a dependency is missing. `spent_usd` is then `null`, never `0`, and stderr says why. | `0` | Posts, and says the cap is unknown. |

`--add-usd` is the trigger about to be spent. A caller gets it from `--rate`, which reads the block's per-review figure. Only when that reads null does `--rate` fall back to `REVIEW_RATE_USD_<PLATFORM>`, then to BugBot's documented `1.58`. That is the block's own measured average, $815.58 over 516 reviews (#1204).

### Where it is consulted

| Path | Behaviour |
|---|---|
| `maybe-trigger-ai-review.sh` | Asks the cap last: the tier skip, then the refused-HEAD skip, then the cap. On `over` it skips `@cursor review` and still posts CodeAnt. It leaves the cursor step open, as the tier skip does, so a resumed run asks again. `--json` and `--dry-run --json` report `bugbot_skipped: {"reason":"daily_cap","gate":null,"tally":{…}}`, plus the tally as `bugbot_daily_cap` whenever the cap was consulted, `unknown` included. |
| `/fixpr` Step 3b | Asks the cap after the same two skips. On `over` it appends `BugBot skipped: daily cap ($spent of $cap today)` under a `## Review notes` heading in the PR body, which it creates if absent. It does this once per HEAD, through `pr-body-review-note.sh`. |
| `cursor-review-pr-comment.yml` | No longer posts anything (issue #1897), so the former no-policy bypass is closed. |
| `review-triggers-allowed.sh` (#1749) | On a tier-aware repo, asks the cap last in its `full`-tier BugBot rule, after the refusal guard. On `over` BugBot is deferred with reason `daily_cap` and the tally, which every caller reports and `/fixpr` Step 3b notes in the PR body. No per-repo tally exists: #1749's section 2.4 is satisfied by this cap. See [Trigger eligibility](#trigger-eligibility). |

### Failure direction

The cap is **soft**, and it fails open. Only a validated `over`, with exit `1` and a matching status, skips a trigger. A missing helper, an `unknown` tally, or an unexpected answer posts, and a stderr line says so. **The vendors' own caps remain the hard stop.** The tally reads live GitHub evidence, so it also counts spend the harness did not trigger, such as vendor auto-reviews and CI nudges. Receipts and per-run estimates are a floor. Comments are read from both ends of a PR, the first 100 and the last 100, and a comment seen from both ends counts once. A partial read is noted on stderr: a PR with more than 50 commits or 200 comments, a commit with more than 5 BugBot check suites, a suite with more than 20 BugBot runs, or a repo with more than 100 PRs updated today. The cap therefore errs toward spending slightly more than it thinks, never less. It is not a lock either: two triggers checked at once, or before an earlier trigger's run shows on GitHub, read the same tally and can both pass, so a burst can overshoot the cap by about one review per concurrent trigger.

## Turning off escalation

A repo can stop the CR → BugBot → Greptile chain at its primary reviewer, on every gate (#1807). Put this in a fenced `ini` block inside `## Review policy`, the same shape as `ACTIVE_WORK_CAP` under `## Active work`:

````markdown
## Review policy

| Tier | Gate | Paths |
|------|------|-------|
| core | full | src/** |

```ini
REVIEW_ESCALATION=off
```
````

**No-review override window (issue #1899).** The same ini block may set `NO_REVIEW_OVERRIDE_MINUTES` — absent → `10`; an integer `1`–`1440` → that many minutes; `off` → disabled; anything else, or the key outside a live ini block (prose, a comment, another section — a near-miss `## Review Policy` heading's block is still read, as for `REVIEW_ESCALATION`), → disabled with one stderr warning (fails toward not merging unreviewed work). `review-tier.sh --json` reports it as `no_review_override_minutes` (number or `null`). What the window does: `.claude/reference/no-review-override.md`.

<a id="codeant-lifetime-cap-on-full"></a>**CodeAnt lifetime cap on `full` (issue #1849).** The same ini block may set `CODEANT_LIFETIME_CAP_FULL`. It sets how many `@codeant-ai review` invitations [`review-triggers-allowed.sh`](#trigger-eligibility) allows on a `full` PR. This lets a repo whose contract allows more CodeAnt rounds on core PRs say so. Example: sales-kit REV-2 allows two, so it sets `CODEANT_LIFETIME_CAP_FULL=2`.

| Value | Cap |
|---|---|
| absent | `1`, the behavior before this knob existed |
| an integer `1`–`5` | that many invitations |
| anything else (`0`, `6`, empty, non-integer), or the key outside a live ini block | `1`, with one stderr warning. An unclear spend knob fails closed to the current cap. |

`review-tier.sh --json` reports the cap as `codeant_lifetime_cap_full`, the last key. `review-triggers-allowed.sh` validates it again, so a missing or malformed value keeps the cap at `1`. Like every policy key, it is read from the PR's **base** branch, so a PR cannot raise its own cap.

The knob is for the free CodeAnt reviewer on `full` only:
- `ci+codeant-one-round` stays at one round.
- BugBot keeps its fixed cap of two invitations and its owner-approval gate.
- CodeRabbit stays uncapped.

Nothing reads a repo's `AGENTS.md` prose: the knob is the only input.

| Value | Meaning |
|---|---|
| `on` (also when the key is absent) | Today's chain: CR → BugBot → Greptile. |
| `off` | BugBot and Greptile are never invited, on any gate, `full` and `legacy` included. |
| anything else, empty included | Read as `off`, with one stderr warning. An unclear cost switch fails toward not spending. |

`on` and `off` match in any case. The key follows `active-work-cap.sh`'s rule: `KEY=value` or `key: value`, the key matched case-insensitively, and the first occurrence wins.

### Where it is read from

The switch is read from the same policy text as the table, so it follows the same source rules: the PR's **base branch** in PR mode, `--config` when given, and the checkout in offline mode. It never comes from the PR head, so a PR cannot turn escalation off for itself.

Only a **live** ` ```ini ` fence inside the `## Review policy` section counts. The section's bounds are found in the fence- and comment-free text, exactly as for the table. So a fenced `## ` line inside the section does not cut it short, and a fenced example section elsewhere is never read. A key anywhere else in the file is ignored with one stderr warning: in prose, inside a `<!-- -->` comment, in a fence with another info string or none, or under another section, such as the `ini` block of `## Active work`. A misplaced cost switch is therefore never silent.

The table and the switch are independent:

- **An ini-only section** (no table) is still `policy: absent`, gate `legacy`, and reports its switch.
- **An invalid table** still resolves to `full`, and reports its switch.
- **A near-miss heading** such as `## Review Policy` makes the gate `full`, but its switch is still honoured. The gate fails toward more review, and the switch fails toward less spend.

`review-tier.sh --json` reports the switch as `"escalation":"on"|"off"` on every line, appended after the other keys. The plain output is still the gate alone.

### What it disables

| Consumer | With `off` |
|---|---|
| `bugbot-tier-excluded.sh` | Exits `0` (skip BugBot) on any recognised gate. stdout stays the gate, and one stderr line names escalation off as the reason. |
| Every BugBot trigger path | Inherits that answer unchanged: `maybe-trigger-ai-review.sh`, `pr-preflight.sh`, and `/fixpr` Step 3b (`cursor-review-pr-comment.yml` never posts — issue #1897). Their messages still name the gate, because the helper's stdout is still the gate. |
| `escalate-review.sh` | Emits `STATUS=tier_gate` where it would otherwise emit `no_reviewer`, at both paid points. It never reads or consumes the Greptile budget. Earlier verdicts keep their precedence, including `polling_cr` inside a CodeRabbit retry window. |

CodeRabbit and CodeAnt triggers follow the tier through [Trigger eligibility](#trigger-eligibility) (#1749), which also reads this switch for BugBot.

### What a `full` PR then needs

The merge gate does not change. On `full` and `legacy`, the reviewer requirement is still the CR path: a CodeRabbit or CodeAnt `APPROVED` on HEAD (`cr-merge-gate.md` Step 1). With escalation off there is **no fallback reviewer**. If neither bot approves, the PR keeps polling on `tier_gate` until one does, or until a human steps in. The lighter gates are unaffected, since they never needed BugBot or Greptile.

### Failure direction — known limit

The switch is read through `review-tier.sh`. If the tier cannot be resolved, the switch reads as **on**, and the chain runs as before. This happens when the resolver is missing, exits non-zero, or answers without a readable `escalation`. It is the same fail-open direction as [BugBot triggering](#bugbot-triggering) (#1728). A repo that turned escalation off can therefore still see one BugBot or Greptile hand-off while its policy is unreadable. `escalate-review.sh` says so on stderr when the resolver fails.

Only a literal `"escalation":"off"` skips. Any other value in the JSON, or a missing field from an older resolver, reads as on. `review-tier.sh` itself already turns an unclear value into `off`, so a typo in the file fails toward not spending.

## Paid review authorization

Owner policy (issue #1897): **no paid AI review without the owner's explicit approval in chat.** The rule is `.claude/rules/safety.md` §Paid AI Reviews; this section is its mechanism. It covers what this harness starts. BugBot and Greptile bill per review; CodeRabbit's included allowance, the CodeAnt App, and the local CLIs are free and unaffected. The one way through is an **owner grant** (issue #1898; [paid-review-approval.md](paid-review-approval.md)): one review on one PR, HEAD, vendor, and session, written only right after the owner's live yes and spent once by `paid-review-grant.sh`. No flag, environment variable, or other state marker bypasses a denial.

### Verdict contract

`escalate-review.sh` emits `STATUS=no_reviewer` at the two points that used to hand a PR to a paid reviewer: where it emitted `switch_bugbot` (BugBot responded, or was never invited) and where it emitted `trigger_greptile` (BugBot failed, or was invited and went silent). Both go through one function, `paid_review_denied`, which also names the replaced verdict on stderr as `paid_route=switch_bugbot|trigger_greptile` — the seam #1898 hooks. The Greptile point is refused **before** `greptile-budget.sh` is read, so `budget_exhausted` is unreachable and the budget ledger is never consumed by an autonomous cycle. Every earlier verdict keeps its precedence: `self_review` at entry, `gate_met`, the evaluator-outage `polling_cr` (bounded by its cap), the BugBot grace window, the CodeRabbit retry-window `polling_cr`, and `tier_gate` (tier exclusion or `REVIEW_ESCALATION=off`).

A consumer of `no_reviewer` posts nothing, changes no reviewer state (the PR stays `cr`; nothing is persisted, so the router recomputes the verdict each cycle), reports "paid review requires owner approval" once, and keeps polling. Merge stays blocked until a free review lands or the [no-review override](no-review-override.md) (issue #1899) is met — at which point the same paid points answer `gate_met`, so a blocked paid path falls through to the override instead of stalling. Consumers keep a defensive arm routing the retired `switch_bugbot` / `trigger_greptile` / `budget_exhausted` to the same handling. `no_reviewer` stays the verdict even when a grant exists — `escalate-review.sh` triggers nothing — and in an attended session it is the point where the agent may ask for one ([paid-review-approval.md](paid-review-approval.md) §When to ask).

### Gated trigger inventory

A change to the review tier on the same commit does not automatically invite BugBot (#1737). A label or policy change can make the PR eligible for BugBot; starting a paid review still needs the owner's explicit approval in chat. Once the tier permits it and the owner approves, the agent can spend that grant with `paid-review-grant.sh --trigger` on the live HEAD without pushing a new commit.

| Path | Behaviour now |
|---|---|
| `escalate-review.sh` | `no_reviewer` in place of `switch_bugbot` / `trigger_greptile`; see above. |
| `review-triggers-allowed.sh` | The last step of the cursor chain turns any `allowed` answer into excluded `approval_required`, after every earlier reason (tier, lifetime cap, CI, settle, `refused_head`, `daily_cap`). `--claim cursor` is denied (exit 1, no ledger write) in every mode, legacy included. CodeAnt and CodeRabbit claims are unchanged. `approval_required` is the seam the three script sites below spend a grant at (#1898), so a grant never skips an earlier reason; the grant's own compare-and-set, not the ledger, bounds its post to one. |
| `maybe-trigger-ai-review.sh` | Legacy path: after the tier, refused-HEAD, and cap skips, the cursor step ends in a skip — `bugbot_skipped: {"reason":"approval_required","gate":null}`, stderr names it, the step is left open. Tiered path: the helper's `approval_required` is reported the same way. CodeAnt still posts. With an owner grant for that PR and HEAD, `paid-review-grant.sh --trigger` posts `@cursor review` at that step instead, once (#1898). |
| `/fixpr` Step 3b (`fixpr-reviewer-triggers.sh`) | Prints `BugBot not invited — paid review requires owner approval` in place of the post, in both modes — or, under an owner grant for the pushed SHA, posts it once through `paid-review-grant.sh --trigger` (#1898). Free reviewers, the CodeRabbit 2-per-hour check, and the daily-cap PR-body note are unchanged. |
| `pr-preflight.sh` | Cursor status `skipped-approval-required` in both modes; it counts as clean (nothing pending). Under an owner grant for HEAD it is `triggered` instead, posted once through `paid-review-grant.sh --trigger` (#1898); a dry run never spends a grant. |
| `cursor-review-pr-comment.yml` | No posting step remains: the workflow keeps its trigger and job name and runs one notice step. No secret is referenced. |
| Phase B (`phase-b-reviewer.md`), `/subagent`'s Phase B prompt, `/go-on` | Route `no_reviewer` as above. BugBot invitation, BugBot re-review, Greptile triggering, and the Greptile P0 re-trigger are owner-approval-only, posted only through `paid-review-grant.sh --trigger` (#1898). |
| `/merge`, `/wrap` recovery, `/fixpr` stale-approval recovery, `pmm-act.md` | `@greptileai` and `@cursor review` are owner-approval-only, posted only through `paid-review-grant.sh --trigger`; `@coderabbitai full review` and `@codeant-ai review` are unchanged. `pmm-act.md`'s BugBot arm prints and releases its claim. |
| `merge-gate.sh` advice strings | Say a BugBot or Greptile re-review is paid and needs the owner's approval, instead of telling the reader to post the trigger. Decision logic is unchanged. |

Not triggers, and unchanged: `reply-thread.sh` token stripping, and the counters in `review_ledger.py` and `review-daily-cap.sh`. The daily-cap machinery stays live — it still protects approved spend once #1898 lands. Related: issue #1854 lists trigger paths that skip the daily cap; with every autonomous path now denied, the cap matters again only for approved reviews.

### Approved Greptile reviews — mechanics

An approved Greptile trigger goes through `paid-review-grant.sh --trigger --vendor greptile`, which spends the grant and then `greptile-budget.sh --consume` (an exhausted budget releases the grant). The daily budget (default **40/day**, `session-state.json`) is a runaway-loop bound, not a spend cap; the vendor-side cap is in `pricing-matrix.md` §Greptile. Exhausted → self-review, which never satisfies the gate. Before a 2nd or 3rd trigger: classify the previous review's findings; with no P0, do not re-trigger — reply naming HEAD, resolve, go to the merge gate (zero-P0 round reuse, issue #1000); with a P0, each re-trigger is a new paid review needing its own approval. Max 3 reviews per PR. 😕 or 10 minutes without a signal is a failure, not a routine fallback: surface it.

### Vendor offers

A vendor's paid on-demand review, credit purchase, cap raise, or metered add-on is always declined without the owner's approval, and the agent continues on the free path. An on-demand review may be accepted only when `paid-review-grant.sh --offer-check` answers `STATUS=consumed` — a matching grant whose approved USD price is at or above the offer (#1898). Purchases and cap raises stay with the owner. Worked example and the CodeRabbit wording: `cr-rate-limits.md` §Paid on-demand review offers.

### Account-side auto-review is out of scope

Paid tools can still review a PR from their own account settings — BugBot's vendor auto-review, or Greptile's dashboard auto-trigger. This harness cannot see or change those. A separate dashboard check should confirm both are off.

## CLI

```bash
.claude/scripts/review-tier.sh <pr_number> [--repo owner/name] [--base <ref>] [--config <path>] [--json]
.claude/scripts/review-tier.sh --files-from <file|-> [--labels a,b] [--config <path>] [--json]
```

The plain output is the gate name. `--json` returns one line:

```json
{"policy":"present","gate":"full","tier":"core","source":"base:main","error":null,
 "matches":[{"tier":"core","gate":"full","via":"path","count":1,"examples":["src/ledger/x.ts"]},
            {"tier":"docs","gate":"ci-only","via":"path","count":1,"examples":["docs/a.md"]}],
 "escalation":"on"}
```

The `via` field is one of `path`, `label`, `default`, or `truncated`. `escalation` is the [switch](#turning-off-escalation), present on every line.

The exit codes are `0` (resolved), `2` (usage error), `3` (PR not found), and `4` (read failure). The full contract is in `review-tier.sh --help`.
