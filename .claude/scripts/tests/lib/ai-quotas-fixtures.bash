#!/usr/bin/env bash
# Source-only quota fixtures and shared helpers for independent case groups.
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

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
SCRIPT="$ROOT/.claude/scripts/ai-quotas.sh"

# These are suite-owned seams; inherited values must never launch a provider.
unset AI_QUOTAS_BROWSER_CLI AI_QUOTAS_CLAUDE_VERSION


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
require_fixture_binaries() {
  local fake
  for fake in curl security codex claude; do
    if [[ ! -f "$BIN/$fake" || ! -x "$BIN/$fake" ]]; then
      echo "FAIL — missing required fake: $fake ($BIN/$fake)" >&2
      return 1
    fi
  done
}


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
      invalid_json) printf 'not-json' > "$out"; printf '200' ;;
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
      timeout)   exit 28 ;;
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
      ratelimit) printf '{}' > "$out"; printf '429' ;;
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
require_fixture_binaries || exit 1
export PATH="$BIN:$PATH"

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
run() { # <args…> — reader failures are assertions; missing harness fakes stop immediately
  require_fixture_binaries || exit 1
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
        AI_QUOTAS_NOTIFY_BIN="${NOTIFY_BIN_UNDER_TEST:-/usr/bin/true}" \
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
  unset BROWSER_STUB_RESET BROWSER_STUB_STATUS BROWSER_STUB_STAGE BROWSER_STUB_FAIL
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


# Shared case helpers retain their original bodies.
SVC_R="Claude Code-credentials-RENEW"
CUR="$PROFILES/cursor-one@example.com/cursor"
HISTORY="$CASE_HOME/.claude/ai-quotas-history.jsonl"
RC_BASE="$(codex_snapshot_primary_weekly)"
ARGV_PAT='--arg(json)?[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]+"?\$\{?(CLAUDE_TOKEN|CLAUDE_REFRESH_TOKEN|CLAUDE_CRED_PRIOR_ACCESS|CURSOR_TOKEN)\}?"?'

seed_renewal_case() { # <expires-at-ms|"">
  reset_state
  CR="$(seed_claude_profile claude-one@example.com "$SVC_R" "$1")"
  write_config "$(account_json claude claude-one@example.com "$CR" "$SVC_R")"
}

argv_probe() { printf '%s\n' "$1" | grep -cE -- "$ARGV_PAT" || true; }

cursor_field() { # <label> <pool> <field>
  printf '%s' "$OUT" | jq -r --arg l "$1" --arg p "$2" --arg f "$3" \
    '.[] | select(.label == $l and .pool == $p) | .[$f] | if . == null then "null" else tostring end'
}

seed_cursor_account() { # — the registry row; no profile directory is created
  write_config "$(account_json cursor cursor-one@example.com "$CUR")"
}

run_no_db_seam() { # <platform> <args…> — sets OUT/RC, no AI_QUOTAS_CURSOR_STATE_DB
  require_fixture_binaries || exit 1
  local plat="$1"; shift
  OUT="$(HOME="$CASE_HOME" \
        CLAUDE_QUOTAS_STATE_DIR="$CASE_HOME/.claude/quotas" \
        AI_QUOTAS_CONFIG="$CONFIG" \
        AI_QUOTAS_PLATFORM="$plat" \
        AI_QUOTAS_NOW="$NOW" \
        AI_QUOTAS_CURL_BIN="$BIN/curl" \
        AI_QUOTAS_SECURITY_BIN="$BIN/security" \
        AI_QUOTAS_CODEX_BIN="$BIN/codex" \
        AI_QUOTAS_CLAUDE_BIN="$BIN/claude" \
        AI_QUOTAS_NOTIFY_BIN="/usr/bin/true" \
        AI_QUOTAS_SQLITE3_BIN="$SQLITE3_REAL" \
        "$SCRIPT" "$@" 2>/dev/null)"
  RC=$?
}

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

history_lines() { cat "$HISTORY" 2>/dev/null || true; }

history_count() { history_lines | grep -c . || true; }


utc_iso() { # <epoch>
  date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || true
}

table_only() { # <output>
  printf '%s\n' "$1" | awk '/^ACCOUNT /{f=1} f && /^[[:space:]]*$/{exit} f {print}'
}

widest_line() { # <text>
  printf '%s\n' "$1" | awk '{ if (length($0) > m) m = length($0) } END { print m + 0 }'
}

rc_snapshot() { # <reset-credits-json>
  printf '%s' "$RC_BASE" | jq -c --argjson rc "$1" '. + {rateLimitResetCredits: $rc}'
}

