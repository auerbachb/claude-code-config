#!/usr/bin/env bash
# review-coverage-measure.sh — read-only measurement of how each PR the owner
# merged into main in a window cleared AI review at its merge HEAD (issue #2313).
# catalog: merge-gate-sequencing —Classify merged PRs by real AI review coverage at merge HEAD, reusing review-substance.sh
#
# Classes (one per PR, first match wins):
#   real        a substantive APPROVED on HEAD (review-substance counts_as_coverage)
#   discounted  a hollow APPROVED on HEAD AND a non-approval bot verdict on HEAD
#   other       a non-approval bot verdict on HEAD and no approval at all, OR activity by
#               another bot (not CodeRabbit or CodeAnt, e.g. Cursor or Greptile) on the
#               PR before the merge. Such a PR is named in `foreign`, never `override`.
#               Those bots are not scored here: the check is presence, not verdict.
#   override    no counted approval and no verdict on HEAD (the no-review override's
#               own definition, no-review-override.md); inferred from GitHub data
#               because the gate JSON is not stored. Sub-field `hollow_any` marks a
#               discounted approval inside it.
#   unknown     a fetch failed, a payload did not parse, or the substance check failed
#
# Nothing is written to GitHub. Reads are GET-only. Immutable API responses are cached under
# --cache-dir, keyed by repo, PR and endpoint, so a re-run costs no API calls. Each run works
# from its own directory under --cache-dir (population, staged payloads, evaluator output)
# and never reads a shared file it may have just replaced. A missing cache file is `unknown`,
# never "no review".
#
# Usage: review-coverage-measure.sh [--repo owner/name] [--author login] [--since YYYY-MM-DD]
#                                   [--cache-dir DIR] [--ledger-json FILE] [--from-cache]
#                                   [--fail-on-unknown]
#        review-coverage-measure.sh --help

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SUBSTANCE_SH="$SCRIPT_DIR/review-substance.sh"
LEDGER_SH="$SCRIPT_DIR/unreviewed-merge-ledger.sh"
CR_LOGIN="coderabbitai[bot]"
CA_LOGIN="codeant-ai[bot]"
# Other reviewer bots that can make a PR "foreign" (not scored here). Same reviewer set
# no-review-override.sh names (reviewer_bots), minus CodeRabbit and CodeAnt above. Any
# other bot (github-actions, Graphite stack comments, coverage bots) is not a reviewer.
FOREIGN_REVIEWERS_JSON='["cursor[bot]","greptile-apps[bot]"]'
THRESHOLD_PCT=20
MIN_CORE_REMAINING=1000
POP_LIMIT=1000
LEDGER_START="2026-11-11"

usage() {
  cat <<'EOF'
review-coverage-measure.sh — classify the PRs you merged into main by how they
cleared AI review at merge HEAD, and print aggregate shares as JSON.

Options
  --repo owner/name     Repo to measure (default: the current repo via gh).
  --author login        PR author to count (default: the authenticated gh user).
  --since YYYY-MM-DD    Earliest merge date, inclusive (default: 14 days ago, UTC).
  --cache-dir DIR       Cache for population and per-PR API payloads
                        (default: ${XDG_CACHE_HOME:-$HOME/.cache}/review-coverage-measure/<owner>_<repo>).
                        Population files are keyed by repo, author and --since, so a
                        --from-cache run needs the same --author and --since as the run
                        that fetched them.
  --ledger-json FILE    Ledger entries as a JSON array, for the cross-check. Default:
                        `unreviewed-merge-ledger.sh list --repo <repo>`.
  --from-cache          Make no network calls; classify from the cache only (tests, re-runs).
  --fail-on-unknown     Exit 4 when any PR is unknown (default: report it and exit 0).
  -h, --help            Show this help.

Output
  stdout   one JSON object: class counts, shares, per-reviewer tallies, the
           threshold decision, and the ledger/label cross-check.
  cache    <cache-dir>/classified.jsonl holds one line per PR (published last, never read back).

Method
  1. gh pr list --state merged --author <login> --base main --search "merged:>=<since>" (limit 1000;
     the run aborts if the count reaches the limit, because a page is then missing).
  2. Per PR: pulls/N/reviews, pulls/N/comments, issues/N/comments (paginated, cached).
  3. Each PR's payloads go to review-substance.sh with head_sha = headRefOid. The
     substance check is reused, not redefined. resolved_comment_ids is passed empty, so
     approvals are not discounted by thread-resolution state; this does not change the
     empty-vs-non-empty split the report relies on.
  4. The class is set from the per-reviewer states (see the header).

Exit codes
  0 ok · 2 usage or missing local tool · 4 GitHub read failed, quota too low, or
  unknown with --fail-on-unknown · 5 population reached the --limit

Limits
  Separates an empty or discounted approval from a counted one. A counted approval can
  still be shallow; this script does not judge depth.
EOF
}

