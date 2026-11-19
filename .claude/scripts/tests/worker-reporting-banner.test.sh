#!/usr/bin/env bash
# Doc test for Issue #2464: worker banners require a structured EXIT_REPORT for every outcome, blockers included.
# catalog: tests — Worker banners keep the quiet-wait rules and require an EXIT_REPORT with the blocker reason for every outcome (checks guidance text, not runtime compliance)
# covers: .claude/agents/phase-a-fixer.md
# covers: .claude/agents/phase-b-reviewer.md
# covers: .claude/agents/phase-c-merger.md
# covers: .claude/agents/pm-worker.md
# covers: .claude/reference/exit-report-format.md
# covers: .claude/reference/lean-orchestrator.md
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

banner() { grep -m1 '^> \*\*Waiting and reporting:\*\*' "$1" || true; }

# banner_ok FILE -> 0 when every required clause is present and the old alternative is absent
banner_ok() {
  local b; b=$(banner "$1")
  [[ -n "$b" ]] || return 1
  grep -qF 'wait inside a single foreground command' <<<"$b" || return 1
  grep -qF 'never a `Monitor` or background command' <<<"$b" || return 1
  grep -qF 'never end a turn with interim status — each one wakes the parent' <<<"$b" || return 1
  grep -qF 'structured `EXIT_REPORT`' <<<"$b" || return 1
  grep -qF 'every outcome' <<<"$b" || return 1
  grep -qF 'prose directly above the report' <<<"$b" || return 1
  grep -qF '`RESULT`' <<<"$b" || return 1
  ! grep -qF 'or a real blocker' <<<"$b" || return 1
}

for f in phase-a-fixer phase-b-reviewer phase-c-merger pm-worker; do
  banner_ok "$ROOT/.claude/agents/$f.md" || fail "$f banner missing a required clause"
done
pass "all four banners carry the quiet-wait and mandatory-report clauses"

B="$ROOT/.claude/agents/phase-b-reviewer.md"
grep -qF '(a bounded wait script)' <<<"$(banner "$B")" || fail "phase B bounded-wait clause missing"
grep -qF 'is not a terminal blocker and does not end a turn' <<<"$(banner "$B")" || fail "phase B nonterminal-notice clause missing"
grep -q 'OUTCOME: <.*blocked|blocked_self_review>' "$B" || fail "phase B template lacks blocked outcomes"
grep -q '^- `blocked_self_review`' "$B" || fail "phase B outcome list lacks blocked_self_review"
pass "phase B bounded-wait, nonterminal-notice and blocker outcomes present"

# Negative controls: removing each clause from a copy must make the predicate fail.
SRC="$ROOT/.claude/agents/phase-a-fixer.md"
n=0
for clause in 'wait inside a single foreground command' 'never a `Monitor` or background command' \
  'never end a turn with interim status' 'structured `EXIT_REPORT`' 'prose directly above the report'; do
  c="$TMP/copy$n.md"; n=$((n+1))
  python3 -I - "$SRC" "$c" "$clause" <<'PY'
import sys
s = open(sys.argv[1]).read()
assert sys.argv[3] in s
open(sys.argv[2], "w").write(s.replace(sys.argv[3], "REMOVED"))
PY
  if banner_ok "$c"; then fail "negative control passed with clause removed: $clause"; fi
done
c="$TMP/old.md"
sed 's/Read the brief/Report only the final EXIT_REPORT or a real blocker. Read the brief/' "$SRC" > "$c"
if banner_ok "$c"; then fail "negative control passed with old alternative wording"; fi
pass "negative controls fail as expected"

grep -qF 'blocker message alone never substitutes' "$ROOT/.claude/reference/exit-report-format.md" || fail "exit-report-format lacks the mandatory-report rule"
grep -qF 'ends every outcome with the structured `EXIT_REPORT`' "$ROOT/.claude/reference/lean-orchestrator.md" || fail "lean-orchestrator lacks the mandatory-report rule"
pass "canonical references carry the same rule"
