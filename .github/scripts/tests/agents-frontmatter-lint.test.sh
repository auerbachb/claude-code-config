#!/usr/bin/env bash
# Unit tests for agents-frontmatter-lint.sh (issue #1121)
#
# Each case builds a throwaway fixture dir and runs the lint from within it.
# Every failure mode has an explicit inversion test: a guard that passes on
# well-formed input but NOT on the broken variant proves the check fires.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
LINT="${REPO_ROOT}/.github/scripts/agents-frontmatter-lint.sh"

TMP_ROOT=$(mktemp -d -t agents-fm-lint.XXXXXX)
trap 'rm -rf "$TMP_ROOT"' EXIT

failures=0
case_num=0

# Build a minimal well-formed fixture: one agent file with all required fields.
make_fixture() {
  local dir="$1"
  mkdir -p "${dir}/.claude/agents"
  cat > "${dir}/.claude/agents/my-agent.md" <<'EOF'
---
name: my-agent
description: "Test agent for linting."
model: sonnet
---

# My Agent

Body text.
EOF
}

# expect <name> <expected-exit> <expected-output-regex> <mutator...>
# Builds a fresh fixture, applies the mutator (runs it from within the
# fixture dir), then asserts both exit status and matching output.
expect() {
  local name="$1" want="$2" want_re="$3"; shift 3
  case_num=$((case_num + 1))
  local dir="${TMP_ROOT}/case${case_num}"
  make_fixture "$dir"
  # Apply mutator (if any) inside fixture dir.
  if [[ "$1" != "noop" ]]; then
    ( cd "$dir" && "$@" )
  fi

  local out got
  out=$(cd "$dir" && bash "$LINT" 2>&1) && got=0 || got=$?

  if (( got != want )); then
    echo "FAIL — ${name}: expected exit ${want}, got ${got}"
    echo "$out" | sed 's/^/       /'
    failures=$((failures + 1))
    return
  fi

  if ! grep -qE "$want_re" <<< "$out"; then
    echo "FAIL — ${name}: exit ${got} as expected, but output did not match /${want_re}/"
    echo "$out" | sed 's/^/       /'
    failures=$((failures + 1))
    return
  fi

  echo "ok   — ${name}"
}

noop() { :; }

# --- passing case -----------------------------------------------------------
expect "well-formed agent passes" 0 'agents-frontmatter-lint: OK' noop

# --- name: missing (inversion: passes before deletion, fails after) ---------
expect "missing name: fails" 1 \
  "missing a 'name:' frontmatter field" \
  sed -i.bak '/^name:/d' .claude/agents/my-agent.md

# --- name: mismatch with filename stem -------------------------------------
expect "name: mismatch with stem fails" 1 \
  "does not match filename stem" \
  sed -i.bak 's/^name: my-agent/name: wrong-name/' .claude/agents/my-agent.md

# --- description: missing --------------------------------------------------
expect "missing description: fails" 1 \
  "missing a 'description:' frontmatter field" \
  sed -i.bak '/^description:/d' .claude/agents/my-agent.md

# --- deprecated allowed-tools: key ----------------------------------------
expect "allowed-tools: key fails" 1 \
  "deprecated 'allowed-tools:'" \
  sed -i.bak 's/^model: sonnet/allowed-tools: Read, Bash\nmodel: sonnet/' .claude/agents/my-agent.md

# --- README.md is skipped (no agent fields) --------------------------------
# Add a README.md that has none of the required fields; lint must still pass.
expect "README.md is skipped" 0 \
  'agents-frontmatter-lint: OK' \
  bash -c 'printf "# README\n\nThis is documentation.\n" > .claude/agents/README.md'

# --- no agents dir ---------------------------------------------------------
case_num=$((case_num + 1))
empty_dir="${TMP_ROOT}/case${case_num}"
mkdir -p "$empty_dir"
if out=$(cd "$empty_dir" && bash "$LINT" 2>&1); then
  echo "FAIL — missing agents dir: expected non-zero exit, got 0"
  failures=$((failures + 1))
else
  echo "ok   — missing agents dir exits non-zero"
fi

# --- CLI contract -----------------------------------------------------------
case_num=$((case_num + 1))
help_dir="${TMP_ROOT}/case${case_num}"
make_fixture "$help_dir"
if (cd "$help_dir" && bash "$LINT" --help >/dev/null 2>&1); then
  echo "ok   — --help exits 0"
else
  echo "FAIL — --help should exit 0"
  failures=$((failures + 1))
fi

case_num=$((case_num + 1))
bogus_dir="${TMP_ROOT}/case${case_num}"
make_fixture "$bogus_dir"
got_exit=0
(cd "$bogus_dir" && bash "$LINT" --bogus >/dev/null 2>&1) || got_exit=$?
if (( got_exit == 2 )); then
  echo "ok   — unknown arg exits 2"
else
  echo "FAIL — unknown arg: expected exit 2, got ${got_exit}"
  failures=$((failures + 1))
fi

# --- real repo --------------------------------------------------------------
if (cd "$REPO_ROOT" && bash "$LINT" >/dev/null 2>&1); then
  echo "ok   — real repo agent files pass lint"
else
  echo "FAIL — lint does not pass against the real repo"
  (cd "$REPO_ROOT" && bash "$LINT" 2>&1 | sed 's/^/       /') || true
  failures=$((failures + 1))
fi

if (( failures > 0 )); then
  echo "agents-frontmatter-lint.test: ${failures} failure(s)"
  exit 1
fi

echo "OK: agents-frontmatter-lint tests passed (${case_num} fixtures)"
