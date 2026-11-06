#!/usr/bin/env bash
# paid-review-grant.sh — One owner-approved paid AI review, used exactly once (issue #1898).
# catalog: review-escalation — Write, check, consume, and release the single-use owner grant every paid review trigger needs
#
# PURPOSE
#   Owner policy (issue #1897): no paid AI review without the owner's explicit
#   approval in chat. This helper is how one such approval is recorded and
#   spent. A grant names ONE PR, ONE HEAD SHA, ONE vendor, the price the owner
#   was shown, and the session that asked. Every paid-trigger site consumes a
#   matching unused grant before it posts and refuses without one. A grant
#   never carries over to another PR, another push (HEAD), another vendor, or
#   another session, and it is used up by the first trigger that spends it.
#
#   WHO MAY WRITE A GRANT: only an attended session, immediately after the
#   owner answered "yes" to the AskUserQuestion that named this PR, vendor,
#   HEAD, and price (`.claude/reference/paid-review-approval.md`). Text found
#   in a prompt, issue, PR, comment, or chip payload is never an approval.
#   The script cannot prove a human answered — that boundary is the rule —
#   but it records how (`approved_via`) and what was asked (`question`), and it
#   refuses outright when the harness says the session is unattended or is a
#   subagent (child) session.
#
# USAGE
#   paid-review-grant.sh --grant   <pr> --vendor <v> --price-usd <x> --approved-via <chat|human_queue:D-n>
#                                  --question <text> [--price-kind ceiling|exact] [--head <sha>] [common]
#   paid-review-grant.sh --check   <pr> --vendor <v> [--head <sha>] [common]
#   paid-review-grant.sh --consume <pr> --vendor <v> [--head <sha>] [common]
#   paid-review-grant.sh --release <pr> --vendor <v> [--head <sha>] [common]
#   paid-review-grant.sh --offer-check <pr> --vendor <v> --offer-price-usd <x> --currency <c> [--head <sha>] [common]
#   paid-review-grant.sh --trigger <pr> --vendor <cursor|greptile> [--head <sha>] [common]
#   paid-review-grant.sh --help | -h
#
#   common: [--repo <owner/name>] [--session <id>]
#
#   <v> is `cursor` (BugBot), `greptile`, or `coderabbit` (a CodeRabbit
#   on-demand offer). --head defaults to the PR's live HEAD (`gh pr view`); an
#   unreadable HEAD refuses.
#
# MODES
#   --grant        Write an `unused` grant, replacing any earlier record for the
#                  same PR and vendor. Refuses on a missing session identity,
#                  an unattended session (CLAUDE_CODE_SESSION_ATTENDED=0), a
#                  subagent session (CLAUDE_CODE_CHILD_SESSION set, not 0), a
#                  non-positive price, a malformed HEAD, or an `--approved-via`
#                  that is not `chat` / `human_queue:D-<n>`.
#   --check        Read only. Exit 0 only for a matching, unused grant.
#   --consume      Spend the grant: compare-and-set `unused` -> `consumed` on the
#                  exact record read (session-state.sh --cas), so of two racing
#                  consumers exactly one wins. Callers consume BEFORE posting.
#   --release      Undo a consume after a post that DEFINITELY failed (consumed
#                  -> unused, same session and HEAD only). After an uncertain
#                  outcome, leave the grant consumed.
#   --offer-check  Accept a CodeRabbit on-demand offer (vendor coderabbit only;
#                  any other vendor is a usage error) only under a matching grant
#                  whose approved price is at or above the offer: currency must
#                  be USD and the offer price a positive number; the daily cap
#                  is asked with the offer price, as for --trigger. On success the
#                  grant is consumed; any refusal writes nothing.
#   --trigger      For instruction-driven triggers: check the grant, confirm the
#                  PR is yours (pr-authorship.sh exit 0) and its live HEAD is
#                  the granted one, refuse `price_above_grant` when the vendor's
#                  current rate exceeds the approved price, ask review-daily-cap.sh (a validated `over`
#                  refuses and leaves the grant unused — surface it), consume, consume the Greptile daily budget
#                  (greptile only), then post `@cursor review` / `@greptileai`.
#                  A post or budget failure releases the grant.
#
# OUTPUT
#   One line on stdout: `STATUS=<status>`. Every refusal also prints a visible
#   note on stderr. Statuses:
#     granted available consumed released triggered            (success, exit 0)
#     no_grant grant_head_mismatch grant_session_mismatch grant_used
#     grant_vendor_mismatch grant_lost_race offer_over_price offer_price_invalid
#     offer_currency_invalid session_unknown unattended subagent not_author
#     budget_exhausted daily_cap_over price_above_grant head_unreadable  (refusal, exit 1)
#     grant_unreadable                                        (fail closed, exit 3)
#     trigger_failed                                          (post failed, exit 5)
#
# STATE
#   `.prs["<pr>"].paid_review_grants["<vendor>"]` in ~/.claude/session-state.json,
#   written ONLY by this script through session-state.sh. Record fields: vendor,
#   pr, head_sha, price_usd, price_kind, currency, granted_at, session_id,
#   approved_via, question, status (unused|consumed), consumed_at. A missing
#   state file is "no grant"; an unparseable file or slot is grant_unreadable,
#   which refuses (fail closed) — never "probably fine".
#
# EXIT CODES
#   0 success   1 refusal   2 usage   3 state unreadable / unwritable   5 post failed
#
# SEE ALSO
#   .claude/reference/paid-review-approval.md (the ask contract)
#   .claude/reference/review-policy.md §Paid review authorization

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; n = 1; next } { exit } END { exit(n ? 0 : 1) }' "$0" ||
    { printf '%s: --help header extraction produced no output\n' "$0" >&2; exit 70; }
}

