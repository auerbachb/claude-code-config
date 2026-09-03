#!/usr/bin/env bash
# merge-sequence.sh — Overlap-aware merge dispatch planner (issue #756).
#
# PURPOSE
#   Merge order is first-ready-first-merged by default, blind to file overlap.
#   That is backwards when one PR's diff dwarfs its siblings' in a shared file:
#   every small PR that lands first forces the big one into another conflict
#   round, multiplying manual effort, reviewer spend, and the risk that a manual
#   re-resolution silently drops work.
#
#   This script answers one mechanical question — given these open PRs, which
#   merges first and which wait? — so the ordering is a computed plan rather
#   than folklore ("merge the biggest first, or batch"). It NEVER merges,
#   rebases, comments, or writes any state: it reads PR file lists and prints a
#   plan. Callers (/pr-monitor-and-manage Step 3.6, /subagent) act on it.
#
# THE RULE
#   PRs that share at least one changed file form a group. Within a group the
#   ANCHOR is the PR with the largest changed-line footprint across the shared
#   files — it merges first. Every other member (a FOLLOWER) is HELD behind it,
#   so the anchor rebases zero times instead of once per follower.
#
#   Holds are bounded (they can never deadlock the fleet). When the anchor stops
#   making progress, its followers are RELEASED as a single BATCH — they merge
#   in one window, so the anchor re-syncs once rather than N times:
#
#     anchor hard-blocked / gone / errored      -> release immediately (batch)
#     anchor signature unchanged past           -> release (batch)
#       --stall-ticks ticks (default 1)
#     otherwise                                 -> hold
#
#   The anchor's SIGNATURE is "<head_sha>:<verdict>". Any real movement — a new
#   commit, a verdict change — resets the stall counter, so a healthy in-progress
#   anchor keeps its followers held; only a genuinely stuck one releases them.
#
# AUTHORSHIP (fail-closed — .claude/rules/safety.md, issue #733)
#   Sequencing decides what gets MERGED, so it may only consider PRs the
#   authenticated user authored. Each PR is gated through pr-authorship.sh;
#   anything not `mine` (not_mine / unknown / not_found) is dropped into
#   excluded_prs[] BEFORE grouping — it can neither become an anchor nor hold
#   one of your PRs. --allow-nonauthor opts out, and is only ever passed under
#   an explicit per-PR user override.
#
# USAGE
#   merge-sequence.sh --prs <n1,n2,...> [--repo <owner/name>]
#                     [--verdicts <json>] [--heads <json>] [--holds <json>]
#                     [--stall-ticks <N>] [--allow-nonauthor]
#   merge-sequence.sh --help | -h
#
#   --prs n1,n2,...   REQUIRED. The caller's already-discovered fleet.
#   --repo owner/name Look PRs up in a named repo (default: current checkout).
#   --verdicts <json> {"100":"wrap","101":"waiting"} — the caller's per-PR
#                     dispatch verdict. Only `wrap` PRs are merge candidates;
#                     everything else is reported `not_merge_ready` and is never
#                     held (it was not going to merge this tick anyway).
#                     Omitted: every PR is treated as `wrap`, which answers the
#                     standalone question "what would the order be?".
#   --heads <json>    {"100":"abc123..."} — PR head SHAs. Omitted: fetched per
#                     PR. Callers that already hold them (PMM's gate JSON)
#                     should pass them and save a round-trip each.
#   --holds <json>    Previous run's `holds` object, verbatim. This is what makes
#                     stall detection work across ticks; omit it on a first run.
#   --stall-ticks N   Ticks of an unchanged anchor signature tolerated before
#                     followers release (default 1, i.e. release on the second
#                     consecutive quiet tick). 0 disables holding entirely.
#   --allow-nonauthor Include PRs authored by others (explicit user override).
#   --skip-missing    A PR that 404s (merged or closed mid-run) becomes an
#                     excluded_prs[] entry instead of exit 3. Fleet callers pass
#                     this: one PR landing between discovery and planning must
#                     not discard the whole fleet's plan. Without it, a missing
#                     PR is a hard error — the right default for an explicit
#                     single-PR request, where a typo should not pass silently.
#
# OUTPUT (single-line JSON on stdout)
#   {
#     "repo": "owner/name",
#     "stall_ticks": 1,
#     "prs_considered": [100,101,102],
#     "excluded_prs": [{"pr":104,"reason":"not_mine","detail":"..."}],
#     "groups": [{"anchor":100,"members":[100,101,102],
#                 "shared_files":["path"],"footprints":{"100":320,"101":12},
#                 "anchor_state":"ready|progressing|blocked",
#                 "anchor_signature":"sha:verdict","ticks":1}],
#     "plan": {"100":{"action":"merge","role":"anchor","group":0,
#                     "shared_files":["path"],"reason":"..."},
#              "101":{"action":"hold","role":"follower","group":0,"anchor":100,
#                     "shared_files":["path"],"reason":"..."}},
#     "batches": [{"anchor":100,"prs":[101,102]}],
#     "holds":   {"100":{"anchor":100,"signature":"...","ticks":1,
#                        "members":[101,102],"released":false}},
#     "summary": "holding #101, #102 until #100 lands — they share `path`"
#   }
#
#   `action` is one of:
#     merge            dispatch normally (anchor, or a PR with no overlap)
#     hold             defer this tick — an anchor is landing ahead of it
#     batch            released from a hold; merge together in ONE window
#     not_merge_ready  verdict is not `wrap`; no merge dispatch either way
#
#   Persist `holds` and pass it back as --holds next tick. Print `summary`
#   verbatim under the fleet status table — it names the shared file(s), which
#   is what makes the ordering visible instead of mysterious.
#
# EXIT STATUS
#   0  sequencing applies — at least one PR is held or batched.
#   1  no sequencing needed — no overlap among merge candidates. The plan is
#      still printed and every PR reads `merge`; behaviour is unchanged.
#   2  usage error (includes a non-canonical PR number such as `0` or `001`, and
#      a --repo that is not exactly owner/name).
#   3  a requested PR was not found (unless --skip-missing).
#   4  gh / jq / helper error — including an anchor whose head SHA cannot be
#      resolved. That is deliberately fatal rather than defaulted: a placeholder
#      would be a STABLE signature across ticks, advancing the stall counter on
#      an anchor that was never actually observed.
#   70  --help header extraction produced no output (internal defect).
#
# DEPENDENCIES
#   gh (authenticated), jq, pr-authorship.sh (resolved next to this script)
#
# EXAMPLES
#   merge-sequence.sh --prs 100,101,102
#   merge-sequence.sh --prs 100,101 --verdicts '{"100":"fixpr","101":"wrap"}' \
#                     --holds "$PREV_HOLDS"

