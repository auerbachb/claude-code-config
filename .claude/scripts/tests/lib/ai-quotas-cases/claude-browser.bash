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
check_eq "$RC" "3" "a Cursor-provider file names no account for a Claude-only label: usage error (#2337)"
cb_obs ok "$CB_OTHER" claude "$CB_OTHER" "$NOW" "$CB_ROWS_OK"
run --json --account "$CB_LABEL" --browser-results "$CB_OBS"
check_eq "$(field_of "$CB_LABEL" 7-day status)" "unreadable" "a wrong-label observation is rejected"

# A Claude observation handed to a Cursor account is rejected by provider.
reset_state
seed_cursor_account
cb_obs ok "cursor-one@example.com" claude "cursor-one@example.com" "$NOW" "$CB_ROWS_OK"
run --json --account cursor-one@example.com --browser-results "$CB_OBS"
check_eq "$RC" "3" "a Claude observation for a Cursor-only label is a usage error (#2337)"

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

# --- 24. Shared labels and organization-ID binding (#2337) -------------------
#
# A Codex account may share a Claude account's label. The observation's provider
# selects the account, and the Codex account is left out of the browser pass.
# Organization IDs are made-up UUIDs; no real identifier belongs in a fixture.
CB_ORG="6f1c2a4e-0d3b-4c5e-9a7b-123456789abc"
CB_ORG_OTHER="0a0a0a0a-0b0b-4c0c-8d0d-e1e1e1e1e1e1"

cb_setup_shared() { # — one Claude and one Codex account registered under the same label
  reset_state
  rm -rf "$CB_DIR_ROOT"; mkdir -p "$CB_DIR_ROOT"
  export AI_QUOTAS_LAST_KNOWN_DIR="$CB_DIR_ROOT/last-known"
  local dir
  dir="$(seed_claude_profile "$CB_LABEL" "Claude-browser-svc")"
  echo ratelimit > "$STUB_ANTHROPIC_MODE"
  mkdir -p "$TMP/codex-shared"
  write_config "$(account_json claude "$CB_LABEL" "$dir" Claude-browser-svc)" \
    "$(account_json codex "$CB_LABEL" "$TMP/codex-shared")"
}

cb_obs_org() { # <identity-json> — a Claude observation whose identity fields are exactly the given object
  jq -n --arg lb "$CB_LABEL" --argjson ob "$NOW" --argjson rows "$CB_ROWS_OK" --argjson id "$1" \
    '{schema_version: 1, provider: "claude", label: $lb, status: "ok", observed_at_epoch: $ob, rows: $rows} + $id' > "$CB_OBS"
  chmod 600 "$CB_OBS"
}

cb_profile_identity() { # <profile-json-object> — replaces the profile's oauthAccount block for this label
  printf '{"oauthAccount":%s}\n' "$1" > "$PROFILES/$CB_LABEL/claude/.claude.json"
}

# The shared label resumes only the Claude account the observation names.
cb_setup_shared
cb_obs ok "$CB_LABEL" claude "$CB_LABEL" "$NOW" "$CB_ROWS_OK"
run --json --account "$CB_LABEL" --browser-results "$CB_OBS"
check_eq "$RC" "0" "a shared label resumes the Claude account named by the observation provider"
check_eq "$(field_of "$CB_LABEL" 7-day status)" "ok" "the shared-label Claude row is ok"
check_eq "$(field_of "$CB_LABEL" 7-day source)" "browser" "the shared-label Claude row names the browser source"
check_eq "$(printf '%s' "$OUT" | jq --arg l "$CB_LABEL" '[.[] | select(.label == $l and .provider == "codex")] | length')" "0" "the Codex account sharing the label is left out of the browser pass"
check_eq "$(grep -c '"provider":"codex"' "$CB_LEDGER" 2>/dev/null || true)" "0" "the Codex account writes no outcomes-ledger entry for the observation"

# A file whose provider has no account with that label is a usage error (exit 3).
reset_state
write_config "$(account_json codex "$CB_LABEL" "$TMP/codex-only")"
cb_obs ok "$CB_LABEL" claude "$CB_LABEL" "$NOW" "$CB_ROWS_OK"
run --json --account "$CB_LABEL" --browser-results "$CB_OBS"
check_eq "$RC" "3" "a Claude observation for a label registered only under Codex is a usage error"

# A provider other than cursor or claude, or an unreadable file, is a usage error.
cb_setup_shared
cb_obs ok "$CB_LABEL" codex "$CB_LABEL" "$NOW" "$CB_ROWS_OK"
run --json --account "$CB_LABEL" --browser-results "$CB_OBS"
check_eq "$RC" "3" "an observation naming an unsupported provider is a usage error"
run --json --account "$CB_LABEL" --browser-results "$TMP/claude-browser-missing.json"
check_eq "$RC" "3" "a missing observation file is a usage error"
printf 'not json' > "$CB_OBS"; chmod 600 "$CB_OBS"
run --json --account "$CB_LABEL" --browser-results "$CB_OBS"
check_eq "$RC" "3" "a malformed observation file is a usage error, not an empty report"

