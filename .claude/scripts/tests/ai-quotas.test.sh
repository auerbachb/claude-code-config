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
# The header of the id_token each codex profile carries. The payload is built
# per profile by `seed_codex_profile` from that account's own email — the
# reader has to base64url-decode the middle segment to render the reported
# email, and must not print the token itself. `eyJ` is what the leak
# assertions scan for, so this prefix is load-bearing: a real JWT starts with
# exactly these characters.
CODEX_JWT_HEADER="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"

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
# STUB_CODEX_IGNORE_TERM models a server that does not honour SIGTERM: it
# ignores the signal and, once the reader closes the pipe, lingers instead of
# exiting. The linger is BOUNDED so a reader that waits unconditionally shows up
# as a slow test rather than a suite that never returns — a test whose failure
# mode is a hang cannot report anything.
if [[ -n "${STUB_CODEX_IGNORE_TERM:-}" ]]; then
  trap '' TERM INT
fi
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
# EOF on the pipe is the reader closing it, which normally ends this stub. In
# ignore-term mode it lingers instead, so the reader's cleanup has something
# that outlives SIGTERM to reap.
[[ -n "${STUB_CODEX_IGNORE_TERM:-}" ]] && sleep 30
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

# The reported email is derived from the profile, not shared across them: a
# fixture where every codex account claims to be codex-one@example.com makes
# each extra account look MISLABELLED to the reader, which decorates its row
# with a `registered as <label>` note no real account would carry. Building the
# JWT from the argument leaves the default byte-identical to the shared one
# these cases used before, so every existing caller and every leak assertion is
# unaffected.
seed_codex_profile() { # <label> <snapshot-json|""> [<reported-email>]
  local label="$1"
  local snapshot="$2"
  local email="${3:-codex-one@example.com}"
  local payload jwt
  payload="$(printf '{"email":"%s"}' "$email" | jq -Rr '@base64' | tr -d '=' | tr '/+' '_-')"
  jwt="${CODEX_JWT_HEADER}.${payload}.FAKESIG"
  local dir="$PROFILES/$label/codex"
  mkdir -p "$dir"
  if [[ -n "$snapshot" ]]; then
    jq -n --arg t "$CODEX_SECRET" --arg id "$jwt" \
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
DOC=""
ERR=""
RC=0
# Empty means "let ai-quotas.sh resolve the helper itself". Only the
# degradation cases in section 16 set it.
CHEAPEST_BIN_OVERRIDE=""
# Same contract for the projection helper (#1701): empty means the reader
# resolves its own sibling, which is what every case below wants — the three
# columns are part of the table now, so a suite that stubbed them out would
# stop measuring the table the owner sees. Section 17i sets it to exercise the
# unavailable-helper path.
FORECAST_BIN_OVERRIDE=""

# The cursor node/helper paths below are PINNED, not overridable (CodeAnt, PR
# #1689). They used to read `${NODE_BIN_UNDER_TEST:-…}` and
# `${CURSOR_HELPER_UNDER_TEST:-…}`, but nothing in THIS suite ever sets either
# hook — so their only reachable effect was an ambient export from whatever
# environment the suite was launched in, which would point the cursor cases at a
# real node and a real helper and let assertions written for the
# missing-dependency path go to the network or open a browser. The suites that
# genuinely vary node (ai-quotas-cursor, ai-quotas-setup) set their own hook and
# reset it between cases; this one has no reason to.
run() { # <args…> — never aborts the suite; sets OUT, DOC, ERR, RC
  local errf="$TMP/run.err"
  OUT="$(HOME="$CASE_HOME" \
        CLAUDE_QUOTAS_STATE_DIR="$CASE_HOME/.claude/quotas" \
        CLAUDE_QUOTAS_CHEAPEST_NEXT_THRESHOLD_PCT="${QUOTAS_THRESHOLD_OVERRIDE-20}" \
        AI_QUOTAS_CONFIG="$CONFIG" \
        AI_QUOTAS_PLATFORM="Darwin" \
        AI_QUOTAS_NOW="$NOW" \
        AI_QUOTAS_CURL_BIN="$BIN/curl" \
        AI_QUOTAS_SECURITY_BIN="$BIN/security" \
        AI_QUOTAS_CODEX_BIN="$BIN/codex" \
        AI_QUOTAS_CLAUDE_BIN="$BIN/claude" \
        AI_QUOTAS_CODEX_TIMEOUT="${AI_QUOTAS_CODEX_TIMEOUT_OVERRIDE-10}" \
        AI_QUOTAS_CHEAPEST_BIN="${CHEAPEST_BIN_OVERRIDE-}" \
        AI_QUOTAS_FORECAST_BIN="${FORECAST_BIN_OVERRIDE-}" \
        AI_QUOTAS_NODE_BIN="$BIN/node-absent" \
        AI_QUOTAS_CURSOR_HELPER="$TMP/no-such-helper.js" \
        "$SCRIPT" "$@" 2>"$errf")"
  RC=$?
  ERR="$(cat "$errf")"
  # #1669 changed --json from a bare row ARRAY to a DOCUMENT — {schema_version,
  # threshold_pct, basis, rows, cheapest_next} — because `cheapest_next` is a
  # property of the whole report and an array had nowhere to put it. Nearly
  # every assertion in this suite is about the rows, so the document is kept
  # whole in DOC and OUT is narrowed to `.rows`; the overage and hint cases
  # assert against DOC.
  #
  # Narrowed ONLY when the output really is that document. A table run, or a
  # --json run that failed and printed a message, must reach the assertions
  # exactly as the script wrote it — a rewrite that "helpfully" applies to
  # everything is how an assertion starts passing against text nobody emitted.
  DOC=""
  if printf '%s' "$OUT" | jq -e 'type == "object" and has("rows") and has("cheapest_next")' >/dev/null 2>&1; then
    DOC="$OUT"
    OUT="$(printf '%s' "$DOC" | jq -c '.rows')"
  fi
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
check_eq "$OUT" "[]" "--json on an empty registry carries no rows"
# The empty exits emit the SAME document as a populated run (#1669) — not a
# bare `[]`. A consumer that had to special-case emptiness is a consumer that
# will eventually read a partial answer as a complete one.
check_eq "$(printf '%s' "$DOC" | jq -r 'type')" "object" \
  "and it is still the document object, not a bare array"
check_eq "$(printf '%s' "$DOC" | jq -r '.cheapest_next | tostring')" "null" \
  "with no cheapest-next hint, because there is nothing to compare"

# --- 4. a broken registry is a broken TOOL, not a verdict --------------------

reset_state
printf 'not json at all\n' > "$CONFIG"
run
check_eq "$RC" "5" "an unparseable registry exits 5"
write_config
jq '.schema_version = "2.0"' "$CONFIG" > "$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG"
run
check_eq "$RC" "5" "a different schema major exits 5 rather than being guessed at"

# A credential_ref of the wrong SHAPE is a broken registry too. Left unchecked
# it reaches the Keychain lookup as a jq type error, the service reads back
# empty, and the row says `needs-login` — blaming the account for the config.
reset_state
CR1="$PROFILES/claude-one@example.com/claude"; mkdir -p "$CR1"
write_config "$(account_json claude claude-one@example.com "$CR1")"
jq '.accounts[0].credential_ref = "Claude Code-credentials"' "$CONFIG" > "$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG"
run
check_eq "$RC" "5" "a credential_ref that is a string, not an object, exits 5"
check_not_contains "$OUT" "needs-login" \
  "control(-): and is not reported as an account that needs a re-login"
# The shape the reader actually indexes is still accepted, or the check above
# would pass on a reader that rejected every credential_ref.
reset_state
write_config "$(account_json claude claude-one@example.com "$CR1")"
jq '.accounts[0].credential_ref = {service: "Claude Code-credentials"}' "$CONFIG" > "$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG"
run
check_eq "$RC" "0" "control(+): a well-formed credential_ref object is still accepted"

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

# --- 13. a broken cursor account degrades alone ------------------------------
#
# The cursor READER has its own suite (ai-quotas-cursor.test.sh, issue #1668);
# what belongs here is the property this file is about — per-row isolation.
# With no helper on disk the cursor account cannot be read, and the assertion
# is that it says so in its own row and takes nothing else down with it.

reset_state
CUR="$PROFILES/cursor-one@example.com/cursor"; mkdir -p "$CUR"
X1="$(seed_codex_profile codex-one@example.com "$(codex_snapshot_primary_weekly)")"
write_config \
  "$(account_json cursor cursor-one@example.com "$CUR")" \
  "$(account_json codex codex-one@example.com "$X1")"
run --json
check_eq "$RC" "0" "a cursor row does not fail the run"
check_eq "$(rows_for cursor-one@example.com)" "unreachable" \
  "an unreadable cursor helper reads unreachable"
check_eq "$(field_of cursor-one@example.com "billing-cycle" used_pct)" "null" \
  "and reports no figure rather than 0 %"
check_contains "$(field_of cursor-one@example.com "billing-cycle" detail)" "helper is missing" \
  "the note names what is actually missing"
check_eq "$(rows_for codex-one@example.com)" "ok" "the codex row beside it still renders"

# An unknown provider is what `unsupported` is for now that cursor is read.
reset_state
write_config "$(account_json weirdprovider someone@example.com "$PROFILES/x")"
run --json
check_eq "$RC" "0" "an unknown provider does not fail the run"
check_eq "$(rows_for someone@example.com)" "unsupported" "and reads unsupported"

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

# --- 12c. a row that cannot be built is never a successful empty report -----
# Every provider path funnels through emit_row. If its jq program cannot build a
# row, the old code appended nothing and the run still exited 0 — an empty table,
# or `[]` under --json, presented as a successful read. That is the report saying
# "no accounts" when it means "I could not build a row", and for a display-only
# tool whose whole output is a claim about accounts, it is the worst shape the
# failure could take. A jq that always fails is what that looks like from the
# script's side.

reset_state
X1="$(seed_codex_profile codex-one@example.com "$(codex_snapshot_primary_weekly)")"
write_config "$(account_json codex codex-one@example.com "$X1")"
run --json
check_eq "$RC" "0" "control(+): the same registry reports normally with a working jq"
check_eq "$(printf '%s' "$OUT" | jq 'length')" "1" "control(+): and yields a row"

# Fails ONLY the `-nc` invocation, which in this script is emit_row and nothing
# else. A jq that fails outright would be caught by the registry checks long
# before any row is built, and this case would pass without ever reaching the
# guard it is named for.
real_jq="$(command -v jq)"
{
  printf '#!/usr/bin/env bash\n'
  printf 'for a in "$@"; do [[ "$a" == "-nc" ]] && exit 91; done\n'
  printf 'exec %s "$@"\n' "$real_jq"
} > "$BIN/jq"
chmod +x "$BIN/jq"
saved_path="$PATH"
PATH="$BIN:$PATH"
run --json
PATH="$saved_path"
rm -f "$BIN/jq"
check_eq "$RC" "70" "a row that cannot be built exits 70, not 0 with an empty report"
check_not_contains "$OUT" "[]" \
  "control(-): and does not print an empty JSON array as if the read succeeded"
check_contains "$ERR" "could not build" \
  "and names the account whose row was lost"

# --- 12b. no `column` degrades the table, it does not replace it ------------
# The fallback for a missing `column` printed the TSV header and then `cat` of
# the ROW FILE — which holds JSON objects, not the rendered columns. That is not
# an unaligned table, it is a different output wearing the table's header.

reset_state
X1="$(seed_codex_profile codex-one@example.com "$(codex_snapshot_primary_weekly)")"
write_config "$(account_json codex codex-one@example.com "$X1")"
# A `column` that always fails is what "column is unavailable" looks like from
# the script's side, without removing it from the sandbox PATH wholesale.
printf '#!/usr/bin/env bash\nexit 127\n' > "$BIN/column"
chmod +x "$BIN/column"
saved_path="$PATH"
PATH="$BIN:$PATH"
run
PATH="$saved_path"
rm -f "$BIN/column"
check_eq "$RC" "0" "a missing column does not fail the run"
check_contains "$OUT" "ACCOUNT" "the fallback still prints the table header"
check_contains "$OUT" "codex-one@example.com" "and the account's row"
check_not_contains "$OUT" '"provider"' \
  "control(-): and does NOT print the raw JSON rows under that header"
check_not_contains "$OUT" '{' \
  "control(-): no JSON object survives into the table output at all"

# --- 13b. one window is one row, even when it stands in for the weekly one ---
# A plan reporting a single sub-weekly window is valid input, and the weekly
# selector's longest-window fallback renders it as the weekly row. The short
# selector must not then pick the SAME slot: that prints one window as two rows
# differing only in the note, which reads as two windows.

reset_state
X1="$(seed_codex_profile codex-one@example.com \
  "$(jq -n --argjson five "$FIVE_RESET" \
     '{rateLimits: {limitId: "codex", planType: "pro",
                    primary: {usedPercent: 33, windowDurationMins: 300, resetsAt: $five},
                    secondary: null}}')")"
write_config "$(account_json codex codex-one@example.com "$X1")"
run --json --five-hour
check_eq "$RC" "0" "a single-short-window plan is not an error"
check_eq "$(printf '%s' "$OUT" | jq '[.[] | select(.label == "codex-one@example.com")] | length')" "1" \
  "one reported window renders exactly one row under --five-hour"
check_eq "$(field_of codex-one@example.com "5-hour" used_pct)" "33" \
  "and it is the window the payload actually reported"
check_contains "$(field_of codex-one@example.com "5-hour" detail)" "no 7-day window reported" \
  "the row says it is standing in for a weekly one"
check_not_contains "$(field_of codex-one@example.com "5-hour" detail)" "reports no short window" \
  "control(-): and does not also claim the plan reports no short window"

# --- 13c. a short window is labelled from its duration, never assumed 5-hour -
# `--five-hour` names the FLAG, not a promise about the window that comes back.
# With two sub-weekly windows and no weekly one, the weekly row takes the longer
# (its longest-window fallback) and the short row takes what is left — and each
# is labelled from its own windowDurationMins. Calling a 60-minute window
# "5-hour" would put a real number under a heading that is wrong, which is the
# failure the whole selector exists to avoid.

reset_state
X1="$(seed_codex_profile codex-one@example.com \
  "$(jq -n --argjson five "$FIVE_RESET" \
     '{rateLimits: {limitId: "codex", planType: "pro",
                    primary: {usedPercent: 41, windowDurationMins: 300, resetsAt: $five},
                    secondary: {usedPercent: 12, windowDurationMins: 60, resetsAt: $five}}}')")"
