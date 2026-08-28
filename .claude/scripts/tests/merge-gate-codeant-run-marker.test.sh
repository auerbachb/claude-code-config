#!/usr/bin/env bash
# merge-gate-codeant-run-marker.test.sh — Regression tests for issue #1365:
# CodeAnt pre-analysis approval STUBS scored as review coverage.
#
# Observed live on auerbachb/still-point PR #676, HEAD bb7d4e2, 2026-08-26.
# Every CodeAnt APPROVED on that PR predates its own run start:
#
#   commit    APPROVED at          run started   run finished   approval precedes
#   a5670b7   16:06:07Z            16:08:52      16:12:21       2m 45s
#   bb7d4e2   16:16:12Z/16:16:13Z  16:16:40      16:19:51       27s
#   3df6f81   18:16:56Z            18:23:50      18:27:07       6m 54s
#   440ded9   18:30:06Z (x2)       18:31:55      18:35:00       1m 49s
#   2ac8055   18:38:26Z            18:40:41      18:44:21       2m 15s
#
# CodeAnt's real verdict always arrives afterwards as a separate COMMENTED
# review. The APPROVED is a stub posted before any analysis has run.
#
# TWO defects combined to pass it:
#
#   1. An IN-FLIGHT review satisfied the evidence check. CodeAnt keeps one
#      in-place-edited "Review Status" comment whose table names every commit it
#      has touched, including the run still executing. That comment clears
#      min_chars, is not a failure phrase, and contains HEAD's SHA — so
#      status_comment_names_head went true, which set external_evidence_on_head,
#      which suppressed BOTH temporal_inversion and capability_failure. The run
#      marker certified itself, which is exactly the circularity
#      review-substance.sh's own header rules out.
#
#   2. CodeAnt run-marker parsing never fired. The prose regex requires the
#      literal "is reviewing" (etc.); CodeAnt writes "Reviewing your PR" /
#      "Reviewed your PR". $marker was therefore structurally null for that bot
#      on every PR, and temporal_inversion was dead code there — silently, with
#      no warning and no disqualified_by entry.
#
# The data was machine-readable and unread: CodeAnt embeds
# `<!-- codeant-review-status:[{"commit":…,"started":…,"finished":…,"done":…}] -->`
# in that same comment.
#
# Cases:
#   (a) pre-run approval                    -> pre_run_approval, not coverage
#   (b) in-flight approval                  -> not coverage; names_head FALSE
#   (c) post-run approval                   -> counts as coverage
#   (d) no structured marker (CodeRabbit)   -> byte-for-byte today's behaviour,
#                                              including the prose-marker
#                                              temporal_inversion path
#   (e) marker for other commits, not HEAD  -> unchanged, no new block
#   (f) malformed payload                   -> degrades, never blocks
#   (g) immune to external_evidence_on_head -> the #1365 defect-1 fix
#   (h) --allow-hollow-approval             -> does NOT launder it
#   (i) merge-gate missing[] names reviewer + timing, not "need 1 approval"
#   (j) the full PR #676 table               -> all five stubs rejected
#
# Issue #1419 (observed live on PR #1378): the payload is NOT append-ordered —
# CodeAnt PREPENDS each new run row, so the old `| last` selection returned the
# OLDEST HEAD run and the verdict depended on vendor insertion order. Selection
# is now by content: an in-flight row outranks completed ones, then the latest
# `started` wins.
#
#   (k) multi-row, newest-first            -> resolves to the newest run
#   (l) multi-row, oldest-first            -> identical verdict (order-agnostic)
#   (m) stub between two completed runs    -> pre_run_approval (the #1419 bypass;
#                                             granted by `| last` before the fix)
#   (n) re-review in flight over a done run -> in-flight row governs: names_head
#                                             false, pre_run_approval (the #1372
#                                             multi-row window)
#   (o) frozen created_at, in-flight row   -> still refused (PR #1378 report,
#                                             defects 1+2: the status comment is
#                                             PATCHed in place, created_at ~19h
#                                             stale; structured path reads
#                                             content, not created_at)
#   (p) frozen created_at, completed run   -> still redeems (created_at must
#                                             never gate the structured path in
#                                             the grant direction either)
#
# Run from repo root: bash .claude/scripts/tests/merge-gate-codeant-run-marker.test.sh
# shellcheck source=tests/lib/merge-gate-test-fixtures.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/merge-gate-test-fixtures.sh"

