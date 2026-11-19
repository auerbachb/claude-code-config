#!/usr/bin/env bash
# ownerless-state-retire.sh — Retire finished legacy ownerless .active_agents / .pipelines records (issue #2448).
# catalog: session-state-locking — Repo-scoped, dry-run-first retirement of old ownerless subagent and pipeline records that can be shown finished (named PR merged or closed, or older than a stated age with no live runtime id); locked compare-and-set writes, nothing deleted
#
# PURPOSE
#   safe-close-inventory.sh counts every non-terminal .active_agents or
#   .pipelines record that names no owner (no session id, no claim holder) as
#   `unknown`, because it cannot prove which thread the record belongs to. Old
#   records no thread will ever finish therefore block "Safe to close" in every
#   thread. This helper is the reviewable path that retires the ones that can
#   be shown finished, so the set stops blocking without anyone treating a
#   record as nobody's on a guess.
#
#   It DELETES NOTHING. A retired record is marked terminal in place, keeping
#   every field it had, and gains:
#     status: "abandoned", outcome: "retired",
#     retired_at: <ISO time>, retired_reason: <the listed reason>
#   Both `status` and `outcome` are terminal to the safe-close inventory.
#
# USAGE
#   ownerless-state-retire.sh --repo owner/name [--apply] [--max-age-days N]
#                             [--include-unscoped] [--now ISO-8601]
#   ownerless-state-retire.sh --help | -h
#
#   --repo R            REQUIRED. The run is scoped to this repository: GitHub
#                       lookups use it, and records owned by any other repo are
#                       never modified.
#   --apply             Write. Without it the run is a dry run: it prints what
#                       it would retire and writes nothing.
#   --max-age-days N    Age rule threshold (default 14). 0 disables the age rule.
#   --include-unscoped  Also consider records that name no repo at all (the
#                       legacy top-level shape). Such a record is skipped when
#                       the PR it names is tracked under another real repo in
#                       session-state, since it may be that repo's.
#   --now T             Clock override for the age rule (tests).
#
# WHICH RECORDS
#   Top-level .active_agents and .pipelines entries that are objects, not
#   terminal (no `outcome`, and `status` not done/merged/completed/failed/
#   stopped/abandoned/closed/cancelled — the inventory's own rule), and name no
#   owner (no session_id/session, no claim_holder). Their repo is `owner_repo`:
#   equal to --repo is in scope, another repo is skipped, absent needs
#   --include-unscoped.
#
#   A record in scope is retired when either reason holds:
#     pr_finished  its `pr` (or `pr_number`) is MERGED or CLOSED on GitHub in --repo
#     aged_out     its launch/start time (launched, launched_at, started_at,
#                  spawned_at, created_at) is older than --max-age-days AND no
#                  live task in the background-task registry carries its id
#   No reason, no retirement: it is listed under skipped[] with why.
#
# FAIL-CLOSED RULES
#   - Any failed GitHub lookup ends the run with exit 4 and NOTHING written,
#     dry run or not: a record is never retired or excused on a read that did
#     not work.
#   - An unreadable background-task registry disables the age rule (noted).
#   - A record without a parsable timestamp cannot age out.
#   - Each write is one `session-state.sh --cas` guarded by `--expect-at` on the
#     whole record, under the state lock: a record that changed since the plan
#     (gained an owner, finished, moved) is left as it is and reported failed.
#     Sibling records and fields are never rewritten.
#
# OUTPUT (JSON on stdout)
#   {mode:"dry_run"|"apply", repo, max_age_days, now,
#    retire:[{path,key,reason,detail,pr,pr_state,recorded_at}],
#    skipped:[{path,key,reason}], applied:[{path,key,reason}],
#    failed:[{path,key,reason}], notes:[...]}
#
# EXIT CODES
#   0  dry run listed its plan, or every planned write was applied
#   1  apply: at least one planned write failed (others may have landed)
#   2  usage error
#   3  missing dependency (jq, gh, session-state.sh)
#   4  a GitHub lookup failed; nothing was written
#   5  session-state could not be read, or has an unexpected shape
#
# Bash 3.2 compatible (macOS); passes under bash 5.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; n = 1; next } { exit } END { exit(n ? 0 : 1) }' "$0" ||
    { printf '%s: --help header extraction produced no output\n' "$0" >&2; exit 70; }
}
die_usage() { printf 'ownerless-state-retire.sh: %s\n' "$1" >&2; exit 2; }

