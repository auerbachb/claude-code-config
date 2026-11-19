#!/usr/bin/env bash
# catalog: tests — Verifies the /quotas paid-usage ($?, $ cap, $), resets and top-tier (top, top %) columns and their --json fields for every provider, the 120-second FETCHED rule, and that the six-account table fits 140 columns, against readings recorded on 2026-11-16 (Issues #2409, #2408, #2415)
#
# Source-only fixtures come from the quota reader suite (lib/ai-quotas-fixtures.bash):
# fake curl/security/codex/claude, a frozen clock (NOW), and a private HOME. Nothing
# here touches a real account, the network, or the owner's saved readings.
set -uo pipefail
unset BASH_ENV ENV
# shellcheck source=lib/ai-quotas-fixtures.bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/ai-quotas-fixtures.bash"

LKD="$TMP/last-known"
export AI_QUOTAS_LAST_KNOWN_DIR="$LKD"
# Antigravity's backend source finds no sign-in here, so these cases read only the saved text (Issue #2465).
export AI_QUOTAS_ANTIGRAVITY_TOKEN_FILE="/nonexistent/agy-token"
# Never open a terminal from this suite (Issue #2466), even when it is run from one.
export AI_QUOTAS_TERMINAL=off
SL_DIR="$CASE_HOME/.claude/ai-quotas/status-line"
AGY_OBS="$CASE_HOME/.claude/ai-quotas-antigravity.json"
PERS="claude-personal@example.com"
WORK="claude-work@example.com"

# A saved Claude reading beside the status line's, as claude-usage-observe.sh files it.
# <label> <age-seconds> <extra-json merged over the document>
seed_claude_app() {
  local label="$1" age="$2" extra="${3:-{\}}" cap=$(( NOW - $2 ))
  mkdir -p "$SL_DIR"
  jq -cn --arg l "$label" --argjson cap "$cap" --argjson week "$WEEK_RESET" --argjson five "$FIVE_RESET" --argjson x "$extra" \
    '{schema_version: "1.0", provider: "claude", source: "app-usage-tool", account_label: $l,
      captured_at_epoch: $cap, captured_at: ($cap | todate), subscription_type: "ultra",
      windows: {seven_day: {used_pct: 35, resets_at_epoch: $week}, five_hour: {used_pct: 4, resets_at_epoch: $five}}}
     + $x' > "$SL_DIR/claude-app--$label.json"
  chmod 600 "$SL_DIR/claude-app--$label.json"
}

# Claude Personal exactly as recorded: extra usage on, $315.79 of $500.00, Weekly · Fable 84% used.
PERS_EXTRA='{"weekly_models":[{"label":"Weekly · Fable","used_pct":84,"resets_at_epoch":'"$WEEK_RESET"'}],
  "extra_usage":{"enabled":true,"used_pct":63,"spent":"315.79","monthly_limit":"500.00","currency":"USD"}}'
# Claude Work: credits off with a $1,000 monthly limit set, $0.00 spent, two limit resets (an agent supplies the count).
WORK_EXTRA='{"weekly_models":[{"label":"Weekly · Fable","used_pct":0,"resets_at_epoch":'"$WEEK_RESET"'}],
  "extra_usage":{"enabled":false,"used_pct":0,"spent":"0.00","monthly_limit":"1000.00","currency":"USD"},
  "limit_resets":{"count":2,"items":[{"kind":"Fable reset","expires_at_epoch":1804000000},{"kind":"Weekly reset","expires_at_epoch":1790000000}]}}'

codex_snapshot_resets() { # <available-count|""> — Pro weekly snapshot, with the reset credits block when a count is given
  jq -n --argjson week "$WEEK_RESET" --arg n "$1" \
    '{rateLimits: {limitId: "codex", planType: "pro",
                   primary: {usedPercent: 71, windowDurationMins: 10080, resetsAt: $week}, secondary: null}}
     + (if $n == "" then {} else {rateLimitResetCredits: {availableCount: ($n | tonumber), credits: []}} end)'
}

cursor_spend_body() { # <spent-cents> <limit-cents|null>
  jq -n --argjson u "$1" --argjson l "$2" \
    '{billingCycleStart: "1787933374000", billingCycleEnd: "1790611774000",
      planUsage: {totalSpend: 209243, includedSpend: 40000, limit: 40000, autoPercentUsed: 53.03, apiPercentUsed: 100, totalPercentUsed: 59.78},
      spendLimitUsage: ({individualUsed: $u, limitType: "user"} + (if $l == null then {} else {individualLimit: $l} end))}'
}

AGY_PANEL='  Account: <email>

GEMINI MODELS
  Models within this group: Gemini 4 Hydrogen, Gemini 3.8 Flash

  Weekly Limit Remaining
    [██████████████████████████████████████████████████] 71.68%
    Refreshes in 153h 32m

  Five Hour Limit Remaining
    [██████████████████████████████████████████████████] 100.00%
    Quota available

CLAUDE AND GPT MODELS
  Models within this group: Claude Opus 5.5, Claude Sonnet 5.5, GPT-OSS 120B

  Weekly Limit Remaining
    [██████████████████████████████████████████████████] 100.00%
    Quota available

  Five Hour Limit Remaining
    [██████████████████████████████████████████████████] 100.00%
    Quota available

GEMINI 4 ARGON
  For paid Pro plans, Argon quota is separate.

  Gemini 4 Argon Weekly Limit
    [████████████░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░] 24.95%
    Refreshes in 153h 28m'

seed_agy() { # <age-seconds>
  jq -n --arg t "$AGY_PANEL" --argjson cap "$(( NOW - $1 ))" \
    '{schema: "antigravity-usage/1", provider: "antigravity", captured_at_epoch: $cap, via: "pasted", text: $t}' > "$AGY_OBS"
}

