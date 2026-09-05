#!/usr/bin/env bash
# pr-preflight.sh — PR pre-flight: draft→ready + four-reviewer trigger (issue #493).
#
# PURPOSE
#   Single source of truth for the per-PR pre-flight run by /fixpr (Step 0c),
#   /babysit-pr (per tick), and /pr-monitor-and-manage (per discovered PR).
#   Two idempotent actions, in order:
#
#     1. Draft check — if the PR isDraft AND the current gh user authored it,
#        flip it ready (`gh pr ready`). If isDraft but authored by someone
#        else, NEVER flip — surface a skip and continue. Author-intentional
#        draft state is never overridden (safety.md).
#     2. Reviewer-trigger check — for each of codeant-ai[bot],
#        coderabbitai[bot], cursor[bot], graphite-app[bot], decide whether that
#        reviewer is engaged ON THE CURRENT HEAD SHA (issue #576). Scans all 3
#        PR endpoints (pulls/reviews, pulls/comments, issues/comments,
#        per_page=100) plus the HEAD commit's check-runs and, for the
#        SHA-less issue-comment path only, the PR timeline (issue #590). A
#        reviewer counts as engaged only when it has a HEAD-fresh artifact,
#        or we already posted its trigger for this HEAD. Otherwise the
#        trigger comment is posted.
#        Greptile is intentionally NOT triggered (stays manual per greptile.md).
#        Before posting `@coderabbitai full review`, gate on
#        cr-review-hourly.sh (--check global budget + read-only --peek-explicit
#        per-PR 2/hour cap). After a successful post, record via --record-explicit
#        (so a failed post never burns a slot). If the cap is hit, skip ONLY
#        CodeRabbit's trigger and still post the other three.
#        Best-effort: two pre-flights racing on the SAME PR within the same second
#        could both pass the peek and double-post; this is an accepted limitation
#        (a lock was removed after it caused ownership bugs and more risk than the
#        rare race it guarded).
#
#   Strictly per-PR: no shared mutable accumulator across a fleet. Running it
#   twice on a clean PR (already ready + all four engaged on HEAD) does nothing
#   and reports "Pre-flight clean — proceeding".
#
# HEAD-SHA FRESHNESS (issue #576)
#   Presence used to be PR-wide: any artifact from a bot on ANY commit marked it
#   `already-present` forever. After a rebase/force-push every such artifact is
#   stale, so pre-flight reported all four engaged while merge-gate.sh correctly
#   reported "need an APPROVED review on HEAD <sha>" — the two disagreed, the
#   re-trigger was skipped, and the PR sat in waiting-on-bots relying on each
#   bot's own auto-review-on-push (not guaranteed). Presence is now evaluated
#   against the current HEAD SHA. A reviewer is engaged on HEAD when ANY holds:
#
#     • a review (pulls/reviews) with .commit_id == HEAD
#     • an inline comment (pulls/comments) with .commit_id == HEAD
#     • a check-run on the HEAD commit whose .app.slug maps to that reviewer
#     • an issue comment (issues/comments) created at/after the HEAD-freshness
#       anchor — issue comments carry NO SHA, so a timestamp comparison is the
#       only signal available for them. The anchor prefers the PR timeline's
#       head_ref_force_pushed/head_ref_pushed event timestamp (GitHub's own
#       clock, stamped when the ref actually moved) and falls back to the HEAD
#       commit's committer date when no such event exists or the timeline call
#       fails (issue #590; see LIMITATION and DEGRADATION below).
#
#   Trigger-comment idempotency is scoped the same way: a trigger posted before
#   the current HEAD existed is stale and does not suppress a fresh trigger.
#
#   LIMITATION (SHA-less issue comments, narrowed by #590): the committer-date
#   proxy had two gaps — a rebase stamps the committer date at REBASE time,
#   which can precede the push by minutes, so a stale-sha comment landing in
#   that window read as fresh; and the committer date is the LOCAL git clock,
#   which can disagree with GitHub's clock by seconds in either direction
#   (observed live on PR #586: an APPROVED review timestamped ~29s before its
#   own reviewed commit's committer date). The timeline's
#   head_ref_force_pushed/head_ref_pushed event — GitHub's own clock, stamped
#   after the ref actually moved — closes both gaps when it exists. What
#   remains: a PR whose HEAD has never been rebased/force-pushed has no such
#   event, so its SHA-less issue-comment freshness still falls back to the
#   HEAD committer date and inherits that proxy's narrower clock-skew exposure
#   (no rebase means no rebase-window gap, just ordinary clock disagreement).
#   Same failure mode as before, same benign direction — a skipped re-trigger,
#   never a false one.
#
# DEGRADATION (deliberately asymmetric — fail toward silence, never toward
# spamming four bots every tick)
#   • Timeline fetch fails, or returns no head_ref_force_pushed/head_ref_pushed
#     event → falls back to the HEAD commit's committer date (unchanged #576
#     proxy). A fetch failure is surfaced as a warning; no matching event is
#     the common, expected case for a PR that has never been rebased and is
#     silent (it is not an error).
#   • HEAD committer date unavailable (fallback path only) → SHA-less issue
#     comments count as present (pre-#576 behavior), surfaced as a warning.
#   • HEAD committer date in the FUTURE (fallback path only; skewed clock on
#     whoever committed) → same path. Otherwise every real comment looks older
#     than HEAD, i.e. every reviewer stale, spending a CodeRabbit slot for
#     nothing.
#   • check-runs fetch fails → that one signal is skipped; reviews and inline
#     comments still decide.
#
# API COST (issue #590)
#   One additional paginated call — repos/{owner}/{repo}/issues/{N}/timeline —
#   per pre-flight run, on top of the existing 5 (PR view, 3 endpoint scans,
#   commit, check-runs). Measured locally against a real (small) PR's timeline
#   on this repo: ~0.7s wall-clock for the call alone. Pre-flight runs once per
#   PR per tick in /babysit-pr and /pr-monitor-and-manage, so this is one extra
#   sub-second `gh api` round-trip per PR per tick — not re-measured against a
#   large/long-lived PR's full timeline history, which would paginate further.
#
# USAGE
#   pr-preflight.sh <pr_number> [--json] [--dry-run]
#   pr-preflight.sh --help | -h
#
# FLAGS
#   --json     Emit only a single-line JSON summary on stdout (no action
#              lines). For tests and machine consumption.
#   --dry-run  Compute draft/reviewer decisions and print/return them WITHOUT
#              flipping draft, posting comments, or recording CR triggers.
#
# OUTPUT
#   Default mode: one timestamped action line per action taken (draft flip,
#   each trigger, each skip) plus a final `PREFLIGHT_SUMMARY: <json>` line that
#   skills splice into their exit-report "Pre-flight" section. When nothing was
#   done, prints a single "Pre-flight clean — proceeding" line.
#   --json mode: the JSON object only.
#
#   JSON shape:
#     {
#       "pr": <N>,
#       "is_draft": <bool>,            # state observed before any flip
#       "author": "<login>",
#       "current_user": "<login>",
#       "head_sha": "<sha>",           # the SHA reviewer freshness was judged
#                                      # against (#576; additive field)
#       "draft_action": "marked-ready" | "would-mark-ready" | "skipped-not-author" | "skipped-auth-unknown" | "not-draft" | "ready-failed",
#       "reviewers": {
#         "codeant":   {"trigger":"@codeant-ai review","status":"<status>"},
#         "coderabbit":{"trigger":"@coderabbitai full review","status":"<status>"},
#         "cursor":    {"trigger":"@cursor review","status":"<status>"},
#         "graphite":  {"trigger":"@graphite-app re-review","status":"<status>"}
#       },
#       "actions": <int>,              # draft flip + triggers actually posted
#       "clean": <bool>                # true ⇒ nothing to do this run
#     }
#   reviewer status ∈ already-present | triggered | skipped-rate-cap |
#                     trigger-failed | dry-run-would-trigger
#
#   Status vocabulary and decision semantics are unchanged by #576 — only the
#   inputs to the decision became SHA-aware, and the JSON gains the additive
#   `head_sha` field. `already-present` still covers both "the bot engaged" and
#   "we already triggered it and it hasn't answered yet", now both scoped to
#   HEAD, so `clean: true` keeps meaning "nothing to do, nothing pending" and
#   existing callers need no changes.
#
# EXIT STATUS
#   0  Success (including clean no-op and rate-cap skip — the skip is surfaced,
#      not an error; the other reviewers still post).
#   2  Usage error.
#   3  PR not found / closed / inaccessible.
#   4  gh / network / API error while reading PR state.
#   70  --help header extraction produced no output (internal defect).
#
# SAFETY (safety.md — absolute)
#   - Never modifies branch protection (no .../branches/.../protection calls).
#   - Never triggers a bot whose rate cap is hit.
#   - Never overrides another user's intentional draft state.
#   - Never triggers Greptile.
#
# DEPENDENCIES
#   gh, jq. Optionally cr-review-hourly.sh (resolved via the standard
#   three-candidate idiom; CR trigger degrades to "skipped-rate-cap" if the
#   helper is missing AND no budget can be confirmed — fail-closed on CR only).
#   Optionally session-state.sh, for the per-SHA trigger dedupe described below;
#   when missing, the on-PR comment scan alone provides idempotency.
#
# PER-SHA TRIGGER DEDUPE (issue #576)
#   After posting a trigger we record `.prs[N].preflight_trigger_head_sha` and
#   `.prs[N].preflight_triggered.<key>` in ~/.claude/session-state.json. On the
#   next tick a reviewer already triggered for THIS HEAD reads back as
#   `already-present` even if GitHub has not yet surfaced our comment on the
#   endpoint scan (eventual consistency) — without this, every tick between the
#   post and its appearance would re-trigger all four bots. The marker is scoped
#   to the SHA, so a new HEAD naturally invalidates it. State-write failures are
#   non-fatal: they can only cost a duplicate trigger, never a missed one.

