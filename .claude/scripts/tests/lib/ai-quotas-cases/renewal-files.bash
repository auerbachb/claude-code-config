#!/usr/bin/env bash
# Source-only quota fixture group: renewal-files. Run ai-quotas.test.sh.
# shellcheck source=../ai-quotas-fixtures.bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/ai-quotas-fixtures.bash"

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
if ! ARGV_LEAKS="$(argv_scan -n < "$SCRIPT")"; then ARGV_LEAKS=ARGV_SCAN_FAILED; fi
check_eq "$ARGV_LEAKS" "" \
  "no credential global is passed to jq with --arg/--argjson, which would put it in argv"

# Controls: the detector fires on EVERY spelling it claims to cover. A control
# that only exercised one form would leave the other three unasserted.

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

continued_arg=$(cat <<'CONTINUED_ARG'
jq -n --arg rt \
  "$CLAUDE_REFRESH_TOKEN" .
CONTINUED_ARG
)
continued_json=$(cat <<'CONTINUED_JSON'
jq -n --argjson at \
  "${CLAUDE_TOKEN}" .
CONTINUED_JSON
)
continued_safe=$(cat <<'CONTINUED_SAFE'
jq -n --arg ea \
  "$CLAUDE_EXPIRES_AT_MS" .
CONTINUED_SAFE
)
check_eq "$(argv_probe "$continued_arg")" "1" \
  'control(+): an LF continuation cannot hide a credential argument'
check_eq "$(argv_probe "$continued_json")" "1" \
  'control(+): a continued --argjson and braced credential are detected'
continued_crlf="$(printf '%s\n' "$continued_arg" | sed $'s/$/\r/')"
check_eq "$(argv_probe "$continued_crlf")" "1" \
  'control(+): a CRLF continuation cannot hide a credential argument'
check_eq "$(argv_probe "$continued_safe")" "0" \
  'control(-): continued non-credential metadata remains allowed'
normalizer_failure="$( (python3() { return 97; }; argv_probe "$continued_arg") )"
check_eq "$normalizer_failure" ARGV_SCAN_FAILED \
  'control(+): an unavailable normalizer cannot report a clean source scan'

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

