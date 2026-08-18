# Release Cadence — Agent-Initiated TestFlight Builds

Mechanism reference for issue #1169. Not auto-loaded; the rule corpus does not
carry this. Scripts: `.claude/scripts/release-{policy,decide,sweep}.sh`.

## The problem this solves

Four repos ship an iOS app — `skingod`, `still-point`, `longlove`, `inventory` —
and all four already had a working TestFlight pipeline. None of them had anything
that *decided* to use it.

Three waited for a human to apply a `release:ios` label to a merged PR, so their
release workflow fired on every merge and immediately skipped. `still-point` last
shipped a TestFlight build on 2026-07-24 despite merges since then triggering and
skipping the pipeline four times in one afternoon. The fourth, `inventory`, built
on every path-matching merge with no gate at all, cutting six builds in 2h44m on
2026-08-04 — two of them ten minutes apart, each one burning a TestFlight slot and
push-notifying every tester about a build that supersedes one they had not opened.

Both are reasonable settings of the same dial. The right setting depends on how
expensive this repo's build is, how fast PRs are landing, and whether the change
is even user-facing — none of which a human can hold at the right position by hand.

## The rule

One rule produces both behaviors with no mode switch:

> On merge, build if enough time has passed since the last build **finished**.
> Otherwise mark the repo as having a release pending, and cut it the moment the
> window opens.

When PRs land once an hour the window has always elapsed, so every merge ships.
When PRs land every five minutes, merges coalesce into roughly one build per
window. The behavior tracks the actual merge cadence instead of being told it.

Measuring from **completion**, not start, is deliberate: a window measured from
the start of a 13-minute build would let the next build begin while the first is
still uploading.

## Policy file — `.claude/release-policy.json`, in the app repo

Absent ⇒ **off**. Present with `"enabled": false` ⇒ off. No repo auto-releases
without an explicit opt-in, so a repo that never opts in behaves exactly as today.

```json
{
  "enabled": true,
  "min_interval": "auto",
  "trigger": "label:release:ios",
  "deferred_trigger": "workflow_dispatch:mobile-testflight.yml",
  "release_workflows": ["mobile-testflight.yml"],
  "suppress": { "paths": ["docs/**", "**/*.md", ".github/**", "web/**"], "labels": ["no-release"] },
  "expedite": { "paths": [], "labels": ["hotfix", "release:urgent"] },
  "max_builds_per_day": 8
}
```

| Field | Meaning |
|-------|---------|
| `enabled` | Master switch. Absent file or `false` ⇒ fully off. |
| `min_interval` | `"auto"`, a duration (`"45m"`, `"2h"`), or a bare number of minutes. |
| `trigger` | Mechanism used at merge time. `label:<name>` \| `workflow_dispatch:<file>` \| `none`. |
| `deferred_trigger` | Mechanism the sweep may use later. Defaults to `trigger` when that mechanism can be deferred; **unavailable for `label:`**. |
| `release_workflows` | Which workflow files are this repo's TestFlight pipeline — used for duration history and in-flight detection. Detected when omitted. |
| `suppress` / `expedite` | Path globs and labels defining the two classes. |
| `max_builds_per_day` | Tester-notification budget; feeds `auto` derivation. |

An unrecognized mechanism **fails closed** (exit 4) and says so. It is never
silently normalized to another mechanism — normalizing a trigger you do not
understand is how you cut a build through a path nobody reviewed.

## Trigger mechanisms are respected, not normalized

Verified against live repo state on 2026-08-18:

| Repo | Merge trigger | Deferred trigger | Notes |
|------|---------------|------------------|-------|
| `skingod` | `label:release:ios` | `workflow_dispatch:mobile-testflight.yml` | `pull_request: [closed]` + `merged == true && contains(labels.*.name, 'release:ios')`. Dispatch `reason` optional. |
| `longlove` | `label:release:ios` | `workflow_dispatch:mobile-testflight.yml` | Same gate. Dispatch `reason` **required**, and documented as an E2E-bypassing break-glass path — prefer the label. |
| `still-point` | `label:release:ios` | *(none available)* | `ios-testflight-auto.yml` has **no** `workflow_dispatch`. Its only other TestFlight path is the `ios-v*-build*` tag, which this automation never pushes. |
| `inventory` | `none` | `none` | `push: main` filtered to `app/mobile/**`. Already automatic — the correct action is to do nothing. |