set -euo pipefail
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" 2>/dev/null >> "$HOME/.claude/script-usage.log" || true

print_help() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; n = 1; next } { exit } END { exit(n ? 0 : 1) }' "$0" ||
    { printf '%s: --help header extraction produced no output\n' "$0" >&2; exit 70; }
}

die_usage() {
  echo "pr-preflight.sh: $1" >&2
  echo "Run with --help for usage." >&2
  exit 2
}

# --- arg parsing ---
PR=""
JSON_OUT=0
DRY_RUN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) print_help; exit 0 ;;
    --json) JSON_OUT=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --) shift; break ;;
    -*) die_usage "unknown flag: $1" ;;
    *)
      if [[ -n "$PR" ]]; then die_usage "unexpected positional argument: $1"; fi
      PR="$1"; shift ;;
  esac
done

if [[ -z "$PR" ]]; then
  die_usage "<pr_number> is required"
fi
if ! [[ "$PR" =~ ^[1-9][0-9]*$ ]]; then
  die_usage "<pr_number> must be a positive integer, got: $PR"
fi

for need in gh jq; do
  if ! command -v "$need" >/dev/null 2>&1; then
    echo "pr-preflight.sh: requires $need on PATH" >&2
    exit 4
  fi
done

# --- timestamped surface helper (ET, per CLAUDE.md #1) ---
surface() {
  # Print one timestamped action line unless in --json mode.
  (( JSON_OUT )) && return 0
  local ts
  ts=$(TZ='America/New_York' date +'%a %b %-d %I:%M %p ET' 2>/dev/null || date -u +'%Y-%m-%dT%H:%M:%SZ')
  echo "[$ts] [preflight #$PR] $*"
}