set -uo pipefail
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" 2>/dev/null >> "$HOME/.claude/script-usage.log" || true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

print_usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; n = 1; next } { exit } END { exit(n ? 0 : 1) }' "$0" ||
    { printf '%s: --help header extraction produced no output\n' "$0" >&2; exit 70; }
}

# --------------------------------------------------------------------------
# Arg parsing
# --------------------------------------------------------------------------
PRS_RAW=""
REPO_FULL=""
VERDICTS_JSON="{}"
HEADS_JSON="{}"
HOLDS_IN="{}"
STALL_TICKS=1
ALLOW_NONAUTHOR=0
SKIP_MISSING=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) print_usage; exit 0 ;;
    --prs)
      [[ -z "${2:-}" ]] && { echo "ERROR: --prs requires a comma-separated PR list" >&2; exit 2; }
      PRS_RAW="$2"; shift 2 ;;
    --repo)
      [[ -z "${2:-}" ]] && { echo "ERROR: --repo requires <owner/name>" >&2; exit 2; }
      REPO_FULL="$2"; shift 2 ;;
    --verdicts)
      [[ -z "${2:-}" ]] && { echo "ERROR: --verdicts requires a JSON object" >&2; exit 2; }
      VERDICTS_JSON="$2"; shift 2 ;;
    --heads)
      [[ -z "${2:-}" ]] && { echo "ERROR: --heads requires a JSON object" >&2; exit 2; }
      HEADS_JSON="$2"; shift 2 ;;
    --holds)
      [[ -z "${2:-}" ]] && { echo "ERROR: --holds requires a JSON object" >&2; exit 2; }
      HOLDS_IN="$2"; shift 2 ;;
    --stall-ticks)
      [[ -z "${2:-}" ]] && { echo "ERROR: --stall-ticks requires a non-negative integer" >&2; exit 2; }
      STALL_TICKS="$2"; shift 2 ;;
    --allow-nonauthor) ALLOW_NONAUTHOR=1; shift ;;
    --skip-missing) SKIP_MISSING=1; shift ;;
    -*) echo "ERROR: unknown flag: $1" >&2; exit 2 ;;
    *)  echo "ERROR: unexpected argument: $1 (did you mean --prs $1?)" >&2; exit 2 ;;
  esac
