#!/usr/bin/env bash
# quotas-cheapest-next.test.sh — coverage for .claude/scripts/quotas-cheapest-next.sh (issue #1669).
# catalog: tests — Tests `quotas-cheapest-next.sh` — the overage annotation per provider (static table, live Codex reset balance, live Cursor on-demand spend), the threshold knob's `--threshold` → env → pm-config → default precedence and its invalid-value fallback, the at-or-below-threshold trigger with its inclusive boundary, the tier ordering that prefers included quota over a banked free reset over metered overage over a flat-fee reset, the Codex month watermark including its fail-soft read of a corrupt file, and the refusals that keep a broken run from printing as an empty-but-successful document
#
# WHAT IS UNDER TEST
#
# This script turns "how much is left" into "what does it cost to keep going,
# and where". Getting that wrong is expensive in a specific direction — it
# points at a $90 purchase — so the properties asserted here are the ones
# that guard that direction:
#
#   * the TRIGGER fires at or below the threshold, inclusive, and never above
#     it, so a hint appears exactly when one is needed;
#   * the ORDERING prefers quota already paid for, then a banked free reset,
#     then metered overage, and only then a flat fee;
#   * a LIVE figure in the row beats the checked-in table, and a table value
#     beats nothing — but a value this script cannot read as a number
#     contributes nothing rather than a fabricated 0;
#   * the WATERMARK fails SOFT. A missing or corrupt file reads as "one free
#     reset available", never as "you already spent it" — the latter is the
#     reading that steers toward the paid reset, and it must never come from
#     a parse failure;
#   * a run that could not compute a document REFUSES rather than printing an
#     empty one, because `{"rows":[],"cheapest_next":null}` and "I failed"
#     look identical to a caller.
#
# HERMETIC. HOME, the watermark directory, and the threshold are all pointed
# at scratch state, and AI_QUOTAS_NOW freezes the ET month, so the watermark
# assertions do not turn over at midnight on the 1st of a month.
#
# Run from anywhere: bash .claude/scripts/tests/quotas-cheapest-next.test.sh

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="$ROOT/.claude/scripts/quotas-cheapest-next.sh"

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

# Frozen at 2026-09-08T20:00:00Z — 4:00 PM EDT on the 8th, so the ET month is
# unambiguously 2026-09 whatever the runner's own clock and zone are.
NOW=1788897600
FROZEN_MONTH="2026-09"

CASE_HOME="$TMP/home"
STATE_DIR="$CASE_HOME/.claude/quotas"

reset_state() {
  rm -rf "$CASE_HOME"
  mkdir -p "$CASE_HOME/.claude"
}

# Never aborts the suite; sets OUT, ERR, RC.
run() { # <rows-json> [args…]
  local rows="$1"; shift
  local errf="$TMP/run.err"
  OUT="$(printf '%s' "$rows" | HOME="$CASE_HOME" \
        CLAUDE_QUOTAS_STATE_DIR="$STATE_DIR" \
        CLAUDE_QUOTAS_PM_CONFIG="${PM_CONFIG_OVERRIDE:-$EMPTY_PM_CONFIG}" \
        CLAUDE_QUOTAS_CHEAPEST_NEXT_THRESHOLD_PCT="${THRESHOLD_ENV-}" \
        AI_QUOTAS_NOW="$NOW" \
        "$SCRIPT" "$@" 2>"$errf")"
  RC=$?
  ERR="$(cat "$errf")"
}

# Runs a non-annotate mode (no stdin rows).
run_mode() { # <args…>
  local errf="$TMP/run.err"
  OUT="$(HOME="$CASE_HOME" \
        CLAUDE_QUOTAS_STATE_DIR="$STATE_DIR" \
        AI_QUOTAS_NOW="$NOW" \
        "$SCRIPT" "$@" 2>"$errf")"
  RC=$?
  ERR="$(cat "$errf")"
}

OUT=""; ERR=""; RC=0; THRESHOLD_ENV=""

