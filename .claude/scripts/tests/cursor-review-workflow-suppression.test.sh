#!/usr/bin/env bash
# Offline tests for the one-nudge-per-HEAD guard in
# .github/workflows/cursor-review-pr-comment.yml (issue #1356).
#
# WHAT IS UNDER TEST
#   CI used to post `@cursor review` on every push gated only on the PAT, so it
#   re-nudged a HEAD that had already drawn a Cursor usage-limit refusal —
#   observed live on PR #1349 (refusal 17:34:47, CI nudge 17:35:06, second
#   refusal 17:35:18). The workflow now runs the shared
#   `bugbot-refused-head.sh` first and skips the nudge on exit 0.
#
#   The guard only ever NARROWS posting, and is fail-open in every direction:
#   a missing helper, an unreadable API, or a usage error all still post,
#   because bugbot.md calls a duplicate nudge harmless while a wrongly
#   suppressed one costs a whole review.
#
# HOW IT IS OBSERVED
#   The guard's shell body is EXTRACTED FROM THE WORKFLOW by step id and run
#   under the runner's exact default shell (`bash --noprofile --norc -eo
#   pipefail`), against the real bugbot-refused-head.sh and a stub `gh`. Nothing
#   here is a copy of the YAML: renaming the step or editing its `run:` makes
#   these tests error rather than pass against a body that no longer ships.
#   Each scenario asserts the literal $GITHUB_OUTPUT contents, so "did not
#   suppress" is read off the transcript rather than inferred from an absence.
#
#   `set -e` is the live trap here — the runner's shell carries it, so a bare
#   `bash guard.sh` would turn the helper's exit 1 ("post") into a failed step.
#   Scenario (h) is the negative control for that: the same harness run against
#   a bare-call variant of the body must FAIL, proving these rc-0 assertions
#   detect the regression instead of reporting success unconditionally.
#
# WHAT THIS CANNOT PROVE (lands on CI evidence)
#   That Actions wires `steps.suppress-check.outputs.suppressed` into the
#   comment step's `if:`, that the base-SHA checkout lands the helper on the
#   runner, and that GITHUB_TOKEN's scopes cover the helper's three endpoints.
#   Those are asserted below only as YAML wiring, never as behaviour.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
WORKFLOW="$REPO_ROOT/.github/workflows/cursor-review-pr-comment.yml"
TMP="$(mktemp -d)"
TMP_HOME="$(mktemp -d)"
cleanup() { rm -rf "$TMP" "$TMP_HOME"; }
trap cleanup EXIT
# HOME is redirected for the guard run ONLY (run_guard below) — the helper
# appends to $HOME/.claude/script-usage.log and must not touch the real one.
# It is deliberately NOT exported: PyYAML can live in the user site-packages
# (it does on macOS system python3), which a clobbered HOME hides.
mkdir -p "$TMP_HOME/.claude"

# Hard dependency, never a skip: without it the workflow could not be read and
# every assertion below would pass vacuously.
if ! python3 -c "import yaml" 2>/dev/null; then
  echo "FAIL — PyYAML is required to read the workflow (pip3 install --user pyyaml)" >&2
  exit 1
fi

PASS=0
FAIL=0
check_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    PASS=$((PASS + 1)); echo "ok   — $desc"
  else
    FAIL=$((FAIL + 1)); echo "FAIL — $desc (expected '$expected', got '$actual')"
  fi
}
check_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    PASS=$((PASS + 1)); echo "ok   — $desc"
  else
    FAIL=$((FAIL + 1)); echo "FAIL — $desc (no '$needle' in '$haystack')"
  fi
}

PR_NUM="99553"
HEAD_SHA="deadbeef0000000000000000000000000000abcd"
STEP_ID="suppress-check"

