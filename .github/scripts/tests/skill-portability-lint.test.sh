#!/usr/bin/env bash
# Unit tests for skill-portability-lint.sh (issue #1189)
#
# Each failure case plants one regression into a copy of the real corpus and
# asserts the lint catches it. The clean case asserts the shipped corpus passes,
# so a fixture that stops reproducing its own premise shows up as a failure
# rather than a silent green.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
LINT="${REPO_ROOT}/.github/scripts/skill-portability-lint.sh"

TMP_ROOT=$(mktemp -d -t skill-portability-lint.XXXXXX)
trap 'chmod -R u+rwX "$TMP_ROOT" 2>/dev/null; rm -rf "$TMP_ROOT"' EXIT

failures=0
case_num=0

SKILLS=(pm subagent prompt wave issue-maker start-issue pr-monitor-and-manage end end-resume pause pause-resume)
REQUIRED_RENAMED_SKILLS=(end end-resume pause pause-resume)

make_fixture() {
  local dir="$1"
  mkdir -p "$dir/.claude/reference" "$dir/.claude/agents"
  cp "$REPO_ROOT/.claude/reference/chip-launching.md" "$dir/.claude/reference/"
  cp "$REPO_ROOT/.claude/reference/portable-skill-resolution.md" "$dir/.claude/reference/"
  cp "$REPO_ROOT/.claude/reference/subagent-phase-guardrails.md" "$dir/.claude/reference/"
  cp "$REPO_ROOT"/.claude/agents/*.md "$dir/.claude/agents/"
  for skill in "${SKILLS[@]}"; do
    mkdir -p "$dir/.claude/skills/${skill}"
    cp "$REPO_ROOT/.claude/skills/${skill}/SKILL.md" "$dir/.claude/skills/${skill}/"
    if [[ -d "$REPO_ROOT/.claude/skills/${skill}/references" ]]; then
      cp -R "$REPO_ROOT/.claude/skills/${skill}/references" "$dir/.claude/skills/${skill}/"
    fi
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

plant_bare_invocation() {
  printf '\n```bash\nCLAIM=$(.claude/scripts/issue-claim.sh 42 --check)\n```\n' \
    >> ".claude/skills/pm/SKILL.md"
}

plant_bare_invocation_in_reference() {
  printf '\n```bash\nGATE=$(.claude/scripts/merge-gate.sh 42)\n```\n' \
    >> ".claude/skills/pr-monitor-and-manage/references/pmm-act.md"
}

plant_bare_invocation_in_agent() {
  printf '\n```bash\nSTATE=$(.claude/scripts/pr-state.sh --pr 42)\n```\n' \
    >> ".claude/agents/phase-b-reviewer.md"
}

# A candidate list that skips the skills-worktree entry resolves to nothing in a
# fresh repo — the exact silent-degradation shape, wearing the resolver's shape.
plant_truncated_candidate_list() {
  {
    printf '\n```bash\n'
    printf 'for c in \\\n'
    printf '  "$HOME/.claude/scripts/session-state.sh" \\\n'
    printf '  ".claude/scripts/session-state.sh"; do\n'
    printf '  [[ -x "$c" ]] && break\n'
    printf 'done\n'
    printf '```\n'
  } >> ".claude/skills/wave/SKILL.md"
}

drift_resolve_block() {
  # Reword one line of the RESOLVE copy; the canonical stays put.
  perl -0pi -e 's/^Read reference docs the same way under/Read reference docs however you like under/m' \
    ".claude/reference/subagent-phase-guardrails.md"
}

drift_claim_bullet() {
  perl -0pi -e 's/^(- Claim the issue before anything else\.).*$/$1 Run `.claude\/scripts\/issue-claim.sh <N> --check`./m' \
    ".claude/skills/prompt/SKILL.md"
}

strip_worktree_from_canonical_claim() {
  perl -0pi -e 's/\$HOME\/\.claude\/skills-worktree\/\.claude\/scripts\/issue-claim\.sh`, //' \
    ".claude/reference/chip-launching.md"
}

remove_guarded_surface() {
  rm -f ".claude/skills/wave/SKILL.md"
}

remove_renamed_guarded_surface() {
  rm -f ".claude/skills/$1/SKILL.md"
}

# The agents directory had no missing-surface counter in the first draft, so an
# absent .claude/agents/ produced zero agent files and a confident pass. This is
# the regression channel that would otherwise be unguarded.
remove_agents_dir() {
  rm -rf ".claude/agents"
}

empty_agents_dir() {
  rm -f .claude/agents/*.md
}

# Two files losing their closing fence in the same edit must not compare equal.
unterminate_both_resolve_blocks() {
  perl -0pi -e 's/^```$//gm' ".claude/reference/subagent-phase-guardrails.md"
  perl -0pi -e 's/^```$//gm' ".claude/reference/portable-skill-resolution.md"
}

make_surface_unreadable() {
  chmod 000 ".claude/skills/prompt/SKILL.md"
}

# --- Cases -----------------------------------------------------------------

expect "clean corpus passes" 0 'skill-portability-lint: OK' noop

expect "bare invocation in a SKILL.md" 1 \
  'skills/pm/SKILL\.md:[0-9]+: bare invocation of issue-claim\.sh' \
  plant_bare_invocation

expect "bare invocation in a skill references/ file" 1 \
  'pmm-act\.md:[0-9]+: bare invocation of merge-gate\.sh' \
  plant_bare_invocation_in_reference

expect "bare invocation in an agent definition" 1 \
  'phase-b-reviewer\.md:[0-9]+: bare invocation of pr-state\.sh' \
  plant_bare_invocation_in_agent

expect "candidate list missing the skills-worktree entry" 1 \
  'candidate list for session-state\.sh has no' \
  plant_truncated_candidate_list

expect "RESOLVE block drifts from its canonical copy" 1 \
  'RESOLVE block differs from the canonical copy' \
  drift_resolve_block

expect "claim bullet drifts from its canonical copy" 1 \
  'claim bullet differs from the canonical copy' \
  drift_claim_bullet

expect "canonical claim bullet loses its worktree candidate" 1 \
  'claim bullet does not carry the skills-worktree candidate' \
  strip_worktree_from_canonical_claim

expect "missing guarded surface is exit 3, never a pass" 3 \
  'Guarded surface missing from disk' \
  remove_guarded_surface

# Keep the rename contract independent from the production linter's SKILLS
# array. If any renamed command disappears from that array, removing its
# fixture file will stop producing exit 3 and this test will fail.
for renamed_skill in "${REQUIRED_RENAMED_SKILLS[@]}"; do
  expect "renamed ${renamed_skill} surface remains guarded" 3 \
    "Guarded surface missing from disk: \\.claude/skills/${renamed_skill}/SKILL\\.md" \
    remove_renamed_guarded_surface "$renamed_skill"
done

expect "missing agents directory is exit 3, never a pass" 3 \
  'Guarded surface missing from disk: \.claude/agents/' \
  remove_agents_dir

expect "empty agents directory is a broken glob, not an empty guard" 3 \
  'contains no \*\.md' \
  empty_agents_dir

expect "unterminated RESOLVE blocks do not compare equal" 1 \
  'no closing .* fence' \
  unterminate_both_resolve_blocks

expect "unreadable guarded surface is exit 3, never a pass" 3 \
  'exists but is unreadable' \
  make_surface_unreadable

# --- Result ----------------------------------------------------------------

echo ""
if (( failures > 0 )); then
  echo "skill-portability-lint.test.sh: ${failures} of ${case_num} case(s) FAILED"
  exit 1
fi
echo "skill-portability-lint.test.sh: all ${case_num} cases passed"
