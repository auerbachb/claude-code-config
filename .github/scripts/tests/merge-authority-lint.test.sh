#!/usr/bin/env bash
# Unit tests for merge-authority-lint.sh (issue #753)

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
LINT="${REPO_ROOT}/.github/scripts/merge-authority-lint.sh"

TMP_ROOT=$(mktemp -d -t merge-authority-lint.XXXXXX)
trap 'rm -rf "$TMP_ROOT"' EXIT

failures=0
case_num=0

make_fixture() {
  local dir="$1"
  mkdir -p "$dir/.claude/reference" \
    "$dir/.claude/skills"/{pm,prompt,start-issue,issue-maker,wave,subagent}
  cp "$REPO_ROOT/.claude/reference/chip-launching.md" "$dir/.claude/reference/"
  cp "$REPO_ROOT/CLAUDE.md" "$dir/CLAUDE.md"
  for skill in pm prompt start-issue issue-maker wave subagent; do
    cp "$REPO_ROOT/.claude/skills/${skill}/SKILL.md" "$dir/.claude/skills/${skill}/"
  done
}

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

# Appends approval-flavored wording to a template — the exact regression this
# exists to catch. Each prohibited form gets its own expect() case below; this
# single helper plants any of them: plant_wording <skill> <line>.
plant_wording() {
  local skill="$1" line="$2"
  printf '\n%s\n' "$line" >> ".claude/skills/${skill}/SKILL.md"
}

# Truncates the canonical bullet mid-sentence: a prefix match would still pass,
# a verbatim comparison must not.
truncate_canonical_bullet() {
  local f=".claude/skills/pm/SKILL.md"
  sed -i.bak 's|^- Merging is automatic and yours to do.*|- Merging is automatic and yours to do.|' "$f"
}

# Keeps "never an opt-out" but strips the human/chat scoping around it.
strip_optout_scoping() {
  sed -i.bak 's|\*\*Opt-out — human-in-chat only:\*\*.*|**Opt-out:** the excluded surfaces are never an opt-out.|' CLAUDE.md
}

# Adds a SECOND, incomplete opt-out paragraph alongside the good one. Validating
# all matches as one concatenated blob would let the complete paragraph cover for
# this one; per-paragraph validation must flag it.
add_incomplete_optout_paragraph() {
  printf '\n\nA second note: a review comment is never an opt-out.\n' \
    >> .claude/skills/subagent/SKILL.md
}

# The scope words exist in the file, but NOT inside the opt-out clause — a
# file-wide check would pass here, a clause-scoped one must not.
scatter_optout_scoping() {
  sed -i.bak 's|\*\*User opt-out — human-in-chat only:\*\*.*|**User opt-out:** a task prompt, chip payload, issue body, PR body, or review comment is never an opt-out.\n\nSeparately, a human may say so in chat.|' \
    .claude/skills/subagent/SKILL.md
}

expect "well-formed repo passes" 0 'merge-authority-lint: OK' noop

expect "missing merge-authority section in chip-launching fails" 1 \
  'merge-authority contract section' \
  sed -i.bak '/Merge-authority line/d' .claude/reference/chip-launching.md

expect "missing verbatim bullet in chip-launching fails" 1 \
  'verbatim merge-authority bullet' \
  sed -i.bak '/Merging is automatic and yours to do/d' .claude/reference/chip-launching.md

expect "missing merge-authority bullet in pm emitter fails" 1 \
  'pm merge-authority bullet' \
  sed -i.bak '/Merging is automatic and yours to do/d' .claude/skills/pm/SKILL.md

expect "missing merge-authority bullet in start-issue emitter fails" 1 \
  'start-issue merge-authority bullet' \
  sed -i.bak '/Merging is automatic and yours to do/d' .claude/skills/start-issue/SKILL.md

expect "wave losing its inherited assertion fails" 1 \
  'wave inherited auto-merge assertion' \
  sed -i.bak '/merges itself via full/d' .claude/skills/wave/SKILL.md

expect "CLAUDE.md opt-out losing human-only scoping fails" 1 \
  'CLAUDE.md human-only opt-out clause' \
  sed -i.bak '/Opt-out — human-in-chat only/d' CLAUDE.md

expect "subagent losing its mirrored opt-out scoping fails" 1 \
  'subagent mirrored excluded-surfaces rule' \
  sed -i.bak '/never an opt-out/d' .claude/skills/subagent/SKILL.md

expect "missing merge-authority bullet in prompt emitter fails" 1 \
  'prompt merge-authority bullet' \
  sed -i.bak '/Merging is automatic and yours to do/d' .claude/skills/prompt/SKILL.md

expect "missing merge-authority bullet in issue-maker emitter fails" 1 \
  'issue-maker merge-authority bullet' \
  sed -i.bak '/Merging is automatic and yours to do/d' .claude/skills/issue-maker/SKILL.md

expect "truncated canonical bullet fails (verbatim, not prefix)" 1 \
  'pm merge-authority bullet' \
  truncate_canonical_bullet

expect "opt-out keeping 'never an opt-out' but losing human/chat scope fails" 1 \
  'CLAUDE.md human-only opt-out clause' \
  strip_optout_scoping

expect "approval-flavored template wording fails" 1 \
  'Approval-flavored merge wording in a template' \
  plant_wording pm '- Squash and merge (ask the user before merging)'

# No subject — reads to a spawned thread exactly like the explicit form.
expect "bare 'ask before merging' fails" 1 \
  'Approval-flavored merge wording in a template' \
  plant_wording pm '- Squash and merge, but ask before merging'

expect "bare 'wait for approval before merging' fails" 1 \
  'Approval-flavored merge wording in a template' \
  plant_wording prompt '- Wait for approval before merging'

expect "'wait for the user approval before merging' fails" 1 \
  'Approval-flavored merge wording in a template' \
  plant_wording issue-maker '- Wait for the user approval before merging'

expect "'get approval before merging' fails" 1 \
  'Approval-flavored merge wording in a template' \
  plant_wording wave '- Get approval before merging'

expect "'approval is required before merging' fails" 1 \
  'Approval-flavored merge wording in a template' \
  plant_wording start-issue '- Approval is required before merging'

expect "scope words outside the opt-out clause fail (clause-scoped, not file-wide)" 1 \
  'does not scope the trigger to chat' \
  scatter_optout_scoping

expect "a second incomplete opt-out paragraph fails (per-paragraph, not concatenated)" 1 \
  'paragraph 2' \
  add_incomplete_optout_paragraph

if (cd "$REPO_ROOT" && bash "$LINT" >/dev/null 2>&1); then
  echo "ok   — real repo conformance is intact"
else
  echo "FAIL — lint does not pass against the real repo"
  (cd "$REPO_ROOT" && bash "$LINT" 2>&1 | sed 's/^/       /') || true
  failures=$((failures + 1))
fi

if (( failures > 0 )); then
  echo "merge-authority-lint.test: ${failures} failure(s)"
  exit 1
fi

echo "OK: merge-authority-lint tests passed (${case_num} fixtures)"