write_config "$(account_json codex codex-one@example.com "$X1")"
run --json --five-hour
check_eq "$(field_of codex-one@example.com "5-hour" used_pct)" "41" \
  "the 300-minute window is the 5-hour row"
check_eq "$(field_of codex-one@example.com "1-hour" used_pct)" "12" \
  "and the 60-minute window is labelled 1-hour from its own duration"
check_eq "$(printf '%s' "$OUT" | jq '[.[] | select(.window == "5-hour")] | length')" "1" \
  "control(-): the shorter window is not also emitted as a second 5-hour row"

# --- 14d. cleanup is bounded when the server outlives SIGTERM ---------------
# SIGTERM is a request the real `codex app-server` may decline. An unconditional
# `wait` after it blocks until the process feels like exiting — at CLEANUP,
# after the answer is already in hand — so a report whose whole contract is that
# it comes back would hang holding the result. Cleanup must escalate to SIGKILL
# and give up on the status rather than on the report.
#
# The stub lingers 30s in this mode, so the regression shows up as elapsed time.
# Asserting a ceiling well under that linger is what makes this discriminating:
# with the bound the run is a few seconds, without it the run inherits the 30.

reset_state
X1="$(seed_codex_profile codex-one@example.com "$(codex_snapshot_primary_weekly)")"
write_config "$(account_json codex codex-one@example.com "$X1")"
export STUB_CODEX_IGNORE_TERM=1
term_t0="$(date +%s)"
run --json
term_elapsed=$(( $(date +%s) - term_t0 ))
unset STUB_CODEX_IGNORE_TERM
check_eq "$(field_of codex-one@example.com "7-day" source)" "app-server" \
  "a server that ignores SIGTERM still yields its answer"
