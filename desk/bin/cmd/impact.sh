# shellcheck shell=bash
# summary: derive open Decisions' impact from the /pm backlog rank, open dependents, and the parked flag; stored beside the declared impact, it orders items
#
# Sourced by desk/bin/human-queue.sh, which has already loaded lib/common.sh
# and lib/db.sh and set HQ_BIN_DIR and HQ_DESK_DIR.

# shellcheck source=../lib/items.sh
. "$HQ_BIN_DIR/lib/items.sh"
# shellcheck source=../lib/lifecycle.sh
. "$HQ_BIN_DIR/lib/lifecycle.sh"
# shellcheck source=../lib/github.sh
. "$HQ_BIN_DIR/lib/github.sh"

cmd_usage() {
  cat <<'EOF'
human-queue.sh impact — derive an item's impact from what its issue really
unblocks (issue #1760).

USAGE
  human-queue.sh impact OWNER/REPO ISSUE [--json] [--no-store]
  human-queue.sh impact --open [--max-age MIN] [--json]

ARGUMENTS
  OWNER/REPO ISSUE  derive for issue ISSUE (`42` or `#42`) of that GitHub
                    repo, and store the result on its open Decisions: those
                    keyed issue-ISSUE in that repo (the key a worker's
                    `issue-N-…` branch gives its questions; the repo is
                    compared case-insensitively)
  --open            derive for every open Decision keyed issue-<N> whose
                    derived impact is missing or older than --max-age, one
                    GitHub read per repo. Decisions of a `local/…` repo (no
                    GitHub remote) are skipped. The desk runs this before it
                    reads a batch (desk/skill/decisions.md)
  --max-age MIN     with --open: re-derive after MIN minutes, 0 to 10080
                    (default 60; 0 re-derives every open Decision keyed by
                    an issue)
  --no-store        derive and print only: no database connection, no write
                    (the parked flag is then unknown and reads as not parked)
  --json            print JSON instead of text

THE INPUTS
  rank        /pm's latest ranking of the repo's backlog, the order it
              presented with the operator's order overlaid
              (pm-rank-cache.sh read; /pm writes it at Step 1B.4c). Used only
              while under 24 hours old; otherwise the rank is unknown. An
              issue a fresh ranking does not hold (in flight, excluded, or
              below the shortlist) is not ranked.
  dependents  the open issues that depend on ISSUE, counted down every chain
              (issue-deps.sh dependents over the repo's open issues, bodies
              and comments: the `Depends on #N` reading /pm and /wave use)
  parked      the Decision's own flag: its agent waits on the answer

THE RULE
  critical-path  dependents >= critical_path_min_dependents (default 2), or a
                 fresh rank <= critical_path_rank_top_n (default 3)
  medium         otherwise, at least one dependent, or the Decision is parked
  low            otherwise
  Both thresholds come from desk/policy.json (desk-policy.sh; its defaults
  when it cannot be read). Declared impact is never an input: a leaf issue at
  rank 40 derives low whatever its asker declared.

WHAT IT STORES
  On each matching open Decision: impact_derived, impact_basis (the inputs in
  words: `2 open dependents, backlog rank unknown`, plus `, agent parked`),
  and impact_derived_at. impact_declared is never changed. Every order that
  reads impact (tick, list, the desk's sets, the day plan's clear-first
  batch, the end-of-day sweep) uses the derived value where there is one:
  critical-path, high, medium, low, none. A derivation is not a change
  `tick` reports, and records no event. Reviews are never derived: they keep
  their own order.

  When the repo's open issues cannot be read (gh missing, failing, or past
  HUMAN_QUEUE_GH_TIMEOUT), or the read returns 500 issues (gh's --limit,
  which it stops at silently, so the list may be cut off), nothing is stored
  for that repo: an outage never demotes an item.

OUTPUT
  Text: `owner/repo#ISSUE: <impact> (<basis>)`, then `  D-n <impact>` for
  each Decision it stored on (`  no open Decision is keyed issue-N` when
  none; `  not stored (--no-store)`). --open prints the same block per issue.
  JSON (ISSUE form): {"repo", "issue", "rank_status", "rank_reason", "rank",
  "tier", "dependents", "direct", "transitive", "cycle", "impact", "basis",
  "thresholds": {"critical_path_rank_top_n", "critical_path_min_dependents"},
  "stored", "items": [{"id", "parked", "impact_declared", "impact_derived",
  "impact_basis"}]}. --open --json: {"max_age_min", "reports": [those
  objects], "skipped": [{"repo", "reason"}], "failed": [{"repo",
  "reason"}]}.

EXIT CODES
  0  ok (including nothing to derive, or no Decision to store on)
  1  the repo's open issues could not be read, or a helper script is missing
     (one line on stderr; with --open, after storing every repo that could be
     read and printing their results); or an unexpected database failure
     (for example the store is not migrated: run human-queue.sh migrate)
  4  usage: a bad repo, issue, flag, or --max-age (before any connection
     attempt)
  7  database unset or unreachable (within two seconds, one line on stderr)

HELPERS
  issue-deps.sh and pm-rank-cache.sh are found in the desk's own checkout
  (.claude/scripts next to desk/), else ~/.claude/skills-worktree/.claude/
  scripts, else ~/.claude/scripts. Without pm-rank-cache.sh the rank is
  unknown; without issue-deps.sh nothing is derived (exit 1). GitHub is read
  through gh (HUMAN_QUEUE_GH, else /opt/homebrew/bin/gh, else PATH).
EOF
}