No file in any app repo is touched by this change: no new workflow, build path,
or signing config anywhere.

### The App Store path is structurally excluded

`still-point`'s `ios-app-store-release.yml` and its semver `ios-v*` tags are never
triggered. This is enforced by construction, not by convention: the dispatch
mechanism can only name a workflow listed in `release_workflows`, declaring the
App Store workflow there fails closed (exit 4), and no code path in these three
scripts pushes a tag. TestFlight only.

## Why the label must be applied BEFORE the merge

The three label-driven workflows subscribe to `pull_request: [closed]` only.
Labeling an already-closed PR emits a `labeled` event, which they do not
subscribe to, and `gh run rerun` replays the *original* event payload — so a
`release:ios` label applied after the merge fires nothing at all.

**Consequence for AC4.** The issue asks for evaluation "inside the existing
post-merge flow." The label half cannot be post-merge, and the tag path that
would work post-merge is explicitly forbidden. So `/wrap` applies the label
immediately *before* `gh pr merge --squash` (Step 2.3a) and does everything else
after (Step 3.14).

The part of AC4 that carries the actual risk is honored strictly: the pre-merge
step blocks on nothing external, and every failure path in it is non-fatal — a
missing script, a malformed policy, a `gh` error, or any non-zero exit is logged
and the merge proceeds untouched. Release logic never gates or delays a merge.

If the label lands and the merge then fails, the label sits on an unmerged PR,
which the workflow ignores until that PR merges. Recoverable and harmless.

## `auto` interval derivation

From the repo's own history, over its `release_workflows`:

- **`median_build_min`** — median duration of **successful** runs from the last
  90 days, keeping only runs of **5–120 minutes**. Widens past the 90-day window
  only when it holds fewer than 3 samples, and falls back to failed/timed-out
  runs only when there are no successes at all.
- **`merges_per_day`** — merged PRs in the trailing 14 days ÷ 14, counted through
  the search API's exact `total_count`. A `gh pr list --limit` would silently cap
  the observed rate below the budget and make the budget term unreachable.

```text
compute_term = RELEASE_BUILD_FACTOR × median_build_min   # 3× — never build back-to-back
budget_term  = merges_per_day > max_builds_per_day ? 1440 / max_builds_per_day : 0
interval     = clamp(max(compute_term, budget_term, notify_floor), 15, 240)   # minutes
```

`notify_floor` is 20 minutes (`RELEASE_NOTIFY_FLOOR_MIN`). Both history axes are
load-bearing: build duration sets the compute floor, and merge rate is what
converts a tester-notification budget into a widened interval — binding only when
the repo would otherwise exceed that budget.

With no qualifying runs in history, fall back to a documented **60 minutes**
(`interval_source: "default"`). Derivations are cached in state with `derived_at`
and refreshed at most hourly (`RELEASE_INTERVAL_CACHE_MIN`).

An **explicit** `min_interval` is honored exactly as written — it is the owner's
override and is never clamped. Only a derived value is.

### Why those three filters

Each one is a real failure mode measured on these repos, not a precaution:

- **`skipped` runs excluded.** Measured 2026-08-18: **29 of the last 30** runs of
  `still-point`'s `ios-testflight-auto.yml` concluded `skipped`, median duration
  **1 second**, and not one of them built — a label-gated workflow firing on every
  merge and skipping. Including them derives a one-second build time, and a
  3× compute floor on that is no floor at all.
- **Sub-5-minute "successes" excluded.** GitHub concludes a run *successful* when
  its only real job never ran, so a run whose build job was skipped still reports
  success. The duration floor is what separates a build from a no-op.
