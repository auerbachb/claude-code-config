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
  "'\\.claude/scripts/delta\\.sh' exists but has no row" \
  bash -c 'printf "#!/usr/bin/env bash\n" > .claude/scripts/delta.sh'

expect "new test with no row fails" 1 \
  "'\\.claude/scripts/tests/delta\\.test\\.sh' exists but has no row" \
  bash -c 'printf "#!/usr/bin/env bash\n" > .claude/scripts/tests/delta.test.sh'

expect "deleted row for an existing script fails" 1 \
  "'\\.claude/scripts/gamma\\.sh' exists but has no row" \
  drop_line '^| \[gamma\.sh\]' .claude/scripts/docs/tools.md

expect "row naming an out-of-scope file fails" 1 \
  "documents '\\.claude/scripts/lib/helper\\.sh' but no such script or test is in scope" \
  bash -c 'printf "%s\n" "| [helper.sh](../lib/helper.sh) | Out of scope |" >> .claude/scripts/docs/tools.md'

expect "duplicate row across two docs fails" 1 \
  "'\\.claude/scripts/alpha\\.sh' has more than one row" \
  bash -c 'printf "%s\n" "| [alpha.sh](../alpha.sh) | Dupe |" >> .claude/scripts/docs/tests.md'

# --- 1b. entry identity is the path, not the basename (issue #1452) --------
# The two in-scope globs overlap on exactly one shape: a *.test.sh that exists
# both at the top level and under tests/. Keyed on basenames those two files
# are one entry, and both cases below come out wrong. Verified against the
# pre-fix script: the first exits 1 with two spurious errors, and the second
# reports a bare 'alpha.test.sh' that never says which file it means.
expect "same-basename pair documented at both paths passes" 0 \
  'scripts-catalog-lint: OK \(5 entries across 2 category docs\)' \
  bash -c 'printf "#!/usr/bin/env bash\n" > .claude/scripts/alpha.test.sh
           printf "%s\n" "| [alpha.test.sh](../alpha.test.sh) | Top-level namesake |" \
             >> .claude/scripts/docs/tools.md'

expect "same-basename pair with one row names the undocumented path" 1 \
  "'\\.claude/scripts/alpha\\.test\\.sh' exists but has no row" \
  bash -c 'printf "#!/usr/bin/env bash\n" > .claude/scripts/alpha.test.sh'

# --- 2. link integrity ----------------------------------------------------
expect "dead link fails" 1 \
  "link target '\.\./alpha-gone\.sh' for 'alpha\.sh' does not resolve" \
  sed -i.bak 's#(\.\./alpha\.sh)#(../alpha-gone.sh)#' .claude/scripts/docs/tools.md

expect "link text naming a different file than the target fails" 1 \
  "link text and the link target name different files" \
  sed -i.bak 's#\[gamma\.sh\](\.\./gamma\.sh)#[gamma.sh](../alpha.sh)#' .claude/scripts/docs/tools.md

# Right name, wrong file: the basename check alone passes because a top-level
# alpha.sh also exists, so the row silently points at the lib/ helper.
expect "row linking to a same-named out-of-scope file fails" 1 \
  'an in-scope entry must link to \.\./alpha\.sh' \
  bash -c 'printf "#!/usr/bin/env bash\n" > .claude/scripts/lib/alpha.sh
           sed -i.bak "s#\[alpha\.sh\](\.\./alpha\.sh)#[alpha.sh](../lib/alpha.sh)#" \
             .claude/scripts/docs/tools.md'

# --- 3. index <-> docs bijection ------------------------------------------
expect "doc missing from the index fails" 1 \
  '\.claude/scripts/docs/tests\.md exists but the index does not link it' \
  drop_line '(docs/tests\.md)' .claude/scripts/README.md

expect "index link to a deleted doc fails" 1 \
  'the index links \.claude/scripts/docs/tools\.md but no such file exists' \
  rm -f .claude/scripts/docs/tools.md

# sort -u would collapse the repeat and call the set comparison a bijection.
expect "duplicate category row in the index fails" 1 \
  'the index links \.claude/scripts/docs/tools\.md more than once' \
  bash -c 'printf "%s\n" "| [Tools again](docs/tools.md) | Duplicate category row |" \
             >> .claude/scripts/README.md'

