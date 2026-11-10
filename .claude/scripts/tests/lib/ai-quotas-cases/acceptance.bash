#!/usr/bin/env bash
# Source-only quota fixture group: acceptance. Run ai-quotas.test.sh.
# shellcheck source=../ai-quotas-fixtures.bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/ai-quotas-fixtures.bash"

# --- 5. the acceptance table: two claude + two codex accounts ----------------

reset_state
C1="$(seed_claude_profile claude-one@example.com "Claude Code-credentials-AAA")"
C2="$(seed_claude_profile claude-two@example.com "Claude Code-credentials-BBB")"
X1="$(seed_codex_profile codex-one@example.com "$(codex_snapshot_primary_weekly)")"
X2="$(seed_codex_profile codex-two@example.com "$(codex_snapshot_both)")"
write_config \
  "$(account_json claude claude-one@example.com "$C1" "Claude Code-credentials-AAA")" \
  "$(account_json claude claude-two@example.com "$C2" "Claude Code-credentials-BBB")" \
  "$(account_json codex codex-one@example.com "$X1")" \
  "$(account_json codex codex-two@example.com "$X2")"

run --json
check_eq "$RC" "0" "four registered accounts exit 0"
check_eq "$(printf '%s' "$OUT" | jq 'length')" "4" "four weekly rows, one per account"
check_eq "$(printf '%s' "$OUT" | jq -r '[.[] | select(.status == "ok")] | length')" "4" \
  "every row reads ok"
check_eq "$(field_of claude-one@example.com "7-day" used_pct)" "64" "the claude weekly used % comes from seven_day"
check_eq "$(field_of claude-one@example.com "7-day" remaining_pct)" "36" "remaining % is 100 - used"

# The whole point of selecting by windowDurationMins: this account reports
# its weekly figures in `primary` with `secondary` null. A position-based
# reader renders nothing here.
check_eq "$(field_of codex-one@example.com "7-day" used_pct)" "71" \
  "the codex weekly window is found in primary when secondary is null"
check_eq "$(field_of codex-two@example.com "7-day" used_pct)" "45" \
  "and in secondary when that is where the 10080-minute window lives"
check_eq "$(field_of codex-two@example.com "7-day" plan)" "plus" "planType is reported"
check_eq "$(field_of codex-one@example.com "7-day" source)" "app-server" \
  "the row says which path produced it"

# Reported email, not the label: this is what makes a mislabelled account
# visible. The codex fixture's JWT carries a DIFFERENT address from its label
# only for the claude accounts, so assert both directions.
check_eq "$(field_of codex-one@example.com "7-day" reported_email)" "codex-one@example.com" \
  "the codex row is labelled with the email the id_token reports"
check_eq "$(field_of claude-two@example.com "7-day" reported_email)" "claude-one@example.com" \
  "a claude row carries the email the provider reports, even when it differs from the label"

# The reader must ask the Keychain for exactly the services the registry
# recorded for these two accounts — no more. The stub logs every lookup, so
# a reader that started probing for a derived or guessed service name (the
# thing #1666 deliberately does not do) reddens this.
# Field 2 is the service; field 1 became the SUBCOMMAND when the stub grew a
# write path (#1716), and field 3 is whether a value was asked for.
check_eq "$(cut -f2 "$STUB_SECURITY_LOG" | sort -u | tr '\n' '|')" \
  "Claude Code-credentials-AAA|Claude Code-credentials-BBB|" \
  "the reader asked the keychain only for the two services the registry records"
# And it only ever READ them here: nothing in this case is expired, so no
# write-back is due. A reader that wrote on every read would redden this.
check_eq "$(cut -f1 "$STUB_SECURITY_LOG" | sort -u | tr '\n' '|')" \
  "find-generic-password|" \
  "and only read them — an unexpired credential is never written back"

# --- 6. opus adds a fifth weekly row -----------------------------------------

