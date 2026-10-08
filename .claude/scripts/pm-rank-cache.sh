#!/usr/bin/env bash
# pm-rank-cache.sh — /pm's latest backlog ranking, written with a timestamp and read back while fresh.
# catalog: backlog-pm — `/pm`'s latest backlog ranking cache (`~/.claude/pm-rank/<owner>-<repo>.json`): `/pm` 1B.4c writes the order it presents, the desk's derived impact reads an issue's rank while the cache is under 24 hours old (else rank unknown)
#
# PURPOSE
#   Keeps the order /pm last presented for a repo — its ranking with the
#   operator's order already overlaid (1B.4 item 7, pm-priority.sh) — so a
#   reader outside /pm can ask "where does #N rank?" without re-ranking.
#   /pm writes it at Step 1B.4c on every ranking (cold start, re-prioritize,
#   every refill re-scan); the human queue's `impact` subcommand reads it
#   (issue #1760). A ranking older than 24 hours is reported as unknown, never
#   as a rank.
#
# FILE
#   ${PM_RANK_DIR:-$HOME/.claude/pm-rank}/<owner>-<repo>.json, the name
#   lowercased (GitHub names are case-insensitive):
#     {"version": 1, "repo": "<owner>/<repo>", "generated_at": "<ISO 8601 UTC>",
#      "ranking": [{"rank": 1, "number": 42, "tier": "Critical"}, ...]}
#   `rank` is the 1-based position in the order given; `tier` is Critical,
#   High, Medium, Low, or null. The stored `repo` is checked on read, so two
#   repos whose names collide once `/` becomes `-` never read each other's
#   ranking. Local runtime state, never committed.
#
# USAGE
#   pm-rank-cache.sh write <owner/repo>  < order
#   pm-rank-cache.sh read <owner/repo> [ISSUE ...] [--ttl-seconds N]
#   pm-rank-cache.sh path <owner/repo>
#   pm-rank-cache.sh --help | -h
#
# VERBS
#   write  stdin: the order, best first, one issue per line as `N` or
#          `N TIER` (a leading `#` is fine; blank lines are skipped; a repeat
#          keeps its first place). Replaces the file through a temp file in
#          the same directory and a rename, so a reader never sees half a
#          file. Input that does not parse leaves the existing file as it
#          was. An empty order is a valid ranking: nothing ranked. Prints the
#          file path.
#   read   prints one JSON object:
#            {"repo", "file", "status": "fresh"|"unknown", "reason",
#             "generated_at", "age_seconds", "ranked", "issues":
#             [{"issue", "rank", "tier"}]}
#          fresh: the file parses, names this repo, and was written between
#          0 and 24 hours ago (strictly under --ttl-seconds, default 86400).
#          Otherwise unknown, with `reason` one of missing, unreadable,
#          malformed, repo-mismatch, no-timestamp, future, stale, no-home;
#          rank and tier are then null for every issue. A fresh ranking that
#          does not hold an issue gives that issue rank null too ("not
#          ranked", which is not the same as unknown).
#   path   prints the file path.
#
# EXIT STATUS
#   0  written, read (fresh or unknown alike), or path printed
#   2  usage error: unknown verb or flag, bad repo, bad issue number, bad
#      --ttl-seconds, or a write whose stdin does not parse
#   5  write failure (no HOME and no PM_RANK_DIR, directory, temp file, or rename)
#
# ENVIRONMENT
#   PM_RANK_DIR  the directory holding the files (tests); default
#                $HOME/.claude/pm-rank
#
# EXAMPLES
#   printf '%s\n' '42 Critical' '38 High' | pm-rank-cache.sh write auerbachb/claude-code-config
#   pm-rank-cache.sh read auerbachb/claude-code-config 42 | jq '.issues[0].rank'
#
# DEPENDENCIES
#   jq 1.6+, date, mv.

set -uo pipefail
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" 2>/dev/null >> "${HOME:-/tmp}/.claude/script-usage.log" || true

ME="pm-rank-cache.sh"
TTL_DEFAULT=86400

print_help() {
  sed -n '/^# PURPOSE$/,/^$/{/^$/d;p;}' "$0" | sed 's/^# \{0,1\}//'
}

die() { local code="$1"; shift; printf '%s: %s\n' "$ME" "$*" >&2; exit "$code"; }
usage_err() { die 2 "$* (run with --help)"; }

# rank_dir — the directory, or nothing when neither PM_RANK_DIR nor HOME is set.
rank_dir() {
  if [[ -n "${PM_RANK_DIR:-}" ]]; then
    printf '%s' "${PM_RANK_DIR%/}"
  elif [[ -n "${HOME:-}" ]]; then
    printf '%s/.claude/pm-rank' "${HOME%/}"
  fi
}

# repo_key REPO — lowercased owner/repo; usage error unless it is one.
repo_key() {
  [[ "$1" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || usage_err "expected <owner/repo>, got '$1'"
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

command -v jq >/dev/null 2>&1 || die 1 "jq not found"

case "${1:-}" in
  -h|--help) print_help; exit 0 ;;
  '') usage_err "missing verb (write, read, or path)" ;;
esac
verb="$1"
shift

repo=""
ttl="$TTL_DEFAULT"
issues=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) print_help; exit 0 ;;
    --ttl-seconds)
      [[ "$verb" == "read" ]] || usage_err "--ttl-seconds is for read"
      [[ $# -ge 2 && "$2" =~ ^[1-9][0-9]{0,9}$ ]] || usage_err "--ttl-seconds needs a whole number of seconds"
      ttl="$2"
      shift 2
      ;;
    -*) usage_err "unknown flag $1" ;;
    *)
      if [[ -z "$repo" ]]; then
        repo=$(repo_key "$1") || exit 2
      else
        [[ "$verb" == "read" ]] || usage_err "$verb takes one <owner/repo>"
        n="${1#\#}"
        [[ "$n" =~ ^[1-9][0-9]{0,9}$ ]] || usage_err "not an issue number: '$1'"
        issues+=("$n")
      fi
      shift
      ;;
  esac