REPO=""
APPLY=0
MAX_AGE_DAYS=14
INCLUDE_UNSCOPED=0
NOW_OPT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --apply) APPLY=1; shift ;;
    --include-unscoped) INCLUDE_UNSCOPED=1; shift ;;
    --repo|--max-age-days|--now)
      [[ $# -ge 2 && -n "$2" ]] || die_usage "$1 requires a value"
      case "$1" in
        --repo) REPO="$2" ;;
        --max-age-days) MAX_AGE_DAYS="$2" ;;
        --now) NOW_OPT="$2" ;;
      esac
      shift 2 ;;
    *) die_usage "unknown argument: $1" ;;
  esac
done
[[ -n "$REPO" ]] || die_usage "--repo owner/name is required"
[[ "$REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || die_usage "--repo must be owner/name, got: $REPO"
REPO="$(printf '%s' "$REPO" | tr '[:upper:]' '[:lower:]')"
[[ "$MAX_AGE_DAYS" =~ ^[0-9]+$ ]] || die_usage "--max-age-days must be a whole number, got: $MAX_AGE_DAYS"

command -v jq >/dev/null 2>&1 || { echo "ownerless-state-retire.sh: jq not found" >&2; exit 3; }
command -v gh >/dev/null 2>&1 || { echo "ownerless-state-retire.sh: gh not found" >&2; exit 3; }

resolve_script() {
  local name="$1" candidate
  for candidate in \
    "$SCRIPT_DIR/$name" \
    "${HOME:+$HOME/.claude/skills-worktree/.claude/scripts/$name}" \
    "${HOME:+$HOME/.claude/scripts/$name}"; do
    if [[ -n "$candidate" && -x "$candidate" ]]; then printf '%s' "$candidate"; return 0; fi
  done
  return 1
}
SESSION_STATE_SH="$(resolve_script session-state.sh)" || { echo "ownerless-state-retire.sh: session-state.sh not found" >&2; exit 3; }
REGISTRY_SH="$(resolve_script background-task-registry.sh)" || REGISTRY_SH=""

JQ_EPOCH='def ep: if type == "string" then (try (sub("\\.[0-9]+"; "") | sub("\\+00:?00$"; "Z") | fromdateiso8601) catch null) else null end;'
if [[ -n "$NOW_OPT" ]]; then
  NOW_ISO="$NOW_OPT"
else
  NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
fi
NOW_EPOCH="$(jq -rn --arg t "$NOW_ISO" "$JQ_EPOCH"' $t | ep // empty')"
[[ -n "$NOW_EPOCH" ]] || die_usage "--now must be an ISO-8601 UTC time, got: $NOW_ISO"

NOTES='[]'
note() { NOTES="$(jq -c --arg n "$1" '. + [$n]' <<<"$NOTES")"; }

ss_get() { # <jq-path> -> JSON; exit 5 on failure
  local out
  out="$("$SESSION_STATE_SH" --repo "$REPO" --get-json "$1" 2>/dev/null)" && [[ -n "$out" ]] && jq empty >/dev/null 2>&1 <<<"$out" || {
    echo "ownerless-state-retire.sh: session-state $1 unreadable" >&2; exit 5; }
  printf '%s' "$out"
}
AGENTS="$(ss_get '.active_agents')"
PIPES="$(ss_get '.pipelines')"
REPOS="$(ss_get '.repos')"
for pair in "active_agents:$AGENTS" "pipelines:$PIPES"; do
  jq -e 'type == "object" or type == "null"' >/dev/null 2>&1 <<<"${pair#*:}" || {
    echo "ownerless-state-retire.sh: session-state .${pair%%:*} has an unexpected shape" >&2; exit 5; }
done
# PR numbers tracked by another real repo: an unscoped record naming one may be that repo's.
OTHER_PRS="$(jq -c --arg r "$REPO" '[(. // {}) | to_entries[]? | select(.key != $r and .key != "_unknown" and (.value|type) == "object")
  | (.value.prs // {}) | objects | keys[]] | unique' <<<"$REPOS" 2>/dev/null)" || {
  # Fail closed: an empty guard would let an unscoped record of another repo through.
  echo "ownerless-state-retire.sh: session-state .repos has an unexpected shape" >&2; exit 5; }

LIVE_OK=0
LIVE_IDS='[]'
if (( MAX_AGE_DAYS > 0 )); then
  if [[ -n "$REGISTRY_SH" ]] && live="$("$REGISTRY_SH" --repo "$REPO" --list --live 2>/dev/null)" && jq -e 'type == "array"' >/dev/null 2>&1 <<<"$live"; then
    LIVE_IDS="$(jq -c '[.[].task_id | tostring]' <<<"$live")"; LIVE_OK=1
  else
    note "background-task registry unreadable: the age rule is off for this run"
  fi
fi

# ---- classify every top-level record ------------------------------------------------
CANDS="$(jq -c -n --argjson a "$AGENTS" --argjson p "$PIPES" --arg r "$REPO" --argjson other "$OTHER_PRS" \
  --argjson unscoped "$INCLUDE_UNSCOPED" "$JQ_EPOCH"'
  def terminal: (.outcome != null) or ((.status // "") | tostring | test("^(done|merged|completed|failed|stopped|abandoned|closed|cancelled)$"));
  # Each owner field on its own: an empty session_id must not hide a non-empty session.
  def owned: [.session_id, .session, .claim_holder] | map(select(. != null) | tostring | select(. != "")) | length > 0;
  def rows($coll; $name): ($coll // {}) | to_entries[] | {path: $name, key: .key, rec: .value};
  [rows($a; ".active_agents"), rows($p; ".pipelines")]
  | map(. as $row | $row.rec as $x
      | if ($x | type) != "object" then empty
        elif ($x | terminal) or ($x | owned) then empty
        else
          (($x.pr // $x.pr_number // null) | if type == "number" or (type == "string" and test("^[0-9]+$")) then tostring else null end) as $pr
          | ([$x.launched, $x.launched_at, $x.started_at, $x.spawned_at, $x.created_at] | map(select(type == "string" and length > 0)) | first // null) as $ts
          | $row + {pr: $pr, recorded_at: $ts, ts_epoch: ($ts | ep),
              ids: ([$x.id, $x.agent, $row.key] | map(select(. != null) | tostring)),
              scope: (if ($x.owner_repo // null) == null then "unscoped"
                      elif (($x.owner_repo | tostring | ascii_downcase) == $r) then "scoped" else "other" end)}
          | if .scope == "other" then . + {skip: "owned by another repo (\($x.owner_repo))"}
            elif .scope == "unscoped" and $unscoped != 1 then . + {skip: "names no repo; pass --include-unscoped to consider it"}
            elif .scope == "unscoped" and $pr != null and (($other | index($pr)) != null) then . + {skip: "names PR #\($pr), which another repo tracks"}
            else . end
        end)')" || { echo "ownerless-state-retire.sh: could not classify records" >&2; exit 5; }

# ---- GitHub lookups: all or nothing ---------------------------------------------------
PR_STATES='{}'
LOOKUP_FAILED=""
while IFS= read -r n; do
  [[ -n "$n" ]] || continue
  if st="$(gh pr view "$n" --repo "$REPO" --json state --jq '.state' 2>/dev/null)" && [[ "$st" =~ ^(OPEN|MERGED|CLOSED)$ ]]; then
    PR_STATES="$(jq -c --arg n "$n" --arg s "$st" '. + {($n): $s}' <<<"$PR_STATES")"
  else
    LOOKUP_FAILED="$LOOKUP_FAILED #$n"
  fi
done < <(jq -r '[.[] | select(.skip == null and .pr != null) | .pr] | unique | .[]' <<<"$CANDS")
if [[ -n "$LOOKUP_FAILED" ]]; then
  echo "ownerless-state-retire.sh: GitHub lookup failed for PR(s)$LOOKUP_FAILED in $REPO; nothing was written" >&2
  exit 4
fi

PLAN="$(jq -c --argjson st "$PR_STATES" --argjson now "$NOW_EPOCH" --argjson days "$MAX_AGE_DAYS" \
  --argjson live "$LIVE_IDS" --argjson live_ok "$LIVE_OK" '
  map(if .skip != null then . else
        (if .pr != null then $st[.pr] else null end) as $ps
        | if $ps == "MERGED" or $ps == "CLOSED" then
            . + {pr_state: $ps, reason: "pr_finished", detail: "PR #\(.pr) is \($ps | ascii_downcase)"}
          elif $days > 0 and .ts_epoch != null and (.ts_epoch < ($now - $days * 86400)) then
            if $live_ok != 1 then . + {pr_state: $ps, skip: "older than \($days) days, but the registry could not be read to rule out a live runtime"}
            elif ([.ids[] | . as $i | ($live | index($i)) != null] | any) then . + {pr_state: $ps, skip: "older than \($days) days, but a live runtime carries its id"}
            else . + {pr_state: $ps, reason: "aged_out", detail: "recorded at \(.recorded_at), older than \($days) days, no live runtime id"} end
          else . + {pr_state: $ps, skip: (if .ts_epoch == null and .pr == null then "no timestamp and no PR: cannot be shown finished"
                                          elif .pr != null then "PR #\(.pr) is \(($ps // "unknown") | ascii_downcase) and the record is not old enough"
                                          else "recorded at \(.recorded_at), not older than \($days) days" end)}
          end
      end)' <<<"$CANDS")" || { echo "ownerless-state-retire.sh: could not build the plan" >&2; exit 5; }

RETIRE="$(jq -c '[.[] | select(.skip == null) | {path, key, reason, detail, pr, pr_state, recorded_at}]' <<<"$PLAN")"
SKIPPED="$(jq -c '[.[] | select(.skip != null) | {path, key, reason: .skip}]' <<<"$PLAN")"
APPLIED='[]'
FAILED='[]'

if (( APPLY == 1 )); then
  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    path="$(jq -r '.path' <<<"$row")"; key="$(jq -r '.key' <<<"$row")"
    reason="$(jq -r '.reason' <<<"$row")"; detail="$(jq -r '.detail' <<<"$row")"
    rec="$(jq -c '.rec' <<<"$row")"
    P="$path[$(jq -cn --arg k "$key" '$k')]"
    cur_status="$(jq -c '.status // null' <<<"$rec")"
    rc=0
    "$SESSION_STATE_SH" --repo "$REPO" \
      --cas "$P.status=\"abandoned\"" --expect "$cur_status" \
      --expect-at "$P" "$rec" \
      --set "$P.outcome=\"retired\"" \
      --set "$P.retired_at=$(jq -cn --arg t "$NOW_ISO" '$t')" \
      --set "$P.retired_reason=$(jq -cn --arg d "$reason: $detail" '$d')" >/dev/null 2>&1 || rc=$?
    entry="$(jq -cn --arg p "$path" --arg k "$key" --arg r "$reason: $detail" '{path:$p,key:$k,reason:$r}')"
    case "$rc" in
      0) APPLIED="$(jq -c --argjson e "$entry" '. + [$e]' <<<"$APPLIED")" ;;
      7) FAILED="$(jq -c --argjson e "$entry" '. + [$e + {reason: "the record changed since the plan; left as it is"}]' <<<"$FAILED")" ;;
      *) FAILED="$(jq -c --argjson e "$entry" --arg rc "$rc" '. + [$e + {reason: "session-state.sh exited \($rc); record left as it is"}]' <<<"$FAILED")" ;;
    esac
  done < <(jq -c '.[] | select(.skip == null)' <<<"$PLAN")
fi

MODE=dry_run; (( APPLY == 1 )) && MODE=apply
jq -n --arg mode "$MODE" --arg repo "$REPO" --argjson days "$MAX_AGE_DAYS" --arg now "$NOW_ISO" \
  --argjson retire "$RETIRE" --argjson skipped "$SKIPPED" --argjson applied "$APPLIED" --argjson failed "$FAILED" \
  --argjson notes "$NOTES" \
  '{mode:$mode, repo:$repo, max_age_days:$days, now:$now, retire:$retire, skipped:$skipped,
    applied:$applied, failed:$failed, notes:$notes}'
[[ "$(jq 'length' <<<"$FAILED")" == 0 ]]
