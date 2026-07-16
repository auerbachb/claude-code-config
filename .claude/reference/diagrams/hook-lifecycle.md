# Diagram: Hook lifecycle (this repo)

<!-- STUB: map UserPromptSubmit / PreToolUse / PostToolUse / Stop to our scripts; compare to upstream event list -->

```mermaid
sequenceDiagram
  participant U as User
  participant CC as Claude Code
  participant H as Hooks
  U->>CC: prompt
  CC->>H: UserPromptSubmit
  Note over H: timestamp-injector.sh, stale-worktree-warn.sh, issue-prefix-nudge.sh, skill-command-tracker.sh
  CC->>H: PreToolUse
  Note over H: worktree-guard.sh, env-guard.py, script-bypass-detector.sh
  CC->>H: PostToolUse
  Note over H: session-start-sync.sh, post-merge-pull.sh, polling-backoff-warn.sh, skill-usage-tracker.sh, silence-detector.sh
  CC->>H: Stop
  Note over H: silence-detector-ack.sh, trust-flag-repair.sh, dirty-main-warn.sh
```

Skill telemetry straddles two of these events (#584): `skill-command-tracker.sh` catches user-typed slash commands at UserPromptSubmit — they arrive pre-expanded and never produce a `Skill` tool call — while `skill-usage-tracker.sh` catches model-initiated calls at PostToolUse. Both write through `.claude/hooks/lib/skill-usage-recorder.sh`, which dedupes so an invocation seen by both paths still counts once. See `.claude/memory/skill_usage_telemetry.md`.
