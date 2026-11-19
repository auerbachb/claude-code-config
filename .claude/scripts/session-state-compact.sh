#!/usr/bin/env bash
# session-state-compact.sh — offline, locked compaction of ~/.claude/session-state.json.
# catalog: session-state-locking — Archive old per-PR, per-agent and terminal background-task entries so the state file stays small (issue #2433)
#
# PURPOSE
#   Long multi-agent sessions grew session-state.json to megabytes; every
#   locked writer rewrites the whole file, so a big file stretches lock hold
#   times until launch hooks time out (issue #2433). This script moves entries
#   that are provably old OUT of the state file into a permission-restricted
#   local archive, in one pass under the shared state lock. It is local-only
#   (no network) and never deletes without archiving first.
#
#   Policy, protections and manual restore:
#   .claude/reference/state-file-contracts.md §Compaction.
#
# MODES
#   --check (default)  Read-only, unlocked. Prints size, bytes per category and
#                      what --apply would archive. --json for machine output.
#   --apply            Archive eligible entries and remove them from the state
#                      file under the lock. Nothing eligible: no rewrite, the
#                      file's bytes and mtime are untouched.
#
# OPTIONS (each also settable through the environment variable shown)
#   --pr-age-days N        CLAUDE_STATE_COMPACT_PR_AGE_DAYS      (default 30)
#   --agent-age-days N     CLAUDE_STATE_COMPACT_AGENT_AGE_DAYS   (default 7)
#   --task-age-days N      CLAUDE_STATE_COMPACT_TASK_AGE_DAYS    (default 3)
#                          terminal background_tasks entries
#   --history N            CLAUDE_STATE_COMPACT_HISTORY          (default 100)
#                          newest items kept in polling_failures / polling_backoffs
#   --size-cap BYTES       CLAUDE_STATE_COMPACT_SIZE_CAP         (default 2097152)
#   --keep-archives N      CLAUDE_STATE_COMPACT_ARCHIVE_KEEP     (default 30)
#   --lock-timeout S       CLAUDE_STATE_LOCK_TIMEOUT             (default 30)
#   --if-due SECONDS       --apply only: exit 0 doing nothing when the last
#                          successful run (the stamp file) is younger than this.
#   --trigger NAME         Label recorded in the archive (manual|post-write|session-start).
#   --state-file PATH      CLAUDE_SESSION_STATE_FILE (default ~/.claude/session-state.json)
#   --json                 Machine-readable output.
#   --help | -h
#
# FILES (next to the state file)
#   <state>.compact.stamp  touched after every successful --apply (no-op included)
#   <state>.compact.run/   mkdir guard: one compactor at a time
#   session-state-archive/ archive dir, mode 0700; one 0600 JSON file per run
#                          (CLAUDE_STATE_COMPACT_ARCHIVE_DIR overrides)
#
# EXIT STATUS
#   0  success (including nothing to do, or another run already in progress)
#   2  usage error
#   3  state file missing
#   4  state file invalid (not one JSON object) or candidate failed validation
#   5  archive or state write failed
#   6  could not acquire the state lock (state unchanged; retry later)
#
# RECURSION
#   Writes through state-lock.sh directly, never through session-state.sh, so
#   it cannot re-trigger the post-write size check. It exports
#   CLAUDE_STATE_COMPACT_RUNNING=1 for anything it spawns.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCHEMA_FILE="${SCRIPT_DIR}/../reference/session-state-schema.json"
export CLAUDE_STATE_COMPACT_RUNNING=1

die_usage() { echo "session-state-compact.sh: $1" >&2; exit 2; }