# --- resolve cr-review-hourly.sh (standard three-candidate idiom; env override for tests) ---
resolve_cr_hourly() {
  if [[ -n "${PREFLIGHT_CR_HOURLY_SH:-}" && -x "${PREFLIGHT_CR_HOURLY_SH}" ]]; then
    echo "$PREFLIGHT_CR_HOURLY_SH"; return 0
  fi
  local candidate
  for candidate in \
    "$HOME/.claude/skills-worktree/.claude/scripts/cr-review-hourly.sh" \
    "$HOME/.claude/scripts/cr-review-hourly.sh" \
    ".claude/scripts/cr-review-hourly.sh"; do
    if [[ -x "$candidate" ]]; then echo "$candidate"; return 0; fi
  done
  return 1
}
CR_HOURLY_SH="$(resolve_cr_hourly || true)"

# --- resolve session-state.sh (per-SHA trigger dedupe; optional) ---
resolve_state_helper() {
  if [[ -n "${PREFLIGHT_SESSION_STATE_SH:-}" ]]; then
    # Explicit override (tests): honor it even if non-executable, so a bogus
    # path degrades to "no dedupe" rather than silently finding a real helper.
    [[ -x "${PREFLIGHT_SESSION_STATE_SH}" ]] && { echo "$PREFLIGHT_SESSION_STATE_SH"; return 0; }
    return 1
  fi
  local candidate
  for candidate in \
    "$HOME/.claude/skills-worktree/.claude/scripts/session-state.sh" \
    "$HOME/.claude/scripts/session-state.sh" \
    ".claude/scripts/session-state.sh"; do
    if [[ -x "$candidate" ]]; then echo "$candidate"; return 0; fi
  done
  return 1
}
STATE_SH="$(resolve_state_helper || true)"
# NOTE: deliberately no STATE_FILE of our own. session-state.sh owns the file
# location (it hardcodes $HOME/.claude/session-state.json), so a path variable
# here could only ever disagree with the helper that actually does the reads and
# writes. Every access below goes through "$STATE_SH", which returns empty for a
# missing file or absent path — the same signal we'd get from an -f test.

# --- resolve review-substance.sh (shared substance evaluator; env override for tests) ---
# Used by review_object_engaged() to detect hollow APPROVED reviews so preflight
# does not count them as "engaged" — the same evaluator merge-gate.sh uses for
# the #875 substance check (issue #1226). Sibling path is preferred so tests and
# production both find the script beside pr-preflight.sh.
resolve_review_substance() {
  if [[ -n "${PREFLIGHT_REVIEW_SUBSTANCE_SH:-}" ]]; then
    # Explicit override (tests): honor it even if non-executable, so a bogus
    # path degrades to "evaluator unavailable" rather than silently finding the
    # sibling — mirrors resolve_state_helper()'s contract exactly.
    [[ -x "${PREFLIGHT_REVIEW_SUBSTANCE_SH}" ]] && { echo "$PREFLIGHT_REVIEW_SUBSTANCE_SH"; return 0; }
    return 1
  fi
  local dir candidate
  dir="$(cd "$(dirname "$0")" && pwd)"
  for candidate in \
    "$dir/review-substance.sh" \
    "$HOME/.claude/skills-worktree/.claude/scripts/review-substance.sh" \
    "$HOME/.claude/scripts/review-substance.sh" \
    ".claude/scripts/review-substance.sh"; do
    if [[ -x "$candidate" ]]; then echo "$candidate"; return 0; fi
  done
  return 1
}
REVIEW_SUBSTANCE_SH="$(resolve_review_substance || true)"

# --- 1. read PR draft state + author + HEAD sha ---
PR_VIEW_ERR="$(mktemp)"

# headRefOid is the authoritative current HEAD SHA (same field merge-gate.sh and
# pr-state.sh use). Fetched in the SAME call as the draft/author fields — no
# extra API round-trip for the #576 freshness check.
if ! PR_VIEW="$(gh pr view "$PR" --json isDraft,author,state,headRefOid 2>"$PR_VIEW_ERR")"; then
  if grep -qiE 'not.?found|could not resolve|no pull requests? found|no such' "$PR_VIEW_ERR"; then
    echo "pr-preflight.sh: PR #$PR not found" >&2
    exit 3
  fi
  echo "pr-preflight.sh: gh pr view failed: $(cat "$PR_VIEW_ERR")" >&2
  exit 4
fi

IS_DRAFT="$(jq -r '.isDraft // false' <<<"$PR_VIEW")"
PR_AUTHOR="$(jq -r '.author.login // ""' <<<"$PR_VIEW")"
PR_STATE="$(jq -r '.state // ""' <<<"$PR_VIEW")"
HEAD_SHA="$(jq -r '.headRefOid // ""' <<<"$PR_VIEW")"

if [[ "$PR_STATE" != "OPEN" ]]; then
  echo "pr-preflight.sh: PR #$PR is $PR_STATE — pre-flight only runs on OPEN PRs" >&2
  exit 3
fi

# Current authenticated user (for the author-match draft rule).
CURRENT_USER="$(gh api user --jq .login 2>/dev/null || echo "")"

# --- 2. scan all 3 endpoints + HEAD check-runs, keeping per-artifact SHA/date ---
# Pre-#576 this collapsed everything into a flat login set and a flat body list,
# which is exactly why staleness was invisible. Each artifact now keeps the
# fields needed to decide freshness against HEAD.
ARTIFACTS_TMP="$(mktemp)"   # login US commit_id US created_at US collapsed_body US type(r/c/i)
SLUGS_TMP="$(mktemp)"       # app.slug of each check-run on the HEAD commit
TIMELINE_TMP="$(mktemp)"    # created_at of each head_ref_force_pushed/head_ref_pushed event
GH_ERR="$(mktemp)"
trap 'rm -f "$PR_VIEW_ERR" "$ARTIFACTS_TMP" "$SLUGS_TMP" "$TIMELINE_TMP" "$GH_ERR" 2>/dev/null' EXIT

