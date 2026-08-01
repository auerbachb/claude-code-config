#!/usr/bin/env bash
# Lint env-template allowlist conformance across agent prompts and canonical rule (issue #877).
#
# Six agent/skill prompt surfaces embed the .env template-exception clause.
# This lint ensures they all say the same thing as the canonical allow-list
# (example|sample|template) enforced at runtime by:
#   .claude/hooks/env-guard.py  TEMPLATE_SUFFIXES = frozenset({'example','sample','template'})
#
# Validates:
#   1. Every prompt surface carries the three-suffix token: .env.<example|sample|template>
#   2. No prompt surface carries a drifted token introducing "dist" or "tpl".
#   3. safety.md carries its own three-suffix prose form: .env.{example,sample,template}
#   4. safety.md does not introduce "dist" or "tpl" into the .env clause.
#
# Run from repo root. Output uses GitHub Actions annotations. Exits 1 on any error.
#
# CI wiring: reached via .github/scripts/tests/env-template-allowlist-lint.test.sh,
# which run-hook-tests.sh auto-discovers (#681) without any workflow edits.

set -euo pipefail

# Canonical three-suffix token used in agent prompt files (prompt form).
PROMPT_TOKEN='.env.<example|sample|template>'

# Canonical three-suffix token used in safety.md (prose/brace form).
PROSE_TOKEN='.env.{example,sample,template}'

# Drifted tokens that must not appear in any .env template-exception clause.
# '|dist>' and '|tpl>' close the partial-append gap where only one extra suffix
# is added after the canonical three (e.g. .env.<example|sample|template|dist>).
# '|tpl>' is also a substring of '|dist|tpl>', so the combined pattern becomes
# technically redundant; it is kept for clarity.
DRIFTED_TOKENS=('|dist|tpl>' '|dist>' '|tpl>' '.env.dist' '.env.tpl')

# All six drifted prompt surfaces (Phase 1 narrowed all of these).
PROMPT_SURFACES=(
  '.claude/agents/phase-a-fixer.md'
  '.claude/agents/phase-b-reviewer.md'
  '.claude/agents/phase-c-merger.md'
  '.claude/agents/pm-worker.md'
  '.claude/agents/README.md'
  '.claude/skills/pr-review-help/SKILL.md'
)

# Canonical rule file (uses brace form, not angle-bracket form).
SAFETY_MD='.claude/rules/safety.md'

errors=0

usage() {
  cat <<'EOF'
Usage: .github/scripts/env-template-allowlist-lint.sh

  Verifies every agent prompt surface and safety.md agree on the three-suffix
  .env template allow-list (example|sample|template) and that no surface
  reintroduces the drifted suffixes dist or tpl. No options. Run from the repo
  root. Exits 1 on any error.
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

require_file() {
  local f="$1"
  if [[ ! -f "$f" ]]; then
    echo "::error file=${f}::Required file not found"
    errors=$((errors + 1))
    return 1
  fi
  return 0
}

# Assert the correct suffix token is present in the file (fixed-string).
require_token() {
  local file="$1" token="$2" label="$3"
  if ! grep -qF -- "$token" "$file"; then
    echo "::error file=${file}::Missing required ${label} token — expected to find: ${token}"
    errors=$((errors + 1))
  fi
}

# Assert a drifted token does NOT appear in the file (fixed-string).
forbid_token() {
  local file="$1" token="$2"
  if grep -qF -- "$token" "$file"; then
    echo "::error file=${file}::Drifted .env suffix token found — must not appear: ${token}"
    errors=$((errors + 1))
  fi
}

# --- Check prompt surfaces ---------------------------------------------------
for surface in "${PROMPT_SURFACES[@]}"; do
  require_file "$surface" || continue

  require_token "$surface" "$PROMPT_TOKEN" '.env template allow-list'

  for drifted in "${DRIFTED_TOKENS[@]}"; do
    forbid_token "$surface" "$drifted"
  done
done

# --- Check safety.md --------------------------------------------------------
require_file "$SAFETY_MD" || true

if [[ -f "$SAFETY_MD" ]]; then
  require_token "$SAFETY_MD" "$PROSE_TOKEN" '.env template allow-list (prose form)'

  for drifted in "${DRIFTED_TOKENS[@]}"; do
    forbid_token "$SAFETY_MD" "$drifted"
  done
fi

# --- Report -----------------------------------------------------------------
if (( errors > 0 )); then
  echo "env-template-allowlist-lint: ${errors} error(s) found"
  exit 1
fi

echo "env-template-allowlist-lint: OK (${#PROMPT_SURFACES[@]} prompt surfaces + safety.md)"