# The six accounts the owner runs, each with its own recorded reading.
six_accounts() {
  reset_state
  rm -rf "$LKD" "$SL_DIR" "$AGY_OBS"
  export AI_QUOTAS_LAST_KNOWN_DIR="$LKD"
  local c1 c2 x1 x2 agy
  c1="$(seed_claude_profile "$PERS" "")"
  c2="$(seed_claude_profile "$WORK" "")"
  x1="$(seed_codex_profile codex-one@example.com "$(codex_snapshot_resets 0)" codex-one@example.com)"
  x2="$(seed_codex_profile codex-two@example.com "$(codex_snapshot_resets "")" codex-two@example.com)"
  agy="$PROFILES/antigravity"; mkdir -p "$agy"
  seed_claude_app "$PERS" 300 "$PERS_EXTRA"
  seed_claude_app "$WORK" 300 "$WORK_EXTRA"
  cursor_spend_body 633 5000 > "$STUB_CURSOR_USAGE"
  seed_agy 300
  write_config \
    "$(account_json claude "$PERS" "$c1" | jq '. + {nickname: "Claude Personal"}')" \
    "$(account_json claude "$WORK" "$c2" | jq '. + {nickname: "Claude Work"}')" \
    "$(account_json codex codex-one@example.com "$x1" | jq '. + {nickname: "GPT LM"}')" \
    "$(account_json codex codex-two@example.com "$x2" | jq '. + {nickname: "GPT Personal"}')" \
    "$(account_json cursor cursor-one@example.com "$CUR" | jq '. + {nickname: "Cursor"}')" \
    "$(account_json antigravity personal "$agy" | jq '. + {nickname: "Antigravity"}')"
}

row_json() { # <label> <window-or-pool> <jq expr on that row>
  printf '%s' "$OUT" | jq -r --arg l "$1" --arg w "$2" '.[] | select(.label == $l and ((.pool // .window) == $w)) | '"$3"
}


# Terminal columns of the widest line of a table: the two icons take two columns each.
table_width() { # <table-text>
  printf '%s\n' "$1" | python3 -I -c '
import sys, unicodedata
print(max(sum(2 if unicodedata.east_asian_width(c) in "WF" else 1 for c in l.rstrip("\n")) for l in sys.stdin))'
}
row_of() { # <table> <account-name> — the first table line of that account
  printf '%s\n' "$1" | grep -E "^$2 " | head -n 1
}
has_row() { # <row> <extended-regex> <label>
  if grep -Eq -- "$2" <<<"$1"; then ok "$3"; else bad "$3 (row was: $1)"; fi
}

# One Claude account on its own, with a saved app reading carrying <extra>.
one_claude() { # <age-seconds> <extra-json>
  reset_state
  rm -rf "$LKD" "$SL_DIR"
  export AI_QUOTAS_LAST_KNOWN_DIR="$LKD"
  local dir
  dir="$(seed_claude_profile "$PERS" "")"
  write_config "$(account_json claude "$PERS" "$dir" | jq '. + {nickname: "Claude Personal"}')"
  seed_claude_app "$PERS" "$1" "$2"
}
claude_field() { row_json "$PERS" 7-day "$1"; }
paid_null() { # the paid, resets and top fields are all null on the 7-day row
  printf '%s' "$OUT" | jq -r --arg l "$PERS" '.[] | select(.label == $l and .window == "7-day")
    | [.paid_enabled, .paid_cap_usd, .paid_cap_unlimited, .paid_spent_usd, .paid_currency, .limit_resets_available, .limit_resets, .top_label, .top_used_pct] | map(. == null) | all'
}

# --- 1. the six accounts, as --json rows --------------------------------------------

six_accounts
run --json --five-hour
check_eq "$RC" "0" "the six-account run exits 0"
check_eq "$(printf '%s' "$OUT" | jq '[.[] | select(.provider == "antigravity")] | length')" "5" "control: Antigravity produced its five rows"
# Every row declares every new field, so the shape never varies by provider.
check_eq "$(printf '%s' "$OUT" | jq -r '[.[] | . as $r | ["paid_enabled","paid_cap_usd","paid_cap_unlimited","paid_spent_usd","paid_currency","paid_period","paid_read_at_epoch","limit_resets_available","limit_resets","top_label","top_used_pct","top_resets_at_epoch","account_primary"] | map(. as $k | $r | has($k)) | all] | all')" "true" "every row declares all thirteen new fields as keys"

