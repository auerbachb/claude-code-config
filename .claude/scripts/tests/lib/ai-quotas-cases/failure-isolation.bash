#!/usr/bin/env bash
# Source-only quota fixture group: failure-isolation. Run ai-quotas.test.sh.
# shellcheck source=../ai-quotas-fixtures.bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/ai-quotas-fixtures.bash"

# --- 10. per-row failure isolation -------------------------------------------
# The core promise: one broken account never suppresses the other three.

# A revoked claude login — the keychain item is gone.
reset_state
C1="$(seed_claude_profile claude-one@example.com "Claude Code-credentials-AAA")"
C2="$(seed_claude_profile claude-two@example.com "")"   # nothing in the keychain
X1="$(seed_codex_profile codex-one@example.com "$(codex_snapshot_primary_weekly)")"
X2="$(seed_codex_profile codex-two@example.com "")"     # empty CODEX_HOME
write_config \
  "$(account_json claude claude-one@example.com "$C1" "Claude Code-credentials-AAA")" \
  "$(account_json claude claude-two@example.com "$C2" "Claude Code-credentials-BBB")" \
  "$(account_json codex codex-one@example.com "$X1")" \
  "$(account_json codex codex-two@example.com "$X2")"

run --json
check_eq "$RC" "0" "a run with two broken accounts still exits 0 — this is a report, not a gate"
check_eq "$(printf '%s' "$OUT" | jq 'length')" "4" "all four rows render"
check_eq "$(rows_for claude-two@example.com)" "needs-login" "a revoked claude login reads needs-login"
check_eq "$(rows_for codex-two@example.com)" "needs-login" "an empty CODEX_HOME reads needs-login for that row only"
check_eq "$(rows_for claude-one@example.com)" "ok" "the healthy claude account still renders"
check_eq "$(rows_for codex-one@example.com)" "ok" "the healthy codex account still renders"
check_contains "$(field_of claude-two@example.com "7-day" detail)" \
  "/quotas-setup relogin claude-two@example.com claude" \
  "the needs-login note carries the exact relogin command"

# The table shows the same verdicts as --json (test-plan parity).
run
check_contains "$OUT" "needs-login" "the table renders the needs-login rows too"
check_contains "$OUT" "/quotas-setup relogin" "and the relogin command is in the table's note column"

# --- 11. rate limiting is not an auth failure --------------------------------

echo "ratelimit" > "$STUB_ANTHROPIC_MODE"
run --json
check_eq "$(rows_for claude-one@example.com)" "rate-limited" "a 429 reads rate-limited, not needs-login"
check_contains "$(field_of claude-one@example.com "7-day" detail)" "retry after 1800s" \
  "and the retry window is reported"
check_eq "$(rows_for codex-one@example.com)" "ok" "a claude 429 does not disturb the codex rows"

echo "unauth" > "$STUB_ANTHROPIC_MODE"
run --json
check_eq "$(rows_for claude-one@example.com)" "needs-login" "a 401 IS an auth failure and says so"

echo "down" > "$STUB_ANTHROPIC_MODE"
run --json
check_eq "$(rows_for claude-one@example.com)" "unreachable" "a network failure reads unreachable"
echo "ok" > "$STUB_ANTHROPIC_MODE"

# --- 12. an unrecognised shape prints the keys, never 0 % --------------------

jq -n '{quota_summary: {}, meta: {}}' > "$STUB_ANTHROPIC_BODY"
run --json
check_eq "$(rows_for claude-one@example.com)" "unreachable" \
  "a response with no known window is unreachable, not a silent success"
check_eq "$(field_of claude-one@example.com "7-day" used_pct)" "null" \
  "and reports no figure rather than 0 %"
check_contains "$(field_of claude-one@example.com "7-day" detail)" "quota_summary, meta" \
  "the note prints the top-level keys it actually saw"
anthropic_body 0 > "$STUB_ANTHROPIC_BODY"

