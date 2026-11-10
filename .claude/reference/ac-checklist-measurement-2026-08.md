# AC Checklist Effectiveness — Measurement (2026-08-26)

Point-in-time measurement for Issue #1333: *across merged PRs, has the mandatory
AC / Test-plan verification at merge time ever caught something CI, the AI
reviewers, or manual testing did not?*

**This file measures. It decides nothing and changes nothing.** No AC machinery
was edited to produce it — `/issue-maker` AC generation, the PR Test-plan
requirement, `cr-merge-gate.md` Step 2, and the `ac-gate` CI workflow are all
untouched. The decision belongs to the repo owner; §7 lays out the options
without enacting any of them.

---

## 1. Method

### Sample

The **last 100 merged PRs**: `#1131` – `#1350`, merged `2026-08-08T04:56Z` –
`2026-08-26T18:01Z` (an 18-day contiguous window). Selection is the whole
contiguous tail of merged PRs, not a filtered subset — nothing was excluded on
content, author, or outcome, so the window cannot be cherry-picked.

```bash
gh pr list --state merged --limit 100 \
  --json number,title,body,mergedAt,author,headRefName > merged100.json
```

Checkbox state was then computed **locally** from that one payload. Boxes were
classified with the same semantics `ac-gate.sh` enforces: a `- [ ]` outside an
exactly-spelled `## Post-merge verification` heading is in-scope; inside it, it
is exempt. Counting was a single `jq` fold over each body's lines, matching
`^[ \t]*[-*][ \t]+\[[ xX]\]` for a box and `^[ \t]*[-*][ \t]+\[[xX]\]` for a
ticked one.

### Second population: the catch corpus

Compliance counts cannot answer the efficacy question (§3). A separate
population was assembled of **every recorded event where merge-time AC
verification found something wrong** — drawn from the durable memory entry
`stale-ac-text-at-merge-time`, which exists specifically to record these. Each
event was then **re-verified against the merged PR artifact** rather than
trusted, via one batched GraphQL call for the seven PRs outside the window:

```bash
gh api graphql -F query=@q.txt   # aliased pullRequest(number:) × 7
```

### Caveats, stated up front

- **`gh` returns the *current* body, not the merge-time body.** Ticking happens
  pre-merge by contract, and post-merge body edits are rare, so current ≈
  merge-time — but a post-merge edit would be invisible here.
- **The catch corpus is self-reported** by the same agent lineage being
  evaluated. It is a *lessons* file, so its bias runs toward over-recording
  catches, not under-recording them. §5 leans on that direction deliberately.
- **18 days is recent, not historical.** The owner's prior spans a far longer
  period. The `ac-gate` CI layer in particular is only ~2 days old (§4), so its
  measurement window is genuinely short.
- **No token figures are invented.** §6 reports only structurally measurable
  cost surfaces.

---

## 2. What the sample shows

| Measure | Value |
|---|---|
| PRs sampled | 100 |
| PRs carrying a `## Test plan` heading | **100 / 100** |
| Total checkboxes | 849 |
| Checked at merge time | **848** |
| Unchecked, in-scope | **1** |
| Unchecked, exempt | 0 |
| PRs using `## Post-merge verification` | **0** |
| Boxes per PR | mean 8.49, median 8, range 2–21 |

The single unchecked in-scope box is **PR #1292**, and it is not a catch — it is
an annotated deliberate deferral that merged as-is:

> `- [ ] Re-run /review-stack-audit and confirm any drift it reports matches the
> blockers found here. (Not ticked: /review-stack-audit requires an
> authenticated session state that the audit skill itself owns …)`

So across 100 consecutive merges, the checklist produced **zero merge-time
blocks for unfinished work**. Compliance is essentially total: 99.9% of boxes
ticked, 100% of PRs carrying the section.

---

## 3. Compliance is not efficacy

A ticked box proves an agent ticked it. It does not prove the agent verified
anything, and the 848 figure must not be read as 848 verified criteria.

This matters more here than in a typical process audit, because of *who* does
the verifying. `cr-merge-gate.md` Step 2 has the merging agent read the Test
plan of the PR **its own session authored** and confirm its own work. That is
the least independent reviewer position available, and it is the one the process
makes mandatory and blocking.

The efficacy question therefore cannot be answered from tick rates at all. It
has to be answered from the catch corpus.

