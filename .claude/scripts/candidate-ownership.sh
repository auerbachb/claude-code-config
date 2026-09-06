#!/usr/bin/env bash
# candidate-ownership.sh — Does another thread already own this candidate? (issue #1431)
# catalog: backlog-pm — Read-only pre-dispatch sweep — does another thread already own this candidate, is it live or dead, and how is it resumed
#
# PURPOSE
#   A cold-started `/pm` rebuilds the board from GitHub and refills the pipeline
#   without being asked. But in-flight work does not live only on GitHub: it also
#   lives in other conversation threads — a coding thread paused mid-issue, a PM
#   thread that parked itself, a fleet manager waiting on its wake command, a
#   session that died with resumable state on disk. The per-item guard used to be
#   the claim gate alone, and a stale claim is re-picked with only a warning —
#   the exact shape that shipped issue #652 twice (PRs #661 and #673).
#
#   This helper answers, per candidate issue, "does another thread already own
#   this, is that thread still alive, and how do I get it moving again?" It is
#   READ-ONLY: it never claims, never releases, never writes session state.
#
# THE THREE-WAY BRANCH (issue #1431 AC)
#   unowned     -> dispatch exactly as today. The common case does not change.
#   owned_live  -> skip and surface one line naming the owner, its state, and the
#                  resume route. `/pm` never un-pauses someone else's thread: a
#                  human parked it, and resuming the same work in two places is
#                  how duplicates get shipped.
#   owned_dead  -> adopt. Resume from whatever state survived — the branch, the
#                  open PR, the handoff file — rather than redoing from scratch
#                  or pointing at a thread that no longer exists.
#
# LIVENESS FAILS TOWARD SURFACING
#   Liveness is resolved against a session listing supplied by the caller
#   (--sessions), because no CLI enumerates Claude sessions — the listing comes
#   from the harness. `open`/`paused` classify live; `archived` or absent from
#   the listing classifies dead. With NO listing, or no resolvable owner session
#   id, liveness is `indeterminate` and the owner is treated as **live**:
#   surfacing a thread that turned out to be dead costs one line, adopting work a
#   live thread is still doing costs a duplicate implementation.
#
# OWNED-RESUMABLE UPGRADE, AND WHAT IT DOES NOT TOUCH
#   `issue-claim.sh` reports `stale` for a claim older than CLAIM_STALE_HOURS and
#   the caller warns and proceeds. This helper upgrades a stale claim to OWNED
#   when resumable evidence stands behind it (a parked entry, a background-task
#   entry, an execution pause, a pause/portable-handoff marker, a linked open PR,
#   or a phase handoff file). A BARE stale claim — no evidence — stays `unowned`,
#   so today's warn-and-proceed survives untouched.
#
# ADOPTION NEEDS A STARTABLE CLAIM
#   Adoption takes the claim over via the EXISTING stale-takeover path
#   (`issue-claim.sh <N> --claim`, which re-stamps a stale claim). That path
#   refuses a fresh foreign claim without `--allow-claimed`, and
#   `--allow-claimed` is an explicit per-issue user instruction — never inferred.
#   So a candidate under a FRESH foreign claim is `skip` even when its session is
#   dead: the claim gate outranks the sweep, and the claim ages out on its own.
#
# DEGRADATION IS NAMED, NEVER SILENT
#   Any missing/unreadable/unparseable source is appended to that candidate's
#   `degraded[]` with the source name, and the sweep continues. A read failure
#   NEVER marks a candidate owned by itself — the failure mode we refuse is a
#   sweep that silently swallows a whole backlog. An `unknown` claim verdict is
#   the one fail-closed input: it is the claim gate's own verdict and keeps its
#   own meaning (skip, per `.claude/rules/issue-planning.md` step 0).
#
# USAGE
#   candidate-ownership.sh <issue> [<issue> ...] [--repo owner/repo] [--json]
#                          [--holder ID] [--sessions PATH|-]
#   candidate-ownership.sh --help | -h
#
#   --repo owner/repo  Evaluate against a named repo instead of the checkout's.
#   --json             One JSON object per candidate, one per line (NDJSON).
#   --holder ID        Holder token identifying THIS thread; passed through to
#                      issue-claim.sh. Evidence attributable to this holder or
#                      this session is never "another thread".
#   --sessions PATH    Session listing JSON for liveness. `-` reads stdin.
#                      Accepts an array, or an object with a `sessions` /
#                      `data` / `results` array. Each entry may name its id as
#                      `id` / `session_id` / `sessionId` / `uuid`, its state as
#                      `status` / `state`, and its title as `title` / `name` /
#                      `summary`. Absent -> liveness `indeterminate` -> live.
#
# ENVIRONMENT
#   CLAUDE_SESSION_LISTING   Path to the session listing when --sessions is unset.
#   CLAUDE_SESSION_ID        This thread's session id (self-attribution + holder).
#   CLAUDE_CLAIM_HOLDER      Holder token, when --holder is not passed.
#   CLAUDE_SESSION_REPO      Repo key when --repo is not passed.
#   CLAUDE_HANDOFF_DIR       Handoff/marker root (default ~/.claude/handoffs).
#   CANDIDATE_OWNERSHIP_SCRIPT_DIR  Directory to resolve sibling helpers from
#                            first (tests). The normal order is the three-path
#                            ladder from portable-skill-resolution.md.
#
# OUTPUT
#   Default: one line per candidate —
#     #N <action> verdict=<v> state=<s> liveness=<l> owner=<label> route=<r>
#   plus, when non-empty, `#N degraded: <source>[, <source>...]`.
#   --json: one object per candidate per line:
#     {issue, owned, verdict, action, reason, state, liveness, owner_label,
#      owner_session_id, resume_route, claim_verdict, adopt:{from,pr,branch,
#      handoff_path,phase}, evidence[], degraded[]}
#
#   verdict: unowned | owned_live | owned_dead
#   action:  dispatch | skip | adopt      <- what the caller does
#   state:   active | paused | stale | none
#   liveness: live | dead | indeterminate
#
# EXIT STATUS
#   0  Sweep ran; every candidate carries a verdict (owned or not).
#   2  Usage error, or a hard dependency (jq) is missing.
#   70  --help header extraction produced no output (internal defect).
#
#   There is deliberately no "something was owned" exit code: a sweep over N
#   candidates has N answers, and collapsing them into one exit status is how a
#   caller ends up blocking a dispatchable backlog on one owned item.
#
# EXAMPLES
#   candidate-ownership.sh 1431 1428 --json
#   candidate-ownership.sh 1431 --sessions /tmp/sessions.json
#   candidate-ownership.sh 1431 --repo auerbachb/claude-code-config

set -uo pipefail
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" 2>/dev/null >> "$HOME/.claude/script-usage.log" || true

print_help() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; n = 1; next } { exit } END { exit(n ? 0 : 1) }' "$0" ||
    { printf '%s: --help header extraction produced no output\n' "$0" >&2; exit 70; }
}

die_usage() {
  echo "candidate-ownership.sh: $1" >&2
  echo "Run with --help for usage." >&2
  exit 2
}

# --- arg parsing ---------------------------------------------------------------
CANDIDATES=()
REPO=""
JSON=0
HOLDER_ARG=""
SESSIONS_ARG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) print_help; exit 0 ;;
    --json) JSON=1; shift ;;
    --repo)
      [[ $# -lt 2 || -z "${2-}" ]] && die_usage "--repo requires a value (owner/repo)"
      REPO="$2"; shift 2 ;;
    --repo=*)
      REPO="${1#--repo=}"
      [[ -z "$REPO" ]] && die_usage "--repo requires a value (owner/repo)"
      shift ;;
    --holder)
      [[ $# -lt 2 || -z "${2-}" ]] && die_usage "--holder requires a value"
      HOLDER_ARG="$2"; shift 2 ;;
    --holder=*)
      HOLDER_ARG="${1#--holder=}"
      [[ -z "$HOLDER_ARG" ]] && die_usage "--holder requires a value"
      shift ;;
    --sessions)
      [[ $# -lt 2 || -z "${2-}" ]] && die_usage "--sessions requires a path or -"
      SESSIONS_ARG="$2"; shift 2 ;;
    --sessions=*)
      SESSIONS_ARG="${1#--sessions=}"
      [[ -z "$SESSIONS_ARG" ]] && die_usage "--sessions requires a path or -"
      shift ;;
    --) shift; break ;;
    -*) die_usage "unknown flag: $1" ;;
    *) CANDIDATES+=("$1"); shift ;;
  esac