if [[ "$term_elapsed" -lt 15 ]]; then
  ok "and cleanup is bounded — the run took ${term_elapsed}s, not the stub's 30s linger"
else
  bad "cleanup was not bounded: the run took ${term_elapsed}s, inheriting the stub's linger"
fi

# --- 14c. an unusable timeout is refused, not used --------------------------
# `[[ -lt ]]` is arithmetic: `abc` evaluates to 0, so the app-server loop makes
# ZERO passes and the row degrades to the HTTP fallback reporting "did not
# answer within abcs" — a silent fallback wearing a timeout's clothes. `08` is
# arithmetically invalid (8 is not an octal digit) and bash says so on stderr.
# Neither is a timeout, so the reader must refuse the value and keep its
# default rather than bounding anything with it.

reset_state
X1="$(seed_codex_profile codex-one@example.com "$(codex_snapshot_primary_weekly)")"
write_config "$(account_json codex codex-one@example.com "$X1")"
jq -n --argjson week "$WEEK_RESET" \
  '{rate_limits: {planType: "pro",
                  primary: {usedPercent: 11, windowDurationMins: 10080, resetsAt: $week},
                  secondary: null}}' > "$STUB_CHATGPT_BODY"
for bad_timeout in abc 08 0; do
  # Exported, not prefixed: a `VAR=x func` prefix leaks past the call in bash,
  # so the next case would inherit it and stop testing what it names.
  export AI_QUOTAS_CODEX_TIMEOUT_OVERRIDE="$bad_timeout"
  run --json
  unset AI_QUOTAS_CODEX_TIMEOUT_OVERRIDE
  check_eq "$(field_of codex-one@example.com "7-day" source)" "app-server" \
    "AI_QUOTAS_CODEX_TIMEOUT='$bad_timeout' is refused, so app-server is still waited for"
  check_eq "$(field_of codex-one@example.com "7-day" used_pct)" "71" \
    "control(+): and the figures are still the app-server fixture's, not the HTTP body's"
  check_contains "$ERR" "not a positive integer" \
    "and the refusal is stated on stderr rather than applied silently"
done
# A usable override is still honoured — or the checks above would pass on a
# reader that ignored the variable altogether.
export AI_QUOTAS_CODEX_TIMEOUT_OVERRIDE="7"
run --json
unset AI_QUOTAS_CODEX_TIMEOUT_OVERRIDE
check_eq "$(field_of codex-one@example.com "7-day" source)" "app-server" \
  "control(+): a valid timeout is accepted"
check_not_contains "$ERR" "not a positive integer" \
  "control(-): and a valid timeout draws no refusal"
