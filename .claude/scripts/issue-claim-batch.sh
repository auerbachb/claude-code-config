#!/usr/bin/env bash
# issue-claim-batch.sh — Check, claim, renew or release a whole planned batch of issues in one step (issue #2286).
# catalog: backlog-pm — Check, claim, renew or release a planned batch of issues in one call, one JSON verdict per issue
#
# PURPOSE
#   An orchestrator that commits to a batch ("these 30 issues, over the next few
#   hours") must stake the claim on the WHOLE batch when it plans it, not one
#   issue at a time as each launches - otherwise a second orchestrator on
#   another machine can build an overlapping plan in good faith while most of
#   the batch still looks free. This script is the sibling of issue-claim.sh
#   that takes several issue numbers and answers once per issue: yours, already
#   taken (and by whom), or could not tell. The caller works only the issues it
#   got; the rest drop out of its plan with the reason shown.
#
#   Single-issue use stays in issue-claim.sh, byte for byte. This script never
#   re-implements claim rules: every write and every per-issue read is delegated
#   to issue-claim.sh, so the holder, marker, staleness, renewal and fail-closed
#   rules are exactly the ones documented in .claude/reference/issue-claim.md.
#
# HOW IT KEEPS THE API COST BOUNDED
#   --check does not read three endpoints per issue. It reads the repo's
#   `in-progress` label index ONCE (`gh api --paginate .../issues?labels=...`,
#   one page per 100 labeled issues) plus the authenticated user, then:
#     - the issues NOT in the index get ONE more bounded read (a single GraphQL
#       call per 50 of them) for existence and state: an open one is reported
#       `unclaimed` straight away; a CLOSED or nonexistent one is `unknown`
#       (exit 4, not startable), never a startable `unclaimed`;
#     - an issue in the index is checked in full by `issue-claim.sh --check`
#       (that is the usual handful, not the whole batch).
#   So checking 50 free open issues costs 3 calls, not 150. This is the same
#   label-index pre-filter /wave uses; the label is written before the claim
#   comment, so a fresh claim nearly always carries it. The residual (a marker
#   whose label was lost) is documented in issue-claim.md and heals on the
#   holder's next renew; --claim never relies on the index (see below).
#   Batch --check is therefore a PLANNING SCREEN: an `unclaimed` answer may
#   still be a live claim whose label was lost. Only --claim, which re-reads
#   every issue in full, is authoritative.
#   --claim, --renew and --release write per issue, so their cost is per issue.
#
# FAIL-CLOSED
#   A failed or truncated index read (non-zero gh exit, unparseable or non-array
#   output) is NEVER read as "nothing is claimed": every issue in the batch comes
#   back `unknown`. An issue whose own check fails is `unknown`. One issue
#   failing never aborts the others.
#
# CLAIM FLOW
#   1. Batch check as above.
#   2. `claimed` / `unknown` issues are reported as they are and not touched.
#   3. Every other issue (`unclaimed`, `mine`, `stale`) is claimed with
#      `issue-claim.sh N --claim --json --batch LABEL --batch-size S`, where S is
#      the number of issues admitted to the batch. The claim comment says so
#      ("One of S claimed together"). `--claim` re-reads each issue in full, so
#      a marker the index missed still blocks it (verdict `claimed`, exit 1).
#   There is no --allow-claimed here: overriding a live claim is a per-issue
#   user instruction and stays a single-issue call.
#
# USAGE
#   issue-claim-batch.sh --check   N [N ...] [--repo owner/repo] [--holder ID]
#   issue-claim-batch.sh --claim   N [N ...] [--repo owner/repo] [--holder ID]
#                    [--provider NAME] [--device NAME] [--label TEXT] [--batch LABEL]
#   issue-claim-batch.sh --renew   N [N ...] [--repo owner/repo] [--holder ID]
#                    [--provider NAME] [--device NAME] [--label TEXT]
#   issue-claim-batch.sh --release N [N ...] [--repo owner/repo] [--holder ID]
#   issue-claim-batch.sh --help | -h
#
#   --check          Report one verdict per issue; writes nothing.
#   --claim          Claim every proceedable issue as one batch.
#   --renew          Renew each held claim (never acquires); the batch label
#                    and size on each marker carry forward.
#   --release        Drop this HOLDER's claim on each issue (an issue removed
#                    from the plan is released with this, in the same step). An
#                    issue held by another holder is left untouched (exit 0,
#                    verdict claimed); an unreadable one is unknown (exit 4).
#   --batch LABEL    Batch label for --claim (default: b-<MMDDHHMM>-<random>).
#   --holder, --repo, --provider, --device, --label
#                    Passed to issue-claim.sh unchanged; the holder must be one
#                    token for the whole batch (resolved once per call by the
#                    same rules as issue-claim.sh).
#   --json           Accepted and ignored: the output is always JSON lines.
#
# OUTPUT
#   One compact JSON object per issue on stdout, in the order given (duplicates
#   removed). For every issue the object is issue-claim.sh's own --json object
#   (verdict, claimant, claimant_holder, provider, device, label, claimed_at,
#   batch, batch_size when set, reason, ...). An issue that --check found absent
#   from the label index has the same keys with null identity fields and
#   `"source":"label-index"`. One summary line goes to stderr.
#
# EXIT STATUS
#   0  every issue proceedable (unclaimed, mine, stale, or a successful write)
#   1  at least one issue `claimed` by someone else (and none unknown/lost)
#   2  usage error
#   4  at least one issue `unknown` (fail-closed; includes a failed or truncated
#      index read, an issue not found, a write that could not be verified)
#   5  --renew/--release: at least one issue lost or not held (and none unknown);
#      a renewal that found a closed or foreign-held issue
#   Precedence when mixed: 4, then 5, then 1, then 0.
#   70  --help header extraction produced no output (internal defect).
#
# DEPENDENCIES
#   - gh (authenticated), jq, issue-claim.sh in the same directory
#
# EXAMPLES
#   issue-claim-batch.sh --check 101 102 103          # one JSON line per issue
#   issue-claim-batch.sh --claim 101 102 103 --batch round-7
#   issue-claim-batch.sh --renew 101 102 103 --holder "$H"
#   issue-claim-batch.sh --release 102 --holder "$H"  # dropped from the plan