# Claude Personal: paid usage on, $315.79 of $500.00, Weekly · Fable 84% used.
check_eq "$(row_json "$PERS" 7-day '.paid_enabled')" "true" "Claude Personal: paid usage is on"
check_eq "$(row_json "$PERS" 7-day '.paid_cap_usd == 500')" "true" "Claude Personal: the cap is \$500"
check_eq "$(row_json "$PERS" 7-day '.paid_spent_usd == 315.79')" "true" "Claude Personal: \$315.79 spent"
check_eq "$(row_json "$PERS" 7-day '.paid_currency')" "USD" "Claude Personal: in dollars"
check_eq "$(row_json "$PERS" 7-day '.paid_period')" "monthly" "Claude Personal: the spend covers the month"
check_eq "$(row_json "$PERS" 7-day '.paid_read_at_epoch')" "$(( NOW - 300 ))" "Claude Personal: the figures carry the time the reading was taken"
check_eq "$(row_json "$PERS" 7-day '.paid_cap_unlimited')" "null" "Claude Personal: a stated cap is not unlimited"
check_eq "$(row_json "$PERS" 7-day '.top_label')" "Fable" "Claude Personal: the top tier is named from the reading, minus its Weekly prefix"
check_eq "$(row_json "$PERS" 7-day '.top_used_pct')" "84" "Claude Personal: 84% of the top tier used"
check_eq "$(row_json "$PERS" 7-day '.top_resets_at_epoch')" "$WEEK_RESET" "Claude Personal: and when it resets"
check_eq "$(row_json "$PERS" 7-day '.limit_resets_available')" "null" "Claude Personal: no reading carries a reset count, so it is unknown, not zero"
# Claude Work: credits off with a $1,000 limit set, $0.00 spent, two limit resets.
check_eq "$(row_json "$WORK" 7-day '.paid_enabled')" "false" "Claude Work: credits are off, although a limit is set"
check_eq "$(row_json "$WORK" 7-day '.paid_cap_usd == 1000')" "true" "Claude Work: the \$1,000 limit is kept"
check_eq "$(row_json "$WORK" 7-day '.paid_spent_usd == 0')" "true" "Claude Work: \$0.00 spent is a figure the provider gave"
check_eq "$(row_json "$WORK" 7-day '.limit_resets_available')" "2" "Claude Work: two limit resets available"
check_eq "$(row_json "$WORK" 7-day '[.limit_resets[].kind] | join(",")')" "Fable reset,Weekly reset" "Claude Work: each reset names its kind"
check_eq "$(row_json "$WORK" 7-day '[.limit_resets[].expires_at_epoch] | join(",")')" "1804000000,1790000000" "Claude Work: and its expiry"
check_eq "$(row_json "$WORK" 7-day '.top_used_pct')" "0" "Claude Work: 0% of Fable used is a figure, not a gap"
# The five-hour row repeats the account's values in JSON and is not the one the table shows.
check_eq "$(row_json "$PERS" 5-hour '.paid_spent_usd')" "315.79" "a Claude five-hour row repeats the account's paid figures in JSON"
check_eq "$(row_json "$PERS" 5-hour '.account_primary')" "false" "and is not the account's table row"
check_eq "$(row_json "$PERS" 7-day '.account_primary')" "true" "the 7-day row is"
# Codex: 0 free resets is a figure the provider gave; no credits block is unknown.
CODEX1=codex-one@example.com; CODEX2=codex-two@example.com
check_eq "$(row_json "$CODEX1" 7-day '.limit_resets_available')" "0" "Codex: zero free resets remaining is 0"
check_eq "$(row_json "$CODEX2" 7-day '.limit_resets_available')" "null" "Codex: no reset credits in the payload is unknown, not 0"
check_eq "$(row_json "$CODEX1" 7-day '[.paid_enabled, .paid_cap_usd, .paid_spent_usd, .top_label] | map(. == null) | all')" "true" "Codex: paid usage and a top tier are not reported, so blank"
# Cursor: on-demand $6.33 of $50, no resets, no top tier.
check_eq "$(row_json cursor-one@example.com cursor-models '.paid_enabled')" "true" "Cursor: on-demand spending is possible (limit above zero)"
check_eq "$(row_json cursor-one@example.com cursor-models '.paid_cap_usd')" "50" "Cursor: the on-demand limit is \$50"
check_eq "$(row_json cursor-one@example.com cursor-models '.paid_spent_usd')" "6.33" "Cursor: \$6.33 spent"
check_eq "$(row_json cursor-one@example.com cursor-models '.limit_resets_available')" "null" "Cursor: no reset allowance, so blank"
check_eq "$(row_json cursor-one@example.com cursor-models '.top_label')" "null" "Cursor: no separate top tier, so blank"
check_eq "$(row_json cursor-one@example.com other-models '.paid_spent_usd')" "6.33" "Cursor: the other pool repeats the plan-wide spend in JSON"
check_eq "$(row_json cursor-one@example.com cursor-models '.account_primary')" "true" "Cursor: the first pool is the table row"
check_eq "$(row_json cursor-one@example.com other-models '.account_primary')" "false" "Cursor: the second pool is not"
# Antigravity: the group with no model list is the top tier, named by the last word, percent USED.
check_eq "$(row_json personal "gemini 7-day" '.top_label')" "Argon" "Antigravity: Gemini 4 Argon shows as Argon"
check_eq "$(row_json personal "gemini 7-day" '.top_used_pct == 75')" "true" "Antigravity: 24.95% remaining is 75% used"
check_eq "$(row_json personal "gemini 7-day" '.paid_enabled')" "null" "Antigravity: paid usage is not read, so blank"
check_eq "$(row_json personal "gemini 7-day" '.limit_resets_available')" "null" "Antigravity: no reset allowance is documented, so blank"
check_eq "$(printf '%s' "$OUT" | jq '[.[] | select(.provider == "antigravity" and .account_primary == true)] | length')" "1" "Antigravity: one table row for the five"

# --- 2. the table ------------------------------------------------------------------------

six_accounts
run
TABLE="$(table_only "$OUT")"
check_contains "$TABLE" '$?' "the table has a \$? column"
check_contains "$TABLE" '$ CAP' "and a \$ CAP column"
check_contains "$TABLE" " RST " "and a resets column"
check_contains "$TABLE" " TOP " "and a TOP column"
check_contains "$TABLE" "TOP%" "and a TOP% column"
check_contains "$TABLE" "FETCHED" "and FETCHED is still there"
WIDTH="$(table_width "$TABLE")"
if [[ "$WIDTH" -le 140 && "$WIDTH" -gt 0 ]]; then ok "the six-account table fits 140 terminal columns (widest line: $WIDTH)"
else bad "the six-account table does not fit 140 terminal columns (widest line: $WIDTH)"; fi
check_eq "$(printf '%s\n' "$TABLE" | grep -c '^Antigravity ')" "5" "control(+): all five Antigravity rows are in the measured table"
has_row "$(row_of "$TABLE" 'Claude Personal')" '✅ \$500 +\$315\.79 +- +Ultra +\$200 +Fable +84% ' "Claude Personal row: ✅, \$500 cap, \$315.79 spent, no resets, Fable 84%"
has_row "$(row_of "$TABLE" 'Claude Work')" '❌ off +\$0\.00 +2 +Ultra +\$200 +Fable +0% ' "Claude Work row: ❌ (credits off), off in \$ CAP despite the \$1000 limit, \$0.00, 2 resets, Fable 0%"
check_not_contains "$(row_of "$TABLE" 'Claude Work')" '1000' "Claude Work row: the unused \$1000 limit is not printed beside a ❌"
has_row "$(row_of "$TABLE" 'GPT LM')" ' - +- +- +0 +Pro +- +- +- ' "GPT LM row: 0 resets, paid usage blank (never ❌ or \$0)"
has_row "$(row_of "$TABLE" 'GPT Personal')" ' - +- +- +- +Pro +- +- +- ' "GPT Personal row: resets unknown shows the blank marker, not 0"
check_not_contains "$(row_of "$TABLE" 'GPT Personal')" ' 0 ' "GPT Personal row: no 0 anywhere in the new columns"
has_row "$(row_of "$TABLE" 'Cursor')" '✅ \$50 +\$6\.33 ' "Cursor row: ✅, \$50, \$6.33"
check_eq "$(printf '%s\n' "$TABLE" | grep -c '\$6\.33')" "1" "Cursor: the two pool rows do not double-count the spend"
check_eq "$(printf '%s\n' "$TABLE" | grep -c '✅')" "2" "two ✅ in all: Claude Personal and Cursor"
check_eq "$(printf '%s\n' "$TABLE" | grep -c '❌')" "1" "one ❌ in all: Claude Work, the only account the provider said is off"
check_eq "$(printf '%s\n' "$TABLE" | grep -c 'Argon')" "1" "Argon appears once for the five Antigravity rows"
has_row "$(row_of "$TABLE" 'Antigravity')" ' Argon +75% ' "Antigravity first row: Argon 75%"
# Long notes and overage labels go to numbered footnotes under the table.
check_contains "$TABLE" "[1]" "a long note is a footnote marker in its row"
check_contains "$OUT" "[1] from the Claude app" "and the text is printed below the table"
check_not_contains "$TABLE" "from the Claude app" "the long text is not in the table itself"
check_contains "$OUT" "] on-demand \$6.33 of \$50" "an overage label too long for its cell is footnoted too"
# --quiet still drops the trailing advisory sections and keeps the table and its footnotes.
run --quiet
check_not_contains "$OUT" "Informational only" "--quiet drops the cheapest-next block"
check_not_contains "$OUT" "RELIABILITY" "--quiet drops the reliability lines"
check_contains "$OUT" "[1] from the Claude app" "--quiet keeps the footnotes, which are part of the table"
check_eq "$(table_width "$(table_only "$OUT")")" "$WIDTH" "--quiet prints the same table"
# The layout is computed in jq on code points, so a runner whose locale is C or POSIX (bytes, not
# characters) prints the identical table.
for loc in C POSIX C.UTF-8; do
  LC_ALL="$loc" LANG="$loc" run --quiet
  check_eq "$(table_width "$(table_only "$OUT")")" "$WIDTH" "the table is the same width under LC_ALL=$loc"