- **A 90-day window, and a 120-minute outlier cap.** Stale runs from a pipeline's
  setup months ago outnumber the builds it does today, and one `still-point` run
  sat queued for three days (2026-07-03 → 07-06). The window is widened only if
  it cannot produce 3 samples.

**Median, not mean**, so a single anomalous run cannot move the result.

### Measured against real history (2026-08-18)

| Repo | Samples | Median build | Merges/day | compute | budget | **Interval** |
|------|---------|--------------|------------|---------|--------|--------------|
| `inventory` | 24 | 7 min | 2.5 | 21 | 0 | **21 min** |
| `still-point` | 6 | 17 min | 0 | 51 | 0 | **51 min** |
| `skingod` | 3 | 11 min | 10.2 | 33 | 180 | **180 min** |
| `longlove` | 0 | *(none)* | 1.1 | — | — | **60 min** (default) |

Four repos, four different intervals, each derived from that repo's own numbers.
The table also shows both terms doing real work: `inventory` and `still-point`
are compute-bound, `skingod` is the one repo whose merge rate exceeds its
notification budget so the budget term binds, and `longlove` has no qualifying
build in history and takes the documented fallback.

These are observations, not fixtures — they move as the repos do. The offline
suites pin the *formula*; this table is what it produced on the day it shipped.

## Decision rule

At merge (with `--pr N`) and at sweep time (repo only), in order:

1. No policy file, or `enabled: false` → `disabled`, inert.
2. No release pipeline detected → `no_pipeline`, inert. Detection is by the
   presence of a TestFlight workflow, never a hardcoded repo list, so a repo with
   no iOS app is inert without having to be listed anywhere.
3. Changed paths + labels all in the *suppress* class → `suppressed`, and **no
   pending marker is set**. Partial matches are not suppressed: one app-touching
   file in a docs-heavy PR still counts.
4. *Expedite* class → `build_now`, window ignored. Checked before suppress: an
   urgent change that also looks docs-shaped is still urgent.
5. A release run is `queued`/`in_progress`, or our own in-flight record is
   unresolved → `in_flight`; set/keep the pending marker. **The concurrency guard
   outranks expedite** — expedite skips the window, not the guard.
6. `now - last_build_completed_at >= interval` → `build_now`; else `pending`.

### Ground truth, not bookkeeping

`last_build_completed_at` and in-flight status are read from the repo's **GitHub
run history**, not from our own state. Builds cut outside this automation — a
manual dispatch, `inventory`'s automatic path — are therefore respected, and the
state self-heals after any gap.

### Phases

The mechanism decides *when* it can act. A phase mismatch is a no-op, never a
silent wrong-time trigger.

| Phase | Acts for | Why |
|-------|----------|-----|
| `pre-merge` | `label:` only | GitHub will not re-fire `pull_request: [closed]` for a label on a closed PR. |
| `post-merge` | `workflow_dispatch:`, `none` | A dispatch before the merge would build the pre-merge default branch. |
| `now` (default) | deferred mechanism | Sweep/manual context: the PR is long since merged. |

## Durable state

`~/.claude/session-state.json` at `.repos["<owner>/<name>"].release`:

```text
{
  pending:         { since, pr, count, reason, notified_at? } | null,
  in_flight:       { pr, mechanism, triggered_at, detail, run_id, awaiting_run } | null,
  last_seen_build: { run_id, conclusion, completed_at },
  interval_minutes, interval_source, derived_at
}
```

Written only through `session-state.sh --raw-path --set` — the lock-respecting
path required by `handoff-files.md`. `--raw-path` is required because auto-scoping
only rewrites `.prs` / `.root_repo`; reads use `--get --raw-path` and never
`--session-view`, which projects only those two keys and would silently report the
whole `.repos` block as absent.

### State writes fail loudly

A discarded write here would be the worst failure in the system: `release-decide`
would report `pending` — "a sweep will cut this later" — while the marker the
sweep reads never landed, and the merge would silently never ship. That is the
exact failure mode this issue exists to end, reintroduced one layer up.