die() {
  printf 'review-coverage-measure: %s\n' "$1" >&2
  exit "${2:-2}"
}

REPO=""
AUTHOR=""
SINCE=""
CACHE_DIR=""
LEDGER_JSON=""
FROM_CACHE=0
FAIL_UNKNOWN=0

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --repo) [ $# -ge 2 ] || die "--repo needs a value"; REPO="$2"; shift 2 ;;
    --author) [ $# -ge 2 ] || die "--author needs a value"; AUTHOR="$2"; shift 2 ;;
    --since) [ $# -ge 2 ] || die "--since needs a value"; SINCE="$2"; shift 2 ;;
    --cache-dir) [ $# -ge 2 ] || die "--cache-dir needs a value"; CACHE_DIR="$2"; shift 2 ;;
    --ledger-json) [ $# -ge 2 ] || die "--ledger-json needs a value"; LEDGER_JSON="$2"; shift 2 ;;
    --from-cache) FROM_CACHE=1; shift ;;
    --fail-on-unknown) FAIL_UNKNOWN=1; shift ;;
    *) die "unknown option: $1" 2 ;;
  esac
done

command -v jq >/dev/null 2>&1 || die "jq not found" 2
[ -x "$SUBSTANCE_SH" ] || die "review-substance.sh not found next to this script" 2
if [ "$FROM_CACHE" -eq 0 ]; then
  command -v gh >/dev/null 2>&1 || die "gh not found" 2
fi

if [ -z "$REPO" ]; then
  if [ "$FROM_CACHE" -eq 1 ]; then
    # The default cache path is derived from the repo, and no repo is resolved offline,
    # so an offline run without --repo must name its cache explicitly.
    [ -n "$CACHE_DIR" ] || die "--from-cache without --repo needs --cache-dir (no repo is resolved offline)" 2
    REPO="fixture/fixture"
  else
    REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null) || die "cannot resolve the repo; pass --repo" 4
  fi
