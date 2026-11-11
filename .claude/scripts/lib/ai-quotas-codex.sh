#!/usr/bin/env bash
# Sourced by ai-quotas.sh. Codex app-server and HTTP usage readers.

codex_bin() {
  local override="${AI_QUOTAS_CODEX_BIN:-}" candidate
  if [[ -n "$override" ]]; then
    [[ -x "$override" ]] && { printf '%s' "$override"; return 0; }
    return 1
  fi
  if candidate="$(command -v codex 2>/dev/null)" && [[ -n "$candidate" ]]; then
    printf '%s' "$candidate"; return 0
  fi
  for candidate in "/opt/homebrew/bin/codex" "/usr/local/bin/codex" \
                   "/Applications/ChatGPT.app/Contents/Resources/codex"; do
    [[ -x "$candidate" ]] && { printf '%s' "$candidate"; return 0; }
  done
  return 1
}

# The email lives in the id_token's JWT payload. Decoding a claim is not
# reading a secret — but the token itself never leaves this function.
codex_email_for() { # <profile_dir>
  local dir="$1" tok payload pad
  [[ -s "$dir/auth.json" ]] || return 0
  tok="$(jq -r '.tokens.id_token // empty' "$dir/auth.json" 2>/dev/null || true)"
  [[ -n "$tok" ]] || return 0
  payload="$(printf '%s' "$tok" | cut -d. -f2 | tr '_-' '/+')"
  [[ -n "$payload" ]] || return 0
  # base64url drops padding; jq's @base64d wants it.
  pad=$(( ${#payload} % 4 ))
  if [[ "$pad" -eq 2 ]]; then payload="${payload}=="
  elif [[ "$pad" -eq 3 ]]; then payload="${payload}="
  elif [[ "$pad" -eq 1 ]]; then return 0
  fi
  jq -rn --arg p "$payload" '($p | @base64d | fromjson | .email // empty)' 2>/dev/null || true
}

# Drives `codex app-server` over a FIFO. The FIFO is what keeps stdin OPEN:
# feeding the requests from a plain pipe closes stdin at once and the server
# shuts down before it has answered (measured — the initialize reply arrives,
# the rate-limit reply does not). The reader polls for the response and kills
# the server the moment it lands, so a healthy account costs a round trip
# rather than the whole bound.
CODEX_RESULT_FILE=""
CODEX_FAIL_REASON=""
# The background supervisor leads an isolated group for the entire read.
# Verify that isolation before starting the provider. Cleanup runs in that
# still-live group, so it never relies on a dead or recycled server PID.
codex_supervise_server() { # control dir, parent group, profile, binary, FIFO, output, response ticks
  local control="$1" parent_group="$2" dir="$3" bin="$4" fifo="$5" out="$6" max_ticks="$7"
  local group expected="" member snap ticks=0 started last now
  # Disable monitor mode *inside* the new group so subsequent children inherit it.
  set +m
  group="$(sh -c 'ps -o pgid= -p "$$"; :' | tr -d '[:space:]')"
  while [[ ! -s "$control/launch" && ! -e "$control/shutdown.request" && -d "$control" ]]; do
    (( ticks < 40 )) || return 1
    if sleep 0.05 2>/dev/null; then ticks=$((ticks + 1))
    else sleep 1; ticks=$((ticks + 20)); fi
  done
  IFS= read -r expected < "$control/launch" || return 1
  [[ ! -e "$control/shutdown.request" ]] || return 1
  if [[ ! "$group" =~ ^[1-9][0-9]*$ || "$group" != "$expected" || "$group" == "$parent_group" ]]; then
    : > "$control/unowned"
    return 1
  fi
  started="${SECONDS:-}"
  [[ "$started" =~ ^[0-9]{1,10}$ ]] || return 1
  last="$started"
  : > "$control/owned" || return 1
  CODEX_HOME="$dir" "$bin" app-server <"$fifo" >"$out" 2>/dev/null &
  member=$!
  # Install the ignore only after the provider has inherited its normal
  # disposition. This process keeps the group identity live through escalation.
  trap '' TERM
  ticks=0
  while [[ ! -e "$control/shutdown.request" && -d "$control" ]]; do
    if [[ ! -e "$control/exited" ]] && ! kill -0 "$member" 2>/dev/null; then
      : > "$control/exited" || break
    fi
    now="${SECONDS:-}"
    [[ "$now" =~ ^[0-9]{1,10}$ ]] || break
    (( 10#$now >= 10#$last && 10#$now - 10#$started < CODEX_TIMEOUT + 3 )) || break
    # Leave two seconds of slack for the caller's start and polling loop.
    (( ticks < max_ticks || ticks - max_ticks < 40 )) || break
    last="$now"
    if sleep 0.05 2>/dev/null; then ticks=$((ticks + 1))
    else sleep 1; ticks=$((ticks + 20)); fi
  done
  kill -s TERM 0 2>/dev/null || true
  ticks=0; started="${SECONDS:-}"; last="$started"
  while [[ "$started" =~ ^[0-9]{1,10}$ && -d "$control" ]]; do
    # Only the launched server represents the provider among our direct children.
    # Other direct children are the snapshot and its polling sleeps. Keep
    # the provider and all other group members, including reparented ones.
    ps -axo pid=,ppid=,pgid=,stat= > "$control/members" &
    snap=$!
    while kill -0 "$snap" 2>/dev/null; do
      now="${SECONDS:-}"
      [[ "$now" =~ ^[0-9]{1,10}$ ]] || break 2
      (( 10#$now >= 10#$last && ticks < 20 && 10#$now - 10#$started < 2 )) || break 2
      last="$now"
      if sleep 0.05 2>/dev/null; then ticks=$((ticks + 1))
      else sleep 1; ticks=$((ticks + 20)); fi
    done
    wait "$snap" 2>/dev/null || break
    awk -v g="$group" -v provider="$member" '
      $3 == g && $1 != g && $4 !~ /^Z/ && ($2 != g || $1 == provider) { live=1 }
      END { exit !live }
    ' "$control/members" || break
    now="${SECONDS:-}"
    [[ "$now" =~ ^[0-9]{1,10}$ ]] || break
    (( 10#$now >= 10#$last && ticks < 20 && 10#$now - 10#$started < 2 )) || break
    last="$now"
    if sleep 0.05 2>/dev/null; then ticks=$((ticks + 1))
    else sleep 1; ticks=$((ticks + 20)); fi
  done
  # Still inside the verified group. A final signal closes the snapshot race
  # even if a remaining member forked while the process list was being read.
  kill -s KILL 0
}

codex_stop_server() { # owned supervisor PID, private control dir
  local pid="$1" control="${2:-}" ticks=0 started="${SECONDS:-}" last now
  local waited=0 scan=0 live
  [[ "$pid" =~ ^[1-9][0-9]*$ && "$pid" != "$$" && -d "$control" ]] || return 1
  : > "$control/shutdown.request" || return 1
  last="$started"
  while :; do
    if (( ! waited )) && ! kill -0 "$pid" 2>/dev/null; then
      wait "$pid" 2>/dev/null || true
      # No provider starts until the supervisor proves it owns the group.
      [[ -e "$control/owned" ]] || return 0
      waited=1
    fi
    if (( waited )); then
      # Reaping the leader confirms only its exit. Observe the verified
      # group's remaining members without sending any signal to that group.
      # The snapshot child shares the cleanup budget if ps itself stalls.
      if (( ! scan )); then
        ps -axo pgid=,stat= > "$control/observed" 2>/dev/null &
        scan=$!
      elif ! kill -0 "$scan" 2>/dev/null; then
        wait "$scan" 2>/dev/null || return 1
        live="$(awk -v g="$pid" '$1 == g && $2 !~ /^Z/ { live=1 } END { print live+0 }' "$control/observed")" || return 1
        [[ "$live" == 0 ]] && return 0
        [[ "$live" == 1 ]] || return 1
        scan=0
      fi
    fi
    now="${SECONDS:-}"
    # The supervisor has its own finite fuse; a broken caller clock still
    # permits a bounded wait by tick count.
    if [[ "$started" =~ ^[0-9]{1,10}$ && "$now" =~ ^[0-9]{1,10}$ &&
          "$last" =~ ^[0-9]{1,10}$ ]] && (( 10#$now >= 10#$last && 10#$now - 10#$started >= 5 )); then
      return 1
    fi
    (( ticks < 80 )) || return 1
    last="$now"
    if sleep 0.05 2>/dev/null; then ticks=$((ticks + 1))
    else sleep 1; ticks=$((ticks + 20)); fi
  done
}

codex_app_server_read() { # <profile_dir> <codex_bin>
  local dir="$1" bin="$2"
  local fifo="$TMP/codex.fifo" out="$TMP/codex.out" poll_ticks=0 srv=0
  local started="${SECONDS:-}" last now max_ticks control parent_group monitor="$-"
  # JSON permits whitespace on BOTH sides of the name separator, so a server
  # that writes `"id" : 2` is as valid as the compact `"id":2` we send. Matching
  # only the compact form makes a healthy account look like a timeout and sends
  # the reader down the HTTP fallback, so tolerate either.
  local id2_re='"id"[[:space:]]*:[[:space:]]*2'
  CODEX_RESULT_FILE=""
  # The three ways this can fail are three different things to fix — a
  # crashed CLI, a hung one, and a broken temp dir — and a single "did not
  # answer within Ns" for all of them sends the reader after a timeout that
  # never happened. Recorded here, reported in the row's note.
  CODEX_FAIL_REASON="app-server did not answer within ${CODEX_TIMEOUT}s"
  if [[ ! "$started" =~ ^[0-9]{1,10}$ ]]; then
    CODEX_FAIL_REASON="app-server response clock unavailable"
    return 1
  fi
  last="$started"
  max_ticks=$(( CODEX_TIMEOUT * 20 ))
  if (( max_ticks <= 0 || max_ticks / 20 != CODEX_TIMEOUT )); then
    CODEX_FAIL_REASON="app-server response timeout out of range"
    return 1
  fi
  rm -f "$fifo" "$out"
  if ! mkfifo "$fifo" 2>/dev/null; then
    CODEX_FAIL_REASON="could not create the app-server pipe in ${TMP}"
    return 1
  fi
  : > "$out"
  parent_group="$(sh -c 'ps -o pgid= -p "$$"; :' | tr -d '[:space:]')"
  if [[ ! "$parent_group" =~ ^[1-9][0-9]*$ ]] ||
     ! control="$(mktemp -d "$TMP/codex-control.XXXXXX")"; then
    CODEX_FAIL_REASON="could not establish app-server process ownership"
    rm -f "$fifo"
    return 1
  fi

  # The server's read-open of the FIFO blocks until a writer appears; it is
  # the BACKGROUND process that waits, so the parent reaches the open below
  # and releases it. Opening read-write (`<>`) here is what makes that open
  # unable to block in turn, even when the server died on startup.
  # The monitor setting is scoped to this launch and restored before the read.
  {
    set -m 2>/dev/null || true
    codex_supervise_server "$control" "$parent_group" "$dir" "$bin" "$fifo" "$out" "$max_ticks" >/dev/null &
    srv=$!
    [[ "$monitor" == *m* ]] || set +m
  } 2>/dev/null
  if ! printf '%s\n' "$srv" > "$control/launch"; then
    CODEX_FAIL_REASON="could not bind app-server process ownership"
    codex_stop_server "$srv" "$control" || true
    rm -f "$fifo"
    return 1
  fi
  if ! exec 3<> "$fifo"; then
    CODEX_FAIL_REASON="could not open the app-server pipe"
    codex_stop_server "$srv" "$control" || true
    rm -f "$fifo"
    return 1
  fi
  printf '%s\n' \
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"ai-quotas","version":"1.0"}}}' \
    '{"jsonrpc":"2.0","method":"initialized"}' \
    '{"jsonrpc":"2.0","id":2,"method":"account/rateLimits/read"}' >&3

  local exited_early=0
  # Twenty short sleeps retain a second of waiting. The elapsed deadline has
  # one whole-second clock quantum of slack to avoid timing out early; the
  # finite tick budget remains effective if SECONDS stops advancing.
  while (( poll_ticks < max_ticks )); do
    if grep -q "$id2_re" "$out" 2>/dev/null; then break; fi
    if [[ -e "$control/exited" ]] || ! kill -0 "$srv" 2>/dev/null; then exited_early=1; break; fi
    now="${SECONDS:-}"
    if [[ ! "$now" =~ ^[0-9]{1,10}$ ]] || (( 10#$now < 10#$last )); then
      CODEX_FAIL_REASON="app-server response clock unavailable or moved backwards"
      break
    fi
    last="$now"
    (( 10#$now - 10#$started < CODEX_TIMEOUT + 1 )) || break
    if sleep 0.05 2>/dev/null; then poll_ticks=$((poll_ticks + 1))
    else sleep 1; poll_ticks=$((poll_ticks + 20)); fi
  done

  exec 3>&-
  if codex_stop_server "$srv" "$control" 2>/dev/null; then
    if [[ -e "$control/unowned" ]]; then
      CODEX_FAIL_REASON="could not establish app-server process ownership"
      exited_early=0
    fi
    rm -f "$control/launch" "$control/shutdown.request" "$control/exited" "$control/members" \
      "$control/unowned" "$control/owned" "$control/observed"
    rmdir "$control" 2>/dev/null || true
  else
    warn "could not confirm app-server group exit within its cleanup budget"
  fi
  rm -f "$fifo"

  if grep -q "$id2_re" "$out" 2>/dev/null; then
    CODEX_FAIL_REASON=""
    CODEX_RESULT_FILE="$out"
    return 0
  fi
  # A server that exited on its own did not time out — it refused, crashed,
  # or found nothing to serve under that CODEX_HOME. Say which.
  [[ "$exited_early" -eq 1 ]] && CODEX_FAIL_REASON="app-server exited without answering"
  return 1
}

# Renders whichever windows a rateLimits snapshot carries. The weekly window
# is picked by windowDurationMins == 10080 across BOTH primary and secondary,
# because which slot holds it varies by plan (measured: a Pro account reports
# the weekly figures in `primary` with `secondary` null).
# <note> is prepended to every row this renders. On the fallback path it
# carries WHY app-server was skipped: `source: http` says which path ran, but
# not what went wrong with the preferred one, and a silently degraded read is
# the thing worth surfacing.
# A LIVE overage figure from the rate-limits payload, when one is there.
#
# The reset balance IS in the payload (#1862), just not under the key this
# hook first guessed: `account/rateLimits/read` carries
# `rateLimitResetCredits: {availableCount, credits: [{status, grantedAt,
# expiresAt, …}]}` beside `rateLimits`, and the HTTP body carries
# `rate_limit_reset_credits: {available_count}`. Credits EXPIRE, so the soonest
# expiry among the still-available ones is read too. The older guessed keys
# stay as harmless fallbacks.
#
# Written so that being wrong costs nothing: a key that is absent, or present
# with a value that is not a plain number, contributes NOTHING to the row, and
# the month watermark in quotas-cheapest-next.sh answers instead. What it must
# never do is invent a balance — hence the explicit numeric guard rather than a
# bare `tonumber`.
codex_live_overage() { # <snapshot-json-file>
  # Type-guarded at every step. `.resets.freeRemaining` on a payload whose
  # `resets` is an array or a number is a jq TYPE ERROR, which aborts the
  # program — and while the `|| printf '{}'` below catches that, an error path
  # is a poor way to express "this key was not there". `obj` narrows to an
  # object first, so an unexpected shape reads as absent, which is what it is.
  jq -c '
    def as_num: if type == "number" then .
                elif type == "string" and test("^[0-9]+(\\.[0-9]+)?$") then tonumber
                else null end;
    def obj: if type == "object" then . else {} end;
    (. | obj) as $s
    | ($s.rateLimitResetCredits | obj) as $rc
    | {free_resets_remaining:
         # The first candidate that is a plain number wins. `//` alone would stop
         # at the first key that is merely PRESENT, so a malformed value in an
         # earlier key would hide a valid count in a later one. MEASURED keys come
         # first (a real payload carried them), the old guessed keys after: a
         # guess nobody has seen must never outrank the figure Codex really sent.
         ([$rc.availableCount,
           ($s.rate_limit_reset_credits | obj | .available_count),
           $s.freeResetsRemaining, $s.free_resets_remaining,
           ($s.resets | obj | .freeRemaining)]
          | map(as_num) | map(select(. != null)) | first),
       free_reset_expires_epoch:
         (if ($rc.credits | type) == "array"
          then ([$rc.credits[] | obj | select(.status == "available")
                 | (.expiresAt | as_num) | select(. != null)] | min)
          else null end),
       credits_remaining_usd:
         (($s.creditBalanceUsd // ($s.credits | obj | .balanceUsd) // null) | as_num)}
    | with_entries(select(.value != null))' "$1" 2>/dev/null \
    || printf '{}'
}

codex_render_snapshot() { # <label> <email> <snapshot-json-file> <source> [<note>]
  local label="$1" email="$2" snap="$3" source="$4"
  local note="${5:-}"
  local plan weekly five rendered=0 weekly_ok=0 weekly_is_short=0 used resets dur
  local live

  plan="$(jq -r '.planType // empty' "$snap" 2>/dev/null || true)"
  live="$(codex_live_overage "$snap")"
  printf '%s' "$live" | jq -e 'type == "object"' >/dev/null 2>&1 || live="{}"
  local exp_epoch exp_date
  exp_epoch="$(printf '%s' "$live" | jq -r '.free_reset_expires_epoch // empty' 2>/dev/null || true)"
  exp_date="$(epoch_to_et_datetime_short "$exp_epoch")"
  if [[ -n "$exp_date" ]]; then
    live="$(printf '%s' "$live" | jq -c --arg d "$exp_date" '. + {free_reset_expires_et_short: $d}' 2>/dev/null || printf '%s' "$live")"
  fi
  weekly="$(jq -c '[.primary, .secondary] | map(select(. != null))
                   | (map(select(.windowDurationMins == 10080)) | first)
                     // (map(select(.windowDurationMins != null))
                         | sort_by(.windowDurationMins) | last)
                     // first
                   // empty' "$snap" 2>/dev/null || true)"

  if [[ -n "$weekly" ]]; then
    used="$(printf '%s' "$weekly" | jq -r '.usedPercent // empty')"
    resets="$(to_epoch_maybe "$(printf '%s' "$weekly" | jq -r '.resetsAt // empty')")"
    dur="$(printf '%s' "$weekly" | jq -r '.windowDurationMins // empty')"
    # Three cases, because "7-day" is a CLAIM about the window, not a default.
    # A window whose duration the payload did not report is not weekly just
    # because the weekly slot is where we looked for it — labelling it
    # `7-day` would put a number under a heading that may be wrong, which is
    # the failure this whole selector exists to avoid.
    local window detail="$note"
    if [[ "$dur" == "10080" ]]; then
      window="7-day"
    elif [[ "$dur" =~ ^[0-9]+$ ]]; then
      window="$(( dur / 60 ))-hour"
      weekly_is_short=1
      detail="${note:+${note}; }no 7-day window reported; showing the longest window this plan reports"
    else
      window="window"
      detail="${note:+${note}; }this plan did not report the window's duration"
    fi
    # The window LENGTH is the one thing Codex does report, so the start is a
    # subtraction rather than a guess — and it is skipped exactly where the
    # duration was missing, which is the `window` case above.
    local wspan=""
    [[ ! "$dur" =~ ^[0-9]+$ ]] || wspan=$(( dur * 60 ))
    emit_row codex "$label" "$email" "$window" "$used" "$resets" ok "$detail" "$source" "$plan" \
      "$(with_window_start "$live" "$resets" "$wspan")"
    rendered=1
    weekly_ok=1
  fi

  if [[ "$FIVE_HOUR" -eq 1 ]]; then
    # Exclude the slot the weekly row already rendered. When a plan reports one
    # window and it is shorter than a week, the weekly selector's
    # longest-window fallback renders THAT window; without this exclusion the
    # short selector picks the same slot again and `--five-hour` prints one
    # window as two rows differing only in the note.
    five="$(jq -c --argjson shown "${weekly:-null}" \
                  '[.primary, .secondary] | map(select(. != null))
                   | map(select(. != $shown))
                   | map(select(.windowDurationMins != null and .windowDurationMins < 10080))
                   | sort_by(.windowDurationMins) | first // empty' "$snap" 2>/dev/null || true)"
    if [[ -n "$five" ]]; then
      used="$(printf '%s' "$five" | jq -r '.usedPercent // empty')"
      resets="$(to_epoch_maybe "$(printf '%s' "$five" | jq -r '.resetsAt // empty')")"
      dur="$(printf '%s' "$five" | jq -r '.windowDurationMins // empty')"
      local flabel="5-hour"
      [[ -n "$dur" && "$dur" != "300" ]] && flabel="$(( dur / 60 ))-hour"
      local fspan=""
      [[ ! "$dur" =~ ^[0-9]+$ ]] || fspan=$(( dur * 60 ))
      emit_row codex "$label" "$email" "$flabel" "$used" "$resets" ok "$note" "$source" "$plan" \
        "$(with_window_start "$live" "$resets" "$fspan")"
      rendered=1
    elif [[ "$weekly_is_short" -eq 1 ]]; then
      # The only sub-weekly window this plan reports is the row above, which
      # already carries its real duration and says why it is standing in for a
      # weekly one. Printing it again would duplicate it; claiming the plan
      # reports no short window would contradict the row directly above it.
      :
    elif [[ "$weekly_ok" -eq 1 ]]; then
      # A single-window response is valid, not an error — say so instead of
      # dropping the row the flag promised. Gated on the weekly row having
      # rendered, because that is the proof this really was a rate-limits
      # snapshot: emitting "this plan reports no short window" for a payload
      # we could not parse AT ALL would report a fact about the plan that we
      # never established, and would mark the whole read as successful — so
      # `--five-hour` would suppress the unrecognised-shape row that the same
      # payload produces without the flag.
      emit_row codex "$label" "$email" "5-hour" "" "" ok \
        "${note:+${note}; }this plan reports no short window" "$source" "$plan" "$live"
      rendered=1
    fi
  fi

  [[ "$rendered" -eq 1 ]]
}

codex_http_fallback() { # <label> <profile_dir> <email> <why>
  local label="$1" dir="$2" email="$3" why="$4"
  local body="$TMP/codex-http.json" hdrs="$TMP/codex-http-hdrs.txt"
  local token account code rc=0 snap="$TMP/codex-http-snap.json"

  token="$(jq -r '.tokens.access_token // empty' "$dir/auth.json" 2>/dev/null || true)"
  account="$(jq -r '.tokens.account_id // .account_id // empty' "$dir/auth.json" 2>/dev/null || true)"
  if [[ -z "$token" ]]; then
    set_outcome logged_out credential-store credential_unavailable
    emit_row codex "$label" "$email" "7-day" "" "" needs-login \
      "${why}; auth.json holds no access token — run: $(relogin_hint codex "$label")" "http" ""
    return 0
  fi

  : > "$body"; : > "$hdrs"
  code="$(printf 'header = "Authorization: Bearer %s"\n' "$token" \
    | "$CURL_BIN" -sS --max-time "$HTTP_TIMEOUT" \
        -o "$body" -D "$hdrs" -w '%{http_code}' \
        -H "ChatGPT-Account-Id: ${account}" \
        -H "Accept: application/json" \
        -K - "$CHATGPT_URL" 2>/dev/null)" || rc=$?
  token=""

  if [[ "$rc" -ne 0 || -z "$code" ]]; then
    transport_outcome "$rc" http
    emit_row codex "$label" "$email" "7-day" "" "" unreachable \
      "${why}; curl failed (exit ${rc:-?}) talking to ${CHATGPT_URL}" "http" ""
    return 0
  fi
  if [[ "$code" == "429" ]]; then
    emit_row codex "$label" "$email" "7-day" "" "" rate-limited \
      "${why}; the usage endpoint rate-limited this read" "http" ""
    return 0
  fi
  if [[ "$code" == "401" || "$code" == "403" ]]; then
    emit_row codex "$label" "$email" "7-day" "" "" needs-login \
      "${why}; the usage endpoint rejected this credential (HTTP ${code}) — run: $(relogin_hint codex "$label")" "http" ""
    return 0
  fi
  if [[ "$code" != "200" ]] || ! jq -e . "$body" >/dev/null 2>&1; then
    if [[ "$code" == "200" ]]; then set_outcome parse_error http invalid_json
    else set_outcome unreadable http "http_${code}"; fi
    emit_row codex "$label" "$email" "7-day" "" "" unreachable \
      "${why}; usage endpoint answered HTTP ${code}" "http" ""
    return 0
  fi

  # The captured wham wire body is snake_case and expresses duration in
  # seconds. Normalize only this boundary; app-server keeps its own contract.
  # A reset is an absolute Unix second when supplied, otherwise a validated
  # relative interval on the reader's existing clock. Never invent USD from
  # the unlabelled credits.balance or guess an unsupported duration's unit.
  # The shared renderer labels whole hours; fractional-hour wire windows
  # therefore remain unreadable rather than being truncated to a false label.
  jq --argjson now "$NOW" '
      def num:
        if type == "number" then (if isfinite then . else null end)
        elif type == "string" and test("^[0-9]+(\\.[0-9]+)?$")
        then (tonumber | if isfinite then . else null end)
        else null end;
      def whole:
        num | if . == null then null
              elif . >= 0 and . == floor then . else null end;
      def wire_window:
        if type != "object" then null else
          . as $w | ($w.used_percent | num) as $pct
          | ($w.limit_window_seconds | whole) as $seconds
          | ($w.reset_at | whole) as $absolute
          | ($w.reset_after_seconds | whole) as $relative
          | if $pct == null or $pct < 0
               or ($w.limit_window_seconds != null and
                   ($seconds == null or $seconds == 0 or $seconds % 3600 != 0))
            then null else
              {usedPercent:$pct,
               windowDurationMins:(if $seconds != null then $seconds / 60 else null end),
               resetsAt:(if $absolute != null then $absolute
                         elif $relative != null then $now + $relative else null end)}
            end
        end;
      . as $top
      | (if (.rate_limit | type) == "object" then
           (.rate_limit.primary_window | wire_window) as $primary
           | (.rate_limit.secondary_window | wire_window) as $secondary
           | if (.rate_limit.primary_window != null and $primary == null)
                or (.rate_limit.secondary_window != null and $secondary == null)
             then null
             else {planType:(if (.plan_type | type) == "string" then .plan_type else null end),
                   primary:$primary, secondary:$secondary}
             end
         else (.rate_limits // .rateLimits // .usage.rateLimits // .) end) as $s
      | if ($s | type) == "object" and ($top.rate_limit_reset_credits | type) == "object"
        then $s + {rate_limit_reset_credits: $top.rate_limit_reset_credits}
        else $s end' "$body" > "$snap" 2>/dev/null || : > "$snap"
  if ! codex_render_snapshot "$label" "$email" "$snap" "http" "$why"; then
    set_outcome parse_error http response_shape
    local keys
    keys="$(jq -r 'if type == "object" then (keys_unsorted | join(", ")) else type end' "$body" 2>/dev/null || echo "unreadable")"
    emit_row codex "$label" "$email" "7-day" "" "" unreachable \
      "${why}; unrecognised response shape; top-level keys seen: ${keys}" "http" ""
  fi
  return 0
}

read_codex_account() { # <label> <profile_dir>
  local label="$1" dir="$2" source="${3:-app-server}"
  local email bin snap="$TMP/codex-snap.json" logged_in=0

  email="$(codex_email_for "$dir")"

  if [[ -s "$dir/auth.json" ]]; then
    logged_in=1
  elif bin="$(codex_bin)"; then
    probe 10 env "CODEX_HOME=$dir" "$bin" login status && logged_in=1
  fi
  if [[ "$logged_in" -eq 0 ]]; then
    emit_row codex "$label" "$email" "7-day" "" "" needs-login \
      "no auth.json in ${dir} — run: $(relogin_hint codex "$label")" "" ""
    return 0
  fi

  if [[ "$source" == "http" ]]; then
    codex_http_fallback "$label" "$dir" "$email" "${SOURCE_WHY:-preferred HTTP source}"
    return 0
  fi
  if bin="$(codex_bin)"; then
    if codex_app_server_read "$dir" "$bin"; then
      # The first match is picked INSIDE jq. Piping into `head -n 1` under
      # `pipefail` means head closes the pipe, jq dies of SIGPIPE, the
      # pipeline reports failure, and the `|| :` then truncates the snapshot
      # jq had just written correctly — a good read discarded by its own
      # error handling, and only when more than one line matches.
      # `rateLimitResetCredits` is a SIBLING of `rateLimits` in the reply, not
      # a child (#1862). Carry it into the snapshot, or the balance Codex shows
      # in its own banner is thrown away here.
      jq -sc 'map(select(.id == 2) | (.result // empty) | select(.rateLimits != null)
                  | (.rateLimits + {rateLimitResetCredits: (.rateLimitResetCredits // null)}))
              | first // empty' \
        "$CODEX_RESULT_FILE" > "$snap" 2>/dev/null || : > "$snap"
      if [[ -s "$snap" ]] && codex_render_snapshot "$label" "$email" "$snap" "app-server"; then
        return 0
      fi
      local rpc_err
      rpc_err="$(jq -sr 'map(select(.id == 2) | (.error.message // empty)) | first // empty' \
        "$CODEX_RESULT_FILE" 2>/dev/null || true)"
      emit_row codex "$label" "$email" "7-day" "" "" unreachable "app-server returned no rate limits${rpc_err:+ (${rpc_err})}" app-server ""
      return 0
    fi
    emit_row codex "$label" "$email" "7-day" "" "" unreachable "${CODEX_FAIL_REASON:-app-server did not answer}" app-server ""
    return 0
  fi

  emit_row codex "$label" "$email" "7-day" "" "" unreachable "no codex CLI found" app-server ""
  return 0
}
