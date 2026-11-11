#!/usr/bin/env bash
# Verify the desk documentation lint rejects index and link regressions.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/.github/scripts" "$TMP/.claude/reference" "$TMP/desk/docs"
cp "$SCRIPT_DIR/desk-docs-index-lint.sh" "$TMP/.github/scripts/"
LINT="$TMP/.github/scripts/desk-docs-index-lint.sh"

cat > "$TMP/desk/README.md" <<'MD'
# Desk
<!-- desk-docs-index:start -->
- <a name="old-section"></a>[Feature](docs/feature.md)
  - [Details](docs/feature.md#details)
<!-- desk-docs-index:end -->
MD
cat > "$TMP/desk/docs/feature.md" <<'MD'
## Feature
### Details
~~~text
~~~example
### Example heading
[An example link](feature.md#ignored)
~~~
### After the fence
MD
cat > "$TMP/.claude/reference/consumer.md" <<'MD'
[Old section](../../desk/README.md#old-section)
[Moved section](../../desk/docs/feature.md#details)
[After the fence][desk-details]

[desk-details]: <../../desk/docs/feature.md#after-the-fence> "Details"
MD
git -C "$TMP" init -q
git -C "$TMP" add .claude desk
"$LINT"
cp "$TMP/desk/README.md" "$TMP/readme.valid"

fail_lint() {
  local expected="$1"
  if "$LINT" > "$TMP/out" 2>&1; then
    printf 'FAIL: expected lint rejection for %s\n' "$expected" >&2
    exit 1
  fi
  grep -F "$expected" "$TMP/out"
}

printf '## Omitted\n' > "$TMP/desk/docs/omitted.md"
fail_lint "must index docs/omitted.md exactly once (found 0)"
rm "$TMP/desk/docs/omitted.md"

awk '/\[Feature\]/ {print} {print}' "$TMP/readme.valid" > "$TMP/desk/README.md"
fail_lint "must index docs/feature.md exactly once (found 2)"
cp "$TMP/readme.valid" "$TMP/desk/README.md"

printf '[Broken link](../../desk/README.md#absent)\n' > "$TMP/.claude/reference/consumer.md"
fail_lint "links to missing desk fragment ../../desk/README.md#absent"
printf '[Broken link](../../desk/docs/feature.md#absent)\n' > "$TMP/.claude/reference/consumer.md"
fail_lint "links to missing desk fragment ../../desk/docs/feature.md#absent"
printf '[Broken link](<../../desk/docs/feature.md#absent> "Title")\n' > "$TMP/.claude/reference/consumer.md"
fail_lint "links to missing desk fragment ../../desk/docs/feature.md#absent"
cat > "$TMP/.claude/reference/consumer.md" <<'MD'
[Broken link][desk-example]

[desk-example]:
  ../../desk/docs/feature.md#example-heading 'Example heading'
MD
fail_lint "links to missing desk fragment ../../desk/docs/feature.md#example-heading"
