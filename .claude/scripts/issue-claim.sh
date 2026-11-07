#!/usr/bin/env bash
# issue-claim.sh — Claim an issue at PICK time so two threads can't work it at once (issue #873).
# catalog: backlog-pm — Claim an issue at pick time so two threads cannot work the same issue at once
#
# PURPOSE
#   Every entry path that starts work on an issue (/start-issue, /subagent Step
#   6.0, a chip-launched coding thread, an ad-hoc "work on #N") used to guard
#   itself by asking "is there an open PR for this issue?" — but a PR is the LAST
#   artifact a thread produces. For the whole plan-and-code window (routinely
#   30+ minutes) that check comes back clean, so a second thread picks the same
#   issue in good faith. This script stakes the claim when work STARTS.
#
#   GitHub is the only source of truth. There is no local claim state — a
#   local file by definition cannot see a sibling thread, let alone another
#   machine. The claim is written as three GitHub artifacts:
#
#     1. the `in-progress` label   — the coarse "someone is working this" bit,
#                                    visible in every issue list at a glance
#     2. the `@me` assignee        — ownership at ACCOUNT level (issue #732)
#     3. a claim comment carrying  — HOLDER identity + the "claimed at" timestamp
#        <!-- claude-claim: {...} -->
#
# WHY A HOLDER, NOT JUST A LOGIN
#   The failure this script exists to prevent is two Claude threads belonging to
#   the SAME human. Both authenticate as the same GitHub login, so "is the
#   assignee me?" answers "yes" in both tabs and blocks nothing. The claim
#   comment therefore records a holder token, and `mine` means *this thread*,
#   not *this account*.
#
#   Holder resolution order:
#     --holder ID  ->  $CLAUDE_CLAIM_HOLDER  ->  $CLAUDE_SESSION_ID
#                  ->  <hostname>:<git toplevel>     (default)
#   The default is honest about its granularity: two threads sharing one
#   checkout resolve to one holder. That is acceptable because CLAUDE.md
#   mandates a worktree per thread, so the mandated workflow always yields
#   distinct holders — but a caller that has a real session id should pass it.
#
# BLOCK AT HOLDER LEVEL, RELEASE AT ACCOUNT LEVEL (deliberate asymmetry)
#   --check/--claim compare HOLDERS, so a sibling thread of yours is blocked.
#   --release compares LOGINS, so a terminal state reached by a different thread
#   of yours (a Phase C merger, a /wrap in another worktree) still clears the
#   claim instead of leaking it. Releasing your own account's claim is always
#   safe; #732 only protects a *collaborator's* claim, and that is still never
#   touched by any action here.
#
# STALE IS A WARNING, NEVER A PERMANENT BLOCK
#   A thread that dies mid-task must not poison the issue forever. A claim older
#   than CLAIM_STALE_HOURS (default 4) reports `stale` and exits 0 — startable.
#   The caller surfaces the warning and proceeds; --claim takes it over.
#
# RENEWAL — HOW LIVE WORK OUTLASTS THE STALE WINDOW (issue #1914)
#   Age is measured from the newest claim comment's GitHub `created_at`, so a
#   holder keeps a long-running claim fresh by RENEWING it: post a new marker,
#   re-read to verify it wins, then delete only this holder's older markers
#   authored by this account. The label and the old marker stay until the new
#   marker exists, so there is never an unclaimed interval.
#   - Renewal is due only once the marker is older than CLAIM_RENEW_MINUTES
#     (default: half the stale window). Inside that, a same-holder call writes
#     nothing — routine resumes cause no comment spam.
#   - --claim by the same holder renews when due (else the old no-op).
#     --renew renews when due and NEVER acquires or takes over: any verdict
#     other than `mine` exits 5 with nothing written.
#   - Renewal needs the marker's payload login AND its comment author to be the
#     viewer; a same holder token from another account is never renewed
#     (--claim warns `renew-not-authorized`, --renew exits 5).
#   - The new marker carries `since` (the original pickup time), so
#     `claimed_since` survives renewals; staleness still uses `created_at`.
#   - CLAIM_RENEW_MINUTES at or past the stale window is rejected (stderr
#     warning) in favour of the default half-window. Exception: with
#     CLAIM_STALE_HOURS=0 there is no window to compare against, so the clamp
#     does not apply (issue #1933 documents this as accepted).
#   - A renewal that loses to a newer foreign marker deletes its own new marker
#     and exits 5 (`superseded`). One that finds its replaced marker gone or the
#     issue closed on re-read (a concurrent --release) withdraws its new marker,
#     never re-adds the label, and exits 5 (`released`); a closed issue is never
#     renewed, due or not. The label/assignee is re-asserted only after
#     verification. A renewal of an already-stale own claim
#     succeeds with reason `renewed-after-expiry` and a stderr warning.
#   - After cleanup, one final re-read (issue #1933) catches a release that
#     landed after verification: no marker of this holder left, or the issue
#     closed -> withdraw, roll back what this run re-added, exit 5 `released`.
#     A surviving marker whose label was removed under it gets the label back.
#   - A not-due same-holder call on an open issue re-adds a missing label or
#     assignee (best effort), so a marker never stays invisible to label-
#     filtering readers (/wave) after a failed or raced re-assert.
#   - Residual race: a takeover that read the claim as stale BEFORE the renewal
#     can still post after verification. Renewing well inside the stale window
#     (the default threshold) is what keeps that window closed in practice.
#     The other residual windows: .claude/reference/issue-claim.md.
#
# FAIL-CLOSED
#   Any indeterminate `gh` result (viewer lookup, issue fetch, comment fetch,
#   timeline fetch) resolves to verdict `unknown`, exit 4. Callers MUST treat
#   `unknown` exactly like `claimed`: skip with a visible note. An `unknown`
#   verdict NEVER reads as permission.
#
# OVERRIDE
#   --allow-claimed proceeds past a fresh foreign claim and SAYS SO in its
#   output. It is only ever an explicit per-issue, per-session chat override
#   from the user ("start it anyway") — never a config default, never inferred
#   from context, never carried forward to the next issue.
#
# USAGE
#   issue-claim.sh <issue_number> --check   [--repo owner/repo] [--holder ID] [--json]
#   issue-claim.sh <issue_number> --claim   [--repo owner/repo] [--holder ID] [--json] [--allow-claimed]
#   issue-claim.sh <issue_number> --release [--repo owner/repo] [--holder ID] [--json]
#   issue-claim.sh <issue_number> --renew   [--repo owner/repo] [--holder ID] [--json]
#   issue-claim.sh --help | -h
#
#   --check          Report the verdict without writing anything.
#   --claim          Take the claim (no-op when already yours; renews when due).
#   --release        Drop your own claim (idempotent; never a collaborator's).
#   --renew          Renew this holder's own claim when due; never acquires.
#   --repo           Act on a named repo instead of the current checkout's.
#   --holder ID      Override the holder token (see above).
#   --json           Machine-readable object on stdout instead of the verdict word.
#   --allow-claimed  Explicit user override; only valid with --claim.
#
# ENVIRONMENT
#   CLAIM_STALE_HOURS     Stale window in hours (default 4).
#   CLAIM_RENEW_MINUTES   Renewal threshold in minutes (default: half the stale
#                         window). A same-holder marker older than this renews.
#   CLAUDE_CLAIM_HOLDER   Holder token, when no --holder is passed.
#   CLAUDE_SESSION_ID     Fallback holder token.
#
# OUTPUT
#   Default: one word on stdout — unclaimed | mine | claimed | stale | unknown.
#            Human-readable refusal / warning / override lines go to stderr, so a
#            caller reading only the exit code still surfaces a clear message.
#   --json:  {"issue":N,"repo":...,"viewer":...,"holder":...,"verdict":...,
#             "claimant":...,"claimant_holder":...,"claimed_at":...,
#             "claimed_since":...,"previous_claimed_at":...,"renewed":true|false,
#             "stale":true|false,"overridden":true|false,"reason":"..."}
#            claimed_at is the GitHub created_at of the live marker (after a
#            renewal, the new one); claimed_since is the original pickup time
#            (payload `since`, else claimed_at); previous_claimed_at is the
#            replaced marker's created_at when renewed is true.
#
# EXIT STATUS
#   0  startable / authorized — unclaimed, mine, stale, or an --allow-claimed
#      override; also every successful --claim / --release.
#   1  blocked   — a fresh claim held by another thread or person.
#   2  usage     — bad/missing issue number, unknown or conflicting flags.
#   3  not_found — no such issue.
#   4  unknown   — claim state undetermined. FAIL-CLOSED: treat as claimed.
#                  Includes a renewal that could not be written or verified.
#   5  not held  — --renew found no claim held by this holder (`not-held`,
#                  `renew-not-authorized`), or a renewal was superseded by a
#                  newer foreign marker (`superseded`) or released under it /
#                  the issue closed (`released`). Stop and report lost
#                  ownership; nothing of anyone else's was touched.
#   70  --help header extraction produced no output (internal defect).
#
# DEPENDENCIES
#   - gh (authenticated)
#   - jq
#
# EXAMPLES
#   issue-claim.sh 873 --check                 # -> unclaimed (exit 0)
#   issue-claim.sh 873 --claim                 # -> mine      (exit 0)
#   issue-claim.sh 873 --check                 # -> claimed   (exit 1, in another thread)
#   issue-claim.sh 873 --claim --allow-claimed # -> mine      (exit 0, override stated)
#   issue-claim.sh 873 --renew --holder "$H"   # -> mine      (exit 0; renewed when due)
#   issue-claim.sh 873 --release               # -> unclaimed (exit 0)

