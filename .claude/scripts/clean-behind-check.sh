#!/usr/bin/env bash
# clean-behind-check.sh — Detect the "clean BEHIND, safe to offer admin-merge" state (issue #631).
#
# When a PR is fully done — review-approved on HEAD, CI green, all threads
# resolved, AC verified — and the ONLY remaining blocker is a purely mechanical
# `mergeStateStatus: BEHIND`, rebasing into a fast-moving `main` can loop
# forever (main lands new commits faster than a rebase → re-approve cycle
# converges). A rebase is genuinely needed when `main`'s new commits could
# interact with the PR — but when the base delta does NOT touch any line the PR
# changed, the rebase is pure churn and an admin-merge (via /admin-merge) is the
# responsible shortcut. This script decides, mechanically, whether that "clean
# BEHIND, safe to offer" condition holds so the offer fires consistently.
#
# It NEVER merges, NEVER modifies branch protection, and NEVER runs a bypass —
# it only reports state. The agent surfaces the offer as a user choice and
# routes an accepted offer through the existing /admin-merge skill (which runs
# its own merge-gate pre-flight before printing anything). See
# .claude/rules/cr-merge-gate.md Step 1d and .claude/skills/fixpr/ (Step 6).
#
# Safety gate (ALL required for safe_to_offer=true):
#   1. merge gate green EXCEPT the BEHIND blocker — merge-gate.sh reports no
#      `missing` reason other than the BEHIND one (this folds in approved review
#      on HEAD, CI passing/complete, and all threads resolved).
#   2. mergeStateStatus == BEHIND.
#   3. mergeable == MERGEABLE (CONFLICTING and UNKNOWN are both unsafe).
#   4. AC verified — every Test Plan checkbox in the PR body is ticked
#      (mechanical proxy via ac-checkboxes.sh; genuine per-criterion
#      verification remains the agent's cr-merge-gate.md Step 2 job).
#   5. no hunk-level overlap — the base delta's changed line ranges and the
#      PR's changed line ranges share NO overlapping interval for every shared
#      file. Detection uses GitHub's three-dot compare to get base-delta patches
#      and the PR files API for PR patches, then intersects old-side hunk
#      ranges. Conservative fallback to file-level applies when a patch is
#      unavailable (binary, truncated, or API failure), so any ambiguity is
#      treated as overlapping, never the reverse.
#
# Churn / rebase-race signal is ADVISORY context only — it raises the value of
# the offer but never gates it. `churn.advisory` is true when main has advanced
# by at least CHURN_THRESHOLD commits (default: 1; configurable via the
# CHURN_THRESHOLD env var or --churn-threshold flag) and its newest commit is
# newer than the PR's HEAD commit, i.e. main moved after the PR was last updated
# — the rebase-race window is live.
#
# File-overlap uses GitHub's three-dot compare (compare/{head}...{base}), which
# reports files and patches changed from merge-base(head, base) to the base tip
# = the base delta, without any local fetch. GitHub caps compare file lists at
# 300 files; that is comfortably above any realistic clean-BEHIND diff. The base
# tip SHA is resolved via `gh api repos/.../git/ref/heads/<base>` (the git-ref
# REST path, which handles slash-named branches like release/2026.07 natively —
# no URL escaping needed). If that call fails, the compare falls back to the ref
# name. NOTE: gh 2.48.0 does not support `baseRefOid` on `gh pr view --json`;
# the git-ref API call is the gh-version-safe way to get the base tip SHA.
#
# Usage:
#   clean-behind-check.sh <pr_number> [--reviewer cr|bugbot|greptile]
#                         [--churn-threshold N]
#   clean-behind-check.sh --help
#
# --reviewer is passed through to merge-gate.sh (which path's gate applies).
# --churn-threshold N: advisory fires when base_ahead_by >= N (default: 1;
#   env var CHURN_THRESHOLD overrides default; flag overrides env var).
#
# Output (single-line JSON on stdout, even when not safe):
#   {
#     "pr": 631,
#     "safe_to_offer": true|false,
#     "reasons_not_safe": ["...", ...],     // empty when safe_to_offer
#     "merge_state": "BEHIND",
#     "mergeable": "MERGEABLE",
#     "gate_met": false,
#     "gate_green_except_behind": true,
#     "residual_blockers": ["..."],          // merge-gate `missing` minus BEHIND
#     "ac": {"available":true,"total":6,"checked":6,"unchecked":0,
#            "all_checked":true,"note":""},
#     "file_overlap": {"count":0,"files":[],
#            "granularity":"hunk",           // "hunk" | "file"
#            "hunk_overlapping_files":[],    // files with intersecting hunk ranges
#            "fallback_files":[],            // files that fell back to file-level
#            "note":"",
#            "pr_file_count":N,
#            "base_delta_file_count":M,"pr_files":[...],"base_delta_files":[...]},
#     "churn": {"base_ahead_by":2,"threshold":1,
#            "newest_base_commit_at":"...",
#            "pr_head_commit_at":"...","advisory":true},
#     "head_sha": "abc123...",
#     "base_ref": "main"
#   }
#
# Exit codes:
#   0 — safe_to_offer == true
#   1 — safe_to_offer == false (JSON `reasons_not_safe` explains why)
#   2 — usage error
#   3 — PR not found / not open
#   4 — gh / network / jq / helper-not-found error

