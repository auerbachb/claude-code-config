#!/usr/bin/env bash
# ai-quotas.test.sh — coverage for .claude/scripts/ai-quotas.sh (issue #1667).
# catalog: tests — Tests `ai-quotas.sh` — the multi-account table and `--json` row shape, weekly-window selection by `windowDurationMins` (asserted with the weekly figures in `primary`, the shape a Pro account really returns), `--five-hour`, per-row isolation of `needs-login`/`rate-limited`/`unreachable`/`unsupported`, the unrecognised-shape path printing the keys it saw instead of 0 %, deterministic ET reset + countdown against a frozen clock, the Cursor IDE-token path against a fixture SQLite state store and a fake `curl` (two pool rows with the captured percentages and billing cycle, 401 → `needs-login` naming the IDE, 500 → `unreachable`, a signed-out IDE → `needs-login`), the Claude token-renewal path (#1716 — an expired stored token renewed before the usage call, a 401 renewed and retried exactly once, the renewed pair written back into the same fake Keychain item with every other field preserved, a rejected grant as `needs-login`, an unreachable or shape-changed token endpoint as `unreachable`, and the same for the file-backed Linux store at mode 600), and the leak assertions that no credential value — the refresh token, the Cursor access token, and its `WorkosCursorSessionToken` cookie included — reaches stdout, stderr, argv, or the usage log
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
# The refresh token in the same item (#1716). Credential-shaped for the same
# reason the access token is: it makes the leak assertions real detectors of a
# reader that echoed the renewal request or logged what it stored.
CLAUDE_REFRESH_SECRET="sk-ant-ort01-FAKE-REFRESH-1A2B3C"
# The `acct` attribute on the fake keychain item. The reader has to read it
# back off the attribute dump and pass it to its update, or the write-back
# lands a SECOND item beside the one Claude Code reads.
CLAUDE_KEYCHAIN_ACCT="fixture-account"
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
  # The cursor cookie and the JWT it carries must arrive on STDIN, never in
  # argv, or `ps` exposes them to anything running as this user (#1703). `eyJ`
  # is the base64url of `{"`, so it catches the raw token as well as the
  # cookie wrapper — and nothing legitimate in this argv can contain it.
  *WorkosCursorSessionToken*) echo "STUB-CURL: a cursor session cookie reached argv" >&2; exit 90 ;;
  *eyJ*) echo "STUB-CURL: a JWT reached argv" >&2; exit 90 ;;
esac
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -D) dump="$2"; shift 2 ;;
    -H) case "$2" in User-Agent:*) ua="$2" ;; esac; shift 2 ;;
    -K) shift 2 ;;
    # Both take a value. Without this they fall to the generic `-*` below,
    # which shifts once and leaves `POST` (or `{}`) to be captured as the URL —
    # every cursor case would then dispatch on the wrong string.
    -X|-d) shift 2 ;;
    # The refresh request's body (#1716). It arrives as `@<path>`, never as
    # the JSON itself — the token is in the FILE, so it is not in this argv
    # and not in `ps`. Captured so the refresh cases can assert what was sent.
    --data-binary)
      case "$2" in
        @*) printf '%s' "$(cat "${2#@}" 2>/dev/null)" > "$STUB_CURL_BODY" ;;
        *) echo "STUB-CURL: a refresh body reached argv inline" >&2; exit 97 ;;
      esac
      shift 2 ;;
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
  # FIRST, and matched on the path rather than the host: the real token
  # endpoint (platform.claude.com) and the real usage endpoint
  # (api.anthropic.com) are different hosts, so a dispatch that tested the
  # host would pass here and mis-route against the shipping defaults.
  *oauth/token*)
    mode="$(cat "$STUB_TOKEN_MODE" 2>/dev/null || echo ok)"
    case "$mode" in
      ok)
        # A NEW access token and a ROTATED refresh token, both distinct from
        # the seeded pair, so "did the write-back land" is answerable.
        printf '{"access_token":"%s","refresh_token":"%s","expires_in":3600,"scope":"user:inference user:profile"}' \
          "$STUB_NEW_ACCESS" "$STUB_NEW_REFRESH" > "$out"
        printf '200' ;;
      # The response that means the grant itself is dead. Anthropic answers
      # 400 with the RFC 6749 error code, not 401.
      invalid_grant) printf '{"error":"invalid_grant","error_description":"expired"}' > "$out"; printf '400' ;;
      norotate)
        # No `refresh_token` in the response: Claude Code keeps the one it
        # already had, and so must this reader.
        printf '{"access_token":"%s","expires_in":3600}' "$STUB_NEW_ACCESS" > "$out"
        printf '200' ;;
      # HTTP 200 carrying no token at all — a CHANGED SHAPE, not a dead
      # login. Saying needs-login here would send the owner through a login
      # that could not fix it.
      noshape) printf '{"ok":true}' > "$out"; printf '200' ;;
      # A renewal that does not say how long the new token lasts. The stored
      # expiry must be DELETED, never left at its stale past value.
      noexpiry)
        printf '{"access_token":"%s","refresh_token":"%s"}' \
          "$STUB_NEW_ACCESS" "$STUB_NEW_REFRESH" > "$out"
        printf '200' ;;
      server)  printf 'oops' > "$out"; printf '500' ;;
      # A 403 carrying NO OAuth error code — what an edge proxy answers, not
      # the token endpoint refusing a grant. It must not read as needs-login.
      proxy403) printf '<html>blocked</html>' > "$out"; printf '403' ;;
      # The real 429, captured from the live endpoint on 2026-09-14. Note the
      # NESTED envelope: Anthropic sends {"error":{"type":…}}, not RFC 6749's
      # flat {"error":"…"}. A reader that only understood the flat shape would
      # misread a genuinely dead grant delivered this way.
      ratelimit)
        printf '{"error":{"type":"rate_limit_error","message":"Rate limited. Please try again later."}}' > "$out"
        printf '429' ;;
      ratelimit_retry)
        printf '{"error":{"type":"rate_limit_error"}}' > "$out"
        printf 'HTTP/2 429\r\nretry-after: 900\r\n' > "${dump:-/dev/null}"
        printf '429' ;;
      # A dead grant in that same nested envelope. This is the case the flat-
      # only reader would have called `unreachable`, leaving the owner never
      # told to log in again.
      nested_invalid_grant)
        printf '{"error":{"type":"invalid_grant","message":"refresh token expired"}}' > "$out"
        printf '400' ;;
      down)    echo "STUB-CURL: simulated token-endpoint failure" >&2; exit 7 ;;
      *) echo "STUB-CURL: unknown token mode '$mode'" >&2; exit 98 ;;
    esac
    ;;
  *anthropic*)
    mode="$(cat "$STUB_ANTHROPIC_MODE" 2>/dev/null || echo ok)"
    case "$mode" in
      ok)        cat "$STUB_ANTHROPIC_BODY" > "$out"; printf '200' ;;
      shape)     cat "$STUB_ANTHROPIC_BODY" > "$out"; printf '200' ;;
      ratelimit) printf '{"error":"rate_limited"}' > "$out"
                 printf 'HTTP/2 429\r\nretry-after: 1800\r\n' > "${dump:-/dev/null}"
                 printf '429' ;;
      unauth)    printf '{"error":"unauthorized"}' > "$out"; printf '401' ;;
      # 401 on the FIRST call of a run, 200 on every call after it — the
      # shape of a token that expired earlier than its stored expiry said
      # (#1716). The counter is what makes "one refresh, one retry" provable:
      # a reader that retried in a loop would still end at 200 without it.
      unauth_once)
        n="$(cat "$STUB_ANTHROPIC_401_COUNT" 2>/dev/null || echo 0)"
        if [[ "$n" -lt 1 ]]; then
          printf '%s' $(( n + 1 )) > "$STUB_ANTHROPIC_401_COUNT"
          printf '{"error":"unauthorized"}' > "$out"; printf '401'
        else
          cat "$STUB_ANTHROPIC_BODY" > "$out"; printf '200'
        fi ;;
      down)      echo "STUB-CURL: simulated network failure" >&2; exit 7 ;;
      *) echo "STUB-CURL: unknown anthropic mode '$mode'" >&2; exit 91 ;;
    esac
    ;;
  *chatgpt*)
    cat "$STUB_CHATGPT_BODY" > "$out"; printf '200'
    ;;
  *cursor.com*)
    mode="$(cat "$STUB_CURSOR_MODE" 2>/dev/null || echo ok)"
    # The cookie has to be HERE, on stdin, and nowhere else.
    if ! grep -q 'WorkosCursorSessionToken=' "$STUB_CURL_STDIN" 2>/dev/null; then
      echo "STUB-CURL: no cursor cookie arrived on stdin" >&2; exit 94
    fi
    # Log the derived USER ID only — the part before the %3A%3A separator.
    sed -n 's/.*WorkosCursorSessionToken=\([^%]*\)%3A%3A.*/\1/p' "$STUB_CURL_STDIN" \
      | head -n 1 >> "$STUB_CURSOR_UID_LOG"
    case "$mode" in
      ok|plan500)
        case "$url" in
          *get-current-period-usage)  cat "$STUB_CURSOR_USAGE" > "$out"; printf '200' ;;
          *get-plan-info)
            if [[ "$mode" == "plan500" ]]; then printf 'oops' > "$out"; printf '500'
            else cat "$STUB_CURSOR_PLAN" > "$out"; printf '200'; fi ;;
          *get-monthly-billing-cycle) cat "$STUB_CURSOR_CYCLE" > "$out"; printf '200' ;;
          *) echo "STUB-CURL: unexpected cursor endpoint '$url'" >&2; exit 95 ;;
        esac ;;
      shape)
        # HTTP 200, recognisable JSON, no pool percentages anywhere in it.
        printf '{"somethingElse":{},"displayMessage":"hi"}' > "$out"; printf '200' ;;
      unauth) printf '{"error":"unauthorized"}' > "$out"; printf '401' ;;
      server) printf 'oops' > "$out"; printf '500' ;;
      down)   echo "STUB-CURL: simulated cursor network failure" >&2; exit 7 ;;
      *) echo "STUB-CURL: unknown cursor mode '$mode'" >&2; exit 96 ;;
    esac
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
# The DB is "service<TAB>account<TAB>value", one item per line.
sub="${1:-}"; shift || true
want=""; want_value=0; acct=""; update=0

