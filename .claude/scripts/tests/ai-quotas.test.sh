#!/usr/bin/env bash
# ai-quotas.test.sh — coverage for .claude/scripts/ai-quotas.sh (issue #1667).
# catalog: tests — Tests `ai-quotas.sh` — the multi-account table and `--json` row shape, weekly-window selection by `windowDurationMins` (asserted with the weekly figures in `primary`, the shape a Pro account really returns), `--five-hour`, per-row isolation of `needs-login`/`rate-limited`/`unreachable`/`unsupported`, the unrecognised-shape path printing the keys it saw instead of 0 %, deterministic ET reset + countdown against a frozen clock, and the leak assertions that no credential value reaches stdout, stderr, or the usage log
#
# WHAT IS UNDER TEST
#
# The reader's job is to answer "which account has room this week" without
# ever leaking a credential and without ever aborting the whole report
# because one account is broken. So the properties asserted here are:
# per-row independence, honest statuses, correct window SELECTION (not
# position), a stable JSON row shape, and no credential value anywhere in the
# output.
#
# EVERY EXTERNAL COMMAND IS A STUB. No real network, keychain, codex, or
# claude is touched: `curl`, `security`, `codex`, and `claude` are fake
# binaries in a scratch dir, reached through the script's own *_BIN seams.
# Each fake dispatches on its arguments and HARD-FAILS on a call it does not
# recognise, so a reader that starts making an unexpected call reddens the
# suite instead of silently passing.
#
# DISCRIMINATING FIXTURES. Every stub credential is a real-shaped secret
# (`sk-ant-…`, a `eyJ…` JWT), so the leak assertions are genuine detectors:
# a reader that echoed the Authorization header, logged the token, or copied
# `auth.json` into a note would fail them. Fixtures without that shape would
# pass for the wrong reason.
#
# THE CLOCK IS FROZEN (AI_QUOTAS_NOW) and every reset timestamp is expressed
# relative to it, so the ET-formatting and countdown assertions are exact
# rather than "looks about right", and they do not rot as the fixtures age.
#
# Run from anywhere: bash .claude/scripts/tests/ai-quotas.test.sh

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="$ROOT/.claude/scripts/ai-quotas.sh"

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

# Credential-SHAPED secrets. These are what make the leak assertions real.
CLAUDE_SECRET="sk-ant-oat01-FAKE-TOKEN-9Z8Y7X"
CODEX_SECRET="FAKE-CODEX-ACCESS-TOKEN-5W4V3U"
# A JWT whose payload is {"email":"codex-one@example.com"} — the reader has
# to base64url-decode the middle segment to render the reported email, and
# must not print the token itself.
CODEX_JWT_HEADER="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"
CODEX_JWT_PAYLOAD="$(printf '{"email":"codex-one@example.com"}' | jq -Rr '@base64' | tr -d '=' | tr '/+' '_-')"
CODEX_JWT="${CODEX_JWT_HEADER}.${CODEX_JWT_PAYLOAD}.FAKESIG"

# Frozen clock: 2026-09-08T20:00:00Z — a Tuesday, 4:00 PM EDT.
NOW=1788897600
WEEK_RESET=$(( NOW + 2 * 86400 + 4 * 3600 ))   # +2d 4h
FIVE_RESET=$(( NOW + 37 * 60 ))                # +37m
PAST_RESET=$(( NOW - 3600 ))                   # already elapsed

BIN="$TMP/bin"
mkdir -p "$BIN"

# --- stub: curl --------------------------------------------------------------
# Understands only the two calls the reader makes. The Authorization header
# arrives on stdin (`-K -`), never in argv — the stub ASSERTS that by failing
# if it ever sees a bearer token in its arguments.
cat > "$BIN/curl" <<'EOF'
#!/usr/bin/env bash
out=""; dump=""; url=""; ua=""
args="$*"
case "$args" in
  *"Bearer"*) echo "STUB-CURL: a bearer token reached argv" >&2; exit 90 ;;
esac
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -D) dump="$2"; shift 2 ;;
    -H) case "$2" in User-Agent:*) ua="$2" ;; esac; shift 2 ;;
    -K) shift 2 ;;
    -w|--max-time) shift 2 ;;
    -sS) shift ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
