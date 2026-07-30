#!/usr/bin/env bash
# merge-gate-ci-dedup.test.sh — Offline integration tests proving merge-gate.sh
# stops blocking on superseded check-runs (issue #675).
#
# merge-gate.sh does not classify CI itself; it delegates to ci-status.sh via
# --check-runs-stdin. These tests assert the deduped verdict actually reaches the
# gate's emitted JSON and its `missing` list — and, via the negative controls, that
# a genuinely failing check still blocks.
#
# Also covers the gate's OTHER reader of the raw check-run list: the CodeAnt
# supplemental gate, which scans for a *successful* CodeAnt check-run. Undeduped,
# a stale success would satisfy it while a newer CodeAnt failure sat right beside
# it — a false clean in the merge-permitting direction.
#
# Only `gh` is stubbed; merge-gate.sh, ci-status.sh and check-runs-dedup.sh are the
# real scripts, run in place so they resolve each other as siblings.
#
# Run from repo root: bash .claude/scripts/tests/merge-gate-ci-dedup.test.sh
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
  *contents/*)
    # No CODEOWNERS file — merge-gate.sh tolerates the 404.
    echo "Not Found" >&2; exit 1 ;;
esac
echo "unexpected gh call: \$ARGS" >&2
exit 1
EOF
chmod +x "$BIN/gh"

OUT=""
RC=0
run_gate() { # $1 = check-runs JSON
  OUT=$(PATH="$BIN:$PATH" FAKE_CHECK_RUNS="$1" \
        FAKE_REVIEWS="${FAKE_REVIEWS:-[]}" \
        "$SUT" 1 --reviewer cr 2>/dev/null)
  RC=$?
}

# Is there a "CI has N failing check-run(s)" entry in `missing`?
has_ci_failing_entry() { echo "$OUT" | jq -e '[.missing[]? | select(startswith("CI has") and contains("failing"))] | length > 0' >/dev/null && echo yes || echo no; }
has_ci_incomplete_entry() { echo "$OUT" | jq -e '[.missing[]? | select(startswith("CI has") and contains("incomplete"))] | length > 0' >/dev/null && echo yes || echo no; }
has_codeant_no_clean_entry() { echo "$OUT" | jq -e '[.missing[]? | select(contains("no successful CodeAnt check-run"))] | length > 0' >/dev/null && echo yes || echo no; }

# `completed_at` matters here in a way it does not for ci-status.sh: the CodeAnt
# supplemental gate reads it to find CodeAnt's latest clean signal, and a run
# without one reads as "no successful check". Ids ascend with suite recency in
# these fixtures, so deriving the timestamp from the id keeps them ordered.
cr() { # id name conclusion suite_id [app_slug] [status]
  jq -cn --argjson id "$1" --arg name "$2" --arg concl "$3" --argjson suite "$4" \
         --arg slug "${5:-gha}" --arg status "${6:-completed}" \
    '{id:$id, name:$name, status:$status,
      conclusion:(if $concl == "null" then null else $concl end),
      completed_at:(if $status == "completed" then "2026-07-21T10:00:0\($id)Z" else null end),
      check_suite:{id:$suite}, app:{slug:$slug, id:1}}'
}
bundle() { printf '{"check_runs":[%s]}' "$(IFS=,; echo "$*")"; }

# --------------------------------------------------------------------------
# 1. The reported bug: superseded failure must not block the gate.
# --------------------------------------------------------------------------
run_gate "$(bundle "$(cr 1 test failure 100)" "$(cr 2 test success 200)")"
check_eq 0 "$(echo "$OUT" | jq -r '.ci_status.failing')" "superseded failure: ci_status.failing == 0"
check_eq 1 "$(echo "$OUT" | jq -r '.ci_status.total')" "superseded failure: only the newest suite's run counted"
check_eq "no" "$(has_ci_failing_entry)" "superseded failure: no 'CI has N failing check-run(s)' entry in missing"

# --------------------------------------------------------------------------
# 2. Negative control — a genuinely failing newest run must still block.
#    Without this, test 1 could pass simply because the gate never emits the entry.
# --------------------------------------------------------------------------
run_gate "$(bundle "$(cr 1 test success 100)" "$(cr 2 test failure 200)")"
check_eq 1 "$(echo "$OUT" | jq -r '.ci_status.failing')" "live failure: ci_status.failing == 1"
check_eq "yes" "$(has_ci_failing_entry)" "live failure: 'CI has N failing check-run(s)' entry present"
check_eq "false" "$(echo "$OUT" | jq -r '.met')" "live failure: gate not met"

# --------------------------------------------------------------------------
# 3. Newest run of a check still running, older run failed -> incomplete, not failing.
# --------------------------------------------------------------------------
run_gate "$(bundle "$(cr 1 test failure 100)" "$(cr 2 test null 200 gha in_progress)")"
check_eq 0 "$(echo "$OUT" | jq -r '.ci_status.failing')" "newest in progress: failing == 0"
check_eq "no" "$(has_ci_failing_entry)" "newest in progress: no failing entry"
check_eq "yes" "$(has_ci_incomplete_entry)" "newest in progress: reported as incomplete instead"

# --------------------------------------------------------------------------
# 4. Matrix legs — a failing leg in the newest suite still blocks.
# --------------------------------------------------------------------------
run_gate "$(bundle "$(cr 1 test failure 100)" "$(cr 2 test success 200)" "$(cr 3 test failure 200)")"
check_eq 1 "$(echo "$OUT" | jq -r '.ci_status.failing')" "matrix legs: failing leg still counted"
check_eq "yes" "$(has_ci_failing_entry)" "matrix legs: failing entry present (not masked by its sibling)"

# --------------------------------------------------------------------------
# 5. CodeAnt supplemental gate reads the same deduped view.
#    Stale CodeAnt success + newer CodeAnt failure on one SHA: the superseded
#    success must NOT count as CodeAnt's clean signal.
# --------------------------------------------------------------------------
run_gate "$(bundle "$(cr 1 "CodeAnt AI" success 100 codeant-ai)" "$(cr 2 "CodeAnt AI" failure 200 codeant-ai)")"
check_eq "yes" "$(has_codeant_no_clean_entry)" \
  "CodeAnt: a superseded successful check-run no longer satisfies the CodeAnt gate"

# Negative control — when the newest CodeAnt run IS successful, the gate is satisfied.
run_gate "$(bundle "$(cr 1 "CodeAnt AI" failure 100 codeant-ai)" "$(cr 2 "CodeAnt AI" success 200 codeant-ai)")"
check_eq "no" "$(has_codeant_no_clean_entry)" \
  "CodeAnt: a current successful check-run still satisfies the CodeAnt gate"
check_eq 0 "$(echo "$OUT" | jq -r '.ci_status.failing')" \
  "CodeAnt: the superseded CodeAnt failure does not block CI either"

# --------------------------------------------------------------------------
# 6. Zero check-runs still reads as incomplete, never as clean.
# --------------------------------------------------------------------------
run_gate '{"check_runs":[]}'
check_eq 0 "$(echo "$OUT" | jq -r '.ci_status.total')" "empty check-run list: total 0"
check_eq "yes" "$(has_ci_incomplete_entry)" "empty check-run list: still reported incomplete"
check_eq "false" "$(echo "$OUT" | jq -r '.met')" "empty check-run list: gate not met"

echo "----------------------------------------"
echo "merge-gate-ci-dedup.test.sh: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
