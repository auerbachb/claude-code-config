#!/usr/bin/env bash
# doc-lint: flag prose references to deprecated frontmatter keys (issue #1170).
#
# Background: PR #1131 renamed the agent frontmatter key `allowed-tools:` to
# `tools:` (the old key was silently ignored by the harness).  Docs can still
# name the deprecated key in agent-scoped prose — e.g. in a code block that
# loops over .claude/agents/*.md — and readers may mistake it for valid syntax.
#
# This lint flags such occurrences so they can be either corrected or
# suppressed with an inline opt-out marker when a mention is deliberate.
#
# === Deprecated-key table ===
#
#   allowed-tools:  →  tools:  (scope: agents)
#
# Extension path: add a new "DEPRECATED|REPLACEMENT|SCOPE" entry to the
# DEPRECATED_KEYS array below (one entry per deprecated key).  No other
# change is needed; the detection logic is driven by the table.
#
# === Opt-out marker ===
#
#   <!-- deprecated-key-ok: allowed-tools -->
#
# Place on the same line as the mention, on the immediately preceding line,
# or anywhere inside the same fenced code block as the mention.  This covers
# historical references, migration guides, and audit commands that legitimately
# name the old key.
#
# === Detection scope: "agent-scoped" ===
#
# An occurrence of `allowed-tools:` is agent-scoped when ANY of:
#   1. The file lives under .claude/agents/
#   2. The occurrence line itself contains ".claude/agents/"
#   3. The occurrence is inside a fenced code block that contains ".claude/agents/"
#
# Non-agent-scoped occurrences are silent — this lets skill frontmatter
# (.claude/skills/*/SKILL.md) keep using `allowed-tools:` where it is correct.
#
# === Canary ===
#
# Also asserts that the two known-restricted agents (phase-c-merger.md and
# researcher.md) still declare a `tools:` restriction in their frontmatter.
# If the key ever drifts back, any prose audit command that greps for
# `^allowed-tools:` would silently report them as unrestricted (fail-open
# defect from issue #864).
#
# === CI wiring ===
#
# Named to match .github/scripts/*-lint.sh — auto-discovered by
# run-doc-lints.sh (PR #1147).  Runs under the `rule-lint` required CI check
# without any change to rule-lint.sh or the workflow file.
#
# Companion: .github/scripts/tests/deprecated-frontmatter-key-lint.test.sh
#
# Usage: bash .github/scripts/deprecated-frontmatter-key-lint.sh
# Exits 0 on clean pass, 1 on any findings, 2 on usage error.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/lint-common.sh
source "$SCRIPT_DIR/lib/lint-common.sh"

errors=0

usage() {
  cat <<'EOF'
Usage: .github/scripts/deprecated-frontmatter-key-lint.sh

  Flags deprecated frontmatter key names (e.g. allowed-tools:) in
  agent-scoped Markdown prose.  Suppressed by an inline opt-out marker:

    <!-- deprecated-key-ok: allowed-tools -->

  See script header for scope rules.  Run from the repo root.
  Exits 1 on any finding, 2 on usage error.
EOF
}