done

[[ -z "$PRS_RAW" ]] && { echo "ERROR: --prs is required (comma-separated PR numbers)" >&2; exit 2; }
[[ "$STALL_TICKS" =~ ^[0-9]+$ ]] || { echo "ERROR: --stall-ticks must be a non-negative integer (got: $STALL_TICKS)" >&2; exit 2; }

for _json_pair in "verdicts:$VERDICTS_JSON" "heads:$HEADS_JSON" "holds:$HOLDS_IN"; do
  _name="${_json_pair%%:*}"; _val="${_json_pair#*:}"
  if ! jq -e 'type == "object"' >/dev/null 2>&1 <<<"$_val"; then
    echo "ERROR: --$_name must be a JSON object" >&2; exit 2
  fi
done

# Normalize + validate the PR list (dedupe, preserve first-seen order).
# `[:blank:]` (space + tab), NOT `[:space:]` — the latter also strips the
# newlines this loop reads on, collapsing the whole list into one token.
# The `|| [[ -n "$_p" ]]` guard reads a final entry with no trailing newline.
PR_LIST=()
_seen=""
while IFS= read -r _p || [[ -n "$_p" ]]; do
  [[ -z "$_p" ]] && continue
  # Canonical positive decimals only. `0` is never a PR, and a leading-zero form
  # like `001` is NOT valid JSON — it would survive this check and then blow up
  # inside `jq --argjson pr 001` further down, turning a usage error into a
  # mid-run plan failure.
  [[ "$_p" =~ ^[1-9][0-9]*$ ]] || {
    echo "ERROR: --prs entries must be canonical positive PR numbers (got: $_p)" >&2; exit 2; }
  case " $_seen " in *" $_p "*) continue ;; esac
  _seen="$_seen $_p"
  PR_LIST+=("$_p")
done < <(tr ',' '\n' <<<"$PRS_RAW" | tr -d '[:blank:]#')

