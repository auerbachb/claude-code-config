#!/usr/bin/env bash
# Source-only quota fixture group: last-known-placement. Run ai-quotas.test.sh.
# shellcheck source=../ai-quotas-fixtures.bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/ai-quotas-fixtures.bash"

# Split from the last-known group so both run in parallel inside the suite
# budget. Every case points the reader at this group's own temporary folder.
LKD="$TMP/last-known"

# --- 22k. #2330: a failed Claude or Codex read shows EVERY saved window ------
#
# The readers stay live-only: an account-wide failure emits one figureless
# 7-day placeholder, and apply_last_known alone expands it into one row per
# saved series. No reader row, history row or saved file carries a cached figure.

reset_state
rm -rf "$LKD"
export AI_QUOTAS_LAST_KNOWN_DIR="$LKD"
C1="$(seed_claude_profile claude-one@example.com "Claude Code-credentials-AAA")"
X1="$(seed_codex_profile codex-one@example.com "$(codex_snapshot_both)")"
write_config \
  "$(account_json claude claude-one@example.com "$C1" "Claude Code-credentials-AAA")" \
  "$(account_json codex codex-one@example.com "$X1")"
# A healthy --five-hour read saves both windows for both accounts.
run --json --five-hour
check_eq "$(printf '%s' "$OUT" | jq -r '[.[] | select(.status == "ok") | .window] | join(",")')" \
  "7-day,5-hour,7-day,5-hour" "seed: a healthy --five-hour read returns both windows for both accounts"
LK_CLAUDE="$LKD/claude--claude-one@example.com.json"
LK_CODEX="$LKD/codex--codex-one@example.com.json"
check_eq "$(jq -r '[.rows[].window] | sort | join(",")' "$LK_CLAUDE" 2>/dev/null)" "5-hour,7-day" "seed: both claude windows are saved"
check_eq "$(jq -r '[.rows[].window] | sort | join(",")' "$LK_CODEX" 2>/dev/null)" "5-hour,7-day" "seed: both codex windows are saved"
cp "$LK_CLAUDE" "$TMP/lk-claude-before.json"
cp "$LK_CODEX" "$TMP/lk-codex-before.json"
HIST_BEFORE="$(history_count)"

# Both accounts now fail account-wide: Anthropic is down; Codex has no
# app-server snapshot and an unparseable HTTP body.
echo "down" > "$STUB_ANTHROPIC_MODE"
rm -f "$X1/rate-limits.json"
printf 'not json' > "$STUB_CHATGPT_BODY"

lk_fail_rows() { # — label|window|status|used_pct|last_known_used_pct|last_known_source|last_known_expired
  printf '%s' "$OUT" | jq -r '.[] | [.label, .window, .status, (.used_pct | tostring),
    (.last_known_used_pct | tostring), (.last_known_source | tostring), (.last_known_expired | tostring)] | join("|")'
}
run --json --no-last-known
check_eq "$(lk_fail_rows)" "claude-one@example.com|7-day|unreachable|null|null|null|null
codex-one@example.com|7-day|unreachable|null|null|null|null" \
  "control: with --no-last-known each failed account is one figureless 7-day placeholder"

run --json
check_eq "$(lk_fail_rows)" "claude-one@example.com|7-day|unreachable|null|64|live: oauth-usage|false
claude-one@example.com|5-hour|unreachable|null|12|live: oauth-usage|false
codex-one@example.com|7-day|unreachable|null|45|live: app-server|false
codex-one@example.com|5-hour|unreachable|null|9|live: app-server|false" \
  "a failed read shows one row per saved window, each with its own figure, without --five-hour"
cmp -s "$LK_CLAUDE" "$TMP/lk-claude-before.json"
check_eq "$?" "0" "the failed claude read leaves its saved file byte-identical"
cmp -s "$LK_CODEX" "$TMP/lk-codex-before.json"
check_eq "$?" "0" "the failed codex read leaves its saved file byte-identical"
check_eq "$(history_count)" "$HIST_BEFORE" "the failed reads append no history rows"

run
check_eq "$RC" "0" "the table renders after the failed reads"
for lk_fig in "64% (last known" "12% (last known" "45% (last known" "9% (last known"; do
  check_contains "$OUT" "$lk_fig" "the table labels the saved figure: $lk_fig"
done
check_eq "$(history_count)" "$HIST_BEFORE" "and the table run appends no history rows either"
unset AI_QUOTAS_LAST_KNOWN_DIR

