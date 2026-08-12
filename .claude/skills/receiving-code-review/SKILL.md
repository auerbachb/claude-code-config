---
name: receiving-code-review
description: Use when a Phase B agent receives bot review findings — before implementing any suggestion, especially when a finding conflicts with sibling patterns in the codebase or contradicts another reviewer. Judgment layer only; the mechanical fix/reply/resolve loop lives in cr-github-review.md.
triggers:
  - bot left a finding
  - coderabbit finding
  - bugbot finding
  - greptile finding
  - review feedback
  - should I implement this
  - reviewer says
---

<!-- Adapted from obra/superpowers skills/receiving-code-review/SKILL.md @ b36e0829 -->

# Receiving Code Review — Judgment Layer

Code review requires technical evaluation, not emotional performance. This skill guides the EVALUATE step that sits between reading a bot finding and touching any code.

**Core principle:** Verify before implementing. Technical correctness over performative compliance.

> **Scope note:** This file is the *judgment* layer. The mechanical loop — polling endpoints, batching fixes, replying to threads, resolving via GraphQL — belongs to `cr-github-review.md`. Do not duplicate that loop here.

## The Six-Step Response Pattern

```
WHEN a bot reviewer (coderabbitai[bot], cursor[bot], greptile-apps[bot],
     codeant-ai[bot], graphite-app[bot]) posts a finding:

1. READ:        Complete the finding without reacting
2. UNDERSTAND:  Restate the requirement in your own words (or flag if unclear)
3. VERIFY:      Check against codebase reality — open the actual file
4. EVALUATE:    Is this finding technically sound FOR THIS codebase?
5. RESPOND:     Technical acknowledgment or reasoned decline with evidence
6. IMPLEMENT:   Only valid findings, one at a time, per cr-github-review.md
```

**STOP before step 6** if you have not completed steps 3 and 4. Incomplete verification = incomplete review.

### Step 3 — VERIFY maps to our verification step

"Check against the actual file" in step 3 is the same verification step described in `cr-local-review.md`. Specifically: open the file the finding references, read the surrounding context, confirm whether the code matches the reviewer's claim. Do not rely on memory or the diff alone.

### Step 5 — RESPOND respects reply conventions

How you reply depends on the reviewer:

- **`coderabbitai[bot]`:** Replies teach CodeRabbit's model. Use `@coderabbitai` in a PR-level comment for general context; inline replies for thread-specific responses.
- **`cursor[bot]` (BugBot) / `greptile-apps[bot]`:** Plain text only. Do NOT include `@cursor` or `@greptileai` in reply comments — each mention triggers a new paid review. For the exact reply-format table see `.claude/reference/greptile-reply-format.md`.
- **`codeant-ai[bot]` / `graphite-app[bot]`:** Plain text inline replies.

## Forbidden Responses

Do not write these before completing steps 3–4:

- "You're absolutely right!" — explicit performative agreement
- "Great point!" / "Excellent feedback!" — performative
- "Let me implement that now" — commits before verification
- "Thanks for catching that!" / any gratitude expression

**Instead:** Restate what the finding is asking, verify it, then either state the fix or decline with evidence.

## Handling Unclear Findings

```
IF any finding is unclear:
  STOP — do not implement anything yet
  RESTATE what you think is being asked
  ASK for clarification if still unclear

WHY: A misread finding implemented wrong costs another review round.
```

## When to Decline (Reasoned Pushback)

Decline a finding when:

- The suggestion breaks existing functionality
- The reviewer lacks full context (e.g., a stale learning predating a refactor)
- The pattern it demands conflicts with sibling patterns in the codebase
- The finding contradicts a different reviewer's finding (trace the logic yourself — both can be partially right)
- YAGNI applies — the code path is unused

**How to decline:** State the technical reason, reference the specific file or pattern it conflicts with, and resolve the thread. A declined finding still gets a reply and thread resolution per `cr-github-review.md` step 4.

## Rationalization Table

These are excuses that feel like reasons. Recognize them before they become code changes.

| Excuse | Reality |
|--------|---------|
| "CR said so, so it must be right" | CR stale learnings can be factually wrong about code that changed since the learning was recorded; verify the actual file (`feedback_cr_stale_learnings.md`) |
| "Greptile and CR contradict each other, I'll implement both" | Contradictions require tracing the logic yourself; implementing both often produces a third bug (`feedback_cr_vs_greptile_contradictions.md`) |
| "The CLI came back clean so the App finding must be stale" | CLI quotas and App reviewer quotas are independent; a CLI outage does not affect the GitHub App reviewer (`feedback_review_clis_down_app_independent.md`) |
| "The local review was clean so the finding is wrong" | A CLI false-clean exit (exit 0 on failure) is a documented failure mode; probe `verified_run == true` before trusting it (`local-review-cli-failure-modes.md`) |
| "Implementing this is the path of least resistance" | Performative compliance creates technical debt; a reasoned decline with evidence is the correct output |
| "Attribution looks right at a glance" | Word counts and section attribution on decision records require `git show <SHA>:path \| wc -w` to verify — approximations cause Greptile P2 findings (`feedback_hotspot_decision_word_count_verification.md`) |
| "CodeAnt approved so we're good" | CodeAnt can approve before it substantively reviews; check for substance evidence per merge-gate-reviewer-paths.md §875 hollow-approval check |

## Red Flags — STOP If You Catch Yourself Thinking…

- "I'll just implement it and see if CR accepts it next round."
- "Both reviewers can't be wrong — I'll do both."
- "It's a nit so I won't verify it."
- "I don't want another review cycle, so I'll agree."
- "The reviewer used confident language so it must be correct."

Each of these is a rationalization path. Return to step 3 (VERIFY).

## Letter vs Spirit

A bot finding can be literally correct but wrong in spirit. Example: a rule says "reply to every thread" and the bot flags an unresolved thread — but the thread is from a review on an old SHA, already superseded. The letter says resolve it; the spirit is not to block a clean current-SHA pass on stale artifacts. When letter and spirit diverge, reason from the spirit and document why in your decline reply.

## Exit Criteria

This skill's work is **done when** every finding in the current review round has been either:

- Verified as valid and queued for a single batched fix commit (per `cr-github-review.md` step 2), OR
- Verified as invalid, declined with a technical reason, and marked for thread reply + resolution.

At that point, return to `cr-github-review.md` for the mechanical fix/reply/resolve loop.