# HERMETIC BY DEFAULT. Without CLAUDE_QUOTAS_PM_CONFIG every run would read
# THIS repo's .claude/pm-config.md — `repo-root.sh` resolves from the script's
# own directory, so no choice of cwd avoids it — and the "the default is 20"
# assertion below would in fact be reading the repo's `= 20`. It would pass
# for the wrong reason today and keep passing if that default ever changed.
# A Budget section with no threshold key is what "nothing configured" looks
# like, so the default is the only thing left to produce the answer.
EMPTY_PM_CONFIG="$TMP/pm-config-empty.md"
cat > "$EMPTY_PM_CONFIG" <<'MD'
# scratch pm-config

## Budget

```ini
daily_credit_budget_usd = 25
```
MD

# A Budget section that DOES configure the knob, for the precedence cases.
CONFIGURED_PM_CONFIG="$TMP/pm-config-configured.md"
cat > "$CONFIGURED_PM_CONFIG" <<'MD'
# scratch pm-config

## Budget

```ini
daily_credit_budget_usd = 25
quotas_cheapest_next_threshold_pct = 45
```
MD

PM_CONFIG_OVERRIDE=""

# --- fixtures ----------------------------------------------------------------
# Rows in the shape ai-quotas.sh emits, trimmed to the fields this script
# reads. `status` matters: only an `ok` row is a candidate, because a row that
# says `needs-login` carries no figure to rank and recommending an account
# nobody can log in to is worse than saying nothing.

row() { # <provider> <label> <window> <remaining|null> <status> [<extra-json>]
  local extra="${6:-}"
  [[ -n "$extra" ]] || extra='{}'
  jq -nc --arg p "$1" --arg l "$2" --arg w "$3" --arg r "$4" --arg s "$5" \
    --argjson extra "$extra" \
    '{provider: $p, label: $l, reported_email: $l, window: $w, pool: null,
      remaining_pct: (if $r == "null" then null else ($r | tonumber) end),
      status: $s, overage: null}
     + $extra'
}

rows() { # <row-json…>
  local acc="[]" r
  for r in "$@"; do
    acc="$(printf '%s' "$acc" | jq -c --argjson e "$r" '. += [$e]')"
  done
  printf '%s' "$acc"
}

echo "== quotas-cheapest-next.sh =="

# --- 1. --help contract ------------------------------------------------------

HELP_ERR="$TMP/help.err"
HELP_OUT="$(HOME="$CASE_HOME" "$SCRIPT" --help 2>"$HELP_ERR")"
check_eq "$?" "0" "--help exits 0"
check_contains "$HELP_OUT" "quotas-cheapest-next.sh" "--help names the script"
check_contains "$HELP_OUT" "EXIT STATUS" "--help carries the exit-status section"
check_contains "$HELP_OUT" "DEPENDENCIES" "--help carries the dependencies section"
check_eq "$(wc -c < "$HELP_ERR" | tr -d ' ')" "0" "--help writes nothing to stderr"

# --- 2. usage and input refusals ---------------------------------------------

reset_state
run '[]' --nonsense
check_eq "$RC" "3" "an unknown flag exits 3"
run '[]' --threshold
check_eq "$RC" "3" "--threshold with no value exits 3"
run '[]' --threshold 101
check_eq "$RC" "3" "--threshold above 100 exits 3"
run '[]' --threshold abc
check_eq "$RC" "3" "a non-numeric --threshold exits 3"

# The equals form is a SECOND parser branch, not a spelling of the first, so
# it gets its own coverage: a guard added to one and forgotten in the other is
# how `--threshold=` ends up silently meaning "the default".
run '[]' --threshold=
check_eq "$RC" "3" "--threshold= with an empty value exits 3"
run '[]' --threshold=101
check_eq "$RC" "3" "--threshold=101 exits 3, same as the spaced form"
run "$(rows "$(row claude a 7-day 40 ok)")" --threshold=55
check_eq "$RC" "0" "control(+): a valid --threshold=<pct> is accepted"
check_eq "$(printf '%s' "$OUT" | jq -r '.threshold_pct')" "55" \
  "and takes effect exactly as the spaced form does"

