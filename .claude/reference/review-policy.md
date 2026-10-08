# Per-repo review policy (`## Review policy`)

A repo can declare **review tiers** in its own `.claude/pm-config.md`, so the review a PR needs follows the risk of what it touches rather than one harness-wide rule. This is issue #1724. Its increments, all landed, are:

| Issue | Part | Status |
|---|---|---|
| #1725 | Tier resolver | Landed |
| #1726 | Merge gate | Landed |
| #1727 | Deferred findings | Landed |
| #1728 | BugBot triggering | Landed |
| #1729 | Pipeline ceiling | Landed |

A follow-up, #1807, lets a repo [turn off escalation](#turning-off-escalation) to BugBot and Greptile altogether. A separate, account-wide control, the [daily cap on paid triggers](#account-level-daily-cap) (#1812), is set once for every repo rather than per repo.

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

| Path | On a `ci-only` or `ci+codeant-one-round` PR |
|---|---|
| `maybe-trigger-ai-review.sh` | Posts the CodeAnt and Graphite nudges only. It leaves the cursor step open, so a resumed run asks the tier again and posts only if the tier now invites BugBot. `--json` adds `bugbot_skipped: {"reason": "review_tier", "gate": …}`, on real and `--dry-run` runs alike. On a real run only, the field reads `{"reason": "refused_head", "gate": null}` when the refusal guard skipped the nudge instead: a dry run exits before that guard runs (Issue #1735). It is `null` when nothing was skipped. |
| `pr-preflight.sh` | Gives the cursor reviewer status `skipped-tier-excluded`, which counts as clean. |
| `/fixpr` Step 3b | Prints `[REVIEWERS] skipping @cursor review — review tier <gate> excludes BugBot`. |
| `cursor-review-pr-comment.yml` | The `tier-check` step runs the helper from the base-branch checkout with `--repo` and `--base`. The comment step skips on `excluded=true`, and a notice annotation says why. A base branch without the helper posts. |
| `escalate-review.sh` | Emits `STATUS=tier_gate` wherever it would have emitted `switch_bugbot`. |

`STATUS=tier_gate` means the review tier, not the escalation chain, governs the PR. The caller does not make BugBot the reviewer and posts nothing. It keeps the current reviewer and keeps polling, and `merge-gate.sh` applies the tier's gate. It is not a stop and not self-review. Every other verdict keeps its meaning, including `trigger_greptile` for a BugBot that reviewed the PR on its own and then failed. The one exception is a repo that [turned escalation off](#turning-off-escalation).

`pmm-act.md` and `wrap-merge-gate-recovery.md` post `@cursor review` only when BugBot already owns the PR. `tier_gate` keeps a lighter-tier PR from reaching that state.

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

The day is the **America/New_York** calendar day, the same boundary `greptile-budget.sh` uses. The UTC date never decides it. The helper lists the repos from `review-repos.sh`, reads every PR updated since ET midnight, and prices that day's events with `lib/review_ledger.py`, the `/review-stack-audit` ledger's own rules:

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
| `maybe-trigger-ai-review.sh` | Asks the cap last: the tier skip, then the refused-HEAD skip, then the cap. On `over` it skips `@cursor review` and still posts CodeAnt and Graphite. It leaves the cursor step open, as the tier skip does, so a resumed run asks again. `--json` and `--dry-run --json` report `bugbot_skipped: {"reason":"daily_cap","gate":null,"tally":{…}}`, plus the tally as `bugbot_daily_cap` whenever the cap was consulted, `unknown` included. |
| `/fixpr` Step 3b | Asks the cap after the same two skips. On `over` it appends `BugBot skipped: daily cap ($spent of $cap today)` under a `## Review notes` heading in the PR body, which it creates if absent. It does this once per HEAD, through `pr-body-review-note.sh`. |
| `cursor-review-pr-comment.yml` | **A known bypass.** CI posts one `@cursor review` per new HEAD and cannot read the account config from a runner. The ledger still measures that spend, so it counts against the cap for every later trigger. |
| #1749's trigger helper | Owns trigger order: CodeAnt first, BugBot once on a settled HEAD, and no Graphite on light tiers. This cap only gates the BugBot post. The per-repo daily check that #1749 proposes in its section 2.4 should call this helper rather than tally one repo. |

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
| Every BugBot trigger path | Inherits that answer unchanged: `maybe-trigger-ai-review.sh`, `pr-preflight.sh`, `/fixpr` Step 3b, and `cursor-review-pr-comment.yml`. Their messages still name the gate, because the helper's stdout is still the gate. |
| `escalate-review.sh` | Emits `STATUS=tier_gate` where it would have emitted `switch_bugbot`, `trigger_greptile`, or `budget_exhausted`. It never reads or consumes the Greptile budget. Earlier verdicts keep their precedence, including `polling_cr` inside a CodeRabbit retry window. |

Out of scope: CodeRabbit, CodeAnt, and Graphite triggers (#1749).

### What a `full` PR then needs

The merge gate does not change. On `full` and `legacy`, the reviewer requirement is still the CR path: a CodeRabbit or CodeAnt `APPROVED` on HEAD (`cr-merge-gate.md` Step 1). With escalation off there is **no fallback reviewer**. If neither bot approves, the PR keeps polling on `tier_gate` until one does, or until a human steps in. The lighter gates are unaffected, since they never needed BugBot or Greptile.

### Failure direction — known limit

The switch is read through `review-tier.sh`. If the tier cannot be resolved, the switch reads as **on**, and the chain runs as before. This happens when the resolver is missing, exits non-zero, or answers without a readable `escalation`. It is the same fail-open direction as [BugBot triggering](#bugbot-triggering) (#1728). A repo that turned escalation off can therefore still see one BugBot or Greptile hand-off while its policy is unreadable. `escalate-review.sh` says so on stderr when the resolver fails.

Only a literal `"escalation":"off"` skips. Any other value in the JSON, or a missing field from an older resolver, reads as on. `review-tier.sh` itself already turns an unclear value into `off`, so a typo in the file fails toward not spending.

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
