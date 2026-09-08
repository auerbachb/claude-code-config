#!/usr/bin/env bash
# ai-quotas-setup.test.sh — coverage for .claude/scripts/ai-quotas-setup.sh
# (issue #1666).
# catalog: tests — Tests `ai-quotas-setup.sh` — the add/remove/relogin/list registry contract, two same-provider accounts staying logged in independently, the macOS Keychain probe against a stub `security` that fails loudly if a credential VALUE is ever requested, the leak assertions (no token/password/cookie and no fixture secret in the config), and the fail-closed paths where a login runs but leaves no visible credential
#
# WHAT IS UNDER TEST
#
# The registry is the only thing increment 1 delivers, so the properties that
# matter are: an account is recorded only when a credential is actually
# visible, a second account of the same provider never disturbs the first,
# `list` classifies honestly, and NO credential value is ever read or stored.
#
# ALL LOGINS ARE STUBS. No real `claude`, `codex`, keychain, or account is
# touched: HOME, the config path, the profile root, the platform name, and
# every provider/`security` binary are redirected into a temp tree for every
# invocation. The stub `security` EXITS NON-ZERO if it is ever asked for a
# password value (`-w`), so "the probe never reads a secret" is asserted by
# construction rather than by reading the source.
#
# DISCRIMINATING FIXTURES. The stub credential file carries an `accessToken`
# field, so the "no token/password/cookie in the config" assertion is a real
# leak detector: a config that copied the credential in would fail it. A
# fixture without that shape would pass for the wrong reason.
#
# Run from anywhere: bash .claude/scripts/tests/ai-quotas-setup.test.sh

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="$ROOT/.claude/scripts/ai-quotas-setup.sh"

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

# --- stub binaries -----------------------------------------------------------

BIN="$TMP/bin"
mkdir -p "$BIN"

# A credential-SHAPED fixture: the accessToken field is what makes the
# leak assertions below discriminating.
FIXTURE_SECRET="FAKE-CRED-VALUE-0F1E2D"

cat > "$BIN/claude-file" <<EOF
#!/usr/bin/env bash
# Stub \`claude\`: records the invocation, then writes the file-store credential
# the real CLI writes on non-macOS platforms.
printf '%s\t%s\n' "\${CLAUDE_CONFIG_DIR:-<unset>}" "\$*" >> "\$STUB_CALL_LOG"
mkdir -p "\$CLAUDE_CONFIG_DIR"
printf '{"claudeAiOauth":{"accessToken":"%s"}}\n' "$FIXTURE_SECRET" > "\$CLAUDE_CONFIG_DIR/.credentials.json"
exit 0
EOF

cat > "$BIN/claude-fail" <<'EOF'
#!/usr/bin/env bash
printf '%s\t%s\n' "${CLAUDE_CONFIG_DIR:-<unset>}" "$*" >> "$STUB_CALL_LOG"
echo "stub: login aborted" >&2
exit 1
EOF

cat > "$BIN/claude-silent" <<'EOF'
#!/usr/bin/env bash
# Exits 0 but writes no credential — the "login window closed without
# finishing" shape.
printf '%s\t%s\n' "${CLAUDE_CONFIG_DIR:-<unset>}" "$*" >> "$STUB_CALL_LOG"
exit 0
EOF

cat > "$BIN/claude-keychain" <<'EOF'
#!/usr/bin/env bash
# Stub `claude` for the macOS path: leaves nothing in the profile directory
# and instead registers a new Keychain service name, exactly as the real CLI
# does when the credential goes to the login keychain.
printf '%s\t%s\n' "${CLAUDE_CONFIG_DIR:-<unset>}" "$*" >> "$STUB_CALL_LOG"
# The counter is monotonic and independent of the DB's contents. Deriving it
# from the DB's line count would restart numbering after the suite empties the
# DB, so a re-login would "create" the same service name it just lost — and
# the assertion that relogin records the NEW item would pass or fail for a
# reason that has nothing to do with the code under test.
n=$(( $(cat "$STUB_KEYCHAIN_SEQ" 2>/dev/null || echo 0) + 1 ))
printf '%s\n' "$n" > "$STUB_KEYCHAIN_SEQ"
printf 'Claude Code-credentials-%08d\n' "$n" >> "$STUB_KEYCHAIN_DB"
exit 0
EOF

cat > "$BIN/claude-keychain-double" <<'EOF'
#!/usr/bin/env bash
# Two Keychain items appear across one login — what a concurrent login by
# another account looks like from inside this run's before/after snapshots.
printf '%s\t%s\n' "${CLAUDE_CONFIG_DIR:-<unset>}" "$*" >> "$STUB_CALL_LOG"
n=$(( $(cat "$STUB_KEYCHAIN_SEQ" 2>/dev/null || echo 0) + 1 ))
printf 'Claude Code-credentials-%08d\n' "$n" >> "$STUB_KEYCHAIN_DB"
n=$(( n + 1 ))
printf 'Claude Code-credentials-%08d\n' "$n" >> "$STUB_KEYCHAIN_DB"
printf '%s\n' "$n" > "$STUB_KEYCHAIN_SEQ"
exit 0
EOF

cat > "$BIN/claude-keychain-stable" <<'EOF'
#!/usr/bin/env bash
# A login against a profile that ALREADY has a Keychain item rewrites that
# item rather than creating one, so the before/after snapshots are identical.
# This is what re-registering a label whose profile `remove` left on disk
# actually looks like.
printf '%s\t%s\n' "${CLAUDE_CONFIG_DIR:-<unset>}" "$*" >> "$STUB_CALL_LOG"
svc="Claude Code-credentials-STABLE01"
grep -Fxq "$svc" "$STUB_KEYCHAIN_DB" 2>/dev/null || printf '%s\n' "$svc" >> "$STUB_KEYCHAIN_DB"
exit 0
EOF

cat > "$BIN/claude-keychain-stable-plus-foreign" <<'EOF'
#!/usr/bin/env bash
# The account's OWN item is rewritten in place (so it contributes nothing to
# the before/after diff) while ONE unrelated item appears — a concurrent login
# by a different account. From inside this run's snapshots that is exactly one
# new service name, which is indistinguishable from an ordinary first login and
# so is NOT refused as ambiguous.
printf '%s\t%s\n' "${CLAUDE_CONFIG_DIR:-<unset>}" "$*" >> "$STUB_CALL_LOG"
svc="Claude Code-credentials-STABLE01"
grep -Fxq "$svc" "$STUB_KEYCHAIN_DB" 2>/dev/null || printf '%s\n' "$svc" >> "$STUB_KEYCHAIN_DB"
foreign="Claude Code-credentials-FOREIGN9"
grep -Fxq "$foreign" "$STUB_KEYCHAIN_DB" 2>/dev/null || printf '%s\n' "$foreign" >> "$STUB_KEYCHAIN_DB"
exit 0
EOF