set -uo pipefail

if [[ -n "${HOME:-}" ]]; then
  printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" 2>/dev/null >> "$HOME/.claude/script-usage.log" || true
fi

print_help() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; n = 1; next } { exit } END { exit(n ? 0 : 1) }' "$0" ||
    { printf '%s: --help header extraction produced no output\n' "$0" >&2; exit 70; }
}

die_usage() {
  echo "issue-claim-batch.sh: $1" >&2
  echo "Run with --help for usage." >&2
  exit 2
}

SELF_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd -P)" || die_usage "could not resolve the script directory"
CLAIM_SH="$SELF_DIR/issue-claim.sh"
[[ -x "$CLAIM_SH" ]] || die_usage "issue-claim.sh not found next to this script ($CLAIM_SH)"

ACTION=""
REPO=""
HOLDER_ARG=""
PROVIDER_ARG=""
DEVICE_ARG=""
LABEL_ARG=""
BATCH_ARG=""
ISSUES=()

set_action() {
  [[ -n "$ACTION" ]] && die_usage "only one of --check / --claim / --renew / --release may be given (got --$ACTION and $1)"
  ACTION="${1#--}"
}
need_value() { [[ $# -ge 2 && -n "${2-}" && "${2-}" != --* ]] || die_usage "$1 requires a value"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) print_help; exit 0 ;;
    --check|--claim|--renew|--release) set_action "$1"; shift ;;
    --json) shift ;;
    --repo)     need_value "$@"; REPO="$2"; shift 2 ;;
    --holder)   need_value "$@"; HOLDER_ARG="$2"; shift 2 ;;
    --provider) need_value "$@"; PROVIDER_ARG="$2"; shift 2 ;;
    --device)   need_value "$@"; DEVICE_ARG="$2"; shift 2 ;;
    --label)    need_value "$@"; LABEL_ARG="$2"; shift 2 ;;
    --batch)    need_value "$@"; BATCH_ARG="$2"; shift 2 ;;
    --repo=*|--holder=*|--provider=*|--device=*|--label=*|--batch=*)
      [[ -n "${1#*=}" ]] || die_usage "${1%%=*} requires a value"
      case "$1" in
        --repo=*)     REPO="${1#*=}" ;;
        --holder=*)   HOLDER_ARG="${1#*=}" ;;
        --provider=*) PROVIDER_ARG="${1#*=}" ;;
        --device=*)   DEVICE_ARG="${1#*=}" ;;
        --label=*)    LABEL_ARG="${1#*=}" ;;
        --batch=*)    BATCH_ARG="${1#*=}" ;;
      esac
      shift ;;
    --allow-claimed) die_usage "--allow-claimed is a per-issue user override and is not available in batch mode; use issue-claim.sh for that one issue" ;;
    -*) die_usage "unknown flag: $1" ;;
    *)
      [[ "$1" =~ ^[1-9][0-9]*$ ]] || die_usage "issue numbers must be positive integers, got: $1"
      dup=0
      for existing in ${ISSUES[@]+"${ISSUES[@]}"}; do [[ "$existing" == "$1" ]] && dup=1; done
      (( dup )) || ISSUES+=("$1")
      shift ;;
  esac
