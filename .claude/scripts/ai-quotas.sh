#!/usr/bin/env bash
# ai-quotas.sh — report each registered AI account's remaining allowance
# (issue #1667).
# catalog: token-measurement — Read every account registered by `/quotas-setup` and print one row per usage window — used %, remaining %, reset time in Eastern, and a countdown — for `claude` (Anthropic OAuth usage endpoint), `codex` (`codex app-server`, HTTP fallback), and `cursor` (the dashboard's own usage response, read through a saved browser session); display only, never a dispatch or spend gate
#
# PURPOSE
#   The owner runs several premium AI subscriptions side by side and drains
#   them in rotation. The question that decides which one to use next is
#   "which accounts have room left this week, and when does each one come
#   back". This script answers exactly that, for every account
#   `/quotas-setup` registered, in one table.
#
#   DISPLAY ONLY. Nothing here may gate dispatch, pause work, downgrade a
#   model, or feed `credit-budget.sh`. It writes no state file: not
#   `session-state.json`, not `credit-budget.sh`'s inputs
#   (`~/.claude/usage-limit-events.jsonl`, `~/.claude/usage-limit-last.json`,
#   the `credit_budget` state key), not any dispatch gate. Quota and spend
#   authority stays where `.claude/rules/safety.md` §"Anthropic Quota & Spend
#   Authority" puts it: Anthropic's own in-app UI and upstream harness
#   signals. The earlier `/quota` skill was rolled back in issue #499 for
#   gating agent decisions on locally-read numbers; this one reports and
#   stops.
#
#   NO CREDENTIAL VALUE IS EVER PRINTED OR LOGGED. Each account's live token
#   is borrowed in place for the one request that needs it, passed to `curl`
#   through a config on stdin rather than on the command line (so it never
#   reaches `ps`), and never echoed, written to a log, or copied into the
#   output at any verbosity.
#
# USAGE
#   ai-quotas.sh [--json] [--five-hour] [--account <label>]
#   ai-quotas.sh --help | -h
#
#   --json         Emit one JSON object per row instead of the table.
#   --five-hour    Add each account's five-hour window, which arrives in the
#                  same payload as the weekly one. Weekly rows are the
#                  default because the weekly cap is what the switching
#                  decision turns on.
#   --account <label>
#                  Restrict the run to accounts registered under <label>.
#
# WHAT IT READS
#   Accounts        ~/.claude/ai-quotas.json, written by ai-quotas-setup.sh.
#                   Schema and profile layout: .claude/reference/ai-quotas.md.
#   claude          The account's live OAuth access token — macOS Keychain
#                   item named by the registry's `credential_ref.service`, or
#                   `<profile_dir>/.credentials.json` elsewhere — then
#                   GET https://api.anthropic.com/api/oauth/usage with
#                   `anthropic-beta: oauth-2025-04-20` and a
#                   `User-Agent: claude-code/<version>` header. The
#                   User-Agent is REQUIRED: without it the endpoint answers
#                   429 indefinitely, which reads as a rate limit and is
#                   really a missing header.
#   codex           `codex app-server` under that account's CODEX_HOME,
#                   JSON-RPC `account/rateLimits/read`. Falls back to
#                   GET https://chatgpt.com/backend-api/wham/usage with the
#                   `auth.json` bearer and `ChatGPT-Account-Id` header only
#                   when app-server is unavailable, and says which path a row
#                   came from.
#   cursor          A saved browser session, not a token: Cursor exposes no
#                   individual usage API. `lib/ai-quotas-cursor.js` drives a
#                   headless Playwright browser on that account's persistent
#                   profile directory, loads the dashboard's Spending tab, and
#                   reads the response the page itself requests —
#                   POST https://cursor.com/api/dashboard/get-current-period-usage,
#                   an endpoint CAPTURED from the live dashboard on
#                   2026-09-08, not guessed. Two rows come back per account,
#                   `cursor-models` and `other-models`. No cookie or session
#                   value ever leaves the profile directory.
#
# WINDOW SELECTION
#   The weekly Codex window is chosen by `windowDurationMins == 10080`,
#   never by position. On a Pro account the weekly figures arrive in
#   `primary` with `secondary` null; on others they arrive in `secondary`.
#   Reading position instead of duration reports the wrong window on half
#   the plans, and it looks exactly like a right answer.
#
# OVERAGE AND THE CHEAPEST-NEXT HINT (#1669)
#   Every row also carries what continuing PAST that cap costs — `1 free
#   reset`, `~$90/reset`, `API rate`, `on-demand $1007.50 of $1000` — and when
#   at least one account is at or below the remaining threshold (default 20 %)
#   the table ends with `Cheapest to continue on: <label> (<reason>)`. Both
#   come from quotas-cheapest-next.sh, which owns the checked-in price table,
#   the threshold knob, and the Codex reset watermark; run it with --help for
#   those. Absent or broken, this script says DEGRADED once and reports
#   without prices or a hint — it never guesses at one.
#
#   INFORMATIONAL ONLY, like everything else here. The hint never switches an
#   account, never purchases anything, and never gates dispatch.
#
# OUTPUT
#   stdout: the table (default) or a JSON OBJECT (--json). Each JSON row
#           carries provider, label, reported_email, window, used_pct,
#           remaining_pct, resets_at_epoch, resets_at_et, status, plus
#           detail, source, plan, pool, used_usd, included_usd,
#           plan_used_usd, plan_included_usd, spend_limit_used_usd,
#           spend_limit_usd, and overage. All but the first nine are `null` on
#           providers that have no such notion, so the shape never varies.
#           The table's third column shows the POOL where a provider has
#           pools and the window otherwise.
#
#           `--json` emits {"schema_version","threshold_pct","basis","rows",
#           "cheapest_next"} — an object, NOT the bare array increments
#           #1667/#1668 emitted. `cheapest_next` is a top-level property of
#           the whole report rather than of any one row, so an array had
#           nowhere to put it; `schema_version` is there so a consumer can
#           tell the two apart instead of inferring it from the JSON type.
#           The "no accounts" and "no account matched" exits emit the same
#           object with an empty `rows`, never a bare `[]`.
#   stderr: one-line per-account diagnostics.
#
#   Statuses are per row, and one failing account never stops the others:
#     ok            figures were read
#     needs-login   no usable credential or saved session — the exact
#                   `/quotas-setup relogin` command is in the row's note
#     rate-limited  the provider answered 429; the retry window is in the note
#     unreachable   network failure, a missing driver, or a response this
#                   reader did not recognise (its top-level keys are printed
#                   rather than a silent 0 %)
#     unreadable    the response arrived but its shape changed; the note names
#                   the keys actually seen. Never a figure, never 0 %.
#     unsupported   a provider this reader does not know
#
# ENVIRONMENT (overrides; the defaults are what you want)
#   AI_QUOTAS_CONFIG          Account registry path.
#   AI_QUOTAS_CURL_BIN        Path to curl.
#   AI_QUOTAS_SECURITY_BIN    Path to macOS security(1).
#   AI_QUOTAS_CLAUDE_BIN      Path to the `claude` CLI (User-Agent version).
#   AI_QUOTAS_CODEX_BIN       Path to the `codex` CLI.
#   AI_QUOTAS_CLAUDE_VERSION  User-Agent version, skipping the CLI probe.
#   AI_QUOTAS_PLATFORM        Platform name (default `uname -s`); `Darwin`
#                             selects the Keychain credential path.
#   AI_QUOTAS_ANTHROPIC_URL   Claude usage endpoint.
#   AI_QUOTAS_CHATGPT_URL     Codex HTTP fallback endpoint.
#   AI_QUOTAS_HTTP_TIMEOUT    Per-request wall-clock bound, seconds (15).
#   AI_QUOTAS_CHEAPEST_BIN    Path to quotas-cheapest-next.sh. Used
#                             EXCLUSIVELY when set — a value that is not
#                             executable degrades the run to "no prices, no
#                             hint" rather than falling back to a search,
#                             which is what makes the unavailable-helper path
#                             testable from inside a checkout.
#   AI_QUOTAS_NODE_BIN        Path to node (the cursor helper's runtime).
#   AI_QUOTAS_CURSOR_HELPER   Path to lib/ai-quotas-cursor.js.
#   AI_QUOTAS_CURSOR_TIMEOUT  Cursor browser-read bound, seconds (30). The
#                             helper's own bound is set a few seconds shorter
#                             so it can print its verdict before this one
#                             elapses; a value under 8 raises this bound
#                             rather than shrinking the helper's below 5s.
#   AI_QUOTAS_CODEX_TIMEOUT   app-server response bound, seconds (20).
#                             Both must be a positive integer with no leading
#                             zero. Anything else is refused on stderr and the
#                             default is used, because a value arithmetic
#                             cannot read makes the bound it governs elapse
#                             instantly and report itself as a timeout.
#   AI_QUOTAS_NOW             Epoch seconds to treat as "now" (countdowns, and
#                             the ET month the reset watermark is read
#                             against).
#   Every one of these exists so .claude/scripts/tests/ai-quotas.test.sh can
#   drive each path against stubs without a live account, network, or
#   keychain. They are not meant for normal use.
#
# EXIT STATUS
#   0   The report was produced. A `needs-login`, `rate-limited`,
#       `unreachable`, `unreadable`, or `unsupported` ROW is not a failure: this is a
#       report, never a gate, so it must not be read as a verdict about
#       whether work may proceed.
#   3   Usage error — unknown flag, or --account without a label.
#   5   The tool cannot run: `jq` missing, or the registry is unreadable,
#       unparseable, or written by a different schema major.
#   70  --help header extraction produced no output (internal defect).
#
# DEPENDENCIES
#   - bash 3.2+, jq, curl
#   - macOS security(1) for the Keychain credential path
#   - the `codex` CLI for the preferred Codex path (the HTTP fallback needs
#     only curl)
#   - Node 20+ and Playwright for the Cursor path — `.claude/scripts/lib`
#     pins the version; install with
#     `npm install --prefix .claude/scripts/lib` then
#     `npx --prefix .claude/scripts/lib playwright install chromium`.
#     Absent, cursor rows read `unreachable` naming that command; every other
#     account still reports.
#   - .claude/scripts/lib/bounded-run.sh (sibling library) for the local CLI
#     probes, which must not hang the report
#
# SEE ALSO
#   .claude/reference/ai-quotas.md      registry schema, reader contract, the
#                                       overage table with its sources
#   .claude/skills/quotas/SKILL.md      the /quotas surface
#   ai-quotas-setup.sh --help           registering and re-logging in accounts
#   quotas-cheapest-next.sh --help      the overage prices, the threshold
#                                       knob, and the Codex reset watermark