HQ_IMPACT_MAX_AGE_DEFAULT=60
# The open-issue read's --limit (issue-deps.sh's and /pm's cap). gh stops there
# without saying so, so a read that fills it may be cut off.
HQ_IMPACT_ISSUE_LIMIT=500
# The policy's defaults (desk/hooks/capture.py POLICY_DEFAULTS), used only
# when desk-policy.sh cannot run at all.
HQ_IMPACT_TOP_N=3
HQ_IMPACT_MIN_DEPS=2

# hq__impact_script VAR NAME — the first executable NAME among the desk's own
# checkout, the skills worktree, and ~/.claude/scripts, into VAR.
hq__impact_script() {
  local hq__c hq__home="${HOME:-}"
  for hq__c in "$HQ_DESK_DIR/../.claude/scripts/$2" \
    ${hq__home:+"$hq__home/.claude/skills-worktree/.claude/scripts/$2"} \
    ${hq__home:+"$hq__home/.claude/scripts/$2"}; do
    if [ -x "$hq__c" ] && [ ! -d "$hq__c" ]; then
      printf -v "$1" '%s' "$hq__c"
      return 0
    fi
  done
  return 1
}

# hq__impact_helper SCRIPT ARGS... — runs a helper script without the
# database URL in its environment, with the jq this CLI found on its PATH.
hq__impact_helper() {
  (
    unset HUMAN_QUEUE_DATABASE_URL
    PATH="$(dirname "$HQ_JQ"):$PATH"
    export PATH
    exec "$@"
  ) </dev/null
}

# hq__impact_thresholds — reads the two thresholds from desk/policy.json
# (desk-policy.sh, which applies the policy's own validation and defaults).
hq__impact_thresholds() {
  local pol v rc=0
  pol=$("$HQ_BIN_DIR/desk-policy.sh" 2>/dev/null) || rc=$?
  if [ "$rc" -ne 0 ]; then return 0; fi
  v=$(printf '%s' "$pol" | hq_jq -r '.critical_path_rank_top_n // empty' 2>/dev/null) || v=""
  case "$v" in ''|*[!0-9]*) ;; *) HQ_IMPACT_TOP_N="$v" ;; esac
  v=$(printf '%s' "$pol" | hq_jq -r '.critical_path_min_dependents // empty' 2>/dev/null) || v=""
  case "$v" in ''|*[!0-9]*) ;; *) HQ_IMPACT_MIN_DEPS="$v" ;; esac
}

