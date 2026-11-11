#!/usr/bin/env bash
# Sourced by ai-quotas.sh. Claude usage requests and credential renewal.

# The token is borrowed into a variable and used for exactly one request. It
# is never echoed, never written to a log, and never passed on a command line
# — `curl` reads the Authorization header from a config on stdin, so it never
# reaches `ps`.
CLAUDE_TOKEN=""
CLAUDE_TOKEN_DETAIL=""

# The renewal material that comes out of the SAME credential store as the
# access token (#1716). All of it stays in these globals: nothing here is ever
# printed, logged, or put in an argv.
#
#   CLAUDE_REFRESH_TOKEN   the refresh token, when the store carries one
#   CLAUDE_EXPIRES_AT_MS   the stored expiry, in MILLISECONDS since the epoch
#   CLAUDE_SCOPES          the stored scopes, space-joined, for the refresh body
#   CLAUDE_CRED_RAW        the whole stored document, so a write-back can
#                          preserve every field this reader does not know about
#   CLAUDE_CRED_KIND       "keychain" | "file" | "bare" — where it came from,
#                          which is also what a write-back has to write to
#   CLAUDE_CRED_SERVICE    the keychain service, when kind is "keychain"
#   CLAUDE_CRED_ACCOUNT    that item's `acct` attribute, so `-U` updates the
#                          existing item instead of creating a second one
#   CLAUDE_CRED_FILE       the credentials path, when kind is "file"
CLAUDE_REFRESH_TOKEN=""
CLAUDE_EXPIRES_AT_MS=""
CLAUDE_SCOPES=""
CLAUDE_CRED_RAW=""
CLAUDE_CRED_KIND=""
CLAUDE_CRED_SERVICE=""
CLAUDE_CRED_ACCOUNT=""
CLAUDE_CRED_FILE=""

# Clearing is its own function because it is called from three places — after
# the usage request, after a write-back, and on every early return — and a
# renewal path that forgot one of them would leave a refresh token live in the
# environment of every later account's `codex`/`curl` child.
claude_forget_credentials() {
  CLAUDE_TOKEN=""
  CLAUDE_REFRESH_TOKEN=""
  CLAUDE_CRED_RAW=""
  CLAUDE_CRED_PRIOR_ACCESS=""
}

# Both results come back in globals rather than on stdout, so no caller can
# put a credential into a command substitution by accident.
claude_token_for() { # <profile_dir> <keychain_service|"">
  local dir="$1" service="$2" raw="" attrs=""
  CLAUDE_TOKEN=""
  CLAUDE_TOKEN_DETAIL=""
  CLAUDE_REFRESH_TOKEN=""
  CLAUDE_EXPIRES_AT_MS=""
  CLAUDE_SCOPES=""
  CLAUDE_CRED_RAW=""
  CLAUDE_CRED_PRIOR_ACCESS=""
  CLAUDE_CRED_KIND=""
  CLAUDE_CRED_SERVICE=""
  CLAUDE_CRED_ACCOUNT=""
  CLAUDE_CRED_FILE=""

  if [[ -s "$dir/.credentials.json" ]]; then
    raw="$(cat "$dir/.credentials.json" 2>/dev/null || true)"
    CLAUDE_CRED_KIND="file"
    CLAUDE_CRED_FILE="$dir/.credentials.json"
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
    CLAUDE_CRED_KIND="keychain"
    CLAUDE_CRED_SERVICE="$service"
    # The `acct` attribute, read WITHOUT `-w` so no value is involved. An
    # update that omitted it would land a second item with an empty account
    # beside the one Claude Code reads, and the two would drift apart.
    attrs="$("$SECURITY_BIN" find-generic-password -s "$service" 2>/dev/null || true)"
    CLAUDE_CRED_ACCOUNT="$(printf '%s\n' "$attrs" \
      | sed -n 's/^[[:space:]]*"acct"<blob>="\(.*\)"$/\1/p' | head -n 1)"
  else
    CLAUDE_TOKEN_DETAIL="no .credentials.json in profile"
    return 1
  fi

  case "$raw" in
    '{'*)
      CLAUDE_CRED_RAW="$raw"
      CLAUDE_TOKEN="$(printf '%s' "$raw" | jq -r '.claudeAiOauth.accessToken // .accessToken // empty' 2>/dev/null || true)"
      CLAUDE_REFRESH_TOKEN="$(printf '%s' "$raw" | jq -r '.claudeAiOauth.refreshToken // .refreshToken // empty' 2>/dev/null || true)"
      # Only a NUMBER is accepted as the expiry. A store that moved the field
      # to a string date would otherwise be compared as a string and read as
      # "not expired" forever — the silent-success shape this whole change
      # exists to remove.
      CLAUDE_EXPIRES_AT_MS="$(printf '%s' "$raw" \
        | jq -r '(.claudeAiOauth.expiresAt // .expiresAt) as $e
                 | if ($e | type) == "number" then ($e | floor | tostring) else "" end' 2>/dev/null || true)"
      CLAUDE_SCOPES="$(printf '%s' "$raw" \
        | jq -r '(.claudeAiOauth.scopes // .scopes) as $s
                 | if ($s | type) == "array"
                   then ([$s[] | select(type == "string")] | join(" "))
                   else "" end' 2>/dev/null || true)"
      ;;
    *)
      # A bare string is the credential itself on installs that store it
      # unwrapped. Nothing is inspected beyond "is it non-empty".
      CLAUDE_TOKEN="$raw"
      CLAUDE_CRED_KIND="bare"
      ;;
  esac

  if [[ -z "$CLAUDE_TOKEN" ]]; then
    # A document carrying a refreshToken but no accessToken has already put
    # the refresh material in these globals, and this path spends it on
    # nothing: the caller emits needs-login without a single request. So it is
    # dropped HERE rather than left live until the next Claude account calls
    # this function or the shell exits. `claude_forget_credentials` does not
    # touch CLAUDE_TOKEN_DETAIL, so the reason below still reaches the row.
    claude_forget_credentials
    CLAUDE_TOKEN_DETAIL="credential store holds no OAuth access token"
    return 1
  fi
  # The baseline the write-back compares against. Captured HERE, from the read
  # that actually happened, rather than snapshotted later next to the write —
  # a baseline taken after the operation compares a value to itself.
  CLAUDE_CRED_PRIOR_ACCESS="$CLAUDE_TOKEN"
  return 0
}