set -uo pipefail

SELF_NAME="$(basename "$0")"
SELF_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Telemetry logs the script name and the ACTION WORD ONLY, never "$*": the
# arguments carry an account label — the owner's subscription email — and
# script-usage.log is a long-lived plaintext file. Same reasoning as
# ai-quotas-setup.sh.
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$SELF_NAME" "read" \
  2>/dev/null >> "${HOME:-/tmp}/.claude/script-usage.log" || true

# --- help --------------------------------------------------------------------

print_help() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; n = 1; next } { exit } END { exit(n ? 0 : 1) }' "$0" ||
    { printf '%s: --help header extraction produced no output\n' "$0" >&2; exit 70; }
}

die_usage() {
  echo "${SELF_NAME}: $1" >&2
  echo "Run with --help for usage." >&2
  exit 3
}

die() { # <exit-code> <message>
  echo "${SELF_NAME}: $2" >&2
  exit "$1"
}

warn() { echo "${SELF_NAME}: $1" >&2; }

# --- arg parsing -------------------------------------------------------------

JSON=0
FIVE_HOUR=0
ACCOUNT_FILTER=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) print_help; exit 0 ;;
    --json) JSON=1; shift ;;
    --five-hour) FIVE_HOUR=1; shift ;;
    --account)
      [[ $# -ge 2 && -n "${2:-}" ]] || die_usage "--account requires a label"
      ACCOUNT_FILTER="$2"; shift 2 ;;
    --account=*) ACCOUNT_FILTER="${1#--account=}"
      [[ -n "$ACCOUNT_FILTER" ]] || die_usage "--account requires a label"
      shift ;;
    *) die_usage "unknown argument: $1" ;;
  esac
done

# --- defaults ----------------------------------------------------------------

_HOME="${HOME:-}"
if [[ -z "$_HOME" && -z "${AI_QUOTAS_CONFIG:-}" ]]; then
  die 5 "HOME is unset — set it, or pass AI_QUOTAS_CONFIG"
fi

CONFIG_FILE="${AI_QUOTAS_CONFIG:-${_HOME}/.claude/ai-quotas.json}"
PLATFORM="${AI_QUOTAS_PLATFORM:-$(uname -s 2>/dev/null || echo unknown)}"
SECURITY_BIN="${AI_QUOTAS_SECURITY_BIN:-security}"
CURL_BIN="${AI_QUOTAS_CURL_BIN:-curl}"
ANTHROPIC_URL="${AI_QUOTAS_ANTHROPIC_URL:-https://api.anthropic.com/api/oauth/usage}"
CHATGPT_URL="${AI_QUOTAS_CHATGPT_URL:-https://chatgpt.com/backend-api/wham/usage}"
# Both timeouts end up in arithmetic (`[[ -lt ]]`) or in curl's --max-time, and
# an unusable value fails in a way that looks like the thing it bounds: `abc`
# evaluates to 0 in arithmetic context, so the app-server loop never runs a
# single pass and the row reports "did not answer within abcs" — a silent
# degradation to the HTTP fallback, wearing a timeout's clothes. `08` is worse
# still: arithmetic reads a leading zero as octal, `8` is not an octal digit,
# and bash prints its own error. Neither is a real timeout, so refuse the value
# and say so rather than bounding the wait with it.
positive_int_or_default() { # <value> <default> <env-var-name>
  case "$1" in
    "" | *[!0-9]*) ;;   # empty, or not all digits
    0*) ;;              # leading zero: 0 and 00 are not positive, 08 is not octal
    *) printf '%s' "$1"; return 0 ;;   # all digits, starts 1-9, so >= 1
  esac
  warn "$3='$1' is not a positive integer number of seconds — using ${2}s"
  printf '%s' "$2"
}
HTTP_TIMEOUT="$(positive_int_or_default "${AI_QUOTAS_HTTP_TIMEOUT:-15}" 15 AI_QUOTAS_HTTP_TIMEOUT)"
CODEX_TIMEOUT="$(positive_int_or_default "${AI_QUOTAS_CODEX_TIMEOUT:-20}" 20 AI_QUOTAS_CODEX_TIMEOUT)"
# A headless browser start plus a dashboard load is slower than an HTTP call
# and slower than app-server; 30s leaves room for a cold profile without
# letting one Cursor account hold the whole report open.
CURSOR_TIMEOUT="$(positive_int_or_default "${AI_QUOTAS_CURSOR_TIMEOUT:-30}" 30 AI_QUOTAS_CURSOR_TIMEOUT)"
SCHEMA_MAJOR="1"
# Last-resort User-Agent version, used only when the `claude` CLI cannot be
# found AND AI_QUOTAS_CLAUDE_VERSION is unset. The endpoint rejects a request
# with no plausible claude-code User-Agent (persistent 429), so sending
# nothing is worse than sending a stale number — and when a 429 does come
# back on this fallback, the row's note names the unresolved version as the
# first thing to check.
CLAUDE_UA_FALLBACK="0.0.0"

command -v jq >/dev/null 2>&1 || die 5 "'jq' not found on PATH"

TMP="$(mktemp -d)" || die 5 "could not create a temp directory"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT
ROWS="$TMP/rows.jsonl"
: > "$ROWS"

# The two local CLI probes below (`claude --version`, `codex login status`)
# are cheap in I/O terms and still unbounded in wall-clock terms, which is
# exactly the shape issue #1363 was about. Sourcing the shared bound is not
# fatal if it is missing — the report degrades to unbounded probes and says
# so once — because a missing sibling library must not turn a read-only
# report into an error.
BOUNDED=0
if [[ -r "$SELF_DIR/lib/bounded-run.sh" ]]; then
  # shellcheck source=./lib/bounded-run.sh
  if source "$SELF_DIR/lib/bounded-run.sh" 2>/dev/null; then
    BOUNDED=1
    CAPTURE="$TMP/bounded.out"
    CAPTURE_ERR="$TMP/bounded.err"
  fi
fi
if [[ "$BOUNDED" -eq 0 ]]; then
  warn "DEGRADED: lib/bounded-run.sh unavailable — local CLI probes run without a wall-clock bound"
fi

# Runs a local CLI probe with a bound when one is available. stdout of the
# probe lands in PROBE_OUT; the return value is the probe's own status.
PROBE_OUT=""
probe() { # <secs> <command> [args…]
  local secs="$1"; shift
  local rc=0
  PROBE_OUT=""
  if [[ "$BOUNDED" -eq 1 ]]; then
    # Never inside $( ): a subshell would discard BOUNDED_TIMED_OUT and the
    # capture handover along with it.
    run_bounded "$secs" "$@" || rc=$?
    PROBE_OUT="$(cat "$CAPTURE" 2>/dev/null || true)"
  else
    PROBE_OUT="$("$@" 2>/dev/null)" || rc=$?
  fi
  return "$rc"
}

# --- registry ----------------------------------------------------------------

# The result comes back in a GLOBAL, and the function is called bare — never
# through `$(…)`. Command substitution runs it in a subshell, where every
# `die 5` below exits that subshell only: the parent would carry on with an
# empty config, count zero accounts, and print "No accounts registered yet"
# with exit 0. A refusal that reports success is worse than no check at all.
CONFIG=""

read_config() {
  CONFIG=""
  if [[ ! -e "$CONFIG_FILE" ]]; then
    CONFIG='{"schema_version":"1.0","accounts":[]}'
    return 0
  fi
  [[ -r "$CONFIG_FILE" ]] || die 5 "registry not readable: $CONFIG_FILE"
  local raw
  raw="$(cat "$CONFIG_FILE")" || die 5 "could not read registry: $CONFIG_FILE"
  # Structural check only, and deliberately the same shape ai-quotas-setup.sh
  # enforces on write: a row whose profile_dir reads back as the string
  # "null" would be handed to CODEX_HOME and to the Keychain lookup, and the
  # report would blame the account for a broken config.
  printf '%s' "$raw" | jq -e '
      type == "object"
      and (.accounts | type == "array")
      and (.accounts | all(
            type == "object"
            and (.provider    | type == "string" and length > 0)
            and (.label       | type == "string" and length > 0)
            and (.profile_dir | type == "string" and length > 0)
            # credential_ref is optional, but when present it must be the
            # object the Keychain lookup indexes. A string here makes that
            # lookup a jq type error, the service reads back empty, and the row
            # says `needs-login` — blaming the ACCOUNT for a broken REGISTRY,
            # which is the exact confusion the checks above exist to prevent.
            and ((.credential_ref | type) as $t
                 | $t == "null"
                   or ($t == "object"
                       and (.credential_ref.service
                            | . == null or (type == "string" and length > 0))))))' >/dev/null 2>&1 \
    || die 5 "registry is not valid ai-quotas JSON — every account needs a non-empty string provider, label, and profile_dir, and any credential_ref must be an object whose service (if present) is a non-empty string: $CONFIG_FILE"
  local found_major
  found_major="$(printf '%s' "$raw" | jq -r '(.schema_version // "1.0") | tostring | split(".")[0]')"
  if [[ "$found_major" != "$SCHEMA_MAJOR" ]]; then
    die 5 "registry schema_version is v${found_major}.x but this reader understands v${SCHEMA_MAJOR}.x — refusing to guess at $CONFIG_FILE"
  fi
  CONFIG="$raw"
}