# A credential must never reach this argv — not on the read, and not on the
# write-back, which is the whole reason the real call takes its value on
# stdin. Asserted before anything is parsed.
case "$*" in
  *sk-ant*|*eyJ*) echo "STUB-SECURITY: a credential value reached argv" >&2; exit 90 ;;
esac

while [[ $# -gt 0 ]]; do
  case "$1" in
    -s) want="${2:-}"; shift 2 ;;
    -a) acct="${2:-}"; shift 2 ;;
    -U) update=1; shift ;;
    # `-w` LAST and valueless is what makes the real security(1) read the
    # value from stdin. A `-w <value>` here would be a credential in argv and
    # is refused above; a bare trailing `-w` is the supported shape.
    -w) want_value=1; shift ;;
    *) shift ;;
  esac
done
[[ -n "$want" ]] || exit 1
printf '%s\t%s\t%s\n' "$sub" "$want" "$want_value" >> "$STUB_SECURITY_LOG"

case "$sub" in
  find-generic-password)
    line="$(grep -F "$want	" "$STUB_KEYCHAIN_DB" 2>/dev/null | head -n 1)"
    [[ -n "$line" ]] || exit 44
    rest="${line#*	}"          # account<TAB>value
    if [[ "$want_value" -eq 1 ]]; then
      # Race simulation (#1716): when this service is armed, the SECOND and
      # later value reads answer with a DIFFERENT access token — somebody else
      # (a concurrent /quotas, or Claude Code) renewed the item while this run
      # was at the token endpoint. The reader's write-back must stand down.
      # The second read is precisely the compare-and-set's own re-read, which
      # is what makes this fixture exercise it rather than merely accompany it.
      if [[ -n "${STUB_KEYCHAIN_RACE:-}" && "$want" == "$(cat "$STUB_KEYCHAIN_RACE" 2>/dev/null)" ]]; then
        n="$(cat "$STUB_KEYCHAIN_RACE_N" 2>/dev/null || echo 0)"
        printf '%s' $(( n + 1 )) > "$STUB_KEYCHAIN_RACE_N"
        if [[ "$n" -ge 1 ]]; then
          # `gone` models the item vanishing between the read and the write —
          # a revoked permission, a deleted item. That is a FAILURE to
          # disclose, and must not be folded into "somebody else won".
          if [[ "$(cat "$STUB_KEYCHAIN_RACE_MODE" 2>/dev/null || echo swap)" == "gone" ]]; then
            exit 44
          fi
          printf '%s' "${rest#*	}" \
            | jq -c --arg w "$STUB_RACE_WINNER" '.claudeAiOauth.accessToken = $w'
          exit 0
        fi
      fi
      printf '%s\n' "${rest#*	}"
    else
      # The attribute dump, in the layout the real tool prints — the reader
      # parses `acct` out of it to aim its update at the same item.
      printf 'keychain: "/fake/login.keychain-db"\n'
      printf '    "acct"<blob>="%s"\n' "${rest%%	*}"
      printf '    "svce"<blob>="%s"\n' "$want"
    fi
    exit 0 ;;
  add-generic-password)
    [[ "$update" -eq 1 ]] || { echo "STUB-SECURITY: add without -U would refuse an existing item" >&2; exit 91; }
    [[ "$want_value" -eq 1 ]] || { echo "STUB-SECURITY: add-generic-password with no -w" >&2; exit 92; }
    # The real tool asks for the value TWICE (measured 2026-09-14: "password
    # data for new item:" then "retype password for new item:") and refuses
    # the write when the two differ. A reader that sent it once would hang
    # the real call waiting on the retype, so the stub insists on both.
    IFS= read -r first || { echo "STUB-SECURITY: no value on stdin" >&2; exit 93; }
    IFS= read -r second || { echo "STUB-SECURITY: value sent once, not retyped" >&2; exit 94; }
    [[ "$first" == "$second" ]] || { echo "STUB-SECURITY: the two values differ" >&2; exit 95; }
    tmp="$(mktemp)"
    grep -v -F "$want	" "$STUB_KEYCHAIN_DB" > "$tmp" 2>/dev/null || true
    printf '%s\t%s\t%s\n' "$want" "$acct" "$first" >> "$tmp"
    mv -f "$tmp" "$STUB_KEYCHAIN_DB"
    exit 0 ;;
  *) echo "STUB-SECURITY: unexpected subcommand '$sub'" >&2; exit 96 ;;
esac
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
# Claude token renewal (#1716): the token endpoint's behaviour, the body the
# reader sent it, and the 401-once counter.
export STUB_TOKEN_MODE="$TMP/token.mode"
export STUB_CURL_BODY="$TMP/curl.body"
export STUB_ANTHROPIC_401_COUNT="$TMP/anthropic.401count"
# The renewed pair the token endpoint hands back. Credential-SHAPED, and
# DIFFERENT from the seeded pair, so every assertion below distinguishes "the
# renewed token was used and stored" from "nothing happened".
export STUB_NEW_ACCESS="sk-ant-oat01-FAKE-RENEWED-2Q3R4S"
export STUB_NEW_REFRESH="sk-ant-ort01-FAKE-ROTATED-5T6U7V"
# The concurrent-writer simulation: which service races, how many value reads
# it has served, and what the OTHER writer left in the item.
export STUB_KEYCHAIN_RACE="$TMP/keychain.race"
export STUB_KEYCHAIN_RACE_N="$TMP/keychain.race.n"
export STUB_KEYCHAIN_RACE_MODE="$TMP/keychain.race.mode"
export STUB_RACE_WINNER="sk-ant-oat01-FAKE-OTHERWRITER-8W9X0Y"
export STUB_CHATGPT_BODY="$TMP/chatgpt.json"
# Cursor IDE-token path (#1703). Three payload fixtures, a mode file, and a log
# of the USER ID the reader derived — the user id only, never the token, so no
# file this suite writes can make a leak assertion pass or fail for the wrong
# reason.
export STUB_CURSOR_USAGE="$TMP/cursor-usage.json"
export STUB_CURSOR_PLAN="$TMP/cursor-plan.json"
export STUB_CURSOR_CYCLE="$TMP/cursor-cycle.json"
export STUB_CURSOR_MODE="$TMP/cursor.mode"
export STUB_CURSOR_UID_LOG="$TMP/cursor-uid.log"

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

# The seeded item carries the SHAPE Claude Code really writes (observed
# 2026-09-14): a refresh token, an `expiresAt` in MILLISECONDS, `scopes`, and
# a `subscriptionType` this reader does not read. The extra fields are not
# decoration — they are what the write-back assertions prove was PRESERVED.
#
# <expires-at-ms> defaults to well in the future, so every pre-#1716 case
# still takes the no-refresh path unchanged; the renewal cases pass a past
# value. "" means the field is absent altogether, which is the store shape
# that must NOT provoke a refresh on every read.
seed_claude_profile() { # <label> <keychain-service|""> [<expires-at-ms|"">]
  # Declared separately on purpose: `local a="$1" b="$PROFILES/$a"` expands
  # every argument BEFORE any of them is assigned, so `$a` is still unset.
  local label="$1"
  local service="$2"
  local expires="${3-$(( (NOW + 3600) * 1000 ))}"
  local dir="$PROFILES/$label/claude"
  local doc
  mkdir -p "$dir"
  if [[ -n "$service" ]]; then
    doc="$(jq -cn --arg at "$CLAUDE_SECRET" --arg rt "$CLAUDE_REFRESH_SECRET" --arg ea "$expires" \
      '{claudeAiOauth: ({accessToken: $at, refreshToken: $rt,
                         scopes: ["user:inference","user:profile"],
                         subscriptionType: "max"}
        + (if $ea == "" then {} else {expiresAt: ($ea | tonumber)} end))}')"
    printf '%s\t%s\t%s\n' "$service" "$CLAUDE_KEYCHAIN_ACCT" "$doc" >> "$STUB_KEYCHAIN_DB"
  fi
  printf '%s' "$dir"
}

