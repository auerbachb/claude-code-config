#!/usr/bin/env bash
# safe-close-clean.sh — Shell-side steps of /safe-close's "tidy what the thread left behind" increment (issue #2262).
# catalog: session-state-locking — Plans and applies /safe-close's cleanup from the read-only inventory's JSON: every removal except plain scratch files goes through an existing helper, work-holding things are kept and named, and it never states a verdict
#
# PURPOSE
#   After /safe-close has checked (#2260) and stopped (#2261), this script
#   tidies the residue the inventory attributed to THIS thread: finished
#   worktrees and local branches, issue claims, handoffs for merged PRs, the
#   thread's own session-state entries, and scratch files. It deletes nothing
#   itself except scratch files; every other removal is delegated to the helper
#   that already owns it (stale-cleanup.sh --apply-finished --only, issue-claim.sh, handoff-state.sh,
#   session-state.sh, execution-pause.sh). There is no new deletion path, no
#   `git clean`, no forced discard.
#
#   It NEVER states the thread's verdict and never reads a helper's exit status
#   as proof: each removal is confirmed by re-reading the state it changed, and
#   the caller re-runs safe-close-inventory.sh afterwards — that re-run is the
#   verdict. The inventory script stays read-only.
#
# USAGE
#   safe-close-clean.sh plan  --inventory FILE|- --session ID --repo owner/name
#                       --worktree PATH [--scratchpad DIR]
#   safe-close-clean.sh apply --inventory FILE|- --session ID --repo owner/name
#                       --worktree PATH [--scratchpad DIR]
#                       [--confirmed-gone AGENT_KEY]... [--approve KIND]...
#   safe-close-clean.sh --help | -h
#
#   plan   Read-only: say what apply would remove, keep, or ask about. Reads
#          GitHub and state; writes nothing.
#   apply  Do it. --confirmed-gone names a subagent record whose runtime id the
#          harness showed absent (the record is removed only then). --approve
#          clears one kind of marker that carries the user's own intent and so
#          cannot be shown to be finished: launch_gate (an armed /pause or /end
#          gate), pause_record (an un-resumed park record — discarding it gives
#          up the /go-on resume), leave (an armed /leave-by marker).
#
#   --session, --repo and --worktree are REQUIRED for both modes (exit 2
#   without): the scoped checks cannot run blind, and silently skipping them
#   would read as "nothing to clean". The inventory must name the same session,
#   repo and worktree, or the script refuses (exit 2): it acts only on the
#   thread the inventory attributed.
#
# WHAT IS REMOVED — and only when verified
#   worktrees + local branches   stale-cleanup.sh --apply-finished (finished-only:
#                                merged owner-authored PR, clean,
#                                pushed, idle — the primitive the repo-wide sweep
#                                itself runs), scoped with --only to exactly the
#                                checkouts the inventory attributed to THIS
#                                thread (its own recovery paths and its
#                                subagents'). Another thread's finished worktree
#                                is never named, so never removed; a locked one
#                                is reported left behind, never forced. Run only
#                                when the inventory shows a checkout of this
#                                thread other than its own (a process cannot
#                                remove the directory it runs in). The outcome is
#                                read back from `git worktree list` and the refs.
#                                Other finished worktrees in the repo are only
#                                COUNTED (a one-line /pm-clean pointer; omitted
#                                when the count cannot be read).
#   issue claims                 issue-claim.sh --release with the recorded
#                                holder, only when this account has no open PR
#                                for the issue; read back with --check.
#   handoff files                handoff-state.sh --delete, only for a PR GitHub
#                                reports MERGED and this account authored.
#   session-state entries        --remove-agent for an agent record named in
#                                --confirmed-gone; this session's resume receipt
#                                (set to null). Only this session's keys.
#   scratch files                regular files under the given scratchpad (links,
#                                special files and .env* are kept and counted).
#
# WHAT IS KEPT (named, with a one-line pickup note)
#   dirty or unpushed worktrees, branches no PR covers, open or closed-unmerged
#   PRs, handoffs and claims for open PRs, queued work, subagent records not
#   confirmed gone, anything an unreadable read could not clear.
#
# OUTPUT (JSON on stdout)
#   {"mode", "verdict":"not_assessed", "removed"|"would_remove":[...],
#    "kept":[...], "ask":[...], "failed":[...], "notes":[...],
#    "unknown_categories":[...], "sweep":{...}}
#   Each entry: {kind, id, why, pickup?}. ask[] has ONE entry per approvable
#   kind — {kind, approve, why, ids[]} — and approving a kind clears every
#   record of that kind this session holds (the legacy top-level one and the
#   repo-scoped one), so the menu offers it once and says so.
#
# EXIT CODES
#   0  every class was processed (kept items are not failures)
#   1  a read or removal failed or could not be confirmed (see failed[])
#   2  usage error / the inventory does not match the arguments
#   3  environment error (jq or git missing)
#
# Bash 3.2 compatible (macOS); passes under bash 5.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; n = 1; next } { exit } END { exit(n ? 0 : 1) }' "$0" ||
    { printf '%s: --help header extraction produced no output\n' "$0" >&2; exit 70; }
}
die() { local rc="$1"; shift; printf 'safe-close-clean.sh: %s\n' "$*" >&2; exit "$rc"; }

command -v jq >/dev/null 2>&1 || die 3 "jq not found"
command -v git >/dev/null 2>&1 || die 3 "git not found"

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

[[ $# -ge 1 ]] || { usage; exit 2; }
MODE="$1"; shift
case "$MODE" in
  --help|-h) usage; exit 0 ;;
  plan|apply) ;;
  *) die 2 "unknown mode: $MODE" ;;
esac