# --- time --------------------------------------------------------------------

# The override is validated, not trusted: a non-numeric AI_QUOTAS_NOW would
# reach `(( e - NOW ))`, where bash errors and the arithmetic yields 0 — so
# every reset would read as already elapsed and every row would say `reset`.
# A bad override falls back to the real clock and says so once.
#
# NAMED `report_now_epoch`, NOT `now_epoch`. lib/bounded-run.sh — sourced
# above — exports its own `now_epoch`, and a function defined here after the
# source silently REPLACES it for the rest of the run. That is not a style
# point: bounded-run.sh reads the clock twice to decide whether a child has
# run past its bound, so a frozen AI_QUOTAS_NOW would make both reads equal,
# `now - start` permanently 0, and EVERY wall-clock bound in this script
# vanish — under the test suite, which is exactly where the bounds are
# asserted. A collision between a sourced library and its caller has no
# symptom until the day something hangs.
report_now_epoch() {
  if [[ -n "${AI_QUOTAS_NOW:-}" ]]; then
    if [[ "$AI_QUOTAS_NOW" =~ ^[0-9]+$ ]]; then printf '%s' "$AI_QUOTAS_NOW"; return 0; fi
    warn "ignoring AI_QUOTAS_NOW='${AI_QUOTAS_NOW}' — not epoch seconds; using the real clock"
  fi
  date -u +%s
}

NOW="$(report_now_epoch)"
# The clock is load-bearing for every countdown; without it the reader would
# quietly report `reset` for everything.
[[ "$NOW" =~ ^[0-9]+$ ]] || die 5 "could not read the current time from date(1)"

# Which date(1) dialect is on PATH, decided ONCE rather than by trying one
# form and falling through when it fails. Falling through is safe for the
# BSD-only `-j -f`, which GNU simply rejects — but it is NOT safe for `-r`:
# GNU accepts `-r` and reads its argument as a FILENAME whose mtime to print.
# A file named for the epoch second almost never exists, so the fallback
# usually saves it; "usually" is the whole problem, because the day one does
# exist the reset column silently shows that file's timestamp. Asking the
# tool which dialect it is removes the coincidence from the answer.
DATE_IS_GNU=0
if date --version 2>/dev/null | grep -qi 'GNU coreutils'; then
  DATE_IS_GNU=1
fi

# ISO-8601 (…Z or with an offset) → epoch seconds. Empty output means "not
# parseable", which callers render as `-` rather than as a reset that has
# already happened.
iso_to_epoch() { # <iso>
  local iso="$1" trimmed
  [[ -n "$iso" ]] || return 0
  # Drop fractional seconds and normalise the zone so either date(1) dialect
  # sees a shape it accepts.
  trimmed="$(printf '%s' "$iso" | sed -e 's/\.[0-9][0-9]*//' -e 's/+00:00$/Z/')"
  if [[ "$DATE_IS_GNU" -eq 1 ]]; then
    date -u -d "$trimmed" +%s 2>/dev/null || true
    return 0
  fi
  # BSD date needs the exact format, and GNU's `-d` accepts a numeric offset
  # (`…+05:00`) that the `…Z` format below cannot match. Without the second
  # attempt the SAME payload yields a reset time on Linux and a bare `-` on
  # macOS — the fleet's primary platform — which reads as "the provider
  # didn't say" rather than "this reader couldn't parse it". `%z` wants the
  # offset without its colon.
  date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$trimmed" +%s 2>/dev/null && return 0
  local offset_form
  offset_form="$(printf '%s' "$trimmed" | sed -e 's/\([+-][0-9][0-9]\):\([0-9][0-9]\)$/\1\2/')"
  date -u -j -f '%Y-%m-%dT%H:%M:%S%z' "$offset_form" +%s 2>/dev/null || true
}

epoch_to_et() { # <epoch>
  local e="${1:-}"
  [[ -n "$e" && "$e" != "null" ]] || return 0
  if [[ "$DATE_IS_GNU" -eq 1 ]]; then
    TZ='America/New_York' date -d "@$e" '+%a %b %-d %-I:%M %p %Z' 2>/dev/null || true
  else
    TZ='America/New_York' date -r "$e" '+%a %b %-d %-I:%M %p %Z' 2>/dev/null || true
  fi
}

# "in 2d 4h" / "in 4h 12m" / "in 37m" / "reset" once the moment has passed.
# A reset timestamp as either provider may report it — epoch seconds today,
# an ISO-8601 string if either payload ever changes shape — reduced to epoch
# seconds, or to nothing when it is neither.
to_epoch_maybe() { # <value>
  local v="${1:-}"
  [[ -n "$v" && "$v" != "null" ]] || return 0
  if [[ "$v" =~ ^[0-9]+$ ]]; then printf '%s' "$v"; return 0; fi
  iso_to_epoch "$v"
}

countdown() { # <epoch>
  local e="${1:-}" delta d h m
  [[ -n "$e" && "$e" != "null" ]] || return 0
  delta=$(( e - NOW ))
  if [[ "$delta" -le 0 ]]; then printf 'reset'; return 0; fi
  d=$(( delta / 86400 ))
  h=$(( (delta % 86400) / 3600 ))
  m=$(( (delta % 3600) / 60 ))
  if [[ "$d" -gt 0 ]]; then printf 'in %dd %dh' "$d" "$h"
  elif [[ "$h" -gt 0 ]]; then printf 'in %dh %dm' "$h" "$m"
  else printf 'in %dm' "$m"; fi
}

# --- row model ---------------------------------------------------------------
# One shape for every provider. #1668's cursor reader added its fields through
# the optional extra-JSON argument below rather than a second renderer, and
# #1669's overage column lands the same way.

# Every numeric conversion below is guarded. A bare `tonumber` on an
# unexpected value — a percentage that arrived as "64%", a reset that arrived
# as an ISO string — aborts jq, and an aborted jq writes NO ROW: the account
# would vanish from a report whose entire promise is that every account gets
# one. A value this reader cannot turn into a number becomes `null`, which
# the table renders as `-` and nobody mistakes for zero usage.
emit_row() { # <provider> <label> <email> <window> <used_pct|""> <resets_epoch|""> <status> <detail> <source> <plan> [<extra-json>]
  local used="${5:-}" resets="${6:-}"
  # Optional 11th argument: a JSON OBJECT merged over the base row, which is
  # how a provider adds a field without forking the renderer (the cursor pool
  # rows use it, and #1669's overage column will). Validated here rather than
  # trusted: a malformed value would abort jq, and an aborted jq writes no
  # row at all — the account would vanish from a report whose whole promise
  # is one row per account.
  local extra="{}"
  if [[ $# -ge 11 && -n "${11:-}" ]]; then
    if printf '%s' "${11}" | jq -e 'type == "object"' >/dev/null 2>&1; then
      extra="${11}"
    else
      warn "internal defect: ignoring a non-object extra field set on the $1 row for ${2}"
    fi
  fi
  # `account_label`, not `label`: `label` is a jq KEYWORD (`label $out | …`), and
  # while jq 1.7 accepts it after `$`, nothing in this repo pins a jq version —
  # the dependency list says "jq". A keyword-named binding is free to rename and
  # not worth betting every row on.
  #
  # The append is checked. Every provider path funnels through here, so a jq
  # program that fails to build a row would otherwise leave `$ROWS` empty and
  # the run would still exit 0 — an empty table, or `[]` under --json, reported
  # as a successful read. That is the report saying "no accounts" when it means
  # "I could not build a row", which is the one thing a display-only tool must
  # never do.
  #
  # Built into a file rather than a `$(…)` capture: bash 3.2 — the fleet's
  # primary shell — scans command substitutions by counting parens, and this jq
  # program is full of them.
  local rowf="$TMP/row.json"
  : > "$rowf"
  jq -nc \
    --arg provider "$1" --arg account_label "$2" --arg email "$3" --arg window "$4" \
    --arg used "$used" --arg resets "$resets" \
    --arg status "$7" --arg detail "${8:-}" --arg source "${9:-}" --arg plan "${10:-}" \
    --arg et "$(epoch_to_et "$resets")" --arg in "$(countdown "$resets")" \
    --argjson extra "$extra" \
    '{provider: $provider,
      label: $account_label,
      reported_email: (if $email == "" then $account_label else $email end),
      window: $window,
      used_pct: (if $used == "" then null else (try ($used | tonumber) catch null) end),
      remaining_pct: (if $used == "" then null
                      else ((try ($used | tonumber) catch null) | if . == null then null else 100 - . end) end),
      resets_at_epoch: (if $resets == "" then null else (try ($resets | tonumber) catch null) end),
      resets_at_et: (if $et == "" then null else $et end),
      countdown: (if $in == "" then null else $in end),
      status: $status,
      detail: $detail,
      source: (if $source == "" then null else $source end),
      plan: (if $plan == "" then null else $plan end),
      # Declared on EVERY row, null where the provider has no such notion, so
      # --json has one shape whatever produced it. A consumer forced to test
      # whether a key exists before reading it is a consumer that will
      # eventually read a partial row as a complete one.
      pool: null,
      used_usd: null,
      included_usd: null,
      plan_used_usd: null,
      plan_included_usd: null,
      # #1669. `overage` is filled in AFTER every row is built, by
      # quotas-cheapest-next.sh, because the price of continuing is a property
      # of the provider and the reset watermark rather than of this read — and
      # declaring it here means a run where that helper is unavailable still
      # emits the same keys, with `null` where the price would be. The two
      # spend-limit fields carry the Cursor on-demand block
      # (`spendLimitUsage`), and are null on every other provider.
      overage: null,
      spend_limit_used_usd: null,
      spend_limit_usd: null,
      # The two speculative Codex live figures. `codex_live_overage` DROPS a
      # key it could not read as a plain number, so without these defaults the
      # field would be present on some Codex rows and absent on every other
      # row — exactly the "test whether the key exists before reading it"
      # shape the note above exists to prevent.
      free_resets_remaining: null,
      credits_remaining_usd: null}
     + $extra' > "$rowf" 2>/dev/null
  if [[ ! -s "$rowf" ]]; then
    ROW_BUILD_FAILURES=$(( ROW_BUILD_FAILURES + 1 ))
    warn "internal defect: could not build the $1 row for ${2} — this account is missing from the report"
    return 1
  fi
  cat "$rowf" >> "$ROWS"
}

relogin_hint() { # <provider> <label>
  printf '/quotas-setup relogin %s %s' "$2" "$1"
}

# --- claude ------------------------------------------------------------------

# The token is borrowed into a variable and used for exactly one request. It
# is never echoed, never written to a log, and never passed on a command line
# — `curl` reads the Authorization header from a config on stdin, so it never
# reaches `ps`.
CLAUDE_TOKEN=""
CLAUDE_TOKEN_DETAIL=""

# Both results come back in globals rather than on stdout, so no caller can
# put a credential into a command substitution by accident.
claude_token_for() { # <profile_dir> <keychain_service|"">
  local dir="$1" service="$2" raw=""
  CLAUDE_TOKEN=""
  CLAUDE_TOKEN_DETAIL=""

  if [[ -s "$dir/.credentials.json" ]]; then
    raw="$(cat "$dir/.credentials.json" 2>/dev/null || true)"
  elif [[ "$PLATFORM" == "Darwin" ]]; then
    if [[ -z "$service" ]]; then
      CLAUDE_TOKEN_DETAIL="no keychain item recorded for this profile"
      return 1
    fi
    if ! command -v "$SECURITY_BIN" >/dev/null 2>&1; then
      CLAUDE_TOKEN_DETAIL="security(1) unavailable, cannot reach the keychain"
      return 1
    fi
    raw="$("$SECURITY_BIN" find-generic-password -s "$service" -w 2>/dev/null || true)"
    if [[ -z "$raw" ]]; then
      CLAUDE_TOKEN_DETAIL="recorded keychain item is gone or empty"
      return 1
    fi
  else
    CLAUDE_TOKEN_DETAIL="no .credentials.json in profile"
    return 1
  fi

  case "$raw" in
    '{'*)
      CLAUDE_TOKEN="$(printf '%s' "$raw" | jq -r '.claudeAiOauth.accessToken // .accessToken // empty' 2>/dev/null || true)"
      ;;
    *)
      # A bare string is the credential itself on installs that store it
      # unwrapped. Nothing is inspected beyond "is it non-empty".
      CLAUDE_TOKEN="$raw"
      ;;
  esac

  if [[ -z "$CLAUDE_TOKEN" ]]; then
    CLAUDE_TOKEN_DETAIL="credential store holds no OAuth access token"
    return 1
  fi
  return 0
}