set -uo pipefail
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" >> "$HOME/.claude/script-usage.log" 2>/dev/null || true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

print_usage() {
  awk 'NR == 1 { next } /^$/ { exit } { print }' "$0" | sed 's/^# \{0,1\}//'
}

# --------------------------------------------------------------------------
# Hunk-level overlap helpers
# --------------------------------------------------------------------------

# Extract old-side (merge-base-relative) hunk ranges from a unified-diff patch.
# Prints one "start:end" pair per line. Empty output if no hunks found.
# @@ -l,s +l,s @@ → old range is [l, l+s-1]; omitted `,s` means s=1; s=0 = pure addition.
_parse_old_side_ranges() {
  local patch="$1"
  local line l s
  while IFS= read -r line; do
    if [[ "$line" == @@* ]]; then
      # Extract the old-side spec: first group matching -N or -N,M
      local old_spec
      old_spec="$(printf '%s\n' "$line" | grep -oE -- '-[0-9]+(,[0-9]+)?' | head -1)"
      [[ -z "$old_spec" ]] && continue
      l="${old_spec#-}"
      if [[ "$l" == *,* ]]; then
        s="${l#*,}"
        l="${l%%,*}"
      else
        s=1
      fi
      # s=0 means a pure-addition hunk (no old lines touched) — no intersection possible
      [[ "$s" -eq 0 ]] && continue
      printf '%s:%s\n' "$l" "$((l + s - 1))"
    fi
  done <<<"$patch"
}

# Test whether two newline-separated sets of "start:end" ranges intersect.
# Returns 0 (true) if any pair intersects, 1 if not.
_ranges_intersect() {
  local a_ranges="$1" b_ranges="$2"
  local a b as ae bs be
  while IFS= read -r a; do
    [[ "$a" == *:* ]] || continue
    as="${a%%:*}" ae="${a##*:}"
    while IFS= read -r b; do
      [[ "$b" == *:* ]] || continue
      bs="${b%%:*}" be="${b##*:}"
      # [as,ae] and [bs,be] overlap iff as <= be AND ae >= bs
      if [[ "$as" -le "$be" && "$ae" -ge "$bs" ]]; then
        return 0
      fi
    done <<<"$b_ranges"
  done <<<"$a_ranges"
  return 1
}