# --- claude token renewal (#1716) --------------------------------------------
#
# Claude Code renews this same token on every launch, from the same item. A
# reader that only ever READ it went dark within hours of a login on any
# profile nobody opened Claude Code in — which is every side profile this
# tracker exists to watch. So the reader renews it too, and writes the renewed
# pair back into the item Claude Code reads, so the two stay in step rather
# than each holding half a rotated credential.
#
# Endpoint, client id, and request shape were read out of the installed Claude
# Code bundle rather than guessed — see `.claude/reference/ai-quotas.md`
# §"Renewing an expired access token" for the observation and its date.
CLAUDE_TOKEN_URL="${AI_QUOTAS_CLAUDE_TOKEN_URL:-https://platform.claude.com/v1/oauth/token}"
CLAUDE_OAUTH_CLIENT_ID="${AI_QUOTAS_CLAUDE_CLIENT_ID:-9d1c250a-e61b-44d9-88ed-5944d1962f5e}"
# Renew this far before the stored expiry. A token that dies mid-request is
# indistinguishable from a rejected one, and the retry that would have covered
# it costs a whole extra round trip.
CLAUDE_REFRESH_MARGIN_MS=60000

CLAUDE_REFRESH_DETAIL=""

# Is the stored token expired (or about to be)? Unknown expiry is NOT treated
# as expired: a store that never carried the field would otherwise burn a
# refresh on every single read.
claude_token_expired() {
  [[ -n "$CLAUDE_EXPIRES_AT_MS" ]] || return 1
  local now_ms
  now_ms=$(( NOW * 1000 ))
  [[ "$CLAUDE_EXPIRES_AT_MS" -le $(( now_ms + CLAUDE_REFRESH_MARGIN_MS )) ]]
}

# What the store held when this run read it. The write-back compares against
# it and stands down if it changed, so a renewal that raced another writer
# never clobbers the winner (see claude_write_back).
CLAUDE_CRED_PRIOR_ACCESS=""

# Read the access token currently in the store, without disturbing any global.
# Used only for the compare-and-set below.
#
# Returns non-zero when the store could not be read OR held no token — the
# caller MUST distinguish that from "read fine, and it changed". Printing an
# empty string and exiting 0 would make an unreadable store compare unequal to
# everything and so read as "somebody else won the race", which is the quiet
# kind of wrong: no write, no race, and nothing reported.
claude_stored_access_token() {
  local raw="" tok=""
  case "$CLAUDE_CRED_KIND" in
    keychain)
      [[ -n "$CLAUDE_CRED_SERVICE" ]] || return 1
      raw="$("$SECURITY_BIN" find-generic-password -s "$CLAUDE_CRED_SERVICE" -w 2>/dev/null || true)" ;;
    file)
      [[ -n "$CLAUDE_CRED_FILE" ]] || return 1
      raw="$(cat "$CLAUDE_CRED_FILE" 2>/dev/null || true)" ;;
    *) return 1 ;;
  esac
  [[ -n "$raw" ]] || return 1
  tok="$(printf '%s' "$raw" | jq -r '.claudeAiOauth.accessToken // .accessToken // empty' 2>/dev/null || true)"
  [[ -n "$tok" ]] || return 1
  printf '%s' "$tok"
}