claude_bin() {
  local override="${AI_QUOTAS_CLAUDE_BIN:-}" candidate
  if [[ -n "$override" ]]; then
    [[ -x "$override" ]] && { printf '%s' "$override"; return 0; }
    return 1
  fi
  if candidate="$(command -v claude 2>/dev/null)" && [[ -n "$candidate" ]]; then
    printf '%s' "$candidate"; return 0
  fi
  for candidate in "${_HOME}/.claude/local/claude" "/opt/homebrew/bin/claude" "/usr/local/bin/claude"; do
    [[ -x "$candidate" ]] && { printf '%s' "$candidate"; return 0; }
  done
  return 1
}

# The User-Agent is not cosmetic: without `claude-code/<version>` the usage
# endpoint answers 429 forever. Resolved once per run.
CLAUDE_VERSION=""
CLAUDE_VERSION_RESOLVED=0
resolve_claude_version() {
  if [[ -n "${AI_QUOTAS_CLAUDE_VERSION:-}" ]]; then
    CLAUDE_VERSION="$AI_QUOTAS_CLAUDE_VERSION"; CLAUDE_VERSION_RESOLVED=1; return 0
  fi
  local bin
  if bin="$(claude_bin)"; then
    if probe 10 "$bin" --version; then
      # `claude --version` prints e.g. "2.1.3 (Claude Code)"; take the first
      # version-shaped token rather than the whole line.
      CLAUDE_VERSION="$(printf '%s' "$PROBE_OUT" | tr ' ' '\n' | grep -E '^[0-9]+\.[0-9]+' | head -n 1)"
    fi
  fi
  if [[ -n "$CLAUDE_VERSION" ]]; then CLAUDE_VERSION_RESOLVED=1; else CLAUDE_VERSION="$CLAUDE_UA_FALLBACK"; fi
}

# Anthropic reports utilization as a percent. A FRACTIONAL value at or below
# 1 is a ratio and is scaled; an integer 1 stays 1 %, because an integer
# percent is never fractional. Anything else is passed through.
normalize_pct() { # <value>
  printf '%s' "${1:-}" | jq -r 'if . == null then ""
    elif (type == "number" and . <= 1 and . != (.|floor)) then (. * 100)
    else . end
    | if type == "number" then (. * 10 | round / 10) else . end' 2>/dev/null || true
}

claude_window_row() { # <label> <email> <body-file> <json-key> <window-label>
  local label="$1" email="$2" body="$3" key="$4" window="$5"
  local util resets_raw used resets
  util="$(jq -c --arg k "$key" '.[$k].utilization // empty' "$body" 2>/dev/null || true)"
  [[ -n "$util" ]] || return 1
  resets_raw="$(jq -r --arg k "$key" '.[$k].resets_at // empty' "$body" 2>/dev/null || true)"
  used="$(normalize_pct "$util")"
  resets="$(to_epoch_maybe "$resets_raw")"
  emit_row claude "$label" "$email" "$window" "$used" "$resets" ok "" "oauth-usage" ""
  return 0
}