[[ ${#PR_LIST[@]} -eq 0 ]] && { echo "ERROR: --prs listed no PR numbers" >&2; exit 2; }

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required" >&2; exit 4; }
command -v gh >/dev/null 2>&1 || { echo "ERROR: gh is required" >&2; exit 4; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --------------------------------------------------------------------------
# Repo resolution
# --------------------------------------------------------------------------
if [[ -z "$REPO_FULL" ]]; then
  REPO_FULL="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null)" || REPO_FULL=""
  [[ -z "$REPO_FULL" ]] && { echo "ERROR: could not resolve the repo (pass --repo owner/name)" >&2; exit 4; }
fi
# Validate the WHOLE value, not just that the split halves are non-empty: a
# component check alone accepts `owner/repo/extra`, whose `%%/*` / `##*/` split
# yields owner=`owner` repo=`extra` — a *different, real* repo that the API would
# be queried against silently. Exactly one slash, both sides legal repo chars.
[[ "$REPO_FULL" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || {
  echo "ERROR: --repo must be exactly owner/name (got: $REPO_FULL)" >&2; exit 2; }
OWNER="${REPO_FULL%%/*}"
REPO="${REPO_FULL##*/}"

# --------------------------------------------------------------------------
# Authorship gate + per-PR file footprints
# --------------------------------------------------------------------------
AUTHORSHIP="$SCRIPT_DIR/pr-authorship.sh"
EXCLUDED='[]'
KEPT=()

for PR in "${PR_LIST[@]}"; do
  if [[ "$ALLOW_NONAUTHOR" -eq 0 ]]; then
    if [[ ! -x "$AUTHORSHIP" ]]; then
      echo "ERROR: pr-authorship.sh not found or not executable at $AUTHORSHIP" >&2
      exit 4
    fi
    VERDICT_AUTH="$("$AUTHORSHIP" "$PR" --repo "$REPO_FULL" 2>/dev/null)"; AUTH_RC=$?
    if [[ "$AUTH_RC" -ne 0 ]]; then
      case "$AUTH_RC" in
        1) REASON="not_mine" ;;
        3) REASON="not_found" ;;
        *) REASON="unknown" ;;   # fail-closed: undetermined authorship is never acted on
      esac
      EXCLUDED="$(jq -c --argjson pr "$PR" --arg reason "$REASON" \
        --arg detail "pr-authorship.sh verdict: ${VERDICT_AUTH:-$REASON} (exit $AUTH_RC)" \
        '. + [{pr:$pr, reason:$reason, detail:$detail}]' <<<"$EXCLUDED")"
      continue
    fi
  fi

  # Changed files + per-file changed-line counts. --paginate with --jq streams
  # one TSV line per file across every page.
  if ! gh api "repos/$OWNER/$REPO/pulls/$PR/files" --paginate \
        --jq '.[] | [.filename, (.changes // 0)] | @tsv' > "$TMP/fc.$PR" 2>"$TMP/err.$PR"; then
    if grep -qiE '404|not found' "$TMP/err.$PR"; then
      if [[ "$SKIP_MISSING" -eq 1 ]]; then
        # Fleet callers: a PR that merged or closed mid-run is normal churn, not
        # a reason to discard the whole plan. Exclude it and keep sequencing.
        EXCLUDED="$(jq -c --argjson pr "$PR" --arg reason "not_found" \
          --arg detail "PR is gone (merged/closed) — excluded from sequencing" \
          '. + [{pr:$pr, reason:$reason, detail:$detail}]' <<<"$EXCLUDED")"
        continue
      fi
      echo "ERROR: PR #$PR not found in $REPO_FULL" >&2
      exit 3
    fi
    echo "ERROR: failed to fetch changed files for PR #$PR: $(tr -d '\n' < "$TMP/err.$PR")" >&2
    exit 4
  fi

  # Sorted unique filename set, used for the cheap pairwise intersection below.
  cut -f1 "$TMP/fc.$PR" | LC_ALL=C sort -u > "$TMP/f.$PR"
  KEPT+=("$PR")
done

N=${#KEPT[@]}

emit_and_exit() {
  # $1 = full plan JSON; exit 0 when sequencing applies, else 1.
  local plan="$1"
  printf '%s\n' "$plan"
  if jq -e '[.plan[] | select(.action == "hold" or .action == "batch")] | length > 0' >/dev/null 2>&1 <<<"$plan"; then
    exit 0
  fi
  exit 1
}

PRS_CONSIDERED="$(printf '%s\n' "${KEPT[@]:-}" | jq -R 'select(length > 0) | tonumber' | jq -sc '.')"

if [[ "$N" -eq 0 ]]; then
  emit_and_exit "$(jq -cn --arg repo "$REPO_FULL" --argjson stall "$STALL_TICKS" \
    --argjson excluded "$EXCLUDED" \
    '{repo:$repo, stall_ticks:$stall, prs_considered:[], excluded_prs:$excluded,
      groups:[], plan:{}, batches:[], holds:{},
      summary:"no PRs eligible for merge sequencing"}')"
fi

# --------------------------------------------------------------------------
# Group PRs by shared changed files (transitive closure over "shares a file").
# GROUP[] is a parallel array to KEPT[] — no associative arrays, so this stays
# bash 3.2 safe (the default shell on macOS).
# --------------------------------------------------------------------------
GROUP=()
for ((i = 0; i < N; i++)); do GROUP[i]=$i; done

for ((i = 0; i < N; i++)); do
  for ((j = i + 1; j < N; j++)); do
    [[ "${GROUP[i]}" == "${GROUP[j]}" ]] && continue
    if [[ -n "$(LC_ALL=C comm -12 "$TMP/f.${KEPT[i]}" "$TMP/f.${KEPT[j]}" | head -1)" ]]; then
      gi="${GROUP[i]}"; gj="${GROUP[j]}"
      for ((k = 0; k < N; k++)); do
        [[ "${GROUP[k]}" == "$gj" ]] && GROUP[k]="$gi"
      done
    fi
  done
done

# --------------------------------------------------------------------------
# Head SHAs (for the anchor signature) — only for PRs we kept.
# --------------------------------------------------------------------------
# Resolve an anchor's head SHA, or FAIL — never substitute a placeholder.
#
# A fabricated sentinel here is worse than a hard error: the signature would be
# a stable `unknown:<verdict>` across ticks, so the stall counter would advance
# on evidence that was never observed and release followers as a batch without
# the anchor's state ever having been read. Same class of bug as a fabricated
# epoch corrupting TTL math (issue #634) — a stable-looking value that means
# "we failed to look", not "nothing changed".
#
# Returns non-zero on failure; the caller turns that into exit 4 (the documented
# gh/helper-error code). `exit` cannot be used here: this runs inside command
# substitution, where it would only kill the subshell and be silently ignored.
head_sha_of() {
  local pr="$1" sha
  sha="$(jq -r --arg pr "$pr" '.[$pr] // empty' <<<"$HEADS_JSON")"
  if [[ -z "$sha" ]]; then
    sha="$(gh pr view "$pr" --repo "$REPO_FULL" --json headRefOid --jq .headRefOid 2>/dev/null)" || return 1
  fi
  [[ -n "$sha" && "$sha" != "null" ]] || return 1
  printf '%s' "$sha"
}

verdict_of() {
  local pr="$1" v
  v="$(jq -r --arg pr "$pr" '.[$pr] // empty' <<<"$VERDICTS_JSON")"
  printf '%s' "${v:-wrap}"
}

# `wrap` is the only verdict that means "would merge this tick".
is_merge_candidate() { [[ "$1" == "wrap" ]]; }

# A hard-blocked anchor never lands, so its followers release immediately.
anchor_state_of() {
  local v="$1"
  case "$v" in
    wrap)                       printf 'ready' ;;
    BLOCKED:*|gone|error)       printf 'blocked' ;;
    *)                          printf 'progressing' ;;
  esac
}