# --------------------------------------------------------------------------
# Arg parsing
# --------------------------------------------------------------------------
DEFAULT_CHURN_THRESHOLD=1
PR_NUMBER=""
REVIEWER_OVERRIDE=""
CHURN_THRESHOLD_FLAG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      print_usage
      exit 0
      ;;
    --reviewer)
      REVIEWER_OVERRIDE="${2:-}"
      case "$REVIEWER_OVERRIDE" in
        cr|bugbot|greptile) ;;
        *)
          echo "ERROR: --reviewer must be one of: cr, bugbot, greptile (got: ${REVIEWER_OVERRIDE:-})" >&2
          exit 2
          ;;
      esac
      shift 2
      ;;
    --churn-threshold)
      if [[ -z "${2:-}" ]]; then
        echo "ERROR: --churn-threshold requires a non-negative integer value" >&2
        exit 2
      fi
      CHURN_THRESHOLD_FLAG="$2"
      shift 2
      ;;
    -*)
      echo "ERROR: unknown flag: $1" >&2
      exit 2
      ;;
    *)
      if [[ -n "$PR_NUMBER" ]]; then
        echo "ERROR: unexpected argument: $1 (PR number already set to $PR_NUMBER)" >&2
        exit 2
      fi
      PR_NUMBER="$1"
      shift
      ;;
  esac
done

if [[ -z "$PR_NUMBER" ]]; then
  echo "ERROR: <pr_number> is required" >&2
  print_usage >&2
  exit 2
fi
if ! [[ "$PR_NUMBER" =~ ^[0-9]+$ ]]; then
  echo "ERROR: <pr_number> must be a positive integer (got: $PR_NUMBER)" >&2
  exit 2
fi

# Resolve effective churn threshold: flag > CHURN_THRESHOLD env var > default.
if [[ -n "$CHURN_THRESHOLD_FLAG" ]]; then
  CHURN_THRESHOLD_VAL="$CHURN_THRESHOLD_FLAG"
elif [[ -n "${CHURN_THRESHOLD:-}" ]]; then
  CHURN_THRESHOLD_VAL="${CHURN_THRESHOLD}"
else
  CHURN_THRESHOLD_VAL="$DEFAULT_CHURN_THRESHOLD"
fi
if ! [[ "$CHURN_THRESHOLD_VAL" =~ ^[0-9]+$ ]]; then
  echo "ERROR: churn threshold must be a non-negative integer (got: '$CHURN_THRESHOLD_VAL')" >&2
  exit 2
fi

# --------------------------------------------------------------------------
# Resolve owner/repo + PR metadata
# --------------------------------------------------------------------------
OWNER_REPO=$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || true)
if [[ -z "$OWNER_REPO" ]]; then
  echo "ERROR: 'gh repo view' failed — not in a git repo or no remote configured." >&2
  exit 4
fi
OWNER="${OWNER_REPO%/*}"
REPO="${OWNER_REPO#*/}"

# `baseRefOid` is NOT requested here — gh 2.48.0 does not support it on
# `gh pr view --json` and the call fails with "Unknown JSON field: baseRefOid".
# The base tip SHA is resolved separately via the git-ref REST path below.
# Adopt the pr-state.sh (PR #616) error-classification pattern: capture 2>&1,
# then distinguish genuine not-found (exit 3) from other tooling errors (exit 4).
RC=0
PR_JSON=$(gh pr view "$PR_NUMBER" --json number,state,headRefOid,baseRefName,mergeStateStatus,mergeable,files 2>&1) || RC=$?
if [[ "$RC" -ne 0 ]]; then
  if echo "$PR_JSON" | grep -qiE 'no pull request|could not resolve to a pullrequest'; then
    echo "ERROR: PR #$PR_NUMBER not found in $OWNER_REPO." >&2
    exit 3
  else
    echo "ERROR: gh pr view failed for PR #$PR_NUMBER: $PR_JSON" >&2
    exit 4
  fi
fi
# A zero-exit gh call that emits unparseable output is a tooling error (exit 4),
# not proof the PR doesn't exist.
if ! jq -e . >/dev/null 2>&1 <<<"$PR_JSON"; then
  echo "ERROR: gh pr view returned unparseable output for PR #$PR_NUMBER: $PR_JSON" >&2
  exit 4
fi
PR_STATE=$(jq -r '.state // "UNKNOWN"' <<<"$PR_JSON")
HEAD_SHA=$(jq -r '.headRefOid // ""' <<<"$PR_JSON")
BASE_REF=$(jq -r '.baseRefName // ""' <<<"$PR_JSON")
MERGE_STATE=$(jq -r '.mergeStateStatus // ""' <<<"$PR_JSON")
MERGEABLE=$(jq -r '.mergeable // ""' <<<"$PR_JSON")