# What the fake keychain item now holds for <service>, as JSON. The assertions
# read it through jq rather than by substring so "the renewed pair landed"
# and "the fields nobody touched survived" are separate questions.
keychain_doc() { # <service>
  grep -F "$1	" "$STUB_KEYCHAIN_DB" 2>/dev/null | head -n 1 | cut -f3-
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

# --- cursor fixtures (#1703) -------------------------------------------------
# A REAL sqlite3 builds a REAL state store, and the reader is pointed at it
# through AI_QUOTAS_CURSOR_STATE_DB. sqlite3 is deliberately not stubbed: the
# thing most likely to break here is the query and the read-only open, and a
# fake would assert nothing about either. No test touches the real IDE store.
# Resolved, then PROVEN executable. Defaulting a failed lookup to a hardcoded
# path that may not exist turns "sqlite3 is missing" into a pile of unrelated
# cursor failures several hundred lines later (CodeAnt).
SQLITE3_REAL="$(command -v sqlite3 2>/dev/null || true)"
[[ -n "$SQLITE3_REAL" ]] || SQLITE3_REAL="/usr/bin/sqlite3"
[[ -x "$SQLITE3_REAL" ]] || {
  echo "FATAL: no usable sqlite3 (checked PATH and /usr/bin/sqlite3) — the cursor cases cannot run" >&2
  exit 1
}
CURSOR_DB="$TMP/cursor-state.vscdb"
CURSOR_DB_SIGNED_OUT="$TMP/cursor-signed-out.vscdb"
CURSOR_DB_MISSING="$TMP/no-such-cursor-state.vscdb"

# The fixture `sub` carries a discriminating marker AND the `google-oauth2|`
# prefix measured on the real account, so a reader that "strips the provider
# prefix" by taking the segment after the final `|` fails this suite instead of
# shipping and answering 401 (#1703).
CURSOR_FIXTURE_SUB='google-oauth2|FIXTURE-CURSOR-USER-1703'
b64url() { printf '%s' "$1" | base64 | tr -d '=\n' | tr '/+' '_-'; }
CURSOR_FIXTURE_TOKEN="$(b64url '{"alg":"HS256","typ":"JWT"}').$(b64url "{\"sub\":\"${CURSOR_FIXTURE_SUB}\"}").FIXTURESIGNATURE"
CURSOR_FIXTURE_EMAIL="cursor-fixture@example.com"

build_cursor_db() { # <path> <token|"">
  rm -f "$1"
  # WAL, like the real IDE store (CodeRabbit). The whole read-only-without-a-
  # copy design rests on this being a WAL database — a fixture left in the
  # default rollback-journal mode would exercise a different open path than
  # the one that ships, and pass without ever testing it. `journal_mode` is a
  # persistent property of the file, so it survives the CLI closing its
  # connection even though the -wal sidecar is checkpointed away with it.
  "$SQLITE3_REAL" "$1" "PRAGMA journal_mode=WAL;" >/dev/null || return 1
  "$SQLITE3_REAL" "$1" "create table ItemTable (key TEXT PRIMARY KEY, value BLOB);" || return 1
  "$SQLITE3_REAL" "$1" \
    "insert into ItemTable (key, value) values ('cursorAuth/cachedEmail', '${CURSOR_FIXTURE_EMAIL}');" || return 1
  if [[ -n "${2:-}" ]]; then
    "$SQLITE3_REAL" "$1" \
      "insert into ItemTable (key, value) values ('cursorAuth/accessToken', '$2');" || return 1
  fi
  return 0
}

# Captured from the owner's live account on 2026-09-11, trimmed to the keys the
# reader reads. Dollars are CENTS and the cycle is MILLISECONDS, exactly as the
# dashboard sends them — a fixture that pre-converted either would let a broken
# conversion pass.
cursor_usage_body() {
  cat <<'JSON'
{"billingCycleStart":"1787933374000","billingCycleEnd":"1790611774000",
 "planUsage":{"totalSpend":209243,"includedSpend":40000,"limit":40000,
              "autoPercentUsed":53.034333333333336,"apiPercentUsed":100,
              "totalPercentUsed":59.78371428571428},
 "spendLimitUsage":{"totalSpend":100750,"individualLimit":100000,
                    "individualUsed":100750,"limitType":"user"},
 "displayMessage":"You have hit your usage limit"}
JSON
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

# Which Cursor state store a case reads. Defaults to the signed-in fixture;
# cases set it to the signed-out or missing one and reset it afterwards. It is
# ALWAYS one of this suite's own temp paths — the real IDE store at
# ~/Library/… is never reachable from here, because the seam is passed
# unconditionally rather than left to fall through to the reader's default.
CURSOR_DB_UNDER_TEST=""
# Which sqlite3 a case resolves. Empty means the real one; a case sets it to a
# path that does not exist to exercise the reader's missing-tool branch.
SQLITE3_BIN_UNDER_TEST=""
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
        AI_QUOTAS_CLAUDE_TOKEN_URL="https://stub.invalid/v1/oauth/token" \
        AI_QUOTAS_CLAUDE_CLIENT_ID="fixture-client-id-1716" \
        AI_QUOTAS_CODEX_TIMEOUT="${AI_QUOTAS_CODEX_TIMEOUT_OVERRIDE-10}" \
        AI_QUOTAS_CHEAPEST_BIN="${CHEAPEST_BIN_OVERRIDE-}" \
        AI_QUOTAS_FORECAST_BIN="${FORECAST_BIN_OVERRIDE-}" \
        AI_QUOTAS_SQLITE3_BIN="${SQLITE3_BIN_UNDER_TEST:-$SQLITE3_REAL}" \
        AI_QUOTAS_CURSOR_STATE_DB="${CURSOR_DB_UNDER_TEST:-$CURSOR_DB}" \
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
  echo "ok" > "$STUB_TOKEN_MODE"
  : > "$STUB_CURL_BODY"
  : > "$STUB_KEYCHAIN_RACE"
  printf '0' > "$STUB_KEYCHAIN_RACE_N"
  printf 'swap' > "$STUB_KEYCHAIN_RACE_MODE"
  printf '0' > "$STUB_ANTHROPIC_401_COUNT"
  anthropic_body 0 > "$STUB_ANTHROPIC_BODY"
  jq -n '{}' > "$STUB_CHATGPT_BODY"
  echo "ok" > "$STUB_CURSOR_MODE"
  : > "$STUB_CURSOR_UID_LOG"
  CURSOR_DB_UNDER_TEST=""
  SQLITE3_BIN_UNDER_TEST=""
  cursor_usage_body > "$STUB_CURSOR_USAGE"
  printf '%s' '{"planInfo":{"planName":"Ultra","includedAmountCents":40000,"price":"$200/mo","billingCycleEnd":"1790611774000"}}' > "$STUB_CURSOR_PLAN"
  printf '%s' '{"startDateEpochMillis":"1787933374000","endDateEpochMillis":"1790611774000"}' > "$STUB_CURSOR_CYCLE"
}

# Built once: the fixture stores are immutable, and rebuilding a SQLite file
# before every case would cost more than it proves.
build_cursor_db "$CURSOR_DB" "$CURSOR_FIXTURE_TOKEN" \
  || { echo "FATAL: could not build the cursor fixture DB with $SQLITE3_REAL" >&2; exit 1; }
build_cursor_db "$CURSOR_DB_SIGNED_OUT" "" \
  || { echo "FATAL: could not build the signed-out cursor fixture DB" >&2; exit 1; }
rm -f "$CURSOR_DB_MISSING"

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
# Field 2 is the service; field 1 became the SUBCOMMAND when the stub grew a
# write path (#1716), and field 3 is whether a value was asked for.
check_eq "$(cut -f2 "$STUB_SECURITY_LOG" | sort -u | tr '\n' '|')" \
  "Claude Code-credentials-AAA|Claude Code-credentials-BBB|" \
  "the reader asked the keychain only for the two services the registry records"
# And it only ever READ them here: nothing in this case is expired, so no
# write-back is due. A reader that wrote on every read would redden this.
check_eq "$(cut -f1 "$STUB_SECURITY_LOG" | sort -u | tr '\n' '|')" \
  "find-generic-password|" \
  "and only read them — an unexpired credential is never written back"

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

# --- 12r. renewing an expired access token (#1716) ---------------------------
#
# The failure this section exists to prevent: both Claude rows went dark three
# days after login because nobody had opened Claude Code on those isolated
# profiles, so nothing refreshed their access tokens — while the stored
# credential held a perfectly good refresh token the whole time.
#
# What is asserted is not just "the row says ok". It is that the reader used
# the RENEWED token for the usage call and wrote the RENEWED pair back into
# the same item Claude Code reads, because a renewal that is not persisted
# costs a fresh refresh on every run and leaves the two clients holding
# different halves of a rotated credential.

SVC_R="Claude Code-credentials-RENEW"

seed_renewal_case() { # <expires-at-ms|"">
  reset_state
  CR="$(seed_claude_profile claude-one@example.com "$SVC_R" "$1")"
  write_config "$(account_json claude claude-one@example.com "$CR" "$SVC_R")"
}

# --- 12r-a. an expired stored token is renewed BEFORE the usage call ---------

seed_renewal_case "$(( (NOW - 60) * 1000 ))"
run --json
check_eq "$(rows_for claude-one@example.com)" "ok" \
  "an expired stored token is renewed and the row reads ok, not needs-login"
check_eq "$(field_of claude-one@example.com "7-day" used_pct)" "64" \
  "and the figures really were read, on the renewed token"

# The usage call carried the RENEWED token, not the expired one. This is the
# assertion that separates "refreshed" from "refreshed and then used the old
# one anyway" — a reader that renewed into a variable nobody read would pass
# every status check above and fail here.
check_contains "$(cat "$STUB_CURL_STDIN")" "Authorization: Bearer $STUB_NEW_ACCESS" \
  "the usage request carried the RENEWED access token"
check_not_contains "$(cat "$STUB_CURL_STDIN")" "Bearer $CLAUDE_SECRET" \
  "and never the expired one"

# The renewal request itself: the stored refresh token, the configured client
# id, and the stored scopes — sent as a BODY FILE, so none of it is in argv.
check_eq "$(jq -r '.grant_type' "$STUB_CURL_BODY" 2>/dev/null)" "refresh_token" \
  "the renewal is a refresh_token grant"
check_eq "$(jq -r '.refresh_token' "$STUB_CURL_BODY" 2>/dev/null)" "$CLAUDE_REFRESH_SECRET" \
  "it sends the refresh token from the same keychain item, never a hand-typed one"
check_eq "$(jq -r '.client_id' "$STUB_CURL_BODY" 2>/dev/null)" "fixture-client-id-1716" \
  "with the client id from the seam"
check_eq "$(jq -r '.scope' "$STUB_CURL_BODY" 2>/dev/null)" "user:inference user:profile" \
  "and the stored scopes, space-joined as the endpoint wants them"

# The write-back. Read through jq, field by field, so a partial write cannot
# pass as a whole one.
check_eq "$(keychain_doc "$SVC_R" | jq -r '.claudeAiOauth.accessToken')" "$STUB_NEW_ACCESS" \
  "the renewed access token was written back into the same keychain item"
check_eq "$(keychain_doc "$SVC_R" | jq -r '.claudeAiOauth.refreshToken')" "$STUB_NEW_REFRESH" \
  "and so was the rotated refresh token"
check_eq "$(keychain_doc "$SVC_R" | jq -r '.claudeAiOauth.expiresAt')" "$(( (NOW + 3600) * 1000 ))" \
  "the stored expiry is now + expires_in, in milliseconds"
# Claude Code owns these. A write-back that replaced the document instead of
# merging into it would break the very client this is keeping in step.
check_eq "$(keychain_doc "$SVC_R" | jq -r '.claudeAiOauth.subscriptionType')" "max" \
  "fields this reader does not read survive the write-back"
check_eq "$(keychain_doc "$SVC_R" | jq -c '.claudeAiOauth.scopes')" '["user:inference","user:profile"]' \
  "and so do the stored scopes"
# One item, not two: the update carried the existing `acct` attribute.
check_eq "$(grep -c -F "$SVC_R	" "$STUB_KEYCHAIN_DB")" "1" \
  "the write-back UPDATED the existing item rather than adding a second one"
check_eq "$(grep -F "$SVC_R	" "$STUB_KEYCHAIN_DB" | head -n 1 | cut -f2)" "$CLAUDE_KEYCHAIN_ACCT" \
  "and kept its account attribute, which is what makes it the same item"

# --- 12r-b. a 401 on a token the store believed good: one refresh, one retry -

seed_renewal_case ""            # no stored expiry at all
echo "unauth_once" > "$STUB_ANTHROPIC_MODE"
run --json
check_eq "$(rows_for claude-one@example.com)" "ok" \
  "a 401 on a non-expired token is renewed and retried, and the row reads ok"
check_eq "$(field_of claude-one@example.com "7-day" used_pct)" "64" \
  "and the retry really returned the figures"
# Exactly three calls: usage (401), token, usage (200). A reader that looped
# would show more, and the count is the only thing that can tell the two apart
# once both end at 200.
check_eq "$(grep -c . "$STUB_CURL_LOG")" "3" \
  "exactly one refresh and one retry — never a loop"
echo "ok" > "$STUB_ANTHROPIC_MODE"

# A store with NO expiry must not provoke a refresh on every read: the
# renewal above happened because of the 401, not because the field was
# missing. Without this the reader would burn a refresh per account per run.
seed_renewal_case ""
run --json
check_eq "$(rows_for claude-one@example.com)" "ok" "a store with no expiry still reads ok"
check_eq "$(grep -c 'oauth/token' "$STUB_CURL_LOG" || true)" "0" \
  "and an absent expiry alone never triggers a refresh"

# A token still inside its stored lifetime is used as-is.
seed_renewal_case "$(( (NOW + 3600) * 1000 ))"
run --json
check_eq "$(grep -c 'oauth/token' "$STUB_CURL_LOG" || true)" "0" \
  "a token still within its stored lifetime is used without a refresh"

# --- 12r-c. a rejected grant is needs-login, with the relogin command --------

seed_renewal_case "$(( (NOW - 60) * 1000 ))"
echo "invalid_grant" > "$STUB_TOKEN_MODE"
run --json
check_eq "$(rows_for claude-one@example.com)" "needs-login" \
  "a refresh the endpoint rejects is needs-login"
check_contains "$(field_of claude-one@example.com "7-day" detail)" "invalid_grant" \
  "the note names the OAuth error code it actually got back"
check_contains "$(field_of claude-one@example.com "7-day" detail)" \
  "/quotas-setup relogin claude-one@example.com claude" \
  "and carries the existing relogin command"
# A dead grant must not be written anywhere. The item still holds what it held.
check_eq "$(keychain_doc "$SVC_R" | jq -r '.claudeAiOauth.accessToken')" "$CLAUDE_SECRET" \
  "a rejected refresh writes nothing back"

# --- 12r-d. an unreachable token endpoint is unreachable, never needs-login --
#
# The distinction is the point: needs-login sends the owner through an
# interactive login, and a login cannot fix a network that is down.

seed_renewal_case "$(( (NOW - 60) * 1000 ))"
echo "down" > "$STUB_TOKEN_MODE"
run --json
check_eq "$(rows_for claude-one@example.com)" "unreachable" \
  "a token endpoint that cannot be reached is unreachable, not needs-login"
check_not_contains "$(field_of claude-one@example.com "7-day" detail)" "/quotas-setup relogin" \
  "and does not tell the owner to log in over a network failure"

seed_renewal_case "$(( (NOW - 60) * 1000 ))"
echo "server" > "$STUB_TOKEN_MODE"
run --json
check_eq "$(rows_for claude-one@example.com)" "unreachable" \
  "a 500 from the token endpoint is unreachable too"
check_contains "$(field_of claude-one@example.com "7-day" detail)" "HTTP 500" \
  "with the status it answered"

# HTTP 200 carrying no access token is a CHANGED SHAPE, not a dead login.
seed_renewal_case "$(( (NOW - 60) * 1000 ))"
echo "noshape" > "$STUB_TOKEN_MODE"
run --json
check_eq "$(rows_for claude-one@example.com)" "unreachable" \
  "a 200 with no access token in it is unreachable, never a silent success"
check_contains "$(field_of claude-one@example.com "7-day" detail)" "no access token" \
  "and says what was wrong with the response"

# A bare 403 with no OAuth error code is an edge proxy, not a dead grant.
# Sending the owner through an interactive login over a WAF block is the
# misdiagnosis the needs-login/unreachable split exists to prevent.
seed_renewal_case "$(( (NOW - 60) * 1000 ))"
echo "proxy403" > "$STUB_TOKEN_MODE"
run --json
check_eq "$(rows_for claude-one@example.com)" "unreachable" \
  "a 403 carrying no OAuth error code is unreachable, not a dead grant"
check_not_contains "$(field_of claude-one@example.com "7-day" detail)" "/quotas-setup relogin" \
  "and does not send the owner through a login a proxy block would not fix"

# --- 12r-d2. a rate-limited token endpoint says rate-limited -----------------
#
# Measured on the live endpoint 2026-09-14: HTTP 429 through Cloudflare with
# `{"error":{"type":"rate_limit_error"}}`. `unreachable` would record a week of
# outages in the snapshot history that never happened, and `needs-login` would
# send the owner through a login that fixes nothing. The reader already has the
# status that says exactly this.

seed_renewal_case "$(( (NOW - 60) * 1000 ))"
echo "ratelimit" > "$STUB_TOKEN_MODE"
run --json
check_eq "$(rows_for claude-one@example.com)" "rate-limited" \
  "a 429 from the token endpoint reads rate-limited, not unreachable"
check_not_contains "$(field_of claude-one@example.com "7-day" detail)" "/quotas-setup relogin" \
  "and never tells the owner to log in over a rate limit"
check_eq "$(keychain_doc "$SVC_R" | jq -r '.claudeAiOauth.accessToken')" "$CLAUDE_SECRET" \
  "a rate-limited refresh writes nothing back"

seed_renewal_case "$(( (NOW - 60) * 1000 ))"
echo "ratelimit_retry" > "$STUB_TOKEN_MODE"
run --json
check_contains "$(field_of claude-one@example.com "7-day" detail)" "retry after 900s" \
  "and a Retry-After header is reported as a duration"

# --- 12r-d3. a dead grant in Anthropic's NESTED envelope is still needs-login -
#
# The live endpoint sends {"error":{"type":…}}, not RFC 6749's flat
# {"error":"…"}. A reader that only understood the flat shape would call a
# genuinely dead grant `unreachable` and never tell the owner to log in.

seed_renewal_case "$(( (NOW - 60) * 1000 ))"
echo "nested_invalid_grant" > "$STUB_TOKEN_MODE"
run --json
check_eq "$(rows_for claude-one@example.com)" "needs-login" \
  "an invalid_grant in the nested envelope is still a dead grant"
check_contains "$(field_of claude-one@example.com "7-day" detail)" "invalid_grant" \
  "and the note names the code it found inside that envelope"
check_contains "$(field_of claude-one@example.com "7-day" detail)" \
  "/quotas-setup relogin claude-one@example.com claude" \
  "with the relogin command"
# The `message` beside that code is never echoed: an endpoint that put the
# submitted token in an error string would otherwise print it.
check_not_contains "$(field_of claude-one@example.com "7-day" detail)" "refresh token expired" \
  "the human-readable message beside the code is not echoed"
echo "ok" > "$STUB_TOKEN_MODE"

# --- 12r-e. a response that omits refresh_token keeps the stored one ---------

seed_renewal_case "$(( (NOW - 60) * 1000 ))"
echo "norotate" > "$STUB_TOKEN_MODE"
run --json
check_eq "$(rows_for claude-one@example.com)" "ok" "a response with no rotated refresh token still renews"
check_eq "$(keychain_doc "$SVC_R" | jq -r '.claudeAiOauth.refreshToken')" "$CLAUDE_REFRESH_SECRET" \
  "and the stored refresh token is kept rather than blanked"
# `norotate` also omits nothing else — expires_in IS present here, so the
# expiry is rewritten. The DELETE case is asserted separately below, where
# the response omits expires_in.
echo "ok" > "$STUB_TOKEN_MODE"

# --- 12r-e2. an unknown new expiry DELETES the stored one --------------------
#
# Leaving the old value would park a PAST timestamp beside a freshly renewed
# token, and every later run would read that as "expired" and spend another
# refresh for ever. Absent is the honest state: unknown.

seed_renewal_case "$(( (NOW - 60) * 1000 ))"
echo "noexpiry" > "$STUB_TOKEN_MODE"
run --json
check_eq "$(rows_for claude-one@example.com)" "ok" "a renewal with no expires_in still reads ok"
check_eq "$(keychain_doc "$SVC_R" | jq -r '.claudeAiOauth | has("expiresAt")')" "false" \
  "and the stale expiry is DELETED, not left behind to force a refresh every run"
check_eq "$(keychain_doc "$SVC_R" | jq -r '.claudeAiOauth.accessToken')" "$STUB_NEW_ACCESS" \
  "control(+): the renewal itself still landed"
echo "ok" > "$STUB_TOKEN_MODE"

# --- 12r-e3. an unparseable keychain item refuses the write-back -------------
#
# `-a ""` does not update the existing item — it creates a SECOND one beside
# the one Claude Code reads. Refusing is the only safe answer; the figures
# were still read, so the row stays ok and discloses the miss.

seed_renewal_case "$(( (NOW - 60) * 1000 ))"
# Blank the account column, which is what the reader parses out of the
# attribute dump. Done with awk on tab fields rather than a sed pattern: the
# service name contains spaces and hyphens, and the separators are tabs.
awk -F'\t' -v OFS='\t' '{ $2 = ""; print }' "$STUB_KEYCHAIN_DB" > "$TMP/acctless.db"
mv -f "$TMP/acctless.db" "$STUB_KEYCHAIN_DB"
check_eq "$(grep -F "$SVC_R	" "$STUB_KEYCHAIN_DB" | head -n 1 | cut -f2)" "" \
  "control(+): the fixture item really has no account attribute to find"
run --json
check_eq "$(rows_for claude-one@example.com)" "ok" \
  "a write-back that cannot identify the item still reports the figures it read"
check_contains "$(field_of claude-one@example.com "7-day" detail)" "could not be written back" \
  "and discloses that the renewal was not persisted rather than failing silently"
check_eq "$(grep -c -F "$SVC_R	" "$STUB_KEYCHAIN_DB")" "1" \
  "and no second keychain item was created beside the one Claude Code reads"

# --- 12r-f. the Linux path renews and rewrites the file, mode 600 ------------
#
# `<profile_dir>/.credentials.json` is the same credential in a different
# store. A renewal path that only covered the Keychain would leave every Linux
# install exactly as dark as the bug being fixed.

reset_state
LDIR="$PROFILES/linux-one/claude"
mkdir -p "$LDIR"
jq -n --arg at "$CLAUDE_SECRET" --arg rt "$CLAUDE_REFRESH_SECRET" \
      --argjson ea "$(( (NOW - 60) * 1000 ))" \
  '{claudeAiOauth: {accessToken: $at, refreshToken: $rt, expiresAt: $ea,
                    scopes: ["user:inference"], subscriptionType: "max"}}' \
  > "$LDIR/.credentials.json"