# Not an array: refuse. Emitting an empty document here would tell the caller
# "no rows, no hint" when the truth is "I could not read your input".
run '{"rows": []}'
check_eq "$RC" "5" "stdin that is not a JSON array exits 5"
check_contains "$ERR" "not a JSON array" "and says why"
check_eq "$OUT" "" "and prints no document at all"

# --- 3. the document shape ---------------------------------------------------

reset_state
run '[]'
check_eq "$RC" "0" "an empty array is a valid report"
check_eq "$(printf '%s' "$OUT" | jq -r 'type')" "object" "and the output is one object"
check_eq "$(printf '%s' "$OUT" | jq -r '.rows | length')" "0" "with no rows"
check_eq "$(printf '%s' "$OUT" | jq -r '.cheapest_next | tostring')" "null" "and no hint"
check_eq "$(printf '%s' "$OUT" | jq -r '.threshold_pct')" "20" "the default threshold is 20"
check_contains "$(printf '%s' "$OUT" | jq -r '.basis')" "do not convert" \
  "and the document states the basis of the comparison"

# --- 4. the acceptance case: 5 % Claude, 60 % Codex --------------------------
# The issue's own worked example. Discriminating: the account at 5 % is FIRST
# in the array, so a selector that took the first row, or the emptiest one,
# would name Claude.

reset_state
ACCEPT="$(rows \
  "$(row claude claude-one@example.com 7-day 5 ok)" \
  "$(row codex codex-one@example.com 7-day 60 ok)")"
run "$ACCEPT"
check_eq "$RC" "0" "the acceptance case exits 0"
check_eq "$(printf '%s' "$OUT" | jq -r '.cheapest_next.label')" "codex-one@example.com" \
  "the codex account is named as the cheapest to continue on"
check_eq "$(printf '%s' "$OUT" | jq -r '.cheapest_next.reason')" \
  "60 % weekly left, 1 free reset this month" \
  "and the reason gives both the headroom and the free reset"
check_eq "$(printf '%s' "$OUT" | jq -r '.rows[0].overage.label')" "API rate" \
  "the claude row prices its overage at the API rate"
check_eq "$(printf '%s' "$OUT" | jq -r '.rows[1].overage.label')" "1 free reset" \
  "and the codex row at the month's free reset"
check_eq "$(printf '%s' "$OUT" | jq -r '[.rows[] | select(.overage.last_verified != null)] | length')" "2" \
  "every priced row carries the date its price was verified"
check_eq "$(printf '%s' "$OUT" | jq -r '[.rows[] | select(.overage.source | startswith("https://"))] | length')" "2" \
  "and a source URL for it"

# --- 5. the threshold: trigger, boundary, and silence ------------------------

reset_state
run "$(rows "$(row claude a 7-day 55 ok)" "$(row codex c 7-day 60 ok)")"
check_eq "$(printf '%s' "$OUT" | jq -r '.cheapest_next | tostring')" "null" \
  "every account above the threshold yields no hint"

# Exactly ON the line fires it. A strict comparison would stay silent for the
# account the hint exists for, and the silence would look like "you're fine".
run "$(rows "$(row claude a 7-day 20 ok)")"
check_eq "$(printf '%s' "$OUT" | jq -r '.cheapest_next.label')" "a" \
  "an account exactly at the threshold fires the hint (boundary inclusive)"
run "$(rows "$(row claude a 7-day 21 ok)")"
check_eq "$(printf '%s' "$OUT" | jq -r '.cheapest_next | tostring')" "null" \
  "control(-): one point above it does not"

# --- 6. the threshold knob: precedence and fail-soft -------------------------
# Four rungs, most specific first: --threshold, the env override, pm-config.md,
# the built-in default. Each case below is discriminating — the configured
# value is 45, which is neither the default (20) nor any env value used here,
# so a rung that silently lost would show up as the wrong number rather than
# as a coincidence.

