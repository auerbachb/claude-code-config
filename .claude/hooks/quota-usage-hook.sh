#!/bin/bash
# quota-usage-hook.sh — PostToolUse hook (all tools): per-response token ledger.
#
# After each tool call, inspects the session transcript, finds the most recent
# assistant message and its token usage, and appends ONE tab-separated line to
# ~/.claude/quota-usage.log (append-only, same family as script-usage.log /
# skill-usage.log). The /quota skill + quota-budget.sh read this ledger to report
# today's spend and project end-of-day vs the daily cap (issue #458).
#
# Input  (stdin) : JSON with {session_id, transcript_path, cwd, tool_name, ...}
# Output (stdout): empty JSON object (non-blocking)
# Exit code      : always 0 — never blocks tool execution
#
# TSV columns (7) — counts + model + session id only; NEVER prompts/completions
# or secrets:
#   ts_utc(ISO8601)  model  input_tokens  output_tokens  cache_read_tokens
#   cache_creation_tokens  session_id
#
# De-duplication:
#   A single assistant message can spawn several PostToolUse events (one per
#   tool_use block). The hook records the last-logged message id per session in
#   ~/.claude/quota-usage.d/<session>.last and skips when it is unchanged, so
#   each response's tokens are counted exactly once. The message id is kept ONLY
#   in the sidecar marker — it never enters the log.
#
# Graceful no-op: if the transcript is missing or exposes no assistant `usage`
# block (the documented payload-availability gap, AC #2), the hook writes nothing
# and exits 0.
#
# Limitation: PostToolUse fires only when a tool runs, so a final text-only
#   assistant message (no tool call) is not captured. This tracks the large
#   majority of spend, which is what the daily projection needs.
#
# Env overrides (tests): QUOTA_USAGE_LOG, QUOTA_STATE_DIR.

set -uo pipefail

INPUT=$(cat)

# Always emit empty JSON and never fail — this hook is strictly non-blocking.
trap 'echo "{}"; exit 0' EXIT

command -v python3 >/dev/null 2>&1 || exit 0

USAGE_LOG="${QUOTA_USAGE_LOG:-$HOME/.claude/quota-usage.log}"
STATE_DIR="${QUOTA_STATE_DIR:-$HOME/.claude/quota-usage.d}"

mkdir -p "$(dirname "$USAGE_LOG")" "$STATE_DIR" 2>/dev/null || exit 0

# NOTE: pass the hook payload via env var, NOT stdin. The heredoc below already
# claims python's stdin to deliver the program, so a piped stdin would be
# shadowed and read back empty.
QUOTA_HOOK_INPUT="$INPUT" python3 - "$USAGE_LOG" "$STATE_DIR" <<'PY' 2>/dev/null || exit 0
import json, os, sys
from datetime import datetime, timezone

usage_log, state_dir = sys.argv[1], sys.argv[2]

try:
    hook_input = json.loads(os.environ.get("QUOTA_HOOK_INPUT", ""))
except Exception:
    sys.exit(0)
if not isinstance(hook_input, dict):
    sys.exit(0)

transcript_path = hook_input.get("transcript_path") or ""
session_id = (hook_input.get("session_id") or os.environ.get("CLAUDE_SESSION_ID") or "unknown")
session_id = "".join(c if (c.isalnum() or c in "_.-") else "_" for c in str(session_id)) or "unknown"

if not transcript_path or not os.path.isfile(transcript_path):
    sys.exit(0)

# --- Read the tail of the transcript and find the latest assistant usage ---
def read_tail_lines(path, max_bytes=1_048_576):
    try:
        size = os.path.getsize(path)
        with open(path, "rb") as f:
            if size > max_bytes:
                f.seek(size - max_bytes)
                f.readline()  # drop partial line
            data = f.read()
    except Exception:
        return []
    return data.decode("utf-8", "replace").splitlines()

latest = None
for line in read_tail_lines(transcript_path):
    line = line.strip()
    if not line:
        continue
    try:
        obj = json.loads(line)
    except Exception:
        continue
    if not isinstance(obj, dict) or obj.get("type") != "assistant":
        continue
    msg = obj.get("message")
    if not isinstance(msg, dict):
        continue
    usage = msg.get("usage")
    if not isinstance(usage, dict):
        continue
    msg_id = msg.get("id") or obj.get("uuid") or ""
    if not msg_id:
        continue
    latest = {"id": str(msg_id), "model": str(msg.get("model") or ""), "usage": usage}

# Graceful no-op when no assistant usage block is present (payload gap, AC #2).
if latest is None:
    sys.exit(0)

# --- De-dup: skip if this assistant message was already logged this session ---
marker = os.path.join(state_dir, session_id + ".last")
try:
    with open(marker, encoding="utf-8") as f:
        if f.read().strip() == latest["id"]:
            sys.exit(0)
except FileNotFoundError:
    pass
except Exception:
    pass

def tok(name):
    try:
        return int(latest["usage"].get(name, 0) or 0)
    except (TypeError, ValueError):
        return 0

inp = tok("input_tokens")
out = tok("output_tokens")
cr = tok("cache_read_input_tokens")
cw = tok("cache_creation_input_tokens")

ts_utc = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
model = (latest["model"] or "unknown")

# Column order matches the issue #458 spec:
# ts_utc, model, input, output, cache_read, cache_creation, session_id
row = "\t".join([ts_utc, model, str(inp), str(out), str(cr), str(cw), session_id])

# Commit the de-dup marker BEFORE appending the ledger line. If the marker write
# fails we skip the append entirely, so the worst case is dropping a single
# response (a small undercount) rather than double-counting it: were we to append
# first and then fail the marker write, the next PostToolUse for this same
# assistant message would pass de-dup and append a duplicate row, inflating
# estimated_usd / responses. For a spend tracker, undercount-by-one is strictly
# safer than a phantom over-cap alarm.
tmp = marker + ".tmp"
try:
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(latest["id"])
    os.replace(tmp, marker)
except Exception:
    try:
        os.unlink(tmp)
    except Exception:
        pass
    sys.exit(0)

try:
    with open(usage_log, "a", encoding="utf-8") as f:
        f.write(row + "\n")
except Exception:
    sys.exit(0)

sys.exit(0)
PY

exit 0
