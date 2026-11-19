#!/usr/bin/env bash
# catalog: tests — Verifies the /quotas TIER and $/MO columns and the plan_tier, plan_tier_source, plan_usd_month and plan_price_source --json fields (Issue #2469): the tier each provider's own reading names (Claude, Codex, Cursor, Antigravity) priced from the dated list in .claude/reference/quotas-plan-prices.json, an unknown tier or price shown as `-` and never $0, the `ai-quotas-setup.sh plan` manual override beating detection and being marked in the table and --json, and the table staying within 140 columns
#
# Source-only fixtures come from the quota reader suite (lib/ai-quotas-fixtures.bash): fake
# curl/security/codex/claude, a frozen clock (NOW), and a private HOME. Nothing here touches a
# real account, the network, or the owner's saved readings.
set -uo pipefail
unset BASH_ENV ENV
# shellcheck source=lib/ai-quotas-fixtures.bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/ai-quotas-fixtures.bash"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP="$HERE/../ai-quotas-setup.sh"
export AI_QUOTAS_LAST_KNOWN_DIR="$TMP/last-known"
export AI_QUOTAS_ANTIGRAVITY_TOKEN_FILE="/nonexistent/agy-token"
export AI_QUOTAS_TERMINAL=off
SL_DIR="$CASE_HOME/.claude/ai-quotas/status-line"
AGY_OBS="$CASE_HOME/.claude/ai-quotas-antigravity.json"
CL="claude-one@example.com"

seed_claude_app() { # <label> <subscription_type|null>
  mkdir -p "$SL_DIR"
  jq -cn --arg l "$1" --argjson st "$2" --argjson cap "$(( NOW - 300 ))" --argjson week "$WEEK_RESET" \
    '{schema_version: "1.0", provider: "claude", source: "app-usage-tool", account_label: $l,
      captured_at_epoch: $cap, captured_at: ($cap | todate), subscription_type: $st,
      windows: {seven_day: {used_pct: 35, resets_at_epoch: $week}}}' > "$SL_DIR/claude-app--$1.json"
  chmod 600 "$SL_DIR/claude-app--$1.json"
}

codex_snap() { # <planType>
  jq -n --argjson week "$WEEK_RESET" --arg p "$1" \
    '{rateLimits: {limitId: "codex", planType: $p,
                   primary: {usedPercent: 71, windowDurationMins: 10080, resetsAt: $week}, secondary: null}}'
}

seed_agy_backend() { # <plan|"">
  jq -n --argjson cap "$(( NOW - 300 ))" --argjson reset "$(( NOW + 86400 ))" --arg plan "$1" \
    '{schema: "antigravity-usage/1", provider: "antigravity", captured_at_epoch: $cap, via: "backend",
      response: {groups: [{displayName: "Gemini", description: "Models within this group: Gemini 4",
                           buckets: [{displayName: "Weekly Limit", remainingFraction: 0.7, resetTime: ($reset | todate)}]}]}}
     + (if $plan == "" then {} else {plan: $plan} end)' > "$AGY_OBS"
}

fresh() {
  reset_state
  rm -rf "$AI_QUOTAS_LAST_KNOWN_DIR" "$SL_DIR" "$AGY_OBS"
}

row() { # <label> <window-or-pool> <jq expr>
  printf '%s' "$OUT" | jq -r --arg l "$1" --arg w "$2" '.[] | select(.label == $l and ((.pool // .window) == $w)) | '"$3"
}
plan_cells() { # <label> <window> -> "tier|source|usd|price-source"
  row "$1" "$2" '[.plan_tier, .plan_tier_source, .plan_usd_month, .plan_price_source] | map(tostring) | join("|")'
}
table_width() {
  printf '%s\n' "$1" | python3 -I -c '
import sys, unicodedata
print(max(sum(2 if unicodedata.east_asian_width(c) in "WF" else 1 for c in l.rstrip("\n")) for l in sys.stdin))'
}

# --- 1. each provider's own plan, priced from the list ----------------------------------------

fresh
c1="$(seed_claude_profile "$CL" "")"
x1="$(seed_codex_profile codex-one@example.com "$(codex_snap plus)" codex-one@example.com)"
x2="$(seed_codex_profile codex-two@example.com "$(codex_snap pro)" codex-two@example.com)"
agy="$PROFILES/antigravity"; mkdir -p "$agy"
seed_claude_app "$CL" '"ultra"'
seed_agy_backend "Google AI Ultra"
write_config \
  "$(account_json claude "$CL" "$c1")" \
  "$(account_json codex codex-one@example.com "$x1")" \
  "$(account_json codex codex-two@example.com "$x2")" \
  "$(account_json cursor cursor-one@example.com "$CUR")" \
  "$(account_json antigravity personal "$agy")"
