#!/usr/bin/env bash
# ai-quotas-setup.test.sh — coverage for .claude/scripts/ai-quotas-setup.sh
# (issue #1666).
# catalog: tests — Tests `ai-quotas-setup.sh` — the add/remove/relogin/list registry contract, two same-provider accounts staying logged in independently, the macOS Keychain probe against a stub `security` that fails loudly if a credential VALUE is ever requested, the leak assertions (no token/password/cookie and no fixture secret in the config), the fail-closed paths where a login runs but leaves no visible credential, and the Cursor IDE-token model against a fixture SQLite state store (`add`/`relogin` create no profile directory and launch nothing, a signed-out IDE registers nothing, and the relogin slot still refuses a concurrent run)
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

# --- fixtures: the Cursor IDE state store (#1703) ----------------------------
# There is no cursor login to stub any more. `add cursor` / `relogin cursor`
# only ask whether the Cursor IDE is signed in, by reading
# `cursorAuth/accessToken` out of the IDE state store with sqlite3 — so what
# this suite provides is a real fixture DB and the seam pointing at it. No
# browser, no node, no Playwright, and the real IDE store is never touched.
#
# sqlite3 itself is NOT stubbed: the read-only open and the query are the parts
# most likely to break, and a fake would assert nothing about either.
# Resolved, then PROVEN executable. Defaulting a failed lookup to a hardcoded
# path that may not exist turns "sqlite3 is missing" into a pile of unrelated
# cursor failures several hundred lines later (CodeAnt).
SQLITE3_REAL="$(command -v sqlite3 2>/dev/null || true)"
[[ -n "$SQLITE3_REAL" ]] || SQLITE3_REAL="/usr/bin/sqlite3"
[[ -x "$SQLITE3_REAL" ]] || {
  echo "FATAL: no usable sqlite3 (checked PATH and /usr/bin/sqlite3) — the cursor cases cannot run" >&2
  exit 1
}
CURSOR_DB_SIGNED_IN="$TMP/cursor-signed-in.vscdb"
CURSOR_DB_SIGNED_OUT="$TMP/cursor-signed-out.vscdb"
CURSOR_DB_MISSING="$TMP/no-such-cursor-state.vscdb"

# Token-shaped but inert. It is asserted ABSENT from the config, so it has to
# be a value a leak would actually put there.
CURSOR_FIXTURE_TOKEN="eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJGSVhUVVJFLTE3MDMifQ.FIXTURESIGNATURE"
CURSOR_FIXTURE_EMAIL="cursor-fixture@example.com"

