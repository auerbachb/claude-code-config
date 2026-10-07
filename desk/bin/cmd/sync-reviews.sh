# shellcheck shell=bash
# summary: pull your merged PRs and captured issues from GitHub into Reviews (R-n), once each
#
# Sourced by desk/bin/human-queue.sh, which has already loaded lib/common.sh
# and lib/db.sh and set HQ_BIN_DIR.

# shellcheck source=../lib/items.sh
. "$HQ_BIN_DIR/lib/items.sh"
# shellcheck source=../lib/secrets.sh
. "$HQ_BIN_DIR/lib/secrets.sh"
# shellcheck source=../lib/lifecycle.sh
. "$HQ_BIN_DIR/lib/lifecycle.sh"
# shellcheck source=../lib/github.sh
. "$HQ_BIN_DIR/lib/github.sh"

# The footer /issue-maker (and the desk's idea entry) writes on every issue it
# files, on a line of its own; the search phrase that finds those issues.
HQ_SYNC_FOOTER='_Captured via /issue-maker._'
HQ_SYNC_PHRASE='"Captured via /issue-maker"'
# GitHub search returns at most 1000 results for one query.
HQ_SYNC_LIMIT_MAX=1000
# Rows per insert transaction: each row is six psql variables on the argv.
HQ_SYNC_CHUNK=50
# How far before the stored watermark the next window starts. A result can
# reach the search index a little after it happened; inserts are idempotent,
# so re-reading the overlap costs nothing.
HQ_SYNC_OVERLAP="1 hour"
HQ_SYNC_WATERMARK_KEY=reviews_watermark

cmd_usage() {
  cat <<'EOF'
human-queue.sh sync-reviews — pull landed work from GitHub into Reviews.

USAGE
  human-queue.sh sync-reviews [--since TIME] [--json]

WHAT IT PULLS
  - every pull request you authored that was merged in the window, in any
    repository (gh search prs --author @me --merged --merged-at ">=TIME")
  - every issue you filed in the window whose body has the line
    _Captured via /issue-maker._ (issues filed by /issue-maker or the desk),
    in any state
  Each becomes one Review (R-n): repo, key pr-<N> or issue-<N>, the title as
  the question, and two context lines (the link, and when it was merged or
  filed), with one `asked` event noted "synced from GitHub". Bodies, diffs,
  and transcripts are never stored: summaries are generated on demand from
  pr-summary-material.sh and cached with `summary set`.

THE WINDOW
  --since TIME  start of the window: YYYY-MM-DD (00:00 UTC) or ISO 8601 with
                a time zone, for example 2026-10-05T14:00-04:00
  Without --since the window starts one hour before the stored watermark
  (the start of the last successful sync; the hour absorbs search-index
  lag). The first sync has no watermark and needs --since: where Reviews
  begin is the operator's call. After every row is written, the watermark
  moves to this sync's start time (never backwards); it is the reserved
  state key reviews_watermark.

ONCE EACH
  Keyed on repository (case-insensitive) plus number: a PR or issue that
  already has a Review, in any status, is never added again, so overlapping
  windows and repeated syncs are safe, and concurrent syncs are serialized.
  A search that returns the full result limit may have been truncated by
  GitHub: the sync stops, writes nothing, and keeps the watermark; run it
  with a later --since.

OUTPUT
  One line per new Review, `R-12 · OWNER/NAME · pr-1787 · title`, then
  `sync-reviews: N new, M already queued (P merged PRs, I captured issues
  since TIME)`, plus `, K skipped (malformed)` when GitHub returned a row
  that cannot be stored. --json prints one object instead: since,
  watermark, merged_prs, captured_issues, already_queued, skipped, and
  created (an array of {id, repo, key, title}).
  A title that looks like a credential is stored as "PR #N (title
  withheld: it looks like a credential)".

ENVIRONMENT
  HUMAN_QUEUE_GH          gh binary override (tests point it at a stub)
  HUMAN_QUEUE_GH_TIMEOUT  seconds each GitHub call may take (default 60)
  HUMAN_QUEUE_SYNC_LIMIT  results asked of each search, 1 to 1000
                          (default 1000)

