#!/usr/bin/env bash
# escalate-review.sh — Deterministic CR→BugBot→Greptile escalation verdict.
#
# PURPOSE
#   Implements the per-cycle reviewer escalation gate documented in
#   .claude/rules/cr-github-review.md. The script gathers the current PR state,
#   checks whether CodeRabbit is still a viable active reviewer, caches whether
#   BugBot appears installed for this PR, and prints exactly one STATUS verdict.
#
# USAGE
#   escalate-review.sh <pr_number>
#   escalate-review.sh --help | -h
#
# OUTPUT
#   stdout: one line, exactly one of:
#     STATUS=gate_met         CR-path primary review already satisfied (CodeRabbit or
#                             CodeAnt has a valid APPROVED review on current HEAD) —
#                             do not escalate; the merge gate will pick this up
#     STATUS=polling_cr       keep polling CodeRabbit/BugBot grace window
#     STATUS=switch_bugbot    BugBot has responded — OR BugBot was never invited
#                             (no footprint on HEAD and no fresh `@cursor review`
#                             trigger comment). Make BugBot the sticky reviewer;
#                             when it has no footprint yet, post the manual
#                             `@cursor review` trigger before polling
#     STATUS=trigger_greptile CR failed AND BugBot either failed outright or was
#                             invited and then timed out; trigger Greptile. NOT
#                             emitted for a BugBot that was never invited — that
#                             case is switch_bugbot above
#     STATUS=budget_exhausted Greptile budget is exhausted; do not trigger Greptile
#     STATUS=self_review      PR is already marked for self-review fallback
#
# EXIT STATUS
#   0  A STATUS verdict was printed
#   2  Usage/dependency error
#   4  GitHub/API/state read error

set -euo pipefail
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" >> "$HOME/.claude/script-usage.log" 2>/dev/null || true

PR_NUMBER=""

print_usage() {
  awk 'NR == 1 { next } /^$/ { exit } { print }' "$0"
}

die_usage() {
  echo "escalate-review.sh: $1" >&2
  echo "Run with --help for usage." >&2
  exit 2
}

emit() {
  printf 'STATUS=%s\n' "$1"
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      print_usage
      exit 0
      ;;
    -*)
      die_usage "unknown flag: $1"
      ;;
    *)
      if [[ -n "$PR_NUMBER" ]]; then
        die_usage "unexpected argument: $1 (PR number already set to $PR_NUMBER)"
      fi
      PR_NUMBER="$1"
      shift
      ;;
  esac
done

if [[ -z "$PR_NUMBER" ]]; then
  die_usage "<pr_number> is required"
fi

if ! [[ "$PR_NUMBER" =~ ^[0-9]+$ ]]; then
  die_usage "<pr_number> must be a positive integer (got: $PR_NUMBER)"
fi

for dep in gh jq python3; do
  if ! command -v "$dep" >/dev/null 2>&1; then
    echo "escalate-review.sh: '$dep' not found on PATH" >&2
    exit 2
  fi
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SESSION_STATE="$SCRIPT_DIR/session-state.sh"
PR_STATE="$SCRIPT_DIR/pr-state.sh"
GREPTILE_BUDGET="$SCRIPT_DIR/greptile-budget.sh"

if [[ ! -x "$SESSION_STATE" || ! -x "$PR_STATE" || ! -x "$GREPTILE_BUDGET" ]]; then
  echo "escalate-review.sh: required sibling scripts are missing or not executable" >&2
  exit 2
fi

CURRENT_REVIEWER="$("$SESSION_STATE" --get ".prs[\"$PR_NUMBER\"].reviewer // \"\"" 2>/dev/null || true)"
if [[ "$CURRENT_REVIEWER" == "self_review" ]]; then
  emit "self_review"
fi