if [[ "$PR_STATE" != "OPEN" ]]; then
  echo "ERROR: PR #$PR_NUMBER is $PR_STATE — not open." >&2
  exit 3
fi
if [[ -z "$HEAD_SHA" || -z "$BASE_REF" ]]; then
  echo "ERROR: could not determine HEAD SHA / base ref for PR #$PR_NUMBER." >&2
  exit 4
fi

# Resolve the base tip SHA via the git-ref REST path (gh-2.48.0-compatible,
# handles slash-named branches like release/2026.07 natively). This is best-effort:
# if the call fails, BASE_SHA stays empty and the existing COMPARE_BASE fallback
# below uses the ref name — no new exit path for this call.
BASE_SHA=$(gh api "repos/$OWNER/$REPO/git/ref/heads/$BASE_REF" --jq '.object.sha' 2>/dev/null || true)

# --------------------------------------------------------------------------
# Resolve sibling helpers (prefer next-to-self, then global installs)
# --------------------------------------------------------------------------
resolve_helper() {
  local name="$1" c
  for c in \
    "$SCRIPT_DIR/$name" \
    "$HOME/.claude/skills-worktree/.claude/scripts/$name" \
    "$HOME/.claude/scripts/$name"; do
    if [[ -x "$c" ]]; then echo "$c"; return 0; fi
  done
  return 1
}

MERGE_GATE=$(resolve_helper merge-gate.sh) || {
  echo "ERROR: merge-gate.sh not found — cannot evaluate the merge gate." >&2
  exit 4
}
AC_CHECKBOXES=$(resolve_helper ac-checkboxes.sh || true)

# --------------------------------------------------------------------------
# Merge gate — the only remaining blocker must be BEHIND
# --------------------------------------------------------------------------
# set -e is off, so a non-zero merge-gate exit (1 = gate not met, which is
# ALWAYS the case for a BEHIND PR) does not abort — capture the code, read JSON.
GATE_ARGS=("$PR_NUMBER")
[[ -n "$REVIEWER_OVERRIDE" ]] && GATE_ARGS+=(--reviewer "$REVIEWER_OVERRIDE")
GATE_JSON="$("$MERGE_GATE" "${GATE_ARGS[@]}" 2>/dev/null)"
GATE_EXIT=$?
if [[ -z "$GATE_JSON" ]] || ! jq -e . >/dev/null 2>&1 <<<"$GATE_JSON"; then
  echo "ERROR: merge-gate.sh produced no parseable JSON (exit $GATE_EXIT)." >&2
  exit 4
fi
case "$GATE_EXIT" in
  3) echo "ERROR: merge-gate.sh reports PR #$PR_NUMBER not found/closed." >&2; exit 3 ;;
  4) echo "ERROR: merge-gate.sh hit a gh/network/jq error." >&2; exit 4 ;;
esac

GATE_MET=$(jq -r '.met' <<<"$GATE_JSON")
# residual = every `missing` reason EXCEPT the BEHIND one. Only the BEHIND
# message contains "BEHIND base" (merge-gate.sh). CONFLICTING / CI / thread /
# review blockers all remain here, so any of them keeps gate_green_except_behind
# false — mirroring how admin-merge.sh filters only the reviewDecision note.
RESIDUAL_JSON=$(jq -c '[.missing[]? | select(test("BEHIND base"; "i") | not)]' <<<"$GATE_JSON")
RESIDUAL_COUNT=$(jq 'length' <<<"$RESIDUAL_JSON")
GATE_GREEN_EXCEPT_BEHIND=false
[[ "$RESIDUAL_COUNT" -eq 0 ]] && GATE_GREEN_EXCEPT_BEHIND=true

IS_BEHIND=false
[[ "$MERGE_STATE" == "BEHIND" ]] && IS_BEHIND=true
# Only an explicit MERGEABLE state is safe. CONFLICTING (textual conflict) and
# UNKNOWN/empty (GitHub still computing mergeability) both make the offer
# premature — the base delta and no-overlap comparison aren't trustworthy yet.
MERGEABLE_OK=false
[[ "$MERGEABLE" == "MERGEABLE" ]] && MERGEABLE_OK=true

