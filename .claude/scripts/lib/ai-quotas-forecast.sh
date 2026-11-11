#!/usr/bin/env bash
# Sourced by ai-quotas.sh. Validation and application of the history projection.

# The projection is applied IN PLACE over $DOC, and only when the helper wrote
# back the report it was given: every row, and every field that already carried
# a value returned unchanged. A projection may only fill THE SEVEN BLANKS IT
# OWNS — a figure appearing in `overage` or a reset this run could not read did
# not come from any provider, and the table has no way to say so. Anything else
# leaves $DOC exactly as it was — every projection field already null — and
# says DEGRADED once. Counting rows alone is not enough, because the helper is
# an ARBITRARY EXECUTABLE: AI_QUOTAS_FORECAST_BIN points this at anything on
# disk, and a same-length document that dropped schema_version, cheapest_next,
# or a row's provider and status would print a report missing the very fields
# a consumer reads it for, successfully.
apply_forecast() {
  local rc=0 want out="$TMP/forecast.json"
  want="$(jq '.rows | length' "$DOC" 2>/dev/null || true)"
  [[ "$want" =~ ^[0-9]+$ ]] || want=""
  if [[ -z "$FORECAST_SH" ]]; then
    if [[ -n "${AI_QUOTAS_FORECAST_BIN:-}" ]]; then
      warn "DEGRADED: AI_QUOTAS_FORECAST_BIN names '${AI_QUOTAS_FORECAST_BIN}', which is not executable — reporting with no figures in the START, %/DAY and LEFT columns"
    else
      warn "DEGRADED: quotas-forecast.sh not found (checked the script's own directory and all three portable paths) — reporting with no figures in the START, %/DAY and LEFT columns"
    fi
    return 0
  fi
  : > "$out"
  # The history path and the clock are passed EXPLICITLY rather than inherited:
  # a run under AI_QUOTAS_HISTORY or a frozen AI_QUOTAS_NOW must project over
  # the same file and the same instant this report was built from, or the
  # projection would describe a different history than the table above it.
  if [[ -n "$HISTORY_FILE" ]]; then
    AI_QUOTAS_NOW="$NOW" "$FORECAST_SH" --history "$HISTORY_FILE" \
      < "$DOC" > "$out" 2>"$TMP/forecast.err" || rc=$?
  else
    AI_QUOTAS_NOW="$NOW" "$FORECAST_SH" < "$DOC" > "$out" 2>"$TMP/forecast.err" || rc=$?
  fi
  if [[ "$rc" -eq 0 && -s "$out" && -n "$want" ]] &&
     jq -se --slurpfile sent "$DOC" \
       '# The ONLY fields this helper is here to write. A blank anywhere else —
        # `overage`, already null on every row when the cheapest-next helper
        # degraded, or a reset this run could not read — is a blank the
        # projection has no business filling: a figure appearing there did not
        # come from any provider and nothing downstream could tell.
        ["usage_start_epoch", "usage_start_is_floor", "usage_start_day",
         "usage_start_display", "pct_per_day", "days_left",
         "days_left_note"] as $writable
        # A blank may be filled only with the DOCUMENTED type for that field:
        # a structured value in a scalar slot breaks the TSV renderer instead
        # of degrading, and the JSON shape consumers rely on is typed.
        | def okval($k; $v):
            if $v == null then true
            elif $k == "days_left_note" then $v == "resets first"
            elif $k == "usage_start_is_floor" then ($v | type) == "boolean"
            elif $k == "usage_start_display" then ($v | type) == "string"
            # One-based by the helper contract: day 0 is not a day.
            elif $k == "usage_start_day" then (($v | type) == "number" and $v >= 1)
            else (($v | type) == "number" and $v >= 0) end;
        ($sent[0]) as $i
        | length == 1 and (.[0] as $o
        | ($o | type) == "object"
          and ($o.rows | type) == "array"
          and ($o.rows | length) == ($i.rows | length)
          # A projection may only FILL BLANKS. Every field this report already
          # carried with a value — schema_version, the threshold and basis,
          # cheapest_next, and on each row the provider, label, status and the
          # figure itself — has to come back unchanged; a field that was null
          # on the way in is one the helper is here to fill. PRESENCE is
          # required either way: a null the helper deleted instead of filling
          # would leave the field off the document altogether, and the one
          # report shape a consumer can rely on is the reason it was declared
          # null rather than omitted in the first place.
          # The KEY SET is identical, top level and every row. `keys` sorts, so
          # this is set equality: nothing dropped, and nothing added either —
          # every field the projection writes is already declared on the row,
          # so a key that was not sent has no legitimate way to come back.
          and ($o | keys) == ($i | keys)
          # Nothing outside the rows is writable at all: the projection is a
          # per-row property, so schema_version, the threshold and basis and
          # cheapest_next come back exactly as they went out.
          and (($i | del(.rows) | to_entries)
               | all(. as $e | $o[$e.key] == $e.value))
          and ([range(0; $i.rows | length)]
               | all(. as $ix
                     | ($o.rows[$ix] | type) == "object"
                       and ($o.rows[$ix] | keys) == ($i.rows[$ix] | keys)
                       and (($i.rows[$ix] | to_entries)
                            | all(. as $e
                                  | ($e.value == null
                                     and ($writable | index($e.key)) != null
                                     and okval($e.key; $o.rows[$ix][$e.key]))
                                    or $o.rows[$ix][$e.key] == $e.value)))))' \
       "$out" >/dev/null 2>&1; then
    [[ ! -s "$TMP/forecast.err" ]] || cat "$TMP/forecast.err" >&2
    mv "$out" "$DOC" 2>/dev/null || warn "DEGRADED: could not apply the projection to this report"
    return 0
  fi
  if [[ "$rc" -ne 0 ]]; then
    warn "DEGRADED: quotas-forecast.sh failed (exit ${rc}) — reporting with no figures in the START, %/DAY and LEFT columns"
  else
    warn "DEGRADED: quotas-forecast.sh exited 0 but did not write back the report it was given — all ${want:-the input} rows, every recorded figure unchanged — so the projection was discarded; reporting with no figures in the START, %/DAY and LEFT columns"
  fi
  [[ ! -s "$TMP/forecast.err" ]] || sed 's/^/  /' "$TMP/forecast.err" >&2
  return 0
}
