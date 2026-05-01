# Diagram: Hook lifecycle (this repo)

<!-- STUB: map UserPromptSubmit / PreToolUse / PostToolUse / Stop to our scripts; compare to upstream event list -->

```mermaid
sequenceDiagram
  participant U as User
  participant CC as Claude Code
  participant H as Hooks
  U->>CC: prompt
  CC->>H: UserPromptSubmit
  Note over H: TODO — list timestamp-injector, stale-worktree-warn, issue-prefix-nudge
  CC->>H: PreToolUse
  Note over H: TODO — worktree-guard, env-guard, script-bypass-detector
  CC->>H: PostToolUse
  Note over H: TODO — session-start-sync, post-merge-pull, skill-usage, silence
  CC->>H: Stop
  Note over H: TODO — silence-ack, trust-flag-repair, dirty-main-warn
```