read_claude_account() { # <label> <profile_dir> <keychain_service>
  local label="$1" dir="$2" service="$3"
  local body="$TMP/claude-body.json" hdrs="$TMP/claude-hdrs.txt"
  local code rc=0 email retry detail keys

  if ! claude_token_for "$dir" "$service"; then
    emit_row claude "$label" "" "7-day" "" "" needs-login \
      "$CLAUDE_TOKEN_DETAIL — run: $(relogin_hint claude "$label")" "" ""
    return 0
  fi

  : > "$body"; : > "$hdrs"
  # The Authorization header goes in on stdin, never in argv: a bearer token
  # in a command line is readable from `ps` by anything running as this user.
  code="$(printf 'header = "Authorization: Bearer %s"\n' "$CLAUDE_TOKEN" \
    | "$CURL_BIN" -sS --max-time "$HTTP_TIMEOUT" \
        -o "$body" -D "$hdrs" -w '%{http_code}' \
        -H "anthropic-beta: oauth-2025-04-20" \
        -H "User-Agent: claude-code/${CLAUDE_VERSION}" \
        -H "Accept: application/json" \
        -K - "$ANTHROPIC_URL" 2>/dev/null)" || rc=$?
  CLAUDE_TOKEN=""

  if [[ "$rc" -ne 0 || -z "$code" ]]; then
    emit_row claude "$label" "" "7-day" "" "" unreachable \
      "curl failed (exit ${rc:-?}) talking to ${ANTHROPIC_URL}" "oauth-usage" ""
    return 0
  fi

  if [[ "$code" == "429" ]]; then
    retry="$(grep -i '^retry-after:' "$hdrs" 2>/dev/null | head -n 1 | sed 's/^[^:]*:[[:space:]]*//' | tr -d '\r' || true)"
    detail="rate-limited by the usage endpoint"
    # Retry-After is either delta-seconds or an HTTP-date (RFC 9110 §10.2.3).
    # Appending "s" to a date produces "retry after Wed, 21 Oct 2026 …GMTs",
    # which is not a duration and not a date.
    if [[ "$retry" =~ ^[0-9]+$ ]]; then
      detail="rate-limited, retry after ${retry}s"
    elif [[ -n "$retry" ]]; then
      detail="rate-limited, retry after ${retry}"
    fi
    # The known cause of a PERSISTENT 429 is a missing or implausible
    # User-Agent, so an unresolved version is named here rather than left for
    # the reader to rediscover.
    [[ "$CLAUDE_VERSION_RESOLVED" -eq 1 ]] || \
      detail="$detail (User-Agent version unresolved — install the claude CLI or set AI_QUOTAS_CLAUDE_VERSION)"
    emit_row claude "$label" "" "7-day" "" "" rate-limited "$detail" "oauth-usage" ""
    return 0
  fi

  if [[ "$code" == "401" || "$code" == "403" ]]; then
    emit_row claude "$label" "" "7-day" "" "" needs-login \
      "the usage endpoint rejected this credential (HTTP ${code}) — run: $(relogin_hint claude "$label")" \
      "oauth-usage" ""
    return 0
  fi

  if [[ "$code" != "200" ]]; then
    emit_row claude "$label" "" "7-day" "" "" unreachable \
      "usage endpoint answered HTTP ${code}" "oauth-usage" ""
    return 0
  fi

  if ! jq -e . "$body" >/dev/null 2>&1; then
    emit_row claude "$label" "" "7-day" "" "" unreachable \
      "usage endpoint answered HTTP 200 with a body that is not JSON" "oauth-usage" ""
    return 0
  fi

  # Explicit paths first, then a scan for anything email-shaped. The scan is
  # what makes a MISLABELLED account visible when the payload moves the field.
  email="$(jq -r '
      (.account.email_address // .account.email // .email_address // .email // .user.email // empty)
      // ([.. | strings]
          | map(select(test("^[^@[:space:]]+@[^@[:space:]]+\\.[^@[:space:]]+$")))
          | first // empty)' "$body" 2>/dev/null || true)"

  local rendered=0
  claude_window_row "$label" "$email" "$body" "seven_day" "7-day" && rendered=1
  claude_window_row "$label" "$email" "$body" "seven_day_opus" "7-day (opus)" && rendered=1
  if [[ "$FIVE_HOUR" -eq 1 ]]; then
    claude_window_row "$label" "$email" "$body" "five_hour" "5-hour" && rendered=1
  fi

  if [[ "$rendered" -eq 0 ]]; then
    # Never a silent 0 %: say what the payload actually contained, so a
    # changed response shape is diagnosable from the output alone.
    keys="$(jq -r 'if type == "object" then (keys_unsorted | join(", ")) else type end' "$body" 2>/dev/null || echo "unreadable")"
    emit_row claude "$label" "$email" "7-day" "" "" unreachable \
      "unrecognised response shape; top-level keys seen: ${keys}" "oauth-usage" ""
  fi
  return 0
}

# --- codex -------------------------------------------------------------------

codex_bin() {
  local override="${AI_QUOTAS_CODEX_BIN:-}" candidate
  if [[ -n "$override" ]]; then
    [[ -x "$override" ]] && { printf '%s' "$override"; return 0; }
    return 1
  fi
  if candidate="$(command -v codex 2>/dev/null)" && [[ -n "$candidate" ]]; then
    printf '%s' "$candidate"; return 0
  fi
  for candidate in "/opt/homebrew/bin/codex" "/usr/local/bin/codex" \
                   "/Applications/ChatGPT.app/Contents/Resources/codex"; do
    [[ -x "$candidate" ]] && { printf '%s' "$candidate"; return 0; }
  done
  return 1
}

# The email lives in the id_token's JWT payload. Decoding a claim is not
# reading a secret — but the token itself never leaves this function.
codex_email_for() { # <profile_dir>
  local dir="$1" tok payload pad
  [[ -s "$dir/auth.json" ]] || return 0
  tok="$(jq -r '.tokens.id_token // empty' "$dir/auth.json" 2>/dev/null || true)"
  [[ -n "$tok" ]] || return 0
  payload="$(printf '%s' "$tok" | cut -d. -f2 | tr '_-' '/+')"
  [[ -n "$payload" ]] || return 0
  # base64url drops padding; jq's @base64d wants it.
  pad=$(( ${#payload} % 4 ))
  if [[ "$pad" -eq 2 ]]; then payload="${payload}=="
  elif [[ "$pad" -eq 3 ]]; then payload="${payload}="
  elif [[ "$pad" -eq 1 ]]; then return 0
  fi
  jq -rn --arg p "$payload" '($p | @base64d | fromjson | .email // empty)' 2>/dev/null || true
}

# Drives `codex app-server` over a FIFO. The FIFO is what keeps stdin OPEN:
# feeding the requests from a plain pipe closes stdin at once and the server
# shuts down before it has answered (measured — the initialize reply arrives,
# the rate-limit reply does not). The reader polls for the response and kills
# the server the moment it lands, so a healthy account costs a round trip
# rather than the whole bound.
CODEX_RESULT_FILE=""
CODEX_FAIL_REASON=""
codex_app_server_read() { # <profile_dir> <codex_bin>
  local dir="$1" bin="$2"
  local fifo="$TMP/codex.fifo" out="$TMP/codex.out" waited=0 srv=0
  # JSON permits whitespace on BOTH sides of the name separator, so a server
  # that writes `"id" : 2` is as valid as the compact `"id":2` we send. Matching
  # only the compact form makes a healthy account look like a timeout and sends
  # the reader down the HTTP fallback, so tolerate either.
  local id2_re='"id"[[:space:]]*:[[:space:]]*2'
  CODEX_RESULT_FILE=""
  # The three ways this can fail are three different things to fix — a
  # crashed CLI, a hung one, and a broken temp dir — and a single "did not
  # answer within Ns" for all of them sends the reader after a timeout that
  # never happened. Recorded here, reported in the row's note.
  CODEX_FAIL_REASON="app-server did not answer within ${CODEX_TIMEOUT}s"
  rm -f "$fifo" "$out"
  if ! mkfifo "$fifo" 2>/dev/null; then
    CODEX_FAIL_REASON="could not create the app-server pipe in ${TMP}"
    return 1
  fi
  : > "$out"

  # The server's read-open of the FIFO blocks until a writer appears; it is
  # the BACKGROUND process that waits, so the parent reaches the open below
  # and releases it. Opening read-write (`<>`) here is what makes that open
  # unable to block in turn, even when the server died on startup.
  CODEX_HOME="$dir" "$bin" app-server <"$fifo" >"$out" 2>/dev/null &
  srv=$!
  if ! exec 3<> "$fifo"; then
    CODEX_FAIL_REASON="could not open the app-server pipe"
    kill "$srv" 2>/dev/null; wait "$srv" 2>/dev/null
    return 1
  fi
  printf '%s\n' \
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"ai-quotas","version":"1.0"}}}' \
    '{"jsonrpc":"2.0","method":"initialized"}' \
    '{"jsonrpc":"2.0","id":2,"method":"account/rateLimits/read"}' >&3

  local exited_early=0
  while [[ "$waited" -lt "$CODEX_TIMEOUT" ]]; do
    if grep -q "$id2_re" "$out" 2>/dev/null; then break; fi
    if ! kill -0 "$srv" 2>/dev/null; then exited_early=1; break; fi
    sleep 1
    waited=$(( waited + 1 ))
  done

  exec 3>&-
  # Bounded reap, same reasoning as lib/bounded-run.sh's: SIGTERM is a request
  # the real `codex app-server` is free to ignore, and SIGKILL is QUEUED rather
  # than effective against a process wedged in uninterruptible I/O. An
  # unconditional `wait` would then block forever HERE — at cleanup, after the
  # answer is already in hand — and hang a report whose whole contract is that
  # it comes back. So escalate TERM to KILL, poll a finite window for the exit,
  # and give up on the status rather than the report. init reaps the orphan.
  kill "$srv" 2>/dev/null || true
  local reap=0 gone=0
  while [[ "$reap" -lt 4 ]]; do
    if ! kill -0 "$srv" 2>/dev/null; then gone=1; break; fi
    [[ "$reap" -eq 1 ]] && kill -9 "$srv" 2>/dev/null
    sleep 1
    reap=$(( reap + 1 ))
  done
  # `kill -0` succeeds on a zombie, so only wait once the process is really
  # gone — that call returns immediately and reaps it.
  [[ "$gone" -eq 1 ]] && wait "$srv" 2>/dev/null

  if grep -q "$id2_re" "$out" 2>/dev/null; then
    CODEX_FAIL_REASON=""
    CODEX_RESULT_FILE="$out"
    return 0
  fi
  # A server that exited on its own did not time out — it refused, crashed,
  # or found nothing to serve under that CODEX_HOME. Say which.
  [[ "$exited_early" -eq 1 ]] && CODEX_FAIL_REASON="app-server exited without answering"
  return 1
}

# Renders whichever windows a rateLimits snapshot carries. The weekly window
# is picked by windowDurationMins == 10080 across BOTH primary and secondary,
# because which slot holds it varies by plan (measured: a Pro account reports
# the weekly figures in `primary` with `secondary` null).
# <note> is prepended to every row this renders. On the fallback path it
# carries WHY app-server was skipped: `source: http` says which path ran, but
# not what went wrong with the preferred one, and a silently degraded read is
# the thing worth surfacing.
# A LIVE overage figure from the rate-limits payload, when one is there.
#
# No captured Codex payload has ever carried either key — the reset balance
# lives in the ChatGPT usage UI, not in `account/rateLimits/read`. This is a
# hook, not an observation, and it is written so that being wrong costs
# nothing: a key that is absent, or present with a value that is not a plain
# number, contributes NOTHING to the row, and the month watermark in
# quotas-cheapest-next.sh answers instead. What it must never do is invent a
# balance — hence the explicit numeric guard rather than a bare `tonumber`.
# If OpenAI ships the figure under a third name, add it here and to
# .claude/reference/ai-quotas.md; until then the fallback is the answer.
codex_live_overage() { # <snapshot-json-file>
  # Type-guarded at every step. `.resets.freeRemaining` on a payload whose
  # `resets` is an array or a number is a jq TYPE ERROR, which aborts the
  # program — and while the `|| printf '{}'` below catches that, an error path
  # is a poor way to express "this key was not there". `obj` narrows to an
  # object first, so an unexpected shape reads as absent, which is what it is.
  jq -c '
    def as_num: if type == "number" then .
                elif type == "string" and test("^[0-9]+(\\.[0-9]+)?$") then tonumber
                else null end;
    def obj: if type == "object" then . else {} end;
    (. | obj) as $s
    | {free_resets_remaining:
         (($s.freeResetsRemaining // $s.free_resets_remaining
           // ($s.resets | obj | .freeRemaining) // null) | as_num),
       credits_remaining_usd:
         (($s.creditBalanceUsd // ($s.credits | obj | .balanceUsd) // null) | as_num)}
    | with_entries(select(.value != null))' "$1" 2>/dev/null \
    || printf '{}'
}

codex_render_snapshot() { # <label> <email> <snapshot-json-file> <source> [<note>]
  local label="$1" email="$2" snap="$3" source="$4"
  local note="${5:-}"
  local plan weekly five rendered=0 weekly_ok=0 weekly_is_short=0 used resets dur
  local live

  plan="$(jq -r '.planType // empty' "$snap" 2>/dev/null || true)"
  live="$(codex_live_overage "$snap")"
  printf '%s' "$live" | jq -e 'type == "object"' >/dev/null 2>&1 || live="{}"
  weekly="$(jq -c '[.primary, .secondary] | map(select(. != null))
                   | (map(select(.windowDurationMins == 10080)) | first)
                     // (map(select(.windowDurationMins != null))
                         | sort_by(.windowDurationMins) | last)
                     // first
                   // empty' "$snap" 2>/dev/null || true)"

  if [[ -n "$weekly" ]]; then
    used="$(printf '%s' "$weekly" | jq -r '.usedPercent // empty')"
    resets="$(to_epoch_maybe "$(printf '%s' "$weekly" | jq -r '.resetsAt // empty')")"
    dur="$(printf '%s' "$weekly" | jq -r '.windowDurationMins // empty')"
    # Three cases, because "7-day" is a CLAIM about the window, not a default.
    # A window whose duration the payload did not report is not weekly just
    # because the weekly slot is where we looked for it — labelling it
    # `7-day` would put a number under a heading that may be wrong, which is
    # the failure this whole selector exists to avoid.
    local window detail="$note"
    if [[ "$dur" == "10080" ]]; then
      window="7-day"
    elif [[ "$dur" =~ ^[0-9]+$ ]]; then
      window="$(( dur / 60 ))-hour"
      weekly_is_short=1
      detail="${note:+${note}; }no 7-day window reported; showing the longest window this plan reports"
    else
      window="window"
      detail="${note:+${note}; }this plan did not report the window's duration"
    fi
    emit_row codex "$label" "$email" "$window" "$used" "$resets" ok "$detail" "$source" "$plan" "$live"
    rendered=1
    weekly_ok=1
  fi

  if [[ "$FIVE_HOUR" -eq 1 ]]; then
    # Exclude the slot the weekly row already rendered. When a plan reports one
    # window and it is shorter than a week, the weekly selector's
    # longest-window fallback renders THAT window; without this exclusion the
    # short selector picks the same slot again and `--five-hour` prints one
    # window as two rows differing only in the note.
    five="$(jq -c --argjson shown "${weekly:-null}" \
                  '[.primary, .secondary] | map(select(. != null))
                   | map(select(. != $shown))
                   | map(select(.windowDurationMins != null and .windowDurationMins < 10080))
                   | sort_by(.windowDurationMins) | first // empty' "$snap" 2>/dev/null || true)"
    if [[ -n "$five" ]]; then
      used="$(printf '%s' "$five" | jq -r '.usedPercent // empty')"
      resets="$(to_epoch_maybe "$(printf '%s' "$five" | jq -r '.resetsAt // empty')")"
      dur="$(printf '%s' "$five" | jq -r '.windowDurationMins // empty')"
      local flabel="5-hour"
      [[ -n "$dur" && "$dur" != "300" ]] && flabel="$(( dur / 60 ))-hour"
      emit_row codex "$label" "$email" "$flabel" "$used" "$resets" ok "$note" "$source" "$plan" "$live"
      rendered=1
    elif [[ "$weekly_is_short" -eq 1 ]]; then
      # The only sub-weekly window this plan reports is the row above, which
      # already carries its real duration and says why it is standing in for a
      # weekly one. Printing it again would duplicate it; claiming the plan
      # reports no short window would contradict the row directly above it.
      :
    elif [[ "$weekly_ok" -eq 1 ]]; then
      # A single-window response is valid, not an error — say so instead of
      # dropping the row the flag promised. Gated on the weekly row having
      # rendered, because that is the proof this really was a rate-limits
      # snapshot: emitting "this plan reports no short window" for a payload
      # we could not parse AT ALL would report a fact about the plan that we
      # never established, and would mark the whole read as successful — so
      # `--five-hour` would suppress the unrecognised-shape row that the same
      # payload produces without the flag.
      emit_row codex "$label" "$email" "5-hour" "" "" ok \
        "${note:+${note}; }this plan reports no short window" "$source" "$plan" "$live"
      rendered=1
    fi
  fi

  [[ "$rendered" -eq 1 ]]
}

codex_http_fallback() { # <label> <profile_dir> <email> <why>
  local label="$1" dir="$2" email="$3" why="$4"
  local body="$TMP/codex-http.json" hdrs="$TMP/codex-http-hdrs.txt"
  local token account code rc=0 snap="$TMP/codex-http-snap.json"

  token="$(jq -r '.tokens.access_token // empty' "$dir/auth.json" 2>/dev/null || true)"
  account="$(jq -r '.tokens.account_id // .account_id // empty' "$dir/auth.json" 2>/dev/null || true)"
  if [[ -z "$token" ]]; then
    emit_row codex "$label" "$email" "7-day" "" "" needs-login \
      "${why}; auth.json holds no access token — run: $(relogin_hint codex "$label")" "http" ""
    return 0
  fi

  : > "$body"; : > "$hdrs"
  code="$(printf 'header = "Authorization: Bearer %s"\n' "$token" \
    | "$CURL_BIN" -sS --max-time "$HTTP_TIMEOUT" \
        -o "$body" -D "$hdrs" -w '%{http_code}' \
        -H "ChatGPT-Account-Id: ${account}" \
        -H "Accept: application/json" \
        -K - "$CHATGPT_URL" 2>/dev/null)" || rc=$?
  token=""

  if [[ "$rc" -ne 0 || -z "$code" ]]; then
    emit_row codex "$label" "$email" "7-day" "" "" unreachable \
      "${why}; curl failed (exit ${rc:-?}) talking to ${CHATGPT_URL}" "http" ""
    return 0
  fi
  if [[ "$code" == "429" ]]; then
    emit_row codex "$label" "$email" "7-day" "" "" rate-limited \
      "${why}; the usage endpoint rate-limited this read" "http" ""
    return 0
  fi
  if [[ "$code" == "401" || "$code" == "403" ]]; then
    emit_row codex "$label" "$email" "7-day" "" "" needs-login \
      "${why}; the usage endpoint rejected this credential (HTTP ${code}) — run: $(relogin_hint codex "$label")" "http" ""
    return 0
  fi
  if [[ "$code" != "200" ]] || ! jq -e . "$body" >/dev/null 2>&1; then
    emit_row codex "$label" "$email" "7-day" "" "" unreachable \
      "${why}; usage endpoint answered HTTP ${code}" "http" ""
    return 0
  fi

  # The HTTP payload nests the same snapshot one or two levels down
  # depending on the caller; take the first object that carries a window.
  jq '(.rate_limits // .rateLimits // .usage.rateLimits // .)' "$body" > "$snap" 2>/dev/null || : > "$snap"
  if ! codex_render_snapshot "$label" "$email" "$snap" "http" "$why"; then
    local keys
    keys="$(jq -r 'if type == "object" then (keys_unsorted | join(", ")) else type end' "$body" 2>/dev/null || echo "unreadable")"
    emit_row codex "$label" "$email" "7-day" "" "" unreachable \
      "${why}; unrecognised response shape; top-level keys seen: ${keys}" "http" ""
  fi
  return 0
}

read_codex_account() { # <label> <profile_dir>
  local label="$1" dir="$2"
  local email bin snap="$TMP/codex-snap.json" logged_in=0

  email="$(codex_email_for "$dir")"

  if [[ -s "$dir/auth.json" ]]; then
    logged_in=1
  elif bin="$(codex_bin)"; then
    probe 10 env "CODEX_HOME=$dir" "$bin" login status && logged_in=1
  fi
  if [[ "$logged_in" -eq 0 ]]; then
    emit_row codex "$label" "$email" "7-day" "" "" needs-login \
      "no auth.json in ${dir} — run: $(relogin_hint codex "$label")" "" ""
    return 0
  fi

  if bin="$(codex_bin)"; then
    if codex_app_server_read "$dir" "$bin"; then
      # The first match is picked INSIDE jq. Piping into `head -n 1` under
      # `pipefail` means head closes the pipe, jq dies of SIGPIPE, the
      # pipeline reports failure, and the `|| :` then truncates the snapshot
      # jq had just written correctly — a good read discarded by its own
      # error handling, and only when more than one line matches.
      jq -sc 'map(select(.id == 2) | (.result.rateLimits // empty)) | first // empty' \
        "$CODEX_RESULT_FILE" > "$snap" 2>/dev/null || : > "$snap"
      if [[ -s "$snap" ]] && codex_render_snapshot "$label" "$email" "$snap" "app-server"; then
        return 0
      fi
      local rpc_err
      rpc_err="$(jq -sr 'map(select(.id == 2) | (.error.message // empty)) | first // empty' \
        "$CODEX_RESULT_FILE" 2>/dev/null || true)"
      codex_http_fallback "$label" "$dir" "$email" \
        "app-server returned no rate limits${rpc_err:+ (${rpc_err})}"
      return 0
    fi
    codex_http_fallback "$label" "$dir" "$email" \
      "${CODEX_FAIL_REASON:-app-server did not answer}"
    return 0
  fi

  codex_http_fallback "$label" "$dir" "$email" "no codex CLI found"
  return 0
}

# --- cursor ------------------------------------------------------------------

# Cursor publishes no individual usage API, so the figures come from the
# logged-in dashboard through a saved browser session. This function does no
# browsing itself: it shells out to lib/ai-quotas-cursor.js, which owns
# Playwright and prints ONE JSON verdict. Everything about a cookie stays
# inside the profile directory and the browser — nothing here reads, prints,
# or copies a session value.
CURSOR_WINDOW="billing-cycle"

cursor_node_bin() {
  local override="${AI_QUOTAS_NODE_BIN:-}" candidate
  if [[ -n "$override" ]]; then
    [[ -x "$override" ]] && { printf '%s' "$override"; return 0; }
    return 1
  fi
  if candidate="$(command -v node 2>/dev/null)" && [[ -n "$candidate" ]]; then
    printf '%s' "$candidate"; return 0
  fi
  # A minimal PATH makes a bare `command -v` lie on this fleet, so the known
  # install locations are checked by absolute path rather than assumed absent.
  for candidate in "/opt/homebrew/bin/node" "/usr/local/bin/node"; do
    [[ -x "$candidate" ]] && { printf '%s' "$candidate"; return 0; }
  done
  return 1
}

# `$1` dollars, or "unknown" — used only in the note, never as a figure.
cursor_usd() { # <number|null|"">
  local v="${1:-}"
  [[ -n "$v" && "$v" != "null" ]] || { printf 'unknown'; return 0; }
  printf '$%s' "$v"
}

read_cursor_account() { # <label> <profile_dir>
  local label="$1" dir="$2"
  local node helper out status detail keys pools count i
  local start_epoch end_epoch plan_name plan_used plan_included source note extra
  local spend_used spend_limit
  local pool used

  helper="${AI_QUOTAS_CURSOR_HELPER:-$SELF_DIR/lib/ai-quotas-cursor.js}"
  if [[ ! -r "$helper" ]]; then
    emit_row cursor "$label" "" "$CURSOR_WINDOW" "" "" unreachable \
      "the cursor helper is missing at ${helper} — reinstall it from the repo" "" ""
    return 0
  fi
  if ! node="$(cursor_node_bin)"; then
    emit_row cursor "$label" "" "$CURSOR_WINDOW" "" "" unreachable \
      "no node found (PATH, AI_QUOTAS_NODE_BIN, and the known install paths were all checked) — the cursor reader needs Node 20+" "" ""
    return 0
  fi
  if [[ ! -d "$dir" ]]; then
    emit_row cursor "$label" "" "$CURSOR_WINDOW" "" "" needs-login \
      "no browser profile at ${dir} — run: $(relogin_hint cursor "$label")" "" ""
    return 0
  fi

  # Bounded like every other local probe: a browser that never finishes
  # loading must not hold a five-account report open.
  # The helper's own bound is set SHORTER than the bash bound, with a few
  # seconds of headroom. Given the same number, the helper would still be
  # closing its browser and serialising its verdict when the outer probe
  # killed it — so an honest `needs-login` or `unreadable` row would be
  # replaced by "the helper did not finish", every time the read ran long.
  local helper_secs=$(( CURSOR_TIMEOUT - 3 ))
  [[ "$helper_secs" -ge 5 ]] || helper_secs=5
  # The outer bound is derived from the FLOORED helper bound, not from
  # CURSOR_TIMEOUT alone. With a configured 5-8s the floor raises helper_secs
  # back to 5 and the subtraction above buys nothing — outer and inner would
  # be equal, or the inner would be the larger of the two, and the headroom
  # this pair exists to create would silently be zero.
  local outer_secs=$(( helper_secs + 3 ))
  [[ "$CURSOR_TIMEOUT" -gt "$outer_secs" ]] && outer_secs="$CURSOR_TIMEOUT"
  if ! probe "$outer_secs" "$node" "$helper" \
       --profile-dir "$dir" --mode read --timeout-ms "$(( helper_secs * 1000 ))"; then
    emit_row cursor "$label" "" "$CURSOR_WINDOW" "" "" unreachable \
      "the cursor helper did not finish within ${outer_secs}s" "" ""
    return 0
  fi
  out="$PROBE_OUT"

  # The helper's contract is one JSON object. Anything else — an empty run, a
  # stack trace, a stray log line — is a broken helper, and saying so beats
  # rendering the account as though it had answered.
  if ! printf '%s' "$out" | jq -e 'type == "object" and (.status | type == "string")' >/dev/null 2>&1; then
    emit_row cursor "$label" "" "$CURSOR_WINDOW" "" "" unreadable \
      "the cursor helper printed no JSON verdict this reader understands" "" ""
    return 0
  fi

  status="$(printf '%s' "$out" | jq -r '.status')"
  detail="$(printf '%s' "$out" | jq -r '.detail // ""')"
  source="$(printf '%s' "$out" | jq -r '.source // ""')"

  case "$status" in
    needs-login)
      emit_row cursor "$label" "" "$CURSOR_WINDOW" "" "" needs-login \
        "${detail:-the saved browser session is gone} — run: $(relogin_hint cursor "$label")" "$source" ""
      return 0 ;;
    unreadable)
      keys="$(printf '%s' "$out" | jq -r '(.keys_seen // []) | join(", ")')"
      emit_row cursor "$label" "" "$CURSOR_WINDOW" "" "" unreadable \
        "${detail:-the usage response changed shape}${keys:+; keys seen: ${keys}}" "$source" ""
      return 0 ;;
    ok) ;;
    *)
      emit_row cursor "$label" "" "$CURSOR_WINDOW" "" "" unreachable \
        "${detail:-the cursor helper reported ${status}}" "$source" ""
      return 0 ;;
  esac

  pools="$(printf '%s' "$out" | jq -c '.pools // []')"
  count="$(printf '%s' "$pools" | jq 'length' 2>/dev/null || echo 0)"
  if [[ ! "$count" =~ ^[0-9]+$ || "$count" -eq 0 ]]; then
    # `ok` with no pool is the helper contradicting itself. Reporting it as a
    # shape problem is the only honest reading; rendering nothing would drop
    # the account silently.
    emit_row cursor "$label" "" "$CURSOR_WINDOW" "" "" unreadable \
      "the cursor helper reported ok but carried no pool figures" "$source" ""
    return 0
  fi

  end_epoch="$(printf '%s' "$out" | jq -r 'if .billing_cycle_end_epoch == null then "" else (.billing_cycle_end_epoch | tostring) end')"
  # Anything that is not epoch seconds becomes "no reset reported" — the table
  # renders that as `-`. A value date(1) cannot read would otherwise format as
  # nothing while the countdown said `reset`, i.e. "your cycle already rolled".
  [[ "$end_epoch" =~ ^[0-9]+$ ]] || end_epoch=""
  start_epoch="$(printf '%s' "$out" | jq -r 'if .billing_cycle_start_epoch == null then "" else (.billing_cycle_start_epoch | tostring) end')"
  [[ "$start_epoch" =~ ^[0-9]+$ ]] || start_epoch=""
  plan_name="$(printf '%s' "$out" | jq -r '.plan_name // ""')"
  plan_used="$(printf '%s' "$out" | jq -r 'if .plan_used_usd == null then "" else (.plan_used_usd | tostring) end')"
  plan_included="$(printf '%s' "$out" | jq -r 'if .plan_included_usd == null then "" else (.plan_included_usd | tostring) end')"
  # The on-demand block (#1669). Plan-wide like the two above — it is one
  # spend limit for the account, not a per-pool one — so both rows carry the
  # same pair, and the overage column says `on-demand` when the helper did not
  # report it rather than showing a dollar figure nobody sent.
  spend_used="$(printf '%s' "$out" | jq -r 'if .spend_limit_used_usd == null then "" else (.spend_limit_used_usd | tostring) end')"
  spend_limit="$(printf '%s' "$out" | jq -r 'if .spend_limit_usd == null then "" else (.spend_limit_usd | tostring) end')"

  # Said on every pool row, because it is the one thing a reader of this table
  # would otherwise get wrong: the dashboard's own response reports the pools
  # as PERCENTAGES, and the only dollars in it are plan-wide. Dividing those
  # dollars across the two pools would manufacture a figure Cursor never sent.
  note="billing cycle"
  [[ -z "$start_epoch" ]] || note="$note since $(epoch_to_et "$start_epoch")"
  note="${note}; plan-wide spend $(cursor_usd "$plan_used") of $(cursor_usd "$plan_included") included"
  note="${note}; this response reports the pools as percent only, so per-pool dollars are unavailable"

  for (( i = 0; i < count; i++ )); do
    pool="$(printf '%s' "$pools" | jq -r --argjson i "$i" '.[$i].pool // ""')"
    used="$(printf '%s' "$pools" | jq -r --argjson i "$i" \
      'if .[$i].used_pct == null then "" else (.[$i].used_pct | tostring) end')"
    [[ -n "$pool" ]] || pool="pool-${i}"
    # One decimal, with a bare `.0` dropped: the payload carries full float
    # precision (49.02333…), the dashboard shows `49%`, and a table column is
    # not the place for fourteen digits. Rounding happens ONCE, here, so the
    # JSON row and the table can never disagree — and `remaining_pct`, which
    # emit_row derives as `100 - used`, comes out of the same number.
    # VALIDATED before rounding, not after. awk coerces a non-numeric value to
    # 0, so `"n/a"` — or any string a future helper version put here — would
    # round to `0.0` and render as `0 %`: a figure nobody measured, reading as
    # "plenty left". A value this reader cannot recognise as a number becomes
    # empty, which emit_row turns into `null` and the table shows as `-`.
    case "$used" in
      "") ;;
      *[!0-9.]* | *.*.* | .) used="" ;;
      *) used="$(awk -v v="$used" 'BEGIN { s = sprintf("%.1f", v); sub(/\.0$/, "", s); print s }' 2>/dev/null || printf '%s' "$used")" ;;
    esac
    extra="$(jq -nc --arg pool "$pool" --arg pu "$plan_used" --arg pi "$plan_included" \
      --arg su "$spend_used" --arg sl "$spend_limit" \
      '{pool: $pool,
        plan_used_usd: (if $pu == "" then null else (try ($pu | tonumber) catch null) end),
        plan_included_usd: (if $pi == "" then null else (try ($pi | tonumber) catch null) end),
        spend_limit_used_usd: (if $su == "" then null else (try ($su | tonumber) catch null) end),
        spend_limit_usd: (if $sl == "" then null else (try ($sl | tonumber) catch null) end)}' \
      2>/dev/null || printf '{}')"
    emit_row cursor "$label" "" "$CURSOR_WINDOW" "$used" "$end_epoch" ok \
      "$note" "$source" "$plan_name" "$extra"
  done
  return 0
}