# --- 4. back-link ---------------------------------------------------------
expect "category doc without the back-link fails" 1 \
  'missing the back-link to the index' \
  drop_line 'back to the index' .claude/scripts/docs/tools.md

# A link that only ever appears inside a code fence is an example of the
# format, not navigation — the doc is still unreachable from the index.
expect "back-link only inside a code fence fails" 1 \
  'missing the back-link to the index' \
  bash -c 'drop_line() { grep -v "$1" "$2" > "${2}.new" && mv "${2}.new" "$2"; };
           drop_line "back to the index" .claude/scripts/docs/tools.md
           printf "%s\n" "" "\`\`\`markdown" "[back to the index](../README.md)" "\`\`\`" \
             >> .claude/scripts/docs/tools.md'

# --- whitespace tolerance in table rows -----------------------------------
# Markdown treats any run of spaces or tabs as cell padding, so a realigned
# table must still parse. Without this the rows vanish from the inventory and
# every script in the doc is reported missing.
expect "space-padded table cells still parse" 0 \
  'scripts-catalog-lint: OK \(4 entries across 2 category docs\)' \
  sed -i.bak 's#^| \[alpha\.sh\](\.\./alpha\.sh) | First |#|   [alpha.sh](../alpha.sh)     | First |#' \
    .claude/scripts/docs/tools.md

expect "tab-padded table cells still parse" 0 \
  'scripts-catalog-lint: OK \(4 entries across 2 category docs\)' \
  bash -c 'printf "%s\t%s\t%s\n" "|" "[gamma.sh](../gamma.sh)" "| Third |" > /tmp/row.$$
           grep -v "^| \[gamma\.sh\]" .claude/scripts/docs/tools.md > .claude/scripts/docs/tools.new
           cat /tmp/row.$$ >> .claude/scripts/docs/tools.new
           printf "%s\n" "" "[back to the index](../README.md)" >> .claude/scripts/docs/tools.new
           mv .claude/scripts/docs/tools.new .claude/scripts/docs/tools.md
           rm -f /tmp/row.$$'

# --- rows inside a code fence are not catalog content ---------------------
# The looser cell matching makes an example row inside a fence matchable, so
# the fence skip has to hold or the example becomes a phantom entry.
expect "example row inside a code fence is not counted" 0 \
  'scripts-catalog-lint: OK \(4 entries across 2 category docs\)' \
  bash -c 'printf "%s\n" "" "\`\`\`markdown" "| [nope.sh](../nope.sh) | Example only |" "\`\`\`" \
             >> .claude/scripts/docs/tools.md'

# --- 5. index purity ------------------------------------------------------
expect "per-script row in the index fails" 1 \
  'index table may only link into' \
  bash -c 'printf "%s\n" "| [alpha.sh](../alpha.sh) | Should not be here |" >> .claude/scripts/README.md'

# Checks 3 and 5 have to agree on what "links into docs/" means. This target
# carries the docs/ prefix but points outside docs/, so a textual prefix test
# in check 5 would wave it through while check 3 correctly declines to count it
# as a category link — leaving the row unclaimed by either check.
expect "index row escaping docs/ through .. fails" 1 \
  'index table may only link into' \
  bash -c 'printf "%s\n" "| [Sneaky](docs/../tools.md) | Escapes docs/ |" >> .claude/scripts/README.md'

# --- 6. row ordering, per-doc opt-in (issue #1544) ------------------------
# The check reads only docs carrying the marker, so both halves need pinning:
# that a marked doc is genuinely checked, and that an unmarked one is not.
# Without the second half the check could quietly grow into a repo-wide rule
# and redden CI on the 12 sibling docs that group rows by role on purpose.

ORDERED_MARKER='<!-- catalog-lint: ordered -->'
# The same marker shown as an example of the format. It must not opt a doc in,
# for the reason the back-link check already applies to fenced links.
FENCED_MARKER=$(printf '%s\n%s\n%s' '```markdown' "$ORDERED_MARKER" '```')