# Re-read the store and adopt what is there, but ONLY if it is a different
# access token than this run started from.
#
#   0  adopted — somebody else renewed; CLAUDE_TOKEN is now THEIR access token
#   1  nothing new — the store still holds what we started with
#
# This is the other half of the rotation problem the compare-and-set covers.
# Refresh tokens rotate, so when Claude Code (or a concurrent /quotas) renews
# first, the refresh token THIS run is holding is invalidated **by that
# rotation** — and the token endpoint answers `invalid_grant`. Taken at face
# value that is a dead login, and the row would say `needs-login` about an
# account whose credential is sitting in the store, freshly renewed, perfectly
# good. That false `needs-login` is the exact failure this whole change exists
# to remove, so it is checked for before the rejection is believed.
claude_adopt_stored_credential() {
  local raw="" candidate=""
  case "$CLAUDE_CRED_KIND" in
    keychain)
      [[ -n "$CLAUDE_CRED_SERVICE" ]] || return 1
      raw="$("$SECURITY_BIN" find-generic-password -s "$CLAUDE_CRED_SERVICE" -w 2>/dev/null || true)" ;;
    file)
      [[ -n "$CLAUDE_CRED_FILE" ]] || return 1
      raw="$(cat "$CLAUDE_CRED_FILE" 2>/dev/null || true)" ;;
    *) return 1 ;;
  esac
  case "$raw" in '{'*) : ;; *) return 1 ;; esac

  candidate="$(printf '%s' "$raw" | jq -r '.claudeAiOauth.accessToken // .accessToken // empty' 2>/dev/null || true)"
  # Empty, or the same token we already tried, is not somebody else's renewal.
  # Accepting the same token here would turn one rejection into a claim that
  # everything is fine, on a credential the endpoint just refused.
  [[ -n "$candidate" ]] || return 1
  [[ "$candidate" != "$CLAUDE_CRED_PRIOR_ACCESS" ]] || return 1

  CLAUDE_CRED_RAW="$raw"
  CLAUDE_TOKEN="$candidate"
  CLAUDE_CRED_PRIOR_ACCESS="$candidate"
  CLAUDE_REFRESH_TOKEN="$(printf '%s' "$raw" | jq -r '.claudeAiOauth.refreshToken // .refreshToken // empty' 2>/dev/null || true)"
  CLAUDE_EXPIRES_AT_MS="$(printf '%s' "$raw" \
    | jq -r '(.claudeAiOauth.expiresAt // .expiresAt) as $e
             | if ($e | type) == "number" then ($e | floor | tostring) else "" end' 2>/dev/null || true)"
  return 0
}