EXIT CODES
  0  ok (including when nothing is new)
  1  GitHub failed (gh or jq missing, not authenticated, timed out, or a
     search hit the result limit) or the database failed; nothing from the
     failing step is written and the watermark does not move
  4  invalid --since, HUMAN_QUEUE_SYNC_LIMIT, or argument (before any
     connection attempt); no --since and no watermark yet (after connecting)
  7  database unset or unreachable (within two seconds, one line on stderr),
     checked before GitHub is called
EOF
}

# hq__sync_since VAR VALUE — validates --since and stores it in VAR as an ISO
# time with a zone: a bare date means 00:00 UTC.
hq__sync_since() {
  local hq__v="$2" hq__re='^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
  if [[ $hq__v =~ $hq__re ]]; then
    hq__v="${hq__v}T00:00:00Z"
  fi
  hq_check_timestamp "sync-reviews: --since (a date, or a time)" "$hq__v"
  printf -v "$1" '%s' "$hq__v"
}

# The window: the database's clock gives the sync's start time, the watermark
# (if any) gives the default start. One line: START|SINCE (SINCE is empty
# when there is neither --since nor a watermark).
hq__sync_window_sql() {
  cat <<'SQL'
SELECT to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') || '|' ||
       coalesce(to_char(coalesce(nullif(:'hq_since', '')::timestamptz,
                                 (SELECT value::timestamptz FROM state WHERE key = :'hq_wm_key')
                                   - :'hq_overlap'::interval)
                          AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'), '');
SQL
}

# hq__sync_insert_sql N — one chunk of N rows. Every value is a psql variable
# (hq_repo_K, hq_key_K, hq_title_K, hq_url_K, hq_at_K, hq_what_K); only the
# references are generated. The advisory lock serializes concurrent syncs,
# and the NOT EXISTS runs in the statement after it, so it sees what the
# previous lock holder committed. DISTINCT ON drops a row the search returned
# twice. Output: one `id<US>repo<US>key<US>title` line per new item.
hq__sync_insert_sql() {
  local n="$1" k=1 rows=""
  while [ "$k" -le "$n" ]; do
    rows="$rows${rows:+,
  }($k, :'hq_repo_$k', :'hq_key_$k', :'hq_title_$k', :'hq_url_$k', :'hq_at_$k'::timestamptz, :'hq_what_$k')"
    k=$((k + 1))
  done
  cat <<'SQL'
SET LOCAL lock_timeout TO '30s';
SELECT pg_advisory_xact_lock(hashtextextended('human-queue:sync-reviews:' || :'hq_schema', 0)) AS hq_locked \gset
SQL
  printf 'WITH input(n, repo, key, title, url, at, what) AS (VALUES\n  %s\n),\n' "$rows"
  cat <<'SQL'
fresh AS (
  SELECT DISTINCT ON (lower(inp.repo), inp.key) inp.*
    FROM input inp
   WHERE NOT EXISTS (SELECT 1 FROM items i
                      WHERE i.kind = 'review'
                        AND lower(i.repo) = lower(inp.repo)
                        AND i.key = inp.key)
   ORDER BY lower(inp.repo), inp.key, inp.n
),
ins AS (
  INSERT INTO items (id, kind, repo, key, question, context)
  SELECT 'R-' || nextval('items_review_seq'), 'review', f.repo, f.key, f.title,
         ARRAY[f.url, f.what || ' ' || to_char(f.at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI "UTC"')]
    FROM (SELECT * FROM fresh ORDER BY at, n) f
  RETURNING id, repo, key, question
),
ev AS (
  INSERT INTO events (item_id, kind, note)
  SELECT id, 'asked', 'synced from GitHub' FROM ins
)
SELECT string_agg(concat_ws(E'\x1f', id, repo, key, question), E'\n'
                  ORDER BY substring(id FROM 3)::numeric)
  FROM ins;
SQL
}

# The watermark only moves forward, so a slow sync that finishes after a
# newer one cannot rewind it.
hq__sync_watermark_sql() {
  cat <<'SQL'
INSERT INTO state (key, value) VALUES (:'hq_wm_key', :'hq_start')
  ON CONFLICT (key) DO UPDATE
  SET value = CASE WHEN state.value::timestamptz >= EXCLUDED.value::timestamptz
                   THEN state.value ELSE EXCLUDED.value END;
SQL
}

# The jq program that turns both searches into rows, oldest first:
# kind<US>repo<US>number<US>title<US>url<US>at. Issues are kept only when a
# body line, trimmed, is exactly the footer (search matching is by token, so
# it also finds prose that merely mentions the phrase). Titles lose control
# characters and are capped at 500 characters (jq counts code points, as
# Postgres does, so a multi-byte character is never split).
hq__sync_jq() {
  cat <<'JQ'
def clean: (. // "") | gsub("[[:cntrl:]]"; " ") | gsub("^ +| +$"; "")
  | if length > 500 then .[0:499] + "…" else . end;
def row($kind; $at): [$kind, (.repository.nameWithOwner // ""), ((.number // 0) | tostring),
  (.title | clean), (.url // ""), ($at // "")];
( [ $prs[0][] | {r: row("pr"; .closedAt), k: [(.repository.nameWithOwner // "" | ascii_downcase), .number]} ]
  + [ $issues[0][]
      | select(any((.body // "") | split("\n")[]; gsub("^[[:space:]]+|[[:space:]]+$"; "") == $footer))
      | {r: row("issue"; .createdAt), k: [(.repository.nameWithOwner // "" | ascii_downcase), .number]} ] )
| unique_by([.r[0]] + .k)
| sort_by(.r[5], .r[1], (.r[2] | tonumber? // 0))
| .[].r | join("\u001f")
JQ
}

# The --json report: the counts, and one {id, repo, key, title} per new item
# from the `id<US>repo<US>key<US>title` lines on stdin.
hq__sync_report_jq() {
  cat <<'JQ'
{since: $since, watermark: $watermark, merged_prs: $prs, captured_issues: $issues,
 already_queued: $already, skipped: $skipped,
 created: [inputs | select(length > 0) | split("\u001f")
           | {id: .[0], repo: .[1], key: .[2], title: .[3]}]}
JQ
}

# hq__sync_search LABEL OUT ARGS... — one GitHub search into OUT; exits 1 on
# a failure, a timeout, a non-array answer, or a full (possibly truncated)
# result page (a search that returns its limit may have been cut short).
HQ__SYNC_LIMIT="$HQ_SYNC_LIMIT_MAX"
hq__sync_search() {
  local label="$1" out="$2" err rc=0 n
  shift 2
  hq_mktemp err
  hq_gh "$out" "$err" "$@" || rc=$?
  if [ "$rc" -eq 124 ]; then
    hq_die_error "sync-reviews: the GitHub search for $label timed out after $(hq__gh_timeout)s; nothing was written"
  fi
  if [ "$rc" -ne 0 ]; then
    hq_die_error "sync-reviews: the GitHub search for $label failed: $(hq_gh_first_error "$err"); nothing was written"
  fi
  n=$(hq_jq -r 'if type == "array" then length else "bad" end' "$out" 2>/dev/null || printf 'bad')
  case "$n" in
    ''|*[!0-9]*) hq_die_error "sync-reviews: the GitHub search for $label returned something other than a JSON array; nothing was written" ;;
  esac
  if [ "$n" -ge "$HQ__SYNC_LIMIT" ]; then
    hq_die_error "sync-reviews: the GitHub search for $label returned $n results, its limit, so some may be missing; nothing was written and the watermark did not move (run it with a later --since)"
  fi
}

# hq__sync_flush — writes the pending chunk (cmd_run's pv and n_chunk, by
# bash's dynamic scope) and appends its new items to `created`. Each chunk is
# its own transaction: a failure leaves earlier chunks written, which is safe
# because a re-run skips them.
hq__sync_flush() {
  local hq__rc=0 hq__out hq__line
  if [ "$n_chunk" -eq 0 ]; then return 0; fi
  hq__out=$(hq__sync_insert_sql "$n_chunk" | hq_db_script -At "${pv[@]}" 2>"$errf") || hq__rc=$?
  if [ "$hq__rc" -ne 0 ]; then
    hq_fail_unmigrated "$hq__rc" "$errf" \
      "sync-reviews: a batch was not written (any earlier batch was; run it again)" 'items_review_seq'
  fi
  while IFS= read -r hq__line; do
    [ -n "$hq__line" ] || continue
    created="$created${created:+$'\n'}$hq__line"
    n_new=$((n_new + 1))
  done <<EOF
$hq__out
EOF
  pv=()
  n_chunk=0
}

# hq__sync_row_ok KIND REPO NUMBER URL AT — true when a row can be stored.
hq__sync_row_ok() {
  local repo_re='^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' num_re='^[1-9][0-9]{0,9}$'
  local url_re='^https://[^[:space:]]+$' at_re='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?Z$'
  case "$1" in pr|issue) ;; *) return 1 ;; esac
  [ "${#2}" -le 200 ] && [[ $2 =~ $repo_re ]] || return 1
  [[ $3 =~ $num_re ]] || return 1
  [ "${#4}" -le 400 ] && [[ $4 =~ $url_re ]] || return 1
  [[ $5 =~ $at_re ]] || return 1
}

cmd_run() {
  local since="" json=0 seen_since=0 limit errf rc window start
  local prs_json issues_json rows_file kind repo num title url at what
  local n_rows=0 n_chunk=0 n_new=0 n_skipped=0 n_prs=0 n_issues=0 created="" line
  local -a pv=()

  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h|--help)
        cmd_usage
        exit 0
        ;;
      --json)
        json=1
        shift
        ;;
      --since)
        if [ "$seen_since" -eq 1 ]; then hq_die_validation "sync-reviews: --since given more than once"; fi
        if [ "$#" -lt 2 ]; then hq_die_validation "sync-reviews: --since needs a value"; fi
        seen_since=1
        hq__sync_since since "$2"
        shift 2
        ;;
      *) hq_die_validation "sync-reviews: unknown $(hq_flag_name "$1") (run human-queue.sh sync-reviews --help)" ;;
    esac
  done
  limit="${HUMAN_QUEUE_SYNC_LIMIT:-$HQ_SYNC_LIMIT_MAX}"
  case "$limit" in
    ''|*[!0-9]*|0*) hq_die_validation "sync-reviews: HUMAN_QUEUE_SYNC_LIMIT must be a whole number from 1 to $HQ_SYNC_LIMIT_MAX" ;;
  esac
  if [ "${#limit}" -gt 4 ] || [ "$limit" -gt "$HQ_SYNC_LIMIT_MAX" ]; then
    hq_die_validation "sync-reviews: HUMAN_QUEUE_SYNC_LIMIT must be a whole number from 1 to $HQ_SYNC_LIMIT_MAX"
  fi
  HQ__SYNC_LIMIT="$limit"

  # --- the window (the database first, so exit 7 comes before any GitHub call)
  hq_db_connect
  hq_mktemp errf
  rc=0
  window=$(hq__sync_window_sql | hq_db_script -At -v "hq_since=$since" \
    -v "hq_wm_key=$HQ_SYNC_WATERMARK_KEY" -v "hq_overlap=$HQ_SYNC_OVERLAP" 2>"$errf") || rc=$?
  if [ "$rc" -ne 0 ]; then
    hq_db_fail "$rc" "$errf" "sync-reviews: nothing was written"
  fi
  start="${window%%|*}"
  since="${window#*|}"
  if [ -z "$start" ] || [ "$start" = "$window" ]; then
    hq_die_error "sync-reviews: the store returned no start time"
  fi
  if [ -z "$since" ]; then
    hq_die_validation "sync-reviews: no watermark is stored yet: give the first window with --since (for example --since 2026-10-01)"
  fi

  # --- GitHub -----------------------------------------------------------------
  hq_gh_find || hq_die_error "sync-reviews: gh not found (HUMAN_QUEUE_GH, /opt/homebrew/bin/gh, or PATH); nothing was written"
  hq_jq_find || hq_die_error "sync-reviews: jq not found (PATH, /opt/homebrew/bin/jq, or /usr/bin/jq); nothing was written"
  hq_mktemp prs_json
  hq_mktemp issues_json
  hq__sync_search "merged PRs" "$prs_json" search prs --author @me --merged \
    --merged-at ">=$since" --json repository,number,title,url,closedAt --limit "$limit"
  hq__sync_search "captured issues" "$issues_json" search issues "$HQ_SYNC_PHRASE" --match body \
    --author @me --created ">=$since" --json repository,number,title,url,createdAt,body --limit "$limit"

  hq_mktemp rows_file
  rc=0
  hq_jq -n -r --slurpfile prs "$prs_json" --slurpfile issues "$issues_json" \
    --arg footer "$HQ_SYNC_FOOTER" "$(hq__sync_jq)" >"$rows_file" 2>"$errf" || rc=$?
  if [ "$rc" -ne 0 ]; then
    hq_die_error "sync-reviews: could not read the GitHub results: $(hq_gh_first_error "$errf"); nothing was written"
  fi

  # --- write, one chunk at a time ----------------------------------------------
  while IFS=$'\x1f' read -r kind repo num title url at || [ -n "$kind" ]; do
    [ -n "$kind" ] || continue
    n_rows=$((n_rows + 1))
    case "$kind" in
      pr) n_prs=$((n_prs + 1)) ;;
      issue) n_issues=$((n_issues + 1)) ;;
    esac
    if ! hq__sync_row_ok "$kind" "$repo" "$num" "$url" "$at"; then
      n_skipped=$((n_skipped + 1))
      continue
    fi
    case "$kind" in
      pr) what=Merged ;;
      *) what=Filed ;;
    esac
    case "$title" in
      *[![:space:]]*) ;;
      *) title="(untitled)" ;;
    esac
    if hq__secret_class "$title"; then
      if [ "$kind" = pr ]; then
        title="PR #$num (title withheld: it looks like a credential)"
      else
        title="Issue #$num (title withheld: it looks like a credential)"
      fi
    fi
    n_chunk=$((n_chunk + 1))
    pv[${#pv[@]}]=-v; pv[${#pv[@]}]="hq_repo_$n_chunk=$repo"
    pv[${#pv[@]}]=-v; pv[${#pv[@]}]="hq_key_$n_chunk=$kind-$num"
    pv[${#pv[@]}]=-v; pv[${#pv[@]}]="hq_title_$n_chunk=$title"
    pv[${#pv[@]}]=-v; pv[${#pv[@]}]="hq_url_$n_chunk=$url"
    pv[${#pv[@]}]=-v; pv[${#pv[@]}]="hq_at_$n_chunk=$at"
    pv[${#pv[@]}]=-v; pv[${#pv[@]}]="hq_what_$n_chunk=$what"
    if [ "$n_chunk" -ge "$HQ_SYNC_CHUNK" ]; then
      hq__sync_flush
    fi
  done <"$rows_file"
  hq__sync_flush

  rc=0
  hq__sync_watermark_sql | hq_db_script -At -v "hq_wm_key=$HQ_SYNC_WATERMARK_KEY" \
    -v "hq_start=$start" >/dev/null 2>"$errf" || rc=$?
  if [ "$rc" -ne 0 ]; then
    hq_db_fail "$rc" "$errf" "sync-reviews: the Reviews were written but the watermark did not move (the next sync re-reads this window safely)"
  fi

  # --- report -------------------------------------------------------------------
  if [ "$json" -eq 1 ]; then
    printf '%s' "$created" | hq_jq -R -n -c \
      --arg since "$since" --arg watermark "$start" \
      --argjson prs "$n_prs" --argjson issues "$n_issues" \
      --argjson already "$((n_rows - n_skipped - n_new))" --argjson skipped "$n_skipped" \
      "$(hq__sync_report_jq)"
    return 0
  fi
  if [ -n "$created" ]; then
    while IFS=$'\x1f' read -r line repo kind title; do
      printf '%s · %s · %s · %s\n' "$line" "$repo" "$kind" "$title"
    done <<EOF
$created
EOF
  fi
  line="sync-reviews: $n_new new, $((n_rows - n_skipped - n_new)) already queued ($n_prs merged PRs, $n_issues captured issues since $since)"
  if [ "$n_skipped" -gt 0 ]; then
    line="${line%)}, $n_skipped skipped (malformed))"
  fi
  printf '%s\n' "$line"
}
