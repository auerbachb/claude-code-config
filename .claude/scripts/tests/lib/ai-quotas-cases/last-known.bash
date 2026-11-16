#!/usr/bin/env bash
# Source-only quota fixture group: last-known. Run ai-quotas.test.sh.
# shellcheck source=../ai-quotas-fixtures.bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/ai-quotas-fixtures.bash"

# --- 22. the last-known folder (#2280) ---------------------------------------
#
# A usable live read is saved per account; a failed read shows the saved figure
# as last known and never as live usage. The folder is private to this group:
# every case points the reader at its own temporary folder, never the owner's.

LKD="$TMP/last-known"
LK_HELPER="$(cd "$(dirname "$SCRIPT")" && pwd)/lib/quotas-last-known.py"
LK_FILE="$LKD/cursor--cursor-one@example.com.json"
export AI_QUOTAS_LAST_KNOWN_DIR="$LKD"

lk_reset() {
  reset_state
  rm -rf "$LKD"
  export AI_QUOTAS_LAST_KNOWN_DIR="$LKD"
  seed_cursor_account
}

lk_row() { # <pool|window> <field> — from the last run's JSON document
  printf '%s' "$DOC" | jq -r --arg p "$1" --arg f "$2" \
    '.rows[] | select((.pool // .window) == $p) | .[$f] | if . == null then "null" else tostring end'
}

lk_seed_owner() { # <used_pct> <resets-text> <now-epoch>
  python3 "$LK_HELPER" owner-report --dir "$LKD" --now "$3" --provider cursor \
    --label cursor-one@example.com --nickname Cursor --window cursor-models --pool cursor-models \
    --used-pct "$1" --resets-text "$2" --now-et "fixture" >/dev/null 2>&1
  python3 "$LK_HELPER" owner-report --dir "$LKD" --now "$3" --provider cursor \
    --label cursor-one@example.com --nickname Cursor --window other-models --pool other-models \
    --used-pct "$1" --resets-text "$2" --now-et "fixture" >/dev/null 2>&1
}

# --- 22a. a usable live read is saved, privately, without secrets ----------

lk_reset
run --json
check_eq "$RC" "0" "a healthy cursor read still exits 0 with the folder in place"
check_eq "$(stat -c '%a' "$LKD" 2>/dev/null || stat -f '%Lp' "$LKD")" "700" \
  "the last-known folder is created private (0700)"
check_eq "$(stat -c '%a' "$LK_FILE" 2>/dev/null || stat -f '%Lp' "$LK_FILE")" "600" \
  "the account file is private (0600)"
check_eq "$(jq -r '.rows | length' "$LK_FILE")" "2" "both cursor pools are saved"
check_not_contains "$(cat "$LK_FILE")" "$CURSOR_FIXTURE_TOKEN" "no token reaches the folder"
check_not_contains "$(cat "$LK_FILE")" "FIXTURE-CURSOR-USER" "no user id reaches the folder"
check_eq "$(lk_row cursor-models last_known_used_pct)" "null" \
  "a healthy row carries no last-known figure"
# #2406: a figure read in this run is live, shown as `now`.
check_eq "$(lk_row cursor-models fetched)" "live" "a live read is marked live"
check_eq "$(lk_row cursor-models fetched_display)" "now" "and the FETCHED cell says now"
check_eq "$(lk_row cursor-models fetched_at)" "$(utc_iso "$NOW")" "with this run's time as an ISO-8601 UTC instant"
run
check_contains "$(table_only "$OUT")" "FETCHED" "the table has a FETCHED column"

# --- 22b. a failed read keeps the file byte-for-byte and shows the figure ---

cp "$LK_FILE" "$TMP/lk-before.json"
echo "shape" > "$STUB_CURSOR_MODE"
run --json
check_eq "$RC" "0" "a failed cursor read does not fail the run"
cmp -s "$LK_FILE" "$TMP/lk-before.json"
check_eq "$?" "0" "a failed read leaves the saved file byte-identical"
check_eq "$(lk_row cursor-models status)" "unreadable" "the live status is unchanged"
check_eq "$(lk_row cursor-models used_pct)" "null" "used_pct stays null on a failed read"
check_eq "$(lk_row cursor-models last_known_used_pct)" "53" \
  "the saved figure appears in last_known_used_pct, not used_pct"