STATE_PATH="$("$PR_STATE" --pr "$PR_NUMBER" 2>/dev/null)"
if [[ -z "$STATE_PATH" || ! -f "$STATE_PATH" ]]; then
  echo "escalate-review.sh: failed to gather PR state for #$PR_NUMBER" >&2
  exit 4
fi

read -r OWNER REPO HEAD_SHA < <(jq -r '[.pr.owner, .pr.repo, .pr.head_sha] | @tsv' "$STATE_PATH") || {
  echo "escalate-review.sh: failed to read PR state JSON" >&2
  exit 4
}

if [[ -z "$OWNER" || -z "$REPO" || -z "$HEAD_SHA" ]]; then
  echo "escalate-review.sh: PR state missing owner/repo/head_sha" >&2
  exit 4
fi

# Gate-already-met short-circuit (issue reported on PR #619, 2026-07-21): before
# evaluating ANY CR->BugBot->Greptile escalation, check whether the CR-path
# primary review requirement is already satisfied by CodeRabbit OR CodeAnt.
# Per cr-merge-gate.md Step 1, "at least one of: CodeRabbit or CodeAnt with
# state: APPROVED ... Either bot satisfies the primary review; you do not need
# both when only one reviewed." If so, the merge gate (merge-gate.sh) is
# already on track regardless of whether CR is rate-limited or BugBot failed —
# escalating to a paid Greptile review would be unwarranted. This mirrors
# merge-gate.sh's CR_APPROVAL_VALID / CA_APPROVAL_VALID retraction-aware logic
# (see merge-gate.sh's `primary_review_met` field) against the PR state already
# fetched above, so no extra gh API calls are needed.
# Emits the LOGINS whose approval is valid, not just a boolean: the substance
# guard below has to test the same reviewer on both conditions, and a bare
# boolean loses which bot it came from (CodeAnt review, PR #883).
VALID_APPROVERS="$(jq -r --arg sha "$HEAD_SHA" '
  def approval_valid($login):
    ([.comments.reviews[]?
      | select(.user.login == $login and (.commit_id // "") == $sha and .state == "APPROVED")
      | .submitted_at] | sort | last // "") as $approved_at
    | ([.comments.reviews[]?
      | select(.user.login == $login and (.commit_id // "") == $sha and .state == "CHANGES_REQUESTED")
      | .submitted_at] | sort | last // "") as $changes_at
    | ($approved_at != "") and (($changes_at == "") or ($changes_at <= $approved_at));
  . as $doc
  | [ "coderabbitai[bot]", "codeant-ai[bot]" ]
  # `. as $l` first: with a `$login`-style parameter jq evaluates the argument
  # closure against the DEF"s input, so `approval_valid(.)` here would pass the
  # whole document rather than the login string.
  | map(. as $l | select($doc | approval_valid($l)))
  | join(",")
' "$STATE_PATH")" || {
  echo "escalate-review.sh: failed to evaluate primary-review-met check" >&2
  exit 4
}
PRIMARY_REVIEW_MET=false
[[ -n "$VALID_APPROVERS" ]] && PRIMARY_REVIEW_MET=true

# Approval FRESHNESS (issue #836), applied here too (BugBot review, PR #883).
# The check above only asks "exists and not retracted". merge-gate.sh also
# requires submitted_at not to predate the HEAD commit, because GitHub retargets
# commit_id onto HEAD after a force-push without touching submitted_at — so a
# stale approval plus fresh evidence would emit gate_met here while the gate
# itself stayed blocked, which is the same escalation stall this file exists to
# prevent. Fetched once, only when an approval actually exists.
HEAD_COMMIT_TS=""
if [[ "$PRIMARY_REVIEW_MET" == "true" ]]; then
  HEAD_COMMIT_TS="$(gh api "repos/$OWNER/$REPO/git/commits/$HEAD_SHA" 2>/dev/null | jq -r '.committer.date // ""' 2>/dev/null || echo "")"
  if [[ -z "$HEAD_COMMIT_TS" ]]; then
    # Fail closed, matching merge-gate.sh's CR_APPROVAL_FRESHNESS_UNKNOWN: an
    # unverifiable approval must not short-circuit escalation. Callers re-poll
    # every ~60 s, so a transient API failure self-heals rather than sticking.
    PRIMARY_REVIEW_MET=false
    VALID_APPROVERS=""
    echo "escalate-review.sh: cannot verify approval freshness — HEAD commit timestamp unavailable; not reporting gate_met (issues #836, #875)" >&2
  else
    # Evaluated into a temporary first so a jq FAILURE is distinguishable from a
    # successful "every approval is stale" (BugBot review, PR #883). Both clear
    # VALID_APPROVERS, but only one is a degraded run, and silently reporting it
    # as "no valid approvers" would escalate to a PAID Greptile review on what is
    # really a tooling fault. The two sibling guards in this block both announce
    # themselves on stderr; this one used to be the exception.
    FRESH_APPROVERS=""
    FRESHNESS_OK=true
    FRESH_APPROVERS="$(jq -rn --arg sha "$HEAD_SHA" --arg push "$HEAD_COMMIT_TS" \
      --arg logins "$VALID_APPROVERS" --slurpfile doc "$STATE_PATH" '
      # Canonicalise before comparing (BugBot review, PR #883): this is a
      # lexicographic string compare, so when two timestamps share a
      # whole-second prefix the zone suffix is the first differing character —
      # and "+" (0x2B) is below "Z" (0x5A), so "…T10:00:16+00:00" sorts BELOW
      # "…T10:00:16Z" despite being the SAME instant. A push stamped "…16Z"
      # against an approval stamped "…16+00:00" therefore reads as
      # approval-before-push: a fresh approval is marked stale and gate_met is
      # withheld on a PR merge-gate.sh considers fine.
      #
      # STRIP the zone suffix, do NOT rewrite it to "Z", and KEEP fractional
      # seconds — this is the jq mirror of norm_ts in lib/ts-normalizer.sh and
      # must reproduce its ordering exactly, because the two implement one rule
      # (#836) and a caller more permissive than the gate is a bug (BugBot
      # review on 7de2a4c, PR #883). jq cannot source a bash function and this
      # repo has no jq-module convention, so the mirror stays inline by design.
      #
      # It is NOT kept in step by hand (issue #885):
      # tests/ts-normalizer-parity.test.sh extracts THIS def block from THIS
      # file and asserts it agrees with norm_ts byte for byte across the whole
      # spelling matrix (Z, +00:00, +0000, fractional, mixed, empty). Any edit
      # that diverges — including a well-meant superset — fails that test.
      #
      # canon_ts in review-substance.sh keeps its own fraction-stripping form:
      # every timestamp it compares passes through that one function, so it
      # stays internally consistent and is never compared against a merge-gate
      # value. The parity test pins that divergence too.
      #
      # NOTE: this comment sits inside a single-quoted jq program — no
      # apostrophes, or the quoting ends here and bash mis-parses the block.
      def canon_ts:
        (. // "")
        | if . == "" then ""
          else sub("(Z|\\+00:00|\\+0000)$"; "")
          end;
      ($logins | split(",") | map(select(length > 0))) as $candidates
      | ($doc[0] // {}) as $d
      | ($push | canon_ts) as $push_c
      | [ $candidates[]
          | . as $l
          | select(
              ([ $d.comments.reviews[]?
                 | select(.user.login == $l and (.commit_id // "") == $sha
                          and .state == "APPROVED")
                 | (.submitted_at | canon_ts) ] | sort | last // "") as $approved_at
              | ($approved_at != "") and ($approved_at >= $push_c)) ]
      | join(",")')" || FRESHNESS_OK=false
    if [[ "$FRESHNESS_OK" == "true" ]]; then
      VALID_APPROVERS="$FRESH_APPROVERS"
    else
      VALID_APPROVERS=""
      echo "escalate-review.sh: approval-freshness filter failed to evaluate (malformed state payload or jq error) — treating every approval as unverifiable; not reporting gate_met (issues #836, #875)" >&2
    fi
    PRIMARY_REVIEW_MET=false
    [[ -n "$VALID_APPROVERS" ]] && PRIMARY_REVIEW_MET=true
  fi
fi

# Review-substance guard (issue #875): the check above only asks whether an
# APPROVED exists on HEAD, not whether anything reviewed it. merge-gate.sh now
# discounts hollow approvals, so without the same test here a rubber stamp would
# short-circuit escalation ("gate_met") while the gate itself stays blocked —
# the PR would sit with no reviewer working on it and no escalation in flight.
# Same evaluator, same definition, no extra API calls (pr-state.sh already
# fetched reviews + both comment endpoints).
if [[ "$PRIMARY_REVIEW_MET" == "true" ]]; then
  REVIEW_SUBSTANCE_SH="$(dirname "$0")/review-substance.sh"
  if [[ ! -x "$REVIEW_SUBSTANCE_SH" ]]; then
    PRIMARY_REVIEW_MET=false
    echo "escalate-review.sh: review-substance.sh not found or not executable at $REVIEW_SUBSTANCE_SH — cannot verify that the APPROVED on HEAD represents a real review; not reporting gate_met (issue #875)" >&2
  else
    # HEAD_COMMIT_TS was fetched by the freshness guard above and is guaranteed
    # non-empty here (that guard clears PRIMARY_REVIEW_MET otherwise), so the
    # evaluator always gets the push_ts its temporal-inversion and
    # capability-failure signals need.
    SUBSTANCE_JSON="$(jq -c --arg sha "$HEAD_SHA" --arg push "$HEAD_COMMIT_TS" '{
        head_sha: $sha,
        push_ts: $push,
        reviews: (.comments.reviews // []),
        pr_comments: (.comments.inline // []),
        issue_comments: (.comments.conversation // [])
      }' "$STATE_PATH" 2>/dev/null | "$REVIEW_SUBSTANCE_SH" 2>/dev/null || true)"
    if [[ -z "$SUBSTANCE_JSON" ]] || ! echo "$SUBSTANCE_JSON" \
        | jq -e 'type == "object" and (.reviewers | type == "object")' >/dev/null 2>&1; then
      # Unusable evaluator output. Fail closed to match merge-gate.sh, which
      # die_local()s on the same condition: claiming gate_met here would stop
      # escalation on a PR whose gate is simultaneously refusing to pass, leaving
      # it stalled with no reviewer working on it.
      PRIMARY_REVIEW_MET=false
      echo "escalate-review.sh: review-substance.sh produced no usable JSON — cannot verify that the APPROVED on HEAD represents a real review; not reporting gate_met (issue #875)" >&2
    elif ! echo "$SUBSTANCE_JSON" | jq -e --arg valid "$VALID_APPROVERS" '
            ($valid | split(",") | map(select(length > 0))) as $v
            | [ (.substantive // [])[] | select(. as $s | $v | index($s)) ]
            | length > 0' >/dev/null 2>&1; then
      # The SAME reviewer must clear both gates (CodeAnt review, PR #883).
      # Testing `.substantive | length > 0` on its own let a substantive but
      # RETRACTED CodeRabbit approval satisfy the check while the fresh approval
      # actually on the table was a hollow CodeAnt stamp — emitting gate_met
      # while merge-gate.sh rejected both, which strands the PR with no reviewer
      # working on it and no escalation in flight.
      PRIMARY_REVIEW_MET=false
      echo "escalate-review.sh: no reviewer holds BOTH a valid APPROVED on HEAD and substantive review evidence (valid approvals: ${VALID_APPROVERS:-none}; substantive: $(echo "$SUBSTANCE_JSON" | jq -r '(.substantive // []) | join(", ") | if . == "" then "none" else . end'); hollow: $(echo "$SUBSTANCE_JSON" | jq -r '(.hollow // []) | join(", ") | if . == "" then "none" else . end')) — not treating the gate as met (issue #875)" >&2
    fi
  fi
fi

if [[ "$PRIMARY_REVIEW_MET" == "true" ]]; then
  emit "gate_met"
fi

COMMITS_JSON="$(gh api --paginate "repos/$OWNER/$REPO/pulls/$PR_NUMBER/commits?per_page=100" 2>/dev/null | jq -s 'add // []')" || {
  echo "escalate-review.sh: failed to fetch PR commits" >&2
  exit 4
}

PUSH_TIMESTAMP="$(jq -r --arg sha "$HEAD_SHA" '
  (map(select(.sha == $sha)) | last // {})
  | .commit.committer.date // .commit.author.date // empty
' <<<"$COMMITS_JSON")"

if [[ -z "$PUSH_TIMESTAMP" ]]; then
  echo "escalate-review.sh: could not determine push timestamp for #$PR_NUMBER" >&2
  exit 4
fi

# Age in seconds of an ISO-8601 timestamp, clamped at 0. Two callers share it —
# the push-age grace window below and the BugBot trigger-comment freshness test
# further down — so both timestamps are parsed by ONE rule and then compared as
# integers. That deliberately avoids a second lexicographic timestamp compare in
# this file: the jq `canon_ts` mirror is pinned byte-for-byte against
# merge-gate.sh's norm_ts (issue #885, tests/ts-normalizer-parity.test.sh
# requires exactly one `def canon_ts:` here), and a near-copy under another name
# would reintroduce exactly the drift that guard exists to prevent.
# An unparseable value yields 0 — see each call site for what that means there.
iso_age_seconds() {
  python3 - "$1" <<'PY'
from datetime import datetime, timezone
import sys

raw = sys.argv[1]
if raw.endswith("Z"):
    raw = raw[:-1] + "+00:00"
try:
    ts = datetime.fromisoformat(raw)
except ValueError:
    print(f"warning: could not parse timestamp: {raw}", file=sys.stderr)
    print(0)
    sys.exit(0)
if ts.tzinfo is None:
    ts = ts.replace(tzinfo=timezone.utc)
print(max(0, int((datetime.now(timezone.utc) - ts).total_seconds())))
PY
}

AGE_SECONDS="$(iso_age_seconds "$PUSH_TIMESTAMP")"

CR_RATE_LIMITED="$(jq -r '
  def text: [(.title // ""), (.description // ""), (.state // ""), (.conclusion // "")] | join(" ");
  (
    [.check_runs.all[]
     | select((.name // "") == "CodeRabbit")
     | select((.conclusion // "") == "failure")
     | select((text | test("rate limit"; "i")))]
    | length
  ) > 0
  or
  (
    [.commit_statuses[]
     | select((.context // "") | test("CodeRabbit"; "i"))
     | select((text | test("rate limit"; "i")))]
    | length
  ) > 0
' "$STATE_PATH")"

CR_REVIEW_ON_HEAD="$(jq -r --arg sha "$HEAD_SHA" '
  [.comments.reviews[]
   | select(.user.login == "coderabbitai[bot]" and ((.commit_id // "") == $sha))]
  | length > 0
' "$STATE_PATH")"

if [[ "$CR_RATE_LIMITED" != "true" && ! ( "$AGE_SECONDS" -gt 720 && "$CR_REVIEW_ON_HEAD" != "true" ) ]]; then
  emit "polling_cr"
fi

# Content-aware BugBot classification (issue #552): a completed `Cursor Bugbot`
# check-run alone does not mean BugBot actually reviewed the PR — a usage/spend
# limit failure produces the same status=completed/conclusion=neutral tuple as
# a genuine clean pass, and a genuinely blocking conclusion (failure/timed_out/
# etc.) is a different kind of non-review that also isn't a real pass. The
# check-run is already scoped to the current HEAD SHA (pr-state.sh fetches it
# per-commit), so it anchors "what happened on this commit"; when its
# conclusion is ambiguous (completed/neutral, non-blocking, non-failure title)
# the LATEST cursor[bot] comment (by timestamp, not "any historical match")
# disambiguates a usage-limit failure from a genuine clean pass/findings.
#
# Both check-run selectors in this file — the $run classifier below and
# BUGBOT_CHECK_PRESENT after it — match the PUBLISHING APP as well as the name
# (issue #956). GitHub lets any app publish a check-run under any name, so a
# name-only match let a foreign app's `Cursor Bugbot` run stand in for BugBot's
# footprint on this commit. That is not a harmless misread: it shuts the
# never-invited branch below, suppressing the FREE `@cursor review` this script
# would otherwise route to, and spends a PAID Greptile review instead. The
# identity comes from pr-state.sh's bundle, which carries `app: {slug, id}` on
# every check-run entry; check-runs-dedup.sh one step earlier has grouped by
# [.app.slug, .app.id, .name] since issue #675 for the same reason.
#
# Slug `cursor` is the publisher confirmed live on this repo (app id 1210556, app
# name "Cursor"). pr-preflight.sh keeps a wider defensive slug set per reviewer;
# that is deliberately NOT mirrored here because the cost asymmetry runs the
# other way. There an unmatched slug costs one extra trigger; here an over-broad
# match costs paid budget. A missing or foreign slug therefore fails toward "not
# a BugBot footprint": classification falls back to cursor[bot]'s own comments,
# and the worst case is one duplicate `@cursor review`, which bugbot.md calls
# harmless.
read -r BUGBOT_FAILED BUGBOT_GENUINE < <(jq -r '
  def is_cursor_bugbot_check: (.name // "") == "Cursor Bugbot" and (.app.slug // "") == "cursor";
  def is_failure_text: test("couldn.t run|could not run|usage limit|usage or spend limit"; "i");
  def is_blocking_conclusion: . == "failure" or . == "timed_out" or . == "action_required" or . == "startup_failure" or . == "stale";
  def cursor_comments: [.comments.reviews[], .comments.inline[], .comments.conversation[]
    | select(.user.login == "cursor[bot]")];
  def comment_ts: (.submitted_at // .created_at // "");

  (cursor_comments | sort_by(comment_ts) | last) as $latest_comment
  | ([.check_runs.all[] | select(is_cursor_bugbot_check)] | last) as $run
  | ($latest_comment != null and (($latest_comment.body // "") | is_failure_text)) as $latest_comment_failed
  | ($run != null and ((($run.conclusion // "") | is_blocking_conclusion) or (($run.title // "") | is_failure_text))) as $run_definitive_failure
  | ($run != null and ($run.status // "") == "completed" and ($run_definitive_failure | not)) as $run_completed_ambiguous
  | (
      $run_definitive_failure
      or ($run_completed_ambiguous and $latest_comment_failed)
      or ($run == null and $latest_comment_failed)
    ) as $failed
  | (
      ($run_completed_ambiguous and ($latest_comment_failed | not))
      or ($run == null and $latest_comment != null and ($latest_comment_failed | not))
    ) as $genuine
  | [$failed, $genuine] | @tsv
' "$STATE_PATH") || {
  echo "escalate-review.sh: failed to classify BugBot activity" >&2
  exit 4
}

# Same app-scoped predicate as the classifier above (issue #956) — a same-named
# check-run from any other app is not a BugBot footprint on this commit.
BUGBOT_CHECK_PRESENT="$(jq -r '
  def is_cursor_bugbot_check: (.name // "") == "Cursor Bugbot" and (.app.slug // "") == "cursor";
  [.check_runs.all[] | select(is_cursor_bugbot_check)] | length > 0
' "$STATE_PATH")"

# Was BugBot ever INVITED on this HEAD? (issue #935.) BugBot does not auto-review
# pushes — something has to post `@cursor review`, normally the
# cursor-review-pr-comment.yml CI job. Without CURSOR_REVIEW_PAT that job
# concludes success while posting NOTHING (issue #905), so "no BugBot footprint"
# means "never asked", not "asked and failed". This separates the two.
#
# Newest matching comment only; the freshness compare happens in bash below.
# Scoped to `.comments.conversation` (the PR conversation) because that is where
# a trigger is posted, and to non-`cursor[bot]` authors because BugBot quoting
# the phrase back is not an invitation. Narrow on purpose: a missed invite costs
# one duplicate `@cursor review` (harmless per bugbot.md), while a false one
# costs a paid Greptile review. No new gh api call — the bundle is already here
# (meta-guard scenario L).
BUGBOT_TRIGGER_TS="$(jq -r '
  [.comments.conversation[]?
   | select((.user.login // "") != "cursor[bot]")
   | select((.body // "") | test("@cursor\\s+review"; "i"))
   | (.created_at // .submitted_at // "")
   | select(. != "")]
  | sort | last // ""
' "$STATE_PATH")" || {
  echo "escalate-review.sh: failed to scan for a BugBot trigger comment" >&2
  exit 4
}

# Only a trigger that POSTDATES the HEAD commit counts. A trigger left over from
# an earlier SHA must not mask a still-unprovisioned auto-trigger on the new one.
# Both sides go through iso_age_seconds, so this is an integer compare: the
# trigger is fresh when it is no older than the push.
# An unparseable comment timestamp yields age 0, i.e. "fresh" — that keeps the
# pre-#935 escalation behaviour on data we cannot read rather than newly
# granting switch_bugbot on it.
BUGBOT_TRIGGER_PRESENT=false
if [[ -n "$BUGBOT_TRIGGER_TS" ]]; then
  BUGBOT_TRIGGER_AGE="$(iso_age_seconds "$BUGBOT_TRIGGER_TS")"
  if [[ "$BUGBOT_TRIGGER_AGE" -le "$AGE_SECONDS" ]]; then
    BUGBOT_TRIGGER_PRESENT=true
  fi
fi

CACHED_BUGBOT_INSTALLED="$("$SESSION_STATE" --get ".prs[\"$PR_NUMBER\"].bugbot_installed // \"\"" 2>/dev/null || true)"
case "$CACHED_BUGBOT_INSTALLED" in
  true|false)
    BUGBOT_INSTALLED="$CACHED_BUGBOT_INSTALLED"
    ;;
  *)
    if [[ "$BUGBOT_CHECK_PRESENT" == "true" || "$BUGBOT_FAILED" == "true" || "$BUGBOT_GENUINE" == "true" ]]; then
      BUGBOT_INSTALLED="true"
      "$SESSION_STATE" --set ".prs[\"$PR_NUMBER\"].bugbot_installed=true" 2>/dev/null || {
        echo "escalate-review.sh: failed to cache bugbot_installed=true" >&2
        exit 4
      }
    elif [[ "$AGE_SECONDS" -ge 600 ]]; then
      BUGBOT_INSTALLED="false"
      "$SESSION_STATE" --set ".prs[\"$PR_NUMBER\"].bugbot_installed=false" 2>/dev/null || {
        echo "escalate-review.sh: failed to cache bugbot_installed=false" >&2
        exit 4
      }
    else
      BUGBOT_INSTALLED="false"
      emit "polling_cr"
    fi
    ;;
esac

# Design note (issue #844): after the merge-gate.sh fix, switch_bugbot leads to a
# satisfiable gate for BOTH BugBot shapes that BUGBOT_GENUINE covers:
#   - conclusion:success check-run (no review object) — accepted by merge-gate.sh's
#     new check-run path (BB_CHECK_CLEAN); freshness + failure-phrase check there.
#   - conclusion:neutral check-run + review object — accepted by the original review-
#     object path in merge-gate.sh.
# This script derives everything from the pre-built STATE_PATH bundle — no new gh api
# fetch added here (meta-guard test L). The gate-satisfiable evaluation lives in
# merge-gate.sh where CHECK_RUNS_JSON and LAST_COMMIT_TS are already available.
if [[ "$BUGBOT_GENUINE" == "true" ]]; then
  emit "switch_bugbot"
fi

# A usage-limit/couldn't-run failure is not a reason to keep waiting out the
# grace window — BugBot has already failed, so fall through to the Greptile
# budget check below (mirrors the CodeRabbit "rate limit" fast-path).
if [[ "$BUGBOT_FAILED" != "true" && "$BUGBOT_INSTALLED" == "true" && "$AGE_SECONDS" -lt 600 ]]; then
  emit "polling_cr"
fi

# BugBot was NEVER INVITED (issue #935; observed on PRs #929 and #932). With
# CURSOR_REVIEW_PAT unprovisioned the post-cursor-review CI job greens without
# posting anything (issue #905), so cursor[bot] has zero footprint and no
# `Cursor Bugbot` check-run ever appears — the same signature as "BugBot is not
# installed here". Escalating on that jumps the chain past a tier that was never
# asked, which greptile.md forbids ("never before both CR AND BugBot have
# failed") and which spends paid Greptile budget for nothing. The remedy is the
# manual `@cursor review` trigger the switch_bugbot arm posts; both times this
# was hit live, BugBot answered within seconds of being asked.
#
# BUGBOT_TRIGGER_PRESENT is what keeps this from looping (the #552 hazard in
# reverse): once an invite postdating HEAD exists and BugBot is still silent past
# the grace window, that is invited-but-silent and falls through to the Greptile
# escalation below exactly as before.
#
# BUGBOT_GENUINE is already false here (it emits above); restated so the branch
# reads as a complete statement of the state it claims. Every term is scoped to
# the CURRENT HEAD, which is the only question this branch asks. The footprint
# term is BUGBOT_CHECK_PRESENT — read from this commit's check-run bundle — and
# NOT the sticky `bugbot_installed` cache it used to be (issue #948, follow-up to
# PR #945). That cache is per-PR and never reset, so once BugBot answered on any
# earlier SHA it read as "invited here" forever: on a later push where the
# CI auto-trigger posts nothing (issue #905) the PR had no BugBot footprint at
# all, yet this branch stayed shut and escalation spent paid Greptile budget
# instead of posting the free `@cursor review` that resolves it. The cache still
# carries the availability signal for the grace window above; it just no longer
# answers a per-SHA question. Swapping in the live term rather than dropping one
# also keeps the branch faithful to the first paragraph: an in-flight
# `Cursor Bugbot` run on this commit is a footprint, so it still falls through —
# provided Cursor published it (issue #956); a same-named run from another app
# leaves this branch open and routes to the free `@cursor review` instead.
if [[ "$BUGBOT_FAILED" != "true" && "$BUGBOT_GENUINE" != "true" \
      && "$BUGBOT_CHECK_PRESENT" != "true" && "$BUGBOT_TRIGGER_PRESENT" != "true" ]]; then
  emit "switch_bugbot"
fi

BUDGET_CHECK_RC=0
BUDGET_JSON="$("$GREPTILE_BUDGET" --check 2>/dev/null)" || BUDGET_CHECK_RC=$?
if [[ $BUDGET_CHECK_RC -ge 2 ]]; then
  echo "escalate-review.sh: failed to check Greptile budget" >&2
  exit 4
fi

BUDGET_EXHAUSTED="$(jq -r '.exhausted == true' <<<"$BUDGET_JSON")"
if [[ "$BUDGET_EXHAUSTED" == "true" ]]; then
  emit "budget_exhausted"
fi

emit "trigger_greptile"