done
# Wide East Asian characters in an account nickname count as two columns each.
check_eq "$(jq -n -r 'def wide: explode | map(if . >= 768 and . <= 879 then 0 elif . == 9989 or . == 10060 or . >= 127744 or (. >= 4352 and . <= 4447) or (. >= 11904 and . <= 42191) or (. >= 44032 and . <= 55203) or (. >= 63744 and . <= 64255) or (. >= 65040 and . <= 65049) or (. >= 65072 and . <= 65135) or (. >= 65280 and . <= 65376) or (. >= 65504 and . <= 65510) then 2 else 1 end) | add // 0; ["日本語","✅","ab","é"] | map(wide) | join(",")')" "6,2,2,1" "the width rule counts CJK as 2, an icon as 2, ASCII and accented letters as 1"

# --- 3. unknown is blank, never zero or off ------------------------------------------------

one_claude 300 '{}'
run --json
check_eq "$(paid_null)" "true" "a Claude reading with no extra-usage data leaves every new field null"
run
TABLE="$(table_only "$OUT")"
has_row "$(row_of "$TABLE" 'Claude Personal')" ' - +- +- +- +Ultra +\$200 +- +- ' "and the table shows the blank marker in all six new columns (the plan columns still show the plan)"
check_not_contains "$TABLE" '❌' "unknown paid usage is never shown as ❌"
check_not_contains "$TABLE" '$0' "and never as \$0"
check_not_contains "$TABLE" '✅' "nor as ✅"

# Enabled absent: the dollars the provider gave are kept, the on/off flag stays blank.
one_claude 300 '{"extra_usage":{"spent":"12.50","monthly_limit":"40.00","currency":"USD"}}'
run --json
check_eq "$(claude_field '.paid_enabled')" "null" "extra usage without an enabled flag leaves on/off unknown"
check_eq "$(claude_field '.paid_cap_usd == 40')" "true" "but keeps the cap"
check_eq "$(claude_field '.paid_spent_usd == 12.5')" "true" "and the spend"
run
has_row "$(row_of "$(table_only "$OUT")" 'Claude Personal')" ' - +\$40 +\$12\.50 ' "table: blank flag, \$40 cap, \$12.50 spend (cents shown on spend, dropped on a whole cap)"
# Another currency is never printed as dollars.
one_claude 300 '{"extra_usage":{"enabled":true,"spent":"12.50","monthly_limit":"40.00","currency":"EUR"}}'
run --json
check_eq "$(claude_field '[.paid_enabled, .paid_cap_usd, .paid_spent_usd, .paid_currency] | map(tostring) | join(",")')" "true,null,null,EUR" "a non-dollar currency keeps the on flag, drops the amounts and names the currency"
run
check_contains "$OUT" "paid amounts are in EUR, not shown" "and the table says why the amounts are blank"
# Garbage amounts are not figures.
one_claude 300 '{"extra_usage":{"enabled":true,"spent":"lots","monthly_limit":"-5","currency":"USD"}}'
run --json
check_eq "$(claude_field '[.paid_cap_usd, .paid_spent_usd] | map(tostring) | join(",")')" "null,null" "an amount that is not a plain non-negative number is dropped, not zeroed"
# Spent but no cap: no invented cap.
one_claude 300 '{"extra_usage":{"enabled":true,"spent":"3.00","monthly_limit":null,"currency":"USD"}}'
run
has_row "$(row_of "$(table_only "$OUT")" 'Claude Personal')" '✅ - +\$3\.00 ' "on, no cap reported, \$3.00 spent: the cap stays blank (only a provider that says unlimited shows none)"
# Off with no cap figure says off in $ CAP; off with a cap shows the cap.
one_claude 300 '{"extra_usage":{"enabled":false,"spent":"0.00","currency":"USD"}}'
run
has_row "$(row_of "$(table_only "$OUT")" 'Claude Personal')" '❌ off +\$0\.00 ' "credits off with no limit figure: ❌ and off in \$ CAP"

# --- 4. $ CAP tells a fixed cap, no cap and off apart (Cursor Spending page) -----------------