# --------------------------------------------------------------------------
# AC verification — mechanical check that every Test Plan checkbox is ticked
# --------------------------------------------------------------------------
AC_AVAILABLE=false
AC_TOTAL=0
AC_CHECKED=0
AC_UNCHECKED=0
AC_ALL_CHECKED=false
AC_NOTE=""
if [[ -n "$AC_CHECKBOXES" ]]; then
  AC_JSON="$("$AC_CHECKBOXES" "$PR_NUMBER" --extract 2>/dev/null)"
  AC_EXIT=$?
  if [[ "$AC_EXIT" -eq 0 ]] && jq -e . >/dev/null 2>&1 <<<"$AC_JSON"; then
    AC_AVAILABLE=true
    AC_TOTAL=$(jq 'length' <<<"$AC_JSON")
    AC_CHECKED=$(jq '[.[] | select(.checked)] | length' <<<"$AC_JSON")
    AC_UNCHECKED=$(jq '[.[] | select(.checked | not)] | length' <<<"$AC_JSON")
    if [[ "$AC_TOTAL" -gt 0 && "$AC_UNCHECKED" -eq 0 ]]; then
      AC_ALL_CHECKED=true
    elif [[ "$AC_TOTAL" -eq 0 ]]; then
      AC_NOTE="Test Plan section has no checkbox items"
    else
      AC_NOTE="$AC_UNCHECKED unchecked Test Plan checkbox(es)"
    fi
  elif [[ "$AC_EXIT" -eq 3 ]]; then
    echo "ERROR: ac-checkboxes.sh reports PR #$PR_NUMBER not found." >&2
    exit 3
  elif [[ "$AC_EXIT" -eq 1 ]]; then
    AC_NOTE="no Test Plan section or no checkboxes (ac-checkboxes.sh exit 1)"
  else
    AC_NOTE="ac-checkboxes.sh error (exit $AC_EXIT) — cannot confirm AC"
  fi
else
  AC_NOTE="ac-checkboxes.sh not found — cannot confirm AC"
fi

# --------------------------------------------------------------------------
# File-level overlap + churn — GitHub three-dot compare (no local fetch)
# --------------------------------------------------------------------------
# compare/{head_sha}...{base_sha}: base=head_sha, head=base tip → files changed
# from merge-base(head_sha, base) to the base tip = the BASE DELTA. `ahead_by`
# is how many commits the base tip is ahead of the merge base (new main commits).
# Prefer the base tip SHA resolved via git/ref/heads above (gh-2.48.0-compatible);
# fall back to the ref name when the SHA fetch failed. Using the SHA avoids
# path-escaping issues with slash-named base branches (e.g. release/2026.07).
COMPARE_BASE="${BASE_SHA:-$BASE_REF}"
COMPARE_JSON="$(gh api "repos/$OWNER/$REPO/compare/$HEAD_SHA...$COMPARE_BASE" 2>/dev/null || true)"
if [[ -z "$COMPARE_JSON" ]] || ! jq -e . >/dev/null 2>&1 <<<"$COMPARE_JSON"; then
  echo "ERROR: could not compare $HEAD_SHA...$COMPARE_BASE via the GitHub API." >&2
  exit 4
fi
BASE_DELTA_FILES=$(jq -c '[.files[]?.filename] | unique' <<<"$COMPARE_JSON")
BASE_AHEAD_BY=$(jq -r '.ahead_by // 0' <<<"$COMPARE_JSON")
[[ "$BASE_AHEAD_BY" =~ ^[0-9]+$ ]] || BASE_AHEAD_BY=0
NEWEST_BASE_COMMIT_AT=$(jq -r '(.commits // []) | if length > 0 then (.[-1].commit.committer.date // .[-1].commit.author.date // "") else "" end' <<<"$COMPARE_JSON")

