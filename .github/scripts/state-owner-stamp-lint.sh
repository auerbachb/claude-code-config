#!/usr/bin/env bash
# state-owner-stamp-lint: every writer that CREATES a session-state
# `.active_agents` or `.pipelines` record must stamp the owning session
# (`session_id`) (issue #2448).
#
# === The defect this exists to prevent ===
#
# safe-close-inventory.sh can attribute a record to a thread only by its
# session id, claim holder, or a runtime id the session registered. A
# non-terminal record that names none of them counts as `unknown` — and
# `unknown` blocks "Safe to close" in EVERY thread of EVERY repo, because the
# inventory cannot prove the record is not that thread's. On 2026-11-17, 32
# such records (25 agents, 7 pipelines) blocked a thread whose own work was
# settled. Old ones are retired with .claude/scripts/ownerless-state-retire.sh;
# this lint stops new ones from being written.
#
# === What counts as a creating write ===
#
#   - a whole-record `.active_agents[<key>]=…` assignment (a `--set`/`--cas`
#     value; sub-field writes such as `.active_agents[<key>].status=` are
#     updates, not creations)
#   - a `.pipelines[<key>].started_at=…` assignment (the pipeline lifecycle's
#     creating write, at top level or under `.repos[...]`)
#
# Each must have the token `session_id` on the same line or within the
# WINDOW lines around it (where the entry JSON or the sibling `--set` is
# built). Lines starting with `#` (shell comments, Markdown headings) are
# skipped; other Markdown prose is scanned too, so keep record writes in code.
#
# === Scan scope ===
#
# Tracked files under .claude/skills, .claude/scripts, .claude/agents,
# .claude/hooks and desk, minus test suites (`/tests/`) and session-state.sh
# itself (its header documents write syntax, it creates no records).
#
# Lint contract: exit 0 on pass / 1 on findings / 2 usage; no args needed
# (optional `--root DIR`, used by .github/scripts/tests/state-owner-stamp-lint.test.sh);
# runnable from anywhere.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# --root DIR scans another git checkout instead (the lint's own test fixtures).
if [[ "${1:-}" == --root ]]; then
  [[ -n "${2:-}" ]] || { echo "state-owner-stamp-lint: --root requires a directory" >&2; exit 2; }
  ROOT="$2"
fi
cd "$ROOT" || { echo "state-owner-stamp-lint: cannot enter $ROOT" >&2; exit 1; }
WINDOW=30

FILES="$(git ls-files -- .claude/skills .claude/scripts .claude/agents .claude/hooks desk 2>/dev/null \
  | grep -v '/tests/' | grep -v '^\.claude/scripts/session-state\.sh$')" || FILES=""
if [[ -z "$FILES" ]]; then
  echo "state-owner-stamp-lint: no files to scan (not a git checkout?)" >&2
  exit 1
fi

FINDINGS=0
while IFS= read -r f; do
  [[ -f "$f" ]] || continue
  out="$(awk -v win="$WINDOW" -v file="$f" '
    { lines[NR] = $0; code[NR] = 1 }
    # A comment is neither a write nor ownership evidence: "# session_id ..." must not pass.
    /^[[:space:]]*#/ { code[NR] = 0; next }
    {
      creates = 0
      if ($0 ~ /active_agents\[[^]]*\]=/) creates = 1
      if ($0 ~ /pipelines\[[^]]*\]\.started_at=/) creates = 1
      if (creates) hits[++n] = NR
    }
    END {
      for (h = 1; h <= n; h++) {
        at = hits[h]; ok = 0
        for (i = at - win; i <= at + win; i++) if (i >= 1 && i <= NR && code[i] && lines[i] ~ /session_id/) { ok = 1; break }
        if (!ok) printf "%s:%d: creates a state record without stamping session_id: %s\n", file, at, lines[at]
      }
    }' "$f")"
  if [[ -n "$out" ]]; then
    printf '%s\n' "$out"
    FINDINGS=$((FINDINGS + $(printf '%s\n' "$out" | grep -c .)))
  fi
done <<<"$FILES"

if (( FINDINGS > 0 )); then
  echo "state-owner-stamp-lint: $FINDINGS writer(s) create .active_agents/.pipelines records without session_id (issue #2448)" >&2
  exit 1
fi
echo "state-owner-stamp-lint: ok"