# hq__impact_derive_repo REPO OUT ISSUE... — the reports for ISSUE... of REPO
# (impact.jq's impact_reports) into the file OUT. Returns 1 with the reason in
# HQ_IMPACT_ERR when the open issues cannot be read or parsed.
HQ_IMPACT_ERR=""
hq__impact_derive_repo() {
  local repo="$1" out="$2" rankf depsf issuesf errf rank_sh deps_sh rc=0 t n
  shift 2
  HQ_IMPACT_ERR=""
  hq_mktemp rankf
  hq_mktemp depsf
  hq_mktemp issuesf
  hq_mktemp errf

  if ! hq__impact_script deps_sh issue-deps.sh; then
    HQ_IMPACT_ERR="issue-deps.sh not found (the desk's checkout, ~/.claude/skills-worktree, ~/.claude/scripts) — dependents unavailable"
    return 1
  fi
  # The rank: an unknown one is a normal answer, so any failure reads as unknown.
  printf '{"status":"unknown","reason":"no-helper","issues":[]}\n' > "$rankf"
  if hq__impact_script rank_sh pm-rank-cache.sh; then
    rc=0
    hq__impact_helper "$rank_sh" read "$repo" "$@" > "$rankf" 2>/dev/null || rc=$?
    if [ "$rc" -ne 0 ] || ! hq_jq -e 'type == "object"' "$rankf" >/dev/null 2>&1; then
      printf '{"status":"unknown","reason":"helper-failed","issues":[]}\n' > "$rankf"
    fi
  fi

  # The repo's open issues, bodies and comments: the same read issue-deps.sh
  # does on its own, through this CLI's gh (deadline, stub, no database URL).
  if [ -z "$HQ_GH" ] && ! hq_gh_find; then
    HQ_IMPACT_ERR="gh not found (HUMAN_QUEUE_GH, /opt/homebrew/bin/gh, or PATH) — dependents unknown"
    return 1
  fi
  rc=0
  hq_gh "$issuesf" "$errf" issue list --repo "$repo" --state open --limit "$HQ_IMPACT_ISSUE_LIMIT" \
    --json number,body,comments || rc=$?
  if [ "$rc" -eq 124 ]; then
    t=$(hq__gh_timeout)
    HQ_IMPACT_ERR="reading the open issues of $repo timed out after ${t}s — dependents unknown"
    return 1
  fi
  if [ "$rc" -ne 0 ]; then
    HQ_IMPACT_ERR="reading the open issues of $repo failed: $(hq_gh_first_error "$errf") — dependents unknown"
    return 1
  fi
  # A full page may be a cut-off list, and a cut-off list undercounts
  # dependents: treat it as a failed read, never as fewer dependents.
  n=$(hq_jq 'if type == "array" then length else 0 end' "$issuesf" 2>/dev/null) || n=""
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  if [ "$n" -ge "$HQ_IMPACT_ISSUE_LIMIT" ]; then
    HQ_IMPACT_ERR="reading the open issues of $repo returned $n, the ${HQ_IMPACT_ISSUE_LIMIT}-issue limit, so the list may be cut off — dependents unknown"
    return 1
  fi
  rc=0
  hq__impact_helper "$deps_sh" dependents --input "$issuesf" "$@" > "$depsf" 2>"$errf" || rc=$?
  if [ "$rc" -ne 0 ] || ! hq_jq -e '(.issues | type) == "array"' "$depsf" >/dev/null 2>&1; then
    HQ_IMPACT_ERR="issue-deps.sh could not read the open issues of $repo: $(hq_gh_first_error "$errf")"
    return 1
  fi

  hq_jq -c -L "$HQ_BIN_DIR/lib" --slurpfile rank "$rankf" --slurpfile deps "$depsf" \
    --argjson top "$HQ_IMPACT_TOP_N" --argjson min "$HQ_IMPACT_MIN_DEPS" \
    -n 'include "impact"; impact_reports($rank[0]; $deps[0]; $top; $min)' > "$out" \
    || { HQ_IMPACT_ERR="the impact rule failed for $repo"; return 1; }
}

