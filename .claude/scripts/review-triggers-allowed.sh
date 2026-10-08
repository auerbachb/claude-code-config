#!/usr/bin/env bash
# review-triggers-allowed.sh — which AI reviewers may a caller invite on this PR's HEAD?
# catalog: review-escalation — One tier-aware answer for every reviewer-trigger path: which AI reviewers may be invited on the PR's current HEAD, with a lifetime-cap claim ledger
#
# PURPOSE
#   A repo may declare review tiers in its `.claude/pm-config.md` (issue #1724),
#   and merge-gate.sh enforces them. The trigger paths did not: /fixpr Step 3b,
#   pr-preflight.sh and maybe-trigger-ai-review.sh still invited CodeRabbit,
#   CodeAnt and Graphite on every push whatever the tier, and BugBot on every
#   intermediate HEAD of a `full` PR. The agent meant to save money spent it
#   (issue #1749). This is the one place that turns the PR's tier into "which
#   reviewers may be invited now", so every trigger path asks the same question
#   and gets the same answer. Rules: .claude/reference/review-policy.md
#   "Trigger eligibility".
#
# USAGE
#   review-triggers-allowed.sh <pr> [--repo <owner/name>] [--base <ref>] [--head <sha>] [--mode-only]
#   review-triggers-allowed.sh <pr> --claim <reviewer> [--repo <o/n>] [--base <ref>] [--head <sha>]
#   review-triggers-allowed.sh <pr> --release <reviewer> [--repo <o/n>]
#   review-triggers-allowed.sh --help | -h
#
#   <reviewer>    codeant | cursor | coderabbit | graphite
#   --repo        Repository (default: gh's current repo). Forwarded to
#                 review-tier.sh, and the ledger is scoped to it.
#   --base        The PR's base branch, forwarded to review-tier.sh.
#   --head        The HEAD the caller observed (a pushed SHA). When the PR's
#                 live HEAD differs, every reviewer is deferred (`head_moved`).
#   --mode-only   Stop once the mode is known: no PR facts are read. For the
#                 CI workflow, which only needs to know "tier-aware or not".
#   --claim       Re-evaluate, and when <reviewer> is allowed record one
#                 invitation in the ledger BEFORE the caller posts. Exit 0 =
#                 claimed, post now; exit 1 = denied, do not post.
#   --release     Undo one claim after a post that definitely failed, so a
#                 failed attempt never counts against a lifetime cap.
#
# MODES (the `mode` field)
#   legacy       The repo has no `## Review policy` (review-tier.sh policy
#                "absent"). Nothing else is read and `reviewers` is null:
#                callers run their unchanged pre-#1749 code. A claim or a
#                release in this mode is a no-op that exits 0.
#   tiered       A policy is present (or invalid, which resolves to `full`).
#                The per-reviewer decisions below apply.
#   fail_closed  The tier could not be resolved and the local checkout either
#                has a `## Review policy` section, cannot be read, or is not
#                the target repo. Every reviewer is denied, deferred, reason
#                `tier_unresolved`. Only a provably policy-free repo falls
#                back to legacy, so an unreadable policy never spends.
#
# RULES (mode tiered), first match wins per reviewer
#   any gate     graphite: excluded `tier_excluded` (never on a tier-aware repo)
#   ci-only      every reviewer: excluded `tier_excluded`
#   ci+codeant-one-round
#                cursor, coderabbit: excluded `tier_excluded`
#                codeant: excluded `round_completed` once a completed CodeAnt
#                round exists on any commit (lib/codeant-round.jq — the merge
#                gate's own definition); excluded `lifetime_cap` once one
#                invitation exists; then the CI gate; then allowed.
#   full         codeant: excluded `lifetime_cap` after one invitation; then
#                the CI gate; then allowed.
#                cursor: excluded `escalation_off` when the policy sets
#                REVIEW_ESCALATION=off; excluded `lifetime_cap` after two
#                invitations; then the CI gate; deferred `head_not_settled`
#                until HEAD has been observed for the settle threshold; excluded
#                `refused_head` when BugBot already refused this HEAD for a
#                usage limit (bugbot-refused-head.sh, fail-open); deferred
#                `daily_cap` when review-daily-cap.sh answers a validated
#                `over` — asked LAST, `unknown` posts; then allowed.
#                coderabbit: only as the CodeAnt-unavailable fallback —
#                allowed `codeant_unavailable` once CodeAnt was invited and
#                no CodeAnt artifact appeared within the timeout (after the CI
#                gate); deferred `codeant_pending` inside that window;
#                otherwise excluded `not_fallback`.
#   Before the per-gate rules, after the static exclusions above: deferred
#   `head_moved` (see --head) and deferred `facts_unreadable` (a PR read
#   failed). The CI gate is BUILD CI on HEAD — `ci-status.sh
#   --exclude-reviewers`, so a reviewer's own check can never hold it — and
#   defers with `ci_pending`, `ci_red` or `ci_unknown`: nothing is invited
#   while CI on HEAD is red or pending.
#   Greptile is never in scope: it stays escalate-review.sh's last resort.
#   The CodeRabbit hourly caps (cr-review-hourly.sh) stay with the callers.
#
# KINDS
#   allowed   invite now (claim first).
#   excluded  nothing to post for this reviewer — the answer will not change
#             by waiting. A caller counts it as done.
#   deferred  not now; the answer can change by itself (CI finishes, HEAD
#             settles, the ET day rolls over). A caller re-asks later.
#
# LIFETIME COUNTS
#   A reviewer's invitation count is the MAX of two sources:
#     • visible trigger comments on the PR, any commit: issue comments whose
#       trimmed body is exactly the trigger, from any author except the four
#       reviewer bots themselves;
#     • this machine's ledger, `.prs["<N>"].review_trigger_ledger.<reviewer>`
#       in ~/.claude/session-state.json, scoped to the repo.
#   Comments cover other machines and the CI workflow; the ledger covers the
#   seconds before GitHub lists a fresh comment, and concurrent local runs.
#   A claim writes the ledger with session-state.sh --cas, so of two racing
#   claims at a cap only one wins; the loser re-evaluates (up to 3 times).
#
# SETTLED HEAD
#   Build CI green on HEAD, AND the HEAD observed for at least the settle
#   threshold. The observation time is the LATEST of: the HEAD commit's
#   committer date, the newest head_ref_pushed / head_ref_force_pushed
#   timeline event (the anchor pr-preflight.sh uses), and the earliest
#   check-run created on HEAD (GitHub's own clock, at about push time). An
#   unreadable anchor is never settled.
#
# CODEANT UNAVAILABLE
#   CodeAnt was invited (count >= 1) and no `codeant-ai[bot]` comment
#   (created or edited), review, or `codeant-ai` check-run on HEAD appeared at
#   or after the newest invitation within the timeout. CLI failures are never
#   evidence: only the GitHub App's own artifacts are.
#
# CONFIG
#   Two optional keys in the local checkout's `.claude/pm-config.md`, section
#   `## Complexity triggers`, each overridden by an environment variable:
#     TRIGGER_SETTLE_SECONDS=600        COMPLEXITY_TRIGGER_SETTLE_SECONDS
#     CODEANT_UNAVAILABLE_SECONDS=1800  COMPLEXITY_CODEANT_UNAVAILABLE_SECONDS
#   A value must be a non-negative integer; anything else warns on stderr and
#   uses the default.
#
# OUTPUT
#   One JSON line on stdout (all modes):
#     {"pr":N,"mode":"legacy|tiered|fail_closed","gate":..,"tier":..,
#      "policy":..,"escalation":"on|off","head_sha":"<sha>"|null,
#      "ci":"green|pending|red|unknown"|null,
#      "settled":{"settled":bool,"age_s":N|null,"threshold_s":N}|null,
#      "codeant":{"round_completed":bool,"invited":bool,
#                 "available":true|false|null}|null,
#      "reviewers":{"codeant":{"allowed":bool,"kind":"..","reason":"..",
#                              "invitations":N,"ledger":N|null},
#                   "cursor":{..,"daily_cap":{..}?},
#                   "coderabbit":{..}, "graphite":{..}}|null,
#      "allowed":[..], "deferred":[..]}
#   --claim adds "claim":{"reviewer":"..","claimed":bool,"count":N|null}.
#   Diagnostics go to stderr.
#
# EXIT STATUS
#   0  Evaluated (denials included), a claim that succeeded, or a release.
#   1  --claim only: the reviewer is not allowed now; nothing was recorded.
#   2  Usage error.
#   3  PR not found.
#   4  Internal failure: a required tool (jq) or the ledger write failed.
#   70 --help header extraction produced no output (internal defect).