die_usage() { echo "paid-review-grant.sh: $1" >&2; echo "STATUS=usage"; exit 2; }

resolve() {
  local name="$1" c
  for c in "$SELF_DIR/$name" \
           "${HOME:-}/.claude/skills-worktree/.claude/scripts/$name" \
           "${HOME:-}/.claude/scripts/$name" \
           ".claude/scripts/$name"; do
    [[ -x "$c" ]] && { printf '%s' "$c"; return 0; }
  done
  return 1
}

MODE="" PR="" VENDOR="" HEAD="" REPO="" SESSION_ARG=""
PRICE="" PRICE_KIND="ceiling" APPROVED_VIA="" QUESTION=""
OFFER_PRICE="" CURRENCY=""

set_mode() {
  [[ -z "$MODE" ]] || die_usage "only one mode may be given (already have --$MODE)"
  MODE="$1"
}
need_val() { (( $2 >= 2 )) || die_usage "$1 requires a value"; }

while (( $# > 0 )); do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --grant|--check|--consume|--release|--offer-check|--trigger)
      set_mode "${1#--}"
      if (( $# >= 2 )) && [[ "$2" != --* ]]; then PR="$2"; shift; fi ;;
    --vendor)          need_val "$1" $#; VENDOR="$2"; shift ;;
    --head)            need_val "$1" $#; HEAD="$2"; shift ;;
    --repo)            need_val "$1" $#; REPO="$2"; shift ;;
    --session)         need_val "$1" $#; SESSION_ARG="$2"; shift ;;
    --price-usd)       need_val "$1" $#; PRICE="$2"; shift ;;
    --price-kind)      need_val "$1" $#; PRICE_KIND="$2"; shift ;;
    --approved-via)    need_val "$1" $#; APPROVED_VIA="$2"; shift ;;
    --question)        need_val "$1" $#; QUESTION="$2"; shift ;;
    --offer-price-usd) need_val "$1" $#; OFFER_PRICE="$2"; shift ;;
    --currency)        need_val "$1" $#; CURRENCY="$2"; shift ;;
    *) die_usage "unknown argument: $1" ;;
  esac
  shift
done

