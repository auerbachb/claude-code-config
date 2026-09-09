#!/usr/bin/env bash
# quotas-cheapest-next.sh — price the overage on each /quotas row and name the
# cheapest account to continue on (issue #1669).
# catalog: token-measurement — Annotate `ai-quotas.sh --json` rows with each provider's overage cost (Codex free-or-paid reset, Claude API rate, Cursor on-demand) from a checked-in table with `last verified` dates, prefer a live figure when the row carries one, and name the cheapest account to continue on when any account is at or below the configurable remaining threshold; informational only, never a dispatch or spend gate
#
# PURPOSE
#   `ai-quotas.sh` answers "how much is left". At the end of a drained week
#   the owner's next question is "what does it cost to keep going, and where".
#   Each provider prices that differently: Codex sells an instant reset (one
#   free, then a flat fee), Claude bills extra usage at API rates, Cursor
#   continues on-demand at model API price. This script attaches that cost to
#   every row and, when at least one account is at or below the threshold,
#   names the cheapest place to continue.
#
#   INFORMATIONAL ONLY. This never switches accounts, never purchases
#   anything, and never gates dispatch. It writes no dispatch state: not
#   `session-state.json`, not `credit-budget.sh`'s inputs, not any gate. The
#   authority on quota and spend stays where `.claude/rules/safety.md`
#   §"Anthropic Quota & Spend Authority" puts it — Anthropic's own in-app UI
#   and upstream harness signals. The earlier `/quota` skill was rolled back
#   in issue #499 for gating agent decisions on locally-read numbers; this one
#   prices a choice and stops. The ONE file it may write is the Codex reset
#   watermark below, and only when `--record-codex-reset` is passed
#   explicitly.
#
#   THE COMPARISON IS APPROXIMATE, AND SAYS SO. A Codex reset buys a fixed
#   week at a flat price; Claude and Cursor overage is metered per unit of
#   work actually done. Those units do not convert. The ranking below is over
#   WHAT CONTINUING COSTS YOU — included quota you already paid for, then a
#   banked free reset, then metered overage, then a flat fee — and every
#   verdict carries the `basis` string stating that. It is a starting point
#   for the owner's decision, never a substitute for it.
#
# USAGE
#   ai-quotas.sh --json | quotas-cheapest-next.sh [--threshold <pct>]
#   quotas-cheapest-next.sh --codex-reset-status
#   quotas-cheapest-next.sh --record-codex-reset [YYYY-MM-DD]
#   quotas-cheapest-next.sh --help | -h
#
#   (default)      Read a JSON ARRAY of rows on stdin; write one JSON object
#                  on stdout. `ai-quotas.sh` calls it this way and renders the
#                  result; nothing else needs to.
#   --threshold <pct>
#                  Integer 0-100, overriding the configured threshold for this
#                  run only. Highest precedence — an explicit invocation beats
#                  the env override, which beats pm-config.md, which beats the
#                  built-in default of 20.
#   --codex-reset-status
#                  Print the reset watermark's verdict as JSON and exit.
#   --record-codex-reset [YYYY-MM-DD]
#                  Record that a Codex reset was used (default: today, ET).
#                  The ONLY writing mode. Run it after buying or spending a
#                  reset so later reports stop offering a free one.
#
# INPUT
#   A JSON array of `ai-quotas.sh` rows. Each row is read for `provider`,
#   `label`, `reported_email`, `window`, `pool`, `remaining_pct`, `status`,
#   and the optional live-figure fields below. Unknown fields are carried
#   through untouched, so a row gains `overage` and loses nothing.
#
# OUTPUT
#   One JSON object on stdout:
#
#     {"schema_version": "1.0",
#      "threshold_pct": 20,
#      "basis": "…",
#      "rows": [ <every input row, each with an `overage` object or null> ],
#      "cheapest_next": {"label": …, "provider": …, "window": …,
#                        "remaining_pct": …, "reason": …, "basis": …,
#                        "overage": {…}}   or null}
#
#   `cheapest_next` is null unless at least one `ok` row with a readable
#   `remaining_pct` sits AT OR BELOW the threshold. Below-threshold is the
#   trigger, not the filter: once it fires, every PRICED `ok` row competes,
#   including the drained one (continuing where you are, at API rate, is a
#   legitimate answer). Triggering and competing are different populations —
#   an unpriced provider can put an account below the threshold, but it can
#   never be the account recommended, because there is no price to rank it by.
#
#   Each row's `overage` object carries `label` (what the table's column
#   shows), `base_label` (the table's generic wording, which the hint's prose
#   uses so a live figure does not read as a rate), `kind` (`metered` or
#   `reset`), `detail`, `source` (the URL the
#   figure came from), `last_verified` (the date someone checked that URL),
#   `cost_rank`, and `figure_source` — `live` when the row itself carried the
#   number, `watermark` when the Codex reset file decided it, `assumed` when
#   that file was missing or unreadable, `table` for the checked-in default.
#   A provider this script has no prices for gets `overage: null`, never a
#   guess.
#
# WHERE THE PRICES COME FROM
#   The table is CHECKED IN, here and in prose in .claude/reference/
#   ai-quotas.md, and it is only as fresh as its `last_verified` dates. It is
#   deliberately NOT read from `.claude/reference/pricing-matrix.md`: that
#   file is the REVIEW-STACK wallet (CodeRabbit, BugBot, Greptile, CodeAnt),
#   a different wallet from these coding-assistant subscriptions. Numbers
#   never move between the two.
#
# THE CODEX RESET WATERMARK
#   OpenAI's payloads have never been observed to report how many resets an
#   account has banked, so this script prefers a live figure when a row
#   carries one and otherwise falls back to a month watermark at
#   `~/.claude/quotas/codex-reset.json`:
#
#     {"schema_version":"1.0","month":"2026-09","used_on":"2026-09-07", …}
#
#   A watermark whose `month` is the current ET month means the free reset is
#   spent. Any other month, or no file at all, means one is available. The
#   read FAILS SOFT: a missing, unreadable, or malformed file degrades to "one
#   free reset assumed" with `figure_source: "assumed"` — never to an error,
#   and never to a silent "you have already paid", which would push the hint
#   toward a $90 purchase on the strength of a corrupt file.
#
# CONFIGURATION (pm-config.md `## Budget`; env override wins; --threshold wins over both)
#   quotas_cheapest_next_threshold_pct   CLAUDE_QUOTAS_CHEAPEST_NEXT_THRESHOLD_PCT   20
#
# ENVIRONMENT (test seams; the defaults are what you want)
#   CLAUDE_QUOTAS_STATE_DIR   Directory holding codex-reset.json
#                             (default ~/.claude/quotas).
#   CLAUDE_QUOTAS_PM_CONFIG   Path to the pm-config.md whose `## Budget`
#                             section supplies the threshold knob. Set, it is
#                             used directly and the repo lookup is skipped —
#                             the only way to exercise the config-file rung of
#                             the cascade without reading this repo's own
#                             pm-config.md.
#   AI_QUOTAS_NOW             Epoch seconds to treat as "now" when deciding
#                             which ET month it is, so a suite's assertions do
#                             not turn over at midnight on the 1st.
#
# EXIT STATUS
#   0   A document was written (or the watermark was recorded).
#   3   Usage error — unknown flag, a bad --threshold, a bad date.
#   5   The tool cannot run: `jq` missing, stdin was not a JSON array, or the
#       watermark could not be written.
#   70  --help header extraction produced no output (internal defect).
#
# DEPENDENCIES
#   bash 3.2+, jq
#   .claude/scripts/pm-config-get.sh and repo-root.sh for the config knob —
#   both optional: absent, the knob falls back to env then to the default.
#
# SEE ALSO
#   ai-quotas.sh --help              the reader that produces the rows
#   .claude/reference/ai-quotas.md   the overage table in prose, with sources
#   .claude/skills/quotas/SKILL.md   the /quotas surface