# Write the renewed credential back where it came from, preserving every other
# field the store carried.
#
#   0  written
#   1  failed — the caller discloses it beside an otherwise-good row, never as
#      a lost read: the renewed token in memory is still good for THIS run
#   2  superseded — somebody else renewed while we were talking to the token
#      endpoint, and THEIR result is the newer one
#
# **Compare-and-set, not a blind write.** Claude Code renews this same item, and
# so does a concurrent `/quotas` (the daily job overlapping a manual run).
# Refresh tokens ROTATE, so a blind last-writer-wins store can leave the item
# holding a token the server already invalidated — and the next run reads
# `needs-login` on a login that was never actually lost. Re-reading the store
# immediately before the write and standing down when it no longer holds the
# token we started from keeps the winner's credential. The window is not zero —
# nothing here can make a Keychain write atomic against another process — but
# it is the width of one `security` call instead of the width of a network
# round trip. Same shape as the park-retirement writes in #1596.
#
# <merged-json> arrives on stdin, never in an argument: an argv carrying the
# document would put both tokens in `ps`.
claude_write_back() { # reads the merged document on stdin
  local merged tmp rc=0 current
  merged="$(cat)"
  [[ -n "$merged" ]] || return 1

  # An empty prior token means we never established a baseline, and a
  # comparison against nothing would authorise every write — the post-hoc
  # baseline that self-certifies. Refuse instead.
  [[ -n "$CLAUDE_CRED_PRIOR_ACCESS" ]] || return 1
  # A store we cannot read is a FAILURE to disclose, not a race to shrug off.
  # Folding the two together would let a vanished keychain item, a revoked
  # permission, or a truncated file report as "somebody else renewed" — a
  # silent no-op with a reassuring explanation.
  if ! current="$(claude_stored_access_token)"; then
    return 1
  fi
  if [[ "$current" != "$CLAUDE_CRED_PRIOR_ACCESS" ]]; then
    return 2
  fi

  case "$CLAUDE_CRED_KIND" in
    keychain)
      [[ -n "$CLAUDE_CRED_SERVICE" ]] || return 1
      # No account, no write. `-a ""` does not update the existing item — it
      # creates a SECOND one beside the one Claude Code reads, and the two
      # then drift apart holding different halves of a rotated credential.
      # An unparseable attribute dump is a reason to refuse the write and say
      # so, never to guess at the item's identity.
      [[ -n "$CLAUDE_CRED_ACCOUNT" ]] || return 1
      # `-w` LAST and valueless makes security(1) read the value from stdin,
      # which it asks for TWICE (measured 2026-09-14: "password data for new
      # item:" then "retype password for new item:"). Both prompts go to
      # stderr and are discarded. Nothing about the value is in the argv.
      #
      # No keychain is named: a trailing keychain argument would be eaten by
      # `-w` as the password itself (measured — it writes the PATH as the
      # secret). The default search list is where Claude Code keeps this item.
      printf '%s\n%s\n' "$merged" "$merged" \
        | "$SECURITY_BIN" add-generic-password -U \
            -a "$CLAUDE_CRED_ACCOUNT" -s "$CLAUDE_CRED_SERVICE" -w \
            >/dev/null 2>&1 || rc=$?
      [[ "$rc" -eq 0 ]] || return 1
      ;;
    file)
      [[ -n "$CLAUDE_CRED_FILE" ]] || return 1
      # Same directory, so the rename is atomic on the same filesystem — a
      # reader that opened the file mid-write gets the old document or the new
      # one, never a truncated one. 600 BEFORE any content lands in it.
      tmp="$(mktemp "${CLAUDE_CRED_FILE}.XXXXXX" 2>/dev/null)" || return 1
      chmod 600 "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
      printf '%s\n' "$merged" > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
      mv -f "$tmp" "$CLAUDE_CRED_FILE" 2>/dev/null || { rm -f "$tmp"; return 1; }
      ;;
    *)
      # A bare-string store has nowhere to put an expiry or a refresh token,
      # so there is nothing to write back to. Reached only if such a store
      # somehow yielded a refresh token, which it cannot.
      return 1
      ;;
  esac
  return 0
}