[[ -n "$MODE" ]] || die_usage "a mode is required (--grant, --check, --consume, --release, --offer-check, --trigger)"
[[ "$PR" =~ ^[1-9][0-9]*$ ]] || die_usage "a PR number is required after --$MODE"
case "$VENDOR" in
  cursor|greptile|coderabbit) ;;
  *) die_usage "--vendor must be cursor, greptile, or coderabbit" ;;
esac
if [[ "$MODE" == "trigger" && "$VENDOR" == "coderabbit" ]]; then
  die_usage "--trigger posts BugBot or Greptile only; accept a CodeRabbit on-demand offer through --offer-check"
fi
if [[ "$MODE" == "offer-check" && "$VENDOR" != "coderabbit" ]]; then
  die_usage "--offer-check accepts a CodeRabbit on-demand offer only; spend a BugBot or Greptile grant through --trigger"
fi

refuse() { # <status> <note> [exit]
  echo "paid-review-grant.sh: PR #$PR $VENDOR: $2 — no paid review (issue #1898)" >&2
  echo "STATUS=$1"
  exit "${3:-1}"
}

command -v jq >/dev/null 2>&1 || refuse grant_unreadable "jq is not available, so no grant can be read" 3
[[ -n "${HOME:-}" ]] || refuse grant_unreadable "HOME is unset, so session state cannot be located" 3

STATE_SH="$(resolve session-state.sh || true)"
[[ -n "$STATE_SH" ]] || refuse grant_unreadable "session-state.sh not found (checked all three paths)" 3
REPO_ARGS=()
[[ -n "$REPO" ]] && REPO_ARGS=(--repo "$REPO")
GH_REPO_ARGS=()
[[ -n "$REPO" ]] && GH_REPO_ARGS=(--repo "$REPO")

# --- session identity: --session, then the harness ids. Never a placeholder:
# a literal `default` matches every session, which is no boundary at all.
SESSION="${SESSION_ARG:-${CLAUDE_CODE_SESSION_ID:-${CLAUDE_SESSION_ID:-}}}"
SESSION="${SESSION#local_}"
case "$SESSION" in
  ""|default|unknown|null) refuse session_unknown "no session identity (--session, CLAUDE_CODE_SESSION_ID, CLAUDE_SESSION_ID), so a grant cannot be bound to this session" ;;
esac
[[ "$SESSION" =~ ^[A-Za-z0-9._:-]+$ ]] || refuse session_unknown "session identity '$SESSION' is malformed"

# --- HEAD: explicit, or the PR's live HEAD.
live_head() {
  gh pr view "$PR" ${GH_REPO_ARGS[@]+"${GH_REPO_ARGS[@]}"} --json headRefOid -q .headRefOid 2>/dev/null
}
if [[ -z "$HEAD" ]]; then
  HEAD="$(live_head || true)"
  [[ -n "$HEAD" ]] || refuse head_unreadable "could not read the PR's HEAD"
fi
HEAD="$(printf '%s' "$HEAD" | tr 'A-F' 'a-f')"
[[ "$HEAD" =~ ^[0-9a-f]{40}$ ]] || refuse head_unreadable "HEAD '$HEAD' is not a full 40-character SHA"

SLOT=".prs[\"$PR\"].paid_review_grants[\"$VENDOR\"]"
now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
is_price() { [[ "$1" =~ ^(0|[1-9][0-9]*)(\.[0-9]+)?$ ]] && awk -v p="$1" 'BEGIN { exit !(p > 0) }'; }