set -uo pipefail
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" 2>/dev/null >> "$HOME/.claude/script-usage.log" || true

if [[ "${1-}" == "-h" || "${1-}" == "--help" ]]; then
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; n = 1; next } { exit } END { exit(n ? 0 : 1) }' "$0" ||
    { printf '%s: --help header extraction produced no output\n' "$0" >&2; exit 70; }
  exit 0
fi

ME="review-triggers-allowed.sh"
warn() { printf '%s: %s\n' "$ME" "$1" >&2; }
die_usage() { warn "$1"; exit 2; }

PR=""
REPO=""
BASE_REF=""
WANT_HEAD=""
MODE_ONLY=0
CLAIM=""
RELEASE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) [[ -n "${2-}" ]] || die_usage "--repo requires a value"; REPO="$2"; shift 2 ;;
    --base) [[ -n "${2-}" ]] || die_usage "--base requires a value"; BASE_REF="$2"; shift 2 ;;
    --head) [[ -n "${2-}" ]] || die_usage "--head requires a value"; WANT_HEAD="$2"; shift 2 ;;
    --mode-only) MODE_ONLY=1; shift ;;
    --claim) [[ -n "${2-}" ]] || die_usage "--claim requires a reviewer"; CLAIM="$2"; shift 2 ;;
    --release) [[ -n "${2-}" ]] || die_usage "--release requires a reviewer"; RELEASE="$2"; shift 2 ;;
    -*) die_usage "unknown flag: $1" ;;
    *)
      [[ -z "$PR" ]] || die_usage "unexpected argument: $1"
      PR="$1"; shift ;;
  esac
done

