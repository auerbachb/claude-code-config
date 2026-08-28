#!/usr/bin/env bash
# Unit tests for scripts-catalog-lint.sh (issue #898)
#
# The lint reads repo-root-relative paths, so each case builds a throwaway
# fixture tree and runs the script with that tree as cwd. Same shape as the
# sibling skill-catalog-lint.test.sh.
#
# Every failure mode gets an explicit case: a guard asserted only on
# well-formed input would pass without proving it catches anything. The
# out-of-scope cases matter just as much — a lint that starts demanding rows
# for lib/ helpers or test fixtures would redden CI on a correct tree.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
LINT="${REPO_ROOT}/.github/scripts/scripts-catalog-lint.sh"

TMP_ROOT=$(mktemp -d -t scripts-catalog-lint.XXXXXX)
trap 'rm -rf "$TMP_ROOT"' EXIT

failures=0
case_num=0

# Well-formed fixture: 2 scripts + 1 python helper + 1 test, split across two
# category docs, both linked from the index. Also seeds the out-of-scope files
# (lib/, tests/lib/, tests/fixtures/, a .plist) that must NOT require rows.
make_fixture() {
  local dir="$1"
  mkdir -p "$dir/.claude/scripts/docs" \
           "$dir/.claude/scripts/tests" \
           "$dir/.claude/scripts/lib" \
           "$dir/.claude/scripts/tests/lib" \
           "$dir/.claude/scripts/tests/fixtures"

  printf '#!/usr/bin/env bash\n' > "$dir/.claude/scripts/alpha.sh"
  printf '#!/usr/bin/env bash\n' > "$dir/.claude/scripts/gamma.sh"
  printf '#!/usr/bin/env python3\n' > "$dir/.claude/scripts/beta.py"
  printf '#!/usr/bin/env bash\n' > "$dir/.claude/scripts/tests/alpha.test.sh"

  # Out of scope on purpose.
  printf '#!/usr/bin/env bash\n' > "$dir/.claude/scripts/lib/helper.sh"
  printf '.x\n' > "$dir/.claude/scripts/lib/program.jq"
  printf '#!/usr/bin/env bash\n' > "$dir/.claude/scripts/tests/lib/fixtures.sh"
  printf 'fixture\n' > "$dir/.claude/scripts/tests/fixtures/sample.md"
  printf '<plist/>\n' > "$dir/.claude/scripts/com.example.thing.plist"

  cat > "$dir/.claude/scripts/docs/tools.md" <<'EOF'
# Tools

Scripts that do tool things.

| Script | Purpose |
|--------|---------|
| [alpha.sh](../alpha.sh) | First |
| [gamma.sh](../gamma.sh) | Third |
| [beta.py](../beta.py) | Second |

---

[back to the index](../README.md)
EOF

  cat > "$dir/.claude/scripts/docs/tests.md" <<'EOF'
# Tests

All tests live in tests/ and run offline.

| Test | What it covers |
|------|----------------|
| [alpha.test.sh](../tests/alpha.test.sh) | Covers alpha |

---

[back to the index](../README.md)
EOF

  cat > "$dir/.claude/scripts/README.md" <<'EOF'
# .claude/scripts/

Index only.

## Categories

| Category | Covers |
|----------|--------|
| [Tools](docs/tools.md) | Scripts that do tool things |
| [Tests](docs/tests.md) | Every test under tests/ |

## scripts/ vs hooks/

Nothing to see here.
EOF
}