# Renew CLAUDE_TOKEN from CLAUDE_REFRESH_TOKEN.
#
#   0  renewed — CLAUDE_TOKEN is the new access token
#   1  rejected — the grant is dead; the caller says needs-login
#   2  unreachable — the endpoint could not be asked; the caller says so
#   3  rate-limited — the endpoint asked us to come back later
#
# CLAUDE_REFRESH_DETAIL carries the reason. It is built from a STATUS CODE and
# an error CODE, never from a response body verbatim: an endpoint that echoed
# the submitted token back in an error message would otherwise print it.
claude_refresh_access_token() {
  local bodyf="$TMP/claude-refresh-body.json"
  local reqf="$TMP/claude-refresh-req.json"
  local hdrs="$TMP/claude-refresh-hdrs.txt"
  local code rc=0 access refresh expires_in merged err retry wb=0
  CLAUDE_REFRESH_DETAIL=""
  OUTCOME_STATUS=""

  if [[ -z "$CLAUDE_REFRESH_TOKEN" ]]; then
    set_outcome logged_out credential-store credential_unavailable
    CLAUDE_REFRESH_DETAIL="the stored credential carries no refresh token"
    return 1
  fi

  # The request body is built by jq (so every value is correctly escaped) into
  # a file inside this run's 0700 temp dir, at 0600, and curl is pointed at the
  # PATH — so the token is on neither this argv nor curl's.
  #
  # The token reaches jq through the ENVIRONMENT, not `--arg`. `--arg` is an
  # argument like any other: it puts the value in jq's command line, where
  # `ps` shows it to every process on the machine. A per-command environment
  # entry is readable only by this user. Same reason curl gets `-K -`.
  ( umask 077
    AIQ_RT="$CLAUDE_REFRESH_TOKEN" \
    jq -n --arg cid "$CLAUDE_OAUTH_CLIENT_ID" \
          --arg sc "$CLAUDE_SCOPES" \
      '{grant_type: "refresh_token", refresh_token: $ENV.AIQ_RT, client_id: $cid}
       + (if $sc == "" then {} else {scope: $sc} end)' > "$reqf" 2>/dev/null )
  if [[ ! -s "$reqf" ]]; then
    rm -f "$reqf"
    CLAUDE_REFRESH_DETAIL="could not build the refresh request"
    return 2
  fi

  : > "$bodyf"; : > "$hdrs"
  code="$("$CURL_BIN" -sS --max-time "$HTTP_TIMEOUT" \
      -o "$bodyf" -D "$hdrs" -w '%{http_code}' \
      -X POST \
      -H "Content-Type: application/json" \
      -H "User-Agent: claude-code/${CLAUDE_VERSION}" \
      -H "Accept: application/json" \
      --data-binary "@$reqf" \
      "$CLAUDE_TOKEN_URL" 2>/dev/null)" || rc=$?
  rm -f "$reqf"

  if [[ "$rc" -ne 0 || -z "$code" ]]; then
    rm -f "$bodyf" "$hdrs"
    transport_outcome "$rc" oauth-refresh
    CLAUDE_REFRESH_DETAIL="could not reach the token endpoint (curl exit ${rc:-?})"
    return 2
  fi

  if [[ "$code" != "200" ]]; then
    # The error CODE only — a short token from a fixed vocabulary, so naming
    # it is safe; the human-readable `message` beside it is never echoed.
    #
    # BOTH envelopes are read. RFC 6749 §5.2 puts a bare string in `error`;
    # Anthropic nests it as `{"error":{"type":…,"message":…}}` (observed
    # 2026-09-14 on a live 429). Reading only the flat shape would classify a
    # genuinely dead grant delivered in the nested one as `unreachable`, and
    # the owner would never be told to log in again.
    err="$(jq -r '(.error // empty) as $e
                  | if ($e | type) == "string" then $e
                    elif ($e | type) == "object" and (($e.type // "") | type) == "string" then $e.type
                    else "" end' "$bodyf" 2>/dev/null || true)"
    retry="$(grep -i '^retry-after:' "$hdrs" 2>/dev/null | head -n 1 | sed 's/^[^:]*:[[:space:]]*//' | tr -d '\r' || true)"
    rm -f "$bodyf" "$hdrs"
    case "$err" in
      invalid_grant|invalid_client|unauthorized_client)
        # Before believing the grant is dead: somebody else may have renewed
        # it while we were in flight, which rotates — and so invalidates — the
        # refresh token we just spent. Their credential is good; adopt it.
        claude_adopt_stored_credential && return 0
        CLAUDE_REFRESH_DETAIL="the stored refresh token was rejected (${err})"
        return 1 ;;
    esac

    # A 429 is the endpoint asking us to come back, not a broken credential
    # and not an unreachable host. The reader already has a status that says
    # exactly that, and using it keeps the daily history honest — a week of
    # `unreachable` would read as an outage that never happened.
    # Observed 2026-09-14: `{"error":{"type":"rate_limit_error"}}` via
    # Cloudflare, with no Retry-After header.
    if [[ "$code" == "429" ]]; then
      CLAUDE_REFRESH_DETAIL="the token endpoint is rate-limiting renewals"
      # Retry-After is delta-seconds or an HTTP-date (RFC 9110 §10.2.3);
      # appending "s" to a date would produce a duration that is neither.
      if [[ "$retry" =~ ^[0-9]+$ ]]; then
        CLAUDE_REFRESH_DETAIL="$CLAUDE_REFRESH_DETAIL, retry after ${retry}s"
      elif [[ -n "$retry" ]]; then
        CLAUDE_REFRESH_DETAIL="$CLAUDE_REFRESH_DETAIL, retry after ${retry}"
      fi
      return 3
    fi
    # 401 is the token endpoint refusing the CLIENT — the grant is finished,
    # and a relogin is the fix. A bare 400 or 403 carrying no OAuth error code
    # is NOT: 403 in particular is what an edge proxy answers, and telling the
    # owner to log in again over a WAF block is the misdiagnosis this whole
    # status split exists to prevent. Those stay `unreachable`, with the
    # status they answered.
    if [[ "$code" == "401" ]]; then
      claude_adopt_stored_credential && return 0
      CLAUDE_REFRESH_DETAIL="the stored refresh token was rejected (HTTP 401)"
      return 1
    fi
    set_outcome unreadable oauth-refresh "http_${code}"
    CLAUDE_REFRESH_DETAIL="the token endpoint answered HTTP ${code}"
    return 2
  fi

  if ! jq -e 'true' "$bodyf" >/dev/null 2>&1; then
    set_outcome parse_error oauth-refresh invalid_json
    CLAUDE_REFRESH_DETAIL="the token endpoint answered HTTP 200 with a body that is not JSON"
    rm -f "$bodyf" "$hdrs"
    return 2
  fi

  access="$(jq -r 'if (.access_token | type) == "string" then .access_token else "" end' "$bodyf" 2>/dev/null || true)"
  refresh="$(jq -r 'if (.refresh_token | type) == "string" then .refresh_token else "" end' "$bodyf" 2>/dev/null || true)"
  expires_in="$(jq -r 'if (.expires_in | type) == "number" then (.expires_in | floor | tostring) else "" end' "$bodyf" 2>/dev/null || true)"
  rm -f "$bodyf" "$hdrs"

  if [[ -z "$access" ]]; then
    # HTTP 200 with no token in it is a CHANGED SHAPE, not a dead grant. Saying
    # needs-login here would send the owner through an interactive login that
    # could not fix it.
    set_outcome parse_error oauth-refresh response_shape
    CLAUDE_REFRESH_DETAIL="the token endpoint answered HTTP 200 with no access token in it"
    return 2
  fi

  CLAUDE_TOKEN="$access"
  # Claude Code keeps the old refresh token when the response omits a new one.
  [[ -n "$refresh" ]] && CLAUDE_REFRESH_TOKEN="$refresh"
  if [[ -n "$expires_in" ]]; then
    CLAUDE_EXPIRES_AT_MS=$(( NOW * 1000 + expires_in * 1000 ))
  else
    CLAUDE_EXPIRES_AT_MS=""
  fi

  # Merge into the stored document rather than replacing it: `scopes`,
  # `subscriptionType`, `rateLimitTier`, and anything a later Claude Code adds
  # belong to Claude Code, and a write that dropped them would break the very
  # client this is keeping in step.
  if [[ -n "$CLAUDE_CRED_RAW" ]]; then
    # Both tokens go in through the ENVIRONMENT, never `--arg` — see the
    # request-body comment above: `--arg` is argv, and argv is world-readable.
    merged="$(printf '%s' "$CLAUDE_CRED_RAW" \
      | AIQ_AT="$CLAUDE_TOKEN" AIQ_RT="$CLAUDE_REFRESH_TOKEN" \
        jq -c --arg ea "$CLAUDE_EXPIRES_AT_MS" \
        'def put($o): $o
           | .accessToken = $ENV.AIQ_AT
           | .refreshToken = $ENV.AIQ_RT
           # An unknown new expiry DELETES the stored one rather than leaving
           # the old value in place. Keeping it would leave a PAST timestamp
           # beside a token that was just renewed, and every later run would
           # read that as "expired" and spend another refresh — for ever. With
           # the field absent the proactive check stands down and the 401 path
           # still covers the token, which is the honest state: unknown.
           | (if $ea == "" then del(.expiresAt) else .expiresAt = ($ea | tonumber) end);
         if has("claudeAiOauth") then .claudeAiOauth = put(.claudeAiOauth)
         else put(.) end' 2>/dev/null || true)"
    if [[ -n "$merged" ]]; then
      wb=0
      printf '%s' "$merged" | claude_write_back || wb=$?
      case "$wb" in
        0) : ;;
        2)
          # Somebody else renewed while we were at the token endpoint. Theirs
          # is the newer credential and it stays; ours is still fine for this
          # one read. Nothing was lost, so nothing is disclosed.
          : ;;
        *)
          # The renewed token still works for THIS read. Saying so beside an
          # otherwise-good row is honest; failing the row would be a lie about
          # the quota figure, which was fetched fine.
          # Not a cosmetic note. The rotation already happened SERVER-side, so
          # the refresh token still sitting in the store is invalidated and
          # cannot renew anything again. This read is fine; the next one, and
          # Claude Code's next launch, will need an interactive login. Saying
          # "Claude Code will renew its own copy" would be false comfort.
          CLAUDE_REFRESH_DETAIL="renewed for this read, but it could not be written back — the stored refresh token is now stale, so the next read and Claude Code's next launch will need a re-login"
          ;;
      esac
      merged=""
    else
      CLAUDE_REFRESH_DETAIL="renewed, but the stored credential could not be rebuilt for write-back"
    fi
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
  for candidate in "${_HOME}/.local/bin/claude" "${_HOME}/.claude/local/claude" "/opt/homebrew/bin/claude" "/usr/local/bin/claude"; do
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