# ---- read the workflow, by structure ----------------------------------------
# Every lookup below exits non-zero with a message when the thing it names is
# gone, so a restructure on main surfaces as a hard error here.
wf_query() {
  python3 - "$WORKFLOW" "$@" <<'PY'
import sys, yaml

path, mode = sys.argv[1], sys.argv[2]
with open(path) as fh:
    wf = yaml.safe_load(fh)

job = wf["jobs"]["post-cursor-review"]
steps = job["steps"]


def by_id(step_id):
    for s in steps:
        if s.get("id") == step_id:
            return s
    sys.exit("no step with id %r in post-cursor-review" % step_id)


def posting_step():
    # Anchored on behaviour, not on the step's name: the one step that creates
    # the trigger comment. A rename cannot quietly move this assertion.
    hits = [s for s in steps if "createComment" in str(s.get("with", {}).get("script", ""))]
    if len(hits) != 1:
        sys.exit("expected exactly 1 comment-posting step, found %d" % len(hits))
    return hits[0]


if mode == "step-field":
    step, field = by_id(sys.argv[3]), sys.argv[4]
    if field not in step:
        sys.exit("step %r has no %r" % (sys.argv[3], field))
    print(step[field], end="")
elif mode == "posting-if":
    print(posting_step().get("if", ""), end="")
elif mode == "checkout-ref":
    hits = [s for s in steps if str(s.get("uses", "")).startswith("actions/checkout@")]
    if len(hits) != 1:
        sys.exit("expected exactly 1 checkout step, found %d" % len(hits))
    print(hits[0].get("with", {}).get("ref", ""), end="")
elif mode == "permission":
    print(wf["permissions"].get(sys.argv[3], "<absent>"), end="")
elif mode == "suppressed-warn-if":
    # The annotation step for a suppressed run: github-script, no createComment.
    hits = [
        s.get("if", "")
        for s in steps
        if "github-script" in str(s.get("uses", ""))
        and "outputs.suppressed" in str(s.get("if", ""))
        and "createComment" not in str(s.get("with", {}).get("script", ""))
    ]
    if len(hits) != 1:
        sys.exit("expected exactly 1 suppression-warning step, found %d" % len(hits))
    print(hits[0], end="")
else:
    sys.exit("unknown mode %r" % mode)
PY
}

RUN_BODY="$(wf_query step-field "$STEP_ID" run)" || { echo "FAIL — could not read the guard body: $RUN_BODY"; exit 1; }
RUNFILE="$TMP/guard-step.sh"
printf '%s\n' "$RUN_BODY" > "$RUNFILE"

# ---- workspace: the real helper, laid out as the checkout leaves it ----------
WORK="$TMP/work"
mkdir -p "$WORK/.claude/scripts/lib"
cp "$REPO_ROOT/.claude/scripts/bugbot-refused-head.sh" "$WORK/.claude/scripts/"
# The real normaliser, not a stub: the helper declines to suppress when this
# library will not load, so a missing copy would make every scenario post and
# the suppression cases would fail for a reason unrelated to their subject.
cp "$REPO_ROOT/.claude/scripts/lib/ts-normalizer.sh" "$WORK/.claude/scripts/lib/"

