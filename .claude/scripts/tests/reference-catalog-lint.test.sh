#!/usr/bin/env bash
# Unit tests for .claude/scripts/reference-catalog-lint.sh (issue #950)
# catalog: tests — Tests that `reference-catalog-lint.sh` fails on every drift class it claims to catch
#
# This lint shipped (PR #909) with no CI caller and no test, so it had never
# been observed either passing or failing under anything but a hand-typed
# invocation. The suite therefore does two jobs:
#
#   1. Prove the lint FAILS on every drift class it claims to catch — the
#      deliberate drift named in the issue (a .claude/reference/*.md file with
#      no ## Contents row) plus the phantom-entry and duplicate-row classes.
#      A guard asserted only on well-formed input would pass without proving
#      it catches anything.
#   2. Prove the lint is WIRED into the required rule-lint job, and that a lint
#      which cannot run reads as a failure rather than a silent green. Both
#      wiring assertions carry a negative control, because a wiring check that
#      quietly matches nothing would itself be a guard that passes by not
#      running.
#
# The lint resolves repo-root-relative paths, so each drift case builds a
# throwaway repo-shaped fixture and runs the script with that tree as cwd.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
LINT="${REPO_ROOT}/.claude/scripts/reference-catalog-lint.sh"
WORKFLOW="${REPO_ROOT}/.github/workflows/rule-lint.yml"
# The exact command the workflow step must run. CI invokes the script via
# `bash`, so the executable bit is deliberately not part of the contract.
WIRED_COMMAND="bash .claude/scripts/reference-catalog-lint.sh"

TMP_ROOT=$(mktemp -d -t reference-catalog-lint.XXXXXX)
trap 'rm -rf "$TMP_ROOT"' EXIT

failures=0
case_num=0

pass() { echo "ok   — $1"; }
fail() { echo "FAIL — $1"; failures=$((failures + 1)); }

# Well-formed fixture: 2 indexed files, 2 matching rows, plus a nested
# diagrams/ file the lint is documented to ignore (maxdepth 1).
make_fixture() {
  local dir="$1"
  mkdir -p "$dir/.claude/reference/diagrams"
  echo "alpha" > "$dir/.claude/reference/alpha.md"
  echo "{}"    > "$dir/.claude/reference/beta.json"
  echo "nested" > "$dir/.claude/reference/diagrams/nested.md"
  cat > "$dir/.claude/reference/README.md" <<'EOF'
# Fixture reference catalog

Prose above the index. A bullet up here is not a registration.

## Contents

- `alpha.md` — first fixture doc
- `beta.json` — second fixture doc
EOF
}

# expect <name> <expected-exit> <expected-output-regex> <mutator...>
# Builds a fresh fixture, applies one mutator, then asserts BOTH the exit
# status and that the output matches the regex. Asserting the message too is
# what stops a case from passing on an unrelated error — a typo or a syntax
# break also exits non-zero, and would otherwise look like a caught drift.
expect() {
  local name="$1" want="$2" want_re="$3"; shift 3
  case_num=$((case_num + 1))
  local dir="${TMP_ROOT}/case${case_num}"
  make_fixture "$dir"

  if ! ( cd "$dir" && "$@" ); then
    fail "${name}: fixture mutator failed, case never ran"
    return
  fi

  local out got
  out=$(cd "$dir" && bash "$LINT" 2>&1) && got=0 || got=$?

  if (( got != want )); then
    fail "${name}: expected exit ${want}, got ${got}"
    echo "$out" | sed 's/^/       /'
    return
  fi

  if ! grep -qE "$want_re" <<< "$out"; then
    fail "${name}: exit ${got} as expected, but output did not match /${want_re}/"
    echo "$out" | sed 's/^/       /'
    return
  fi

  pass "$name"
}

noop() { :; }