# SHA field: prefer .original_commit_id, fall back to .commit_id.
#
# For an INLINE comment these differ, and the difference is load-bearing.
# .original_commit_id is the commit the reviewer actually reviewed;
# .commit_id is "the newest commit this comment still applies to" — GitHub
# RE-POINTS it as the PR head moves. Observed live on PR #586: a CodeAnt inline
# comment written at 18:13 against 2193d77 reported commit_id=ff42856 minutes
# after a force-push — a SHA that did not exist when the comment was made.
# Keying freshness off .commit_id would mark a bot "engaged on HEAD" on the
# strength of a comment from a superseded commit: the exact #576 bug, re-entering
# through a different field.
#
# Reviews (pulls/reviews) carry only .commit_id, and GitHub does NOT re-point it
# (verified on #586: older COMMENTED reviews stayed pinned to 2193d77 across the
# push), so the fallback is correct for them. Issue comments have neither → "".
#
# Field separator is ASCII Unit Separator (0x1f), NOT tab. Tab is IFS
# *whitespace*, and bash collapses runs of IFS whitespace into ONE delimiter —
# so a row with an empty commit_id (every issue comment: they carry no SHA)
# would silently lose that field and shift date/body left by one, making every
# SHA-less artifact unparseable. 0x1f is not IFS whitespace, so empty fields
# survive. It also cannot occur in real GitHub content, unlike tab.
#
# `@tsv` would need per-endpoint field lists; a manual join keeps a consistent
# shape across all three endpoints. Body is the 4th field; the 5th is a static
# endpoint-type tag ("r"/"c"/"i"). Separators/newlines are stripped from the
# body so a hostile body cannot forge the type tag (issue #1226).
US=$'\037'
# Per-endpoint jq filters.  Each row has 5 US-separated fields:
#   login | sha | date | body | type
# "type" distinguishes the endpoint so login_fresh_on_head() can apply the
# substance check only to review objects (issue #1226):
#   "r"  = review object  (pulls/reviews)      - substance-checked for codeant/coderabbit
#   "c"  = inline comment (pulls/comments)     - always counts as engagement on HEAD
#   "i"  = issue comment  (issues/PR comments) - SHA-less, freshness checked by date
ARTIFACT_JQ_REVIEW='.[]? | [
    (.user.login // ""),
    (.original_commit_id // .commit_id // ""),
    (.submitted_at // .created_at // ""),
    ((.body // "") | gsub("[\r\n\t\u001f]+"; " ")),
    "r"
  ] | join("\u001f")'
ARTIFACT_JQ_INLINE='.[]? | [
    (.user.login // ""),
    (.original_commit_id // .commit_id // ""),
    (.submitted_at // .created_at // ""),
    ((.body // "") | gsub("[\r\n\t\u001f]+"; " ")),
    "c"
  ] | join("\u001f")'
ARTIFACT_JQ_ISSUE='.[]? | [
    (.user.login // ""),
    (.original_commit_id // .commit_id // ""),
    (.submitted_at // .created_at // ""),
    ((.body // "") | gsub("[\r\n\t\u001f]+"; " ")),
    "i"
  ] | join("\u001f")'

# Fetch all three endpoints as raw JSON so we can both populate ARTIFACTS_TMP
# and pass the raw payloads to review-substance.sh (issue #1226).
RAW_REVIEWS_JSON="[]"
RAW_INLINE_JSON="[]"
RAW_ISSUE_JSON="[]"

if ! RAW_REVIEWS_JSON="$(gh api --paginate "repos/{owner}/{repo}/pulls/$PR/reviews?per_page=100" 2>"$GH_ERR")"; then
  echo "pr-preflight.sh: failed to scan pulls reviews: $(cat "$GH_ERR")" >&2
  exit 4
fi
if ! RAW_INLINE_JSON="$(gh api --paginate "repos/{owner}/{repo}/pulls/$PR/comments?per_page=100" 2>"$GH_ERR")"; then
  echo "pr-preflight.sh: failed to scan pulls comments: $(cat "$GH_ERR")" >&2
  exit 4
fi
if ! RAW_ISSUE_JSON="$(gh api --paginate "repos/{owner}/{repo}/issues/$PR/comments?per_page=100" 2>"$GH_ERR")"; then
  echo "pr-preflight.sh: failed to scan issue comments: $(cat "$GH_ERR")" >&2
  exit 4
fi

printf '%s\n' "$RAW_REVIEWS_JSON" | jq -r "$ARTIFACT_JQ_REVIEW" >>"$ARTIFACTS_TMP"
printf '%s\n' "$RAW_INLINE_JSON"  | jq -r "$ARTIFACT_JQ_INLINE"  >>"$ARTIFACTS_TMP"
printf '%s\n' "$RAW_ISSUE_JSON"   | jq -r "$ARTIFACT_JQ_ISSUE"   >>"$ARTIFACTS_TMP"


# HEAD freshness anchor for SHA-less issue comments (issue #590). Preferred
# source: the PR timeline's head_ref_force_pushed/head_ref_pushed event —
# GitHub's own clock, stamped when the ref actually moved. Falls back to the
# HEAD commit's committer date (the original #576 proxy, logic unchanged
# below) when no such event exists or the timeline call fails. Either stage
# failing is NON-fatal (see DEGRADATION).
TIMELINE_JQ='.[]? | select(.event=="head_ref_force_pushed" or .event=="head_ref_pushed") | (.created_at // empty)'
HEAD_PUSH_DATE=""
if [[ -n "$HEAD_SHA" ]]; then
  if gh api --paginate "repos/{owner}/{repo}/issues/$PR/timeline?per_page=100" \
       --jq "$TIMELINE_JQ" >"$TIMELINE_TMP" 2>"$GH_ERR"; then
    # Latest event wins when a PR was rebased more than once. ISO-8601 UTC
    # timestamps sort lexicographically (same rationale as at_or_after_head).
    HEAD_PUSH_DATE="$(LC_ALL=C sort "$TIMELINE_TMP" | tail -1)"
  else
    surface "WARNING: could not read PR timeline for #$PR — falling back to HEAD commit committer date: $(cat "$GH_ERR")"
  fi
fi

if [[ -n "$HEAD_PUSH_DATE" ]]; then
  HEAD_DATE="$HEAD_PUSH_DATE"
else
  # HEAD committer date — the fallback freshness signal for SHA-less issue
  # comments. Failure is NON-fatal and degrades to pre-#576 behavior (see
  # DEGRADATION).
  HEAD_DATE=""
  if [[ -n "$HEAD_SHA" ]]; then
    HEAD_DATE="$(gh api "repos/{owner}/{repo}/commits/$HEAD_SHA" \
                   --jq '.commit.committer.date // ""' 2>/dev/null || echo "")"
  fi
  # A future-dated HEAD commit (skewed clock on whoever rebased — committer date
  # comes from that machine's clock) would make every real comment look older than
  # HEAD, i.e. every reviewer stale. The per-SHA dedupe bounds that to one trigger
  # per SHA rather than a per-tick storm, but it still spends a CodeRabbit slot for
  # nothing. Treat it as an unreadable date and take the same degradation path.
  # The false-positive direction (a *local* clock running behind GitHub's) merely
  # degrades to "present" — the safe side, consistent with the rule above.
  if [[ -z "$HEAD_DATE" ]]; then
    surface "WARNING: could not read HEAD commit date for ${HEAD_SHA:0:7} — treating SHA-less issue comments as engaged (pre-#576 behavior); a stale reviewer may not be re-triggered this run"
  else
    # `[` is a regular builtin, so an assignment prefix is legal here — unlike the
    # `[[` keyword (see at_or_after_head).
    NOW_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if LC_ALL=C [ "$HEAD_DATE" \> "$NOW_UTC" ]; then
      surface "WARNING: HEAD commit date ($HEAD_DATE) is in the future — ignoring it (clock skew on the machine that committed?); treating SHA-less issue comments as engaged this run"
      HEAD_DATE=""
    fi
  fi
fi

# --- substance evidence for review objects (issue #1226) ---
# Evaluate the substantive footprint of codeant-ai[bot] and coderabbitai[bot]
# reviews using the same evaluator as merge-gate.sh (#875). The result is
# consumed by review_object_engaged() so that login_fresh_on_head() can skip
# hollow APPROVED reviews that merge-gate.sh would reject.
# Degradation: if REVIEW_SUBSTANCE_SH is unavailable or fails, leave
# PREFLIGHT_REVIEW_EVIDENCE as "{}" — review_object_engaged() degrades to
# "engaged" (fail toward silence) in that case.
#
# `resolved_comment_ids` (issue #1632) is deliberately NOT supplied here. This
# script fetches no review-thread data, and its only consumer of the verdict is
# review_object_engaged(), which decides whether to RE-TRIGGER a bot. Omitting
# the key means an earlier run's resolved findings still count, so a redeemable
# approval reads as not-coverage and the bot is re-triggered — which is the
# documented remedy for that state anyway. It fails toward noise, never toward a
# laundered gate. Add a reviewThreads fetch here if that ever stops being true.
PREFLIGHT_REVIEW_EVIDENCE="{}"
if [[ -n "${REVIEW_SUBSTANCE_SH:-}" && -n "$HEAD_SHA" ]]; then
  # Merge each endpoint's pages explicitly before building the payload (issue #1226).
  # gh api --paginate can emit multiple JSON arrays when a result spans pages; jq
  # --argjson with `jq -s 'add // []'` collapses them into one flat array per
  # endpoint regardless of how many pages the endpoint returned.
  PREFLIGHT_REVIEW_EVIDENCE="$(
    jq -n \
      --arg sha "$HEAD_SHA" \
      --arg push "${HEAD_DATE:-}" \
      --argjson reviews "$(printf '%s\n' "$RAW_REVIEWS_JSON" | jq -s 'add // []')" \
      --argjson pr_comments "$(printf '%s\n' "$RAW_INLINE_JSON" | jq -s 'add // []')" \
      --argjson issue_comments "$(printf '%s\n' "$RAW_ISSUE_JSON" | jq -s 'add // []')" \
      '{head_sha: $sha, push_ts: $push, reviews: $reviews, pr_comments: $pr_comments, issue_comments: $issue_comments}' \
      | "$REVIEW_SUBSTANCE_SH" 2>/dev/null
  )" || PREFLIGHT_REVIEW_EVIDENCE="{}"
  [[ -z "$PREFLIGHT_REVIEW_EVIDENCE" ]] && PREFLIGHT_REVIEW_EVIDENCE="{}"
fi

# Check-runs on the HEAD commit. Keyed by commit, so a matching app slug is a
# strong HEAD-freshness signal (verified: Cursor posts `Cursor Bugbot` under
# slug `cursor`). Non-fatal: one signal among several.
# Fetches whole run objects and reads the slug off the deduped set, so this script
# sees the same check-runs view as ci-status.sh and pr-state.sh (issue #675). The
# slug SET is provably unchanged by that dedup — grouping is per (app, check name)
# and every group keeps at least one run, so no app can lose its only run. It is
# applied anyway to keep one shared view across all three consumers, and to stay
# correct if this extraction ever widens past `app.slug` to a field a superseded
# run could distort.
if [[ -n "$HEAD_SHA" ]]; then
  gh api --paginate "repos/{owner}/{repo}/commits/$HEAD_SHA/check-runs?per_page=100" \
    --jq '.check_runs[]?' 2>/dev/null \
    | "$(cd "$(dirname "$0")" && pwd)/check-runs-dedup.sh" 2>/dev/null \
    | jq -r '.[] | (.app.slug // empty)' >>"$SLUGS_TMP" 2>/dev/null || true
fi

# ISO-8601 UTC (`...Z`) timestamps from the GitHub API sort lexicographically,
# so a plain string compare is a correct chronological compare. LC_ALL=C keeps
# that true regardless of the caller's locale collation.
at_or_after_head() {
  # $1 = artifact timestamp. True when it is at/after the HEAD commit date.
  local ts="$1"
  [[ -z "$ts" || -z "$HEAD_DATE" ]] && return 1
  # `local LC_ALL=C` (NOT an `LC_ALL=C [[ ... ]]` prefix — an assignment prefix
  # applies only to external commands, and would make bash parse `[[` as a
  # command name). Function-scoped, so collation is pinned for the compare and
  # restored on return.
  local LC_ALL=C
  [[ ! "$ts" < "$HEAD_DATE" ]]
}

review_object_engaged() {
  # $1 = exact bot login. Returns 0 when the reviewer has a substantive
  # footprint on HEAD (non-empty body, inline comments, or a status comment
  # naming HEAD). Only applies to codeant-ai[bot] and coderabbitai[bot];
  # other reviewers' review objects always count as engaged to preserve
  # pre-#1226 behavior. (issue #1226)
  local login="$1"
  case "$login" in
    "codeant-ai[bot]"|"coderabbitai[bot]") ;;
    *) return 0 ;;  # outside scope: unconditionally engaged
  esac
  # Degrade to "engaged" (fail toward silence) when the evaluator was
  # unavailable or returned empty/invalid output.
  [[ -z "${PREFLIGHT_REVIEW_EVIDENCE:-}" || "$PREFLIGHT_REVIEW_EVIDENCE" == "{}" ]] && return 0
  # For APPROVED reviews: require .counts_as_coverage (substantive + no
  # disqualifiers — same gate as merge-gate.sh). A disqualified approval
  # (temporal inversion, capability failure, self-report SHA mismatch) must not
  # suppress a re-trigger even when the body is long enough.
  # For non-APPROVED reviews (CHANGES_REQUESTED, COMMENTED): .substantive alone
  # suffices — the bot already reviewed and posted meaningful findings.
  printf '%s' "$PREFLIGHT_REVIEW_EVIDENCE" \
    | jq -e --arg l "$login" '
        .reviewers[$l] |
        ((.counts_as_coverage // false)
         or ((.approved_on_head // false | not) and (.substantive // false)))
      ' >/dev/null 2>&1
}

login_fresh_on_head() {
  # $1 = exact bot login (e.g. coderabbitai[bot]); $2 = reviewer key.
  # Engaged on HEAD when ANY signal in the HEAD-SHA FRESHNESS table holds.
  local login="$1" key="$2" a_login a_sha a_date a_type

  # No HEAD SHA (unexpected — headRefOid absent from the PR view): every
  # freshness test would fail and we would trigger all four bots on every tick.
  # Degrade to pre-#576 PR-wide presence instead — fail toward silence.
  if [[ -z "$HEAD_SHA" ]]; then
    cut -d"$US" -f1 "$ARTIFACTS_TMP" | grep -qxF -- "$login" && return 0
    return 1
  fi

  # (a) check-run on the HEAD commit from this reviewer's app.
  local slug
  for slug in $(reviewer_check_slugs "$key"); do
    grep -qxF -- "$slug" "$SLUGS_TMP" && return 0
  done

  # (b) review / inline comment on HEAD, or (c) SHA-less issue comment at or
  # after the HEAD commit date.
  while IFS="$US" read -r a_login a_sha a_date _ a_type; do
    [[ "$a_login" == "$login" ]] || continue
    if [[ -n "$a_sha" ]]; then
      if [[ "$a_sha" == "$HEAD_SHA" ]]; then
        # Review objects (type "r") from codeant/coderabbit must carry a
        # substantive footprint to count as engaged — catches hollow APPROVED
        # reviews that merge-gate.sh would reject (issue #1226). Inline diff
        # comments (type "c") are always substantive by definition.
        if [[ "${a_type:-}" == "r" ]]; then
          review_object_engaged "$login" && return 0
        else
          return 0
        fi
      fi
    else
      # No SHA to compare (issue comment). With no HEAD date to compare
      # against either, fail toward pre-#576 "present" rather than re-trigger.
      [[ -z "$HEAD_DATE" ]] && return 0
      at_or_after_head "$a_date" && return 0
    fi
  done < "$ARTIFACTS_TMP"

  return 1
}

trigger_fresh_for_head() {
  # $1 = literal trigger string. True when WE already posted that trigger for
  # the current HEAD (so the bot is engaged/pending and must not be re-poked).
  # A trigger that pre-dates HEAD is stale — it was aimed at an older commit —
  # and must NOT suppress a fresh trigger (the #565 regression).
  #
  # Whole-line match on the collapsed body, so prose mentions of the trigger
  # ("I ran @coderabbitai full review earlier") still do not suppress a real
  # trigger post — a trigger comment we posted is exactly that string.
  local trigger="$1" a_sha a_date a_body
  while IFS="$US" read -r _ a_sha a_date a_body _; do
    [[ "$a_body" == "$trigger" ]] || continue
    # Only a SHA-less artifact can be one of OUR triggers: post_trigger posts via
    # `gh pr comment`, which creates an issue comment (no commit_id). A
    # SHA-bearing artifact whose body happens to equal the trigger string is
    # someone else's review/inline comment quoting it — it must not suppress.
    [[ -n "$a_sha" ]] && continue
    # Same degradation rule as above: with no HEAD sha/date to compare against,
    # treat any prior trigger as fresh (pre-#576 behavior).
    [[ -z "$HEAD_SHA" || -z "$HEAD_DATE" ]] && return 0
    at_or_after_head "$a_date" && return 0
  done < "$ARTIFACTS_TMP"
  return 1
}

triggered_for_head_in_state() {
  # $1 = reviewer key. True when a prior run in this session already posted this
  # reviewer's trigger for the CURRENT HEAD. Covers the window where our comment
  # is posted but not yet visible to the endpoint scan (GitHub eventual
  # consistency), which would otherwise re-trigger all four bots every tick.
  local key="$1"
  [[ -z "$STATE_SH" || -z "$HEAD_SHA" ]] && return 1
  local recorded_sha
  recorded_sha="$("$STATE_SH" --get ".prs[\"$PR\"].preflight_trigger_head_sha" 2>/dev/null || echo "")"
  [[ "$recorded_sha" == "$HEAD_SHA" ]] || return 1   # marker is for another SHA ⇒ stale
  local flag
  flag="$("$STATE_SH" --get ".prs[\"$PR\"].preflight_triggered.$key" 2>/dev/null || echo "")"
  [[ "$flag" == "true" ]]
}

record_trigger_for_head() {
  # Persist the per-SHA dedupe marker after a successful post. Best-effort:
  # a failure here can only cost a duplicate trigger next tick, never a missed
  # one, so it never fails the run.
  local key="$1"
  [[ -z "$STATE_SH" || -z "$HEAD_SHA" ]] && return 0
  local recorded_sha
  recorded_sha="$("$STATE_SH" --get ".prs[\"$PR\"].preflight_trigger_head_sha" 2>/dev/null || echo "")"
  if [[ "$recorded_sha" == "$HEAD_SHA" ]]; then
    # Same HEAD — add this key alongside any already recorded.
    "$STATE_SH" --set ".prs[\"$PR\"].preflight_triggered.$key=true" >/dev/null 2>&1 || true
  else
    # HEAD moved (or first record for this PR): REPLACE the map rather than
    # merging into it. Carrying flags over from the old SHA while stamping the
    # new SHA would mark those reviewers triggered-for-HEAD when they were only
    # triggered for the parent commit — suppressing exactly the re-trigger #576
    # exists to perform. One atomic write keeps sha+map consistent.
    "$STATE_SH" \
      --set ".prs[\"$PR\"].preflight_trigger_head_sha=\"$HEAD_SHA\"" \
      --set ".prs[\"$PR\"].preflight_triggered={\"$key\":true}" >/dev/null 2>&1 || true
  fi
}

# --- 3. draft check ---
DRAFT_ACTION="not-draft"
if [[ "$IS_DRAFT" == "true" ]]; then
  if [[ -z "$CURRENT_USER" ]]; then
    DRAFT_ACTION="skipped-auth-unknown"
    surface "WARNING: could not determine current user (gh api user failed) — leaving #$PR as draft; cannot verify authorship"
  elif [[ "$PR_AUTHOR" == "$CURRENT_USER" ]]; then
    if (( DRY_RUN )); then
      DRAFT_ACTION="would-mark-ready"
      surface "draft by you (@$PR_AUTHOR) — would mark ready (dry-run)"
    elif gh pr ready "$PR" >/dev/null 2>&1; then
      DRAFT_ACTION="marked-ready"
      surface "Marked #$PR ready for review"
    else
      DRAFT_ACTION="ready-failed"
      surface "WARNING: failed to mark #$PR ready (gh pr ready errored) — leaving as draft"
    fi
  else
    DRAFT_ACTION="skipped-not-author"
    surface "PR #$PR is draft (author: @${PR_AUTHOR:-unknown}) — skipping pre-flight ready"
  fi
fi

# --- 4. reviewer-trigger check ---
# Ordered list: key | bot-login | trigger-string. Greptile intentionally absent.
# Graphite known outage (issue #610, confirmed 2026-07-21): zero engagement (no
# comments, no check-runs) on every PR since 2026-05-08 — external GitHub App
# issue, not fixable from this script. Kept in the trigger set anyway (cheap,
# self-healing) — see .claude/reference/codeant-graphite-supplemental.md.
REVIEWER_KEYS=(codeant coderabbit cursor graphite)
# Bash 3.2-compatible (macOS default ships Bash 3.2): NO associative arrays.
# `declare -A` is a syntax error on Bash 3 and, under `set -euo pipefail`, aborts
# the script immediately (issue #494). Map key->login and key->trigger via case;
# store per-reviewer status in dynamic REVIEWER_STATUS_<key> variables addressed
# with printf -v / indirect expansion.
reviewer_login() {
  case "$1" in
    codeant)    printf '%s' "codeant-ai[bot]" ;;
    coderabbit) printf '%s' "coderabbitai[bot]" ;;
    cursor)     printf '%s' "cursor[bot]" ;;
    graphite)   printf '%s' "graphite-app[bot]" ;;
  esac
}
reviewer_trigger() {
  case "$1" in
    codeant)    printf '%s' "@codeant-ai review" ;;
    coderabbit) printf '%s' "@coderabbitai full review" ;;
    cursor)     printf '%s' "@cursor review" ;;
    graphite)   printf '%s' "@graphite-app re-review" ;;
  esac
}
reviewer_check_slugs() {
  # GitHub App slug(s) whose check-runs on the HEAD commit prove this reviewer
  # ran against HEAD. Space-separated; a reviewer may ship under more than one
  # slug, and not every reviewer posts a check-run at all (in which case this
  # signal simply never fires and reviews/comments decide). Confirmed on this
  # repo: `cursor` → "Cursor Bugbot". The others are the vendors' documented
  # app slugs, matched defensively — an unmatched slug costs nothing.
  case "$1" in
    codeant)    printf '%s' "codeant-ai codeant" ;;
    coderabbit) printf '%s' "coderabbitai coderabbit" ;;
    cursor)     printf '%s' "cursor cursor-com" ;;
    graphite)   printf '%s' "graphite-app graphite" ;;
  esac
}
set_status() { printf -v "REVIEWER_STATUS_$1" '%s' "$2"; }
get_status() { local __v="REVIEWER_STATUS_$1"; printf '%s' "${!__v-}"; }

ACTIONS=0
[[ "$DRAFT_ACTION" == "marked-ready" ]] && ACTIONS=$((ACTIONS + 1))

# CR budget gate. Returns 0 if a CR trigger may be posted (and, when not
# dry-run, atomically reserves one explicit-trigger slot). Returns non-zero
# (caller skips) when the global hourly budget or per-PR 2/hour cap is hit, or
# the helper is missing (fail-closed on CR only — never spam CodeRabbit).
cr_budget_allows() {
  # Pre-gate ONLY (no consumption): global hourly budget (--check) + a read-only
  # per-PR cap peek (--peek-explicit). The per-PR slot is recorded in post_trigger
  # AFTER a successful `gh pr comment`, so a failed post never burns a slot with no
  # trigger on the PR (issue #494 BugBot — "CR recorded before comment posts").
  if [[ -z "$CR_HOURLY_SH" ]]; then
    surface "CodeRabbit helper (cr-review-hourly.sh) not found — skipping @coderabbitai full review (fail-closed)"
    return 1
  fi
  if ! "$CR_HOURLY_SH" --check >/dev/null 2>&1; then
    return 1   # global hourly budget exhausted
  fi
  # Non-consuming per-PR cap check (exit 1 at global-exhausted or >=2/hour cap).
  # Runs in dry-run too (--peek-explicit is read-only; no slot consumed).
  if ! "$CR_HOURLY_SH" --peek-explicit "$PR" >/dev/null 2>&1; then
    return 1
  fi
  return 0
}

post_trigger() {
  # $1 = reviewer key
  local key="$1" trigger
  trigger="$(reviewer_trigger "$1")"
  if (( DRY_RUN )); then
    set_status "$key" "dry-run-would-trigger"
    surface "would trigger $key: $trigger (dry-run)"
    return 0
  fi
  if gh pr comment "$PR" --body "$trigger" >/dev/null 2>&1; then
    set_status "$key" "triggered"
    ACTIONS=$((ACTIONS + 1))
    surface "triggered $key: $trigger"
    # Per-SHA dedupe marker — only after a successful post, mirroring the CR
    # slot-recording rule below (a failed post must not suppress a retry).
    record_trigger_for_head "$key"
    # Record CodeRabbit's per-PR explicit-trigger slot ONLY after a successful
    # post, so a failed `gh pr comment` never consumes the cap with no trigger on
    # the PR (issue #494 BugBot). Other reviewers have no per-PR cap to record.
    if [[ "$key" == "coderabbit" && -n "$CR_HOURLY_SH" ]]; then
      if ! "$CR_HOURLY_SH" --record-explicit "$PR" >/dev/null 2>&1; then
        # Retry once; if still fails, surface a loud budget-undercount warning.
        if ! "$CR_HOURLY_SH" --record-explicit "$PR" >/dev/null 2>&1; then
          surface "WARNING: CR trigger posted to #$PR but recording the hourly/per-PR slot FAILED twice — the global CR budget is now UNDERCOUNTED by 1. Reconcile cr_hourly.events before relying on the CR rate cap."
        fi
      fi
    fi
  else
    set_status "$key" "trigger-failed"
    surface "WARNING: failed to post $key trigger ($trigger) — check gh auth/scopes"
  fi
}

for key in "${REVIEWER_KEYS[@]}"; do
  login="$(reviewer_login "$key")"
  trigger="$(reviewer_trigger "$key")"
  # Idempotency, all three scoped to the CURRENT HEAD (issue #576): the bot has
  # a HEAD-fresh artifact, OR we already posted its trigger for this HEAD, OR
  # this session recorded that trigger for this HEAD (comment not yet visible).
  # Anything older belongs to a superseded commit and must not suppress.
  if login_fresh_on_head "$login" "$key" \
     || trigger_fresh_for_head "$trigger" \
     || triggered_for_head_in_state "$key"; then
    set_status "$key" "already-present"
    continue
  fi
  if [[ "$key" == "coderabbit" ]]; then
    if cr_budget_allows; then
      post_trigger "$key"
    else
      set_status "$key" "skipped-rate-cap"
      surface "skipping @coderabbitai full review — CR rate cap hit (posting the other reviewers)"
    fi
  else
    post_trigger "$key"
  fi
done

# --- 5. clean determination + summary ---
# Clean ⇒ nothing was done and nothing is pending: not flipped, and every
# reviewer was already-present (no triggers, no skips, no failures).
CLEAN=true
# Any draft action other than a genuine "not-draft" means work happened or the PR
# is still a draft (marked-ready / skipped-not-author / ready-failed) — not clean.
# ready-failed in particular keeps is_draft true, so clean MUST be false even when
# all four reviewers are present (issue #494 BugBot — "False clean after ready failure").
[[ "$DRAFT_ACTION" != "not-draft" ]] && CLEAN=false
for key in "${REVIEWER_KEYS[@]}"; do
  [[ "$(get_status "$key")" != "already-present" ]] && CLEAN=false
done

if [[ "$CLEAN" == "true" ]]; then
  surface "Pre-flight clean — proceeding"
fi

SUMMARY="$(jq -n \
  --argjson pr "$PR" \
  --argjson is_draft "$([[ "$IS_DRAFT" == "true" ]] && echo true || echo false)" \
  --arg author "$PR_AUTHOR" \
  --arg current_user "$CURRENT_USER" \
  --arg head_sha "$HEAD_SHA" \
  --arg draft_action "$DRAFT_ACTION" \
  --argjson actions "$ACTIONS" \
  --argjson clean "$CLEAN" \
  --arg ca_t "$(reviewer_trigger codeant)"    --arg ca_s "$(get_status codeant)" \
  --arg cr_t "$(reviewer_trigger coderabbit)" --arg cr_s "$(get_status coderabbit)" \
  --arg cu_t "$(reviewer_trigger cursor)"     --arg cu_s "$(get_status cursor)" \
  --arg gr_t "$(reviewer_trigger graphite)"   --arg gr_s "$(get_status graphite)" \
  '{
    pr: $pr,
    is_draft: $is_draft,
    author: $author,
    current_user: $current_user,
    head_sha: $head_sha,
    draft_action: $draft_action,
    reviewers: {
      codeant:    {trigger: $ca_t, status: $ca_s},
      coderabbit: {trigger: $cr_t, status: $cr_s},
      cursor:     {trigger: $cu_t, status: $cu_s},
      graphite:   {trigger: $gr_t, status: $gr_s}
    },
    actions: $actions,
    clean: $clean
  }')"

if (( JSON_OUT )); then
  jq -c . <<<"$SUMMARY"
else
  echo "PREFLIGHT_SUMMARY: $(jq -c . <<<"$SUMMARY")"
fi
exit 0