# A doc that shows a fenced example and *then* carries the real marker. The
# lint promises position-independence ("a marker anywhere in the doc counts"),
# so closing a fence must not stop the reader from seeing what follows it.
FENCE_THEN_MARKER=$(printf '%s\n%s\n%s\n\n%s' \
  '```markdown' '| [example.sh](../example.sh) | Shown, not counted |' '```' \
  "$ORDERED_MARKER")

# The same doc without the marker, but quoting the fence delimiter inline
# afterwards. Nothing here opts the doc in, and an inline ``` is not a fence —
# it does not start the line.
FENCE_THEN_INLINE=$(printf '%s\n%s\n%s\n\n%s' \
  '```markdown' '| [example.sh](../example.sh) | Shown, not counted |' '```' \
  'Quote the delimiter as ``` when writing about fences.')

ROW_ALPHA='| [alpha.sh](../alpha.sh) | First |'
ROW_BETA='| [beta.py](../beta.py) | Second |'
ROW_GAMMA='| [gamma.sh](../gamma.sh) | Third |'
ROW_ALPHA_TWO='| [alpha-two.sh](../alpha-two.sh) | Prefix namesake |'
ROW_TEST_NESTED='| [alpha.test.sh](../tests/alpha.test.sh) | Covers alpha |'
ROW_TEST_TOPLEVEL='| [alpha.test.sh](../alpha.test.sh) | Top-level namesake |'

# write_doc <path> <title> <marker-or-empty> <row>...
# Rewrites a category doc with the given rows in the given order, so a case
# states the order it is testing rather than patching the fixture into shape.
write_doc() {
  # Not `local path=` — zsh ties path/PATH, and a sourced copy would blow away
  # PATH for everything after it (issue #1556).
  local doc_path="$1" title="$2" marker="$3" row
  shift 3
  {
    printf '# %s\n\n' "$title"
    printf 'Category prose.\n\n'
    if [[ -n "$marker" ]]; then printf '%s\n\n' "$marker"; fi
    printf '| Entry | Purpose |\n|-------|---------|\n'
    for row in "$@"; do printf '%s\n' "$row"; done
    printf '\n---\n\n[back to the index](../README.md)\n'
  } > "$doc_path"
}

# The namesake pair of issue #1452: one file at the top level, one under
# tests/, identical link text. Rendered, the two rows are indistinguishable,
# so the ordering check has to treat them as a tie.
write_namesake_tests_doc() {
  printf '#!/usr/bin/env bash\n' > .claude/scripts/alpha.test.sh
  write_doc .claude/scripts/docs/tests.md Tests "$ORDERED_MARKER" "$@"
}

# A name that is a prefix of another, separated by a byte that sorts below the
# extension dot — the shape that drifted into the real tests.md.
write_prefix_pair_tools_doc() {
  printf '#!/usr/bin/env bash\n' > .claude/scripts/alpha-two.sh
  write_doc .claude/scripts/docs/tools.md Tools "$ORDERED_MARKER" "$@"
}

expect "marked doc in sort order passes" 0 \
  'scripts-catalog-lint: OK \(4 entries across 2 category docs\)' \
  write_doc .claude/scripts/docs/tools.md Tools "$ORDERED_MARKER" \
    "$ROW_ALPHA" "$ROW_BETA" "$ROW_GAMMA"

# The negative control. Without it every case above passes on a check that
# never fires.
expect "marked doc with a displaced row fails and names the row" 1 \
  "row 'beta\.py' is out of order.*it follows 'gamma\.sh'" \
  write_doc .claude/scripts/docs/tools.md Tools "$ORDERED_MARKER" \
    "$ROW_ALPHA" "$ROW_GAMMA" "$ROW_BETA"

# The 12 role-grouped siblings in the real repo, in miniature: rows in no
# particular order, no marker, and nothing for the lint to say about it.
expect "unmarked doc with displaced rows passes" 0 \
  'scripts-catalog-lint: OK \(4 entries across 2 category docs\)' \
  write_doc .claude/scripts/docs/tools.md Tools "" \
    "$ROW_GAMMA" "$ROW_BETA" "$ROW_ALPHA"

