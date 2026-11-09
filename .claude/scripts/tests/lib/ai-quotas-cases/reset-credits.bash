#!/usr/bin/env bash
# Source-only quota fixture group: reset-credits. Run ai-quotas.test.sh.
# shellcheck source=../ai-quotas-fixtures.bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/ai-quotas-fixtures.bash"

# --- 20. Codex reset credits (#1862) ------------------------------------------
# `rateLimitResetCredits` is a SIBLING of `rateLimits` in the app-server reply,
# so a reader that keeps only `.result.rateLimits` throws the balance away.

RC_BASE="$(codex_snapshot_primary_weekly)"

EXP_SOON=1794007918   # 2026-11-06, Eastern
EXP_LATE=1796000000
EXP_GONE=1790000000

reset_state
X1="$(seed_codex_profile codex-one@example.com "$(rc_snapshot "$(jq -n \
  --argjson a "$EXP_LATE" --argjson b "$EXP_SOON" --argjson c "$EXP_GONE" \
  '{availableCount: 2, credits: [
      {status: "available", expiresAt: $a},
      {status: "available", expiresAt: $b},
      {status: "redeemed",  expiresAt: $c}]}')")")"
write_config "$(account_json codex codex-one@example.com "$X1")"
run --json
check_eq "$(field_of codex-one@example.com "7-day" free_resets_remaining)" "2" \
  "the reset count comes from the app-server's rateLimitResetCredits"
# Discriminating: the REDEEMED credit has the earliest expiry. A reader that
# took the minimum over every credit would report it.
check_eq "$(field_of codex-one@example.com "7-day" free_reset_expires_epoch)" "$EXP_SOON" \
  "the expiry is the soonest among credits still available, not among all of them"
check_eq "$(field_of codex-one@example.com "7-day" free_reset_expires_et_short)" "Nov 6 6:31 PM ET" \
  "and is rendered as an Eastern date and time, since the last day turns on the hour"

reset_state
X1="$(seed_codex_profile codex-one@example.com "$(rc_snapshot '{"availableCount": 0, "credits": []}')")"
write_config "$(account_json codex codex-one@example.com "$X1")"
run --json
check_eq "$(field_of codex-one@example.com "7-day" free_resets_remaining)" "0" \
  "an account with no reset credits reports zero, not an absence"
check_eq "$(field_of codex-one@example.com "7-day" free_reset_expires_epoch)" "null" \
  "and has no expiry"

reset_state
X1="$(seed_codex_profile codex-one@example.com "$(codex_snapshot_primary_weekly)")"
write_config "$(account_json codex codex-one@example.com "$X1")"
run --json
check_eq "$(field_of codex-one@example.com "7-day" free_resets_remaining)" "null" \
  "control(-): a reply without the section leaves the count null, so the monthly fallback answers"

reset_state
X1="$(seed_codex_profile codex-one@example.com "$(rc_snapshot '{"availableCount": "abc", "credits": "nope"}')")"
write_config "$(account_json codex codex-one@example.com "$X1")"
run --json
check_eq "$(field_of codex-one@example.com "7-day" free_resets_remaining)" "null" \
  "a count that is not a number contributes nothing"
check_eq "$(field_of codex-one@example.com "7-day" free_reset_expires_epoch)" "null" \
  "and credits that are not a list contribute no expiry"
check_eq "$(field_of codex-one@example.com "7-day" status)" "ok" \
  "and the row still reads ok"

# A measured count outranks a guessed key: a guess nobody has seen must not override
# what Codex really sent, even when the guess is a valid number.
reset_state
X1="$(seed_codex_profile codex-one@example.com "$(codex_snapshot_primary_weekly | jq -c '. + {freeResetsRemaining: 1, rateLimitResetCredits: {availableCount: 0}}')")"
write_config "$(account_json codex codex-one@example.com "$X1")"
run --json
check_eq "$(field_of codex-one@example.com "7-day" free_resets_remaining)" "0" \
  "the measured rateLimitResetCredits count outranks a guessed freeResetsRemaining"

# A malformed value in an EARLIER key must not hide a valid count in a later one.
reset_state
X1="$(seed_codex_profile codex-one@example.com "$(codex_snapshot_primary_weekly | jq -c '. + {freeResetsRemaining: "n/a", rateLimitResetCredits: {availableCount: 5}}')")"
write_config "$(account_json codex codex-one@example.com "$X1")"
run --json
check_eq "$(field_of codex-one@example.com "7-day" free_resets_remaining)" "5" \
  "the first candidate that is a number wins, not the first key that is present"

reset_state
X1="$(seed_codex_profile codex-one@example.com "$(rc_snapshot '{"availableCount": 3}')")"
write_config "$(account_json codex codex-one@example.com "$X1")"
run --json
check_eq "$(field_of codex-one@example.com "7-day" free_resets_remaining)" "3" \
  "a count with no credit list is still a count"
check_eq "$(field_of codex-one@example.com "7-day" free_reset_expires_epoch)" "null" \
  "with no expiry to report"

# The HTTP fallback carries the same summary under its own key names, as a
# sibling of the nested window data.
reset_state
X1="$(seed_codex_profile codex-one@example.com "$(codex_snapshot_primary_weekly)")"
write_config "$(account_json codex codex-one@example.com "$X1")"
rm -f "$X1/rate-limits.json"
jq -n --argjson week "$WEEK_RESET" \
  '{rate_limits: {planType: "pro",
                  primary: {usedPercent: 88, windowDurationMins: 10080, resetsAt: $week},
                  secondary: null},
    rate_limit_reset_credits: {available_count: 4}}' > "$STUB_CHATGPT_BODY"
run --json
check_eq "$(field_of codex-one@example.com "7-day" source)" "http" \
  "the HTTP fallback path ran"
check_eq "$(field_of codex-one@example.com "7-day" free_resets_remaining)" "4" \
  "and its sibling rate_limit_reset_credits.available_count is kept"