set -uo pipefail

SELF_NAME="$(basename "$0")"
SELF_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Telemetry logs the script name and the action word only, never "$*" — the
# arguments can carry an account label, and script-usage.log is a long-lived
# plaintext file. Same reasoning as ai-quotas.sh.
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$SELF_NAME" "read" \
  2>/dev/null >> "${HOME:-/tmp}/.claude/script-usage.log" || true

print_help() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; n = 1; next } { exit } END { exit(n ? 0 : 1) }' "$0" ||
    { printf '%s: --help header extraction produced no output\n' "$0" >&2; exit 70; }
}

die_usage() {
  echo "${SELF_NAME}: $1" >&2
  echo "Run with --help for usage." >&2
  exit 3
}
die() { echo "${SELF_NAME}: $2" >&2; exit "$1"; }
warn() { echo "${SELF_NAME}: $1" >&2; }

# --- arg parsing -------------------------------------------------------------

MODE="annotate"
THRESHOLD_OVERRIDE=""
RECORD_DATE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) print_help; exit 0 ;;
    --threshold)
      [[ $# -ge 2 && -n "${2:-}" ]] || die_usage "--threshold requires a percentage"
      THRESHOLD_OVERRIDE="$2"; shift 2 ;;
    --threshold=*) THRESHOLD_OVERRIDE="${1#--threshold=}"
      [[ -n "$THRESHOLD_OVERRIDE" ]] || die_usage "--threshold requires a percentage"
      shift ;;
    --codex-reset-status) MODE="status"; shift ;;
    --record-codex-reset)
      MODE="record"; shift
      if [[ $# -ge 1 && "$1" != -* ]]; then RECORD_DATE="$1"; shift; fi ;;
    *) die_usage "unknown argument: $1" ;;
  esac
done

command -v jq >/dev/null 2>&1 || die 5 "'jq' not found on PATH"

PCT_RE='^(0|[1-9][0-9]?|100)$'
DEFAULT_THRESHOLD_PCT=20

if [[ -n "$THRESHOLD_OVERRIDE" && ! "$THRESHOLD_OVERRIDE" =~ $PCT_RE ]]; then
  die_usage "--threshold must be an integer 0-100 (got '${THRESHOLD_OVERRIDE}')"
fi

# --- configuration -----------------------------------------------------------
# Precedence: --threshold -> env override -> pm-config.md `## Budget` -> the
# built-in default. Same cascade and the same fail-soft handling as
# usage-horizon.sh: a typo in a config file is reported and replaced by the
# default, because a knob nobody can parse must not silently move a threshold.

BUDGET_SECTION=""
BUDGET_SECTION_LOADED=0

load_budget_section() {
  [[ $BUDGET_SECTION_LOADED -eq 1 ]] && return 0
  BUDGET_SECTION_LOADED=1
  local getter="$SELF_DIR/pm-config-get.sh"
  [[ -x "$getter" ]] || return 0
  # CLAUDE_QUOTAS_PM_CONFIG, when set, names the config file directly and the
  # repo lookup is skipped. Without it there is no way to exercise the
  # config-file rung of the cascade from a checkout: `repo-root.sh` resolves
  # from THIS script's directory, so it always finds the real pm-config.md,
  # and a suite asserting "the default is 20" would in fact be reading the
  # repo's own `= 20` — passing for the wrong reason, and going on passing if
  # the default ever changed underneath it.
  local config="${CLAUDE_QUOTAS_PM_CONFIG:-}"
  if [[ -z "$config" ]]; then
    local root=""
    if [[ -x "$SELF_DIR/repo-root.sh" ]]; then
      root="$("$SELF_DIR/repo-root.sh" 2>/dev/null)" || root=""
    fi
    [[ -n "$root" ]] || return 0
    config="$root/.claude/pm-config.md"
  fi
  [[ -r "$config" ]] || return 0
  BUDGET_SECTION="$("$getter" --section "Budget" --file "$config" 2>/dev/null)" || BUDGET_SECTION=""
  return 0
}

config_value() { # <ini_key>
  load_budget_section
  [[ -n "$BUDGET_SECTION" ]] || return 0
  printf '%s\n' "$BUDGET_SECTION" | awk -v key="$1" '
    {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      split(line, parts, /[=:]/)
      k = parts[1]
      sub(/[[:space:]]+$/, "", k)
      if (tolower(k) != tolower(key)) next
      sub(/^[^=:]*[=:][[:space:]]*/, "", line)
      sub(/[[:space:]]+#.*$/, "", line)
      sub(/[[:space:]]*$/, "", line)
      print line
      exit
    }'
}

resolve_threshold() {
  if [[ -n "$THRESHOLD_OVERRIDE" ]]; then printf '%s' "$THRESHOLD_OVERRIDE"; return 0; fi
  local val="${CLAUDE_QUOTAS_CHEAPEST_NEXT_THRESHOLD_PCT:-}"
  local origin="env CLAUDE_QUOTAS_CHEAPEST_NEXT_THRESHOLD_PCT"
  if [[ -z "$val" ]]; then
    val="$(config_value quotas_cheapest_next_threshold_pct)"
    origin="pm-config.md quotas_cheapest_next_threshold_pct"
  fi
  if [[ -z "$val" ]]; then printf '%s' "$DEFAULT_THRESHOLD_PCT"; return 0; fi
  if ! [[ "$val" =~ $PCT_RE ]]; then
    warn "invalid value '${val}' from ${origin}; using default ${DEFAULT_THRESHOLD_PCT}"
    printf '%s' "$DEFAULT_THRESHOLD_PCT"
    return 0
  fi
  printf '%s' "$val"
}

# --- the checked-in overage table --------------------------------------------
# Mirrored in prose, with the same dates, in .claude/reference/ai-quotas.md.
# `cost_rank` is what continuing costs ONCE THE INCLUDED QUOTA IS GONE, and it
# is an ordering, not a price: 2 = metered (you pay for the work you actually
# do), 3 = a flat fee for a fixed week you may not use. Included quota you
# have already paid for outranks both and is scored in the selector, not here.
#
# `~$90/reset` is OWNER-REPORTED (2026-09-07). OpenAI's help page documents
# the reset product and says prices vary by account, region, and plan; it
# publishes no figure, so neither does the source URL below. The label says
# `~` for exactly that reason.
OVERAGE_TABLE='{
  "claude": {
    "kind": "metered",
    "label": "API rate",
    "cost_rank": 2,
    "detail": "extra usage continues at standard API rates once usage credits are enabled; auto-reload lives in Console billing settings",
    "source": "https://support.claude.com/en/articles/11145838-using-claude-code-with-your-pro-or-max-plan",
    "last_verified": "2026-09-09"
  },
  "codex": {
    "kind": "reset",
    "label": "~$90/reset",
    "free_label": "1 free reset",
    "paid_label": "~$90/reset",
    "cost_rank": 3,
    "detail": "an instant reset restores the 5-hour and weekly allowances at once and starts a new weekly period on the next request; one free reset to start (plus any banked from referrals), then a paid one at ~$90 (owner-reported 2026-09-07 — OpenAI publishes no figure and says prices vary by account and region). Credits, bought from Settings > Usage, are the other lever",
    "source": "https://help.openai.com/en/articles/20001507-paid-weekly-work-and-codex-rate-limit-resets",
    "last_verified": "2026-09-09"
  },
  "cursor": {
    "kind": "metered",
    "label": "on-demand",
    "cost_rank": 2,
    "detail": "once the included monthly usage is spent, extra usage continues at the standard model API rates as pay-as-you-go",
    "source": "https://cursor.com/docs/account/pricing",
    "last_verified": "2026-09-09"
  }
}'

BASIS='Approximate: a Codex reset buys a fixed week at a flat price, while Claude and Cursor overage is metered per unit of work — the units do not convert. Ranked by what continuing costs you, not by dollars.'

# --- the Codex reset watermark -----------------------------------------------

STATE_DIR="${CLAUDE_QUOTAS_STATE_DIR:-${HOME:-/tmp}/.claude/quotas}"
RESET_FILE="$STATE_DIR/codex-reset.json"

# Which date(1) dialect is on PATH, asked ONCE — the same probe, for the same
# reason, as ai-quotas.sh: `-r` is not safe to try-and-fall-through, because
# GNU ACCEPTS `-r` and reads its argument as a FILENAME whose mtime to print.
# A file named for an epoch second almost never exists, so a fallthrough
# usually recovers; "usually" is the whole problem. Probing with a GNU-only
# form would be a coincidence of the same kind — it works only as long as BSD
# keeps rejecting it. Ask the tool what it is.
DATE_IS_GNU=0
if date --version 2>/dev/null | grep -qi 'GNU coreutils'; then
  DATE_IS_GNU=1
fi

# The ET month, so a watermark written on the 31st in Eastern time is not read
# as next month's by a UTC clock four hours ahead of it.
et_month() {
  local now="${AI_QUOTAS_NOW:-}"
  if [[ "$now" =~ ^[0-9]+$ ]]; then
    if [[ "$DATE_IS_GNU" -eq 1 ]]; then
      TZ='America/New_York' date -d "@$now" '+%Y-%m' 2>/dev/null && return 0
    else
      TZ='America/New_York' date -r "$now" '+%Y-%m' 2>/dev/null && return 0
    fi
  fi
  TZ='America/New_York' date '+%Y-%m'
}

et_today() {
  local now="${AI_QUOTAS_NOW:-}"
  if [[ "$now" =~ ^[0-9]+$ ]]; then
    if [[ "$DATE_IS_GNU" -eq 1 ]]; then
      TZ='America/New_York' date -d "@$now" '+%Y-%m-%d' 2>/dev/null && return 0
    else
      TZ='America/New_York' date -r "$now" '+%Y-%m-%d' 2>/dev/null && return 0
    fi
  fi
  TZ='America/New_York' date '+%Y-%m-%d'
}

# Result in globals, never through `$( )`: the caller needs BOTH the verdict
# and where it came from, and a subshell would drop one of them.
CODEX_FREE_RESET=1
CODEX_RESET_SOURCE="assumed"
CODEX_RESET_USED_ON=""

read_codex_watermark() {
  local month recorded
  month="$(et_month)"
  CODEX_FREE_RESET=1
  CODEX_RESET_SOURCE="assumed"
  CODEX_RESET_USED_ON=""
  [[ -r "$RESET_FILE" ]] || return 0
  # Fail soft, deliberately. A corrupt file must not read as "you already
  # spent this month's free reset": that is the reading that steers the hint
  # toward a paid reset, and it would be steering on a parse failure.
  recorded="$(jq -r 'if type == "object" and (.month | type == "string") then .month else empty end' \
    "$RESET_FILE" 2>/dev/null || true)"
  [[ -n "$recorded" ]] || { warn "the Codex reset watermark at ${RESET_FILE} is unreadable — assuming one free reset is available"; return 0; }
  CODEX_RESET_SOURCE="watermark"
  if [[ "$recorded" == "$month" ]]; then
    CODEX_FREE_RESET=0
    CODEX_RESET_USED_ON="$(jq -r '.used_on // empty' "$RESET_FILE" 2>/dev/null || true)"
  fi
  return 0
}

record_codex_reset() {
  local day="${1:-}" month tmp
  [[ -n "$day" ]] || day="$(et_today)"
  [[ "$day" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die_usage "--record-codex-reset takes a YYYY-MM-DD date (got '${day}')"
  month="${day%-*}"
  # Recording a month other than the current one is allowed — a reset used
  # last week and remembered late is the ordinary case — but it is SAID,
  # because the file that results will not affect this month's verdict at all.
  # Writing it silently would look like "the free reset is now marked spent"
  # while the next report goes on offering one.
  local now_month
  now_month="$(et_month)"
  if [[ "$month" != "$now_month" ]]; then
    warn "recording a reset for ${month}, which is not the current month (${now_month}) — this month's free reset stays available"
  fi
  mkdir -p "$STATE_DIR" 2>/dev/null || die 5 "could not create ${STATE_DIR}"
  tmp="${RESET_FILE}.tmp.$$"
  jq -nc --arg month "$month" --arg day "$day" --arg at "$(date -u +%FT%TZ)" \
    '{schema_version: "1.0", month: $month, used_on: $day, recorded_at: $at}' > "$tmp" 2>/dev/null \
    || { rm -f "$tmp"; die 5 "could not build the watermark record"; }
  mv "$tmp" "$RESET_FILE" 2>/dev/null || { rm -f "$tmp"; die 5 "could not write ${RESET_FILE}"; }
  echo "${SELF_NAME}: recorded a Codex reset used on ${day} (month ${month}) in ${RESET_FILE}"
  return 0
}

# --- modes -------------------------------------------------------------------

if [[ "$MODE" == "record" ]]; then
  record_codex_reset "$RECORD_DATE"
  exit 0
fi

read_codex_watermark

if [[ "$MODE" == "status" ]]; then
  jq -nc --arg month "$(et_month)" --arg src "$CODEX_RESET_SOURCE" \
    --arg used_on "$CODEX_RESET_USED_ON" --arg file "$RESET_FILE" \
    --argjson free "$CODEX_FREE_RESET" \
    '{month: $month,
      free_reset_available: ($free == 1),
      figure_source: $src,
      used_on: (if $used_on == "" then null else $used_on end),
      watermark_file: $file}'
  exit 0
fi

# --- annotate ----------------------------------------------------------------

THRESHOLD_PCT="$(resolve_threshold)"

TMP="$(mktemp -d)" || die 5 "could not create a temp directory"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

ROWS_IN="$TMP/rows.json"
cat > "$ROWS_IN"
if ! jq -e 'type == "array"' "$ROWS_IN" >/dev/null 2>&1; then
  die 5 "stdin was not a JSON array of rows"
fi

# The jq program lives in a FILE, not in a `$( )` capture: bash 3.2 — the
# fleet's primary shell — scans command substitutions by counting parens, and
# this program is full of them (see the same note in ai-quotas.sh's emit_row).
PROG="$TMP/select.jq"
cat > "$PROG" <<'JQ'
# ---- helpers ----------------------------------------------------------------
def as_number: if type == "number" and (isnan | not) and (isinfinite | not) then . else null end;

# Reads a field that may legitimately be absent, a string, or junk, and gives
# back a number or null. Never a 0: a fabricated zero here would read as "no
# resets left" or "nothing spent", both of which move the verdict.
def field($row; $key):
  ($row[$key]? // null)
  | if type == "number" then as_number
    elif type == "string" and (test("^-?[0-9]+(\\.[0-9]+)?$")) then (tonumber | as_number)
    else null end;

def pct_text: if . == null then "?" elif . == (. | floor) then (. | floor | tostring) else (. | tostring) end;

# Money reads as money: two fractional digits when there are cents, none when
# there are not. A bare `tostring` on the rounded number prints `$100.7` for
# ten dollars seventy — which is not a price anyone writes, and in a column of
# figures reads as a truncation.
def usd_text:
  if . == null then "?"
  else (. * 100 | round) as $cents
    | ($cents / 100 | floor) as $dollars
    | ($cents - $dollars * 100) as $rem
    | if $rem == 0 then "$\($dollars)"
      else "$\($dollars).\(if $rem < 10 then "0" else "" end)\($rem)" end
  end;

# The window as a person says it. The row's `7-day` is a duration; "weekly" is
# what the owner calls it, and the hint is prose, not a field dump.
def window_phrase:
  if . == "7-day" then "weekly"
  elif . == "billing-cycle" then "monthly"
  elif . == null or . == "" then "window"
  else . end;

# ---- per-row overage --------------------------------------------------------
def overage_for($row):
  ($table[$row.provider? // ""] // null) as $t
  | if $t == null then null
    elif ($row.provider? // "") == "codex" then
      (field($row; "free_resets_remaining")) as $live
      | (if $live != null then ($live | floor) else null end) as $live_n
      | (if $live_n != null then $live_n
         elif $ctx.codex_free_reset then 1
         else 0 end) as $free
      | (if $live_n != null then "live" else $ctx.codex_reset_source end) as $src
      | $t
        + {label: (if $free >= 1
                   then (if $free == 1 then $t.free_label else "\($free) free resets" end)
                   else $t.paid_label end),
           # The table's own wording, kept beside the rendered one. The column
           # shows the live label ("2 free resets", "on-demand $1007.50 of
           # $1000"); the hint's prose reads better with the generic term, and
           # a reader comparing the two can see which number is live.
           base_label: $t.label,
           free_resets_remaining: $free,
           credits_remaining_usd: (field($row; "credits_remaining_usd")),
           figure_source: $src}
    elif ($row.provider? // "") == "cursor" then
      (field($row; "spend_limit_used_usd")) as $used
      | (field($row; "spend_limit_usd")) as $limit
      | if $used != null and $limit != null then
          $t + {label: "on-demand \($used | usd_text) of \($limit | usd_text)",
                base_label: $t.label,
                spend_limit_used_usd: $used,
                spend_limit_usd: $limit,
                figure_source: "live"}
        else $t + {base_label: $t.label, figure_source: "table"} end
    else $t + {base_label: $t.label, figure_source: "table"} end;

# ---- annotate every row -----------------------------------------------------
[ .[] | . + {overage: overage_for(.)} ] as $rows

# ---- candidates -------------------------------------------------------------
# A candidate needs a readable remaining figure and a successful read: a row
# that says `needs-login` carries no number to rank, and recommending an
# account nobody can log in to is worse than saying nothing.
| [ $rows | to_entries[]
    | .key as $idx | .value as $r
    | ($r.remaining_pct | as_number) as $rem
    | select($rem != null and ($r.status? // "") == "ok")
    | {idx: $idx, row: $r, remaining: $rem}
  ] as $readable

# Triggering and ranking are DIFFERENT populations, deliberately.
#
# Anything readable can trigger: an account running low is worth a hint even
# when this script has no prices for that provider. But only a PRICED row can
# be recommended — ranking an unpriced one against a priced one is comparing
# a number to an absence, and the reason line would go on to assert a cost
# model ("continues at …, metered per unit of work") that nothing here
# established. An unknown price is a reason to name someone else, or to say
# nothing at all; it is never a reason to guess cheap.
| [ $readable[] | select((.row.overage? // null) != null) ] as $cands

# The TRIGGER: at least one readable row at or below the threshold. Inclusive
# on purpose — an account sitting exactly on the line is the case the hint
# exists for, and a strict comparison would stay silent there.
| ([ $readable[] | select(.remaining <= $ctx.threshold_pct) ] | length > 0) as $fired

| (if ($fired | not) or ($cands | length == 0) then null
   else
     [ $cands[]
       | . as $c
       | ($c.row.overage // null) as $ov
       | (($ov.free_resets_remaining? // 0) >= 1) as $has_free_reset
       # Tier 0 — included quota you have already paid for. Tier 1 — a banked
       # free reset: no money, but it spends the one you have. Tiers 2/3 come
       # from the table: metered before flat-fee, because metered money buys
       # exactly the work you do while a flat fee buys a week you may not use.
       | (if $c.remaining > $ctx.threshold_pct then 0
          elif $has_free_reset then 1
          else ($ov.cost_rank? // 9) end) as $tier
       | $c + {tier: $tier, has_free_reset: $has_free_reset, overage: $ov}
     ]
     | sort_by([.tier, (0 - .remaining), .idx])
     | first
     | . as $w
     | ($w.row.window | window_phrase) as $phrase
     | ($w.remaining | pct_text) as $rem_text
     # Every reason opens with the SAME measured figure the table shows. The
     # earlier draft wrote "no quota left" for the banked-reset tier, which
     # was true only when the winner happened to be at zero — with a raised
     # threshold it said "no quota left" about an account with 60 % of its
     # week untouched. The tiers order the choice; they do not describe it.
     | (if $w.tier <= 1 then
          "\($rem_text) % \($phrase) left"
          + (if $w.has_free_reset then ", \($w.overage.free_resets_remaining) free reset\(if $w.overage.free_resets_remaining == 1 then "" else "s" end) this month" else "" end)
        elif ($w.overage.kind? // "") == "reset" then
          "\($rem_text) % \($phrase) left; the next reset costs \($w.overage.paid_label // $w.overage.base_label // $w.overage.label)"
        else
          "\($rem_text) % \($phrase) left; continues at \($w.overage.base_label // $w.overage.label // "the provider's overage rate"), metered per unit of work"
        end) as $reason
     | {label: ($w.row.reported_email // $w.row.label),
        registered_label: $w.row.label,
        provider: $w.row.provider,
        window: $w.row.window,
        pool: ($w.row.pool // null),
        remaining_pct: $w.remaining,
        reason: $reason,
        basis: $ctx.basis,
        overage: $w.overage}
   end) as $cheapest

| {schema_version: "1.0",
   threshold_pct: $ctx.threshold_pct,
   basis: $ctx.basis,
   rows: $rows,
   cheapest_next: $cheapest}
JQ

CTX="$(jq -nc --argjson threshold "$THRESHOLD_PCT" \
  --argjson free "$CODEX_FREE_RESET" --arg src "$CODEX_RESET_SOURCE" --arg basis "$BASIS" \
  '{threshold_pct: $threshold, codex_free_reset: ($free == 1), codex_reset_source: $src, basis: $basis}')" \
  || die 5 "could not build the selection context"

OUT="$TMP/out.json"
: > "$OUT"
jq --argjson table "$OVERAGE_TABLE" --argjson ctx "$CTX" -f "$PROG" "$ROWS_IN" > "$OUT" 2>"$TMP/jq.err"
# Checked, not assumed. A jq program that failed to build the document would
# otherwise leave an empty stdout that the caller reads as "no rows and no
# hint" — the report saying "nothing to suggest" when it means "I could not
# compute anything", which is the one thing an advisory surface must not do.
if [[ ! -s "$OUT" ]]; then
  die 5 "could not build the overage document$(sed -n '1p' "$TMP/jq.err" 2>/dev/null | sed 's/^/: /')"
fi
cat "$OUT"
exit 0