expect "marker inside a code fence does not opt the doc in" 0 \
  'scripts-catalog-lint: OK \(4 entries across 2 category docs\)' \
  write_doc .claude/scripts/docs/tools.md Tools "$FENCED_MARKER" \
    "$ROW_GAMMA" "$ROW_BETA" "$ROW_ALPHA"

# The fence skip must not blind the reader to what comes after the fence. Both
# cases below failed before the prelude stopped naming its scratch variable
# `marker`: it overwrote has_order_marker's -v marker on the first fence line,
# so afterwards the detector searched for a literal ``` instead of the marker.
# Position-independence and the fenced-example rule are the two halves of the
# documented contract, and each one broke in a different direction.
expect "marker below a fenced block still opts the doc in" 1 \
  "row 'beta\.py' is out of order.*it follows 'gamma\.sh'" \
  write_doc .claude/scripts/docs/tools.md Tools "$FENCE_THEN_MARKER" \
    "$ROW_GAMMA" "$ROW_BETA" "$ROW_ALPHA"

expect "a fence plus a later inline delimiter does not opt the doc in" 0 \
  'scripts-catalog-lint: OK \(4 entries across 2 category docs\)' \
  write_doc .claude/scripts/docs/tools.md Tools "$FENCE_THEN_INLINE" \
    "$ROW_GAMMA" "$ROW_BETA" "$ROW_ALPHA"

# Ordering is keyed on the link text a reader scans, not on the path key
# checks 1 and 3 use, so the namesake pair compares equal and both orders are
# legal. Pinning both is what stops a later switch to a path key from
# reddening a doc no reader could have written differently.
expect "marked doc allows a same-link-text pair, nested first" 0 \
  'scripts-catalog-lint: OK \(5 entries across 2 category docs\)' \
  write_namesake_tests_doc "$ROW_TEST_NESTED" "$ROW_TEST_TOPLEVEL"

expect "marked doc allows a same-link-text pair, top level first" 0 \
  'scripts-catalog-lint: OK \(5 entries across 2 category docs\)' \
  write_namesake_tests_doc "$ROW_TEST_TOPLEVEL" "$ROW_TEST_NESTED"

# Byte order, not dictionary order: '-' (0x2D) sorts before '.' (0x2E). This
# is the shape that drifted into the real tests.md between PR #1539 and this
# change, and the one a reader is most likely to "correct" back.
expect "marked doc enforces byte order, not dictionary order" 1 \
  "row 'alpha-two\.sh' is out of order.*it follows 'alpha\.sh'" \
  write_prefix_pair_tools_doc "$ROW_ALPHA" "$ROW_ALPHA_TWO" "$ROW_BETA" "$ROW_GAMMA"

expect "marked doc passes with the byte-order pair the right way round" 0 \
  'scripts-catalog-lint: OK \(5 entries across 2 category docs\)' \
  write_prefix_pair_tools_doc "$ROW_ALPHA_TWO" "$ROW_ALPHA" "$ROW_BETA" "$ROW_GAMMA"

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

# --- normalize_relpath contract -------------------------------------------
# The path keying above is only as sound as the normalizer under it, and the
# lint itself exercises just two target shapes. These pin the rest of the
# contract, including the two forms that would corrupt a key silently: a
# segment holding a glob character (an unquoted IFS split would expand it
# against the cwd) and a '..' that escapes the base (droppable only when the
# path is absolute).
errors=0  # lint-common.sh's caller contract; unused by these cases.
# shellcheck source=.github/scripts/lib/lint-common.sh
source "${REPO_ROOT}/.github/scripts/lib/lint-common.sh"

normalize_case() {
  local base="$1" target="$2" want="$3" got
  got=$(normalize_relpath "$base" "$target")
  if [[ "$got" == "$want" ]]; then
    echo "ok   — normalize_relpath '${base}' '${target}' -> ${want}"
  else
    echo "FAIL — normalize_relpath '${base}' '${target}': expected '${want}', got '${got}'"
    failures=$((failures + 1))
  fi
}

