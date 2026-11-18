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
  if ! jq -c --arg ts "$ts" --arg source "$SNAPSHOT_SOURCE" --argjson now "$NOW" '
        .rows[]
        | select(.status == "ok" and .used_pct != null)
        # Issue #2467: the daily snapshot records Antigravity from the backend source alone. A saved
        # reading (pasted, terminal, or an earlier capture) shown as a fallback would otherwise be
        # appended with the run time as its timestamp; the failed backend read is in the outcomes ledger.
        | select($source != "scheduled" or .provider != "antigravity"
                 or (.source == "backend" and .live_read == true))
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
       ($a.sources // (if .provider == "claude" then ["oauth-usage"] elif .provider == "codex" then ["app-server","http"] elif .provider == "antigravity" then ["observation"] else ["ide-token","browser"] end)) as $order |
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

# #2406. When each row's figure was read: `fetched_at` (ISO-8601 UTC), `fetched`
# (`live` | `saved`) and `fetched_display` (`now` | `Mmm dd` in Eastern time).
# A row with no figure gets all three null. A figure is LIVE (`now`) when it was
# read within 120 seconds before this run began, whatever the source: a provider
# sets `fetched_at_epoch` on the row for a saved reading or an observation, and
# that instant is kept exactly in `fetched_at`. A figure older than that is SAVED
# and shows its date, as does any last-known reading apply_last_known attached.
# A row with a number from a source that is by construction a network read made
# in this run (oauth-usage, app-server, http, ide-token) is LIVE at this run's
# own time. Every other source needs an explicit `fetched_at_epoch` or stays
# blank: a default of `now` would claim a read nobody made.
# Reads the epoch the provider already holds; invents no second clock. `live` and
# `now` never depend on the date helper; only a saved date (and any ISO instant)
# degrades, to null, when date operations are unavailable.
stamp_fetched_field() { # <doc-json-file>
  local doc="$1" e iso md map="{}" out="$TMP/doc.fetched.json"
  while IFS= read -r e; do
    [[ "$e" =~ ^[0-9]+$ ]] || continue
    iso="$(epoch_to_utc_iso "$e")"
    md=""
    if [[ "$QUOTA_DATE_DIALECT" != unavailable ]]; then
      md="$(quota_date_format "$QUOTA_DATE_DIALECT" "$e" '+%b %d' America/New_York 2>/dev/null || true)"
    fi
    map="$(printf '%s' "$map" | jq -c --arg e "$e" --arg iso "$iso" --arg md "$md" \
      '. + {($e): {iso: (if $iso == "" then null else $iso end), md: (if $md == "" then null else $md end)}}')"
  done < <(jq -r --argjson now "$NOW" '[.rows[] | (.fetched_at_epoch // .last_known_at_epoch)
                   | select(type == "number") | floor] + [$now] | unique[]' "$doc" 2>/dev/null)
  if jq --argjson map "$map" --argjson now "$NOW" '
      def num: type == "number";
      def blank: . + {fetched_at: null, fetched: null, fetched_display: null};
      def stamp($kind; $e):
        ($map[($e | floor | tostring)] // {iso: null, md: null}) as $m
        | . + {fetched_at: $m.iso, fetched: $kind,
               fetched_display: (if $kind == "live" then "now" else $m.md end)};
      .rows |= map(
        (.fetched_at_epoch // .last_known_at_epoch) as $saved
        | if ((.used_pct | num) or (.last_known_used_pct | num)) | not then blank
          elif (.status == "ok" and (.fetched_at_epoch | num) and (.used_pct | num)
                and .fetched_at_epoch <= $now and ($now - .fetched_at_epoch) <= 120) then
            # Read within 120 seconds before this run began: for this request that is a
            # fresh read, whatever produced it (a saved status-line or app reading, a
            # browser or text observation). fetched_at keeps the exact instant. A
            # last-known figure never takes this branch, and neither does a capture time
            # after this run began (a clock that cannot be trusted shows its date).
            stamp("live"; .fetched_at_epoch)
          elif ($saved | num) then stamp("saved"; $saved)
          elif (.status == "ok" and (.used_pct | num)
                and ((.source // "") as $s | ["oauth-usage","app-server","http","ide-token"] | index($s) != null)) then
            stamp("live"; $now)
          else blank end)' "$doc" > "$out" 2>/dev/null && [[ -s "$out" ]]; then
    mv "$out" "$doc" 2>/dev/null || warn "could not stamp fetched times onto the report"
  else
    warn "could not stamp fetched times onto the report"
  fi
}

# #2409, #2408. Account-level figures a provider reports under older field names are
# lifted into the uniform ones, over the finished rows file (a JSON array), before
# anything else reads them. Cursor: on-demand spending is possible when the limit is
# above zero or the page said unlimited, off when the limit is zero, and unknown when
# no limit was reported; the dollars are the plan-wide on-demand figures. Codex: the
# free resets remaining become the resets available. Nothing is inferred from a
# missing figure, and no value is ever invented.
derive_account_fields() { # <rows-json-file>
  local rows="$1" out="$TMP/rows.derived.json"
  if jq --argjson now "$NOW" '
      def num: type == "number";
      def nn: type == "number" and . >= 0;
      def unset: .paid_enabled == null and .paid_cap_usd == null and .paid_cap_unlimited == null and .paid_spent_usd == null;
      map(
        (if .provider == "cursor" and unset
            and (.spend_limit_unlimited == true or (.spend_limit_usd | nn) or (.spend_limit_used_usd | nn)) then
           . + {paid_enabled: (if .spend_limit_unlimited == true then true
                               elif (.spend_limit_usd | nn) then (.spend_limit_usd > 0) else null end),
                paid_cap_usd: (if .spend_limit_unlimited == true then null
                               elif (.spend_limit_usd | nn) then .spend_limit_usd else null end),
                paid_cap_unlimited: (if .spend_limit_unlimited == true then true else null end),
                paid_spent_usd: (if (.spend_limit_used_usd | nn) then .spend_limit_used_usd else null end),
                paid_currency: "USD",
                paid_period: "monthly",
                paid_read_at_epoch: (.fetched_at_epoch // (if .status == "ok" then $now else null end))}
         else . end)
        | if .limit_resets_available == null and (.free_resets_remaining | num)
             and .free_resets_remaining >= 0 and .free_resets_remaining == (.free_resets_remaining | floor)
          then . + {limit_resets_available: .free_resets_remaining} else . end)' "$rows" > "$out" 2>/dev/null && [[ -s "$out" ]]; then
    mv "$out" "$rows"
  else
    warn "DEGRADED: could not derive the paid-usage and resets columns — they show as unknown"
  fi
}

# Issue #2469. Each row gets plan_tier, plan_tier_source (provider | override),
# plan_usd_month and plan_price_source (list | override). The tier is what the provider
# reported (row `plan`, set by each reader) or the account's manual override from the
# registry (`plan_override`: {tier, usd_per_month?}, set by `ai-quotas-setup.sh plan`);
# the override wins. The price is the override's own figure, else the dated list in
# .claude/reference/quotas-plan-prices.json looked up by provider and tier. An unknown
# tier or price stays null (the table shows `-`); nothing is guessed and `$0` is never
# printed for "unknown". Display only: nothing reads these fields to gate work.
derive_plan_fields() { # <rows-json-file>
  local rows="$1" out="$TMP/rows.plan.json" prices="${AI_QUOTAS_PRICE_LIST:-}" cfg="${CONFIG:-}"
  [[ -n "$prices" ]] || prices="$SELF_DIR/../reference/quotas-plan-prices.json"
  [[ -r "$prices" ]] && jq -e 'type == "object"' "$prices" >/dev/null 2>&1 || {
    warn "DEGRADED: plan price list not readable (${prices}) — prices show as unknown"
    prices="$TMP/no-prices.json"; printf '{}' > "$prices"
  }
  printf '%s' "$cfg" | jq -e 'type == "object"' >/dev/null 2>&1 || cfg='{}'
  if jq --slurpfile pl "$prices" --argjson cfg "$cfg" '
      def norm: ascii_downcase | gsub("[^a-z0-9]+"; "_") | gsub("^_+|_+$"; "");
      def clean: gsub("[\u0000-\u001f\u007f]"; " ") | gsub("^ +| +$"; "") | .[0:40];
      def num: type == "number" and . >= 0;
      ($pl[0].providers // {}) as $P
      | map(
          . as $r
          | ((($cfg.accounts // []) | map(select(.provider == $r.provider and .label == $r.label)) | first // {}).plan_override
             | if type == "object" and (.tier | type) == "string" and (.tier | clean) != "" then . else null end) as $ov
          | ((($P[$r.provider].tiers // {}) | to_entries | map(.value)) as $tiers
             | def find($s): ($s | norm) as $k | ([$tiers[] | select((.match // []) | index($k) != null)] | first // null);
               (if $ov != null then ($ov.tier | clean) elif ($r.plan | type) == "string" and ($r.plan | clean) != "" then ($r.plan | clean) else null end) as $raw
               | if $raw == null then {plan_tier: null, plan_tier_source: null, plan_usd_month: null, plan_price_source: null}
                 else find($raw) as $m
                   | {plan_tier: (if $ov != null then $raw elif $m != null then $m.name
                                          elif ($raw | test("^[a-z]")) then (($raw[0:1] | ascii_upcase) + $raw[1:]) else $raw end),
                      plan_tier_source: (if $ov != null then "override" else "provider" end)}
                   + (if $ov != null and ($ov.usd_per_month | num) then {plan_usd_month: $ov.usd_per_month, plan_price_source: "override"}
                      elif $m != null and ($m.usd_per_month | num) then {plan_usd_month: $m.usd_per_month, plan_price_source: "list"}
                      else {plan_usd_month: null, plan_price_source: null} end)
                 end)
          | $r + .)' "$rows" > "$out" 2>/dev/null && [[ -s "$out" ]]; then
    mv "$out" "$rows"
  else
    warn "DEGRADED: could not derive the plan tier and price columns — they show as unknown"
  fi
}

# Marks, on each row, whether it carries its account's values in the table: the first
# row of the account that has any of them, or its first row when none does, so a
# multi-row account (Cursor pools, Antigravity groups, five-hour rows) is shown once.
stamp_account_primary() { # <doc-json-file>
  local doc="$1" out="$TMP/doc.primary.json"
  if jq '
      def has_data: (.paid_enabled != null or .paid_cap_usd != null or .paid_cap_unlimited != null or .paid_spent_usd != null
                     or .limit_resets_available != null or .top_label != null or .plan_tier != null);
      .rows as $rows
      | ($rows | to_entries
         | reduce .[] as $e ({first: {}, data: {}};
             ([$e.value.provider, $e.value.label] | tojson) as $k
             | .first[$k] = (.first[$k] // $e.key)
             | if ($e.value | has_data) then .data[$k] = (.data[$k] // $e.key) else . end)) as $idx
      | def groups: [["paid_enabled","paid_cap_usd","paid_cap_unlimited","paid_spent_usd","paid_currency","paid_period","paid_read_at_epoch"],
                      ["limit_resets_available","limit_resets"], ["top_label","top_used_pct","top_resets_at_epoch"],
                      ["plan_tier","plan_tier_source","plan_usd_month","plan_price_source"]];
        # Each group of values (paid usage, resets, top tier) is shown once per account, on the
        # primary row. A group the primary row lacks is taken whole from the first other row of the
        # same account that has it, so one known value never prints as `-` because it sits on a
        # different row; groups are never mixed field by field.
        def fill($r; $all): reduce groups[] as $g ($r;
          if ([$g[] as $k | $r[$k]] | any(. != null)) then .
          else ([$all[] | select(.provider == $r.provider and .label == $r.label) | select([$g[] as $k | .[$k]] | any(. != null))] | first) as $src
               | if $src == null then . else . + ($src | with_entries(select(.key as $k | ($g | index($k)) != null))) end end);
      .rows = [ $rows | to_entries[] | .key as $i | .value
                | (($i == ($idx.data[([.provider, .label] | tojson)] // $idx.first[([.provider, .label] | tojson)]))) as $p
                | (if $p then fill(.; $rows) else . end) + {account_primary: $p} ]' \
      "$doc" > "$out" 2>/dev/null && [[ -s "$out" ]]; then
    mv "$out" "$doc"
  else
    warn "could not mark each account's first row"
  fi
}

render_quota_table() {
  # Rendered ONCE, to a file, then printed.
  TABLE="$TMP/table.txt"
  # Each action leads its account output and is printed once even for multi-pool
  # accounts. Keep the diagnostic detail unchanged in JSON for existing callers.
  jq -r '[.rows[] | select(.action != null) | {provider,label,action}] | unique[] | .action' "$DOC"
  # Laid out here rather than by column(1) (#2409): the paid-usage, resets and top-tier
  # columns put the table at the edge of 140 columns, so cells are one space apart, a
  # note or overage label too long for its cell is moved to a numbered footnote under the
  # table (`[1]` in the row, the text below), and the two icons are measured as the two
  # terminal columns they occupy, which column(1) does not do. Every cell is stripped of
  # control characters, so a hostile label or detail cannot forge a row or a column.
  jq -r '
      def pct: if . == null then "-" else "\(.)%" end;
      def dash: if . == null or . == "" then "-" else . end;
      # One decimal, always: 25 and 25.0 in one column read as different kinds of
      # number, and the projection is an estimate in every cell.
      def one_dp: if . == null then "-"
                  else (tostring | if test("\\.") then . else . + ".0" end) end;
      def cents: (. * 100 | round);
      def two_dp: cents as $c | (($c / 100) | floor | tostring) + "." + (($c % 100) | tostring | if length < 2 then "0" + . else . end);
      # A cap prints without cents when it is a whole number of dollars ($500), spend
      # always with them ($0.00), so a $0 spend is plainly a figure and not a gap.
      def cap_usd: if (cents % 100) == 0 then "$" + ((cents / 100) | tostring) else "$" + two_dp end;
      def num: type == "number";
      # A currency other than USD never prints as dollars (the JSON keeps whatever was saved).
      def foreign: (.paid_currency | type) == "string" and .paid_currency != "USD";
      def clean: if type == "string" then gsub("[\u0000-\u001f\u007f]"; " ") else . end;
      # Terminal width: the two icons and East Asian wide characters take two columns, combining marks none.
      def wide: explode | map(if . >= 768 and . <= 879 then 0
                                       elif . == 9989 or . == 10060 or . >= 127744
                                         or (. >= 4352 and . <= 4447) or (. >= 11904 and . <= 42191)
                                         or (. >= 44032 and . <= 55203) or (. >= 63744 and . <= 64255)
                                         or (. >= 65040 and . <= 65049) or (. >= 65072 and . <= 65135)
                                         or (. >= 65280 and . <= 65376) or (. >= 65504 and . <= 65510) then 2 else 1 end) | add // 0;
      # Issue #2469: a cell wider than its ceiling is cut with an ellipsis so the table stays within 140 columns for every value setup accepts; --json keeps the full value.
      def fit0($n): . as $t | if ($t | wide) <= $n then $t
                          else ([range($t | length; -1; -1) | select(($t[0:.] | wide) <= ($n - 1))] | first) as $k | $t[0:$k] + "…" end;
      # The trailing `*` (set by hand) survives a cut.
      def fit($n): if endswith("*") and length > 1 then (.[:-1] | fit0($n - 1)) + "*" else fit0($n) end;
      def spaces($n): [range(0; $n)] | map(" ") | join("");
      def pad($w): . + spaces($w - wide);
      # Account-level values print on the row that carries them and are blank on the
      # rest, so a two-pool or two-window account is never counted twice by eye.
      def fnum($foot; $t): "[" + (([$foot | to_entries[] | select(.value == $t) | .key][0]) + 1 | tostring) + "]";
      .rows
      | map(
          . as $x
          | {
            acct: ((.nickname // .reported_email) | if type == "string" then fit(24) else . end),
            # The pool name when the provider has pools, the window otherwise. A
            # composite Antigravity window (`<group> <window>`) is shortened to
            # `<group> 7d` / `<group> 5h`.
            win: ((.pool // .window) | if test(" ") then (sub("-hour$"; "h") | sub("-day$"; "d")) else . end
                  # Issue #2469: capped at 13 columns to make room for TIER and $/MO; a long composite name keeps its window suffix.
                  | if length <= 13 then .
                    elif test(" ") then (split(" ") | .[-1] as $t | (.[:-1] | join(" ")) as $g | $g[0:(11 - ($t | length))] + "… " + $t)
                    else .[0:12] + "…" end),
            # A failed read with a saved (last-known) figure shows the saved percent here and
            # its date in FETCHED; the reason and the "last known" explanation are in the
            # note, which is a footnote. An expired saved figure, or none, stays `-`.
            # --json keeps used_pct null for such a row; only this table cell borrows it.
            used: (if (.used_pct | num) then (.used_pct | pct)
                   elif (.last_known_used_pct | num) and .last_known_expired != true then (.last_known_used_pct | pct)
                   else "-" end),
            fetched: (.fetched_display | dash),
            # `<=` (the record does not reach back to the window start) is one symbol wide here.
            start: (.usage_start_display | dash | sub("^<="; "≤")),
            pday: (.pct_per_day | one_dp),
            left: (if .days_left != null then (.days_left | one_dp)
                   else (.days_left_note | if . == "resets first" then "resets" else . end | dash) end),
            ovg: (.overage.label? | dash),
            paid: (if .account_primary == false then "-"
                   elif .paid_enabled == true then "✅" elif .paid_enabled == false then "❌" else "-" end),
            # `off` when the provider said paid usage is off, whatever limit is set (the
            # limit stays in --json), so a $1000 limit never reads as spendable money.
            cap: (if .account_primary == false then "-"
                  elif .paid_enabled == false then "off"
                  elif .paid_cap_unlimited == true then "none"
                  elif foreign then "-"
                  elif ((.paid_cap_usd | num) and .paid_cap_usd >= 0) then (.paid_cap_usd | cap_usd | fit(8))
                  else "-" end),
            spent: (if .account_primary == false or foreign or ((.paid_spent_usd | num) | not) or .paid_spent_usd < 0 then "-" else ("$" + (.paid_spent_usd | two_dp) | fit(9)) end),
            rst: (if .account_primary == false or ((.limit_resets_available | num) | not) or .limit_resets_available < 0 then "-" else (.limit_resets_available | floor | tostring) end),
            tier: (if .account_primary == false or (.plan_tier | type) != "string" then "-"
                   else (((.plan_tier | fit(8)) + (if .plan_tier_source == "override" then "*" else "" end))) end),
            mo: (if .account_primary == false or ((.plan_usd_month | num) | not) then "-"
                 else (((.plan_usd_month | cap_usd | fit(8)) + (if .plan_price_source == "override" then "*" else "" end))) end),
            top: (if .account_primary == false then "-" else (.top_label | dash | if type == "string" then fit(8) else . end) end),
            toppct: (if .account_primary == false or ((.top_used_pct | num) | not) or .top_used_pct < 0 or .top_used_pct > 100 then "-"
                     else (.top_used_pct | (if . == floor then floor else . end) | tostring) + "%" end),
            reset: ((.resets_at_et_short // .resets_at_et
                     // (if (.last_known_used_pct | num) and .last_known_expired != true
                         then (.last_known_resets_et // "" | [match("[A-Z][a-z]{2} [0-9]{1,2}").string][0]) else null end))
                    | dash | sub("(?<h>[0-9]) (?<p>[AP]M)"; "\(.h)\(.p)")),
            # Ten or more days away shows days only (`19d`): the hours are noise at that range, and the column makes room for TIER and $/MO (#2469).
            inn: (.countdown | dash | sub("^in "; "") | sub("^(?<d>[0-9]{2,})d [0-9]+h$"; "\(.d)d")),
            # ACTIONABLE TEXT ONLY (#1700). Provenance (`plan pro`, `via app-server`) is on
            # every --json row. What stays is what the reader must act on: the status word
            # on a row that is not `ok`, the mislabelled-account warning, the detail belonging
            # to the row, and a saved figure (#2280), always labelled last known with its
            # date and source. USED stays a dash on every such row.
            #
            # NO APOSTROPHES ANYWHERE IN THIS jq PROGRAM. It is a single-quoted shell
            # string, so one apostrophe in a comment closes it.
            note: ([ (if (.status // "ok") != "ok" then .status else empty end),
                     (if .label != .reported_email then "registered as \(.label)" else empty end),
                     (if .account_primary != false and (.paid_currency | type) == "string" and .paid_currency != "USD"
                      then "paid amounts are in \(.paid_currency), not shown" else empty end),
                     (if .status == "needs-login" then empty else (.detail | if . == null or . == "" then empty else . end) end),
                     (if .last_known_used_pct == null then empty
                      else ((if .last_known_expired == true then "expired: " else "" end)
                            + "\(.last_known_used_pct)% (last known, \(.last_known_at_et // "" | [match("[A-Z][a-z]{2} [0-9]{1,2}").string][0] // "-"), \(.last_known_source // "unknown"))"
                            + (if .last_known_resets_et == null then ""
                               else "; \(if .last_known_expired == true then "reset" else "resets" end) \(.last_known_resets_et | [match("[A-Z][a-z]{2} [0-9]{1,2}").string][0] // "-")" end))
                      end) ]
                   | join("; ") | if . == "" then "-" else . end)
          }
          | with_entries(.value |= clean)) as $R
      # A label or note longer than its cell goes under the table, numbered in the
      # order it first appears; identical texts share one number.
      | ($R | map((if (.ovg | length) > 8 then .ovg else empty end), (if (.note | length) > 11 then .note else empty end))
         | reduce .[] as $t ([]; if any(.[]; . == $t) then . else . + [$t] end)) as $foot
      | ($R | map([.acct, .win, .used, .fetched, .start, .pday, .left,
                   (if (.ovg | length) > 8 then fnum($foot; .ovg) else .ovg end),
                   .paid, .cap, .spent, .rst, .tier, .mo, .top, .toppct, .reset, .inn,
                   (if (.note | length) > 11 then fnum($foot; .note) else .note end)])) as $body
      | ([["ACCOUNT", "WINDOW", "USED", "FETCHED", "START", "%/DAY", "LEFT", "OVERAGE", "$?", "$ CAP", "$", "RST", "TIER", "$/MO", "TOP", "TOP%", "RESET (ET)", "IN", "NOTE"]] + $body) as $all
      | ($all[0] | length) as $n
      | ([range(0; $n)] | map(. as $c | [$all[] | .[$c] | wide] | max)) as $w0
      # Issue #2469: past 140 columns the widest of the cut-able columns (account, window, $ cap, $, tier, $/MO, top) gives up one column at a time, down to 7, and its cells are cut to fit; --json keeps every full value.
      | ([0, 1, 9, 10, 12, 13, 14]) as $red
      | (reduce range(0; 80) as $_ ($w0;
           . as $w
           | if (($w | add) + $n - 1) > 140
             then ([$red[] | select($w[.] > 7)] | if length == 0 then $w else (max_by($w[.]) as $i | $w | .[$i] -= 1) end)
             else $w end)) as $w
      | ($all | map(. as $r | reduce $red[] as $c ($r; .[$c] = (.[$c] | fit($w[$c]))))) as $all
      | ($all[] | . as $row | [range(0; $n)]
         | map(. as $c | if $c == $n - 1 then $row[$c] else ($row[$c] | pad($w[$c])) end) | join(" ")),
        (if ($foot | length) > 0 then "", ($foot | to_entries[] | "[\(.key + 1)] \(.value)") else empty end),
        (if any($R[]; (.tier | endswith("*")) or (.mo | endswith("*"))) then (if ($foot | length) > 0 then empty else "" end), "* set by hand with ai-quotas-setup.sh plan, not read from the provider" else empty end)' "$DOC" > "$TABLE"
  cat "$TABLE"

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