# PR's changed files — reuse the PR_JSON already fetched above (no second call).
PR_FILES_JSON="$(jq -c '[.files[]?.path] | unique' <<<"$PR_JSON" 2>/dev/null || echo '[]')"
if ! jq -e . >/dev/null 2>&1 <<<"$PR_FILES_JSON"; then PR_FILES_JSON='[]'; fi

# File-level intersection = a - (a - b): elements of PR files also in base delta.
OVERLAP_JSON=$(jq -cn --argjson a "$PR_FILES_JSON" --argjson b "$BASE_DELTA_FILES" '$a - ($a - $b) | unique')
OVERLAP_COUNT=$(jq 'length' <<<"$OVERLAP_JSON")
NO_OVERLAP=true
[[ "$OVERLAP_COUNT" -gt 0 ]] && NO_OVERLAP=false

# --------------------------------------------------------------------------
# Hunk-level overlap refinement (only runs on file-level overlap candidates)
# --------------------------------------------------------------------------
# When the file-level check finds shared filenames, refine to hunk-level:
# fetch patches for those files and test old-side line-range intersection.
# Conservative fallback: if a patch is unavailable (binary, truncated, API
# failure) → treat the file as overlapping (file-level conservative behavior).
# Ambiguity always resolves toward "not safe to offer", never the reverse.

HUNK_OVERLAPPING_FILES_JSON='[]'
FALLBACK_FILES_JSON='[]'
HUNK_GRANULARITY="file"
HUNK_NOTE=""

if [[ "$OVERLAP_COUNT" -gt 0 ]]; then
  # Fetch PR file patches — scoped to the candidate overlap set.
  # `--paginate` handles PRs with many files; results include `.patch` per file.
  RC_PF=0
  PR_FILES_PATCH_JSON="$(gh api "repos/$OWNER/$REPO/pulls/$PR_NUMBER/files" --paginate 2>/dev/null)" || RC_PF=$?

  if [[ "$RC_PF" -eq 0 ]] && jq -e . >/dev/null 2>&1 <<<"$PR_FILES_PATCH_JSON"; then
    HUNK_OVERLAPPING_FILES=()
    FALLBACK_FILES=()

    while IFS= read -r CANDIDATE_FILE; do
      # Extract base-delta patch for this file (already in COMPARE_JSON)
      BASE_PATCH="$(jq -r --arg f "$CANDIDATE_FILE" '.files[]? | select(.filename == $f) | .patch // ""' <<<"$COMPARE_JSON")"
      # Extract PR patch for this file
      PR_PATCH="$(jq -r --arg f "$CANDIDATE_FILE" '.[] | select(.filename == $f) | .patch // ""' <<<"$PR_FILES_PATCH_JSON")"

      # Conservative fallback: no patch available (binary, newly added/deleted,
      # or truncated by GitHub's diff-size limit) → treat file as overlapping.
      if [[ -z "$BASE_PATCH" || -z "$PR_PATCH" ]]; then
        FALLBACK_FILES+=("$CANDIDATE_FILE")
        HUNK_OVERLAPPING_FILES+=("$CANDIDATE_FILE")
        continue
      fi

      BASE_RANGES="$(_parse_old_side_ranges "$BASE_PATCH")"
      PR_RANGES="$(_parse_old_side_ranges "$PR_PATCH")"

      # No parseable ranges (e.g., pure additions or unrecognized format) →
      # conservative fallback: treat file as overlapping.
      if [[ -z "$BASE_RANGES" || -z "$PR_RANGES" ]]; then
        FALLBACK_FILES+=("$CANDIDATE_FILE")
        HUNK_OVERLAPPING_FILES+=("$CANDIDATE_FILE")
        continue
      fi

      # Test hunk-level intersection; only truly overlapping hunks count.
      if _ranges_intersect "$BASE_RANGES" "$PR_RANGES"; then
        HUNK_OVERLAPPING_FILES+=("$CANDIDATE_FILE")
      fi
      # If no intersection: file is NOT added — disjoint hunks → no real conflict.

    done < <(jq -r '.[]' <<<"$OVERLAP_JSON")

    # Build JSON arrays (check length first to avoid set -u issues on empty arrays)
    if [[ "${#HUNK_OVERLAPPING_FILES[@]}" -gt 0 ]]; then
      HUNK_OVERLAPPING_FILES_JSON="$(printf '%s\n' "${HUNK_OVERLAPPING_FILES[@]}" | jq -R . | jq -cs .)"
    else
      HUNK_OVERLAPPING_FILES_JSON='[]'
    fi
    if [[ "${#FALLBACK_FILES[@]}" -gt 0 ]]; then
      FALLBACK_FILES_JSON="$(printf '%s\n' "${FALLBACK_FILES[@]}" | jq -R . | jq -cs .)"
    else
      FALLBACK_FILES_JSON='[]'
    fi

    HUNK_GRANULARITY="hunk"
    if [[ "${#FALLBACK_FILES[@]}" -gt 0 ]]; then
      HUNK_NOTE="${#FALLBACK_FILES[@]} file(s) fell back to file-level (no usable patch)"
    fi

    # Recompute overlap based on hunk-level result
    OVERLAP_JSON="$HUNK_OVERLAPPING_FILES_JSON"
    OVERLAP_COUNT="${#HUNK_OVERLAPPING_FILES[@]}"
    NO_OVERLAP=true
    [[ "$OVERLAP_COUNT" -gt 0 ]] && NO_OVERLAP=false

  else
    # PR files API call failed → hunk analysis unavailable; keep file-level result
    HUNK_NOTE="hunk analysis unavailable (PR files API fetch failed) — file-level verdict kept"
    FALLBACK_FILES_JSON="$OVERLAP_JSON"
  fi