CURSOR_ACCT="cursor-spending"
cursor_browser_account() { # <on_demand_limit-json|omit> <unlimited:true|false> <used-json|omit>
  reset_state
  rm -rf "$LKD"
  export AI_QUOTAS_LAST_KNOWN_DIR="$LKD"
  mkdir -p "$TMP/browser-account"
  write_config "$(account_json cursor "$CURSOR_ACCT" "$TMP/browser-account" | jq '. + {nickname: "Cursor"}')"
  CURSOR_DB_UNDER_TEST="$TMP/cursor-columns-encrypted.vscdb"
  build_cursor_db "$CURSOR_DB_UNDER_TEST" 'cursor-safe-storage:v1:FIXTURE_CIPHER_SENTINEL'
  jq -n --argjson ob "$NOW" --arg label "$CURSOR_ACCT" --arg email "${CURSOR_OBS_EMAIL-$CURSOR_FIXTURE_EMAIL}" --arg lim "$1" --arg unl "$2" --arg used "$3" \
    '{schema_version:1,provider:"cursor",label:$label,email:$email,status:"ok",observed_at_epoch:$ob,plan:"Ultra",
      rows:[{window:"cursor-models",used_pct:41,resets_at_epoch:null},{window:"other-models",used_pct:12,resets_at_epoch:null}]}
     + (if $lim == "omit" then {} else {on_demand_limit_usd: ($lim | fromjson)} end)
     + (if $unl == "true" then {on_demand_unlimited: true} else {} end)
     + (if $used == "omit" then {} else {on_demand_used_usd: ($used | fromjson)} end)' > "$TMP/cursor-columns-obs.json"
  chmod 600 "$TMP/cursor-columns-obs.json"
  run --json --account "$CURSOR_ACCT" --browser-results "$TMP/cursor-columns-obs.json"
}
cursor_cell() { # <field> — from the first Cursor row
  printf '%s' "$OUT" | jq -r --arg f "$1" '[.[] | select(.label == "cursor-spending")][0] | .[$f] | if . == null then "null" else tostring end'
}
cursor_table_row() {
  run --account "$CURSOR_ACCT" --browser-results "$TMP/cursor-columns-obs.json"
  row_of "$(table_only "$OUT")" Cursor
}

cursor_browser_account 50 false 6.33
check_eq "$(cursor_cell paid_enabled),$(cursor_cell paid_cap_usd),$(cursor_cell paid_spent_usd)" "true,50,6.33" "Cursor Spending page: a \$50 limit with \$6.33 spent is on, \$50, \$6.33"
cursor_browser_account null true 6.33
check_eq "$(cursor_cell paid_enabled),$(cursor_cell paid_cap_unlimited),$(cursor_cell paid_cap_usd)" "true,true,null" "Cursor Spending page: unlimited is on with no cap amount"
has_row "$(cursor_table_row)" '✅ none +\$6\.33 ' "table: unlimited on-demand shows ✅ and none in \$ CAP"
cursor_browser_account 0 false 0
check_eq "$(cursor_cell paid_enabled),$(cursor_cell paid_cap_usd),$(cursor_cell paid_spent_usd)" "false,0,0" "Cursor Spending page: a limit of 0 is off, and the provider-said 0 spend is kept"
has_row "$(cursor_table_row)" '❌ off +\$0\.00 ' "table: limit 0 shows ❌, off in \$ CAP, \$0.00 (the provider said so)"
cursor_browser_account omit false omit
check_eq "$(cursor_cell paid_enabled),$(cursor_cell paid_cap_usd),$(cursor_cell paid_spent_usd)" "null,null,null" "Cursor Spending page without on-demand figures leaves the paid fields null"
has_row "$(cursor_table_row)" ' - +- +- ' "table: and shows the blank marker, never ❌ or \$0"
cursor_browser_account omit false 6.33
check_eq "$(cursor_cell paid_enabled),$(cursor_cell paid_cap_usd),$(cursor_cell paid_spent_usd)" "null,null,6.33" "spend without a limit: the flag and cap stay unknown, the spend is kept"
# An observation with no email (PR #2425: the Spending page shows none): the figures still show,
# marked not verified, and the paid columns come from the same observation.
CURSOR_OBS_EMAIL="" cursor_browser_account 50 false 6.33
check_eq "$(cursor_cell identity_verified)" "false" "an observation with no email is not verified"
check_eq "$(cursor_cell paid_enabled),$(cursor_cell paid_cap_usd),$(cursor_cell paid_spent_usd)" "true,50,6.33" "and still carries on, \$50 and \$6.33 from the same observation"
run --account "$CURSOR_ACCT" --browser-results "$TMP/cursor-columns-obs.json"
UNV_TABLE="$(row_of "$(table_only "$OUT")" Cursor)"
has_row "$UNV_TABLE" '✅ \$50 +\$6\.33 ' "table: the unverified Cursor row shows ✅, \$50, \$6.33"
has_row "$UNV_TABLE" ' now ' "and FETCHED is now (read within 120 seconds)"
check_contains "$OUT" "account not verified" "and the not-verified marking is printed (in the footnote under the table)"
check_contains "$UNV_TABLE" "[" "and the row points at that footnote"
CURSOR_DB_UNDER_TEST=""

# --- 5. FETCHED: read within 120 seconds before the run counts as fetched now ---------------