cat > "$BIN/claude-keychain-rekey" <<'EOF'
#!/usr/bin/env bash
# The account's existing item is GONE and one new item takes its place — what
# re-keying an account actually looks like. The new item is this login's, so it
# must be adopted.
printf '%s\t%s\n' "${CLAUDE_CONFIG_DIR:-<unset>}" "$*" >> "$STUB_CALL_LOG"
grep -Fxv "Claude Code-credentials-STABLE01" "$STUB_KEYCHAIN_DB" > "$STUB_KEYCHAIN_DB.tmp" 2>/dev/null || :
mv "$STUB_KEYCHAIN_DB.tmp" "$STUB_KEYCHAIN_DB"
printf '%s\n' "Claude Code-credentials-REKEYED1" >> "$STUB_KEYCHAIN_DB"
exit 0
EOF

cat > "$BIN/codex-file" <<EOF
#!/usr/bin/env bash
printf '%s\t%s\n' "\${CODEX_HOME:-<unset>}" "\$*" >> "\$STUB_CALL_LOG"
mkdir -p "\$CODEX_HOME"
printf '{"tokens":{"access_token":"%s"}}\n' "$FIXTURE_SECRET" > "\$CODEX_HOME/auth.json"
exit 0
EOF

cat > "$BIN/codex-status-only" <<'EOF'
#!/usr/bin/env bash
# A logged-in CODEX_HOME with no auth.json: `login status` is the only witness.
# It also prints an account line, which the probe must discard rather than
# surface.
printf '%s\t%s\n' "${CODEX_HOME:-<unset>}" "$*" >> "$STUB_CALL_LOG"
if [[ "${1:-}" == "login" && "${2:-}" == "status" ]]; then
  echo "Logged in as someone@example.com"
  exit 0
fi
exit 0
EOF

cat > "$BIN/codex-nothing" <<'EOF'
#!/usr/bin/env bash
# Neither an auth.json nor a passing status — a genuinely logged-out profile.
printf '%s\t%s\n' "${CODEX_HOME:-<unset>}" "$*" >> "$STUB_CALL_LOG"
if [[ "${1:-}" == "login" && "${2:-}" == "status" ]]; then
  exit 1
fi
exit 0
EOF

# --- stubs: the cursor login (node + the Playwright helper) ------------------
# `add cursor` / `relogin cursor` resolve node through AI_QUOTAS_NODE_BIN and
# the helper through AI_QUOTAS_CURSOR_HELPER. Both are stubbed, so no browser
# is ever launched and CI needs neither node nor playwright.
#
# The helper file itself only has to EXIST — the script checks it is readable
# before invoking the login, and the fake node ignores its content.
FAKE_CURSOR_HELPER="$TMP/fake-ai-quotas-cursor.js"
printf '// stub — the fake node never reads this\n' > "$FAKE_CURSOR_HELPER"
export FAKE_CURSOR_HELPER

# A successful login: writes the cookie store a real Chromium persistent
# context would leave behind, then prints the helper's ok verdict.
cat > "$BIN/node-login-ok" <<'EOF'
#!/usr/bin/env bash
printf '%s\t%s\n' "node" "$*" >> "$STUB_CALL_LOG"
dir=""
while [[ $# -gt 0 ]]; do
  case "$1" in --profile-dir) dir="$2"; shift 2 ;; *) shift ;; esac
done
if [[ -n "$dir" ]]; then
  mkdir -p "$dir/Default/Network"
  printf 'SQLite format 3\0STUB-COOKIE-STORE\n' > "$dir/Default/Network/Cookies"
fi
printf '{"status":"ok","source":"network"}\n'
exit 0
EOF

# A login the user abandoned. Exits 0 with a NON-ok verdict — the shape that
# catches a caller reading the exit status instead of the verdict.
cat > "$BIN/node-login-abandoned" <<'EOF'
#!/usr/bin/env bash
printf '%s\t%s\n' "node" "$*" >> "$STUB_CALL_LOG"
printf '{"status":"needs-login","detail":"the login did not complete in time"}\n'
exit 0
EOF

cat > "$BIN/security" <<'EOF'
#!/usr/bin/env bash
# Stub macOS security(1) over a flat file of service names.
#
# Asking for a VALUE (-w) is a test failure, not a supported mode: the probe
# under test must never request a password. Recording it in a sentinel file
# lets the suite assert that no run ever did.
for arg in "$@"; do
  if [[ "$arg" == "-w" ]]; then
    echo "REQUESTED_VALUE $*" >> "$STUB_SECURITY_VALUE_REQUESTS"
    exit 99
  fi
