<!-- pm-routing:begin -->
Run the existing forgotten-PR triage after Your Open PRs, before Suggested Next Issues.
<!-- pm-routing:end -->

Runs on **every** `/pm` invocation, no flag required — both 1A.4 (resume) and 1B.5 (cold start) call it, rendering its block **immediately after `## Your Open PRs` and before `## Suggested Next Issues`**. Like Step 1C, it is informational-first: its block never alters 1B.3 narrowing, 1B.4 scoring, or the 1B.4b judgment check. Its scope is deliberately narrow — a **one-shot startup triage** of PRs you have likely forgotten, then a hand-off. It does **not** enter a monitoring loop; continuous PR-fleet monitoring remains `/pr-monitor-and-manage`'s job.

**Execute the complete `.claude/skills/pm-forgotten-pr/SKILL.md` workflow inline** — detection, render, confirmation-gated close flow (with independent branch-delete gate), and confirmation-gated merge flow (sequenced via `merge-sequence.sh`, dispatched as `phase-c-merger` subagents, one-shot hand-off). This is the same "invoke the full SKILL.md workflow inline, no shortcuts" idiom Step 1C uses for `/pm-clean`. Pass `$GH_USER` and `$FORGOTTEN_PR_DAYS` from the current session; both have defaults in the skill itself.


Mark `1D ran` when the triage and any required handoff finish, or `1D failed`
with the reason if triage cannot run.