# --------------------------------------------------------------------------
# Build the plan, one group at a time.
# --------------------------------------------------------------------------
GROUPS_JSON='[]'
PLAN='{}'
BATCHES='[]'
HOLDS_OUT='{}'
SUMMARY_PARTS=()
GROUP_INDEX=0

# Representative ids in ascending order → deterministic group numbering.
REPS="$(printf '%s\n' "${GROUP[@]}" | LC_ALL=C sort -n -u)"

while IFS= read -r rep; do
  [[ -z "$rep" ]] && continue

  MEMBERS=()
  for ((i = 0; i < N; i++)); do
    [[ "${GROUP[i]}" == "$rep" ]] && MEMBERS+=("${KEPT[i]}")
  done

  # --- Singleton: no overlap with anything, dispatch unchanged. -------------
  if [[ ${#MEMBERS[@]} -eq 1 ]]; then
    PR="${MEMBERS[0]}"
    V="$(verdict_of "$PR")"
    if is_merge_candidate "$V"; then ACTION="merge"; REASON="no overlap with other open PRs"
    else ACTION="not_merge_ready"; REASON="verdict is \`$V\` — not a merge candidate this tick"; fi
    PLAN="$(jq -c --arg pr "$PR" --arg a "$ACTION" --arg r "$REASON" \
      '.[$pr] = {action:$a, role:"independent", group:null, anchor:null,
                 shared_files:[], reason:$r}' <<<"$PLAN")"
    continue
  fi

  # --- Shared files = touched by 2+ members of this group. -----------------
  SHARED_FILE="$TMP/shared.$rep"
  : > "$SHARED_FILE"
  for PR in "${MEMBERS[@]}"; do cat "$TMP/f.$PR"; done \
    | LC_ALL=C sort | LC_ALL=C uniq -d > "$SHARED_FILE"
  SHARED_JSON="$(jq -R -s -c 'split("\n") | map(select(length > 0))' < "$SHARED_FILE")"

  # --- Footprint = changed lines in the SHARED files only. -----------------
  # Anchor = largest footprint; ties break to the lowest PR number, so the plan
  # is stable tick to tick rather than dependent on iteration order.
  FOOTPRINTS='{}'
  ANCHOR=""
  ANCHOR_FP=-1
  for PR in "${MEMBERS[@]}"; do
    # awk set-membership rather than sort|join: `join` needs both sides sorted on
    # the join field under the SAME delimiter, and a filename containing a space
    # would sort/split inconsistently between the tab-delimited fc.* and the
    # single-column shared list. Matching whole $1 against a set sidesteps that.
    FP="$(awk -F'\t' 'NR == FNR { want[$0] = 1; next }
                      ($1 in want) { s += $2 }
                      END { print s + 0 }' "$SHARED_FILE" "$TMP/fc.$PR")"
    [[ -z "$FP" ]] && FP=0
    FOOTPRINTS="$(jq -c --arg pr "$PR" --argjson fp "$FP" '.[$pr] = $fp' <<<"$FOOTPRINTS")"
    if (( FP > ANCHOR_FP )) || { (( FP == ANCHOR_FP )) && (( PR < ANCHOR )); }; then
      ANCHOR="$PR"; ANCHOR_FP="$FP"
    fi
  done

  ANCHOR_VERDICT="$(verdict_of "$ANCHOR")"
  ANCHOR_STATE="$(anchor_state_of "$ANCHOR_VERDICT")"
  if ! ANCHOR_SHA="$(head_sha_of "$ANCHOR")"; then
    echo "ERROR: could not resolve head SHA for anchor PR #$ANCHOR — refusing to" >&2
    echo "       fabricate a signature (it would advance the stall counter on an" >&2
    echo "       unobserved anchor). Pass --heads, or retry when gh is reachable." >&2
    exit 4
  fi
  ANCHOR_SIG="$ANCHOR_SHA:$ANCHOR_VERDICT"

  # --- Stall counter: unchanged signature since last tick means no progress.
  PRIOR_SIG="$(jq -r --arg a "$ANCHOR" '.[$a].signature // empty' <<<"$HOLDS_IN")"
  PRIOR_TICKS="$(jq -r --arg a "$ANCHOR" '.[$a].ticks // 0' <<<"$HOLDS_IN")"
  [[ "$PRIOR_TICKS" =~ ^[0-9]+$ ]] || PRIOR_TICKS=0
  if [[ -n "$PRIOR_SIG" && "$PRIOR_SIG" == "$ANCHOR_SIG" ]]; then
    TICKS=$(( PRIOR_TICKS + 1 ))
  else
    TICKS=1
  fi

  if [[ "$STALL_TICKS" -eq 0 ]]; then
    RELEASE=1; RELEASE_WHY="holding disabled (--stall-ticks 0)"
  elif [[ "$ANCHOR_STATE" == "blocked" ]]; then
    RELEASE=1; RELEASE_WHY="#$ANCHOR is $ANCHOR_VERDICT and will not land"
  elif (( TICKS > STALL_TICKS )); then
    RELEASE=1; RELEASE_WHY="#$ANCHOR has not progressed for $TICKS tick(s)"
  else
    RELEASE=0; RELEASE_WHY=""
  fi

  SHARED_PRETTY="$(jq -r '[.[] | "`" + . + "`"] | join(", ")' <<<"$SHARED_JSON")"
  BATCH_PRS=()
  HELD_PRS=()

  for PR in "${MEMBERS[@]}"; do
    V="$(verdict_of "$PR")"
    MY_SHARED="$(jq -c --slurpfile mine <(jq -R -s 'split("\n") | map(select(length > 0))' < "$TMP/f.$PR") \
      'map(select(. as $f | $mine[0] | index($f)))' <<<"$SHARED_JSON")"
    FP="$(jq -r --arg pr "$PR" '.[$pr] // 0' <<<"$FOOTPRINTS")"

    if [[ "$PR" == "$ANCHOR" ]]; then
      ROLE="anchor"
      if is_merge_candidate "$V"; then
        ACTION="merge"
        REASON="largest footprint ($FP changed line(s)) across the shared file(s) — merges first"
      else
        ACTION="not_merge_ready"
        REASON="anchor of this group but verdict is \`$V\` — not a merge candidate this tick"
      fi
    else
      ROLE="follower"
      if ! is_merge_candidate "$V"; then
        ACTION="not_merge_ready"
        REASON="verdict is \`$V\` — not a merge candidate this tick"
      elif [[ "$RELEASE" -eq 1 ]]; then
        ACTION="batch"; BATCH_PRS+=("$PR")
        REASON="released from hold — $RELEASE_WHY; batched so #$ANCHOR re-syncs once"
      else
        ACTION="hold"; HELD_PRS+=("$PR")
        REASON="held behind #$ANCHOR — shares $SHARED_PRETTY"
      fi
    fi

    PLAN="$(jq -c --arg pr "$PR" --arg a "$ACTION" --arg role "$ROLE" \
      --argjson g "$GROUP_INDEX" --argjson anchor "$ANCHOR" --argjson sf "$MY_SHARED" --arg r "$REASON" \
      '.[$pr] = {action:$a, role:$role, group:$g, anchor:$anchor, shared_files:$sf, reason:$r}' <<<"$PLAN")"
  done

  if [[ ${#BATCH_PRS[@]} -gt 0 ]]; then
    BATCHES="$(jq -c --argjson anchor "$ANCHOR" \
      --argjson prs "$(printf '%s\n' "${BATCH_PRS[@]}" | jq -R 'tonumber' | jq -sc '.')" \
      '. + [{anchor:$anchor, prs:$prs}]' <<<"$BATCHES")"
  fi

  # Carry the entry forward whenever this group produced a hold or a release, so
  # the stall counter keeps advancing across ticks. A released entry keeps its
  # (already-past-threshold) count so a follower that failed to merge is not
  # re-held; a changed anchor signature resets it to 1 above.
  if [[ ${#HELD_PRS[@]} -gt 0 || ${#BATCH_PRS[@]} -gt 0 ]]; then
    TRACKED=("${HELD_PRS[@]:-}" "${BATCH_PRS[@]:-}")
    TRACKED_JSON="$(printf '%s\n' "${TRACKED[@]}" | jq -R 'select(length > 0) | tonumber' | jq -sc 'sort')"
    HOLDS_OUT="$(jq -c --arg a "$ANCHOR" --argjson anchor "$ANCHOR" --arg sig "$ANCHOR_SIG" \
      --argjson ticks "$TICKS" --argjson members "$TRACKED_JSON" \
      --argjson released "$([[ ${#BATCH_PRS[@]} -gt 0 ]] && echo true || echo false)" \
      '.[$a] = {anchor:$anchor, signature:$sig, ticks:$ticks, members:$members, released:$released}' \
      <<<"$HOLDS_OUT")"
  fi

  if [[ ${#HELD_PRS[@]} -gt 0 ]]; then
    HELD_PRETTY="$(printf '#%s, ' "${HELD_PRS[@]}")"; HELD_PRETTY="${HELD_PRETTY%, }"
    SUMMARY_PARTS+=("holding $HELD_PRETTY until #$ANCHOR lands — they share $SHARED_PRETTY")
  fi
  if [[ ${#BATCH_PRS[@]} -gt 0 ]]; then
    BATCH_PRETTY="$(printf '#%s, ' "${BATCH_PRS[@]}")"; BATCH_PRETTY="${BATCH_PRETTY%, }"
    SUMMARY_PARTS+=("releasing $BATCH_PRETTY as one batch — $RELEASE_WHY; they share $SHARED_PRETTY")
  fi

  GROUPS_JSON="$(jq -c --argjson anchor "$ANCHOR" \
    --argjson members "$(printf '%s\n' "${MEMBERS[@]}" | jq -R 'tonumber' | jq -sc '.')" \
    --argjson shared "$SHARED_JSON" --argjson fp "$FOOTPRINTS" \
    --arg state "$ANCHOR_STATE" --arg sig "$ANCHOR_SIG" --argjson ticks "$TICKS" \
    '. + [{anchor:$anchor, members:$members, shared_files:$shared, footprints:$fp,
           anchor_state:$state, anchor_signature:$sig, ticks:$ticks}]' <<<"$GROUPS_JSON")"
  GROUP_INDEX=$(( GROUP_INDEX + 1 ))
done <<<"$REPS"

if [[ ${#SUMMARY_PARTS[@]} -eq 0 ]]; then
  SUMMARY="no overlap among merge candidates — dispatch order unchanged"
else
  SUMMARY="$(printf '%s; ' "${SUMMARY_PARTS[@]}")"; SUMMARY="${SUMMARY%; }"
fi

emit_and_exit "$(jq -cn --arg repo "$REPO_FULL" --argjson stall "$STALL_TICKS" \
  --argjson considered "$PRS_CONSIDERED" --argjson excluded "$EXCLUDED" \
  --argjson groups "$GROUPS_JSON" --argjson plan "$PLAN" \
  --argjson batches "$BATCHES" --argjson holds "$HOLDS_OUT" --arg summary "$SUMMARY" \
  '{repo:$repo, stall_ticks:$stall, prs_considered:$considered, excluded_prs:$excluded,
    groups:$groups, plan:$plan, batches:$batches, holds:$holds, summary:$summary}')"
