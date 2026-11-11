#!/usr/bin/env bash
# Sourced by ai-quotas.sh. Cursor IDE credential and usage reader.

# IDE credential and dashboard contract: .claude/reference/ai-quotas.md.
CURSOR_WINDOW="billing-cycle"
CURSOR_API_BASE="https://cursor.com/api/dashboard"
# Said instead of `relogin_hint` for every cursor login failure: there is no
# command to run. The credential belongs to the IDE, so the only thing that
# fixes a missing or expired one is signing in there.
CURSOR_SIGNIN_HINT="open the Cursor IDE and sign in"

# The IDE's state store, SELECTED BY PLATFORM (CodeAnt). macOS is the fleet,
# but hardcoding its path meant a signed-in Linux user read as `needs-login` —
# a status that tells them to sign in again, which is the one instruction that
# cannot help. `$PLATFORM` already exists here and already decides the Keychain
# path above, so the Linux store is picked the same way. Windows stays on the
# env seam: its `%APPDATA%` path is documented in .claude/reference/ai-quotas.md
# but nothing in this fleet or in CI can exercise it, and a guessed path that
# does not exist reads as `needs-login` too — the failure this change removes.
cursor_state_db() {
  if [[ -n "${AI_QUOTAS_CURSOR_STATE_DB:-}" ]]; then
    printf '%s' "$AI_QUOTAS_CURSOR_STATE_DB"
    return 0
  fi
  if [[ "$PLATFORM" == "Linux" ]]; then
    printf '%s' "${_HOME}/.config/Cursor/User/globalStorage/state.vscdb"
    return 0
  fi
  # `${_HOME}`, not a bare `$HOME`: this script resolves the home directory
  # ONCE, through the guard at the top, and every other path here is built
  # from that. Reading `$HOME` directly in one function is how the reader and
  # ai-quotas-setup.sh end up naming different stores — and `list` would then
  # disagree with `/quotas` about whether this machine is signed in (CodeAnt).
  printf '%s' "${_HOME}/Library/Application Support/Cursor/User/globalStorage/state.vscdb"
}

# The token, the cached email, and the user id the cookie needs, in globals —
# never on stdout, so no caller can put the credential into a command
# substitution by accident. Mirrors claude_token_for.
CURSOR_TOKEN=""
CURSOR_EMAIL=""
CURSOR_USER_ID=""
CURSOR_TOKEN_DETAIL=""
# Which row status the caller should emit on failure. Set alongside every
# detail below so "I could not read the store" never reaches the user as
# "sign in again" — the one instruction that cannot fix it.
CURSOR_TOKEN_STATUS=""

# Read display-only IDE identity, clearing terminal controls identically for every source.
cursor_cached_email() { # <state-db>
  local email cleaned
  email="$("$SQLITE3_BIN" -readonly "$1" "select value from ItemTable where key='cursorAuth/cachedEmail';" 2>/dev/null || true)"
  cleaned="$(printf '%s' "$email" | LC_ALL=C tr -d '[:cntrl:]')"
  [[ "$email" != "$cleaned" ]] || printf '%s' "$email"
}