anthropic_body 1 > "$STUB_ANTHROPIC_BODY"
run --json
check_eq "$(printf '%s' "$OUT" | jq 'length')" "6" \
  "seven_day_opus adds one more weekly row per claude account"
check_eq "$(field_of claude-one@example.com "7-day (opus)" used_pct)" "31" \
  "the opus row carries its own utilization"
anthropic_body 0 > "$STUB_ANTHROPIC_BODY"

# --- 7. reset time in ET, and the countdown ----------------------------------

run --json
check_eq "$(field_of claude-one@example.com "7-day" resets_at_epoch)" "$WEEK_RESET" \
  "the weekly reset is carried as epoch seconds"
check_eq "$(field_of claude-one@example.com "7-day" countdown)" "in 2d 4h" \
  "the countdown is rendered against the frozen clock"
check_contains "$(field_of claude-one@example.com "7-day" resets_at_et)" "EDT" \
  "the reset time is rendered in Eastern"

# A reset expressed with a numeric offset rather than `Z`. GNU `date -d`
# takes it either way; BSD needs its own format, so without the offset-aware
# second attempt the SAME payload yields a time on Linux and a bare `-` on
# macOS — the fleet's primary platform. This fixture uses `+00:00` stripped
# to a non-UTC-looking offset so the assertion cannot pass by accident on the
# `…Z` path.
OFFSET_ISO="$(TZ=UTC jq -rn --argjson e "$WEEK_RESET" '($e - 18000 | todate | sub("Z$"; "-05:00"))')"
jq -n --arg off "$OFFSET_ISO" \
  '{account: {email_address: "claude-one@example.com"},
    seven_day: {utilization: 50, resets_at: $off}}' > "$STUB_ANTHROPIC_BODY"
run --json
check_eq "$(field_of claude-one@example.com "7-day" resets_at_epoch)" "$WEEK_RESET" \
  "a reset carrying a numeric UTC offset parses to the same instant on either date(1) dialect"
anthropic_body 0 > "$STUB_ANTHROPIC_BODY"

# An elapsed reset must read `reset`, not a negative countdown.
PAST_SNAP="$(jq -n --argjson past "$PAST_RESET" \
  '{rateLimits: {planType: "pro",
                 primary: {usedPercent: 99, windowDurationMins: 10080, resetsAt: $past},
                 secondary: null}}')"
printf '%s' "$PAST_SNAP" > "$X1/rate-limits.json"
run --json
check_eq "$(field_of codex-one@example.com "7-day" countdown)" "reset" \
  "an already-elapsed reset prints 'reset'"
printf '%s' "$(codex_snapshot_primary_weekly)" > "$X1/rate-limits.json"

# --- 8. --five-hour ----------------------------------------------------------

run --json --five-hour
check_eq "$(field_of claude-one@example.com "5-hour" used_pct)" "12" \
  "--five-hour adds the claude five-hour row"
check_eq "$(field_of claude-one@example.com "5-hour" countdown)" "in 37m" \
  "a sub-hour countdown is rendered in minutes"
check_eq "$(field_of codex-two@example.com "5-hour" used_pct)" "9" \
  "--five-hour adds the codex short window when the plan reports one"
# A single-window response is valid, not an error: the row is rendered and
# says why it has no figure, rather than silently disappearing.
check_eq "$(field_of codex-one@example.com "5-hour" status)" "ok" \
  "a plan with only a weekly window still renders its five-hour row"
check_eq "$(field_of codex-one@example.com "5-hour" used_pct)" "null" \
  "and reports no figure rather than a fabricated 0"

# --- 9. --account narrows the run --------------------------------------------

run --json --account codex-two@example.com
check_eq "$(printf '%s' "$OUT" | jq 'length')" "1" "--account renders only that account"
check_eq "$(printf '%s' "$OUT" | jq -r '.[0].label')" "codex-two@example.com" "and it is the right one"
run --json --account nobody@example.com
check_eq "$RC" "0" "--account naming no registered label still exits 0"
check_eq "$OUT" "[]" "and returns no rows"

