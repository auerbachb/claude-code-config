# Subagent model audit, November 2026

Issue #2298. One-time, read-only look at which model each helper agent actually
ran on, and whether a cheaper model was eligible. Fixes are filed as separate
issues (linked at the end). Prior work this builds on, not repeated here:
`model-routing-trials-2026-11-07.md`, `harness-model-audit-2026-06.md`,
`token-efficiency-audit-2026-07.md`, `pm-routing-audit-2026-07.md`.

## Correction

The first draft's headline was wrong. It said no helper ran on Opus after
2026-11-07. Across all projects, 141 helper spawns resolved to Opus on or after
2026-11-07: 85 on 11-07 and 56 on 11-09 through 11-13. This repo's sessions
account for one of the 141, a `phase-b-reviewer` spawn on 11-07. The first
draft's Haiku count (49) and its window total (173) did not reproduce. The
counts below replace them. Its verdict that 11 Sonnet routings were unjustified
step-ups was also wrong. The routing records show first launches; see
"Step-ups and eligibility."

## Bottom line

- In this repo's sessions, 66 Opus helper spawns fall in the window, all dated
  11-06 or 11-07. One of them is dated 11-07, the routing-landing day. No
  Opus spawn in this repo's sessions is dated after 11-07.
- Across all projects, 56 helper spawns resolved to Opus on 11-09 through 11-13
  (54 `general-purpose`, 2 `researcher`). All 56 named `opus` at the call site.
  None came from this repo's sessions. They came from two other project
  directories (29 spawns) and from home-directory sessions with no project (27).
  The records do not show which skill launched them.
- The routing store holds 173 decisions and none selected Opus. All 153 Sonnet
  picks show Haiku marked `capable: false`. 152 are first launches with no
  attempts, and one is a same-model retry. None is an escalation.