fetched_of() { # <field> — from the Personal 7-day row
  claude_field ".$1"
}
one_claude 120 "$PERS_EXTRA"
run --json
check_eq "$(fetched_of fetched)" "live" "a saved reading taken 120 seconds before the run counts as fetched for this request"
check_eq "$(fetched_of fetched_display)" "now" "and the table cell says now"
check_eq "$(fetched_of fetched_at)" "$(utc_iso "$(( NOW - 120 ))")" "while fetched_at keeps the exact instant it was read"
check_eq "$(fetched_of fetched_at_epoch)" "$(( NOW - 120 ))" "and so does fetched_at_epoch"
one_claude 121 "$PERS_EXTRA"
run --json
check_eq "$(fetched_of fetched)" "saved" "121 seconds before the run is saved"
check_eq "$(fetched_of fetched_display)" "$(TZ=America/New_York date -j -f %s "$(( NOW - 121 ))" '+%b %d' 2>/dev/null || TZ=America/New_York date -d "@$(( NOW - 121 ))" '+%b %d')" "and shows its date"
check_eq "$(fetched_of fetched_at)" "$(utc_iso "$(( NOW - 121 ))")" "with its exact instant"
# A capture time after the run began is never "now".
one_claude -60 "$PERS_EXTRA"
run --json
check_not_contains "$(fetched_of fetched_display)" "now" "a reading stamped after the run began is not fetched now"
one_claude 5 "$PERS_EXTRA"
run
has_row "$(row_of "$(table_only "$OUT")" 'Claude Personal')" ' now ' "a 5-second-old status reading shows now in the table"
# A saved Antigravity capture follows the same rule.
six_accounts
seed_agy 100
run --json
check_eq "$(row_json personal "gemini 7-day" '.fetched_display')" "now" "an Antigravity capture 100 seconds old counts as fetched now"
seed_agy 121
run --json
check_eq "$(row_json personal "gemini 7-day" '.fetched')" "saved" "an Antigravity capture 121 seconds old is saved"
# A stale Antigravity capture keeps no top tier (it has no live figure to attach it to).
seed_agy 11000
run --json
check_eq "$(printf '%s' "$OUT" | jq '[.[] | select(.provider == "antigravity" and .top_label != null)] | length')" "0" "a stale Antigravity capture shows no top tier"
# A group with a model list is not a top tier: only the two ordinary groups.
jq '.text |= (split("GEMINI 4 ARGON")[0])' "$AGY_OBS" > "$TMP/agy-no-argon.json" && cp "$TMP/agy-no-argon.json" "$AGY_OBS"
seed_agy 300
jq --arg t "$(printf '%s' "$AGY_PANEL" | awk '/^GEMINI 4 ARGON/{exit} {print}')" '.text = $t' "$AGY_OBS" > "$TMP/agy-two.json" && cp "$TMP/agy-two.json" "$AGY_OBS"
run --json
check_eq "$(printf '%s' "$OUT" | jq '[.[] | select(.provider == "antigravity" and .status == "ok")] | length')" "4" "control: a panel with only the two ordinary groups still reads"
check_eq "$(printf '%s' "$OUT" | jq '[.[] | select(.provider == "antigravity" and .top_label != null)] | length')" "0" "and an Antigravity panel with no single-model group shows no top tier, never 0%"

# --- 6. saved figures restored from last-known keep the new fields ---------------------------

reset_state
rm -rf "$LKD"
export AI_QUOTAS_LAST_KNOWN_DIR="$LKD"
cursor_spend_body 633 5000 > "$STUB_CURSOR_USAGE"
seed_cursor_account
run --json
check_eq "$(row_json cursor-one@example.com cursor-models '.paid_spent_usd')" "6.33" "control: a healthy Cursor read has the spend"
FIRST_NOW="$NOW"
NOW=$(( NOW + 3600 ))
echo "shape" > "$STUB_CURSOR_MODE"
run --json
check_eq "$(row_json cursor-one@example.com cursor-models '.status')" "unreadable" "the live read failed"
check_eq "$(row_json cursor-one@example.com cursor-models '.used_pct')" "null" "so USED is blank"
check_eq "$(row_json cursor-one@example.com cursor-models '[.paid_enabled, .paid_cap_usd, .paid_spent_usd] | map(tostring) | join(",")')" "true,50,6.33" "the saved paid figures come back with the saved row"
check_eq "$(row_json cursor-one@example.com cursor-models '.paid_read_at_epoch')" "$FIRST_NOW" "and carry the time they were read, not the time of this run"
check_eq "$(row_json cursor-one@example.com cursor-models '.last_known_at_epoch')" "$FIRST_NOW" "the row's own read time"
check_eq "$(row_json cursor-one@example.com cursor-models '.fetched')" "saved" "FETCHED shows the saved date, not now"
check_eq "$(row_json cursor-one@example.com cursor-models '.account_primary')" "true" "the restored first pool is still the account's table row"
check_eq "$(row_json cursor-one@example.com other-models '.account_primary')" "false" "and the second is not"
NOW="$FIRST_NOW"
echo "ok" > "$STUB_CURSOR_MODE"

# --- 7. a saved status-line reading and a newer app reading ------------------------------------

# Status line: a spend_limit whose shape was never seen live is read conservatively (an
# explicit on/off flag and *_usd amounts only), and any per-model weekly window is the top tier.
mk_statusline() { # <age-seconds> <rate_limits-json>
  mkdir -p "$SL_DIR"
  jq -cn --arg l "$PERS" --argjson cap "$(( NOW - $1 ))" --argjson week "$WEEK_RESET" --argjson rl "$2" \
    '{schema_version: "1.0", provider: "claude", account_label: $l, captured_at_epoch: $cap, captured_at: ($cap | todate),
      subscription_type: "max", rate_limits: $rl,
      windows: {seven_day: {used_pct: 10, resets_at_epoch: $week}}}' > "$SL_DIR/claude--$PERS.json"
  chmod 600 "$SL_DIR/claude--$PERS.json"
}
one_claude 4000 '{}'
rm -f "$SL_DIR/claude-app--$PERS.json"
mk_statusline 60 '{"seven_day":{"used_percentage":10,"resets_at":'"$WEEK_RESET"'},"seven_day_opus":{"used_percentage":12.5,"resets_at":'"$WEEK_RESET"'},"spend_limit":{"is_enabled":false,"limit_usd":50,"limit":5000}}'
run --json
check_eq "$(claude_field '.source')" "status-line" "control: the row comes from the status line"
check_eq "$(claude_field '[.paid_enabled, .paid_cap_usd, .paid_spent_usd] | map(tostring) | join(",")')" "false,50,null" "status-line spend_limit: the explicit flag and the *_usd cap, no spend invented"
check_eq "$(claude_field '[.top_label, .top_used_pct] | map(tostring) | join(",")')" "Opus,12.5" "status-line per-model window: the top tier is named from its key"
mk_statusline 60 '{"seven_day":{"used_percentage":10,"resets_at":'"$WEEK_RESET"'},"spend_limit":{"enabled":true,"limit":5000,"used":120}}'
run --json
check_eq "$(claude_field '[.paid_enabled, .paid_cap_usd, .paid_spent_usd] | map(tostring) | join(",")')" "true,null,null" "a bare number in spend_limit could be cents, so it is never shown as dollars"
# The status line is newer and carries no extras: the older app reading still supplies them,
# with its own read time, while FETCHED follows the figure actually shown.
one_claude 300 "$PERS_EXTRA"
mk_statusline 30 '{"seven_day":{"used_percentage":10,"resets_at":'"$WEEK_RESET"'}}'
run --json
check_eq "$(claude_field '.source')" "status-line" "control: the newer status-line reading is the row"
check_eq "$(claude_field '.paid_spent_usd')" "315.79" "the older app reading supplies the paid figures"
check_eq "$(claude_field '.paid_read_at_epoch')" "$(( NOW - 300 ))" "with its own read time"
check_eq "$(claude_field '.fetched_at_epoch')" "$(( NOW - 30 ))" "while the row follows the status-line reading"
check_eq "$(claude_field '.fetched_display')" "now" "which was read within 120 seconds"