# <span-seconds> is the window's LENGTH, which the payload does not report:
# Anthropic names the window in the key (`seven_day`, `five_hour`) and gives
# only its end. Passed by the caller that chose the key rather than derived
# from the label here, so a new window arrives as one call site with its own
# length instead of a string this function has to recognise.
claude_window_row() { # <label> <email> <body-file> <json-key> <window-label> <span-seconds>
  local label="$1" email="$2" body="$3" key="$4" window="$5" span="${6:-}"
  local util resets_raw used resets extra
  util="$(jq -c --arg k "$key" '.[$k].utilization // empty' "$body" 2>/dev/null || true)"
  [[ -n "$util" ]] || return 1
  resets_raw="$(jq -r --arg k "$key" '.[$k].resets_at // empty' "$body" 2>/dev/null || true)"
  used="$(normalize_pct "$util")"
  resets="$(to_epoch_maybe "$resets_raw")"
  extra="$(with_window_start "{}" "$resets" "$span")"
  # CLAUDE_ROW_NOTE is empty on every ordinary read; it carries a disclosure
  # only when a renewal succeeded but could not be persisted (#1716).
  emit_row claude "$label" "$email" "$window" "$used" "$resets" ok \
    "$CLAUDE_ROW_NOTE" "oauth-usage" "" "$extra"
  return 0
}