# --- main --------------------------------------------------------------------

# Bare call: see read_config's own note on why this must not be a `$(…)`.
read_config
COUNT="$(printf '%s' "$CONFIG" | jq '.accounts | length' 2>/dev/null || true)"
# read_config only returns on a config it has already validated, so a count
# that is not a number here means the read itself failed in a way this
# script does not model — which must be an error, never an empty report that
# reads exactly like "you have no accounts".
[[ "$COUNT" =~ ^[0-9]+$ ]] || die 5 "could not count the accounts in $CONFIG_FILE"

MATCHED=0
ROW_BUILD_FAILURES=0
resolve_claude_version

for (( i = 0; i < COUNT; i++ )); do
  PROVIDER="$(printf '%s' "$CONFIG" | jq -r --argjson i "$i" '.accounts[$i].provider')"
  LABEL="$(printf '%s' "$CONFIG" | jq -r --argjson i "$i" '.accounts[$i].label')"
  DIR="$(printf '%s' "$CONFIG" | jq -r --argjson i "$i" '.accounts[$i].profile_dir')"
  SERVICE="$(printf '%s' "$CONFIG" | jq -r --argjson i "$i" '.accounts[$i].credential_ref.service // ""')"

  if [[ -n "$ACCOUNT_FILTER" && "$LABEL" != "$ACCOUNT_FILTER" ]]; then
    continue
  fi
  MATCHED=$(( MATCHED + 1 ))

  # Every account is read on its own. A provider that fails takes its row
  # down with it and nothing else — which is the whole point of a report
  # across five subscriptions.
  case "$PROVIDER" in
    claude) read_claude_account "$LABEL" "$DIR" "$SERVICE" ;;
    codex)  read_codex_account "$LABEL" "$DIR" ;;
    cursor) read_cursor_account "$LABEL" "$DIR" ;;
    *)
      emit_row "$PROVIDER" "$LABEL" "" "7-day" "" "" unsupported \
        "this reader knows claude, codex, and cursor; '${PROVIDER}' is not one of them" "" ""
      ;;
  esac