# --- 22l. #2330: placement claims each saved series once per account ---------
#
# Real readers rarely emit multi-row failures, so the placement rules are
# driven directly: the REAL apply_last_known, extracted by its anchored
# definition, runs on synthetic documents with a stubbed helper.

LKP_SRC="$(awk '/^apply_last_known\(\) \{/{f=1} f{print} f && /^\}$/{exit}' "$SCRIPT")"
check_eq "$(printf '%s\n' "$LKP_SRC" | grep -c 'lk_run lookup' || true)" "1" \
  "control(+): the extracted body is the function that asks the helper for saved figures"
LKP_DIR="$TMP/lk-place"
mkdir -p "$LKP_DIR"

lkp_row() { # <provider> <label> <window> <pool|""> <status> <used_pct|null> <detail>
  jq -cn --arg p "$1" --arg l "$2" --arg w "$3" --arg pool "$4" --arg s "$5" --argjson u "$6" --arg d "$7" \
    '{provider: $p, label: $l, window: $w, pool: (if $pool == "" then null else $pool end),
      status: $s, used_pct: $u, detail: $d}'
}
lkp_series() { # <provider> <label> <window> <pool|""> <used_pct>
  jq -cn --arg p "$1" --arg l "$2" --arg w "$3" --arg pool "$4" --argjson u "$5" \
    '{provider: $p, label: $l, window: $w, pool: (if $pool == "" then null else $pool end),
      used_pct: $u, fetched_at_epoch: 1000, source: "live: fixture", resets_at_epoch: null, expired: false}'
}
lkp_doc() { # <row-json…> — writes the document
  jq -n --args '{rows: ($ARGS.positional | map(fromjson))}' -- "$@" > "$LKP_DIR/doc.json"
}
lkp_run() { # <helper-exit> — places $LKP_DIR/series.jsonl into doc.json; keys asked go to keys.jsonl
  : > "$LKP_DIR/keys.jsonl"; : > "$LKP_DIR/warn.log"
  ( TMP="$LKP_DIR"; LK_ENABLED=1; LK_DIR="$LKP_DIR/unused"; NOW=2000
    warn() { printf '%s\n' "$*" >> "$LKP_DIR/warn.log"; }
    epoch_to_et() { printf 'ET-%s' "$1"; }
    lk_run() {
      [[ "$1" == "lookup" ]] || return 9
      cat > "$LKP_DIR/keys.jsonl"
      cat "$LKP_DIR/series.jsonl"
      return "$LKP_HELPER_RC"
    }
    LKP_HELPER_RC="$1"
    eval "$LKP_SRC"
    apply_last_known "$LKP_DIR/doc.json" )
}
lkp_rows() { # — label|window|pool|status|detail|used_pct|last_known_used_pct, one row per line
  jq -r '.rows[] | [.label, .window, (.pool // "-"), .status, .detail, (.used_pct | tostring),
    (.last_known_used_pct | tostring)] | join("|")' "$LKP_DIR/doc.json"
}
lkp_keys() { jq -r '.label' "$LKP_DIR/keys.jsonl" | paste -sd, -; }

# A failed 7-day and a failed 5-hour row, with only the 7-day series saved:
# the 5-hour failure row stays visible (it used to be dropped).
lkp_doc "$(lkp_row claude a 7-day "" unreachable null d1)" "$(lkp_row claude a 5-hour "" unreachable null d2)"
lkp_series claude a 7-day "" 50 > "$LKP_DIR/series.jsonl"
lkp_run 0
check_eq "$(lkp_rows)" "a|7-day|-|unreachable|d1|null|50
a|5-hour|-|unreachable|d2|null|null" \
  "a failed row with no saved series of its own is kept unchanged beside the derived row"

# An unrelated account with two failed rows and nothing saved keeps both rows,
# though another account's saved series is placed in the same run.
lkp_doc "$(lkp_row claude a 7-day "" unreachable null d1)" \
  "$(lkp_row codex b 7-day "" unreachable null e1)" "$(lkp_row codex b 5-hour "" needs-login null e2)"
lkp_series claude a 7-day "" 50 > "$LKP_DIR/series.jsonl"
lkp_run 0
check_eq "$(lkp_rows)" "a|7-day|-|unreachable|d1|null|50
b|7-day|-|unreachable|e1|null|null
b|5-hour|-|needs-login|e2|null|null" \
  "an account with no saved series keeps every row, whatever other accounts receive"
check_eq "$(lkp_keys)" "a,b" "both failed accounts are looked up"

