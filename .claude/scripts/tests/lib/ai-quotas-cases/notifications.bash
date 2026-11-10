#!/usr/bin/env bash
# Source-only quota fixture group: notifications. Run ai-quotas.test.sh.
# shellcheck source=../ai-quotas-fixtures.bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/ai-quotas-fixtures.bash"

# --- logged-out actions / scheduled notifications (#1886) ---------------------
reset_state
action_label="O'Brien account"
write_config "$(account_json codex "$action_label" "$TMP/no-action-profile")"
run --json
expected_action="/quotas-setup relogin 'O'\\''Brien account' codex"
check_eq "$(printf '%s' "$DOC" | jq -r '.rows[0].action')" "$expected_action" "logged-out JSON has exact safely quoted action"
run
check_eq "${OUT%%$'\n'*}" "$expected_action" "the account action leads text output"
check_eq "$(printf '%s' "$OUT" | awk '/quotas-setup relogin/ {n++} END {print n+0}')" "1" "the action appears once in text"
cat > "$BIN/notify-1886" <<'NOTIFY'
#!/bin/bash
printf '%s\n' "$1" >> "$NOTIFY_LOG"
NOTIFY
chmod +x "$BIN/notify-1886"
export NOTIFY_LOG="$TMP/notify-1886.log"
# Notification days use local wall time, independently of the reader's NOW.
# Freeze that clock too so consecutive scheduled runs cannot straddle midnight.
export AI_QUOTAS_NOTIFY_DAY=2001-02-03
NOTIFY_BIN_UNDER_TEST="$BIN/notify-1886"
run --json
check_eq "$(test -f "$NOTIFY_LOG" && echo yes || echo no)" "no" "manual reports do not notify"
run --json --quiet
check_eq "$(wc -l < "$NOTIFY_LOG" | tr -d ' ')" "1" "quiet scheduled JSON notifies before early exit"
run --json --quiet
check_eq "$(wc -l < "$NOTIFY_LOG" | tr -d ' ')" "1" "scheduled report deduplicates account local day"
unset NOTIFY_BIN_UNDER_TEST NOTIFY_LOG AI_QUOTAS_NOTIFY_DAY