done

# --- overage annotation (#1669) ----------------------------------------------
#
# The price of continuing is a property of the provider and the reset
# watermark, not of this read, so it is computed by a helper over the finished
# rows rather than threaded through every provider path. INFORMATIONAL ONLY:
# it names the cheapest account to continue on and stops. It never switches an
# account, never buys anything, and never gates dispatch
# (.claude/rules/safety.md §"Anthropic Quota & Spend Authority"; the #499
# rollback is the precedent).
#
# Resolved sibling-first, then through the standard three-candidate lookup, so
# a copy of this script running outside a checkout still finds it.
# AI_QUOTAS_CHEAPEST_BIN, when set, is used EXCLUSIVELY — no fall-through to
# the search below. A seam that falls back would find the repo copy through
# the relative candidate whenever the caller happens to be standing in a
# checkout, so the "helper unavailable" case could never be exercised from
# inside this repo, which is the only place anyone runs the suite.
CHEAPEST_SH=""
if [[ -n "${AI_QUOTAS_CHEAPEST_BIN:-}" ]]; then
  [[ -x "$AI_QUOTAS_CHEAPEST_BIN" ]] && CHEAPEST_SH="$AI_QUOTAS_CHEAPEST_BIN"
else
  for _c in "$SELF_DIR/quotas-cheapest-next.sh" \
            "${_HOME}/.claude/skills-worktree/.claude/scripts/quotas-cheapest-next.sh" \
            "${_HOME}/.claude/scripts/quotas-cheapest-next.sh" \
            ".claude/scripts/quotas-cheapest-next.sh"; do
    if [[ -x "$_c" ]]; then CHEAPEST_SH="$_c"; break; fi
  done
  unset _c