So both scripts propagate the write's exit code (`5` missing sibling library, `6`
lock timeout) and keep its stderr:

- `release-decide.sh` blocks (exit 3) rather than reporting a `pending` it cannot
  honor, and carries the underlying error in `state_write_error`.
- When a trigger already fired but its bookkeeping did not, **both** facts are
  reported: `decision: build_now` with `applied: true` and the detail of what
  fired, plus exit 3 — because without the in-flight record nothing will follow
  that build to a terminal state.
- The derived-interval cache is the one write allowed to fail without blocking:
  it only saves a re-derivation and can never make a decision wrong.
- `release-sweep.sh` records a `state_write_failed` attention event and continues
  to the next repo — one repo's unwritable state is not a reason to stop
  following every other repo's builds.

## The sweep

`release-sweep.sh` is the half that outlives the thread that started it. Per repo
carrying release state:

1. **Resolve the in-flight build to a terminal state.** A trigger that produced no
   run within `RELEASE_RUN_APPEAR_GRACE_MIN` (default 15) is reported as a trigger
   that did not take. A completed run that failed, timed out, was cancelled, or
   was **skipped** is reported. A skipped run matters most: the trigger fired, the
   workflow's own guard did not match, and nothing shipped — the silent failure
   this whole issue is about. A still-running build prints nothing; the next sweep
   resolves it.
2. **Cut a pending build whose window has opened**, through
   `release-decide.sh --apply --phase now`, using the deferred mechanism. Never
   while a build is still processing.

A pending marker on a `label:`-only repo (i.e. `still-point`) cannot be cut by the
sweep. It is reported **once per marker** — repeating it every tick would be noise
— the marker is kept, and the repo's next merge ships the accumulated work.

### Invocation surfaces

None of these depends on the thread that created the marker:

| Surface | When |
|---------|------|
| `session-scheduling-reconcile.sh` | Session start — the repo's documented cross-session durability path (#827). |
| `/pr-monitor-and-manage` | Once per fleet tick, on its persistent `Monitor` (the approved recurring primitive). |
| `/wrap` Step 3.14 | After each merge. |

`CronCreate` is not used: it does not reliably fire and is session-scoped
(`scheduling-reliability.md`).

## Output

Per `CLAUDE.md` output rules, a cut build is a single line:

```text
cut TestFlight build — auerbachb/skingod (PR #412)
```

A skip, a suppression, a pending marker, a healthy in-progress build, and a
successful completion all print nothing. Failures and blockers print one terse
line each.

## Deliberately out of scope

- **Consumption as a signal.** The most honest input is whether anyone actually
  installed and used the previous build — building faster than feedback is
  consumed is pure waste. That needs App Store Connect API access. The
  "don't build while the last one is still processing" rule is the cheap proxy.
- **Version numbers.** Every pipeline already owns its own versioning (committed
  `project.yml` in `still-point`, EAS remote auto-increment in `inventory`,
  `package.json` in the others). This automation has no opinion about them.
- **The interval floor's real basis.** Compute cost and tester-notification
  fatigue are different axes, and the second is harder: a 90-second build is cheap
  in runner minutes and still annoying at twelve pings a day. The floor is
  notification-driven with compute as a secondary input; worth revisiting once
  there is real data on how often builds get installed.

## Testing

`.claude/scripts/tests/release-{policy,decide,sweep}.test.sh` — offline, `gh`
faked, auto-discovered by `hook-scripts.yml`. The decide and sweep suites use the
**real** `session-state.sh` against a temp `$HOME`, so durable writes are
exercised rather than mocked; the fixture must therefore mirror the repo layout
including `lib/repo-normalizer.sh`, without which `session-state.sh` exits 5 and
every write silently fails.

Both suites also assert the failure paths directly — a stubbed `session-state.sh`
that exits non-zero must produce a blocked decision or an attention event, and the
identical call with writes working again must be clean, so those tests cannot pass
for the wrong reason.
