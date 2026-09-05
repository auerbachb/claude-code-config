#!/usr/bin/env bash
# Unit tests for scripts-catalog-gen.sh (issue #1578)
#
# The generator reads repo-root-relative paths, so each case builds a throwaway
# fixture tree and runs the script against it. Every fixture lives under a
# mktemp root and the real repository is only ever READ — the last case runs
# `--check` against it, which writes nothing.
#
# Every failure mode gets an explicit case. A generator asserted only on
# well-formed input would pass without proving it refuses anything, and this one
# has taken over five checks the lint used to perform: a silent miss here is a
# catalog nobody validates.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
CATALOG_GEN="${REPO_ROOT}/.github/scripts/scripts-catalog-gen.sh"
export CATALOG_GEN

# shellcheck source=lib/catalog-fixture.sh
source "${REPO_ROOT}/.github/scripts/tests/lib/catalog-fixture.sh"

TMP_ROOT=$(mktemp -d -t scripts-catalog-gen.XXXXXX)
trap 'rm -rf "$TMP_ROOT"' EXIT

failures=0
case_num=0

ok()  { echo "ok   — $1"; }
bad() { echo "FAIL — $1"; failures=$((failures + 1)); }

check() {
  local name="$1" got="$2" want="$3"
  if [[ "$got" == "$want" ]]; then ok "$name"; else
    bad "$name: expected '${want}', got '${got}'"
  fi
}

# new_case [--empty-regions] — builds a fresh fixture and assigns $dir.
# Call it as a bare statement. A command substitution would run the function in a
# subshell, so the case counter would increment only there and never advance
# here, and every case would build into — and inherit the mutations of — one
# shared directory.
new_case() {
  case_num=$((case_num + 1))
  dir="${TMP_ROOT}/case${case_num}"
  make_catalog_fixture "$dir" "${1:-}"
}

# expect NAME WANT_EXIT WANT_REGEX DIR ARGS...
# Asserts BOTH the exit status and that the output matches the regex. Asserting
# the message too is what stops a case passing on an unrelated error — a typo or
# a syntax break also exits non-zero and would otherwise look like a pass.
expect() {
  local name="$1" want="$2" want_re="$3" dir="$4"; shift 4
  local out got
  out=$(cd "$dir" && bash "$CATALOG_GEN" "$@" 2>&1) && got=0 || got=$?
  if (( got != want )); then
    bad "${name}: expected exit ${want}, got ${got}"
    printf '%s\n' "$out" | sed 's/^/       /'
    return
  fi
  if ! grep -qE -- "$want_re" <<< "$out"; then
    bad "${name}: exit ${got} as expected, but output did not match /${want_re}/"
    printf '%s\n' "$out" | sed 's/^/       /'
    return
  fi
  ok "$name"
}

# --- CLI contract ---------------------------------------------------------
new_case
expect "--help exits 0" 0 'Usage: .*scripts-catalog-gen\.sh' "$dir" --help
expect "unknown argument exits 2" 2 'Unknown argument' "$dir" --bogus
expect "no mode exits 2" 2 'exactly one of --check or --write' "$dir"
expect "--root with no value exits 2" 2 '--root requires a value' "$dir" --check --root
expect "--check and --write together exit 2" 2 'mutually exclusive' "$dir" --check --write
expect "a repeated mode is accepted" 0 'no drift' "$dir" --check --check

# --root with a value: the generator must read the tree it names and report paths
# relative to THAT root, not to whatever cwd it happens to run in.
new_case
(cd / && bash "$CATALOG_GEN" --check --root "$dir" >/dev/null 2>&1) \
  && root_rc=0 || root_rc=$?
check "--root <abs> checks the named tree from an unrelated cwd" "$root_rc" "0"

new_case
printf '#!/usr/bin/env bash\n# stray.sh — undeclared.\n' > "$dir/.claude/scripts/stray.sh"
root_out=$(cd / && bash "$CATALOG_GEN" --check --root "$dir" 2>&1) || true
if grep -q 'file=\.claude/scripts/stray\.sh::' <<< "$root_out"; then
  ok "--root reports repo-root-relative paths, with the root prefix stripped"
else
  bad "--root reports repo-root-relative paths, with the root prefix stripped"
  printf '%s\n' "$root_out" | sed 's/^/       /'
fi

# --- write / check round trip --------------------------------------------
new_case --empty-regions
expect "--check on an ungenerated tree reports drift" 1 \
  'committed catalog region is stale' "$dir" --check
