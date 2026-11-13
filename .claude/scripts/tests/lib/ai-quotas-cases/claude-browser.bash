#!/usr/bin/env bash
# Source-only quota fixture group: claude-browser. Run ai-quotas.test.sh.
# shellcheck source=../ai-quotas-fixtures.bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/ai-quotas-fixtures.bash"

# --- 23. Claude browser observation source (#2299) ---------------------------
#
# The OAuth renewal is rate-limited (429 fixture), so the normal read fails and
# the browser source is the only way to a figure. Every observation is a private
# file written by this group; the reader is never pointed at the owner's store.
# Example addresses only: no real account identity belongs in a fixture.

CB_LABEL="claude-browser@example.com"
CB_OTHER="someone-else@example.com"
CB_DIR_ROOT="$TMP/claude-browser"
CB_OBS="$TMP/claude-browser-obs.json"
CB_ROWS_OK="[{\"window\":\"7-day\",\"used_pct\":64,\"resets_at_epoch\":$WEEK_RESET},{\"window\":\"5-hour\",\"used_pct\":12,\"resets_at_epoch\":$FIVE_RESET}]"
CB_LEDGER="$CASE_HOME/.claude/ai-quotas-history.outcomes.jsonl"

cb_setup() { # <label> — rate-limited renewal, one Claude account, no profile email
  reset_state
  rm -rf "$CB_DIR_ROOT"; mkdir -p "$CB_DIR_ROOT"
  export AI_QUOTAS_LAST_KNOWN_DIR="$CB_DIR_ROOT/last-known"
  local dir
  dir="$(seed_claude_profile "$1" "Claude-browser-svc")"
  echo ratelimit > "$STUB_ANTHROPIC_MODE"
  write_config "$(account_json claude "$1" "$dir" Claude-browser-svc)"
}

cb_obs() { # <status> <email> <provider> <label> <observed-epoch> <rows-json>
  jq -n --arg st "$1" --arg em "$2" --arg pv "$3" --arg lb "$4" --argjson ob "$5" --argjson rows "$6" \
    '{schema_version: 1, provider: $pv, label: $lb, email: $em, status: $st, observed_at_epoch: $ob, rows: $rows}' > "$CB_OBS"
  chmod 600 "$CB_OBS"
}

cb_ledger_class() { # — the last browser error class recorded in the outcomes ledger
  jq -r 'select(.source == "browser") | .error_class' "$CB_LEDGER" 2>/dev/null | tail -n 1
}

# Plain --browser never opens a page for Claude: an agent-collected observation is required.
cb_setup "$CB_LABEL"
run --json --browser
check_eq "$RC" "0" "plain --browser for Claude completes without a browser attempt"
check_eq "$(field_of "$CB_LABEL" 7-day status)" "unreadable" "plain --browser leaves the failed Claude row failed"
check_contains "$(field_of "$CB_LABEL" 7-day detail)" "agent-collected" "plain --browser names the agent-collected path"
check_eq "$(cb_ledger_class)" "browser_agent_observation_required" "plain --browser records a fixed agent-path outcome class"

# A valid ok observation resumes exactly this account and skips the OAuth renewal.
cb_setup "$CB_LABEL"
cb_obs ok "$CB_LABEL" claude "$CB_LABEL" "$NOW" "$CB_ROWS_OK"
BEFORE_CALLS="$(wc -l < "$STUB_CURL_LOG" | tr -d ' ')"
run --json --account "$CB_LABEL" --browser-results "$CB_OBS"
check_eq "$RC" "0" "a valid Claude observation resumes exactly one account"
check_eq "$(field_of "$CB_LABEL" 7-day status)" "ok" "a valid Claude observation makes the row ok"
check_eq "$(field_of "$CB_LABEL" 7-day used_pct)" "64" "the observed weekly percentage is shown"
check_eq "$(field_of "$CB_LABEL" 7-day source)" "browser" "the ok row names the browser source"
check_eq "$(field_of "$CB_LABEL" 7-day resets_at_epoch)" "$WEEK_RESET" "the observed weekly reset time is shown"
check_eq "$(field_of "$CB_LABEL" 5-hour status)" "" "the five-hour row is shown only with --five-hour"
check_eq "$(wc -l < "$STUB_CURL_LOG" | tr -d ' ')" "$BEFORE_CALLS" "resume performs no OAuth renewal or usage request"
check_eq "$(grep -rl 'live: browser' "$CB_DIR_ROOT/last-known" 2>/dev/null | wc -l | tr -d ' ')" "1" "an ok browser read is saved through the last-known record path"