# One usage request with the token currently in CLAUDE_TOKEN. Split out of
# read_claude_account so the 401-then-refresh path can make the SAME request a
# second time rather than a near-copy of it (#1716) — a second copy is how the
# retry ends up missing the User-Agent that the 429 note above is all about.
#
# Returns curl's exit status; the HTTP status lands in CLAUDE_HTTP_CODE.
CLAUDE_HTTP_CODE=""
claude_usage_request() { # <body-file> <headers-file>
  local body="$1" hdrs="$2" rc=0
  CLAUDE_HTTP_CODE=""
  : > "$body"; : > "$hdrs"
  # The Authorization header goes in on stdin, never in argv: a bearer token
  # in a command line is readable from `ps` by anything running as this user.
  CLAUDE_HTTP_CODE="$(printf 'header = "Authorization: Bearer %s"\n' "$CLAUDE_TOKEN" \
    | "$CURL_BIN" -sS --max-time "$HTTP_TIMEOUT" \
        -o "$body" -D "$hdrs" -w '%{http_code}' \
        -H "anthropic-beta: oauth-2025-04-20" \
        -H "User-Agent: claude-code/${CLAUDE_VERSION}" \
        -H "Accept: application/json" \
        -K - "$ANTHROPIC_URL" 2>/dev/null)" || rc=$?
  return "$rc"
}

# A note to hang on this account's successful rows — used only to disclose a
# write-back that did not land, so a renewal that silently stopped persisting
# is visible in the table instead of costing a fresh refresh on every run
# forever.
CLAUDE_ROW_NOTE=""