fi

# --------------------------------------------------------------------------
# Churn advisory (never gates safe_to_offer)
# --------------------------------------------------------------------------
# Fires when base advanced by >= threshold AND its newest commit is newer than
# the PR's HEAD commit — the rebase-race window is live.
# `churn.threshold` in JSON reflects the effective configured value.
PR_HEAD_COMMIT_AT="$(gh api "repos/$OWNER/$REPO/commits/$HEAD_SHA" --jq '.commit.committer.date // .commit.author.date // ""' 2>/dev/null || echo "")"
CHURN_ADVISORY=false
if [[ "$BASE_AHEAD_BY" -ge "$CHURN_THRESHOLD_VAL" ]]; then
  if [[ -n "$NEWEST_BASE_COMMIT_AT" && -n "$PR_HEAD_COMMIT_AT" ]]; then
    [[ "$NEWEST_BASE_COMMIT_AT" > "$PR_HEAD_COMMIT_AT" ]] && CHURN_ADVISORY=true
  else
    # Timestamps unavailable (e.g. compare commit list truncated) — flag on the
    # bare fact that the base moved, so the advisory errs toward surfacing churn.
    CHURN_ADVISORY=true
  fi
fi

# --------------------------------------------------------------------------
# Compose safe_to_offer + reasons
# --------------------------------------------------------------------------
SAFE=false
if [[ "$IS_BEHIND" == true && "$MERGEABLE_OK" == true \
      && "$GATE_GREEN_EXCEPT_BEHIND" == true && "$AC_ALL_CHECKED" == true \
      && "$NO_OVERLAP" == true ]]; then
  SAFE=true
fi

REASONS=()
if [[ "$IS_BEHIND" != true ]]; then
  REASONS+=("mergeStateStatus is ${MERGE_STATE:-unknown}, not BEHIND — no clean-behind bypass to offer")
fi
if [[ "$MERGEABLE" == "CONFLICTING" ]]; then
  REASONS+=("mergeable is CONFLICTING — resolve conflicts via rebase; no bypass")
elif [[ "$MERGEABLE_OK" != true ]]; then
  REASONS+=("mergeable is ${MERGEABLE:-unknown}, not MERGEABLE — GitHub still computing mergeability; wait and re-check")
fi
if [[ "$GATE_GREEN_EXCEPT_BEHIND" != true ]]; then
  while IFS= read -r r; do
    [[ -z "$r" ]] && continue
    # CONFLICTING is already surfaced by the mergeable axis above.
    [[ "$r" == *CONFLICTING* ]] && continue
    REASONS+=("merge gate blocker: $r")
  done < <(jq -r '.[]' <<<"$RESIDUAL_JSON")
