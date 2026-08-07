# Babysit-PR Hotspot Decision

Reference for Issue #986 (`.claude/skills/babysit-pr/SKILL.md` churn hotspot). Not auto-loaded.

## Executive summary

### Verdict: **KEEP** the single skill file unchanged

Keep `.claude/skills/babysit-pr/SKILL.md` intact. The 9 merged PRs in the hotspot window were
driven by scheduling substrate evolution and feature additions — not by unrelated concerns
accumulating independently. Extraction into a `babysit-pr/references/` directory was proposed by
the CR plan but is blocked by an existing CI test suite that pins 18+ correctness invariants
directly in `SKILL.md`. Moving those sections would break CI without improving coverage.

No operative change is applied. The decision record is the only deliverable.

## 1. Trigger and diagnosis

The churn detector recorded nine merged PRs touching `babysit-pr/SKILL.md` since 2026-07-21:
PRs #616, #641, #690, #739, #761, #825, #867, #922, and #982. At diagnosis time the file was
859 lines and 7,509 words — the largest single `SKILL.md` in the repo, and over the 2,000-word
per-file soft warning. Size alone does not determine the verdict; the churn source does.

### Per-PR attribution (section-level, with evidence from `gh pr diff`)

| PR | Title | Sections touched | Churn driver |
|----|-------|-----------------|--------------|
| #616 | fix: gh pr view --json merged errors | A1 (validation bash), T1/T3 (state fetch bash) | Bug fix: `merged` field removed from `gh pr view --json` call |
| #641 | fix: portable date parsing | Bash helpers block (new `to_epoch()` + `bump_parse_failure_counter()`), state schema | Feature: portable date parsing + bounded parse-failure counters to fix corrupted TTL/age math |
| #690 | feat: opt-in auto-resolve conflicts | Frontmatter description, arguments table, safety boundaries, state schema, T3 classification table, T4 `conflicting` dispatch (new section) | Feature: `--auto-resolve-conflicts` flag + new `conflicting` state class + `conflict_streak` bookkeeping |
| #739 | feat: hard authorship guard | Safety boundaries | Feature: authorship guard bullet (enroll = "touch"; `pr-authorship.sh` gate) |
| #761 | feat: auto-run no-protection admin merge | T3 classification table row 5 | Feature: admin-merge auto-run for BEHIND-only blocker (`admin-merge.sh --auto-plain`) |
| #825 | fix: correct CronCreate durability claims | Arguments table (`--durable` description), A3 arm prose | Correction: CronCreate is session-only, `durable: true` is a no-op |
| #867 | feat: replace CronCreate with /loop | Frontmatter description + argument-hint, arguments table (`--durable` → strikethrough row), state schema (drop `durable`/`cron_job_id` fields), A3 arm prose | Removal: `--durable`/CronCreate path replaced with `/loop` only |
| #922 | fix: CronCreate zero ticks — route polls to /loop | Frontmatter, arguments table, A3 arm prose (dynamic `/loop` mode detail), T5 re-arm cadence prose | Fix: documented `/loop` dynamic mode nuance post-#914 controlled probe |
| #982 | fix: move recurring polls to Monitor | A3 arm prose (major rewrite: `/loop` → persistent `Monitor`), T5 cadence re-arm (Monitor identity, generation validation), state schema, verbatim-block tests added | Migration: full Monitor architecture; Monitor task ID + generation identity pair; stale-reclaim and rollback protocol |

### Churn cluster analysis

Three distinct drivers produced the nine edits:

