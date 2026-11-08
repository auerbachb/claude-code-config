# Published pre-1646 post-merge fences, retained as cwd-drift counterfactuals.

<!-- test-anchor: old-wrap-main-sync -->

```bash
ROOT_REPO=$([[ -n "$REPO_ROOT_SH" ]] && "$REPO_ROOT_SH" 2>/dev/null || true)
MAIN_SYNC_STATUS=""
QUARANTINE_STATUS=""
QUARANTINE_OK=0
if [ -z "$ROOT_REPO" ] || [ ! -d "$ROOT_REPO" ]; then
  MAIN_SYNC_STATUS="failed: could not determine root repo path"
else
  if [[ -n "$DIRTY_MAIN_GUARD_SH" ]] && "$DIRTY_MAIN_GUARD_SH" --check --repo "$ROOT_REPO" >/dev/null 2>&1; then
    QUARANTINE_STATUS="clean"
    QUARANTINE_OK=1
  elif [[ -z "$DIRTY_MAIN_GUARD_SH" ]]; then
    QUARANTINE_STATUS="DEGRADED: dirty-main-guard.sh not found (checked all three paths) — quarantine unavailable"
  else
    QUARANTINE_RC=0
    QUARANTINE_STATUS=$("$DIRTY_MAIN_GUARD_SH" --quarantine --repo "$ROOT_REPO" 2>&1) || QUARANTINE_RC=$?
    if [[ "$QUARANTINE_RC" -eq 0 ]]; then
      QUARANTINE_OK=1
    else
      QUARANTINE_STATUS="failed(rc=$QUARANTINE_RC): $QUARANTINE_STATUS"
    fi
  fi
  MAIN_SYNC_RC=0
  if [[ "$QUARANTINE_OK" -ne 1 ]]; then
    MAIN_SYNC_RC=1
    MAIN_SYNC_STATUS="skipped: root quarantine did not complete; aggressive reset was not run"
  elif [[ -z "$MAIN_SYNC_SH" ]]; then
    MAIN_SYNC_RC=127
    MAIN_SYNC_STATUS="ERROR: main-sync.sh not found (checked all three paths) — root main sync unavailable"
  else
    MAIN_SYNC_STATUS=$("$MAIN_SYNC_SH" --reset --repo "$ROOT_REPO" 2>&1) || MAIN_SYNC_RC=$?
  fi
  if [ "$MAIN_SYNC_RC" -ne 0 ] && ! [[ "$MAIN_SYNC_STATUS" == aborted:* || "$MAIN_SYNC_STATUS" == skipped:* ]]; then
    MAIN_SYNC_STATUS="failed(rc=$MAIN_SYNC_RC): $MAIN_SYNC_STATUS"
  fi
fi
if [ "$WRAP_VERBOSE" = "1" ]; then
  echo "Main quarantine: $QUARANTINE_STATUS"
  echo "Main sync: $MAIN_SYNC_STATUS"
fi
```

<!-- test-anchor: old-merge-main-sync -->

```bash
# .claude/scripts/main-sync.sh writes the status line to stdout and exits
# 0 OK / 1 skipped (uncommitted) / 2 failed (checkout/pull). All three
# outcomes are captured here for the completion report — a non-zero exit
# is not a hard error for /merge, just a report-worthy condition.
if [[ -z "$MAIN_SYNC_SH" ]]; then
  MAIN_SYNC_STATUS="DEGRADED: main-sync.sh not found (checked all three paths) — post-merge main sync unavailable"
else
  MAIN_SYNC_STATUS=$("$MAIN_SYNC_SH" 2>&1 || true)
fi
echo "Main sync: $MAIN_SYNC_STATUS"
```
