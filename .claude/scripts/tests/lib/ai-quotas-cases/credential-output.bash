#!/usr/bin/env bash
# Source-only quota fixture group: credential-output. Run ai-quotas.test.sh.
# shellcheck source=../ai-quotas-fixtures.bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/ai-quotas-fixtures.bash"

# --- 15. no credential value reaches stdout, stderr, or any log --------------
# Cumulative and last, so it covers every case above.

reset_state
C1="$(seed_claude_profile claude-one@example.com "Claude Code-credentials-AAA")"
X1="$(seed_codex_profile codex-one@example.com "$(codex_snapshot_primary_weekly)")"
write_config \
  "$(account_json claude claude-one@example.com "$C1" "Claude Code-credentials-AAA")" \
  "$(account_json codex codex-one@example.com "$X1")"

run --five-hour
COMBINED="$OUT
$ERR"
check_eq "$(printf '%s' "$COMBINED" | grep -cE 'Bearer|sk-ant|eyJ|refresh_token=' || true)" "0" \
  "no Bearer header, sk-ant token, or JWT appears in stdout or stderr"
check_not_contains "$COMBINED" "$CLAUDE_SECRET" "the claude token value never reaches the output"
check_not_contains "$COMBINED" "$CODEX_SECRET" "the codex token value never reaches the output"

run --json --five-hour
# The WHOLE document, not just the rows: the overage annotation and the
# cheapest-next hint copy a label and a reason out of a row, and a leak that
# only reached those would pass an assertion scoped to `.rows`.
#
# DOC is asserted non-empty FIRST. A grep for secrets over an empty string
# finds none, so a run that produced no document at all would score a clean
# leak check — the scan passing because there was nothing to scan.
check_eq "$(printf '%s' "$DOC" | jq -r 'if (.rows | length) > 0 then "populated" else "empty" end' 2>/dev/null)" \
  "populated" "control(+): the --json document under the leak scan actually has rows in it"
COMBINED="$DOC
$ERR"
check_eq "$(printf '%s' "$COMBINED" | grep -cE 'Bearer|sk-ant|eyJ|refresh_token=' || true)" "0" \
  "and none appears in --json output either"

USAGE_LOG="$CASE_HOME/.claude/script-usage.log"
if [[ -s "$USAGE_LOG" ]]; then
  check_not_contains "$(cat "$USAGE_LOG")" "@example.com" \
    "the usage log records the action word only, never the account label"
  check_not_contains "$(cat "$USAGE_LOG")" "$CLAUDE_SECRET" \
    "and never a credential value"
else
  bad "the usage log was not written — the telemetry line is part of the contract"
fi

# The stub curl exits 90 the moment a bearer token appears in argv, so a
# clean run is itself the assertion that the token went in on stdin. Assert
# the config actually carried it, or the check above would pass vacuously on
# a reader that sent no Authorization header at all.
check_contains "$(cat "$STUB_CURL_STDIN" 2>/dev/null || true)" "Authorization: Bearer" \
  "control(+): the Authorization header really was sent — on stdin, not in argv"