read_claude_account() { # <label> <profile_dir> <keychain_service>
  local label="$1" dir="$2" service="$3"
  local body="$TMP/claude-body.json" hdrs="$TMP/claude-hdrs.txt"
  local code rc=0 email retry detail keys
  local refreshed=0 refresh_rc=0

  CLAUDE_ROW_NOTE=""

  if ! claude_token_for "$dir" "$service"; then
    emit_row claude "$label" "" "7-day" "" "" needs-login \
      "$CLAUDE_TOKEN_DETAIL — run: $(relogin_hint claude "$label")" "" ""
    return 0
  fi

  # Renew BEFORE spending a request on a token the store already says is dead.
  # Claude Code renews on launch; a profile nobody launches has nothing else
  # to do it (#1716).
  if claude_token_expired; then
    claude_refresh_access_token || refresh_rc=$?
    case "$refresh_rc" in
      0)
        refreshed=1
        CLAUDE_ROW_NOTE="$CLAUDE_REFRESH_DETAIL"
        ;;
      1)
        claude_forget_credentials
        emit_row claude "$label" "" "7-day" "" "" needs-login \
          "the stored access token has expired and ${CLAUDE_REFRESH_DETAIL} — run: $(relogin_hint claude "$label")" \
          "oauth-refresh" ""
        return 0
        ;;
      3)
        claude_forget_credentials
        emit_row claude "$label" "" "7-day" "" "" rate-limited \
          "the stored access token has expired and ${CLAUDE_REFRESH_DETAIL}" "oauth-refresh" ""
        return 0
        ;;
      *)
        claude_forget_credentials
        emit_row claude "$label" "" "7-day" "" "" unreachable \
          "the stored access token has expired and ${CLAUDE_REFRESH_DETAIL}" "oauth-refresh" ""
        return 0
        ;;
    esac
  fi

  rc=0
  claude_usage_request "$body" "$hdrs" || rc=$?
  code="$CLAUDE_HTTP_CODE"

  # A 401 on a token the store believed was still good means the expiry was
  # wrong or the grant was revoked server-side. One refresh, one retry — never
  # a loop: a refresh that yields another 401 is a dead login, and asking again
  # would just burn the rate limit on the way to the same answer.
  if [[ "$rc" -eq 0 && ( "$code" == "401" || "$code" == "403" ) \
        && "$refreshed" -eq 0 && -n "$CLAUDE_REFRESH_TOKEN" ]]; then
    refresh_rc=0
    claude_refresh_access_token || refresh_rc=$?
    case "$refresh_rc" in
      0)
        refreshed=1
        CLAUDE_ROW_NOTE="$CLAUDE_REFRESH_DETAIL"
        rc=0
        claude_usage_request "$body" "$hdrs" || rc=$?
        code="$CLAUDE_HTTP_CODE"
        ;;
      1)
        claude_forget_credentials
        emit_row claude "$label" "" "7-day" "" "" needs-login \
          "the usage endpoint rejected this credential (HTTP ${code}) and ${CLAUDE_REFRESH_DETAIL} — run: $(relogin_hint claude "$label")" \
          "oauth-refresh" ""
        return 0
        ;;
      3)
        claude_forget_credentials
        emit_row claude "$label" "" "7-day" "" "" rate-limited \
          "the usage endpoint rejected this credential (HTTP ${code}) and ${CLAUDE_REFRESH_DETAIL}" \
          "oauth-refresh" ""
        return 0
        ;;
      *)
        claude_forget_credentials
        emit_row claude "$label" "" "7-day" "" "" unreachable \
          "the usage endpoint rejected this credential (HTTP ${code}) and ${CLAUDE_REFRESH_DETAIL}" \
          "oauth-refresh" ""
        return 0
        ;;
    esac
  fi

  claude_forget_credentials

  if [[ "$rc" -ne 0 || -z "$code" ]]; then
    transport_outcome "$rc" oauth-usage
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
    # Reached either with no refresh token to try, or on the ONE retry a
    # successful refresh bought. Both mean the login itself is finished, so
    # the note is the same relogin command it has always been.
    detail="the usage endpoint rejected this credential (HTTP ${code})"
    [[ "$refreshed" -eq 1 ]] && \
      detail="$detail even after renewing it from the stored refresh token"
    emit_row claude "$label" "" "7-day" "" "" needs-login \
      "${detail} — run: $(relogin_hint claude "$label")" \
      "oauth-usage" ""
    return 0
  fi

  if [[ "$code" != "200" ]]; then
    set_outcome unreadable oauth-usage "http_${code}"
    emit_row claude "$label" "" "7-day" "" "" unreachable \
      "usage endpoint answered HTTP ${code}" "oauth-usage" ""
    return 0
  fi

  if ! jq -e . "$body" >/dev/null 2>&1; then
    set_outcome parse_error oauth-usage invalid_json
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
  claude_window_row "$label" "$email" "$body" "seven_day" "7-day" 604800 && rendered=1
  claude_window_row "$label" "$email" "$body" "seven_day_opus" "7-day (opus)" 604800 && rendered=1
  if [[ "$FIVE_HOUR" -eq 1 ]]; then
    claude_window_row "$label" "$email" "$body" "five_hour" "5-hour" 18000 && rendered=1
  fi

  if [[ "$rendered" -eq 0 ]]; then
    set_outcome parse_error oauth-usage response_shape
    # Never a silent 0 %: say what the payload actually contained, so a
    # changed response shape is diagnosable from the output alone.
    keys="$(jq -r 'if type == "object" then (keys_unsorted | join(", ")) else type end' "$body" 2>/dev/null || echo "unreadable")"
    emit_row claude "$label" "$email" "7-day" "" "" unreachable \
      "unrecognised response shape; top-level keys seen: ${keys}" "oauth-usage" ""
  fi
  return 0
}