# --five-hour shows the five-hour window too, observed as the agent read it.
cb_setup "$CB_LABEL"
cb_obs ok "$CB_LABEL" claude "$CB_LABEL" "$NOW" "$CB_ROWS_OK"
run --json --five-hour --account "$CB_LABEL" --browser-results "$CB_OBS"
check_eq "$(field_of "$CB_LABEL" 5-hour used_pct)" "12" "--five-hour shows the observed five-hour percentage"

# A rendered email that is not this account is rejected; the row keeps its failure.
cb_setup "$CB_LABEL"
cb_obs ok "$CB_OTHER" claude "$CB_LABEL" "$NOW" "$CB_ROWS_OK"
run --json --account "$CB_LABEL" --browser-results "$CB_OBS"
check_eq "$(field_of "$CB_LABEL" 7-day status)" "unreadable" "an account mismatch keeps the row failed"
check_eq "$(cb_ledger_class)" "browser_observation_rejected" "an account mismatch is a fixed rejected class"

# A label that is not an email, with no profile email, has no known identity: reject.
cb_setup "claude-noemail"
cb_obs ok "claude-noemail@example.com" claude "claude-noemail" "$NOW" "$CB_ROWS_OK"
run --json --account claude-noemail --browser-results "$CB_OBS"
check_eq "$(field_of claude-noemail 7-day status)" "unreadable" "an unknown expected identity rejects the observation"
check_eq "$(cb_ledger_class)" "browser_observation_rejected" "an unknown identity is a fixed rejected class"

# Conflicting identity evidence (profile says another address) is unknown, and rejected.
cb_setup "$CB_LABEL"
printf '{"oauthAccount":{"emailAddress":"%s"}}\n' "$CB_OTHER" > "$PROFILES/$CB_LABEL/claude/.claude.json"
cb_obs ok "$CB_LABEL" claude "$CB_LABEL" "$NOW" "$CB_ROWS_OK"
run --json --account "$CB_LABEL" --browser-results "$CB_OBS"
check_eq "$(field_of "$CB_LABEL" 7-day status)" "unreadable" "conflicting profile and label identities reject the observation"
# A profile email that agrees with the label is the verified identity, and the observation is accepted.
printf '{"oauthAccount":{"emailAddress":"%s"}}\n' "$CB_LABEL" > "$PROFILES/$CB_LABEL/claude/.claude.json"
run --json --account "$CB_LABEL" --browser-results "$CB_OBS"
check_eq "$(field_of "$CB_LABEL" 7-day status)" "ok" "a profile email that matches the label verifies the identity"

# A signed-out page yields needs-login with an action naming the claude.ai page; nothing logs in.
cb_setup "$CB_LABEL"
cb_obs logged_out "" claude "$CB_LABEL" "$NOW" "[]"
run --json --account "$CB_LABEL" --browser-results "$CB_OBS"
check_eq "$(field_of "$CB_LABEL" 7-day status)" "needs-login" "a signed-out observation yields needs-login"
check_contains "$(field_of "$CB_LABEL" 7-day action)" "claude.ai usage page" "the sign-in action names the claude.ai usage page"