normalize_case ".claude/scripts/docs" "../foo.sh"           ".claude/scripts/foo.sh"
normalize_case ".claude/scripts/docs" "../tests/foo.test.sh" ".claude/scripts/tests/foo.test.sh"
normalize_case ".claude/scripts"      "docs/../foo.sh"       ".claude/scripts/foo.sh"
normalize_case ".claude/scripts"      "./docs/./tools.md"    ".claude/scripts/docs/tools.md"
normalize_case ".claude/scripts/docs" "..//..///x.sh"        ".claude/x.sh"
normalize_case ".claude/scripts/docs" "../tools.md/"         ".claude/scripts/tools.md"
normalize_case ""                     ".claude/scripts/a.sh" ".claude/scripts/a.sh"
normalize_case "."                    "foo.sh"               "foo.sh"
normalize_case "a/b"                  "c/*/d.sh"             "a/b/c/*/d.sh"
normalize_case "a/b"                  "../../../../up.sh"    "../../up.sh"
normalize_case "a/b"                  "../.."                "."
normalize_case "a/b"                  "/abs/path.sh"         "/abs/path.sh"
normalize_case "/tmp/x"               "../y.sh"              "/tmp/y.sh"
normalize_case "/"                    "../../etc"            "/etc"

# --- real repo: the row-ordering opt-in is actually in effect --------------
# The sanity run below passes whether or not any doc carries the marker, so on
# its own it cannot tell an enforced tests.md from an unmarked one — a green
# check that never ran. Assert the marker is where the decision put it, and
# nowhere else: the 12 sibling docs stay unmarked by design (issue #1544).
#
# Read the marker the way the lint does — outside any fence. A plain grep is
# wrong in both directions here: it would call a sibling that merely documents
# the marker inside a fence opted in and redden CI on a correct tree, and it
# would go on reporting tests.md as marked if that marker ever moved inside a
# fence, leaving the ordering unenforced behind this very assertion.
effective_marker_docs() {
  local doc
  for doc in "$@"; do
    # Fence skip mirrors AWK_DOC_PRELUDE; the probes below pin the two apart.
    if awk -v marker="$ORDERED_MARKER" '
      /^[[:space:]]*(```|~~~)/ {
        fence_tok = ($0 ~ /^[[:space:]]*```/) ? "```" : "~~~"
        if (!in_fence) { in_fence = 1; fence = fence_tok }
        else if (fence_tok == fence) { in_fence = 0; fence = "" }
        next
      }
      in_fence { next }
      index($0, marker) > 0 { found = 1 }
      END { if (found) exit 0; exit 1 }
    ' "$doc"; then
      printf '%s\n' "$doc"
    fi
  done
}

# The reader above is a second copy of semantics the lint owns, so pin it
# against the same three shapes the fixture cases pin the lint against. Without
# these it could rot back into a plain grep without anything going red.
marker_probe="${TMP_ROOT}/marker-probe.md"
probe_marker() {
  local name="$1" body="$2" want="$3" got
  printf '%s\n' "$body" > "$marker_probe"
  got=$(effective_marker_docs "$marker_probe")
  if [[ "$got" == "$want" ]]; then
    echo "ok   — marker reader: ${name}"
  else
    echo "FAIL — marker reader: ${name}: expected '${want:-<none>}', got '${got:-<none>}'"
    failures=$((failures + 1))
  fi
}
probe_marker "a bare marker opts in"                "$ORDERED_MARKER"    "$marker_probe"
probe_marker "a fenced marker does not"             "$FENCED_MARKER"     ""
probe_marker "a marker below a fence still opts in" "$FENCE_THEN_MARKER" "$marker_probe"

marked_docs=$(effective_marker_docs "${REPO_ROOT}"/.claude/scripts/docs/*.md)
if [[ "$marked_docs" == "${REPO_ROOT}/.claude/scripts/docs/tests.md" ]]; then
  echo "ok   — tests.md is the only category doc opted in to row ordering"
else
  echo "FAIL — expected only .claude/scripts/docs/tests.md to carry the ordering marker"
  echo "       got: ${marked_docs:-<none>}"
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