set -uo pipefail
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" 2>/dev/null >> "$HOME/.claude/script-usage.log" || true

CLAIM_LABEL="in-progress"
CLAIM_MARKER="claude-claim"
GUARD_REF="the issue-claim guard (.claude/rules/issue-planning.md)"

print_help() {
  # Print the leading comment header (everything after the shebang up to the
  # first blank line), stripping the leading "# ".
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; n = 1; next } { exit } END { exit(n ? 0 : 1) }' "$0" ||
    { printf '%s: --help header extraction produced no output\n' "$0" >&2; exit 70; }
}

die_usage() {
  echo "issue-claim.sh: $1" >&2
  echo "Run with --help for usage." >&2
  exit 2
}

# --- arg parsing ---------------------------------------------------------------
ISSUE_NUMBER=""
REPO=""
ACTION=""
HOLDER_ARG=""
JSON=0
ALLOW_CLAIMED=0

set_action() {
  [[ -n "$ACTION" ]] && die_usage "only one of --check / --claim / --release / --renew may be given (got --$ACTION and $1)"
  ACTION="${1#--}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)      print_help; exit 0 ;;
    --check|--claim|--release|--renew) set_action "$1"; shift ;;
    --json)         JSON=1; shift ;;
    --allow-claimed) ALLOW_CLAIMED=1; shift ;;
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
    --) shift; break ;;
    -*) die_usage "unknown flag: $1" ;;
    *)
      [[ -n "$ISSUE_NUMBER" ]] && die_usage "unexpected positional argument: $1"
      ISSUE_NUMBER="$1"; shift ;;
  esac
done

