#!/usr/bin/env bash
# Unit tests for scripts-catalog-lint.sh (issues #898, #1578)
#
# The lint reads repo-root-relative paths, so each case builds a throwaway
# fixture tree and runs the script with that tree as cwd. Same shape as the
# sibling skill-catalog-lint.test.sh.
#
# SCOPE OF THIS SUITE, AFTER #1578
#
# The rows are generated now, so coverage, row uniqueness, link integrity,
# link-text agreement, index purity and per-doc row ordering are properties of
# `scripts-catalog-gen.sh` and are pinned by its own suite. What remains this
# lint's own is the pair of checks generation cannot make structural — the
# back-link, and a hand-written row sitting OUTSIDE a generated region — plus
# the fact that it actually delegates the rest instead of silently passing.
# Delegation is asserted through observable behaviour: each delegated failure
# mode is introduced in a fixture and the lint must go red.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
LINT="${REPO_ROOT}/.github/scripts/scripts-catalog-lint.sh"
CATALOG_GEN="${REPO_ROOT}/.github/scripts/scripts-catalog-gen.sh"
export CATALOG_GEN

# shellcheck source=lib/catalog-fixture.sh
source "${REPO_ROOT}/.github/scripts/tests/lib/catalog-fixture.sh"

TMP_ROOT=$(mktemp -d -t scripts-catalog-lint.XXXXXX)
trap 'rm -rf "$TMP_ROOT"' EXIT

failures=0
case_num=0

# expect <name> <expected-exit> <expected-output-regex> <mutator...>
# Builds a fresh fixture, applies the mutator, then asserts BOTH the exit
# status and that the output matches the regex. Asserting the message too is
# what stops a case from passing on an unrelated error — a typo or a syntax
# break also exits non-zero, and would otherwise look like a pass.
expect() {
  local name="$1" want="$2" want_re="$3"; shift 3
  case_num=$((case_num + 1))
  local dir="${TMP_ROOT}/case${case_num}"
  make_catalog_fixture "$dir"
  ( cd "$dir" && "$@" )

  local out got
  out=$(cd "$dir" && bash "$LINT" 2>&1) && got=0 || got=$?

  if (( got != want )); then
    echo "FAIL — ${name}: expected exit ${want}, got ${got}"
    echo "$out" | sed 's/^/       /'
    failures=$((failures + 1))
    return
  fi

  if ! grep -qE -- "$want_re" <<< "$out"; then
    echo "FAIL — ${name}: exit ${got} as expected, but output did not match /${want_re}/"
    echo "$out" | sed 's/^/       /'
    failures=$((failures + 1))
    return
  fi

  echo "ok   — ${name}"
}

noop() { :; }

drop_line() { grep -v "$1" "$2" > "${2}.new" && mv "${2}.new" "$2"; }

append_to() { printf '%s\n' "$2" >> "$1"; }

# --- passing case ---------------------------------------------------------
expect "well-formed generated catalog passes" 0 \
  'scripts-catalog-lint: OK \(2 category docs, rows generated and in sync\)' noop

# --- CLI contract ---------------------------------------------------------
case_num=$((case_num + 1))
help_dir="${TMP_ROOT}/case${case_num}"
make_catalog_fixture "$help_dir"
if (cd "$help_dir" && bash "$LINT" --help | grep -q 'Usage:'); then
  echo "ok   — --help prints usage and exits 0"
else
  echo "FAIL — --help prints usage and exits 0"
  failures=$((failures + 1))
fi
# expect() always invokes the lint with no arguments, so the argument cases run
# their own invocation rather than going through it.
bogus_out=$(cd "$help_dir" && bash "$LINT" --bogus 2>&1) && bogus_rc=0 || bogus_rc=$?
if (( bogus_rc == 2 )) && grep -q 'Unknown argument' <<< "$bogus_out"; then
  echo "ok   — unknown argument exits 2 with a diagnostic"
else
  echo "FAIL — unknown argument exits 2 with a diagnostic (got ${bogus_rc})"
  echo "$bogus_out" | sed 's/^/       /'
  failures=$((failures + 1))
fi

# --- 1. back-link ---------------------------------------------------------
expect "category doc without the back-link fails" 1 \
  'missing the back-link to the index' \
  drop_line 'back to the index' .claude/scripts/docs/tools.md

# A back-link shown inside a fenced block documents the format; it is not
# navigation, so it must not satisfy the check.
expect "back-link only inside a code fence fails" 1 \
  'missing the back-link to the index' \
  bash -c 'drop() { grep -v "back to the index" "$1" > "$1.new" && mv "$1.new" "$1"; }
           drop .claude/scripts/docs/tools.md
           printf "%s\n" "\`\`\`markdown" "[back to the index](../README.md)" "\`\`\`" \
             >> .claude/scripts/docs/tools.md'

# --- 2. no hand-written row outside a generated region --------------------
# This is the one row-shaped property generation does NOT make structural: the
# generator only rewrites what lies between the markers, so a row appended below
# one would survive every regeneration, uncatalogued and unchecked, forever.
expect "a hand-written row below the region fails and names the line" 1 \
  'hand-written catalog row outside a generated region' \
  append_to .claude/scripts/docs/tools.md '| [smuggled.sh](../smuggled.sh) | Snuck in |'