fi
case "$REPO" in
  */*) : ;;
  *) die "--repo must be owner/name" 2 ;;
esac

if [ -z "$SINCE" ]; then
  SINCE=$(date -u -v-14d +%Y-%m-%d 2>/dev/null || date -u -d '14 days ago' +%Y-%m-%d) || die "cannot compute the window start" 2
fi
case "$SINCE" in
  [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) : ;;
  *) die "--since must be YYYY-MM-DD" 2 ;;
esac
if ! date -u -j -f %Y-%m-%d "$SINCE" +%Y-%m-%d >/dev/null 2>&1 \
    && ! date -u -d "$SINCE" +%Y-%m-%d >/dev/null 2>&1; then
  die "--since is not a real calendar date" 2
fi

if [ -z "$AUTHOR" ]; then
  if [ "$FROM_CACHE" -eq 1 ]; then
    AUTHOR="fixture"
  else
    AUTHOR=$(gh api user --jq .login 2>/dev/null) || die "cannot resolve the author; pass --author" 4
  fi
fi
# The author becomes part of a cache file name, so only login characters are accepted.
# Brackets (bot logins such as name[bot]) map to underscores in the file name.
if ! LC_ALL=C grep -Eq '^[][A-Za-z0-9._-]+$' <<<"$AUTHOR"; then
  die "--author must be a GitHub login (letters, digits, '.', '_', '-', '[bot]')" 2
fi
AUTHOR_KEY=$(printf '%s' "$AUTHOR" | tr '[]' '__')

if [ -z "$CACHE_DIR" ]; then
  [ -n "${HOME:-}" ] || die "HOME is unset; pass --cache-dir" 2
  SLUG=$(printf '%s' "$REPO" | tr '/' '_')
  CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/review-coverage-measure/$SLUG"
fi
mkdir -p "$CACHE_DIR" || die "cannot create cache dir $CACHE_DIR" 4
# Per-run directory inside the cache (same filesystem, so a publish is a hard link or a
# rename). Every file this run reads back lives here: the population copy, the staged PR
# payloads, the merge-time cut, the evaluator output and the classification list. Concurrent
# runs sharing one cache therefore never read or replace each other's files. The shared
# cache receives only immutable API responses and publish-only outputs, written after use.
RUN_DIR=$(mktemp -d "$CACHE_DIR/.run.XXXXXX") || die "cannot create a run directory in $CACHE_DIR" 4
# Remove only the directory mktemp returned above, and keep the exit status of the run.
cleanup_run_dir() {
  st=$?
  if [ -n "$RUN_DIR" ] && [ -d "$RUN_DIR" ]; then
    rm -f "$RUN_DIR"/* 2>/dev/null
    rmdir "$RUN_DIR" 2>/dev/null
  fi
  exit "$st"
}
trap cleanup_run_dir EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [ "$FROM_CACHE" -eq 0 ]; then
  REMAINING=$(gh api rate_limit --jq .resources.core.remaining 2>/dev/null) || die "rate_limit lookup failed" 4
  case "$REMAINING" in
    ''|*[!0-9]*) die "rate_limit unreadable; not measuring" 4 ;;
  esac
  if [ "$REMAINING" -lt "$MIN_CORE_REMAINING" ]; then
    die "core REST quota too low ($REMAINING remaining, need $MIN_CORE_REMAINING); re-run after the reset" 4
  fi
fi

# Every temp file is per-run (mktemp), so two runs sharing one cache never write the
# same temporary path; each finished file is then renamed into place atomically.
tmpf() { mktemp "$RUN_DIR/tmp.XXXXXX"; }

REPO_KEY=$(printf '%s' "$REPO" | tr '/' '_')
# The population is keyed by everything that selects it: repo, author, window start and
# base (fixed to main). Two runs with different windows or authors therefore never share
# a population file, and a window with no file is refused rather than served another's.
POP_NAME="$REPO_KEY.population.author-$AUTHOR_KEY.since-$SINCE.base-main.json"
POP="$CACHE_DIR/$POP_NAME"
RUN_POP="$RUN_DIR/population.json"
if [ "$FROM_CACHE" -eq 0 ]; then
  POP_TMP=$(tmpf) || die "cannot create a temp file in $RUN_DIR" 4
  if ! gh pr list --repo "$REPO" --state merged --author "$AUTHOR" --base main \
      --search "merged:>=$SINCE" --limit "$POP_LIMIT" \
      --json number,mergedAt,headRefOid,changedFiles,labels,baseRefName </dev/null > "$POP_TMP" 2>/dev/null; then
    die "population fetch failed" 4
  fi
  N_POP=$(jq 'length' "$POP_TMP") || die "population unreadable" 4
  if [ "$N_POP" -ge "$POP_LIMIT" ]; then
    die "population reached --limit $POP_LIMIT; a page is missing, so the run is refused" 5
  fi
  mv "$POP_TMP" "$RUN_POP" || die "cannot stage the population in $RUN_DIR" 4
  # Publish a copy for later --from-cache runs. An atomic rename replaces the same key only;
  # this run keeps reading its own copy, so a failed publish does not change its result.
  if ! { cp "$RUN_POP" "$RUN_DIR/population.publish" && mv -f "$RUN_DIR/population.publish" "$POP"; }; then
    rm -f "$RUN_DIR/population.publish"
    printf 'warning: could not publish %s (this run is unaffected; --from-cache will not see it)\n' "$POP" >&2
  fi
else
  [ -s "$POP" ] || die "no population at $POP (run once without --from-cache)" 2
  cp "$POP" "$RUN_POP" || die "population unreadable at $POP" 4
fi
[ -s "$RUN_POP" ] || die "population is empty for this run (author $AUTHOR, since $SINCE)" 2

# stage_payload NUM KIND — leaves this run's copy of one PR payload in $RUN_DIR. A cached
# payload is copied in (it is immutable per request). A missing payload is fetched while
# online, and the fetched copy is published to the cache by a no-clobber hard link. A
# payload still missing after this stays absent, so the PR is classified unknown.
stage_payload() {
  num="$1"; kind="$2"
  src="$CACHE_DIR/$REPO_KEY.pr-$num.$kind.json"
  dst="$RUN_DIR/pr-$num.$kind.json"
  if [ -s "$src" ]; then
    if ! cp "$src" "$dst" 2>/dev/null; then
      rm -f "$dst"
      printf 'cache read failed: PR %s %s (classified unknown)\n' "$num" "$kind" >&2
    fi
    return 0
  fi
  if [ "$FROM_CACHE" -eq 1 ]; then
    return 0
  fi
  case "$kind" in
    reviews) API="repos/$REPO/pulls/$num/reviews" ;;
    pr_comments) API="repos/$REPO/pulls/$num/comments" ;;
    issue_comments) API="repos/$REPO/issues/$num/comments" ;;
  esac
  FT=$(tmpf) || die "cannot create a temp file in $RUN_DIR" 4
  if gh api --paginate --slurp "$API?per_page=100" </dev/null > "$FT" 2>/dev/null \
      && jq -e 'flatten | type == "array"' "$FT" >/dev/null 2>&1 \
      && mv "$FT" "$dst"; then
    # Publish is best effort: an existing cache response is never replaced.
    if [ ! -e "$src" ] && ! ln "$dst" "$src" 2>/dev/null && [ ! -e "$src" ]; then
      printf 'warning: could not publish %s to the cache (this run is unaffected)\n' "$src" >&2
    fi
  else
    rm -f "$FT"
    printf 'fetch failed: PR %s %s (classified unknown)\n' "$num" "$kind" >&2
  fi
  return 0
}

# classify_pr NUM HEAD PR_JSON — prints one JSON line on stdout. Reads only this run's
# staged payloads in $RUN_DIR.
classify_pr() {
  num="$1"; head="$2"; pr="$3"
  rv="$RUN_DIR/pr-$num.reviews.json"
  pc="$RUN_DIR/pr-$num.pr_comments.json"
  ic="$RUN_DIR/pr-$num.issue_comments.json"
  base=$(printf '%s' "$pr" | jq -c '{number, merged_at: (.mergedAt // ""), head_sha: (.headRefOid // ""), changed_files: (.changedFiles // 0), labels: [(.labels // [])[] | .name]}') || return 1

  for f in "$rv" "$pc" "$ic"; do
    if [ ! -s "$f" ] || ! jq -e 'flatten | type == "array"' "$f" >/dev/null 2>&1; then
      printf '%s' "$base" | jq -c '. + {class: "unknown", sub: "fetch_or_parse_failed", cr: "unknown", ca: "unknown", hollow_any: false}'
      return 0
    fi
  done

  # Merge-time view: only evidence posted at or before the merge counts. A review
  # or comment that arrives after the merge cannot have cleared the gate.
  merged=$(printf '%s' "$pr" | jq -r '.mergedAt // ""')
  if [ -z "$merged" ]; then
    printf '%s' "$base" | jq -c '. + {class: "unknown", sub: "no_merge_time", cr: "unknown", ca: "unknown", hollow_any: false}'
    return 0
  fi
  rv_m=$(tmpf) || return 1
  pc_m=$(tmpf) || return 1
  ic_m=$(tmpf) || return 1
  # A review is cut on submitted_at. A comment is cut on updated_at: a status comment
  # created before the merge can be edited afterwards (CodeAnt's run record), so its
  # created_at says nothing about what it said at merge time. Cutting on updated_at
  # drops any comment edited after the merge, the conservative side.
  jq -c --arg m "$merged" '[flatten[] | select(((.submitted_at // .created_at // "") <= $m))]' "$rv" > "$rv_m" \
    && jq -c --arg m "$merged" '[flatten[] | select(((.updated_at // .created_at // "") <= $m))]' "$pc" > "$pc_m" \
    && jq -c --arg m "$merged" '[flatten[] | select(((.updated_at // .created_at // "") <= $m))]' "$ic" > "$ic_m" \
    || { printf '%s' "$base" | jq -c '. + {class: "unknown", sub: "merge_time_filter_failed", cr: "unknown", ca: "unknown", hollow_any: false}'; return 0; }
  rv="$rv_m"; pc="$pc_m"; ic="$ic_m"

  SI=$(tmpf) || return 1
  ST=$(tmpf) || { rm -f "$SI"; return 1; }
  jq -n --arg sha "$head" --slurpfile r "$rv" --slurpfile p "$pc" --slurpfile i "$ic" \
    '{head_sha: $sha, reviews: ($r[0] | flatten), pr_comments: ($p[0] | flatten), issue_comments: ($i[0] | flatten), resolved_comment_ids: []}' \
    > "$SI" 2>/dev/null || { rm -f "$SI" "$ST"; printf '%s' "$base" | jq -c '. + {class: "unknown", sub: "input_build_failed", cr: "unknown", ca: "unknown", hollow_any: false}'; return 0; }

  if ! "$SUBSTANCE_SH" < "$SI" > "$ST" 2>/dev/null \
      || ! jq -e '.reviewers | type == "object"' "$ST" >/dev/null 2>&1; then
    rm -f "$SI" "$ST"
    printf '%s' "$base" | jq -c '. + {class: "unknown", sub: "substance_check_failed", cr: "unknown", ca: "unknown", hollow_any: false}'
    return 0
  fi
  rm -f "$SI"

  # The evaluator output is classified from this run's copy only. It is never published,
  # so no other run can replace it between the evaluator and the classification.
  printf '%s' "$pr" | jq -c --arg h "$head" \
    --slurpfile s "$ST" --slurpfile r "$rv" --slurpfile p "$pc" --slurpfile i "$ic" --arg cr "$CR_LOGIN" --arg ca "$CA_LOGIN" --argjson fr "$FOREIGN_REVIEWERS_JSON" \
    '
    def state($login):
      ($s[0].reviewers[$login] // {}) as $rv
      | ([$r[0] | flatten[] | select(.user.login == $login and .commit_id == $h
            and (.state == "CHANGES_REQUESTED"
                 or (.state == "COMMENTED" and ((.body // "") | gsub("<!--[\\s\\S]*?-->"; "") | test("\\S")))))] | length) as $nonapp
      | ($rv.approved_on_head == true and $rv.counts_as_coverage == true) as $real
      | ($rv.approved_on_head == true and $rv.counts_as_coverage != true) as $hollow
      | ([$p[0] | flatten[] | select(.user.login == $login
            and (.commit_id == $h or .original_commit_id == $h)
            and ((.in_reply_to_id // null) == null))] | length) as $inlc
      | ($inlc > 0) as $inl
      | ($rv.run_done == true) as $done
      | { s: (if $real then "real"
              elif ($nonapp > 0 or $inl or $done) then "verdict"
              elif $hollow then "hollow"
              else "none" end),
          hollow: $hollow };
    # Reviewer bots from the $fr allowlist (Cursor, Greptile) that reviewed or commented
    # on HEAD before the merge. Issue comments count only when their body names HEAD
    # (full or 7-char SHA), since they carry no commit id. The gate counts these through
    # other paths; this script does not score them, so such a PR is never override.
    def foreign_bots:
      ([$r[0] | flatten[] | select(.commit_id == $h) | .user.login]
       + [$p[0] | flatten[] | select(.commit_id == $h or .original_commit_id == $h) | .user.login]
       + [$i[0] | flatten[] | select(((.body // "") | (contains($h) or contains($h[0:7])))) | .user.login])
      | map(select(. != null and (. as $x | $fr | index($x) != null))) | unique;
    [state($cr), state($ca)] as $st
    | foreign_bots as $fb
    | (any($st[]; .s == "real")) as $anyreal
    | (any($st[]; .s == "verdict")) as $anyverdict
    | (any($st[]; .hollow)) as $anyhollow
    | (if $anyreal then "real"
       elif $anyverdict and $anyhollow then "discounted"
       elif $anyverdict then "other"
       elif ($fb | length) > 0 then "other"
       else "override" end) as $class
    | (if $class == "real" then "counted_approval"
       elif $class == "discounted" then "hollow_approval_with_verdict"
       elif $class == "other" and $anyverdict then "non_approval_verdict_on_head"
       elif $class == "other" then "foreign_reviewer_activity"
       elif $anyhollow then "override_discounted_approval"
       else "override_no_signal" end) as $sub
    | {number, merged_at: (.mergedAt // ""), head_sha: $h, changed_files: (.changedFiles // 0),
       labels: [(.labels // [])[] | .name], class: $class, sub: $sub,
       cr: $st[0].s, ca: $st[1].s, hollow_any: $anyhollow, foreign: $fb}
    ' || { printf '%s' "$base" | jq -c '. + {class: "unknown", sub: "classify_failed", cr: "unknown", ca: "unknown", hollow_any: false}'; }
}

CLASSIFIED="$CACHE_DIR/classified.jsonl"
CLS_TMP=$(tmpf) || die "cannot create a temp file in $CACHE_DIR" 4
LINES=$(tmpf) || die "cannot create a temp file in $CACHE_DIR" 4
# Only PRs merged into main are in the denominator; a missing baseRefName reads as main.
jq -c '.[] | select((.baseRefName // "main") == "main")' "$RUN_POP" > "$LINES" || die "population unreadable" 4

COUNT=0
while IFS= read -r PR; do
  NUM=$(printf '%s' "$PR" | jq -r '.number') || die "population row unreadable" 4
  HEAD=$(printf '%s' "$PR" | jq -r '.headRefOid // ""')
  COUNT=$((COUNT + 1))

  for KIND in reviews pr_comments issue_comments; do
    stage_payload "$NUM" "$KIND"
  done
  if [ "$FROM_CACHE" -eq 0 ] && [ $((COUNT % 25)) -eq 0 ]; then
    printf 'progress: %s PRs read\n' "$COUNT" >&2
  fi

  classify_pr "$NUM" "$HEAD" "$PR" >> "$CLS_TMP" || die "classification failed for PR $NUM" 4
done < "$LINES"
rm -f "$LINES"

# Ledger cross-check input. Status says where the ledger came from.
LEDGER_FILE="$RUN_DIR/ledger.json"
LEDGER_STATUS="not checked"
if [ -n "$LEDGER_JSON" ]; then
  if jq -e 'type == "array"' "$LEDGER_JSON" >/dev/null 2>&1; then
    cp "$LEDGER_JSON" "$LEDGER_FILE"
    LEDGER_STATUS="from file"
  else
    die "--ledger-json is not a JSON array" 2
  fi
elif [ "$FROM_CACHE" -eq 0 ] && [ -x "$LEDGER_SH" ]; then
  LEDGER_TMP=$(tmpf) || die "cannot create a temp file in $CACHE_DIR" 4
  if "$LEDGER_SH" list --repo "$REPO" > "$LEDGER_TMP" 2>/dev/null \
      && jq -e 'type == "array"' "$LEDGER_TMP" >/dev/null 2>&1; then
    mv "$LEDGER_TMP" "$LEDGER_FILE"
    LEDGER_STATUS="unreviewed-merge-ledger.sh list"
  else
    rm -f "$LEDGER_TMP"
    LEDGER_STATUS="unavailable"
  fi
fi
[ -s "$LEDGER_FILE" ] || printf '[]\n' > "$LEDGER_FILE"

# Aggregates. Shares use all merged PRs as the denominator. The lower bound counts
# unknown PRs as having a real review; the upper bound counts them as lacking one.
# The decision is "warranted" only when the lower bound is above the threshold and
# "not warranted" only when the upper bound is at or below it.
jq -s --arg repo "$REPO" --arg since "$SINCE" --argjson thr "$THRESHOLD_PCT" \
   --arg ledger_status "$LEDGER_STATUS" --slurpfile ledger "$LEDGER_FILE" \
   --arg ledger_start "$LEDGER_START" --arg cr "$CR_LOGIN" --arg ca "$CA_LOGIN" '
  def pct($a; $b): if $b == 0 then 0 else (($a * 1000 / $b) | round) / 10 end;
  def fsum: map(.changed_files) | add // 0;
  # Compare exact integers, never the one-decimal rounded share: 200 of 999 is 20.02%,
  # which is above a strict 20% line even though it rounds to 20.0.
  def decide($lo; $up; $tot):
    if $lo * 100 > $thr * $tot then "warranted"
    elif $up * 100 <= $thr * $tot then "not_warranted"
    else "undetermined" end;
  . as $all
  | ($all | length) as $n
  | ($all | map(select(.class == "unknown")) | length) as $u
  | ($all | map(select(.class == "real"))) as $real
  | ($real | length) as $r
  | ($all | fsum) as $nf
  | ($real | fsum) as $rf
  | ($all | map(select(.class == "unknown")) | fsum) as $uf
  | ($n - $r - $u) as $lack_prs_lower_n
  | ($n - $r) as $lack_prs_upper_n
  | ($nf - $rf - $uf) as $lack_files_lower_n
  | ($nf - $rf) as $lack_files_upper_n
  | ($ledger[0] // []) as $led
  | ($led | map(select(((.repo // "") | ascii_downcase) == ($repo | ascii_downcase)))) as $led_repo
  | ($led_repo | map(.pr)) as $lnums
  | ($all | map(select(.class == "override")) | map(.number)) as $ov
  | ($all | map(.number)) as $popnums
  | ($all | map(select(.class == "override") | select(.merged_at < $ledger_start)) | map(.number)) as $ov_pre
  | ($ov - $lnums) as $ov_not_in_ledger
  | ($lnums | map(select(. as $x | $popnums | any(. == $x)))) as $led_in_pop
  | ($led_in_pop - $ov) as $led_not_override
  | ($all | map(select(any(.labels[]; . == "merged-unreviewed")) | .number)) as $lab_mu
  | ($all | map(select(any(.labels[]; . == "backfill-reviewed")) | .number)) as $lab_br
  | {
      repo: $repo,
      since: $since,
      threshold_pct: $thr,
      prs_total: $n,
      prs_unknown: $u,
      files_total: $nf,
      classes: (["real","override","discounted","other","unknown"]
        | map(. as $c | {key: $c, value: {prs: ($all | map(select(.class == $c)) | length),
                                          files: ($all | map(select(.class == $c)) | fsum)}})
        | from_entries),
      override_subclasses: ($all | map(select(.class == "override")) | group_by(.sub)
        | map({key: .[0].sub, value: length}) | from_entries),
      per_reviewer: ({($cr): ($all | reduce .[] as $x ({}; .[$x.cr] += 1)),
                      ($ca): ($all | reduce .[] as $x ({}; .[$x.ca] += 1))}),
      shares: {
        real_prs_pct: pct($r; $n),
        real_files_pct: pct($rf; $nf),
        lacking_prs_pct: {lower: pct($lack_prs_lower_n; $n), upper: pct($lack_prs_upper_n; $n)},
        lacking_files_pct: {lower: pct($lack_files_lower_n; $nf), upper: pct($lack_files_upper_n; $nf)}
      },
      decision: {
        prs: decide($lack_prs_lower_n; $lack_prs_upper_n; $n),
        files: decide($lack_files_lower_n; $lack_files_upper_n; $nf),
        overall: (if ($lack_prs_lower_n * 100 > $thr * $n) or ($lack_files_lower_n * 100 > $thr * $nf) then "warranted"
                  elif ($lack_prs_upper_n * 100 <= $thr * $n) and ($lack_files_upper_n * 100 <= $thr * $nf) then "not_warranted"
                  else "undetermined" end)
      },
      foreign_reviewer_prs: ($all | map(select((.foreign // []) | length > 0)) | length),
      ledger_cross_check: {
        status: $ledger_status,
        ledger_entries_in_repo: ($led_repo | length),
        ledger_entries_in_window: ($led_in_pop | length),
        override_prs: ($ov | length),
        override_in_ledger: (($ov | length) - ($ov_not_in_ledger | length)),
        override_not_in_ledger: ($ov_not_in_ledger | length),
        override_not_in_ledger_before_ledger_start: ($ov_pre | length),
        ledger_not_classified_override: $led_not_override
      },
      labels: {
        merged_unreviewed: ($lab_mu | length),
        backfill_reviewed: ($lab_br | length),
        merged_unreviewed_not_override: (($lab_mu - $ov) | length),
        backfill_reviewed_not_override: (($lab_br - $ov) | length)
      }
    }
' "$CLS_TMP" || die "aggregation failed" 4

# The aggregate is computed from this run's own list; the shared file is replaced only
# after the aggregate succeeded, so a concurrent run cannot change what was reported.
UNKNOWN=$(jq -s 'map(select(.class == "unknown")) | length' "$CLS_TMP") || die "cannot count unknown PRs" 4
mv "$CLS_TMP" "$CLASSIFIED" || die "cannot write $CLASSIFIED" 4
if [ "$FAIL_UNKNOWN" -eq 1 ] && [ "$UNKNOWN" -gt 0 ]; then
  printf 'review-coverage-measure: %s PR(s) unknown; see %s\n' "$UNKNOWN" "$CLASSIFIED" >&2
  exit 4
fi
exit 0