# --- 8. the usage tool result and the optional limit_resets block ---------------------------------

OBS_DIR="$TMP/observe"
rm -rf "$OBS_DIR"; mkdir -p "$OBS_DIR"
reset_state
write_config "$(account_json claude "$PERS" "$PROFILES/p" | jq '. + {nickname: "Claude Personal"}')"
OBSERVE="$ROOT/.claude/scripts/claude-usage-observe.sh"
TOOL_BASE='{"plan":{"status":"ok","plan":"Ultra","windows":[{"label":"Weekly · all models","percentUsed":35,"resetsAt":"2026-11-16T22:00:00.409Z"},{"label":"Weekly · Fable","percentUsed":84,"resetsAt":"2026-11-16T22:00:00.409Z"}],"extraUsage":{"enabled":true,"percentUsed":63,"spent":"315.79","monthlyLimit":"500.00","currency":"USD"}}}'
observe_json() { # <tool-json> — saves through the real script; prints its one line
  printf '%s' "$1" > "$OBS_DIR/tool.json"
  AI_QUOTAS_STATUSLINE_DIR="$OBS_DIR/out" AI_QUOTAS_CONFIG="$CONFIG" AI_QUOTAS_NOW=1794839940 CLAUDE_CONFIG_DIR="$OBS_DIR/cfg" CLAUDE_CODE_USER_EMAIL="$PERS" \
    "$OBSERVE" "$OBS_DIR/tool.json" 2>&1
}
OBS_FILE="$OBS_DIR/out/claude-app--$PERS.json"
observe_json "$TOOL_BASE" >/dev/null
check_eq "$(jq -c '.limit_resets' "$OBS_FILE")" "null" "a tool result with no limit_resets saves none (unknown, not zero)"
check_eq "$(jq -c '.weekly_models[0].label' "$OBS_FILE")" '"Weekly · Fable"' "the per-model weekly window is saved with its label"
observe_json "$(jq -c '. + {limit_resets: {count: 2, items: [{kind: "Fable reset", expires_at: "2027-03-09T00:00:00Z"}, {kind: "Weekly reset", expires_at: "2026-12-10T00:00:00Z"}]}}' <<<"$TOOL_BASE")" >/dev/null
check_eq "$(jq -c '[.limit_resets.count, (.limit_resets.items | map(.kind))]' "$OBS_FILE")" '[2,["Fable reset","Weekly reset"]]' "an agent-supplied limit_resets block is saved with its count and kinds"
check_eq "$(jq -c '.limit_resets.items | map(.expires_at_epoch)' "$OBS_FILE")" '[1804550400,1796860800]' "and each expiry as an epoch"
observe_json "$(jq -c '. + {limit_resets: [{kind: "Weekly reset", expires_at: "2026-12-10T00:00:00Z"}]}' <<<"$TOOL_BASE")" >/dev/null
check_eq "$(jq -c '.limit_resets.count' "$OBS_FILE")" "1" "a bare list of items counts as its own count"
observe_json "$(jq -c '. + {limit_resets: {count: 0}}' <<<"$TOOL_BASE")" >/dev/null
check_eq "$(jq -c '.limit_resets' "$OBS_FILE")" '{"count":0,"items":[]}' "a count of 0 the page showed is saved as 0"
for bad in '{"count":2,"items":[{"kind":"Weekly reset","expires_at":"2026-12-10T00:00:00Z"}]}' \
           '{"count":-1}' '{"count":"2"}' '{"count":1,"items":[{"kind":"x\u0000y","expires_at":"2026-12-10T00:00:00Z"}]}' \
           '{"count":1,"items":[{"kind":"Weekly reset","expires_at":"next week"}]}' '"2"' '{"count":1.5}'; do
  before="$(cat "$OBS_FILE")"
  out="$(observe_json "$(jq -c --argjson lr "$bad" '. + {limit_resets: $lr}' <<<"$TOOL_BASE")")"; rc=$?
  check_eq "$rc,$(printf '%s' "$out" | grep -c 'limit_resets is malformed')" "1,1" "a malformed limit_resets block is refused with its reason: $bad"
  check_eq "$(cat "$OBS_FILE")" "$before" "and nothing is written"
done
observe_json "$(jq -c 'del(.plan.extraUsage.enabled)' <<<"$TOOL_BASE")" >/dev/null
check_eq "$(jq -c '.extra_usage.enabled' "$OBS_FILE")" "null" "an extraUsage with no enabled flag is saved as unknown, never off"
observe_json "$(jq -c '.plan.extraUsage.enabled = false' <<<"$TOOL_BASE")" >/dev/null
check_eq "$(jq -c '.extra_usage.enabled' "$OBS_FILE")" "false" "an enabled flag of false the tool reported is saved as false"

# --- 9. the claude.ai page observation carries the same figures --------------------------------------