[[ -n "$PR" ]] || die_usage "usage: $ME <pr> [--repo <owner/name>] [--base <ref>] [--head <sha>] [--mode-only | --claim <reviewer> | --release <reviewer>]"
[[ "$PR" =~ ^[1-9][0-9]*$ ]] || die_usage "<pr> must be a positive integer (got: $PR)"
[[ -z "$REPO" || "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die_usage "--repo must be owner/name (got: $REPO)"
[[ -z "$WANT_HEAD" || "$WANT_HEAD" =~ ^[0-9a-fA-F]{7,40}$ ]] || die_usage "--head must be a commit SHA (got: $WANT_HEAD)"
n_modes=0
[[ "$MODE_ONLY" -eq 1 ]] && n_modes=$((n_modes + 1))
[[ -n "$CLAIM" ]] && n_modes=$((n_modes + 1))
[[ -n "$RELEASE" ]] && n_modes=$((n_modes + 1))
[[ "$n_modes" -le 1 ]] || die_usage "--mode-only, --claim and --release are mutually exclusive"
for r in "$CLAIM" "$RELEASE"; do
  case "$r" in ""|codeant|cursor|coderabbit|graphite) ;; *) die_usage "unknown reviewer: $r (codeant | cursor | coderabbit | graphite)" ;; esac
done
command -v jq >/dev/null 2>&1 || { warn "'jq' not found on PATH"; exit 4; }

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESOLVER="$SELF_DIR/review-tier.sh"
STATE_SH="$SELF_DIR/session-state.sh"

# ---------------------------------------------------------------------------
# Ledger (repo-scoped session state). Reads never fail the run: an unreadable
# ledger counts 0 and the visible comments still bound the cap.
# ---------------------------------------------------------------------------
ledger_get() { # <reviewer> -> JSON object or null
  local out
  [[ -x "$STATE_SH" ]] || { echo null; return 0; }
  out="$("$STATE_SH" ${REPO:+--repo "$REPO"} --get-json ".prs[\"$PR\"].review_trigger_ledger.$1" 2>/dev/null)" || out="null"
  jq -e 'type == "object"' <<<"$out" >/dev/null 2>&1 || out="null"
  printf '%s' "$out"
}
ledger_count_of() { # <ledger json> -> integer
  jq -r 'if type == "object" and (.count | type) == "number" and .count >= 0 then (.count | floor) else 0 end' <<<"$1" 2>/dev/null || echo 0
}

# --release needs no evaluation: undo one claim. Best effort, bounded retries.
if [[ -n "$RELEASE" ]]; then
  [[ -n "$REPO" ]] || REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
  attempt=0
  while (( attempt < 3 )); do
    attempt=$((attempt + 1))
    L="$(ledger_get "$RELEASE")"
    C="$(ledger_count_of "$L")"
    if [[ "$L" == "null" || "$C" -eq 0 ]]; then
      jq -cn --argjson pr "$PR" --arg r "$RELEASE" '{pr: $pr, release: {reviewer: $r, released: false, count: 0}}'
      exit 0
    fi
    RC=0
    "$STATE_SH" ${REPO:+--repo "$REPO"} \
      --cas ".prs[\"$PR\"].review_trigger_ledger.$RELEASE.count=$((C - 1))" --expect "$C" >/dev/null 2>&1 || RC=$?
    if [[ "$RC" -eq 0 ]]; then
      jq -cn --argjson pr "$PR" --arg r "$RELEASE" --argjson c "$((C - 1))" '{pr: $pr, release: {reviewer: $r, released: true, count: $c}}'
      exit 0
    fi
    [[ "$RC" -eq 7 ]] || break
  done
  warn "could not release the $RELEASE claim on PR #$PR — the ledger may over-count by one"
  exit 4
fi

# ---------------------------------------------------------------------------
# 1. Mode: resolve the tier. Only a provably policy-free repo is legacy.
# ---------------------------------------------------------------------------
TIER_JSON=""
TIER_RC=0
if [[ -f "$RESOLVER" ]]; then
  TIER_JSON="$(bash "$RESOLVER" "$PR" ${REPO:+--repo "$REPO"} ${BASE_REF:+--base "$BASE_REF"} --json 2>/dev/null)" || TIER_RC=$?
else
  warn "review-tier.sh not found beside this script ($RESOLVER) — tier unresolved"
  TIER_RC=127
fi
if [[ "$TIER_RC" -eq 3 ]]; then
  warn "PR #$PR not found"
  exit 3
fi

MODE=""
GATE="null"; TIER="null"; POLICY="null"; ESCALATION="on"
if [[ "$TIER_RC" -eq 0 ]] && jq -e 'type == "object"' <<<"$TIER_JSON" >/dev/null 2>&1; then
  P="$(jq -r '.policy // ""' <<<"$TIER_JSON")"
  G="$(jq -r '.gate // ""' <<<"$TIER_JSON")"
  case "$P:$G" in
    absent:legacy) MODE="legacy" ;;
    present:ci-only|present:ci+codeant-one-round|present:full|invalid:full) MODE="tiered" ;;
  esac
  if [[ -n "$MODE" ]]; then
    GATE="$(jq -c '.gate' <<<"$TIER_JSON")"
    TIER="$(jq -c '.tier // null' <<<"$TIER_JSON")"
    POLICY="$(jq -c '.policy' <<<"$TIER_JSON")"
    # Only a literal "off" turns escalation off, as bugbot-tier-excluded.sh reads it.
    [[ "$(jq -r '.escalation // "on" | tostring' <<<"$TIER_JSON")" == "off" ]] && ESCALATION="off"
  fi