# Puts a catalog-shaped bullet ABOVE the '## Contents' header, simulating a
# filename mentioned in the README preamble. Counting it would make the run
# report a phantom entry, so exit 0 is what proves the section scoping works.
insert_bullet_above_contents() {
  local tmp
  tmp=$(mktemp)
  awk '
    /^## Contents/ && !seen {
      print "- `decoy-above.md` — mentioned before the index"
      print ""
      seen = 1
    }
    { print }
  ' .claude/reference/README.md > "$tmp"
  mv "$tmp" .claude/reference/README.md
}

# Same idea below the index: the awk in the lint stops at the next '## '.
append_section_below_contents() {
  {
    printf '\n%s\n\n' "## Appendix"
    printf '%s\n' "- \`decoy-below.md\` — listed outside the index"
  } >> .claude/reference/README.md
}

# --- passing case ---------------------------------------------------------
# The file count in the marker is load-bearing: it proves the run actually
# scanned the fixture rather than passing vacuously over an empty set.
expect "well-formed catalog passes" 0 \
  'reference-catalog-lint: OK \(2 files indexed\)' \
  noop

# --- drift failures -------------------------------------------------------
# This is the acceptance criterion: a deliberately-introduced catalog drift
# (a .claude/reference/*.md file with no README row) must fail the check.
expect "undocumented reference file fails" 1 \
  "File 'gamma.md' exists in .* but has no entry in the ## Contents index" \
  bash -c 'echo gamma > .claude/reference/gamma.md'

expect "undocumented .json file fails" 1 \
  "File 'gamma.json' exists in .* but has no entry in the ## Contents index" \
  bash -c 'echo "{}" > .claude/reference/gamma.json'

expect "Contents row with no file on disk fails" 1 \
  "README indexes 'delta.md' but no such file exists" \
  bash -c 'printf "%s\n" "- \`delta.md\` — phantom entry" >> .claude/reference/README.md'

expect "duplicate Contents row fails" 1 \
  "'alpha.md' appears more than once in the ## Contents index" \
  bash -c 'printf "%s\n" "- \`alpha.md\` — duplicate row" >> .claude/reference/README.md'

# --- fast-path failure ----------------------------------------------------
# Missing README is the reachable half of the two fast-path guards: the
# REFERENCE_DIR check below it cannot fire on its own, since the README can
# only exist when the directory does.
expect "missing README fails" 1 \
  'README\.md not found' \
  rm .claude/reference/README.md

# --- scoping / false-positive guards --------------------------------------
expect "bullet above the Contents section is ignored" 0 \
  'reference-catalog-lint: OK \(2 files indexed\)' \
  insert_bullet_above_contents

expect "bullet in a later section is ignored" 0 \
  'reference-catalog-lint: OK \(2 files indexed\)' \
  append_section_below_contents

expect "path-qualified cross-reference is not a registration" 0 \
  'reference-catalog-lint: OK \(2 files indexed\)' \
  bash -c 'printf "%s\n" "- \`.claude/rules/safety.md\` — cross reference" >> .claude/reference/README.md'

expect "nested diagrams/ file needs no index row" 0 \
  'reference-catalog-lint: OK \(2 files indexed\)' \
  bash -c 'echo more > .claude/reference/diagrams/extra.md'

# --- CLI contract ---------------------------------------------------------
case_num=$((case_num + 1))
cli_dir="${TMP_ROOT}/case${case_num}"
make_fixture "$cli_dir"

if (cd "$cli_dir" && bash "$LINT" --help >/dev/null 2>&1); then
  pass "--help exits 0"
else
  fail "--help should exit 0"
fi

got=0
(cd "$cli_dir" && bash "$LINT" --bogus >/dev/null 2>&1) || got=$?
if (( got == 2 )); then
  pass "unknown arg exits 2"
else
  fail "unknown arg: expected exit 2, got ${got}"
fi

# --- CI wiring (updated for auto-discovery runner — issue #1138) -----------
# reference-catalog-lint.sh is now wired via the auto-discovery runner
# (.github/scripts/run-doc-lints.sh, included via its EXTRA path).  The
# per-lint step 'Run reference-catalog-lint' was removed in PR #1147; the
# wiring check now verifies the runner step exists in the rule-lint job.
# run-doc-lints.test.sh verifies the script is reachable through the runner.
WIRED_RUNNER_CMD='bash .github/scripts/summarize-test-run.sh "Doc lints" .github/scripts/run-doc-lints.sh'
RUNNER_STEP_NAME="Run doc lints (auto-discovered)"