check_eq "$(lk_row cursor-models last_known_source)" "live: ide-token" \
  "and names where it came from"
check_eq "$(lk_row cursor-models last_known_expired)" "false" \
  "a saved figure with no passed reset is not expired"
# #2406: a figure saved earlier in the day shows the date, never `now`.
check_eq "$(lk_row cursor-models fetched)" "saved" "a saved figure is marked saved"
check_eq "$(lk_row cursor-models fetched_display)" "Sep 08" "and shows its date, not now"
check_eq "$(lk_row cursor-models fetched_at)" "$(utc_iso "$NOW")" "and the instant it was read"
run
check_contains "$(table_only "$OUT")" "Sep 08" "the table prints that date in the FETCHED column"
echo "ok" > "$STUB_CURSOR_MODE"

# --- 22c. the ticket fixture: an owner-reported 100% on both pools ---------

lk_reset
lk_seed_owner 100 "Nov 28 2026" "$NOW"
echo "shape" > "$STUB_CURSOR_MODE"
run
check_eq "$RC" "0" "the owner-reported fixture renders with a failed read"
printf '%s\n' "$OUT" > "$TMP/lk-table.txt"
check_contains "$OUT" "last known" "the table shows the saved figure, labelled last known"
check_contains "$OUT" "owner-reported" "with its source"
check_contains "$OUT" "resets" "and its reset"
check_not_contains "$OUT" "expired" "a reset in the future is not expired"
run --json
check_eq "$(lk_row cursor-models status)" "unreadable" \
  "the cursor-models row keeps the live unreadable status"
check_eq "$(lk_row other-models last_known_used_pct)" "100" \
  "the other-models pool carries its own saved figure"
echo "ok" > "$STUB_CURSOR_MODE"

# --- 22d. an expired saved reset is shown as expired ------------------------

lk_reset
YESTERDAY_ET="$(python3 -c "import datetime; print(datetime.datetime.fromtimestamp($NOW - 86400, datetime.timezone.utc).strftime('%Y-%m-%d'))")"
lk_seed_owner 100 "$YESTERDAY_ET" "$((NOW - 3 * 86400))"
echo "shape" > "$STUB_CURSOR_MODE"
run --json
check_eq "$(lk_row cursor-models last_known_expired)" "true" \
  "a saved reset before now is flagged expired"
run
check_contains "$OUT" "expired: " "and the table says expired, not current"
echo "ok" > "$STUB_CURSOR_MODE"

# --- 22d2. the table shows a saved figure in USED, dated in FETCHED, explained in a footnote ---

lk_reset
lk_seed_owner 77 "Nov 28 2026" "$((NOW - 3 * 86400))"
echo "shape" > "$STUB_CURSOR_MODE"
run --json
check_eq "$(lk_row cursor-models used_pct)" "null" "json: used_pct stays null for a saved figure"
check_eq "$(lk_row cursor-models last_known_used_pct)" "77" "json: the saved figure stays in last_known_used_pct"
run
LK_TABLE="$(table_only "$OUT")"
LK_ROW="$(printf '%s\n' "$LK_TABLE" | grep -E '^cursor-fixture' | head -n 1)"
check_contains "$LK_ROW" " 77% " "table: a fresh saved figure shows its percent in USED"
check_not_contains "$LK_ROW" " now " "and FETCHED is a date, never now"
check_contains "$LK_ROW" "Nov " "and the reset column shows the saved reset"
check_contains "$LK_ROW" "[" "and the row points at a footnote"
check_contains "$OUT" "(last known" "whose text says it is last known"
check_not_contains "$(printf '%s\n' "$LK_ROW" | sed 's/\[[0-9]*\]//')" "last known" "and the explanation is not in the row itself"
check_eq "$(printf '%s\n' "$LK_TABLE" | awk '{ if (length($0) > m) m = length($0) } END { print (m <= 140) ? "fits" : "wide" }')" "fits" "and the table stays within 140 columns"