# An EMPTY value is not a wrong value: `${VAR:-20}` cannot tell it from unset,
# and "you left it unset" is not something to warn about. It takes the default
# silently, and the refusal above stays reserved for values someone meant.
export AI_QUOTAS_CODEX_TIMEOUT_OVERRIDE=""
run --json
unset AI_QUOTAS_CODEX_TIMEOUT_OVERRIDE
check_eq "$(field_of codex-one@example.com "7-day" source)" "app-server" \
  "an empty timeout takes the default"
check_not_contains "$ERR" "not a positive integer" \
  "control(-): and is not refused — empty is indistinguishable from unset"

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

# --- 16. the overage column and the cheapest-next hint (#1669) ---------------
# The issue's own worked example: one Claude account at 5 % remaining, one
# Codex account at 60 %. The Codex account should win — it still has room AND
# the month's free reset is unspent — and the hint should say both.
#
# Discriminating on purpose: the Claude account is the one at 5 %, so a
# selector that simply picked the FIRST row, or the one with the least left,
# would name it and fail here.

overage_case() { # <claude-used-pct> <codex-used-pct>
  reset_state
  jq -n --argjson week "$WEEK_RESET" --argjson five "$FIVE_RESET" --argjson u "$1" \
    '{account: {email_address: "claude-one@example.com"},
      five_hour: {utilization: 12, resets_at: ($five | todate)},
      seven_day: {utilization: $u, resets_at: ($week | todate)}}' > "$STUB_ANTHROPIC_BODY"
  local snap
  snap="$(jq -n --argjson week "$WEEK_RESET" --argjson u "$2" \
    '{rateLimits: {limitId: "codex", planType: "pro",
                   primary: {usedPercent: $u, windowDurationMins: 10080, resetsAt: $week},
                   secondary: null}}')"
  C1="$(seed_claude_profile claude-one@example.com "Claude Code-credentials-AAA")"
  X1="$(seed_codex_profile codex-one@example.com "$snap")"
  write_config \
    "$(account_json claude claude-one@example.com "$C1" "Claude Code-credentials-AAA")" \
    "$(account_json codex codex-one@example.com "$X1")"
}

overage_case 95 40
run
check_eq "$RC" "0" "the drained-Claude / roomy-Codex table exits 0"
check_contains "$OUT" "OVERAGE" "the table has an Overage column"
check_contains "$OUT" "API rate" "the claude row prices its overage at the API rate"
check_contains "$OUT" "1 free reset" "and the codex row shows the month's free reset"
check_contains "$OUT" \
  "Cheapest to continue on: codex-one@example.com (60 % weekly left, 1 free reset this month)" \
  "and the hint names the codex account, with both reasons"
check_contains "$OUT" "never switches accounts" \
  "and says at the point of use that it never switches, buys, or gates"
check_not_contains "$OUT" "Cheapest to continue on: claude-one@example.com" \
  "control(-): the account at 5 % is not offered as the cheapest one"

run --json
check_eq "$(printf '%s' "$OUT" | jq -r '[.[] | select(.overage != null)] | length')" "2" \
  "--json carries an overage object on every row"
check_eq "$(printf '%s' "$OUT" | jq -r '.[] | select(.provider == "claude") | .overage.label')" \
  "API rate" "the claude row's overage label is the API rate"
check_eq "$(printf '%s' "$OUT" | jq -r '.[] | select(.provider == "codex") | .overage.label')" \
  "1 free reset" "the codex row's overage label is the free reset"
check_eq "$(printf '%s' "$OUT" | jq -r '.[] | select(.provider == "codex") | .overage.last_verified')" \
  "2026-09-09" "and every priced row carries the date its price was verified"
check_contains "$(printf '%s' "$OUT" | jq -r '.[] | select(.provider == "codex") | .overage.source')" \
  "help.openai.com" "and the source URL that price came from"
check_eq "$(printf '%s' "$DOC" | jq -r '.cheapest_next.provider')" "codex" \
  "--json carries cheapest_next at the top level"
check_eq "$(printf '%s' "$DOC" | jq -r '.threshold_pct')" "20" \
  "and the threshold it was decided against"
check_contains "$(printf '%s' "$DOC" | jq -r '.cheapest_next.basis')" "do not convert" \
  "and states its basis rather than pretending the units match"

# Every account well above the threshold: nothing prints. A hint offered when
# nobody needs one is a line the reader learns to skip.
overage_case 10 20
run
check_eq "$RC" "0" "with every account above the threshold the run still exits 0"
check_contains "$OUT" "OVERAGE" "the overage column is still rendered"
check_not_contains "$OUT" "Cheapest to continue on:" \
  "but no cheapest-next line is printed"
run --json
check_eq "$(printf '%s' "$DOC" | jq -r '.cheapest_next | tostring')" "null" \
  "and --json reports cheapest_next as null"

# Boundary: exactly AT the threshold fires it. An account sitting on the line
# is the case the hint exists for, and a strict comparison would stay silent.
overage_case 80 40
run
check_contains "$OUT" "Cheapest to continue on:" \
  "an account exactly at the threshold fires the hint (boundary inclusive)"

# The helper going missing degrades the report; it never fails it, and never
# silently drops a column the header still promises. Driven through the
# AI_QUOTAS_CHEAPEST_BIN seam rather than by chmod-ing the real script, so an
# interrupted suite cannot leave a repo file non-executable behind it.
overage_case 95 40
CHEAPEST_BIN_OVERRIDE="$TMP/no-such-cheapest.sh"
run
check_eq "$RC" "0" "an unavailable cheapest-next helper does not fail the report"
check_contains "$ERR" "DEGRADED" "and the degradation is stated on stderr"
check_contains "$OUT" "claude-one@example.com" "every account still reports"
check_contains "$OUT" "OVERAGE" "the column header is still printed"
check_not_contains "$OUT" "Cheapest to continue on:" \
  "and no hint is invented without prices to base it on"
run --json
check_eq "$(printf '%s' "$DOC" | jq -r '[.rows[] | select(.overage == null)] | length')" "2" \
  "--json still declares overage on every row, as null"
check_eq "$(printf '%s' "$DOC" | jq -r '.cheapest_next | tostring')" "null" \
  "and cheapest_next is null, not absent"

