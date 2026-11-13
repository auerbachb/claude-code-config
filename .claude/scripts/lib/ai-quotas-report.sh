#!/usr/bin/env bash
# Sourced by ai-quotas.sh. Snapshot history, reliability, and table rendering.

# Snapshot and table contract: .claude/reference/ai-quotas.md.

epoch_to_utc_iso() { # <epoch>
  [[ "$QUOTA_DATE_DIALECT" != unavailable ]] || return 0
  quota_date_format "$QUOTA_DATE_DIALECT" "${1:-}" '+%Y-%m-%dT%H:%M:%SZ' UTC || true
}

# One `ts` for the whole run, taken from the SAME clock every countdown in
# this report was measured against — so a frozen AI_QUOTAS_NOW freezes the
# snapshot too, and a run's rows group by an exact equality rather than by
# "within a second or so of each other".
append_history() { # <doc-json-file>
  [[ -n "$HISTORY_FILE" ]] || return 0
  local ts dir tmp
  ts="$(epoch_to_utc_iso "$NOW")"
  if [[ -z "$ts" ]]; then
    warn "could not format this run's timestamp — nothing was recorded to $HISTORY_FILE"
    return 0
  fi
  dir="$(dirname "$HISTORY_FILE")"
  if ! mkdir -p "$dir" 2>/dev/null; then
    warn "could not create ${dir} — nothing was recorded to $HISTORY_FILE"
    return 0
  fi
  tmp="$TMP/history.jsonl"
  : > "$tmp"
  # A row with no figure appends NOTHING. A line carrying a null `used_pct`
  # would be indistinguishable, three months later, from a genuine reading —
  # and the projection reading it would average a failure in as a 0.
  #
  # `window` takes the POOL where a provider has pools, which is the same
  # value the table's third column shows. Without it a Cursor account's two
  # rows land as two readings of one series per run, and a burn rate computed
  # over them is the average of two unrelated pools.
  if ! jq -c --arg ts "$ts" --arg source "$SNAPSHOT_SOURCE" '
        .rows[]
        | select(.status == "ok" and .used_pct != null)
        | {ts: $ts,
           provider: .provider,
           label: .label,
           nickname: .nickname,
           window: (.pool // .window),
           used_pct: .used_pct,
           resets_at_epoch: .resets_at_epoch,
           # When the window this reading belongs to OPENED (#1701). Recorded
           # rather than re-derived at read time: the reset time can move, and
           # a line that carries its own window start can be assigned to a
           # cycle months later without knowing what the window length was
           # then. Null on a row whose window this reader could not place.
           window_start_epoch: .window_start_epoch,
           source: $source}' "$1" > "$tmp" 2>/dev/null; then
    warn "could not build this run's snapshot lines — the report is unaffected, but nothing was recorded to $HISTORY_FILE"
    return 0
  fi
  # Every row failed to read. Not an error and not worth a warning: the
  # statuses in the table already say so, row by row.
  [[ -s "$tmp" ]] || return 0
  # A SYMLINK is refused before anything else, and before the create below —
  # every other test here follows one. `-f` is true for a link to a regular
  # file, so without this the chmod would retarget an unrelated file's mode
  # and the append would write quota JSON into it; `-e` is FALSE for a
  # dangling link, so the create branch would follow it and bring its target
  # into existence. Neither is something a tool whose contract is that it
  # writes nothing that matters may do to a path it did not choose.
  if [[ -L "$HISTORY_FILE" ]]; then
    warn "$HISTORY_FILE is a symbolic link — nothing was recorded, and neither the link nor its target was touched"
    return 0
  fi
  # Created through a 077 umask so the file is never briefly world-readable
  # between creation and the mode being set — the same reasoning the config
  # writer uses for its temp file.
  if [[ ! -e "$HISTORY_FILE" ]]; then
    if ! ( umask 077; : >> "$HISTORY_FILE" ) 2>/dev/null; then
      warn "could not create $HISTORY_FILE — nothing was recorded"
      return 0
    fi
  fi
  # A path that exists but is not a regular file is refused BEFORE the chmod.
  # `chmod 600` on a DIRECTORY succeeds and strips its execute bit, making it
  # unusable — so a history path occupied by a directory would be silently
  # mutated by a tool whose whole contract is that it writes nothing that
  # matters.
  if [[ ! -f "$HISTORY_FILE" ]]; then
    warn "$HISTORY_FILE exists but is not a regular file — nothing was recorded, and its mode was left alone"
    return 0
  fi
  # The mode is settled BEFORE any content lands, not after. The umask above
  # already covers a file this run creates; what this covers is a file that
  # was already there with a looser mode — tightening it afterwards would mean
  # this run appended readings to a world-readable file first.
  # A chmod this run could not apply STOPS the append. Recording readings into
  # a file whose permissions we failed to secure is worse than not recording
  # them: the history is documented as mode 600, and a consumer reading it back
  # is entitled to that. The run itself still exits 0 — this is a record, not a
  # gate — and the warning says what to fix.
  if ! chmod 600 "$HISTORY_FILE" 2>/dev/null; then
    warn "could not set mode 600 on $HISTORY_FILE — nothing was recorded; check its permissions"
    return 0
  fi
  # ONE append of the whole block, not one per row. A `/quotas` run by hand
  # while the LaunchAgent happens to fire is the ordinary case, and appending
  # once keeps that block contiguous instead of interleaving it row by row
  # with the other run's.
  #
  # This is a NARROWING of the window, not atomicity, and the difference
  # matters to whoever next reads this. `cat` writes in buffer-sized chunks;
  # a block larger than one chunk becomes several O_APPEND writes, and a
  # concurrent appender can land between them. What that costs is bounded:
  # O_APPEND advances the offset atomically per write, so the two runs never
  # overwrite each other and no line written on an earlier day can be damaged
  # — the only casualty is the pair of records straddling a chunk boundary,
  # which arrive torn and which `last_scheduled_snapshot_at` and every other
  # reader already DROP via `fromjson?`. A lost reading self-heals at the next
  # run; the history has no unique data in any single line. A lock would buy
  # those two records at the price of a stale-lock failure mode on a file
  # whose entire contract is that it never blocks the report it decorates.
  if ! cat "$tmp" >> "$HISTORY_FILE" 2>/dev/null; then
    warn "could not append this run's snapshots to $HISTORY_FILE"
    return 0
  fi
  return 0
}

# The `ts` of the most recent `scheduled` snapshot, or nothing.
last_scheduled_snapshot_at() {
  [[ -n "$HISTORY_FILE" && -r "$HISTORY_FILE" ]] || return 0
  # `fromjson?` DROPS a line it cannot parse instead of aborting the program.
  # A run killed mid-append can leave one torn line, and one torn line must
  # not cost the footer every good line written before it. The `type` guard is
  # the other half: `fromjson?` catches only the PARSE error, so a line holding
  # a bare `5` parses fine and then aborts jq on `.source`.
  #
  # The NEWEST `ts`, not the last line. A run stamps every one of its rows
  # with the clock it started on, so file order is append-completion order,
  # not reading order: a slow run that started at 09:00 and finished at 09:05
  # lands AFTER a quick one that started at 09:02, and `tail -n 1` would then
  # report 09:00 as the latest snapshot — an hour of drift near the staleness
  # boundary, from a footer whose whole job is to say when the job last ran.
  # `sort` is exact here rather than approximate: these are fixed-width UTC
  # `%Y-%m-%dT%H:%M:%SZ` strings, which order lexicographically.
  jq -R -r 'fromjson?
            | select(type == "object" and .source == "scheduled")
            | .ts // empty' \
    "$HISTORY_FILE" 2>/dev/null | sort | tail -n 1 || true
}

# `LAST SNAPSHOT: <time> (scheduled)`, `… — stale (>1 day)`, or `none yet`.
snapshot_footer() { # <iso|"">
  local iso="$1" e et
  if [[ -z "$iso" ]]; then
    printf 'LAST SNAPSHOT: none yet — install the daily job with: /quotas-setup schedule install'
    return 0
  fi
  e="$(iso_to_epoch "$iso")"
  if [[ -z "$e" ]]; then
    # A recorded timestamp this reader cannot parse is shown verbatim rather
    # than dropped: "none yet" would be a lie about a job that did run.
    printf 'LAST SNAPSHOT: %s (scheduled)' "$iso"
    return 0
  fi
  et="$(epoch_to_et "$e")"
  [[ -n "$et" ]] || et="$iso"
  if [[ $(( NOW - e )) -gt 86400 ]]; then
    printf 'LAST SNAPSHOT: %s (scheduled) — stale (>1 day)' "$et"
  else
    printf 'LAST SNAPSHOT: %s (scheduled)' "$et"
  fi
}

# Persist attempts separately from successful window snapshots. The helper
# returns account-level statistics including this run even if persistence fails.
record_outcomes() {
  local stamped="$TMP/outcomes.stamped.jsonl" ts
  [[ -s "$OUTCOMES_RUN" ]] || return 0
  ts="$(epoch_to_utc_iso "$NOW")"
  if ! jq -c --arg ts "$ts" '. + {ts:$ts}' "$OUTCOMES_RUN" > "$stamped"; then
    warn "could not timestamp read outcomes"; return 0
  fi
  if command -v python3 >/dev/null 2>&1 && [[ -r "$SELF_DIR/lib/quotas-outcomes.py" ]]; then
    if ! python3 "$SELF_DIR/lib/quotas-outcomes.py" "$OUTCOMES_FILE" "$stamped" "$NOW" > "$RELIABILITY"; then
      printf '[]' > "$RELIABILITY"
      warn "could not record read outcomes"
    fi
  else
    warn "DEGRADED: python3 or lib/quotas-outcomes.py unavailable — read outcomes disabled"
  fi
}

# Adds `last_scheduled_snapshot_at` to the document. Called on EVERY exit that
# emits one, including the two empty ones, so --json has a single shape.
stamp_snapshot_field() {
  local iso stamped="$TMP/doc.stamped.json"
  local threshold
  threshold="$(printf '%s' "$CONFIG" | jq '.source_failure_threshold // 3')" || threshold=3
  iso="$(last_scheduled_snapshot_at)"
  if jq --arg v "$iso" --argjson threshold "$threshold" --argjson config "$CONFIG" --slurpfile reliability "$RELIABILITY" \
      '. + {last_scheduled_snapshot_at: (if $v == "" then null else $v end), account_reliability: ($reliability[0] // []), recommendations: [($reliability[0] // [])[] |
       . as $r | ($config.accounts | map(select(.provider == $r.provider and .label == $r.label)) | first) as $a |
       ($a.sources // (if .provider == "claude" then ["oauth-usage"] elif .provider == "codex" then ["app-server","http"] else ["ide-token","browser"] end)) as $order |
       (.sources | map(select(.source == $order[0] and .consecutive_failures >= $threshold)) | first) as $failed |
       select($failed != null) |
       {provider:.provider,label:.label,source:$failed.source,failures:$failed.consecutive_failures,
        next_source:($order[1] // null), message:("SOURCE " + .label + ": " + $failed.source + " failed " + ($failed.consecutive_failures | tostring) + " consecutive reads; " +
          (if $order[1] == null then "no alternate source configured" else "try " + $order[1] + " with /quotas-setup sources " + .label + " " + ($order | reverse | join(",")) + " " + .provider end))}
       | .message |= gsub("[\u0000-\u001f\u007f]"; "")]}'  \
      "$DOC" > "$stamped" 2>/dev/null && [[ -s "$stamped" ]]; then
    mv "$stamped" "$DOC" 2>/dev/null || warn "could not stamp last_scheduled_snapshot_at onto the report"
  else
    warn "could not stamp last_scheduled_snapshot_at onto the report"
  fi
}