# Drain the config on stdin so the writer never takes SIGPIPE.
cat > "$STUB_CURL_STDIN" 2>/dev/null || true
printf '%s\t%s\n' "$url" "$ua" >> "$STUB_CURL_LOG"
: > "${dump:-/dev/null}"
case "$url" in
  *anthropic*)
    mode="$(cat "$STUB_ANTHROPIC_MODE" 2>/dev/null || echo ok)"
    case "$mode" in
      ok)        cat "$STUB_ANTHROPIC_BODY" > "$out"; printf '200' ;;
      shape)     cat "$STUB_ANTHROPIC_BODY" > "$out"; printf '200' ;;
      ratelimit) printf '{"error":"rate_limited"}' > "$out"
                 printf 'HTTP/2 429\r\nretry-after: 1800\r\n' > "${dump:-/dev/null}"
                 printf '429' ;;
      unauth)    printf '{"error":"unauthorized"}' > "$out"; printf '401' ;;
      down)      echo "STUB-CURL: simulated network failure" >&2; exit 7 ;;
      *) echo "STUB-CURL: unknown anthropic mode '$mode'" >&2; exit 91 ;;
    esac
    ;;
  *chatgpt*)
    cat "$STUB_CHATGPT_BODY" > "$out"; printf '200'
    ;;
  *)
    echo "STUB-CURL: unexpected url '$url'" >&2; exit 92 ;;
esac
exit 0
EOF

# --- stub: security ----------------------------------------------------------
# A flat file of "service<TAB>value" rows. `-w` is a supported mode here
# (unlike the setup suite's stub) because reading the token IS this script's
# job — but every request is logged, so the suite can assert the reader asked
# only for the services it had a right to.
cat > "$BIN/security" <<'EOF'
#!/usr/bin/env bash
want=""; want_value=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -s) want="${2:-}"; shift 2 ;;
    -w) want_value=1; shift ;;
    *) shift ;;
  esac
done
[[ -n "$want" ]] || exit 1
printf '%s\t%s\n' "$want" "$want_value" >> "$STUB_SECURITY_LOG"
line="$(grep -F "$want	" "$STUB_KEYCHAIN_DB" 2>/dev/null | head -n 1)"
[[ -n "$line" ]] || exit 44
if [[ "$want_value" -eq 1 ]]; then printf '%s\n' "${line#*	}"; fi
exit 0
EOF

# --- stub: codex -------------------------------------------------------------
# Speaks just enough JSON-RPC over stdio: answers `initialize`, ignores
# `initialized`, and answers `account/rateLimits/read` from the fixture named
# by this CODEX_HOME. A CODEX_HOME with no fixture exits non-zero, which is
# what an unusable profile looks like.
cat > "$BIN/codex" <<'EOF'
#!/usr/bin/env bash
printf '%s\t%s\n' "${CODEX_HOME:-<unset>}" "$*" >> "$STUB_CALL_LOG"
case "${1:-}" in
  login)
    [[ -s "${CODEX_HOME:-}/auth.json" ]] && exit 0
    exit 1
    ;;
  app-server) : ;;
  *) echo "STUB-CODEX: unexpected subcommand '${1:-}'" >&2; exit 93 ;;
esac
fixture="${CODEX_HOME}/rate-limits.json"
if [[ ! -s "$fixture" ]]; then
  echo "STUB-CODEX: no app-server fixture for $CODEX_HOME" >&2
  exit 94
fi
while IFS= read -r line; do
  case "$line" in
    *'"initialize"'*)
      printf '{"id":1,"result":{"userAgent":"stub","codexHome":"%s"}}\n' "$CODEX_HOME"
      ;;
    *'"initialized"'*) : ;;
    *'account/rateLimits/read'*)
      # JSON permits whitespace around the name separator. STUB_CODEX_SPACED_ID
      # makes this stub emit the equally-valid `"id" : 2` so the reader's match
      # is exercised against a serialization it does not itself produce. It
      # governs BOTH lines below: leaving the duplicate compact would let a
      # reader that only matches the compact form pass on that line, and the
      # case would assert nothing.
      #
      # Each branch emits a SECOND id:2 line, so the reader's "take the first
      # match" really is exercised rather than assumed from a single-line
      # stream. It pins the SELECTION; it does not reproduce the SIGPIPE timing
      # that motivated moving that selection inside jq (measured: with payloads
      # this small jq finishes writing before `head` closes the pipe, so the old
      # `| head -n 1` under `pipefail` passed here too). The jq-only form is
      # kept because it cannot depend on that timing at all.
      if [[ -n "${STUB_CODEX_SPACED_ID:-}" ]]; then
        printf '{"id" : 2, "result" : %s}\n' "$(cat "$fixture")"
        printf '{"id" : 2, "result" : %s}\n' '{"note":"duplicate response"}'
      else
        printf '{"id":2,"result":%s}\n' "$(cat "$fixture")"
        printf '{"id":2,"result":%s}\n' '{"note":"duplicate response"}'
      fi
      ;;
    *) echo "STUB-CODEX: unexpected request: $line" >&2; exit 95 ;;
  esac
