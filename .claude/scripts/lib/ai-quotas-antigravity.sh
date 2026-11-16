#!/usr/bin/env bash
# Sourced by ai-quotas.sh. Google Antigravity reader (Issue #2407): display only.
#
# Source: an observation file holding the text of the `agy` `/usage` panel plus its
# capture time, written by `quotas-antigravity-capture.sh`. Nothing here contacts the
# signed-in backend and no credential is read. Antigravity never feeds
# `quota-reserve.sh` (it keeps only Claude and Codex rows). Contract and sample:
# .claude/reference/ai-quotas-antigravity.md.

ANTIGRAVITY_HINT="run quotas-antigravity-capture.sh (or paste the agy /usage panel into it)"

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

read_antigravity_account() { # <label>
  local label="$1" obs result status account age stale_after captured via_note
  obs="$(antigravity_observation_file)"
  if ! command -v python3 >/dev/null 2>&1 || [[ ! -r "$SELF_DIR/lib/quotas-antigravity.py" ]]; then
    set_outcome unreadable observation reader_unavailable
    emit_row antigravity "$label" "" "usage" "" "" unreadable "Antigravity parser unavailable (python3 or lib/quotas-antigravity.py missing)" observation ""
    return 0
  fi
  result="$(python3 -I "$SELF_DIR/lib/quotas-antigravity.py" show "$obs" "$NOW" 2>/dev/null || true)"
  status="$(printf '%s' "$result" | jq -r '.status // "unreadable"' 2>/dev/null || echo unreadable)"
  case "$status" in
    ok) ;;
    missing)
      set_outcome unreadable observation observation_missing
      emit_row antigravity "$label" "" "usage" "" "" unreadable "no Antigravity reading yet — ${ANTIGRAVITY_HINT}" observation ""
      return 0 ;;
    *)
      set_outcome parse_error observation response_shape
      emit_row antigravity "$label" "" "usage" "" "" unreadable \
        "saved Antigravity text is unreadable ($(printf '%s' "$result" | jq -r '.reason // "unknown reason"' 2>/dev/null)) — ${ANTIGRAVITY_HINT}" observation ""
      return 0 ;;
  esac
  account="$(printf '%s' "$result" | jq -r '.account // "" | gsub("[\u0000-\u001f\u007f]"; "")')"
  age="$(printf '%s' "$result" | jq -r '.age_seconds')"
  captured="$(printf '%s' "$result" | jq -r '.captured_at_epoch')"
  via_note="$(printf '%s' "$result" | jq -r '.via | if . == "agy-print" then "agy -p /usage" elif . == "pasted" then "pasted /usage text" else "saved /usage text" end')"
  stale_after=10800
  [[ -z "${AI_QUOTAS_ANTIGRAVITY_STALE_SECONDS:-}" ]] \
    || stale_after="$(positive_int_or_default "$AI_QUOTAS_ANTIGRAVITY_STALE_SECONDS" 10800 AI_QUOTAS_ANTIGRAVITY_STALE_SECONDS)"
  local line window used resets group models fet_et res_et top
  fet_et="$(epoch_to_et "$captured")"
  # The top tier (#2415): the group the panel prints with no "Models within this group"
  # line, because it is a single named model with its own allowance ("GEMINI 4 ARGON").
  # Its label is the last word of the printed group name, its percent is USED (the
  # panel prints remaining), and it is taken from the weekly window when there is one.
  # The first such group wins. A window whose reset passed since the capture, or a
  # capture older than the stale cutoff, shows nothing rather than an old figure.
  top="$(printf '%s' "$result" | jq -c --argjson now "$NOW" '
    ([.groups[] | select((.models | length) == 0)][0]) as $g
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
      [[ "$OUTCOME_USABLE" -eq 1 ]] || set_outcome unreadable observation observation_stale
      emit_row antigravity "$label" "$account" "$window" "" "" unreadable \
        "stale: captured $(antigravity_age "$age") ago via ${via_note}; account not verified — ${ANTIGRAVITY_HINT}" observation "" \
        "$(jq -nc --arg g "$group" --argjson m "$models" --argjson u "$used" --argjson at "$captured" --argjson a "$age" --argjson now "$NOW" --arg fet "$fet_et" \
             --arg r "$resets" --arg ret "$res_et" '
             {group: $g, group_models: $m, observed_age_seconds: $a,
              last_known_used_pct: $u, last_known_at_epoch: $at, last_known_at_et: $fet,
              last_known_source: "agy /usage",
              last_known_resets_at_epoch: (if $r == "" then null else ($r | tonumber) end),
              last_known_resets_et: (if $ret == "" then null else $ret end),
              last_known_expired: ($r != "" and (($r | tonumber) <= $now))}')"
    else
      emit_row antigravity "$label" "$account" "$window" "$used" "$resets" ok \
        "from ${via_note}, observed $(antigravity_age "$age") ago; account not verified" observation "" \
        "$(jq -nc --arg g "$group" --argjson m "$models" --argjson a "$age" --argjson at "$captured" --argjson top "$top" \
             '{group: $g, group_models: $m, observed_age_seconds: $a, fetched_at_epoch: $at} + $top')"
    fi
  done < <(printf '%s' "$result" | jq -c '.groups[] | .name as $g | .models as $m | .slug as $s
      | .windows[] | {window: ($s + " " + .name), used_pct, resets_at_epoch, group: $g, models: $m}')
  return 0
}
