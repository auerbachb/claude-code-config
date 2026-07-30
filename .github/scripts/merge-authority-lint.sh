#!/usr/bin/env bash
# Lint merge-authority conformance across canonical chip/prompt emitters (issue #753).
#
# A launched thread reads its own prompt up close and the global rules only if it
# goes looking. #674 made auto-merge the default in the rules; this lint keeps that
# default asserted in the prompts threads are actually launched with.
#
# Validates:
#   1. chip-launching.md defines the shared merge-authority contract: the verbatim
#      bullet, the never-ask-for-approval rule, and the human-in-chat-only opt-out.
#   2. Each canonical emitter SKILL.md carries the merge-authority bullet, naming
#      full /wrap, the merge gate, and AC verification.
#   3. CLAUDE.md's opt-out clause is scoped to a human message in chat.
#   4. No skill/reference template carries approval-flavored merge wording.
#
# Companion to rule-lint.sh / chip-model-guard-lint.sh. Run from repo root.
# Output uses GitHub Actions annotations. Exits 1 on any error.
#
# CI wiring: reached via tests/merge-authority-lint.test.sh, which hook-scripts.yml
# auto-discovers (#681) and which asserts real-repo conformance — not via
# rule-lint.sh, a path config-protection.py blocks from modification.

set -euo pipefail

CHIP_LAUNCHING=".claude/reference/chip-launching.md"
CLAUDE_MD="CLAUDE.md"
SKILLS_DIR=".claude/skills"
REFERENCE_DIR=".claude/reference"

CANONICAL_EMITTERS=(pm prompt start-issue issue-maker wave)

# The one sentence every emitter's Constraints block must carry, character for
# character. Kept here as the lint's single source of truth; the prose copy lives
# in chip-launching.md "Merge-authority line". Compared with grep -F, so a
# reworded or truncated variant fails rather than passing on a prefix match.
CANONICAL_BULLET='- Merging is automatic and yours to do: once the merge gate passes and every Test Plan / AC checkbox verifies, run the full `/wrap` yourself to squash-merge — no approval pause, no pre-merge message (`CLAUDE.md` "PR MERGE AUTHORIZATION")'

# Mirrored restatements of the opt-out — each must scope it to a human in chat.
OPT_OUT_MIRRORS=(
  "${SKILLS_DIR}/pm/SKILL.md"
  "${SKILLS_DIR}/subagent/SKILL.md"
)

# Approval-flavored wording that must never appear in a template. Supersets the
# issue #753 acceptance grep, enforced in CI so a one-time cleanup cannot drift back.
# The subject is optional ("ask before merging" reads to a spawned thread exactly
# like "ask the user before merging"), and "approval" alone is enough — a template
# does not have to name whose approval it is waiting on to cause the pause.
# "get approval before merging" and "approval is required before merging" pause a
# thread exactly like the wait-for forms, so they are prohibited too.
APPROVAL_PATTERN='ask ((the user|me|first) )?before merg|(wait for|get|obtain|seek) ((my|the |a )?(user|human) )?approval before merg|approval (is )?(required|needed) before merg'

errors=0

usage() {
  cat <<'EOF'
Usage: .github/scripts/merge-authority-lint.sh

  Verifies every canonical emitter asserts the auto-merge default, that the
  CLAUDE.md opt-out is human-in-chat only, and that no template asks for merge
  approval. No options. Run from the repo root. Exits 1 on any error.
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
}

require_pattern() {
  local file="$1" pattern="$2" label="$3"
  if ! grep -qE "$pattern" "$file"; then
    echo "::error file=${file}::Missing required ${label} (expected /${pattern}/)"
    errors=$((errors + 1))
  fi
}

# Fixed-string check for a line that must appear *verbatim*. A regex prefix match
# would pass on a truncated or reworded bullet — precisely the drift this lint
# exists to catch — so the whole canonical sentence is compared literally.
require_literal() {
  local file="$1" literal="$2" label="$3"
  if ! grep -qF -- "$literal" "$file"; then
    echo "::error file=${file}::Missing required ${label} — the canonical line must appear verbatim: ${literal}"
    errors=$((errors + 1))
  fi
}

require_file "$CHIP_LAUNCHING" || true
require_file "$CLAUDE_MD" || true

# --- 1. chip-launching.md shared contract ---------------------------------
if [[ -f "$CHIP_LAUNCHING" ]]; then
  require_pattern "$CHIP_LAUNCHING" 'Merge-authority line' 'merge-authority contract section'
  require_literal "$CHIP_LAUNCHING" "$CANONICAL_BULLET" 'verbatim merge-authority bullet'
  require_pattern "$CHIP_LAUNCHING" 'No template may ask for merge approval' 'never-ask-for-approval rule'
  require_pattern "$CHIP_LAUNCHING" 'human-in-chat only' 'human-only opt-out scoping'
fi