[[ -z "$ISSUE_NUMBER" ]] && die_usage "<issue_number> is required"
[[ "$ISSUE_NUMBER" =~ ^[1-9][0-9]*$ ]] || die_usage "<issue_number> must be a positive integer, got: $ISSUE_NUMBER"
[[ -z "$ACTION" ]] && die_usage "one of --check / --claim / --release / --renew is required"
if [[ -n "$REPO" ]] && ! [[ "$REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
  die_usage "--repo must be owner/repo, got: $REPO"
fi
# --allow-claimed is a write-time override; on --check or --release it would be
# silently inert, and a silently-inert override flag is how an override leaks
# into a config default. Reject it outright instead.
if (( ALLOW_CLAIMED )) && [[ "$ACTION" != "claim" ]]; then
  die_usage "--allow-claimed is only valid with --claim"
fi

for dep in gh jq; do
  command -v "$dep" >/dev/null 2>&1 || { echo "issue-claim.sh: '$dep' not found on PATH" >&2; exit 2; }
done

STALE_HOURS="${CLAIM_STALE_HOURS:-4}"
if ! [[ "$STALE_HOURS" =~ ^[0-9]+$ ]]; then
  die_usage "CLAIM_STALE_HOURS must be a non-negative integer, got: $STALE_HOURS"
fi
# Force base 10: a leading zero (`08`) passes the digit check but is invalid
# octal in shell arithmetic.
STALE_HOURS=$(( 10#$STALE_HOURS ))
# Renewal threshold: half the stale window by default, so live work renews well
# before any other holder can read its claim as stale.
RENEW_MINUTES="${CLAIM_RENEW_MINUTES:-$(( STALE_HOURS * 30 ))}"
if ! [[ "$RENEW_MINUTES" =~ ^[0-9]+$ ]]; then
  die_usage "CLAIM_RENEW_MINUTES must be a non-negative integer, got: $RENEW_MINUTES"
fi
RENEW_MINUTES=$(( 10#$RENEW_MINUTES ))
# A threshold at or past the stale window would let another holder read live
# work as stale (and take it over) before renewal is ever due. Fall back to the
# default half-window instead of honouring it. STALE_HOURS=0 is exempt on
# purpose: every claim is stale at once there, so no threshold can keep it
# fresh, and rejecting it would turn --check/--release into usage errors too
# (accepted residual, issue #1933).
if [[ -n "${CLAIM_RENEW_MINUTES:-}" ]] && (( STALE_HOURS > 0 && RENEW_MINUTES * 60 >= STALE_HOURS * 3600 )); then
  echo "issue-claim.sh: warning — CLAIM_RENEW_MINUTES=$RENEW_MINUTES is not below the ${STALE_HOURS}h stale window; using the default $(( STALE_HOURS * 30 ))m instead" >&2
  RENEW_MINUTES=$(( STALE_HOURS * 30 ))
fi

# --- holder resolution ---------------------------------------------------------
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

# --- API path helpers ----------------------------------------------------------
# {owner}/{repo} resolves from the current checkout unless --repo names one.
REPO_PREFIX="repos/{owner}/{repo}"
[[ -n "$REPO" ]] && REPO_PREFIX="repos/$REPO"

# Select the repo via GH_REPO rather than a `--repo` argument array: an empty
# array expanded under `set -u` is an unbound-variable error in bash 3.2, which
# is the shell macOS ships. GH_REPO is read natively by every `gh` subcommand
# and by the {owner}/{repo} placeholder, so one export covers all of them.
[[ -n "$REPO" ]] && export GH_REPO="$REPO"

# --- emit helper ---------------------------------------------------------------
# Populated as the state is read; emit() serializes whatever is known.
VIEWER=""
VERDICT=""
CLAIMANT=""
CLAIMANT_HOLDER=""
CLAIMED_AT=""
CLAIMED_SINCE=""
PREVIOUS_CLAIMED_AT=""
RENEWED="false"
MARKER_ID=""
MARKER_AUTHOR=""
MARKER_SINCE=""
IS_STALE="false"
OVERRIDDEN="false"

# emit <verdict> <exit_code> <reason>
emit() {
  local verdict="$1" code="$2" reason="$3"
  if [[ "$JSON" -eq 1 ]]; then
    jq -cn \
      --argjson issue "$ISSUE_NUMBER" \
      --arg repo "$REPO" \
      --arg viewer "$VIEWER" \
      --arg holder "$HOLDER" \
      --arg verdict "$verdict" \
      --arg claimant "$CLAIMANT" \
      --arg claimant_holder "$CLAIMANT_HOLDER" \
      --arg claimed_at "$CLAIMED_AT" \
      --arg claimed_since "$CLAIMED_SINCE" \
      --arg previous_claimed_at "$PREVIOUS_CLAIMED_AT" \
      --argjson renewed "$RENEWED" \
      --argjson stale "$IS_STALE" \
      --argjson overridden "$OVERRIDDEN" \
      --arg reason "$reason" \
      '{issue: $issue,
        repo: (if $repo == "" then null else $repo end),
        viewer: (if $viewer == "" then null else $viewer end),
        holder: $holder,
        verdict: $verdict,
        claimant: (if $claimant == "" then null else $claimant end),
        claimant_holder: (if $claimant_holder == "" then null else $claimant_holder end),
        claimed_at: (if $claimed_at == "" then null else $claimed_at end),
        claimed_since: (if $claimed_since == "" then null else $claimed_since end),
        previous_claimed_at: (if $previous_claimed_at == "" then null else $previous_claimed_at end),
        renewed: $renewed,
        stale: $stale,
        overridden: $overridden,
        reason: $reason}'
  else
    printf '%s\n' "$verdict"
  fi
  # Non-startable verdicts, the stale warning, and the override statement all go
  # to stderr so a caller reading only the exit code still surfaces a message.
  case "$verdict" in
    claimed|unknown) echo "issue-claim.sh: $reason" >&2 ;;
    stale)           echo "issue-claim.sh: $reason" >&2 ;;
    *)               [[ "$code" -eq 5 ]] && echo "issue-claim.sh: $reason" >&2 ;;
  esac
  [[ "$OVERRIDDEN" == "true" ]] && echo "issue-claim.sh: OVERRIDE — proceeding past a live claim on issue #$ISSUE_NUMBER because --allow-claimed was passed. This is only valid as an explicit per-issue instruction from the user; it is never a default." >&2
  exit "$code"
}

fail_closed() {
  emit unknown 4 "$1 — claim state undetermined; treat issue #$ISSUE_NUMBER as claimed (fail-closed per $GUARD_REF)"
}

# --- resolve the authenticated viewer ------------------------------------------
VIEWER="$(gh api user --jq '.login' 2>/dev/null || true)"
if [[ -z "$VIEWER" || "$VIEWER" == "null" ]]; then
  fail_closed "could not resolve the authenticated user (gh api user failed)"
fi

# --- read the issue ------------------------------------------------------------
ERR_FILE="$(mktemp)"
trap 'rm -f "$ERR_FILE" 2>/dev/null' EXIT

if ! ISSUE_JSON="$(gh api "$REPO_PREFIX/issues/$ISSUE_NUMBER" 2>"$ERR_FILE")"; then
  # ERE for BSD/macOS grep portability (pr-authorship.sh lesson).
  if grep -qiE "http 404|not found|could not resolve|no such" "$ERR_FILE"; then
    emit unknown 3 "issue #$ISSUE_NUMBER not found${REPO:+ in $REPO} — cannot act"
  fi
  fail_closed "gh api failed reading issue #$ISSUE_NUMBER ($(tr '\n' ' ' < "$ERR_FILE"))"
fi

HAS_LABEL="$(printf '%s' "$ISSUE_JSON" | jq -r --arg l "$CLAIM_LABEL" '[.labels[]?.name] | index($l) != null' 2>/dev/null || echo "ERR")"
[[ "$HAS_LABEL" == "ERR" ]] && fail_closed "could not parse issue #$ISSUE_NUMBER labels"
ASSIGNEES="$(printf '%s' "$ISSUE_JSON" | jq -r '[.assignees[]?.login] | join(" ")' 2>/dev/null || echo "ERR")"
[[ "$ASSIGNEES" == "ERR" ]] && fail_closed "could not parse issue #$ISSUE_NUMBER assignees"

# --- read the claim comment ----------------------------------------------------
# The marker is an HTML comment so it renders invisibly, and carries the holder
# token + claimant login as JSON. Newest matching comment wins.
if ! COMMENTS_JSON="$(gh api --paginate "$REPO_PREFIX/issues/$ISSUE_NUMBER/comments?per_page=100" 2>"$ERR_FILE")"; then
  fail_closed "gh api failed reading issue #$ISSUE_NUMBER comments ($(tr '\n' ' ' < "$ERR_FILE"))"
fi

# --paginate concatenates one JSON array per page; -s flattens them into one.
CLAIM_COMMENTS="$(printf '%s' "$COMMENTS_JSON" | jq -s --arg m "$CLAIM_MARKER" \
  '[ .[] | .[]? | select(.body != null and (.body | contains("<!-- " + $m + ":"))) ]' 2>/dev/null || echo "ERR")"
[[ "$CLAIM_COMMENTS" == "ERR" ]] && fail_closed "could not parse issue #$ISSUE_NUMBER comments"

# Select the winning (newest) claim comment and parse its payload. The payload
# is the JSON object between the marker prefix and the closing " -->". Ties on
# created_at break on the comment id, so "which marker wins" is deterministic —
# renewal verification compares winners by id. One jq pass emits the winner's
# fields separated by US (0x1f): a non-whitespace IFS keeps empty fields
# positional, which a tab would not. An unparseable winner yields nothing (no
# claim comment), exactly as before.
#
# parse_winner <claim-comments-json> -> sets W_ID W_AUTHOR W_HOLDER W_LOGIN W_SINCE W_AT
parse_winner() {
  W_ID=""; W_AUTHOR=""; W_HOLDER=""; W_LOGIN=""; W_SINCE=""; W_AT=""
  local rec
  rec="$(printf '%s' "$1" | jq -r --arg m "$CLAIM_MARKER" '
    if length == 0 then ""
    else
      (sort_by(.created_at, .id) | last) as $c
      | ($c.body | capture("<!-- " + $m + ": *(?<p>.*?) *-->") | .p | fromjson) as $p
      | [($c.id // ""), ($c.user.login // ""), ($p.holder // ""), ($p.login // ""),
         ($p.since // ""), ($c.created_at // "")]
      | map(tostring) | join("\u001f")
    end' 2>/dev/null || printf '')"
  [[ -z "$rec" ]] && return 0
  IFS=$'\x1f' read -r W_ID W_AUTHOR W_HOLDER W_LOGIN W_SINCE W_AT <<<"$rec"
}

# read_claim_comments -> stdout: the claim-marker comments as one JSON array.
# Returns non-zero on any read or parse failure (callers fail closed). Used for
# the renewal's verification re-read; the initial read above keeps its own
# distinct error messages.
read_claim_comments() {
  local raw
  raw="$(gh api --paginate "$REPO_PREFIX/issues/$ISSUE_NUMBER/comments?per_page=100" 2>"$ERR_FILE")" || return 1
  printf '%s' "$raw" | jq -s --arg m "$CLAIM_MARKER" \
    '[ .[] | .[]? | select(.body != null and (.body | contains("<!-- " + $m + ":"))) ]' 2>/dev/null
}

parse_winner "$CLAIM_COMMENTS"
MARKER_ID="$W_ID"
MARKER_AUTHOR="$W_AUTHOR"
CLAIMANT_HOLDER="$W_HOLDER"
CLAIMANT="$W_LOGIN"
CLAIMED_AT="$W_AT"
MARKER_SINCE="$W_SINCE"

HAS_CLAIM_COMMENT=0
[[ -n "$CLAIMANT_HOLDER" ]] && HAS_CLAIM_COMMENT=1

# --- fallback timestamp: the label's most recent `labeled` timeline event ------
# Only needed when the label was applied without a claim comment (a human
# labelling the issue by hand). Skipped otherwise so the common path stays at
# three API reads.
if [[ "$HAS_LABEL" == "true" && "$HAS_CLAIM_COMMENT" -eq 0 ]]; then
  if ! TIMELINE_JSON="$(gh api --paginate "$REPO_PREFIX/issues/$ISSUE_NUMBER/timeline?per_page=100" 2>"$ERR_FILE")"; then
    fail_closed "gh api failed reading issue #$ISSUE_NUMBER timeline ($(tr '\n' ' ' < "$ERR_FILE"))"
  fi
  CLAIMED_AT="$(printf '%s' "$TIMELINE_JSON" | jq -rs --arg l "$CLAIM_LABEL" '
    [ .[] | .[]? | select(.event == "labeled" and .label.name == $l) ]
    | if length == 0 then "" else (sort_by(.created_at) | last | .created_at) end' 2>/dev/null || printf '')"
fi

# --- staleness -----------------------------------------------------------------
# Portable epoch conversion: GNU date and BSD date disagree on -d/-j, so parse
# the ISO-8601 timestamp arithmetically instead of shelling out to either.
iso_to_epoch() {
  local ts="$1"
  [[ -z "$ts" ]] && { printf ''; return; }
  printf '%s' "$ts" | awk '
    match($0, /^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})/) {
      y = substr($0,1,4)+0; mo = substr($0,6,2)+0; d = substr($0,9,2)+0
      h = substr($0,12,2)+0; mi = substr($0,15,2)+0; s = substr($0,18,2)+0
      # Days since the Unix epoch via the civil-from-days algorithm.
      yy = y - (mo <= 2 ? 1 : 0)
      era = int((yy >= 0 ? yy : yy - 399) / 400)
      yoe = yy - era * 400
      doy = int((153 * (mo + (mo > 2 ? -3 : 9)) + 2) / 5) + d - 1
      doe = yoe * 365 + int(yoe/4) - int(yoe/100) + doy
      days = era * 146097 + doe - 719468
      print days * 86400 + h * 3600 + mi * 60 + s
    }'
}

# claimed_since: the original pickup time. A renewed marker carries it as the
# payload `since`; an unparseable or absent `since` falls back to created_at.
CLAIMED_SINCE="$CLAIMED_AT"
if [[ -n "$MARKER_SINCE" && -n "$(iso_to_epoch "$MARKER_SINCE")" ]]; then
  CLAIMED_SINCE="$MARKER_SINCE"
fi

NOW_EPOCH="$(date -u +%s)"
CLAIMED_EPOCH="$(iso_to_epoch "$CLAIMED_AT")"
AGE_SECONDS=""
if [[ -n "$CLAIMED_EPOCH" ]]; then
  AGE_SECONDS=$(( NOW_EPOCH - CLAIMED_EPOCH ))
fi

is_stale() {
  # A claim with no readable timestamp cannot be aged out. Fail closed: it stays
  # a live claim rather than expiring instantly into "startable".
  [[ -z "$AGE_SECONDS" ]] && return 1
  (( AGE_SECONDS > STALE_HOURS * 3600 ))
}

# --- verdict -------------------------------------------------------------------
# A claim exists when EITHER artifact is present: the comment (written by this
# script) or the label (which a human may apply by hand). Requiring both would
# let a half-written claim read as unclaimed.
CLAIM_EXISTS=0
[[ "$HAS_LABEL" == "true" || "$HAS_CLAIM_COMMENT" -eq 1 ]] && CLAIM_EXISTS=1

if (( ! CLAIM_EXISTS )); then
  VERDICT="unclaimed"
elif [[ "$HAS_CLAIM_COMMENT" -eq 1 && "$CLAIMANT_HOLDER" == "$HOLDER" ]]; then
  VERDICT="mine"
elif is_stale; then
  VERDICT="stale"
  IS_STALE="true"
else
  VERDICT="claimed"
fi

viewer_owns_claim() {
  # Account-level ownership, for --release only (see the header's asymmetry
  # note). True when the claim comment is the viewer's, or when there is no
  # claim comment but the viewer is assigned alongside the label.
  if [[ "$HAS_CLAIM_COMMENT" -eq 1 ]]; then
    [[ "$CLAIMANT" == "$VIEWER" ]]
  else
    [[ " $ASSIGNEES " == *" $VIEWER "* ]]
  fi
}

describe_claim() {
  local who="${CLAIMANT:-an unknown account}"
  local when="${CLAIMED_AT:-an unrecorded time}"
  printf 'issue #%s is already being worked — claimed by %s (holder %s) at %s' \
    "$ISSUE_NUMBER" "$who" "${CLAIMANT_HOLDER:-unknown}" "$when"
}

# --- action: --check -----------------------------------------------------------
if [[ "$ACTION" == "check" ]]; then
  case "$VERDICT" in
    unclaimed) emit unclaimed 0 "issue #$ISSUE_NUMBER is unclaimed — startable" ;;
    mine)      emit mine 0 "issue #$ISSUE_NUMBER is already claimed by this thread (holder $HOLDER) — startable" ;;
    stale)     emit stale 0 "$(describe_claim), which is older than the ${STALE_HOURS}h stale window — proceeding is allowed; surface this as a warning, not a block" ;;
    claimed)   emit claimed 1 "$(describe_claim). Skipping. Only an explicit per-issue instruction from the user (\"start it anyway\") authorizes starting it, per $GUARD_REF." ;;
  esac
