#!/usr/bin/env bash
# Doc test for Issue #2435: the parent-run steps named in /pm and /subagent agree with the lean-orchestrator reference.
# catalog: tests — Parent-permitted list, /pm and /subagent parent-run steps and the monitor-mode pointer agree, and no step is both parent-run and handed off
# covers: .claude/reference/lean-orchestrator.md
# covers: .claude/skills/pm/SKILL.md
# covers: .claude/skills/subagent/SKILL.md
# covers: .claude/rules/monitor-mode.md
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
REF="$ROOT/.claude/reference/lean-orchestrator.md"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }
for f in "$REF" "$ROOT/.claude/skills/pm/SKILL.md" "$ROOT/.claude/skills/subagent/SKILL.md" "$ROOT/.claude/rules/monitor-mode.md"; do
  [[ -r "$f" ]] || fail "cannot read $f"
done

# Block between <!-- lean-orchestrator:NAME --> and <!-- /lean-orchestrator:NAME -->.
block() { awk -v n="$2" '$0 == "<!-- lean-orchestrator:" n " -->" { on=1; next } $0 == "<!-- /lean-orchestrator:" n " -->" { on=0 } on' "$1"; }
line_of() { grep -m1 "^$2:" <<<"$1" || true; }

# Permitted-work list: exactly the issue's short list plus the trivial-lookup floor.
perm=$(block "$REF" permitted | sed -n 's/^- `\([a-z-]*\)`.*/\1/p' | tr '\n' ' ')
want="user-conversation launch-decision phase-transition gate-outcome blocker-judgment trivial-lookup "
[[ "$perm" == "$want" ]] || fail "permitted list changed unexpectedly: $perm"
pass "permitted list is the explicit short list"

for pair in "pm:.claude/skills/pm/SKILL.md" "subagent:.claude/skills/subagent/SKILL.md"; do
  name=${pair%%:*}; skill="$ROOT/${pair#*:}"
  ref_block=$(block "$REF" "$name")
  [[ -n "$ref_block" ]] || fail "reference has no $name block"
  ref_run=$(line_of "$ref_block" "Parent-run"); ref_off=$(line_of "$ref_block" "Handed off")
  [[ -n "$ref_run" && -n "$ref_off" ]] || fail "$name block lacks Parent-run / Handed off lines"
  grep -qxF "$ref_run" "$skill" || fail "$name skill lacks reference line: $ref_run"
  grep -qxF "$ref_off" "$skill" || fail "$name skill lacks reference line: $ref_off"
  # No step may appear on both lines.
  run_steps=$(printf '%s' "${ref_run#Parent-run:}" | tr ',' '\n' | tr -d ' ')
  off_steps=$(printf '%s' "${ref_off#Handed off:}" | tr ',' '\n' | tr -d ' ')
  for s in $run_steps; do
    case $'\n'"$off_steps"$'\n' in *$'\n'"$s"$'\n'*) fail "$name step $s is both parent-run and handed off" ;; esac
  done
  pass "$name: skill and reference agree, lists disjoint"
done

grep -q 'lean-orchestrator.md' "$ROOT/.claude/rules/monitor-mode.md" || fail "monitor-mode.md does not point at the reference"
pass "monitor-mode.md points at the reference"
echo "All lean-orchestrator list checks passed."