# An expired saved figure is blank in USED, with the footnote saying expired.
lk_reset
YESTERDAY_ET="$(python3 -c "import datetime; print(datetime.datetime.fromtimestamp($NOW - 86400, datetime.timezone.utc).strftime('%Y-%m-%d'))")"
lk_seed_owner 77 "$YESTERDAY_ET" "$((NOW - 3 * 86400))"
echo "shape" > "$STUB_CURSOR_MODE"
run
LK_ROW="$(printf '%s\n' "$(table_only "$OUT")" | grep -E '^cursor-fixture' | head -n 1)"
check_not_contains "$LK_ROW" "77%" "table: an expired saved figure is not shown in USED"
check_contains "$OUT" "expired: 77%" "and the footnote says it expired"

# No saved figure at all: blank USED and no FETCHED date.
lk_reset
echo "shape" > "$STUB_CURSOR_MODE"
run
LK_ROW="$(printf '%s\n' "$(table_only "$OUT")" | grep -E '^cursor-fixture' | head -n 1)"
check_not_contains "$LK_ROW" "%" "table: with no saved figure USED is blank"
check_not_contains "$OUT" "last known" "and nothing claims a last known figure"
echo "ok" > "$STUB_CURSOR_MODE"

# --- 22d3. restored account columns: one observation, own top-tier expiry, never a foreign currency ---

lk_reset
run --json
jq --argjson t "$((NOW - 100))" '.rows |= map(. + {account: {paid_enabled: true, paid_cap_usd: 40, paid_spent_usd: 12.5,
     paid_currency: "EUR", paid_period: "monthly", limit_resets_available: 3, top_label: "Zed", top_used_pct: 40, top_resets_at_epoch: $t}})' \
  "$LK_FILE" > "$TMP/lk-acct.json"
cat "$TMP/lk-acct.json" > "$LK_FILE"
echo "shape" > "$STUB_CURSOR_MODE"
run --json
check_eq "$(lk_row cursor-models paid_enabled)" "true" "restore: the saved paid flag comes back with the saved reading"
check_eq "$(lk_row other-models limit_resets_available)" "3" "restore: the other pool row carries the same account observation"
check_eq "$(lk_row cursor-models top_label)" "null" "restore: a top tier whose own reset has passed is not restored, though the saved window is still valid"
check_eq "$(lk_row cursor-models top_used_pct)" "null" "and neither is its percent"
run
LK_ROW="$(printf '%s\n' "$(table_only "$OUT")" | grep -E '^cursor-fixture' | head -n 1)"
check_not_contains "$LK_ROW" '$40' "table: a euro cap is never printed as dollars"
check_not_contains "$LK_ROW" '12.50' "and neither is a euro spend"
check_contains "$OUT" "paid amounts are in EUR, not shown" "and the footnote says why"
echo "ok" > "$STUB_CURSOR_MODE"

# --- 22e. the next usable live read replaces an owner reading ---------------

lk_reset
lk_seed_owner 100 "Nov 28 2026" "$NOW"
run --json
check_eq "$RC" "0" "a healthy read after an owner entry exits 0"
check_contains "$(cat "$LK_FILE")" "live: ide-token" "the owner reading is replaced by the live reading"
check_not_contains "$(cat "$LK_FILE")" "owner-reported" "no owner-reported row survives the live read"

# --- 22f. a stopgap-format file (no schema, no row provenance) still reads --

lk_reset
mkdir -p "$LKD"
cat > "$LK_FILE" <<'STOPGAP'
{
  "provider": "cursor",
  "label": "cursor-one@example.com",
  "nickname": "Cursor",
  "fetched_at_epoch": 1794512040,
  "fetched_at_et": "Thu Nov 12 2026 2:34 PM ET",
  "source": "owner-reported",
  "rows": [
    {"window": "cursor-models", "used_pct": 100, "resets_at_epoch": null, "resets": "Nov 28 2026", "overage": null},
    {"window": "other-models", "used_pct": 100, "resets_at_epoch": null, "resets": "Nov 28 2026", "overage": null}
  ]
}
STOPGAP
echo "shape" > "$STUB_CURSOR_MODE"
run --json
check_eq "$(lk_row cursor-models last_known_used_pct)" "100" \
  "a stopgap file without row provenance is read"
