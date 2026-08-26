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
#   The `gh` stub is keyed to the PR number and SHA the body must forward, and
#   logs what it served, so the arguments deciding WHICH commit is judged are
#   asserted positively rather than assumed.
#
#   Step conditions are EVALUATED, not string-matched: `A && B` and `A || B`
#   contain the same substrings but only one of them suppresses, so scenario (i)
#   reads a truth table off the shipped condition.
#
#   `set -e` is the live trap here — the runner's shell carries it, so a bare
#   `bash guard.sh` would turn the helper's exit 1 ("post") into a failed step.
#   Two negative controls keep the green from being unconditional: (h) runs a
#   bare-call variant of the body, which must FAIL; (j) feeds the body a SHA the
#   harness never vouched for, which the stub must catch.
#
# WHICH HELPER IS UNDER TEST
#   The scenarios run against the WORKING TREE's bugbot-refused-head.sh, while
#   production runs the BASE branch's (the workflow pins `base.sha`). Those are
#   the same file on any PR that does not edit the helper, and scenario (k)
#   covers the case where they diverge by proving the body against the exit-code
#   contract rather than one implementation.
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

# Hard dependencies, never a skip. Without PyYAML the workflow could not be read
# and every assertion below would pass vacuously. Without `jq` the real helper
# exits 2 at its own dependency preflight, so every scenario would take the
# fail-open path and the suppression cases would fail for the environment rather
# than for the guard — an unactionable error unless it is named here (CodeAnt,
# PR #1377). `gh` is deliberately absent from this list: the stub below supplies
# it, and a real one on PATH must never be reached.
if ! python3 -c "import yaml" 2>/dev/null; then
  echo "FAIL — PyYAML is required to read the workflow (pip3 install --user pyyaml)" >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "FAIL — jq is required: bugbot-refused-head.sh preflights it and exits 2 without it" >&2
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
GH_REPO_FIXTURE="auerbachb/claude-code-config"
STEP_ID="suppress-check"