chmod 600 "$LDIR/.credentials.json"
write_config "$(account_json claude linux-one "$LDIR")"
run --json
check_eq "$(rows_for linux-one)" "ok" "the file-backed credential is renewed too"
check_eq "$(jq -r '.claudeAiOauth.accessToken' "$LDIR/.credentials.json")" "$STUB_NEW_ACCESS" \
  "and the renewed access token was written back to the file"
check_eq "$(jq -r '.claudeAiOauth.refreshToken' "$LDIR/.credentials.json")" "$STUB_NEW_REFRESH" \
  "along with the rotated refresh token"
check_eq "$(jq -r '.claudeAiOauth.subscriptionType' "$LDIR/.credentials.json")" "max" \
  "preserving the fields this reader does not read"
# The rewrite must not widen the file. A credential world-readable after a
# renewal is a worse outcome than the row that was being fixed.
check_eq "$(ls -l "$LDIR/.credentials.json" | cut -c1-10)" "-rw-------" \
  "and the rewritten file is still mode 600"

# --- 12r-f2. a concurrent renewal is never clobbered -------------------------
#
# Claude Code renews this same item, and the daily job can overlap a manual
# run. Refresh tokens ROTATE, so a blind last-writer-wins store can leave the
# item holding a token the server already invalidated — and the NEXT run then
# reads `needs-login` on a login nobody actually lost. The write-back re-reads
# the store and stands down when it no longer holds what this run started from.