# ---- gh stub ----------------------------------------------------------------
# FIXTURE_COMMENTS_JSON   — issues/{n}/comments payload
# FIXTURE_HEAD_TS         — the HEAD commit's committer date
# FIXTURE_CHECK_RUNS_JSON — commits/{sha}/check-runs payload
# FIXTURE_API_FAIL=1      — every `gh api` call fails (fail-open probe)
STUB_BIN="$TMP/bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/gh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
[[ "${1-}" == "api" ]] || exit 0
shift
if [[ "${FIXTURE_API_FAIL:-0}" == "1" ]]; then exit 1; fi
for arg in "$@"; do
  case "$arg" in
    repos/*/commits/*/check-runs*) cat "$FIXTURE_CHECK_RUNS_JSON"; exit 0 ;;
    repos/*/commits/*)             printf '%s\n' "$FIXTURE_HEAD_TS"; exit 0 ;;
    repos/*/issues/*/comments*)    cat "$FIXTURE_COMMENTS_JSON";  exit 0 ;;
  esac
done
echo "[]"
STUB
chmod +x "$STUB_BIN/gh"

ts_seconds_ago() {
  python3 -c "
from datetime import datetime, timedelta, timezone
print((datetime.now(timezone.utc) - timedelta(seconds=$1)).strftime('%Y-%m-%dT%H:%M:%SZ'))
"
}

refusal() {
  printf '{"user": {"login": "cursor[bot]"}, "created_at": "%s", "body": "<h3>Bugbot couldn'"'"'t run - usage limit reached</h3> this run hit a usage or spend limit."}' "$1"
}
ordinary_cursor_comment() {
  printf '{"user": {"login": "cursor[bot]"}, "created_at": "%s", "body": "Found 1 bug: possible null dereference."}' "$1"
}

OUT="$TMP/github_output"
setup() {
  local head_age="$1" comments_json="$2"
  FIXTURE_HEAD_TS="$(ts_seconds_ago "$head_age")"
  export FIXTURE_HEAD_TS
  printf '%s\n' "$comments_json" > "$TMP/comments.json"
  export FIXTURE_COMMENTS_JSON="$TMP/comments.json"
  export FIXTURE_API_FAIL=0
  # Default: BugBot has a check-run on HEAD, so a post-HEAD refusal is
  # attributable. Scenarios needing the un-attributable case override this.
  printf '%s\n' '{"check_runs":[{"name":"Cursor Bugbot","app":{"slug":"cursor"},"status":"completed","conclusion":"neutral"}]}' > "$TMP/check-runs.json"
  export FIXTURE_CHECK_RUNS_JSON="$TMP/check-runs.json"
  : > "$OUT"
}

# The runner's default shell, verbatim: `set -e` is present and `set -u` is not.
run_guard() {
  local pr="${1-$PR_NUM}" script="${2-$RUNFILE}"
  (
    cd "$WORK" || exit 99
    HOME="$TMP_HOME" GITHUB_OUTPUT="$OUT" GH_REPO="auerbachb/claude-code-config" \
      GH_TOKEN="stub" PR_NUMBER="$pr" HEAD_SHA="$HEAD_SHA" PATH="$STUB_BIN:$PATH" \
      bash --noprofile --norc -eo pipefail "$script" >/dev/null 2>&1
  )
}
emitted() { tr -d '\n' < "$OUT"; }

############################################################################
echo "== (pre): the extracted body is the shipped one =="
check_contains "guard body invokes the shared helper" \
  ".claude/scripts/bugbot-refused-head.sh" "$RUN_BODY"

############################################################################
echo "== (a): refusal POSTDATES the HEAD commit -> suppressed =="
setup 600 "[$(refusal "$(ts_seconds_ago 60)")]"
run_guard; RC=$?
check_eq "step succeeded" "0" "$RC"
check_eq "wrote suppressed=true" "suppressed=true" "$(emitted)"

############################################################################
echo "== (b): refusal PREDATES the HEAD commit -> posts (new push, clean slate) =="
setup 60 "[$(refusal "$(ts_seconds_ago 600)")]"
run_guard; RC=$?
check_eq "step succeeded despite the helper's non-zero verdict" "0" "$RC"
check_eq "wrote suppressed=false" "suppressed=false" "$(emitted)"

############################################################################
echo "== (c): cursor[bot] active but never refused -> posts =="
setup 600 "[$(ordinary_cursor_comment "$(ts_seconds_ago 60)")]"
run_guard; RC=$?
check_eq "step succeeded" "0" "$RC"
check_eq "wrote suppressed=false" "suppressed=false" "$(emitted)"

############################################################################
echo "== (d): refusal with NO BugBot check-run on HEAD -> not attributable, posts =="
# An issue comment carries no SHA, so a timestamp alone cannot attribute the
# refusal to this commit (PR #1203). Only the fixture's check-runs differ from (a).
setup 600 "[$(refusal "$(ts_seconds_ago 60)")]"
printf '%s\n' '{"check_runs":[]}' > "$TMP/check-runs.json"
run_guard; RC=$?
check_eq "step succeeded" "0" "$RC"
check_eq "wrote suppressed=false" "suppressed=false" "$(emitted)"

############################################################################
echo "== (e): FAILS OPEN — gh api unreadable -> posts anyway =="
# The (a) fixture, which would suppress if it could be read, so the API failure
# is the only difference. Green here proves the fail-open direction rather than
# proving the fixture was never a refusal.
setup 600 "[$(refusal "$(ts_seconds_ago 60)")]"
export FIXTURE_API_FAIL=1
run_guard; RC=$?
check_eq "step succeeded" "0" "$RC"
check_eq "wrote suppressed=false despite the unreadable API" "suppressed=false" "$(emitted)"

############################################################################
echo "== (f): FAILS OPEN — helper exits 2 (usage error) -> posts =="
# Exit 2 is the helper's dependency/usage channel, distinct from its exit-1
# verdict; an empty PR number reaches it without touching PATH.
setup 600 "[$(refusal "$(ts_seconds_ago 60)")]"
run_guard ""; RC=$?
check_eq "step succeeded on the helper's exit 2" "0" "$RC"
check_eq "wrote suppressed=false" "suppressed=false" "$(emitted)"

############################################################################
echo "== (g): BOOTSTRAP — helper absent from the base branch -> posts =="
# A repo given this workflow without .claude/scripts, or the PR introducing the
# helper. Behaviour must match the pre-guard workflow exactly.
setup 600 "[$(refusal "$(ts_seconds_ago 60)")]"
mv "$WORK/.claude/scripts/bugbot-refused-head.sh" "$TMP/helper.bak"
run_guard; RC=$?
mv "$TMP/helper.bak" "$WORK/.claude/scripts/bugbot-refused-head.sh"
check_eq "step succeeded" "0" "$RC"
check_eq "wrote suppressed=false" "suppressed=false" "$(emitted)"

############################################################################
echo "== (h): NEGATIVE CONTROL — a bare call would fail the step under set -e =="
# Without this, every rc-0 assertion above could be a harness that never fails.
# Same body with the `if` stripped to a bare invocation: the helper's exit 1 must
# take the step down, proving those rc-0 results are the `if` construct working.
BARE="$TMP/guard-step-bare.sh"
cat > "$BARE" <<'BARE_BODY'
GUARD=.claude/scripts/bugbot-refused-head.sh
bash "$GUARD" "$PR_NUMBER" "$HEAD_SHA"
echo "suppressed=false" >> "$GITHUB_OUTPUT"
BARE_BODY
setup 60 "[$(refusal "$(ts_seconds_ago 600)")]"
run_guard "$PR_NUM" "$BARE"; RC=$?
check_eq "bare call fails the step (harness can detect the regression)" "1" "$RC"
check_eq "and never reaches its output write" "" "$(emitted)"

############################################################################
echo "== (i): YAML wiring — the guard is actually consulted =="
# Behaviour of these lines lands on CI evidence; the wiring is checkable here.
POSTING_IF="$(wf_query posting-if)" || { echo "FAIL — $POSTING_IF"; exit 1; }
check_contains "comment step consults the guard output" \
  "steps.$STEP_ID.outputs.suppressed != 'true'" "$POSTING_IF"
check_contains "comment step keeps the existing PAT gate" \
  "env.HAS_TRIGGER_TOKEN == 'true'" "$POSTING_IF"

WARN_IF="$(wf_query suppressed-warn-if)" || { echo "FAIL — $WARN_IF"; exit 1; }
check_contains "a suppressed run still emits an annotation" \
  "steps.$STEP_ID.outputs.suppressed == 'true'" "$WARN_IF"

check_eq "guard step never fails the job" "True" "$(wf_query step-field "$STEP_ID" continue-on-error)"
check_eq "guard step is gated on the PAT" "env.HAS_TRIGGER_TOKEN == 'true'" \
  "$(wf_query step-field "$STEP_ID" if)"
check_eq "helper is checked out from the base branch, not the PR" \
  "\${{ github.event.pull_request.base.sha }}" "$(wf_query checkout-ref)"

for scope in contents issues pull-requests checks; do
  check_eq "permissions grant $scope: read" "read" "$(wf_query permission "$scope")"
done

echo
echo "== summary: $PASS passed, $FAIL failed =="
[[ "$FAIL" -eq 0 ]] || exit 1
echo "OK: cursor-review-pr-comment.yml BugBot suppression guard tests passed"