MODE=check
AS_JSON=0
IF_DUE=""
TRIGGER=manual
STATE_FILE="${CLAUDE_SESSION_STATE_FILE:-${HOME:-}/.claude/session-state.json}"
PR_AGE_DAYS="${CLAUDE_STATE_COMPACT_PR_AGE_DAYS:-30}"
AGENT_AGE_DAYS="${CLAUDE_STATE_COMPACT_AGENT_AGE_DAYS:-7}"
TASK_AGE_DAYS="${CLAUDE_STATE_COMPACT_TASK_AGE_DAYS:-3}"
HISTORY="${CLAUDE_STATE_COMPACT_HISTORY:-100}"
SIZE_CAP="${CLAUDE_STATE_COMPACT_SIZE_CAP:-2097152}"
ARCHIVE_KEEP="${CLAUDE_STATE_COMPACT_ARCHIVE_KEEP:-30}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) MODE=check ;;
    --apply) MODE=apply ;;
    --json) AS_JSON=1 ;;
    --pr-age-days) PR_AGE_DAYS="${2:-}"; shift ;;
    --agent-age-days) AGENT_AGE_DAYS="${2:-}"; shift ;;
    --task-age-days) TASK_AGE_DAYS="${2:-}"; shift ;;
    --history) HISTORY="${2:-}"; shift ;;
    --size-cap) SIZE_CAP="${2:-}"; shift ;;
    --keep-archives) ARCHIVE_KEEP="${2:-}"; shift ;;
    --lock-timeout) export CLAUDE_STATE_LOCK_TIMEOUT="${2:-}"; shift ;;
    --if-due) IF_DUE="${2:-}"; shift ;;
    --trigger) TRIGGER="${2:-}"; shift ;;
    --state-file) STATE_FILE="${2:-}"; shift ;;
    -h|--help) sed -n '2,/^set -uo pipefail$/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *) die_usage "unknown argument: $1" ;;
  esac
  shift
done

for _pair in "pr-age-days:$PR_AGE_DAYS" "agent-age-days:$AGENT_AGE_DAYS" \
             "task-age-days:$TASK_AGE_DAYS" "history:$HISTORY" "size-cap:$SIZE_CAP" \
             "keep-archives:$ARCHIVE_KEEP"; do
  [[ "${_pair#*:}" =~ ^[0-9]+$ ]] || die_usage "--${_pair%%:*} must be a non-negative integer"
done
[[ -z "$IF_DUE" || "$IF_DUE" =~ ^[0-9]+$ ]] || die_usage "--if-due must be a non-negative integer"
[[ -z "${CLAUDE_STATE_LOCK_TIMEOUT:-}" || "$CLAUDE_STATE_LOCK_TIMEOUT" =~ ^[0-9]+$ ]] \
  || die_usage "--lock-timeout must be a non-negative integer"
