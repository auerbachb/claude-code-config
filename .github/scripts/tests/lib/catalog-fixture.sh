#!/usr/bin/env bash
# Shared fixture builder for the .claude/scripts/ catalog suites (issue #1578).
# Source this file; do NOT execute it directly.
#
# This file intentionally does not end in .test.sh so run-hook-tests.sh will not
# execute it as a standalone test suite.
#
# Requires the caller to export CATALOG_GEN (the absolute path to
# scripts-catalog-gen.sh) before building a non-empty fixture: that is the
# script make_catalog_fixture runs to bring the fixture's regions up to date.
#
# Provides:
#   make_catalog_fixture DIR [--empty-regions]
#     Builds a complete, well-formed miniature catalog under DIR: two shell
#     scripts and a Python helper in the `tools` category, one test suite in the
#     `tests` category, an index, and a churn-hotspot exemption file. With
#     --empty-regions the generated regions are left empty, which is the state a
#     freshly authored doc is in before the first `--write`.
#
#     Also seeds the out-of-scope files (lib/, tests/lib/, tests/fixtures/, a
#     .plist) that must NOT require a declaration. A catalog tool that started
#     demanding rows for those would redden CI on a correct tree, so every suite
#     that builds a fixture builds them too.
#
#   catalog_script DIR REL CATEGORY DESCRIPTION
#     Writes an in-scope shell script at DIR/REL carrying the header
#     declaration. Used to add files to a fixture mid-case.
#
#   catalog_py DIR REL CATEGORY DESCRIPTION
#     The same, for a Python helper — its declaration sits directly after the
#     shebang, ahead of the module docstring.
#
# Fixtures are always disposable trees under mktemp; nothing here writes to the
# repository being tested.

# catalog_script DIR REL CATEGORY DESCRIPTION
catalog_script() {
  local dir="$1" rel="$2" category="$3" desc="$4"
  mkdir -p "$(dirname "$dir/$rel")"
  {
    printf '#!/usr/bin/env bash\n'
    printf '# %s — a fixture script.\n' "$(basename "$rel")"
    printf '# catalog: %s — %s\n' "$category" "$desc"
    printf '\nset -euo pipefail\n'
  } > "$dir/$rel"
}

# catalog_py DIR REL CATEGORY DESCRIPTION
catalog_py() {
  local dir="$1" rel="$2" category="$3" desc="$4"
  mkdir -p "$(dirname "$dir/$rel")"
  {
    printf '#!/usr/bin/env python3\n'
    printf '# catalog: %s — %s\n' "$category" "$desc"
    printf '"""A fixture helper."""\n'
  } > "$dir/$rel"
}

make_catalog_fixture() {
  local dir="$1" mode="${2:-}"
  mkdir -p "$dir/.claude/scripts/docs" \
           "$dir/.claude/scripts/tests" \
           "$dir/.claude/scripts/lib" \
           "$dir/.claude/scripts/tests/lib" \
           "$dir/.claude/scripts/tests/fixtures" \
           "$dir/.claude/reference"

  catalog_script "$dir" ".claude/scripts/alpha.sh"            tools "First"
  catalog_script "$dir" ".claude/scripts/gamma.sh"            tools "Third"
  catalog_py     "$dir" ".claude/scripts/beta.py"             tools "Second"
  catalog_script "$dir" ".claude/scripts/tests/alpha.test.sh" tests "Covers alpha"

  # Out of scope on purpose.
  printf '#!/usr/bin/env bash\n' > "$dir/.claude/scripts/lib/helper.sh"
  printf '.x\n'                  > "$dir/.claude/scripts/lib/program.jq"
  printf '#!/usr/bin/env bash\n' > "$dir/.claude/scripts/tests/lib/fixtures.sh"
  printf 'fixture\n'             > "$dir/.claude/scripts/tests/fixtures/sample.md"
  printf '<plist/>\n'            > "$dir/.claude/scripts/com.example.thing.plist"

  cat > "$dir/.claude/scripts/docs/tools.md" <<'EOF'
# Tools

<!-- catalog:category id=tools order=10 -->
<!-- catalog:covers Scripts that do tool things -->

Scripts that do tool things.

| Script | Purpose |
|--------|---------|
<!-- catalog:rows:begin -->
<!-- catalog:rows:end -->

## Python helpers

| Script | Purpose |
|--------|---------|
<!-- catalog:rows:begin kind=py -->
<!-- catalog:rows:end -->

---

[back to the index](../README.md)
EOF

  cat > "$dir/.claude/scripts/docs/tests.md" <<'EOF'
# Tests

<!-- catalog:category id=tests order=20 -->
<!-- catalog:covers Every test under tests/ -->

All tests live in tests/ and run offline.

| Test | What it covers |
|------|----------------|
<!-- catalog:rows:begin -->
<!-- catalog:rows:end -->

---

[back to the index](../README.md)
EOF

  cat > "$dir/.claude/scripts/README.md" <<'EOF'
# .claude/scripts/

Index only.

## Categories

| Category | Covers |
|----------|--------|
<!-- catalog:categories:begin -->
<!-- catalog:categories:end -->

## scripts/ vs hooks/

Nothing to see here.
EOF

  cat > "$dir/.claude/reference/churn-hotspot-exemptions.json" <<'EOF'
{
  "schema": "churn-hotspot-exemptions/v1",
  "source": {
    "issue": 1571,
    "provenance": "lint-enforced-catalog",
    "note": "Fixture."
  },
  "exemptions": {
    "docs/hand-written.md": {
      "lint": "some-other-lint.sh",
      "reason": "Hand-written entry the generator must preserve verbatim."
    }
  }
}
EOF

  # Unless the caller wants the pre-generation state, hand back a fixture whose
  # committed regions already match — every "does X break it" case then starts
  # from a tree that passes, so a failure is attributable to the mutation.
  if [[ "$mode" != "--empty-regions" ]]; then
    ( cd "$dir" && bash "$CATALOG_GEN" --write >/dev/null )
  fi
}
