#!/usr/bin/env bash
# Source-only quota fixture group: core. Run ai-quotas.test.sh.
# shellcheck source=../ai-quotas-fixtures.bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/ai-quotas-fixtures.bash"

# --- 1. --help contract ------------------------------------------------------

HELP_ERR="$TMP/help.err"
HELP_OUT="$(HOME="$CASE_HOME" "$SCRIPT" --help 2>"$HELP_ERR")"
check_eq "$?" "0" "--help exits 0"
check_contains "$HELP_OUT" "ai-quotas.sh" "--help names the script"
check_contains "$HELP_OUT" "EXIT STATUS" "--help carries the exit-status section"
check_contains "$HELP_OUT" "DEPENDENCIES" "--help carries the dependencies section"
check_eq "$(wc -c < "$HELP_ERR" | tr -d ' ')" "0" "--help writes nothing to stderr"

# --- 2. usage errors ---------------------------------------------------------

run --nonsense
check_eq "$RC" "3" "an unknown flag exits 3"
run --account
check_eq "$RC" "3" "--account with no label exits 3"

# --- 3. empty registry -------------------------------------------------------

reset_state
write_config
run
check_eq "$RC" "0" "an empty registry exits 0"
check_contains "$OUT" "No accounts registered yet." "and says so"
run --json
check_eq "$OUT" "[]" "--json on an empty registry carries no rows"
# The empty exits emit the SAME document as a populated run (#1669) — not a
# bare `[]`. A consumer that had to special-case emptiness is a consumer that
# will eventually read a partial answer as a complete one.
check_eq "$(printf '%s' "$DOC" | jq -r 'type')" "object" \
  "and it is still the document object, not a bare array"
check_eq "$(printf '%s' "$DOC" | jq -r '.cheapest_next | tostring')" "null" \
  "with no cheapest-next hint, because there is nothing to compare"

# --- 4. a broken registry is a broken TOOL, not a verdict --------------------

reset_state
printf 'not json at all\n' > "$CONFIG"
run
check_eq "$RC" "5" "an unparseable registry exits 5"
write_config
jq '.schema_version = "2.0"' "$CONFIG" > "$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG"
run
check_eq "$RC" "5" "a different schema major exits 5 rather than being guessed at"

# A credential_ref of the wrong SHAPE is a broken registry too. Left unchecked
# it reaches the Keychain lookup as a jq type error, the service reads back
# empty, and the row says `needs-login` — blaming the account for the config.
reset_state
CR1="$PROFILES/claude-one@example.com/claude"; mkdir -p "$CR1"
write_config "$(account_json claude claude-one@example.com "$CR1")"
jq '.accounts[0].credential_ref = "Claude Code-credentials"' "$CONFIG" > "$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG"
run
check_eq "$RC" "5" "a credential_ref that is a string, not an object, exits 5"
check_not_contains "$OUT" "needs-login" \
  "control(-): and is not reported as an account that needs a re-login"
# The shape the reader actually indexes is still accepted, or the check above
# would pass on a reader that rejected every credential_ref.
reset_state
write_config "$(account_json claude claude-one@example.com "$CR1")"
jq '.accounts[0].credential_ref = {service: "Claude Code-credentials"}' "$CONFIG" > "$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG"
run
check_eq "$RC" "0" "control(+): a well-formed credential_ref object is still accepted"