# hq__impact_store_sql — one statement: every open Decision keyed by a
# payload issue in :'hq_repo' takes its value, the parked choice made per row
# from the row itself, so a parked flag that changes meanwhile is never
# overwritten with a stale reading. Prints the rows it wrote as JSON.
hq__impact_store_sql() {
  cat <<'SQL'
SET LOCAL lock_timeout TO '30s';
WITH d AS (
  SELECT * FROM jsonb_to_recordset(:'hq_payload'::jsonb)
    AS x(issue bigint, impact text, impact_parked text, basis text, basis_parked text)
), u AS (
  UPDATE items i
     SET impact_derived = CASE WHEN i.parked THEN d.impact_parked ELSE d.impact END,
         impact_basis = CASE WHEN i.parked THEN d.basis_parked ELSE d.basis END,
         impact_derived_at = statement_timestamp()
    FROM d
   WHERE i.kind = 'decision' AND i.status = 'open'
     AND lower(i.repo) = lower(:'hq_repo') AND i.key = 'issue-' || d.issue
  RETURNING i.id, i.key, i.parked, i.impact_declared, i.impact_derived, i.impact_basis, i.created_at
)
SELECT coalesce(jsonb_agg(jsonb_build_object('id', id, 'issue', substr(key, 7)::bigint, 'parked', parked,
                                             'impact_declared', impact_declared,
                                             'impact_derived', impact_derived,
                                             'impact_basis', impact_basis)
                          ORDER BY created_at, id), '[]'::jsonb)
  FROM u;
SQL
}

# hq__impact_store REPO REPORTS OUT — writes REPORTS (a file) for REPO and the
# stored rows (JSON) into the file OUT. Exits through hq_fail_unmigrated.
hq__impact_store() {
  local repo="$1" reports="$2" out="$3" payload errf rc=0
  hq_mktemp errf
  payload=$(hq_jq -c -L "$HQ_BIN_DIR/lib" 'include "impact"; impact_payload' "$reports") \
    || hq_die_error "impact: cannot build the payload for $repo; nothing was stored"
  hq__impact_store_sql | hq_db_script -At -v "hq_repo=$repo" -v "hq_payload=$payload" >"$out" 2>"$errf" || rc=$?
  if [ "$rc" -ne 0 ]; then
    hq_fail_unmigrated "$rc" "$errf" "impact: nothing was stored for $repo" 'impact_derived'
  fi
}

# hq__impact_open_sql — the (repo, issues) pairs `--open` derives for.
hq__impact_open_sql() {
  cat <<'SQL'
SELECT coalesce(jsonb_agg(jsonb_build_object('repo', r.repo, 'issues', to_jsonb(r.issues)) ORDER BY r.repo), '[]'::jsonb)
  FROM (SELECT lower(i.repo) AS repo,
               array_agg(DISTINCT substr(i.key, 7)::bigint ORDER BY substr(i.key, 7)::bigint) AS issues
          FROM items i
         WHERE i.kind = 'decision' AND i.status = 'open'
           AND i.key ~ '^issue-[1-9][0-9]{0,9}$'
           AND (i.impact_derived_at IS NULL
                OR i.impact_derived_at <= statement_timestamp() - make_interval(mins => :'hq_max_age'::int))
         GROUP BY lower(i.repo)) r;
SQL
}

# hq__impact_text REPORT ITEMS STORED — one issue's text block.
hq__impact_text() {
  hq_jq -r --argjson items "$2" --argjson stored "$3" '
    "\(.repo)#\(.issue): \(.impact) (\(.basis))",
    (if $stored | not then "  not stored (--no-store)"
     elif ($items | length) == 0 then "  no open Decision is keyed issue-\(.issue)"
     else ($items[] | "  \(.id) \(.impact_derived)" + (if .parked then " (agent parked)" else "" end)) end)' <<EOF
$1
EOF
}

