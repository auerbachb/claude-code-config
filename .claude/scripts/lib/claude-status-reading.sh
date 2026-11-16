#!/usr/bin/env bash
# claude-status-reading.sh — Save and read the Claude usage figures the status line is handed.
# catalog: scheduling-monitoring — Sourced library: statusline.sh saves the `rate_limits` figures Claude Code passes it to one private file per registered account; ai-quotas-claude.sh reads that file back, so /quotas and the weekly reserve need no token
#
# Sourced, never executed. Two callers share it so the file layout lives in one
# place:
#   statusline.sh        csr_save_from_session   (every status-line render)
#   ai-quotas-claude.sh  csr_load / csr_window   (every /quotas read)
#
# WHAT IS SAVED. The whole `rate_limits` object exactly as handed over (including
# `spend_limit` when present), `subscription_type`, the capture time (epoch and
# UTC ISO-8601), the account label, and a normalised `windows` view the reader
# uses. Later readers (fetched, resets, paid-usage columns) take their fields from
# this one file. Nothing else from the payload is copied, so a credential sitting
# elsewhere in it cannot reach the file. Mode 600 in a mode 700
# folder, written to a temp file and moved into place.
#
# WHICH ACCOUNT. The session's own .claude.json names the signed-in email; the
# registry (~/.claude/ai-quotas.json) names each Claude account's label, and a
# profile's .claude.json (or an email-shaped label) names its email. The reading
# is filed under the ONE registered account whose email matches. Never by folder
# name (Issue #1850), and never when zero or several accounts match: a reading
# that cannot be attributed is dropped, not guessed.
#
# NO NETWORK. This runs on every status-line render (every 10 seconds), so it
# reads and writes local files only.
#
# Test seams: AI_QUOTAS_STATUSLINE_DIR, AI_QUOTAS_CONFIG, AI_QUOTAS_NOW.

CSR_THROTTLE_SECONDS=60

csr_home_dir() { printf '%s' "${AI_QUOTAS_STATUSLINE_DIR:-${HOME:-}/.claude/ai-quotas/status-line}"; }

# A label becomes part of a file name. Anything outside a plain email/name
# alphabet is refused rather than escaped.
csr_label_ok() { [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._@+-]*$ && "$1" != *..* ]]; }

# A second producer files its reading BESIDE the status line's, never over it:
# the desktop app runs no status line, so its agent saves what the app's usage
# tool returned (claude-usage-observe.sh, #2404). The reader takes the newer of
# the two.
csr_file_for() { # <label> [status-line|app-usage-tool]
  csr_label_ok "$1" || return 1
  [[ -n "${HOME:-}" || -n "${AI_QUOTAS_STATUSLINE_DIR:-}" ]] || return 1
  case "${2:-status-line}" in
    status-line) printf '%s/claude--%s.json' "$(csr_home_dir)" "$1" ;;
    app-usage-tool) printf '%s/claude-app--%s.json' "$(csr_home_dir)" "$1" ;;
    *) return 1 ;;
  esac
}

