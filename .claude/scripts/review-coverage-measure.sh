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
# Nothing is written to GitHub. Reads are GET-only and cached under --cache-dir, so a
# re-run costs no API calls. A missing cache file is `unknown`, never "no review".
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
# Graphite posts PR stack metadata, not a review verdict; it is excluded from "foreign".
STACK_LOGIN="graphite-app[bot]"
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
  --ledger-json FILE    Ledger entries as a JSON array, for the cross-check. Default:
                        `unreviewed-merge-ledger.sh list --repo <repo>`.
  --from-cache          Make no network calls; classify from the cache only (tests, re-runs).
  --fail-on-unknown     Exit 4 when any PR is unknown (default: report it and exit 0).
  -h, --help            Show this help.

Output
  stdout   one JSON object: class counts, shares, per-reviewer tallies, the
           threshold decision, and the ledger/label cross-check.
  cache    <cache-dir>/classified.jsonl holds one line per PR.

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

if [ -z "$CACHE_DIR" ]; then
  [ -n "${HOME:-}" ] || die "HOME is unset; pass --cache-dir" 2
  SLUG=$(printf '%s' "$REPO" | tr '/' '_')
  CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/review-coverage-measure/$SLUG"
fi
mkdir -p "$CACHE_DIR" || die "cannot create cache dir $CACHE_DIR" 4

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
tmpf() { mktemp "$CACHE_DIR/.tmp.XXXXXX"; }

POP="$CACHE_DIR/population.json"
if [ "$FROM_CACHE" -eq 0 ]; then
  POP_TMP=$(tmpf) || die "cannot create a temp file in $CACHE_DIR" 4
  if ! gh pr list --repo "$REPO" --state merged --author "$AUTHOR" --base main \
      --search "merged:>=$SINCE" --limit "$POP_LIMIT" \
      --json number,mergedAt,headRefOid,changedFiles,labels,baseRefName </dev/null > "$POP_TMP" 2>/dev/null; then
    rm -f "$POP_TMP"
    die "population fetch failed" 4
  fi
  N_POP=$(jq 'length' "$POP_TMP") || { rm -f "$POP_TMP"; die "population unreadable" 4; }
  if [ "$N_POP" -ge "$POP_LIMIT" ]; then
    rm -f "$POP_TMP"
    die "population reached --limit $POP_LIMIT; a page is missing, so the run is refused" 5
  fi
  mv "$POP_TMP" "$POP"
fi
[ -s "$POP" ] || die "no population at $POP (run once without --from-cache)" 2

# classify_pr NUM HEAD PR_JSON — prints one JSON line on stdout.
classify_pr() {
  num="$1"; head="$2"; pr="$3"
  rv="$CACHE_DIR/pr-$num.reviews.json"
  pc="$CACHE_DIR/pr-$num.pr_comments.json"
  ic="$CACHE_DIR/pr-$num.issue_comments.json"
  subst="$CACHE_DIR/pr-$num.substance.json"
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
  rv_m="$CACHE_DIR/pr-$num.reviews.atmerge.json"
  pc_m="$CACHE_DIR/pr-$num.pr_comments.atmerge.json"
  ic_m="$CACHE_DIR/pr-$num.issue_comments.atmerge.json"
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
  mv "$ST" "$subst"
  rm -f "$SI"

  printf '%s' "$pr" | jq -c --arg h "$head" \
    --slurpfile s "$subst" --slurpfile r "$rv" --slurpfile p "$pc" --slurpfile i "$ic" --arg cr "$CR_LOGIN" --arg ca "$CA_LOGIN" --arg stack "$STACK_LOGIN" \
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
    # Any other bot that reviewed or commented on this PR before the merge (Cursor,
    # Greptile, ...). The gate counts these through other paths; this script does not
    # score them, so such a PR is never classed as override.
    def foreign_bots:
      ([$r[0] | flatten[] | select(.commit_id == $h) | .user.login]
       + [$p[0] | flatten[] | select(.commit_id == $h or .original_commit_id == $h) | .user.login]
       + [$i[0] | flatten[] | .user.login])
      | map(select(. != null and endswith("[bot]") and . != $cr and . != $ca and . != $stack)) | unique;
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
jq -c '.[] | select((.baseRefName // "main") == "main")' "$POP" > "$LINES" || die "population unreadable" 4

COUNT=0
while IFS= read -r PR; do
  NUM=$(printf '%s' "$PR" | jq -r '.number') || die "population row unreadable" 4
  HEAD=$(printf '%s' "$PR" | jq -r '.headRefOid // ""')
  COUNT=$((COUNT + 1))

  if [ "$FROM_CACHE" -eq 0 ]; then
    for KIND in reviews pr_comments issue_comments; do
      F="$CACHE_DIR/pr-$NUM.$KIND.json"
      if [ ! -s "$F" ]; then
        case "$KIND" in
          reviews) API="repos/$REPO/pulls/$NUM/reviews" ;;
          pr_comments) API="repos/$REPO/pulls/$NUM/comments" ;;
          issue_comments) API="repos/$REPO/issues/$NUM/comments" ;;
        esac
        FT=$(tmpf) || die "cannot create a temp file in $CACHE_DIR" 4
        if gh api --paginate --slurp "$API?per_page=100" </dev/null > "$FT" 2>/dev/null \
            && jq -e 'flatten | type == "array"' "$FT" >/dev/null 2>&1; then
          mv "$FT" "$F"
        else
          rm -f "$FT"
          printf 'fetch failed: PR %s %s (classified unknown)\n' "$NUM" "$KIND" >&2
        fi
      fi
    done
    if [ $((COUNT % 25)) -eq 0 ]; then
      printf 'progress: %s PRs read\n' "$COUNT" >&2
    fi
  fi

  classify_pr "$NUM" "$HEAD" "$PR" >> "$CLS_TMP" || die "classification failed for PR $NUM" 4
done < "$LINES"
mv "$CLS_TMP" "$CLASSIFIED"
rm -f "$LINES"

# Ledger cross-check input. Status says where the ledger came from.
LEDGER_FILE="$CACHE_DIR/ledger.json"
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
' "$CLASSIFIED" || die "aggregation failed" 4

UNKNOWN=$(jq -s 'map(select(.class == "unknown")) | length' "$CLASSIFIED") || die "cannot count unknown PRs in $CLASSIFIED" 4
if [ "$FAIL_UNKNOWN" -eq 1 ] && [ "$UNKNOWN" -gt 0 ]; then
  printf 'review-coverage-measure: %s PR(s) unknown; see %s\n' "$UNKNOWN" "$CLASSIFIED" >&2
  exit 4
fi
exit 0