fi

if [[ -z "$MODE" ]]; then
  # The tier is unresolved. Probe the local checkout: legacy ONLY when it is the
  # target repo and has no policy at all. Anything else fails closed.
  PROBE_OK=0
  if [[ -f "$RESOLVER" ]] && git rev-parse --show-toplevel >/dev/null 2>&1; then
    if [[ -n "$REPO" ]]; then
      origin="$(git remote get-url origin 2>/dev/null || true)"
      origin="${origin%.git}"
      origin="${origin##*github.com[:/]}"
      [[ "$(printf '%s' "$origin" | tr '[:upper:]' '[:lower:]')" == "$(printf '%s' "$REPO" | tr '[:upper:]' '[:lower:]')" ]] && PROBE_OK=1
    else
      PROBE_OK=1
    fi
  fi
  if [[ "$PROBE_OK" -eq 1 ]]; then
    PROBE_RC=0
    PROBE="$(printf '' | bash "$RESOLVER" --files-from - --json 2>/dev/null)" || PROBE_RC=$?
    if [[ "$PROBE_RC" -eq 0 ]] && [[ "$(jq -r 'if type == "object" then (.policy // "") else "" end' <<<"$PROBE" 2>/dev/null)" == "absent" ]]; then
      MODE="legacy"
      GATE='"legacy"'; POLICY='"absent"'
      [[ "$(jq -r '.escalation // "on" | tostring' <<<"$PROBE" 2>/dev/null)" == "off" ]] && ESCALATION="off"
      warn "review tier unresolved for PR #$PR (review-tier.sh exit $TIER_RC); the local checkout declares no ## Review policy — legacy behaviour"
    fi
  fi
  if [[ -z "$MODE" ]]; then
    MODE="fail_closed"
    warn "review tier unresolved for PR #$PR (review-tier.sh exit $TIER_RC) and this repo may declare a ## Review policy — denying every reviewer trigger (fail closed, issue #1749)"
  fi
fi

base_json() {
  jq -cn --argjson pr "$PR" --arg mode "$MODE" --argjson gate "$GATE" --argjson tier "$TIER" \
    --argjson policy "$POLICY" --arg esc "$ESCALATION" \
    '{pr: $pr, mode: $mode, gate: $gate, tier: $tier, policy: $policy, escalation: $esc,
      head_sha: null, ci: null, settled: null, codeant: null, reviewers: null,
      allowed: [], deferred: []}'
}

if [[ "$MODE" == "legacy" ]]; then
  OUT="$(base_json)"
  if [[ -n "$CLAIM" ]]; then
    OUT="$(jq -c --arg r "$CLAIM" '.claim = {reviewer: $r, claimed: true, count: null}' <<<"$OUT")"
  fi
  printf '%s\n' "$OUT"
  exit 0
fi

if [[ "$MODE_ONLY" -eq 1 ]]; then
  base_json
  exit 0
fi

if [[ "$MODE" == "fail_closed" ]]; then
  OUT="$(base_json | jq -c '
    .reviewers = ({codeant: 0, cursor: 0, coderabbit: 0, graphite: 0}
      | with_entries(.value = {allowed: false, kind: "deferred", reason: "tier_unresolved", invitations: null}))
    | .deferred = ["codeant", "cursor", "coderabbit", "graphite"]')"
  if [[ -n "$CLAIM" ]]; then
    printf '%s\n' "$(jq -c --arg r "$CLAIM" '.claim = {reviewer: $r, claimed: false, count: null}' <<<"$OUT")"
    exit 1
  fi
  printf '%s\n' "$OUT"
  exit 0
fi

# ---------------------------------------------------------------------------
# 2. Config (tiered mode only).
# ---------------------------------------------------------------------------
SETTLE_S=600
CODEANT_TIMEOUT_S=1800
read_cfg() { # <key> -> value from ## Complexity triggers of the local pm-config.md
  local root cfg
  root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  cfg="$root/.claude/pm-config.md"
  [[ -n "$root" && -r "$cfg" ]] || return 0
  awk -v key="$1" '
    /^## / { insec = ($0 ~ /^## Complexity triggers[[:space:]]*$/); next }
    insec {
      line = $0
      if (match(line, "^[[:space:]]*" key "[[:space:]]*=")) {
        v = substr(line, RLENGTH + 1); gsub(/^[[:space:]]+|[[:space:]]+$/, "", v); print v; exit
      }
    }' "$cfg" 2>/dev/null || true
}
apply_cfg() { # <var name> <pm-config key> <env name>
  local v env_v
  v="$(read_cfg "$2")"
  if [[ -n "$v" ]]; then
    if [[ "$v" =~ ^(0|[1-9][0-9]*)$ ]]; then printf -v "$1" '%s' "$v"
    else warn "pm-config $2='$v' is not a non-negative integer — using the default"; fi
  fi
  env_v="${!3-}"
  if [[ -n "$env_v" ]]; then
    if [[ "$env_v" =~ ^(0|[1-9][0-9]*)$ ]]; then printf -v "$1" '%s' "$env_v"
    else warn "$3='$env_v' is not a non-negative integer — using the default"; fi
  fi
}
apply_cfg SETTLE_S TRIGGER_SETTLE_SECONDS COMPLEXITY_TRIGGER_SETTLE_SECONDS
apply_cfg CODEANT_TIMEOUT_S CODEANT_UNAVAILABLE_SECONDS COMPLEXITY_CODEANT_UNAVAILABLE_SECONDS