INVENTORY="" SESSION="" REPO="" WT_ARG="" SCRATCH_ARG=""
GONE=" " APPROVED=" "
while [[ $# -gt 0 ]]; do
  case "$1" in
    --inventory|--session|--repo|--worktree|--scratchpad|--confirmed-gone|--approve)
      [[ $# -ge 2 && -n "$2" ]] || die 2 "$1 requires a value"
      case "$1" in
        --inventory) INVENTORY="$2" ;;
        --session) SESSION="$2" ;;
        --repo) REPO="$2" ;;
        --worktree) WT_ARG="$2" ;;
        --scratchpad) SCRATCH_ARG="$2" ;;
        --confirmed-gone) GONE="$GONE$2 " ;;
        --approve)
          case "$2" in launch_gate|pause_record|leave) APPROVED="$APPROVED$2 " ;;
            *) die 2 "--approve takes launch_gate, pause_record or leave, got: $2" ;; esac ;;
      esac
      shift 2 ;;
    *) die 2 "unknown argument: $1" ;;
  esac
done
[[ -n "$INVENTORY" ]] || die 2 "--inventory FILE|- is required"
[[ -n "$SESSION" ]] || die 2 "--session is required: without it this thread's entries cannot be told from another's"
[[ -n "$REPO" ]] || die 2 "--repo owner/name is required: the repo-scoped checks cannot run without it"
[[ -n "$WT_ARG" ]] || die 2 "--worktree is required: the cleanup scope and the attribution check need the thread's own checkout"
[[ "$REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || die 2 "--repo must be owner/name, got: $REPO"
# The session id becomes part of a jq path below, so it is restricted to a literal-safe alphabet.
[[ "$SESSION" =~ ^[A-Za-z0-9._:-]+$ ]] || die 2 "--session has characters outside [A-Za-z0-9._:-]"
REPO="$(printf '%s' "$REPO" | tr '[:upper:]' '[:lower:]')"
if [[ "$GONE" != " " ]]; then
  for g in $GONE; do [[ "$g" =~ ^[A-Za-z0-9._:-]+$ ]] || die 2 "--confirmed-gone has characters outside [A-Za-z0-9._:-]: $g"; done
fi

WT="$(cd "$WT_ARG" 2>/dev/null && pwd -P)" || die 2 "--worktree is not a readable directory: $WT_ARG"

if [[ "$INVENTORY" == "-" ]]; then INV="$(cat)"; else INV="$(cat "$INVENTORY" 2>/dev/null)" || die 2 "cannot read $INVENTORY"; fi
jq -e '.schema_version == 1 and (.items | type == "array") and (.categories | type == "object")' >/dev/null 2>&1 <<<"$INV" \
  || die 2 "the inventory is not a safe-close-inventory.sh --json document"
jq -e --arg s "$SESSION" --arg r "$REPO" --arg w "$WT" \
  '(.session == $s) and ((.repo // "") | ascii_downcase) == $r and (.worktree == $w)' >/dev/null 2>&1 <<<"$INV" \
  || die 2 "the inventory names a different session, repo or worktree than the arguments; refusing to clean a thread it did not attribute"

SESSION_STATE_SH="$(resolve_script session-state.sh)" || SESSION_STATE_SH=""
CLAIM_SH="$(resolve_script issue-claim.sh)" || CLAIM_SH=""
HANDOFF_SH="$(resolve_script handoff-state.sh)" || HANDOFF_SH=""
STALE_SH="$(resolve_script stale-cleanup.sh)" || STALE_SH=""
PAUSE_SH="$(resolve_script execution-pause.sh)" || PAUSE_SH=""

DO=0
[[ "$MODE" == apply ]] && DO=1
HOST="$(hostname 2>/dev/null || echo unknown)"
HOLDER_DEFAULT="$HOST:$WT"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# ---- report accumulators --------------------------------------------------------------
A_REMOVED='[]' A_KEPT='[]' A_ASK='[]' A_FAILED='[]' A_NOTES='[]'
SWEEP_JSON='null'
emit() { # bucket kind id why [pickup]
  local b="$1" k="$2" i="$3" w="$4" p="${5:-}"
  local obj
  obj="$(jq -nc --arg k "$k" --arg i "$i" --arg w "$w" --arg p "$p" \
    '{kind:$k, id:$i, why:$w} + (if $p == "" then {} else {pickup:$p} end)')" || return 1
  case "$b" in
    removed) A_REMOVED="$(jq -c --argjson o "$obj" '. + [$o]' <<<"$A_REMOVED")" ;;
    kept) A_KEPT="$(jq -c --argjson o "$obj" '. + [$o]' <<<"$A_KEPT")" ;;
    failed) A_FAILED="$(jq -c --argjson o "$obj" '. + [$o]' <<<"$A_FAILED")" ;;
    notes) A_NOTES="$(jq -c --argjson o "$obj" '. + [$o]' <<<"$A_NOTES")" ;;
  esac
}
emit_ask() { # kind id why approve-kind
  local obj
  obj="$(jq -nc --arg k "$1" --arg i "$2" --arg w "$3" --arg a "$4" '{kind:$k, id:$i, why:$w, approve:$a}')" || return 1
  A_ASK="$(jq -c --argjson o "$obj" '. + [$o]' <<<"$A_ASK")"
}
items_of() { jq -c --arg c "$1" '.items[] | select(.category == $c)' <<<"$INV"; }
done_or_would() { # kind id why  — the thing was removed (apply) or would be (plan)
  emit removed "$1" "$2" "$3"
}

ss() { "$SESSION_STATE_SH" --repo "$REPO" "$@"; }