---

## 4. Classification of every AC-verification event found

Taxonomy per Issue #1333: `caught-real-defect` / `blocked-then-fixed` /
`corrected-false-claim-no-code-change` / `pure-formality`.

### 4a. Events where merge-time AC verification found something wrong

All ten events — across nine PRs, since #882 contributes two — re-verified
against the merged artifact. All ten landed as **edits to the PR body's prose**.

| PR | What AC verification found | Resolution | Class | Code changed? |
|---|---|---|---|---|
| #882 | Box read `suite is 92/92`; a later phase took it to 94 | Text corrected to `94/94` | corrected-false-claim | **No** |
| #882 | Phase B added `--ref` exit-3 behavior that **no box covered** | Box added, then verified | corrected-false-claim | **No** — already implemented + tested (`18h`/`18i`) |
| #929 | `shellcheck clean (exit 0)` read false under bare `shellcheck` | Invocation corrected to `-x`; multiset diffed vs `main` | corrected-false-claim | **No** |
| #931 | "no `gh`/`Cron` token appears" disproved by the script's own header comment | Rescoped to "no *invocation* of either" | corrected-false-claim | **No** |
| #934 | "63 bash suites" went stale sideways — `main` had added two | Rescoped to "green *on this branch*" | corrected-false-claim | **No** |
| #951 | "140 pre-existing assertions" — real merge-base count was 124 | Corrected to 124 + label `comm` | corrected-false-claim | **No** |
| #954 | "remains accurate" about an **untouched** file, disprovable twice | Rescoped to "no less accurate than before"; doc defect filed separately | corrected-false-claim | **No** |
| #963 | Parity clause "all of which pass against `main`" — 13 of 19 fail *by construction* | Split forward-only proof from real parity controls | corrected-false-claim | **No** |
| #1338 | Box cited PRs as evidence for a classification they did not carry | Citation split by evidence kind, corrected | corrected-false-claim | **No** |
| #1349 | Parenthetical claimed deferred scope was "owned by a sibling PR"; the sibling never carried it | Rescoped to measured truth | corrected-false-claim | **No** |

Verification samples (merged bodies, confirming the correction landed as text):

- #882 line 53 → `All 62 pre-existing assertions still pass unchanged; suite is 94/94`
- #954 → `*(Clause corrected at merge time: …)*` — the PR body self-documents the event
- #931 → `its sole gh/Cron occurrence is the header comment stating there is no such call — no invocation of either`

**Totals: `caught-real-defect` 0. `blocked-then-fixed` 0.
`corrected-false-claim-no-code-change` 10 events across 9 PRs.**

Within the 100-PR window itself, the catch events are #1338 and #1349 — **2
events out of 849 boxes (0.24%)**, both prose corrections.

### 4b. What the other three layers would have caught

In all ten events: **nothing, because there was nothing wrong with the code.**
Each defect existed only in the PR body's description of correct, already-tested
work. CI, the AI reviewers, and manual testing do not read Test-plan prose for
accuracy, so none of them would have caught these — and none of them needed to.

The closest thing to a genuine catch is #882's second row: scope added in a later
phase that no box covered. That is the one event that surfaced *undescribed
work* rather than *wrong prose*. Even there the behavior was already implemented
and already covered by tests `18h`/`18i` in a suite CI ran green at 94/94 — CI
covered the code; AC covered only its description.

### 4c. The CI gate's actual bite

