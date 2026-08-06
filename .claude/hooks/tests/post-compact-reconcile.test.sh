#!/usr/bin/env bash
# Regression tests for post-compact-reconcile.sh (issue #813).
# Asserts correct event registration wiring in global-settings.json,
# correct hookEventName in emitted JSON, stdin fully consumed, and exit 0
# behavior.
#
# Follows the same conventions as session-start-sync.test.sh.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
HOOK="$REPO_ROOT/.claude/hooks/post-compact-reconcile.sh"
SETTINGS="$REPO_ROOT/global-settings.json"

fail() { echo "FAIL: $*" >&2; exit 1; }

# --- 1. Registration: must be under PostCompact in global-settings.json ---
python3 - "$SETTINGS" <<'PY' || fail "post-compact-reconcile.sh not found under PostCompact in global-settings.json"
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
hooks = data.get("hooks", {})
post_compact = hooks.get("PostCompact", [])
found = any(
    h.get("command", "").endswith("post-compact-reconcile.sh")
    for group in post_compact
    for h in group.get("hooks", [])
)
sys.exit(0 if found else 1)
PY

# --- 2. PostCompact registration must have timeout 10 ---
python3 - "$SETTINGS" <<'PY' || fail "post-compact-reconcile.sh PostCompact registration does not have timeout 10"
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
hooks = data.get("hooks", {})
post_compact = hooks.get("PostCompact", [])
for group in post_compact:
    for h in group.get("hooks", []):
        if h.get("command", "").endswith("post-compact-reconcile.sh"):
            sys.exit(0 if h.get("timeout") == 10 else 1)
sys.exit(1)
PY

# --- 3. Must NOT be registered under any other event ---
python3 - "$SETTINGS" <<'PY' || fail "post-compact-reconcile.sh appears under an event other than PostCompact"
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
hooks = data.get("hooks", {})
for event, groups in hooks.items():
    if event == "PostCompact":
        continue
    if not isinstance(groups, list):
        continue
    for group in groups:
        for h in (group.get("hooks") or []):
            if h.get("command", "").endswith("post-compact-reconcile.sh"):
                print(f"found under {event}", file=sys.stderr)
                sys.exit(1)
sys.exit(0)
PY

# --- 4. Hook script exits 0 on empty input ---
out=$(echo '{}' | bash "$HOOK" 2>/dev/null)
[[ $? -eq 0 ]] || fail "hook must exit 0"
[[ -n "$out" ]] || fail "hook must produce output on empty input"

# --- 5. Output must be valid JSON containing hookEventName: "PostCompact" ---
HOOK_OUT="$out" python3 - <<'PY' || fail "hook output is not valid JSON with hookEventName PostCompact; got: $out"
import json, os, sys
text = os.environ.get("HOOK_OUT", "").strip()
if not text or text == '{}':
    # Empty output is acceptable only if there's nothing to report — but this
    # hook always has something to say (the reconciliation prompt). Flag it.
    print("hook produced empty or bare-{} output", file=sys.stderr)
    sys.exit(1)
try:
    obj = json.loads(text)
except json.JSONDecodeError as e:
    print(f"not valid JSON: {e}", file=sys.stderr)
    sys.exit(1)
hso = obj.get("hookSpecificOutput", {})
event_name = hso.get("hookEventName", "")
if event_name != "PostCompact":
    print(f"hookEventName is '{event_name}', expected 'PostCompact'", file=sys.stderr)
    sys.exit(1)
ctx = hso.get("additionalContext", "")
if not ctx:
    print("additionalContext is empty", file=sys.stderr)
    sys.exit(1)
sys.exit(0)
PY

# --- 6. additionalContext must mention Post-Compaction Recovery ---
HOOK_OUT="$out" python3 - <<'PY' || fail "additionalContext does not mention Post-Compaction Recovery"
import json, os, sys
text = os.environ.get("HOOK_OUT", "").strip()
try:
    obj = json.loads(text)
except json.JSONDecodeError:
    sys.exit(1)
ctx = obj.get("hookSpecificOutput", {}).get("additionalContext", "")
# The context must reference the recovery sequence so the agent knows what to do.
if "Post-Compaction Recovery" not in ctx:
    print(f"context missing 'Post-Compaction Recovery'; got: {ctx[:120]!r}", file=sys.stderr)
    sys.exit(1)
sys.exit(0)
PY

# --- 7. compact_summary in payload is surfaced in additionalContext ---
PAYLOAD='{"compact_summary":"Compacted 3 PRs in flight","session_id":"test-123"}'
OUT_WITH_SUMMARY=$(echo "$PAYLOAD" | bash "$HOOK" 2>/dev/null)
HOOK_OUT="$OUT_WITH_SUMMARY" python3 - <<'PY' || fail "compact_summary from payload not surfaced in additionalContext"
import json, os, sys
text = os.environ.get("HOOK_OUT", "").strip()
try:
    obj = json.loads(text)
except json.JSONDecodeError as e:
    print(f"not valid JSON: {e}", file=sys.stderr)
    sys.exit(1)
ctx = obj.get("hookSpecificOutput", {}).get("additionalContext", "")
if "Compacted 3 PRs in flight" not in ctx:
    print(f"compact_summary not in context; got: {ctx[:240]!r}", file=sys.stderr)
    sys.exit(1)
sys.exit(0)
PY

# --- 8. Stdin fully consumed (no EPIPE on large input) ---
# Generate >64 KB of input to exceed any pipe buffer; hook must drain it all
# without producing a broken-pipe error or hanging.
python3 -c "import sys; sys.stdout.write('{\"compact_summary\":\"x\"' + ',\"pad\":\"' + 'A'*65536 + '\"}')" \
  | bash "$HOOK" >/dev/null 2>&1 \
  || fail "hook failed or hung on large stdin input"

echo "ok   — post-compact-reconcile.sh: all tests passed"