# ---- 1. issue claims -------------------------------------------------------------------
clean_claims() {
  local items row n cout verdict holder_rec holder open_prs pr_ok=1 cover held_json held cid
  items="$(items_of claims | jq -c 'select(.ref.kind == "claim")')" || { emit failed claims "-" "could not read the inventory's claim items"; return; }
  [[ -n "$items" ]] || return 0
  if [[ -z "$CLAIM_SH" ]]; then
    emit failed claims "-" "issue-claim.sh not found (checked all three paths): claims cannot be released"; return
  fi
  if ! command -v gh >/dev/null 2>&1; then
    emit failed claims "-" "gh not found: open PRs for the claimed issues cannot be checked, so no claim is released"; return
  fi
  open_prs="$(gh pr list --repo "$REPO" --author "@me" --state open --json number,headRefName,closingIssuesReferences --limit 100 2>/dev/null)" || pr_ok=0
  if (( pr_ok == 1 )) && ! jq -e 'type == "array" and length < 100' >/dev/null 2>&1 <<<"$open_prs"; then pr_ok=0; fi
  # Issues that a work-holding worktree or branch of this thread still names (issue-N-* branches): the
  # claim is the only thing stopping a second thread from redoing that work, so it stays.
  held_json="$(jq -c '[.items[]
      | select((.category == "worktrees" and ((.id // "") | test("^(dirty|unpushed):")))
               or (.category == "branches" and .consequence != "harmless"))
      | ((.ref.branch // "") | capture("^(worktree-)?issue-(?<k>[0-9]+)(-|$)")? | (.k | tonumber))]' <<<"$INV" 2>/dev/null)" || held_json=""
  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    n="$(jq -r '.ref.issue' <<<"$row")"
    [[ "$n" =~ ^[0-9]+$ ]] || { emit failed claim "$n" "the inventory's claim item has no usable issue number"; continue; }
    if (( pr_ok == 0 )); then
      emit kept claim "issue #$n" "could not read this account's open PRs, so it cannot be shown that no open PR needs the claim" \
        "re-run /safe-close once GitHub is reachable"
      emit failed claim "issue #$n" "open-PR list unreadable (or truncated at 100); claim kept"
      continue
    fi
    # The issue number is extracted from the branch name and compared with ==, never interpolated into a pattern.
    cover="$(jq -r --argjson n "$n" '
      [.[] | select(
          ((.headRefName // "") | capture("^(worktree-)?issue-(?<k>[0-9]+)(-|$)")? // null | if . == null then false else (.k | tonumber) == $n end)
          or ([(.closingIssuesReferences // [])[] | .number] | index($n) != null)
        ) | .number] | .[0] // ""' <<<"$open_prs" 2>/dev/null)" \
      || { emit failed claim "issue #$n" "could not match open PRs to the issue; claim kept"; continue; }
    if [[ -n "$cover" ]]; then
      emit kept claim "issue #$n" "PR #$cover is open for it, so the claim stays" \
        "merge PR #$cover (/wrap) and the claim is released; or run issue-claim.sh $n --release"
      continue
    fi
    if [[ -z "$held_json" ]]; then
      emit kept claim "issue #$n" "could not tell whether a worktree or branch still holds unlanded work for it" "re-run /safe-close"
      emit failed claim "issue #$n" "the inventory's work-holding items could not be read; claim kept"
      continue
    fi
    held="$(jq -r --argjson n "$n" 'index($n) != null' <<<"$held_json" 2>/dev/null)" || held=""
    if [[ "$held" != false ]]; then
      emit kept claim "issue #$n" "a worktree or branch of this thread still holds unlanded work for it, so the claim stays" \
        "commit, push and open a PR for it, then run /safe-close again"
      continue
    fi
    cout="$("$CLAIM_SH" "$n" --check --json --repo "$REPO" --holder "$SESSION" 2>/dev/null)"
    if ! jq -e '.verdict != null' >/dev/null 2>&1 <<<"$cout"; then
      emit failed claim "issue #$n" "could not read the claim; kept"; continue
    fi
    cid="$(jq -r '.claim_comment_id // ""' <<<"$cout")"
    verdict="$(jq -r '.verdict' <<<"$cout")"
    holder_rec="$(jq -r '.claimant_holder // ""' <<<"$cout")"
    case "$verdict" in
      mine) holder="$SESSION" ;;
      claimed)
        if [[ -n "$holder_rec" && ( "$holder_rec" == "$SESSION" || "$holder_rec" == "$HOLDER_DEFAULT" ) ]]; then holder="$holder_rec"
        else emit kept claim "issue #$n" "claimed by another thread; not this thread's to release" ""; continue; fi ;;
      unclaimed|stale) continue ;;
      *) emit failed claim "issue #$n" "claim state is '$verdict'; kept"; continue ;;
    esac
    if [[ ! "$cid" =~ ^[1-9][0-9]*$ ]]; then
      emit failed claim "issue #$n" "the claim's comment id could not be read, so it cannot be released against the claim that was checked; kept"; continue
    fi
    if (( DO == 0 )); then done_or_would claim "issue #$n" "claim would be released (holder $holder)"; continue; fi
    # --release compares logins, not holders, so a sibling thread of this account that took the claim
    # between the check above and this call would lose it. --expect-claim-id makes the release refuse
    # (exit 5, nothing written) when the claim is no longer the one that was checked; the read-back below
    # still reports a claim that is not unclaimed afterwards as failed, never as released.
    "$CLAIM_SH" "$n" --release --repo "$REPO" --holder "$holder" --expect-claim-id "$cid" --json >/dev/null 2>&1
    # The release command's exit status is not proof: read the claim back.
    cout="$("$CLAIM_SH" "$n" --check --json --repo "$REPO" --holder "$SESSION" 2>/dev/null)"
    if jq -e '.verdict == "unclaimed"' >/dev/null 2>&1 <<<"$cout"; then
      done_or_would claim "issue #$n" "claim released and confirmed unclaimed"
    else
      emit failed claim "issue #$n" "claim is still held after the release attempt"
    fi
  done <<<"$items"
}

# ---- 2. handoffs ------------------------------------------------------------------------
clean_handoffs() {
  local items row id n hp want pj state author viewer
  items="$(items_of handoffs | jq -c 'select(.ref.kind == "handoff")')" || { emit failed handoffs "-" "could not read the inventory's handoff items"; return; }
  [[ -n "$items" ]] || return 0
  if [[ -z "$HANDOFF_SH" ]]; then emit failed handoffs "-" "handoff-state.sh not found (checked all three paths)"; return; fi
  if ! command -v gh >/dev/null 2>&1; then emit failed handoffs "-" "gh not found: PR state cannot be read, so no handoff is deleted"; return; fi
  viewer="$(gh api user --jq '.login' 2>/dev/null)" || viewer=""
  if [[ -z "$viewer" || "$viewer" == null ]]; then
    emit failed handoffs "-" "could not resolve the authenticated GitHub user, so no handoff is deleted"; return
  fi
  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    id="$(jq -r '.id' <<<"$row")"; n="${id#handoff:}"
    [[ "$n" =~ ^[0-9]+$ ]] || { emit failed handoff "$id" "no usable PR number in the item id"; continue; }
    hp="$(jq -r '.ref.path // ""' <<<"$row")"
    want="$("$HANDOFF_SH" --owner-repo "$REPO" --path "$n" 2>/dev/null)" || want=""
    if [[ -z "$want" || "$want" != "$hp" ]]; then
      emit failed handoff "PR #$n" "the inventory's handoff path does not match the canonical one; kept"; continue
    fi
    pj="$(gh pr view "$n" --repo "$REPO" --json state,author 2>/dev/null)"
    if ! jq -e '.state != null' >/dev/null 2>&1 <<<"$pj"; then
      emit kept handoff "PR #$n" "PR state could not be read, so it cannot be shown to be merged" "re-run /safe-close once GitHub is reachable"
      emit failed handoff "PR #$n" "PR state unreadable; handoff kept"; continue
    fi
    state="$(jq -r '.state' <<<"$pj")"; author="$(jq -r '.author.login // ""' <<<"$pj")"
    if [[ "$state" != MERGED ]]; then
      emit kept handoff "PR #$n" "PR is $state; the handoff is its record" "it is deleted after the PR merges (/wrap)"
      continue
    fi
    if [[ "$author" != "$viewer" ]]; then
      emit kept handoff "PR #$n" "PR was not authored by this account" ""; continue
    fi
    if (( DO == 0 )); then done_or_would handoff "PR #$n" "handoff would be deleted (PR merged)"; continue; fi
    "$HANDOFF_SH" --owner-repo "$REPO" --delete "$n" >/dev/null 2>&1
    if [[ ! -e "$hp" ]]; then done_or_would handoff "PR #$n" "handoff deleted (PR merged) and confirmed gone"
    else emit failed handoff "PR #$n" "the handoff file is still there after the delete"; fi
  done <<<"$items"
}

# ---- 3. finished worktrees and local branches (stale-cleanup.sh --apply-finished --only) ----
# Thread-scoped: only the checkouts the inventory attributed to this thread are ever named to
# the helper. Ownership that cannot be shown means the path is not in the inventory, so it is
# never named (and nothing here widens to "every finished worktree").
# bounded_capture <secs> <command...> - run one command under the repo's wall-clock bound
# (lib/bounded-run.sh). Output lands in BCAP_OUT. Returns 0 only for a real success: a timeout, a
# missing bound library or a failed temp file is a failed read, never an empty one.
BCAP_OUT=""
bounded_capture() {
  local secs="$1" cap cap_err rc lib
  shift
  BCAP_OUT=""
  lib="$(dirname "${STALE_SH:-/nonexistent/x}")/lib/bounded-run.sh"
  [[ -r "$lib" ]] || return 125
  # shellcheck source=lib/bounded-run.sh
  source "$lib" || return 125
  cap="$(mktemp)" || return 125
  cap_err="$(mktemp)" || { rm -f "$cap"; return 125; }
  CAPTURE="$cap" CAPTURE_ERR="$cap_err"
  secs="$(normalize_bound "$secs" 60)"
  run_bounded "$secs" "$@"; rc=$?
  BCAP_OUT="$(cat "$cap" 2>/dev/null)"
  rm -f "$cap" "$cap_err"
  [[ "${BOUNDED_TIMED_OUT:-0}" != 1 ]] || return 124
  return "$rc"
}

# 0 only when the branch's newest PR (the row the finished-worktree helper itself judges) is
# MERGED on GitHub. A CLOSED-unmerged PR, no PR, a failed or timed-out lookup, or an unreadable
# answer all return non-zero and set MERGED_WHY: that checkout is kept, never removed.
MERGED_WHY=""
branch_pr_merged() {
  local b="$1" state
  MERGED_WHY=""
  if ! bounded_capture "${SAFE_CLOSE_PR_LOOKUP_TIMEOUT_SECS:-60}" \
      gh pr list --repo "$REPO" --head "$b" --state all --author "@me" --limit 100 --json number,state,headRefName; then
    MERGED_WHY="its PR state could not be read from GitHub"; return 1
  fi
  if ! state="$(jq -r --arg b "$b" 'if type == "array" and length > 0 and all(.[]; type == "object" and .headRefName == $b) then (.[0].state // "") else "?" end' <<<"$BCAP_OUT" 2>/dev/null)"; then
    MERGED_WHY="its PR state could not be read from GitHub"; return 1
  fi
  case "$state" in
    MERGED) return 0 ;;
    CLOSED) MERGED_WHY="its PR was closed without merging: that is unmerged work" ;;
    OPEN) MERGED_WHY="its PR is still open" ;;
    *) MERGED_WHY="no merged PR could be verified for it" ;;
  esac
  return 1
}

clean_worktrees() {
  clean_worktrees_own
  report_other_finished
}

# The report line for finished worktrees this thread does NOT own: counted from the helper's
# read-only detection and pointed at /pm-clean. Never removes anything. An unreadable count is
# omitted, never guessed; a scan that finished incompletely says "at least".
report_other_finished() {
  local helper bounded out rc n own scan p cap cap_err bound prev
  [[ -n "$STALE_SH" ]] || return 0
  helper="$(dirname "$STALE_SH")/lib/stale-cleanup-finished.py"
  bounded="$(dirname "$STALE_SH")/lib/bounded-run.sh"
  [[ -r "$helper" && -r "$bounded" ]] && command -v python3 >/dev/null 2>&1 || return 0
  # The count is optional: a wall-clock bound keeps a slow repo-wide scan from stalling the cleanup
  # (an expired bound omits the line, it never guesses).
  # shellcheck source=lib/bounded-run.sh
  source "$bounded" || return 0
  cap="$(mktemp)" || return 0
  cap_err="$(mktemp)" || { rm -f "$cap"; return 0; }
  CAPTURE="$cap" CAPTURE_ERR="$cap_err"
  bound="$(normalize_bound "${SAFE_CLOSE_OTHER_COUNT_TIMEOUT_SECS:-120}" 120)"
  prev="$PWD"
  cd "$WT" 2>/dev/null || { rm -f "$cap" "$cap_err"; return 0; }
  run_bounded "$bound" python3 "$helper" --root "$WT" --caller "$WT" --json; rc=$?
  cd "$prev" 2>/dev/null || true
  out="$(cat "$cap" 2>/dev/null)"; rm -f "$cap" "$cap_err"
  [[ "${BOUNDED_TIMED_OUT:-0}" != 1 ]] || return 0
  (( rc == 0 || rc == 1 )) || return 0
  jq -e 'type == "object" and (.finished_worktrees | type == "array") and (.finished_scan == "complete" or .finished_scan == "incomplete")' >/dev/null 2>&1 <<<"$out" || return 0
  scan="$(jq -r '.finished_scan' <<<"$out")" || return 0
  own="$(items_of worktrees | jq -r '.ref.path // empty')" || return 0
  n=0
  while IFS= read -r p; do
    [[ -n "$p" && "$p" != "$WT" ]] || continue
    case "
$own
" in *"
$p
"*) continue ;; esac
    n=$((n + 1))
  done < <(jq -r '.finished_worktrees[]?.path // empty' <<<"$out")
  (( n > 0 )) || return 0
  emit notes other_finished_worktrees "-" "$([[ "$scan" == incomplete ]] && printf 'at least ')$n other finished worktree(s) in this repo are not attributed to this thread and were left alone" \
    "/pm-clean clears them"
}

clean_worktrees_own() {
  local rows row p b id wlist cands="" crows="" brefs="" gone="" wasref removed_wt listed rc line present only_args reason out wt_rows wbefore was
  # Work-holding things: kept and named, never touched.
  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    id="$(jq -r '.id' <<<"$row")"
    case "$id" in
      dirty:*|unpushed:*)
        emit kept worktree "${id#*:}" "$(jq -r '.summary' <<<"$row")" \
          "commit and push it (or open a PR for it), then run /safe-close again" ;;
    esac
  done < <(items_of worktrees)
  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    emit kept branch "$(jq -r '.ref.branch // .id' <<<"$row")" "$(jq -r '.summary' <<<"$row")" \
      "open a PR for it, or delete it by hand when it is not needed"
  done < <(items_of branches | jq -c 'select(.consequence != "harmless" and .consequence != "unknown")')
  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    emit kept pr "$(jq -r '.id' <<<"$row")" "$(jq -r '.summary' <<<"$row")" "let it merge (/wrap), then run /safe-close again"
  done < <(items_of open_prs | jq -c 'select(.consequence != "harmless" and .consequence != "unknown")')

  # This thread's other, clean checkouts (the inventory's attribution): the only candidates.
  # Captured first so an unreadable inventory is a failure, not an empty candidate list.
  if ! wt_rows="$(items_of worktrees)"; then
    emit failed worktree "-" "could not read this thread's worktrees from the inventory; nothing was removed"; return
  fi
  while IFS=$'\t' read -r p b; do
    [[ -n "$p" && "$p" != "$WT" ]] || continue
    # Identity the removal is bound to. No recorded branch means no identity to bind: kept.
    if [[ -z "$b" ]]; then
      emit kept worktree "$p" "the inventory recorded no branch for it, so it cannot be bound to what was inventoried" \
        "/pm-clean can judge a detached checkout"
      continue
    fi
    # Unmerged work is kept. The helper now keeps a CLOSED PR too (Issue #2281); this stays as a second line of defence.
    if ! branch_pr_merged "$b"; then
      emit kept worktree "$p" "$MERGED_WHY; the checkout and its branch '$b' are kept" \
        "merge the PR (/wrap) or reopen it, or remove the checkout by hand once the work is saved elsewhere"
      continue
    fi
    cands="$cands
$p"
    crows="$crows
$p	$b"
  done < <(jq -r 'select(.id | startswith("clean:")) | [(.ref.path // ""), (.ref.branch // "")] | @tsv' <<<"$wt_rows")
  if [[ -z "$(printf '%s' "$cands" | tr -d '[:space:]')" ]]; then
    if items_of worktrees | jq -e 'select(.id | startswith("clean:")) | select(.ref.path == $w)' --arg w "$WT" >/dev/null 2>&1; then
      emit notes own_checkout "$WT" "this thread's own checkout stays: a process cannot remove the directory it runs in" \
        "remove it from another checkout (git worktree remove) or let the session-exit prompt handle it"
    fi
    return 0
  fi
  if (( DO == 0 )); then
    while IFS= read -r p; do
      [[ -n "$p" ]] || continue
      done_or_would worktree "$p" "its PR is verified merged; it would be removed by the finished-worktree cleanup if it is also clean, pushed and idle"
    done <<<"$cands"
    return 0
  fi
  if [[ -z "$STALE_SH" ]]; then
    emit failed sweep "-" "stale-cleanup.sh not found (checked all three paths): finished worktrees cannot be removed"; return
  fi
  only_args=()
  while IFS=$'\t' read -r p b; do
    [[ -n "$p" ]] && only_args+=(--only-identity "$p" "$b")
  done <<<"$crows"
  # A scope that came out empty must refuse, never widen to every finished worktree.
  if (( ${#only_args[@]} == 0 )); then
    emit failed sweep "-" "no thread-owned worktree path to scope the cleanup to; nothing was removed"; return
  fi
  # "Removed" needs a before AND an after: a path that was never registered cannot have been removed.
  # Both reads are wall-clock bounded; a timeout is a failed read, never an empty list.
  if ! bounded_capture "${SAFE_CLOSE_GIT_TIMEOUT_SECS:-60}" git -C "$WT" worktree list --porcelain; then
    emit failed sweep "-" "could not read the worktree list before the cleanup (failed or timed out); nothing was removed"; return
  fi
  wbefore="$BCAP_OUT"
  # Branch refs before: a branch is reported removed only if it existed before and is gone after.
  brefs=""
  while IFS=$'\t' read -r p b; do
    [[ -n "$p" ]] || continue
    git -C "$WT" show-ref --verify --quiet "refs/heads/$b" 2>/dev/null && brefs="$brefs
$b"
  done <<<"$crows"
  out="$(cd "$WT" && "$STALE_SH" --apply-finished --json --root "$WT" "${only_args[@]}" 2>/dev/null)"
  rc=$?
  # No usable report plus a failing exit: say the helper failed (the read-back below still decides what was removed).
  if (( rc != 0 )) && ! jq -e 'type == "object"' >/dev/null 2>&1 <<<"$out"; then
    emit failed sweep "-" "stale-cleanup.sh exited $rc without a readable report; whatever it removed is confirmed below from the worktree list"
  fi
  SWEEP_JSON="$(jq -nc --argjson rc "$rc" '{ran:true, scoped:true, exit:$rc, note:"exit status is not evidence; removal was read back"}')"
  # Read back: what is still registered, what is still on disk.
  if ! bounded_capture "${SAFE_CLOSE_GIT_TIMEOUT_SECS:-60}" git -C "$WT" worktree list --porcelain; then
    emit failed sweep "-" "could not re-read the worktree list after the cleanup (failed or timed out); nothing is reported removed"; return
  fi
  wlist="$BCAP_OUT"
  gone=""
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    listed=0
    while IFS= read -r line; do [[ "$line" == "worktree $p" ]] && listed=1; done <<<"$wlist"
    present=0; [[ -e "$p" ]] && present=1
    was=0
    while IFS= read -r line; do [[ "$line" == "worktree $p" ]] && was=1; done <<<"$wbefore"
    if (( was == 0 )); then
      emit kept worktree "$p" "it was not a registered worktree before the cleanup, so nothing was removed" \
        "/pm-clean lists orphaned registrations and checkouts"
    elif (( listed == 0 && present == 0 )); then
      done_or_would worktree "$p" "removed by the finished-worktree cleanup and confirmed gone"
      gone="$gone
$p"
    elif (( listed == 0 && present == 1 )); then
      emit failed worktree "$p" "unregistered but the folder is still on disk (a .DS_Store race, or leftover files); it is not forced away"
    else
      # The helper's own reason for retaining it (locked, open PR, live process, ...), when readable.
      reason="$(jq -r --arg p "$p" '[((.skipped_finished_worktrees // []) + (.unknown_finished_worktrees // []) + (.finished_apply // []))[] | select(.path == $p) | .reason // empty] | last // empty' <<<"$out" 2>/dev/null)" || reason=""
      case "$reason" in
        locked) emit kept worktree "$p" "left behind: the worktree is locked, and a lock is never overridden" \
          "unlock it (git worktree unlock) if it is really finished, then run /safe-close again" ;;
        only_identity_mismatch) emit kept worktree "$p" "left alone: a different worktree is registered at this path than the one the inventory recorded" \
          "run /safe-close again for a fresh inventory" ;;
        *) emit kept worktree "$p" "the cleanup retained it${reason:+ ($reason)}: its PR is not verified merged, or it is not provably idle" \
          "finish or merge the PR, then run /safe-close again; /pm-clean lists what blocks it" ;;
      esac
    fi
  done <<<"$cands"
  # Local branches: claimed removed only when this cleanup removed the worktree AND the ref existed
  # before and is absent now. A failed guarded deletion after the worktree is gone is a failure.
  while IFS=$'\t' read -r p b; do
    [[ -n "$p" && -n "$b" ]] || continue
    wasref=0; case "
$brefs
" in *"
$b
"*) wasref=1 ;; esac
    removed_wt=0; case "
$gone
" in *"
$p
"*) removed_wt=1 ;; esac
    git -C "$WT" show-ref --verify --quiet "refs/heads/$b" 2>/dev/null
    case $? in
      0) if (( removed_wt == 1 )); then emit failed branch "$b" "its worktree was removed but the guarded branch deletion did not happen, so the local branch remains" \
           "check it is merged, then delete it with git branch -d $b"; fi ;;
      1) if (( removed_wt == 1 && wasref == 1 )); then
           done_or_would branch "$b" "local branch removed with its finished worktree and confirmed gone"
         elif (( wasref == 1 )); then
           emit notes branch "$b" "the branch is gone but this cleanup did not remove its worktree, so it is not counted as removed by this cleanup"
         fi ;;
      *) emit failed branch "$b" "could not read the branch refs after the cleanup, so its removal is unconfirmed" ;;
    esac
  done <<<"$crows"
}