done

[[ -n "$ACTION" ]] || die_usage "one of --check / --claim / --renew / --release is required"
(( ${#ISSUES[@]} > 0 )) || die_usage "at least one issue number is required"
if [[ -n "$REPO" ]] && ! [[ "$REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
  die_usage "--repo must be owner/repo, got: $REPO"
fi
if [[ -n "$PROVIDER_ARG$DEVICE_ARG$LABEL_ARG$BATCH_ARG" && "$ACTION" != claim && "$ACTION" != renew ]]; then
  die_usage "--provider / --device / --label / --batch are only valid with --claim or --renew"
fi
if [[ -n "$BATCH_ARG" && "$ACTION" != claim ]]; then
  die_usage "--batch is only valid with --claim (a renewal carries each marker's batch forward)"
fi

for dep in gh jq; do
  command -v "$dep" >/dev/null 2>&1 || { echo "issue-claim-batch.sh: '$dep' not found on PATH" >&2; exit 2; }
done

# Flags every delegated issue-claim.sh call receives unchanged.
COMMON=()
[[ -n "$REPO" ]] && COMMON+=(--repo "$REPO")
[[ -n "$HOLDER_ARG" ]] && COMMON+=(--holder "$HOLDER_ARG")
FACTS=()
[[ -n "$PROVIDER_ARG" ]] && FACTS+=(--provider "$PROVIDER_ARG")
[[ -n "$DEVICE_ARG" ]] && FACTS+=(--device "$DEVICE_ARG")
[[ -n "$LABEL_ARG" ]] && FACTS+=(--label "$LABEL_ARG")

WORK="$(mktemp -d)" || die_usage "could not create a temporary directory"
trap 'rm -rf "$WORK" 2>/dev/null' EXIT

REPO_PREFIX="repos/{owner}/{repo}"
[[ -n "$REPO" ]] && REPO_PREFIX="repos/$REPO"
TOTAL=${#ISSUES[@]}

# result <index> <json> <rc>: record one issue's final object and exit code.
record() { printf '%s\n' "$2" > "$WORK/r.$1"; printf '%s\n' "$3" > "$WORK/rc.$1"; }

# unknown_object <issue> <reason>: the fail-closed object for an issue whose
# state could not be read.
unknown_object() {
  jq -cn --argjson issue "$1" --arg repo "$REPO" --arg holder "$HOLDER_ARG" --arg reason "$2" \
    '{issue: $issue, repo: (if $repo == "" then null else $repo end),
      holder: (if $holder == "" then null else $holder end), verdict: "unknown",
      claimant: null, claimant_holder: null, provider: null, device: null, label: null,
      claim_comment_id: null, claimed_at: null, stale: false, overridden: false,
      reason: $reason}'
}

# run_one <index> <issue> <args...>: run issue-claim.sh for one issue and record
# its JSON object and exit code. Anything that does not yield a JSON object with
# a verdict is `unknown`; one issue never aborts the loop.
run_one() {
  local idx="$1" issue="$2" out rc obj
  shift 2
  out="$("$CLAIM_SH" "$issue" "$@" --json 2>>"$WORK/stderr")"; rc=$?
  if obj="$(printf '%s' "$out" | jq -ce 'select(type == "object" and (.verdict | type) == "string")' 2>/dev/null)" && [[ -n "$obj" ]]; then
    case "$rc" in 0|1|3|4|5) ;; *) obj="$(unknown_object "$issue" "issue-claim.sh exited $rc unexpectedly")"; rc=4 ;; esac
    [[ "$rc" == 3 ]] && rc=4
    record "$idx" "$obj" "$rc"
  else
    record "$idx" "$(unknown_object "$issue" "issue-claim.sh produced no readable result (exit $rc)")" 4
  fi
}

# --- the label index (bounded batch read) ------------------------------------
# Sets INDEX_NUMBERS (space-padded) when the read is complete.
INDEX_NUMBERS=" "
INDEX_ERR=""
VIEWER=""
read_label_index() {
  local raw nums
  VIEWER="$(gh api user --jq '.login' 2>/dev/null || true)"
  if [[ -z "$VIEWER" || "$VIEWER" == "null" ]]; then
    VIEWER=""; INDEX_ERR="could not resolve the authenticated user (gh api user failed)"; return 1
  fi
  if ! raw="$(gh api --paginate "$REPO_PREFIX/issues?labels=in-progress&state=all&per_page=100" 2>"$WORK/index.err")"; then
    INDEX_ERR="could not read the in-progress label index ($(tr '\n' ' ' < "$WORK/index.err"))"; return 1
  fi
  # --paginate emits one JSON array per page. Anything that is not an array of
  # objects with a numeric `.number` is a truncated or damaged read.
  if ! nums="$(printf '%s' "$raw" | jq -rs '
        if length == 0 then error("no pages") else . end
        | [ .[] | if type == "array" then .[] else error("not an array") end
          | .number | if type == "number" then . else error("no number") end ]
        | map(tostring) | join(" ")' 2>/dev/null)"; then
    INDEX_ERR="the in-progress label index came back truncated or unreadable"; return 1
  fi
  INDEX_NUMBERS=" $nums "
}

# index_object <issue>: `unclaimed` for an issue absent from a complete index.
index_object() {
  jq -cn --argjson issue "$1" --arg repo "$REPO" --arg viewer "$VIEWER" --arg holder "$HOLDER_ARG" \
    '{issue: $issue, repo: (if $repo == "" then null else $repo end),
      viewer: $viewer, holder: (if $holder == "" then null else $holder end),
      verdict: "unclaimed", claimant: null, claimant_holder: null,
      provider: null, device: null, label: null, claim_comment_id: null,
      claimed_at: null, stale: false, overridden: false, source: "label-index",
      reason: ("issue #" + ($issue | tostring) + " is not in the in-progress label index - unclaimed, startable")}'
}

# read_states <issue...>: ONE bounded GraphQL read (chunks of 50 aliases) for the
# issues the label index did not list. Writes $WORK/state.<n> = open | closed |
# missing | err for each. A chunk whose read fails or comes back without
# `data.repository` marks its issues `err` (fail-closed, never "exists").
read_states() {
  local chunk=() n q i raw body
  while (( $# > 0 )); do
    chunk=()
    while (( $# > 0 && ${#chunk[@]} < 50 )); do chunk+=("$1"); shift; done
    q="query(\$owner: String!, \$name: String!) { repository(owner: \$owner, name: \$name) {"
    for n in "${chunk[@]}"; do q+=" i$n: issue(number: $n) { number state }"; done
    q+=" } }"
    if [[ -n "$REPO" ]]; then
      raw="$(gh api graphql -f query="$q" -F owner="${REPO%%/*}" -F name="${REPO#*/}" 2>/dev/null)" || true
    else
      raw="$(gh api graphql -f query="$q" -F owner='{owner}' -F name='{repo}' 2>/dev/null)" || true
    fi
    for n in "${chunk[@]}"; do
      body="$(printf '%s' "$raw" | jq -r --arg a "i$n" '
        if (.data.repository | type) != "object" then "err"
        elif (.data.repository[$a] | type) == "object" then (.data.repository[$a].state | ascii_downcase)
        elif ([ .errors[]? | select(.type == "NOT_FOUND" and (.path // [] | .[1]) == $a) ] | length) > 0 then "missing"
        else "err" end' 2>/dev/null || echo err)"
      case "$body" in open|closed|missing) ;; *) body=err ;; esac
      printf '%s\n' "$body" > "$WORK/state.$n"
    done
  done
}

# batch_check: fill r.<i>/rc.<i> for every issue.
batch_check() {
  local i issue st
  local unindexed=()
  if ! read_label_index; then
    for (( i = 0; i < TOTAL; i++ )); do
      record "$i" "$(unknown_object "${ISSUES[$i]}" "$INDEX_ERR - claim state undetermined; treat the issue as claimed (fail-closed)")" 4
    done
    return 0
  fi
  for (( i = 0; i < TOTAL; i++ )); do
    [[ "$INDEX_NUMBERS" == *" ${ISSUES[$i]} "* ]] || unindexed+=("${ISSUES[$i]}")
  done
  (( ${#unindexed[@]} > 0 )) && read_states "${unindexed[@]}"
  for (( i = 0; i < TOTAL; i++ )); do
    issue="${ISSUES[$i]}"
    if [[ "$INDEX_NUMBERS" == *" $issue "* ]]; then
      run_one "$i" "$issue" --check ${COMMON[@]+"${COMMON[@]}"}
      continue
    fi
    st="$(cat "$WORK/state.$issue" 2>/dev/null || echo err)"
    case "$st" in
      open)    record "$i" "$(index_object "$issue")" 0 ;;
      closed)  record "$i" "$(unknown_object "$issue" "issue #$issue is closed - not startable (it is not claimed; reopen it or drop it from the plan)")" 4 ;;
      missing) record "$i" "$(unknown_object "$issue" "issue #$issue not found - not startable (check the number)")" 4 ;;
      *)       record "$i" "$(unknown_object "$issue" "could not read the state of issue #$issue - claim state undetermined; treat the issue as claimed (fail-closed)")" 4 ;;
    esac
  done
}

case "$ACTION" in
  check)
    batch_check ;;

  claim)
    batch_check
    ADMITTED=0
    for (( i = 0; i < TOTAL; i++ )); do
      v="$(jq -r '.verdict' "$WORK/r.$i" 2>/dev/null || echo unknown)"
      case "$v" in unclaimed|mine|stale) ADMITTED=$(( ADMITTED + 1 )) ;; esac
    done
    BATCH_LABEL="${BATCH_ARG:-b-$(date -u +%m%d%H%M)-$RANDOM}"
    for (( i = 0; i < TOTAL; i++ )); do
      v="$(jq -r '.verdict' "$WORK/r.$i" 2>/dev/null || echo unknown)"
      case "$v" in
        unclaimed|mine|stale)
          run_one "$i" "${ISSUES[$i]}" --claim --batch "$BATCH_LABEL" --batch-size "$ADMITTED" \
            ${COMMON[@]+"${COMMON[@]}"} ${FACTS[@]+"${FACTS[@]}"} ;;
      esac
    done ;;

  renew)
    for (( i = 0; i < TOTAL; i++ )); do
      run_one "$i" "${ISSUES[$i]}" --renew ${COMMON[@]+"${COMMON[@]}"} ${FACTS[@]+"${FACTS[@]}"}
    done ;;

  release)
    # Holder-scoped, unlike issue-claim.sh's account-level release: an issue
    # dropped from THIS plan is released only when this holder holds it, so a
    # replacement claim by another thread is never cleared. The check and the
    # release both read the holder the same way (--holder or the default).
    for (( i = 0; i < TOTAL; i++ )); do
      run_one "$i" "${ISSUES[$i]}" --check ${COMMON[@]+"${COMMON[@]}"}
      case "$(jq -r '.verdict' "$WORK/r.$i" 2>/dev/null || echo unknown)" in
        mine)
          # Pin the observed marker: a claim that changed since the check exits 5
          # and is left alone (issue-claim.sh --expect-claim-id).
          cid="$(jq -r '.claim_comment_id // empty' "$WORK/r.$i" 2>/dev/null || true)"
          if [[ -n "$cid" ]]; then
            run_one "$i" "${ISSUES[$i]}" --release --expect-claim-id "$cid" ${COMMON[@]+"${COMMON[@]}"}
          else
            record "$i" "$(unknown_object "${ISSUES[$i]}" "the claim marker id could not be read - nothing released")" 4
          fi ;;
        claimed|stale) record "$i" "$(jq -c '.reason = "claimed by another holder - not released by this batch release"' "$WORK/r.$i")" 0 ;;
      esac
    done ;;
esac

# --- emit and summarize --------------------------------------------------------
WORST=0
N_OK=0; N_CLAIMED=0; N_UNKNOWN=0; N_LOST=0
for (( i = 0; i < TOTAL; i++ )); do
  cat "$WORK/r.$i"
  rc="$(cat "$WORK/rc.$i")"
  case "$rc" in
    0) N_OK=$(( N_OK + 1 )) ;;
    1) N_CLAIMED=$(( N_CLAIMED + 1 )) ;;
    5) N_LOST=$(( N_LOST + 1 )) ;;
    *) N_UNKNOWN=$(( N_UNKNOWN + 1 )) ;;
  esac
done
[[ -s "$WORK/stderr" ]] && cat "$WORK/stderr" >&2
printf 'issue-claim-batch.sh: %s %d issue(s) - %d proceedable, %d claimed, %d unknown, %d not held\n' \
  "$ACTION" "$TOTAL" "$N_OK" "$N_CLAIMED" "$N_UNKNOWN" "$N_LOST" >&2

if (( N_UNKNOWN > 0 )); then WORST=4
elif (( N_LOST > 0 )); then WORST=5
elif (( N_CLAIMED > 0 )); then WORST=1
fi
exit "$WORST"