reset_state
PM_CONFIG_OVERRIDE="$CONFIGURED_PM_CONFIG"
run "$(rows "$(row claude a 7-day 40 ok)")"
check_eq "$(printf '%s' "$OUT" | jq -r '.threshold_pct')" "45" \
  "the pm-config.md Budget value is read when nothing more specific is set"
check_eq "$(printf '%s' "$OUT" | jq -r '.cheapest_next.label')" "a" \
  "and an account at 40 % fires the hint at that configured threshold"

THRESHOLD_ENV="30"
run "$(rows "$(row claude a 7-day 40 ok)")"
check_eq "$(printf '%s' "$OUT" | jq -r '.threshold_pct')" "30" \
  "the env override beats the pm-config.md value"
run "$(rows "$(row claude a 7-day 40 ok)")" --threshold 15
check_eq "$(printf '%s' "$OUT" | jq -r '.threshold_pct')" "15" \
  "and --threshold beats both"
THRESHOLD_ENV=""
PM_CONFIG_OVERRIDE=""

run "$(rows "$(row claude a 7-day 40 ok)")"
check_eq "$(printf '%s' "$OUT" | jq -r '.threshold_pct')" "20" \
  "control(-): with no key configured, the built-in default is what answers"

THRESHOLD_ENV="70"
run "$(rows "$(row claude a 7-day 55 ok)" "$(row codex c 7-day 60 ok)")"
check_eq "$(printf '%s' "$OUT" | jq -r '.threshold_pct')" "70" \
  "the env override sets the threshold"
check_eq "$(printf '%s' "$OUT" | jq -r '.cheapest_next.label')" "c" \
  "and a hint fires that the default 20 would have suppressed"

# --threshold beats the env override, because an explicit invocation is the
# most specific statement of intent available.
run "$(rows "$(row claude a 7-day 55 ok)" "$(row codex c 7-day 60 ok)")" --threshold 10
check_eq "$(printf '%s' "$OUT" | jq -r '.threshold_pct')" "10" \
  "--threshold beats the env override"
check_eq "$(printf '%s' "$OUT" | jq -r '.cheapest_next | tostring')" "null" \
  "and the run falls silent again at that threshold"

# A knob nobody can parse must not silently move the threshold — it is
# reported and replaced by the default.
THRESHOLD_ENV="abc"
run "$(rows "$(row claude a 7-day 5 ok)")"
check_eq "$RC" "0" "an unparseable threshold does not fail the run"
check_eq "$(printf '%s' "$OUT" | jq -r '.threshold_pct')" "20" \
  "and falls back to the default"
check_contains "$ERR" "invalid value 'abc'" "saying so on stderr rather than applying it silently"
THRESHOLD_ENV=""

# --- 7. ordering: paid-for quota, then a free reset, then metered, then flat --

reset_state
# Everything drained. Claude is metered; Codex, with its free reset spent,
# costs a flat ~$90 — so the metered account wins.
run_mode --record-codex-reset "2026-09-07" >/dev/null
run "$(rows "$(row codex c 7-day 2 ok)" "$(row claude a 7-day 3 ok)")"
check_eq "$(printf '%s' "$OUT" | jq -r '.cheapest_next.label')" "a" \
  "with the free reset spent, metered overage beats a flat-fee reset"
check_contains "$(printf '%s' "$OUT" | jq -r '.cheapest_next.reason')" "metered per unit of work" \
  "and the reason says the charge is metered"
check_eq "$(printf '%s' "$OUT" | jq -r '.rows[0].overage.label')" '~$90/reset' \
  "the codex row now prices the next reset instead of offering a free one"

# Restore the unspent-reset state: the banked reset now beats metered money,
# because it costs nothing.
reset_state
run "$(rows "$(row codex c 7-day 2 ok)" "$(row claude a 7-day 3 ok)")"
check_eq "$(printf '%s' "$OUT" | jq -r '.cheapest_next.label')" "c" \
  "control(+): with the reset unspent, the free reset wins instead"