# ---- 4. session-state entries ---------------------------------------------------------------
# cas_set <path> <expected-json> <new-json>  — a one-key compare-and-set; 0 only when it landed.
cas_set() { ss --cas "$1=$3" --expect "$2" >/dev/null 2>&1; }

clean_state() {
  local items row key rec sid gone raw agents recsess kind path val expect new cur wdt
  # (a) subagent records: removed only when the harness showed the runtime id absent.
  items="$(items_of subagents | jq -c 'select(.ref.kind == "state_record")')" \
    || { items=""; emit failed agents "-" "could not read the inventory's subagent records"; }
  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    key="$(jq -r '.ref.key' <<<"$row")"
    [[ "$key" =~ ^[A-Za-z0-9._:-]+$ ]] || { emit failed agent "$key" "agent key has unexpected characters; kept"; continue; }
    case "$GONE" in
      *" $key "*) ;;
      *) emit kept agent "$key" "still recorded as running; not confirmed gone" "stop it (the stop step) and pass it as confirmed gone, or let it finish"; continue ;;
    esac
    if [[ -z "$SESSION_STATE_SH" ]]; then emit failed agent "$key" "session-state.sh not found"; continue; fi
    raw="$(ss --get-json '.active_agents' 2>/dev/null)" && jq -e 'type == "object"' >/dev/null 2>&1 <<<"$raw" \
      || { emit failed agent "$key" "could not read .active_agents; record kept"; continue; }
    rec="$(jq -c --arg k "$key" '.[$k] // null' <<<"$raw")"
    if [[ "$rec" == null ]]; then continue; fi
    recsess="$(jq -r '(.session_id // .session // "")' <<<"$rec")"
    if [[ -n "$recsess" && "$recsess" != "$SESSION" ]]; then
      emit kept agent "$key" "the record names another session; not this thread's" ""; continue
    fi
    if (( DO == 0 )); then done_or_would agent "$key" "agent record would be removed (confirmed gone)"; continue; fi
    # The record was read and attributed just above; agent keys are unique runtime ids, so the window
    # between that read and this removal is two adjacent calls (the helper has no compare-and-delete).
    ss --remove-agent "$key" >/dev/null 2>&1
    raw="$(ss --get-json '.active_agents' 2>/dev/null)" && jq -e 'type == "object" or type == "null"' >/dev/null 2>&1 <<<"$raw" \
      || { emit failed agent "$key" "could not re-read .active_agents after the removal"; continue; }
    if jq -e --arg k "$key" '(. // {}) | has($k) | not' >/dev/null 2>&1 <<<"$raw"; then
      done_or_would agent "$key" "agent record removed and confirmed gone"
    else
      emit failed agent "$key" "the agent record is still there after the removal"
    fi
  done <<<"$items"
  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    emit kept queued "$(jq -r '.id' <<<"$row")" "$(jq -r '.summary' <<<"$row")" \
      "queued work is the thread's unfinished plan: resume it with /go-on or /pm, or drop it by hand"
  done < <(items_of queued_work | jq -c 'select(.consequence != "harmless" and .consequence != "unknown")')

  # (b) this session's markers. The inventory reads the top-level paths; the writers use .repos[repo].
  [[ -n "$(items_of state_markers | jq -c 'select(.consequence != "harmless")')" ]] || return 0
  if [[ -z "$SESSION_STATE_SH" ]]; then emit failed markers "-" "session-state.sh not found"; return; fi
  for kind in resumes pauses execution_pauses; do
    for path in ".$kind" ".repos[\"$REPO\"].$kind"; do
      raw="$(ss --get-json "$path" 2>/dev/null)" && jq -e 'type == "object" or type == "null"' >/dev/null 2>&1 <<<"$raw" \
        || { emit failed "$kind" "$path" "could not read the marker map; kept"; continue; }
      val="$(jq -c --arg s "$SESSION" '.[$s] // null' <<<"$raw")"
      [[ "$val" == null ]] && continue
      case "$kind" in
        resumes)
          new=null
          if (( DO == 0 )); then done_or_would marker "$path[$SESSION]" "resume receipt would be cleared"; continue; fi
          cas_set "$path[\"$SESSION\"]" "$val" "$new" ;;
        pauses)
          if jq -e '.active == false or (.resumed_at != null)' >/dev/null 2>&1 <<<"$val"; then continue; fi
          case "$APPROVED" in
            *" pause_record "*) ;;
            *) emit_ask pause_record "$path[$SESSION]" \
                 "an un-resumed park record: clearing it gives up the /go-on resume of what this thread parked" pause_record; continue ;;
          esac
          if (( DO == 0 )); then done_or_would marker "$path[$SESSION]" "park record would be closed (approved)"; continue; fi
          new="$(jq -c --arg n "$NOW" '. + {active:false, resumed_at:$n, discarded_by:"safe-close"}' <<<"$val")"
          cas_set "$path[\"$SESSION\"]" "$val" "$new" ;;
        execution_pauses)
          if jq -e '.active == false' >/dev/null 2>&1 <<<"$val"; then continue; fi
          case "$APPROVED" in
            *" launch_gate "*) ;;
            *) emit_ask launch_gate "$path[$SESSION]" \
                 "a /pause or /end launch gate armed for this session; only an explicit resume normally reopens it" launch_gate; continue ;;
          esac
          if (( DO == 0 )); then done_or_would marker "$path[$SESSION]" "launch gate would be cleared (approved)"; continue; fi
          if [[ "$path" == ".repos["* ]]; then
            if [[ -z "$PAUSE_SH" ]]; then emit failed launch_gate "$path[$SESSION]" "execution-pause.sh not found"; continue; fi
            "$PAUSE_SH" --repo "$REPO" --clear --session "$SESSION" >/dev/null 2>&1
          else
            cas_set "$path[\"$SESSION\"]" "$val" "$(jq -c '. + {active:false}' <<<"$val")"
          fi ;;
      esac
      # Read back: the entry must now be cleared in the sense this kind defines.
      raw="$(ss --get-json "$path" 2>/dev/null)" && jq -e 'type == "object" or type == "null"' >/dev/null 2>&1 <<<"$raw" \
        || { emit failed "$kind" "$path" "could not re-read the marker after clearing it"; continue; }
      cur="$(jq -c --arg s "$SESSION" '.[$s] // null' <<<"$raw")"
      case "$kind" in
        resumes) wdt="$cur" ;;
        pauses) wdt="$(jq -c 'if . == null then null elif (.active == false or .resumed_at != null) then null else . end' <<<"$cur")" ;;
        *) wdt="$(jq -c 'if . == null then null elif .active == false then null else . end' <<<"$cur")" ;;
      esac
      if [[ "$wdt" == null ]]; then done_or_would marker "$path[$SESSION]" "$kind marker cleared and confirmed"
      else emit failed marker "$path[$SESSION]" "the $kind marker is still set after clearing it"; fi
    done
  done
  # (c) the armed leave-by marker.
  for path in ".leave" ".repos[\"$REPO\"].leave"; do
    raw="$(ss --get-json "$path" 2>/dev/null)" && jq -e 'type == "object" or type == "null"' >/dev/null 2>&1 <<<"$raw" \
      || { emit failed leave "$path" "could not read the leave marker; kept"; continue; }
    if ! jq -e --arg s "$SESSION" 'type == "object" and .active == true and ((.session_id // .session // "") == $s)' >/dev/null 2>&1 <<<"$raw"; then continue; fi
    wdt="$(jq -r '.winddown_task_id // ""' <<<"$raw")"
    if [[ -n "$wdt" ]]; then
      emit kept leave "$path" "its wind-down Monitor ($wdt) is still named, so the marker is not safe to clear by hand" \
        "run /leave-by cancel (it stops the wind-down first)"
      continue
    fi
    case "$APPROVED" in
      *" leave "*) ;;
      *) emit_ask leave "$path" "an armed /leave-by marker for this session (the repo's planning deadline is a separate setting and stays)" leave; continue ;;
    esac
    if (( DO == 0 )); then done_or_would marker "$path" "leave marker would be cleared (approved)"; continue; fi
    new="$(jq -c '. + {active:false, checkin_epoch:null, winddown_task_id:null, winddown_generation:null}' <<<"$raw")"
    cas_set "$path" "$raw" "$new"
    cur="$(ss --get-json "$path" 2>/dev/null)" || cur=""
    if jq -e '.active == false' >/dev/null 2>&1 <<<"$cur"; then done_or_would marker "$path" "leave marker cleared and confirmed"
    else emit failed marker "$path" "the leave marker is still armed after clearing it"; fi
  done
}