check_eq "$(lk_row cursor-models last_known_source)" "owner-reported" \
  "and inherits its file-level source"
echo "ok" > "$STUB_CURSOR_MODE"

# --- 22g. a newer saved reading is never overwritten by an older run -------

lk_reset
lk_seed_owner 100 "Nov 28 2026" "$((NOW + 3600))"
before="$(cat "$LK_FILE")"
run --quiet
check_eq "$(cat "$LK_FILE")" "$before" "a file with a newer reading is not overwritten by an older run"

# --- 22h. a symlinked folder warns and the report still renders ------------

lk_reset
rm -rf "$LKD"; mkdir -p "$TMP/lk-target"; ln -s "$TMP/lk-target" "$LKD"
run --json
check_eq "$RC" "0" "a symlinked folder does not fail the report"
check_eq "$(jq -r '.rows | length' <<<"$DOC")" "2" "and the rows still render"
check_contains "$ERR" "DEGRADED" "with a warning on stderr"
rm -f "$LKD"

# --- 22i. --no-last-known never touches the helper; a positive control does -

lk_reset
LOG="$TMP/lk-stub.log"
STUB="$TMP/lk-stub.sh"
printf '#!/bin/sh\necho "$*" >> %s\ncat >/dev/null\nexit 0\n' "$LOG" > "$STUB"
chmod +x "$STUB"
: > "$LOG"
export AI_QUOTAS_LAST_KNOWN_BIN="$STUB"
run --json --no-last-known
check_eq "$(wc -c < "$LOG" | tr -d ' ')" "0" "--no-last-known never invokes the helper"
echo "shape" > "$STUB_CURSOR_MODE"
run --json
check_contains "$(cat "$LOG")" "lookup" \
  "positive control: without the flag, a failed read asks the helper for saved figures"
echo "ok" > "$STUB_CURSOR_MODE"

# --- 22j. a scheduled --no-last-known run makes no helper call either ------

: > "$LOG"
run --json --no-last-known --quiet
check_eq "$(wc -c < "$LOG" | tr -d ' ')" "0" "a scheduled --no-last-known run also makes no helper call"
unset AI_QUOTAS_LAST_KNOWN_BIN

unset AI_QUOTAS_LAST_KNOWN_DIR

# --- 22e. #2406: zero-padded day, year boundary, and no figure -------------

# 2026-01-01 17:00Z is Jan 01 in Eastern time; 2026-01-01 04:30Z is still Dec 31.
lk_reset
lk_seed_owner 100 "Nov 28 2026" "1767286800"
echo "shape" > "$STUB_CURSOR_MODE"
run --json
check_eq "$(lk_row cursor-models fetched_display)" "Jan 01" "a single-digit day is zero-padded"
lk_reset
lk_seed_owner 100 "Nov 28 2026" "1767241800"
echo "shape" > "$STUB_CURSOR_MODE"
run --json
check_eq "$(lk_row cursor-models fetched_display)" "Dec 31" "the date is Eastern, so a UTC new year can still be Dec 31"
lk_reset
echo "shape" > "$STUB_CURSOR_MODE"
run --json
check_eq "$(printf '%s' "$DOC" | jq -r '[.rows[] | .fetched // "null"] | unique | join(",")')" "null" "a row with no figure at all has no fetched kind"
check_eq "$(printf '%s' "$DOC" | jq -r '[.rows[] | .fetched_display // "null"] | unique | join(",")')" "null" "and no display, never now"
run
check_not_contains "$(table_only "$OUT")" "now" "and the table never claims now for it"
echo "ok" > "$STUB_CURSOR_MODE"
