#!/usr/bin/env bash
# safe-close-inventory.sh — Read-only inventory of what one thread still owns (issue #2260).
# catalog: session-state-locking — Read-only inventory of everything a thread started or still owns, with a safe-to-close verdict; each item tagged lost / keeps_running / orphaned / harmless, unreadable categories reported unknown
#
# PURPOSE
#   Answers "is it safe to close this thread?" from recorded state. It reads
#   the background-task registry, session-state.json, the bgwork ceiling, git
#   worktrees, GitHub PRs and issue claims, handoff files and an optional
#   scratchpad, and prints one verdict plus a flat item list. It is the single
#   source for /safe-close; the later stop (#2261) and cleanup (#2262)
#   increments consume its JSON instead of re-deriving state.
#
#   STRICTLY READ-ONLY. It stops no process, deletes nothing, releases no
#   claim and writes no state. (The helper scripts it calls may append their
#   usual one-line telemetry to ~/.claude/script-usage.log; that is not state.)
#
# USAGE
#   safe-close-inventory.sh [--session ID] [--repo owner/name] [--worktree PATH]
#                           [--scratchpad DIR] [--json | --text]
#   safe-close-inventory.sh --help | -h
#
#   --session ID    The thread's session id (default: $CLAUDE_SESSION_ID).
#                   Without one, session-scoped categories are `unknown`.
#   --repo R        owner/name (default: resolved from the checkout's origin).
#   --worktree P    The thread's own checkout (default: cwd's top level).
#   --scratchpad D  The thread's scratchpad directory, when it has one.
#   --json          Machine-readable output (default).
#   --text          Short human report: verdict line, then outstanding items.
#
# EXIT CODES
#   0  safe to close (no outstanding item among the script-readable categories)
#   1  not yet (at least one non-harmless item, an unknown included)
#   2  usage error
#   3  the inventory itself could not run (missing jq or git)
#
# OUTPUT (--json, schema_version 1)
#   verdict           "safe" | "not_yet"
#   outstanding       count of items whose consequence is not "harmless"
#   needs_agent_checks true while agent_checks[] is non-empty: the verdict only
#                     covers what a shell can read; the skill merges the rest
#   categories        {<name>: {status: "ok"|"unknown", reason, items: N}}
#   items[]           {category, id, summary, consequence, detail, ref}
#                     consequence: lost | keeps_running | orphaned | harmless | unknown
#   excluded[]        other threads' / other authors' items: context only,
#                     never counted
#   agent_checks[]    {id, what, how} facts only the harness can see
#
# ATTRIBUTION
#   An item counts only when the thread's ownership of it is shown: the session
#   id on its record, the thread's own worktree or branch, or a runtime id the
#   session registered. A record naming another session or repo is excluded.
#   A non-terminal record that names no owner cannot be attributed: it is
#   reported as ONE `unknown` item per category, never claimed and never ignored.
#
# Bash 3.2 compatible (macOS); passes under bash 5.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONSEQUENCES="lost keeps_running orphaned harmless unknown"

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; n = 1; next } { exit } END { exit(n ? 0 : 1) }' "$0" ||
    { printf '%s: --help header extraction produced no output\n' "$0" >&2; exit 70; }
}
die_usage() { printf 'safe-close-inventory.sh: %s\n' "$1" >&2; exit 2; }

SESSION_ID="${CLAUDE_SESSION_ID:-}"
REPO_OPT=""
WT_OPT=""
SCRATCH=""
FORMAT=json
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --json) FORMAT=json; shift ;;
    --text) FORMAT=text; shift ;;
    --session|--repo|--worktree|--scratchpad)
      [[ $# -ge 2 ]] || die_usage "$1 requires a value"
      # An empty --session means "no session id" (the caller's variable was unset): the
      # session-scoped categories then report unknown. Every other flag needs a value.
      [[ -n "$2" || "$1" == --session ]] || die_usage "$1 requires a value"
      case "$1" in
        --session) SESSION_ID="$2" ;;
        --repo) REPO_OPT="$2" ;;
        --worktree) WT_OPT="$2" ;;
        --scratchpad) SCRATCH="$2" ;;
      esac
      shift 2 ;;
    *) die_usage "unknown argument: $1" ;;
  esac