cursor_spend_body() { jq -n '{billingCycleStart: "1787933374000", billingCycleEnd: "1790611774000",
  planUsage: {totalSpend: 209243, includedSpend: 40000, limit: 40000, autoPercentUsed: 53.03, apiPercentUsed: 100, totalPercentUsed: 59.78}, spendLimitUsage: {individualUsed: 633, limitType: "user", individualLimit: 5000}}'; }
cursor_spend_body > "$STUB_CURSOR_USAGE"
run --json
check_eq "$RC" "0" "the five-account run exits 0"
check_eq "$(plan_cells "$CL" 7-day)" "Ultra|provider|200|list" "Claude: the saved reading's subscription type is the tier, priced from the list"
check_eq "$(plan_cells codex-one@example.com 7-day)" "Plus|provider|20|list" "Codex plus: Plus at the listed price"
check_eq "$(plan_cells codex-two@example.com 7-day)" "Pro|provider|null|null" "Codex pro: the tier is shown, the price is unknown (null, never 0)"
check_eq "$(row cursor-one@example.com cursor-models '.plan_tier')" "Ultra" "Cursor: the membership name the provider reports"
check_eq "$(row cursor-one@example.com cursor-models '[.plan_usd_month, .plan_price_source] | map(tostring) | join("|")')" "200|list" "Cursor Ultra: priced from the list"
check_eq "$(row personal "gemini 7-day" '.plan_tier')" "Ultra" "Antigravity: the plan the account lookup named, by its list name"
check_eq "$(row personal "gemini 7-day" '.plan_usd_month')" "99.99" "Antigravity AI Ultra: priced from the list"
for k in plan_tier plan_tier_source plan_usd_month plan_price_source; do
  check_eq "$(printf '%s' "$OUT" | jq --arg k "$k" '[.[] | has($k)] | all')" "true" "every row declares $k"
done

run --five-hour
TABLE="$(table_only "$OUT")"
check_contains "$TABLE" "TIER" "the table has a TIER column"
check_contains "$TABLE" '$/MO' "and a \$/MO column"
has_row() { grep -Eq -- "$2" <<<"$1" && ok "$3" || bad "$3 (row was: $1)"; }
has_row "$(printf '%s\n' "$TABLE" | grep -E '^claude' | head -n 1)" 'Ultra +\$200' "the Claude row shows Ultra and \$200"
check_contains "$(printf '%s\n' "$TABLE" | grep -E '^codex-two' | head -n 1)" ' Pro ' "Codex Pro row shows the tier"
check_not_contains "$(printf '%s\n' "$TABLE" | grep -E '^codex-two' | head -n 1)" '$0' "and never \$0 for an unknown price"
check_eq "$(printf '%s\n' "$TABLE" | grep -Ec 'Ultra +\$200')" "2" "Ultra \$200 appears once for Claude and once for Cursor (not once per row)"

# The same five accounts under nicknames, as the owner runs them: the table stays within 140 columns.
write_config \
  "$(account_json claude "$CL" "$c1" | jq '. + {nickname: "Claude Personal"}')" \
  "$(account_json codex codex-one@example.com "$x1" | jq '. + {nickname: "GPT LM"}')" \
  "$(account_json codex codex-two@example.com "$x2" | jq '. + {nickname: "GPT Personal"}')" \
  "$(account_json cursor cursor-one@example.com "$CUR" | jq '. + {nickname: "Cursor"}')" \
  "$(account_json antigravity personal "$agy" | jq '. + {nickname: "Antigravity"}')"
run --five-hour
W="$(table_width "$(table_only "$OUT")")"
if [[ "$W" -le 140 && "$W" -gt 0 ]]; then ok "the nicknamed table fits 140 columns (widest line: $W)"; else bad "the nicknamed table is $W columns wide"; fi

# --- 2. an unknown plan is `-`, never $0 ---------------------------------------------------------

fresh
c1="$(seed_claude_profile "$CL" "")"
seed_claude_app "$CL" 'null'
write_config "$(account_json claude "$CL" "$c1")"
run --json
check_eq "$(plan_cells "$CL" 7-day)" "null|null|null|null" "no plan reported: every plan field is null"
run
TABLE="$(table_only "$OUT")"
check_not_contains "$TABLE" '$0' "no plan reported: the table never prints \$0"
check_contains "$(printf '%s\n' "$TABLE" | sed -n 2p)" " - " "and the cells are the blank marker"

# With no saved reading the stored login names the plan (subscriptionType: max in the fixture).
fresh
SVC_PLAN="Claude Code-credentials-PLAN"
c1="$(seed_claude_profile "$CL" "$SVC_PLAN")"
write_config "$(account_json claude "$CL" "$c1" "$SVC_PLAN")"
run --json
check_eq "$(plan_cells "$CL" 7-day)" "Max|provider|null|null" "the token path: a bare max names the tier but carries no price"

