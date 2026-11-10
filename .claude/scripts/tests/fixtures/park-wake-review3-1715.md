# Published PR #2050 R3 wake-publication fences

Commit: 254017729bc25f19dd3a4816277ebc3b7313f8a2. Regression input only.

<!-- test-anchor: pm-day-2d6-wake-publish -->

```bash
# TaskStop is the harness tool; stop only the Monitor this invocation armed.
WAKE_PUBLISH_SH=""
for candidate in "${HOME:+$HOME/.claude/skills-worktree/.claude/scripts/park-wake-publish.sh}" "${HOME:+$HOME/.claude/scripts/park-wake-publish.sh}" ".claude/scripts/park-wake-publish.sh"; do
  if [ -x "$candidate" ]; then WAKE_PUBLISH_SH="$candidate"; break; fi
done
PUBLISH_RC=4
if [ -n "$WAKE_PUBLISH_SH" ]; then
  PUBLISH_RC=0
  "$WAKE_PUBLISH_SH" --repo "$REPO_KEY" --cause reactive \
    --task-id "$LIMIT_MONITOR_TASK_ID" --generation "$LIMIT_GENERATION" \
    --park-generation "${PARK_GENERATION:-}" --task-encoding json-or-string --state-helper "$SESSION_STATE_SH" >/dev/null || PUBLISH_RC=$?
fi
if [ "$PUBLISH_RC" -eq 0 ]; then
  echo "WAKE_PUBLISH=armed"
elif TaskStop "$LIMIT_MONITOR_TASK_ID"; then
  if [ "$PUBLISH_RC" -eq 7 ]; then echo "WAKE_PUBLISH=lost"; else echo "WAKE_PUBLISH=failed"; fi
else
  echo "WAKE_PUBLISH=stranded"
fi
```

<!-- test-anchor: pm-day-2d7-wake-publish -->

```bash
# TaskStop is the harness tool; stop only the Monitor this invocation armed.
WAKE_PUBLISH_SH=""
for candidate in "${HOME:+$HOME/.claude/skills-worktree/.claude/scripts/park-wake-publish.sh}" "${HOME:+$HOME/.claude/scripts/park-wake-publish.sh}" ".claude/scripts/park-wake-publish.sh"; do
  if [ -x "$candidate" ]; then WAKE_PUBLISH_SH="$candidate"; break; fi
done
PUBLISH_RC=4
if [ -n "$WAKE_PUBLISH_SH" ]; then
  PUBLISH_RC=0
  "$WAKE_PUBLISH_SH" --repo "$REPO_KEY" --cause preemptive \
    --task-id "$WAKE_TASK_ID" --generation "$WAKE_GENERATION" \
    --park-generation "${PARK_GENERATION:-}" --task-encoding string --state-helper "$SESSION_STATE_SH" >/dev/null || PUBLISH_RC=$?
fi
if [ "$PUBLISH_RC" -eq 0 ]; then
  echo "WAKE_PUBLISH=armed"
elif TaskStop "$WAKE_TASK_ID"; then
  if [ "$PUBLISH_RC" -eq 7 ]; then echo "WAKE_PUBLISH=lost"; else echo "WAKE_PUBLISH=failed"; fi
else
  echo "WAKE_PUBLISH=stranded"
fi
```

<!-- test-anchor: subagent-limit-wake-publish -->

```bash
# The original winning claim's durable generation is an input, not re-read here.
WAKE_PUBLISH_SH=""
for candidate in "${HOME:+$HOME/.claude/skills-worktree/.claude/scripts/park-wake-publish.sh}" "${HOME:+$HOME/.claude/scripts/park-wake-publish.sh}" ".claude/scripts/park-wake-publish.sh"; do
  if [ -x "$candidate" ]; then WAKE_PUBLISH_SH="$candidate"; break; fi
done
PUBLISH_RC=4
if [ -n "$WAKE_PUBLISH_SH" ]; then
  PUBLISH_RC=0
  "$WAKE_PUBLISH_SH" --repo "$REPO_KEY" --cause "${PARK_CAUSE:-reactive}" \
    --task-id "$LIMIT_MONITOR_TASK_ID" --generation "$WAKE_GENERATION" \
    --park-generation "${PARK_GENERATION:-}" --task-encoding json-or-string \
    --state-helper "$SESSION_STATE_SH" >/dev/null || PUBLISH_RC=$?
fi
case "$PUBLISH_RC" in
  0) echo "WAKE_PUBLISH=ok" ;;
  7) echo "WAKE_PUBLISH=superseded" ;;  # retired/replaced/occupied — stop only ours
  *) echo "WAKE_PUBLISH=error rc=$PUBLISH_RC" ;;
esac

```