**Driver 1 — Scheduling substrate evolution (PRs #825, #867, #922, #982):**
All four touched A3 (arm prose) and the arguments table as one logical progression:
`CronCreate (--durable)` → `/loop (default)` → `/loop dynamic mode` → `persistent Monitor`.
The scheduling change required synchronized updates to arguments, arm-mode prose, T5 cadence
re-arm detail, and (in #982) the session-state schema and CI tests. Future scheduling changes
will require the same multi-section update regardless of where the prose lives.

**Driver 2 — Feature additions (PRs #690, #739, #761):**
Each added a new capability that naturally spans multiple sections of the state machine:
`--auto-resolve-conflicts` required arguments + safety + classification + dispatch;
the authorship guard required one safety bullet;
the admin-merge auto-run required one classification-table row.
These are coherent coupled additions, not unrelated concerns accumulating.

**Driver 3 — Bug fixes (PRs #616, #641):**
Targeted corrections: the `merged` field removal from `gh pr view`, and the portable
date-parsing / bounded-counter fix. Small, surgical, and unlikely to recur as classes.

## 2. Options considered

### Option 1: Split the skill into multiple skill files

Create separate skills for arm mode, tick mode, and reporting.

**Rejected.** No `SKILL.md` split precedent exists in the repo. Every caller depends on the
single arm/tick step contract, step numbering, and footer tokens. A physical split would force
synchronized caller migration and duplicate the frontmatter. The 859-line file has a clear
internal structure (ARM / TICK / T-END) that already localizes concerns without splitting callers.

### Option 2: KEEP + extract prose into `babysit-pr/references/`

Following the `pr-monitor-and-manage/references/pmm-*.md` precedent, move concern-localized
prose (lifecycle mechanics, classification, terminal reporting) into:
- `babysit-lifecycle.md` — A2 freshness/TTL/reclaim math + T5 cadence backoff + Monitor re-arm
- `babysit-classify.md` — T1–T1c fail-closed read sequence + T3 6-row classification table
- `babysit-reporting.md` — T-END conflict-specific terminal report formats

**Rejected.** This option conflicts with an existing CI test suite
(`.claude/scripts/tests/scheduling-primitive-alignment.test.sh`) that pins 18+ correctness
invariants directly in `SKILL.md` via `require_text .claude/skills/babysit-pr/SKILL.md '...'`
checks. The checked strings fall entirely within the sections the extraction would move:

- A2: `refuses re-arm regardless of tick age`, `a stale reclaim **must stop the exact
  \`$RETAINED_TASK_ID\` with \`TaskStop\`**`, `TASK_STOP_SUCCEEDED=true only when that exact
  tool call succeeds`
- A3: `babysit.monitor_task_id`, `--monitor-generation $MONITOR_GENERATION`, `If that
  task-ID publication fails`, `babysit.monitor_generation=\"$NEW_MONITOR_GENERATION\"`
- T0: `if [[ "$BABYSIT_INTERNAL_TICK" == true ]]; then`, `"$TICK_GENERATION" !=
  "$RECORDED_GENERATION"`, `TICK_GENERATION="$_BABYSIT_ARG"`
- T5: `stop the exact current Monitor`, `Before comparing cadences, read the exact`,
  `if (( STREAK >= 3 )); then EFFECTIVE_MIN=$WIDE_MIN; else EFFECTIVE_MIN=$BASE_MIN; fi`,
  `monitor_task_id=$NEW_MONITOR_TASK_ID`, `Before that stop, atomically set
  \`stop_requested=true\``, `known-stopped old identity and set \`active=false\`,
  \`stop_requested=false\``
- T-END: `Run that atomic cleanup only after \`TaskStop\` succeeds.`

These tests were added by PR #982 precisely because these sections encode correctness-critical
safety properties (generation mismatch detection, atomic task-ID publication, rollback teardown).
Moving the text to reference files would require re-pointing all 18 tests to the new paths, and
reference files are not governed by the same enforcement mechanism. The net effect would be
reduced safety coverage with no behavioral improvement.

The `pr-monitor-and-manage` extraction precedent does not apply here because `pmm-lifecycle.md`
does not contain verbatim-guarded text. The CI gate that makes this file different from PMM was
deliberately installed by the same PR that drove the largest single edit to the file.

### Option 3: KEEP + dedup only (like `monitor-mode` #984)

Identify duplicated prose and remove restatements in downstream files.

**Examined.** No downstream file replicates the babysit-pr arm/tick contract or the backoff
formula. `scheduling-reliability.md` references `babysit.cadence_base_minutes` (read by
`polling-backoff-warn.sh`) and the `max(15m, 3×base)` formula, but the formula is defined in
SKILL.md and applied in the hook — not duplicated. No duplication removal is available.

### Option 4: KEEP unchanged

Record the diagnosis and verdict; make no operative changes.

**Chosen.** The file is correct and consistent. CI guards the critical invariants. The churn was
necessary and is self-explanatory in hindsight. The scheduling substrate appears stable after
PR #982 completed the Monitor migration; future edits are expected to land in the new sections
(A3/T5 Monitor identity, T0 generation validation) at a lower frequency now that the migration
is complete.

## 3. Ownership boundaries

| Content | Canonical owner | Non-owner |
|---------|-----------------|-----------|
| Arm/tick state machine (A1–A3, T0–T7, T-END) | `.claude/skills/babysit-pr/SKILL.md` | Do not reimplement in downstream skills |
| Safety boundaries (authorship, branch-protection, dismiss, resolve-thread) | `.claude/skills/babysit-pr/SKILL.md` `## Safety boundaries` | `safety.md` owns the cross-cutting rule; SKILL.md applies it to this skill |
| Per-tick Monitor identity (task ID + generation pair) | `.claude/skills/babysit-pr/SKILL.md` A3 + T0 + T5 + T-END | `scheduling-primitive-alignment.test.sh` verifies the invariants; do not replicate the prose |
| Stable-state backoff formula `max(15m, 3×base)` | `.claude/skills/babysit-pr/SKILL.md` T5 | `scheduling-reliability.md` references the formula; does not own it |
| `.prs["<N>"].babysit` session-state schema | `.claude/skills/babysit-pr/SKILL.md` (schema block) | `babysit-pr-stop/SKILL.md` reads and writes the same fields — any schema change must update both |
| Poll-lifecycle actions (`last_cron_action` historical field) | `.claude/skills/babysit-pr/SKILL.md` T-END + T5 re-arm | `polling-backoff-warn.sh` reads the field by name; field-name changes must update the hook |

## 4. Preserved invariants

- `SKILL.md` step numbering (A1–A3, T0–T7, T-END) is unchanged — callers, tests, and cross-references use named steps.
- The `.prs["<N>"].babysit` schema fields are unchanged — `babysit-pr-stop/SKILL.md` depends on them without migration.
- Footer tokens and the verbatim bash helper blocks (`to_epoch()`, `bump_parse_failure_counter()`, `resolve_script()`) stay inline — they are not extracted (shared-script extraction is deferred; see below).
- `scheduling-primitive-alignment.test.sh` CI guards remain valid with no path changes.
- The `--durable` removed-flag row stays in the arguments table — accepted and ignored per #827 so a saved chip payload does not hard-error.
- Cross-references in `scheduling-reliability.md` (`babysit.cadence_base_minutes`, `babysit.last_tick_at`, the `max(15m, 3×base)` formula) continue to resolve to the SKILL.md-owned source.

## 5. Deferred items

**Shared-script extraction of `to_epoch()`:**
The function appears verbatim in at least 5 files across the repo. Extracting it is a repo-wide
change, out of scope for a single-file hotspot ticket. Recorded in
`.claude/reference/script-extraction-audit.md` for future consideration.

**Extraction of the `max(15m, 3×base)` backoff formula:**
The literal text `if (( STREAK >= 3 )); then EFFECTIVE_MIN=$WIDE_MIN; else EFFECTIVE_MIN=$BASE_MIN; fi`
is pinned by `require_text` in `scheduling-primitive-alignment.test.sh`. Extracting it to a
shared helper would require simultaneously updating the CI test, which is a coordinated change
tracked separately.

## 6. Verification and future edits

Verification for this verdict checks: (1) the reference catalog entry exists,
(2) `rule-lint.sh` and `verbatim-block-lint.sh` pass, (3) `reference-catalog-lint.sh`
confirms 1:1 parity, and (4) `scheduling-primitive-alignment.test.sh` still passes without
any path changes. No auto-loaded corpus file changes, so `.claude/rules/.budget-soft-cap`
is untouched.

Future edits to `babysit-pr/SKILL.md` that change sections covered by `require_text` guards
must simultaneously update the corresponding test in `scheduling-primitive-alignment.test.sh`.
The pattern is: change SKILL.md, update the literal string in the test, verify CI passes.
Adding a new critical invariant should follow the same pattern — add a `require_text` guard
when the prose encodes a safety or correctness boundary.

If the scheduling substrate evolves again (a new primitive replaces Monitor), expect changes
across A3, T5, arguments table, and potentially T0 — the same cluster pattern as #825/#867/#922/#982.
That would be a legitimate re-evaluation trigger for this verdict, but only if the CI tests
are also updated to govern the new sections.

## 7. Related precedent

- `.claude/reference/fixpr-hotspot-decision.md` — KEEP + extract (extraction chose scripts, not
  reference prose; contrasting case where extraction suited deterministic command forms).
- `.claude/reference/monitor-mode-hotspot-decision.md` — KEEP + dedup; same 9-PR trigger count;
  dedup was available; extraction was not applicable to agent-judgment policy.
- `.claude/reference/start-issue-hotspot-decision.md` — KEEP unchanged; same 9-PR trigger count;
  no duplication, no extraction target.
- `.claude/reference/pmm-lifecycle-hotspot-decision.md` — KEEP + dedup; churn driven by same
  scheduling-substrate evolution; canonical-source marker approach applied. The PMM extraction
  precedent (`references/pmm-*.md`) was proposed for this ticket but blocked by CI constraints
  that do not apply to the PMM reference files.
- `.claude/reference/scheduling-reliability-hotspot-decision.md` — KEEP; 12 PRs in the same
  scheduling-substrate window; formula/enforcement restatements removed downstream.
- `.claude/reference/script-extraction-audit.md` — extraction registry; `to_epoch()` deferred
  here for future consideration.