cursor_token_for() { # <state-db>
  local db="$1" payload pad identity_result identity_reason
  CURSOR_TOKEN=""
  CURSOR_EMAIL=""
  CURSOR_USER_ID=""
  CURSOR_TOKEN_DETAIL=""
  CURSOR_TOKEN_STATUS=""

  # Read-only, and deliberately NOT a copy. The plan of record said to copy
  # the store to a temp file because Cursor holds it locked; measured on this
  # machine the store is 10 GB, so a copy is minutes of I/O and 10 GB of disk
  # for two key lookups. It is also unnecessary: the store is a WAL database,
  # where readers and the writer coexist by design, and `sqlite3 -readonly`
  # answers both queries in ~15 ms with the IDE running (measured
  # 2026-09-11). `-readonly` rather than a `file:...?mode=ro` URI so a path
  # holding a space, `?`, or `#` — the default macOS path holds a space —
  # needs no percent-encoding to be correct.
  #
  # No `immutable=1` fallback, on purpose: it would open a WAL database while
  # IGNORING the WAL, which returns whatever token predates the last
  # checkpoint. A stale token is indistinguishable here from a current one and
  # fails later as a 401, i.e. it reports "signed out" about an IDE that is
  # signed in. A read this reader cannot do honestly is reported, not guessed.
  CURSOR_TOKEN="$("$SQLITE3_BIN" -readonly "$db" \
    "select value from ItemTable where key='cursorAuth/accessToken';" 2>/dev/null)" || {
    CURSOR_TOKEN=""
    CURSOR_TOKEN_STATUS="unreachable"
    CURSOR_TOKEN_DETAIL="sqlite3 could not read the Cursor IDE state store at ${db}"
    return 1
  }
  if [[ -z "$CURSOR_TOKEN" ]]; then
    CURSOR_TOKEN_STATUS="needs-login"
    CURSOR_TOKEN_DETAIL="the Cursor IDE is not signed in (its state store holds no access token)"
    return 1
  fi
  # Best-effort: an account that reads fine but cannot name itself is still a
  # readable account, so a missing email falls back to the label in emit_row.
  CURSOR_EMAIL="$(cursor_cached_email "$db")"

  # Distinguish format changes from a missing subject without echoing any
  # token/claim value. Do not guess identities from unrelated fields.
  # Cursor 3.29.9's installed auth-storage codec seals these database values
  # through Electron safeStorage; direct SQLite ciphertext is not a JWT.
  case "$CURSOR_TOKEN" in
    cursor-safe-storage:v1:*)
      CURSOR_TOKEN=""; CURSOR_TOKEN_STATUS="unreadable"
      CURSOR_TOKEN_DETAIL="the Cursor IDE stores this access token encrypted; use --browser with an already signed-in Chrome profile"
      return 1
      ;;
  esac
  if [[ ! "$CURSOR_TOKEN" =~ ^[A-Za-z0-9._-]+$ ]]; then
    CURSOR_TOKEN=""
    CURSOR_USER_ID=""
    CURSOR_TOKEN_STATUS="unreadable"
    CURSOR_TOKEN_DETAIL="the Cursor IDE state store holds an access token that is not shaped like a JWT"
    return 1
  fi
  local jwt_shape='^[^.]+[.][^.]+[.][^.]+$'
  if ! [[ "$CURSOR_TOKEN" =~ $jwt_shape ]]; then
    CURSOR_TOKEN=""; CURSOR_TOKEN_STATUS="unreadable"
    CURSOR_TOKEN_DETAIL="the Cursor IDE access token has an unsupported structure (expected three JWT parts)"
    return 1
  fi

  # The user id is the token's `sub` claim. Decoding a claim is not reading a
  # secret — the same reasoning codex_email_for documents — but the token
  # itself still never leaves these globals.
  payload="$(printf '%s' "$CURSOR_TOKEN" | cut -d. -f2 | tr '_-' '/+')"
  if [[ -n "$payload" ]]; then
    # base64url drops padding; jq's @base64d wants it.
    pad=$(( ${#payload} % 4 ))
    if [[ "$pad" -eq 2 ]]; then payload="${payload}=="
    elif [[ "$pad" -eq 3 ]]; then payload="${payload}="
    elif [[ "$pad" -eq 1 ]]; then payload=""
    fi
  fi
  # Payload travels only through stdin, never jq argv. Failure objects contain
  # fixed reasons only; validate a string subject before shell newline trimming.
  identity_result='{"reason":"payload_base64_invalid"}'
  if [[ -n "$payload" ]]; then
    identity_result="$(printf '%s' "$payload" | jq -Rsc '
      (try {decoded: @base64d} catch {reason:"payload_base64_invalid"})
      | if has("reason") then .
        else (try {claim:(.decoded | fromjson)} catch {reason:"payload_json_invalid"}) end
      | if has("reason") then .
        elif (.claim | type) != "object" then {reason:"payload_not_object"}
        elif (.claim | has("sub") | not) then {reason:"subject_missing"}
        elif (.claim.sub | type) != "string" then {reason:"subject_not_string"}
        elif .claim.sub == "" then {reason:"subject_empty"}
        elif (.claim.sub | test("[^A-Za-z0-9._@|-]")) then {reason:"subject_unsafe"}
        else {reason:"ok",subject:.claim.sub} end
    ' 2>/dev/null)" || identity_result='{"reason":"decoder_unavailable"}'
  fi
  identity_reason="$(printf '%s' "$identity_result" | jq -r '.reason // "decoder_unavailable"' 2>/dev/null)"
  case "$identity_reason" in
    ok)
      CURSOR_USER_ID="$(printf '%s' "$identity_result" | jq -r '.subject' 2>/dev/null)" || {
        CURSOR_TOKEN=""; CURSOR_TOKEN_STATUS="unreadable"
        CURSOR_TOKEN_DETAIL="the Cursor IDE JWT subject decoder could not run"
        return 1
      }
      ;;
    *)
      CURSOR_TOKEN=""; CURSOR_TOKEN_STATUS="unreadable"
      case "$identity_reason" in
        payload_base64_invalid) CURSOR_TOKEN_DETAIL="the Cursor IDE JWT payload is not valid base64url" ;;
        payload_json_invalid) CURSOR_TOKEN_DETAIL="the Cursor IDE JWT payload is not valid JSON" ;;
        payload_not_object) CURSOR_TOKEN_DETAIL="the Cursor IDE JWT payload is not an object" ;;
        subject_missing) CURSOR_TOKEN_DETAIL="the Cursor IDE JWT payload has no sub claim" ;;
        subject_not_string) CURSOR_TOKEN_DETAIL="the Cursor IDE JWT sub claim is not a string" ;;
        subject_empty) CURSOR_TOKEN_DETAIL="the Cursor IDE JWT sub claim is empty" ;;
        subject_unsafe) CURSOR_TOKEN_DETAIL="the token's sub claim carries characters this reader will not put in a request header" ;;
        *) CURSOR_TOKEN_DETAIL="the Cursor IDE JWT subject decoder could not run" ;;
      esac
      return 1
      ;;
  esac
  # Only a LEADING `auth0|` comes off. Taking the segment after the final `|`
  # instead — the obvious-looking reading of "strip the provider prefix" — is
  # wrong and was measured wrong: this account's `sub` is
  # `google-oauth2|<id>`, and the dashboard accepts the cookie only with that
  # prefix intact. Stripping it answers 401 on a signed-in IDE.
  CURSOR_USER_ID="${CURSOR_USER_ID#auth0|}"
  if [[ -z "$CURSOR_USER_ID" ]]; then
    CURSOR_TOKEN=""
    CURSOR_TOKEN_STATUS="unreadable"
    CURSOR_TOKEN_DETAIL="the Cursor IDE JWT sub claim is empty after its auth0 prefix"
    return 1
  fi

  # Both halves of the cookie are checked against an allow-list BEFORE either
  # reaches the curl config (CodeRabbit). That config is line-oriented and
  # quoted, so a value carrying a newline, a quote, or a backslash does not
  # merely corrupt the header — it ends the line and whatever follows is read
  # by curl as further OPTIONS. The values come from a local SQLite file this
  # script does not own; treating their shape as guaranteed is the assumption
  # that turns a tampered state store into argument injection.
  #
  # The sets are the real ones: a JWT is base64url with two dots, and the
  # `sub` claims measured here are `google-oauth2|<digits>` and `auth0|<hex>`.
  # Anything outside them is reported rather than sent.
  if [[ ! "$CURSOR_USER_ID" =~ ^[A-Za-z0-9._@|-]+$ ]]; then
    CURSOR_TOKEN=""
    CURSOR_USER_ID=""
    CURSOR_TOKEN_STATUS="unreadable"
    CURSOR_TOKEN_DETAIL="the token's sub claim carries characters this reader will not put in a request header"
    return 1
  fi
  return 0
}

