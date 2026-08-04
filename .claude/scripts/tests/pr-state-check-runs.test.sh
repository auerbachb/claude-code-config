#!/usr/bin/env bash
# Unit test for the canonical `pr-state-cr-split.jq` projection invoked by
# `pr-state.sh`
# (issue #956).
#
# What it pins:
#   1. Publishing-app identity survives the projection on ALL THREE arrays
#      (`check_runs.all`, `.failing_runs`, `.in_progress_runs`). The raw
#      check-run objects carry `.app.slug`/`.app.id`, and check-runs-dedup.sh one
#      step earlier already groups by [.app.slug, .app.id, .name] — the identity
#      was fetched, used, then dropped by this projection, leaving reviewer
#      routing to match check NAMES that any GitHub App may publish.
#   2. Two runs sharing a name but published by different apps stay
#      distinguishable after projection — the motivating case.
#   3. Absent app data projects as {slug: null, id: null} rather than vanishing,
#      so a consumer can tell "no identity" from "identity says not me".
#   4. Backward compatibility: every field the pre-#956 projection emitted is
#      still emitted, unrenamed and unchanged. Asserted as exact key sets plus
#      per-field values, so a dropped or renamed field fails here rather than in
#      a downstream consumer.
#
# Strategy (same as pr-state-classify.test.sh): execute the canonical jq file
# used by pr-state.sh, so the test cannot drift from production behavior.
#
# Requires: jq, bash 3.2+ (macOS-compatible). Offline: no gh, git, or network.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$TEST_DIR/../pr-state.sh"
FILTER="$TEST_DIR/../lib/pr-state-cr-split.jq"

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

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

# ---- canonical production projection --------------------------------------
FILTER_OK="yes"
[[ -r "$FILTER" ]] || FILTER_OK="not readable"
if [[ "$FILTER_OK" == "yes" ]] && ! jq -e -f "$FILTER" <<<'[]' >/dev/null 2>&1; then
  FILTER_OK="invalid jq"
fi
check_eq "canonical CR_SPLIT projection is readable jq" "yes" "$FILTER_OK"
if [[ "$FILTER_OK" != "yes" ]]; then
  echo "== summary: $PASS passed, $FAIL failed ==" >&2
  exit 1
fi

# Run the real projection over a raw check-run array, then apply the assertion
# filter to its output.
project() {
  # $1 = raw check-runs JSON array, $2 = jq filter over the projection output
  jq -c -f "$FILTER" <<<"$1" | jq -c "$2"
}

# ---- fixtures ---------------------------------------------------------------
# Shaped like real GitHub check-run objects post-dedup. Two entries deliberately
# share the name "Cursor Bugbot": one from Cursor (app slug `cursor`, app id
# 1210556 — confirmed live on this repo), one from another app publishing under
# the identical name. That pair is the whole point of issue #956.
RUNS='[
  {"id": 11, "name": "Cursor Bugbot", "status": "completed", "conclusion": "success",
   "output": {"title": "No issues"}, "details_url": "https://example/1", "html_url": "https://example/h1",
   "app": {"slug": "cursor", "id": 1210556, "name": "Cursor"}},
  {"id": 12, "name": "Cursor Bugbot", "status": "completed", "conclusion": "success",
   "output": {"title": "impostor"}, "details_url": "https://example/2", "html_url": "https://example/h2",
   "app": {"slug": "github-actions", "id": 15368, "name": "GitHub Actions"}},
  {"id": 13, "name": "rule-lint", "status": "completed", "conclusion": "failure",
   "output": {"title": "budget exceeded"}, "details_url": "https://example/3", "html_url": "https://example/h3",
   "app": {"slug": "github-actions", "id": 15368, "name": "GitHub Actions"}},
  {"id": 14, "name": "CodeRabbit", "status": "in_progress", "conclusion": null,
   "output": {"title": null}, "details_url": "https://example/4", "html_url": "https://example/h4",
   "app": {"slug": "coderabbitai", "id": 173846, "name": "CodeRabbit"}}
]'

# The same four runs with the app object stripped entirely — a bundle produced
# before the projection carried identity, or an API response missing it.
RUNS_NO_APP="$(jq -c 'map(del(.app))' <<<"$RUNS")"

############################################################################
echo "== app identity survives the projection on all three arrays =="
check_eq "all[] carry app slugs in input order" \
  '["cursor","github-actions","github-actions","coderabbitai"]' \
  "$(project "$RUNS" '[.all[].app.slug]')"
check_eq "all[] carry numeric app ids" \
  '[1210556,15368,15368,173846]' \
  "$(project "$RUNS" '[.all[].app.id]')"
check_eq "failing_runs[] carry the publishing app" \
  '[{"name":"rule-lint","slug":"github-actions","id":15368}]' \
  "$(project "$RUNS" '[.failing_runs[] | {name, slug: .app.slug, id: .app.id}]')"
check_eq "in_progress_runs[] carry the publishing app" \
  '[{"name":"CodeRabbit","slug":"coderabbitai","id":173846}]' \
  "$(project "$RUNS" '[.in_progress_runs[] | {name, slug: .app.slug, id: .app.id}]')"

############################################################################
echo
echo "== two apps publishing the SAME check name stay distinguishable (issue #956) =="
# Pre-#956 both entries projected to an identical {id, name, status, conclusion,
# title} shape modulo id, and every consumer matching on `.name` counted the
# impostor as Cursor. A consumer can now filter on the publisher.
check_eq "only the Cursor-published run matches name + slug" \
  '[11]' \
  "$(project "$RUNS" '[.all[] | select(.name == "Cursor Bugbot" and .app.slug == "cursor") | .id]')"