done
case "${1:-}" in
  dump-keychain)
    while IFS= read -r svc; do
      [[ -n "$svc" ]] || continue
      printf '    "svce"<blob>="%s"\n' "$svc"
    done < "$STUB_KEYCHAIN_DB"
    exit 0
    ;;
  find-generic-password)
    want=""
    while [[ $# -gt 0 ]]; do
      if [[ "$1" == "-s" ]]; then want="${2:-}"; shift 2; continue; fi
      shift
    done
    [[ -n "$want" ]] || exit 1
    if grep -Fxq "$want" "$STUB_KEYCHAIN_DB" 2>/dev/null; then
      echo "keychain: stub"
      echo "    \"svce\"<blob>=\"$want\""
      exit 0
    fi
    exit 44
    ;;
esac
exit 1
EOF

chmod +x "$BIN"/*

# --- harness -----------------------------------------------------------------

export STUB_CALL_LOG="$TMP/calls.log"
export STUB_KEYCHAIN_DB="$TMP/keychain.db"
export STUB_KEYCHAIN_SEQ="$TMP/keychain.seq"
export STUB_SECURITY_VALUE_REQUESTS="$TMP/security-value-requests.log"
: > "$STUB_CALL_LOG"
: > "$STUB_KEYCHAIN_DB"
printf '0\n' > "$STUB_KEYCHAIN_SEQ"
: > "$STUB_SECURITY_VALUE_REQUESTS"

OUT=""
RC=0

new_case() { # <name>
  # Reset the per-case overrides here rather than relying on each block to
  # undo its own: a stub left set by an earlier case would silently drive a
  # later one, and the later case would pass or fail for a reason nowhere in
  # its own text.
  PLATFORM_UNDER_TEST="Linux"
  CLAUDE_BIN_UNDER_TEST=""
  CODEX_BIN_UNDER_TEST=""
  NODE_BIN_UNDER_TEST=""
  CASE_DIR="$TMP/case-$(printf '%s' "$1" | tr -c 'A-Za-z0-9' '-')"
  rm -rf "$CASE_DIR"
  mkdir -p "$CASE_DIR/home/.claude"
  CONFIG="$CASE_DIR/ai-quotas.json"
  PROFILES="$CASE_DIR/profiles"
  : > "$STUB_CALL_LOG"
  : > "$STUB_KEYCHAIN_DB"
}

run() { # <args...>  — never aborts the suite; sets OUT and RC
  OUT="$(HOME="$CASE_DIR/home" \
        AI_QUOTAS_CONFIG="$CONFIG" \
        AI_QUOTAS_PROFILE_ROOT="$PROFILES" \
        AI_QUOTAS_PLATFORM="${PLATFORM_UNDER_TEST:-Linux}" \
        AI_QUOTAS_SECURITY_BIN="$BIN/security" \
        AI_QUOTAS_CLAUDE_BIN="${CLAUDE_BIN_UNDER_TEST:-$BIN/claude-file}" \
        AI_QUOTAS_CODEX_BIN="${CODEX_BIN_UNDER_TEST:-$BIN/codex-file}" \
        AI_QUOTAS_NODE_BIN="${NODE_BIN_UNDER_TEST:-$BIN/node-login-ok}" \
        AI_QUOTAS_CURSOR_HELPER="$FAKE_CURSOR_HELPER" \
        "$SCRIPT" "$@" 2>&1)"
  RC=$?
}

account_count() {
  jq '.accounts | length' "$CONFIG" 2>/dev/null || echo "READ-ERROR"
}

status_of() { # <label> [<provider>]
  local label="$1" provider="${2:-}"
  # The provider binaries are passed here too, not just in `run`: a status
  # probe that consults the provider's CLI must reach the same stub the login
  # did, or every such account reads as needs-login for a harness reason.
  HOME="$CASE_DIR/home" AI_QUOTAS_CONFIG="$CONFIG" AI_QUOTAS_PROFILE_ROOT="$PROFILES" \
    AI_QUOTAS_PLATFORM="${PLATFORM_UNDER_TEST:-Linux}" \
    AI_QUOTAS_SECURITY_BIN="$BIN/security" \
    AI_QUOTAS_CLAUDE_BIN="${CLAUDE_BIN_UNDER_TEST:-$BIN/claude-file}" \
    AI_QUOTAS_CODEX_BIN="${CODEX_BIN_UNDER_TEST:-$BIN/codex-file}" \
    AI_QUOTAS_NODE_BIN="${NODE_BIN_UNDER_TEST:-$BIN/node-login-ok}" \
    AI_QUOTAS_CURSOR_HELPER="$FAKE_CURSOR_HELPER" \
    "$SCRIPT" list --json 2>/dev/null \
    | jq -r --arg l "$label" --arg p "$provider" \
        '.[] | select(.label == $l and ($p == "" or .provider == $p)) | .status'
}

detail_of() { # <label> [<provider>]
  local label="$1" provider="${2:-}"
  HOME="$CASE_DIR/home" AI_QUOTAS_CONFIG="$CONFIG" AI_QUOTAS_PROFILE_ROOT="$PROFILES" \
    AI_QUOTAS_PLATFORM="${PLATFORM_UNDER_TEST:-Linux}" \
    AI_QUOTAS_SECURITY_BIN="$BIN/security" \
    AI_QUOTAS_CLAUDE_BIN="${CLAUDE_BIN_UNDER_TEST:-$BIN/claude-file}" \
    AI_QUOTAS_CODEX_BIN="${CODEX_BIN_UNDER_TEST:-$BIN/codex-file}" \
    AI_QUOTAS_NODE_BIN="${NODE_BIN_UNDER_TEST:-$BIN/node-login-ok}" \
    AI_QUOTAS_CURSOR_HELPER="$FAKE_CURSOR_HELPER" \
    "$SCRIPT" list --json 2>/dev/null \
    | jq -r --arg l "$label" --arg p "$provider" \
        '.[] | select(.label == $l and ($p == "" or .provider == $p)) | .detail'
}

service_of() { # <label>
  jq -r --arg l "$1" \
    '.accounts[] | select(.label == $l) | .credential_ref.service // ""' \
    "$CONFIG" 2>/dev/null || echo "READ-ERROR"
}

PLATFORM_UNDER_TEST="Linux"
CLAUDE_BIN_UNDER_TEST=""
CODEX_BIN_UNDER_TEST=""

echo "== ai-quotas-setup.sh =="

# --- 1. --help contract ------------------------------------------------------

new_case "help"
HELP_ERR="$TMP/help.err"
# HOME is redirected here too: --help still writes the telemetry line, and a
# suite that appends to the real ~/.claude/script-usage.log is a suite with a
# side effect outside its temp tree.
HELP_OUT="$(HOME="$CASE_DIR/home" "$SCRIPT" --help 2>"$HELP_ERR")"
check_eq "$?" "0" "--help exits 0"
check_contains "$HELP_OUT" "ai-quotas-setup.sh" "--help names the script"
check_contains "$HELP_OUT" "EXIT STATUS" "--help carries the exit-status section"
check_eq "$(wc -c < "$HELP_ERR" | tr -d ' ')" "0" "--help writes nothing to stderr"

# --- 2. usage errors ---------------------------------------------------------

new_case "usage"
run bogus-action
check_eq "$RC" "3" "unknown action exits 3"
run add nosuchprovider me@example.com
check_eq "$RC" "3" "unknown provider exits 3"
run add claude "../escape"
check_eq "$RC" "3" "a path-traversal label is rejected (exit 3)"
# Check the resolved destination, not the unresolved `$PROFILES/../escape`:
# the assertion has to name the path a traversal would actually land on.
if [[ -e "$CASE_DIR/escape" ]]; then
  bad "a rejected label must not create a directory outside the profile root"
else
  ok "a rejected label creates nothing outside the profile root"
fi
run add claude "me@example.com" extra-arg
check_eq "$RC" "3" "add with too many arguments exits 3"
run remove
check_eq "$RC" "3" "remove without a label exits 3"

# --- 3. list on an empty registry -------------------------------------------

new_case "empty-list"
run list
check_eq "$RC" "0" "list on an empty registry exits 0"
check_contains "$OUT" "No accounts registered" "empty list says so"
run --json
check_eq "$OUT" "[]" "empty list --json is an empty array"

# --- 4. two claude accounts, both logged in, neither disturbing the other ----

new_case "two-claude"
run add claude first@example.com
check_eq "$RC" "0" "add claude (first) exits 0"
FIRST_DIR="$PROFILES/first@example.com/claude"
FIRST_CRED="$FIRST_DIR/.credentials.json"
if [[ -s "$FIRST_CRED" ]]; then ok "first account's credential landed in its own profile"; else bad "first account's credential is missing"; fi
cp "$FIRST_CRED" "$TMP/first-cred.snapshot"

run add claude second@example.com
check_eq "$RC" "0" "add claude (second) exits 0"
SECOND_DIR="$PROFILES/second@example.com/claude"
if [[ -s "$SECOND_DIR/.credentials.json" ]]; then ok "second account's credential landed in its own profile"; else bad "second account's credential is missing"; fi
if cmp -s "$FIRST_CRED" "$TMP/first-cred.snapshot"; then
  ok "adding the second account left the first account's credential untouched"
else
  bad "adding the second account modified the first account's credential"
fi
check_eq "$(account_count)" "2" "both claude accounts are registered"
check_eq "$(status_of first@example.com claude)" "ok" "first claude account lists as ok"
check_eq "$(status_of second@example.com claude)" "ok" "second claude account lists as ok"

DISTINCT="$(jq -r '[.accounts[].profile_dir] | unique | length' "$CONFIG")"
check_eq "$DISTINCT" "2" "the two accounts have distinct profile_dir values"
check_eq "$(jq -r '.accounts[0].profile_dir' "$CONFIG")" "$FIRST_DIR" "profile_dir follows <root>/<label>/<provider>"

# The stub records the CLAUDE_CONFIG_DIR it was handed: the isolation claim is
# that each login ran against its own directory, not the shared default.
check_contains "$(cat "$STUB_CALL_LOG")" "$SECOND_DIR" "the second login ran against the second profile dir"

# --- 5. no credential value reaches the config -------------------------------

CONFIG_TEXT="$(cat "$CONFIG")"
check_not_contains "$CONFIG_TEXT" "$FIXTURE_SECRET" "the credential value never reaches the config"
# The issue's own Test Plan step, run verbatim on ordinary labels.
LEAKS="$(grep -icE 'token|password|cookie' "$CONFIG" || true)"
check_eq "$LEAKS" "0" "config contains no token/password/cookie text"
run list
check_not_contains "$OUT" "$FIXTURE_SECRET" "list never prints a credential value"

# The grep above is a text match, so a legitimate label like token@example.com
# would trip it (CodeRabbit, local review). The invariant that actually holds
# is about KEY NAMES — assert that one directly, with a label chosen to break
# the text match, so the two checks fail for different reasons.
new_case "credential-key-names"
run add claude token@example.com
check_eq "$RC" "0" "a label containing 'token' registers normally"
KEY_LEAKS="$(jq -r '[paths | map(tostring) | .[]] | map(select(test("token|password|cookie"; "i"))) | length' "$CONFIG")"
check_eq "$KEY_LEAKS" "0" "no JSON key anywhere in the config is a token/password/cookie field"
check_not_contains "$(cat "$CONFIG")" "$FIXTURE_SECRET" "still no credential value in the config"

# --- 6. codex ----------------------------------------------------------------

new_case "codex"
run add codex codexuser@example.com
check_eq "$RC" "0" "add codex exits 0"
CODEX_DIR="$PROFILES/codexuser@example.com/codex"
if [[ -s "$CODEX_DIR/auth.json" ]]; then ok "codex auth.json landed in the per-account CODEX_HOME"; else bad "codex auth.json is missing"; fi
check_contains "$(cat "$STUB_CALL_LOG")" "$CODEX_DIR" "codex login ran with CODEX_HOME set to the profile dir"
check_contains "$(cat "$STUB_CALL_LOG")" "login" "codex was invoked with the login subcommand"
check_eq "$(status_of codexuser@example.com codex)" "ok" "codex account lists as ok"

# A logged-in CODEX_HOME without an auth.json is still logged in: ask the tool.
new_case "codex-status-fallback"
CODEX_BIN_UNDER_TEST="$BIN/codex-status-only"
run add codex statusonly@example.com
check_eq "$RC" "0" "a codex login witnessed only by 'login status' registers"
if [[ -e "$PROFILES/statusonly@example.com/codex/auth.json" ]]; then
  bad "the fixture must not write auth.json — it would mask the status fallback"
else
  ok "the fixture proves the status fallback, not the auth.json probe"
fi
check_eq "$(status_of statusonly@example.com codex)" "ok" "the status-only account lists as ok"
run list
check_not_contains "$OUT" "Logged in as" "the probe discards what 'login status' prints"

# Control: with status failing too, the same shape is honestly logged out.
new_case "codex-really-logged-out"
CODEX_BIN_UNDER_TEST="$BIN/codex-nothing"
run add codex loggedout@example.com
check_eq "$RC" "1" "control(-): no auth.json and a failing status exits 1"
check_eq "$(account_count)" "READ-ERROR" "control(-): and nothing was registered"

# --- 7. cursor logs in through the browser helper (issue #1668) --------------

new_case "cursor"
run add cursor cursoruser@example.com
check_eq "$RC" "0" "add cursor exits 0"
if [[ -d "$PROFILES/cursoruser@example.com/cursor" ]]; then
  ok "the cursor browser profile is created on disk"
else
  bad "the cursor browser profile was not created"
fi
check_eq "$(account_count)" "1" "cursor account is recorded"
check_eq "$(status_of cursoruser@example.com cursor)" "ok" \
  "a completed cursor login lists as ok"
check_contains "$(cat "$STUB_CALL_LOG")" "--mode login" \
  "the cursor login ran headed (--mode login), not as a headless read"
check_contains "$(cat "$STUB_CALL_LOG")" "$PROFILES/cursoruser@example.com/cursor" \
  "and it ran against this account's own profile directory"

# The verdict decides, not the exit status. This stub exits 0 while reporting
# `needs-login` — the exact shape that would register a phantom account if the
# caller read `$?` instead of the JSON the helper prints.
new_case "cursor-abandoned"
NODE_BIN_UNDER_TEST="$BIN/node-login-abandoned"
run add cursor quitter@example.com
check_eq "$RC" "1" "a cursor login the user abandoned exits 1"
check_eq "$(account_count)" "READ-ERROR" "and nothing is registered"
check_contains "$OUT" "did not complete" "the message says the login did not complete"

# No session value may reach stdout, stderr, or the config — the stub writes a
# recognisable cookie store, so this is a real detector rather than a fixture
# that could not have failed.
new_case "cursor-no-leak"
run add cursor leaky@example.com
check_not_contains "$OUT" "STUB-COOKIE-STORE" \
  "no cookie-store content reaches the tool output"
check_not_contains "$(cat "$CONFIG")" "STUB-COOKIE-STORE" \
  "and none of it reaches the config"
check_eq "$(jq -r '[.accounts[0] | paths | map(tostring) | join(".")] | map(select(test("cookie"; "i"))) | length' "$CONFIG")" "0" \
  "no key in the cursor account entry is cookie-shaped"

# relogin REPLACES the profile rather than layering a second session onto it.
new_case "cursor-relogin"
run add cursor recur@example.com
check_eq "$RC" "0" "add cursor for the relogin case exits 0"
CURSOR_DIR="$PROFILES/recur@example.com/cursor"
printf 'stale\n' > "$CURSOR_DIR/STALE-MARKER"
run relogin recur@example.com
check_eq "$RC" "0" "relogin on a cursor account exits 0"
if [[ -e "$CURSOR_DIR/STALE-MARKER" ]]; then
  bad "relogin layered the new session over the old profile (the stale marker survived)"
else
  ok "relogin started a fresh profile — the previous one was moved aside"
fi
check_contains "$OUT" "moved aside" "and it says where the previous profile went"
check_eq "$(status_of recur@example.com cursor)" "ok" "the account is ok again after relogin"

# A second relogin inside the same whole second must not land INSIDE the first
# retirement: `mv olddir existingdir` succeeds by nesting, so the profile would
# be somewhere other than where the message says.
printf 'stale2\n' > "$CURSOR_DIR/STALE-MARKER-2"
run relogin recur@example.com
check_eq "$RC" "0" "a second back-to-back relogin exits 0"
# Asserted by SHAPE, not by counting: whether the two stamps collide depends on
# which side of a second boundary the run lands, so a count would pass for the
# wrong reason half the time. Nesting has one unmistakable signature —
# `cursor.retired-<stamp>/cursor` — and that is what is checked.
NESTED="$(find "$PROFILES/recur@example.com" -maxdepth 2 -mindepth 2 -type d -name cursor 2>/dev/null | wc -l | tr -d ' ')"
check_eq "$NESTED" "0" "no retirement was moved inside an earlier one"
if [[ -e "$CURSOR_DIR/STALE-MARKER-2" ]]; then
  bad "the second relogin did not replace the profile"
else
  ok "and the second relogin started a fresh profile too"
fi

# Deleting the session flips the account back, which is the other half of the
# status contract: presence of the cookie store is the whole signal.
rm -rf "$CURSOR_DIR/Default"
check_eq "$(status_of recur@example.com cursor)" "needs-login" \
  "deleting the browser session flips the cursor account to needs-login"

# A relogin that CANNOT run must not cost the user the session that still
# works: the dependency check has to happen before the profile is moved aside.
new_case "cursor-relogin-no-helper"
run add cursor keepme@example.com
check_eq "$RC" "0" "add cursor for the missing-helper relogin case exits 0"
CURSOR_DIR="$PROFILES/keepme@example.com/cursor"
SAVED_HELPER="$FAKE_CURSOR_HELPER"
FAKE_CURSOR_HELPER="$TMP/no-such-helper.js"
run relogin keepme@example.com
check_eq "$RC" "6" "a relogin with no helper exits 6"
if [[ -s "$CURSOR_DIR/Default/Network/Cookies" ]]; then
  ok "and the working profile is still there — the refused relogin destroyed nothing"
else
  bad "the refused relogin moved the working profile aside anyway"
fi
FAKE_CURSOR_HELPER="$SAVED_HELPER"
check_eq "$(status_of keepme@example.com cursor)" "ok" \
  "the account still reads ok after the refused relogin"

# A missing helper is reported, never worked around.
new_case "cursor-helper-missing"
SAVED_HELPER="$FAKE_CURSOR_HELPER"
FAKE_CURSOR_HELPER="$TMP/no-such-helper.js"
run add cursor nohelper@example.com
check_eq "$RC" "6" "a missing cursor helper exits 6 (the login tool was not found)"
check_contains "$OUT" "missing" "and says the helper is missing"
FAKE_CURSOR_HELPER="$SAVED_HELPER"

# --no-login still reserves a cursor slot without opening anything.
new_case "cursor-no-login"
run add cursor later@example.com --no-login
check_eq "$RC" "0" "add cursor --no-login exits 0"
check_eq "$(status_of later@example.com cursor)" "needs-login" \
  "a reserved cursor slot reports needs-login"
check_eq "$(wc -c < "$STUB_CALL_LOG" | tr -d ' ')" "0" \
  "control(-): --no-login launched no browser at all"

# --- 8. credential disappears -> needs-login; relogin restores it ------------

new_case "relogin"
run add claude relogin@example.com
check_eq "$RC" "0" "add claude for the relogin case exits 0"
check_eq "$(status_of relogin@example.com)" "ok" "account starts as ok"
rm -f "$PROFILES/relogin@example.com/claude/.credentials.json"
check_eq "$(status_of relogin@example.com)" "needs-login" "a deleted credential flips the account to needs-login"
run list
check_eq "$RC" "0" "list still exits 0 with a needs-login account (a report, not a gate)"
run relogin relogin@example.com
check_eq "$RC" "0" "relogin exits 0"
check_eq "$(status_of relogin@example.com)" "ok" "relogin restores the account to ok"
check_eq "$(account_count)" "1" "relogin does not duplicate the account row"

# --- 9. failing logins register nothing (fail-closed) ------------------------

new_case "login-fails"
CLAUDE_BIN_UNDER_TEST="$BIN/claude-fail"
run add claude failed@example.com
check_eq "$RC" "1" "a login that exits non-zero exits 1"
check_eq "$(account_count)" "READ-ERROR" "no config is written when the login fails"

new_case "login-silent"
CLAUDE_BIN_UNDER_TEST="$BIN/claude-silent"
run add claude silent@example.com
check_eq "$RC" "1" "a login that leaves no credential exits 1"
check_contains "$OUT" "no credential" "the message says no credential was visible"
check_eq "$(account_count)" "READ-ERROR" "no account is registered when no credential appears"

# --no-login is the sanctioned way to record that same slot on purpose.
run add claude silent@example.com --no-login
check_eq "$RC" "0" "add --no-login exits 0"
check_eq "$(account_count)" "1" "add --no-login records the slot"
check_eq "$(status_of silent@example.com)" "needs-login" "a --no-login slot lists as needs-login"
CLAUDE_BIN_UNDER_TEST=""

# --- 10. missing provider CLI -----------------------------------------------

new_case "missing-cli"
CLAUDE_BIN_UNDER_TEST="$TMP/definitely-not-installed"
run add claude nocli@example.com
check_eq "$RC" "6" "a missing provider CLI exits 6"
check_contains "$OUT" "CLAUDE_CONFIG_DIR=" "the manual login command is printed"
CLAUDE_BIN_UNDER_TEST=""

# --- 11. duplicate, ambiguous, and unknown labels ----------------------------

new_case "labels"
run add claude dup@example.com
check_eq "$RC" "0" "add claude dup@example.com exits 0"
run add claude dup@example.com
check_eq "$RC" "3" "re-adding the same (provider, label) pair exits 3"
check_eq "$(account_count)" "1" "the duplicate add left one row"

run add codex dup@example.com
check_eq "$RC" "0" "the same label under a different provider is allowed"
run remove dup@example.com
check_eq "$RC" "3" "an ambiguous label exits 3"
check_eq "$(account_count)" "2" "an ambiguous remove deletes nothing"
run remove dup@example.com codex
check_eq "$RC" "0" "remove with a provider exits 0"
check_eq "$(account_count)" "1" "remove with a provider deleted exactly one row"
check_eq "$(jq -r '.accounts[0].provider' "$CONFIG")" "claude" "remove deleted the named provider's row"
if [[ -d "$PROFILES/dup@example.com/codex" ]]; then
  ok "remove leaves the profile directory on disk"
else
  bad "remove destroyed the profile directory"
fi
check_contains "$OUT" "left in place" "remove says where the profile directory is"

run remove nosuch@example.com
check_eq "$RC" "4" "removing an unknown label exits 4"
run relogin nosuch@example.com
check_eq "$RC" "4" "relogin on an unknown label exits 4"

# --- 12. macOS keychain probe ------------------------------------------------

new_case "keychain"
PLATFORM_UNDER_TEST="Darwin"
CLAUDE_BIN_UNDER_TEST="$BIN/claude-keychain"
run add claude mac@example.com
check_eq "$RC" "0" "add claude on Darwin exits 0"
SERVICE="$(jq -r '.accounts[0].credential_ref.service // ""' "$CONFIG")"
check_contains "$SERVICE" "Claude Code-credentials-" "the observed keychain service name is recorded"
check_eq "$(status_of mac@example.com)" "ok" "the keychain-backed account lists as ok"
if [[ -e "$PROFILES/mac@example.com/claude/.credentials.json" ]]; then
  bad "the Darwin fixture must not also write a file credential (it would mask the keychain probe)"
else
  ok "the Darwin fixture proves the keychain probe, not the file probe"
fi

# Drop the item: the recorded name must stop reading as ok.
: > "$STUB_KEYCHAIN_DB"
check_eq "$(status_of mac@example.com)" "needs-login" "a vanished keychain item flips the account to needs-login"

run relogin mac@example.com
check_eq "$RC" "0" "relogin on Darwin exits 0"
NEW_SERVICE="$(jq -r '.accounts[0].credential_ref.service // ""' "$CONFIG")"
check_eq "$(status_of mac@example.com)" "ok" "relogin restores the Darwin account to ok"
if [[ "$NEW_SERVICE" != "$SERVICE" ]]; then
  ok "relogin records the newly created keychain item, not the stale one"
else
  bad "relogin kept the stale keychain service name"
fi

# A second Darwin account must claim its own item and leave the first alone.
run add claude mac2@example.com
check_eq "$RC" "0" "second Darwin account exits 0"
SERVICE_2="$(jq -r '.accounts[1].credential_ref.service // ""' "$CONFIG")"
if [[ -n "$SERVICE_2" && "$SERVICE_2" != "$NEW_SERVICE" ]]; then
  ok "the second Darwin account recorded a distinct keychain item"
else
  bad "the second Darwin account did not get its own keychain item"
fi
check_eq "$(status_of mac@example.com)" "ok" "the first Darwin account is still ok after the second was added"

# Re-registering a label whose profile `remove` left on disk: the login
# rewrites the existing Keychain item, so nothing new appears and the name has
# to come from what was recorded beside the profile.
new_case "keychain-rewrite"
PLATFORM_UNDER_TEST="Darwin"
CLAUDE_BIN_UNDER_TEST="$BIN/claude-keychain-stable"
run add claude stable@example.com
check_eq "$RC" "0" "first add against a stable keychain item exits 0"
STABLE_SERVICE="$(jq -r '.accounts[0].credential_ref.service // ""' "$CONFIG")"
check_eq "$STABLE_SERVICE" "Claude Code-credentials-STABLE01" "the created item is recorded"
SIDECAR="$PROFILES/stable@example.com/.keychain-service-claude"
if [[ -s "$SIDECAR" ]]; then ok "the service name is remembered beside the profile"; else bad "no sidecar was written beside the profile"; fi
check_not_contains "$(cat "$SIDECAR")" "$FIXTURE_SECRET" "the sidecar holds a name, not a value"

run remove stable@example.com
check_eq "$RC" "0" "remove exits 0"
run add claude stable@example.com
check_eq "$RC" "0" "re-adding the same label succeeds even though no NEW keychain item appears"
check_eq "$(jq -r '.accounts[0].credential_ref.service // ""' "$CONFIG")" "$STABLE_SERVICE" "the re-add recorded the same existing item"
check_eq "$(status_of stable@example.com)" "ok" "the re-added account lists as ok"

# Negative control: without the remembered name there is nothing to recall, so
# the same login shape fails closed. Without this, the assertions above could
# pass because the code guessed rather than recalled.
run remove stable@example.com
rm -f "$SIDECAR"
run add claude stable@example.com
check_eq "$RC" "1" "control(-): with the remembered name gone, the same login registers nothing"
check_eq "$(account_count)" "0" "control(-): and no account row was written"

# An ambiguous snapshot is refused rather than guessed: binding an account to
# another account's keychain item is a wrong answer indistinguishable from a
# right one.
new_case "keychain-ambiguous"
PLATFORM_UNDER_TEST="Darwin"
CLAUDE_BIN_UNDER_TEST="$BIN/claude-keychain-double"
run add claude ambiguous@example.com
check_eq "$RC" "1" "two new keychain items across one login exits 1"
check_contains "$OUT" "more than one keychain item" "the message names the ambiguity"
check_eq "$(account_count)" "READ-ERROR" "an ambiguous login registers nothing"

# Positive control on the same fixture family: the single-item stub, run in the
# same case, still registers — so the refusal above is the ambiguity check
# firing, not the Darwin path being broken outright.
CLAUDE_BIN_UNDER_TEST="$BIN/claude-keychain"
run add claude ambiguous@example.com
check_eq "$RC" "0" "control(+): one new keychain item still registers normally"

PLATFORM_UNDER_TEST="Linux"
CLAUDE_BIN_UNDER_TEST=""

# A sidecar the script cannot write is a real degradation, not a nothing: the
# add still succeeds (the credential is verified and the row is genuine), but a
# LATER re-add of this label would then fail closed with no visible cause. The
# assertion is that the failure is reported at the moment it happens. The path
# is blocked by occupying it with a directory rather than by permissions —
# ensure_profile_dir chmods the parent back to 700 on every run, so a
# permission-based block would be undone before the write is attempted, and the
# test would pass for the wrong reason.
new_case "sidecar-unwritable"
PLATFORM_UNDER_TEST="Darwin"
CLAUDE_BIN_UNDER_TEST="$BIN/claude-keychain"
mkdir -p "$PROFILES/blocked@example.com/.keychain-service-claude"
run add claude blocked@example.com
check_eq "$RC" "0" "an unwritable sidecar does not fail the add"
check_contains "$OUT" "could not remember the keychain service name" "the failed sidecar write is reported, not swallowed"
check_eq "$(account_count)" "1" "the account is still registered when the sidecar could not be written"
check_eq "$(status_of blocked@example.com)" "ok" "and it lists as ok — the credential is what decides that"

# Control(+): the same stub with the path free writes the sidecar silently, so
# the warning above is the write failing, not the Darwin path warning always.
run add claude unblocked@example.com
check_eq "$RC" "0" "control(+): the same login with a writable path exits 0"
check_not_contains "$OUT" "could not remember the keychain service name" "control(+): a successful sidecar write warns about nothing"

PLATFORM_UNDER_TEST="Linux"
CLAUDE_BIN_UNDER_TEST=""

# --- 13. an unparseable config is never overwritten --------------------------

new_case "bad-config"
printf 'not json at all\n' > "$CONFIG"
run list
check_eq "$RC" "5" "an unparseable config exits 5"
check_eq "$(cat "$CONFIG")" "not json at all" "the unparseable config is left untouched"

# A future MAJOR schema is refused rather than rewritten — a v1 writer would
# drop whatever v2 fields it does not know about.
new_case "schema-major"
printf '{"schema_version":"2.0","accounts":[]}\n' > "$CONFIG"
run add claude v2@example.com
check_eq "$RC" "5" "a future major schema_version exits 5"
check_contains "$OUT" "schema_version" "the message names the version mismatch"
check_eq "$(jq -r '.schema_version' "$CONFIG")" "2.0" "the v2 config is left untouched"

# ...while a future MINOR is compatible, keeps its own version, and keeps the
# unknown fields it carries. Without this the check above could pass by
# refusing everything.
new_case "schema-minor"
printf '{"schema_version":"1.7","accounts":[],"future_field":"keep me"}\n' > "$CONFIG"
run add claude v1minor@example.com
check_eq "$RC" "0" "control(+): a future minor schema_version is accepted"
check_eq "$(jq -r '.schema_version' "$CONFIG")" "1.7" "the newer minor version is preserved, not downgraded"
check_eq "$(jq -r '.future_field' "$CONFIG")" "keep me" "unknown top-level fields survive a write"

# A row that is missing `profile_dir` is refused, not walked. Read back
# through `jq -r` the absent field becomes the STRING "null", and that string
# reaches `mkdir -p` and `chmod 700 "$(dirname …)"` — creating `./null` and
# chmodding the CURRENT DIRECTORY to 700. `./null` in the working directory is
# the discriminating artifact: it exists only if the malformed row was walked.
new_case "malformed-account-row"
printf '{"schema_version":"1.0","accounts":[{"provider":"claude","label":"broken@example.com"}]}\n' > "$CONFIG"
CWD_PROBE="$CASE_DIR/cwd-probe"
mkdir -p "$CWD_PROBE"
PREV_PWD="$PWD"
cd "$CWD_PROBE" || exit 1
run relogin broken@example.com
cd "$PREV_PWD" || exit 1
check_eq "$RC" "5" "an account row missing profile_dir exits 5"
check_contains "$OUT" "profile_dir" "the message names the field the row is missing"
if [[ -e "$CWD_PROBE/null" ]]; then
  bad "the malformed row was walked — 'null' was created in the working directory"
else
  ok "the malformed row never reached mkdir/chmod in the working directory"
fi

# Control(+): a well-formed row in the same shape still works, so the refusal
# above is the shape check firing rather than relogin being broken outright.
new_case "malformed-account-row-control"
run add claude wellformed@example.com
check_eq "$RC" "0" "control(+): a well-formed row registers"
run relogin wellformed@example.com
check_eq "$RC" "0" "control(+): and relogin on it exits 0"

# The documented argv-list override is SPLIT but never GLOBBED. Splitting is
# the point — it is an argument list, not one word — but an unquoted expansion
# would also expand `*` against the working directory and hand `claude` an
# argv nobody wrote.
new_case "login-args-not-globbed"
GLOB_DIR="$CASE_DIR/globdir"
mkdir -p "$GLOB_DIR"
: > "$GLOB_DIR/decoy-one"
: > "$GLOB_DIR/decoy-two"
PREV_PWD="$PWD"
cd "$GLOB_DIR" || exit 1
export AI_QUOTAS_CLAUDE_LOGIN_ARGS='/login *'
run add claude globby@example.com
unset AI_QUOTAS_CLAUDE_LOGIN_ARGS
cd "$PREV_PWD" || exit 1
check_eq "$RC" "0" "an override carrying a wildcard still registers"
check_contains "$(cat "$STUB_CALL_LOG")" "/login *" "the override reaches claude as written"
check_not_contains "$(cat "$STUB_CALL_LOG")" "decoy-one" "the wildcard is not expanded against the working directory"

# A symlink planted at the label component is the one way out of PROFILE_ROOT
# that the label restriction does not cover: `mkdir -p` follows it, and the
# login would then write its credential outside the root. The discriminating
# assertion is the OUTSIDE directory — a refusal that still deposited a
# credential there would be no refusal at all.
new_case "profile-dir-symlink-escape"
OUTSIDE="$CASE_DIR/outside"
mkdir -p "$OUTSIDE"
mkdir -p "$PROFILES"
ln -s "$OUTSIDE" "$PROFILES/escapee@example.com"
run add claude escapee@example.com
check_eq "$RC" "5" "a profile path that resolves outside the profile root exits 5"
check_contains "$OUT" "outside the profile root" "the message names the containment failure"
check_eq "$(account_count)" "READ-ERROR" "nothing was registered"
if [[ -e "$OUTSIDE/claude/.credentials.json" ]]; then
  bad "a credential was written outside the profile root"
else
  ok "no credential was written outside the profile root"
fi
# The refusal must also leave no DIRECTORY behind (Greptile). Checking only for
# the credential file passes even when `mkdir -p` followed the symlink first and
# the containment check refused afterwards — a refused operation that had
# already written outside the configured root.
if [[ -d "$OUTSIDE/claude" ]]; then
  bad "the refused add still created a directory outside the profile root"
else
  ok "the refused add created no directory outside the profile root"
fi

# Control(+): a symlink that stays INSIDE the root moves nothing out, so it is
# left alone. Without this the check above could pass by refusing every
# symlink, which is a different (and more hostile) rule than the one intended.
new_case "profile-dir-symlink-inside"
mkdir -p "$PROFILES/real-home"
ln -s "$PROFILES/real-home" "$PROFILES/inside@example.com"
run add claude inside@example.com
check_eq "$RC" "0" "control(+): a symlink that stays inside the root is accepted"
check_eq "$(status_of inside@example.com)" "ok" "control(+): and the account lists as ok"

# A `credential_ref` of the wrong TYPE is refused by this script rather than
# by jq. `relogin` reads `.credential_ref.service` through `jq -r`, and jq
# aborts with "Cannot index string" on a string-valued ref — an error that
# names jq's problem, not the user's config.
new_case "malformed-credential-ref"
printf '{"schema_version":"1.0","accounts":[{"provider":"claude","label":"badref@example.com","profile_dir":"%s/badref@example.com/claude","credential_ref":"Claude Code-credentials"}]}\n' "$PROFILES" > "$CONFIG"
run relogin badref@example.com
check_eq "$RC" "5" "a credential_ref of the wrong type exits 5"
check_contains "$OUT" "credential_ref" "the message names credential_ref rather than leaking a jq error"
check_not_contains "$OUT" "Cannot index" "the jq error never reaches the user"

# Control(+): a well-formed credential_ref in the same position is accepted,
# so the refusal above is the type check firing rather than the field being
# rejected outright. `added_at` is absent here on purpose — nothing reads it,
# and requiring it would refuse a config from a newer 1.x writer.
new_case "credential-ref-control"
PLATFORM_UNDER_TEST="Darwin"
CLAUDE_BIN_UNDER_TEST="$BIN/claude-keychain"
run add claude goodref@example.com
check_eq "$RC" "0" "control(+): an add that records a credential_ref exits 0"
jq 'del(.accounts[0].added_at)' "$CONFIG" > "$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG"
check_eq "$(status_of goodref@example.com)" "ok" "control(+): a row with a valid credential_ref and no added_at still reads"
PLATFORM_UNDER_TEST="Linux"
CLAUDE_BIN_UNDER_TEST=""

# A relogin against a profile that already has a Keychain item rewrites that
# item in place, so this login adds nothing to the before/after diff. If ONE
# unrelated item appears in the same window — a concurrent login by a different
# account — it is not ambiguous by count, and adopting it would rebind this
# account to another account's credential. `credential_present` cannot catch
# that: the foreign item does exist, so the account would still report `ok`.
# The discriminating assertion is the SERVICE NAME in the config, not the exit
# code: the pre-fix script exits 0 here too, having recorded the wrong one.
new_case "relogin-foreign-keychain-item"
PLATFORM_UNDER_TEST="Darwin"
CLAUDE_BIN_UNDER_TEST="$BIN/claude-keychain-stable"
run add claude owner@example.com
check_eq "$RC" "0" "the initial add records this profile's own keychain item"
check_eq "$(service_of owner@example.com)" "Claude Code-credentials-STABLE01" \
  "the recorded service is the profile's own item"
CLAUDE_BIN_UNDER_TEST="$BIN/claude-keychain-stable-plus-foreign"
run relogin owner@example.com
check_eq "$RC" "0" "a relogin alongside another account's login still succeeds"
check_eq "$(service_of owner@example.com)" "Claude Code-credentials-STABLE01" \
  "the relogin keeps its own item rather than adopting the one that appeared"
check_eq "$(status_of owner@example.com)" "ok" "and the account still reads ok"
PLATFORM_UNDER_TEST="Linux"
CLAUDE_BIN_UNDER_TEST=""

# Control(+): when the recorded item is GONE and one new item took its place,
# that new item IS this login's and must be adopted. Without this the check
# above could pass by never adopting an appeared item at all, which would
# silently strand every genuine re-key on a dead service name.
new_case "relogin-rekeyed-keychain-item"
PLATFORM_UNDER_TEST="Darwin"
CLAUDE_BIN_UNDER_TEST="$BIN/claude-keychain-stable"
run add claude rekey@example.com
check_eq "$(service_of rekey@example.com)" "Claude Code-credentials-STABLE01" \
  "control(+): the initial add records the original item"
CLAUDE_BIN_UNDER_TEST="$BIN/claude-keychain-rekey"
run relogin rekey@example.com
check_eq "$RC" "0" "control(+): a re-key relogin exits 0"
check_eq "$(service_of rekey@example.com)" "Claude Code-credentials-REKEYED1" \
  "control(+): the replacement item is adopted when the recorded one is gone"
PLATFORM_UNDER_TEST="Linux"
CLAUDE_BIN_UNDER_TEST=""

# `account_status` reports through globals, so its CRED_DETAIL must survive to
# the caller. Called through `$(...)` it would not: the note is set in a
# subshell that is discarded before the next line reads it, and every NOTE
# column and JSON `detail` renders empty — hiding exactly the diagnostic the
# user needs to know WHY an account is not logged in.
new_case "status-detail-survives"
CODEX_BIN_UNDER_TEST="$BIN/codex-nothing"
run add codex nodetail@example.com --no-login
check_eq "$RC" "0" "a reserved codex slot registers"
check_eq "$(status_of nodetail@example.com)" "needs-login" "and reads as needs-login"
check_eq "$(detail_of nodetail@example.com)" "no auth.json in profile" \
  "the JSON detail carries the reason rather than an empty string"
run list
check_contains "$OUT" "no auth.json in profile" "the table NOTE column carries it too"
CODEX_BIN_UNDER_TEST=""

# --- 14. config file mode ----------------------------------------------------

new_case "mode"
run add claude mode@example.com
check_eq "$RC" "0" "add for the mode case exits 0"
MODE="$(ls -l "$CONFIG" | cut -c1-10)"
check_eq "$MODE" "-rw-------" "the config is written with mode 600"

# The profile chain is the credential's neighbourhood: a world-readable parent
# is how a per-account profile stops being isolated.
dir_mode() { ls -ld "$1" | cut -c1-10; }
check_eq "$(dir_mode "$PROFILES")" "drwx------" "the profile root is mode 700"
check_eq "$(dir_mode "$PROFILES/mode@example.com")" "drwx------" "the per-label directory is mode 700"
check_eq "$(dir_mode "$PROFILES/mode@example.com/claude")" "drwx------" "the per-account profile directory is mode 700"

# --- 15. no case, anywhere, asked for a credential value ---------------------
# Cumulative, so it runs last: the stub records every `-w` request across the
# whole suite, and asserting here covers the cases that come after the
# keychain block as well.

check_eq "$(wc -c < "$STUB_SECURITY_VALUE_REQUESTS" | tr -d ' ')" "0" \
  "no case in this suite ever asked security(1) for a credential value (-w)"

# --- summary -----------------------------------------------------------------

echo
echo "passed: $PASS   failed: $FAILED"
[[ "$FAILED" -eq 0 ]] || exit 1
exit 0