expect "--write fills the regions" 0 'scripts-catalog-gen: OK' "$dir" --write
expect "--check passes after --write" 0 'no drift' "$dir" --check
expect "--write is idempotent" 0 'scripts-catalog-gen: OK' "$dir" --write

# --- grouping by category id ---------------------------------------------
new_case
if grep -q '^| \[alpha\.sh\](\.\./alpha\.sh) | First |$' "$dir/.claude/scripts/docs/tools.md" \
   && grep -q '^| \[alpha\.test\.sh\](\.\./tests/alpha\.test\.sh) | Covers alpha |$' "$dir/.claude/scripts/docs/tests.md"; then
  ok "each row lands in the doc its category id names"
else
  bad "each row lands in the doc its category id names"
fi
if grep -q 'alpha\.test\.sh' "$dir/.claude/scripts/docs/tools.md"; then
  bad "a row leaked into a doc that does not own it"
else
  ok "no row leaks into a doc that does not own it"
fi

# kind=py: the Python helper belongs to the tools category but must land in the
# kind=py region, not beside the shell scripts.
sh_region=$(sed -n '/catalog:rows:begin -->/,/catalog:rows:end/p' "$dir/.claude/scripts/docs/tools.md")
py_region=$(sed -n '/catalog:rows:begin kind=py/,/catalog:rows:end/p' "$dir/.claude/scripts/docs/tools.md")
if grep -q 'beta\.py' <<< "$py_region" && ! grep -q 'beta\.py' <<< "$sh_region"; then
  ok "a .py helper lands in the kind=py region, not the sh one"
else
  bad "a .py helper lands in the kind=py region, not the sh one"
fi

# --- deterministic ordering ----------------------------------------------
new_case
catalog_script "$dir" ".claude/scripts/tests/overrun-check.test.sh" tests "Later"
catalog_script "$dir" ".claude/scripts/tests/overrun-check-tzdata.test.sh" tests "Earlier"
( cd "$dir" && bash "$CATALOG_GEN" --write >/dev/null )
order=$(sed -n 's/^| \[\([^]]*\)\].*/\1/p' "$dir/.claude/scripts/docs/tests.md" | tr '\n' ' ')
# LC_ALL=C byte order, not dictionary order: '-' (0x2D) sorts before '.' (0x2E).
check "rows are emitted in LC_ALL=C byte order" \
  "$order" "alpha.test.sh overrun-check-tzdata.test.sh overrun-check.test.sh "

# A '|' in a description would split the markdown table if it reached the row
# unescaped, silently corrupting every column after it.
new_case
catalog_script "$dir" ".claude/scripts/piped.sh" tools 'Handles a | b | c alternatives'
( cd "$dir" && bash "$CATALOG_GEN" --write >/dev/null )
if grep -qF '| [piped.sh](../piped.sh) | Handles a \| b \| c alternatives |' \
     "$dir/.claude/scripts/docs/tools.md"; then
  ok "a pipe in a description is escaped rather than splitting the table"
else
  bad "a pipe in a description is escaped rather than splitting the table"
  grep -F 'piped.sh' "$dir/.claude/scripts/docs/tools.md" | sed 's/^/       /'
fi
expect "the escaped row is stable across a re-check" 0 'no drift' "$dir" --check

new_case
jq -n '"not an object"' > "$dir/.claude/reference/churn-hotspot-exemptions.json"
expect "a non-object exemption file fails on its own terms" 1 \
  'not a JSON object carrying an' "$dir" --check

new_case
jq 'del(.exemptions)' "$dir/.claude/reference/churn-hotspot-exemptions.json" > "$dir/tmp" \
  && mv "$dir/tmp" "$dir/.claude/reference/churn-hotspot-exemptions.json"
expect "an exemption file with no exemptions object fails on its own terms" 1 \
  'not a JSON object carrying an' "$dir" --check

# --- prose, table headers and back-links survive -------------------------
new_case --empty-regions
before=$(grep -c . "$dir/.claude/scripts/docs/tools.md")
( cd "$dir" && bash "$CATALOG_GEN" --write >/dev/null )
for needle in '^# Tools$' '^Scripts that do tool things\.$' '^| Script | Purpose |$' \
              '^## Python helpers$' '^\[back to the index\]\(\.\./README\.md\)$'; do
  if grep -qE "$needle" "$dir/.claude/scripts/docs/tools.md"; then
    ok "human-edited line survives generation: ${needle}"
  else
    bad "human-edited line survives generation: ${needle}"
  fi