hq__impact_one() {
  local repo="$1" issue="$2" json="$3" store="$4" reports report items="[]"
  hq_mktemp reports
  if ! hq__impact_derive_repo "$repo" "$reports" "$issue"; then
    hq_die_error "impact: $HQ_IMPACT_ERR; nothing was stored"
  fi
  if [ "$store" -eq 1 ]; then
    local stored_f
    hq_mktemp stored_f
    hq__impact_store "$repo" "$reports" "$stored_f"
    items=$(cat "$stored_f")
    [ -n "$items" ] || items="[]"
  fi
  report=$(hq_jq -c --arg repo "$repo" --argjson items "$items" --argjson stored "$([ "$store" -eq 1 ] && echo true || echo false)" \
    --argjson top "$HQ_IMPACT_TOP_N" --argjson min "$HQ_IMPACT_MIN_DEPS" '
    .[0] | {repo: $repo} + del(.impact_parked, .basis_parked)
    + {thresholds: {critical_path_rank_top_n: $top, critical_path_min_dependents: $min},
       stored: $stored, items: $items}' "$reports") \
    || hq_die_error "impact: cannot build the report"
  if [ "$json" -eq 1 ]; then
    printf '%s\n' "$report"
  else
    hq__impact_text "$report" "$items" "$([ "$store" -eq 1 ] && echo true || echo false)"
  fi
}

hq__impact_open() {
  local json="$1" max_age="$2" errf rc=0 pairs repo issues_csv reports stored_f items
  local all_reports="[]" skipped="[]" failed="[]" text="" one first_fail=""
  local -a issue_list
  hq_mktemp errf
  pairs=$(hq__impact_open_sql | hq_db_script -At -v "hq_max_age=$max_age" 2>"$errf") || rc=$?
  if [ "$rc" -ne 0 ]; then
    hq_fail_unmigrated "$rc" "$errf" "impact: nothing was derived" 'impact_derived_at'
  fi
  [ -n "$pairs" ] || pairs="[]"
  hq_mktemp reports
  hq_mktemp stored_f
  while IFS= read -r repo; do
    [ -n "$repo" ] || continue
    issues_csv=$(printf '%s' "$pairs" | hq_jq -r --arg r "$repo" '.[] | select(.repo == $r) | .issues | map(tostring) | join(" ")')
    case "$repo" in
      local/*)
        skipped=$(printf '%s' "$skipped" | hq_jq -c --arg r "$repo" '. + [{repo: $r, reason: "no GitHub remote"}]')
        continue
        ;;
    esac
    if ! [[ $repo =~ ^[a-z0-9._-]+/[a-z0-9._-]+$ ]]; then
      skipped=$(printf '%s' "$skipped" | hq_jq -c --arg r "$repo" '. + [{repo: $r, reason: "not a GitHub owner/repo"}]')
      continue
    fi
    issue_list=()
    read -r -a issue_list <<EOF
$issues_csv
EOF
    if ! hq__impact_derive_repo "$repo" "$reports" ${issue_list[@]+"${issue_list[@]}"}; then
      failed=$(printf '%s' "$failed" | hq_jq -c --arg r "$repo" --arg why "$HQ_IMPACT_ERR" '. + [{repo: $r, reason: $why}]')
      [ -n "$first_fail" ] || first_fail="$HQ_IMPACT_ERR"
      continue
    fi
    hq__impact_store "$repo" "$reports" "$stored_f"
    items=$(cat "$stored_f")
    [ -n "$items" ] || items="[]"
    one=$(hq_jq -c --arg repo "$repo" --argjson items "$items" \
      --argjson top "$HQ_IMPACT_TOP_N" --argjson min "$HQ_IMPACT_MIN_DEPS" '
      map(. as $r | {repo: $repo} + ($r | del(.impact_parked, .basis_parked))
          + {thresholds: {critical_path_rank_top_n: $top, critical_path_min_dependents: $min},
             stored: true, items: [ $items[] | select(.issue == $r.issue) | del(.issue) ]})' "$reports")
    all_reports=$(printf '%s\n%s\n' "$all_reports" "$one" | hq_jq -c -s 'add')
  done <<EOF
$(printf '%s' "$pairs" | hq_jq -r '.[].repo')
EOF

  if [ "$json" -eq 1 ]; then
    hq_jq -n -c --argjson max "$max_age" --argjson reports "$all_reports" \
      --argjson skipped "$skipped" --argjson failed "$failed" \
      '{max_age_min: $max, reports: $reports, skipped: $skipped, failed: $failed}'
  else
    while IFS= read -r one; do
      [ -n "$one" ] || continue
      text=$(hq__impact_text "$one" "$(printf '%s' "$one" | hq_jq -c '.items')" true)
      printf '%s\n' "$text"
    done <<EOF
$(printf '%s' "$all_reports" | hq_jq -c '.[]')
EOF
    printf '%s' "$skipped" | hq_jq -r '.[] | "skipped \(.repo): \(.reason)"'
  fi
  if [ -n "$first_fail" ]; then
    hq_die_error "impact: $first_fail; nothing was stored for that repo$(printf '%s' "$failed" | hq_jq -r 'if length > 1 then " (and \(length - 1) more)" else "" end')"
  fi
}

cmd_run() {
  local json=0 store=1 open=0 max_age="" have_max=0 repo="" issue="" n=0 a
  for a in "$@"; do
    case "$a" in
      -h|--help)
        cmd_usage
        exit 0
        ;;
    esac
  done
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --json) json=1 ;;
      --no-store) store=0 ;;
      --open) open=1 ;;
      --max-age)
        if [ "$have_max" -eq 1 ]; then hq_die_validation "impact: --max-age given more than once"; fi
        if [ "$#" -lt 2 ]; then hq_die_validation "impact: --max-age needs a number of minutes"; fi
        have_max=1
        max_age="$2"
        shift
        ;;
      -*) hq_die_validation "impact: unknown $(hq_flag_name "$1") (run human-queue.sh impact --help)" ;;
      *)
        case "$n" in
          0) repo="$1" ;;
          1) issue="$1" ;;
          *) hq_die_validation "impact: takes OWNER/REPO and one ISSUE (run human-queue.sh impact --help)" ;;
        esac
        n=$((n + 1))
        ;;
    esac
    shift
  done

  if [ "$open" -eq 1 ]; then
    if [ "$n" -gt 0 ]; then hq_die_validation "impact: --open takes no OWNER/REPO or ISSUE"; fi
    if [ "$store" -eq 0 ]; then hq_die_validation "impact: --open stores what it derives; --no-store is for one issue"; fi
    if [ "$have_max" -eq 0 ]; then max_age="$HQ_IMPACT_MAX_AGE_DEFAULT"; fi
    case "$max_age" in
      ''|*[!0-9]*) hq_die_validation "impact: --max-age must be a whole number of minutes, 0 to 10080" ;;
    esac
    if [ "${#max_age}" -gt 5 ] || [ "$((10#$max_age))" -gt 10080 ]; then
      hq_die_validation "impact: --max-age must be a whole number of minutes, 0 to 10080"
    fi
    max_age=$((10#$max_age))
  else
    if [ "$have_max" -eq 1 ]; then hq_die_validation "impact: --max-age is for --open"; fi
    if [ "$n" -lt 2 ]; then hq_die_validation "impact: needs OWNER/REPO and ISSUE, or --open (run human-queue.sh impact --help)"; fi
    if ! [[ $repo =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || [ "${#repo}" -gt 200 ]; then
      hq_die_validation "impact: OWNER/REPO must be a GitHub repo, for example auerbachb/claude-code-config"
    fi
    issue="${issue#\#}"
    if ! [[ $issue =~ ^[1-9][0-9]{0,9}$ ]]; then
      hq_die_validation "impact: ISSUE must be an issue number, for example 42 or #42"
    fi
  fi

  hq_jq_find || hq_die_error "impact: jq not found (PATH, /opt/homebrew/bin/jq, or /usr/bin/jq); nothing was derived"
  if [ "$store" -eq 1 ]; then
    hq_db_connect
  fi
  hq__impact_thresholds

  if [ "$open" -eq 1 ]; then
    hq__impact_open "$json" "$max_age"
  else
    hq__impact_one "$repo" "$issue" "$json" "$store"
  fi
}