# A helper that RUNS and fails is a different failure from one that is
# missing, and it must degrade the same way rather than emitting the empty
# document its broken output would otherwise produce.
printf '#!/usr/bin/env bash\necho "boom" >&2\nexit 1\n' > "$TMP/broken-cheapest.sh"
chmod +x "$TMP/broken-cheapest.sh"
CHEAPEST_BIN_OVERRIDE="$TMP/broken-cheapest.sh"
run
CHEAPEST_BIN_OVERRIDE=""
check_eq "$RC" "0" "a cheapest-next helper that exits non-zero does not fail the report"
check_contains "$ERR" "DEGRADED" "and that degradation is stated too"
check_contains "$ERR" "boom" "with the helper's own message passed through"
check_contains "$OUT" "codex-one@example.com" "every account still reports"

# A helper that reports SUCCESS while dropping the rows is the dangerous
# shape: the document is well-formed, so a shape-only check passes it, and the
# populated account list prints as no accounts at all with exit 0. The row
# count is what catches it — and the message must not blame an exit code that
# was zero.
cat > "$TMP/empty-rows-cheapest.sh" <<'EMPTY_ROWS_HELPER'
#!/usr/bin/env bash
cat >/dev/null
echo '{"schema_version":"1.0","threshold_pct":20,"basis":"x","rows":[],"cheapest_next":null}'
EMPTY_ROWS_HELPER
chmod +x "$TMP/empty-rows-cheapest.sh"
CHEAPEST_BIN_OVERRIDE="$TMP/empty-rows-cheapest.sh"
run
check_eq "$RC" "0" "a helper that drops every row does not fail the report"
check_contains "$ERR" "DEGRADED" "the dropped rows are stated as a degradation"
check_not_contains "$ERR" "failed (exit" "and are not reported as an exit-code failure"
check_contains "$OUT" "claude-one@example.com" "every account still reports"
check_contains "$OUT" "codex-one@example.com" "including the second one"
run --json
CHEAPEST_BIN_OVERRIDE=""
check_eq "$(printf '%s' "$DOC" | jq -r '.rows | length')" "2" \
  "--json carries the real rows rather than the helper's empty array"

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
# The WHOLE document, not just the rows: the overage annotation and the
# cheapest-next hint copy a label and a reason out of a row, and a leak that
# only reached those would pass an assertion scoped to `.rows`.
#
# DOC is asserted non-empty FIRST. A grep for secrets over an empty string
# finds none, so a run that produced no document at all would score a clean
# leak check — the scan passing because there was nothing to scan.
check_eq "$(printf '%s' "$DOC" | jq -r 'if (.rows | length) > 0 then "populated" else "empty" end' 2>/dev/null)" \
  "populated" "control(+): the --json document under the leak scan actually has rows in it"
COMBINED="$DOC
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

# --- 17. snapshot history, nicknames, and the compact table (#1700) ----------
#
# The history file is what the burn-rate projection in #1701 reads, so what is
# asserted here is its SHAPE and its honesty: one line per row that actually
# produced a figure, nothing at all for a row that did not, the source of the
# run, and a mode that keeps it to this user. The compact table is asserted by
# MEASURING it — a five-account render whose widest line has to fit inside 100
# columns — rather than by eyeballing a fixture.

HISTORY="$CASE_HOME/.claude/ai-quotas-history.jsonl"

history_lines() { cat "$HISTORY" 2>/dev/null || true; }
history_count() { history_lines | grep -c . || true; }

utc_iso() { # <epoch>
  date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || true
}

# The table only, from its header to the blank line that follows it. The
# advisory prose under it is deliberately excluded: the display-only sentence
# is a fixed hundred-plus-column sentence, and measuring it would turn the
# width assertion into a statement about that sentence rather than the table.
table_only() { # <output>
  printf '%s\n' "$1" | awk '/^ACCOUNT /{f=1} f && /^[[:space:]]*$/{exit} f {print}'
}

widest_line() { # <text>
  printf '%s\n' "$1" | awk '{ if (length($0) > m) m = length($0) } END { print m + 0 }'
}

# --- 17a. one line per successfully read row per run -------------------------

overage_case 40 50
run
check_eq "$RC" "0" "a run that records history still exits 0"
check_eq "$(history_count)" "2" "one snapshot line per row is appended"
run
check_eq "$(history_count)" "4" "a second run APPENDS its own set rather than replacing the first"
check_eq "$(history_lines | jq -s 'length' 2>/dev/null || echo PARSE-ERROR)" "4" \
  "every line parses as JSON — the file really is JSONL"
check_eq "$(ls -l "$HISTORY" | cut -c1-10)" "-rw-------" "the history file is mode 600"

# The exact field set #1701 will read, asserted as a sorted key list rather
# than field by field, so a key silently added or dropped fails here instead
# of in the consumer six weeks later.
check_eq "$(history_lines | tail -n 1 | jq -r '[keys_unsorted[]] | sort | join(",")')" \
  "label,nickname,provider,resets_at_epoch,source,ts,used_pct,window,window_start_epoch" \
  "a snapshot carries exactly the documented fields"
# The window this reading belongs to, recorded rather than re-derived later
# (#1701). A weekly Codex window is its reset minus its own reported duration,
# which is the figure the projection places every other reading against.
check_eq "$(history_lines | jq -r 'select(.provider == "codex") | .window_start_epoch' | tail -n 1)" \
  "$(( WEEK_RESET - 604800 ))" \
  "and the start of the window it was reported for"
check_eq "$(history_lines | tail -n 1 | jq -r '.ts')" "2026-09-08T20:00:00Z" \
  "the snapshot timestamp is the run clock, not a second-order guess at it"
check_eq "$(history_lines | jq -r 'select(.provider == "codex") | .used_pct' | tail -n 1)" "50" \
  "the recorded percentage is the one the row reported"
check_eq "$(history_lines | jq -r 'select(.provider == "codex") | .window' | tail -n 1)" "7-day" \
  "and the window it was reported for"
check_eq "$(history_lines | jq -r '.source' | sort -u | tr '\n' ' ' | sed 's/ $//')" "manual" \
  "a hand-run /quotas records its snapshots as manual"

# --- 17b. a row that could not be read appends NOTHING -----------------------
#
# Discriminating on purpose: the config holds one account that reads and one
# that cannot, so "no line for the failed row" cannot pass by the file simply
# being empty.