done
if (( $(grep -c . "$dir/.claude/scripts/docs/tools.md") > before )); then
  ok "generation added rows rather than replacing the document"
else
  bad "generation added rows rather than replacing the document"
fi

# --- declaration failures -------------------------------------------------
new_case
printf '#!/usr/bin/env bash\n# undeclared.sh — no catalog line.\n' > "$dir/.claude/scripts/undeclared.sh"
expect "a file with no '# catalog:' line is refused" 1 \
  "no '# catalog: <category-id>" "$dir" --check

new_case
printf '#!/usr/bin/env bash\n# catalog: tools\n' > "$dir/.claude/scripts/broken.sh"
expect "a declaration with no description is refused" 1 \
  "malformed '# catalog:' line" "$dir" --check

new_case
catalog_script "$dir" ".claude/scripts/orphan.sh" nosuchcategory "Orphan"
expect "a category id with no doc is refused" 1 \
  "does not match any doc" "$dir" --check

# A `# catalog:` string in the BODY of a script is not a declaration: only the
# leading comment region is read. Without that bound a heredoc or an error
# message quoting the format would silently become the file's category.
new_case
{
  printf '#!/usr/bin/env bash\n# body-only.sh — declaration is in the body.\n'
  printf 'set -euo pipefail\n'
  printf 'echo "# catalog: tools — not a declaration"\n'
} > "$dir/.claude/scripts/body-only.sh"
expect "a '# catalog:' line in the script body is not a declaration" 1 \
  "no '# catalog: <category-id>" "$dir" --check

# --- doc-side failures ----------------------------------------------------
new_case
grep -v 'catalog:category' "$dir/.claude/scripts/docs/tools.md" > "$dir/tmp" \
  && mv "$dir/tmp" "$dir/.claude/scripts/docs/tools.md"
expect "a doc with no category declaration is refused" 1 \
  'no <!-- catalog:category' "$dir" --check

new_case
sed 's/id=tests order=20/id=tools order=20/' "$dir/.claude/scripts/docs/tests.md" > "$dir/tmp" \
  && mv "$dir/tmp" "$dir/.claude/scripts/docs/tests.md"
expect "a doc whose id does not match its filename is refused" 1 \
  'the id must be the filename stem' "$dir" --check

new_case
grep -v 'catalog:rows:' "$dir/.claude/scripts/docs/tests.md" > "$dir/tmp" \
  && mv "$dir/tmp" "$dir/.claude/scripts/docs/tests.md"
expect "a doc with no rows region is refused" 1 \
  'no <!-- catalog:rows:begin' "$dir" --check

# A .py file whose category doc carries no kind=py region has a valid
# declaration and an existing doc — without the unplaced check its row would
# simply vanish from the catalog with no diagnostic at all.
new_case
catalog_py "$dir" ".claude/scripts/stray.py" tests "Python in a doc with no py region"
expect "a file no region accepts is refused, not dropped" 1 \
  'no catalog row region accepts this file' "$dir" --check

new_case
grep -v 'catalog:rows:end' "$dir/.claude/scripts/docs/tests.md" > "$dir/tmp" \
  && mv "$dir/tmp" "$dir/.claude/scripts/docs/tests.md"
expect "a rows region that never closes is refused" 1 \
  'unbalanced, nested, or names a kind' "$dir" --check

# --- markers inside a fenced block are examples, not regions --------------
# A doc that documents the marker syntax must not have its example rewritten as
# a real region. The catalog lint applies the same fence rule when it hunts for
# stray rows, so a marker one side treats as real and the other as an example
# would be a doc neither of them checks.
new_case
cat >> "$dir/.claude/scripts/docs/tools.md" <<'FENCE'

Example, not a region:

```markdown
<!-- catalog:rows:begin -->
| [example.sh](../example.sh) | Example row |
<!-- catalog:rows:end -->
```
FENCE
expect "a fenced marker example is not treated as a region" 0 'no drift' "$dir" --check
if grep -q '| \[example\.sh\](\.\./example\.sh) | Example row |' "$dir/.claude/scripts/docs/tools.md"; then
  ok "the fenced example row survives regeneration verbatim"
else
  bad "the fenced example row survives regeneration verbatim"
fi