# Prints the run command of the auto-discovery runner step inside the
# rule-lint job. Prints nothing when absent, in another job, or no run: key.
wired_step_command() {
  awk '
    /^  [A-Za-z0-9_-]+:/ { in_job = ($0 ~ /^  rule-lint:/) }
    !in_job { next }
    /^[[:space:]]*- name:[[:space:]]*Run doc lints \(auto-discovered\)[[:space:]]*$/ { want = 1; next }
    want && /^[[:space:]]*- / { want = 0; next }
    want && /^[[:space:]]*run:[[:space:]]*/ {
      sub(/^[[:space:]]*run:[[:space:]]*/, "")
      print
      exit
    }
  ' "$1"
}

wired="$(wired_step_command "$WORKFLOW")"
if [[ "$wired" == "$WIRED_RUNNER_CMD" ]]; then
  pass "rule-lint job runs the auto-discovery runner"
else
  fail "rule-lint job does not run '${WIRED_RUNNER_CMD}' under a '${RUNNER_STEP_NAME}' step (found: '${wired}')"
fi

# Negative controls for the wiring check itself.
neg_dir="${TMP_ROOT}/wiring"
mkdir -p "$neg_dir"

cat > "${neg_dir}/absent.yml" <<'EOF'
jobs:
  rule-lint:
    runs-on: ubuntu-latest
    steps:
      - name: Run rule-lint
        run: bash .github/scripts/rule-lint.sh
EOF

cat > "${neg_dir}/other-job.yml" <<'EOF'
jobs:
  rule-lint:
    runs-on: ubuntu-latest
    steps:
      - name: Run rule-lint
        run: bash .github/scripts/rule-lint.sh

  unrelated-job:
    runs-on: ubuntu-latest
    steps:
      - name: Run reference-catalog-lint
        run: bash .claude/scripts/reference-catalog-lint.sh
EOF

cat > "${neg_dir}/no-run.yml" <<'EOF'
jobs:
  rule-lint:
    runs-on: ubuntu-latest
    steps:
      - name: Run reference-catalog-lint
        uses: actions/checkout@v5
EOF

for control in absent other-job no-run; do
  if [[ -z "$(wired_step_command "${neg_dir}/${control}.yml")" ]]; then
    pass "wiring check reports not-wired for the ${control} control"
  else
    fail "wiring check matched the ${control} control — it would pass on an unwired repo"
  fi
done

# Both scripts referenced by the runner step must exist on disk.
for runner_script in ".github/scripts/summarize-test-run.sh" ".github/scripts/run-doc-lints.sh"; do
  if [[ -f "${REPO_ROOT}/${runner_script}" ]]; then
    pass "runner script ${runner_script} exists"
  else
    fail "runner script ${runner_script} does not exist — CI step would exit non-zero"
  fi
done

# A lint that cannot run must read as failure, never as a silent pass.
got=0
(cd "$REPO_ROOT" && bash .claude/scripts/reference-catalog-lint-does-not-exist.sh) >/dev/null 2>&1 || got=$?
if (( got != 0 )); then
  pass "a missing lint script exits non-zero (CI step fails, not skips)"
else
  fail "a missing lint script exited 0 — a deleted lint would pass CI green"
fi

# --- real repo ------------------------------------------------------------
if (cd "$REPO_ROOT" && bash "$LINT" >/dev/null 2>&1); then
  pass "real repo catalog is in sync"
else
  fail "lint does not pass against the real repo"
  (cd "$REPO_ROOT" && bash "$LINT" 2>&1 | sed 's/^/       /') || true
fi

if (( failures > 0 )); then
  echo "reference-catalog-lint.test: ${failures} failure(s)"
  exit 1
fi

echo "OK: reference-catalog-lint tests passed (${case_num} fixtures)"