build_cursor_db() { # <path> <token|"">
  rm -f "$1"
  # WAL, like the real IDE store (CodeRabbit) — the presence probe opens it
  # read-only, and a rollback-journal fixture would exercise a different open
  # path than the one that ships.
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

build_cursor_db "$CURSOR_DB_SIGNED_IN" "$CURSOR_FIXTURE_TOKEN" \
  || { echo "FATAL: could not build the cursor fixture DB with $SQLITE3_REAL" >&2; exit 1; }
build_cursor_db "$CURSOR_DB_SIGNED_OUT" "" \
  || { echo "FATAL: could not build the signed-out cursor fixture DB" >&2; exit 1; }
rm -f "$CURSOR_DB_MISSING"

# Which store a case reads. Always one of this suite's own temp paths — the
# seam is passed unconditionally, so the reader can never fall through to the
# real ~/Library/… store.
CURSOR_DB_UNDER_TEST=""

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

# --- stub: launchctl ---------------------------------------------------------
# launchd, modelled as one state file. `bootstrap`/`load` create it,
# `bootout`/`unload` remove it, `list`/`print` report it — which is the whole
# of the contract `schedule` depends on.
#
# HARD-FAILS on a subcommand it does not recognise (exit 90), so a `schedule`
# that starts calling something new reddens the suite instead of quietly
# treating an unknown call as a failed one and taking a fallback path.
#
# STUB_LAUNCHCTL_BOOTSTRAP_FAILS drives the fallback deliberately: the modern
# `bootstrap` spelling is refused, and the legacy `load -w` must then be what
# gets the job loaded.
#
# STUB_LAUNCHCTL_LOAD_FAILS and STUB_LAUNCHCTL_BOOTOUT_FAILS exist for the one
# case neither of those reaches: a bootout that does not take, followed by a
# bootstrap and a load that are both refused. The label is then still held by
# the definition loaded BEFORE the install, so `list` keeps answering "loaded"
# — the shape an install must not report as success. A failed bootout leaves
# the state file in place precisely so that stays true.
#
# The stub also CHECKS the arguments it is given rather than accepting any
# label, domain, or path. A fake whose default is success absorbs a call it
# was never taught about: an install that bootstrapped the wrong plist, or
# booted out a domain-less label, would pass every assertion here and fail
# only on a real Mac. The checks are on SHAPE, not on per-case values, so they
# stay true as cases are added: a domain is `gui/<uid>`, a bootout target is
# that plus a label, and a path handed to bootstrap/load/unload must be a
# plist that actually exists at the moment it is passed. A violation exits 91,
# distinct from the unrecognised-call 90, and says which rule was broken.
cat > "$BIN/launchctl" <<'EOF'
#!/usr/bin/env bash
printf 'launchctl %s\n' "$*" >> "$STUB_LAUNCHCTL_LOG"
stub_die() { echo "STUB-LAUNCHCTL: $1" >&2; exit 91; }
stub_check_domain() { # <domain>
  [[ "$1" =~ ^gui/[0-9]+$ ]] || stub_die "expected a gui/<uid> domain, got: $1"
}
stub_check_service() { # <domain/label>
  [[ "$1" =~ ^gui/[0-9]+/[A-Za-z0-9._-]+$ ]] \
    || stub_die "expected a gui/<uid>/<label> service target, got: $1"
}
stub_check_plist() { # <path>
  [[ "$1" == *.plist ]] || stub_die "expected a .plist path, got: $1"
  [[ -f "$1" ]] || stub_die "handed a plist path that does not exist: $1"
}
case "${1:-}" in
  bootstrap)
    [[ $# -eq 3 ]] || stub_die "bootstrap takes a domain and a path, got: $*"
    stub_check_domain "$2"; stub_check_plist "$3" ;;
  bootout)
    [[ $# -eq 2 ]] || stub_die "bootout takes one service target, got: $*"
    stub_check_service "$2" ;;
  load|unload)
    [[ "${2:-}" == "-w" ]] || stub_die "$1 is expected with -w, got: $*"
    [[ $# -eq 3 ]] || stub_die "$1 -w takes one path, got: $*"
    stub_check_plist "$3" ;;
  print)
    [[ $# -eq 2 ]] || stub_die "print takes one service target, got: $*"
    stub_check_service "$2" ;;
esac
case "${1:-}" in
  list|print)
    [[ -f "$STUB_LAUNCHCTL_STATE" ]] && exit 0
    exit 113
    ;;
  bootstrap)
    if [[ "${STUB_LAUNCHCTL_BOOTSTRAP_FAILS:-0}" == "1" ]]; then exit 5; fi
    : > "$STUB_LAUNCHCTL_STATE"; exit 0 ;;
  load)
    if [[ "${STUB_LAUNCHCTL_LOAD_FAILS:-0}" == "1" ]]; then exit 5; fi
    : > "$STUB_LAUNCHCTL_STATE"; exit 0 ;;
  bootout|unload)
    if [[ "${STUB_LAUNCHCTL_BOOTOUT_FAILS:-0}" == "1" ]]; then exit 5; fi
    rm -f "$STUB_LAUNCHCTL_STATE"; exit 0 ;;
esac
echo "STUB-LAUNCHCTL: unrecognised call: $*" >&2
exit 90
EOF

chmod +x "$BIN"/*

# --- harness -----------------------------------------------------------------

export STUB_CALL_LOG="$TMP/calls.log"
export STUB_KEYCHAIN_DB="$TMP/keychain.db"
export STUB_KEYCHAIN_SEQ="$TMP/keychain.seq"
export STUB_SECURITY_VALUE_REQUESTS="$TMP/security-value-requests.log"
export STUB_LAUNCHCTL_LOG="$TMP/launchctl.log"
export STUB_LAUNCHCTL_STATE="$TMP/launchctl.loaded"
export STUB_LAUNCHCTL_BOOTSTRAP_FAILS=0
export STUB_LAUNCHCTL_LOAD_FAILS=0
export STUB_LAUNCHCTL_BOOTOUT_FAILS=0
: > "$STUB_CALL_LOG"
: > "$STUB_KEYCHAIN_DB"
printf '0\n' > "$STUB_KEYCHAIN_SEQ"
: > "$STUB_SECURITY_VALUE_REQUESTS"
: > "$STUB_LAUNCHCTL_LOG"
rm -f "$STUB_LAUNCHCTL_STATE"

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
  SQLITE3_BIN_UNDER_TEST=""
  CURSOR_DB_UNDER_TEST=""
  READER_BIN_UNDER_TEST=""
  STUB_LAUNCHCTL_BOOTSTRAP_FAILS=0
  STUB_LAUNCHCTL_LOAD_FAILS=0
  STUB_LAUNCHCTL_BOOTOUT_FAILS=0
  CASE_DIR="$TMP/case-$(printf '%s' "$1" | tr -c 'A-Za-z0-9' '-')"
  rm -rf "$CASE_DIR"
  mkdir -p "$CASE_DIR/home/.claude"
  CONFIG="$CASE_DIR/ai-quotas.json"
  PROFILES="$CASE_DIR/profiles"
  : > "$STUB_CALL_LOG"
  : > "$STUB_KEYCHAIN_DB"
  : > "$STUB_LAUNCHCTL_LOG"
  rm -f "$STUB_LAUNCHCTL_STATE"
}

run() { # <args...>  — never aborts the suite; sets OUT and RC
  OUT="$(HOME="$CASE_DIR/home" \
        AI_QUOTAS_CONFIG="$CONFIG" \
        AI_QUOTAS_PROFILE_ROOT="$PROFILES" \
        AI_QUOTAS_PLATFORM="${PLATFORM_UNDER_TEST:-Linux}" \
        AI_QUOTAS_SECURITY_BIN="$BIN/security" \
        AI_QUOTAS_CLAUDE_BIN="${CLAUDE_BIN_UNDER_TEST:-$BIN/claude-file}" \
        AI_QUOTAS_CODEX_BIN="${CODEX_BIN_UNDER_TEST:-$BIN/codex-file}" \
        AI_QUOTAS_SQLITE3_BIN="${SQLITE3_BIN_UNDER_TEST:-$SQLITE3_REAL}" \
        AI_QUOTAS_CURSOR_STATE_DB="${CURSOR_DB_UNDER_TEST:-$CURSOR_DB_SIGNED_IN}" \
        AI_QUOTAS_LAUNCHCTL_BIN="$BIN/launchctl" \
        AI_QUOTAS_READER_BIN="${READER_BIN_UNDER_TEST-}" \
        STUB_LAUNCHCTL_BOOTSTRAP_FAILS="${STUB_LAUNCHCTL_BOOTSTRAP_FAILS:-0}" \
        STUB_LAUNCHCTL_LOAD_FAILS="${STUB_LAUNCHCTL_LOAD_FAILS:-0}" \
        STUB_LAUNCHCTL_BOOTOUT_FAILS="${STUB_LAUNCHCTL_BOOTOUT_FAILS:-0}" \
        "$SCRIPT" "$@" 2>&1)"
  RC=$?
}

# The plist, the job log, and the history file all resolve from HOME, so every
# `schedule` case is already confined to the case directory — nothing here can
# touch the real ~/Library/LaunchAgents or the owner's own registry.
plist_path() { printf '%s' "$CASE_DIR/home/Library/LaunchAgents/com.claude.ai-quotas.plist"; }
history_path() { printf '%s' "$CASE_DIR/home/.claude/ai-quotas-history.jsonl"; }
nickname_of() { # <label>
  jq -r --arg l "$1" '.accounts[] | select(.label == $l) | .nickname // "<none>"' \
    "$CONFIG" 2>/dev/null || echo "READ-ERROR"
}
has_nickname_key() { # <label>
  jq -r --arg l "$1" '[.accounts[] | select(.label == $l) | has("nickname")] | first | tostring' \
    "$CONFIG" 2>/dev/null || echo "READ-ERROR"
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
    AI_QUOTAS_SQLITE3_BIN="${SQLITE3_BIN_UNDER_TEST:-$SQLITE3_REAL}" \
    AI_QUOTAS_CURSOR_STATE_DB="${CURSOR_DB_UNDER_TEST:-$CURSOR_DB_SIGNED_IN}" \
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
    AI_QUOTAS_SQLITE3_BIN="${SQLITE3_BIN_UNDER_TEST:-$SQLITE3_REAL}" \
    AI_QUOTAS_CURSOR_STATE_DB="${CURSOR_DB_UNDER_TEST:-$CURSOR_DB_SIGNED_IN}" \
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

# --- 7. cursor reads the Cursor IDE login (issue #1703) ----------------------
#
# There is no login for this tool to run. `add cursor` and `relogin … cursor`
# confirm the Cursor IDE is signed in and say "open the Cursor IDE and sign in"
# when it is not. Nothing opens, and no profile directory is created.

new_case "cursor"
run add cursor cursoruser@example.com
check_eq "$RC" "0" "add cursor exits 0 when the IDE is signed in"
if [[ -e "$PROFILES/cursoruser@example.com/cursor" ]]; then
  bad "add cursor created a profile directory — the IDE owns this credential"
else
  ok "add cursor creates NO profile directory"
fi
check_eq "$(account_count)" "1" "cursor account is recorded"
check_eq "$(status_of cursoruser@example.com cursor)" "ok" \
  "a signed-in IDE lists as ok"
check_contains "$(detail_of cursoruser@example.com cursor)" "signed in" \
  "and the note says the IDE is signed in"
check_contains "$OUT" "no profile directory is created" \
  "and add says so on screen"
# The one thing that must NOT have happened.
check_eq "$(wc -c < "$STUB_CALL_LOG" | tr -d ' ')" "0" \
  "control(-): no provider CLI was launched for a cursor add"

# A signed-out IDE registers nothing. The old browser path proved this by
# reading a JSON verdict rather than an exit status; the same property holds
# here — the presence probe decides, and it fails closed.
new_case "cursor-signed-out"
CURSOR_DB_UNDER_TEST="$CURSOR_DB_SIGNED_OUT"
run add cursor quitter@example.com
check_eq "$RC" "1" "add cursor against a signed-out IDE exits 1"
check_eq "$(account_count)" "READ-ERROR" "and nothing is registered"
check_contains "$OUT" "not signed in" "the message says the IDE is not signed in"
check_contains "$OUT" "open the Cursor IDE and sign in" \
  "and gives the only instruction that can fix it"
CURSOR_DB_UNDER_TEST=""

# Nothing about the IDE store may reach the tool's output or the config. The
# fixture token is token-shaped, so this is a real detector rather than a
# fixture that could not have failed.
new_case "cursor-no-leak"
run add cursor leaky@example.com
check_not_contains "$OUT" "$CURSOR_FIXTURE_TOKEN" \
  "no access token reaches the tool output"
check_not_contains "$OUT" "eyJ" \
  "nothing JWT-shaped reaches the tool output"
check_not_contains "$(cat "$CONFIG")" "$CURSOR_FIXTURE_TOKEN" \
  "and no token reaches the config"
check_eq "$(jq -r '[.accounts[0] | paths | map(tostring) | join(".")] | map(select(test("token|cookie"; "i"))) | length' "$CONFIG")" "0" \
  "no key in the cursor account entry is token- or cookie-shaped"
check_eq "$(jq -r '.accounts[0] | has("credential_ref") | tostring' "$CONFIG")" "false" \
  "and credential_ref stays unset for cursor"

# relogin is an instruction plus a presence check. It retires nothing, because
# there is no longer a profile to retire (#1703 removed that machinery).
new_case "cursor-relogin"
run add cursor recur@example.com
check_eq "$RC" "0" "add cursor for the relogin case exits 0"
run relogin recur@example.com
check_eq "$RC" "0" "relogin on a cursor account exits 0"
check_contains "$OUT" "signed in" "and confirms the IDE holds a token"
check_not_contains "$OUT" "moved aside" \
  "and it does NOT claim to have moved a profile aside"
# Searched from the profile ROOT, not from this account's directory: cursor no
# longer has one, so a find rooted there would scan a path that does not exist,
# print nothing, and pass no matter what the code did (CodeRabbit). The root
# always exists, so a retirement anywhere under it is caught.
RETIRED="$(find "$PROFILES" -type d -name 'cursor.retired-*' 2>/dev/null | wc -l | tr -d ' ')"
check_eq "$RETIRED" "0" "no retirement directory is created anywhere under the profile root"
if [[ -e "$PROFILES/recur@example.com/cursor" ]]; then
  bad "relogin created a profile directory"
else
  ok "and relogin creates no profile directory either"
fi
check_eq "$(status_of recur@example.com cursor)" "ok" "the account is ok after relogin"

# Signing out of the IDE flips the account back, which is the other half of the
# status contract: presence of the token is the whole signal.
CURSOR_DB_UNDER_TEST="$CURSOR_DB_SIGNED_OUT"
check_eq "$(status_of recur@example.com cursor)" "needs-login" \
  "signing out of the IDE flips the cursor account to needs-login"
check_contains "$(detail_of recur@example.com cursor)" "not signed in" \
  "and the note says which"
CURSOR_DB_UNDER_TEST=""

# cursor is a SINGLETON (CodeAnt). Every other provider isolates accounts by
# profile directory, so two labels are two accounts; cursor has no directory
# and every row reads the one IDE store, so a second label would register the
# same account twice and /quotas would render two rows with identical usage.
# The pre-existing duplicate-label guard cannot catch it — the labels differ.
new_case "cursor-singleton"
run add cursor first@example.com
check_eq "$RC" "0" "the first cursor add exits 0"
run add cursor second@example.com
check_eq "$RC" "3" "a second cursor add under a different label is refused"
check_contains "$OUT" "first@example.com" \
  "and the refusal names the label already holding the slot"
check_eq "$(account_count)" "1" "nothing is registered by the refused add"
# control(+): the refusal is about cursor being a singleton, not about adding a
# second account at all — a different provider under a second label still works.
run add codex alsome@example.com
check_eq "$RC" "0" "control(+): a second account on another provider is still allowed"
check_eq "$(account_count)" "2" "and it is recorded"

# The default store path is chosen by PLATFORM, not hardcoded to macOS
# (CodeAnt). This is the one case that must run WITHOUT the state-db env seam
# — `run` always sets it, which is exactly what hid the hardcoded path — so it
# invokes the script directly with the seam absent and reads the path back off
# the line `add` prints. `--no-login` because no store exists at either path.
run_no_db_seam() { # <platform> <args...> — sets OUT/RC, no AI_QUOTAS_CURSOR_STATE_DB
  local plat="$1"; shift
  OUT="$(HOME="$CASE_DIR/home" \
        AI_QUOTAS_CONFIG="$CONFIG" \
        AI_QUOTAS_PROFILE_ROOT="$PROFILES" \
        AI_QUOTAS_PLATFORM="$plat" \
        AI_QUOTAS_SECURITY_BIN="$BIN/security" \
        AI_QUOTAS_SQLITE3_BIN="$SQLITE3_REAL" \
        AI_QUOTAS_LAUNCHCTL_BIN="$BIN/launchctl" \
        "$SCRIPT" "$@" 2>&1)"
  RC=$?
}

new_case "cursor-state-db-platform"
run_no_db_seam Linux add cursor linuxuser@example.com --no-login
check_eq "$RC" "0" "add cursor --no-login on Linux exits 0"
check_contains "$OUT" "/.config/Cursor/User/globalStorage/state.vscdb" \
  "a Linux platform resolves the documented Linux store path"
check_not_contains "$OUT" "Library/Application Support/Cursor" \
  "and does NOT name the macOS path — the bug was a signed-in Linux user reading needs-login"
new_case "cursor-state-db-platform-darwin"
run_no_db_seam Darwin add cursor macuser@example.com --no-login
check_eq "$RC" "0" "control(+): the same add on Darwin exits 0"
check_contains "$OUT" "Library/Application Support/Cursor/User/globalStorage/state.vscdb" \
  "control(+): Darwin still resolves the macOS store path"

# The singleton check is re-run UNDER THE WRITE LOCK, not only pre-flight
# (CodeAnt). Two concurrent `add cursor` runs under different labels both clear
# the pre-flight read, and without the second check the loser appends the very
# duplicate row the reference doc promises cannot exist.
#
# The race is made deterministic through the sqlite3 seam: the presence probe
# runs between the pre-flight read and `state_lock_acquire`, so a wrapper that
# registers a rival cursor account there IS the competing process, landing in
# exactly the window the lock exists to close. It then execs the real sqlite3,
# so the probe still answers honestly and the add still reaches the lock — a
# stub that faked the answer would prove nothing about this window.
#
# The rival row carries a non-empty `profile_dir` because `read_config` refuses
# a row without one. A blank there made the loser die 5 on the config read
# BEFORE the lock — every downstream assertion still passed, for the wrong
# reason. The exit-code assertion is what caught it.
new_case "cursor-singleton-under-lock"
RIVAL="$TMP/sqlite3-registers-a-rival"
cat > "$RIVAL" <<RIVALEOF
#!/usr/bin/env bash
if [[ ! -e "$TMP/rival-done" ]]; then
  : > "$TMP/rival-done"
  jq '.accounts += [{"provider":"cursor","label":"rival@example.com","profile_dir":"/nonexistent/rival/cursor","added_at":"2026-01-01T00:00:00Z"}]' \
    "$CONFIG" > "$TMP/rival.json" && mv "$TMP/rival.json" "$CONFIG"
fi
exec "$SQLITE3_REAL" "\$@"
RIVALEOF
chmod +x "$RIVAL"
rm -f "$TMP/rival-done"
# Seeded so the config exists for the rival to append to — a claude row, so the
# pre-flight cursor check genuinely passes and the refusal can only come from
# the re-check under the lock.
run add claude holder@example.com
check_eq "$RC" "0" "the seed claude add exits 0"
SQLITE3_BIN_UNDER_TEST="$RIVAL"
run add cursor loser@example.com
SQLITE3_BIN_UNDER_TEST=""
check_eq "$RC" "3" "an add that loses the race to another cursor registration exits 3"
check_contains "$OUT" "another process" \
  "and says the rival registered it while this add ran"
check_eq "$(jq '[.accounts[] | select(.provider == "cursor")] | length' "$CONFIG")" "1" \
  "exactly one cursor account survives — the duplicate row is never appended"
check_eq "$(jq -r '[.accounts[] | select(.provider == "cursor") | .label] | .[0]' "$CONFIG")" "rival@example.com" \
  "and it is the rival's, not the loser's"
# control(+): the same wrapper with no rival to register lets the add through,
# so the refusal above is the lock re-check and not the wrapper breaking sqlite3.
new_case "cursor-singleton-under-lock-control"
: > "$TMP/rival-done"
SQLITE3_BIN_UNDER_TEST="$RIVAL"
run add cursor winner@example.com
SQLITE3_BIN_UNDER_TEST=""
check_eq "$RC" "0" "control(+): the same wrapper without a rival registers normally"
check_eq "$(account_count)" "1" "control(+): and the account is recorded"

# A relogin against a signed-out IDE fails and registers nothing new.
new_case "cursor-relogin-signed-out"
run add cursor lapsed@example.com
check_eq "$RC" "0" "add cursor for the lapsed case exits 0"
CURSOR_DB_UNDER_TEST="$CURSOR_DB_SIGNED_OUT"
run relogin lapsed@example.com
check_eq "$RC" "1" "a relogin against a signed-out IDE exits 1"
check_contains "$OUT" "open the Cursor IDE and sign in" "and says what to do"
CURSOR_DB_UNDER_TEST=""
check_eq "$(status_of lapsed@example.com cursor)" "ok" \
  "and the account is untouched — signing back in restores it"

# Two relogins for one account must not both run (CodeAnt, PR #1689). The slot
# no longer guards a profile retirement — #1703 removed that — but it still
# guards the registry write, and a refusal must cost the account nothing.
new_case "cursor-relogin-concurrent-refused"
run add cursor busy@example.com
check_eq "$RC" "0" "add cursor for the concurrent-relogin case exits 0"
# $$ is this suite's own pid, so the recorded holder is genuinely alive — the
# refusal is being proven for a live holder, not for an unparseable one.
SLOT_DIR="$PROFILES/.relogin-slots/busy@example.com__cursor"
mkdir -p "${SLOT_DIR}"
printf '%s\n' "$$" > "${SLOT_DIR}/pid"
run relogin busy@example.com
check_eq "$RC" "7" "a relogin racing a live one exits 7"
check_contains "$OUT" "already running" "and says another relogin holds the account"
check_contains "$OUT" "is unchanged" "and states the account was not touched"
if [[ -d "${SLOT_DIR}" ]]; then
  ok "and the live holder's slot marker was left alone"
else
  bad "the refused relogin deleted the running relogin's slot marker"
fi
check_eq "$(status_of busy@example.com cursor)" "ok" \
  "the account still reads ok after the refused relogin"
rm -rf "${SLOT_DIR}"

# The other half of the same guard: a relogin killed hard (lost terminal,
# reboot mid-login) leaves a marker no one owns. Refusing forever on a dead
# holder would be a permanent lockout with no documented way out, so a holder
# this run can PROVE is gone is taken over rather than waited on.
new_case "cursor-relogin-abandoned-slot-taken-over"
run add cursor stale@example.com
check_eq "$RC" "0" "add cursor for the abandoned-slot case exits 0"
# A pid that has been reaped: started and waited for, so it is not running and
# the kernel has not had the chance to hand the number to anything else.
( exit 0 ) & DEAD_PID=$!
wait "$DEAD_PID" 2>/dev/null || true
SLOT_DIR="$PROFILES/.relogin-slots/stale@example.com__cursor"
mkdir -p "${SLOT_DIR}"
printf '%s\n' "$DEAD_PID" > "${SLOT_DIR}/pid"
run relogin stale@example.com
check_eq "$RC" "0" "a relogin inheriting an abandoned slot runs and exits 0"
check_eq "$(status_of stale@example.com cursor)" "ok" \
  "and the account is logged in again afterwards"
if [[ -d "${SLOT_DIR}" ]]; then
  bad "the finished relogin left its slot marker behind — the next one would be refused"
else
  ok "and the finished relogin released the slot"
fi
STALE_LEFTOVER="$(find "$PROFILES/.relogin-slots" -maxdepth 1 -type d -name 'stale@example.com__cursor.stale.*' 2>/dev/null | wc -l | tr -d ' ')"
check_eq "$STALE_LEFTOVER" "0" "and cleaned up the abandoned marker it displaced"

# The slot is released on the FAILURE path too (CodeRabbit, local review). A
# relogin that gives up still holds the slot until its trap runs, and a slot
# leaked there would refuse every later attempt for the account — turning one
# failed login into a permanently unrepairable one. The retry is the assertion
# that matters: it has to succeed outright, not by recovering an abandoned
# marker, which is a path with its own guard and its own failure modes.
new_case "cursor-relogin-failure-releases-slot"
run add cursor freed@example.com
check_eq "$RC" "0" "add cursor for the slot-release case exits 0"
SLOT_DIR="$PROFILES/.relogin-slots/freed@example.com__cursor"
CURSOR_DB_UNDER_TEST="$CURSOR_DB_SIGNED_OUT"
run relogin freed@example.com
check_eq "$RC" "1" "the relogin against a signed-out IDE exits 1"
CURSOR_DB_UNDER_TEST=""
if [[ -d "$SLOT_DIR" ]]; then
  bad "the failed relogin leaked its slot marker — the account could never be relogged in"
else
  ok "the failed relogin released its slot marker"
fi
run relogin freed@example.com
check_eq "$RC" "0" "and the next relogin runs straight away, with no slot to recover"
check_eq "$(status_of freed@example.com cursor)" "ok" \
  "and the account is logged in again"

# Recovering an abandoned slot is itself serialized (CodeRabbit, local review).
# Two recoveries both finding the marker dead is the subtle re-entry of the same
# bug: the first replaces the marker and starts a login, the second moves that
# now-LIVE marker aside and claims the slot on top of it. A recovery already in
# progress is refused, not waited out and not broken.
new_case "cursor-relogin-recovery-serialized"
run add cursor recover@example.com
check_eq "$RC" "0" "add cursor for the serialized-recovery case exits 0"
SLOT_DIR="$PROFILES/.relogin-slots/recover@example.com__cursor"
( exit 0 ) & DEAD_PID=$!
wait "$DEAD_PID" 2>/dev/null || true
mkdir -p "${SLOT_DIR}"
printf '%s\n' "$DEAD_PID" > "${SLOT_DIR}/pid"
# A recovery already under way, staged exactly as a competing run leaves it:
# the dead marker still in place, the recovery guard taken.
mkdir -p "${SLOT_DIR}.recovering"
run relogin recover@example.com
check_eq "$RC" "7" "a relogin racing another run's slot recovery exits 7"
check_contains "$OUT" "recovering this slot" "and says a recovery is in progress"
if [[ -d "${SLOT_DIR}.recovering" ]]; then
  ok "and the in-progress recovery guard was left alone, not broken"
else
  bad "the refused relogin broke the guard it was supposed to respect"
fi
check_eq "$(status_of recover@example.com cursor)" "ok" \
  "and the account is untouched by the refusal"
rm -rf "${SLOT_DIR}.recovering" "${SLOT_DIR}"

# The slot must not depend on the profile tree still being there (CodeRabbit,
# local review). For cursor there is no tree at all now, which makes the point
# sharper rather than moot: a relogin must run regardless.
new_case "cursor-relogin-deleted-profile-tree"
run add cursor gone@example.com
check_eq "$RC" "0" "add cursor for the deleted-tree case exits 0"
rm -rf "$PROFILES/gone@example.com"
run relogin gone@example.com
check_eq "$RC" "0" "a relogin with no profile tree still runs and exits 0"
check_eq "$(status_of gone@example.com cursor)" "ok" \
  "and the account is logged in again afterwards"

# A missing sqlite3 is reported, never worked around: without it this tool
# cannot see whether the IDE is signed in, and guessing either way is worse
# than saying so. Exit 6 is the same "provider tool not found" code the old
# missing-node/helper path used.
new_case "cursor-sqlite3-missing"
SQLITE3_BIN_UNDER_TEST="$TMP/no-such-sqlite3"
run add cursor nosqlite@example.com
check_eq "$RC" "6" "a missing sqlite3 exits 6 (the provider tool was not found)"
check_contains "$OUT" "sqlite3" "and says which tool is missing"
check_not_contains "$OUT" "no 'cursor' CLI found" \
  "and does NOT send the user looking for a cursor login binary"
SQLITE3_BIN_UNDER_TEST=""

# An unreadable state store is not the same as a signed-out IDE, and `list`
# says so rather than telling the user to sign in again over a missing tool.
new_case "cursor-state-store-missing"
run add cursor nostore@example.com --no-login
CURSOR_DB_UNDER_TEST="$CURSOR_DB_MISSING"
check_eq "$(status_of nostore@example.com cursor)" "needs-login" \
  "an absent state store reads needs-login"
check_contains "$(detail_of nostore@example.com cursor)" "no readable Cursor IDE state store" \
  "and the note says the store is missing, not that the IDE is signed out"
CURSOR_DB_UNDER_TEST=""

# A store that EXISTS but is not a database is a different failure from one
# that is absent, and from an IDE that is signed out (CodeRabbit). Without this
# case the read-error branch of cursor_token_present ships uncovered.
new_case "cursor-state-store-corrupt"
run add cursor corrupt@example.com --no-login
CURSOR_DB_CORRUPT="$TMP/cursor-corrupt.vscdb"
printf 'this is not a SQLite database at all\n' > "$CURSOR_DB_CORRUPT"
CURSOR_DB_UNDER_TEST="$CURSOR_DB_CORRUPT"
check_eq "$(status_of corrupt@example.com cursor)" "needs-login" \
  "an unreadable state store still lists (a report, never a gate)"
check_contains "$(detail_of corrupt@example.com cursor)" "could not read" \
  "and the note names a READ failure rather than claiming the IDE is signed out"
CURSOR_DB_UNDER_TEST=""

# A zero-length token is signed out, and the probe has to agree with the reader
# about that. The column is declared BLOB, and SQLite never compares a blob
# equal to a text literal — so `value <> ''` would call an empty blob a present
# token while the reader, which checks the value it read, called it absent
# (CodeRabbit).
new_case "cursor-empty-token-blob"
run add cursor emptytok@example.com --no-login
CURSOR_DB_EMPTY_BLOB="$TMP/cursor-empty-blob.vscdb"
rm -f "$CURSOR_DB_EMPTY_BLOB"
"$SQLITE3_REAL" "$CURSOR_DB_EMPTY_BLOB" "PRAGMA journal_mode=WAL;" >/dev/null
"$SQLITE3_REAL" "$CURSOR_DB_EMPTY_BLOB" "create table ItemTable (key TEXT PRIMARY KEY, value BLOB);"
# x'' is a genuine zero-length BLOB, which is the storage class the real store
# uses — a '' text literal here would not exercise the bug at all.
"$SQLITE3_REAL" "$CURSOR_DB_EMPTY_BLOB" \
  "insert into ItemTable (key, value) values ('cursorAuth/accessToken', x'');"
CURSOR_DB_UNDER_TEST="$CURSOR_DB_EMPTY_BLOB"
check_eq "$(status_of emptytok@example.com cursor)" "needs-login" \
  "a zero-length BLOB token reads as signed out, not as a present token"
CURSOR_DB_UNDER_TEST=""

# --no-login still reserves a cursor slot without checking anything.
new_case "cursor-no-login"
CURSOR_DB_UNDER_TEST="$CURSOR_DB_SIGNED_OUT"
run add cursor later@example.com --no-login
check_eq "$RC" "0" "add cursor --no-login exits 0 even with the IDE signed out"
CURSOR_DB_UNDER_TEST=""
check_eq "$(status_of later@example.com cursor)" "ok" \
  "and the reserved slot reads ok once the IDE is signed in"
check_eq "$(wc -c < "$STUB_CALL_LOG" | tr -d ' ')" "0" \
  "control(-): --no-login launched nothing at all"

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

# --- 15. nicknames (#1700) ---------------------------------------------------
#
# A nickname is what `/quotas` prints in place of a full subscription email,
# so what matters here is that it reaches the registry intact, that clearing
# one REMOVES the key rather than storing an empty string, and that a value
# which would corrupt the table it is displayed in is refused rather than
# stored and rendered.

new_case "nick-add"
run add codex gpt-lm@example.com --nick "GPT LM"
check_eq "$RC" "0" "add --nick exits 0"
check_eq "$(nickname_of gpt-lm@example.com)" "GPT LM" "add --nick records the nickname"
check_contains "$OUT" "GPT LM" "and the confirmation names it"
run list
check_contains "$OUT" "NICKNAME" "the list table has a nickname column"
check_contains "$OUT" "GPT LM" "showing the nickname"
run list --json
check_eq "$(printf '%s' "$OUT" | jq -r '.[0].nickname')" "GPT LM" "list --json carries the nickname"

new_case "nick-absent"
run add codex plain@example.com
check_eq "$RC" "0" "an add without --nick exits 0"
check_eq "$(has_nickname_key plain@example.com)" "false" \
  "control(-): an account registered without one carries no nickname key at all"
run list --json
check_eq "$(printf '%s' "$OUT" | jq -r '.[0].nickname | tostring')" "null" \
  "and list --json reports it as null rather than omitting the key"

new_case "nick-set"
run add codex later@example.com
run nick later@example.com "GPT Personal"
check_eq "$RC" "0" "nick on an existing account exits 0"
check_eq "$(nickname_of later@example.com)" "GPT Personal" "and records the new name"
run nick later@example.com "GPT Renamed"
check_eq "$(nickname_of later@example.com)" "GPT Renamed" "a second nick replaces the first"
run nick later@example.com ""
check_eq "$RC" "0" "clearing a nickname exits 0"
check_eq "$(has_nickname_key later@example.com)" "false" \
  "and DELETES the key rather than storing an empty string"
check_contains "$OUT" "no longer has a nickname" "saying so"

new_case "nick-errors"
run add codex nickerr@example.com
run nick nosuch@example.com "Whatever"
check_eq "$RC" "4" "nick on an unregistered label exits 4"
run nick nickerr@example.com "$(printf 'has\ta tab')"
check_eq "$RC" "3" "a nickname containing a tab is refused (it would split the table row)"
check_eq "$(has_nickname_key nickerr@example.com)" "false" "and nothing was written"
run nick nickerr@example.com "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
check_eq "$RC" "3" "a nickname over 32 characters is refused"
# A bare control character — one that a terminal would act on rather than
# print. Bracket ranges are matched by LC_COLLATE, so this passes only if the
# check forces the C collation it was written for.
run nick nickerr@example.com "$(printf 'esc\033[2Jhere')"
check_eq "$RC" "3" "a nickname containing a control character is refused"
check_eq "$(has_nickname_key nickerr@example.com)" "false" "and nothing was written for it either"
# Padding is REFUSED, not trimmed. A rule the reference and the skill both
# state, and one a well-meaning trim would quietly replace: two nicknames that
# render identically are two the owner cannot tell apart in `list`.
run nick nickerr@example.com " Padded"
check_eq "$RC" "3" "a nickname with a leading space is refused rather than trimmed"
run nick nickerr@example.com "Padded "
check_eq "$RC" "3" "and one with a trailing space too"
check_eq "$(has_nickname_key nickerr@example.com)" "false" "with nothing written for either"
run nick nickerr@example.com
check_eq "$RC" "3" "nick without a name is a usage error"
run remove nickerr@example.com --nick "Nope"
check_eq "$RC" "3" "--nick is refused on an action that has no use for it"
run nick nickerr@example.com "Positional" --nick "Flag"
check_eq "$RC" "3" "giving the name both ways at once is refused rather than silently resolved"
check_eq "$(has_nickname_key nickerr@example.com)" "false" "and neither name was written"
run nick nickerr@example.com "Fine Name"
check_eq "$RC" "0" "control(+): an ordinary name on the same account still succeeds"
check_eq "$(nickname_of nickerr@example.com)" "Fine Name" "and lands in the registry"

# Two providers, one label: the same ambiguity `remove` and `relogin` refuse.
new_case "nick-ambiguous"
run add claude both@example.com
run add codex both@example.com
run nick both@example.com "Ambiguous"
check_eq "$RC" "3" "an ambiguous label is refused rather than guessed at"
check_contains "$OUT" "name the provider" "and says how to disambiguate"
run nick both@example.com "Just Codex" codex
check_eq "$RC" "0" "naming the provider resolves it"
check_eq "$(jq -r '.accounts[] | select(.provider == "codex") | .nickname // "<none>"' "$CONFIG")" \
  "Just Codex" "the codex row got the name"
check_eq "$(jq -r '.accounts[] | select(.provider == "claude") | .nickname // "<none>"' "$CONFIG")" \
  "<none>" "control(-): and the claude row of the same label did not"

# --- 16. the daily unattended snapshot job (#1700) ---------------------------
#
# Every assertion below reads the plist that was actually written and the
# launchctl calls that were actually made. The PATH assertion is the one that
# would go unnoticed in production for weeks: launchd hands a job a minimal
# PATH, and the reader needs Homebrew for `jq`, `codex`, and `node`.

new_case "schedule-unsupported"
PLATFORM_UNDER_TEST="Linux"
run schedule install
check_eq "$RC" "2" "schedule install on a non-macOS host exits 2"
check_contains "$OUT" "launchd" "saying which scheduler it needs"
check_eq "$(test -e "$(plist_path)" && echo present || echo absent)" "absent" \
  "and writes no plist"
run schedule remove
check_eq "$RC" "2" "schedule remove exits 2 there too"
run schedule status
check_eq "$RC" "2" "and schedule status"

new_case "schedule-install"
PLATFORM_UNDER_TEST="Darwin"
run schedule install
check_eq "$RC" "0" "schedule install exits 0 on macOS"
PLIST="$(plist_path)"
check_eq "$(test -f "$PLIST" && echo present || echo absent)" "present" "it writes the plist"
PLIST_BODY="$(cat "$PLIST" 2>/dev/null || true)"
check_contains "$PLIST_BODY" "<string>com.claude.ai-quotas</string>" "carrying the job label"
check_contains "$PLIST_BODY" "ai-quotas.sh" "the reader it runs"
# This case has no ~/.claude copy under its isolated HOME, so resolution falls
# through to the sibling in the checkout — which must SAY so, because a plist
# pointing into a worktree keeps working until that worktree is removed.
check_contains "$OUT" "scheduling the reader at" \
  "and says out loud when the copy it scheduled is the one in this checkout"
check_contains "$PLIST_BODY" "<string>--json</string>" "with --json"
check_contains "$PLIST_BODY" "<string>--quiet</string>" "and --quiet, which is what marks the snapshots scheduled"
check_contains "$PLIST_BODY" "<key>RunAtLoad</key>" "RunAtLoad, so installing it takes a reading immediately"
check_contains "$PLIST_BODY" "<key>StartCalendarInterval</key>" "a calendar interval"
check_contains "$PLIST_BODY" "<integer>9</integer>" "at the documented default hour"
check_contains "$PLIST_BODY" "launchd.log" "and a log path for both streams"
check_contains "$PLIST_BODY" "/opt/homebrew/bin" \
  "the PATH names Homebrew — launchd gives a job a minimal one, and jq, codex and node all live there"
check_contains "$PLIST_BODY" "<key>HOME</key>" "and HOME, which the reader resolves every path from"
# A custom registry path set in the installing shell has to reach the job too.
# `run` sets AI_QUOTAS_CONFIG for every case, so this is the ordinary path,
# not a contrivance: without it the nightly run would resolve the HOME default
# while every command the user types honoured the override.
check_contains "$PLIST_BODY" "<key>AI_QUOTAS_CONFIG</key>" \
  "a custom registry path set at install time is carried into the job"
check_contains "$PLIST_BODY" "<string>${CONFIG}</string>" "and it is the path this shell had"
# The reader takes each account's profile_dir from the registry and never
# reads AI_QUOTAS_PROFILE_ROOT, so carrying it would advertise an effect it
# does not have. Asserted because "harmless to pass" is how it gets added back.
check_eq "$(printf '%s' "$PLIST_BODY" | grep -c 'AI_QUOTAS_PROFILE_ROOT' || true)" "0" \
  "but AI_QUOTAS_PROFILE_ROOT is not, because the reader never reads it"
# Unset in this shell means absent from the plist — not written empty, which
# would override the reader's own HOME-derived default with nothing.
check_eq "$(printf '%s' "$PLIST_BODY" | grep -c 'AI_QUOTAS_HISTORY' || true)" "0" \
  "and an unset AI_QUOTAS_HISTORY is left out rather than written empty"
check_contains "$(cat "$STUB_LAUNCHCTL_LOG")" "bootstrap gui/" "the job is loaded through bootstrap"
# Naming the PATH, not just the verb. A bootstrap handed the wrong plist fails,
# the legacy `load -w` then loads the right one, and every other assertion here
# still passes — so without this the install could be bootstrapping something
# that does not exist and nothing in this suite would say so.
# Compared EXACTLY, not by substring: a path with anything appended to it
# contains the right one, so `check_contains` here would accept the very
# mistake this assertion exists to catch.
check_eq "$(grep 'launchctl bootstrap' "$STUB_LAUNCHCTL_LOG" | tail -n 1 | awk '{print $NF}')" \
  "$PLIST" "and bootstrap is handed exactly the plist that was just installed"
check_contains "$OUT" "is loaded" "and the run says so"
check_eq "$(ls -l "$PLIST" | cut -c1-10)" "-rw-r--r--" "the plist is mode 644"

# The plist must be valid property-list XML, not merely a string that contains
# the right words. Skipped rather than faked where plutil is unavailable.
if command -v plutil >/dev/null 2>&1; then
  if plutil -lint "$PLIST" >/dev/null 2>&1; then
    ok "the plist parses as a property list (plutil -lint)"
  else
    bad "the plist does not parse as a property list (plutil -lint)"
  fi
else
  ok "SKIP: plutil unavailable — plist XML validity not checked"
fi

run schedule status
check_eq "$RC" "0" "schedule status exits 0"
check_contains "$OUT" "(present)" "reporting the plist as present"
check_contains "$OUT" "loaded" "and the job as loaded"
check_contains "$OUT" "LAST SNAPSHOT: none yet" "with no snapshot recorded yet"

# A history holding only MANUAL lines must still read as "none yet": the
# footer is about the unattended job, and a hand-run /quotas is not it.
printf '%s\n' '{"ts":"2026-09-08T20:00:00Z","provider":"codex","label":"a@b.c","nickname":null,"window":"7-day","used_pct":10,"resets_at_epoch":null,"source":"manual"}' \
  > "$(history_path)"
run schedule status
check_contains "$OUT" "LAST SNAPSHOT: none yet" "control(-): manual snapshots do not count as the job having run"
# A line that PARSES but is not an object, ahead of the real one: `fromjson?`
# catches only the parse error, so a bare number reaches `.source` and would
# abort jq, taking the good line below down with it.
printf '5\n' >> "$(history_path)"
printf '%s\n' '{"ts":"2026-09-09T09:00:00Z","provider":"codex","label":"a@b.c","nickname":null,"window":"7-day","used_pct":11,"resets_at_epoch":null,"source":"scheduled"}' \
  >> "$(history_path)"
run schedule status
check_contains "$OUT" "LAST SNAPSHOT: 2026-09-09T09:00:00Z" "a scheduled snapshot is reported with its time"
# An OLDER scheduled line appended after the newer one — what a slow run
# finishing behind a quick one leaves, since a row carries the clock its run
# started on. `status` must agree with the reader's own footer about which
# reading is the latest; two commands answering that differently is worse
# than either being wrong.
printf '%s\n' '{"ts":"2026-09-07T09:00:00Z","provider":"codex","label":"a@b.c","nickname":null,"window":"7-day","used_pct":9,"resets_at_epoch":null,"source":"scheduled"}' \
  >> "$(history_path)"
run schedule status
check_contains "$OUT" "LAST SNAPSHOT: 2026-09-09T09:00:00Z" \
  "and it is the NEWEST scheduled reading, not whichever line landed last"

run schedule remove
check_eq "$RC" "0" "schedule remove exits 0"
check_eq "$(test -e "$PLIST" && echo present || echo absent)" "absent" "the plist is deleted"
check_contains "$(cat "$STUB_LAUNCHCTL_LOG")" "bootout gui/" "the job is booted out"
run schedule status
check_contains "$OUT" "(absent" "status then reports the plist as absent"
check_contains "$OUT" "not loaded" "and the job as not loaded"
check_contains "$OUT" "LAST SNAPSHOT: 2026-09-09T09:00:00Z" \
  "control(+): removing the job leaves the history it already recorded alone"

new_case "schedule-hour"
PLATFORM_UNDER_TEST="Darwin"
run schedule install --hour 3
check_eq "$RC" "0" "schedule install --hour exits 0"
check_contains "$(cat "$(plist_path)")" "<integer>3</integer>" "and writes the hour it was given"
# `09` is a reasonable thing to type and bash reads a leading zero as octal,
# where 9 is not a digit at all — so this passes only if the comparison and the
# plist value are both forced to base 10.
run schedule install --hour 09
check_eq "$RC" "0" "a zero-padded hour is accepted"
check_contains "$(cat "$(plist_path)")" "<integer>9</integer>" \
  "and reaches the plist as a plain integer, not as 09"
run schedule install --hour 24
check_eq "$RC" "3" "an out-of-range hour is a usage error"
run schedule install --hour abc
check_eq "$RC" "3" "and so is a non-numeric one"
run schedule status --hour 4
check_eq "$RC" "3" "--hour is refused on an operation that does not schedule anything"

# bootstrap is the modern spelling and legacy launchctl does not have it. When
# it is refused the job must still end up loaded through `load -w`, or every
# install on an older system silently produces a plist nothing ever runs.
new_case "schedule-bootstrap-fallback"
PLATFORM_UNDER_TEST="Darwin"
STUB_LAUNCHCTL_BOOTSTRAP_FAILS=1
run schedule install
check_eq "$RC" "0" "an install whose bootstrap is refused still exits 0"
check_contains "$(cat "$STUB_LAUNCHCTL_LOG")" "load -w" "it falls back to the legacy load"
check_contains "$OUT" "is loaded" "and the job really is loaded afterwards"

# The shape neither spelling covers: a bootout that does not take, then a
# bootstrap and a load that are both refused. launchd holds a job by LABEL, so
# what is running tonight is the definition loaded before this install — the
# old hour, the old reader — while the new plist sits on disk and `list` still
# answers "loaded". Reporting that as a plain success is the failure this
# case exists to catch, so the assertion is on what the run SAYS, not only on
# the state file.
new_case "schedule-reload-did-not-take"
PLATFORM_UNDER_TEST="Darwin"
run schedule install
check_eq "$RC" "0" "a first install to load the job exits 0"
STUB_LAUNCHCTL_BOOTOUT_FAILS=1
STUB_LAUNCHCTL_BOOTSTRAP_FAILS=1
STUB_LAUNCHCTL_LOAD_FAILS=1
run schedule install --hour 4
check_eq "$RC" "0" "a re-install whose bootout, bootstrap and load all fail still exits 0"
check_contains "$(cat "$(plist_path)")" "<integer>4</integer>" \
  "the new plist is on disk with the hour it was given"
check_contains "$OUT" "loaded before this install" \
  "but the run says the definition launchd is running is the previous one"
check_eq "$(printf '%s' "$OUT" | grep -c 'ai-quotas is loaded\.' || true)" "0" \
  "and does NOT report it as plainly loaded, which is what the old plist would look like"

# A custom history path set in the installing shell reaches the job. Driven
# directly rather than through `run`, which does not set AI_QUOTAS_HISTORY —
# the point is that a var this shell HAS is carried, and one it lacks is not.
new_case "schedule-history-override-carried"
SCHEDULE_HIST="$CASE_DIR/custom-history.jsonl"
SCHEDULE_HIST_OUT="$(HOME="$CASE_DIR/home" \
  AI_QUOTAS_CONFIG="$CONFIG" \
  AI_QUOTAS_PROFILE_ROOT="$PROFILES" \
  AI_QUOTAS_HISTORY="$SCHEDULE_HIST" \
  AI_QUOTAS_PLATFORM="Darwin" \
  AI_QUOTAS_LAUNCHCTL_BIN="$BIN/launchctl" \
  "$SCRIPT" schedule install 2>&1)" && SCHEDULE_HIST_RC=0 || SCHEDULE_HIST_RC=$?
check_eq "$SCHEDULE_HIST_RC" "0" "schedule install with a custom AI_QUOTAS_HISTORY exits 0"
check_contains "$(cat "$(plist_path)")" "<string>${SCHEDULE_HIST}</string>" \
  "and the job writes to that history file, not to the HOME default"

# A reader path that does not resolve must stop BEFORE a plist is written: a
# LaunchAgent pointing at a missing script fails silently every night.
new_case "schedule-reader-missing"
PLATFORM_UNDER_TEST="Darwin"
READER_BIN_UNDER_TEST="$CASE_DIR/no-such-reader.sh"
run schedule install
check_eq "$RC" "5" "an unresolvable reader fails the install"
check_eq "$(test -e "$(plist_path)" && echo present || echo absent)" "absent" \
  "and no plist is left behind pointing at nothing"
check_eq "$(grep -c 'bootstrap\|load' "$STUB_LAUNCHCTL_LOG" || true)" "0" \
  "control(-): nothing was loaded either"

# HOME unset is ACCEPTED by this script when both path overrides are given, and
# every schedule path derives from HOME — so without this guard the LaunchAgent
# would resolve to `/Library/LaunchAgents/…`, a machine-wide location. Driven
# through `env -u HOME` rather than `run`, which sets HOME by construction.
new_case "schedule-home-unset"
SCHEDULE_NOHOME_OUT="$(env -u HOME \
  AI_QUOTAS_CONFIG="$CONFIG" \
  AI_QUOTAS_PROFILE_ROOT="$PROFILES" \
  AI_QUOTAS_PLATFORM="Darwin" \
  AI_QUOTAS_LAUNCHCTL_BIN="$BIN/launchctl" \
  "$SCRIPT" schedule install 2>&1)" && SCHEDULE_NOHOME_RC=0 || SCHEDULE_NOHOME_RC=$?
check_eq "$SCHEDULE_NOHOME_RC" "5" "schedule install with HOME unset is refused"
check_contains "$SCHEDULE_NOHOME_OUT" "HOME is unset" "saying why"
check_eq "$(test -e /Library/LaunchAgents/com.claude.ai-quotas.plist && echo present || echo absent)" \
  "absent" "control(-): and nothing was written to the machine-wide LaunchAgents directory"

new_case "schedule-usage"
PLATFORM_UNDER_TEST="Darwin"
run schedule
check_eq "$RC" "3" "schedule with no operation is a usage error"
run schedule bogus
check_eq "$RC" "3" "and an unknown operation is too"

# --- 17. no case, anywhere, asked for a credential value ---------------------
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