# A category declaration shown inside a fence must not declare a category —
# otherwise a doc explaining the format would silently claim an id.
new_case
cp "$dir/.claude/scripts/docs/tools.md" "$dir/.claude/scripts/docs/guide.md"
python3 - "$dir/.claude/scripts/docs/guide.md" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
s = p.read_text()
s = s.replace("<!-- catalog:category id=tools order=10 -->",
              "```markdown\n<!-- catalog:category id=guide order=15 -->\n```")
p.write_text(s)
PY
expect "a fenced category declaration does not declare a category" 1 \
  'no <!-- catalog:category' "$dir" --check

# --- an unreadable in-scope file is its own diagnostic --------------------
# Folding an I/O error into "no declaration" would report a file that could not
# be examined as a file that was examined and found wanting.
# Root ignores the mode bits, so under uid 0 the file stays readable and the
# case would assert the wrong thing. Skipped rather than silently inverted.
if [[ "$(id -u)" == "0" ]]; then
  echo "skip — unreadable-file case needs a non-root uid"
else
  new_case
  chmod 000 "$dir/.claude/scripts/gamma.sh"
  expect "an unreadable in-scope file is reported as unreadable" 1 \
    'could not be read while looking for' "$dir" --check
  chmod 644 "$dir/.claude/scripts/gamma.sh"
fi

# --- drift detection ------------------------------------------------------
new_case
grep -v 'gamma\.sh' "$dir/.claude/scripts/docs/tools.md" > "$dir/tmp" \
  && mv "$dir/tmp" "$dir/.claude/scripts/docs/tools.md"
expect "a deleted row is drift" 1 \
  'docs/tools\.md::committed catalog region is stale' "$dir" --check

new_case
sed 's/| First |/| Edited by hand |/' "$dir/.claude/scripts/docs/tools.md" > "$dir/tmp" \
  && mv "$dir/tmp" "$dir/.claude/scripts/docs/tools.md"
expect "a hand-edited description inside the region is drift" 1 \
  'committed catalog region is stale' "$dir" --check
( cd "$dir" && bash "$CATALOG_GEN" --write >/dev/null )
expect "--write repairs hand-edited drift" 0 'no drift' "$dir" --check

new_case
sed 's/| \[Tests\](docs\/tests\.md).*/| [Tests](docs\/tests.md) | Stale summary |/' \
  "$dir/.claude/scripts/README.md" > "$dir/tmp" && mv "$dir/tmp" "$dir/.claude/scripts/README.md"
expect "a stale index Categories table is drift" 1 \
  'README\.md::committed catalog region is stale' "$dir" --check

# --- the acceptance criterion: adding a script edits one file -------------
# The whole point of the change. A new script plus a regenerate must leave every
# other human-edited file byte-identical; only the generated regions move.
new_case
snapshot="$TMP_ROOT/snapshot-$case_num"
mkdir -p "$snapshot"
cp "$dir/.claude/scripts/docs/tests.md" "$snapshot/tests.md"
cp "$dir/.claude/scripts/README.md" "$snapshot/README.md"
catalog_script "$dir" ".claude/scripts/delta.sh" tools "A brand new script"
( cd "$dir" && bash "$CATALOG_GEN" --write >/dev/null )
if grep -q '^| \[delta\.sh\](\.\./delta\.sh) | A brand new script |$' "$dir/.claude/scripts/docs/tools.md"; then
  ok "adding a script needs only its own header plus a regenerate"
else
  bad "adding a script needs only its own header plus a regenerate"
fi
if cmp -s "$snapshot/tests.md" "$dir/.claude/scripts/docs/tests.md" \
   && cmp -s "$snapshot/README.md" "$dir/.claude/scripts/README.md"; then
  ok "adding a script touches no other catalog file"
else
  bad "adding a script touches no other catalog file"
fi

# --- exemption entries ----------------------------------------------------
new_case
EX="$dir/.claude/reference/churn-hotspot-exemptions.json"
got=$(jq -r '.exemptions | keys | join(",")' "$EX")
check "an exemption entry exists for the index and every category doc" "$got" \
  ".claude/scripts/README.md,.claude/scripts/docs/tests.md,.claude/scripts/docs/tools.md,docs/hand-written.md"
check "generated entries are stamped" \
  "$(jq -r '.exemptions[".claude/scripts/docs/tests.md"].generated_by' "$EX")" \
  ".github/scripts/scripts-catalog-gen.sh"
check "generated entries name a non-empty enforcing lint" \
  "$(jq -r '.exemptions[".claude/scripts/docs/tests.md"].lint | test("\\S")' "$EX")" "true"
