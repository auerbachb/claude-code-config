#!/usr/bin/env bash
# ai-quotas-cursor.test.sh — coverage for the Cursor reader in
# .claude/scripts/ai-quotas.sh (issue #1668).
# catalog: tests — Tests the Cursor branch of `ai-quotas.sh` against a PATH-shim fake for the Playwright helper — two pool rows (`cursor-models`, `other-models`) with the percentages and billing-cycle reset the captured dashboard response carries, `needs-login` naming the exact relogin command, a changed response shape reported as `unreadable` with the keys seen instead of a silent 0 %, a missing helper or node degrading that account alone, and the assertion that no cookie or session value reaches stdout, stderr, or the usage log
#
# WHAT IS UNDER TEST
#
# The BASH side of the Cursor reader — everything between the helper's JSON
# verdict and the row the user sees. The helper itself (Playwright, a real
# browser, cursor.com) is replaced by a fake `node` that prints canned JSON,
# so this suite needs neither node, nor playwright, nor a network, nor an
# account, and it never opens a browser.
#
# That seam is deliberate. The reader's job is to turn a verdict into an
# honest row, and every way that goes wrong is on this side: a changed
# payload rendering as 0 %, an expired session reading as "no usage", a
# missing driver taking the whole report down, a cookie reaching the output.
#
# DISCRIMINATING FIXTURES. The good-shape fixture is the response actually
# captured from the Spending tab of a live Ultra account on 2026-09-08, with
# the owner's figures replaced by synthetic ones — same keys, same types,
# same string-encoded epoch milliseconds. A fixture with round numbers and
# plain integers would pass on a reader that mishandled either.
#
# THE FAKE HELPER ALSO CARRIES A COOKIE-SHAPED SECRET in a field the reader
# is not supposed to read, so the leak assertions are real detectors: a
# reader that echoed the helper's raw stdout into a note would fail them.
#
# THE CLOCK IS FROZEN (AI_QUOTAS_NOW), so the ET reset and the countdown are
# asserted exactly rather than "looks about right".
#
# Run from anywhere: bash .claude/scripts/tests/ai-quotas-cursor.test.sh

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="$ROOT/.claude/scripts/ai-quotas.sh"
HELPER="$ROOT/.claude/scripts/lib/ai-quotas-cursor.js"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }
[[ -x "$SCRIPT" ]] || { echo "FAIL — $SCRIPT is not executable"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAILED=0
ok()  { PASS=$((PASS + 1)); echo "ok   — $*"; }
bad() { FAILED=$((FAILED + 1)); echo "FAIL — $*" >&2; }

check_eq() { # <actual> <expected> <label>
  if [[ "$1" == "$2" ]]; then ok "$3"; else bad "$3 (got '$1', want '$2')"; fi
}
check_contains() { # <haystack> <needle> <label>
  case "$1" in
    *"$2"*) ok "$3" ;;
    *) bad "$3 (output did not contain '$2')" ;;
  esac
}
check_not_contains() { # <haystack> <needle> <label>
  case "$1" in
    *"$2"*) bad "$3 (output unexpectedly contained '$2')" ;;
    *) ok "$3" ;;
  esac
}

# --- fixtures ----------------------------------------------------------------

# A cookie-shaped value the reader must never surface. It rides along in the
# fake helper's stdout, in a field the contract does not include.
COOKIE_SECRET="WorkosCursorSessionToken=FAKE-SESSION-COOKIE-7Q6P5O"

# Frozen clock: 2026-09-08T20:00:00Z — a Tuesday, 4:00 PM EDT.
NOW=1788897600
# Billing cycle ends in 20 days and 2 hours; starts 10 days before "now".
CYCLE_END_MS=$(( (NOW + 20 * 86400 + 2 * 3600) * 1000 ))
CYCLE_START_MS=$(( (NOW - 10 * 86400) * 1000 ))

BIN="$TMP/bin"
mkdir -p "$BIN"

CASE_HOME="$TMP/home"
CONFIG="$TMP/ai-quotas.json"
PROFILES="$TMP/profiles"
VERDICT="$TMP/verdict.json"
NODE_LOG="$TMP/node-calls.log"
export NODE_LOG