CB_LABEL="$PERS"
cb_page_obs() { # <extra-json merged into the observation>
  reset_state
  rm -rf "$LKD" "$SL_DIR"
  export AI_QUOTAS_LAST_KNOWN_DIR="$LKD"
  local dir
  dir="$(seed_claude_profile "$CB_LABEL" "Claude-browser-svc")"
  echo ratelimit > "$STUB_ANTHROPIC_MODE"
  write_config "$(account_json claude "$CB_LABEL" "$dir" Claude-browser-svc)"
  jq -n --arg l "$CB_LABEL" --argjson ob "${CB_OBS_AT:-$NOW}" --argjson wk "$WEEK_RESET" --argjson x "$1" \
    '{schema_version: 1, provider: "claude", label: $l, email: $l, status: "ok", observed_at_epoch: $ob,
      rows: [{window: "7-day", used_pct: 64, resets_at_epoch: $wk}]} + $x' > "$TMP/claude-page-obs.json"
  chmod 600 "$TMP/claude-page-obs.json"
  run --json --account "$CB_LABEL" --browser-results "$TMP/claude-page-obs.json"
}
cb_page_obs '{"extra_usage":{"enabled":false,"spent_usd":0,"monthly_limit_usd":1000},"limit_resets":{"count":2,"items":[{"kind":"Fable reset","expires_at_epoch":1804000000},{"kind":"Weekly reset","expires_at_epoch":1790000000}]},"top_model":{"label":"Fable","used_pct":0,"resets_at_epoch":null}}'
check_eq "$(claude_field '[.status, .paid_enabled, .paid_cap_usd, .paid_spent_usd, .limit_resets_available, .top_label, .top_used_pct] | map(tostring) | join(",")')" "ok,false,1000,0,2,Fable,0" "a page observation supplies credits off, the \$1000 limit, \$0 spent, 2 resets and Fable 0%"
check_eq "$(claude_field '.fetched_display')" "now" "and was taken at the start of the run"
cb_page_obs '{}'
check_eq "$(paid_null)" "true" "a page observation without those blocks leaves them all null"
cb_page_obs '{"limit_resets":{"count":2,"items":[]}}'
check_eq "$(claude_field '.status')" "unreadable" "a page observation whose limit_resets count and items disagree is rejected"
cb_page_obs '{"extra_usage":{"enabled":"yes"}}'
check_eq "$(claude_field '.status')" "unreadable" "a page observation whose enabled flag is not a boolean is rejected"
cb_page_obs '{"extra_usage":{"spent_usd":-1}}'
check_eq "$(claude_field '.status')" "unreadable" "a negative spend is rejected"
cb_page_obs '{"top_model":{"label":"Fable","used_pct":140,"resets_at_epoch":null}}'
check_eq "$(claude_field '.status')" "unreadable" "a top-model percent above 100 is rejected"
cb_page_obs '{"top_model":{"label":"Fa\nble","used_pct":3,"resets_at_epoch":null}}'
check_eq "$(claude_field '.status')" "unreadable" "a top-model label with control characters is rejected"

# --- 7. review round: account values survive an unreadable window; stale and future figures ---

cb_page_obs '{"rows":[{"window":"7-day","used_pct":null,"resets_at_epoch":null},{"window":"5-hour","used_pct":10,"resets_at_epoch":'"$FIVE_RESET"'}],"extra_usage":{"enabled":true,"spent_usd":4,"monthly_limit_usd":20}}'
check_eq "$(claude_field '[.status, .paid_enabled, .paid_cap_usd, .paid_spent_usd] | map(tostring) | join(",")')" "unreadable,true,20,4" "an unreadable window still carries the account's paid figures"
cb_page_obs '{"top_model":{"label":"Fable","used_pct":50,"resets_at_epoch":'"$(( NOW - 10 ))"'}}'
check_eq "$(claude_field '[.top_label, .top_used_pct] | map(tostring) | join(",")')" "null,null" "a top-tier window whose reset has passed is blank, not an old percent"
cb_page_obs '{"top_model":{"label":"Fable","used_pct":50,"resets_at_epoch":'"$WEEK_RESET"'}}'
check_eq "$(claude_field '[.top_label, .top_used_pct] | map(tostring) | join(",")')" "Fable,50" "control: a top-tier window that resets later is shown"
CB_OBS_AT=$(( NOW + 100 )) cb_page_obs '{}'
check_eq "$(claude_field '.fetched_display')" "$(TZ=America/New_York date -j -f %s "$(( NOW + 100 ))" '+%b %d' 2>/dev/null || TZ=America/New_York date -d "@$(( NOW + 100 ))" '+%b %d')" "an observation stamped 100 seconds after the run began shows its date, never now"

# --- 8. review round 3: contracts the second review found --------------------------------------

# The documented limit_resets example is itself valid input.
DOC_EXAMPLE="$(grep -o '{"count": 1, "items": \[{"kind": "[^"]*", "expires_at": "[^"]*"}\]}' "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../reference/ai-quotas-reader.md" | head -n 1)"
check_contains "$DOC_EXAMPLE" '"count": 1' "the documented limit_resets example was found in the reference"
observe_json "$(jq -c --argjson lr "$DOC_EXAMPLE" '. + {limit_resets: $lr}' <<<"$TOOL_BASE")" >/dev/null
check_eq "$?,$(jq -c '.limit_resets.count' "$OBS_FILE")" "0,1" "the documented example passes the real validator and is saved"

# false is not "absent": a false block or false items list is refused and nothing is written.
for bad in 'false' '{"count":2,"items":false}'; do
  before="$(cat "$OBS_FILE")"
  out="$(observe_json "$(jq -c --argjson lr "$bad" '. + {limit_resets: $lr}' <<<"$TOOL_BASE")")"; rc=$?
  check_eq "$rc,$(printf '%s' "$out" | grep -c 'limit_resets is malformed')" "1,1" "limit_resets $bad is refused as malformed"
  check_eq "$(cat "$OBS_FILE")" "$before" "and nothing is written for it"
done

# A fractional expiry is saved as a whole number, so it survives the last-known file.
cb_page_obs '{"limit_resets":{"count":1,"items":[{"kind":"Weekly reset","expires_at_epoch":1804550400.5}]}}'
check_eq "$(claude_field '.limit_resets | map(.expires_at_epoch) | join(",")')" "1804550400" "a fractional reset expiry is normalised to an integer"

# Paid usage off stays off (false is not missing), and a zero reset count stays 0.
cb_page_obs '{"extra_usage":{"enabled":false},"limit_resets":{"count":0}}'
check_eq "$(claude_field '[.paid_enabled, .limit_resets_available] | map(tostring) | join(",")')" "false,0" "enabled false is kept as false and a count of 0 as 0"

printf 'ai-quotas-columns.test.sh: %s passed, %s failed\n' "$PASS" "$FAILED"
[[ "$FAILED" -eq 0 ]]
