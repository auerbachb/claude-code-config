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
#        coderabbitai[bot], cursor[bot], graphite-app[bot], scan all 3 PR
#        endpoints (pulls/reviews, pulls/comments, issues/comments,
#        per_page=100) for ANY artifact from that login OR a prior trigger
#        comment for it. If neither exists, post the matching trigger comment.
#        Greptile is intentionally NOT triggered (stays manual per greptile.md).
#        Before posting `@coderabbitai full review`, gate on
#        cr-review-hourly.sh (--check global budget + read-only --peek-explicit
#        per-PR 2/hour cap). After a successful post, record via --record-explicit
#        under a per-PR mkdir lock so concurrent pre-flights cannot double-trigger.
#        If the cap is hit, skip ONLY CodeRabbit's trigger and
#        still post the other three.
#
#   Strictly per-PR: no shared mutable accumulator across a fleet. Running it
#   twice on a clean PR (already ready + all four engaged) does nothing and
#   reports "Pre-flight clean — proceeding".
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
#       "draft_action": "marked-ready" | "would-mark-ready" | "skipped-not-author" | "not-draft" | "ready-failed",
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
# EXIT STATUS
#   0  Success (including clean no-op and rate-cap skip — the skip is surfaced,
#      not an error; the other reviewers still post).
#   2  Usage error.
#   3  PR not found / closed / inaccessible.
#   4  gh / network / API error while reading PR state.
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

set -euo pipefail
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" >> "$HOME/.claude/script-usage.log" 2>/dev/null || true

print_help() {
  sed -n '/^# PURPOSE$/,/^# DEPENDENCIES$/p' "$0" | sed 's/^# \{0,1\}//'
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

# --- per-PR CR concurrency lock (mkdir atomic on macOS/Linux; Bash 3.2 compatible) ---
CR_LOCK_DIR="${TMPDIR:-/tmp}/pr-preflight-cr-${PR}.lock"
cr_lock_acquire() {
  # Bounded wait ~30s; reclaim a stale lock >60s old (crashed holder); best-effort.
  local waited=0 age
  while ! mkdir "$CR_LOCK_DIR" 2>/dev/null; do
    if [[ -d "$CR_LOCK_DIR" ]]; then
      age=$(( $(date +%s) - $(stat -f %m "$CR_LOCK_DIR" 2>/dev/null || stat -c %Y "$CR_LOCK_DIR" 2>/dev/null || echo 0) ))
      (( age > 60 )) && { rmdir "$CR_LOCK_DIR" 2>/dev/null || true; continue; }
    fi
    (( waited >= 30 )) && return 1
    sleep 1; waited=$((waited + 1))
  done
  return 0
}
cr_lock_release() { rmdir "$CR_LOCK_DIR" 2>/dev/null || true; }

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

# --- 1. read PR draft state + author ---
PR_VIEW_ERR="$(mktemp)"
trap 'rm -f "$PR_VIEW_ERR" 2>/dev/null; rmdir "$CR_LOCK_DIR" 2>/dev/null || true' EXIT
if ! PR_VIEW="$(gh pr view "$PR" --json isDraft,author,state 2>"$PR_VIEW_ERR")"; then
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

if [[ "$PR_STATE" != "OPEN" ]]; then
  echo "pr-preflight.sh: PR #$PR is $PR_STATE — pre-flight only runs on OPEN PRs" >&2
  exit 3
fi

# Current authenticated user (for the author-match draft rule).
CURRENT_USER="$(gh api user --jq .login 2>/dev/null || echo "")"

# --- 2. scan all 3 endpoints once: bot author set + comment bodies ---
AUTHORS_TMP="$(mktemp)"
BODIES_TMP="$(mktemp)"
GH_ERR="$(mktemp)"
trap 'rm -f "$PR_VIEW_ERR" "$AUTHORS_TMP" "$BODIES_TMP" "$GH_ERR" 2>/dev/null' EXIT

for endpoint in \
  "repos/{owner}/{repo}/pulls/$PR/reviews" \
  "repos/{owner}/{repo}/pulls/$PR/comments" \
  "repos/{owner}/{repo}/issues/$PR/comments"; do
  if ! gh api --paginate "${endpoint}?per_page=100" \
       --jq '.[]? | (.user.login // empty)' >>"$AUTHORS_TMP" 2>"$GH_ERR"; then
    echo "pr-preflight.sh: failed to scan $endpoint (authors): $(cat "$GH_ERR")" >&2
    exit 4
  fi
  # Bodies on their own lines (collapse internal newlines so each artifact is
  # one grep-able line). Used to detect prior trigger comments for idempotency.
  if ! gh api --paginate "${endpoint}?per_page=100" \
       --jq '.[]? | ((.body // "") | gsub("[\r\n]+"; " "))' >>"$BODIES_TMP" 2>"$GH_ERR"; then
    echo "pr-preflight.sh: failed to scan $endpoint (bodies): $(cat "$GH_ERR")" >&2
    exit 4
  fi
done

AUTHORS="$(sort -u "$AUTHORS_TMP")"

login_present() {
  # $1 = exact bot login (e.g. coderabbitai[bot])
  printf '%s\n' "$AUTHORS" | grep -qxF -- "$1"
}
trigger_already_posted() {
  # $1 = literal trigger string already in some comment body
  grep -qF -- "$1" "$BODIES_TMP"
}

# --- 3. draft check ---
DRAFT_ACTION="not-draft"
if [[ "$IS_DRAFT" == "true" ]]; then
  if [[ -n "$CURRENT_USER" && "$PR_AUTHOR" == "$CURRENT_USER" ]]; then
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
  # Idempotency: present if the bot already has an artifact OR we already posted
  # its trigger comment (covers "triggered but bot hasn't responded yet").
  if login_present "$login" || trigger_already_posted "$trigger"; then
    set_status "$key" "already-present"
    continue
  fi
  if [[ "$key" == "coderabbit" ]]; then
    CR_LOCKED=0
    if (( ! DRY_RUN )); then
      cr_lock_acquire && CR_LOCKED=1 || surface "WARNING: could not acquire CR pre-flight lock for #$PR — proceeding without concurrency guard"
    fi
    if cr_budget_allows; then
      post_trigger "$key"
    else
      set_status "$key" "skipped-rate-cap"
      surface "skipping @coderabbitai full review — CR rate cap hit (posting the other reviewers)"
    fi
    (( CR_LOCKED )) && cr_lock_release
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
