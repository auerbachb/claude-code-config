# PR State & Polling

Scripts that read PR state, track comment watermarks, and determine reviewer ownership.

| Script | Purpose |
|--------|---------|
| [pr-state.sh](../pr-state.sh) | Gather full PR state (threads, CI, comments, merge state) into a JSON snapshot |
| [infer-pr.sh](../infer-pr.sh) | Resolve a PR reference from an explicit URL/number or from session-state candidates |
| [poll-watermarks.sh](../poll-watermarks.sh) | Track high-water IDs for the three PR comment endpoints to detect new bot findings |
| [polling-state-gate.sh](../polling-state-gate.sh) | CR polling procedural gate — registers PR in session-state and runs merge-gate.sh each cycle |
| [pr-preflight.sh](../pr-preflight.sh) | Flip a draft PR to ready and trigger the four AI reviewers when absent |
| [pr-authorship.sh](../pr-authorship.sh) | Hard authorship gate — verify the authenticated user authored a PR before any automated write |
| [pr-issue-ref.sh](../pr-issue-ref.sh) | Extract the linked issue number from a PR body via GitHub's issue-closing keywords |
| [reviewer-of.sh](../reviewer-of.sh) | Determine which reviewer (cr/bugbot/greptile) owns a PR; reads session-state then GitHub history |
| [reviewer-activity.sh](../reviewer-activity.sh) | Detect whether each AI reviewer has posted activity on a specific pushed SHA |

---

[← back to the index](../README.md)
