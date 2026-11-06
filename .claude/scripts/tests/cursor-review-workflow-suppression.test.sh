#!/usr/bin/env bash
# Offline structural tests: the per-push BugBot nudge workflow never posts.
# catalog: tests — Asserts `.github/workflows/cursor-review-pr-comment.yml` can never post `@cursor review` (issue #1897)
#
# WHAT IS UNDER TEST
#   .github/workflows/cursor-review-pr-comment.yml used to post `@cursor review`
#   after every push (issues #892, #1356, #1728, #1749). BugBot bills per
#   review, and the owner's policy is that no paid AI review starts without
#   the owner's explicit approval in chat (issue #1897) — which a workflow can
#   never carry. The workflow now keeps only its trigger and job name (so a
#   required check keyed on the job still reports) and one notice step.
#
# HOW IT IS OBSERVED
#   The YAML is PARSED (PyYAML), not grepped, and every step is inspected: no
#   step may call the comments API, mention `@cursor review` outside a notice,
#   use github-script (the only way the old step posted), reference a secret,
#   or read a step output / input that could switch posting back on. A control
#   runs the same checks against a synthetic posting workflow and must FAIL, so
#   the green here is not unconditional.
#
# WHAT THIS CANNOT PROVE (lands on CI evidence)
#   That GitHub runs the job as written. The manual check — push to a test PR
#   and confirm no `@cursor review` comment appears — is recorded in the PR body.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
WORKFLOW="$REPO_ROOT/.github/workflows/cursor-review-pr-comment.yml"
TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# Hard dependency, never a skip: without PyYAML every assertion would pass
# vacuously (issue #1392; hook-scripts.yml installs it on CI).
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

# Prints one line per violation; empty output = the workflow cannot post.
cat > "$TMP/inspect.py" <<'PY'
import json, re, sys, yaml

doc = yaml.safe_load(open(sys.argv[1]))
mode = sys.argv[2]
on = doc.get("on", doc.get(True))  # PyYAML reads a bare `on:` key as True
jobs = doc.get("jobs") or {}
if mode == "shape":
    print(json.dumps({
        "name": doc.get("name"),
        "pull_request": sorted((on or {}).get("pull_request", {}).get("types", [])),
        "jobs": sorted(jobs),
        "steps": sum(len(j.get("steps") or []) for j in jobs.values()),
    }, sort_keys=True))
    sys.exit(0)

def norm(v):  # stringify keys (the bare `on:` key parses as True)
    if isinstance(v, dict):
        return {str(k): norm(x) for k, x in v.items()}
    if isinstance(v, list):
        return [norm(x) for x in v]
    return v

def text(v):
    return json.dumps(norm(v), sort_keys=True)

violations = []
whole = text(doc)
if "secrets." in whole:
    violations.append("references a secret")
if "CURSOR_REVIEW_PAT" in whole:
    violations.append("references CURSOR_REVIEW_PAT")
events = norm(on) if isinstance(on, dict) else {e: None for e in ([on] if isinstance(on, str) else (on or []))}
if "workflow_dispatch" in events or "workflow_call" in events or any(
        isinstance(cfg, dict) and "inputs" in cfg for cfg in events.values()):
    violations.append("accepts inputs that could enable a post")
perms = doc.get("permissions")
if perms not in ({}, None) and any(v == "write" for v in (perms or {}).values()):
    violations.append("grants a write permission")
for jname, job in jobs.items():
    jp = job.get("permissions")
    if isinstance(jp, dict) and any(v == "write" for v in jp.values()):
        violations.append(f"{jname}: grants a write permission")
    for i, step in enumerate(job.get("steps") or []):
        sid = step.get("id") or step.get("name") or str(i)
        body = text(step)
        if "createComment" in body or re.search(r"/comments", body):
            violations.append(f"{sid}: calls the comments API")
        if "github-script" in str(step.get("uses", "")):
            violations.append(f"{sid}: uses github-script")
        if re.search(r"gh\s+(pr\s+(comment|review)|issue\s+comment|api)\b", body):
            violations.append(f"{sid}: runs a gh write path")
        if "steps." in body or "outputs." in body:
            violations.append(f"{sid}: reads a step output")
        run = str(step.get("run", ""))
        stripped = "\n".join(l for l in run.splitlines() if "::notice::" not in l)
        if "@cursor review" in stripped or "@cursor review" in text(step.get("with", {})):
            violations.append(f"{sid}: carries an @cursor review body")
for v in violations:
    print(v)
PY

echo "== (w1): the shipped workflow parses and keeps its trigger and job name =="
SHAPE="$(python3 "$TMP/inspect.py" "$WORKFLOW" shape 2>&1)"
check_eq "trigger + job name preserved, one step" \
  '{"jobs": ["post-cursor-review"], "name": "Cursor BugBot review trigger", "pull_request": ["opened", "reopened", "synchronize"], "steps": 1}' \
  "$SHAPE"

echo "== (w2): no step can post a trigger comment =="
VIOL="$(python3 "$TMP/inspect.py" "$WORKFLOW" check 2>&1)"
check_eq "no posting path (violations listed if any)" "" "$VIOL"

echo "== (w3): the notice states the approval requirement =="
check_eq "notice names owner approval" "1" \
  "$(grep -c "needs the owner's explicit approval" "$WORKFLOW" | tr -d ' ')"

echo "== (w4): CONTROL — a synthetic posting workflow is caught =="
# The pre-#1897 posting step's shape: github-script + the PAT + createComment,
# gated on a guard step's output. Every check above must see it.
cat > "$TMP/posting.yml" <<'YML'
name: Cursor BugBot review trigger
on:
  pull_request:
    types: [opened, synchronize, reopened]
jobs:
  post-cursor-review:
    runs-on: ubuntu-latest
    steps:
      - name: Comment @cursor review
        if: steps.suppress-check.outputs.suppressed != 'true'
        uses: actions/github-script@v9
        with:
          github-token: ${{ secrets.CURSOR_REVIEW_PAT }}
          script: |
            await github.rest.issues.createComment({body: '@cursor review'});
      - name: Post via gh
        run: gh pr comment 1 --body done
YML
CTRL="$(python3 "$TMP/inspect.py" "$TMP/posting.yml" check 2>&1)"
for needle in "references a secret" "CURSOR_REVIEW_PAT" "calls the comments API" \
              "uses github-script" "runs a gh write path" "reads a step output" "carries an @cursor review body"; do
  check_eq "control flags: $needle" "1" "$(grep -c -- "$needle" <<<"$CTRL" | tr -d ' ')"
done

echo
echo "== summary: $PASS passed, $FAIL failed =="
[[ "$FAIL" -eq 0 ]] || exit 1
echo "OK: cursor-review-pr-comment.yml never posts @cursor review"
