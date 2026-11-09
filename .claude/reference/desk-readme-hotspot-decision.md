# Desk operating manual hotspot decision

Issue #1796. The untruncated default-branch detector after PR #2064 counted three changes to `desk/README.md`, with score 3 and no recorded conflict rounds.

KEEP a single operating manual. The README owns the queue's CLI, storage and capture contracts; `DESIGN.md` explains the design and `skill/` routes day-to-day work. Skills and hook documentation already refer to named sections in the README, so keeping those entry points stable helps readers find the contract they need.

| Counted PR | Documentation change |
|---|---|
| #1998 | Recorded that text reaches psql without appearing in its argument list. |
| #2023 | Completed the list of inputs that refuse credential-shaped text. |
| #2044 | Described the ordering between control replacement and preceding ticks. |

The original report counted #1786 for the item CLI, #1789 for capture, and #1794 for the prose-question nudge. Those verified merges are historical and separate from the three counted now. The original report noted merge-order care, but neither snapshot recorded a conflict re-resolution.

The strongest split would move setup and provisioning into its own guide. A separate reader or recurring conflicts in that section could justify it. For now, keep the existing section links and add a short navigation line for the existing setup, CLI, capture and test sections. No runtime or database behavior changes.