EVAL_SUT="$REPO_ROOT/.claude/scripts/review-substance.sh"
CA="codeant-ai[bot]"
CR_BOT="coderabbitai[bot]"
PUSH_TS="2026-08-26T16:16:00Z"

check_contains() { # needle haystack label
  case "$2" in
    *"$1"*) ok "$3" ;;
    *) bad "$3 (missing '$1' in: $2)" ;;
  esac
}
check_not_contains() { # needle haystack label
  case "$2" in
    *"$1"*) bad "$3 (unexpectedly found '$1')" ;;
    *) ok "$3" ;;
  esac
}

# CodeAnt's Review Status comment, carrying the structured payload verbatim in
# the shape observed on PR #676. `finished` is omitted when empty, which is what
# an in-flight row actually looks like.
status_comment() { # commit done started finished [created] [updated]
  jq -cn --arg commit "$1" --arg done "$2" --arg st "$3" --arg fin "$4" \
         --arg created "${5:-2026-08-26T16:16:05Z}" --arg updated "${6:-2026-08-26T16:16:45Z}" \
         --arg login "$CA" '
    ($commit | .[0:7]) as $short
    | { user: {login: $login, type: "Bot"},
        created_at: $created, updated_at: $updated,
        body: ("## 🤖 CodeAnt AI — Review Status\n\n"
               + "Reviewing your PR and tracking every commit in one place below.\n\n"
               + "| Commit | Status |\n|---|---|\n| `" + $short + "` | "
               + (if $done == "true" then "Reviewed your PR" else "🔄 Reviewing your PR…" end)
               + " |\n\n<!-- codeant-review-status:[{\"label\":\""
               + (if $done == "true" then "Reviewed your PR" else "Reviewing your PR" end)
               + "\",\"commit\":\"" + $commit + "\",\"started\":\"" + $st + "\""
               + (if $fin == "" then "" else ",\"finished\":\"" + $fin + "\"" end)
               + ",\"done\":" + $done + "}] -->") }'
}

approval() { # login submitted_at [body]
  jq -cn --arg login "$1" --arg at "$2" --arg body "${3:-}" --arg sha "$HEAD_SHA" \
    '{user:{login:$login,type:"Bot"}, state:"APPROVED", commit_id:$sha,
      submitted_at:$at, body:$body}'
}

# Run the pure evaluator over a payload assembled from JSON arrays.
evidence() { # reviews_json issue_comments_json [pr_comments_json]
  jq -cn --arg sha "$HEAD_SHA" --arg push "$PUSH_TS" \
     --argjson reviews "$1" --argjson convo "$2" --argjson inline "${3:-[]}" \
     '{head_sha:$sha, push_ts:$push, reviews:$reviews,
       pr_comments:$inline, issue_comments:$convo}' \
    | "$EVAL_SUT" 2>/dev/null
}
r_field() { echo "$1" | jq -r --arg l "${3:-$CA}" ".reviewers[\$l].$2"; }
r_disq()  { echo "$1" | jq -r --arg l "${2:-$CA}" '.reviewers[$l].disqualified_by | join(",")'; }

STARTED="2026-08-26T16:16:40.854977"
FINISHED="2026-08-26T16:19:51.141986"

# --------------------------------------------------------------------------
# (a) The reported trace: APPROVED 16:16:13Z, run started 16:16:40 — 27 seconds
#     BEFORE. The run completed and posted a real finding afterwards, so the
#     gate was green on a PR that was about to receive one.
# --------------------------------------------------------------------------
EV=$(evidence "[$(approval "$CA" "2026-08-26T16:16:13Z")]" \
              "[$(status_comment "$HEAD_SHA" true "$STARTED" "$FINISHED")]")