check_eq "the same-named foreign run is still present, just attributable" \
  '[12]' \
  "$(project "$RUNS" '[.all[] | select(.name == "Cursor Bugbot" and .app.slug != "cursor") | .id]')"

############################################################################
echo
echo "== absent app data projects as {slug: null, id: null} =="
# Not dropped and not an error: consumers get a readable "identity unknown" and
# decide for themselves whether that fails open or closed.
check_eq "all[] app is a null-valued object, not a missing key" \
  '[{"slug":null,"id":null},{"slug":null,"id":null},{"slug":null,"id":null},{"slug":null,"id":null}]' \
  "$(project "$RUNS_NO_APP" '[.all[].app]')"
check_eq "failing_runs[] app is a null-valued object" \
  '[{"slug":null,"id":null}]' \
  "$(project "$RUNS_NO_APP" '[.failing_runs[].app]')"
check_eq "in_progress_runs[] app is a null-valued object" \
  '[{"slug":null,"id":null}]' \
  "$(project "$RUNS_NO_APP" '[.in_progress_runs[].app]')"
check_eq "app key is present even when identity is unknown" \
  'true' \
  "$(project "$RUNS_NO_APP" '.all | all(has("app"))')"

############################################################################
echo
echo "== backward compatibility: the change is purely additive =="
# Exact key sets (jq `keys` sorts), so a dropped or renamed pre-#956 field fails
# here instead of surfacing as a downstream consumer reading null.
check_eq "all[] key set = pre-#956 keys + app" \
  '["app","conclusion","id","name","status","title"]' \
  "$(project "$RUNS" '.all[0] | keys')"
check_eq "failing_runs[] key set = pre-#956 keys + app" \
  '["app","conclusion","details_url","html_url","id","name","title"]' \
  "$(project "$RUNS" '.failing_runs[0] | keys')"
check_eq "in_progress_runs[] key set = pre-#956 keys + app" \
  '["app","id","name","status"]' \
  "$(project "$RUNS" '.in_progress_runs[0] | keys')"
check_eq "all[] pre-existing field values unchanged" \
  '{"id":11,"name":"Cursor Bugbot","status":"completed","conclusion":"success","title":"No issues"}' \
  "$(project "$RUNS" '.all[0] | del(.app)')"
check_eq "failing_runs[] pre-existing field values unchanged" \
  '{"id":13,"name":"rule-lint","conclusion":"failure","title":"budget exceeded","details_url":"https://example/3","html_url":"https://example/h3"}' \
  "$(project "$RUNS" '.failing_runs[0] | del(.app)')"
check_eq "in_progress_runs[] pre-existing field values unchanged" \
  '{"id":14,"name":"CodeRabbit","status":"in_progress"}' \
  "$(project "$RUNS" '.in_progress_runs[0] | del(.app)')"
check_eq "counts unchanged (total/passing/failing/in_progress)" \
  '{"total":4,"passing":2,"failing":1,"in_progress":1}' \
  "$(project "$RUNS" '{total, passing, failing, in_progress}')"
check_eq "top-level bundle key set unchanged" \
  '["all","failing","failing_runs","in_progress","in_progress_runs","passing","total"]' \
  "$(project "$RUNS" 'keys')"

############################################################################
echo
echo "== missing canonical filters fail on the existing operational-error code =="
mkdir -p "$TMP/partial-deploy"
cp "$SCRIPT" "$TMP/partial-deploy/pr-state.sh"
chmod +x "$TMP/partial-deploy/pr-state.sh"
"$TMP/partial-deploy/pr-state.sh" --pr 1 >"$TMP/missing.out" 2>"$TMP/missing.err"
missing_rc=$?
check_eq "partial deployment exits with existing runtime code 5" "5" "$missing_rc"
missing_message="no"
grep -q 'required pr-state jq filter not readable:' "$TMP/missing.err" && missing_message="yes"
check_eq "partial deployment reports the missing jq filter" "yes" "$missing_message"

mkdir -p "$TMP/empty-home/.claude"
HOME="$TMP/empty-home" "$TMP/partial-deploy/pr-state.sh" --help >/dev/null 2>&1
check_eq "--help does not require full-snapshot filters" "0" "$?"
HOME="$TMP/empty-home" "$TMP/partial-deploy/pr-state.sh" --infer-candidates >"$TMP/infer.out" 2>"$TMP/infer.err"
check_eq "--infer-candidates does not require full-snapshot filters" "0" "$?"
check_eq "--infer-candidates keeps its missing-state output" "[]" "$(cat "$TMP/infer.out")"
printf '%s\n' '{"pr":{"head_sha":"abc"},"comments":{"reviews":[],"inline":[],"conversation":[]},"check_runs":{"all":[]},"bot_statuses":{},"new_since_baseline":{"finding_count":0}}' >"$TMP/wait-bundle.json"
HOME="$TMP/empty-home" "$TMP/partial-deploy/pr-state.sh" --wait-state-eval abc "$TMP/wait-bundle.json" >"$TMP/wait.out" 2>"$TMP/wait.err"
check_eq "--wait-state-eval does not require full-snapshot filters" "0" "$?"
check_eq "--wait-state-eval output remains unchanged" \
  '{"head_moved":false,"bots_pending":[],"ci_pending":[],"ci_failing":[],"new_findings":0}' \
  "$(cat "$TMP/wait.out")"

echo
echo "== summary: $PASS passed, $FAIL failed =="
[[ "$FAIL" -eq 0 ]] || exit 1
echo "OK: pr-state.sh check-run projection tests passed"