# Included quota outranks both, even when the roomy account is last.
run "$(rows "$(row claude a 7-day 3 ok)" "$(row codex c 7-day 45 ok)")"
check_eq "$(printf '%s' "$OUT" | jq -r '.cheapest_next.label')" "c" \
  "an account with quota left outranks any kind of overage"

# --- 8. only a readable, successful row is a candidate -----------------------

reset_state
run "$(rows "$(row claude a 7-day 4 ok)" "$(row codex c 7-day 90 needs-login)")"
check_eq "$(printf '%s' "$OUT" | jq -r '.cheapest_next.label')" "a" \
  "a needs-login account is never recommended, however much it claims to have left"
check_eq "$(printf '%s' "$OUT" | jq -r '.rows[1].overage.label')" "1 free reset" \
  "though its overage price is still reported — the price does not depend on the read"

run "$(rows "$(row claude a 7-day null ok)")"
check_eq "$(printf '%s' "$OUT" | jq -r '.cheapest_next | tostring')" "null" \
  "a row with no readable remaining figure triggers nothing"

# --- 9. live figures beat the table ------------------------------------------

reset_state
run "$(rows "$(row codex c 7-day 4 ok '{"free_resets_remaining": 2}')")"
check_eq "$(printf '%s' "$OUT" | jq -r '.rows[0].overage.label')" "2 free resets" \
  "a live Codex reset balance is rendered in place of the table's value"
check_eq "$(printf '%s' "$OUT" | jq -r '.rows[0].overage.figure_source')" "live" \
  "and is marked as live"

# The captured payload's own numbers, converted: `individualUsed` 100750 and
# `individualLimit` 100000 are CENTS, so the dollars are 1007.50 of 1000 — the
# account is over its own on-demand limit. Using $100.75/$100 here would be a
# fixture off by a factor of ten from the response it claims to model.
run "$(rows "$(row cursor cu billing-cycle 0 ok '{"spend_limit_used_usd": 1007.50, "spend_limit_usd": 1000}')")"
check_eq "$(printf '%s' "$OUT" | jq -r '.rows[0].overage.label')" 'on-demand $1007.50 of $1000' \
  "a live Cursor on-demand figure is rendered as spent-of-limit"
check_eq "$(printf '%s' "$OUT" | jq -r '.rows[0].overage.figure_source')" "live" \
  "and is marked as live"

# Money formats as money: two fractional digits when there are cents, none
# when there are not. A bare number-to-string prints `$10.5`, which is not a
# price anyone writes and reads as a truncation in a column of figures.
run "$(rows "$(row cursor cu billing-cycle 0 ok '{"spend_limit_used_usd": 10.5, "spend_limit_usd": 20}')")"
check_eq "$(printf '%s' "$OUT" | jq -r '.rows[0].overage.label')" 'on-demand $10.50 of $20' \
  "a value with one decimal renders as two, and a whole dollar renders bare"

# A value that is not a number contributes NOTHING. A `tonumber`-style
# coercion would turn "n/a" into 0 and render "0 free resets" — a figure
# nobody sent, pointing straight at a paid reset.
run "$(rows "$(row codex c 7-day 4 ok '{"free_resets_remaining": "n/a"}')")"
check_eq "$(printf '%s' "$OUT" | jq -r '.rows[0].overage.label')" "1 free reset" \
  "an unreadable live figure falls back to the watermark rather than reading as zero"
check_eq "$(printf '%s' "$OUT" | jq -r '.rows[0].overage.figure_source')" "assumed" \
  "and is not marked live"

# --- 10. the Codex month watermark -------------------------------------------

reset_state
run_mode --codex-reset-status
check_eq "$RC" "0" "--codex-reset-status exits 0 with no watermark on disk"
check_eq "$(printf '%s' "$OUT" | jq -r '.free_reset_available')" "true" \
  "and reports a free reset available"
