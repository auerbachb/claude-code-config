#!/usr/bin/env bash
# ai-quotas.sh — report each registered AI account's remaining allowance
# (issue #1667).
# catalog: token-measurement — Read every account registered by `/quotas-setup` and print one row per usage window — used %, remaining %, reset time in Eastern, and a countdown — for `claude` (Anthropic OAuth usage endpoint) and `codex` (`codex app-server`, HTTP fallback); display only, never a dispatch or spend gate
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
#   cursor          Nothing yet — every cursor row reports `unsupported`
#                   until increment 3 (issue #1668) adds the reader.
#
# WINDOW SELECTION
#   The weekly Codex window is chosen by `windowDurationMins == 10080`,
#   never by position. On a Pro account the weekly figures arrive in
#   `primary` with `secondary` null; on others they arrive in `secondary`.
#   Reading position instead of duration reports the wrong window on half
#   the plans, and it looks exactly like a right answer.
#
# OUTPUT
#   stdout: the table (default) or a JSON array (--json). Each JSON row
#           carries provider, label, reported_email, window, used_pct,
#           remaining_pct, resets_at_epoch, resets_at_et, status, plus
#           detail, source, and plan.
#   stderr: one-line per-account diagnostics.
#
#   Statuses are per row, and one failing account never stops the others:
#     ok            figures were read
#     needs-login   no usable credential — the exact `/quotas-setup relogin`
#                   command is in the row's note
#     rate-limited  the provider answered 429; the retry window is in the note
#     unreachable   network failure, or a response this reader did not
#                   recognise (its top-level keys are printed rather than a
#                   silent 0 %)
#     unsupported   cursor, until increment 3
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
#   AI_QUOTAS_CODEX_TIMEOUT   app-server response bound, seconds (20).
#                             Both must be a positive integer with no leading
#                             zero. Anything else is refused on stderr and the
#                             default is used, because a value arithmetic
#                             cannot read makes the bound it governs elapse
#                             instantly and report itself as a timeout.
#   AI_QUOTAS_NOW             Epoch seconds to treat as "now" (countdowns).
#   Every one of these exists so .claude/scripts/tests/ai-quotas.test.sh can
#   drive each path against stubs without a live account, network, or
#   keychain. They are not meant for normal use.
#
# EXIT STATUS
#   0   The report was produced. A `needs-login`, `rate-limited`,
#       `unreachable`, or `unsupported` ROW is not a failure: this is a
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
#   - .claude/scripts/lib/bounded-run.sh (sibling library) for the local CLI
#     probes, which must not hang the report
#
# SEE ALSO
#   .claude/reference/ai-quotas.md   registry schema, reader contract
#   .claude/skills/quotas/SKILL.md   the /quotas surface
#   ai-quotas-setup.sh --help        registering and re-logging in accounts

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
            and (.profile_dir | type == "string" and length > 0)))' >/dev/null 2>&1 \
    || die 5 "registry is not valid ai-quotas JSON — every account needs a non-empty string provider, label, and profile_dir: $CONFIG_FILE"
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
now_epoch() {
  if [[ -n "${AI_QUOTAS_NOW:-}" ]]; then
    if [[ "$AI_QUOTAS_NOW" =~ ^[0-9]+$ ]]; then printf '%s' "$AI_QUOTAS_NOW"; return 0; fi
    warn "ignoring AI_QUOTAS_NOW='${AI_QUOTAS_NOW}' — not epoch seconds; using the real clock"
  fi
  date -u +%s
}

NOW="$(now_epoch)"
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
# One shape for every provider, so #1668's cursor reader and #1669's overage
# column add a field rather than a second renderer.

