#!/usr/bin/env bash
# ai-quotas-export.test.sh — coverage for `ai-quotas-setup.sh export` and `import` (Issue #2468).
# catalog: tests — Tests `ai-quotas-setup.sh export` and `import` (Issue #2468): a four-provider fixture registry exported to the expected JSON at mode 600 with a grep that fails on any credential field name or token-shaped value and on any profile path, an import into an empty HOME recreating every entry with this environment's profile paths and a second import changing nothing, a conflicting existing entry reported and left untouched, a second Cursor or Antigravity account refused with the one-per-machine message, the guided login pass (signed-in accounts skipped, the exact step printed, a stubbed login run only after Enter, a ready / needs-you summary, a re-run resuming only what is still signed out), `--no-login` skipping the pass, and a non-interactive session listing the logins to do elsewhere
#
# ALL LOGINS ARE STUBS. No real claude, codex, agy, keychain, or account is touched: HOME, the
# registry, the profile root, every provider binary and the Cursor/agy sign-in stores point into
# a temp tree. The stub claude/codex write a token-SHAPED credential into the profile, so the
# credential grep is a real leak detector.
#
# Run from anywhere: bash .claude/scripts/tests/ai-quotas-export.test.sh
set -uo pipefail
unset BASH_ENV ENV

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="$ROOT/.claude/scripts/ai-quotas-setup.sh"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }
SQLITE3_REAL="$(command -v sqlite3 2>/dev/null || true)"
if [[ -z "$SQLITE3_REAL" ]]; then
  # A silent pass would leave the Cursor and Antigravity cases untested: fail where CI runs it.
  if [[ -n "${CI:-}" ]]; then echo "FAIL: sqlite3 not installed (required by this suite in CI)" >&2; exit 1; fi
  echo "SKIP: sqlite3 not installed"; exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0
FAILED=0
ok()  { PASS=$((PASS + 1)); echo "ok   — $*"; }
bad() { FAILED=$((FAILED + 1)); echo "FAIL — $*" >&2; }
check_eq() { if [[ "$1" == "$2" ]]; then ok "$3"; else bad "$3 (got '$1', want '$2')"; fi; }
check_contains() { case "$1" in *"$2"*) ok "$3" ;; *) bad "$3 (output lacked '$2')" ;; esac; }
check_not_contains() { case "$1" in *"$2"*) bad "$3 (output had '$2')" ;; *) ok "$3" ;; esac; }