# A saved reading that says a bare `max` is refined by the stored login's rateLimitTier (Max 20x is $200, not $100).
fresh
SVC_PLAN="Claude Code-credentials-PLAN20"
c1="$(seed_claude_profile "$CL" "$SVC_PLAN")"
printf '%s\t%s\t%s\n' "$SVC_PLAN" "$CLAUDE_KEYCHAIN_ACCT" \
  "$(jq -cn --arg at "$CLAUDE_SECRET" '{claudeAiOauth: {accessToken: $at, scopes: ["user:inference","user:profile"], subscriptionType: "max", rateLimitTier: "default_claude_max_20x"}}')" > "$STUB_KEYCHAIN_DB"
seed_claude_app "$CL" '"max"'
write_config "$(account_json claude "$CL" "$c1" "$SVC_PLAN")"
run --json
check_eq "$(plan_cells "$CL" 7-day)" "Max 20x|provider|200|list" "a saved bare max is refined to Max 20x by the stored login"

# A tier the list does not price keeps its name and shows `-` for the price.
fresh
x1="$(seed_codex_profile codex-one@example.com "$(codex_snap enterprise_plus)" codex-one@example.com)"
write_config "$(account_json codex codex-one@example.com "$x1")"
run --json
check_eq "$(plan_cells codex-one@example.com 7-day)" "Enterprise_plus|provider|null|null" "an unlisted tier shows its reported name and no price"

# --- 3. the manual override ---------------------------------------------------------------------

fresh
c1="$(seed_claude_profile "$CL" "")"
seed_claude_app "$CL" '"pro"'
write_config "$(account_json claude "$CL" "$c1")"
set_plan() { HOME="$CASE_HOME" AI_QUOTAS_CONFIG="$CONFIG" bash "$SETUP" plan "$@" 2>&1; }
OUTS="$(set_plan "$CL" "Max 20x" 180)"; RCS=$?
check_eq "$RCS" "0" "plan <label> <tier> <usd> succeeds"
check_contains "$OUTS" 'Max 20x' "and says what it set"
check_eq "$(jq -c '.accounts[0].plan_override' "$CONFIG")" '{"tier":"Max 20x","usd_per_month":180}' "the override is stored as plan_override {tier, usd_per_month}"
run --json
check_eq "$(plan_cells "$CL" 7-day)" "Max 20x|override|180|override" "the override beats what the provider reports, price included"
run
TABLE="$(table_only "$OUT")"
check_contains "$TABLE" 'Max 20x*' "the table marks an overridden tier"
check_contains "$TABLE" '$180*' "and an overridden price"
check_contains "$OUT" '* set by hand with ai-quotas-setup.sh plan' "and explains the mark under the table"

# A tier without a price: the list prices it when it knows the tier.
OUTS="$(set_plan "$CL" "Max 20x")"; RCS=$?
check_eq "$RCS" "0" "plan <label> <tier> without a price succeeds"
check_eq "$(jq -c '.accounts[0].plan_override' "$CONFIG")" '{"tier":"Max 20x"}' "no price key is stored"
run --json
check_eq "$(plan_cells "$CL" 7-day)" "Max 20x|override|200|list" "the override tier is priced from the list"
OUTS="$(set_plan "$CL" "Custom Team")"
run --json
check_eq "$(plan_cells "$CL" 7-day)" "Custom Team|override|null|null" "an override tier the list does not know has no price"

# A third argument naming a provider is the provider, not a price.
OUTS="$(set_plan "$CL" "Pro" claude)"; RCS=$?
check_eq "$RCS,$(jq -c '.accounts[0].plan_override' "$CONFIG")" '0,{"tier":"Pro"}' "a provider as the third argument is taken as the provider"
OUTS="$(set_plan "$CL" "Pro" 20 claude)"; RCS=$?
check_eq "$RCS,$(jq -c '.accounts[0].plan_override' "$CONFIG")" '0,{"tier":"Pro","usd_per_month":20}' "tier, price and provider together"

# Refusals and clearing.
OUTS="$(set_plan "$CL" "Pro" 100000)"; RCS=$?
check_eq "$RCS" "3" "a price above 99999.99 is refused"
OUTS="$(set_plan "$CL" "Pro" abc)"; RCS=$?
check_eq "$RCS" "3" "a price that is not an amount is refused"
OUTS="$(set_plan "no-such@example.com" "Pro")"; RCS=$?
check_eq "$RCS" "4" "an unregistered label is refused"
OUTS="$(set_plan "$CL" "")"; RCS=$?
check_eq "$RCS,$(jq -r '.accounts[0] | has("plan_override")' "$CONFIG")" "0,false" "an empty tier clears the override"
run --json
check_eq "$(plan_cells "$CL" 7-day)" "Pro|provider|20|list" "after clearing, the provider's own plan shows again"