check_eq "false" "$(r_field "$EV" counts_as_coverage)" "(a) pre-run stub: not review coverage"
check_contains "pre_run_approval" "$(r_disq "$EV")" "(a) pre-run stub: named in disqualified_by"
check_eq "true" "$(r_field "$EV" pre_run_approval)" "(a) pre-run stub: pre_run_approval flag set"
check_eq "$CA" "$(echo "$EV" | jq -r '.pre_run | join(",")')" "(a) pre-run stub: listed in .pre_run"
check_eq "2026-08-26T16:16:40Z" "$(r_field "$EV" run_started_at)" \
  "(a) pre-run stub: run_started_at canonicalised onto the Z spelling"
check_eq "2026-08-26T16:19:51Z" "$(r_field "$EV" run_finished_at)" "(a) pre-run stub: run_finished_at exposed"
check_eq "true" "$(r_field "$EV" run_done)" "(a) pre-run stub: run_done exposed"
check_contains "$CA" "$(echo "$EV" | jq -r '.hollow | join(",")')" "(a) pre-run stub: reported hollow"

# --------------------------------------------------------------------------
# (b) In-flight: the HEAD row exists but `done` is false. This is the shape that
#     used to manufacture its own evidence — assert BOTH that it is refused and
#     that status_comment_names_head is the flag that stopped saying yes.
# --------------------------------------------------------------------------
EV=$(evidence "[$(approval "$CA" "2026-08-26T16:16:13Z")]" \
              "[$(status_comment "$HEAD_SHA" false "$STARTED" "")]")
check_eq "false" "$(r_field "$EV" counts_as_coverage)" "(b) in-flight: not review coverage"
check_eq "false" "$(r_field "$EV" status_comment_names_head)" \
  "(b) in-flight: an unfinished run-status row no longer names HEAD as evidence"
check_eq "false" "$(r_field "$EV" external_evidence_on_head)" \
  "(b) in-flight: and so grants no external evidence — the defect-1 chain is cut"
check_contains "pre_run_approval" "$(r_disq "$EV")" "(b) in-flight: disqualified"
check_eq "false" "$(r_field "$EV" run_done)" "(b) in-flight: run_done reported false"

# An approval landing AFTER an in-flight run started is still refused: `done` is
# the guarantee that a verdict exists at all.
EV=$(evidence "[$(approval "$CA" "2026-08-26T16:18:00Z")]" \
              "[$(status_comment "$HEAD_SHA" false "$STARTED" "")]")
check_contains "pre_run_approval" "$(r_disq "$EV")" \
  "(b) in-flight: approval after run start but before completion is still refused"

# --------------------------------------------------------------------------
# (c) The genuine shape must keep passing. The lower bound is the run START,
#     not its finish, and deliberately so: CodeAnt stamps `finished` when it
#     rewrites the table, AFTER posting its verdict object (observed on a5670b7:
#     COMMENTED 16:12:07, finished 16:12:21). A finish-based bound would reject
#     real approvals.
# --------------------------------------------------------------------------
EV=$(evidence "[$(approval "$CA" "2026-08-26T16:17:30Z")]" \
              "[$(status_comment "$HEAD_SHA" true "$STARTED" "$FINISHED")]")
check_eq "true" "$(r_field "$EV" counts_as_coverage)" "(c) post-run approval: counts as coverage"
check_eq "" "$(r_disq "$EV")" "(c) post-run approval: nothing disqualifying"
check_eq "true" "$(r_field "$EV" status_comment_names_head)" \
  "(c) post-run approval: a COMPLETED run-status row is still status evidence (#876 preserved)"

# Approval in the same second as the run start: accepted. The bound is
# submitted_at >= started, and canon_marker_ts makes that compare meaningful by
# folding the marker's naive UTC onto the same Z spelling the review uses —
# without it "…T16:16:40" is a strict PREFIX of "…T16:16:40Z" and sorts first.
EV=$(evidence "[$(approval "$CA" "2026-08-26T16:16:40Z")]" \
              "[$(status_comment "$HEAD_SHA" true "$STARTED" "$FINISHED")]")
