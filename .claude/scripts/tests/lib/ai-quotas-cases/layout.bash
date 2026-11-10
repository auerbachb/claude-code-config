#!/usr/bin/env bash
# Source-only quota fixture group: layout. Run ai-quotas.test.sh.
# shellcheck source=../ai-quotas-fixtures.bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/ai-quotas-fixtures.bash"

# --- layout mismatch regression (issue #1850) --------------------------------
reset_state
A="$(seed_claude_profile layout-alpha '')"
B="$(seed_claude_profile layout-beta '')"
for LAYOUT_DIR in "$A" "$B"; do
  jq -n --arg at "$CLAUDE_SECRET" --argjson ea "$(( (NOW + 3600) * 1000 ))" '{claudeAiOauth:{accessToken:$at,expiresAt:$ea}}' > "$LAYOUT_DIR/.credentials.json"
done
write_config "$(account_json claude layout-alpha "$B")" "$(account_json claude layout-beta "$A")"
cp "$CONFIG" "$TMP/layout-config-before"
LAYOUT_OUT="$(HOME="$CASE_HOME" AI_QUOTAS_CONFIG="$CONFIG" AI_QUOTAS_PROFILE_ROOT="$PROFILES" "$ROOT/.claude/scripts/ai-quotas-setup.sh" doctor --json)"; LAYOUT_RC=$?
check_eq "$LAYOUT_RC" 8 'setup doctor detects cross-wired Claude profile labels'
check_eq "$(printf '%s' "$LAYOUT_OUT" | jq '[.[] | select(.finding == "label-mismatch")] | length')" 2 'both labels flagged by doctor'
cmp -s "$CONFIG" "$TMP/layout-config-before" && ok 'doctor keeps registry byte identical' || bad 'doctor rewrote registry'
LAYOUT_OUT="$(HOME="$CASE_HOME" AI_QUOTAS_CONFIG="$CONFIG" AI_QUOTAS_PROFILE_ROOT="$PROFILES" "$ROOT/.claude/scripts/ai-quotas-setup.sh" repair-layout claude)"; LAYOUT_RC=$?
check_eq "$LAYOUT_RC" 0 'supported repair succeeds from reader fixture'
run --json
check_eq "$(field_of layout-alpha "7-day" status)" ok 'first repaired account remains readable'
check_eq "$(field_of layout-beta "7-day" status)" ok 'second repaired account remains readable'

