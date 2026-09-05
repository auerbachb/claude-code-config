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
#   (a) pre-run approval, run posts a finding -> pre_run_approval, not coverage
#   (a2) pre-run approval, run comes back clean -> redeemed (issue #1432, below)
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
# Issue #1432 — the complementary shape. The #1365 disqualifier conflates "an
# approval with no run behind it" (a rubber stamp; must block) with "an approval
# whose timestamp merely precedes a run that then COMPLETED CLEAN on the same
# SHA" (an emission-order artefact). On repos where CodeAnt emits APPROVED only
# as a pre-run stub, posts findings as a later COMMENTED review, and posts
# NOTHING when the run is clean, the second shape is the ONLY shape a clean pass
# can produce — so the CR path deadlocked with no exit but a paid Greptile
# escalation or an admin merge (still-point PR #696; this repo PR #1454).
#
# The redemption keys on the run marker reaching `done` with zero findings on
# HEAD — never on submitted_at, which CodeAnt freezes on in-place edits (#876)
# and which therefore can never move past the run start no matter how many times
# the bot is re-triggered.
#
#   (q1) the PR #696 trace verbatim         -> redeemed
#   (q2) frozen submitted_at + later clean run (PR #1454) -> redeemed
#   (q3) finding with an OLD submitted_at   -> blocks (presence, not ordering)
#   (q4) inline comment repointed off HEAD  -> not a finding; still redeems
#   (q4b) which review STATES are findings  -> COMMENTED/CHANGES_REQUESTED yes;
#                                              DISMISSED/PENDING no
#   (q5) redemption + self_report_mismatch  -> still blocked, flag false
#   (q6) no structured run record at all    -> nothing to redeem, unchanged
#   (r)  merge-gate integration             -> gate passes, redemption announced
#
# Issue #1632 — two runs on ONE SHA. `run_has_findings_on_head` counted EVERY
# CodeAnt inline comment on HEAD, not the findings of the run doing the
# redeeming. So on a SHA where run 1 posted findings that were all
# declined-with-evidence and RESOLVED (no code change warranted, therefore no new
# HEAD), the gate's own stated remedy — "comment `@codeant-ai review`" — could
# not work: run 2 completes with zero new findings, but the earlier comments keep
# the term true forever. Observed on PR #1612 at da2acd8 and PR #1627 at d4ac833;
# both fell to Greptile with the stickiness that brings.
#
# The inline term is now scoped to the governing run: a comment counts only when
# its created_at is inside that run's window, or its thread is not known to be
# resolved. Review-state findings stay SHA-wide.
#
#   (s1) run 1 findings resolved, run 2 clean -> redeemed
#   (s2) run 2 posts a NEW finding            -> blocks
#   (s2b) run-2 finding already resolved      -> still blocks (window branch)
#   (s3) a run-1 thread still unresolved      -> blocks
#   (s4) negative control: the same (s1) fixture with no thread data is the
#        pre-#1632 payload, and it must still return false — otherwise (s1)
#        proves nothing. The whole-suite control is
#        `EVAL_SUT=<origin/main>/review-substance.sh bash "$0"`, under which
#        (s1) fails; verified 2026-09-04.
#
# Every case above whose claim is "the stub is REFUSED" carries a finding on
# HEAD, so it keeps testing the refusal path rather than sliding onto the
# redemption path. (i) and (r) are the same fixture differing only in that
# finding — the discrimination control for the whole feature.
#
# Run from repo root: bash .claude/scripts/tests/merge-gate-codeant-run-marker.test.sh
# shellcheck source=tests/lib/merge-gate-test-fixtures.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# SUT and EVAL_SUT come from the harness sourced on the next line, which honours
# an environment override (issue #1485) — so the origin/main negative control for
# the assertions below is one command, not a clone-and-overlay:
#   EVAL_SUT=/path/to/main/.claude/scripts/review-substance.sh bash "$0"
source "$SCRIPT_DIR/lib/merge-gate-test-fixtures.sh"

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
  jq -cn --arg commit "$1" --arg 'done' "$2" --arg st "$3" --arg fin "$4" \
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