# ---- read the workflow, by structure ----------------------------------------
# Every lookup below exits non-zero with a message when the thing it names is
# gone, so a restructure on main surfaces as a hard error here.
wf_query() {
  python3 - "$WORKFLOW" "$@" <<'PY'
import re
import sys
import yaml

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
elif mode == "step-env":
    # The harness injects GH_REPO/GH_TOKEN/PR_NUMBER/HEAD_SHA from outside the
    # extracted body, so a workflow that dropped or misnamed one of them would
    # still pass every scenario (CodeAnt, PR #1377). Only the YAML can answer
    # whether the real step declares them, so assert them here.
    step, key = by_id(sys.argv[3]), sys.argv[4]
    env = step.get("env") or {}
    if key not in env:
        sys.exit("step %r declares no env %r (has: %s)"
                 % (sys.argv[3], key, ", ".join(sorted(env)) or "<none>"))
    print(env[key], end="")
elif mode == "posting-if":
    print(posting_step().get("if", ""), end="")
elif mode == "checkout-ref":
    hits = [s for s in steps if str(s.get("uses", "")).startswith("actions/checkout@")]
    if len(hits) != 1:
        sys.exit("expected exactly 1 checkout step, found %d" % len(hits))
    print(hits[0].get("with", {}).get("ref", ""), end="")
elif mode == "permission":
    print(wf["permissions"].get(sys.argv[3], "<absent>"), end="")
elif mode == "if-truth-table":
    # Substring assertions cannot tell `A && B` from `A || B`, so a regression to
    # OR would leave a suppressed run free to post while every check still passed
    # (CodeAnt, PR #1377). This evaluates the condition instead of reading it.
    #
    # Each atom is replaced by exact text and every LEFTOVER token is then
    # rejected, so an added, renamed, or retyped clause errors here rather than
    # being quietly evaluated away. That token allow-list is also what makes the
    # eval below safe: nothing but these names and boolean operators survives it.
    targets = {"posting": posting_step, "warn": lambda: by_id("suppressed-warn")}
    if sys.argv[3] not in targets:
        sys.exit("unknown truth-table target %r" % sys.argv[3])
    cond = targets[sys.argv[3]]().get("if", "")

    atoms = [
        ("env.HAS_TRIGGER_TOKEN == 'true'", "TOKEN"),
        ("steps.suppress-check.outputs.suppressed != 'true'", "NOT_SUPPRESSED"),
        ("steps.suppress-check.outputs.suppressed == 'true'", "SUPPRESSED"),
    ]
    expr = " ".join(cond.split())
    for literal, name in atoms:
        expr = expr.replace(literal, name)
    expr = expr.replace("&&", " and ").replace("||", " or ").replace("!", " not ")

    allowed = {"TOKEN", "NOT_SUPPRESSED", "SUPPRESSED", "and", "or", "not", "(", ")"}
    unknown = [
        t for t in re.findall(r"[A-Za-z_][A-Za-z_0-9]*|\S", expr) if t not in allowed
    ]
    if unknown:
        sys.exit("unrecognized token(s) in the %r condition: %r (from %r)"
                 % (sys.argv[3], unknown, cond))

    # SUPPRESSED and NOT_SUPPRESSED read the same step output, so they are one
    # input with two spellings — never two independent variables.
    rows = []
    for token in (True, False):
        for suppressed in (True, False):
            fired = eval(expr, {"__builtins__": {}}, {
                "TOKEN": token,
                "SUPPRESSED": suppressed,
                "NOT_SUPPRESSED": not suppressed,
            })
            rows.append("token=%d,suppressed=%d:%d" % (token, suppressed, bool(fired)))
    print(" ".join(rows), end="")
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
# EXPECT_SHA / EXPECT_PR  — the values the guard body is supposed to forward
# STUB_ERR / STUB_CALLS   — mismatch log / served-URL log
#
# The stub is KEYED to the PR number and SHA rather than serving any commit or
# issue URL it is handed. A body that forwarded the base SHA, a stale HEAD, or
# the wrong PR — the arguments that decide which refusal and which commit get
# evaluated — would otherwise still be served the suppressing fixture and pass
# (CodeAnt, PR #1377). Every served URL is logged too, so a scenario can prove
# the call HAPPENED instead of reading an empty mismatch log as success.
STUB_BIN="$TMP/bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/gh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
[[ "${1-}" == "api" ]] || exit 0
shift
if [[ "${FIXTURE_API_FAIL:-0}" == "1" ]]; then exit 1; fi
# A mismatch is recorded AND fails the call: the helper then fails open, so the
# scenario's own assertion moves too rather than the log being the only witness.
bad() { printf '%s\n' "$1" >> "$STUB_ERR"; exit 1; }
served() { printf '%s\n' "$1" >> "$STUB_CALLS"; }
# The real gh resolves {owner}/{repo} from GH_REPO and authenticates with
# GH_TOKEN, so a body that unset or overrode either would fail open in
# production while this stub happily answered. Refuse to answer without them.
[[ "${GH_REPO:-}" == "$EXPECT_REPO" ]] || bad "GH_REPO '${GH_REPO:-}' != expected '$EXPECT_REPO'"
[[ -n "${GH_TOKEN:-}" ]] || bad "GH_TOKEN is empty — the real gh would be unauthenticated"
PAGINATE=0
for arg in "$@"; do [[ "$arg" == "--paginate" ]] && PAGINATE=1; done
for arg in "$@"; do
  case "$arg" in
    repos/*/commits/*/check-runs*)
      got="${arg#*/commits/}"; got="${got%%/check-runs*}"
      [[ "$got" == "$EXPECT_SHA" ]] || bad "check-runs sha '$got' != expected '$EXPECT_SHA'"
      served "check-runs:$got"
      cat "$FIXTURE_CHECK_RUNS_JSON"; exit 0 ;;
    repos/*/commits/*)
      got="${arg#*/commits/}"; got="${got%%\?*}"
      [[ "$got" == "$EXPECT_SHA" ]] || bad "commit sha '$got' != expected '$EXPECT_SHA'"
      served "commit:$got"
      printf '%s\n' "$FIXTURE_HEAD_TS"; exit 0 ;;
    repos/*/issues/*/comments*)
      got="${arg#*/issues/}"; got="${got%%/comments*}"
      [[ "$got" == "$EXPECT_PR" ]] || bad "comments pr '$got' != expected '$EXPECT_PR'"
      # Explicit test, not ${PAGINATE:+…}: PAGINATE is "0" when the flag is
      # absent, and "0" is non-empty, so :+ would tag every call as paginated.
      if [[ "$PAGINATE" == "1" ]]; then served "comments:$got:paginate"; else served "comments:$got"; fi
      # Faithful --paginate emulation (CodeAnt, PR #1377). Real gh emits ONE
      # JSON array PER PAGE, concatenated; the helper merges them with
      # `jq -s 'add // []'`. Page 1 carries only a decoy and the refusal lives
      # on page 2, so dropping --paginate (or slurping to anything but `add`)
      # loses the refusal and the suppression scenarios go red rather than
      # being handed the whole fixture regardless of the flags.
      cat "$FIXTURE_COMMENTS_PAGE1"
      [[ "$PAGINATE" == "1" ]] && cat "$FIXTURE_COMMENTS_JSON"
      exit 0 ;;
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
STUB_ERR="$TMP/stub-mismatches"
STUB_CALLS="$TMP/stub-calls"
export STUB_ERR STUB_CALLS
setup() {
  local head_age="$1" comments_json="$2"
  FIXTURE_HEAD_TS="$(ts_seconds_ago "$head_age")"
  export FIXTURE_HEAD_TS
  printf '%s\n' "$comments_json" > "$TMP/comments.json"
  export FIXTURE_COMMENTS_JSON="$TMP/comments.json"
  # Page 1 of the paginated comments response: a non-refusal decoy, so merging
  # must CONCATENATE the pages rather than keep either one alone.
  printf '%s\n' '[{"user": {"login": "auerbachb"}, "created_at": "2020-01-01T00:00:00Z", "body": "page-one decoy, not a refusal"}]' > "$TMP/comments-page1.json"
  export FIXTURE_COMMENTS_PAGE1="$TMP/comments-page1.json"
  export FIXTURE_API_FAIL=0
  # Default: BugBot has a check-run on HEAD, so a post-HEAD refusal is
  # attributable. Scenarios needing the un-attributable case override this.
  printf '%s\n' '{"check_runs":[{"name":"Cursor Bugbot","app":{"slug":"cursor"},"status":"completed","conclusion":"neutral"}]}' > "$TMP/check-runs.json"
  export FIXTURE_CHECK_RUNS_JSON="$TMP/check-runs.json"
  # What the guard body is expected to forward — never what it actually sent.
  export EXPECT_SHA="$HEAD_SHA" EXPECT_PR="$PR_NUM" EXPECT_REPO="$GH_REPO_FIXTURE"
  : > "$OUT"; : > "$STUB_ERR"; : > "$STUB_CALLS"
}

