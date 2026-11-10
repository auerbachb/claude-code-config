#!/usr/bin/env bash
# Source-only quota fixture group: renewal. Run ai-quotas.test.sh.
# shellcheck source=../ai-quotas-fixtures.bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/ai-quotas-fixtures.bash"

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

