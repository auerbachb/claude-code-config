#!/usr/bin/env bash
# Sourced by ai-quotas.sh. Google Antigravity reader (Issue #2407): display only.
#
# Sources, in the order the account's `sources` lists them (default backend,observation):
#   backend      read_antigravity_backend: asks Google's quota service for the figures with the
#                token agy holds in the keychain (Issue #2465), saves the response as the
#                observation, then shows it. The token lives in lib/quotas-antigravity.py's
#                memory for the request only; nothing here sees, prints or stores it.
#   observation  read_antigravity_account: an observation file holding either that saved
#                response or the text of the `agy` `/usage` panel, plus its capture time
#                (quotas-antigravity-capture.sh). Stale rules apply to both.
# Antigravity never feeds `quota-reserve.sh` (it keeps only Claude and Codex rows).
# Contract and sample: .claude/reference/ai-quotas-antigravity.md.

ANTIGRAVITY_HINT="sign in by running agy, then re-run /quotas (or paste the agy /usage panel into quotas-antigravity-capture.sh)"
ANTIGRAVITY_BACKEND_WHY=""

antigravity_observation_file() {
  if [[ -n "${AI_QUOTAS_ANTIGRAVITY_OBSERVATION:-}" ]]; then
    printf '%s' "$AI_QUOTAS_ANTIGRAVITY_OBSERVATION"
  else
    printf '%s' "${_HOME}/.claude/ai-quotas-antigravity.json"
  fi
}

# "3h 5m" style age; the same shape the countdown uses, without the leading "in".
antigravity_age() { # <seconds>
  local s="$1" d h m
  d=$(( s / 86400 )); h=$(( (s % 86400) / 3600 )); m=$(( (s % 3600) / 60 ))
  if [[ "$d" -gt 0 ]]; then printf '%dd %dh' "$d" "$h"
  elif [[ "$h" -gt 0 ]]; then printf '%dh %dm' "$h" "$m"
  else printf '%dm' "$m"; fi
}

# Fetch fresh figures from the backend, then show them. A saved reading younger than
# AI_QUOTAS_ANTIGRAVITY_REFRESH_SECONDS (default 300) is shown as is, so repeated runs do
# not call Google each time (only a backend reading with no window past its reset counts). The failure reason is kept for the observation fallback.
read_antigravity_backend() { # <label>
  local label="$1" obs saved result status min_age next_step error_class reason
  ANTIGRAVITY_BACKEND_WHY=""
  obs="$(antigravity_observation_file)"
  if ! command -v python3 >/dev/null 2>&1 || [[ ! -r "$SELF_DIR/lib/quotas-antigravity.py" ]]; then
    ANTIGRAVITY_BACKEND_WHY="Antigravity parser unavailable (python3 or lib/quotas-antigravity.py missing)"
    set_outcome unreadable backend reader_unavailable
    emit_row antigravity "$label" "" "usage" "" "" unreadable "$ANTIGRAVITY_BACKEND_WHY" backend ""
    return 0
  fi
  min_age=300
  [[ -z "${AI_QUOTAS_ANTIGRAVITY_REFRESH_SECONDS:-}" ]] \
    || min_age="$(positive_int_or_default "$AI_QUOTAS_ANTIGRAVITY_REFRESH_SECONDS" 300 AI_QUOTAS_ANTIGRAVITY_REFRESH_SECONDS)"
  saved="$(python3 -I "$SELF_DIR/lib/quotas-antigravity.py" show "$obs" "$NOW" 2>/dev/null || true)"
  if [[ "$(printf '%s' "$saved" | jq -r --argjson m "$min_age" --argjson now "$NOW" 'if .status == "ok" and .via == "backend" and (.age_seconds | type) == "number" and .age_seconds <= $m
         and ([.groups[].windows[].resets_at_epoch | select(. != null and . <= $now)] | length) == 0 then "fresh" else "" end' 2>/dev/null || true)" == fresh ]]; then
    read_antigravity_account "$label" backend
    return 0
  fi
  result="$(python3 -I "$SELF_DIR/lib/quotas-antigravity.py" backend "$NOW" "$obs" 2>/dev/null || true)"
  status="$(printf '%s' "$result" | jq -r '.status // "unreadable"' 2>/dev/null || echo unreadable)"
  if [[ "$status" == ok ]]; then
    read_antigravity_account "$label" backend
    return 0
  fi
  error_class="$(printf '%s' "$result" | jq -r '.error_class // "unclassified"' 2>/dev/null || echo unclassified)"
  [[ "$error_class" =~ ^[a-z0-9_]{1,32}$ ]] || error_class=unclassified
  reason="$(printf '%s' "$result" | jq -r '.reason // "the Google usage read failed"' 2>/dev/null | tr -d '\000-\037\177' | cut -c1-200)"
  [[ -n "$reason" ]] || reason="the Google usage read failed"
  case "$error_class" in
    token_missing|token_expired|http_401|http_403) next_step="run agy and sign in, then re-run /quotas" ;;
    http_429) next_step="wait a few minutes and re-run /quotas" ;;
    *) next_step="re-run /quotas, or paste the agy /usage panel into quotas-antigravity-capture.sh" ;;
  esac
  ANTIGRAVITY_BACKEND_WHY="Google usage read failed: ${reason} — ${next_step}"
  case "$error_class" in
    token_missing|token_expired|http_401|http_403) set_outcome logged_out backend "$error_class" ;;
    http_429) set_outcome rate_limited backend http_429 ;;
    network) set_outcome timeout backend network ;;
    response_shape) set_outcome parse_error backend response_shape ;;
    *) set_outcome unreadable backend "$error_class" ;;
  esac
  emit_row antigravity "$label" "" "usage" "" "" unreadable "$ANTIGRAVITY_BACKEND_WHY" backend ""
  return 0
}

