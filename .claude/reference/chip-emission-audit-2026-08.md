# Chip Emission-Path Audit — 2026-08

Every path in this repo that can call `mcp__ccd_session__spawn_task` or otherwise
put a click-to-launch **task chip** in front of the user, with the gate each path
applied **before** Issue
[#1367](https://github.com/auerbachb/claude-code-config/issues/1367). Recorded to
satisfy that issue's audit criterion and to confirm — rather than assume — which
path produced the 2026-08-26 five-chip incident.

Companion documents: `chip-launching.md` (canonical chip mechanics, including the
PM-context inline gate this audit refers to throughout), `.claude/rules/chip-spawn.md`
(the auto-loaded rule that now carries the emission decision), and
`inline-default-any-thread-2026-08.md` (#1229, the inline-first flip this incident
violated).

## The incident

On 2026-08-26 a verifiably `/pm`-initiated thread — mid-orchestration, three live
pipelines, a fresh merge — finished a `/wrap` follow-up sweep and put **five
"Suggested task" chips** on screen. The user interrupted the session to ask that
all five be retracted and run as subagents instead. One chip was later
hand-upgraded into Issue
[#1361](https://github.com/auerbachb/claude-code-config/issues/1361).

The interruption is the failure. The thread was execution-capable, already
running pipelines, and had every mechanism it needed to file the work and queue
it itself.

## Emission paths and the gates they applied

Gates as they stood **before** this change; the "What changed" section below
records the one row that moved.

| # | Path | Emits a chip? | Gate applied | Registers in `chip-offer-registry.sh`? |
|---|------|---------------|---------------------------|----------------------------------------|
| 1 | `/pm` Step 3.1 | Yes | PM-context inline gate; repo-wide cap read from `active-work-cap.sh`; per-issue too-big verdict from `/subagent` Step 4 | Yes — explicit `--reserve` call site |
| 2 | `/prompt` Step 6 | Yes | Same gate, after Step 5.5 inline/thread partitioning | Yes — explicit `--reserve` call site |
| 3 | `/start-issue` Step 7 | Yes | Same gate; in-thread adoption is the documented default, chip is one of three terminal shapes | Yes — explicit `--reserve --emitter start-issue` |
| 4 | `/issue-maker` Step 9c | On request only | Capture-mode invariant; the default session ending is an **in-thread inline-run offer**, not a chip | Yes — explicit `--reserve --emitter issue-maker` |
| 5 | `/wave` Step 7.1 | Yes | Same gate, applied per issue after the independent-set filter; inline rows never degrade to chips (#1229) | Yes — explicit `--reserve` call site |
| 6 | `/harness-audit` Step 5 | Yes | Month-watermark lock; delegates wholly to `chip-launching.md` | **By reference only** — see the gap note below |
| 7 | `/wrap` Phase 3 (per-PR follow-ups + full-session sweep) | **No** | Files every novel candidate via `gh issue create`, unconditionally and without asking (#633, #851). The skill contains no chip, `spawn_task`, or `dismiss_task` text at all. | N/A |
| 8 | `pm-worker` agent | **No** | Issue management only; the agent definition contains no chip, `spawn_task`, or `dismiss_task` text. | N/A |
| 9 | **Ad-hoc `spawn_task`** — any thread calling the tool outside paths 1–6 | Yes | **None.** `chip-spawn.md` bound the payload *format*; nothing bound the *decision to emit*. | No — the registry validates `--emitter` against the six canonical names only, so an ad-hoc chip cannot register even in principle |

## Root cause: path 9

The hypothesis in Issue #1367 was that `/wrap`'s own text never mentions chips, so
the five chips must have come from ad-hoc `spawn_task` calls made alongside wrap's
issue filing rather than from a mis-specified emitter. **The audit confirms it.**
Rows 7 and 8 above are textual absences, not judgment calls: `/wrap` and
`pm-worker` have no chip vocabulary anywhere in them. Rows 1–6 all route through
the PM-context inline gate, which for an execution-capable thread with
subagent-fit work returns *inline*, not *chip*. Only row 9 can produce a chip with
**no gate consulted at all**, and only row 9 is *structurally* incapable of
registering: `--emitter` is validated against the six canonical names, so an
ad-hoc chip cannot enter the census even if its caller tried.

Three forces made path 9 the path of least resistance:

1. **Layer mismatch.** The prohibition lived in `chip-launching.md` — a reference
   file that is not auto-loaded. The chip rule that *is* auto-loaded every turn,
   `chip-spawn.md`, said only how a chip must be *formatted*. A thread reasoning
   from the loaded corpus alone found a format contract and no emission
   contract, which reads as permission.
2. **A live counter-nudge.** The harness's own `mcp__ccd_session__spawn_task`
   tool description invites exactly this behavior — "flag an out-of-scope issue
   for a separate background task" — and it is present in every session. A repo
   rule can only out-shout it if it is auto-loaded too.
3. **Monitor mode misread as a prohibition.** `monitor-mode.md` bars *substantive
   work* while subagents are active. A thread can talk itself into chips as
   compliance: "I must not do substantive work here, so I'll hand this off."
   Spawning and queueing subagents is the orchestration monitor mode exists to
   do, not substantive work — but nothing said so at the point of decision.

## Secondary finding — `/harness-audit` registration is by-reference only

`chip-launching.md` §Offer Registry states that **every** emitter calling
`spawn_task` must call `chip-offer-registry.sh --reserve` first, and the registry
accepts `harness-audit` as a valid `--emitter` value. But `/harness-audit` Step 5
inherits that contract by pointing at `chip-launching.md` rather than carrying an
explicit `--reserve` call site the way the other five do. This is a
documentation-shape gap, not a correctness bug — the contract does reach it, and
unlike path 9 this emitter *can* register — and it is out of scope for Issue
#1367, which is about ungated *ad-hoc* chips. Noted here so the next audit does
not have to rediscover it.

## What Issue #1367 changed

- **`.claude/rules/chip-spawn.md`** grew an **emission gate**: the auto-loaded rule
  now says when a chip may exist, not only how it must look. It states the
  inline-first default, bars ad-hoc chips from execution-capable threads,
  enumerates the legitimate cases **by citation** to `chip-launching.md`'s
  PM-context inline gate, carries the monitor-mode clarification and the
  cross-repo note, and points at the recovery procedure.
- **`chip-launching.md`** gained one new section, §Wrong-chip recovery, next to
  the existing stale-chip hygiene section. Recovery is written once, there.
- **This document** records the audit, indexed from `.claude/reference/README.md`
  under "Audits and research".

Nothing about the six canonical emitters' behavior changed. Path 9 is the only
path whose gate moved — from none to barred.

## Decisions taken while implementing

**No `chip-offer-registry.sh` schema change.** Issue #1367's open question asked whether
a legitimately-emitted ad-hoc chip should have to register so the active-work-cap
census counts it. It should not need to, because after the gate there is no such
thing: every legitimate chip case routes through a canonical emitter, and those
already register. Adding an `ad-hoc` emitter category would create a supported
path for the exact behavior the gate exists to remove.

**No new line in CLAUDE.md's non-negotiables.** `chip-spawn.md` is already in the
auto-loaded corpus and is already indexed from CLAUDE.md's rule table, so it
already out-shouts the harness nudge on every turn. A CLAUDE.md line would spend
scarce budget for no added coverage.

**Cross-repo follow-ups stay inline-runnable.** Some of the 2026-08-26 chips
covered work in a different repo from the thread's own. That is not a reason to
route out: a subagent gets its own worktree, and the active-work cap is
per-repo, so cross-repo work consumes a slot on the repo it targets. The gate
says so explicitly rather than leaving it to inference.

## Budget accounting

The rule-corpus budget is measured with
`{ cat CLAUDE.md; find .claude/rules -name '*.md' -exec cat {} +; } | wc -w` and
enforced by `.github/scripts/rule-lint.sh` (which delegates the count to
`rule-lint-ratchet.sh`) against `.claude/rules/.budget-soft-cap`. Only CLAUDE.md
and `.claude/rules/*.md` count; everything in `.claude/reference/` — this file
included — is free.

The emission gate is therefore deliberately short, and every word of mechanism,
rationale, and history it would otherwise have carried lives here or in
`chip-launching.md` instead. Part of the addition was paid for in the same pass by
cutting restatement already carried elsewhere: the picker-has-two-controls
rationale (duplicated from `chip-launching.md` §"Model and effort lines"), the
Fable pre-click warning stated twice in one file, and the `/issue-maker`
default-ending gloss now covered by the gate itself.

Measured at implementation time: the corpus moved **11,857 → 11,999 words**, a
`+142` net delta that leaves it under the 12,000-word soft warning and **604 words
under the 12,603 ratchet cap** — no cap raise, so no PR-body justification line is
owed (`budget-cap-raise-decision.md`).

## Related

- [#1229](https://github.com/auerbachb/claude-code-config/issues/1229) — inline-subagent default in any execution-capable thread (the gate this incident violated)
- [#633](https://github.com/auerbachb/claude-code-config/issues/633) — `/wrap` files follow-up issues autonomously
- [#1191](https://github.com/auerbachb/claude-code-config/issues/1191) — repo-wide active-work cap, whose census an unregistered chip bypasses
- [#1361](https://github.com/auerbachb/claude-code-config/issues/1361) — one of the five 2026-08-26 chips, hand-upgraded to a real issue
- [#1225](https://github.com/auerbachb/claude-code-config/issues/1225) / [#1238](https://github.com/auerbachb/claude-code-config/issues/1238) — the offer registry and its deferrals