# --- stubs -------------------------------------------------------------------
SECRET="FAKE-CRED-VALUE-0F1E2D"
JWT="eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJGSVhUVVJFLTI0NjgifQ.FIXTURESIGNATURE2468"
BIN="$TMP/bin"; mkdir -p "$BIN"
cat > "$BIN/claude" <<EOF
#!/usr/bin/env bash
printf 'claude\t%s\n' "\${CLAUDE_CONFIG_DIR:-<unset>}" >> "\$STUB_CALL_LOG"
mkdir -p "\$CLAUDE_CONFIG_DIR"
printf '{"claudeAiOauth":{"accessToken":"%s"}}\n' "$SECRET" > "\$CLAUDE_CONFIG_DIR/.credentials.json"
EOF
cat > "$BIN/codex" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == login && "\${2:-}" == status ]]; then exit 1; fi
printf 'codex\t%s\n' "\${CODEX_HOME:-<unset>}" >> "\$STUB_CALL_LOG"
mkdir -p "\$CODEX_HOME"
printf '{"tokens":{"access_token":"%s"}}\n' "$SECRET" > "\$CODEX_HOME/auth.json"
EOF
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/agy"
chmod +x "$BIN"/*

build_cursor_db() { # <path> <token|"">
  rm -f "$1"
  "$SQLITE3_REAL" "$1" "create table ItemTable (key TEXT PRIMARY KEY, value BLOB);" || return 1
  [[ -z "$2" ]] || "$SQLITE3_REAL" "$1" "insert into ItemTable (key, value) values ('cursorAuth/accessToken', '$2');"
}
build_cursor_db "$TMP/cursor-in.vscdb" "$JWT" || { echo "FATAL: cursor fixture" >&2; exit 1; }
build_cursor_db "$TMP/cursor-out.vscdb" "" || { echo "FATAL: cursor fixture" >&2; exit 1; }

AGY_IN="$TMP/agy-in"; AGY_OUT="$TMP/agy-none"
printf 'go-keyring-base64:%s' "$(printf '{"token":{"access_token":"%s","expiry":"2099-01-01T00:00:00Z","refresh_token":"R-sentinel"},"auth_method":"consumer","id_token_email":"agy-one@example.com"}' "$SECRET" | base64 | tr -d '\n')" > "$AGY_IN"

export STUB_CALL_LOG="$TMP/calls.log"
CURSOR_DB="$TMP/cursor-in.vscdb"
AGY_TOKEN="$AGY_IN"
INTERACTIVE=1

new_case() { # <name>
  CASE_DIR="$TMP/case-$(printf '%s' "$1" | tr -c 'A-Za-z0-9' '-')"
  rm -rf "$CASE_DIR"; mkdir -p "$CASE_DIR/home/.claude"
  CONFIG="$CASE_DIR/ai-quotas.json"; PROFILES="$CASE_DIR/profiles"
  : > "$STUB_CALL_LOG"
  CURSOR_DB="$TMP/cursor-in.vscdb"; AGY_TOKEN="$AGY_IN"; INTERACTIVE=1
}
run_in() { # <stdin-text> <args...> — sets OUT and RC
  local input="$1"; shift
  OUT="$(printf '%b' "$input" | HOME="$CASE_DIR/home" AI_QUOTAS_CONFIG="$CONFIG" AI_QUOTAS_PROFILE_ROOT="$PROFILES" \
    AI_QUOTAS_PLATFORM=Linux AI_QUOTAS_TERMINAL=off AI_QUOTAS_IMPORT_INTERACTIVE="$INTERACTIVE" \
    AI_QUOTAS_CLAUDE_BIN="$BIN/claude" AI_QUOTAS_CODEX_BIN="$BIN/codex" AI_QUOTAS_AGY_BIN="$BIN/agy" \
    AI_QUOTAS_SQLITE3_BIN="$SQLITE3_REAL" AI_QUOTAS_CURSOR_STATE_DB="$CURSOR_DB" \
    AI_QUOTAS_ANTIGRAVITY_TOKEN_FILE="$AGY_TOKEN" \
    "$SCRIPT" "$@" 2>&1)"
  RC=$?
}
run() { run_in "" "$@"; }
calls() { grep -c "^$1" "$STUB_CALL_LOG" || true; }

# The "source" environment: a registry with all four providers and real-looking credentials on disk.
SRC_PROFILES=""
seed_source() {
  new_case source
  SRC_PROFILES="$PROFILES"
  local c="$PROFILES/claude-one@example.com/claude" x="$PROFILES/codex-one@example.com/codex"
  mkdir -p "$c" "$x"
  printf '{"claudeAiOauth":{"accessToken":"%s"}}\n' "$SECRET" > "$c/.credentials.json"
  printf '{"tokens":{"access_token":"%s","refresh_token":"%s"}}\n' "$SECRET" "$JWT" > "$x/auth.json"
  jq -n --arg c "$c" --arg x "$x" '{schema_version: "1.0", source_failure_threshold: 4, accounts: [
    {provider: "claude", label: "claude-one@example.com", profile_dir: $c, added_at: "2026-09-07T16:40:00Z",
     nickname: "Claude Work", sources: ["oauth-usage", "browser"], ids: {organization_id: "org-1234", cookie: "NOT-AN-ID-FIELD"},
     plan_override: {tier: "Max 20x", usd_per_month: 200},
     credential_ref: {kind: "macos-keychain", service: "Claude Code-credentials-1a2b3c4d"}},
    {provider: "codex", label: "codex-one@example.com", profile_dir: $x, added_at: "2026-09-08T10:00:00Z", nickname: "GPT LM"},
    {provider: "cursor", label: "cursor-one@example.com", profile_dir: "/nonexistent/cursor", added_at: "2026-09-09T10:00:00Z",
     plan_override: {tier: "Pro+"}},
    {provider: "antigravity", label: "agy-one@example.com", profile_dir: "/nonexistent/agy", added_at: "2026-09-10T10:00:00Z"}]}' > "$CONFIG"
  chmod 600 "$CONFIG"
}

# --- 1. export ---------------------------------------------------------------
seed_source
EXPORT="$CASE_DIR/export.json"
run export --out "$EXPORT"
check_eq "$RC" "0" "export exits 0"
check_contains "$OUT" "keep it private" "export tells the person the file holds emails and IDs"
if mode="$(stat -f %Lp "$EXPORT" 2>/dev/null)" && [[ "$mode" =~ ^[0-7]{3,4}$ ]]; then :; else mode="$(stat -c %a "$EXPORT")"; fi
check_eq "$mode" "600" "the export is written mode 600"
expected='{"schema":"ai-quotas-accounts/1","source_failure_threshold":4,"accounts":[
 {"provider":"claude","label":"claude-one@example.com","nickname":"Claude Work","ids":{"organization_id":"org-1234"},"plan_override":{"tier":"Max 20x","usd_per_month":200},"sources":["oauth-usage","browser"],"login":{"method":"claude-cli"}},
 {"provider":"codex","label":"codex-one@example.com","nickname":"GPT LM","login":{"method":"codex-cli"}},
 {"provider":"cursor","label":"cursor-one@example.com","plan_override":{"tier":"Pro+"},"login":{"method":"cursor-ide"}},
 {"provider":"antigravity","label":"agy-one@example.com","login":{"method":"agy-cli"}}]}'
diff_out="$(diff <(jq -S 'del(.exported_at)' "$EXPORT") <(printf '%s' "$expected" | jq -S .) 2>&1)"
check_eq "$diff_out" "" "export matches the expected JSON (only whitelisted fields, ids allow-listed)"
check_eq "$(jq -r '.exported_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T")' "$EXPORT")" "true" "export carries a timestamp"

# credential grep: field names, token shapes, the fixture secrets, any profile path
leaks=""
grep -Eiq 'accessToken|access_token|refresh_token|id_token|password|cookie|secret|api_?key|credential|keychain|bearer|session|token' "$EXPORT" && leaks+="field-name "
grep -Eq 'eyJ[A-Za-z0-9_-]{8,}|sk-[A-Za-z0-9]{16,}|[A-Za-z0-9+/_=-]{40,}' "$EXPORT" && leaks+="token-shape "
grep -Fq -e "$SECRET" -e "$JWT" -e "1a2b3c4d" -e "NOT-AN-ID-FIELD" "$EXPORT" && leaks+="fixture-secret "
grep -Eq '"/|profile|/Users/|/home/|/private/|/tmp/|\.claude' "$EXPORT" && leaks+="path "
check_eq "$leaks" "" "the export holds no credential field, token-shaped value, keychain name, or profile path"
run export --out -
check_eq "$(printf '%s\n' "$OUT" | grep -v 'left out of the export' | jq -r '.schema')" "ai-quotas-accounts/1" "export --out - prints the document"

new_case empty-export
run export --out "$CASE_DIR/none.json"
check_eq "$RC" "3" "export with nothing registered exits 3"
if [[ ! -e "$CASE_DIR/none.json" ]]; then ok "no file is written when there is nothing to export"; else bad "an empty export wrote a file"; fi

# --- 2. import into an empty HOME; idempotent second import -------------------
new_case empty-home
run import "$EXPORT" --no-login
check_eq "$RC" "0" "import into an empty HOME exits 0"
check_contains "$OUT" "4 added, 0 kept, 0 conflict(s), 0 refused" "import reports four added"
check_eq "$(jq '.accounts | length' "$CONFIG")" "4" "all four entries are recreated"
check_eq "$(jq -r '.accounts[] | select(.provider=="claude") | .profile_dir' "$CONFIG")" "$PROFILES/claude-one@example.com/claude" "claude profile_dir is recomputed for THIS environment"
check_eq "$(jq -r '.accounts[] | select(.provider=="codex") | .profile_dir' "$CONFIG")" "$PROFILES/codex-one@example.com/codex" "codex profile_dir is recomputed for THIS environment"
if [[ -d "$PROFILES/claude-one@example.com/claude" ]]; then ok "the claude profile directory is created"; else bad "claude profile directory missing"; fi
check_eq "$(jq -r '[.accounts[] | .profile_dir | contains("claude-code-config") or contains("'"$SRC_PROFILES"'")] | any' "$CONFIG")" "false" "no source-environment path survives"
check_eq "$(jq -r '.accounts[] | select(.provider=="claude") | [.nickname, .plan_override.tier, .plan_override.usd_per_month, (.sources|join(",")), .ids.organization_id] | join("|")' "$CONFIG")" "Claude Work|Max 20x|200|oauth-usage,browser|org-1234" "nickname, plan, sources and IDs are restored"
check_eq "$(jq -r '.source_failure_threshold' "$CONFIG")" "4" "the source-failure threshold is restored when absent"
check_eq "$(jq -r '[.accounts[] | has("credential_ref")] | any' "$CONFIG")" "false" "import records no credential reference"
check_contains "$OUT" "--no-login: entries only" "--no-login says how to continue"
check_not_contains "$OUT" "Login pass" "--no-login skips the guided pass"
check_eq "$(calls claude)$(calls codex)" "00" "--no-login starts no login"
before="$(cat "$CONFIG")"
run import "$EXPORT" --no-login
check_eq "$RC" "0" "second import exits 0"
check_contains "$OUT" "0 added, 4 kept, 0 conflict(s), 0 refused" "second import is a no-op"
check_eq "$(cat "$CONFIG")" "$before" "second import leaves the registry byte-identical"

# --- 3. conflict ---------------------------------------------------------------
new_case conflict
jq -n --arg d "$PROFILES/claude-one@example.com/claude" '{schema_version:"1.0",accounts:[{provider:"claude",label:"claude-one@example.com",profile_dir:$d,added_at:"2026-01-01T00:00:00Z",nickname:"Mine"}]}' > "$CONFIG"
run import "$EXPORT" --no-login
check_eq "$RC" "3" "a conflict exits 3"
check_contains "$OUT" "conflict     claude 'claude-one@example.com' - differs in nickname" "the conflict is reported by field"
check_contains "$OUT" "left untouched" "the report says the entry was left untouched"
check_eq "$(jq -r '.accounts[] | select(.provider=="claude") | [.nickname, has("plan_override")] | join("|")' "$CONFIG")" "Mine|false" "the conflicting entry is not overwritten"
check_eq "$(jq '.accounts | length' "$CONFIG")" "4" "the other three accounts are still imported"

# --- 4. one per machine --------------------------------------------------------
new_case singleton
jq -n '{schema_version:"1.0",accounts:[
  {provider:"cursor",label:"other-cursor@example.com",profile_dir:"/x",added_at:"2026-01-01T00:00:00Z"},
  {provider:"antigravity",label:"other-agy@example.com",profile_dir:"/y",added_at:"2026-01-01T00:00:00Z"}]}' > "$CONFIG"
run import "$EXPORT" --no-login
check_eq "$RC" "3" "a second Cursor/Antigravity account exits 3"
check_contains "$OUT" "cursor is already registered as 'other-cursor@example.com': one Cursor IDE holds one account" "cursor is refused with the one-per-machine message"
check_contains "$OUT" "antigravity is already registered as 'other-agy@example.com': agy holds one account" "antigravity is refused with the one-per-machine message"
check_eq "$(jq '[.accounts[] | select(.provider=="cursor" or .provider=="antigravity")] | length' "$CONFIG")" "2" "neither extra account is registered"
check_eq "$(jq '.accounts | length' "$CONFIG")" "4" "claude and codex are still imported"
# two cursors inside one file
new_case two-cursors
jq '.accounts += [{provider:"cursor",label:"cursor-two@example.com",login:{method:"cursor-ide"}}]' "$EXPORT" > "$CASE_DIR/two.json"
run import "$CASE_DIR/two.json" --no-login
check_contains "$OUT" "refused      cursor 'cursor-two@example.com'" "a second cursor inside the same file is refused"

# --- 5. guided login pass ------------------------------------------------------
new_case guided
run_in "\n\n" import "$EXPORT"
check_eq "$RC" "0" "guided import exits 0"
check_contains "$OUT" "ready        cursor 'cursor-one@example.com' - already signed in, skipped" "a signed-in Cursor is skipped"
check_contains "$OUT" "ready        antigravity 'agy-one@example.com' - already signed in, skipped" "a signed-in agy is skipped"
check_contains "$OUT" "needs login  claude 'claude-one@example.com' - sign in with the Claude CLI" "the claude step is printed"
check_contains "$OUT" "CLAUDE_CONFIG_DIR=" "the exact claude command is printed"
check_contains "$OUT" "needs login  codex 'codex-one@example.com' - sign in with the Codex CLI" "the codex step is printed"
check_contains "$OUT" "Summary: 4 ready, 0 need you." "everything signed in ends ready"
check_eq "$(calls claude) $(calls codex)" "1 1" "each login ran once, after Enter"
if [[ -s "$PROFILES/claude-one@example.com/claude/.credentials.json" ]]; then ok "the stub login left its credential in the recomputed profile"; else bad "login profile empty"; fi

new_case skipped
CURSOR_DB="$TMP/cursor-out.vscdb"
run_in "s\ns\ns\n" import "$EXPORT"
check_contains "$OUT" "needs login  cursor 'cursor-one@example.com' - open the Cursor IDE and sign in" "the Cursor step is printed when the IDE is signed out"
check_contains "$OUT" "Summary: 1 ready, 3 need you." "skipped logins end in the needs-you list"
check_eq "$(calls claude) $(calls codex)" "0 0" "a skipped login is never started"
check_contains "$OUT" "- claude 'claude-one@example.com':" "the summary lists what still needs the person"
# resume: only the accounts still signed out are asked about; the signed-in ones are skipped
CURSOR_DB="$TMP/cursor-in.vscdb"
run_in "\n\n" import "$EXPORT"
check_contains "$OUT" "0 added, 4 kept" "re-running import adds nothing"
check_contains "$OUT" "Summary: 4 ready, 0 need you." "re-running import resumes and finishes the pass"
check_eq "$(calls claude) $(calls codex)" "1 1" "the resumed pass logs in only the accounts still signed out"
run_in "" import "$EXPORT"
check_contains "$OUT" "Summary: 4 ready" "a third run finds everything ready"
check_eq "$(calls claude) $(calls codex)" "1 1" "a fully signed-in re-run starts no login"

new_case noninteractive
INTERACTIVE=0
CURSOR_DB="$TMP/cursor-out.vscdb"; AGY_TOKEN="$AGY_OUT"
run import "$EXPORT"
check_eq "$RC" "0" "a non-interactive import exits 0"
check_contains "$OUT" "Summary: 0 ready, 4 need you." "nothing is signed in on this fixture"
check_contains "$OUT" "This session cannot take a login" "the session says the logins must happen elsewhere"
check_contains "$OUT" "- antigravity 'agy-one@example.com': run agy" "each login to do elsewhere is listed with its step"
check_eq "$(jq '.accounts | length' "$CONFIG")" "4" "entries are still created without a terminal"
check_eq "$(calls claude) $(calls codex)" "0 0" "no login is started without a terminal"

# --- 6. validation -------------------------------------------------------------
new_case invalid
printf '{"schema":"something-else/1","accounts":[]}' > "$CASE_DIR/bad.json"
run import "$CASE_DIR/bad.json"
check_eq "$RC" "3" "a file with the wrong schema is refused"
if [[ ! -e "$CONFIG" ]]; then ok "a refused file creates no registry"; else bad "registry created by a refused file"; fi
jq '.accounts[0].label = "../evil" | .accounts[1].plan_override.tier = "x\u0001y"' "$EXPORT" > "$CASE_DIR/bad2.json"
run import "$CASE_DIR/bad2.json"
check_eq "$RC" "3" "an invalid label or plan is refused"
check_contains "$OUT" "invalid label" "the invalid label is named"
jq '.accounts[0].sources = ["http"] | .accounts[1].ids = {team_id: "t-1"}' "$EXPORT" > "$CASE_DIR/bad3.json"
run import "$CASE_DIR/bad3.json"
check_contains "$OUT" "invalid sources for claude" "a source the provider does not support is refused"
check_contains "$OUT" "invalid ids" "an ID key export would drop is refused"
jq '.accounts[0].plan_override.access_token = "x"' "$EXPORT" > "$CASE_DIR/bad5.json"
run import "$CASE_DIR/bad5.json"
check_contains "$OUT" "invalid plan_override" "a plan override with an extra member is refused, so nothing credential-shaped is copied in"
jq '.source_failure_threshold = 0' "$EXPORT" > "$CASE_DIR/bad6.json"
run import "$CASE_DIR/bad6.json"
check_contains "$OUT" "invalid source_failure_threshold" "an unusable threshold refuses the whole file"
if [[ ! -e "$CONFIG" ]]; then ok "no account is written for a file with a bad threshold"; else bad "a bad threshold still wrote accounts"; fi
jq '.accounts[0].sources = ["browser","browser"]' "$EXPORT" > "$CASE_DIR/bad4.json"
run import "$CASE_DIR/bad4.json"
check_contains "$OUT" "invalid sources for claude" "a repeated source is refused"
run import "$CASE_DIR/missing.json"
check_eq "$RC" "3" "a missing file exits 3"
run export --out
check_eq "$RC" "3" "--out without a path is a usage error"
run list --out x
check_eq "$RC" "3" "--out on another action is a usage error"

# --- 7. review-round hardening (#2476) -----------------------------------------
cp "$EXPORT" "$TMP/export-keep.json"; EXPORT="$TMP/export-keep.json"
# export --out can never replace the live registry (by path, symlink or hard link)
seed_source
BEFORE="$(cat "$CONFIG")"
run export --out "$CONFIG"
check_eq "$RC" "3" "export --out naming the live registry is refused"
check_contains "$OUT" "live account registry" "the refusal names the registry"
ln -s "$CONFIG" "$CASE_DIR/link.json"
run export --out "$CASE_DIR/link.json"
check_eq "$RC" "3" "export --out through a symlink to the registry is refused"
check_eq "$(cat "$CONFIG")" "$BEFORE" "the registry is untouched by the refused exports"

# a token-shaped provider ID is dropped on export (with a warning) and refused on import
TOKID="sk-ant-api03-FIXTUREFIXTUREFIXTURE"
jq --arg t "$TOKID" '.accounts[0].ids = {organization_id: "org-1234", account_id: $t, user_id: "eyJhbGciOiJIUzI1NiJ9.abc.def"}' "$CONFIG" > "$CASE_DIR/c.json" && mv "$CASE_DIR/c.json" "$CONFIG"
run export --out "$CASE_DIR/leak.json"
check_eq "$RC" "0" "export with credential-shaped IDs still succeeds"
check_contains "$OUT" "2 provider ID value(s) were left out" "dropped IDs are reported"
if grep -q -e "sk-ant" -e "eyJ" "$CASE_DIR/leak.json"; then bad "a token-shaped ID leaked into the export"; else ok "no token-shaped ID is in the export"; fi
check_eq "$(jq -c '.accounts[0].ids' "$CASE_DIR/leak.json")" '{"organization_id":"org-1234"}' "the legitimate ID survives"
new_case leak-import
jq --arg t "$TOKID" '.accounts[0].ids.account_id = $t' "$EXPORT" > "$CASE_DIR/leak2.json"
run import "$CASE_DIR/leak2.json" --no-login
check_eq "$RC" "3" "an import carrying a token-shaped ID is refused"
check_contains "$OUT" "invalid ids" "the refusal names the invalid ids, not a missing file"

# the schema string must match exactly; nicknames are limited in bytes; prices to 2 decimals
new_case strict-validation
jq '.schema = "ai-quotas-accounts/1/2"' "$EXPORT" > "$CASE_DIR/s.json"
run import "$CASE_DIR/s.json" --no-login
check_eq "$RC" "3" "a schema with a suffix is refused"
jq '.accounts[0].nickname = "ééééééééééééééééé"' "$EXPORT" > "$CASE_DIR/n.json"
run import "$CASE_DIR/n.json" --no-login
check_contains "$OUT" "invalid nickname" "17 two-byte characters exceed the 32-byte nickname limit"
jq '.accounts[0].nickname = "éééééééééééééééé"' "$EXPORT" > "$CASE_DIR/n2.json"
run import "$CASE_DIR/n2.json" --no-login
check_eq "$RC" "0" "16 two-byte characters (32 bytes) are accepted"
new_case price
jq '.accounts[0].plan_override.usd_per_month = 19.999' "$EXPORT" > "$CASE_DIR/p.json"
run import "$CASE_DIR/p.json" --no-login
check_contains "$OUT" "invalid plan_override" "a three-decimal price is refused like the plan action"
jq '.accounts[0].plan_override.usd_per_month = 19.99' "$EXPORT" > "$CASE_DIR/p2.json"
run import "$CASE_DIR/p2.json" --no-login
check_eq "$RC" "0" "a two-decimal price is accepted"

# the login pass must not call another account's sign-in "ready"
new_case identity
AGY_OTHER="$TMP/agy-other"
printf 'go-keyring-base64:%s' "$(printf '{"token":{"access_token":"%s","expiry":"2099-01-01T00:00:00Z","refresh_token":"R-sentinel"},"auth_method":"consumer","id_token_email":"someone-else@example.com"}' "$SECRET" | base64 | tr -d '\n')" > "$AGY_OTHER"
AGY_TOKEN="$AGY_OTHER"
INTERACTIVE=0
run import "$EXPORT"
check_contains "$OUT" "needs you    antigravity 'agy-one@example.com' - agy is signed in as someone-else@example.com" "a different agy account is needs-you, not ready"
check_contains "$OUT" "cannot read which account the Cursor IDE holds" "Cursor's unconfirmed identity is said plainly"
AGY_TOKEN="$AGY_IN"
INTERACTIVE=1

echo
echo "passed: $PASS  failed: $FAILED"
[[ $FAILED -eq 0 ]]