# Plan values are printable ASCII, so a character is a terminal column (Issue #2469 review).
OUTS="$(set_plan "$CL" "Élite" 50)"; RCS=$?
check_eq "$RCS" "3" "a non-ASCII tier is refused"
OUTS="$(set_plan "$CL" "$(printf 'Pro\tX')")"; RCS=$?
check_eq "$RCS" "3" "a tier with a control character is refused"
OUTS="$(set_plan "$CL" $'\n' 180)"; RCS=$?
check_eq "$RCS" "3" "a newline-only tier is refused, not read as clearing"

# Worst case: every value setup accepts, on the widest rows, still fits 140 columns (--json keeps the full value).
LONGNICK="漢字漢字漢字漢字漢字漢字漢字漢字漢字漢字漢字漢字漢字漢字漢字漢字"
LONGTIER="Discount Platinum Plus Ultra Premium"
LONGTIER="${LONGTIER:0:32}"
write_config "$(account_json claude "$CL" "$c1" | jq --arg n "$LONGNICK" --arg t "$LONGTIER" '. + {nickname: $n, plan_override: {tier: $t, usd_per_month: 99999.99}}')"
run --five-hour
W="$(table_width "$(table_only "$OUT")")"
if [[ "$W" -le 140 && "$W" -gt 0 ]]; then ok "the worst-case accepted values fit 140 columns (widest line: $W)"; else bad "the worst-case table is $W columns wide"; fi
run --json
check_eq "$(plan_cells "$CL" 7-day)" "$LONGTIER|override|99999.99|override" "and --json keeps the full tier and price"

# The old nickname and the override live side by side.
HOME="$CASE_HOME" AI_QUOTAS_CONFIG="$CONFIG" bash "$SETUP" nick "$CL" "Work" >/dev/null 2>&1
set_plan "$CL" "Ultra" 200 >/dev/null
check_eq "$(jq -c '.accounts[0] | [.nickname, .plan_override.tier]' "$CONFIG")" '["Work","Ultra"]' "a nickname and a plan override do not disturb each other"

# Worst case on the Cursor rows: a 24-character nickname, the long cursor-models window, the longest override and a paid spend together.
fresh
write_config "$(account_json cursor cursor-one@example.com "$CUR" | jq '. + {nickname: "abcdefghijklmnopqrstuvwx", plan_override: {tier: "Discount", usd_per_month: 99999.99}}')"
cursor_spend_body > "$STUB_CURSOR_USAGE"
run --five-hour
W="$(table_width "$(table_only "$OUT")")"
if [[ "$W" -le 140 && "$W" -gt 0 ]]; then ok "the long-nickname Cursor override row fits 140 columns (widest line: $W)"; else bad "the long-nickname Cursor override row is $W columns wide"; fi

# The same with a nickname of ten watch emoji (two columns each in a terminal): a 24-character nickname, the long cursor-models window, the longest override and a paid spend together.
fresh
write_config "$(account_json cursor cursor-one@example.com "$CUR" | jq '. + {nickname: "⌚⌚⌚⌚⌚⌚⌚⌚⌚⌚", plan_override: {tier: "Discount", usd_per_month: 99999.99}}')"
cursor_spend_body > "$STUB_CURSOR_USAGE"
run --five-hour
W="$(table_width "$(table_only "$OUT")")"
if [[ "$W" -le 140 && "$W" -gt 0 ]]; then ok "the emoji-nickname Cursor override row fits 140 columns (widest line: $W)"; else bad "the emoji-nickname Cursor override row is $W columns wide"; fi

# The same with a nickname of eight U+16FE0 characters (East Asian Width wide, outside the common ranges): a 24-character nickname, the long cursor-models window, the longest override and a paid spend together.
fresh
write_config "$(account_json cursor cursor-one@example.com "$CUR" | jq '. + {nickname: "𖿠𖿠𖿠𖿠𖿠𖿠𖿠𖿠", plan_override: {tier: "Discount", usd_per_month: 99999.99}}')"
cursor_spend_body > "$STUB_CURSOR_USAGE"
run --five-hour
W="$(table_width "$(table_only "$OUT")")"
if [[ "$W" -le 140 && "$W" -gt 0 ]]; then ok "the U+16FE0-nickname Cursor override row fits 140 columns (widest line: $W)"; else bad "the U+16FE0-nickname Cursor override row is $W columns wide"; fi

# --- 4. display only -----------------------------------------------------------------------------

check_eq "$(grep -c 'plan_tier\|plan_usd_month\|plan_override\|usd_per_month\|price' "$HERE/../quota-reserve.sh")" "0" "quota-reserve.sh never reads the plan or price"

printf 'ai-quotas-plan.test.sh: %s passed, %s failed\n' "$PASS" "$FAILED"
[[ "$FAILED" -eq 0 ]]