done
exit 0
EOF

# --- stub: claude ------------------------------------------------------------
cat > "$BIN/claude" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  --version) echo "2.4.1 (Claude Code)"; exit 0 ;;
  *) echo "STUB-CLAUDE: unexpected argument '${1:-}'" >&2; exit 96 ;;
esac
EOF

chmod +x "$BIN"/*

# --- harness -----------------------------------------------------------------

export STUB_CALL_LOG="$TMP/calls.log"
export STUB_CURL_LOG="$TMP/curl.log"
export STUB_CURL_STDIN="$TMP/curl.stdin"
export STUB_SECURITY_LOG="$TMP/security.log"
export STUB_KEYCHAIN_DB="$TMP/keychain.db"
export STUB_ANTHROPIC_BODY="$TMP/anthropic.json"
export STUB_ANTHROPIC_MODE="$TMP/anthropic.mode"
export STUB_CHATGPT_BODY="$TMP/chatgpt.json"

CASE_HOME="$TMP/home"
mkdir -p "$CASE_HOME/.claude"
CONFIG="$TMP/ai-quotas.json"
PROFILES="$TMP/profiles"

anthropic_body() { # <opus:0|1>
  local opus="$1"
  jq -n --argjson week "$WEEK_RESET" --argjson five "$FIVE_RESET" --argjson opus "$opus" \
    '{account: {email_address: "claude-one@example.com"},
      five_hour: {utilization: 12, resets_at: ($five | todate)},
      seven_day: {utilization: 64, resets_at: ($week | todate)}}
     + (if $opus == 1 then {seven_day_opus: {utilization: 31, resets_at: ($week | todate)}} else {} end)'
}

# The weekly figures go in `primary` with `secondary` null — the shape a Pro
# account really returns (measured 2026-09-07). A reader that took
# `secondary` as "the weekly one" would render nothing here, so this fixture
# is what makes the duration-based selection assertion discriminating.
codex_snapshot_primary_weekly() {
  jq -n --argjson week "$WEEK_RESET" \
    '{rateLimits: {limitId: "codex", planType: "pro",
                   primary: {usedPercent: 71, windowDurationMins: 10080, resetsAt: $week},
                   secondary: null}}'
}

# Both windows present, weekly in `secondary` — the other plan shape.
codex_snapshot_both() {
  jq -n --argjson week "$WEEK_RESET" --argjson five "$FIVE_RESET" \
    '{rateLimits: {limitId: "codex", planType: "plus",
                   primary: {usedPercent: 9, windowDurationMins: 300, resetsAt: $five},
                   secondary: {usedPercent: 45, windowDurationMins: 10080, resetsAt: $week}}}'
}

seed_claude_profile() { # <label> <keychain-service|"">
  # Declared separately on purpose: `local a="$1" b="$PROFILES/$a"` expands
  # every argument BEFORE any of them is assigned, so `$a` is still unset.
  local label="$1"
  local service="$2"
  local dir="$PROFILES/$label/claude"
  mkdir -p "$dir"
  if [[ -n "$service" ]]; then
    printf '%s\t{"claudeAiOauth":{"accessToken":"%s"}}\n' "$service" "$CLAUDE_SECRET" >> "$STUB_KEYCHAIN_DB"
  fi
  printf '%s' "$dir"
}

seed_codex_profile() { # <label> <snapshot-json|"">
  local label="$1"
  local snapshot="$2"
  local dir="$PROFILES/$label/codex"
  mkdir -p "$dir"
  if [[ -n "$snapshot" ]]; then
    jq -n --arg t "$CODEX_SECRET" --arg id "$CODEX_JWT" \
      '{auth_mode:"chatgpt", tokens:{id_token:$id, access_token:$t, account_id:"acct-123"}}' \
      > "$dir/auth.json"
    printf '%s' "$snapshot" > "$dir/rate-limits.json"
  fi
  printf '%s' "$dir"
}

write_config() { # <account-json…>
  local acc="[]" a
  for a in "$@"; do
    acc="$(printf '%s' "$acc" | jq --argjson e "$a" '. += [$e]')"
  done
  printf '%s' "$acc" | jq '{schema_version: "1.0", accounts: .}' > "$CONFIG"
}

account_json() { # <provider> <label> <dir> [<service>]
  jq -n --arg p "$1" --arg l "$2" --arg d "$3" --arg s "${4:-}" \
    '{provider: $p, label: $l, profile_dir: $d, added_at: "2026-09-07T00:00:00Z"}
     + (if $s == "" then {} else {credential_ref: {kind: "macos-keychain", service: $s}} end)'
}

OUT=""
ERR=""
RC=0

run() { # <args…> — never aborts the suite; sets OUT, ERR, RC
  local errf="$TMP/run.err"
  OUT="$(HOME="$CASE_HOME" \
        AI_QUOTAS_CONFIG="$CONFIG" \
        AI_QUOTAS_PLATFORM="Darwin" \
        AI_QUOTAS_NOW="$NOW" \
        AI_QUOTAS_CURL_BIN="$BIN/curl" \
        AI_QUOTAS_SECURITY_BIN="$BIN/security" \
        AI_QUOTAS_CODEX_BIN="$BIN/codex" \
        AI_QUOTAS_CLAUDE_BIN="$BIN/claude" \
        AI_QUOTAS_CODEX_TIMEOUT="10" \
        "$SCRIPT" "$@" 2>"$errf")"
  RC=$?
  ERR="$(cat "$errf")"
}

rows_for() { # <label> — one status per line, in row order
  printf '%s' "$OUT" | jq -r --arg l "$1" '.[] | select(.label == $l) | .status'
}

field_of() { # <label> <window> <field>
  printf '%s' "$OUT" | jq -r --arg l "$1" --arg w "$2" --arg f "$3" \
    '.[] | select(.label == $l and .window == $w) | .[$f] | if . == null then "null" else tostring end'
}

reset_state() {
  : > "$STUB_CALL_LOG"; : > "$STUB_CURL_LOG"; : > "$STUB_SECURITY_LOG"
  : > "$STUB_KEYCHAIN_DB"; : > "$STUB_CURL_STDIN"
  rm -rf "$PROFILES"; mkdir -p "$PROFILES"
  rm -rf "$CASE_HOME"; mkdir -p "$CASE_HOME/.claude"
  echo "ok" > "$STUB_ANTHROPIC_MODE"
  anthropic_body 0 > "$STUB_ANTHROPIC_BODY"
  jq -n '{}' > "$STUB_CHATGPT_BODY"
}
reset_state

echo "== ai-quotas.sh =="

# --- 1. --help contract ------------------------------------------------------

HELP_ERR="$TMP/help.err"
HELP_OUT="$(HOME="$CASE_HOME" "$SCRIPT" --help 2>"$HELP_ERR")"
check_eq "$?" "0" "--help exits 0"
check_contains "$HELP_OUT" "ai-quotas.sh" "--help names the script"
check_contains "$HELP_OUT" "EXIT STATUS" "--help carries the exit-status section"
check_contains "$HELP_OUT" "DEPENDENCIES" "--help carries the dependencies section"
check_eq "$(wc -c < "$HELP_ERR" | tr -d ' ')" "0" "--help writes nothing to stderr"

# --- 2. usage errors ---------------------------------------------------------

run --nonsense
check_eq "$RC" "3" "an unknown flag exits 3"
run --account
check_eq "$RC" "3" "--account with no label exits 3"

# --- 3. empty registry -------------------------------------------------------

reset_state
write_config
run
check_eq "$RC" "0" "an empty registry exits 0"
check_contains "$OUT" "No accounts registered yet." "and says so"
run --json
check_eq "$OUT" "[]" "--json on an empty registry is an empty array"

# --- 4. a broken registry is a broken TOOL, not a verdict --------------------

reset_state
printf 'not json at all\n' > "$CONFIG"
run
check_eq "$RC" "5" "an unparseable registry exits 5"
write_config
jq '.schema_version = "2.0"' "$CONFIG" > "$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG"
run
check_eq "$RC" "5" "a different schema major exits 5 rather than being guessed at"

# --- 5. the acceptance table: two claude + two codex accounts ----------------

reset_state
C1="$(seed_claude_profile claude-one@example.com "Claude Code-credentials-AAA")"
C2="$(seed_claude_profile claude-two@example.com "Claude Code-credentials-BBB")"
X1="$(seed_codex_profile codex-one@example.com "$(codex_snapshot_primary_weekly)")"
X2="$(seed_codex_profile codex-two@example.com "$(codex_snapshot_both)")"
write_config \
  "$(account_json claude claude-one@example.com "$C1" "Claude Code-credentials-AAA")" \
  "$(account_json claude claude-two@example.com "$C2" "Claude Code-credentials-BBB")" \
  "$(account_json codex codex-one@example.com "$X1")" \
  "$(account_json codex codex-two@example.com "$X2")"

run --json
check_eq "$RC" "0" "four registered accounts exit 0"
check_eq "$(printf '%s' "$OUT" | jq 'length')" "4" "four weekly rows, one per account"
check_eq "$(printf '%s' "$OUT" | jq -r '[.[] | select(.status == "ok")] | length')" "4" \
  "every row reads ok"
check_eq "$(field_of claude-one@example.com "7-day" used_pct)" "64" "the claude weekly used % comes from seven_day"
check_eq "$(field_of claude-one@example.com "7-day" remaining_pct)" "36" "remaining % is 100 - used"

# The whole point of selecting by windowDurationMins: this account reports
# its weekly figures in `primary` with `secondary` null. A position-based
# reader renders nothing here.
check_eq "$(field_of codex-one@example.com "7-day" used_pct)" "71" \
  "the codex weekly window is found in primary when secondary is null"
check_eq "$(field_of codex-two@example.com "7-day" used_pct)" "45" \
  "and in secondary when that is where the 10080-minute window lives"
check_eq "$(field_of codex-two@example.com "7-day" plan)" "plus" "planType is reported"
check_eq "$(field_of codex-one@example.com "7-day" source)" "app-server" \
  "the row says which path produced it"

# Reported email, not the label: this is what makes a mislabelled account
# visible. The codex fixture's JWT carries a DIFFERENT address from its label
# only for the claude accounts, so assert both directions.
check_eq "$(field_of codex-one@example.com "7-day" reported_email)" "codex-one@example.com" \
  "the codex row is labelled with the email the id_token reports"
check_eq "$(field_of claude-two@example.com "7-day" reported_email)" "claude-one@example.com" \
  "a claude row carries the email the provider reports, even when it differs from the label"

# The reader must ask the Keychain for exactly the services the registry
# recorded for these two accounts — no more. The stub logs every lookup, so
# a reader that started probing for a derived or guessed service name (the
# thing #1666 deliberately does not do) reddens this.
check_eq "$(cut -f1 "$STUB_SECURITY_LOG" | sort -u | tr '\n' '|')" \
  "Claude Code-credentials-AAA|Claude Code-credentials-BBB|" \
  "the reader asked the keychain only for the two services the registry records"

# --- 6. opus adds a fifth weekly row -----------------------------------------

anthropic_body 1 > "$STUB_ANTHROPIC_BODY"
run --json
check_eq "$(printf '%s' "$OUT" | jq 'length')" "6" \
  "seven_day_opus adds one more weekly row per claude account"
check_eq "$(field_of claude-one@example.com "7-day (opus)" used_pct)" "31" \
  "the opus row carries its own utilization"
anthropic_body 0 > "$STUB_ANTHROPIC_BODY"

# --- 7. reset time in ET, and the countdown ----------------------------------

run --json
check_eq "$(field_of claude-one@example.com "7-day" resets_at_epoch)" "$WEEK_RESET" \
  "the weekly reset is carried as epoch seconds"
check_eq "$(field_of claude-one@example.com "7-day" countdown)" "in 2d 4h" \
  "the countdown is rendered against the frozen clock"
check_contains "$(field_of claude-one@example.com "7-day" resets_at_et)" "EDT" \
  "the reset time is rendered in Eastern"

# A reset expressed with a numeric offset rather than `Z`. GNU `date -d`
# takes it either way; BSD needs its own format, so without the offset-aware
# second attempt the SAME payload yields a time on Linux and a bare `-` on
# macOS — the fleet's primary platform. This fixture uses `+00:00` stripped
# to a non-UTC-looking offset so the assertion cannot pass by accident on the
# `…Z` path.
OFFSET_ISO="$(TZ=UTC jq -rn --argjson e "$WEEK_RESET" '($e - 18000 | todate | sub("Z$"; "-05:00"))')"
jq -n --arg off "$OFFSET_ISO" \
  '{account: {email_address: "claude-one@example.com"},
    seven_day: {utilization: 50, resets_at: $off}}' > "$STUB_ANTHROPIC_BODY"
run --json
check_eq "$(field_of claude-one@example.com "7-day" resets_at_epoch)" "$WEEK_RESET" \
  "a reset carrying a numeric UTC offset parses to the same instant on either date(1) dialect"
anthropic_body 0 > "$STUB_ANTHROPIC_BODY"

# An elapsed reset must read `reset`, not a negative countdown.
PAST_SNAP="$(jq -n --argjson past "$PAST_RESET" \
  '{rateLimits: {planType: "pro",
                 primary: {usedPercent: 99, windowDurationMins: 10080, resetsAt: $past},
                 secondary: null}}')"
printf '%s' "$PAST_SNAP" > "$X1/rate-limits.json"
run --json
check_eq "$(field_of codex-one@example.com "7-day" countdown)" "reset" \
  "an already-elapsed reset prints 'reset'"
printf '%s' "$(codex_snapshot_primary_weekly)" > "$X1/rate-limits.json"

# --- 8. --five-hour ----------------------------------------------------------

run --json --five-hour
check_eq "$(field_of claude-one@example.com "5-hour" used_pct)" "12" \
  "--five-hour adds the claude five-hour row"
check_eq "$(field_of claude-one@example.com "5-hour" countdown)" "in 37m" \
  "a sub-hour countdown is rendered in minutes"
check_eq "$(field_of codex-two@example.com "5-hour" used_pct)" "9" \
  "--five-hour adds the codex short window when the plan reports one"
# A single-window response is valid, not an error: the row is rendered and
# says why it has no figure, rather than silently disappearing.
check_eq "$(field_of codex-one@example.com "5-hour" status)" "ok" \
  "a plan with only a weekly window still renders its five-hour row"
check_eq "$(field_of codex-one@example.com "5-hour" used_pct)" "null" \
  "and reports no figure rather than a fabricated 0"

# --- 9. --account narrows the run --------------------------------------------

run --json --account codex-two@example.com
check_eq "$(printf '%s' "$OUT" | jq 'length')" "1" "--account renders only that account"
check_eq "$(printf '%s' "$OUT" | jq -r '.[0].label')" "codex-two@example.com" "and it is the right one"
run --json --account nobody@example.com
check_eq "$RC" "0" "--account naming no registered label still exits 0"
check_eq "$OUT" "[]" "and returns no rows"

# --- 10. per-row failure isolation -------------------------------------------
# The core promise: one broken account never suppresses the other three.

# A revoked claude login — the keychain item is gone.
reset_state
C1="$(seed_claude_profile claude-one@example.com "Claude Code-credentials-AAA")"
C2="$(seed_claude_profile claude-two@example.com "")"   # nothing in the keychain
X1="$(seed_codex_profile codex-one@example.com "$(codex_snapshot_primary_weekly)")"
X2="$(seed_codex_profile codex-two@example.com "")"     # empty CODEX_HOME
write_config \
  "$(account_json claude claude-one@example.com "$C1" "Claude Code-credentials-AAA")" \
  "$(account_json claude claude-two@example.com "$C2" "Claude Code-credentials-BBB")" \
  "$(account_json codex codex-one@example.com "$X1")" \
  "$(account_json codex codex-two@example.com "$X2")"

run --json
check_eq "$RC" "0" "a run with two broken accounts still exits 0 — this is a report, not a gate"
check_eq "$(printf '%s' "$OUT" | jq 'length')" "4" "all four rows render"
check_eq "$(rows_for claude-two@example.com)" "needs-login" "a revoked claude login reads needs-login"
check_eq "$(rows_for codex-two@example.com)" "needs-login" "an empty CODEX_HOME reads needs-login for that row only"
check_eq "$(rows_for claude-one@example.com)" "ok" "the healthy claude account still renders"
check_eq "$(rows_for codex-one@example.com)" "ok" "the healthy codex account still renders"
check_contains "$(field_of claude-two@example.com "7-day" detail)" \
  "/quotas-setup relogin claude-two@example.com claude" \
  "the needs-login note carries the exact relogin command"

# The table shows the same verdicts as --json (test-plan parity).
run
check_contains "$OUT" "needs-login" "the table renders the needs-login rows too"
check_contains "$OUT" "/quotas-setup relogin" "and the relogin command is in the table's note column"

# --- 11. rate limiting is not an auth failure --------------------------------

echo "ratelimit" > "$STUB_ANTHROPIC_MODE"
run --json
check_eq "$(rows_for claude-one@example.com)" "rate-limited" "a 429 reads rate-limited, not needs-login"
check_contains "$(field_of claude-one@example.com "7-day" detail)" "retry after 1800s" \
  "and the retry window is reported"
check_eq "$(rows_for codex-one@example.com)" "ok" "a claude 429 does not disturb the codex rows"

echo "unauth" > "$STUB_ANTHROPIC_MODE"
run --json
check_eq "$(rows_for claude-one@example.com)" "needs-login" "a 401 IS an auth failure and says so"

echo "down" > "$STUB_ANTHROPIC_MODE"
run --json
check_eq "$(rows_for claude-one@example.com)" "unreachable" "a network failure reads unreachable"
echo "ok" > "$STUB_ANTHROPIC_MODE"

# --- 12. an unrecognised shape prints the keys, never 0 % --------------------

jq -n '{quota_summary: {}, meta: {}}' > "$STUB_ANTHROPIC_BODY"
run --json
check_eq "$(rows_for claude-one@example.com)" "unreachable" \
  "a response with no known window is unreachable, not a silent success"
check_eq "$(field_of claude-one@example.com "7-day" used_pct)" "null" \
  "and reports no figure rather than 0 %"
check_contains "$(field_of claude-one@example.com "7-day" detail)" "quota_summary, meta" \
  "the note prints the top-level keys it actually saw"
anthropic_body 0 > "$STUB_ANTHROPIC_BODY"

# --- 13. cursor is unsupported, not broken -----------------------------------

reset_state
CUR="$PROFILES/cursor-one@example.com/cursor"; mkdir -p "$CUR"
X1="$(seed_codex_profile codex-one@example.com "$(codex_snapshot_primary_weekly)")"
write_config \
  "$(account_json cursor cursor-one@example.com "$CUR")" \
  "$(account_json codex codex-one@example.com "$X1")"
run --json
check_eq "$RC" "0" "a cursor row does not fail the run"
check_eq "$(rows_for cursor-one@example.com)" "unsupported" "the cursor row reads unsupported"
check_contains "$(field_of cursor-one@example.com "7-day" detail)" "not yet" \
  "and says 'not yet' rather than pretending to a figure"
check_eq "$(rows_for codex-one@example.com)" "ok" "the codex row beside it still renders"

# --- 14. the codex HTTP fallback, and only when app-server is unavailable ----

reset_state
X1="$(seed_codex_profile codex-one@example.com "$(codex_snapshot_primary_weekly)")"
write_config "$(account_json codex codex-one@example.com "$X1")"
run --json
check_eq "$(field_of codex-one@example.com "7-day" source)" "app-server" \
  "with app-server available, no HTTP call is made"
check_eq "$(grep -c chatgpt "$STUB_CURL_LOG" 2>/dev/null || true)" "0" \
  "control(-): the fallback endpoint is not touched on the app-server path"

# Remove the app-server fixture: the stub then exits non-zero, which is what
# "app-server unavailable" looks like from the reader's side.
rm -f "$X1/rate-limits.json"
jq -n --argjson week "$WEEK_RESET" \
  '{rate_limits: {planType: "pro",
                  primary: {usedPercent: 88, windowDurationMins: 10080, resetsAt: $week},
                  secondary: null}}' > "$STUB_CHATGPT_BODY"
run --json
check_eq "$(field_of codex-one@example.com "7-day" source)" "http" \
  "an unavailable app-server falls back to the HTTP path"
check_eq "$(field_of codex-one@example.com "7-day" used_pct)" "88" \
  "and renders the fallback's figures"
check_contains "$(field_of codex-one@example.com "7-day" detail)" "app-server" \
  "the note says why the fallback was used"
# …and says WHICH failure it was. The stub exits non-zero without answering,
# which is not a timeout; reporting one would send the reader after a hang
# that never happened.
check_contains "$(field_of codex-one@example.com "7-day" detail)" "exited without answering" \
  "a server that exited is reported as an exit, not as a timeout"
check_not_contains "$(field_of codex-one@example.com "7-day" detail)" "did not answer within" \
  "control(-): the timeout wording is not used for a server that exited"

# --- 14a. a spaced `"id" : 2` is the same response, not a timeout ------------
# JSON puts no constraint on whitespace around the name separator, so a server
# is free to answer `"id" : 2`. A reader that matches only the compact form
# reads a perfectly good answer as silence, burns the whole CODEX_TIMEOUT, and
# degrades to the HTTP fallback with a timeout note — a wrong number's worth of
# wrong, reported as if the server had hung.

reset_state
X1="$(seed_codex_profile codex-one@example.com "$(codex_snapshot_primary_weekly)")"
write_config "$(account_json codex codex-one@example.com "$X1")"
# The fallback body is deliberately DIFFERENT from the fixture, so an answer
# read off the HTTP path could not be mistaken for the app-server's.
jq -n --argjson week "$WEEK_RESET" \
  '{rate_limits: {planType: "pro",
                  primary: {usedPercent: 11, windowDurationMins: 10080, resetsAt: $week},
                  secondary: null}}' > "$STUB_CHATGPT_BODY"
STUB_CODEX_SPACED_ID=1 run --json
unset STUB_CODEX_SPACED_ID
check_eq "$(field_of codex-one@example.com "7-day" source)" "app-server" \
  "a spaced \`\"id\" : 2\` is still read off app-server, not fallen back on"
check_not_contains "$(field_of codex-one@example.com "7-day" detail)" "did not answer within" \
  "control(-): a spaced id is not reported as a timeout"
check_eq "$(field_of codex-one@example.com "7-day" used_pct)" "71" \
  "control(+): the figures are the fixture's 71, not the HTTP body's 11"

# --- 14b. --five-hour must not mask an unreadable codex payload -------------
# A payload with no windows at all is an unrecognised SHAPE. Rendering "this
# plan reports no short window" for it would state a fact about the plan
# nobody established, and would mark the read successful — so the flag would
# SUPPRESS the unreachable row the same payload produces without it.

# This case is about the HTTP payload, so it has to be the HTTP path that runs.
# Removing the fixture here rather than inheriting test 14's removal is what
# keeps the premise the case's own: with app-server answering, the reader never
# reaches the body below and all three checks pass on the wrong path.
rm -f "$X1/rate-limits.json"
jq -n '{something_else: {}, other: 1}' > "$STUB_CHATGPT_BODY"
run --json --five-hour
check_eq "$(rows_for codex-one@example.com)" "unreachable" \
  "an unreadable payload is unreachable even under --five-hour"
check_contains "$(field_of codex-one@example.com "7-day" detail)" "something_else, other" \
  "and the note still prints the keys it saw"
run --json
check_eq "$(rows_for codex-one@example.com)" "unreachable" \
  "control(+): the same payload is unreachable without the flag too"

# --- 15. no credential value reaches stdout, stderr, or any log --------------
# Cumulative and last, so it covers every case above.

reset_state
C1="$(seed_claude_profile claude-one@example.com "Claude Code-credentials-AAA")"
X1="$(seed_codex_profile codex-one@example.com "$(codex_snapshot_primary_weekly)")"
write_config \
  "$(account_json claude claude-one@example.com "$C1" "Claude Code-credentials-AAA")" \
  "$(account_json codex codex-one@example.com "$X1")"

run --five-hour
COMBINED="$OUT
$ERR"
check_eq "$(printf '%s' "$COMBINED" | grep -cE 'Bearer|sk-ant|eyJ' || true)" "0" \
  "no Bearer header, sk-ant token, or JWT appears in stdout or stderr"
check_not_contains "$COMBINED" "$CLAUDE_SECRET" "the claude token value never reaches the output"
check_not_contains "$COMBINED" "$CODEX_SECRET" "the codex token value never reaches the output"

run --json --five-hour
COMBINED="$OUT
$ERR"
check_eq "$(printf '%s' "$COMBINED" | grep -cE 'Bearer|sk-ant|eyJ' || true)" "0" \
  "and none appears in --json output either"

USAGE_LOG="$CASE_HOME/.claude/script-usage.log"
if [[ -s "$USAGE_LOG" ]]; then
  check_not_contains "$(cat "$USAGE_LOG")" "@example.com" \
    "the usage log records the action word only, never the account label"
  check_not_contains "$(cat "$USAGE_LOG")" "$CLAUDE_SECRET" \
    "and never a credential value"
else
  bad "the usage log was not written — the telemetry line is part of the contract"
fi

# The stub curl exits 90 the moment a bearer token appears in argv, so a
# clean run is itself the assertion that the token went in on stdin. Assert
# the config actually carried it, or the check above would pass vacuously on
# a reader that sent no Authorization header at all.
check_contains "$(cat "$STUB_CURL_STDIN" 2>/dev/null || true)" "Authorization: Bearer" \
  "control(+): the Authorization header really was sent — on stdin, not in argv"

# --- summary -----------------------------------------------------------------

echo
echo "passed: $PASS   failed: $FAILED"
[[ "$FAILED" -eq 0 ]] || exit 1
exit 0