# The runner's default shell, verbatim: `set -e` is present and `set -u` is not.
# GUARD_HEAD_SHA overrides only what reaches the body's env, leaving EXPECT_SHA
# on the true HEAD — that gap is what scenario (j) drives the stub's check with.
run_guard() {
  local pr="${1-$PR_NUM}" script="${2-$RUNFILE}"
  (
    cd "$WORK" || exit 99
    HOME="$TMP_HOME" GITHUB_OUTPUT="$OUT" GH_REPO="$GH_REPO_FIXTURE" \
      GH_TOKEN="stub" PR_NUMBER="$pr" HEAD_SHA="${GUARD_HEAD_SHA:-$HEAD_SHA}" \
      PATH="$STUB_BIN:$PATH" \
      bash --noprofile --norc -eo pipefail "$script" >/dev/null 2>&1
  )
}
emitted() { tr -d '\n' < "$OUT"; }
served_urls() { LC_ALL=C sort "$STUB_CALLS" | tr '\n' ' '; }
mismatches() { tr '\n' ';' < "$STUB_ERR"; }

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
# Argument wiring, positively: the body forwarded PR_NUMBER and HEAD_SHA — in
# that order — to all three endpoints the helper reads. Asserting the served
# URLs rather than an empty mismatch log keeps "never called" from reading as
# "called correctly".
check_eq "guard forwarded the PR number and HEAD SHA to every endpoint, comments paginated" \
  "check-runs:$HEAD_SHA comments:$PR_NUM:paginate commit:$HEAD_SHA " "$(served_urls)"
check_eq "no argument mismatches" "" "$(mismatches)"

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
echo "== (j): NEGATIVE CONTROL — a wrong SHA is caught, and cannot suppress =="
# Pairs with (a)'s wiring assertion: without this, an argument check that never
# fires would look identical to one that passes. The (a) fixture verbatim, with
# only the SHA the body receives changed — as a base-SHA or stale-HEAD mix-up
# would change it — so the fixture would still suppress if it were served.
setup 600 "[$(refusal "$(ts_seconds_ago 60)")]"
GUARD_HEAD_SHA="0000000000000000000000000000000000000000" run_guard; RC=$?
check_eq "step still succeeded (fail-open)" "0" "$RC"
check_contains "stub recorded the SHA mismatch" \
  "!= expected '$HEAD_SHA'" "$(mismatches)"
check_eq "a SHA the harness never vouched for cannot suppress" \
  "suppressed=false" "$(emitted)"

############################################################################
echo "== (k): the body honours the EXIT-CODE CONTRACT, whichever helper ships =="
# Production runs the BASE-branch helper (the checkout pins base.sha) while this
# harness copies the working tree's, so a PR that edited the helper would be
# proving something about code CI does not run (CodeAnt, PR #1377). Loading the
# base revision instead would not fix it — CI checks out shallow, so the lookup
# would fail there and a fallback would pass vacuously, which is the failure
# mode this file exists to avoid.
#
# So the gap is closed from the other side: the body is proven to map every
# documented exit code correctly, which holds for ANY conforming helper version.
# Conformance itself is enforced by the helper's own suite
# (maybe-trigger-bugbot-suppression.test.sh), so base and PR copies are
# interchangeable here as far as this body is concerned.
CONTRACT="$WORK/.claude/scripts/bugbot-refused-head.sh"
cp "$CONTRACT" "$TMP/helper.real"
for spec in "0:suppressed=true" "1:suppressed=false" "2:suppressed=false"; do
  code="${spec%%:*}"; want="${spec#*:}"
  setup 600 "[]"
  printf '#!/usr/bin/env bash\nexit %s\n' "$code" > "$CONTRACT"
  run_guard; RC=$?
  check_eq "helper exit $code keeps the step green" "0" "$RC"
  check_eq "helper exit $code -> $want" "$want" "$(emitted)"
