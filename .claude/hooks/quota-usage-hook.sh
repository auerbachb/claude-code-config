#!/bin/bash
# quota-usage-hook.sh — PostToolUse hook (all tools): per-response API spend ledger.
#
# On each tool call, inspects the session transcript, finds the most recent
# assistant message and its token usage, costs it with the per-model pricing in
# quota-config.json, and appends ONE tab-separated line to
# ~/.claude/quota-usage.log (append-only, same family as script-usage.log /
# skill-usage.log). The /quota skill + quota-budget.sh read this ledger to report
# today's spend and project end-of-day vs the daily cap (issue #458).
#
# Input  (stdin) : JSON with {session_id, transcript_path, cwd, tool_name, ...}
# Output (stdout): empty JSON object (non-blocking)
# Exit code      : always 0 — never blocks tool execution
#
# De-duplication:
#   A single assistant message can spawn several PostToolUse events (one per
#   tool_use block). We must count each assistant message's tokens once, so the
#   hook records the last-logged message id per session in
#   ~/.claude/quota-usage.d/<session>.last and skips when it is unchanged.
#
# TSV columns (10):
#   ts_utc  et_date  session_id  message_id  model
#   input_tokens  output_tokens  cache_creation_tokens  cache_read_tokens  cost_usd
#
# Limitation: PostToolUse fires only when a tool runs, so a final text-only
#   assistant message (no tool call) is not captured. This tracks the large
#   majority of spend, which is what the daily projection needs.
#
# Env overrides (tests): QUOTA_CONFIG, QUOTA_USAGE_LOG, QUOTA_STATE_DIR.

set -uo pipefail

INPUT=$(cat)

# Always emit empty JSON and never fail — this hook is strictly non-blocking.
trap 'echo "{}"; exit 0' EXIT

command -v python3 >/dev/null 2>&1 || exit 0

# Resolve config path: env override, else repo root (two levels up from this hook).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CONFIG_PATH="${QUOTA_CONFIG:-$REPO_ROOT/quota-config.json}"

USAGE_LOG="${QUOTA_USAGE_LOG:-$HOME/.claude/quota-usage.log}"
STATE_DIR="${QUOTA_STATE_DIR:-$HOME/.claude/quota-usage.d}"

mkdir -p "$(dirname "$USAGE_LOG")" "$STATE_DIR" 2>/dev/null || exit 0

# NOTE: pass the hook payload via env var, NOT stdin. The heredoc below already
# claims python's stdin to deliver the program, so a piped stdin would be
# shadowed and read back empty.
QUOTA_HOOK_INPUT="$INPUT" python3 - "$CONFIG_PATH" "$USAGE_LOG" "$STATE_DIR" <<'PY' 2>/dev/null || exit 0
import json, os, sys
from datetime import datetime, timezone

config_path, usage_log, state_dir = sys.argv[1], sys.argv[2], sys.argv[3]

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

# --- Pricing (USD per 1,000,000 tokens) ---
def load_pricing(path):
    try:
        with open(path, encoding="utf-8") as f:
            cfg = json.load(f)
    except Exception:
        cfg = {}
    pricing = cfg.get("pricing") if isinstance(cfg, dict) else None
    if not isinstance(pricing, dict):
        pricing = {}
    default = pricing.get("default")
    if not isinstance(default, dict):
        default = {"input": 15.0, "output": 75.0, "cache_write": 18.75, "cache_read": 1.5}
    return pricing, default

pricing, default_price = load_pricing(config_path)

def price_for(model):
    model = model or ""
    best_key, best_len = None, -1
    for key, val in pricing.items():
        if key in ("default", "_comment") or not isinstance(val, dict):
            continue
        if key in model and len(key) > best_len:
            best_key, best_len = key, len(key)
    chosen = pricing.get(best_key, default_price) if best_key else default_price
    def num(v, fb):
        try:
            return float(v)
        except (TypeError, ValueError):
            return fb
    return {
        "input": num(chosen.get("input"), default_price.get("input", 0.0)),
        "output": num(chosen.get("output"), default_price.get("output", 0.0)),
        "cache_write": num(chosen.get("cache_write"), default_price.get("cache_write", 0.0)),
        "cache_read": num(chosen.get("cache_read"), default_price.get("cache_read", 0.0)),
    }

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
cw = tok("cache_creation_input_tokens")
cr = tok("cache_read_input_tokens")

p = price_for(latest["model"])
cost = (inp * p["input"] + out * p["output"] + cw * p["cache_write"] + cr * p["cache_read"]) / 1_000_000.0

now = datetime.now(timezone.utc)
ts_utc = now.strftime("%Y-%m-%dT%H:%M:%SZ")
try:
    import zoneinfo
    et_date = datetime.now(zoneinfo.ZoneInfo("America/New_York")).date().isoformat()
except Exception:
    et_date = now.date().isoformat()

row = "\t".join([
    ts_utc, et_date, session_id, latest["id"], (latest["model"] or "unknown"),
    str(inp), str(out), str(cw), str(cr), f"{cost:.6f}",
])

try:
    with open(usage_log, "a", encoding="utf-8") as f:
        f.write(row + "\n")
except Exception:
    sys.exit(0)

# Update the per-session marker only after a successful append.
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
PY

exit 0