# Stale, wrong provider, and wrong label observations are each rejected.
cb_setup "$CB_LABEL"
cb_obs ok "$CB_LABEL" claude "$CB_LABEL" "$((NOW - 3600))" "$CB_ROWS_OK"
run --json --account "$CB_LABEL" --browser-results "$CB_OBS"
check_eq "$(field_of "$CB_LABEL" 7-day status)" "unreadable" "a stale observation is rejected"
cb_obs ok "$CB_LABEL" cursor "$CB_LABEL" "$NOW" "$CB_ROWS_OK"
run --json --account "$CB_LABEL" --browser-results "$CB_OBS"
check_eq "$(field_of "$CB_LABEL" 7-day status)" "unreadable" "a Cursor-provider file is rejected for a Claude account"
cb_obs ok "$CB_OTHER" claude "$CB_OTHER" "$NOW" "$CB_ROWS_OK"
run --json --account "$CB_LABEL" --browser-results "$CB_OBS"
check_eq "$(field_of "$CB_LABEL" 7-day status)" "unreadable" "a wrong-label observation is rejected"

# A Claude observation handed to a Cursor account is rejected by provider.
reset_state
seed_cursor_account
cb_obs ok "cursor-one@example.com" claude "cursor-one@example.com" "$NOW" "$CB_ROWS_OK"
run --json --account cursor-one@example.com --browser-results "$CB_OBS"
check_eq "$(cb_ledger_class)" "browser_observation_rejected" "a Claude observation passed with a Cursor account is rejected"

# One window null and one numeric: the numeric one is ok, the null one is never invented.
cb_setup "$CB_LABEL"
cb_obs ok "$CB_LABEL" claude "$CB_LABEL" "$NOW" "[{\"window\":\"7-day\",\"used_pct\":null,\"resets_at_epoch\":null},{\"window\":\"5-hour\",\"used_pct\":12,\"resets_at_epoch\":$FIVE_RESET}]"
run --json --five-hour --account "$CB_LABEL" --browser-results "$CB_OBS"
check_eq "$(field_of "$CB_LABEL" 5-hour status)" "ok" "a numeric window in a partial observation is ok"
check_eq "$(field_of "$CB_LABEL" 7-day status)" "unreadable" "a null window is reported unreadable, not invented"
check_eq "$(field_of "$CB_LABEL" 7-day used_pct)" "null" "a null window carries no percentage"

# Without --five-hour the numeric five-hour window is hidden, yet the unreadable weekly
# row is reported exactly once: no duplicate fallback row for the same account.
cb_setup "$CB_LABEL"
cb_obs ok "$CB_LABEL" claude "$CB_LABEL" "$NOW" "[{\"window\":\"7-day\",\"used_pct\":null,\"resets_at_epoch\":null},{\"window\":\"5-hour\",\"used_pct\":12,\"resets_at_epoch\":$FIVE_RESET}]"
run --json --account "$CB_LABEL" --browser-results "$CB_OBS"
check_eq "$(printf '%s' "$OUT" | jq --arg l "$CB_LABEL" '[.[] | select(.label == $l and .window == "7-day")] | length')" "1" "a hidden five-hour window does not duplicate an unreadable weekly row"
check_eq "$(field_of "$CB_LABEL" 7-day status)" "unreadable" "the single weekly row stays unreadable"

# A Cursor window name in a Claude observation is malformed.
cb_setup "$CB_LABEL"
cb_obs ok "$CB_LABEL" claude "$CB_LABEL" "$NOW" "[{\"window\":\"cursor-models\",\"used_pct\":5,\"resets_at_epoch\":null}]"
run --json --account "$CB_LABEL" --browser-results "$CB_OBS"
check_eq "$(field_of "$CB_LABEL" 7-day status)" "unreadable" "a malformed Claude window is rejected"

# Scheduled runs never open a browser and record the same skip Cursor records.
cb_setup "$CB_LABEL"
run --json --quiet --account "$CB_LABEL"
check_eq "$(field_of "$CB_LABEL" 7-day status)" "rate-limited" "a scheduled Claude run keeps the OAuth failure"
check_eq "$(tail -n 1 "$CB_LEDGER" | jq -r '.skip_reason')" "browser-unattended" "a scheduled Claude run records the browser-unattended skip"

# Unset the group's private folder override so later groups see their own defaults.
unset AI_QUOTAS_LAST_KNOWN_DIR