check_eq "$(printf '%s' "$OUT" | jq -r '.figure_source')" "assumed" \
  "marked as assumed, because nothing was read"

run_mode --record-codex-reset "2026-09-07"
check_eq "$RC" "0" "--record-codex-reset exits 0"
check_eq "$(jq -r '.month' "$STATE_DIR/codex-reset.json")" "$FROZEN_MONTH" \
  "and writes the month it was used in"
run_mode --codex-reset-status
check_eq "$(printf '%s' "$OUT" | jq -r '.free_reset_available')" "false" \
  "a reset recorded this month means no free one is left"
check_eq "$(printf '%s' "$OUT" | jq -r '.figure_source')" "watermark" \
  "and the verdict is attributed to the watermark"
check_eq "$(printf '%s' "$OUT" | jq -r '.used_on')" "2026-09-07" "with the date it was used"

# A watermark from a PREVIOUS month is spent history, not this month's answer.
run_mode --record-codex-reset "2026-08-30"
run_mode --codex-reset-status
check_eq "$(printf '%s' "$OUT" | jq -r '.free_reset_available')" "true" \
  "a reset recorded in an earlier month leaves this month's free one available"

run_mode --record-codex-reset "not-a-date"
check_eq "$RC" "3" "a malformed --record-codex-reset date exits 3"

# FAIL SOFT, and in the safe direction. A corrupt file must not read as "you
# already spent it": that reading is the one that steers the hint toward a $90
# purchase, and it would be steering on a parse failure.
reset_state
mkdir -p "$STATE_DIR"
printf 'not json at all\n' > "$STATE_DIR/codex-reset.json"
run_mode --codex-reset-status
check_eq "$RC" "0" "a corrupt watermark does not fail the run"
check_eq "$(printf '%s' "$OUT" | jq -r '.free_reset_available')" "true" \
  "and degrades to 'one free reset available', never to 'already spent'"
check_contains "$ERR" "unreadable" "saying so on stderr"

# --- 11. unknown providers are never priced ----------------------------------

reset_state
run "$(rows "$(row someone-else x 7-day 4 ok)")"
check_eq "$(printf '%s' "$OUT" | jq -r '.rows[0].overage | tostring')" "null" \
  "a provider with no table row gets a null overage, never a guessed one"
check_eq "$(printf '%s' "$OUT" | jq -r '.rows | length')" "1" \
  "and the row itself still survives into the report"
# Never RECOMMENDED, though. Ranking an unpriced account against a priced one
# compares a number to an absence, and the reason line would then assert a
# cost model ("continues at …, metered per unit of work") that nothing
# established. Silence is the honest answer when the only account left is one
# whose overage price we do not know.
check_eq "$(printf '%s' "$OUT" | jq -r '.cheapest_next | tostring')" "null" \
  "and it is never named as the cheapest to continue on"

# It can still TRIGGER the hint, though — an account running low is worth an
# answer even when its own price is unknown; the answer just names a priced
# account instead. Discriminating: the unpriced row is the only one below the
# threshold, so a trigger scoped to priced rows only would stay silent here.
run "$(rows "$(row someone-else x 7-day 4 ok)" "$(row codex c 7-day 80 ok)")"
check_eq "$(printf '%s' "$OUT" | jq -r '.cheapest_next.label')" "c" \
  "an unpriced account below the threshold still fires the hint, naming a priced one"

# --- 12. rows are carried through, not rebuilt -------------------------------

reset_state
run "$(rows "$(row claude a 7-day 4 ok '{"detail": "a note", "used_pct": 96}')")"
check_eq "$(printf '%s' "$OUT" | jq -r '.rows[0].detail')" "a note" \
  "fields this script does not read are carried through untouched"
check_eq "$(printf '%s' "$OUT" | jq -r '.rows[0].used_pct')" "96" \
  "including the figures the table renders"

# --- summary -----------------------------------------------------------------

echo
echo "passed: $PASS   failed: $FAILED"
[[ "$FAILED" -eq 0 ]] || exit 1
exit 0