# ---- 5. scratch files ------------------------------------------------------------------------
# count_find <find-args...> — sets FOUND_N; returns 1 when find could not traverse the whole tree.
count_find() {
  local out
  out="$(find "$@" 2>/dev/null)" || return 1
  FOUND_N="$(printf '%s' "$out" | awk 'END { print NR }')"
}
clean_scratch() {
  local row dir real home_real before kept_env other left depth nested hdepth
  row="$(items_of scratchpad | jq -c 'select(.ref.kind == "scratchpad")' | head -n 1)" || row=""
  [[ -n "$row" ]] || return 0
  dir="$(jq -r '.ref.path' <<<"$row")"
  if [[ -z "$SCRATCH_ARG" || "$dir" != "$SCRATCH_ARG" ]]; then
    emit failed scratch "$dir" "the inventory's scratchpad is not the one named on the command line; nothing deleted"; return
  fi
  real="$(cd "$dir" 2>/dev/null && pwd -P)" || { emit failed scratch "$dir" "scratchpad is not a readable directory"; return; }
  # Refuse anything that could be a checkout, a home directory or a root.
  depth="$(printf '%s' "$real" | awk -F/ '{n=0; for (i=1;i<=NF;i++) if ($i != "") n++; print n}')"
  # HOME is canonicalised too: a symlinked home must not slip past the comparison.
  home_real="$(cd "${HOME:-/nonexistent}" 2>/dev/null && pwd -P)" || home_real="${HOME:-/nonexistent}"
  if [[ "$real" == / || "$real" == "$home_real" || "$real" == "${HOME:-/nonexistent}" || "$depth" -lt 3 || -e "$real/.git" ]] \
     || git -C "$real" rev-parse --show-toplevel >/dev/null 2>&1; then
    emit failed scratch "$real" "refusing to delete in a directory that looks like a home, a root or a git checkout"; return
  fi
  # Nothing at or just below a home directory (Documents, Downloads, Desktop, ~/.claude) is a scratchpad,
  # and no ancestor of a home directory is either.
  hdepth="$(printf '%s' "$home_real" | awk -F/ '{n=0; for (i=1;i<=NF;i++) if ($i != "") n++; print n}')"
  if [[ "$real/" == "$home_real/"* && $(( depth - hdepth )) -lt 3 ]] || [[ "$home_real/" == "$real/"* ]]; then
    emit failed scratch "$real" "refusing to delete at or just below a home directory"; return
  fi
  # A git checkout nested anywhere below holds work-in-progress: fail closed, delete nothing.
  count_find "$real" -name .git || { emit failed scratch "$real" "the scratch tree could not be fully read; nothing deleted"; return; }
  nested="$FOUND_N"
  if [[ "$nested" != 0 ]]; then
    emit failed scratch "$real" "a git checkout is nested inside the scratchpad; nothing deleted" ; return
  fi
  # A traversal that fails partway must never read as "nothing left": every count is checked.
  count_find "$real" ! -type d ! -type f || { emit failed scratch "$real" "the scratch tree could not be fully read; nothing deleted"; return; }
  other="$FOUND_N"
  count_find "$real" -type f -name '.env*' || { emit failed scratch "$real" "the scratch tree could not be fully read; nothing deleted"; return; }
  kept_env="$FOUND_N"
  count_find "$real" -type f || { emit failed scratch "$real" "the scratch tree could not be fully read; nothing deleted"; return; }
  before="$FOUND_N"
  if (( DO == 0 )); then
    done_or_would scratch "$real" "$(( before - kept_env )) file(s) would be removed ($kept_env .env* and $other non-regular entries kept)"
    return 0
  fi
  find "$real" -type f ! -name '.env*' -delete 2>/dev/null
  count_find "$real" -type f ! -name '.env*' || { emit failed scratch "$real" "could not re-read the scratch tree after deleting, so the removal is unconfirmed"; return; }
  left="$FOUND_N"
  if [[ "$left" == 0 ]]; then
    done_or_would scratch "$real" "$(( before - kept_env )) scratch file(s) removed; $kept_env .env* file(s) and $other non-regular entries kept"
  else
    emit failed scratch "$real" "$left scratch file(s) could not be removed"
  fi
}

