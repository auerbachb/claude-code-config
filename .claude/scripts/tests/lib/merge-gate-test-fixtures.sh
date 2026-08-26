#!/usr/bin/env bash
# merge-gate-test-fixtures.sh — shared offline fixture, GitHub stub, and
# assertion harness for the concern-based merge-gate.sh test suites.
# This file intentionally does not end in .test.sh, so the test runner
# will not execute it directly.
#
# Consumed by:
#   merge-gate-ci-dedup.test.sh  — CI check-run dedup + CodeAnt supplemental gate (issue #675)
#   merge-gate-bugbot.test.sh    — BugBot reviewer merge-gate paths (issues #844, #962)
#
# Source from repo root or any worktree — REPO_ROOT is resolved via git.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SUT="$REPO_ROOT/.claude/scripts/merge-gate.sh"

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# Sandbox HOME: no session-state.json, so reviewer resolution stays deterministic.
export HOME="$TMP/home"; mkdir -p "$HOME/.claude"

PASS=0
FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1" >&2; FAIL=$((FAIL + 1)); }

check_eq() { # expected actual label
  if [[ "$1" == "$2" ]]; then ok "$3"; else bad "$3 (expected: $1, got: $2)"; fi
}

HEAD_SHA="deadbeefcafedeadbeefcafedeadbeefcafedead"

# --- Fake gh: only the endpoints merge-gate.sh actually calls. ---------------
BIN="$TMP/bin"; mkdir -p "$BIN"
cat > "$BIN/gh" <<EOF
#!/usr/bin/env bash
ARGS="\$*"
case "\$ARGS" in
  "repo view --json nameWithOwner --jq .nameWithOwner")
    echo "solo/repo"; exit 0 ;;
  "api user --jq .login")
    # Authorship guard (issue #733): viewer login; matches the PR author below
    # so authorship == "mine" and the merge is not blocked.
    echo "solouser"; exit 0 ;;
  *"pr view "*headRefOid*)
    jq -cn '{number:1, state:"OPEN", headRefOid:"$HEAD_SHA", baseRefName:"main",
             mergeStateStatus:"CLEAN", mergeable:"MERGEABLE", reviewDecision:"APPROVED",
             author:{login:"solouser", type:"User"}}'
    exit 0 ;;
  *check-runs*)
    printf '%s' "\$FAKE_CHECK_RUNS"; exit 0 ;;
  *commits/*/statuses*)
    # Legacy commit statuses (issue #1361) — a required context can be satisfied
    # by one of these instead of a check-run. Empty unless a test supplies them.
    printf '%s' "\${FAKE_COMMIT_STATUSES:-[]}"; exit 0 ;;
  *pulls/*/reviews*)
    printf '%s' "\${FAKE_REVIEWS:-[]}"; exit 0 ;;
  *pulls/*/comments*)
    printf '%s' "\${FAKE_PR_COMMENTS:-[]}"; exit 0 ;;
  *issues/*/comments*)
    printf '%s' "\${FAKE_ISSUE_COMMENTS:-[]}"; exit 0 ;;
  *graphql*)
    jq -cn '{data:{repository:{pullRequest:{reviewThreads:{nodes:[]}}}}}'; exit 0 ;;
  *"git/commits/"*)
    # Return a HEAD committer date earlier than all check-run completed_at values
    # (which are derived from check-run id as "2026-07-21T10:00:0{id}Z"). This
    # lets the stale-approval guard (issue #836) treat every check-run as fresh
    # — the important variable for CI-dedup tests is suite ordering, not freshness.
    jq -cn '{committer:{date:"2026-07-21T09:59:00Z"}}'; exit 0 ;;
  *"/branches/"*"/protection/required_status_checks"*)
    # Branch-protection required contexts (issue #1361). Default is a 404, which
    # combined with the unprotected branch object below resolves to "no required
    # status checks" — so every pre-#1361 expectation in this file is unchanged.
    # FAKE_REQUIRED_STATUS_CHECKS supplies the endpoint payload;
    # FAKE_BRANCH_PROTECTED=true marks the base branch protected.
    if [[ -n "\${FAKE_REQUIRED_STATUS_CHECKS:-}" ]]; then
      printf '%s' "\${FAKE_REQUIRED_STATUS_CHECKS}"; exit 0
    fi
    echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
  *"/branches/"*)
    if [[ -n "\${FAKE_BRANCH_JSON:-}" ]]; then
      printf '%s' "\${FAKE_BRANCH_JSON}"; exit 0
    fi
    jq -cn --arg p "\${FAKE_BRANCH_PROTECTED:-false}" \
      '{name:"main", protected:(\$p == "true"),
        protection:{required_status_checks:{contexts:[]}}}'
    exit 0 ;;
  *contents/*)
    # No CODEOWNERS file — merge-gate.sh tolerates the 404.
    echo "Not Found" >&2; exit 1 ;;
esac
echo "unexpected gh call: \$ARGS" >&2
exit 1
EOF
chmod +x "$BIN/gh"

# `completed_at` matters here in a way it does not for ci-status.sh: the CodeAnt
# supplemental gate reads it to find CodeAnt's latest clean signal, and a run
# without one reads as "no successful check". Ids ascend with suite recency in
# these fixtures, so deriving the timestamp from the id keeps them ordered.
# `app.id` defaults to 15368 — GitHub Actions' real app id, and the same value
# the required-contexts fixtures pin `checks[].app_id` to. They must agree by
# default: protection that scopes a context to an app is only satisfied by a run
# from THAT app (issue #1383 review), so a fixture whose run carried a different
# id than its own protection payload would read as `wrong_app` and describe a
# configuration GitHub never produces. Pass arg 7 to model a genuine mismatch.
# Dedup groups by [.app.slug, .app.id, .name], so a uniform id leaves every
# existing grouping exactly as it was — the slug is what varies across fixtures.
cr() { # id name conclusion suite_id [app_slug] [status] [app_id]
  jq -cn --argjson id "$1" --arg name "$2" --arg concl "$3" --argjson suite "$4" \
         --arg slug "${5:-gha}" --arg status "${6:-completed}" \
         --argjson appid "${7:-15368}" \
    '{id:$id, name:$name, status:$status,
      conclusion:(if $concl == "null" then null else $concl end),
      completed_at:(if $status == "completed" then "2026-07-21T10:00:0\($id)Z" else null end),
      check_suite:{id:$suite}, app:{slug:$slug, id:$appid}}'
}
bundle() { printf '{"check_runs":[%s]}' "$(IFS=,; echo "$*")"; }