check_eq "true" "$(r_field "$EV" counts_as_coverage)" \
  "(c) same-second as run start: accepted (>= is the documented bound)"

# One second earlier is refused — the boundary is real, not a rounding artefact.
EV=$(evidence "[$(approval "$CA" "2026-08-26T16:16:39Z")]" \
              "[$(status_comment "$HEAD_SHA" true "$STARTED" "$FINISHED")]")
check_contains "pre_run_approval" "$(r_disq "$EV")" "(c) one second before run start: refused"

# --------------------------------------------------------------------------
# (d) No structured marker at all -> today's behaviour, unchanged. The #1365
#     fix is scoped to structured markers precisely so the prose heuristic and
#     every #875 shape stay byte-for-byte alone.
# --------------------------------------------------------------------------
CR_WALKTHROUGH=$(jq -cn --arg login "$CR_BOT" --arg sha "$HEAD_SHA" '
  {user:{login:$login,type:"Bot"}, created_at:"2026-08-26T16:17:00Z", updated_at:"2026-08-26T16:17:00Z",
   body:("Reviewing files that changed from the base of the PR up to " + $sha
         + ". Walkthrough: three files changed, all covered below in detail.")}')
EV=$(evidence "[$(approval "$CR_BOT" "2026-08-26T16:18:00Z")]" "[$CR_WALKTHROUGH]")
check_eq "true" "$(r_field "$EV" counts_as_coverage "$CR_BOT")" \
  "(d) CodeRabbit bodylen=0 + walkthrough naming HEAD: still coverage"
check_eq "null" "$(r_field "$EV" run_done "$CR_BOT")" \
  "(d) no structured marker: run_done is null, distinguishable from 'unfinished'"
check_eq "false" "$(r_field "$EV" pre_run_approval "$CR_BOT")" "(d) no structured marker: pre_run_approval false"

# The prose-marker temporal_inversion path is untouched: approval BEFORE the
# bot's own "is running the review" notice, with no external evidence.
CR_MARKER=$(jq -cn --arg login "$CR_BOT" '
  {user:{login:$login,type:"Bot"}, created_at:"2026-08-26T16:17:00Z", updated_at:"2026-08-26T16:17:00Z",
   body:"CodeRabbit is running the review on the latest commit now."}')
EV=$(evidence "[$(approval "$CR_BOT" "2026-08-26T16:16:30Z")]" "[$CR_MARKER]")
check_contains "temporal_inversion" "$(r_disq "$EV" "$CR_BOT")" \
  "(d) prose-marker temporal_inversion still fires — the old path is intact"
check_not_contains "pre_run_approval" "$(r_disq "$EV" "$CR_BOT")" \
  "(d) and does not double-report as pre_run_approval"

# --------------------------------------------------------------------------
# (e) A structured marker covering OTHER commits but not HEAD constrains
#     nothing — the reviewer simply has not recorded a run for this commit.
# --------------------------------------------------------------------------
OTHER_SHA="a5670b7aaaabbbbccccddddeeeeffff001122334"
CONVO=$(jq -cn --argjson c "$(status_comment "$OTHER_SHA" true "2026-08-26T16:08:52" "2026-08-26T16:12:21")" \
               --arg sha "$HEAD_SHA" '
  [ $c | .body = (.body + "\n\nReviewed your PR at commit " + $sha
                  + " with a full pass over every changed file in the diff.") ]')
EV=$(evidence "[$(approval "$CA" "2026-08-26T16:16:13Z")]" "$CONVO")
check_eq "true" "$(r_field "$EV" counts_as_coverage)" "(e) marker for another commit only: unchanged, coverage stands"
check_eq "null" "$(r_field "$EV" run_done)" "(e) marker for another commit only: no HEAD run recorded"

# --------------------------------------------------------------------------
# (f) A malformed payload degrades to today's behaviour rather than blocking.
#     `fromjson?` swallows it and the chain yields no markers.
# --------------------------------------------------------------------------
BAD=$(jq -cn --arg login "$CA" --arg sha "$HEAD_SHA" '
  {user:{login:$login,type:"Bot"}, created_at:"2026-08-26T16:16:05Z", updated_at:"2026-08-26T16:16:45Z",
   body:("Reviewed your PR at commit " + $sha + " and checked every changed file in the diff.\n"
         + "<!-- codeant-review-status:[{\"commit\": broken,,,] -->")}')
EV=$(evidence "[$(approval "$CA" "2026-08-26T16:16:13Z")]" "[$BAD]")
check_eq "true" "$(r_field "$EV" counts_as_coverage)" "(f) malformed payload: degrades, does not block"
check_eq "null" "$(r_field "$EV" run_done)" "(f) malformed payload: no marker parsed"

# A run marked done with no parseable `started` also degrades: there is nothing
# to order the approval against, and inventing a blocker from missing data is
# the failure mode #836 already warns about.
EV=$(evidence "[$(approval "$CA" "2026-08-26T16:16:13Z")]" \
              "[$(status_comment "$HEAD_SHA" true "" "$FINISHED")]")
check_not_contains "pre_run_approval" "$(r_disq "$EV")" "(f) done run with no start timestamp: degrades"

# --------------------------------------------------------------------------
# (g) NOT suppressed by external_evidence_on_head. temporal_inversion and
#     capability_failure both yield to external evidence; this one must not,
#     because in the reported trace the suppressing evidence WAS the marker
#     comment. Here CodeAnt leaves genuine HEAD-anchored inline comments — real
#     external evidence — and the pre-run approval is STILL refused.
# --------------------------------------------------------------------------
INLINE=$(jq -cn --arg login "$CA" --arg sha "$HEAD_SHA" '
  [{user:{login:$login,type:"Bot"}, commit_id:$sha, original_commit_id:$sha,
    created_at:"2026-08-26T16:19:00Z", updated_at:"2026-08-26T16:19:00Z",
    body:"Consider extracting this branch into a helper."}]')
EV=$(evidence "[$(approval "$CA" "2026-08-26T16:16:13Z")]" \
              "[$(status_comment "$HEAD_SHA" true "$STARTED" "$FINISHED")]" "$INLINE")
check_eq "true" "$(r_field "$EV" external_evidence_on_head)" "(g) external evidence genuinely present"
check_eq "false" "$(r_field "$EV" counts_as_coverage)" "(g) pre-run approval refused ANYWAY"
check_contains "pre_run_approval" "$(r_disq "$EV")" "(g) pre_run_approval is immune to the suppression"

# --------------------------------------------------------------------------
# (j) The whole PR #676 table. Every one of the five APPROVEDs is a stub.
# --------------------------------------------------------------------------
j_case() { # approved_at started finished label
  local ev
  ev=$(evidence "[$(approval "$CA" "$1")]" "[$(status_comment "$HEAD_SHA" true "$2" "$3")]")
  check_contains "pre_run_approval" "$(r_disq "$ev")" "(j) PR #676 $4: rejected"
}
j_case "2026-08-26T16:06:07Z" "2026-08-26T16:08:52" "2026-08-26T16:12:21" "a5670b7 (2m45s early)"
j_case "2026-08-26T16:16:12Z" "2026-08-26T16:16:40" "2026-08-26T16:19:51" "bb7d4e2 (27s early)"
j_case "2026-08-26T18:16:56Z" "2026-08-26T18:23:50" "2026-08-26T18:27:07" "3df6f81 (6m54s early)"
j_case "2026-08-26T18:30:06Z" "2026-08-26T18:31:55" "2026-08-26T18:35:00" "440ded9 (1m49s early)"
j_case "2026-08-26T18:38:26Z" "2026-08-26T18:40:41" "2026-08-26T18:44:21" "2ac8055 (2m15s early)"

# --------------------------------------------------------------------------
# (k)-(n) Multi-row selection (issue #1419). Live PR #1378: CodeAnt PREPENDS
#     each new run row (three rows for one SHA ordered 16:35, 16:31, 15:48; the
#     5-row visible table dropped its oldest commit when a new row arrived), so
#     the old `| last` picked the OLDEST run. Rows carry their own started/done
#     data, so selection must not read list position at all.
# --------------------------------------------------------------------------
run_row() { # commit done started [finished]
  jq -cn --arg commit "$1" --arg done "$2" --arg st "$3" --arg fin "${4:-}" '
    {label: (if $done == "true" then "Reviewed your PR" else "Reviewing your PR" end),
     commit: $commit}
    + (if $st == "" then {} else {started: $st} end)
    + (if $fin == "" then {} else {finished: $fin} end)
    + {done: ($done == "true")}'
}

# Same visible-table + embedded-payload shape as status_comment(), but carrying
# an arbitrary rows array so one comment can record several runs of one commit.
status_comment_rows() { # rows_json [created] [updated]
  jq -cn --argjson rows "$1" \
         --arg created "${2:-2026-08-26T16:16:05Z}" --arg updated "${3:-2026-08-26T16:16:45Z}" \
         --arg login "$CA" '
    { user: {login: $login, type: "Bot"},
      created_at: $created, updated_at: $updated,
      body: ("## 🤖 CodeAnt AI — Review Status\n\n| Commit | Status |\n|---|---|\n"
             + ([ $rows[] | ("| `" + (.commit | .[0:7]) + "` | "
                  + (if .done then "Reviewed your PR" else "🔄 Reviewing your PR…" end)
                  + " |\n") ] | add)
             + "\n<!-- codeant-review-status:" + ($rows | tojson) + " -->") }'
}

STARTED2="2026-08-26T16:25:00.500000"
FINISHED2="2026-08-26T16:27:00.100000"
ROWS_NEWEST_FIRST="[$(run_row "$HEAD_SHA" true "$STARTED2" "$FINISHED2"),$(run_row "$HEAD_SHA" true "$STARTED" "$FINISHED")]"
ROWS_OLDEST_FIRST="[$(run_row "$HEAD_SHA" true "$STARTED" "$FINISHED"),$(run_row "$HEAD_SHA" true "$STARTED2" "$FINISHED2")]"

# (k) Newest-first (the observed live ordering): the newest run governs, and an
#     approval inside it is coverage.
EV_K=$(evidence "[$(approval "$CA" "2026-08-26T16:26:00Z")]" \
                "[$(status_comment_rows "$ROWS_NEWEST_FIRST")]")
check_eq "2026-08-26T16:25:00Z" "$(r_field "$EV_K" run_started_at)" \
  "(k) newest-first payload: run_started_at is the newest run, not the oldest"
check_eq "2026-08-26T16:27:00Z" "$(r_field "$EV_K" run_finished_at)" \
  "(k) newest-first payload: run_finished_at is the newest run"
check_eq "true" "$(r_field "$EV_K" counts_as_coverage)" \
  "(k) approval inside the newest run: counts as coverage"
check_eq "" "$(r_disq "$EV_K")" "(k) approval inside the newest run: nothing disqualifying"

# (l) Oldest-first mirror: byte-identical reviewer verdict. Pinning the whole
#     object (sorted keys) is the order-independence claim itself.
EV_L=$(evidence "[$(approval "$CA" "2026-08-26T16:26:00Z")]" \
                "[$(status_comment_rows "$ROWS_OLDEST_FIRST")]")
check_eq "2026-08-26T16:25:00Z" "$(r_field "$EV_L" run_started_at)" \
  "(l) oldest-first payload resolves to the same newest run"
check_eq "$(echo "$EV_K" | jq -cS '.reviewers')" "$(echo "$EV_L" | jq -cS '.reviewers')" \
  "(l) reviewer verdicts identical under both payload orderings"

# (m) The #1419 bypass, pinned as a negative control: a stub posted AFTER the
#     older run started but BEFORE the newest run started. Under `| last` on
#     the live (newest-first) ordering the stale row vouched for it —
#     pre_run_approval false, coverage granted. It must be refused, under both
#     orderings.
EV=$(evidence "[$(approval "$CA" "2026-08-26T16:20:00Z")]" \
              "[$(status_comment_rows "$ROWS_NEWEST_FIRST")]")
check_contains "pre_run_approval" "$(r_disq "$EV")" \
  "(m) stub between runs: pre_run_approval fires against the newest run"
check_eq "false" "$(r_field "$EV" counts_as_coverage)" "(m) stub between runs: not coverage"
EV=$(evidence "[$(approval "$CA" "2026-08-26T16:20:00Z")]" \
              "[$(status_comment_rows "$ROWS_OLDEST_FIRST")]")
check_contains "pre_run_approval" "$(r_disq "$EV")" \
  "(m) stub between runs: same refusal under oldest-first ordering"

# (n) Re-review in flight over a completed first run (the issue #1372 multi-row
#     window): the in-flight row governs even though a done row exists, so the
#     comment stops being evidence and the approval is pre-run. Both orderings.
ROWS_REFLIGHT_NF="[$(run_row "$HEAD_SHA" false "$STARTED2"),$(run_row "$HEAD_SHA" true "$STARTED" "$FINISHED")]"
ROWS_REFLIGHT_OF="[$(run_row "$HEAD_SHA" true "$STARTED" "$FINISHED"),$(run_row "$HEAD_SHA" false "$STARTED2")]"
EV=$(evidence "[$(approval "$CA" "2026-08-26T16:26:00Z")]" \
              "[$(status_comment_rows "$ROWS_REFLIGHT_NF")]")
check_eq "false" "$(r_field "$EV" run_done)" "(n) re-review in flight: the in-flight row governs"
check_eq "2026-08-26T16:25:00Z" "$(r_field "$EV" run_started_at)" \
  "(n) re-review in flight: run_started_at is the in-flight run"
check_eq "false" "$(r_field "$EV" status_comment_names_head)" \
  "(n) a completed earlier run does not vouch while a re-review is in flight"
check_contains "pre_run_approval" "$(r_disq "$EV")" "(n) approval during re-flight: refused"
EV=$(evidence "[$(approval "$CA" "2026-08-26T16:26:00Z")]" \
              "[$(status_comment_rows "$ROWS_REFLIGHT_OF")]")
check_eq "false" "$(r_field "$EV" status_comment_names_head)" \
  "(n) same refusal under oldest-first ordering"

# A QUEUED in-flight row — done:false with no started at all — still governs
# over a completed sibling (CodeRabbit CLI review of this PR proposed excluding
# empty-started rows before max_by; that would let the completed run vouch the
# instant a re-review is queued, and a sole queued row would fall back to the
# legacy names-HEAD path — both reopen #1365 in the grant direction).
ROWS_QUEUED="[$(run_row "$HEAD_SHA" false ""),$(run_row "$HEAD_SHA" true "$STARTED" "$FINISHED")]"
EV=$(evidence "[$(approval "$CA" "2026-08-26T16:26:00Z")]" \
              "[$(status_comment_rows "$ROWS_QUEUED")]")
check_eq "false" "$(r_field "$EV" status_comment_names_head)" \
  "(n) queued re-review (no started yet): completed run still does not vouch"
check_contains "pre_run_approval" "$(r_disq "$EV")" \
  "(n) queued re-review: approval refused while the queued run governs"

# --------------------------------------------------------------------------
# (o)/(p) Frozen created_at (PR #1378 report, 2026-08-27, defects 1+2). CodeAnt
#     PATCHes its one status comment in place: on PR #1378 created_at
#     (2026-08-26T21:00:22Z) predated the push by ~19h while updated_at tracked
#     the run. Every fixture above uses a post-push created_at, so these two pin
#     that the structured path reads CONTENT, never created_at — in the refuse
#     direction (o) and the redeem direction (p). A refactor filtering the
#     structured path on `created_at >= push` would fail (p); one keying the
#     refusals on created_at would fail (o).
# --------------------------------------------------------------------------
EV=$(evidence "[$(approval "$CA" "2026-08-26T16:16:28Z")]" \
              "[$(status_comment "$HEAD_SHA" false "$STARTED" "" "2026-08-25T21:00:22Z" "2026-08-26T16:16:45Z")]")
check_contains "pre_run_approval" "$(r_disq "$EV")" \
  "(o) frozen created_at: in-flight marker still read via content, approval 12s pre-start refused"
check_eq "false" "$(r_field "$EV" status_comment_names_head)" \
  "(o) frozen created_at: in-flight row is still not HEAD evidence"
check_eq "false" "$(r_field "$EV" counts_as_coverage)" "(o) frozen created_at: not coverage"

EV=$(evidence "[$(approval "$CA" "2026-08-26T16:17:30Z")]" \
              "[$(status_comment "$HEAD_SHA" true "$STARTED" "$FINISHED" "2026-08-25T21:00:22Z" "2026-08-26T16:20:00Z")]")
check_eq "true" "$(r_field "$EV" status_comment_names_head)" \
  "(p) frozen created_at, completed run: table still names HEAD as evidence"
check_eq "true" "$(r_field "$EV" counts_as_coverage)" \
  "(p) frozen created_at, completed run: redemption unaffected by comment age"

# --------------------------------------------------------------------------
# (h)/(i) merge-gate.sh integration: the verdict has to reach the gate, and the
#     missing[] reason has to say WHY — naming the reviewer and the timing, not
#     the generic "need 1 approval". And --allow-hollow-approval must not
#     launder it: that flag covers "the bot said nothing", never the bot's own
#     record contradicting the claim that it reviewed this commit.
# --------------------------------------------------------------------------
GATE_OUT=""
run_gate() { # extra args forwarded to merge-gate.sh
  GATE_OUT=$(PATH="$BIN:$PATH" \
    FAKE_CHECK_RUNS='{"check_runs":[]}' \
    FAKE_REVIEWS="[$(approval "$CA" "2026-07-21T10:00:00Z")]" \
    FAKE_ISSUE_COMMENTS="[$(status_comment "$HEAD_SHA" true "2026-07-21T10:05:00" "2026-07-21T10:09:00" \
                            "2026-07-21T09:59:30Z" "2026-07-21T10:06:00Z")]" \
    "$SUT" 1 --reviewer cr "$@" 2>/dev/null)
}
gate_missing() { echo "$GATE_OUT" | jq -r '.missing | join(" | ")'; }

run_gate
check_eq "false" "$(echo "$GATE_OUT" | jq -r '.primary_review_met')" \
  "(i) merge-gate: a pre-run CodeAnt stub does not satisfy the primary review"
check_contains "$CA" "$(gate_missing)" "(i) merge-gate: missing[] names the reviewer"
check_contains "before its own recorded analysis" "$(gate_missing)" \
  "(i) merge-gate: missing[] explains the timing, not just 'need 1 approval'"
check_contains "2026-07-21T10:05:00Z" "$(gate_missing)" \
  "(i) merge-gate: missing[] quotes the run start so a reader can check it"
check_not_contains "need 1 explicit CodeRabbit or CodeAnt APPROVED" "$(gate_missing)" \
  "(i) merge-gate: does not also claim no approval exists — one exists, it is not coverage"
check_eq "true" "$(echo "$GATE_OUT" | jq -r '[.review_evidence.pre_run[]?] | length > 0')" \
  "(i) merge-gate: review_evidence.pre_run surfaces the discounted approver"

run_gate --allow-hollow-approval
check_eq "false" "$(echo "$GATE_OUT" | jq -r '.primary_review_met')" \
  "(h) --allow-hollow-approval does NOT launder a pre-run approval"
check_contains "before its own recorded analysis" "$(gate_missing)" \
  "(h) --allow-hollow-approval: the reason survives the override"

echo "----------------------------------------"
echo "merge-gate-codeant-run-marker.test.sh: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