# --- stub: node --------------------------------------------------------------
# Stands in for `node lib/ai-quotas-cursor.js …`. It logs its argv, then
# prints whatever the current case put in $VERDICT — which is exactly the
# helper's contract: one JSON object on stdout, exit 0. A case that wants the
# helper to fail outright uses $BIN/node-crash instead.
cat > "$BIN/node" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$NODE_LOG"
cat "$STUB_VERDICT"
exit 0
EOF

# A helper that dies without printing a verdict: the contract violation the
# reader has to survive.
cat > "$BIN/node-crash" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$NODE_LOG"
echo "TypeError: cannot read properties of undefined" >&2
exit 1
EOF

# A helper that prints something that is not the contract — a log line where
# a verdict belongs.
cat > "$BIN/node-noise" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$NODE_LOG"
echo "Downloading Chromium 148.0 …"
exit 0
EOF

chmod +x "$BIN"/*

# The helper path the reader is pointed at. Its CONTENT is never read (the
# fake node ignores it); it only has to exist, because the reader refuses to
# invoke a helper that is not there.
FAKE_HELPER="$TMP/fake-helper.js"
printf '// stub\n' > "$FAKE_HELPER"

# The captured shape, with synthetic figures. Percentages are deliberately
# fractional (the real payload sends full float precision) and the epoch
# milliseconds are deliberately STRINGS, both as captured.
verdict_ok() { # [<auto_pct>] [<api_pct>]
  jq -n \
    --arg auto "${1:-49.02333333333333}" \
    --arg api "${2:-100}" \
    --arg start "$CYCLE_START_MS" \
    --arg end "$CYCLE_END_MS" \
    --arg cookie "$COOKIE_SECRET" \
    '{status: "ok",
      source: "network",
      endpoint: "https://cursor.com/api/dashboard/get-current-period-usage",
      billing_cycle_start_epoch: (($start | tonumber) / 1000 | floor),
      billing_cycle_end_epoch: (($end | tonumber) / 1000 | floor),
      pools: [{pool: "cursor-models", used_pct: ($auto | tonumber)},
              {pool: "other-models",  used_pct: ($api  | tonumber)}],
      plan_used_usd: 1972.1,
      plan_included_usd: 400,
      plan_name: "Ultra",
      _debug_session: $cookie}'
}

account_json() { # <provider> <label> <dir>
  jq -n --arg p "$1" --arg l "$2" --arg d "$3" \
    '{provider: $p, label: $l, profile_dir: $d, added_at: "2026-09-07T00:00:00Z"}'
}

write_config() { # <account-json…>
  local acc="[]" a
  for a in "$@"; do
    acc="$(printf '%s' "$acc" | jq --argjson e "$a" '. += [$e]')"
  done
  printf '%s' "$acc" | jq '{schema_version: "1.0", accounts: .}' > "$CONFIG"
}

OUT=""
DOC=""
ERR=""
RC=0

run() { # <args…> — never aborts the suite; sets OUT, DOC, ERR, RC
  local errf="$TMP/run.err"
  OUT="$(HOME="$CASE_HOME" \
        CLAUDE_QUOTAS_STATE_DIR="$CASE_HOME/.claude/quotas" \
        CLAUDE_QUOTAS_CHEAPEST_NEXT_THRESHOLD_PCT="20" \
        STUB_VERDICT="$VERDICT" \
        NODE_LOG="$NODE_LOG" \
        AI_QUOTAS_CONFIG="$CONFIG" \
        AI_QUOTAS_PLATFORM="Darwin" \
        AI_QUOTAS_NOW="$NOW" \
        AI_QUOTAS_NODE_BIN="${NODE_BIN_UNDER_TEST:-$BIN/node}" \
        AI_QUOTAS_CURSOR_HELPER="${HELPER_UNDER_TEST:-$FAKE_HELPER}" \
        AI_QUOTAS_CURSOR_TIMEOUT="${CURSOR_TIMEOUT_UNDER_TEST:-5}" \
        "$SCRIPT" "$@" 2>"$errf")"
  RC=$?
  ERR="$(cat "$errf")"
  # #1669 changed --json from a bare row ARRAY to a DOCUMENT — {schema_version,
  # threshold_pct, basis, rows, cheapest_next}. Every assertion here is about
  # the Cursor rows, so the document is kept whole in DOC and OUT is narrowed
  # to `.rows`; same treatment, and same reasoning, as ai-quotas.test.sh.
  #
  # Narrowed ONLY when the output really is that document, so a table run or a
  # failed --json run reaches the assertions exactly as the script wrote it.
  DOC=""
  if printf '%s' "$OUT" | jq -e 'type == "object" and has("rows") and has("cheapest_next")' >/dev/null 2>&1; then
    DOC="$OUT"
    OUT="$(printf '%s' "$DOC" | jq -c '.rows')"
  fi
}

# One field of the row for one POOL. The two Cursor rows share a window, so
# the pool is what tells them apart — which is the point of the field.
pool_field() { # <label> <pool> <field>
  printf '%s' "$OUT" | jq -r --arg l "$1" --arg p "$2" --arg f "$3" \
    '.[] | select(.label == $l and .pool == $p) | .[$f] | if . == null then "null" else tostring end'
}

# The single row a non-ok account produces.
row_field() { # <label> <field>
  printf '%s' "$OUT" | jq -r --arg l "$1" --arg f "$2" \
    '.[] | select(.label == $l) | .[$f] | if . == null then "null" else tostring end'
}

statuses_for() { # <label>
  printf '%s' "$OUT" | jq -r --arg l "$1" '.[] | select(.label == $l) | .status'
}

reset_state() {
  NODE_BIN_UNDER_TEST=""
  HELPER_UNDER_TEST=""
  CURSOR_TIMEOUT_UNDER_TEST=""
  : > "$NODE_LOG"
  rm -rf "$PROFILES"; mkdir -p "$PROFILES"
  rm -rf "$CASE_HOME"; mkdir -p "$CASE_HOME/.claude"
  verdict_ok > "$VERDICT"
}

seed_cursor_profile() { # <label> -> dir on stdout
  local dir="$PROFILES/$1/cursor"
  mkdir -p "$dir/Default/Network"
  printf 'SQLite format 3\0%s\n' "$COOKIE_SECRET" > "$dir/Default/Network/Cookies"
  printf '%s' "$dir"
}

reset_state

echo "== ai-quotas.sh — cursor reader =="

# --- 1. the helper ships and is syntactically sound --------------------------
#
# The suite drives a fake, so nothing else here would notice a helper that
# does not parse. That is precisely why this check exists: without it the
# whole suite could pass against a helper that cannot run.

if [[ -r "$HELPER" ]]; then
  ok "the cursor helper ships at .claude/scripts/lib/ai-quotas-cursor.js"
else
  bad "the cursor helper is missing at $HELPER"
fi

NODE_REAL=""
for candidate in "$(command -v node 2>/dev/null || true)" /opt/homebrew/bin/node /usr/local/bin/node; do
  if [[ -n "$candidate" && -x "$candidate" ]]; then NODE_REAL="$candidate"; break; fi
done
if [[ -n "$NODE_REAL" ]]; then
  if "$NODE_REAL" --check "$HELPER" >/dev/null 2>&1; then
    ok "the cursor helper parses under node"
  else
    bad "the cursor helper does not parse under node"
  fi
else
  echo "note — node not installed; skipping the helper parse check"
fi

if [[ -r "$ROOT/.claude/scripts/lib/package.json" ]]; then
  PINNED="$(jq -r '.dependencies.playwright // ""' "$ROOT/.claude/scripts/lib/package.json" 2>/dev/null)"
  # An EXACT pin, not a range: `^1.63.0` would let the browser driver change
  # under a reader whose output nobody re-checked.
  if [[ "$PINNED" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    ok "playwright is pinned to an exact version ($PINNED)"
  else
    bad "playwright is not pinned to an exact version (got '$PINNED')"
  fi
else
  bad "the helper's package.json is missing"
fi

# --- 1b. the helper's pure logic, driven directly ----------------------------
#
# Everything else in this file drives the BASH side against a fake. These few
# assertions exercise the helper's own normaliser and URL matcher, which is
# where a changed Cursor payload actually lands. Skipped without node — the
# suite must stay runnable on a machine that has none.

if [[ -n "$NODE_REAL" ]]; then
  JS_OUT="$("$NODE_REAL" -e '
    const m = require(process.argv[1]);
    const out = [];
    const t = (name, cond) => out.push((cond ? "PASS " : "FAIL ") + name);

    t("a query string still matches the endpoint path",
      m.pathIs("https://cursor.com/api/dashboard/get-current-period-usage?x=1",
               "/api/dashboard/get-current-period-usage"));
    t("a longer path does not match",
      !m.pathIs("https://cursor.com/api/dashboard/get-current-period-usage-v2",
                "/api/dashboard/get-current-period-usage"));
    // The reason the match is exact rather than a suffix: anything mounted in
    // front of the real path would otherwise hand this reader its quota
    // figures.
    t("a prefixed path does not match",
      !m.pathIs("https://cursor.com/debug/api/dashboard/get-current-period-usage",
                "/api/dashboard/get-current-period-usage"));
    t("an unparseable url does not match",
      !m.pathIs("not a url", "/api/dashboard/get-current-period-usage"));

    const good = m.normalise({
      billingCycleStart: "1787933374000",
      billingCycleEnd: "1790611774000",
      planUsage: { totalSpend: 197210, limit: 40000,
                   autoPercentUsed: 49.02333333333333, apiPercentUsed: 100 }
    });
    t("the captured shape normalises", good.ok === true);
    t("epoch milliseconds become seconds",
      good.ok && good.row.billing_cycle_end_epoch === 1790611774);
    t("cents become dollars", good.ok && good.row.plan_used_usd === 1972.1);
    t("both pools are emitted, in dashboard order",
      good.ok && good.row.pools.map(function (p) { return p.pool; }).join(",")
        === "cursor-models,other-models");

    const bad = m.normalise({ billingCycleEnd: "1790611774000", usageSummary: {} });
    t("a missing planUsage is not ok", bad.ok === false);
    t("and the keys seen are reported",
      bad.ok === false && bad.keysSeen.join(",") === "billingCycleEnd,usageSummary");

    const partial = m.normalise({ planUsage: { autoPercentUsed: 12.5, apiPercentUsed: "n/a" } });
    t("an unparseable pool is omitted, not 0",
      partial.ok === true && partial.row.pools.length === 1
        && partial.row.pools[0].used_pct === 12.5);

    // Number("") is 0, not NaN — so a blank field is the one input that can
    // slip a figure nobody measured past every finite check and render as
    // "plenty left". Blank and whitespace are asserted separately because
    // trimming is what makes the second reach the first.
    const blank = m.normalise({ planUsage: { autoPercentUsed: "", apiPercentUsed: 42 } });
    t("a blank pool percentage is omitted, not read as 0",
      blank.ok === true && blank.row.pools.length === 1
        && blank.row.pools[0].pool === "other-models");
    const spaces = m.normalise({ planUsage: { autoPercentUsed: "   ", apiPercentUsed: 42 } });
    t("a whitespace-only pool percentage is omitted too",
      spaces.ok === true && spaces.row.pools.length === 1);
    t("a blank dollar figure is null, not $0.00",
      m.centsToUsd("") === null && m.centsToUsd("   ") === null);
    t("and a real one still converts",
      m.centsToUsd("197210") === 1972.1 && m.asPercent("49.5") === 49.5);

    process.stdout.write(out.join("\n"));
  ' "$HELPER" 2>&1)"
  while IFS= read -r js_line; do
    case "$js_line" in
      "PASS "*) ok "helper: ${js_line#PASS }" ;;
      "FAIL "*) bad "helper: ${js_line#FAIL }" ;;
      "") ;;
      *) bad "helper: unexpected output from the node assertions: $js_line" ;;
    esac
  done <<< "$JS_OUT"

  # Argument parsing happens before playwright is loaded, so these run on a
  # machine with no browser driver installed. A digit string long enough to
  # reach Infinity must be REJECTED, not accepted as a deadline no wait can
  # cross — the failure mode the range check exists for.
  if "$NODE_REAL" "$HELPER" --profile-dir /nonexistent \
       --timeout-ms 99999999999999999999999 >/dev/null 2>&1; then
    bad "helper: an Infinity-sized --timeout-ms is rejected"
  else
    check_eq "$?" "2" "helper: an Infinity-sized --timeout-ms is a usage error"
  fi
  # One past the cap, and still a safe integer — so this value reaches the
  # RANGE branch rather than being caught by the safe-integer test above. A
  # fixture the earlier branch would reject anyway would pass for the wrong
  # reason and leave the cap itself unexercised.
  if "$NODE_REAL" "$HELPER" --profile-dir /nonexistent \
       --timeout-ms 86400001 >/dev/null 2>&1; then
    bad "helper: a --timeout-ms one past the cap is rejected"
  else
    check_eq "$?" "2" "helper: a --timeout-ms one past the cap is a usage error"
  fi
  # The control: the cap itself is ACCEPTED, so the bound rejects "too large"
  # rather than everything. It is skipped where playwright is installed — there
  # a successful parse goes on to open a browser and wait out the bound just
  # given it, which at the cap is a day. With no driver the helper reports
  # `unreachable` and exits 0 the instant parsing succeeds, so exit 0 is proof
  # the value was accepted and nothing is launched.
  if "$NODE_REAL" -e 'require("playwright")' >/dev/null 2>&1; then
    echo "note — playwright is installed; skipping the cap-accepted control (it would open a browser)"
  else
    "$NODE_REAL" "$HELPER" --profile-dir /nonexistent --timeout-ms 86400000 >/dev/null 2>&1
    check_eq "$?" "0" "control(+): the cap value itself is accepted"
  fi
else
  echo "note — node not installed; skipping the helper's own unit assertions"
fi

# --- 2. the acceptance shape: two pool rows ----------------------------------

reset_state
CUR="$(seed_cursor_profile cursor-one@example.com)"
write_config "$(account_json cursor cursor-one@example.com "$CUR")"

run --json
check_eq "$RC" "0" "a cursor account exits 0"
check_eq "$(printf '%s' "$OUT" | jq 'length')" "2" "one cursor account produces two rows"
check_eq "$(printf '%s' "$OUT" | jq -r '[.[].pool] | join(",")')" "cursor-models,other-models" \
  "the rows are the two pools, in dashboard order"
check_eq "$(statuses_for cursor-one@example.com | sort -u | tr '\n' ' ')" "ok " \
  "both rows read ok"

check_eq "$(pool_field cursor-one@example.com cursor-models used_pct)" "49" \
  "the cursor-models row carries autoPercentUsed, rounded for display"
check_eq "$(pool_field cursor-one@example.com other-models used_pct)" "100" \
  "the other-models row carries apiPercentUsed"
check_eq "$(pool_field cursor-one@example.com cursor-models remaining_pct)" "51" \
  "remaining % is 100 - used"
check_eq "$(pool_field cursor-one@example.com cursor-models window)" "billing-cycle" \
  "the window is the billing cycle, not a week"

# The reset date and countdown against the frozen clock — the payload sends
# epoch MILLISECONDS as a string, and a reader that forgot the /1000 would
# render a date in the year 58000 rather than failing loudly.
check_eq "$(pool_field cursor-one@example.com cursor-models resets_at_epoch)" \
  "$(( CYCLE_END_MS / 1000 ))" "the reset is the billing-cycle end in epoch SECONDS"
check_eq "$(pool_field cursor-one@example.com cursor-models resets_at_et)" \
  "Mon Sep 28 6:00 PM EDT" "and renders in Eastern time"
check_eq "$(pool_field cursor-one@example.com cursor-models countdown)" "in 20d 2h" \
  "the countdown matches the frozen clock"

check_eq "$(pool_field cursor-one@example.com cursor-models plan)" "Ultra" \
  "the plan name from get-plan-info is reported"
check_eq "$(pool_field cursor-one@example.com cursor-models source)" "network" \
  "the row says the figures came from the observed response"

# Per-pool dollars are NOT in the dashboard response — the Spending tab shows
# the two pools as percentage bars. The fields exist on every row, and stay
# null here rather than being manufactured by dividing the plan-wide total.
check_eq "$(pool_field cursor-one@example.com cursor-models used_usd)" "null" \
  "used_usd is null, because the response carries no per-pool dollars"
check_eq "$(pool_field cursor-one@example.com cursor-models included_usd)" "null" \
  "and so is included_usd"
check_eq "$(pool_field cursor-one@example.com cursor-models plan_used_usd)" "1972.1" \
  "the plan-WIDE spend is reported as what it is"
check_eq "$(pool_field cursor-one@example.com cursor-models plan_included_usd)" "400" \
  "alongside the plan-wide included allowance"
check_contains "$(pool_field cursor-one@example.com other-models detail)" "percent only" \
  "and the note says why the per-pool dollars are absent"

# The table has to tell the two rows apart, or it prints one figure twice.
run
check_contains "$OUT" "cursor-models" "the table names the cursor-models pool"
check_contains "$OUT" "other-models" "and the other-models pool"

# The reader must run the helper HEADLESS against this account's own profile.
check_contains "$(cat "$NODE_LOG")" "--mode read" "the reader runs the helper in read mode"
check_contains "$(cat "$NODE_LOG")" "$CUR" "against this account's own profile directory"

# --- 3. every row shape carries the same keys --------------------------------

reset_state
CUR="$(seed_cursor_profile cursor-one@example.com)"
write_config "$(account_json cursor cursor-one@example.com "$CUR")"
run --json
check_eq "$(printf '%s' "$OUT" | jq -r '[.[0] | has("pool"), has("used_usd"), has("included_usd"), has("plan_used_usd"), has("plan_included_usd")] | all')" \
  "true" "the row declares every cursor field"

# --- 4. an expired session is needs-login, with the exact command ------------

reset_state
CUR="$(seed_cursor_profile cursor-one@example.com)"
write_config "$(account_json cursor cursor-one@example.com "$CUR")"
jq -n '{status: "needs-login", detail: "the dashboard redirected to a login page — the saved session is gone"}' > "$VERDICT"
run --json
check_eq "$RC" "0" "an expired cursor session does not fail the run"
check_eq "$(statuses_for cursor-one@example.com)" "needs-login" "the row reads needs-login"
check_eq "$(row_field cursor-one@example.com used_pct)" "null" \
  "and reports no figure rather than 0 %"
check_contains "$(row_field cursor-one@example.com detail)" \
  "/quotas-setup relogin cursor-one@example.com cursor" \
  "the note carries the exact relogin command"

# A profile directory that is not there at all is the same verdict, reached
# without paying for a browser start.
reset_state
write_config "$(account_json cursor gone@example.com "$PROFILES/gone@example.com/cursor")"
run --json
check_eq "$(statuses_for gone@example.com)" "needs-login" \
  "a missing profile directory reads needs-login"
check_contains "$(row_field gone@example.com detail)" "/quotas-setup relogin gone@example.com cursor" \
  "and names the relogin command too"
check_eq "$(wc -c < "$NODE_LOG" | tr -d ' ')" "0" \
  "control(-): no browser was started for a profile that does not exist"

# --- 5. a changed response shape is unreadable, never a silent 0 % -----------

reset_state
CUR="$(seed_cursor_profile cursor-one@example.com)"
write_config "$(account_json cursor cursor-one@example.com "$CUR")"
jq -n '{status: "unreadable",
        detail: "no planUsage object in the usage response",
        keys_seen: ["billingCycleStart", "billingCycleEnd", "usageSummary", "enabled"]}' > "$VERDICT"
run --json
check_eq "$RC" "0" "a changed shape does not fail the run"
check_eq "$(statuses_for cursor-one@example.com)" "unreadable" "the row reads unreadable"
check_eq "$(row_field cursor-one@example.com used_pct)" "null" \
  "and reports no figure rather than 0 %"
check_contains "$(row_field cursor-one@example.com detail)" \
  "billingCycleStart, billingCycleEnd, usageSummary, enabled" \
  "the note prints the keys the helper actually saw"

# `ok` with no pools is the helper contradicting itself. Reported as a shape
# problem, never as an account that quietly has nothing to show.
reset_state
CUR="$(seed_cursor_profile cursor-one@example.com)"
write_config "$(account_json cursor cursor-one@example.com "$CUR")"
jq -n '{status: "ok", pools: [], billing_cycle_end_epoch: 1790611774}' > "$VERDICT"
run --json
check_eq "$(statuses_for cursor-one@example.com)" "unreadable" \
  "an ok verdict with no pools reads unreadable"
check_contains "$(row_field cursor-one@example.com detail)" "no pool figures" \
  "and says the helper carried no pool figures"

# A pool the helper could not parse is simply absent from its list — the
# account still reports the pool it COULD read, and never invents the other.
reset_state
CUR="$(seed_cursor_profile cursor-one@example.com)"
write_config "$(account_json cursor cursor-one@example.com "$CUR")"
jq -n --argjson end "$(( CYCLE_END_MS / 1000 ))" \
  '{status: "ok", source: "network", billing_cycle_end_epoch: $end,
    pools: [{pool: "cursor-models", used_pct: 12.5}],
    plan_used_usd: null, plan_included_usd: null, plan_name: null}' > "$VERDICT"
run --json
check_eq "$(printf '%s' "$OUT" | jq 'length')" "1" "an unreadable pool yields one row, not two"
check_eq "$(pool_field cursor-one@example.com cursor-models used_pct)" "12.5" \
  "and the readable pool still reports its figure"
check_eq "$(printf '%s' "$OUT" | jq -r '[.[] | select(.pool == "other-models")] | length')" "0" \
  "control(-): the pool that could not be read is absent, not 0 %"

# A percentage that is not a number must not become 0 %. awk would coerce
# `"n/a"` to zero and the row would read as "plenty left" — the one outcome
# every reader in this toolset is built to prevent.
reset_state
CUR="$(seed_cursor_profile cursor-one@example.com)"
write_config "$(account_json cursor cursor-one@example.com "$CUR")"
jq -n --argjson end "$(( CYCLE_END_MS / 1000 ))" \
  '{status: "ok", source: "network", billing_cycle_end_epoch: $end,
    pools: [{pool: "cursor-models", used_pct: "n/a"},
            {pool: "other-models",  used_pct: 100}],
    plan_used_usd: null, plan_included_usd: null, plan_name: null}' > "$VERDICT"
run --json
check_eq "$(pool_field cursor-one@example.com cursor-models used_pct)" "null" \
  "a non-numeric percentage reports no figure, never 0 %"
check_eq "$(pool_field cursor-one@example.com cursor-models remaining_pct)" "null" \
  "and no remaining % is derived from it"
check_eq "$(pool_field cursor-one@example.com other-models used_pct)" "100" \
  "control(+): the numeric pool beside it still renders"

# --- 6. the helper's own failures degrade that account alone -----------------

reset_state
CUR="$(seed_cursor_profile cursor-one@example.com)"
write_config "$(account_json cursor cursor-one@example.com "$CUR")"
NODE_BIN_UNDER_TEST="$BIN/node-crash"
run --json
check_eq "$RC" "0" "a crashing helper does not fail the run"
check_eq "$(statuses_for cursor-one@example.com)" "unreachable" "a crashing helper reads unreachable"
check_eq "$(row_field cursor-one@example.com used_pct)" "null" "with no figure"

reset_state
CUR="$(seed_cursor_profile cursor-one@example.com)"
write_config "$(account_json cursor cursor-one@example.com "$CUR")"
NODE_BIN_UNDER_TEST="$BIN/node-noise"
run --json
check_eq "$(statuses_for cursor-one@example.com)" "unreadable" \
  "a helper that prints a log line instead of a verdict reads unreadable"
check_contains "$(row_field cursor-one@example.com detail)" "no JSON verdict" \
  "and says the verdict was not understood"

# No node at all: an install problem, named as one.
reset_state
CUR="$(seed_cursor_profile cursor-one@example.com)"
write_config "$(account_json cursor cursor-one@example.com "$CUR")"
NODE_BIN_UNDER_TEST="$TMP/no-such-node"
run --json
check_eq "$(statuses_for cursor-one@example.com)" "unreachable" "no node reads unreachable"
check_contains "$(row_field cursor-one@example.com detail)" "Node 20+" \
  "and the note names the missing runtime"

reset_state
CUR="$(seed_cursor_profile cursor-one@example.com)"
write_config "$(account_json cursor cursor-one@example.com "$CUR")"
HELPER_UNDER_TEST="$TMP/no-such-helper.js"
run --json
check_eq "$(statuses_for cursor-one@example.com)" "unreachable" "a missing helper reads unreachable"
check_contains "$(row_field cursor-one@example.com detail)" "helper is missing" \
  "and the note says the helper is missing"

# --- 7. one broken cursor account never takes another account down -----------

reset_state
CUR_OK="$(seed_cursor_profile good@example.com)"
write_config \
  "$(account_json cursor good@example.com "$CUR_OK")" \
  "$(account_json cursor broken@example.com "$PROFILES/broken@example.com/cursor")"
run --json
check_eq "$RC" "0" "a mixed run exits 0"
check_eq "$(statuses_for broken@example.com)" "needs-login" "the broken account reports its own status"
check_eq "$(statuses_for good@example.com | sort -u | tr '\n' ' ')" "ok " \
  "and the healthy account still renders both pool rows"
check_eq "$(printf '%s' "$OUT" | jq -r '[.[] | select(.label == "good@example.com")] | length')" "2" \
  "both of them"

# --- 8. --account narrows to one cursor account ------------------------------
#
# Deliberately continues from section 7's two-account registry above (no
# reset_state here): narrowing is only meaningful when there is something
# to narrow away from.

run --json --account good@example.com
check_eq "$(printf '%s' "$OUT" | jq 'length')" "2" "--account keeps that account's two rows"
check_eq "$(printf '%s' "$OUT" | jq -r '[.[].label] | unique | join(",")')" "good@example.com" \
  "and drops the others"

# --- 9. no cookie or session value ever reaches the output -------------------
#
# The fake helper carries a cookie-shaped value in a field the contract does
# not include, and the seeded profile's cookie store contains the same
# string. A reader that echoed the helper's raw stdout into a note, or read
# the cookie store itself, fails here.

reset_state
CUR="$(seed_cursor_profile cursor-one@example.com)"
write_config "$(account_json cursor cursor-one@example.com "$CUR")"

run
COMBINED="$OUT
$ERR"
check_not_contains "$COMBINED" "$COOKIE_SECRET" "no session cookie reaches the table or stderr"
check_eq "$(printf '%s' "$COMBINED" | grep -cE 'SessionToken|Cookie' || true)" "0" \
  "nothing cookie-shaped appears in the output at all"

run --json
COMBINED="$OUT
$ERR"
check_not_contains "$COMBINED" "$COOKIE_SECRET" "and none reaches --json output either"
check_eq "$(printf '%s' "$OUT" | jq -r '[.[] | keys[]] | unique | map(select(test("cookie|session|token"; "i"))) | length')" "0" \
  "no row key is cookie-, session-, or token-shaped"

# Control(+): the fixture really did carry the secret, or every assertion
# above would pass on a helper that returned nothing.
check_contains "$(cat "$VERDICT")" "$COOKIE_SECRET" \
  "control(+): the fixture verdict really did carry a session value"

USAGE_LOG="$CASE_HOME/.claude/script-usage.log"
if [[ -s "$USAGE_LOG" ]]; then
  check_not_contains "$(cat "$USAGE_LOG")" "$COOKIE_SECRET" \
    "the usage log never records a session value"
  check_not_contains "$(cat "$USAGE_LOG")" "@example.com" \
    "nor the account label"
else
  bad "the usage log was not written — the telemetry line is part of the contract"
fi

# --- 10. the reader is bounded ------------------------------------------------
#
# A browser that never finishes must not hold a five-account report open. The
# stub sleeps past the bound; the assertion is that the run still returns and
# the row says what happened.

cat > "$BIN/node-hang" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$NODE_LOG"
sleep 30
printf '{"status":"ok"}\n'
EOF
chmod +x "$BIN/node-hang"

reset_state
CUR="$(seed_cursor_profile cursor-one@example.com)"
write_config "$(account_json cursor cursor-one@example.com "$CUR")"
NODE_BIN_UNDER_TEST="$BIN/node-hang"
CURSOR_TIMEOUT_UNDER_TEST="2"
START="$(date -u +%s)"
run --json
ELAPSED=$(( $(date -u +%s) - START ))
check_eq "$RC" "0" "a hanging helper still returns a report"
check_eq "$(statuses_for cursor-one@example.com)" "unreachable" "and the row reads unreachable"
if [[ "$ELAPSED" -lt 20 ]]; then
  ok "the run was bounded (${ELAPSED}s, well under the helper's own sleep)"
else
  bad "the run was not bounded (${ELAPSED}s)"
fi

# --- summary -----------------------------------------------------------------

echo
echo "passed: $PASS   failed: $FAILED"
[[ "$FAILED" -eq 0 ]] || exit 1
exit 0