done
while [[ $# -gt 0 ]]; do CANDIDATES+=("$1"); shift; done

[[ ${#CANDIDATES[@]} -eq 0 ]] && die_usage "at least one <issue> number is required"
for n in "${CANDIDATES[@]}"; do
  [[ "$n" =~ ^[1-9][0-9]*$ ]] || die_usage "<issue> must be a positive integer, got: $n"
done
if [[ -n "$REPO" ]] && ! [[ "$REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
  die_usage "--repo must be owner/repo, got: $REPO"
fi

command -v jq >/dev/null 2>&1 || die_usage "'jq' not found on PATH"

# Dedupe while preserving the caller's order — a repeated candidate would emit
# two contradictory-looking lines for one issue.
UNIQ=()
for n in "${CANDIDATES[@]}"; do
  seen=0
  for u in ${UNIQ[@]+"${UNIQ[@]}"}; do [[ "$u" == "$n" ]] && { seen=1; break; }; done
  (( seen )) || UNIQ+=("$n")
done
CANDIDATES=(${UNIQ[@]+"${UNIQ[@]}"})

# --- sibling-script resolution (portable-skill-resolution.md ladder) -----------
resolve_script() {
  local name="$1" candidate
  for candidate in \
    ${CANDIDATE_OWNERSHIP_SCRIPT_DIR:+"$CANDIDATE_OWNERSHIP_SCRIPT_DIR/$name"} \
    "$HOME/.claude/skills-worktree/.claude/scripts/$name" \
    "$HOME/.claude/scripts/$name" \
    ".claude/scripts/$name"; do
    [[ -x "$candidate" ]] && { printf '%s' "$candidate"; return 0; }
  done
  return 1
}

ISSUE_CLAIM_SH="$(resolve_script issue-claim.sh || true)"
SESSION_STATE_SH="$(resolve_script session-state.sh || true)"
ACTIVE_WORK_CAP_SH="$(resolve_script active-work-cap.sh || true)"

HANDOFF_DIR="${CLAUDE_HANDOFF_DIR:-$HOME/.claude/handoffs}"

# --- holder / self identity ----------------------------------------------------
resolve_holder() {
  [[ -n "$HOLDER_ARG" ]] && { printf '%s' "$HOLDER_ARG"; return; }
  [[ -n "${CLAUDE_CLAIM_HOLDER:-}" ]] && { printf '%s' "$CLAUDE_CLAIM_HOLDER"; return; }
  [[ -n "${CLAUDE_SESSION_ID:-}" ]] && { printf '%s' "$CLAUDE_SESSION_ID"; return; }
  local host top
  host="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo unknown-host)"
  top="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  printf '%s:%s' "$host" "$top"
}
HOLDER="$(resolve_holder)"
SELF_SESSION="${CLAUDE_SESSION_ID:-}"

# --- repo key ------------------------------------------------------------------
# Batch-level degradation entries are appended to EVERY candidate's degraded[],
# because a source that could not be read was not read for any of them.
BATCH_DEGRADED=()
batch_degrade() {
  local d
  for d in ${BATCH_DEGRADED[@]+"${BATCH_DEGRADED[@]}"}; do [[ "$d" == "$1" ]] && return 0; done
  BATCH_DEGRADED+=("$1")
}

REPO_KEY="$REPO"
if [[ -z "$REPO_KEY" ]]; then
  REPO_KEY="${CLAUDE_SESSION_REPO:-}"
fi
if [[ -z "$REPO_KEY" ]] && command -v gh >/dev/null 2>&1; then
  REPO_KEY="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)"
fi
if [[ -n "$REPO_KEY" ]]; then
  REPO_KEY="$(printf '%s' "$REPO_KEY" | tr '[:upper:]' '[:lower:]')"
else
  batch_degrade "repo-key: could not resolve owner/repo (PR, handoff, and repo-scoped state reads skipped)"
fi

# Point `gh` at the SAME repo the state and handoff paths use, however the key
# was resolved. Exporting only for an explicit --repo would let a session whose
# $CLAUDE_SESSION_REPO differs from the checkout read PRs from one repo and
# ownership state from another — a cross-repo mismatch that reads as clean.
if [[ "$REPO_KEY" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
  export GH_REPO="$REPO_KEY"
fi

# --- session listing (liveness) -------------------------------------------------
SESSIONS_JSON=""
SESSIONS_AVAILABLE=0
SESSIONS_SRC="${SESSIONS_ARG:-${CLAUDE_SESSION_LISTING:-}}"
if [[ -n "$SESSIONS_SRC" ]]; then
  RAW_SESSIONS=""
  READ_OK=1
  if [[ "$SESSIONS_SRC" == "-" ]]; then
    RAW_SESSIONS="$(cat 2>/dev/null)" || READ_OK=0
  elif [[ -r "$SESSIONS_SRC" ]]; then
    RAW_SESSIONS="$(cat "$SESSIONS_SRC" 2>/dev/null)" || READ_OK=0
  else
    READ_OK=0
  fi
  if (( READ_OK )) && [[ -n "$RAW_SESSIONS" ]]; then
    # Normalize every accepted shape into [{id, status, title}].
    SESSIONS_JSON="$(printf '%s' "$RAW_SESSIONS" | jq -c '
      (if type == "array" then .
       elif type == "object" then (.sessions // .data // .results // [])
       else [] end)
      | map(select(type == "object"))
      | map({ id:     ((.id // .session_id // .sessionId // .uuid // "") | tostring),
              status: ((.status // .state // "") | tostring | ascii_downcase),
              title:  ((.title // .name // .summary // "") | tostring) })
      | map(select(.id != ""))' 2>/dev/null || true)"
    if [[ -n "$SESSIONS_JSON" ]]; then
      SESSIONS_AVAILABLE=1
    else
      batch_degrade "sessions: $SESSIONS_SRC is not parseable session listing JSON (liveness indeterminate -> owners treated as live)"
    fi
  else
    batch_degrade "sessions: could not read $SESSIONS_SRC (liveness indeterminate -> owners treated as live)"
  fi
fi

# A claim's `claimant_holder` is whatever token the claiming thread resolved,
# and `resolve_holder`'s documented last resort is `<hostname>:<worktree path>`.
# That is not a session id and will never appear in a session listing — so
# looking it up returns `__absent__`, which this script reads as `dead`, the one
# classification that adopts. Absence is only evidence of death for something
# that could have been present: a token carrying `:` or `/` is holder-shaped, and
# its liveness is simply unknown.
looks_like_session_id() {
  local tok="$1"
  [[ -z "$tok" ]] && return 1
  case "$tok" in
    *:*|*/*) return 1 ;;
    *) return 0 ;;
  esac
}

# session_status <session_id> -> live | dead | indeterminate
session_status() {
  local sid="$1"
  [[ -z "$sid" ]] && { printf 'indeterminate'; return; }
  looks_like_session_id "$sid" || { printf 'indeterminate'; return; }
  (( SESSIONS_AVAILABLE )) || { printf 'indeterminate'; return; }
  local st
  st="$(printf '%s' "$SESSIONS_JSON" | jq -r --arg id "$sid" \
    'map(select(.id == $id)) | if length == 0 then "__absent__" else .[0].status end' 2>/dev/null || printf '__err__')"
  case "$st" in
    __err__) printf 'indeterminate' ;;
    # Absent from a listing we could read is the archived/dead case (AC #1431).
    __absent__) printf 'dead' ;;
    archived|deleted|closed|ended|dead|terminated|gone|expired) printf 'dead' ;;
    open|active|running|paused|idle|live|suspended|waiting) printf 'live' ;;
    # A status word this script does not recognize is not evidence of death.
    *) printf 'live' ;;
  esac
}

session_title() {
  local sid="$1"
  [[ -z "$sid" ]] && return 0
  (( SESSIONS_AVAILABLE )) || return 0
  printf '%s' "$SESSIONS_JSON" | jq -r --arg id "$sid" \
    'map(select(.id == $id)) | if length == 0 then "" else .[0].title end' 2>/dev/null || true
}

# --- batched pre-pass: one read each, shared by every candidate ------------------

# (1) The `in-progress` label index — /wave's batching pattern. Advisory only:
#     a candidate outside it still gets its full per-issue read, because the
#     label is only one of several ownership signals.
LABELED_NUMS=""
if command -v gh >/dev/null 2>&1; then
  if ! LABELED_NUMS="$(gh issue list --label in-progress --state open --limit 100 \
        --json number --jq '.[].number' 2>/dev/null)"; then
    LABELED_NUMS=""
    batch_degrade "gh issue list --label in-progress: unreadable (claim index unavailable)"
  fi
else
  batch_degrade "gh: not on PATH (claim index, open-PR, and branch reads unavailable)"
fi

# (2) active-work-cap.sh offered_issue_nums — a cheap first-pass filter that
#     explains why an issue is already spoken for. Evidence, never a verdict.
OFFERED_NUMS=""
if [[ -n "$ACTIVE_WORK_CAP_SH" ]]; then
  AWC_JSON="$("$ACTIVE_WORK_CAP_SH" --json 2>/dev/null || true)"
  if [[ -n "$AWC_JSON" ]]; then
    OFFERED_NUMS="$(printf '%s' "$AWC_JSON" | jq -r '.offered_issue_nums[]?' 2>/dev/null || true)"
  else
    batch_degrade "active-work-cap.sh --json: unreadable (offered-work filter unavailable)"
  fi
fi

# (3) Open PRs and their closing refs — one call, not one per candidate.
OPEN_PRS_JSON="[]"
if command -v gh >/dev/null 2>&1; then
  if ! OPEN_PRS_JSON="$(gh pr list --state open --limit 100 \
        --json number,title,body,headRefName,url,author 2>/dev/null)"; then
    OPEN_PRS_JSON="[]"
    batch_degrade "gh pr list: unreadable (linked-PR evidence unavailable)"
  fi
  [[ -z "$OPEN_PRS_JSON" ]] && OPEN_PRS_JSON="[]"
fi

# (4) Session state — read each block explicitly. `.pause`, `.day`, `.resume`,
#     and `.execution_pauses` are INVISIBLE to --session-view, so an armed pause
#     reads as absent unless it is fetched by path (handoff-files.md).
# Sets SS_VALUE rather than echoing: a `$(...)` capture would run this in a
# SUBSHELL, and every batch_degrade it recorded would be discarded with that
# subshell — an unreadable state file would then degrade to complete silence,
# which is the one failure mode the degradation contract exists to prevent.
SS_VALUE=""
_ss_read() { # _ss_read <flag> <jq-path> <degrade-label> -> SS_VALUE, rc 0 on a usable read
  local flag="$1" path="$2" label="$3" rc=0
  SS_VALUE=""
  [[ -z "$SESSION_STATE_SH" ]] && return 1
  SS_VALUE="$("$SESSION_STATE_SH" "$flag" "$path" 2>/dev/null)" || rc=$?
  case "$rc" in
    0) return 0 ;;
    # 3 = no state file has ever been written. Legitimately empty, not a failure.
    3) SS_VALUE=""; return 1 ;;
    *) SS_VALUE=""
       batch_degrade "session-state.sh $flag $label: rc=$rc (that source not consulted)"
       return 1 ;;
  esac
}
ss_get() { # ss_get <jq-path> <degrade-label> -> SS_VALUE, rc 0 on a usable read
  _ss_read --get "$1" "$2"
}
# Pause slots only (issue #1629). `--get` prints raw, so a slot holding the
# JSON STRING "null" arrives as the four characters `null` — indistinguishable
# from an absent slot, and therefore read as "nothing parked": exactly the
# masking the per-slot degradation contract exists to stop. `--get-json` keeps
# the value's JSON type, so that slot arrives as `"null"`, is not a record map,
# and `slot_class` names it `unreadable`. Same guards, same exit codes, same
# rc mapping — only the wire format differs. The non-pause reads below stay on
# `--get`: their consumers want the raw scalar.
ss_get_json() { # ss_get_json <jq-path> <degrade-label> -> SS_VALUE
  _ss_read --get-json "$1" "$2"
}

PAUSE_JSON=""
PAUSES_MAP_JSON=""
PAUSE_LEGACY_JSON=""
SUSPEND_LEGACY_JSON=""
BG_TASKS_JSON=""
EXEC_PAUSES_JSON=""
PMM_ACTIVE=""
PMM_JSON=""
if [[ -z "$SESSION_STATE_SH" ]]; then
  batch_degrade "session-state.sh: not found (parked, background-task, and fleet evidence unavailable)"
else
  if [[ -n "$REPO_KEY" ]]; then
    # Pause records are keyed per session at .pauses[<session>] (issue #1576).
    # The pre-#1576 singleton `.pause` and the pre-#1310 `.suspend` slot are read
    # alongside it as UNION members, not as a fallback that fires only when the
    # map is empty: an else-branch would make a board parked before either rename
    # invisible the moment any session wrote a keyed record — the same masking
    # bug #1576 removed one level up.
    # Read with `--get-json` (issue #1629), so the value keeps its JSON type and
    # the combine can tell an absent slot from a corrupt one. On a usable read
    # the value is kept VERBATIM: a slot holding `""` arrives as `""` and one
    # holding the string "null" arrives as `"null"` — both damaged, both of
    # which the combine has to see rather than mistake for absent. A failed read
    # is already named by ss_get_json, so it is handed the literal `null`
    # instead of being classified a second time (issue #1611).
    if ss_get_json ".repos[\"$REPO_KEY\"].pauses" "pauses"; then
      PAUSES_MAP_JSON="$SS_VALUE"; else PAUSES_MAP_JSON="null"; fi
    if ss_get_json ".repos[\"$REPO_KEY\"].pause" "pause (legacy)"; then
      PAUSE_LEGACY_JSON="$SS_VALUE"; else PAUSE_LEGACY_JSON="null"; fi
    if ss_get_json ".repos[\"$REPO_KEY\"].suspend" "suspend (legacy)"; then
      SUSPEND_LEGACY_JSON="$SS_VALUE"; else SUSPEND_LEGACY_JSON="null"; fi
    # Each of the three slots is classified on its OWN in the combine below
    # (issue #1611), so a corrupt one is named alone and the healthy ones still
    # contribute. Nothing is pre-checked or cleared here: a shell-side check for
    # `pauses` only, with the legacy slots left to a raise inside the combine,
    # is exactly the asymmetry that made one damaged singleton discard every
    # keyed record read alongside it.
    ss_get ".repos[\"$REPO_KEY\"].background_tasks" "background_tasks" || true
    BG_TASKS_JSON="$SS_VALUE"
    # execution-pause.sh writes ONLY to .repos[<key>].execution_pauses[<session>];
    # session-state.sh rewrites just `.prs` / `.root_repo` into repo scope, so a
    # top-level `.execution_pauses` read finds nothing and every /end or /pause
    # launch gate is invisible to the sweep.
    ss_get ".repos[\"$REPO_KEY\"].execution_pauses" "execution_pauses" || true
    EXEC_PAUSES_JSON="$SS_VALUE"
  else
    batch_degrade "execution_pauses: no repo key (repo-scoped launch-gate evidence not consulted)"
  fi
  ss_get '.pmm_active' "pmm_active" || true
  PMM_ACTIVE="$SS_VALUE"
  ss_get '.pmm' "pmm" || true
  PMM_JSON="$SS_VALUE"
fi

json_or_null() { # a `--get` on a missing path prints "null"; normalize both
  local v="$1"
  [[ -z "$v" || "$v" == "null" ]] && { printf 'null'; return; }
  if printf '%s' "$v" | jq -e . >/dev/null 2>&1; then printf '%s' "$v"; else printf 'null'; fi
}
# A pause slot that READ successfully (rc=0) but holds text that is not JSON is
# a DAMAGED slot, not an absent one. `json_or_null` coerces it to `null`, which
# `slot_class` would then call `absent` — a corrupt board read as "nothing
# parked", the exact masking this degradation contract exists to prevent. Hand
# the raw text through as a JSON STRING instead: a string is neither a record nor
# a map, so slot_class already classifies it `unreadable` and the slot is named.
# Its input is `--get-json` output (issue #1629), so the bare text `null` is now
# unambiguously JSON null, and a slot corrupted into the STRING "null" arrives
# quoted as `"null"` — valid JSON, passed straight through, classified
# `unreadable` by slot_class. Under the old raw `--get` the two were the same
# four characters and the corrupt slot was read as absent.
pause_slot_arg() {
  local v="$1"
  # The literal `null` is the ONLY absent value. An EMPTY value cannot come from
  # a successful --get-json read (every JSON value prints something), so it means
  # the read produced nothing at all — damaged, and it must reach slot_class as a
  # string so it is named, not coerced to `null` and reported as "nothing parked".
  [[ "$v" == "null" ]] && { printf 'null'; return; }
  if printf '%s' "$v" | jq -e . >/dev/null 2>&1; then printf '%s' "$v"
  else jq -Rn --arg v "$v" '$v'; fi
}
# PAUSE_JSON is an ARRAY of un-resumed pause records (issue #1576), never one
# block: a repo can hold several, and a sibling's `active: false` is not evidence
# that nothing else is parked. Records that are already resumed are dropped here,
# so downstream code no longer re-checks `.active` per block.
#
# Each of the three sources is validated on its OWN before the combine (issue
# #1611) and the program returns both the surviving records and the names of the
# damaged slots. It never raises: a raise aborts the whole program, so one
# damaged legacy singleton used to discard every healthy keyed record read
# beside it and this sweep then drew no parked-unit evidence at all.
PAUSE_COMBINED="$(jq -nc \
  --argjson pauses "$(pause_slot_arg "$PAUSES_MAP_JSON")" \
  --argjson legacy_pause "$(pause_slot_arg "$PAUSE_LEGACY_JSON")" \
  --argjson legacy_suspend "$(pause_slot_arg "$SUSPEND_LEGACY_JSON")" '
  # ---- one slot, one verdict (issue #1611) -----------------------------------
  # Classify a single pause source on its OWN: `absent` (null), `present` (the
  # shape that slot holds), or `unreadable` (anything else). The session-keyed
  # map and the legacy singletons take the SAME rule — only `$kind` differs,
  # because only the shape differs — so a corrupt map is named exactly the way a
  # corrupt singleton is, and neither is ever read as "nothing parked".
  # This definition is identical in /pause-resume Step 1, /go-on probe B, and
  # here; pause-multisession.test.sh extracts all three and fails if they drift.
  def slot_class($kind):
    if type == "null" then "absent"
    elif $kind == "map"
      then (if type == "object" and (to_entries | all(.value | type == "object"))
            then "present" else "unreadable" end)
    elif type == "object" then "present"
    else "unreadable" end;
  # A damaged slot names itself and nothing else. The caller degrades exactly
  # the slots listed here, so every surviving slot still contributes.
  def slot_degraded($name; $kind):
    if slot_class($kind) == "unreadable" then [$name] else [] end;
  # ---- end shared per-slot validation ----------------------------------------
  # ONE un-resumed predicate across every reader (pause-resume Step 1, go-on
  # probe B, here). It must match /pause-resume exactly: a record it would still
  # restore is a record this sweep must still call parked.
  #   - NOT `.active // true`: jq treats false as empty, so that expression
  #     returns true for exactly the resumed records it should exclude.
  #   - A record closed with re-arms still outstanding is PARTIALLY restored;
  #     /pause-resume re-selects it, so it is parked work here too.
  #   - A malformed array must not throw and lose the whole selection.
  #   - A missing `active` counts as active — this sweep fails toward surfacing.
  def pend($a): ($a | if type == "array"
                      then map(select((type != "object") or ((.rearmed // false) != true))) | length
                      else 0 end);
  def unresumed: (.active != false)
                 or ((pend(.monitors_stopped) + pend(.background_tasks_stopped)) > 0);
  # Only a `present` slot contributes records; a damaged one contributes none
  # and is reported by name instead.
  def slot_records($kind):
    if slot_class($kind) != "present" then []
    elif $kind == "map" then (to_entries | map(.value))
    else [.] end;
  { records: ( ($pauses         | slot_records("map"))
             + ($legacy_pause   | slot_records("slot"))
             + ($legacy_suspend | slot_records("slot"))
             | map(select(unresumed)) ),
    degraded: ( ($pauses         | slot_degraded("pauses"; "map"))
              + ($legacy_pause   | slot_degraded("pause (legacy)"; "slot"))
              + ($legacy_suspend | slot_degraded("suspend (legacy)"; "slot")) ) }' 2>/dev/null)" \
  || PAUSE_COMBINED=""
if [[ -z "$PAUSE_COMBINED" ]]; then
  PAUSE_JSON="null"
  batch_degrade "pause records: could not be combined (parked-unit evidence not consulted)"
else
  # Name each damaged slot on its own line. Every slot NOT named here was read
  # and did contribute, so a candidate owned by a healthy record is still
  # reported as owned even while a sibling slot is corrupt.
  while IFS= read -r _damaged_slot; do
    [[ -n "$_damaged_slot" ]] || continue
    batch_degrade "$_damaged_slot: not a pause record, or holds a malformed record (that slot alone was not consulted; the other pause sources still were)"
  done < <(printf '%s' "$PAUSE_COMBINED" | jq -r '.degraded[]?' 2>/dev/null)
  PAUSE_JSON="$(printf '%s' "$PAUSE_COMBINED" | jq -c '.records' 2>/dev/null)" || PAUSE_JSON=""
  [[ -n "$PAUSE_JSON" ]] || {
    PAUSE_JSON="null"
    batch_degrade "pause records: could not be combined (parked-unit evidence not consulted)"
  }
fi
BG_TASKS_JSON="$(json_or_null "$BG_TASKS_JSON")"
EXEC_PAUSES_JSON="$(json_or_null "$EXEC_PAUSES_JSON")"
PMM_JSON="$(json_or_null "$PMM_JSON")"

# The paused PR fleet: `.pmm_active` false with `.pmm.paused_at` set.
FLEET_PAUSED=0
FLEET_PRS=""
if [[ "$PMM_ACTIVE" != "true" && "$PMM_JSON" != "null" ]]; then
  if [[ -n "$(printf '%s' "$PMM_JSON" | jq -r '.paused_at // empty' 2>/dev/null)" ]]; then
    FLEET_PAUSED=1
    FLEET_PRS="$(printf '%s' "$PMM_JSON" | jq -r '
      (.fleet_at_pause // []) | .[]? | if type == "object" then (.pr // .number // empty) else . end' 2>/dev/null || true)"
  fi
fi

# marker_parse <path> <basename> -> sets MP_REPO and MP_SESSION (either may be
# empty, meaning "this marker does not say").
#
# Marker names are `pause-<stamp>-<REPO_KEY_SAFE>-<session>-<tag>[-draft].md`,
# where REPO_KEY_SAFE is `<len-owner>-<owner>-<len-repo>-<repo>` — length-prefixed
# precisely because owners and repos may contain `-`, so splitting on dashes
# alone is ambiguous. Walking those lengths is what makes BOTH fields recoverable:
#   * repo, to refuse a marker belonging to another repository; and
#   * the session id, which is a UUID and keeps its own dashes. Reading it as a
#     single dash field returns only the UUID's last group, and a truncated id is
#     absent from the session listing — which this script reads as `dead`, the
#     one classification that adopts. A live paused thread would be resumed
#     underneath, which is the duplicate-ship failure this sweep exists to stop.
#
# Repo has a second, preferred source: the rendered ``Repository: `owner/repo` ``
# line. It is exact, and it is the only one `portable-handoff-*` has — those
# encode no repo in the filename at all. A `/`-less repo key writes the literal
# `unknown`, which attributes no repo but still carries a session id.
#
# Two globals rather than one delimited string: either field can legitimately be
# empty, and empty fields do not survive an `IFS` split intact.
MP_REPO=""
MP_SESSION=""
marker_parse() {
  local path="$1" base="$2" line owner name rest lo ln stripped
  MP_REPO=""
  MP_SESSION=""

  line="$(grep -m1 -E '^Repository:' "$path" 2>/dev/null || true)"
  if [[ -n "$line" ]]; then
    line="${line#Repository:}"
    line="${line//\`/}"
    # Trim surrounding whitespace without a subshell.
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    if [[ "$line" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
      MP_REPO="$(printf '%s' "$line" | tr '[:upper:]' '[:lower:]')"
    fi
  fi

  case "$base" in
    pause-*|suspend-*) ;;
    *) return 0 ;;
  esac
  stripped="${base%.md}"
  stripped="${stripped%-draft}"
  rest="${stripped#*-}"                 # drop `pause-` / `suspend-`
  rest="${rest#*-}"                     # drop <stamp>
  if [[ "$rest" == unknown-* ]]; then
    rest="${rest#unknown-}"
  else
    lo="${rest%%-*}"                    # <len-owner>
    [[ "$lo" =~ ^[0-9]+$ ]] || return 0
    rest="${rest#*-}"
    owner="${rest:0:$lo}"
    [[ ${#owner} -eq "$lo" ]] || return 0
    rest="${rest:$lo}"
    rest="${rest#-}"
    ln="${rest%%-*}"                    # <len-repo>
    [[ "$ln" =~ ^[0-9]+$ ]] || return 0
    rest="${rest#*-}"
    name="${rest:0:$ln}"
    [[ ${#name} -eq "$ln" ]] || return 0
    rest="${rest:$ln}"
    rest="${rest#-}"
    # The body line wins when both are present: it is the exact string /pause
    # rendered, not a reconstruction.
    if [[ -z "$MP_REPO" && -n "$owner" && -n "$name" ]]; then
      MP_REPO="$(printf '%s/%s' "$owner" "$name" | tr '[:upper:]' '[:lower:]')"
    fi
  fi
  # What remains is `<session>-<tag>`. The tag is mktemp's own suffix and carries
  # no dash, so everything before the LAST dash is the session id, dashes intact.
  [[ "$rest" == *-* ]] || return 0
  MP_SESSION="${rest%-*}"
}

# (5) Resume markers on disk. Read once; matched per candidate.
MARKER_FILES=()
if [[ -d "$HANDOFF_DIR" ]]; then
  while IFS= read -r f; do
    [[ -n "$f" ]] && MARKER_FILES+=("$f")
  done < <(find "$HANDOFF_DIR" -maxdepth 1 -type f \
             \( -name 'pause-*.md' -o -name 'suspend-*.md' -o -name 'portable-handoff-*.md' \) \
             ! -name '*-checkpoint.md' 2>/dev/null | sort || true)
fi

# --- per-candidate helpers ------------------------------------------------------

# Ownership accumulators, reset per candidate.
reset_candidate() {
  OWNED=0
  VERDICT="unowned"
  ACTION="dispatch"
  REASON=""
  STATE="none"
  LIVENESS="indeterminate"
  OWNER_LABEL=""
  OWNER_TITLE=""
  OWNER_FALLBACK=""
  OWNER_SESSION=""
  OWNER_SESSIONS=()
  RESUME_ROUTE=""
  EVIDENCE=()
  DEGRADED=()
  ADOPT_FROM=""
  ADOPT_PR=""
  ADOPT_BRANCH=""
  ADOPT_HANDOFF=""
  ADOPT_PHASE=""
  RESUMABLE=0
  FLEET_OWNED=0
}

add_evidence() { EVIDENCE+=("$1"); }
add_degraded() {
  local d
  for d in ${DEGRADED[@]+"${DEGRADED[@]}"}; do [[ "$d" == "$1" ]] && return 0; done
  DEGRADED+=("$1")
}

# Owner naming is a two-tier preference, not first-write-wins: a human-readable
# title beats a machine token however early the token was found. The final
# ranking is session-listing title > source-supplied title > claim-derived
# description > session id (issue #1431 "Notes / Open questions").
# The LABEL is first-write-wins by preference order, but every session id an
# evidence source attributes to this candidate is kept. Liveness is a question
# about the work, not about whichever source happened to run first: the claim
# gate always runs before markers, background tasks, and the fleet, so keeping
# only its session id let a claim whose session is absent (-> dead) outrank a
# marker naming a session that is demonstrably live, and adopt underneath it.
note_owner() { # note_owner <fallback-label> <session_id>
  [[ -z "$OWNER_FALLBACK" && -n "$1" ]] && OWNER_FALLBACK="$1"
  [[ -z "$OWNER_SESSION" && -n "$2" ]] && OWNER_SESSION="$2"
  if [[ -n "$2" ]]; then
    local s
    for s in ${OWNER_SESSIONS[@]+"${OWNER_SESSIONS[@]}"}; do
      [[ "$s" == "$2" ]] && return 0
    done
    OWNER_SESSIONS+=("$2")
  fi
  return 0
}

# Liveness over EVERY attributed session. One live session means the work is
# live; `dead` requires that something actually resolved dead and nothing
# resolved live. Anything else is indeterminate, which the caller treats as
# live — the direction that costs a surfaced line instead of a duplicate.
owner_liveness() {
  local sid st saw_dead=0
  for sid in ${OWNER_SESSIONS[@]+"${OWNER_SESSIONS[@]}"}; do
    st="$(session_status "$sid")"
    [[ "$st" == "live" ]] && { printf 'live'; return; }
    [[ "$st" == "dead" ]] && saw_dead=1
  done
  (( saw_dead )) && { printf 'dead'; return; }
  printf 'indeterminate'
}
note_title() { # note_title <human-readable title>
  [[ -z "$OWNER_TITLE" && -n "$1" ]] && OWNER_TITLE="$1"
  return 0
}

# `paused` > `active` > `stale`. Explicit parked state outranks an inference of
# activity, the same precedence `/go-on` uses (`universal-resume.md`): a fresh
# claim only says the claim is recent, which is exactly what a thread parked
# twenty minutes ago also looks like, while a `/pause` record is a deliberate
# statement that the thread stopped. Reporting that thread as `active` would
# send the user looking for work that is not running.
note_state() {
  case "$1" in
    paused) STATE="paused" ;;
    active) [[ "$STATE" == "paused" ]] || STATE="active" ;;
    stale)  [[ "$STATE" == "none" ]] && STATE="stale" ;;
  esac
  return 0
}

is_self() { # is_self <holder-or-session-token>
  local tok="$1"
  [[ -z "$tok" ]] && return 1
  [[ "$tok" == "$HOLDER" ]] && return 0
  [[ -n "$SELF_SESSION" && "$tok" == "$SELF_SESSION" ]] && return 0
  return 1
}

# Elements are passed as jq positional args rather than newline-joined text: an
# evidence string carrying a newline (a `stopped_at` copied from a marker, say)
# would otherwise be split into two array entries.
json_array() { # json_array <element>... -> compact JSON array of strings
  if [[ $# -eq 0 ]]; then printf '[]'; return; fi
  jq -cn '$ARGS.positional' --args "$@"
}

emit_candidate() {
  local issue="$1"
  local evidence_json degraded_json adopt_json
  evidence_json="$(json_array ${EVIDENCE[@]+"${EVIDENCE[@]}"})"
  degraded_json="$(json_array ${DEGRADED[@]+"${DEGRADED[@]}"})"
  adopt_json="$(jq -cn \
    --arg from "$ADOPT_FROM" --arg pr "$ADOPT_PR" --arg branch "$ADOPT_BRANCH" \
    --arg handoff "$ADOPT_HANDOFF" --arg phase "$ADOPT_PHASE" \
    '{from:   (if $from   == "" then null else $from end),
      pr:     (if $pr     == "" then null else ($pr | tonumber) end),
      branch: (if $branch == "" then null else $branch end),
      handoff_path: (if $handoff == "" then null else $handoff end),
      phase:  (if $phase  == "" then null else $phase end)}')"

  if (( JSON )); then
    jq -cn \
      --argjson issue "$issue" \
      --argjson owned "$( ((OWNED)) && echo true || echo false )" \
      --arg verdict "$VERDICT" \
      --arg action "$ACTION" \
      --arg reason "$REASON" \
      --arg state "$STATE" \
      --arg liveness "$LIVENESS" \
      --arg owner_label "$OWNER_LABEL" \
      --arg owner_session_id "$OWNER_SESSION" \
      --arg resume_route "$RESUME_ROUTE" \
      --arg claim_verdict "$CLAIM_VERDICT" \
      --argjson adopt "$adopt_json" \
      --argjson evidence "$evidence_json" \
      --argjson degraded "$degraded_json" \
      '{issue: $issue, owned: $owned, verdict: $verdict, action: $action,
        reason: $reason, state: $state, liveness: $liveness,
        owner_label: (if $owner_label == "" then null else $owner_label end),
        owner_session_id: (if $owner_session_id == "" then null else $owner_session_id end),
        resume_route: (if $resume_route == "" then null else $resume_route end),
        claim_verdict: $claim_verdict,
        adopt: $adopt, evidence: $evidence, degraded: $degraded}'
  else
    printf '#%s %s verdict=%s state=%s liveness=%s owner=%s route=%s\n' \
      "$issue" "$ACTION" "$VERDICT" "$STATE" "$LIVENESS" \
      "${OWNER_LABEL:-none}" "${RESUME_ROUTE:-none}"
    if [[ ${#DEGRADED[@]} -gt 0 ]]; then
      local joined
      joined="$(printf '%s; ' "${DEGRADED[@]}")"
      printf '#%s degraded: %s\n' "$issue" "${joined%; }"
    fi
  fi
}

# --- the sweep ------------------------------------------------------------------
for ISSUE in "${CANDIDATES[@]}"; do
  reset_candidate
  for d in ${BATCH_DEGRADED[@]+"${BATCH_DEGRADED[@]}"}; do add_degraded "$d"; done

  # -- claim gate ---------------------------------------------------------------
  CLAIM_VERDICT="unavailable"
  CLAIM_HOLDER=""
  CLAIM_LOGIN=""
  if [[ -z "$ISSUE_CLAIM_SH" ]]; then
    add_degraded "issue-claim.sh: not found (claim gate unavailable for #$ISSUE)"
  else
    CLAIM_ARGS=("$ISSUE" --check --json --holder "$HOLDER")
    [[ -n "$REPO" ]] && CLAIM_ARGS+=(--repo "$REPO")
    CLAIM_RC=0
    CLAIM_JSON="$("$ISSUE_CLAIM_SH" "${CLAIM_ARGS[@]}" 2>/dev/null)" || CLAIM_RC=$?
    if [[ -n "$CLAIM_JSON" ]] && printf '%s' "$CLAIM_JSON" | jq -e . >/dev/null 2>&1; then
      CLAIM_VERDICT="$(printf '%s' "$CLAIM_JSON" | jq -r '.verdict // "unavailable"')"
      CLAIM_HOLDER="$(printf '%s' "$CLAIM_JSON" | jq -r '.claimant_holder // ""')"
      CLAIM_LOGIN="$(printf '%s' "$CLAIM_JSON" | jq -r '.claimant // ""')"
    else
      add_degraded "issue-claim.sh --check: unparseable output (rc=$CLAIM_RC) for #$ISSUE"
    fi
  fi

  # Decide self-attribution BEFORE the claim can confer ownership. `mine` is the
  # gate's own verdict; `is_self` additionally catches a claim this thread wrote
  # under a different token than the one `resolve_holder` produces now (a session
  # id where the holder is `CLAUDE_CLAIM_HOLDER`, or vice versa). Appending
  # "held by this thread" AFTER setting OWNED left the flag standing, so a thread
  # skipped its own claimed work as if a stranger held it.
  CLAIM_IS_SELF=0
  if [[ "$CLAIM_VERDICT" == "mine" ]] || is_self "$CLAIM_HOLDER"; then
    CLAIM_IS_SELF=1
  fi

  if (( CLAIM_IS_SELF )); then
    add_evidence "claim: held by this thread — not foreign ownership"
  else
    case "$CLAIM_VERDICT" in
      claimed)
        OWNED=1
        note_state active
        add_evidence "claim: fresh claim held by ${CLAIM_LOGIN:-another account} (holder ${CLAIM_HOLDER:-unknown})"
        note_owner "${CLAIM_LOGIN:+$CLAIM_LOGIN }thread ${CLAIM_HOLDER:-unknown}" "$CLAIM_HOLDER"
        ;;
      stale)
        # Not owned yet — the owned-resumable upgrade below decides.
        note_state stale
        add_evidence "claim: stale claim by ${CLAIM_LOGIN:-another account} (holder ${CLAIM_HOLDER:-unknown})"
        note_owner "${CLAIM_LOGIN:+$CLAIM_LOGIN }thread ${CLAIM_HOLDER:-unknown}" "$CLAIM_HOLDER"
        ;;
      unknown)
        add_evidence "claim: state undetermined (issue-claim.sh fail-closed)"
        ;;
    esac
  fi

  if [[ -n "$LABELED_NUMS" ]] && grep -qx "$ISSUE" <<<"$LABELED_NUMS"; then
    add_evidence "in-progress label present on #$ISSUE"
  fi
  if [[ -n "$OFFERED_NUMS" ]] && grep -qx "$ISSUE" <<<"$OFFERED_NUMS"; then
    add_evidence "active-work-cap: #$ISSUE is already offered work"
  fi

  # -- linked open PR ------------------------------------------------------------
  LINKED_PR=""
  LINKED_BRANCH=""
  if [[ "$OPEN_PRS_JSON" != "[]" ]]; then
    # Closing-keyword shape mirrors pr-issue-ref.sh, plus GitHub's optional
    # colon: `Closes #1`, `Closes#1`, `Closes: #1`, `Closes:#1` all count.
    # A qualified `owner/repo#N` counts ONLY when the owner/repo is this repo —
    # an arbitrary prefix would link a PR that closes someone else's issue #N.
    # With no resolved repo key the prefix cannot be verified, so only the bare
    # form is accepted.
    PR_RC=0
    PR_MATCH="$(printf '%s' "$OPEN_PRS_JSON" | jq -c --arg n "$ISSUE" --arg repo "$REPO_KEY" '
      (if $repo == "" then "" else "(" + ($repo | gsub("\\."; "\\.")) + ")?" end) as $prefix
      | [ .[]? | select((.body // "")
          | test("(?i)(^|[^A-Za-z0-9_])(close[sd]?|fix(e[sd])?|resolve[sd]?)\\s*:?\\s*"
                 + $prefix + "#" + $n + "\\b")) ]
      | if length == 0 then null else .[0] end' 2>/dev/null)" || PR_RC=$?
    if (( PR_RC != 0 )); then
      add_degraded "open-PR closing-ref scan failed (jq rc=$PR_RC) — linked-PR evidence not consulted for #$ISSUE"
      PR_MATCH="null"
    fi
    if [[ -n "$PR_MATCH" && "$PR_MATCH" != "null" ]]; then
      LINKED_PR="$(printf '%s' "$PR_MATCH" | jq -r '.number // ""')"
      LINKED_BRANCH="$(printf '%s' "$PR_MATCH" | jq -r '.headRefName // ""')"
      add_evidence "open PR #$LINKED_PR closes #$ISSUE (branch ${LINKED_BRANCH:-unknown})"
      RESUMABLE=1
      ADOPT_FROM="pr"; ADOPT_PR="$LINKED_PR"; ADOPT_BRANCH="$LINKED_BRANCH"
    fi
  fi

  # -- handoff file for the linked PR --------------------------------------------
  if [[ -n "$LINKED_PR" && -n "$REPO_KEY" && "$REPO_KEY" == */* ]]; then
    HF="$HANDOFF_DIR/${REPO_KEY%%/*}/${REPO_KEY#*/}/pr-$LINKED_PR-handoff.json"
    if [[ -f "$HF" ]]; then
      if jq -e . "$HF" >/dev/null 2>&1; then
        ADOPT_HANDOFF="$HF"
        RESUMABLE=1
        PHASE_DONE="$(jq -r '.phase_completed // ""' "$HF" 2>/dev/null || true)"
        add_evidence "handoff file for PR #$LINKED_PR (phase_completed=${PHASE_DONE:-unknown})"
        case "$PHASE_DONE" in
          A) ADOPT_PHASE="b" ;;
          B) ADOPT_PHASE="c" ;;
          C) ADOPT_PHASE="c" ;;
          *) ADOPT_PHASE="b" ;;
        esac
      else
        # Corrupt handoff: named, and it does NOT become ownership on its own.
        add_degraded "handoff file $HF is unreadable or not valid JSON"
      fi
    fi
  fi
  # An open PR with no handoff still resumes — at the review lane, not Phase A.
  [[ -n "$LINKED_PR" && -z "$ADOPT_PHASE" ]] && ADOPT_PHASE="b"

  # -- parked units across every un-resumed pause record --------------------------
  # PAUSE_JSON is already filtered to active records, so scan all of them: a match
  # in ANY session's board owns this issue. The matched record supplies its own
  # marker path — a repo-wide marker would name the wrong session's artifact.
  if [[ "$PAUSE_JSON" != "null" && "$PAUSE_JSON" != "[]" ]]; then
      PARK_RC=0
      PARK_COMBINED="$(printf '%s' "$PAUSE_JSON" | jq -r --arg n "$ISSUE" --arg pr "$LINKED_PR" '
        [ .[]?
          | . as $rec
          # `(.parked // [])[]?` would swallow a malformed `parked` and read it
          # as "nothing parked". Validate the type and raise instead, so PARK_RC
          # goes non-zero and the record is NAMED as degraded — an absent field
          # is still legitimately empty.
          | (if ($rec.parked | type) == "array" then $rec.parked[]
             elif $rec.parked == null then empty
             else error("parked is not an array") end)
          | select(
              ((.ref // "") | tostring) == $pr and $pr != ""
              or ((.branch // "") | test("issue-" + $n + "(\\D|$)"))
              or ((.issue // "") | tostring) == $n
              or ((.stopped_at // "") | test("#" + $n + "\\b"))
              or ((.next_move // "") | test("#" + $n + "\\b")) )
          | { unit: ((.kind // "unit") + " " + ((.ref // "?") | tostring)
                     + " — " + (.stopped_at // "parked")),
              marker: ($rec.marker_path // "") } ]
        | if length == 0 then "" else
            (.[0].unit + "\u001f" + .[0].marker)
          end' 2>/dev/null)" || PARK_RC=$?
      # An empty result is a legitimate no-match; a non-zero jq is a malformed
      # pause record, which must be named rather than read as "nothing parked".
      if (( PARK_RC != 0 )); then
        add_degraded "pause records are malformed (jq rc=$PARK_RC) — parked-unit evidence not consulted for #$ISSUE"
        PARK_COMBINED=""
      fi
      # Split on US rather than reading with IFS: a tab/IFS read collapses an
      # empty trailing field and shifts the rest, which is exactly the shape an
      # absent marker_path produces.
      PARK_HIT="${PARK_COMBINED%%$'\x1f'*}"
      if [[ -n "$PARK_HIT" ]]; then
        MARKER_PATH="${PARK_COMBINED#*$'\x1f'}"
        OWNED=1
        RESUMABLE=1
        note_state paused
        add_evidence "parked by /pause: $PARK_HIT"
        note_title "paused thread${MARKER_PATH:+ ($(basename "$MARKER_PATH"))}"
        [[ -z "$ADOPT_FROM" && -n "$LINKED_PR" ]] && { ADOPT_FROM="pr"; ADOPT_PR="$LINKED_PR"; }
      fi
  fi

  # -- background-task registry ---------------------------------------------------
  if [[ "$BG_TASKS_JSON" != "null" ]]; then
    BG_RC=0
    BG_HIT="$(printf '%s' "$BG_TASKS_JSON" | jq -c --arg n "$ISSUE" --arg pr "$LINKED_PR" '
      [ .[]?
        | select(((.work_item // "") | test("#" + $n + "\\b"))
                 or ((.name // "") | test("(^|\\D)" + $n + "(\\D|$)"))
                 or ((.recovery_path // "") | test("issue-" + $n + "(\\D|$)"))
                 or ($pr != "" and ((.name // "") | test("#?" + $pr + "(\\D|$)")))) ]
      | if length == 0 then null else .[0] end' 2>/dev/null)" || BG_RC=$?
    if (( BG_RC != 0 )); then
      add_degraded "background_tasks is malformed (jq rc=$BG_RC) — registry evidence not consulted for #$ISSUE"
      BG_HIT="null"
    fi
    if [[ -n "$BG_HIT" && "$BG_HIT" != "null" ]]; then
      BG_STATUS="$(printf '%s' "$BG_HIT" | jq -r '.status // ""')"
      BG_SESSION="$(printf '%s' "$BG_HIT" | jq -r '.session_id // ""')"
      BG_LABEL="$(printf '%s' "$BG_HIT" | jq -r '.name // .work_item // ""')"
      BG_RECOVERY="$(printf '%s' "$BG_HIT" | jq -r '.recovery_path // ""')"
      if is_self "$BG_SESSION"; then
        add_evidence "background task $BG_LABEL belongs to this session — not foreign ownership"
      else
        OWNED=1
        RESUMABLE=1
        add_evidence "background task ${BG_LABEL:-unnamed} (status ${BG_STATUS:-unknown}) owns #$ISSUE"
        note_title "$BG_LABEL"
        note_owner "$BG_LABEL" "$BG_SESSION"
        case "$BG_STATUS" in
          running|stopping|rearming|stop_failed) note_state active ;;
          stopped|abandoned|failed) note_state paused ;;
          *) note_state paused ;;
        esac
        if [[ -z "$ADOPT_FROM" && -n "$BG_RECOVERY" ]]; then
          ADOPT_FROM="branch"
          ADOPT_BRANCH="$(basename "$BG_RECOVERY")"
          ADOPT_PHASE="a"
        fi
      fi
    fi
  fi

  # -- execution pauses: a session-scoped launch gate ------------------------------
  # Not per-issue on its own — it qualifies an owner we already identified, and
  # it is what makes "paused thread" rather than "dead thread" the right reading.
  if [[ "$EXEC_PAUSES_JSON" != "null" && -n "$OWNER_SESSION" ]]; then
    EP_ACTIVE="$(printf '%s' "$EXEC_PAUSES_JSON" | jq -r --arg s "$OWNER_SESSION" \
      '(.[$s].active // false) | tostring' 2>/dev/null || printf 'false')"
    if [[ "$EP_ACTIVE" == "true" ]]; then
      EP_CMD="$(printf '%s' "$EXEC_PAUSES_JSON" | jq -r --arg s "$OWNER_SESSION" '.[$s].command // ""' 2>/dev/null || true)"
      add_evidence "execution pause active for session $OWNER_SESSION (${EP_CMD:-stopped})"
      note_state paused
      RESUMABLE=1
      OWNED=1
    fi
  fi

  # -- resume markers on disk ------------------------------------------------------
  for MF in ${MARKER_FILES[@]+"${MARKER_FILES[@]}"}; do
    MF_HIT=0
    if grep -qE "(^|[^0-9])#${ISSUE}([^0-9]|$)|issue-${ISSUE}([^0-9]|$)" "$MF" 2>/dev/null; then
      MF_HIT=1
    elif [[ -n "$LINKED_PR" ]] && grep -qE "(^|[^0-9])#${LINKED_PR}([^0-9]|$)" "$MF" 2>/dev/null; then
      MF_HIT=1
    fi
    (( MF_HIT )) || continue
    MF_BASE="$(basename "$MF")"
    # $HANDOFF_DIR is shared across repositories, and the match above is issue
    # or PR TEXT only — #1431 exists in every repo. Attribute the marker before
    # trusting it: a foreign marker that reaches `note_owner` can carry a dead
    # session id into the owned_dead branch and adopt another repo's work.
    marker_parse "$MF" "$MF_BASE"
    MF_REPO="$MP_REPO"
    if [[ -n "$MF_REPO" && -n "$REPO_KEY" ]] && [[ "$MF_REPO" != "$REPO_KEY" ]]; then
      continue
    fi
    # The session id comes out of the same length-prefixed walk, dashes intact —
    # a title is not in the name, so ids are the documented fallback label
    # (issue #1431 "Notes / Open questions").
    MF_SESSION="$MP_SESSION"
    if is_self "$MF_SESSION"; then
      add_evidence "resume marker $MF_BASE belongs to this session — not foreign ownership"
      continue
    fi
    OWNED=1
    RESUMABLE=1
    note_state paused
    if [[ -z "$MF_REPO" ]]; then
      # Unattributable: `unknown` in the name and no `Repository:` line. It may
      # be ours, so it still surfaces (fail toward surfacing) — but an owner
      # session that cannot be tied to THIS repo must not reach the liveness
      # lookup, where `dead` would turn a foreign marker into an adoption.
      add_evidence "resume marker $MF_BASE references #$ISSUE (repository unattributable — surfaced, not adoptable)"
      add_degraded "marker $MF_BASE: no repository attribution (owner session not consulted; candidate surfaced, never adopted)"
      note_title "$MF_BASE"
      note_owner "$MF_BASE" ""
      continue
    fi
    add_evidence "resume marker $MF_BASE references #$ISSUE"
    note_title "$MF_BASE"
    note_owner "$MF_BASE" "$MF_SESSION"
  done

  # -- paused PR fleet -------------------------------------------------------------
  if (( FLEET_PAUSED )) && [[ -n "$LINKED_PR" ]]; then
    if grep -qx "$LINKED_PR" <<<"$FLEET_PRS"; then
      OWNED=1
      FLEET_OWNED=1
      RESUMABLE=1
      note_state paused
      add_evidence "PR #$LINKED_PR is in the paused /pr-monitor-and-manage fleet"
      note_title "paused PR fleet"
      note_owner "paused PR fleet" ""
    fi
  fi

  # -- surviving branch (adoption source of last resort) ---------------------------
  if [[ -z "$ADOPT_FROM" ]] && command -v git >/dev/null 2>&1; then
    BR="$(git for-each-ref --format='%(refname:short)' refs/heads refs/remotes 2>/dev/null \
          | grep -E "(^|/)issue-${ISSUE}(-|$)" | head -n 1 || true)"
    if [[ -n "$BR" ]]; then
      add_evidence "surviving branch $BR"
      RESUMABLE=1
      ADOPT_FROM="branch"; ADOPT_BRANCH="$BR"; ADOPT_PHASE="a"
    fi
  fi

  # -- owned-resumable upgrade -----------------------------------------------------
  # A stale claim WITH resumable evidence is owned; a bare stale claim is not, so
  # today's warn-and-proceed is preserved exactly (issue #1431 AC).
  if [[ "$CLAIM_VERDICT" == "stale" ]]; then
    if (( RESUMABLE )); then
      OWNED=1
      add_evidence "owned-resumable upgrade: stale claim backed by surviving state"
    else
      add_evidence "bare stale claim, no resumable state — warn-and-proceed preserved"
    fi
  fi

  # -- liveness --------------------------------------------------------------------
  if (( OWNED )); then
    for OS in ${OWNER_SESSIONS[@]+"${OWNER_SESSIONS[@]}"}; do
      looks_like_session_id "$OS" || \
        add_degraded "owner token $OS is holder-shaped, not a session id (liveness indeterminate -> owner treated as live)"
    done
    LIVENESS="$(owner_liveness)"
    if [[ -n "$OWNER_SESSION" ]]; then
      T="$(session_title "$OWNER_SESSION")"
      # A title the listing supplies is the most human-readable name available,
      # so it outranks every token-derived label — including one found earlier.
      [[ -n "$T" ]] && OWNER_TITLE="$T"
    fi
    OWNER_LABEL="${OWNER_TITLE:-}"
    [[ -z "$OWNER_LABEL" ]] && OWNER_LABEL="$OWNER_FALLBACK"
    [[ -z "$OWNER_LABEL" ]] && OWNER_LABEL="${OWNER_SESSION:-an unnamed thread}"
    if (( FLEET_OWNED )); then
      RESUME_ROUTE="/pr-monitor-and-manage-wake"
    else
      RESUME_ROUTE="/go-on"
    fi
  fi

  # -- verdict and action ----------------------------------------------------------
  if (( ! OWNED )); then
    VERDICT="unowned"
    if [[ "$CLAIM_VERDICT" == "unknown" ]]; then
      # The claim gate's own fail-closed verdict outranks the sweep.
      ACTION="skip"
      REASON="claim state undetermined — treat as claimed (issue-claim.sh fail-closed)"
    else
      ACTION="dispatch"
      REASON="no other thread owns this candidate"
    fi
  elif [[ "$LIVENESS" == "dead" ]]; then
    VERDICT="owned_dead"
    # Adoption takes the claim over through the EXISTING stale-takeover path, so
    # it is only available where that path would succeed: a claim verdict
    # issue-claim.sh already reports startable. Every other verdict skips.
    if [[ "$CLAIM_VERDICT" == "claimed" ]]; then
      # Taking a FRESH foreign claim needs --allow-claimed, which is a user
      # instruction and never inferred. The claim ages out on its own.
      ACTION="skip"
      REASON="owner session is archived, but its claim is still fresh — takeover needs an explicit user override"
    elif [[ "$CLAIM_VERDICT" == "unknown" ]]; then
      # Fail-closed outranks adoption in BOTH directions: a claim we could not
      # read is never permission to take it over.
      ACTION="skip"
      REASON="owner session is archived, but the claim state is undetermined — treat as claimed (issue-claim.sh fail-closed)"
    elif [[ "$CLAIM_VERDICT" == "unavailable" ]]; then
      ACTION="skip"
      REASON="owner session is archived, but the claim gate is unavailable — surfacing instead of taking over an unreadable claim"
    else
      ACTION="adopt"
      if [[ -n "$ADOPT_FROM" ]]; then
        REASON="owner session is archived — adopt from surviving ${ADOPT_FROM}"
      else
        REASON="owner session is archived and nothing survived — adopt as a fresh dispatch"
      fi
    fi
  else
    VERDICT="owned_live"
    ACTION="skip"
    REASON="owned by a ${STATE} thread — resume it there with $RESUME_ROUTE"
  fi

  emit_candidate "$ISSUE"
done

exit 0
