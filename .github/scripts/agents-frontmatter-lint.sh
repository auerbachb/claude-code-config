#!/usr/bin/env bash
# Lint the frontmatter of every .claude/agents/*.md agent definition file.
#
# Validates (per the Claude Code sub-agents schema and issue #1121):
#   1. Each file has a `name:` field in frontmatter.
#   2. Each file has a `description:` field in frontmatter.
#   3. The `name:` value matches the filename stem exactly (identity source).
#   4. No file uses the deprecated `allowed-tools:` key (use `tools:` instead).
#
# Output uses GitHub Actions annotations (::error::) so issues surface
# directly on PR checks. Exits 1 on any error condition.
#
# Run from the repo root.

set -euo pipefail
shopt -s nullglob

AGENTS_DIR=".claude/agents"
errors=0

usage() {
  cat <<'EOF'
Usage: .github/scripts/agents-frontmatter-lint.sh

  Verifies all .claude/agents/*.md files carry required frontmatter.
  No options. Run from the repo root. Exits 1 on any error.
EOF
}

while (( $# > 0 )); do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "::error::Unknown argument: $1"
      usage >&2
      exit 2
      ;;
  esac
  shift
done

if [[ ! -d "$AGENTS_DIR" ]]; then
  echo "::error::${AGENTS_DIR} directory not found — run from repo root"
  exit 1
fi

# Extract the frontmatter block (between first --- and second ---) from a file.
# Prints only the frontmatter lines (not the delimiters).
# Exits 1 if the opening --- is present but the closing --- is never found
# (unterminated frontmatter), so callers can detect malformed files.
extract_frontmatter() {
  local file="$1"
  awk 'NR==1 && /^---/ { in_fm=1; next }
       in_fm && /^---/ { terminated=1; exit }
       in_fm { print }
       END { if (in_fm && !terminated) exit 1 }' "$file"
}

checked=0

for file in "${AGENTS_DIR}"/*.md; do
  stem=$(basename "$file" .md)

  # README.md is documentation, not an agent definition — skip it.
  if [[ "$stem" == "README" ]]; then
    continue
  fi

  if ! fm=$(extract_frontmatter "$file"); then
    echo "::error file=${file}::${file} has unterminated frontmatter (missing closing '---')"
    errors=$((errors + 1))
    continue
  fi
  checked=$((checked + 1))

  # 1. name: present
  if ! grep -qE '^name:' <<< "$fm"; then
    echo "::error file=${file}::${file} is missing a 'name:' frontmatter field (required for subagent_type resolution)"
    errors=$((errors + 1))
  else
    # 3. name: value matches filename stem
    name_val=$(grep -E '^name:' <<< "$fm" | head -1 | sed 's/^name:[[:space:]]*//')
    if [[ "$name_val" != "$stem" ]]; then
      echo "::error file=${file}::${file}: name: '${name_val}' does not match filename stem '${stem}' — subagent_type must match name: exactly"
      errors=$((errors + 1))
    fi
  fi

  # 2. description: present
  if ! grep -qE '^description:' <<< "$fm"; then
    echo "::error file=${file}::${file} is missing a 'description:' frontmatter field (required)"
    errors=$((errors + 1))
  fi

  # 4. deprecated allowed-tools: key
  if grep -qE '^allowed-tools:' <<< "$fm"; then
    echo "::error file=${file}::${file} uses deprecated 'allowed-tools:' key — rename to 'tools:' per the current schema"
    errors=$((errors + 1))
  fi
done

if (( checked == 0 )); then
  echo "::error::No agent definition files found in ${AGENTS_DIR}/ (excluding README.md)"
  exit 1
fi

if (( errors > 0 )); then
  echo "agents-frontmatter-lint: ${errors} error(s) found across ${checked} files"
  exit 1
fi

echo "agents-frontmatter-lint: OK (${checked} files)"
