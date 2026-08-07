# `escalate-review.sh` hotspot — diagnosis and KEEP decision

Reference for Issue #977 (`.claude/scripts/escalate-review.sh` churn hotspot). Not auto-loaded.

## The problem being read

`.claude/scripts/escalate-review.sh` was touched by 9 distinct merged PRs since
2026-07-20: #626, #709, #849, #883, #891, #945, #954, #963, #969.

The file is the authoritative CR→BugBot→Greptile escalation gate whose `STATUS=`
contract is consumed verbatim by four runtime callers: `phase-b-reviewer.md`,
`phase-a-fixer.md`, `cr-github-review.md` (rule prose and example), and
`monitor-mode.md` (monitor loop step 3 — runs `escalate-review.sh` each cycle and
acts on the `STATUS=` verdict). Non-runtime reference: the `escalate-review.sh`
entry in `.claude/reference/scripts-reference.md`. Splitting it would force
matching updates to every consumer; the contract-junction nature explains some
churn. Three additional concerns within the file also iterate independently.

## Churn attribution — per-section evidence

The 570-line file divides into four functional sections. Per-PR changes are
summarized below; all entries apply to the production script only (not the
companion test file, which was separately adjudicated in Issue #966 and split
into four concern suites in that PR).

### Section A — Gate-met / approval-freshness / review-substance block (lines ~122–294)

Implements the `gate_met` short-circuit: before evaluating CR→BugBot→Greptile
escalation, check whether CodeRabbit or CodeAnt already holds a valid APPROVED on
current HEAD, including freshness and substance guards.

| PR | Change | Driver |
|----|--------|--------|
| #626 | Added `gate_met` STATUS=, introduced `approval_valid` jq check for CR+CA | New CodeAnt reviewer support required guarding escalation before paid Greptile spend |
| #883 | Switched from boolean to `VALID_APPROVERS` list; added freshness guard (`HEAD_COMMIT_TS` fetch, `canon_ts` def, freshness filter) and review-substance guard via `review-substance.sh` | Timestamp retargeting after force-push (issue #836); substance guard for hollow approvals (issue #875) |
| #891 | Corrected `canon_ts` to strip zone suffix without rewriting, and to preserve fractional seconds; wired to `ts-normalizer-parity.test.sh` pin | Timestamp drift in lexicographic compare caused false staleness (issue #885) |

This block's logic does **not** appear in `merge-gate.sh` in the same form.
`merge-gate.sh` is the gate itself; this block is a lighter short-circuit that
mirrors its semantics to avoid routing a still-met gate into paid Greptile
escalation. The two are intentionally parallel, not duplicated.

### Section B — CR rate-limit / push-age grace window (lines ~296–368)

Evaluates whether CodeRabbit is still in a viable polling window.

| PR | Change | Driver |
|----|--------|--------|
| #709 | Changed CR rate-limit detection from commit-status `state` to description text; renamed `PUSH_TIMESTAMP` variable to use the commits endpoint | CR emits `failure` description not `pending` status during rate-limit (issue #708) |

This block is unique to `escalate-review.sh`; `merge-gate.sh` does not implement
a CR grace-window concept.

### Section C — BugBot check-run classifier (lines ~370–433)

Classifies the `Cursor Bugbot` check-run and `cursor[bot]` comments into
`BUGBOT_FAILED` / `BUGBOT_GENUINE` booleans and `BUGBOT_CHECK_PRESENT` sentinel.

| PR | Change | Driver |
|----|--------|--------|
| #849 | Added design note documenting the existing `BUGBOT_GENUINE` check-run success path (comment-only; the actual jq classifier predated this PR) | `merge-gate.sh` received the new check-run path; `escalate-review.sh` received only a cross-reference comment |
| #963 | Added `is_cursor_bugbot_check` predicate (name + `app.slug == "cursor"`); applied to both `$run` selector and `BUGBOT_CHECK_PRESENT` | GitHub allows any app to publish under any check-run name; publisher spoofing suppressed paid BugBot invite (issue #956) |

**Overlap with `merge-gate.sh`:** The `is_failure_text` regex and the concept of
matching `app.slug == "cursor"` also appear in `merge-gate.sh`'s BugBot path.
The two implementations share the same constants but diverge structurally:

- `escalate-review.sh` reads a pre-built STATE_PATH bundle (produced by
  `pr-state.sh`), runs a single unified jq classifier (~26 lines), and emits
  `$failed $genuine` as a tab-separated pair.
- `merge-gate.sh` reads separate bash variables (`CHECK_RUNS_JSON`,
  `PR_COMMENTS_JSON`, `ISSUE_COMMENTS_JSON`), uses a bash+jq hybrid (~150 lines),
  and sets `BB_CHECK_CLEAN`, `BB_CHECK_FRESHNESS_ERR`, `BB_CHECK_APP_MISMATCH`
  with side effects on `MISSING[]`.

Only PR #963 required sync edits to both files for this section. PR #849 was structurally different: `merge-gate.sh`
received the new check-run path while `escalate-review.sh` received only a
cross-reference comment.

### Section D — BugBot invitation / never-invited detection (lines ~435–556)

Determines whether BugBot was ever invited for the current HEAD SHA (as opposed
to having failed or not having been asked). This is the most-churned block.