# Every numeric conversion below is guarded. A bare `tonumber` on an
# unexpected value — a percentage that arrived as "64%", a reset that arrived
# as an ISO string — aborts jq, and an aborted jq writes NO ROW: the account
# would vanish from a report whose entire promise is that every account gets
# one. A value this reader cannot turn into a number becomes `null`, which
# the table renders as `-` and nobody mistakes for zero usage.
emit_row() { # <provider> <label> <email> <window> <used_pct|""> <resets_epoch|""> <status> <detail> <source> <plan>
  local used="${5:-}" resets="${6:-}"
  jq -nc \
    --arg provider "$1" --arg label "$2" --arg email "$3" --arg window "$4" \
    --arg used "$used" --arg resets "$resets" \
    --arg status "$7" --arg detail "${8:-}" --arg source "${9:-}" --arg plan "${10:-}" \
    --arg et "$(epoch_to_et "$resets")" --arg in "$(countdown "$resets")" \
    '{provider: $provider,
      label: $label,
      reported_email: (if $email == "" then $label else $email end),
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
      plan: (if $plan == "" then null else $plan end)}' >> "$ROWS"
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
  kill "$srv" 2>/dev/null || true
  wait "$srv" 2>/dev/null || true

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
codex_render_snapshot() { # <label> <email> <snapshot-json-file> <source> [<note>]
  local label="$1" email="$2" snap="$3" source="$4"
  local note="${5:-}"
  local plan weekly five rendered=0 weekly_ok=0 used resets dur

  plan="$(jq -r '.planType // empty' "$snap" 2>/dev/null || true)"
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
      detail="${note:+${note}; }no 7-day window reported; showing the longest window this plan reports"
    else
      window="window"
      detail="${note:+${note}; }this plan did not report the window's duration"
    fi
    emit_row codex "$label" "$email" "$window" "$used" "$resets" ok "$detail" "$source" "$plan"
    rendered=1
    weekly_ok=1
  fi

  if [[ "$FIVE_HOUR" -eq 1 ]]; then
    five="$(jq -c '[.primary, .secondary] | map(select(. != null))
                   | map(select(.windowDurationMins != null and .windowDurationMins < 10080))
                   | sort_by(.windowDurationMins) | first // empty' "$snap" 2>/dev/null || true)"
    if [[ -n "$five" ]]; then
      used="$(printf '%s' "$five" | jq -r '.usedPercent // empty')"
      resets="$(to_epoch_maybe "$(printf '%s' "$five" | jq -r '.resetsAt // empty')")"
      dur="$(printf '%s' "$five" | jq -r '.windowDurationMins // empty')"
      local flabel="5-hour"
      [[ -n "$dur" && "$dur" != "300" ]] && flabel="$(( dur / 60 ))-hour"
      emit_row codex "$label" "$email" "$flabel" "$used" "$resets" ok "$note" "$source" "$plan"
      rendered=1
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
        "${note:+${note}; }this plan reports no short window" "$source" "$plan"
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
    cursor)
      emit_row cursor "$LABEL" "" "7-day" "" "" unsupported \
        "not yet — the Cursor reader arrives in increment 3 (issue #1668)" "" ""
      ;;
    *)
      emit_row "$PROVIDER" "$LABEL" "" "7-day" "" "" unsupported \
        "this reader knows claude and codex; '${PROVIDER}' is not one of them" "" ""
      ;;
  esac
done

if [[ "$COUNT" -eq 0 ]]; then
  if [[ "$JSON" -eq 1 ]]; then echo "[]"; else
    echo "No accounts registered yet."
    echo "Register one with: /quotas-setup add <claude|codex|cursor> <label>"
  fi
  exit 0
fi

if [[ "$MATCHED" -eq 0 ]]; then
  if [[ "$JSON" -eq 1 ]]; then echo "[]"; else
    echo "No registered account matches --account '${ACCOUNT_FILTER}'."
    echo "List the registered accounts with: /quotas-setup list"
  fi
  exit 0
fi

if [[ "$JSON" -eq 1 ]]; then
  jq -s '.' "$ROWS"
  exit 0
fi

{
  printf 'ACCOUNT\tPROVIDER\tWINDOW\tUSED\tREMAIN\tRESETS (ET)\tIN\tSTATUS\tNOTE\n'
  jq -r '
    def pct: if . == null then "-" else "\(.)%" end;
    def dash: if . == null or . == "" then "-" else . end;
    [ .reported_email,
      .provider,
      .window,
      (.used_pct | pct),
      (.remaining_pct | pct),
      (.resets_at_et | dash),
      (.countdown | dash),
      .status,
      ([ (if .label != .reported_email then "registered as \(.label)" else empty end),
         (.plan | if . == null then empty else "plan \(.)" end),
         (.source | if . == null then empty else "via \(.)" end),
         (.detail | if . == null or . == "" then empty else . end) ]
       | join("; ") | if . == "" then "-" else . end)
    ] | @tsv' "$ROWS"
} | column -t -s $'\t' 2>/dev/null || {
  printf 'ACCOUNT\tPROVIDER\tWINDOW\tUSED\tREMAIN\tRESETS (ET)\tIN\tSTATUS\tNOTE\n'
  cat "$ROWS"
}

echo
echo "Display only — never a dispatch or spend gate (.claude/rules/safety.md §Anthropic Quota & Spend Authority)."
exit 0