reset_state
C_OK="$(seed_claude_profile claude-one@example.com "Claude Code-credentials-AAA")"
X_BAD="$(seed_codex_profile codex-nologin@example.com "")"
write_config \
  "$(account_json claude claude-one@example.com "$C_OK" "Claude Code-credentials-AAA")" \
  "$(account_json codex codex-nologin@example.com "$X_BAD")"
run
check_eq "$RC" "0" "a failed row does not fail the run"
check_contains "$OUT" "needs-login" "control(+): the failing account really did fail"
check_eq "$(history_count)" "1" "a row with no figure appends no snapshot line"
check_eq "$(history_lines | jq -r '.provider')" "claude" \
  "control(+): the row that did read appended exactly one"

# --- 17b-ii. a history path that is a symlink is refused ---------------------
#
# `-f` and `-e` both FOLLOW a link, so without an explicit check the chmod
# would retarget an unrelated file's mode and the append would write quota
# JSON into it — and a DANGLING link would be followed into existence.

overage_case 40 50
SYMLINK_TARGET="$TMP/not-the-history.txt"
printf 'pre-existing content\n' > "$SYMLINK_TARGET"
chmod 644 "$SYMLINK_TARGET"
mkdir -p "$(dirname "$HISTORY")"
rm -f "$HISTORY"
ln -s "$SYMLINK_TARGET" "$HISTORY"
run
check_eq "$RC" "0" "a symlinked history path does not fail the run"
check_contains "$ERR" "symbolic link" "it says why nothing was recorded, on stderr like every other warn"
check_eq "$(cat "$SYMLINK_TARGET")" "pre-existing content" \
  "the link target is not written to"
check_eq "$(ls -l "$SYMLINK_TARGET" | cut -c1-10)" "-rw-r--r--" \
  "and its mode is left alone — the chmod never reached it"

# The dangling half of the same rule: `-e` is false for a link to nothing, so
# the create branch would bring the target into existence.
overage_case 40 50
DANGLING_TARGET="$TMP/never-created.jsonl"
rm -f "$DANGLING_TARGET"
mkdir -p "$(dirname "$HISTORY")"
rm -f "$HISTORY"
ln -s "$DANGLING_TARGET" "$HISTORY"
run
check_eq "$RC" "0" "a dangling symlink does not fail the run either"
check_eq "$(test -e "$DANGLING_TARGET" && echo created || echo absent)" "absent" \
  "and its target is not created"

# --- 17c. --quiet is the unattended run --------------------------------------

overage_case 40 50
run --quiet
check_eq "$RC" "0" "--quiet exits 0"
check_eq "$(history_lines | jq -r '.source' | sort -u | tr '\n' ' ' | sed 's/ $//')" "scheduled" \
  "--quiet records its snapshots as scheduled"
check_contains "$OUT" "OVERAGE" "control(+): --quiet still prints the report itself"
check_not_contains "$OUT" "Display only" "--quiet drops the trailing advisory prose"
check_not_contains "$OUT" "LAST SNAPSHOT" \
  "and the snapshot footer, which under --quiet would only tell the job log about itself"

# --- 17d. the LAST SNAPSHOT footer -------------------------------------------

overage_case 40 50
run
check_contains "$OUT" "LAST SNAPSHOT: none yet" \
  "with no scheduled snapshot the footer says none yet — manual lines do not count"
run --quiet
run
check_not_contains "$OUT" "none yet" "once the unattended job has run the footer names its time"
check_contains "$OUT" "LAST SNAPSHOT: Tue Sep 8" \
  "and names it in Eastern, like every other time in the table"
check_not_contains "$OUT" "stale" "a snapshot taken now is not stale"

overage_case 40 50
mkdir -p "$(dirname "$HISTORY")"
# A torn line FIRST, then the real one: a run killed mid-append leaves exactly
# this, and one unparseable line must not cost the footer the lines around it.
printf 'this line is not json\n' > "$HISTORY"
# And a line that PARSES but is not an object. `fromjson?` catches only the
# parse error, so a bare number reaches `.source` and aborts jq — which would
# take the good line below down with it.
printf '5\n' >> "$HISTORY"
jq -nc --arg ts "$(utc_iso $(( NOW - 3 * 86400 )))" \
  '{ts: $ts, provider: "codex", label: "codex-one@example.com", nickname: null,
    window: "7-day", used_pct: 10, resets_at_epoch: null, source: "scheduled"}' >> "$HISTORY"
run
check_contains "$OUT" "stale (>1 day)" "a scheduled snapshot older than a day reads as stale"
check_contains "$OUT" "LAST SNAPSHOT: Sat Sep 5" \
  "control(+): neither the torn line nor the non-object one stopped the good one being read"

# File order is append-COMPLETION order, and every row of a run carries the
# clock that run STARTED on — so a slow run finishing after a quick one leaves
# an older ts on the last line. Written in exactly that order here: the newer
# reading first, the older one appended after it.
overage_case 40 50
mkdir -p "$(dirname "$HISTORY")"
jq -nc --arg ts "$(utc_iso "$NOW")" \
  '{ts: $ts, provider: "codex", label: "codex-one@example.com", nickname: null,
    window: "7-day", used_pct: 10, resets_at_epoch: null, source: "scheduled"}' > "$HISTORY"
jq -nc --arg ts "$(utc_iso $(( NOW - 3 * 86400 )))" \
  '{ts: $ts, provider: "codex", label: "codex-one@example.com", nickname: null,
    window: "7-day", used_pct: 10, resets_at_epoch: null, source: "scheduled"}' >> "$HISTORY"
run
check_contains "$OUT" "LAST SNAPSHOT: Tue Sep 8" \
  "the footer names the NEWEST scheduled reading, not whichever line landed last"
check_not_contains "$OUT" "stale" \
  "so a fresh reading is not reported stale because an older one was appended after it"

# --- 17e. nicknames ----------------------------------------------------------

overage_case 40 50
NICKED="$TMP/nicked.json"
jq '.accounts = [.accounts[] | if .provider == "codex" then . + {nickname: "GPT LM"} else . end]' \
  "$CONFIG" > "$NICKED" && mv "$NICKED" "$CONFIG"
run
check_contains "$OUT" "GPT LM" "the table shows the nickname"
check_not_contains "$OUT" "codex-one@example.com" "in place of the address it replaces"
check_contains "$OUT" "claude-one@example.com" \
  "control(+): an account with no nickname still shows its address"