done
if [[ -n "$REPO_OPT" ]] && ! [[ "$REPO_OPT" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
  die_usage "--repo must be owner/name, got: $REPO_OPT"
fi

command -v jq >/dev/null 2>&1 || { echo "safe-close-inventory.sh: jq not found" >&2; exit 3; }
command -v git >/dev/null 2>&1 || { echo "safe-close-inventory.sh: git not found" >&2; exit 3; }

# ---- helper resolution: sibling first, then the installed copies ----------------
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
SESSION_STATE_SH="$(resolve_script session-state.sh)" || SESSION_STATE_SH=""
REGISTRY_SH="$(resolve_script background-task-registry.sh)" || REGISTRY_SH=""
CEILING_SH="$(resolve_script bgwork-ceiling.sh)" || CEILING_SH=""
HANDOFF_SH="$(resolve_script handoff-state.sh)" || HANDOFF_SH=""
CLAIM_SH="$(resolve_script issue-claim.sh)" || CLAIM_SH=""
GATE_SH="$(resolve_script merge-gate.sh)" || GATE_SH=""

# ---- accumulators (JSON held in shell variables; no temp files) -----------------
ITEMS='[]'
EXCLUDED='[]'
CATS='{}'
UNKNOWN_CATS=""

json_str() { jq -n --arg v "$1" '$v'; }

add_item() { # category id summary consequence detail [ref-json]
  ITEMS="$(jq -c --arg c "$1" --arg i "$2" --arg s "$3" --arg q "$4" --arg d "$5" \
    --argjson r "${6:-null}" '. + [{category:$c,id:$i,summary:$s,consequence:$q,detail:$d,ref:$r}]' <<<"$ITEMS")"
}
add_excluded() { # category id summary reason
  EXCLUDED="$(jq -c --arg c "$1" --arg i "$2" --arg s "$3" --arg r "$4" \
    '. + [{category:$c,id:$i,summary:$s,reason:$r}]' <<<"$EXCLUDED")"
}
cat_unknown() { # category reason [ref-json]  — unreadable or unattributable
  add_item "$1" "$1:unknown" "$2" unknown "cannot be verified; treated as outstanding" "${3:-null}"
  UNKNOWN_CATS="$UNKNOWN_CATS $1"
  CATS="$(jq -c --arg c "$1" --arg r "$2" '. + {($c):{status:"unknown",reason:$r}}' <<<"$CATS")"
}
cat_ok() { # category
  CATS="$(jq -c --arg c "$1" 'if has($c) then . else . + {($c):{status:"ok",reason:null}} end' <<<"$CATS")"
}

# ---- identity ---------------------------------------------------------------------
WT="${WT_OPT:-}"
if [[ -z "$WT" ]]; then WT="$(git rev-parse --show-toplevel 2>/dev/null)" || WT=""; fi
if [[ -n "$WT" ]]; then WT="$(cd "$WT" 2>/dev/null && pwd -P)" || WT=""; fi

REPO="$REPO_OPT"
if [[ -z "$REPO" && -n "$SESSION_STATE_SH" ]]; then
  REPO="$("$SESSION_STATE_SH" --repo-key 2>/dev/null)" || REPO=""
  [[ "$REPO" == "_unknown" ]] && REPO=""
fi
REPO="$(printf '%s' "$REPO" | tr '[:upper:]' '[:lower:]')"
HOST="$(hostname 2>/dev/null || echo unknown)"
HOLDER_DEFAULT=""
[[ -n "$WT" ]] && HOLDER_DEFAULT="$HOST:$WT"

# ---- session-state read helper ---------------------------------------------------
# ss_get <jq-path> -> stdout JSON (null when absent); returns 1 when unreadable.
ss_get() {
  local out
  [[ -n "$SESSION_STATE_SH" && -n "$REPO" ]] || return 1
  out="$("$SESSION_STATE_SH" --repo "$REPO" --get-json "$1" 2>/dev/null)" || return 1
  jq empty >/dev/null 2>&1 <<<"$out" || return 1
  printf '%s' "$out"
}

# jq: normalise a collection (object, array, null) into records carrying _key.
JQ_RECS='def recs: if . == null then [] elif type == "object" then (to_entries | map(if (.value|type)=="object" then .value + {_key:.key} else {_key:.key, _value:.value} end)) elif type == "array" then (to_entries | map(if (.value|type)=="object" then .value + {_key:(.key|tostring)} else {_key:(.key|tostring), _value:.value} end)) else error("unexpected shape") end;'
# jq: classify one record as this | other | unknown | terminal.
JQ_ATTR='def terminal: (.outcome != null) or ((.status // "") | tostring | test("^(done|merged|completed|failed|stopped|abandoned|closed|cancelled)$"));
def attr($s; $h; $r; $ids):
  if terminal then "terminal"
  elif ((.owner_repo // null) != null and ((.owner_repo|ascii_downcase) != $r) and $r != "") then "other"
  elif ((.session_id // .session // "") | tostring) != "" then (if ((.session_id // .session)|tostring) == $s and $s != "" then "this" else "other" end)
  elif ((.claim_holder // "") | tostring) != "" then ((.claim_holder|tostring) as $ch | if ([$s,$h] | index($ch)) != null then "this" else "other" end)
  elif ([(.id // null), (.agent // null), (._key // null)] | map(select(. != null) | tostring) | map(. as $x | ($ids | index($x)) != null) | any) then "this"
  else "unknown" end;'

# ---- 1. background tasks (registry) ---------------------------------------------
REG_IDS='[]'
REG_JSON='[]'
if [[ -z "$SESSION_ID" ]]; then
  cat_unknown background_tasks "no session id: tasks cannot be attributed to this thread (pass --session or set CLAUDE_SESSION_ID)"
elif [[ -z "$REGISTRY_SH" ]]; then
  cat_unknown background_tasks "background-task-registry.sh not found"
else
  if out="$("$REGISTRY_SH" ${REPO:+--repo "$REPO"} --list --session "$SESSION_ID" --live 2>/dev/null)" && jq -e 'type=="array"' >/dev/null 2>&1 <<<"$out"; then
    # Historical records too: a finished task's worktree can still hold unsaved work, and
    # its runtime id still attributes the session-state records that name it. Only live
    # tasks become keeps_running items.
    if all="$("$REGISTRY_SH" ${REPO:+--repo "$REPO"} --list --session "$SESSION_ID" 2>/dev/null)" && jq -e 'type=="array"' >/dev/null 2>&1 <<<"$all"; then
      REG_JSON="$all"
    else
      REG_JSON="$out"
      cat_unknown background_tasks "could not read this session's finished task records, so their worktrees cannot be found"
    fi
    REG_IDS="$(jq -c '[.[].task_id | tostring]' <<<"$REG_JSON")"
    while IFS= read -r row; do
      [[ -n "$row" ]] || continue
      tid="$(jq -r '.task_id' <<<"$row")"
      ttype="$(jq -r '.type // "task"' <<<"$row")"
      tname="$(jq -r '.name // .work_item // ""' <<<"$row")"
      tstat="$(jq -r '.status // ""' <<<"$row")"
      tstale="$(jq -r 'if .stale == true then " (stale record)" else "" end' <<<"$row")"
      add_item background_tasks "$tid" "$ttype ${tname:-$tid} is $tstat$tstale" keeps_running \
        "registered live background task; closing leaves it running unattended" \
        "$(jq -c '{kind:"background_task",task_id:.task_id,type:.type,status:.status,output_file:(.output_file // null),recovery_path:(.recovery_path // null)}' <<<"$row")"
    done < <(jq -c '.[]' <<<"$out")
    cat_ok background_tasks
  else
    cat_unknown background_tasks "background-task registry unreadable (missing or corrupt session-state.json)"
  fi
fi

# ---- 2. subagent records, 3. queued work, 4. pause/resume markers (session-state)
scan_records() { # category jq-path label consequence-for-this
  local cat="$1" path="$2" label="$3" cons="$4" raw recs row n_unk=0 unk_ids="" cls id c
  if ! raw="$(ss_get "$path")"; then
    cat_unknown "$cat" "session-state $path unreadable"
    return
  fi
  if ! recs="$(jq -c "$JQ_RECS $JQ_ATTR"' recs | map(. + {_cls: attr($s; $h; $r; $ids)})' \
      --arg s "$SESSION_ID" --arg h "$HOLDER_DEFAULT" --arg r "$REPO" --argjson ids "$REG_IDS" <<<"$raw" 2>/dev/null)"; then
    cat_unknown "$cat" "session-state $path has an unexpected shape"
    return
  fi
  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    cls="$(jq -r '._cls' <<<"$row")"
    id="$(jq -r '._key' <<<"$row")"
    case "$cls" in
      this)
        c="$cons"
        if [[ "$cat" == queued_work ]] && jq -e '.started_at != null' >/dev/null <<<"$row"; then c=orphaned; fi
        add_item "$cat" "$path:$id" "$label $id ($(jq -r '.task // .phase // .status // "recorded"' <<<"$row"))" "$c" \
          "$(if [[ "$c" == lost ]]; then echo "queued but not started; closing drops it"; elif [[ "$c" == orphaned ]]; then echo "pipeline started; nothing will carry it forward"; else echo "recorded as live; closing leaves it unattended"; fi)" \
          "$(jq -c --arg p "$path" '{kind:"state_record",path:$p,key:._key,issue:(.issue // null),pr:(.pr // null)}' <<<"$row")" ;;
      other) add_excluded "$cat" "$path:$id" "$label $id" "owned by another thread or repo" ;;
      unknown) n_unk=$((n_unk + 1)); unk_ids="$unk_ids $id" ;;
    esac
  done < <(jq -c '.[]' <<<"$recs")
  if (( n_unk > 0 )); then
    cat_unknown "$cat" "$n_unk non-terminal $path record(s) name no owner, so this thread's share cannot be shown (keys in ref)" \
      "$(jq -n --arg p "$path" --arg ids "$unk_ids" '{kind:"unattributed_records",path:$p,keys:($ids|split(" ")|map(select(length>0)))}')"
  fi
  cat_ok "$cat"
}
scan_records subagents '.active_agents' "subagent" keeps_running
for qpath in '.pipelines' '.queued_chain' '.subagent_queue'; do scan_records queued_work "$qpath" "queued/pipeline entry" lost; done

mark_one() { # category jq-path label  — one per-session marker map
  local cat="$1" path="$2" label="$3" raw
  if ! raw="$(ss_get "$path")"; then cat_unknown "$cat" "session-state $path unreadable"; return; fi
  # A marker map is an object or absent; any other JSON shape cannot be read as "no entry".
  if ! jq -e 'type == "object" or type == "null"' >/dev/null 2>&1 <<<"$raw"; then
    cat_unknown "$cat" "session-state $path has an unexpected shape"; return
  fi
  if [[ -z "$SESSION_ID" ]]; then
    if jq -e 'type=="object" and length>0' >/dev/null <<<"$raw"; then
      cat_unknown "$cat" "no session id: cannot tell which $path markers are this thread's"
    fi
    return
  fi
  if jq -e --arg s "$SESSION_ID" 'type=="object" and has($s) and (.[$s] != null)' >/dev/null <<<"$raw"; then
    local active
    active="$(jq -r --arg s "$SESSION_ID" '.[$s] | if .active == false then "false" else "true" end' <<<"$raw")"
    if [[ "$active" == false ]]; then
      add_item "$cat" "$path:$SESSION_ID" "$label marker (cleared)" harmless "marker already cleared" '{"kind":"state_marker"}'
    else
      add_item "$cat" "$path:$SESSION_ID" "$label marker is still set for this session" orphaned \
        "nothing will clear or act on it once the thread is gone" "$(jq -n --arg p "$path" '{kind:"state_marker",path:$p}')"
    fi
  fi
  cat_ok "$cat"
}
# The writers (/pause, /go-on, execution-pause.sh) keep these maps under .repos[<repo>]; the top-level
# path is the legacy layout. Each is judged on its own, so an active entry in either stays active even
# when the other holds a cleared one (issue #2262).
mark_session() {
  mark_one "$1" "$2" "$3"
  [[ -n "$REPO" ]] && mark_one "$1" ".repos[\"$REPO\"]$2" "$3"
}
mark_session state_markers '.execution_pauses' "launch-pause gate"
mark_session state_markers '.pauses' "pause/park"
mark_session state_markers '.resumes' "resume"
for lpath in '.leave' ".repos[\"$REPO\"].leave"; do
  [[ "$lpath" == .repos* && -z "$REPO" ]] && continue
  if raw="$(ss_get "$lpath")"; then
    if jq -e 'type=="object" and (.active == true)' >/dev/null <<<"$raw"; then
      lsid="$(jq -r '(.session_id // .session // "")' <<<"$raw")"
      if [[ -z "$lsid" ]]; then
        cat_unknown state_markers "an armed repo-scoped leave marker names no session, so it cannot be attributed to this thread"
      elif [[ "$lsid" == "$SESSION_ID" ]]; then
        add_item state_markers "$lpath" "leave-by marker is armed for this session" orphaned "the wind-down monitor dies with the thread" \
          "$(jq -n --arg p "$lpath" '{kind:"state_marker",path:$p}')"
      else
        add_excluded state_markers "$lpath" "leave-by marker" "armed for another session"
      fi
    fi
  else
    cat_unknown state_markers "session-state $lpath unreadable"
  fi
done
cat_ok state_markers

# ---- 5. bgwork ceiling / watchers ----------------------------------------------
if [[ -z "$SESSION_ID" ]]; then
  cat_unknown ceiling "no session id: ceiling markers cannot be attributed"
elif [[ -z "$CEILING_SH" ]]; then
  cat_unknown ceiling "bgwork-ceiling.sh not found"
elif out="$("$CEILING_SH" --status --session "$SESSION_ID" 2>/dev/null)" && jq -e '.background_work != null' >/dev/null 2>&1 <<<"$out"; then
  nwork="$(jq -r '.background_work | length' <<<"$out")"
  armed="$(jq -r '.armed' <<<"$out")"
  if (( nwork > 0 )); then
    add_item ceiling "bgwork:$SESSION_ID" "$nwork background work marker(s) recorded; silence ceiling armed=$armed" keeps_running \
      "background work was noted as started and never cleared" "$(jq -c '{kind:"bgwork",background_work:.background_work,armed:.armed}' <<<"$out")"
  elif [[ "$armed" == true ]]; then
    add_item ceiling "bgwork:$SESSION_ID" "silence-ceiling watch armed with no background work noted" harmless \
      "the watch ends with the session" '{"kind":"bgwork"}'
  fi
  cat_ok ceiling
else
  cat_unknown ceiling "bgwork-ceiling.sh --status failed or returned no snapshot"
fi

# ---- 6. worktrees, branches, PRs, handoffs -----------------------------------------
# The thread's checkouts: its own worktree plus the recovery paths of the agents it registered.
WT_LIST=""
[[ -n "$WT" ]] && WT_LIST="$WT"
while IFS= read -r p; do
  [[ -n "$p" && -d "$p" ]] || continue
  if ! p="$(cd "$p" 2>/dev/null && pwd -P)"; then
    cat_unknown worktrees "a registered recovery path exists but cannot be entered: $p"
    continue
  fi
  case "
$WT_LIST
" in *"
$p
"*) ;; *) WT_LIST="$WT_LIST
$p" ;; esac
done < <(jq -r '.[] | .recovery_path // empty' <<<"$REG_JSON")

PR_NUMS=""   # PRs the thread is linked to besides its branches
BRANCHES=""
ISSUES=""
add_issue() { case " $ISSUES " in *" $1 "*) ;; *) ISSUES="$ISSUES $1" ;; esac; }
add_pr() { case " $PR_NUMS " in *" $1 "*) ;; *) PR_NUMS="$PR_NUMS $1" ;; esac; }

default_ref() { # <wt> -> remote default branch ref, or empty
  local r
  r="$(git -C "$1" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null)" && { printf '%s' "${r#refs/remotes/}"; return; }
  for r in origin/main origin/master; do
    git -C "$1" rev-parse --verify --quiet "$r" >/dev/null 2>&1 && { printf '%s' "$r"; return; }
  done
}

if [[ -z "$WT" ]]; then
  cat_unknown worktrees "no git checkout found for this thread (pass --worktree)"
else
  while IFS= read -r w; do
    [[ -n "$w" ]] || continue
    if ! br_out="$(git -C "$w" branch --show-current 2>/dev/null)"; then
      cat_unknown worktrees "could not read the branch of $w"; continue
    fi
    if ! st_out="$(git -C "$w" --no-optional-locks status --porcelain 2>/dev/null)"; then
      cat_unknown worktrees "could not read git status of $w"; continue
    fi
    if ! unpushed="$(git -C "$w" rev-list --count HEAD --not --remotes 2>/dev/null)"; then
      cat_unknown worktrees "could not count unpushed commits in $w"; continue
    fi
    ndirty=0
    [[ -n "$st_out" ]] && ndirty="$(printf '%s\n' "$st_out" | grep -c .)"
    dref="$(default_ref "$w")"
    on_default=0
    case "$br_out" in main|master) on_default=1 ;; esac
    wref="$(jq -n --arg p "$w" --arg b "$br_out" '{kind:"worktree",path:$p,branch:$b}')"
    if (( ndirty > 0 )); then
      add_item worktrees "dirty:$w" "$ndirty uncommitted path(s) in $w${br_out:+ ($br_out)}" lost \
        "uncommitted edits exist only in this checkout" "$wref"
    fi
    if (( unpushed > 0 )); then
      add_item worktrees "unpushed:$w" "$unpushed unpushed commit(s) in $w${br_out:+ ($br_out)}" lost \
        "commits exist on no remote" "$wref"
    fi
    if (( ndirty == 0 && unpushed == 0 )); then
      add_item worktrees "clean:$w" "checkout $w is clean and fully pushed" harmless "nothing unsaved" "$wref"
    fi
    if [[ -z "$br_out" ]]; then
      # Detached HEAD: no branch to look a PR up by, so ownership of its work cannot be shown.
      cat_unknown branches "checkout $w is on a detached HEAD, so its branch and PR cannot be determined"
    elif (( on_default == 0 )); then
      if ! headsha="$(git -C "$w" rev-parse HEAD 2>/dev/null)"; then
        cat_unknown branches "could not read HEAD of $w"; continue
      fi
      BRANCHES="$BRANCHES
$br_out|$w|$dref|$unpushed|$headsha"
      if [[ "$br_out" =~ ^(worktree-)?issue-([0-9]+)(-|$) ]]; then add_issue "${BASH_REMATCH[2]}"; fi
    fi
  done <<<"$WT_LIST"
  cat_ok worktrees
fi

# PR numbers and issue numbers the registered work items and this thread's records name.
while IFS= read -r wi; do
  [[ -n "$wi" ]] || continue
  if [[ "$wi" =~ PR[[:space:]]*#?([0-9]+) ]]; then add_pr "${BASH_REMATCH[1]}"; fi
  if [[ "$wi" =~ [Ii]ssue[[:space:]]*#?([0-9]+) ]]; then add_issue "${BASH_REMATCH[1]}"; fi
done < <(jq -r '.[] | .work_item // empty' <<<"$REG_JSON")
for src in '.active_agents' '.pipelines'; do
  if raw="$(ss_get "$src")" && recs="$(jq -c "$JQ_RECS $JQ_ATTR"' recs | map(del(.outcome) | .status = "" | select(attr($s; $h; $r; $ids) == "this"))' \
      --arg s "$SESSION_ID" --arg h "$HOLDER_DEFAULT" --arg r "$REPO" --argjson ids "$REG_IDS" <<<"$raw" 2>/dev/null)"; then
    while IFS= read -r n; do [[ "$n" =~ ^[0-9]+$ ]] && add_pr "$n"; done < <(jq -r '.[] | .pr // empty' <<<"$recs")
    while IFS= read -r n; do [[ "$n" =~ ^[0-9]+$ ]] && add_issue "$n"; done < <(jq -r '.[] | .issue // empty' <<<"$recs")
  fi
done

# Open PRs, branches without a PR, handoffs.
VIEWER=""
if [[ -z "$REPO" ]]; then
  cat_unknown open_prs "repository could not be resolved"
  cat_unknown branches "repository could not be resolved"
  cat_unknown claims "repository could not be resolved"
elif ! command -v gh >/dev/null 2>&1; then
  cat_unknown open_prs "gh not found"
  cat_unknown branches "gh not found"
  cat_unknown claims "gh not found"
else
  VIEWER="$(gh api user --jq '.login' 2>/dev/null)" || VIEWER=""
  [[ "$VIEWER" == null ]] && VIEWER=""
  if [[ -z "$VIEWER" ]]; then
    cat_unknown open_prs "could not resolve the authenticated GitHub user, so authorship is undetermined"
  fi
  SEEN_PRS=""
  MERGED_COVERS=0   # per branch: merged PRs whose head is the checkout's head
  handle_pr() { # <pr-json> <via>
    local pj="$1" n st author merged url gate gdetail c
    n="$(jq -r '.number' <<<"$pj")"; st="$(jq -r '.state' <<<"$pj")"
    case " $SEEN_PRS " in *" $n "*) return ;; esac
    SEEN_PRS="$SEEN_PRS $n"
    author="$(jq -r '.author.login // .user.login // ""' <<<"$pj")"
    url="$(jq -r '.url // ""' <<<"$pj")"
    if [[ "$st" == MERGED ]]; then
      add_item open_prs "pr:$n" "PR #$n is merged" harmless "already landed" \
        "$(jq -n --argjson n "$n" --arg u "$url" '{kind:"pr",number:$n,url:$u}')"
      return
    fi
    if [[ "$st" != OPEN ]]; then
      # Closed without merging: the PR's existence is not proof the work landed.
      if [[ -n "$VIEWER" && -n "$author" && "$author" != "$VIEWER" ]]; then
        add_excluded open_prs "pr:$n" "PR #$n by $author" "another author's PR"
      elif [[ "$MERGED_COVERS" -gt 0 ]]; then
        add_item open_prs "pr:$n" "PR #$n was closed, but a merged PR covers the branch head" harmless "the work landed through another PR" \
          "$(jq -n --argjson n "$n" --arg u "$url" '{kind:"pr",number:$n,url:$u}')"
      else
        add_item open_prs "pr:$n" "PR #$n was closed without merging" orphaned \
          "the branch work did not land; nothing will carry it forward" \
          "$(jq -n --argjson n "$n" --arg u "$url" '{kind:"pr",number:$n,url:$u}')"
      fi
      return
    fi
    if [[ -z "$author" ]]; then
      cat_unknown open_prs "PR #$n has no readable author, so ownership is undetermined"; return
    fi
    if [[ -n "$VIEWER" && "$author" != "$VIEWER" ]]; then
      add_excluded open_prs "pr:$n" "PR #$n by $author" "another author's PR"; return
    fi
    [[ -z "$VIEWER" ]] && return
    gdetail="merge gate not read"
    if [[ -n "$GATE_SH" ]]; then
      if gout="$("$GATE_SH" "$n" 2>/dev/null)" && jq -e . >/dev/null 2>&1 <<<"$gout"; then
        gdetail="merge gate met"
      elif jq -e . >/dev/null 2>&1 <<<"${gout:-}"; then
        gdetail="merge gate not met: $(jq -r '[.missing[]? | tostring] | .[0:3] | join("; ")' <<<"$gout")"
      else
        gdetail="merge gate unavailable"
      fi
    fi
    add_item open_prs "pr:$n" "PR #$n is open ($gdetail)" orphaned \
      "no thread will babysit or merge it once this one is closed" \
      "$(jq -n --argjson n "$n" --arg u "$url" --arg g "$gdetail" '{kind:"pr",number:$n,url:$u,gate:$g}')"
  }
  PR_FIELDS='number,state,url,author,mergedAt,headRefName,headRefOid'
  while IFS='|' read -r b w dref unpushed headsha; do
    [[ -n "$b" ]] || continue
    if out="$(gh pr list --repo "$REPO" --head "$b" --state all --json "$PR_FIELDS" --limit 20 2>/dev/null)" && jq -e 'type=="array"' >/dev/null 2>&1 <<<"$out"; then
      # A PR covers the branch only when it includes the checkout's current head.
      covered="$(jq -r --arg h "$headsha" '[.[] | select(.headRefOid == $h)] | length' <<<"$out")"
      MERGED_COVERS="$(jq -r --arg h "$headsha" '[.[] | select(.state == "MERGED" and .headRefOid == $h)] | length' <<<"$out")"
      if [[ "$covered" == 0 ]]; then
        ahead=0
        if [[ -n "$dref" ]]; then ahead="$(git -C "$w" rev-list --count "$dref..HEAD" 2>/dev/null)" || ahead=-1; fi
        if [[ "$ahead" == -1 || -z "$dref" ]]; then
          cat_unknown branches "could not measure branch $b against the default branch"
        elif (( ahead > 0 && unpushed == 0 )); then
          add_item branches "branch:$b" "branch $b has $ahead commit(s) pushed that no PR covers" orphaned \
            "pushed work with no PR covering it; nothing will land it" "$(jq -n --arg b "$b" '{kind:"branch",branch:$b}')"
        elif (( ahead > 0 )); then
          :  # unpushed work is already reported as lost under worktrees
        else
          add_item branches "branch:$b" "branch $b has no commits beyond the default branch" harmless "nothing to land" "$(jq -n --arg b "$b" '{kind:"branch",branch:$b}')"
        fi
      fi
      while IFS= read -r pj; do handle_pr "$pj"; done < <(jq -c '.[]' <<<"$out")
    else
      cat_unknown open_prs "could not list PRs for branch $b"
    fi
  done <<<"$BRANCHES"
  MERGED_COVERS=0
  for n in $PR_NUMS; do
    if out="$(gh pr view "$n" --repo "$REPO" --json "$PR_FIELDS" 2>/dev/null)" && jq -e '.number != null' >/dev/null 2>&1 <<<"$out"; then
      handle_pr "$out"
    else
      cat_unknown open_prs "could not read PR #$n named by this thread's records"
    fi
  done
  cat_ok open_prs
  cat_ok branches

  # Handoff files for this thread's PRs.
  if [[ -n "$HANDOFF_SH" ]]; then
    for n in $SEEN_PRS; do
      if hp="$("$HANDOFF_SH" --owner-repo "$REPO" --path "$n" 2>/dev/null)" && [[ -n "$hp" ]]; then
        if [[ -e "$hp" ]]; then
          add_item handoffs "handoff:$n" "handoff file for PR #$n exists" harmless "a leftover note; cleanup removes it after merge" \
            "$(jq -n --arg p "$hp" '{kind:"handoff",path:$p}')"
        fi
      else
        cat_unknown handoffs "could not resolve the handoff path for PR #$n"
      fi
    done
  else
    [[ -n "$SEEN_PRS" ]] && cat_unknown handoffs "handoff-state.sh not found"
  fi
  cat_ok handoffs

  # Issue claims still held by this thread.
  # Candidates: issues the thread's records and branches name, plus every open
  # in-progress issue assigned to this account (a claim can outlive its records).
  # A failed enumeration is unknown, never an empty list.
  if [[ -n "$VIEWER" ]]; then
    if iout="$(gh issue list --repo "$REPO" --label in-progress --assignee "@me" --state open --json number --limit 50 2>/dev/null)" \
        && jq -e 'type=="array"' >/dev/null 2>&1 <<<"$iout"; then
      while IFS= read -r n; do [[ "$n" =~ ^[0-9]+$ ]] && add_issue "$n"; done < <(jq -r '.[].number' <<<"$iout")
      if [[ "$(jq 'length' <<<"$iout")" -ge 50 ]]; then
        cat_unknown claims "50 or more in-progress issues are assigned to this account; the list may be truncated"
      fi
    else
      cat_unknown claims "could not list this account's in-progress issues, so held claims cannot be enumerated"
    fi
  else
    cat_unknown claims "could not resolve the authenticated GitHub user, so held claims cannot be enumerated"
  fi
  if [[ -n "$ISSUES" ]]; then
    if [[ -z "$CLAIM_SH" ]]; then
      cat_unknown claims "issue-claim.sh not found"
    else
      holder="${SESSION_ID:-$HOLDER_DEFAULT}"
      for i in $ISSUES; do
        # --check exits non-zero for claimed/unknown but still prints its JSON verdict.
        cout="$("$CLAIM_SH" "$i" --check --json --repo "$REPO" --holder "$holder" 2>/dev/null)"
        if jq -e '.verdict != null' >/dev/null 2>&1 <<<"$cout"; then
          verdict="$(jq -r '.verdict' <<<"$cout")"
          cholder="$(jq -r '.claimant_holder // ""' <<<"$cout")"
          case "$verdict" in
            mine) add_item claims "claim:$i" "issue #$i is still claimed by this thread" orphaned \
                    "the claim blocks other threads until it goes stale" "$(jq -n --argjson i "$i" '{kind:"claim",issue:$i}')" ;;
            claimed)
              if [[ -n "$cholder" && ( "$cholder" == "$SESSION_ID" || "$cholder" == "$HOLDER_DEFAULT" ) ]]; then
                add_item claims "claim:$i" "issue #$i is still claimed by this thread" orphaned \
                  "the claim blocks other threads until it goes stale" "$(jq -n --argjson i "$i" '{kind:"claim",issue:$i}')"
              else
                add_excluded claims "claim:$i" "issue #$i" "claimed by another thread"
              fi ;;
            unclaimed|stale) : ;;
            *) cat_unknown claims "claim state of issue #$i is unknown" ;;
          esac
        else
          cat_unknown claims "could not read the claim on issue #$i"
        fi
      done
    fi
  fi
  cat_ok claims
fi
# Without a repo the GitHub-backed categories were already marked unknown above.
cat_ok claims

# ---- 7. scratchpad files ------------------------------------------------------------
SCRATCH_CHECKED=false
if [[ -n "$SCRATCH" ]]; then
  SCRATCH_CHECKED=true
  if [[ ! -d "$SCRATCH" ]] || ! find "$SCRATCH" -type f >/dev/null 2>&1; then
    cat_unknown scratchpad "scratchpad $SCRATCH is not a readable directory"
  else
    nfiles="$(find "$SCRATCH" -type f 2>/dev/null | wc -l | tr -d ' ')"
    if (( nfiles > 0 )); then
      add_item scratchpad "scratch:$SCRATCH" "$nfiles scratch file(s) in $SCRATCH" harmless "temporary files; cleanup may remove them" \
        "$(jq -n --arg p "$SCRATCH" '{kind:"scratchpad",path:$p}')"
    fi
    cat_ok scratchpad
  fi
fi

# ---- agent checks (facts only the harness can see) -------------------------------------
AGENT_CHECKS="$(jq -n '[
 {id:"harness_background_tasks", what:"Background shell commands, Monitors and wake-ups the harness is running for this thread, including ones never registered", how:"List your own running background tasks (the harness task list); each is keeps_running"},
 {id:"harness_subagents", what:"Subagents still running that this thread launched", how:"Check the harness agent list and any unresolved agent completion; each is keeps_running"},
 {id:"unregistered_worktrees", what:"Worktrees this thread created itself that no registered task names, so the script never inspected them", how:"List the checkouts you created (git worktree list, minus the one already inspected); for each, an uncommitted or unpushed change is lost and a PR-less branch is orphaned"},
 {id:"linked_sessions", what:"Sessions this thread started and that are still live", how:"Check the sessions this thread spawned or linked (session list); each is keeps_running"},
 {id:"unanswered_question", what:"A question to the user in this conversation that has no answer yet", how:"Reread the last turns; an open question is lost on close"},
 {id:"human_queue", what:"Questions this thread queued to the human desk that are still open", how:"human-queue.sh list --status open (desk/bin), keep those this thread asked; each is lost"}
]')"

# ---- verdict ------------------------------------------------------------------------------
for c in background_tasks subagents queued_work state_markers ceiling worktrees open_prs branches handoffs claims; do
  cat_ok "$c"
done
if [[ "$SCRATCH_CHECKED" == false ]]; then
  CATS="$(jq -c '. + {scratchpad:{status:"not_checked",reason:"no --scratchpad given"}}' <<<"$CATS")"
fi
CATS="$(jq -c --argjson it "$ITEMS" 'with_entries(.key as $k | .value += {items: ($it | map(select(.category == $k)) | length)})' <<<"$CATS")"
OUTSTANDING="$(jq '[.[] | select(.consequence != "harmless")] | length' <<<"$ITEMS")"
VERDICT=safe
(( OUTSTANDING > 0 )) && VERDICT=not_yet

RESULT="$(jq -n --argjson items "$ITEMS" --argjson excl "$EXCLUDED" --argjson cats "$CATS" --argjson checks "$AGENT_CHECKS" \
  --arg verdict "$VERDICT" --argjson out "$OUTSTANDING" --arg session "$SESSION_ID" --arg repo "$REPO" --arg wt "$WT" \
  '{schema_version:1, verdict:$verdict, outstanding:$out, needs_agent_checks:($checks|length>0),
    session:(if $session=="" then null else $session end), repo:(if $repo=="" then null else $repo end),
    worktree:(if $wt=="" then null else $wt end),
    categories:$cats, items:$items, excluded:$excl, agent_checks:$checks}')" || { echo "safe-close-inventory.sh: could not assemble the result" >&2; exit 3; }

if [[ "$FORMAT" == text ]]; then
  if [[ "$VERDICT" == safe ]]; then
    echo "Safe to close (script-readable state is clear)."
  else
    echo "Not yet: $OUTSTANDING outstanding."
    jq -r '.items[] | select(.consequence != "harmless") | "  [\(.consequence)] \(.category): \(.summary)"' <<<"$RESULT"
  fi
  nh="$(jq '[.items[] | select(.consequence == "harmless")] | length' <<<"$RESULT")"
  nx="$(jq '.excluded | length' <<<"$RESULT")"
  echo "$nh harmless, $nx owned by others (not counted); harness-only checks still to do: $(jq -r '[.agent_checks[].id] | join(", ")' <<<"$RESULT")"
else
  printf '%s\n' "$RESULT"
fi
[[ "$VERDICT" == safe ]]
