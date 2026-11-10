# codeant-round.jq — what counts as a COMPLETED CodeAnt round (issue #1749).
#
# One definition, used by two callers that must agree:
#   merge-gate.sh                 the ci+codeant-one-round gate (issue #1726)
#   review-triggers-allowed.sh    the "never re-invite CodeAnt once a round
#                                 exists" trigger rule (issue #1749)
# Load it with `jq -L <this dir> 'include "codeant-round"; ...'`. The rules are
# documented in .claude/reference/review-policy.md "What each gate means";
# change them here and both callers move together.
#
# A completed round is any ONE of three signals. An APPROVED alone is never a
# round: CodeAnt posts an approval stub before it has analysed anything
# (#1365, #1432). Identity is the exact `codeant-ai[bot]` login or the exact
# `codeant-ai` app slug. A check NAME is not identity, since any workflow in
# the PR can name a job "CodeAnt".

# (a) `done` rows in CodeAnt's structured run record, on ANY commit.
#     Input: the PR's issue comments, one flat array.
def codeant_round_record_count:
  [ .[]?
    | select((.user.login // "") == "codeant-ai[bot]")
    | (.body // "")
    | scan("<!--[[:space:]]*codeant-review-status:([\\s\\S]*?)-->")
    | (if type == "array" then (.[0] // "") else . end)
    | (fromjson? // empty)
    | (if type == "array" then .[] else empty end)
    | select(type == "object" and .done == true) ]
  | length;

# (b) COMMENTED / CHANGES_REQUESTED reviews, on ANY commit: CodeAnt posts
#     those only once it has run.
#     Input: the PR's reviews, one flat array.
def codeant_round_review_count:
  [ .[]?
    | select((.user.login // "") == "codeant-ai[bot]")
    | select((.state // "") == "COMMENTED" or (.state // "") == "CHANGES_REQUESTED") ]
  | length;

# (c) A completed check-run on HEAD that reached a verdict, published by the
#     CodeAnt app itself.
#     Input: {"check_runs": [...]} for the HEAD commit.
def codeant_round_check_count:
  [ .check_runs[]?
    | select((.status // "") == "completed")
    | select((.conclusion // "") | IN("success", "neutral", "failure"))
    | select((.app.slug // "") == "codeant-ai") ]
  | length;