# --- read the slot. Sets RECORD (compact JSON) or exits with a refusal.
RECORD=""
read_record() {
  local out rc=0
  out="$("$STATE_SH" ${REPO_ARGS[@]+"${REPO_ARGS[@]}"} --get-json "$SLOT" 2>/dev/null)" || rc=$?
  if (( rc == 3 )); then refuse no_grant "no owner grant (no session state yet)"; fi
  (( rc == 0 )) || refuse grant_unreadable "session state is unreadable (session-state.sh exit $rc), so no grant can be trusted" 3
  [[ -n "$out" && "$out" != "null" ]] || refuse no_grant "no owner grant for this PR and vendor"
  RECORD="$(jq -c 'if type == "object" then . else error("not an object") end' <<<"$out" 2>/dev/null)" \
    || refuse grant_unreadable "the grant record is not a JSON object" 3
  # A record that does not describe its own slot, or carries an unusable price
  # or currency, is corrupt — refuse rather than guess.
  jq -e --arg v "$VENDOR" --argjson pr "$PR" '
      .vendor == $v and .pr == $pr and (.currency == "USD")
      and ((.price_usd | type) == "number") and .price_usd > 0
      and ((.head_sha // "") | test("^[0-9a-f]{40}$"))
      and ((.status == "unused") or (.status == "consumed"))' <<<"$RECORD" >/dev/null 2>&1 \
    || refuse grant_unreadable "the grant record is malformed" 3
}

# Validate the record against this PR/HEAD/session; usable only when unused.
match_record() {
  local f
  f="$(jq -r '.head_sha' <<<"$RECORD")"
  [[ "$f" == "$HEAD" ]] || refuse grant_head_mismatch "the owner granted HEAD ${f:0:7}, not ${HEAD:0:7} — a new push needs a new approval"
  f="$(jq -r '.session_id // ""' <<<"$RECORD")"
  [[ "$f" == "$SESSION" ]] || refuse grant_session_mismatch "the grant belongs to another session — approvals never carry over"
}
require_unused() {
  [[ "$(jq -r '.status' <<<"$RECORD")" == "unused" ]] || refuse grant_used "this grant was already used — each approval buys one review"
}

consume_record() {
  local new rc=0
  new="$(jq -c --arg at "$(now_iso)" '.status = "consumed" | .consumed_at = $at' <<<"$RECORD")"
  "$STATE_SH" ${REPO_ARGS[@]+"${REPO_ARGS[@]}"} --cas "$SLOT=$new" --expect "$RECORD" >/dev/null 2>&1 || rc=$?
  (( rc == 7 )) && refuse grant_lost_race "another trigger spent this grant first"
  (( rc == 0 )) || refuse grant_unreadable "could not record the grant as used (session-state.sh exit $rc) — not posting" 3
  RECORD="$new"
}

release_record() { # releases RECORD (must be consumed) back to unused
  local new rc=0
  new="$(jq -c '.status = "unused" | .consumed_at = null' <<<"$RECORD")"
  "$STATE_SH" ${REPO_ARGS[@]+"${REPO_ARGS[@]}"} --cas "$SLOT=$new" --expect "$RECORD" >/dev/null 2>&1 || rc=$?
  return "$rc"
}

# Account daily cap (issue #1854, folded in here): an approved review still
# asks review-daily-cap.sh before it spends. A validated `over` refuses BEFORE
# the grant is consumed, so the owner sees the cap and decides (raise it, or
# approve again tomorrow); the grant stays unused. An `unknown` tally or a
# missing helper proceeds with a note — the vendor cap stays the hard stop,
# the same fail-open direction every other cap reader takes.
daily_cap_check() { # <platform> [usd]
  local cap usd="${2:-}" out rc=0
  cap="$(resolve review-daily-cap.sh || true)"
  if [[ -z "$cap" ]]; then
    echo "paid-review-grant.sh: DEGRADED: review-daily-cap.sh not found (checked all three paths) — daily cap unknown, continuing" >&2
    return 0
  fi
  [[ -n "$usd" ]] || usd="$("$cap" "$1" --rate 2>/dev/null)" || usd=""
  [[ "$usd" =~ ^[0-9]+(\.[0-9]+)?$ ]] || usd=0
  out="$("$cap" "$1" --add-usd "$usd" 2>/dev/null)" || rc=$?
  if (( rc == 1 )) && [[ "$(jq -r '.status // ""' <<<"$out" 2>/dev/null)" == "over" ]]; then
    refuse daily_cap_over "the account's $1 daily cap would be exceeded ($(jq -r '"$\(.spent_usd) spent + $\(.add_usd) > $\(.cap_usd) cap"' <<<"$out" 2>/dev/null)) — tell the owner; the grant stays unused"
  fi
  [[ "$(jq -r '.status // ""' <<<"$out" 2>/dev/null)" == "ok" ]] \
    || echo "paid-review-grant.sh: $1 daily cap unknown (rc=$rc) — continuing; the vendor cap stays the hard stop" >&2
  return 0
}

case "$MODE" in
  grant)
    [[ "${CLAUDE_CODE_SESSION_ATTENDED:-}" != "0" ]] \
      || refuse unattended "this session is unattended — only the owner's live answer in an attended session creates a grant"
    # A subagent shares its parent's session id, so the session binding alone
    # would let it mint a grant its parent could spend. It never asks the
    # owner, so it never writes one (paid-review-approval.md).
    case "${CLAUDE_CODE_CHILD_SESSION:-}" in
      ""|0) ;;
      *) refuse subagent "this is a subagent session — only the attended parent, on the owner's live answer, creates a grant" ;;
    esac
    is_price "$PRICE" || die_usage "--price-usd must be a positive number in USD"
    case "$PRICE_KIND" in exact|ceiling) ;; *) die_usage "--price-kind must be exact or ceiling" ;; esac
    [[ "$APPROVED_VIA" == "chat" || "$APPROVED_VIA" =~ ^human_queue:D-[0-9]+$ ]] \
      || die_usage "--approved-via must be chat or human_queue:D-<n>"
    [[ -n "$QUESTION" ]] || die_usage "--question (the exact question the owner answered) is required"
    REC="$(jq -cn --arg v "$VENDOR" --argjson pr "$PR" --arg h "$HEAD" --argjson p "$PRICE" \
      --arg k "$PRICE_KIND" --arg at "$(now_iso)" --arg s "$SESSION" --arg via "$APPROVED_VIA" --arg q "$QUESTION" \
      '{vendor: $v, pr: $pr, head_sha: $h, price_usd: $p, price_kind: $k, currency: "USD",
        granted_at: $at, session_id: $s, approved_via: $via, question: $q,
        status: "unused", consumed_at: null}')"
    RC=0
    "$STATE_SH" ${REPO_ARGS[@]+"${REPO_ARGS[@]}"} --set "$SLOT=$REC" >/dev/null 2>&1 || RC=$?
    (( RC == 0 )) || refuse grant_unreadable "could not write the grant (session-state.sh exit $RC)" 3
    echo "paid-review-grant.sh: PR #$PR $VENDOR: one paid review granted for HEAD ${HEAD:0:7}, up to \$$PRICE ($APPROVED_VIA)" >&2
    echo "STATUS=granted"
    ;;
  check)
    read_record; match_record; require_unused
    echo "STATUS=available"
    ;;
  consume)
    read_record; match_record; require_unused; consume_record
    echo "STATUS=consumed"
    ;;
  release)
    read_record; match_record
    [[ "$(jq -r '.status' <<<"$RECORD")" == "consumed" ]] || refuse no_grant "nothing to release — the grant is not consumed"
    RC=0; release_record || RC=$?
    (( RC == 7 )) && refuse grant_lost_race "the grant changed while releasing it"
    (( RC == 0 )) || refuse grant_unreadable "could not release the grant (session-state.sh exit $RC)" 3
    echo "STATUS=released"
    ;;
  offer-check)
    [[ "$(printf '%s' "$CURRENCY" | tr 'a-z' 'A-Z')" == "USD" ]] \
      || refuse offer_currency_invalid "the offer's currency '${CURRENCY:-missing}' is not USD"
    is_price "$OFFER_PRICE" || refuse offer_price_invalid "the offer's price '${OFFER_PRICE:-missing}' is not a positive number"
    read_record; match_record; require_unused
    APPROVED="$(jq -r '.price_usd' <<<"$RECORD")"
    awk -v o="$OFFER_PRICE" -v a="$APPROVED" 'BEGIN { exit !(o <= a) }' \
      || refuse offer_over_price "the offer (\$$OFFER_PRICE) is above the approved \$$APPROVED"
    daily_cap_check coderabbit "$OFFER_PRICE"
    consume_record
    echo "STATUS=consumed"
    ;;
  trigger)
    read_record; match_record; require_unused
    AUTH_SH="$(resolve pr-authorship.sh || true)"
    [[ -n "$AUTH_SH" ]] || refuse not_author "pr-authorship.sh not found (checked all three paths), so authorship is unknown"
    "$AUTH_SH" "$PR" ${GH_REPO_ARGS[@]+"${GH_REPO_ARGS[@]}"} >/dev/null 2>&1 \
      || refuse not_author "this PR is not confirmed as yours (pr-authorship.sh) — automated writes need your own PR"
    LIVE="$(live_head || true)"
    [[ "$LIVE" == "$HEAD" ]] || refuse grant_head_mismatch "the PR's live HEAD is ${LIVE:0:7}, not the granted ${HEAD:0:7}"
    case "$VENDOR" in cursor) PLATFORM=bugbot ;; greptile) PLATFORM=greptile ;; esac
    # The owner approved a price, not "whatever it costs now": a current rate
    # above the approved one refuses and leaves the grant unused. An unreadable
    # rate proceeds with a note, the same fail-open as the daily cap.
    APPROVED="$(jq -r '.price_usd' <<<"$RECORD")"
    RATE=""
    CAP_SH="$(resolve review-daily-cap.sh || true)"
    [[ -n "$CAP_SH" ]] && RATE="$("$CAP_SH" "$PLATFORM" --rate 2>/dev/null)" || RATE=""
    if [[ "$RATE" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
      awk -v r="$RATE" -v a="$APPROVED" 'BEGIN { exit !(r <= a) }' \
        || refuse price_above_grant "the current $PLATFORM rate (\$$RATE) is above the approved \$$APPROVED — tell the owner; the grant stays unused"
    else
      echo "paid-review-grant.sh: $PLATFORM rate unknown — cannot compare it with the approved \$$APPROVED; continuing" >&2
      RATE=""
    fi
    daily_cap_check "$PLATFORM" "$RATE"
    consume_record
    case "$VENDOR" in
      cursor) BODY="@cursor review" ;;
      greptile) BODY="@greptileai" ;;
    esac
    if [[ "$VENDOR" == "greptile" ]]; then
      BUDGET_SH="$(resolve greptile-budget.sh || true)"
      if [[ -z "$BUDGET_SH" ]] || ! "$BUDGET_SH" --consume >/dev/null 2>&1; then
        release_record || echo "paid-review-grant.sh: could not release the grant after the budget refusal — ask again" >&2
        refuse budget_exhausted "the Greptile daily budget is exhausted or unreadable — self-review, which never satisfies the gate"
      fi
    fi
    # Re-read HEAD right before the post to shrink the push-vs-post window.
    # A PR comment cannot name a SHA, so a push landing after this read is a
    # residual risk (paid-review-approval.md §HEAD race).
    LIVE="$(live_head || true)"
    if [[ "$LIVE" != "$HEAD" ]]; then
      release_record || echo "paid-review-grant.sh: could not release the grant after HEAD moved — ask again" >&2
      refuse grant_head_mismatch "the PR's HEAD moved to ${LIVE:0:7} before posting; the grant was released"
    fi
    if ! gh pr comment "$PR" ${GH_REPO_ARGS[@]+"${GH_REPO_ARGS[@]}"} --body "$BODY" >/dev/null; then
      release_record || echo "paid-review-grant.sh: could not release the grant after the failed post — ask again" >&2
      refuse trigger_failed "posting $BODY failed; the grant was released" 5
    fi
    echo "paid-review-grant.sh: PR #$PR: posted $BODY on HEAD ${HEAD:0:7} under the owner's grant (now used)" >&2
    echo "STATUS=triggered"
    ;;
esac
exit 0