expect "a per-script row in the index fails" 1 \
  'hand-written catalog row outside a generated region' \
  append_to .claude/scripts/README.md '| [alpha.sh](docs/../alpha.sh) | Wrong home |'

# The fence rule applies here too — an example row is documentation.
expect "an example row inside a code fence is not counted" 0 \
  'scripts-catalog-lint: OK' \
  bash -c 'printf "%s\n" "" "\`\`\`markdown" "| [example.sh](../example.sh) | Example row |" "\`\`\`" \
             >> .claude/scripts/docs/tools.md'

# A category doc is free to carry an ordinary link table — a pointer to the
# reference doc that owns a mechanism, say. Only a row whose link text is a bare
# script or test filename is a catalog row, so an ordinary table must not be
# reported. Without this case the stray-row matcher could be narrowed wrongly
# and nothing would notice.
expect "an ordinary link table in a category doc is not a catalog row" 0 \
  'scripts-catalog-lint: OK' \
  bash -c 'printf "%s\n" "" "| Topic | Mechanism |" "|---|---|" \
             "| Ordering | [churn-hotspots.md](../../reference/churn-hotspots.md) |" \
             >> .claude/scripts/docs/tools.md'

# --- 3. delegation --------------------------------------------------------
# Each of these is the generator's check, not this lint's. They are asserted
# here because a lint that stopped delegating would go green on all of them.
expect "a script with no declaration fails through delegation" 1 \
  "no '# catalog: <category-id>" \
  bash -c 'printf "#!/usr/bin/env bash\n# delta.sh — undeclared.\n" > .claude/scripts/delta.sh'

expect "a test with no declaration fails through delegation" 1 \
  "no '# catalog: <category-id>" \
  bash -c 'printf "#!/usr/bin/env bash\n# delta.test.sh — undeclared.\n" > .claude/scripts/tests/delta.test.sh'

expect "an unknown category id fails through delegation" 1 \
  'does not match any doc' \
  bash -c 'printf "#!/usr/bin/env bash\n# catalog: nosuch — Orphan\n" > .claude/scripts/orphan.sh'

expect "a stale committed region fails through delegation" 1 \
  'committed catalog region is stale' \
  drop_line '\[gamma\.sh\]' .claude/scripts/docs/tools.md

expect "a doc with no category declaration fails through delegation" 1 \
  'no <!-- catalog:category' \
  drop_line 'catalog:category' .claude/scripts/docs/tools.md

expect "a stale exemption list fails through delegation" 1 \
  'churn-hotspot-exemptions\.json::committed catalog region is stale' \
  bash -c 'jq "del(.exemptions[\".claude/scripts/docs/tests.md\"])" \
             .claude/reference/churn-hotspot-exemptions.json > tmp.json \
           && mv tmp.json .claude/reference/churn-hotspot-exemptions.json'

# --- out of scope ---------------------------------------------------------
# A catalog tool that started demanding declarations for lib/ helpers or test
# fixtures would redden CI on a correct tree.
expect "new lib/ helper needs no declaration" 0 'scripts-catalog-lint: OK' \
  bash -c 'printf "#!/usr/bin/env bash\n" > .claude/scripts/lib/new-helper.sh'

expect "new tests/lib/ helper needs no declaration" 0 'scripts-catalog-lint: OK' \
  bash -c 'printf "#!/usr/bin/env bash\n" > .claude/scripts/tests/lib/new-fixture.sh'

expect "non-test file under tests/ needs no declaration" 0 'scripts-catalog-lint: OK' \
  bash -c 'printf "notes\n" > .claude/scripts/tests/NOTES.md'

expect "non-script file needs no declaration" 0 'scripts-catalog-lint: OK' \
  bash -c 'printf "<plist/>\n" > .claude/scripts/com.example.other.plist'

# --- structural failures --------------------------------------------------
expect "empty docs dir fails rather than passing green" 1 \
  'contains no category docs' \
  bash -c 'rm -f .claude/scripts/docs/*.md'

expect "a missing index fails" 1 'index not found' \
  bash -c 'rm -f .claude/scripts/README.md'

# --- the retired ordering marker ------------------------------------------
# #1544's per-doc opt-in is superseded: rows are generated in LC_ALL=C order for
# every doc. The marker must be inert, not an error and not a re-enabled check.
expect "the retired catalog-lint: ordered marker is inert" 0 'scripts-catalog-lint: OK' \
  bash -c 'printf "%s\n" "" "<!-- catalog-lint: ordered -->" >> .claude/scripts/docs/tools.md'

# --- real repo ------------------------------------------------------------
if (cd "$REPO_ROOT" && bash "$LINT" >/dev/null 2>&1); then
  echo "ok   — real repo catalog is in sync"
else
  echo "FAIL — lint does not pass against the real repo"
  (cd "$REPO_ROOT" && bash "$LINT" 2>&1 | sed 's/^/       /') || true
  failures=$((failures + 1))
fi

if (( failures > 0 )); then
  echo "scripts-catalog-lint.test.sh: ${failures} failure(s)"
  exit 1
fi
echo "scripts-catalog-lint.test.sh: all checks passed"