fi
if [[ "$AC_ALL_CHECKED" != true ]]; then
  REASONS+=("acceptance criteria not fully verified: ${AC_NOTE:-unchecked Test Plan checkboxes}")
fi
if [[ "$NO_OVERLAP" != true ]]; then
  OV=$(jq -r 'join(", ")' <<<"$OVERLAP_JSON")
  REASONS+=("base delta overlaps PR files ($OV) — rebase so CI + review re-run on the integrated result")
fi

if [[ "${#REASONS[@]}" -gt 0 ]]; then
  REASONS_JSON=$(printf '%s\n' "${REASONS[@]}" | jq -R . | jq -cs .)
else
  REASONS_JSON='[]'
fi

# --------------------------------------------------------------------------
# Emit
# --------------------------------------------------------------------------
jq -n \
  --argjson pr "$PR_NUMBER" \
  --argjson safe "$SAFE" \
  --argjson reasons "$REASONS_JSON" \
  --arg merge_state "$MERGE_STATE" \
  --arg mergeable "$MERGEABLE" \
  --argjson gate_met "$GATE_MET" \
  --argjson gate_green_except_behind "$GATE_GREEN_EXCEPT_BEHIND" \
  --argjson residual "$RESIDUAL_JSON" \
  --argjson ac_available "$AC_AVAILABLE" \
  --argjson ac_total "$AC_TOTAL" \
  --argjson ac_checked "$AC_CHECKED" \
  --argjson ac_unchecked "$AC_UNCHECKED" \
  --argjson ac_all_checked "$AC_ALL_CHECKED" \
  --arg ac_note "$AC_NOTE" \
  --argjson overlap_count "$OVERLAP_COUNT" \
  --argjson overlap_files "$OVERLAP_JSON" \
  --arg hunk_granularity "$HUNK_GRANULARITY" \
  --argjson hunk_overlapping_files "$HUNK_OVERLAPPING_FILES_JSON" \
  --argjson fallback_files "$FALLBACK_FILES_JSON" \
  --arg hunk_note "$HUNK_NOTE" \
  --argjson pr_files "$PR_FILES_JSON" \
  --argjson base_delta_files "$BASE_DELTA_FILES" \
  --argjson base_ahead_by "$BASE_AHEAD_BY" \
  --argjson churn_threshold "$CHURN_THRESHOLD_VAL" \
  --arg newest_base_commit_at "$NEWEST_BASE_COMMIT_AT" \
  --arg pr_head_commit_at "$PR_HEAD_COMMIT_AT" \
  --argjson churn_advisory "$CHURN_ADVISORY" \
  --arg head_sha "$HEAD_SHA" \
  --arg base_ref "$BASE_REF" \
  '{
    pr: $pr,
    safe_to_offer: $safe,
    reasons_not_safe: $reasons,
    merge_state: $merge_state,
    mergeable: $mergeable,
    gate_met: $gate_met,
    gate_green_except_behind: $gate_green_except_behind,
    residual_blockers: $residual,
    ac: {
      available: $ac_available,
      total: $ac_total,
      checked: $ac_checked,
      unchecked: $ac_unchecked,
      all_checked: $ac_all_checked,
      note: $ac_note
    },
    file_overlap: {
      count: $overlap_count,
      files: $overlap_files,
      granularity: $hunk_granularity,
      hunk_overlapping_files: $hunk_overlapping_files,
      fallback_files: $fallback_files,
      note: $hunk_note,
      pr_file_count: ($pr_files | length),
      base_delta_file_count: ($base_delta_files | length),
      pr_files: $pr_files,
      base_delta_files: $base_delta_files
    },
    churn: {
      base_ahead_by: $base_ahead_by,
      threshold: $churn_threshold,
      newest_base_commit_at: $newest_base_commit_at,
      pr_head_commit_at: $pr_head_commit_at,
      advisory: $churn_advisory
    },
    head_sha: $head_sha,
    base_ref: $base_ref
  }'

if [[ "$SAFE" == true ]]; then
  exit 0
else
  exit 1
fi