while (( $# > 0 )); do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    *)
      echo "::error::deprecated-frontmatter-key-lint.sh: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

# ---------------------------------------------------------------------------
# Deprecated-key table (extensible).
# Format: "DEPRECATED_KEY|REPLACEMENT_KEY|SCOPE"
# Add one entry per deprecated key — the detection loop consumes the whole table.
# ---------------------------------------------------------------------------
DEPRECATED_KEYS=(
  "allowed-tools:|tools:|agents"
)

# Opt-out marker prefix; the key name follows the colon.
OPT_OUT_PREFIX="<!-- deprecated-key-ok:"

# ---------------------------------------------------------------------------
# Build the scan corpus: all git-tracked Markdown files.
# Falls back to find when not in a git repo (test fixtures use git init).
# ---------------------------------------------------------------------------
md_files=()
while IFS= read -r f; do
  [[ -n "$f" ]] && md_files+=("$f")
done < <(git ls-files '*.md' 2>/dev/null || find . -name '*.md' ! -path './.git/*')

if (( ${#md_files[@]} == 0 )); then
  echo "::error::deprecated-frontmatter-key-lint.sh: no Markdown files found — run from repo root"
  exit 1
fi

# ---------------------------------------------------------------------------
# Per-file stateful analysis using awk.
#
# For each file, awk tracks fenced code-block state (``` or ~~~) and decides
# whether each allowed-tools: occurrence is "agent-scoped".  It emits
# ::error:: lines for unprotected occurrences; bash counts them.
#
# Variables passed to awk:
#   file     — path for annotations
#   agent    — 1 if file lives under .claude/agents/, 0 otherwise
#   AGENTS   — the path fragment that marks agent co-occurrence
#   TARGET   — the deprecated key to detect
#   MARKER   — the inline opt-out marker (full string)
#   MSG      — error message text (avoids single-quote issues in awk)
# ---------------------------------------------------------------------------

for file in "${md_files[@]}"; do
  [[ -f "$file" ]] || continue

  is_agent_file=0
  [[ "$file" == .claude/agents/* ]] && is_agent_file=1

  # Extract the key and opt-out marker for the table entry.
  # Currently one entry; loop is ready for additional deprecated keys.
  for entry in "${DEPRECATED_KEYS[@]}"; do
    dep_key="${entry%%|*}"
    rest="${entry#*|}"
    rep_key="${rest%%|*}"
    # scope="${rest##*|}"  # informational only

    marker="${OPT_OUT_PREFIX} ${dep_key%:} -->"
    msg="Deprecated frontmatter key '${dep_key}' in agent-scoped context (use '${rep_key}' instead). For a deliberate migration mention add: ${marker}"

    while IFS= read -r err_line; do
      [[ -n "$err_line" ]] && echo "$err_line" && errors=$((errors + 1))
    done < <(
      awk -v file="$file" -v agent="$is_agent_file" \
          -v AGENTS=".claude/agents/" \
          -v TARGET="$dep_key" \
          -v MARKER="$marker" \
          -v MSG="$msg" \
      'BEGIN { in_fence=0; fence_n=0; fence_agents=0; prev="" }

       /^[`]{3}|^[~]{3}/ {
         if (!in_fence) {
           in_fence=1; fence_n=0; fence_agents=0
           for (k in fl) delete fl[k]
           for (k in fn) delete fn[k]
         } else {
           if (agent || fence_agents) {
             blk_m=0
             for (i=1; i<=fence_n; i++) {
               if (index(fl[i], MARKER) > 0) { blk_m=1; break }
             }
             if (!blk_m) {
               for (i=1; i<=fence_n; i++) {
                 if (index(fl[i], TARGET) > 0)
                   printf "::error file=%s,line=%d::%s\n", file, fn[i], MSG
               }
             }
           }
           in_fence=0; fence_n=0; fence_agents=0
           for (k in fl) delete fl[k]
           for (k in fn) delete fn[k]
         }
         prev=$0; next
       }

       in_fence {
         fence_n++; fl[fence_n]=$0; fn[fence_n]=NR
         if (index($0, AGENTS) > 0) fence_agents=1
         prev=$0; next
       }

       index($0, TARGET) > 0 {
         scoped=agent
         if (!scoped && index($0, AGENTS) > 0) scoped=1
         if (scoped) {
           has_m=(index($0, MARKER) > 0 || index(prev, MARKER) > 0) ? 1 : 0
           if (!has_m)
             printf "::error file=%s,line=%d::%s\n", file, NR, MSG
         }
         prev=$0; next
       }

       { prev=$0 }
      ' "$file"
    )
  done
done

# ---------------------------------------------------------------------------
# Canary: the two known-restricted agents must still carry a tools: key.
# If this fails, any prose snippet that greps ^allowed-tools: in these agents
# will report them as unrestricted — the fail-open defect from issue #864.
# ---------------------------------------------------------------------------
RESTRICTED_AGENTS=(
  ".claude/agents/phase-c-merger.md"
  ".claude/agents/researcher.md"
)

for agent_file in "${RESTRICTED_AGENTS[@]}"; do
  require_file "$agent_file" || continue
  fm="$(awk 'NR==1 && /^---/{in_fm=1; next} in_fm && /^---/{exit} in_fm{print}' "$agent_file")"
  if ! printf '%s\n' "$fm" | grep -qE '^tools:'; then
    echo "::error file=${agent_file}::Canary: ${agent_file} no longer declares a 'tools:' restriction in frontmatter. Any prose audit command greping '^allowed-tools:' would silently report this agent as unrestricted (fail-open defect, issue #864). Restore the 'tools:' key."
    errors=$((errors + 1))
  fi
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
if (( errors > 0 )); then
  echo "deprecated-frontmatter-key-lint: ${errors} error(s) found"
  exit 1
fi

echo "deprecated-frontmatter-key-lint: OK (${#md_files[@]} files scanned)"