# The email a registered account is expected to be signed in as: its profile's
# own .claude.json when readable (never a symlink), else an email-shaped label.
csr_account_email() { # <label> <profile_dir>
  local label="$1" dir="$2" email=""
  if [[ -n "$dir" && -f "$dir/.claude.json" && ! -L "$dir/.claude.json" ]]; then
    email="$(jq -r '.oauthAccount.emailAddress // empty' "$dir/.claude.json" 2>/dev/null || true)"
  fi
  if [[ -z "$email" && "$label" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]; then
    email="$label"
  fi
  printf '%s' "$email" | tr '[:upper:]' '[:lower:]'
}

# Prints the registered Claude account label whose email equals <email>
# (case-insensitive exact equality), or nothing when zero or several match.
csr_label_for_email() { # <email>
  local cfg="${AI_QUOTAS_CONFIG:-${HOME:-}/.claude/ai-quotas.json}"
  local session_email label dir acct_email match="" matches=0
  session_email="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
  [[ -r "$cfg" && -n "$session_email" ]] || return 0
  while IFS=$'\t' read -r label dir; do
    [[ -n "$label" ]] || continue
    acct_email="$(csr_account_email "$label" "$dir")"
    if [[ -n "$acct_email" && "$acct_email" == "$session_email" ]]; then
      if [[ "$label" != "$match" ]]; then matches=$((matches + 1)); fi
      match="$label"
    fi
  done < <(jq -r '(.accounts // [])[] | select(.provider == "claude" and (.label | type) == "string" and (.profile_dir | type) == "string") | [.label, .profile_dir] | @tsv' "$cfg" 2>/dev/null)
  [[ "$matches" -eq 1 ]] && printf '%s' "$match"
  return 0
}

# Prints the registered Claude account label for the running session, or nothing.
csr_resolve_label() {
  local cj="${CLAUDE_CONFIG_DIR:-${HOME:-}}/.claude.json"
  [[ -f "$cj" ]] || return 0
  csr_label_for_email "$(jq -r '.oauthAccount.emailAddress // empty' "$cj" 2>/dev/null)"
}

# Save the rate_limits of one status-line payload. <session-json> is the raw
# stdin of the status line. Silent; returns 0 when it saved or had nothing to
# save, non-zero only on a write failure (the caller ignores it).
csr_save_from_session() { # <session-json>
  local json="$1" now label file dir tmp doc old
  [[ "$json" == *rate_limits* ]] || return 0
  now="${AI_QUOTAS_NOW:-$(date -u +%s)}"
  [[ "$now" =~ ^[0-9]+$ ]] || return 0
  doc="$(printf '%s' "$json" | jq -c --argjson now "$now" '
      def pct: if type == "number" and . >= 0 and . <= 100 then (. * 10 | round / 10) else empty end;
      def ep: if type == "number" and . > 0 then (if . > 253402300799 then (. / 1000 | floor) else floor end) else empty end;
      def win($k): (.rate_limits[$k] // null) as $w
        | (if ($w | type) == "object" then ([$w.used_percentage | pct] | first // null) else null end) as $p
        | (if ($w | type) == "object" then ([$w.resets_at | ep] | first // null) else null end) as $r
        | if $p != null and $r != null then {($k): {used_pct: $p, resets_at_epoch: $r}} else {} end;
      (win("seven_day") + win("five_hour")) as $w
      | if ($w | length) == 0 then empty
        else {schema_version: "1.0", provider: "claude", captured_at_epoch: $now,
             captured_at: ($now | todate), subscription_type: (.subscription_type // null),
             rate_limits: .rate_limits, windows: $w} end' 2>/dev/null)" || return 0
  [[ -n "$doc" ]] || return 0
  label="$(csr_resolve_label)"
  [[ -n "$label" ]] || return 0
  file="$(csr_file_for "$label")" || return 0
  dir="$(dirname "$file")"
  # Skip the write when nothing moved and the file is recent.
  if [[ -f "$file" ]]; then
    old="$(jq -c --argjson now "$now" --argjson t "$CSR_THROTTLE_SECONDS" --argjson new "$doc" \
        'select(.rate_limits == $new.rate_limits and .subscription_type == $new.subscription_type and ((.captured_at_epoch // 0) | type) == "number"
                and ($now - .captured_at_epoch) >= 0 and ($now - .captured_at_epoch) < $t) | "same"' "$file" 2>/dev/null || true)"
    [[ -z "$old" ]] || return 0
  fi
  doc="$(printf '%s' "$doc" | jq -c --arg l "$label" '. + {account_label: $l}' 2>/dev/null)" || return 0
  ( umask 077
    mkdir -p "$dir" 2>/dev/null && chmod 700 "$dir" 2>/dev/null
    tmp="$(mktemp "$dir/.claude-reading.XXXXXX" 2>/dev/null)" || exit 1
    if printf '%s\n' "$doc" > "$tmp" 2>/dev/null && chmod 600 "$tmp" 2>/dev/null && mv -f "$tmp" "$file" 2>/dev/null; then
      exit 0
    fi
    rm -f "$tmp"
    exit 1 )
}

# Reader side ---------------------------------------------------------------

CSR_STATE=""        # fresh | stale | absent | invalid
CSR_AGE=""          # seconds since capture
CSR_FILE=""

# Classify the saved reading for <label>. <max-age> is seconds.
csr_load() { # <label> <now> <max-age> [status-line|app-usage-tool]
  local label="$1" now="$2" max="$3" captured
  CSR_STATE="absent"; CSR_AGE=""; CSR_FILE=""
  CSR_FILE="$(csr_file_for "$label" "${4:-status-line}")" || return 1
  [[ -f "$CSR_FILE" && ! -L "$CSR_FILE" ]] || return 1
  captured="$(jq -r 'if .provider == "claude" and (.account_label | type) == "string"
                        and (.captured_at_epoch | type) == "number"
                     then "\(.account_label)\t\(.captured_at_epoch | floor)" else empty end' "$CSR_FILE" 2>/dev/null || true)"
  if [[ -z "$captured" || "${captured%%$'\t'*}" != "$label" ]]; then CSR_STATE="invalid"; return 1; fi
  captured="${captured#*$'\t'}"
  CSR_AGE=$(( now - captured ))
  if [[ "$CSR_AGE" -lt 0 ]]; then CSR_STATE="invalid"; return 1; fi
  if [[ "$CSR_AGE" -gt "$max" ]]; then CSR_STATE="stale"; return 1; fi
  CSR_STATE="fresh"
  return 0
}

# Prints "<used_pct> <resets_at_epoch>" for a window in the loaded file, or nothing.
csr_window() { # <seven_day|five_hour>
  jq -r --arg k "$1" '.windows[$k] // empty | select((.used_pct | type) == "number" and .used_pct >= 0 and .used_pct <= 100 and (.resets_at_epoch | type) == "number") | "\(.used_pct) \(.resets_at_epoch)"' "$CSR_FILE" 2>/dev/null || true
}

# App usage tool side (#2404) -----------------------------------------------
#
# The desktop app runs no status line, so its agent calls the app's usage tool
# (mcp__ccd_session_mgmt__get_usage) and hands the result to
# claude-usage-observe.sh, which calls csr_observe_app. The saved file has the
# same `windows` shape the reader already uses, with `source` "app-usage-tool",
# plus two blocks kept for later readers and not rendered yet: `extra_usage`
# (the tool's extraUsage object) and `weekly_models` (the per-model weekly
# windows). Only fields named here are copied, so nothing else the tool returns
# can reach the file.
#
# Prints one line and returns 0 on success; sets CSR_OBSERVE_REASON and returns
# 1 when the input is refused or cannot be saved.
CSR_OBSERVE_REASON=""

# The jq program lives in a variable, not inside $( ): bash 3.2 counts parens
# in a command substitution and misparses a program this size.
CSR_OBSERVE_JQ='
  def pct: if type == "number" and . >= 0 and . <= 100 then (. * 10 | round / 10) else null end;
  def ep: if type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}([.][0-9]+)?Z$")
          then (try (sub("[.][0-9]+Z$"; "Z") | fromdateiso8601) catch null) else null end;
  def lbl: (.label // "" | if type == "string" then . else "" end);
  def weekly: (lbl | test("^weekly"; "i"));
  def allmodels: (lbl | test("all models"; "i"));
  def fivehour: (lbl | test("(5|five)[ -]?h"; "i"));
  def str: if type == "string" or type == "number" then tostring else null end;
  (if type != "object" then null elif (.plan | type) == "object" then .plan elif has("status") then . else null end) as $p
  | if $p == null then {err: "the input is not the usage tool result or its plan object"}
    elif $p.status != "ok" then {err: ("plan status is " + ($p.status | tostring) + ", not ok")}
    elif ($p.windows | type) != "array" then {err: "the plan names no windows"}
    else
      ([$p.windows[] | select(type == "object" and weekly and allmodels)]) as $w
      | if ($w | length) == 0 then {err: "no weekly all-models window"}
        elif ($w | length) > 1 then {err: "several weekly all-models windows"}
        elif ($w[0].percentUsed | pct) == null then {err: "the weekly all-models percentUsed is not a number from 0 to 100"}
        elif ($w[0].resetsAt | ep) == null then {err: "the weekly all-models reset time is not a UTC ISO-8601 timestamp"}
        else
          ([$p.windows[] | select(type == "object" and fivehour and (weekly | not))
            | {used_pct: (.percentUsed | pct), resets_at_epoch: (.resetsAt | ep)}
            | select(.used_pct != null and .resets_at_epoch != null)] | first // null) as $f
          | {doc: {schema_version: "1.0", provider: "claude", source: "app-usage-tool",
                   captured_at_epoch: $now, captured_at: ($now | todate),
                   subscription_type: (if ($p.plan | type) == "string" then ($p.plan | ascii_downcase) else null end),
                   windows: ({seven_day: {used_pct: ($w[0].percentUsed | pct), resets_at_epoch: ($w[0].resetsAt | ep)}}
                             + (if $f == null then {} else {five_hour: $f} end)),
                   weekly_models: [$p.windows[] | select(type == "object" and weekly and (allmodels | not))
                                   | {label: lbl, used_pct: (.percentUsed | pct), resets_at_epoch: (.resetsAt | ep)}
                                   | select(.used_pct != null and .resets_at_epoch != null)],
                   extra_usage: (if ($p.extraUsage | type) == "object" then
                                   {enabled: ($p.extraUsage.enabled == true), used_pct: ($p.extraUsage.percentUsed | pct),
                                    spent: ($p.extraUsage.spent | str), monthly_limit: ($p.extraUsage.monthlyLimit | str),
                                    currency: (if ($p.extraUsage.currency | type) == "string" then $p.extraUsage.currency else null end)}
                                 else null end)}}
        end
    end'

csr_observe_app() { # <tool-json>
  local json="$1" now email label file dir tmp doc res
  CSR_OBSERVE_REASON=""
  now="${AI_QUOTAS_NOW:-$(date -u +%s)}"
  [[ "$now" =~ ^[0-9]+$ ]] || { CSR_OBSERVE_REASON="the clock is unreadable"; return 1; }
  # Slurped: exactly one JSON value is accepted, never the first of several.
  res="$(printf '%s' "$json" | jq -c -s --argjson now "$now" "if length != 1 then {err: \"expected exactly one JSON value\"} else .[0] | $CSR_OBSERVE_JQ end" 2>/dev/null)" || res=""
  if [[ -z "$res" ]]; then CSR_OBSERVE_REASON="the input is not valid JSON"; return 1; fi
  if [[ "$(printf '%s' "$res" | jq -r 'has("err")')" == "true" ]]; then
    CSR_OBSERVE_REASON="$(printf '%s' "$res" | jq -r '.err')"; return 1
  fi
  email="${CLAUDE_CODE_USER_EMAIL:-}"
  [[ -n "$email" ]] || { CSR_OBSERVE_REASON="CLAUDE_CODE_USER_EMAIL is not set, so the account cannot be named"; return 1; }
  label="$(csr_label_for_email "$email")"
  [[ -n "$label" ]] || { CSR_OBSERVE_REASON="CLAUDE_CODE_USER_EMAIL matches no registered Claude account, or matches several"; return 1; }
  file="$(csr_file_for "$label" app-usage-tool)" || { CSR_OBSERVE_REASON="the account label cannot name a file"; return 1; }
  doc="$(printf '%s' "$res" | jq -c --arg l "$label" '.doc + {account_label: $l}')" || { CSR_OBSERVE_REASON="could not build the reading"; return 1; }
  dir="$(dirname "$file")"
  if ( umask 077
       mkdir -p "$dir" 2>/dev/null && chmod 700 "$dir" 2>/dev/null
       tmp="$(mktemp "$dir/.claude-app-reading.XXXXXX" 2>/dev/null)" || exit 1
       if printf '%s\n' "$doc" > "$tmp" 2>/dev/null && chmod 600 "$tmp" 2>/dev/null && mv -f "$tmp" "$file" 2>/dev/null; then
         exit 0
       fi
       rm -f "$tmp"
       exit 1 ); then
    printf 'saved the app usage tool reading for %s (7-day %s%% used)\n' "$label" "$(printf '%s' "$doc" | jq -r '.windows.seven_day.used_pct')"
    return 0
  fi
  CSR_OBSERVE_REASON="the reading could not be written"
  return 1
}