done
[[ -n "$repo" ]] || usage_err "$verb needs <owner/repo>"

DIR=$(rank_dir)
FILE=""
if [[ -n "$DIR" ]]; then
  FILE="$DIR/${repo%%/*}-${repo#*/}.json"
fi

case "$verb" in
  path)
    [[ -n "$FILE" ]] || die 5 "neither PM_RANK_DIR nor HOME is set — no cache location"
    printf '%s\n' "$FILE"
    ;;

  write)
    [[ -n "$FILE" ]] || die 5 "neither PM_RANK_DIR nor HOME is set — the ranking was not written"
    # Parse stdin first: a bad line leaves the existing file untouched.
    RANKING=$(jq -R -s -c '
      [ split("\n")[] | sub("^\\s+"; "") | sub("\\s+$"; "") | select(. != "") ] as $lines
      | if any($lines[]; test("^#?[1-9][0-9]{0,9}(\\s+(?i:critical|high|medium|low))?$") | not)
        then error("bad line")
        else [ $lines[]
               | capture("^#?(?<n>[0-9]+)(\\s+(?<t>\\S+))?$")
               | {number: (.n | tonumber),
                  tier: (if .t == null then null else (.t | ascii_downcase | .[0:1] | ascii_upcase) + (.t | ascii_downcase | .[1:]) end)} ]
             | reduce .[] as $r ([]; if any(.[]; .number == $r.number) then . else . + [$r] end)
             | to_entries | map({rank: (.key + 1), number: .value.number, tier: .value.tier})
        end' 2>/dev/null) \
      || usage_err "write: every stdin line must be an issue number, optionally followed by Critical, High, Medium, or Low"
    mkdir -p "$DIR" 2>/dev/null || die 5 "cannot create $DIR"
    TMP=$(mktemp "$DIR/.pm-rank.XXXXXX" 2>/dev/null) || die 5 "cannot create a temp file in $DIR"
    trap 'rm -f "$TMP"' EXIT
    NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    jq -n -c --arg repo "$repo" --arg at "$NOW" --argjson ranking "$RANKING" \
      '{version: 1, repo: $repo, generated_at: $at, ranking: $ranking}' > "$TMP" \
      || die 5 "cannot write the temp file"
    chmod 600 "$TMP" 2>/dev/null || true
    mv -f "$TMP" "$FILE" || die 5 "cannot replace $FILE"
    trap - EXIT
    printf '%s\n' "$FILE"
    ;;

  read)
    ISSUES_JSON=$(printf '%s\n' ${issues[@]+"${issues[@]}"} | jq -s -c 'map(select(. != null))')
    reason=""
    CONTENT="null"
    if [[ -z "$FILE" ]]; then
      reason="no-home"
    elif [[ ! -e "$FILE" ]]; then
      reason="missing"
    elif [[ ! -r "$FILE" || ! -f "$FILE" ]]; then
      reason="unreadable"
    else
      CONTENT=$(jq -c 'if type == "object" and (.ranking | type) == "array" then . else error("shape") end' "$FILE" 2>/dev/null) \
        || { CONTENT="null"; reason="malformed"; }
    fi
    jq -n -c --arg repo "$repo" --arg file "$FILE" --arg reason "$reason" \
      --argjson ttl "$ttl" --argjson want "$ISSUES_JSON" --argjson c "$CONTENT" '
      ($c // {}) as $c
      | (if $reason != "" then $reason
         elif (($c.repo // "") | ascii_downcase) != $repo then "repo-mismatch"
         elif ($c.generated_at | type) != "string" then "no-timestamp"
         else null end) as $r0
      | (if $r0 == null then ($c.generated_at | try (sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) catch null) else null end) as $t
      | (if $r0 != null then $r0 elif $t == null then "no-timestamp" else null end) as $r1
      | (if $r1 == null then (now | floor) - $t else null end) as $age
      | (if $r1 != null then $r1 elif $age < 0 then "future" elif $age >= $ttl then "stale" else null end) as $reason
      | ($reason == null) as $fresh
      | ([ ($c.ranking // [])[] | select(type == "object" and (.number | type) == "number") ]) as $rows
      | { repo: $repo,
          file: (if $file == "" then null else $file end),
          status: (if $fresh then "fresh" else "unknown" end),
          reason: $reason,
          generated_at: (if $c.generated_at | type == "string" then $c.generated_at else null end),
          age_seconds: $age,
          ranked: (if $fresh then ($rows | length) else null end),
          issues: [ $want[] as $n
                    | ([ $rows[] | select(.number == $n) ][0]) as $hit
                    | { issue: $n,
                        rank: (if $fresh and $hit != null then $hit.rank else null end),
                        tier: (if $fresh and $hit != null then $hit.tier else null end) } ] }'
    ;;

  *) usage_err "unknown verb '$verb'" ;;
esac