`ac-gate.yml` landed on `main` **2026-08-24** (PR #1291). Since then:

| Conclusion | Runs |
|---|---|
| success | 69 |
| failure | **6** |
| startup_failure | 1 |

All six failures were **transient mid-PR states**, on four branches:

- `issue-1281-ac-gate` ×2 — the AC gate failing on **its own PR** → merged as #1291
- `issue-1325-window-planning` → merged as #1334
- `issue-1303-cr-drift-baseline` → merged as #1338
- `issue-1266-persist-allow-nonauthor` ×2 → PR still open

The failure text is the ordinary one (`AC gate: FAIL — PR #1338 has unchecked
acceptance-criteria box(es) …`). Every branch that merged did so with **all
boxes ticked and no code change attributable to the gate**. The gate fired on the
expected state of a PR whose work is not yet verified, and was satisfied by
ticking.

**Zero of six ac-gate failures represented unfinished work caught at merge time.**

---

## 5. Counter-example hunt (search method and result)

The finding is only as strong as the effort spent trying to refute the owner's
prior, so the counter-example search is documented in full.

**Shapes searched for:** AC verification that (a) found a real unmet criterion
and blocked or fixed code pre-merge, (b) corrected stale-but-load-bearing claims
in a way that changed what shipped, (c) caught scope silently dropped between
phases.

| # | Search | Result |
|---|---|---|
| 1 | All 849 boxes in the 100-PR window for unchecked-at-merge state | 1 hit — an annotated deferral (§2), not a catch |
| 2 | Cached bodies regex-swept for correction language (`corrected the box\|AC text\|stale criterion\|rescoped the claim\|…`) | 1 hit (#1224), a machinery PR — no catch |
| 3 | Cached bodies for `merge.?gate step 2\|AC verification\|acceptance criteria verif` | 0 hits |
| 4 | `grep -rniE 'AC (verification\|check\|gate) (caught\|found\|blocked)\|checklist caught'` over `.claude/reference/` + `.claude/rules/` | **0 hits** |
| 5 | `gh search prs --merged --match body 'AC verification'` (repo-wide, all history) | 16 hits — **all** PRs that *build* the AC machinery (#312, #737, #761, #997, …); none records a catch |
| 6 | `gh search prs --merged --match body 'Post-merge verification'` | **2 PRs in all repo history** — the exemption hatch is effectively unused |
| 7 | Every event in the `stale-ac-text-at-merge-time` memory, re-verified against merged artifacts | 10 events, **all** prose-only (§4a) |
| 8 | `ac-gate` CI failure history since it shipped | 6, **all** transient (§4c) |

**Result: no counter-example found.** Not one event in which merge-time AC
verification changed what merged, as opposed to what the paperwork said about
it.

The strongest form of this argument is search #7. The memory entry
`stale-ac-text-at-merge-time` exists *precisely because* AC verification kept
finding things — it is a corpus curated to record AC catches, by the agents
performing them, and it is the place a code-changing catch would certainly have
been written down. It contains ten catches and **zero** that touched code.

### 5a. A datapoint in the opposite direction

PR **#1336** (merged today) is the control case. Its `ac-gate` passed — it is
absent from the six failures — while `Hook scripts` CI **failed** at
`2026-08-26T15:58Z` on a real defect that had to be fixed before merge. On the
same PR, on the same day: the checklist said everything was fine; CI had the
bite.

---

## 6. Cost surfaces (structural, not estimated)

No token figures are invented. What is measurable:

| Surface | Measure |
|---|---|
| **Merge verification** | ~**8.5 boxes** read and verified against source **per merge**, every merge, forever (mean of 849/100) |
| **Rule corpus** | `cr-merge-gate.md` Step 2 = **177 words** of the auto-loaded corpus; **18 AC mentions** across `CLAUDE.md` + 6 rule files |
| **Scripts / CI** | **1,530 LOC** — `ac-checkboxes.sh` 434, `ac-gate.sh` 334, `ac-gate.test.sh` 728, `ac-gate.yml` 34 |
| **Blast radius** | **36 files** reference `ac-checkboxes.sh`, `ac-gate.{sh,yml}`, or `--ac-verified`, this report excluded — 10 skill files (across 9 skills), 1 agent, 7 scripts, 4 test files, 11 reference docs, 2 rule/README files, 1 workflow |
| **Issue creation** | `/issue-maker` generates an `## Acceptance Criteria` section for **every** issue |
| **PR creation** | A `## Test plan` section is mandatory on **every** PR — present in 100/100 sampled |
| **Provisioning** | `repo-bootstrap.sh` installs the 4-file AC gate set into other repos (#1282); 4 downstream repos carry an AC-style gate |

The merge-verification row is the recurring cost; the rest is one-time or
per-artifact.

---

## 7. What this measurement supports — options, not a decision

The evidence answers the question that was asked, and the answer is consistent
with the owner's prior, sharpened:

> Across 100 consecutive merges (849 boxes) and every recorded catch event in
> repo history, merge-time AC verification has **never** changed what merged. Its
> ten recorded catches were all corrections to the accuracy of the PR body's own
> prose. Its CI gate has failed six times, all transient. The one same-day
> control shows CI catching a real defect on a PR whose AC gate passed.

The sharpest way to state it: **the checklist's only measured catches are of
defects in the paperwork the checklist itself mandates.** Remove the checklist
and eight of the ten recorded catches cease to be possible, because the false
statements they corrected would never have been written.

Two honest qualifications against over-reading this:

1. **The prose corrections were not worthless.** A merged PR body is a durable
   record; #951's "140 pre-existing assertions" would have been permanently
   wrong. The question is whether accuracy of a self-authored record justifies a
   blocking gate on every merge — a *value* judgment the data cannot make.
2. **The window is 18 days**, and `ac-gate` CI is ~2 days old. This measures the
   current era well and the historical era not at all.

### Options for the owner

| Option | What it means | What the evidence says |
|---|---|---|
| **Keep** | Status quo on all four surfaces | Requires valuing PR-body accuracy above the per-merge cost; no defect-catching case survives the data |
| **Trim to specific surfaces** | e.g. keep the `## Test plan` section as unenforced narrative prose ("here is how I verified this"), drop the blocking merge-time walk and/or the CI gate | Directly supported: the section is universally present and cheap; the *blocking walk* is the surface with zero measured yield. CodeRabbit's plan reached the same split independently |
| **Rip out** | Remove generation, the PR requirement, merge-gate Step 2, and the CI gate; merge gate retains CI, review approval, resolved threads | Supported by every measurement here; the largest single cost (a ~8.5-box verification per merge, forever) has no measured catch to justify it |

Two open questions from Issue #1333 that this measurement informs but does not
settle, and that any decision should answer explicitly rather than by omission:

- **Downstream repos.** Four (`inventory`, `skingod`, `meeting_insights_and_actions`,
  `longlove`) carry an AC-style gate. `inventory#597` was already closed as moot
  by the owner on 2026-08-25.
- **Test-plan prose vs the checkbox ritual.** These are separable, and the
  evidence separates them cleanly: the section is universally adopted; the
  blocking verification is what has no measured yield.

**Next step if the decision is removal:** a decision record plus an ordered
removal plan — a separate issue and a separate PR. Neither is in scope here, and
nothing in this measurement has changed any behavior.

---

## Reproducing this

```bash
# 1. Sample (one API call)
gh pr list --state merged --limit 100 \
  --json number,title,body,mergedAt,author,headRefName > merged100.json

# 2. Compliance counts — local, no API
jq '[.[] | {n: .number,
     total:   ([(.body // "" | split("\n"))[] | select(test("^[ \t]*[-*][ \t]+\\[[ xX]\\]"))] | length),
     checked: ([(.body // "" | split("\n"))[] | select(test("^[ \t]*[-*][ \t]+\\[[xX]\\]"))]  | length)}]' merged100.json
# (full fold, incl. the Post-merge exemption state machine, in §1)

# 3. CI gate bite
gh run list --workflow=ac-gate.yml --limit 100 \
  --json conclusion --jq 'group_by(.conclusion)|map({(.[0].conclusion):length})'

# 4. Counter-example sweeps
grep -rniE 'AC (verification|check|gate) (caught|found|blocked)|checklist caught' \
  .claude/reference/ .claude/rules/
gh search prs --repo auerbachb/claude-code-config --merged --match body 'AC verification' --limit 30
gh search prs --repo auerbachb/claude-code-config --merged --match body 'Post-merge verification' --limit 50

# 5. Blast radius (§6) — this report itself excluded, so the figure is the
#    pre-existing surface rather than a self-reference
grep -rlE 'ac-checkboxes\.sh|ac-gate\.(sh|yml)|--ac-verified' \
  --exclude-dir=.git --exclude-dir=worktrees . \
  | grep -v 'ac-checklist-measurement-2026-08\.md' | wc -l
```

## References

- Issue #1333 — the question, the owner's recorded reasoning, and CodeRabbit's plan
- `.claude/rules/cr-merge-gate.md` Step 2 — the blocking verification measured here
- `.claude/reference/ac-gate.md` — `ac-gate.sh` exemption logic and exit codes
- `stale-ac-text-at-merge-time` (durable memory) — the catch corpus of §4a
- PR #1291 (#1281) — the AC gate; PR #1326 (#1282) — its provisioning