[[ "$STATE_FILE" == /* ]] || die_usage "state file path must be absolute (HOME unset?)"
command -v jq >/dev/null 2>&1 || { echo "session-state-compact.sh: jq is required" >&2; exit 4; }

# shellcheck source=state-lock.sh
source "$SCRIPT_DIR/state-lock.sh" || { echo "session-state-compact.sh: cannot load state-lock.sh" >&2; exit 5; }

STATE_DIR="${STATE_FILE%/*}"
STAMP="$STATE_FILE.compact.stamp"
GUARD="$STATE_FILE.compact.run"
ARCHIVE_DIR="${CLAUDE_STATE_COMPACT_ARCHIVE_DIR:-$STATE_DIR/session-state-archive}"

# Validated digit strings are forced to base 10 (`08` is not octal here).
PR_AGE_DAYS=$(( 10#$PR_AGE_DAYS )); AGENT_AGE_DAYS=$(( 10#$AGENT_AGE_DAYS ))
TASK_AGE_DAYS=$(( 10#$TASK_AGE_DAYS )); HISTORY=$(( 10#$HISTORY ))
SIZE_CAP=$(( 10#$SIZE_CAP )); ARCHIVE_KEEP=$(( 10#$ARCHIVE_KEEP ))
[[ -z "$IF_DUE" ]] || IF_DUE=$(( 10#$IF_DUE ))

NOW_EPOCH="$(date -u +%s)"
[[ "$NOW_EPOCH" =~ ^[0-9]+$ ]] || { echo "session-state-compact.sh: cannot read the clock" >&2; exit 4; }
# Cutoffs are unix seconds; timestamps are parsed (offsets applied) in jq.
CUT_PR=$(( NOW_EPOCH - PR_AGE_DAYS * 86400 ))
CUT_AGENT=$(( NOW_EPOCH - AGENT_AGE_DAYS * 86400 ))
CUT_TASK=$(( NOW_EPOCH - TASK_AGE_DAYS * 86400 ))

# Size decisions use the bytes of the representation that is committed (jq's
# default pretty print), whatever the on-disk formatting is today.
file_bytes() { jq . "$1" 2>/dev/null | wc -c | tr -d ' '; }

# ---------------------------------------------------------------------------
# The plan: ONE jq program computes the candidate document and every removed
# item (with its JSON path) from local evidence only.
#   Categories touched (everything else is retained by construction):
#     .repos[R].prs[N]               newest valid ISO timestamp in the entry < CUT_PR,
#                                    unless babysit.active, wrap_sweep.needs_decision,
#                                    or a kept agent's .pr names it
#     .repos[R].background_tasks[i]  terminal status and updated_at/started_at < CUT_TASK
#                                    (stopped/failed: < CUT_PR — /end-resume recovers them)
#     .active_agents[ID]             last_seen_at/launched < CUT_AGENT, unless its
#                                    .pr names a PR entry the age pass retained
#     .polling_failures / .polling_backoffs   keep the newest $hist items
#     .repos[R]                      only once nothing but empty prs/background_tasks remain
#   Then, while the estimated size is over the cap, further eligible-category
#   items (unprotected PRs, terminal tasks — never agents) oldest first.
#   An item without a parseable timestamp is never eligible.
# ---------------------------------------------------------------------------
# shellcheck disable=SC2016
PLAN_JQ='
def compact_plan: .;
# A timestamp is an ISO-8601 string with a VALID date/time and an optional
# Z / +-HH:MM / +-HHMM offset; it becomes unix seconds (offset applied).
# Anything else is null — never eligible, never compared.
def ts_of:
  if type != "string" then null
  else (capture("^(?<y>[0-9]{4})-(?<mo>[0-9]{2})-(?<d>[0-9]{2})T(?<h>[0-9]{2}):(?<mi>[0-9]{2}):(?<s>[0-9]{2})(\\.[0-9]+)?(?<z>Z|[+-][0-9]{2}:?[0-9]{2})?$") // null)
    | if . == null then null
      elif ((.mo | tonumber) < 1 or (.mo | tonumber) > 12 or (.d | tonumber) < 1 or (.d | tonumber) > 31
            or (.h | tonumber) > 23 or (.mi | tonumber) > 59 or (.s | tonumber) > 60) then null
      else . as $c
        | (("\($c.y)-\($c.mo)-\($c.d)T\($c.h):\($c.mi):\($c.s)Z") | try fromdateiso8601 catch null) as $base
        | if $base == null then null
          elif ($c.z == null or $c.z == "Z") then $base
          else ($c.z | sub(":"; "")) as $z
            | (if $z[0:1] == "-" then -1 else 1 end) as $sign
            | ($z[1:3] | tonumber) as $oh | ($z[3:5] | tonumber) as $om
            # An out-of-range offset (+99:99) makes the timestamp invalid.
            | if $oh > 23 or $om > 59 then null
              else $base - $sign * ($oh * 3600 + $om * 60) end
          end
      end
  end;
def newest_ts: [.. | strings | select(test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T")) | ts_of | select(. != null)] | max;
def nonempty: . != null and . != false and . != [] and . != {} and . != "";
def pr_protected:
  ((.babysit | if type == "object" then .active else null end) == true)
  or ((.wrap_sweep | if type == "object" then .needs_decision else null end) | nonempty);
# Scalar membership only: an array status must not match as a subsequence.
def terminal: type == "string" and (. as $s | ["done","failed","stopped","abandoned","rearmed"] | any(. == $s));
# /end-resume lists `stopped` and `failed` entries as recoverable work, and an
# /end can last days: those keep the PR age window ($cut_pr), not the task one.
def recoverable: type == "string" and (. == "stopped" or . == "failed");
def objents: if type == "object" then to_entries[] else empty end;
def arrents: if type == "array" then to_entries[] else empty end;
# Encoded UTF-8 bytes, never characters: a character count under-weights
# multibyte text and skews every size decision (issue #2433 review).
def sz: tojson | utf8bytelength;

. as $doc
| ($doc | sz) as $compact_len
| (if $compact_len > 0 then ($file_bytes / $compact_len) else 1 end) as $ratio
# PR keys referenced by an agent the age rule keeps: such a PR is evidence the
# session view uses to attribute that agent, so it is never archived.
| [ $doc.active_agents | objents | .value | select(type == "object")
    | select(((.last_seen_at // .launched) | ts_of) as $t | $t == null or $t >= $cut_agent)
    | .pr | select(. != null) | tostring ] as $live_agent_prs
| [ $doc.repos | objents | .key as $rk | .value | if type == "object" then . else {} end
    | .prs | objents | select(.value | type == "object")
    | (.value | newest_ts) as $t
    | .key as $pk
    | {cat:"pr", path:["repos",$rk,"prs",.key], container:"object", ts:$t,
       protected:((.value | pr_protected) or ($live_agent_prs | any(. == $pk))),
       pr:.key, bytes:(.value | sz), value:.value} ] as $prs
| [ $doc.repos | objents | .key as $rk | .value | if type == "object" then . else {} end
    | .background_tasks | arrents | select(.value | type == "object")
    | ((.value.updated_at // .value.started_at) | ts_of) as $t
    | {cat:"background_task", path:["repos",$rk,"background_tasks",.key], container:"array", ts:$t,
       protected:(((.value.status | terminal) | not)
                  or ((.value.status | recoverable) and ($t == null or $t >= $cut_pr))),
       bytes:(.value | sz), value:.value} ] as $tasks
| ($prs | map(select((.protected | not) and .ts != null and .ts < $cut_pr))) as $age_prs
| ([$age_prs[].path | tostring]) as $age_pr_paths
| ([$prs[] | select((.path | tostring) as $p | $age_pr_paths | index($p) | not) | .pr]) as $kept_prs
| [ $doc.active_agents | objents | select(.value | type == "object")
    | ((.value.last_seen_at // .value.launched) | ts_of) as $t
    | (.value.pr | if . == null then null else tostring end) as $apr
    | {cat:"agent", path:["active_agents",.key], container:"object", ts:$t,
       protected:($apr != null and ($kept_prs | index($apr)) != null),
       bytes:(.value | sz), value:.value} ] as $agents
| [ ("polling_failures","polling_backoffs") as $h
    | ($doc[$h] | if type == "array" then . else [] end) as $arr
    | ($arr | length) as $n
    | if $n > $hist then range(0; $n - $hist) | {cat:"history", path:[$h, .], container:"array",
        ts:null, protected:false, bytes:($arr[.] | sz), value:$arr[.]} else empty end ] as $history
| ( $age_prs
    + ($tasks | map(select((.protected | not) and .ts != null and .ts < $cut_task)))
    + ($agents | map(select((.protected | not) and .ts != null and .ts < $cut_agent)))
    + $history ) as $age_removed
| ($doc | delpaths([$age_removed[].path])) as $after_age
| (($after_age | sz) * $ratio) as $est_after_age
| ([$age_removed[].path | tostring]) as $removed_keys
# PRs named by EVERY agent the age pass kept (old agents kept for their PR
# included): the size pass must not archive a PR a retained agent points at.
| [ $agents[] | select((.path | tostring) as $p | $removed_keys | index($p) | not)
    | .value.pr | select(. != null) | tostring ] as $retained_agent_prs
# The size pass never takes an agent: every agent the age pass kept is within
# its age window (or protected), i.e. possibly live, and agents are tiny.
| ( if $est_after_age > $target_cap then
      ( (($prs | map(select(.pr as $k | $retained_agent_prs | index($k) | not))) + $tasks)
        | map(select((.protected | not) and .ts != null
                     and ((.path | tostring) as $p | $removed_keys | index($p) | not)))
        | sort_by(.ts) ) as $pool
      | ($est_after_age - $target_cap) as $excess
      | reduce $pool[] as $c ({acc:0, items:[]};
          if .acc < $excess then .acc += ($c.bytes * $ratio) | .items += [$c] else . end)
      | .items
    else [] end ) as $size_removed
| ($age_removed + $size_removed) as $removed0
| ($doc | delpaths([$removed0[].path])) as $cand0
| [ $cand0.repos | objents
    | select(.value | type == "object")
    | select(.value | to_entries | all(
        (.key == "prs" and .value == {}) or (.key == "background_tasks" and .value == [])))
    | .key as $rk
    | select(any($removed0[]; .path[0] == "repos" and .path[1] == $rk))
    | {cat:"repo", path:["repos",.key], container:"object", ts:null, protected:false,
       bytes:(.value | sz), value:$doc.repos[.key]} ] as $repos
| ($removed0 + $repos) as $removed
| {
    doc: ($cand0 | delpaths([$repos[].path])),
    removed: [$removed[] | {cat, path, container, ts, value}],
    summary: {
      size_bytes: $file_bytes,
      size_cap: $size_cap,
      estimated_after_bytes: (($cand0 | delpaths([$repos[].path]) | sz) * $ratio | floor),
      categories: ([$doc | objents | {key, value:((.value | sz) * $ratio | floor)}] | from_entries),
      repo_categories: ([$doc.repos | objents | .value | objents | {k:.key, b:(.value | sz)}]
                        | group_by(.k) | map({key:.[0].k, value:((map(.b) | add) * $ratio | floor)})
                        | from_entries),
      eligible: ($removed | group_by(.cat)
                 | map({key:.[0].cat, value:{count:length, bytes:((map(.value | sz) | add) * $ratio | floor)}})
                 | from_entries),
      size_pass_items: ($size_removed | length),
      retained_protected: {
        prs: ([$prs[] | select(.protected)] | length),
        live_background_tasks: ([$tasks[] | select(.protected)] | length),
        referenced_agents: ([$agents[] | select(.protected)] | length),
        undated: (([$prs[], $tasks[], $agents[]] | map(select(.ts == null)) | length))
      }
    }
  }
| compact_plan
'

run_plan() { # run_plan <input-file> <file-bytes> [target-cap]
  jq -c --argjson cut_pr "$CUT_PR" --argjson cut_agent "$CUT_AGENT" --argjson cut_task "$CUT_TASK" \
     --argjson hist "$HISTORY" --argjson size_cap "$SIZE_CAP" --argjson target_cap "${3:-$SIZE_CAP}" \
     --argjson file_bytes "$2" "$PLAN_JQ" "$1"
}

# The size pass works from an estimate (compact UTF-8 bytes scaled by the
# file's pretty-print overhead, which varies with nesting depth). Verify the
# real committed size — the candidate's pretty-printed bytes — and, while it
# is still over the cap and the size pass took items, re-plan against a cap
# lowered by the measured overshoot. Bounded; the plan is deterministic.
plan_to_cap() { # plan_to_cap <input-file> <out-file>
  local bytes target="$SIZE_CAP" actual _i
  bytes="$(file_bytes "$1")"
  run_plan "$1" "$bytes" > "$2" || return 1
  for _i in 1 2 3 4 5; do
    [[ "$(jq '.summary.size_pass_items' "$2")" -gt 0 ]] || return 0
    actual="$(jq '.doc' "$2" | wc -c | tr -d ' ')"
    [[ "$actual" =~ ^[0-9]+$ ]] || return 1
    (( actual > SIZE_CAP )) || return 0
    target=$(( target - (actual - SIZE_CAP) ))
    (( target > 0 )) || target=0
    run_plan "$1" "$bytes" "$target" > "$2" || return 1
  done
  return 0
}

print_summary() { # print_summary <plan-json-file> <verb>
  if [[ "$AS_JSON" == 1 ]]; then
    jq -c --arg mode "$MODE" --arg verb "$2" \
      '.summary + {mode:$mode, result:$verb, removed_paths:[.removed[].path]}' "$1"
    return
  fi
  jq -r --arg verb "$2" '
    .summary as $s
    | "session-state-compact: \($verb)",
      "  size: \($s.size_bytes) bytes (cap \($s.size_cap)); estimated after: \($s.estimated_after_bytes)",
      "  top-level bytes: " + ([$s.categories | to_entries | sort_by(-.value)[] | "\(.key)=\(.value)"] | join(" ")),
      "  per-repo category bytes: " + ([$s.repo_categories | to_entries | sort_by(-.value)[] | "\(.key)=\(.value)"] | join(" ")),
      "  eligible: " + (if ($s.eligible | length) == 0 then "nothing"
                        else [$s.eligible | to_entries[] | "\(.key) \(.value.count) (\(.value.bytes) bytes)"] | join(", ") end),
      "  retained (protected): \($s.retained_protected | to_entries | map("\(.key)=\(.value)") | join(" "))",
      (if $s.estimated_after_bytes > $s.size_cap
       then "  WARNING: still over the size cap after compaction; the remainder is protected or undated"
       else empty end)
  ' "$1"
}

[[ -f "$STATE_FILE" ]] || { echo "session-state-compact.sh: state file not found: $STATE_FILE" >&2; exit 3; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/ss-compact.XXXXXX")" || exit 5
cleanup() { rm -f "$WORK"/* 2>/dev/null; rmdir "$WORK" 2>/dev/null; }
trap cleanup EXIT

is_one_object() { [[ "$(jq -s 'length == 1 and (.[0] | type) == "object"' "$1" 2>/dev/null)" == true ]]; }

if [[ "$MODE" == check ]]; then
  is_one_object "$STATE_FILE" \
    || { echo "session-state-compact.sh: $STATE_FILE must contain exactly one top-level JSON object" >&2; exit 4; }
  plan_to_cap "$STATE_FILE" "$WORK/plan.json" \
    || { echo "session-state-compact.sh: plan failed" >&2; exit 4; }
  print_summary "$WORK/plan.json" "check (no changes made)"
  exit 0
fi

# ---------------------------------------------------------------------------
# --apply
# ---------------------------------------------------------------------------
stamp_age() { local m; m="$(_state_lock_file_mtime "$STAMP")" || return 1; printf '%s' $(( NOW_EPOCH - m )); }
if [[ -n "$IF_DUE" ]] && age="$(stamp_age)" && (( age < IF_DUE )); then
  [[ "$AS_JSON" == 1 ]] && printf '{"result":"not-due","stamp_age_seconds":%s}\n' "$age"
  exit 0
fi

# One compactor at a time (`<state>.compact.run/`, owner pid inside).
#   live owner pid                      -> another run is in progress: exit 0
#   no pid yet and guard < 10 min old   -> owner is still publishing: exit 0
#   dead owner pid, or ownerless >= 10 min -> abandoned: reclaim it
#   guard cannot be created at all      -> write error: exit 5
already_running() {
  [[ "$AS_JSON" == 1 ]] && printf '{"result":"already-running"}\n'
  exit 0
}
take_guard() {
  mkdir "$GUARD" 2>/dev/null && return 0
  [[ -d "$GUARD" ]] || { echo "session-state-compact.sh: cannot create guard $GUARD" >&2; exit 5; }
  return 1
}
if ! take_guard; then
  gpid="$(cat "$GUARD/pid" 2>/dev/null || true)"
  gage=0
  if gm="$(_state_lock_file_mtime "$GUARD")"; then gage=$(( NOW_EPOCH - gm )); fi
  if [[ "$gpid" =~ ^[0-9]+$ ]] && kill -0 "$gpid" 2>/dev/null; then already_running; fi
  if [[ -z "$gpid" ]] && (( gage < 600 )); then already_running; fi
  rm -f "$GUARD/pid" 2>/dev/null; rmdir "$GUARD" 2>/dev/null
  take_guard || already_running
fi
printf '%s\n' "$$" > "$GUARD/pid" 2>/dev/null
# Remove the guard only while it is still ours: a reclaimed guard belongs to
# whichever run reclaimed it.
release_guard() {
  [[ "$(cat "$GUARD/pid" 2>/dev/null)" == "$$" ]] || return 0
  rm -f "$GUARD/pid" 2>/dev/null; rmdir "$GUARD" 2>/dev/null
}
trap 'state_lock_release; release_guard; cleanup' EXIT

state_lock_acquire "$STATE_FILE" || exit "$STATE_LOCK_EXIT_TIMEOUT"

if ! is_one_object "$STATE_FILE"; then
  echo "session-state-compact.sh: $STATE_FILE must contain exactly one top-level JSON object" >&2
  exit 4
fi

plan_to_cap "$STATE_FILE" "$WORK/plan.json" \
  || { echo "session-state-compact.sh: plan failed" >&2; exit 4; }

REMOVED="$(jq '.removed | length' "$WORK/plan.json")"
if [[ "$REMOVED" == 0 ]]; then
  state_lock_release
  : > "$STAMP" 2>/dev/null || true
  print_summary "$WORK/plan.json" "nothing eligible (state file not rewritten)"
  exit 0
fi

CAND="$STATE_FILE.compact.tmp.$$"
# Owner-only, whatever the caller's umask: the candidate replaces the state file.
if ! (umask 077 && jq '.doc' "$WORK/plan.json" > "$CAND") 2>/dev/null; then
  rm -f "$CAND"; echo "session-state-compact.sh: could not build candidate" >&2; exit 5
fi

# Validate: one object; everything outside the touched categories unchanged;
# every surviving repo unchanged apart from prs/background_tasks; the
# field-type contract still holds.
FIELD_TYPES='{}'
[[ -f "$SCHEMA_FILE" ]] && FIELD_TYPES="$(jq -c '._field_types.top_level // {}' "$SCHEMA_FILE" 2>/dev/null || echo '{}')"
if ! jq -n -e --slurpfile o "$STATE_FILE" --slurpfile c "$CAND" --argjson ft "$FIELD_TYPES" '
    ($o | length) == 1 and ($c | length) == 1 and ($c[0] | type) == "object"
    and ($o[0] | del(.repos, .active_agents, .polling_failures, .polling_backoffs))
        == ($c[0] | del(.repos, .active_agents, .polling_failures, .polling_backoffs))
    and all(($c[0].repos // {}) | to_entries[];
            . as $e | ($e.value | if type == "object" then del(.prs, .background_tasks) else . end)
                      == ($o[0].repos[$e.key] | if type == "object" then del(.prs, .background_tasks) else . end))
    and all($ft | to_entries[]; . as $f | ($c[0] | has($f.key) | not)
            or ($c[0][$f.key] == null) or (($c[0][$f.key] | type) == $f.value)
            or (($o[0][$f.key] | type) == ($c[0][$f.key] | type)))
  ' >/dev/null 2>&1; then
  rm -f "$CAND"
  echo "session-state-compact.sh: candidate failed validation; state left unchanged, nothing archived" >&2
  exit 4
fi

# Archive only after the candidate validated, and still BEFORE the commit, so
# a failed validation leaves no archive behind.
# Microseconds after the seconds keep same-second runs in creation order, so
# retention's name sort is age order (pid order is not).
# Seconds and microseconds come from ONE clock read, so a second boundary
# between two reads cannot misorder the stamp.
# CLAUDE_STATE_COMPACT_CLOCK_FALLBACK=1 forces the seconds-only path (tests).
_rt=""
if [[ "${CLAUDE_STATE_COMPACT_CLOCK_FALLBACK:-0}" == 1 ]]; then
  :
elif [[ -n "${EPOCHREALTIME:-}" ]]; then
  _rt="${EPOCHREALTIME/,/.}"
elif command -v perl >/dev/null 2>&1; then
  _rt="$(perl -MTime::HiRes=time -e 'my $t = time; printf "%d.%06d", int $t, ($t - int $t) * 1e6' 2>/dev/null)"
fi
_sec="${_rt%%.*}" _usec="${_rt#*.}"
if [[ "$_sec" =~ ^[0-9]+$ && "$_usec" =~ ^[0-9]{6}$ ]] \
   && _stamp="$(date -u -r "$_sec" +%Y%m%dT%H%M%S 2>/dev/null || date -u -d "@$_sec" +%Y%m%dT%H%M%S 2>/dev/null)" \
   && [[ -n "$_stamp" ]]; then
  :
else
  _stamp="$(date -u +%Y%m%dT%H%M%S)" _usec="000000"
fi
if ! (umask 077 && mkdir -p "$ARCHIVE_DIR") || ! chmod 700 "$ARCHIVE_DIR"; then
  rm -f "$CAND"
  echo "session-state-compact.sh: could not create archive dir $ARCHIVE_DIR" >&2
  exit 5
fi
# Prefixed by the state file's name AND a checksum of its full path, so
# retention below only ever rotates archives of THIS state file (two state
# files — even with the same basename — may share the directory).
STATE_PATH_ID="$(printf '%s' "$STATE_FILE" | cksum | awk '{print $1}')"
ARCHIVE_PREFIX="compact-${STATE_FILE##*/}-${STATE_PATH_ID}-"
# Strictly increasing stamps: runs of one state file are serialized by the run
# guard, so if the newest existing archive's stamp is not older than ours (the
# seconds-only fallback, or a coarse clock), take the next microsecond after it.
_last="$(LC_ALL=C; shopt -s nullglob; _n=""
         for _a in "$ARCHIVE_DIR/$ARCHIVE_PREFIX"*.json; do _n="${_a##*/}"; done
         _n="${_n#"$ARCHIVE_PREFIX"}"; printf '%s' "${_n%%Z-*}")"