seed_renewal_case "$(( (NOW - 60) * 1000 ))"
printf '%s' "$SVC_R" > "$STUB_KEYCHAIN_RACE"
printf '0' > "$STUB_KEYCHAIN_RACE_N"
run --json
check_eq "$(rows_for claude-one@example.com)" "ok" \
  "a renewal that lost a race still reports the figures it read"
# The other writer's credential is what survives — ours is the stale one.
check_eq "$(keychain_doc "$SVC_R" | jq -r '.claudeAiOauth.accessToken')" "$CLAUDE_SECRET" \
  "and the item was NOT overwritten with this run's renewal"
check_eq "$(grep -c 'add-generic-password' "$STUB_SECURITY_LOG" || true)" "0" \
  "the write was not merely harmless — it never happened at all"
# Losing a race costs nothing, so it must not be reported as a problem.
check_eq "$(field_of claude-one@example.com "7-day" detail)" "" \
  "losing a race to another writer is not a defect and is not disclosed"
: > "$STUB_KEYCHAIN_RACE"
printf '0' > "$STUB_KEYCHAIN_RACE_N"

# Control: with the race disarmed, the very same fixture DOES write back — so
# the assertions above are measuring the stand-down, not a write-back that was
# broken for some unrelated reason.
seed_renewal_case "$(( (NOW - 60) * 1000 ))"
run --json
check_eq "$(keychain_doc "$SVC_R" | jq -r '.claudeAiOauth.accessToken')" "$STUB_NEW_ACCESS" \
  "control(+): unraced, the identical fixture writes the renewal back"

# A store that cannot be read at write-back time is a FAILURE, not a race.
# Folding the two together would let a vanished item, a revoked permission, or
# a truncated file report as "somebody else renewed" — a silent no-op wearing a
# reassuring explanation.
seed_renewal_case "$(( (NOW - 60) * 1000 ))"
printf '%s' "$SVC_R" > "$STUB_KEYCHAIN_RACE"
printf '0' > "$STUB_KEYCHAIN_RACE_N"
printf 'gone' > "$STUB_KEYCHAIN_RACE_MODE"
run --json
check_eq "$(rows_for claude-one@example.com)" "ok" \
  "an unreadable store at write-back time still reports the figures it read"
check_contains "$(field_of claude-one@example.com "7-day" detail)" "could not be written back" \
  "but DISCLOSES the failure rather than reporting it as a lost race"
: > "$STUB_KEYCHAIN_RACE"
printf '0' > "$STUB_KEYCHAIN_RACE_N"
printf 'swap' > "$STUB_KEYCHAIN_RACE_MODE"

# --- 12r-f3. invalid_grant caused by SOMEBODY ELSE renewing is not a dead login
#
# The other half of the rotation problem. When Claude Code (or a concurrent
# /quotas) renews first, the refresh token THIS run holds is invalidated *by
# that rotation*, and the endpoint answers invalid_grant. Believed at face
# value the row says `needs-login` about an account whose credential is in the
# store, freshly renewed and perfectly good — the exact false `needs-login`
# this whole change exists to remove.

seed_renewal_case "$(( (NOW - 60) * 1000 ))"
printf '%s' "$SVC_R" > "$STUB_KEYCHAIN_RACE"
printf '0' > "$STUB_KEYCHAIN_RACE_N"
echo "invalid_grant" > "$STUB_TOKEN_MODE"
run --json
check_eq "$(rows_for claude-one@example.com)" "ok" \
  "an invalid_grant explained by another writer's renewal is not needs-login"
check_contains "$(cat "$STUB_CURL_STDIN")" "Authorization: Bearer $STUB_RACE_WINNER" \
  "the usage call used the credential that other writer left behind"
check_eq "$(field_of claude-one@example.com "7-day" used_pct)" "64" \
  "and the figures were read on it"
: > "$STUB_KEYCHAIN_RACE"
printf '0' > "$STUB_KEYCHAIN_RACE_N"

# Control: the SAME invalid_grant with nobody else writing is still a dead
# login. Without this the check above would pass on a reader that had simply
# stopped reporting needs-login at all.
seed_renewal_case "$(( (NOW - 60) * 1000 ))"
echo "invalid_grant" > "$STUB_TOKEN_MODE"
run --json
check_eq "$(rows_for claude-one@example.com)" "needs-login" \
  "control(-): unraced, the same invalid_grant is still a dead login"
echo "ok" > "$STUB_TOKEN_MODE"

# --- 12r-g. no credential reaches argv on the renewal path -------------------
#
# Both stubs hard-fail on a secret in argv (curl exit 90, security exit 90), so
# the clean runs above are already that assertion. What is asserted here is the
# CONTROL: that the renewal really happened, or every check in this section
# would be passing over a code path nothing exercised.

seed_renewal_case "$(( (NOW - 60) * 1000 ))"
run --json
check_eq "$(grep -c 'oauth/token' "$STUB_CURL_LOG" || true)" "1" \
  "control(+): the renewal path under these assertions really did run"
check_eq "$(grep -c 'add-generic-password' "$STUB_SECURITY_LOG" || true)" "1" \
  "control(+): and it really did write back, exactly once"
COMBINED="$OUT
$ERR"
check_not_contains "$COMBINED" "$CLAUDE_REFRESH_SECRET" \
  "the refresh token never reaches stdout or stderr"
check_not_contains "$COMBINED" "$STUB_NEW_REFRESH" \
  "and neither does the rotated one"
check_not_contains "$COMBINED" "$STUB_NEW_ACCESS" \
  "nor the renewed access token"
check_eq "$(printf '%s' "$COMBINED" | grep -cE 'sk-ant|eyJ|refresh_token=' || true)" "0" \
  "and nothing token-shaped appears anywhere in the output"

# --- 12r-h. no token is handed to a helper on ITS command line ---------------
#
# The stubs assert this for `curl` and `security`, because the reader invokes
# them through seams the suite controls. `jq` has no seam — it is the real one
# — so a `jq --arg rt "$CLAUDE_REFRESH_TOKEN"` would build a correct request,
# pass every behavioural assertion above, and publish the refresh token in
# jq's argv, where `ps` shows it to every process on the machine. Caught by
# CodeAnt during #1716, after it had already shipped past the runtime checks.
#
# This is a SOURCE assertion because that is the only level at which it is
# observable: argv is gone by the time any output exists.
# The pattern covers `--arg` AND `--argjson`, braced and unbraced, quoted and
# unquoted. A detector that only knew `"$VAR"` would wave through `$VAR` and
# `"${VAR}"` — the same leak, spelled differently, which is exactly how a
# guard stops guarding.
ARGV_PAT='--arg(json)?[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]+"?\$\{?(CLAUDE_TOKEN|CLAUDE_REFRESH_TOKEN|CLAUDE_CRED_PRIOR_ACCESS|CURSOR_TOKEN)\}?"?'
ARGV_LEAKS="$(grep -nE -- "$ARGV_PAT" "$SCRIPT" || true)"
check_eq "$ARGV_LEAKS" "" \
  "no credential global is passed to jq with --arg/--argjson, which would put it in argv"

# Controls: the detector fires on EVERY spelling it claims to cover. A control
# that only exercised one form would leave the other three unasserted.
argv_probe() { printf '%s\n' "$1" | grep -cE -- "$ARGV_PAT" || true; }
check_eq "$(argv_probe 'jq -n --arg rt "$CLAUDE_REFRESH_TOKEN" .')" "1" \
  'control(+): the scan detects --arg with "$VAR"'
check_eq "$(argv_probe 'jq -n --arg rt $CLAUDE_REFRESH_TOKEN .')" "1" \
  'control(+): and unquoted $VAR'
check_eq "$(argv_probe 'jq -n --arg at "${CLAUDE_TOKEN}" .')" "1" \
  'control(+): and braced "${VAR}"'
check_eq "$(argv_probe 'jq -n --argjson at "$CLAUDE_TOKEN" .')" "1" \
  'control(+): and --argjson'
# Control(-): it must not fire on a NON-credential variable, or it would be
# satisfied by any jq call at all and prove nothing about secrets.
check_eq "$(argv_probe 'jq -n --arg ea "$CLAUDE_EXPIRES_AT_MS" .')" "0" \
  "control(-): and does not fire on a non-credential variable"

# --- 12r-i. a credential with a refresh token but NO access token ------------
#
# The shape a partial write leaves behind: `refreshToken` present,
# `accessToken` gone. `claude_token_for` has already loaded the refresh
# material into its globals by the time it discovers there is no access token,
# and this path spends it on NOTHING — no token call, no usage call — so the
# caller emits needs-login and returns. Without the clear, the refresh token
# would sit in those globals until the next Claude account called the function
# or the shell exited. Reported by CodeRabbit on #1721.