# --- 2. Canonical emitters assert the default -----------------------------
for skill in "${CANONICAL_EMITTERS[@]}"; do
  skill_file="${SKILLS_DIR}/${skill}/SKILL.md"
  if [[ ! -f "$skill_file" ]]; then
    echo "::error::${skill_file} not found — canonical emitter missing"
    errors=$((errors + 1))
    continue
  fi

  # /wave carries no prompt template of its own — it reuses /pm Step 3.1's block,
  # so it must reference the shared contract rather than fork a second copy.
  if [[ "$skill" == "wave" ]]; then
    require_pattern "$skill_file" 'Merge-authority line' "${skill} merge-authority contract reference"
    require_pattern "$skill_file" 'merges itself via full `/wrap`' "${skill} inherited auto-merge assertion"
    require_pattern "$skill_file" 'merge gate' "${skill} merge-gate reference"
    require_pattern "$skill_file" 'every AC checkbox verifies' "${skill} AC-verification reference"
  else
    # Verbatim, not a prefix match — the whole point is that every emitter says
    # the same thing, so a reworded or truncated bullet must fail.
    require_literal "$skill_file" "$CANONICAL_BULLET" "${skill} merge-authority bullet"
  fi
done

# --- 3. Opt-out is human-in-chat only -------------------------------------
# Each statement of the opt-out must carry the whole clause, not just a fragment
# of it. "never an opt-out" on its own is satisfied by wording that never says a
# *human* must say it *in chat* — the exact hole a spawned thread fell through
# when it read its own task prompt as the user speaking (#753).
#
# Granularity is one markdown paragraph, and every paragraph stating the rule is
# validated independently. Checking file-wide would let "human" in an unrelated
# sentence satisfy a file whose opt-out never says who may trigger it; checking
# all matches concatenated would let one complete paragraph cover for an
# incomplete one. Both are the same "somewhere else in the file says it" gap the
# rule change closes for spawned threads. Paragraphs also let a clause wrap
# across several lines.
validate_opt_out_paragraph() {
  local file="$1" label="$2" para="$3" idx="$4"
  local ok=0

  for surface in 'task prompt' 'chip payload' 'issue body' 'PR body' 'review comment'; do
    if ! grep -qF -- "$surface" <<< "$para"; then
      echo "::error file=${file}::${label} opt-out clause (paragraph ${idx}) does not name the excluded surface '${surface}'"
      errors=$((errors + 1)); ok=1
    fi
  done

  if ! grep -qE 'human' <<< "$para"; then
    echo "::error file=${file}::${label} opt-out clause (paragraph ${idx}) does not scope the trigger to a human (issue #753)"
    errors=$((errors + 1)); ok=1
  fi
  if ! grep -qE 'in chat|in-chat' <<< "$para"; then
    echo "::error file=${file}::${label} opt-out clause (paragraph ${idx}) does not scope the trigger to chat (issue #753)"
    errors=$((errors + 1)); ok=1
  fi

  return $ok
}

require_opt_out_scoping() {
  local file="$1" label="$2"
  local para="" idx=0 found=0 line

  # Walk the file paragraph by paragraph (blank line = separator), validating
  # every paragraph that states the opt-out. A trailing paragraph with no final
  # blank line is flushed after the loop.
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ -z "$line" ]]; then
      if [[ -n "$para" ]] && grep -q 'never an opt-out' <<< "$para"; then
        idx=$((idx + 1)); found=1
        validate_opt_out_paragraph "$file" "$label" "$para" "$idx" || true
      fi
      para=""
      continue
    fi
    para+="${line}"$'\n'
  done < "$file"

  if [[ -n "$para" ]] && grep -q 'never an opt-out' <<< "$para"; then
    idx=$((idx + 1)); found=1
    validate_opt_out_paragraph "$file" "$label" "$para" "$idx" || true
  fi

  if (( found == 0 )); then
    echo "::error file=${file}::Missing required ${label} excluded-surfaces rule (expected /never an opt-out/)"
    errors=$((errors + 1))
  fi
}

if [[ -f "$CLAUDE_MD" ]]; then
  require_pattern "$CLAUDE_MD" 'Opt-out — human-in-chat only' 'CLAUDE.md human-only opt-out clause'
  require_opt_out_scoping "$CLAUDE_MD" 'CLAUDE.md'
fi

for mirror in "${OPT_OUT_MIRRORS[@]}"; do
  if [[ ! -f "$mirror" ]]; then
    echo "::error::${mirror} not found — opt-out restatement missing"
    errors=$((errors + 1))
    continue
  fi
  require_opt_out_scoping "$mirror" "$(basename "$(dirname "$mirror")") mirrored"
done

# --- 4. No approval-flavored template wording -----------------------------
# Scans skills + reference docs + CLAUDE.md. Rule prose describing the opt-out is
# worded to avoid this pattern entirely, so any hit is a genuine regression.
approval_hits=$(grep -rniE "$APPROVAL_PATTERN" \
  "$SKILLS_DIR" "$REFERENCE_DIR" "$CLAUDE_MD" 2>/dev/null || true)

if [[ -n "$approval_hits" ]]; then
  while IFS= read -r hit; do
    [[ -n "$hit" ]] || continue
    hit_file="${hit%%:*}"
    echo "::error file=${hit_file}::Approval-flavored merge wording in a template — a launched thread reads this as an instruction to pause (issue #753): ${hit}"
    errors=$((errors + 1))
  done <<< "$approval_hits"
fi

if (( errors > 0 )); then
  echo "merge-authority-lint: ${errors} error(s) found"
  exit 1
fi

echo "merge-authority-lint: OK (${#CANONICAL_EMITTERS[@]} emitters)"