- Remaining gaps: telemetry cannot tie helper usage to a PR (#2300); the
  `capable: false` basis is not written into the decision reason (#2301, see
  its framing note below); and a stale Sonnet 4.6 pin sits in the settings
  `env` block (#2302).

## Method

Reproducible with one pass over the transcripts. No transcript text is kept.

1. Source: top-level `~/.claude/projects/*/*.jsonl` session transcripts (354
   files). No nested transcripts exist at that depth, so none are excluded.
2. Helper spawn: each assistant `tool_use` block with `name == "Agent"`,
   deduplicated by its `id`. Across all dates this gives 4,833 distinct spawns.
3. Requested model: `input.model`. Absent = `unnamed`. Subagent type:
   `input.subagent_type`. Absent = `general-purpose`.
4. Resolved model: join by `tool_use_id` to the matching tool result's
   `toolUseResult.resolvedModel`. No result = `unknown`. Family = substring
   match on `opus`, `sonnet`, `haiku`, or `fable`.
5. Date: UTC calendar date of the record timestamp. Window 2026-11-06 to
   2026-11-13. "Post-routing" = 2026-11-07 or later, the day cost-first routing
   landed (#1978). The split is by date, not time of day.
6. Scope: "this repo" = project directories whose name contains
   `claude-code-config`. That includes this repo's worktrees and one other
   working copy of the same repo. "All projects" = every directory. Both are
   reported.
7. Routing store: `model_routing` in the session-state file. Decision records
   (with `action`) and request records (with `models`) are joined on task and
   phase. Records carry no timestamp, so routing counts cover the whole file,
   not the window.
8. Flow grouping: rough keyword match on each spawn's short `description`. It
   is not a verified attribution.

## Inventory of helper spawn sites

The grep `grep -rn 'subagent_type' .claude/skills .claude/agents .claude/reference`
returned 34 hits in 16 files at review time. Every file with a hit is listed
here. This report also contains the string, so a re-run now adds hits in this
file; it appears under "mentions only."

Live spawn sites:

| File | Spawn | Model named? | Routed through `model-route.sh`? |
|---|---|---|---|
| `.claude/skills/subagent/SKILL.md` | Phase A (no literal `subagent_type`), Phase B (`phase-b-reviewer`), Phase C (`phase-c-merger`) | Yes, `model: ROUTED_MODEL` on all three (lines 1187, 1942, 2036) | Yes, persisted decision |
| `.claude/skills/pr-monitor-and-manage/references/pmm-act.md` | Bulk fix (`phase-a-fixer`) | Yes, `ROUTED_MODEL` | Yes |
| `.claude/skills/pm/SKILL.md` | Read-only data helpers (`researcher`) | Yes, required; "never omit `model`" | Yes, `model-route.sh` named on the line |
| `.claude/skills/pm-forgotten-pr/SKILL.md` | One `phase-c-merger` per approved PR | Yes, `model: ROUTED_MODEL` | Yes, persisted decision |
| `.claude/skills/harness-audit/SKILL.md` | `claude-code-guide` | No. Defers to the read-only row in `subagent-orchestration.md` | No |

Agent definitions (`.claude/agents/*.md`) hold no spawn sites. Six define
`model: haiku` in frontmatter, which is the fallback when a spawn names no model.
Those spawns are not routed.

Mentions only (docs and examples, not spawn sites):

- `.claude/agents/README.md` (4 hits, including an example block).
- `.claude/reference/`: `agents-readme-hotspot-decision.md`,
  `issue-1121-subagent-registration-verification.md` (4),
  `issue-852-browser-rung-verification-hotspot-decision.md`,
  `issue-852-browser-rung-verification.md` (3), `phase-decomposition.md` (3),
  `repo-audit-2026-05.md`, `researcher-hotspot-decision.md` (2),
  `skill-first-hotspot-decision.md` (2), `skill-symlink-setup.md`,
  `token-efficiency-audit-2026-07.md` (4).
- This report (`subagent-model-audit-2026-11.md`), which names the string in its
  own inventory and method.

Not verified: the `/code-review` background run and Workflow-script spawns.
Transcripts show `general-purpose` and unnamed spawns that may cover these
paths, but no skill was mapped to each one.

## Sample: this repo's sessions

Window 2026-11-06 to 2026-11-13. 176 distinct spawns, of which 81 are on or after
2026-11-07.

| Resolved | Requested | Subagent type | Count |
|---|---|---|---|
| opus | opus (named) | phase-b-reviewer | 35 |
| opus | opus (named) | general-purpose | 31 |
| sonnet | sonnet (named) | phase-c-merger | 38 |
| sonnet | sonnet (named) | general-purpose | 11 |
| sonnet | sonnet (named) | phase-b-reviewer | 9 |
| haiku | haiku (named) | general-purpose | 21 |
| haiku | haiku (named) | phase-b-reviewer | 20 |
| haiku | haiku (named) | phase-c-merger | 8 |
| haiku | haiku (named) | phase-a-fixer | 1 |
| haiku | unnamed | claude-code-guide | 1 |
| unknown | opus (named) | general-purpose | 1 |

Totals: Opus 66 resolved, all dated 11-06 or 11-07; Sonnet 58; Haiku 50 named
plus 1 unnamed; unknown 1.

On or after 2026-11-07 in this repo: Opus 1 (`phase-b-reviewer`, 11-07); Sonnet
29; Haiku 51 (50 named, 1 unnamed).

## Sample: all projects

Window 2026-11-06 to 2026-11-13. 1,093 distinct spawns.

| Resolved | Requested | Subagent type | Count |
|---|---|---|---|
| opus | opus (named) | general-purpose | 149 |
| opus | opus (named) | phase-a-fixer | 88 |
| opus | opus (named) | phase-b-reviewer | 74 |
| opus | opus (named) | researcher | 3 |
| sonnet | sonnet (named) | phase-c-merger | 237 |
| sonnet | sonnet (named) | phase-b-reviewer | 170 |
| sonnet | sonnet (named) | general-purpose | 135 |
| sonnet | sonnet (named) | phase-a-fixer | 129 |
| sonnet | sonnet (named) | researcher | 24 |
| haiku | haiku (named) | general-purpose / phase-b / phase-c / phase-a | 21 / 20 / 8 / 3 |
| haiku | unnamed | web-fetch 5, claude-code-guide 1 | 6 |
| unknown | sonnet (named) | general-purpose 11, phase-a 2, phase-b 2, phase-c 1, pm-worker 1 | 17 |
| unknown | opus (named) | general-purpose 6, phase-a 1, phase-b 1, researcher 1 | 9 |

On or after 2026-11-07 (830 spawns): Opus 141, all named `opus` at the call
site. Sonnet 608 named plus 16 unknown. Haiku 52 named plus 6 unnamed. Unknown
resolution 7 Opus-named.

## Opus spawns after routing landed

Each of the 141 Opus-resolved spawns on or after 11-07 named `opus` at the call
site. None was inherited or pinned. Eligibility verdicts follow.

| Group | Count | Dates | Subagent type | Eligibility verdict |
|---|---|---|---|---|
| This repo's sessions | 1 | 11-07 | phase-b-reviewer | Evidence: the definition sets `model: haiku`, and this override departs from it. Opinion: Haiku suffices. Verdict: historical, on the routing-landing day. No new issue. |
| Other project directories | 140 | 11-07 and 11-09 to 11-13 | mostly general-purpose | Outside this repo's routing and definitions. Eligibility not assessable from the records (no task identity). Opinion only. |

The 56 spawns on 11-09 to 11-13 (all projects): general-purpose 54,
researcher 2. By date: 8 on 11-09, 19 on 11-10, 9 on 11-12, 20 on 11-13. By
source: 29 from other project directories, 27 from home-directory sessions.
Rough keyword grouping of their descriptions: phase, fix, review, or merge work
36; docs, issue, plan, or spec work 4; other 16. No routing record can be linked
to them, because the store has no project or timestamp field. Whether the owning
repos have a cheaper-tier rule is outside this repo's records.

## Routing records

The routing store holds 173 decisions: 169 Phase A and 4 research. Phase B and C
have no records. Decisions: 171 `start` and 2 `retry`. Selected tier: 153 Sonnet,
20 Haiku, 0 Opus. No `escalate` actions.

Every Sonnet decision joins to a request in which Haiku shows `available: true`,
`budget_allowed: true`, `reserve_allowed: true`, and `capable: false`. Of the 153:

- 152 are first launches (`start`, zero attempts), recorded with the reason
  "Cheapest eligible configured tier."
- 1 is a same-model `retry`, recorded as "Useful progress: retain discoveries
  and targeted feedback on the same model."

The first draft's "31 tasks, 11 Sonnet, 20 Haiku" does not reproduce. The file
holds no timestamps, so a window cannot be applied to it.

## Step-ups and eligibility

`model-route.py` counts a tier as eligible only when `available`, `capable`,
`budget_allowed` and `reserve_allowed` are all true. With no prior attempts, the
cheapest eligible tier is selected and recorded as `start`. So a Haiku marked
`capable: false` is skipped, and Sonnet becomes the first eligible tier. That is
a first-launch pick. It is not an escalation, and no escalation diagnosis was
required.

`task-model-routing.md` defines `capable` as whether the tier's requirements (for
example tool support and required context) are supported. It is not a judgment
that the first attempt will succeed.

The gap that remains: the decision reason does not name the requirement that
Haiku lacked. A reader cannot tell from the record which requirement was unmet.
Issue #2301 proposes recording that basis.

Verdict on the 153 Sonnet picks: evidence shows first launches with Haiku marked
not capable. Nothing shows an unjustified step-up. The reason text is generic.

Issue #2301 is framed around "step-ups." Its premise, that these were
escalations that skipped a cheaper tier, does not match the records. Its
remaining request (record a basis for `capable: false`) still applies. Its "11
picks" count does not reproduce from the file, which holds 153. The issue body
was not edited.

## Inherited model and the environment pin

Vendor docs (https://code.claude.com/docs/en/sub-agents): resolution order is the
per-invocation `model` parameter, then the definition's `model` frontmatter,
then `CLAUDE_CODE_SUBAGENT_MODEL`, then the main conversation's model. The docs
state that frontmatter outranks the variable, and that before v2.1.251 the
variable came first and overrode the per-invocation parameter.

Record evidence agrees with that ordering. From 2026-07-21 to 2026-08-26, every
Opus and Sonnet request resolved to `claude-sonnet-4-6`, which is the pinned
value. From 2026-09-07 on, the requested model was honored. The runtime version
history for July and August is not in the records, so the pre-v2.1.251 cause is
an inference.

Answer, with the session's runtime version recorded as 2.1.322 (routing records):
from v2.1.251 the order is the invocation model, then the definition's model, then
the environment pin, then the parent model. Before v2.1.251 the pin overrode both
the invocation model and the definition. A definition with its own `model`
never reaches the pin. Setting only the pin does not change the built-in Explore
or Plan helpers, per the docs. A helper started with no model named, and no
definition model, therefore takes the pin (`claude-sonnet-4-6`) and never the
parent's model. That makes the stale pinned version a finding for such spawns.
The one unnamed sample is `claude-code-guide`, whose definition may set Haiku on
its own. That single record is not enough to confirm the pin in effect, so the
unnamed-spawn claim rests on the docs, not on a record.

## Verdicts

Fixed-model skills (opinion unless noted):

- quotas, quotas-setup: **keep**. Display and configuration work; sampled use
  is too thin to revisit.
- recap, standup, status, tldr (sonnet): **revisit**. Short summary work that
  Haiku might serve. Opinion only; no run in the sample. No issue filed.

New-thread advice:

- `/start-issue`: **keep**. Sonnet default, Opus for skills, rules and
  orchestration. Opinion.
- `/prompt`: **keep**. Heavy maps to Opus with a Fable step-up. Opinion; this
  is advice for a human-started thread, not a helper.
- `/wave`: **revisit**. Chip templates recommend Opus. Opinion; no record shows
  what those threads actually ran on.

## Evidence versus opinion

Evidence: the spawn tables and counts above, the method, the date split, the
Opus resolution for the 141 spawns (all named at the call site), the routing
store counts and joins, the `eligible()` rule in `model-route.py`, the telemetry
gap counts, the settings pin, and the docs resolution order.

Opinion: the keep and revisit verdicts on skills and advice surfaces, the claim
that Haiku is sufficient for the skills marked revisit, and the eligibility
judgment on the 140 spawns outside this repo.

## Follow-up issues

- Issue #2300: spend telemetry cannot link usage to a PR or task (0 of 93,079 messages linked). The gap also blocks attributing the 140 out-of-repo Opus spawns to a skill.
- Issue #2301: record a basis for any `capable: false` pick (153 Sonnet picks in the routing store: 152 first launches and one same-model retry). Framed there as "step-ups"; see the framing note above.
- Issue #2302: replace the stale `CLAUDE_CODE_SUBAGENT_MODEL` pin in owner settings (owner decision).

No new issue was filed for the Opus spawns. The data shows no concrete fix to
file. The one in-repo spawn was on the routing-landing day, and no repo-scope
Opus spawn follows it. The 140 others sit in projects whose launching skill the
records cannot name, so a fix cannot be filed in the repo that owns it.
