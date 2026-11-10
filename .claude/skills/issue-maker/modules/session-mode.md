# Switch capture mode

> Load only for: explicit "switch to rapid-fire mode" or "switch to default mode" request
> Prerequisites: `session:state` restored the conversation log and initialized `set_log`

Parse only the two explicit mode requests. If the request names `rapid-fire`, set `REQUESTED_MODE=rapid-fire`; if it names `default`, set `REQUESTED_MODE=default`. For any other value, stop without changing the log.

Persist the switch to this conversation's log before acknowledging it. Do not seed the mode from `$ARGUMENTS` on a recovered session, and do not change issue, offer, or execution state:

```bash
case "$REQUESTED_MODE" in
  default|rapid-fire) ;;
  *) echo "ERROR: unsupported capture mode; choose default or rapid-fire" >&2; exit 2 ;;
esac
set_log '.mode = $mode' --arg mode "$REQUESTED_MODE" || {
  echo "ERROR: could not persist capture mode; the prior mode remains active" >&2
  exit 1
}
MODE="$REQUESTED_MODE"
jq -e --arg mode "$MODE" '.mode == $mode' "$LOG" >/dev/null || {
  echo "ERROR: capture mode change could not be verified; do not claim the mode switched" >&2
  exit 1
}
```

After verification, acknowledge the new mode. The change affects subsequent issue capture/report behavior only; current offers and already-filed issues remain unchanged.
