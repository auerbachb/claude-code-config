#!/usr/bin/env bash
# Source-only quota fixture group: recommendations. Run ai-quotas.test.sh.
# shellcheck source=../ai-quotas-fixtures.bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/ai-quotas-fixtures.bash"

reset_state
bad_label="bad$(printf '\033')label"
write_config "$(account_json cursor "$bad_label" "$TMP/browser-account" | jq '. + {sources:["unknown-source"]}')"
run --json
run --json
run --json
check_eq "$(printf '%s' "$DOC" | jq '.recommendations|length')" "1" "controlled-label fixture reaches recommendation threshold"
check_eq "$(printf '%s' "$DOC" | jq '[.recommendations[0].message|explode[]|select(.<32 or .==127)]|length')" "0" "recommendation text excludes every terminal control character"