# A finding this reviewer produced ON HEAD: the COMMENTED verdict object CodeAnt
# posts when a run is not clean. Issue #1432 turns the ABSENCE of one of these
# into the redemption of a pre-run stub, so every case whose claim is "the stub
# is refused" now has to carry one — otherwise it is asserting the redemption
# path, not the refusal path. Where a fixture below gained this comment, the
# case narrative already said the run produced a finding; the fixture simply did
# not model it, because before #1432 nothing read it.
finding_review() { # login submitted_at
  jq -cn --arg login "$1" --arg at "$2" --arg sha "$HEAD_SHA" \
    '{user:{login:$login,type:"Bot"}, state:"COMMENTED", commit_id:$sha,
      submitted_at:$at,
      body:"The early return on the error path leaves the advisory lock held; release it before returning."}'
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
#     The finding the run posted afterwards is now part of the fixture: issue
#     #1432 makes "did this run produce a finding on HEAD" the term that decides
#     between a rubber stamp and an emission-order artefact, so the case that
#     claims REFUSAL has to model the trace it describes. (a2) below is the same
#     trace with the finding removed, and it redeems.
EV=$(evidence "[$(approval "$CA" "2026-08-26T16:16:13Z"),$(finding_review "$CA" "2026-08-26T16:19:55Z")]" \
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
check_eq "true" "$(r_field "$EV" run_has_findings_on_head)" \
  "(a) pre-run stub: the run that produced a finding is recorded as such"
check_eq "false" "$(r_field "$EV" redeemed_by_clean_run)" \
  "(a) pre-run stub: a run WITH findings redeems nothing"

# --------------------------------------------------------------------------
# (a2) Issue #1432 — the same trace with the run coming back CLEAN. This is the
#     shape that deadlocked still-point PR #696: CodeAnt emits APPROVED only as
#     a pre-run stub, posts findings as a later COMMENTED review, and posts
#     NOTHING when the run is clean, so a clean pass could never produce a
#     gate-valid approval. The completed run on this same SHA with zero findings
#     redeems the stub; `pre_run_approval` stays true because the ordering
#     violation really did happen.
# --------------------------------------------------------------------------
EV=$(evidence "[$(approval "$CA" "2026-08-26T16:16:13Z")]" \
              "[$(status_comment "$HEAD_SHA" true "$STARTED" "$FINISHED")]")
check_eq "true" "$(r_field "$EV" counts_as_coverage)" \
  "(a2) stub + completed clean run on the same SHA: counts as coverage"
check_eq "true" "$(r_field "$EV" redeemed_by_clean_run)" "(a2) redeemed_by_clean_run set"
check_eq "true" "$(r_field "$EV" pre_run_approval)" \
  "(a2) raw pre_run_approval stays true — the shape is redeemed, not erased"
check_eq "false" "$(r_field "$EV" run_has_findings_on_head)" "(a2) no findings on HEAD"
check_eq "" "$(r_disq "$EV")" "(a2) pre_run_approval left disqualified_by"
check_eq "$CA" "$(echo "$EV" | jq -r '.redeemed_by_clean_run | join(",")')" \
  "(a2) listed in the top-level redeemed_by_clean_run bucket"
check_eq "$CA" "$(echo "$EV" | jq -r '.substantive | join(",")')" "(a2) listed in .substantive"
check_eq "" "$(echo "$EV" | jq -r '.hollow | join(",")')" "(a2) no longer reported hollow"
check_eq "$CA" "$(echo "$EV" | jq -r '.pre_run | join(",")')" \
  "(a2) still listed in .pre_run — the bucket reports the shape, and nothing gates on it"

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
# Carries a finding so the boundary is read off `disqualified_by` itself; on a
# clean run the #1432 redemption clears the tag, and the boundary is then
# asserted on the raw field immediately below. Both halves are needed: the tag
# proves the refusal still lands, the raw field proves detection did not move.
EV=$(evidence "[$(approval "$CA" "2026-08-26T16:16:39Z"),$(finding_review "$CA" "2026-08-26T16:20:00Z")]" \
              "[$(status_comment "$HEAD_SHA" true "$STARTED" "$FINISHED")]")
check_contains "pre_run_approval" "$(r_disq "$EV")" "(c) one second before run start: refused"
EV=$(evidence "[$(approval "$CA" "2026-08-26T16:16:39Z")]" \
              "[$(status_comment "$HEAD_SHA" true "$STARTED" "$FINISHED")]")
check_eq "true" "$(r_field "$EV" pre_run_approval)" \
  "(c) one second before run start: still DETECTED when the clean run redeems it"
check_eq "true" "$(r_field "$EV" redeemed_by_clean_run)" \
  "(c) one second before run start, clean run: redeemed rather than refused"

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
# Each row is checked BOTH ways, because #1432 splits the verdict on a term the
# original fixture did not model. With the run"s finding present the stub is
# rejected exactly as before; with the run coming back clean the ordering
# violation is still DETECTED (raw pre_run_approval) and then redeemed. Asserting
# only the clean half would silently drop the #1365 refusal claim.
j_case() { # approved_at started finished label
  local ev
  ev=$(evidence "[$(approval "$CA" "$1"),$(finding_review "$CA" "2026-08-26T19:00:00Z")]" \
                "[$(status_comment "$HEAD_SHA" true "$2" "$3")]")
  check_contains "pre_run_approval" "$(r_disq "$ev")" "(j) PR #676 $4: rejected"
  ev=$(evidence "[$(approval "$CA" "$1")]" "[$(status_comment "$HEAD_SHA" true "$2" "$3")]")
  check_eq "true" "$(r_field "$ev" pre_run_approval)" "(j) PR #676 $4: stub still detected on a clean run"
  check_eq "true" "$(r_field "$ev" redeemed_by_clean_run)" "(j) PR #676 $4: clean run redeems it"
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
  jq -cn --arg commit "$1" --arg 'done' "$2" --arg st "$3" --arg fin "${4:-}" '
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
#     The newest run"s finding is carried so the claim under test stays the
#     SELECTION one (#1419: the newest row governs, not the oldest). On a clean
#     newest run #1432 redeems the stub, and the selection claim is then read off
#     run_started_at plus the raw pre_run_approval flag — asserted below so a
#     regression to `| last` still fails here.
EV=$(evidence "[$(approval "$CA" "2026-08-26T16:20:00Z"),$(finding_review "$CA" "2026-08-26T16:28:00Z")]" \
              "[$(status_comment_rows "$ROWS_NEWEST_FIRST")]")
check_contains "pre_run_approval" "$(r_disq "$EV")" \
  "(m) stub between runs: pre_run_approval fires against the newest run"
check_eq "false" "$(r_field "$EV" counts_as_coverage)" "(m) stub between runs: not coverage"
EV=$(evidence "[$(approval "$CA" "2026-08-26T16:20:00Z"),$(finding_review "$CA" "2026-08-26T16:28:00Z")]" \
              "[$(status_comment_rows "$ROWS_OLDEST_FIRST")]")
check_contains "pre_run_approval" "$(r_disq "$EV")" \
  "(m) stub between runs: same refusal under oldest-first ordering"

# Clean-newest-run mirror: still detected against the NEWEST run (a regression to
# `| last` on the newest-first payload would pick the 16:16 run, put the 16:20
# approval inside it, and report pre_run_approval false), then redeemed.
EV=$(evidence "[$(approval "$CA" "2026-08-26T16:20:00Z")]" \
              "[$(status_comment_rows "$ROWS_NEWEST_FIRST")]")
check_eq "2026-08-26T16:25:00Z" "$(r_field "$EV" run_started_at)" \
  "(m) clean newest run: the newest row still governs selection"
check_eq "true" "$(r_field "$EV" pre_run_approval)" \
  "(m) clean newest run: stub still detected against the newest run"
check_eq "true" "$(r_field "$EV" redeemed_by_clean_run)" \
  "(m) clean newest run: and then redeemed (issue #1432)"

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
# (q) Issue #1432 redemption, the four shapes stated in the ticket plus the two
#     live traces. (a2)/(c)/(j)/(m) above already cover the positive shape inside
#     their own narratives; these pin the boundaries that have no other home.
# --------------------------------------------------------------------------
# (q1) The still-point PR #696 trace verbatim: APPROVED 01:22:18Z, run started
#      01:22:36Z, finished 01:24:30Z, done, zero findings, no further review
#      object. Before #1432 this PR could only land via a paid Greptile
#      escalation or an admin merge.
Q_SHA="1ecca19bb2cc3dd44ee55ff66007718829aabbcc"
q_evidence() { # reviews_json issue_comments_json [pr_comments_json]
  jq -cn --arg sha "$Q_SHA" --arg push "2026-08-27T01:22:00Z" \
     --argjson reviews "$1" --argjson convo "$2" --argjson inline "${3:-[]}" \
     '{head_sha:$sha, push_ts:$push, reviews:$reviews,
       pr_comments:$inline, issue_comments:$convo}' \
    | "$EVAL_SUT" 2>/dev/null
}
q_approval() { # submitted_at
  jq -cn --arg login "$CA" --arg at "$1" --arg sha "$Q_SHA" \
    '{user:{login:$login,type:"Bot"}, state:"APPROVED", commit_id:$sha,
      submitted_at:$at, body:""}'
}
q_status() { # done started finished
  jq -cn --arg commit "$Q_SHA" --arg 'done' "$1" --arg st "$2" --arg fin "$3" --arg login "$CA" '
    ($commit | .[0:7]) as $short
    | { user: {login: $login, type: "Bot"},
        created_at: "2026-08-27T01:22:36Z", updated_at: "2026-08-27T01:24:30Z",
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
EV=$(q_evidence "[$(q_approval "2026-08-27T01:22:18Z")]" \
                "[$(q_status true "2026-08-27T01:22:36" "2026-08-27T01:24:30")]")
check_eq "true" "$(r_field "$EV" redeemed_by_clean_run)" "(q1) PR #696 trace: redeemed"
check_eq "true" "$(r_field "$EV" counts_as_coverage)" "(q1) PR #696 trace: counts as coverage"
check_eq "true" "$(r_field "$EV" pre_run_approval)" "(q1) PR #696 trace: 18s ordering violation still recorded"

# (q2) The PR #1454 shape (this repo, HEAD 52a3338): CodeAnt PATCHed its review
#      object in place after an explicit @codeant-ai review, so submitted_at
#      stayed frozen a DAY before the run it is being judged against. Any
#      redemption keyed on submitted_at moving past the run start could never
#      fire here — this pins that the rule keys on the run marker instead.
FROZEN_SHA="52a3338cc11dd22ee33ff4400556677889900aab"
q2_evidence() { # reviews_json issue_comments_json
  jq -cn --arg sha "$FROZEN_SHA" --arg push "2026-08-29T16:20:00Z" \
     --argjson reviews "$1" --argjson convo "$2" \
     '{head_sha:$sha, push_ts:$push, reviews:$reviews,
       pr_comments:[], issue_comments:$convo}' | "$EVAL_SUT" 2>/dev/null
}
FROZEN_APPROVAL=$(jq -cn --arg login "$CA" --arg sha "$FROZEN_SHA" \
  '{user:{login:$login,type:"Bot"}, state:"APPROVED", commit_id:$sha,
    submitted_at:"2026-08-28T19:04:56Z", body:""}')
FROZEN_STATUS=$(jq -cn --arg commit "$FROZEN_SHA" --arg login "$CA" '
  ($commit | .[0:7]) as $short
  | { user: {login: $login, type: "Bot"},
      created_at: "2026-08-28T19:00:00Z", updated_at: "2026-08-29T16:32:38Z",
      body: ("## 🤖 CodeAnt AI — Review Status\n\nReviewing your PR and tracking every commit in one place below.\n\n"
             + "| Commit | Status |\n|---|---|\n| `" + $short + "` | Reviewed your PR |\n\n"
             + "<!-- codeant-review-status:[{\"label\":\"Reviewed your PR\",\"commit\":\"" + $commit
             + "\",\"started\":\"2026-08-29T16:29:53\",\"finished\":\"2026-08-29T16:32:38\",\"done\":true}] -->") }')
EV=$(q2_evidence "[$FROZEN_APPROVAL]" "[$FROZEN_STATUS]")
check_eq "true" "$(r_field "$EV" pre_run_approval)" \
  "(q2) frozen submitted_at: a day-old timestamp is still a pre-run approval"
check_eq "true" "$(r_field "$EV" redeemed_by_clean_run)" \
  "(q2) frozen submitted_at + later clean run on the same SHA: redeemed (PR #1454)"
check_eq "true" "$(r_field "$EV" counts_as_coverage)" "(q2) frozen submitted_at: counts as coverage"

# (q3) Ordering is per commit_id, never per submitted_at. The finding here is
#      stamped BEFORE the run even started — the frozen-timestamp shape from
#      (q2) applied to a COMMENTED object — and it must still block redemption,
#      because presence on the HEAD-scoped index is the whole signal.
EV=$(evidence "[$(approval "$CA" "2026-08-26T16:16:13Z"),$(finding_review "$CA" "2026-08-25T09:00:00Z")]" \
              "[$(status_comment "$HEAD_SHA" true "$STARTED" "$FINISHED")]")
check_eq "true" "$(r_field "$EV" run_has_findings_on_head)" \
  "(q3) a finding on HEAD counts regardless of how old its submitted_at is"
check_eq "false" "$(r_field "$EV" redeemed_by_clean_run)" "(q3) and blocks the redemption"
check_contains "pre_run_approval" "$(r_disq "$EV")" "(q3) the stub stays refused"

# (q4) An inline comment whose original_commit_id points at an EARLIER commit is
#      not a finding from this run — $iidx already excludes it — so it neither
#      blocks the redemption nor grants evidence. The mirror of (g): a
#      HEAD-anchored inline comment DOES block (asserted there).
OLD_SHA_Q="9f8e7d6c5b4a39281706f5e4d3c2b1a098765432"
REPOINTED=$(jq -cn --arg login "$CA" --arg sha "$HEAD_SHA" --arg old "$OLD_SHA_Q" '
  [{user:{login:$login,type:"Bot"}, commit_id:$sha, original_commit_id:$old,
    created_at:"2026-08-26T16:19:00Z", updated_at:"2026-08-26T16:19:00Z",
    body:"Consider extracting this branch into a helper."}]')
EV=$(evidence "[$(approval "$CA" "2026-08-26T16:16:13Z")]" \
              "[$(status_comment "$HEAD_SHA" true "$STARTED" "$FINISHED")]" "$REPOINTED")
check_eq "false" "$(r_field "$EV" run_has_findings_on_head)" \
  "(q4) an inline comment repointed off HEAD is not a finding from this run"
check_eq "true" "$(r_field "$EV" redeemed_by_clean_run)" "(q4) so the clean run still redeems"

# (q4b) Which review STATES count as findings. The two that carry findings do;
#       DISMISSED and PENDING do not. GitHub re-points commit_id onto HEAD
#       across a conflict-free rebase, so a review this repo dismissed itself
#       (/fixpr runs dismiss-stale-bot-changes.sh after every push) can arrive
#       carrying HEAD"s SHA — counting it would block redemption permanently on
#       any PR that ever had one, re-creating the stranding the dismissal exists
#       to clear. Raised by the CodeRabbit CLI review of this PR.
state_review() { # state submitted_at
  jq -cn --arg login "$CA" --arg st "$1" --arg at "$2" --arg sha "$HEAD_SHA" \
    '{user:{login:$login,type:"Bot"}, state:$st, commit_id:$sha, submitted_at:$at,
      body:"The early return on the error path leaves the advisory lock held."}'
}
q4b_case() { # state expect_findings expect_redeemed
  local ev
  ev=$(evidence "[$(approval "$CA" "2026-08-26T16:16:13Z"),$(state_review "$1" "2026-08-26T16:20:00Z")]" \
                "[$(status_comment "$HEAD_SHA" true "$STARTED" "$FINISHED")]")
  check_eq "$2" "$(r_field "$ev" run_has_findings_on_head)" "(q4b) $1: run_has_findings_on_head == $2"
  check_eq "$3" "$(r_field "$ev" redeemed_by_clean_run)" "(q4b) $1: redeemed_by_clean_run == $3"
}
q4b_case CHANGES_REQUESTED true false
q4b_case COMMENTED         true false
q4b_case DISMISSED         false true
q4b_case PENDING           false true

# (q5) Redemption clears exactly two tags and nothing else. A self-report
#      mismatch on the same payload still blocks, and redeemed_by_clean_run is
#      false — the flag can never read as "gate cleared" when it was not.
#      Without this control, a redemption that dropped the whole $disq array
#      would pass every assertion above.
WRONG_SHA_COMMENT=$(jq -cn --arg login "$CA" '
  {user:{login:$login,type:"Bot"}, created_at:"2026-08-26T16:20:00Z", updated_at:"2026-08-26T16:20:00Z",
   body:"Finished reviewing the changes at commit deadbeefcafe1234567890abcdef0987654321ab across every changed file."}')
CR_INV_MARKER=$(jq -cn --arg login "$CR_BOT" '
  {user:{login:$login,type:"Bot"}, created_at:"2026-08-26T16:17:00Z", updated_at:"2026-08-26T16:17:00Z",
   body:"CodeRabbit is running the review on the latest commit now."}')
EV=$(evidence "[$(approval "$CA" "2026-08-26T16:16:13Z")]" \
              "[$(status_comment "$HEAD_SHA" true "$STARTED" "$FINISHED"),$WRONG_SHA_COMMENT]")
check_contains "self_report_mismatch" "$(r_disq "$EV")" "(q5) an unrelated disqualifier survives"
check_eq "false" "$(r_field "$EV" redeemed_by_clean_run)" \
  "(q5) redeemed_by_clean_run is false while any other disqualifier stands"
check_eq "false" "$(r_field "$EV" counts_as_coverage)" "(q5) and the approval is still not coverage"

# (q6) A reviewer with NO structured run record is untouched: there is no run to
#      redeem against, so the pre-#1365 judgement applies unchanged. Pairs with
#      the ticket"s "stub + no run -> still hollow" case.
EV=$(evidence "[$(approval "$CR_BOT" "2026-08-26T16:16:30Z")]" "[$CR_INV_MARKER]")
check_eq "false" "$(r_field "$EV" redeemed_by_clean_run "$CR_BOT")" \
  "(q6) no structured run record: nothing to redeem"
check_contains "temporal_inversion" "$(r_disq "$EV" "$CR_BOT")" \
  "(q6) and the prose-marker inversion path is unaffected"
check_eq "false" "$(r_field "$EV" counts_as_coverage "$CR_BOT")" "(q6) still not coverage"

# --------------------------------------------------------------------------
# (s) Issue #1632 — per-run scoping of the inline-comment findings term.
#
#     One SHA, two completed runs. Run 1 (16:16:40 -> 16:19:51) posted two
#     inline findings; both were answered and their threads RESOLVED, so no new
#     commit exists. Run 2 (16:25:00 -> 16:27:00) was the "@codeant-ai review"
#     re-run and came back clean, posting nothing. The governing marker is run 2
#     (max_by([done not, started])), and the approval predates both.
# --------------------------------------------------------------------------

# An inline finding on HEAD carrying the REST id and created_at the window and
# resolution tests read. commit_id AND original_commit_id are HEAD so it is not
# excluded by the (q4) repointing filter.
inline_finding() { # id created_at
  jq -cn --arg login "$CA" --arg sha "$HEAD_SHA" --argjson id "$1" --arg at "$2" '
    {id: $id, user: {login: $login, type: "Bot"},
     commit_id: $sha, original_commit_id: $sha,
     created_at: $at, updated_at: $at,
     body: "This early return leaves the advisory lock held; release it first."}'
}

# evidence() with the issue #1632 key added. Kept separate rather than folded
# into evidence() so every existing case keeps exercising the ABSENT-key path,
# which is the compatibility contract this feature rests on.
evidence_res() { # reviews_json issue_comments_json pr_comments_json resolved_ids_json
  jq -cn --arg sha "$HEAD_SHA" --arg push "$PUSH_TS" \
     --argjson reviews "$1" --argjson convo "$2" --argjson inline "$3" \
     --argjson resolved "$4" \
     '{head_sha:$sha, push_ts:$push, reviews:$reviews,
       pr_comments:$inline, issue_comments:$convo,
       resolved_comment_ids:$resolved}' \
    | "$EVAL_SUT" 2>/dev/null
}

S_ROWS="[$(run_row "$HEAD_SHA" true "$STARTED2" "$FINISHED2"),$(run_row "$HEAD_SHA" true "$STARTED" "$FINISHED")]"
S_STATUS="[$(status_comment_rows "$S_ROWS")]"
S_APPROVAL="[$(approval "$CA" "2026-08-26T16:16:13Z")]"
# Inside run 1's window (16:16:40 -> 16:19:51), outside run 2's.
S_RUN1_FINDINGS="[$(inline_finding 901 "2026-08-26T16:17:00Z"),$(inline_finding 902 "2026-08-26T16:18:00Z")]"

# (s1) Both run-1 findings resolved, run 2 clean -> the re-run redeems the stub.
EV=$(evidence_res "$S_APPROVAL" "$S_STATUS" "$S_RUN1_FINDINGS" "[901,902]")
check_eq "false" "$(r_field "$EV" run_has_findings_on_head)" \
  "(s1) resolved findings from an EARLIER run on this SHA are not this run's findings"
check_eq "true" "$(r_field "$EV" redeemed_by_clean_run)" \
  "(s1) so the later clean run redeems the pre-run approval"
check_eq "true" "$(r_field "$EV" counts_as_coverage)" "(s1) and the approval counts as coverage"
check_eq "true" "$(r_field "$EV" pre_run_approval)" \
  "(s1) the ordering violation is still recorded — redeemed, not erased"
check_eq "2" "$(r_field "$EV" inline_comments_on_head)" \
  "(s1) the comments are still COUNTED and reported; only the findings term changed"
check_eq "" "$(r_disq "$EV")" "(s1) nothing left in disqualified_by"

# (s2) Run 2 posts a NEW finding on the same SHA -> nothing to redeem.
S_RUN2_FINDING=$(inline_finding 903 "2026-08-26T16:26:00Z")
EV=$(evidence_res "$S_APPROVAL" "$S_STATUS" \
     "[$(inline_finding 901 "2026-08-26T16:17:00Z"),$(inline_finding 902 "2026-08-26T16:18:00Z"),$S_RUN2_FINDING]" \
     "[901,902]")
check_eq "true" "$(r_field "$EV" run_has_findings_on_head)" \
  "(s2) a finding posted inside the governing run's window counts"
check_eq "false" "$(r_field "$EV" redeemed_by_clean_run)" "(s2) and blocks the redemption"
check_contains "pre_run_approval" "$(r_disq "$EV")" "(s2) the stub stays refused"

# (s2b) Same, but the run-2 finding's thread was resolved too. The window branch
#       is a disjunct, not a fallback: a finding THIS run produced counts however
#       quickly it was closed out. Without this, "resolve the thread" would be a
#       one-step laundering of a live finding.
EV=$(evidence_res "$S_APPROVAL" "$S_STATUS" \
     "[$(inline_finding 901 "2026-08-26T16:17:00Z"),$S_RUN2_FINDING]" "[901,903]")
check_eq "true" "$(r_field "$EV" run_has_findings_on_head)" \
  "(s2b) resolving a finding the governing run itself posted does not launder it"
check_eq "false" "$(r_field "$EV" redeemed_by_clean_run)" "(s2b) redemption still refused"

# (s3) One run-1 thread is still UNRESOLVED -> blocks, whatever run posted it.
EV=$(evidence_res "$S_APPROVAL" "$S_STATUS" "$S_RUN1_FINDINGS" "[901]")
check_eq "true" "$(r_field "$EV" run_has_findings_on_head)" \
  "(s3) an unresolved earlier-run thread still counts as an open finding"
check_eq "false" "$(r_field "$EV" redeemed_by_clean_run)" "(s3) and blocks the redemption"
check_contains "pre_run_approval" "$(r_disq "$EV")" "(s3) the stub stays refused"

# (s4) NEGATIVE CONTROL. The identical (s1) fixture with the key absent is the
#      pre-#1632 payload — every inline comment reads as unresolved — and it must
#      still refuse. If this ever passes as redeemed, (s1) is vacuous: the
#      redemption would be coming from the window test alone rather than from the
#      resolution data, and every caller that supplies no thread data would have
#      silently changed verdict.
EV=$(evidence "$S_APPROVAL" "$S_STATUS" "$S_RUN1_FINDINGS")
check_eq "true" "$(r_field "$EV" run_has_findings_on_head)" \
  "(s4) negative control: with no thread data every HEAD inline comment still counts"
check_eq "false" "$(r_field "$EV" redeemed_by_clean_run)" \
  "(s4) negative control: and the pre-#1632 payload still refuses redemption"
# Same, spelled as an explicit empty array rather than an absent key.
EV=$(evidence_res "$S_APPROVAL" "$S_STATUS" "$S_RUN1_FINDINGS" "[]")
check_eq "false" "$(r_field "$EV" redeemed_by_clean_run)" \
  "(s4) negative control: an explicit empty resolved set behaves identically"
# And ids may arrive as strings — both sides are stringified before the compare.
EV=$(evidence_res "$S_APPROVAL" "$S_STATUS" "$S_RUN1_FINDINGS" '["901","902"]')
check_eq "true" "$(r_field "$EV" redeemed_by_clean_run)" \
  "(s4) string-spelled ids match the numeric REST ids"

# --------------------------------------------------------------------------
# (h)/(i) merge-gate.sh integration: the verdict has to reach the gate, and the
#     missing[] reason has to say WHY — naming the reviewer and the timing, not
#     the generic "need 1 approval". And --allow-hollow-approval must not
#     launder it: that flag covers "the bot said nothing", never the bot's own
#     record contradicting the claim that it reviewed this commit.
# --------------------------------------------------------------------------
GATE_OUT=""
GATE_ERR=""
# The run carries a finding, so this is the REFUSAL fixture (see (a) above for
# why every refusal case now models one). The clean-run counterpart is (r).
run_gate() { # extra args forwarded to merge-gate.sh
  GATE_ERR="$TMP/gate-stderr-$$.txt"
  GATE_OUT=$(PATH="$BIN:$PATH" \
    FAKE_CHECK_RUNS='{"check_runs":[]}' \
    FAKE_REVIEWS="[$(approval "$CA" "2026-07-21T10:00:00Z"),$(finding_review "$CA" "2026-07-21T10:10:00Z")]" \
    FAKE_ISSUE_COMMENTS="[$(status_comment "$HEAD_SHA" true "2026-07-21T10:05:00" "2026-07-21T10:09:00" \
                            "2026-07-21T09:59:30Z" "2026-07-21T10:06:00Z")]" \
    "$SUT" 1 --reviewer cr "$@" 2>"$GATE_ERR")
}
# Same fixture with the finding removed: the #1432 shape reaching the real gate.
run_gate_clean() {
  GATE_ERR="$TMP/gate-clean-stderr-$$.txt"
  GATE_OUT=$(PATH="$BIN:$PATH" \
    FAKE_CHECK_RUNS='{"check_runs":[]}' \
    FAKE_REVIEWS="[$(approval "$CA" "2026-07-21T10:00:00Z")]" \
    FAKE_ISSUE_COMMENTS="[$(status_comment "$HEAD_SHA" true "2026-07-21T10:05:00" "2026-07-21T10:09:00" \
                            "2026-07-21T09:59:30Z" "2026-07-21T10:06:00Z")]" \
    "$SUT" 1 --reviewer cr 2>"$GATE_ERR")
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

# --------------------------------------------------------------------------
# (r) Issue #1432 at the gate: the identical fixture with the run coming back
#     clean has to reach primary_review_met, and the redemption has to be
#     ANNOUNCED — the same "redemption is never silent" convention the #876
#     STALE_REDEEMED messages set. (i)/(r) differ only in the finding, so a
#     change that granted unconditionally fails (i) rather than passing here.
# --------------------------------------------------------------------------
run_gate_clean
check_eq "true" "$(echo "$GATE_OUT" | jq -r '.primary_review_met')" \
  "(r) merge-gate: a pre-run stub redeemed by a completed clean run satisfies the primary review"
check_not_contains "before its own recorded analysis" "$(gate_missing)" \
  "(r) merge-gate: the pre-run blocking reason is gone from missing[]"
check_contains "issue #1432" "$(cat "$GATE_ERR")" \
  "(r) merge-gate: the redemption is announced on stderr"
check_contains "with zero findings" "$(cat "$GATE_ERR")" \
  "(r) merge-gate: the announcement says WHY it was redeemed"
check_contains "2026-07-21T10:05:00Z" "$(cat "$GATE_ERR")" \
  "(r) merge-gate: the announcement quotes the run start so a reader can check it"
check_eq "true" "$(echo "$GATE_OUT" | jq -r '[.review_evidence.redeemed_by_clean_run[]?] | length > 0')" \
  "(r) merge-gate: review_evidence.redeemed_by_clean_run surfaces the redeemed approver"
check_eq "true" "$(echo "$GATE_OUT" | jq -r '[.review_evidence.pre_run[]?] | length > 0')" \
  "(r) merge-gate: and review_evidence.pre_run still records the shape for audit"

echo "----------------------------------------"
echo "merge-gate-codeant-run-marker.test.sh: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