# Organization-ID binding (#2337): the email stays required; an organization ID is an extra
# check that is compared only when the profile records one, and never identifies a user alone.
cb_profile_identity "{\"emailAddress\":\"$CB_LABEL\",\"organizationUuid\":\"$CB_ORG\"}"
cb_obs_org "{\"email\":\"$CB_LABEL\",\"organization_id\":\"$CB_ORG\"}"
run --json --account "$CB_LABEL" --browser-results "$CB_OBS"
check_eq "$(field_of "$CB_LABEL" 7-day status)" "ok" "an email and organization ID that both match verify the observation"
check_eq "$(field_of "$CB_LABEL" 7-day source)" "browser" "a fully matched row names the browser source"

# An organization ID with no email is rejected: an organization can have several members.
cb_setup "$CB_LABEL"
cb_profile_identity "{\"emailAddress\":\"$CB_LABEL\",\"organizationUuid\":\"$CB_ORG\"}"
cb_obs_org "{\"organization_id\":\"$CB_ORG\"}"
run --json --account "$CB_LABEL" --browser-results "$CB_OBS"
check_eq "$(field_of "$CB_LABEL" 7-day status)" "unreadable" "a matching organization ID alone never verifies a Claude observation"
check_eq "$(cb_ledger_class)" "browser_observation_rejected" "an organization-only observation is the fixed rejected class"

# A non-matching organization ID is rejected even when the email matches.
cb_setup "$CB_LABEL"
cb_profile_identity "{\"emailAddress\":\"$CB_LABEL\",\"organizationUuid\":\"$CB_ORG\"}"
cb_obs_org "{\"email\":\"$CB_LABEL\",\"organization_id\":\"$CB_ORG_OTHER\"}"
run --json --account "$CB_LABEL" --browser-results "$CB_OBS"
check_eq "$(field_of "$CB_LABEL" 7-day status)" "unreadable" "a non-matching organization ID is rejected with a matching email"
check_eq "$(cb_ledger_class)" "browser_observation_rejected" "a non-matching organization ID is the fixed rejected class"

# A profile with no recorded organization ID has nothing to compare: a valid email match is still accepted.
cb_setup "$CB_LABEL"
cb_profile_identity "{\"emailAddress\":\"$CB_LABEL\"}"
cb_obs_org "{\"email\":\"$CB_LABEL\",\"organization_id\":\"$CB_ORG\"}"
run --json --account "$CB_LABEL" --browser-results "$CB_OBS"
check_eq "$(field_of "$CB_LABEL" 7-day status)" "ok" "a profile without an organization ID does not reject a valid email match"

# An email match with no organization ID anywhere stays accepted, as before.
cb_setup "$CB_LABEL"
cb_profile_identity "{\"emailAddress\":\"$CB_LABEL\"}"
cb_obs_org "{\"email\":\"$CB_LABEL\"}"
run --json --account "$CB_LABEL" --browser-results "$CB_OBS"
check_eq "$(field_of "$CB_LABEL" 7-day status)" "ok" "an email-only observation with no organization ID is unchanged"

# An observation with neither field is rejected.
cb_setup "$CB_LABEL"
cb_profile_identity "{\"emailAddress\":\"$CB_LABEL\",\"organizationUuid\":\"$CB_ORG\"}"
cb_obs_org "{}"
run --json --account "$CB_LABEL" --browser-results "$CB_OBS"
check_eq "$(field_of "$CB_LABEL" 7-day status)" "unreadable" "an observation with neither email nor organization ID is rejected"

# A matching organization ID does not rescue a mismatched email.
cb_setup "$CB_LABEL"
cb_profile_identity "{\"emailAddress\":\"$CB_LABEL\",\"organizationUuid\":\"$CB_ORG\"}"
cb_obs_org "{\"email\":\"$CB_OTHER\",\"organization_id\":\"$CB_ORG\"}"
run --json --account "$CB_LABEL" --browser-results "$CB_OBS"
check_eq "$(field_of "$CB_LABEL" 7-day status)" "unreadable" "a matching organization ID does not carry a non-matching email"

# A conflicting profile email is an unknown identity: a matching organization ID cannot rescue it.
cb_setup "$CB_LABEL"
cb_profile_identity "{\"emailAddress\":\"$CB_OTHER\",\"organizationUuid\":\"$CB_ORG\"}"
cb_obs_org "{\"email\":\"$CB_LABEL\",\"organization_id\":\"$CB_ORG\"}"
run --json --account "$CB_LABEL" --browser-results "$CB_OBS"
check_eq "$(field_of "$CB_LABEL" 7-day status)" "unreadable" "a conflicting profile email is not rescued by a matching organization ID"

# Unset the group's private folder override so later groups see their own defaults.
unset AI_QUOTAS_LAST_KNOWN_DIR