clean_claims
clean_handoffs
clean_worktrees
clean_state
clean_scratch

UNKNOWN_CATS="$(jq -c '[.categories | to_entries[] | select(.value.status == "unknown") | {category:.key, reason:.value.reason}]' <<<"$INV")" || UNKNOWN_CATS='[]'
RKEY=removed; (( DO == 0 )) && RKEY=would_remove
jq -n --arg mode "$MODE" --arg rkey "$RKEY" --argjson removed "$A_REMOVED" --argjson kept "$A_KEPT" --argjson ask "$A_ASK" \
  --argjson failed "$A_FAILED" --argjson notes "$A_NOTES" --argjson unknown "$UNKNOWN_CATS" --argjson sweep "$SWEEP_JSON" \
  '{mode:$mode, verdict:"not_assessed", next:"re-run safe-close-inventory.sh: the final verdict comes from that re-run, not from this report"}
   + {($rkey):$removed} + {kept:$kept,
       ask:($ask | group_by(.approve) | map({kind:.[0].kind, approve:.[0].approve, why:.[0].why, ids:map(.id)})),
       failed:$failed, notes:$notes, unknown_categories:$unknown, sweep:$sweep}' \
  || die 3 "could not assemble the report"
[[ "$(jq 'length' <<<"$A_FAILED")" == 0 ]]