| PR | Change | Driver |
|----|--------|--------|
| #945 | Added `iso_age_seconds` helper function, `BUGBOT_TRIGGER_TS` detection, `BUGBOT_TRIGGER_PRESENT` freshness compare, and the `switch_bugbot` never-invited branch | CURSOR_REVIEW_PAT absent → CI job greens without posting anything; zero BugBot footprint was indistinguishable from "BugBot not installed"; escalation spent paid Greptile for an uninvited reviewer (issue #935) |
| #954 | Changed never-invited guard to use `BUGBOT_CHECK_PRESENT` (live per-SHA check) instead of `BUGBOT_INSTALLED` (sticky per-PR cache) | `BUGBOT_INSTALLED=true` from an earlier SHA masked missing BugBot footprint on subsequent pushes; per-SHA question requires per-SHA evidence (issue #948) |
| #969 | Fixed `CACHED_BUGBOT_INSTALLED` jq path to use `if has("bugbot_installed") then` (handles explicit `false`); extended grace-window guard to also check `BUGBOT_CHECK_PRESENT` | `// ""` in jq returns `""` for `false` as well as null, so a cached `false` was ignored and the grace window applied regardless (no issue number; live regression after #954) |

This block has **no counterpart in `merge-gate.sh`**. The gate never needs to
distinguish "BugBot never invited" from "BugBot failed" — it only evaluates what
BugBot produced on this HEAD.

## Churn classification

| Section | PRs | Driver category |
|---------|-----|-----------------|
| A: gate-met / freshness / substance | #626, #883, #891 | New reviewer support + upstream bot timestamp behavior (retargeting, mixed zone spellings) |
| B: CR grace window | #709 | Upstream bot output format change (CR rate-limit signals) |
| C: BugBot classifier | #849 (comment), #963 | Publisher-spoofing risk (security) |
| D: BugBot invitation detection | #945, #954, #969 | Upstream CI/PAT behavior (missing auto-trigger) + per-SHA vs per-PR state bug |

**Churn driver summary:** All 9 PRs were reactive to upstream bot and CI behavior
changes — new reviewer (CA, #626), bot format changes (CR rate-limit, #709),
new BugBot delivery shape (#849), timestamp encoding quirks (#883, #891),
publisher-identity gap (#963), and PAT-provisioning gaps (#935, #948, #969).
None arose from code maintainability problems with the shared logic.

## Decision: KEEP — no extraction

**The evidence does not support extracting the BugBot check-run classifier.**

### Why extraction was considered

The CodeRabbit implementation plan (Issue #977) proposed extracting the BugBot
classifier into a shared `bugbot-classify.sh` stdin/stdout evaluator, citing
the `review-substance.sh` precedent and duplication between `escalate-review.sh`
and `merge-gate.sh`.

### Why extraction is not warranted

**1. Most churn is in unshared sections.**

7 of 9 PRs touched code that exists only in `escalate-review.sh`:
- Section A (3 PRs): the gate-met short-circuit is unique to this script.
- Section B (1 PR): CR grace window is unique to this script.
- Section D (3 PRs): BugBot invitation detection is unique to this script.

Only Section C changes (PR #963 and #849 as a partial comment)
involved code present in both scripts.

**2. The overlapping logic is small and structurally incompatible.**

The shared logic amounts to: the `is_failure_text` regex literal, the
`app.slug == "cursor"` identity constant, and the concept that
`conclusion:success + no-failure-comment = clean pass`. Each is a few lines.

The input structures are incompatible:
- `escalate-review.sh` receives a unified STATE_PATH bundle from `pr-state.sh`.
- `merge-gate.sh` receives separate bash variables populated by its own fetching
  logic.

A shared evaluator would require both callers to reshape their data. The reshaping
code would be longer than the shared logic it saves.

**3. The output contracts are incompatible.**

`escalate-review.sh` needs a binary `$failed / $genuine` classification for
escalation routing (fail-open: unverifiable publisher → "not BugBot", post free
`@cursor review`). `merge-gate.sh` needs three-way state with MISSING[] side
effects for gate-blocking messages (fail-closed: unverifiable publisher blocks the
gate). A shared evaluator must either pick one policy (breaking the other) or
accept a configuration flag (obscuring the intentional divergence that both files
document explicitly).

**4. Extraction cost exceeds savings.**

A new `bugbot-classify.sh` pure evaluator (analogous to `review-substance.sh`)
would require: a new ~60-line script, data-reshaping code in both callers,
new parity tests, and updates to the test suites that were just split into four
concern suites (Issue #966). The sync-burden reduction covers at most 1–2 future
PRs with the same publisher-identity class of change.

**5. The existing extraction precedents do not apply.**

The `review-substance.sh` precedent (#788/#814) extracted a pure deterministic
function called identically by both callers with the same input shape and the same
output semantics. The `_fetch_bot_approvals` extraction in `merge-gate.sh`
(#936/PR #1010) collapsed a 104-line duplicated CR+CA block into one
parameterized function inside the same file. Neither extraction changed the input
data structures. This situation has neither property.

The `escalate-review.test.sh` split (Issue #966) already addressed the most
impactful maintainability concern by splitting the test monolith into four
concern suites. No parallel change to the production script is needed.

### What would change this verdict

A future PR where the `is_failure_text` regex, the `app.slug` constant, or the
pass/fail classification logic diverges between the two scripts and causes a live
bug would reopen the case. At that point, a narrow inline constant extraction
(e.g., a shared `bugbot-constants.sh` sourced by both) may be warranted.

## Related

- Issue #966 — `escalate-review.test.sh` hotspot: verdict SPLIT into four concern
  suites plus shared fixture helper; production script unchanged
- Issue #936 — `merge-gate.sh` hotspot: verdict KEEP + extract `_fetch_bot_approvals`
- Issue #788 — `fixpr/SKILL.md` hotspot, structural precedent for extract-not-split
- Issue #814 — `subagent-orchestration.md` hotspot, precedent for extraction
- `.claude/scripts/review-substance.sh` — the pure-evaluator precedent CR plan cited
- `.claude/scripts/tests/ts-normalizer-parity.test.sh` — structural test pinning `canon_ts`
- `.claude/reference/merge-gate-reviewer-paths.md` — authoritative per-path gate semantics
