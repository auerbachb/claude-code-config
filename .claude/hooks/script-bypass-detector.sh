#!/bin/bash
# Script bypass detector — PreToolUse hook (matcher: Bash)
#
# Logs likely inline reimplementations of shared .claude/scripts helpers without
# blocking the Bash command. This gives an outside signal when agents bypass
# canonical scripts such as pr-state.sh or merge-gate.sh.
#
# Input  (stdin) : JSON with {tool_name, tool_input, cwd, ...}
# Output (stdout): empty JSON object (non-blocking)
# Exit code      : always 0 — never blocks tool execution
#
# Storage model:
#   - Live TSV log: ~/.claude/script-bypass.log (NEVER in the skills worktree;
#     session-start-sync.sh may reset worktrees, which would wipe live counters).
#   - Format: timestamp UTC, cwd, matched pattern, suggested script, command
#     truncated to 200 chars. Fields are tab-separated and single-line.

set -uo pipefail

INPUT=$(cat)

# Always emit empty JSON and never fail — this hook is non-blocking.
trap 'printf "{}\n"; exit 0' EXIT

SCRIPT_BYPASS_INPUT="$INPUT" python3 <<'PY' 2>/dev/null || true
import json
import os
import re
from datetime import datetime, timezone

payload_raw = os.environ.get("SCRIPT_BYPASS_INPUT", "")
try:
    payload = json.loads(payload_raw)
except Exception:
    raise SystemExit(0)

tool_name = payload.get("tool_name") or payload.get("toolName") or ""
tool_input = payload.get("tool_input") or payload.get("toolInput") or {}
if tool_name and tool_name != "Bash":
    raise SystemExit(0)

if isinstance(tool_input, dict):
    command = tool_input.get("command") or ""
elif isinstance(tool_input, str):
    command = tool_input
else:
    command = ""

if not command:
    raise SystemExit(0)

cwd = payload.get("cwd") or os.getcwd()

def _cycle_count_sentinel(cmd: str) -> bool:
    """
    Detects manual cycle-count.sh bypasses. Returns True if cmd looks like it
    manually counts review-fix rounds without using cycle-count.sh.

    Split on &&, || and newlines so each pipeline line is a separate segment —
    a multiline bypass with | length on one line and select(.user.login on a
    later line would otherwise suppress detection. Semicolons are NOT split
    because ; inside python3 -c "..." strings would create false segments.

    Pattern 1 — raw count without bot-login filter:
        A pipeline segment fetches /reviews and uses | length or python3 len()
        to count reviews as "rounds". Routine CR/BugBot polling ALWAYS filters
        by .user.login; a genuine bypass does not.

    Pattern 2/3 — temporal comparison:
        Reviews submitted_at is compared against commits endpoint data in the same
        compound command — manually reimplementing the cycle algorithm.
    """
    segments = re.split(r"&&|\|\||\n", cmd)
    p1 = re.compile(
        r"gh\s+api.*pulls/[0-9]+/reviews.*(?:\|\s*length\b|python3.*len\()",
        re.S,
    )
    for seg in segments:
        if p1.search(seg) and not re.search(r'select\(\s*\.user\.login', seg):
            return True
    temporal = re.compile(
        r"(?:"
        r"gh\s+api.*pulls/[0-9]+/reviews.*submitted_at.*gh\s+api.*pulls/[0-9]+/commits"
        r"|"
        r"gh\s+api.*pulls/[0-9]+/commits.*gh\s+api.*pulls/[0-9]+/reviews.*submitted_at"
        r")",
        re.S,
    )
    return bool(temporal.search(cmd))


sentinels = [
    (
        "gh api PR reviews/comments with per_page",
        "pr-state.sh",
        re.compile(r"gh\s+api.*repos/.*/pulls/[0-9]+/(reviews|comments).*per_page", re.S),
    ),
    (
        "gh api check-runs blocking conclusions",
        "merge-gate.sh",
        re.compile(r"gh\s+api.*check-runs.*(failure|timed_out|action_required)", re.S),
    ),
    (
        "resolveReviewThread mutation",
        "resolve-review-threads.sh",
        re.compile(r"resolveReviewThread", re.S),
    ),
    (
        "CodeRabbit issue plan comment",
        "cr-plan.sh",
        re.compile(r"gh\s+issue\s+comment.*@coderabbitai\s+plan", re.S),
    ),
    (
        "gh api PR reviews counting rounds without bot filter",
        "cycle-count.sh",
        # Sentinel uses a callable instead of a bare regex to handle compound
        # shell commands correctly. A genuine cycle-count.sh bypass either:
        #   1. Fetches /reviews and counts them without any .user.login filter
        #      (treating raw review count as a proxy for fix rounds). Presence of
        #      select(.user.login in the SAME pipeline segment is a negative
        #      indicator — routine CR/BugBot polling always filters by bot login.
        #      We split only on && and || (not ; or newline) to avoid breaking
        #      on ; inside python3 -c "..." strings.
        #   2. Compares review submitted_at timestamps against commits endpoint
        #      data to manually reconstruct the cycle algorithm.
        _cycle_count_sentinel,
    ),
    (
        "git worktree porcelain piped to awk/sed",
        "repo-root.sh",
        re.compile(r"git\s+worktree\s+list\s+--porcelain.*\|.*\b(awk|sed)\b", re.S),
    ),
]

matches = []
for pattern_name, script_name, matcher in sentinels:
    if isinstance(matcher, re.Pattern):
        matched = bool(matcher.search(command))
    elif callable(matcher):
        matched = matcher(command)
    else:
        matched = False
    if matched:
        matches.append((pattern_name, script_name))

has_date_window = re.search(r"\bdate\b.*(?:-v-|-d\b)", command, re.S)
has_gh_query = re.search(r"\bgh\s+(?:search|api)\b", command, re.S)
if has_date_window and has_gh_query:
    matches.append(("date window combined with gh search/api", "gh-window.sh"))

if not matches:
    raise SystemExit(0)

def single_line(value: str) -> str:
    return re.sub(r"[\t\r\n]+", " ", str(value)).strip()

timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
safe_cwd = single_line(cwd)
safe_command = single_line(command)[:200]

log_path = os.path.join(os.path.expanduser("~"), ".claude", "script-bypass.log")
os.makedirs(os.path.dirname(log_path), exist_ok=True)

with open(log_path, "a", encoding="utf-8") as log:
    for pattern_name, script_name in matches:
        fields = [
            timestamp,
            safe_cwd,
            single_line(pattern_name),
            script_name,
            safe_command,
        ]
        log.write("\t".join(fields) + "\n")
PY

exit 0