run --json
check_eq "$(printf '%s' "$OUT" | jq -r '.[] | select(.provider == "codex") | .nickname')" "GPT LM" \
  "--json carries the nickname on the row"
check_eq "$(printf '%s' "$OUT" | jq -r '.[] | select(.provider == "claude") | .nickname')" "null" \
  "and null — not a missing key — on a row without one"
check_eq "$(history_lines | jq -r 'select(.provider == "codex") | .nickname' | tail -n 1)" "GPT LM" \
  "the snapshot records the nickname alongside the label"

# `nick` refuses control characters, but this reader accepts any compatible
# 1.x registry — a hand-edited one, or one a future sibling wrote — and the
# value goes straight into a terminal table. A tab splits the columns, a
# newline forges a row, and an escape sequence is executed rather than shown.
overage_case 40 50
NICK_HOSTILE="$TMP/hostile-nick.json"
jq '.accounts = [.accounts[]
      | if .provider == "codex" then . + {nickname: "col\tsplit"} else . end]' \
  "$CONFIG" > "$NICK_HOSTILE" && mv "$NICK_HOSTILE" "$CONFIG"
# The fixture builds its own premise: a nickname that did not actually contain
# a tab would pass every assertion below for the wrong reason.
check_eq "$(jq -r '[.accounts[].nickname // empty | explode[] | select(. == 9)] | length' "$CONFIG")" "1" \
  "premise: the registry really does hold a nickname with a tab in it"
run
check_eq "$RC" "0" "a registry nickname holding a control character does not fail the run"
check_not_contains "$OUT" "col	split" "the raw value never reaches the table"
check_contains "$OUT" "codex-one@example.com" \
  "which falls back to the label, exactly as an absent nickname does"
run --json
check_eq "$(printf '%s' "$OUT" | jq -r '.[] | select(.provider == "codex") | .nickname')" "null" \
  "control(+): --json carries it as null, the same shape an account with no nickname has"

overage_case 40 50
NICK_ESC="$TMP/esc-nick.json"
jq '.accounts = [.accounts[]
      | if .provider == "codex" then . + {nickname: "esc[2Jhere"} else . end]' \
  "$CONFIG" > "$NICK_ESC" && mv "$NICK_ESC" "$CONFIG"
check_eq "$(jq -r '[.accounts[].nickname // empty | explode[] | select(. == 27)] | length' "$CONFIG")" "1" \
  "premise: and one holding a real escape character"
run
check_not_contains "$OUT" "esc" "an escape sequence is dropped rather than handed to the terminal"
check_contains "$OUT" "codex-one@example.com" "control(+): that row fell back to its label too"

# --- 17f. last_scheduled_snapshot_at is on every document --------------------

overage_case 40 50
run --json
check_eq "$(printf '%s' "$DOC" | jq -r 'has("last_scheduled_snapshot_at") | tostring')" "true" \
  "--json declares last_scheduled_snapshot_at"
check_eq "$(printf '%s' "$DOC" | jq -r '.last_scheduled_snapshot_at | tostring')" "null" \
  "null before the unattended job has ever run"
run --quiet
run --json
check_eq "$(printf '%s' "$DOC" | jq -r '.last_scheduled_snapshot_at')" "2026-09-08T20:00:00Z" \
  "and the instant of the last scheduled snapshot once it has"

reset_state
write_config
run --json
check_eq "$(printf '%s' "$DOC" | jq -r 'has("last_scheduled_snapshot_at") | tostring')" "true" \
  "the no-accounts document has the same shape — nothing for a consumer to special-case"

# --- 17g. the compact table fits five accounts in 100 columns ----------------

# One claude and four codex accounts, each reporting its OWN address, so no row
# carries a `registered as` note that a real five-account registry would not
# have. Only one claude account: the anthropic stub answers from a single
# shared body, so a second one would report the first account address and
# reintroduce exactly the artificial note this fixture exists to avoid.
#
# The nicknames are the length nicknames actually are — the owner uses `GPT LM`
# and `GPT Personal` — because the ACCOUNT column is sized by the longest one,
# and a fixture with 30-character nicknames would be measuring the fixture.
reset_state
FIVE_SNAP="$(codex_snapshot_primary_weekly)"
C_A="$(seed_claude_profile claude-one@example.com "Claude Code-credentials-AAA")"
X_A="$(seed_codex_profile codex-one@example.com "$FIVE_SNAP" codex-one@example.com)"
X_B="$(seed_codex_profile codex-two@example.com "$FIVE_SNAP" codex-two@example.com)"
X_C="$(seed_codex_profile codex-three@example.com "$FIVE_SNAP" codex-three@example.com)"
X_D="$(seed_codex_profile codex-four@example.com "$FIVE_SNAP" codex-four@example.com)"
write_config \
  "$(account_json claude claude-one@example.com "$C_A" "Claude Code-credentials-AAA" | jq '. + {nickname: "Claude Work"}')" \
  "$(account_json codex codex-one@example.com "$X_A" | jq '. + {nickname: "GPT LM"}')" \
  "$(account_json codex codex-two@example.com "$X_B" | jq '. + {nickname: "GPT Personal"}')" \
  "$(account_json codex codex-three@example.com "$X_C" | jq '. + {nickname: "GPT Spare"}')" \
  "$(account_json codex codex-four@example.com "$X_D" | jq '. + {nickname: "GPT Extra"}')"
run
check_eq "$RC" "0" "a five-account table exits 0"
check_not_contains "$OUT" "REMAIN" "the compact table has no REMAIN column"
check_contains "$OUT" "USED" "and still has USED"
FIVE_TABLE="$(table_only "$OUT")"
# The control comes FIRST: a width measured over a table that never rendered
# would pass for the emptiest possible reason.
check_eq "$(printf '%s\n' "$FIVE_TABLE" | grep -c '7-day' || true)" "5" \
  "control(+): all five accounts really are in the measured table"
# Second control: the measured table must be the CLEAN five-account case. A
# `registered as` note is a fixture artifact here (the stub bodies are shared),
# and if one crept back it would widen the table for a reason no real registry
# has — the width assertion below would then be failing, or passing, on the
# strength of a fake note.
check_not_contains "$FIVE_TABLE" "registered as" \
  "control(-): no row is decorated with a mislabelled-account note"
