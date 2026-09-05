# End-of-Task Wrap-Up Format

Canonical shape of the single message a thread emits when its requested work reaches a terminal state. Referenced from `CLAUDE.md` item #3 (always-emit exceptions) and `.claude/rules/monitor-mode.md` (drain-time closing message). Provenance: Issue #1396, from the 2026-08-27 conversation on the [Issue #1362](https://github.com/auerbachb/claude-code-config/issues/1362) thread, where an accurate but jargon-heavy completion report took four rounds of follow-up questions to converge on the summary the user actually wanted.

## Why this exists

`CLAUDE.md` item #3 suppresses progress narration and interim completion reports, yet the final message of a task still has to carry the outcome. That tension used to be unresolved, so threads ended either in near-silence or in an investigator's-eye dump — script names, SHAs, evaluator internals, and the chronology of the investigation — leaving the reader to ask "give me one sentence", "what part of the system was this?", "so was anything actually wrong?".

This file is the resolution: the wrap-up **is** the sanctioned final message, not an extra report layered on top of it.

## Template

```text
{Eastern-time prefix, per `CLAUDE.md` item #1 — e.g. Thu Aug 27 04:12 PM ET}

{TL;DR — one plain-English sentence stating the overall outcome.}

- **Where this lives:** {what part of the system was worked on, naming key
  components by ROLE — "the script that decides reviewer escalation", "the
  script that authorizes merges" — not by filename.}
- **What happened:** {plain English. If the investigation overturned the
  original premise, say so explicitly and FIRST.}
- **What changed / what deliberately didn't:** {including "no change needed,
  and why".}
- **Deliverables:** {PRs and issues as links, one plain line each.}
- **Decisions you made:** {recorded so they are not re-proposed later.}
```

Slot order is fixed. Slots with nothing to say are omitted, not padded — an omitted slot is silence, never a "N/A" line.

## Rules

### Emit exactly once, at terminal state

- Terminal state = the work merged, the work is blocked pending a decision, or the user's question is answered.
- **Never per-phase.** A pipeline that runs Phase A → B → C emits one wrap-up at the end, not one per phase.
- **Never repeated on later conversational turns.** Once emitted for a task, follow-up turns answer what was asked; they do not re-render the wrap-up. A genuinely new task earns its own.
- The `merged PR #N` always-emit line is a **separate, unchanged** exception (`CLAUDE.md` item #3). It fires at the merge moment, carries no timestamp prefix, and is neither replaced by nor folded into the wrap-up.
- **The two sit at different layers, so both firing is correct, not a contract breach.** `/wrap`'s "exactly one line, then nothing else" silent default (`wrap/SKILL.md` §Silent default) governs `/wrap`'s **own** output. The wrap-up is the **task's** terminal message, emitted by the thread once `/wrap` has returned — so a task that ends in a clean merge legitimately shows `merged PR #N` and then one wrap-up.

### Length and timestamp

- The wrap-up is the one message exempt from the ≤2-line ceiling in `CLAUDE.md` item #3 — the exemption is named there, and is what makes a multi-bullet ending legal. It is not a license to sprawl: the scale-down rule below still binds, and the jargon policy still sends detail to the PR body.
- The wrap-up **carries the Eastern-time prefix** required by `CLAUDE.md` item #1, on its own first line; the TL;DR is the first line of content. The timestamp-free form belongs only to `merged PR #N`.

### Scale down for trivial work

A trivial task — a one-file fix, a single lookup answered — renders as the TL;DR plus **at most three** bullets. Reach for the full six-slot shape only when there is genuinely something in each slot. Padding a small result into the full template is the same failure as the dense dump, from the other direction.

### Blocked endings use the same shape

Same template, with the blocker and the decision needed as the **first** bullet, phrased as a question the user can answer in one line. The TL;DR still leads and still states the outcome plainly ("Stopped short of merging — X needs your call").

### Jargon policy

- Name components by **role**, not by filename: "the script that decides reviewer escalation", not `escalate-review.sh`.
- Include a filename, SHA, line number, or flag **only when the reader must act on it** — a file they will open, a command they will run, a PR they will click.
- Deep technical detail — SHAs, timelines, evaluator internals, step-by-step chronology — belongs in the PR body, the issue body, or a reference file. Chat gets the conclusion, not the transcript.
- Every PR or issue reference carries its type prefix in the link text: `[PR #N](url)`, `[Issue #N](url)` — per `CLAUDE.md` §"GitHub reference prefix", which governs link text too.

### Premise corrections lead

When the investigation overturned the framing the task started with — the bug was already fixed, the gap does not exist, the cause was something else — that correction is the first thing after the TL;DR, stated head-on. Burying it under the chronology is the specific failure this format exists to prevent.

## Scope boundary

**In scope:** the end-of-task chat message, in any thread — coding threads, orchestration threads at fleet drain, research threads answering a question.

**Out of scope, keeping their existing formats:**

- `/recap` — its own functional-summary format.
- `/standup` — its own daily business-lens format.
- `/wrap`'s internal report format and its post-merge phases.
- The machine-parsed `EXIT_REPORT` block subagents print (`exit-report-format.md`). That is a parser contract between agents; this file is the human-facing chat surface. Issue #1171 covered the former and is unrelated.

## Worked example

The corrected final summary from the 2026-08-27 [Issue #1362](https://github.com/auerbachb/claude-code-config/issues/1362) thread, rendered in this format. Note that the premise correction — the bug was not real — leads.

```text
Thu Aug 27 04:12 PM ET

The reported bug wasn't real: the guard it says is missing has been wired in
since early August, and what we actually saw was two checks reading the same
PR 108 seconds apart, on either side of a bot quietly editing its own comment.

- **Where this lives:** the two scripts that answer "is this PR ready?" — the
  one that decides whether to escalate to the next reviewer, and the one that
  authorizes the merge. Both consult the same shared judge of whether a bot's
  approval is substantive or a rubber stamp.
- **What happened:** the original report said the escalation script skips that
  shared judge. It does not, and hasn't since the guard shipped — both scripts
  build the identical payload and cannot disagree on it. Replaying the real
  payloads confirmed the flip came from timing: the review bot edited its own
  status comment in place between the two runs, and that edit is what turned a
  hollow approval into a passing one — for both scripts equally.
- **What changed / what deliberately didn't:** no production change. Adding a
  fix to a script that already has one would be noise. I added a regression
  test that pins the exact reported shape so a real regression here fails
  loudly, and filed the genuine hazard the replay exposed.
- **Deliverables:** [Issue #1362](https://github.com/auerbachb/claude-code-config/issues/1362)
  closed with the verified diagnosis in its body. A follow-up issue covers the
  real hazard: while a review is still running, its "started" row names the
  current commit and redeems a hollow approval for the whole run window — which
  affects both scripts, not just one.
- **Decisions you made:** ship the regression test rather than a speculative
  code change, and split the residual hazard into its own issue rather than
  widening this one.
```

Contrast with the shape this replaces: the original ending led with `escalate-review.sh` line numbers, the commit that introduced the guard, two UTC timestamps to the second, and the evaluator's `disqualified_by` array — all accurate, none of it answering "so was anything actually wrong?".