# ---------------------------------------------------------------------------
# 3. Facts (tiered mode). Any read failure defers every reviewer the gate does
#    not already exclude: a failed read must never read as "allowed".
# ---------------------------------------------------------------------------
FACTS_OK=1
note_fact_failure() { warn "$1 — deferring reviewer triggers"; FACTS_OK=0; }
# `ci-only` excludes every reviewer whatever the facts say, so a docs PR costs
# no PR reads at all on each poll tick.
READ_FACTS=1
[[ "$GATE" == '"ci-only"' ]] && READ_FACTS=0

if [[ "$READ_FACTS" -eq 1 && -z "$REPO" ]]; then
  REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
  [[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { REPO=""; note_fact_failure "could not resolve the repository (gh repo view)"; }
fi

HEAD_SHA=""
PR_STATE=""
if [[ "$READ_FACTS" -eq 1 && "$FACTS_OK" -eq 1 ]]; then
  if PRV="$(gh pr view "$PR" --repo "$REPO" --json headRefOid,state 2>/dev/null)"; then
    HEAD_SHA="$(jq -r '.headRefOid // ""' <<<"$PRV" 2>/dev/null || true)"
    PR_STATE="$(jq -r '.state // ""' <<<"$PRV" 2>/dev/null || true)"
  fi
  [[ "$HEAD_SHA" =~ ^[0-9a-f]{40}$ ]] || note_fact_failure "could not read PR #$PR's HEAD"
fi
HEAD_MOVED=false
if [[ -n "$WANT_HEAD" && -n "$HEAD_SHA" ]]; then
  WANT_LC="$(printf '%s' "$WANT_HEAD" | tr '[:upper:]' '[:lower:]')"
  [[ "$HEAD_SHA" == "$WANT_LC"* ]] || HEAD_MOVED=true
fi
PR_OPEN=true
[[ -z "$PR_STATE" || "$PR_STATE" == "OPEN" ]] || PR_OPEN=false

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

COMMENTS="[]"; REVIEWS="[]"; CHECKS_RAW=""; CHECKS='{"check_runs":[]}'; CI="unknown"
ANCHOR_TIMES="[]"
[[ "$READ_FACTS" -eq 1 ]] || CI="not_read"
if [[ "$READ_FACTS" -eq 1 && "$FACTS_OK" -eq 1 ]]; then
  if ! gh api --paginate "repos/$REPO/issues/$PR/comments?per_page=100" >"$TMPD/c" 2>/dev/null \
     || ! COMMENTS="$(jq -s 'add // []' "$TMPD/c" 2>/dev/null)" || [[ -z "$COMMENTS" ]]; then
    COMMENTS="[]"; note_fact_failure "could not read PR #$PR's comments"
  fi
fi
if [[ "$READ_FACTS" -eq 1 && "$FACTS_OK" -eq 1 ]]; then
  if ! gh api --paginate "repos/$REPO/pulls/$PR/reviews?per_page=100" >"$TMPD/r" 2>/dev/null \
     || ! REVIEWS="$(jq -s 'add // []' "$TMPD/r" 2>/dev/null)" || [[ -z "$REVIEWS" ]]; then
    REVIEWS="[]"; note_fact_failure "could not read PR #$PR's reviews"
  fi
fi
if [[ "$READ_FACTS" -eq 1 && "$FACTS_OK" -eq 1 ]]; then
  if gh api --paginate "repos/$REPO/commits/$HEAD_SHA/check-runs?per_page=100" >"$TMPD/k" 2>/dev/null; then
    CHECKS_RAW="$(cat "$TMPD/k")"
    DEDUP="$SELF_DIR/check-runs-dedup.sh"
    if [[ -x "$DEDUP" ]] && D="$(printf '%s\n' "$CHECKS_RAW" | "$DEDUP" 2>/dev/null)" && [[ -n "$D" ]]; then
      CHECKS="$(jq -c '{check_runs: .}' <<<"$D" 2>/dev/null || echo '{"check_runs":[]}')"
    fi
    # Build CI only: a reviewer's own check never holds the gate (issue #1749).
    CI_RC=0
    if [[ -x "$SELF_DIR/ci-status.sh" ]]; then
      printf '%s\n' "$CHECKS_RAW" | "$SELF_DIR/ci-status.sh" "$HEAD_SHA" --check-runs-stdin --exclude-reviewers --format json >/dev/null 2>&1 || CI_RC=$?
      case "$CI_RC" in 0) CI="green" ;; 1) CI="pending" ;; 3) CI="red" ;; *) CI="unknown" ;; esac
    else
      warn "ci-status.sh not found beside this script — CI unknown"
    fi
    # Earliest check-run on HEAD: GitHub's own clock, at about push time.
    ANCHOR_TIMES="$(printf '%s\n' "$CHECKS_RAW" | jq -s -c '
      [ .[]?.check_runs[]? | (.started_at // .created_at // empty) ] | sort | .[0:1]' 2>/dev/null || echo '[]')"
  else
    note_fact_failure "could not read the check-runs on ${HEAD_SHA:0:7}"
  fi
fi

# Settle anchor parts — read only on `full`, the one gate that needs them.
if [[ "$FACTS_OK" -eq 1 && "$GATE" == '"full"' ]]; then
  PUSHED="$(gh api --paginate "repos/$REPO/issues/$PR/timeline?per_page=100" \
    --jq '.[]? | select(.event == "head_ref_force_pushed" or .event == "head_ref_pushed") | (.created_at // empty)' 2>/dev/null \
    | LC_ALL=C sort | tail -1)" || PUSHED=""
  COMMITTED="$(gh api "repos/$REPO/commits/$HEAD_SHA" --jq '.commit.committer.date // empty' 2>/dev/null)" || COMMITTED=""
  ANCHOR_TIMES="$(jq -c --arg p "$PUSHED" --arg c "$COMMITTED" '. + ([$p, $c] | map(select(. != "")))' <<<"$ANCHOR_TIMES" 2>/dev/null || echo '[]')"
fi

# ---------------------------------------------------------------------------
# 4. Decide (pure jq over the facts).
# ---------------------------------------------------------------------------
evaluate() {
  local l_codeant l_cursor l_coderabbit
  l_codeant="$(ledger_get codeant)"; l_cursor="$(ledger_get cursor)"; l_coderabbit="$(ledger_get coderabbit)"
  printf '%s' "$COMMENTS" > "$TMPD/comments.json"
  printf '%s' "$REVIEWS" > "$TMPD/reviews.json"
  printf '%s' "$CHECKS" > "$TMPD/checks.json"
  jq -cn -L "$SELF_DIR/lib" \
    --argjson pr "$PR" --argjson gate "$GATE" --argjson tier "$TIER" --argjson policy "$POLICY" \
    --arg esc "$ESCALATION" --arg head "$HEAD_SHA" --arg ci "$CI" \
    --argjson facts_ok "$( [[ "$FACTS_OK" -eq 1 ]] && echo true || echo false )" \
    --argjson head_moved "$HEAD_MOVED" --argjson pr_open "$PR_OPEN" \
    --argjson settle_s "$SETTLE_S" --argjson codeant_timeout_s "$CODEANT_TIMEOUT_S" \
    --argjson anchors "$ANCHOR_TIMES" \
    --argjson l_codeant "$l_codeant" --argjson l_cursor "$l_cursor" --argjson l_coderabbit "$l_coderabbit" \
    --slurpfile comments "$TMPD/comments.json" --slurpfile reviews "$TMPD/reviews.json" \
    --slurpfile checks "$TMPD/checks.json" '
    include "codeant-round";
    ($comments[0] // []) as $comments
    | ($reviews[0] // []) as $reviews
    | ($checks[0] // {check_runs: []}) as $checks
    | (now | floor) as $now
    | def epoch: if type == "string" and . != "" then (sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | (try fromdateiso8601 catch null)) else null end;
      def bots: ["codeant-ai[bot]", "cursor[bot]", "coderabbitai[bot]", "graphite-app[bot]"];
      def trigger($r): {codeant: "@codeant-ai review", cursor: "@cursor review",
                        coderabbit: "@coderabbitai full review", graphite: "@graphite-app re-review"}[$r];
      def invites($r): [ $comments[]?
        | select(((.user.login // "") as $l | bots | any(. == $l)) | not)
        | select(((.body // "") | gsub("^[[:space:]]+|[[:space:]]+$"; "")) == trigger($r)) ];
      def ledger_count($l): if ($l | type) == "object" and (($l.count // null) | type) == "number" then ([$l.count, 0] | max | floor) else 0 end;
      def count($r; $l): [ (invites($r) | length), ledger_count($l) ] | max;
      def deny($k; $why): {allowed: false, kind: $k, reason: $why};
      # The raw ledger value this decision was computed from — a claim CASes
      # against exactly this, so any claim landing in between fails the CAS.
      def ledger_raw($l): if ($l | type) == "object" then ($l.count // null) else null end;
    ($l_codeant) as $lc
    | count("codeant"; $l_codeant) as $n_codeant
    | count("cursor"; $l_cursor) as $n_cursor
    | count("coderabbit"; $l_coderabbit) as $n_coderabbit
    | ((invites("graphite") | length)) as $n_graphite
    | ((($comments | codeant_round_record_count) + ($reviews | codeant_round_review_count)
        + ($checks | codeant_round_check_count)) > 0) as $round
    # CodeAnt availability, for the CodeRabbit fallback on `full`.
    | ([ (invites("codeant")[] | .created_at | epoch), (if ($lc | type) == "object" then ($lc.at // null | epoch) else null end) ]
        | map(select(. != null)) | max) as $invited_at
    | (if $invited_at == null then null else
         ( [ $comments[]? | select((.user.login // "") == "codeant-ai[bot]")
             | ((.updated_at // .created_at) | epoch) | select(. != null and . >= $invited_at) ]
           + [ $reviews[]? | select((.user.login // "") == "codeant-ai[bot]")
             | ((.submitted_at // "") | epoch) | select(. != null and . >= $invited_at) ]
           + [ $checks.check_runs[]? | select((.app.slug // "") == "codeant-ai")
             | ((.started_at // .created_at // "") | epoch) | select(. != null and . >= $invited_at) ] ) | length > 0
       end) as $codeant_answered
    | (if $n_codeant == 0 or $invited_at == null then null
       elif $codeant_answered then true
       elif ($now - $invited_at) >= $codeant_timeout_s then false
       else null end) as $codeant_available
    | (if $n_codeant > 0 and $invited_at != null and ($codeant_answered | not) and ($now - $invited_at) < $codeant_timeout_s
       then true else false end) as $codeant_pending
    # Settled HEAD.
    | ($anchors | map(epoch) | map(select(. != null)) | max) as $anchor
    | (if $anchor == null then null else ($now - $anchor) end) as $age
    | ($ci == "green" and $age != null and $age >= $settle_s) as $settled
    | (if $ci == "green" then null
       elif $ci == "red" then deny("deferred"; "ci_red")
       elif $ci == "pending" then deny("deferred"; "ci_pending")
       else deny("deferred"; "ci_unknown") end) as $ci_gate
    | def decide($r):
        # Static exclusions: they hold whatever the facts say.
        if $r == "graphite" then deny("excluded"; "tier_excluded")
        elif $gate == "ci-only" then deny("excluded"; "tier_excluded")
        elif $gate == "ci+codeant-one-round" and ($r == "cursor" or $r == "coderabbit") then deny("excluded"; "tier_excluded")
        elif $gate == "full" and $r == "cursor" and $esc == "off" then deny("excluded"; "escalation_off")
        elif ($pr_open | not) then deny("excluded"; "pr_not_open")
        elif $head_moved then deny("deferred"; "head_moved")
        elif ($facts_ok | not) then deny("deferred"; "facts_unreadable")
        elif $r == "codeant" then
          if $gate == "ci+codeant-one-round" and $round then deny("excluded"; "round_completed")
          elif $n_codeant >= 1 then deny("excluded"; "lifetime_cap")
          elif $ci_gate != null then $ci_gate
          else {allowed: true, kind: "allowed", reason: "tier_allows"} end
        elif $r == "cursor" then
          if $n_cursor >= 2 then deny("excluded"; "lifetime_cap")
          elif $ci_gate != null then $ci_gate
          elif ($settled | not) then deny("deferred"; "head_not_settled")
          else {allowed: true, kind: "allowed", reason: "tier_allows"} end
        else # coderabbit on full: only as the CodeAnt-unavailable fallback
          if $codeant_available == false then
            (if $ci_gate != null then $ci_gate else {allowed: true, kind: "allowed", reason: "codeant_unavailable"} end)
          elif $codeant_pending then deny("deferred"; "codeant_pending")
          else deny("excluded"; "not_fallback") end
        end;
      {pr: $pr, mode: "tiered", gate: $gate, tier: $tier, policy: $policy, escalation: $esc,
       head_sha: (if $head == "" then null else $head end),
       ci: (if $facts_ok and $ci != "not_read" then $ci else null end),
       settled: (if $gate == "full" then {settled: $settled, age_s: $age, threshold_s: $settle_s} else null end),
       codeant: {round_completed: $round, invited: ($n_codeant > 0), available: $codeant_available},
       reviewers: {
         codeant: (decide("codeant") + {invitations: $n_codeant, ledger: ledger_raw($l_codeant)}),
         cursor: (decide("cursor") + {invitations: $n_cursor, ledger: ledger_raw($l_cursor)}),
         coderabbit: (decide("coderabbit") + {invitations: $n_coderabbit, ledger: ledger_raw($l_coderabbit)}),
         graphite: (decide("graphite") + {invitations: $n_graphite, ledger: null})
       }}
    | .allowed = [ .reviewers | to_entries[] | select(.value.allowed) | .key ]
    | .deferred = [ .reviewers | to_entries[] | select(.value.kind == "deferred") | .key ]'
}

# BugBot's last two guards, asked only when everything above allows it — the
# same order and failure direction as maybe-trigger-ai-review.sh: the refusal
# guard first, the account daily cap LAST. Both fail open.
bugbot_guards() { # <decision json> -> decision json
  local d="$1" refused="$SELF_DIR/bugbot-refused-head.sh" cap="$SELF_DIR/review-daily-cap.sh"
  local rate out rc status
  [[ "$(jq -r '.reviewers.cursor.allowed' <<<"$d")" == "true" ]] || { printf '%s' "$d"; return 0; }
  if [[ -x "$refused" ]] && GH_REPO="$REPO" "$refused" "$PR" "$HEAD_SHA" >/dev/null 2>&1; then
    printf '%s' "$d" | jq -c '.reviewers.cursor += {allowed: false, kind: "excluded", reason: "refused_head"}
      | .allowed -= ["cursor"]'
    return 0
  fi
  if [[ ! -x "$cap" ]]; then
    warn "DEGRADED: review-daily-cap.sh not found beside this script — account daily cap unavailable, continuing without it"
    printf '%s' "$d"; return 0
  fi
  rate="$("$cap" bugbot --rate 2>/dev/null)" || rate=""
  [[ "$rate" =~ ^[0-9]+(\.[0-9]+)?$ ]] || rate=0
  rc=0
  out="$("$cap" bugbot --add-usd "$rate" 2>/dev/null)" || rc=$?
  if (( rc > 1 )) || ! jq -e 'type == "object" and (.status == "ok" or .status == "over" or .status == "unknown")' <<<"$out" >/dev/null 2>&1; then
    warn "review-daily-cap.sh gave no usable answer (rc=$rc) — BugBot daily cap unknown, allowing"
    printf '%s' "$d"; return 0
  fi
  status="$(jq -r '.status' <<<"$out")"
  # The exit code and the status must agree before a skip is believed.
  if [[ "$status" == "over" && "$rc" -ne 1 ]] || [[ "$status" != "over" && "$rc" -ne 0 ]]; then
    warn "review-daily-cap.sh status '$status' disagrees with its exit $rc — treating the cap as unknown, allowing"
    out="$(jq -c '.status = "unknown"' <<<"$out")"; status="unknown"
  fi
  [[ "$status" == "unknown" ]] && warn "BugBot daily cap is unknown today — allowing (the vendor cap stays the hard stop)"
  if [[ "$status" == "over" ]]; then
    printf '%s' "$d" | jq -c --argjson t "$out" '.reviewers.cursor += {allowed: false, kind: "deferred", reason: "daily_cap", daily_cap: $t}
      | .allowed -= ["cursor"] | .deferred += ["cursor"]'
  else
    printf '%s' "$d" | jq -c --argjson t "$out" '.reviewers.cursor.daily_cap = $t'
  fi
}

decide_all() {
  local d
  d="$(evaluate)" || return 1
  [[ -n "$d" ]] || return 1
  # A claim for another reviewer never reads cursor's answer, so it spends
  # neither the refusal lookup nor the daily-cap tally.
  if [[ -n "$CLAIM" && "$CLAIM" != "cursor" ]]; then printf '%s' "$d"; return 0; fi
  bugbot_guards "$d"
}

if [[ -z "$CLAIM" ]]; then
  OUT="$(decide_all)" || { warn "could not evaluate the decision (jq failure)"; exit 4; }
  printf '%s\n' "$OUT"
  exit 0
fi

# ---------------------------------------------------------------------------
# 5. --claim: re-evaluated, then one CAS on the ledger. A lost CAS means a
#    concurrent claim landed: evaluate again against the new count.
# ---------------------------------------------------------------------------
[[ -x "$STATE_SH" ]] || { warn "session-state.sh not found beside this script — cannot record a claim; not posting"; exit 4; }
attempt=0
while (( attempt < 3 )); do
  attempt=$((attempt + 1))
  OUT="$(decide_all)" || { warn "could not evaluate the decision (jq failure)"; exit 4; }
  if [[ "$(jq -r --arg r "$CLAIM" '.reviewers[$r].allowed' <<<"$OUT")" != "true" ]]; then
    printf '%s\n' "$(jq -c --arg r "$CLAIM" '.claim = {reviewer: $r, claimed: false, count: .reviewers[$r].invitations}' <<<"$OUT")"
    exit 1
  fi
  # Compare-and-set against the very ledger value this decision was computed
  # from. A claim that landed after the evaluation changed it, so the CAS
  # fails (exit 7) and the loop re-evaluates against the new count, instead
  # of claiming on a stale "allowed" (CodeRabbit review, PR for #1749).
  EXPECT="$(jq -c --arg r "$CLAIM" '.reviewers[$r].ledger' <<<"$OUT")"
  NEXT=$(( $(jq -r --arg r "$CLAIM" '.reviewers[$r].invitations' <<<"$OUT") + 1 ))
  NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  RC=0
  "$STATE_SH" --repo "$REPO" \
    --cas ".prs[\"$PR\"].review_trigger_ledger.$CLAIM.count=$NEXT" --expect "$EXPECT" \
    --set ".prs[\"$PR\"].review_trigger_ledger.$CLAIM.head_sha=\"$HEAD_SHA\"" \
    --set ".prs[\"$PR\"].review_trigger_ledger.$CLAIM.at=\"$NOW_ISO\"" >/dev/null 2>&1 || RC=$?
  if [[ "$RC" -eq 0 ]]; then
    printf '%s\n' "$(jq -c --arg r "$CLAIM" --argjson n "$NEXT" '.claim = {reviewer: $r, claimed: true, count: $n}' <<<"$OUT")"
    exit 0
  fi
  [[ "$RC" -eq 7 ]] || { warn "could not record the $CLAIM claim (session-state.sh exit $RC) — not posting"; exit 4; }
done
warn "the $CLAIM claim lost the ledger race three times — not posting"
printf '%s\n' "$(jq -c --arg r "$CLAIM" '.claim = {reviewer: $r, claimed: false, count: null}' <<<"$OUT")"
exit 1
