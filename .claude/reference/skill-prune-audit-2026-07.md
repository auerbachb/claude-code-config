# Skill prune audit — 2026-07-02 (#431)

Follow-up to #416 skill-usage telemetry. Audit date: 2026-07-02.

## Telemetry

- Log: `~/.claude/skill-usage.log` (global, not in repo)
- Tracking since: 2026-05-01 (~62 days as of audit date)
- Thresholds (`skill-usage-report.sh`): 90d stale **or** never invoked after ≥30d of telemetry
- 90d stale rule: **not yet met** for any previously-invoked skill (re-check ~2026-07-30)

## Invoked skills (active)

| Skill | Invocations | Last used |
|-------|------------|-----------|
| wrap | 36 | 2026-06-25 |
| prompt | 25 | 2026-06-25 |
| fixpr | 10 | 2026-06-25 |
| start-issue | 8 | 2026-06-15 |
| merge-conflict | 1 | 2026-06-25 |
| status | 1 | 2026-05-25 |

## Dead-skill candidates (26 — never invoked, tracking ≥30d)

### Added on/after log start (2026-05-01)

`go-on`, `babysit-pr`, `babysit-pr-stop`, `pr-monitor-and-manage`, `pr-monitor-and-manage-stop`, `admin-merge`, `issue-maker`, `monitor`, `recap`

### Pre-May skills with external references (load-bearing)

| Skill | Referenced by |
|-------|---------------|
| check-acceptance-criteria | `ac-checkboxes.sh`, README — removed 2026-07-16 (#582); see addendum |
| lessons | `phase-c-merger.md`, `cr-merge-gate.md`, `wrap/SKILL.md` — removed 2026-07-16 (#582); see addendum |
| merge | phase A/B/C agents, orchestration rules |
| pm + pm-* suite | `pm-worker.md`, cross-skill refs, `stale-cleanup.sh`, README |
| pr-review-help | `subagent-orchestration.md`, `pm-config.md` |
| prioritize *(retired)* | *Historical, as of this audit:* `issue-maker/SKILL.md`, reference docs. Folded into `/pm` and retired (#583) — those references now point at `/pm`. |
| standup | `workday.sh`, ~~`pm-okr/SKILL.md`~~ *(that skill was retired — #1585; see addendum)* |
| subagent | phase A/B/C agents, orchestration rules |

## Outcome (original audit, 2026-07-02)

**Zero skills pruned.** All 26 candidates are either too new or referenced by agents, rules, scripts, or other skills. Autonomous invocation (orchestrator, `/wrap`, subagents) explains zero log lines for skills like `subagent`, `merge`, `lessons`, and the PM suite. *(2026-07-16: six of these candidates were subsequently removed — see addendum below.)*

Run `bash .claude/scripts/skill-usage-report.sh` locally for live rollups; confirm each deletion out-of-band before removing any skill directory.

## Addendum — 2026-07-16 (#582): July early trim

The 75-day usage report recovered from the old MacBook (#572) plus owner confirmation ("never typed either") resolved six of the candidates above, removed ahead of the October audit (#573):

- **PM rituals** — `pm-rate-team`, `pm-team-standup`, `pm-sprint-review`, `pm-sprint-plan`: multi-contributor ceremonies never exercised in this solo workflow.
- **`lessons` / `check-acceptance-criteria`** — the prior "load-bearing" classification is resolved: their external references were call-site listings and mentions of `/wrap`'s inline lessons phase, not delegations. `/wrap`'s lessons phase (Steps 4.1–4.3) and the merge gate's AC verification (`cr-merge-gate.md` Step 2 + `ac-checkboxes.sh`) are self-contained, so nothing functional was lost.

## Addendum — 2026-07-30 (#793): CUT verdict for the ocr CLI wrapper

The skill wrapping Alibaba's `ocr` CLI was resolved to **CUT** via Issue #793, the first dedicated keep/cut decision for this candidate:

- **Zero recorded invocations** across 511 skill-usage.log entries; telemetry tracking since 2026-05-01.
- **`ocr` excludes `.md` files** as `unsupported_ext` — in this doc/config-heavy repo, the tool reviews almost nothing without a custom rule config.
- **Live side-by-side eval was permanently blocked** (no Anthropic credential in the eval VM); no concrete `ocr`-only differentiator was ever substantiated.
- **Native `/code-review`** (with `--fix`, `--comment`, `ultra`) now fills the same advisory, non-gating role.
- The prior `keep` verdict from the harness audit was only the mechanical "uncertainty resolves to keep" default, not a real case.

Removed: the `ocr` skill directory, README catalog row + count anchors (`29` → `28`), `.claude/reference/ocr-eval.md`, and its reference-index entry. Resurrection path: `git log -- .claude/skills/ocr-wrapper/SKILL.md` or search commit history for the removal PR (`Closes #793`).

## Addendum — 2026-09-02 (#1585): `/pm-okr` and `/pm-update` retired

The October audit (#573) had deferred both to 2026-10-16 as "not a pre-approved deletion". The owner pulled the decision forward in chat on 2026-09-02 after reviewing `skill-usage-report.sh` on both machines: **zero invocations on either** — 48 days of telemetry on the new machine, 124 on the old.

- **`/pm-okr`** — showed, set, or suggested objectives in `pm-config.md`. The OKRs section still reads "No OKRs set", so the skill never had anything to manage, and `/pm` ranks fine without it. Its `suggest` mode (theming recent PRs into proposed objectives) is dropped outright; it borrowed `/standup`'s theming, and `/standup` is where it belongs if ever wanted again. **`/pm`'s `OKR_MODE` read path is untouched** — objectives added to the section by hand still shape ranking exactly as before.
- **`/pm-update`** — re-scanned the repo to refresh `pm-config.md`'s Infrastructure and Architecture sections (Steps 2-7), then ran a stale worktree/branch sweep (Step 8). Both halves were already covered elsewhere or unused: the config has not drifted, and Step 8 duplicated `/pm-clean`, which calls the same `stale-cleanup.sh`.

**Where the surviving behavior went.** `/pm-update` Steps 2-7 moved into `/pm-handoff` Step 3 (now Steps 3a-3g), which already bootstrapped `pm-config.md` on first run and is therefore the one place the config is created or refreshed — inheriting the section classification, the never-overwrite-user-edited-sections rule, the infrastructure and architecture re-scan, and the diff-before-write gate. **Step 8 was dropped, not moved:** `/pm-clean` is now the sole documented caller of `stale-cleanup.sh`.

Removed: both skill directories, their README catalog rows + count anchors (`38` → `36`), and their zero-usage telemetry records. Every file that cited `/pm-update` was re-pointed at `/pm-clean` (cleanup) or `/pm-handoff` (config) — the seven the ticket named (`merge`, `wrap`, `pm-clean`, `wave`, `pm-forgotten-pr`, `stale-cleanup.sh`, `phase-c-merger.md`) plus `pm-config.md` and three point-in-time reference docs, which retain the names only as retirement history. The `~/.claude/skills/pm-okr` and `~/.claude/skills/pm-update` symlinks are removed post-merge per `skill-symlinks.md`. Resurrection path: `git log -- .claude/skills/pm-okr/SKILL.md .claude/skills/pm-update/SKILL.md`, or search commit history for the removal PR (`Closes #1585`).