seed_renewal_case "$(( (NOW + 3600) * 1000 ))"
# Drop ONLY the access token, on the JSON column of the fake keychain row, so
# the refresh token and every other field survive exactly as a real partial
# write would leave them.
awk -F'\t' -v OFS='\t' '{ print $1, $2, $3 }' "$STUB_KEYCHAIN_DB" > "$TMP/pre.db"
: > "$TMP/noaccess.db"
while IFS=$'\t' read -r svc acct doc; do
  printf '%s\t%s\t%s\n' "$svc" "$acct" \
    "$(printf '%s' "$doc" | jq -c 'del(.claudeAiOauth.accessToken)')" >> "$TMP/noaccess.db"
done < "$TMP/pre.db"
mv -f "$TMP/noaccess.db" "$STUB_KEYCHAIN_DB"

check_eq "$(keychain_doc "$SVC_R" | jq -r '.claudeAiOauth | has("accessToken")')" "false" \
  "control(+): the fixture item really has no access token"
check_eq "$(keychain_doc "$SVC_R" | jq -r '.claudeAiOauth.refreshToken')" "$CLAUDE_REFRESH_SECRET" \
  "control(+): and it really does still carry the refresh token that must not linger"

run --json
check_eq "$(rows_for claude-one@example.com)" "needs-login" \
  "a credential with no access token is needs-login"
check_contains "$(field_of claude-one@example.com "7-day" detail)" "no OAuth access token" \
  "and the reason survives the clear rather than being blanked with the secrets"
check_contains "$(field_of claude-one@example.com "7-day" detail)" \
  "/quotas-setup relogin claude-one@example.com claude" \
  "and it still carries the relogin command"
check_eq "$(grep -c 'oauth/token' "$STUB_CURL_LOG" || true)" "0" \
  "control(-): nothing was spent on the token endpoint, so nothing consumed the refresh token"
COMBINED="$OUT
$ERR"
check_not_contains "$COMBINED" "$CLAUDE_REFRESH_SECRET" \
  "and the refresh token never reaches stdout or stderr on this path"

# The clear itself is in-process state, so the only level at which it is
# observable is the source. Asserted on the IDENTIFIER, not on any prose: a
# refactor that drops the call is what this catches.
TOKEN_FOR_BODY="$(awk '/^claude_token_for\(\) \{/{f=1} f{print} f && /^\}$/{exit}' "$SCRIPT")"
# Anchored to the CALL shape — a bare identifier on its own line. A plain
# substring match is satisfied by the comment above the call, so a refactor
# that deleted the call and left the comment would still pass.
FORGET_CALL='^[[:space:]]*claude_forget_credentials[[:space:]]*$'
check_eq "$(printf '%s' "$TOKEN_FOR_BODY" | grep -cE -- "$FORGET_CALL" || true)" "1" \
  "the credential read clears its globals on the failure path that loaded them"
check_eq "$(printf '%s\n' '  # calls claude_forget_credentials somewhere' | grep -cE -- "$FORGET_CALL" || true)" "0" \
  "control(-): and a mere mention in a comment does not satisfy that check"
check_eq "$(printf '%s' "$TOKEN_FOR_BODY" | grep -c 'credential store holds no OAuth access token' || true)" "1" \
  "control(+): and the extracted body really is the function that owns that path"

# --- 13. the cursor IDE-token reader (#1703) ---------------------------------
#
# The reader borrows the token the Cursor IDE holds, derives the dashboard
# cookie in memory, and calls three endpoints. Everything below runs against a
# fixture SQLite state store and the fake curl; the real IDE store is never
# touched and no browser exists to launch.

# A pool field, addressed by pool rather than by window: a cursor account
# contributes TWO rows sharing one window, so field_of alone cannot tell
# `cursor-models` from `other-models` and would answer with whichever came
# first — a test that passes while reading the wrong pool.
cursor_field() { # <label> <pool> <field>
  printf '%s' "$OUT" | jq -r --arg l "$1" --arg p "$2" --arg f "$3" \
    '.[] | select(.label == $l and .pool == $p) | .[$f] | if . == null then "null" else tostring end'
}

CUR="$PROFILES/cursor-one@example.com/cursor"
seed_cursor_account() { # — the registry row; no profile directory is created
  write_config "$(account_json cursor cursor-one@example.com "$CUR")"
}

# --- 13a. a signed-in IDE renders both pool rows -----------------------------

reset_state
seed_cursor_account
run --json
check_eq "$RC" "0" "a cursor account reads cleanly"
check_eq "$(cursor_field cursor-one@example.com cursor-models status)" "ok" \
  "the cursor-models pool reads ok"
check_eq "$(cursor_field cursor-one@example.com other-models status)" "ok" \
  "the other-models pool reads ok"
# 53.034333… rounds to one decimal with a bare .0 dropped, exactly as the
# retired helper rendered it — the display contract, unchanged by the transport.
check_eq "$(cursor_field cursor-one@example.com cursor-models used_pct)" "53" \
  "autoPercentUsed drives the cursor-models figure, rounded once"
check_eq "$(cursor_field cursor-one@example.com other-models used_pct)" "100" \
  "apiPercentUsed drives the other-models figure"
check_eq "$(cursor_field cursor-one@example.com cursor-models remaining_pct)" "47" \
  "remaining_pct comes off the same rounded number"
# Cents to dollars, on every dollar field.
check_eq "$(cursor_field cursor-one@example.com cursor-models plan_used_usd)" "2092.43" \
  "totalSpend is read as cents"
check_eq "$(cursor_field cursor-one@example.com cursor-models plan_included_usd)" "400" \
  "the plan limit is read as cents"
check_eq "$(cursor_field cursor-one@example.com other-models spend_limit_used_usd)" "1007.5" \
  "the on-demand block is read as cents, on both rows"
check_eq "$(cursor_field cursor-one@example.com other-models spend_limit_usd)" "1000" \
  "as is its limit"
# Milliseconds to epoch seconds, from get-monthly-billing-cycle.
check_eq "$(cursor_field cursor-one@example.com cursor-models resets_at_epoch)" "1790611774" \
  "the billing-cycle end is read as milliseconds and becomes the reset"
check_eq "$(cursor_field cursor-one@example.com cursor-models window_start_epoch)" "1787933374" \
  "and the cycle start becomes the window start"
check_eq "$(cursor_field cursor-one@example.com cursor-models plan)" "Ultra" \
  "get-plan-info supplies the plan name"
check_eq "$(cursor_field cursor-one@example.com cursor-models reported_email)" "$CURSOR_FIXTURE_EMAIL" \
  "the row is labelled with the IDE's cached email"
check_eq "$(cursor_field cursor-one@example.com cursor-models source)" "ide-token" \
  "and names the path it came from"

# The cookie's user id keeps the `google-oauth2|` prefix. Stripping to the
# segment after the final `|` is the plausible-looking mistake that answers 401
# against the real dashboard, so it is asserted rather than assumed.
check_eq "$(head -n 1 "$STUB_CURSOR_UID_LOG")" "$CURSOR_FIXTURE_SUB" \
  "the cookie carries the sub claim with only a leading auth0| removed"
check_eq "$(sort -u "$STUB_CURSOR_UID_LOG" | wc -l | tr -d ' ')" "1" \
  "and every one of the three calls carried the same user id"
check_eq "$(grep -c 'cursor.com/api/dashboard' "$STUB_CURL_LOG" | tr -d ' ')" "3" \
  "all three dashboard endpoints are called"

# --- 13b. the leak assertion (the ticket's own check) ------------------------
#
# `grep -iE 'WorkosCursorSessionToken=|eyJ'` over everything this run wrote
# must find nothing. The fixture token really is a JWT, so `eyJ` is a live
# tripwire here and not a formality.
check_not_contains "$OUT" "WorkosCursorSessionToken" "no cookie reaches stdout"
check_not_contains "$OUT" "eyJ" "no token reaches stdout"
check_not_contains "$ERR" "WorkosCursorSessionToken" "no cookie reaches stderr"
check_not_contains "$ERR" "eyJ" "no token reaches stderr"
check_not_contains "$(cat "$STUB_CURL_LOG")" "eyJ" "no token reaches the curl argv log"
LEAK_HIT="$(grep -icE 'WorkosCursorSessionToken=|eyJ' "$CASE_HOME/.claude/ai-quotas-history.jsonl" 2>/dev/null | tr -d ' ' || true)"
check_eq "${LEAK_HIT:-0}" "0" "no token or cookie reaches the history file"

# --- 13c. a rejected token says to sign in, in the IDE -----------------------

reset_state
seed_cursor_account
echo "unauth" > "$STUB_CURSOR_MODE"
run --json
check_eq "$RC" "0" "a rejected cursor token does not fail the run"
check_eq "$(rows_for cursor-one@example.com)" "needs-login" "HTTP 401 reads needs-login"
check_contains "$(field_of cursor-one@example.com "billing-cycle" detail)" "open the Cursor IDE and sign in" \
  "and the note says to sign in IN THE IDE, not to run a command"
check_not_contains "$(field_of cursor-one@example.com "billing-cycle" detail)" "/quotas-setup relogin" \
  "the relogin command is NOT offered — it cannot create this credential"
check_eq "$(field_of cursor-one@example.com "billing-cycle" used_pct)" "null" \
  "and no figure is invented"
# The two enrichment calls are SKIPPED once the usage call has decided the row
# (CodeRabbit). Three 401s per account per read is latency spent on a row that
# will not render, against a provider that rate-limits.
check_eq "$(grep -c 'cursor.com/api/dashboard' "$STUB_CURL_LOG" | tr -d ' ')" "1" \
  "and the enrichment endpoints are not called after a rejected token"

# --- 13d. any other non-200 is unreachable, with the status ------------------

reset_state
seed_cursor_account
echo "server" > "$STUB_CURSOR_MODE"
run --json
check_eq "$(rows_for cursor-one@example.com)" "unreachable" "HTTP 500 reads unreachable"
check_contains "$(field_of cursor-one@example.com "billing-cycle" detail)" "500" \
  "and the note carries the status code"
check_eq "$(grep -c 'cursor.com/api/dashboard' "$STUB_CURL_LOG" | tr -d ' ')" "1" \
  "and the enrichment endpoints are not called after a failed usage read"