check "generated entries carry a non-empty reason" \
  "$(jq -r '.exemptions[".claude/scripts/docs/tests.md"].reason | test("\\S")' "$EX")" "true"
check "a hand-written entry is preserved verbatim" \
  "$(jq -r '.exemptions["docs/hand-written.md"].reason' "$EX")" \
  "Hand-written entry the generator must preserve verbatim."
check "a hand-written entry is not stamped" \
  "$(jq -r '.exemptions["docs/hand-written.md"].generated_by // "absent"' "$EX")" "absent"
check "the hand-written source block is untouched" \
  "$(jq -r '.source.note' "$EX")" "Fixture."

# as_of is carried forward from the committed entry, so a re-run on an unchanged
# tree is a no-op rather than a date churn of its own.
jq '.exemptions[".claude/scripts/docs/tests.md"].as_of = "2020-01-01"' "$EX" > "$dir/tmp" \
  && mv "$dir/tmp" "$EX"
( cd "$dir" && bash "$CATALOG_GEN" --write >/dev/null )
check "as_of is carried forward from the committed entry" \
  "$(jq -r '.exemptions[".claude/scripts/docs/tests.md"].as_of' "$EX")" "2020-01-01"
expect "a re-run on an unchanged tree reports no drift" 0 'no drift' "$dir" --check

# A new catalog file gets today's date and shows up as drift until written —
# which is exactly what --check is for.
new_case
cp "$dir/.claude/scripts/docs/tests.md" "$dir/.claude/scripts/docs/extra.md"
sed 's/id=tests order=20/id=extra order=30/' "$dir/.claude/scripts/docs/extra.md" > "$dir/tmp" \
  && mv "$dir/tmp" "$dir/.claude/scripts/docs/extra.md"
expect "a new category doc surfaces as exemption drift" 1 \
  'churn-hotspot-exemptions\.json::committed catalog region is stale' "$dir" --check

# --- duplicate rows regions ------------------------------------------------
# Two regions of the same kind in one doc would each be filled with the same
# rows, listing every script twice — and --check could never report it, because
# regeneration reproduces the duplication exactly. The generator refuses instead.
new_case
awk '
  /<!-- catalog:rows:begin -->/ && !done {
    print; print "<!-- catalog:rows:end -->"
    print ""
    print "| Script | Purpose |"
    print "|--------|---------|"
    print "<!-- catalog:rows:begin -->"
    done = 1
    next
  }
  { print }
' "$dir/.claude/scripts/docs/tools.md" > "$dir/tmp" && mv "$dir/tmp" "$dir/.claude/scripts/docs/tools.md"
expect "a second region of the same kind is refused" 1 \
  'more than one <!-- catalog:rows:begin kind=sh --> region' "$dir" --check
expect "the same duplication is refused by --write too" 1 \
  'more than one <!-- catalog:rows:begin kind=sh --> region' "$dir" --write

# NEGATIVE CONTROL: two regions of DIFFERENT kinds is the normal shape every
# category doc with Python helpers already uses, and must stay accepted —
# otherwise the check above could pass by rejecting every multi-region doc.
new_case
expect "two regions of different kinds are still accepted" 0 'no drift' "$dir" --check

# --- out-of-scope files need no declaration -------------------------------
new_case
printf '#!/usr/bin/env bash\n' > "$dir/.claude/scripts/lib/new-helper.sh"
printf '#!/usr/bin/env bash\n' > "$dir/.claude/scripts/tests/lib/new-fixture.sh"
printf 'notes\n'               > "$dir/.claude/scripts/tests/fixtures/new.md"
printf '<plist/>\n'            > "$dir/.claude/scripts/com.example.other.plist"
expect "out-of-scope files need no declaration" 0 'no drift' "$dir" --check

# --- real repo ------------------------------------------------------------
# Read-only: --check regenerates into a temp buffer and writes nothing.
if (cd "$REPO_ROOT" && bash "$CATALOG_GEN" --check >/dev/null 2>&1); then
  ok "real repo catalog is generated and in sync"
else
  bad "generator reports drift against the real repo"
  (cd "$REPO_ROOT" && bash "$CATALOG_GEN" --check 2>&1 | sed 's/^/       /') || true
fi

if (( failures > 0 )); then
  echo "scripts-catalog-gen.test.sh: ${failures} failure(s)"
  exit 1
fi
echo "scripts-catalog-gen.test.sh: all checks passed"