render_quota_table() {
  # Rendered ONCE, to a file, so the no-`column` fallback prints the same table
  # unaligned rather than something else entirely. Piping into `column` and
  # falling back to `cat "$ROWS"` printed the TSV header over the raw JSON rows —
  # a fallback that does not degrade the output but replaces it.
  TABLE="$TMP/table.tsv"
  # Each action leads its account output and is printed once even for multi-pool
  # accounts. Keep the diagnostic detail unchanged in JSON for existing callers.
  jq -r '[.rows[] | select(.action != null) | {provider,label,action}] | unique[] | .action' "$DOC"
  {
    printf '%s\n' 'ACCOUNT	WINDOW	USED	START	%/DAY	LEFT	OVERAGE	RESETS (ET)	IN	NOTE'
    jq -r '
      def pct: if . == null then "-" else "\(.)%" end;
      def dash: if . == null or . == "" then "-" else . end;
      # One decimal, always — `25` and `25.0` in one column read as different
      # kinds of number, and the projection is an estimate in every cell.
      def one_dp: if . == null then "-"
                  else (tostring | if test("\\.") then . else . + ".0" end) end;
      .rows[] |
      [ # The nickname when the owner set one, the provider-reported email
        # otherwise (#1700). A five-account table of full subscription emails
        # is what pushed this table past 100 columns; `GPT LM` is also simply
        # what the owner calls the account. The label is still reachable —
        # the note below says `registered as <label>` whenever it differs from
        # the reported email, so a nickname can shorten a row without hiding
        # which registry entry produced it.
        #
        # No PROVIDER column (#1701). It was a fixed-width column repeating
        # what the account name already tells the owner — the same trade #1700
        # made when it dropped REMAIN — and the ten columns it cost are what
        # the three projection columns needed to keep a five-account table
        # inside 100. `provider` is still on every --json row.
        (.nickname // .reported_email),
        # The pool name when the provider has pools, the window otherwise. A
        # Cursor account contributes TWO rows for one window, so printing the
        # window here would render them as two identical lines differing only
        # in a percentage — the reader could not tell which pool was which.
        (.pool // .window),
        (.used_pct | pct),
        # No REMAIN column (#1700): it was `100 - USED` on every row, so it
        # carried no information the reader did not already have, and the width
        # it cost is what a five-account table needs to stay inside 100
        # columns. `remaining_pct` is still on every --json row.
        #
        # The projection (#1701), in three columns: when usage started in this
        # window, how much a day it has been going, and how many days that
        # leaves. A `-` in any of them is the same `-` every other unknown in
        # this table uses — no window to place the reading in, no usage yet, or
        # a row that did not read — and never a zero, which would read as
        # "nothing is being spent". A START cell prefixed `<=` means the record
        # does not reach back to the window start, so usage may have begun
        # earlier: the day shown is the latest it can have been.
        (.usage_start_display | dash),
        (.pct_per_day | one_dp),
        # `resets first` is not a number of days, so it lives in a note rather
        # than in `days_left`, and the cell prints the note when there is one:
        # the window comes back before the pace runs the account out.
        (if .days_left != null then (.days_left | one_dp)
         else (.days_left_note | dash) end),
        # What continuing past this cap costs. `-` when no price is known — a
        # provider this reader has no table row for, or a run where the helper
        # was unavailable — never a blank that reads as "free".
        (.overage.label? | dash),
        # Weekday and time only (#1701) — the date and the zone are what the
        # countdown beside it and the column heading already say. The full
        # string is on every --json row as `resets_at_et`.
        (.resets_at_et_short // .resets_at_et | dash),
        # Without its `in ` prefix, which the heading supplies. `reset` — the
        # word this prints once the moment has passed — is unchanged.
        (.countdown | dash | sub("^in "; "")),
        # ACTIONABLE TEXT ONLY (#1700). `plan pro` and `via app-server` are
        # provenance — which subscription tier answered, which of the two Codex
        # read paths did — and on an `ok` row there is nothing to do about
        # either. Together they were the widest thing on a healthy row, and the
        # columns they cost are what a five-account table needs to stay inside
        # 100. Both are still on every --json row, which is where you go when a
        # number looks wrong. What stays here is what the reader must act on:
        # the mislabelled-account warning, and the detail belonging to the row
        # — a relogin command, a retry window, the keys an unreadable response
        # actually had. The note on a failing row is therefore as long as the
        # instruction it carries; truncating a relogin command to save columns
        # would trade the one line worth printing for the merely tidy ones.
        #
        # NO APOSTROPHES ANYWHERE IN THIS jq PROGRAM. It is a single-quoted
        # shell string, so one apostrophe in a comment closes it, and the jq
        # source after that point is parsed by bash — which reports a syntax
        # error a hundred lines away from the comment that caused it.
        #
        # No STATUS column either (#1701), for the same width reason — and
        # because it was never the whole answer on its own: what a reader does
        # about `needs-login` is in the note beside it. The status WORD now
        # leads the note on any row that is not `ok`, so the vocabulary is
        # unchanged and the two are read as one sentence rather than as two
        # columns that must be crossed. An `ok` row says nothing, which is what
        # `ok` was worth. `status` is still on every --json row, and it is
        # still the field to branch on.
        # The saved figure (#2280) follows the live status, so a row that could
        # not be read says so first and then shows what was last read. It is
        # always labelled last known with its date and source, and an expired
        # one says so; USED stays a dash on every such row.
        ([ (if (.status // "ok") != "ok" then .status else empty end),
           (if .label != .reported_email then "registered as \(.label)" else empty end),
           (if .status == "needs-login" then empty else (.detail | if . == null or . == "" then empty else . end) end),
           (if .last_known_used_pct == null then empty
            else ((if .last_known_expired == true then "expired: " else "" end)
                  + "\(.last_known_used_pct)% (last known, \(.last_known_at_et // "" | [match("[A-Z][a-z]{2} [0-9]{1,2}").string][0] // "-"), \(.last_known_source // "unknown"))"
                  + (if .last_known_resets_et == null then ""
                     else "; \(if .last_known_expired == true then "reset" else "resets" end) \(.last_known_resets_et | [match("[A-Z][a-z]{2} [0-9]{1,2}").string][0] // "-")" end))
            end) ]
         | join("; ") | if . == "" then "-" else . end)
      ] | @tsv' "$DOC"
  } > "$TABLE"
  column -t -s $'\t' "$TABLE" 2>/dev/null || cat "$TABLE"

  # The cheapest-next hint, printed ONLY when the helper returned one — i.e.
  # when at least one account is at or below the threshold. Nothing prints while
  # every account still has room, because a suggestion nobody needs is a
  # suggestion that trains the reader to ignore the line.
  HINT=""
  if [[ "$QUIET" -eq 0 ]]; then
    HINT="$(jq -r 'if .cheapest_next == null then empty
                   else "Cheapest to continue on: \(.cheapest_next.label) (\(.cheapest_next.reason))" end' \
      "$DOC" 2>/dev/null || true)"
  fi
  if [[ -n "$HINT" ]]; then
    echo
    echo "$HINT"
    # The basis, on its own line, because the units do NOT convert and a hint
    # that hides that is a hint that reads as a price comparison.
    jq -r 'if .cheapest_next == null then empty else "  \(.cheapest_next.basis)" end' "$DOC" 2>/dev/null || true
    echo "  Informational only — it never switches accounts, never buys anything, and never gates dispatch."
  fi

  # When the unattended job last ran. Printed on EVERY table, including a run
  # with no history at all — "none yet" is the answer that sends the owner to
  # `schedule install`, and a footer that appears only once history exists would
  # hide exactly the state worth acting on. Suppressed under --quiet with the
  # rest of the trailing prose: the scheduled run IS the snapshot, so telling
  # its own log when it last ran says nothing.
  if [[ "$QUIET" -eq 0 ]]; then
    echo
    jq -r '[.rows[] | select(.status == "ok" and .used_pct != null) | {name:(.nickname // .reported_email // .label),source}] | unique[] |
      "SOURCE " + (.name | gsub("[\u0000-\u001f\u007f]"; "")) + ": via " + .source' "$DOC"
    printf '%s\n' "$(snapshot_footer "$(last_scheduled_snapshot_at)")"
    jq -r '
      .rows as $rows | (.account_reliability // [])[] |
      . as $r | ($rows | map(select(.provider == $r.provider and .label == $r.label)) | first) as $row |
      "RELIABILITY \($row.nickname // $row.reported_email // .label): " +
      "7d \(.failures_7d)/\(.attempts_7d) failed (\(((.failure_rate_7d // 0) * 100) | round)%) · " +
      "30d \(.failures_30d)/\(.attempts_30d) failed (\(((.failure_rate_30d // 0) * 100) | round)%) · " +
      (if .streak_count == 0 then "no current streak"
       else "\(.streak_status) × \(.streak_count) consecutive reads since \(.streak_since)" end)' "$DOC"
    echo
    jq -r '.recommendations[]?.message' "$DOC"
    echo "Display only — never a dispatch or spend gate (.claude/rules/safety.md §Anthropic Quota & Spend Authority)."
  fi
}