if [[ "$_last" =~ ^([0-9]{8}T[0-9]{6})\.([0-9]{6})$ ]] && [[ ! "$_stamp.$_usec" > "$_last" ]]; then
  _stamp="${BASH_REMATCH[1]}"
  _usec=$(( 10#${BASH_REMATCH[2]} + 1 ))
  if (( _usec > 999999 )); then
    # Carry into the next second (BSD date, then GNU date). If neither can,
    # stop before archiving or committing: the state is left unchanged.
    _e="$(date -u -j -f %Y%m%dT%H%M%S "$_stamp" +%s 2>/dev/null \
          || date -u -d "${_stamp:0:4}-${_stamp:4:2}-${_stamp:6:2} ${_stamp:9:2}:${_stamp:11:2}:${_stamp:13:2}" +%s 2>/dev/null)"
    if [[ "$_e" =~ ^[0-9]+$ ]] \
       && _stamp="$(date -u -r "$(( _e + 1 ))" +%Y%m%dT%H%M%S 2>/dev/null \
                    || date -u -d "@$(( _e + 1 ))" +%Y%m%dT%H%M%S 2>/dev/null)" && [[ -n "$_stamp" ]]; then
      _usec=0
    else
      rm -f "$CAND"
      echo "session-state-compact.sh: could not order the archive id after $_last; state unchanged" >&2
      exit 5
    fi
  fi
  _usec="$(printf '%06d' "$_usec")"
fi
COMPACTION_ID="${_stamp}.${_usec}Z-$$-${RANDOM}"
ARCHIVE_FILE="$ARCHIVE_DIR/$ARCHIVE_PREFIX$COMPACTION_ID.json"
if ! (umask 077 && jq --arg id "$COMPACTION_ID" --arg at "$(date -u +%FT%TZ)" \
        --arg state "$STATE_FILE" --arg trigger "$TRIGGER" \
        '{compaction_id:$id, compacted_at:$at, state_file:$state, trigger:$trigger, items:.removed}' \
        "$WORK/plan.json" > "$ARCHIVE_FILE") || ! chmod 600 "$ARCHIVE_FILE"; then
  rm -f "$ARCHIVE_FILE" "$CAND" 2>/dev/null
  echo "session-state-compact.sh: could not write archive $ARCHIVE_FILE" >&2
  exit 5
fi

commit_rc=0
state_lock_commit "$CAND" "$STATE_FILE" || commit_rc=$?
if [[ "$commit_rc" -ne 0 ]]; then
  # Nothing was committed, so the archive would only duplicate live entries;
  # drop it so repeated failed attempts cannot grow the archive without bound.
  rm -f "$ARCHIVE_FILE" 2>/dev/null
  echo "session-state-compact.sh: commit failed (rc $commit_rc); state unchanged; archive for compaction $COMPACTION_ID removed" >&2
  exit "$commit_rc"
fi
state_lock_release
: > "$STAMP" 2>/dev/null || true

# Bounded archive retention: newest ARCHIVE_KEEP files. Names embed a UTC
# timestamp (to the microsecond) right after the prefix, so a C-locale glob
# (sorted by name) is oldest first — no newline-delimited listing to parse.
if [[ "$ARCHIVE_KEEP" -gt 0 ]]; then
  # The path checksum is only 32 bits: an archive counts as this state file's
  # only when its own `state_file` field names this exact path.
  _archives=()
  while IFS= read -r -d '' _a; do
    [[ "$(jq -r '.state_file // empty' "$_a" 2>/dev/null)" == "$STATE_FILE" ]] && _archives+=("$_a")
  done < <(
    LC_ALL=C; shopt -s nullglob
    for _a in "$ARCHIVE_DIR/$ARCHIVE_PREFIX"*.json; do printf '%s\0' "$_a"; done)
  _drop=$(( ${#_archives[@]} - ARCHIVE_KEEP ))
  for (( _i = 0; _i < _drop; _i++ )); do rm -f "${_archives[_i]}"; done
fi

print_summary "$WORK/plan.json" "archived $REMOVED item(s) to $ARCHIVE_FILE"
exit 0
