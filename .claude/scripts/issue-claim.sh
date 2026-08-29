#!/usr/bin/env bash
# issue-claim.sh — Claim an issue at PICK time so two threads can't work it at once (issue #873).
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
#   issue-claim.sh --help | -h
#
#   --check          Report the verdict without writing anything.
#   --claim          Take the claim (no-op when already yours).
#   --release        Drop your own claim (idempotent; never a collaborator's).
#   --repo           Act on a named repo instead of the current checkout's.
#   --holder ID      Override the holder token (see above).
#   --json           Machine-readable object on stdout instead of the verdict word.
#   --allow-claimed  Explicit user override; only valid with --claim.
#
# ENVIRONMENT
#   CLAIM_STALE_HOURS     Stale window in hours (default 4).
#   CLAUDE_CLAIM_HOLDER   Holder token, when no --holder is passed.
#   CLAUDE_SESSION_ID     Fallback holder token.
#
# OUTPUT
#   Default: one word on stdout — unclaimed | mine | claimed | stale | unknown.
#            Human-readable refusal / warning / override lines go to stderr, so a
#            caller reading only the exit code still surfaces a clear message.
#   --json:  {"issue":N,"repo":...,"viewer":...,"holder":...,"verdict":...,
#             "claimant":...,"claimant_holder":...,"claimed_at":...,
#             "stale":true|false,"overridden":true|false,"reason":"..."}
#
# EXIT STATUS
#   0  startable / authorized — unclaimed, mine, stale, or an --allow-claimed
#      override; also every successful --claim / --release.
#   1  blocked   — a fresh claim held by another thread or person.
#   2  usage     — bad/missing issue number, unknown or conflicting flags.
#   3  not_found — no such issue.
#   4  unknown   — claim state undetermined. FAIL-CLOSED: treat as claimed.
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
#   issue-claim.sh 873 --release               # -> unclaimed (exit 0)

set -uo pipefail
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" 2>/dev/null >> "$HOME/.claude/script-usage.log" || true

CLAIM_LABEL="in-progress"
CLAIM_MARKER="claude-claim"
GUARD_REF="the issue-claim guard (.claude/rules/issue-planning.md)"

print_help() {
  # Print the leading comment header (everything after the shebang up to the
  # first blank line), stripping the leading "# ".
  awk 'NR == 1 { next } /^$/ { exit } { print }' "$0" | sed 's/^# \{0,1\}//'
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
  [[ -n "$ACTION" ]] && die_usage "only one of --check / --claim / --release may be given (got --$ACTION and $1)"
  ACTION="${1#--}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)      print_help; exit 0 ;;
    --check|--claim|--release) set_action "$1"; shift ;;
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
[[ -z "$ACTION" ]] && die_usage "one of --check / --claim / --release is required"
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

# Extract the newest claim comment's payload. The payload is the JSON object
# between the marker prefix and the closing " -->".
read_claim_field() {
  printf '%s' "$CLAIM_COMMENTS" | jq -r --arg m "$CLAIM_MARKER" --arg f "$1" '
    if length == 0 then ""
    else
      (sort_by(.created_at) | last) as $c
      | ($c.body | capture("<!-- " + $m + ": *(?<p>.*?) *-->") | .p) as $raw
      | ($raw | fromjson) as $payload
      | if $f == "created_at" then $c.created_at
        elif $f == "id" then ($c.id | tostring)
        else ($payload[$f] // "") end
    end' 2>/dev/null || printf ''
}

CLAIMANT_HOLDER="$(read_claim_field holder)"
CLAIMANT="$(read_claim_field login)"
CLAIMED_AT="$(read_claim_field created_at)"

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
  CLAIMANT=""; CLAIMANT_HOLDER=""; CLAIMED_AT=""; IS_STALE="false"
  emit unclaimed 0 "released the claim on issue #$ISSUE_NUMBER"
fi

# --- action: --claim -----------------------------------------------------------
# Already ours: a genuine no-op. A resumed thread or a post-compaction recovery
# re-claims constantly; writing a second marker each time would turn recovery
# into comment spam and break the "one live claim" read.
if [[ "$VERDICT" == "mine" ]]; then
  emit mine 0 "issue #$ISSUE_NUMBER is already claimed by this thread (holder $HOLDER) — no-op"
fi

if [[ "$VERDICT" == "claimed" ]]; then
  if (( ! ALLOW_CLAIMED )); then
    emit claimed 1 "$(describe_claim). Refusing to claim it. Only an explicit per-issue instruction from the user (\"start it anyway\") authorizes taking it, per $GUARD_REF."
  fi
  OVERRIDDEN="true"
fi

PRIOR_HOLDER="$CLAIMANT_HOLDER"
PRIOR_CLAIMANT="$CLAIMANT"

# Create the label idempotently. An existing label is reused, never recreated —
# `gh label create` on an existing name is an error, not a no-op.
# `gh --jq` takes a bare expression — it has no `--arg` passthrough — so the
# label name is matched by jq reading it from the environment instead.
LABEL_EXISTS="$(CLAIM_LABEL="$CLAIM_LABEL" gh label list --limit 200 --json name \
  --jq '[.[].name] | index(env.CLAIM_LABEL) != null' 2>/dev/null || echo "")"
if [[ "$LABEL_EXISTS" != "true" ]]; then
  gh label create "$CLAIM_LABEL" \
    --color FBCA04 \
    --description "A thread is actively working this issue (issue-claim.sh)" \
    >/dev/null 2>&1 || true
fi

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

CLAIM_BODY="$(printf '%s\n\n%s\n' \
  "🔒 Claimed by \`$VIEWER\` for active work. It will be released when this issue's PR merges, when the issue closes, or automatically after ${STALE_HOURS}h of no activity." \
  "<!-- $CLAIM_MARKER: $(jq -cn --arg h "$HOLDER" --arg l "$VIEWER" '{holder: $h, login: $l}') -->")"

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
IS_STALE="false"

if [[ "$OVERRIDDEN" == "true" ]]; then
  emit mine 0 "claimed issue #$ISSUE_NUMBER for holder $HOLDER, overriding a live claim held by ${PRIOR_CLAIMANT:-another account} (holder ${PRIOR_HOLDER:-unknown})"
elif [[ "$VERDICT" == "stale" ]]; then
  emit mine 0 "took over the stale claim on issue #$ISSUE_NUMBER (previously ${PRIOR_CLAIMANT:-an unknown account}, holder ${PRIOR_HOLDER:-unknown}) for holder $HOLDER"
fi
emit mine 0 "claimed issue #$ISSUE_NUMBER for holder $HOLDER"