# Duplicate live keys: the saved series attaches once, to the first matching
# row; its own series comes before an orphan whatever order the helper used.
lkp_doc "$(lkp_row claude a 7-day "" unreachable null d1)" "$(lkp_row claude a 7-day "" unreachable null d2)"
{ lkp_series claude a 5-hour "" 20; lkp_series claude a 7-day "" 50; } > "$LKP_DIR/series.jsonl"
lkp_run 0
check_eq "$(lkp_rows)" "a|7-day|-|unreachable|d1|null|50
a|5-hour|-|unreachable|d1|null|20
a|7-day|-|unreachable|d2|null|null" \
  "a duplicate-key row claims nothing and is kept; no series is repeated; own before orphan"

# A multi-row Cursor failure with two saved pools: each pool goes to its own
# row once; a failure row whose pool nothing saved is kept unchanged.
lkp_doc "$(lkp_row cursor cur billing-cycle cursor-models unreadable null c1)" \
  "$(lkp_row cursor cur billing-cycle other-models unreadable null c2)" \
  "$(lkp_row cursor cur billing-cycle "" unreadable null c3)"
{ lkp_series cursor cur other-models other-models 70; lkp_series cursor cur cursor-models cursor-models 60; } > "$LKP_DIR/series.jsonl"
lkp_run 0
check_eq "$(lkp_rows)" "cur|billing-cycle|cursor-models|unreadable|c1|null|60
cur|billing-cycle|other-models|unreadable|c2|null|70
cur|billing-cycle|-|unreadable|c3|null|null" \
  "cursor: each saved pool is placed once, on its own row, and the unclaimed row is kept"

# One account-wide Cursor placeholder still carries both saved pools.
lkp_doc "$(lkp_row cursor cur billing-cycle "" unreadable null c1)"
{ lkp_series cursor cur cursor-models cursor-models 60; lkp_series cursor cur other-models other-models 70; } > "$LKP_DIR/series.jsonl"
lkp_run 0
check_eq "$(lkp_rows)" "cur|billing-cycle|cursor-models|unreadable|c1|null|60
cur|billing-cycle|other-models|unreadable|c1|null|70" \
  "cursor: a single failure placeholder expands into one row per saved pool"

# An account with a usable ok row is not looked up and is left exactly as read,
# even if the helper (wrongly) answered for it.
lkp_doc "$(lkp_row codex ok-acct 7-day "" ok 30 live)" "$(lkp_row codex ok-acct 5-hour "" unreachable null f1)" \
  "$(lkp_row claude a 7-day "" unreachable null d1)"
{ lkp_series codex ok-acct 5-hour "" 99; lkp_series claude a 7-day "" 50; } > "$LKP_DIR/series.jsonl"
lkp_run 0
check_eq "$(lkp_keys)" "a" "an account with a usable live row is not looked up"
check_eq "$(lkp_rows)" "ok-acct|7-day|-|ok|live|30|null
ok-acct|5-hour|-|unreachable|f1|null|null
a|7-day|-|unreachable|d1|null|50" \
  "and its rows are unchanged; only the failed account is enriched"

# A figureless ok row becomes unreadable; a derived row never keeps a reader used_pct.
lkp_doc "$(lkp_row claude a 7-day "" ok null "")" "$(lkp_row codex b 7-day "" unreachable 40 e1)"
{ lkp_series claude a 7-day "" 50; lkp_series codex b 7-day "" 45; } > "$LKP_DIR/series.jsonl"
lkp_run 0
check_eq "$(lkp_rows)" "a|7-day|-|unreadable|live read returned no usable figure|null|50
b|7-day|-|unreachable|e1|null|45" \
  "a figureless ok row reads unreadable, and every derived row has used_pct null"

# The helper returns no series, or fails: the document is unchanged.
lkp_doc "$(lkp_row claude a 7-day "" unreachable null d1)" "$(lkp_row claude a 5-hour "" unreachable null d2)"
cp "$LKP_DIR/doc.json" "$LKP_DIR/doc-before.json"
: > "$LKP_DIR/series.jsonl"
lkp_run 0
cmp -s "$LKP_DIR/doc.json" "$LKP_DIR/doc-before.json"
check_eq "$?" "0" "no saved series leaves the document byte-identical"
lkp_series claude a 7-day "" 50 > "$LKP_DIR/series.jsonl"
lkp_run 1
cmp -s "$LKP_DIR/doc.json" "$LKP_DIR/doc-before.json"
check_eq "$?" "0" "a failed helper call leaves the document byte-identical"
check_contains "$(cat "$LKP_DIR/warn.log")" "DEGRADED" "and says so"
