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