# One dashboard call. The cookie goes in on stdin, never in argv. Prints the
# HTTP status; the body lands in <out-file>.
cursor_api_call() { # <endpoint> <out-file>
  local endpoint="$1" out="$2" rc=0 code
  : > "$out"
  code="$(printf 'header = "Cookie: WorkosCursorSessionToken=%s%%3A%%3A%s"\n' \
      "$CURSOR_USER_ID" "$CURSOR_TOKEN" \
    | "$CURL_BIN" -sS --max-time "$HTTP_TIMEOUT" \
        -o "$out" -w '%{http_code}' \
        -X POST \
        -H "Content-Type: application/json" \
        -H "Origin: https://cursor.com" \
        -H "Accept: application/json" \
        -d '{}' \
        -K - "${CURSOR_API_BASE}/${endpoint}" 2>/dev/null)" || rc=$?
  printf '%s' "$rc" > "${out}.curl-status"
  if [[ "$rc" -ne 0 ]]; then
    printf '000'
    return 0
  fi
  printf '%s' "$code"
  return 0
}

# `$1` dollars, or "unknown" — used only in the note, never as a figure.
cursor_usd() { # <number|null|"">
  local v="${1:-}"
  [[ -n "$v" && "$v" != "null" ]] || { printf 'unknown'; return 0; }
  printf '$%s' "$v"
}

