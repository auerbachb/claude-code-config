#!/usr/bin/env bash
# Generational model-fleet drift guard (issue #752).
#
# Flags enumerated legacy model versions matching `(Opus|Sonnet) 4.<digit>`
# (e.g. "Opus 4.8", "Sonnet 4.6") in live surfaces only.
#
# Scan targets (live operative corpus):
#   CLAUDE.md
#   .claude/rules/
#   .claude/skills/
#   .claude/agents/
#
# EXEMPTED (intentionally stale by design):
#   .claude/reference/  — dated audit records legitimately name old model
#                         versions and must not be rewritten (#791).
#
# Why deny-list, not allow-list:
#   An allow-list fails closed — a stale list blocks unrelated PRs until
#   hand-edited at each fleet bump.  A deny-list fails open — a stale list
#   simply misses future drift rather than blocking unrelated PRs.
#   See .claude/reference/model-fleet-drift-guard-decision.md.
#
# Why these families only:
#   The pattern targets Opus and Sonnet because those are the families that
#   have had enumerated 4.x versions in live surfaces.  Haiku 4.5 is the
#   current fleet member, not a legacy one, and Haiku is deliberately excluded
#   from the pattern.  Fable has never carried a 4.x enumeration.
#
# Why digit, not 'x':
#   `Opus 4.x` is the generational prose that /prompt uses for its Legacy
#   list — a legitimate reference that must not be flagged.  The deny-list
#   matches only a literal digit after the dot, so `4.8` matches but `4.x`
#   does not.
#
# Extension cost:
#   When the next cross-generation fleet bump makes 5.x legacy, extend the
#   pattern from `4` to `(4|5)`.  One-line edit, explicitly accepted per #752.
#
# CI wiring:
#   Named to match .github/scripts/*-lint.sh — auto-discovered by
#   run-doc-lints.sh (PR #1147).  Runs under the same `rule-lint` required
#   CI check without any change to rule-lint.sh or the workflow file.
#
# Companion: .github/scripts/tests/model-drift-lint.test.sh
#
# Usage: bash .github/scripts/model-drift-lint.sh
# Exits 0 on clean pass, 1 on any findings.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/lint-common.sh
source "$SCRIPT_DIR/lib/lint-common.sh"

# Legacy enumerated-version pattern.
# Matches: "Opus 4.8", "Opus 4.7", "Sonnet 4.6", etc.
# Does NOT match: "Haiku 4.5" (Haiku excluded), "Opus 4.x" (x is not a digit),
#   "claude-opus-4-5" (lowercase/hyphenated API ids).
LEGACY_RE='(Opus|Sonnet) 4\.[0-9]'

errors=0

usage() {
  cat <<'EOF'
Usage: .github/scripts/model-drift-lint.sh

  Flags legacy enumerated model versions (Opus/Sonnet 4.<digit>) in live
  surfaces.  Exempts .claude/reference/ (dated records are stale by design).
  See .claude/reference/model-fleet-drift-guard-decision.md.

  No options.  Run from the repo root.  Exits 1 on any finding.
EOF
}

while (( $# > 0 )); do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    *)
      echo "::error::model-drift-lint.sh: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

# Collect scan targets that exist.
scan_targets=()
for target in CLAUDE.md .claude/rules .claude/skills .claude/agents; do
  [[ -e "$target" ]] && scan_targets+=("$target")
done

if (( ${#scan_targets[@]} == 0 )); then
  echo "::warning::model-drift-lint.sh: no scan targets found — run from repo root"
  exit 0
fi

while IFS= read -r hit; do
  [[ -n "$hit" ]] || continue
  hit_file="${hit%%:*}"
  hit_rest="${hit#*:}"
  hit_line="${hit_rest%%:*}"
  hit_match="${hit_rest#*:}"
  echo "::error file=${hit_file},line=${hit_line}::Legacy model version in live surface: '${hit_match}' — update to the current fleet family name. See .claude/reference/model-fleet-drift-guard-decision.md and .claude/agents/README.md \"Model naming\"."
  errors=$((errors + 1))
done < <(grep -rnE "$LEGACY_RE" --include='*.md' "${scan_targets[@]}" 2>/dev/null || true)

if (( errors > 0 )); then
  echo "model-drift-lint: ${errors} legacy model version(s) found in live surfaces"
  exit 1
fi

echo "model-drift-lint: OK"
