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