read_antigravity_account() { # <label> [<source-name>]
  local label="$1" row_source="${2:-observation}" obs result status account age stale_after captured via_note why
  obs="$(antigravity_observation_file)"
  why="${ANTIGRAVITY_BACKEND_WHY:+; ${ANTIGRAVITY_BACKEND_WHY}}"
  if ! command -v python3 >/dev/null 2>&1 || [[ ! -r "$SELF_DIR/lib/quotas-antigravity.py" ]]; then
    set_outcome unreadable "$row_source" reader_unavailable
    emit_row antigravity "$label" "" "usage" "" "" unreadable "Antigravity parser unavailable (python3 or lib/quotas-antigravity.py missing)" "$row_source" ""
    return 0
  fi
  result="$(python3 -I "$SELF_DIR/lib/quotas-antigravity.py" show "$obs" "$NOW" 2>/dev/null || true)"
  status="$(printf '%s' "$result" | jq -r '.status // "unreadable"' 2>/dev/null || echo unreadable)"
  case "$status" in
    ok) ;;
    missing)
      set_outcome unreadable "$row_source" observation_missing
      emit_row antigravity "$label" "" "usage" "" "" unreadable "no Antigravity reading yet${why} — ${ANTIGRAVITY_HINT}" "$row_source" ""
      return 0 ;;
    *)
      set_outcome parse_error "$row_source" response_shape
      emit_row antigravity "$label" "" "usage" "" "" unreadable \
        "saved Antigravity text is unreadable ($(printf '%s' "$result" | jq -r '.reason // "unknown reason"' 2>/dev/null))${why} — ${ANTIGRAVITY_HINT}" "$row_source" ""
      return 0 ;;
  esac
  account="$(printf '%s' "$result" | jq -r '.account // "" | gsub("[\u0000-\u001f\u007f]"; "")')"
  age="$(printf '%s' "$result" | jq -r '.age_seconds')"
  captured="$(printf '%s' "$result" | jq -r '.captured_at_epoch')"
  via_note="$(printf '%s' "$result" | jq -r '.via | if . == "backend" then "Google backend" elif . == "agy-print" then "agy -p /usage" elif . == "pasted" then "pasted /usage text" else "saved /usage text" end')"

  # Label rows by what the saved reading really is: a manual capture that replaced the
  # backend reading between the check and this read must not be credited to Google.
  [[ "$row_source" != backend || "$(printf '%s' "$result" | jq -r '.via')" == backend ]] || row_source=observation

  stale_after=10800
  [[ -z "${AI_QUOTAS_ANTIGRAVITY_STALE_SECONDS:-}" ]] \
    || stale_after="$(positive_int_or_default "$AI_QUOTAS_ANTIGRAVITY_STALE_SECONDS" 10800 AI_QUOTAS_ANTIGRAVITY_STALE_SECONDS)"
  local line window used resets group models fet_et res_et top
  fet_et="$(epoch_to_et "$captured")"
  # The top tier (#2415): the group the panel prints with no "Models within this group"
  # line, because it is a single named model with its own allowance ("<VENDOR> <N> <NAME>").
  # Its label is the last word of the printed group name, its percent is USED (the
  # panel prints remaining), and it is taken from the weekly window when there is one.
  # The first such group wins. A window whose reset passed since the capture, or a
  # capture older than the stale cutoff, shows nothing rather than an old figure.
  top="$(printf '%s' "$result" | jq -c --argjson now "$NOW" '
    ([.groups[] | select((.models | length) == 0 and .slug != "unknown")][0]) as $g
    | if $g == null then {}
      else ([$g.windows[] | select(.name == "7-day")][0] // $g.windows[0]) as $w
        | (($g.name | gsub("[\u0000-\u001f\u007f]"; "") | split(" ") | map(select(. != "")) | last | if . == null then null else .[0:20] end) // null) as $l
        | if $w == null or $l == null or ($w.resets_at_epoch != null and $w.resets_at_epoch <= $now) then {}
          else {top_label: $l, top_used_pct: $w.used_pct, top_resets_at_epoch: $w.resets_at_epoch} end
      end' 2>/dev/null || printf '{}')"
  [[ -n "$top" ]] || top="{}"
  [[ "$age" -le "$stale_after" ]] || top="{}"
  while IFS= read -r line; do
    window="$(printf '%s' "$line" | jq -r '.window')"
    used="$(printf '%s' "$line" | jq -r '.used_pct')"
    resets="$(printf '%s' "$line" | jq -r '.resets_at_epoch // ""')"
    group="$(printf '%s' "$line" | jq -r '.group')"
    models="$(printf '%s' "$line" | jq -c '.models')"
    # Stale: older than the cutoff, or the window's own reset passed after the capture.
    if [[ "$age" -gt "$stale_after" ]] || { [[ -n "$resets" ]] && [[ "$resets" -le "$NOW" ]]; }; then
      res_et="$(epoch_to_et "$resets")"
      [[ "$OUTCOME_USABLE" -eq 1 ]] || set_outcome unreadable "$row_source" observation_stale
      emit_row antigravity "$label" "$account" "$window" "" "" unreadable \
        "stale: captured $(antigravity_age "$age") ago via ${via_note}; account not verified${why} — ${ANTIGRAVITY_HINT}" "$row_source" "" \
        "$(jq -nc --arg via "$via_note" --arg g "$group" --argjson m "$models" --argjson u "$used" --argjson at "$captured" --argjson a "$age" --argjson now "$NOW" --arg fet "$fet_et" \
             --arg r "$resets" --arg ret "$res_et" '
             {group: $g, group_models: $m, observed_age_seconds: $a,
              last_known_used_pct: $u, last_known_at_epoch: $at, last_known_at_et: $fet,
              last_known_source: $via,
              last_known_resets_at_epoch: (if $r == "" then null else ($r | tonumber) end),
              last_known_resets_et: (if $ret == "" then null else $ret end),
              last_known_expired: ($r != "" and (($r | tonumber) <= $now))}')"
    else
      emit_row antigravity "$label" "$account" "$window" "$used" "$resets" ok \
        "from ${via_note}, observed $(antigravity_age "$age") ago; account not verified${why}" "$row_source" "" \
        "$(jq -nc --arg g "$group" --argjson m "$models" --argjson a "$age" --argjson at "$captured" --argjson top "$top" \
             '{group: $g, group_models: $m, observed_age_seconds: $a, fetched_at_epoch: $at} + $top')"
    fi
  done < <(printf '%s' "$result" | jq -c '.groups[] | .name as $g | .models as $m | .slug as $s
      | .windows[] | {window: ($s + " " + .name), used_pct, resets_at_epoch, group: $g, models: $m}')
  return 0
}