# expect <name> <expected-exit> <expected-output-regex> <mutator...>
# Builds a fresh fixture, applies the mutator, then asserts BOTH the exit
# status and that the output matches the regex. Asserting the message too is
# what stops a case from passing on an unrelated error — a typo or a syntax
# break also exits non-zero, and would otherwise look like a pass.
expect() {
  local name="$1" want="$2" want_re="$3"; shift 3
  case_num=$((case_num + 1))
  local dir="${TMP_ROOT}/case${case_num}"
  make_fixture "$dir"
  ( cd "$dir" && "$@" )

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

drop_line() { grep -v "$1" "$2" > "${2}.new" && mv "${2}.new" "$2"; }

# --- passing case ---------------------------------------------------------
expect "well-formed catalog passes" 0 \
  'scripts-catalog-lint: OK \(4 entries across 2 category docs\)' noop

# --- 1. coverage ----------------------------------------------------------
expect "new script with no row fails" 1 \
  "'delta\.sh' exists in .* but has no row" \
  bash -c 'printf "#!/usr/bin/env bash\n" > .claude/scripts/delta.sh'

expect "new test with no row fails" 1 \
  "'delta\.test\.sh' exists in .* but has no row" \
  bash -c 'printf "#!/usr/bin/env bash\n" > .claude/scripts/tests/delta.test.sh'

expect "deleted row for an existing script fails" 1 \
  "'gamma\.sh' exists in .* but has no row" \
  drop_line '^| \[gamma\.sh\]' .claude/scripts/docs/tools.md

expect "row naming an out-of-scope file fails" 1 \
  "documents 'helper\.sh' but no such script or test is in scope" \
  bash -c 'printf "%s\n" "| [helper.sh](../lib/helper.sh) | Out of scope |" >> .claude/scripts/docs/tools.md'

expect "duplicate row across two docs fails" 1 \
  "'alpha\.sh' has more than one row" \
  bash -c 'printf "%s\n" "| [alpha.sh](../alpha.sh) | Dupe |" >> .claude/scripts/docs/tests.md'

# --- 2. link integrity ----------------------------------------------------
expect "dead link fails" 1 \
  "link target '\.\./alpha-gone\.sh' for 'alpha\.sh' does not resolve" \
  sed -i.bak 's#(\.\./alpha\.sh)#(../alpha-gone.sh)#' .claude/scripts/docs/tools.md

expect "link text naming a different file than the target fails" 1 \
  "link text and the link target name different files" \
  sed -i.bak 's#\[gamma\.sh\](\.\./gamma\.sh)#[gamma.sh](../alpha.sh)#' .claude/scripts/docs/tools.md

# --- 3. index <-> docs bijection ------------------------------------------
expect "doc missing from the index fails" 1 \
  'docs/tests\.md exists but the index does not link it' \
  drop_line '(docs/tests\.md)' .claude/scripts/README.md

expect "index link to a deleted doc fails" 1 \
  'the index links docs/tools\.md but no such file exists' \
  rm -f .claude/scripts/docs/tools.md

# --- 4. back-link ---------------------------------------------------------
expect "category doc without the back-link fails" 1 \
  'missing the back-link to the index' \
  drop_line 'back to the index' .claude/scripts/docs/tools.md

# --- 5. index purity ------------------------------------------------------
expect "per-script row in the index fails" 1 \
  'index table may only link into' \
  bash -c 'printf "%s\n" "| [alpha.sh](../alpha.sh) | Should not be here |" >> .claude/scripts/README.md'

# --- out-of-scope files must NOT require rows -----------------------------
# These pin the scope boundary. Without them a future tightening of the
# inventory glob would demand catalog rows for helper libraries and test
# fixtures, reddening CI on a perfectly correct tree.
expect "new lib/ helper needs no row" 0 \
  'scripts-catalog-lint: OK' \
  bash -c 'printf "#!/usr/bin/env bash\n" > .claude/scripts/lib/another.sh'

expect "new tests/lib/ helper needs no row" 0 \
  'scripts-catalog-lint: OK' \
  bash -c 'printf "#!/usr/bin/env bash\n" > .claude/scripts/tests/lib/more-fixtures.sh'

expect "non-test file under tests/ needs no row" 0 \
  'scripts-catalog-lint: OK' \
  bash -c 'printf "#!/usr/bin/env bash\n" > .claude/scripts/tests/run-helper.sh'

expect "non-script file needs no row" 0 \
  'scripts-catalog-lint: OK' \
  bash -c 'printf "<plist/>\n" > .claude/scripts/com.example.other.plist'

# --- fail-loud discovery --------------------------------------------------
expect "empty docs dir fails rather than passing green" 1 \
  'contains no category docs|No catalog rows found' \
  bash -c 'rm -f .claude/scripts/docs/*.md'

# --- CLI contract ---------------------------------------------------------
case_num=$((case_num + 1))
help_dir="${TMP_ROOT}/case${case_num}"
make_fixture "$help_dir"
if (cd "$help_dir" && bash "$LINT" --help >/dev/null 2>&1); then
  echo "ok   — --help exits 0"
else
  echo "FAIL — --help should exit 0"
  failures=$((failures + 1))
fi

got=0
(cd "$help_dir" && bash "$LINT" --bogus >/dev/null 2>&1) || got=$?
if (( got == 2 )); then
  echo "ok   — unknown arg exits 2"
else
  echo "FAIL — unknown arg: expected exit 2, got ${got}"
  failures=$((failures + 1))
fi

# --- real repo ------------------------------------------------------------
if (cd "$REPO_ROOT" && bash "$LINT" >/dev/null 2>&1); then
  echo "ok   — real repo catalog is in sync"
else
  echo "FAIL — lint does not pass against the real repo"
  (cd "$REPO_ROOT" && bash "$LINT" 2>&1 | sed 's/^/       /') || true
  failures=$((failures + 1))
fi

if (( failures > 0 )); then
  echo "scripts-catalog-lint.test: ${failures} failure(s)"
  exit 1
fi

echo "OK: scripts-catalog-lint tests passed (${case_num} fixtures)"