# --- 13e. a signed-out IDE ---------------------------------------------------

reset_state
seed_cursor_account
CURSOR_DB_UNDER_TEST="$CURSOR_DB_SIGNED_OUT"
run --json
CURSOR_DB_UNDER_TEST=""
check_eq "$(rows_for cursor-one@example.com)" "needs-login" \
  "a state store with no access token reads needs-login"
check_contains "$(field_of cursor-one@example.com "billing-cycle" detail)" "not signed in" \
  "and says the IDE is not signed in"
check_eq "$(grep -c 'cursor.com' "$STUB_CURL_LOG" | tr -d ' ')" "0" \
  "no dashboard call is made without a token"

# --- 13f. no state store at all ----------------------------------------------

reset_state
seed_cursor_account
CURSOR_DB_UNDER_TEST="$CURSOR_DB_MISSING"
run --json
CURSOR_DB_UNDER_TEST=""
check_eq "$(rows_for cursor-one@example.com)" "needs-login" \
  "a missing state store reads needs-login"
check_contains "$(field_of cursor-one@example.com "billing-cycle" detail)" "open the Cursor IDE and sign in" \
  "with the same instruction"

# --- 13f2. no sqlite3 at all is unreachable, not needs-login -----------------
#
# Without sqlite3 this reader cannot see whether the IDE is signed in. Saying
# `needs-login` there would tell the user to sign in again over a missing tool,
# which is the one instruction that cannot help (CodeRabbit).

reset_state
seed_cursor_account
SQLITE3_BIN_UNDER_TEST="$TMP/no-such-sqlite3"
run --json
SQLITE3_BIN_UNDER_TEST=""
check_eq "$RC" "0" "a missing sqlite3 does not fail the run"
check_eq "$(rows_for cursor-one@example.com)" "unreachable" \
  "a missing sqlite3 reads unreachable, not needs-login"
check_contains "$(field_of cursor-one@example.com "billing-cycle" detail)" "sqlite3" \
  "and the note names the tool that is missing"
check_eq "$(grep -c 'cursor.com' "$STUB_CURL_LOG" | tr -d ' ')" "0" \
  "control(-): no request was made without a way to read the token"

# --- 13f3. the default store path follows PLATFORM ---------------------------
#
# The path was hardcoded to macOS, so a signed-in Linux user read `needs-login`
# — telling them to sign in again over a path this reader was looking for in
# the wrong place (CodeAnt). `run` always sets AI_QUOTAS_CURSOR_STATE_DB, which
# is precisely what hid it, so this case invokes the reader with that seam
# ABSENT and reads the path back out of the row's own detail note.

run_no_db_seam() { # <platform> <args…> — sets OUT/RC, no AI_QUOTAS_CURSOR_STATE_DB
  local plat="$1"; shift
  OUT="$(HOME="$CASE_HOME" \
        CLAUDE_QUOTAS_STATE_DIR="$CASE_HOME/.claude/quotas" \
        AI_QUOTAS_CONFIG="$CONFIG" \
        AI_QUOTAS_PLATFORM="$plat" \
        AI_QUOTAS_NOW="$NOW" \
        AI_QUOTAS_CURL_BIN="$BIN/curl" \
        AI_QUOTAS_SECURITY_BIN="$BIN/security" \
        AI_QUOTAS_SQLITE3_BIN="$SQLITE3_REAL" \
        "$SCRIPT" "$@" 2>/dev/null)"
  RC=$?
}

reset_state
seed_cursor_account
run_no_db_seam Linux --json
check_contains "$OUT" "/.config/Cursor/User/globalStorage/state.vscdb" \
  "a Linux platform looks for the documented Linux store path"
check_not_contains "$OUT" "Library/Application Support/Cursor" \
  "and not the macOS one"
reset_state
seed_cursor_account
run_no_db_seam Darwin --json
check_contains "$OUT" "Library/Application Support/Cursor/User/globalStorage/state.vscdb" \
  "control(+): Darwin still looks for the macOS store path"

# --- 13g. a changed payload shape is unreadable, never 0 % -------------------

reset_state
seed_cursor_account
echo "shape" > "$STUB_CURSOR_MODE"
run --json
check_eq "$(rows_for cursor-one@example.com)" "unreadable" \
  "HTTP 200 carrying no pool percentages reads unreadable"
check_eq "$(field_of cursor-one@example.com "billing-cycle" used_pct)" "null" \
  "and reports no figure rather than 0 %"
check_contains "$(field_of cursor-one@example.com "billing-cycle" detail)" "somethingElse" \
  "the note names the keys it actually saw"

# --- 13h. an enrichment failure costs a label, not the row -------------------
#
# Only get-current-period-usage decides the row. A row that went unreachable
# because a plan-NAME lookup 500'd would report a blackout it does not have.

reset_state
seed_cursor_account
echo "plan500" > "$STUB_CURSOR_MODE"
run --json
check_eq "$(cursor_field cursor-one@example.com cursor-models status)" "ok" \
  "a 500 from get-plan-info still renders the row"
check_eq "$(cursor_field cursor-one@example.com cursor-models used_pct)" "53" \
  "with its figures intact"
check_eq "$(cursor_field cursor-one@example.com cursor-models plan)" "null" \
  "and only the plan name missing"

# --- 13h2. a hostile sub claim never reaches the curl config -----------------
#
# The cookie is handed to curl through a line-oriented, quoted config on stdin.
# A `sub` carrying a newline does not merely corrupt the header — it ends the
# line, and what follows is read by curl as further OPTIONS. The state store is
# a local file this script does not own, so its shape is checked, not assumed
# (CodeRabbit).

reset_state
seed_cursor_account
CURSOR_DB_HOSTILE="$TMP/cursor-hostile.vscdb"
# `"` closes the quoted value and the newline starts a fresh config directive —
# the exact two characters the guard exists for.
HOSTILE_SUB='evil"
output = /dev/null'
build_cursor_db "$CURSOR_DB_HOSTILE" \
  "$(b64url '{"alg":"HS256","typ":"JWT"}').$(b64url "$(jq -nc --arg s "$HOSTILE_SUB" '{sub: $s}')").SIG" \
  || bad "could not build the hostile cursor fixture"
CURSOR_DB_UNDER_TEST="$CURSOR_DB_HOSTILE"
run --json
CURSOR_DB_UNDER_TEST=""
check_eq "$(rows_for cursor-one@example.com)" "unreadable" \
  "a sub claim carrying a quote and a newline is refused, not sent"
check_contains "$(field_of cursor-one@example.com "billing-cycle" detail)" "will not put in a request header" \
  "and the note says why"
check_eq "$(grep -c 'cursor.com' "$STUB_CURL_LOG" | tr -d ' ')" "0" \
  "control(-): no request was made at all"

# --- 13h3. a cached email carrying control characters is dropped -------------
#
# `reported_email` goes straight into a terminal table, where a tab splits the
# columns, a newline forges a row, and an escape sequence is executed by the
# terminal rather than shown. It comes from the same local file the token does,
# so it gets the invariant ROW_NICKNAME already documents (CodeRabbit).

reset_state
seed_cursor_account
CURSOR_DB_CTRL="$TMP/cursor-ctrl-email.vscdb"
rm -f "$CURSOR_DB_CTRL"
"$SQLITE3_REAL" "$CURSOR_DB_CTRL" "PRAGMA journal_mode=WAL;" >/dev/null
"$SQLITE3_REAL" "$CURSOR_DB_CTRL" "create table ItemTable (key TEXT PRIMARY KEY, value BLOB);"
"$SQLITE3_REAL" "$CURSOR_DB_CTRL" \
  "insert into ItemTable (key, value) values ('cursorAuth/accessToken', '${CURSOR_FIXTURE_TOKEN}');"
# A tab and a newline, inserted as real control characters via SQLite's own
# char() so the fixture cannot be softened by shell quoting on the way in.
"$SQLITE3_REAL" "$CURSOR_DB_CTRL" \
  "insert into ItemTable (key, value) values ('cursorAuth/cachedEmail', 'ev' || char(9) || 'il' || char(10) || '@example.com');"
CURSOR_DB_UNDER_TEST="$CURSOR_DB_CTRL"
run --json
CURSOR_DB_UNDER_TEST=""
check_eq "$(cursor_field cursor-one@example.com cursor-models status)" "ok" \
  "a control-character email does not take the row down"
check_eq "$(cursor_field cursor-one@example.com cursor-models reported_email)" "cursor-one@example.com" \
  "and the row falls back to the label instead of rendering it"

# --- 13i. a broken cursor account degrades alone -----------------------------
#
# The property this file is about: per-row isolation.

reset_state
X1="$(seed_codex_profile codex-one@example.com "$(codex_snapshot_primary_weekly)")"
write_config \
  "$(account_json cursor cursor-one@example.com "$CUR")" \
  "$(account_json codex codex-one@example.com "$X1")"
echo "down" > "$STUB_CURSOR_MODE"
run --json
check_eq "$RC" "0" "a cursor row does not fail the run"
check_eq "$(rows_for cursor-one@example.com)" "unreachable" \
  "a curl failure reads unreachable"
# The email was read from the LOCAL store before any request went out, so a
# network failure has not invalidated it (CodeAnt). Discriminating on purpose:
# the fixture email differs from the label, and an emit_row that passed "" here
# would fall back to the label and this assertion would read it.
check_eq "$(field_of cursor-one@example.com "billing-cycle" reported_email)" "$CURSOR_FIXTURE_EMAIL" \
  "and the unreachable row still names the account from the local store"
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
check_eq "$(printf '%s' "$COMBINED" | grep -cE 'Bearer|sk-ant|eyJ|refresh_token=' || true)" "0" \
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
check_eq "$(printf '%s' "$COMBINED" | grep -cE 'Bearer|sk-ant|eyJ|refresh_token=' || true)" "0" \
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
# The column is found by NAME in the header rather than counted to. Reading a
# fixed field number would keep passing against whatever ends up fourth after
# the next column change, and reading from $OUT rather than the table would let
# a DEGRADED line printed above it supply the value being asserted on.
check_eq "$(table_only "$OUT" | awk 'NR == 1 { for (i = 1; i <= NF; i++) if ($i == "START") c = i; next }
                                     c { print $c }' | sort -u | tr -d '\n')" "-" \
  "control(-): and every START cell is a dash rather than a figure nobody computed"