fi

# Result in a file, and the caller checks it. A helper that fails must degrade
# to "no prices, no hint" — never to an empty document that reads as "no
# accounts", and never to a silent table missing a column it promised.
DOC="$TMP/doc.json"
annotate_rows() { # <rows-json-file>
  local src="$1" rc=0
  : > "$DOC"
  if [[ -n "$CHEAPEST_SH" ]]; then
    "$CHEAPEST_SH" < "$src" > "$DOC" 2>"$TMP/cheapest.err" || rc=$?
    # The FULL documented shape, not just `.rows`. A partial document — rows
    # present, `cheapest_next` missing — would pass a looser check and then be
    # read for a hint that was never there, so the run would silently print no
    # hint and call it "no account is low". Degrading says which it was.
    if [[ "$rc" -eq 0 && -s "$DOC" ]] &&
       jq -e 'type == "object" and (.rows | type == "array") and has("cheapest_next")' \
         "$DOC" >/dev/null 2>&1; then
      # The helper writes its own warnings (an unreadable watermark, a bad
      # knob) to stderr; pass them through rather than swallowing them.
      [[ ! -s "$TMP/cheapest.err" ]] || cat "$TMP/cheapest.err" >&2
      return 0
    fi
    warn "DEGRADED: quotas-cheapest-next.sh failed (exit ${rc}) — reporting without overage prices or a cheapest-next hint"
    [[ ! -s "$TMP/cheapest.err" ]] || sed 's/^/  /' "$TMP/cheapest.err" >&2
  elif [[ -n "${AI_QUOTAS_CHEAPEST_BIN:-}" ]]; then
    # An override that does not resolve is a CONFIGURATION problem, and saying
    # "checked all three portable paths" here would send the reader looking in
    # three places this run never consulted.
    warn "DEGRADED: AI_QUOTAS_CHEAPEST_BIN names '${AI_QUOTAS_CHEAPEST_BIN}', which is not executable — reporting without overage prices or a cheapest-next hint"
  else
    warn "DEGRADED: quotas-cheapest-next.sh not found (checked the script's own directory and all three portable paths) — reporting without overage prices or a cheapest-next hint"
  fi
  # Same document shape, minus the prices. `overage` is already null on every
  # row (emit_row declares it), so a consumer sees one shape either way.
  jq -n --slurpfile rows "$src" \
    '{schema_version: "1.0", threshold_pct: null, basis: null,
      rows: ($rows[0] // []), cheapest_next: null}' > "$DOC" 2>/dev/null \
    || printf '{"schema_version":"1.0","threshold_pct":null,"basis":null,"rows":[],"cheapest_next":null}\n' > "$DOC"
  return 0
}

# The two "nothing to report" exits emit the SAME document as a full run, with
# an empty `rows` array — not a bare `[]`. A consumer that reads `.rows` on a
# populated run and gets a top-level array here would have to special-case
# emptiness, and the special case is exactly where a partial read gets mistaken
# for a complete one.
EMPTY_ROWS="$TMP/empty.json"
printf '[]' > "$EMPTY_ROWS"

if [[ "$COUNT" -eq 0 ]]; then
  if [[ "$JSON" -eq 1 ]]; then
    annotate_rows "$EMPTY_ROWS"; cat "$DOC"
  else
    echo "No accounts registered yet."
    echo "Register one with: /quotas-setup add <claude|codex|cursor> <label>"
  fi
  exit 0
fi

if [[ "$MATCHED" -eq 0 ]]; then
  if [[ "$JSON" -eq 1 ]]; then
    annotate_rows "$EMPTY_ROWS"; cat "$DOC"
  else
    echo "No registered account matches --account '${ACCOUNT_FILTER}'."
    echo "List the registered accounts with: /quotas-setup list"
  fi
  exit 0
fi

# Accounts matched the filter but nothing survived row-building: the report has
# nothing to say and no honest way to say it, because `[]` and a bare header
# both read as "no accounts". Exit 70 — the same internal-defect status the
# --help extraction failure uses — rather than emitting a successful nothing.
if [[ ! -s "$ROWS" ]]; then
  die 70 "row builder produced no rows for $MATCHED matched account(s) (${ROW_BUILD_FAILURES} failed) — refusing to print an empty report as a successful read"
fi

ROWS_JSON="$TMP/rows.json"
jq -s '.' "$ROWS" > "$ROWS_JSON" 2>/dev/null || die 70 "could not assemble the rows into an array"
annotate_rows "$ROWS_JSON"

if [[ "$JSON" -eq 1 ]]; then
  cat "$DOC"
  exit 0
fi

# Rendered ONCE, to a file, so the no-`column` fallback prints the same table
# unaligned rather than something else entirely. Piping into `column` and
# falling back to `cat "$ROWS"` printed the TSV header over the raw JSON rows —
# a fallback that does not degrade the output but replaces it.
TABLE="$TMP/table.tsv"
{
  printf 'ACCOUNT\tPROVIDER\tWINDOW\tUSED\tREMAIN\tOVERAGE\tRESETS (ET)\tIN\tSTATUS\tNOTE\n'
  jq -r '
    def pct: if . == null then "-" else "\(.)%" end;
    def dash: if . == null or . == "" then "-" else . end;
    .rows[] |
    [ .reported_email,
      .provider,
      # The pool name when the provider has pools, the window otherwise. A
      # Cursor account contributes TWO rows for one window, so printing the
      # window here would render them as two identical lines differing only
      # in a percentage — the reader could not tell which pool was which.
      (.pool // .window),
      (.used_pct | pct),
      (.remaining_pct | pct),
      # What continuing past this cap costs. `-` when no price is known — a
      # provider this reader has no table row for, or a run where the helper
      # was unavailable — never a blank that reads as "free".
      (.overage.label? | dash),
      (.resets_at_et | dash),
      (.countdown | dash),
      .status,
      ([ (if .label != .reported_email then "registered as \(.label)" else empty end),
         (.plan | if . == null then empty else "plan \(.)" end),
         (.source | if . == null then empty else "via \(.)" end),
         (.detail | if . == null or . == "" then empty else . end) ]
       | join("; ") | if . == "" then "-" else . end)
    ] | @tsv' "$DOC"
} > "$TABLE"
column -t -s $'\t' "$TABLE" 2>/dev/null || cat "$TABLE"

# The cheapest-next hint, printed ONLY when the helper returned one — i.e.
# when at least one account is at or below the threshold. Nothing prints while
# every account still has room, because a suggestion nobody needs is a
# suggestion that trains the reader to ignore the line.
HINT="$(jq -r 'if .cheapest_next == null then empty
               else "Cheapest to continue on: \(.cheapest_next.label) (\(.cheapest_next.reason))" end' \
  "$DOC" 2>/dev/null || true)"
if [[ -n "$HINT" ]]; then
  echo
  echo "$HINT"
  # The basis, on its own line, because the units do NOT convert and a hint
  # that hides that is a hint that reads as a price comparison.
  jq -r 'if .cheapest_next == null then empty else "  \(.cheapest_next.basis)" end' "$DOC" 2>/dev/null || true
  echo "  Informational only — it never switches accounts, never buys anything, and never gates dispatch."
fi

echo
echo "Display only — never a dispatch or spend gate (.claude/rules/safety.md §Anthropic Quota & Spend Authority)."
exit 0