done
cp "$TMP/helper.real" "$CONTRACT"

############################################################################
echo "== (l): PREMISE — the helper under test is the one production will run =="
# Scenarios (a)-(j) copy the WORKING TREE's helper, while production checks out
# base.sha. Where the base revision is reachable, prove the two match, so a PR
# that edits the helper gets a LOUD failure here saying those scenarios no
# longer describe what CI runs and only (k)'s contract coverage carries — the
# same loud-on-drift standard this file already applies to the workflow body.
# Where the base is unreachable (CI checks out shallow) this reports UNVERIFIED
# instead of passing quietly; the suite never claimed to test the base copy, so
# every other assertion stands either way (CodeAnt, PR #1377).
BASE_REF=""
for cand in origin/main main; do
  if git rev-parse --verify --quiet "$cand^{commit}" >/dev/null 2>&1; then BASE_REF="$cand"; break; fi
done
if [[ -z "$BASE_REF" ]]; then
  echo "UNVERIFIED — no base revision reachable here; (k) carries the helper contract"
else
  for f in .claude/scripts/bugbot-refused-head.sh .claude/scripts/lib/ts-normalizer.sh; do
    base_hash="$(git rev-parse --verify --quiet "$BASE_REF:$f" 2>/dev/null || echo "absent-on-base")"
    check_eq "$(basename "$f") is identical to $BASE_REF (else update this suite: CI runs the base copy)" \
      "$base_hash" "$(git hash-object "$REPO_ROOT/$f")"
  done
fi

############################################################################
echo "== (i): YAML wiring — the guard is actually consulted =="
# Behaviour of these lines lands on CI evidence; the wiring is checkable here.
POSTING_IF="$(wf_query posting-if)" || { echo "FAIL — $POSTING_IF"; exit 1; }
check_contains "comment step consults the guard output" \
  "steps.$STEP_ID.outputs.suppressed != 'true'" "$POSTING_IF"
check_contains "comment step keeps the existing PAT gate" \
  "env.HAS_TRIGGER_TOKEN == 'true'" "$POSTING_IF"

# Both clauses being PRESENT does not make them CONJOINED — `||` reads identical
# to the two checks above while letting a suppressed run post. The tables below
# are evaluated from the shipped condition, so only a real AND satisfies them.
POSTING_TABLE="$(wf_query if-truth-table posting)" || { echo "FAIL — $POSTING_TABLE"; exit 1; }
check_eq "comment posts ONLY with the PAT and no suppression (a real AND, not OR)" \
  "token=1,suppressed=1:0 token=1,suppressed=0:1 token=0,suppressed=1:0 token=0,suppressed=0:0" \
  "$POSTING_TABLE"

# Selected by step id, so removing or renaming the annotation step errors here
# instead of matching some other github-script step that mentions the output.
WARN_IF="$(wf_query step-field suppressed-warn if)" || { echo "FAIL — $WARN_IF"; exit 1; }
check_contains "a suppressed run still emits an annotation" \
  "steps.$STEP_ID.outputs.suppressed == 'true'" "$WARN_IF"
WARN_TABLE="$(wf_query if-truth-table warn)" || { echo "FAIL — $WARN_TABLE"; exit 1; }
check_eq "the annotation fires ONLY on a suppressed run that had the PAT" \
  "token=1,suppressed=1:1 token=1,suppressed=0:0 token=0,suppressed=1:0 token=0,suppressed=0:0" \
  "$WARN_TABLE"

# The four values the body reads. run_guard supplies them from outside the
# extracted script, so only these assertions can catch a step that stopped
# declaring one — the scenarios never would.
check_eq "step passes the repository to the helper" "\${{ github.repository }}" \
  "$(wf_query step-env "$STEP_ID" GH_REPO)"
check_eq "step passes a token to the helper" "\${{ github.token }}" \
  "$(wf_query step-env "$STEP_ID" GH_TOKEN)"
check_eq "step passes THIS PR's number" "\${{ github.event.pull_request.number }}" \
  "$(wf_query step-env "$STEP_ID" PR_NUMBER)"
check_eq "step passes the PR's HEAD sha, not the base sha" \
  "\${{ github.event.pull_request.head.sha }}" "$(wf_query step-env "$STEP_ID" HEAD_SHA)"

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