FORECAST_BIN_OVERRIDE=""
check_contains "$OUT" "OVERAGE" "the rest of the table still renders"
check_contains "$OUT" "40%" "including every figure that was read"

# A projection may only FILL BLANKS. The dangerous shape here is a helper that
# returns the RIGHT NUMBER OF ROWS while dropping fields off them: a row-count
# check passes it, and the report prints missing the very fields a consumer
# reads it for, with exit 0. AI_QUOTAS_FORECAST_BIN points this at anything on
# disk, so the reader has to survive it rather than trust the repo copy.
#
# The pass-through stub is the CONTROL, and it goes first. Without it a
# rejection below could not be attributed to the dropped field — a stub
# mechanism that simply never produced an accepted document would fail the
# same way and the assertion would pass for the wrong reason.
cat > "$TMP/passthrough-forecast.sh" <<'PASSTHROUGH_FORECAST'
#!/usr/bin/env bash
jq '.rows |= map(. + {pct_per_day: 7.5, days_left: 8.0, usage_start_is_floor: false})'
PASSTHROUGH_FORECAST
chmod +x "$TMP/passthrough-forecast.sh"
overage_case 40 50
FORECAST_BIN_OVERRIDE="$TMP/passthrough-forecast.sh"
run --json
check_eq "$(field_of claude-one@example.com "7-day" pct_per_day)" "7.5" \
  "control(+): a helper that only fills blanks has its projection applied"
run
check_not_contains "$ERR" "DEGRADED" \
  "control(+): and nothing is reported as degraded"

# Same length, every projection field filled — but `provider` is gone off each
# row, and the top-level `schema_version` with it.
cat > "$TMP/stripping-forecast.sh" <<'STRIPPING_FORECAST'
#!/usr/bin/env bash
jq 'del(.schema_version)
    | .rows |= map(del(.provider) + {pct_per_day: 7.5, days_left: 8.0})'
STRIPPING_FORECAST
chmod +x "$TMP/stripping-forecast.sh"
FORECAST_BIN_OVERRIDE="$TMP/stripping-forecast.sh"
run
check_eq "$RC" "0" "a helper that strips fields off the report does not fail it"
check_contains "$ERR" "DEGRADED" "the stripped report is stated as a degradation"
check_not_contains "$ERR" "failed (exit" \
  "and is not reported as an exit-code failure, because the exit was zero"
run --json
check_eq "$(printf '%s' "$DOC" | jq -r '.schema_version')" "1.0" \
  "schema_version survives, because the stripped document was discarded whole"
check_eq "$(field_of claude-one@example.com "7-day" provider)" "claude" \
  "and so does every row's provider"
check_eq "$(printf '%s' "$DOC" | jq -r \
  '.rows[] | select(.label == "claude-one@example.com") | .pct_per_day | tostring')" "null" \
  "with no figure from a document that could not be trusted to carry the rest"

# Overwriting a MEASURED figure is the same failure wearing different clothes:
# the document is complete, so a field-presence check passes it, and the table
# prints a usage percentage this run never read.
# DELETING a blank is not filling it. A helper that drops `pct_per_day` off
# every row rather than computing one returns a document whose every surviving
# field matches — and a check that excused null-valued keys from having to come
# back would take it, leaving `--json` consumers a row where the field is
# ABSENT rather than null. One shape either way is the whole reason these
# fields are declared null on rows nothing was projected for.
cat > "$TMP/deleting-forecast.sh" <<'DELETING_FORECAST'
#!/usr/bin/env bash
jq '.rows |= map(del(.pct_per_day))'
DELETING_FORECAST
chmod +x "$TMP/deleting-forecast.sh"
FORECAST_BIN_OVERRIDE="$TMP/deleting-forecast.sh"
run
check_eq "$RC" "0" "a helper that deletes a blank instead of filling it does not fail the report"
check_contains "$ERR" "DEGRADED" "the deleted field is stated as a degradation"
run --json
check_eq "$(printf '%s' "$DOC" | jq -r \
  '.rows | map(has("pct_per_day")) | all | tostring')" "true" \
  "and every row still HAS pct_per_day, because the document was discarded whole"
check_eq "$(field_of claude-one@example.com "7-day" pct_per_day)" "null" \
  "carrying it as null — the shape a consumer gets when nothing was projected"

# Filling a blank the projection does NOT own. `overage` is null on every row
# whenever the cheapest-next helper degraded, and a price appearing in it did
# not come from any provider — the report would state a dollar figure nobody
# read, in the column owners use to choose what to spend next, with exit 0.
# Only the seven fields the projection declares may be written.
cat > "$TMP/foreign-field-forecast.sh" <<'FOREIGN_FIELD_FORECAST'
#!/usr/bin/env bash
jq '.rows |= map(.overage = "$42.00" | . + {pct_per_day: 7.5})'
FOREIGN_FIELD_FORECAST
chmod +x "$TMP/foreign-field-forecast.sh"
FORECAST_BIN_OVERRIDE="$TMP/foreign-field-forecast.sh"
run
check_eq "$RC" "0" "a helper that fills a field it does not own does not fail the report"
check_contains "$ERR" "DEGRADED" "filling a blank outside the projection is a degradation"
check_not_contains "$OUT" "42.00" "and the fabricated figure never reaches the table"

# A field the report never declared. Every value the projection writes has a
# null already waiting for it on the row, so a key that was not sent has no
# legitimate way back — and a --json consumer reading a field this reader never
# promised is reading whatever the helper felt like saying.
cat > "$TMP/extra-field-forecast.sh" <<'EXTRA_FIELD_FORECAST'
#!/usr/bin/env bash
jq '.rows |= map(. + {pct_per_day: 7.5, projected_spend_usd: 99})'
EXTRA_FIELD_FORECAST
chmod +x "$TMP/extra-field-forecast.sh"
FORECAST_BIN_OVERRIDE="$TMP/extra-field-forecast.sh"
run --json
check_eq "$(printf '%s' "$DOC" | jq -r \
  '.rows | map(has("projected_spend_usd")) | any | tostring')" "false" \
  "a field the report never declared does not reach --json"
check_eq "$(field_of claude-one@example.com "7-day" pct_per_day)" "null" \
  "and the projection that arrived with it is discarded whole"

# Rows that are not objects at all. The comparison the check runs against each
# row is only defined over objects, so the arm that matters is what happens
# when it is not: the run has to end in the SAME discard-and-degrade as every
# other malformed answer, rather than in an error escaping to the terminal or
# a report built on rows nobody can read.
cat > "$TMP/scalar-rows-forecast.sh" <<'SCALAR_ROWS_FORECAST'
#!/usr/bin/env bash
jq '.rows |= map("gone")'
SCALAR_ROWS_FORECAST
chmod +x "$TMP/scalar-rows-forecast.sh"
FORECAST_BIN_OVERRIDE="$TMP/scalar-rows-forecast.sh"
run
check_eq "$RC" "0" "rows that are not objects do not fail the report"
check_contains "$ERR" "DEGRADED" "they degrade like any other answer that cannot be trusted"
check_contains "$OUT" "claude-one@example.com" "and every account still reports from the rows this run built"

cat > "$TMP/overwriting-forecast.sh" <<'OVERWRITING_FORECAST'
#!/usr/bin/env bash
jq '.rows |= map(.used_pct = 99 | . + {pct_per_day: 7.5})'
OVERWRITING_FORECAST
chmod +x "$TMP/overwriting-forecast.sh"
FORECAST_BIN_OVERRIDE="$TMP/overwriting-forecast.sh"
run
FORECAST_BIN_OVERRIDE=""

# A blank may be filled only with the DOCUMENTED type. A helper that answers
# with a structured value in a scalar slot — or a note that is not the one
# the contract names — is rejected whole: the projection is discarded and the
# table degrades, because the TSV renderer would otherwise print JSON into a
# column and a --json consumer would meet an array where a number was promised.
cat > "$TMP/badtype-forecast.sh" <<'BADTYPE_FORECAST'
#!/usr/bin/env bash
jq '.rows |= map(. + {pct_per_day: [], days_left: {}, usage_start_display: 7, days_left_note: "later"})'
BADTYPE_FORECAST
chmod +x "$TMP/badtype-forecast.sh"
overage_case 40 50
FORECAST_BIN_OVERRIDE="$TMP/badtype-forecast.sh"
run
check_eq "$RC" "0" "a projection with the wrong field types does not fail the report"
check_contains "$ERR" "DEGRADED" "it is rejected as DEGRADED"
check_eq "$(table_only "$OUT" | awk 'NR == 1 { for (i = 1; i <= NF; i++) if ($i == "%/DAY") c = i; next }
                                     c { print $c }' | sort -u | tr -d '\n')" "-" \
  "and no structured value reaches the %/DAY column"
check_contains "$OUT" "40%" "while every figure that was read still prints"
FORECAST_BIN_OVERRIDE=""

# `usage_start_day` is ONE-based. A stub that fills every field with a valid
# value except a day of 0 discriminates the key-specific bound from the
# generic non-negative check: pre-fix, 0 passed as a number >= 0.
cat > "$TMP/dayzero-forecast.sh" <<'DAYZERO_FORECAST'
#!/usr/bin/env bash
jq '.rows |= map(. + {usage_start_day: 0, usage_start_display: "d0", pct_per_day: 7.5, days_left: 8.0, usage_start_is_floor: false})'
DAYZERO_FORECAST
chmod +x "$TMP/dayzero-forecast.sh"
overage_case 40 50
FORECAST_BIN_OVERRIDE="$TMP/dayzero-forecast.sh"
run
check_eq "$RC" "0" "a projection naming day 0 does not fail the report"
check_contains "$ERR" "DEGRADED" "it is rejected as DEGRADED, because day 0 is not a day"
check_eq "$(table_only "$OUT" | awk 'NR == 1 { for (i = 1; i <= NF; i++) if ($i == "START") c = i; next }
                                     c { print $c }' | sort -u | tr -d '\n')" "-" \
  "and the START column carries no d0"
FORECAST_BIN_OVERRIDE=""
check_eq "$RC" "0" "a helper that rewrites a figure it was given does not fail the report"
check_contains "$ERR" "DEGRADED" "that rewrite is a degradation too"
check_contains "$OUT" "40%" "and the figure this run actually read is what prints"
check_not_contains "$OUT" "99%" "never the one the helper substituted"

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