read_cursor_account() { # <label>
  local label="$1"
  local db code plan_code cycle_code norm keys pools count i
  local start_epoch end_epoch plan_name plan_used plan_included source note extra
  local spend_used spend_limit
  local pool used
  local usage_body="$TMP/cursor-usage.json"
  local plan_body="$TMP/cursor-plan.json"
  local cycle_body="$TMP/cursor-cycle.json"

  # Named on every row so a reader of --json can tell this path from the
  # browser one it replaced without diffing dates.
  source="ide-token"

  if ! command -v "$SQLITE3_BIN" >/dev/null 2>&1; then
    emit_row cursor "$label" "" "$CURSOR_WINDOW" "" "" unreachable \
      "no sqlite3 found (set AI_QUOTAS_SQLITE3_BIN) — it is what reads the Cursor IDE state store" "$source" ""
    return 0
  fi
  db="$(cursor_state_db)"
  if [[ ! -r "$db" ]]; then
    emit_row cursor "$label" "" "$CURSOR_WINDOW" "" "" needs-login \
      "no readable Cursor IDE state store at ${db} — ${CURSOR_SIGNIN_HINT}" "$source" ""
    return 0
  fi
  if ! cursor_token_for "$db"; then
    # The status is the one cursor_token_for chose: a store it could not read
    # is `unreachable`, a store with no token is `needs-login`, and a token it
    # could not decode is `unreadable`. Collapsing all three into
    # `needs-login` would tell a user to sign in again over a missing sqlite3
    # or a changed token format, which is the one instruction that cannot help.
    if [[ "$CURSOR_TOKEN_STATUS" == "needs-login" ]]; then
      emit_row cursor "$label" "" "$CURSOR_WINDOW" "" "" needs-login \
        "${CURSOR_TOKEN_DETAIL} — ${CURSOR_SIGNIN_HINT}" "$source" ""
    else
      emit_row cursor "$label" "" "$CURSOR_WINDOW" "" "" "$CURSOR_TOKEN_STATUS" \
        "$CURSOR_TOKEN_DETAIL" "$source" ""
    fi
    return 0
  fi

  code="$(cursor_api_call get-current-period-usage "$usage_body")"
  # The other two are ENRICHMENT, and their failures are deliberately not the
  # row's failure: every figure rendered below comes from the usage payload,
  # which carries cycle bounds of its own. get-monthly-billing-cycle is the
  # authoritative source for those bounds and get-plan-info supplies the plan
  # name, so losing either costs a label, not a number — and a row that went
  # `unreachable` because a plan-NAME lookup 500'd would be reporting a
  # blackout it does not have.
  #
  # They run ONLY after the usage call succeeded (CodeRabbit). A rejected
  # token, a dead endpoint, or a network failure has already decided this row,
  # and spending two more requests to enrich a row that will not render is
  # pure latency — worst case, three 401s per account per read against a
  # provider that rate-limits.
  plan_code=""
  cycle_code=""
  if [[ "$code" == "200" ]]; then
    plan_code="$(cursor_api_call get-plan-info "$plan_body")"
    cycle_code="$(cursor_api_call get-monthly-billing-cycle "$cycle_body")"
  fi
  # Spent, and gone. Everything below reads files.
  CURSOR_TOKEN=""
  CURSOR_USER_ID=""

  case "$code" in
    000)
      transport_outcome "$(cat "${usage_body}.curl-status" 2>/dev/null || echo 0)" "$source"
      # The email came from the local store, not the network, so a curl
      # failure has not invalidated it (CodeAnt). Every other failure branch
      # below carries it; dropping it here would blank the account identity on
      # exactly the rows a user is most likely to be squinting at.
      emit_row cursor "$label" "$CURSOR_EMAIL" "$CURSOR_WINDOW" "" "" unreachable \
        "curl failed talking to ${CURSOR_API_BASE}/get-current-period-usage" "$source" ""
      return 0 ;;
    401 | 403)
      # The IDE refreshes this token as long as it is used; a rejection means
      # it lapsed, and only the IDE can mint a new one.
      emit_row cursor "$label" "$CURSOR_EMAIL" "$CURSOR_WINDOW" "" "" needs-login \
        "the dashboard rejected the IDE token (HTTP ${code}) — ${CURSOR_SIGNIN_HINT}" "$source" ""
      return 0 ;;
    200) ;;
    429)
      set_outcome rate_limited "$source" http_429
      emit_row cursor "$label" "$CURSOR_EMAIL" "$CURSOR_WINDOW" "" "" rate-limited "the usage endpoint answered HTTP 429" "$source" ""
      return 0 ;;
    *)
      set_outcome unreadable "$source" "http_${code}"
      emit_row cursor "$label" "$CURSOR_EMAIL" "$CURSOR_WINDOW" "" "" unreachable \
        "the usage endpoint answered HTTP ${code}" "$source" ""
      return 0 ;;
  esac

  if ! jq -e 'type == "object"' "$usage_body" >/dev/null 2>&1; then
    emit_row cursor "$label" "$CURSOR_EMAIL" "$CURSOR_WINDOW" "" "" unreadable \
      "the usage endpoint answered HTTP 200 with a body that is not a JSON object" "$source" ""
    return 0
  fi
  # An enrichment call that did not answer 200 with JSON is replaced by an
  # empty object, so the normaliser below falls back to the usage payload
  # instead of aborting on a slurpfile it cannot parse.
  [[ "$plan_code" == "200" ]] && jq -e 'type == "object"' "$plan_body" >/dev/null 2>&1 || printf '{}' > "$plan_body"
  [[ "$cycle_code" == "200" ]] && jq -e 'type == "object"' "$cycle_body" >/dev/null 2>&1 || printf '{}' > "$cycle_body"

  # One jq program owns every conversion, because the figures it produces have
  # to match what the retired JS helper produced to the cent: dollars arrive
  # as CENTS, the cycle as MILLISECONDS, and a blank string is an ABSENT
  # figure rather than zero. `"" | tonumber` is an error in jq and `Number("")`
  # was `0` in the helper this replaces — the one conversion both had to get
  # right, in opposite ways, so it is written out here rather than implied.
  norm="$(jq -nc \
    --slurpfile usage "$usage_body" \
    --slurpfile plan "$plan_body" \
    --slurpfile cycle "$cycle_body" '
    def num:
      if . == null then null
      elif type == "number" then (if (isinfinite or isnan) then null else . end)
      elif type == "string" then
        (gsub("^[[:space:]]+|[[:space:]]+$"; "")
         | if . == "" then null else (try tonumber catch null) end)
      else null end;
    def cents: num | if . == null then null else ((. | round) / 100) end;
    def ms:    num | if . == null or . <= 0 then null else ((. / 1000) | floor) end;
    def pct:   num | if . == null or . < 0 then null else . end;
    ($usage[0] // {}) as $u
    | (($u.planUsage // {}) | if type == "object" then . else {} end) as $p
    | (($u.spendLimitUsage // {}) | if type == "object" then . else {} end) as $s
    | ((($plan[0] // {}).planInfo // {}) | if type == "object" then . else {} end) as $pi
    | ($cycle[0] // {}) as $c
    | {
        pools: [
          (if ($p.autoPercentUsed | pct) == null then empty
           else {pool: "cursor-models", used_pct: ($p.autoPercentUsed | pct)} end),
          (if ($p.apiPercentUsed | pct) == null then empty
           else {pool: "other-models", used_pct: ($p.apiPercentUsed | pct)} end)
        ],
        cycle_start: (($c.startDateEpochMillis // $u.billingCycleStart) | ms),
        cycle_end:   (($c.endDateEpochMillis // $u.billingCycleEnd) | ms),
        plan_name:   (($pi.planName // "") | if type == "string" then . else "" end),
        plan_used_usd: ($p.totalSpend | cents),
        plan_included_usd: ((if ($p | has("limit")) then $p.limit else $p.includedSpend end) | cents),
        spend_limit_used_usd: ($s.individualUsed | cents),
        spend_limit_usd:      ($s.individualLimit | cents),
        keys_seen: ($u | keys)
      }' 2>/dev/null || true)"

  if [[ -z "$norm" ]]; then
    emit_row cursor "$label" "$CURSOR_EMAIL" "$CURSOR_WINDOW" "" "" unreadable \
      "the usage response changed shape past what this reader can normalise" "$source" ""
    return 0
  fi

  pools="$(printf '%s' "$norm" | jq -c '.pools // []')"
  count="$(printf '%s' "$pools" | jq 'length' 2>/dev/null || echo 0)"
  if [[ ! "$count" =~ ^[0-9]+$ || "$count" -eq 0 ]]; then
    # HTTP 200 with no pool figure in it is the dashboard answering without
    # saying anything. Reporting it as a shape problem, with the keys that DID
    # arrive, is the only honest reading; rendering nothing would drop the
    # account silently from a report whose whole promise is one row each.
    keys="$(printf '%s' "$norm" | jq -r '(.keys_seen // []) | join(", ")')"
    emit_row cursor "$label" "$CURSOR_EMAIL" "$CURSOR_WINDOW" "" "" unreadable \
      "the usage response carried no pool percentages${keys:+; keys seen: ${keys}}" "$source" ""
    return 0
  fi

  end_epoch="$(printf '%s' "$norm" | jq -r 'if .cycle_end == null then "" else (.cycle_end | tostring) end')"
  # Anything that is not epoch seconds becomes "no reset reported" — the table
  # renders that as `-`. A value date(1) cannot read would otherwise format as
  # nothing while the countdown said `reset`, i.e. "your cycle already rolled".
  [[ "$end_epoch" =~ ^[0-9]+$ ]] || end_epoch=""
  start_epoch="$(printf '%s' "$norm" | jq -r 'if .cycle_start == null then "" else (.cycle_start | tostring) end')"
  [[ "$start_epoch" =~ ^[0-9]+$ ]] || start_epoch=""
  plan_name="$(printf '%s' "$norm" | jq -r '.plan_name // ""')"
  plan_used="$(printf '%s' "$norm" | jq -r 'if .plan_used_usd == null then "" else (.plan_used_usd | tostring) end')"
  plan_included="$(printf '%s' "$norm" | jq -r 'if .plan_included_usd == null then "" else (.plan_included_usd | tostring) end')"
  # The on-demand block (#1669). Plan-wide like the two above — it is one
  # spend limit for the account, not a per-pool one — so both rows carry the
  # same pair, and the overage column says `on-demand` when the dashboard did
  # not report it rather than showing a dollar figure nobody sent.
  spend_used="$(printf '%s' "$norm" | jq -r 'if .spend_limit_used_usd == null then "" else (.spend_limit_used_usd | tostring) end')"
  spend_limit="$(printf '%s' "$norm" | jq -r 'if .spend_limit_usd == null then "" else (.spend_limit_usd | tostring) end')"

  # Said on every pool row, because it is the one thing a reader of this table
  # would otherwise get wrong: the dashboard's own response reports the pools
  # as PERCENTAGES, and the only dollars in it are plan-wide. Dividing those
  # dollars across the two pools would manufacture a figure Cursor never sent.
  note="billing cycle"
  [[ -z "$start_epoch" ]] || note="$note since $(epoch_to_et "$start_epoch")"
  note="${note}; plan-wide spend $(cursor_usd "$plan_used") of $(cursor_usd "$plan_included") included"
  note="${note}; this response reports the pools as percent only, so per-pool dollars are unavailable"

  for (( i = 0; i < count; i++ )); do
    pool="$(printf '%s' "$pools" | jq -r --argjson i "$i" '.[$i].pool // ""')"
    used="$(printf '%s' "$pools" | jq -r --argjson i "$i" \
      'if .[$i].used_pct == null then "" else (.[$i].used_pct | tostring) end')"
    [[ -n "$pool" ]] || pool="pool-${i}"
    # One decimal, with a bare `.0` dropped: the payload carries full float
    # precision (49.02333…), the dashboard shows `49%`, and a table column is
    # not the place for fourteen digits. Rounding happens ONCE, here, so the
    # JSON row and the table can never disagree — and `remaining_pct`, which
    # emit_row derives as `100 - used`, comes out of the same number.
    # VALIDATED before rounding, not after. awk coerces a non-numeric value to
    # 0, so `"n/a"` — or any string a future payload version put here — would
    # round to `0.0` and render as `0 %`: a figure nobody measured, reading as
    # "plenty left". A value this reader cannot recognise as a number becomes
    # empty, which emit_row turns into `null` and the table shows as `-`.
    case "$used" in
      "") ;;
      *[!0-9.]* | *.*.* | .) used="" ;;
      *) used="$(awk -v v="$used" 'BEGIN { s = sprintf("%.1f", v); sub(/\.0$/, "", s); print s }' 2>/dev/null || printf '%s' "$used")" ;;
    esac
    # Cursor is the one provider that reports its window START directly: the
    # billing cycle has a start date in the same payload, so nothing is
    # derived from the end. A cycle whose start the response omitted leaves
    # the field null, exactly as an unparseable one does.
    extra="$(jq -nc --arg pool "$pool" --arg pu "$plan_used" --arg pi "$plan_included" \
      --arg su "$spend_used" --arg sl "$spend_limit" --arg ws "$start_epoch" \
      '{pool: $pool,
        window_start_epoch: (if $ws == "" then null else (try ($ws | tonumber) catch null) end),
        plan_used_usd: (if $pu == "" then null else (try ($pu | tonumber) catch null) end),
        plan_included_usd: (if $pi == "" then null else (try ($pi | tonumber) catch null) end),
        spend_limit_used_usd: (if $su == "" then null else (try ($su | tonumber) catch null) end),
        spend_limit_usd: (if $sl == "" then null else (try ($sl | tonumber) catch null) end)}' \
      2>/dev/null || printf '{}')"
    emit_row cursor "$label" "$CURSOR_EMAIL" "$CURSOR_WINDOW" "$used" "$end_epoch" ok \
      "$note" "$source" "$plan_name" "$extra"
  done
  CURSOR_EMAIL=""
  return 0
}