FIVE_WIDTH="$(widest_line "$FIVE_TABLE")"
if [[ "$FIVE_WIDTH" -le 100 && "$FIVE_WIDTH" -gt 0 ]]; then
  ok "the five-account table fits in 100 columns (widest line: ${FIVE_WIDTH})"
else
  bad "the five-account table does not fit in 100 columns (widest line: ${FIVE_WIDTH})"
fi
check_eq "$(history_count)" "5" "and every one of the five rows was recorded"

# --- 17i. the burn-rate projection reaches the table and --json (#1701) ------
#
# The reader does not compute the pace — quotas-forecast.sh does, and its own
# suite covers the arithmetic. What is asserted here is the WIRING: that the
# window start each provider derives is recorded and handed over, that the
# three columns reach the table, that the fields reach --json, and that a run
# without the helper degrades to a table missing exactly those three columns
# rather than to a broken one.

reset_state
overage_case 40 50
run
check_contains "$OUT" "START" "the table has a START column"
check_contains "$OUT" "%/DAY" "and a %/DAY column"
check_contains "$OUT" "LEFT" "and a LEFT column"
check_not_contains "$OUT" "PROVIDER" "the PROVIDER column is gone"
check_not_contains "$OUT" "STATUS" "and so is the STATUS column"
# The reset cell is the collapsed form now: a weekday and a time, no date and
# no zone — the countdown beside it and the ET in the heading say the rest.
check_not_contains "$(table_only "$OUT")" "EDT" \
  "the table prints the reset without its date and zone"
check_contains "$(table_only "$OUT")" "8:00 PM" "keeping the weekday and the time"
# The window this reader placed the reading in is the reset minus the window
# length the payload reported — the figure every projection is measured from.
run --json
check_eq "$(field_of claude-one@example.com "7-day" window_start_epoch)" \
  "$(( WEEK_RESET - 604800 ))" "a claude weekly row carries its window start"
check_eq "$(field_of codex-one@example.com "7-day" window_start_epoch)" \
  "$(( WEEK_RESET - 604800 ))" "and so does a codex one, from its reported duration"
# 40 % of a week that opened 4d19h ago, projected to a rate and a runway. The
# exact figures are the forecast suite's business; what matters here is that
# they are NUMBERS on the row rather than nulls, which is what a run with no
# projection would leave.
check_eq "$(printf '%s' "$OUT" | jq -r \
  '.[] | select(.label == "claude-one@example.com") | .pct_per_day | type')" "number" \
  "--json carries pct_per_day as a number"
check_eq "$(field_of claude-one@example.com "7-day" usage_start_is_floor)" "true" \
  "the first run of a window is a floor start — nothing recorded reaches back further"
# The only snapshot is this run own reading, so the start is TODAY — day 5 of
# a window that opened 4d19h ago — carrying the <= that says usage may have
# begun earlier and nothing recorded can rule it out.
# GNU form first: GNU date reads `-r` as a FILENAME, so the BSD form tried
# first would print an unrelated file's weekday on the day one is named for
# this epoch second. BSD rejects `-d` outright, so this order never misreads.
ET_TODAY="$(TZ=America/New_York date -d "@$NOW" '+%a' 2>/dev/null \
  || TZ=America/New_York date -r "$NOW" '+%a' 2>/dev/null)"
check_eq "$(field_of claude-one@example.com "7-day" usage_start_display)" \
  "<=${ET_TODAY} d5" \
  "and the cell says so with a <= prefix on the day of the reading"
# The long reset string is still on the row even though the table shortened it.
check_contains "$(field_of claude-one@example.com "7-day" resets_at_et)" "EDT" \
  "--json keeps the full reset string"

# A helper that does not resolve degrades to a table without those three
# columns — and says so. Pointed at a path that is not executable, because the
# reader uses AI_QUOTAS_FORECAST_BIN exclusively: a fall-through would find the
# repo copy and this case could never be exercised from inside a checkout.
overage_case 40 50
FORECAST_BIN_OVERRIDE="$TMP/no-such-quotas-forecast.sh"
run
check_eq "$RC" "0" "an unavailable projection helper does not fail the report"
check_contains "$ERR" "DEGRADED" "it says DEGRADED on stderr"
check_contains "$ERR" "$FORECAST_BIN_OVERRIDE" \
  "naming the path it could not use, so the reader is not sent hunting three others"
check_contains "$ERR" "LEFT" "and which columns lost their figures because of it"
# The COLUMNS stay — one table shape whatever ran, with the same `-` every
# other unknown in this table uses. What must not survive is a FIGURE in them,
# which is what a helper that half-ran would leave.
check_contains "$(table_only "$OUT")" "%/DAY" \
  "the columns are still there, so the table has one shape either way"
check_eq "$(printf '%s' "$OUT" | awk '/^ACCOUNT /{next} /^[[:space:]]*$/{exit} {print $4}' | sort -u | tr -d '\n')" "-" \
  "control(-): and every START cell is a dash rather than a figure nobody computed"
FORECAST_BIN_OVERRIDE=""
check_contains "$OUT" "OVERAGE" "the rest of the table still renders"
check_contains "$OUT" "40%" "including every figure that was read"

# --- 17h. history never changes the exit status ------------------------------
#
# The history path is made unwritable by occupying it with a DIRECTORY rather
# than by permissions: this suite may run as a user for whom a mode-000 file is
# still writable, and the assertion would then pass without ever reaching the
# failure it claims to test.

overage_case 40 50
rm -rf "$HISTORY"
mkdir -p "$HISTORY"
BLOCKED_MODE_BEFORE="$(ls -ld "$HISTORY" | cut -c1-10)"
run
check_eq "$RC" "0" "an unwritable history file does not fail the report"
check_contains "$OUT" "OVERAGE" "and the table still renders in full"
check_contains "$ERR" "$HISTORY" "the failure is named on stderr rather than swallowed"
# `chmod 600` on a directory SUCCEEDS and strips its execute bit, making it
# unusable. A display tool must not mutate a path it merely failed to write to,
# so the mode is asserted unchanged rather than assumed.
check_eq "$(ls -ld "$HISTORY" | cut -c1-10)" "$BLOCKED_MODE_BEFORE" \
  "and the directory occupying that path is left exactly as it was"
rm -rf "$HISTORY"

# --- summary -----------------------------------------------------------------

echo
echo "passed: $PASS   failed: $FAILED"
[[ "$FAILED" -eq 0 ]] || exit 1
exit 0