fi

# --- action: --release ---------------------------------------------------------
if [[ "$ACTION" == "release" ]]; then
  if (( ! CLAIM_EXISTS )); then
    emit unclaimed 0 "issue #$ISSUE_NUMBER holds no claim — nothing to release"
  fi
  if ! viewer_owns_claim; then
    # Never touch a collaborator's claim (issue #732). Not an error: releasing
    # what isn't yours was never the job.
    emit "$VERDICT" 0 "issue #$ISSUE_NUMBER is claimed by ${CLAIMANT:-another account}, not you ($VIEWER) — left untouched"
  fi

  RELEASE_ERRORS=0

  # ORDER MATTERS: comments first, label last.
  #
  # A release can fail part-way, and the two possible half-states are not
  # equally safe. The `in-progress` label is the cheap index every batch reader
  # uses to narrow a backlog before calling --check at all (`/wave` Step 2), so
  # a claim comment left WITHOUT the label is invisible to those readers and
  # reads as unclaimed. The reverse — label without comment — still shows up in
  # every batch scan and still blocks. Removing the label last makes the label a
  # superset of the claim at every intermediate point, so a partial failure
  # degrades toward over-blocking (which expires on its own) rather than toward
  # a missed claim (which does not).
  while IFS= read -r cid; do
    [[ -z "$cid" ]] && continue
    gh api -X DELETE "$REPO_PREFIX/issues/comments/$cid" >/dev/null 2>"$ERR_FILE" || RELEASE_ERRORS=1
  done < <(printf '%s' "$CLAIM_COMMENTS" | jq -r --arg v "$VIEWER" \
    '.[] | select((.user.login // "") == $v) | .id' 2>/dev/null || true)

  # Ordering alone is not enough — the label must also be WITHHELD when a comment
  # delete failed. Dropping it anyway would produce exactly the comment-without-
  # label state the ordering exists to prevent, just one step later.
  if (( ! RELEASE_ERRORS )); then
    EDIT_ARGS=()
    [[ "$HAS_LABEL" == "true" ]] && EDIT_ARGS+=(--remove-label "$CLAIM_LABEL")
    [[ " $ASSIGNEES " == *" $VIEWER "* ]] && EDIT_ARGS+=(--remove-assignee "$VIEWER")
    if (( ${#EDIT_ARGS[@]} > 0 )); then
      gh issue edit "$ISSUE_NUMBER" "${EDIT_ARGS[@]}" >/dev/null 2>"$ERR_FILE" || RELEASE_ERRORS=1
    fi
  fi

  if (( RELEASE_ERRORS )); then
    fail_closed "release of issue #$ISSUE_NUMBER partially failed ($(tr '\n' ' ' < "$ERR_FILE"))"
  fi
  CLAIMANT=""; CLAIMANT_HOLDER=""; CLAIMED_AT=""; CLAIMED_SINCE=""; IS_STALE="false"
  emit unclaimed 0 "released the claim on issue #$ISSUE_NUMBER"
fi

# --- shared write helpers ------------------------------------------------------
# Create the label idempotently. An existing label is reused, never recreated —
# `gh label create` on an existing name is an error, not a no-op.
# `gh --jq` takes a bare expression — it has no `--arg` passthrough — so the
# label name is matched by jq reading it from the environment instead.
ensure_label() {
  local exists
  exists="$(CLAIM_LABEL="$CLAIM_LABEL" gh label list --limit 200 --json name \
    --jq '[.[].name] | index(env.CLAIM_LABEL) != null' 2>/dev/null || echo "")"
  if [[ "$exists" != "true" ]]; then
    gh label create "$CLAIM_LABEL" \
      --color FBCA04 \
      --description "A thread is actively working this issue (issue-claim.sh)" \
      >/dev/null 2>&1 || true
  fi
}

# claim_body <payload-json> -> the visible claim comment, marker included.
claim_body() {
  printf '%s\n\n%s\n' \
    "🔒 Claimed by \`$VIEWER\` for active work. It will be released when this issue's PR merges or when the issue closes; it becomes stale if not renewed within ${STALE_HOURS}h." \
    "<!-- $CLAIM_MARKER: $1 -->"
}

# --- renewal (issue #1914) -----------------------------------------------------
renew_due() {
  [[ -n "$AGE_SECONDS" ]] && (( AGE_SECONDS > RENEW_MINUTES * 60 ))
}

# Issue-snapshot predicates (take the issue JSON as $1).
issue_is_closed()  { [[ "$(printf '%s' "$1" | jq -r '.state // ""' 2>/dev/null)" == "closed" ]]; }
issue_has_label()  { [[ "$(printf '%s' "$1" | jq -r --arg l "$CLAIM_LABEL" '[.labels[]?.name] | index($l) != null' 2>/dev/null)" == "true" ]]; }
issue_has_viewer() { [[ "$(printf '%s' "$1" | jq -r --arg v "$VIEWER" '[.assignees[]?.login] | index($v) != null' 2>/dev/null)" == "true" ]]; }

# repair_claim_metadata (issue #1933): a not-due, authorized, same-holder call
# on an open issue re-adds a missing label and/or viewer assignee. The marker is
# the claim; the label is the index batch readers (/wave) filter on, so a fresh
# marker without it reads as unclaimed to them. Reaches that state: a failed
# label re-assert after a renewal POST (exit 4), or a release that removed the
# label after a renewal's final re-read. Best effort — a failed repair warns and
# leaves the verdict alone; the next call tries again.
#
# Why this cannot resurrect a release in flight: the issue is read before the
# comments, and --release deletes markers before it removes the label. So
# "label gone, marker present" here means the label went first — never the
# middle of a release of this marker.
repair_claim_metadata() {
  local args=()
  [[ "$HAS_LABEL" != "true" ]] && args+=(--add-label "$CLAIM_LABEL")
  [[ " $ASSIGNEES " != *" $VIEWER "* ]] && args+=(--add-assignee "@me")
  (( ${#args[@]} == 0 )) && return 0
  # The caller's open check used the startup snapshot; an issue closed since
  # then must not be re-labelled. Re-read right before the edit, and once
  # more after it to roll back a close that landed in between (narrows the
  # window; no compare-and-set exists on GitHub).
  local fresh=""
  if ! fresh="$(gh api "$REPO_PREFIX/issues/$ISSUE_NUMBER" 2>/dev/null)" || issue_is_closed "$fresh"; then
    return 0
  fi
  [[ "$HAS_LABEL" != "true" ]] && ensure_label
  if gh issue edit "$ISSUE_NUMBER" "${args[@]}" >/dev/null 2>"$ERR_FILE"; then
    REPAIR_NOTE="; re-asserted the missing label/assignee"
    if fresh="$(gh api "$REPO_PREFIX/issues/$ISSUE_NUMBER" 2>/dev/null)" && issue_is_closed "$fresh"; then
      local undo=()
      [[ "$HAS_LABEL" != "true" ]] && undo+=(--remove-label "$CLAIM_LABEL")
      [[ " $ASSIGNEES " != *" $VIEWER "* ]] && undo+=(--remove-assignee "$VIEWER")
      if gh issue edit "$ISSUE_NUMBER" "${undo[@]}" >/dev/null 2>&1; then
        REPAIR_NOTE="; the issue closed during the label/assignee repair, which was rolled back"
      else
        REPAIR_NOTE="; the issue closed during the label/assignee repair and rolling it back failed — clear it with: issue-claim.sh $ISSUE_NUMBER --release"
      fi
    fi
  else
    echo "issue-claim.sh: warning — issue #$ISSUE_NUMBER carries this holder's marker but lacks the in-progress label or assignee, and re-adding them failed ($(tr '\n' ' ' < "$ERR_FILE")); label-filtering readers (/wave) may not see the claim until the next --renew or --claim repairs it" >&2
  fi
}
REPAIR_NOTE=""

# withdraw_markers <ids-newline> <context>: best-effort delete of this run's
# own markers. Each id must come from this run (the POST or its nonce).
withdraw_markers() {
  local rid
  while IFS= read -r rid; do
    [[ -z "$rid" ]] && continue
    gh api -X DELETE "$REPO_PREFIX/issues/comments/$rid" >/dev/null 2>&1 \
      || echo "issue-claim.sh: warning — could not withdraw this run's renewal marker $rid on issue #$ISSUE_NUMBER $2; clear it with: issue-claim.sh $ISSUE_NUMBER --release" >&2
  done <<<"$1"
}

# emit_renew_released <label-note>: exit 5 `released`, reporting the parsed
# winner (W_*) as the current claimant when it is not this holder's.
emit_renew_released() {
  local v="unclaimed"
  if [[ -n "$W_ID" ]] && ! { [[ "$W_HOLDER" == "$HOLDER" && "$W_AUTHOR" == "$VIEWER" ]]; }; then
    v="claimed"; CLAIMANT="$W_LOGIN"; CLAIMANT_HOLDER="$W_HOLDER"; CLAIMED_AT="$W_AT"; CLAIMED_SINCE="$W_AT"
  else
    CLAIMANT=""; CLAIMANT_HOLDER=""; CLAIMED_AT=""; CLAIMED_SINCE=""
  fi
  IS_STALE="false"
  emit "$v" 5 "released — the claim on issue #$ISSUE_NUMBER was released (or the issue closed) while this renewal was in flight; this run's marker was withdrawn and $1 — ownership is lost, stop and report"
}

# emit_renew_superseded: exit 5 `superseded`, reporting the parsed foreign
# winner (W_*). The caller has already withdrawn this run's own markers.
emit_renew_superseded() {
  CLAIMANT="$W_LOGIN"; CLAIMANT_HOLDER="$W_HOLDER"; CLAIMED_AT="$W_AT"
  CLAIMED_SINCE="$W_AT"; MARKER_ID="$W_ID"; MARKER_AUTHOR="$W_AUTHOR"
  # A renewed winner carries its original pickup time as `since`.
  if [[ -n "$W_SINCE" && -n "$(iso_to_epoch "$W_SINCE")" ]]; then
    CLAIMED_SINCE="$W_SINCE"
  fi
  local v="claimed" w_epoch
  w_epoch="$(iso_to_epoch "$W_AT")"
  if [[ -n "$w_epoch" ]] && (( $(date -u +%s) - w_epoch > STALE_HOURS * 3600 )); then
    v="stale"; IS_STALE="true"
  else
    IS_STALE="false"
  fi
  emit "$v" 5 "superseded — a newer claim by ${W_LOGIN:-an unknown account} (holder ${W_HOLDER:-unknown}) won issue #$ISSUE_NUMBER while this renewal was in flight; ownership is lost — stop and report"
}

# The holder token alone is not proof of ownership: another account could pass
# the same string. Renewal additionally needs the marker's payload login and
# its comment author to be the viewer — the account whose own comments the
# cleanup step is allowed to delete.
renew_authorized() {
  [[ "$CLAIMANT" == "$VIEWER" && "$MARKER_AUTHOR" == "$VIEWER" ]]
}

# winner_is_ours: the parsed winner (W_*) is a viewer-authored marker for this
# holder other than the one being replaced.
winner_is_ours() {
  [[ -n "$W_ID" && "$W_ID" != "$1" && "$W_HOLDER" == "$HOLDER" \
     && "$W_AUTHOR" == "$VIEWER" && "$W_LOGIN" == "$VIEWER" ]]
}

# own_run_markers <claim-comments-json> -> ids (one per line) of the
# viewer-authored markers carrying this run's nonce (payload `run`). The nonce
# is the only proof a marker is this run's own: a sibling same-holder renewal's
# marker is otherwise indistinguishable, so nothing is ever reconciled or
# withdrawn by holder or by id order.
own_run_markers() {
  printf '%s' "$1" | jq -r --arg v "$VIEWER" --arg r "$RUN_NONCE" --arg m "$CLAIM_MARKER" '
    .[] | select((.user.login // "") == $v)
    | select((try (.body | capture("<!-- " + $m + ": *(?<p>.*?) *-->") | .p | fromjson | .run) catch "") == $r)
    | .id' 2>/dev/null || true
}

# do_renew: create a new marker, verify it wins, then delete this holder's older
# viewer-authored markers. Always exits via emit. The order is what keeps the
# claim continuously held: the label and the old marker stay in place until the
# new marker is verified, and a failure at any step leaves at least one live
# marker of ours behind (over-blocking, which expires) rather than none.
do_renew() {
  local old_id="$MARKER_ID" old_at="$CLAIMED_AT" since="$CLAIMED_SINCE"
  local was_stale=0 new_id="" post_out="" post_err="" verify="" payload issue_now="" post_id=""
  is_stale && was_stale=1

  # A closed issue is terminal: its claim is being (or was) released, so a
  # renewal must not resurrect it.
  if [[ "$(printf '%s' "$ISSUE_JSON" | jq -r '.state // ""' 2>/dev/null)" == "closed" ]]; then
    emit "$VERDICT" 5 "not-held — issue #$ISSUE_NUMBER is closed; its claim is not renewed — nothing written"
  fi

  # Per-run nonce: identifies this run's own marker on re-read (own_run_markers).
  RUN_NONCE="$(date -u +%s)-$$-$RANDOM$RANDOM"
  payload="$(jq -cn --arg h "$HOLDER" --arg l "$VIEWER" --arg s "$since" --arg r "$RUN_NONCE" \
    '{holder: $h, login: $l, since: $s, run: $r}')"
  # `gh api` POST (not `gh issue comment`) so the response carries the new
  # comment's id — the identity verification compares.
  if post_out="$(gh api -X POST "$REPO_PREFIX/issues/$ISSUE_NUMBER/comments" \
       -f "body=$(claim_body "$payload")" 2>"$ERR_FILE")"; then
    new_id="$(printf '%s' "$post_out" | jq -r '.id // empty' 2>/dev/null || true)"
    post_id="$new_id"
  else
    post_err="$(tr '\n' ' ' < "$ERR_FILE")"
  fi

  # Verification re-read. A failed POST may still have landed (a timeout after
  # the write), so it is re-read too and reconciled rather than assumed lost.
  if ! verify="$(read_claim_comments)"; then
    if [[ -z "$new_id" ]]; then
      fail_closed "renew-failed — could not post the renewal marker on issue #$ISSUE_NUMBER (${post_err:-no comment id returned}) and could not re-read to reconcile; the existing marker was left in place"
    fi
    fail_closed "renew-unverified — posted renewal marker $new_id on issue #$ISSUE_NUMBER but could not re-read to verify it; no older marker was deleted"
  fi
  parse_winner "$verify"

  if [[ -z "$new_id" ]]; then
    # The POST reported failure but may have landed. Reconcile ONLY by this
    # run's nonce — never by holder or id order, which cannot tell this run's
    # marker from a sibling renewal's. Not found: nothing of ours landed.
    new_id="$(own_run_markers "$verify" | tail -n 1)"
    if [[ -z "$new_id" ]]; then
      fail_closed "renew-failed — could not post the renewal marker on issue #$ISSUE_NUMBER (${post_err:-no comment id returned}) and no marker of this run is on the re-read; nothing was deleted — retry"
    fi
  fi
  post_id="$new_id"

  # Concurrent release (e.g. /wrap after merge): it deletes the replaced marker
  # and then the label. If the replaced marker is gone or the issue closed, the
  # claim was released under us — withdraw this run's marker(s), leave the
  # label alone, and report lost ownership rather than resurrect the claim.
  if ! issue_now="$(gh api "$REPO_PREFIX/issues/$ISSUE_NUMBER" 2>"$ERR_FILE")"; then
    fail_closed "renew-unverified — posted the renewal marker${new_id:+ $new_id} on issue #$ISSUE_NUMBER but could not re-read the issue to confirm it is still open ($(tr '\n' ' ' < "$ERR_FILE")); no older marker was deleted"
  fi
  local issue_closed=0 old_gone=0 concurrent_own=0
  [[ "$(printf '%s' "$issue_now" | jq -r '.state // ""' 2>/dev/null)" == "closed" ]] && issue_closed=1
  [[ "$(printf '%s' "$verify" | jq -r --arg old "$old_id" \
        'any(.[]; (.id | tostring) == $old)' 2>/dev/null)" == "false" ]] && old_gone=1
  # A missing replaced marker is NOT a release when another renewal of this
  # same holder (a heartbeat --renew racing a resume --claim) already won: the
  # winner is a newer viewer-authored marker of ours that this run did not post,
  # and the label that renewal re-asserted is still present. Withdrawing then
  # would delete the sibling's live marker and leave the issue unclaimed.
  # post_id is the id this run created (from the POST, or reconciled by this
  # run's nonce from an errored-but-landed POST), so it never names a sibling's.
  if (( old_gone && ! issue_closed )) && winner_is_ours "$old_id" \
     && [[ -n "$post_id" && "$W_ID" != "$post_id" ]] \
     && [[ "$(printf '%s' "$issue_now" | jq -r --arg l "$CLAIM_LABEL" \
           '[.labels[]?.name] | index($l) != null' 2>/dev/null)" == "true" ]]; then
    concurrent_own=1
  fi
  if (( issue_closed || (old_gone && ! concurrent_own) )); then
    withdraw_markers "$({ printf '%s\n' "$new_id"; own_run_markers "$verify"; } | sort -u)" "after a concurrent release"
    emit_renew_released "the label left as found"
  fi

  if [[ -n "$new_id" ]] && { [[ "$W_ID" == "$new_id" ]] || winner_is_ours "$old_id"; }; then
    # Re-assert the label/assignee only now, once the claim is confirmed still
    # held — doing it before the POST would re-add a label a concurrent release
    # had just removed.
    ensure_label
    if ! gh issue edit "$ISSUE_NUMBER" \
         --add-label "$CLAIM_LABEL" --add-assignee "@me" >/dev/null 2>"$ERR_FILE"; then
      fail_closed "renew-failed — could not re-assert the label/assignee on issue #$ISSUE_NUMBER ($(tr '\n' ' ' < "$ERR_FILE")); the renewal marker was left in place and the next --renew or --claim re-adds the label"
    fi
    # Verified: a marker of ours, newer than the one replaced, wins. Clean up
    # every OTHER viewer-authored marker for this holder — never a different
    # holder's, never a collaborator's.
    new_id="$W_ID"
    local cleanup_failed=0 cid
    while IFS= read -r cid; do
      [[ -z "$cid" ]] && continue
      gh api -X DELETE "$REPO_PREFIX/issues/comments/$cid" >/dev/null 2>&1 || cleanup_failed=1
    done < <(printf '%s' "$verify" | jq -r --arg v "$VIEWER" --arg h "$HOLDER" \
      --arg keep "$new_id" --arg m "$CLAIM_MARKER" '
      .[] | select((.user.login // "") == $v and ((.id | tostring) != $keep))
      | select((try (.body | capture("<!-- " + $m + ": *(?<p>.*?) *-->") | .p | fromjson | .holder) catch "") == $h)
      | .id' 2>/dev/null || true)
    (( cleanup_failed )) && echo "issue-claim.sh: warning — renewed issue #$ISSUE_NUMBER but could not delete an older marker of this holder; the duplicate is inert (the newest marker wins) and the next renewal or release removes it" >&2

    # Final consistency re-read (issue #1933). The verification snapshot can be
    # stale by now: a --release that ran after it deleted the markers and the
    # label, and the re-assert above would have put a label back on a released
    # claim. Re-read once and judge on the fresh state. The replaced marker is
    # deliberately not consulted here — cleanup just deleted it. This narrows
    # the window; it cannot close it (no compare-and-set on GitHub), and a
    # failed re-read keeps the already-verified renewal.
    local final="" final_issue="" final_ok=1 kept_id="$new_id"
    if ! final="$(read_claim_comments)"; then
      final_ok=0
    elif ! final_issue="$(gh api "$REPO_PREFIX/issues/$ISSUE_NUMBER" 2>"$ERR_FILE")"; then
      final_ok=0
    fi
    if (( ! final_ok )); then
      echo "issue-claim.sh: warning — renewed issue #$ISSUE_NUMBER but the final consistency re-read failed; the renewal was already verified, so it stands" >&2
    else
      parse_winner "$final"
      local f_closed=0 f_ours=0 kept_present=0
      issue_is_closed "$final_issue" && f_closed=1
      [[ -n "$W_ID" && "$W_HOLDER" == "$HOLDER" && "$W_AUTHOR" == "$VIEWER" \
         && "$W_LOGIN" == "$VIEWER" ]] && f_ours=1
      [[ "$(printf '%s' "$final" | jq -r --arg k "$kept_id" \
            'any(.[]; (.id | tostring) == $k)' 2>/dev/null)" == "true" ]] && kept_present=1
      if (( ! f_closed && f_ours )); then
        # Still held (this run's marker, or a sibling renewal of this holder).
        # The label follows the marker: put back whatever a racing release
        # removed after the re-assert above.
        local fix=()
        issue_has_label "$final_issue" || fix+=(--add-label "$CLAIM_LABEL")
        issue_has_viewer "$final_issue" || fix+=(--add-assignee "@me")
        if (( ${#fix[@]} > 0 )); then
          if ! gh issue edit "$ISSUE_NUMBER" "${fix[@]}" >/dev/null 2>"$ERR_FILE"; then
            fail_closed "renew-failed — the label/assignee on issue #$ISSUE_NUMBER was removed after this renewal re-asserted it, and re-adding it failed ($(tr '\n' ' ' < "$ERR_FILE")); the renewal marker was left in place and the next --renew or --claim re-adds the label"
          fi
        fi
        new_id="$W_ID"
      else
        local mine_ids
        mine_ids="$(own_run_markers "$final")"
        withdraw_markers "$mine_ids" "after a concurrent release"
        if (( ! f_closed && kept_present )); then
          # This run's marker is still there but a newer foreign one wins.
          emit_renew_superseded
        fi
        # Released under us (or closed). Roll back only what this run added —
        # the label/assignee absent before the re-assert — and only when no
        # marker at all is left, so a newer claim's label is never stripped.
        local rest
        rest="$(printf '%s' "$final" | jq -c --arg ids "$mine_ids" \
          '($ids | split("\n")) as $w | [ .[] | select(((.id | tostring) as $i | $w | index($i)) | not) ]' 2>/dev/null || printf '')"
        parse_winner "${rest:-[]}"
        local note="the label left as found"
        local undo=()
        if [[ -n "$rest" && -z "$W_ID" ]]; then
          issue_has_label "$issue_now" || { issue_has_label "$final_issue" && undo+=(--remove-label "$CLAIM_LABEL"); }
          issue_has_viewer "$issue_now" || { issue_has_viewer "$final_issue" && undo+=(--remove-assignee "$VIEWER"); }
        fi
        if (( ${#undo[@]} > 0 )); then
          if gh issue edit "$ISSUE_NUMBER" "${undo[@]}" >/dev/null 2>"$ERR_FILE"; then
            note="the label/assignee this run re-added were rolled back"
          else
            note="the label/assignee this run re-added could NOT be rolled back — clear them with: issue-claim.sh $ISSUE_NUMBER --release"
          fi
        fi
        emit_renew_released "$note"
      fi
    fi

    MARKER_ID="$new_id"; MARKER_AUTHOR="$VIEWER"
    CLAIMANT="$VIEWER"; CLAIMANT_HOLDER="$HOLDER"
    PREVIOUS_CLAIMED_AT="$old_at"; CLAIMED_AT="$W_AT"; CLAIMED_SINCE="$since"
    IS_STALE="false"; RENEWED="true"
    if (( was_stale )); then
      echo "issue-claim.sh: warning — the claim on issue #$ISSUE_NUMBER had already aged past the ${STALE_HOURS}h stale window before this renewal; another holder could have taken it over in that gap" >&2
      emit mine 0 "renewed-after-expiry — renewed the expired claim on issue #$ISSUE_NUMBER for holder $HOLDER (previous marker $old_at)"
    fi
    emit mine 0 "renewed — renewed the claim on issue #$ISSUE_NUMBER for holder $HOLDER (previous marker $old_at)"
  fi

  if [[ -n "$W_ID" && "$W_ID" != "$old_id" && "$W_ID" != "$new_id" ]]; then
    # A newer marker that is not ours won the race. Remove our own new marker
    # (best effort) so it can never resurface as the winner later, and report
    # the winner. Nothing of the winner's is touched.
    # new_id is this run's marker (from the POST or reconciled by nonce).
    withdraw_markers "$({ printf '%s\n' "$new_id"; own_run_markers "$verify"; } | sort -u)" "after it was superseded"
    emit_renew_superseded
  fi

  fail_closed "renew-unverified — the renewal marker${new_id:+ $new_id} on issue #$ISSUE_NUMBER was not found on re-read; no older marker was deleted"
}

# --- action: --renew -----------------------------------------------------------
# Renew-only: a heartbeat caller must never acquire or take over an issue, so
# anything but this holder's own claim exits 5 with nothing written.
if [[ "$ACTION" == "renew" ]]; then
  if [[ "$VERDICT" != "mine" ]]; then
    emit "$VERDICT" 5 "not-held — issue #$ISSUE_NUMBER is not claimed by this thread (holder $HOLDER; verdict $VERDICT); --renew never acquires or takes over a claim — nothing written"
  fi
  if ! renew_authorized; then
    emit claimed 5 "renew-not-authorized — the claim marker on issue #$ISSUE_NUMBER carries holder $HOLDER but was written by ${MARKER_AUTHOR:-an unknown account} for ${CLAIMANT:-an unknown account}, not $VIEWER — nothing written"
  fi
  # A closed issue is terminal whether or not renewal is due (issue #1933): a
  # heartbeat on a closed issue must hear "stop", not `mine`/0. Same output as
  # do_renew's own closed check.
  if issue_is_closed "$ISSUE_JSON"; then
    emit "$VERDICT" 5 "not-held — issue #$ISSUE_NUMBER is closed; its claim is not renewed — nothing written"
  fi
  if ! renew_due; then
    repair_claim_metadata
    emit mine 0 "issue #$ISSUE_NUMBER is claimed by this thread (holder $HOLDER); renewal not due (threshold ${RENEW_MINUTES}m) — no-op$REPAIR_NOTE"
  fi
  do_renew
fi

# --- action: --claim -----------------------------------------------------------
# Already ours: a genuine no-op. A resumed thread or a post-compaction recovery
# re-claims constantly; writing a second marker each time would turn recovery
# into comment spam and break the "one live claim" read.
#
# Renewal (issue #1914): once the marker is older than the renewal threshold, a
# same-holder --claim renews it instead, so a resumed long-running thread keeps
# its claim fresh. Inside the threshold it stays the old silent no-op.
if [[ "$VERDICT" == "mine" ]]; then
  if renew_due; then
    if renew_authorized; then
      do_renew
    fi
    echo "issue-claim.sh: warning — renew-not-authorized: the claim marker on issue #$ISSUE_NUMBER carries holder $HOLDER but was written by ${MARKER_AUTHOR:-an unknown account} for ${CLAIMANT:-an unknown account}, not $VIEWER; it was not renewed" >&2
  elif renew_authorized && ! issue_is_closed "$ISSUE_JSON"; then
    # Not due: the same label/assignee repair --renew does (issue #1933). A
    # closed issue keeps the old silent no-op — never re-label a closed issue.
    repair_claim_metadata
  fi
  emit mine 0 "issue #$ISSUE_NUMBER is already claimed by this thread (holder $HOLDER) — no-op$REPAIR_NOTE"
fi

if [[ "$VERDICT" == "claimed" ]]; then
  if (( ! ALLOW_CLAIMED )); then
    emit claimed 1 "$(describe_claim). Refusing to claim it. Only an explicit per-issue instruction from the user (\"start it anyway\") authorizes taking it, per $GUARD_REF."
  fi
  OVERRIDDEN="true"
fi

PRIOR_HOLDER="$CLAIMANT_HOLDER"
PRIOR_CLAIMANT="$CLAIMANT"

ensure_label

if ! gh issue edit "$ISSUE_NUMBER" \
     --add-label "$CLAIM_LABEL" --add-assignee "@me" >/dev/null 2>"$ERR_FILE"; then
  fail_closed "could not write the claim on issue #$ISSUE_NUMBER ($(tr '\n' ' ' < "$ERR_FILE"))"
fi

# Stale takeover / override: drop our OWN stale markers so exactly one live
# claim comment of ours remains and staleness is measured from the new claim.
#
# A collaborator's claim comment is deliberately left in place even here (#732):
# deleting another person's comment is a write to their content, and an
# --allow-claimed override authorizes starting the work, not editing someone
# else's writing. Leaving it is safe — every read takes the newest claim
# comment, which is the one written just below.
if (( HAS_CLAIM_COMMENT )); then
  while IFS= read -r cid; do
    [[ -z "$cid" ]] && continue
    gh api -X DELETE "$REPO_PREFIX/issues/comments/$cid" >/dev/null 2>&1 || true
  done < <(printf '%s' "$CLAIM_COMMENTS" | jq -r --arg v "$VIEWER" \
    '.[] | select((.user.login // "") == $v) | .id' 2>/dev/null || true)
fi

CLAIM_BODY="$(claim_body "$(jq -cn --arg h "$HOLDER" --arg l "$VIEWER" '{holder: $h, login: $l}')")"

if ! gh issue comment "$ISSUE_NUMBER" --body "$CLAIM_BODY" >/dev/null 2>"$ERR_FILE"; then
  # ROLL BACK the label + assignee this run added. A half-written claim (marker
  # present, holder absent) is worse than no claim: `mine` requires a parsed
  # claim comment, so the very thread that wrote the label reads its own claim
  # back as a foreign `claimed` and cannot re-claim without --allow-claimed —
  # while every other thread stays blocked too. Leave the issue as we found it.
  COMMENT_ERR="$(tr '\n' ' ' < "$ERR_FILE")"
  ROLLBACK_ARGS=()
  [[ "$HAS_LABEL" != "true" ]] && ROLLBACK_ARGS+=(--remove-label "$CLAIM_LABEL")
  [[ " $ASSIGNEES " != *" $VIEWER "* ]] && ROLLBACK_ARGS+=(--remove-assignee "$VIEWER")
  if (( ${#ROLLBACK_ARGS[@]} == 0 )); then
    fail_closed "could not post the claim comment on issue #$ISSUE_NUMBER ($COMMENT_ERR); this run added no marker of its own, so nothing was left behind"
  fi
  if gh issue edit "$ISSUE_NUMBER" "${ROLLBACK_ARGS[@]}" >/dev/null 2>&1; then
    fail_closed "could not post the claim comment on issue #$ISSUE_NUMBER ($COMMENT_ERR); the label/assignee this run added were rolled back, so the issue is unclaimed — retry"
  fi
  fail_closed "could not post the claim comment on issue #$ISSUE_NUMBER ($COMMENT_ERR) AND could not roll the label/assignee back; the issue carries a holderless marker that expires in ${STALE_HOURS}h — clear it with: issue-claim.sh $ISSUE_NUMBER --release"
fi

CLAIMANT="$VIEWER"
CLAIMANT_HOLDER="$HOLDER"
CLAIMED_AT="$(date -u +%FT%TZ)"
# Prefer the marker's GitHub created_at — the timestamp every later --check
# reads — over the local clock. Best effort: a failed re-read keeps the clock.
if POSTED_COMMENTS="$(read_claim_comments)"; then
  parse_winner "$POSTED_COMMENTS"
  if [[ "$W_AUTHOR" == "$VIEWER" && "$W_HOLDER" == "$HOLDER" && -n "$(iso_to_epoch "$W_AT")" ]]; then
    CLAIMED_AT="$W_AT"
  fi
fi
CLAIMED_SINCE="$CLAIMED_AT"
IS_STALE="false"

if [[ "$OVERRIDDEN" == "true" ]]; then
  emit mine 0 "claimed issue #$ISSUE_NUMBER for holder $HOLDER, overriding a live claim held by ${PRIOR_CLAIMANT:-another account} (holder ${PRIOR_HOLDER:-unknown})"
elif [[ "$VERDICT" == "stale" ]]; then
  emit mine 0 "took over the stale claim on issue #$ISSUE_NUMBER (previously ${PRIOR_CLAIMANT:-an unknown account}, holder ${PRIOR_HOLDER:-unknown}) for holder $HOLDER"
fi
emit mine 0 "claimed issue #$ISSUE_NUMBER for holder $HOLDER"
